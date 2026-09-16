// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {StableStakerV1} from "stable-staker/versions/v1/StableStakerV1.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";
import {CrossVersionMigrator} from "stable-staker/CrossVersionMigrator.sol";
import {IStableStakerMigratable} from "stable-staker/interfaces/IStableStakerMigratable.sol";
import {IAntimatter} from "stable-staker/interfaces/IAntimatter.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {IFlax} from "flax-token/IFlax.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {MockERC20} from "@vault/mocks/MockERC20.sol";
import {MockERC4626Vault} from "../lib/vault/test/mocks/MockERC4626Vault.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";
import {
    StableStakerCutoverCore,
    ICutoverStaker,
    ICutoverMigrator
} from "../script/helpers/StableStakerCutoverCore.sol";

/**
 * @title StableStakerCutoverDustTest  (stories 082, 085, 087)
 * @notice Proves the dust predicate and straggler handling that `CutoverStableStakerV2Mainnet` runs,
 *         by inheriting the SAME `StableStakerCutoverCore` the mainnet script inherits and driving it
 *         against the real `StableStakerV1` (frozen), `StableStakerV2`, `CrossVersionMigrator` and
 *         `ERC4626YieldStrategy` bytecode over a mock ERC4626 vault. Modelled on story 080's
 *         rehearsal and story 062's `YsSwapMigrationHardening.t.sol`.
 *
 *         Dust is PLANTED honestly, not by storage writes: a tiny position is staked while the vault
 *         trades 1:1, then the vault's share price is moved (yield or loss) so the tiny position's
 *         migration credit either cannot mint a V2 share (straggler) or rounds to zero (zero credit).
 *
 *         The market-strategy (USDe) branch of the predicate needs a Curve Router NG quote, so it is
 *         covered by `test_fork_marketPredicate`, which skips when RPC_MAINNET is unset, and by the
 *         mainnet preview itself.
 */
contract StableStakerCutoverDustTest is Test, StableStakerCutoverCore {
    MockPhUSD phusd;
    MockERC20 dola;
    MockERC4626Vault vault;
    ERC4626YieldStrategy ys;
    StableStakerV1 v1;
    StableStakerV2 v2;
    CrossVersionMigrator mig;

    address bigA = makeAddr("bigA");
    address bigB = makeAddr("bigB");
    address dust = makeAddr("dust");

    uint256 constant BIG = 1_000e18;
    uint256 constant CAP = 1e16; // 1 cent of an 18-decimal stable, as the mainnet script computes it

    function setUp() public {
        phusd = new MockPhUSD();
        dola = new MockERC20("Dola", "DOLA", 18);
        vault = new MockERC4626Vault("autoDOLA", "aDOLA", address(dola));
        ys = new ERC4626YieldStrategy(address(this), address(dola), address(vault));

        v1 = new StableStakerV1(IFlax(address(phusd)), address(this));
        v2 = new StableStakerV2(IAntimatter(address(new Antimatter(address(this)))), address(this));
        mig = new CrossVersionMigrator(
            IStableStakerMigratable(address(v1)), IStableStakerMigratable(address(v2)), address(this)
        );
        phusd.setMinter(address(v1), true);

        v1.addToken(address(dola));
        ys.setClient(address(v1), true);
        v1.setYieldStrategy(address(dola), IYieldStrategy(address(ys)));

        v2.addToken(address(dola));
        ys.setClient(address(v2), true);
        v2.setYieldStrategy(address(dola), IYieldStrategy(address(ys)));

        v1.setMigrator(address(mig));
        v2.setMigrator(address(mig));

        _stake(bigA, BIG);
        _stake(bigB, BIG);
        vm.warp(block.timestamp + 1 days); // accrue pending phUSD so batchMigrate exercises the mint
    }

    // ------------------------------------------------------------------ external wrappers (expectRevert)

    function doInitiate() external {
        _initiatePool(ICutoverMigrator(address(mig)), ICutoverStaker(address(v1)), address(dola), address(ys));
    }

    function doMigrate(uint256 cap) external returns (PoolPlan memory) {
        return _migratePool(
            ICutoverMigrator(address(mig)), ICutoverStaker(address(v1)), address(dola), address(ys), 1, cap
        );
    }

    function doAssert(PoolPlan memory plan, uint256 maxLossBps, uint256 weiSlack) external view {
        _assertPoolPostMigration(
            ICutoverStaker(address(v1)),
            ICutoverStaker(address(v2)),
            address(dola),
            address(ys),
            address(ys),
            plan,
            maxLossBps,
            maxLossBps,
            weiSlack
        );
    }

    // ------------------------------------------------------------------ tests

    /// credit > 0 but previewDeposit(credit) == 0 -> straggler, left in V1, allow-listed under the cap,
    /// and the batch containing everyone else does NOT revert.
    function test_dustStraggler_leftBehindUnderCap_batchDoesNotRevert() public {
        _stake(dust, 5); // 5 wei, 1:1 -> 5 shares, 5 principal
        vault.simulateYield(vault.totalAssets() * 9); // share price -> 10: 4-5 wei buys 0 shares

        this.doInitiate();
        (, uint256 dustCredit) = _creditOf(dust);
        assertGt(dustCredit, 0, "setup: dust credit must be non-zero");
        (bool fails,) = _depositWouldFail(address(ys), address(dola), dustCredit);
        assertTrue(fails, "predicate: dust credit must be classified as failing the V2 deposit");

        // Negative control: the naive whole-set batch the old rehearsal would send DOES revert.
        address[] memory all = v1.getStakers(address(dola));
        uint256 snap = vm.snapshotState();
        vm.expectRevert(bytes("ERC4626YieldStrategy: no shares received"));
        mig.migrate(address(dola), all);
        vm.revertToState(snap);

        PoolPlan memory plan = this.doMigrate(CAP);
        assertEq(plan.stragglers.length, 1, "exactly one straggler");
        assertEq(plan.stragglers[0], dust, "the straggler is the dust staker");
        assertEq(plan.migratable.length, 2, "both real stakers migrated");
        assertEq(v1.stakerCount(address(dola)), 1, "V1 keeps only the straggler");

        // Loss: exit + re-deposit at price 10 rounds by < 10 wei per leg.
        _assertPoolPostMigration(
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2)), address(dola), address(ys), address(ys), plan, 0, 0, 20
        );
        (uint256 v2Dust,) = v2.userInfo(address(dola), dust);
        assertEq(v2Dust, 0, "straggler has no V2 position");
    }

    /// credit == 0 -> migrated (batchMigrate removes the user, migrator skips depositFor), no revert.
    function test_zeroCreditUser_isMigratedNotStranded() public {
        _stake(dust, 1);
        vault.simulateLoss(1e18); // R < P, so 1 * R / P == 0

        this.doInitiate();
        (uint256 amt, uint256 credit) = _creditOf(dust);
        assertEq(amt, 1, "setup: dust principal");
        assertEq(credit, 0, "setup: dust credit rounds to zero");

        PoolPlan memory plan = this.doMigrate(CAP);
        assertEq(plan.zeroCreditCount, 1, "zero-credit user classified");
        assertEq(plan.stragglers.length, 0, "zero-credit user is NOT a straggler");
        assertEq(plan.migratable.length, 3, "zero-credit user rides a batch");
        assertEq(v1.stakerCount(address(dola)), 0, "V1 fully drained - zero-credit user removed from the set");
        assertEq(v2.stakerCount(address(dola)), 2, "only credited users land on V2");

        // 1e18 loss on 2000e18 = 5 bps socialised by min(R,P)/P.
        _assertPoolPostMigration(
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2)), address(dola), address(ys), address(ys), plan, 6, 6, 2
        );
    }

    /// Straggler principal at or above the cap -> STOP AND REPORT before any migrate call.
    function test_stragglerAboveCap_stopsAndReports() public {
        _stake(dust, 5);
        vault.simulateYield(vault.totalAssets() * 9);
        this.doInitiate();

        vm.expectRevert(
            bytes(
                "STOP AND REPORT: straggler principal is at or above the dust cap - a non-dust position cannot deposit into V2"
            )
        );
        this.doMigrate(5); // cap == straggler principal -> not strictly below
        assertEq(v1.stakerCount(address(dola)), 3, "nothing migrated");
    }

    /// The story-060 surplus (principalOf > totalStaked) is relinquished so initiateMigration cannot
    /// revert "incomplete exit"; the negative control proves the grief is real.
    function test_principalSurplus_relinquishedBeforeInitiate() public {
        dola.mint(address(this), 1e18);
        dola.approve(address(ys), 1e18);
        ys.depositAsOwner(address(dola), 1e18, address(v1));
        assertGt(ys.principalOf(address(dola), address(v1)), 2 * BIG, "setup: surplus booked on V1");

        uint256 snap = vm.snapshotState();
        vm.expectRevert(bytes("StableStaker: incomplete exit"));
        mig.initiateMigration(address(dola));
        vm.revertToState(snap);

        this.doInitiate();
        assertEq(ys.principalOf(address(dola), address(v1)), 0, "V1 principal fully cleared");
        assertEq(uint256(v1.poolState(address(dola))), 1, "V1 Migrating");
    }

    /// Resume legs: re-running initiate and migrate after completion is a no-op, not a revert.
    function test_resumeLegs_areIdempotent() public {
        _stake(dust, 5);
        vault.simulateYield(vault.totalAssets() * 9);
        this.doInitiate();
        this.doMigrate(CAP);

        this.doInitiate(); // skipped
        PoolPlan memory again = this.doMigrate(CAP);
        assertEq(again.migratable.length, 0, "nothing left to migrate on a resume leg");
        assertEq(again.stragglers.length, 1, "straggler still allow-listed on a resume leg");
        _assertPoolPostMigration(
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2)), address(dola), address(ys), address(ys), again, 0, 0, 20
        );
    }

    // ------------------------------------------------------------------ story 091: source != destination

    /// The per-user bound: source + destination when the strategies differ, the bound ONCE when they are the same.
    function test_perUserLossBps_sourcePlusDestination_onceWhenEqual() public view {
        assertEq(_perUserLossBps(address(ys), address(ys), 5, 5), 5, "same strategy: counted once");
        assertEq(_perUserLossBps(address(ys), address(0xBEEF), 5, 5), 10, "different strategies: 5 + 5");
        assertEq(_perUserLossBps(address(ys), address(0xBEEF), 61, 5), 66, "legs add");
    }

    /// V1 exits through the SOURCE strategy and V2 re-deposits into a DIFFERENT destination strategy over another
    /// vault (the DOLA autoDOLA -> sDOLA shape): the plan and migration use the destination, the post-condition uses
    /// the source for V1's booked principal and the exit bound, and the destination for the lockstep.
    function test_sourceDestinationSplit_v2LandsInDestination() public {
        MockERC4626Vault vault2 = new MockERC4626Vault("sDOLA", "sDOLA", address(dola));
        ERC4626YieldStrategy dst = new ERC4626YieldStrategy(address(this), address(dola), address(vault2));
        StableStakerV2 v2b = new StableStakerV2(IAntimatter(address(new Antimatter(address(this)))), address(this));
        CrossVersionMigrator migB = new CrossVersionMigrator(
            IStableStakerMigratable(address(v1)), IStableStakerMigratable(address(v2b)), address(this)
        );
        v2b.addToken(address(dola));
        dst.setClient(address(v2b), true);
        v2b.setYieldStrategy(address(dola), IYieldStrategy(address(dst)));
        v1.setMigrator(address(migB));
        v2b.setMigrator(address(migB));

        _initiatePool(ICutoverMigrator(address(migB)), ICutoverStaker(address(v1)), address(dola), address(ys));
        PoolPlan memory plan = _migratePool(
            ICutoverMigrator(address(migB)), ICutoverStaker(address(v1)), address(dola), address(dst), 25, CAP
        );
        assertEq(plan.migratable.length, 2, "both stakers migrated");
        _assertPoolPostMigration(
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2b)), address(dola), address(ys), address(dst), plan, 5, 5, 1_000
        );
        assertEq(ys.principalOf(address(dola), address(v1)), 0, "V1 books nothing on the source");
        assertEq(ys.principalOf(address(dola), address(v2b)), 0, "V2 never touched the source");
        assertEq(dst.principalOf(address(dola), address(v2b)), 2 * BIG, "V2 principal booked on the destination");
        assertGt(vault2.balanceOf(address(dst)), 0, "destination holds the new vault's shares");

        // Passing the SAME strategy for both sides must fail: V2 books nothing on the source (lockstep).
        vm.expectRevert(bytes("cutover-post: strategy principal for V2 below V2 booked totalStaked (lockstep)"));
        this.doAssertSplit(plan, address(ys), address(ys), address(v2b));
    }

    function doAssertSplit(PoolPlan memory plan, address src, address dst, address v2x) external view {
        _assertPoolPostMigration(
            ICutoverStaker(address(v1)), ICutoverStaker(v2x), address(dola), src, dst, plan, 5, 5, 1_000
        );
    }

    // ------------------------------------------------------------------ story 087: exit-realization bound
    //  Story 085's `P - v1Staked` aggregate floor was replaced (audit-33 L-06): a permissionless V1 `userMigrate`
    //  self-exit made it a false loss alarm. The F-01 coverage it provided (a strategy haircut beyond the bound,
    //  caught on a resume leg with an empty plan) is kept by the realization bound on V1's immutable R / P.

    string constant BOUND_REVERT = "cutover-post: V1 exit realization below loss bound";

    address exiter = makeAddr("selfExiter");
    uint256 constant EXIT = 100e18; // 5% of the pool - far above any wei slack or bps headroom

    function doUserMigrate(address who) external {
        vm.prank(who);
        v1.userMigrate(address(dola));
    }

    /// The pre-085 (story 085) floor, restated inline ONLY to prove the regression scenario would have tripped it.
    function _story085Floor(uint256 bps, uint256 weiSlack) internal view returns (uint256 floor) {
        (, uint256 P) = v1.migrationInfo(address(dola));
        (,,, uint256 v1Staked) = v1.poolInfo(address(dola));
        floor = (P - v1Staked) * (CUTOVER_MAX_BPS - bps) / CUTOVER_MAX_BPS;
        uint256 slack = v2.stakerCount(address(dola)) * weiSlack;
        floor = floor > slack ? floor - slack : 0;
    }

    /// Clean migration (no loss, no stragglers): R == P, the bound holds at 0 bps, the lockstep holds.
    function test_realizationBound_cleanMigrationPasses() public {
        this.doInitiate();
        PoolPlan memory plan = this.doMigrate(CAP);
        assertEq(plan.stragglers.length, 0, "setup: no stragglers");

        (uint256 R, uint256 P) = v1.migrationInfo(address(dola));
        assertEq(P, 2 * BIG, "snapshot is the pre-migration V1 total");
        assertTrue(_exitRealizationWithinBound(R, P, 0, 0), "zero loss passes a 0 bps, 0 wei bound");
        (,,, uint256 v2Staked) = v2.poolInfo(address(dola));
        assertEq(ys.principalOf(address(dola), address(v2)), v2Staked, "lockstep: strategy book == V2 book");

        this.doAssert(plan, 0, 0);
    }

    /// (i) AUDIT-33 L-06 REGRESSION. A staker self-exits via the permissionless `userMigrate` between
    /// `initiateMigration` and `migrate`; everyone else migrates cleanly. Both post-condition shapes pass: the
    /// fresh leg re-planned from live state, and the resume/verifier leg (empty plan) after the broadcast-shaped
    /// migrate whose user list was computed BEFORE the exit. The old story-085 floor fails the same state.
    function test_selfExitBetweenInitiateAndMigrate_passes() public {
        _stake(exiter, EXIT);
        this.doInitiate();
        PoolPlan memory planned = _planPool(ICutoverStaker(address(v1)), address(dola), address(ys));
        assertEq(planned.migratable.length, 3, "setup: the exiter was planned for migration");

        uint256 walletBefore = dola.balanceOf(exiter);
        this.doUserMigrate(exiter);
        assertGt(dola.balanceOf(exiter) - walletBefore, EXIT - 1e3, "self-exit paid the credit to the wallet");

        // Broadcast shape: the migrate tx carries the pre-exit list; V1 batchMigrate skips the exited user.
        mig.migrate(address(dola), planned.migratable);
        assertEq(v1.stakerCount(address(dola)), 0, "every staker left V1 (migrated or self-exited)");
        (uint256 inV2,) = v2.userInfo(address(dola), exiter);
        assertEq(inV2, 0, "the exiter never reached V2 - by their own choice");

        (,,, uint256 v2Staked) = v2.poolInfo(address(dola));
        assertLt(v2Staked, _story085Floor(0, 20), "the story-085 floor would have raised a false loss alarm here");

        PoolPlan memory live = this.doMigrate(CAP); // resume leg: empty plan
        assertEq(live.migratable.length, 0, "setup: resume plan is empty");
        this.doAssert(live, 0, 20);
        this.doAssert(live, 5, 1_000); // the mainnet ERC4626 parameters (story 088: 5 bps)
    }

    /// (i-b) Same self-exit, fresh leg: `_migratePool` re-plans from live state after the exit and asserts.
    function test_selfExitBeforeMigrateLeg_freshLegPasses() public {
        _stake(exiter, EXIT);
        this.doInitiate();
        this.doUserMigrate(exiter);
        PoolPlan memory plan = this.doMigrate(CAP);
        assertEq(plan.migratable.length, 2, "the exiter is no longer planned");
        this.doAssert(plan, 0, 20);
    }

    /// (ii) Self-exit PLUS a strategy haircut beyond the bound: the realization bound still fails closed.
    function test_selfExitWithBeyondBoundHaircut_reverts() public {
        _stake(exiter, EXIT);
        vault.simulateLoss(21e17); // 10 bps of 2100e18
        this.doInitiate();
        this.doUserMigrate(exiter);
        this.doMigrate(CAP);
        PoolPlan memory again = this.doMigrate(CAP); // resume/verifier shape: the per-user loop sees nothing

        vm.expectRevert(bytes(BOUND_REVERT));
        this.doAssert(again, 5, 1_000);
    }

    /// Single-leg haircut: a vault loss before initiation makes R < P, so every credit is cut 5 bps. With a
    /// 0 bps allowance the post-condition reverts; 6 bps passes.
    function test_realizationBound_singleLegHaircutReverts() public {
        vault.simulateLoss(1e18); // 5 bps of 2000e18
        this.doInitiate();
        PoolPlan memory plan = this.doMigrate(CAP);
        assertEq(plan.migratable.length, 2, "setup: both stakers migrated this leg");

        vm.expectRevert();
        this.doAssert(plan, 0, 20);

        this.doAssert(plan, 6, 20);
    }

    /// (iii) F-01 coverage kept: haircut applied during the FIRST leg, asserted on a RESUME leg with an empty
    /// plan. The per-user loop sees nothing, the lockstep is equal by construction, and the realization bound
    /// catches the lost principal.
    function test_realizationBound_resumeLegHaircutReverts() public {
        vault.simulateLoss(2e18); // 10 bps
        this.doInitiate();
        this.doMigrate(CAP); // first leg: no post-assertion run

        this.doInitiate(); // skipped
        PoolPlan memory again = this.doMigrate(CAP);
        assertEq(again.migratable.length, 0, "setup: resume plan is empty");
        (,,, uint256 v2Staked) = v2.poolInfo(address(dola));
        assertEq(ys.principalOf(address(dola), address(v2)), v2Staked, "lockstep holds - it cannot see the loss");

        vm.expectRevert(bytes(BOUND_REVERT));
        this.doAssert(again, 5, 1_000); // the mainnet ERC4626 bound (5 bps): 10 bps is beyond it

        this.doAssert(again, 11, 20);
    }

    /// (iv) A 4 bps haircut is within the mainnet 5 bps ERC4626 bound on a resume leg.
    function test_realizationBound_withinBoundHaircutPasses() public {
        vault.simulateLoss(8e17); // 4 bps of 2000e18
        this.doInitiate();
        this.doMigrate(CAP);
        PoolPlan memory again = this.doMigrate(CAP);
        (uint256 R, uint256 P) = v1.migrationInfo(address(dola));
        assertLt(R, P, "setup: the exit realized less than the snapshot");
        this.doAssert(again, 5, 1_000);
    }

    /// Stragglers left behind on V1 do not trip the bound: R / P is pool-wide and says nothing about who stayed.
    function test_realizationBound_stragglersLeftBehindPass() public {
        _stake(dust, 9_000); // 9,000 wei at 1:1
        vault.simulateYield(vault.totalAssets() * 99_999); // share price 1e5: 9,000 wei buys 0 shares
        this.doInitiate();
        this.doMigrate(CAP);
        PoolPlan memory again = this.doMigrate(CAP);
        assertEq(again.stragglers.length, 1, "setup: the dust staker is a straggler");
        (,,, uint256 v1Staked) = v1.poolInfo(address(dola));
        assertEq(v1Staked, 9_000, "straggler principal stays on V1");
        this.doAssert(again, 0, 1e5);
    }

    /// (v) Unit: the bound's arithmetic - exact boundary, pool-level wei slack, R > P capped at par, loud guards.
    function test_realizationBound_unitMath() public {
        assertTrue(_exitRealizationWithinBound(10_000, 10_000, 0, 0), "par passes 0 bps");
        assertFalse(_exitRealizationWithinBound(9_999, 10_000, 0, 0), "1 bps short fails 0 bps");
        assertTrue(_exitRealizationWithinBound(9_995, 10_000, 5, 0), "exactly at the 5 bps boundary passes");
        assertFalse(_exitRealizationWithinBound(9_994, 10_000, 5, 0), "6 bps short fails 5 bps");
        assertTrue(_exitRealizationWithinBound(9_939, 10_000, 61, 0), "61 bps boundary (market strategy)");
        assertFalse(_exitRealizationWithinBound(9_938, 10_000, 61, 0), "62 bps short fails 61 bps");
        assertTrue(_exitRealizationWithinBound(20_000, 10_000, 0, 0), "R > P is capped at par and passes");
        assertTrue(_exitRealizationWithinBound(0, 10_000, 10_000, 0), "a 100% allowance admits R == 0");
        assertFalse(_exitRealizationWithinBound(0, 10_000, 9_999, 0), "R == 0 fails any smaller allowance");
        // Pool-level wei slack: admits exit rounding, once, and nothing more.
        assertTrue(_exitRealizationWithinBound(1e24 - 7, 1e24, 0, 7), "7 wei of exit rounding within 7 wei slack");
        assertFalse(_exitRealizationWithinBound(1e24 - 8, 1e24, 0, 7), "8 wei short fails 7 wei slack");
        // No rounding: 1e18-scale values at the exact bps boundary.
        assertTrue(_exitRealizationWithinBound(1e24 - 5e20, 1e24, 5, 0), "large values, exact boundary");
        assertFalse(_exitRealizationWithinBound(1e24 - 5e20 - 1, 1e24, 5, 0), "large values, 1 wei past the boundary");
        assertTrue(_exitRealizationWithinBound(1e24 - 5e20 - 1000, 1e24, 5, 1_000), "mainnet params: bps + 1000 wei");
        assertFalse(_exitRealizationWithinBound(1e24 - 5e20 - 1001, 1e24, 5, 1_000), "mainnet params: 1 wei past");

        vm.expectRevert(bytes("cutover-post: V1 principalSnapshot is zero"));
        this.boundExt(0, 0, 0);
        vm.expectRevert(bytes("cutover-post: maxLossBps above MAX_BPS"));
        this.boundExt(1, 1, 10_001);
    }

    function boundExt(uint256 r, uint256 p, uint256 b) external pure returns (bool) {
        return _exitRealizationWithinBound(r, p, b, 0);
    }

    /// Unit: the ERC4626 predicate boundary at share price 10.
    function test_erc4626Predicate_boundary() public {
        vault.simulateYield(vault.totalAssets() * 9);
        (bool zero,) = _depositWouldFail(address(ys), address(dola), 0);
        assertFalse(zero, "credit 0 is never a deposit failure (depositFor is skipped)");
        (bool one,) = _depositWouldFail(address(ys), address(dola), 1);
        assertTrue(one, "1 wei at price 10 mints 0 shares");
        (bool fifty,) = _depositWouldFail(address(ys), address(dola), 50);
        assertFalse(fifty, "50 wei at price 10 mints shares");
    }

    /// Market branch against live mainnet (USDe on ERC4626MarketYieldStrategy via Curve Router NG).
    function test_fork_marketPredicate() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_975_000);
        address ysUsde = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;
        address usde = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
        address ysUsdc = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83;
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        (bool oneWei,) = _depositWouldFail(ysUsde, usde, 1);
        assertTrue(oneWei, "1 wei USDe: haircut credit is 0");
        (bool real,) = _depositWouldFail(ysUsde, usde, 1_000e18);
        assertFalse(real, "1000 USDe deposits through the AMM within the 30 bps floor");
        (bool usdcReal,) = _depositWouldFail(ysUsdc, usdc, 1_000e6);
        assertFalse(usdcReal, "1000 USDC deposits into autoUSDC");
    }

    // ------------------------------------------------------------------ helpers

    function _stake(address who, uint256 amount) internal {
        dola.mint(who, amount);
        vm.startPrank(who);
        dola.approve(address(v1), amount);
        v1.stake(address(dola), amount);
        vm.stopPrank();
    }

    function _creditOf(address who) internal view returns (uint256 amount, uint256 credit) {
        (amount,) = v1.userInfo(address(dola), who);
        credit = _migrationCredit(ICutoverStaker(address(v1)), address(dola), amount);
    }
}
