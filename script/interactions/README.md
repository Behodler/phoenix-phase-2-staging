# Contract Interaction Test Scripts

This directory contains Foundry scripts to test and interact with deployed Phoenix Phase 2 contracts on local Anvil. These scripts validate that contracts function correctly before integrating with the Phoenix UI.

## Overview

The scripts simulate real-world user and admin operations:

- **User Operations**: Mint phUSD, stake on Phlimbo, claim rewards, withdraw
- **View Operations**: Query pending rewards, pool info, yield strategies, mint quotes
- **Admin Operations**: Set APY, register stablecoins, update rates, pause contracts
- **Test Helpers**: Fund test users, simulate yield, fast-forward time (Anvil only)

## Prerequisites

1. **Anvil Running**: Start local blockchain with `npm run start:anvil`
2. **Contracts Deployed**: Deploy contracts with `npm run deploy:local`
3. **Addresses Loaded**: Scripts automatically load addresses from `server/deployments/local.json`

## Quick Start

After running `npm run dev`, you can interact with contracts using npm scripts:

```bash
# User operations
npm run interact:mint                # Mint phUSD by depositing stablecoins
npm run interact:stake               # Stake phUSD on Phlimbo
npm run interact:claim-rewards       # Claim accumulated Phlimbo rewards
npm run interact:withdraw            # Withdraw staked phUSD from Phlimbo
npm run interact:claim-accumulator   # Trigger Phlimbo to collect from yield accumulator

# View operations (read-only, no transactions)
npm run view:pending-rewards         # View pending rewards for default user
npm run view:pool                    # View Phlimbo pool information
npm run view:yield-strategies        # View yield strategy balances and config
npm run view:mint-quote              # Preview phUSD mint amounts

# Admin operations
npm run admin:set-apy                # Set desired APY on Phlimbo (two-step)
npm run admin:register-stable        # Register a new stablecoin
npm run admin:update-rate            # Update exchange rate for a stablecoin
npm run admin:add-yield-strategy     # Authorize a new yield strategy client
npm run admin:set-yield-rate         # Set yield rate on MockYieldStrategy
npm run admin:pause                  # Pause/unpause Phlimbo contract

# Test helpers (Anvil only)
npm run test:fund-user               # Fund test user with tokens
npm run test:simulate-yield          # Add simulated yield to strategy
npm run test:fast-forward            # Fast-forward blockchain time
```

## Script Categories

### User Operations

#### MintPhUSD.s.sol
Mints phUSD by depositing stablecoins into PhusdStableMinter.

**Flow:**
1. Approve stablecoin for minter
2. Call `mint()` to deposit stablecoin and receive phUSD
3. Logs amount received

**Usage:**
```bash
npm run interact:mint
# OR
forge script script/interactions/MintPhUSD.s.sol:MintPhUSD --rpc-url http://localhost:8545 --broadcast
```

#### StakeOnPhlimbo.s.sol
Stakes phUSD on Phlimbo yield farm to earn rewards.

**Flow:**
1. Approve phUSD for Phlimbo
2. Call `stake()` to deposit phUSD
3. Logs staked amount

**Usage:**
```bash
npm run interact:stake
```

#### ClaimPhlimboRewards.s.sol
Claims accumulated rewards (phUSD + stablecoin) from Phlimbo staking.

**Flow:**
1. Call `withdraw(0)` to claim without unstaking
2. Logs rewards claimed in both tokens

**Usage:**
```bash
npm run interact:claim-rewards
```

#### WithdrawFromPhlimbo.s.sol
Withdraws staked phUSD from Phlimbo (also claims pending rewards).

**Flow:**
1. Call `withdraw(amount)` to unstake
2. Automatically claims pending rewards
3. Logs amount unstaked and rewards received

**Usage:**
```bash
npm run interact:withdraw
```

#### ClaimYieldAccumulator.s.sol
Triggers Phlimbo to collect rewards from the yield accumulator.

**Flow:**
1. Call `collectReward()` on Phlimbo
2. Phlimbo pulls yield from MockYieldStrategy
3. Logs rewards collected

**Usage:**
```bash
npm run interact:claim-accumulator
```

### View Operations

These are read-only scripts that query contract state without modifying it.

#### ViewPendingRewards.s.sol
Displays pending rewards for a user on Phlimbo.

**Shows:**
- Pending phUSD rewards
- Pending stablecoin rewards
- User's staked amount
- User's share of total pool

**Usage:**
```bash
npm run view:pending-rewards
```

#### ViewPoolInfo.s.sol
Shows global Phlimbo pool statistics.

**Shows:**
- Total phUSD staked in pool
- Desired APY (in basis points and percentage)
- Current emission rates (phUSD and stablecoin per second)
- Estimated daily emissions
- Last reward update timestamp
- Pause status

**Usage:**
```bash
npm run view:pool
```

#### ViewYieldStrategies.s.sol
Displays yield strategy balances and configurations.

**Shows:**
- Minter's principal balance in yield strategy
- Minter's total balance (principal + yield)
- Accumulated yield
- Yield rate configuration
- Authorization status
- Stablecoin configuration from minter

**Usage:**
```bash
npm run view:yield-strategies
```

#### ViewMintQuote.s.sol
Previews how much phUSD will be minted for various stablecoin amounts.

**Shows:**
- Stablecoin configuration (exchange rate, decimals)
- Mint quotes for 10, 100, 1000, and 10,000 stablecoin amounts

**Usage:**
```bash
npm run view:mint-quote
```

### Admin Operations

These scripts require owner/admin permissions and modify contract state.

#### SetDesiredAPY.s.sol
Sets the desired APY on Phlimbo (two-step process for safety).

**Flow:**
1. Call `setDesiredAPY(newAPY)` to preview change
2. Advance block
3. Call `setDesiredAPY(newAPY)` again to commit
4. Logs old and new APY

**Default:** Sets APY to 7.5% (750 basis points)

**Usage:**
```bash
npm run admin:set-apy
```

#### RegisterStablecoin.s.sol
Registers a new stablecoin with the PhusdStableMinter.

**Flow:**
1. Call `registerStablecoin()` with token address, yield strategy, rate, and decimals
2. Logs configuration
3. Verifies registration

**Usage:**
```bash
npm run admin:register-stable
```

#### UpdateExchangeRate.s.sol
Updates the exchange rate for an existing stablecoin.

**Flow:**
1. Reads current exchange rate
2. Updates to new rate (default: 0.95:1)
3. Shows impact on mint amounts

**Usage:**
```bash
npm run admin:update-rate
```

#### AddYieldStrategy.s.sol
Authorizes a new client on MockYieldStrategy.

**Flow:**
1. Check current authorization
2. Call `setClient()` to authorize
3. Verify authorization

**Usage:**
```bash
npm run admin:add-yield-strategy
```

#### SetDiscountRate.s.sol
Sets the yield rate on MockYieldStrategy for testing.

**Flow:**
1. Read current yield rate
2. Update to new rate (default: 10% APY = 1000 bps)
3. Log old and new rates

**Usage:**
```bash
npm run admin:set-yield-rate
```

#### PauseContract.s.sol
Pauses or unpauses the Phlimbo contract (emergency operation).

**Flow:**
1. Check current pause state
2. Toggle pause state (pause if unpaused, unpause if paused)
3. Verify new state

**Usage:**
```bash
npm run admin:pause
```

### Test Helpers

These scripts are for local testing only and should NOT be used on real networks.

#### FundTestUser.s.sol
Funds a test user with phUSD and stablecoins for testing.

**Flow:**
1. Mint 1000 phUSD to test user
2. Mint 10,000 USDC to test user
3. Log balances before and after

**Usage:**
```bash
npm run test:fund-user
```

#### SimulateYield.s.sol
Manually adds simulated yield to MockYieldStrategy without waiting.

**Flow:**
1. Read current yield
2. Add 1000 USDC worth of yield
3. Log yield increase

**Usage:**
```bash
npm run test:simulate-yield
```

#### FastForward.s.sol
Fast-forwards blockchain time to test time-dependent features.

**Flow:**
1. Use `vm.warp()` to advance timestamp by 1 day
2. Use `vm.roll()` to advance block number
3. Log time advancement

**Note:** Effects only visible in subsequent script calls in same session.

**Usage:**
```bash
npm run test:fast-forward
```

## AddressLoader Library

The `AddressLoader.sol` library provides a centralized way to access deployed contract addresses. All scripts use this library to load addresses from `server/deployments/local.json`.

**Functions:**
- `getPhUSD()` - Returns MockPhUSD address
- `getRewardToken()` - Returns MockRewardToken address
- `getYieldStrategy()` - Returns MockYieldStrategy address
- `getMinter()` - Returns PhusdStableMinter address
- `getPhlimbo()` - Returns PhlimboEA address
- `getDefaultUser()` - Returns Anvil's default test address
- `getDefaultPrivateKey()` - Returns Anvil's default private key
- `logAddresses()` - Logs all addresses for debugging

## Customizing Scripts

All scripts use Anvil's default account (0xf39F...) for simplicity. To customize:

1. **Change amounts**: Edit the amount variables in each script
2. **Change user**: Modify the `testUser` variable in relevant scripts
3. **Change parameters**: Update configuration values (APY, rates, etc.)

## Security Notes

- These scripts use publicly known private keys from Anvil
- NEVER use these scripts or private keys on real networks (Sepolia, Mainnet)
- For production, use hardware wallets and secure key management
- Mock contracts allow unlimited minting - suitable for testing only

## Typical Workflow

1. **Setup**: Start Anvil and deploy contracts
   ```bash
   npm run dev
   ```

2. **Fund user**: Give test user initial tokens
   ```bash
   npm run test:fund-user
   ```

3. **User flow**: Simulate user journey
   ```bash
   npm run interact:mint          # Mint phUSD
   npm run interact:stake         # Stake on Phlimbo
   npm run view:pending-rewards   # Check rewards
   npm run interact:claim-rewards # Claim rewards
   ```

4. **Admin operations**: Configure contracts
   ```bash
   npm run admin:set-apy          # Adjust APY
   npm run view:pool              # Verify change
   ```

5. **Testing yield**: Simulate yield generation
   ```bash
   npm run test:simulate-yield    # Add yield
   npm run view:yield-strategies  # Verify yield
   npm run interact:claim-accumulator # Collect to Phlimbo
   ```

## Troubleshooting

**"No contract deployed at address"**
- Ensure contracts are deployed with `npm run deploy:local`
- Verify addresses in `server/deployments/local.json` match AddressLoader

**"Insufficient balance" or "ERC20: transfer amount exceeds balance"**
- Fund test user first: `npm run test:fund-user`
- Check balances with view scripts

**"Not authorized" errors**
- Verify deployment completed successfully
- Check that authorization steps in DeployMocks.s.sol executed

**View scripts return zeros**
- Ensure you've performed operations first (mint, stake, etc.)
- Simulate yield if testing reward accumulation

## Contract Addresses

Default Anvil deployment addresses (deterministic):

- MockPhUSD: `0x5FbDB2315678afecb367f032d93F642f64180aa3`
- MockRewardToken: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`
- MockYieldStrategy: `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0`
- PhusdStableMinter: `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`
- PhlimboEA: `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9`

## Integration with Phoenix UI

These scripts validate the same operations that the Phoenix UI will perform via Wagmi hooks:

1. **UI fetches addresses**: From `http://localhost:3001/contracts`
2. **UI imports hooks**: From generated `@behodler/wagmi-hooks`
3. **UI calls contract functions**: Same operations as these scripts
4. **Scripts validate**: That contract interactions work before UI integration

## Further Reading

- Foundry Scripts Documentation: https://book.getfoundry.sh/tutorials/solidity-scripting
- Phoenix Deployment Guide: See `CLAUDE.md` in project root
- Contract Documentation: See individual contract repos (phlimbo, phUSD-stable-minter)
