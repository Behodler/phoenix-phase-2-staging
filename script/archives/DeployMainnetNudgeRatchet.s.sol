// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@pauser/Pauser.sol";
import {NudgeRatchet} from "@yield-claim-nft/dispatchers/NudgeRatchet.sol";
import {NudgeRatchetMintDebtHook} from "@yield-claim-nft/hooks/NudgeRatchetMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";
import {IBalancerPoolerMintDebtHook} from "@yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {ITokenMinterV2} from "@yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {NFTStakerPriceScaled} from "nft-staking/NFTStakerPriceScaled.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {INFTSupply} from "nft-staking/INFTSupply.sol";
import {FlaxToken} from "@flax-token/FlaxToken.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
import {ViewRouter} from "../src/views/ViewRouter.sol";
import {IPageView} from "../src/views/IPageView.sol";
// V1 INFTMinter removed (yield-claim-nft story-039); MintPageView now takes INFTMinterV2.
import {INFTMinterV2 as INFTMinter} from "@yield-claim-nft/interfaces/INFTMinterV2.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMainnetNudgeRatchet
 * @notice Single-broadcast mainnet deployment that promotes story 068's local
 *         NudgeRatchet integration (DeployMocks.s.sol Phase 3.7) to mainnet.
 *
 *         Deploys five contracts, wires them together, registers the NudgeRatchet
 *         dispatcher (auto-assigns index 7 — index 6 is the permanently disabled
 *         bugged pooler), and redeploys MintPageView so the mint page surfaces the
 *         new ratchet path. A companion Node patcher (patch-mainnet-addresses-ratchet.js)
 *         fills the address fields after broadcast.
 *
 *         Deploy + wiring order (mirrors DeployMocks.s.sol exactly — the hook is fully
 *         wired BEFORE NFTMinterV2.registerDispatcher so the dispatcher is never bricked):
 *           1.  Deploy RatchetBatchNFTMinter(owner)
 *           2.  RatchetBatchNFTMinter.setTokenMinter(NFTMinterV2)
 *           3.  RatchetBatchNFTMinter.setDispatcherIndex(7)
 *               (NudgeRatchet is deployed in step 4 BEFORE this in DeployMocks, but the
 *                ratchet BatchNFTMinter index pin in DeployMocks comes after registration.
 *                We follow DeployMocks ordering precisely below.)
 *           4.  Deploy NudgeRatchet(USDC, RatchetBatchNFTMinter, owner)
 *           5.  NudgeRatchet.setMinter(NFTMinterV2)
 *           6.  Deploy NudgeRatchetMintDebtHook(owner, NudgeRatchet, phUSD)
 *           7.  NudgeRatchet.setHook(hook)
 *           8.  phUSD.setMinter(hook, true)
 *           9.  NFTMinterV2.registerDispatcher(NudgeRatchet, 10_000_000, 100) -> index 7
 *          10.  Deploy NFTStakerPriceScaled(NFTMinterV2, 7, phUSD, owner, NFTMinterV2, 7, 1e12)
 *          11.  NFTStakerPriceScaled.setDispatcherHook(hook)
 *          12.  hook.setRecipient(NFTStakerPriceScaled)
 *          13.  NFTStakerPriceScaled.setTargetAPY(0.45e18)
 *          14.  RatchetBatchNFTMinter.setNudgePaymentToken(USDS)
 *          15.  RatchetBatchNFTMinter.setNudgeSize(40)
 *          16.  NFTStakerPriceScaled.setPauser(Pauser); Pauser.register(staker)
 *          17.  Deploy MintPageView(NFTMinterV2, BurnRecorder, EYE, SCX, FLAX, USDS, WBTC, USDC)
 *          18.  ViewRouter.setPage(keccak256("mint"), MintPageView)
 *
 *         NOTE on DeployMocks parity: DeployMocks deploys RatchetBatchNFTMinter LAST
 *         (after the staker) and pins its index/nudge config there. The constructor args
 *         and the *set of* config calls are identical; only the relative position of the
 *         batch-minter block differs. Because NudgeRatchet's batchMinter_ constructor arg
 *         requires the batch minter to exist FIRST, we deploy RatchetBatchNFTMinter up
 *         front (step 1) — exactly as the story spec's "Contracts to Deploy (in order)"
 *         lists it. Its dispatcher-index pin uses the on-chain registered index (==7),
 *         derived after registration, identical to DeployMocks.
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/DeployMainnetNudgeRatchet.s.sol --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast:
 *   forge script script/DeployMainnetNudgeRatchet.s.sol --rpc-url $RPC_MAINNET --broadcast
 *     --skip-simulation --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract DeployMainnetNudgeRatchet is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    //   (from server/deployments/mainnet-addresses.ts)
    // ==========================================

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // MintPageView dependencies (shared NFT infra + V2 prime tokens)
    address public constant BURN_RECORDER = 0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F;
    address public constant VIEW_ROUTER = 0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a;
    address public constant OLD_MINT_PAGE_VIEW = 0x64FE63ca7BA456a9Bb190140e35DF2e437AbD119;

    // Prime tokens consumed by the V2 mint flow (must match each dispatcher's primeToken()).
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLAX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // V2 BalancerPoolerV2 prime (index 4)
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    // Canonical mainnet USDC — NudgeRatchet's 6-decimal prime token (dispatcher index 7).
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ==========================================
    //         CONFIGURATION CONSTANTS
    //   Configuration Safety (CLAUDE.md): every value below is deliberately
    //   chosen and justified — none left at a zero/compiler default.
    // ==========================================

    /// @notice Mint price for the ratchet dispatcher: 10 USDC (6-decimal). Confirmed by story spec.
    uint256 public constant RATCHET_INITIAL_PRICE = 10_000_000; // 10 * 1e6
    /// @notice Per-mint price growth: 1% = 100 basis points. Confirmed by story spec.
    uint256 public constant RATCHET_GROWTH_BPS = 100;
    /// @notice 45% target APY (1e18-scaled). Bounded by NFTStakerPriceScaled.MAX_TARGET_APY = 0.5e18.
    uint256 public constant TARGET_APY = 0.45e18;
    /// @notice priceScale = 1e12 normalises 6-decimal USDC mint price against 18-decimal phUSD reward,
    ///         so latestPrice * priceScale does not floor-divide the emission rate to zero.
    uint256 public constant RATCHET_PRICE_SCALE = 1e12;
    /// @notice RatchetBatchNFTMinter nudge REWARD token = USDS (18-decimal), deliberately DISTINCT
    ///         from the USDC payment token (BatchNFTMinter reverts if they match). The nudge feature
    ///         is not used for the ratchet flow, but reusing BatchNFTMinter avoids a new contract.
    address public constant RATCHET_NUDGE_TOKEN = USDS;
    /// @notice Match the existing mainnet BatchNFTMinter's nudge size (40) for consistency. Never
    ///         triggered for the ratchet flow; carried for parity with the index-4 batch minter.
    uint256 public constant RATCHET_NUDGE_SIZE = 40;
    /// @notice Expected dispatcher index after registration (index 6 is the disabled bugged pooler).
    uint256 public constant EXPECTED_RATCHET_INDEX = 7;

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    address public ratchetBatchNFTMinter;
    address public nudgeRatchet;
    address public nudgeRatchetHook;
    address public ratchetNFTStaker;
    address public mintPageView;
    uint256 public ratchetIndex;

    // Progress tracking
    string constant PROGRESS_FILE = "server/deployments/progress.nudge-ratchet.1.json";
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
        console.log("  MAINNET NUDGE RATCHET DEPLOYMENT");
        console.log("=========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- EXISTING CONTRACTS ---");
        console.log("Owner (ledger):       ", OWNER_ADDRESS);
        console.log("NFTMinterV2:          ", NFT_MINTER_V2);
        console.log("phUSD (FlaxToken):    ", PHUSD);
        console.log("Pauser:               ", PAUSER);
        console.log("BurnRecorder:         ", BURN_RECORDER);
        console.log("ViewRouter:           ", VIEW_ROUTER);
        console.log("USDC (ratchet prime): ", USDC);
        console.log("USDS (nudge reward):  ", USDS);
        console.log("--- CONFIG ---");
        console.log("Ratchet price (USDC): ", RATCHET_INITIAL_PRICE);
        console.log("Growth (bps):         ", RATCHET_GROWTH_BPS);
        console.log("Target APY (1e18):    ", TARGET_APY);
        console.log("Price scale:          ", RATCHET_PRICE_SCALE);
        console.log("Nudge size:           ", RATCHET_NUDGE_SIZE);
        console.log("----------------------------------------------------");

        // Configuration Safety guards — refuse to broadcast with unsafe defaults.
        require(RATCHET_INITIAL_PRICE > 0, "ratchet mint price unset");
        require(RATCHET_GROWTH_BPS > 0, "ratchet growth unset");
        require(TARGET_APY > 0, "target APY unset");
        require(RATCHET_PRICE_SCALE > 0, "price scale unset");
        require(USDC != address(0) && USDS != address(0) && PHUSD != address(0), "token address unset");
        require(OWNER_ADDRESS != address(0), "owner unset");

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

        // ====== Step 1: Deploy RatchetBatchNFTMinter ======
        console.log("\n=== Step 1: Deploy RatchetBatchNFTMinter ===");
        _deployRatchetBatchNFTMinter();

        // ====== Step 2: RatchetBatchNFTMinter.setTokenMinter(NFTMinterV2) ======
        console.log("\n=== Step 2: RatchetBatchNFTMinter.setTokenMinter(NFTMinterV2) ===");
        _setBatchTokenMinter();

        // ====== Step 3: Deploy NudgeRatchet(USDC, RatchetBatchNFTMinter, owner) ======
        console.log("\n=== Step 3: Deploy NudgeRatchet ===");
        _deployNudgeRatchet();

        // ====== Step 4: NudgeRatchet.setMinter(NFTMinterV2) ======
        console.log("\n=== Step 4: NudgeRatchet.setMinter(NFTMinterV2) ===");
        _setRatchetMinter();

        // ====== Step 5: Deploy NudgeRatchetMintDebtHook(owner, NudgeRatchet, phUSD) ======
        console.log("\n=== Step 5: Deploy NudgeRatchetMintDebtHook ===");
        _deployHook();

        // ====== Step 6: NudgeRatchet.setHook(hook) ======
        console.log("\n=== Step 6: NudgeRatchet.setHook(hook) ===");
        _setHookOnRatchet();

        // ====== Step 7: phUSD.setMinter(hook, true) ======
        console.log("\n=== Step 7: phUSD.setMinter(hook, true) ===");
        _authorizeHookAsMinter();

        // ====== Step 8: NFTMinterV2.registerDispatcher(NudgeRatchet, 10 USDC, 1%) -> index 7 ======
        console.log("\n=== Step 8: NFTMinterV2.registerDispatcher(NudgeRatchet) ===");
        _registerRatchetDispatcher();

        // ====== Step 9: RatchetBatchNFTMinter.setDispatcherIndex(ratchetIndex) ======
        console.log("\n=== Step 9: RatchetBatchNFTMinter.setDispatcherIndex(ratchetIndex) ===");
        _setBatchDispatcherIndex();

        // ====== Step 10: Deploy NFTStakerPriceScaled ======
        console.log("\n=== Step 10: Deploy NFTStakerPriceScaled (RatchetNFTStaker) ===");
        _deployRatchetStaker();

        // ====== Step 11: NFTStakerPriceScaled.setDispatcherHook(hook) ======
        console.log("\n=== Step 11: RatchetNFTStaker.setDispatcherHook(hook) ===");
        _setDispatcherHookOnStaker();

        // ====== Step 12: hook.setRecipient(NFTStakerPriceScaled) ======
        console.log("\n=== Step 12: hook.setRecipient(RatchetNFTStaker) ===");
        _setRecipientOnHook();

        // ====== Step 13: NFTStakerPriceScaled.setTargetAPY(0.45e18) ======
        console.log("\n=== Step 13: RatchetNFTStaker.setTargetAPY(0.45e18) ===");
        _setTargetAPYOnStaker();

        // ====== Step 14: RatchetBatchNFTMinter.setNudgePaymentToken(USDS) ======
        console.log("\n=== Step 14: RatchetBatchNFTMinter.setNudgePaymentToken(USDS) ===");
        _setBatchNudgeToken();

        // ====== Step 15: RatchetBatchNFTMinter.setNudgeSize(40) ======
        console.log("\n=== Step 15: RatchetBatchNFTMinter.setNudgeSize(40) ===");
        _setBatchNudgeSize();

        // ====== Step 16: RatchetNFTStaker.setPauser + Pauser.register ======
        console.log("\n=== Step 16: RatchetNFTStaker.setPauser + Pauser.register ===");
        _registerStakerWithPauser();

        // ====== Step 17: Deploy new MintPageView ======
        console.log("\n=== Step 17: Deploy MintPageView ===");
        _deployMintPageView();

        // ====== Step 18: ViewRouter.setPage(keccak256("mint"), MintPageView) ======
        console.log("\n=== Step 18: ViewRouter.setPage('mint', MintPageView) ===");
        _registerMintPageView();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // Post-broadcast verification (read-only; safe in both modes).
        _verifyWiring();

        if (!isPreview) {
            _markDeploymentComplete();
        }
        _printDeploymentSummary();
    }

    // ========================================
    // Step 1: Deploy RatchetBatchNFTMinter
    // ========================================

    function _deployRatchetBatchNFTMinter() internal {
        if (_isDeployed("RatchetBatchNFTMinter")) {
            ratchetBatchNFTMinter = deployments["RatchetBatchNFTMinter"].addr;
            console.log("RatchetBatchNFTMinter already deployed at:", ratchetBatchNFTMinter);
            return;
        }
        uint256 gasBefore = gasleft();
        BatchNFTMinter b = new BatchNFTMinter(OWNER_ADDRESS);
        ratchetBatchNFTMinter = address(b);
        _trackDeployment("RatchetBatchNFTMinter", ratchetBatchNFTMinter, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("RatchetBatchNFTMinter deployed at:", ratchetBatchNFTMinter);
    }

    // ========================================
    // Step 2: RatchetBatchNFTMinter.setTokenMinter
    // ========================================

    function _setBatchTokenMinter() internal {
        if (_isConfigured("batch_setTokenMinter")) {
            console.log("RatchetBatchNFTMinter.setTokenMinter already configured");
            return;
        }
        require(ratchetBatchNFTMinter != address(0), "RatchetBatchNFTMinter must be deployed");

        uint256 gasBefore = gasleft();
        BatchNFTMinter(ratchetBatchNFTMinter).setTokenMinter(ITokenMinterV2(NFT_MINTER_V2));
        console.log("RatchetBatchNFTMinter.setTokenMinter -> NFTMinterV2");
        _trackConfig("batch_setTokenMinter", gasBefore - gasleft());
    }

    // ========================================
    // Step 3: Deploy NudgeRatchet
    // ========================================

    function _deployNudgeRatchet() internal {
        if (_isDeployed("NudgeRatchet")) {
            nudgeRatchet = deployments["NudgeRatchet"].addr;
            console.log("NudgeRatchet already deployed at:", nudgeRatchet);
            return;
        }
        require(ratchetBatchNFTMinter != address(0), "RatchetBatchNFTMinter must be deployed");
        uint256 gasBefore = gasleft();
        // token_ = USDC (6-decimal guard enforced in constructor), batchMinter_ = RatchetBatchNFTMinter.
        NudgeRatchet r = new NudgeRatchet(USDC, ratchetBatchNFTMinter, OWNER_ADDRESS);
        nudgeRatchet = address(r);
        _trackDeployment("NudgeRatchet", nudgeRatchet, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("NudgeRatchet deployed at:", nudgeRatchet);
    }

    // ========================================
    // Step 4: NudgeRatchet.setMinter(NFTMinterV2)
    // ========================================

    function _setRatchetMinter() internal {
        if (_isConfigured("ratchet_setMinter")) {
            console.log("NudgeRatchet.setMinter already configured");
            return;
        }
        require(nudgeRatchet != address(0), "NudgeRatchet must be deployed");
        uint256 gasBefore = gasleft();
        NudgeRatchet(nudgeRatchet).setMinter(NFT_MINTER_V2);
        console.log("NudgeRatchet.setMinter -> NFTMinterV2");
        _trackConfig("ratchet_setMinter", gasBefore - gasleft());
    }

    // ========================================
    // Step 5: Deploy NudgeRatchetMintDebtHook
    // ========================================

    function _deployHook() internal {
        if (_isDeployed("NudgeRatchetMintDebtHook")) {
            nudgeRatchetHook = deployments["NudgeRatchetMintDebtHook"].addr;
            console.log("NudgeRatchetMintDebtHook already deployed at:", nudgeRatchetHook);
            return;
        }
        require(nudgeRatchet != address(0), "NudgeRatchet must be deployed");
        uint256 gasBefore = gasleft();
        // Constructor seeds `dispatcher = nudgeRatchet`; no separate setDispatcher call needed
        // (matches DeployMocks.s.sol).
        NudgeRatchetMintDebtHook h = new NudgeRatchetMintDebtHook(OWNER_ADDRESS, nudgeRatchet, PHUSD);
        nudgeRatchetHook = address(h);
        _trackDeployment("NudgeRatchetMintDebtHook", nudgeRatchetHook, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("NudgeRatchetMintDebtHook deployed at:", nudgeRatchetHook);
    }

    // ========================================
    // Step 6: NudgeRatchet.setHook(hook)
    // ========================================

    function _setHookOnRatchet() internal {
        if (_isConfigured("ratchet_setHook")) {
            console.log("NudgeRatchet.setHook already configured");
            return;
        }
        require(nudgeRatchet != address(0), "NudgeRatchet must be deployed");
        require(nudgeRatchetHook != address(0), "Hook must be deployed");
        uint256 gasBefore = gasleft();
        NudgeRatchet(nudgeRatchet).setHook(IDispatchHook(nudgeRatchetHook));
        console.log("NudgeRatchet.setHook -> NudgeRatchetMintDebtHook");
        _trackConfig("ratchet_setHook", gasBefore - gasleft());
    }

    // ========================================
    // Step 7: phUSD.setMinter(hook, true)
    // ========================================

    function _authorizeHookAsMinter() internal {
        if (_isConfigured("phUSD_setMinter")) {
            console.log("phUSD.setMinter(hook, true) already configured");
            return;
        }
        require(nudgeRatchetHook != address(0), "Hook must be deployed");
        uint256 gasBefore = gasleft();
        FlaxToken(PHUSD).setMinter(nudgeRatchetHook, true);
        console.log("phUSD.setMinter(NudgeRatchetMintDebtHook, true)");
        _trackConfig("phUSD_setMinter", gasBefore - gasleft());
    }

    // ========================================
    // Step 8: NFTMinterV2.registerDispatcher
    // ========================================

    function _registerRatchetDispatcher() internal {
        if (_isConfigured("registerDispatcher")) {
            console.log("NFTMinterV2.registerDispatcher already configured");
            // Re-derive the index for downstream steps even on resume.
            ratchetIndex = NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(nudgeRatchet);
            console.log("  ratchet dispatcher index:", ratchetIndex);
            return;
        }
        require(nudgeRatchet != address(0), "NudgeRatchet must be deployed");
        // Hook MUST be fully wired before registration (else first dispatch reverts).
        require(nudgeRatchetHook != address(0), "Hook must be deployed before registration");

        uint256 gasBefore = gasleft();
        NFTMinterV2(NFT_MINTER_V2).registerDispatcher(nudgeRatchet, RATCHET_INITIAL_PRICE, RATCHET_GROWTH_BPS);
        console.log("NFTMinterV2.registerDispatcher(NudgeRatchet, 10 USDC, 1% growth)");

        ratchetIndex = NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(nudgeRatchet);
        console.log("  assigned dispatcher index:", ratchetIndex);
        require(ratchetIndex == EXPECTED_RATCHET_INDEX, "NudgeRatchet did not land at index 7");

        _trackConfig("registerDispatcher", gasBefore - gasleft());
    }

    // ========================================
    // Step 9: RatchetBatchNFTMinter.setDispatcherIndex
    // ========================================

    function _setBatchDispatcherIndex() internal {
        if (_isConfigured("batch_setDispatcherIndex")) {
            console.log("RatchetBatchNFTMinter.setDispatcherIndex already configured");
            return;
        }
        require(ratchetBatchNFTMinter != address(0), "RatchetBatchNFTMinter must be deployed");
        require(ratchetIndex != 0, "ratchet index not derived");
        uint256 gasBefore = gasleft();
        BatchNFTMinter(ratchetBatchNFTMinter).setDispatcherIndex(ratchetIndex);
        console.log("RatchetBatchNFTMinter.setDispatcherIndex ->", ratchetIndex);
        _trackConfig("batch_setDispatcherIndex", gasBefore - gasleft());
    }

    // ========================================
    // Step 10: Deploy NFTStakerPriceScaled
    // ========================================

    function _deployRatchetStaker() internal {
        if (_isDeployed("RatchetNFTStaker")) {
            ratchetNFTStaker = deployments["RatchetNFTStaker"].addr;
            console.log("RatchetNFTStaker already deployed at:", ratchetNFTStaker);
            return;
        }
        require(ratchetIndex != 0, "ratchet index not derived");
        uint256 gasBefore = gasleft();
        NFTStakerPriceScaled s = new NFTStakerPriceScaled(
            IERC1155(NFT_MINTER_V2),
            ratchetIndex,
            IERC20(PHUSD),
            OWNER_ADDRESS,
            INFTSupply(NFT_MINTER_V2),
            ratchetIndex,
            RATCHET_PRICE_SCALE
        );
        ratchetNFTStaker = address(s);
        _trackDeployment("RatchetNFTStaker", ratchetNFTStaker, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("RatchetNFTStaker deployed at:", ratchetNFTStaker);
    }

    // ========================================
    // Step 11: RatchetNFTStaker.setDispatcherHook
    // ========================================

    function _setDispatcherHookOnStaker() internal {
        if (_isConfigured("staker_setDispatcherHook")) {
            console.log("RatchetNFTStaker.setDispatcherHook already configured");
            return;
        }
        require(ratchetNFTStaker != address(0), "RatchetNFTStaker must be deployed");
        require(nudgeRatchetHook != address(0), "Hook must be deployed");
        uint256 gasBefore = gasleft();
        NFTStakerPriceScaled(ratchetNFTStaker).setDispatcherHook(IBalancerPoolerMintDebtHook(nudgeRatchetHook));
        console.log("RatchetNFTStaker.setDispatcherHook -> NudgeRatchetMintDebtHook");
        _trackConfig("staker_setDispatcherHook", gasBefore - gasleft());
    }

    // ========================================
    // Step 12: hook.setRecipient(RatchetNFTStaker)
    // ========================================

    function _setRecipientOnHook() internal {
        if (_isConfigured("hook_setRecipient")) {
            console.log("NudgeRatchetMintDebtHook.setRecipient already configured");
            return;
        }
        require(ratchetNFTStaker != address(0), "RatchetNFTStaker must be deployed");
        require(nudgeRatchetHook != address(0), "Hook must be deployed");
        uint256 gasBefore = gasleft();
        NudgeRatchetMintDebtHook(nudgeRatchetHook).setRecipient(ratchetNFTStaker);
        console.log("NudgeRatchetMintDebtHook.setRecipient -> RatchetNFTStaker");
        _trackConfig("hook_setRecipient", gasBefore - gasleft());
    }

    // ========================================
    // Step 13: RatchetNFTStaker.setTargetAPY
    // ========================================

    function _setTargetAPYOnStaker() internal {
        if (_isConfigured("staker_setTargetAPY")) {
            console.log("RatchetNFTStaker.setTargetAPY already configured");
            return;
        }
        require(ratchetNFTStaker != address(0), "RatchetNFTStaker must be deployed");
        uint256 gasBefore = gasleft();
        NFTStakerPriceScaled(ratchetNFTStaker).setTargetAPY(TARGET_APY);
        console.log("RatchetNFTStaker.setTargetAPY -> 0.45e18 (45%)");
        _trackConfig("staker_setTargetAPY", gasBefore - gasleft());
    }

    // ========================================
    // Step 14: RatchetBatchNFTMinter.setNudgePaymentToken(USDS)
    // ========================================

    function _setBatchNudgeToken() internal {
        if (_isConfigured("batch_setNudgePaymentToken")) {
            console.log("RatchetBatchNFTMinter.setNudgePaymentToken already configured");
            return;
        }
        require(ratchetBatchNFTMinter != address(0), "RatchetBatchNFTMinter must be deployed");
        uint256 gasBefore = gasleft();
        BatchNFTMinter(ratchetBatchNFTMinter).setNudgePaymentToken(RATCHET_NUDGE_TOKEN);
        console.log("RatchetBatchNFTMinter.setNudgePaymentToken -> USDS");
        _trackConfig("batch_setNudgePaymentToken", gasBefore - gasleft());
    }

    // ========================================
    // Step 15: RatchetBatchNFTMinter.setNudgeSize(40)
    // ========================================

    function _setBatchNudgeSize() internal {
        if (_isConfigured("batch_setNudgeSize")) {
            console.log("RatchetBatchNFTMinter.setNudgeSize already configured");
            return;
        }
        require(ratchetBatchNFTMinter != address(0), "RatchetBatchNFTMinter must be deployed");
        uint256 gasBefore = gasleft();
        BatchNFTMinter(ratchetBatchNFTMinter).setNudgeSize(RATCHET_NUDGE_SIZE);
        console.log("RatchetBatchNFTMinter.setNudgeSize ->", RATCHET_NUDGE_SIZE);
        _trackConfig("batch_setNudgeSize", gasBefore - gasleft());
    }

    // ========================================
    // Step 16: RatchetNFTStaker.setPauser + Pauser.register
    //
    // Only NFTStakerPriceScaled implements IPausable (setPauser/pauser()), so it is the
    // single ratchet-stack contract registrable with the global Pauser. NudgeRatchet
    // (ATokenDispatcherV2) and NudgeRatchetMintDebtHook do NOT implement pauser()/setPauser
    // — calling Pauser.register on them reverts ("contract may not implement pauser()").
    // The dispatcher's pause coverage routes through NFTMinterV2 (already registered with
    // the Pauser), exactly as the live BalancerPoolerV2 does (see DeployMainnetNudgePoolerV2
    // step 34 SKIPPED). The hook is not pausable and has no pause surface.
    // ========================================

    function _registerStakerWithPauser() internal {
        require(ratchetNFTStaker != address(0), "RatchetNFTStaker must be deployed");

        if (!_isConfigured("staker_setPauser")) {
            uint256 gasBefore = gasleft();
            NFTStakerPriceScaled(ratchetNFTStaker).setPauser(PAUSER);
            console.log("RatchetNFTStaker.setPauser -> Pauser");
            _trackConfig("staker_setPauser", gasBefore - gasleft());
        } else {
            console.log("RatchetNFTStaker.setPauser already configured");
        }

        if (!_isConfigured("pauser_register_staker")) {
            uint256 gasBefore = gasleft();
            Pauser(PAUSER).register(ratchetNFTStaker);
            console.log("Pauser.register(RatchetNFTStaker)");
            _trackConfig("pauser_register_staker", gasBefore - gasleft());
        } else {
            console.log("Pauser.register(RatchetNFTStaker) already configured");
        }

        console.log("Pauser: NudgeRatchet pauses via NFTMinterV2; hook has no pause surface (both skipped)");
    }

    // ========================================
    // Step 17: Deploy MintPageView
    // ========================================

    function _deployMintPageView() internal {
        if (_isDeployed("MintPageView")) {
            mintPageView = deployments["MintPageView"].addr;
            console.log("MintPageView already deployed at:", mintPageView);
            return;
        }
        uint256 gasBefore = gasleft();
        // 8-arg constructor, identical order to DeployMocks / RedeployMintPageViewV2.
        MintPageView mpv = new MintPageView(
            INFTMinter(NFT_MINTER_V2),
            BurnRecorder(BURN_RECORDER),
            EYE,
            SCX,
            FLAX,
            USDS,
            WBTC,
            USDC // NudgeRatchet prime token (dispatcher index 7)
        );
        mintPageView = address(mpv);
        _trackDeployment("MintPageView", mintPageView, gasBefore - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log("MintPageView deployed at:", mintPageView);
    }

    // ========================================
    // Step 18: ViewRouter.setPage('mint', MintPageView)
    // ========================================

    function _registerMintPageView() internal {
        if (_isConfigured("viewRouter_setPage")) {
            console.log("ViewRouter.setPage('mint') already configured");
            return;
        }
        require(mintPageView != address(0), "MintPageView must be deployed");
        bytes32 pageKey = keccak256("mint");
        uint256 gasBefore = gasleft();
        ViewRouter(VIEW_ROUTER).setPage(pageKey, IPageView(mintPageView));
        console.log("ViewRouter.setPage('mint') -> new MintPageView");
        _trackConfig("viewRouter_setPage", gasBefore - gasleft());
    }

    // ========================================
    // Post-broadcast verification (read-only)
    // ========================================

    function _verifyWiring() internal view {
        console.log("\n=== Verification ===");
        // NudgeRatchet at index 7.
        uint256 idx = NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(nudgeRatchet);
        require(idx == EXPECTED_RATCHET_INDEX, "verify: NudgeRatchet not at index 7");
        console.log("  NudgeRatchet dispatcher index == 7: OK");

        // MintPageView wired to V2 minter, and registered on the router.
        require(
            address(MintPageView(mintPageView).nftMinter()) == NFT_MINTER_V2, "verify: MintPageView.nftMinter != V2"
        );
        address registered = address(ViewRouter(VIEW_ROUTER).pages(keccak256("mint")));
        require(registered == mintPageView, "verify: ViewRouter 'mint' not updated");
        console.log("  MintPageView registered on ViewRouter under 'mint': OK");
    }

    // ========================================
    // Progress File Management
    // (mirrors DeployMainnetNFTStaking.s.sol)
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
        string[20] memory names = [
            "RatchetBatchNFTMinter",
            "NudgeRatchet",
            "NudgeRatchetMintDebtHook",
            "RatchetNFTStaker",
            "MintPageView",
            "batch_setTokenMinter",
            "ratchet_setMinter",
            "ratchet_setHook",
            "phUSD_setMinter",
            "registerDispatcher",
            "batch_setDispatcherIndex",
            "staker_setDispatcherHook",
            "hook_setRecipient",
            "staker_setTargetAPY",
            "batch_setNudgePaymentToken",
            "batch_setNudgeSize",
            "staker_setPauser",
            "pauser_register_staker",
            "viewRouter_setPage",
            ""
        ];
        for (uint256 i = 0; i < names.length; i++) {
            if (bytes(names[i]).length == 0) continue;
            _parseEntry(json, names[i]);
        }
        // Re-derive deployed addresses into the working fields.
        ratchetBatchNFTMinter = deployments["RatchetBatchNFTMinter"].addr;
        nudgeRatchet = deployments["NudgeRatchet"].addr;
        nudgeRatchetHook = deployments["NudgeRatchetMintDebtHook"].addr;
        ratchetNFTStaker = deployments["RatchetNFTStaker"].addr;
        mintPageView = deployments["MintPageView"].addr;
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
            name: name, addr: addr, deployed: true, configured: false, deployGas: gas, configGas: 0
        });
    }

    /// @dev Tracks a configuration-only step (no contract address) and writes the progress
    ///      file (skipped in preview). Mirrors the _trackDeployment + _markConfigured +
    ///      _writeProgressFile triple used per-step in DeployMainnetNFTStaking.s.sol.
    function _trackConfig(string memory name, uint256 gas) internal {
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
            name: name, addr: address(0), deployed: true, configured: true, deployGas: 0, configGas: gas
        });
        if (!isPreview) _writeProgressFile();
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
        console.log("    NUDGE RATCHET DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("RatchetBatchNFTMinter:    ", ratchetBatchNFTMinter);
        console.log("NudgeRatchet:             ", nudgeRatchet);
        console.log("NudgeRatchetMintDebtHook: ", nudgeRatchetHook);
        console.log("RatchetNFTStaker:         ", ratchetNFTStaker);
        console.log("MintPageView (new):       ", mintPageView);
        console.log("Dispatcher index:         ", ratchetIndex);
        console.log("");
        console.log("Wiring:");
        console.log("  NudgeRatchet.minter -> NFTMinterV2");
        console.log("  NudgeRatchet.hook   -> NudgeRatchetMintDebtHook");
        console.log("  phUSD authorizes hook as minter");
        console.log("  NudgeRatchet registered at index 7 (10 USDC, 1% growth)");
        console.log("  RatchetNFTStaker.hook -> hook; hook.recipient -> staker");
        console.log("  RatchetNFTStaker.targetAPY = 0.45e18 (45%); priceScale = 1e12");
        console.log("  RatchetBatchNFTMinter: minter+index+USDS nudge configured");
        console.log("  RatchetNFTStaker registered with Pauser");
        console.log("  MintPageView redeployed + registered on ViewRouter('mint')");
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
