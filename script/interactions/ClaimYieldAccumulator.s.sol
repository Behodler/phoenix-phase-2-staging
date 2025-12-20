// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockRewardToken.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title ClaimYieldAccumulator
 * @notice Script to trigger Phlimbo to collect rewards from yield accumulator
 * @dev This is typically called by an automated process, but can be manually triggered
 */
contract ClaimYieldAccumulator is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address rewardToken = AddressLoader.getRewardToken();
        address phlimbo = AddressLoader.getPhlimbo();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        console.log("\n=== Claiming from Yield Accumulator ===");

        // Check Phlimbo's reward token balance before
        uint256 balanceBefore = MockRewardToken(rewardToken).balanceOf(phlimbo);
        console.log("Phlimbo stablecoin balance before:", balanceBefore);

        vm.startBroadcast(deployerKey);

        // Collect reward from yield accumulator
        // Note: In the mock setup, yieldAccumulator is the MockYieldStrategy
        // This triggers the collectReward function which withdraws accumulated yield
        // Amount to collect (100 USDC = 100 * 10^6)
        uint256 amountToCollect = 100 * 10**6;
        PhlimboEA(phlimbo).collectReward(amountToCollect);
        console.log("Collected rewards from yield accumulator");

        vm.stopBroadcast();

        // Check balance after
        uint256 balanceAfter = MockRewardToken(rewardToken).balanceOf(phlimbo);
        console.log("Phlimbo stablecoin balance after:", balanceAfter);
        console.log("Rewards collected:", balanceAfter - balanceBefore);

        console.log("=== Collection Complete ===\n");
    }
}
