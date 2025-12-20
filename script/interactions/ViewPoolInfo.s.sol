// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title ViewPoolInfo
 * @notice Script to view global Phlimbo pool information
 * @dev Query-only script showing pool status and reward rates
 */
contract ViewPoolInfo is Script {
    using AddressLoader for *;

    function run() external view {
        // Load addresses
        address phlimbo = AddressLoader.getPhlimbo();

        console.log("\n=== Phlimbo Pool Information ===");

        // Total staked
        uint256 totalStaked = PhlimboEA(phlimbo).totalStaked();
        console.log("Total phUSD staked:", totalStaked);

        // Desired APY
        uint256 desiredAPY = PhlimboEA(phlimbo).desiredAPYBps();
        console.log("Desired APY (bps):", desiredAPY);
        console.log("Desired APY (%): ", desiredAPY / 100);

        // Current emission rates
        uint256 phUSDPerSecond = PhlimboEA(phlimbo).phUSDPerSecond();
        uint256 smoothedStablePerSecond = PhlimboEA(phlimbo).smoothedStablePerSecond();
        console.log("phUSD emission per second:", phUSDPerSecond);
        console.log("Stablecoin emission per second (smoothed):", smoothedStablePerSecond);

        // Calculate daily emissions
        uint256 phUSDPerDay = phUSDPerSecond * 86400;
        uint256 stablePerDay = (smoothedStablePerSecond * 86400) / 1e18; // Unscale from PRECISION
        console.log("Estimated phUSD per day:", phUSDPerDay);
        console.log("Estimated stablecoin per day:", stablePerDay);

        // Last reward time
        uint256 lastRewardTime = PhlimboEA(phlimbo).lastRewardTime();
        console.log("Last reward update:", lastRewardTime);

        // Check if paused
        bool isPaused = PhlimboEA(phlimbo).paused();
        console.log("Contract paused:", isPaused ? "YES" : "NO");

        console.log("====================================\n");
    }
}
