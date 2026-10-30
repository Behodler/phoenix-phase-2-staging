// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
// Reusable: claim the owner wallet's PhlimboV3 USDC yield and swap it to ETH.
//
// PURPOSE
//   Behodler company expense, not personal income. The owner/deployer wallet
//   0xCad1…D0B6 stakes phUSD in PhlimboV3 and accrues USDC yield. This script
//   turns that USDC into native ETH in the same wallet, to cover gas for future
//   contract deployments. Re-run whenever the wallet needs topping up.
//
// WHAT THIS DOES (3 transactions from 0xCad1, all mainnet)
//   1. PhlimboV3.claim(OWNER): pays pending USDC (and any pending phUSD) to the
//      wallet. If the wallet has USDC banked in unclaimableStableOf from an
//      earlier failed transfer, claimUnclaimableStable() is also called.
//   2. USDC.approve(SwapRouter, claimed): exact amount, never infinite.
//   3. SwapRouter.multicall([exactInputSingle USDC->WETH on the 0.05% pool with
//      the router as recipient, unwrapWETH9(minOut, OWNER)]): native ETH lands
//      in the wallet in one transaction.
//
// Only the USDC this run claimed is swapped. USDC the wallet already held is
// left alone. Under --broadcast the claim mines a few seconds after the local
// pass, so it pays slightly more than the amount baked into the swap calldata.
// That extra is cents of USDC dust left in the wallet, never a shortfall,
// because Phlimbo rewards only grow with time.
//
// SAFETY PARAMETERS (CLAUDE.md "Configuration Safety")
//   - Slippage floor: minOut = live QuoterV2 quote x (1 - SLIPPAGE_BPS). Default
//     50 bps (owner request 2026-10-30: small gas top-up, 0.05% pool), hard cap
//     MAX_SLIPPAGE_BPS = 300. Never 0.
//   - Independent price check: the quote must be within 200 bps of the
//     Chainlink ETH/USD feed (USDC taken at $1), so a manipulated pool aborts the
//     run before anything is broadcast. Feed staleness limit: 1h heartbeat + 10m.
//   - Deadline: block.timestamp + 30 minutes, to allow for Ledger signing.
//   - Minimum claim: MIN_USDC (default 10 USDC) so gas is not spent swapping dust.
//
// Run: npm run phlimbo-usdc-to-eth:preview    (mainnet fork, impersonates OWNER)
//      npm run phlimbo-usdc-to-eth:broadcast  (Ledger m/44'/60'/46'/0/0; records
//                                             the txs in ledger/transactions.csv)
// Env: SLIPPAGE_BPS (default 50), MIN_USDC (6dp, default 10e6)
// ============================================================================

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IPhlimboV3Min {
    function rewardToken() external view returns (address);
    function paused() external view returns (bool);
    function pendingStable(address user) external view returns (uint256);
    function pendingPhUSD(address user) external view returns (uint256);
    function unclaimableStableOf(address user) external view returns (uint256);
    function claim(address user) external;
    function claimUnclaimableStable() external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Uniswap V3 SwapRouter (0xE592…1564): exactInputSingle + Multicall + PeripheryPayments.
interface ISwapRouterV1 {
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
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

/// @notice Uniswap V3 QuoterV2. Non-view, but it reverts its inner swap, so pool state is untouched.
interface IQuoterV2Min {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract ClaimPhlimboUsdcToEth is Script {
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    // PhlimboV3 in server/deployments/mainnet-addresses.ts.
    address constant PHLIMBO_V3 = 0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant UNI_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint24 constant UNI_FEE = 500; // USDC/WETH 0.05% pool (deepest)

    uint256 constant DEFAULT_SLIPPAGE_BPS = 50;
    uint256 constant MAX_SLIPPAGE_BPS = 300;
    uint256 constant MAX_ORACLE_DEVIATION_BPS = 200;
    uint256 constant MAX_ORACLE_AGE = 1 hours + 10 minutes; // ETH/USD heartbeat is 1h
    uint256 constant DEADLINE_WINDOW = 30 minutes;
    uint256 constant DEFAULT_MIN_USDC = 10e6;

    function run() external {
        require(block.chainid == 1, "mainnet only");

        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", DEFAULT_SLIPPAGE_BPS);
        require(slippageBps > 0 && slippageBps <= MAX_SLIPPAGE_BPS, "SLIPPAGE_BPS out of (0, 300]");
        uint256 minUsdc = vm.envOr("MIN_USDC", DEFAULT_MIN_USDC);
        require(minUsdc > 0, "MIN_USDC must be > 0");

        IPhlimboV3Min phlimbo = IPhlimboV3Min(PHLIMBO_V3);
        IERC20Min usdc = IERC20Min(USDC);
        require(phlimbo.rewardToken() == USDC, "PhlimboV3 reward token is not USDC");
        require(!phlimbo.paused(), "PhlimboV3 paused: claim would revert");

        uint256 pending = phlimbo.pendingStable(OWNER);
        uint256 banked = phlimbo.unclaimableStableOf(OWNER);
        uint256 pendingPhUSD = phlimbo.pendingPhUSD(OWNER);
        console.log("=== PhlimboV3 rewards for", OWNER, "===");
        console.log("pending USDC (6dp):        ", pending);
        console.log("banked USDC (6dp):         ", banked);
        console.log("pending phUSD (18dp, kept):", pendingPhUSD);
        require(pending + banked >= minUsdc, "claimable USDC below MIN_USDC: not worth the gas");

        uint256 usdcBefore = usdc.balanceOf(OWNER);
        uint256 ethBefore = OWNER.balance;

        bool isPreview = vm.envOr("PREVIEW_MODE", false);

        // ---- Tx 1: claim ----
        _begin(isPreview);
        if (pending > 0) phlimbo.claim(OWNER);
        if (banked > 0) phlimbo.claimUnclaimableStable();
        _end(isPreview);

        uint256 claimed = usdc.balanceOf(OWNER) - usdcBefore;
        console.log("USDC claimed (6dp):", claimed);
        require(claimed >= minUsdc, "claim delivered less than MIN_USDC (transfer banked?)");

        // ---- Quote + independent oracle check (local only, nothing broadcast) ----
        (uint256 quotedEth,,,) = IQuoterV2Min(UNI_QUOTER)
            .quoteExactInputSingle(
                IQuoterV2Min.QuoteExactInputSingleParams({
                    tokenIn: USDC, tokenOut: WETH, amountIn: claimed, fee: UNI_FEE, sqrtPriceLimitX96: 0
                })
            );
        uint256 oracleEth = _oracleEthFor(claimed);
        console.log("Uniswap quote (wei):  ", quotedEth);
        console.log("Chainlink-implied wei:", oracleEth);
        require(
            quotedEth >= (oracleEth * (10_000 - MAX_ORACLE_DEVIATION_BPS)) / 10_000,
            "pool quote > 2% below Chainlink: pool may be manipulated"
        );

        uint256 minEthOut = (quotedEth * (10_000 - slippageBps)) / 10_000;
        require(minEthOut > 0, "slippage floor is zero");
        console.log("min ETH out (wei):    ", minEthOut);

        // ---- Tx 2 + 3: exact approve, then swap and unwrap in one multicall ----
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            ISwapRouterV1.exactInputSingle,
            (ISwapRouterV1.ExactInputSingleParams({
                    tokenIn: USDC,
                    tokenOut: WETH,
                    fee: UNI_FEE,
                    recipient: UNI_ROUTER, // router holds the WETH until unwrapWETH9 below
                    deadline: block.timestamp + DEADLINE_WINDOW,
                    amountIn: claimed,
                    amountOutMinimum: minEthOut,
                    sqrtPriceLimitX96: 0
                }))
        );
        calls[1] = abi.encodeCall(ISwapRouterV1.unwrapWETH9, (minEthOut, OWNER));

        _begin(isPreview);
        require(usdc.approve(UNI_ROUTER, claimed), "USDC approve failed");
        ISwapRouterV1(UNI_ROUTER).multicall(calls);
        _end(isPreview);

        // ---- Post-conditions ----
        uint256 ethReceived = OWNER.balance - ethBefore;
        require(ethReceived >= minEthOut, "ETH received below floor");
        require(usdc.balanceOf(OWNER) == usdcBefore, "claimed USDC not fully swapped");
        require(usdc.allowance(OWNER, UNI_ROUTER) == 0, "router allowance left over");

        console.log("=== Done ===");
        console.log("ETH received (wei):", ethReceived);
        console.log("Wallet ETH (wei):  ", OWNER.balance);
    }

    /// @dev ETH (18dp) worth `usdcAmount` (6dp) at the Chainlink ETH/USD price, USDC taken at $1.
    function _oracleEthFor(uint256 usdcAmount) internal view returns (uint256) {
        IChainlinkFeed feed = IChainlinkFeed(CHAINLINK_ETH_USD);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer > 0, "Chainlink ETH/USD answer <= 0");
        require(block.timestamp - updatedAt <= MAX_ORACLE_AGE, "Chainlink ETH/USD stale");
        // usdc(6dp) * 1e12 -> 18dp USD; divide by price scaled to 18dp.
        return (usdcAmount * 1e12 * 10 ** feed.decimals()) / uint256(answer);
    }

    function _begin(bool isPreview) internal {
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast(OWNER);
    }

    function _end(bool isPreview) internal {
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
    }
}
