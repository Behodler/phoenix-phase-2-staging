// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../../src/mocks/MockAutoDOLA.sol";
import {AutoPoolYieldStrategy} from "@vault/concreteYieldStrategies/AutoPoolYieldStrategy.sol";

/**
 * @title SimulateYield
 * @notice Script to manually add simulated yield to DOLA and USDC yield strategies
 * @dev Testing helper to simulate yield generation without waiting.
 *      Adds yield to DOLA and USDC AutoPool strategies by minting tokens
 *      directly to the underlying vaults (raising share price).
 *      Supports both Anvil and Sepolia networks.
 */
contract SimulateYield is Script {
    struct NetworkAddresses {
        address yieldStrategyDola;
        address yieldStrategyUSDC;
        address mockAutoDola;
        address mockAutoUSDC;
        address dola;
        address usdc;
        address minter;
    }

    function _getAddresses() internal view returns (NetworkAddresses memory addrs, uint256 deployerKey) {
        uint256 chainId = block.chainid;

        if (chainId == 31337) {
            // Anvil addresses - these will change after redeployment
            addrs = NetworkAddresses({
                yieldStrategyDola: address(0),
                yieldStrategyUSDC: address(0),
                mockAutoDola: address(0),
                mockAutoUSDC: address(0),
                dola: address(0),
                usdc: address(0),
                minter: address(0)
            });
            deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            revert("Anvil addresses need updating after redeployment - populate from progress.31337.json");
        } else if (chainId == 11155111) {
            // Sepolia addresses (from progress.11155111.json)
            addrs = NetworkAddresses({
                yieldStrategyDola: 0xd31cB159dD88492E08C05A12A58A76bD564463F1,
                yieldStrategyUSDC: address(0), // Update after Sepolia redeploy
                mockAutoDola: 0x947F60FF8062d6818978988281C864C469af1742,
                mockAutoUSDC: address(0), // Update after Sepolia redeploy
                dola: 0x4e826aB805DC2866bcA0632023dF719bE3f22390,
                usdc: address(0), // Update after Sepolia redeploy
                minter: 0x45626bfb1904166Db112138fE0D2fA6C5123A75B
            });
            deployerKey = vm.envUint("DEPLOYER_SEPOLIA_pk");
        } else {
            revert("Unsupported chain ID");
        }
    }

    function run() external {
        console.log("Chain ID:", block.chainid);

        (NetworkAddresses memory addrs, uint256 deployerKey) = _getAddresses();

        uint256 dolaYield = 500 * 10**18;    // 500 DOLA (18 decimals)
        uint256 usdcYield = 500 * 10**6;     // 500 USDC (6 decimals)

        console.log("\n=== Simulating Yield Generation ===");

        _logDOLABefore(addrs);
        _logUSDCBefore(addrs);

        vm.startBroadcast(deployerKey);

        // Add yield to DOLA strategy via MockAutoDOLA
        if (addrs.mockAutoDola != address(0)) {
            MockAutoDOLA(addrs.mockAutoDola).addYield(dolaYield);
            console.log("\nDOLA yield added via MockAutoDOLA.addYield()");
        }

        // Add yield to USDC strategy via MockAutoUSDC
        if (addrs.mockAutoUSDC != address(0)) {
            MockAutoDOLA(addrs.mockAutoUSDC).addYield(usdcYield);
            console.log("USDC yield added via MockAutoUSDC.addYield()");
        }

        vm.stopBroadcast();

        console.log("\n--- Results ---");
        _logResults(addrs);

        console.log("\n=== Yield Simulation Complete ===\n");
    }

    function _logDOLABefore(NetworkAddresses memory addrs) internal view {
        if (addrs.yieldStrategyDola == address(0)) return;

        console.log("\n--- DOLA Strategy ---");
        console.log("Strategy:", addrs.yieldStrategyDola);
        console.log("MockAutoDOLA:", addrs.mockAutoDola);

        uint256 total = AutoPoolYieldStrategy(addrs.yieldStrategyDola).totalBalanceOf(addrs.dola, addrs.minter);
        uint256 principal = AutoPoolYieldStrategy(addrs.yieldStrategyDola).principalOf(addrs.dola, addrs.minter);
        console.log("Total balance before:", total);
        console.log("Principal before:", principal);
        console.log("Yield before:", total > principal ? total - principal : 0);
    }

    function _logUSDCBefore(NetworkAddresses memory addrs) internal view {
        if (addrs.yieldStrategyUSDC == address(0)) return;

        console.log("\n--- USDC Strategy ---");
        console.log("Strategy:", addrs.yieldStrategyUSDC);
        console.log("MockAutoUSDC:", addrs.mockAutoUSDC);

        uint256 total = AutoPoolYieldStrategy(addrs.yieldStrategyUSDC).totalBalanceOf(addrs.usdc, addrs.minter);
        uint256 principal = AutoPoolYieldStrategy(addrs.yieldStrategyUSDC).principalOf(addrs.usdc, addrs.minter);
        console.log("Total balance before:", total);
        console.log("Principal before:", principal);
        console.log("Yield before:", total > principal ? total - principal : 0);
    }

    function _logResults(NetworkAddresses memory addrs) internal view {
        uint256 dolaYield = 0;
        if (addrs.yieldStrategyDola != address(0)) {
            uint256 dolaTotal = AutoPoolYieldStrategy(addrs.yieldStrategyDola).totalBalanceOf(addrs.dola, addrs.minter);
            uint256 dolaPrincipal = AutoPoolYieldStrategy(addrs.yieldStrategyDola).principalOf(addrs.dola, addrs.minter);
            dolaYield = dolaTotal > dolaPrincipal ? dolaTotal - dolaPrincipal : 0;
            console.log("DOLA yield after:", dolaYield);
        }

        uint256 usdcYieldAfter = 0;
        if (addrs.yieldStrategyUSDC != address(0)) {
            uint256 usdcTotal = AutoPoolYieldStrategy(addrs.yieldStrategyUSDC).totalBalanceOf(addrs.usdc, addrs.minter);
            uint256 usdcPrincipal = AutoPoolYieldStrategy(addrs.yieldStrategyUSDC).principalOf(addrs.usdc, addrs.minter);
            usdcYieldAfter = usdcTotal > usdcPrincipal ? usdcTotal - usdcPrincipal : 0;
            console.log("USDC yield after:", usdcYieldAfter);
        }

        // Total in USD equivalent (convert 18 decimal tokens to 6 decimals for display)
        uint256 totalYieldUsd = usdcYieldAfter + (dolaYield / 1e12);
        console.log("\nTotal yield (USD equiv, 6 decimals):", totalYieldUsd);
    }
}
