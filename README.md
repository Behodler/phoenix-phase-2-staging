# phUSD Deployment Staging (Phase 2)

Deployment orchestration for [Phoenix USD (phUSD)](https://phusd.behodler.io) — an Evergreen Stablecoin on Ethereum whose backing grows over time through protocol-owned yield.

This repo deploys and configures Phase 2 contracts (Phlimbo staking, phUSD minter, yield strategies) across Anvil, Sepolia, and Mainnet. It tracks deployment state per network, serves contract data via a local API, and generates type-safe Wagmi hooks for the Phoenix UI.

## Quick Start

```bash
git submodule update --init --recursive
npm install
forge build
forge test
```

## Deploy

```bash
# Local (Anvil)
npm run dev:anvil

# Testnet
npm run deploy:sepolia

# Production
npm run deploy:mainnet
```

Deployments are checkpoint-based — if a run fails partway, re-running the same command resumes from the last successful step via `progress.<chainId>.json`.

## Project Structure

```
script/           Foundry deployment & governance scripts
src/              Views, mocks, interfaces
lib/              Git submodules (contract source lives here)
server/           Express API serving deployment data (port 3001)
hooks/            Generated Wagmi hooks
test/             Foundry tests
docs/             Project documentation
```

### Key Submodules

| Submodule | Purpose |
|-----------|---------|
| `lib/phUSD-stable-minter` | Mint-only stablecoin minter |
| `lib/phlimbo-ea` | phUSD staking yield farm |
| `lib/stable-yield-accumulator` | Multi-strategy yield consolidation |
| `lib/vault` | ERC4626 yield strategy adapters |
| `lib/flax-token-v2` | phUSD token contract |

## How phUSD Works

1. Users deposit stablecoins (DOLA, USDC) and receive phUSD at 1:1
2. Deposited capital routes into ERC4626 yield vaults (AutoDOLA, AutoUSD)
3. Vault yield is consolidated into USDC and distributed to phUSD stakers via Phlimbo
4. AMM arbitrage + counter-cyclical yield incentives maintain the dollar peg

## Mainnet Contracts

| Contract | Address |
|----------|---------|
| PhusdStableMinter | `0x435B0A1884bd0fb5667677C9eb0e59425b1477E5` |
| PhlimboEA | `0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4` |
| StableYieldAccumulator | `0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E` |
| Pauser | `0x7c5A8EeF1d836450C019FB036453ac6eC97885a3` |

## Part of the Behodler Ecosystem

phUSD is built by [Behodler](https://behodler.io) alongside the Behodler AMM, Limbo yield farm, and EYE governance token.
