// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockPhUSD.sol";
import "../../src/mocks/MockRewardToken.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title ClaimPhlimboRewards
 * @notice Script to claim accumulated rewards from Phlimbo staking
 * @dev Claims both phUSD and stablecoin rewards
 */
contract ClaimPhlimboRewards is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address phUSD = AddressLoader.getPhUSD();
        address rewardToken = AddressLoader.getRewardToken();
        address phlimbo = AddressLoader.getPhlimbo();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();
        address user = vm.addr(deployerKey);

        console.log("\n=== Claiming Phlimbo Rewards ===");
        console.log("User:", user);

        // Check balances before
        uint256 phUSDBefore = MockPhUSD(phUSD).balanceOf(user);
        uint256 stableBefore = MockRewardToken(rewardToken).balanceOf(user);
        console.log("phUSD balance before:", phUSDBefore);
        console.log("Stablecoin balance before:", stableBefore);

        vm.startBroadcast(deployerKey);

        // Claim rewards (withdraw with 0 amount claims without unstaking)
        PhlimboEA(phlimbo).withdraw(0);
        console.log("Claimed rewards");

        vm.stopBroadcast();

        // Check balances after
        uint256 phUSDAfter = MockPhUSD(phUSD).balanceOf(user);
        uint256 stableAfter = MockRewardToken(rewardToken).balanceOf(user);

        console.log("phUSD balance after:", phUSDAfter);
        console.log("Stablecoin balance after:", stableAfter);
        console.log("phUSD rewards claimed:", phUSDAfter - phUSDBefore);
        console.log("Stablecoin rewards claimed:", stableAfter - stableBefore);

        console.log("=== Claim Complete ===\n");
    }
}
