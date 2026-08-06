# Changelog

All notable changes to the @behodler/phase2-wagmi-hooks package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.14.0] - 2026-08-07

Story-078. The read side of the PhlimboV3 cutover. **This is the first published release since
0.12.0** — 0.13.0 was version-bumped in the repo but never pushed to the registry, so a consumer
upgrading from 0.12.0 receives both releases' contents at once. The 0.13.0 notes below therefore
apply to this upgrade too.

Strictly additive across both releases: no ABI export was removed, and no existing ABI's content
changed.

### Added
- `depositPageViewV3Abi` — `IPageView` implementation for the deposit page, typed against
  `IPhlimboV3`.

### UI-breaking note (not an ABI change)
**`DepositPageViewV3` is NOT a drop-in re-cast of `DepositPageView`, and the failure is silent.**
`PhlimboV3.userInfo` returns a **4**-tuple (`amount`, `phUSDDebt`, `stableDebt`, `promoDebt`)
where V1/V2 returned 3. Solidity's decoder tolerates extra trailing returndata for static types,
so pointing the old V1-typed page at a V3 farm does **not** revert — it returns
undefined-by-accident data carrying none of the promo fields. Field count grows 7 → 23.

Resolve the page through the router, never through a hardcoded address:
`address impl = await router.pages(keccak256("deposit"))`. This package deliberately ships **no
addresses** (`wagmi.config.ts` declares no `deployments:`), because a second address-resolution
path competing with `ViewRouter` is exactly how the mainnet deposit page sat on a stale view
unnoticed for months.

Two scaling traps in the returned array, both inherited unchanged from the predecessor so that
existing consumers are not silently broken by `1e18`:
- field 1 `phUSDRewardsPerSecond` is **RAW** (phUSD wei/second, not PRECISION-scaled)
- field 2 `stableRewardsPerSecond` and field 13 `promoRewardPerSecond` are **PRECISION-scaled**

Also note `pendingX` is **not** the user's entitlement: V3 banks a failed transfer or mint per
user and `pendingX` then reads zero by design. True entitlement is `pendingX + bank` — read
fields 20/21/22 (`unclaimablePromo` / `unclaimableStable` / `unclaimablePhUSD`) or a banked user
will be told they have nothing.

## [0.13.0] - 2026-08-04

Story-076. Phase 4e of the mainnet promotion-ready cutover: a new `PhlimboV3` farm and the
one-shot migration of the `PhlimboV2` user base into it. **Never published to the registry** —
see the 0.14.0 note above.

### Added
- `phlimboV3Abi` — the post-cutover farm. Adds a single rotating promotional reward slot
  (`promoPhase` is `0 = None`, `1 = Active`, `2 = Flushing`), staker enumeration
  (`stakerCount` / `stakerAt`), and non-reverting reward settlement with per-user banks
  (`claimUnclaimablePromo` / `claimUnclaimableStable` / `claimUnclaimablePhUSD`).
- `migratorV2V3Abi` — the transient V2→V3 migrator. Included for **event decoding**, not for
  calling: a misconfigured pass completes without reverting, and `UserMigrationSkipped` carries
  the raw revert data that tells a genuinely bad position apart from a wiring mistake.

### UI-breaking note (not an ABI change)
`stake`, `withdraw` and `claim` all take an explicit `user` argument on V3, gated on
`msg.sender == user || msg.sender == migrator`. The V1 shapes (`withdraw(uint256)`,
`claim()`, and the `withdraw(0)`-to-claim idiom) are gone; V3 exposes a first-class
`claim(address)`. While `promoPhase == Flushing` the contract is paused and `pendingPromo` is
frozen — read the promo phase and the paused flag together, or a UI shows a stalled counter with
no explanation.

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
