# Fix: BalancerPooler Vault Unlock Callback Encoding

## Problem

The `BalancerPooler.dispatch()` function fails on mainnet because of how the Balancer V3 vault's `unlock` function works.

The Balancer V3 vault's `unlock(bytes calldata data)` does a **raw low-level call** back to the caller:

```solidity
// Inside Balancer V3 Vault:
(bool success, bytes memory result) = msg.sender.call(data);
```

It does NOT wrap the callback in `IUnlockCallback.unlockCallback(data)`. The raw `data` bytes are sent directly as calldata to `msg.sender`.

The current `dispatch` function encodes:

```solidity
bytes memory data = abi.encode(amount, minBptAmountOut);
IBalancerVault(_vault).unlock(data);
```

This means the vault calls `BalancerPooler.call(abi.encode(amount, minBptAmountOut))`. The first 4 bytes of this ABI-encoded data are `0x00000000` (zero-padded uint256), which is not a valid function selector. The call reverts with `FailedInnerCall()`.

## Fix

In `src/dispatchers/BalancerPooler.sol`, change the `dispatch` function (around line 47-51):

### Before

```solidity
function dispatch(address, uint256 amount, bytes calldata extraData) external override onlyMinter whenNotPaused {
    uint256 minBptAmountOut = extraData.length > 0 ? abi.decode(extraData, (uint256)) : 0;
    bytes memory data = abi.encode(amount, minBptAmountOut);
    IBalancerVault(_vault).unlock(data);
}
```

### After

```solidity
function dispatch(address, uint256 amount, bytes calldata extraData) external override onlyMinter whenNotPaused {
    uint256 minBptAmountOut = extraData.length > 0 ? abi.decode(extraData, (uint256)) : 0;
    bytes memory innerData = abi.encode(amount, minBptAmountOut);
    bytes memory data = abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, innerData);
    IBalancerVault(_vault).unlock(data);
}
```

The data passed to `vault.unlock()` must include the `unlockCallback` function selector (`0x91dd7346`) so that when the vault does `msg.sender.call(data)`, it correctly routes to the `unlockCallback(bytes)` function on the BalancerPooler.

## Files Changed

- `src/dispatchers/BalancerPooler.sol` — `dispatch` function only. No other files need changes.

## Verification

The `unlockCallback` function itself is correct and does not need changes. The only issue is that `dispatch` was not including the function selector in the data sent to `vault.unlock()`.

The fix has been verified on a mainnet fork test — after the change, the full flow (NFTMinter.mint → BalancerPooler.dispatch → vault.unlock → unlockCallback → addLiquidity → settle) succeeds and BPT tokens are correctly minted.

## Impact

This is a bug fix with no interface changes. The `BalancerPooler` contract must be redeployed on mainnet since the deployed version has the bug baked into its bytecode. After redeployment:
1. The old BalancerPooler dispatcher (index 4 on mainnet NFTMinter) will be disabled
2. The new BalancerPooler will be registered as a new dispatcher
3. The new dispatcher will be configured with the same price and growth parameters
