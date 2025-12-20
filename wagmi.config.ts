import { defineConfig } from '@wagmi/cli'
import { foundry } from '@wagmi/cli/plugins'

export default defineConfig({
  out: 'hooks/generated.ts',
  contracts: [],
  plugins: [
    foundry({
      project: '.',
      include: [
        // Mock contracts for testing (use mocks/ directory)
        'mocks/MockPhUSD.sol/MockPhUSD.json',
        'mocks/MockRewardToken.sol/MockRewardToken.json',
        'mocks/MockYieldStrategy.sol/MockYieldStrategy.json',

        // Main Phase 2 contracts (use src/ directory)
        'src/PhusdStableMinter.sol/PhusdStableMinter.json',
        'src/Phlimbo.sol/PhlimboEA.json',

        // Key interfaces
        'src/IFlax.sol/IFlax.json',
        'interfaces/IPhlimbo.sol/IPhlimbo.json',
        'interfaces/IYieldStrategy.sol/IYieldStrategy.json',
      ],
    }),
  ],
})
