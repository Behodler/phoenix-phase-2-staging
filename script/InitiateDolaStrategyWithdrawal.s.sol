// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title InitiateDolaStrategyWithdrawal  (story 090, sprint stable-staker-v2)
 * @notice STARTS THE CLOCK ONLY on the two-phase `totalWithdrawal(DOLA, PhusdStableMinter)` of the live
 *         autoDOLA yield strategy `YieldStrategyDola` 0x1760E05356Ec1FBBA159C730781dCfB9920524e2.
 *
 *         `totalWithdrawal` is two calls:
 *           1st call (status None / Expired): snapshots the client's principal, sets status Initiated, emits
 *              WithdrawalInitiated. NOTHING MOVES. This script makes exactly this call.
 *           2nd call inside [initiatedAt + 6h, initiatedAt + 78h]: EXECUTES - redeems the client's LIVE
 *              pro-rata share, sends the DOLA to owner() (the OWNER EOA) and zeroes the client's principal.
 *              That call belongs to story 092's cutover broadcast ONLY. This script REFUSES to make it: if a
 *              withdrawal is already pending (waiting period or execution window) the preflight reverts.
 *
 *         Only the PhusdStableMinter's principal needs the delay. StableStaker V1 exits synchronously through
 *         `initiateMigration` inside the cutover, so V1 is never a client of this script (enforced).
 *
 *         TIMING: the cutover broadcast must land >= 6h and <= 78h after THIS broadcast. If the window lapses,
 *         rerun this script (lazy expiry makes it re-initiable). `totalWithdrawal` is whenNotPaused, so a pause
 *         during the window also blocks execution.
 *
 *         STALE DELAY DOCS (intentionally not edited here): the NatSpec above `totalWithdrawal` in
 *         lib/vault/src/AYieldStrategy.sol still says 24h/48h, and script/archives/InitiateYieldStrategyWithdrawal.s.sol
 *         hard-codes WAITING_PERIOD = 24h. Vault story-048 changed the constants to 6h/72h; the live 0x1760 bytecode
 *         holds 6h/72h (broadcast/MigrateSaga2Deploy.s.sol/1/run-latest.json). This script asserts them on-chain.
 *
 * Preview:   npm run initiate-dola-ys-withdrawal:preview     (PREVIEW_MODE=true, OWNER prank, nothing signed)
 * Broadcast: npm run initiate-dola-ys-withdrawal:broadcast   (Ledger m/44'/60'/46'/0/0)
 * Status:    npm run dola-ys-withdrawal:status               (read-only, safe anytime)
 */

/// @notice Minimal interface for the live AYieldStrategy at 0x1760 (copied, not imported, per archive precedent).
interface IDolaYieldStrategyLive {
    function owner() external view returns (address);
    function underlyingToken() external view returns (address);
    function paused() external view returns (bool);
    function WAITING_PERIOD() external view returns (uint256);
    function EXECUTION_WINDOW() external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);

    /// @dev token => client => (initiatedAt, status, balance). Status enum in lib/vault/src/AYieldStrategy.sol
    ///      `WithdrawalStatus { None, Initiated, Executable, Expired }` => 0, 1, 2, 3. The transitions to
    ///      Executable / Expired are LAZY: only written inside the next totalWithdrawal call.
    function withdrawalStates(address token, address client)
        external
        view
        returns (uint256 initiatedAt, uint8 status, uint256 balance);

    function totalWithdrawal(address token, address client) external;
}

/// @notice Minimal PhusdStableMinter view (lib/phUSD-stable-minter/src/PhusdStableMinter.sol StablecoinConfig).
interface IPhusdStableMinterConfigs {
    function stablecoinConfigs(address stablecoin)
        external
        view
        returns (
            address yieldStrategy,
            uint256 exchangeRate,
            uint8 decimals,
            bool enabled,
            uint256 maxMintPerDay,
            uint256 mintedToday,
            uint256 lastMintTimestamp
        );
}

/// @notice Shared constants + helpers for the initiate and status scripts.
abstract contract DolaStrategyWithdrawalBase is Script {
    // mainnet-addresses.ts `YieldStrategyDola` (plain ERC4626YieldStrategy(owner, DOLA, autoDOLA))
    address public constant YIELD_STRATEGY_DOLA = 0x1760E05356Ec1FBBA159C730781dCfB9920524e2;
    // mainnet-addresses.ts `Dola`
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    // mainnet-addresses.ts `PhusdStableMinter` - the only client whose principal needs the delayed withdrawal
    address public constant PHUSD_STABLE_MINTER = 0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C;
    // mainnet-addresses.ts `StableStaker` (V1) - NEVER a client here; exits via initiateMigration in the cutover
    address public constant STABLE_STAKER_V1 = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    // Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0)
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // lib/vault/src/AYieldStrategy.sol after vault story-048 (verified against the 0x1760 bytecode)
    uint256 public constant WAITING_PERIOD = 6 hours;
    uint256 public constant EXECUTION_WINDOW = 72 hours;
    uint256 public constant TOTAL_DURATION = WAITING_PERIOD + EXECUTION_WINDOW; // 78h

    // AYieldStrategy.WithdrawalStatus ordinals (checked against the enum declaration, not assumed)
    uint8 internal constant STATUS_NONE = 0;
    uint8 internal constant STATUS_INITIATED = 1;
    uint8 internal constant STATUS_EXECUTABLE = 2;
    uint8 internal constant STATUS_EXPIRED = 3;

    function _strategy() internal pure returns (IDolaYieldStrategyLive) {
        return IDolaYieldStrategyLive(YIELD_STRATEGY_DOLA);
    }

    function _statusName(uint8 s) internal pure returns (string memory) {
        if (s == STATUS_NONE) return "None";
        if (s == STATUS_INITIATED) return "Initiated";
        if (s == STATUS_EXECUTABLE) return "Executable";
        if (s == STATUS_EXPIRED) return "Expired";
        return "Unknown";
    }

    /// @notice Unix seconds -> "YYYY-MM-DD HH:MM:SS UTC" (Howard Hinnant civil-from-days).
    function _isoUtc(uint256 ts) internal pure returns (string memory) {
        uint256 daysSince = ts / 86400;
        uint256 secs = ts % 86400;
        int256 z = int256(daysSince) + 719468;
        int256 era = z / 146097;
        uint256 doe = uint256(z - era * 146097);
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = uint256(int256(yoe) + era * 400) + (m <= 2 ? 1 : 0);
        return string.concat(
            vm.toString(y),
            "-",
            _pad2(m),
            "-",
            _pad2(d),
            " ",
            _pad2(secs / 3600),
            ":",
            _pad2((secs % 3600) / 60),
            ":",
            _pad2(secs % 60),
            " UTC"
        );
    }

    function _pad2(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", vm.toString(v)) : vm.toString(v);
    }
}

contract InitiateDolaStrategyWithdrawal is DolaStrategyWithdrawalBase {
    /// @dev Overridable so fork tests can pin preview without racing the process-wide env.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }

    /// @dev The client whose withdrawal is initiated. Virtual ONLY so a test can prove the V1 guard fires.
    function _client() internal view virtual returns (address) {
        return PHUSD_STABLE_MINTER;
    }

    function run() external {
        bool isPreview = _previewModeFromEnv();
        address client = _client();
        IDolaYieldStrategyLive strategy = _strategy();

        console.log("=========================================");
        console.log("  story 090: INITIATE DOLA strategy totalWithdrawal (clock only)");
        console.log("=========================================");
        console.log("strategy:", YIELD_STRATEGY_DOLA);
        console.log("token:   ", DOLA);
        console.log("client:  ", client);
        console.log("mode:    ", isPreview ? "PREVIEW (OWNER prank, nothing signed)" : "BROADCAST (Ledger)");

        uint256 principal = _preflight(client);

        if (isPreview) {
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }
        strategy.totalWithdrawal(DOLA, client);
        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- read-back ----
        (uint256 initiatedAt, uint8 status, uint256 balance) = strategy.withdrawalStates(DOLA, client);
        require(status == STATUS_INITIATED, "readback: status != Initiated");
        require(balance == principal, "readback: snapshot balance != principal");
        require(initiatedAt == block.timestamp, "readback: initiatedAt != block.timestamp");

        uint256 executableAt = initiatedAt + WAITING_PERIOD;
        uint256 expiresAt = initiatedAt + TOTAL_DURATION;
        console.log("");
        console.log("READBACK OK: status Initiated, snapshot balance == principal:", balance);
        console.log("initiatedAt (unix): ", initiatedAt, _isoUtc(initiatedAt));
        console.log("executableAt (unix):", executableAt, _isoUtc(executableAt));
        console.log("expiresAt (unix):   ", expiresAt, _isoUtc(expiresAt));
        console.log("");
        console.log(">>> broadcast the cutover between executableAt and expiresAt <<<");
        console.log("    (if expiresAt passes first, rerun initiate-dola-ys-withdrawal:broadcast)");
        if (isPreview) {
            console.log("PREVIEW complete - no state changed on-chain.");
        }
    }

    /// @notice Every check runs BEFORE the write. Returns the minter principal captured just before initiation.
    function _preflight(address client) internal view returns (uint256 principal) {
        IDolaYieldStrategyLive strategy = _strategy();

        require(block.chainid == 1, "preflight: wrong chain (expected mainnet 1)");
        require(strategy.owner() == OWNER, "preflight: strategy owner != OWNER");
        require(strategy.underlyingToken() == DOLA, "preflight: underlyingToken != DOLA");
        require(!strategy.paused(), "preflight: strategy is paused (totalWithdrawal is whenNotPaused)");
        require(strategy.WAITING_PERIOD() == WAITING_PERIOD, "preflight: on-chain WAITING_PERIOD != 6 hours");
        require(strategy.EXECUTION_WINDOW() == EXECUTION_WINDOW, "preflight: on-chain EXECUTION_WINDOW != 72 hours");

        require(
            client != STABLE_STAKER_V1,
            "preflight: client is StableStaker V1 - V1 exits synchronously via initiateMigration in the cutover"
        );
        require(client == PHUSD_STABLE_MINTER, "preflight: client must be PhusdStableMinter");

        principal = strategy.principalOf(DOLA, client);
        require(principal > 0, "preflight: minter DOLA principal is zero (withdrawal already executed, or DOLA never deposited) - nothing to initiate");

        (uint256 initiatedAt, uint8 status,) = strategy.withdrawalStates(DOLA, client);
        if (status == STATUS_NONE || status == STATUS_EXPIRED) {
            console.log("preflight: withdrawal status", _statusName(status), "- OK to initiate");
        } else if (status == STATUS_INITIATED || status == STATUS_EXECUTABLE) {
            if (block.timestamp > initiatedAt + TOTAL_DURATION) {
                console.log("preflight: stored status", _statusName(status), "is past 78h (lazy expiry) - re-initiable");
            } else if (block.timestamp < initiatedAt + WAITING_PERIOD) {
                revert(
                    "preflight: DOLA withdrawal ALREADY PENDING (in 6h waiting period) - do not re-run; check npm run dola-ys-withdrawal:status"
                );
            } else {
                revert(
                    "preflight: DOLA withdrawal ALREADY PENDING and INSIDE its execution window - a second totalWithdrawal would EXECUTE and move the minter's DOLA to OWNER; that belongs only to story 092's cutover. Check npm run dola-ys-withdrawal:status"
                );
            }
        } else {
            revert("preflight: unknown withdrawal status on-chain - investigate before initiating");
        }

        console.log("preflight: owner / underlying / unpaused / 6h+72h / client OK; minter principal:", principal);
    }
}
