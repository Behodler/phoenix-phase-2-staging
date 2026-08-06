// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import {PhlimboV3} from "@phlimbo-ea/PhlimboV3.sol";

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
        uint256 totalStaked = PhlimboV3(phlimbo).totalStaked();
        console.log("Total phUSD staked:", totalStaked);

        // Desired APY
        uint256 desiredAPY = PhlimboV3(phlimbo).desiredAPYBps();
        console.log("Desired APY (bps):", desiredAPY);
        console.log("Desired APY (%): ", desiredAPY / 100);

        // Current emission rates (Linear Depletion Model)
        uint256 phUSDPerSecond = PhlimboV3(phlimbo).phUSDPerSecond();
        uint256 rewardPerSecond = PhlimboV3(phlimbo).rewardPerSecond();
        console.log("phUSD emission per second:", phUSDPerSecond);
        console.log("Stablecoin reward per second:", rewardPerSecond);

        // Linear depletion state
        uint256 rewardBalance = PhlimboV3(phlimbo).rewardBalance();
        uint256 depletionDuration = PhlimboV3(phlimbo).depletionDuration();
        console.log("Reward balance remaining:", rewardBalance);
        console.log("Depletion duration (seconds):", depletionDuration);

        // Calculate daily emissions
        uint256 phUSDPerDay = phUSDPerSecond * 86400;
        uint256 stablePerDay = (rewardPerSecond * 86400) / 1e18; // Unscale from PRECISION
        console.log("Estimated phUSD per day:", phUSDPerDay);
        console.log("Estimated stablecoin per day:", stablePerDay);

        // Last reward time
        uint256 lastRewardTime = PhlimboV3(phlimbo).lastRewardTime();
        console.log("Last reward update:", lastRewardTime);

        // Check if paused
        bool isPaused = PhlimboV3(phlimbo).paused();
        console.log("Contract paused:", isPaused ? "YES" : "NO");

        console.log("====================================\n");
    }
}
