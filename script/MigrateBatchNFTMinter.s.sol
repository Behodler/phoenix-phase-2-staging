// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// [story-057] Migrate the BatchNFTMinter to the self-refund-fixed instance (nft-staking 5f863d2,
// "snapshot nudge pot before mint loop"). Deploy a new (fixed) BatchNFTMinter, configure it
// identically to the live one, repoint the two real funders (SYA nudge + Sky-route
// BalancerPoolerV2 batchMinter), drain the old instance's residual USDC into the new pot
// (plain rescueERC20 — NO BPT exit/swap dance), restore the pooler batchDonationSize to 15%
// (zeroed as the interim bleed-stop; owner raised the operating value 10% -> 15% on 2026-06-10),
// and retire the old contract. Then pre-fill the StableStaker set-aside buffers: sell 100 phUSD
// for sUSDS on the canonical Balancer V3 pool, unwrap to USDS, split into equal thirds, convert
// each third to USDC via the Sky PSM, swap two of them on Curve into USDe and DOLA, and deliver
// all three to the StableStaker (idle balance == the underwater-withdraw buffer). Single
// owner-signed broadcast, PREVIEW_MODE-aware fork dry-run. Primary template:
// script/ReplaceBatchNFTMinter.s.sol (story 050); donation-restore pattern:
// script/SetBatchDonationSizeIndex4.s.sol (retargeted to the live Sky pooler); atomic
// swap-chain pattern: script/MintSellAndDonateToBatchMinter.s.sol (helper executes the whole
// amount-dependent chain in ONE tx so no simulated output is ever baked into later calldata).

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFlax} from "@flax-token/IFlax.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {ITokenMinterV2} from "@yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";
import {ISkyPSM} from "@yield-claim-nft/V2/interfaces/ISkyPSM.sol";

/**
 * @title MigrateBatchNFTMinter
 * @notice One-shot mainnet migration (story 057 / self-refund-fix-and-migration-plan §6): deploys
 *         the self-refund-fixed BatchNFTMinter (nft-staking 5f863d2 snapshots the nudge pot BEFORE
 *         the mint loop, so a 40-batcher receives only the PRIOR pot and their own per-mint
 *         donations seed the next claimant), repoints its two real funders, seeds the new USDC
 *         nudge pot by draining the old instance (rescueERC20), restores the Sky-route pooler's
 *         batchDonationSize to 15% (owner directive 2026-06-10), neutralizes the old (buggy)
 *         contract, and pre-fills the StableStaker's set-aside buffers with USDC / USDe / DOLA
 *         sourced from 100 phUSD (sold for sUSDS on Balancer, unwrapped to USDS, split in thirds,
 *         converted via Sky PSM + Curve).
 *
 * Flow (single owner-signed broadcast; order matters):
 *   1. Pre-flight snapshot (old USDC balance, pooler.batchMinter, SYA.nudge, pooler.batchDonationSize).
 *   2. Deploy new BatchNFTMinter(OWNER).
 *   3. Configure (minter first): setTokenMinter -> setDispatcherIndex(4) -> setNudgePaymentToken(USDC)
 *                 -> setNudgeSize(40) -> (optional) setPauser (default: leave 0, matching current).
 *   4. Guards (config invariants) before any funds/pointers move.
 *   5. Repoint funders: SYA.setNudgeAddress(new) + BalancerPoolerV2.setBatchMinter(new).
 *      (nudgeSplit is LEFT at 30 — only the address is repointed; zeroing it while split>0 DoSes claim().)
 *   6. Drain + seed: if old USDC balance > 0, oldBatch.rescueERC20(USDC, new, bal) -> seeds the new pot.
 *      The amount is read LIVE at execution — the FULL residual moves, whatever it has grown to.
 *   7. Restore donation: pooler.setBatchDonationSize(15) (skip if already 15) — AFTER the repoint so
 *      restored donations flow to the NEW minter.
 *   8. Retire old contract: assert USDC balance == 0; zero its nudge config (idempotent).
 *   9. Pre-fill StableStaker set-aside buffers: deploy a throwaway BufferPrefillHelper, fund it with
 *      BUFFER_PHUSD_WEI phUSD (owner wallet balance first, mint only the shortfall — the owner is an
 *      authorized phUSD minter), then ONE atomic helper.execute(): sell phUSD -> sUSDS (Balancer V3,
 *      querySwap-floored), redeem sUSDS -> USDS, split into equal thirds, PSM-buy USDC (leg A straight
 *      to the staker), Curve-swap legs B/C into USDe (USDe/USDC pool) and DOLA (DOLA-3CRV metapool,
 *      exchange_underlying) and deliver both to the staker. Idle balance ON the StableStaker is its
 *      set-aside buffer (the underwater-withdraw path spends it; rescueERC20 can recover it).
 *  10. Persist progress JSON (broadcast only).
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/MigrateBatchNFTMinter.s.sol:MigrateBatchNFTMinter \
 *     --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --slow -vvv
 *
 * Broadcast:
 *   forge script script/MigrateBatchNFTMinter.s.sol:MigrateBatchNFTMinter \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

interface ISYANudge {
    function setNudgeAddress(address) external;
    // NOTE: the getter is the public state var `nudge` (StableYieldAccumulator.sol:
    // `address public nudge;`), NOT `nudgeAddress`. The setter is `setNudgeAddress`. (story 050 quirk)
    function nudge() external view returns (address);
    // nudgeSplit (percent [0,100]) is LEFT UNTOUCHED at 30 by this migration — only the nudge address
    // is repointed. SYA.claim() reverts whenever nudgeSplit>0 && nudge==address(0), so the pointer
    // must remain live; we never zero it.
    function nudgeSplit() external view returns (uint256);
}

interface IBalancerPoolerV2Min {
    function setBatchMinter(address) external;
    function batchMinter() external view returns (address);
    function setBatchDonationSize(uint256) external;
    function batchDonationSize() external view returns (uint256);
    function owner() external view returns (address);
}

interface IOldBatchMinter {
    function setNudgePaymentToken(address) external;
    function setNudgeSize(uint256) external;
    function nudgeSize() external view returns (uint256);
    function nudgePaymentToken() external view returns (address);
    function rescueERC20(IERC20 token, address to, uint256 amount) external;
}

interface INFTMinterV2Configs {
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

interface ITokenDispatcherV2Prime {
    function primeToken() external view returns (address);
}

/// @notice Minimal Balancer V3 Router surface (swap + its eth_call quote twin), as used by
///         MintSellAndDonateToBatchMinter.
interface IBalancerRouter {
    function swapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool wethIsEth,
        bytes calldata userData
    ) external payable returns (uint256 amountCalculated);

    function querySwapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountCalculated);
}

/// @notice Uniswap Permit2 allowance approval (Balancer V3 pulls via Permit2).
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Curve stableswap-ng pool (USDe/USDC 0x0295...4d72; coins: 0 = USDe, 1 = USDC).
interface ICurveStableSwap {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @notice Curve factory metapool (DOLA-3CRV 0xAA5A...927D; coins: 0 = DOLA, 1 = 3CRV;
///         underlying: 0 = DOLA, 1 = DAI, 2 = USDC, 3 = USDT).
interface ICurveMetaPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @notice StableStaker view used to assert the buffer tokens are registered pools.
interface IStableStakerTokens {
    function getStakedTokens() external view returns (address[] memory);
}

/**
 * @title BufferPrefillHelper
 * @notice Throwaway, per-run atomic executor for the StableStaker buffer pre-fill:
 *         phUSD -> sUSDS (Balancer V3) -> USDS (ERC4626 redeem) -> equal thirds ->
 *         USDC / USDe / DOLA -> StableStaker. The whole amount-dependent chain runs inside ONE
 *         `execute()` tx reading LIVE balances, the hardening pattern from
 *         MintSellAndDonateToBatchMinter (a multi-tx version would bake stale simulated amounts
 *         into later calldata and revert, as the original mint-sell-donate flow did).
 * @dev Trust model: deployed per run, holds funds only transiently inside `execute()`, has no
 *      protocol role, and `execute()` is onlyOwner so nobody else can trigger the flow between
 *      the funding tx and execution. Slippage floors are sized by the script from live quotes
 *      and asserted on-chain; the helper refuses any unprotected swap.
 */
contract BufferPrefillHelper {
    using SafeERC20 for IERC20;

    uint256 constant WAD = 1e18;
    // Ceiling on the PSM buy fee (LitePSM maxTout default, WAD-scaled; tout is currently 0).
    uint256 constant MAX_TOUT = 1e16; // 1%

    struct Cfg {
        address owner;
        address phusd;
        address susds;
        address usds;
        address usdc;
        address usde;
        address dola;
        address balPool;
        address balRouter;
        address permit2;
        address skyPsm;
        address curveUsdeUsdc;
        address curveDola3crv;
        address stableStaker;
    }

    address public immutable owner;
    address public immutable phusd;
    address public immutable susds;
    address public immutable usds;
    address public immutable usdc;
    address public immutable usde;
    address public immutable dola;
    address public immutable balPool;
    address public immutable balRouter;
    address public immutable permit2;
    address public immutable skyPsm;
    address public immutable curveUsdeUsdc;
    address public immutable curveDola3crv;
    address public immutable stableStaker;

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(Cfg memory c) {
        owner = c.owner;
        phusd = c.phusd;
        susds = c.susds;
        usds = c.usds;
        usdc = c.usdc;
        usde = c.usde;
        dola = c.dola;
        balPool = c.balPool;
        balRouter = c.balRouter;
        permit2 = c.permit2;
        skyPsm = c.skyPsm;
        curveUsdeUsdc = c.curveUsdeUsdc;
        curveDola3crv = c.curveDola3crv;
        stableStaker = c.stableStaker;
    }

    /**
     * @notice Atomically convert the phUSD this contract was pre-funded with into equal-thirds
     *         USDC / USDe / DOLA delivered to the StableStaker as set-aside buffer.
     * @param phusdToSwap       phUSD held by this contract to sell.
     * @param minSusdsOut       slippage floor for the Balancer swap leg (querySwap-sized; never 0).
     * @param usdeFloorPerUsdc  minimum USDe-wei out per 1 USDC (1e6) swapped on Curve (never 0).
     * @param dolaFloorPerUsdc  minimum DOLA-wei out per 1 USDC (1e6) swapped on Curve (never 0).
     */
    function execute(
        uint256 phusdToSwap,
        uint256 minSusdsOut,
        uint256 usdeFloorPerUsdc,
        uint256 dolaFloorPerUsdc
    ) external onlyOwner returns (uint256 usdcSent, uint256 usdeSent, uint256 dolaSent) {
        require(phusdToSwap > 0, "nothing to swap");
        require(minSusdsOut > 0, "swap floor unset"); // never an unprotected swap
        require(usdeFloorPerUsdc > 0 && dolaFloorPerUsdc > 0, "curve floors unset");

        // ---- 1. Sell phUSD -> sUSDS on the canonical Balancer V3 50/50 pool ----
        IERC20(phusd).forceApprove(permit2, type(uint256).max);
        IPermit2(permit2).approve(phusd, balRouter, type(uint160).max, type(uint48).max);
        uint256 swapOut = IBalancerRouter(balRouter).swapSingleTokenExactIn(
            balPool, IERC20(phusd), IERC20(susds), phusdToSwap, minSusdsOut, block.timestamp + 300, false, ""
        );
        require(swapOut >= minSusdsOut, "swap below minAmountOut");

        // ---- 2. Unwrap: redeem ALL sUSDS this contract holds -> USDS (live amount) ----
        uint256 redeemed =
            IERC4626(susds).redeem(IERC20(susds).balanceOf(address(this)), address(this), address(this));
        require(redeemed > 0, "redeem returned 0 USDS");

        // ---- 3. Split into equal thirds (<= 2 wei remainder swept as dust below) ----
        uint256 third = redeemed / 3;
        require(third > 0, "third rounds to 0");

        // ---- 4. PSM safety gates, shared by all three legs ----
        uint256 tout = ISkyPSM(skyPsm).tout();
        require(tout <= MAX_TOUT, "live PSM tout > MAX_TOUT");
        uint256 conv = ISkyPSM(skyPsm).to18ConversionFactor();
        require(conv > 0, "to18ConversionFactor == 0");

        // ---- Leg A: USDS -> USDC straight to the staker ----
        usdcSent = _buyGem(third, tout, conv, stableStaker);

        // ---- Leg B: USDS -> USDC -> USDe (Curve USDe/USDC; 1 = USDC in, 0 = USDe out) ----
        uint256 gemB = _buyGem(third, tout, conv, address(this));
        IERC20(usdc).forceApprove(curveUsdeUsdc, gemB);
        uint256 usdeBefore = IERC20(usde).balanceOf(address(this));
        ICurveStableSwap(curveUsdeUsdc).exchange(1, 0, gemB, (gemB * usdeFloorPerUsdc) / 1e6);
        IERC20(usdc).forceApprove(curveUsdeUsdc, 0);
        usdeSent = IERC20(usde).balanceOf(address(this)) - usdeBefore;
        require(usdeSent >= (gemB * usdeFloorPerUsdc) / 1e6, "USDe below floor");
        IERC20(usde).safeTransfer(stableStaker, usdeSent);

        // ---- Leg C: USDS -> USDC -> DOLA (DOLA-3CRV metapool; underlying 2 = USDC, 0 = DOLA) ----
        uint256 gemC = _buyGem(third, tout, conv, address(this));
        IERC20(usdc).forceApprove(curveDola3crv, gemC);
        uint256 dolaBefore = IERC20(dola).balanceOf(address(this));
        ICurveMetaPool(curveDola3crv).exchange_underlying(2, 0, gemC, (gemC * dolaFloorPerUsdc) / 1e6);
        IERC20(usdc).forceApprove(curveDola3crv, 0);
        dolaSent = IERC20(dola).balanceOf(address(this)) - dolaBefore;
        require(dolaSent >= (gemC * dolaFloorPerUsdc) / 1e6, "DOLA below floor");
        IERC20(dola).safeTransfer(stableStaker, dolaSent);

        // ---- 5. Sweep rounding dust (thirds remainder + PSM flooring) back to the owner ----
        uint256 dust = IERC20(usds).balanceOf(address(this));
        if (dust > 0) IERC20(usds).safeTransfer(owner, dust);
    }

    /// @dev Convert `usdsBudget` USDS to USDC via the Sky PSM, delivered to `to`. Floors the gem
    ///      amount so the PSM can never pull more USDS than the budget (mirrors
    ///      MintSellDonateHelper's math), and asserts the recipient's USDC delta.
    function _buyGem(uint256 usdsBudget, uint256 tout, uint256 conv, address to)
        internal
        returns (uint256 gemAmt)
    {
        gemAmt = (usdsBudget * WAD) / (conv * (WAD + tout));
        require(gemAmt > 0, "leg rounds to dust");
        uint256 usdsSpent = (gemAmt * conv * (WAD + tout)) / WAD;
        require(usdsSpent <= usdsBudget, "PSM would pull more than budget");
        uint256 balBefore = IERC20(usdc).balanceOf(to);
        IERC20(usds).forceApprove(skyPsm, usdsSpent);
        ISkyPSM(skyPsm).buyGem(to, gemAmt);
        IERC20(usds).forceApprove(skyPsm, 0);
        require(IERC20(usdc).balanceOf(to) - balBefore == gemAmt, "USDC delta != gemAmt");
    }
}

contract MigrateBatchNFTMinter is Script {
    // ============ Mainnet addresses (hardcoded constants, per repo convention) ============
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    // Story-056 deploy, current/live, self-refund bug — drain its residual USDC and retire it.
    address public constant OLD_BATCH_MINTER = 0x6e9886AfDF07DD67dc70b8335E4e9DF14B445071;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    // The LIVE Sky-route BalancerPoolerV2 (story 056, index-4) — repoint + restore donation.
    // NOT the stale 0x26F89f… pooler that SetBatchDonationSizeIndex4.s.sol hardcodes.
    address public constant POOLER = 0x7f74388bc970dE5e2822036A1aD06fCCd156786b;
    address public constant SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Derived prime/payment token of dispatcher index 4 (must differ from the USDC nudge token).
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    uint256 public constant DISPATCHER_INDEX = 4;
    uint256 public constant NUDGE_SIZE = 40;
    // Pooler donation rate (percent) to restore after the migration. It was zeroed as the interim
    // bleed-stop (plan §"Interim bleed-stop"); the plan's canonical value was 10%, raised to 15%
    // by owner directive 2026-06-10.
    uint256 public constant DONATION_SIZE = 15;

    // ============ Buffer pre-fill: tokens, venues, staker (mainnet, verified live 2026-06-10) ============
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    // Sky USDS<->USDC PSM (UsdsPsmWrapper "LitePSMWrapper-USDS-USDC").
    address public constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;
    // Canonical Balancer V3 50/50 weighted phUSD/sUSDS pool + its router/permit2
    // (same constants as MintSellAndDonateToBatchMinter).
    address public constant BAL_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address public constant BAL_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Curve stableswap-ng USDe/USDC pool (coins 0 = USDe, 1 = USDC; coin order re-asserted in-script).
    address public constant CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    // Curve factory metapool DOLA-3CRV (underlying 0 = DOLA, 2 = USDC; coin order re-asserted in-script).
    address public constant CURVE_DOLA_3CRV = 0xAA5A67c256e27A5d80712c51971408db3370927D;
    // Live StableStaker (story-055 migration, 2026-06-10). Its idle token balance IS the
    // set-aside buffer: _routeExit's underwater path pays withdrawals from it.
    address public constant STABLE_STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;

    address public newMinter;

    string public constant PROGRESS_PATH = "server/deployments/progress.batch-minter-migrate.1.json";

    /// @dev Slippage-floored live quotes for the buffer pre-fill legs, sized BEFORE broadcast.
    struct BufferQuote {
        uint256 phusdIn; // total phUSD to sell
        uint256 minSusdsOut; // Balancer swap floor (querySwap minus SLIPPAGE_BPS)
        uint256 usdeFloorPerUsdc; // USDe-wei out per 1 USDC (1e6) in, slippage-floored
        uint256 dolaFloorPerUsdc; // DOLA-wei out per 1 USDC (1e6) in, slippage-floored
    }

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");
        bool preview = vm.envOr("PREVIEW_MODE", false);

        // Quote the buffer legs BEFORE broadcast/prank: the Balancer querySwap needs its own
        // prank+snapshot (tx.origin == 0 spoof), which cannot nest inside an active broadcast.
        BufferQuote memory q = _quoteBufferLegs();

        if (preview) {
            console.log("=== PREVIEW MODE (fork dry-run) ===");
            vm.startPrank(OWNER);
        } else {
            console.log("=== BROADCAST MODE ===");
            vm.startBroadcast();
        }

        _preflight();
        _deployAndConfigure();
        _guards();
        _repoint();
        uint256 usdcSeeded = _drainAndSeed();
        _restoreDonation();
        _retireOld();
        (uint256 bufUsdc, uint256 bufUsde, uint256 bufDola) = _prefillBuffers(q);
        _postflight(usdcSeeded);

        if (preview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
            _persist(usdcSeeded, bufUsdc, bufUsde, bufDola);
        }
    }

    // ============ 1. Pre-flight snapshot ============
    function _preflight() internal view {
        console.log("==== PRE-FLIGHT ====");
        console.log("old batchMinter:       ", OLD_BATCH_MINTER);
        console.log("old USDC balance:      ", IERC20(USDC).balanceOf(OLD_BATCH_MINTER));
        console.log("SYA nudge:             ", ISYANudge(SYA).nudge());
        console.log("SYA nudgeSplit:        ", ISYANudge(SYA).nudgeSplit());
        console.log("pooler batchMinter:    ", IBalancerPoolerV2Min(POOLER).batchMinter());
        console.log("pooler batchDonation%: ", IBalancerPoolerV2Min(POOLER).batchDonationSize());
    }

    // ============ 2-3. Deploy + configure ============
    function _deployAndConfigure() internal {
        BatchNFTMinter m = new BatchNFTMinter(OWNER);
        newMinter = address(m);
        console.log("Deployed new BatchNFTMinter:", newMinter);

        // order matters — minter first, then index, payment token, size
        m.setTokenMinter(ITokenMinterV2(NFT_MINTER_V2));
        m.setDispatcherIndex(DISPATCHER_INDEX);
        m.setNudgePaymentToken(USDC);
        m.setNudgeSize(NUDGE_SIZE);
        // Pauser: default to matching the current live instance (pauser == address(0), minimal
        // change). Wiring the global Pauser is flagged to the operator as an option (plan §4 Q1),
        // not assumed here.
        console.log("Configured: tokenMinter, dispatcherIndex=4, nudgeToken=USDC, nudgeSize=40");
    }

    // ============ 4. Config-invariant guards (before any funds/pointers move) ============
    function _guards() internal view {
        BatchNFTMinter m = BatchNFTMinter(newMinter);
        require(address(m.tokenMinter()) != address(0), "tokenMinter not set");
        require(m.dispatcherIndex() == DISPATCHER_INDEX, "dispatcherIndex != 4");
        require(m.nudgePaymentToken() == USDC, "nudge token != USDC");

        // resolve the pinned index-4 dispatcher via the live NFTMinterV2 and check its prime token
        (address dispatcher,,,) = INFTMinterV2Configs(NFT_MINTER_V2).configs(DISPATCHER_INDEX);
        require(dispatcher != address(0), "index-4 dispatcher missing");
        address primeToken = ITokenDispatcherV2Prime(dispatcher).primeToken();
        console.log("index-4 dispatcher: ", dispatcher);
        console.log("index-4 primeToken: ", primeToken);
        // index-4 is the USDS / BalancerPoolerV2 path (confirmed on-chain 2026-06-05:
        // configs(4).primeToken == USDS 0xdC03...384F).
        require(primeToken == USDS, "index-4 primeToken != USDS");
        // The security-critical exploit guard: nudge payout token MUST differ from the dispatcher's
        // prime (mint payment) token, else batchMint would revert up-front.
        require(m.nudgePaymentToken() != primeToken, "nudge token == prime token");
        console.log("Guards passed.");
    }

    // ============ 5. Repoint dependencies ============
    function _repoint() internal {
        // Only the nudge ADDRESS is repointed; nudgeSplit stays 30 (the intended incentive). Zeroing
        // the split is NOT done — and we never zero the address while split>0 (would DoS claim()).
        ISYANudge(SYA).setNudgeAddress(newMinter);
        IBalancerPoolerV2Min(POOLER).setBatchMinter(newMinter);
        require(ISYANudge(SYA).nudge() == newMinter, "SYA repoint failed");
        require(IBalancerPoolerV2Min(POOLER).batchMinter() == newMinter, "pooler repoint failed");
        console.log("Repointed SYA + BalancerPoolerV2 to new minter");
    }

    // ============ 6. Drain old USDC + seed new pot ============
    function _drainAndSeed() internal returns (uint256 usdcSeeded) {
        // Seeding is a plain drain (the predecessor already holds USDC) — NOT the BPT exit/swap dance
        // from story 050. Read the rescue amount LIVE (USDC is 6-dp; don't hardcode).
        uint256 oldBal = IERC20(USDC).balanceOf(OLD_BATCH_MINTER);
        uint256 potBefore = IERC20(USDC).balanceOf(newMinter);
        if (oldBal > 0) {
            IOldBatchMinter(OLD_BATCH_MINTER).rescueERC20(IERC20(USDC), newMinter, oldBal);
        }
        usdcSeeded = IERC20(USDC).balanceOf(newMinter) - potBefore;
        require(usdcSeeded == oldBal, "seed amount mismatch");
        console.log("Drained old USDC into new pot:", usdcSeeded);
    }

    // ============ 7. Restore pooler donation (AFTER repoint) ============
    function _restoreDonation() internal {
        require(IBalancerPoolerV2Min(POOLER).owner() == OWNER, "unexpected pooler owner");
        uint256 cur = IBalancerPoolerV2Min(POOLER).batchDonationSize();
        if (cur != DONATION_SIZE) {
            IBalancerPoolerV2Min(POOLER).setBatchDonationSize(DONATION_SIZE);
        }
        require(IBalancerPoolerV2Min(POOLER).batchDonationSize() == DONATION_SIZE, "donation restore failed");
        console.log("pooler batchDonationSize restored to:", DONATION_SIZE);
    }

    // ============ 8. Retire old contract (defense-in-depth) ============
    function _retireOld() internal {
        uint256 oldUsdc = IERC20(USDC).balanceOf(OLD_BATCH_MINTER);
        console.log("Old contract USDC balance:", oldUsdc);
        require(oldUsdc == 0, "old contract still holds USDC");

        // idempotent — zero the old nudge config so it can never pay out again.
        if (IOldBatchMinter(OLD_BATCH_MINTER).nudgePaymentToken() != address(0)) {
            IOldBatchMinter(OLD_BATCH_MINTER).setNudgePaymentToken(address(0));
        }
        if (IOldBatchMinter(OLD_BATCH_MINTER).nudgeSize() != 0) {
            IOldBatchMinter(OLD_BATCH_MINTER).setNudgeSize(0);
        }
        console.log("Old contract neutralized (nudge token=0, size=0)");
    }

    // ============ 9a. Buffer pre-fill quotes (run BEFORE broadcast) ============
    /// @dev Sizes every swap floor from live state so no leg can ever run unprotected
    ///      (CLAUDE.md "Configuration Safety": minAmountOut is NEVER 0).
    function _quoteBufferLegs() internal returns (BufferQuote memory q) {
        // 100 phUSD per owner instruction 2026-06-10 (env-overridable).
        q.phusdIn = vm.envOr("BUFFER_PHUSD_WEI", uint256(100e18));
        require(q.phusdIn > 0, "BUFFER_PHUSD_WEI == 0");
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100)); // 1%
        require(slippageBps < 10_000, "SLIPPAGE_BPS >= 100%");

        // Live Balancer quote with the two forge-vs-eth_call quirks handled exactly as
        // MintSellAndDonateToBatchMinter does: (1) query mode requires tx.origin == 0, so prank it;
        // (2) called in-process the query MUTATES pool balances, so snapshot/revert around it.
        uint256 snap = vm.snapshotState();
        vm.prank(address(0), address(0));
        (bool ok, bytes memory ret) = BAL_ROUTER.call(
            abi.encodeWithSelector(
                IBalancerRouter.querySwapSingleTokenExactIn.selector,
                BAL_POOL,
                IERC20(PHUSD),
                IERC20(SUSDS),
                q.phusdIn,
                OWNER,
                bytes("")
            )
        );
        vm.revertToState(snap);
        require(ok, "querySwap failed");
        uint256 quotedSusds = abi.decode(ret, (uint256));
        require(quotedSusds > 0, "querySwap returned 0");
        q.minSusdsOut = (quotedSusds * (10_000 - slippageBps)) / 10_000;

        // Reference USDC leg size for the Curve rate floors: USDS the floor redeem would return,
        // thirded, floor-converted with the PSM's live params (mirrors the helper's _buyGem math).
        uint256 usdsRef = IERC4626(SUSDS).previewRedeem(q.minSusdsOut);
        uint256 tout = ISkyPSM(SKY_PSM).tout();
        require(tout <= 1e16, "PSM tout > 1%");
        uint256 conv = ISkyPSM(SKY_PSM).to18ConversionFactor();
        require(conv > 0, "to18ConversionFactor == 0");
        uint256 gemRef = ((usdsRef / 3) * 1e18) / (conv * (1e18 + tout));
        require(gemRef > 0, "gemRef == 0");

        // Per-USDC output floors. Quoting at the reference size and floor-checking per actual
        // USDC-in keeps the floor valid even if the executed leg differs slightly from gemRef.
        uint256 usdeOut = ICurveStableSwap(CURVE_USDE_USDC).get_dy(1, 0, gemRef);
        uint256 dolaOut = ICurveMetaPool(CURVE_DOLA_3CRV).get_dy_underlying(2, 0, gemRef);
        q.usdeFloorPerUsdc = ((usdeOut * (10_000 - slippageBps)) / 10_000) * 1e6 / gemRef;
        q.dolaFloorPerUsdc = ((dolaOut * (10_000 - slippageBps)) / 10_000) * 1e6 / gemRef;
        // Depeg circuit breaker: refuse to broadcast if either stable quotes >5% off par
        // (floors already include the slippage haircut, hence the asymmetric lower bound).
        require(
            q.usdeFloorPerUsdc > 0.93e18 && q.usdeFloorPerUsdc < 1.06e18,
            "USDe rate >5% off par - refusing"
        );
        require(
            q.dolaFloorPerUsdc > 0.93e18 && q.dolaFloorPerUsdc < 1.06e18,
            "DOLA rate >5% off par - refusing"
        );

        console.log("==== BUFFER QUOTES ====");
        console.log("phUSD to sell:           ", q.phusdIn);
        console.log("querySwap sUSDS out:     ", quotedSusds);
        console.log("swap floor (sUSDS):      ", q.minSusdsOut);
        console.log("reference USDC leg:      ", gemRef);
        console.log("USDe floor per USDC:     ", q.usdeFloorPerUsdc);
        console.log("DOLA floor per USDC:     ", q.dolaFloorPerUsdc);
    }

    // ============ 9b. Pre-fill StableStaker set-aside buffers ============
    function _prefillBuffers(BufferQuote memory q)
        internal
        returns (uint256 bufUsdc, uint256 bufUsde, uint256 bufDola)
    {
        // Venue / wiring guards (all view; re-asserted on-chain even though verified off-chain).
        require(ICurveStableSwap(CURVE_USDE_USDC).coins(0) == USDE, "USDe pool coin0 != USDe");
        require(ICurveStableSwap(CURVE_USDE_USDC).coins(1) == USDC, "USDe pool coin1 != USDC");
        require(ICurveMetaPool(CURVE_DOLA_3CRV).coins(0) == DOLA, "DOLA pool coin0 != DOLA");
        require(IERC4626(SUSDS).asset() == USDS, "sUSDS.asset() != USDS");
        require(ISkyPSM(SKY_PSM).gem() == USDC, "PSM gem != USDC");
        require(ISkyPSM(SKY_PSM).usds() == USDS, "PSM usds != USDS");
        _requireStakerToken(USDC);
        _requireStakerToken(USDE);
        _requireStakerToken(DOLA);

        BufferPrefillHelper helper = new BufferPrefillHelper(
            BufferPrefillHelper.Cfg({
                owner: OWNER,
                phusd: PHUSD,
                susds: SUSDS,
                usds: USDS,
                usdc: USDC,
                usde: USDE,
                dola: DOLA,
                balPool: BAL_POOL,
                balRouter: BAL_ROUTER,
                permit2: PERMIT2,
                skyPsm: SKY_PSM,
                curveUsdeUsdc: CURVE_USDE_USDC,
                curveDola3crv: CURVE_DOLA_3CRV,
                stableStaker: STABLE_STAKER
            })
        );
        console.log("BufferPrefillHelper deployed:", address(helper));

        // Source the phUSD: spend the owner's wallet balance first, mint only the shortfall
        // (the owner is an authorized phUSD minter; checked live 2026-06-10 the wallet holds ~0,
        // so in practice this mints the full amount).
        uint256 ownerBal = IERC20(PHUSD).balanceOf(OWNER);
        uint256 fromWallet = ownerBal >= q.phusdIn ? q.phusdIn : ownerBal;
        if (fromWallet > 0) {
            require(IERC20(PHUSD).transfer(address(helper), fromWallet), "phUSD transfer failed");
            console.log("phUSD funded from wallet:", fromWallet);
        }
        uint256 shortfall = q.phusdIn - fromWallet;
        if (shortfall > 0) {
            IFlax ph = IFlax(PHUSD);
            if (!ph.authorizedMinters(OWNER).canMint) {
                console.log("OWNER not authorized minter - calling setMinter(OWNER, true)");
                ph.setMinter(OWNER, true);
            }
            ph.mint(address(helper), shortfall);
            console.log("phUSD shortfall minted:  ", shortfall);
        }

        uint256 usdcBefore = IERC20(USDC).balanceOf(STABLE_STAKER);
        uint256 usdeBefore = IERC20(USDE).balanceOf(STABLE_STAKER);
        uint256 dolaBefore = IERC20(DOLA).balanceOf(STABLE_STAKER);

        // The whole amount-dependent chain in ONE tx (no stale simulated amounts in calldata).
        (bufUsdc, bufUsde, bufDola) =
            helper.execute(q.phusdIn, q.minSusdsOut, q.usdeFloorPerUsdc, q.dolaFloorPerUsdc);

        require(IERC20(USDC).balanceOf(STABLE_STAKER) - usdcBefore == bufUsdc, "staker USDC delta");
        require(IERC20(USDE).balanceOf(STABLE_STAKER) - usdeBefore == bufUsde, "staker USDe delta");
        require(IERC20(DOLA).balanceOf(STABLE_STAKER) - dolaBefore == bufDola, "staker DOLA delta");
        console.log("Buffer pre-filled USDC:  ", bufUsdc);
        console.log("Buffer pre-filled USDe:  ", bufUsde);
        console.log("Buffer pre-filled DOLA:  ", bufDola);
    }

    function _requireStakerToken(address token) internal view {
        address[] memory toks = IStableStakerTokens(STABLE_STAKER).getStakedTokens();
        for (uint256 i; i < toks.length; i++) {
            if (toks[i] == token) return;
        }
        revert("token not registered on StableStaker");
    }

    // ============ Post-flight + persist ============
    function _postflight(uint256 usdcSeeded) internal view {
        console.log("==== POST-FLIGHT ====");
        console.log("new batchMinter:       ", newMinter);
        console.log("new USDC (nudge pot):  ", IERC20(USDC).balanceOf(newMinter));
        console.log("usdc seeded:           ", usdcSeeded);
        console.log("SYA nudge:             ", ISYANudge(SYA).nudge());
        console.log("SYA nudgeSplit:        ", ISYANudge(SYA).nudgeSplit());
        console.log("pooler batchMinter:    ", IBalancerPoolerV2Min(POOLER).batchMinter());
        console.log("pooler batchDonation%: ", IBalancerPoolerV2Min(POOLER).batchDonationSize());
        console.log("staker USDC buffer:    ", IERC20(USDC).balanceOf(STABLE_STAKER));
        console.log("staker USDe buffer:    ", IERC20(USDE).balanceOf(STABLE_STAKER));
        console.log("staker DOLA buffer:    ", IERC20(DOLA).balanceOf(STABLE_STAKER));
    }

    function _persist(uint256 usdcSeeded, uint256 bufUsdc, uint256 bufUsde, uint256 bufDola) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": 1,');
        json = string.concat(json, '"networkName": "mainnet",');
        json = string.concat(json, '"batchMinter": "', vm.toString(newMinter), '",');
        json = string.concat(json, '"oldBatchMinter": "', vm.toString(OLD_BATCH_MINTER), '",');
        json = string.concat(json, '"usdcSeeded": ', vm.toString(usdcSeeded), ",");
        json = string.concat(json, '"donationSize": ', vm.toString(DONATION_SIZE), ",");
        json = string.concat(json, '"stableStaker": "', vm.toString(STABLE_STAKER), '",');
        json = string.concat(json, '"bufferUsdc": ', vm.toString(bufUsdc), ",");
        json = string.concat(json, '"bufferUsde": ', vm.toString(bufUsde), ",");
        json = string.concat(json, '"bufferDola": ', vm.toString(bufDola), ",");
        json = string.concat(json, '"timestamp": ', vm.toString(block.timestamp));
        json = string.concat(json, "}");
        vm.writeFile(PROGRESS_PATH, json);
        console.log("Progress file written:", PROGRESS_PATH);
    }
}
