// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import {AutoPoolYieldStrategy} from "@vault/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title ViewYieldStrategies
 * @notice Script to view yield strategy balances and configurations
 * @dev Query-only script showing deposits and yield generation for AutoPoolYieldStrategy instances
 *      Addresses need updating from progress.31337.json after redeployment
 */
contract ViewYieldStrategies is Script {
    using AddressLoader for *;

    function run() external view {
        address minter = AddressLoader.getMinter();

        console.log("\n=== Yield Strategy Information ===");
        console.log("Minter:", minter);

        // NOTE: yieldStrategyDola and yieldStrategyUSDC addresses must be
        // populated from progress.31337.json after redeployment.
        // This script serves as a template for viewing AutoPoolYieldStrategy state.

        console.log("\nTo use this script, populate strategy addresses from progress.31337.json");
        console.log("====================================\n");
    }
}
