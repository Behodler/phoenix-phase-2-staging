# Action Plan: Migrate BalancerPoolerV2 donation route to Sky redeem + PSM

**Status:** Planned — not yet implemented.
**Author context:** Diagnosed from a failing owner-initiated `pool()` on mainnet.
**Scope:** One contract change (in the `yield-claim-nft` submodule) plus one single
owner-signed orchestration script that cuts the index-4 dispatcher over to a new
pooler that uses the Sky route, seeds it, and pools.

> Addresses are intentionally **omitted** from this document. A later agent must
> look up and verify every live address and ABI on-chain before writing code.
> Where a constant is named below it is a *pointer to find*, not a value to trust.

---

## 1. Why we are making this change

### The symptom
An owner-initiated `pool(minBPT, minUSDC)` on the live index-4 pooler reverts. The
chosen slippage floors (e.g. `minBPT = 280`, `minUSDC = 63`) are **not** the cause —
the call reverts identically for *any* floors, including `pool(1, 1)`.

### The root cause
`pool()` runs an optional **batch-donation phase** before the LP add. With
`batchDonationSize = 10`, it diverts 10% of the accumulated sUSDS and tries to
convert it to USDC for the BatchNFTMinter via:

```
sUSDS --(Balancer V3 swap on `swapPool`)--> waUSDC --(ERC4626 redeem)--> USDC
```

The configured `swapPool` is a Balancer V3 **StableSurge** pool of
`[waUSDT, sUSDS, waUSDC]` that is **effectively unseeded**:

- `totalSupply` is only the `POOL_MINIMUM_TOTAL_SUPPLY` dead shares minted at init.
- Live balances are dust (~1e-6 of each token; the sUSDS side is ~0).

Swapping a real amount of sUSDS into a near-empty pool is an effectively infinite
relative trade, so the pool's StableSurge hook rejects it with the custom error
`MaxImbalanceRatioExceeded()` (selector `0x8a3b7ff1`). Because the donation runs
inside the same atomic Balancer `unlock` callback as the LP add, the **entire
`pool()` reverts** before any liquidity is added.

### Why we cannot just repoint `setSwapConfig`
The donation path requires a **single** Balancer V3 pool holding both **sUSDS and
waUSDC** with real liquidity. A scan of the Balancer V3 API (mainnet) shows:

- Pools containing sUSDS (sUSDS/phUSD, GYD/sUSDS with its sUSDS side drained,
  sDOLA/sUSDS, a couple of dust surge pools) — **none contain waUSDC**.
- ~24 pools contain waUSDC (Aave GHO/USDT/USDC, etc.) — **none contain sUSDS**.

There is **no liquid sUSDS↔waUSDC market on Balancer V3**. The only pool with the
right token set is the empty one we are already pointed at. The Balancer-swap
donation mechanism is therefore structurally unworkable here; repointing config
cannot fix it.

### The fix: Sky redeem + PSM
Replace the Balancer-swap donation leg with a reserve-backed, fixed-rate path:

```
sUSDS --(ERC4626 redeem on the sUSDS savings vault)--> USDS   (no slippage; rate only)
USDS  --(Sky PSM, fixed 1:1 minus tout fee)----------> USDC   (no AMM curve, no imbalance limit)
USDC  --> BatchNFTMinter
```

**What a PSM is:** the Sky/Maker *Peg Stability Module* is not an AMM. It swaps a
Sky stablecoin (USDS/DAI) against USDC at a **fixed 1:1 rate** out of a USDC reserve
it holds directly (`sellGem`: USDC→USDS; `buyGem`: USDS→USDC). Because it is
reserve-backed at a fixed rate, there is **no price curve, no slippage, and no
imbalance ceiling** — the exact `MaxImbalanceRatioExceeded` failure mode cannot
occur. Fees are flat `tin`/`tout` basis-point parameters (frequently 0). The only
limits are available USDC liquidity and the debt ceiling, both enormous relative to
a ~tens-of-USDC donation.

This also simplifies the contract: USDS is already known to the pooler as
`_primeToken = IERC4626(sUSDS).asset()`, and the pooler is already ERC4626-aware
(it deposits USDS→sUSDS in its dispatch path). The only genuinely new external
dependency is the **PSM contract address**; `waUSDC` and the Balancer `swapPool`
drop out of the donation path entirely.

---

## 2. Contract change (in `lib/yield-claim-nft`, via the submodule's own repo + TDD)

> **Read §8 (Design refinements) first.** It records two agreed changes that alter
> the shape below: (a) the donation moves OUT of `pool()` into `_dispatch` with
> failure-isolation, so `pool()` becomes a pure LP add and a PSM outage can never
> block a mint; and (b) the mint-debt hook gains a `setDispatcher` setter. The steps
> in this section describe the baseline donation-in-`pool()` rewrite for reference;
> the §8 refinements supersede where they conflict.

The new pooler is a **modified `BalancerPoolerV2` artifact**, not a redeploy of the
current bytecode. Changes, all TDD-first per the submodule's CLAUDE.md:

1. **Rewrite the donation phase** inside `pool()` / `unlockCallback`:
   - Compute `donationSUSDS = sUSDSAmount * batchDonationSize / 100` (unchanged).
   - `IERC4626(_sUSDS).redeem(donationSUSDS, address(this), address(this))` → USDS.
   - Convert USDS→USDC through the PSM (`buyGem`/equivalent), honouring the
     **18dp USDS vs 6dp USDC** decimal conversion and the `tout` fee.
   - `require(usdcReceived >= minUSDC, "...")` — keep the existing slippage-floor
     guard on the *final USDC delivered*.
   - Transfer the USDC to `batchMinter`.
   - The donation phase no longer touches the Balancer vault, `swapPool`, or `waUSDC`.
2. **Configuration surface:**
   - Add the PSM address (constructor arg, or a dedicated `onlyOwner` setter —
     prefer an explicit setter mirroring `setSwapConfig` so it is auditable and
     re-pointable).
   - Decide the fate of `setSwapConfig`/`waUsdc`/`swapPool`: either remove them or
     leave them inert. Removing reduces foot-guns; document whichever is chosen.
   - `batchMinter`, `batchDonationSize`, the authorized-pooler set, the LP-add path,
     and `_primeToken`/sUSDS/vault/router/`sUSDSIsFirst` are all unchanged.
3. **Keep the LP-add path byte-for-byte** (it works against the seeded phUSD/sUSDS
   pool; only the donation leg is broken).
4. Bump the `yield-claim-nft` submodule pointer in this repo once merged.

> Open design question for the implementer: confirm the exact PSM interface to use
> for USDS→USDC (the Sky USDS PSM / wrapper vs. the DAI LitePSM reached via the
> USDS↔DAI converter), its `buyGem` signature, decimal/fee conventions, and current
> `tout`. Record the source of each in a code comment per the Configuration Safety
> section of the repo CLAUDE.md.

---

## 3. The single orchestration script

Model it on the existing, fully-worked cutover
`script/DispatcherReplaceAtIndex4.s.sol` (same owner ledger, same
`replaceDispatcher(4, …)` mechanism, same PREVIEW_MODE/broadcast pattern). That
script proves every primitive this plan relies on. The differences from that script:

- The **current** index-4 dispatcher is now the live nudge pooler (the one this doc
  diagnoses), not the pre-donation pooler that the earlier story replaced.
- We are **not** doing the one-time index-6 cleanup (bugged-pooler drain, founder
  id-6 burn, `setDispatcherDisabled(6)`) — those were specific to story 048.
- We **add** an sUSDS rescue→seed and a final `pool()` invocation.
- The new pooler is the **Sky-route artifact** from section 2.

### Pre-flight (no broadcast)
- Assert `block.chainid == 1`.
- Snapshot: `configs(4).dispatcher` (= old pooler), its `sUSDS()`, `pool()` (= BPT),
  `vault()`, the router + `sUSDSIsFirst` constants (mirror from the existing script —
  the pooler exposes no getters for the latter two), `batchDonationSize`,
  `batchMinter`, current sUSDS balance on the old pooler, current BPT balances.
- Verify owner = the ledger signer; verify NFTStaker owner; read the current
  `NFTStaker.dispatcherHook()`.

### Broadcast (single owner-signed run)
1. **Drain old mint-debt hook** — `NFTStaker.pullAndRefresh()`, assert
   `oldHook.mintDebt() == 0`. (Required before swapping the hook; mirrors step 3 of
   the reference script.)
2. **Deploy new pooler** (Sky-route artifact) with the mirrored constructor args
   `(sUSDS, lpPool, vault, router, sUSDSIsFirst, OWNER)`.
3. **Deploy + wire a new mint-debt hook** for the new pooler, then
   `pooler.setHook(newHook)`, `newHook.setRecipient(NFTStaker)`,
   `phUSD.setMinter(newHook, true)`. **(See "Required, easy to miss" below.)**
4. **Mirror pooler config** onto the new pooler: `setBatchDonationSize`,
   `setBatchMinter`, the **PSM config setter** (new), and re-authorize the
   owner/ledger as a pooler (assert `poolerAuthVersion(owner) == authVersion`).
5. **Remove BPT from old pooler** — `oldPooler.withdrawBPT(OWNER, bptBal)`.
6. **Rescue sUSDS from old pooler** — `oldPooler.rescueERC20(sUSDS, OWNER, susdsBal)`
   (escape hatch; `onlyOwner`, not pause-gated).
7. **Seed new pooler** — plain ERC20 `transfer` of the rescued sUSDS **and** the
   withdrawn BPT to the new pooler. (Both are read via `balanceOf(self)`; no deposit
   call needed — see section 4.)
8. **Swap the staker's hook** — `NFTStaker.setDispatcherHook(newHook)`; assert.
9. **Replace dispatcher at index 4** — `NFTMinterV2.replaceDispatcher(4, newPooler)`;
   assert `configs(4).dispatcher == newPooler`. This keeps the **NFT id == 4** (the
   index/id is stable; only the dispatcher pointer flips, so the NFTStaker
   `stakedId=4 / dispatcherIndex=4` keeps working unchanged).
10. **Decommission old hook** — `phUSD.setMinter(oldHook, false)`.
11. **Invoke `pool(minBPT, minUSDC)`** from the (now-authorized) owner with correctly
    derived slippage floors (section 5). Assert it succeeds and BPT increases.
12. Post-state invariant log: `configs(4).dispatcher == newPooler`, new pooler holds
    the migrated BPT, `NFTStaker.dispatcherHook() == newHook`, old pooler drained.

### Required, easy to miss
The user-described scope ("rescue sUSDS, remove BPT, deploy, replaceDispatcher, seed,
pool") **omits the mint-debt hook redeploy + re-wire (steps 1, 3, 8, 10)**. Deploying
a new pooler orphans the existing hook (its dispatcher reference is set at
construction), and the NFTStaker mint-debt accounting will break if the hook is not
swapped. The reference script treats this as mandatory; this plan keeps it. If a
later analysis proves the hook can be re-pointed without redeploy, simplify then —
but do not silently drop it.

---

## 4. Seeding — confirmed mechanism

`pool()` begins with:

```solidity
uint256 sUSDSAmount = IERC20(_sUSDS).balanceOf(address(this));
require(sUSDSAmount > 0, "BalancerPoolerV2: nothing to pool");
```

It pools **whatever sUSDS the contract holds** — there is no deposit/seed function and
no internal accounting. Therefore:

- **Yes — you seed a new pooler with sUSDS by a plain ERC20 `transfer` to its
  address.** Nothing else is required.
- The same is true for **BPT**: it is a normal ERC20; transferring it in places it
  under the new pooler's custody, and `withdrawBPT` can later move it out. The LP-add
  path likewise reads BPT/sUSDS via `balanceOf(self)`.

---

## 5. Safety parameters (must be deliberately chosen — see repo CLAUDE.md)

Per the Configuration Safety gate, every safety-relevant value must be sourced
explicitly and guarded by an in-script `require` on mainnet. For this change:

- **`minUSDC`** — floor on USDC delivered to `batchMinter`. Derive at execution time
  from `donationSUSDS × (sUSDS→USDS redeem rate) × (1 − PSM tout) ` converted to 6dp,
  minus a small tolerance. Must be `> 0`; never hardcode a stale value.
- **`minBPT`** — floor on BPT from the LP add. Derive from the router's ideal-BPT
  query (`getIdealBPT`/`queryAddLiquidityUnbalanced`) for the remaining sUSDS, minus
  a tolerance. Must be `> 0`.
- **PSM address** — must be non-zero and verified to be the canonical Sky USDS↔USDC
  PSM; assert in the contract setter and log in the script.
- **Decimals** — USDS is 18dp, USDC is 6dp; the contract must convert correctly and a
  test must cover it (off-by-1e12 here silently mis-sizes the donation).
- **Authorized pooler / owner** — assert the ledger signer is authorized on the new
  pooler before step 11.
- **`batchMinter`** — confirm it is the intended live BatchNFTMinter (note the prior
  memory about permissionless nudge drains on BatchNFTMinter funding — confirm the
  donation target is correct and intended).

Anvil may relax the floor `require`s behind an explicit `block.chainid == 31337`
branch; mainnet/Sepolia must not.

---

## 6. Open items for the implementing agent

1. Look up and verify on-chain: the Sky USDS↔USDC **PSM** contract + ABI + current
   `tin`/`tout` + available USDC liquidity; the live index-4 pooler, NFTMinterV2,
   NFTStaker, current hook, owner ledger, BatchNFTMinter, sUSDS, USDS, USDC, BPT/LP
   pool, Balancer vault/router.
2. Confirm the exact USDS→USDC conversion call and whether a USDS↔DAI hop is needed.
3. Decide constructor-vs-setter for the PSM address, and whether to delete the dead
   Balancer-swap donation config.
4. Confirm whether the mint-debt hook must be redeployed (default: yes — see §3).
5. Decide the slippage-tolerance bps for `minBPT`/`minUSDC`.
6. Write the contract change TDD-first in the `yield-claim-nft` repo; bump the
   submodule pointer here; then write the orchestration script with a working
   `PREVIEW_MODE=true` dry run before any broadcast.

---

## 7. Verification & rollback

- **Dry run:** `PREVIEW_MODE=true forge script … --rpc-url $RPC_MAINNET -vvv`
  (impersonate owner, no broadcast) — all asserts must pass, including the final
  `pool()`.
- **Post-broadcast checks:** `configs(4).dispatcher`, new pooler BPT balance,
  `NFTStaker.dispatcherHook()`, a `cast code` at the new pooler, and the BatchNFTMinter
  USDC receipt from the donation leg.
- **Rollback:** because `replaceDispatcher` is reversible and BPT/sUSDS are recoverable
  via `withdrawBPT`/`rescueERC20`, a botched cutover can be reverted by replacing
  index 4 back to the prior dispatcher and re-rescuing assets — but prefer to catch
  everything in the preview run.

---

## 8. Design refinements (agreed in review)

### 8a. Make `pool()` pure — donation moves into `_dispatch` with failure-isolation (CHOSEN)

`pool()` becomes nothing but the LP add (unlock → `addLiquidity`): drop its `minUSDC`
arg and the entire `donationActive` branch. The donation moves into `_dispatch`, which
already holds the raw **USDS** for the mint — so it converts the donation share directly
via PSM `buyGem` (USDS→USDC), skipping the sUSDS→USDS redeem hop entirely.

**Per-dispatch behaviour (the chosen failure-isolated shape):**
- Compute `donationUSDS = amount * donationRatio / 100`.
- **Try** the donation: PSM `buyGem(USDS→USDC)` delivering USDC to `batchMinter`.
  - **On success:** wrap the remainder `(amount − donationUSDS)` → sUSDS.
  - **On failure:** wrap **only** `(amount − donationUSDS)` → sUSDS and leave
    `donationUSDS` sitting as **raw USDS on the contract, untouched**. The mint still
    succeeds; `pool()` still works on the wrapped sUSDS; the skipped donation simply
    waits until the PSM path is healthy again.

Because `pool()` reads `balanceOf(_sUSDS)` only, stranded raw USDS is **never**
accidentally pooled — it is safely parked. This keeps the user-facing mint path
**independent of Sky/PSM availability** (the §8/March-2023 tail risk cannot brick mints)
while still making `pool()` maximally simple.

**Mandatory implementation requirements:**
1. **`try/catch` must roll back partial donation state.** Structure the donation as a
   single external call (the `buyGem`, or a self-external-call wrapping
   approve+buyGem) so any mid-way revert moves *nothing*; only then does the catch
   branch wrap the remainder. Never leave a half-executed donation.
2. **Stranded-USDS recovery path.** Add an owner/keeper `retryDonation(uint256 minUSDC)`
   that sweeps accumulated raw USDS → USDC → `batchMinter` (with the same `minUSDC`
   guard). Decide whether a permanent give-up instead wraps the stranded USDS to sUSDS.
   Do **not** rely solely on `rescueERC20` for this.
3. **Mint-debt hook semantics unchanged.** `dispatch()` still calls
   `hook.onDispatch(minter, amount, …)` with the **gross** `amount` after `_dispatch`,
   so debt accrues on the full dispatched USDS regardless of donation success/failure.
   Confirm this is intended (it is for staker minting; the donation is orthogonal).
4. **Decimals / fee / dust.** `buyGem` takes the USDC amount out (6dp); derive it from
   `donationUSDS` (18dp) net of `tout`. Skip gracefully (no revert, no donation) if a
   small mint rounds the donation to 0 gem; leftover USDS dust stays on the contract.
5. **No fee-free path — treat `tout` as live and non-zero-capable.** `buyGemNoFee`
   requires the caller be a whitelisted PSM `bud`; the pooler won't be, so use regular
   `buyGem` and pay `tout`. The PSM is **slippage-free** (fixed rate, no price impact)
   but **not guaranteed fee-free**: `tout` is a governance-settable WAD parameter,
   currently ~0 but with precedent for being raised (LitePSM migration; stress events).
   Therefore:
   - **Do not hardcode a 1:1 assumption.** Read `tout` on-chain at execution and size
     `gemAmt` (USDC out) from it.
   - **`minUSDC` must be computed for an acceptable `tout` and must be `> 0`** — it is
     the real guard against any fee/rounding shortfall (see §5).
   - **Assert a `tout` ceiling** (`require(tout <= MAX_TOUT)`) so a surprise fee spike
     makes the donation safely revert into the §8a fallback (USDS parks, mint still
     succeeds) rather than silently shipping a worse rate.

**Alternative considered — separate keeper-only `donate()` (not chosen):** a standalone
`donate(minUSDC)` keeps donation batched and off the mint path with zero per-mint gas,
but requires an extra keeper tx and does not match the user's preference for automatic,
per-mint donation. Retained here only as a fallback if per-mint gas ever proves
unacceptable.

### 8b. Give the mint-debt hook a `setDispatcher` so future pooler swaps don't redeploy it

`BalancerPoolerMintDebtHook.dispatcher` is currently `immutable` (gates `onDispatch`
against debt inflation). Replace it with a mutable storage var + `onlyOwner
setDispatcher(address)`. Trust model is unchanged (owner is already fully trusted).

- **Does not save the current cutover** — you can't add a setter to deployed immutable
  bytecode, so this migration still redeploys the hook once.
- **Pays off on every future pooler swap:** with `setDispatcher`, a future cutover is
  just `deploy pooler → hook.setDispatcher(newPooler) → newPooler.setHook(existingHook)
  → replaceDispatcher`. The `NFTStaker.dispatcherHook` reference and the
  `phUSD.setMinter(hook)` grant **never change**, collapsing ~12 steps to ~4.
- **Operational guard:** `pull()` the outstanding `mintDebt` before repointing so the
  ledger is clean across the swap (the cutover already drains via
  `NFTStaker.pullAndRefresh`).

> Since this cutover redeploys the hook anyway, build `setDispatcher` into the new hook
> now (TDD in `yield-claim-nft`) so the *next* migration is cheap.
