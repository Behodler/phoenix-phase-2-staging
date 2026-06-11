# ERC4626MarketYieldStrategy — Conservative Principal Crediting Plan

## Purpose

`ERC4626MarketYieldStrategy` acquires its yield-bearing position by **swapping underlying for vault shares through an AMM** rather than depositing directly into the ERC4626 vault (the whole reason it exists — it sidesteps vault withdrawal restrictions like sUSDe's 7-day cooldown). Every deposit therefore crosses an AMM and incurs slippage on the way *in*, and every withdrawal incurs slippage on the way *out*.

Today, on deposit, the strategy credits the client with the **full nominal `amount`** of principal regardless of how many shares the swap actually returned:

```solidity
// ERC4626MarketYieldStrategy.sol:287  (_depositInternal)
clientBalances[token][recipient] += amount;   // full requested amount
totalDeposited[token]            += amount;
```

But the swap (`:276-283`) only delivered shares worth roughly `amount − entry_slippage`. The recorded obligation (`totalDeposited`) therefore exceeds the fair value of the position actually acquired. Because client balances are pooled and yield is distributed **proportionally** by principal weight, a fresh deposit transiently pushes the pool *underwater* relative to its recorded principal and **dilutes the surplus of existing clients**.

**This plan changes `_depositInternal` to credit principal conservatively — `amount` minus the maximum possible entry slippage — so that the pool's recorded obligation never exceeds the fair value of the shares it holds.** Any execution better than worst-case automatically surfaces as yield.

## Why This Is Sound (and Why It Auto-Generates Yield)

Yield in this strategy is **not a stored variable**. It is derived on read:

```solidity
// ERC4626MarketYieldStrategy.sol:138-152  (totalBalanceOf)
totalBalanceOf(client) = totalValue * principal_client / totalDeposited
//   where totalValue = vault.convertToAssets(vault.balanceOf(this))
surplus (yield)        = totalBalanceOf(client) − principal_client
```

`totalValue` is computed from the **shares the contract actually holds**, which reflect what the AMM really delivered. `totalDeposited` is bookkeeping we control. Therefore **anything we choose not to credit as principal becomes the residual that the surplus-skim path picks up** (`_accrueSurplusShares` at `:465-491`). No new accounting plumbing is required — lowering recorded principal raises measured surplus by construction.

### The provable solvency invariant

The fix ties the principal haircut to the **same bound the swap already enforces**, which makes solvency a theorem rather than a hope:

- The swap requires `sharesReceived ≥ minOut = convertToShares(amount) × (1 − bps)` (`:276-277`); it reverts otherwise.
- So fair value of shares acquired = `convertToAssets(sharesReceived) ≥ amount × (1 − bps)` (convert* are linear modulo rounding, and rounding already favors the protocol).
- If we credit `principal = amount × (1 − bps)`, then **fair share value ≥ credited principal, always.**

"Minus max possible slippage" = minus `slippageToleranceBps`, because the swap reverts on anything worse. The haircut and `minOut` are the *same* number — that symmetry is what makes the invariant clean.

### Entry vs exit slippage — only entry needs buffering

The round trip has two slippage events, but the **withdraw path already protects the fund on exit** (`:308-336`): it debits the *requested* principal, delivers only the *actual* AMM output, and caps `sharesToSell` to shares held. The withdrawing client absorbs exit slippage, not the pool. So buffering the *entry* is sufficient; entry-haircut + debit-requested-on-exit together make the full round trip robust.

## The Change

### `_depositInternal` (ERC4626MarketYieldStrategy.sol:267-291)

Replace the full-amount credit with a slippage-haircut credit, tied to the existing `minOut` computation so the two can never drift apart.

```solidity
// Calculate ideal shares and minimum acceptable output
uint256 idealShares = vault.convertToShares(amount);
uint256 minOut      = idealShares * (MAX_BPS - slippageToleranceBps) / MAX_BPS;

// ... swap ...

// Conservative principal: credit the worst-case fair value of the position
// acquired, NOT the nominal amount. Tied to the same slippage bound the swap
// enforces, so fair value of shares received >= creditedPrincipal always.
// The gap between worst-case and actual execution surfaces as protocol yield.
uint256 creditedPrincipal = amount * (MAX_BPS - slippageToleranceBps) / MAX_BPS;
clientBalances[token][recipient] += creditedPrincipal;
totalDeposited[token]            += creditedPrincipal;
```

Notes:
- Keep emitting the **nominal `amount`** in the `Deposited` event (callers still want to know what was sent in); only the *credited principal* changes. Document the distinction in the event NatSpec.
- The withdraw paths (`_withdrawInternal`, `_totalWithdraw`) already operate on `clientBalances`/`totalDeposited` and need no change — they debit whatever was credited.
- `setSlippageTolerance` already exists (`:190-195`). Because credited principal now depends on `slippageToleranceBps` at *deposit time*, a later change to the tolerance does not retroactively alter existing principal — which is correct, principal is locked in at the rate that was live when the position was opened.

### Open decision: haircut size

Two viable options — pick before implementing:

| Option | Credited principal | Effect |
|---|---|---|
| **A (recommended)** | `amount × (1 − bps)` | Buffers exactly the entry slippage the swap permits. Provable solvency invariant. Buffer → yield when execution beats worst-case. |
| **B** | `amount × (1 − k·bps)`, k>1 | Extra conservatism (e.g. also pre-absorbs some future exit/skim slippage). Larger guaranteed yield buffer, but credits clients less principal than strictly necessary. |

Do **not** credit `convertToAssets(sharesReceived)` (mark-to-actual): it is solvent but leaves no buffer, so good execution would *not* show up as yield — defeating the goal.

## Caveats (acknowledged, not blocking)

1. **Buffer-yield is pooled, not attributed.** The surplus generated by the haircut is distributed proportionally across all clients by principal weight at skim time, not credited to the specific depositor who generated it. Consistent with how existing yield already pools in this strategy.
2. **Measured-vs-realized asymmetry on skim.** Surplus is *measured* at `vault.convertToAssets` (fair price) but *realized* by selling through the AMM (`:434-440`), net of exit slippage — see `lib/vault/CLAUDE.md` ("skimSurplus return value vs SurplusSkimmed events"). **Out of scope for this plan:** `skimSurplus` is consumed by internal protocol contracts, not retail, so the snapshot-vs-realized gap is acceptable here.

## TDD Test Plan

Following the repo's mandatory red→green→refactor flow, add to `lib/vault/test/` (new or existing `ERC4626MarketYieldStrategy` test file). Use a mock AMM adapter whose effective swap rate is configurable so slippage can be dialed precisely.

**Red phase — write these failing first:**

1. **Solvency invariant after deposit.** Deposit `amount` through an adapter at worst-case execution (exactly `minOut`). Assert `vault.convertToAssets(vault.balanceOf(strategy)) ≥ totalDeposited(token)`. (Fails today because full `amount` is credited.)
2. **Good execution becomes yield.** Deposit through an adapter giving near-ideal execution (zero effective slippage). Assert `totalBalanceOf(client) > principalOf(client)` by approximately `amount × bps`, i.e. the buffer shows as surplus.
3. **No dilution of an existing client.** Client A deposits; record A's `totalBalanceOf`. Client B then deposits through a slippage-incurring swap. Assert A's `totalBalanceOf` does not decrease (today it does, because B's full nominal principal dilutes the proportional pool).
4. **Principal credited equals the haircut.** Assert `principalOf(client) == amount × (MAX_BPS − bps) / MAX_BPS` after a deposit at a known `bps`.
5. **Tolerance change is not retroactive.** Deposit at `bps₁`; change tolerance to `bps₂`; assert the earlier client's principal is unchanged.

**Green phase:** apply the `_depositInternal` change above (Option A).

**Refactor phase:** factor the haircut into a small `_creditedPrincipal(amount)` helper if it improves readability; keep `minOut` and the haircut computed from the same expression so they cannot drift.

**Regression:** re-run the full `ERC4626MarketYieldStrategy` and `AYieldStrategy` suites; confirm withdraw, `withdrawAsOwner`, `_totalWithdraw`, and skim behavior still pass unchanged.

## Files Touched

- `lib/vault/src/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol` — `_depositInternal` credit logic + `Deposited` event NatSpec.
- `lib/vault/test/` — new TDD tests per the plan above.
- No deployment-script changes in this repo until the submodule pointer is bumped (`forge build` + `git submodule` update + new strategy redeploy, handled separately).

## Out of Scope

- `ERC4626YieldStrategy` (direct deposit/redeem, no AMM) — it has only ERC4626 rounding drift, not market slippage; the full-amount credit there is acceptable. No change.
- Any change to the surplus-skim realization path or its consumers.
