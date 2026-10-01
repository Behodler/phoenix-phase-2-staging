# Balancer Wind-down Plan (BIP-928)

*Written 2026-10-01. On-chain figures come from mainnet block 26,093,540 unless stated otherwise.*

## Summary

Balancer DAO passed BIP-928, an orderly wind-down, with more than 99% of about 17.2M BAL voting. Our phUSD/sUSDS 50/50 pool on Balancer V3 becomes withdrawals-only on **30 October 2026**, and the V3 Vault is paused on **30 November 2026**.

**The damage is smaller than it first looks.** `BalancerPoolerV2._dispatch` only wraps USDS into sUSDS; it never calls Balancer. Pooling into Balancer happens in a separate, authorized-pooler-gated `pool(minBPT)` call. Index-4 NFT minting therefore keeps working after 30 October. The dispatcher simply accumulates sUSDS it can no longer pool. Nothing else on mainnet reads a price from the Balancer pool.

**Decision (2026-10-01): move to a Uniswap V2 phUSD/sUSDS pair, and replace single-sided adds with a buy-and-pool zap.** The zap is the same pattern `Uniboost` already runs on mainnet against the EYE, SCX and FLX Uniswap V2 pairs.

- **Why Uniswap V2 isn't at risk of abandonment:** its contracts are immutable and have no pause switch, so no governance vote can wind it down the way BIP-928 winds down Balancer.
- **Why the zap and not a donation:** on a constant-product pool, a zap lifts price exactly as much as a single-sided add. A plain donation leaks about one sixth of its value to Uniswap's fee switch, which is now live. The zap avoids that leak.

**Deadlines:**

| Date | Event | What we must have done |
|---|---|---|
| 16 Oct | Last day to apply for a V3 pool extension to 30 Nov | Decide whether to apply (recommendation: no, see [Extension decision](#extension-decision)) |
| 30 Oct | Pools paused, withdrawals-only, Recovery Mode enabled where needed | Stop calling `pool()`. Ideally exit the BPT and seed the replacement pool before this date |
| 30 Nov | V3 Vault paused | Protocol BPT fully exited (a proportional recovery exit still works after this, but it's a fallback) |
| ~May 2027 | BAL burn-to-claim treasury distribution begins | Not relevant to us unless we hold BAL |

---

## 1. What BIP-928 changes

These are the technical consequences, according to the Balancer forum thread and the V3 Vault docs:

- **Before 30 Oct:** everything works as it does today.
- **From 30 Oct:**
  - Pausable pools are paused.
  - Recovery Mode is enabled where needed to keep exits open.
  - The bug bounty ends.
  - Balancer will publish its pool-by-pool treatment before 30 Oct. We haven't seen that list yet.
- **What a paused pool blocks:** a paused V3 pool, or the paused Vault after 30 Nov, blocks swaps, `addLiquidity` and non-proportional `removeLiquidity`.
- **What still works:** the proportional exit `removeLiquidityRecovery`. Once the pool or Vault is paused, `enableRecoveryMode` becomes permissionless, so LPs can always get out proportionally.
- **What this means for us:** we lose single-sided exits, the swap route, and single-sided adds. We keep the proportional exit, which is the only exit we want anyway.
- **Infrastructure after 1 Nov:** Balancer's UI shrinks to a withdrawal-only interface. The subgraph and docs stay up through the distribution rounds, which run to about July 2028.

## 2. Everything Balancer touches

### 2.1 Live mainnet state

| Item | Address | State |
|---|---|---|
| Balancer V3 Vault | `0xbA1333333333a1BA1108E8412f11850A5C319bA9` | Holds 34,842.75 phUSD, about 36.8% of phUSD supply (94,566) |
| Balancer V3 Router | `0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd` | Used by `getIdealBPT()` and by manual scripts |
| phUSD/sUSDS pool (50/50 weighted, 0.30% fee) | `0x642BB6860b4776CC10b26B8f361Fd139E7f0db04` | 30,418.87 sUSDS (≈ 33,804 USDS at 1.11128 USDS/sUSDS) and 34,816.80 phUSD |
| Old E-CLP pool | `0x5b26d938f0be6357c39e936cc9c2277b9334ea58` | Dust only (112 wei sUSDS, 1,718 wei phUSD). Ignore it |

**Pool maths:**
- **Spot price:** 33,804 / 34,817 ≈ **0.971 USDS per phUSD**.
- **TVL:** about $67.6k. GeckoTerminal reports $67.1k TVL and **$16.60 of 24h volume**. The pool exists for depth and price support, not trading volume.

**Who owns the BPT** (32,438.77 in total supply):

| Holder | BPT | Share | Underlying (approx.) |
|---|---|---|---|
| `BalancerPoolerV2` `0x7f6874332c4629429d70D15f685A8230323F11F1` (protocol-owned) | 20,401.81 | 62.9% | 19,129 sUSDS + 21,896 phUSD |
| EOA `0xc65faaafbbda520791f344d33497485edf58e8db` (nonce 177, not referenced anywhere in this repo) | 12,036.97 | 37.1% | 11,289 sUSDS + 12,921 phUSD |
| Minimum-supply burn at `address(0)` | 1e-12 | — | — |

**Open question: who owns `0xc65f…e8db`?** If it's a team wallet, it should exit alongside the protocol. If it's a third party, they need warning, because their liquidity is 37% of our depth.

### 2.2 Contracts

| Contract | Deployed? | Balancer dependency | Breaks on 30 Oct? | Action |
|---|---|---|---|---|
| `BalancerPoolerV2` (`lib/yield-claim-nft/src/dispatchers/BalancerPoolerV2.sol`), index 4, `0x7f68…11F1` | Live | `pool()` → `vault.unlock` → `addLiquidity(UNBALANCED)`. `getIdealBPT()` → Router query. `withdrawBPT()` | **`pool()` and `getIdealBPT()` only.** `_dispatch` (the mint path) touches only sUSDS `deposit` and the Sky PSM | Stop pooling. Exit the BPT. Replace the dispatcher at index 4 (section 4) |
| `BalancerPoolerMintDebtHook` `0x4A26…8bD7` | Live | None. The name is historical: it accrues phUSD mint debt on dispatch (ratio 50, recipient `NFTStaker` `0xc851…a13b`, debt currently 0) | No | Repoint to the new dispatcher with `setDispatcher` (no redeploy) |
| `NFTStaker` / `NFTStakerPriceScaled*` (`lib/nft-staking`) | Live | Imports the `IBalancerPoolerMintDebtHook` *interface* only (`pull()`, `mintDebt()`). It doesn't read Balancer or any price | No | None |
| `PromotionUniV2_Eth` (`lib/yield-claim-nft/src/dispatchers/PromotionUniV2_Eth.sol`) | **Not deployed** | Leg A hardcodes `BALANCER_VAULT` and `BALANCER_POOL` as constants and swaps sUSDS→phUSD through `vault.unlock/swap/settle/sendTo` | Would revert on its first `pool()` | Rewrite Leg A for the new venue **before** it is ever deployed |
| `Uniboost` EYE/SCX/FLX, indices 1/2/3 | Live | None. The comments cite `BalancerPoolerV2` as a design ancestor. These already zap into Uniswap V2 (factory `0x5C69…aA6f`) | No | None. **This is the template for the replacement** |
| `NudgeRatchetDelayRelease`, `MintPageView` | Live / superseded | Comments only | No | Refresh comments whenever a file is next touched |

**Why the mint path survives.** Dispatch only wraps and optionally donates:

```solidity
// BalancerPoolerV2._dispatch — no Balancer call anywhere in the mint path
if (poolingUSDS > 0) {
    IERC20(_primeToken).forceApprove(_sUSDS, poolingUSDS);
    IERC4626(_sUSDS).deposit(poolingUSDS, address(this));
}
if (donationEnabled) { ... try this._psmDonate(remainingUSDS) {} catch { ... } }
```

The live donation is currently disabled: `batchDonationSize == 0`, while `psm`, `batchMinter`, `nudgeStreamer` and `maxTout = 1%` are all set. The pooler holds 0 sUSDS and 4.7e-7 USDS of dust.

### 2.3 Scripts and tooling in this repo

**Scripts that break or go stale:**

| File | Role | Action |
|---|---|---|
| `script/DeployMocks.s.sol` (anvil) and `script/DeployMocksSepolia.s.sol` | About 100 references each: `MockBalancerPool`, `MockBalancerVault`, `MockBalancerRouter`, and deploying/wiring `BalancerPoolerV2` at index 4 | Swap in a UniV2 pair (both already deploy the UniV2 stack for Uniboost) and the new pooler. Redeploy Sepolia |
| `src/mocks/MockBalancer{Pool,Vault,Router}.sol` | Mocks for the above | Delete once both deploy scripts stop using them |
| `script/interactions/BalancerECLPInterfaces.sol` | Interfaces for the E-CLP helpers | Archive |
| `scripts/compute-min-bpt-poolerv2.js` | Computes `minBPT` for manual `pool()` calls | Replace with a zap-quote helper (`minPhusdOut`, `minLP`) |
| `scripts/check-phusd-amm-balances.sh` (`npm run mainnet:phusd-amm-balances`) | Reads phUSD held by the Balancer Vault and the Uniswap V4 PoolManager | Add the new pair |
| `npm run mainnet:verify-eclp-fork`, `npm run sim:eclp-rebalance` (`test/VerifyECLPSymmetry.t.sol`, `test/SimulateECLPRebalance.t.sol`) | E-CLP fork tests | Retire. They target the dead E-CLP pool |
| `test/MintPageView.t.sol`, `test/BptBaselinePersistence.t.sol`, `test/VerifyPromotionReadyGuards.t.sol` | Reference BPT and pooler state | Update alongside `DeployMocks` |
| `script/archives/**` (about 35 files) | Historical Balancer scripts | Leave as they are. They're history, not live tooling |

**Address book, extraction and hooks:**

| File | Role | Action |
|---|---|---|
| `server/deployments/addresses.ts` (interface) and `mainnet-addresses.ts` | `BalancerPool`, `BalancerVault`, `BalancerRouter`, `BalancerPooler`, `BalancerPoolerMintDebtHook` keys | Add `PhusdSusdsPair`, `UniswapV2Router` and `UniPooler`. Keep `BalancerPooler` and the Balancer keys until the wind-down is confirmed complete, then remove them |
| `server/extract-addresses.js` | `NFT_BASE_NAMES` includes `BalancerPooler` | Add the new pooler name |
| `wagmi.config.ts`, `hooks/` (`@behodler/wagmi-hooks`) | Generates hooks for `BalancerPoolerV2` and `BalancerPoolerMintDebtHook` ABIs | Add the new pooler ABI. Publish a new hooks version |

### 2.4 Outside this repo

- **Phoenix UI (phlimbo-ui):** the Admin pool action and any price or "buy phUSD" widget depend on the Balancer pool. The UI is outside this project. Section 7 gives the order in which it must change.
- **Aggregators and third parties:** phUSD routing via 1inch, CoW and others currently finds the Balancer pool. Once the new pair exists, routing picks it up automatically.
- **Uniswap V4:** the PoolManager holds 197.76 phUSD. Some small V4 phUSD pool already exists. I haven't identified it, but it's too small to act as the fallback venue.

## 3. Choosing the replacement venue

### 3.1 Requirements

These come from you and from the current design:

1. A traditional 50/50 constant-product curve (`x·y = k`).
2. phUSD paired with **sUSDS**, so the treasury side earns the Sky Savings Rate.
3. A venue that can't be switched off by a governance vote, and that aggregators will keep routing.
4. A way to deploy sUSDS that **both deepens liquidity and raises the phUSD price**, as today's single-sided add does.
5. Integration effort proportionate to a $67k pool.

**sUSDS depth elsewhere doesn't matter much.** sUSDS is an ERC4626 over USDS with instant, fee-free deposit and redeem, and USDS↔USDC goes through the Sky PSM. Aggregators can therefore reach sUSDS via USDC/USDS plus a wrap. The depth that matters is depth in *our* pair.

This is lucky, because sUSDS barely trades on Uniswap V2: the only sUSDS/USDS V2 pair holds 0.27 sUSDS, and there is no sUSDS/USDC or sUSDS/WETH V2 pair. The deepest sUSDS pools are:
- OHM/sUSDS on Uniswap V3: $11.6M.
- DOLA/sUSDS on Curve: $7.2M.
- XAUt/sUSDS on Uniswap V4: $2.4M.
- frxUSD/sUSDS on Curve: $1.6M.

(The research did not confirm that every aggregator routes the ERC4626 wrap. 0x, 1inch and ParaSwap are generally known to; Odos and CoW were not confirmed.)

### 3.2 Uniswap V2 in depth

Your worry is that V2 gets abandoned as it loses popularity. **V2 is losing trading share, but it can't be switched off.**

**Usage** (DefiLlama, pulled 2026-10-01):

| Metric | Uniswap V2 (Ethereum) | For comparison |
|---|---|---|
| TVL | $898M ($1.05B on all chains) | V3 $941M, V4 $678M, Curve $1.24B |
| 30-day volume | $166M ($11.3M/24h) | V4 $13.9B, V3 $10.6B |
| Share of Uniswap mainnet volume | ~0.7% | — |

**Pair creation** (factory `allPairsLength`, read on-chain):

| When | Pairs |
|---|---|
| 365 days ago | 459,198 |
| 90 days ago | 514,705 |
| 30 days ago | 520,297 |
| Now | 523,402 |

That is about 3,100 new pairs in the last 30 days and about 64,000 in the last year, so people are still creating V2 pairs every day.

**Why it can't be abandoned the way Balancer was:**
- **Immutability:** the V2 factory, pair and router contracts have no pause, no upgrade and no owner-controlled kill switch.
  - Governance controls only `feeTo`, and the protocol fee is hard-capped at 1/6 of LP fees.
  - BIP-928 can pause Balancer pools only because V3 has pause and recovery authority built in. V2 has no equivalent.
  - The worst case for V2 is **neglect** (the UI or aggregators deprioritising it), not **shutdown**.
- **Governance direction:** the research found no deprecation statement from Uniswap governance or Uniswap Labs. The trend runs the other way: the UNIfication proposal of December 2025 switched V2 fees *on* (so V2 now earns the DAO revenue), and there is a temp check to deploy V2 on more chains.
- **Routing:** 1inch, CoW, 0x/Matcha, Velora/ParaSwap and Odos all route V2 pairs as standard. Uniswap's SwapRouter02 and Universal Router route V2 too.
  - Unverified: whether app.uniswap.org still lets users create *new* V2 positions. Our tooling doesn't need that, because we add liquidity through the router contract.
- **Operational familiarity:** our own `Uniboost` dispatchers already pool into three V2 pairs on mainnet, so the interfaces, tests and ops runbooks already exist.

**Cost of the fee switch.** The UNIfication switch is live: V2 factory `feeTo` = `0xf38521f130fcCF29dB1961597bc5d2B60F995f85`. Two things follow:
- LPs earn 0.25% of the 0.30% fee, and the protocol takes 0.05%. At our volume that's negligible.
- The fee is minted as `1/6` of the growth in `√k` since the last mint or burn, and any growth counts, not only trading fees. So a donation (transfer + `sync()`) leaks about 1/6 of its value to Uniswap. Section 5 explains why that rules donations out.

### 3.3 Alternatives compared

| Venue | Curve fits 50/50? | Kill-switch risk | Liquidity and routing | Raise-price mechanism | Integration cost | Verdict |
|---|---|---|---|---|---|---|
| **Uniswap V2** | Yes, native `x·y=k` | None (immutable, no pause) | $898M TVL. Universal aggregator support. Low trading share | Buy-and-pool zap. `sync()` donation works but leaks 1/6 | **Lowest.** `Uniboost` pattern already live | **Recommended** |
| **Uniswap V4, hookless, full-range** | Yes. A full-range position is `x·y=k` | None on the core (PoolManager has no pause) | Largest Ethereum DEX ($13.9B/30d). Aggregators index hookless pools | Zap only. `donate()` pays in-range LPs as fees and **does not move price** | Medium-high: unlock callback, `PositionManager` NFT, flash accounting. Our Balancer V3 code has the same unlock shape, which partly offsets this | Strong second choice. Pick it if the volume-venue argument matters more than simplicity |
| **Uniswap V3, full-range** | Yes | None | $941M TVL. OHM/sUSDS ($11.6M) is a treasury-owned precedent | Zap only. No donate or sync | Medium: position NFT, no gain over V2 at full range | No advantage over V2 for a full-range position |
| **Curve twocrypto-ng** | No. Concentrated around an EMA-repegging `price_scale` | Low (immutable pools) | $1.24B TVL. Strong in stables. DOLA/sUSDS is the deepest active sUSDS pool | Single-sided adds pay an imbalance fee. Repeg is lagged and parameter-driven, so the price response is less predictable | Medium, plus A/gamma/fee tuning | Poor fit for "push price with treasury sUSDS" |
| **Curve stableswap-ng** | No | Low | As above | — | Medium | Wrong for a non-pegged pair (phUSD 0.97, and sUSDS drifts upward against USDS) |
| **Fluid DEX** | No | Governance-listed | $220M TVL / $3.1B per 30d | — | Pools are governance-listed, not permissionless. DEX v2 still rolling out | Not available to us today |
| **Ekubo (Ethereum)** | Full range is possible | Extension-based | $3.7M TVL | Zap | Medium-high | Too small |
| **Sushi (V2 fork)** | Yes | V2 contracts are immutable, but the org has had years of turmoil (ownership changed Dec 2025) and front-end/router churn | $25M TVL on Ethereum | Zap | Low (V2 ABI) | Same code as Uniswap V2 but with less routing. No reason to prefer it. Your instability concern stands |
| **PancakeSwap on Ethereum** | V2: yes | Immutable | V2 $1.9M, V3 $27M | Zap | Low | Too little presence on mainnet |
| **Bunni v2, Balancer forks, CoW AMM** | Various | High | Bunni has $0.2M post-exploit. The BIP-929 fork was rejected. CoW AMM's future is unclear after the wind-down | — | — | Avoid |

**Decision (2026-10-01): Uniswap V2 phUSD/sUSDS, 0.30% fee** (the same fee as the Balancer pool today).
- **Revisit Uniswap V4 if:** aggregator routing to our V2 pair turns out to be poor in practice, or the Uniswap front-end drops V2.
- **Cheap exit if we do:** the migration is repeatable. Burn the V2 LP and add to V4 full-range, with one dispatcher swap at index 4.

### 3.4 Uniswap V2 vs Uniswap V4 hookless full-range

**Fees and NFTs are not the main differences.** In fact the NFT is optional on V4. If our pooler calls the `PoolManager` directly, the position is just a storage entry keyed by `(owner = pooler, tickLower, tickUpper, salt)`, and no NFT exists. The `PositionManager` NFT is only a convenience wrapper. The differences that matter are below.

| Concern | Uniswap V2 | Uniswap V4 (hookless, full-range) |
|---|---|---|
| Fee compounding | **Automatic.** Fees stay in the reserves, so our LP's depth grows on its own | **Manual.** Fees accrue as owed tokens beside the position. Depth grows only if the pooler collects and re-adds them (each `modifyLiquidity` call returns accrued fees into the caller's delta, so `pool()` could reinvest them every time) |
| Integration shape | Two router calls: `swapExactTokensForTokens` and `addLiquidity` | One `unlock` callback containing `swap`, `modifyLiquidity` and a net `settle`/`take`. This is the same shape as our Balancer V3 code. phUSD never leaves the PoolManager, because only the net sUSDS is settled |
| Liquidity maths | Reserves `x`, `y` | `sqrtPriceX96`, ticks and liquidity `L`. Full range means ticks at `MIN/MAX_TICK` aligned to the tick spacing, with `L` from `LiquidityAmounts.getLiquidityForAmounts`. More rounding edges to test |
| Optimal zap | Closed form for a 0.30% fee (section 4) | The same closed form with the pool's fee `f` and the virtual sUSDS reserve `L / sqrtP` (equal to the real reserve at full range) |
| Pool creation | `createPair`. A hostile pre-seed with real liquidity costs the attacker money, and our seeding guard refuses to add to a non-empty pair | `initialize(key, sqrtPriceX96)` sets a price before any liquidity. Pool IDs are deterministic, so someone can initialize at a hostile price first. With zero liquidity, a free swap moves it back, so it's a nuisance, not a loss |
| Protocol fee | Live. 1/6 of the LP fee, hard cap 1/6 | Up to 0.1% of swap volume per pool, set by the fee controller. Mainnet status unverified |
| Price-moving donation | `transfer` + `sync()` works (leaks 1/6) | `donate()` pays in-range LPs as fees and does not move price |
| Fee tier | Fixed 0.30% | Any fee and tick spacing |
| Volume and routing | ~0.7% of Uniswap mainnet volume. Universally routed | The largest Ethereum DEX. Indexed by the major aggregators. Others can create competing pools for the pair, including hooked ones |
| Dependencies | Router02 and pair interfaces (already in `yield-claim-nft` for Uniboost) | `v4-core` interfaces and libraries (`TickMath`, `StateLibrary`), plus `LiquidityAmounts` from `v4-periphery`. Larger audit surface |

**How the V4 zap would work inside a single `unlock`:**
1. **Read state:** `slot0` and liquidity via `StateLibrary`. Compute `s` from the virtual sUSDS reserve.
2. **Swap:** `swap(key, zeroForOne = sUSDS→phUSD, -s)`. Our delta becomes `-s` sUSDS and `+phusdOut` phUSD.
3. **Add liquidity:** compute `L` for `(a − s, phusdOut)` at the post-swap price, then `modifyLiquidity(key, {fullRange, +L, salt})`. The delta becomes about `-(a − s)` sUSDS and `-phusdOut` phUSD, plus any accrued fees.
4. **Settle:** `sync(sUSDS)`, transfer `a` sUSDS, `settle()`, then `take` any phUSD or sUSDS dust left in the net delta.
5. **Guards:** `minPhusdOut` on the swap and `minL` on the liquidity.

**Decision: Uniswap V2** (confirmed 2026-10-01).
- For protocol-owned liquidity whose purpose is depth, V2's automatic compounding is a real advantage. On V4 we'd have to reinvest fees deliberately.
- V2 reuses the tested Uniboost interfaces.
- V4's volume advantage helps traders, not a $67k pool that trades $16 a day.
- V4 makes sense if routing to the V2 pair proves poor. The plan makes that a repeatable dispatcher swap at index 4.

## 4. Migration path

The plan keeps the index-4 NFT id, price curve and mint-debt hook exactly as they are, and changes only what happens to the accumulated sUSDS.

The build follows four stages in strict order. Each stage finishes, and is audited, before the next begins:

| Stage | What gets built | Gate to move on |
|---|---|---|
| 1 | New contracts, a cutover dress rehearsal in `DeployMocks`, `ContractAddresses` changes | Contract and rehearsal audit passes. The UI (a separate project) can then adapt against the anvil stack |
| 2 | npm keys and script for the mainnet cutover | Script audit passes (fork preview clean) |
| 3 | `DeployMocksSepolia` switched to a fresh deploy of the new contracts (no rehearsal) | Sepolia preview clean |
| 4 | Execution: UI in maintenance, mainnet cutover, fresh Sepolia deploy, UI back up | Post-cutover verification passes |

### Holding pattern until the cutover

**Funds that land on the pooler before the cutover are safe.**
- A mint sends USDS to `BalancerPoolerV2`, which wraps it into sUSDS and keeps it. The pooler held 0 sUSDS at block 26,093,540.
- Only three functions move sUSDS out of the pooler:
  - `pool(minBPT)` (authorized poolers only). It deposits the sUSDS into the Balancer pool, and the BPT is minted back to the pooler itself (`to: address(this)`). It is value-preserving, not a withdrawal.
  - `rescueERC20` (owner only).
  - `withdrawBPT` (owner only).
- `dispatch` is `onlyMinter`. `_psmDonate` is callable only by the pooler itself, and the donation is disabled (`batchDonationSize == 0`).
- From 30 October, `pool()` reverts because the Balancer pool is paused, so after that date the sUSDS simply accumulates.
- The remaining exposure is the same as always: the owner key and Sky's sUSDS contract.

**Recommended action: revoke the four authorized poolers.** Until 30 October, any of these can still call `pool()` and push sUSDS into the dying pool:

| Pooler | What it is |
|---|---|
| owner `0xCad1…D0B6` | Owner |
| `MultiPooler` `0xd1E5…7b51` | Gated to its own `pooler` |
| `0x186c…a77F` | A 7702-delegated EOA, granted by a `Temp.s.sol` transaction |
| `0x6309…d476` | An EOA, granted by a `Temp.s.sol` transaction |

- **Why revoke:** that isn't theft, because the BPT stays on the pooler. But every sUSDS added has to come back out through the exit, and a `pool()` with a loose `minBPT` is sandwichable.
- **How:** one owner transaction, `BalancerPoolerV2.incrementAuthVersion()`, revokes all four at once.
- **Also, before 16 Oct:** make the extension decision (see [Extension decision](#extension-decision); the recommendation is not to apply), and find out who owns the `0xc65f…e8db` LP.

### Stage 1: Contracts, dress rehearsal, addresses, audit

#### 1a. `UniPoolerV2` (working name) in `yield-claim-nft`, TDD

It is `BalancerPoolerV2` with the Balancer parts removed and a Uniswap V2 zap in their place.

**What is kept:**
- The `_dispatch` override copied **verbatim**: the USDS→sUSDS wrap, the PSM donation through `NudgeStreamer`, and the `try/catch` isolation.
- Every donation setter, the authorized-pooler versioning, `rescueERC20` (which is also the LP exit), and `primeToken() == USDS`. The hook, NFT id and minter all see an identical dispatcher.

**What is removed:** `IUnlockCallback`, `unlockCallback`, `getIdealBPT`, `withdrawBPT`, and the vault and router immutables.

**What is new:**
- Immutables `_router` (Uniswap V2 Router02 `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`) and `_pair`. The constructor validates that `{pair.token0, pair.token1} == {sUSDS, phUSD}`.
- `pool(uint256 sUSDSIn, uint256 minPhusdOut, uint256 minLP)`, and the view `quotePool(uint256 sUSDSIn) returns (uint256 swapIn, uint256 phusdOut, uint256 expectedLP)`.

**The efficiency requirement is met by computing the swap amount on-chain.** The contract reads the pair's reserves at execution time and derives the exact swap from them:

```solidity
// r = live sUSDS reserve read inside pool(), a = sUSDSIn, 0.30% fee:
//   s = (sqrt(r * (r * 3988009 + a * 3988000)) - r * 1997) / 1994
// Swapping s leaves (a - s) sUSDS and phusdOut phUSD in exactly the post-swap reserve ratio,
// so addLiquidity consumes both sides with at most wei-level rounding dust.
```

**Why it can't be sized off-chain.** If the UI computed the swap amount itself, any price movement between quote and execution would leave one side over-supplied, and the router would refund the surplus. Deriving `s` from the reserves the swap actually executes against removes that failure mode entirely:
- A front-run changes `s` and the price we buy at, but not the leftover, which stays near zero.
- The worst the front-run can do is make us buy at a worse price, and that is what the slippage parameters bound.

**The UI's job** is to call `quotePool(sUSDSIn)` and then call `pool(sUSDSIn, minPhusdOut, minLP)`:
- `minPhusdOut` and `minLP` are `quotePool`'s outputs reduced by a tolerance.
- The UI never passes `s`.

**Configuration Safety:**
- `minPhusdOut` and `minLP` must be non-zero.
- There is **deliberately no price ceiling.** Pooling that pushes phUSD above the $1 mint price is intended: arbitrageurs then mint phUSD through `PhusdStableMinter` and sell it into the pair, and every such mint adds collateral to the yield strategies, which grows protocol-owned yield.

**Tests:**
- The zap consumes both sides to within dust across a range of reserve sizes and `sUSDSIn` values.
- A front-run reserve shift reverts on `minPhusdOut` or `minLP`, and never strands a refund.
- `pool()` reverts on an empty pair.
- Dispatch still works while the pooler is paused.
- The donation branch passes the existing `BalancerPoolerV2` dispatch suite unchanged.
- A mainnet-fork test runs against the real V2 router.

`PromotionUniV2_Eth` Leg A gets the same treatment in the same stage: replace the Balancer swap with a V2 `swapExactTokensForTokens(sUSDS→phUSD)`. It isn't deployed, so there's nothing to migrate.

#### 1b. Cutover dress rehearsal in `DeployMocks.s.sol` (anvil)

The anvil script first builds the stack as it exists on mainnet today, then performs the exact mainnet cutover sequence from Stage 2 against it. This mirrors how the StableStaker V1→V2 and DOLA repoint cutovers were rehearsed.

**Steps:**
1. **Build today's stack:**
   - Deploy the mock Balancer pool and `BalancerPoolerV2` at index 4.
   - Mint some NFTs so sUSDS accrues, and `pool()` it so the pooler holds BPT.
2. **Run the cutover sequence** (Stage 2 steps 1–10).
3. **Leave the post-cutover state as the anvil state the UI develops against.** The UniV2 factory, router and WETH are already deployed there for Uniboost.

**Work item: the mocks need a proportional exit.** `MockBalancerVault` has no `removeLiquidity` today, so it needs a proportional exit (and ideally a recovery exit) for the rehearsal to be faithful.

Once the mainnet cutover has executed, the rehearsal is retired, together with the Balancer mocks. The same thing happened to the phlimbo V1→V2→V3 rehearsals.

#### 1c. `ContractAddresses` changes

**Keys to add or remove:**

| Key | Change |
|---|---|
| `PhusdSusdsPair` | Add |
| `UniswapV2Router` | Add. The comment in `mainnet-addresses.ts` currently says the UniV2 stack is anvil-only and filtered out of extraction, so `extract-addresses.js` needs updating too |
| `UniPooler` | Add (the new pooler) |
| `BalancerPooler`, `BalancerPool`, `BalancerVault`, `BalancerRouter` | **Keep** through the cutover. `BalancerPooler` keeps pointing at the retired pooler. Remove these keys in a later story, once you're satisfied the wind-down is complete (BPT fully exited, old pooler drained and paused) |

**Pooler key: decided.** Both keys coexist during the wind-down: `UniPooler` is the live index-4 dispatcher, and `BalancerPooler` names the retired one. Removing the old key is a separate, later change.

**`BalancerPoolerMintDebtHook` stays as it is.** The contract is unchanged, and renaming its key would break consumers for no gain.

**Files to update in step:** `addresses.ts` (the generated interface), `mainnet-addresses.ts`, `local-addresses.ts`, `server/extract-addresses.js` (`NFT_BASE_NAMES`), `wagmi.config.ts` (the new pooler ABI), and a new `@behodler/wagmi-hooks` version.

#### 1d. Audit

**Audit** the new contracts plus the `DeployMocks` rehearsal. For consistency with previous stories, use the audit pipeline (code-scanner/econ-scanner on the contracts, script-auditor on the rehearsal).

**UI adjustments are out of scope for this project.** Their order relative to these stages is in section 7.

### Stage 2: Mainnet cutover npm keys, then audit

This is a new `script/DeployMainnetUniPoolerCutover.s.sol`. It carries the usual npm keys:

| npm key | Purpose |
|---|---|
| `unipooler-cutover:preview` | Fork simulation |
| `unipooler-cutover:broadcast` | Ledger broadcast. Not prefixed with the preview |
| `unipooler-cutover:verify` | Post-broadcast checks |

The script uses a progress file, `progress.unipooler-cutover.1.json`. **A crash mid-broadcast poisons the progress file**, so resume from receipts, not from the progress file.

**Ordering and preconditions.** The sequence below is the same one the Stage 1 rehearsal runs:

0. **Preconditions** (all `require`d):
   - The pooler's authorized-pooler set is revoked.
   - The pair doesn't exist, or its reserves are `(0,0)`.
   - Every configuration value is read live.
1. **Deploy `UniPoolerV2`,** but don't wire it in yet.
2. **Take the BPT out:** `BalancerPoolerV2.withdrawBPT(OWNER, fullBalance)`.
3. **Proportional exit:**
   - Before 30 Oct: `removeLiquidityProportional`.
   - After 30 Oct: `removeLiquidityRecovery`.
   - `minAmountsOut` is the live proportional share minus a tight tolerance. It is never 0.
4. **Seed the pair in one atomic helper call.** The helper runs `addLiquidity` with **all** the recovered sUSDS and phUSD, with `to = UniPoolerV2`. The proportional exit returns tokens in exactly the Balancer pool's reserve ratio, so seeding with both amounts carries the existing price over unchanged and leaves nothing behind (decision 3). Doing it in one call means the new price can't be sandwiched between creating the pair and the first add.
5. **Clean the hook ledger:** `BalancerPoolerMintDebtHook.pull()`.
6. **Repoint the hook:** `hook.setDispatcher(UniPoolerV2)`, then `UniPoolerV2.setHook(hook)`.
7. **Configure `UniPoolerV2`:**
   - `setMinter(NFTMinterV2)`. `replaceDispatcher` doesn't wire this, and without it index 4 bricks.
   - The PSM, `maxTout`, `batchMinter`, `nudgeStreamer` and `batchDonationSize` values, each copied live from the old pooler.
   - `setAuthorizedPooler` for the same four poolers as today (owner, `MultiPooler`, `0x186c…a77F`, `0x6309…d476`).
   - Register with the Pauser.
8. **Swap the dispatcher:** `NFTMinterV2.replaceDispatcher(4, UniPoolerV2)`.
9. **Move leftovers:** `BalancerPoolerV2.rescueERC20(sUSDS, UniPoolerV2, balance)` for sUSDS accrued since the holding pattern began, plus a USDS dust sweep.
10. **Retire the old pooler:** pause it and unregister it from the Pauser.
11. **Verify:**
    - `configs(4).dispatcher` is the new pooler.
    - `hook.dispatcher()` is the new pooler.
    - The pair's reserves match what was seeded.
    - The new pooler holds the LP.
    - A forked test mint dispatches, wraps and accrues debt.
    - A `pool()` preview with `quotePool` floors succeeds.

**Audit:** run script-auditor on the cutover (fork preview, intent conformance, side effects) before Stage 3 starts.

**Minimum viable fallback.** If Stages 1–2 slip past 30 October, nothing breaks and nothing is lost. Mints keep accruing sUSDS on `BalancerPoolerV2`. The BPT can still be recovered through `removeLiquidityRecovery`, and step 3 already allows for that.

### Stage 3: Sepolia fresh deployment

`DeployMocksSepolia.s.sol` deploys the new contracts directly: a mock-token V2 pair plus `UniPoolerV2` at index 4, with the Balancer mocks removed and **no cutover rehearsal**. This is the same policy as the story-098 script, which dropped every anvil-only rehearsal. Update the script header's "dropped/kept" list to match.

**Legacy keys on Sepolia.** The `ContractAddresses` interface keeps the Balancer keys until the wind-down is complete, and `generate:ts-sepolia` fails loudly on a key-set mismatch. With no Balancer mocks deployed, Sepolia must therefore emit zero-address placeholders for `BalancerPooler`, `BalancerPool`, `BalancerVault` and `BalancerRouter`. This is the same convention `mainnet-addresses.ts` uses for undeployed keys.

**Gate:** `forge build --sizes`, `forge fmt --check`, `forge test` and `npm run deploy:sepolia-preview` all run clean.

### Stage 4: Execution

1. Put the UI into maintenance mode (UI step U3).
2. `unipooler-cutover:preview`, then `unipooler-cutover:broadcast` (Ledger), then `unipooler-cutover:verify`.
3. Patch `mainnet-addresses.ts`.
4. Run `npm run deploy:sepolia` for the fresh Sepolia set, then commit the regenerated `sepolia-addresses.ts`.
5. Publish the hooks package, then release the new UI build and lift maintenance once verification passes (UI step U3).
6. Make the first `pool()` of the accumulated sUSDS through the new pooler.

### After 30 November

- Confirm the Balancer Vault holds none of our value: pooler BPT = 0, owner BPT = 0.
- Delete the Balancer interfaces in `yield-claim-nft` once nothing compiles against them.
- Update or delete the Balancer-era memory notes.

## 5. The pooling strategy: single-sided add vs buy-and-pool vs donation

**On a 50/50 constant-product pool, all three ways of committing Δ sUSDS lift the price by the same amount.** Only who owns the result differs.

Take reserves `X` sUSDS-value and `Y` phUSD, with spot price `p = X / Y`:

| Method | Resulting reserves | New price | LP minted to us | Leakage |
|---|---|---|---|---|
| Balancer single-sided add (today) | `(X+Δ, Y)` | `(X+Δ)/Y` | Yes (BPT for Δ, minus swap fee on the implied imbalance) | Implied swap fee, mostly back to LPs (us) |
| **Buy-and-pool zap** (swap `s`, add rest) | `(X+Δ, Y)` (swap moves `s` in and `phUSD` out, then the add returns that phUSD) | `(X+Δ)/Y` | **Yes** (LP for the whole Δ, minus 0.3% on `s`) | 0.3% on `s ≈ Δ/2`. 5/6 of that accrues to LPs (≈ us), 1/6 to the Uniswap fee switch |
| Donation (`transfer` + `sync()`) | `(X+Δ, Y)` | `(X+Δ)/Y` | **No.** Value spreads pro-rata to all LP holders | ~1/6 of Δ to Uniswap `feeTo` at the next mint/burn (via the `√k` growth rule). Any non-protocol LP share also leaks. Sandwichable without a pre-check |

**Worked example at today's reserves** (X ≈ 33,804, Y ≈ 34,817, p ≈ 0.971):

| Δ (USDS value in sUSDS) | Price after |
|---|---|
| 250 | 0.978 |
| 500 | 0.985 |
| 1,000 | 0.9996 |

**The zap is the right choice.** It reproduces the current strategy's price-and-depth effect exactly, and the protocol keeps ownership of everything it adds. It is also the "protocol tokens approach" `Uniboost` already runs for EYE, SCX and FLX, so it is the design you suggested.

**Why not donate:**
- **Fee leak:** with the V2 fee switch live, a donation leaks about 1/6 of its value to Uniswap.
- **Sandwich exposure:** a searcher buys phUSD first, lets the donation lift the price, and sells into it. They capture about `Δ·a/(X+a)` for a front-run of size `a`, which is profitable once Δ exceeds roughly 0.6% of pool depth. At today's size that is about $200–400.
- **Mitigation, if ever needed:** a reserve-ratio pre-check makes donation safer. It still loses the 1/6 to the fee switch.
- **Uniswap V4's `donate()` is a different thing entirely:** it pays in-range LPs as fees and doesn't move the price at all.

**Pushing through the mint price is intended.**
- **The pool is shallow:** about $1k of sUSDS moves phUSD from 0.971 to peg, so a modest `pool()` can lift the price above $1.
- **Why that's wanted:** above $1, arbitrageurs mint phUSD 1:1 through `PhusdStableMinter` and sell it into the pair. Every such mint adds collateral to the yield strategies, and more collateral means more protocol-owned yield.
- **Consequence:** the pooler has no price ceiling. Only `minPhusdOut` and `minLP` bound each call, and they exist to stop sandwiches, not to cap price.

**Arbitrage doesn't need another phUSD venue.** The mint-and-sell loop runs through `PhusdStableMinter`, the pair, the sUSDS redeem and the Sky PSM, so it works even if we are the only phUSD liquidity on Uniswap V2.

## 6. Decisions and open questions

### Extension decision
**Recommendation: do not apply for the 30 Nov extension.**
- We need Balancer only for a proportional exit, and that stays available after 30 Oct through `removeLiquidityRecovery`.
- Our $16/day of volume doesn't justify asking Balancer to keep the pool running.
- Applying anyway would keep the swap route alive four weeks longer as a safety margin. That is worth it only if the Stage 4 cutover can't happen before 30 Oct.

### Decisions (2026-10-01)

| # | Question | Decision |
|---|---|---|
| 1 | Who owns the `0xc65f…e8db` LP (37%)? | Known to the owner, who will contact them directly |
| 2 | Uniswap V2 or Uniswap V4 hookless full-range? | **Uniswap V2**, 0.30% fee. V4 stays the fallback if routing to the V2 pair proves poor (see [3.4](#34-uniswap-v2-vs-uniswap-v4-hookless-full-range)) |
| 3 | Seeding price | Carry over the existing Balancer price |
| 4 | Recovered phUSD: re-pool or burn? | Moot. Carrying the price over re-pools all of it, because the proportional exit already returns tokens at that price ratio |
| 5 | LP custody | The new pooler contract |
| 6 | Pooler key | Keep both `BalancerPooler` and `UniPooler` until the wind-down is confirmed complete, then remove the old key and the Balancer keys |
| 7 | Authorized poolers | Re-authorize the same four on the new pooler |
| 8 | UI story | Out of scope for this project |

## 7. UI change sequence (phlimbo-ui)

The UI is outside this project. This section only records **when** the UI must change relative to the stages above, and **what** must change. Implementation belongs to the phlimbo-ui story.

| Step | When | What changes |
|---|---|---|
| U1 | After the Stage 1 audit, against the anvil stack | <ul><li>Adopt the new hooks package</li><li>The Admin pool action targets `UniPooler`'s zap, with slippage floors taken from `quotePool`. This replaces the BPT-based pool action</li><li>The pooler balance display reads `UniPooler`</li><li>Price and "buy phUSD" widgets read the phUSD/sUSDS V2 pair</li><li>Live features stop depending on the Balancer keys. Those keys stay only for legacy or wind-down display</li></ul> |
| U2 | After Stage 3, against the fresh Sepolia set | <ul><li>Verify U1 end to end on Sepolia</li><li>Zero-address legacy Balancer keys must be tolerated</li></ul> |
| U3 | Stage 4 | <ul><li>Maintenance mode on before the cutover broadcast</li><li>Release the build carrying the updated mainnet addresses and hooks</li><li>Lift maintenance only after `unipooler-cutover:verify` passes</li></ul> |
| U4 | After the wind-down is confirmed complete | Remove the legacy Balancer displays in the same release that drops the old keys from `ContractAddresses` |

## Sources

**Balancer wind-down:**
- [KuCoin: Balancer community approves BIP-928](https://www.kucoin.com/news/flash/balancer-community-approves-bip-928-orderly-liquidation-proposal)
- [KuCoin: pools remain active until 30 Oct](https://www.kucoin.com/news/flash/balancer-community-votes-to-orderly-wind-down-liquidity-pools-to-run-until-october-30)
- [Unchained: Balancer is shutting down](https://unchainedcrypto.com/balancer-is-shutting-down-with-payouts-estimated-at-about-16-cents-per-bal/)
- Balancer forum: *BIP-xxx Orderly wind-down of Balancer and distribution of the treasury* (forum.balancer.fi/t/…/7107)
- Balancer V3 Vault API docs (docs.balancer.fi): pause and Recovery Mode semantics

**Uniswap:**
- Uniswap UNIfication: blog.uniswap.org/unification; gov.uniswap.org/t/unification-proposal/25881
- Uniswap V4 PoolManager `donate` reference: docs.uniswap.org/contracts/v4/reference/core/PoolManager

**Other venues:**
- Curve twocrypto-ng docs: docs.curve.finance/developer/integration/twocrypto-ng
- Fluid DEX v2: blog.instadapp.io/fluid-dex-v2/

**Market data:**
- TVL and volume: DefiLlama API (api.llama.fi), pulled 2026-10-01
- Pool data: GeckoTerminal API (sUSDS pools, our pool's volume), pulled 2026-10-01

**Read directly from mainnet at block 26,093,540:**
- Uniswap V2 factory `allPairsLength` history and `feeTo`
- sUSDS V2 pairs
- Balancer pool balances and BPT holders
- Live pooler and hook configuration
