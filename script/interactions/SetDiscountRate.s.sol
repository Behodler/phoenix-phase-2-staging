// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockYieldStrategy.sol";

/**
 * @title SetDiscountRate
 * @notice Script to set the yield rate on MockYieldStrategy
 * @dev Admin-only operation to configure simulated yield generation
 */
contract SetDiscountRate is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address yieldStrategy = AddressLoader.getYieldStrategy();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // New yield rate in basis points (1000 = 10% APY)
        uint256 newYieldRate = 1000;

        console.log("\n=== Setting Yield Rate ===");
        console.log("Yield strategy:", yieldStrategy);

        // Get current rate
        uint256 oldRate = MockYieldStrategy(yieldStrategy).yieldRateBps();
        console.log("Old yield rate (bps):", oldRate);
        console.log("Old yield rate (%): ", oldRate / 100);
        console.log("New yield rate (bps):", newYieldRate);
        console.log("New yield rate (%): ", newYieldRate / 100);

        vm.startBroadcast(deployerKey);

        // Set new yield rate
        MockYieldStrategy(yieldStrategy).setYieldRate(newYieldRate);
        console.log("Yield rate updated");

        vm.stopBroadcast();

        // Verify update
        uint256 currentRate = MockYieldStrategy(yieldStrategy).yieldRateBps();
        console.log("Current yield rate (bps):", currentRate);
        console.log("Current yield rate (%): ", currentRate / 100);

        console.log("=== Rate Update Complete ===\n");
    }
}
