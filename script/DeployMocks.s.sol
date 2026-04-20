// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/mocks/MockPhUSD.sol";
import "../src/mocks/MockRewardToken.sol";
import "../src/mocks/MockUSDS.sol";
import "../src/mocks/MockUSDe.sol";
import "../src/mocks/MockSUSDe.sol";
import "../src/mocks/MockDola.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockSUSDS.sol";
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
import "../src/mocks/MockBalancerRouter.sol";
import {NFTMinterV2} from "@yield-claim-nft/V2/NFTMinterV2.sol";
import {BurnerV2} from "@yield-claim-nft/V2/dispatchers/BurnerV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";
import {GatherV2} from "@yield-claim-nft/V2/dispatchers/GatherV2.sol";
import {NFTMigrator} from "@yield-claim-nft/V2/NFTMigrator.sol";

/**
 * @title DeployMocks
 * @notice Deployment script for Phase 2 contracts on local Anvil
 * @dev Full architecture matching DeployMainnet pattern:
 *
 * Architecture Overview:
 * - Multiple YieldStrategies (vaults) accumulate yield from different stablecoins
 * - PhusdStableMinter manages stablecoin deposits and phUSD minting
 * - StableYieldAccumulator gathers yield from all strategies and offers to users for discounted USDC
 * - USDC is then injected into Phlimbo for distribution via collectReward()
 * - Phlimbo handles staking and reward distribution
 *
 * Key Integration Points:
 * - StableYieldAccumulator deployment and configuration
 * - Multiple YieldStrategy deployment and registration
 * - USDC holding account setup for the collectReward swap mechanism
 * - Phlimbo contract integration for yield distribution
 */
contract DeployMocks is Script {
    // Deployment addresses
    MockPhUSD public phUSD;
    MockRewardToken public rewardToken; // USDC - the consolidated reward token
    MockUSDS public usds; // Underlying USDS stablecoin (plain ERC20)
    MockSUSDS public susds; // ERC4626 savings vault wrapping USDS
    MockUSDe public usde; // Underlying USDe stablecoin (plain ERC20)
    MockSUSDe public susde; // ERC4626 savings vault wrapping USDe
    MockDola public dola;
    MockAutoDOLA public mockAutoDola;
    MockAutoDOLA public mockAutoUSDC;  // Reusing MockAutoDOLA pattern for USDC
    ERC4626YieldStrategy public yieldStrategyDola;
    ERC4626YieldStrategy public yieldStrategyUSDC;
    ERC4626YieldStrategy public yieldStrategyUSDe;
    PhusdStableMinter public minter;
    PhlimboEA public phlimbo;
    MockEYE public eyeToken;
    Pauser public pauser;
    StableYieldAccumulator public stableYieldAccumulator;
    DepositView public depositView;
    ViewRouter public viewRouter;
    DepositPageView public depositPageView;
    MintPageView public mintPageView;

    // NFTMinter infrastructure
    MockSCX public mockSCX;
    MockFlax public mockFlax;
    MockWBTC public mockWBTC;
    MockBalancerPool public mockBalancerPool;
    MockBalancerVault public mockBalancerVault;
    NFTMinter public nftMinter;
    BurnRecorder public burnRecorder;
    Burner public burnerEYE;
    Burner public burnerSCX;
    Burner public burnerFlax;
    BalancerPooler public balancerPooler;
    Gather public gatherWBTC;

    // V2 NFTMinter infrastructure
    MockBalancerRouter public mockBalancerRouter;
    NFTMinterV2 public nftMinterV2;
    BurnerV2 public burnerEYEV2;
    BurnerV2 public burnerSCXV2;
    BurnerV2 public burnerFlaxV2;
    BalancerPoolerV2 public balancerPoolerV2;
    GatherV2 public gatherWBTCV2;
    NFTMigrator public nftMigrator;

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
        usds = new MockUSDS();
        _trackDeployment("MockUSDS", address(usds), gasBefore - gasleft());
        console.log("MockUSDS deployed at:", address(usds));

        // Deploy MockSUSDS (ERC4626 savings vault wrapping USDS)
        gasBefore = gasleft();
        susds = new MockSUSDS(address(usds));
        _trackDeployment("MockSUSDS", address(susds), gasBefore - gasleft());
        console.log("MockSUSDS deployed at:", address(susds));

        // Deposit initial USDS into MockSUSDS to establish baseline shares
        uint256 initialSusdsDeposit = 10_000 * 10**18; // 10,000 USDS
        usds.approve(address(susds), initialSusdsDeposit);
        susds.deposit(initialSusdsDeposit, deployer);
        console.log("Deposited 10,000 USDS into MockSUSDS (baseline shares established)");

        // Deploy MockUSDe (ERC20, 18 decimals) — mirrors mainnet Ethena USDe
        gasBefore = gasleft();
        usde = new MockUSDe();
        _trackDeployment("USDe", address(usde), gasBefore - gasleft());
        console.log("MockUSDe deployed at:", address(usde));

        // Deploy MockSUSDe (ERC4626 savings vault wrapping USDe)
        gasBefore = gasleft();
        susde = new MockSUSDe(address(usde));
        _trackDeployment("SUSDe", address(susde), gasBefore - gasleft());
        console.log("MockSUSDe deployed at:", address(susde));

        // Deposit initial USDe into MockSUSDe to establish baseline shares
        uint256 initialSusdeDeposit = 10_000 * 10**18; // 10,000 USDe
        usde.approve(address(susde), initialSusdeDeposit);
        susde.deposit(initialSusdeDeposit, deployer);
        console.log("Deposited 10,000 USDe into MockSUSDe (baseline shares established)");

        gasBefore = gasleft();
        dola = new MockDola();
        _trackDeployment("MockDola", address(dola), gasBefore - gasleft());
        console.log("MockDola deployed at:", address(dola));

        // ====== PHASE 1.5: EYE Token and Pauser Deployment ======
        console.log("\n=== Phase 1.5: Deploying EYE Token and Pauser ===");

        gasBefore = gasleft();
        eyeToken = new MockEYE();
        _trackDeployment("MockEYE", address(eyeToken), gasBefore - gasleft());
        console.log("MockEYE deployed at:", address(eyeToken));

        gasBefore = gasleft();
        mockSCX = new MockSCX();
        _trackDeployment("MockSCX", address(mockSCX), gasBefore - gasleft());
        console.log("MockSCX deployed at:", address(mockSCX));

        gasBefore = gasleft();
        mockFlax = new MockFlax();
        _trackDeployment("MockFlax", address(mockFlax), gasBefore - gasleft());
        console.log("MockFlax deployed at:", address(mockFlax));

        gasBefore = gasleft();
        mockWBTC = new MockWBTC();
        _trackDeployment("MockWBTC", address(mockWBTC), gasBefore - gasleft());
        console.log("MockWBTC deployed at:", address(mockWBTC));

        gasBefore = gasleft();
        pauser = new Pauser(address(eyeToken));
        _trackDeployment("Pauser", address(pauser), gasBefore - gasleft());
        console.log("Pauser deployed at:", address(pauser));

        // ====== PHASE 2: Yield Strategy Deployment ======
        console.log("\n=== Phase 2: Deploying Yield Strategies ===");

        // ====== PHASE 2.5: AutoDOLA ERC4626 Infrastructure for DOLA YieldStrategy ======
        console.log("\n=== Phase 2.5: Deploying AutoDOLA ERC4626 Infrastructure ===");

        // Deploy MockAutoDOLA (ERC4626 vault wrapper)
        gasBefore = gasleft();
        mockAutoDola = new MockAutoDOLA(address(dola));
        _trackDeployment("MockAutoDOLA", address(mockAutoDola), gasBefore - gasleft());
        console.log("MockAutoDOLA deployed at:", address(mockAutoDola));

        // Deploy ERC4626YieldStrategy wrapping the DOLA vault
        gasBefore = gasleft();
        yieldStrategyDola = new ERC4626YieldStrategy(
            deployer,                // owner
            address(dola),           // underlyingToken (DOLA)
            address(mockAutoDola)    // erc4626Vault
        );
        _trackDeployment("YieldStrategyDola", address(yieldStrategyDola), gasBefore - gasleft());
        console.log("YieldStrategyDola (ERC4626YieldStrategy) deployed at:", address(yieldStrategyDola));

        // ====== PHASE 2.6: AutoUSDC ERC4626 Infrastructure for USDC YieldStrategy ======
        console.log("\n=== Phase 2.6: Deploying AutoUSDC ERC4626 Infrastructure ===");

        // Deploy MockAutoUSDC (ERC4626 vault wrapper for USDC) - reusing MockAutoDOLA pattern
        gasBefore = gasleft();
        mockAutoUSDC = new MockAutoDOLA(address(rewardToken)); // rewardToken is USDC (6 decimals)
        _trackDeployment("MockAutoUSDC", address(mockAutoUSDC), gasBefore - gasleft());
        console.log("MockAutoUSDC deployed at:", address(mockAutoUSDC));

        // Deploy ERC4626YieldStrategy wrapping the USDC vault
        gasBefore = gasleft();
        yieldStrategyUSDC = new ERC4626YieldStrategy(
            deployer,                // owner
            address(rewardToken),    // underlyingToken (USDC)
            address(mockAutoUSDC)    // erc4626Vault
        );
        _trackDeployment("YieldStrategyUSDC", address(yieldStrategyUSDC), gasBefore - gasleft());
        console.log("YieldStrategyUSDC (ERC4626YieldStrategy) deployed at:", address(yieldStrategyUSDC));

        // ====== PHASE 2.7: USDe ERC4626 Infrastructure for USDe YieldStrategy ======
        console.log("\n=== Phase 2.7: Deploying USDe ERC4626 Infrastructure ===");

        // Deploy ERC4626YieldStrategy wrapping the USDe vault (MockSUSDe)
        gasBefore = gasleft();
        yieldStrategyUSDe = new ERC4626YieldStrategy(
            deployer,           // owner
            address(usde),      // underlyingToken (USDe)
            address(susde)      // erc4626Vault (MockSUSDe)
        );
        _trackDeployment("YieldStrategyUSDe", address(yieldStrategyUSDe), gasBefore - gasleft());
        console.log("YieldStrategyUSDe (ERC4626YieldStrategy) deployed at:", address(yieldStrategyUSDe));

        // ====== PHASE 3: Core Contract Deployment ======
        console.log("\n=== Phase 3: Deploying Core Contracts ===");

        // 1. Deploy PhusdStableMinter
        gasBefore = gasleft();
        minter = new PhusdStableMinter(address(phUSD));
        _trackDeployment("PhusdStableMinter", address(minter), gasBefore - gasleft());
        console.log("PhusdStableMinter deployed at:", address(minter));

        // 2. Deploy PhlimboEA
        // Using Linear Depletion model: depletion window = 1 week (604800 seconds)
        uint256 oneWeekInSeconds = 604800;
        gasBefore = gasleft();
        phlimbo = new PhlimboEA(
            address(phUSD),           // _phUSD
            address(rewardToken),     // _rewardToken (USDC)
            oneWeekInSeconds          // _depletionDuration (1 week for linear depletion)
        );
        _trackDeployment("PhlimboEA", address(phlimbo), gasBefore - gasleft());
        console.log("PhlimboEA deployed at:", address(phlimbo));
        console.log("  - Depletion window:", oneWeekInSeconds, "seconds (1 week)");

        // 3. Deploy StableYieldAccumulator
        gasBefore = gasleft();
        stableYieldAccumulator = new StableYieldAccumulator();
        _trackDeployment("StableYieldAccumulator", address(stableYieldAccumulator), gasBefore - gasleft());
        console.log("StableYieldAccumulator deployed at:", address(stableYieldAccumulator));

        // ====== PHASE 3.5: NFTMinter Infrastructure ======
        console.log("\n=== Phase 3.5: Deploying NFTMinter Infrastructure ===");

        // 1. Deploy MockBalancerPool (ERC20 BPT)
        gasBefore = gasleft();
        mockBalancerPool = new MockBalancerPool();
        _trackDeployment("MockBalancerPool", address(mockBalancerPool), gasBefore - gasleft());
        console.log("MockBalancerPool deployed at:", address(mockBalancerPool));

        // 2. Deploy MockBalancerVault
        gasBefore = gasleft();
        mockBalancerVault = new MockBalancerVault(address(mockBalancerPool));
        _trackDeployment("MockBalancerVault", address(mockBalancerVault), gasBefore - gasleft());
        console.log("MockBalancerVault deployed at:", address(mockBalancerVault));

        // Wire MockBalancerPool to recognize the vault
        mockBalancerPool.setVault(address(mockBalancerVault));
        console.log("Wired MockBalancerPool to recognize MockBalancerVault");

        // 3. Deploy NFTMinter
        gasBefore = gasleft();
        nftMinter = new NFTMinter(deployer);
        _trackDeployment("NFTMinter", address(nftMinter), gasBefore - gasleft());
        console.log("NFTMinter deployed at:", address(nftMinter));

        // 4. Deploy BurnRecorder
        gasBefore = gasleft();
        burnRecorder = new BurnRecorder(deployer);
        _trackDeployment("BurnRecorder", address(burnRecorder), gasBefore - gasleft());
        console.log("BurnRecorder deployed at:", address(burnRecorder));

        // 5. Deploy 4 Dispatchers
        // Burner #1: burns MockEYE (prime token = EYE)
        gasBefore = gasleft();
        burnerEYE = new Burner(address(eyeToken), address(burnRecorder), deployer);
        _trackDeployment("BurnerEYE", address(burnerEYE), gasBefore - gasleft());
        console.log("BurnerEYE deployed at:", address(burnerEYE));

        // Burner #2: burns MockSCX (prime token = SCX)
        gasBefore = gasleft();
        burnerSCX = new Burner(address(mockSCX), address(burnRecorder), deployer);
        _trackDeployment("BurnerSCX", address(burnerSCX), gasBefore - gasleft());
        console.log("BurnerSCX deployed at:", address(burnerSCX));

        // Burner #3: burns MockFlax (prime token = Flax)
        gasBefore = gasleft();
        burnerFlax = new Burner(address(mockFlax), address(burnRecorder), deployer);
        _trackDeployment("BurnerFlax", address(burnerFlax), gasBefore - gasleft());
        console.log("BurnerFlax deployed at:", address(burnerFlax));

        // BalancerPooler: user sends sUSDS, single-sided add to phUSD/sUSDS pool boosts phUSD price + liquidity
        gasBefore = gasleft();
        balancerPooler = new BalancerPooler(
            address(susds),              // primeToken_ (sUSDS ERC4626 vault - single-sided add boosts phUSD price)
            address(mockBalancerPool),   // pool_ (BPT token for phUSD/sUSDS pool)
            address(mockBalancerVault),  // vault_
            true,                        // primeTokenIsFirst_
            deployer                     // initialOwner
        );
        _trackDeployment("BalancerPooler", address(balancerPooler), gasBefore - gasleft());
        console.log("BalancerPooler deployed at:", address(balancerPooler));

        // Gather: accumulates WBTC, sends to deployer
        gasBefore = gasleft();
        gatherWBTC = new Gather(
            address(mockWBTC),      // token_ (WBTC)
            deployer,               // recipient_ (deployer)
            deployer                // initialOwner
        );
        _trackDeployment("GatherWBTC", address(gatherWBTC), gasBefore - gasleft());
        console.log("GatherWBTC deployed at:", address(gatherWBTC));

        // 6. Authorize burner dispatchers on BurnRecorder
        burnRecorder.setBurner(address(burnerEYE), true);
        burnRecorder.setBurner(address(burnerSCX), true);
        burnRecorder.setBurner(address(burnerFlax), true);
        console.log("Authorized BurnerEYE, BurnerSCX, BurnerFlax as burners on BurnRecorder");

        // ====== PHASE 3.6: V2 NFTMinter Infrastructure ======
        console.log("\n=== Phase 3.6: Deploying V2 NFTMinter Infrastructure ===");

        // 1. Deploy MockBalancerRouter
        gasBefore = gasleft();
        mockBalancerRouter = new MockBalancerRouter();
        _trackDeployment("MockBalancerRouter", address(mockBalancerRouter), gasBefore - gasleft());
        console.log("MockBalancerRouter deployed at:", address(mockBalancerRouter));

        // 2. Deploy NFTMinterV2
        gasBefore = gasleft();
        nftMinterV2 = new NFTMinterV2(deployer);
        _trackDeployment("NFTMinterV2", address(nftMinterV2), gasBefore - gasleft());
        console.log("NFTMinterV2 deployed at:", address(nftMinterV2));

        // 3. Deploy V2 Dispatchers
        // BurnerV2 #1: burns EYE
        gasBefore = gasleft();
        burnerEYEV2 = new BurnerV2(address(eyeToken), address(burnRecorder), deployer);
        _trackDeployment("BurnerEYEV2", address(burnerEYEV2), gasBefore - gasleft());
        console.log("BurnerEYEV2 deployed at:", address(burnerEYEV2));

        // BurnerV2 #2: burns SCX
        gasBefore = gasleft();
        burnerSCXV2 = new BurnerV2(address(mockSCX), address(burnRecorder), deployer);
        _trackDeployment("BurnerSCXV2", address(burnerSCXV2), gasBefore - gasleft());
        console.log("BurnerSCXV2 deployed at:", address(burnerSCXV2));

        // BurnerV2 #3: burns Flax
        gasBefore = gasleft();
        burnerFlaxV2 = new BurnerV2(address(mockFlax), address(burnRecorder), deployer);
        _trackDeployment("BurnerFlaxV2", address(burnerFlaxV2), gasBefore - gasleft());
        console.log("BurnerFlaxV2 deployed at:", address(burnerFlaxV2));

        // BalancerPoolerV2: prime token is USDS (derived from sUSDS via IERC4626.asset())
        gasBefore = gasleft();
        balancerPoolerV2 = new BalancerPoolerV2(
            address(susds),              // sUSDS_ (ERC4626 vault)
            address(mockBalancerPool),   // pool_ (BPT token)
            address(mockBalancerVault),  // vault_
            address(mockBalancerRouter), // router_
            true,                        // sUSDSIsFirst_
            deployer                     // initialOwner
        );
        _trackDeployment("BalancerPoolerV2", address(balancerPoolerV2), gasBefore - gasleft());
        console.log("BalancerPoolerV2 deployed at:", address(balancerPoolerV2));

        // GatherV2: accumulates WBTC, sends to deployer
        gasBefore = gasleft();
        gatherWBTCV2 = new GatherV2(
            address(mockWBTC),      // token_ (WBTC)
            deployer,               // recipient_ (deployer)
            deployer                // initialOwner
        );
        _trackDeployment("GatherWBTCV2", address(gatherWBTCV2), gasBefore - gasleft());
        console.log("GatherWBTCV2 deployed at:", address(gatherWBTCV2));

        // 4. Register V2 dispatchers with NFTMinterV2
        uint256 v2InitialPrice = 100 * 10 ** 18;
        uint256 v2WBTCInitialPrice = 100 * 10 ** 8; // WBTC has 8 decimals

        nftMinterV2.registerDispatcher(address(burnerEYEV2), v2InitialPrice, 200); // 2% growth
        console.log("Registered BurnerEYEV2 dispatcher with NFTMinterV2 (index 1, 2% growth)");

        nftMinterV2.registerDispatcher(address(burnerSCXV2), v2InitialPrice, 200); // 2% growth
        console.log("Registered BurnerSCXV2 dispatcher with NFTMinterV2 (index 2, 2% growth)");

        nftMinterV2.registerDispatcher(address(burnerFlaxV2), v2InitialPrice, 200); // 2% growth
        console.log("Registered BurnerFlaxV2 dispatcher with NFTMinterV2 (index 3, 2% growth)");

        nftMinterV2.registerDispatcher(address(balancerPoolerV2), v2InitialPrice, 10); // 0.1% growth
        console.log("Registered BalancerPoolerV2 dispatcher with NFTMinterV2 (index 4, 0.1% growth)");

        nftMinterV2.registerDispatcher(address(gatherWBTCV2), v2WBTCInitialPrice, 1000); // 10% growth
        console.log("Registered GatherWBTCV2 dispatcher with NFTMinterV2 (index 5, 10% growth)");

        // 5. Set minter on each V2 dispatcher
        burnerEYEV2.setMinter(address(nftMinterV2));
        console.log("BurnerEYEV2.setMinter -> NFTMinterV2");

        burnerSCXV2.setMinter(address(nftMinterV2));
        console.log("BurnerSCXV2.setMinter -> NFTMinterV2");

        burnerFlaxV2.setMinter(address(nftMinterV2));
        console.log("BurnerFlaxV2.setMinter -> NFTMinterV2");

        balancerPoolerV2.setMinter(address(nftMinterV2));
        console.log("BalancerPoolerV2.setMinter -> NFTMinterV2");

        gatherWBTCV2.setMinter(address(nftMinterV2));
        console.log("GatherWBTCV2.setMinter -> NFTMinterV2");

        // 6. Authorize V2 burner dispatchers on BurnRecorder
        burnRecorder.setBurner(address(burnerEYEV2), true);
        burnRecorder.setBurner(address(burnerSCXV2), true);
        burnRecorder.setBurner(address(burnerFlaxV2), true);
        console.log("Authorized BurnerEYEV2, BurnerSCXV2, BurnerFlaxV2 as burners on BurnRecorder");

        // 7. Deploy NFTMigrator
        gasBefore = gasleft();
        nftMigrator = new NFTMigrator(address(nftMinter), address(nftMinterV2), deployer);
        _trackDeployment("NFTMigrator", address(nftMigrator), gasBefore - gasleft());
        console.log("NFTMigrator deployed at:", address(nftMigrator));

        // 8. Configure NFTMigrator permissions
        // NFTMigrator needs to burn V1 NFTs
        nftMinter.setAuthorizedBurner(address(nftMigrator), true);
        console.log("NFTMinter.setAuthorizedBurner(NFTMigrator, true)");

        // NFTMigrator needs to mint V2 NFTs via mintFor()
        nftMinterV2.setAuthorizedMinter(address(nftMigrator), true);
        console.log("NFTMinterV2.setAuthorizedMinter(NFTMigrator, true)");

        // 9. Configure V1-to-V2 index mapping on NFTMigrator (1:1 mapping)
        uint256[] memory v1Indexes = new uint256[](5);
        uint256[] memory v2Indexes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            v1Indexes[i] = i + 1;
            v2Indexes[i] = i + 1;
        }
        nftMigrator.setMappings(v1Indexes, v2Indexes);
        nftMigrator.setInitialized();
        console.log("NFTMigrator index mappings set and initialized (1:1 for indices 1-5)");

        // ====== PHASE 4: Token Authorization ======
        console.log("\n=== Phase 4: Token Authorization ===");

        // Authorize PhlimboEA as phUSD minter
        phUSD.setMinter(address(phlimbo), true);
        console.log("Authorized PhlimboEA as phUSD minter");

        // Authorize PhusdStableMinter as phUSD minter
        phUSD.setMinter(address(minter), true);
        console.log("Authorized PhusdStableMinter as phUSD minter");

        // ====== PHASE 5: YieldStrategy Configuration ======
        console.log("\n=== Phase 5: YieldStrategy Configuration ===");

        // Authorize minter as client on all yield strategies
        yieldStrategyDola.setClient(address(minter), true);
        yieldStrategyUSDC.setClient(address(minter), true);
        console.log("Authorized minter as yield strategy client (all strategies)");

        // ====== PHASE 6: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 6: PhusdStableMinter Configuration ===");

        // Approve yield strategies for their respective tokens
        minter.approveYS(address(dola), address(yieldStrategyDola));
        minter.approveYS(address(rewardToken), address(yieldStrategyUSDC)); // USDC
        console.log("Approved yield strategies for their tokens");

        // Register DOLA as stablecoin (18 decimals)
        minter.registerStablecoin(
            address(dola),               // stablecoin
            address(yieldStrategyDola),  // yieldStrategy
            1e18,                        // exchangeRate (1:1)
            18                           // decimals
        );
        console.log("Registered DOLA as stablecoin");

        // Register USDC as stablecoin (6 decimals)
        minter.registerStablecoin(
            address(rewardToken),        // stablecoin (USDC)
            address(yieldStrategyUSDC),  // yieldStrategy
            1e18,                        // exchangeRate (1:1)
            6                            // decimals
        );
        console.log("Registered USDC as stablecoin");

        // ====== PHASE 7: Phlimbo Configuration ======
        console.log("\n=== Phase 7: Phlimbo Configuration ===");

        // Desired APY = 0: no phUSD minted by phlimbo, yield comes only from the yield funnel
        phlimbo.setDesiredAPY(0);
        console.log("Set desired APY (preview): 0 bps");

        // Wait for next block (simulate block advancement)
        vm.roll(block.number + 1);

        // Commit APY change
        phlimbo.setDesiredAPY(0);
        console.log("Set desired APY (commit): 0 bps");

        // ====== PHASE 7.5: StableYieldAccumulator Configuration ======
        console.log("\n=== Phase 7.5: StableYieldAccumulator Configuration ===");

        // Set reward token to USDC (rewardToken is MockRewardToken which is USDC)
        stableYieldAccumulator.setRewardToken(address(rewardToken));
        console.log("Set reward token to USDC:", address(rewardToken));

        // Set Phlimbo as the reward recipient
        stableYieldAccumulator.setPhlimbo(address(phlimbo));
        console.log("Set Phlimbo as reward recipient:", address(phlimbo));

        // Set minter address for yield queries
        stableYieldAccumulator.setMinter(address(minter));
        console.log("Set minter for yield queries:", address(minter));

        // Configure USDC token (6 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(rewardToken), 6, 1e18);
        console.log("Configured USDC token config (6 decimals, 1:1 rate)");

        // Configure DOLA token (18 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(dola), 18, 1e18);
        console.log("Configured DOLA token config (18 decimals, 1:1 rate)");

        // Add YieldStrategyDola to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyDola), address(dola));
        console.log("Added YieldStrategyDola to yield strategy registry");

        // Add YieldStrategyUSDC to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyUSDC), address(rewardToken));
        console.log("Added YieldStrategyUSDC to yield strategy registry");

        // Set discount rate (20% = 2000 basis points)
        stableYieldAccumulator.setDiscountRate(2000);
        console.log("Set discount rate to 2000 basis points (20%)");

        // Approve Phlimbo to spend reward tokens with max approval
        stableYieldAccumulator.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo to spend reward tokens from StableYieldAccumulator");

        // CRITICAL: Authorize StableYieldAccumulator as withdrawer on all yield strategies
        // This allows StableYieldAccumulator to withdraw yield from the strategies
        yieldStrategyDola.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyDola");

        yieldStrategyUSDC.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyUSDC");

        // ====== PHASE 8: Pauser Registration ======
        console.log("\n=== Phase 8: Pauser Registration ===");
        console.log("CRITICAL: setPauser() must be called BEFORE register()");

        // Register PhusdStableMinter with Pauser
        // Step 1: Set pauser address on contract FIRST
        minter.setPauser(address(pauser));
        console.log("PhusdStableMinter.setPauser() called");
        // Step 2: Register with pauser (validates that pauser() == address(this))
        pauser.register(address(minter));
        console.log("Pauser.register(PhusdStableMinter) completed");

        // Register PhlimboEA with Pauser
        // Step 1: Set pauser address on contract FIRST
        phlimbo.setPauser(address(pauser));
        console.log("PhlimboEA.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(phlimbo));
        console.log("Pauser.register(PhlimboEA) completed");

        // Register StableYieldAccumulator with Pauser
        // Step 1: Set pauser address on contract FIRST
        stableYieldAccumulator.setPauser(address(pauser));
        console.log("StableYieldAccumulator.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(stableYieldAccumulator));
        console.log("Pauser.register(StableYieldAccumulator) completed");
        // Register NFTMinter with Pauser
        nftMinter.setPauser(address(pauser));
        console.log("NFTMinter.setPauser() called");
        pauser.register(address(nftMinter));
        console.log("Pauser.register(NFTMinter) completed");

        // Register NFTMinterV2 with Pauser
        nftMinterV2.setPauser(address(pauser));
        console.log("NFTMinterV2.setPauser() called");
        pauser.register(address(nftMinterV2));
        console.log("Pauser.register(NFTMinterV2) completed");

        console.log("All protocol contracts registered with Pauser");

        // ====== PHASE 8.5: NFTMinter Configuration ======
        console.log("\n=== Phase 8.5: NFTMinter V1 Configuration ===");

        // Register each dispatcher with NFTMinter (initialPrice = 100e18, varying growthBps)
        uint256 initialPrice = 100 * 10 ** 18;
        uint256 wbtcInitialPrice = 100 * 10 ** 8; // WBTC has 8 decimals

        nftMinter.registerDispatcher(address(burnerEYE), initialPrice, 200); // 2% growth
        console.log("Registered BurnerEYE dispatcher with NFTMinter (index 1, 2% growth)");

        nftMinter.registerDispatcher(address(burnerSCX), initialPrice, 200); // 2% growth
        console.log("Registered BurnerSCX dispatcher with NFTMinter (index 2, 2% growth)");

        nftMinter.registerDispatcher(address(burnerFlax), initialPrice, 200); // 2% growth
        console.log("Registered BurnerFlax dispatcher with NFTMinter (index 3, 2% growth)");

        nftMinter.registerDispatcher(address(balancerPooler), initialPrice, 10); // 0.1% growth
        console.log("Registered BalancerPooler dispatcher with NFTMinter (index 4, 0.1% growth)");

        nftMinter.registerDispatcher(address(gatherWBTC), wbtcInitialPrice, 1000); // 10% growth
        console.log("Registered GatherWBTC dispatcher with NFTMinter (index 5, 10% growth)");

        // Set minter on each dispatcher
        burnerEYE.setMinter(address(nftMinter));
        console.log("BurnerEYE.setMinter -> NFTMinter");

        burnerSCX.setMinter(address(nftMinter));
        console.log("BurnerSCX.setMinter -> NFTMinter");

        burnerFlax.setMinter(address(nftMinter));
        console.log("BurnerFlax.setMinter -> NFTMinter");

        balancerPooler.setMinter(address(nftMinter));
        console.log("BalancerPooler.setMinter -> NFTMinter");

        gatherWBTC.setMinter(address(nftMinter));
        console.log("GatherWBTC.setMinter -> NFTMinter");

        // ====== PHASE 8.6: Mint V1 Test NFTs for Migration Testing ======
        console.log("\n=== Phase 8.6: Mint V1 Test NFTs for Migration Testing ===");

        // Mint V1 NFTs for dispatcher indices 1-3, 5 for migration testing.
        // Index 4 (BalancerPooler) is skipped because its dispatch triggers the Balancer vault
        // unlock/callback flow which doesn't work cleanly with MockBalancerVault encoding.

        // Index 1: BurnerEYE — approve EYE, mint
        eyeToken.approve(address(nftMinter), initialPrice);
        nftMinter.mint(address(eyeToken), 1, deployer);
        console.log("Minted V1 NFT index 1 (BurnerEYE) for deployer");

        // Index 2: BurnerSCX — approve SCX, mint
        mockSCX.approve(address(nftMinter), initialPrice);
        nftMinter.mint(address(mockSCX), 2, deployer);
        console.log("Minted V1 NFT index 2 (BurnerSCX) for deployer");

        // Index 3: BurnerFlax — approve Flax, mint
        mockFlax.approve(address(nftMinter), initialPrice);
        nftMinter.mint(address(mockFlax), 3, deployer);
        console.log("Minted V1 NFT index 3 (BurnerFlax) for deployer");

        // Index 5: GatherWBTC — priced in 8-decimal WBTC
        mockWBTC.mint(deployer, wbtcInitialPrice);
        mockWBTC.approve(address(nftMinter), wbtcInitialPrice);
        nftMinter.mint(address(mockWBTC), 5, deployer);
        console.log("Minted V1 NFT index 5 (GatherWBTC) for deployer");

        console.log("4 V1 test NFTs minted for migration testing (indices 1,2,3,5; index 4 skipped due to mock vault limitation)");

        // ====== PHASE 8.7: SYA Integration — V2 Replaces V1 ======
        console.log("\n=== Phase 8.7: SYA Integration - V2 Replaces V1 ===");

        // Set V2 NFTMinter on StableYieldAccumulator (replaces V1)
        stableYieldAccumulator.setNFTMinter(address(nftMinterV2));
        console.log("StableYieldAccumulator.setNFTMinter -> NFTMinterV2 (V2 replaces V1)");

        // Set StableYieldAccumulator as authorized burner on V2 NFTMinter
        nftMinterV2.setAuthorizedBurner(address(stableYieldAccumulator), true);
        console.log("NFTMinterV2.setAuthorizedBurner(StableYieldAccumulator, true)");

        // Revoke SYA's burner authorization on V1 NFTMinter
        nftMinter.setAuthorizedBurner(address(stableYieldAccumulator), false);
        console.log("NFTMinter.setAuthorizedBurner(StableYieldAccumulator, false) - V1 deregistered");

        // ====== PHASE 9: Seed YieldStrategyDola with PhUSD Minting ======
        console.log("\n=== Phase 9: Seed YieldStrategyDola with PhUSD Minting ===");

        uint256 dolaAmount = 5000 * 10**18; // 5000 DOLA

        // Deployer already has DOLA from MockDola constructor mint
        // Approve minter to spend deployer's DOLA
        dola.approve(address(minter), dolaAmount);
        console.log("Approved minter to spend 5000 DOLA");

        // Mint PhUSD by depositing DOLA through the minter
        // This will: 1) Transfer DOLA to minter, 2) Deposit DOLA into YieldStrategyDola, 3) Mint PhUSD to deployer
        minter.mint(address(dola), dolaAmount);
        console.log("Minted PhUSD with 5000 DOLA");
        console.log("  - DOLA deposited to YieldStrategyDola");
        console.log("  - PhUSD minted to deployer:", deployer);

        // ====== PHASE 9.5: Add DOLA Yield to MockAutoDOLA Vault ======
        console.log("\n=== Phase 9.5: Add DOLA Yield to MockAutoDOLA Vault ===");

        uint256 yieldAmount = 1000 * 10**18; // 1000 DOLA

        // To create yield, we must transfer DOLA directly to the vault WITHOUT minting shares.
        // This increases totalAssets without increasing totalSupply, raising share price.
        // Using deposit() would mint new shares, keeping share price at 1:1 (no yield).

        // Mint 1000 DOLA directly to the vault address (not to deployer)
        dola.mint(address(mockAutoDola), yieldAmount);
        console.log("Minted 1000 DOLA directly to MockAutoDOLA vault as yield");
        console.log("  - totalAssets increased without minting new shares");
        console.log("  - Share price now > 1, creating claimable yield");
        console.log("  - YieldStrategyDola can claim this yield via ERC4626YieldStrategy");

        // ====== PHASE 9.55: Seed YieldStrategyUSDC with PhUSD Minting ======
        console.log("\n=== Phase 9.55: Seed YieldStrategyUSDC with PhUSD Minting ===");

        uint256 usdcAmount = 5000 * 10**6; // 5000 USDC (6 decimals)

        // Deployer already has USDC from MockRewardToken constructor mint
        // Approve minter to spend deployer's USDC
        rewardToken.approve(address(minter), usdcAmount);
        console.log("Approved minter to spend 5000 USDC");

        // Mint PhUSD by depositing USDC through the minter
        // This will: 1) Transfer USDC to minter, 2) Deposit USDC into YieldStrategyUSDC, 3) Mint PhUSD to deployer
        minter.mint(address(rewardToken), usdcAmount);
        console.log("Minted PhUSD with 5000 USDC");
        console.log("  - USDC deposited to YieldStrategyUSDC");
        console.log("  - PhUSD minted to deployer:", deployer);

        _trackDeployment("UsdcSeeding", address(0), 0);
        _markConfigured("UsdcSeeding", 0);

        // ====== PHASE 9.6: Add USDC Yield to MockAutoUSDC Vault ======
        console.log("\n=== Phase 9.6: Add USDC Yield to MockAutoUSDC Vault ===");

        uint256 usdcYieldAmount = 1000 * 10**6; // 1000 USDC (6 decimals)

        // Mint 1000 USDC directly to the vault address (not to deployer)
        rewardToken.mint(address(mockAutoUSDC), usdcYieldAmount);
        console.log("Minted 1000 USDC directly to MockAutoUSDC vault as yield");
        console.log("  - totalAssets increased without minting new shares");
        console.log("  - Share price now > 1, creating claimable yield");
        console.log("  - YieldStrategyUSDC can claim this yield via ERC4626YieldStrategy");

        // ====== PHASE 10: Deploy DepositView for UI Polling ======
        console.log("\n=== Phase 10: Deploy DepositView for UI Polling ===");

        depositView = new DepositView(
            IPhlimbo(address(phlimbo)),
            IERC20(address(phUSD))
        );
        _trackDeployment("DepositView", address(depositView), 0);
        console.log("DepositView deployed at:", address(depositView));

        // ====== PHASE 11: Deploy ViewRouter + DepositPageView ======
        console.log("\n=== Phase 11: Deploy ViewRouter + DepositPageView ===");

        gasBefore = gasleft();
        viewRouter = new ViewRouter();
        _trackDeployment("ViewRouter", address(viewRouter), gasBefore - gasleft());
        console.log("ViewRouter deployed at:", address(viewRouter));

        gasBefore = gasleft();
        depositPageView = new DepositPageView(
            IPhlimbo(address(phlimbo)),
            IERC20(address(phUSD))
        );
        _trackDeployment("DepositPageView", address(depositPageView), gasBefore - gasleft());
        console.log("DepositPageView deployed at:", address(depositPageView));

        // Register DepositPageView with ViewRouter
        viewRouter.setPage(keccak256("deposit"), IPageView(address(depositPageView)));
        console.log("Registered DepositPageView with ViewRouter under key: keccak256('deposit')");

        gasBefore = gasleft();
        mintPageView = new MintPageView(
            INFTMinterView(address(nftMinterV2)),
            burnRecorder,
            address(eyeToken),
            address(mockSCX),
            address(mockFlax),
            address(usds),
            address(mockWBTC)
        );
        _trackDeployment("MintPageView", address(mintPageView), gasBefore - gasleft());
        console.log("MintPageView deployed at:", address(mintPageView));

        // Register MintPageView with ViewRouter
        viewRouter.setPage(keccak256("mint"), IPageView(address(mintPageView)));
        console.log("Registered MintPageView with ViewRouter under key: keccak256('mint')");

        // Mark configurations as complete (gas tracking simplified to avoid stack depth issues)
        _markConfigured("MockPhUSD", 0);
        _markConfigured("MockUSDC", 0);
        _markConfigured("MockUSDS", 0);
        _markConfigured("MockSUSDS", 0);
        _markConfigured("USDe", 0);
        _markConfigured("SUSDe", 0);
        _markConfigured("MockDola", 0);
        _markConfigured("MockEYE", 0);
        _markConfigured("MockSCX", 0);
        _markConfigured("MockFlax", 0);
        _markConfigured("MockWBTC", 0);
        _markConfigured("MockAutoDOLA", 0);
        _markConfigured("MockAutoUSDC", 0);
        _markConfigured("YieldStrategyDola", 0);
        _markConfigured("YieldStrategyUSDC", 0);
        _markConfigured("YieldStrategyUSDe", 0);
        _markConfigured("PhusdStableMinter", 0);
        _markConfigured("PhlimboEA", 0);
        _markConfigured("StableYieldAccumulator", 0);
        _markConfigured("Pauser", 0);
        _markConfigured("MockBalancerPool", 0);
        _markConfigured("MockBalancerVault", 0);
        _markConfigured("NFTMinter", 0);
        _markConfigured("BurnRecorder", 0);
        _markConfigured("BurnerEYE", 0);
        _markConfigured("BurnerSCX", 0);
        _markConfigured("BurnerFlax", 0);
        _markConfigured("BalancerPooler", 0);
        _markConfigured("GatherWBTC", 0);
        _markConfigured("MockBalancerRouter", 0);
        _markConfigured("NFTMinterV2", 0);
        _markConfigured("BurnerEYEV2", 0);
        _markConfigured("BurnerSCXV2", 0);
        _markConfigured("BurnerFlaxV2", 0);
        _markConfigured("BalancerPoolerV2", 0);
        _markConfigured("GatherWBTCV2", 0);
        _markConfigured("NFTMigrator", 0);
        _markConfigured("DepositView", 0);
        _markConfigured("ViewRouter", 0);
        _markConfigured("DepositPageView", 0);
        _markConfigured("MintPageView", 0);

        // Track seeding completion
        _trackDeployment("Seeding", address(0), 0);
        _markConfigured("Seeding", 0);
        _trackDeployment("DolaYield", address(0), 0);
        _markConfigured("DolaYield", 0);
        _trackDeployment("UsdcYield", address(0), 0);
        _markConfigured("UsdcYield", 0);

        vm.stopBroadcast();

        // ====== Write Progress File ======
        console.log("\n=== Writing Deployment Progress ===");
        _writeProgressFile();

        console.log("\n=== Deployment Complete ===");
        console.log("All contracts deployed and configured successfully!");
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
        console.log("Global Pauser System:");
        console.log("  - Pauser contract deployed with MockEYE token");
        console.log("  - PhusdStableMinter registered with Pauser");
        console.log("  - PhlimboEA registered with Pauser");
        console.log("  - StableYieldAccumulator registered with Pauser");
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
        console.log("  - ERC4626YieldStrategy can claim this yield via StableYieldAccumulator");
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
