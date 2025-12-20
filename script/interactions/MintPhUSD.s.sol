// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockUSDT.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title MintPhUSD
 * @notice Script to mint phUSD by depositing stablecoins into PhusdStableMinter
 * @dev Demonstrates the user flow: approve stablecoin → mint phUSD
 *      Uses USDT as the stablecoin (DAI also works)
 */
contract MintPhUSD is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address minter = AddressLoader.getMinter();
        address usdt = AddressLoader.getUSDT();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();
        address user = vm.addr(deployerKey);

        // Amount to mint (100 USDT = 100 * 10^6 due to 6 decimals)
        uint256 stablecoinAmount = 100 * 10**6;

        console.log("\n=== Minting phUSD ===");
        console.log("User:", user);
        console.log("Stablecoin (USDT):", usdt);
        console.log("Stablecoin amount:", stablecoinAmount);

        vm.startBroadcast(deployerKey);

        // Step 1: Approve stablecoin for minter
        MockUSDT(usdt).approve(minter, stablecoinAmount);
        console.log("Approved USDT for minter");

        // Step 2: Mint phUSD
        PhusdStableMinter(minter).mint(usdt, stablecoinAmount);
        console.log("Minted phUSD successfully");

        vm.stopBroadcast();

        console.log("=== Mint Complete ===\n");
    }
}
