# InPlaceMigrator — plan for the stable-staker agent

**Status:** plan / not yet implemented
**Target submodule:** `stable-staker` (contract lives at `lib/stable-staker/src/InPlaceMigrator.sol`)
**Author handoff:** this doc lives in `phStaging2`; the stable-staker agent implements the contract in its own repo (TDD-first). Do not let this repo's submodule pointer move until the submodule has committed.

---

## 1. Why this contract exists

`StableStaker.setYieldStrategy(token, strategy)` reverts unless `poolInfo[token].totalStaked == 0`.
There is **no hot-swap path**: to replace a yield strategy (or any per-token principal-custody
dependency) on a *live* pool you must drain every staker out, reset the pool, wire the new
strategy, then put everyone back. The existing `StableStakerMigrator` does this by bouncing all
users through a **throwaway temporary StableStaker** (leg 1: original→temp, reset+rewire, leg 2:
temp→original), which needs a second deployed staker, a second migrator, a temp phUSD-minter grant
and revoke, token re-registration, and a second terminal-migration snapshot cycle.

`InPlaceMigrator` removes the temporary staker entirely. The migrator **already physically receives
the principal** during `batchMigrate` (the staker transfers the aggregate to `msg.sender`), so
instead of forwarding it into a temp staker and pulling it back later, the migrator simply **parks
it** across the reset and re-injects it into the *same* staker once the new strategy is wired.

> **Use case (put this verbatim near the top of the contract as a NatSpec `@dev`):**
> This contract is for the narrow case of **safely changing a per-token dependency (e.g. a
> `IYieldStrategy`) on a single live `StableStaker` without hot-swapping while staking is live.**
> It evacuates users into the migrator's own custody, lets the operator run the empty-pool-only
> `finalizeAndReset` + `setYieldStrategy` rewire, then re-injects the same users into the same
> staker. Source and target are the **same** staker — hence "in place".

This is scoped for a **small staker set, a single batch, and a short (minutes-to-hours) window.**
It is not built for long-running, multi-day, many-batch migrations.

---

## 2. The throwaway-staker design vs. this one

| Concern | Temp-staker bounce (current) | InPlaceMigrator |
|---|---|---|
| Extra StableStaker deployed | yes | **no** |
| Migrators needed | 2 (immutable old/new, opposite directions) | **1** |
| phUSD `setMinter` grant/revoke on temp | yes | **no** |
| `addToken` / `setMigrator` / `pause` on temp | yes | **no** |
| Second `initiateMigration` + `batchMigrate` snapshot cycle | yes | **no** (parked funds are a plain mapping, not a staker position) |
| User self-custody during the window | yes — real `UserInfo` position in temp staker, `emergencyWithdraw`-able | **weaker** — a row in the migrator's mapping; recoverable only via the **timeout escape hatch** (§5) |

The one thing the temp staker gave us — a user-accessible escape hatch during the window — is
re-introduced deliberately and on the operator's terms by the timeout mechanism in §5.

### Coexistence: this is additive, not a replacement

`InPlaceMigrator` is a **new, separate contract**. The existing `StableStakerMigrator` is left
completely untouched — its source, its deployed instances, and anything downstream that references
it (addresses baked into other scripts, UI, or wiring) keep working unchanged. We are not modifying
or repurposing it, so there is no risk of breaking a downstream dependency on it. Choose
`InPlaceMigrator` for the in-place dependency-swap case; the temp-staker `StableStakerMigrator`
remains available for the cross-staker (true replacement) case it was built for.

---

## 3. Security model (REQUIRE these comments in the code, for the auditor)

The contract takes **custody of user principal across multiple transactions**. That is a real,
deliberate trust concession during the rewire window. The code must make the following invariants
explicit in comments so an auditor sees exactly what we are doing and why it is bounded:

1. **Custody is the whole point.** Between `migrateOut` and `migrateIn` the migrator holds raw
   principal for every parked user. Document why (the `setYieldStrategy` empty-pool requirement) and
   that the window is intended to be short and operator-orchestrated.

2. **The owner can never redirect parked principal to a non-user destination.** This is the
   load-bearing invariant. The only two exits for parked principal are:
   - `migrateIn` → `staker.depositFor(token, user, amount)` — credits the original user on the
     **immutable** staker; and
   - `claimTimedOut` → transfers to the **user themselves** (`msg.sender`).
   There is **no** owner path that sends parked principal anywhere else. `rescueERC20` (if included)
   must be provably incapable of touching parked principal (see §4.5).

3. **The staker is immutable — on purpose.** We deliberately do **not** accept an owner-supplied
   target address in `migrateIn`. An owner-mutable target is a drain vector: a compromised key could
   point `depositFor` at a malicious contract that pulls the migrator's approval and credits nobody,
   defeating the very timeout escape hatch this contract adds. Pinning `staker` at construction
   closes that hole. Comment this reasoning at the immutable's declaration and at `migrateIn`.

4. **Approvals are scoped to the exact slice total**, set immediately before the `depositFor` loop
   and never left dangling beyond what `forceApprove` overwrites. Comment it.

5. **The timeout is a guarded escape hatch, not a convenience.** Comment that the delay is
   intentional: it gives the operator an uninterrupted window to finish the rewire while guaranteeing
   that if the operator is incapacitated, loses keys, or the keys are compromised, every parked user
   can eventually recover their **principal** unilaterally. Note that earned phUSD was already minted
   to the user at `migrateOut` time (inside `batchMigrate`), so the hatch returns principal only.

---

## 4. Contract specification

`lib/stable-staker/src/InPlaceMigrator.sol`, `Ownable` + `ReentrancyGuard`, `using SafeERC20`.
Depends on the existing `IStableStaker` interface and OZ `EnumerableSet`.

### 4.1 Immutables / storage

```solidity
// The single live staker we are rewiring in place. Source AND target — see security model #3.
IStableStaker public immutable staker;

// Seconds after a user is parked before they may self-rescue via claimTimedOut. See #5.
uint256 public immutable migrationTimeout;

// token => user => parked principal (the exact per-user amount returned by batchMigrate).
mapping(address => mapping(address => uint256)) public parked;

// token => user => block.timestamp recorded at migrateOut (start of that user's escape clock).
mapping(address => mapping(address => uint256)) public migrationBegin;

// token => set of currently-parked users, for migrateIn pagination and bookkeeping.
mapping(address => EnumerableSet.AddressSet) private _parkedUsers;

// token => sum of parked[token][*]. rescueERC20 may only ever touch balance ABOVE this.
mapping(address => uint256) public totalParked;
```

### 4.2 Constructor (Configuration Safety — see phStaging2 CLAUDE.md)

```solidity
constructor(IStableStaker _staker, uint256 _migrationTimeout, address initialOwner)
```

Required guards (the script must refuse to deploy something dangerous):
- `require(address(_staker) != address(0), "InPlaceMigrator: zero staker")`
- `require(_migrationTimeout >= MIN_TIMEOUT && _migrationTimeout <= MAX_TIMEOUT, "InPlaceMigrator: timeout out of bounds")`
  - `MIN_TIMEOUT` rejects 0 / tiny values. A near-zero timeout opens the hatch immediately, letting
    an impatient user front-run `migrateIn` and break the in-progress migration.
  - `MAX_TIMEOUT` rejects an effectively-infinite value that would neuter the escape hatch (users
    never recover).
  - **OPEN QUESTION — operator must confirm before deploy:** proposed `MIN_TIMEOUT = 1 days`,
    `MAX_TIMEOUT = 30 days`, recommended `migrationTimeout = 7 days`. Per CLAUDE.md's cardinal rule,
    these are not to be silently accepted — confirm with the user. Record the chosen value and its
    justification in the deploy script as a comment.

### 4.3 `initiateMigration(address token) external onlyOwner`

Thin forwarder to `staker.initiateMigration(token)` (the staker hook is `onlyMigrator`, so it must
be called through this contract). Call once per token before the first `migrateOut`. Same shape as
the existing `StableStakerMigrator.initiateMigration`.

### 4.4 `migrateOut(address token, address[] calldata users) external onlyOwner nonReentrant`

1. `uint256[] memory amounts = staker.batchMigrate(token, users);` — pulls each user's principal
   into this contract and mints their earned phUSD to them. `amounts[i]` is the fixed snapshot
   credit `p_i·min(R,P)/P`.
2. For each `i` with `amounts[i] > 0`:
   - `parked[token][users[i]] += amounts[i];`
   - `migrationBegin[token][users[i]] = block.timestamp;`
   - `_parkedUsers[token].add(users[i]);`
   - `totalParked[token] += amounts[i];`
3. Emit `MigratedOut(token, count, total)`.

Note on idempotency: `batchMigrate` zeroes the source position, so a user cannot be migrated out
twice (a re-run returns `0` for them). No double-park guard needed, but document this.

### 4.5 `migrateIn(address token, uint256 start, uint256 end) external onlyOwner nonReentrant`

Re-injects a paginated slice of parked users back into the **immutable** `staker` (now wired to the
new strategy). Pagination because the set may exceed one tx's gas — though for this migration one
call (`start=0, end=len`) is expected.

Implementation notes:
- Clamp `end` to `_parkedUsers[token].length()`.
- **Snapshot the slice into a memory array first** (read `_parkedUsers[token].at(i)` for
  `i ∈ [start,end)`), THEN process — because removing from the set mid-loop shifts live indices.
- Sum the slice's `parked` amounts into `total`; `IERC20(token).forceApprove(address(staker), total);`
- For each user in the snapshot with `parked > 0`:
  - `staker.depositFor(token, user, parked[token][user]);`
  - `totalParked[token] -= parked[token][user];`
  - `parked[token][user] = 0; delete migrationBegin[token][user]; _parkedUsers[token].remove(user);`
- Emit `MigratedIn(token, count, total)`.

Double-spend safety: every exit path checks `parked > 0` and zeroes it under `nonReentrant` (CEI).
If a `claimTimedOut` interleaves after timeout, the worst case is a skipped index in one pass —
never a double payout — and the operator simply re-runs `migrateIn(token, 0, len)` to mop up.

### 4.6 `claimTimedOut(address token) external nonReentrant` — the escape hatch (permissionless)

```
amount = parked[token][msg.sender];
require(amount > 0, "InPlaceMigrator: nothing parked");
require(block.timestamp >= migrationBegin[token][msg.sender] + migrationTimeout,
        "InPlaceMigrator: timeout not elapsed");
// CEI: clear state BEFORE transfer
parked[token][msg.sender] = 0;
delete migrationBegin[token][msg.sender];
totalParked[token] -= amount;
_parkedUsers[token].remove(msg.sender);
IERC20(token).safeTransfer(msg.sender, amount);
emit TimedOutClaim(token, msg.sender, amount);
```

Returns principal only (phUSD already minted at `migrateOut`). Permissionless and self-only —
a user can only ever recover their own parked balance.

### 4.7 `rescueERC20(address token, address to, uint256 amount) external onlyOwner` (OPTIONAL)

If included, it MUST be incapable of touching parked principal:
```
uint256 surplus = IERC20(token).balanceOf(address(this)) - totalParked[token];
require(amount <= surplus, "InPlaceMigrator: cannot touch parked principal");
```
Only for stray/donated tokens. Comment that `totalParked` is the floor the owner can never cross —
this is what preserves the §3 invariant even against the owner.

### 4.8 Views

`parkedUserCount(token)`, `parkedUsersRange(token, start, end)`, `claimableAt(token, user)`
(returns `migrationBegin + migrationTimeout`) for off-chain batch building and UI.

---

## 5. The timeout escape hatch — rationale (restate in code comments)

- **Protects the operator's window.** A short delay stops an impatient user from calling
  `claimTimedOut` mid-migration and pulling their funds out from under an in-progress `migrateIn`,
  which would corrupt batch bookkeeping and leave the pool half-rewired.
- **Protects users against operator failure.** If the keys are lost/compromised or the operator
  dies before completing `migrateIn`, the hatch guarantees every parked user can recover principal
  on their own after `migrationTimeout`, with no owner action and no owner ability to front-run them
  (the owner has no path to redirect parked principal — §3.2).
- **The clock is per (token, user)**, started at that user's `migrateOut`. A batch all starts the
  same block, so in practice it's one deadline.

---

## 6. TDD test plan (write these RED first, in `lib/stable-staker/test/InPlaceMigrator.t.sol`)

Use the existing `Migration.t.sol` / mock harness as a template (mock staker + mock token + a real
or mock yield strategy).

1. `migrateOut` parks the exact `batchMigrate` amounts, sets `migrationBegin = now`, grows
   `totalParked` and `_parkedUsers`.
2. Full in-place cycle: `initiateMigration → migrateOut → finalizeAndReset → setYieldStrategy(V2)
   → migrateIn` re-credits each user the same principal on the same staker, routed through V2;
   `parked`/`totalParked` return to 0 and the set empties.
3. `claimTimedOut` **reverts before** `migrationTimeout` ("timeout not elapsed").
4. `claimTimedOut` **succeeds at/after** timeout: exact principal transferred, all state cleared,
   user removed from set.
5. No double-spend: cannot `claimTimedOut` twice; cannot `claimTimedOut` after `migrateIn`;
   `migrateIn` after a user already claimed skips them (no revert, no double pay).
6. `migrateIn` pagination: `(start,end)` processes only the slice; re-running over the remainder
   mops up; an interleaved post-timeout `claimTimedOut` never causes a double payout.
7. `rescueERC20` reverts when `amount` would dip into `totalParked`; succeeds for a genuine stray
   donation above the floor.
8. Constructor rejects zero staker, timeout `0`, timeout `< MIN_TIMEOUT`, timeout `> MAX_TIMEOUT`.
9. Reentrancy: a malicious token/user callback on `claimTimedOut` cannot re-enter to double-claim.
10. Only-owner gates on `initiateMigration` / `migrateOut` / `migrateIn` / `rescueERC20`;
    `claimTimedOut` is permissionless and self-scoped.

---

## 7. How the migration runbook collapses (phStaging2 side, for later)

The 5-step temp-staker saga shrinks to roughly:

- **Deploy:** one `InPlaceMigrator(original, migrationTimeout, owner)`. No temp staker, no second
  migrator, no temp minter grant, no temp `addToken`. Wire it once: `original.setMigrator(migrator)`
  (stays set for both legs). Deploy the V2 strategies and authorize them
  (`strategy.setClient(original, true)`).
- **Out:** pause original; skim surplus + Phase-4 shortfall pre-fund (unchanged — operates on the
  original's idle balance, orthogonal to the migrator); `migrator.initiateMigration(token)` per
  token; `migrator.migrateOut(token, users)` (likely one batch).
- **Rewire:** `original.finalizeAndReset(token)` then `original.setYieldStrategy(token, V2)`
  (sweeps the skim/pre-fund idle into V2).
- **In:** `migrator.migrateIn(token, 0, N)`.
- **Verify/close:** existing post-migration safety gates (zero-haircut floor, set-aside buffers,
  `withdrawDisabled == false`), then unpause. Leave the migrator deployed until all parked users are
  back in; no temp-staker decommission step.
- **Fallback:** if `migrateIn` never completes within `migrationTimeout`, parked users call
  `claimTimedOut(token)` to recover principal.

The skim-surplus / Phase-4 pre-fund / zero-haircut-floor machinery is unchanged and out of scope for
this contract — it stays in the phStaging2 deploy scripts.

---

## 8. Open questions to confirm before any deploy

1. **`migrationTimeout` value** and the `MIN_TIMEOUT` / `MAX_TIMEOUT` bounds (§4.2). Proposed
   7 days, bounded [1 day, 30 days]. Needs explicit operator sign-off (CLAUDE.md cardinal rule).
2. **Include `rescueERC20`?** It's safe as specified (§4.7) but adds surface; omit if not needed.
3. **Per-token vs. all-token `claimTimedOut`** — spec'd per-token for simplicity; confirm that's fine
   given the small set.
