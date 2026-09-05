// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import {PhlimboV3} from "@phlimbo-ea/PhlimboV3.sol";

/**
 * @title PauseContract
 * @notice Script to pause or unpause the Phlimbo contract
 * @dev Admin-only emergency operation
 */
contract PauseContract is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address phlimbo = AddressLoader.getPhlimbo();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        console.log("\n=== Pausing/Unpausing Phlimbo ===");
        console.log("Phlimbo address:", phlimbo);

        // Check current pause state
        bool isPaused = PhlimboV3(phlimbo).paused();
        console.log("Currently paused:", isPaused ? "YES" : "NO");

        vm.startBroadcast(deployerKey);

        if (isPaused) {
            // Unpause
            console.log("Unpausing contract...");
            PhlimboV3(phlimbo).unpause();
            console.log("Contract unpaused");
        } else {
            // Pause
            console.log("Pausing contract...");
            PhlimboV3(phlimbo).pause();
            console.log("Contract paused");
        }

        vm.stopBroadcast();

        // Verify new state
        bool newState = PhlimboV3(phlimbo).paused();
        console.log("Now paused:", newState ? "YES" : "NO");

        console.log("=== Pause State Updated ===\n");
    }
}
