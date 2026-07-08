// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@pauser/Pauser.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {Uniboost} from "@yield-claim-nft/dispatchers/Uniboost.sol";
import {UniboostMintDebtHook} from "@yield-claim-nft/hooks/UniboostMintDebtHook.sol";
import {IUniboostMintDebtHook} from "@yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {MultiPooler} from "@yield-claim-nft/MultiPooler.sol";
import {NudgeRatchetDelayRelease} from "@yield-claim-nft/dispatchers/NudgeRatchetDelayRelease.sol";
import {NudgeRatchetMintDebtHook} from "@yield-claim-nft/hooks/NudgeRatchetMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";
import {IBalancerPoolerMintDebtHook} from "@yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import {NFTStakerDepletion} from "nft-staking/NFTStakerDepletion.sol";
import {NFTStakerPriceScaled} from "nft-staking/NFTStakerPriceScaled.sol";
import {INFTSupply} from "nft-staking/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployMainnetUniboostCutover
 * @notice Single-broadcast mainnet differential deploy promoting Story 070's
 *         DeployMocks changes to mainnet. Two coordinated cutovers in one atomic
 *         Ledger session (mirrors how Story 069 promoted Story 068):
 *
 *           A. Replace the three live BurnerV2 dispatchers at NFTMinterV2 indices
 *              1/2/3 (EYE, SCX, FLX) with Uniboost dispatchers, each backed by a
 *              real, already-live UniV2 pool (EYE/WETH, SCX/WETH, FLX/WETH), a
 *              UniboostMintDebtHook, and an NFTStakerDepletion staker. A MultiPooler
 *              is deployed and wired as each Uniboost's ONLY authorized pooler, with
 *              the deployer as the MultiPooler's pooler.
 *
 *           B. Swap the index-7 dispatcher from the live plain NudgeRatchet to
 *              NudgeRatchetDelayRelease (deployer whitelisted as releaser), deploying
 *              a fresh NudgeRatchetMintDebtHook, re-pointing the existing
 *              RatchetNFTStaker, and decommissioning the old ratchet hook.
 *
 *         This is a LIVE-FUNDS, MID-FLIGHT change. All new contracts are deployed
 *         and fully wired BEFORE any replaceDispatcher, on-chain preconditions are
 *         asserted before every mutation, and the burner-slot pricing is RESET after
 *         each replaceDispatcher (see the CRITICAL note below).
 *
 *         ---- CRITICAL price/decimals loose-end (highest-risk detail) ----
 *         NFTMinterV2.replaceDispatcher repoints configs[index].dispatcher IN PLACE
 *         and does NOT reset price/growthBasisPoints. The live burner slots hold
 *         target-token-denominated 18-decimal prices (464.279e18 / 1.737e18 /
 *         22876.13e18) at 1000 bps. A USDC-primed Uniboost expects a 6-DECIMAL price.
 *         So after each replaceDispatcher(1/2/3) we MUST call setPrice(idx, 10e6) and
 *         setGrowthFactor(idx, 2). Index-7 price/growth (70e6 / 0) is left UNTOUCHED.
 *
 *         Growth factor = 2 bps for indices 1/2/3 (user override of the mock's 10 bps).
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *
 * Dry run (PREVIEW_MODE, no broadcast, no progress file written):
 *   PREVIEW_MODE=true forge script script/DeployMainnetUniboostCutover.s.sol:DeployMainnetUniboostCutover \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast (Ledger):
 *   forge script script/DeployMainnetUniboostCutover.s.sol:DeployMainnetUniboostCutover \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract DeployMainnetUniboostCutover is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    //   (from server/deployments/mainnet-addresses.ts, verified on-chain)
    // ==========================================

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant BURN_RECORDER = 0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F;

    // Index-4 LSP BatchNFTMinter — the Uniboost donation recipient AND the ratchet
    // release sink. RATCHET_SINK is READ from NudgeRatchet.batchMinter() at runtime and
    // asserted == this constant, rather than hardcoding RatchetBatchNFTMinter.
    address public constant BATCH_NFT_MINTER = 0x86866e01a115C17892Ed04c548F2e8638851029d;

    // Existing (reused) dedicated staker for the ratchet NFT — NFTStakerPriceScaled.
    address public constant RATCHET_NFT_STAKER = 0x299b0071DEf42D35eaf5ea24CC0a71Cf10655A64;

    // Live dispatcher lineup being replaced.
    address public constant BURNER_EYE = 0x13fb51BCb3C5Ae9E7115730BC1a58eC676CEeef2; // index 1
    address public constant BURNER_SCX = 0xA833603fD82674aeC51F8A57c6a27B91bC1725b2; // index 2
    address public constant BURNER_FLX = 0xb63b57025E9BeE5BBb66E4A5297eD0CA044d5Ff7; // index 3
    address public constant OLD_NUDGE_RATCHET = 0x7A4eD11160A06bB1C5b59091575d59707BE97a72; // index 7
    address public constant OLD_RATCHET_HOOK = 0xdCddB2F6548D5F1baC812110679E4c87e4BA9958; // decommission

    // Tokens.
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // prime, 6-decimal
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    address public constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Canonical UniV2 Router02 (Uniboost's swap router).
    address public constant ROUTER02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // Target pools (real, live on mainnet — verified getPair + reserves). Each pairs
    // against WETH, so Uniboost.pool()'s default [USDC, WETH] path resolves through the
    // deep canonical USDC/WETH pool. No pool creation/seeding on mainnet.
    address public constant POOL_EYE = 0x54965801946d768b395864019903aEF8B5b63BB3; // EYE/WETH
    address public constant POOL_SCX = 0x319eAd06eb01E808C80c7eb9bd77C5d8d163AddB; // SCX/WETH
    address public constant POOL_FLX = 0x6dF6B57FB7c35D7C71395F77cb08b82A62635e19; // FLX/WETH

    // ==========================================
    //         CONFIGURATION CONSTANTS
    //   Configuration Safety (CLAUDE.md): every value below is deliberately
    //   chosen and justified — none left at a zero/compiler default.
    // ==========================================

    /// @notice Uniboost NFT mint price: 10 USDC (USDC is 6-decimal). Story spec.
    uint256 public constant UNIBOOST_PRICE = 10 * 10 ** 6; // 10e6
    /// @notice Per-mint growth for the burner slots: 2 bps. Explicit user override of the
    ///         Story 070 mock's 10 bps (Concerns). A touch above BalancerPooler's 1 bps.
    uint256 public constant UNIBOOST_GROWTH_BPS = 2;
    /// @notice Uniboost donation split: 50% of each mint's USDC nudges the LSP batch minter;
    ///         the remaining 50% is retained by the Uniboost for pool(). Story 070 parity.
    uint256 public constant DONATION_SPLIT = 50;
    /// @notice NFTStakerDepletion depletion window = 12 months (one APY-year analogue).
    ///         Bounded 1..120; budget is refilled by the hook's pull() on dispatch. Non-default.
    uint256 public constant DEPLETION_WINDOW_MONTHS = 12;

    // Expected dispatcher indices (asserted against configs()).
    uint256 public constant EYE_INDEX = 1;
    uint256 public constant SCX_INDEX = 2;
    uint256 public constant FLX_INDEX = 3;
    uint256 public constant RATCHET_INDEX = 7;

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    address public uniboostEYE;
    address public uniboostSCX;
    address public uniboostFLX;
    address public uniboostHookEYE;
    address public uniboostHookSCX;
    address public uniboostHookFLX;
    address public multiPooler;
    address public uniboostStakerEYE;
    address public uniboostStakerSCX;
    address public uniboostStakerFLX;
    address public newRatchet; // NudgeRatchetDelayRelease
    address public newRatchetHook; // NudgeRatchetMintDebtHook

    // RATCHET_SINK read from the OLD NudgeRatchet at runtime (verified == BATCH_NFT_MINTER).
    address public ratchetSink;

    // Progress tracking (mirrors DeployMainnetNudgeRatchet.s.sol).
    string constant PROGRESS_FILE = "server/deployments/progress.uniboost-cutover.1.json";
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

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "Wrong chain id - expected Mainnet (1)");
    }

    function run() external {
        console.log("=========================================");
        console.log("  MAINNET UNIBOOST CUTOVER (story 071)");
        console.log("=========================================");
        console.log("Chain ID:            ", block.chainid);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("Owner (ledger):      ", OWNER_ADDRESS);
        console.log("NFTMinterV2:         ", NFT_MINTER_V2);
        console.log("phUSD (FlaxToken):   ", PHUSD);
        console.log("USDC (prime, 6dp):   ", USDC);
        console.log("--- CONFIG ---");
        console.log("Uniboost price (USDC):", UNIBOOST_PRICE);
        console.log("Uniboost growth (bps):", UNIBOOST_GROWTH_BPS);
        console.log("Donation split:       ", DONATION_SPLIT);
        console.log("Depletion window (mo):", DEPLETION_WINDOW_MONTHS);
        console.log("----------------------------------------------------");

        // Configuration Safety guards — refuse to broadcast with unsafe defaults.
        require(UNIBOOST_PRICE == 10 * 10 ** 6, "uniboost price must be 10 USDC (6dp)");
        require(UNIBOOST_GROWTH_BPS == 2, "uniboost growth must be 2 bps (user override)");
        require(DONATION_SPLIT > 0 && DONATION_SPLIT <= 100, "donation split out of range");
        require(DEPLETION_WINDOW_MONTHS >= 1 && DEPLETION_WINDOW_MONTHS <= 120, "depletion window out of range");
        require(USDC != address(0) && PHUSD != address(0) && OWNER_ADDRESS != address(0), "core address unset");

        _loadProgressFile();

        isPreview = vm.envOr("PREVIEW_MODE", false);

        // ====== Phase 0: Preconditions (no mutation, no broadcast) ======
        _phase0_preconditions();

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating owner (no signing) ***");
            console.log("*** Progress file will NOT be written ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // ====== Phase 1: Deploy + wire ALL new contracts (before any replaceDispatcher) ======
        _phase1_deployUniboostStack();

        // ====== Phase 2: Swap indices 1/2/3 + RESET pricing (MANDATORY) ======
        _phase2_swapBurners();

        // ====== Phase 3: Uniboost donation config + stakers (index resolvable now) ======
        _phase3_donationAndStakers();

        // ====== Phase 4: Index-7 ratchet swap (drain-first) ======
        _phase4_ratchetSwap();

        // ====== Phase 5: Optional cleanup (revoke defunct burn authorizations) ======
        _phase5_cleanup();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // Post-mutation verification (read-only; safe in both modes).
        _verifyFinalState();

        // ====== Phase 6: progress file + summary ======
        if (!isPreview) {
            _markDeploymentComplete();
        } else {
            console.log("");
            console.log("PREVIEW: no progress file written (by design).");
        }
        _printSummary();
    }

    // =====================================================================
    // Phase 0 — Preconditions
    // =====================================================================

    function _phase0_preconditions() internal {
        console.log("\n=== Phase 0: Preconditions (require-gated, no mutation) ===");

        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        // Owners.
        require(minter.owner() == OWNER_ADDRESS, "NFTMinterV2.owner != OWNER");
        require(
            NFTStakerPriceScaled(RATCHET_NFT_STAKER).owner() == OWNER_ADDRESS,
            "RatchetNFTStaker.owner != OWNER (pullAndRefresh/setDispatcherHook would revert)"
        );
        require(IFlaxMinimal(PHUSD).owner() == OWNER_ADDRESS, "phUSD.owner != OWNER (setMinter would revert)");
        console.log("Owners OK (NFTMinterV2, RatchetNFTStaker, phUSD all == OWNER)");

        // Current dispatchers at the slots we mutate.
        (address d1,,,) = minter.configs(EYE_INDEX);
        (address d2,,,) = minter.configs(SCX_INDEX);
        (address d3,,,) = minter.configs(FLX_INDEX);
        (address d7,,,) = minter.configs(RATCHET_INDEX);
        require(d1 == BURNER_EYE, "configs(1).dispatcher != live BurnerV2 (EYE)");
        require(d2 == BURNER_SCX, "configs(2).dispatcher != live BurnerV2 (SCX)");
        require(d3 == BURNER_FLX, "configs(3).dispatcher != live BurnerV2 (FLX)");
        require(d7 == OLD_NUDGE_RATCHET, "configs(7).dispatcher != live NudgeRatchet");
        console.log("configs(1/2/3) == live burners; configs(7) == live NudgeRatchet: OK");

        // Read RATCHET_SINK from the OLD ratchet, assert == index-4 BatchNFTMinter.
        ratchetSink = INudgeRatchetLike(OLD_NUDGE_RATCHET).batchMinter();
        require(ratchetSink != address(0), "OLD NudgeRatchet.batchMinter() == 0");
        require(ratchetSink == BATCH_NFT_MINTER, "RATCHET_SINK != index-4 BatchNFTMinter (0x86866e..)");
        console.log("RATCHET_SINK (NudgeRatchet.batchMinter()):", ratchetSink);

        // Target-pool sanity: pair exists, target token is a pool token, reserves > 0.
        _assertPoolSane(POOL_EYE, EYE, "EYE/WETH");
        _assertPoolSane(POOL_SCX, SCX, "SCX/WETH");
        _assertPoolSane(POOL_FLX, FLX, "FLX/WETH");
        console.log("All three target pools sane (target token present, reserves > 0)");
    }

    function _assertPoolSane(address pool, address targetToken, string memory label) internal view {
        require(pool.code.length > 0, string.concat(label, ": pool has no code"));
        address t0 = IUniV2PairLike(pool).token0();
        address t1 = IUniV2PairLike(pool).token1();
        require(targetToken == t0 || targetToken == t1, string.concat(label, ": target token not in pool"));
        (uint112 r0, uint112 r1,) = IUniV2PairLike(pool).getReserves();
        require(r0 > 0 && r1 > 0, string.concat(label, ": pool reserves are zero"));
    }

    // =====================================================================
    // Phase 1 — Deploy + wire the Uniboost stack (before any replaceDispatcher)
    // =====================================================================

    function _phase1_deployUniboostStack() internal {
        console.log("\n=== Phase 1: Deploy + wire Uniboost stack ===");

        // Per token: deploy Uniboost -> setMinter -> deploy hook -> setHook ->
        // phUSD.setMinter(hook, true). MultiPooler auth is applied after MultiPooler exists.
        (uniboostEYE, uniboostHookEYE) = _deployUniboostAndHook("UniboostEYE", "UniboostHookEYE", POOL_EYE, EYE);
        (uniboostSCX, uniboostHookSCX) = _deployUniboostAndHook("UniboostSCX", "UniboostHookSCX", POOL_SCX, SCX);
        (uniboostFLX, uniboostHookFLX) = _deployUniboostAndHook("UniboostFLX", "UniboostHookFLX", POOL_FLX, FLX);

        // Deploy MultiPooler, set the deployer/OWNER as its pooler.
        if (_isDeployed("MultiPooler")) {
            multiPooler = deployments["MultiPooler"].addr;
            console.log("MultiPooler already deployed at:", multiPooler);
        } else {
            uint256 g = gasleft();
            MultiPooler mp = new MultiPooler(OWNER_ADDRESS);
            multiPooler = address(mp);
            _trackDeployment("MultiPooler", multiPooler, g - gasleft());
            if (!isPreview) _writeProgressFile();
            console.log("MultiPooler deployed at:", multiPooler);
        }
        if (!_isConfigured("multiPooler_setPooler")) {
            MultiPooler(multiPooler).setPooler(OWNER_ADDRESS);
            console.log("MultiPooler.setPooler -> OWNER (deployer is the batch caller)");
            _trackConfig("multiPooler_setPooler");
        }

        // Authorize the MultiPooler as the ONLY pooler on each Uniboost (deployer NOT whitelisted).
        _authorizePooler("UniboostEYE", uniboostEYE);
        _authorizePooler("UniboostSCX", uniboostSCX);
        _authorizePooler("UniboostFLX", uniboostFLX);
    }

    function _deployUniboostAndHook(
        string memory ubName,
        string memory hookName,
        address targetPool,
        address targetToken
    ) internal returns (address ub, address hook) {
        // Uniboost.
        if (_isDeployed(ubName)) {
            ub = deployments[ubName].addr;
            console.log(string.concat(ubName, " already deployed at:"), ub);
        } else {
            uint256 g = gasleft();
            Uniboost u = new Uniboost(USDC, ROUTER02, targetPool, targetToken, OWNER_ADDRESS);
            ub = address(u);
            _trackDeployment(ubName, ub, g - gasleft());
            if (!isPreview) _writeProgressFile();
            console.log(string.concat(ubName, " deployed at:"), ub);
        }
        if (!_isConfigured(string.concat(ubName, "_setMinter"))) {
            Uniboost(ub).setMinter(NFT_MINTER_V2);
            console.log(string.concat(ubName, ".setMinter -> NFTMinterV2"));
            _trackConfig(string.concat(ubName, "_setMinter"));
        }

        // Hook.
        if (_isDeployed(hookName)) {
            hook = deployments[hookName].addr;
            console.log(string.concat(hookName, " already deployed at:"), hook);
        } else {
            uint256 g = gasleft();
            // UniboostMintDebtHook(initialOwner, dispatcher_, phUSD_, primeToken_)
            UniboostMintDebtHook h = new UniboostMintDebtHook(OWNER_ADDRESS, ub, PHUSD, USDC);
            hook = address(h);
            _trackDeployment(hookName, hook, g - gasleft());
            if (!isPreview) _writeProgressFile();
            console.log(string.concat(hookName, " deployed at:"), hook);
        }
        if (!_isConfigured(string.concat(ubName, "_setHook"))) {
            Uniboost(ub).setHook(IDispatchHook(hook));
            console.log(string.concat(ubName, ".setHook -> ", hookName));
            _trackConfig(string.concat(ubName, "_setHook"));
        }
        if (!_isConfigured(string.concat(hookName, "_phUSDMinter"))) {
            IFlaxMinimal(PHUSD).setMinter(hook, true);
            console.log(string.concat("phUSD.setMinter(", hookName, ", true)"));
            _trackConfig(string.concat(hookName, "_phUSDMinter"));
        }
    }

    function _authorizePooler(string memory ubName, address ub) internal {
        if (_isConfigured(string.concat(ubName, "_authPooler"))) {
            return;
        }
        Uniboost(ub).setAuthorizedPooler(multiPooler, true);
        console.log(string.concat(ubName, ".setAuthorizedPooler(MultiPooler, true)"));
        _trackConfig(string.concat(ubName, "_authPooler"));
    }

    // =====================================================================
    // Phase 2 — replaceDispatcher(1/2/3) + MANDATORY price/growth reset
    // =====================================================================

    function _phase2_swapBurners() internal {
        console.log("\n=== Phase 2: replaceDispatcher(1/2/3) + RESET price/growth ===");
        _swapBurner(EYE_INDEX, uniboostEYE, "UniboostEYE");
        _swapBurner(SCX_INDEX, uniboostSCX, "UniboostSCX");
        _swapBurner(FLX_INDEX, uniboostFLX, "UniboostFLX");
    }

    function _swapBurner(uint256 idx, address uniboost, string memory label) internal {
        string memory key = string.concat("phase2_swap_", vm.toString(idx));
        if (_isConfigured(key)) {
            console.log(string.concat(label, ": already swapped"));
            return;
        }
        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        minter.replaceDispatcher(idx, uniboost);
        console.log(string.concat(label, ": replaceDispatcher(idx, uniboost) idx="), idx);

        // MANDATORY: replaceDispatcher preserves the burners' 18-decimal price. Reset to
        // 10 USDC (6-decimal) + 2 bps growth so USDC-primed mints price correctly.
        minter.setPrice(idx, UNIBOOST_PRICE);
        minter.setGrowthFactor(idx, UNIBOOST_GROWTH_BPS);
        console.log("  setPrice(idx, 10e6) + setGrowthFactor(idx, 2): OK");

        (address d, uint256 price, uint256 growth,) = minter.configs(idx);
        require(d == uniboost, "post: configs(idx).dispatcher != uniboost");
        require(price == UNIBOOST_PRICE, "post: configs(idx).price != 10e6");
        require(growth == UNIBOOST_GROWTH_BPS, "post: configs(idx).growth != 2");
        console.log("  post-condition invariants hold (dispatcher/price/growth)");

        _trackConfig(key);
    }

    // =====================================================================
    // Phase 3 — Uniboost donation config + NFTStakerDepletion stakers
    // =====================================================================

    function _phase3_donationAndStakers() internal {
        console.log("\n=== Phase 3: Uniboost donation config + stakers ===");
        uniboostStakerEYE =
            _finalizeUniboost(EYE_INDEX, uniboostEYE, uniboostHookEYE, "UniboostEYE", "UniboostStakerEYE");
        uniboostStakerSCX =
            _finalizeUniboost(SCX_INDEX, uniboostSCX, uniboostHookSCX, "UniboostSCX", "UniboostStakerSCX");
        uniboostStakerFLX =
            _finalizeUniboost(FLX_INDEX, uniboostFLX, uniboostHookFLX, "UniboostFLX", "UniboostStakerFLX");
    }

    function _finalizeUniboost(
        uint256 expectedIdx,
        address uniboost,
        address hook,
        string memory ubLabel,
        string memory stakerName
    ) internal returns (address staker) {
        // Donation config (recipient = index-4 LSP BatchNFTMinter; split = 50%).
        if (!_isConfigured(string.concat(ubLabel, "_donation"))) {
            Uniboost(uniboost).setRecipient(BATCH_NFT_MINTER);
            Uniboost(uniboost).setDonationSplit(DONATION_SPLIT);
            console.log(string.concat(ubLabel, ".setRecipient(BatchNFTMinter) + setDonationSplit(50)"));
            _trackConfig(string.concat(ubLabel, "_donation"));
        }

        // Resolve the on-chain index (== expectedIdx) for the staker's stakedId/dispatcherIndex.
        uint256 idx = NFTMinterV2(NFT_MINTER_V2).dispatcherToIndex(uniboost);
        require(idx == expectedIdx, "staker: uniboost index mismatch");

        // Deploy + wire the staker (NFTStakerDepletion). Guarded as a unit by _isDeployed.
        if (_isDeployed(stakerName)) {
            staker = deployments[stakerName].addr;
            console.log(string.concat(stakerName, " already deployed at:"), staker);
            return staker;
        }
        uint256 g = gasleft();
        NFTStakerDepletion s = new NFTStakerDepletion(
            IERC1155(NFT_MINTER_V2), idx, IERC20(PHUSD), OWNER_ADDRESS, INFTSupply(NFT_MINTER_V2), idx
        );
        staker = address(s);
        _trackDeployment(stakerName, staker, g - gasleft());
        if (!isPreview) _writeProgressFile();
        console.log(string.concat(stakerName, " deployed at:"), staker);

        // Wire: staker.dispatcherHook -> hook; hook.recipient -> staker; depletion window; Pauser.
        s.setDispatcherHook(IUniboostMintDebtHook(hook));
        UniboostMintDebtHook(hook).setRecipient(staker);
        s.setDepletionWindow(DEPLETION_WINDOW_MONTHS);
        s.setPauser(PAUSER);
        Pauser(PAUSER).register(staker);
        console.log(string.concat(stakerName, ": hook wired, window=12mo, Pauser registered"));
    }

    // =====================================================================
    // Phase 4 — Index-7 ratchet swap (drain-first)
    // =====================================================================

    function _phase4_ratchetSwap() internal {
        console.log("\n=== Phase 4: Index-7 ratchet swap (drain-first) ===");

        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        // (drain) settle accrued mint-debt through the OLD hook before repointing.
        if (!_isConfigured("phase4_drain")) {
            NFTStakerPriceScaled(RATCHET_NFT_STAKER).pullAndRefresh();
            uint256 postDebt = IMintDebtLike(OLD_RATCHET_HOOK).mintDebt();
            console.log("OLD ratchet hook mintDebt() after pullAndRefresh:", postDebt);
            require(postDebt == 0, "OLD ratchet hook mintDebt != 0 after pullAndRefresh");
            _trackConfig("phase4_drain");
        }

        // Deploy NudgeRatchetDelayRelease (tracked under the "NudgeRatchet" TS key).
        if (_isDeployed("NudgeRatchet")) {
            newRatchet = deployments["NudgeRatchet"].addr;
            console.log("NudgeRatchetDelayRelease already deployed at:", newRatchet);
        } else {
            uint256 g = gasleft();
            NudgeRatchetDelayRelease r = new NudgeRatchetDelayRelease(USDC, ratchetSink, OWNER_ADDRESS);
            newRatchet = address(r);
            _trackDeployment("NudgeRatchet", newRatchet, g - gasleft());
            if (!isPreview) _writeProgressFile();
            console.log("NudgeRatchetDelayRelease deployed at:", newRatchet);
        }
        if (!_isConfigured("newRatchet_setMinter")) {
            NudgeRatchetDelayRelease(newRatchet).setMinter(NFT_MINTER_V2);
            console.log("NudgeRatchetDelayRelease.setMinter -> NFTMinterV2");
            _trackConfig("newRatchet_setMinter");
        }
        if (!_isConfigured("newRatchet_setReleaser")) {
            NudgeRatchetDelayRelease(newRatchet).setReleaser(OWNER_ADDRESS, true);
            console.log("NudgeRatchetDelayRelease.setReleaser(OWNER, true)");
            _trackConfig("newRatchet_setReleaser");
        }

        // Deploy the matching NudgeRatchetMintDebtHook (dispatcher is a constructor arg —
        // a NEW hook is mandatory per new dispatcher).
        if (_isDeployed("NudgeRatchetMintDebtHook")) {
            newRatchetHook = deployments["NudgeRatchetMintDebtHook"].addr;
            console.log("NudgeRatchetMintDebtHook already deployed at:", newRatchetHook);
        } else {
            uint256 g = gasleft();
            NudgeRatchetMintDebtHook h = new NudgeRatchetMintDebtHook(OWNER_ADDRESS, newRatchet, PHUSD);
            newRatchetHook = address(h);
            _trackDeployment("NudgeRatchetMintDebtHook", newRatchetHook, g - gasleft());
            if (!isPreview) _writeProgressFile();
            console.log("NudgeRatchetMintDebtHook deployed at:", newRatchetHook);
        }
        if (!_isConfigured("newRatchet_setHook")) {
            NudgeRatchetDelayRelease(newRatchet).setHook(IDispatchHook(newRatchetHook));
            console.log("NudgeRatchetDelayRelease.setHook -> new NudgeRatchetMintDebtHook");
            _trackConfig("newRatchet_setHook");
        }
        if (!_isConfigured("newRatchetHook_phUSDMinter")) {
            IFlaxMinimal(PHUSD).setMinter(newRatchetHook, true);
            console.log("phUSD.setMinter(new ratchet hook, true)");
            _trackConfig("newRatchetHook_phUSDMinter");
        }

        // Swap the dispatcher at index 7 — do NOT reset price/growth (keep 70e6 / 0).
        if (!_isConfigured("phase4_replace7")) {
            minter.replaceDispatcher(RATCHET_INDEX, newRatchet);
            (address d7,,,) = minter.configs(RATCHET_INDEX);
            require(d7 == newRatchet, "post: configs(7).dispatcher != newRatchet");
            console.log("replaceDispatcher(7, newRatchet): OK (price/growth untouched)");
            _trackConfig("phase4_replace7");
        }

        // Repoint the existing staker to the new hook; point the hook at the staker.
        if (!_isConfigured("phase4_repointStaker")) {
            NFTStakerPriceScaled(RATCHET_NFT_STAKER).setDispatcherHook(IBalancerPoolerMintDebtHook(newRatchetHook));
            NudgeRatchetMintDebtHook(newRatchetHook).setRecipient(RATCHET_NFT_STAKER);
            require(
                address(NFTStakerPriceScaled(RATCHET_NFT_STAKER).dispatcherHook()) == newRatchetHook,
                "post: RatchetNFTStaker.dispatcherHook != newRatchetHook"
            );
            console.log("RatchetNFTStaker.setDispatcherHook(new) + newHook.setRecipient(staker): OK");
            _trackConfig("phase4_repointStaker");
        }

        // Decommission the old ratchet hook as a phUSD minter.
        if (!_isConfigured("phase4_decommissionOldHook")) {
            IFlaxMinimal(PHUSD).setMinter(OLD_RATCHET_HOOK, false);
            console.log("phUSD.setMinter(OLD ratchet hook, false): decommissioned");
            _trackConfig("phase4_decommissionOldHook");
        }
    }

    // =====================================================================
    // Phase 5 — Optional cleanup (revoke defunct burn authorizations)
    // =====================================================================

    function _phase5_cleanup() internal {
        console.log("\n=== Phase 5: Optional cleanup (revoke old burner authorizations) ===");
        if (_isConfigured("phase5_cleanup")) {
            console.log("cleanup already done");
            return;
        }
        // The outgoing BurnerV2s burn on receipt, so they should hold ~0 target tokens and
        // the outgoing NudgeRatchet holds no stranded USDC. Revoke burn authorizations so the
        // retired burners can no longer record burns. Low value, deploy-safe.
        BurnRecorder(BURN_RECORDER).setBurner(BURNER_EYE, false);
        BurnRecorder(BURN_RECORDER).setBurner(BURNER_SCX, false);
        BurnRecorder(BURN_RECORDER).setBurner(BURNER_FLX, false);
        console.log("BurnRecorder.setBurner(oldBurner, false) x3");

        uint256 rEye = IERC20(EYE).balanceOf(BURNER_EYE);
        uint256 rScx = IERC20(SCX).balanceOf(BURNER_SCX);
        uint256 rFlx = IERC20(FLX).balanceOf(BURNER_FLX);
        uint256 stranded = IERC20(USDC).balanceOf(OLD_NUDGE_RATCHET);
        console.log("outgoing burner target balances (EYE/SCX/FLX):", rEye, rScx, rFlx);
        console.log("outgoing NudgeRatchet stranded USDC:", stranded);

        _trackConfig("phase5_cleanup");
    }

    // =====================================================================
    // Final verification (read-only)
    // =====================================================================

    function _verifyFinalState() internal view {
        console.log("\n=== Verification (read-only) ===");
        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        (address d1, uint256 p1, uint256 g1,) = minter.configs(EYE_INDEX);
        (address d2, uint256 p2, uint256 g2,) = minter.configs(SCX_INDEX);
        (address d3, uint256 p3, uint256 g3,) = minter.configs(FLX_INDEX);
        (address d7,,,) = minter.configs(RATCHET_INDEX);

        require(d1 == uniboostEYE && p1 == UNIBOOST_PRICE && g1 == UNIBOOST_GROWTH_BPS, "verify: index 1 wrong");
        require(d2 == uniboostSCX && p2 == UNIBOOST_PRICE && g2 == UNIBOOST_GROWTH_BPS, "verify: index 2 wrong");
        require(d3 == uniboostFLX && p3 == UNIBOOST_PRICE && g3 == UNIBOOST_GROWTH_BPS, "verify: index 3 wrong");
        require(d7 == newRatchet, "verify: index 7 != newRatchet");
        console.log("  indices 1/2/3 -> Uniboost @ 10e6 / 2 bps; index 7 -> NudgeRatchetDelayRelease: OK");

        require(
            address(NFTStakerPriceScaled(RATCHET_NFT_STAKER).dispatcherHook()) == newRatchetHook,
            "verify: RatchetNFTStaker hook != new"
        );
        console.log("  RatchetNFTStaker.dispatcherHook == new hook: OK");
    }

    // =====================================================================
    // Progress File Management (mirrors DeployMainnetNudgeRatchet.s.sol)
    // =====================================================================

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
        // Deployed contracts (addresses re-derived into working fields below).
        string[12] memory deployNames = [
            "UniboostEYE",
            "UniboostSCX",
            "UniboostFLX",
            "UniboostHookEYE",
            "UniboostHookSCX",
            "UniboostHookFLX",
            "MultiPooler",
            "UniboostStakerEYE",
            "UniboostStakerSCX",
            "UniboostStakerFLX",
            "NudgeRatchet",
            "NudgeRatchetMintDebtHook"
        ];
        for (uint256 i = 0; i < deployNames.length; i++) {
            _parseEntry(json, deployNames[i]);
        }

        // Config-only step flags.
        string[26] memory cfgNames = [
            "UniboostEYE_setMinter",
            "UniboostSCX_setMinter",
            "UniboostFLX_setMinter",
            "UniboostEYE_setHook",
            "UniboostSCX_setHook",
            "UniboostFLX_setHook",
            "UniboostHookEYE_phUSDMinter",
            "UniboostHookSCX_phUSDMinter",
            "UniboostHookFLX_phUSDMinter",
            "multiPooler_setPooler",
            "UniboostEYE_authPooler",
            "UniboostSCX_authPooler",
            "UniboostFLX_authPooler",
            "phase2_swap_1",
            "phase2_swap_2",
            "phase2_swap_3",
            "UniboostEYE_donation",
            "UniboostSCX_donation",
            "UniboostFLX_donation",
            "phase4_drain",
            "newRatchet_setMinter",
            "newRatchet_setReleaser",
            "newRatchet_setHook",
            "newRatchetHook_phUSDMinter",
            "phase4_replace7",
            "phase4_repointStaker"
        ];
        for (uint256 i = 0; i < cfgNames.length; i++) {
            _parseEntry(json, cfgNames[i]);
        }
        // Trailing config flags not fitting the 26-slot array.
        _parseEntry(json, "phase4_decommissionOldHook");
        _parseEntry(json, "phase5_cleanup");

        // Re-derive deployed addresses into working fields.
        uniboostEYE = deployments["UniboostEYE"].addr;
        uniboostSCX = deployments["UniboostSCX"].addr;
        uniboostFLX = deployments["UniboostFLX"].addr;
        uniboostHookEYE = deployments["UniboostHookEYE"].addr;
        uniboostHookSCX = deployments["UniboostHookSCX"].addr;
        uniboostHookFLX = deployments["UniboostHookFLX"].addr;
        multiPooler = deployments["MultiPooler"].addr;
        uniboostStakerEYE = deployments["UniboostStakerEYE"].addr;
        uniboostStakerSCX = deployments["UniboostStakerSCX"].addr;
        uniboostStakerFLX = deployments["UniboostStakerFLX"].addr;
        newRatchet = deployments["NudgeRatchet"].addr;
        newRatchetHook = deployments["NudgeRatchetMintDebtHook"].addr;
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
            try vm.parseJsonUint(json, string.concat(".contracts.", name, ".deployGas")) returns (uint256 gg) {
                deployGas = gg;
            } catch {}
            uint256 configGas;
            try vm.parseJsonUint(json, string.concat(".contracts.", name, ".configGas")) returns (uint256 gg) {
                configGas = gg;
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
        _pushNameIfNew(name);
        deployments[name] = ContractDeployment({
            name: name, addr: addr, deployed: true, configured: false, deployGas: gas, configGas: 0
        });
    }

    /// @dev Tracks a config-only step (no contract address) and writes progress (skip in preview).
    function _trackConfig(string memory name) internal {
        _pushNameIfNew(name);
        deployments[name] = ContractDeployment({
            name: name, addr: address(0), deployed: true, configured: true, deployGas: 0, configGas: 0
        });
        if (!isPreview) _writeProgressFile();
    }

    function _pushNameIfNew(string memory name) internal {
        for (uint256 i = 0; i < contractNames.length; i++) {
            if (keccak256(bytes(contractNames[i])) == keccak256(bytes(name))) return;
        }
        contractNames.push(name);
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

    // =====================================================================
    // Summary
    // =====================================================================

    function _printSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("     UNIBOOST CUTOVER SUMMARY");
        console.log("=========================================");
        console.log("UniboostEYE:             ", uniboostEYE);
        console.log("UniboostSCX:             ", uniboostSCX);
        console.log("UniboostFLX:             ", uniboostFLX);
        console.log("UniboostHookEYE:         ", uniboostHookEYE);
        console.log("UniboostHookSCX:         ", uniboostHookSCX);
        console.log("UniboostHookFLX:         ", uniboostHookFLX);
        console.log("MultiPooler:             ", multiPooler);
        console.log("UniboostStakerEYE:       ", uniboostStakerEYE);
        console.log("UniboostStakerSCX:       ", uniboostStakerSCX);
        console.log("UniboostStakerFLX:       ", uniboostStakerFLX);
        console.log("NudgeRatchetDelayRelease:", newRatchet);
        console.log("NudgeRatchetMintDebtHook:", newRatchetHook);
        console.log("RATCHET_SINK (reused):   ", ratchetSink);
        console.log("=========================================");
    }
}

// ==========================================
//   MINIMAL EXTERNAL TYPE INTERFACES
// ==========================================

/// @dev IFlax surface used here: phUSD implements setMinter(address,bool) + owner().
interface IFlaxMinimal {
    function setMinter(address minter, bool canMint) external;
    function owner() external view returns (address);
}

/// @dev Read-only surface of the OLD NudgeRatchet to source the release sink.
interface INudgeRatchetLike {
    function batchMinter() external view returns (address);
}

/// @dev mintDebt() getter shared by the mint-debt hooks (drain verification).
interface IMintDebtLike {
    function mintDebt() external view returns (uint256);
}

/// @dev Minimal UniV2 pair surface for pool preconditions.
interface IUniV2PairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}
