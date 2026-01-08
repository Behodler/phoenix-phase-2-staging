// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockYieldStrategy.sol";

/**
 * @title SimulateYield
 * @notice Script to manually add simulated yield to both yield strategies (Anvil only)
 * @dev Testing helper to simulate yield generation without waiting
 *      Adds yield to both USDT and DAI strategies for testing the accumulator claim flow
 */
contract SimulateYield is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address yieldStrategyUSDT = AddressLoader.getYieldStrategyUSDT();
        address yieldStrategyUSDS = AddressLoader.getYieldStrategyUSDS();
        address usdt = AddressLoader.getUSDT();
        address usds = AddressLoader.getUSDS();
        address minter = AddressLoader.getMinter();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // Yield amounts to add
        uint256 usdtYield = 500 * 10**6;    // 500 USDT (6 decimals)
        uint256 usdsYield = 500 * 10**18;    // 500 USDS (18 decimals)

        console.log("\n=== Simulating Yield Generation ===");

        // ====== USDT Strategy ======
        console.log("\n--- USDT Strategy ---");
        console.log("Strategy:", yieldStrategyUSDT);
        console.log("Yield to add:", usdtYield);

        uint256 usdtTotalBefore = MockYieldStrategy(yieldStrategyUSDT).totalBalanceOf(usdt, minter);
        uint256 usdtPrincipalBefore = MockYieldStrategy(yieldStrategyUSDT).principalOf(usdt, minter);
        console.log("Total balance before:", usdtTotalBefore);
        console.log("Principal before:", usdtPrincipalBefore);
        console.log("Yield before:", usdtTotalBefore - usdtPrincipalBefore);

        // ====== USDS Strategy ======
        console.log("\n--- USDS Strategy ---");
        console.log("Strategy:", yieldStrategyUSDS);
        console.log("Yield to add:", usdsYield);

        uint256 usdsTotalBefore = MockYieldStrategy(yieldStrategyUSDS).totalBalanceOf(usds, minter);
        uint256 usdsPrincipalBefore = MockYieldStrategy(yieldStrategyUSDS).principalOf(usds, minter);
        console.log("Total balance before:", usdsTotalBefore);
        console.log("Principal before:", usdsPrincipalBefore);
        console.log("Yield before:", usdsTotalBefore - usdsPrincipalBefore);

        vm.startBroadcast(deployerKey);

        // Add simulated yield to both strategies
        MockYieldStrategy(yieldStrategyUSDT).addYield(usdt, minter, usdtYield);
        console.log("\nUSDT yield added");

        MockYieldStrategy(yieldStrategyUSDS).addYield(usds, minter, usdsYield);
        console.log("USDS yield added");

        vm.stopBroadcast();

        // ====== Results ======
        console.log("\n--- Results ---");

        uint256 usdtTotalAfter = MockYieldStrategy(yieldStrategyUSDT).totalBalanceOf(usdt, minter);
        uint256 usdtYieldAfter = usdtTotalAfter - usdtPrincipalBefore;
        console.log("USDT yield after:", usdtYieldAfter);

        uint256 usdsTotalAfter = MockYieldStrategy(yieldStrategyUSDS).totalBalanceOf(usds, minter);
        uint256 usdsYieldAfter = usdsTotalAfter - usdsPrincipalBefore;
        console.log("USDS yield after:", usdsYieldAfter);

        // Total in USD equivalent (convert USDS to 6 decimals for display)
        uint256 totalYieldUsd = usdtYieldAfter + (usdsYieldAfter / 1e12);
        console.log("\nTotal yield (USD equiv, 6 decimals):", totalYieldUsd);

        console.log("\n=== Yield Simulation Complete ===\n");
    }
}
