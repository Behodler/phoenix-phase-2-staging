// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@vault/concreteYieldStrategies/AutoDolaYieldStrategy.sol";

/**
 * @title FixMainnetWithdrawer
 * @notice One-time fix script to authorize StableYieldAccumulator as withdrawer on AutoDolaYieldStrategy
 * @dev This script fixes the missing setWithdrawer call from the initial mainnet deployment.
 *
 * The StableYieldAccumulator needs to call withdrawFrom() on AutoDolaYieldStrategy to collect yield.
 * Without being an authorized withdrawer, claim() reverts with:
 * "AYieldStrategy: unauthorized, only authorized withdrawers"
 *
 * Usage:
 *   forge script script/FixMainnetWithdrawer.s.sol:FixMainnetWithdrawer --rpc-url $MAINNET_RPC_URL --broadcast
 *
 * For Ledger signing (index 46):
 *   forge script script/FixMainnetWithdrawer.s.sol:FixMainnetWithdrawer --rpc-url $MAINNET_RPC_URL --broadcast --ledger --hd-paths "m/44'/60'/46'/0/0"
 */
contract FixMainnetWithdrawer is Script {
    // ==========================================
    //    MAINNET ADDRESSES (from mainnet-addresses.ts)
    // ==========================================

    // Deployed Phase 2 contracts
    address public constant AUTO_DOLA_YIELD_STRATEGY = 0x01d34d7EF3988C5b981ee06bF0Ba4485Bd8eA20C;
    address public constant STABLE_YIELD_ACCUMULATOR = 0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f;

    // Expected owner address (Ledger index 46)
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        console.log("=========================================");
        console.log("  FIX MAINNET WITHDRAWER AUTHORIZATION");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");
        console.log("");
        console.log("AutoDolaYieldStrategy:", AUTO_DOLA_YIELD_STRATEGY);
        console.log("StableYieldAccumulator:", STABLE_YIELD_ACCUMULATOR);
        console.log("Expected Owner:", OWNER_ADDRESS);
        console.log("");

        // Verify current state before fix
        AutoDolaYieldStrategy yieldStrategy = AutoDolaYieldStrategy(AUTO_DOLA_YIELD_STRATEGY);

        // Check current owner
        address currentOwner = yieldStrategy.owner();
        console.log("Current YieldStrategy Owner:", currentOwner);
        require(currentOwner == OWNER_ADDRESS, "Unexpected owner - aborting for safety");

        // Check if already authorized
        bool alreadyAuthorized = yieldStrategy.authorizedWithdrawers(STABLE_YIELD_ACCUMULATOR);
        console.log("StableYieldAccumulator already authorized:", alreadyAuthorized);

        if (alreadyAuthorized) {
            console.log("");
            console.log("StableYieldAccumulator is already an authorized withdrawer.");
            console.log("No action needed.");
            return;
        }

        console.log("");
        console.log("Proceeding with fix...");
        console.log("");

        vm.startBroadcast();

        // Authorize StableYieldAccumulator as withdrawer
        yieldStrategy.setWithdrawer(STABLE_YIELD_ACCUMULATOR, true);

        vm.stopBroadcast();

        // Verify the fix
        bool nowAuthorized = yieldStrategy.authorizedWithdrawers(STABLE_YIELD_ACCUMULATOR);
        require(nowAuthorized, "Fix failed - StableYieldAccumulator not authorized");

        console.log("=========================================");
        console.log("            FIX SUCCESSFUL");
        console.log("=========================================");
        console.log("");
        console.log("StableYieldAccumulator is now authorized to withdraw from AutoDolaYieldStrategy");
        console.log("The claim() function on StableYieldAccumulator should now work correctly.");
    }
}
