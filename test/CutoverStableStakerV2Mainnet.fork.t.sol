// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    CutoverStableStakerV2Mainnet,
    IPausableLike,
    IPauserRegistry
} from "../script/CutoverStableStakerV2Mainnet.s.sol";

/// @dev Exposes the internal phases of the mainnet cutover script so single phases can be driven.
contract CutoverStableStakerV2MainnetHarness is CutoverStableStakerV2Mainnet {
    function harnessPhase0(bool preview) external {
        isPreview = preview;
        _loadProgressFile();
        _phase0_preconditions();
    }

    function harnessPhase1AsOwner() external {
        vm.startPrank(OWNER);
        _phase1_pauseV1();
        vm.stopPrank();
    }

    function harnessSimulateGlobalPause(string memory stage, bool tolerateV1Only) external {
        _assertGlobalPauseWorks(stage, tolerateV1Only);
    }
}

/// @dev A registrant that is already paused: its pause() reverts, so it bricks the Pauser loop.
contract PausedDummyPausable {
    address public immutable pauser;
    bool public paused = true;

    constructor(address p) {
        pauser = p;
    }

    function pause() external {
        require(msg.sender == pauser, "dummy: only pauser");
        require(!paused, "dummy: already paused");
        paused = true;
    }

    function unpause() external {
        require(msg.sender == pauser, "dummy: only pauser");
        paused = false;
    }
}

/**
 * @title CutoverStableStakerV2MainnetForkTest  (story 084, audit L-04 / L-03b)
 * @notice Reproduces the mid-run global-pause window on a mainnet fork and proves it closed:
 *         Phase 1 now unregisters V1 from the global Pauser BEFORE pausing it, and preview runs a
 *         snapshot-isolated EYE-funded `Pauser.pause()` at three stages.
 *         Skips cleanly when RPC_MAINNET is unset (CI runs plain `forge test` with no RPC).
 */
contract CutoverStableStakerV2MainnetForkTest is Test {
    uint256 constant FORK_BLOCK = 25_978_784;

    CutoverStableStakerV2MainnetHarness h;
    address OWNER;
    address V1;
    address PAUSER;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.setEnv("PREVIEW_MODE", "true");
        h = new CutoverStableStakerV2MainnetHarness();
        OWNER = h.OWNER();
        V1 = h.STABLE_STAKER_V1();
        PAUSER = h.PAUSER();
        return true;
    }

    /// Permissionless EYE-funded pause from a fresh actor. Returns whether Pauser.pause() succeeded.
    function _eyeFundedPause() internal returns (bool ok, bytes memory ret) {
        IPauserRegistry p = IPauserRegistry(PAUSER);
        address eye = p.eyeToken();
        uint256 burn = p.eyeBurnAmount();
        address actor = makeAddr("test-eye-pauser");
        deal(eye, actor, burn, false);
        vm.prank(actor);
        IERC20(eye).approve(PAUSER, burn);
        vm.prank(actor);
        (ok, ret) = PAUSER.call(abi.encodeWithSignature("pause()"));
    }

    function _assertAllRegistrantsPaused() internal view {
        address[] memory r = IPauserRegistry(PAUSER).getPausableContracts();
        assertGt(r.length, 0, "registry empty");
        for (uint256 i = 0; i < r.length; i++) {
            assertTrue(IPausableLike(r[i]).paused(), "registrant not paused by global pause");
        }
    }

    /// CONTROL: the OLD Phase 1 ordering (setPauser(OWNER) + pause, V1 left registered) bricks the breaker.
    function test_fork_oldOrdering_bricksGlobalPause() public {
        if (!_fork()) return;
        assertTrue(IPauserRegistry(PAUSER).isRegistered(V1), "setup: V1 registered at fork block");
        vm.startPrank(OWNER);
        IPausableLike(V1).setPauser(OWNER);
        IPausableLike(V1).pause();
        vm.stopPrank();

        (bool ok, bytes memory ret) = _eyeFundedPause();
        assertFalse(ok, "old ordering: global pause must REVERT (the L-04 window)");
        assertEq(ret, abi.encodeWithSignature("Error(string)", "StableStaker: only pauser"), "revert reason");
    }

    /// After Phase 0 + the NEW Phase 1 as OWNER, the EYE-funded Pauser.pause() SUCCEEDS.
    function test_fork_windowClosed_afterPhase1() public {
        if (!_fork()) return;
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();

        assertFalse(IPauserRegistry(PAUSER).isRegistered(V1), "Phase 1 must unregister V1");
        assertTrue(IPausableLike(V1).paused(), "Phase 1 must pause V1");
        assertEq(IPausableLike(V1).pauser(), OWNER, "V1 pauser OWNER");

        (bool ok,) = _eyeFundedPause();
        assertTrue(ok, "global pause must SUCCEED once V1 is unregistered");
        _assertAllRegistrantsPaused();
    }

    /// The script's own simulation passes after Phase 1, and is snapshot-isolated (nothing stays paused).
    function test_fork_simulatedPause_isSnapshotIsolated() public {
        if (!_fork()) return;
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();
        h.harnessSimulateGlobalPause("after-phase1", false);
        assertEq(h.globalPauseStageCount(), 1, "stage recorded");
        address[] memory r = IPauserRegistry(PAUSER).getPausableContracts();
        for (uint256 i = 0; i < r.length; i++) {
            assertFalse(IPausableLike(r[i]).paused(), "simulation leaked a pause out of its snapshot");
        }
    }

    /// Resume from "V1 paused, pauser OWNER, still registered" converges: run() passes, V1 ends unregistered.
    function test_fork_resume_pausedButRegistered_converges() public {
        if (!_fork()) return;
        vm.startPrank(OWNER);
        IPausableLike(V1).setPauser(OWNER);
        IPausableLike(V1).pause();
        vm.stopPrank();
        assertTrue(IPauserRegistry(PAUSER).isRegistered(V1), "setup: V1 still registered");

        h.run();

        assertFalse(IPauserRegistry(PAUSER).isRegistered(V1), "V1 must end unregistered");
        assertTrue(IPausableLike(V1).paused(), "V1 must end paused");
        // Phase 0 is the tolerated BROKEN_BY_V1 case (not recorded); the two strict stages must pass.
        assertEq(h.globalPauseStageCount(), 2, "strict stages after-phase1 + after-phase8");
        assertEq(h.globalPauseStagesPassed(0), "after-phase1");
        assertEq(h.globalPauseStagesPassed(1), "after-phase8");
    }

    /// Full preview run() passes with all three GLOBAL_PAUSE stages succeeding.
    function test_fork_fullPreview_threeGlobalPauseStages() public {
        if (!_fork()) return;
        h.run();
        assertEq(h.globalPauseStageCount(), 3, "three GLOBAL_PAUSE stages");
        assertEq(h.globalPauseStagesPassed(0), "phase0");
        assertEq(h.globalPauseStagesPassed(1), "after-phase1");
        assertEq(h.globalPauseStagesPassed(2), "after-phase8");
        assertFalse(IPauserRegistry(PAUSER).isRegistered(V1), "V1 unregistered");
        assertTrue(IPauserRegistry(PAUSER).isRegistered(address(h.v2())), "V2 registered");
    }

    /// NEGATIVE: a paused registrant bricks the breaker; the Phase 0 simulation reverts naming it.
    function test_fork_pausedRegistrant_phase0SimulationRevertsNamingIt() public {
        if (!_fork()) return;
        PausedDummyPausable dummy = new PausedDummyPausable(PAUSER);
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).register(address(dummy));

        vm.expectRevert(
            bytes(
                string.concat(
                    "globalPause(phase0): Pauser.pause() does not pause every registrant; first failing registrant: ",
                    vm.toString(address(dummy))
                )
            )
        );
        h.run();
    }

    /// NEGATIVE (strict stage): a non-V1 broken registrant is never tolerated, even with tolerateV1Only.
    function test_fork_toleranceIsV1Only() public {
        if (!_fork()) return;
        vm.startPrank(OWNER);
        IPausableLike(V1).setPauser(OWNER);
        IPausableLike(V1).pause();
        vm.stopPrank();
        h.harnessPhase0(true);
        // V1-only breakage is tolerated at phase0 (no revert, nothing recorded) ...
        h.harnessSimulateGlobalPause("phase0", true);
        assertEq(h.globalPauseStageCount(), 0, "tolerated stage is not recorded as passed");
        // ... but not at a strict stage.
        vm.expectRevert(
            bytes(
                string.concat(
                    "globalPause(strict): Pauser.pause() does not pause every registrant; first failing registrant: ",
                    vm.toString(V1)
                )
            )
        );
        h.harnessSimulateGlobalPause("strict", false);

        // And a second broken (non-V1) registrant defeats the tolerance.
        PausedDummyPausable dummy = new PausedDummyPausable(PAUSER);
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).register(address(dummy));
        vm.expectRevert();
        h.harnessSimulateGlobalPause("phase0", true);
    }
}
