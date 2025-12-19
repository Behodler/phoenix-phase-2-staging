// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/mocks/MockPhUSD.sol";
import "../src/mocks/MockRewardToken.sol";
import "../src/mocks/MockYieldStrategy.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title DeployMocks
 * @notice Deployment script for Phase 2 contracts on local Anvil
 * @dev Follows IntegrationChecklist.md deployment sequence
 */
contract DeployMocks is Script {
    // Deployment addresses
    MockPhUSD public phUSD;
    MockRewardToken public rewardToken;
    MockYieldStrategy public yieldStrategy;
    PhusdStableMinter public minter;
    PhlimboEA public phlimbo;

    // Progress tracking structure
    struct ContractDeployment {
        string name;
        address addr;
        bool deployed;
        bool configured;
        uint256 deployGas;
        uint256 configGas;
    }

    // Track all deployments
    mapping(string => ContractDeployment) public deployments;
    string[] public contractNames;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Phase 2 contracts to Anvil...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // ====== PHASE 1: Pre-Deployment (Mock Contracts) ======
        console.log("\n=== Phase 1: Deploying Mock Contracts ===");

        uint256 gasBefore = gasleft();
        phUSD = new MockPhUSD();
        _trackDeployment("MockPhUSD", address(phUSD), gasBefore - gasleft());
        console.log("MockPhUSD deployed at:", address(phUSD));

        gasBefore = gasleft();
        rewardToken = new MockRewardToken();
        _trackDeployment("MockRewardToken", address(rewardToken), gasBefore - gasleft());
        console.log("MockRewardToken deployed at:", address(rewardToken));

        gasBefore = gasleft();
        yieldStrategy = new MockYieldStrategy();
        _trackDeployment("MockYieldStrategy", address(yieldStrategy), gasBefore - gasleft());
        console.log("MockYieldStrategy deployed at:", address(yieldStrategy));

        // ====== PHASE 2: Core Contract Deployment ======
        console.log("\n=== Phase 2: Deploying Core Contracts ===");

        // 1. Deploy PhusdStableMinter
        gasBefore = gasleft();
        minter = new PhusdStableMinter(address(phUSD));
        _trackDeployment("PhusdStableMinter", address(minter), gasBefore - gasleft());
        console.log("PhusdStableMinter deployed at:", address(minter));

        // 2. Deploy PhlimboEA (note: StableYieldAccumulator will be mock for now)
        // For simplicity, we're using the yield strategy address as accumulator
        // In full deployment, this would be the actual StableYieldAccumulator
        gasBefore = gasleft();
        phlimbo = new PhlimboEA(
            address(phUSD),           // _phUSD
            address(rewardToken),     // _rewardToken
            address(yieldStrategy),   // _yieldAccumulator (using yield strategy as mock accumulator)
            0.1e18                    // _alpha (10% EMA smoothing)
        );
        _trackDeployment("PhlimboEA", address(phlimbo), gasBefore - gasleft());
        console.log("PhlimboEA deployed at:", address(phlimbo));

        // ====== PHASE 3: Token Authorization ======
        console.log("\n=== Phase 3: Token Authorization ===");

        gasBefore = gasleft();
        // Authorize PhlimboEA as phUSD minter
        phUSD.setMinter(address(phlimbo), true);
        console.log("Authorized PhlimboEA as phUSD minter");

        // Authorize PhusdStableMinter as phUSD minter
        phUSD.setMinter(address(minter), true);
        console.log("Authorized PhusdStableMinter as phUSD minter");
        uint256 authGas = gasBefore - gasleft();

        // ====== PHASE 4: YieldStrategy Configuration ======
        console.log("\n=== Phase 4: YieldStrategy Configuration ===");

        gasBefore = gasleft();
        // Authorize minter as client on yield strategy
        yieldStrategy.setClient(address(minter), true);
        console.log("Authorized minter as yield strategy client");

        // Authorize phlimbo as withdrawer (for collecting rewards)
        yieldStrategy.setWithdrawer(address(phlimbo), true);
        console.log("Authorized phlimbo as yield strategy withdrawer");
        uint256 ysConfigGas = gasBefore - gasleft();

        // ====== PHASE 5: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 5: PhusdStableMinter Configuration ===");

        gasBefore = gasleft();
        // Approve yield strategy for reward token
        minter.approveYS(address(rewardToken), address(yieldStrategy));
        console.log("Approved yield strategy for reward token");

        // Register reward token as stablecoin (6 decimals like USDC)
        minter.registerStablecoin(
            address(rewardToken),    // stablecoin
            address(yieldStrategy),  // yieldStrategy
            1e18,                    // exchangeRate (1:1)
            6                        // decimals
        );
        console.log("Registered reward token as stablecoin");
        uint256 minterConfigGas = gasBefore - gasleft();

        // Mark configurations as complete
        _markConfigured("MockPhUSD", authGas / 2);
        _markConfigured("MockRewardToken", 0);
        _markConfigured("MockYieldStrategy", ysConfigGas);
        _markConfigured("PhusdStableMinter", minterConfigGas);
        _markConfigured("PhlimboEA", authGas / 2);

        // ====== PHASE 6: Phlimbo Configuration ======
        console.log("\n=== Phase 6: Phlimbo Configuration ===");

        gasBefore = gasleft();
        // Set desired APY (5% = 500 basis points) - two-step process
        phlimbo.setDesiredAPY(500);
        console.log("Set desired APY (preview): 500 bps");

        // Wait for next block (simulate block advancement)
        vm.roll(block.number + 1);

        // Commit APY change
        phlimbo.setDesiredAPY(500);
        console.log("Set desired APY (commit): 500 bps");
        uint256 phlimboConfigGas = gasBefore - gasleft();

        // Update phlimbo config gas
        deployments["PhlimboEA"].configGas += phlimboConfigGas;

        vm.stopBroadcast();

        // ====== Write Progress File ======
        console.log("\n=== Writing Deployment Progress ===");
        _writeProgressFile();

        console.log("\n=== Deployment Complete ===");
        console.log("All contracts deployed and configured successfully!");
    }

    /**
     * @dev Track contract deployment
     */
    function _trackDeployment(string memory name, address addr, uint256 gas) internal {
        deployments[name] = ContractDeployment({
            name: name,
            addr: addr,
            deployed: true,
            configured: false,
            deployGas: gas,
            configGas: 0
        });
        contractNames.push(name);
    }

    /**
     * @dev Mark contract as configured
     */
    function _markConfigured(string memory name, uint256 gas) internal {
        deployments[name].configured = true;
        deployments[name].configGas = gas;
    }

    /**
     * @dev Write progress file in JSON format
     */
    function _writeProgressFile() internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": 31337,');
        json = string.concat(json, '"networkName": "anvil",');
        json = string.concat(json, '"deploymentStatus": "completed",');
        json = string.concat(json, '"contracts": {');

        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            ContractDeployment memory deployment = deployments[name];

            if (i > 0) json = string.concat(json, ",");

            json = string.concat(json, '"', name, '": {');
            json = string.concat(json, '"address": "', vm.toString(deployment.addr), '",');
            json = string.concat(json, '"deployed": ', deployment.deployed ? "true" : "false", ",");
            json = string.concat(json, '"configured": ', deployment.configured ? "true" : "false", ",");
            json = string.concat(json, '"deployGas": ', vm.toString(deployment.deployGas), ",");
            json = string.concat(json, '"configGas": ', vm.toString(deployment.configGas));
            json = string.concat(json, "}");
        }

        json = string.concat(json, "}}");

        // Write to server/deployments/progress.31337.json
        vm.writeFile("server/deployments/progress.31337.json", json);
        console.log("Progress file written to: server/deployments/progress.31337.json");
    }
}
