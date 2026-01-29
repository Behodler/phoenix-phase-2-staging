// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/mocks/MockPhUSD.sol";
import "../src/mocks/MockRewardToken.sol";
import "../src/mocks/MockUSDT.sol";
import "../src/mocks/MockUSDS.sol";
import "../src/mocks/MockDola.sol";
import "../src/mocks/MockToke.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockMainRewarder.sol";
import "../src/mocks/MockYieldStrategy.sol";
import "../src/mocks/MockEYE.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phlimbo-ea/interfaces/IPhlimbo.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@pauser/Pauser.sol";
import {AutoPoolYieldStrategy} from "@vault/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import "../src/views/DepositView.sol";

/**
 * @title DeployMocksSepolia
 * @notice Deployment script for Phase 2 contracts on Sepolia testnet with resumable progress
 * @dev Key features:
 *      - Reads from existing progress.11155111.json if it exists (does NOT delete it)
 *      - Skips already-deployed contracts based on progress file
 *      - Skips already-configured contracts based on progress file
 *      - Updates progress.11155111.json after EACH successful deployment/configuration step
 *      - Uses Sepolia chain ID (11155111) in progress file path
 *
 * Architecture Overview (simplified after StableYieldAccumulator removal):
 * - Multiple YieldStrategies (vaults) accumulate yield from different stablecoins
 * - PhusdStableMinter manages stablecoin deposits and phUSD minting
 * - Phlimbo handles staking and reward distribution via collectReward()
 * - Rewards are injected directly into Phlimbo through collectReward
 */
contract DeployMocksSepolia is Script {
    // Deployment addresses - loaded from progress file or set during deployment
    address public phUSD;
    address public rewardToken; // USDC - the consolidated reward token
    address public usdt;
    address public usds;
    address public dola;
    address public toke;
    address public mockAutoDola;
    address public mockMainRewarder;
    address public mockAutoUSDC;
    address public mockMainRewarderUSDC;
    address public yieldStrategyUSDT;
    address public yieldStrategyUSDS;
    address public yieldStrategyDola;
    address public yieldStrategyUSDC;
    address public minter;
    address public phlimbo;
    address public eyeToken;
    address public pauser;
    address public depositView;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.11155111.json";
    uint256 constant CHAIN_ID = 11155111;
    string constant NETWORK_NAME = "sepolia";

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
    bool progressFileExists;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_SEPOLIA_pk");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Phase 2 contracts to Sepolia...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Sepolia (11155111)");

        // Load existing progress file if it exists
        _loadProgressFile();

        vm.startBroadcast(deployerPrivateKey);

        // ====== PHASE 1: Token Deployment ======
        console.log("\n=== Phase 1: Deploying Tokens ===");

        _deployMockPhUSD();
        _deployMockUSDC();
        _deployMockUSDT();
        _deployMockUSDS();
        _deployMockDola();
        _deployMockToke();

        // ====== PHASE 1.5: EYE Token and Pauser Deployment ======
        console.log("\n=== Phase 1.5: Deploying EYE Token and Pauser ===");

        _deployMockEYE();
        _deployPauser(deployer);

        // ====== PHASE 2: Yield Strategy Deployment ======
        console.log("\n=== Phase 2: Deploying Yield Strategies ===");

        _deployYieldStrategyUSDT();
        _deployYieldStrategyUSDS();

        // ====== PHASE 2.5: AutoDola Infrastructure for DOLA YieldStrategy ======
        console.log("\n=== Phase 2.5: Deploying AutoDola Infrastructure ===");

        _deployMockAutoDOLA();
        _deployMockMainRewarder();
        _configureAutoDola();
        _deployYieldStrategyDola(deployer);

        // ====== PHASE 2.6: AutoPool Infrastructure for USDC YieldStrategy ======
        console.log("\n=== Phase 2.6: Deploying AutoPool Infrastructure for USDC ===");

        _deployMockAutoUSDC();
        _deployMockMainRewarderUSDC();
        _configureAutoUSDC();
        _deployYieldStrategyUSDC(deployer);

        // ====== PHASE 3: Core Contract Deployment ======
        console.log("\n=== Phase 3: Deploying Core Contracts ===");

        _deployPhusdStableMinter();
        _deployPhlimboEA();

        // ====== PHASE 4: Token Authorization ======
        console.log("\n=== Phase 4: Token Authorization ===");
        _configureTokenAuthorization();

        // ====== PHASE 5: YieldStrategy Configuration ======
        console.log("\n=== Phase 5: YieldStrategy Configuration ===");
        _configureYieldStrategies();

        // ====== PHASE 6: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 6: PhusdStableMinter Configuration ===");
        _configurePhusdStableMinter();

        // ====== PHASE 7: Phlimbo Configuration ======
        console.log("\n=== Phase 7: Phlimbo Configuration ===");
        _configurePhlimbo();

        // ====== PHASE 8: Pauser Registration ======
        console.log("\n=== Phase 8: Pauser Registration ===");
        _configurePauser();

        // ====== PHASE 9: Seed YieldStrategyDola with PhUSD Minting ======
        console.log("\n=== Phase 9: Seed YieldStrategyDola with PhUSD Minting ===");
        _seedYieldStrategyDola(deployer);

        // ====== PHASE 9.5: Add DOLA Yield to MockAutoDOLA Vault ======
        console.log("\n=== Phase 9.5: Add DOLA Yield to MockAutoDOLA Vault ===");
        _addDolaYield(deployer);

        // ====== PHASE 9.55: Seed YieldStrategyUSDC with PhUSD Minting ======
        console.log("\n=== Phase 9.55: Seed YieldStrategyUSDC with PhUSD Minting ===");
        _seedYieldStrategyUSDC(deployer);

        // ====== PHASE 9.6: Add USDC Yield to MockAutoUSDC Vault ======
        console.log("\n=== Phase 9.6: Add USDC Yield to MockAutoUSDC Vault ===");
        _addUsdcYield(deployer);

        // ====== PHASE 10: Deploy DepositView for UI Polling ======
        console.log("\n=== Phase 10: Deploy DepositView for UI Polling ===");
        _deployDepositView();

        vm.stopBroadcast();

        // ====== Final Progress Update ======
        _markDeploymentComplete();

        console.log("\n=== Deployment Complete ===");
        console.log("All contracts deployed and configured successfully!");
        _printArchitectureSummary();
    }

    // ========================================
    // PHASE 1: Token Deployment Functions
    // ========================================

    function _deployMockPhUSD() internal {
        if (_isDeployed("MockPhUSD")) {
            phUSD = deployments["MockPhUSD"].addr;
            console.log("MockPhUSD already deployed at:", phUSD);
            return;
        }

        uint256 gasBefore = gasleft();
        MockPhUSD token = new MockPhUSD();
        phUSD = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockPhUSD", phUSD, gasUsed);
        _writeProgressFile();
        console.log("MockPhUSD deployed at:", phUSD);
    }

    function _deployMockUSDC() internal {
        if (_isDeployed("MockUSDC")) {
            rewardToken = deployments["MockUSDC"].addr;
            console.log("MockUSDC already deployed at:", rewardToken);
            return;
        }

        uint256 gasBefore = gasleft();
        MockRewardToken token = new MockRewardToken();
        rewardToken = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockUSDC", rewardToken, gasUsed);
        _writeProgressFile();
        console.log("MockUSDC (RewardToken) deployed at:", rewardToken);
    }

    function _deployMockUSDT() internal {
        if (_isDeployed("MockUSDT")) {
            usdt = deployments["MockUSDT"].addr;
            console.log("MockUSDT already deployed at:", usdt);
            return;
        }

        uint256 gasBefore = gasleft();
        MockUSDT token = new MockUSDT();
        usdt = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockUSDT", usdt, gasUsed);
        _writeProgressFile();
        console.log("MockUSDT deployed at:", usdt);
    }

    function _deployMockUSDS() internal {
        if (_isDeployed("MockUSDS")) {
            usds = deployments["MockUSDS"].addr;
            console.log("MockUSDS already deployed at:", usds);
            return;
        }

        uint256 gasBefore = gasleft();
        MockUSDS token = new MockUSDS();
        usds = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockUSDS", usds, gasUsed);
        _writeProgressFile();
        console.log("MockUSDS deployed at:", usds);
    }

    function _deployMockDola() internal {
        if (_isDeployed("MockDola")) {
            dola = deployments["MockDola"].addr;
            console.log("MockDola already deployed at:", dola);
            return;
        }

        uint256 gasBefore = gasleft();
        MockDola token = new MockDola();
        dola = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockDola", dola, gasUsed);
        _writeProgressFile();
        console.log("MockDola deployed at:", dola);
    }

    function _deployMockToke() internal {
        if (_isDeployed("MockToke")) {
            toke = deployments["MockToke"].addr;
            console.log("MockToke already deployed at:", toke);
            return;
        }

        uint256 gasBefore = gasleft();
        MockToke token = new MockToke();
        toke = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockToke", toke, gasUsed);
        _writeProgressFile();
        console.log("MockToke deployed at:", toke);
    }

    // ========================================
    // PHASE 1.5: EYE Token and Pauser
    // ========================================

    function _deployMockEYE() internal {
        if (_isDeployed("MockEYE")) {
            eyeToken = deployments["MockEYE"].addr;
            console.log("MockEYE already deployed at:", eyeToken);
            return;
        }

        uint256 gasBefore = gasleft();
        MockEYE token = new MockEYE();
        eyeToken = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockEYE", eyeToken, gasUsed);
        _writeProgressFile();
        console.log("MockEYE deployed at:", eyeToken);
    }

    function _deployPauser(address /* deployer */) internal {
        if (_isDeployed("Pauser")) {
            pauser = deployments["Pauser"].addr;
            console.log("Pauser already deployed at:", pauser);
            return;
        }

        require(eyeToken != address(0), "MockEYE must be deployed before Pauser");

        uint256 gasBefore = gasleft();
        Pauser p = new Pauser(eyeToken);
        pauser = address(p);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("Pauser", pauser, gasUsed);
        _writeProgressFile();
        console.log("Pauser deployed at:", pauser);
    }

    // ========================================
    // PHASE 2: Yield Strategies
    // ========================================

    function _deployYieldStrategyUSDT() internal {
        if (_isDeployed("YieldStrategyUSDT")) {
            yieldStrategyUSDT = deployments["YieldStrategyUSDT"].addr;
            console.log("YieldStrategyUSDT already deployed at:", yieldStrategyUSDT);
            return;
        }

        uint256 gasBefore = gasleft();
        MockYieldStrategy ys = new MockYieldStrategy();
        yieldStrategyUSDT = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("YieldStrategyUSDT", yieldStrategyUSDT, gasUsed);
        _writeProgressFile();
        console.log("YieldStrategyUSDT deployed at:", yieldStrategyUSDT);
    }

    function _deployYieldStrategyUSDS() internal {
        if (_isDeployed("YieldStrategyUSDS")) {
            yieldStrategyUSDS = deployments["YieldStrategyUSDS"].addr;
            console.log("YieldStrategyUSDS already deployed at:", yieldStrategyUSDS);
            return;
        }

        uint256 gasBefore = gasleft();
        MockYieldStrategy ys = new MockYieldStrategy();
        yieldStrategyUSDS = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("YieldStrategyUSDS", yieldStrategyUSDS, gasUsed);
        _writeProgressFile();
        console.log("YieldStrategyUSDS deployed at:", yieldStrategyUSDS);
    }

    // ========================================
    // PHASE 2.5: AutoDola Infrastructure
    // ========================================

    function _deployMockAutoDOLA() internal {
        if (_isDeployed("MockAutoDOLA")) {
            mockAutoDola = deployments["MockAutoDOLA"].addr;
            console.log("MockAutoDOLA already deployed at:", mockAutoDola);
            return;
        }

        require(dola != address(0), "MockDola must be deployed before MockAutoDOLA");

        uint256 gasBefore = gasleft();
        MockAutoDOLA vault = new MockAutoDOLA(dola);
        mockAutoDola = address(vault);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockAutoDOLA", mockAutoDola, gasUsed);
        _writeProgressFile();
        console.log("MockAutoDOLA deployed at:", mockAutoDola);
    }

    function _deployMockMainRewarder() internal {
        if (_isDeployed("MockMainRewarder")) {
            mockMainRewarder = deployments["MockMainRewarder"].addr;
            console.log("MockMainRewarder already deployed at:", mockMainRewarder);
            return;
        }

        require(mockAutoDola != address(0), "MockAutoDOLA must be deployed before MockMainRewarder");
        require(toke != address(0), "MockToke must be deployed before MockMainRewarder");

        uint256 gasBefore = gasleft();
        MockMainRewarder rewarder = new MockMainRewarder(mockAutoDola, toke);
        mockMainRewarder = address(rewarder);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockMainRewarder", mockMainRewarder, gasUsed);
        _writeProgressFile();
        console.log("MockMainRewarder deployed at:", mockMainRewarder);
    }

    function _configureAutoDola() internal {
        // Check if already configured (we track this in MockAutoDOLA's configured field)
        if (_isConfigured("MockAutoDOLA")) {
            console.log("MockAutoDOLA already configured");
            return;
        }

        require(mockAutoDola != address(0), "MockAutoDOLA must be deployed");
        require(mockMainRewarder != address(0), "MockMainRewarder must be deployed");

        uint256 gasBefore = gasleft();
        MockAutoDOLA(mockAutoDola).setRewarder(mockMainRewarder);
        uint256 gasUsed = gasBefore - gasleft();

        _markConfigured("MockAutoDOLA", gasUsed);
        _writeProgressFile();
        console.log("Wired MockAutoDOLA to use MockMainRewarder");
    }

    function _deployYieldStrategyDola(address deployer) internal {
        if (_isDeployed("YieldStrategyDola")) {
            yieldStrategyDola = deployments["YieldStrategyDola"].addr;
            console.log("YieldStrategyDola already deployed at:", yieldStrategyDola);
            return;
        }

        require(dola != address(0), "MockDola must be deployed");
        require(toke != address(0), "MockToke must be deployed");
        require(mockAutoDola != address(0), "MockAutoDOLA must be deployed");
        require(mockMainRewarder != address(0), "MockMainRewarder must be deployed");

        uint256 gasBefore = gasleft();
        AutoPoolYieldStrategy ys = new AutoPoolYieldStrategy(
            deployer,           // owner
            dola,               // underlyingToken (DOLA)
            toke,               // tokeToken
            mockAutoDola,       // autoPoolVault
            mockMainRewarder    // mainRewarder
        );
        yieldStrategyDola = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("YieldStrategyDola", yieldStrategyDola, gasUsed);
        _writeProgressFile();
        console.log("YieldStrategyDola (AutoPoolYieldStrategy) deployed at:", yieldStrategyDola);
    }

    // ========================================
    // PHASE 2.6: USDC AutoPool Infrastructure
    // ========================================

    function _deployMockAutoUSDC() internal {
        if (_isDeployed("MockAutoUSDC")) {
            mockAutoUSDC = deployments["MockAutoUSDC"].addr;
            console.log("MockAutoUSDC already deployed at:", mockAutoUSDC);
            return;
        }

        require(rewardToken != address(0), "MockUSDC must be deployed before MockAutoUSDC");

        uint256 gasBefore = gasleft();
        MockAutoDOLA vault = new MockAutoDOLA(rewardToken); // Reusing MockAutoDOLA pattern for USDC
        mockAutoUSDC = address(vault);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockAutoUSDC", mockAutoUSDC, gasUsed);
        _writeProgressFile();
        console.log("MockAutoUSDC deployed at:", mockAutoUSDC);
    }

    function _deployMockMainRewarderUSDC() internal {
        if (_isDeployed("MockMainRewarderUSDC")) {
            mockMainRewarderUSDC = deployments["MockMainRewarderUSDC"].addr;
            console.log("MockMainRewarderUSDC already deployed at:", mockMainRewarderUSDC);
            return;
        }

        require(mockAutoUSDC != address(0), "MockAutoUSDC must be deployed before MockMainRewarderUSDC");
        require(toke != address(0), "MockToke must be deployed before MockMainRewarderUSDC");

        uint256 gasBefore = gasleft();
        MockMainRewarder rewarder = new MockMainRewarder(mockAutoUSDC, toke);
        mockMainRewarderUSDC = address(rewarder);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockMainRewarderUSDC", mockMainRewarderUSDC, gasUsed);
        _writeProgressFile();
        console.log("MockMainRewarderUSDC deployed at:", mockMainRewarderUSDC);
    }

    function _configureAutoUSDC() internal {
        // Check if already configured
        if (_isConfigured("MockAutoUSDC")) {
            console.log("MockAutoUSDC already configured");
            return;
        }

        require(mockAutoUSDC != address(0), "MockAutoUSDC must be deployed");
        require(mockMainRewarderUSDC != address(0), "MockMainRewarderUSDC must be deployed");

        uint256 gasBefore = gasleft();
        MockAutoDOLA(mockAutoUSDC).setRewarder(mockMainRewarderUSDC);
        uint256 gasUsed = gasBefore - gasleft();

        _markConfigured("MockAutoUSDC", gasUsed);
        _writeProgressFile();
        console.log("Wired MockAutoUSDC to use MockMainRewarderUSDC");
    }

    function _deployYieldStrategyUSDC(address deployer) internal {
        if (_isDeployed("YieldStrategyUSDC")) {
            yieldStrategyUSDC = deployments["YieldStrategyUSDC"].addr;
            console.log("YieldStrategyUSDC already deployed at:", yieldStrategyUSDC);
            return;
        }

        require(rewardToken != address(0), "MockUSDC must be deployed");
        require(toke != address(0), "MockToke must be deployed");
        require(mockAutoUSDC != address(0), "MockAutoUSDC must be deployed");
        require(mockMainRewarderUSDC != address(0), "MockMainRewarderUSDC must be deployed");

        uint256 gasBefore = gasleft();
        AutoPoolYieldStrategy ys = new AutoPoolYieldStrategy(
            deployer,               // owner
            rewardToken,            // underlyingToken (USDC)
            toke,                   // tokeToken
            mockAutoUSDC,           // autoPoolVault
            mockMainRewarderUSDC    // mainRewarder
        );
        yieldStrategyUSDC = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("YieldStrategyUSDC", yieldStrategyUSDC, gasUsed);
        _writeProgressFile();
        console.log("YieldStrategyUSDC (AutoPoolYieldStrategy) deployed at:", yieldStrategyUSDC);
    }

    // ========================================
    // PHASE 3: Core Contract Deployment
    // ========================================

    function _deployPhusdStableMinter() internal {
        if (_isDeployed("PhusdStableMinter")) {
            minter = deployments["PhusdStableMinter"].addr;
            console.log("PhusdStableMinter already deployed at:", minter);
            return;
        }

        require(phUSD != address(0), "MockPhUSD must be deployed");

        uint256 gasBefore = gasleft();
        PhusdStableMinter m = new PhusdStableMinter(phUSD);
        minter = address(m);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("PhusdStableMinter", minter, gasUsed);
        _writeProgressFile();
        console.log("PhusdStableMinter deployed at:", minter);
    }

    function _deployPhlimboEA() internal {
        if (_isDeployed("PhlimboEA")) {
            phlimbo = deployments["PhlimboEA"].addr;
            console.log("PhlimboEA already deployed at:", phlimbo);
            return;
        }

        require(phUSD != address(0), "MockPhUSD must be deployed");
        require(rewardToken != address(0), "MockUSDC must be deployed");

        uint256 oneMonthInSeconds = 2629746; // 30.44 days

        uint256 gasBefore = gasleft();
        PhlimboEA p = new PhlimboEA(
            phUSD,              // _phUSD
            rewardToken,        // _rewardToken (USDC)
            oneMonthInSeconds   // _depletionDuration (1 month)
        );
        phlimbo = address(p);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("PhlimboEA", phlimbo, gasUsed);
        _writeProgressFile();
        console.log("PhlimboEA deployed at:", phlimbo);
        console.log("  - Depletion window:", oneMonthInSeconds, "seconds (1 month / 30.44 days)");
    }

    // ========================================
    // PHASE 4: Token Authorization
    // ========================================

    function _configureTokenAuthorization() internal {
        if (_isConfigured("MockPhUSD")) {
            console.log("Token authorization already configured");
            return;
        }

        require(phUSD != address(0), "MockPhUSD must be deployed");
        require(phlimbo != address(0), "PhlimboEA must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");

        uint256 gasBefore = gasleft();

        // Authorize PhlimboEA as phUSD minter
        MockPhUSD(phUSD).setMinter(phlimbo, true);
        console.log("Authorized PhlimboEA as phUSD minter");

        // Authorize PhusdStableMinter as phUSD minter
        MockPhUSD(phUSD).setMinter(minter, true);
        console.log("Authorized PhusdStableMinter as phUSD minter");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("MockPhUSD", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 5: YieldStrategy Configuration
    // ========================================

    function _configureYieldStrategies() internal {
        if (_isConfigured("YieldStrategyUSDT") && _isConfigured("YieldStrategyUSDS") && _isConfigured("YieldStrategyDola") && _isConfigured("YieldStrategyUSDC")) {
            console.log("YieldStrategies already configured");
            return;
        }

        require(yieldStrategyUSDT != address(0), "YieldStrategyUSDT must be deployed");
        require(yieldStrategyUSDS != address(0), "YieldStrategyUSDS must be deployed");
        require(yieldStrategyDola != address(0), "YieldStrategyDola must be deployed");
        require(yieldStrategyUSDC != address(0), "YieldStrategyUSDC must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");

        uint256 gasBefore = gasleft();

        // Authorize minter as client on all yield strategies
        MockYieldStrategy(yieldStrategyUSDT).setClient(minter, true);
        MockYieldStrategy(yieldStrategyUSDS).setClient(minter, true);
        AutoPoolYieldStrategy(yieldStrategyDola).setClient(minter, true);
        AutoPoolYieldStrategy(yieldStrategyUSDC).setClient(minter, true);
        console.log("Authorized minter as yield strategy client (all strategies)");

        uint256 gasUsed = gasBefore - gasleft();
        uint256 gasPerStrategy = gasUsed / 4;
        _markConfigured("YieldStrategyUSDT", gasPerStrategy);
        _markConfigured("YieldStrategyUSDS", gasPerStrategy);
        _markConfigured("YieldStrategyDola", gasPerStrategy);
        _markConfigured("YieldStrategyUSDC", gasPerStrategy);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 6: PhusdStableMinter Configuration
    // ========================================

    function _configurePhusdStableMinter() internal {
        if (_isConfigured("PhusdStableMinter")) {
            console.log("PhusdStableMinter already configured");
            return;
        }

        require(minter != address(0), "PhusdStableMinter must be deployed");
        require(usdt != address(0), "MockUSDT must be deployed");
        require(usds != address(0), "MockUSDS must be deployed");
        require(dola != address(0), "MockDola must be deployed");
        require(rewardToken != address(0), "MockUSDC must be deployed");
        require(yieldStrategyUSDT != address(0), "YieldStrategyUSDT must be deployed");
        require(yieldStrategyUSDS != address(0), "YieldStrategyUSDS must be deployed");
        require(yieldStrategyDola != address(0), "YieldStrategyDola must be deployed");
        require(yieldStrategyUSDC != address(0), "YieldStrategyUSDC must be deployed");

        uint256 gasBefore = gasleft();

        PhusdStableMinter m = PhusdStableMinter(minter);

        // Approve yield strategies for their respective tokens
        m.approveYS(usdt, yieldStrategyUSDT);
        m.approveYS(usds, yieldStrategyUSDS);
        m.approveYS(dola, yieldStrategyDola);
        m.approveYS(rewardToken, yieldStrategyUSDC); // USDC
        console.log("Approved yield strategies for their tokens");

        // Register USDT as stablecoin (6 decimals)
        m.registerStablecoin(
            usdt,                   // stablecoin
            yieldStrategyUSDT,      // yieldStrategy
            1e18,                   // exchangeRate (1:1)
            6                       // decimals
        );
        console.log("Registered USDT as stablecoin");

        // Register USDS as stablecoin (18 decimals)
        m.registerStablecoin(
            usds,                   // stablecoin
            yieldStrategyUSDS,      // yieldStrategy
            1e18,                   // exchangeRate (1:1)
            18                      // decimals
        );
        console.log("Registered USDS as stablecoin");

        // Register DOLA as stablecoin (18 decimals)
        m.registerStablecoin(
            dola,                   // stablecoin
            yieldStrategyDola,      // yieldStrategy
            1e18,                   // exchangeRate (1:1)
            18                      // decimals
        );
        console.log("Registered DOLA as stablecoin");

        // Register USDC as stablecoin (6 decimals)
        m.registerStablecoin(
            rewardToken,            // stablecoin (USDC)
            yieldStrategyUSDC,      // yieldStrategy
            1e18,                   // exchangeRate (1:1)
            6                       // decimals
        );
        console.log("Registered USDC as stablecoin");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("PhusdStableMinter", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 7: Phlimbo Configuration
    // ========================================

    function _configurePhlimbo() internal {
        if (_isConfigured("PhlimboEA")) {
            console.log("PhlimboEA already configured");
            return;
        }

        require(phlimbo != address(0), "PhlimboEA must be deployed");

        uint256 gasBefore = gasleft();

        PhlimboEA p = PhlimboEA(phlimbo);

        // Set desired APY (5% = 500 basis points) - two-step process
        // Step 1: Preview the APY change
        p.setDesiredAPY(500);
        console.log("Set desired APY (preview): 500 bps");

        // Step 2: Commit the APY change
        // On real networks, each transaction is in a separate block
        p.setDesiredAPY(500);
        console.log("Set desired APY (commit): 500 bps");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("PhlimboEA", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 8: Pauser Registration
    // ========================================

    function _configurePauser() internal {
        if (_isConfigured("Pauser")) {
            console.log("Pauser already configured");
            return;
        }

        require(pauser != address(0), "Pauser must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");
        require(phlimbo != address(0), "PhlimboEA must be deployed");

        console.log("CRITICAL: setPauser() must be called BEFORE register()");

        uint256 gasBefore = gasleft();

        Pauser p = Pauser(pauser);

        // Register PhusdStableMinter with Pauser
        PhusdStableMinter(minter).setPauser(pauser);
        console.log("PhusdStableMinter.setPauser() called");
        p.register(minter);
        console.log("Pauser.register(PhusdStableMinter) completed");

        // Register PhlimboEA with Pauser
        PhlimboEA(phlimbo).setPauser(pauser);
        console.log("PhlimboEA.setPauser() called");
        p.register(phlimbo);
        console.log("Pauser.register(PhlimboEA) completed");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("Pauser", gasUsed);
        _writeProgressFile();
        console.log("Both protocol contracts registered with Pauser");
    }

    // ========================================
    // PHASE 9: Seed YieldStrategyDola
    // ========================================

    function _seedYieldStrategyDola(address deployer) internal {
        // Use a special tracking key for seeding
        if (_isConfigured("Seeding")) {
            console.log("YieldStrategyDola already seeded");
            return;
        }

        require(dola != address(0), "MockDola must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");

        uint256 dolaAmount = 5000 * 10**18; // 5000 DOLA

        uint256 gasBefore = gasleft();

        // Approve minter to spend deployer's DOLA
        MockDola(dola).approve(minter, dolaAmount);
        console.log("Approved minter to spend 5000 DOLA");

        // Mint PhUSD by depositing DOLA through the minter
        PhusdStableMinter(minter).mint(dola, dolaAmount);
        console.log("Minted PhUSD with 5000 DOLA");
        console.log("  - DOLA deposited to YieldStrategyDola");
        console.log("  - PhUSD minted to deployer:", deployer);

        uint256 gasUsed = gasBefore - gasleft();

        // Track seeding completion
        _trackDeployment("Seeding", address(0), 0);
        _markConfigured("Seeding", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 9.5: Add DOLA Yield to MockAutoDOLA
    // ========================================

    function _addDolaYield(address /* deployer */) internal {
        // Use a special tracking key for yield addition
        if (_isConfigured("DolaYield")) {
            console.log("DOLA yield already added to MockAutoDOLA vault");
            return;
        }

        require(dola != address(0), "MockDola must be deployed");
        require(mockAutoDola != address(0), "MockAutoDOLA must be deployed");

        uint256 yieldAmount = 1000 * 10**18; // 1000 DOLA

        uint256 gasBefore = gasleft();

        // To create yield, we must transfer DOLA directly to the vault WITHOUT minting shares.
        // This increases totalAssets without increasing totalSupply, raising share price.
        // Using deposit() would mint new shares, keeping share price at 1:1 (no yield).

        // Mint 1000 DOLA directly to the vault address (not to deployer)
        MockDola(dola).mint(mockAutoDola, yieldAmount);
        console.log("Minted 1000 DOLA directly to MockAutoDOLA vault as yield");
        console.log("  - totalAssets increased without minting new shares");
        console.log("  - Share price now > 1, creating claimable yield");
        console.log("  - YieldStrategyDola can claim this yield via AutoPoolYieldStrategy");

        uint256 gasUsed = gasBefore - gasleft();

        // Track yield addition completion
        _trackDeployment("DolaYield", address(0), 0);
        _markConfigured("DolaYield", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 9.55: Seed YieldStrategyUSDC
    // ========================================

    function _seedYieldStrategyUSDC(address deployer) internal {
        // Use a special tracking key for seeding
        if (_isConfigured("UsdcSeeding")) {
            console.log("YieldStrategyUSDC already seeded");
            return;
        }

        require(rewardToken != address(0), "MockUSDC must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");

        uint256 usdcAmount = 5000 * 10**6; // 5000 USDC (6 decimals)

        uint256 gasBefore = gasleft();

        // Approve minter to spend deployer's USDC
        MockRewardToken(rewardToken).approve(minter, usdcAmount);
        console.log("Approved minter to spend 5000 USDC");

        // Mint PhUSD by depositing USDC through the minter
        PhusdStableMinter(minter).mint(rewardToken, usdcAmount);
        console.log("Minted PhUSD with 5000 USDC");
        console.log("  - USDC deposited to YieldStrategyUSDC");
        console.log("  - PhUSD minted to deployer:", deployer);

        uint256 gasUsed = gasBefore - gasleft();

        // Track seeding completion
        _trackDeployment("UsdcSeeding", address(0), 0);
        _markConfigured("UsdcSeeding", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 9.6: Add USDC Yield to MockAutoUSDC
    // ========================================

    function _addUsdcYield(address /* deployer */) internal {
        // Use a special tracking key for yield addition
        if (_isConfigured("UsdcYield")) {
            console.log("USDC yield already added to MockAutoUSDC vault");
            return;
        }

        require(rewardToken != address(0), "MockUSDC must be deployed");
        require(mockAutoUSDC != address(0), "MockAutoUSDC must be deployed");

        uint256 yieldAmount = 1000 * 10**6; // 1000 USDC (6 decimals)

        uint256 gasBefore = gasleft();

        // To create yield, we must transfer USDC directly to the vault WITHOUT minting shares.
        // This increases totalAssets without increasing totalSupply, raising share price.
        // Using deposit() would mint new shares, keeping share price at 1:1 (no yield).

        // Mint 1000 USDC directly to the vault address (not to deployer)
        MockRewardToken(rewardToken).mint(mockAutoUSDC, yieldAmount);
        console.log("Minted 1000 USDC directly to MockAutoUSDC vault as yield");
        console.log("  - totalAssets increased without minting new shares");
        console.log("  - Share price now > 1, creating claimable yield");
        console.log("  - YieldStrategyUSDC can claim this yield via AutoPoolYieldStrategy");

        uint256 gasUsed = gasBefore - gasleft();

        // Track yield addition completion
        _trackDeployment("UsdcYield", address(0), 0);
        _markConfigured("UsdcYield", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 11: Deploy DepositView
    // ========================================

    function _deployDepositView() internal {
        if (_isDeployed("DepositView")) {
            depositView = deployments["DepositView"].addr;
            console.log("DepositView already deployed at:", depositView);
            return;
        }

        require(phlimbo != address(0), "PhlimboEA must be deployed");
        require(phUSD != address(0), "MockPhUSD must be deployed");

        uint256 gasBefore = gasleft();
        DepositView dv = new DepositView(
            IPhlimbo(phlimbo),
            IERC20(phUSD)
        );
        depositView = address(dv);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("DepositView", depositView, gasUsed);
        _markConfigured("DepositView", 0);
        _writeProgressFile();
        console.log("DepositView deployed at:", depositView);
    }

    // ========================================
    // Progress File Management
    // ========================================

    /**
     * @dev Load existing progress file if it exists
     */
    function _loadProgressFile() internal {
        try vm.readFile(PROGRESS_FILE) returns (string memory json) {
            if (bytes(json).length > 0) {
                progressFileExists = true;
                console.log("Found existing progress file, loading...");
                _parseProgressJson(json);
            }
        } catch {
            progressFileExists = false;
            console.log("No existing progress file found, starting fresh deployment");
        }
    }

    /**
     * @dev Parse the progress JSON and populate deployments mapping
     * Note: This is a simplified parser - Foundry's JSON parsing is limited
     */
    function _parseProgressJson(string memory json) internal {
        // We need to extract contract addresses from the JSON
        // Format: "ContractName": {"address": "0x...", "deployed": true, ...}

        string[] memory names = new string[](23);
        names[0] = "MockPhUSD";
        names[1] = "MockUSDC";
        names[2] = "MockUSDT";
        names[3] = "MockUSDS";
        names[4] = "MockDola";
        names[5] = "MockToke";
        names[6] = "MockEYE";
        names[7] = "Pauser";
        names[8] = "YieldStrategyUSDT";
        names[9] = "YieldStrategyUSDS";
        names[10] = "MockAutoDOLA";
        names[11] = "MockMainRewarder";
        names[12] = "YieldStrategyDola";
        names[13] = "MockAutoUSDC";
        names[14] = "MockMainRewarderUSDC";
        names[15] = "YieldStrategyUSDC";
        names[16] = "PhusdStableMinter";
        names[17] = "PhlimboEA";
        names[18] = "DepositView";
        names[19] = "Seeding";
        names[20] = "DolaYield";
        names[21] = "UsdcSeeding";
        names[22] = "UsdcYield";

        for (uint256 i = 0; i < names.length; i++) {
            string memory name = names[i];

            // Try to extract address using Foundry's JSON parsing
            try vm.parseJsonAddress(json, string.concat(".contracts.", name, ".address")) returns (address addr) {
                if (addr != address(0)) {
                    // Try to get deployed status
                    bool deployed = false;
                    try vm.parseJsonBool(json, string.concat(".contracts.", name, ".deployed")) returns (bool d) {
                        deployed = d;
                    } catch {}

                    // Try to get configured status
                    bool configured = false;
                    try vm.parseJsonBool(json, string.concat(".contracts.", name, ".configured")) returns (bool c) {
                        configured = c;
                    } catch {}

                    // Try to get gas values
                    uint256 deployGas = 0;
                    try vm.parseJsonUint(json, string.concat(".contracts.", name, ".deployGas")) returns (uint256 g) {
                        deployGas = g;
                    } catch {}

                    uint256 configGas = 0;
                    try vm.parseJsonUint(json, string.concat(".contracts.", name, ".configGas")) returns (uint256 g) {
                        configGas = g;
                    } catch {}

                    deployments[name] = ContractDeployment({
                        name: name,
                        addr: addr,
                        deployed: deployed,
                        configured: configured,
                        deployGas: deployGas,
                        configGas: configGas
                    });
                    contractNames.push(name);

                    console.log("Loaded from progress:", name, "at", addr);
                }
            } catch {
                // Contract not in progress file, will be deployed
            }
        }
    }

    /**
     * @dev Check if a contract has been deployed
     */
    function _isDeployed(string memory name) internal view returns (bool) {
        return deployments[name].deployed && deployments[name].addr != address(0);
    }

    /**
     * @dev Check if a contract has been configured
     */
    function _isConfigured(string memory name) internal view returns (bool) {
        return deployments[name].configured;
    }

    /**
     * @dev Track contract deployment
     */
    function _trackDeployment(string memory name, address addr, uint256 gas) internal {
        // Check if already in contractNames
        bool found = false;
        for (uint256 i = 0; i < contractNames.length; i++) {
            if (keccak256(bytes(contractNames[i])) == keccak256(bytes(name))) {
                found = true;
                break;
            }
        }
        if (!found) {
            contractNames.push(name);
        }

        deployments[name] = ContractDeployment({
            name: name,
            addr: addr,
            deployed: true,
            configured: false,
            deployGas: gas,
            configGas: 0
        });
    }

    /**
     * @dev Mark contract as configured
     */
    function _markConfigured(string memory name, uint256 gas) internal {
        deployments[name].configured = true;
        deployments[name].configGas = gas;
    }

    /**
     * @dev Mark deployment as complete
     */
    function _markDeploymentComplete() internal {
        // Final write with completed status
        _writeProgressFileWithStatus("completed");
    }

    /**
     * @dev Write progress file with in_progress status
     */
    function _writeProgressFile() internal {
        _writeProgressFileWithStatus("in_progress");
    }

    /**
     * @dev Write progress file in JSON format with specified status
     */
    function _writeProgressFileWithStatus(string memory status) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": ', vm.toString(CHAIN_ID), ",");
        json = string.concat(json, '"networkName": "', NETWORK_NAME, '",');
        json = string.concat(json, '"deploymentStatus": "', status, '",');
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

        // Write to server/deployments/progress.11155111.json
        vm.writeFile(PROGRESS_FILE, json);
        console.log("Progress file updated:", PROGRESS_FILE);
    }

    /**
     * @dev Print architecture summary
     */
    function _printArchitectureSummary() internal pure {
        console.log("");
        console.log("Architecture Summary:");
        console.log("  - USDT -> YieldStrategyUSDT (MockYieldStrategy) -> PhusdStableMinter");
        console.log("  - USDS -> YieldStrategyUSDS (MockYieldStrategy) -> PhusdStableMinter");
        console.log("  - DOLA -> YieldStrategyDola (AutoDolaYieldStrategy) -> PhusdStableMinter");
        console.log("    \\-> AutoDolaYieldStrategy uses real contract with mocked dependencies:");
        console.log("        - MockAutoDOLA (ERC4626 vault)");
        console.log("        - MockMainRewarder (TOKE rewards)");
        console.log("        - MockToke (reward token)");
        console.log("  - Rewards injected directly into Phlimbo via collectReward()");
        console.log("");
        console.log("PhlimboEA Configuration:");
        console.log("  - Depletion window: 2629746 seconds (1 month / 30.44 days)");
        console.log("  - Rewards drip linearly over the depletion period");
        console.log("");
        console.log("Global Pauser System:");
        console.log("  - Pauser contract deployed with MockEYE token");
        console.log("  - PhusdStableMinter registered with Pauser");
        console.log("  - PhlimboEA registered with Pauser");
        console.log("  - Burn 1000 EYE to trigger global pause");
        console.log("");
        console.log("Initial Seeding:");
        console.log("  - 5000 DOLA deposited to YieldStrategyDola via minter.mint()");
        console.log("  - Deployer received 5000 PhUSD");
        console.log("  - YieldStrategyDola now has positive balance");
        console.log("");
        console.log("DOLA Yield Seeding:");
        console.log("  - 1000 DOLA deposited directly to MockAutoDOLA vault");
        console.log("  - This increases share value for YieldStrategyDola");
        console.log("  - AutoDolaYieldStrategy can claim this yield");
        console.log("");
        console.log("USDC Seeding:");
        console.log("  - 5000 USDC deposited to YieldStrategyUSDC via minter.mint()");
        console.log("  - Deployer received 5000 PhUSD");
        console.log("  - YieldStrategyUSDC now has positive balance");
        console.log("");
        console.log("USDC Yield Seeding:");
        console.log("  - 1000 USDC deposited directly to MockAutoUSDC vault");
        console.log("  - This increases share value for YieldStrategyUSDC");
        console.log("  - AutoPoolYieldStrategy can claim this yield");
    }
}
