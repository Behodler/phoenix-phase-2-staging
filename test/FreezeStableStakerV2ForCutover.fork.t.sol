// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";
import {
    CutoverAntimatterPoolMainnet,
    AntimatterPoolMainnetBase,
    IAmCutoverPooler,
    IAmCutoverAntimatter,
    IAmCutoverFactory
} from "../script/CutoverAntimatterPoolMainnet.s.sol";
import {IPausableLike, IPauserRegistry} from "../script/CutoverStableStakerV2Mainnet.s.sol";
import {
    CutoverAntimatterPoolHarness,
    VerifyAntimatterPoolHarness,
    FreezeSsv2Harness,
    UnfreezeSsv2Harness
} from "./CutoverAntimatterPoolMainnet.fork.t.sol";
import {DeploySyaHarvesterHarness, VerifySyaHarvesterHarness} from "./DeploySyaHarvesterMainnet.fork.t.sol";
import {DeployUniswapHelperHarness, VerifyUniswapHelperHarness} from "./DeployUniswapHelperMainnet.fork.t.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";

interface I124Staker {
    function claimEnabled() external view returns (bool);
    function claim(address) external;
    function withdraw(address, uint256) external;
    function autoAnnihilate(address) external;
    function emergencyWithdraw(address) external;
    function userInfo(address, address) external view returns (uint256 amount, uint256 rewardDebt);
    function pendingReward(address, address) external view returns (uint256);
}

interface I124Factory {
    function createPair(address, address) external returns (address);
}

interface I124Pair {
    function mint(address) external returns (uint256);
}

/**
 * @title FreezeStableStakerV2ForCutoverForkTest  (story 124, audit run-44 M-02 / run-45 pps44m2)
 * @notice The SSV2 freeze around Script B, on a mainnet fork at the run-45 block 26_308_978 (AM supply 0, the run-45
 *         staker still holds DOLA principal with AM pending). Skipped without RPC_MAINNET. Covers the story's six fork
 *         verifications plus the completed-B re-run:
 *           1. full sequence freeze -> B -> A -> C, SSV2 ends restored, every verifier passes;
 *           2. race: withdraw + autoAnnihilate before the freeze lands -> B aborts on totalSupply() != 0 before any
 *              transaction; the unfreeze key restores cleanly;
 *           3. while frozen: withdraw / autoAnnihilate / claim / stake-path revert EnforcedPause, emergencyWithdraw works;
 *           4. B fails mid-run (tx5 reverted): SSV2 stays frozen + unregistered, the global pause still works, the
 *              freeze re-run is a no-op, B resumes and restores;
 *           5. global pause probe before the freeze, while frozen and after B's restore;
 *           6. run-45 fb-rerun2-spoof: the attacker cannot obtain AM, so cannot mint the dust LP; and even a dust LP
 *              (AM conjured with `deal`) no longer passes B's resume gate.
 */
contract FreezeStableStakerV2ForCutoverForkTest is Test {
    uint256 constant FORK_BLOCK = 26_308_978;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant STAKER = 0xD57e5f043cB3C05be4E8138886cCEF2448a07C66;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    string constant TMP = "server/deployments/progress.antimatter-pool.1.forktest-124-";
    bytes4 constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));

    AntimatterPoolMainnetBase.Config c;
    address attacker;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        c = new CutoverAntimatterPoolMainnet().expectedConfig();
        attacker = makeAddr("attacker");
        assertEq(IERC20(c.antimatter).totalSupply(), 0, "AM supply 0 at the run-45 block");
        assertEq(IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS), address(0), "AM/sUSDS pair absent");
        _assertRestored("fork block");
        return true;
    }

    function _tmp(string memory name) internal returns (string memory path) {
        path = string.concat(TMP, name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    function _assertFrozen(string memory when) internal view {
        assertTrue(IPausableLike(c.stableStakerV2).paused(), string.concat(when, ": SSV2 paused"));
        assertEq(IPausableLike(c.stableStakerV2).pauser(), OWNER, string.concat(when, ": SSV2 pauser == OWNER"));
        assertFalse(
            IPauserRegistry(c.pauser).isRegistered(c.stableStakerV2), string.concat(when, ": SSV2 unregistered")
        );
    }

    function _assertRestored(string memory when) internal view {
        assertFalse(IPausableLike(c.stableStakerV2).paused(), string.concat(when, ": SSV2 unpaused"));
        assertEq(IPausableLike(c.stableStakerV2).pauser(), c.pauser, string.concat(when, ": SSV2 pauser == Pauser"));
        assertTrue(IPauserRegistry(c.pauser).isRegistered(c.stableStakerV2), string.concat(when, ": SSV2 registered"));
    }

    /// @dev The permissionless global breaker, EYE-funded, inside a snapshot: succeeds and pauses every registrant.
    function _globalPauseWorks() internal returns (bool ok) {
        IPauserRegistry reg = IPauserRegistry(c.pauser);
        address eye = reg.eyeToken();
        uint256 burn = reg.eyeBurnAmount();
        address[] memory registrants = reg.getPausableContracts();
        uint256 snap = vm.snapshotState();
        address actor = makeAddr("story124-test-breaker");
        deal(eye, actor, burn, false);
        vm.prank(actor);
        IERC20(eye).approve(c.pauser, burn);
        vm.prank(actor);
        (ok,) = c.pauser.call(abi.encodeWithSignature("pause()"));
        for (uint256 i = 0; ok && i < registrants.length; i++) {
            if (!IPausableLike(registrants[i]).paused()) ok = false;
        }
        vm.revertToState(snap);
    }

    function _freeze(string memory path) internal returns (FreezeSsv2Harness f) {
        f = new FreezeSsv2Harness(false, path);
        f.run();
    }

    /// The run-45 pre-Script-A acquisition: full withdraw banks the pending reward, autoAnnihilate mints it raw.
    function _rawAmViaAutoAnnihilate() internal returns (uint256 amGot) {
        assertFalse(I124Staker(c.stableStakerV2).claimEnabled(), "claim gate closed");
        (uint256 principal,) = I124Staker(c.stableStakerV2).userInfo(DOLA, STAKER);
        assertGt(principal, 0, "staker has DOLA principal");
        vm.startPrank(STAKER);
        I124Staker(c.stableStakerV2).withdraw(DOLA, principal);
        I124Staker(c.stableStakerV2).autoAnnihilate(DOLA);
        vm.stopPrank();
        amGot = IERC20(c.antimatter).balanceOf(STAKER);
    }

    /// forge's LOCAL pass of B's `:broadcast` (rolled back), leaving its progress file on disk exactly as a real run
    /// would - seed record included - then the on-chain tx1-tx4. tx5 (`seed`) reverted on chain, so nothing of it
    /// remains: the state is tx1-tx4 landed, SSV2 frozen, the restore never sent.
    function _bDiesAtTx5(string memory path) internal returns (AntimatterPoolSeeder seeder, uint256 lp) {
        uint256 snap = vm.snapshotState();
        CutoverAntimatterPoolHarness local = new CutoverAntimatterPoolHarness(false, path);
        local.run();
        address predicted = address(local.seeder());
        vm.revertToState(snap);
        assertTrue(vm.exists(path), "local pass wrote the progress file");
        assertTrue(vm.parseJsonBool(vm.readFile(path), ".cutover.seeded"), "local pass recorded the seed");

        lp = vm.parseJsonUint(vm.readFile(path), ".cutover.lpAmount");
        vm.startPrank(OWNER);
        seeder =
            new AntimatterPoolSeeder(OWNER, c.phUSD, c.sUSDS, c.antimatter, c.router, c.phusdSusdsPair, c.uniPooler);
        IAmCutoverPooler(c.uniPooler).rescueERC20(c.phusdSusdsPair, OWNER, lp);
        IERC20(c.phusdSusdsPair).approve(address(seeder), lp);
        IAmCutoverAntimatter(c.antimatter).setApprovedMinter(address(seeder), true);
        vm.stopPrank();
        assertEq(address(seeder), predicted, "tx1 CREATE == local-pass seeder");
    }

    // ------------------------------------------------------------------ 1. full sequence

    function test_fork_fullSequence_freeze_B_A_C_restoresSsv2() public {
        if (!_fork()) return;
        string memory pB = _tmp("full-b");
        string memory pA = string.concat("server/deployments/progress.sya-harvester.1.forktest-124-full.json");
        string memory pC = string.concat("server/deployments/progress.uniswap-helper-am.1.forktest-124-full.json");
        if (vm.exists(pA)) vm.removeFile(pA);
        if (vm.exists(pC)) vm.removeFile(pC);

        assertTrue(_globalPauseWorks(), "breaker live before the freeze");
        FreezeSsv2Harness f = _freeze(pB);
        assertEq(f.txCount(), 3, "freeze: setPauser(OWNER), unregister, pause");
        _assertFrozen("after freeze");
        assertTrue(_globalPauseWorks(), "breaker live while frozen (SSV2 unregistered)");

        CutoverAntimatterPoolHarness b = new CutoverAntimatterPoolHarness(false, pB);
        b.run();
        assertEq(b.txCount(), 9, "B: 6 cutover + 3 restore");
        _assertRestored("after B");
        assertTrue(_globalPauseWorks(), "breaker live after B's restore");
        new VerifyAntimatterPoolHarness(pB).run();

        DeploySyaHarvesterHarness a = new DeploySyaHarvesterHarness(false, pA);
        a.run();
        assertTrue(I124Staker(c.stableStakerV2).claimEnabled(), "A opened claims");
        new VerifySyaHarvesterHarness(pA).run();

        DeployUniswapHelperHarness ch = new DeployUniswapHelperHarness(false, pC);
        ch.setBookAmPair(b.amSusdsPair());
        ch.run();
        UniswapHelper h = ch.helper();
        assertEq(h.amPair(), b.amSusdsPair(), "C resolves B's pair");
        assertGt(h.quotePhUSDToAM(1000e18), 0, "AM quote");
        VerifyUniswapHelperHarness vc = new VerifyUniswapHelperHarness(pC);
        vc.setBookAmPair(b.amSusdsPair());
        vc.run();

        // End to end: the protocol AM sits in the pair, OWNER owns its LP, SSV2 is back to normal.
        (,,,,,, uint256 amMinted, uint256 liquidity,,,,,,) = b.progress();
        assertEq(IERC20(c.antimatter).balanceOf(b.amSusdsPair()), amMinted, "pair holds the seeded AM");
        assertEq(IERC20(b.amSusdsPair()).balanceOf(OWNER), liquidity, "OWNER holds the AM/sUSDS LP");
        _assertRestored("end");

        // Completed-B re-run of the combined key: freeze no-op (SSV2 NOT re-frozen), B no-op, A no-op.
        FreezeSsv2Harness f2 = _freeze(pB);
        assertTrue(f2.skippedBCompleted(), "freeze short-circuits on the completed B");
        assertEq(f2.txCount(), 0, "freeze re-run: 0 txs");
        _assertRestored("after freeze re-run");
        CutoverAntimatterPoolHarness b2 = new CutoverAntimatterPoolHarness(false, pB);
        b2.run();
        assertEq(b2.txCount(), 0, "B re-run: 0 txs");
        DeploySyaHarvesterHarness a2 = new DeploySyaHarvesterHarness(false, pA);
        a2.run();
        assertEq(a2.txCount(), 0, "A re-run: 0 txs");
        _assertRestored("after combined re-run");

        vm.removeFile(pB);
        vm.removeFile(pA);
        vm.removeFile(pC);
    }

    // ------------------------------------------------------------------ 2. race

    function test_fork_race_amMintedBeforeFreeze_BAborts_unfreezeRestores() public {
        if (!_fork()) return;
        string memory path = _tmp("race");
        // The attacker's withdraw + autoAnnihilate lands in the block before the freeze.
        uint256 amGot = _rawAmViaAutoAnnihilate();
        assertGt(amGot, 0, "raw AM in third-party hands with claimEnabled == false");

        _freeze(path);
        _assertFrozen("after freeze");
        uint256 nonce = vm.getNonce(OWNER);

        CutoverAntimatterPoolHarness b = new CutoverAntimatterPoolHarness(false, path);
        vm.expectRevert(
            bytes(
                "Step 0 (M-02): Antimatter.totalSupply() != 0 while the AM/sUSDS pair does not exist - AM is in hands outside this cutover, so a dust-LP resume spoof is possible. ABORT before any transaction. SSV2 stays FROZEN: investigate, then the human decides (npm run ssv2-unfreeze-after-cutover-abort:broadcast restores SSV2; see docs/SyaAntimatterMainnetCutover.md)."
            )
        );
        b.run();
        assertEq(vm.getNonce(OWNER), nonce, "B sent nothing");
        assertEq(b.txCount(), 0, "txCount 0");
        assertFalse(vm.exists(path), "no progress file written");
        _assertFrozen("after the abort");
        assertTrue(_globalPauseWorks(), "breaker live while frozen after the abort");

        // The human abandons the window: the unfreeze key restores SSV2 cleanly.
        UnfreezeSsv2Harness u = new UnfreezeSsv2Harness(false, path);
        u.run();
        assertEq(u.txCount(), 3, "unpause, setPauser(Pauser), register");
        _assertRestored("after unfreeze");
        assertTrue(_globalPauseWorks(), "breaker live after unfreeze");

        UnfreezeSsv2Harness u2 = new UnfreezeSsv2Harness(false, path);
        u2.run();
        assertEq(u2.txCount(), 0, "unfreeze is idempotent");
    }

    /// @dev The unfreeze key refuses while B's seeder can still mint AM (B died between grant and revoke).
    function test_fork_unfreeze_refusesWhileSeederIsMinter() public {
        if (!_fork()) return;
        string memory path = _tmp("unfreeze-minter");
        _freeze(path);
        _bDiesAtTx5(path);
        UnfreezeSsv2Harness u = new UnfreezeSsv2Harness(false, path);
        vm.expectRevert(
            bytes(
                "unfreeze: the progress-file AntimatterPoolSeeder is STILL an approved Antimatter minter - revoke it first (Antimatter.setApprovedMinter(seeder, false)); see docs/SyaAntimatterMainnetCutover.md"
            )
        );
        u.run();
        vm.removeFile(path);
    }

    /// @dev Preview of the unfreeze key probes the global pause after the restore.
    function test_fork_unfreeze_preview_probesBreaker() public {
        if (!_fork()) return;
        string memory path = _tmp("unfreeze-preview");
        _freeze(path);
        UnfreezeSsv2Harness u = new UnfreezeSsv2Harness(true, path);
        u.run();
        assertEq(u.txCount(), 3, "3 pranked txs");
        assertEq(u.globalPauseStageCount(), 1, "after-unfreeze probe");
        _assertRestored("after unfreeze preview");
    }

    // ------------------------------------------------------------------ 3. while frozen

    function test_fork_whileFrozen_mintPathsRevert_emergencyWithdrawWorks() public {
        if (!_fork()) return;
        _freeze(_tmp("frozen"));
        (uint256 principal,) = I124Staker(c.stableStakerV2).userInfo(DOLA, STAKER);
        assertGt(I124Staker(c.stableStakerV2).pendingReward(DOLA, STAKER), 0, "AM pending");

        vm.startPrank(STAKER);
        vm.expectRevert(ENFORCED_PAUSE);
        I124Staker(c.stableStakerV2).withdraw(DOLA, principal);
        vm.expectRevert(ENFORCED_PAUSE);
        I124Staker(c.stableStakerV2).autoAnnihilate(DOLA);
        vm.expectRevert(ENFORCED_PAUSE);
        I124Staker(c.stableStakerV2).claim(DOLA);

        uint256 dolaBefore = IERC20(DOLA).balanceOf(STAKER);
        I124Staker(c.stableStakerV2).emergencyWithdraw(DOLA);
        vm.stopPrank();
        assertGt(IERC20(DOLA).balanceOf(STAKER), dolaBefore, "emergencyWithdraw paid principal out");
        (uint256 left,) = I124Staker(c.stableStakerV2).userInfo(DOLA, STAKER);
        assertEq(left, 0, "position closed");
        assertEq(IERC20(c.antimatter).totalSupply(), 0, "emergencyWithdraw minted no AM");
    }

    // ------------------------------------------------------------------ 4. B fails mid-run

    function test_fork_BFailsAtTx5_ssv2StaysFrozen_rerunResumesAndRestores() public {
        if (!_fork()) return;
        string memory path = _tmp("midrun");
        _freeze(path);
        (AntimatterPoolSeeder seeder,) = _bDiesAtTx5(path);

        _assertFrozen("after the failed B");
        assertTrue(_globalPauseWorks(), "Pauser.pause() still succeeds for the remaining registrants");
        assertTrue(IAmCutoverAntimatter(c.antimatter).isApprovedMinter(address(seeder)), "seeder still a minter");

        // Recovery: re-run the combined key. The freeze step is a no-op; B resumes at tx5 and restores.
        FreezeSsv2Harness f = _freeze(path);
        assertFalse(f.skippedBCompleted(), "B is not complete");
        assertEq(f.txCount(), 0, "freeze re-run: 0 txs");
        CutoverAntimatterPoolHarness b = new CutoverAntimatterPoolHarness(false, path);
        b.run();
        assertFalse(b.deployedThisRun(), "seeder adopted");
        assertFalse(b.rescuedThisRun(), "rescue not repeated");
        assertTrue(b.seededThisRun(), "seeded on resume");
        assertEq(b.txCount(), 5, "seed, revoke, unpause, setPauser, register");
        assertFalse(IAmCutoverAntimatter(c.antimatter).isApprovedMinter(address(seeder)), "minter revoked");
        _assertRestored("after resume");
        new VerifyAntimatterPoolHarness(path).run();
        vm.removeFile(path);
    }

    // ------------------------------------------------------------------ 5. global pause probe

    function test_fork_globalPause_beforeFreeze_whileFrozen_afterRestore() public {
        if (!_fork()) return;
        string memory path = _tmp("probe");
        assertTrue(_globalPauseWorks(), "before the freeze");
        _freeze(path);
        assertTrue(_globalPauseWorks(), "while frozen");
        new CutoverAntimatterPoolHarness(false, path).run();
        assertTrue(_globalPauseWorks(), "after B's restore");
        vm.removeFile(path);

        // The preview of B probes the same three stages itself (on a fresh fork state).
        vm.createSelectFork(vm.envString("RPC_MAINNET"), FORK_BLOCK);
        CutoverAntimatterPoolHarness pv = new CutoverAntimatterPoolHarness(true, _tmp("probe-preview"));
        pv.run();
        assertEq(pv.globalPauseStageCount(), 3, "preview: before-freeze, frozen, after-restore");
        assertEq(pv.freezeTxCount(), 3, "preview pranked the freeze");

        // And the freeze step's own preview probes before and after.
        vm.createSelectFork(vm.envString("RPC_MAINNET"), FORK_BLOCK);
        FreezeSsv2Harness fp = new FreezeSsv2Harness(true, _tmp("probe-freeze-preview"));
        fp.run();
        assertEq(fp.globalPauseStageCount(), 2, "freeze preview: before-freeze, frozen");
    }

    /// @dev The M2-fix.md triple (setPauser(OWNER) -> pause -> setPauser(Pauser)) would have bricked the breaker:
    ///      a registered, paused SSV2 reverts the Pauser loop. Documents why the story changed the triple.
    function test_fork_planTriple_wouldBrickBreaker() public {
        if (!_fork()) return;
        vm.startPrank(OWNER);
        IPausableLike(c.stableStakerV2).setPauser(OWNER);
        IPausableLike(c.stableStakerV2).pause();
        IPausableLike(c.stableStakerV2).setPauser(c.pauser);
        vm.stopPrank();
        assertFalse(_globalPauseWorks(), "paused + registered SSV2 bricks Pauser.pause()");
    }

    // ------------------------------------------------------------------ 6. run-45 fb-rerun2-spoof

    function test_fork_run45Spoof_attackerCannotObtainAm_rerunRefusesDustPair() public {
        if (!_fork()) return;
        string memory path = _tmp("spoof");
        _freeze(path);
        _bDiesAtTx5(path);
        address recordedPair = vm.parseJsonAddress(vm.readFile(path), ".contracts.AntimatterSusdsPair.address");

        // The attacker (a real staker) tries every AM source: all shut while frozen.
        (uint256 principal,) = I124Staker(c.stableStakerV2).userInfo(DOLA, STAKER);
        vm.startPrank(STAKER);
        vm.expectRevert(ENFORCED_PAUSE);
        I124Staker(c.stableStakerV2).withdraw(DOLA, principal);
        vm.expectRevert(ENFORCED_PAUSE);
        I124Staker(c.stableStakerV2).autoAnnihilate(DOLA);
        vm.expectRevert(ENFORCED_PAUSE);
        I124Staker(c.stableStakerV2).claim(DOLA);
        vm.stopPrank();
        assertEq(IERC20(c.antimatter).totalSupply(), 0, "no AM exists anywhere");

        // Without AM the attacker can create the pair but cannot mint any LP (one-sided mint reverts).
        deal(c.sUSDS, attacker, 1_000e18);
        vm.startPrank(attacker);
        address pair = I124Factory(c.factory).createPair(c.antimatter, c.sUSDS);
        assertEq(pair, recordedPair, "the attacker's pair is the canonical address B recorded");
        IERC20(c.sUSDS).transfer(pair, 1e6);
        vm.expectRevert(); // UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED
        I124Pair(pair).mint(OWNER);
        vm.stopPrank();
        assertEq(IERC20(pair).balanceOf(OWNER), 0, "OWNER holds no spoof LP");

        // The re-run of B refuses to resume onto the attacker's pair.
        CutoverAntimatterPoolHarness b = new CutoverAntimatterPoolHarness(false, path);
        vm.expectRevert(
            bytes(
                "Step 0: the AM/sUSDS pair ALREADY EXISTS and this cutover did not create it - ABORT (griefing risk R1, story 113). Do not seed into a pair someone else created; investigate first."
            )
        );
        b.run();

        // Second layer: even with AM conjured out of thin air (impossible under the freeze), a dust LP to OWNER
        // stays below the recorded liquidity, so B still refuses (run-45 recommendation: LP >= recorded).
        deal(c.antimatter, attacker, 1e18, true);
        vm.startPrank(attacker);
        IERC20(c.antimatter).transfer(pair, 1e18);
        I124Pair(pair).mint(OWNER);
        vm.stopPrank();
        assertGt(IERC20(pair).balanceOf(OWNER), 0, "OWNER holds dust spoof LP");
        assertLt(
            IERC20(pair).balanceOf(OWNER),
            vm.parseJsonUint(vm.readFile(path), ".cutover.liquidity"),
            "dust < recorded liquidity"
        );
        b = new CutoverAntimatterPoolHarness(false, path);
        vm.expectRevert(
            bytes(
                "Step 0: the AM/sUSDS pair ALREADY EXISTS and this cutover did not create it - ABORT (griefing risk R1, story 113). Do not seed into a pair someone else created; investigate first."
            )
        );
        b.run();
        _assertFrozen("after the refused spoof re-run");
        vm.removeFile(path);
    }
}
