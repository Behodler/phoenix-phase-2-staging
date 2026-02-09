// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title SetDepletionDuration
 * @notice Sets PhlimboEA depletion duration to 2 weeks
 *
 * Usage (dry run):
 *   npm run mainnet:set-depletion-dry
 *
 * Usage (broadcast with Ledger index 46):
 *   npm run mainnet:set-depletion
 */
contract SetDepletionDuration is Script {
    // Mainnet addresses
    address public constant PHLIMBO_EA = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;

    // Expected owner (Ledger index 46)
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Parameters
    uint256 public constant DEPLETION_DURATION = 14 days; // 2 weeks

    function run() external {
        console.log("=========================================");
        console.log("  SET DEPLETION DURATION");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        PhlimboEA phlimbo = PhlimboEA(PHLIMBO_EA);

        // Verify ownership
        address phlimboOwner = phlimbo.owner();
        console.log("PhlimboEA owner:", phlimboOwner);
        require(phlimboOwner == OWNER_ADDRESS, "Unexpected PhlimboEA owner");

        // Show current values
        uint256 oldDepletionDuration = phlimbo.depletionDuration();
        console.log("");
        console.log("--- Current Values ---");
        console.log("Depletion duration (s):", oldDepletionDuration);
        console.log("");
        console.log("--- New Values ---");
        console.log("Depletion duration (s):", DEPLETION_DURATION);
        console.log("");

        vm.startBroadcast();

        phlimbo.setDepletionDuration(DEPLETION_DURATION);
        console.log("Depletion duration set to 2 weeks");

        vm.stopBroadcast();

        // Verify
        uint256 newDepletionDuration = phlimbo.depletionDuration();
        require(newDepletionDuration == DEPLETION_DURATION, "Depletion duration not updated");

        console.log("");
        console.log("=========================================");
        console.log("  DEPLETION DURATION UPDATED SUCCESSFULLY");
        console.log("=========================================");
    }
}
