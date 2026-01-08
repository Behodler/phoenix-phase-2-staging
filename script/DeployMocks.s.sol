// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/mocks/MockPhUSD.sol";
import "../src/mocks/MockRewardToken.sol";
import "../src/mocks/MockUSDT.sol";
import "../src/mocks/MockDAI.sol";
import "../src/mocks/MockYieldStrategy.sol";
import "../src/mocks/MockEYE.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "@pauser/Pauser.sol";

/**
 * @title DeployMocks
 * @notice Deployment script for Phase 2 contracts on local Anvil
 * @dev Follows the full architecture with StableYieldAccumulator:
 *
 * Architecture Overview:
 * - Multiple YieldStrategies (vaults) accumulate yield from different stablecoins
 * - StableYieldAccumulator aggregates yield from all strategies
 * - External users call claim() on accumulator, paying USDC at a discount
 * - The USDC payment goes to Phlimbo for distribution to stakers
 * - Claimer receives the yield tokens (USDT, DAI, etc.) at a discount
 */
contract DeployMocks is Script {
    // Deployment addresses
    MockPhUSD public phUSD;
    MockRewardToken public rewardToken; // USDC - the consolidated reward token
    MockUSDT public usdt;
    MockDAI public dai;
    MockYieldStrategy public yieldStrategyUSDT;
    MockYieldStrategy public yieldStrategyDAI;
    StableYieldAccumulator public accumulator;
    PhusdStableMinter public minter;
    PhlimboEA public phlimbo;
    MockEYE public eyeToken;
    Pauser public pauser;

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

        // ====== PHASE 1: Token Deployment ======
        console.log("\n=== Phase 1: Deploying Tokens ===");

        uint256 gasBefore = gasleft();
        phUSD = new MockPhUSD();
        _trackDeployment("MockPhUSD", address(phUSD), gasBefore - gasleft());
        console.log("MockPhUSD deployed at:", address(phUSD));

        gasBefore = gasleft();
        rewardToken = new MockRewardToken(); // USDC - reward token for Phlimbo
        _trackDeployment("MockUSDC", address(rewardToken), gasBefore - gasleft());
        console.log("MockUSDC (RewardToken) deployed at:", address(rewardToken));

        gasBefore = gasleft();
        usdt = new MockUSDT();
        _trackDeployment("MockUSDT", address(usdt), gasBefore - gasleft());
        console.log("MockUSDT deployed at:", address(usdt));

        gasBefore = gasleft();
        dai = new MockDAI();
        _trackDeployment("MockDAI", address(dai), gasBefore - gasleft());
        console.log("MockDAI deployed at:", address(dai));

        // ====== PHASE 1.5: EYE Token and Pauser Deployment ======
        console.log("\n=== Phase 1.5: Deploying EYE Token and Pauser ===");

        gasBefore = gasleft();
        eyeToken = new MockEYE();
        _trackDeployment("MockEYE", address(eyeToken), gasBefore - gasleft());
        console.log("MockEYE deployed at:", address(eyeToken));

        gasBefore = gasleft();
        pauser = new Pauser(address(eyeToken));
        _trackDeployment("Pauser", address(pauser), gasBefore - gasleft());
        console.log("Pauser deployed at:", address(pauser));

        // ====== PHASE 2: Yield Strategy Deployment ======
        console.log("\n=== Phase 2: Deploying Yield Strategies ===");

        gasBefore = gasleft();
        yieldStrategyUSDT = new MockYieldStrategy();
        _trackDeployment("YieldStrategyUSDT", address(yieldStrategyUSDT), gasBefore - gasleft());
        console.log("YieldStrategyUSDT deployed at:", address(yieldStrategyUSDT));

        gasBefore = gasleft();
        yieldStrategyDAI = new MockYieldStrategy();
        _trackDeployment("YieldStrategyDAI", address(yieldStrategyDAI), gasBefore - gasleft());
        console.log("YieldStrategyDAI deployed at:", address(yieldStrategyDAI));

        // ====== PHASE 3: Core Contract Deployment ======
        console.log("\n=== Phase 3: Deploying Core Contracts ===");

        // 1. Deploy PhusdStableMinter
        gasBefore = gasleft();
        minter = new PhusdStableMinter(address(phUSD));
        _trackDeployment("PhusdStableMinter", address(minter), gasBefore - gasleft());
        console.log("PhusdStableMinter deployed at:", address(minter));

        // 2. Deploy StableYieldAccumulator
        gasBefore = gasleft();
        accumulator = new StableYieldAccumulator();
        _trackDeployment("StableYieldAccumulator", address(accumulator), gasBefore - gasleft());
        console.log("StableYieldAccumulator deployed at:", address(accumulator));

        // 3. Deploy PhlimboEA with accumulator as yieldAccumulator
        gasBefore = gasleft();
        phlimbo = new PhlimboEA(
            address(phUSD),           // _phUSD
            address(rewardToken),     // _rewardToken (USDC)
            address(accumulator),     // _yieldAccumulator (the real accumulator!)
            0.1e18                    // _alpha (10% EMA smoothing)
        );
        _trackDeployment("PhlimboEA", address(phlimbo), gasBefore - gasleft());
        console.log("PhlimboEA deployed at:", address(phlimbo));

        // ====== PHASE 4: Token Authorization ======
        console.log("\n=== Phase 4: Token Authorization ===");

        gasBefore = gasleft();
        // Authorize PhlimboEA as phUSD minter
        phUSD.setMinter(address(phlimbo), true);
        console.log("Authorized PhlimboEA as phUSD minter");

        // Authorize PhusdStableMinter as phUSD minter
        phUSD.setMinter(address(minter), true);
        console.log("Authorized PhusdStableMinter as phUSD minter");
        uint256 authGas = gasBefore - gasleft();

        // ====== PHASE 5: YieldStrategy Configuration ======
        console.log("\n=== Phase 5: YieldStrategy Configuration ===");

        gasBefore = gasleft();
        // Authorize minter as client on both yield strategies
        yieldStrategyUSDT.setClient(address(minter), true);
        yieldStrategyDAI.setClient(address(minter), true);
        console.log("Authorized minter as yield strategy client (both strategies)");

        // Authorize accumulator as withdrawer on both yield strategies
        yieldStrategyUSDT.setWithdrawer(address(accumulator), true);
        yieldStrategyDAI.setWithdrawer(address(accumulator), true);
        console.log("Authorized accumulator as yield strategy withdrawer (both strategies)");
        uint256 ysConfigGas = gasBefore - gasleft();

        // ====== PHASE 6: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 6: PhusdStableMinter Configuration ===");

        gasBefore = gasleft();
        // Approve yield strategies for their respective tokens
        minter.approveYS(address(usdt), address(yieldStrategyUSDT));
        minter.approveYS(address(dai), address(yieldStrategyDAI));
        console.log("Approved yield strategies for their tokens");

        // Register USDT as stablecoin (6 decimals)
        minter.registerStablecoin(
            address(usdt),              // stablecoin
            address(yieldStrategyUSDT), // yieldStrategy
            1e18,                       // exchangeRate (1:1)
            6                           // decimals
        );
        console.log("Registered USDT as stablecoin");

        // Register DAI as stablecoin (18 decimals)
        minter.registerStablecoin(
            address(dai),               // stablecoin
            address(yieldStrategyDAI),  // yieldStrategy
            1e18,                       // exchangeRate (1:1)
            18                          // decimals
        );
        console.log("Registered DAI as stablecoin");
        uint256 minterConfigGas = gasBefore - gasleft();

        // ====== PHASE 7: StableYieldAccumulator Configuration ======
        console.log("\n=== Phase 7: StableYieldAccumulator Configuration ===");

        gasBefore = gasleft();
        // Set reward token (USDC) - the token claimers pay with
        accumulator.setRewardToken(address(rewardToken));
        console.log("Set reward token (USDC)");

        // Set Phlimbo as recipient
        accumulator.setPhlimbo(address(phlimbo));
        console.log("Set Phlimbo as recipient");

        // Set minter address (for querying yield from strategies)
        accumulator.setMinter(address(minter));
        console.log("Set minter address");

        // Add yield strategies with their underlying tokens
        accumulator.addYieldStrategy(address(yieldStrategyUSDT), address(usdt));
        accumulator.addYieldStrategy(address(yieldStrategyDAI), address(dai));
        console.log("Added yield strategies");

        // Configure token decimals and exchange rates
        accumulator.setTokenConfig(address(usdt), 6, 1e18);   // USDT: 6 decimals, 1:1 rate
        accumulator.setTokenConfig(address(dai), 18, 1e18);   // DAI: 18 decimals, 1:1 rate
        accumulator.setTokenConfig(address(rewardToken), 6, 1e18); // USDC: 6 decimals, 1:1 rate
        console.log("Configured token decimals and exchange rates");

        // Set discount rate (2% = 200 basis points)
        accumulator.setDiscountRate(200);
        console.log("Set discount rate: 200 bps (2%)");

        // Approve Phlimbo to pull reward tokens from accumulator
        accumulator.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo for reward token spending");
        uint256 accumulatorConfigGas = gasBefore - gasleft();

        // ====== PHASE 8: Phlimbo Configuration ======
        console.log("\n=== Phase 8: Phlimbo Configuration ===");

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

        // ====== PHASE 9: Pauser Registration ======
        console.log("\n=== Phase 9: Pauser Registration ===");
        console.log("CRITICAL: setPauser() must be called BEFORE register()");

        gasBefore = gasleft();

        // Register PhusdStableMinter with Pauser
        // Step 1: Set pauser address on contract FIRST
        minter.setPauser(address(pauser));
        console.log("PhusdStableMinter.setPauser() called");
        // Step 2: Register with pauser (validates that pauser() == address(this))
        pauser.register(address(minter));
        console.log("Pauser.register(PhusdStableMinter) completed");

        // Register StableYieldAccumulator with Pauser
        // Step 1: Set pauser address on contract FIRST
        accumulator.setPauser(address(pauser));
        console.log("StableYieldAccumulator.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(accumulator));
        console.log("Pauser.register(StableYieldAccumulator) completed");

        // Register PhlimboEA with Pauser
        // Step 1: Set pauser address on contract FIRST
        phlimbo.setPauser(address(pauser));
        console.log("PhlimboEA.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(phlimbo));
        console.log("Pauser.register(PhlimboEA) completed");

        uint256 pauserConfigGas = gasBefore - gasleft();
        console.log("All 3 protocol contracts registered with Pauser");

        // Mark configurations as complete
        _markConfigured("MockPhUSD", authGas / 2);
        _markConfigured("MockUSDC", 0);
        _markConfigured("MockUSDT", 0);
        _markConfigured("MockDAI", 0);
        _markConfigured("MockEYE", 0);
        _markConfigured("YieldStrategyUSDT", ysConfigGas / 2);
        _markConfigured("YieldStrategyDAI", ysConfigGas / 2);
        _markConfigured("PhusdStableMinter", minterConfigGas);
        _markConfigured("StableYieldAccumulator", accumulatorConfigGas);
        _markConfigured("PhlimboEA", phlimboConfigGas + authGas / 2);
        _markConfigured("Pauser", pauserConfigGas);

        vm.stopBroadcast();

        // ====== Write Progress File ======
        console.log("\n=== Writing Deployment Progress ===");
        _writeProgressFile();

        console.log("\n=== Deployment Complete ===");
        console.log("All contracts deployed and configured successfully!");
        console.log("");
        console.log("Architecture Summary:");
        console.log("  - USDT -> YieldStrategyUSDT -> StableYieldAccumulator");
        console.log("  - DAI  -> YieldStrategyDAI  -> StableYieldAccumulator");
        console.log("  - StableYieldAccumulator.claim() accepts USDC at 2% discount");
        console.log("  - USDC payment goes to Phlimbo for staker rewards");
        console.log("");
        console.log("Global Pauser System:");
        console.log("  - Pauser contract deployed with MockEYE token");
        console.log("  - PhusdStableMinter registered with Pauser");
        console.log("  - StableYieldAccumulator registered with Pauser");
        console.log("  - PhlimboEA registered with Pauser");
        console.log("  - Burn 1000 EYE to trigger global pause");
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
