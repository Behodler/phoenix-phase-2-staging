// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";
import {DeployUniswapHelperMainnet, UniswapHelperMainnetBase} from "../script/DeployUniswapHelperMainnet.s.sol";
import {VerifyUniswapHelper} from "../script/VerifyUniswapHelper.s.sol";
import {IUniswapV2Router02} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Router02.sol";
import {CutoverAntimatterPoolHarness} from "./CutoverAntimatterPoolMainnet.fork.t.sol";

interface IUniswapV2FactoryCreate111 {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

/// @dev Pins the mode and the progress path (never the process-wide PREVIEW_MODE env, which races parallel suites,
///      and never the real progress file).
contract DeployUniswapHelperHarness is DeployUniswapHelperMainnet {
    bool internal immutable preview;
    string internal progressPath;

    constructor(bool preview_, string memory progressPath_) {
        preview = preview_;
        progressPath = progressPath_;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    /// @dev Story 122: stands in the address book's AntimatterSusdsPair (the live book is patched only after the
    ///      human's Script B broadcast).
    address internal bookAmPair;

    function setBookAmPair(address p) external {
        bookAmPair = p;
    }

    function _bookAntimatterSusdsPair() internal view override returns (address) {
        return bookAmPair;
    }
}

/// @dev The fork block predates the deploy, so the live address book's filled `UniswapHelper` key names a helper with
///      no code there. The harness stands in the pre-patch zero placeholder so only the scratch progress file counts.
contract VerifyUniswapHelperHarness is VerifyUniswapHelper {
    string internal progressPath;

    constructor(string memory progressPath_) {
        progressPath = progressPath_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookHelper() internal pure override returns (address) {
        return address(0);
    }

    address internal bookAmPair;

    function setBookAmPair(address p) external {
        bookAmPair = p;
    }

    function _bookAntimatterSusdsPair() internal view override returns (address) {
        return bookAmPair;
    }
}

/// @dev Exposes the address-book reader for the no-RPC test.
contract UniswapHelperBookHarness is UniswapHelperMainnetBase {
    function bookAddress(string memory key) external view returns (address) {
        return _bookAddress(vm.readFile(ADDRESS_BOOK), key);
    }
}

/// @dev Story 111's constructor table, written out independently of the script so a drift in either the address
///      book or the script's constants fails here.
abstract contract Story111Table {
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;
    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant V3_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant CURVE_DOLA = 0xAA5A67c256e27A5d80712c51971408db3370927D;
    address constant CURVE_USDE = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    /// @dev Story 120: the constructor gained the Antimatter token.
    address constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    uint24 constant FEE = 500;
}

/**
 * @title DeployUniswapHelperMainnetConfigTest  (story 111)
 * @notice No RPC needed: the deploy's constructor inputs, read from mainnet-addresses.ts plus the script constants,
 *         equal story 111's table.
 */
contract DeployUniswapHelperMainnetConfigTest is Test, Story111Table {
    function test_expectedConfig_matchesStoryTable() public {
        DeployUniswapHelperMainnet s = new DeployUniswapHelperMainnet();
        UniswapHelperMainnetBase.HelperConfig memory c = s.expectedConfig();
        assertEq(c.phUSD, PHUSD, "phUSD");
        assertEq(c.sUSDS, SUSDS, "sUSDS");
        assertEq(c.USDS, USDS, "USDS");
        assertEq(c.USDC, USDC, "USDC");
        assertEq(c.DOLA, DOLA, "DOLA");
        assertEq(c.USDe, USDE, "USDe");
        assertEq(c.WETH, WETH, "WETH");
        assertEq(c.skyPSM, SKY_PSM, "SkyPSM");
        assertEq(c.v2Router, V2_ROUTER, "v2Router");
        assertEq(c.v3SwapRouter, V3_ROUTER, "v3SwapRouter");
        assertEq(c.v3Quoter, V3_QUOTER, "v3Quoter");
        assertEq(c.curveDolaPool, CURVE_DOLA, "curveDolaPool");
        assertEq(c.curveUsdePool, CURVE_USDE, "curveUsdePool");
        assertEq(c.antimatter, ANTIMATTER, "antimatter");
        assertEq(uint256(c.v3Fee), uint256(FEE), "v3Fee");
    }

    function test_bookReader_matchesWholeKeysOnly() public {
        UniswapHelperBookHarness b = new UniswapHelperBookHarness();
        assertEq(b.bookAddress("USDC"), USDC, "USDC, not AutoUSDC");
        assertEq(b.bookAddress("USDe"), USDE, "USDe, not SUSDe");
        assertEq(b.bookAddress("NoSuchKey"), address(0), "absent key");
        // Filled by the patcher after the 2026-10-23 mainnet broadcast.
        assertEq(b.bookAddress("UniswapHelper"), 0x564810D5d9D31754C8dbdb8F62Bb429D50Dfa5b3, "deployed UniswapHelper");
    }
}

/**
 * @title DeployUniswapHelperMainnetForkTest  (story 111)
 * @notice Runs the deploy script's own logic against a mainnet fork. Skips cleanly when RPC_MAINNET is unset.
 *         Proves: preview deploys a helper whose immutables equal story 111's table and writes no progress file;
 *         broadcast mode writes the progress file the patcher reads, and a re-run sends nothing; the verifier passes
 *         with the pair absent (Stage 4 pending) and again, quote smoke test included, once the pair exists; a
 *         freshly deployed helper swaps through an in-fork pair; the verifier rejects a mis-configured helper; the
 *         deploy aborts on a progress address with no code.
 */
contract DeployUniswapHelperMainnetForkTest is Test, Story111Table {
    /// @dev Same block as story 109's fork test. The phUSD/sUSDS V2 pair does not exist at it.
    uint256 constant FORK_BLOCK = 26_170_000;

    string constant TMP_PREFIX = "server/deployments/progress.uniswap-helper.1.forktest-";

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        return true;
    }

    function _tmp(string memory name) internal returns (string memory path) {
        path = string.concat(TMP_PREFIX, name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    function _assertTable(UniswapHelper h) internal view {
        assertEq(h.phUSD(), PHUSD, "phUSD");
        assertEq(h.sUSDS(), SUSDS, "sUSDS");
        assertEq(h.USDS(), USDS, "USDS");
        assertEq(h.USDC(), USDC, "USDC");
        assertEq(h.DOLA(), DOLA, "DOLA");
        assertEq(h.USDe(), USDE, "USDe");
        assertEq(h.WETH(), WETH, "WETH");
        assertEq(h.skyPSM(), SKY_PSM, "skyPSM");
        assertEq(h.v2Router(), V2_ROUTER, "v2Router");
        assertEq(h.v3SwapRouter(), V3_ROUTER, "v3SwapRouter");
        assertEq(h.v3Quoter(), V3_QUOTER, "v3Quoter");
        assertEq(h.curveDolaPool(), CURVE_DOLA, "curveDolaPool");
        assertEq(h.curveUsdePool(), CURVE_USDE, "curveUsdePool");
        assertEq(h.antimatter(), ANTIMATTER, "antimatter");
        assertEq(uint256(h.v3Fee()), uint256(FEE), "v3Fee");
    }

    /// @dev Creates and seeds the phUSD/sUSDS pair (~$1M a side at phUSD = $1), as story 109's fork test does.
    function _createPair() internal returns (address lp) {
        IUniswapV2FactoryCreate111 factory = IUniswapV2FactoryCreate111(IUniswapV2Router02(V2_ROUTER).factory());
        assertEq(factory.getPair(SUSDS, PHUSD), address(0), "pair must not exist at FORK_BLOCK");
        lp = factory.createPair(SUSDS, PHUSD);
        uint256 seed = 1_000_000e18;
        deal(USDS, address(this), seed);
        IERC20(USDS).approve(SUSDS, seed);
        uint256 shares = IERC4626(SUSDS).deposit(seed, address(this));
        deal(PHUSD, address(this), seed);
        IERC20(SUSDS).approve(V2_ROUTER, shares);
        IERC20(PHUSD).approve(V2_ROUTER, seed);
        IUniswapV2Router02(V2_ROUTER).addLiquidity(SUSDS, PHUSD, shares, seed, 0, 0, address(this), block.timestamp);
    }

    /// @dev Story 122: the deploy now refuses unless the AM/sUSDS pair exists and matches the (stood-in) address
    ///      book. At FORK_BLOCK it does not, so create it - seeded with ~100k a side when `seed`, so the verifier's
    ///      Antimatter quote smoke has liquidity to quote against.
    function _createAmPair(bool seed) internal returns (address amp) {
        IUniswapV2FactoryCreate111 factory = IUniswapV2FactoryCreate111(IUniswapV2Router02(V2_ROUTER).factory());
        amp = factory.getPair(ANTIMATTER, SUSDS);
        if (amp == address(0)) amp = factory.createPair(ANTIMATTER, SUSDS);
        if (!seed) return amp;
        uint256 amt = 100_000e18;
        deal(ANTIMATTER, address(this), amt);
        deal(SUSDS, address(this), amt);
        IERC20(ANTIMATTER).approve(V2_ROUTER, amt);
        IERC20(SUSDS).approve(V2_ROUTER, amt);
        IUniswapV2Router02(V2_ROUTER).addLiquidity(ANTIMATTER, SUSDS, amt, amt, 0, 0, address(this), block.timestamp);
    }

    function _deployHarness(bool preview_, string memory path, bool seedAm)
        internal
        returns (DeployUniswapHelperHarness s, address amp)
    {
        amp = _createAmPair(seedAm);
        s = new DeployUniswapHelperHarness(preview_, path);
        s.setBookAmPair(amp);
    }

    function _assertHelperEmpty(UniswapHelper h, address lp) internal view {
        assertEq(address(h).balance, 0, "helper ETH");
        address[8] memory toks = [PHUSD, SUSDS, USDS, USDC, DOLA, USDE, WETH, lp];
        for (uint256 i; i < toks.length; i++) {
            assertEq(IERC20(toks[i]).balanceOf(address(h)), 0, "helper holds a token");
        }
    }

    // ------------------------------------------------------------------------------------------------------------

    function test_fork_preview_deploysTableImmutables_writesNoProgress() public {
        if (!_fork()) return;
        string memory path = _tmp("preview");
        (DeployUniswapHelperHarness s, address amp) = _deployHarness(true, path, false);
        s.run();

        assertTrue(s.deployedThisRun(), "deployed");
        UniswapHelper h = s.helper();
        assertGt(address(h).code.length, 0, "helper code");
        _assertTable(h);
        assertEq(h.pair(), address(0), "pair absent until Stage 4");
        assertEq(h.amPair(), amp, "helper resolves the AM pair the precondition required");
        assertFalse(vm.exists(path), "preview must not write the progress file");
    }

    function test_fork_deployedHelper_swapsThroughInForkPair() public {
        if (!_fork()) return;
        (DeployUniswapHelperHarness s,) = _deployHarness(true, _tmp("swap"), false);
        s.run();
        UniswapHelper h = s.helper();

        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        uint256 amt = 1000e6;
        deal(USDC, user, amt);

        // Before the pair exists, the helper cannot swap.
        vm.startPrank(user);
        IERC20(USDC).approve(address(h), amt);
        vm.expectRevert();
        h.swapToPhUSD(USDC, amt, 1, recipient, block.timestamp);
        vm.stopPrank();

        address lp = _createPair();
        assertEq(h.pair(), lp, "helper resolves the new pair");

        uint256 quote = h.quoteToPhUSD(USDC, amt);
        vm.prank(user);
        uint256 out = h.swapToPhUSD(USDC, amt, quote * 999 / 1000, recipient, block.timestamp);
        console2.log("1000 USDC -> phUSD via freshly deployed helper:", out);
        assertGt(out, 990e18, "~1000 phUSD out");
        assertEq(IERC20(PHUSD).balanceOf(recipient), out, "recipient got phUSD");
        _assertHelperEmpty(h, lp);

        // And back out to USDS.
        uint256 back = out / 2;
        uint256 quoteBack = h.quoteFromPhUSD(USDS, back);
        vm.startPrank(recipient);
        IERC20(PHUSD).approve(address(h), back);
        uint256 usdsOut = h.swapFromPhUSD(USDS, back, quoteBack * 999 / 1000, recipient, block.timestamp);
        vm.stopPrank();
        assertGt(usdsOut, 0, "USDS out");
        assertEq(IERC20(USDS).balanceOf(recipient), usdsOut, "recipient got USDS");
        _assertHelperEmpty(h, lp);
    }

    function test_fork_broadcastMode_writesProgress_rerunIsNoop_verifyPasses() public {
        if (!_fork()) return;
        string memory path = _tmp("broadcast");

        (DeployUniswapHelperHarness s, address amp) = _deployHarness(false, path, true);
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        address h = address(s.helper());
        _assertTable(UniswapHelper(payable(h)));

        // The shape scripts/patch-mainnet-addresses-uniswap-helper.js reads.
        assertTrue(vm.exists(path), "progress written");
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1, "chainId");
        assertEq(vm.parseJsonString(json, ".networkName"), "mainnet", "networkName");
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "completed", "status");
        assertEq(vm.parseJsonAddress(json, ".contracts.UniswapHelper.address"), h, "address");
        assertTrue(vm.parseJsonBool(json, ".contracts.UniswapHelper.deployed"), "deployed flag");

        // Re-run: idempotent, nothing deployed.
        DeployUniswapHelperHarness again = new DeployUniswapHelperHarness(false, path);
        again.setBookAmPair(amp);
        again.run();
        assertFalse(again.deployedThisRun(), "re-run must not deploy");
        assertEq(address(again.helper()), h, "re-run adopts the recorded helper");

        // Verifier: passes with the pair absent (Stage 4 pending) ...
        VerifyUniswapHelperHarness v = new VerifyUniswapHelperHarness(path);
        v.setBookAmPair(amp);
        v.run();
        // ... and again, quote smoke test included, once the pair exists.
        _createPair();
        v.run();

        vm.removeFile(path);
    }

    function test_fork_verify_rejectsMisconfiguredHelper() public {
        if (!_fork()) return;
        string memory path = _tmp("wrongfee");
        UniswapHelper wrong = new UniswapHelper(
            PHUSD,
            SUSDS,
            USDS,
            USDC,
            DOLA,
            USDE,
            WETH,
            SKY_PSM,
            V2_ROUTER,
            V3_ROUTER,
            V3_QUOTER,
            CURVE_DOLA,
            CURVE_USDE,
            ANTIMATTER,
            3000
        );
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"completed","contracts":{"UniswapHelper":{"address":"',
                vm.toString(address(wrong)),
                '","deployed":true}}}'
            )
        );
        VerifyUniswapHelperHarness v = new VerifyUniswapHelperHarness(path);
        vm.expectRevert(bytes("verify: v3Fee mismatch"));
        v.run();

        // The deploy refuses to adopt it too, rather than silently skipping.
        (DeployUniswapHelperHarness s,) = _deployHarness(true, path, false);
        vm.expectRevert(bytes("verify: v3Fee mismatch"));
        s.run();
        vm.removeFile(path);
    }

    function test_fork_deploy_abortsOnProgressAddressWithoutCode() public {
        if (!_fork()) return;
        string memory path = _tmp("nocode");
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"completed","contracts":{"UniswapHelper":{"address":"',
                vm.toString(makeAddr("neverLanded")),
                '","deployed":true}}}'
            )
        );
        (DeployUniswapHelperHarness s,) = _deployHarness(true, path, false);
        vm.expectRevert(
            bytes(
                "Progress file names a UniswapHelper with NO CODE - it was recorded in forge's local pass but never landed. Delete server/deployments/progress.uniswap-helper-am.1.json and re-run preview."
            )
        );
        s.run();
        vm.removeFile(path);
    }

    function test_fork_verify_failsWithNoHelper() public {
        if (!_fork()) return;
        VerifyUniswapHelperHarness v = new VerifyUniswapHelperHarness(_tmp("absent"));
        vm.expectRevert(
            bytes(
                "verify: no UniswapHelper address (no progress file and the address-book key is zero) - broadcast first"
            )
        );
        v.run();
    }
}

/**
 * @title UniswapHelperAfterAntimatterCutoverForkTest  (story 122, Script C)
 * @notice At a recent block (phUSD/sUSDS pair live, AM/sUSDS pair absent): the redeploy refuses to run before the
 *         Antimatter cutover (Script B), and after an in-fork Script B run it deploys, records into the NEW progress
 *         file and passes the verifier including the Antimatter checks and quote smoke.
 */
contract UniswapHelperAfterAntimatterCutoverForkTest is Test {
    uint256 constant FORK_BLOCK = 26_303_500;
    address constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    string constant TMP_PREFIX = "server/deployments/progress.uniswap-helper-am.1.forktest-";

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        return true;
    }

    function _tmp(string memory name) internal returns (string memory path) {
        path = string.concat(TMP_PREFIX, name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    function test_fork_cBeforeB_revertsOnPrecondition() public {
        if (!_fork()) return;
        assertEq(IUniswapV2FactoryCreate111(FACTORY).getPair(ANTIMATTER, SUSDS), address(0), "AM pair absent");
        DeployUniswapHelperHarness s = new DeployUniswapHelperHarness(true, _tmp("c-before-b"));
        // the stood-in book key is zero, exactly as mainnet-addresses.ts is before Script B is patched
        vm.expectRevert(
            bytes(
                "precondition: AntimatterSusdsPair is zero in mainnet-addresses.ts - run the Antimatter cutover (Script B) first"
            )
        );
        s.run();

        // A book key that names something the factory does not know is refused too.
        s.setBookAmPair(makeAddr("notThePair"));
        vm.expectRevert(
            bytes(
                "precondition: factory.getPair(AM, sUSDS) != book AntimatterSusdsPair - run the Antimatter cutover (Script B) first"
            )
        );
        s.run();
    }

    function test_fork_bThenC_deploysAndVerifies() public {
        if (!_fork()) return;
        // Script B in-fork (preview mode: OWNER prank, no progress file).
        CutoverAntimatterPoolHarness b = new CutoverAntimatterPoolHarness(true, _tmp("b"));
        b.run();
        address amp = b.amSusdsPair();
        assertTrue(amp != address(0), "Script B created the AM pair");

        // Script C in broadcast mode against a scratch progress file.
        string memory path = _tmp("c");
        DeployUniswapHelperHarness c = new DeployUniswapHelperHarness(false, path);
        c.setBookAmPair(amp);
        c.run();
        assertTrue(c.deployedThisRun(), "deployed");
        UniswapHelper h = c.helper();
        assertEq(h.amPair(), amp, "helper resolves Script B's pair");
        assertEq(h.antimatter(), ANTIMATTER, "antimatter");
        assertEq(vm.parseJsonAddress(vm.readFile(path), ".contracts.UniswapHelper.address"), address(h), "new progress");
        assertGt(h.quotePhUSDToAM(1000e18), 0, "AM quote");

        VerifyUniswapHelperHarness v = new VerifyUniswapHelperHarness(path);
        v.setBookAmPair(amp);
        v.run();
        vm.removeFile(path);
    }
}
