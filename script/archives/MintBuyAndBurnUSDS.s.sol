// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFlax} from "@flax-token/IFlax.sol";
import {ISkyPSM} from "@yield-claim-nft/interfaces/ISkyPSM.sol";

/// @notice Minimal Balancer V3 Router surface. We use the EXACT_OUT swap (buy a
///         precise amount of sUSDS, paying up to `maxAmountIn` phUSD) plus its
///         off-chain quote twin. `querySwapSingleTokenExactOut` is non-view but is
///         designed to be eth_call'd; we invoke it pre-broadcast to size how much
///         phUSD to mint as the `maxAmountIn` budget for the swap.
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

/// @notice Uniswap V3 SwapRouter (canonical "SwapRouter", 0xE592…1564) exact-in single.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Uniswap V3 QuoterV2 (0x61fF…B21e). `quoteExactInputSingle` is non-view but
///         self-reverts its inner swap, so a plain forge call leaves pool state intact
///         (no snapshot dance needed, unlike the Balancer V3 query).
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @notice Canonical WETH9: wrap/unwrap so we can hand the recipient NATIVE ETH.
interface IWETH {
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title MintBuyDistributeHelper
 * @notice Single-transaction, on-chain executor for the
 *         mint(over-estimate) -> buy-exact-sUSDS -> redeem-to-USDS ->
 *         split(exact USDC | rest to native ETH) -> burn-leftover flow.
 *
 *         Pre-funded by the script with an OVER-ESTIMATE of phUSD (the live
 *         exact-out quote plus a slippage buffer). Inside `execute()` it:
 *           1. Buys EXACTLY `exactSusdsOut` sUSDS on the canonical Balancer V3
 *              phUSD/sUSDS pool via an EXACT_OUT swap (spend <= `maxAmountIn` phUSD;
 *              the surplus stays here because exact-out pulls only what the pool charges).
 *           2. Redeems the full sUSDS balance to USDS (ERC4626). Asserts >= `targetUsds`.
 *           3. Sells EXACTLY `usdcOut` (6dp) worth of USDS for USDC via the Sky PSM
 *              (1:1, zero-slippage), delivered straight to `recipient`.
 *           4. Sells ALL remaining USDS for native ETH: USDS->USDC (Sky PSM) then
 *              USDC->WETH on Uniswap V3 (floored by `minWethPerUsdc`), unwraps WETH to
 *              ETH, and forwards the ETH to `recipient`.
 *           5. BURNS every leftover phUSD wei (the over-estimate surplus) so only the
 *              phUSD that actually entered the pool survives as new supply. Any sub-USDC
 *              USDS dust from PSM flooring is returned to the owner.
 *
 * @dev Why a single on-chain call: the prior multi-tx mint/sell scripts reverted
 *      because Foundry bakes a *simulated* swap return value into the *next* tx's
 *      calldata; on live drift the dependent tx operates on a stale figure and reverts.
 *      Here every intermediate amount (sUSDS bought, USDS redeemed, USDS left for the
 *      ETH leg, USDC produced, WETH out) is read LIVE inside this one tx — nothing
 *      stale crosses a tx boundary. (See memory: project_mint_sell_donate_atomic.)
 *
 *      Trust model: throwaway, deployed per run, holds funds only transiently inside
 *      `execute()`, granted no protocol role. `execute()` is `onlyOwner`, so even
 *      though the owner pre-funds it with phUSD there is no MEV grief window.
 *
 *      Safety invariants asserted on-chain, atomically:
 *        - phUSD swap spend <= `maxAmountIn` (router-enforced and re-checked);
 *        - USDS redeemed >= `targetUsds`, and strictly > the USDS the USDC leg needs
 *          (so the ETH leg always has a non-zero remainder);
 *        - PSM `tout` <= `MAX_TOUT` and `to18ConversionFactor` > 0;
 *        - PSM never pulls more USDS than budgeted for each leg;
 *        - the UniV3 ETH leg has a non-zero `minWethOut` price floor (never an
 *          unprotected swap) and the realized WETH clears it;
 *        - exactly `usdcOut` USDC reached the recipient;
 *        - all swap deadlines are finite (`block.timestamp + 300`).
 */
contract MintBuyDistributeHelper {
    using SafeERC20 for IERC20;

    uint256 constant WAD = 1e18;
    // Ceiling on the PSM buy fee (mirrors the sibling script's MAX_TOUT; tout is 0 now).
    uint256 constant MAX_TOUT = 1e16; // 1%
    uint24 constant UNI_FEE = 500; // USDC/WETH 0.05% pool (deepest)

    address public immutable owner;
    address public immutable phusd;
    address public immutable susds;
    address public immutable usds;
    address public immutable usdc;
    address public immutable weth;
    address public immutable pool;
    address public immutable balancerRouter;
    address public immutable permit2;
    address public immutable skyPsm;
    address public immutable uniRouter;
    address public immutable recipient;

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(address[12] memory a) {
        owner = a[0];
        phusd = a[1];
        susds = a[2];
        usds = a[3];
        usdc = a[4];
        weth = a[5];
        pool = a[6];
        balancerRouter = a[7];
        permit2 = a[8];
        skyPsm = a[9];
        uniRouter = a[10];
        recipient = a[11];
    }

    // Accept ETH from the WETH unwrap.
    receive() external payable {}

    struct Result {
        uint256 phusdSpent;
        uint256 usdsRedeemed;
        uint256 usdcDelivered;
        uint256 ethDelivered;
        uint256 phusdBurned;
    }

    /**
     * @param exactSusdsOut    exact sUSDS to buy (sized so the redeem yields >= targetUsds).
     * @param maxAmountIn      max phUSD the swap may spend; also the amount pre-minted here.
     * @param targetUsds       minimum USDS the redeem must produce.
     * @param usdcOut          exact USDC (6dp) to deliver to the recipient via Sky PSM.
     * @param minWethPerUsdc   price floor for the ETH leg: min WETH wei per 1.0 USDC.
     */
    function execute(
        uint256 exactSusdsOut,
        uint256 maxAmountIn,
        uint256 targetUsds,
        uint256 usdcOut,
        uint256 minWethPerUsdc
    ) external onlyOwner returns (Result memory r) {
        require(exactSusdsOut > 0, "no sUSDS target");
        require(maxAmountIn > 0, "no phUSD budget"); // never an unbounded-spend swap
        require(targetUsds > 0, "no USDS target");
        require(usdcOut > 0, "no USDC target");
        require(minWethPerUsdc > 0, "no ETH-leg price floor"); // never an unprotected swap
        require(IERC20(phusd).balanceOf(address(this)) >= maxAmountIn, "helper underfunded");

        r.phusdSpent = _buySusds(exactSusdsOut, maxAmountIn);
        r.usdsRedeemed = _redeemAll(exactSusdsOut, targetUsds);

        // ---- PSM fee/decimal params (shared by both USDS->USDC legs) ----
        uint256 tout = ISkyPSM(skyPsm).tout();
        require(tout <= MAX_TOUT, "live PSM tout > MAX_TOUT");
        uint256 conv = ISkyPSM(skyPsm).to18ConversionFactor();
        require(conv > 0, "to18ConversionFactor == 0");

        // ---- Leg 1: exact `usdcOut` USDC to the recipient ----
        uint256 usdsForUsdc = (usdcOut * conv * (WAD + tout)) / WAD;
        require(usdsForUsdc < r.usdsRedeemed, "USDC leg leaves no USDS for ETH leg");
        IERC20(usds).forceApprove(skyPsm, usdsForUsdc);
        uint256 paid = ISkyPSM(skyPsm).buyGem(recipient, usdcOut);
        require(paid <= usdsForUsdc, "PSM pulled more USDS than budgeted (USDC leg)");
        IERC20(usds).forceApprove(skyPsm, 0);
        r.usdcDelivered = usdcOut;

        // ---- Leg 2: ALL remaining USDS -> USDC -> WETH -> native ETH to recipient ----
        r.ethDelivered = _sellRestForEth(conv, tout, minWethPerUsdc);

        // ---- Burn the over-estimate surplus phUSD ----
        r.phusdBurned = _burnLeftoverPhusd();

        // ---- Return any sub-USDC USDS dust (from PSM flooring) to the owner ----
        uint256 usdsDust = IERC20(usds).balanceOf(address(this));
        if (usdsDust > 0) IERC20(usds).safeTransfer(owner, usdsDust);
    }

    /// @dev Buy EXACTLY `exactSusdsOut` sUSDS, spending at most `maxAmountIn` phUSD.
    function _buySusds(uint256 exactSusdsOut, uint256 maxAmountIn) internal returns (uint256 phusdSpent) {
        IERC20(phusd).forceApprove(permit2, type(uint256).max);
        IPermit2(permit2).approve(phusd, balancerRouter, type(uint160).max, type(uint48).max);
        phusdSpent = IBalancerRouter(balancerRouter)
            .swapSingleTokenExactOut(
                pool, IERC20(phusd), IERC20(susds), exactSusdsOut, maxAmountIn, block.timestamp + 300, false, ""
            );
        require(phusdSpent <= maxAmountIn, "swap spent above maxAmountIn");
    }

    /// @dev Redeem the full sUSDS balance to USDS held here; assert >= targetUsds.
    function _redeemAll(uint256 exactSusdsOut, uint256 targetUsds) internal returns (uint256 redeemed) {
        uint256 susdsBal = IERC20(susds).balanceOf(address(this));
        require(susdsBal >= exactSusdsOut, "received less sUSDS than bought");
        redeemed = IERC4626(susds).redeem(susdsBal, address(this), address(this));
        require(redeemed >= targetUsds, "USDS redeemed below target");
    }

    /// @dev Sell ALL remaining USDS: PSM USDS->USDC, UniV3 USDC->WETH (floored), unwrap, send ETH.
    function _sellRestForEth(uint256 conv, uint256 tout, uint256 minWethPerUsdc) internal returns (uint256 ethOut) {
        uint256 leftoverUsds = IERC20(usds).balanceOf(address(this));
        require(leftoverUsds > 0, "no USDS left for ETH leg");

        // Floor the USDS->USDC conversion (sub-USDC dust is swept to owner later).
        uint256 gemAmt = (leftoverUsds * WAD) / (conv * (WAD + tout));
        require(gemAmt > 0, "ETH-leg USDS rounds to < 1 USDC");
        uint256 usdsForEth = (gemAmt * conv * (WAD + tout)) / WAD;
        require(usdsForEth <= leftoverUsds, "PSM pulled more USDS than budgeted (ETH leg)");
        IERC20(usds).forceApprove(skyPsm, usdsForEth);
        ISkyPSM(skyPsm).buyGem(address(this), gemAmt);
        IERC20(usds).forceApprove(skyPsm, 0);

        uint256 usdcForEth = IERC20(usdc).balanceOf(address(this));
        require(usdcForEth > 0, "no USDC for ETH leg");

        // Price floor scales with the live USDC amount: minWethPerUsdc is WETH wei per 1.0 USDC.
        uint256 minWethOut = (usdcForEth * minWethPerUsdc) / 1e6;
        require(minWethOut > 0, "ETH-leg minWethOut rounds to 0");

        IERC20(usdc).forceApprove(uniRouter, usdcForEth);
        uint256 wethOut = ISwapRouter(uniRouter)
            .exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: usdc,
                    tokenOut: weth,
                    fee: UNI_FEE,
                    recipient: address(this),
                    deadline: block.timestamp + 300,
                    amountIn: usdcForEth,
                    amountOutMinimum: minWethOut,
                    sqrtPriceLimitX96: 0
                })
            );
        IERC20(usdc).forceApprove(uniRouter, 0);
        require(wethOut >= minWethOut, "WETH out below floor");

        // Unwrap WETH -> native ETH and forward to the recipient.
        uint256 wethBal = IWETH(weth).balanceOf(address(this));
        IWETH(weth).withdraw(wethBal);
        ethOut = address(this).balance;
        require(ethOut > 0, "no ETH after unwrap");
        (bool ok,) = recipient.call{value: ethOut}("");
        require(ok, "ETH transfer to recipient failed");
    }

    /// @dev Burn the over-estimate surplus phUSD via IFlax.burn (self-allowance first).
    function _burnLeftoverPhusd() internal returns (uint256 burned) {
        uint256 leftover = IERC20(phusd).balanceOf(address(this));
        if (leftover > 0) {
            IERC20(phusd).forceApprove(address(this), leftover);
            IFlax(phusd).burn(address(this), leftover);
            burned = leftover;
        }
    }
}

/**
 * @title MintBuyAndBurnUSDS
 * @notice One-shot mainnet operational flow: mint enough phUSD (over-estimated) to
 *         purchase `TARGET_USDS_WEI` worth of USDS (default 1100) from the only phUSD
 *         venue — the canonical Balancer V3 50/50 phUSD/sUSDS pool — convert the bought
 *         sUSDS to USDS (ERC4626), then DISTRIBUTE the USDS:
 *           - exactly `USDC_OUT_6DP` USDC (default 1000e6) sold via the Sky PSM (1:1)
 *             and delivered to RECIPIENT;
 *           - the rest of the USDS sold for native ETH (USDS->USDC via PSM, USDC->WETH
 *             on Uniswap V3, unwrapped) and delivered to RECIPIENT.
 *         The over-minted phUSD surplus is burned atomically so it never inflates supply.
 *
 * @dev Safety (see CLAUDE.md "Configuration Safety"):
 *        - chainid pinned to mainnet (1).
 *        - The phUSD spend bound (`maxAmountIn`) is NEVER 0/unbounded: live exact-out
 *          quote + SLIPPAGE_BPS, or `MAX_PHUSD_IN_WEI` override.
 *        - The ETH leg's UniV3 swap floor (`minWethPerUsdc`) is sized from a live
 *          QuoterV2 quote minus ETH_SLIPPAGE_BPS; the helper reverts rather than swap
 *          unprotected.
 *        - The redeem must yield strictly more USDS than the USDC leg consumes, so the
 *          ETH leg always has a non-zero remainder (asserted on-chain).
 *        - sUSDS.asset()==USDS, PSM gem()==USDC, PSM usds()==USDS cross-checked.
 *        - All swap deadlines finite (block.timestamp + 300).
 *
 *      Env:
 *        - PREVIEW_MODE=true   impersonate OWNER instead of broadcasting (dry run).
 *        - TARGET_USDS_WEI     USDS to obtain, in wei. Default 1100e18.
 *        - USDC_OUT_6DP        exact USDC (6dp) delivered to RECIPIENT. Default 1000e6.
 *        - SLIPPAGE_BPS        over-estimate buffer on the phUSD budget. Default 200 (2%).
 *        - ETH_SLIPPAGE_BPS    slippage floor on the USDC->WETH leg. Default 100 (1%).
 *        - MAX_PHUSD_IN_WEI    hard override for the phUSD budget (skips the quote).
 */
contract MintBuyAndBurnUSDS is Script {
    // ---- Protocol / token addresses (mainnet, verified live 2026-06-04) ----
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // sUSDS.asset()
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Canonical Balancer V3 50/50 weighted phUSD/sUSDS pool + its router/permit2.
    address constant POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address constant BAL_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Sky USDS<->USDC PSM (UsdsPsmWrapper "LitePSMWrapper-USDS-USDC").
    address constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    // Uniswap V3 SwapRouter + QuoterV2 (for the USDC->WETH ETH leg).
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNI_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    uint24 constant UNI_FEE = 500; // USDC/WETH 0.05% pool (deepest)

    // Destination for BOTH the USDC and the ETH (user-specified).
    address constant RECIPIENT = 0x287004f90203ACCFB79b5C764a2ee9d4D2Cd2b48;

    // Owner / signer — Ledger index 46 (m/44'/60'/46'/0/0), authorized phUSD minter.
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");

        uint256 targetUsds = vm.envOr("TARGET_USDS_WEI", uint256(1100e18));
        uint256 usdcOut = vm.envOr("USDC_OUT_6DP", uint256(1000e6));
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(200)); // phUSD budget buffer, 2%
        uint256 ethSlippageBps = vm.envOr("ETH_SLIPPAGE_BPS", uint256(100)); // USDC->WETH floor, 1%
        require(targetUsds > 0, "TARGET_USDS_WEI must be > 0");
        require(usdcOut > 0, "USDC_OUT_6DP must be > 0");
        require(slippageBps < 10_000 && ethSlippageBps < 10_000, "slippage bps >= 100%");

        // ---- Cross-check token/PSM wiring before doing anything ----
        require(IERC4626(SUSDS).asset() == USDS, "sUSDS.asset() != USDS");
        require(ISkyPSM(SKY_PSM).gem() == USDC, "PSM gem != USDC");
        require(ISkyPSM(SKY_PSM).usds() == USDS, "PSM usds != USDS");

        // The USDC leg must leave a remainder for the ETH leg. Size the USDS it needs
        // from live PSM params and require the target strictly exceeds it.
        uint256 conv = ISkyPSM(SKY_PSM).to18ConversionFactor();
        uint256 tout = ISkyPSM(SKY_PSM).tout();
        uint256 usdsForUsdc = (usdcOut * conv * (1e18 + tout)) / 1e18;
        require(targetUsds > usdsForUsdc, "TARGET_USDS_WEI must exceed the USDC leg (need a remainder for ETH)");

        // ---- Size the exact sUSDS to buy so the redeem yields >= targetUsds ----
        uint256 exactSusdsOut = IERC4626(SUSDS).previewWithdraw(targetUsds);
        require(exactSusdsOut > 0, "previewWithdraw returned 0 sUSDS");

        console.log("===== MintBuyAndBurnUSDS (atomic distribute) =====");
        console.log("Target USDS (wei):        ", targetUsds);
        console.log("Exact USDC to recipient:  ", usdcOut);
        console.log("USDS used by USDC leg:    ", usdsForUsdc);
        console.log("USDS left for ETH leg:    ", targetUsds - usdsForUsdc);
        console.log("Exact sUSDS to buy (wei): ", exactSusdsOut);

        uint256 maxPhusdIn = _sizePhusdBudget(exactSusdsOut, slippageBps);
        uint256 minWethPerUsdc = _sizeEthFloor(targetUsds - usdsForUsdc, conv, tout, ethSlippageBps);

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating OWNER ***");
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }

        // ---- Deploy the per-run atomic executor ----
        address[12] memory a =
            [OWNER, PHUSD, SUSDS, USDS, USDC, WETH, POOL, BAL_ROUTER, PERMIT2, SKY_PSM, UNI_ROUTER, RECIPIENT];
        MintBuyDistributeHelper helper = new MintBuyDistributeHelper(a);
        console.log("Helper deployed at:       ", address(helper));

        // ---- Mint the (over-estimated) phUSD straight into the helper ----
        IFlax phUSD = IFlax(PHUSD);
        if (!phUSD.authorizedMinters(OWNER).canMint) {
            console.log("OWNER not authorized minter - calling setMinter(OWNER, true)");
            phUSD.setMinter(OWNER, true);
        }
        phUSD.mint(address(helper), maxPhusdIn);
        console.log("Minted phUSD into helper: ", maxPhusdIn);

        uint256 recipUsdcBefore = IERC20(USDC).balanceOf(RECIPIENT);
        uint256 recipEthBefore = RECIPIENT.balance;

        // ---- The atomic buy -> redeem -> distribute(USDC + ETH) -> burn ----
        MintBuyDistributeHelper.Result memory r =
            helper.execute(exactSusdsOut, maxPhusdIn, targetUsds, usdcOut, minWethPerUsdc);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- Off-chain cross-checks against the recipient's real deltas ----
        uint256 usdcDelta = IERC20(USDC).balanceOf(RECIPIENT) - recipUsdcBefore;
        uint256 ethDelta = RECIPIENT.balance - recipEthBefore;
        require(usdcDelta == usdcOut, "recipient USDC delta != usdcOut");
        require(usdcDelta == r.usdcDelivered, "USDC delta != reported");
        require(ethDelta == r.ethDelivered, "recipient ETH delta != reported");
        require(ethDelta > 0, "recipient received no ETH");

        console.log("phUSD spent into pool:    ", r.phusdSpent);
        console.log("phUSD burned (surplus):   ", r.phusdBurned);
        console.log("USDS redeemed total:      ", r.usdsRedeemed);
        console.log("USDC -> recipient:        ", usdcDelta);
        console.log("ETH  -> recipient (wei):  ", ethDelta);
        console.log("===== Done =====");
    }

    /// @dev Size the phUSD budget (maxAmountIn) for the exact-out sUSDS buy — never 0.
    function _sizePhusdBudget(uint256 exactSusdsOut, uint256 slippageBps) internal returns (uint256 maxPhusdIn) {
        maxPhusdIn = vm.envOr("MAX_PHUSD_IN_WEI", uint256(0));
        if (maxPhusdIn == 0) {
            // Live quote of the phUSD cost to buy `exactSusdsOut` sUSDS, then add buffer.
            // Two forge-vs-eth_call quirks (see memory project_balancer_v3_query_in_forge):
            //   1. Balancer V3 gates "query mode" on tx.origin == address(0) — spoof it.
            //   2. As a normal forge .call the query MUTATES pool balances (it "executes"
            //      the swap) — snapshot before and revert after to discard the side effects.
            uint256 snap = vm.snapshotState();
            vm.prank(address(0), address(0));
            (bool ok, bytes memory ret) = BAL_ROUTER.call(
                abi.encodeWithSelector(
                    IBalancerRouter.querySwapSingleTokenExactOut.selector,
                    POOL,
                    IERC20(PHUSD),
                    IERC20(SUSDS),
                    exactSusdsOut,
                    OWNER,
                    bytes("")
                )
            );
            vm.revertToState(snap);
            require(ok, "querySwap failed - pass MAX_PHUSD_IN_WEI");
            uint256 quoted = abi.decode(ret, (uint256));
            require(quoted > 0, "querySwap returned 0 - pass MAX_PHUSD_IN_WEI");
            maxPhusdIn = (quoted * (10_000 + slippageBps)) / 10_000;
            console.log("querySwap phUSD cost:     ", quoted);
        }
        require(maxPhusdIn > 0, "maxPhusdIn resolved to 0 - refusing unbounded swap");
        console.log("phUSD to mint (maxAmtIn): ", maxPhusdIn);
    }

    /// @dev Size the ETH-leg price floor: min WETH wei per 1.0 USDC, from a live UniV3
    ///      quote of the estimated remainder USDC minus `ethSlippageBps`. Linear in size,
    ///      so it protects the swap regardless of the exact runtime USDC amount.
    function _sizeEthFloor(uint256 remainderUsds, uint256 conv, uint256 tout, uint256 ethSlippageBps)
        internal
        returns (uint256 minWethPerUsdc)
    {
        uint256 usdcEst = (remainderUsds * 1e18) / (conv * (1e18 + tout)); // 6dp
        require(usdcEst > 0, "ETH-leg remainder < 1 USDC");
        (uint256 quotedWeth,,,) = IQuoterV2(UNI_QUOTER)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: USDC, tokenOut: WETH, amountIn: usdcEst, fee: UNI_FEE, sqrtPriceLimitX96: 0
                })
            );
        require(quotedWeth > 0, "UniV3 quote returned 0 WETH");
        // WETH wei per 1.0 USDC (1e6 units), haircut by ETH slippage.
        minWethPerUsdc = (quotedWeth * (10_000 - ethSlippageBps) * 1e6) / (10_000 * usdcEst);
        require(minWethPerUsdc > 0, "ETH-leg price floor rounds to 0");
        console.log("ETH-leg USDC est (6dp):   ", usdcEst);
        console.log("ETH-leg WETH quote (wei): ", quotedWeth);
        console.log("ETH-leg minWethPerUsdc:   ", minWethPerUsdc);
    }
}
