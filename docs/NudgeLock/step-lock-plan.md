# Step Lock: Burn a Protocol NFT to Reserve the Next Discounted NFT

**Status:** Design plan for review. No code written, nothing broadcast.
**Date:** 2026-11-25.
**Scope:** A lock that lets one address reserve upcoming discount steps of the index-4 nudge-discount
minter by burning protocol NFTs (EYE/SCX/FLX, indices 1/2/3). This covers the contract design, the mainnet
cutover, and the guard that stops the cutover from shipping without equalised protocol-NFT prices. The same
cutover also moves the WBTC NFT (index 5) from WBTC to USDC payment; that is a separate, long-wanted change
that rides along and has nothing to do with locking.

---

## 1. Summary

**A holder burns one protocol NFT per step to reserve that many upcoming discount steps.** Only the holder
may `batchMint` until they claim, or until the pot has filled one whole step beyond their reservation, at
which point the lock lapses and the public may mint everything. Burning happens at deposit, so there is no
escrow and no refund: a holder who never claims loses their NFTs and gets nothing. The UI line is "Burn 1
EYE, SCX or FLX to reserve the next discounted NFT." There is no formula, credit balance or auction for
the user to learn.

The mechanism needs a new index-4 **batch minter**. The index-4 NFT itself (ERC-1155 id 4 on NFTMinterV2), its
dispatcher UniPoolerV2 and NFTStaker `0xc851…a13b` are all unchanged, so staked users are not touched, as in
the story-119 cutover. The batch minter must change because the live `BatchNFTMinterNudgeDiscount`
(`0xD41235bC…C42a`) has a permissionless `batchMint` with no hook to gate it. The new minter consults a
separate, owner-settable **lock gate**. A later pricing upgrade (dollar credits, an auction) then replaces
the gate and leaves the minter alone. The cutover repeats the shape of story 119
(`DeployMainnetNudgeDiscount.s.sol`).

**The WBTC NFT (index 5) switches from WBTC payment to USDC payment in the same cutover.** A new
dispatcher keeps the USDC, and an authorised buyer later swaps it for WBTC on Uniswap and leaves the WBTC in
the dispatcher, where only the owner's `rescueERC20` can move it. Index 5 launches at the same price as the
protocol NFTs but **cannot be used to lock**; the lock accepts only indices 1, 2 and 3 (section 3.4).

**The price equalisation cannot be forgotten, because the gate refuses to switch on until the
accepted NFTs are priced within a narrow spread.** Section 6 describes the layers.

## 2. Economics this plan is built on

Live values read on 2026-11-25:

| Input | Value |
|---|---|
| LSP (index 4) next price N | $18.60, growth 1 bp |
| EYE / SCX / FLX price | $10.957 / $10.716 / $10.036, growth 2 bp |
| Uniboost `donationSplit` | 50% of each protocol mint → this minter's USDC pot (30-day stream) |
| Uniboost hook ratio | 50% of each protocol mint as phUSD mint debt → that index's staker budget |
| Staked / supply | EYE 447/458, SCX 345/345, FLX 14/17 |
| WBTC NFT (index 5) | GatherWBTC `0xfd37…9880`, price 17,624 sats (~$10.3 at the V2 pair's ~$58k/BTC), growth **1,200 bp**, supply **0**, dispatcher balance 0, forwards to EOA `0x64d3…08D2`, not on PauserV2 |

- **One NFT per step, hardcoded.** After equalisation P ≈ $10.96, so the whale pays $10.96 for
  an $18.60 step, a $7.64 margin. Two NFTs ($21.92) would cost more than the step is worth, so 1:1 is a
  constant until prices converge, which is years away (next point).
- **The margin corrects itself slowly.** Each fresh burn raises its index price 2 bp, and each LSP paid
  mint raises N 1 bp. Bringing the margin down to $3 takes ~5,300 burns, which is years at ~2 locked
  steps a day.
- **Every burn helps the protocol.** A fresh mint-and-burn sends $5.48 to the pot and $5.48 to the
  protocol token pool, and adds $5.48 of mint debt to a staker with no new claimant (+0.11 pp EYE
  APY). Burning an old staked NFT gives almost the same APY lift (+0.10 pp) but nothing to the pot or
  the pool.
- **Equal prices stay roughly equal.** With equal prices a whale has no price reason to prefer one index,
  and each fresh burn makes its own index 2 bp dearer, so whales choosing the cheapest index keep the
  three close together.

## 3. Contract design (nft-staking)

A "step" is one free NFT's worth of pot. The pot's whole-step count is `potSteps = floor(potUSD / P0)`,
computed with the minter's own PSM maths and **not** capped by `maxFreePerBatch`, so a large reservation can
still lapse.

### 3.1 `StepLockGate` (new)

**The gate burns on deposit and holds nothing.** It needs only burner authorisation on NFTMinterV2.

**State**

| Field | Meaning |
|---|---|
| `minter` | The lockable batch minter (sole caller of `authorize`) |
| `nftMinter` | NFTMinterV2 `0x39Af…E10F`; the gate is an authorised burner |
| `acceptedIndex[i]` | Protocol NFT indices that may be burned (1, 2, 3 only) |
| `NFTS_PER_STEP` | Constant 1 (section 2) |
| `maxReservedSteps` | Owner-settable cap on a lock's reserved steps, for experiments. Must stay below the minter's `maxFreePerBatch` so a holder's batch fits the gas cap |
| `maxPriceSpreadBps` | Spread tolerance for `enable()` (section 6) |
| `enabled` | Starts `false`; only `enable()` sets it |
| `lock` | `{holder, reserved}` |
| `publicBatchRequired` | Set when a lock ends (claim or lapse), cleared by the next public batch; only if the gap rule is chosen (section 5) |
| `pauser` | PauserV2 hybrid pattern, as the minter |

**Lifecycle of a lock**

- `lock(uint256 index, uint256 steps)`. Requires `enabled`, not paused, `acceptedIndex[index]`, `steps > 0`
  and `reserved + steps <= maxReservedSteps`.
  - **No live lock** (none, or the current one has lapsed): the caller becomes holder with
    `reserved = steps`. With the gap rule on, this also requires that a public batch has happened since
    the last lock ended.
  - **Live lock:** only the holder may call, which extends it (`reserved += steps`). Anyone else reverts.
  - Then `nftMinter.burn(msg.sender, index, steps)`. **The gate always burns from `msg.sender` and takes no
    holder argument**, because NFTMinterV2's `burn` does not check approvals (the NFTBonfire precedent).
- **Lapse.** A lock is live while `potSteps < reserved + 1`. When the pot holds one whole step more than the
  reservation, the lock has lapsed. Lapse is evaluated whenever the gate is asked, from the pot reading, so no
  timestamp, keeper or poke is involved. At today's inflow the grace step is ~9.6h after the last reserved
  step arrives, and it scales with inflow automatically.
- `authorize(address caller, uint256 potSteps) returns (uint256 cap)`, `onlyMinter`. The minter calls it in
  `batchMint` **after** flushing the streams and reading the pot, passing the same `potSteps` the batch will
  use, so the gate and the minter can never disagree about a lapse.
  - **Live lock, caller is not the holder:** reverts `Locked(holder, reserved)`.
  - **Live lock, caller is the holder:** returns `reserved` as the free-NFT cap and ends the lock.
  - **No live lock:** returns `type(uint256).max`, ends a lapsed lock if one is recorded, and clears
    `publicBatchRequired`.
- `lock()` needs the same lapse test outside a batch, so the minter exposes a view `potSteps()` that
  includes un-flushed stream accrual exactly as the flush would. A test pins the view to the in-batch figure.
- `clearLock()`, owner-only emergency lever. It ends a live lock with no refund (nothing is held). Intended
  for a stall that leaves a dead holder's delivered steps stuck; expected never to be used.
- Owner setters for `acceptedIndex`, `maxReservedSteps` and `maxPriceSpreadBps`, `enable()` / `disable()`,
  and pause and unpause.

**Behaviour that falls out of this**

- **The holder can never claim more than they reserved.** The minter caps the holder's free count at
  `reserved`; any pot above that stays for the next batch.
- **At lapse the public may mint the whole pot, the former holder included.** A holder could wait for the
  lapse and race the bots for `reserved + 1` free NFTs. This is accepted (owner decision, 2026-11-25): bots
  watching the same threshold make it a race the holder can lose outright, and losing forfeits every
  reserved step.
- **Minting early forfeits the undelivered steps.** A holder who mints with fewer steps in the pot than they
  reserved gets the smaller batch, and the lock ends. The UI must warn about this.
- **A holder who never claims loses their burned NFTs.** The steps they reserved go to the public at lapse,
  so nothing is wasted.
- If the pot is below one step, the holder's `batchMint` reverts `free == 0` and the lock survives.
- A stalled inflow leaves the lock live, but a stall stops public minting anyway. The only extra effect is
  that steps delivered before the stall wait for the holder; `clearLock` covers the case where they never come.
- The holder's batch also collects the full bonus streams (phUSD, Kendu) that accrued during the lock.
- Every burned NFT raises the remaining stakers' APY: fresh mints through mint debt, old staked NFTs by
  leaving the denominator (section 2).

### 3.2 Lockable minter (copy of `BatchNFTMinterNudgeDiscount`)

This is a hand-maintained copy, following the repo's pattern for successors. Its deltas are:

1. **`lockGate`** is owner-settable. `address(0)` means no lock, so the minter behaves byte-for-byte
   like the current one.
2. **`batchMint`** calls `cap = lockGate.authorize(msg.sender, potSteps)` after the stream flush and pot
   read, and before any value moves. The holder is `msg.sender`, so a holder who batch-mints through a
   helper contract is not recognised. The UI must call the minter directly.
3. **`_computeBatch`** uses `free = min(potFree, maxFreePerBatch, cap)`. **The lock cap must not feed the
   overflow boost.** Pot left above `cap` is ordinary unreserved pot for the next batch, not
   `overflowFree`. The tests must pin this.
4. **`potSteps()`** view, as section 3.1 requires.

`previewBatch` gains a `previewBatchFor(address caller)` variant, so the UI can show the holder their
capped batch and show everyone else whether they are locked out.

### 3.3 Tests the story must carry (TDD)

- Non-holder `batchMint` reverts `Locked` while `potSteps < reserved + 1`, and succeeds once the pot reaches
  `reserved + 1`, minting the whole pot.
- The holder's batch is capped at `reserved`. The remaining pot stays and is not counted as boost overflow.
- A holder minting early gets the pot-forced smaller batch, and the lock ends.
- Extending by the holder adds steps and moves the lapse threshold. Extending by anyone else reverts.
- `lock` burns exactly `steps` of `index` from `msg.sender` only. A third party's NFTs are never touched.
- `lock` on a lapsed lock makes the caller the new holder (subject to the gap rule).
- The gate and the minter agree on lapse: `potSteps()` (view) equals the in-batch `potSteps` after the flush.
- A reservation equal to or above `maxFreePerBatch` is refused, and lapse uses the uncapped step count.
- `maxReservedSteps` changes apply to new locks and extensions. An existing lock above a lowered cap
  keeps its reservation.
- `enable()` reverts when prices are outside `maxPriceSpreadBps`, or when the step price does not exceed
  the highest accepted protocol-NFT price (section 6).
- `clearLock` is owner-only and ends a live lock.
- `lockGate == address(0)` reproduces the current minter's behaviour (reuse the existing suite).
- If the public-batch gap is chosen: no new lock after a claim or lapse until a public batch has happened.
- A holder's reverting batch leaves the lock intact.

### 3.4 WBTC NFT on USDC: `UsdcToWbtcAccumulator` dispatcher (yield-claim-nft, new)

**Index 5 keeps its NFT id, and only its dispatcher changes.** `NFTMinterV2.replaceDispatcher(5, new)` swaps
the contract behind the index; `mint` derives the payment token from the dispatcher's `primeToken()`, so
payment becomes USDC with no minter change. Supply is 0 today, so no holder or staker is affected.

**Contract** (extends `ATokenDispatcherV2`, modelled on Uniboost's deferred, authorised `pool`):

| Item | Spec |
|---|---|
| `primeToken()` | USDC, immutable |
| `targetToken` | WBTC `0x2260…C599`, immutable |
| `_dispatch` | Keeps the USDC on the contract; forwards nothing |
| `buy(usdcIn, minWbtcOut, deadline)` | Authorised buyers only (`authVersion` pattern; initialise `authVersion = 1`, since a zero version authorises everyone). Swaps USDC → WBTC on Uniswap to the contract itself. `minWbtcOut == 0` reverts. Output measured as a WBTC balance delta, never the router's return value. Not pause-gated, so the USDC can always be converted |
| Route | Owner-settable router and pool fee (section 5) |
| `treasuryRecipient` | Owner-settable via `setTreasuryRecipient`, **`address(0)` at deploy**. The setter refuses `owner()` (the deployer wallet) but accepts `address(0)`, which switches rescues off again |
| `rescueERC20(token, amount)` | `onlyOwner`, not pause-gated. Sends only to `treasuryRecipient`, with no `to` argument, and reverts while it is `address(0)`. The only way WBTC (or stray USDC) leaves |
| `setAuthorizedBuyer`, `incrementAuthVersion` | Owner; the version bump is the kill switch for every buyer |

**Why the buy is deferred.** A swap inside the minter's `mint` could be sandwiched, because the minter caller
sets no floor. A separate, authorised `buy` with an off-chain quoted floor follows the MEV rule in
`docs/NFT/UniV2PriceTilting.md`, as `UniPoolerV2.pool` and `buyAndBurn` do.

**Operating the buy (phStaging2).** It's a new npm key pair, `wbtc-accumulator:buy:preview` /
`:broadcast`, built like `nudge-discount:buy-and-burn`: a quote script run just before forge sets a non-zero
`minWbtcOut` from a live quote minus a tolerance (default 50 bp, max 100), and the broadcast key ends with the
tax-ledger recorder. Each NFT adds only ~$11, so buys should be batched (e.g. weekly), not per mint.

**Rescue destination.** The WBTC is protocol treasury, so it can only go to the stored `treasuryRecipient`.
That starts unset, so the WBTC cannot leave until the owner deliberately chooses a destination. The setter
rejects `owner()`, which catches the most likely mistake: `0xCad1…D0B6` is both the owner and the owner's
personal and tax wallet.

**Not a lock currency.** Index 5 is never in the gate's `acceptedIndex`. Equal pricing is only for
consistency across the mint page.

**Tests (TDD):** `mint(5)` pulls USDC at the new price and leaves it on the dispatcher; `buy` by a non-buyer
reverts; a version bump de-authorises every buyer; `minWbtcOut == 0` reverts; a floor above the fork quote
reverts; WBTC is measured by balance delta; `rescueERC20` is owner-only, works while paused, reverts while
`treasuryRecipient` is unset and pays only `treasuryRecipient`; `setTreasuryRecipient` is owner-only, rejects
`owner()` and accepts `address(0)`.

## 4. Mainnet cutover (phStaging2)

The script is modelled on `script/DeployMainnetNudgeDiscount.s.sol`: state-gated and re-runnable, with a
Ledger-signed broadcast, a `:preview` fork simulation, a verifier and the ledger recorder. Order:

0. **Preflight.** Read the book, owners, hook ratio, PauserV2 health, the old minter's
   `pendingBuyUSDC` / `pendingStakerPhUSD` (56.64 USDC / 27.9 phUSD on 2026-11-25), and index 5's
   dispatcher, supply (must be 0) and GatherWBTC balance (must be 0).
1. **Freeze the old minter** following the CLAUDE.md deregister rule: `PauserV2.unregister(old)` →
   `old.setPauser(OWNER)` → `old.pause()`.
2. **Drain the old reserve** with `nudge-discount:buy-and-burn`. `rescueERC20` cannot move reserved USDC,
   and `buyAndBurn` is not pause-gated, so it can run after the freeze. The old minter is not retired
   until `pendingBuyUSDC == 0`.
3. **Deploy and configure the new minter**, mirroring live config (discount 50, burn 100, cap/perPoint
   50/3, maxBoost 0, whitelist USDC/phUSD/Kendu, NFTStaker, hook, PSM, sUSDS, route, OWNER as buyer).
   Register it on PauserV2 and the streams (USDC/phUSD/Kendu, 30 days; whitelist before
   `registerStream`).
4. **Deploy the gate** with `minter` set, `enabled = false`, `acceptedIndex` 1/2/3 and the section 5
   values. Register it on PauserV2. Then `newMinter.setLockGate(gate)`.
5. **Authorise on NFTMinterV2.** `setAuthorizedMinter(newMinter, true)` and `setAuthorizedBurner(gate, true)`.
6. **Repoint every donor** to the new minter: Uniboost EYE/SCX/FLX `setRecipient`, UniPoolerV2 and
   NudgeRatchet `setBatchMinter`, SYA `setNudgeAddress`. Require that none still targets the old minter.
7. **Migrate pending stream buffers** through a one-shot `NudgePotForwarder`, as in story 119.
   OWNER is never a recipient.
8. **Convert index 5 to USDC.** The order matters, because index 5's price is stored in raw token units.
   The live 17,624 read as USDC would sell the NFT for **$0.0176**.
   1. `setDispatcherDisabled(5, true)`.
   2. Deploy `UsdcToWbtcAccumulator`. Wire it to NFTMinterV2 as its minter (the dispatcher `setMinter`
      gotcha: `replaceDispatcher` does not do it, and an unwired dispatcher bricks `mint(5)`). Copy
      GatherWBTC's metadata so `uri(5)` survives, set the route, authorise OWNER as buyer, and register it on
      PauserV2.
   3. `replaceDispatcher(5, accumulator)`.
   4. `setGrowthFactor(5, 2)`, matching the protocol NFTs instead of the current 1,200 bp.
   5. The price is set in step 9. Index 5 is re-enabled only after that, and the script refuses to
      re-enable it unless its price equals the equalised protocol price. The gate's guard does not cover
      index 5, because index 5 is not a lock currency, so this script check and the verifier are its guard.

   GatherWBTC is not on PauserV2 and holds nothing, so retiring it needs no deregistration and no rescue.
9. **Equalise prices.** Read the live maximum of `configs(1|2|3).price` (USDC, 6 dp) and `setPrice` indices
   1–3 below it, and index 5, to that value in the same broadcast. Then `setDispatcherDisabled(5, false)`.
10. **`gate.enable()`.** This reverts unless step 9 happened for indices 1–3 (section 6).
11. **Retire the old minter.** `setAuthorizedMinter(old, false)`, then `old.incrementAuthVersion()` once
    its reserve is zero.
12. **Patch the book and verify.** Add `StepLockGate`, the new minter and `UsdcToWbtcAccumulator` keys
    (retire `GatherWBTC`), update `PauserV2Registry`, run `pauser-v2-verify` and a new `step-lock:verify`.
    The verifier asserts that index 5's dispatcher is the accumulator, that its `primeToken()` is USDC, and
    that index 5 has growth 2, is enabled and is priced equal to the others.

The phlimbo-ui story must ship with or before the broadcast. It routes index-4 batch mints to the new
minter, adds the lock button and the early-mint and lapse warnings, and calls the minter directly
(section 3.2). It must also switch the index-5 mint flow from WBTC to USDC approvals and display.
DeployMocks and DeployMocksSepolia get the same gate and the USDC index 5, so the UI can be tested against them.

## 5. Decisions

**Decided by the owner (2026-11-25):**

| Decision | Choice |
|---|---|
| NFTs per step | 1, hardcoded |
| Burn timing | At deposit; no escrow, no refund |
| Lapse | When the pot holds `reserved + 1` whole steps; the public may then mint everything |
| Holder sniping at lapse | Accepted; bots police it |
| Time-based backstop | None; owner `clearLock` for emergencies |
| `maxReservedSteps` | Owner-settable, for experimentation |

**Still open.** Under Configuration Safety, none of these may default silently:

| Parameter | Recommendation | Why |
|---|---|---|
| Public batch between locks | **On** | Without it a holder can claim and relock in one transaction and hold the discount indefinitely. With it, every lock is followed by at least one public batch. |
| `maxReservedSteps` starting value | 10 | Below `maxFreePerBatch` 50 for gas, and still a whale-sized batch. |
| `maxPriceSpreadBps` | 10 | Covers mints between the live price read and `setPrice` in the same broadcast. |
| Accepted indices | 1, 2, 3 (decided: WBTC index 5 never locks) | Equal prices plus the 2 bp self-equalisation make the choice neutral. Watch FLX: with 14 stakers, its APY moves ~30× more per burn than EYE's. |
| WBTC buy route | Uniswap V3 USDC/WBTC 0.3% pool `0x99ac…Bc35` via SwapRouter, single hop | Deepest venue checked on 2026-11-25 (~$5.9M USDC side). The V2 USDC/WBTC pair holds only ~$42k; V2 via WETH works but pays two 0.3% fees. The repo already has `IUniswapV3SwapRouter`. |
| Buy cadence and tolerance | Weekly; 50 bp (max 100) | Keeps gas small against ~$11 per mint; same tolerance rule as `buyAndBurn`. |
| `treasuryRecipient` | Unset at deploy (decided); set later to a contract or multisig | Rescues are impossible until it is set. The setter rejects `owner()`, the deployer wallet. |

## 6. Guarding the price equalisation

**The contract refuses to turn on with unequal prices, so forgetting is not possible.**
`StepLockGate.enable()` reads `configs(i).price` for every accepted index (1, 2, 3) and reverts unless:

- `(max − min) * 10_000 <= maxPriceSpreadBps * min`, and
- the minter's next LSP price exceeds `max`, so the whale's margin at one NFT per step is positive.

The check runs only at `enable()`, never on `lock()`. After launch the prices may drift apart, and burns
pull them back together. A later `disable()` / `enable()` re-checks, and the owner can widen the tolerance
deliberately if needed.

Three further layers make sure no one is surprised at broadcast time:

1. The cutover script does the equalisation itself (step 9), immediately before `enable()` (step 10).
2. `step-lock:verify` asserts that `gate.enabled()` is true and that the three protocol prices were within
   tolerance at the cutover block. It separately asserts index 5's USDC price, growth and dispatcher
   (step 12), since the gate does not check index 5.
3. The nft-staking story's acceptance criteria include the `enable()` guard tests (section 3.3), so the
   guard is audited with everything else.

## 7. Work breakdown

1. **nft-staking:** `StepLockGate` plus the lockable minter, TDD, then audit.
2. **yield-claim-nft:** `UsdcToWbtcAccumulator` dispatcher, TDD, audited in the same round as the gate.
3. **phStaging2:** mocks and Sepolia wiring, mainnet cutover script with `:preview` / `:broadcast`, verifier,
   book patcher, `PauserV2Registry` update, and the `wbtc-accumulator:buy` keys with their quote script.
4. **phlimbo-ui:** index-5 mint on USDC; lock button, holder preview, locked-out notice for everyone else, early-mint and
   lapse warnings, and the minter repoint.
