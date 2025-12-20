// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title UpdateExchangeRate
 * @notice Script to update the exchange rate for a registered stablecoin
 * @dev Admin-only operation to adjust minting ratios
 */
contract UpdateExchangeRate is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address minter = AddressLoader.getMinter();
        address rewardToken = AddressLoader.getRewardToken();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // New exchange rate (0.95:1 = 95e16, meaning 1 stablecoin -> 0.95 phUSD)
        uint256 newExchangeRate = 95e16;

        console.log("\n=== Updating Exchange Rate ===");
        console.log("Stablecoin:", rewardToken);

        // Get current rate
        (, uint256 oldRate,,) = PhusdStableMinter(minter).stablecoinConfigs(rewardToken);
        console.log("Old exchange rate:", oldRate);
        console.log("New exchange rate:", newExchangeRate);

        vm.startBroadcast(deployerKey);

        // Update exchange rate
        PhusdStableMinter(minter).updateExchangeRate(rewardToken, newExchangeRate);
        console.log("Exchange rate updated");

        vm.stopBroadcast();

        // Verify update
        (, uint256 currentRate,,) = PhusdStableMinter(minter).stablecoinConfigs(rewardToken);
        console.log("Current exchange rate:", currentRate);

        // Show impact
        console.log("\n--- Impact Example ---");
        uint256 stableInput = 100 * 10**6; // 100 USDC
        uint256 phUSDOld = (stableInput * oldRate * 1e12) / 1e18; // 6 decimals -> 18 decimals
        uint256 phUSDNew = (stableInput * currentRate * 1e12) / 1e18;

        console.log("100 stablecoin with old rate ->", phUSDOld / 1e18, "phUSD");
        console.log("100 stablecoin with new rate ->", phUSDNew / 1e18, "phUSD");

        console.log("=== Update Complete ===\n");
    }
}
