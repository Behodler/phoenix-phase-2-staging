# The Phoenix Protocol, Explained in Layers

*A build-it-up walkthrough of how Phoenix fits together — written so each idea rests on the one before it.*

---

## How to read this document

Phoenix is not a pile of features. It is one idea — **protocol-owned yield** — wrapped in ring after ring of mechanism, where each new ring only becomes *possible* because of the ring underneath it, and each new ring *strengthens* the rings it sits on.

The metaphor we'll use throughout is a **tree's growth rings**. A tree doesn't grow by bolting on parts; it lays down a new ring of living wood around the existing trunk every season. The old rings give the new ring something to grow on; the new ring protects and feeds the old. Cut the trunk across and you see the whole history at a glance — a single organism, not a kit of parts. That's the shape of Phoenix, and it's why we call its core behaviour the **evergreen effect**.

Read it top to bottom. Each section ends with a single sentence: *"Because of this, we can now build…"* — that sentence is the seed of the next ring.

---

## The Heartwood — Protocol-Owned Yield

Start with the problem every stablecoin has to solve: **what makes the coin worth a dollar?**

Historically there have been two honest answers, and one dishonest one:

1. **Fully redeemable / asset-backed.** Every coin is a claim on something real you can take back — dollars in a bank, gold in a vault. The backing *is* the value.
2. **Debt-backed.** The coin is born when someone takes on a collateralized loan. The debt — and the obligation to repay it — is what stands behind the coin.
3. **Purely algorithmic.** A formula expands and contracts supply to chase the peg. With no redeemability and no debt underneath it, the algorithm has *no bite*: nothing forces the price back to a dollar, and inflation eventually runs away with itself. Every purely algorithmic coin that has lasted did so by quietly importing some backing or some debt.

Phoenix takes a different stance. **phUSD is minted *by* stablecoins, but it is deliberately *not* redeemable.**

When you mint phUSD, you hand the protocol a real stablecoin (USDC, DOLA, USDe, …). The protocol does **not** hold that stablecoin in a drawer waiting for you to ask for it back. Instead it **invests your stablecoin into a yield-bearing vault**, and **re-routes the yield from that vault back into the protocol**.

> **In the code:** `PhusdStableMinter.mint()` takes a registered stablecoin, immediately deposits it into an `IYieldStrategy` (an ERC-4626 vault adapter), and mints phUSD to you. There is no `redeem()` and no `withdraw()` — minting is strictly one-way. ([`lib/phUSD-stable-minter/src/PhusdStableMinter.sol`](../../lib/phUSD-stable-minter/src/PhusdStableMinter.sol))

This single design choice is the heartwood — the dense core every other ring grows around. And it produces a surprising property: **antifragility.**

Consider what happens if everyone panics and sells phUSD:

- The **yield** the protocol earns is denominated in *real* stablecoins (USDC etc.) sitting in vaults. A sell-off in phUSD doesn't touch it.
- So if the *market value of the phUSD supply falls*, the **yield stream is unchanged** — which means the yield has become *larger relative to the coin it backs.*

The pressure that would normally break a stablecoin instead **increases the relative strength of its backing**. The system leans into the wind. We call this countercyclical behaviour the **evergreen effect**: the protocol's productive core stays green through every season, and gets *relatively richer* exactly when the market is fearful.

> **Because of this, we can now build** a way to make that core grow — to turn a static kernel of yield into a flywheel for total value locked (TVL).

---

## Ring 1 — The AMM and the Mint-and-Sell Pump

A kernel of protocol-owned yield is wonderful, but on its own it just sits there. We need a mechanism that makes the **TVL** (the stablecoins under management, earning yield) grow on its own. Here is the trick.

We provide **open-market backing for phUSD on an AMM**, but we pair it against a **yield-bearing stablecoin** — specifically **sUSDS** (Savings USDS, which accrues yield over time).

> **In the code:** the canonical pool is a **Balancer V3 phUSD / sUSDS pool**. ([`lib/yield-claim-nft/src/V2/dispatchers/BalancerPoolerV2.sol`](../../lib/yield-claim-nft/src/V2/dispatchers/BalancerPoolerV2.sol))

Why a yield-bearing pair? Because sUSDS quietly gains value every block. That means the pool's exchange rate has a **constant gentle drift upward** in the price of phUSD measured against the pair. Left alone, phUSD tends to drift *above* $1.

And the moment phUSD trades above $1, a clean profit opportunity opens:

1. **Mint phUSD at the fixed $1 price** through the minter (deposit $1 of stablecoin, get 1 phUSD).
2. **Sell that phUSD onto the AMM** at the above-$1 market price.
3. Pocket the difference.

Notice what each turn of this arbitrage actually *does* to the protocol:

- The arbitrageur's **mint deposits a fresh stablecoin into the yield vaults → TVL grows.**
- The arbitrageur's **sell adds phUSD-side depth to the AMM → liquidity grows.**

So the price drift doesn't just enrich arbitrageurs — it **pumps the two things the protocol most wants**: more productive TVL, and more on-chain liquidity. The peg is held from *above* (drift pushes up; minting-and-selling pushes back toward $1), which is exactly the safe direction for a coin to be defended from.

> **Because of this, we can now build** something that rewards holders of phUSD — because we finally have a growing TVL whose yield we can point somewhere.

---

## Ring 2 — Phlimbo, the Staking Farm (and the above-market yield)

Now we have a kernel of yield and an engine that grows it. Let's reward people for holding phUSD by letting them **stake** it.

**Phlimbo** is the staking farm. We **re-route the protocol's vault yield into Phlimbo**, and stakers of phUSD earn it.

> **In the code:** Phlimbo receives yield via `collectReward()` and pays it out to stakers over a **depletion duration** (a smoothing window so a lump of yield streams out steadily rather than all at once). ([`lib/phlimbo-ea/src/PhlimboV2.sol`](../../lib/phlimbo-ea/src/PhlimboV2.sol))

Here is the elegant part — the bit worth pausing a video on.

> **If 100% of all phUSD were staked**, the APY on Phlimbo would simply equal the APY of the underlying yield vaults. Fair, but unremarkable.
>
> But **not** 100% of phUSD can be staked — because some of it is *stuck in the AMM* providing liquidity (Ring 1).
>
> So you have a situation where **less than 100% of the phUSD supply is chasing the yield that backs 100% of the supply.** The same yield, divided among fewer stakers → **the staking APY is structurally above market.**

That above-market APY is not an accident or a subsidy. It is a direct *consequence* of having an AMM, and it is the fuel for everything that comes later.

And watch how it loops back to strengthen Ring 1:

- Above-market staking APY makes people **want** phUSD to stake.
- The natural way to get phUSD is to **buy it on the AMM** — which **pushes the price above $1**.
- Price above $1 **triggers the mint-and-sell arbitrage** (Ring 1) — which **grows TVL and liquidity.**

So **the existence of staking actively drives TVL growth.** The rings feed each other.

phUSD is now held up by **two pillars**:

- **The AMM** (liquidity / market backing), and
- **The farm** (yield demand).

These two pillars are self-balancing. If phUSD is pulled *out* of the farm to be sold on the AMM, fewer stakers share the yield, so **the farm's APY rises** — creating pressure to restake. Capital sloshes between the two pillars and the system finds equilibrium on its own.

> **Because of this, we can now build** more robustness — and handle the complexity that robustness creates.

---

## Ring 3 — Many Vaults, and the Yield Accumulator

A protocol resting on a single yield vault is fragile: if that one vault fails or its rate collapses, everything above it wobbles. So we **add more vaults** — diversifying the sources of yield makes the whole tree more resistant to any single rot.

But diversity creates a new problem: **now the yield arrives in many different tokens, from many different vaults.** A staker doesn't want to manage a fruit-salad of yield tokens; the farm wants one clean reward stream.

Enter the **Stable Yield Accumulator (SYA)** — a new incentive layer that turns scattered yield into a clean, single-token stream, *and uses the market to do the work for free.*

Here's how it works:

1. The SYA gathers all the incoming yield from all the vaults — many tokens, many sources.
2. It **presents that whole basket to any user**, who can **claim it in exchange for USDC of equal value.**
3. The claimer is offered the basket at a **discount** — they pay slightly less USDC than the basket is worth. That discount is their profit incentive.

> **In the code:** `StableYieldAccumulator.claim()` charges `totalYield × (1 − discountRate)`, hands the claimer the underlying yield tokens, and routes the USDC they pay onward. ([`lib/stable-yield-accumulator/src/StableYieldAccumulator.sol`](../../lib/stable-yield-accumulator/src/StableYieldAccumulator.sol))

The effect is beautiful in its simplicity:

- **Users get a simple farm that pays pure USDC** — no token-juggling, easy to understand, easy to value.
- **The protocol gets robustness** — many vaults, no single point of failure — *and* it gets a clean USDC stream to feed Phlimbo, **without the protocol itself having to run swaps or take market risk.** The discount-hunting claimers do the consolidation, and competition keeps the discount tight.

And the same self-reinforcing loop from Ring 2 still hums underneath: if staking draws phUSD out of the AMM, it induces more minting, which grows TVL, which grows the yield that flows through the SYA. Every ring keeps turning the rings around it.

> **Because of this, we can now build** a deliberate engine for *liquidity* — because we now have a clean, above-market surplus of yield we can afford to spend.

---

## Ring 4 — Liquidity as a Product: NFT Minting

Why obsess over liquidity? Because **liquidity is runway for the Ring 1 pump.**

Think about the mint-and-sell arbitrage. Its profit depends entirely on how much phUSD the AMM can absorb before the price falls back to $1:

- An AMM that can absorb **$10** of selling gives an arbitrageur a tiny window — TVL grows by a trickle.
- An AMM that can absorb **$1,000** of selling gives an arbitrageur a huge window — every time the price drifts up, far more can be minted-and-sold before the gap closes. **TVL grows fast.**

So **deeper liquidity = more runway = faster TVL growth.** Liquidity is not a cost centre; it is the throttle on the whole engine. We want a dedicated machine for producing it.

That machine is **NFT minting.**

> **In the code:** minting an NFT through `NFTMinterV2` runs a **`BalancerPoolerV2`** dispatcher: it takes **USDS**, wraps it into **sUSDS**, and performs a **single-sided join** into the phUSD / sUSDS Balancer pool. ([`lib/yield-claim-nft/src/V2/NFTMinterV2.sol`](../../lib/yield-claim-nft/src/V2/NFTMinterV2.sol), [`.../dispatchers/BalancerPoolerV2.sol`](../../lib/yield-claim-nft/src/V2/dispatchers/BalancerPoolerV2.sol))

A single-sided sUSDS join does **two** good things at once:

- It **increases liquidity** (more depth in the pool → more runway).
- It **pushes phUSD's price closer to $1** (adding to the *other* side of the pair nudges phUSD down toward peg) — a built-in stabilizer.

But — why would anyone mint an NFT? An NFT that does nothing has no reason to exist. **We give it value by tying it to another part of the protocol.** Specifically, we **gate the yield claim behind it**:

> **In the code:** `StableYieldAccumulator.claim()` requires the caller to hold and **burn one NFT** to claim the discounted yield basket. ([`StableYieldAccumulator.sol`](../../lib/stable-yield-accumulator/src/StableYieldAccumulator.sol))

Now the rings click together with a satisfying snap:

- The **profit available on the SYA yield claim grows continuously** (yield keeps flowing in).
- Eventually that growing profit **exceeds the cost of minting an NFT.**
- So a rational actor **mints an NFT** (funding liquidity) **in order to claim the yield** (which is profitable because the yield is above-market).

Read that chain backwards and marvel at it:

> We are using **a portion of external incoming yield to pay for liquidity growth.**
> We can only *afford* to do that because the yield is **above market rate.**
> And it is only above market rate because **some phUSD is locked in the AMM** (Ring 2).

**The AMM funds the liquidity that funds the AMM.** Each ring is literally paying for the others. *This* is the moment in a presentation where the audience should feel the whole structure lock into place.

> **Because of this, we can now build** something even more aggressive — because NFT minting has a hidden monetary side effect we can exploit.

---

## Ring 5 — The Deflation Trick and NFT Staking

NFT minting has a subtle consequence: by adding sUSDS to the pool and nudging phUSD toward $1, **it places a deflationary pressure on phUSD.** Each NFT minted effectively *removes* some upward phUSD pressure from the system — call it, for illustration, **−50 phUSD of indirect deflation** per NFT.

That deflation is a budget. Here is the insight:

> If each NFT creates roughly **−50 phUSD** of deflationary pressure, then we can afford to **mint up to ~50 fresh phUSD** *without* pushing the price down — as long as the new phUSD we mint is **less than the deflation the NFT created.** The two cancel.

So let's spend that budget productively. Suppose we **mint 30 phUSD** per NFT and put it into a **staking contract for the NFTs themselves.** Now NFT holders can **stake their NFT and earn a very high phUSD APY** — funded by phUSD we minted "for free" against the deflation the NFT itself produced.

> **In the code:** the **`BalancerPoolerMintDebtHook`** accrues a configurable share (≈50%) of dispatched USDS as a **phUSD mint-debt**, which is materialized and paid into **`NFTStaker`**. `NFTStaker` targets an APY computed off the *latest NFT mint price*, so the most recent minter earns the headline rate. ([`.../hooks/BalancerPoolerMintDebtHook.sol`](../../lib/yield-claim-nft/src/V2/hooks/BalancerPoolerMintDebtHook.sol), [`lib/nft-staking/src/NFTStaker.sol`](../../lib/nft-staking/src/NFTStaker.sol))

The result was a **liquidity explosion.** A very high APY on staked NFTs makes minting NFTs extremely attractive → far more NFTs minted → far more single-sided sUSDS poured into the pool → liquidity grows dramatically → the Ring 1 pump gets a much longer runway → TVL accelerates.

> **Because of this, we can now build** a way to *encourage batches* of NFT minting — because liquidity is growing so fast it's worth pouring fuel on the fire.

---

## Ring 6 — The Batch Minter and the Nudge Reward

Liquidity minting took off so strongly that it became clearly worthwhile to **encourage people to mint many NFTs at once.** So we built the **`BatchNFTMinter`** — mint a whole batch in a single transaction.

Then we layered an incentive on top, and it's a clever one. Walk through a concrete example:

- A batch of 40 NFTs costs, say, **400 USDS.**
- We levy a **10% tax** on that 400 USDS → **40 USDS** is skimmed off.
- We then **recycle that 40** as a **reward for whoever mints the next batch of 40.**

> **In the code:** the tax is the **batch-donation phase** of `BalancerPoolerV2` — it diverts a configured percentage of the incoming sUSDS, swaps it to USDC, and sends it to the `BatchNFTMinter`. `BatchNFTMinter.batchMint()` pays out the accumulated pot as the **nudge reward** once a batch of at least `nudgeSize` is minted. ([`lib/nft-staking/src/BatchNFTMinter.sol`](../../lib/nft-staking/src/BatchNFTMinter.sol), [`.../dispatchers/BalancerPoolerV2.sol`](../../lib/yield-claim-nft/src/V2/dispatchers/BalancerPoolerV2.sol))

This is the **nudge reward.** Because the NFT-staking APY is *already* very high (Ring 5, ~30%), bolting a cash rebate on top of it gives a **massive effective APY** for the batch minter who claims it.

And there's a self-firing timer built in. We **redirect a little of the protocol's surplus yield into the nudge pool**, so the nudge reward **grows over time** — it keeps climbing until it's so juicy that minting a batch *has* to happen. The protocol effectively winds up a spring that periodically *demands* a fresh burst of liquidity minting.

We can only afford to keep topping up the nudge pool because, by now, the protocol has **so much surplus** — surplus yield (above-market) *and* surplus liquidity runway. Each previous ring widened the margin that pays for this one.

> **Because of this, we can now build** something that directly attacks the slowest part of the system — the raw growth rate of TVL itself.

---

## Ring 7 — Stable Staking: Inviting the Blue Chips In

By now the engine is humming, but there was one lingering worry: **TVL, while inevitably growing, was still growing too slowly** relative to the appetite the rest of the system had built up. We had runway to spare and incentive budget to spare — we needed more *base capital* flowing in.

So we opened the doors wider with **`StableStaker`**: users can now stake **traditional blue-chip stablecoins directly** — **USDC, USDe, DOLA** — without first minting phUSD.

> **In the code:** `StableStaker.stake()` accepts any registered token and routes the deposit **straight into that token's underlying ERC-4626 yield vault.** ([`lib/stable-staker/src/StableStaker.sol`](../../lib/stable-staker/src/StableStaker.sol))

Those deposits **go directly into the underlying vaults**, so they immediately become **more TVL producing more yield** — fuel for every ring above.

But here's the twist that ties it back to the heartwood. We don't pay stable-stakers in the underlying yield. **We pay them in freshly minted phUSD instead.** We can *afford* to mint that phUSD because of all the deflationary runway and surplus the lower rings created (Rings 5–6). The underlying yield stays inside the protocol — strengthening the core — while the staker is happily paid in phUSD.

And there's a final safety dividend. Each vault's pool emits phUSD at a **fixed rate per second** (configurable per pool). Because the rate per pool is fixed, **as a pool fills up, each staker's share of that fixed emission shrinks** — its per-dollar APY falls. That gently pushes new capital toward the *emptier, higher-APY* pools.

> **In the code:** each pool has its own `phusdPerSecond`; user rewards are that fixed rate shared across `totalStaked`, so per-user yield falls as a pool grows — nudging capital toward under-filled pools. ([`StableStaker.sol`](../../lib/stable-staker/src/StableStaker.sol))

The equilibrium this drives toward is **roughly equal *dollar value* staked across vaults** — which means the protocol's risk is **spread evenly** rather than piled into one vault. More even distribution = **a safer protocol.** The outermost ring loops all the way back and hardens the heartwood.

---

## The Whole Tree

Step back and look at the cross-section. Every ring exists because the ring inside it made it possible, and every ring strengthens the ring inside it:

| Ring | Mechanism | Made possible by… | …and it strengthens |
|---|---|---|---|
| **Heartwood** | Protocol-owned, non-redeemable yield (phUSD) | the core insight | everything |
| **1** | AMM vs. yield-bearing sUSDS → mint-and-sell pump | a yield kernel worth arbitraging | TVL + liquidity |
| **2** | Phlimbo staking farm | a growing TVL with yield to route | the peg, via buy→mint loop |
| **3** | Many vaults + Yield Accumulator | above-market yield worth claiming | robustness + clean USDC stream |
| **4** | NFT minting funds single-sided liquidity | a yield surplus that can pay for liquidity | the pump's runway |
| **5** | Deflation budget → high-APY NFT staking | NFT minting's deflationary pressure | liquidity, explosively |
| **6** | Batch minter + self-growing nudge reward | surplus yield + surplus runway | the pace of liquidity minting |
| **7** | Stable staking of blue chips, paid in phUSD | spare runway to mint phUSD | raw TVL + even, safer risk |

The thing to communicate — in a video, a deck, a pitch — is that **none of these is a standalone feature.** Pull any ring out and the rings around it lose their justification:

- No AMM lock-up → no above-market yield → nothing to fund NFTs with.
- No NFT gating → no reason to mint NFTs → no liquidity runway → the pump stalls.
- No deflation budget → no high-APY NFT staking → no liquidity explosion → no surplus to run the nudge or pay stable-stakers in phUSD.

It is a **single organism that compounds its own advantages** — antifragile at the core, self-funding in the middle, self-accelerating at the edge. That is the evergreen protocol: it stays green through every season, and every season it lays down another ring.

---

### A note on the metaphors

If the **growth-rings** image doesn't land for a given audience, two alternatives carry the same idea:

- **Onion, built outward.** Each layer wraps and protects the one inside; you peel inward to reach the core insight (protocol-owned yield). Good for "let me show you what's underneath."
- **A coral reef / ecosystem.** Each organism's waste is another's food; remove one species and the web frays. Good for emphasizing *mutual* dependence rather than linear stacking.

Pick whichever fits the room — but keep the through-line identical: **each layer unlocks the incentive for the next, and feeds value back to the ones below it.**
