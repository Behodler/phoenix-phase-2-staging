// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phlimbo-ea/interfaces/IPhlimbo.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@pauser/Pauser.sol";
import {AutoDolaYieldStrategy} from "@vault/concreteYieldStrategies/Legacy/phase1/AutoDolaYieldStrategy.sol";
import {AutoPoolYieldStrategy} from "@vault/concreteYieldStrategies/AutoPoolYieldStrategy.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "../src/views/ViewRouter.sol";
import "../src/views/DepositPageView.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
import {INFTMinter as INFTMinterView} from "@yield-claim-nft/interfaces/INFTMinter.sol";
import {NFTMinter} from "@yield-claim-nft/NFTMinter.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import {Burner} from "@yield-claim-nft/dispatchers/Burner.sol";
import {BalancerPooler} from "@yield-claim-nft/dispatchers/BalancerPooler.sol";
import {Gather} from "@yield-claim-nft/dispatchers/Gather.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMainnetNFT
 * @notice Differential mainnet deployment script for NFT infrastructure and accumulator replacement
 * @dev This script deploys ONLY the new contracts needed for NFT-gated claiming:
 *      - NFTMinter, BurnRecorder, 5 dispatchers
 *      - New StableYieldAccumulator (replacing the old one)
 *      - ViewRouter, DepositPageView, MintPageView (if not already deployed)
 *
 *      It does NOT redeploy: phUSD, PhlimboEA, PhusdStableMinter, Pauser, YieldStrategies
 *
 *      Two execution modes:
 *      - PREVIEW_MODE=true  -> startPrank(OWNER_ADDRESS), NO progress file writes
 *      - PREVIEW_MODE=false -> startBroadcast() with Ledger, DOES write progress file
 *
 * LEDGER SIGNER:
 * - Index: 46
 * - Owner Address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/DeployMainnetNFT.s.sol --rpc-url mainnet
 *
 * Broadcast:
 *   forge script script/DeployMainnetNFT.s.sol --broadcast --skip-simulation --rpc-url mainnet --ledger --hd-paths "m/44'/60'/46'/0/0"
 */
contract DeployMainnetNFT is Script {
    // ==========================================
    //         EXISTING DEPLOYED CONTRACTS (DO NOT REDEPLOY)
    // ==========================================

    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant YIELD_STRATEGY_DOLA = 0x01d34d7EF3988C5b981ee06bF0Ba4485Bd8eA20C;
    address public constant YIELD_STRATEGY_USDC = 0xf5F91E8240a0320CAC40b799B25F944a61090E5B;
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant PHLIMBO_EA = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;
    address public constant OLD_ACCUMULATOR = 0xFc88cE7Ca2f4D2A78b2f96F6d1c34691960A9027;
    address public constant DEPOSIT_VIEW = 0x2Fdf77d4Ea75eFd48922B8E521612197FFbB564c;

    // ==========================================
    //         EXTERNAL MAINNET TOKEN ADDRESSES
    // ==========================================

    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLAX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant WBTC = 0x2260FAc5E5542A773aA44FBcfeDD86a3D015c766;

    // ==========================================
    //         BALANCER V3 ADDRESSES
    // ==========================================

    address public constant BALANCER_POOL = 0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58;
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;

    // ==========================================
    //         SIGNER CONFIGURATION
    // ==========================================

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ==========================================
    //         CONFIGURATION CONSTANTS
    // ==========================================

    uint256 public constant DISCOUNT_RATE_BPS = 2000; // 20% discount

    // Per-token initial prices: $5 worth of each token, except sUSDS at $4 (discounted to encourage early minting)
    // WBTC uses 8 decimals; all others use 18 decimals
    uint256 public constant INITIAL_PRICE_EYE = 179e18;      // ~$5 at $0.027932/EYE
    uint256 public constant INITIAL_PRICE_SCX = 81037e13;     // ~$5 at $6.17/SCX
    uint256 public constant INITIAL_PRICE_FLAX = 6024e18;     // ~$5 at $0.00083/FLAX
    uint256 public constant INITIAL_PRICE_SUSDS = 3706e15;    // ~$4 at $1.07918/sUSDS (discounted)
    uint256 public constant INITIAL_PRICE_WBTC = 712;         // ~$5 at $702,331/WBTC (8 decimals)

    // Dispatcher growth rates (basis points)
    uint256 public constant GROWTH_BURNER = 1000;          // 10%
    uint256 public constant GROWTH_BALANCER_POOLER = 500;   // 5%
    uint256 public constant GROWTH_GATHER_WBTC = 1200;     // 12%

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    address public nftMinter;
    address public burnRecorder;
    address public burnerEYE;
    address public burnerSCX;
    address public burnerFlax;
    address public balancerPooler;
    address public gatherWBTC;
    address public newAccumulator;
    address public viewRouter;
    address public depositPageView;
    address public mintPageView;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.1.json";
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    struct ContractDeployment {
        string name;
        address addr;
        bool deployed;
        bool configured;
        uint256 deployGas;
        uint256 configGas;
    }

    mapping(string => ContractDeployment) public deployments;
    string[] public contractNames;
    bool progressFileExists;
    bool isPreview;

    function run() external {
        console.log("=========================================");
        console.log("  MAINNET NFT INFRASTRUCTURE DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- EXISTING CONTRACTS (NOT REDEPLOYED) ---");
        console.log("Pauser:              ", PAUSER);
        console.log("YieldStrategyDola:   ", YIELD_STRATEGY_DOLA);
        console.log("YieldStrategyUSDC:   ", YIELD_STRATEGY_USDC);
        console.log("PhusdStableMinter:   ", PHUSD_STABLE_MINTER);
        console.log("PhlimboEA:           ", PHLIMBO_EA);
        console.log("Old Accumulator:     ", OLD_ACCUMULATOR);
        console.log("DepositView:         ", DEPOSIT_VIEW);
        console.log("");
        console.log("--- EXTERNAL TOKENS ---");
        console.log("phUSD:   ", PHUSD);
        console.log("USDC:    ", USDC);
        console.log("DOLA:    ", DOLA);
        console.log("EYE:     ", EYE);
        console.log("SCX:     ", SCX);
        console.log("Flax:    ", FLAX);
        console.log("sUSDS:   ", SUSDS);
        console.log("WBTC:    ", WBTC);
        console.log("");
        console.log("--- BALANCER V3 ---");
        console.log("Pool:    ", BALANCER_POOL);
        console.log("Vault:   ", BALANCER_VAULT);
        console.log("Owner:   ", OWNER_ADDRESS);
        console.log("----------------------------------------------------");

        // Load existing progress file
        _loadProgressFile();

        // Check preview mode
        isPreview = vm.envOr("PREVIEW_MODE", false);

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - Impersonating owner (no signing required) ***");
            console.log("*** Progress file will NOT be written ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // ====== PHASE 1: Deploy NFT Core ======
        console.log("\n=== Phase 1: Deploy NFT Core ===");
        _deployNFTMinter();
        _deployBurnRecorder();

        // ====== PHASE 2: Deploy Dispatchers ======
        console.log("\n=== Phase 2: Deploy Dispatchers ===");
        _deployBurnerEYE();
        _deployBurnerSCX();
        _deployBurnerFlax();
        _deployBalancerPooler();
        _deployGatherWBTC();

        // ====== PHASE 3: Deploy New StableYieldAccumulator ======
        console.log("\n=== Phase 3: Deploy New StableYieldAccumulator ===");
        _deployNewAccumulator();
        _configureNewAccumulator();

        // ====== PHASE 4: Reconfigure YieldStrategy Withdrawers ======
        console.log("\n=== Phase 4: Reconfigure YieldStrategy Withdrawers ===");
        _reconfigureWithdrawers();

        // ====== PHASE 5: NFTMinter Configuration ======
        console.log("\n=== Phase 5: NFTMinter Configuration ===");
        _registerDispatchers();
        _setMintersOnDispatchers();
        _authorizeBurnersOnBurnRecorder();
        _linkAccumulatorAndNFTMinter();

        // ====== PHASE 6: Pauser Registration ======
        console.log("\n=== Phase 6: Pauser Registration ===");
        _registerWithPauser();

        // ====== PHASE 7: Deploy View Contracts ======
        console.log("\n=== Phase 7: Deploy View Contracts ===");
        _deployViewRouter();
        _deployDepositPageView();
        _deployMintPageView();
        _registerPagesWithViewRouter();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ====== Phase 8: Final Steps ======
        console.log("\n=== Phase 8: Final Steps ===");
        if (!isPreview) {
            _markDeploymentComplete();
        }

        _printDeploymentSummary();
    }

    // ========================================
    // PHASE 1: Deploy NFT Core
    // ========================================

    function _deployNFTMinter() internal {
        if (_isDeployed("NFTMinter")) {
            nftMinter = deployments["NFTMinter"].addr;
            console.log("NFTMinter already deployed at:", nftMinter);
            return;
        }

        uint256 gasBefore = gasleft();
        NFTMinter minterNFT = new NFTMinter(OWNER_ADDRESS);
        nftMinter = address(minterNFT);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("NFTMinter", nftMinter, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("NFTMinter deployed at:", nftMinter);
    }

    function _deployBurnRecorder() internal {
        if (_isDeployed("BurnRecorder")) {
            burnRecorder = deployments["BurnRecorder"].addr;
            console.log("BurnRecorder already deployed at:", burnRecorder);
            return;
        }

        uint256 gasBefore = gasleft();
        BurnRecorder recorder = new BurnRecorder(OWNER_ADDRESS);
        burnRecorder = address(recorder);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnRecorder", burnRecorder, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("BurnRecorder deployed at:", burnRecorder);
    }

    // ========================================
    // PHASE 2: Deploy Dispatchers
    // ========================================

    function _deployBurnerEYE() internal {
        if (_isDeployed("BurnerEYE")) {
            burnerEYE = deployments["BurnerEYE"].addr;
            console.log("BurnerEYE already deployed at:", burnerEYE);
            return;
        }

        require(burnRecorder != address(0), "BurnRecorder must be deployed");

        uint256 gasBefore = gasleft();
        Burner b = new Burner(EYE, burnRecorder, OWNER_ADDRESS);
        burnerEYE = address(b);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnerEYE", burnerEYE, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("BurnerEYE deployed at:", burnerEYE);
    }

    function _deployBurnerSCX() internal {
        if (_isDeployed("BurnerSCX")) {
            burnerSCX = deployments["BurnerSCX"].addr;
            console.log("BurnerSCX already deployed at:", burnerSCX);
            return;
        }

        require(burnRecorder != address(0), "BurnRecorder must be deployed");

        uint256 gasBefore = gasleft();
        Burner b = new Burner(SCX, burnRecorder, OWNER_ADDRESS);
        burnerSCX = address(b);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnerSCX", burnerSCX, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("BurnerSCX deployed at:", burnerSCX);
    }

    function _deployBurnerFlax() internal {
        if (_isDeployed("BurnerFlax")) {
            burnerFlax = deployments["BurnerFlax"].addr;
            console.log("BurnerFlax already deployed at:", burnerFlax);
            return;
        }

        require(burnRecorder != address(0), "BurnRecorder must be deployed");

        uint256 gasBefore = gasleft();
        Burner b = new Burner(FLAX, burnRecorder, OWNER_ADDRESS);
        burnerFlax = address(b);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BurnerFlax", burnerFlax, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("BurnerFlax deployed at:", burnerFlax);
    }

    function _deployBalancerPooler() internal {
        if (_isDeployed("BalancerPooler")) {
            balancerPooler = deployments["BalancerPooler"].addr;
            console.log("BalancerPooler already deployed at:", balancerPooler);
            return;
        }

        uint256 gasBefore = gasleft();
        BalancerPooler bp = new BalancerPooler(
            SUSDS,              // primeToken_ (sUSDS)
            BALANCER_POOL,      // pool_ (BPT token)
            BALANCER_VAULT,     // vault_
            true,               // primeTokenIsFirst_ (sUSDS is token[0])
            OWNER_ADDRESS       // initialOwner
        );
        balancerPooler = address(bp);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("BalancerPooler", balancerPooler, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("BalancerPooler deployed at:", balancerPooler);
    }

    function _deployGatherWBTC() internal {
        if (_isDeployed("GatherWBTC")) {
            gatherWBTC = deployments["GatherWBTC"].addr;
            console.log("GatherWBTC already deployed at:", gatherWBTC);
            return;
        }

        uint256 gasBefore = gasleft();
        Gather g = new Gather(
            WBTC,               // token_ (WBTC)
            OWNER_ADDRESS,      // recipient_ (Ledger address as default)
            OWNER_ADDRESS       // initialOwner
        );
        gatherWBTC = address(g);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("GatherWBTC", gatherWBTC, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("GatherWBTC deployed at:", gatherWBTC);
    }

    // ========================================
    // PHASE 3: Deploy & Configure New Accumulator
    // ========================================

    function _deployNewAccumulator() internal {
        if (_isDeployed("NewStableYieldAccumulator")) {
            newAccumulator = deployments["NewStableYieldAccumulator"].addr;
            console.log("NewStableYieldAccumulator already deployed at:", newAccumulator);
            return;
        }

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = new StableYieldAccumulator();
        newAccumulator = address(sya);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("NewStableYieldAccumulator", newAccumulator, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("NewStableYieldAccumulator deployed at:", newAccumulator);
    }

    function _configureNewAccumulator() internal {
        if (_isConfigured("NewStableYieldAccumulator")) {
            console.log("NewStableYieldAccumulator already configured");
            return;
        }

        require(newAccumulator != address(0), "NewStableYieldAccumulator must be deployed");

        uint256 gasBefore = gasleft();

        StableYieldAccumulator sya = StableYieldAccumulator(newAccumulator);

        // Step 1: setRewardToken(USDC)
        sya.setRewardToken(USDC);
        console.log("Set reward token to USDC:", USDC);

        // Step 2: setPhlimbo(PHLIMBO_EA)
        sya.setPhlimbo(PHLIMBO_EA);
        console.log("Set Phlimbo:", PHLIMBO_EA);

        // Step 3: setMinter(PHUSD_STABLE_MINTER)
        sya.setMinter(PHUSD_STABLE_MINTER);
        console.log("Set minter:", PHUSD_STABLE_MINTER);

        // Step 4: setTokenConfig(USDC, 6, 1e18)
        sya.setTokenConfig(USDC, 6, 1e18);
        console.log("Configured USDC token config (6 decimals, 1:1 rate)");

        // Step 5: setTokenConfig(DOLA, 18, 1e18)
        sya.setTokenConfig(DOLA, 18, 1e18);
        console.log("Configured DOLA token config (18 decimals, 1:1 rate)");

        // Step 6: addYieldStrategy(YIELD_STRATEGY_DOLA, DOLA)
        sya.addYieldStrategy(YIELD_STRATEGY_DOLA, DOLA);
        console.log("Added YieldStrategyDola:", YIELD_STRATEGY_DOLA);

        // Step 7: addYieldStrategy(YIELD_STRATEGY_USDC, USDC)
        sya.addYieldStrategy(YIELD_STRATEGY_USDC, USDC);
        console.log("Added YieldStrategyUSDC:", YIELD_STRATEGY_USDC);

        // Step 8: setDiscountRate(2000) - 20%
        sya.setDiscountRate(DISCOUNT_RATE_BPS);
        console.log("Set discount rate:", DISCOUNT_RATE_BPS, "bps (20%)");

        // Step 9: approvePhlimbo(max)
        sya.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo to spend reward tokens");

        uint256 gasUsed = gasBefore - gasleft();
        _markConfigured("NewStableYieldAccumulator", gasUsed);
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // PHASE 4: Reconfigure YieldStrategy Withdrawers
    // ========================================

    function _reconfigureWithdrawers() internal {
        if (_isConfigured("WithdrawerReconfig")) {
            console.log("Withdrawer reconfiguration already done");
            return;
        }

        require(newAccumulator != address(0), "NewStableYieldAccumulator must be deployed");

        uint256 gasBefore = gasleft();

        // Revoke old accumulator as withdrawer on both YieldStrategies
        AYieldStrategy(YIELD_STRATEGY_DOLA).setWithdrawer(OLD_ACCUMULATOR, false);
        console.log("Revoked old accumulator as withdrawer on YieldStrategyDola");

        AYieldStrategy(YIELD_STRATEGY_USDC).setWithdrawer(OLD_ACCUMULATOR, false);
        console.log("Revoked old accumulator as withdrawer on YieldStrategyUSDC");

        // Authorize new accumulator as withdrawer on both YieldStrategies
        AYieldStrategy(YIELD_STRATEGY_DOLA).setWithdrawer(newAccumulator, true);
        console.log("Authorized new accumulator as withdrawer on YieldStrategyDola");

        AYieldStrategy(YIELD_STRATEGY_USDC).setWithdrawer(newAccumulator, true);
        console.log("Authorized new accumulator as withdrawer on YieldStrategyUSDC");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("WithdrawerReconfig", address(0), 0);
        _markConfigured("WithdrawerReconfig", gasUsed);
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // PHASE 5: NFTMinter Configuration
    // ========================================

    function _registerDispatchers() internal {
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

        // Index 1: BurnerEYE (EYE, ~$5 worth, 10% growth)
        NFTMinter(nftMinter).registerDispatcher(burnerEYE, INITIAL_PRICE_EYE, GROWTH_BURNER);
        console.log("Registered BurnerEYE (index 1, 10% growth)");

        // Index 2: BurnerSCX (SCX, ~$5 worth, 10% growth)
        NFTMinter(nftMinter).registerDispatcher(burnerSCX, INITIAL_PRICE_SCX, GROWTH_BURNER);
        console.log("Registered BurnerSCX (index 2, 10% growth)");

        // Index 3: BurnerFlax (Flax, ~$5 worth, 10% growth)
        NFTMinter(nftMinter).registerDispatcher(burnerFlax, INITIAL_PRICE_FLAX, GROWTH_BURNER);
        console.log("Registered BurnerFlax (index 3, 10% growth)");

        // Index 4: BalancerPooler (sUSDS, ~$4 worth discounted, 5% growth)
        NFTMinter(nftMinter).registerDispatcher(balancerPooler, INITIAL_PRICE_SUSDS, GROWTH_BALANCER_POOLER);
        console.log("Registered BalancerPooler (index 4, 5% growth)");

        // Index 5: GatherWBTC (WBTC, ~$5 worth, 12% growth)
        NFTMinter(nftMinter).registerDispatcher(gatherWBTC, INITIAL_PRICE_WBTC, GROWTH_GATHER_WBTC);
        console.log("Registered GatherWBTC (index 5, 12% growth)");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("NFTMinterDispatchers", address(0), 0);
        _markConfigured("NFTMinterDispatchers", gasUsed);
        if (!isPreview) _writeProgressFile();
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

        uint256 gasBefore = gasleft();

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

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("DispatcherMinters", address(0), 0);
        _markConfigured("DispatcherMinters", gasUsed);
        if (!isPreview) _writeProgressFile();
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
        if (!isPreview) _writeProgressFile();
        console.log("Authorized BurnerEYE, BurnerSCX, BurnerFlax as burners on BurnRecorder");
    }

    function _linkAccumulatorAndNFTMinter() internal {
        if (_isConfigured("AccumulatorNFTLink")) {
            console.log("Accumulator-NFTMinter link already configured");
            return;
        }

        require(newAccumulator != address(0), "NewStableYieldAccumulator must be deployed");
        require(nftMinter != address(0), "NFTMinter must be deployed");

        uint256 gasBefore = gasleft();

        // Step 10 of accumulator config: setNFTMinter
        StableYieldAccumulator(newAccumulator).setNFTMinter(nftMinter);
        console.log("StableYieldAccumulator.setNFTMinter -> NFTMinter");

        // Authorize accumulator as burner on NFTMinter
        NFTMinter(nftMinter).setAuthorizedBurner(newAccumulator, true);
        console.log("NFTMinter.setAuthorizedBurner(NewAccumulator, true)");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("AccumulatorNFTLink", address(0), 0);
        _markConfigured("AccumulatorNFTLink", gasUsed);
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // PHASE 6: Pauser Registration
    // ========================================

    function _registerWithPauser() internal {
        if (_isConfigured("PauserRegistration")) {
            console.log("Pauser registration already configured");
            return;
        }

        require(newAccumulator != address(0), "NewStableYieldAccumulator must be deployed");
        require(nftMinter != address(0), "NFTMinter must be deployed");

        uint256 gasBefore = gasleft();

        Pauser p = Pauser(PAUSER);

        // Register new StableYieldAccumulator with Pauser
        StableYieldAccumulator(newAccumulator).setPauser(PAUSER);
        console.log("NewAccumulator.setPauser() called");
        p.register(newAccumulator);
        console.log("Pauser.register(NewAccumulator) completed");

        // Register NFTMinter with Pauser (it implements Pausable)
        NFTMinter(nftMinter).setPauser(PAUSER);
        console.log("NFTMinter.setPauser() called");
        p.register(nftMinter);
        console.log("Pauser.register(NFTMinter) completed");

        // Note: De-registering old accumulator from Pauser may require a separate call
        // if the Pauser contract supports deregistration. Leaving as a manual step.
        console.log("NOTE: Consider de-registering old accumulator from Pauser manually");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("PauserRegistration", address(0), 0);
        _markConfigured("PauserRegistration", gasUsed);
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // PHASE 7: Deploy View Contracts
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
        if (!isPreview) _writeProgressFile();
        console.log("ViewRouter deployed at:", viewRouter);
    }

    function _deployDepositPageView() internal {
        if (_isDeployed("DepositPageView")) {
            depositPageView = deployments["DepositPageView"].addr;
            console.log("DepositPageView already deployed at:", depositPageView);
            return;
        }

        uint256 gasBefore = gasleft();
        DepositPageView dpv = new DepositPageView(
            IPhlimbo(PHLIMBO_EA),
            IERC20(PHUSD)
        );
        depositPageView = address(dpv);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("DepositPageView", depositPageView, gasUsed);
        if (!isPreview) _writeProgressFile();
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

        uint256 gasBefore = gasleft();
        MintPageView mpv = new MintPageView(
            INFTMinterView(nftMinter),
            BurnRecorder(burnRecorder),
            EYE,
            SCX,
            FLAX,
            SUSDS,
            WBTC
        );
        mintPageView = address(mpv);
        uint256 gasUsed = gasBefore - gasleft();

        _trackDeployment("MintPageView", mintPageView, gasUsed);
        if (!isPreview) _writeProgressFile();
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
        console.log("Registered DepositPageView under key: keccak256('deposit')");

        ViewRouter(viewRouter).setPage(keccak256("mint"), IPageView(mintPageView));
        console.log("Registered MintPageView under key: keccak256('mint')");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("ViewRouterPages", address(0), 0);
        _markConfigured("ViewRouterPages", gasUsed);
        if (!isPreview) _writeProgressFile();
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
            console.log("No existing progress file found, starting fresh");
        }
    }

    function _parseProgressJson(string memory json) internal {
        // Parse all contract names from existing progress file + new ones
        string[] memory names = new string[](18);
        // Existing entries from DeployMainnet.s.sol
        names[0] = "NewPauser";
        names[1] = "AutoDolaYieldStrategy";
        names[2] = "PhusdStableMinter";
        names[3] = "PhlimboEA";
        names[4] = "StableYieldAccumulator";
        names[5] = "TokenAuth";
        names[6] = "DepositView";
        // New entries from this script
        names[7] = "NFTMinter";
        names[8] = "BurnRecorder";
        names[9] = "BurnerEYE";
        names[10] = "BurnerSCX";
        names[11] = "BurnerFlax";
        names[12] = "BalancerPooler";
        names[13] = "GatherWBTC";
        names[14] = "NewStableYieldAccumulator";
        names[15] = "ViewRouter";
        names[16] = "DepositPageView";
        names[17] = "MintPageView";

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

        // Also try to parse config-only entries that have address(0)
        string[] memory configNames = new string[](6);
        configNames[0] = "WithdrawerReconfig";
        configNames[1] = "NFTMinterDispatchers";
        configNames[2] = "DispatcherMinters";
        configNames[3] = "BurnRecorderAuth";
        configNames[4] = "AccumulatorNFTLink";
        configNames[5] = "PauserRegistration";

        for (uint256 i = 0; i < configNames.length; i++) {
            string memory name = configNames[i];

            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".configured")) returns (bool c) {
                if (c) {
                    deployments[name] = ContractDeployment({
                        name: name,
                        addr: address(0),
                        deployed: true,
                        configured: true,
                        deployGas: 0,
                        configGas: 0
                    });
                    contractNames.push(name);
                    console.log("Loaded config step from progress:", name);
                }
            } catch {}
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

    // ========================================
    // Deployment Summary
    // ========================================

    function _printDeploymentSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("");
        console.log("NEW Contracts Deployed:");
        console.log("  - NFTMinter:                  ", nftMinter);
        console.log("  - BurnRecorder:               ", burnRecorder);
        console.log("  - BurnerEYE:                  ", burnerEYE);
        console.log("  - BurnerSCX:                  ", burnerSCX);
        console.log("  - BurnerFlax:                 ", burnerFlax);
        console.log("  - BalancerPooler:             ", balancerPooler);
        console.log("  - GatherWBTC:                 ", gatherWBTC);
        console.log("  - NewStableYieldAccumulator:  ", newAccumulator);
        console.log("  - ViewRouter:                 ", viewRouter);
        console.log("  - DepositPageView:            ", depositPageView);
        console.log("  - MintPageView:               ", mintPageView);
        console.log("");
        console.log("Accumulator Configuration:");
        console.log("  - Reward Token: USDC (", USDC, ")");
        console.log("  - Phlimbo:      ", PHLIMBO_EA);
        console.log("  - Minter:       ", PHUSD_STABLE_MINTER);
        console.log("  - Discount Rate: 2000 bps (20%)");
        console.log("  - YieldStrategies: DOLA + USDC");
        console.log("  - NFTMinter linked for gated claiming");
        console.log("");
        console.log("Withdrawer Reconfiguration:");
        console.log("  - Old accumulator REVOKED on both YieldStrategies");
        console.log("  - New accumulator AUTHORIZED on both YieldStrategies");
        console.log("");
        console.log("Dispatcher Registration (indices 1-5):");
        console.log("  1: BurnerEYE     (EYE,   10% growth)");
        console.log("  2: BurnerSCX     (SCX,   10% growth)");
        console.log("  3: BurnerFlax    (Flax,  10% growth)");
        console.log("  4: BalancerPooler(sUSDS, 5% growth)");
        console.log("  5: GatherWBTC    (WBTC,  12% growth)");
        console.log("");
        console.log("Pauser Registration:");
        console.log("  - NewAccumulator registered with Pauser");
        console.log("  - NFTMinter registered with Pauser");
        console.log("");
        console.log("OLD Accumulator (replaced):", OLD_ACCUMULATOR);
        console.log("");
        console.log("=========================================");
        console.log("  NEXT STEPS");
        console.log("=========================================");
        console.log("1. Update server/deployments/mainnet-addresses.ts with actual addresses");
        console.log("2. Verify all contracts on Etherscan");
        console.log("3. Consider de-registering old accumulator from Pauser");
        console.log("=========================================");
    }
}
