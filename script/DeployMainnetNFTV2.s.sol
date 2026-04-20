// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@pauser/Pauser.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {NFTMinter} from "@yield-claim-nft/NFTMinter.sol";
import {NFTMinterV2} from "@yield-claim-nft/V2/NFTMinterV2.sol";
import {NFTMigrator} from "@yield-claim-nft/V2/NFTMigrator.sol";
import {BurnerV2} from "@yield-claim-nft/V2/dispatchers/BurnerV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";
import {GatherV2} from "@yield-claim-nft/V2/dispatchers/GatherV2.sol";
import {BalancerPooler as V1BalancerPooler} from "@yield-claim-nft/dispatchers/BalancerPooler.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title DeployMainnetNFTV2
 * @notice Mainnet deployment script for NFT V2 stack + NFTMigrator. Mirrors price/growth
 *         from live V1 dispatchers, except BalancerPoolerV2 which converts sUSDS -> USDS
 *         (via IERC4626.convertToAssets) and uses 1 bp growth.
 *
 *         Execution order (see story 043):
 *           1. Deploy NFTMinterV2 + 5 V2 dispatchers (BurnerEYE/SCX/Flax, BalancerPooler, GatherWBTC).
 *           2. Register dispatchers at indices 1-5, mirroring V1 prices/growth; convert index 4.
 *           3. setMinter on each dispatcher, authorize V2 burners on BurnRecorder.
 *           4. Deploy NFTMigrator, authorize migrator on both minters, set mappings, initialize.
 *           5. Rewire StableYieldAccumulator: setNFTMinter(V2), grant V2 burn auth, revoke V1 burn auth.
 *           6. Register NFTMinterV2 with the live Pauser.
 *           7. Log current discount rate and call setDiscountRate(3500).
 *           8. Withdraw any BPT balance on V1 BalancerPooler to the gatherer recipient.
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/DeployMainnetNFTV2.s.sol --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast:
 *   forge script script/DeployMainnetNFTV2.s.sol --rpc-url $RPC_MAINNET --broadcast
 *     --skip-simulation --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

/// @notice Minimal interface for reading V1 NFTMinter state (price + config tuple).
interface IYieldNFTMinter {
    function getPrice(uint256 index) external view returns (uint256);
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

contract DeployMainnetNFTV2 is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    // Core protocol
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant STABLE_YIELD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address public constant BURN_RECORDER = 0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F;

    // V1 NFT stack
    address public constant V1_NFT_MINTER = 0xd936461f1C15eA9f34Ca1F20ecD54A0819068811;
    address public constant V1_BALANCER_POOLER = 0xC2d1a82C66Fd535ae218b59F77a1B716919a46C3;

    // ERC20 tokens
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLAX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    // Balancer V3
    address public constant BALANCER_POOL = 0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58;
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address public constant BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;

    // Signers / recipients
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant GATHERER_RECIPIENT = 0x64d3CbAB6100782a7839fC1af791027a2f1908D2;

    // ==========================================
    //         CONFIGURATION CONSTANTS
    // ==========================================

    uint256 public constant DISCOUNT_RATE_BPS = 3500; // 35%
    uint256 public constant BALANCER_POOLER_V2_GROWTH_BPS = 1; // 0.01% minimum non-zero growth
    bool public constant SUSDS_IS_FIRST = true; // Live mainnet pool: sUSDS is token[0]

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    address public nftMinterV2;
    address public burnerEYEV2;
    address public burnerSCXV2;
    address public burnerFlaxV2;
    address public balancerPoolerV2;
    address public gatherWBTCV2;
    address public nftMigrator;

    // Mirrored from V1 at deploy time (indexes 0..4 correspond to dispatcher indexes 1..5)
    uint256[5] public v1Prices;
    uint256[5] public v1Growth;
    uint256 public balancerV2UsdsPrice;
    uint256 public priorDiscountRate;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.nftv2.1.json";
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
        console.log("  MAINNET NFT V2 DEPLOYMENT");
        console.log("=========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- EXISTING CONTRACTS ---");
        console.log("Pauser:                      ", PAUSER);
        console.log("StableYieldAccumulator:      ", STABLE_YIELD_ACCUMULATOR);
        console.log("BurnRecorder:                ", BURN_RECORDER);
        console.log("V1 NFTMinter:                ", V1_NFT_MINTER);
        console.log("V1 BalancerPooler:           ", V1_BALANCER_POOLER);
        console.log("");
        console.log("--- TOKENS ---");
        console.log("EYE:   ", EYE);
        console.log("SCX:   ", SCX);
        console.log("Flax:  ", FLAX);
        console.log("WBTC:  ", WBTC);
        console.log("sUSDS: ", SUSDS);
        console.log("USDS:  ", USDS);
        console.log("");
        console.log("--- BALANCER V3 ---");
        console.log("Pool:    ", BALANCER_POOL);
        console.log("Vault:   ", BALANCER_VAULT);
        console.log("Router:  ", BALANCER_ROUTER);
        console.log("");
        console.log("--- RECIPIENTS ---");
        console.log("Owner (ledger):    ", OWNER_ADDRESS);
        console.log("Gatherer recipient:", GATHERER_RECIPIENT);
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

        // ====== Phase 1: Read live V1 prices + growth rates ======
        console.log("\n=== Phase 1: Read V1 prices & growth from live NFTMinter ===");
        _readV1Prices();

        // ====== Phase 2: Deploy V2 NFTMinter + dispatchers ======
        console.log("\n=== Phase 2: Deploy V2 contracts ===");
        _deployNFTMinterV2();
        _deployBurnerEYEV2();
        _deployBurnerSCXV2();
        _deployBurnerFlaxV2();
        _deployBalancerPoolerV2();
        _deployGatherWBTCV2();

        // ====== Phase 3: Wire V2 dispatchers to NFTMinterV2 ======
        console.log("\n=== Phase 3: Register dispatchers + setMinter on each ===");
        _registerDispatchersV2();
        _setMintersOnV2Dispatchers();
        _authorizeV2BurnersOnBurnRecorder();

        // ====== Phase 4: NFTMigrator ======
        console.log("\n=== Phase 4: NFTMigrator deploy + wiring ===");
        _deployNFTMigrator();
        _configureNFTMigrator();

        // ====== Phase 5: SYA rewire to V2 ======
        console.log("\n=== Phase 5: Rewire StableYieldAccumulator to V2 minter ===");
        _rewireStableYieldAccumulator();

        // ====== Phase 6: Pauser registration ======
        console.log("\n=== Phase 6: Register NFTMinterV2 with live Pauser ===");
        _registerV2WithPauser();

        // ====== Phase 7: Discount rate update ======
        console.log("\n=== Phase 7: Lower SYA discount rate to 3500 bps ===");
        _setDiscountRate();

        // ====== Phase 8: Withdraw V1 BPT ======
        console.log("\n=== Phase 8: Withdraw BPT from V1 BalancerPooler ===");
        _withdrawV1BPT();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ====== Phase 9: Finalize ======
        if (!isPreview) {
            _markDeploymentComplete();
        }
        _printDeploymentSummary();
    }

    // ========================================
    // Phase 1: Read V1 prices
    // ========================================

    function _readV1Prices() internal {
        IYieldNFTMinter v1 = IYieldNFTMinter(V1_NFT_MINTER);
        for (uint256 i = 1; i <= 5; i++) {
            uint256 price = v1.getPrice(i);
            (, , uint256 g, ) = v1.configs(i);
            v1Prices[i - 1] = price;
            v1Growth[i - 1] = g;
            console.log("V1 index", i);
            console.log("  price: ", price);
            console.log("  growth (bps):", g);
        }

        // Convert sUSDS price -> USDS price for V2 index 4.
        balancerV2UsdsPrice = IERC4626(SUSDS).convertToAssets(v1Prices[3]);
        console.log("Index 4 (BalancerPooler) conversion:");
        console.log("  V1 sUSDS price:     ", v1Prices[3]);
        console.log("  V2 USDS price:      ", balancerV2UsdsPrice);
        console.log("  V2 growth (bps):    ", BALANCER_POOLER_V2_GROWTH_BPS);
    }

    // ========================================
    // Phase 2: Deployments
    // ========================================

    function _deployNFTMinterV2() internal {
        if (_isDeployed("NFTMinterV2")) {
            nftMinterV2 = deployments["NFTMinterV2"].addr;
            console.log("NFTMinterV2 already deployed at:", nftMinterV2);
            return;
        }
        uint256 gasBefore = gasleft();
        NFTMinterV2 m = new NFTMinterV2(OWNER_ADDRESS);
        nftMinterV2 = address(m);
        _trackDeployment("NFTMinterV2", nftMinterV2, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("NFTMinterV2 deployed at:", nftMinterV2);
    }

    function _deployBurnerEYEV2() internal {
        if (_isDeployed("BurnerEYEV2")) {
            burnerEYEV2 = deployments["BurnerEYEV2"].addr;
            console.log("BurnerEYEV2 already deployed at:", burnerEYEV2);
            return;
        }
        uint256 gasBefore = gasleft();
        BurnerV2 b = new BurnerV2(EYE, BURN_RECORDER, OWNER_ADDRESS);
        burnerEYEV2 = address(b);
        _trackDeployment("BurnerEYEV2", burnerEYEV2, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("BurnerEYEV2 deployed at:", burnerEYEV2);
    }

    function _deployBurnerSCXV2() internal {
        if (_isDeployed("BurnerSCXV2")) {
            burnerSCXV2 = deployments["BurnerSCXV2"].addr;
            console.log("BurnerSCXV2 already deployed at:", burnerSCXV2);
            return;
        }
        uint256 gasBefore = gasleft();
        BurnerV2 b = new BurnerV2(SCX, BURN_RECORDER, OWNER_ADDRESS);
        burnerSCXV2 = address(b);
        _trackDeployment("BurnerSCXV2", burnerSCXV2, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("BurnerSCXV2 deployed at:", burnerSCXV2);
    }

    function _deployBurnerFlaxV2() internal {
        if (_isDeployed("BurnerFlaxV2")) {
            burnerFlaxV2 = deployments["BurnerFlaxV2"].addr;
            console.log("BurnerFlaxV2 already deployed at:", burnerFlaxV2);
            return;
        }
        uint256 gasBefore = gasleft();
        BurnerV2 b = new BurnerV2(FLAX, BURN_RECORDER, OWNER_ADDRESS);
        burnerFlaxV2 = address(b);
        _trackDeployment("BurnerFlaxV2", burnerFlaxV2, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("BurnerFlaxV2 deployed at:", burnerFlaxV2);
    }

    function _deployBalancerPoolerV2() internal {
        if (_isDeployed("BalancerPoolerV2")) {
            balancerPoolerV2 = deployments["BalancerPoolerV2"].addr;
            console.log("BalancerPoolerV2 already deployed at:", balancerPoolerV2);
            return;
        }
        uint256 gasBefore = gasleft();
        BalancerPoolerV2 bp = new BalancerPoolerV2(
            SUSDS,
            BALANCER_POOL,
            BALANCER_VAULT,
            BALANCER_ROUTER,
            SUSDS_IS_FIRST,
            OWNER_ADDRESS
        );
        balancerPoolerV2 = address(bp);
        _trackDeployment("BalancerPoolerV2", balancerPoolerV2, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("BalancerPoolerV2 deployed at:", balancerPoolerV2);
    }

    function _deployGatherWBTCV2() internal {
        if (_isDeployed("GatherWBTCV2")) {
            gatherWBTCV2 = deployments["GatherWBTCV2"].addr;
            console.log("GatherWBTCV2 already deployed at:", gatherWBTCV2);
            return;
        }
        uint256 gasBefore = gasleft();
        GatherV2 g = new GatherV2(WBTC, GATHERER_RECIPIENT, OWNER_ADDRESS);
        gatherWBTCV2 = address(g);
        _trackDeployment("GatherWBTCV2", gatherWBTCV2, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("GatherWBTCV2 deployed at:", gatherWBTCV2);
    }

    // ========================================
    // Phase 3: V2 NFTMinter wiring
    // ========================================

    function _registerDispatchersV2() internal {
        if (_isConfigured("NFTMinterV2Dispatchers")) {
            console.log("NFTMinterV2 dispatchers already registered");
            return;
        }
        require(nftMinterV2 != address(0), "NFTMinterV2 must be deployed");

        uint256 gasBefore = gasleft();
        NFTMinterV2 m = NFTMinterV2(nftMinterV2);

        // Index 1: BurnerEYEV2 — mirror V1 price + growth
        m.registerDispatcher(burnerEYEV2, v1Prices[0], v1Growth[0]);
        console.log("Registered BurnerEYEV2 (index 1)");

        // Index 2: BurnerSCXV2
        m.registerDispatcher(burnerSCXV2, v1Prices[1], v1Growth[1]);
        console.log("Registered BurnerSCXV2 (index 2)");

        // Index 3: BurnerFlaxV2
        m.registerDispatcher(burnerFlaxV2, v1Prices[2], v1Growth[2]);
        console.log("Registered BurnerFlaxV2 (index 3)");

        // Index 4: BalancerPoolerV2 — USDS-denominated, 1 bp growth
        m.registerDispatcher(balancerPoolerV2, balancerV2UsdsPrice, BALANCER_POOLER_V2_GROWTH_BPS);
        console.log("Registered BalancerPoolerV2 (index 4, 1 bp growth, USDS terms)");

        // Index 5: GatherV2 (WBTC)
        m.registerDispatcher(gatherWBTCV2, v1Prices[4], v1Growth[4]);
        console.log("Registered GatherWBTCV2 (index 5)");

        _trackDeployment("NFTMinterV2Dispatchers", address(0), 0);
        _markConfigured("NFTMinterV2Dispatchers", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    function _setMintersOnV2Dispatchers() internal {
        if (_isConfigured("V2DispatcherMinters")) {
            console.log("V2 dispatcher minters already configured");
            return;
        }

        uint256 gasBefore = gasleft();
        BurnerV2(burnerEYEV2).setMinter(nftMinterV2);
        BurnerV2(burnerSCXV2).setMinter(nftMinterV2);
        BurnerV2(burnerFlaxV2).setMinter(nftMinterV2);
        BalancerPoolerV2(balancerPoolerV2).setMinter(nftMinterV2);
        GatherV2(gatherWBTCV2).setMinter(nftMinterV2);
        console.log("All V2 dispatchers setMinter -> NFTMinterV2");

        _trackDeployment("V2DispatcherMinters", address(0), 0);
        _markConfigured("V2DispatcherMinters", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    function _authorizeV2BurnersOnBurnRecorder() internal {
        if (_isConfigured("V2BurnRecorderAuth")) {
            console.log("V2 burners already authorized on BurnRecorder");
            return;
        }

        uint256 gasBefore = gasleft();
        // BurnRecorder.setBurner is the authorization method
        (bool ok1,) = BURN_RECORDER.call(abi.encodeWithSignature("setBurner(address,bool)", burnerEYEV2, true));
        require(ok1, "setBurner BurnerEYEV2 failed");
        (bool ok2,) = BURN_RECORDER.call(abi.encodeWithSignature("setBurner(address,bool)", burnerSCXV2, true));
        require(ok2, "setBurner BurnerSCXV2 failed");
        (bool ok3,) = BURN_RECORDER.call(abi.encodeWithSignature("setBurner(address,bool)", burnerFlaxV2, true));
        require(ok3, "setBurner BurnerFlaxV2 failed");
        console.log("BurnRecorder.setBurner(V2 burner, true) x3");

        _trackDeployment("V2BurnRecorderAuth", address(0), 0);
        _markConfigured("V2BurnRecorderAuth", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Phase 4: NFTMigrator
    // ========================================

    function _deployNFTMigrator() internal {
        if (_isDeployed("NFTMigrator")) {
            nftMigrator = deployments["NFTMigrator"].addr;
            console.log("NFTMigrator already deployed at:", nftMigrator);
            return;
        }
        uint256 gasBefore = gasleft();
        NFTMigrator m = new NFTMigrator(V1_NFT_MINTER, nftMinterV2, OWNER_ADDRESS);
        nftMigrator = address(m);
        _trackDeployment("NFTMigrator", nftMigrator, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("NFTMigrator deployed at:", nftMigrator);
    }

    function _configureNFTMigrator() internal {
        if (_isConfigured("NFTMigratorConfig")) {
            console.log("NFTMigrator already configured");
            return;
        }
        require(nftMigrator != address(0), "NFTMigrator must be deployed");

        uint256 gasBefore = gasleft();

        // Authorize migrator: burn V1 + mint V2
        NFTMinter(V1_NFT_MINTER).setAuthorizedBurner(nftMigrator, true);
        console.log("V1 NFTMinter.setAuthorizedBurner(NFTMigrator, true)");
        NFTMinterV2(nftMinterV2).setAuthorizedMinter(nftMigrator, true);
        console.log("NFTMinterV2.setAuthorizedMinter(NFTMigrator, true)");

        // 1:1 mapping for indices 1-5
        uint256[] memory v1Indexes = new uint256[](5);
        uint256[] memory v2Indexes = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            v1Indexes[i] = i + 1;
            v2Indexes[i] = i + 1;
        }
        NFTMigrator(nftMigrator).setMappings(v1Indexes, v2Indexes);
        console.log("NFTMigrator mappings set (1:1 for indices 1-5)");

        NFTMigrator(nftMigrator).setInitialized();
        console.log("NFTMigrator initialized");

        _trackDeployment("NFTMigratorConfig", address(0), 0);
        _markConfigured("NFTMigratorConfig", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Phase 5: SYA rewire
    // ========================================

    function _rewireStableYieldAccumulator() internal {
        if (_isConfigured("SYARewire")) {
            console.log("SYA already rewired to V2");
            return;
        }

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(STABLE_YIELD_ACCUMULATOR);

        sya.setNFTMinter(nftMinterV2);
        console.log("SYA.setNFTMinter -> NFTMinterV2");

        NFTMinterV2(nftMinterV2).setAuthorizedBurner(STABLE_YIELD_ACCUMULATOR, true);
        console.log("NFTMinterV2.setAuthorizedBurner(SYA, true)");

        NFTMinter(V1_NFT_MINTER).setAuthorizedBurner(STABLE_YIELD_ACCUMULATOR, false);
        console.log("V1 NFTMinter.setAuthorizedBurner(SYA, false)");

        _trackDeployment("SYARewire", address(0), 0);
        _markConfigured("SYARewire", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Phase 6: Pauser
    // ========================================

    function _registerV2WithPauser() internal {
        if (_isConfigured("V2PauserRegistration")) {
            console.log("NFTMinterV2 already registered with Pauser");
            return;
        }

        uint256 gasBefore = gasleft();
        NFTMinterV2(nftMinterV2).setPauser(PAUSER);
        console.log("NFTMinterV2.setPauser(Pauser)");
        Pauser(PAUSER).register(nftMinterV2);
        console.log("Pauser.register(NFTMinterV2)");

        _trackDeployment("V2PauserRegistration", address(0), 0);
        _markConfigured("V2PauserRegistration", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Phase 7: Discount rate
    // ========================================

    function _setDiscountRate() internal {
        if (_isConfigured("DiscountRateUpdate")) {
            console.log("Discount rate already updated");
            return;
        }

        uint256 gasBefore = gasleft();
        StableYieldAccumulator sya = StableYieldAccumulator(STABLE_YIELD_ACCUMULATOR);

        priorDiscountRate = sya.discountRate();
        console.log("Current (pre-update) discount rate:", priorDiscountRate);
        sya.setDiscountRate(DISCOUNT_RATE_BPS);
        console.log("New discount rate:", DISCOUNT_RATE_BPS);

        _trackDeployment("DiscountRateUpdate", address(0), 0);
        _markConfigured("DiscountRateUpdate", gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
    }

    // ========================================
    // Phase 8: Withdraw V1 BPT
    // ========================================

    function _withdrawV1BPT() internal {
        if (_isConfigured("V1BPTWithdraw")) {
            console.log("V1 BPT withdraw already executed");
            return;
        }

        uint256 gasBefore = gasleft();
        uint256 bptBalance = IERC20(BALANCER_POOL).balanceOf(V1_BALANCER_POOLER);
        console.log("V1 BalancerPooler BPT balance:", bptBalance);
        if (bptBalance > 0) {
            V1BalancerPooler(V1_BALANCER_POOLER).withdrawBPT(GATHERER_RECIPIENT, bptBalance);
            console.log("Withdrew BPT to gatherer recipient:", GATHERER_RECIPIENT);
        } else {
            console.log("No BPT to withdraw (balance == 0)");
        }

        _trackDeployment("V1BPTWithdraw", address(0), 0);
        _markConfigured("V1BPTWithdraw", gasBefore - gasleft());
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
        string[13] memory names = [
            "NFTMinterV2",
            "BurnerEYEV2",
            "BurnerSCXV2",
            "BurnerFlaxV2",
            "BalancerPoolerV2",
            "GatherWBTCV2",
            "NFTMigrator",
            "NFTMinterV2Dispatchers",
            "V2DispatcherMinters",
            "V2BurnRecorderAuth",
            "NFTMigratorConfig",
            "SYARewire",
            "V2PauserRegistration"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            _parseEntry(json, names[i]);
        }
        // Additional config-only steps (separate loop to avoid stack issues)
        _parseEntry(json, "DiscountRateUpdate");
        _parseEntry(json, "V1BPTWithdraw");
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
        console.log("       V2 DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("NFTMinterV2:         ", nftMinterV2);
        console.log("BurnerEYEV2:         ", burnerEYEV2);
        console.log("BurnerSCXV2:         ", burnerSCXV2);
        console.log("BurnerFlaxV2:        ", burnerFlaxV2);
        console.log("BalancerPoolerV2:    ", balancerPoolerV2);
        console.log("GatherWBTCV2:        ", gatherWBTCV2);
        console.log("NFTMigrator:         ", nftMigrator);
        console.log("");
        console.log("V1 -> V2 price mirroring:");
        console.log("  Index 1 (EYE)    price:", v1Prices[0]);
        console.log("                  growth:", v1Growth[0]);
        console.log("  Index 2 (SCX)    price:", v1Prices[1]);
        console.log("                  growth:", v1Growth[1]);
        console.log("  Index 3 (Flax)   price:", v1Prices[2]);
        console.log("                  growth:", v1Growth[2]);
        console.log("  Index 4 V1 sUSDS price:", v1Prices[3]);
        console.log("  Index 4 V2 USDS  price:", balancerV2UsdsPrice);
        console.log("  Index 4 V2 growth (bps):", BALANCER_POOLER_V2_GROWTH_BPS);
        console.log("  Index 5 (WBTC)   price:", v1Prices[4]);
        console.log("                  growth:", v1Growth[4]);
        console.log("");
        console.log("SYA discount rate:");
        console.log("  prior:", priorDiscountRate);
        console.log("  new:  ", DISCOUNT_RATE_BPS);
        console.log("=========================================");
    }
}
