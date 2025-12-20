// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "../../src/mocks/MockYieldStrategy.sol";

/**
 * @title AddYieldStrategy
 * @notice Script to authorize a new client on a yield strategy
 * @dev Admin-only operation on MockYieldStrategy
 */
contract AddYieldStrategy is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address yieldStrategy = AddressLoader.getYieldStrategy();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // Example new client to authorize
        address newClient = address(0x9876543210987654321098765432109876543210);

        console.log("\n=== Adding Yield Strategy Client ===");
        console.log("Yield strategy:", yieldStrategy);
        console.log("New client:", newClient);

        // Check current authorization
        bool wasAuthorized = MockYieldStrategy(yieldStrategy).authorizedClients(newClient);
        console.log("Currently authorized:", wasAuthorized ? "YES" : "NO");

        vm.startBroadcast(deployerKey);

        // Authorize the new client
        MockYieldStrategy(yieldStrategy).setClient(newClient, true);
        console.log("Client authorized");

        vm.stopBroadcast();

        // Verify authorization
        bool isAuthorized = MockYieldStrategy(yieldStrategy).authorizedClients(newClient);
        console.log("Now authorized:", isAuthorized ? "YES" : "NO");

        console.log("=== Authorization Complete ===\n");
    }
}
