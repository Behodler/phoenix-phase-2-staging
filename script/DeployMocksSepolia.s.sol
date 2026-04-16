// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/mocks/MockPhUSD.sol";
import "../src/mocks/MockRewardToken.sol";
import "../src/mocks/MockUSDS.sol";
import "../src/mocks/MockSUSDS.sol";
import "../src/mocks/MockDola.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockEYE.sol";
import "../src/mocks/MockSCX.sol";
import "../src/mocks/MockFlax.sol";
import "../src/mocks/MockWBTC.sol";
import "../src/mocks/MockBalancerPool.sol";
import "../src/mocks/MockBalancerVault.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phlimbo-ea/interfaces/IPhlimbo.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@pauser/Pauser.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "../src/views/DepositView.sol";
import "../src/views/ViewRouter.sol";
import "../src/views/DepositPageView.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
import {INFTMinter as INFTMinterView} from "@yield-claim-nft/interfaces/INFTMinter.sol";
import {NFTMinter} from "@yield-claim-nft/NFTMinter.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import {Burner} from "@yield-claim-nft/dispatchers/Burner.sol";
import {BalancerPooler} from "@yield-claim-nft/dispatchers/BalancerPooler.sol";
import {Gather} from "@yield-claim-nft/dispatchers/Gather.sol";

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
 * Architecture Overview:
 * - Multiple YieldStrategies (vaults) accumulate yield from different stablecoins
 * - PhusdStableMinter manages stablecoin deposits and phUSD minting
 * - StableYieldAccumulator gathers yield from all strategies and offers to users for discounted USDC
 * - USDC is then injected into Phlimbo for distribution via collectReward()
 * - Phlimbo handles staking and reward distribution
 * - NFTMinter infrastructure for claim gating via dispatchers
 */
contract DeployMocksSepolia is Script {
    // Deployment addresses - loaded from progress file or set during deployment
    address public phUSD;
    address public rewardToken; // USDC - the consolidated reward token
    address public usds;
    address public susds;
    address public dola;
    address public mockAutoDola;
    address public mockAutoUSDC;
    address public yieldStrategyDola;
    address public yieldStrategyUSDC;
    address public minter;
    address public phlimbo;
    address public eyeToken;
    address public mockSCX;
    address public mockFlax;
    address public mockWBTC;
    address public pauser;
    address public stableYieldAccumulator;
    address public depositView;
    address public viewRouter;
    address public depositPageView;
    address public mintPageView;

    // NFTMinter infrastructure
    address public mockBalancerPool;
    address public mockBalancerVault;
    address public nftMinter;
    address public burnRecorder;
    address public burnerEYE;
    address public burnerSCX;
    address public burnerFlax;
    address public balancerPooler;
    address public gatherWBTC;

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
    bool previewMode;

    function run() external {
        previewMode = vm.envOr("PREVIEW_MODE", false);
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
        _deployMockUSDS();
        _deployMockSUSDS(deployer);
        _deployMockDola();

        // ====== PHASE 1.5: EYE Token and Pauser Deployment ======
        console.log("\n=== Phase 1.5: Deploying EYE Token and Pauser ===");

        _deployMockEYE();
        _deployMockSCX();
        _deployMockFlax();
        _deployMockWBTC();
        _deployPauser(deployer);

        // ====== PHASE 2.5: AutoDOLA ERC4626 Infrastructure for DOLA YieldStrategy ======
        console.log("\n=== Phase 2.5: Deploying AutoDOLA ERC4626 Infrastructure ===");

        _deployMockAutoDOLA();
        _deployYieldStrategyDola(deployer);

        // ====== PHASE 2.6: AutoUSDC ERC4626 Infrastructure for USDC YieldStrategy ======
        console.log("\n=== Phase 2.6: Deploying AutoUSDC ERC4626 Infrastructure ===");

        _deployMockAutoUSDC();
        _deployYieldStrategyUSDC(deployer);

        // ====== PHASE 3: Core Contract Deployment ======
        console.log("\n=== Phase 3: Deploying Core Contracts ===");

        _deployPhusdStableMinter();
        _deployPhlimboEA();
        _deployStableYieldAccumulator();

        // ====== PHASE 3.5: NFTMinter Infrastructure ======
        console.log("\n=== Phase 3.5: Deploying NFTMinter Infrastructure ===");

        _deployMockBalancerPool();
        _deployMockBalancerVault();
        _wireBalancerPool();
        _deployNFTMinter(deployer);
        _deployBurnRecorder(deployer);
        _deployBurnerEYE(deployer);
        _deployBurnerSCX(deployer);
        _deployBurnerFlax(deployer);
        _deployBalancerPooler(deployer);
        _deployGatherWBTC(deployer);
        _authorizeBurnersOnBurnRecorder();

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

        // ====== PHASE 7.5: StableYieldAccumulator Configuration ======
        console.log("\n=== Phase 7.5: StableYieldAccumulator Configuration ===");
        _configureStableYieldAccumulator();

        // ====== PHASE 8: Pauser Registration ======
        console.log("\n=== Phase 8: Pauser Registration ===");
        _configurePauser();

        // ====== PHASE 8.5: NFTMinter Configuration ======
        console.log("\n=== Phase 8.5: NFTMinter Configuration ===");
        _registerDispatchersWithNFTMinter();
        _setMintersOnDispatchers();

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

        // ====== PHASE 11: Deploy ViewRouter + DepositPageView + MintPageView ======
        console.log("\n=== Phase 11: Deploy ViewRouter + DepositPageView + MintPageView ===");
        _deployViewRouter();
        _deployDepositPageView();
        _deployMintPageView();
        _registerPagesWithViewRouter();

        vm.stopBroadcast();

        // ====== Mark all contracts as configured ======
        // Contracts that don't have dedicated configuration steps (mock tokens,
        // view contracts, etc.) or whose configuration happens inside another
        // function's scope need to be explicitly marked here.
        _markConfigured("MockUSDC", 0);
        _markConfigured("MockUSDS", 0);
        _markConfigured("MockSUSDS", 0);
        _markConfigured("MockDola", 0);
        _markConfigured("MockEYE", 0);
        _markConfigured("MockSCX", 0);
        _markConfigured("MockFlax", 0);
        _markConfigured("MockWBTC", 0);
        _markConfigured("MockBalancerVault", 0);
        _markConfigured("NFTMinter", 0);
        _markConfigured("BurnRecorder", 0);
        _markConfigured("BurnerEYE", 0);
        _markConfigured("BurnerSCX", 0);
        _markConfigured("BurnerFlax", 0);
        _markConfigured("BalancerPooler", 0);
        _markConfigured("GatherWBTC", 0);
        _markConfigured("ViewRouter", 0);
        _markConfigured("DepositPageView", 0);
        _markConfigured("MintPageView", 0);

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

    function _deployMockSUSDS(address deployer) internal {
        if (_isDeployed("MockSUSDS")) {
            susds = deployments["MockSUSDS"].addr;
            console.log("MockSUSDS already deployed at:", susds);
            return;
        }

        require(usds != address(0), "MockUSDS must be deployed before MockSUSDS");

        uint256 gasBefore = gasleft();
        MockSUSDS token = new MockSUSDS(usds);
        susds = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        // Deposit initial USDS into MockSUSDS to establish baseline shares
        uint256 initialSusdsDeposit = 10_000 * 10**18; // 10,000 USDS
        MockUSDS(usds).approve(susds, initialSusdsDeposit);
        MockSUSDS(susds).deposit(initialSusdsDeposit, deployer);
        console.log("Deposited 10,000 USDS into MockSUSDS (baseline shares established)");

        _trackDeployment("MockSUSDS", susds, gasUsed);
        _writeProgressFile();
        console.log("MockSUSDS deployed at:", susds);
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

    function _deployMockSCX() internal {
        if (_isDeployed("MockSCX")) {
            mockSCX = deployments["MockSCX"].addr;
            console.log("MockSCX already deployed at:", mockSCX);
            return;
        }

        uint256 gasBefore = gasleft();
        MockSCX token = new MockSCX();
        mockSCX = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockSCX", mockSCX, gasUsed);
        _writeProgressFile();
        console.log("MockSCX deployed at:", mockSCX);
    }

    function _deployMockFlax() internal {
        if (_isDeployed("MockFlax")) {
            mockFlax = deployments["MockFlax"].addr;
            console.log("MockFlax already deployed at:", mockFlax);
            return;
        }

        uint256 gasBefore = gasleft();
        MockFlax token = new MockFlax();
        mockFlax = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockFlax", mockFlax, gasUsed);
        _writeProgressFile();
        console.log("MockFlax deployed at:", mockFlax);
    }

    function _deployMockWBTC() internal {
        if (_isDeployed("MockWBTC")) {
            mockWBTC = deployments["MockWBTC"].addr;
            console.log("MockWBTC already deployed at:", mockWBTC);
            return;
        }

        uint256 gasBefore = gasleft();
        MockWBTC token = new MockWBTC();
        mockWBTC = address(token);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockWBTC", mockWBTC, gasUsed);
        _writeProgressFile();
        console.log("MockWBTC deployed at:", mockWBTC);
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

    function _deployYieldStrategyDola(address deployer) internal {
        if (_isDeployed("YieldStrategyDola")) {
            yieldStrategyDola = deployments["YieldStrategyDola"].addr;
            console.log("YieldStrategyDola already deployed at:", yieldStrategyDola);
            return;
        }

        require(dola != address(0), "MockDola must be deployed");
        require(mockAutoDola != address(0), "MockAutoDOLA must be deployed");

        uint256 gasBefore = gasleft();
        ERC4626YieldStrategy ys = new ERC4626YieldStrategy(
            deployer,     // owner
            dola,         // underlyingToken (DOLA)
            mockAutoDola  // erc4626Vault
        );
        yieldStrategyDola = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("YieldStrategyDola", yieldStrategyDola, gasUsed);
        _writeProgressFile();
        console.log("YieldStrategyDola (ERC4626YieldStrategy) deployed at:", yieldStrategyDola);
    }

    // ========================================
    // PHASE 2.6: USDC ERC4626 Infrastructure
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

    function _deployYieldStrategyUSDC(address deployer) internal {
        if (_isDeployed("YieldStrategyUSDC")) {
            yieldStrategyUSDC = deployments["YieldStrategyUSDC"].addr;
            console.log("YieldStrategyUSDC already deployed at:", yieldStrategyUSDC);
            return;
        }

        require(rewardToken != address(0), "MockUSDC must be deployed");
        require(mockAutoUSDC != address(0), "MockAutoUSDC must be deployed");

        uint256 gasBefore = gasleft();
        ERC4626YieldStrategy ys = new ERC4626YieldStrategy(
            deployer,     // owner
            rewardToken,  // underlyingToken (USDC)
            mockAutoUSDC  // erc4626Vault
        );
        yieldStrategyUSDC = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("YieldStrategyUSDC", yieldStrategyUSDC, gasUsed);
        _writeProgressFile();
        console.log("YieldStrategyUSDC (ERC4626YieldStrategy) deployed at:", yieldStrategyUSDC);
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

    function _deployStableYieldAccumulator() internal {
        if (_isDeployed("StableYieldAccumulator")) {
            stableYieldAccumulator = deployments["StableYieldAccumulator"].addr;
            console.log("StableYieldAccumulator already deployed at:", stableYieldAccumulator);
            return;
        }

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = new StableYieldAccumulator();
        stableYieldAccumulator = address(sya);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("StableYieldAccumulator", stableYieldAccumulator, gasUsed);
        _writeProgressFile();
        console.log("StableYieldAccumulator deployed at:", stableYieldAccumulator);
    }

    // ========================================
    // PHASE 3.5: NFTMinter Infrastructure
    // ========================================

    function _deployMockBalancerPool() internal {
        if (_isDeployed("MockBalancerPool")) {
            mockBalancerPool = deployments["MockBalancerPool"].addr;
            console.log("MockBalancerPool already deployed at:", mockBalancerPool);
            return;
        }

        uint256 gasBefore = gasleft();
        MockBalancerPool pool = new MockBalancerPool();
        mockBalancerPool = address(pool);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockBalancerPool", mockBalancerPool, gasUsed);
        _writeProgressFile();
        console.log("MockBalancerPool deployed at:", mockBalancerPool);
    }

    function _deployMockBalancerVault() internal {
        if (_isDeployed("MockBalancerVault")) {
            mockBalancerVault = deployments["MockBalancerVault"].addr;
            console.log("MockBalancerVault already deployed at:", mockBalancerVault);
            return;
        }

        require(mockBalancerPool != address(0), "MockBalancerPool must be deployed before MockBalancerVault");

        uint256 gasBefore = gasleft();
        MockBalancerVault vault = new MockBalancerVault(mockBalancerPool);
        mockBalancerVault = address(vault);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MockBalancerVault", mockBalancerVault, gasUsed);
        _writeProgressFile();
        console.log("MockBalancerVault deployed at:", mockBalancerVault);
    }

    function _wireBalancerPool() internal {
        if (_isConfigured("MockBalancerPool")) {
            console.log("MockBalancerPool already wired to MockBalancerVault");
            return;
        }

        require(mockBalancerPool != address(0), "MockBalancerPool must be deployed");
        require(mockBalancerVault != address(0), "MockBalancerVault must be deployed");

        uint256 gasBefore = gasleft();
        MockBalancerPool(mockBalancerPool).setVault(mockBalancerVault);
        uint256 gasUsed = gasBefore - gasleft();

        _markConfigured("MockBalancerPool", gasUsed);
        _writeProgressFile();
        console.log("Wired MockBalancerPool to recognize MockBalancerVault");
    }

    function _deployNFTMinter(address deployer) internal {
        if (_isDeployed("NFTMinter")) {
            nftMinter = deployments["NFTMinter"].addr;
            console.log("NFTMinter already deployed at:", nftMinter);
            return;
        }

        uint256 gasBefore = gasleft();
        NFTMinter minterNFT = new NFTMinter(deployer);
        nftMinter = address(minterNFT);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("NFTMinter", nftMinter, gasUsed);
        _writeProgressFile();
        console.log("NFTMinter deployed at:", nftMinter);
    }

    function _deployBurnRecorder(address deployer) internal {
        if (_isDeployed("BurnRecorder")) {
            burnRecorder = deployments["BurnRecorder"].addr;
            console.log("BurnRecorder already deployed at:", burnRecorder);
            return;
        }

        uint256 gasBefore = gasleft();
        BurnRecorder recorder = new BurnRecorder(deployer);
        burnRecorder = address(recorder);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnRecorder", burnRecorder, gasUsed);
        _writeProgressFile();
        console.log("BurnRecorder deployed at:", burnRecorder);
    }

    function _deployBurnerEYE(address deployer) internal {
        if (_isDeployed("BurnerEYE")) {
            burnerEYE = deployments["BurnerEYE"].addr;
            console.log("BurnerEYE already deployed at:", burnerEYE);
            return;
        }

        require(eyeToken != address(0), "MockEYE must be deployed");
        require(burnRecorder != address(0), "BurnRecorder must be deployed");

        uint256 gasBefore = gasleft();
        Burner b = new Burner(eyeToken, burnRecorder, deployer);
        burnerEYE = address(b);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnerEYE", burnerEYE, gasUsed);
        _writeProgressFile();
        console.log("BurnerEYE deployed at:", burnerEYE);
    }

    function _deployBurnerSCX(address deployer) internal {
        if (_isDeployed("BurnerSCX")) {
            burnerSCX = deployments["BurnerSCX"].addr;
            console.log("BurnerSCX already deployed at:", burnerSCX);
            return;
        }

        require(mockSCX != address(0), "MockSCX must be deployed");
        require(burnRecorder != address(0), "BurnRecorder must be deployed");

        uint256 gasBefore = gasleft();
        Burner b = new Burner(mockSCX, burnRecorder, deployer);
        burnerSCX = address(b);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnerSCX", burnerSCX, gasUsed);
        _writeProgressFile();
        console.log("BurnerSCX deployed at:", burnerSCX);
    }

    function _deployBurnerFlax(address deployer) internal {
        if (_isDeployed("BurnerFlax")) {
            burnerFlax = deployments["BurnerFlax"].addr;
            console.log("BurnerFlax already deployed at:", burnerFlax);
            return;
        }

        require(mockFlax != address(0), "MockFlax must be deployed");
        require(burnRecorder != address(0), "BurnRecorder must be deployed");

        uint256 gasBefore = gasleft();
        Burner b = new Burner(mockFlax, burnRecorder, deployer);
        burnerFlax = address(b);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnerFlax", burnerFlax, gasUsed);
        _writeProgressFile();
        console.log("BurnerFlax deployed at:", burnerFlax);
    }

    function _deployBalancerPooler(address deployer) internal {
        if (_isDeployed("BalancerPooler")) {
            balancerPooler = deployments["BalancerPooler"].addr;
            console.log("BalancerPooler already deployed at:", balancerPooler);
            return;
        }

        require(susds != address(0), "MockSUSDS must be deployed");
        require(mockBalancerPool != address(0), "MockBalancerPool must be deployed");
        require(mockBalancerVault != address(0), "MockBalancerVault must be deployed");

        uint256 gasBefore = gasleft();
        BalancerPooler bp = new BalancerPooler(
            susds,              // primeToken_ (sUSDS)
            mockBalancerPool,   // pool_ (BPT token)
            mockBalancerVault,  // vault_
            true,               // primeTokenIsFirst_
            deployer            // initialOwner
        );
        balancerPooler = address(bp);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BalancerPooler", balancerPooler, gasUsed);
        _writeProgressFile();
        console.log("BalancerPooler deployed at:", balancerPooler);
    }

    function _deployGatherWBTC(address deployer) internal {
        if (_isDeployed("GatherWBTC")) {
            gatherWBTC = deployments["GatherWBTC"].addr;
            console.log("GatherWBTC already deployed at:", gatherWBTC);
            return;
        }

        require(mockWBTC != address(0), "MockWBTC must be deployed");

        uint256 gasBefore = gasleft();
        Gather g = new Gather(
            mockWBTC,   // token_ (WBTC)
            deployer,   // recipient_
            deployer    // initialOwner
        );
        gatherWBTC = address(g);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("GatherWBTC", gatherWBTC, gasUsed);
        _writeProgressFile();
        console.log("GatherWBTC deployed at:", gatherWBTC);
    }

    function _authorizeBurnersOnBurnRecorder() internal {
        if (_isConfigured("BurnRecorderAuth")) {
            console.log("BurnRecorder burner authorization already configured");
            return;
        }

        require(burnRecorder != address(0), "BurnRecorder must be deployed");
        require(burnerEYE != address(0), "BurnerEYE must be deployed");
        require(burnerSCX != address(0), "BurnerSCX must be deployed");
        require(burnerFlax != address(0), "BurnerFlax must be deployed");

        uint256 gasBefore = gasleft();

        BurnRecorder(burnRecorder).setBurner(burnerEYE, true);
        BurnRecorder(burnRecorder).setBurner(burnerSCX, true);
        BurnRecorder(burnRecorder).setBurner(burnerFlax, true);

        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnRecorderAuth", address(0), 0);
        _markConfigured("BurnRecorderAuth", gasUsed);
        _writeProgressFile();
        console.log("Authorized BurnerEYE, BurnerSCX, BurnerFlax as burners on BurnRecorder");
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
        if (_isConfigured("YieldStrategyDola") && _isConfigured("YieldStrategyUSDC")) {
            console.log("YieldStrategies already configured");
            return;
        }

        require(yieldStrategyDola != address(0), "YieldStrategyDola must be deployed");
        require(yieldStrategyUSDC != address(0), "YieldStrategyUSDC must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");

        uint256 gasBefore = gasleft();

        // Authorize minter as client on all yield strategies
        ERC4626YieldStrategy(yieldStrategyDola).setClient(minter, true);
        ERC4626YieldStrategy(yieldStrategyUSDC).setClient(minter, true);
        console.log("Authorized minter as yield strategy client (all strategies)");

        uint256 gasUsed = gasBefore - gasleft();
        uint256 gasPerStrategy = gasUsed / 2;
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
        require(dola != address(0), "MockDola must be deployed");
        require(rewardToken != address(0), "MockUSDC must be deployed");
        require(yieldStrategyDola != address(0), "YieldStrategyDola must be deployed");
        require(yieldStrategyUSDC != address(0), "YieldStrategyUSDC must be deployed");

        uint256 gasBefore = gasleft();

        PhusdStableMinter m = PhusdStableMinter(minter);

        // Approve yield strategies for their respective tokens
        m.approveYS(dola, yieldStrategyDola);
        m.approveYS(rewardToken, yieldStrategyUSDC); // USDC
        console.log("Approved yield strategies for their tokens");

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
    // PHASE 7.5: StableYieldAccumulator Configuration
    // ========================================

    function _configureStableYieldAccumulator() internal {
        if (_isConfigured("StableYieldAccumulator")) {
            console.log("StableYieldAccumulator already configured");
            return;
        }

        require(stableYieldAccumulator != address(0), "StableYieldAccumulator must be deployed");
        require(rewardToken != address(0), "MockUSDC must be deployed");
        require(phlimbo != address(0), "PhlimboEA must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");
        require(dola != address(0), "MockDola must be deployed");
        require(yieldStrategyDola != address(0), "YieldStrategyDola must be deployed");
        require(yieldStrategyUSDC != address(0), "YieldStrategyUSDC must be deployed");

        uint256 gasBefore = gasleft();

        StableYieldAccumulator sya = StableYieldAccumulator(stableYieldAccumulator);

        // Set reward token to USDC
        sya.setRewardToken(rewardToken);
        console.log("Set reward token to USDC:", rewardToken);

        // Set Phlimbo as the reward recipient
        sya.setPhlimbo(phlimbo);
        console.log("Set Phlimbo as reward recipient:", phlimbo);

        // Set minter address for yield queries
        sya.setMinter(minter);
        console.log("Set minter for yield queries:", minter);

        // Configure USDC token (6 decimals, 1:1 exchange rate)
        sya.setTokenConfig(rewardToken, 6, 1e18);
        console.log("Configured USDC token config (6 decimals, 1:1 rate)");

        // Configure DOLA token (18 decimals, 1:1 exchange rate)
        sya.setTokenConfig(dola, 18, 1e18);
        console.log("Configured DOLA token config (18 decimals, 1:1 rate)");

        // Add YieldStrategyDola to the yield strategy registry
        sya.addYieldStrategy(yieldStrategyDola, dola);
        console.log("Added YieldStrategyDola to yield strategy registry");

        // Add YieldStrategyUSDC to the yield strategy registry
        sya.addYieldStrategy(yieldStrategyUSDC, rewardToken);
        console.log("Added YieldStrategyUSDC to yield strategy registry");

        // Set discount rate (20% = 2000 basis points)
        sya.setDiscountRate(2000);
        console.log("Set discount rate to 2000 basis points (20%)");

        // Approve Phlimbo to spend reward tokens with max approval
        sya.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo to spend reward tokens from StableYieldAccumulator");

        // Authorize StableYieldAccumulator as withdrawer on all yield strategies
        ERC4626YieldStrategy(yieldStrategyDola).setWithdrawer(stableYieldAccumulator, true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyDola");

        ERC4626YieldStrategy(yieldStrategyUSDC).setWithdrawer(stableYieldAccumulator, true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyUSDC");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("StableYieldAccumulator", gasUsed);
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
        require(stableYieldAccumulator != address(0), "StableYieldAccumulator must be deployed");
        require(nftMinter != address(0), "NFTMinter must be deployed");

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

        // Register StableYieldAccumulator with Pauser
        StableYieldAccumulator(stableYieldAccumulator).setPauser(pauser);
        console.log("StableYieldAccumulator.setPauser() called");
        p.register(stableYieldAccumulator);
        console.log("Pauser.register(StableYieldAccumulator) completed");

        // Register NFTMinter with Pauser
        NFTMinter(nftMinter).setPauser(pauser);
        console.log("NFTMinter.setPauser() called");
        p.register(nftMinter);
        console.log("Pauser.register(NFTMinter) completed");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("Pauser", gasUsed);
        _writeProgressFile();
        console.log("All protocol contracts registered with Pauser");
    }

    // ========================================
    // PHASE 8.5: NFTMinter Configuration
    // ========================================

    function _registerDispatchersWithNFTMinter() internal {
        if (_isConfigured("NFTMinterDispatchers")) {
            console.log("NFTMinter dispatchers already registered");
            return;
        }

        require(nftMinter != address(0), "NFTMinter must be deployed");
        require(burnerEYE != address(0), "BurnerEYE must be deployed");
        require(burnerSCX != address(0), "BurnerSCX must be deployed");
        require(burnerFlax != address(0), "BurnerFlax must be deployed");
        require(balancerPooler != address(0), "BalancerPooler must be deployed");
        require(gatherWBTC != address(0), "GatherWBTC must be deployed");

        uint256 gasBefore = gasleft();

        uint256 initialPrice = 100 * 10 ** 18;

        NFTMinter(nftMinter).registerDispatcher(burnerEYE, initialPrice, 200); // 2% growth
        console.log("Registered BurnerEYE dispatcher with NFTMinter (index 1, 2% growth)");

        NFTMinter(nftMinter).registerDispatcher(burnerSCX, initialPrice, 200); // 2% growth
        console.log("Registered BurnerSCX dispatcher with NFTMinter (index 2, 2% growth)");

        NFTMinter(nftMinter).registerDispatcher(burnerFlax, initialPrice, 200); // 2% growth
        console.log("Registered BurnerFlax dispatcher with NFTMinter (index 3, 2% growth)");

        NFTMinter(nftMinter).registerDispatcher(balancerPooler, initialPrice, 10); // 0.1% growth
        console.log("Registered BalancerPooler dispatcher with NFTMinter (index 4, 0.1% growth)");

        NFTMinter(nftMinter).registerDispatcher(gatherWBTC, initialPrice, 1000); // 10% growth
        console.log("Registered GatherWBTC dispatcher with NFTMinter (index 5, 10% growth)");

        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("NFTMinterDispatchers", address(0), 0);
        _markConfigured("NFTMinterDispatchers", gasUsed);
        _writeProgressFile();
    }

    function _setMintersOnDispatchers() internal {
        if (_isConfigured("DispatcherMinters")) {
            console.log("Dispatcher minters already configured");
            return;
        }

        require(nftMinter != address(0), "NFTMinter must be deployed");
        require(burnerEYE != address(0), "BurnerEYE must be deployed");
        require(burnerSCX != address(0), "BurnerSCX must be deployed");
        require(burnerFlax != address(0), "BurnerFlax must be deployed");
        require(balancerPooler != address(0), "BalancerPooler must be deployed");
        require(gatherWBTC != address(0), "GatherWBTC must be deployed");
        require(stableYieldAccumulator != address(0), "StableYieldAccumulator must be deployed");

        uint256 gasBefore = gasleft();

        // Set minter on each dispatcher
        Burner(burnerEYE).setMinter(nftMinter);
        console.log("BurnerEYE.setMinter -> NFTMinter");

        Burner(burnerSCX).setMinter(nftMinter);
        console.log("BurnerSCX.setMinter -> NFTMinter");

        Burner(burnerFlax).setMinter(nftMinter);
        console.log("BurnerFlax.setMinter -> NFTMinter");

        BalancerPooler(balancerPooler).setMinter(nftMinter);
        console.log("BalancerPooler.setMinter -> NFTMinter");

        Gather(gatherWBTC).setMinter(nftMinter);
        console.log("GatherWBTC.setMinter -> NFTMinter");

        // Set NFTMinter on StableYieldAccumulator
        StableYieldAccumulator(stableYieldAccumulator).setNFTMinter(nftMinter);
        console.log("StableYieldAccumulator.setNFTMinter -> NFTMinter");

        // Set StableYieldAccumulator as authorized burner on NFTMinter
        NFTMinter(nftMinter).setAuthorizedBurner(stableYieldAccumulator, true);
        console.log("NFTMinter.setAuthorizedBurner(StableYieldAccumulator, true)");

        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("DispatcherMinters", address(0), 0);
        _markConfigured("DispatcherMinters", gasUsed);
        _writeProgressFile();
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
        console.log("  - YieldStrategyDola can claim this yield via ERC4626YieldStrategy");

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
        console.log("  - YieldStrategyUSDC can claim this yield via ERC4626YieldStrategy");

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
    // PHASE 11: ViewRouter + DepositPageView + MintPageView
    // ========================================

    function _deployViewRouter() internal {
        if (_isDeployed("ViewRouter")) {
            viewRouter = deployments["ViewRouter"].addr;
            console.log("ViewRouter already deployed at:", viewRouter);
            return;
        }

        uint256 gasBefore = gasleft();
        ViewRouter vr = new ViewRouter();
        viewRouter = address(vr);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("ViewRouter", viewRouter, gasUsed);
        _writeProgressFile();
        console.log("ViewRouter deployed at:", viewRouter);
    }

    function _deployDepositPageView() internal {
        if (_isDeployed("DepositPageView")) {
            depositPageView = deployments["DepositPageView"].addr;
            console.log("DepositPageView already deployed at:", depositPageView);
            return;
        }

        require(phlimbo != address(0), "PhlimboEA must be deployed");
        require(phUSD != address(0), "MockPhUSD must be deployed");

        uint256 gasBefore = gasleft();
        DepositPageView dpv = new DepositPageView(
            IPhlimbo(phlimbo),
            IERC20(phUSD)
        );
        depositPageView = address(dpv);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("DepositPageView", depositPageView, gasUsed);
        _writeProgressFile();
        console.log("DepositPageView deployed at:", depositPageView);
    }

    function _deployMintPageView() internal {
        if (_isDeployed("MintPageView")) {
            mintPageView = deployments["MintPageView"].addr;
            console.log("MintPageView already deployed at:", mintPageView);
            return;
        }

        require(nftMinter != address(0), "NFTMinter must be deployed");
        require(burnRecorder != address(0), "BurnRecorder must be deployed");
        require(eyeToken != address(0), "MockEYE must be deployed");
        require(mockSCX != address(0), "MockSCX must be deployed");
        require(mockFlax != address(0), "MockFlax must be deployed");
        require(susds != address(0), "MockSUSDS must be deployed");
        require(mockWBTC != address(0), "MockWBTC must be deployed");

        uint256 gasBefore = gasleft();
        MintPageView mpv = new MintPageView(
            INFTMinterView(nftMinter),
            BurnRecorder(burnRecorder),
            eyeToken,
            mockSCX,
            mockFlax,
            susds,
            mockWBTC
        );
        mintPageView = address(mpv);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MintPageView", mintPageView, gasUsed);
        _writeProgressFile();
        console.log("MintPageView deployed at:", mintPageView);
    }

    function _registerPagesWithViewRouter() internal {
        if (_isConfigured("ViewRouterPages")) {
            console.log("ViewRouter pages already registered");
            return;
        }

        require(viewRouter != address(0), "ViewRouter must be deployed");
        require(depositPageView != address(0), "DepositPageView must be deployed");
        require(mintPageView != address(0), "MintPageView must be deployed");

        uint256 gasBefore = gasleft();

        ViewRouter(viewRouter).setPage(keccak256("deposit"), IPageView(depositPageView));
        console.log("Registered DepositPageView with ViewRouter under key: keccak256('deposit')");

        ViewRouter(viewRouter).setPage(keccak256("mint"), IPageView(mintPageView));
        console.log("Registered MintPageView with ViewRouter under key: keccak256('mint')");

        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("ViewRouterPages", address(0), 0);
        _markConfigured("ViewRouterPages", gasUsed);
        _writeProgressFile();
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

        string[] memory names = new string[](39);
        names[0] = "MockPhUSD";
        names[1] = "MockUSDC";
        names[2] = "MockUSDS";
        names[3] = "MockSUSDS";
        names[4] = "MockDola";
        names[5] = "MockEYE";
        names[6] = "MockSCX";
        names[7] = "MockFlax";
        names[8] = "MockWBTC";
        names[9] = "Pauser";
        names[10] = "MockAutoDOLA";
        names[11] = "YieldStrategyDola";
        names[12] = "MockAutoUSDC";
        names[13] = "YieldStrategyUSDC";
        names[14] = "PhusdStableMinter";
        names[15] = "PhlimboEA";
        names[16] = "StableYieldAccumulator";
        names[17] = "MockBalancerPool";
        names[18] = "MockBalancerVault";
        names[19] = "NFTMinter";
        names[20] = "BurnRecorder";
        names[21] = "BurnerEYE";
        names[22] = "BurnerSCX";
        names[23] = "BurnerFlax";
        names[24] = "BalancerPooler";
        names[25] = "GatherWBTC";
        names[26] = "BurnRecorderAuth";
        names[27] = "NFTMinterDispatchers";
        names[28] = "DispatcherMinters";
        names[29] = "DepositView";
        names[30] = "ViewRouter";
        names[31] = "DepositPageView";
        names[32] = "MintPageView";
        names[33] = "ViewRouterPages";
        names[34] = "Seeding";
        names[35] = "DolaYield";
        names[36] = "UsdcSeeding";
        names[37] = "UsdcYield";
        names[38] = "DeploymentComplete";

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
        if (previewMode) return;
        // Final write with completed status
        _writeProgressFileWithStatus("completed");
    }

    /**
     * @dev Write progress file with in_progress status
     */
    function _writeProgressFile() internal {
        if (previewMode) return;
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
        console.log("  - DOLA -> YieldStrategyDola (ERC4626YieldStrategy) -> PhusdStableMinter");
        console.log("    \\-> ERC4626YieldStrategy wraps MockAutoDOLA (ERC4626 vault)");
        console.log("  - USDC -> YieldStrategyUSDC (ERC4626YieldStrategy) -> PhusdStableMinter");
        console.log("    \\-> ERC4626YieldStrategy wraps MockAutoUSDC (ERC4626 vault)");
        console.log("");
        console.log("StableYieldAccumulator Configuration:");
        console.log("  - Reward token: USDC (MockRewardToken)");
        console.log("  - Discount rate: 20% (2000 basis points)");
        console.log("  - Yield strategies registered: YieldStrategyDola, YieldStrategyUSDC");
        console.log("  - Phlimbo set as reward recipient");
        console.log("  - Minter set for yield queries");
        console.log("  - Authorized as withdrawer on all yield strategies");
        console.log("");
        console.log("Reward Flow:");
        console.log("  - Yield accrues in yield strategies");
        console.log("  - StableYieldAccumulator gathers yield and offers to users for discounted USDC");
        console.log("  - USDC is then injected into Phlimbo via collectReward()");
        console.log("  - Phlimbo distributes rewards to stakers");
        console.log("");
        console.log("PhlimboEA Configuration:");
        console.log("  - Depletion window: 2629746 seconds (1 month / 30.44 days)");
        console.log("  - Rewards drip linearly over the depletion period");
        console.log("");
        console.log("Global Pauser System:");
        console.log("  - Pauser contract deployed with MockEYE token");
        console.log("  - PhusdStableMinter registered with Pauser");
        console.log("  - PhlimboEA registered with Pauser");
        console.log("  - StableYieldAccumulator registered with Pauser");
        console.log("  - NFTMinter registered with Pauser");
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
        console.log("  - AutoDolaYieldStrategy can claim this yield via StableYieldAccumulator");
        console.log("");
        console.log("USDC Seeding:");
        console.log("  - 5000 USDC deposited to YieldStrategyUSDC via minter.mint()");
        console.log("  - Deployer received 5000 PhUSD");
        console.log("  - YieldStrategyUSDC now has positive balance");
        console.log("");
        console.log("USDC Yield Seeding:");
        console.log("  - 1000 USDC deposited directly to MockAutoUSDC vault");
        console.log("  - This increases share value for YieldStrategyUSDC");
        console.log("  - ERC4626YieldStrategy can claim this yield via StableYieldAccumulator");
        console.log("");
        console.log("NFTMinter Infrastructure:");
        console.log("  - NFTMinter (ERC1155) deployed for claim gating");
        console.log("  - BurnRecorder tracks token burns across dispatchers");
        console.log("  - BurnerEYE dispatcher (index 1: burns EYE tokens)");
        console.log("  - BurnerSCX dispatcher (index 2: burns SCX tokens)");
        console.log("  - BurnerFlax dispatcher (index 3: burns Flax tokens)");
        console.log("  - BalancerPooler dispatcher (index 4: sUSDS single-sided add to phUSD/sUSDS pool)");
        console.log("  - GatherWBTC dispatcher (index 5: accumulates WBTC to deployer)");
        console.log("  - StableYieldAccumulator authorized as NFT burner");
        console.log("  - NFTMinter registered with Global Pauser");
    }
}
