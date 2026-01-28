# UniswapV4 Stable Yield Strategy Plan

## Overview

Design an oracle-free yield strategy that encapsulates a Uniswap V4 stable pool (e.g., USDT-USDC) for the Phoenix protocol. The strategy accepts a single stablecoin, provides liquidity to a V4 stable pool, and distributes collected fees as yield.

## Context

Currently on mainnet:
- StableMinter accepts 1 DOLA → mints 1 phUSD
- DOLA deposited into AutoDolaYieldStrategy
- Yield distributed via StableYieldAccumulator → Phlimbo

This plan explores an alternative yield source using Uniswap V4 LP positions.

## Design Constraints

- **Oracle-free**: Relies on stability assumptions (stablecoins maintain peg)
- **No user withdrawals**: Principal only exits via admin migration
- **Single-token interface**: Accepts USDC, returns yield in USDC
- **Compatible with existing yield accumulator pattern**

## Architecture

### Flow

```
User deposits USDC to Minter
         │
         ▼
┌─────────────────────────────────┐
│   UniV4StableYieldStrategy      │
│                                 │
│  1. Receive USDC                │
│  2. Swap 50% USDC → USDT        │
│  3. Add liquidity to V4 pool    │
│  4. Track total deposited       │
└─────────────────────────────────┘
         │
         ▼ (periodic)
┌─────────────────────────────────┐
│   Yield Collection              │
│                                 │
│  1. Collect fees (USDC + USDT)  │
│  2. Swap USDT fees → USDC       │
│  3. Return single-token yield   │
└─────────────────────────────────┘
         │
         ▼
  StableYieldAccumulator → Phlimbo
```

### Interface Compliance

Must implement `IYieldStrategy`:

```solidity
interface IYieldStrategy {
    function deposit(uint256 amount) external;
    function totalDeposits() external view returns (uint256);
    function principalOf(address user) external view returns (uint256);
    function collectYield() external returns (uint256);
}
```

### Contract Structure

```solidity
contract UniV4StableYieldStrategy is IYieldStrategy {
    // Tokens
    IERC20 public immutable depositToken;    // USDC
    IERC20 public immutable pairedToken;     // USDT

    // V4 Pool
    IPoolManager public immutable poolManager;
    PoolId public immutable poolId;

    // Position tracking
    uint128 public liquidityPosition;
    uint256 public totalDeposited;           // Total USDC received

    // Configuration
    uint24 public slippageTolerance;         // e.g., 10 = 0.1%
    int24 public tickLower;                  // Fixed tick range
    int24 public tickUpper;                  // Fixed tick range

    // Access control
    address public minter;
    address public owner;
}
```

## Key Functions

### deposit()

```solidity
function deposit(uint256 usdcAmount) external onlyMinter {
    // 1. Transfer USDC from minter
    depositToken.transferFrom(msg.sender, address(this), usdcAmount);

    // 2. Swap half to USDT with slippage check
    uint256 halfAmount = usdcAmount / 2;
    uint256 usdtOut = _swapWithSlippageCheck(
        depositToken,
        pairedToken,
        halfAmount,
        slippageTolerance
    );

    // 3. Add liquidity to V4 position
    uint128 liquidityAdded = _addLiquidity(halfAmount, usdtOut);
    liquidityPosition += liquidityAdded;

    // 4. Track deposits
    totalDeposited += usdcAmount;

    emit Deposited(usdcAmount, liquidityAdded);
}
```

### collectYield()

```solidity
function collectYield() external returns (uint256 yieldInUSDC) {
    // 1. Collect accumulated fees from V4 position
    (uint256 usdcFees, uint256 usdtFees) = _collectFees();

    // 2. Convert USDT fees to USDC
    uint256 convertedUSDT = 0;
    if (usdtFees > 0) {
        convertedUSDT = _swapWithSlippageCheck(
            pairedToken,
            depositToken,
            usdtFees,
            slippageTolerance
        );
    }

    // 3. Return total yield in single token
    yieldInUSDC = usdcFees + convertedUSDT;

    // 4. Transfer to caller (yield accumulator)
    if (yieldInUSDC > 0) {
        depositToken.transfer(msg.sender, yieldInUSDC);
    }

    emit YieldCollected(usdcFees, usdtFees, yieldInUSDC);
}
```

### View Functions

```solidity
function totalDeposits() external view returns (uint256) {
    return totalDeposited;
}

function principalOf(address) external view returns (uint256) {
    // Single-depositor model (minter only)
    // Returns total for migration accounting
    return totalDeposited;
}

function pendingYield() external view returns (uint256 usdcFees, uint256 usdtFees) {
    // Query V4 for uncollected fees (view function)
    return _getPendingFees();
}
```

### Admin Functions

```solidity
function migrate(address newStrategy) external onlyOwner {
    // 1. Remove all liquidity
    (uint256 usdcOut, uint256 usdtOut) = _removeLiquidity(liquidityPosition);

    // 2. Swap USDT to USDC
    uint256 convertedUSDT = _swapWithSlippageCheck(
        pairedToken,
        depositToken,
        usdtOut,
        slippageTolerance
    );

    // 3. Transfer all USDC to new strategy
    uint256 totalUSDC = usdcOut + convertedUSDT;
    depositToken.transfer(newStrategy, totalUSDC);

    // 4. Reset state
    liquidityPosition = 0;

    emit Migrated(newStrategy, totalUSDC);
}

function setSlippageTolerance(uint24 newTolerance) external onlyOwner {
    require(newTolerance <= 100, "Max 1%"); // Safety cap
    slippageTolerance = newTolerance;
}
```

## Stability Assumptions

The oracle-free design relies on these assumptions:

| Assumption | Impact if Violated |
|------------|-------------------|
| USDC maintains $1 peg | Deposit value affected |
| USDT maintains $1 peg | LP position imbalanced |
| USDC ≈ USDT (1:1 ratio) | Swap slippage increases |
| Pool not manipulated | Entry/exit at bad rates |

### Acceptable Because

1. **No user withdrawals** - IL only matters at migration
2. **Stable pairs** - Historical IL on USDC-USDT is minimal
3. **Tight slippage** - Bounds worst-case entry/exit costs
4. **Protocol absorbs risk** - Not passed to individual users

## Risk Analysis

### Low Risk
- **Fee collection**: Clean V4 API, well-tested
- **Slippage on stable swaps**: Bounded by tolerance parameter
- **Position tracking**: Single position, straightforward accounting

### Medium Risk
- **Entry slippage accumulation**: ~0.05-0.1% loss per deposit on half-swap
- **V4 integration complexity**: Newer protocol, less battle-tested than V3
- **Gas costs**: V4 singleton may have different gas profile

### High Risk (Mitigated by Design)
- **Depeg event**: Would cause IL, but only realized at migration
- **Sandwich attacks**: Mitigated by slippage tolerance, reverts if exceeded

## Accounting Model

### What We Track
- `totalDeposited`: Sum of USDC received from minter
- `liquidityPosition`: V4 liquidity units owned
- Fees collected (via events)

### What We Don't Track (By Design)
- Real-time LP position value (would require oracle)
- Unrealized IL (only matters at migration)
- Per-user accounting (single depositor: minter)

### Yield Definition
```
yield = collected_USDC_fees + swap(collected_USDT_fees, USDC)
```

Fees only. No mark-to-market gains/losses reported as yield.

## V4-Specific Considerations

### Position Management
- V4 uses PoolManager singleton (not per-pool contracts)
- Positions identified by (owner, tickLower, tickUpper, salt)
- No NFT tokenization by default (unlike V3)

### Hooks
- Could implement custom hooks for additional logic
- Not required for basic strategy

### Fee Collection
- `collect()` on PoolManager
- Returns both token amounts
- Can be called permissionlessly

## Implementation Phases

### Phase 1: Core Contract
- [ ] Implement UniV4StableYieldStrategy
- [ ] V4 pool interaction (swap, addLiquidity, collect)
- [ ] Slippage protection
- [ ] Basic access control

### Phase 2: Testing
- [ ] Unit tests with mock V4 pool
- [ ] Fork tests against V4 deployment
- [ ] Slippage tolerance edge cases
- [ ] Migration flow tests

### Phase 3: Integration
- [ ] Deploy to testnet with test stable pool
- [ ] Connect to StableYieldAccumulator
- [ ] End-to-end yield flow testing

### Phase 4: Production
- [ ] Audit
- [ ] Mainnet deployment
- [ ] Monitor fee collection
- [ ] Compare yield to autoDola strategy

## Open Questions

1. **Which V4 stable pool?** USDC-USDT most liquid, but need to verify V4 deployment
2. **Tick range selection?** Full range vs concentrated for stables
3. **Fee tier?** V4 allows dynamic fees - which tier for stables?
4. **Minimum deposit size?** To ensure gas-efficient liquidity additions
5. **Collection frequency?** How often to harvest fees?

## Comparison: AutoDola vs UniV4Stable

| Aspect | AutoDolaYieldStrategy | UniV4StableYieldStrategy |
|--------|----------------------|--------------------------|
| Yield source | Lending (Inverse) | LP fees (Uniswap V4) |
| Risk profile | Lending/liquidation risk | IL risk (minimal for stables) |
| Oracle dependency | None (vault tracks) | None (stability assumption) |
| Yield predictability | More stable | Varies with volume |
| Capital efficiency | Single token | Split between two tokens |
| Complexity | Lower | Higher (swaps, LP mgmt) |

## Conclusion

An oracle-free UniswapV4 stable yield strategy is **feasible** given:

1. No user principal withdrawals (only admin migration)
2. Yield defined as collected fees only
3. Tight slippage tolerance on swaps
4. Acceptance of stability assumptions

The architecture maps cleanly to the existing `IYieldStrategy` interface and yield accumulator pattern. Main trade-off is added complexity vs. single-token strategies like autoDola.
