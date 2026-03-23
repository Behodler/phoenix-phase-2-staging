# Governance Scripts

Scripts in this directory perform protocol governance actions on mainnet. These are **real transactions** that move real funds — treat them with the same care as deployment scripts.

## Scripts

### BuyPhUSDWithSUSDS.s.sol

Swaps sUSDS for phUSD on the Balancer V3 Gyro e-CLP pool to rebalance the pool price. This was created to recover from a depeg event where phUSD traded below $1, draining sUSDS from the pool.

**How it works:**
1. Reads `PHUSD_BUY_DOLLAR_IN` from env — the dollar amount to spend (assumes USDS = $1)
2. Converts dollars to sUSDS via `IERC4626(sUSDS).convertToShares()` — this accounts for sUSDS being worth more than $1
3. Approves sUSDS through Permit2 → Router (Balancer V3 approval flow)
4. Executes `swapSingleTokenExactIn` on the Balancer Router
5. Reverts if phUSD received is less than `PHUSD_BUY_MIN_OUT` — slippage protection enforced in simulation before any broadcast

**Mainnet addresses used:**
- Pool: `0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58` (Gyro e-CLP phUSD/sUSDS)
- sUSDS: `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`
- phUSD: `0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605`
- Balancer Router: `0xAE563E3f8219521950555F5962419C8919758Ea2`
- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3`

## Environment Variables

Set in `.envrc` at the project root:

| Variable | Units | Example | Description |
|----------|-------|---------|-------------|
| `PHUSD_BUY_DOLLAR_IN` | Whole dollars (1 = $1) | `9596` | Dollar amount of sUSDS to swap into the pool |
| `PHUSD_BUY_MIN_OUT` | Ether units (1 = 1 phUSD = 1e18 wei) | `9700` | Minimum phUSD to receive. Tx reverts if output is below this |

## package.json Scripts

| Script | Command | Purpose |
|--------|---------|---------|
| `sim:eclp-rebalance` | `npm run sim:eclp-rebalance` | Fork simulation using `PHUSD_BUY_DOLLAR_IN`. Shows before/after pool state, marginal rates, and whether the pool lands in the e-CLP flat range. No broadcast. Uses `test/SimulateECLPRebalance.t.sol` |
| `mainnet:buy-phusd-dry` | `npm run mainnet:buy-phusd-dry` | Dry-run against mainnet (no broadcast, no Ledger). Uses sender `0xCad1a...` |
| `mainnet:buy-phusd` | `npm run mainnet:buy-phusd` | **Live broadcast** via Ledger index 46 (HD path `m/44'/60'/46'/0/0`). Forge simulates first — if `minAmountOut` check fails, nothing is sent |

## Workflow

1. **Set env vars** in `.envrc` — choose `PHUSD_BUY_DOLLAR_IN` and `PHUSD_BUY_MIN_OUT`
2. **Run simulation** — `npm run sim:eclp-rebalance` to see the expected outcome on a fork
3. **Dry-run** — `npm run mainnet:buy-phusd-dry` to verify the script reads env vars correctly
4. **Broadcast** — `npm run mainnet:buy-phusd` to execute on mainnet via Ledger

## e-CLP Pool Context

The pool uses a Gyro Elliptic Concentrated Liquidity curve with these parameters:
- **Alpha** (lower price bound): ~1.0359 phUSD per sUSDS (phUSD at $1.05)
- **Beta** (upper price bound): ~1.1449 phUSD per sUSDS (phUSD at $0.95)
- **Swap fee**: 0.3%
- **Lambda**: 50 (stretching factor)

The "flat range" is where alpha <= marginal rate <= beta. When the pool is in this zone, liquidity is deep and the price is stable. When out of range, the pool is fully concentrated in one token and effectively has no liquidity in the other direction.

**When phUSD depegs below $1:** Arbitrageurs sell phUSD for sUSDS, draining sUSDS from the pool. The marginal rate pushes toward (or past) beta. Swapping sUSDS back in pushes the rate down toward the midpoint (~1.0904), restoring peg.

## Related Files

- `test/SimulateECLPRebalance.t.sol` — Fork simulation tests (testSimulateRebalance, testFindExactPegAmount)
- `script/interactions/BalancerECLPInterfaces.sol` — Shared Balancer V3 interface definitions (IRouter, IPermit2, etc.)
- `script/interactions/CreateBalancerECLPPool.s.sol` — Original pool creation script (e-CLP parameter derivation)
- `script/interactions/VerifyBalancerECLPPool.s.sol` — Post-deploy pool verification
