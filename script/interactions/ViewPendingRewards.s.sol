// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title ViewPendingRewards
 * @notice Script to view pending rewards for a staker on Phlimbo
 * @dev Query-only script, does not modify state
 */
contract ViewPendingRewards is Script {
    using AddressLoader for *;

    function run() external view {
        // Load addresses
        address phlimbo = AddressLoader.getPhlimbo();
        address user = AddressLoader.getDefaultUser();

        console.log("\n=== Viewing Pending Rewards ===");
        console.log("User:", user);

        // Get pending rewards (separate functions for each token)
        uint256 pendingPhUSDReward = PhlimboEA(phlimbo).pendingPhUSD(user);
        uint256 pendingStableReward = PhlimboEA(phlimbo).pendingStable(user);

        console.log("Pending phUSD rewards:", pendingPhUSDReward);
        console.log("Pending stablecoin rewards:", pendingStableReward);

        // Get user staking info
        (uint256 stakedAmount,,) = PhlimboEA(phlimbo).userInfo(user);
        console.log("Staked amount:", stakedAmount);

        // Get pool info
        uint256 totalStaked = PhlimboEA(phlimbo).totalStaked();
        console.log("Total pool staked:", totalStaked);

        if (totalStaked > 0) {
            uint256 sharePercentage = (stakedAmount * 10000) / totalStaked;
            console.log("User's share of pool (%):", sharePercentage / 100);
        }

        console.log("===================================\n");
    }
}
