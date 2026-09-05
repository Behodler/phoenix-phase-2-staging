// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";

/**
 * @title FastForward
 * @notice Script to advance Anvil blockchain time for testing time-dependent features
 * @dev Testing helper to simulate passage of time
 */
contract FastForward is Script {
    using AddressLoader for *;

    function run() external {
        // Time to advance (1 day = 86400 seconds)
        uint256 timeToAdvance = 1 days;

        console.log("\n=== Fast Forwarding Time ===");
        console.log("Current block timestamp:", block.timestamp);
        console.log("Current block number:", block.number);
        console.log("Time to advance (seconds):", timeToAdvance);

        // Calculate new timestamp
        uint256 newTimestamp = block.timestamp + timeToAdvance;
        console.log("New timestamp:", newTimestamp);

        // Advance time using vm.warp (changes block.timestamp)
        vm.warp(newTimestamp);

        // Also advance block number (assume 12 second blocks)
        uint256 blocksToAdvance = timeToAdvance / 12;
        vm.roll(block.number + blocksToAdvance);

        console.log("\n--- After Fast Forward ---");
        console.log("Block timestamp:", block.timestamp);
        console.log("Block number:", block.number);
        console.log("Time advanced:", block.timestamp - (newTimestamp - timeToAdvance), "seconds");
        console.log("Blocks advanced:", blocksToAdvance);

        console.log("=== Fast Forward Complete ===\n");

        console.log("NOTE: This script uses vm.warp which affects the test environment.");
        console.log("To see the effects, you need to run subsequent scripts in the same session.");
    }
}
