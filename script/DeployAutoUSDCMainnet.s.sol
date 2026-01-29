// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@pauser/Pauser.sol";
import {AutoPoolYieldStrategy} from "@vault/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployAutoUSDCMainnet
 * @notice Mainnet deployment script for AutoUSDC YieldStrategy integration
 * @dev This script deploys and configures an AutoPoolYieldStrategy for USDC
 *      using Tokemak's autoUSD vault on mainnet.
 *
 * Key features:
 *      - Resumable deployment via progress file (progress.autoUSDC.1.json)
 *      - Preview mode support for dry runs (PREVIEW_MODE=true)
 *      - Gas tracking per step
 *      - Uses existing deployed Phoenix Phase 2 contracts
 *
 * External Contracts (Tokemak/USDC):
 * - USDC:              0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (Circle USDC, 6 decimals)
 * - TOKE:              0x2e9d63788249371f1DFC918a52f8d799F4a38C94 (Tokemak)
 * - autoUSD Vault:     0xa7569A44f348d3D70d8ad5889e50F78E33d80D35 (Tokemak USDC autopool)
 * - MainRewarder:      0x726104cfbd7ece2d1f5b3654a19109a9e2b6c27b (for autoUSD)
 *
 * Previously Deployed Phoenix Phase 2 Contracts:
 * - Pauser:                    0x7c5A8EeF1d836450C019FB036453ac6eC97885a3
 * - PhusdStableMinter:         0x435B0A1884bd0fb5667677C9eb0e59425b1477E5
 * - StableYieldAccumulator:    0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f
 *
 * LEDGER SIGNER:
 * - Index: 46
 * - Owner Address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
contract DeployAutoUSDCMainnet is Script {
    // ==========================================
    //         MAINNET ADDRESSES
    // ==========================================

    // External Protocol Contracts (USDC/Tokemak autoUSD)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;           // Circle USDC (6 decimals)
    address public constant TOKE = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;           // Tokemak TOKE
    address public constant AUTO_USD_VAULT = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35; // Tokemak autoUSD (ERC4626)
    address public constant MAIN_REWARDER_USDC = 0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B; // MainRewarder for autoUSD

    // Previously Deployed Phoenix Phase 2 Contracts
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant ACCUMULATOR = 0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f;

    // Ledger Signer Configuration
    // Index 46 corresponds to owner address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    // Newly deployed contract address
    address public autoUSDCYieldStrategy;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.autoUSDC.1.json";
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    // Progress tracking structure
    struct DeploymentStep {
        string name;
        address addr;
        bool completed;
        uint256 gasUsed;
    }

    // Track all steps
    mapping(string => DeploymentStep) public steps;
    string[] public stepNames;
    bool progressFileExists;
    bool isPreview;

    function run() external {
        console.log("=========================================");
        console.log("  AUTOUSDC YIELDSTRATEGY MAINNET DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- MAINNET ADDRESSES (VERIFY BEFORE DEPLOYMENT) ---");
        console.log("USDC:               ", USDC);
        console.log("TOKE:               ", TOKE);
        console.log("autoUSD Vault:      ", AUTO_USD_VAULT);
        console.log("MainRewarder (USDC):", MAIN_REWARDER_USDC);
        console.log("Pauser:             ", PAUSER);
        console.log("Minter:             ", MINTER);
        console.log("Accumulator:        ", ACCUMULATOR);
        console.log("Owner Address:      ", OWNER_ADDRESS);
        console.log("----------------------------------------------------");

        // Load existing progress file if it exists
        _loadProgressFile();

        // Check if we're in preview mode (dry run without signing)
        isPreview = vm.envOr("PREVIEW_MODE", false);

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - Impersonating owner (no signing required) ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // ====== STEP 1: Deploy AutoPoolYieldStrategy for USDC ======
        console.log("\n=== Step 1: Deploy AutoUSDC YieldStrategy ===");
        _deployAutoUSDCYieldStrategy();

        // ====== STEP 2: Configure YieldStrategy (setClient) ======
        console.log("\n=== Step 2: Configure AutoUSDC YieldStrategy ===");
        _configureAutoUSDCYieldStrategy();

        // ====== STEP 3: Configure Minter for USDC ======
        console.log("\n=== Step 3: Configure Minter for USDC ===");
        _configureMinterForUSDC();

        // ====== STEP 4: Configure Accumulator for USDC ======
        console.log("\n=== Step 4: Configure Accumulator for USDC ===");
        _configureAccumulatorForUSDC();

        // ====== STEP 5: Register with Pauser ======
        console.log("\n=== Step 5: Register with Pauser ===");
        _registerWithPauser();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ====== Final Progress Update ======
        _markDeploymentComplete();

        console.log("\n=== Deployment Complete ===");
        console.log("AutoUSDC YieldStrategy deployed and configured successfully!");
        _printDeploymentSummary();
    }

    // ========================================
    // STEP 1: Deploy AutoPoolYieldStrategy for USDC
    // ========================================

    function _deployAutoUSDCYieldStrategy() internal {
        if (_isStepComplete("DeployAutoUSDCYieldStrategy")) {
            autoUSDCYieldStrategy = steps["DeployAutoUSDCYieldStrategy"].addr;
            console.log("AutoUSDCYieldStrategy already deployed at:", autoUSDCYieldStrategy);
            return;
        }

        uint256 gasBefore = gasleft();

        AutoPoolYieldStrategy ys = new AutoPoolYieldStrategy(
            OWNER_ADDRESS,          // owner
            USDC,                   // underlyingToken (USDC, 6 decimals)
            TOKE,                   // tokeToken
            AUTO_USD_VAULT,         // autoPoolVault (autoUSD)
            MAIN_REWARDER_USDC      // mainRewarder for autoUSD
        );

        autoUSDCYieldStrategy = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackStep("DeployAutoUSDCYieldStrategy", autoUSDCYieldStrategy, gasUsed);
        _writeProgressFile();

        console.log("AutoUSDCYieldStrategy deployed at:", autoUSDCYieldStrategy);
        console.log("  - Owner:", OWNER_ADDRESS);
        console.log("  - USDC:", USDC);
        console.log("  - TOKE:", TOKE);
        console.log("  - autoUSD Vault:", AUTO_USD_VAULT);
        console.log("  - MainRewarder:", MAIN_REWARDER_USDC);
    }

    // ========================================
    // STEP 2: Configure YieldStrategy (setClient)
    // ========================================

    function _configureAutoUSDCYieldStrategy() internal {
        if (_isStepComplete("ConfigureAutoUSDCYieldStrategy")) {
            console.log("AutoUSDCYieldStrategy already configured (setClient)");
            return;
        }

        require(autoUSDCYieldStrategy != address(0), "AutoUSDCYieldStrategy must be deployed");

        uint256 gasBefore = gasleft();

        // Authorize minter as client
        AutoPoolYieldStrategy(autoUSDCYieldStrategy).setClient(MINTER, true);
        console.log("Authorized PhusdStableMinter as client on AutoUSDCYieldStrategy");

        uint256 gasUsed = gasBefore - gasleft();
        _trackStep("ConfigureAutoUSDCYieldStrategy", address(0), gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // STEP 3: Configure Minter for USDC
    // ========================================

    function _configureMinterForUSDC() internal {
        if (_isStepComplete("ConfigureMinterForUSDC")) {
            console.log("Minter already configured for USDC");
            return;
        }

        require(autoUSDCYieldStrategy != address(0), "AutoUSDCYieldStrategy must be deployed");

        uint256 gasBefore = gasleft();

        PhusdStableMinter minter = PhusdStableMinter(MINTER);

        // Approve yield strategy for USDC
        minter.approveYS(USDC, autoUSDCYieldStrategy);
        console.log("Approved AutoUSDCYieldStrategy for USDC at:", autoUSDCYieldStrategy);

        // Register USDC as stablecoin (6 decimals, 1:1 exchange rate)
        // Exchange rate is always 1e18 for 1:1 pegged stablecoins
        minter.registerStablecoin(
            USDC,                   // stablecoin
            autoUSDCYieldStrategy,  // yieldStrategy
            1e18,                   // exchangeRate (1:1 - always 1e18)
            6                       // decimals (USDC has 6 decimals)
        );
        console.log("Registered USDC as stablecoin with AutoUSDCYieldStrategy");
        console.log("  - Exchange rate: 1e18 (1:1)");
        console.log("  - Decimals: 6");

        uint256 gasUsed = gasBefore - gasleft();
        _trackStep("ConfigureMinterForUSDC", address(0), gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // STEP 4: Configure Accumulator for USDC
    // ========================================

    function _configureAccumulatorForUSDC() internal {
        if (_isStepComplete("ConfigureAccumulatorForUSDC")) {
            console.log("Accumulator already configured for USDC");
            return;
        }

        require(autoUSDCYieldStrategy != address(0), "AutoUSDCYieldStrategy must be deployed");

        uint256 gasBefore = gasleft();

        StableYieldAccumulator accumulator = StableYieldAccumulator(ACCUMULATOR);

        // Add YieldStrategy to Accumulator
        // Note: USDC token config (6 decimals, 1e18 rate) is already set in StableYieldAccumulator
        accumulator.addYieldStrategy(autoUSDCYieldStrategy, USDC);
        console.log("Added AutoUSDCYieldStrategy to StableYieldAccumulator at:", autoUSDCYieldStrategy);

        // Authorize Accumulator as Withdrawer on YieldStrategy
        AutoPoolYieldStrategy(autoUSDCYieldStrategy).setWithdrawer(ACCUMULATOR, true);
        console.log("Authorized StableYieldAccumulator as withdrawer on AutoUSDCYieldStrategy");

        uint256 gasUsed = gasBefore - gasleft();
        _trackStep("ConfigureAccumulatorForUSDC", address(0), gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // STEP 5: Register with Pauser
    // ========================================

    function _registerWithPauser() internal {
        if (_isStepComplete("RegisterWithPauser")) {
            console.log("AutoUSDCYieldStrategy already registered with Pauser");
            return;
        }

        require(autoUSDCYieldStrategy != address(0), "AutoUSDCYieldStrategy must be deployed");

        console.log("CRITICAL: setPauser() must be called BEFORE register()");

        uint256 gasBefore = gasleft();

        Pauser pauser = Pauser(PAUSER);

        // First, set the pauser on the YieldStrategy
        AutoPoolYieldStrategy(autoUSDCYieldStrategy).setPauser(PAUSER);
        console.log("AutoUSDCYieldStrategy.setPauser() called");

        // Then register the YieldStrategy with the Pauser
        pauser.register(autoUSDCYieldStrategy);
        console.log("Pauser.register(AutoUSDCYieldStrategy) completed");

        uint256 gasUsed = gasBefore - gasleft();
        _trackStep("RegisterWithPauser", address(0), gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // Progress File Management
    // ========================================

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

    function _parseProgressJson(string memory json) internal {
        string[] memory names = new string[](5);
        names[0] = "DeployAutoUSDCYieldStrategy";
        names[1] = "ConfigureAutoUSDCYieldStrategy";
        names[2] = "ConfigureMinterForUSDC";
        names[3] = "ConfigureAccumulatorForUSDC";
        names[4] = "RegisterWithPauser";

        for (uint256 i = 0; i < names.length; i++) {
            string memory name = names[i];

            try vm.parseJsonBool(json, string.concat(".steps.", name, ".completed")) returns (bool completed) {
                if (completed) {
                    address addr = address(0);
                    try vm.parseJsonAddress(json, string.concat(".steps.", name, ".address")) returns (address a) {
                        addr = a;
                    } catch {}

                    uint256 gasUsed = 0;
                    try vm.parseJsonUint(json, string.concat(".steps.", name, ".gasUsed")) returns (uint256 g) {
                        gasUsed = g;
                    } catch {}

                    steps[name] = DeploymentStep({
                        name: name,
                        addr: addr,
                        completed: true,
                        gasUsed: gasUsed
                    });
                    stepNames.push(name);

                    // Load deployed address if this is the deployment step
                    if (keccak256(bytes(name)) == keccak256(bytes("DeployAutoUSDCYieldStrategy"))) {
                        autoUSDCYieldStrategy = addr;
                    }

                    console.log("Loaded from progress:", name, "completed:", completed);
                }
            } catch {
                // Step not in progress file, will be executed
            }
        }
    }

    function _isStepComplete(string memory name) internal view returns (bool) {
        return steps[name].completed;
    }

    function _trackStep(string memory name, address addr, uint256 gas) internal {
        bool found = false;
        for (uint256 i = 0; i < stepNames.length; i++) {
            if (keccak256(bytes(stepNames[i])) == keccak256(bytes(name))) {
                found = true;
                break;
            }
        }
        if (!found) {
            stepNames.push(name);
        }

        steps[name] = DeploymentStep({
            name: name,
            addr: addr,
            completed: true,
            gasUsed: gas
        });
    }

    function _markDeploymentComplete() internal {
        _writeProgressFileWithStatus("completed");
    }

    function _writeProgressFile() internal {
        _writeProgressFileWithStatus("in_progress");
    }

    function _writeProgressFileWithStatus(string memory status) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": ', vm.toString(CHAIN_ID), ",");
        json = string.concat(json, '"networkName": "', NETWORK_NAME, '",');
        json = string.concat(json, '"deploymentStatus": "', status, '",');
        json = string.concat(json, '"autoUSDCYieldStrategy": "', vm.toString(autoUSDCYieldStrategy), '",');
        json = string.concat(json, '"steps": {');

        for (uint256 i = 0; i < stepNames.length; i++) {
            string memory name = stepNames[i];
            DeploymentStep memory step = steps[name];

            if (i > 0) json = string.concat(json, ",");

            json = string.concat(json, '"', name, '": {');
            json = string.concat(json, '"address": "', vm.toString(step.addr), '",');
            json = string.concat(json, '"completed": ', step.completed ? "true" : "false", ",");
            json = string.concat(json, '"gasUsed": ', vm.toString(step.gasUsed));
            json = string.concat(json, "}");
        }

        json = string.concat(json, "}}");

        vm.writeFile(PROGRESS_FILE, json);
        console.log("Progress file updated:", PROGRESS_FILE);
    }

    function _printDeploymentSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("");
        console.log("AutoUSDC YieldStrategy Integration:");
        console.log("  - USDC -> AutoUSDCYieldStrategy -> PhusdStableMinter -> phUSD");
        console.log("  - AutoUSDCYieldStrategy deposits to autoUSD vault via Tokemak MainRewarder");
        console.log("  - Yield gathered by StableYieldAccumulator");
        console.log("");
        console.log("Deployed Contract:");
        console.log("  - AutoUSDCYieldStrategy:", autoUSDCYieldStrategy);
        console.log("");
        console.log("Configuration Completed:");
        console.log("  - Minter authorized as client on YieldStrategy");
        console.log("  - YieldStrategy approved for USDC on Minter");
        console.log("  - USDC registered as stablecoin (6 decimals, 1:1 rate)");
        console.log("  - YieldStrategy added to StableYieldAccumulator");
        console.log("  - StableYieldAccumulator authorized as withdrawer");
        console.log("  - YieldStrategy registered with Pauser");
        console.log("");
        console.log("External Contracts Used:");
        console.log("  - USDC:", USDC);
        console.log("  - TOKE:", TOKE);
        console.log("  - autoUSD Vault:", AUTO_USD_VAULT);
        console.log("  - MainRewarder (USDC):", MAIN_REWARDER_USDC);
        console.log("");
        console.log("Existing Phoenix Contracts:");
        console.log("  - Pauser:", PAUSER);
        console.log("  - PhusdStableMinter:", MINTER);
        console.log("  - StableYieldAccumulator:", ACCUMULATOR);
        console.log("=========================================");
    }
}
