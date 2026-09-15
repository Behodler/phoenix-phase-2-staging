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
 * @title StableStakerCutoverDustTest  (story 082)
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
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2)), address(dola), address(ys), plan, maxLossBps, weiSlack
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
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2)), address(dola), address(ys), plan, 0, 20
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
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2)), address(dola), address(ys), plan, 6, 2
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
            ICutoverStaker(address(v1)), ICutoverStaker(address(v2)), address(dola), address(ys), again, 0, 20
        );
    }

    // ------------------------------------------------------------------ story 085: aggregate principal floor

    string constant FLOOR_REVERT = "cutover-post: V2 booked total below pre-migration principal floor (067)";

    /// Clean migration (no loss, no stragglers): the aggregate floor holds exactly and the lockstep holds.
    function test_aggregateFloor_cleanMigrationPasses() public {
        this.doInitiate();
        PoolPlan memory plan = this.doMigrate(CAP);
        assertEq(plan.stragglers.length, 0, "setup: no stragglers");

        (, uint256 P) = v1.migrationInfo(address(dola));
        (,,, uint256 v2Staked) = v2.poolInfo(address(dola));
        uint256 floor = _aggregatePrincipalFloor(P, 0, 0, v2.stakerCount(address(dola)), 0);
        assertEq(P, 2 * BIG, "snapshot is the pre-migration V1 total");
        assertEq(floor, 2 * BIG, "zero loss, zero slack: floor is the full snapshot");
        assertGe(v2Staked, floor, "clean 1:1 migration books the whole snapshot on V2");
        assertEq(ys.principalOf(address(dola), address(v2)), v2Staked, "lockstep: strategy book == V2 book");

        this.doAssert(plan, 0, 0);
    }

    /// Injected haircut on the single-leg path: a vault loss before initiation makes R < P, so every credit
    /// is cut 5 bps. With a 0 bps allowance the post-condition reverts (the per-user loop fires first).
    function test_aggregateFloor_singleLegHaircutReverts() public {
        vault.simulateLoss(1e18); // 5 bps of 2000e18
        this.doInitiate();
        PoolPlan memory plan = this.doMigrate(CAP);
        assertEq(plan.migratable.length, 2, "setup: both stakers migrated this leg");

        vm.expectRevert();
        this.doAssert(plan, 0, 20);

        // Control: the strategy-explained 6 bps allowance passes both the per-user bound and the floor.
        this.doAssert(plan, 6, 20);
    }

    /// Injected haircut applied during the FIRST leg, asserted on a RESUME leg with an empty plan: the
    /// per-user loop sees nothing, the lockstep is equal by construction, and only the aggregate floor
    /// catches the lost principal.
    function test_aggregateFloor_resumeLegHaircutReverts() public {
        vault.simulateLoss(1e18);
        this.doInitiate();
        this.doMigrate(CAP); // first leg: no post-assertion run

        this.doInitiate(); // skipped
        PoolPlan memory again = this.doMigrate(CAP);
        assertEq(again.migratable.length, 0, "setup: resume plan is empty");
        (,,, uint256 v2Staked) = v2.poolInfo(address(dola));
        assertEq(ys.principalOf(address(dola), address(v2)), v2Staked, "lockstep holds - it cannot see the loss");

        vm.expectRevert(bytes(FLOOR_REVERT));
        this.doAssert(again, 0, 20);

        // Control: the same resume leg passes when the loss is within the allowance.
        this.doAssert(again, 6, 20);
    }

    /// Stragglers left behind on V1 do not trip the floor, because their principal is subtracted from the
    /// snapshot. Slack is set to the tightest value that admits the real rounding deficit, and the test
    /// proves an un-subtracted (raw-P) floor with that same slack WOULD have reverted.
    function test_aggregateFloor_stragglersLeftBehindPass() public {
        _stake(dust, 9_000); // 9,000 wei at 1:1
        vault.simulateYield(vault.totalAssets() * 99_999); // share price 1e5: 9,000 wei buys 0 shares
        this.doInitiate();
        this.doMigrate(CAP);
        PoolPlan memory again = this.doMigrate(CAP); // resume plan isolates the aggregate floor
        assertEq(again.stragglers.length, 1, "setup: the dust staker is a straggler");

        (, uint256 P) = v1.migrationInfo(address(dola));
        (,,, uint256 v1Staked) = v1.poolInfo(address(dola));
        (,,, uint256 v2Staked) = v2.poolInfo(address(dola));
        uint256 n = v2.stakerCount(address(dola));
        assertEq(v1Staked, 9_000, "straggler principal stays on V1");
        uint256 deficit = P - v1Staked - v2Staked;
        uint256 slack = (deficit + n - 1) / n; // ceil: smallest per-user slack admitting the deficit
        assertLt(n * slack, deficit + v1Staked, "setup: slack must not also cover the straggler principal");

        assertLt(v2Staked, _aggregatePrincipalFloor(P, 0, 0, n, slack), "a raw-P floor would false-fail");
        this.doAssert(again, 0, slack);
    }

    /// Unit: floor arithmetic - straggler subtraction, bps haircut, saturating slack, loud guards.
    function test_aggregateFloor_unitMath() public {
        assertEq(_aggregatePrincipalFloor(10_000, 1_000, 0, 0, 0), 9_000, "stragglers subtracted");
        assertEq(_aggregatePrincipalFloor(10_000, 0, 61, 0, 0), 9_939, "bps haircut, floored");
        assertEq(_aggregatePrincipalFloor(10_000, 0, 0, 3, 1_000), 7_000, "slack scales with nMigrated");
        assertEq(_aggregatePrincipalFloor(10_000, 0, 0, 20, 1_000), 0, "slack saturates at zero");
        assertEq(_aggregatePrincipalFloor(10_000, 10_000, 0, 0, 0), 0, "all stragglers: nothing due on V2");

        vm.expectRevert(bytes("cutover-post: V1 principalSnapshot is zero"));
        this.floorExt(0, 0, 0, 0, 0);
        vm.expectRevert(bytes("cutover-post: V1 principalSnapshot < V1 straggler principal"));
        this.floorExt(10, 11, 0, 0, 0);
    }

    function floorExt(uint256 p, uint256 s, uint256 b, uint256 n, uint256 w) external pure returns (uint256) {
        return _aggregatePrincipalFloor(p, s, b, n, w);
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
