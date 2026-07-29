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
        'PhlimboV2.sol/PhlimboV2.json',

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
        // NFTStakerDepletion and BatchNFTMinter are RETAINED alongside their story-073
        // successors: the local chain now ends on the V2 / multi-token types, but the retired
        // ABIs stay readable while the UI transitions.
        'NFTStakerDepletion.sol/NFTStakerDepletion.json',
        'NFTStakerDepletionV2.sol/NFTStakerDepletionV2.json',
        'NFTStakerMigrator.sol/NFTStakerMigrator.json',
        'NFTStakerPriceScaled.sol/NFTStakerPriceScaled.json',
        'BatchNFTMinter.sol/BatchNFTMinter.json',
        'BatchNFTMinterMultiToken.sol/BatchNFTMinterMultiToken.json',
        'NudgeStreamer.sol/NudgeStreamer.json',

        // Stable Staker (yield farm for stablecoin staking)
        'StableStaker.sol/StableStaker.json',

        // Core infrastructure
        'StableYieldAccumulator.sol/StableYieldAccumulator.json',
        'ERC4626YieldStrategy.sol/ERC4626YieldStrategy.json',
        // USDe strategy uses the AMM-market variant (slippage haircut + principalOf/totalBalanceOf)
        'ERC4626MarketYieldStrategy.sol/ERC4626MarketYieldStrategy.json',
        'Pauser.sol/Pauser.json',

        // View contracts for UI polling
        'DepositView.sol/DepositView.json',
        'DepositPageView.sol/DepositPageView.json',
        'ViewRouter.sol/ViewRouter.json',
        'MintPageView.sol/MintPageView.json',
      ],
    }),
  ],
})
