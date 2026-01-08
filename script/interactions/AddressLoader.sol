// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title AddressLoader
 * @notice Helper library to load deployed contract addresses
 * @dev Addresses from latest deployment run
 */
library AddressLoader {
    // ========== Token Addresses ==========

    function getPhUSD() internal pure returns (address) {
        return 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    }

    function getUSDC() internal pure returns (address) {
        return 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    }

    function getRewardToken() internal pure returns (address) {
        return getUSDC();
    }

    function getUSDT() internal pure returns (address) {
        return 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;
    }

    function getUSDS() internal pure returns (address) {
        return 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
    }

    // ========== Yield Strategy Addresses ==========

    function getYieldStrategyUSDT() internal pure returns (address) {
        return 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    }

    function getYieldStrategyUSDS() internal pure returns (address) {
        return 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707;
    }

    function getYieldStrategy() internal pure returns (address) {
        return getYieldStrategyUSDT();
    }

    // ========== Core Contract Addresses ==========

    function getMinter() internal pure returns (address) {
        return 0x0165878A594ca255338adfa4d48449f69242Eb8F;
    }

    function getAccumulator() internal pure returns (address) {
        return 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;
    }

    function getPhlimbo() internal pure returns (address) {
        return 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;
    }

    // ========== Test Helpers ==========

    function getDefaultUser() internal pure returns (address) {
        return 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    }

    // Second test user (Anvil account #1)
    function getSecondUser() internal pure returns (address) {
        return 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    }

    function getDefaultPrivateKey() internal pure returns (uint256) {
        return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    }

    // Second user private key (Anvil account #1)
    function getSecondPrivateKey() internal pure returns (uint256) {
        return 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    }

    function logAddresses() internal pure {
        console.log("=== Deployed Contract Addresses ===");
        console.log("MockPhUSD:", getPhUSD());
        console.log("MockUSDC:", getUSDC());
        console.log("MockUSDT:", getUSDT());
        console.log("MockUSDS:", getUSDS());
        console.log("YieldStrategyUSDT:", getYieldStrategyUSDT());
        console.log("YieldStrategyUSDS:", getYieldStrategyUSDS());
        console.log("PhusdStableMinter:", getMinter());
        console.log("StableYieldAccumulator:", getAccumulator());
        console.log("PhlimboEA:", getPhlimbo());
        console.log("===================================");
    }
}
