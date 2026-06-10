// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// [no-story] Standalone extract of the buffer-prefill swap chain from
// script/MigrateBatchNFTMinter.s.sol (story 057): MINT a fixed amount of phUSD, sell it for sUSDS
// on the canonical Balancer V3 pool, unwrap to USDS, split into equal thirds, and convert each
// third to USDC (Sky PSM), USDe (Curve USDe/USDC) and DOLA (Curve DOLA-3CRV) — delivering ALL
// three stables to the DEPLOYER account instead of the StableStaker.
//
// Two deliberate differences from the migration's _prefillBuffers:
//   1. Recipient is the deployer (OWNER), not the StableStaker.
//   2. The phUSD is ALWAYS freshly minted (default 100e18, env-overridable). The deployer's
//      existing phUSD wallet balance is NEVER spent — only minting credits the helper. (The
//      migration spent the wallet balance first and minted only the shortfall; here we do not.)
//
// Everything else mirrors the migration's hardening: the entire amount-dependent chain runs inside
// ONE atomic helper.execute() reading LIVE balances (no simulated amount is ever baked into later
// calldata, the failure mode the original mint-sell-donate flow hit), every swap floor is sized
// from a live querySwap / get_dy quote (NEVER 0, per CLAUDE.md "Configuration Safety"), and a
// >5%-off-par depeg circuit breaker refuses to broadcast on a manipulated/depegged stable.
//
// Dry run (preview, fork dry-run — no broadcast):
//   PREVIEW_MODE=true forge script script/MintAndSellPhUSDToDeployer.s.sol:MintAndSellPhUSDToDeployer \
//     --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --slow -vvv
//
// Broadcast:
//   forge script script/MintAndSellPhUSDToDeployer.s.sol:MintAndSellPhUSDToDeployer \
//     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
//     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFlax} from "@flax-token/IFlax.sol";
import {ISkyPSM} from "@yield-claim-nft/V2/interfaces/ISkyPSM.sol";

/// @notice Minimal Balancer V3 Router surface (swap + its eth_call quote twin).
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

/// @notice Curve factory metapool (DOLA-3CRV 0xAA5A...927D; underlying: 0 = DOLA, 2 = USDC).
interface ICurveMetaPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/**
 * @title SellPhUSDHelper
 * @notice Throwaway, per-run atomic executor: phUSD -> sUSDS (Balancer V3) -> USDS (ERC4626
 *         redeem) -> equal thirds -> USDC / USDe / DOLA -> recipient. The whole amount-dependent
 *         chain runs inside ONE `execute()` tx reading LIVE balances (the hardening pattern from
 *         MintSellAndDonateToBatchMinter: a multi-tx version would bake stale simulated amounts
 *         into later calldata and revert).
 * @dev Trust model: deployed per run, holds funds only transiently inside `execute()`, has no
 *      protocol role, and `execute()` is onlyOwner so nobody else can trigger the flow between the
 *      funding tx and execution. Slippage floors are sized by the script from live quotes and
 *      asserted on-chain; the helper refuses any unprotected swap.
 */
contract SellPhUSDHelper {
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
        address recipient; // where the three stables land — the DEPLOYER (not a staker)
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
    address public immutable recipient;

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
        recipient = c.recipient;
    }

    /**
     * @notice Atomically convert the phUSD this contract was pre-funded with into equal-thirds
     *         USDC / USDe / DOLA delivered to `recipient` (the deployer).
     * @param phusdToSwap       phUSD held by this contract to sell.
     * @param minSusdsOut       slippage floor for the Balancer swap leg (querySwap-sized; never 0).
     * @param usdeFloorPerUsdc  minimum USDe-wei out per 1 USDC (1e6) swapped on Curve (never 0).
     * @param dolaFloorPerUsdc  minimum DOLA-wei out per 1 USDC (1e6) swapped on Curve (never 0).
     */
    function execute(uint256 phusdToSwap, uint256 minSusdsOut, uint256 usdeFloorPerUsdc, uint256 dolaFloorPerUsdc)
        external
        onlyOwner
        returns (uint256 usdcSent, uint256 usdeSent, uint256 dolaSent)
    {
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
        uint256 redeemed = IERC4626(susds).redeem(IERC20(susds).balanceOf(address(this)), address(this), address(this));
        require(redeemed > 0, "redeem returned 0 USDS");

        // ---- 3. Split into equal thirds (<= 2 wei remainder swept as dust below) ----
        uint256 third = redeemed / 3;
        require(third > 0, "third rounds to 0");

        // ---- 4. PSM safety gates, shared by all three legs ----
        uint256 tout = ISkyPSM(skyPsm).tout();
        require(tout <= MAX_TOUT, "live PSM tout > MAX_TOUT");
        uint256 conv = ISkyPSM(skyPsm).to18ConversionFactor();
        require(conv > 0, "to18ConversionFactor == 0");

        // ---- Leg A: USDS -> USDC straight to the recipient ----
        usdcSent = _buyGem(third, tout, conv, recipient);

        // ---- Leg B: USDS -> USDC -> USDe (Curve USDe/USDC; 1 = USDC in, 0 = USDe out) ----
        uint256 gemB = _buyGem(third, tout, conv, address(this));
        IERC20(usdc).forceApprove(curveUsdeUsdc, gemB);
        uint256 usdeBefore = IERC20(usde).balanceOf(address(this));
        ICurveStableSwap(curveUsdeUsdc).exchange(1, 0, gemB, (gemB * usdeFloorPerUsdc) / 1e6);
        IERC20(usdc).forceApprove(curveUsdeUsdc, 0);
        usdeSent = IERC20(usde).balanceOf(address(this)) - usdeBefore;
        require(usdeSent >= (gemB * usdeFloorPerUsdc) / 1e6, "USDe below floor");
        IERC20(usde).safeTransfer(recipient, usdeSent);

        // ---- Leg C: USDS -> USDC -> DOLA (DOLA-3CRV metapool; underlying 2 = USDC, 0 = DOLA) ----
        uint256 gemC = _buyGem(third, tout, conv, address(this));
        IERC20(usdc).forceApprove(curveDola3crv, gemC);
        uint256 dolaBefore = IERC20(dola).balanceOf(address(this));
        ICurveMetaPool(curveDola3crv).exchange_underlying(2, 0, gemC, (gemC * dolaFloorPerUsdc) / 1e6);
        IERC20(usdc).forceApprove(curveDola3crv, 0);
        dolaSent = IERC20(dola).balanceOf(address(this)) - dolaBefore;
        require(dolaSent >= (gemC * dolaFloorPerUsdc) / 1e6, "DOLA below floor");
        IERC20(dola).safeTransfer(recipient, dolaSent);

        // ---- 5. Sweep rounding dust (thirds remainder + PSM flooring) back to the owner ----
        uint256 dust = IERC20(usds).balanceOf(address(this));
        if (dust > 0) IERC20(usds).safeTransfer(owner, dust);
    }

    /// @dev Convert `usdsBudget` USDS to USDC via the Sky PSM, delivered to `to`. Floors the gem
    ///      amount so the PSM can never pull more USDS than the budget, and asserts the delta.
    function _buyGem(uint256 usdsBudget, uint256 tout, uint256 conv, address to) internal returns (uint256 gemAmt) {
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

contract MintAndSellPhUSDToDeployer is Script {
    // ============ Mainnet addresses (verified live 2026-06-10, same constants as story 057) ============
    // The deployer / signer — receives the three stables AND mints the phUSD (authorized minter).
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    // Sky USDS<->USDC PSM (UsdsPsmWrapper "LitePSMWrapper-USDS-USDC").
    address public constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;
    // Canonical Balancer V3 50/50 weighted phUSD/sUSDS pool + its router/permit2.
    address public constant BAL_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address public constant BAL_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // Curve stableswap-ng USDe/USDC pool (coins 0 = USDe, 1 = USDC; coin order re-asserted in-script).
    address public constant CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    // Curve factory metapool DOLA-3CRV (underlying 0 = DOLA, 2 = USDC; coin order re-asserted in-script).
    address public constant CURVE_DOLA_3CRV = 0xAA5A67c256e27A5d80712c51971408db3370927D;

    string public constant PROGRESS_PATH = "server/deployments/progress.mint-sell-to-deployer.1.json";

    /// @dev Slippage-floored live quotes, sized BEFORE broadcast.
    struct Quote {
        uint256 phusdIn; // total phUSD to MINT and sell
        uint256 minSusdsOut; // Balancer swap floor (querySwap minus SLIPPAGE_BPS)
        uint256 usdeFloorPerUsdc; // USDe-wei out per 1 USDC (1e6) in, slippage-floored
        uint256 dolaFloorPerUsdc; // DOLA-wei out per 1 USDC (1e6) in, slippage-floored
    }

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");
        bool preview = vm.envOr("PREVIEW_MODE", false);

        // Quote the legs BEFORE broadcast/prank: the Balancer querySwap needs its own prank+snapshot
        // (tx.origin == 0 spoof), which cannot nest inside an active broadcast.
        Quote memory q = _quote();

        if (preview) {
            console.log("=== PREVIEW MODE (fork dry-run) ===");
            vm.startPrank(OWNER);
        } else {
            console.log("=== BROADCAST MODE ===");
            vm.startBroadcast();
        }

        (uint256 usdc, uint256 usde, uint256 dola) = _mintAndSell(q);

        if (preview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
            _persist(usdc, usde, dola);
        }
    }

    // ============ Live-quoted, slippage-floored leg sizes (run BEFORE broadcast) ============
    /// @dev Sizes every swap floor from live state so no leg can run unprotected
    ///      (CLAUDE.md "Configuration Safety": minAmountOut is NEVER 0).
    function _quote() internal returns (Quote memory q) {
        // 100 phUSD default (env-overridable). This is the amount MINTED — wallet balance untouched.
        q.phusdIn = vm.envOr("MINT_PHUSD_WEI", uint256(100e18));
        require(q.phusdIn > 0, "MINT_PHUSD_WEI == 0");
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100)); // 1%
        require(slippageBps < 10_000, "SLIPPAGE_BPS >= 100%");

        // Live Balancer quote with the two forge-vs-eth_call quirks handled exactly as the
        // migration does: (1) query mode requires tx.origin == 0, so prank it; (2) called in-process
        // the query MUTATES pool balances, so snapshot/revert around it.
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
        require(q.usdeFloorPerUsdc > 0.93e18 && q.usdeFloorPerUsdc < 1.06e18, "USDe rate >5% off par - refusing");
        require(q.dolaFloorPerUsdc > 0.93e18 && q.dolaFloorPerUsdc < 1.06e18, "DOLA rate >5% off par - refusing");

        console.log("==== QUOTES ====");
        console.log("phUSD to mint+sell:      ", q.phusdIn);
        console.log("querySwap sUSDS out:     ", quotedSusds);
        console.log("swap floor (sUSDS):      ", q.minSusdsOut);
        console.log("reference USDC leg:      ", gemRef);
        console.log("USDe floor per USDC:     ", q.usdeFloorPerUsdc);
        console.log("DOLA floor per USDC:     ", q.dolaFloorPerUsdc);
    }

    // ============ Mint phUSD + run the atomic sell chain into the deployer ============
    function _mintAndSell(Quote memory q) internal returns (uint256 outUsdc, uint256 outUsde, uint256 outDola) {
        // Venue / wiring guards (all view; re-asserted on-chain even though verified off-chain).
        require(ICurveStableSwap(CURVE_USDE_USDC).coins(0) == USDE, "USDe pool coin0 != USDe");
        require(ICurveStableSwap(CURVE_USDE_USDC).coins(1) == USDC, "USDe pool coin1 != USDC");
        require(ICurveMetaPool(CURVE_DOLA_3CRV).coins(0) == DOLA, "DOLA pool coin0 != DOLA");
        require(IERC4626(SUSDS).asset() == USDS, "sUSDS.asset() != USDS");
        require(ISkyPSM(SKY_PSM).gem() == USDC, "PSM gem != USDC");
        require(ISkyPSM(SKY_PSM).usds() == USDS, "PSM usds != USDS");

        SellPhUSDHelper helper = new SellPhUSDHelper(
            SellPhUSDHelper.Cfg({
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
                recipient: OWNER // credit the deployer
            })
        );
        console.log("SellPhUSDHelper deployed:", address(helper));

        // Source the phUSD by MINTING ONLY (the owner is an authorized phUSD minter). The deployer's
        // existing phUSD wallet balance is deliberately NOT spent — unlike the migration's prefill.
        IFlax ph = IFlax(PHUSD);
        if (!ph.authorizedMinters(OWNER).canMint) {
            console.log("OWNER not authorized minter - calling setMinter(OWNER, true)");
            ph.setMinter(OWNER, true);
        }
        ph.mint(address(helper), q.phusdIn);
        console.log("phUSD minted to helper:  ", q.phusdIn);

        uint256 usdcBefore = IERC20(USDC).balanceOf(OWNER);
        uint256 usdeBefore = IERC20(USDE).balanceOf(OWNER);
        uint256 dolaBefore = IERC20(DOLA).balanceOf(OWNER);

        // The whole amount-dependent chain in ONE tx (no stale simulated amounts in calldata).
        (outUsdc, outUsde, outDola) = helper.execute(q.phusdIn, q.minSusdsOut, q.usdeFloorPerUsdc, q.dolaFloorPerUsdc);

        require(IERC20(USDC).balanceOf(OWNER) - usdcBefore == outUsdc, "deployer USDC delta");
        require(IERC20(USDE).balanceOf(OWNER) - usdeBefore == outUsde, "deployer USDe delta");
        require(IERC20(DOLA).balanceOf(OWNER) - dolaBefore == outDola, "deployer DOLA delta");
        console.log("Deployer credited USDC:  ", outUsdc);
        console.log("Deployer credited USDe:  ", outUsde);
        console.log("Deployer credited DOLA:  ", outDola);
    }

    function _persist(uint256 outUsdc, uint256 outUsde, uint256 outDola) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": 1,');
        json = string.concat(json, '"networkName": "mainnet",');
        json = string.concat(json, '"recipient": "', vm.toString(OWNER), '",');
        json = string.concat(json, '"creditedUsdc": ', vm.toString(outUsdc), ",");
        json = string.concat(json, '"creditedUsde": ', vm.toString(outUsde), ",");
        json = string.concat(json, '"creditedDola": ', vm.toString(outDola), ",");
        json = string.concat(json, '"timestamp": ', vm.toString(block.timestamp));
        json = string.concat(json, "}");
        vm.writeFile(PROGRESS_PATH, json);
        console.log("Progress file written:", PROGRESS_PATH);
    }
}
