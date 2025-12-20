// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockPhUSD.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title StakeOnPhlimbo
 * @notice Script to stake phUSD on Phlimbo yield farm
 * @dev Demonstrates user flow: approve phUSD → stake
 */
contract StakeOnPhlimbo is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address phUSD = AddressLoader.getPhUSD();
        address phlimbo = AddressLoader.getPhlimbo();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();
        address user = vm.addr(deployerKey);

        // Amount to stake (50 phUSD = 50 * 10^18)
        uint256 stakeAmount = 50 * 10**18;

        console.log("\n=== Staking on Phlimbo ===");
        console.log("User:", user);
        console.log("Stake amount:", stakeAmount);

        vm.startBroadcast(deployerKey);

        // Step 1: Approve phUSD for Phlimbo
        MockPhUSD(phUSD).approve(phlimbo, stakeAmount);
        console.log("Approved phUSD for Phlimbo");

        // Step 2: Stake phUSD (recipient is user)
        PhlimboEA(phlimbo).stake(stakeAmount, user);
        console.log("Staked successfully");

        // Query staked amount
        (uint256 stakedAmount,,) = PhlimboEA(phlimbo).userInfo(user);
        console.log("Total staked:", stakedAmount);

        vm.stopBroadcast();

        console.log("=== Stake Complete ===\n");
    }
}
