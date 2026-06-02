// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title InitiateYieldStrategyWithdrawal
 * @notice Mainnet StableStaker migration — SET 1 of 2 (story 054): PHASE-1 "initiate".
 *
 *         Opens the 24-hour total-withdrawal window on the three live mainnet yield
 *         strategies (DOLA / USDC / USDe) so they can be drained and replaced by new
 *         versions that support `setAsideBuffer`. NO funds move in this script; it only
 *         calls `totalWithdrawal(token, client)` once per strategy, which (because each
 *         strategy is currently in `WithdrawalStatus.None`) routes into the phase-1
 *         `_initiateWithdrawal` branch: snapshots the client's principal, sets status to
 *         `Initiated`, and emits `WithdrawalInitiated(token, client, balance, initiatedAt,
 *         executableAt)` with `executableAt = initiatedAt + 24h`.
 *
 *         Story 055 (set 2) calls the SAME function again inside the 24h→72h window to
 *         execute (drain) the withdrawal. Capture each `executableAt` from this run's logs.
 *
 *         The `client` is the phUSD minter (PhusdStableMinter). On-chain verification
 *         (principalOf + full Deposited-event replay across all three strategies, story
 *         054 pre-flight) confirmed the minter is the ONLY principal-holding client on
 *         every strategy — no extra per-client withdrawals are required.
 *
 * NON-NEGOTIABLE pre-flight asserts (Configuration Safety gate), per strategy:
 *   - owner() == deployer ledger (else `onlyOwner` reverts on broadcast anyway; fail loud early)
 *   - underlyingToken() == intended token (DOLA/USDC/USDe)
 *   - principalOf(token, minter) > 0 (initiating an empty position reverts in _initiateWithdrawal)
 *   - withdrawal status == None || Expired (guards against the in-waiting-period revert and
 *     against accidentally re-running after story 055 has executed)
 *   - paused() == false (totalWithdrawal is whenNotPaused)
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run (no broadcast — deployer impersonated, prints snapshot principal + executableAt):
 *   PREVIEW_MODE=true forge script script/InitiateYieldStrategyWithdrawal.s.sol:InitiateYieldStrategyWithdrawal \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast (ledger — opens the windows):
 *   forge script script/InitiateYieldStrategyWithdrawal.s.sol:InitiateYieldStrategyWithdrawal \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

/// @notice Minimal view+action interface for the live yield strategies.
/// @dev Deliberately NOT importing the in-repo AYieldStrategy: the *deployed* mainnet
///      bytecode predates the EnumerableSet client refactor, so newer getters
///      (getAuthorizedClients/authorizedClientCount) revert on-chain. Every method
///      below was confirmed present on the live contracts during the story 054 pre-flight.
interface ILiveYieldStrategy {
    function owner() external view returns (address);
    function underlyingToken() external view returns (address);
    function paused() external view returns (bool);
    function principalOf(address token, address account) external view returns (uint256);

    /// @dev Public mapping getter: token => client => (initiatedAt, status, balance).
    ///      status enum: 0=None, 1=Initiated, 2=Executable, 3=Expired.
    function withdrawalStates(address token, address client)
        external
        view
        returns (uint256 initiatedAt, uint8 status, uint256 balance);

    /// @dev Two-phase total withdrawal. With status None/Expired this initiates (phase 1).
    function totalWithdrawal(address token, address client) external;
}

contract InitiateYieldStrategyWithdrawal is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES (read-only refs)
    // ==========================================

    // Owner / Ledger signer (HD path m/44'/60'/46'/0/0, index 46)
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // phUSD minter — the authorized client whose collateral backs minted phUSD.
    // Pre-flight (principalOf + Deposited-event replay) confirmed it is the ONLY
    // principal-holding client on all three strategies.
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;

    // Active yield strategies (the 3 to drain) — from server/deployments/mainnet-addresses.ts
    address public constant YIELD_STRATEGY_DOLA = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;
    address public constant YIELD_STRATEGY_USDC = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address public constant YIELD_STRATEGY_USDE = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;

    // Underlying tokens (must match each strategy's underlyingToken()).
    // USDe address confirmed on-chain in pre-flight: YieldStrategyUSDe.underlyingToken().
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // Withdrawal timing constant (mirrors AYieldStrategy.WAITING_PERIOD).
    uint256 public constant WAITING_PERIOD = 24 hours;

    uint256 public constant CHAIN_ID = 1;

    bool public isPreview;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
    }

    function run() external {
        console.log("=========================================");
        console.log("  StableStaker migration set 1/2 (story 054)");
        console.log("  PHASE 1: INITIATE 24h withdrawal window");
        console.log("=========================================");
        console.log("Chain ID:        ", block.chainid);
        console.log("Owner (ledger):  ", OWNER_ADDRESS);
        console.log("Client (minter): ", PHUSD_STABLE_MINTER);
        console.log("");

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign each totalWithdrawal ***");
            console.log("");
            vm.startBroadcast();
        }

        _initiate("DOLA", YIELD_STRATEGY_DOLA, DOLA);
        _initiate("USDC", YIELD_STRATEGY_USDC, USDC);
        _initiate("USDe", YIELD_STRATEGY_USDE, USDe);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("");
        console.log("=========================================");
        if (isPreview) {
            console.log("  PREVIEW complete. No state changed on-chain.");
            console.log("  Re-run without PREVIEW_MODE (with --ledger) to open the windows.");
        } else {
            console.log("  BROADCAST complete. 3 WithdrawalInitiated events emitted.");
            console.log("  Record each executableAt; story 055 MUST run in [executableAt, executableAt+48h].");
        }
        console.log("=========================================");
    }

    /// @notice Pre-flight-assert one strategy then call totalWithdrawal to open its window.
    function _initiate(string memory label, address strategyAddr, address token) internal {
        ILiveYieldStrategy strategy = ILiveYieldStrategy(strategyAddr);

        console.log("--- Initiate:", label, "---");
        console.log("  strategy:", strategyAddr);
        console.log("  token:   ", token);

        // ---- Configuration Safety gate (NON-NEGOTIABLE) ----
        address ownr = strategy.owner();
        require(ownr == OWNER_ADDRESS, "preflight: strategy owner != deployer ledger");

        address underlying = strategy.underlyingToken();
        require(underlying == token, "preflight: underlyingToken() mismatch");

        require(!strategy.paused(), "preflight: strategy is paused");

        uint256 principal = strategy.principalOf(token, PHUSD_STABLE_MINTER);
        require(principal > 0, "preflight: no principal to withdraw");

        (uint256 initiatedAt, uint8 status,) = strategy.withdrawalStates(token, PHUSD_STABLE_MINTER);
        // 0 = None, 3 = Expired are the only states from which initiation is valid.
        require(status == 0 || status == 3, "preflight: withdrawal window already open (status != None/Expired)");

        console.log("  owner OK (== deployer)");
        console.log("  underlyingToken OK (== token)");
        console.log("  paused: false OK");
        console.log("  status (0=None,3=Expired):", status);
        console.log("  snapshot principal:", principal);
        if (initiatedAt != 0) {
            console.log("  prior initiatedAt (stale/expired):", initiatedAt);
        }

        // ---- Phase 1: initiate (snapshots principal, sets Initiated, emits WithdrawalInitiated) ----
        strategy.totalWithdrawal(token, PHUSD_STABLE_MINTER);

        // executableAt computed the same way the contract does: now + WAITING_PERIOD.
        uint256 executableAt = block.timestamp + WAITING_PERIOD;
        console.log("  totalWithdrawal(token, minter) called");
        console.log("  computed executableAt (now + 24h):", executableAt);
        console.log("  execution window closes at (now + 72h):", block.timestamp + 72 hours);
        console.log("");
    }
}
