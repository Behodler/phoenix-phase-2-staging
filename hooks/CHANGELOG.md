# Changelog

All notable changes to the @behodler/phase2-wagmi-hooks package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.0] - 2026-08-01

Story-072 mainnet promotion-ready cutover. ABIs regenerated against the pinned upstream tips
(`lib/nft-staking` @ `9611312`, `lib/yield-claim-nft` @ `9c18020`,
`lib/stable-yield-accumulator` @ `6eab35c`). 0.11.0 already named every contract in this
release, so the package `description` is unchanged; what moved is the ABI content below.

### Changed
- `batchNftMinterMultiTokenAbi`: **`BatchMint__RewardTokenIsPaymentToken` REMOVED.** `nft-staking:032`
  deleted the error and the `_resolvePaymentPath()` call from `setNudgeTokenWhitelist`'s add
  branch, so a reward token may now be whitelisted on a bare, unconfigured minter and the
  payment token may itself be a reward token. Any UI decoding that error must drop it.
- `nudgeStreamerAbi`: **`NudgeStreamer__ZeroReceived` ADDED.** `nft-staking:031` made
  `collectNudge` credit the MEASURED receipt (`min(balanceDelta, amount)`) rather than the
  requested amount, and revert when a non-zero request delivers a zero delta.

### UI-breaking note (not an ABI change)
`batchMint(count, recipient, paymentAmount, minRewards)` now runs against a THREE-token
whitelist (USDC / phUSD / Kendu) on the shared batch minter. `minRewards.length` must equal
`getNudgeTokens().length` or the call reverts `BatchMint__ArrayLengthMismatch`, and the token
order changes on removal (swap-and-pop), so callers must re-fetch `getNudgeTokens()`
immediately before each batch. Two batch-minter ABIs now coexist on mainnet: the multi-token
one on the shared minter, and the legacy `batchNftMinterAbi` on the four nudge-disabled
per-token UI entrypoints.

## [0.11.0] - 2026-07-31

Catch-up release: `generated.ts` was regenerated in story-073 without a version bump, so 0.10.1 on the registry was missing everything below.

### Added
- BatchNFTMinterMultiToken hooks — multi-token batch mint helper
- NudgeStreamer & NudgeRatchet hooks — story-073 nudge stream cutover
- NFTStakerDepletionV2 & NFTStakerMigrator hooks
- MockKendu hooks (local/test token)
- BalancerPoolerV2, Uniboost: `nudgeStreamer` / `setNudgeStreamer` + `NudgeStreamerUpdated` event
- StableYieldAccumulator: `nudgeStreamer` / `setNudgeStreamer`, `batchMinter`, reward-token setter, plus `NudgeStreamNotRegistered` / `NudgeStreamerNotConfigured` errors and `NudgeStreamerUpdated` / `RewardTokenUpdated` events

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
