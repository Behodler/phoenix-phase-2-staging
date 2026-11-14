// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {IOldSYA} from "../script/helpers/SyaGateOffMainnetBase.sol";
import {ReplaceSYAGateOffHarness} from "./ReplaceSYAGateOffMainnet.fork.t.sol";
import {DeployNudgeDiscountHarness} from "./helpers/NudgeDiscountHarnesses.sol";

interface IStrat134 {
    function authorizedWithdrawers(address) external view returns (bool);
    function setWithdrawer(address, bool) external;
}

interface IPaused134 {
    function paused() external view returns (bool);
}

/**
 * @title ReplaceSYAGateOffCompletionGateForkTest  (story 134, audit pps56m1 / pps56l4)
 * @notice Audit run 56's guard-gap PoCs (G1-G6c), ported INVERTED: on the COMPLETED progress file with the SYA
 *         adopted, every re-run that would send a transaction refuses, naming the step, before anything is sent -
 *         in PREVIEW and in broadcast mode - and the deliberate change survives. A PENDING (interrupted) run is not
 *         gated: it resumes, and story 133's value check still refuses a set-and-different value.
 *
 *         Runs at the audit's block 26_408_795 (sya-gate-off broadcast and completed, 119 not yet broadcast).
 *         Skipped without RPC_MAINNET. The real progress files and the address book are only ever READ.
 *
 *         Temp progress files: every test body runs through `_inTmp`, which removes the temp copies AFTER the body
 *         whether it passed or failed (a try/finally via an external self-call), then re-raises any failure.
 */
contract ReplaceSYAGateOffCompletionGateForkTest is Test {
    uint256 constant FORK_BLOCK = 26_408_795;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant LIVE_SYA = 0x9d69c68F354575B95c1ebf7E87DB85BF3BFF2cE8;
    address constant LIVE_HARVESTER = 0xbB0D5e0C7bb621df8Db65133D3DF625D04F0F7E3;
    address constant RETIRED_SYA = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;
    address constant OLD_MINTER = 0x068395556b8c43eDf257DC54D109EA5910aE15c7;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant YS_USDC = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83;
    string constant REAL_PROGRESS = "server/deployments/progress.sya-gate-off.1.json";
    string constant TMP_PREFIX = "server/deployments/progress.sya-gate-off.1.forktest-s134-";
    string constant TMP_NUDGE_PREFIX = "server/deployments/progress.nudge-discount.1.forktest-s134-";
    string constant COMPLETED_POINTER =
        ": sya-gate-off has completed (progress deploymentStatus == completed), so a re-run must send nothing (pps56m1). To finish a run that was wrongly marked completed, see runbook docs/runbooks/sya-gate-off-mainnet.md";
    string constant VALUE_POINTER =
        "value check: a re-run must not roll back a later change (pps55m1). See runbook docs/runbooks/sya-gate-off-mainnet.md";

    StableYieldAccumulator sya = StableYieldAccumulator(LIVE_SYA);
    SYAHarvester harv = SYAHarvester(payable(LIVE_HARVESTER));
    string internal tmpProgress;
    string internal tmpNudge;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    // ============================================================
    // Temp-file plumbing (try/finally)
    // ============================================================

    /// @dev Copies the REAL completed progress file to a per-test temp path (suites run tests in parallel), runs
    ///      `body` as an external self-call, ALWAYS removes the temp files, then re-raises the body's failure.
    function _inTmp(string memory name, bool pending, bytes memory body) internal {
        tmpProgress = string.concat(TMP_PREFIX, name, ".json");
        tmpNudge = string.concat(TMP_NUDGE_PREFIX, name, ".json");
        _cleanup();
        vm.writeFile(tmpProgress, vm.readFile(REAL_PROGRESS));
        if (pending) vm.writeJson("\"pending\"", tmpProgress, ".deploymentStatus");
        (bool ok, bytes memory err) = address(this).call(body);
        _cleanup();
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
    }

    function _cleanup() internal {
        if (vm.exists(tmpProgress)) vm.removeFile(tmpProgress);
        if (vm.exists(tmpNudge)) vm.removeFile(tmpNudge);
    }

    function _harness(bool preview) internal returns (ReplaceSYAGateOffHarness) {
        return new ReplaceSYAGateOffHarness(preview, tmpProgress, LIVE_SYA, LIVE_HARVESTER);
    }

    function _gated(string memory step) internal pure returns (bytes memory) {
        return bytes(string.concat("re-run guard: refusing step ", step, COMPLETED_POINTER));
    }

    /// @dev Both modes refuse with exactly `reason`. A revert in run() means forge would broadcast nothing.
    function _expectGatedBothModes(bytes memory reason) internal {
        ReplaceSYAGateOffHarness p = _harness(true);
        vm.expectRevert(reason);
        p.run();
        ReplaceSYAGateOffHarness b = _harness(false);
        vm.expectRevert(reason);
        b.run();
    }

    function _stagePost119() internal returns (address newMinter) {
        DeployNudgeDiscountHarness cutover = new DeployNudgeDiscountHarness(false, tmpNudge, address(0));
        cutover.run();
        newMinter = address(cutover.minter());
        assertEq(sya.nudge(), newMinter, "pre: 119 repointed the live SYA");
        assertTrue(IPaused134(OLD_MINTER).paused(), "pre: old minter paused by 119");
    }

    // ============================================================
    // Control: a completed re-run with nothing to change is still a 0-tx no-op
    // ============================================================

    function test_fork_completed_noChange_isNoop_previewAndBroadcast() public {
        _inTmp("noop", false, abi.encodeCall(this.body_completed_noChange_isNoop, ()));
    }

    function body_completed_noChange_isNoop() external {
        ReplaceSYAGateOffHarness p = _harness(true);
        p.run();
        assertFalse(p.deployedSyaThisRun(), "adopted");
        assertEq(p.txCount(), 0, "preview: nothing sent");
        ReplaceSYAGateOffHarness b = _harness(false);
        b.run();
        assertFalse(b.deployedSyaThisRun(), "adopted");
        assertEq(b.txCount(), 0, "broadcast mode: nothing sent");
    }

    // ============================================================
    // G1 inverted (pps56m1): post-119 disarm (split 0 + nudge 0) -> refused, nudge and split stay 0
    // ============================================================

    function test_fork_G1_post119Disarm_rerun_refused_previewAndBroadcast() public {
        _inTmp("g1", false, abi.encodeCall(this.body_G1, ()));
    }

    function body_G1() external {
        _stagePost119();
        vm.startPrank(OWNER);
        sya.setNudgeSplit(0);
        sya.setNudgeAddress(address(0));
        vm.stopPrank();
        _expectGatedBothModes(_gated("3.4 setNudgeAddress"));
        assertEq(sya.nudge(), address(0), "nudge stays cleared (never the paused old minter)");
        assertEq(sya.nudgeSplit(), 0, "nudgeSplit stays 0 (never re-armed)");
        assertTrue(sya.nudge() != OLD_MINTER, "never rolled back to the paused old minter");
    }

    // ============================================================
    // pps56l4 inverted: the retunes the value check cannot see
    // ============================================================

    /// G2: nudgeSplit disarmed to 0 (pre-119 state at this block).
    function test_fork_G2_nudgeSplitZero_refused() public {
        _inTmp("g2", false, abi.encodeCall(this.body_G2, ()));
    }

    function body_G2() external {
        vm.prank(OWNER);
        sya.setNudgeSplit(0);
        _expectGatedBothModes(_gated("3.4 setNudgeSplit"));
        assertEq(sya.nudgeSplit(), 0, "split stays 0");
    }

    /// G3: discount reset to 0.
    function test_fork_G3_discountZero_refused() public {
        _inTmp("g3", false, abi.encodeCall(this.body_G3, ()));
    }

    function body_G3() external {
        vm.prank(OWNER);
        sya.setDiscountRate(0);
        _expectGatedBothModes(_gated("3.6 setDiscountRate"));
        assertEq(sya.getDiscountRate(), 0, "discount stays 0");
    }

    /// G4: approvePhlimbo(0) on the live SYA.
    function test_fork_G4_phlimboAllowanceZero_refused() public {
        _inTmp("g4", false, abi.encodeCall(this.body_G4, ()));
    }

    function body_G4() external {
        address ph = sya.phlimbo();
        vm.prank(OWNER);
        sya.approvePhlimbo(0);
        _expectGatedBothModes(_gated("3.3 approvePhlimbo"));
        assertEq(IERC20(USDC).allowance(LIVE_SYA, ph), 0, "allowance stays 0");
    }

    /// G5: a strategy's withdrawer right revoked from the live SYA (step 4).
    function test_fork_G5_revokedWithdrawer_refused() public {
        _inTmp("g5", false, abi.encodeCall(this.body_G5, ()));
    }

    function body_G5() external {
        vm.prank(OWNER);
        IStrat134(YS_USDC).setWithdrawer(LIVE_SYA, false);
        _expectGatedBothModes(_gated("4 setWithdrawer(newSYA, true)"));
        assertFalse(IStrat134(YS_USDC).authorizedWithdrawers(LIVE_SYA), "withdrawer stays revoked");
    }

    /// G6a: harvester DOLA route retuned (step 6).
    function test_fork_G6a_retunedDolaRoute_refused() public {
        _inTmp("g6a", false, abi.encodeCall(this.body_G6a, ()));
    }

    function body_G6a() external {
        SYAHarvester.CurveRoute memory orig = harv.getRoute(DOLA);
        uint256 origPoolType = orig.swapParams[0][3];
        uint256[5][5] memory sp = orig.swapParams;
        sp[0][3] = origPoolType + 1;
        vm.prank(OWNER);
        harv.setRoute(DOLA, orig.path, sp, orig.pools);
        _expectGatedBothModes(_gated("6 setRoute(DOLA)"));
        assertEq(harv.getRoute(DOLA).swapParams[0][3], origPoolType + 1, "retune kept");
    }

    /// G6b: harvester DOLA route cleared (step 6).
    function test_fork_G6b_clearedDolaRoute_refused() public {
        _inTmp("g6b", false, abi.encodeCall(this.body_G6b, ()));
    }

    function body_G6b() external {
        vm.prank(OWNER);
        harv.clearRoute(DOLA);
        _expectGatedBothModes(_gated("6 setRoute(DOLA)"));
        assertFalse(harv.getRoute(DOLA).configured, "route stays cleared");
    }

    /// G6c: harvester ETH pool retuned (step 6).
    function test_fork_G6c_retunedEthPool_refused() public {
        _inTmp("g6c", false, abi.encodeCall(this.body_G6c, ()));
    }

    function body_G6c() external {
        PoolKey memory k = harv.getEthPool();
        k.fee = 500;
        k.tickSpacing = 10;
        vm.prank(OWNER);
        harv.setEthPool(k);
        _expectGatedBothModes(_gated("6 setEthPool"));
        assertEq(uint256(harv.getEthPool().fee), 500, "ETH pool retune kept");
    }

    // ============================================================
    // PENDING resume: not gated; the story-133 value check still guards it
    // ============================================================

    /// A pending run with a value still at its default resumes and writes it: the gate does not fire.
    function test_fork_pending_resume_notGated() public {
        _inTmp("pendingResume", true, abi.encodeCall(this.body_pending_resume_notGated, ()));
    }

    function body_pending_resume_notGated() external {
        uint256 mirror = IOldSYA(RETIRED_SYA).nudgeSplit();
        assertGt(mirror, 0, "pre: mirrored split is non-zero");
        vm.prank(OWNER);
        sya.setNudgeSplit(0); // as if the interrupted run had not reached 3.4 setNudgeSplit yet
        ReplaceSYAGateOffHarness b = _harness(false);
        b.run();
        assertFalse(b.deployedSyaThisRun(), "adopted");
        assertEq(b.txCount(), 1, "resume sent exactly the one missing write");
        assertEq(sya.nudgeSplit(), mirror, "resume filled the default value in");
    }

    /// A pending run resumed after a later set-and-different change (119's repoint) is refused by the value check.
    function test_fork_pending_resume_valueCheckStillRefuses() public {
        _inTmp("pendingValueCheck", true, abi.encodeCall(this.body_pending_resume_valueCheck, ()));
    }

    function body_pending_resume_valueCheck() external {
        address newMinter = _stagePost119();
        bytes memory reason = bytes(
            string.concat(
                "re-run guard: refusing step 3.4 setNudgeAddress on the adopted SYA: live ",
                vm.toString(newMinter),
                " != target ",
                vm.toString(OLD_MINTER),
                ". ",
                VALUE_POINTER
            )
        );
        ReplaceSYAGateOffHarness p = _harness(true);
        vm.expectRevert(reason);
        p.run();
        ReplaceSYAGateOffHarness b = _harness(false);
        vm.expectRevert(reason);
        b.run();
        assertEq(sya.nudge(), newMinter, "119 repoint kept");
    }
}
