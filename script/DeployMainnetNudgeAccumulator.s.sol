// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@pauser/Pauser.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {NFTMinterV2} from "@yield-claim-nft/V2/NFTMinterV2.sol";
import {ITokenDispatcherV2} from "@yield-claim-nft/V2/interfaces/ITokenDispatcherV2.sol";

/**
 * @title DeployMainnetNudgeAccumulator
 * @notice Mainnet deployment script that replaces the live StableYieldAccumulator
 *         and BatchNFTMinter with the new "nudge"-aware versions.
 *
 *         The new accumulator splits 30% of every claim payment to a configurable
 *         nudge recipient (the new BatchNFTMinter), and the new BatchNFTMinter
 *         releases its accumulated USDC balance to any caller minting a batch
 *         of >= 40 NFTs.
 *
 *         Mirrors live mainnet wiring (yield strategies, token configs, downstream
 *         addresses) but lowers the discount rate from 35% (3500 bps) -> 30% (3000 bps)
 *         and enables the new nudge split.
 *
 * Configuration sequence (24 calls):
 *   1.  new BatchNFTMinter(deployer)
 *   2.  new StableYieldAccumulator()
 *   3.  sya.setRewardToken(USDC)
 *   4.  sya.setPhlimbo(PHLIMBO_EA)
 *   5.  sya.setMinter(PHUSD_STABLE_MINTER)
 *   6.  sya.setNFTMinter(NFT_MINTER_V2)
 *   7.  sya.setPauser(PAUSER)
 *   8.  sya.setTokenConfig(USDC, 6, 1e18)
 *   9.  sya.setTokenConfig(DOLA, 18, 1e18)
 *   10. sya.setTokenConfig(USDe, 18, 1e18)
 *   11. sya.addYieldStrategy(YIELD_STRATEGY_DOLA, DOLA)
 *   12. sya.addYieldStrategy(YIELD_STRATEGY_USDC, USDC)
 *   13. sya.addYieldStrategy(YIELD_STRATEGY_USDE, USDe)
 *   14. sya.setDiscountRate(3000)
 *   15. sya.setNudgeAddress(address(batch))
 *   16. sya.setNudgeSplit(30)
 *   17. sya.approvePhlimbo(type(uint256).max)
 *   18. batch.setNudgePaymentToken(USDC)
 *   19. batch.setNudgeSize(40)
 *   20. setWithdrawer(newSya, true) on each of the 3 active yield strategies
 *   21. setWithdrawer(OLD_ACCUMULATOR, false) on each of the 3 active yield strategies
 *   22. NFTMinterV2.setAuthorizedBurner(newSya, true)
 *   23. NFTMinterV2.setAuthorizedBurner(OLD_ACCUMULATOR, false)
 *   24. Pauser.register(newSya)
 *
 * The 2 deprecated/inert yield strategies (0xf5F9...0E5B, 0x5cBA...99a4) are
 * skipped entirely — they are not re-registered and their withdrawer
 * authorizations are not modified.
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/DeployMainnetNudgeAccumulator.s.sol \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast:
 *   forge script script/DeployMainnetNudgeAccumulator.s.sol \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

/// @notice Minimal interface for reading NFTMinterV2 dispatcher configs (used to
///         assert that USDC is not in use as a primeToken on any active dispatcher,
///         which would collide with the BatchNFTMinter nudge-payment-token check).
interface INFTMinterV2View {
    function nextIndex() external view returns (uint256);

    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

contract DeployMainnetNudgeAccumulator is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    // External Token Contracts
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // Deployed Phoenix Phase 2 contracts (live, must mirror)
    address public constant PHLIMBO_EA = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // Active yield strategies (3) — re-registered on the new accumulator
    address public constant YIELD_STRATEGY_DOLA = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;
    address public constant YIELD_STRATEGY_USDC = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address public constant YIELD_STRATEGY_USDE = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;

    // Old contracts (to be replaced)
    address public constant OLD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address public constant OLD_BATCH_MINTER = 0xD3104A6e6D53b37061856fe1f31296D8962f9e01;

    // Ledger signer
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ==========================================
    //         CONFIGURATION CONSTANTS
    // ==========================================

    uint256 public constant DISCOUNT_RATE_BPS = 3000; // 30%
    uint256 public constant NUDGE_SPLIT = 30; // percent (0-100)
    uint256 public constant NUDGE_SIZE = 40; // batch size threshold

    // Token configs (token, decimals, normalizedExchangeRate)
    uint8 public constant USDC_DECIMALS = 6;
    uint8 public constant DOLA_DECIMALS = 18;
    uint8 public constant USDE_DECIMALS = 18;
    uint256 public constant EXCHANGE_RATE_1E18 = 1e18;

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    address public newAccumulator;
    address public newBatchMinter;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.nudge-accumulator.1.json";
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
        console.log("  MAINNET NUDGE ACCUMULATOR DEPLOYMENT");
        console.log("=========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- LIVE CONTRACTS (mirrored on new accumulator) ---");
        console.log("USDC:                ", USDC);
        console.log("DOLA:                ", DOLA);
        console.log("USDe:                ", USDe);
        console.log("PhlimboEA:           ", PHLIMBO_EA);
        console.log("PhusdStableMinter:   ", PHUSD_STABLE_MINTER);
        console.log("NFTMinterV2:         ", NFT_MINTER_V2);
        console.log("Pauser:              ", PAUSER);
        console.log("YieldStrategyDola:   ", YIELD_STRATEGY_DOLA);
        console.log("YieldStrategyUSDC:   ", YIELD_STRATEGY_USDC);
        console.log("YieldStrategyUSDe:   ", YIELD_STRATEGY_USDE);
        console.log("");
        console.log("--- CONTRACTS BEING REPLACED ---");
        console.log("Old StableYieldAccumulator: ", OLD_ACCUMULATOR);
        console.log("Old BatchNFTMinter:         ", OLD_BATCH_MINTER);
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

        // ====== Step 1: Deploy BatchNFTMinter ======
        console.log("\n=== Step 1: Deploy BatchNFTMinter ===");
        _deployBatchNFTMinter();

        // ====== Step 2: Deploy StableYieldAccumulator ======
        console.log("\n=== Step 2: Deploy StableYieldAccumulator ===");
        _deployAccumulator();

        // ====== Step 3-7: Configure accumulator (downstream wiring) ======
        console.log("\n=== Steps 3-7: Configure accumulator downstream wiring ===");
        _configureAccumulatorDownstream();

        // ====== Steps 8-10: Token configs ======
        console.log("\n=== Steps 8-10: Token configs (USDC/DOLA/USDe) ===");
        _configureTokenConfigs();

        // ====== Steps 11-13: Yield strategies ======
        console.log("\n=== Steps 11-13: Register active yield strategies (3) ===");
        _registerYieldStrategies();

        // ====== Step 14: Discount rate ======
        console.log("\n=== Step 14: Set discount rate to 30% (3000 bps) ===");
        _setDiscountRate();

        // ====== Steps 15-16: Nudge address + split ======
        console.log("\n=== Steps 15-16: Set nudge address + split ===");
        _setNudge();

        // ====== Step 17: Approve phlimbo ======
        console.log("\n=== Step 17: Approve phlimbo for max USDC ===");
        _approvePhlimbo();

        // ====== Steps 18-19: Configure batch minter ======
        console.log("\n=== Steps 18-19: Configure BatchNFTMinter (nudgePaymentToken + nudgeSize) ===");
        _configureBatchMinter();

        // ====== Step 9.1 (post-config): collision check ======
        console.log("\n=== Sanity: assert nudgePaymentToken (USDC) does not collide with any registered dispatcher's primeToken ===");
        _assertNoNudgeTokenCollision();

        // ====== Steps 20-21: Rewire yield strategy withdrawers ======
        console.log("\n=== Steps 20-21: Rewire yield strategy withdrawers (3+3) ===");
        _rewireYieldStrategyWithdrawers();

        // ====== Steps 22-23: Rewire NFTMinterV2 burners ======
        console.log("\n=== Steps 22-23: Rewire NFTMinterV2 authorized burners ===");
        _rewireNFTMinterV2Burners();

        // ====== Step 24: Pauser registration ======
        console.log("\n=== Step 24: Register new accumulator with Pauser ===");
        _registerWithPauser();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ====== Finalize ======
        if (!isPreview) {
            _markDeploymentComplete();
        }
        _printDeploymentSummary();
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
        // Owner is the deployer (Ledger signer in broadcast, OWNER_ADDRESS prank in preview).
        BatchNFTMinter b = new BatchNFTMinter(OWNER_ADDRESS);
        newBatchMinter = address(b);
        _trackDeployment("BatchNFTMinter", newBatchMinter, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("BatchNFTMinter deployed at:", newBatchMinter);
        console.log("  - owner:", OWNER_ADDRESS);
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
        _trackDeployment("StableYieldAccumulator", newAccumulator, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("StableYieldAccumulator deployed at:", newAccumulator);
        console.log("  - owner: deployer (Ownable assigns msg.sender)");
    }

    // ========================================
    // Steps 3-7: Configure accumulator downstream wiring
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
        console.log("Step 3: setRewardToken(USDC) ->", USDC);

        sya.setPhlimbo(PHLIMBO_EA);
        console.log("Step 4: setPhlimbo(PhlimboEA) ->", PHLIMBO_EA);

        sya.setMinter(PHUSD_STABLE_MINTER);
        console.log("Step 5: setMinter(PhusdStableMinter) ->", PHUSD_STABLE_MINTER);

        sya.setNFTMinter(NFT_MINTER_V2);
        console.log("Step 6: setNFTMinter(NFTMinterV2) ->", NFT_MINTER_V2);

        sya.setPauser(PAUSER);
        console.log("Step 7: setPauser(Pauser) ->", PAUSER);

        _trackDeployment("AccumulatorDownstream", address(0), 0);
        _markConfigured("AccumulatorDownstream", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Steps 8-10: Token configs
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
        console.log("Step 8: setTokenConfig(USDC, 6, 1e18)");

        sya.setTokenConfig(DOLA, DOLA_DECIMALS, EXCHANGE_RATE_1E18);
        console.log("Step 9: setTokenConfig(DOLA, 18, 1e18)");

        sya.setTokenConfig(USDe, USDE_DECIMALS, EXCHANGE_RATE_1E18);
        console.log("Step 10: setTokenConfig(USDe, 18, 1e18)");

        _trackDeployment("TokenConfigs", address(0), 0);
        _markConfigured("TokenConfigs", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Steps 11-13: Register active yield strategies
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
        console.log("Step 11: addYieldStrategy(YieldStrategyDola, DOLA) ->", YIELD_STRATEGY_DOLA);

        sya.addYieldStrategy(YIELD_STRATEGY_USDC, USDC);
        console.log("Step 12: addYieldStrategy(YieldStrategyUSDC, USDC) ->", YIELD_STRATEGY_USDC);

        sya.addYieldStrategy(YIELD_STRATEGY_USDE, USDe);
        console.log("Step 13: addYieldStrategy(YieldStrategyUSDe, USDe) ->", YIELD_STRATEGY_USDE);

        _trackDeployment("YieldStrategies", address(0), 0);
        _markConfigured("YieldStrategies", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 14: Discount rate
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
        console.log("Step 14: setDiscountRate(", DISCOUNT_RATE_BPS, ") = 30%");

        _trackDeployment("DiscountRate", address(0), 0);
        _markConfigured("DiscountRate", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Steps 15-16: Nudge address + split
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
        console.log("Step 15: setNudgeAddress(BatchNFTMinter) ->", newBatchMinter);

        sya.setNudgeSplit(NUDGE_SPLIT);
        console.log("Step 16: setNudgeSplit(", NUDGE_SPLIT, ") = 30%");

        _trackDeployment("Nudge", address(0), 0);
        _markConfigured("Nudge", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 17: Approve phlimbo
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
        console.log("Step 17: approvePhlimbo(type(uint256).max)");

        _trackDeployment("ApprovePhlimbo", address(0), 0);
        _markConfigured("ApprovePhlimbo", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Steps 18-19: Configure batch minter
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
        console.log("Step 18: setNudgePaymentToken(USDC) ->", USDC);

        batch.setNudgeSize(NUDGE_SIZE);
        console.log("Step 19: setNudgeSize(", NUDGE_SIZE, ")");

        _trackDeployment("BatchMinterConfig", address(0), 0);
        _markConfigured("BatchMinterConfig", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 9.1: Collision check between nudgePaymentToken and active dispatcher primeTokens
    // ========================================

    /// @dev Iterates over every registered dispatcher on the live NFTMinterV2 and
    ///      asserts that none has primeToken() == USDC. The BatchNFTMinter's
    ///      nudgePaymentToken (USDC) must differ from any per-mint paymentToken
    ///      a caller might pass in batchMint() — otherwise a batch >= nudgeSize
    ///      reverts with NudgeTokenMatchesPaymentToken().
    ///
    ///      Verified via cast on 2026-05-07: no live dispatcher has USDC as
    ///      primeToken. This check is defensive in case a future dispatcher
    ///      registration changes that.
    function _assertNoNudgeTokenCollision() internal view {
        INFTMinterV2View v2 = INFTMinterV2View(NFT_MINTER_V2);
        uint256 upper = v2.nextIndex(); // exclusive
        if (upper <= 1) {
            console.log("NFTMinterV2 has no registered dispatchers; skipping collision check");
            return;
        }
        for (uint256 i = 1; i < upper; i++) {
            (address dispatcher, , , bool disabled) = v2.configs(i);
            if (dispatcher == address(0)) {
                continue;
            }
            address primeToken = ITokenDispatcherV2(dispatcher).primeToken();
            console.log("NFTMinterV2 dispatcher index", i);
            console.log("  primeToken:", primeToken);
            console.log("  disabled:  ", disabled);
            require(
                primeToken != USDC,
                "Collision: dispatcher primeToken == USDC. nudgePaymentToken (USDC) collides; escalate to user."
            );
        }
        console.log("Collision check passed: no active dispatcher uses USDC as primeToken");
    }

    // ========================================
    // Steps 20-21: Rewire yield strategy withdrawers
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

        // Step 20: grant new accumulator on each strategy
        for (uint256 i = 0; i < 3; i++) {
            AYieldStrategy(strategies[i]).setWithdrawer(newAccumulator, true);
            console.log("Step 20: setWithdrawer(newAcc, true) on", labels[i]);
            console.log("  strategy:", strategies[i]);
        }

        // Step 21: revoke old accumulator on each strategy
        for (uint256 i = 0; i < 3; i++) {
            AYieldStrategy(strategies[i]).setWithdrawer(OLD_ACCUMULATOR, false);
            console.log("Step 21: setWithdrawer(OLD_ACCUMULATOR, false) on", labels[i]);
            console.log("  strategy:", strategies[i]);
        }

        _trackDeployment("YieldStrategyRewire", address(0), 0);
        _markConfigured("YieldStrategyRewire", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Steps 22-23: Rewire NFTMinterV2 burners
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
        console.log("Step 22: NFTMinterV2.setAuthorizedBurner(newAcc, true)");
        console.log("  newAcc:", newAccumulator);

        minter.setAuthorizedBurner(OLD_ACCUMULATOR, false);
        console.log("Step 23: NFTMinterV2.setAuthorizedBurner(OLD_ACCUMULATOR, false)");
        console.log("  OLD_ACCUMULATOR:", OLD_ACCUMULATOR);

        _trackDeployment("NFTMinterV2Rewire", address(0), 0);
        _markConfigured("NFTMinterV2Rewire", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Step 24: Pauser registration
    // ========================================

    function _registerWithPauser() internal {
        if (_isConfigured("PauserRegister")) {
            console.log("Accumulator already registered with Pauser");
            return;
        }
        require(newAccumulator != address(0), "Accumulator must be deployed");

        uint256 gasBefore = gasleft();
        Pauser(PAUSER).register(newAccumulator);
        console.log("Step 24: Pauser.register(newAcc)");
        console.log("  newAcc:", newAccumulator);

        _trackDeployment("PauserRegister", address(0), 0);
        _markConfigured("PauserRegister", gasBefore - gasleft());
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
        string[14] memory names = [
            "BatchNFTMinter",
            "StableYieldAccumulator",
            "AccumulatorDownstream",
            "TokenConfigs",
            "YieldStrategies",
            "DiscountRate",
            "Nudge",
            "ApprovePhlimbo",
            "BatchMinterConfig",
            "YieldStrategyRewire",
            "NFTMinterV2Rewire",
            "PauserRegister",
            "",
            ""
        ];
        for (uint256 i = 0; i < names.length; i++) {
            if (bytes(names[i]).length == 0) continue;
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
        console.log("       NUDGE DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("New StableYieldAccumulator:", newAccumulator);
        console.log("New BatchNFTMinter:        ", newBatchMinter);
        console.log("");
        console.log("--- Address rewires (OLD -> NEW) ---");
        console.log("StableYieldAccumulator:");
        console.log("  OLD:", OLD_ACCUMULATOR);
        console.log("  NEW:", newAccumulator);
        console.log("BatchNFTMinter:");
        console.log("  OLD:", OLD_BATCH_MINTER);
        console.log("  NEW:", newBatchMinter);
        console.log("");
        console.log("--- Configuration ---");
        console.log("  rewardToken:        USDC (", USDC, ")");
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
        console.log("  YieldStrategyDola: ", YIELD_STRATEGY_DOLA);
        console.log("  YieldStrategyUSDC: ", YIELD_STRATEGY_USDC);
        console.log("  YieldStrategyUSDe: ", YIELD_STRATEGY_USDE);
        console.log("");
        console.log("--- BatchNFTMinter ---");
        console.log("  nudgePaymentToken: USDC");
        console.log("  nudgeSize:         ", NUDGE_SIZE);
        console.log("");
        console.log("--- External rewires ---");
        console.log("  YieldStrategy.setWithdrawer(newAcc, true) x3");
        console.log("  YieldStrategy.setWithdrawer(OLD_ACCUMULATOR, false) x3");
        console.log("  NFTMinterV2.setAuthorizedBurner(newAcc, true)");
        console.log("  NFTMinterV2.setAuthorizedBurner(OLD_ACCUMULATOR, false)");
        console.log("  Pauser.register(newAcc)");
        console.log("");
        _printGasSummary();
        console.log("=========================================");
    }

    function _printGasSummary() internal view {
        console.log("--- Gas consumption (per step) ---");
        uint256 totalDeployGas;
        uint256 totalConfigGas;
        for (uint256 i = 0; i < contractNames.length; i++) {
            ContractDeployment memory d = deployments[contractNames[i]];
            if (d.deployGas > 0) {
                console.log("  deploy ", d.name);
                console.log("    gas:", d.deployGas);
                totalDeployGas += d.deployGas;
            }
            if (d.configGas > 0) {
                console.log("  config ", d.name);
                console.log("    gas:", d.configGas);
                totalConfigGas += d.configGas;
            }
        }
        console.log("");
        console.log("Total deploy gas:", totalDeployGas);
        console.log("Total config gas:", totalConfigGas);
        console.log("TOTAL GAS:       ", totalDeployGas + totalConfigGas);
    }
}
