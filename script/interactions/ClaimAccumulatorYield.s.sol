// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";

/**
 * @title ClaimAccumulatorYield
 * @notice Script to claim yield from StableYieldAccumulator
 * @dev Demonstrates the full claim flow:
 *      1. User pays USDC at a discount (e.g., 98 USDC for 100 USD worth of yield)
 *      2. User receives yield tokens (USDT + DAI) from strategies
 *      3. USDC payment goes to Phlimbo for staker rewards
 */
contract ClaimAccumulatorYield is Script {
    using AddressLoader for *;

    function run() external {
        address accumulator = AddressLoader.getAccumulator();
        address usdc = AddressLoader.getUSDC();
        address usdt = AddressLoader.getUSDT();
        address usds = AddressLoader.getUSDS();
        address phlimbo = AddressLoader.getPhlimbo();
        address user = AddressLoader.getDefaultUser();
        uint256 userKey = AddressLoader.getDefaultPrivateKey();

        console.log("\n=== Claiming Yield from StableYieldAccumulator ===");
        console.log("User:", user);

        StableYieldAccumulator acc = StableYieldAccumulator(accumulator);

        // Check discount rate and payment required
        console.log("Discount rate (bps):", acc.getDiscountRate());

        uint256 paymentRequired = acc.calculateClaimAmount();
        console.log("USDC payment required:", paymentRequired);

        if (paymentRequired == 0) {
            console.log("No yield available to claim!");
            return;
        }

        // Log balances before
        console.log("\n--- Balances Before ---");
        _logBalances(user, phlimbo, usdc, usdt, usds);

        vm.startBroadcast(userKey);

        // Approve and claim
        IERC20(usdc).approve(accumulator, paymentRequired);
        acc.claim();
        console.log("\nClaim executed!");

        vm.stopBroadcast();

        // Log balances after
        console.log("\n--- Balances After ---");
        _logBalances(user, phlimbo, usdc, usdt, usds);

        console.log("\n=== Claim Complete ===\n");
    }

    function _logBalances(
        address user,
        address phlimbo,
        address usdc,
        address usdt,
        address usds
    ) internal view {
        console.log("User USDC:", IERC20(usdc).balanceOf(user));
        console.log("User USDT:", IERC20(usdt).balanceOf(user));
        console.log("User USDS:", IERC20(usds).balanceOf(user));
        console.log("Phlimbo USDC:", IERC20(usdc).balanceOf(phlimbo));
    }
}
