// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import {CurveAMMAdapter} from "@vault/AMMAdapters/CurveAMMAdapter.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";
// StableStaker's constructor takes the flax-token-v2 IFlax; alias to avoid clashing with any
// transitively-scoped IFlax (mirrors DeployMocks.s.sol).
import {IFlax as IFlaxStaker} from "flax-token/IFlax.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MigrateStableStakerMainnet
 * @notice Mainnet StableStaker migration — SET 2 of 2 (story 055): EXECUTE the cutover.
 *
 *         Run 24–72h AFTER story 054 (InitiateYieldStrategyWithdrawal), inside the execution
 *         window story 054 opened. Performs the WHOLE cutover in order under ONE broadcast:
 *
 *           PHASE A — drain: re-call totalWithdrawal(token, minter) on each old strategy so it
 *                     falls into the Executable branch and redeems the minter's principal to the
 *                     deployer EOA (owner). Capture the ACTUAL received amount via balance delta.
 *           PHASE B — deploy 3 NEW strategies reusing the SAME external vault + underlying each old
 *                     strategy used (read on-chain in B-asserts). DOLA/USDC: plain
 *                     ERC4626YieldStrategy. USDe: ERC4626MarketYieldStrategy + fresh CurveAMMAdapter
 *                     (USDe<->sUSDe via crvUSD, routes from lib/vault/AMMRoutes.json) at 30 bps
 *                     slippage tolerance — sUSDe redeem is BLOCKED by Ethena's cooldown
 *                     (cooldownDuration == 86400 on-chain, 2026-06-10), so a plain strategy would
 *                     brick every USDe withdrawal path; the live USDe strategy is already
 *                     market-based (asserted in B). Each new strategy is then wired to the global
 *                     Pauser (setPauser + Pauser.register).
 *           PHASE C — minter cutover + re-deposit: setClient(minter) -> registerStablecoin(token,
 *                     newYS, PRESERVED rate, decimals) -> minter.approveYS(token, newYS) -> deployer
 *                     approves newYS for received -> depositAsOwner(token, received, minter).
 *           PHASE D — SYA cutover: addYieldStrategy(newYS, token) + newYS.setWithdrawer(sya, true)
 *                     for each; THEN removeYieldStrategy(oldYS) for each old strategy.
 *           PHASE E — phlimbo + other-dependency verification (verified NO-OP; see pre-flight).
 *           PHASE F — StableStaker: deploy + setPauser/pauser.register + phUSD.setMinter; per token
 *                     addToken/setClient/setYieldStrategy/setSetAsideBuffer(ss,10)/phUSDPerDay.
 *
 *         POST: the package.json broadcast entry runs patch-mainnet-addresses-stable-staker.js to
 *         write the 3 new YS + StableStaker addresses into mainnet-addresses.ts.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * CONFIGURATION SAFETY (NON-NEGOTIABLE). Every safety-relevant value is asserted in-script and the
 * script REVERTS on mainnet rather than proceed if any is unsafe/unexpected:
 *   - block.chainid == 1
 *   - each old (token,minter) withdrawal status == Executable (else STOP — never silently re-init)
 *   - deployer == owner() of each old strategy, the minter, and the SYA
 *   - each old strategy underlyingToken()/vault() == the expected (story-confirmed, on-chain-verified) value
 *   - minter exchangeRate preserved == 1e18 (read live; assert == expected) and decimals match
 *   - daily rates USDe=10e18, USDC=7e18, DOLA=5e18 all > 0; buffer == 10 (<=100)
 *   - USDe market strategy slippage tolerance set + asserted == 30 bps (user-confirmed 2026-06-10,
 *     matching the live-route measurement recorded in DeployMocks Phase 2.7)
 *   - phUSD / pauser / minter / SYA != address(0)
 *
 * Re-deposit uses the ACTUAL received amount (deployer balance delta across the drain), NOT the
 * story-054 snapshot (vault rounding / accrued yield drift between initiate and execute).
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run (no broadcast — deployer impersonated):
 *   PREVIEW_MODE=true forge script script/MigrateStableStakerMainnet.s.sol:MigrateStableStakerMainnet \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *   NOTE: until the 24h window has elapsed the preview WILL revert at the Phase A status assert.
 *         That is the safety gate working — run the live broadcast only once status == Executable.
 *
 * Broadcast (ledger):
 *   node scripts/backup-mainnet-addresses.js && \
 *   forge script script/MigrateStableStakerMainnet.s.sol:MigrateStableStakerMainnet \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv && \
 *   node scripts/patch-mainnet-addresses-stable-staker.js
 */

/// @notice Minimal interface for the LIVE (old) yield strategies.
/// @dev The deployed mainnet bytecode predates the EnumerableSet client refactor, so newer getters
///      revert on-chain. Every method below was confirmed present during the story 054/055 pre-flight.
interface ILiveYieldStrategy {
    function owner() external view returns (address);
    function underlyingToken() external view returns (address);
    function vault() external view returns (address);
    function paused() external view returns (bool);
    function principalOf(address token, address account) external view returns (uint256);

    /// @dev token => client => (initiatedAt, status, balance). status: 0=None,1=Initiated,2=Executable,3=Expired.
    function withdrawalStates(address token, address client)
        external
        view
        returns (uint256 initiatedAt, uint8 status, uint256 balance);

    /// @dev Two-phase total withdrawal. With status Executable this executes (phase 2) -> funds to owner.
    function totalWithdrawal(address token, address client) external;
}

/// @notice Probe for the LIVE USDe strategy's market-ness (plain strategies have no ammAdapter()).
interface IOldMarketYS {
    function ammAdapter() external view returns (address);
}

/// @notice Minimal interface for the LIVE phUSD minter (PhusdStableMinter).
/// @dev The DEPLOYED struct has only 4 fields (yieldStrategy, exchangeRate, decimals, enabled) — it
///      predates the maxMintPerDay/mintedToday/lastMintTimestamp additions in current source. Reading
///      the full 7-tuple reverts with a buffer overrun, so the getter is declared with 4 returns.
interface ILiveMinter {
    function owner() external view returns (address);
    function stablecoinConfigs(address stablecoin)
        external
        view
        returns (address yieldStrategy, uint256 exchangeRate, uint8 decimals, bool enabled);
    function registerStablecoin(address stablecoin, address yieldStrategy, uint256 exchangeRate, uint8 decimals)
        external;
    function approveYS(address token, address yieldStrategy) external;
}

/// @notice Minimal interface for the LIVE StableYieldAccumulator.
interface ILiveSYA {
    function owner() external view returns (address);
    function addYieldStrategy(address strategy, address token) external;
    function removeYieldStrategy(address strategy) external;
    function isRegisteredStrategy(address strategy) external view returns (bool);
    function getYieldStrategies() external view returns (address[] memory);
}

/// @notice Minimal interface for the LIVE Pauser.
interface ILivePauser {
    function register(address contractToRegister) external;
    function owner() external view returns (address);
}

/// @notice Minimal interface for the LIVE phUSD (FlaxToken).
interface ILivePhUSD {
    function setMinter(address minter, bool canMint) external;
}

contract MigrateStableStakerMainnet is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES (read-only refs)
    // ==========================================

    // Owner / Ledger signer (HD path m/44'/60'/46'/0/0)
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // phUSD minter — the authorized client whose collateral backs minted phUSD.
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;

    // StableYieldAccumulator.
    address public constant SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;

    // phUSD (FlaxToken) + Pauser.
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // OLD (live) yield strategies to drain + replace — from mainnet-addresses.ts / story 054.
    address public constant OLD_YS_DOLA = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;
    address public constant OLD_YS_USDC = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address public constant OLD_YS_USDE = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;

    // Underlying tokens.
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // External ERC4626 vaults each old strategy uses (asserted == the live strategy's vault() in B).
    address public constant VAULT_DOLA = 0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d; // AutoDOLA
    address public constant VAULT_USDC = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35; // AutoUSDC
    address public constant VAULT_USDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497; // SUSDe

    // ==========================================
    //   SAFETY CONSTANTS (Configuration Safety)
    // ==========================================

    // Minter exchange rate to PRESERVE per token (read live in C, asserted == this). Pre-flight: all 1e18.
    uint256 public constant EXPECTED_RATE = 1e18;
    uint8 public constant DECIMALS_DOLA = 18;
    uint8 public constant DECIMALS_USDC = 6;
    uint8 public constant DECIMALS_USDE = 18;

    // StableStaker daily phUSD emission budgets (phUSD wei/day, 18-dec; user-specified 2026-06-10:
    // DOLA 5 / USDC 7 / USDe 10 phUSD per day).
    uint256 public constant DAILY_USDE = 10e18;
    uint256 public constant DAILY_USDC = 7e18;
    uint256 public constant DAILY_DOLA = 5e18;

    // ---- USDe market-strategy config (USDe cannot use the plain ERC4626 path: sUSDe redeem is
    // blocked while Ethena's cooldown is on — cooldownDuration read 86400 on-chain 2026-06-10) ----
    // Curve Router NG + route hops, transcribed from lib/vault/AMMRoutes.json (Curve.RouterNG),
    // verified against the adapter's setRoute endpoint checks at run time.
    address public constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address public constant POOL_USDE_CRVUSD = 0xF55B0f6F2Da5ffDDb104b58a60F2862745960442;
    address public constant POOL_CRVUSD_SUSDE = 0x57064F49Ad7123C92560882a45518374ad982e85;
    // Slippage tolerance for the new USDe market strategy: 30 bps (0.3%), user-confirmed 2026-06-10.
    // Matches the go-live tolerance measured on the live Curve route (DeployMocks Phase 2.7 notes);
    // the LIVE (old) strategy runs at 120 bps — this is a deliberate tightening, owner-retunable
    // later via setSlippageTolerance.
    uint256 public constant USDE_SLIPPAGE_BPS = 30;

    // Set-aside buffer for StableStaker on each strategy: integer PERCENT (require <= 100), NOT bps/wad.
    uint256 public constant SETASIDE_BUFFER = 10;

    // Withdrawal status enum values: 0=None, 1=Initiated, 2=Executable, 3=Expired.
    uint8 public constant STATUS_INITIATED = 1;
    uint8 public constant STATUS_EXECUTABLE = 2;

    // Two-phase withdrawal timing (mirrors AYieldStrategy WAITING_PERIOD / TOTAL_DURATION). The stored
    // status only transitions to Executable LAZILY inside totalWithdrawal, so a static withdrawalStates
    // read still returns Initiated(1) even when the window is open. We therefore derive executability
    // from initiatedAt rather than trusting the stored enum: executable iff
    //   status == Initiated AND  now in [initiatedAt + 24h, initiatedAt + 72h]
    // (or, defensively, status already == Executable from a prior triggering tx).
    uint256 public constant WAITING_PERIOD = 24 hours;
    uint256 public constant TOTAL_DURATION = 72 hours;

    uint256 public constant CHAIN_ID = 1;

    // ==========================================
    //   DEPLOYMENT / RUNTIME STATE
    // ==========================================

    bool public isPreview;

    // New strategies (deployed in B). USDe is market-based (AMM swap instead of vault redeem).
    ERC4626YieldStrategy public newYsDola;
    ERC4626YieldStrategy public newYsUsdc;
    ERC4626MarketYieldStrategy public newYsUsde;
    CurveAMMAdapter public usdeAmmAdapter;

    // Actual received amounts captured in A (deployer balance deltas).
    uint256 public receivedDola;
    uint256 public receivedUsdc;
    uint256 public receivedUsde;

    StableStaker public stableStaker;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
    }

    function run() external {
        console.log("=========================================");
        console.log("  StableStaker migration set 2/2 (story 055)");
        console.log("  EXECUTE: drain -> deploy YS -> cutover -> StableStaker");
        console.log("=========================================");
        console.log("Chain ID:        ", block.chainid);
        console.log("Owner (ledger):  ", OWNER_ADDRESS);
        console.log("Client (minter): ", PHUSD_STABLE_MINTER);
        console.log("SYA:             ", SYA);
        console.log("");

        // ---- GLOBAL pre-flight asserts (cheap, before any broadcast) ----
        _globalPreflight();

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            console.log("*** NOTE: reverts at Phase A status assert until the 24h window opens ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign each tx ***");
            console.log("");
            vm.startBroadcast();
        }

        _phaseA_drain();
        _phaseB_deploy();
        _phaseC_minterCutoverAndRedeposit();
        _phaseD_syaCutover();
        _phaseE_dependencyVerification();
        _phaseF_stableStaker();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _printSummary();
    }

    // ==========================================
    //   GLOBAL PRE-FLIGHT (Configuration Safety)
    // ==========================================

    function _globalPreflight() internal view {
        // Owners for the onlyOwner calls.
        require(ILiveYieldStrategy(OLD_YS_DOLA).owner() == OWNER_ADDRESS, "preflight: DOLA old strategy owner != deployer");
        require(ILiveYieldStrategy(OLD_YS_USDC).owner() == OWNER_ADDRESS, "preflight: USDC old strategy owner != deployer");
        require(ILiveYieldStrategy(OLD_YS_USDE).owner() == OWNER_ADDRESS, "preflight: USDe old strategy owner != deployer");
        require(ILiveMinter(PHUSD_STABLE_MINTER).owner() == OWNER_ADDRESS, "preflight: minter owner != deployer");
        require(ILiveSYA(SYA).owner() == OWNER_ADDRESS, "preflight: SYA owner != deployer");
        // Pauser.register is onlyOwner on the Pauser itself — needed for the new strategies + staker.
        require(ILivePauser(PAUSER).owner() == OWNER_ADDRESS, "preflight: Pauser owner != deployer");

        // Non-zero critical addresses.
        require(PHUSD != address(0), "preflight: phUSD zero");
        require(PAUSER != address(0), "preflight: pauser zero");
        require(PHUSD_STABLE_MINTER != address(0), "preflight: minter zero");
        require(SYA != address(0), "preflight: SYA zero");

        // Rates / buffer / slippage.
        require(DAILY_USDE > 0 && DAILY_USDC > 0 && DAILY_DOLA > 0, "preflight: a daily rate is 0");
        require(DAILY_USDE == 10e18 && DAILY_USDC == 7e18 && DAILY_DOLA == 5e18, "preflight: daily rate mismatch");
        require(SETASIDE_BUFFER == 10 && SETASIDE_BUFFER <= 100, "preflight: buffer != 10");
        require(USDE_SLIPPAGE_BPS > 0 && USDE_SLIPPAGE_BPS <= 100, "preflight: USDe slippage outside (0,100] bps");
    }

    // ==========================================
    //   PHASE A — drain (execute total withdrawal)
    // ==========================================

    function _phaseA_drain() internal {
        console.log("=== PHASE A: drain old strategies (execute totalWithdrawal) ===");
        receivedDola = _drainOne("DOLA", OLD_YS_DOLA, DOLA);
        receivedUsdc = _drainOne("USDC", OLD_YS_USDC, USDC);
        receivedUsde = _drainOne("USDe", OLD_YS_USDE, USDe);
        require(receivedDola > 0, "Phase A: zero DOLA received");
        require(receivedUsdc > 0, "Phase A: zero USDC received");
        require(receivedUsde > 0, "Phase A: zero USDe received");
        console.log("");
    }

    /// @dev Assert the withdrawal is Executable, then execute and return the ACTUAL received amount.
    function _drainOne(string memory label, address oldYs, address token) internal returns (uint256 received) {
        ILiveYieldStrategy ys = ILiveYieldStrategy(oldYs);
        console.log("--- drain", label, "---");

        require(!ys.paused(), "Phase A: old strategy paused");

        (uint256 initiatedAt, uint8 status,) = ys.withdrawalStates(token, PHUSD_STABLE_MINTER);

        // Derive executability from initiatedAt — the stored status transitions to Executable only
        // LAZILY inside totalWithdrawal, so a static read returns Initiated(1) even when the window is
        // open. STOP unless the window is genuinely open; NEVER let the call fall into the phase-1
        // re-initiate branch (which would re-open a fresh 24h window with funds half-migrated).
        bool windowOpen;
        if (status == STATUS_EXECUTABLE) {
            // Already lazily transitioned by a prior tx; still must be within the 72h total window.
            windowOpen = block.timestamp <= initiatedAt + TOTAL_DURATION;
        } else if (status == STATUS_INITIATED) {
            windowOpen = block.timestamp >= initiatedAt + WAITING_PERIOD
                && block.timestamp <= initiatedAt + TOTAL_DURATION;
        } else {
            // None(0) or Expired(3): there is no live window to execute.
            windowOpen = false;
        }
        require(
            windowOpen,
            "Phase A STOP: withdrawal not Executable (in 24h wait, Expired >72h, or None). Re-run story 054 if needed; do NOT proceed."
        );

        uint256 balBefore = IERC20(token).balanceOf(OWNER_ADDRESS);
        ys.totalWithdrawal(token, PHUSD_STABLE_MINTER); // phase 2: redeems shares -> underlying to owner (deployer)
        uint256 balAfter = IERC20(token).balanceOf(OWNER_ADDRESS);
        received = balAfter - balBefore;

        console.log("  withdrawal window OPEN (executable) OK; stored status:", status);
        console.log("  received (balance delta):", received);
        return received;
    }

    // ==========================================
    //   PHASE B — deploy new strategies
    // ==========================================

    function _phaseB_deploy() internal {
        console.log("=== PHASE B: deploy 3 new strategies (DOLA/USDC plain, USDe market) ===");
        newYsDola = _deployOne("DOLA", OLD_YS_DOLA, DOLA, VAULT_DOLA);
        newYsUsdc = _deployOne("USDC", OLD_YS_USDC, USDC, VAULT_USDC);
        newYsUsde = _deployUsdeMarket();

        // Global-pauser wiring for each new strategy (AYieldStrategy implements IPausable).
        // setPauser BEFORE register — Pauser.register validates pauser() == the Pauser contract.
        _wirePauser("DOLA", newYsDola);
        _wirePauser("USDC", newYsUsdc);
        _wirePauser("USDe", newYsUsde);
        console.log("");
    }

    function _wirePauser(string memory label, AYieldStrategy newYs) internal {
        newYs.setPauser(PAUSER);
        ILivePauser(PAUSER).register(address(newYs));
        require(newYs.pauser() == PAUSER, "Phase B: strategy pauser not set");
        console.log("  Pauser wired + registered for", label, address(newYs));
    }

    /// @dev Reuse the SAME external vault + underlying the live strategy uses — read off the OLD strategy
    ///      on-chain and assert == the expected constant before deploying.
    function _deployOne(string memory label, address oldYs, address token, address expectedVault)
        internal
        returns (ERC4626YieldStrategy newYs)
    {
        ILiveYieldStrategy old = ILiveYieldStrategy(oldYs);
        require(old.underlyingToken() == token, "Phase B: old underlyingToken mismatch");
        require(old.vault() == expectedVault, "Phase B: old vault mismatch");

        newYs = new ERC4626YieldStrategy(OWNER_ADDRESS, token, expectedVault);
        console.log("--- deployed new", label, "---");
        console.log("  newYS:", address(newYs));
        console.log("  token:", token);
        console.log("  vault:", expectedVault);
        return newYs;
    }

    /// @dev USDe MUST stay market-based: sUSDe redeem/withdraw revert while Ethena's cooldown is on
    ///      (cooldownDuration == 86400, read on-chain 2026-06-10), so a plain ERC4626YieldStrategy
    ///      would brick every USDe withdrawal path (skimSurplus, totalWithdrawal, staker exits). The
    ///      LIVE strategy is already an ERC4626MarketYieldStrategy (adapter 0xCd6e87bD…, 120 bps) —
    ///      asserted below. A FRESH CurveAMMAdapter is deployed (rather than reusing the live one) so
    ///      the adapter matches the current vault-lib IAMMAdapter and its routes are set from the
    ///      canonical AMMRoutes.json payloads under this script's control.
    function _deployUsdeMarket() internal returns (ERC4626MarketYieldStrategy newYs) {
        ILiveYieldStrategy old = ILiveYieldStrategy(OLD_YS_USDE);
        require(old.underlyingToken() == USDe, "Phase B: old USDe underlyingToken mismatch");
        require(old.vault() == VAULT_USDE, "Phase B: old USDe vault mismatch");
        require(IOldMarketYS(OLD_YS_USDE).ammAdapter() != address(0), "Phase B: old USDe YS not market-based");

        usdeAmmAdapter = new CurveAMMAdapter(OWNER_ADDRESS, CURVE_ROUTER_NG);
        _setUsdeRoutes(usdeAmmAdapter);

        newYs = new ERC4626MarketYieldStrategy(OWNER_ADDRESS, USDe, VAULT_USDE, address(usdeAmmAdapter));
        newYs.setSlippageTolerance(USDE_SLIPPAGE_BPS);
        require(newYs.slippageToleranceBps() == USDE_SLIPPAGE_BPS, "Phase B: USDe slippage tolerance unset");

        console.log("--- deployed new USDe (market) ---");
        console.log("  newYS:", address(newYs));
        console.log("  ammAdapter:", address(usdeAmmAdapter));
        console.log("  vault:", VAULT_USDE);
        console.log("  slippage tolerance (bps):", USDE_SLIPPAGE_BPS);
        return newYs;
    }

    /// @dev Route payloads transcribed verbatim from lib/vault/AMMRoutes.json (Curve.RouterNG):
    ///      USDe <-> sUSDe via crvUSD, two stable-ng hops each way. setRoute validates the path
    ///      endpoints (path[0] == tokenIn, last non-zero == tokenOut) on-chain.
    function _setUsdeRoutes(CurveAMMAdapter adapter) internal {
        address[5] memory noBasePools; // all zero — no meta-swaps on this route

        // USDe -> sUSDe (deposit leg): USDe -[0xF55B…0442]-> crvUSD -[0x5706…2e85]-> sUSDe
        address[11] memory pathIn = [
            USDe, POOL_USDE_CRVUSD, CRVUSD, POOL_CRVUSD_SUSDE, VAULT_USDE,
            address(0), address(0), address(0), address(0), address(0), address(0)
        ];
        uint256[5][5] memory paramsIn;
        paramsIn[0] = [uint256(0), 1, 1, 10, 2];
        paramsIn[1] = [uint256(0), 1, 1, 10, 2];
        adapter.setRoute(USDe, VAULT_USDE, pathIn, paramsIn, noBasePools);

        // sUSDe -> USDe (withdraw leg): the reverse hops with flipped (i, j) coin indices.
        address[11] memory pathOut = [
            VAULT_USDE, POOL_CRVUSD_SUSDE, CRVUSD, POOL_USDE_CRVUSD, USDe,
            address(0), address(0), address(0), address(0), address(0), address(0)
        ];
        uint256[5][5] memory paramsOut;
        paramsOut[0] = [uint256(1), 0, 1, 10, 2];
        paramsOut[1] = [uint256(1), 0, 1, 10, 2];
        adapter.setRoute(VAULT_USDE, USDe, pathOut, paramsOut, noBasePools);

        console.log("  CurveAMMAdapter routes set (USDe<->sUSDe via crvUSD)");
    }

    // ==========================================
    //   PHASE C — minter cutover + re-deposit
    // ==========================================

    function _phaseC_minterCutoverAndRedeposit() internal {
        console.log("=== PHASE C: minter cutover + re-deposit ===");
        _cutoverMinter("DOLA", DOLA, newYsDola, receivedDola, DECIMALS_DOLA);
        _cutoverMinter("USDC", USDC, newYsUsdc, receivedUsdc, DECIMALS_USDC);
        _cutoverMinter("USDe", USDe, newYsUsde, receivedUsde, DECIMALS_USDE);
        console.log("");
    }

    function _cutoverMinter(
        string memory label,
        address token,
        AYieldStrategy newYs,
        uint256 received,
        uint8 expectedDecimals
    ) internal {
        ILiveMinter minter = ILiveMinter(PHUSD_STABLE_MINTER);

        // Read & PRESERVE the minter's existing config; assert it matches expectations.
        (, uint256 rate, uint8 decimals,) = minter.stablecoinConfigs(token);
        require(rate == EXPECTED_RATE, "Phase C: minter exchangeRate != expected (preserve check)");
        require(decimals == expectedDecimals, "Phase C: minter decimals mismatch");

        // 1. authorize the minter as a client ON the new strategy (else minter deposit path reverts).
        newYs.setClient(PHUSD_STABLE_MINTER, true);

        // 2. re-point the minter at the new strategy, preserving rate + decimals.
        minter.registerStablecoin(token, address(newYs), rate, decimals);

        // 3. let the minter approve the NEW strategy for future user mint() deposits (minter is owned by
        //    deployer). Without this, the next mint() reverts on transfer into the strategy.
        minter.approveYS(token, address(newYs));

        // 4. re-deposit the ACTUAL drained principal: deployer approves the new strategy, then
        //    depositAsOwner credits the minter as client (no phUSD minted). NOTE: for USDe the
        //    market strategy credits the slippage-haircut principal (received * (1 - 30bps)) and
        //    swaps in via Curve — the principalOf log below will show the haircut figure. This
        //    mirrors how the LIVE USDe market strategy already books principal (at 120 bps).
        IERC20(token).approve(address(newYs), received);
        newYs.depositAsOwner(token, received, PHUSD_STABLE_MINTER);

        console.log("--- minter re-pointed", label, "---");
        console.log("  newYS:", address(newYs));
        console.log("  preserved rate:", rate);
        console.log("  re-deposited (received):", received);
        console.log("  minter principalOf(new):", newYs.principalOf(token, PHUSD_STABLE_MINTER));
    }

    // ==========================================
    //   PHASE D — SYA cutover
    // ==========================================

    function _phaseD_syaCutover() internal {
        console.log("=== PHASE D: SYA cutover (add new + authorize, then remove old) ===");
        ILiveSYA sya = ILiveSYA(SYA);

        // Add + authorize the NEW strategies FIRST so SYA is never left with zero strategies mid-run.
        _syaAdd(sya, "DOLA", newYsDola, DOLA);
        _syaAdd(sya, "USDC", newYsUsdc, USDC);
        _syaAdd(sya, "USDe", newYsUsde, USDe);

        // Then remove the drained OLD strategies.
        _syaRemove(sya, "DOLA", OLD_YS_DOLA);
        _syaRemove(sya, "USDC", OLD_YS_USDC);
        _syaRemove(sya, "USDe", OLD_YS_USDE);
        console.log("");
    }

    function _syaAdd(ILiveSYA sya, string memory label, AYieldStrategy newYs, address token) internal {
        sya.addYieldStrategy(address(newYs), token);
        newYs.setWithdrawer(SYA, true); // authorize SYA to skimSurplus on the new strategy
        console.log("  SYA + new", label, address(newYs));
    }

    function _syaRemove(ILiveSYA sya, string memory label, address oldYs) internal {
        require(sya.isRegisteredStrategy(oldYs), "Phase D: old strategy not registered in SYA");
        sya.removeYieldStrategy(oldYs);
        console.log("  SYA - old", label, oldYs);
    }

    // ==========================================
    //   PHASE E — dependency verification (no-op)
    // ==========================================

    function _phaseE_dependencyVerification() internal view {
        // Verified during pre-flight (see scratchpad/analysis-reports/phStaging2-story-055-preflight-reads.md):
        // the ONLY live fund-routing consumers of the yield strategies are the phUSD minter (re-pointed
        // in Phase C) and the SYA (re-pointed in Phase D). phlimbo references the SYA, not strategies
        // directly (SYA.phlimbo() push model); PhlimboEA holds NO yield-strategy state. No phlimbo re-wire
        // is required. This phase is a verified no-op.
        console.log("=== PHASE E: dependency verification (no phlimbo/other re-wire required) ===");
        console.log("");
    }

    // ==========================================
    //   PHASE F — StableStaker deploy + wiring
    // ==========================================

    function _phaseF_stableStaker() internal {
        console.log("=== PHASE F: deploy + wire StableStaker ===");

        // 1. deploy the MasterChef-style stable farm (deployer = initial owner).
        stableStaker = new StableStaker(IFlaxStaker(PHUSD), OWNER_ADDRESS);
        console.log("  StableStaker:", address(stableStaker));

        // 2. pauser wiring — setPauser BEFORE register (register validates pauser() == this).
        stableStaker.setPauser(PAUSER);
        ILivePauser(PAUSER).register(address(stableStaker));

        // 3. authorize StableStaker as a phUSD minter (it mints rewards on claim/withdraw/migration).
        ILivePhUSD(PHUSD).setMinter(address(stableStaker), true);

        // 4. per-token wiring loop. addToken -> setClient ON strategy -> setYieldStrategy ->
        //    setSetAsideBuffer(ss, 10) ON strategy -> phUSDPerDay. Mirrors DeployMocks Phase 3.7,
        //    with the mainnet daily rates (USDe 10 / USDC 7 / DOLA 5 phUSD/day, user 2026-06-10).
        _wirePool("DOLA", DOLA, newYsDola, DAILY_DOLA);
        _wirePool("USDC", USDC, newYsUsdc, DAILY_USDC);
        _wirePool("USDe", USDe, newYsUsde, DAILY_USDE);
        console.log("");
    }

    function _wirePool(string memory label, address token, AYieldStrategy newYs, uint256 dailyRate) internal {
        stableStaker.addToken(token);
        newYs.setClient(address(stableStaker), true); // client added ON the strategy (two-sided wiring)
        stableStaker.setYieldStrategy(token, IYieldStrategy(address(newYs)));
        newYs.setSetAsideBuffer(address(stableStaker), SETASIDE_BUFFER); // 10% integer percent, on the STRATEGY
        stableStaker.phUSDPerDay(token, dailyRate);
        console.log("--- StableStaker pool wired", label, "---");
        console.log("  token:", token);
        console.log("  phUSD/day:", dailyRate);
        console.log("  set-aside buffer (strategy):", newYs.setAsideBufferSize(address(stableStaker)));
    }

    // ==========================================
    //   SUMMARY
    // ==========================================

    function _printSummary() internal view {
        console.log("=========================================");
        console.log("  MIGRATION SUMMARY (story 055)");
        console.log("=========================================");
        console.log("New YieldStrategy DOLA:", address(newYsDola));
        console.log("New YieldStrategy USDC:", address(newYsUsdc));
        console.log("New YieldStrategy USDe:", address(newYsUsde));
        console.log("StableStaker:          ", address(stableStaker));
        console.log("");
        console.log("Re-deposited (received) DOLA:", receivedDola);
        console.log("Re-deposited (received) USDC:", receivedUsdc);
        console.log("Re-deposited (received) USDe:", receivedUsde);
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No state changed on-chain.");
        } else {
            console.log("BROADCAST complete. Run patch-mainnet-addresses-stable-staker.js to update addresses.");
        }
        console.log("=========================================");
    }
}
