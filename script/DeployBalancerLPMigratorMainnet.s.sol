// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {BalancerLPMigrator} from "../src/periphery/BalancerLPMigrator.sol";

/// @notice Minimal venue views the preflight reads (copied, not imported, per repo script precedent).
interface IBLMPreflightV2Router {
    function factory() external view returns (address);
}

interface IBLMPreflightV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IBLMPreflightV3Vault {
    function getPoolTokens(address pool) external view returns (address[] memory tokens);
}

/**
 * @title DeployBalancerLPMigratorMainnet  (story 121, sprint balancer-lp-migrator)
 * @notice Deploys `src/periphery/BalancerLPMigrator.sol` to mainnet in ONE owner transaction and records it in
 *         `server/deployments/progress.balancer-lp-migrator.1.json` for
 *         `scripts/patch-mainnet-addresses-balancer-lp-migrator.js`.
 *
 *         CONSTRUCTOR INPUTS. The Uniswap V2 Router02, sUSDS and phUSD are READ FROM the hand-maintained address
 *         book `server/deployments/mainnet-addresses.ts` (`UniswapV2Router`, `SUSDS`, `PhUSD`), so the migrator
 *         cannot disagree with the registry the UI reads. The Balancer V3 Vault, Router and pool are the constants
 *         below: story 107 removed the Balancer keys from the book, and its header records these as their last
 *         values.
 *
 *         PREFLIGHT. Every input has code; `factory.getPair(sUSDS, phUSD)` equals the book's `PhusdSusdsPair`; the
 *         Vault reports the pool's tokens as exactly {sUSDS, phUSD}; and the book's `BalancerLPMigrator` key is
 *         still the zero placeholder (unless the progress file records a prior deploy, see below).
 *
 *         IDEMPOTENT. If the progress file already names a migrator with code, the script re-checks its
 *         immutables and sends nothing. A progress address with NO code (recorded in forge's local pass, never
 *         landed) aborts: delete the progress file and re-run preview. A filled book key with no progress file
 *         aborts too: the migrator was deployed some other way, so check it by hand.
 *
 *         The migrator is stateless and ownerless, so the deployer key has no further role after the CREATE.
 *
 * Preview:   npm run balancer-lp-migrator:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed)
 * Broadcast: npm run balancer-lp-migrator:broadcast   (backup -> Ledger m/44'/60'/46'/0/0 -> patcher -> :verify
 *                                                       -> tax ledger)
 * Verify:    npm run balancer-lp-migrator:verify      (read-only, script/VerifyBalancerLPMigrator.s.sol)
 */

/// @notice Shared constants, the address-book reader, the preflight and the immutables check.
abstract contract BalancerLPMigratorMainnetBase is Script {
    uint256 public constant CHAIN_ID = 1;
    string public constant NETWORK_NAME = "mainnet";

    /// @dev Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0), the `--sender` of every repo mainnet script.
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    string public constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";
    string public constant PROGRESS_FILE = "server/deployments/progress.balancer-lp-migrator.1.json";
    string public constant BOOK_KEY = "BalancerLPMigrator";

    // ---- Balancer V3 (no address-book keys since story 107; last values in the mainnet-addresses.ts header) ----
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address public constant BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    /// @dev The 50/50 phUSD/sUSDS weighted pool, which is also the BPT. Token order [sUSDS, phUSD].
    address public constant BALANCER_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;

    struct MigratorConfig {
        address vault;
        address v3Router;
        address pool;
        address uniRouter;
        address sUSDS;
        address phUSD;
        address pair;
    }

    /// @notice The constructor inputs (and the expected pair): address-book keys where they exist, constants
    ///         otherwise.
    function expectedConfig() public view returns (MigratorConfig memory c) {
        string memory book = vm.readFile(ADDRESS_BOOK);
        c.vault = BALANCER_VAULT;
        c.v3Router = BALANCER_ROUTER;
        c.pool = BALANCER_POOL;
        c.uniRouter = _requireBook(book, "UniswapV2Router");
        c.sUSDS = _requireBook(book, "SUSDS");
        c.phUSD = _requireBook(book, "PhUSD");
        c.pair = _requireBook(book, "PhusdSusdsPair");
    }

    /// @dev The address literal of `key` in mainnet-addresses.ts, or address(0) when the key is absent. Matches
    ///      only an uncommented top-level entry (`\n  <key>: "0x..."`), so `USDC` never matches `AutoUSDC`.
    function _bookAddress(string memory book, string memory key) internal pure returns (address) {
        string memory needle = string.concat("\n  ", key, ": \"");
        uint256 at = vm.indexOf(book, needle);
        if (at == type(uint256).max) return address(0);
        bytes memory src = bytes(book);
        uint256 start = at + bytes(needle).length;
        require(src.length >= start + 42, string.concat("address book: truncated entry for ", key));
        bytes memory lit = new bytes(42);
        for (uint256 i; i < 42; i++) {
            lit[i] = src[start + i];
        }
        return vm.parseAddress(string(lit));
    }

    function _requireBook(string memory book, string memory key) internal pure returns (address a) {
        a = _bookAddress(book, key);
        require(a != address(0), string.concat("address book: key missing or zero in mainnet-addresses.ts: ", key));
    }

    /// @dev The migrator named by the address book's `BalancerLPMigrator` key (zero while it is the placeholder).
    ///      `virtual` only so fork tests can stand in a filled or zero key; production reads ADDRESS_BOOK.
    function _bookMigrator() internal view virtual returns (address) {
        string memory book = vm.readFile(ADDRESS_BOOK);
        require(
            vm.indexOf(book, string.concat("\n  ", BOOK_KEY, ": \"")) != type(uint256).max,
            "address book: BalancerLPMigrator key absent from mainnet-addresses.ts"
        );
        return _bookAddress(book, BOOK_KEY);
    }

    /// @dev Configuration safety (repo CLAUDE.md): every venue is cross-checked against the tokens it must
    ///      trade, so a wrong-but-live address refuses to deploy instead of producing a migrator that reverts or
    ///      seeds the wrong pair. The constructor re-checks the pool tokens and the pair itself.
    function _preflight(MigratorConfig memory c) internal view {
        _code(c.vault, "Balancer V3 Vault");
        _code(c.v3Router, "Balancer V3 Router");
        _code(c.pool, "Balancer pool (BPT)");
        _code(c.uniRouter, "UniswapV2Router");
        _code(c.sUSDS, "sUSDS");
        _code(c.phUSD, "phUSD");
        _code(c.pair, "PhusdSusdsPair");

        address factory = IBLMPreflightV2Router(c.uniRouter).factory();
        _code(factory, "UniswapV2Factory");
        require(
            IBLMPreflightV2Factory(factory).getPair(c.sUSDS, c.phUSD) == c.pair,
            "preflight: factory.getPair(sUSDS, phUSD) != PhusdSusdsPair"
        );

        address[] memory tokens = IBLMPreflightV3Vault(c.vault).getPoolTokens(c.pool);
        require(tokens.length == 2, "preflight: Balancer pool does not hold exactly two tokens");
        require(
            (tokens[0] == c.sUSDS && tokens[1] == c.phUSD) || (tokens[0] == c.phUSD && tokens[1] == c.sUSDS),
            "preflight: Balancer pool tokens != {sUSDS, phUSD}"
        );
    }

    function _code(address a, string memory name) private view {
        require(a.code.length > 0, string.concat("preflight: no code at ", name));
    }

    /// @dev require()s every immutable of `m` against `c`. Revert strings name the first mismatch.
    function _checkImmutables(BalancerLPMigrator m, MigratorConfig memory c) internal view {
        require(address(m).code.length > 0, "verify: BalancerLPMigrator has no code");
        require(m.vault() == c.vault, "verify: vault mismatch");
        require(m.v3Router() == c.v3Router, "verify: v3Router mismatch");
        require(m.pool() == c.pool, "verify: pool mismatch");
        require(m.uniRouter() == c.uniRouter, "verify: uniRouter mismatch");
        require(m.sUSDS() == c.sUSDS, "verify: sUSDS mismatch");
        require(m.phUSD() == c.phUSD, "verify: phUSD mismatch");
        require(m.pair() == c.pair, "verify: pair mismatch");
        address[] memory tokens = IBLMPreflightV3Vault(c.vault).getPoolTokens(c.pool);
        require(tokens[m.sUSDSIndex()] == c.sUSDS, "verify: sUSDSIndex mismatch");
        require(tokens[m.phUSDIndex()] == c.phUSD, "verify: phUSDIndex mismatch");
    }

    function _logConfig(MigratorConfig memory c) internal pure {
        console.log("  Balancer V3 Vault ", c.vault);
        console.log("  Balancer V3 Router", c.v3Router);
        console.log("  Balancer pool/BPT ", c.pool);
        console.log("  UniV2 Router02    ", c.uniRouter);
        console.log("  sUSDS             ", c.sUSDS);
        console.log("  phUSD             ", c.phUSD);
        console.log("  phUSD/sUSDS pair  ", c.pair);
    }

    /// @dev The progress file path. `virtual` only so fork tests can point at a scratch file.
    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    /// @dev The migrator recorded in the progress file, or address(0) when there is none.
    function _progressMigrator() internal view returns (address) {
        string memory json;
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            return address(0);
        }
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".contracts.BalancerLPMigrator.address")) {
            return address(0);
        }
        return vm.parseJsonAddress(json, ".contracts.BalancerLPMigrator.address");
    }
}

contract DeployBalancerLPMigratorMainnet is BalancerLPMigratorMainnetBase {
    BalancerLPMigrator public migrator;
    bool public deployedThisRun;

    function run() external {
        console.log("=================================================");
        console.log("  DEPLOY BalancerLPMigrator - MAINNET (story 121)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        bool isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );

        MigratorConfig memory c = expectedConfig();
        console.log("Constructor inputs:");
        _logConfig(c);
        _preflight(c);
        console.log("Preflight OK: every input has code, the pair and the pool tokens match.");

        address recorded = _progressMigrator();
        address booked = _bookMigrator();
        if (recorded != address(0)) {
            require(
                recorded.code.length > 0,
                "Progress file names a BalancerLPMigrator with NO CODE - it was recorded in forge's local pass but never landed. Delete server/deployments/progress.balancer-lp-migrator.1.json and re-run preview."
            );
            require(
                booked == address(0) || booked == recorded,
                "address book BalancerLPMigrator != the progress file's migrator"
            );
            migrator = BalancerLPMigrator(recorded);
            _checkImmutables(migrator, c);
            console.log("BalancerLPMigrator already deployed (progress file):", recorded);
            console.log("Immutables match - nothing to do, no transaction sent (idempotent).");
            return;
        }
        require(
            booked == address(0),
            "address book BalancerLPMigrator is already filled but no progress file records it - check it by hand"
        );

        if (isPreview) {
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }
        migrator = new BalancerLPMigrator(c.vault, c.v3Router, c.pool, c.uniRouter, c.sUSDS, c.phUSD);
        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }
        deployedThisRun = true;

        console.log("BalancerLPMigrator:", address(migrator));
        _checkImmutables(migrator, c);
        console.log("OK: every immutable matches its constructor input.");

        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (a preview CREATE address is fork-local)."
            );
            return;
        }
        _writeProgress();
    }

    function _writeProgress() internal {
        vm.serializeAddress("s121.migrator", "address", address(migrator));
        string memory entry = vm.serializeBool("s121.migrator", "deployed", true);
        string memory contracts = vm.serializeString("s121.contracts", "BalancerLPMigrator", entry);
        vm.serializeUint("s121.root", "chainId", CHAIN_ID);
        vm.serializeString("s121.root", "networkName", NETWORK_NAME);
        vm.serializeString("s121.root", "deploymentStatus", "completed");
        string memory json = vm.serializeString("s121.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written:", _progressFile());
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode
    ///      (`vm.setEnv` is process-wide and forge runs suites in parallel). Production always reads the env.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
