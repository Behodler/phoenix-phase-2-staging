import { defineConfig } from '@wagmi/cli'
import { foundry } from '@wagmi/cli/plugins'

export default defineConfig({
  out: 'hooks/generated.ts',
  contracts: [],
  plugins: [
    foundry({
      project: '.',
      include: [
        // Mock contracts for testing
        'MockPhUSD.sol/MockPhUSD.json',
        'MockRewardToken.sol/MockRewardToken.json',
        // Story 073: third nudge-reward asset on the multi-token batch minter.
        'MockKendu.sol/MockKendu.json',

        // Main Phase 2 contracts
        'PhusdStableMinter.sol/PhusdStableMinter.json',
        // PhlimboV2 is RETAINED as an ABI although the local chain no longer deploys it: story
        // 076's cutover migrated the mainnet user base into V3, but V2 still exists there wound
        // down and unpaused, so the UI must stay able to read it. ABI retention and address
        // retention are decoupled -- see the view-contract note below.
        'PhlimboV2.sol/PhlimboV2.json',
        'PhlimboV3.sol/PhlimboV3.json',
        // MigratorV2V3 is TRANSIENT, gets no address key, and is no longer deployed locally now
        // that the V2->V3 cutover has executed on mainnet. It is included anyway for the ABI
        // alone, to decode a historical migration pass: `UserMigrationSkipped` and
        // `RewardForwardFailed` are the ONLY diagnostic surface for a failed migration pass
        // (the pass completes even when wholly misconfigured -- MigratorV2V3.sol:68-73), and
        // decoding those events off-chain is exactly what an operator needs.
        'MigratorV2V3.sol/MigratorV2V3.json',

        // Key interfaces (path-prefixed to avoid duplicate artifact conflicts)
        'src/IFlax.sol/IFlax.json',
        'IPhlimbo.sol/IPhlimbo.json',
        'interfaces/IYieldStrategy.sol/IYieldStrategy.json',

        // NFT Minter infrastructure
        'BurnRecorder.sol/BurnRecorder.json',

        // V2 NFT Minter infrastructure
        // (V1 NFTMinter / BalancerPooler / Burner / Gather / BurnerV2 / NFTMigrator
        //  were removed upstream in yield-claim-nft story-039's src flatten)
        'NFTMinterV2.sol/NFTMinterV2.json',
        'BalancerPoolerV2.sol/BalancerPoolerV2.json',
        'GatherV2.sol/GatherV2.json',
        'MultiPooler.sol/MultiPooler.json',

        // Dispatchers (yield-claim-nft story-040/043)
        // NudgeRatchetDelayRelease is RETAINED on purpose: story 073 swapped index 7 back to
        // NudgeRatchet locally, but the retired type stays readable by the UI during the
        // transition (the same posture story 072 takes for the mainnet cutover).
        'NudgeRatchetDelayRelease.sol/NudgeRatchetDelayRelease.json',
        'NudgeRatchet.sol/NudgeRatchet.json',
        'Uniboost.sol/Uniboost.json',

        // V2 Dispatch hooks
        'IDispatchHook.sol/IDispatchHook.json',
        'DefaultDispatchHook.sol/DefaultDispatchHook.json',
        'BalancerPoolerMintDebtHook.sol/BalancerPoolerMintDebtHook.json',
        'UniboostMintDebtHook.sol/UniboostMintDebtHook.json',

        // NFT Staking
        'NFTStaker.sol/NFTStaker.json',
        // NFTStakerDepletion, NFTStakerMigrator and BatchNFTMinter are RETAINED alongside their
        // story-073 successors: the local chain deploys only the V2 / multi-token types now that
        // the migration has executed on mainnet, but the retired ABIs stay readable while the UI
        // transitions.
        'NFTStakerDepletion.sol/NFTStakerDepletion.json',
        'NFTStakerDepletionV2.sol/NFTStakerDepletionV2.json',
        'NFTStakerMigrator.sol/NFTStakerMigrator.json',
        'NFTStakerPriceScaled.sol/NFTStakerPriceScaled.json',
        'BatchNFTMinter.sol/BatchNFTMinter.json',
        'BatchNFTMinterMultiToken.sol/BatchNFTMinterMultiToken.json',
        'NudgeStreamer.sol/NudgeStreamer.json',

        // Stable Staker (yield farm for stablecoin staking)
        // Story 080: this entry used to read 'StableStaker.sol/StableStaker.json', which has not
        // been a real artifact since the stable-staker repo split into a frozen V1 snapshot and
        // the evergreen V2 — there is no out/StableStaker.sol/ directory, so a `wagmi generate`
        // would have silently DROPPED the export and the `stableStakerAbi` still in
        // hooks/generated.ts was a frozen leftover carrying the V1 constructor shape.
        'StableStakerV2.sol/StableStakerV2.json',
        // The Antimatter reward token V2 pays instead of phUSD.
        'Antimatter.sol/Antimatter.json',

        // Core infrastructure
        'StableYieldAccumulator.sol/StableYieldAccumulator.json',
        'ERC4626YieldStrategy.sol/ERC4626YieldStrategy.json',
        // USDe strategy uses the AMM-market variant (slippage haircut + principalOf/totalBalanceOf)
        'ERC4626MarketYieldStrategy.sol/ERC4626MarketYieldStrategy.json',
        'Pauser.sol/Pauser.json',

        // View contracts for UI polling
        // Story 078 removed the DepositView / DepositPageView / MintPageView ADDRESS keys from
        // the address books, leaving ViewRouter as the sole view key — but the ABIs below are
        // all RETAINED, on the same reasoning as NudgeRatchetDelayRelease and NFTStakerDepletion
        // above: superseded types stay readable while the UI transitions, whether or not
        // DeployMocks still deploys them (it no longer deploys either deposit page). The two
        // surfaces are
        // decoupled — this config declares no `deployments:`, so it emits bare `…Abi` exports
        // and no addresses, and keeping an ABI therefore cannot reintroduce a second
        // address-resolution path. Retaining DepositPageViewV3's predecessors also keeps
        // `getRetiredPromoBanks` and the old layouts callable, which the router cannot forward.
        'DepositView.sol/DepositView.json',
        'DepositPageView.sol/DepositPageView.json',
        'DepositPageViewV3.sol/DepositPageViewV3.json',
        'ViewRouter.sol/ViewRouter.json',
        'MintPageView.sol/MintPageView.json',
      ],
    }),
  ],
})
