// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockYieldStrategy.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title ViewYieldStrategies
 * @notice Script to view yield strategy balances and configurations
 * @dev Query-only script showing deposits and yield generation
 */
contract ViewYieldStrategies is Script {
    using AddressLoader for *;

    function run() external view {
        // Load addresses
        address yieldStrategy = AddressLoader.getYieldStrategy();
        address minter = AddressLoader.getMinter();
        address rewardToken = AddressLoader.getRewardToken();

        console.log("\n=== Yield Strategy Information ===");
        console.log("YieldStrategy address:", yieldStrategy);

        // Get minter's balance in yield strategy
        uint256 principal = MockYieldStrategy(yieldStrategy).principalOf(rewardToken, minter);
        uint256 totalBalance = MockYieldStrategy(yieldStrategy).totalBalanceOf(rewardToken, minter);

        console.log("Minter's principal balance:", principal);
        console.log("Minter's total balance (principal + yield):", totalBalance);
        console.log("Accumulated yield:", totalBalance - principal);

        // Get yield rate
        uint256 yieldRateBps = MockYieldStrategy(yieldStrategy).yieldRateBps();
        console.log("Yield rate (bps):", yieldRateBps);
        console.log("Yield rate (%): ", yieldRateBps / 100);

        // Check authorization
        bool minterAuthorized = MockYieldStrategy(yieldStrategy).authorizedClients(minter);
        console.log("Minter authorized:", minterAuthorized ? "YES" : "NO");

        // Get stablecoin config from minter
        (address configYS, uint256 exchangeRate, uint8 decimals, bool enabled) =
            PhusdStableMinter(minter).stablecoinConfigs(rewardToken);

        console.log("\n--- Stablecoin Configuration ---");
        console.log("Configured yield strategy:", configYS);
        console.log("Exchange rate:", exchangeRate);
        console.log("Decimals:", uint256(decimals));
        console.log("Enabled:", enabled ? "YES" : "NO");

        console.log("====================================\n");
    }
}
