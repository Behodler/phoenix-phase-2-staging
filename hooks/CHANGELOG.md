# Changelog

All notable changes to the @behodler/phase2-wagmi-hooks package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.0] - 2026-06-27

### Added
- NFTStakerDepletion hooks — audited (M-01 fix) depletion-window staking model (nft-staking story-018/020)
- NFTStakerPriceScaled hooks — price-scaled staker variant (nft-staking)
- NudgeRatchetDelayRelease hooks — yield-claim-nft dispatcher wired at index 7 (story-043)
- Uniboost & UniboostMintDebtHook hooks — buy-and-pool UniV2 dispatcher + mint-debt hook (yield-claim-nft story-040/041)

### Removed
- NFTMinter, BalancerPooler, BurnerV2, NFTMigrator (NFT V1) hooks — removed upstream in yield-claim-nft story-039's src flatten

## [0.9.0] - 2026-06-16

### Added
- ERC4626YieldStrategy & ERC4626MarketYieldStrategy: `previewDeposit` / `previewRedeem` view functions
- ERC4626YieldStrategy & ERC4626MarketYieldStrategy: set-aside-buffer recipient wiring — `setAsideBufferRecipient` (getter), `setSetAsideBufferRecipient` (setter), and `SetAsideBufferRecipientSet` event

### Removed
- Burner and Gather (NFT V1) hooks — V1 contracts removed from the build (story 059)

## [0.8.0] - 2026-06-03

### Added
- StableStaker hooks (ERC4626-style staking vault for stablecoins with a configurable set-aside buffer, wired into the global Pauser)

## [0.5.0] - 2026-04-29

### Added
- NFTStaker hooks (Masterchef-style staking pool over BalancerPoolerV2 NFT id 4, paying phUSD rewards sized off targetAPY)
- BalancerPoolerMintDebtHook hooks (dispatch hook that accrues phUSD mint debt on BalancerPoolerV2 mints; owner/recipient can call pull())
- BatchNFTMinter hooks (stateless helper that loops ITokenMinterV2.mint() and refunds dust)

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
