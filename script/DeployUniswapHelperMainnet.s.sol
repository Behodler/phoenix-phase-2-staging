// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";

/// @notice Minimal venue views the preflight reads (copied, not imported, per repo script precedent).
interface IUniHelperPreflightV3 {
    function factory() external view returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IUniHelperPreflightV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IUniHelperPreflightPsm {
    function gem() external view returns (address);
    function usds() external view returns (address);
}

interface IUniHelperPreflightVault {
    function asset() external view returns (address);
}

interface IUniHelperPreflightCurve {
    function coins(uint256 i) external view returns (address);
}

/**
 * @title DeployUniswapHelperMainnet  (story 111, sprint Balancexit)
 * @notice Deploys `src/periphery/UniswapHelper.sol` (story 109) to mainnet in ONE owner transaction and records it in
 *         `server/deployments/progress.uniswap-helper.1.json` for `scripts/patch-mainnet-addresses-uniswap-helper.js`.
 *
 *         CONSTRUCTOR INPUTS. Every input that has a key in the hand-maintained address book
 *         `server/deployments/mainnet-addresses.ts` is READ FROM IT (PhUSD, SUSDS, USDS, USDC, Dola, USDe, SkyPSM,
 *         UniswapV2Router), so the helper can never disagree with the registry the UI reads. The venues the book has
 *         no key for (WETH9, the Uniswap V3 SwapRouter and QuoterV2, the two Curve pools, the V3 fee tier) are the
 *         constants below; story 109's fork test exercised exactly these.
 *
 *         THE phUSD/sUSDS PAIR IS NOT AN INPUT. `PhusdSusdsPair` stays a zero placeholder until story 103's cutover
 *         (broadcast at Stage 4) creates the pair. The helper resolves it at call time via `factory.getPair`, so it
 *         can be deployed first; until the pair exists every swap and liquidity call reverts (`PairNotFound`, or the
 *         Router02 path revert). This script never reads `PhusdSusdsPair`.
 *
 *         IDEMPOTENT. If the progress file already names a helper with code, the script re-checks its immutables
 *         and sends nothing. A progress address with NO code (recorded in forge's local pass, never landed) aborts:
 *         delete the progress file and re-run preview.
 *
 *         The helper is stateless and ownerless, so the deployer key has no further role after the CREATE.
 *
 * Preview:   npm run uniswap-helper:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written)
 * Broadcast: npm run uniswap-helper:broadcast   (backup -> Ledger m/44'/60'/46'/0/0 -> patcher -> :verify)
 * Verify:    npm run uniswap-helper:verify      (read-only, script/VerifyUniswapHelper.s.sol)
 */

/// @notice Shared constants, the address-book reader and the immutables check for the deploy and verify scripts.
abstract contract UniswapHelperMainnetBase is Script {
    uint256 public constant CHAIN_ID = 1;
    string public constant NETWORK_NAME = "mainnet";

    /// @dev Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0), the `--sender` of every repo mainnet script.
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    string public constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";
    string public constant PROGRESS_FILE = "server/deployments/progress.uniswap-helper.1.json";

    // ---- Venues with no mainnet-addresses.ts key (story 111 table; story 109 fork-tested these) ----
    address public constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564; // SwapRouter (v1)
    address public constant V3_QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address public constant CURVE_DOLA_3CRV = 0xAA5A67c256e27A5d80712c51971408db3370927D;
    address public constant CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72; // stableswap-ng
    uint24 public constant V3_FEE = 500;

    struct HelperConfig {
        address phUSD;
        address sUSDS;
        address USDS;
        address USDC;
        address DOLA;
        address USDe;
        address WETH;
        address skyPSM;
        address v2Router;
        address v3SwapRouter;
        address v3Quoter;
        address curveDolaPool;
        address curveUsdePool;
        uint24 v3Fee;
    }

    /// @notice The constructor inputs: address-book keys where they exist, the constants above otherwise.
    function expectedConfig() public view returns (HelperConfig memory c) {
        string memory book = vm.readFile(ADDRESS_BOOK);
        c.phUSD = _requireBook(book, "PhUSD");
        c.sUSDS = _requireBook(book, "SUSDS");
        c.USDS = _requireBook(book, "USDS");
        c.USDC = _requireBook(book, "USDC");
        c.DOLA = _requireBook(book, "Dola");
        c.USDe = _requireBook(book, "USDe");
        c.WETH = WETH9;
        c.skyPSM = _requireBook(book, "SkyPSM");
        c.v2Router = _requireBook(book, "UniswapV2Router");
        c.v3SwapRouter = V3_SWAP_ROUTER;
        c.v3Quoter = V3_QUOTER_V2;
        c.curveDolaPool = CURVE_DOLA_3CRV;
        c.curveUsdePool = CURVE_USDE_USDC;
        c.v3Fee = V3_FEE;
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

    /// @dev Every constructor input must be a live contract on the current chain.
    function _requireCode(HelperConfig memory c) internal view {
        _code(c.phUSD, "phUSD");
        _code(c.sUSDS, "sUSDS");
        _code(c.USDS, "USDS");
        _code(c.USDC, "USDC");
        _code(c.DOLA, "DOLA");
        _code(c.USDe, "USDe");
        _code(c.WETH, "WETH9");
        _code(c.skyPSM, "SkyPSM");
        _code(c.v2Router, "UniswapV2Router");
        _code(c.v3SwapRouter, "V3SwapRouter");
        _code(c.v3Quoter, "V3QuoterV2");
        _code(c.curveDolaPool, "CurveDola3CRV");
        _code(c.curveUsdePool, "CurveUsdeUsdc");
    }

    /// @dev Configuration safety (repo CLAUDE.md): every venue is cross-checked against the tokens it must trade,
    ///      so a wrong-but-live address (a different pool, a different PSM, a missing V3 fee tier) refuses to
    ///      deploy instead of producing a helper whose routes revert or misprice. The constructor itself only
    ///      rejects zero addresses and a USDe/USDC pool with the wrong coin order.
    function _requireVenues(HelperConfig memory c) internal view {
        require(IUniHelperPreflightVault(c.sUSDS).asset() == c.USDS, "preflight: sUSDS.asset() != USDS");
        require(IUniHelperPreflightPsm(c.skyPSM).gem() == c.USDC, "preflight: SkyPSM.gem() != USDC");
        require(IUniHelperPreflightPsm(c.skyPSM).usds() == c.USDS, "preflight: SkyPSM.usds() != USDS");
        require(IUniHelperPreflightV2Router(c.v2Router).WETH() == c.WETH, "preflight: Router02.WETH() != WETH9");
        require(
            IUniHelperPreflightV2Router(c.v2Router).factory() != address(0), "preflight: Router02.factory() is zero"
        );
        address v3Factory = IUniHelperPreflightV3(c.v3SwapRouter).factory();
        require(v3Factory != address(0), "preflight: V3 SwapRouter.factory() is zero");
        require(IUniHelperPreflightV3(c.v3Quoter).factory() == v3Factory, "preflight: V3 QuoterV2 on another factory");
        require(
            IUniHelperPreflightV3(v3Factory).getPool(c.WETH, c.USDC, c.v3Fee) != address(0),
            "preflight: no Uniswap V3 WETH/USDC pool at the fee tier"
        );
        require(
            IUniHelperPreflightCurve(c.curveDolaPool).coins(0) == c.DOLA, "preflight: Curve DOLA-3CRV coins(0) != DOLA"
        );
        require(
            IUniHelperPreflightCurve(c.curveUsdePool).coins(0) == c.USDe, "preflight: Curve USDe/USDC coins(0) != USDe"
        );
        require(
            IUniHelperPreflightCurve(c.curveUsdePool).coins(1) == c.USDC, "preflight: Curve USDe/USDC coins(1) != USDC"
        );
    }

    function _code(address a, string memory name) private view {
        require(a.code.length > 0, string.concat("preflight: no code at ", name));
    }

    /// @dev require()s every immutable of `h` against `c`. Revert strings name the first mismatch.
    function _checkImmutables(UniswapHelper h, HelperConfig memory c) internal view {
        require(address(h).code.length > 0, "verify: UniswapHelper has no code");
        require(h.phUSD() == c.phUSD, "verify: phUSD mismatch");
        require(h.sUSDS() == c.sUSDS, "verify: sUSDS mismatch");
        require(h.USDS() == c.USDS, "verify: USDS mismatch");
        require(h.USDC() == c.USDC, "verify: USDC mismatch");
        require(h.DOLA() == c.DOLA, "verify: DOLA mismatch");
        require(h.USDe() == c.USDe, "verify: USDe mismatch");
        require(h.WETH() == c.WETH, "verify: WETH mismatch");
        require(h.skyPSM() == c.skyPSM, "verify: skyPSM mismatch");
        require(h.v2Router() == c.v2Router, "verify: v2Router mismatch");
        require(h.v3SwapRouter() == c.v3SwapRouter, "verify: v3SwapRouter mismatch");
        require(h.v3Quoter() == c.v3Quoter, "verify: v3Quoter mismatch");
        require(h.curveDolaPool() == c.curveDolaPool, "verify: curveDolaPool mismatch");
        require(h.curveUsdePool() == c.curveUsdePool, "verify: curveUsdePool mismatch");
        require(h.v3Fee() == c.v3Fee, "verify: v3Fee mismatch");
        require(h.ETH() == address(0), "verify: ETH sentinel mismatch");
    }

    function _logConfig(HelperConfig memory c) internal pure {
        console.log("  phUSD          ", c.phUSD);
        console.log("  sUSDS          ", c.sUSDS);
        console.log("  USDS           ", c.USDS);
        console.log("  USDC           ", c.USDC);
        console.log("  DOLA           ", c.DOLA);
        console.log("  USDe           ", c.USDe);
        console.log("  WETH9          ", c.WETH);
        console.log("  SkyPSM         ", c.skyPSM);
        console.log("  V2 Router02    ", c.v2Router);
        console.log("  V3 SwapRouter  ", c.v3SwapRouter);
        console.log("  V3 QuoterV2    ", c.v3Quoter);
        console.log("  Curve DOLA-3CRV", c.curveDolaPool);
        console.log("  Curve USDe/USDC", c.curveUsdePool);
        console.log("  V3 fee tier    ", uint256(c.v3Fee));
    }

    /// @dev The progress file path. `virtual` only so fork tests can point at a scratch file; production uses
    ///      PROGRESS_FILE.
    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    /// @dev The helper recorded in the progress file, or address(0) when there is none.
    function _progressHelper() internal view returns (address) {
        string memory json;
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            return address(0);
        }
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".contracts.UniswapHelper.address")) return address(0);
        return vm.parseJsonAddress(json, ".contracts.UniswapHelper.address");
    }
}

contract DeployUniswapHelperMainnet is UniswapHelperMainnetBase {
    UniswapHelper public helper;
    bool public deployedThisRun;

    function run() external {
        console.log("=================================================");
        console.log("  DEPLOY UniswapHelper - MAINNET (story 111)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        bool isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );

        HelperConfig memory c = expectedConfig();
        console.log("Constructor inputs:");
        _logConfig(c);
        _requireCode(c);
        _requireVenues(c);
        console.log("Preflight OK: every input has code and every venue trades the expected tokens.");

        address recorded = _progressHelper();
        if (recorded != address(0)) {
            require(
                recorded.code.length > 0,
                "Progress file names a UniswapHelper with NO CODE - it was recorded in forge's local pass but never landed. Delete server/deployments/progress.uniswap-helper.1.json and re-run preview."
            );
            helper = UniswapHelper(payable(recorded));
            _checkImmutables(helper, c);
            console.log("UniswapHelper already deployed (progress file):", recorded);
            console.log("Immutables match - nothing to do, no transaction sent (idempotent).");
            return;
        }

        if (isPreview) {
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }
        helper = new UniswapHelper(
            c.phUSD,
            c.sUSDS,
            c.USDS,
            c.USDC,
            c.DOLA,
            c.USDe,
            c.WETH,
            c.skyPSM,
            c.v2Router,
            c.v3SwapRouter,
            c.v3Quoter,
            c.curveDolaPool,
            c.curveUsdePool,
            c.v3Fee
        );
        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }
        deployedThisRun = true;

        console.log("UniswapHelper:", address(helper));
        _checkImmutables(helper, c);
        console.log("OK: every immutable matches its constructor input.");

        address p = helper.pair();
        if (p == address(0)) {
            console.log(
                "phUSD/sUSDS pair not yet created (Stage 4 pending): swaps and liquidity calls revert until then."
            );
        } else {
            console.log("phUSD/sUSDS pair:", p);
        }

        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (a preview CREATE address is fork-local)."
            );
            return;
        }
        _writeProgress();
    }

    function _writeProgress() internal {
        vm.serializeAddress("s111.helper", "address", address(helper));
        string memory entry = vm.serializeBool("s111.helper", "deployed", true);
        string memory contracts = vm.serializeString("s111.contracts", "UniswapHelper", entry);
        vm.serializeUint("s111.root", "chainId", CHAIN_ID);
        vm.serializeString("s111.root", "networkName", NETWORK_NAME);
        vm.serializeString("s111.root", "deploymentStatus", "completed");
        string memory json = vm.serializeString("s111.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written:", _progressFile());
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode
    ///      (`vm.setEnv` is process-wide and forge runs suites in parallel). Production always reads the env.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
