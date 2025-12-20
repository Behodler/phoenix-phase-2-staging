// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title AddressLoader
 * @notice Helper library to load deployed contract addresses from local.json
 * @dev Reads addresses from server/deployments/local.json for interaction scripts
 */
library AddressLoader {
    /**
     * @notice Load MockPhUSD address from local.json
     * @dev Reads from server/deployments/local.json
     * @return Address of deployed MockPhUSD contract
     */
    function getPhUSD() internal view returns (address) {
        // For Anvil, contracts are deployed deterministically
        // These addresses match what's in local.json
        return 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    }

    /**
     * @notice Load MockRewardToken address from local.json
     * @return Address of deployed MockRewardToken contract
     */
    function getRewardToken() internal view returns (address) {
        return 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    }

    /**
     * @notice Load MockYieldStrategy address from local.json
     * @return Address of deployed MockYieldStrategy contract
     */
    function getYieldStrategy() internal view returns (address) {
        return 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
    }

    /**
     * @notice Load PhusdStableMinter address from local.json
     * @return Address of deployed PhusdStableMinter contract
     */
    function getMinter() internal view returns (address) {
        return 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
    }

    /**
     * @notice Load PhlimboEA address from local.json
     * @return Address of deployed PhlimboEA contract
     */
    function getPhlimbo() internal view returns (address) {
        return 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    }

    /**
     * @notice Get default test user address (Anvil account #0)
     * @return Anvil's default deployer/test address
     */
    function getDefaultUser() internal pure returns (address) {
        return 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    }

    /**
     * @notice Get default test user private key
     * @dev This is publicly known - NEVER use on real networks
     * @return Anvil's default private key
     */
    function getDefaultPrivateKey() internal pure returns (uint256) {
        return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    }

    /**
     * @notice Log all deployed addresses for reference
     */
    function logAddresses() internal view {
        console.log("=== Deployed Contract Addresses ===");
        console.log("MockPhUSD:", getPhUSD());
        console.log("MockRewardToken:", getRewardToken());
        console.log("MockYieldStrategy:", getYieldStrategy());
        console.log("PhusdStableMinter:", getMinter());
        console.log("PhlimboEA:", getPhlimbo());
        console.log("Default User:", getDefaultUser());
        console.log("===================================");
    }
}
