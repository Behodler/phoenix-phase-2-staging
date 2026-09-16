// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "@forge-std/console.sol";

/**
 * @title StableStakerCutoverCore
 * @notice Story 082. The V1 -> V2 migration leg of the mainnet StableStaker cutover, factored out
 *         of `script/CutoverStableStakerV2Mainnet.s.sol` so that the DUST PREDICATE and the
 *         STRAGGLER handling are exercised by `test/StableStakerCutoverDust.t.sol` against the real
 *         `StableStakerV1` / `StableStakerV2` / `CrossVersionMigrator` / `ERC4626YieldStrategy`
 *         bytecode, rather than by a copy of the logic that could drift from what the mainnet
 *         script runs.
 *
 * @dev WHY DUST CAN GRIEF THE CUTOVER, AND WHAT COUNTS AS DUST
 *
 *      `CrossVersionMigrator.migrate(token, users)` is one transaction: `V1.batchMigrate` exits every
 *      listed user, then `V2.depositFor` is called once per user whose credit is non-zero. A single
 *      `depositFor` revert reverts the whole batch. Every V2 deposit routes through the pool's yield
 *      strategy, so the revert surface is exactly the strategy's deposit path plus V2's own
 *      `require(credited > 0, "StableStaker: nothing credited")`.
 *
 *      Credit is computed EXACTLY as `StableStakerV1._exitPosition` does it:
 *          credit = amount * min(R, P) / P            (R, P from V1.migrationInfo(token))
 *
 *      Classification, per staker (derived from reading the strategy code at the pinned lib/vault):
 *
 *        ZERO CREDIT (credit == 0). `migrate` skips the `depositFor`, and V1 `_exitPosition` still
 *          zeroes the position and REMOVES the user from V1's staker set (the old DeployMocks comment
 *          claiming they stay in the set is wrong - see StableStakerV1._exitPosition). Including them
 *          in a batch is therefore safe and guarantees strict progress. They are MIGRATED.
 *
 *        STRAGGLER (credit > 0 but the V2 deposit would revert). Left in V1, named, and allow-listed
 *          under a per-token value cap. The predicate, by strategy type:
 *
 *          ERC4626YieldStrategy._acquireShares:
 *              shares   = vault.deposit(credit)          -> require(shares > 0, "no shares received")
 *              credited = vault.convertToAssets(shares)  -> V2 require(credited > 0, "nothing credited")
 *            ERC4626 guarantees previewDeposit(x) <= deposit(x) in the same block, so
 *              previewDeposit(credit) == 0 || convertToAssets(previewDeposit(credit)) == 0  => STRAGGLER.
 *
 *          ERC4626MarketYieldStrategy._acquireShares:
 *              credited = credit * (MAX_BPS - slippageToleranceBps) / MAX_BPS
 *              minOut   = vault.convertToShares(credited)
 *              shares   = ammAdapter.swap(token, vault, credit, minOut) -> require(shares > 0)
 *            so
 *              credited == 0                                          => STRAGGLER ("nothing credited")
 *              router.get_dy(route, credit) == 0 or reverts            => STRAGGLER ("no shares received")
 *              router.get_dy(route, credit) <  minOut                  => STRAGGLER (router minOut revert)
 *            `get_dy` is the Curve Router NG quote over the adapter's own configured route, read in the
 *            same block the batch is planned in.
 *
 *        MIGRATABLE otherwise.
 *
 *      STRAGGLER CAP. The sum of the stragglers' V1 principal (not their smaller credit - the larger
 *      number is the conservative one) must be strictly below `cap`. Anything at or above it reverts
 *      "STOP AND REPORT": a position that size failing to deposit is not dust, it is a broken
 *      strategy, and a human must look before any mint right is revoked.
 */

interface ICutoverStaker {
    function poolInfo(address token)
        external
        view
        returns (uint256 ratePerSecond, uint256 accPerShare, uint256 lastRewardTime, uint256 totalStaked);
    function userInfo(address token, address user) external view returns (uint256 amount, uint256 rewardDebt);
    function poolState(address token) external view returns (uint8);
    function migrationInfo(address token) external view returns (uint256 realized, uint256 principalSnapshot);
    function stakerCount(address token) external view returns (uint256);
    function getStakersRange(address token, uint256 start, uint256 end) external view returns (address[] memory);
}

interface ICutoverStrategy {
    function principalOf(address token, address account) external view returns (uint256);
    function vault() external view returns (address);
    function slippageToleranceBps() external view returns (uint256);
    function relinquishPrincipalAsOwner(address client, uint256 amount) external;
}

interface ICutoverVault {
    function previewDeposit(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface ICutoverCurveAdapter {
    function router() external view returns (address);
    function getRoute(address tokenIn, address tokenOut)
        external
        view
        returns (address[11] memory path, uint256[5][5] memory swapParams, address[5] memory pools, bool configured);
}

interface ICutoverCurveRouterNG {
    function get_dy(address[11] calldata route, uint256[5][5] calldata swapParams, uint256 amount, address[5] calldata pools)
        external
        view
        returns (uint256);
}

interface ICutoverMigrator {
    function initiateMigration(address token) external;
    function migrate(address token, address[] calldata users) external;
}

abstract contract StableStakerCutoverCore {
    uint256 internal constant POOL_ACTIVE = 0;
    uint256 internal constant POOL_MIGRATING = 1;
    uint256 internal constant CUTOVER_MAX_BPS = 10_000;

    /// @notice The migration plan for one pool, computed from LIVE state (never a snapshot).
    struct PoolPlan {
        address[] migratable; // credit > 0 and deposit-safe, PLUS every zero-credit user
        uint256[] migratablePre; // V1 principal of each migratable user, for the per-user loss check
        uint256[] migratableCredit;
        address[] stragglers; // credit > 0 but the V2 deposit would revert
        uint256[] stragglerAmount;
        uint256[] stragglerCredit;
        uint256 zeroCreditCount;
        uint256 migratableCreditTotal;
        uint256 stragglerAmountTotal;
    }

    // =====================================================================
    //  Strategy introspection
    // =====================================================================

    /// @dev Non-zero iff `strategy` is an `ERC4626MarketYieldStrategy` (it exposes `ammAdapter()`).
    ///      A plain `ERC4626YieldStrategy` has no such getter, so the staticcall fails.
    function _marketAdapter(address strategy) internal view returns (address adapter) {
        (bool ok, bytes memory data) = strategy.staticcall(abi.encodeWithSignature("ammAdapter()"));
        if (!ok || data.length < 32) return address(0);
        adapter = abi.decode(data, (address));
    }

    /// @dev Curve Router NG quote over the adapter's configured `tokenIn -> tokenOut` route. Returns
    ///      (false, 0) when the route is unconfigured or the quote reverts.
    function _curveQuote(address adapter, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bool ok, uint256 out)
    {
        (address[11] memory path, uint256[5][5] memory params, address[5] memory pools, bool configured) =
            ICutoverCurveAdapter(adapter).getRoute(tokenIn, tokenOut);
        if (!configured) return (false, 0);
        address router = ICutoverCurveAdapter(adapter).router();
        try ICutoverCurveRouterNG(router).get_dy(path, params, amountIn, pools) returns (uint256 q) {
            return (true, q);
        } catch {
            return (false, 0);
        }
    }

    // =====================================================================
    //  The dust predicate
    // =====================================================================

    /// @notice Whether a V2 `depositFor(token, user, credit)` would revert on the strategy's deposit
    ///         path. `credit == 0` is NOT a failure: the migrator never calls `depositFor` for it.
    /// @return fails True when the deposit would revert.
    /// @return reason A short tag naming the revert that would fire.
    function _depositWouldFail(address strategy, address token, uint256 credit)
        internal
        view
        returns (bool fails, string memory reason)
    {
        if (credit == 0) return (false, "");
        address vault = ICutoverStrategy(strategy).vault();
        address adapter = _marketAdapter(strategy);

        if (adapter == address(0)) {
            // ERC4626YieldStrategy
            uint256 shares = ICutoverVault(vault).previewDeposit(credit);
            if (shares == 0) return (true, "ERC4626: previewDeposit == 0 (no shares received)");
            if (ICutoverVault(vault).convertToAssets(shares) == 0) {
                return (true, "ERC4626: credited principal == 0 (nothing credited)");
            }
            return (false, "");
        }

        // ERC4626MarketYieldStrategy
        uint256 bps = ICutoverStrategy(strategy).slippageToleranceBps();
        uint256 credited = credit * (CUTOVER_MAX_BPS - bps) / CUTOVER_MAX_BPS;
        if (credited == 0) return (true, "market: haircut credit == 0 (nothing credited)");
        uint256 minOut = ICutoverVault(vault).convertToShares(credited);
        (bool quoted, uint256 quote) = _curveQuote(adapter, token, vault, credit);
        if (!quoted) return (true, "market: AMM quote unavailable or reverted");
        if (quote == 0) return (true, "market: AMM quote == 0 (no shares received)");
        if (quote < minOut) return (true, "market: AMM quote below strategy minOut");
        return (false, "");
    }

    /// @dev `amount * min(R, P) / P`, byte-for-byte the V1 `_exitPosition` credit formula.
    function _migrationCredit(ICutoverStaker v1, address token, uint256 amount) internal view returns (uint256) {
        (uint256 R, uint256 P) = v1.migrationInfo(token);
        if (P == 0) return 0;
        uint256 S = R < P ? R : P;
        return amount * S / P;
    }

    // =====================================================================
    //  Planning
    // =====================================================================

    /// @notice Classify every live V1 staker of `token`. Requires the pool to be Migrating (so R and
    ///         P exist). Enumerates on-chain via `getStakersRange` - never a stale snapshot.
    function _planPool(ICutoverStaker v1, address token, address strategy) internal view returns (PoolPlan memory plan) {
        require(v1.poolState(token) == POOL_MIGRATING, "cutover: planning a pool that is not Migrating");
        uint256 n = v1.stakerCount(token);
        address[] memory users = v1.getStakersRange(token, 0, n);

        plan.migratable = new address[](n);
        plan.migratablePre = new uint256[](n);
        plan.migratableCredit = new uint256[](n);
        plan.stragglers = new address[](n);
        plan.stragglerAmount = new uint256[](n);
        plan.stragglerCredit = new uint256[](n);
        uint256 m;
        uint256 s;

        for (uint256 i = 0; i < n; i++) {
            (uint256 amount,) = v1.userInfo(token, users[i]);
            uint256 credit = _migrationCredit(v1, token, amount);
            if (credit == 0) {
                plan.zeroCreditCount++;
            } else {
                (bool fails,) = _depositWouldFail(strategy, token, credit);
                if (fails) {
                    plan.stragglers[s] = users[i];
                    plan.stragglerAmount[s] = amount;
                    plan.stragglerCredit[s] = credit;
                    plan.stragglerAmountTotal += amount;
                    s++;
                    continue;
                }
            }
            plan.migratable[m] = users[i];
            plan.migratablePre[m] = amount;
            plan.migratableCredit[m] = credit;
            plan.migratableCreditTotal += credit;
            m++;
        }

        _shrink(plan.migratable, m);
        _shrink(plan.migratablePre, m);
        _shrink(plan.migratableCredit, m);
        _shrink(plan.stragglers, s);
        _shrink(plan.stragglerAmount, s);
        _shrink(plan.stragglerCredit, s);
    }

    function _shrink(address[] memory a, uint256 len) private pure {
        assembly {
            mstore(a, len)
        }
    }

    function _shrink(uint256[] memory a, uint256 len) private pure {
        assembly {
            mstore(a, len)
        }
    }

    function _logPlan(address token, PoolPlan memory plan) internal view {
        console.log("  plan (token / migratable / zero-credit):", token, plan.migratable.length, plan.zeroCreditCount);
        console.log("  plan stragglers (count / principal total):", plan.stragglers.length, plan.stragglerAmountTotal);
        for (uint256 i = 0; i < plan.stragglers.length; i++) {
            console.log("    STRAGGLER (address / V1 principal / credit):");
            console.log("     ", plan.stragglers[i], plan.stragglerAmount[i], plan.stragglerCredit[i]);
        }
    }

    // =====================================================================
    //  Initiation (V1 side), with the incomplete-exit griefs handled
    // =====================================================================

    /// @notice Clear the V1 principal surplus and initiate V1's terminal migration for `token`.
    ///         Idempotent: a pool already Migrating is left alone.
    /// @dev    `StableStakerV1.initiateMigration` exits `P = totalStaked` and then requires the
    ///         strategy's booked principal for V1 to be exactly zero ("StableStaker: incomplete exit").
    ///         `AYieldStrategy._withdrawInternal` deducts the requested amount from the booked
    ///         principal EXACTLY (clamped to what is booked), independent of share rounding, so:
    ///           - principalOf > P  (story 060 skim surplus)  -> remainder == principalOf - P. Cleared
    ///             here with `relinquishPrincipalAsOwner(v1, principalOf - P)`, both reads taken in the
    ///             same block, never rounded up, and only when > 0 (the call reverts on 0).
    ///           - principalOf <= P -> the withdraw clamps, principal lands on exactly 0, the exit
    ///             realizes less (R < P) and the loss is socialised pro-rata by `min(R,P)/P`. Logged.
    ///         A 1-wei remainder cannot arise from rounding: the principal ledger is never rounded.
    ///         While V1 is paused nothing but the owner can move V1's booked principal, so the two
    ///         reads cannot be invalidated between planning and the initiate transaction.
    ///
    ///         Market strategy exit: `_disposeShares` sells `convertToShares(P)` vault shares through
    ///         the AMM with `minOut = convertToAssets(shares) * (MAX_BPS - bps) / MAX_BPS`. If the AMM
    ///         cannot honour that floor the router reverts and so does `initiateMigration`. That is not
    ///         dust - it is market depth - so it is pre-quoted here and fails with STOP AND REPORT
    ///         before any transaction, instead of as an anonymous router revert.
    function _initiatePool(ICutoverMigrator migrator, ICutoverStaker v1, address token, address strategy) internal {
        if (v1.poolState(token) == POOL_MIGRATING) {
            (uint256 R0, uint256 P0) = v1.migrationInfo(token);
            console.log("  V1 pool already Migrating - initiate skipped (token / R / P):", token, R0, P0);
            return;
        }

        (,,, uint256 staked) = v1.poolInfo(token);
        uint256 recorded = ICutoverStrategy(strategy).principalOf(token, address(v1));
        if (recorded > staked) {
            uint256 surplus = recorded - staked;
            ICutoverStrategy(strategy).relinquishPrincipalAsOwner(address(v1), surplus);
            console.log("  relinquished V1 principal surplus (token / surplus):", token, surplus);
        } else if (recorded < staked) {
            console.log("  WARNING: V1 booked principal < totalStaked - exit will realize R < P (token):", token);
            console.log("           booked / staked:", recorded, staked);
        }

        address vault = ICutoverStrategy(strategy).vault();
        address adapter = _marketAdapter(strategy);
        uint256 exitAmount = recorded < staked ? recorded : staked;
        if (exitAmount > 0) {
            // Both strategies clamp the shares they dispose of to the shares they actually hold.
            uint256 shares = ICutoverVault(vault).convertToShares(exitAmount);
            uint256 held = ICutoverVault(vault).balanceOf(strategy);
            if (shares > held) shares = held;
            if (adapter != address(0)) {
                uint256 bps = ICutoverStrategy(strategy).slippageToleranceBps();
                uint256 minOut = ICutoverVault(vault).convertToAssets(shares) * (CUTOVER_MAX_BPS - bps) / CUTOVER_MAX_BPS;
                (bool quoted, uint256 quote) = _curveQuote(adapter, vault, token, shares);
                console.log("  market exit pre-quote (shares / quote / minOut):", shares, quote, minOut);
                require(
                    quoted && quote >= minOut,
                    "STOP AND REPORT: market-strategy exit would breach its slippage floor - V1 initiateMigration would revert"
                );
            } else {
                uint256 maxRedeem = ICutoverVault(vault).maxRedeem(strategy);
                require(
                    maxRedeem >= shares,
                    "STOP AND REPORT: ERC4626 vault maxRedeem is below the V1 exit - initiateMigration would revert"
                );
            }
        }

        migrator.initiateMigration(token);

        require(v1.poolState(token) == POOL_MIGRATING, "cutover: V1 pool did not enter Migrating");
        require(
            ICutoverStrategy(strategy).principalOf(token, address(v1)) == 0,
            "cutover: V1 still books principal after initiateMigration"
        );
        (uint256 R, uint256 P) = v1.migrationInfo(token);
        console.log("  V1 initiateMigration (token / R realized / P snapshot):", token, R, P);
    }

    // =====================================================================
    //  Batched migration
    // =====================================================================

    /// @notice Migrate every migratable V1 staker of `token` in batches of `chunk`, leaving only the
    ///         allow-listed stragglers behind. Re-plans from live state, so a resume leg picks up
    ///         exactly where a previous one stopped.
    /// @param cap Exclusive upper bound on the stragglers' summed V1 principal (token decimals).
    function _migratePool(
        ICutoverMigrator migrator,
        ICutoverStaker v1,
        address token,
        address strategy,
        uint256 chunk,
        uint256 cap
    ) internal returns (PoolPlan memory plan) {
        require(chunk > 0 && chunk <= 50, "cutover: migrate chunk out of range (1..50)");
        plan = _planPool(v1, token, strategy);
        _logPlan(token, plan);

        require(
            plan.stragglerAmountTotal < cap,
            "STOP AND REPORT: straggler principal is at or above the dust cap - a non-dust position cannot deposit into V2"
        );

        if (_marketAdapter(strategy) == address(0) && plan.migratableCreditTotal > 0) {
            address vault = ICutoverStrategy(strategy).vault();
            require(
                ICutoverVault(vault).maxDeposit(strategy) >= plan.migratableCreditTotal,
                "STOP AND REPORT: ERC4626 vault maxDeposit is below the total migrating credit"
            );
        }

        uint256 n = plan.migratable.length;
        uint256 batches;
        for (uint256 start = 0; start < n; start += chunk) {
            uint256 end = start + chunk > n ? n : start + chunk;
            address[] memory batch = new address[](end - start);
            for (uint256 i = start; i < end; i++) {
                batch[i - start] = plan.migratable[i];
            }
            uint256 before = v1.stakerCount(token);
            migrator.migrate(token, batch);
            uint256 afterCount = v1.stakerCount(token);
            // Strict progress. Every user in the batch had amount > 0, and V1 `_exitPosition` removes
            // every such user (zero-credit included), so the set must shrink by exactly the batch.
            require(
                afterCount < before && before - afterCount == batch.length,
                "cutover: migrate batch did not remove every batched staker from V1 - no-progress guard"
            );
            batches++;
        }
        console.log("  migrated (token / users / batches):", token, n, batches);

        require(
            v1.stakerCount(token) == plan.stragglers.length,
            "cutover: V1 staker count != allow-listed stragglers after migration"
        );
    }

    // =====================================================================
    //  Post-conditions
    // =====================================================================

    /// @notice The exit-realization loss bound (story 087, audit-33 L-06; replaces story 085's aggregate floor).
    ///         True iff V1's terminal exit of `token` realized at least `(MAX_BPS - maxLossBps)` of its principal
    ///         snapshot, less one `weiSlack`: `(min(R, P) + weiSlack) * MAX_BPS >= P * (MAX_BPS - maxLossBps)`.
    /// @dev    WHY R / P AND NOT `P - v1Staked`. `StableStakerV1.initiateMigration` fixes
    ///         `migrationInfo[token] = {realized: R, principalSnapshot: P}` ONCE, and every exit - `batchMigrate`
    ///         through the migrator OR a staker's own permissionless `userMigrate` - credits
    ///         `amount * min(R, P) / P`. So `min(R, P) / P` IS the pre -> credit haircut of every staker, however
    ///         they leave, and neither R nor P can be moved by anyone for the life of the migration.
    ///         Story 085 anchored on `P - v1Staked` against V2's booked total. A `userMigrate` self-exit landing
    ///         between the broadcast `initiateMigration` and `migrate` transactions keeps its principal inside
    ///         `P`, removes it from `v1Staked` and never reaches V2, so that floor counted a legitimate,
    ///         designed exit as V2 loss: a false-red `:verify` and a resume that could not finish (audit-33
    ///         L-06). The rule this bound follows: a post-condition must never read a quantity a permissionless
    ///         actor can move between two broadcast transactions.
    ///         Coverage kept from story 085 (audit F-01): a strategy exit haircut beyond the bound is caught on
    ///         EVERY leg, including a resume leg whose `plan.migratable` is empty, because R and P are pool-wide.
    ///         The credit -> credited (V2 re-deposit) leg stays bounded per user: in-leg by
    ///         `_assertPoolPostMigration`, and after the broadcast by the verifier's `MigratedOut` / `DepositedFor`
    ///         re-check plus its self-exit-aware aggregate (`VerifyStableStakerV2Cutover`).
    ///         R > P (a strategy exit that realized a gain) is capped at par, exactly as V1 caps the credit.
    ///         ONE `weiSlack` for the pool, not one per user: the exit is a single strategy withdraw of `P`, whose
    ///         vault share rounding can realize a few wei under par even with no economic loss (unit-tested at a
    ///         high share price). On mainnet 1000 wei is below 1e-9 of a 2 bps allowance on any live pool.
    ///         Multiplication, not division: no rounding in either direction.
    function _exitRealizationWithinBound(
        uint256 realized,
        uint256 principalSnapshot,
        uint256 maxLossBps,
        uint256 weiSlack
    ) internal pure returns (bool) {
        require(principalSnapshot > 0, "cutover-post: V1 principalSnapshot is zero");
        require(maxLossBps <= CUTOVER_MAX_BPS, "cutover-post: maxLossBps above MAX_BPS");
        uint256 capped = realized < principalSnapshot ? realized : principalSnapshot;
        return (capped + weiSlack) * CUTOVER_MAX_BPS >= principalSnapshot * (CUTOVER_MAX_BPS - maxLossBps);
    }

    /// @notice 080's `_assertStableStakerCutover`, extended for stragglers, resume legs, a V2 book /
    ///         strategy lockstep and the story-087 exit-realization bound.
    /// @dev    LOSS GATE (story 087, audit-33 L-06; the loss gate story 067 and story 082 Phase 6 asked for):
    ///         `_exitRealizationWithinBound(R, P, maxLossBps, weiSlack)` with `(R, P) = V1.migrationInfo(token)`, both fixed
    ///         at `initiateMigration` and never reset by the cutover (only `finalizeAndReset` zeroes them, and
    ///         the cutover never calls it). It reads nothing a self-exit, an organic stake/withdraw or a
    ///         donation can move, so it is equally valid on a fresh leg, on a resume leg (empty
    ///         `plan.migratable`) and in the post-broadcast verifier. See `_exitRealizationWithinBound`.
    ///         The per-user in-leg bound below still covers the full pre -> credited loss of THIS leg's users.
    ///         Organic stakes: V2 is paused until Phase 7; checks here that read V2 totals are equalities over
    ///         V2's own staker set, which organic stakes keep true.
    /// @param plan The plan `_migratePool` executed in THIS leg (per-user checks cover its users).
    /// @param maxLossBps Principal loss allowed in bps, per user and on the exit leg (`_maxLossBps`: 2 for the
    ///        ERC4626 autopools, 2 * slippageToleranceBps + 1 for the market strategy).
    /// @param weiSlack Absolute rounding slack, in token wei: per user in the per-user bound, and once for the pool's
    ///        single V1 exit in the realization bound.
    function _assertPoolPostMigration(
        ICutoverStaker v1,
        ICutoverStaker v2,
        address token,
        address strategy,
        PoolPlan memory plan,
        uint256 maxLossBps,
        uint256 weiSlack
    ) internal view {
        // ---- V1 holds the stragglers and nothing else ----
        require(v1.poolState(token) == POOL_MIGRATING, "cutover-post: V1 pool not Migrating");
        require(v1.stakerCount(token) == plan.stragglers.length, "cutover-post: V1 stakerCount != stragglers");
        (,,, uint256 v1Staked) = v1.poolInfo(token);
        require(v1Staked == plan.stragglerAmountTotal, "cutover-post: V1 totalStaked != straggler principal");

        // ---- Per migrated user (this leg) ----
        for (uint256 i = 0; i < plan.migratable.length; i++) {
            uint256 pre = plan.migratablePre[i];
            (uint256 post,) = v2.userInfo(token, plan.migratable[i]);
            if (plan.migratableCredit[i] == 0) {
                // zero-credit: exited from V1, never deposited on V2
                (uint256 left,) = v1.userInfo(token, plan.migratable[i]);
                require(left == 0, "cutover-post: zero-credit user still holds V1 principal");
                continue;
            }
            require(pre > 0, "cutover-post: migratable user had no V1 principal");
            require(post > 0, "cutover-post: a migrated staker was not credited on V2");
            require(post <= pre, "cutover-post: a staker gained principal in the cutover");
            require(
                pre - post <= pre * maxLossBps / CUTOVER_MAX_BPS + weiSlack,
                "cutover-post: cutover lost more principal than the strategy can explain"
            );
        }

        // ---- V2 books exactly the sum of its stakers (resume-safe: enumerate the live set) ----
        (,,, uint256 v2Staked) = v2.poolInfo(token);
        uint256 n = v2.stakerCount(token);
        address[] memory v2Users = v2.getStakersRange(token, 0, n);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            (uint256 a,) = v2.userInfo(token, v2Users[i]);
            sum += a;
        }
        require(v2Staked == sum, "cutover-post: V2 totalStaked != sum of V2 staker principal");

        // ---- Exit-realization bound (story 087, audit-33 L-06): anchored on V1's immutable R / P only ----
        {
            (uint256 realized, uint256 principalSnapshot) = v1.migrationInfo(token);
            console.log("  exit realization (token / R realized / P snapshot):", token, realized, principalSnapshot);
            console.log("    loss bound bps / V2 totalStaked:", maxLossBps, v2Staked);
            require(
                _exitRealizationWithinBound(realized, principalSnapshot, maxLossBps, weiSlack),
                "cutover-post: V1 exit realization below loss bound"
            );
        }

        // ---- V2 book / strategy lockstep (not a loss floor) ----
        // `depositFor` credits `strategy.principalOf(token, V2)` and `V2.totalStaked` from the same value, so
        // on a clean cutover these are equal by construction. This detects a booking desync between V2 and
        // its strategy; it cannot detect principal lost in the cutover (the realization bound above and the
        // per-user bounds do that).
        uint256 stratPrincipal = ICutoverStrategy(strategy).principalOf(token, address(v2));
        require(
            stratPrincipal >= v2Staked, "cutover-post: strategy principal for V2 below V2 booked totalStaked (lockstep)"
        );

        console.log("  post-migration OK (token / V2 totalStaked / V2 stakers):", token, v2Staked, n);
    }
}
