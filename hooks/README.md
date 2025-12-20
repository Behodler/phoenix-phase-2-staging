# @behodler/phase2-wagmi-hooks

Type-safe Wagmi hooks for Phoenix Phase 2 protocol contracts including MockPhUSD, MockRewardToken, MockYieldStrategy, PhusdStableMinter, and PhlimboEA.

## Installation

This package is published to GitHub Package Registry under the Behodler organization.

### Prerequisites

1. **GitHub Personal Access Token**: You need a GitHub personal access token with `read:packages` scope.
   - Create one at: https://github.com/settings/tokens
   - Select `read:packages` scope

2. **Configure npm for GitHub Registry**: Create or update `.npmrc` in your project root:

```bash
@behodler:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_GITHUB_TOKEN
```

**Important**: Replace `YOUR_GITHUB_TOKEN` with your actual GitHub personal access token. For security, consider using environment variables:

```bash
@behodler:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

Then set the environment variable before running npm commands:
```bash
export GITHUB_TOKEN=your_token_here
```

### Install the Package

```bash
npm install @behodler/phase2-wagmi-hooks
```

Or with yarn:
```bash
yarn add @behodler/phase2-wagmi-hooks
```

## Usage

Import the generated hooks in your React/TypeScript application:

```typescript
import {
  useMockPhUSDRead,
  useMockPhUSDWrite,
  useMockRewardTokenRead,
  useMockRewardTokenWrite,
  useMockYieldStrategyRead,
  useMockYieldStrategyWrite,
  usePhusdStableMinterRead,
  usePhusdStableMinterWrite,
  usePhlimboRead,
  usePhlimboWrite,
  // ... and many more
} from '@behodler/phase2-wagmi-hooks'
```

### Example: Reading phUSD Balance

```typescript
import { useMockPhUSDRead } from '@behodler/phase2-wagmi-hooks'

function PhUSDBalance({ address }: { address: string }) {
  const { data: balance, isLoading, isError } = useMockPhUSDRead({
    functionName: 'balanceOf',
    args: [address],
  })

  if (isLoading) return <div>Loading...</div>
  if (isError) return <div>Error fetching balance</div>

  return <div>Balance: {balance?.toString()}</div>
}
```

### Example: Minting phUSD

```typescript
import { usePhusdStableMinterWrite } from '@behodler/phase2-wagmi-hooks'
import { parseUnits } from 'viem'

function MintButton({ amount }: { amount: string }) {
  const { write, isLoading, isSuccess } = usePhusdStableMinterWrite({
    functionName: 'mint',
    args: [parseUnits(amount, 18)],
  })

  return (
    <button onClick={() => write?.()} disabled={isLoading}>
      {isLoading ? 'Minting...' : 'Mint phUSD'}
    </button>
  )
}
```

### Example: Staking in Phlimbo

```typescript
import { usePhlimboWrite, usePhlimboRead } from '@behodler/phase2-wagmi-hooks'
import { parseUnits } from 'viem'

function StakePhUSD({
  phlimboAddress,
  amount
}: {
  phlimboAddress: string
  amount: string
}) {
  const { write: stake, isLoading } = usePhlimboWrite({
    address: phlimboAddress,
    functionName: 'stake',
    args: [parseUnits(amount, 18)],
  })

  const { data: stakedBalance } = usePhlimboRead({
    address: phlimboAddress,
    functionName: 'balanceOf',
    args: [userAddress],
  })

  return (
    <div>
      <p>Staked: {stakedBalance?.toString()}</p>
      <button onClick={() => stake?.()} disabled={isLoading}>
        {isLoading ? 'Staking...' : `Stake ${amount} phUSD`}
      </button>
    </div>
  )
}
```

### Example: Using Yield Strategy

```typescript
import { useMockYieldStrategyRead } from '@behodler/phase2-wagmi-hooks'

function YieldInfo({
  strategyAddress,
  userAddress
}: {
  strategyAddress: string
  userAddress: string
}) {
  const { data: totalBalance } = useMockYieldStrategyRead({
    address: strategyAddress,
    functionName: 'totalBalanceOf',
    args: [userAddress],
  })

  const { data: principal } = useMockYieldStrategyRead({
    address: strategyAddress,
    functionName: 'principalOf',
    args: [userAddress],
  })

  return (
    <div>
      <p>Total Balance (with yield): {totalBalance?.toString()}</p>
      <p>Principal Deposited: {principal?.toString()}</p>
    </div>
  )
}
```

## Available Contracts

This package includes hooks for the following Phase 2 contracts:

### Main Contracts
- **PhusdStableMinter**: Minting mechanisms for phUSD stablecoin
- **Phlimbo**: Yield farm for staking phUSD and earning mixed yield in phUSD and stablecoins

### Mock Contracts (Testing)
- **MockPhUSD**: Mock phUSD token for testing
- **MockRewardToken**: Mock reward token for testing yield distributions
- **MockYieldStrategy**: Mock yield strategy for testing accumulation logic

## Interfaces

The package also exports hooks for key interfaces:
- IFlax
- IPhlimbo
- IYieldStrategy
- IPhusdStableMinter

## Development

This package is auto-generated from the phStaging2 deployment repository. Do not edit the generated hooks manually.

To update hooks in the source repository:
```bash
npm run generate:hooks
```

## Requirements

- `viem ^2.0.0`
- `wagmi ^2.0.0`

## License

MIT

## Repository

https://github.com/Behodler/phStaging2

## Notes

**CRITICAL TERMINOLOGY**: The token is **phUSD** (Phoenix USD), NOT pxUSD. pxUSD is a completely different token from another company that exists on mainnet. Always use phUSD in all code, documentation, and user-facing text.
