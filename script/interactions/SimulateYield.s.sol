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
        address yieldStrategyDAI = AddressLoader.getYieldStrategyDAI();
        address usdt = AddressLoader.getUSDT();
        address dai = AddressLoader.getDAI();
        address minter = AddressLoader.getMinter();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // Yield amounts to add
        uint256 usdtYield = 500 * 10**6;    // 500 USDT (6 decimals)
        uint256 daiYield = 500 * 10**18;    // 500 DAI (18 decimals)

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

        // ====== DAI Strategy ======
        console.log("\n--- DAI Strategy ---");
        console.log("Strategy:", yieldStrategyDAI);
        console.log("Yield to add:", daiYield);

        uint256 daiTotalBefore = MockYieldStrategy(yieldStrategyDAI).totalBalanceOf(dai, minter);
        uint256 daiPrincipalBefore = MockYieldStrategy(yieldStrategyDAI).principalOf(dai, minter);
        console.log("Total balance before:", daiTotalBefore);
        console.log("Principal before:", daiPrincipalBefore);
        console.log("Yield before:", daiTotalBefore - daiPrincipalBefore);

        vm.startBroadcast(deployerKey);

        // Add simulated yield to both strategies
        MockYieldStrategy(yieldStrategyUSDT).addYield(usdt, minter, usdtYield);
        console.log("\nUSDT yield added");

        MockYieldStrategy(yieldStrategyDAI).addYield(dai, minter, daiYield);
        console.log("DAI yield added");

        vm.stopBroadcast();

        // ====== Results ======
        console.log("\n--- Results ---");

        uint256 usdtTotalAfter = MockYieldStrategy(yieldStrategyUSDT).totalBalanceOf(usdt, minter);
        uint256 usdtYieldAfter = usdtTotalAfter - usdtPrincipalBefore;
        console.log("USDT yield after:", usdtYieldAfter);

        uint256 daiTotalAfter = MockYieldStrategy(yieldStrategyDAI).totalBalanceOf(dai, minter);
        uint256 daiYieldAfter = daiTotalAfter - daiPrincipalBefore;
        console.log("DAI yield after:", daiYieldAfter);

        // Total in USD equivalent (convert DAI to 6 decimals for display)
        uint256 totalYieldUsd = usdtYieldAfter + (daiYieldAfter / 1e12);
        console.log("\nTotal yield (USD equiv, 6 decimals):", totalYieldUsd);

        console.log("\n=== Yield Simulation Complete ===\n");
    }
}
