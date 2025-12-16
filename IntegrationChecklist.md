# Phoenix Phase 2 Integration Checklist

This document serves as a chain-agnostic deployment guide for agents deploying the Phoenix Phase 2 protocol contracts. It contains only English instructions in the correct order of operations, with no code sequences. Agents reading this document should make strategic decisions about using mocks vs real contracts based on the target chain.

## Purpose

The Phoenix Phase 2 protocol consists of three core contracts that work together to enable phUSD staking and yield distribution:

1. **PhusdStableMinter** - Accepts stablecoin deposits, routes them to yield strategies, and mints phUSD
2. **StableYieldAccumulator** - Consolidates yield from multiple strategies into a single reward token for Phlimbo
3. **PhlimboEA** - Staking yield farm where users stake phUSD and earn rewards (phUSD emissions + stable token yield)

This document provides the deployment sequence, configuration steps, and validation procedures to ensure correct contract integration.

---

## Core Protocol Contracts

These contracts must always be deployed fresh for each network. They form the backbone of the Phoenix Phase 2 system.

### 1. PhlimboEA (Phlimbo)

**Purpose**: EMA-smoothed staking yield farm where users stake phUSD tokens and earn two types of rewards - newly minted phUSD (based on desired APY) and external stablecoin rewards received from yield strategies via StableYieldAccumulator.

**Constructor Parameters**:
- `_phUSD` - Address of the phUSD token (must implement IFlax interface with mint capability)
- `_rewardToken` - Address of the stablecoin used for external rewards (e.g., USDC, DOLA)
- `_yieldAccumulator` - Address of the StableYieldAccumulator contract
- `_alpha` - EMA smoothing parameter (scaled by 1e18, e.g., 0.1e18 = 10% weight on new rate)

**Post-Deployment Configuration Functions**:
- `setPauser(address)` - Sets the address authorized to pause the contract
- `setDesiredAPY(uint256)` - Sets the phUSD emission APY in basis points (two-step: preview then commit)
- `setYieldAccumulator(address)` - Updates the yield accumulator address if needed
- `setAlpha(uint256)` - Updates the EMA smoothing parameter

**Minting Rights Required**: Phlimbo must be authorized as a minter on phUSD to mint reward emissions.

---

### 2. PhusdStableMinter

**Purpose**: Manages phUSD minting from stablecoin deposits. Users deposit supported stablecoins, which are routed to yield strategies, and receive phUSD in return.

**Constructor Parameters**:
- `_phUSD` - Address of the phUSD token (immutable after deployment)

**Post-Deployment Configuration Functions**:
- `registerStablecoin(address stablecoin, address yieldStrategy, uint256 exchangeRate, uint8 decimals)` - Registers a supported stablecoin with its corresponding yield strategy and exchange rate
- `updateExchangeRate(address stablecoin, uint256 newRate)` - Updates exchange rate for a registered stablecoin
- `approveYS(address token, address yieldStrategy)` - Grants max token approval to a yield strategy (required before deposits work)

**Minting Rights Required**: PhusdStableMinter must be authorized as a minter on phUSD to mint tokens for depositors.

---

### 3. StableYieldAccumulator

**Purpose**: Consolidates yield from multiple yield strategies into a single reward token (e.g., USDC) for simplified distribution to Phlimbo. External claimers swap their reward tokens for accumulated yield, and those reward tokens are sent to Phlimbo.

**Constructor Parameters**: None (owner is set to deployer)

**Post-Deployment Configuration Functions**:
- `addYieldStrategy(address strategy, address token)` - Registers a yield strategy and its underlying token
- `removeYieldStrategy(address strategy)` - Removes a yield strategy from the registry
- `setTokenConfig(address token, uint8 decimals, uint256 normalizedExchangeRate)` - Configures token decimals and exchange rate
- `setRewardToken(address)` - Sets the single stablecoin used for consolidated rewards
- `setPhlimbo(address)` - Sets the Phlimbo address where claimed reward tokens are transferred
- `setMinter(address)` - Sets the minter contract address (used to query yield from strategies)
- `approvePhlimbo(uint256 amount)` - Approves Phlimbo to pull reward tokens via collectReward
- `setDiscountRate(uint256 rate)` - Sets the discount rate for claimers in basis points
- `setPauser(address)` - Sets the address authorized to pause the contract
- `pauseToken(address)` / `unpauseToken(address)` - Pause/unpause individual tokens

---

## Supportive Contracts

These secondary contracts may already exist on the target chain or may need to be deployed as mocks depending on the deployment context.

### phUSD Token (IFlax implementation)

**Purpose**: ERC20 token with permissioned minting. Must implement the IFlax interface which includes:
- `mint(address recipient, uint256 amount)` - Mints tokens to recipient
- `burn(address holder, uint256 amount)` - Burns tokens from holder
- `authorizedMinters(address)` - Returns minter authorization info

**Deployment Decision**:
- On mainnet: Use the existing deployed phUSD token
- On testnets/local: Deploy a mock IFlax token with owner-controlled minting rights

### Pauser

**Purpose**: Global pause mechanism for emergency stops. Each core contract has its own internal pause functionality via a designated pauser address.

**Deployment Decision**:
- On mainnet: Deploy a Pauser contract with appropriate governance controls
- On testnets/local: Can use a simple EOA as pauser or deploy a mock Pauser

### Yield Strategies (IYieldStrategy implementations)

**Purpose**: External yield source adapters that hold stablecoin deposits and earn yield. Must implement:
- `deposit(address token, uint256 amount, address recipient)` - Deposits tokens
- `withdraw(address token, uint256 amount, address recipient)` - Withdraws tokens
- `withdrawFrom(address token, address holder, uint256 amount, address recipient)` - Withdraws from specific holder
- `totalBalanceOf(address token, address account)` - Returns total balance including yield
- `principalOf(address token, address account)` - Returns deposited principal

**Deployment Decision**:
- On mainnet: Use real yield strategies (e.g., AutoDolaYieldStrategy for Inverse Finance)
- On testnets/local: Deploy mock yield strategies with simulated yield generation

### Reward Token (e.g., USDC)

**Purpose**: The consolidated reward stablecoin that claimers pay and Phlimbo distributes.

**Deployment Decision**:
- On mainnet: Use real USDC or chosen stablecoin
- On testnets/local: Deploy a mock ERC20 for testing

---

## Deployment Sequence

Follow these steps in order to ensure correct contract deployment and configuration.

### Phase 1: Pre-Deployment Requirements

Before deploying core contracts, ensure the following exist:

1. **phUSD Token** - The phUSD token contract must be deployed and accessible. If on a test network, deploy a mock IFlax implementation first.

2. **Reward Token** - The stablecoin to be used for rewards (e.g., USDC) must be available. On test networks, deploy a mock ERC20.

3. **Yield Strategies** - At least one yield strategy should be ready (deployed or mock). On test networks, deploy mock yield strategies with simulated yield capabilities.

4. **Depositable Stablecoins** - The stablecoins that users will deposit (e.g., DOLA, USDC, USDT) must be available.

### Phase 2: Core Contract Deployment

Deploy the three core contracts in this specific order due to constructor dependencies:

1. **Deploy PhusdStableMinter**
   - Requires: phUSD address
   - Deploy with phUSD address as constructor parameter
   - Record the deployed address for later configuration

2. **Deploy StableYieldAccumulator**
   - Requires: Nothing (no constructor params)
   - Deploy the contract
   - Record the deployed address for later configuration

3. **Deploy PhlimboEA (Phlimbo)**
   - Requires: phUSD address, rewardToken address, StableYieldAccumulator address, alpha value
   - Deploy with all four constructor parameters
   - Suggested alpha: 0.1e18 (10% weight on new rate for EMA smoothing)
   - Record the deployed address for later configuration

### Phase 3: Token Authorization

Grant minting rights on phUSD to the contracts that need to mint:

1. **Authorize PhlimboEA as phUSD minter**
   - Call phUSD's minter authorization function
   - Phlimbo needs this to mint phUSD reward emissions

2. **Authorize PhusdStableMinter as phUSD minter**
   - Call phUSD's minter authorization function
   - PhusdStableMinter needs this to mint phUSD for depositors

### Phase 4: StableYieldAccumulator Configuration

Configure the yield accumulator with all necessary references:

1. **Set Reward Token**
   - Call `setRewardToken(rewardTokenAddress)`
   - This is the stablecoin that claimers pay (e.g., USDC)

2. **Set Phlimbo Address**
   - Call `setPhlimbo(phlimboAddress)`
   - This is where claimed reward tokens are transferred

3. **Set Minter Address**
   - Call `setMinter(phusdStableMinterAddress)`
   - Used to query yield from strategies for the minter's deposits

4. **Register Yield Strategies**
   - For each yield strategy, call `addYieldStrategy(strategyAddress, underlyingTokenAddress)`
   - Example: addYieldStrategy(dolaYieldStrategy, DOLA)

5. **Configure Token Settings**
   - For each token used by yield strategies, call `setTokenConfig(tokenAddress, decimals, normalizedExchangeRate)`
   - Also configure the reward token
   - Example: setTokenConfig(USDC, 6, 1e18) for USDC at 1:1 rate
   - Example: setTokenConfig(DOLA, 18, 1e18) for DOLA at 1:1 rate

6. **Set Discount Rate**
   - Call `setDiscountRate(rateBps)` with desired discount in basis points
   - Example: setDiscountRate(200) for 2% discount

7. **Approve Phlimbo**
   - Call `approvePhlimbo(amount)` to allow Phlimbo to pull reward tokens
   - Use type(uint256).max for unlimited approval

8. **Set Pauser** (optional)
   - Call `setPauser(pauserAddress)` if using a dedicated pauser

### Phase 5: PhusdStableMinter Configuration

Configure the minter with supported stablecoins and yield strategies:

1. **Approve Yield Strategies**
   - For each stablecoin/strategy pair, call `approveYS(tokenAddress, yieldStrategyAddress)`
   - This grants the minter approval to deposit into yield strategies
   - Example: approveYS(DOLA, dolaYieldStrategy)

2. **Register Stablecoins**
   - For each supported stablecoin, call `registerStablecoin(stablecoinAddress, yieldStrategyAddress, exchangeRate, decimals)`
   - Example: registerStablecoin(DOLA, dolaYieldStrategy, 1e18, 18) for DOLA at 1:1 rate

### Phase 6: Phlimbo Configuration

Configure the yield farm settings:

1. **Set Desired APY**
   - Call `setDesiredAPY(bps)` twice (two-step process: preview then commit)
   - First call emits IntendedSetAPY event (preview)
   - Second call with same value within 100 blocks commits the change
   - Example: setDesiredAPY(500) for 5% APY

2. **Set Pauser** (optional)
   - Call `setPauser(pauserAddress)` if using a dedicated pauser

---

## Configuration Dependencies

This matrix shows which contracts need references to which other contracts.

| Contract | Needs Reference To | Configuration Function |
|----------|-------------------|----------------------|
| PhlimboEA | phUSD | Constructor parameter |
| PhlimboEA | Reward Token | Constructor parameter |
| PhlimboEA | StableYieldAccumulator | Constructor parameter |
| PhusdStableMinter | phUSD | Constructor parameter |
| PhusdStableMinter | Yield Strategies | registerStablecoin() |
| StableYieldAccumulator | Reward Token | setRewardToken() |
| StableYieldAccumulator | PhlimboEA | setPhlimbo() |
| StableYieldAccumulator | PhusdStableMinter | setMinter() |
| StableYieldAccumulator | Yield Strategies | addYieldStrategy() |

### Circular Reference Resolution

The deployment order resolves the following circular reference:
- Phlimbo needs StableYieldAccumulator address at construction
- StableYieldAccumulator needs Phlimbo address for configuration

Solution: Deploy StableYieldAccumulator first, then Phlimbo, then call setPhlimbo() on StableYieldAccumulator.

---

## Validation Steps

After deployment and configuration, verify the setup is correct.

### 1. Verify Contract Ownership

- Check that PhusdStableMinter.owner() returns the expected owner address
- Check that StableYieldAccumulator.owner() returns the expected owner address
- Check that PhlimboEA.owner() returns the expected owner address

### 2. Verify phUSD Minting Rights

- Call phUSD.authorizedMinters(phlimboAddress) and verify canMint is true
- Call phUSD.authorizedMinters(phusdStableMinterAddress) and verify canMint is true

### 3. Verify StableYieldAccumulator Configuration

- Call rewardToken() and verify it returns the correct address
- Call phlimbo() and verify it returns the Phlimbo address
- Call minterAddress() and verify it returns the PhusdStableMinter address
- Call getYieldStrategies() and verify all expected strategies are registered
- For each token, call getTokenConfig() and verify decimals and exchange rate
- Call getDiscountRate() and verify the expected discount rate

### 4. Verify PhusdStableMinter Configuration

- Call phUSD() and verify it returns the phUSD address
- For each supported stablecoin, call getStablecoinConfig() and verify:
  - yieldStrategy is the correct strategy address
  - exchangeRate is correctly set
  - decimals match the token

### 5. Verify Phlimbo Configuration

- Call phUSD() and verify it returns the phUSD address
- Call rewardToken() and verify it returns the reward token address
- Call yieldAccumulator() and verify it returns the StableYieldAccumulator address
- Call desiredAPYBps() and verify the expected APY
- Call alpha() and verify the EMA smoothing parameter

### 6. Functional Tests

After verification, perform end-to-end functional tests:

1. **Test PhusdStableMinter Flow**:
   - Approve minter to spend stablecoin
   - Call mint() with a small amount
   - Verify phUSD balance increased
   - Verify yield strategy received the deposit

2. **Test Phlimbo Staking**:
   - Approve Phlimbo to spend phUSD
   - Call stake() with phUSD
   - Verify totalStaked increased
   - Verify user position is recorded

3. **Test Yield Accumulator Claim** (requires accumulated yield):
   - Verify calculateClaimAmount() returns expected value
   - If yield exists, verify claim() transfers correctly

---

## Important Notes

### Token Naming

The protocol uses **phUSD** (Phoenix USD) as the token name. Do NOT use pxUSD - that is a different token from another company that exists on mainnet.

### Exchange Rates

- Exchange rates use 18 decimal precision (1e18 = 1:1 ratio)
- Adjust exchange rates for stablecoins that depeg from $1

### Decimal Handling

- The system normalizes all amounts to 18 decimals internally
- Token configs must accurately specify each token's decimal places
- USDC/USDT use 6 decimals, DOLA/DAI use 18 decimals

### Two-Step APY Setting

Phlimbo uses a two-step process for setting APY:
1. First setDesiredAPY() call emits IntendedSetAPY event (preview)
2. Second call with same value within 100 blocks commits the change
3. This provides a safety window to catch erroneous settings

### Pause Mechanism

Each contract can be paused independently:
- Only the designated pauser can pause
- Both owner AND pauser can unpause (Behodler3 pattern for redundancy)
- Paused state halts state-changing operations but allows view functions
