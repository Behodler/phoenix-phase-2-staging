# UniswapV2 Price Tilting via Single-Sided WETH Zap

## Goal

Deposit WETH into a UniswapV2 pair (e.g. **EYE/WETH**) such that the net effect is
**both higher liquidity and a higher EYE price** — while keeping the position
protected against sandwich/MEV attacks.

The actor holds only WETH. They want to:

1. End up with an LP position in the pair (more liquidity in the pool).
2. Nudge the EYE price upward (in ETH terms) as a side effect.
3. Not get sandwiched while doing it.

## Why a naive one-sided deposit does not work

UniswapV2's `mint()` credits liquidity as:

```
liquidity = min(
    wethDelta * totalSupply / reserveWETH,
    eyeDelta  * totalSupply / reserveEYE
)
```

If you transfer **only** WETH to the pair and call `mint()`, `eyeDelta == 0`, so
`liquidity == 0` and the call reverts with `INSUFFICIENT_LIQUIDITY_MINTED`. A pure
one-sided send is just a donation to existing LPs — you get nothing back, and there
is no "slippage", just a gift.

To turn one-sided WETH into an LP position you must first **rebalance via a swap**.
That swap is where the price tilt and the slippage cost both come from.

## The single-sided zap

1. Swap the *optimal* portion `s` of the input WETH for EYE through the pair.
2. Add the leftover WETH (`wethIn − s`) together with the EYE just bought.
3. Mint LP.

### Net effects

- **Liquidity higher**: the full `wethIn` of value ends up in the pool. The WETH
  reserve rises by `wethIn`; the EYE reserve is net unchanged (the swap removes EYE,
  the add puts the same EYE back).
- **Price higher**: buying EYE during the rebalance lifts the marginal price; the
  balanced add does not move it back, so `priceAfter > priceBefore`.

### Choosing the optimal swap amount `s`

"Optimal" means: after the swap, the leftover WETH and the bought EYE are in the
**exact ratio of the new reserves**, so `mint()` consumes both with zero discarded
dust. Equivalently, the two halves have **equal value at the new marginal price**
(a true 50/50-by-value split).

The balance condition is:

```
(wethIn − s) / eyeOut  =  reserveWETH' / reserveEYE'
```

where `reserveWETH' = reserveWETH + s` and `reserveEYE' = reserveEYE − eyeOut`.
Solving for `s`, including the 0.3% fee, gives the standard closed form:

```
s = ( sqrt( reserveWETH * (reserveWETH * 3988009 + amountIn * 3988000) )
      − reserveWETH * 1997 ) / 1994
```

The constant `3988009 = 1997² + 4·997·1000` is what carries the fee through.

`s` is always a hair **below** `wethIn / 2`. With zero fee and zero price impact it
would be exactly half; the 0.3% fee plus the price impact of the swap itself mean you
need to convert slightly less than half to end up balanced. The gap from half widens
the larger your trade is relative to the reserves.

## Valuing the resulting LP — two honest numbers

After minting, the LP position can be valued two ways, and they disagree:

1. **Mark-to-market at the new marginal price.** Tends to read **> `wethIn`** (e.g.
   0.5075 WETH for a 0.5 WETH input). This is a *paper* number: your one-sided add
   lifted the price, and you are marking your own EYE at that inflated price. It is
   not recoverable.

2. **Realized cash-out.** Burn the LP and sell the EYE half back through the same
   pool. This is **< `wethIn`** (e.g. 0.49857 WETH), the real economic figure. The
   shortfall (~0.3% of the rebalanced half) is the round-trip swap fee. This is the
   number to reason about for "how much did this cost me".

## MEV protection: pass in `minLPGenerated`

The swap leg is sandwichable. The guard is a caller-supplied minimum-LP floor:

```solidity
require(liquidity >= minLP, "zap: insufficient LP out");
```

### The cardinal rule

**`minLP` MUST be computed off-chain (from a recent/trusted price) and passed in as a
fixed parameter. It must NOT be re-derived on-chain from the same `getReserves()` the
swap reads.**

If the floor were computed in-tx from live reserves, the guard is a no-op: a
sandwicher moves the reserves, so the "expected" value and the actual result slide
together and the check passes every time. The floor has to be anchored to a price the
attacker did not get to set. Encoding it as a function *parameter* enforces this — the
on-chain code reads live reserves only to **size** the swap, never to **set** the
floor.

### Why bounding LP *count* is a sound proxy for value

- The profitable sandwich direction is to **inflate** EYE's price before you
  (front-run buy → more WETH, less EYE in the pool). This raises the WETH backing per
  LP token, so you receive **fewer** LP tokens for your WETH — monotonically fewer the
  larger the attack.
- The opposite direction (push price down) hands you cheap EYE and loses the attacker
  money, so it is not a threat.
- Because the attacker restores the reserves on the back-run, your locked-in pool
  *fraction* maps to your true recoverable value. A lower bound on LP count is
  therefore a lower bound on attack size and on realized value.

So `liquidity >= minLP` is a clean, monotone guard.

### Sizing `minLP`

Off-chain, quote the LP the zap would mint at the current price (mirror the mint math),
then apply a deliberate slippage tolerance:

```
minLP = quotedLP * (10_000 − slippageBps) / 10_000
```

`slippageBps` must be a **deliberately chosen, non-zero** value (e.g. 50 = 0.5%). Zero
tolerance disables the protection. Also reject `minLP == 0` on-chain so an unbounded
zap can never be broadcast.

### Stale-tx guard

Add a `deadline` and `require(block.timestamp <= deadline)` so a tx that sits in the
mempool cannot execute later against a worse pool state.

## Reference implementation

A working, runnable reference lives in the throwaway scratchpad script
`script/interactions/Temp.s.sol` (preview-only: it uses `vm.deal` / `vm.startPrank`
cheatcodes to fund and act, so it runs under `npm run Temp:preview` against a mainnet
fork, not under broadcast). The core pieces:

- `_zapSingleSidedWeth(pair, eyeIsToken0, to, wethIn, minLP, deadline)` — reads live
  reserves to size the swap, executes swap + add + mint, and enforces both the `minLP`
  and `deadline` guards (plus `minLP > 0`).
- `_quoteZap(...)` — a `view` reproducing the mint math so a caller can size `minLP`.
- `_optimalSwapIn(reserveIn, amountIn)` — the closed-form optimal swap amount above.
- `_getAmountOut(amountIn, reserveIn, reserveOut)` — standard 0.3%-fee UniswapV2 quote.

### Worked example (EYE/WETH mainnet fork, 0.5 WETH in)

| Metric | Value |
|---|---|
| Pair (from factory) | `0x54965801946d768b395864019903aEF8B5b63BB3` |
| Reserves before | 669,226 EYE / 7.350 WETH |
| EYE price before (ETH/EYE ×1e18) | 10,983,052,901,588 |
| Optimal WETH swapped → EYE | 0.2463 WETH → 21,631.7 EYE |
| Quoted LP / minLP floor (0.5%) | 44.2071 / 43.9861 |
| LP minted | 44.2127 (≥ floor ✓) |
| LP value — mark-to-market | 0.50749 WETH (paper, > input) |
| LP value — realized cash-out | 0.49857 WETH (< input) |
| Round-trip cost | 0.001428 WETH (~0.29%) |
| EYE price after (ETH/EYE ×1e18) | 11,730,184,158,125 (**+6.8%**) |

## Production checklist

- [ ] `minLP` computed off-chain from a recent price, passed in as a parameter.
- [ ] `slippageBps` deliberately chosen and non-zero; document why.
- [ ] On-chain `require(minLP > 0)` rejects an unbounded zap.
- [ ] `deadline` supplied and enforced.
- [ ] Live reserves used only to size the swap, never to set the floor.
- [ ] No `address(this)` reliance in scripts; use a concrete actor.
- [ ] Real broadcast path drops the `vm.*` cheatcodes (preview-only constructs).
