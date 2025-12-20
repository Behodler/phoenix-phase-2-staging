// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockPhUSD.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title WithdrawFromPhlimbo
 * @notice Script to withdraw staked phUSD from Phlimbo
 * @dev Withdraws specified amount and automatically claims pending rewards
 */
contract WithdrawFromPhlimbo is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address phUSD = AddressLoader.getPhUSD();
        address phlimbo = AddressLoader.getPhlimbo();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();
        address user = vm.addr(deployerKey);

        // Amount to withdraw (25 phUSD = 25 * 10^18)
        uint256 withdrawAmount = 25 * 10**18;

        console.log("\n=== Withdrawing from Phlimbo ===");
        console.log("User:", user);
        console.log("Withdraw amount:", withdrawAmount);

        // Check balances before
        uint256 phUSDBefore = MockPhUSD(phUSD).balanceOf(user);
        (uint256 stakedBefore,,) = PhlimboEA(phlimbo).userInfo(user);
        console.log("phUSD balance before:", phUSDBefore);
        console.log("Staked amount before:", stakedBefore);

        vm.startBroadcast(deployerKey);

        // Withdraw phUSD (also claims rewards automatically)
        PhlimboEA(phlimbo).withdraw(withdrawAmount);
        console.log("Withdrawn successfully");

        vm.stopBroadcast();

        // Check balances after
        uint256 phUSDAfter = MockPhUSD(phUSD).balanceOf(user);
        (uint256 stakedAfter,,) = PhlimboEA(phlimbo).userInfo(user);

        console.log("phUSD balance after:", phUSDAfter);
        console.log("Staked amount after:", stakedAfter);
        console.log("phUSD received:", phUSDAfter - phUSDBefore);
        console.log("Amount unstaked:", stakedBefore - stakedAfter);

        console.log("=== Withdraw Complete ===\n");
    }
}
