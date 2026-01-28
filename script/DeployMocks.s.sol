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
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "../src/views/DepositView.sol";

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
    MockUSDT public usdt;
    MockUSDS public usds;
    MockDola public dola;
    MockToke public toke;
    MockAutoDOLA public mockAutoDola;
    MockMainRewarder public mockMainRewarder;
    MockAutoDOLA public mockAutoUSDC;  // Reusing MockAutoDOLA pattern for USDC
    MockMainRewarder public mockMainRewarderUSDC;
    MockYieldStrategy public yieldStrategyUSDT;
    MockYieldStrategy public yieldStrategyUSDS;
    AutoPoolYieldStrategy public yieldStrategyDola;
    AutoPoolYieldStrategy public yieldStrategyUSDC;
    PhusdStableMinter public minter;
    PhlimboEA public phlimbo;
    MockEYE public eyeToken;
    Pauser public pauser;
    StableYieldAccumulator public stableYieldAccumulator;
    DepositView public depositView;

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
        usds = new MockUSDS();
        _trackDeployment("MockUSDS", address(usds), gasBefore - gasleft());
        console.log("MockUSDS deployed at:", address(usds));

        gasBefore = gasleft();
        dola = new MockDola();
        _trackDeployment("MockDola", address(dola), gasBefore - gasleft());
        console.log("MockDola deployed at:", address(dola));

        gasBefore = gasleft();
        toke = new MockToke();
        _trackDeployment("MockToke", address(toke), gasBefore - gasleft());
        console.log("MockToke deployed at:", address(toke));

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
        yieldStrategyUSDS = new MockYieldStrategy();
        _trackDeployment("YieldStrategyUSDS", address(yieldStrategyUSDS), gasBefore - gasleft());
        console.log("YieldStrategyUSDS deployed at:", address(yieldStrategyUSDS));

        // ====== PHASE 2.5: AutoDola Infrastructure for DOLA YieldStrategy ======
        console.log("\n=== Phase 2.5: Deploying AutoDola Infrastructure ===");

        // Deploy MockAutoDOLA (ERC4626 vault wrapper)
        gasBefore = gasleft();
        mockAutoDola = new MockAutoDOLA(address(dola));
        _trackDeployment("MockAutoDOLA", address(mockAutoDola), gasBefore - gasleft());
        console.log("MockAutoDOLA deployed at:", address(mockAutoDola));

        // Deploy MockMainRewarder (staking/rewards contract)
        gasBefore = gasleft();
        mockMainRewarder = new MockMainRewarder(address(mockAutoDola), address(toke));
        _trackDeployment("MockMainRewarder", address(mockMainRewarder), gasBefore - gasleft());
        console.log("MockMainRewarder deployed at:", address(mockMainRewarder));

        // Wire MockAutoDOLA to use MockMainRewarder
        mockAutoDola.setRewarder(address(mockMainRewarder));
        console.log("Wired MockAutoDOLA to use MockMainRewarder");

        // Deploy real AutoPoolYieldStrategy with mocked dependencies (DOLA)
        gasBefore = gasleft();
        yieldStrategyDola = new AutoPoolYieldStrategy(
            deployer,                    // owner
            address(dola),               // underlyingToken (DOLA)
            address(toke),               // tokeToken
            address(mockAutoDola),       // autoPoolVault
            address(mockMainRewarder)    // mainRewarder
        );
        _trackDeployment("YieldStrategyDola", address(yieldStrategyDola), gasBefore - gasleft());
        console.log("YieldStrategyDola (AutoPoolYieldStrategy) deployed at:", address(yieldStrategyDola));

        // ====== PHASE 2.6: AutoPool Infrastructure for USDC YieldStrategy ======
        console.log("\n=== Phase 2.6: Deploying AutoPool Infrastructure for USDC ===");

        // Deploy MockAutoUSDC (ERC4626 vault wrapper for USDC) - reusing MockAutoDOLA pattern
        gasBefore = gasleft();
        mockAutoUSDC = new MockAutoDOLA(address(rewardToken)); // rewardToken is USDC (6 decimals)
        _trackDeployment("MockAutoUSDC", address(mockAutoUSDC), gasBefore - gasleft());
        console.log("MockAutoUSDC deployed at:", address(mockAutoUSDC));

        // Deploy MockMainRewarder for USDC (staking/rewards contract)
        gasBefore = gasleft();
        mockMainRewarderUSDC = new MockMainRewarder(address(mockAutoUSDC), address(toke));
        _trackDeployment("MockMainRewarderUSDC", address(mockMainRewarderUSDC), gasBefore - gasleft());
        console.log("MockMainRewarderUSDC deployed at:", address(mockMainRewarderUSDC));

        // Wire MockAutoUSDC to use MockMainRewarderUSDC
        mockAutoUSDC.setRewarder(address(mockMainRewarderUSDC));
        console.log("Wired MockAutoUSDC to use MockMainRewarderUSDC");

        // Deploy AutoPoolYieldStrategy for USDC
        gasBefore = gasleft();
        yieldStrategyUSDC = new AutoPoolYieldStrategy(
            deployer,                        // owner
            address(rewardToken),            // underlyingToken (USDC)
            address(toke),                   // tokeToken
            address(mockAutoUSDC),           // autoPoolVault
            address(mockMainRewarderUSDC)    // mainRewarder
        );
        _trackDeployment("YieldStrategyUSDC", address(yieldStrategyUSDC), gasBefore - gasleft());
        console.log("YieldStrategyUSDC (AutoPoolYieldStrategy) deployed at:", address(yieldStrategyUSDC));

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
        yieldStrategyUSDT.setClient(address(minter), true);
        yieldStrategyUSDS.setClient(address(minter), true);
        yieldStrategyDola.setClient(address(minter), true);
        yieldStrategyUSDC.setClient(address(minter), true);
        console.log("Authorized minter as yield strategy client (all strategies)");

        // ====== PHASE 6: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 6: PhusdStableMinter Configuration ===");

        // Approve yield strategies for their respective tokens
        minter.approveYS(address(usdt), address(yieldStrategyUSDT));
        minter.approveYS(address(usds), address(yieldStrategyUSDS));
        minter.approveYS(address(dola), address(yieldStrategyDola));
        minter.approveYS(address(rewardToken), address(yieldStrategyUSDC)); // USDC
        console.log("Approved yield strategies for their tokens");

        // Register USDT as stablecoin (6 decimals)
        minter.registerStablecoin(
            address(usdt),              // stablecoin
            address(yieldStrategyUSDT), // yieldStrategy
            1e18,                       // exchangeRate (1:1)
            6                           // decimals
        );
        console.log("Registered USDT as stablecoin");

        // Register USDS as stablecoin (18 decimals)
        minter.registerStablecoin(
            address(usds),               // stablecoin
            address(yieldStrategyUSDS),  // yieldStrategy
            1e18,                        // exchangeRate (1:1)
            18                           // decimals
        );
        console.log("Registered USDS as stablecoin");

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

        // Set desired APY (5% = 500 basis points) - two-step process
        phlimbo.setDesiredAPY(500);
        console.log("Set desired APY (preview): 500 bps");

        // Wait for next block (simulate block advancement)
        vm.roll(block.number + 1);

        // Commit APY change
        phlimbo.setDesiredAPY(500);
        console.log("Set desired APY (commit): 500 bps");

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

        // Configure USDT token (6 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(usdt), 6, 1e18);
        console.log("Configured USDT token config (6 decimals, 1:1 rate)");

        // Configure USDS token (18 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(usds), 18, 1e18);
        console.log("Configured USDS token config (18 decimals, 1:1 rate)");

        // Configure DOLA token (18 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(dola), 18, 1e18);
        console.log("Configured DOLA token config (18 decimals, 1:1 rate)");

        // Add YieldStrategyUSDT to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyUSDT), address(usdt));
        console.log("Added YieldStrategyUSDT to yield strategy registry");

        // Add YieldStrategyUSDS to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyUSDS), address(usds));
        console.log("Added YieldStrategyUSDS to yield strategy registry");

        // Add YieldStrategyDola to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyDola), address(dola));
        console.log("Added YieldStrategyDola to yield strategy registry");

        // Add YieldStrategyUSDC to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyUSDC), address(rewardToken));
        console.log("Added YieldStrategyUSDC to yield strategy registry");

        // Set discount rate (e.g., 2% = 200 basis points)
        stableYieldAccumulator.setDiscountRate(200);
        console.log("Set discount rate to 200 basis points (2%)");

        // Approve Phlimbo to spend reward tokens with max approval
        stableYieldAccumulator.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo to spend reward tokens from StableYieldAccumulator");

        // CRITICAL: Authorize StableYieldAccumulator as withdrawer on all yield strategies
        // This allows StableYieldAccumulator to withdraw yield from the strategies
        yieldStrategyUSDT.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyUSDT");

        yieldStrategyUSDS.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyUSDS");

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
        console.log("All protocol contracts registered with Pauser");

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
        console.log("  - YieldStrategyDola can claim this yield via AutoPoolYieldStrategy");

        // ====== PHASE 9.6: Add USDC Yield to MockAutoUSDC Vault ======
        console.log("\n=== Phase 9.6: Add USDC Yield to MockAutoUSDC Vault ===");

        uint256 usdcYieldAmount = 1000 * 10**6; // 1000 USDC (6 decimals)

        // Mint 1000 USDC directly to the vault address (not to deployer)
        rewardToken.mint(address(mockAutoUSDC), usdcYieldAmount);
        console.log("Minted 1000 USDC directly to MockAutoUSDC vault as yield");
        console.log("  - totalAssets increased without minting new shares");
        console.log("  - Share price now > 1, creating claimable yield");
        console.log("  - YieldStrategyUSDC can claim this yield via AutoPoolYieldStrategy");

        // ====== PHASE 10: Deploy DepositView for UI Polling ======
        console.log("\n=== Phase 10: Deploy DepositView for UI Polling ===");

        depositView = new DepositView(
            IPhlimbo(address(phlimbo)),
            IERC20(address(phUSD))
        );
        _trackDeployment("DepositView", address(depositView), 0);
        console.log("DepositView deployed at:", address(depositView));

        // Mark configurations as complete (gas tracking simplified to avoid stack depth issues)
        _markConfigured("MockPhUSD", 0);
        _markConfigured("MockUSDC", 0);
        _markConfigured("MockUSDT", 0);
        _markConfigured("MockUSDS", 0);
        _markConfigured("MockDola", 0);
        _markConfigured("MockToke", 0);
        _markConfigured("MockEYE", 0);
        _markConfigured("MockAutoDOLA", 0);
        _markConfigured("MockMainRewarder", 0);
        _markConfigured("MockAutoUSDC", 0);
        _markConfigured("MockMainRewarderUSDC", 0);
        _markConfigured("YieldStrategyUSDT", 0);
        _markConfigured("YieldStrategyUSDS", 0);
        _markConfigured("YieldStrategyDola", 0);
        _markConfigured("YieldStrategyUSDC", 0);
        _markConfigured("PhusdStableMinter", 0);
        _markConfigured("PhlimboEA", 0);
        _markConfigured("StableYieldAccumulator", 0);
        _markConfigured("Pauser", 0);
        _markConfigured("DepositView", 0);

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
        console.log("  - USDT -> YieldStrategyUSDT (MockYieldStrategy) -> PhusdStableMinter");
        console.log("  - USDS -> YieldStrategyUSDS (MockYieldStrategy) -> PhusdStableMinter");
        console.log("  - DOLA -> YieldStrategyDola (AutoPoolYieldStrategy) -> PhusdStableMinter");
        console.log("    \\-> AutoPoolYieldStrategy uses real contract with mocked dependencies:");
        console.log("        - MockAutoDOLA (ERC4626 vault)");
        console.log("        - MockMainRewarder (TOKE rewards)");
        console.log("        - MockToke (reward token)");
        console.log("  - USDC -> YieldStrategyUSDC (AutoPoolYieldStrategy) -> PhusdStableMinter");
        console.log("    \\-> AutoPoolYieldStrategy uses real contract with mocked dependencies:");
        console.log("        - MockAutoUSDC (ERC4626 vault)");
        console.log("        - MockMainRewarderUSDC (TOKE rewards)");
        console.log("        - MockToke (reward token)");
        console.log("");
        console.log("StableYieldAccumulator Configuration:");
        console.log("  - Reward token: USDC (MockRewardToken)");
        console.log("  - Discount rate: 2% (200 basis points)");
        console.log("  - Yield strategies registered: YieldStrategyUSDT, YieldStrategyUSDS, YieldStrategyDola, YieldStrategyUSDC");
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
        console.log("  - AutoDolaYieldStrategy can claim this yield via StableYieldAccumulator");
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
