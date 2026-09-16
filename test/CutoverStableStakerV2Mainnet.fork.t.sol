// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";
import {IAntimatter} from "stable-staker/interfaces/IAntimatter.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {
    CutoverStableStakerV2Mainnet,
    IPausableLike,
    IPauserRegistry,
    IPhUSDOwner
} from "../script/CutoverStableStakerV2Mainnet.s.sol";

/// @dev Exposes the internal phases of the mainnet cutover script so single phases can be driven.
contract CutoverStableStakerV2MainnetHarness is CutoverStableStakerV2Mainnet {
    /// Pinned: these fork tests only ever run the cutover in PREVIEW (never race the process-wide env).
    function _previewModeFromEnv() internal pure override returns (bool) {
        return true;
    }

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

    // ---- story 087: single phases as OWNER, and the replicated pieces of Phase 3 / Phase 7 ----
    function harnessPhase2AsOwner() external {
        vm.startPrank(OWNER);
        _phase2_antimatter();
        vm.stopPrank();
    }

    function harnessPhase3AsOwner() external {
        vm.startPrank(OWNER);
        _phase3_stakerV2();
        vm.stopPrank();
    }

    function harnessPhase4AsOwner() external {
        vm.startPrank(OWNER);
        _phase4_pools();
        vm.stopPrank();
    }

    function harnessPhase5AsOwner() external {
        vm.startPrank(OWNER);
        _phase5_mintRights();
        vm.stopPrank();
    }

    function harnessPhase6AsOwner() external {
        vm.startPrank(OWNER);
        _phase6_migration();
        vm.stopPrank();
    }

    function harnessPhase7AsOwner() external {
        vm.startPrank(OWNER);
        _phase7_finalize();
        vm.stopPrank();
    }

    function harnessPhase8() external view {
        _phase8_wiringAssertions();
    }

    /// Phase 3's CREATE only, byte-for-byte (so the test can step the pauser/pause txs one at a time).
    function harnessDeployV2Only() external {
        vm.prank(OWNER);
        v2 = new StableStakerV2(IAntimatter(address(antimatter)), OWNER);
    }

    /// Everything `_phase7_finalize` does BEFORE its pauser block, via the script's own helpers.
    function harnessPhase7Preamble() external {
        vm.startPrank(OWNER);
        for (uint256 i = 0; i < tokens.length; i++) {
            address ys = _strategyFor(tokens[i]);
            if (!_doneBufferRecipientV2(ys)) IYieldStrategy(ys).setSetAsideBufferRecipient(address(v2));
        }
        if (!_v1MintRevoked()) IPhUSDOwner(PHUSD).setMinter(STABLE_STAKER_V1, false);
        _retireV1("Phase7");
        vm.stopPrank();
    }

    function harnessResetTokens() external {
        delete tokens;
    }

    /// Stubbed on-chain ETH: `vm.deal` moves the LOCAL EVM, which is exactly what the production reader ignores.
    uint256 public stubbedOwnerEth;
    bool public stubOwnerEth;

    function setStubbedOwnerEth(uint256 wei_) external {
        stubbedOwnerEth = wei_;
        stubOwnerEth = true;
    }

    function _ownerEthOnChain() internal override returns (uint256) {
        if (stubOwnerEth) return stubbedOwnerEth;
        return super._ownerEthOnChain();
    }

    function harnessPreflight() external {
        _preflightOwnerEth();
    }

    function harnessOwnerEthOnChain() external returns (uint256) {
        return _ownerEthOnChain();
    }

    function harnessRequiredOwnerEth(uint256 price) external pure returns (uint256) {
        return _requiredOwnerEth(price);
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
 * @title CutoverStableStakerV2MainnetForkTest  (story 084, audit L-04 / L-03b; story 087, audit-33 L-05 / L-07)
 * @notice Reproduces the mid-run global-pause windows on a mainnet fork and proves them closed:
 *         Phase 1 unregisters V1 from the global Pauser BEFORE pausing it (084); Phase 7 unpauses V2 BEFORE
 *         registering it (087). The breaker is probed after EVERY pause-state-touching transaction of Phases
 *         1, 3 and 7, and preview runs a snapshot-isolated EYE-funded `Pauser.pause()` after every phase.
 *         Also: Phase 7 halt-point resume convergence and the OWNER ETH preflight (087).
 *         Fork tests skip cleanly when RPC_MAINNET is unset (CI runs plain `forge test` with no RPC); the
 *         source guards at the bottom run without RPC.
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
        // Phase 0 is the tolerated BROKEN_BY_V1 case (not recorded); every strict stage must pass.
        assertEq(h.globalPauseStageCount(), 8, "strict stages after-phase1 .. after-phase8");
        for (uint256 i = 0; i < 8; i++) {
            assertEq(h.globalPauseStagesPassed(i), string.concat("after-phase", vm.toString(i + 1)));
        }
    }

    /// Full preview run() passes with the GLOBAL_PAUSE simulation succeeding at phase0 and after EVERY phase 1..8
    /// (story 087 class check: story 084 sampled only phase0 / after-phase1 / after-phase8).
    function test_fork_fullPreview_globalPauseAfterEveryPhase() public {
        if (!_fork()) return;
        h.run();
        assertEq(h.globalPauseStageCount(), 9, "phase0 + after-phase1 .. after-phase8");
        assertEq(h.globalPauseStagesPassed(0), "phase0");
        for (uint256 i = 1; i <= 8; i++) {
            assertEq(h.globalPauseStagesPassed(i), string.concat("after-phase", vm.toString(i)));
        }
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

    // =====================================================================
    //  Story 087 (audit-33 L-05): transaction-granular breaker probe
    // =====================================================================

    bytes4 constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));

    /// Probe the permissionless breaker inside a snapshot, so the probe never leaves anything paused.
    function _breakerLive(string memory step) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        bytes memory ret;
        (ok, ret) = _eyeFundedPause();
        if (ok) _assertAllRegistrantsPaused();
        vm.revertToState(snap);
        console.log(string.concat("BREAKER|", step, ok ? "|LIVE" : "|DEAD"));
    }

    function _toPhase6() internal {
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();
        h.harnessPhase2AsOwner();
        h.harnessPhase3AsOwner();
        h.harnessPhase4AsOwner();
        h.harnessPhase5AsOwner();
        h.harnessPhase6AsOwner();
    }

    /// Phase 7's pauser block, one state-changing call at a time, in the script's order (pinned to the source
    /// by `test_phase7SourceOrder_unpauseBeforeRegister`). Returns after `stopAfter` steps (1..5).
    function _phase7PauserSteps(uint256 stopAfter, bool probe) internal {
        address v2 = address(h.v2());
        address am = address(h.antimatter());
        vm.prank(OWNER);
        IPausableLike(v2).setPauser(PAUSER);
        if (probe) assertTrue(_breakerLive("P7-after-V2.setPauser(Pauser)"), "P7 step 1");
        if (stopAfter == 1) return;
        vm.prank(OWNER);
        IPausableLike(v2).unpause();
        if (probe) assertTrue(_breakerLive("P7-after-V2.unpause()"), "P7 step 2");
        if (stopAfter == 2) return;
        assertFalse(IPausableLike(v2).paused(), "V2 is UNPAUSED when it is registered");
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).register(v2);
        if (probe) assertTrue(_breakerLive("P7-after-register(V2)"), "P7 step 3");
        if (stopAfter == 3) return;
        vm.prank(OWNER);
        IPausableLike(am).setPauser(PAUSER);
        if (probe) assertTrue(_breakerLive("P7-after-Antimatter.setPauser(Pauser)"), "P7 step 4");
        if (stopAfter == 4) return;
        assertFalse(IPausableLike(am).paused(), "Antimatter is UNPAUSED when it is registered");
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).register(am);
        if (probe) assertTrue(_breakerLive("P7-after-register(Antimatter)"), "P7 step 5");
    }

    /// CONTROL: the pre-087 Phase 7 order (register V2 while paused, unpause last) bricks the breaker with
    /// `EnforcedPause()` - the audit-33 L-05 window this story closes.
    function test_fork_phase7_oldOrder_bricksBreaker() public {
        if (!_fork()) return;
        _toPhase6();
        h.harnessPhase7Preamble();
        address v2 = address(h.v2());
        vm.startPrank(OWNER);
        IPausableLike(v2).setPauser(PAUSER);
        IPauserRegistry(PAUSER).register(v2);
        vm.stopPrank();
        (bool ok, bytes memory ret) = _eyeFundedPause();
        assertFalse(ok, "old order: registered + paused V2 bricks Pauser.pause()");
        assertEq(ret, abi.encodeWithSelector(ENFORCED_PAUSE), "EnforcedPause from V2.pause()");
    }

    /// After every state-changing call of the FIXED Phase 7 the breaker is live; the real Phase 7 then skips
    /// every step and the real Phase 8 passes on the result.
    function test_fork_phase7_breakerLiveAfterEveryStep() public {
        if (!_fork()) return;
        _toPhase6();
        assertTrue(_breakerLive("P7-start"), "P7 start");
        h.harnessPhase7Preamble();
        assertTrue(_breakerLive("P7-after-preamble"), "P7 preamble");
        _phase7PauserSteps(5, true);
        h.harnessPhase7AsOwner(); // real Phase 7: every step already satisfied
        h.harnessPhase8();
        assertTrue(_breakerLive("P7-after-real-phase7"), "end state");
    }

    /// Every pause-state-touching call in Phases 1, 3 and 7 (the list `test_pauseStateCallSites_enumerated`
    /// pins), probed one transaction at a time. The ONLY dead point is the single tx between
    /// `V1.setPauser(OWNER)` and `Pauser.unregister(V1)`.
    function test_fork_breakerProbe_everyPauseStateTx_phases1_3_7() public {
        if (!_fork()) return;
        h.harnessPhase0(true);
        uint256 dead;
        assertTrue(_breakerLive("phase0"), "live state");

        // ---- Phase 1 (`_retireV1`) ----
        vm.prank(OWNER);
        IPausableLike(V1).setPauser(OWNER);
        bool afterSetPauser = _breakerLive("P1-after-V1.setPauser(OWNER)");
        assertFalse(afterSetPauser, "the one forced window: registered V1 whose pauser is OWNER");
        if (!afterSetPauser) dead++;
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).unregister(V1);
        assertTrue(_breakerLive("P1-after-unregister(V1)"), "P1 unregister");
        vm.prank(OWNER);
        IPausableLike(V1).pause();
        assertTrue(_breakerLive("P1-after-V1.pause()"), "P1 pause");
        h.harnessPhase1AsOwner(); // real Phase 1 on the stepped state: every gate skips, read-backs pass

        h.harnessPhase2AsOwner();
        assertTrue(_breakerLive("after-phase2"), "phase 2");

        // ---- Phase 3: V2 is paused while UNREGISTERED, so its pause cannot reach the breaker ----
        h.harnessDeployV2Only();
        address v2 = address(h.v2());
        assertTrue(_breakerLive("P3-after-V2-deploy"), "P3 deploy");
        vm.prank(OWNER);
        IPausableLike(v2).setPauser(OWNER);
        assertTrue(_breakerLive("P3-after-V2.setPauser(OWNER)"), "P3 setPauser");
        vm.prank(OWNER);
        IPausableLike(v2).pause();
        assertFalse(IPauserRegistry(PAUSER).isRegistered(v2), "V2 is not registered when Phase 3 pauses it");
        assertTrue(_breakerLive("P3-after-V2.pause()"), "P3 pause");
        h.harnessPhase3AsOwner(); // real Phase 3: pause step skips, identity read-backs pass

        h.harnessPhase4AsOwner();
        assertTrue(_breakerLive("after-phase4"), "phase 4");
        h.harnessPhase5AsOwner();
        assertTrue(_breakerLive("after-phase5"), "phase 5");
        h.harnessPhase6AsOwner();
        assertTrue(_breakerLive("after-phase6"), "phase 6");

        // ---- Phase 7 ----
        h.harnessPhase7Preamble();
        _phase7PauserSteps(5, true);
        h.harnessPhase7AsOwner();
        h.harnessPhase8();
        assertTrue(_breakerLive("after-phase8"), "end state");
        assertEq(dead, 1, "exactly one dead point in the whole session");
    }

    // =====================================================================
    //  Story 087 (audit-33 L-05): resume convergence from each new Phase 7 halt point
    // =====================================================================

    /// Halt after `haltAfter` Phase 7 pauser steps: (1) setPauser(PAUSER) only, (2) + unpause, (3) + register(V2).
    /// The breaker is live at the halt; a PREVIEW run() over the halted state passes (its phase0 simulation does
    /// not revert); and a broadcast-shaped resume (the real phases as OWNER) converges to the Phase 8 end state.
    function _haltedPhase7ResumeConverges(uint256 haltAfter) internal {
        _toPhase6();
        h.harnessPhase7Preamble();
        _phase7PauserSteps(haltAfter, false);
        assertTrue(_breakerLive(string.concat("HALT-P7-after-step-", vm.toString(haltAfter))), "breaker live at halt");
        if (haltAfter == 1) assertTrue(IPausableLike(address(h.v2())).paused(), "setup: halted with V2 still paused");

        uint256 snap = vm.snapshotState();
        h.harnessResetTokens();
        h.run(); // PREVIEW over the halted state
        assertEq(h.globalPauseStagesPassed(0), "phase0", "phase0 simulation passed on the halted state");
        vm.revertToState(snap);

        h.harnessResetTokens();
        _toPhase6(); // resume leg: every step state-gated
        h.harnessPhase7AsOwner();
        h.harnessPhase8();
        assertFalse(IPausableLike(address(h.v2())).paused(), "V2 unpaused after resume");
        assertTrue(_breakerLive("HALT-P7-resumed"), "breaker live after resume");
    }

    function test_fork_phase7Halt_afterSetPauser_resumeConverges() public {
        if (!_fork()) return;
        _haltedPhase7ResumeConverges(1);
    }

    function test_fork_phase7Halt_afterUnpause_resumeConverges() public {
        if (!_fork()) return;
        _haltedPhase7ResumeConverges(2);
    }

    function test_fork_phase7Halt_afterRegisterV2_resumeConverges() public {
        if (!_fork()) return;
        _haltedPhase7ResumeConverges(3);
    }

    // =====================================================================
    //  Story 088: Phase 7 one-tx COVERAGE gaps (unpaused, pauser == Pauser, unregistered) and their remedy
    // =====================================================================

    /// Halt after step 2 (V2 unpaused, not yet registered): the global pause SUCCEEDS but MISSES V2, while every
    /// strategy V2 routes through is paused (why nothing is exposed). OWNER's direct pause() reverts onlyPauser;
    /// setPauser(OWNER) then pause() works. A resume afterwards re-runs Phase 7 and UNPAUSES V2 (resume hazard).
    function test_fork_phase7Gap_V2_afterUnpause_globalPauseMissesV2_remedyWorks() public {
        if (!_fork()) return;
        _toPhase6();
        h.harnessPhase7Preamble();
        _phase7PauserSteps(2, false);
        address v2 = address(h.v2());
        assertEq(IPausableLike(v2).pauser(), PAUSER, "setup: V2 pauser is already the Pauser");
        assertFalse(IPauserRegistry(PAUSER).isRegistered(v2), "setup: V2 not registered");

        uint256 snap = vm.snapshotState();
        (bool ok,) = _eyeFundedPause();
        assertTrue(ok, "global pause does not revert at the gap");
        assertFalse(IPausableLike(v2).paused(), "GAP: global pause leaves V2 unpaused");
        assertTrue(IPausableLike(h.YS_DOLA()).paused(), "strategy DOLA paused by the global pause");
        assertTrue(IPausableLike(h.YS_USDC()).paused(), "strategy USDC paused by the global pause");
        assertTrue(IPausableLike(h.YS_USDE()).paused(), "strategy USDE paused by the global pause");
        vm.revertToState(snap);

        vm.prank(OWNER);
        vm.expectRevert(bytes("StableStaker: only pauser"));
        IPausableLike(v2).pause();

        snap = vm.snapshotState();
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).register(v2);
        (ok,) = _eyeFundedPause();
        assertTrue(ok, "alternative remedy: register then global pause");
        assertTrue(IPausableLike(v2).paused(), "alternative remedy pauses V2");
        vm.revertToState(snap);

        vm.startPrank(OWNER);
        IPausableLike(v2).setPauser(OWNER);
        IPausableLike(v2).pause();
        vm.stopPrank();
        assertTrue(IPausableLike(v2).paused(), "remedy: V2 paused");

        // Resume hazard: the finalized marker is cleared, so the real Phase 7 re-runs and unpauses V2.
        h.harnessPhase7AsOwner();
        assertFalse(IPausableLike(v2).paused(), "HAZARD: a resume after the remedy unpauses V2");
    }

    /// Halt after step 4 (Antimatter pauser == Pauser, not yet registered): same gap and same remedy.
    function test_fork_phase7Gap_Antimatter_afterSetPauser_globalPauseMissesIt_remedyWorks() public {
        if (!_fork()) return;
        _toPhase6();
        h.harnessPhase7Preamble();
        _phase7PauserSteps(4, false);
        address am = address(h.antimatter());
        assertEq(IPausableLike(am).pauser(), PAUSER, "setup: Antimatter pauser is already the Pauser");
        assertFalse(IPauserRegistry(PAUSER).isRegistered(am), "setup: Antimatter not registered");

        uint256 snap = vm.snapshotState();
        (bool ok,) = _eyeFundedPause();
        assertTrue(ok, "global pause does not revert at the gap");
        assertFalse(IPausableLike(am).paused(), "GAP: global pause leaves Antimatter unpaused");
        assertTrue(IPausableLike(address(h.v2())).paused(), "registered V2 is paused by the global pause");
        vm.revertToState(snap);

        vm.prank(OWNER);
        vm.expectRevert(bytes4(keccak256("OnlyPauser()")));
        IPausableLike(am).pause();

        snap = vm.snapshotState();
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).register(am);
        (ok,) = _eyeFundedPause();
        assertTrue(ok, "alternative remedy: register then global pause");
        assertTrue(IPausableLike(am).paused(), "alternative remedy pauses Antimatter");
        vm.revertToState(snap);

        vm.startPrank(OWNER);
        IPausableLike(am).setPauser(OWNER);
        IPausableLike(am).pause();
        vm.stopPrank();
        assertTrue(IPausableLike(am).paused(), "remedy: Antimatter paused");
    }

    // =====================================================================
    //  Story 087 (audit-33 L-07): OWNER ETH preflight
    // =====================================================================

    /// All env-dependent scenarios live in ONE test: `vm.setEnv` is process-wide and forge runs tests in parallel.
    function test_fork_ethPreflight_scenarios() public {
        if (!_fork()) return;
        uint256 at03 = h.harnessRequiredOwnerEth(300_000_000);
        uint256 at035 = h.harnessRequiredOwnerEth(350_000_000);

        // (0) The reader is the CHAIN's balance, not the local EVM's: forge pre-funds the script sender, so a
        // vm.deal here must NOT move what the preflight sees (story 087).
        uint256 onChain = h.harnessOwnerEthOnChain();
        vm.deal(OWNER, 500 ether);
        assertEq(h.harnessOwnerEthOnChain(), onChain, "preflight must read eth_getBalance, not OWNER.balance");
        assertTrue(onChain != OWNER.balance, "setup: the local EVM balance differs from the chain's");

        // (1) Broadcast-mode preflight reverts on a low OWNER balance, naming need / price / have.
        vm.setEnv("CUTOVER_GAS_PRICE_WEI", "300000000");
        h.setStubbedOwnerEth(at03 - 1);
        vm.expectRevert(
            bytes(
                string.concat(
                    "Preflight: OWNER ETH below cutover gas budget - need ", vm.toString(at03),
                    " wei at 300000000 wei/gas, have ", vm.toString(at03 - 1), ". Top up OWNER before signing."
                )
            )
        );
        h.harnessPreflight();

        // (2) Passes with exactly the budget.
        h.setStubbedOwnerEth(at03);
        h.harnessPreflight();

        // (3) The env price is honoured: the 0.3 gwei budget is short at 0.35 gwei, the 0.35 gwei budget passes.
        vm.setEnv("CUTOVER_GAS_PRICE_WEI", "350000000");
        vm.expectRevert();
        h.harnessPreflight();
        h.setStubbedOwnerEth(at035);
        h.harnessPreflight();

        // (4) A node gas price above the pinned one WARNS but does not inflate the requirement: every transaction
        // is signed at the pinned --with-gas-price, so that is what the budget is priced at (story 071 is a
        // separate hazard, logged).
        vm.txGasPrice(5 gwei);
        h.harnessPreflight();
        vm.txGasPrice(0);

        // (5) Loud revert when the env var is unset, however much ETH OWNER holds.
        vm.setEnv("CUTOVER_GAS_PRICE_WEI", "");
        h.setStubbedOwnerEth(100 ether);
        vm.expectRevert(
            bytes(
                "Preflight: CUTOVER_GAS_PRICE_WEI is unset - run via npm run stable-staker-v2-cutover:broadcast (it exports the price it passes to --with-gas-price)"
            )
        );
        h.harnessPreflight();

        // (6) Preview never reverts on ETH: OWNER at zero on-chain balance, env unset, full preview run() passes.
        h.setStubbedOwnerEth(0);
        h.run();
    }

    /// The production reader is the raw RPC call, and `OWNER.balance` is never used for the gate.
    function test_ownerEthReader_usesEthGetBalanceNotEvmBalance() public view {
        string memory src = vm.readFile(SCRIPT_SRC);
        assertTrue(_indexOf(src, "vm.rpc(\"eth_getBalance\"", 0) != type(uint256).max, "reads eth_getBalance over RPC");
        assertEq(_count(src, "OWNER.balance"), 0, "OWNER.balance must not be used: forge pre-funds the script sender");
    }

    function test_ethBudget_math() public {
        CutoverStableStakerV2MainnetHarness x = new CutoverStableStakerV2MainnetHarness();
        assertEq(x.CUTOVER_GAS_BUDGET(), 22_000_000, "budget");
        assertGe(x.CUTOVER_GAS_BUDGET(), 18_317_077 + 3_383_096, "covers rehearsal gasUsed + largest late gas limit");
        assertEq(x.harnessRequiredOwnerEth(300_000_000), 7_920_000_000_000_000, "0.3 gwei -> 0.00792 ETH");
        assertEq(x.harnessRequiredOwnerEth(350_000_000), 9_240_000_000_000_000, "0.35 gwei -> 0.00924 ETH");
    }

    // =====================================================================
    //  Story 087: source guards (no RPC)
    // =====================================================================

    string constant SCRIPT_SRC = "script/CutoverStableStakerV2Mainnet.s.sol";

    function _indexOf(string memory hay, string memory needle, uint256 from) internal pure returns (uint256) {
        bytes memory a = bytes(hay);
        bytes memory b = bytes(needle);
        if (b.length == 0 || b.length > a.length) return type(uint256).max;
        for (uint256 i = from; i <= a.length - b.length; i++) {
            bool m = true;
            for (uint256 j = 0; j < b.length; j++) {
                if (a[i + j] != b[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return i;
        }
        return type(uint256).max;
    }

    function _count(string memory hay, string memory needle) internal pure returns (uint256 n) {
        uint256 i = _indexOf(hay, needle, 0);
        while (i != type(uint256).max) {
            n++;
            i = _indexOf(hay, needle, i + 1);
        }
    }

    /// The replica in `_phase7PauserSteps` matches the SOURCE order of `_phase7_finalize`.
    function test_phase7SourceOrder_unpauseBeforeRegister() public view {
        string memory src = vm.readFile(SCRIPT_SRC);
        uint256 body = _indexOf(src, "function _phase7_finalize()", 0);
        assertTrue(body != type(uint256).max, "Phase 7 body");
        string[5] memory steps = [
            "if (v2.pauser() != PAUSER) v2.setPauser(PAUSER);",
            "if (!_doneV2Unpaused()) v2.unpause();",
            "IPauserRegistry(PAUSER).register(address(v2));",
            "if (antimatter.pauser() != PAUSER) antimatter.setPauser(PAUSER);",
            "IPauserRegistry(PAUSER).register(address(antimatter));"
        ];
        uint256 last = body;
        for (uint256 i = 0; i < steps.length; i++) {
            uint256 at = _indexOf(src, steps[i], body);
            assertTrue(at != type(uint256).max, string.concat("step missing: ", steps[i]));
            assertGt(at, last, string.concat("step out of order: ", steps[i]));
            assertEq(_count(src, steps[i]), 1, string.concat("step appears more than once: ", steps[i]));
            last = at;
        }
        uint256 end = _indexOf(src, "function _phase8_wiringAssertions()", body);
        assertLt(last, end, "all five steps are inside _phase7_finalize");
    }

    /// Class check: the pause-state-touching call sites are exactly what the tx-granular probe covers
    /// (Phase 1: 3, Phase 3: 2, Phase 7: 5), grepped by receiver. A new call site on these receivers fails this
    /// test until the probe is extended; the preview stage after every phase catches any other receiver.
    function test_pauseStateCallSites_enumerated() public view {
        string memory src = vm.readFile(SCRIPT_SRC);
        assertEq(_count(src, "v1p.setPauser(OWNER);"), 1, "P1 setPauser");
        assertEq(_count(src, "IPauserRegistry(PAUSER).unregister("), 1, "P1 unregister");
        assertEq(_count(src, "v1p.pause();"), 1, "P1 pause");
        assertEq(_count(src, "v2.setPauser(OWNER);"), 1, "P3 setPauser");
        assertEq(_count(src, "v2.pause();"), 1, "P3 pause");
        assertEq(_count(src, "v2.setPauser(PAUSER);"), 1, "P7 setPauser");
        assertEq(_count(src, "v2.unpause();"), 1, "P7 unpause");
        assertEq(_count(src, "IPauserRegistry(PAUSER).register("), 2, "P7 register x2");
        assertEq(_count(src, "antimatter.setPauser(PAUSER);"), 1, "P7 Antimatter setPauser");
    }

    /// L-07: the preflight is called from run() only in broadcast mode and never from Phase 0 (the verifier runs
    /// Phase 0); the verifier never calls it; :broadcast feeds one env var to both forge and the script.
    function test_ethPreflight_wiring() public view {
        string memory src = vm.readFile(SCRIPT_SRC);
        assertEq(_count(src, "_preflightOwnerEth();"), 1, "exactly one call site");
        uint256 call = _indexOf(src, "_preflightOwnerEth();", 0);
        uint256 broadcast = _indexOf(src, "vm.startBroadcast();", 0);
        uint256 elseBranch = _indexOf(src, "} else {", _indexOf(src, "vm.startPrank(OWNER);", 0));
        assertGt(call, elseBranch, "preflight is in the non-preview branch");
        assertLt(call, broadcast, "preflight precedes startBroadcast");
        uint256 p0 = _indexOf(src, "function _phase0_preconditions()", 0);
        uint256 p0End = _indexOf(src, "function _phase1_pauseV1()", p0);
        uint256 inP0 = _indexOf(src, "_preflightOwnerEth", p0);
        assertTrue(inP0 > p0End, "Phase 0 never calls the preflight");

        string memory ver = vm.readFile("script/VerifyStableStakerV2Cutover.s.sol");
        assertEq(_count(ver, "_preflightOwnerEth"), 0, "verifier never calls the preflight");

        string memory pkg = vm.readFile("package.json");
        assertTrue(
            _indexOf(pkg, "export CUTOVER_GAS_PRICE_WEI=${CUTOVER_GAS_PRICE_WEI:-300000000} &&", 0) != type(uint256).max,
            ":broadcast exports the gas price env var"
        );
        assertTrue(
            _indexOf(pkg, "--with-gas-price $CUTOVER_GAS_PRICE_WEI --gas-estimate-multiplier 200", 0) != type(uint256).max,
            ":broadcast feeds the SAME env var to --with-gas-price"
        );
        assertEq(_count(pkg, "--with-gas-price 0.3gwei"), 0, "no literal gas price left beside the env var");
    }
}
