// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../../src/mocks/MockYieldStrategy.sol";
import "../../src/mocks/MockAutoDOLA.sol";
import {AutoDolaYieldStrategy} from "@vault/concreteYieldStrategies/Legacy/phase1/AutoDolaYieldStrategy.sol";

/**
 * @title SimulateYield
 * @notice Script to manually add simulated yield to all yield strategies
 * @dev Testing helper to simulate yield generation without waiting
 *      Adds yield to USDT, USDS, and DOLA strategies for testing the reward flow
 *      Supports both Anvil and Sepolia networks
 */
contract SimulateYield is Script {
    // Network addresses struct to avoid stack too deep
    struct NetworkAddresses {
        address yieldStrategyUSDT;
        address yieldStrategyUSDS;
        address yieldStrategyDola;
        address mockAutoDola;
        address usdt;
        address usds;
        address dola;
        address minter;
    }

    function _getAddresses() internal view returns (NetworkAddresses memory addrs, uint256 deployerKey) {
        uint256 chainId = block.chainid;

        if (chainId == 31337) {
            // Anvil addresses
            addrs = NetworkAddresses({
                yieldStrategyUSDT: 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9,
                yieldStrategyUSDS: 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707,
                yieldStrategyDola: address(0),
                mockAutoDola: address(0),
                usdt: 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0,
                usds: 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9,
                dola: address(0),
                minter: 0x0165878A594ca255338adfa4d48449f69242Eb8F
            });
            deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        } else if (chainId == 11155111) {
            // Sepolia addresses (from progress.11155111.json - updated after redeploy)
            addrs = NetworkAddresses({
                yieldStrategyUSDT: 0xe329770bfaeCceC9EfF6dACDb64AB5B0CCf0B230,
                yieldStrategyUSDS: 0x712b8EcF372c2Bf5708f059bF0089271FEf06cd0,
                yieldStrategyDola: 0xd31cB159dD88492E08C05A12A58A76bD564463F1,
                mockAutoDola: 0x947F60FF8062d6818978988281C864C469af1742,
                usdt: 0x5277592f42F69ce66f8981Bd65b5f70C92b64704,
                usds: 0x132A660DC639b0598DdFe4D04eF800B5ddd22780,
                dola: 0x4e826aB805DC2866bcA0632023dF719bE3f22390,
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

        // Yield amounts to add
        uint256 usdtYield = 500 * 10**6;     // 500 USDT (6 decimals)
        uint256 usdsYield = 500 * 10**18;    // 500 USDS (18 decimals)
        uint256 dolaYield = 500 * 10**18;    // 500 DOLA (18 decimals)

        console.log("\n=== Simulating Yield Generation ===");

        // Log before states
        _logUSDTBefore(addrs);
        _logUSDSBefore(addrs);
        _logDOLABefore(addrs);

        vm.startBroadcast(deployerKey);

        // Add simulated yield to USDT and USDS strategies
        MockYieldStrategy(addrs.yieldStrategyUSDT).addYield(addrs.usdt, addrs.minter, usdtYield);
        console.log("\nUSDT yield added");

        MockYieldStrategy(addrs.yieldStrategyUSDS).addYield(addrs.usds, addrs.minter, usdsYield);
        console.log("USDS yield added");

        // Add yield to DOLA strategy via MockAutoDOLA
        if (addrs.mockAutoDola != address(0)) {
            MockAutoDOLA(addrs.mockAutoDola).addYield(dolaYield);
            console.log("DOLA yield added via MockAutoDOLA.addYield()");
        }

        vm.stopBroadcast();

        // Log results
        console.log("\n--- Results ---");
        _logResults(addrs);

        console.log("\n=== Yield Simulation Complete ===\n");
    }

    function _logUSDTBefore(NetworkAddresses memory addrs) internal view {
        console.log("\n--- USDT Strategy ---");
        console.log("Strategy:", addrs.yieldStrategyUSDT);

        uint256 total = MockYieldStrategy(addrs.yieldStrategyUSDT).totalBalanceOf(addrs.usdt, addrs.minter);
        uint256 principal = MockYieldStrategy(addrs.yieldStrategyUSDT).principalOf(addrs.usdt, addrs.minter);
        console.log("Total balance before:", total);
        console.log("Principal before:", principal);
        console.log("Yield before:", total - principal);
    }

    function _logUSDSBefore(NetworkAddresses memory addrs) internal view {
        console.log("\n--- USDS Strategy ---");
        console.log("Strategy:", addrs.yieldStrategyUSDS);

        uint256 total = MockYieldStrategy(addrs.yieldStrategyUSDS).totalBalanceOf(addrs.usds, addrs.minter);
        uint256 principal = MockYieldStrategy(addrs.yieldStrategyUSDS).principalOf(addrs.usds, addrs.minter);
        console.log("Total balance before:", total);
        console.log("Principal before:", principal);
        console.log("Yield before:", total - principal);
    }

    function _logDOLABefore(NetworkAddresses memory addrs) internal view {
        if (addrs.yieldStrategyDola == address(0)) return;

        console.log("\n--- DOLA Strategy ---");
        console.log("Strategy:", addrs.yieldStrategyDola);
        console.log("MockAutoDOLA:", addrs.mockAutoDola);

        uint256 total = AutoDolaYieldStrategy(addrs.yieldStrategyDola).totalBalanceOf(addrs.dola, addrs.minter);
        uint256 principal = AutoDolaYieldStrategy(addrs.yieldStrategyDola).principalOf(addrs.dola, addrs.minter);
        console.log("Total balance before:", total);
        console.log("Principal before:", principal);
        console.log("Yield before:", total > principal ? total - principal : 0);
    }

    function _logResults(NetworkAddresses memory addrs) internal view {
        uint256 usdtTotal = MockYieldStrategy(addrs.yieldStrategyUSDT).totalBalanceOf(addrs.usdt, addrs.minter);
        uint256 usdtPrincipal = MockYieldStrategy(addrs.yieldStrategyUSDT).principalOf(addrs.usdt, addrs.minter);
        uint256 usdtYield = usdtTotal - usdtPrincipal;
        console.log("USDT yield after:", usdtYield);

        uint256 usdsTotal = MockYieldStrategy(addrs.yieldStrategyUSDS).totalBalanceOf(addrs.usds, addrs.minter);
        uint256 usdsPrincipal = MockYieldStrategy(addrs.yieldStrategyUSDS).principalOf(addrs.usds, addrs.minter);
        uint256 usdsYield = usdsTotal - usdsPrincipal;
        console.log("USDS yield after:", usdsYield);

        uint256 dolaYield = 0;
        if (addrs.yieldStrategyDola != address(0)) {
            uint256 dolaTotal = AutoDolaYieldStrategy(addrs.yieldStrategyDola).totalBalanceOf(addrs.dola, addrs.minter);
            uint256 dolaPrincipal = AutoDolaYieldStrategy(addrs.yieldStrategyDola).principalOf(addrs.dola, addrs.minter);
            dolaYield = dolaTotal > dolaPrincipal ? dolaTotal - dolaPrincipal : 0;
            console.log("DOLA yield after:", dolaYield);
        }

        // Total in USD equivalent (convert 18 decimal tokens to 6 decimals for display)
        uint256 totalYieldUsd = usdtYield + (usdsYield / 1e12) + (dolaYield / 1e12);
        console.log("\nTotal yield (USD equiv, 6 decimals):", totalYieldUsd);
    }
}
