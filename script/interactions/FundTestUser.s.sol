// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockPhUSD.sol";
import "../../src/mocks/MockRewardToken.sol";

/**
 * @title FundTestUser
 * @notice Script to fund a test user with tokens for testing (Anvil only)
 * @dev Mints phUSD and stablecoins to a specified address
 */
contract FundTestUser is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address phUSD = AddressLoader.getPhUSD();
        address rewardToken = AddressLoader.getRewardToken();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // Test user to fund (can be changed)
        address testUser = AddressLoader.getDefaultUser();

        // Amounts to mint
        uint256 phUSDAmount = 1000 * 10**18; // 1000 phUSD
        uint256 stableAmount = 10000 * 10**6; // 10,000 USDC

        console.log("\n=== Funding Test User ===");
        console.log("Test user:", testUser);
        console.log("phUSD to mint:", phUSDAmount);
        console.log("Stablecoin to mint:", stableAmount);

        // Check balances before
        uint256 phUSDBefore = MockPhUSD(phUSD).balanceOf(testUser);
        uint256 stableBefore = MockRewardToken(rewardToken).balanceOf(testUser);
        console.log("\n--- Before ---");
        console.log("phUSD balance:", phUSDBefore);
        console.log("Stablecoin balance:", stableBefore);

        vm.startBroadcast(deployerKey);

        // Mint phUSD (deployer is authorized minter)
        MockPhUSD(phUSD).mint(testUser, phUSDAmount);
        console.log("\nMinted phUSD");

        // Mint stablecoins (anyone can mint on MockRewardToken)
        MockRewardToken(rewardToken).mint(testUser, stableAmount);
        console.log("Minted stablecoins");

        vm.stopBroadcast();

        // Check balances after
        uint256 phUSDAfter = MockPhUSD(phUSD).balanceOf(testUser);
        uint256 stableAfter = MockRewardToken(rewardToken).balanceOf(testUser);
        console.log("\n--- After ---");
        console.log("phUSD balance:", phUSDAfter);
        console.log("Stablecoin balance:", stableAfter);

        console.log("=== Funding Complete ===\n");
    }
}
