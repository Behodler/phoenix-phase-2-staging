// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";
import {StableStakerMigrator} from "stable-staker/StableStakerMigrator.sol";
import {IStableStaker} from "stable-staker/interfaces/IStableStaker.sol";
import {IFlax} from "flax-token/IFlax.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {MockERC20} from "@vault/mocks/MockERC20.sol";
import {MockERC4626Vault} from "../lib/vault/test/mocks/MockERC4626Vault.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";

/**
 * @title YsSwapMigrationHardeningTest
 * @notice Story 062 (YS-09) hardening proof. Builds a self-contained local model of the YS-swap
 *         migration suite (real StableStaker + StableStakerMigrator + ERC4626YieldStrategy over a
 *         mock ERC4626 vault) and exercises the two invariants the hardened scripts rely on:
 *
 *           (a) A re-run after a simulated mid-suite revert at `setYieldStrategy` is a no-op up to
 *               the failure point and then completes. We drive the ResetAndRewire state machine
 *               through finalizeAndReset -> setYieldStrategy, simulate a halt AFTER setYieldStrategy
 *               but before setMigrator, then RE-RUN the whole step using the same guard predicates
 *               the script uses (poolState == Migrating? / yieldStrategy != V2? / migrator != m?).
 *               The re-run must skip the already-done transitions (asserted via revert-on-naive-retry)
 *               and complete the remainder.
 *
 *           (b) stake() reverts while the staker is paused (the grief surface the pause closes), and
 *               the same stake() succeeds once unpaused.
 *
 *         No mainnet RPC / ledger is required — this runs under plain `forge test`.
 */
contract YsSwapMigrationHardeningTest is Test {
    // Pool lifecycle mirror (StableStaker.PoolState).
    enum PoolState { Active, Migrating }

    MockPhUSD phusd;
    MockERC20 dola;
    MockERC4626Vault vaultV1;
    MockERC4626Vault vaultV2;
    ERC4626YieldStrategy ysV1;
    ERC4626YieldStrategy ysV2;

    StableStaker original;
    StableStaker temp;
    StableStakerMigrator migrator1; // original -> temp
    StableStakerMigrator migrator2; // temp -> original

    address owner = address(this);
    address pauserEOA = makeAddr("pauserEOA");
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");

    uint256 constant STAKE = 1_000e18;

    function setUp() public {
        phusd = new MockPhUSD();
        dola = new MockERC20("Dola", "DOLA", 18);

        vaultV1 = new MockERC4626Vault("V1 Shares", "vV1", address(dola));
        vaultV2 = new MockERC4626Vault("V2 Shares", "vV2", address(dola));

        ysV1 = new ERC4626YieldStrategy(owner, address(dola), address(vaultV1));
        ysV2 = new ERC4626YieldStrategy(owner, address(dola), address(vaultV2));

        original = new StableStaker(IFlax(address(phusd)), owner);
        temp = new StableStaker(IFlax(address(phusd)), owner);

        migrator1 = new StableStakerMigrator(
            IStableStaker(address(original)), IStableStaker(address(temp)), owner
        );
        migrator2 = new StableStakerMigrator(
            IStableStaker(address(temp)), IStableStaker(address(original)), owner
        );

        // phUSD minter wiring so reward settle paths can mint.
        phusd.setMinter(address(original), true);
        phusd.setMinter(address(temp), true);

        // Register tokens.
        original.addToken(address(dola));
        temp.addToken(address(dola));

        // Wire ysV1 on original and let a user stake so there is real principal to migrate.
        ysV1.setClient(address(original), true);
        original.setYieldStrategy(address(dola), IYieldStrategy(address(ysV1)));

        // Pre-wire ysV2 for the post-reset swap.
        ysV2.setClient(address(original), true);

        // Fund + stake a user on original.
        dola.mint(userA, STAKE);
        vm.startPrank(userA);
        dola.approve(address(original), STAKE);
        original.stake(address(dola), STAKE);
        vm.stopPrank();

        assertEq(_totalStaked(original, address(dola)), STAKE, "setup: original totalStaked");
        assertEq(ysV1.principalOf(address(dola), address(original)), STAKE, "setup: ysV1 principal");
    }

    // -----------------------------------------------------------------------------------------
    // (a) Resume idempotency: re-run after a halt at setYieldStrategy is a no-op then completes.
    // -----------------------------------------------------------------------------------------
    function test_resume_after_setYieldStrategy_halt_is_noop_then_completes() public {
        // ---- Leg 1: drain original -> temp so original is empty (precondition for reset) ----
        address[] memory users = new address[](1);
        users[0] = userA;
        original.setMigrator(address(migrator1));
        temp.setMigrator(address(migrator1));
        migrator1.initiateMigration(address(dola));
        migrator1.migrate(address(dola), users);

        assertEq(original.stakerCount(address(dola)), 0, "leg1: original drained");
        assertEq(_poolState(original, address(dola)), uint8(PoolState.Migrating), "leg1: original Migrating");

        // ============ ResetAndRewire — FIRST (interrupted) run ============
        // Step 1: finalizeAndReset (guard: skip if already Active).
        if (_poolState(original, address(dola)) == uint8(PoolState.Migrating)) {
            original.finalizeAndReset(address(dola));
        }
        assertEq(_poolState(original, address(dola)), uint8(PoolState.Active), "reset: pool Active");

        // Step 2: setYieldStrategy to V2 (guard: skip if already V2).
        if (address(original.yieldStrategy(address(dola))) != address(ysV2)) {
            original.setYieldStrategy(address(dola), IYieldStrategy(address(ysV2)));
        }
        assertEq(address(original.yieldStrategy(address(dola))), address(ysV2), "reset: ysV2 wired");

        // *** SIMULATED MID-SUITE HALT here: the run dies AFTER setYieldStrategy but BEFORE
        //     setMigrator(migrator2). migrator2 is therefore NOT yet set. ***
        assertTrue(original.migrator() != address(migrator2), "halt: migrator2 not yet set");

        // ---- Prove a NAIVE (unguarded) retry of the completed transitions reverts ----
        // finalizeAndReset on an Active pool reverts "pool not migrating".
        vm.expectRevert(bytes("StableStaker: pool not migrating"));
        original.finalizeAndReset(address(dola));

        // setYieldStrategy swapping an already-V2 strategy in place: the empty-pool gate still passes
        // (totalStaked == 0) but it would needlessly re-run the swap. The guard avoids it entirely;
        // here we just assert the guard predicate is now false (i.e. a guarded re-run SKIPS it).
        assertFalse(
            address(original.yieldStrategy(address(dola))) != address(ysV2),
            "guard: setYieldStrategy predicate false on resume (would skip)"
        );

        // ============ ResetAndRewire — SECOND (resume) run, using the script's guards ============
        uint256 ysV2PrincipalBefore = ysV2.principalOf(address(dola), address(original));

        // Step 1 guard: pool already Active -> SKIP (no-op, no revert).
        if (_poolState(original, address(dola)) == uint8(PoolState.Migrating)) {
            original.finalizeAndReset(address(dola));
            revert("resume should have skipped finalizeAndReset");
        }
        // Step 2 guard: already V2 -> SKIP (no-op).
        if (address(original.yieldStrategy(address(dola))) != address(ysV2)) {
            original.setYieldStrategy(address(dola), IYieldStrategy(address(ysV2)));
            revert("resume should have skipped setYieldStrategy");
        }
        // Step 3 guard: migrator not yet migrator2 -> EXECUTE (this is where the resume picks up).
        if (original.migrator() != address(migrator2)) {
            original.setMigrator(address(migrator2));
        }
        if (temp.migrator() != address(migrator2)) {
            temp.setMigrator(address(migrator2));
        }

        // Resume completed the remainder without touching the already-done state.
        assertEq(original.migrator(), address(migrator2), "resume: migrator2 set on original");
        assertEq(temp.migrator(), address(migrator2), "resume: migrator2 set on temp");
        assertEq(
            ysV2.principalOf(address(dola), address(original)),
            ysV2PrincipalBefore,
            "resume: ysV2 principal unchanged by skipped setYieldStrategy"
        );
        assertEq(_poolState(original, address(dola)), uint8(PoolState.Active), "resume: pool still Active");
    }

    // -----------------------------------------------------------------------------------------
    // (b) Pause closes the stake() grief surface.
    // -----------------------------------------------------------------------------------------
    function test_stake_reverts_while_paused_and_succeeds_after_unpause() public {
        // Record + take pauser role (mirrors deploy step), then pause.
        address recordedPauser = original.pauser();
        if (recordedPauser != owner) original.setPauser(owner);
        if (!original.paused()) original.pause();
        assertTrue(original.paused(), "paused");

        // A would-be griefer cannot stake (even 1 wei) while paused -> empty-pool gate stays closed.
        dola.mint(userB, STAKE);
        vm.startPrank(userB);
        dola.approve(address(original), STAKE);
        vm.expectRevert(); // OZ Pausable: EnforcedPause()
        original.stake(address(dola), 1);
        vm.stopPrank();

        // Cleanup: unpause + restore the recorded pauser (mirrors PostMigrationCleanup).
        if (original.paused()) original.unpause();
        if (original.pauser() != recordedPauser) original.setPauser(recordedPauser);
        assertFalse(original.paused(), "unpaused");
        assertEq(original.pauser(), recordedPauser, "pauser restored");

        // Same stake now succeeds.
        vm.startPrank(userB);
        original.stake(address(dola), STAKE);
        vm.stopPrank();
        assertGt(original.stakerCount(address(dola)), 1, "userB staked after unpause");
    }

    // -------------------------------- helpers --------------------------------
    function _poolState(StableStaker s, address token) internal view returns (uint8) {
        return uint8(s.poolState(token));
    }

    function _totalStaked(StableStaker s, address token) internal view returns (uint256) {
        (, , , uint256 totalStaked) = s.poolInfo(token);
        return totalStaked;
    }
}
