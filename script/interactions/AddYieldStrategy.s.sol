// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import {AutoPoolYieldStrategy} from "@vault/concreteYieldStrategies/AutoPoolYieldStrategy.sol";

/**
 * @title AddYieldStrategy
 * @notice Script to authorize a new client on an AutoPoolYieldStrategy
 * @dev Admin-only operation. Addresses need updating from progress.31337.json after redeployment.
 */
contract AddYieldStrategy is Script {
    using AddressLoader for *;

    function run() external {
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // NOTE: Update this address from progress.31337.json after redeployment
        address yieldStrategy = address(0);
        require(yieldStrategy != address(0), "Set yieldStrategy address from progress.31337.json");

        // Example new client to authorize
        address newClient = address(0x9876543210987654321098765432109876543210);

        console.log("\n=== Adding Yield Strategy Client ===");
        console.log("Yield strategy:", yieldStrategy);
        console.log("New client:", newClient);

        vm.startBroadcast(deployerKey);

        AutoPoolYieldStrategy(yieldStrategy).setClient(newClient, true);
        console.log("Client authorized");

        vm.stopBroadcast();

        console.log("=== Authorization Complete ===\n");
    }
}
