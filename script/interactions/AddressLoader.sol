// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title AddressLoader
 * @notice Helper library to load deployed contract addresses
 * @dev Addresses are deterministic in Anvil based on deployer nonce
 *
 * Deployment Order (nonce):
 *   0: MockPhUSD
 *   1: MockUSDC (RewardToken)
 *   2: MockUSDT
 *   3: MockDAI
 *   4: YieldStrategyUSDT
 *   5: YieldStrategyDAI
 *   6: PhusdStableMinter
 *   7: StableYieldAccumulator
 *   8: PhlimboEA
 */
library AddressLoader {
    // ========== Token Addresses ==========

    /**
     * @notice Load MockPhUSD address (nonce 0)
     * @return Address of deployed MockPhUSD contract
     */
    function getPhUSD() internal pure returns (address) {
        return 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    }

    /**
     * @notice Load MockUSDC (RewardToken) address (nonce 1)
     * @dev This is the consolidated reward token for Phlimbo
     * @return Address of deployed MockUSDC contract
     */
    function getUSDC() internal pure returns (address) {
        return 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    }

    /**
     * @notice Alias for getUSDC for backwards compatibility
     */
    function getRewardToken() internal pure returns (address) {
        return getUSDC();
    }

    /**
     * @notice Load MockUSDT address (nonce 2)
     * @return Address of deployed MockUSDT contract
     */
    function getUSDT() internal pure returns (address) {
        return 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
    }

    /**
     * @notice Load MockDAI address (nonce 3)
     * @return Address of deployed MockDAI contract
     */
    function getDAI() internal pure returns (address) {
        return 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
    }

    // ========== Yield Strategy Addresses ==========

    /**
     * @notice Load YieldStrategyUSDT address (nonce 4)
     * @return Address of deployed YieldStrategyUSDT contract
     */
    function getYieldStrategyUSDT() internal pure returns (address) {
        return 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    }

    /**
     * @notice Load YieldStrategyDAI address (nonce 5)
     * @return Address of deployed YieldStrategyDAI contract
     */
    function getYieldStrategyDAI() internal pure returns (address) {
        return 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707;
    }

    /**
     * @notice Alias for backwards compatibility - returns USDT strategy
     */
    function getYieldStrategy() internal pure returns (address) {
        return getYieldStrategyUSDT();
    }

    // ========== Core Contract Addresses ==========

    /**
     * @notice Load PhusdStableMinter address (nonce 6)
     * @return Address of deployed PhusdStableMinter contract
     */
    function getMinter() internal pure returns (address) {
        return 0x0165878A594ca255338adfa4d48449f69242Eb8F;
    }

    /**
     * @notice Load StableYieldAccumulator address (nonce 7)
     * @return Address of deployed StableYieldAccumulator contract
     */
    function getAccumulator() internal pure returns (address) {
        return 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;
    }

    /**
     * @notice Load PhlimboEA address (nonce 8)
     * @return Address of deployed PhlimboEA contract
     */
    function getPhlimbo() internal pure returns (address) {
        return 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;
    }

    // ========== Test Helpers ==========

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
    function logAddresses() internal pure {
        console.log("=== Deployed Contract Addresses ===");
        console.log("");
        console.log("Tokens:");
        console.log("  MockPhUSD:", getPhUSD());
        console.log("  MockUSDC:", getUSDC());
        console.log("  MockUSDT:", getUSDT());
        console.log("  MockDAI:", getDAI());
        console.log("");
        console.log("Yield Strategies:");
        console.log("  YieldStrategyUSDT:", getYieldStrategyUSDT());
        console.log("  YieldStrategyDAI:", getYieldStrategyDAI());
        console.log("");
        console.log("Core Contracts:");
        console.log("  PhusdStableMinter:", getMinter());
        console.log("  StableYieldAccumulator:", getAccumulator());
        console.log("  PhlimboEA:", getPhlimbo());
        console.log("");
        console.log("Test User:", getDefaultUser());
        console.log("===================================");
    }
}
