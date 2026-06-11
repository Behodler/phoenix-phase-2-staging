# Phoenix Protocol — Presentation Deck & Short Script

*Companion to [`phoenix-protocol-explained.md`](./phoenix-protocol-explained.md). Two deliverables in one file:*
1. **A slide-by-slide deck outline** (with speaker notes and a "what to show" cue per slide).
2. **A 3-minute spoken script** (the same story, compressed for a teaser / intro video).

The visual spine is the **growth-rings** metaphor. Pair this with the diagrams in [`phoenix-protocol-ring-diagram.md`](./phoenix-protocol-ring-diagram.md).

---

## Part 1 — Slide-by-Slide Deck

> **Format convention per slide:** a short title, the **one line** the audience should remember, optional **on-slide bullets** (keep them sparse — 3 max), **speaker notes** (what you say), and a **visual cue** (what's on screen).

### Slide 0 — Title

- **Title:** *Phoenix: The Evergreen Protocol*
- **One line:** A stablecoin that gets *stronger* when the market gets scared.
- **Visual cue:** A tree cross-section (growth rings) fading in. Hold on it.
- **Speaker notes:** "Most protocols are a pile of features. Phoenix is one idea, grown in rings. By the end of three minutes you'll see why you can't remove a single ring without the others losing their reason to exist."

---

### Slide 1 — The problem every stablecoin must solve

- **One line:** What actually makes a coin worth a dollar?
- **On-slide bullets:**
  - Redeemable / asset-backed — backing *is* the value
  - Debt-backed — the loan stands behind it
  - Purely algorithmic — *no bite*; inflation runs away
- **Visual cue:** Three columns; the third (algorithmic) cracks / crumbles.
- **Speaker notes:** "Two honest answers, one that has never survived on its own. Algorithms with no backing and no debt have nothing forcing the price home. Phoenix takes a third path."

---

### Slide 2 — The Heartwood: Protocol-Owned Yield

- **One line:** phUSD is minted *by* stablecoins — but it is **not redeemable.**
- **On-slide bullets:**
  - You mint phUSD by depositing a real stablecoin
  - That stablecoin is invested into a yield vault
  - The yield is re-routed back into the protocol
- **Visual cue:** Dense centre ring of the tree highlighted; arrow: stablecoin → vault → yield → protocol.
- **Speaker notes:** "We don't hold your stablecoin in a drawer. We put it to work and keep the yield. That one decision is the heartwood everything grows around." *(Code: `PhusdStableMinter.mint()` — one-way, deposits into an ERC-4626 strategy.)*

---

### Slide 3 — The Evergreen Effect (antifragility)

- **One line:** If everyone sells phUSD, the yield is untouched — so the backing gets *relatively stronger.*
- **On-slide bullets:**
  - Yield is denominated in real USDC, not phUSD
  - phUSD price falls → yield grows *relative* to supply
  - Countercyclical: leans into the wind
- **Visual cue:** Two bars — phUSD market value drops, yield stays flat → the *ratio* visibly widens. Label it **"Evergreen Effect."**
- **Speaker notes:** "The pressure that breaks a normal stablecoin makes Phoenix's core *richer relative to the coin it backs.* This is antifragility, not just resilience."

---

### Slide 4 — Ring 1: The Mint-and-Sell Pump

- **One line:** Pair phUSD on an AMM against a *yield-bearing* stablecoin (sUSDS) → constant upward drift.
- **On-slide bullets:**
  - sUSDS gains value every block → phUSD drifts above $1
  - Above $1 → mint at $1, sell on the AMM
  - Each arb: **TVL grows** *and* **liquidity grows**
- **Visual cue:** A loop animation: price ticks above $1 → mint → sell → price back to $1, with TVL and liquidity meters ticking up each cycle.
- **Speaker notes:** "The drift isn't a bug to suppress — it's a pump. Every arbitrage deposits fresh capital into the vaults and deepens the pool. The peg is defended from *above*, which is the safe direction." *(Code: Balancer V3 phUSD/sUSDS pool.)*

---

### Slide 5 — Ring 2: Phlimbo & the above-market yield

- **One line:** Some phUSD is stuck in the AMM — so the *farm's* yield is structurally above market.
- **On-slide bullets:**
  - Stake phUSD in Phlimbo, earn the vault yield
  - <100% can stake (rest is locked in the AMM)
  - Same yield ÷ fewer stakers = **above-market APY**
- **Visual cue:** A pie of total phUSD: a slice "locked in AMM" greyed out; the yield pours only onto the remaining slice → that slice glows hotter.
- **Speaker notes:** "This is the hinge of the whole design. Less than 100% of phUSD chases the yield that backs 100% of it. That surplus APY is the fuel for everything that comes next — and it pulls buyers in, which triggers the Ring 1 pump again."

---

### Slide 6 — Two self-balancing pillars

- **One line:** phUSD now stands on two legs — the AMM and the farm — and they balance each other.
- **On-slide bullets:**
  - Pull phUSD from the farm → APY rises → pressure to restake
  - Buy phUSD to stake → price up → triggers minting
- **Visual cue:** A see-saw / two pillars with capital sloshing between them, settling to equilibrium.
- **Speaker notes:** "Capital sloshes between liquidity and yield and finds its own balance. No central hand required."

---

### Slide 7 — Ring 3: Many vaults + the Yield Accumulator

- **One line:** Diversify yield sources for safety — then let the market consolidate them for free.
- **On-slide bullets:**
  - Many vaults → no single point of failure
  - Yield arrives as many tokens → messy
  - SYA: anyone claims the basket for USDC, **at a discount**
- **Visual cue:** Many coloured yield tokens funnel into the SYA; a claimer pays clean USDC (with a small "discount" tag) and the USDC flows to Phlimbo.
- **Speaker notes:** "Stakers get a simple USDC stream. The protocol gets robustness *and* avoids running swaps itself — discount-hunters do the consolidation, competition keeps the discount tight." *(Code: `StableYieldAccumulator.claim()`.)*

---

### Slide 8 — Ring 4: Liquidity as a product (NFT minting)

- **One line:** Deeper liquidity = longer runway for the pump = faster TVL growth.
- **On-slide bullets:**
  - $10 of depth = tiny arb window; $1,000 = huge window
  - Minting an NFT adds single-sided sUSDS liquidity
  - …and nudges phUSD toward $1 (built-in stabilizer)
- **Visual cue:** Two AMMs side by side — shallow vs deep — showing how much can be minted-and-sold before price returns to $1.
- **Speaker notes:** "Liquidity isn't a cost — it's the throttle. So we built a machine that turns USDS into pool depth. Minting an NFT runs a single-sided sUSDS join." *(Code: `NFTMinterV2` → `BalancerPoolerV2`.)*

---

### Slide 9 — Why mint the NFT? The lock clicks shut

- **One line:** Gate the yield claim behind the NFT — now external yield *pays for* liquidity growth.
- **On-slide bullets:**
  - Claiming SYA yield requires burning an NFT
  - Growing yield-claim profit eventually exceeds NFT cost
  - We fund liquidity with **above-market yield**
- **Visual cue:** The full circular chain lit up: **AMM lock-up → above-market yield → funds NFTs → funds liquidity → feeds the AMM.** Pause here.
- **Speaker notes:** *(This is the climax — slow down.)* "Read it backwards: we pay for liquidity with external yield; we can afford that only because the yield is above-market; and it's above-market only because phUSD is locked in the AMM. **The AMM funds the liquidity that funds the AMM.** Every ring is paying for the others."

---

### Slide 10 — Ring 5: The deflation trick & NFT staking

- **One line:** NFT minting deflates phUSD — so we can mint a little phUSD for free and pay a *huge* NFT-staking APY.
- **On-slide bullets:**
  - Each NFT ≈ −50 phUSD of deflation (illustrative)
  - Mint ~30 phUSD → pay NFT stakers → cancels out
  - Very high APY → liquidity **explosion**
- **Visual cue:** A scale: "−50 deflation" outweighs "+30 minted" → net still deflationary; arrow to a steeply rising liquidity curve.
- **Speaker notes:** "The deflation is a budget. We spend part of it minting phUSD to reward NFT staking. High APY → far more minting → a liquidity explosion." *(Code: `BalancerPoolerMintDebtHook` → `NFTStaker`.)*

---

### Slide 11 — Ring 6: Batch minter & the self-winding nudge

- **One line:** A 10% tax on batches funds a reward that grows until minting a batch *has* to happen.
- **On-slide bullets:**
  - Batch of 40 NFTs ≈ 400 USDS → 10% tax = 40
  - That 40 becomes the **nudge reward** for the next batch
  - Surplus yield tops it up → it self-winds
- **Visual cue:** A spring winding tighter (nudge pot growing); when it crosses a line, a batch fires and the spring releases.
- **Speaker notes:** "On top of an already-high APY, a cash rebate makes the effective APY enormous. We trickle surplus yield into the pot so it keeps climbing until someone *must* mint a batch. The protocol winds its own spring." *(Code: `BatchNFTMinter.batchMint()`.)*

---

### Slide 12 — Ring 7: Stable staking (inviting the blue chips)

- **One line:** Stake USDC / USDe / DOLA directly — paid in freshly minted phUSD.
- **On-slide bullets:**
  - Deposits go straight into the yield vaults → instant TVL
  - Paid in phUSD (we have the runway to mint it)
  - Fixed per-second emission → pushes toward **equal $ per vault**
- **Visual cue:** Blue-chip logos flowing into vaults; a balance-bar showing vault TVL evening out across pools.
- **Speaker notes:** "We needed raw TVL faster. So we let blue chips in directly and pay them in phUSD — affordable because of all the runway the lower rings built. And fixed per-pool emission spreads capital evenly across vaults, so risk is spread evenly. Safer." *(Code: `StableStaker.stake()`.)*

---

### Slide 13 — The whole tree

- **One line:** One organism that compounds its own advantages.
- **Visual cue:** The full ring diagram (from `phoenix-protocol-ring-diagram.md`), each ring labelled, feedback arrows curving inward.
- **Speaker notes:** "Antifragile at the core, self-funding in the middle, self-accelerating at the edge. Pull any ring and the ones around it lose their justification. That's the evergreen protocol — green through every season, laying down another ring each one."

---

### Slide 14 — Close / Call to action

- **One line:** Phoenix — protocol-owned yield, grown in rings.
- **Visual cue:** Back to the tree cross-section; logo; link / next step.
- **Speaker notes:** Tailor to venue (mint phUSD, stake, mint an NFT, read the docs, etc.).

---

## Part 2 — The 3-Minute Script

> ~430 words ≈ 3:00 at a calm narration pace. Bracketed cues map to the slides/visuals above. Trim the parentheticals if you need to hit 2:30.

---

**[Tree cross-section appears.]**

Most crypto protocols are a pile of features. Phoenix is one idea, grown in rings — and by the end of this you'll see you can't remove a single ring without the rest losing their reason to exist.

**[Heartwood ring highlights.]**

Start at the core. Every stablecoin has to answer one question: what makes the coin worth a dollar? Phoenix's answer is unusual. You mint phUSD by depositing a real stablecoin — but phUSD is *not* redeemable. Instead of holding your deposit in a drawer, we invest it into a yield vault and keep the yield flowing back into the protocol.

**[Two bars: price drops, yield holds.]**

Here's the magic. If everyone panic-sells phUSD, the yield doesn't care — it's denominated in real dollars. So when the coin's market value falls, the backing actually grows *relative* to the supply. The protocol gets stronger exactly when the market gets scared. We call it the evergreen effect.

**[Ring 1: the pump loop.]**

Now we make it grow. We pair phUSD on an exchange against a *yield-bearing* stablecoin, so the price gently drifts above a dollar. Every time it does, anyone can mint at one dollar and sell the difference — and each time they do, they deposit fresh capital and deepen our liquidity. The drift is a pump.

**[Ring 2: the glowing pie slice.]**

Then we let people stake phUSD to earn that yield. But some phUSD is always locked in the exchange — so fewer stakers share the yield that backs the *entire* supply. That makes the staking yield structurally *above market.* And that surplus is the fuel for everything that follows.

**[Ring 4 → the circular chain lights up.]**

Because deeper liquidity means a longer runway for the pump, we turn liquidity into a product: mint an NFT, add liquidity. Why mint it? Because the NFT unlocks that above-market yield. Read it backwards — we pay for liquidity using external yield; we can afford that only because the yield is above market; and it's above market only because phUSD is locked in the exchange. **The exchange funds the liquidity that funds the exchange.**

**[Rings 5–7 bloom outward.]**

From there it compounds: NFT minting deflates phUSD, so we mint a little for free to pay enormous NFT-staking yields. A self-winding reward keeps liquidity minting in batches. And blue-chip stablecoins can stake directly, spreading risk evenly across vaults.

**[Full tree.]**

Antifragile at the core. Self-funding in the middle. Self-accelerating at the edge. One organism — the evergreen protocol.
