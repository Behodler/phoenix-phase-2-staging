// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// [no-story] mainnet operational: MINT enough phUSD (over-estimated; signer's authorized-minter
// role — the deployer's existing phUSD wallet balance is NEVER spent), sell it for sUSDS on the
// canonical Balancer V3 50/50 phUSD/sUSDS pool (0x642BB6…db04), unwrap sUSDS -> USDS (ERC4626),
// then BUY two specific outputs and credit BOTH to the DEPLOYER:
//   * DOLA  — USDS -> USDC (Sky PSM) -> DOLA on the Curve DOLA-3CRV metapool
//             (0xAA5A…927D, exchange_underlying), target DOLA_OUT_WEI (default 20e18).
//   * ETH   — USDS -> USDC (Sky PSM) -> WETH on Uniswap V3 0.05% (EXACT-OUT, exactly ETH_OUT_WEI),
//             unwrapped to native ETH. Default 0.0056e18.
//
// Combines the EXACT-OUT ETH leg of MintBuyAndBurnUSDS (story buy-usds) with the Curve DOLA leg of
// MigrateBatchNFTMinter (story 057), retargeted from the StableStaker to the deployer (OWNER).
//
// Hardening (identical pattern to those scripts; see CLAUDE.md "Configuration Safety" + memory
// project_mint_sell_donate_atomic / project_balancer_v3_query_in_forge):
//   * The ENTIRE amount-dependent chain runs inside ONE atomic helper.execute() reading LIVE
//     balances — no simulated amount is ever baked into a later tx's calldata (the failure mode the
//     original multi-tx mint-sell-donate flow hit).
//   * EVERY swap floor/cap is sized from a LIVE quote and is NEVER 0/unbounded:
//       - phUSD spend bound  = Balancer querySwapExactOut(exactSusdsOut) + SLIPPAGE_BPS;
//       - DOLA floor (min_dy) = DOLA_OUT_WEI − SLIPPAGE_BPS, plus a >5%-off-par depeg circuit breaker;
//       - ETH leg USDC cap   = Uniswap quoteExactOutputSingle(ETH_OUT) + ETH_SLIPPAGE_BPS.
//   * recipient == owner == deployer for every leg, so all rounding dust / unspent USDC is swept
//     back to the deployer — nothing is stranded or lost.
//
// Dry run (preview, fork dry-run — no broadcast):
//   PREVIEW_MODE=true forge script script/MintSellBuyDolaEthToDeployer.s.sol:MintSellBuyDolaEthToDeployer \
//     --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --slow -vvv
//
// Broadcast:
//   forge script script/MintSellBuyDolaEthToDeployer.s.sol:MintSellBuyDolaEthToDeployer \
//     --rpc-url $RPC_MAINNET --broadcast --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFlax} from "@flax-token/IFlax.sol";
import {ISkyPSM} from "@yield-claim-nft/V2/interfaces/ISkyPSM.sol";

/// @notice Minimal Balancer V3 Router surface. EXACT_OUT swap (buy a precise amount of sUSDS,
///         paying up to `maxAmountIn` phUSD) plus its off-chain quote twin (eth_call'd pre-broadcast
///         to size the phUSD `maxAmountIn` budget).
interface IBalancerRouter {
    function swapSingleTokenExactOut(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountOut,
        uint256 maxAmountIn,
        uint256 deadline,
        bool wethIsEth,
        bytes calldata userData
    ) external payable returns (uint256 amountIn);

    function querySwapSingleTokenExactOut(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountOut,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountIn);
}

/// @notice Uniswap Permit2 allowance approval (Balancer V3 pulls tokenIn via Permit2).
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Uniswap V3 SwapRouter (canonical "SwapRouter", 0xE592…1564) exact-OUT single.
interface ISwapRouter {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/// @notice Uniswap V3 QuoterV2 (0x61fF…B21e). `quoteExactOutputSingle` is non-view but self-reverts
///         its inner swap, so a plain forge call leaves pool state intact (no snapshot dance needed).
interface IQuoterV2 {
    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount; // exact OUTPUT amount
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @notice Curve factory metapool (DOLA-3CRV 0xAA5A…927D; coins: 0 = DOLA, 1 = 3CRV;
///         underlying: 0 = DOLA, 1 = DAI, 2 = USDC, 3 = USDT).
interface ICurveMetaPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}

/// @notice Canonical WETH9: unwrap so we can hand the deployer NATIVE ETH.
interface IWETH {
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title BuyDolaEthHelper
 * @notice Throwaway, per-run atomic executor for the
 *         mint(over-estimate) -> buy-exact-sUSDS -> redeem-to-USDS ->
 *         buy DOLA (Curve) + buy ETH (Uniswap exact-out) -> burn-leftover flow.
 *
 *         Pre-funded by the script with an OVER-ESTIMATE of phUSD (live exact-out quote + buffer).
 *         Inside `execute()` it, atomically:
 *           1. Buys EXACTLY `p.exactSusdsOut` sUSDS on the canonical Balancer V3 phUSD/sUSDS pool
 *              via an EXACT_OUT swap (spend <= `p.maxPhusdIn`; exact-out pulls only what the pool
 *              charges, so the surplus phUSD stays here for burning).
 *           2. Redeems the full sUSDS balance to USDS (ERC4626). Asserts >= `p.targetUsds`.
 *           3. DOLA leg: USDS -> `p.usdcForDola` USDC (Sky PSM) -> DOLA (Curve exchange_underlying,
 *              floored by `p.dolaMinOut`), DOLA forwarded to the deployer.
 *           4. ETH leg: USDS -> `p.maxUsdcForEth` USDC (Sky PSM) -> EXACTLY `p.ethOut` WETH (Uniswap
 *              exact-out, spend <= the USDC bought), WETH unwrapped to ETH and forwarded to deployer.
 *           5. BURNS every leftover phUSD wei (the over-estimate surplus) so only the phUSD that
 *              actually entered the pool survives as new supply.
 *           6. Sweeps leftover USDS dust + unspent ETH-leg USDC back to the owner (== deployer).
 *
 * @dev Trust model: deployed per run, holds funds only transiently inside `execute()`, granted no
 *      protocol role. `execute()` is `onlyOwner`, so even though the owner pre-funds it with phUSD
 *      there is no MEV grief window. Every swap is floored/capped (never unprotected/unbounded);
 *      every safety invariant is asserted on-chain in the same tx.
 */
contract BuyDolaEthHelper {
    using SafeERC20 for IERC20;

    uint256 constant WAD = 1e18;
    uint256 constant MAX_TOUT = 1e16; // 1% ceiling on the PSM buy fee (tout is 0 now)
    uint24 constant UNI_FEE = 500; // USDC/WETH 0.05% pool (deepest)

    // DOLA-3CRV underlying indices (re-asserted via coins() in the script).
    int128 constant CRV_USDC_IDX = 2;
    int128 constant CRV_DOLA_IDX = 0;

    struct Cfg {
        address owner;
        address phusd;
        address susds;
        address usds;
        address usdc;
        address weth;
        address dola;
        address pool;
        address balRouter;
        address permit2;
        address skyPsm;
        address uniRouter;
        address curveDola3crv;
        address recipient; // where the DOLA + ETH land — the DEPLOYER (== owner here)
    }

    struct Params {
        uint256 exactSusdsOut; // exact sUSDS to buy (sized so redeem >= targetUsds)
        uint256 maxPhusdIn; // max phUSD the swap may spend; also the amount pre-minted here
        uint256 targetUsds; // minimum USDS the redeem must produce
        uint256 usdcForDola; // exact USDC (6dp) routed into the DOLA leg
        uint256 dolaMinOut; // floor on DOLA received (never 0)
        uint256 ethOut; // exact WETH/ETH to deliver (never 0)
        uint256 maxUsdcForEth; // cap on USDC (6dp) bought for the ETH leg (never 0)
    }

    struct Result {
        uint256 phusdSpent;
        uint256 usdsRedeemed;
        uint256 dolaDelivered;
        uint256 ethDelivered;
        uint256 phusdBurned;
    }

    Cfg internal cfg;

    modifier onlyOwner() {
        require(msg.sender == cfg.owner, "only owner");
        _;
    }

    constructor(Cfg memory c) {
        cfg = c;
    }

    // Accept ETH from the WETH unwrap.
    receive() external payable {}

    function execute(Params calldata p) external onlyOwner returns (Result memory r) {
        require(p.exactSusdsOut > 0, "no sUSDS target");
        require(p.maxPhusdIn > 0, "no phUSD budget"); // never an unbounded-spend swap
        require(p.targetUsds > 0, "no USDS target");
        require(p.usdcForDola > 0, "no DOLA-leg USDC");
        require(p.dolaMinOut > 0, "no DOLA floor"); // never an unprotected swap
        require(p.ethOut > 0, "no ETH target");
        require(p.maxUsdcForEth > 0, "no ETH-leg USDC cap"); // never an unbounded buy
        require(IERC20(cfg.phusd).balanceOf(address(this)) >= p.maxPhusdIn, "helper underfunded");

        r.phusdSpent = _buySusds(p.exactSusdsOut, p.maxPhusdIn);
        r.usdsRedeemed = _redeemAll(p.exactSusdsOut, p.targetUsds);

        // ---- PSM fee/decimal params (shared by both USDS->USDC legs) ----
        uint256 tout = ISkyPSM(cfg.skyPsm).tout();
        require(tout <= MAX_TOUT, "live PSM tout > MAX_TOUT");
        uint256 conv = ISkyPSM(cfg.skyPsm).to18ConversionFactor();
        require(conv > 0, "to18ConversionFactor == 0");

        r.dolaDelivered = _buyDola(p.usdcForDola, p.dolaMinOut, conv, tout);
        r.ethDelivered = _buyEth(p.ethOut, p.maxUsdcForEth, conv, tout);

        r.phusdBurned = _burnLeftoverPhusd();

        // ---- Sweep leftover USDS dust + unspent ETH-leg USDC back to the owner (== deployer) ----
        uint256 usdsDust = IERC20(cfg.usds).balanceOf(address(this));
        if (usdsDust > 0) IERC20(cfg.usds).safeTransfer(cfg.owner, usdsDust);
        uint256 usdcDust = IERC20(cfg.usdc).balanceOf(address(this));
        if (usdcDust > 0) IERC20(cfg.usdc).safeTransfer(cfg.owner, usdcDust);
    }

    /// @dev Buy EXACTLY `exactSusdsOut` sUSDS, spending at most `maxAmountIn` phUSD.
    function _buySusds(uint256 exactSusdsOut, uint256 maxAmountIn) internal returns (uint256 phusdSpent) {
        IERC20(cfg.phusd).forceApprove(cfg.permit2, type(uint256).max);
        IPermit2(cfg.permit2).approve(cfg.phusd, cfg.balRouter, type(uint160).max, type(uint48).max);
        phusdSpent = IBalancerRouter(cfg.balRouter)
            .swapSingleTokenExactOut(
                cfg.pool,
                IERC20(cfg.phusd),
                IERC20(cfg.susds),
                exactSusdsOut,
                maxAmountIn,
                block.timestamp + 300,
                false,
                ""
            );
        require(phusdSpent <= maxAmountIn, "swap spent above maxAmountIn");
    }

    /// @dev Redeem the full sUSDS balance to USDS held here; assert >= targetUsds.
    function _redeemAll(uint256 exactSusdsOut, uint256 targetUsds) internal returns (uint256 redeemed) {
        uint256 susdsBal = IERC20(cfg.susds).balanceOf(address(this));
        require(susdsBal >= exactSusdsOut, "received less sUSDS than bought");
        redeemed = IERC4626(cfg.susds).redeem(susdsBal, address(this), address(this));
        require(redeemed >= targetUsds, "USDS redeemed below target");
    }

    /// @dev USDS (18dp) the PSM pulls to mint `usdc6` USDC: usdc6 * conv * (1 + tout).
    function _usdsForUsdc(uint256 usdc6, uint256 conv, uint256 tout) internal pure returns (uint256) {
        return (usdc6 * conv * (WAD + tout)) / WAD;
    }

    /// @dev DOLA leg: USDS -> exactly `usdcForDola` USDC (PSM) -> DOLA (Curve, floored), to recipient.
    function _buyDola(uint256 usdcForDola, uint256 dolaMinOut, uint256 conv, uint256 tout)
        internal
        returns (uint256 dolaSent)
    {
        uint256 usdsForDola = _usdsForUsdc(usdcForDola, conv, tout);
        require(usdsForDola <= IERC20(cfg.usds).balanceOf(address(this)), "DOLA leg: USDS short");
        IERC20(cfg.usds).forceApprove(cfg.skyPsm, usdsForDola);
        ISkyPSM(cfg.skyPsm).buyGem(address(this), usdcForDola);
        IERC20(cfg.usds).forceApprove(cfg.skyPsm, 0);

        IERC20(cfg.usdc).forceApprove(cfg.curveDola3crv, usdcForDola);
        uint256 dolaBefore = IERC20(cfg.dola).balanceOf(address(this));
        ICurveMetaPool(cfg.curveDola3crv).exchange_underlying(CRV_USDC_IDX, CRV_DOLA_IDX, usdcForDola, dolaMinOut);
        IERC20(cfg.usdc).forceApprove(cfg.curveDola3crv, 0);
        dolaSent = IERC20(cfg.dola).balanceOf(address(this)) - dolaBefore;
        require(dolaSent >= dolaMinOut, "DOLA below floor");
        IERC20(cfg.dola).safeTransfer(cfg.recipient, dolaSent);
    }

    /// @dev ETH leg: USDS -> `maxUsdcForEth` USDC (PSM) -> EXACTLY `ethOut` WETH (UniV3 exact-out),
    ///      unwrap to native ETH, forward to recipient. Unspent USDC stays here (swept to owner).
    function _buyEth(uint256 ethOut, uint256 maxUsdcForEth, uint256 conv, uint256 tout)
        internal
        returns (uint256 ethSent)
    {
        uint256 usdsForEth = _usdsForUsdc(maxUsdcForEth, conv, tout);
        require(usdsForEth <= IERC20(cfg.usds).balanceOf(address(this)), "ETH leg: USDS short");
        IERC20(cfg.usds).forceApprove(cfg.skyPsm, usdsForEth);
        ISkyPSM(cfg.skyPsm).buyGem(address(this), maxUsdcForEth);
        IERC20(cfg.usds).forceApprove(cfg.skyPsm, 0);

        IERC20(cfg.usdc).forceApprove(cfg.uniRouter, maxUsdcForEth);
        uint256 usdcSpent = ISwapRouter(cfg.uniRouter)
            .exactOutputSingle(
                ISwapRouter.ExactOutputSingleParams({
                    tokenIn: cfg.usdc,
                    tokenOut: cfg.weth,
                    fee: UNI_FEE,
                    recipient: address(this),
                    deadline: block.timestamp + 300,
                    amountOut: ethOut,
                    amountInMaximum: maxUsdcForEth,
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(cfg.usdc).forceApprove(cfg.uniRouter, 0);
        require(usdcSpent <= maxUsdcForEth, "ETH leg spent above cap");

        uint256 wethBal = IWETH(cfg.weth).balanceOf(address(this));
        require(wethBal >= ethOut, "received less WETH than bought");
        IWETH(cfg.weth).withdraw(wethBal);
        ethSent = address(this).balance;
        require(ethSent >= ethOut, "ETH after unwrap below target");
        (bool ok,) = cfg.recipient.call{value: ethSent}("");
        require(ok, "ETH transfer to recipient failed");
    }

    /// @dev Burn the over-estimate surplus phUSD via IFlax.burn (self-allowance first).
    function _burnLeftoverPhusd() internal returns (uint256 burned) {
        uint256 leftover = IERC20(cfg.phusd).balanceOf(address(this));
        if (leftover > 0) {
            IERC20(cfg.phusd).forceApprove(address(this), leftover);
            IFlax(cfg.phusd).burn(address(this), leftover);
            burned = leftover;
        }
    }
}

/**
 * @title MintSellBuyDolaEthToDeployer
 * @notice One-shot mainnet flow: mint over-estimated phUSD, sell it for sUSDS on the canonical
 *         Balancer V3 phUSD/sUSDS pool, redeem to USDS, then buy DOLA_OUT_WEI DOLA (Curve) and
 *         exactly ETH_OUT_WEI native ETH (Uniswap exact-out) and credit BOTH to the deployer. The
 *         over-minted phUSD surplus is burned atomically so it never inflates supply.
 *
 * @dev Env:
 *        - PREVIEW_MODE=true   impersonate OWNER instead of broadcasting (dry run).
 *        - DOLA_OUT_WEI        DOLA to buy (18dp). Default 20e18.
 *        - ETH_OUT_WEI         native ETH to buy (18dp). Default 0.0056e18 (5.6e15 wei).
 *        - SLIPPAGE_BPS        buffer on the phUSD budget AND haircut on the DOLA floor. Default 100 (1%).
 *        - ETH_SLIPPAGE_BPS    buffer on the ETH-leg USDC cap. Default 100 (1%).
 *        - MAX_PHUSD_IN_WEI    hard override for the phUSD budget (skips the Balancer quote).
 */
contract MintSellBuyDolaEthToDeployer is Script {
    // ============ Mainnet addresses (verified live 2026-06-10; same constants as buy-usds / story 057) ============
    // The deployer / signer — receives the DOLA + ETH AND mints the phUSD (authorized minter).
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // sUSDS.asset()
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;

    // Canonical Balancer V3 50/50 weighted phUSD/sUSDS pool + its router/permit2.
    address public constant POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address public constant BAL_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Sky USDS<->USDC PSM (UsdsPsmWrapper "LitePSMWrapper-USDS-USDC").
    address public constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    // Uniswap V3 SwapRouter + QuoterV2 (for the USDC->WETH ETH leg, exact-out).
    address public constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNI_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    uint24 public constant UNI_FEE = 500; // USDC/WETH 0.05% pool (deepest)

    // Curve factory metapool DOLA-3CRV (underlying 0 = DOLA, 2 = USDC; coin order re-asserted in-script).
    address public constant CURVE_DOLA_3CRV = 0xAA5A67c256e27A5d80712c51971408db3370927D;

    string public constant PROGRESS_PATH = "server/deployments/progress.buy-dola-eth-to-deployer.1.json";

    /// @dev Slippage-floored live quotes + the full helper param set, sized BEFORE broadcast.
    struct Plan {
        uint256 exactSusdsOut;
        uint256 maxPhusdIn;
        uint256 targetUsds;
        uint256 usdcForDola;
        uint256 dolaMinOut;
        uint256 ethOut;
        uint256 maxUsdcForEth;
        uint256 quotedPhusd; // pre-buffer Balancer cost (logging only)
    }

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");
        bool preview = vm.envOr("PREVIEW_MODE", false);

        // ---- Cross-check token / PSM / pool wiring before anything ----
        require(IERC4626(SUSDS).asset() == USDS, "sUSDS.asset() != USDS");
        require(ISkyPSM(SKY_PSM).gem() == USDC, "PSM gem != USDC");
        require(ISkyPSM(SKY_PSM).usds() == USDS, "PSM usds != USDS");
        // Metapool coins() only exposes top-level coins (0 = DOLA, 1 = 3CRV); USDC is underlying
        // index 2 via the base 3pool and is not reachable through coins(). Assert coin0 == DOLA (as
        // the source migration does) and trust the canonical USDC constant (also cross-checked via
        // PSM.gem() == USDC above).
        require(ICurveMetaPool(CURVE_DOLA_3CRV).coins(0) == DOLA, "DOLA pool coin0 != DOLA");

        // Quote BEFORE broadcast/prank: the Balancer querySwap needs its own prank+snapshot
        // (tx.origin == 0 spoof), which cannot nest inside an active broadcast.
        Plan memory p = _plan();

        if (preview) {
            console.log("=== PREVIEW MODE (fork dry-run) ===");
            vm.startPrank(OWNER);
        } else {
            console.log("=== BROADCAST MODE ===");
            vm.startBroadcast();
        }

        BuyDolaEthHelper.Result memory r = _mintAndBuy(p);

        if (preview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
            _persist(r);
        }
    }

    // ============ Live-quoted, slippage-floored sizing (run BEFORE broadcast) ============
    function _plan() internal returns (Plan memory p) {
        uint256 dolaOut = vm.envOr("DOLA_OUT_WEI", uint256(20e18));
        p.ethOut = vm.envOr("ETH_OUT_WEI", uint256(0.0056e18));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100)); // 1%
        uint256 ethSlippageBps = vm.envOr("ETH_SLIPPAGE_BPS", uint256(100)); // 1%
        require(dolaOut > 0, "DOLA_OUT_WEI == 0");
        require(p.ethOut > 0, "ETH_OUT_WEI == 0");
        require(slippageBps < 10_000 && ethSlippageBps < 10_000, "slippage bps >= 100%");

        uint256 conv = ISkyPSM(SKY_PSM).to18ConversionFactor();
        uint256 tout = ISkyPSM(SKY_PSM).tout();

        // ---- ETH leg: live UniV3 exact-out quote (USDC needed to buy exactly ethOut WETH) ----
        (uint256 usdcForEthEst,,,) = IQuoterV2(UNI_QUOTER)
            .quoteExactOutputSingle(
                IQuoterV2.QuoteExactOutputSingleParams({
                    tokenIn: USDC, tokenOut: WETH, amount: p.ethOut, fee: UNI_FEE, sqrtPriceLimitX96: 0
                })
            );
        require(usdcForEthEst > 0, "UniV3 exact-out quote returned 0 USDC");
        p.maxUsdcForEth = (usdcForEthEst * (10_000 + ethSlippageBps)) / 10_000;
        uint256 usdsForEth = (p.maxUsdcForEth * conv * (1e18 + tout)) / 1e18;

        // ---- DOLA leg: size USDC for ~dolaOut, floor at dolaOut − slippage, depeg-guarded ----
        // Probe the rate near target: ~dolaOut USDC (DOLA & USDC both ~$1), invert to find the USDC
        // input that yields ~dolaOut DOLA. get_dy_underlying is view (no snapshot needed).
        uint256 probeUsdc = dolaOut / 1e12; // 18dp DOLA -> ~6dp USDC at par
        require(probeUsdc > 0, "DOLA target rounds to < 1 USDC");
        uint256 dolaForProbe = ICurveMetaPool(CURVE_DOLA_3CRV).get_dy_underlying(2, 0, probeUsdc);
        require(dolaForProbe > 0, "Curve get_dy_underlying returned 0");
        // Depeg circuit breaker: DOLA-wei out per 1.0 USDC must be within ~5% of par.
        uint256 dolaPerUsdc = (dolaForProbe * 1e6) / probeUsdc; // ~1e18 at par
        require(dolaPerUsdc > 0.93e18 && dolaPerUsdc < 1.06e18, "DOLA rate >5% off par - refusing");
        // USDC needed for dolaOut, plus a buffer so the realized output clears the floor.
        p.usdcForDola = (((dolaOut * probeUsdc) / dolaForProbe) * (10_000 + slippageBps)) / 10_000;
        require(p.usdcForDola > 0, "DOLA-leg USDC rounds to 0");
        p.dolaMinOut = (dolaOut * (10_000 - slippageBps)) / 10_000; // never 0
        uint256 usdsForDola = (p.usdcForDola * conv * (1e18 + tout)) / 1e18;

        // ---- USDS the redeem must produce: both legs + 0.2% rounding headroom ----
        p.targetUsds = ((usdsForEth + usdsForDola) * 10_020) / 10_000;
        p.exactSusdsOut = IERC4626(SUSDS).previewWithdraw(p.targetUsds);
        require(p.exactSusdsOut > 0, "previewWithdraw returned 0 sUSDS");

        // ---- phUSD budget: live Balancer exact-out quote + SLIPPAGE_BPS (never 0/unbounded) ----
        p.maxPhusdIn = vm.envOr("MAX_PHUSD_IN_WEI", uint256(0));
        if (p.maxPhusdIn == 0) {
            // Balancer V3 query quirks (memory project_balancer_v3_query_in_forge):
            //   1. query mode gates on tx.origin == 0 -> prank it;
            //   2. as a normal forge .call it MUTATES pool balances -> snapshot/revert around it.
            uint256 snap = vm.snapshotState();
            vm.prank(address(0), address(0));
            (bool ok, bytes memory ret) = BAL_ROUTER.call(
                abi.encodeWithSelector(
                    IBalancerRouter.querySwapSingleTokenExactOut.selector,
                    POOL,
                    IERC20(PHUSD),
                    IERC20(SUSDS),
                    p.exactSusdsOut,
                    OWNER,
                    bytes("")
                )
            );
            vm.revertToState(snap);
            require(ok, "querySwap failed - pass MAX_PHUSD_IN_WEI");
            p.quotedPhusd = abi.decode(ret, (uint256));
            require(p.quotedPhusd > 0, "querySwap returned 0 - pass MAX_PHUSD_IN_WEI");
            p.maxPhusdIn = (p.quotedPhusd * (10_000 + slippageBps)) / 10_000;
        }
        require(p.maxPhusdIn > 0, "maxPhusdIn resolved to 0 - refusing unbounded swap");

        console.log("==== PLAN ====");
        console.log("DOLA to buy (wei):        ", dolaOut);
        console.log("  USDC for DOLA (6dp):    ", p.usdcForDola);
        console.log("  DOLA floor (min_dy):    ", p.dolaMinOut);
        console.log("ETH to buy (wei):         ", p.ethOut);
        console.log("  UniV3 USDC quote (6dp): ", usdcForEthEst);
        console.log("  ETH-leg USDC cap (6dp): ", p.maxUsdcForEth);
        console.log("USDS target (redeem >=):  ", p.targetUsds);
        console.log("Exact sUSDS to buy (wei): ", p.exactSusdsOut);
        console.log("querySwap phUSD cost:     ", p.quotedPhusd);
        console.log("phUSD to mint (maxAmtIn): ", p.maxPhusdIn);
    }

    // ============ Mint phUSD + run the atomic buy chain, crediting the deployer ============
    function _mintAndBuy(Plan memory p) internal returns (BuyDolaEthHelper.Result memory r) {
        BuyDolaEthHelper helper = new BuyDolaEthHelper(
            BuyDolaEthHelper.Cfg({
                owner: OWNER,
                phusd: PHUSD,
                susds: SUSDS,
                usds: USDS,
                usdc: USDC,
                weth: WETH,
                dola: DOLA,
                pool: POOL,
                balRouter: BAL_ROUTER,
                permit2: PERMIT2,
                skyPsm: SKY_PSM,
                uniRouter: UNI_ROUTER,
                curveDola3crv: CURVE_DOLA_3CRV,
                recipient: OWNER // credit the deployer
            })
        );
        console.log("BuyDolaEthHelper deployed:", address(helper));

        // Source phUSD by MINTING ONLY (the owner is an authorized phUSD minter). The deployer's
        // existing phUSD wallet balance is deliberately NOT spent.
        IFlax ph = IFlax(PHUSD);
        if (!ph.authorizedMinters(OWNER).canMint) {
            console.log("OWNER not authorized minter - calling setMinter(OWNER, true)");
            ph.setMinter(OWNER, true);
        }
        ph.mint(address(helper), p.maxPhusdIn);
        console.log("phUSD minted to helper:  ", p.maxPhusdIn);

        uint256 dolaBefore = IERC20(DOLA).balanceOf(OWNER);
        uint256 ethBefore = OWNER.balance;

        r = helper.execute(
            BuyDolaEthHelper.Params({
                exactSusdsOut: p.exactSusdsOut,
                maxPhusdIn: p.maxPhusdIn,
                targetUsds: p.targetUsds,
                usdcForDola: p.usdcForDola,
                dolaMinOut: p.dolaMinOut,
                ethOut: p.ethOut,
                maxUsdcForEth: p.maxUsdcForEth
            })
        );

        // ---- Off-chain cross-checks against the deployer's real deltas ----
        uint256 dolaDelta = IERC20(DOLA).balanceOf(OWNER) - dolaBefore;
        uint256 ethDelta = OWNER.balance - ethBefore;
        require(dolaDelta == r.dolaDelivered, "deployer DOLA delta != reported");
        require(dolaDelta >= p.dolaMinOut, "deployer DOLA below floor");
        require(ethDelta == r.ethDelivered, "deployer ETH delta != reported");
        require(ethDelta >= p.ethOut, "deployer ETH below target");

        console.log("phUSD spent into pool:    ", r.phusdSpent);
        console.log("phUSD burned (surplus):   ", r.phusdBurned);
        console.log("USDS redeemed total:      ", r.usdsRedeemed);
        console.log("DOLA -> deployer (wei):   ", dolaDelta);
        console.log("ETH  -> deployer (wei):   ", ethDelta);
        console.log("===== Done =====");
    }

    function _persist(BuyDolaEthHelper.Result memory r) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": 1,');
        json = string.concat(json, '"networkName": "mainnet",');
        json = string.concat(json, '"recipient": "', vm.toString(OWNER), '",');
        json = string.concat(json, '"dolaDelivered": ', vm.toString(r.dolaDelivered), ",");
        json = string.concat(json, '"ethDelivered": ', vm.toString(r.ethDelivered), ",");
        json = string.concat(json, '"phusdSpent": ', vm.toString(r.phusdSpent), ",");
        json = string.concat(json, '"phusdBurned": ', vm.toString(r.phusdBurned), ",");
        json = string.concat(json, '"timestamp": ', vm.toString(block.timestamp));
        json = string.concat(json, "}");
        vm.writeFile(PROGRESS_PATH, json);
        console.log("Progress file written:", PROGRESS_PATH);
    }
}
