// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";
import {IAntimatter} from "stable-staker/interfaces/IAntimatter.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {
    CutoverStableStakerV2Mainnet,
    IPausableLike,
    IPauserRegistry,
    IPhUSDOwner,
    ISourceDolaStrategy,
    ISyaStrategyList
} from "../script/CutoverStableStakerV2Mainnet.s.sol";
import {PhusdStableMinter} from "@phUSDMinter/PhusdStableMinter.sol";
import {InitiateDolaStrategyWithdrawalHarness} from "./InitiateDolaStrategyWithdrawal.fork.t.sol";

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

    /// Story 092: Phase 0 WITHOUT the minter withdrawal-window preflight - ONLY for the V1-exit-vs-pending-withdrawal
    /// cases (a)-(c), which must run Phase 6 inside the 6h waiting period. Production never calls the half.
    function harnessPhase0ReadChecksOnly(bool preview) external {
        isPreview = preview;
        _loadProgressFile();
        _phase0_readChecks();
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

    function harnessPhase3bAsOwner() external {
        vm.startPrank(OWNER);
        _phase3b_sdolaStrategy();
        vm.stopPrank();
    }

    /// Phase 3b's CREATE only, byte-for-byte (so the test can step the pauser/register txs one at a time).
    function harnessDeploySdolaStrategyOnly() external {
        vm.prank(OWNER);
        sdolaStrategy = new ERC4626YieldStrategy(OWNER, DOLA, SDOLA);
    }

    /// Story 091: simulate a resume whose progress file does not name the sDOLA strategy.
    function harnessForgetSdolaStrategy() external {
        sdolaStrategy = ERC4626YieldStrategy(address(0));
    }

    function harnessDestinationStrategyFor(address t) external view returns (address) {
        return _destinationStrategyFor(t);
    }

    function harnessSourceStrategyFor(address t) external pure returns (address) {
        return _sourceStrategyFor(t);
    }

    function harnessPerUserLossBpsFor(address t) external view returns (uint256) {
        return _perUserLossBpsFor(t);
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

    // ---- story 092: Phase 6b whole and by sub-step ----
    function harnessPhase6bAsOwner() external {
        vm.startPrank(OWNER);
        _phase6b_minterSyaRetireSource();
        vm.stopPrank();
    }

    function harnessMinterRecordAndDisableAsOwner() external {
        vm.startPrank(OWNER);
        _minterRecordConfigAndDisable();
        vm.stopPrank();
    }

    function harnessMinterExecuteAsOwner() external {
        vm.startPrank(OWNER);
        _minterExecuteWithdrawal();
        vm.stopPrank();
    }

    function harnessMinterReseedAsOwner() external {
        vm.startPrank(OWNER);
        _minterReseedSdola();
        vm.stopPrank();
    }

    function harnessMinterRegisterAsOwner() external {
        vm.startPrank(OWNER);
        _minterRegisterSdola();
        vm.stopPrank();
    }

    function harnessSyaRepointAsOwner() external {
        vm.startPrank(OWNER);
        _syaRepointDola();
        vm.stopPrank();
    }

    /// A resume whose progress file lost the execution record (and R).
    function harnessForgetMinterExecRecord() external {
        minterExecRecorded = false;
        minterRecoveredRecorded = false;
        minterRecovered = 0;
    }

    // ---- story 094: the broadcast leg ends after the minter execute (audit-35 L-09) ----
    /// Forces the BROADCAST leg-end rule while the harness stays in preview (OWNER prank, progress file never written).
    bool public forceBroadcastLegEnd;

    function harnessForceBroadcastLegEnd(bool on) external {
        forceBroadcastLegEnd = on;
    }

    function _legEndsAfterExecute() internal view override returns (bool) {
        return forceBroadcastLegEnd || super._legEndsAfterExecute();
    }

    /// The progress file of a real leg 1 carries the LOCAL-pass R, which can differ from the mined one.
    function harnessSetRecordedRecovered(uint256 r) external {
        minterRecovered = r;
        minterRecoveredRecorded = true;
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
            address ys = _destinationStrategyFor(tokens[i]);
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

    /// @dev Story 092: every full-cutover test now needs the minter's DOLA totalWithdrawal initiated (story 090's script)
    ///      and the clock inside its execution window, exactly as the mainnet runbook orders it.
    ///      TIME IS MOVED BY AGEING `initiatedAt`, NOT BY `vm.warp`: the minter's execute redeems enough autoDOLA to hit
    ///      Tokemak's debt path, whose Chainlink feeds are frozen at the fork block and revert `InvalidDataReturned()` as
    ///      stale after an hours-long warp (on mainnet they keep updating). The strategy only compares `block.timestamp`
    ///      with `initiatedAt`, so rewinding `initiatedAt` by N seconds is the same contract state as waiting N seconds.
    function _fork() internal returns (bool) {
        if (!_forkNoInitiate()) return false;
        _initiateMinterWithdrawal();
        _ageWithdrawal(6 hours + 60);
        return true;
    }

    function _forkNoInitiate() internal returns (bool) {
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

    /// @dev Storage, not a local: via_ir folds a `block.timestamp` local into reads after a warp (story 090 note).
    uint256 initiatedAt;

    /// Story 090's initiate script itself (preview harness: OWNER prank), not a hand-written copy of its call.
    function _initiateMinterWithdrawal() internal {
        InitiateDolaStrategyWithdrawalHarness init = new InitiateDolaStrategyWithdrawalHarness();
        init.run();
        (initiatedAt,,) = ISourceDolaStrategy(YS_DOLA_SOURCE).withdrawalStates(DOLA_T, MINTER);
        assertGt(initiatedAt, 0, "setup: minter DOLA withdrawal initiated");
    }

    function _warpTo(uint256 ts) internal {
        vm.warp(ts);
    }

    /// @dev Rewrites the minter's `withdrawalStates(DOLA, minter).initiatedAt` to `block.timestamp - secondsAgo` (see
    ///      `_fork`). The slot is discovered with `vm.record` on the public getter, then read back through the getter.
    function _ageWithdrawal(uint256 secondsAgo) internal {
        vm.record();
        ISourceDolaStrategy(YS_DOLA_SOURCE).withdrawalStates(DOLA_T, MINTER);
        (bytes32[] memory reads,) = vm.accesses(YS_DOLA_SOURCE);
        uint256 target = block.timestamp - secondsAgo;
        bool done;
        for (uint256 i = 0; i < reads.length && !done; i++) {
            if (uint256(vm.load(YS_DOLA_SOURCE, reads[i])) != initiatedAt) continue;
            vm.store(YS_DOLA_SOURCE, reads[i], bytes32(target));
            (uint256 at,,) = ISourceDolaStrategy(YS_DOLA_SOURCE).withdrawalStates(DOLA_T, MINTER);
            if (at == target) done = true;
            else vm.store(YS_DOLA_SOURCE, reads[i], bytes32(initiatedAt));
        }
        require(done, "test setup: initiatedAt slot not found");
        initiatedAt = target;
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
        string[10] memory expected = _strictStages();
        assertEq(h.globalPauseStageCount(), 10, "strict stages after-phase1 .. after-phase8 incl. after-phase3b / after-phase6b");
        for (uint256 i = 0; i < 10; i++) {
            assertEq(h.globalPauseStagesPassed(i), expected[i]);
        }
    }

    /// Full preview run() passes with the GLOBAL_PAUSE simulation succeeding at phase0 and after EVERY phase 1..8
    /// (story 087 class check: story 084 sampled only phase0 / after-phase1 / after-phase8).
    /// Strict stages in run() order. Story 091 adds after-phase3b (the sDOLA strategy registration).
    function _strictStages() internal pure returns (string[10] memory) {
        return [
            "after-phase1",
            "after-phase2",
            "after-phase3",
            "after-phase3b",
            "after-phase4",
            "after-phase5",
            "after-phase6",
            "after-phase6b",
            "after-phase7",
            "after-phase8"
        ];
    }

    function test_fork_fullPreview_globalPauseAfterEveryPhase() public {
        if (!_fork()) return;
        h.run();
        string[10] memory expected = _strictStages();
        assertEq(h.globalPauseStageCount(), 11, "phase0 + after-phase1 .. after-phase8 incl. after-phase3b / after-phase6b");
        assertEq(h.globalPauseStagesPassed(0), "phase0");
        for (uint256 i = 0; i < 10; i++) {
            assertEq(h.globalPauseStagesPassed(i + 1), expected[i]);
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

    /// Story 092: through Phase 6b (the minter move / SYA / source retirement runs between Phase 6 and Phase 7).
    function _toPhase6b() internal {
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();
        h.harnessPhase2AsOwner();
        h.harnessPhase3AsOwner();
        h.harnessPhase3bAsOwner();
        h.harnessPhase4AsOwner();
        h.harnessPhase5AsOwner();
        h.harnessPhase6AsOwner();
        h.harnessPhase6bAsOwner();
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
        _toPhase6b();
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
        _toPhase6b();
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

        // ---- Phase 3b (story 091): the sDOLA strategy is never paused, and registered only once its pauser is the Pauser ----
        h.harnessDeploySdolaStrategyOnly();
        address sys = address(h.sdolaStrategy());
        assertTrue(_breakerLive("P3b-after-sDOLA-strategy-deploy"), "P3b deploy");
        vm.prank(OWNER);
        IPausableLike(sys).setPauser(PAUSER);
        assertTrue(_breakerLive("P3b-after-sDOLA-strategy.setPauser(Pauser)"), "P3b setPauser");
        assertFalse(IPausableLike(sys).paused(), "sDOLA strategy is UNPAUSED when it is registered");
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).register(sys);
        assertTrue(_breakerLive("P3b-after-register(sDOLA strategy)"), "P3b register");
        h.harnessPhase3bAsOwner(); // real Phase 3b: CREATE skipped (address held), pauser/register skip, withdrawer lands
        assertTrue(_breakerLive("after-phase3b"), "phase 3b");

        h.harnessPhase4AsOwner();
        assertTrue(_breakerLive("after-phase4"), "phase 4");
        h.harnessPhase5AsOwner();
        assertTrue(_breakerLive("after-phase5"), "phase 5");
        h.harnessPhase6AsOwner();
        assertTrue(_breakerLive("after-phase6"), "phase 6");

        // ---- Phase 6b (story 092): minter move and SYA touch no pause state; the source retirement repeats Phase 1's rule ----
        h.harnessMinterRecordAndDisableAsOwner();
        assertTrue(_breakerLive("P6b-after-minter-disable"), "P6b disable");
        h.harnessMinterExecuteAsOwner();
        assertTrue(_breakerLive("P6b-after-execute"), "P6b execute");
        h.harnessMinterReseedAsOwner();
        assertTrue(_breakerLive("P6b-after-reseed"), "P6b reseed");
        h.harnessMinterRegisterAsOwner();
        assertTrue(_breakerLive("P6b-after-register"), "P6b register");
        h.harnessSyaRepointAsOwner();
        assertTrue(_breakerLive("P6b-after-SYA"), "P6b SYA");
        vm.startPrank(OWNER);
        ISourceDolaStrategy(YS_DOLA_SOURCE).setClient(V1, false);
        ISourceDolaStrategy(YS_DOLA_SOURCE).setClient(MINTER, false);
        vm.stopPrank();
        assertTrue(_breakerLive("P6b-after-source-clients-revoked"), "P6b clients");
        vm.prank(OWNER);
        IPausableLike(YS_DOLA_SOURCE).setPauser(OWNER);
        bool afterSourceSetPauser = _breakerLive("P6b-after-source.setPauser(OWNER)");
        assertFalse(afterSourceSetPauser, "the second forced window: registered autoDOLA strategy whose pauser is OWNER");
        if (!afterSourceSetPauser) dead++;
        vm.prank(OWNER);
        IPauserRegistry(PAUSER).unregister(YS_DOLA_SOURCE);
        assertTrue(_breakerLive("P6b-after-unregister(source)"), "P6b unregister");
        vm.prank(OWNER);
        IPausableLike(YS_DOLA_SOURCE).pause();
        assertTrue(_breakerLive("P6b-after-source.pause()"), "P6b pause");
        h.harnessPhase6bAsOwner(); // real Phase 6b on the stepped state: every step skips, read-backs pass
        assertTrue(_breakerLive("after-phase6b"), "phase 6b");

        // ---- Phase 7 ----
        h.harnessPhase7Preamble();
        _phase7PauserSteps(5, true);
        h.harnessPhase7AsOwner();
        h.harnessPhase8();
        assertTrue(_breakerLive("after-phase8"), "end state");
        assertEq(dead, 2, "exactly two dead points: V1 (Phase 1) and the autoDOLA source (Phase 6b), each between setPauser(OWNER) and unregister");
    }

    // =====================================================================
    //  Story 087 (audit-33 L-05): resume convergence from each new Phase 7 halt point
    // =====================================================================

    /// Halt after `haltAfter` Phase 7 pauser steps: (1) setPauser(PAUSER) only, (2) + unpause, (3) + register(V2).
    /// The breaker is live at the halt; a PREVIEW run() over the halted state passes (its phase0 simulation does
    /// not revert); and a broadcast-shaped resume (the real phases as OWNER) converges to the Phase 8 end state.
    function _haltedPhase7ResumeConverges(uint256 haltAfter) internal {
        _toPhase6b();
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
        _toPhase6b(); // resume leg: every step state-gated
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
        _toPhase6b();
        h.harnessPhase7Preamble();
        _phase7PauserSteps(2, false);
        address v2 = address(h.v2());
        assertEq(IPausableLike(v2).pauser(), PAUSER, "setup: V2 pauser is already the Pauser");
        assertFalse(IPauserRegistry(PAUSER).isRegistered(v2), "setup: V2 not registered");

        uint256 snap = vm.snapshotState();
        (bool ok,) = _eyeFundedPause();
        assertTrue(ok, "global pause does not revert at the gap");
        assertFalse(IPausableLike(v2).paused(), "GAP: global pause leaves V2 unpaused");
        assertTrue(IPausableLike(address(h.sdolaStrategy())).paused(), "V2's DOLA strategy (sDOLA, story 091) paused by the global pause");
        assertTrue(IPausableLike(h.YS_DOLA()).paused(), "source strategy DOLA paused by the global pause");
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
        _toPhase6b();
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
    //  Story 091: sDOLA destination strategy + source/destination split
    // =====================================================================

    address constant DOLA_T = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant YS_DOLA_SOURCE = 0x1760E05356Ec1FBBA159C730781dCfB9920524e2;
    address constant MINTER = 0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C;
    address constant SYA = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;

    /// Full preview end state: V2's DOLA principal sits in the NEW sDOLA strategy, V1 books nothing on 0x1760, the
    /// sDOLA strategy is Pauser-registered with SYA as withdrawer, the other pools keep source == destination, and
    /// the preview smoke tests (stake/withdraw every pool, autoAnnihilate(DOLA)) passed inside run().
    function test_fork_fullPreview_v2DolaLandsInSdolaStrategy() public {
        if (!_fork()) return;
        (,,, uint256 v1DolaBefore) = ICutoverStakerLike(V1).poolInfo(DOLA_T);
        assertGt(v1DolaBefore, 0, "setup: V1 holds DOLA at the fork block");
        h.run();

        ERC4626YieldStrategy sys = h.sdolaStrategy();
        address v2 = address(h.v2());
        assertTrue(address(sys) != address(0) && address(sys) != YS_DOLA_SOURCE, "a NEW DOLA strategy was deployed");
        assertEq(address(sys.vault()), h.SDOLA(), "vault is sDOLA");
        assertEq(address(sys.underlyingToken()), DOLA_T, "underlying DOLA");
        assertEq(sys.owner(), OWNER, "owner OWNER");
        assertEq(sys.pauser(), PAUSER, "pauser Pauser");
        assertTrue(IPauserRegistry(PAUSER).isRegistered(address(sys)), "sDOLA strategy registered with the Pauser");
        assertTrue(sys.authorizedWithdrawers(h.STABLE_YIELD_ACCUMULATOR()), "SYA withdrawer");
        assertTrue(sys.authorizedClients(v2), "V2 client");
        assertEq(sys.setAsideBufferSize(v2), IStrategyBufferLike(YS_DOLA_SOURCE).setAsideBufferSize(V1), "V1's buffer pct copied");
        assertEq(sys.setAsideBufferRecipient(), v2, "destination recipient V2");
        assertEq(IStrategyBufferLike(YS_DOLA_SOURCE).setAsideBufferRecipient(), V1, "source recipient left as V1 (story 092 retires the strategy)");
        assertTrue(sys.authorizedClients(h.PHUSD_STABLE_MINTER()), "story 092: the minter is a client of the sDOLA strategy");

        assertEq(address(StableStakerV2(v2).yieldStrategy(DOLA_T)), address(sys), "V2 DOLA -> sDOLA strategy");
        (,,, uint256 v2DolaStaked) = StableStakerV2(v2).poolInfo(DOLA_T);
        assertGt(v2DolaStaked, 0, "V2 DOLA pool populated");
        assertGe(sys.principalOf(DOLA_T, v2), v2DolaStaked, "V2's DOLA principal is booked in the sDOLA strategy");
        assertEq(IStrategyBufferLike(YS_DOLA_SOURCE).principalOf(DOLA_T, V1), 0, "V1 principal on 0x1760 == 0");
        assertEq(IStrategyBufferLike(YS_DOLA_SOURCE).principalOf(DOLA_T, v2), 0, "V2 never touched the source strategy");

        assertEq(h.harnessSourceStrategyFor(h.USDC()), h.harnessDestinationStrategyFor(h.USDC()), "USDC same both sides");
        assertEq(h.harnessSourceStrategyFor(h.USDE()), h.harnessDestinationStrategyFor(h.USDE()), "USDe same both sides");
        assertEq(h.harnessPerUserLossBpsFor(DOLA_T), 10, "DOLA per-user bound: autoDOLA 5 + sDOLA 5");
        assertEq(h.harnessPerUserLossBpsFor(h.USDC()), 5, "USDC per-user bound counted once");
        assertEq(h.harnessPerUserLossBpsFor(h.USDE()), 61, "USDe per-user bound counted once (2*30+1)");
    }

    /// Before Phase 3b (and with no progress entry) the DOLA destination is unknown and every V2-side read reverts.
    function test_fork_destinationUnknown_revertsLoudly() public {
        if (!_fork()) return;
        vm.expectRevert(
            bytes("DOLA destination (sDOLA strategy) unknown - Phase 3b has not deployed it and the progress file does not name it")
        );
        h.harnessDestinationStrategyFor(DOLA_T);
        assertEq(h.harnessDestinationStrategyFor(h.USDC()), h.YS_USDC(), "USDC destination needs no deployment");
    }

    /// Resume with a progress file that lost the sDOLA strategy while it is REGISTERED with the Pauser: Phase 3b
    /// refuses to deploy a second one.
    function test_fork_phase3b_unrecordedRegisteredStrategy_failsClosed() public {
        if (!_fork()) return;
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();
        h.harnessPhase2AsOwner();
        h.harnessPhase3AsOwner();
        h.harnessPhase3bAsOwner();
        address first = address(h.sdolaStrategy());
        h.harnessForgetSdolaStrategy();
        vm.expectRevert(
            bytes(
                string.concat(
                    "Phase3b: Pauser registrant ", vm.toString(first),
                    " is an ERC4626YieldStrategy(OWNER, DOLA, sDOLA) the progress file does not name - STOP (record it; never deploy a second one)"
                )
            )
        );
        h.harnessPhase3bAsOwner();
    }

    /// Resume with a progress file that lost the sDOLA strategy after V2 was wired to it: fails closed on V2 state.
    function test_fork_phase3b_unrecordedV2Wiring_failsClosed() public {
        if (!_fork()) return;
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();
        h.harnessPhase2AsOwner();
        h.harnessPhase3AsOwner();
        h.harnessPhase3bAsOwner();
        h.harnessPhase4AsOwner();
        address first = address(h.sdolaStrategy());
        vm.startPrank(OWNER); // hide it from the registrant scan: only V2 state names it
        IPausableLike(first).setPauser(OWNER);
        IPauserRegistry(PAUSER).unregister(first);
        vm.stopPrank();
        h.harnessForgetSdolaStrategy();
        vm.expectRevert(
            bytes(
                "Phase3b: V2 already routes DOLA to a strategy the progress file does not name - STOP (add contracts.ERC4626YieldStrategySDOLA to the progress file; never deploy a second one)"
            )
        );
        h.harnessPhase3bAsOwner();
    }

    /// A resume that re-enters Phase 3b with the address held (as loaded from the progress file) deploys nothing.
    function test_fork_phase3b_resumeIsIdempotent() public {
        if (!_fork()) return;
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();
        h.harnessPhase2AsOwner();
        h.harnessPhase3AsOwner();
        h.harnessPhase3bAsOwner();
        address first = address(h.sdolaStrategy());
        uint256 registrants = IPauserRegistry(PAUSER).getPausableContracts().length;
        h.harnessPhase3bAsOwner();
        assertEq(address(h.sdolaStrategy()), first, "same strategy");
        assertEq(IPauserRegistry(PAUSER).getPausableContracts().length, registrants, "no second registration");
    }

    /// Source guard: `_strategyFor` is gone from every cutover source, so no call site is ambiguous.
    function test_strategyMapSplit_noAmbiguousCallSite() public view {
        string[3] memory files = [SCRIPT_SRC, "script/VerifyStableStakerV2Cutover.s.sol", "script/helpers/StableStakerCutoverCore.sol"];
        for (uint256 i = 0; i < files.length; i++) {
            assertEq(_count(vm.readFile(files[i]), "_strategyFor("), 0, string.concat("_strategyFor still used in ", files[i]));
        }
        string memory src = vm.readFile(SCRIPT_SRC);
        uint256 p3b = _indexOf(src, "_phase3b_sdolaStrategy();", _indexOf(src, "function run()", 0));
        uint256 p4 = _indexOf(src, "_phase4_pools();", _indexOf(src, "function run()", 0));
        uint256 p3 = _indexOf(src, "_phase3_stakerV2();", _indexOf(src, "function run()", 0));
        assertTrue(p3 < p3b && p3b < p4, "Phase 3b runs after Phase 3 and before Phase 4");
    }

    // =====================================================================
    //  Story 092: minter DOLA collateral + SYA onto the sDOLA strategy, autoDOLA source retired
    // =====================================================================

    struct MinterCfg {
        address ys;
        uint256 rate;
        uint8 dec;
        bool enabled;
        uint256 maxPerDay;
    }

    function _minterCfg() internal view returns (MinterCfg memory c) {
        (c.ys, c.rate, c.dec, c.enabled, c.maxPerDay,,) = PhusdStableMinter(MINTER).stablecoinConfigs(DOLA_T);
    }

    function _withdrawalState() internal view returns (uint256 at, uint8 status, uint256 bal) {
        return ISourceDolaStrategy(YS_DOLA_SOURCE).withdrawalStates(DOLA_T, MINTER);
    }

    /// Asserts the complete Phase 6b end state against the pre-cutover minter config.
    function _assertMinterMoved(MinterCfg memory pre, uint256 ownerDolaPre) internal view {
        ERC4626YieldStrategy sys = h.sdolaStrategy();
        MinterCfg memory post = _minterCfg();
        assertEq(pre.ys, YS_DOLA_SOURCE, "setup: minter DOLA was on the autoDOLA strategy");
        assertEq(post.ys, address(sys), "minter DOLA registration -> sDOLA strategy");
        assertEq(post.rate, pre.rate, "exchangeRate unchanged");
        assertEq(post.dec, pre.dec, "decimals unchanged");
        assertEq(post.maxPerDay, pre.maxPerDay, "maxMintPerDay restored");
        assertEq(post.enabled, pre.enabled, "enabled restored");
        uint256 r = h.minterRecovered();
        assertGt(r, 0, "R recorded");
        uint256 principal = sys.principalOf(DOLA_T, MINTER);
        assertGe(principal + r * 5 / 10_000 + 1000, r, "minter principal on sDOLA strategy within bound of R");
        assertEq(IERC20(DOLA_T).balanceOf(OWNER), ownerDolaPre, "OWNER DOLA back to its pre-cutover level");
        assertTrue(sys.authorizedClients(MINTER), "minter is a sDOLA strategy client");
        address[] memory list = ISyaStrategyList(SYA).getYieldStrategies();
        bool hasNew;
        bool hasOld;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == address(sys)) hasNew = true;
            if (list[i] == YS_DOLA_SOURCE) hasOld = true;
        }
        assertTrue(hasNew && !hasOld, "SYA list: +sDOLA strategy, -autoDOLA strategy");
        assertTrue(sys.authorizedWithdrawers(SYA), "SYA withdrawer on sDOLA strategy");
        assertFalse(ISourceDolaStrategy(YS_DOLA_SOURCE).authorizedWithdrawers(SYA), "SYA withdrawer revoked on source");
        assertFalse(ISourceDolaStrategy(YS_DOLA_SOURCE).authorizedClients(V1), "source client V1 revoked");
        assertFalse(ISourceDolaStrategy(YS_DOLA_SOURCE).authorizedClients(MINTER), "source client minter revoked");
        assertEq(ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, V1), 0, "source V1 principal 0");
        assertEq(ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, MINTER), 0, "source minter principal 0");
        assertEq(IPausableLike(YS_DOLA_SOURCE).pauser(), OWNER, "source pauser OWNER");
        assertFalse(IPauserRegistry(PAUSER).isRegistered(YS_DOLA_SOURCE), "source unregistered");
        assertTrue(IPausableLike(YS_DOLA_SOURCE).paused(), "source paused");
        assertTrue(IPauserRegistry(PAUSER).isRegistered(address(sys)), "sDOLA strategy registered");
        assertFalse(sys.paused(), "sDOLA strategy unpaused");
        (, uint8 status,) = _withdrawalState();
        assertEq(status, 0, "withdrawal state reset (executed once)");
    }

    /// Happy path: initiate (story 090 script) -> warp 6h + 60s -> full preview cutover -> every Phase 6b assert, then
    /// V2 autoAnnihilate(DOLA) deposits the minter's DOLA into the sDOLA strategy.
    function test_fork_092_fullCutover_minterSyaRepointed_sourceRetired() public {
        if (!_fork()) return;
        MinterCfg memory pre = _minterCfg();
        uint256 ownerDolaPre = IERC20(DOLA_T).balanceOf(OWNER);
        uint256 minterPrincipalPre = ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, MINTER);
        assertGt(minterPrincipalPre, 0, "setup: minter holds DOLA principal on the autoDOLA strategy");

        h.run();

        _assertMinterMoved(pre, ownerDolaPre);
        assertEq(h.minterPrincipalBeforeExec(), minterPrincipalPre, "P recorded");
        console.log("092|P / R / minter principal on sDOLA strategy:", minterPrincipalPre, h.minterRecovered(), h.sdolaStrategy().principalOf(DOLA_T, MINTER));

        // autoAnnihilate(DOLA) after the cutover lands its minter deposit in the sDOLA strategy.
        StableStakerV2 v2 = h.v2();
        address actor = makeAddr("story092-annihilator");
        deal(DOLA_T, actor, 1000e18);
        vm.startPrank(actor);
        IERC20(DOLA_T).approve(address(v2), 1000e18);
        v2.stake(DOLA_T, 1000e18);
        vm.stopPrank();
        _warpTo(block.timestamp + 10 minutes);
        uint256 before = h.sdolaStrategy().principalOf(DOLA_T, MINTER);
        vm.prank(actor);
        v2.autoAnnihilate(DOLA_T);
        assertGt(h.sdolaStrategy().principalOf(DOLA_T, MINTER), before, "autoAnnihilate(DOLA) deposits into the sDOLA strategy");
        assertEq(ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, MINTER), 0, "nothing lands on the retired source");
    }

    // ---- Phase 0 negative window tests ----

    function test_fork_092_phase0_notInitiated_reverts() public {
        if (!_forkNoInitiate()) return;
        vm.expectRevert(
            bytes(
                "Phase0: PhusdStableMinter DOLA totalWithdrawal is NOT initiated on the autoDOLA strategy - run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status)"
            )
        );
        h.run();
    }

    function test_fork_092_phase0_waitingPeriod_reverts() public {
        if (!_forkNoInitiate()) return;
        _initiateMinterWithdrawal();
        _warpTo(initiatedAt + 6 hours - 1);
        vm.expectRevert(
            bytes(
                string.concat(
                    "Phase0: minter DOLA withdrawal still in its 6h waiting period - run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status); executable at ",
                    vm.toString(initiatedAt + 6 hours)
                )
            )
        );
        h.run();
    }

    function test_fork_092_phase0_expiredWindow_reverts() public {
        if (!_forkNoInitiate()) return;
        _initiateMinterWithdrawal();
        _warpTo(initiatedAt + 78 hours + 1);
        vm.expectRevert(
            bytes(
                "Phase0: minter DOLA withdrawal window EXPIRED - run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status)"
            )
        );
        h.run();
    }

    function test_fork_092_phase0_pastSafetyMargin_reverts() public {
        if (!_forkNoInitiate()) return;
        _initiateMinterWithdrawal();
        uint256 closesAt = initiatedAt + 78 hours;
        _warpTo(closesAt - h.WINDOW_SAFETY_MARGIN());
        vm.expectRevert(
            bytes(
                string.concat(
                    "Phase0: fewer than WINDOW_SAFETY_MARGIN seconds left in the minter DOLA withdrawal window - too late to start the session. Wait for expiry at ",
                    vm.toString(closesAt),
                    ", then run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status)"
                )
            )
        );
        h.run();
    }

    /// Boundary control: one second inside the margin the preflight passes (Phase 0 only).
    function test_fork_092_phase0_justInsideMargin_passes() public {
        if (!_forkNoInitiate()) return;
        _initiateMinterWithdrawal();
        _warpTo(initiatedAt + 78 hours - h.WINDOW_SAFETY_MARGIN() - 1);
        h.harnessPhase0(true);
    }

    // ---- Resume ----

    function _throughPhase6() internal {
        h.harnessPhase0(true);
        h.harnessPhase1AsOwner();
        h.harnessPhase2AsOwner();
        h.harnessPhase3AsOwner();
        h.harnessPhase3bAsOwner();
        h.harnessPhase4AsOwner();
        h.harnessPhase5AsOwner();
        h.harnessPhase6AsOwner();
    }

    /// Halt after the EXECUTE (DOLA on OWNER), resume: no second execution, R preserved and re-seeded, converges.
    function test_fork_092_haltAfterExecute_resumeConverges() public {
        if (!_fork()) return;
        MinterCfg memory pre = _minterCfg();
        uint256 ownerDolaPre = IERC20(DOLA_T).balanceOf(OWNER);
        _throughPhase6();
        h.harnessMinterRecordAndDisableAsOwner();
        h.harnessMinterExecuteAsOwner();
        uint256 r = h.minterRecovered();
        assertGt(r, 0, "R recorded at the halt");
        assertEq(IERC20(DOLA_T).balanceOf(OWNER), ownerDolaPre + r, "HALT: the minter's collateral sits on OWNER");
        assertFalse(_minterCfg().enabled, "HALT: DOLA minting disabled");

        // Fail closed: a resume whose progress file lost the execution record cannot recover R.
        uint256 snap = vm.snapshotState();
        h.harnessForgetMinterExecRecord();
        vm.expectRevert(
            bytes(
                "Phase6b: minter withdrawal executed but the progress file has no execution record (minterMove.ownerDolaBeforeExec) - R cannot be recovered. STOP: reconstruct it from the WithdrawalExecuted tx before resuming"
            )
        );
        h.harnessMinterReseedAsOwner();
        vm.revertToState(snap);

        // Resume leg: the real phases from Phase 0, every step state-gated.
        h.harnessResetTokens();
        _toPhase6b();
        h.harnessPhase7AsOwner();
        h.harnessPhase8();
        assertEq(h.minterRecovered(), r, "R preserved across the resume");
        _assertMinterMoved(pre, ownerDolaPre);
    }

    /// Halt after registerStablecoin (maxMintPerDay reset to 0, enabled forced true), resume: cap and flag restored, no
    /// second execution, no second deposit.
    function test_fork_092_haltAfterRepoint_resumeConverges() public {
        if (!_fork()) return;
        MinterCfg memory pre = _minterCfg();
        uint256 ownerDolaPre = IERC20(DOLA_T).balanceOf(OWNER);
        _throughPhase6();
        h.harnessMinterRecordAndDisableAsOwner();
        h.harnessMinterExecuteAsOwner();
        h.harnessMinterReseedAsOwner();
        address sys = address(h.sdolaStrategy());
        vm.prank(OWNER);
        PhusdStableMinter(MINTER).registerStablecoin(DOLA_T, sys, pre.rate, pre.dec); // the halt: only the repoint landed
        assertEq(_minterCfg().maxPerDay, 0, "HALT: registerStablecoin reset maxMintPerDay");
        uint256 principalAtHalt = h.sdolaStrategy().principalOf(DOLA_T, MINTER);

        h.harnessResetTokens();
        _toPhase6b();
        h.harnessPhase7AsOwner();
        h.harnessPhase8();
        assertEq(h.sdolaStrategy().principalOf(DOLA_T, MINTER), principalAtHalt, "no second re-seed");
        _assertMinterMoved(pre, ownerDolaPre);
    }

    /// Halt point (g): autoDOLA source pauser moved to OWNER while still registered - the breaker is DEAD. A PREVIEW over
    /// the un-remedied halt reverts at phase0 naming the source (not tolerated); after the documented remedy (OWNER
    /// Pauser.unregister(source)) the breaker is live and the preview resume converges through every strict stage.
    function test_fork_092_haltAtSourceDeadWindow_remedyThenResumeConverges() public {
        if (!_fork()) return;
        MinterCfg memory pre = _minterCfg();
        uint256 ownerDolaPre = IERC20(DOLA_T).balanceOf(OWNER);
        _throughPhase6();
        h.harnessMinterRecordAndDisableAsOwner();
        h.harnessMinterExecuteAsOwner();
        h.harnessMinterReseedAsOwner();
        h.harnessMinterRegisterAsOwner();
        h.harnessSyaRepointAsOwner();
        vm.startPrank(OWNER);
        ISourceDolaStrategy(YS_DOLA_SOURCE).setClient(V1, false);
        ISourceDolaStrategy(YS_DOLA_SOURCE).setClient(MINTER, false);
        IPausableLike(YS_DOLA_SOURCE).setPauser(OWNER);
        vm.stopPrank();
        assertFalse(_breakerLive("HALT-P6b-source-dead-window"), "setup: breaker dead at halt point (g)");

        h.harnessResetTokens();
        vm.expectRevert(
            bytes(
                string.concat(
                    "globalPause(phase0): Pauser.pause() does not pause every registrant; first failing registrant: ",
                    vm.toString(YS_DOLA_SOURCE)
                )
            )
        );
        h.run();

        vm.prank(OWNER);
        IPauserRegistry(PAUSER).unregister(YS_DOLA_SOURCE); // the remedy
        assertTrue(_breakerLive("HALT-P6b-remedied"), "breaker live after the remedy");

        h.harnessResetTokens();
        h.run(); // PREVIEW resume (in-memory records stand in for the progress file)
        string[10] memory expected = _strictStages();
        assertEq(h.globalPauseStageCount(), 11, "phase0 + every strict stage");
        for (uint256 i = 0; i < 10; i++) {
            assertEq(h.globalPauseStagesPassed(i + 1), expected[i]);
        }
        _assertMinterMoved(pre, ownerDolaPre);
    }

    // ---- Story 094 (audit-35 L-09): the first broadcast leg ends after the execute; the re-seed approves 1.5R ----

    /// An UNINTERRUPTED run from Phase 0 stops right after the minter execute: no OWNER approve to the minter and no
    /// noMintDeposit is recorded in that run, Phase 7 / 8 never run, and the progress status names the leg end.
    function test_fork_094_uninterruptedRun_endsLegAfterExecute() public {
        if (!_fork()) return;
        MinterCfg memory pre = _minterCfg();
        uint256 ownerDolaPre = IERC20(DOLA_T).balanceOf(OWNER);
        uint256 allowancePre = IERC20(DOLA_T).allowance(OWNER, MINTER);
        h.harnessForceBroadcastLegEnd(true);

        vm.expectCall(DOLA_T, abi.encodeWithSelector(IERC20.approve.selector, MINTER), 0);
        vm.expectCall(MINTER, abi.encodeWithSelector(PhusdStableMinter.noMintDeposit.selector), 0);
        h.run();

        assertTrue(h.minterLegEndedAfterExecute(), "leg ended after the execute");
        assertEq(h.lastProgressStatus(), h.PROGRESS_STATUS_AWAITING_RESEED(), "progress status names the leg end");
        assertEq(h.PROGRESS_STATUS_AWAITING_RESEED(), "awaiting_reseed");
        assertEq(ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, MINTER), 0, "the execute ran in leg 1");
        uint256 r = h.minterRecovered();
        assertGt(r, 0, "R recorded");
        assertEq(IERC20(DOLA_T).balanceOf(OWNER), ownerDolaPre + r, "leg-1 end: the collateral sits on OWNER");
        assertEq(IERC20(DOLA_T).allowance(OWNER, MINTER), allowancePre, "no approve recorded in leg 1");
        assertEq(h.sdolaStrategy().principalOf(DOLA_T, MINTER), 0, "no re-seed recorded in leg 1");
        MinterCfg memory mid = _minterCfg();
        assertEq(mid.ys, pre.ys, "registration not moved in leg 1");
        assertFalse(mid.enabled, "DOLA minting stays disabled until leg 2");
        assertTrue(h.v2().paused(), "Phase 7 did not run in leg 1");
    }

    /// Leg 2 re-seeds the MINED R. Reproduces the audit's injection: the leg-1 state is recorded, then SYA's
    /// skimSurplus(DOLA, claimer) lands before the execute, so the mined R is BELOW the R an unskimmed local pass saw.
    /// Leg 2 (carrying the local-pass R in its progress file) deposits the live delta, converges, and leaves OWNER's
    /// DOLA exactly at its pre-execution level.
    function test_fork_094_leg2_reseedsMinedR_afterSkimBeforeExecute() public {
        if (!_fork()) return;
        MinterCfg memory pre = _minterCfg();
        uint256 ownerDolaPre = IERC20(DOLA_T).balanceOf(OWNER);

        // Forge's local pass of an uninterrupted leg 1 (no skim): the R it would have signed.
        uint256 snap = vm.snapshotState();
        h.harnessForceBroadcastLegEnd(true);
        h.run();
        uint256 rLocal = h.minterRecovered();
        vm.revertToState(snap);

        // On chain: leg-1 state recorded, then the skim mines before the execute.
        _throughPhase6();
        h.harnessMinterRecordAndDisableAsOwner();
        vm.prank(SYA);
        uint256 skimmed = ISkimSurplusLike(YS_DOLA_SOURCE).skimSurplus(DOLA_T, makeAddr("story094-claimer"));
        assertGt(skimmed, 0, "setup: surplus skimmed between the local pass and the execute");

        h.harnessForceBroadcastLegEnd(true);
        h.harnessResetTokens();
        h.run(); // leg 1 continues to the execute, then ends
        assertTrue(h.minterLegEndedAfterExecute(), "leg 1 ended after the execute");
        uint256 rMined = IERC20(DOLA_T).balanceOf(OWNER) - ownerDolaPre;
        assertLt(rMined, rLocal, "setup: mined R below the local-pass R (the old revert branch)");
        assertEq(h.sdolaStrategy().principalOf(DOLA_T, MINTER), 0, "nothing re-seeded in leg 1");

        // Leg 2: its progress file carries the local-pass R; the re-seed must use the mined one.
        h.harnessSetRecordedRecovered(rLocal);
        h.harnessResetTokens();
        h.run();
        assertFalse(h.minterLegEndedAfterExecute(), "leg 2 does not end early (no execute in this run)");
        assertEq(h.minterRecovered(), rMined, "leg 2 re-seeded the mined R");
        assertEq(IERC20(DOLA_T).balanceOf(OWNER), h.ownerDolaBeforeExec(), "OWNER DOLA == ownerDolaBeforeExec");
        _assertMinterMoved(pre, ownerDolaPre);
        assertFalse(h.v2().paused(), "leg 2 finalized the cutover");
    }

    /// @dev OWNER's DOLA allowance to the minter is live state (type(uint256).max at FORK_BLOCK), so each approve test sets
    ///      the allowance it needs explicitly after the execute.
    function _throughExecute() internal returns (uint256 r) {
        _throughPhase6();
        h.harnessMinterRecordAndDisableAsOwner();
        h.harnessMinterExecuteAsOwner();
        r = h.minterRecovered();
        assertGt(r, 0, "setup: R recorded");
    }

    /// The re-seed approves ceil(1.5 * R) (human decision) and still deposits exactly R.
    function test_fork_094_reseedApprovesOneAndAHalfR() public {
        if (!_fork()) return;
        uint256 r = _throughExecute();
        uint256 headroom = (r * 3 + 1) / 2;
        vm.prank(OWNER);
        IERC20(DOLA_T).approve(MINTER, 0); // a fresh session: no allowance
        vm.expectCall(DOLA_T, abi.encodeCall(IERC20.approve, (MINTER, headroom)), 1);
        vm.expectCall(DOLA_T, abi.encodeCall(IERC20.approve, (MINTER, uint256(0))), 0);
        vm.expectCall(MINTER, abi.encodeCall(PhusdStableMinter.noMintDeposit, (address(h.sdolaStrategy()), DOLA_T, r)), 1);
        h.harnessMinterReseedAsOwner();
        assertEq(IERC20(DOLA_T).allowance(OWNER, MINTER), headroom - r, "the unused 0.5R headroom stays as allowance");
        assertEq(IERC20(DOLA_T).balanceOf(OWNER), h.ownerDolaBeforeExec(), "exactly R deposited");
    }

    /// Resume after a halt between the approve and noMintDeposit: an allowance that already covers R is NOT zeroed and
    /// not re-approved.
    function test_fork_094_resume_allowanceCoveringR_notZeroed() public {
        if (!_fork()) return;
        uint256 r = _throughExecute();
        uint256 headroom = (r * 3 + 1) / 2;
        vm.prank(OWNER);
        IERC20(DOLA_T).approve(MINTER, headroom); // the halted leg's approve landed
        vm.expectCall(DOLA_T, abi.encodeWithSelector(IERC20.approve.selector, MINTER), 0);
        h.harnessMinterReseedAsOwner();
        assertEq(IERC20(DOLA_T).allowance(OWNER, MINTER), headroom - r, "existing headroom kept, R pulled");
        assertEq(IERC20(DOLA_T).balanceOf(OWNER), h.ownerDolaBeforeExec(), "exactly R deposited");
    }

    /// A non-zero allowance BELOW R is zeroed first, then re-approved to 1.5R.
    function test_fork_094_resume_allowanceBelowR_zeroedThenOneAndAHalfR() public {
        if (!_fork()) return;
        uint256 r = _throughExecute();
        uint256 headroom = (r * 3 + 1) / 2;
        vm.prank(OWNER);
        IERC20(DOLA_T).approve(MINTER, r / 2);
        vm.expectCall(DOLA_T, abi.encodeCall(IERC20.approve, (MINTER, uint256(0))), 1);
        vm.expectCall(DOLA_T, abi.encodeCall(IERC20.approve, (MINTER, headroom)), 1);
        h.harnessMinterReseedAsOwner();
        assertEq(IERC20(DOLA_T).allowance(OWNER, MINTER), headroom - r);
    }

    /// Source guard: run() returns between Phase 6b and Phase 7 when the leg ended, Phase 6b checks the flag between the
    /// execute and the re-seed, and only a BROADCAST ends the leg (preview rehearses the whole session).
    function test_094_legEnd_wiring() public view {
        string memory src = vm.readFile(SCRIPT_SRC);
        uint256 runAt = _indexOf(src, "function run()", 0);
        uint256 p6b = _indexOf(src, "_phase6b_minterSyaRetireSource();", runAt);
        uint256 legEnd = _indexOf(src, "if (minterLegEndedAfterExecute)", runAt);
        uint256 p7 = _indexOf(src, "_phase7_finalize();", runAt);
        assertTrue(p6b < legEnd && legEnd < p7, "run() ends the leg between Phase 6b and Phase 7");
        uint256 body = _indexOf(src, "function _phase6b_minterSyaRetireSource()", 0);
        uint256 exec = _indexOf(src, "_minterExecuteWithdrawal();", body);
        uint256 flag = _indexOf(src, "if (minterLegEndedAfterExecute) return;", body);
        uint256 reseed = _indexOf(src, "_minterReseedSdola();", body);
        assertTrue(exec < flag && flag < reseed, "Phase 6b returns between the execute and the re-seed");
        assertEq(_count(src, "return !isPreview;"), 1, "only a broadcast ends the leg");
        assertEq(_count(src, "IERC20(DOLA).approve(PHUSD_STABLE_MINTER, (r * 3 + 1) / 2);"), 1, "1.5R approve");
    }

    // ---- V1 exit vs pending minter withdrawal (human-requested proof), cases (a) - (c) ----

    /// Phases 0 (read checks only - Phase 0's window gate is untouched) .. 6 with the minter withdrawal pending, then
    /// (c): the pending state is untouched by V1's exit, and Phase 6b executes it.
    function _v1ExitWithPendingWithdrawal(bool warpIntoWindowBeforePhase6) internal {
        if (!_forkNoInitiate()) return;
        _initiateMinterWithdrawal();
        (uint256 at0, uint8 st0, uint256 bal0) = _withdrawalState();
        assertEq(st0, 1, "setup: Initiated");
        uint256 minterPrincipal0 = ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, MINTER);
        (,,, uint256 v1DolaBefore) = ICutoverStakerLike(V1).poolInfo(DOLA_T);
        assertGt(v1DolaBefore, 0, "setup: V1 holds DOLA");

        h.harnessPhase0ReadChecksOnly(true);
        h.harnessPhase1AsOwner();
        h.harnessPhase2AsOwner();
        h.harnessPhase3AsOwner();
        h.harnessPhase3bAsOwner();
        h.harnessPhase4AsOwner();
        h.harnessPhase5AsOwner();
        if (warpIntoWindowBeforePhase6) {
            _ageWithdrawal(6 hours + 60); // into the 72h execution window (see `_fork` on why not vm.warp)
        } else {
            assertLt(block.timestamp, initiatedAt + 6 hours, "case (a): still inside the 6h waiting period");
        }
        // The V1 exit runs `initiateMigration` for DOLA through CrossVersionMigrator; Phase 6's own post-conditions bound
        // every migrated user (autoDOLA exit 5 + sDOLA entry 5 bps + 1000 wei) and the exit realization.
        h.harnessPhase6AsOwner();

        assertEq(ICutoverStakerLike(V1).poolState(DOLA_T), 1, "V1 DOLA pool Migrating: initiateMigration succeeded");
        assertEq(ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, V1), 0, "V1 drained off the autoDOLA strategy");
        StableStakerV2 v2 = h.v2();
        (,,, uint256 v2Dola) = v2.poolInfo(DOLA_T);
        assertGe(v2Dola + 1e16, v1DolaBefore * (10_000 - 10) / 10_000, "V2 credited within the 10 bps DOLA bound (+1-cent straggler cap)");

        // (c) V1's exit neither consumed nor reset the minter's pending withdrawal.
        (uint256 at1, uint8 st1, uint256 bal1) = _withdrawalState();
        assertEq(at1, initiatedAt, "(c) initiatedAt unchanged by the V1 exit");
        if (!warpIntoWindowBeforePhase6) assertEq(at1, at0, "(c) initiatedAt unchanged since initiation");
        assertEq(st1, 1, "(c) still Initiated, not executed");
        assertEq(bal1, bal0, "(c) snapshot balance unchanged");
        assertEq(ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, MINTER), minterPrincipal0, "(c) minter principal untouched");

        // (c) then the minter execution phase succeeds inside the window.
        if (!warpIntoWindowBeforePhase6) _ageWithdrawal(6 hours + 60);
        (at1,,) = _withdrawalState();
        h.harnessPhase6bAsOwner();
        assertEq(ISourceDolaStrategy(YS_DOLA_SOURCE).principalOf(DOLA_T, MINTER), 0, "(c) minter withdrawal executed by Phase 6b");
        assertGt(h.sdolaStrategy().principalOf(DOLA_T, MINTER), 0, "(c) minter collateral re-seeded into the sDOLA strategy");
    }

    function test_fork_092_caseA_v1ExitDuringWaitingPeriod() public {
        _v1ExitWithPendingWithdrawal(false);
    }

    function test_fork_092_caseB_v1ExitInsideExecutionWindow() public {
        _v1ExitWithPendingWithdrawal(true);
    }

    /// Source guard: Phase 6b sits between Phase 6 and Phase 7 in run(), and the execute requires V1 drained first.
    function test_092_phase6bOrder_andV1DrainGate() public view {
        string memory src = vm.readFile(SCRIPT_SRC);
        uint256 runAt = _indexOf(src, "function run()", 0);
        uint256 p6 = _indexOf(src, "_phase6_migration();", runAt);
        uint256 p6b = _indexOf(src, "_phase6b_minterSyaRetireSource();", runAt);
        uint256 p7 = _indexOf(src, "_phase7_finalize();", runAt);
        assertTrue(p6 < p6b && p6b < p7, "Phase 6b runs after Phase 6 and before Phase 7");
        uint256 body = _indexOf(src, "function _phase6b_minterSyaRetireSource()", 0);
        uint256 gate = _indexOf(src, "ICutoverStrategy(YS_DOLA).principalOf(DOLA, STABLE_STAKER_V1) == 0", body);
        uint256 exec = _indexOf(src, "_minterExecuteWithdrawal();", body);
        assertTrue(gate < exec, "V1-drained require precedes the execute");
        assertEq(_count(src, "_phase0_readChecks();"), 1, "the window-free half is called only from _phase0_preconditions");
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
        assertEq(_count(src, "IPauserRegistry(PAUSER).unregister("), 2, "P1 unregister V1 + P6b unregister autoDOLA source");
        assertEq(_count(src, "v1p.pause();"), 1, "P1 pause");
        assertEq(_count(src, "v2.setPauser(OWNER);"), 1, "P3 setPauser");
        assertEq(_count(src, "v2.pause();"), 1, "P3 pause");
        assertEq(_count(src, "v2.setPauser(PAUSER);"), 1, "P7 setPauser");
        assertEq(_count(src, "v2.unpause();"), 1, "P7 unpause");
        assertEq(_count(src, "IPauserRegistry(PAUSER).register("), 3, "P3b register sDOLA strategy + P7 register x2");
        assertEq(_count(src, "sdolaStrategy.setPauser(PAUSER);"), 1, "P3b sDOLA strategy setPauser");
        assertEq(_count(src, "antimatter.setPauser(PAUSER);"), 1, "P7 Antimatter setPauser");
        // Story 092: the autoDOLA source retirement (probed tx by tx in test_fork_breakerProbe_everyPauseStateTx_phases1_3_7).
        assertEq(_count(src, "IPauserRegistry(PAUSER).unregister(YS_DOLA);"), 1, "P6b unregister source");
        assertEq(_count(src, "IPausableLike(YS_DOLA).setPauser(OWNER);"), 1, "P6b source setPauser");
        assertEq(_count(src, "IPausableLike(YS_DOLA).pause();"), 1, "P6b source pause");
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

interface ICutoverStakerLike {
    function poolInfo(address token) external view returns (uint256, uint256, uint256, uint256);
    function poolState(address token) external view returns (uint8);
}

interface IStrategyBufferLike {
    function setAsideBufferSize(address client) external view returns (uint256);
    function setAsideBufferRecipient() external view returns (address);
    function principalOf(address token, address account) external view returns (uint256);
}

interface ISkimSurplusLike {
    function skimSurplus(address token, address recipient) external returns (uint256);
}
