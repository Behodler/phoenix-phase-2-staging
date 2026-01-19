// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@phlimbo-ea/Phlimbo.sol";

/**
 * @title SetDesiredAPY
 * @notice Script to set desired APY on Phlimbo (two-step process)
 * @dev On real networks, each broadcast creates a separate transaction in a new block.
 *      The script calls setDesiredAPY twice - first to preview, second to commit.
 *
 * Usage:
 *   # Anvil (local)
 *   forge script script/interactions/SetDesiredAPY.s.sol:SetDesiredAPY --rpc-url http://localhost:8545 --broadcast
 *
 *   # Sepolia
 *   forge script script/interactions/SetDesiredAPY.s.sol:SetDesiredAPY --rpc-url $SEPOLIA_RPC_URL --broadcast
 *
 * Environment variables:
 *   - DEPLOYER_SEPOLIA_pk: Private key for Sepolia (required for Sepolia)
 *   - PHLIMBO_ADDRESS: (optional) Override the default Phlimbo address
 *   - DESIRED_APY_BPS: (optional) Override the default APY (default: 500 = 5%)
 */
contract SetDesiredAPY is Script {
    // Sepolia PhlimboEA address from deployment
    address constant SEPOLIA_PHLIMBO = 0x347168aCbf5d5d6E2e49e7Ca6298e77123758C0F;

    // Anvil PhlimboEA address (default Anvil deployment)
    address constant ANVIL_PHLIMBO = 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;

    function run() external {
        // Determine network and get appropriate addresses
        address phlimbo = _getPhlimboAddress();
        uint256 deployerKey = _getPrivateKey();

        // Get APY from env or use default (500 = 5%)
        uint256 newAPY = vm.envOr("DESIRED_APY_BPS", uint256(500));

        console.log("\n=== Setting Desired APY ===");
        console.log("Chain ID:", block.chainid);
        console.log("Phlimbo address:", phlimbo);
        console.log("New APY (bps):", newAPY);
        console.log("New APY: %s.%s%s%%", newAPY / 100, (newAPY % 100) / 10, newAPY % 10);

        // Check current state before making changes
        PhlimboEA p = PhlimboEA(phlimbo);
        uint256 currentAPY = p.desiredAPYBps();
        bool inProgress = p.apySetInProgress();
        uint256 pendingAPY = p.pendingAPYBps();
        uint256 pendingBlock = p.pendingAPYBlockNumber();

        console.log("\n--- Current State ---");
        console.log("Current APY (bps):", currentAPY);
        console.log("APY set in progress:", inProgress ? "YES" : "NO");
        if (inProgress) {
            console.log("Pending APY (bps):", pendingAPY);
            console.log("Pending since block:", pendingBlock);
            console.log("Current block:", block.number);
            console.log("Blocks elapsed:", block.number - pendingBlock);
        }

        vm.startBroadcast(deployerKey);

        if (inProgress && pendingAPY == newAPY && block.number <= pendingBlock + 100) {
            // Already in progress with same value and within 100 blocks - just commit
            console.log("\n--- Committing Pending APY ---");
            console.log("APY change already previewed, committing...");
            p.setDesiredAPY(newAPY);
            console.log("APY change committed!");
        } else {
            // Need to do both steps (preview then commit)
            // On real networks, each call is a separate tx in a separate block
            console.log("\n--- Step 1: Preview APY Change ---");
            p.setDesiredAPY(newAPY);
            console.log("APY change previewed (tx 1)");

            console.log("\n--- Step 2: Commit APY Change ---");
            // On real networks (Sepolia, Mainnet), this will be in a new block
            // On Anvil with --broadcast, forge sends transactions sequentially
            // which should result in different blocks
            p.setDesiredAPY(newAPY);
            console.log("APY change committed (tx 2)");
        }

        vm.stopBroadcast();

        // Verify the change
        uint256 finalAPY = p.desiredAPYBps();
        bool finalInProgress = p.apySetInProgress();

        console.log("\n--- Final State ---");
        console.log("Final APY (bps):", finalAPY);
        console.log("APY set in progress:", finalInProgress ? "YES" : "NO");

        if (finalAPY == newAPY) {
            console.log("\n SUCCESS: APY successfully set to %s.%s%s%%", newAPY / 100, (newAPY % 100) / 10, newAPY % 10);
        } else {
            console.log("\n WARNING: APY may not have been committed.");
            console.log("If both transactions were in the same block, run this script again to commit.");
        }

        console.log("\n=== APY Update Complete ===\n");
    }

    function _getPhlimboAddress() internal view returns (address) {
        // Check for override first
        address override_ = vm.envOr("PHLIMBO_ADDRESS", address(0));
        if (override_ != address(0)) {
            return override_;
        }

        // Select based on chain ID
        if (block.chainid == 11155111) {
            return SEPOLIA_PHLIMBO;
        } else if (block.chainid == 31337) {
            return ANVIL_PHLIMBO;
        } else if (block.chainid == 1) {
            revert("Mainnet Phlimbo address not configured - set PHLIMBO_ADDRESS env var");
        } else {
            revert("Unknown chain ID - set PHLIMBO_ADDRESS env var");
        }
    }

    function _getPrivateKey() internal view returns (uint256) {
        if (block.chainid == 11155111) {
            // Sepolia - use DEPLOYER_SEPOLIA_pk
            return vm.envUint("DEPLOYER_SEPOLIA_pk");
        } else if (block.chainid == 31337) {
            // Anvil - use default Anvil private key
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        } else if (block.chainid == 1) {
            // Mainnet - require explicit key
            return vm.envUint("DEPLOYER_MAINNET_pk");
        } else {
            return vm.envUint("PRIVATE_KEY");
        }
    }
}
