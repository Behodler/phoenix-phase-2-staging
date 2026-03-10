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
        'MockYieldStrategy.sol/MockYieldStrategy.json',

        // Main Phase 2 contracts
        'PhusdStableMinter.sol/PhusdStableMinter.json',
        'Phlimbo.sol/PhlimboEA.json',

        // Key interfaces (path-prefixed to avoid duplicate artifact conflicts)
        'src/IFlax.sol/IFlax.json',
        'IPhlimbo.sol/IPhlimbo.json',
        'interfaces/IYieldStrategy.sol/IYieldStrategy.json',

        // NFT Minter infrastructure
        'NFTMinter.sol/NFTMinter.json',
        'BurnRecorder.sol/BurnRecorder.json',

        // Dispatchers
        'BalancerPooler.sol/BalancerPooler.json',
        'Burner.sol/Burner.json',
        'Gather.sol/Gather.json',

        // View contracts for UI polling
        'DepositView.sol/DepositView.json',
        'ViewRouter.sol/ViewRouter.json',
        'MintPageView.sol/MintPageView.json',
      ],
    }),
  ],
})
