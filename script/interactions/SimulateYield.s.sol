// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockYieldStrategy.sol";
import "../../src/mocks/MockRewardToken.sol";

/**
 * @title SimulateYield
 * @notice Script to manually add simulated yield to yield strategy (Anvil only)
 * @dev Testing helper to simulate yield generation without waiting
 */
contract SimulateYield is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address yieldStrategy = AddressLoader.getYieldStrategy();
        address rewardToken = AddressLoader.getRewardToken();
        address minter = AddressLoader.getMinter();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // Amount of yield to add (1000 USDC = 1000 * 10^6)
        uint256 yieldAmount = 1000 * 10**6;

        console.log("\n=== Simulating Yield Generation ===");
        console.log("Yield strategy:", yieldStrategy);
        console.log("Yield amount to add:", yieldAmount);

        // Get balances before
        uint256 totalBefore = MockYieldStrategy(yieldStrategy).totalBalanceOf(rewardToken, minter);
        uint256 principalBefore = MockYieldStrategy(yieldStrategy).principalOf(rewardToken, minter);
        console.log("Total balance before:", totalBefore);
        console.log("Principal before:", principalBefore);
        console.log("Yield before:", totalBefore - principalBefore);

        vm.startBroadcast(deployerKey);

        // Add simulated yield
        MockYieldStrategy(yieldStrategy).addYield(rewardToken, minter, yieldAmount);
        console.log("Yield added");

        vm.stopBroadcast();

        // Get balances after
        uint256 totalAfter = MockYieldStrategy(yieldStrategy).totalBalanceOf(rewardToken, minter);
        uint256 principalAfter = MockYieldStrategy(yieldStrategy).principalOf(rewardToken, minter);
        console.log("Total balance after:", totalAfter);
        console.log("Principal after:", principalAfter);
        console.log("Yield after:", totalAfter - principalAfter);
        console.log("Yield increase:", (totalAfter - principalAfter) - (totalBefore - principalBefore));

        console.log("=== Yield Simulation Complete ===\n");
    }
}
