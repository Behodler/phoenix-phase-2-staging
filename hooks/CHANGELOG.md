# Changelog

All notable changes to the @behodler/phase2-wagmi-hooks package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-01-24

### Removed
- Removed StableYieldAccumulator hooks (contract deprecated from architecture)
- Removed IStableYieldAccumulator interface hooks

### Changed
- PhlimboEA constructor now takes only 3 parameters (phUSD, rewardToken, depletionDuration)
- Simplified architecture: rewards are now injected directly via collectReward()

## [0.1.5] - 2026-01-16

### Added
- DepositView contract for efficient UI polling
  - Aggregates all deposit-related data in a single RPC call
  - Returns userPhUSDBalance, phUSDRewardsPerSecond, stableRewardsPerSecond, pendingPhUSDRewards, pendingStableRewards, stakedBalance, and userAllowance
  - Enables consistent data snapshots for reactive UI updates

## [0.1.0] - 2025-12-20

### Added
- Initial release of @behodler/phase2-wagmi-hooks package
- Type-safe wagmi hooks for Phoenix Phase 2 protocol contracts
- Support for PhusdStableMinter contract (phUSD minting mechanisms)
- Support for Phlimbo contract (yield farm for phUSD staking)
- Mock contract hooks for testing:
  - MockPhUSD (mock phUSD token)
  - MockRewardToken (mock reward token for yield distributions)
  - MockYieldStrategy (mock yield strategy for accumulation logic)
- Interface hooks for:
  - IFlax (Flax token interface)
  - IPhlimbo (Phlimbo interface)
  - IYieldStrategy (Yield strategy interface)
  - IPhusdStableMinter (phUSD minter interface)
- Comprehensive README with installation and usage examples
- Published to GitHub Package Registry under @behodler organization

### Notes
- This package provides hooks for Phoenix Phase 2 contracts
- Sibling package @behodler/wagmi-hooks covers Phase 1 contracts
- All documentation uses correct terminology: phUSD (Phoenix USD), not pxUSD
- Initial contract coverage includes stable minting and yield farming functionality
