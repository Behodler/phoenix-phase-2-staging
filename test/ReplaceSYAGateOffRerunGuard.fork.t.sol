// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {ReplaceSYAGateOffMainnet} from "../script/ReplaceSYAGateOffMainnet.s.sol";
import {IOldSYA} from "../script/helpers/SyaGateOffMainnetBase.sol";
import {ReplaceSYAGateOffHarness} from "./ReplaceSYAGateOffMainnet.fork.t.sol";
import {DeployNudgeDiscountHarness} from "./helpers/NudgeDiscountHarnesses.sol";

/// @dev The audit PoC's own runner (pps55m1, `SyaGateOffRerunM01`), ported verbatim: PREVIEW, sender OWNER, and the
///      REAL completed progress file + REAL address book (both only READ: preview writes nothing).
contract SyaGateOffRerunPoC is ReplaceSYAGateOffMainnet {
    function _previewModeFromEnv() internal pure override returns (bool) {
        return true;
    }

    function _sender() internal pure override returns (address) {
        return OWNER;
    }
}

interface IOldMinterGuard133 {
    function paused() external view returns (bool);
}

/**
 * @title ReplaceSYAGateOffRerunGuardForkTest  (story 133, audit pps55m1)
 * @notice A re-run of sya-gate-off against the ADOPTED live SYA `0x9d69...2cE8` refuses, in PREVIEW and in broadcast
 *         mode, to overwrite any value that is set and differs from its target - headline: story 119's nudge repoint,
 *         which the run would otherwise roll back to the paused old minter. With nothing retuned, the re-run is still
 *         a no-op. Fresh-run mirroring and interrupted-run resume stay covered by ReplaceSYAGateOffMainnet.fork.t.sol.
 *         Skipped without RPC_MAINNET. Never writes the real progress files or the address book.
 */
contract ReplaceSYAGateOffRerunGuardForkTest is Test {
    /// @dev The audit PoC's block: sya-gate-off broadcast and completed, 119 not yet broadcast.
    uint256 constant FORK_BLOCK = 26_407_007;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant LIVE_SYA = 0x9d69c68F354575B95c1ebf7E87DB85BF3BFF2cE8;
    address constant LIVE_HARVESTER = 0xbB0D5e0C7bb621df8Db65133D3DF625D04F0F7E3;
    address constant RETIRED_SYA = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;
    address constant OLD_MINTER = 0x068395556b8c43eDf257DC54D109EA5910aE15c7;
    address constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    string constant REAL_PROGRESS = "server/deployments/progress.sya-gate-off.1.json";
    string constant TMP_PREFIX = "server/deployments/progress.sya-gate-off.1.forktest-s133-";
    string constant TMP_NUDGE_PREFIX = "server/deployments/progress.nudge-discount.1.forktest-s133-";
    string constant POINTER =
        "sya-gate-off is complete; a re-run must not roll back a later change (pps55m1). See runbook docs/runbooks/sya-gate-off-mainnet.md";

    StableYieldAccumulator sya = StableYieldAccumulator(LIVE_SYA);
    string internal tmpProgress;
    string internal tmpNudgeProgress;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    /// @dev Per-test temp paths (suites run tests in parallel). The sya-gate-off one is a COPY of the real completed
    ///      progress file, for the harness; the real file is only ever read.
    function _useTmp(string memory name) internal {
        tmpProgress = string.concat(TMP_PREFIX, name, ".json");
        tmpNudgeProgress = string.concat(TMP_NUDGE_PREFIX, name, ".json");
        if (vm.exists(tmpProgress)) vm.removeFile(tmpProgress);
        vm.writeFile(tmpProgress, vm.readFile(REAL_PROGRESS));
        if (vm.exists(tmpNudgeProgress)) vm.removeFile(tmpNudgeProgress);
    }

    function _cleanup() internal {
        if (vm.exists(tmpProgress)) vm.removeFile(tmpProgress);
        if (vm.exists(tmpNudgeProgress)) vm.removeFile(tmpNudgeProgress);
    }

    function _harness(bool preview) internal returns (ReplaceSYAGateOffHarness) {
        return new ReplaceSYAGateOffHarness(preview, tmpProgress, LIVE_SYA, LIVE_HARVESTER);
    }

    function _refusal(string memory step, string memory live, string memory target)
        internal
        pure
        returns (bytes memory)
    {
        return bytes(
            string.concat(
                "re-run guard: refusing step ",
                step,
                " on the adopted SYA: live ",
                live,
                " != target ",
                target,
                ". ",
                POINTER
            )
        );
    }

    /// @dev Story 119's cutover through its own harness (broadcast-mode logic, OWNER prank, temp progress file).
    function _stagePost119() internal returns (address newMinter) {
        DeployNudgeDiscountHarness cutover = new DeployNudgeDiscountHarness(false, tmpNudgeProgress, address(0));
        cutover.run();
        newMinter = address(cutover.minter());
        assertEq(sya.nudge(), newMinter, "precondition: 119 repointed the live SYA to the new minter");
        assertEq(IOldSYA(RETIRED_SYA).nudge(), OLD_MINTER, "precondition: retired SYA left on the old minter");
        assertTrue(IOldMinterGuard133(OLD_MINTER).paused(), "precondition: 119 paused the old minter");
    }

    // ---------------- baseline: nothing retuned -> the re-run is still a no-op ----------------

    function test_fork_rerun_noRetune_isNoop_previewAndBroadcast() public {
        _useTmp("rerun_noRetune_isNoop_previewAndBroadcast");
        assertEq(sya.nudge(), IOldSYA(RETIRED_SYA).nudge(), "live nudge == mirror before 119");
        ReplaceSYAGateOffHarness p = _harness(true);
        p.run();
        assertFalse(p.deployedSyaThisRun(), "adopted");
        assertEq(p.txCount(), 0, "preview re-run sends nothing");
        ReplaceSYAGateOffHarness b = _harness(false);
        b.run();
        assertFalse(b.deployedSyaThisRun(), "adopted");
        assertEq(b.txCount(), 0, "broadcast-mode re-run sends nothing");
        _cleanup();
    }

    // ---------------- pps55m1: the audit PoC fails closed ----------------

    /// @dev The PoC scenario exactly: 119 cutover, then the PoC's own runner (preview, real progress file, real book).
    ///      Before story 133 this succeeded and left SYA.nudge() == OLD_MINTER.
    function test_fork_pps55m1_poc_rerunAfter119_refuses() public {
        _useTmp("pps55m1_poc_rerunAfter119_refuses");
        address newMinter = _stagePost119();
        SyaGateOffRerunPoC poc = new SyaGateOffRerunPoC();
        vm.expectRevert(_refusal("3.4 setNudgeAddress", vm.toString(newMinter), vm.toString(OLD_MINTER)));
        poc.run();
        assertEq(sya.nudge(), newMinter, "live SYA nudge still the new minter");
        assertTrue(sya.nudge() != OLD_MINTER, "never rolled back to the paused old minter");
        _cleanup();
    }

    function test_fork_rerunAfter119_refuses_preview() public {
        _useTmp("rerunAfter119_refuses_preview");
        address newMinter = _stagePost119();
        ReplaceSYAGateOffHarness r = _harness(true);
        vm.expectRevert(_refusal("3.4 setNudgeAddress", vm.toString(newMinter), vm.toString(OLD_MINTER)));
        r.run();
        assertEq(sya.nudge(), newMinter, "live SYA nudge still the new minter");
        _cleanup();
    }

    function test_fork_rerunAfter119_refuses_broadcastMode() public {
        _useTmp("rerunAfter119_refuses_broadcastMode");
        address newMinter = _stagePost119();
        ReplaceSYAGateOffHarness r = _harness(false);
        vm.expectRevert(_refusal("3.4 setNudgeAddress", vm.toString(newMinter), vm.toString(OLD_MINTER)));
        r.run();
        assertEq(sya.nudge(), newMinter, "live SYA nudge still the new minter");
        assertEq(vm.readFile(tmpProgress), vm.readFile(REAL_PROGRESS), "progress copy untouched");
        _cleanup();
    }

    // ---------------- retunes on the adopted SYA: each refused by name, in both modes ----------------

    function _expectRefusedBothModes(bytes memory reason) internal {
        ReplaceSYAGateOffHarness p = _harness(true);
        vm.expectRevert(reason);
        p.run();
        ReplaceSYAGateOffHarness b = _harness(false);
        vm.expectRevert(reason);
        b.run();
    }

    function test_fork_retunedNudgeSplit_refuses() public {
        _useTmp("retunedNudgeSplit_refuses");
        uint256 mirror = IOldSYA(RETIRED_SYA).nudgeSplit();
        uint256 retuned = mirror == 30 ? 40 : 30;
        vm.prank(OWNER);
        sya.setNudgeSplit(retuned);
        _expectRefusedBothModes(_refusal("3.4 setNudgeSplit", vm.toString(retuned), vm.toString(mirror)));
        assertEq(sya.nudgeSplit(), retuned, "retune kept");
        _cleanup();
    }

    function test_fork_retunedNudgeStreamer_refuses() public {
        _useTmp("retunedNudgeStreamer_refuses");
        address mirror = IOldSYA(RETIRED_SYA).nudgeStreamer();
        address retuned = makeAddr("otherStreamer");
        vm.prank(OWNER);
        sya.setNudgeStreamer(retuned);
        _expectRefusedBothModes(_refusal("3.4 setNudgeStreamer", vm.toString(retuned), vm.toString(mirror)));
        assertEq(sya.nudgeStreamer(), retuned, "retune kept");
        _cleanup();
    }

    function test_fork_retunedDiscountRate_refuses() public {
        _useTmp("retunedDiscountRate_refuses");
        vm.prank(OWNER);
        sya.setDiscountRate(3000);
        _expectRefusedBothModes(_refusal("3.6 setDiscountRate", "3000", "100"));
        assertEq(sya.getDiscountRate(), 3000, "retune kept");
        _cleanup();
    }

    function test_fork_retunedPhlimbo_refuses() public {
        _useTmp("retunedPhlimbo_refuses");
        address mirror = IOldSYA(RETIRED_SYA).phlimbo();
        address retuned = makeAddr("otherPhlimbo");
        vm.prank(OWNER);
        sya.setPhlimbo(retuned);
        _expectRefusedBothModes(_refusal("3.3 setPhlimbo", vm.toString(retuned), vm.toString(mirror)));
        _cleanup();
    }

    function test_fork_retunedPauser_refuses() public {
        _useTmp("retunedPauser_refuses");
        address retuned = makeAddr("otherPauser");
        vm.prank(OWNER);
        sya.setPauser(retuned);
        _expectRefusedBothModes(_refusal("3.7 setPauser", vm.toString(retuned), vm.toString(PAUSER_V2)));
        _cleanup();
    }

    function test_fork_retunedTokenConfig_refuses() public {
        _useTmp("retunedTokenConfig_refuses");
        vm.prank(OWNER);
        sya.setTokenConfig(DOLA, 18, 2e18);
        _expectRefusedBothModes(
            _refusal(
                "3.1 setTokenConfig(DOLA)",
                "decimals 18 rate 2000000000000000000",
                "decimals 18 rate 1000000000000000000"
            )
        );
        _cleanup();
    }
}
