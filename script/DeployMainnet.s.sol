// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phlimbo-ea/interfaces/IPhlimbo.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@pauser/Pauser.sol";
import "@vault/concreteYieldStrategies/AutoDolaYieldStrategy.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "../src/views/DepositView.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMainnet
 * @notice Production mainnet deployment script for Phoenix Phase 2 contracts
 * @dev Key features:
 *      - Uses REAL mainnet addresses (no mocks)
 *      - Reads from existing progress.1.json if it exists (does NOT delete it)
 *      - Skips already-deployed contracts based on progress file
 *      - Skips already-configured contracts based on progress file
 *      - Updates progress.1.json after EACH successful deployment/configuration step
 *      - Uses Ethereum Mainnet chain ID (1)
 *      - Configured for Ledger hardware wallet signing (index 46)
 *
 * Architecture Overview:
 * - Dola is the ONLY minting stablecoin (via AutoDolaYieldStrategy)
 * - Real USDC is the reward token for Phlimbo and StableYieldAccumulator
 * - AutoDolaYieldStrategy deposits to AutoDola vault via Tokemak's MainRewarder
 * - StableYieldAccumulator gathers yield and offers to users for discounted USDC
 * - USDC is then injected into Phlimbo for distribution
 *
 * ==========================================
 *       MAINNET CONTRACT ADDRESSES
 * ==========================================
 * These addresses MUST be verified before deployment!
 *
 * EXTERNAL CONTRACTS (from other protocols):
 * - USDC:          0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48  (Circle USDC)
 * - DOLA:          0x865377367054516e17014CcdED1e7d814EDC9ce4  (Inverse Finance)
 * - TOKE:          0x2e9d63788249371f1DFC918a52f8d799F4a38C94  (Tokemak)
 * - EYE:           0x155ff1A85F440EE0A382eA949f24CE4E0b751c65  (Behodler)
 * - AutoDOLA:      0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d  (Inverse/Tokemak)
 * - MainRewarder:  0xDC39C67b38ecdA8a1974336c89B00F68667c91B7  (Tokemak)
 *
 * PREVIOUSLY DEPLOYED PHOENIX CONTRACTS:
 * - phUSD:                    0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605  (FlaxToken deployment)
 *
 * LEDGER SIGNER:
 * - Index: 46
 * - Owner Address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 * ==========================================
 */
contract DeployMainnet is Script {
    // ==========================================
    //         MAINNET ADDRESSES - VERIFY BEFORE DEPLOYMENT
    // ==========================================

    // External Protocol Contracts
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;           // Circle USDC (6 decimals)
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;           // Inverse Finance DOLA
    address public constant TOKE = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;           // Tokemak TOKE
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;            // Behodler EYE
    address public constant AUTO_DOLA_VAULT = 0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d; // Inverse/Tokemak AutoDOLA
    address public constant MAIN_REWARDER = 0xDC39C67b38ecdA8a1974336c89B00F68667c91B7;   // Tokemak MainRewarder

    // Previously Deployed Phoenix Contracts
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;          // phUSD (FlaxToken)

    // Ledger Signer Configuration
    // Index 46 corresponds to owner address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    // Newly deployed contract addresses - loaded from progress file or set during deployment
    address public minter;
    address public phlimbo;
    address public stableYieldAccumulator;
    address public newPauser;
    address public depositView;
    address public autoDolaYieldStrategy;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.1.json";
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    // Phlimbo configuration
    uint256 constant ONE_MONTH_IN_SECONDS = 2629746; // 30.44 days

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
    bool isPreview;

    function run() external {
        console.log("=========================================");
        console.log("  PHOENIX PHASE 2 MAINNET DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- MAINNET ADDRESSES (VERIFY BEFORE DEPLOYMENT) ---");
        console.log("USDC:           ", USDC);
        console.log("DOLA:           ", DOLA);
        console.log("TOKE:           ", TOKE);
        console.log("EYE:            ", EYE);
        console.log("AutoDOLA Vault: ", AUTO_DOLA_VAULT);
        console.log("MainRewarder:   ", MAIN_REWARDER);
        console.log("phUSD:          ", PHUSD);
        console.log("Owner Address:  ", OWNER_ADDRESS);
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

        // ====== PHASE 1: Deploy New Pauser ======
        console.log("\n=== Phase 1: Deploy New Pauser ===");
        _deployNewPauser();

        // ====== PHASE 2: Core Contract Deployment ======
        console.log("\n=== Phase 2: Deploying Core Contracts ===");
        _deployAutoDolaYieldStrategy();
        _deployPhusdStableMinter();
        _deployPhlimboEA();
        _deployStableYieldAccumulator();

        // ====== PHASE 3: Token Authorization ======
        console.log("\n=== Phase 3: Token Authorization ===");
        _configureTokenAuthorization();

        // ====== PHASE 4: YieldStrategy Configuration ======
        console.log("\n=== Phase 4: YieldStrategy Configuration ===");
        _configureYieldStrategy();

        // ====== PHASE 5: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 5: PhusdStableMinter Configuration ===");
        _configurePhusdStableMinter();

        // ====== PHASE 6: StableYieldAccumulator Configuration ======
        console.log("\n=== Phase 6: StableYieldAccumulator Configuration ===");
        _configureStableYieldAccumulator();

        // ====== PHASE 7: Phlimbo Configuration ======
        console.log("\n=== Phase 7: Phlimbo Configuration ===");
        _configurePhlimbo();

        // ====== PHASE 8: New Pauser Registration ======
        console.log("\n=== Phase 8: New Pauser Registration ===");
        _configureNewPauser();

        // ====== PHASE 9: Deploy DepositView for UI Polling ======
        console.log("\n=== Phase 9: Deploy DepositView ===");
        _deployDepositView();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ====== Final Progress Update ======
        _markDeploymentComplete();

        console.log("\n=== Deployment Complete ===");
        console.log("All contracts deployed and configured successfully!");
        _printArchitectureSummary();
    }

    // ========================================
    // PHASE 1: Deploy New Pauser
    // ========================================

    function _deployNewPauser() internal {
        if (_isDeployed("NewPauser")) {
            newPauser = deployments["NewPauser"].addr;
            console.log("NewPauser already deployed at:", newPauser);
            return;
        }

        uint256 gasBefore = gasleft();
        Pauser p = new Pauser(EYE);
        newPauser = address(p);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("NewPauser", newPauser, gasUsed);
        _writeProgressFile();
        console.log("NewPauser deployed at:", newPauser);
        console.log("  - Configured with EYE token:", EYE);
    }

    // ========================================
    // PHASE 2: Core Contract Deployment
    // ========================================

    function _deployAutoDolaYieldStrategy() internal {
        if (_isDeployed("AutoDolaYieldStrategy")) {
            autoDolaYieldStrategy = deployments["AutoDolaYieldStrategy"].addr;
            console.log("AutoDolaYieldStrategy already deployed at:", autoDolaYieldStrategy);
            return;
        }

        uint256 gasBefore = gasleft();
        AutoDolaYieldStrategy ys = new AutoDolaYieldStrategy(
            OWNER_ADDRESS,      // owner
            DOLA,               // dola
            TOKE,               // toke
            AUTO_DOLA_VAULT,    // autoDolaVault
            MAIN_REWARDER       // mainRewarder
        );
        autoDolaYieldStrategy = address(ys);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("AutoDolaYieldStrategy", autoDolaYieldStrategy, gasUsed);
        _writeProgressFile();
        console.log("AutoDolaYieldStrategy deployed at:", autoDolaYieldStrategy);
        console.log("  - Owner:", OWNER_ADDRESS);
        console.log("  - DOLA:", DOLA);
        console.log("  - TOKE:", TOKE);
        console.log("  - AutoDOLA Vault:", AUTO_DOLA_VAULT);
        console.log("  - MainRewarder:", MAIN_REWARDER);
    }

    function _deployPhusdStableMinter() internal {
        if (_isDeployed("PhusdStableMinter")) {
            minter = deployments["PhusdStableMinter"].addr;
            console.log("PhusdStableMinter already deployed at:", minter);
            return;
        }

        uint256 gasBefore = gasleft();
        PhusdStableMinter m = new PhusdStableMinter(PHUSD);
        minter = address(m);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("PhusdStableMinter", minter, gasUsed);
        _writeProgressFile();
        console.log("PhusdStableMinter deployed at:", minter);
        console.log("  - phUSD address:", PHUSD);
    }

    function _deployPhlimboEA() internal {
        if (_isDeployed("PhlimboEA")) {
            phlimbo = deployments["PhlimboEA"].addr;
            console.log("PhlimboEA already deployed at:", phlimbo);
            return;
        }

        uint256 gasBefore = gasleft();
        PhlimboEA p = new PhlimboEA(
            PHUSD,                  // _phUSD
            USDC,                   // _rewardToken (real USDC)
            ONE_MONTH_IN_SECONDS    // _depletionDuration (1 month)
        );
        phlimbo = address(p);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("PhlimboEA", phlimbo, gasUsed);
        _writeProgressFile();
        console.log("PhlimboEA deployed at:", phlimbo);
        console.log("  - Depletion window:", ONE_MONTH_IN_SECONDS, "seconds (1 month)");
        console.log("  - Reward token: USDC at", USDC);
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
    // PHASE 3: Token Authorization
    // ========================================

    function _configureTokenAuthorization() internal {
        if (_isConfigured("TokenAuth")) {
            console.log("Token authorization already configured");
            return;
        }

        require(phlimbo != address(0), "PhlimboEA must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");

        uint256 gasBefore = gasleft();

        // phUSD is a FlaxToken which has setMinter function
        // We need to authorize PhlimboEA and PhusdStableMinter as minters
        // This requires calling phUSD.setMinter(address, true) - which must be done by phUSD owner
        console.log("NOTE: phUSD.setMinter() must be called by phUSD owner for:");
        console.log("  - PhlimboEA:", phlimbo);
        console.log("  - PhusdStableMinter:", minter);

        // Assuming the deployment account is the phUSD owner, we'll make these calls
        // If not, these will revert and must be done separately by the owner

        // Get the phUSD contract interface for minting authorization
        // FlaxToken interface: setMinter(address minter, bool canMint)
        (bool success1,) = PHUSD.call(abi.encodeWithSignature("setMinter(address,bool)", phlimbo, true));
        if (success1) {
            console.log("Authorized PhlimboEA as phUSD minter");
        } else {
            console.log("WARNING: Could not authorize PhlimboEA as phUSD minter - owner must do this");
        }

        (bool success2,) = PHUSD.call(abi.encodeWithSignature("setMinter(address,bool)", minter, true));
        if (success2) {
            console.log("Authorized PhusdStableMinter as phUSD minter");
        } else {
            console.log("WARNING: Could not authorize PhusdStableMinter as phUSD minter - owner must do this");
        }

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("TokenAuth", address(0), 0);
        _markConfigured("TokenAuth", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 4: YieldStrategy Configuration
    // ========================================

    function _configureYieldStrategy() internal {
        if (_isConfigured("AutoDolaYieldStrategy")) {
            console.log("AutoDolaYieldStrategy already configured");
            return;
        }

        require(minter != address(0), "PhusdStableMinter must be deployed");
        require(autoDolaYieldStrategy != address(0), "AutoDolaYieldStrategy must be deployed");

        uint256 gasBefore = gasleft();

        // Configure the newly deployed AutoDolaYieldStrategy to authorize the minter as a client
        console.log("Configuring AutoDolaYieldStrategy at:", autoDolaYieldStrategy);
        console.log("  - Setting PhusdStableMinter as client:", minter);

        AutoDolaYieldStrategy yieldStrategy = AutoDolaYieldStrategy(autoDolaYieldStrategy);

        // Authorize minter as client
        yieldStrategy.setClient(minter, true);
        console.log("Authorized minter as AutoDolaYieldStrategy client");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("AutoDolaYieldStrategy", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 5: PhusdStableMinter Configuration
    // ========================================

    function _configurePhusdStableMinter() internal {
        if (_isConfigured("PhusdStableMinter")) {
            console.log("PhusdStableMinter already configured");
            return;
        }

        require(minter != address(0), "PhusdStableMinter must be deployed");
        require(autoDolaYieldStrategy != address(0), "AutoDolaYieldStrategy must be deployed");

        uint256 gasBefore = gasleft();

        PhusdStableMinter m = PhusdStableMinter(minter);

        // Approve yield strategy for DOLA
        m.approveYS(DOLA, autoDolaYieldStrategy);
        console.log("Approved AutoDolaYieldStrategy for DOLA at:", autoDolaYieldStrategy);

        // Register DOLA as stablecoin (18 decimals)
        m.registerStablecoin(
            DOLA,                       // stablecoin
            autoDolaYieldStrategy,      // yieldStrategy
            1e18,                       // exchangeRate (1:1)
            18                          // decimals
        );
        console.log("Registered DOLA as stablecoin with AutoDolaYieldStrategy");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("PhusdStableMinter", gasUsed);
        _writeProgressFile();
    }

    // ========================================
    // PHASE 6: StableYieldAccumulator Configuration
    // ========================================

    function _configureStableYieldAccumulator() internal {
        if (_isConfigured("StableYieldAccumulator")) {
            console.log("StableYieldAccumulator already configured");
            return;
        }

        require(stableYieldAccumulator != address(0), "StableYieldAccumulator must be deployed");
        require(phlimbo != address(0), "PhlimboEA must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");
        require(autoDolaYieldStrategy != address(0), "AutoDolaYieldStrategy must be deployed");

        uint256 gasBefore = gasleft();

        StableYieldAccumulator sya = StableYieldAccumulator(stableYieldAccumulator);

        // Set reward token to USDC
        sya.setRewardToken(USDC);
        console.log("Set reward token to USDC:", USDC);

        // Set Phlimbo as the reward recipient
        sya.setPhlimbo(phlimbo);
        console.log("Set Phlimbo as reward recipient:", phlimbo);

        // Set minter address for yield queries
        sya.setMinter(minter);
        console.log("Set minter for yield queries:", minter);

        // Configure USDC token (6 decimals, 1:1 exchange rate)
        sya.setTokenConfig(USDC, 6, 1e18);
        console.log("Configured USDC token config (6 decimals, 1:1 rate)");

        // Configure DOLA token (18 decimals, 1:1 exchange rate)
        sya.setTokenConfig(DOLA, 18, 1e18);
        console.log("Configured DOLA token config (18 decimals, 1:1 rate)");

        // Add AutoDolaYieldStrategy to the yield strategy registry
        sya.addYieldStrategy(autoDolaYieldStrategy, DOLA);
        console.log("Added AutoDolaYieldStrategy to yield strategy registry at:", autoDolaYieldStrategy);

        // Set discount rate (e.g., 2% = 200 basis points)
        sya.setDiscountRate(200);
        console.log("Set discount rate to 200 basis points (2%)");

        // Approve Phlimbo to spend reward tokens with max approval
        sya.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo to spend reward tokens from StableYieldAccumulator");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("StableYieldAccumulator", gasUsed);
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
        require(stableYieldAccumulator != address(0), "StableYieldAccumulator must be deployed");

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
    // PHASE 8: New Pauser Registration
    // ========================================

    function _configureNewPauser() internal {
        if (_isConfigured("NewPauser")) {
            console.log("NewPauser already configured");
            return;
        }

        require(newPauser != address(0), "NewPauser must be deployed");
        require(minter != address(0), "PhusdStableMinter must be deployed");
        require(phlimbo != address(0), "PhlimboEA must be deployed");
        require(stableYieldAccumulator != address(0), "StableYieldAccumulator must be deployed");
        require(autoDolaYieldStrategy != address(0), "AutoDolaYieldStrategy must be deployed");

        console.log("CRITICAL: setPauser() must be called BEFORE register()");

        uint256 gasBefore = gasleft();

        Pauser p = Pauser(newPauser);

        // Register AutoDolaYieldStrategy with NewPauser
        AutoDolaYieldStrategy(autoDolaYieldStrategy).setPauser(newPauser);
        console.log("AutoDolaYieldStrategy.setPauser() called");
        p.register(autoDolaYieldStrategy);
        console.log("NewPauser.register(AutoDolaYieldStrategy) completed");

        // Register PhusdStableMinter with NewPauser
        PhusdStableMinter(minter).setPauser(newPauser);
        console.log("PhusdStableMinter.setPauser() called");
        p.register(minter);
        console.log("NewPauser.register(PhusdStableMinter) completed");

        // Register PhlimboEA with NewPauser
        PhlimboEA(phlimbo).setPauser(newPauser);
        console.log("PhlimboEA.setPauser() called");
        p.register(phlimbo);
        console.log("NewPauser.register(PhlimboEA) completed");

        // Register StableYieldAccumulator with NewPauser
        StableYieldAccumulator(stableYieldAccumulator).setPauser(newPauser);
        console.log("StableYieldAccumulator.setPauser() called");
        p.register(stableYieldAccumulator);
        console.log("NewPauser.register(StableYieldAccumulator) completed");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("NewPauser", gasUsed);
        _writeProgressFile();
        console.log("All Phase 2 contracts registered with NewPauser");
    }

    // ========================================
    // PHASE 9: Deploy DepositView
    // ========================================

    function _deployDepositView() internal {
        if (_isDeployed("DepositView")) {
            depositView = deployments["DepositView"].addr;
            console.log("DepositView already deployed at:", depositView);
            return;
        }

        require(phlimbo != address(0), "PhlimboEA must be deployed");

        uint256 gasBefore = gasleft();
        DepositView dv = new DepositView(
            IPhlimbo(phlimbo),
            IERC20(PHUSD)
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
        string[] memory names = new string[](9);
        names[0] = "NewPauser";
        names[1] = "AutoDolaYieldStrategy";
        names[2] = "PhusdStableMinter";
        names[3] = "PhlimboEA";
        names[4] = "StableYieldAccumulator";
        names[5] = "TokenAuth";
        names[6] = "DepositView";
        names[7] = "Seeding";
        names[8] = "DolaYield";

        for (uint256 i = 0; i < names.length; i++) {
            string memory name = names[i];

            try vm.parseJsonAddress(json, string.concat(".contracts.", name, ".address")) returns (address addr) {
                if (addr != address(0)) {
                    bool deployed = false;
                    try vm.parseJsonBool(json, string.concat(".contracts.", name, ".deployed")) returns (bool d) {
                        deployed = d;
                    } catch {}

                    bool configured = false;
                    try vm.parseJsonBool(json, string.concat(".contracts.", name, ".configured")) returns (bool c) {
                        configured = c;
                    } catch {}

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

    function _isDeployed(string memory name) internal view returns (bool) {
        return deployments[name].deployed && deployments[name].addr != address(0);
    }

    function _isConfigured(string memory name) internal view returns (bool) {
        return deployments[name].configured;
    }

    function _trackDeployment(string memory name, address addr, uint256 gas) internal {
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

    function _markConfigured(string memory name, uint256 gas) internal {
        deployments[name].configured = true;
        deployments[name].configGas = gas;
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

        vm.writeFile(PROGRESS_FILE, json);
        console.log("Progress file updated:", PROGRESS_FILE);
    }

    function _printArchitectureSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("");
        console.log("Architecture:");
        console.log("  - DOLA -> AutoDolaYieldStrategy -> PhusdStableMinter -> phUSD");
        console.log("  - AutoDolaYieldStrategy deposits to AutoDOLA vault via Tokemak MainRewarder");
        console.log("  - Yield gathered by StableYieldAccumulator");
        console.log("  - Users exchange stablecoins for discounted USDC");
        console.log("  - USDC injected into Phlimbo for distribution");
        console.log("");
        console.log("PhlimboEA Configuration:");
        console.log("  - Depletion window:", ONE_MONTH_IN_SECONDS, "seconds (1 month)");
        console.log("  - Reward token: USDC");
        console.log("  - Rewards drip linearly over the depletion period");
        console.log("");
        console.log("StableYieldAccumulator Configuration:");
        console.log("  - Reward token: USDC");
        console.log("  - Discount rate: 2% (200 basis points)");
        console.log("  - Yield strategies: AutoDolaYieldStrategy (DOLA)");
        console.log("");
        console.log("Global Pauser System:");
        console.log("  - NewPauser deployed for all Phase 2 contracts");
        console.log("  - AutoDolaYieldStrategy registered with NewPauser");
        console.log("  - PhusdStableMinter registered with NewPauser");
        console.log("  - PhlimboEA registered with NewPauser");
        console.log("  - StableYieldAccumulator registered with NewPauser");
        console.log("  - Burn 1000 EYE to trigger global pause on NewPauser");
        console.log("");
        console.log("Deployed Contract Addresses:");
        console.log("  - NewPauser:", newPauser);
        console.log("  - AutoDolaYieldStrategy:", autoDolaYieldStrategy);
        console.log("  - PhusdStableMinter:", minter);
        console.log("  - PhlimboEA:", phlimbo);
        console.log("  - StableYieldAccumulator:", stableYieldAccumulator);
        console.log("  - DepositView:", depositView);
        console.log("");
        console.log("External Contracts Used:");
        console.log("  - phUSD:", PHUSD);
        console.log("  - USDC:", USDC);
        console.log("  - DOLA:", DOLA);
        console.log("  - AutoDOLA Vault:", AUTO_DOLA_VAULT);
        console.log("  - MainRewarder:", MAIN_REWARDER);
        console.log("=========================================");
    }
}
