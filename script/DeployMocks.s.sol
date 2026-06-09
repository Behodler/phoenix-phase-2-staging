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
import "../src/mocks/MockERC4626Wrapper.sol";
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
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import "../src/mocks/MockBalancerRouter.sol";
import {NFTMinterV2} from "@yield-claim-nft/V2/NFTMinterV2.sol";
import {BurnerV2} from "@yield-claim-nft/V2/dispatchers/BurnerV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";
import {GatherV2} from "@yield-claim-nft/V2/dispatchers/GatherV2.sol";
import {BalancerPoolerMintDebtHook} from "@yield-claim-nft/V2/hooks/BalancerPoolerMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/V2/interfaces/IDispatchHook.sol";
import {IBalancerPoolerMintDebtHook} from "@yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {NFTStaker} from "nft-staking/NFTStaker.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {INFTSupply} from "nft-staking/INFTSupply.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";
// StableStaker's constructor takes the flax-token-v2 IFlax; alias to avoid an
// identifier clash with phlimbo-ea's IFlax which is already in scope transitively.
import {IFlax as IFlaxStaker} from "flax-token/IFlax.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    // Mock-vs-mainnet parity constants for nudge feature (story 045.5)
    // - MOCK_NUDGE_SPLIT matches mainnet (story 046)
    // - MOCK_NUDGE_SIZE is lowered from mainnet's 40 for dev ergonomics
    uint256 constant MOCK_NUDGE_SPLIT = 30;
    uint256 constant MOCK_NUDGE_SIZE = 25;
    // Story 045.5 Phase 7 — BalancerPoolerV2 batch-donation phase
    // Percent of sUSDS share balance diverted to the donation phase on each pool() call.
    // Mirrors MOCK_NUDGE_SPLIT for mental-model parity; LP path still receives 70%.
    uint256 constant MOCK_BATCH_DONATION_SIZE = 30;

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

    // NFTMinter infrastructure (V2 only — V1 removed in story 059)
    MockSCX public mockSCX;
    MockFlax public mockFlax;
    MockWBTC public mockWBTC;
    MockBalancerPool public mockBalancerPool;
    MockBalancerVault public mockBalancerVault;
    BurnRecorder public burnRecorder;

    // V2 NFTMinter infrastructure
    MockBalancerRouter public mockBalancerRouter;
    NFTMinterV2 public nftMinterV2;
    BurnerV2 public burnerEYEV2;
    BurnerV2 public burnerSCXV2;
    BurnerV2 public burnerFlaxV2;
    BalancerPoolerV2 public balancerPoolerV2;
    GatherV2 public gatherWBTCV2;

    // NFT Staking infrastructure
    BalancerPoolerMintDebtHook public balancerPoolerHook;
    NFTStaker public nftStaker;
    BatchNFTMinter public batchNFTMinter;

    // Stable Staking infrastructure (story 051)
    StableStaker public stableStaker;

    // Story 045.5 Phase 7 — BalancerPoolerV2 donation-phase mocks
    // waUSDC mock = ERC4626 wrapper over the existing USDC `rewardToken`.
    MockERC4626Wrapper public mockWaUsdc;

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

        // ====== PHASE 3.6: V2 NFTMinter Infrastructure ======
        // (Phase 3.5 V1 NFTMinter infra removed in story 059 — V1 is decommissioned)
        console.log("\n=== Phase 3.6: Deploying V2 NFTMinter Infrastructure ===");

        // Deploy MockBalancerPool (ERC20 BPT)
        gasBefore = gasleft();
        mockBalancerPool = new MockBalancerPool();
        _trackDeployment("MockBalancerPool", address(mockBalancerPool), gasBefore - gasleft());
        console.log("MockBalancerPool deployed at:", address(mockBalancerPool));

        // Deploy MockBalancerVault
        gasBefore = gasleft();
        mockBalancerVault = new MockBalancerVault(address(mockBalancerPool));
        _trackDeployment("MockBalancerVault", address(mockBalancerVault), gasBefore - gasleft());
        console.log("MockBalancerVault deployed at:", address(mockBalancerVault));

        // Wire MockBalancerPool to recognize the vault
        mockBalancerPool.setVault(address(mockBalancerVault));
        console.log("Wired MockBalancerPool to recognize MockBalancerVault");

        // Deploy BurnRecorder
        gasBefore = gasleft();
        burnRecorder = new BurnRecorder(deployer);
        _trackDeployment("BurnRecorder", address(burnRecorder), gasBefore - gasleft());
        console.log("BurnRecorder deployed at:", address(burnRecorder));

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

        balancerPoolerV2.setAuthorizedPooler(deployer, true);
        console.log("BalancerPoolerV2.setAuthorizedPooler(deployer, true)");

        // ---- Story 045.5 Phase 7: BalancerPoolerV2 swap-config + waUSDC ----
        // (setBatchMinter and setBatchDonationSize land in Phase 3.7 below, after
        // BatchNFTMinter is deployed.)
        // Deploy waUSDC mock (ERC4626 wrapper over the existing USDC reward token).
        // 6 decimals to match real USDC; default rate 10000 bps (1:1 redeem).
        gasBefore = gasleft();
        mockWaUsdc = new MockERC4626Wrapper(
            "Mock Wrapped Aave USDC",
            "mwaUSDC",
            address(rewardToken),
            6,
            10000
        );
        _trackDeployment("MockWaUSDC", address(mockWaUsdc), gasBefore - gasleft());
        console.log("MockWaUSDC deployed at:", address(mockWaUsdc));

        // Pre-fund the waUSDC wrapper with underlying USDC so `redeem` payouts
        // succeed during BalancerPoolerV2 donation-phase unwraps. The mock
        // wrapper mints shares without taking deposits, so it has no USDC
        // backing unless we seed it here. See src/mocks/MockERC4626Wrapper.sol
        // ("Tests/dev scripts pre-fund the wrapper directly").
        rewardToken.mint(address(mockWaUsdc), 1_000_000 * 10 ** 6);
        console.log("Pre-funded MockWaUSDC with 1,000,000 USDC for redeem backing");

        // Configure mock swap rate sUSDS -> waUSDC.
        // sUSDS has 18 decimals (MockSUSDS uses ERC4626's default), waUSDC has 6 decimals.
        // 1 sUSDS share -> 1 waUSDC share (decimal scale-down): num = 1, den = 1e12.
        // This means donationSUSDS / 1e12 waUSDC shares are minted, then redeemed 1:1
        // for USDC at 6 decimals — preserving USD value across the swap+unwrap.
        mockBalancerVault.setSwapRate(address(susds), address(mockWaUsdc), 1, 1e12);
        console.log("MockBalancerVault.setSwapRate(sUSDS -> waUSDC) -> 1 / 1e12 (decimal scale)");

        // Wire swap config on BalancerPoolerV2 (recipient comes later in Phase 3.7).
        // Note: the swap-pool address is opaque to MockBalancerVault.swap (which
        // keys off (tokenIn, tokenOut)), so we reuse mockBalancerPool as the
        // placeholder identifier rather than deploying a separate stub.
        balancerPoolerV2.setSwapConfig(
            address(mockBalancerPool), // swapPool placeholder identifier (opaque to mock)
            address(mockWaUsdc),       // waUsdc
            address(rewardToken)       // usdc
        );
        console.log("BalancerPoolerV2.setSwapConfig(mockBalancerPool, mockWaUsdc, USDC)");

        gatherWBTCV2.setMinter(address(nftMinterV2));
        console.log("GatherWBTCV2.setMinter -> NFTMinterV2");

        // 6. Authorize V2 burner dispatchers on BurnRecorder
        burnRecorder.setBurner(address(burnerEYEV2), true);
        burnRecorder.setBurner(address(burnerSCXV2), true);
        burnRecorder.setBurner(address(burnerFlaxV2), true);
        console.log("Authorized BurnerEYEV2, BurnerSCXV2, BurnerFlaxV2 as burners on BurnRecorder");

        // ====== PHASE 3.7: NFT Staking Stack ======
        console.log("\n=== Phase 3.7: NFT Staking Stack ===");

        // 1. Deploy BalancerPoolerMintDebtHook (replaces the default no-op DispatchHook)
        gasBefore = gasleft();
        balancerPoolerHook = new BalancerPoolerMintDebtHook(
            deployer,
            address(balancerPoolerV2),
            address(phUSD)
        );
        _trackDeployment("BalancerPoolerMintDebtHook", address(balancerPoolerHook), gasBefore - gasleft());
        console.log("BalancerPoolerMintDebtHook deployed at:", address(balancerPoolerHook));

        // 2. Install the hook on BalancerPoolerV2 (swaps out the constructor-installed DefaultDispatchHook)
        balancerPoolerV2.setHook(IDispatchHook(address(balancerPoolerHook)));
        console.log("BalancerPoolerV2.setHook -> BalancerPoolerMintDebtHook");

        // 3. Deploy NFTStaker (BalancerPoolerV2 NFT id = 4, phUSD as reward, dispatcher index 4)
        gasBefore = gasleft();
        nftStaker = new NFTStaker(
            IERC1155(address(nftMinterV2)),
            4,
            IERC20(address(phUSD)),
            deployer,
            INFTSupply(address(nftMinterV2)),
            4
        );
        _trackDeployment("NFTStaker", address(nftStaker), gasBefore - gasleft());
        console.log("NFTStaker deployed at:", address(nftStaker));

        // 4. Wire NFTStaker -> hook
        nftStaker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(balancerPoolerHook)));
        console.log("NFTStaker.setDispatcherHook -> BalancerPoolerMintDebtHook");

        // 5. Wire hook recipient -> NFTStaker
        balancerPoolerHook.setRecipient(address(nftStaker));
        console.log("BalancerPoolerMintDebtHook.setRecipient -> NFTStaker");

        // 6. Authorize the hook to mint phUSD (so pull() can realise mint debt)
        phUSD.setMinter(address(balancerPoolerHook), true);
        console.log("Authorized BalancerPoolerMintDebtHook as phUSD minter");

        // 7. Set the target APY (30% — bounded by MAX_TARGET_APY = 50%)
        nftStaker.setTargetAPY(0.3e18);
        console.log("NFTStaker.setTargetAPY -> 0.3e18 (30%)");

        // 8. Deploy BatchNFTMinter (owner-administered nudge, deployer is initial owner)
        gasBefore = gasleft();
        batchNFTMinter = new BatchNFTMinter(deployer);
        _trackDeployment("BatchNFTMinter", address(batchNFTMinter), gasBefore - gasleft());
        console.log("BatchNFTMinter deployed at:", address(batchNFTMinter));

        // 9. Wire nudge config on BatchNFTMinter (story 045.5)
        //    nudgePaymentToken first, then nudgeSize (mirrors story 046 mainnet sequence).
        //    The runtime guard (BatchNFTMinter.sol:122-126) requires
        //    nudgePaymentToken != paymentToken at batchMint time. The mock V2 mint flow
        //    uses non-USDC prime tokens (EYE/SCX/Flax/USDS), so the constraint holds.
        batchNFTMinter.setNudgePaymentToken(address(rewardToken)); // USDC
        console.log("BatchNFTMinter.setNudgePaymentToken -> USDC");

        batchNFTMinter.setNudgeSize(MOCK_NUDGE_SIZE);
        console.log("BatchNFTMinter.setNudgeSize ->", MOCK_NUDGE_SIZE);

        // ---- Story 045.5 Phase 7: Finalise BalancerPoolerV2 batch-donation wiring ----
        // BatchNFTMinter is now deployed — point the donation recipient at it and
        // turn the donation phase on. Order: setBatchMinter (recipient) BEFORE
        // setBatchDonationSize (the activator). Swap config was already wired in
        // Phase 3.6 above.
        balancerPoolerV2.setBatchMinter(address(batchNFTMinter));
        console.log("BalancerPoolerV2.setBatchMinter -> BatchNFTMinter");

        balancerPoolerV2.setBatchDonationSize(MOCK_BATCH_DONATION_SIZE);
        console.log("BalancerPoolerV2.setBatchDonationSize ->", MOCK_BATCH_DONATION_SIZE);

        // ====== PHASE 3.7: StableStaker Deployment + Wiring (story 051) ======
        console.log("\n=== Phase 3.7: Deploying + Wiring StableStaker ===");

        // 1. Deploy the MasterChef-style stable farm. phUSD (MockPhUSD) satisfies IFlax
        //    (exposes mint/setMinter); deployer is the initial owner.
        gasBefore = gasleft();
        stableStaker = new StableStaker(IFlaxStaker(address(phUSD)), deployer);
        _trackDeployment("StableStaker", address(stableStaker), gasBefore - gasleft());
        console.log("StableStaker deployed at:", address(stableStaker));

        // 2. Authorize StableStaker as a phUSD minter — it mints rewards on claim/withdraw.
        phUSD.setMinter(address(stableStaker), true);
        console.log("Authorized StableStaker as phUSD minter");

        // 3. Per token: register the pool, authorize the staker as a client ON the strategy
        //    (mandatory two-sided wiring — without it stake/withdraw revert), wire the
        //    strategy on the staker, then set the daily phUSD emission budget.
        //    Emission units are phUSD wei/day (18 decimals) regardless of the staked
        //    token's decimals: 10e18 = 10 phUSD/day, 5e18 = 5 phUSD/day.
        //    DOLA and USDe pools get 10/day; the USDC (rewardToken) pool gets 5/day so
        //    the reduced rate is visible in the UI (story 051 Concerns).
        address[3] memory ssTokens = [address(dola), address(rewardToken), address(usde)];
        ERC4626YieldStrategy[3] memory ssStrats = [yieldStrategyDola, yieldStrategyUSDC, yieldStrategyUSDe];
        for (uint256 i = 0; i < 3; i++) {
            stableStaker.addToken(ssTokens[i]);
            ssStrats[i].setClient(address(stableStaker), true); // client added ON the yield strategy
            stableStaker.setYieldStrategy(ssTokens[i], IYieldStrategy(address(ssStrats[i])));
            // Reserve a 10% liquid buffer of realized surplus back to StableStaker (the client)
            // on each skimSurplus, so 90% flows downstream. Integer percent (require <= 100); the
            // setter lives on the strategy, not the staker (story 053).
            ssStrats[i].setSetAsideBuffer(address(stableStaker), 10);
            uint256 dailyRate = ssTokens[i] == address(rewardToken) ? 5e18 : 10e18;
            stableStaker.phUSDPerDay(ssTokens[i], dailyRate);
            console.log("StableStaker pool wired (token / phUSD-per-day):", ssTokens[i], dailyRate);
            console.log("StableStaker set-aside buffer set to 10% on strategy:", address(ssStrats[i]));
        }
        console.log("StableStaker: 3 pools registered, strategies wired (both sides), rates set, 10% set-aside buffer");

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

        // NOTE: SYA.setMinter() was removed in the stable-yield-accumulator bump
        // (the accumulator no longer tracks the phUSD stable minter directly;
        // yield strategies are registered via addYieldStrategy instead). Call dropped.
        // stableYieldAccumulator.setMinter(address(minter));

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

        // Wire nudge config on StableYieldAccumulator (story 045.5)
        //   nudge address first, then split (mirrors mainnet sequence in story 046).
        //   When claim() runs, nudgeSplit% of the discounted USDC payment is forwarded
        //   to the BatchNFTMinter; the remainder goes to Phlimbo as before.
        stableYieldAccumulator.setNudgeAddress(address(batchNFTMinter));
        console.log("SYA.setNudgeAddress ->", address(batchNFTMinter));

        stableYieldAccumulator.setNudgeSplit(MOCK_NUDGE_SPLIT);
        console.log("SYA.setNudgeSplit ->", MOCK_NUDGE_SPLIT);

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

        // Register NFTMinterV2 with Pauser
        nftMinterV2.setPauser(address(pauser));
        console.log("NFTMinterV2.setPauser() called");
        pauser.register(address(nftMinterV2));
        console.log("Pauser.register(NFTMinterV2) completed");

        // Register NFTStaker with Pauser
        nftStaker.setPauser(address(pauser));
        console.log("NFTStaker.setPauser() called");
        pauser.register(address(nftStaker));
        console.log("Pauser.register(NFTStaker) completed");

        // Register StableStaker with Pauser (story 052 — fixes story 051's missing pauser wiring)
        // Step 1: Set pauser address on contract FIRST (register() validates pauser() == address(this))
        stableStaker.setPauser(address(pauser));
        console.log("StableStaker.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(stableStaker));
        console.log("Pauser.register(StableStaker) completed");

        console.log("All protocol contracts registered with Pauser");

        // ====== PHASE 8.7: SYA Integration — V2 NFTMinter ======
        console.log("\n=== Phase 8.7: SYA Integration - V2 NFTMinter ===");

        // Set V2 NFTMinter on StableYieldAccumulator
        stableYieldAccumulator.setNFTMinter(address(nftMinterV2));
        console.log("StableYieldAccumulator.setNFTMinter -> NFTMinterV2");

        // Set StableYieldAccumulator as authorized burner on V2 NFTMinter
        nftMinterV2.setAuthorizedBurner(address(stableYieldAccumulator), true);
        console.log("NFTMinterV2.setAuthorizedBurner(StableYieldAccumulator, true)");

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
        _markConfigured("BurnRecorder", 0);
        _markConfigured("MockBalancerRouter", 0);
        _markConfigured("NFTMinterV2", 0);
        _markConfigured("BurnerEYEV2", 0);
        _markConfigured("BurnerSCXV2", 0);
        _markConfigured("BurnerFlaxV2", 0);
        _markConfigured("BalancerPoolerV2", 0);
        _markConfigured("MockWaUSDC", 0);
        _markConfigured("GatherWBTCV2", 0);
        _markConfigured("BalancerPoolerMintDebtHook", 0);
        _markConfigured("NFTStaker", 0);
        _markConfigured("BatchNFTMinter", 0);
        _markConfigured("StableStaker", 0);
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
        console.log("  - StableStaker registered with Pauser");
        console.log("StableStaker: 10% set-aside buffer on all 3 pools (DOLA, USDC, USDe)");
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
