import { defineConfig } from '@wagmi/cli'
import { foundry } from '@wagmi/cli/plugins'

/**
 * The include list below is scoped to ONE rule: an ABI earns its place here only if the
 * local dev stack (`npm run dev` -> script/DeployMocks.s.sol) actually puts an instance of
 * that type on the chain. DeployMocks is a deliberate superset of what the UI needs, so it
 * is a safe upper bound; anything it does not deploy is dead weight here.
 *
 * This replaces the older "retain the superseded type while the UI transitions" posture.
 * Every generation that has finished its mainnet cutover (PhlimboV2 + MigratorV2V3,
 * NFTStakerDepletion + NFTStakerMigrator, NudgeRatchetDelayRelease, DepositView +
 * DepositPageView, and the V1 StableStaker) is gone from the list: the cutovers have
 * executed, nothing local deploys those types any more, and a stale ABI in a published
 * package is a live invitation to decode the wrong contract.
 *
 * StableStakerV1 is a special case worth naming, because DeployMocks DOES still deploy it.
 * It exists there purely as the SOURCE of the V1->V2 cutover rehearsal (story 080) and is
 * untracked -- it gets no `ContractAddresses` key, and neither does the CrossVersionMigrator
 * that drains it. No address means nothing for the UI to call, so neither type is exported.
 */
export default defineConfig({
  out: 'hooks/generated.ts',
  contracts: [],
  plugins: [
    foundry({
      project: '.',
      include: [
        // Mock contracts for testing
        'MockPhUSD.sol/MockPhUSD.json',
        // MockRewardToken is the consolidated USDC mock (6dp) -- Phlimbo's reward token, the
        // Uniboost prime token, and the underlying of waUSDC / the Sky PSM mocks.
        'MockRewardToken.sol/MockRewardToken.json',
        // Story 073: third nudge-reward asset on the multi-token batch minter.
        'MockKendu.sol/MockKendu.json',

        // Main Phase 2 contracts
        'PhusdStableMinter.sol/PhusdStableMinter.json',
        'PhlimboV3.sol/PhlimboV3.json',

        // Key interfaces (path-prefixed to avoid duplicate artifact conflicts).
        // IFlax is the phUSD token interface behind the `PhUSD` address key. It is retained
        // even though the LOCAL phUSD is a MockPhUSD, because on a real network that key
        // points at the actual Flax-token phUSD and mockPhUsdAbi would be the wrong shape.
        'src/IFlax.sol/IFlax.json',
        // IPhlimbo (the V1/V2 shape) is deliberately NOT here: its 3-tuple `userInfo`
        // silently mis-decodes PhlimboV3's 4-tuple. Use phlimboV3Abi.
        'interfaces/IYieldStrategy.sol/IYieldStrategy.json',

        // NFT Minter infrastructure
        'BurnRecorder.sol/BurnRecorder.json',
        'NFTMinterV2.sol/NFTMinterV2.json',
        'BalancerPoolerV2.sol/BalancerPoolerV2.json',
        'GatherV2.sol/GatherV2.json',
        'MultiPooler.sol/MultiPooler.json',

        // Dispatchers (yield-claim-nft story-040/043)
        'NudgeRatchet.sol/NudgeRatchet.json',
        'Uniboost.sol/Uniboost.json',

        // V2 Dispatch hooks. DefaultDispatchHook is constructor-installed on every
        // dispatcher and is left in place on the ones that accrue no mint debt.
        'IDispatchHook.sol/IDispatchHook.json',
        'DefaultDispatchHook.sol/DefaultDispatchHook.json',
        'BalancerPoolerMintDebtHook.sol/BalancerPoolerMintDebtHook.json',
        'UniboostMintDebtHook.sol/UniboostMintDebtHook.json',
        'NudgeRatchetMintDebtHook.sol/NudgeRatchetMintDebtHook.json',

        // NFT Staking
        'NFTStaker.sol/NFTStaker.json',
        'NFTStakerDepletionV2.sol/NFTStakerDepletionV2.json',
        'NFTStakerPriceScaled.sol/NFTStakerPriceScaled.json',
        // Both batch-minter shapes are live locally and on mainnet: the shared minter is the
        // multi-token one (length-3 minRewards), the four per-dispatcher minters are legacy.
        'BatchNFTMinter.sol/BatchNFTMinter.json',
        'BatchNFTMinterMultiToken.sol/BatchNFTMinterMultiToken.json',
        'NudgeStreamer.sol/NudgeStreamer.json',

        // Stable Staker (yield farm for stablecoin staking) and the Antimatter reward token
        // it pays instead of phUSD.
        'StableStakerV2.sol/StableStakerV2.json',
        'Antimatter.sol/Antimatter.json',

        // Core infrastructure
        'StableYieldAccumulator.sol/StableYieldAccumulator.json',
        'ERC4626YieldStrategy.sol/ERC4626YieldStrategy.json',
        // USDe strategy uses the AMM-market variant (slippage haircut + principalOf/totalBalanceOf)
        'ERC4626MarketYieldStrategy.sol/ERC4626MarketYieldStrategy.json',
        'Pauser.sol/Pauser.json',

        // View contracts for UI polling. Story 078 left ViewRouter as the sole view ADDRESS
        // key; DepositPageViewV3 and MintPageView are still deployed behind it, so their
        // ABIs stay (the router cannot forward an unknown layout).
        'DepositPageViewV3.sol/DepositPageViewV3.json',
        'ViewRouter.sol/ViewRouter.json',
        'MintPageView.sol/MintPageView.json',
      ],
    }),
  ],
})
