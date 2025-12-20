// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title SetDesiredAPY
 * @notice Script to set desired APY on Phlimbo (two-step process)
 * @dev Demonstrates admin flow: preview APY → commit APY (requires different block)
 */
contract SetDesiredAPY is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address phlimbo = AddressLoader.getPhlimbo();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // New APY in basis points (750 = 7.5%)
        uint256 newAPY = 750;

        console.log("\n=== Setting Desired APY ===");
        console.log("New APY (bps):", newAPY);
        console.log("New APY (%): ", newAPY / 100);
        console.log("  (", newAPY % 100, "/100 ths)");

        vm.startBroadcast(deployerKey);

        // Step 1: Preview the change
        console.log("\nStep 1: Previewing APY change...");
        PhlimboEA(phlimbo).setDesiredAPY(newAPY);
        console.log("APY change previewed");

        // Check pending state
        bool inProgress = PhlimboEA(phlimbo).apySetInProgress();
        uint256 pendingAPY = PhlimboEA(phlimbo).pendingAPYBps();
        console.log("Change in progress:", inProgress ? "YES" : "NO");
        console.log("Pending APY:", pendingAPY);

        // Step 2: Advance block and commit
        console.log("\nStep 2: Advancing block and committing...");
        vm.roll(block.number + 1);

        PhlimboEA(phlimbo).setDesiredAPY(newAPY);
        console.log("APY change committed");

        vm.stopBroadcast();

        // Verify the change
        uint256 currentAPY = PhlimboEA(phlimbo).desiredAPYBps();
        console.log("\nCurrent APY (bps):", currentAPY);
        console.log("Current APY (%): ", currentAPY / 100);

        console.log("=== APY Update Complete ===\n");
    }
}
