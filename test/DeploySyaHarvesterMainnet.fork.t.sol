// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {ICurveRouterNG} from "sya-harvester/interfaces/ICurveRouterNG.sol";
import {
    DeploySyaHarvesterMainnet,
    SyaHarvesterMainnetBase,
    IStableStakerV2ClaimGate
} from "../script/DeploySyaHarvesterMainnet.s.sol";
import {VerifySyaHarvester} from "../script/VerifySyaHarvester.s.sol";
import {ClaimUnblockState} from "../script/helpers/ClaimUnblockState.sol";

/// @dev Pins the mode and the progress path (never the process-wide PREVIEW_MODE env, never the real progress file).
contract DeploySyaHarvesterHarness is DeploySyaHarvesterMainnet {
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
}

/// @dev The fork block predates the broadcast: only the scratch progress file counts.
contract VerifySyaHarvesterHarness is VerifySyaHarvester {
    string internal progressPath;

    constructor(string memory progressPath_) {
        progressPath = progressPath_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookHarvester() internal pure override returns (address) {
        return address(0);
    }
}

/// @dev Exposes the pure route helpers and the claim-unblock reader for the no-RPC tests.
contract SyaHarvesterRouteHarness is SyaHarvesterMainnetBase {
    function cfg() public pure returns (Config memory c) {
        c.sya = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;
        c.usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        c.dola = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
        c.usde = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
        c.stableStakerV2 = 0xA6d3fc83C91B8319D219cEB12B46e3dfF064B58F;
        c.nftMinter = 0x39Af088408e815844c567037C157B31d48d2E10F;
    }

    function claimRecordedAt(string memory progress, string memory book) external view returns (bool) {
        return ClaimUnblockState.recordedAt(progress, book);
    }
}

/**
 * @title DeploySyaHarvesterMainnetRouteTest  (story 122, no RPC)
 * @notice The off-chain story-052 payload checker accepts exactly the shipped payloads and rejects every
 *         malformed shape - above all the gapped `[USDe, pool, crvUSD, 0, USDC, ...]` payload of audit ryv18m5.
 *         Also pins the expected config and the claim-unblock reader the cutover scripts now use.
 */
contract DeploySyaHarvesterMainnetRouteTest is Test {
    SyaHarvesterRouteHarness h;
    SyaHarvesterMainnetBase.Config c;

    function setUp() public {
        h = new SyaHarvesterRouteHarness();
        c = h.cfg();
    }

    function test_expectedConfig_matchesAddressBook() public {
        DeploySyaHarvesterMainnet s = new DeploySyaHarvesterMainnet();
        SyaHarvesterMainnetBase.Config memory b = s.expectedConfig();
        assertEq(b.sya, c.sya, "SYA");
        assertEq(b.usdc, c.usdc, "USDC");
        assertEq(b.dola, c.dola, "DOLA");
        assertEq(b.usde, c.usde, "USDe");
        assertEq(b.stableStakerV2, c.stableStakerV2, "StableStakerV2");
        assertEq(b.nftMinter, c.nftMinter, "NFTMinter");
    }

    function test_shippedPayloads_pass() public view {
        assertEq(h.checkRoutePayload(h.usdeRoute(c), c.usde, c.usdc), 2, "USDe 2 hops");
        assertEq(h.checkRoutePayload(h.dolaRoute(c), c.dola, c.usdc), 1, "DOLA 1 hop");
        // The reverse payloads the dry run sends pass too.
        assertEq(h.checkRoutePayload(h.reverseRoute(h.usdeRoute(c), c.usdc), c.usdc, c.usde), 2, "USDe reverse");
        assertEq(h.checkRoutePayload(h.reverseRoute(h.dolaRoute(c), c.usdc), c.usdc, c.dola), 1, "DOLA reverse");
    }

    function test_reverseRoute_swapsIndicesAndPath() public view {
        SyaHarvesterMainnetBase.Route memory r = h.reverseRoute(h.usdeRoute(c), c.usdc);
        assertEq(r.path[0], c.usdc);
        assertEq(r.path[1], h.POOL_CRVUSD_USDC());
        assertEq(r.path[2], h.CRVUSD());
        assertEq(r.path[3], h.POOL_USDE_CRVUSD());
        assertEq(r.path[4], c.usde);
        assertEq(r.path[5], address(0));
        assertEq(r.swapParams[0][0], 0, "USDC is coin0 of crvUSD/USDC");
        assertEq(r.swapParams[0][1], 1);
        assertEq(r.swapParams[0][3], 1, "pool_type kept");
        assertEq(r.swapParams[1][0], 1, "crvUSD is coin1 of USDe/crvUSD");
        assertEq(r.swapParams[1][1], 0);
        assertEq(r.swapParams[1][3], 10, "stableswap-ng kept");
        SyaHarvesterMainnetBase.Route memory d = h.reverseRoute(h.dolaRoute(c), c.usdc);
        assertEq(d.swapParams[0][0], 2);
        assertEq(d.swapParams[0][1], 0);
        assertEq(d.swapParams[0][2], 2, "exchange_underlying kept");
    }

    /// @dev THE audit ryv18m5 payload: `[USDe, pool, crvUSD, 0, USDC, ...]` - Router NG would stop at crvUSD.
    function test_gappedPayload_reverts() public {
        SyaHarvesterMainnetBase.Route memory r = h.usdeRoute(c);
        r.path[3] = address(0); // drop the crvUSD/USDC pool, keep USDC at path[4]
        vm.expectRevert(
            bytes(
                "route check: GAPPED route - non-zero path entry after the first empty pool slot (Router NG would stop early and deliver an intermediate token)"
            )
        );
        h.checkRoutePayload(r, c.usde, c.usdc);
    }

    function test_zeroIntermediate_reverts() public {
        SyaHarvesterMainnetBase.Route memory r = h.usdeRoute(c);
        r.path[2] = address(0);
        vm.expectRevert(bytes("route check: zero token inside the executed prefix"));
        h.checkRoutePayload(r, c.usde, c.usdc);
    }

    function test_wrongDeliveredToken_reverts() public {
        SyaHarvesterMainnetBase.Route memory r = h.usdeRoute(c);
        r.path[3] = address(0);
        r.path[4] = address(0); // ends at crvUSD
        vm.expectRevert(bytes("route check: path[2k] (the delivered token) != tokenOut"));
        h.checkRoutePayload(r, c.usde, c.usdc);
    }

    function test_swapType0And9_revert() public {
        SyaHarvesterMainnetBase.Route memory r = h.dolaRoute(c);
        r.swapParams[0][2] = 0;
        vm.expectRevert(bytes("route check: executed hop has swap_type 0"));
        h.checkRoutePayload(r, c.dola, c.usdc);
        r.swapParams[0][2] = 9;
        vm.expectRevert(bytes("route check: executed hop has swap_type 9 (rejected by Router NG v1.1)"));
        h.checkRoutePayload(r, c.dola, c.usdc);
    }

    function test_unexecutedRowOrPool_reverts() public {
        SyaHarvesterMainnetBase.Route memory r = h.dolaRoute(c);
        r.swapParams[1][0] = 1;
        vm.expectRevert(bytes("route check: unexecuted swapParams row is not zero"));
        h.checkRoutePayload(r, c.dola, c.usdc);
        r = h.dolaRoute(c);
        r.pools[3] = address(1);
        vm.expectRevert(bytes("route check: pools entry is not zero (no route here uses a zap)"));
        h.checkRoutePayload(r, c.dola, c.usdc);
    }

    function test_zeroHopRoute_reverts() public {
        SyaHarvesterMainnetBase.Route memory r = h.dolaRoute(c);
        r.path[1] = address(0);
        r.path[2] = address(0);
        r.swapParams[0] = [uint256(0), 0, 0, 0, 0];
        vm.expectRevert(bytes("route check: no executed hop (path[1] is zero)"));
        h.checkRoutePayload(r, c.dola, c.usdc);
    }

    function test_wrongStart_reverts() public {
        SyaHarvesterMainnetBase.Route memory r = h.dolaRoute(c);
        vm.expectRevert(bytes("route check: route registered for a different token"));
        h.checkRoutePayload(r, c.usde, c.usdc);
        r.token = c.usde;
        vm.expectRevert(bytes("route check: path[0] != tokenIn"));
        h.checkRoutePayload(r, c.usde, c.usdc);
    }

    // ---- ClaimUnblockState (the state-aware claimEnabled assertions in the V2 cutover scripts) ----

    string constant TMP = "server/deployments/claim-unblock.test-";

    function _write(string memory name, string memory body) internal returns (string memory path) {
        path = string.concat(TMP, name);
        vm.writeFile(path, body);
    }

    function test_claimUnblock_notRecordedByDefault() public {
        string memory book =
            _write("book-zero.ts", "x\n  SYAHarvester: \"0x0000000000000000000000000000000000000000\",\n");
        assertFalse(h.claimRecordedAt(string.concat(TMP, "absent.json"), book), "no progress + zero key");
        string memory p = _write("p-false.json", '{"claimEnabled":false}');
        assertFalse(h.claimRecordedAt(p, book), "progress says false");
        vm.removeFile(book);
        vm.removeFile(p);
    }

    function test_claimUnblock_recordedByProgressOrBook() public {
        string memory zeroBook =
            _write("book-zero2.ts", "x\n  SYAHarvester: \"0x0000000000000000000000000000000000000000\",\n");
        string memory p = _write("p-true.json", '{"claimEnabled":true}');
        assertTrue(h.claimRecordedAt(p, zeroBook), "progress records the claim enable");
        string memory book =
            _write("book-filled.ts", "x\n  SYAHarvester: \"0x1111111111111111111111111111111111111111\",\n");
        assertTrue(h.claimRecordedAt(string.concat(TMP, "absent.json"), book), "patched book key");
        vm.removeFile(zeroBook);
        vm.removeFile(p);
        vm.removeFile(book);
    }

    function test_claimUnblock_liveBookIsZeroUntilBroadcast() public view {
        // Until the human broadcasts Script A the real address book keeps the placeholder: false stays expected.
        assertFalse(
            ClaimUnblockState.bookHasSyaHarvester(ClaimUnblockState.ADDRESS_BOOK), "live SYAHarvester key is zero"
        );
    }
}

/**
 * @title DeploySyaHarvesterMainnetForkTest  (story 122)
 * @notice The deploy script's own logic against a mainnet fork (skipped without RPC_MAINNET): route safety in both
 *         directions, deployment and configuration, the harvest smoke, the claim unblock, resume, idempotency and
 *         the verifier.
 */
contract DeploySyaHarvesterMainnetForkTest is Test {
    /// @dev Recent block (2026-10-30): StableStakerV2 claims still closed, SYA has claimable yield.
    uint256 constant FORK_BLOCK = 26_303_500;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    string constant TMP_PREFIX = "server/deployments/progress.sya-harvester.1.forktest-";

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

    function _assertEndState(DeploySyaHarvesterMainnet s) internal view {
        SYAHarvester harvester = s.harvester();
        SyaHarvesterMainnetBase.Config memory c = s.expectedConfig();
        assertEq(harvester.owner(), OWNER, "owner");
        assertEq(address(harvester.sya()), c.sya, "sya");
        assertTrue(harvester.getRoute(c.usde).configured, "USDe route");
        assertTrue(harvester.getRoute(c.dola).configured, "DOLA route");
        assertFalse(harvester.getRoute(c.usdc).configured, "USDC unrouted");
        assertTrue(IStableStakerV2ClaimGate(c.stableStakerV2).claimEnabled(), "claims open");
    }

    function test_fork_preview_routeSafety_configures_smokes_enablesClaim() public {
        if (!_fork()) return;
        SyaHarvesterMainnetBase.Config memory c = new DeploySyaHarvesterMainnet().expectedConfig();
        assertFalse(IStableStakerV2ClaimGate(c.stableStakerV2).claimEnabled(), "claims closed at fork block");

        string memory path = _tmp("preview");
        DeploySyaHarvesterHarness s = new DeploySyaHarvesterHarness(true, path);
        s.run();

        assertTrue(s.deployedThisRun(), "deployed");
        assertEq(s.txCount(), 5, "deploy + 2 routes + ETH pool + claim enable");
        // Dry-run deltas (balance-based) were all within 3% of par in both directions.
        assertGe(s.dryUsdeToUsdc(), 970e6, "USDe -> USDC");
        assertGe(s.dryUsdcToUsde(), 970e18, "USDC -> USDe");
        assertGe(s.dryDolaToUsdc(), 970e6, "DOLA -> USDC");
        assertGe(s.dryUsdcToDola(), 970e18, "USDC -> DOLA");
        assertGt(s.smokeEthOut(), 0, "harvest smoke paid ETH");
        _assertEndState(s);
        assertFalse(vm.exists(path), "preview must not write the progress file");
    }

    function test_fork_broadcastMode_writesProgress_rerunIsNoop_verifyPasses() public {
        if (!_fork()) return;
        string memory path = _tmp("broadcast");
        DeploySyaHarvesterHarness s = new DeploySyaHarvesterHarness(false, path);
        s.run();
        _assertEndState(s);

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1, "chainId");
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "completed", "status");
        assertTrue(vm.parseJsonBool(json, ".claimEnabled"), "claimEnabled recorded");
        assertEq(vm.parseJsonAddress(json, ".contracts.SYAHarvester.address"), address(s.harvester()), "address");
        // The cutover scripts' state-aware assertion now accepts claimEnabled == true.
        assertTrue(ClaimUnblockState.progressRecordsClaimEnabled(path), "claim unblock recorded");

        DeploySyaHarvesterHarness again = new DeploySyaHarvesterHarness(false, path);
        again.run();
        assertFalse(again.deployedThisRun(), "re-run must not deploy");
        assertEq(again.txCount(), 0, "re-run sends nothing");
        assertEq(address(again.harvester()), address(s.harvester()), "re-run adopts the recorded harvester");

        new VerifySyaHarvesterHarness(path).run();
        vm.removeFile(path);
    }

    /// @dev A broadcast that died after the deploy and the USDe route: the resume adopts the harvester and sends
    ///      only the DOLA route, the ETH pool and the claim enable.
    function test_fork_resume_afterDeployAndOneRoute() public {
        if (!_fork()) return;
        string memory path = _tmp("resume");
        DeploySyaHarvesterHarness probe = new DeploySyaHarvesterHarness(true, _tmp("probe"));
        SyaHarvesterMainnetBase.Config memory c = probe.expectedConfig();
        SyaHarvesterMainnetBase.Route memory u = probe.usdeRoute(c);

        vm.startPrank(OWNER);
        SYAHarvester h = new SYAHarvester(
            OWNER,
            IPoolManager(probe.POOL_MANAGER()),
            IStableYieldAccumulator(c.sya),
            ICurveRouterNG(probe.CURVE_ROUTER_NG())
        );
        h.setRoute(u.token, u.path, u.swapParams, u.pools);
        vm.stopPrank();
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","claimEnabled":false,"deploymentStatus":"in_progress","contracts":{"SYAHarvester":{"address":"',
                vm.toString(address(h)),
                '","deployed":true}}}'
            )
        );

        DeploySyaHarvesterHarness s = new DeploySyaHarvesterHarness(false, path);
        s.run();
        assertFalse(s.deployedThisRun(), "resume must not redeploy");
        assertEq(address(s.harvester()), address(h), "adopted");
        assertEq(s.txCount(), 3, "DOLA route + ETH pool + claim enable only");
        _assertEndState(s);
        assertEq(vm.parseJsonString(vm.readFile(path), ".deploymentStatus"), "completed", "completed after resume");
        new VerifySyaHarvesterHarness(path).run();
        vm.removeFile(path);
    }

    function test_fork_deploy_abortsOnProgressAddressWithoutCode() public {
        if (!_fork()) return;
        string memory path = _tmp("nocode");
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"contracts":{"SYAHarvester":{"address":"', vm.toString(makeAddr("neverLanded")), '"}}}'
            )
        );
        DeploySyaHarvesterHarness s = new DeploySyaHarvesterHarness(true, path);
        vm.expectRevert(
            bytes(
                "Progress file names an SYAHarvester with NO CODE - recorded in forge's local pass but never landed. Delete server/deployments/progress.sya-harvester.1.json and re-run preview."
            )
        );
        s.run();
        vm.removeFile(path);
    }

    function test_fork_verify_failsBeforeBroadcast() public {
        if (!_fork()) return;
        VerifySyaHarvesterHarness v = new VerifySyaHarvesterHarness(_tmp("absent"));
        vm.expectRevert(
            bytes(
                "verify: no SYAHarvester address (no progress file and the address-book key is zero) - broadcast first"
            )
        );
        v.run();
    }

    /// @dev Router NG really does deliver the intermediate token on the gapped payload: the defence the off-chain
    ///      check and the balance-delta dry run exist for (audit ryv18m5). Proven on the fork, then reverted.
    function test_fork_gappedPayload_realRouterDeliversCrvUsd() public {
        if (!_fork()) return;
        DeploySyaHarvesterHarness probe = new DeploySyaHarvesterHarness(true, _tmp("gap"));
        SyaHarvesterMainnetBase.Config memory c = probe.expectedConfig();
        SyaHarvesterMainnetBase.Route memory r = probe.usdeRoute(c);
        r.path[3] = address(0);
        address who = makeAddr("gapped");
        deal(c.usde, who, 1000e18);
        vm.startPrank(who);
        IERC20Like(c.usde).approve(probe.CURVE_ROUTER_NG(), 1000e18);
        ICurveRouterNG(probe.CURVE_ROUTER_NG()).exchange(r.path, r.swapParams, 1000e18, 0, r.pools, who);
        vm.stopPrank();
        assertEq(IERC20Like(c.usdc).balanceOf(who), 0, "no USDC delivered");
        assertGt(IERC20Like(probe.CRVUSD()).balanceOf(who), 0, "crvUSD delivered instead");
    }
}

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
