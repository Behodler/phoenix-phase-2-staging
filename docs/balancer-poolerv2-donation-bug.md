# BalancerPoolerV2 donation phase: missing `vault.sendTo` (story-047)

## Summary

`BalancerPoolerV2.unlockCallback` calls `IERC4626(waUsdc).redeem(...)` against `address(this)` immediately after a Balancer V3 swap, without first instructing the vault to release the swapped tokens. The vault credits the dispatcher in its internal ledger but does **not** transfer the output ERC20 to the dispatcher's balance — that requires an explicit `vault.sendTo(token, recipient, amount)` call. Without it, the dispatcher's real `balanceOf(waUsdc)` stays at zero, and OpenZeppelin's ERC4626 implementation reverts with `ERC4626ExceededMaxRedeem(pooler, sharesRequested, 0)` because `maxRedeem == balanceOf == 0`.

Net effect: any `pool(...)` call with `batchDonationSize > 0`, `batchMinter != address(0)`, and the swap config populated reverts. The LP-add phase is unaffected (it uses `addLiquidity({to: address(this), …})`, which has an explicit recipient parameter).

## Where the bug lives

`lib/yield-claim-nft/src/V2/dispatchers/BalancerPoolerV2.sol`, inside `unlockCallback`, around the donation block (~lines 214–238):

```solidity
IERC20(_sUSDS).safeTransfer(_vault, donationSUSDS);
VaultSwapParams memory swapParams = VaultSwapParams({
    kind: SwapKind.EXACT_IN,
    pool: swapPool,
    tokenIn: IERC20(_sUSDS),
    tokenOut: IERC20(waUsdc),
    amountGivenRaw: donationSUSDS,
    limitRaw: 0,
    userData: ""
});
(, , uint256 waUsdcReceived) = IBalancerVault(_vault).swap(swapParams);
IBalancerVault(_vault).settle(IERC20(_sUSDS), donationSUSDS);

// ❌ Missing: vault.sendTo(IERC20(waUsdc), address(this), waUsdcReceived);

uint256 usdcReceived =
    IERC4626(waUsdc).redeem(waUsdcReceived, address(this), address(this));
```

## Why the test suite didn't catch it

The Balancer V3 vault mock used in `lib/yield-claim-nft/test/V2/BalancerPoolerV2.t.sol` directly mints the swap output to `msg.sender`:

```solidity
// test mock — NOT how the real V3 vault behaves
function swap(VaultSwapParams memory params) external returns (…) {
    …
    MockERC4626Wrapper(address(params.tokenOut)).mintShares(msg.sender, amountOutRaw);
}
```

This bypasses the production accounting model. Unit tests pass; the real vault leaves the output as a credit that must be claimed via `sendTo`.

## Recommended fix

### Source change

Insert the missing `sendTo` between `settle` and `redeem`:

```diff
 (, , uint256 waUsdcReceived) = IBalancerVault(_vault).swap(swapParams);
 IBalancerVault(_vault).settle(IERC20(_sUSDS), donationSUSDS);
+IBalancerVault(_vault).sendTo(IERC20(waUsdc), address(this), waUsdcReceived);

 uint256 usdcReceived =
     IERC4626(waUsdc).redeem(waUsdcReceived, address(this), address(this));
```

The `IBalancerVault` interface in `lib/yield-claim-nft/src/interfaces/balancer/IBalancerVault.sol` already declares `sendTo(IERC20, address, uint256)` — no interface change needed.

### Regression test

Replace (or supplement) the mock-vault swap path with a fork-mode test that exercises the real Balancer V3 vault and swap pool on mainnet, e.g. `test/V2/BalancerPoolerV2DonationFork.t.sol`. The test should:

1. `vm.createSelectFork($RPC_MAINNET)` at a pinned recent block.
2. Authorize the test contract as a pooler and seed it with sUSDS.
3. Configure the donation phase (`batchDonationSize > 0`, `batchMinter`, `swapPool`, `waUsdc`, `usdc` set to live addresses).
4. Call `pool(0, 0)`.
5. Assert that USDC arrives at `batchMinter` and the BPT add succeeds.

A unit test against the mock will not catch the regression; only a real-vault fork test will.

## Migration path

Because `BalancerPoolerV2` is immutable and currently holds sUSDS, BPT positions, and a dispatcher slot on `NFTMinterV2`, the long-term fix is a fresh deploy mirroring story-047's pattern:

1. Update `BalancerPoolerV2.sol` with the `sendTo` line plus a fork integration test.
2. Deploy the patched pooler.
3. `replaceDispatcher(6, newPooler)` on `NFTMinterV2`.
4. `setMinter(NFTMinterV2)` on the new pooler (the wiring story-047 also missed).
5. `setAuthorizedPooler(operator, true)` on the new pooler.
6. Migrate the existing BPT position and any residual sUSDS from the broken pooler via `withdrawBPT` / `rescueERC20`.
7. Update `nftsV2.BalancerPooler` in `server/deployments/mainnet-addresses.ts`.
8. Regenerate hooks and ABIs as needed.

Treat the broken pooler the same way story-047 treated its predecessor: leave the dispatcher disabled, point users at the new index, and recover stuck funds via the owner escape hatches.

## Interim workaround

Until the redeploy:

- `setBatchDonationSize(0)` (or `setBatchMinter(address(0))`) on the broken pooler so `pool()` skips the donation phase. The LP add still works.
- Top up `BatchNFTMinter` USDC manually (rescue sUSDS, swap it owner-side, transfer USDC to the batch minter) — see `script/RescuePoolAndDonateUSDC.s.sol`.
