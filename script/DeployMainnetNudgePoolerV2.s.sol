// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {Pauser} from "@pauser/Pauser.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {NFTMinterV2} from "@yield-claim-nft/V2/NFTMinterV2.sol";
import {ITokenDispatcherV2} from "@yield-claim-nft/V2/interfaces/ITokenDispatcherV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";

/**
 * @title DeployMainnetNudgePoolerV2
 * @notice Unified mainnet deploy that ships three new contracts in one Ledger session:
 *
 *           1. BatchNFTMinter        (new — nudgeSize=40, nudgePaymentToken=USDC)
 *           2. StableYieldAccumulator (new — discountRate=3000 bps, nudgeSplit=30, nudge=<new BatchNFTMinter>)
 *           3. BalancerPoolerV2       (new — same 50/50 LP pool route established by
 *                                       MigrateBalancerPoolerV2Pool.s.sol; batch-donation
 *                                       phase wired to sUSDS<->waUSDC swap pool, USDC
 *                                       drains to the new BatchNFTMinter)
 *
 *         This story (047) supersedes story 046 — the prior accumulator+batch-minter
 *         deploy script was merged to master but never broadcast.
 *
 * Configuration sequence (~34 calls):
 *
 *   1.  new BatchNFTMinter(deployer)
 *   2.  new StableYieldAccumulator()
 *   3.  new BalancerPoolerV2(SUSDS, LP_POOL, BALANCER_VAULT, BALANCER_ROUTER, SUSDS_IS_FIRST, deployer)
 *
 *   Accumulator config (steps 4–18 — mirror story 046):
 *   4.  sya.setRewardToken(USDC)
 *   5.  sya.setPhlimbo(PHLIMBO_EA)
 *   6.  sya.setMinter(PHUSD_STABLE_MINTER)
 *   7.  sya.setNFTMinter(NFT_MINTER_V2)
 *   8.  sya.setPauser(PAUSER)
 *   9.  sya.setTokenConfig(USDC, 6, 1e18)
 *   10. sya.setTokenConfig(DOLA, 18, 1e18)
 *   11. sya.setTokenConfig(USDe, 18, 1e18)
 *   12. sya.addYieldStrategy(YIELD_STRATEGY_DOLA, DOLA)
 *   13. sya.addYieldStrategy(YIELD_STRATEGY_USDC, USDC)
 *   14. sya.addYieldStrategy(YIELD_STRATEGY_USDE, USDe)
 *   15. sya.setDiscountRate(3000)
 *   16. sya.setNudgeAddress(address(batch))
 *   17. sya.setNudgeSplit(30)
 *   18. sya.approvePhlimbo(type(uint256).max)
 *
 *   BatchNFTMinter config:
 *   19. batch.setNudgePaymentToken(USDC)
 *   20. batch.setNudgeSize(40)
 *   21. assert no nudgePaymentToken collision against NFTMinterV2 dispatcher primeTokens
 *
 *   BalancerPoolerV2 config:
 *   22. pooler.setBatchDonationSize(10)
 *   23. pooler.setBatchMinter(address(batch))
 *   24. pooler.setSwapConfig(SWAP_POOL_SUSDS_WAUSDC, WAUSDC_MAINNET, USDC)
 *
 *   Rewire surrounding system:
 *   26. for each active strategy (3): setWithdrawer(newAcc, true)
 *   27. for each active strategy (3): setWithdrawer(OLD_ACCUMULATOR, false)
 *   28. NFTMinterV2.setAuthorizedBurner(newAcc, true)
 *   29. NFTMinterV2.setAuthorizedBurner(OLD_ACCUMULATOR, false)
 *
 *   NFTMinterV2 dispatcher rewiring (on-chain introspection):
 *   30. NFTMinterV2.registerDispatcher(newPooler, oldInitialPrice, oldGrowthBps)
 *   31. NFTMinterV2.setDispatcherDisabled(oldIndex, true)
 *
 *   Pauser register:
 *   33. Pauser.register(newAcc)
 *   34. Pauser.register(newPooler)
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/DeployMainnetNudgePoolerV2.s.sol \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast:
 *   forge script script/DeployMainnetNudgePoolerV2.s.sol \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

/// @notice Minimal NFTMinterV2 view interface — reads dispatcher configs by index and
///         resolves dispatcher address -> index via the public dispatcherToIndex map.
interface INFTMinterV2View {
    function nextIndex() external view returns (uint256);

    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);

    function dispatcherToIndex(address dispatcher) external view returns (uint256);
}

contract DeployMainnetNudgePoolerV2 is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    // External tokens
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    // Live protocol
    address public constant PHLIMBO_EA = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address public constant BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;

    // Active yield strategies (3 — discard the 2 deprecated)
    address public constant YIELD_STRATEGY_DOLA = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;
    address public constant YIELD_STRATEGY_USDC = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address public constant YIELD_STRATEGY_USDE = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;

    // Old contracts to replace (self-validated by patcher)
    address public constant OLD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address public constant OLD_BATCH_MINTER = 0xD3104A6e6D53b37061856fe1f31296D8962f9e01;
    address public constant OLD_BALANCER_POOLER_V2 = 0x6e957842AFBCD01cE9DB296D173F39134b362771;

    // BalancerPoolerV2 constructor args (route established by MigrateBalancerPoolerV2Pool.s.sol)
    address public constant LP_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04; // 50/50 phUSD/sUSDS
    bool public constant SUSDS_IS_FIRST = true; // verified by prior migration

    // Owner / Ledger
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6; // index 46

    // External — user-supplied, verified before execution
    address public constant WAUSDC_MAINNET = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address public constant SWAP_POOL_SUSDS_WAUSDC = 0x0B65A4505E8C323AE4fEDcc48515FD713dC9d8C0;

    // ==========================================
    //         CONFIGURATION CONSTANTS
    // ==========================================

    uint256 public constant DISCOUNT_RATE_BPS = 3000;     // 30% — accumulator (basis points, max 10000)
    uint256 public constant NUDGE_SPLIT = 30;             // 30% — accumulator (units 0..100)
    uint256 public constant NUDGE_SIZE = 40;              // BatchNFTMinter trigger threshold
    uint256 public constant BATCH_DONATION_SIZE = 10;     // 10% — BalancerPoolerV2 (units 0..100)

    uint8 public constant USDC_DECIMALS = 6;
    uint8 public constant DOLA_DECIMALS = 18;
    uint8 public constant USDE_DECIMALS = 18;
    uint256 public constant EXCHANGE_RATE_1E18 = 1e18;

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    address public newAccumulator;
    address public newBatchMinter;
    address public newPooler;

    // Captured from on-chain introspection of OLD_BALANCER_POOLER_V2's dispatcher config
    uint256 public oldDispatcherIndex;
    uint256 public oldDispatcherPrice;
    uint256 public oldDispatcherGrowthBps;

    string constant PROGRESS_FILE = "server/deployments/progress.nudge-pooler.1.json";
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

    function setUp() public {
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        require(WAUSDC_MAINNET != address(0), "WAUSDC_MAINNET placeholder; refusing to run");
        require(SWAP_POOL_SUSDS_WAUSDC != address(0), "SWAP_POOL_SUSDS_WAUSDC placeholder; refusing to run");
    }

    function run() external {
        console.log("=========================================");
        console.log("  MAINNET NUDGE POOLER V2 DEPLOYMENT");
        console.log("=========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);

        console.log("");
        console.log("--- LIVE CONTRACTS (mirrored on new system) ---");
        console.log("USDC:                ", USDC);
        console.log("DOLA:                ", DOLA);
        console.log("USDe:                ", USDe);
        console.log("SUSDS:               ", SUSDS);
        console.log("PhlimboEA:           ", PHLIMBO_EA);
        console.log("PhusdStableMinter:   ", PHUSD_STABLE_MINTER);
        console.log("NFTMinterV2:         ", NFT_MINTER_V2);
        console.log("Pauser:              ", PAUSER);
        console.log("BalancerVault:       ", BALANCER_VAULT);
        console.log("BalancerRouter:      ", BALANCER_ROUTER);
        console.log("LP pool (phUSD/sUSDS):", LP_POOL);
        console.log("WaUSDC:              ", WAUSDC_MAINNET);
        console.log("Swap pool (sUSDS/waUSDC):", SWAP_POOL_SUSDS_WAUSDC);
        console.log("YieldStrategyDola:   ", YIELD_STRATEGY_DOLA);
        console.log("YieldStrategyUSDC:   ", YIELD_STRATEGY_USDC);
        console.log("YieldStrategyUSDe:   ", YIELD_STRATEGY_USDE);
        console.log("");
        console.log("--- CONTRACTS BEING REPLACED ---");
        console.log("Old StableYieldAccumulator: ", OLD_ACCUMULATOR);
        console.log("Old BatchNFTMinter:         ", OLD_BATCH_MINTER);
        console.log("Old BalancerPoolerV2:       ", OLD_BALANCER_POOLER_V2);
        console.log("");
        console.log("--- LEDGER SIGNER ---");
        console.log("Owner (ledger):    ", OWNER_ADDRESS);
        console.log("----------------------------------------------------");

        _loadProgressFile();

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

        // ====== Step 0: Snapshot old dispatcher config (on-chain introspection) ======
        console.log("\n=== Step 0: Snapshot OLD BalancerPoolerV2 dispatcher config ===");
        _snapshotOldDispatcher();

        // ====== Step 1: Deploy BatchNFTMinter ======
        console.log("\n=== Step 1: Deploy BatchNFTMinter ===");
        _deployBatchNFTMinter();

        // ====== Step 2: Deploy StableYieldAccumulator ======
        console.log("\n=== Step 2: Deploy StableYieldAccumulator ===");
        _deployAccumulator();

        // ====== Step 3: Deploy BalancerPoolerV2 ======
        console.log("\n=== Step 3: Deploy BalancerPoolerV2 ===");
        _deployBalancerPoolerV2();

        // ====== Steps 4-8: Configure accumulator downstream wiring ======
        console.log("\n=== Steps 4-8: Configure accumulator downstream wiring ===");
        _configureAccumulatorDownstream();

        // ====== Steps 9-11: Token configs ======
        console.log("\n=== Steps 9-11: Token configs (USDC/DOLA/USDe) ===");
        _configureTokenConfigs();

        // ====== Steps 12-14: Yield strategies ======
        console.log("\n=== Steps 12-14: Register active yield strategies (3) ===");
        _registerYieldStrategies();

        // ====== Step 15: Discount rate ======
        console.log("\n=== Step 15: Set discount rate to 30% (3000 bps) ===");
        _setDiscountRate();

        // ====== Steps 16-17: Nudge address + split ======
        console.log("\n=== Steps 16-17: Set nudge address + split ===");
        _setNudge();

        // ====== Step 18: Approve phlimbo ======
        console.log("\n=== Step 18: Approve phlimbo for max USDC ===");
        _approvePhlimbo();

        // ====== Steps 19-20: Configure batch minter ======
        console.log("\n=== Steps 19-20: Configure BatchNFTMinter (nudgePaymentToken + nudgeSize) ===");
        _configureBatchMinter();

        // ====== Step 21: Collision check ======
        console.log("\n=== Step 21: Assert nudgePaymentToken (USDC) doesn't collide with any dispatcher primeToken ===");
        _assertNoNudgeTokenCollision();

        // ====== Steps 22-24: Configure BalancerPoolerV2 ======
        console.log("\n=== Steps 22-24: Configure BalancerPoolerV2 (donation size + batchMinter + swap config) ===");
        _configureBalancerPoolerV2();

        // ====== Steps 26-27: Rewire yield-strategy withdrawers ======
        console.log("\n=== Steps 26-27: Rewire yield strategy withdrawers (3+3) ===");
        _rewireYieldStrategyWithdrawers();

        // ====== Steps 28-29: Rewire NFTMinterV2 burners ======
        console.log("\n=== Steps 28-29: Rewire NFTMinterV2 authorized burners ===");
        _rewireNFTMinterV2Burners();

        // ====== Steps 30-31: Register new pooler + disable old pooler ======
        console.log("\n=== Steps 30-31: Register new BalancerPoolerV2 dispatcher + disable old ===");
        _rewireDispatcher();

        // ====== Steps 33-34: Pauser registration ======
        console.log("\n=== Steps 33-34: Register accumulator + new pooler with Pauser ===");
        _registerWithPauser();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        if (!isPreview) {
            _markDeploymentComplete();
        }
        _printDeploymentSummary();
    }

    // ========================================
    // Step 0: Snapshot old dispatcher config
    // ========================================

    /// @dev Reads the OLD BalancerPoolerV2 dispatcher config from the live NFTMinterV2.
    ///      Captures index, price (initialPrice equivalent post-growth), and growthBasisPoints
    ///      so the new dispatcher inherits identical pricing curve state. Reverts if the
    ///      old dispatcher is not registered or if multiple dispatchers share that address.
    function _snapshotOldDispatcher() internal {
        if (_isConfigured("OldDispatcherSnapshot")) {
            console.log("Old dispatcher snapshot already loaded from progress");
            return;
        }
        INFTMinterV2View v2 = INFTMinterV2View(NFT_MINTER_V2);
        uint256 idx = v2.dispatcherToIndex(OLD_BALANCER_POOLER_V2);
        require(idx != 0, "Old BalancerPoolerV2 not registered as a dispatcher; refusing to proceed");

        (address d, uint256 price, uint256 growthBps, bool disabled) = v2.configs(idx);
        require(d == OLD_BALANCER_POOLER_V2, "dispatcherToIndex / configs mismatch for OLD pooler");

        oldDispatcherIndex = idx;
        oldDispatcherPrice = price;
        oldDispatcherGrowthBps = growthBps;

        console.log("Old dispatcher index:        ", idx);
        console.log("Old dispatcher current price:", price);
        console.log("Old dispatcher growth (bps): ", growthBps);
        console.log("Old dispatcher disabled?:    ", disabled);

        _trackDeployment("OldDispatcherSnapshot", address(0), 0);
        _markConfigured("OldDispatcherSnapshot", 0);
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 1: Deploy BatchNFTMinter
    // ========================================

    function _deployBatchNFTMinter() internal {
        if (_isDeployed("BatchNFTMinter")) {
            newBatchMinter = deployments["BatchNFTMinter"].addr;
            console.log("BatchNFTMinter already deployed at:", newBatchMinter);
            return;
        }
        uint256 gasBefore = gasleft();
        BatchNFTMinter b = new BatchNFTMinter(OWNER_ADDRESS);
        newBatchMinter = address(b);
        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("BatchNFTMinter", newBatchMinter, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("BatchNFTMinter deployed at:", newBatchMinter);
        console.log("  owner:", OWNER_ADDRESS);
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Step 2: Deploy StableYieldAccumulator
    // ========================================

    function _deployAccumulator() internal {
        if (_isDeployed("StableYieldAccumulator")) {
            newAccumulator = deployments["StableYieldAccumulator"].addr;
            console.log("StableYieldAccumulator already deployed at:", newAccumulator);
            return;
        }
        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = new StableYieldAccumulator();
        newAccumulator = address(sya);
        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("StableYieldAccumulator", newAccumulator, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("StableYieldAccumulator deployed at:", newAccumulator);
        console.log("  owner: deployer (Ownable assigns msg.sender)");
        console.log("  gas:  ", gasUsed);
    }

    // ========================================
    // Step 3: Deploy BalancerPoolerV2
    // ========================================

    function _deployBalancerPoolerV2() internal {
        if (_isDeployed("BalancerPoolerV2")) {
            newPooler = deployments["BalancerPoolerV2"].addr;
            console.log("BalancerPoolerV2 already deployed at:", newPooler);
            return;
        }
        uint256 gasBefore = gasleft();
        BalancerPoolerV2 p = new BalancerPoolerV2(
            SUSDS,
            LP_POOL,
            BALANCER_VAULT,
            BALANCER_ROUTER,
            SUSDS_IS_FIRST,
            OWNER_ADDRESS
        );
        newPooler = address(p);
        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("BalancerPoolerV2", newPooler, gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("BalancerPoolerV2 deployed at:", newPooler);
        console.log("  sUSDS:        ", SUSDS);
        console.log("  pool:         ", LP_POOL);
        console.log("  vault:        ", BALANCER_VAULT);
        console.log("  router:       ", BALANCER_ROUTER);
        console.log("  sUSDSIsFirst: ", SUSDS_IS_FIRST);
        console.log("  owner:        ", OWNER_ADDRESS);
        console.log("  gas:          ", gasUsed);
    }

    // ========================================
    // Steps 4-8: Configure accumulator downstream wiring
    // ========================================

    function _configureAccumulatorDownstream() internal {
        if (_isConfigured("AccumulatorDownstream")) {
            console.log("Accumulator downstream wiring already configured");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(newAccumulator);

        sya.setRewardToken(USDC);
        console.log("Step 4: setRewardToken(USDC)");

        sya.setPhlimbo(PHLIMBO_EA);
        console.log("Step 5: setPhlimbo(PhlimboEA)");

        sya.setMinter(PHUSD_STABLE_MINTER);
        console.log("Step 6: setMinter(PhusdStableMinter)");

        sya.setNFTMinter(NFT_MINTER_V2);
        console.log("Step 7: setNFTMinter(NFTMinterV2)");

        sya.setPauser(PAUSER);
        console.log("Step 8: setPauser(Pauser)");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("AccumulatorDownstream", address(0), 0);
        _markConfigured("AccumulatorDownstream", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 9-11: Token configs
    // ========================================

    function _configureTokenConfigs() internal {
        if (_isConfigured("TokenConfigs")) {
            console.log("Token configs already set");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(newAccumulator);

        sya.setTokenConfig(USDC, USDC_DECIMALS, EXCHANGE_RATE_1E18);
        console.log("Step 9:  setTokenConfig(USDC, 6, 1e18)");

        sya.setTokenConfig(DOLA, DOLA_DECIMALS, EXCHANGE_RATE_1E18);
        console.log("Step 10: setTokenConfig(DOLA, 18, 1e18)");

        sya.setTokenConfig(USDe, USDE_DECIMALS, EXCHANGE_RATE_1E18);
        console.log("Step 11: setTokenConfig(USDe, 18, 1e18)");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("TokenConfigs", address(0), 0);
        _markConfigured("TokenConfigs", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 12-14: Register active yield strategies
    // ========================================

    function _registerYieldStrategies() internal {
        if (_isConfigured("YieldStrategies")) {
            console.log("Yield strategies already registered");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(newAccumulator);

        sya.addYieldStrategy(YIELD_STRATEGY_DOLA, DOLA);
        console.log("Step 12: addYieldStrategy(YieldStrategyDola, DOLA)");

        sya.addYieldStrategy(YIELD_STRATEGY_USDC, USDC);
        console.log("Step 13: addYieldStrategy(YieldStrategyUSDC, USDC)");

        sya.addYieldStrategy(YIELD_STRATEGY_USDE, USDe);
        console.log("Step 14: addYieldStrategy(YieldStrategyUSDe, USDe)");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("YieldStrategies", address(0), 0);
        _markConfigured("YieldStrategies", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Step 15: Discount rate
    // ========================================

    function _setDiscountRate() internal {
        if (_isConfigured("DiscountRate")) {
            console.log("Discount rate already set");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(newAccumulator);

        sya.setDiscountRate(DISCOUNT_RATE_BPS);
        console.log("Step 15: setDiscountRate(", DISCOUNT_RATE_BPS, ") = 30%");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("DiscountRate", address(0), 0);
        _markConfigured("DiscountRate", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 16-17: Nudge address + split
    // ========================================

    function _setNudge() internal {
        if (_isConfigured("Nudge")) {
            console.log("Nudge already configured");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");
        require(newBatchMinter != address(0), "BatchNFTMinter must be deployed");

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(newAccumulator);

        sya.setNudgeAddress(newBatchMinter);
        console.log("Step 16: setNudgeAddress(BatchNFTMinter)");

        sya.setNudgeSplit(NUDGE_SPLIT);
        console.log("Step 17: setNudgeSplit(", NUDGE_SPLIT, ") = 30%");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("Nudge", address(0), 0);
        _markConfigured("Nudge", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Step 18: Approve phlimbo
    // ========================================

    function _approvePhlimbo() internal {
        if (_isConfigured("ApprovePhlimbo")) {
            console.log("Phlimbo allowance already set");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(newAccumulator);

        sya.approvePhlimbo(type(uint256).max);
        console.log("Step 18: approvePhlimbo(type(uint256).max)");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("ApprovePhlimbo", address(0), 0);
        _markConfigured("ApprovePhlimbo", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 19-20: Configure batch minter
    // ========================================

    function _configureBatchMinter() internal {
        if (_isConfigured("BatchMinterConfig")) {
            console.log("BatchNFTMinter already configured");
            return;
        }
        require(newBatchMinter != address(0), "BatchNFTMinter must be deployed");

        uint256 gasBefore = gasleft();
        BatchNFTMinter batch = BatchNFTMinter(newBatchMinter);

        batch.setNudgePaymentToken(USDC);
        console.log("Step 19: setNudgePaymentToken(USDC)");

        batch.setNudgeSize(NUDGE_SIZE);
        console.log("Step 20: setNudgeSize(", NUDGE_SIZE, ")");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("BatchMinterConfig", address(0), 0);
        _markConfigured("BatchMinterConfig", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Step 21: Collision check
    // ========================================

    /// @dev Iterates over every registered NFTMinterV2 dispatcher and asserts none
    ///      has primeToken() == USDC, which would collide with the BatchNFTMinter's
    ///      nudgePaymentToken (USDC) at runtime.
    function _assertNoNudgeTokenCollision() internal view {
        INFTMinterV2View v2 = INFTMinterV2View(NFT_MINTER_V2);
        uint256 upper = v2.nextIndex();
        if (upper <= 1) {
            console.log("NFTMinterV2 has no registered dispatchers; skipping collision check");
            return;
        }
        for (uint256 i = 1; i < upper; i++) {
            (address dispatcher, , , bool disabled) = v2.configs(i);
            if (dispatcher == address(0)) {
                continue;
            }
            address primeTok = ITokenDispatcherV2(dispatcher).primeToken();
            console.log("dispatcher", i);
            console.log("  primeToken:", primeTok);
            console.log("  disabled:  ", disabled);
            require(
                primeTok != USDC,
                "Collision: a dispatcher primeToken == USDC. nudgePaymentToken collision; escalate to user."
            );
        }
        console.log("Collision check passed: no active dispatcher uses USDC as primeToken");
    }

    // ========================================
    // Steps 22-24: Configure BalancerPoolerV2
    // ========================================

    function _configureBalancerPoolerV2() internal {
        if (_isConfigured("BalancerPoolerV2Config")) {
            console.log("BalancerPoolerV2 already configured");
            return;
        }
        require(newPooler != address(0), "BalancerPoolerV2 must be deployed");
        require(newBatchMinter != address(0), "BatchNFTMinter must be deployed");

        uint256 gasBefore = gasleft();
        BalancerPoolerV2 pooler = BalancerPoolerV2(newPooler);

        pooler.setBatchDonationSize(BATCH_DONATION_SIZE);
        console.log("Step 22: setBatchDonationSize(", BATCH_DONATION_SIZE, ") = 10%");

        pooler.setBatchMinter(newBatchMinter);
        console.log("Step 23: setBatchMinter(BatchNFTMinter)");

        pooler.setSwapConfig(SWAP_POOL_SUSDS_WAUSDC, WAUSDC_MAINNET, USDC);
        console.log("Step 24: setSwapConfig(swapPool, waUsdc, usdc)");
        console.log("  swapPool:", SWAP_POOL_SUSDS_WAUSDC);
        console.log("  waUsdc:  ", WAUSDC_MAINNET);
        console.log("  usdc:    ", USDC);

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("BalancerPoolerV2Config", address(0), 0);
        _markConfigured("BalancerPoolerV2Config", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 26-27: Rewire yield-strategy withdrawers
    // ========================================

    function _rewireYieldStrategyWithdrawers() internal {
        if (_isConfigured("YieldStrategyRewire")) {
            console.log("Yield strategy withdrawers already rewired");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();

        address[3] memory strategies = [YIELD_STRATEGY_DOLA, YIELD_STRATEGY_USDC, YIELD_STRATEGY_USDE];
        string[3] memory labels = ["YieldStrategyDola", "YieldStrategyUSDC", "YieldStrategyUSDe"];

        for (uint256 i = 0; i < 3; i++) {
            AYieldStrategy(strategies[i]).setWithdrawer(newAccumulator, true);
            console.log("Step 26: setWithdrawer(newAcc, true) on", labels[i]);
            console.log("  strategy:", strategies[i]);
            console.log("  NEW acc: ", newAccumulator);
        }

        for (uint256 i = 0; i < 3; i++) {
            AYieldStrategy(strategies[i]).setWithdrawer(OLD_ACCUMULATOR, false);
            console.log("Step 27: setWithdrawer(OLD_ACC, false) on", labels[i]);
            console.log("  strategy:", strategies[i]);
            console.log("  OLD acc: ", OLD_ACCUMULATOR);
        }

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("YieldStrategyRewire", address(0), 0);
        _markConfigured("YieldStrategyRewire", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 28-29: Rewire NFTMinterV2 burners
    // ========================================

    function _rewireNFTMinterV2Burners() internal {
        if (_isConfigured("NFTMinterV2Rewire")) {
            console.log("NFTMinterV2 authorized burners already rewired");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();
        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        minter.setAuthorizedBurner(newAccumulator, true);
        console.log("Step 28: NFTMinterV2.setAuthorizedBurner(newAcc, true)");
        console.log("  NEW acc:", newAccumulator);

        minter.setAuthorizedBurner(OLD_ACCUMULATOR, false);
        console.log("Step 29: NFTMinterV2.setAuthorizedBurner(OLD_ACC, false)");
        console.log("  OLD acc:", OLD_ACCUMULATOR);

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("NFTMinterV2Rewire", address(0), 0);
        _markConfigured("NFTMinterV2Rewire", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 30-31: Register new pooler / disable old
    // ========================================

    function _rewireDispatcher() internal {
        if (_isConfigured("DispatcherRewire")) {
            console.log("Dispatcher rewire already done");
            return;
        }
        require(newPooler != address(0), "BalancerPoolerV2 must be deployed");
        require(oldDispatcherIndex != 0, "Old dispatcher index not snapshotted");

        uint256 gasBefore = gasleft();
        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        // Step 30: register new dispatcher mirroring OLD price/growth
        minter.registerDispatcher(newPooler, oldDispatcherPrice, oldDispatcherGrowthBps);
        console.log("Step 30: NFTMinterV2.registerDispatcher(newPooler, price, growthBps)");
        console.log("  newPooler:    ", newPooler);
        console.log("  initialPrice: ", oldDispatcherPrice);
        console.log("  growthBps:    ", oldDispatcherGrowthBps);

        // Step 31: disable old dispatcher at the snapshotted index
        minter.setDispatcherDisabled(oldDispatcherIndex, true);
        console.log("Step 31: NFTMinterV2.setDispatcherDisabled(oldIndex, true)");
        console.log("  oldIndex:  ", oldDispatcherIndex);
        console.log("  OLD pooler:", OLD_BALANCER_POOLER_V2);

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("DispatcherRewire", address(0), 0);
        _markConfigured("DispatcherRewire", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
    }

    // ========================================
    // Steps 33-34: Pauser registration
    // ========================================

    function _registerWithPauser() internal {
        if (_isConfigured("PauserRegister")) {
            console.log("Pauser registration already done");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");
        require(newPooler != address(0), "BalancerPoolerV2 must be deployed");

        uint256 gasBefore = gasleft();
        Pauser p = Pauser(PAUSER);

        p.register(newAccumulator);
        console.log("Step 33: Pauser.register(newAcc)");
        console.log("  newAcc:", newAccumulator);

        // Step 34 SKIPPED per Concerns: BalancerPoolerV2 (and ATokenDispatcherV2) do NOT
        //   implement IPausable's `pauser()` getter. They inherit OZ Pausable but route
        //   pause/unpause via NFTMinterV2 (`onlyMinter`), NOT the global Pauser.
        //   The OLD BalancerPoolerV2 (0x6e957842…2771) was likewise never registered
        //   on-chain (Pauser.isRegistered() returns false). Calling register() here
        //   reverts with "Pauser: unable to verify pauser - contract may not implement
        //   pauser() getter". Pause coverage for the new pooler comes via NFTMinterV2,
        //   which IS registered with the Pauser.
        console.log("Step 34 SKIPPED: BalancerPoolerV2 is not an IPausable target - pause routes via NFTMinterV2");

        uint256 gasUsed = gasBefore - gasleft();
        _trackDeployment("PauserRegister", address(0), 0);
        _markConfigured("PauserRegister", gasUsed);
        if (!isPreview) _writeProgressFile();
        console.log("  gas: ", gasUsed);
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
        string[16] memory names = [
            "OldDispatcherSnapshot",
            "BatchNFTMinter",
            "StableYieldAccumulator",
            "BalancerPoolerV2",
            "AccumulatorDownstream",
            "TokenConfigs",
            "YieldStrategies",
            "DiscountRate",
            "Nudge",
            "ApprovePhlimbo",
            "BatchMinterConfig",
            "BalancerPoolerV2Config",
            "YieldStrategyRewire",
            "NFTMinterV2Rewire",
            "DispatcherRewire",
            "PauserRegister"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            _parseEntry(json, names[i]);
        }
    }

    function _parseEntry(string memory json, string memory name) internal {
        try vm.parseJsonAddress(json, string.concat(".contracts.", name, ".address")) returns (address addr) {
            bool deployed;
            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".deployed")) returns (bool d) {
                deployed = d;
            } catch {}

            bool configured;
            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".configured")) returns (bool c) {
                configured = c;
            } catch {}

            uint256 deployGas;
            try vm.parseJsonUint(json, string.concat(".contracts.", name, ".deployGas")) returns (uint256 g) {
                deployGas = g;
            } catch {}

            uint256 configGas;
            try vm.parseJsonUint(json, string.concat(".contracts.", name, ".configGas")) returns (uint256 g) {
                configGas = g;
            } catch {}

            if (deployed || configured) {
                deployments[name] = ContractDeployment({
                    name: name,
                    addr: addr,
                    deployed: deployed,
                    configured: configured,
                    deployGas: deployGas,
                    configGas: configGas
                });
                contractNames.push(name);
                console.log("Loaded from progress:", name);
                if (addr != address(0)) {
                    console.log("  address:", addr);
                }
            }
        } catch {}
    }

    function _isDeployed(string memory name) internal view returns (bool) {
        return deployments[name].deployed && deployments[name].addr != address(0);
    }

    function _isConfigured(string memory name) internal view returns (bool) {
        return deployments[name].configured;
    }

    function _trackDeployment(string memory name, address addr, uint256 gas) internal {
        bool found;
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
            ContractDeployment memory d = deployments[name];
            if (i > 0) json = string.concat(json, ",");
            json = string.concat(json, '"', name, '": {');
            json = string.concat(json, '"address": "', vm.toString(d.addr), '",');
            json = string.concat(json, '"deployed": ', d.deployed ? "true" : "false", ",");
            json = string.concat(json, '"configured": ', d.configured ? "true" : "false", ",");
            json = string.concat(json, '"deployGas": ', vm.toString(d.deployGas), ",");
            json = string.concat(json, '"configGas": ', vm.toString(d.configGas));
            json = string.concat(json, "}");
        }
        json = string.concat(json, "}}");

        vm.writeFile(PROGRESS_FILE, json);
        console.log("Progress file updated:", PROGRESS_FILE);
    }

    // ========================================
    // Summary
    // ========================================

    function _printDeploymentSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("       NUDGE POOLER V2 SUMMARY");
        console.log("=========================================");
        console.log("New StableYieldAccumulator:", newAccumulator);
        console.log("New BatchNFTMinter:        ", newBatchMinter);
        console.log("New BalancerPoolerV2:      ", newPooler);
        console.log("");
        console.log("--- Address rewires (OLD -> NEW) ---");
        console.log("StableYieldAccumulator:");
        console.log("  OLD:", OLD_ACCUMULATOR);
        console.log("  NEW:", newAccumulator);
        console.log("BatchNFTMinter:");
        console.log("  OLD:", OLD_BATCH_MINTER);
        console.log("  NEW:", newBatchMinter);
        console.log("BalancerPoolerV2 (nftsV2.BalancerPooler):");
        console.log("  OLD:", OLD_BALANCER_POOLER_V2);
        console.log("  NEW:", newPooler);
        console.log("");
        console.log("--- Accumulator Configuration ---");
        console.log("  rewardToken:        USDC");
        console.log("  phlimbo:            ", PHLIMBO_EA);
        console.log("  minter (phUSD):     ", PHUSD_STABLE_MINTER);
        console.log("  nftMinter:          ", NFT_MINTER_V2);
        console.log("  pauser:             ", PAUSER);
        console.log("  discountRate (bps): ", DISCOUNT_RATE_BPS);
        console.log("  nudge:              ", newBatchMinter);
        console.log("  nudgeSplit (%):     ", NUDGE_SPLIT);
        console.log("  phlimbo allowance:  type(uint256).max");
        console.log("");
        console.log("--- Token configs ---");
        console.log("  USDC: 6 decimals, 1:1 rate");
        console.log("  DOLA: 18 decimals, 1:1 rate");
        console.log("  USDe: 18 decimals, 1:1 rate");
        console.log("");
        console.log("--- Active yield strategies (3) ---");
        console.log("  YieldStrategyDola:", YIELD_STRATEGY_DOLA);
        console.log("  YieldStrategyUSDC:", YIELD_STRATEGY_USDC);
        console.log("  YieldStrategyUSDe:", YIELD_STRATEGY_USDE);
        console.log("");
        console.log("--- BatchNFTMinter ---");
        console.log("  nudgePaymentToken: USDC");
        console.log("  nudgeSize:        ", NUDGE_SIZE);
        console.log("");
        console.log("--- BalancerPoolerV2 ---");
        console.log("  pool:             ", LP_POOL);
        console.log("  sUSDSIsFirst:     ", SUSDS_IS_FIRST);
        console.log("  batchDonationSize:", BATCH_DONATION_SIZE);
        console.log("  batchMinter:      ", newBatchMinter);
        console.log("  swapPool:         ", SWAP_POOL_SUSDS_WAUSDC);
        console.log("  waUsdc:           ", WAUSDC_MAINNET);
        console.log("  usdc:             ", USDC);
        console.log("");
        console.log("--- Dispatcher rewiring ---");
        console.log("  oldIndex (disabled):", oldDispatcherIndex);
        console.log("  inherited price:    ", oldDispatcherPrice);
        console.log("  inherited growthBps:", oldDispatcherGrowthBps);
        console.log("");
        console.log("--- External rewires ---");
        console.log("  YieldStrategy.setWithdrawer(newAcc, true) x3");
        console.log("  YieldStrategy.setWithdrawer(OLD_ACCUMULATOR, false) x3");
        console.log("  NFTMinterV2.setAuthorizedBurner(newAcc, true)");
        console.log("  NFTMinterV2.setAuthorizedBurner(OLD_ACCUMULATOR, false)");
        console.log("  NFTMinterV2.registerDispatcher(newPooler, ...)");
        console.log("  NFTMinterV2.setDispatcherDisabled(oldIndex, true)");
        console.log("  Pauser.register(newAcc)");
        console.log("  (skipped) Pauser.register(newPooler) - dispatcher pause routes via NFTMinterV2");
        console.log("");
        _printGasSummary();
        console.log("=========================================");
    }

    function _printGasSummary() internal view {
        console.log("--------- GAS SUMMARY (per step) ---------");
        uint256 totalDeployGas;
        uint256 totalConfigGas;
        for (uint256 i = 0; i < contractNames.length; i++) {
            ContractDeployment memory d = deployments[contractNames[i]];
            if (d.deployGas > 0) {
                console.log("  deploy", d.name);
                console.log("    gas:", d.deployGas);
                totalDeployGas += d.deployGas;
            }
            if (d.configGas > 0) {
                console.log("  config", d.name);
                console.log("    gas:", d.configGas);
                totalConfigGas += d.configGas;
            }
        }
        uint256 totalGas = totalDeployGas + totalConfigGas;
        console.log("");
        console.log("--------- GRAND TOTAL ---------");
        console.log("Total deploy gas:", totalDeployGas);
        console.log("Total config gas:", totalConfigGas);
        console.log("TOTAL GAS USED:  ", totalGas);
        console.log("");
        console.log("--- Estimated cost ---");
        console.log("  @ 10 gwei (wei):", totalGas * 10 gwei);
        console.log("  @ 30 gwei (wei):", totalGas * 30 gwei);
    }
}
