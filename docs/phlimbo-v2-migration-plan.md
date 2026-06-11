# Phlimbo V2 Migration Plan

## Purpose

The current PhlimboEA contract recalculates `rewardPerSecond` inside `_updatePool` every time a partial distribution occurs:

```solidity
// Phlimbo.sol:416 (inside _updatePool)
rewardPerSecond = (rewardBalance * PRECISION) / depletionDuration;
```

Because `rewardBalance` decreases by `toDistribute` immediately before this line, and the new rate is then divided by the *full* `depletionDuration`, the system behaves as exponential decay (time constant ≈ `depletionDuration`) rather than linear depletion. The net effect is that the realized USDC reward per second is not constant over a depletion window — it falls every time any user claims, stakes, or withdraws, and the total fraction distributed within one window depends on the claim cadence (asymptotically approaching `1 − 1/e ≈ 63.2%` under continuous interactions).

**V2's fix is conceptually simple: only recompute `rewardPerSecond` inside `collectReward` (and `setDepletionDuration`), never inside `_updatePool`.** Combined with an explicit window-end timestamp to cap distribution, this gives true linear depletion over `depletionDuration`.

The migration described below preserves user balances and accrued rewards so that this upgrade does not impose any withdraw-and-restake burden on stakers.

## High-Level Flow

1. Deploy V2 PhlimboEA with the corrected depletion math and a one-shot migration entry point.
2. Pause V1 (so no new stake/withdraw/claim can interleave).
3. Snapshot the staker set off-chain from `Staked` events up to the pause block; compute each user's pending phUSD and pending stable.
4. Owner calls V1 `emergencyTransfer` — atomic transfer of all phUSD and all reward token to the Migrator contract (also re-pauses V1, redundantly safe).
5. Migrator validates received phUSD balance equals the snapshot's `Σ user.amount` (passed in as a constructor / init param). On mismatch, transfers funds back to V1 and exits.
6. Migrator pays pending rewards directly to each user (USDC + phUSD).
7. Migrator stakes principal on behalf of each user into V2 via `migrationStake`.
8. Migrator forwards the entire remaining reward-token balance to V2 as a single `collectReward` call. V2's corrected depletion math then distributes it linearly over the new `depletionDuration`.
9. Owner grants phUSD-minter role to V2; revokes from V1.
10. Migrator self-disables.

## Why Atomic emergencyTransfer Solves the Race

`Phlimbo.sol:214-227` already calls `_pause()` at the end of `emergencyTransfer`. Within a single tx, no `pauseWithdraw` can interleave, so there is no need to engineer a separate transfer-then-pause / pause-then-transfer sequence to close that window. The mismatch escape hatch in step 5 exists only as defense-in-depth against an **off-chain bookkeeping error** (missed staker in the snapshot), not against on-chain reentrancy or front-running.

The snapshot ordering still matters: pause **before** enumerating events, so no new `Staked` event lands between snapshot and pause. Required setup: owner is set as the pauser via `setPauser` so they can call `pause()` independently of `emergencyTransfer`.

## Two Reward Streams

Both must be handled at migration time:

| Stream | Source | How to settle |
|---|---|---|
| Pending stable (USDC) | `accStablePerShare` accumulator backed by `rewardBalance` | Migrator transfers `pendingStable_i` directly to each user from received balance. |
| Pending phUSD (APY) | `accPhUSDPerShare` accumulator, minted on claim | Owner pre-mints `Σ pendingPhUSD_i` to the Migrator (or grants Migrator phUSD-minter rights for the migration window). Migrator transfers each share to users. |

Paying pending rewards out at migration time avoids the negative-debt problem that would arise from trying to encode pending rewards into V2's `userInfo.stableDebt` / `userInfo.phUSDDebt` when V2's accumulators start at zero.

## rewardBalance Disposition

Transfer V1's full reward-token balance (sum of distributed-but-unclaimed + undistributed `rewardBalance`) to the Migrator via `emergencyTransfer`. After settling pending stable to users, **forward the entire remaining amount to V2 as a single `collectReward(amount)`**. V2's corrected depletion math will distribute this linearly over the next `depletionDuration` — no manual accounting needed.

## phUSD Minter Role Handoff

- Owner of phUSD must **grant** minter role to V2 PhlimboEA before V2 begins accruing APY rewards.
- Owner must **revoke** minter role from V1 PhlimboEA after migration completes, since V1 is paused but still holds the role.
- If the migrator mints pending phUSD itself, grant minter role to the Migrator for the migration window and revoke immediately after.

## V2 Contract Changes

### Depletion math fix
- Remove the `rewardPerSecond` recalculation from `_updatePool` (current `Phlimbo.sol:416`).
- Recompute `rewardPerSecond` only in `collectReward` and `setDepletionDuration`.
- Track an explicit `rewardEndTime` and cap distribution at `min(block.timestamp, rewardEndTime)` so the rate cleanly runs to zero at window end.

### Migration entry point
- New function: `migrationStake(address[] users, uint256[] amounts)`.
- Callable only by the designated Migrator address (set once at construction, revocable once).
- Skips `MINIMUM_STAKE` guard (some V1 balances may sit below it after dust handling).
- Pulls one bulk `transferFrom` of phUSD from the Migrator instead of per-user transfers.
- Writes `userInfo.amount` directly; sets `phUSDDebt` and `stableDebt` to current accumulator values (both zero at fresh V2, so debts are zero).

## Batching

If staker count exceeds what fits in one block (~100+ users), `migrationStake` must be batchable. Invariant checks:

- Before first batch: `phUSD.balanceOf(migrator) >= expectedTotal` (passed as init param).
- After final batch (finalize call): `phUSD.balanceOf(migrator) == 0` and `V2.totalStaked() == expectedTotal`.

A separate `finalizeMigration` call verifies and locks the migrator out of further `migrationStake` calls.

## Snapshot Procedure

1. Owner calls `setPauser(owner)` (if not already).
2. Owner calls `pause()` on V1.
3. Off-chain: enumerate all `Staked(recipient, amount)` events up to and including the pause block. Filter to addresses where `userInfo(addr).amount > 0` on-chain. (Withdrawals zero out the amount, so reading current `userInfo` after pause is the source of truth — events are only used to discover the address set.)
4. For each address, query `userInfo`, `pendingPhUSD(addr)`, `pendingStable(addr)`.
5. Compute `expectedTotal = Σ userInfo(addr).amount`. Sanity-check against `phUSD.balanceOf(V1) == expectedTotal`.

## Migrator Contract Outline

```
constructor:
  - record V1 address, V2 address, owner, expectedTotal
  - record arrays: users[], principals[], pendingStable[], pendingPhUSD[]

migrate() onlyOwner:
  require(phUSD.balanceOf(this) == expectedTotal, "phUSD mismatch")
  require(rewardToken.balanceOf(this) >= Σ pendingStable, "stable mismatch")
  require(this has Σ pendingPhUSD available to send, "phUSD-rewards mismatch")

  // pay pending rewards directly to users
  for each i: rewardToken.transfer(users[i], pendingStable[i])
  for each i: phUSD.transfer(users[i], pendingPhUSD[i])  // or mint

  // stake principal on behalf
  phUSD.approve(V2, expectedTotal)
  V2.migrationStake(users, principals)  // batched as needed

  // forward remaining reward-token balance to V2 as a fresh collect
  uint256 remaining = rewardToken.balanceOf(this)
  if (remaining > 0) {
    rewardToken.approve(V2, remaining)
    V2.collectReward(remaining)
  }

  V2.finalizeMigration()  // locks migrationStake permanently

abort() onlyOwner:
  // if invariant check fails, send everything back to V1
  rewardToken.transfer(V1, rewardToken.balanceOf(this))
  phUSD.transfer(V1, phUSD.balanceOf(this))
  // V1 is paused; pauseWithdraw remains available to users
```

## Edge Cases

- **Dust below `MINIMUM_STAKE`**: pre-existing `userInfo.amount` may legitimately be below `MINIMUM_STAKE` after a partial withdrawal that hit the dust-prevention branch (`Phlimbo.sol:347-351`). V2's `migrationStake` must accept these without the `MINIMUM_STAKE` check.
- **Recipient ≠ msg.sender**: `Staked` event records `recipient`, so off-chain enumeration is keyed on the staker, not the caller. Correct by construction.
- **`pauseWithdraw` after pause but before snapshot completes**: harmless — users can withdraw their phUSD principal anyway, and they forfeit pending rewards by exiting through that path. They'll just not appear in the migration set. (Decision point: do we want to delay the snapshot until after a grace period to let users self-exit if they prefer?)
- **V1 still holds phUSD-minter rights post-migration**: must be revoked. V1 is paused but still authorized.

## Acceptance Checks Post-Migration

- `V2.totalStaked() == V1.totalStaked()` (pre-migration value).
- For every snapshot address: `V2.userInfo(addr).amount == V1.userInfo(addr).amount` (pre-migration).
- For every snapshot address: pending rewards on V2 are zero immediately after migration (since they were paid out).
- `V2.rewardBalance() == V1_rewardToken_balance - Σ pendingStable_i` (the forwarded remainder).
- `phUSD.balanceOf(Migrator) == 0`, `rewardToken.balanceOf(Migrator) == 0`.
- V2 holds phUSD-minter role; V1 does not.
- Migrator's `migrationStake` permissions are revoked.
