// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title ViewMintQuote
 * @notice Script to preview how much phUSD will be minted for a given stablecoin amount
 * @dev Query-only script showing mint preview calculations
 */
contract ViewMintQuote is Script {
    using AddressLoader for *;

    function run() external view {
        // Load addresses
        address minter = AddressLoader.getMinter();
        address rewardToken = AddressLoader.getRewardToken();

        // Test amounts (in USDC with 6 decimals)
        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 10 * 10**6;    // 10 USDC
        testAmounts[1] = 100 * 10**6;   // 100 USDC
        testAmounts[2] = 1000 * 10**6;  // 1,000 USDC
        testAmounts[3] = 10000 * 10**6; // 10,000 USDC

        console.log("\n=== phUSD Mint Quote ===");
        console.log("Stablecoin:", rewardToken);

        // Get stablecoin configuration
        (address yieldStrategy, uint256 exchangeRate, uint8 decimals, bool enabled) =
            PhusdStableMinter(minter).stablecoinConfigs(rewardToken);

        console.log("Yield strategy:", yieldStrategy);
        console.log("Exchange rate:", exchangeRate);
        console.log("Decimals:", uint256(decimals));
        console.log("Enabled:", enabled ? "YES" : "NO");

        console.log("\n--- Mint Quotes ---");
        for (uint256 i = 0; i < testAmounts.length; i++) {
            uint256 stableAmount = testAmounts[i];

            // Calculate phUSD amount using the same formula as the contract
            // phUSDAmount = (inputAmount * exchangeRate * 10^(18 - inputDecimals)) / 1e18
            uint256 phUSDAmount = (stableAmount * exchangeRate * (10**(18 - decimals))) / 1e18;

            console.log("Input (stablecoin):", stableAmount / 10**decimals);
            console.log("Output (phUSD):", phUSDAmount / 1e18);
            console.log("---");
        }

        console.log("========================\n");
    }
}
