// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";
import {IUniswapV2Router02} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Router02.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Stand-in for Antimatter if it has no code at FORK_BLOCK (story 120).
contract ForkStubAM is ERC20 {
    constructor() ERC20("Antimatter", "AM") {}
}

interface IUniswapV2FactoryCreate {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

/// @title  UniswapHelperForkTest
/// @notice Every UniswapHelper route against real mainnet venues: Sky PSM, sUSDS, Curve DOLA-3CRV and
///         USDe/USDC stableswap-ng, Uniswap V3 WETH/USDC 0.05% and Uniswap V2 Router02.
/// @dev    The mainnet phUSD/sUSDS V2 pair does not exist until story 103's cutover, so it is created
///         and seeded in-fork when `getPair` returns zero. Skips cleanly when RPC_MAINNET is unset
///         (CI runs plain `forge test` with no RPC).
contract UniswapHelperForkTest is Test {
    uint256 constant FORK_BLOCK = 26_170_000;

    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant V3_QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant CURVE_DOLA = 0xAA5A67c256e27A5d80712c51971408db3370927D;
    address constant CURVE_USDE = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;
    address constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;

    /// @dev Quotes are read in the same state as the swap and are exact for every venue except one:
    ///      the Curve DOLA-3CRV metapool's `get_dy_underlying` for USDC -> DOLA estimates the 3pool
    ///      deposit with `calc_token_amount`, which ignores imbalance fees (~0.002% at FORK_BLOCK).
    ///      1e14 = 0.01% covers that while still catching any real quote/route mismatch.
    uint256 constant QUOTE_TOLERANCE = 1e14;

    UniswapHelper helper;
    address lp;
    address am;
    address amLp;
    address user = makeAddr("user");
    address recipient = makeAddr("recipient");

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        // Story 120: the live Antimatter token, or a plain ERC20 stand-in if it is not deployed yet
        // at FORK_BLOCK. Either way the AM/sUSDS pair is created and seeded in-fork below.
        am = ANTIMATTER.code.length > 0 ? ANTIMATTER : address(new ForkStubAM());

        // Deploy from a dedicated EOA: the test contract's own CREATE addresses collide with mainnet
        // addresses that already hold ETH dust, which would mask the zero-balance assertions.
        vm.prank(makeAddr("helperDeployer"));
        helper = new UniswapHelper(
            PHUSD,
            SUSDS,
            USDS,
            USDC,
            DOLA,
            USDE,
            WETH,
            SKY_PSM,
            V2_ROUTER,
            V3_ROUTER,
            V3_QUOTER,
            CURVE_DOLA,
            CURVE_USDE,
            am,
            500
        );

        IUniswapV2FactoryCreate factory = IUniswapV2FactoryCreate(IUniswapV2Router02(V2_ROUTER).factory());
        lp = factory.getPair(SUSDS, PHUSD);
        if (lp == address(0)) {
            // Seed ~$1M a side at phUSD = $1.
            lp = factory.createPair(SUSDS, PHUSD);
            uint256 seed = 1_000_000e18;
            deal(USDS, address(this), seed);
            IERC20(USDS).approve(SUSDS, seed);
            uint256 shares = IERC4626(SUSDS).deposit(seed, address(this));
            deal(PHUSD, address(this), seed);
            IERC20(SUSDS).approve(V2_ROUTER, shares);
            IERC20(PHUSD).approve(V2_ROUTER, seed);
            IUniswapV2Router02(V2_ROUTER).addLiquidity(SUSDS, PHUSD, shares, seed, 0, 0, address(this), block.timestamp);
        }
        assertEq(helper.pair(), lp, "helper resolves the pair");

        amLp = factory.getPair(SUSDS, am);
        if (amLp == address(0)) {
            // Seed ~$1M of sUSDS against 4M AM (AM ~ $0.25).
            amLp = factory.createPair(SUSDS, am);
            uint256 seed = 1_000_000e18;
            deal(USDS, address(this), seed);
            IERC20(USDS).approve(SUSDS, seed);
            uint256 shares = IERC4626(SUSDS).deposit(seed, address(this));
            deal(am, address(this), 4 * seed);
            IERC20(SUSDS).approve(V2_ROUTER, shares);
            IERC20(am).approve(V2_ROUTER, 4 * seed);
            IUniswapV2Router02(V2_ROUTER)
                .addLiquidity(SUSDS, am, shares, 4 * seed, 0, 0, address(this), block.timestamp);
        }
        assertEq(helper.amPair(), amLp, "helper resolves the AM pair");
        _assertHelperEmpty();
    }

    // ---------------------------------------------------------------- helpers

    function _stables() internal pure returns (address[5] memory) {
        return [SUSDS, USDS, USDC, DOLA, USDE];
    }

    function _unit(address t) internal pure returns (uint256) {
        return t == USDC ? 1e6 : 1e18;
    }

    function _fund(address token, address to, uint256 amt) internal {
        if (token == SUSDS) {
            uint256 usds = IERC4626(SUSDS).previewMint(amt);
            deal(USDS, address(this), usds);
            IERC20(USDS).approve(SUSDS, usds);
            IERC4626(SUSDS).mint(amt, to);
        } else {
            deal(token, to, IERC20(token).balanceOf(to) + amt);
        }
    }

    function _assertHelperEmpty() internal view {
        address h = address(helper);
        assertEq(h.balance, 0, "helper ETH");
        address[10] memory toks = [PHUSD, SUSDS, USDS, USDC, DOLA, USDE, WETH, lp, am, amLp];
        for (uint256 i; i < toks.length; i++) {
            assertEq(IERC20(toks[i]).balanceOf(h), 0, "helper holds a token");
        }
    }

    // ---------------------------------------------------------------- swaps, every route both ways

    function test_fork_swapToPhUSD_everyStable() public {
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 amt = 1000 * _unit(toks[i]);
            _fund(toks[i], user, amt);
            uint256 quote = helper.quoteToPhUSD(toks[i], amt);

            vm.startPrank(user);
            IERC20(toks[i]).approve(address(helper), amt);
            uint256 before = IERC20(PHUSD).balanceOf(recipient);
            uint256 out = helper.swapToPhUSD(toks[i], amt, quote * 999 / 1000, recipient, block.timestamp);
            vm.stopPrank();

            console2.log("to phUSD from", IERC20Meta(toks[i]).symbol(), out);
            assertGt(out, 900e18, "route lost too much value");
            assertApproxEqRel(out, quote, QUOTE_TOLERANCE, "quote != actual");
            assertEq(IERC20(PHUSD).balanceOf(recipient) - before, out, "recipient phUSD");
            _assertHelperEmpty();
        }
    }

    function test_fork_swapFromPhUSD_everyStable() public {
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 phIn = 1000e18;
            deal(PHUSD, user, phIn);
            uint256 quote = helper.quoteFromPhUSD(toks[i], phIn);

            vm.startPrank(user);
            IERC20(PHUSD).approve(address(helper), phIn);
            uint256 before = IERC20(toks[i]).balanceOf(recipient);
            uint256 out = helper.swapFromPhUSD(toks[i], phIn, quote * 999 / 1000, recipient, block.timestamp);
            vm.stopPrank();

            console2.log("from phUSD to", IERC20Meta(toks[i]).symbol(), out);
            assertGt(out, (toks[i] == SUSDS ? 800 : 900) * _unit(toks[i]), "route lost too much value");
            assertApproxEqRel(out, quote, QUOTE_TOLERANCE, "quote != actual");
            assertGe(IERC20(toks[i]).balanceOf(recipient) - before, out, "recipient out");
            _assertHelperEmpty();
        }
    }

    function test_fork_ethRoutes() public {
        vm.deal(user, 1 ether);
        uint256 q = helper.quoteETHToPhUSD(1 ether);
        vm.prank(user);
        uint256 out = helper.swapETHToPhUSD{value: 1 ether}(q * 999 / 1000, recipient, block.timestamp);
        console2.log("ETH -> phUSD", out);
        assertGt(out, 500e18, "1 ETH bought too little phUSD");
        assertApproxEqRel(out, q, QUOTE_TOLERANCE, "eth->phUSD quote");
        _assertHelperEmpty();

        uint256 phIn = 2000e18;
        deal(PHUSD, user, phIn);
        uint256 qe = helper.quotePhUSDToETH(phIn);
        vm.startPrank(user);
        IERC20(PHUSD).approve(address(helper), phIn);
        uint256 ethOut = helper.swapPhUSDToETH(phIn, qe * 999 / 1000, payable(recipient), block.timestamp);
        vm.stopPrank();
        console2.log("phUSD -> ETH (wei)", ethOut);
        assertGt(ethOut, 0.1 ether);
        assertApproxEqRel(ethOut, qe, QUOTE_TOLERANCE, "phUSD->eth quote");
        assertEq(recipient.balance, ethOut, "recipient ETH");
        _assertHelperEmpty();
    }

    // ---------------------------------------------------------------- guards

    function test_fork_minOutAndDeadline() public {
        uint256 amt = 1000e6;
        _fund(USDC, user, amt);
        uint256 quote = helper.quoteToPhUSD(USDC, amt);
        vm.startPrank(user);
        IERC20(USDC).approve(address(helper), amt);
        vm.expectPartialRevert(UniswapHelper.InsufficientOutput.selector);
        helper.swapToPhUSD(USDC, amt, quote + quote / 100, recipient, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, block.timestamp - 1, block.timestamp));
        helper.swapToPhUSD(USDC, amt, 0, recipient, block.timestamp - 1);
        vm.stopPrank();

        deal(PHUSD, user, 1000e18);
        uint256 qe = helper.quotePhUSDToETH(1000e18);
        vm.startPrank(user);
        IERC20(PHUSD).approve(address(helper), 1000e18);
        vm.expectPartialRevert(UniswapHelper.InsufficientOutput.selector);
        helper.swapPhUSDToETH(1000e18, qe + qe / 100, payable(recipient), block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- liquidity

    function test_fork_liquidity_addAndRemove() public {
        // addLiquiditySUSDS with surplus phUSD: the excess is refunded.
        uint256 sIn = 1000e18;
        _fund(SUSDS, user, sIn);
        deal(PHUSD, user, 5000e18);
        vm.startPrank(user);
        IERC20(SUSDS).approve(address(helper), sIn);
        IERC20(PHUSD).approve(address(helper), 5000e18);
        (uint256 sUsed, uint256 pUsed, uint256 liq1) =
            helper.addLiquiditySUSDS(sIn, 5000e18, sIn, 0, user, block.timestamp);
        vm.stopPrank();
        assertEq(sUsed, sIn);
        assertLt(pUsed, 5000e18);
        assertEq(IERC20(PHUSD).balanceOf(user), 5000e18 - pUsed, "phUSD refund");
        assertEq(IERC20(lp).balanceOf(user), liq1, "LP to user");
        _assertHelperEmpty();

        // addLiquidityUSDS with surplus USDS: the excess sUSDS is redeemed back to USDS.
        deal(USDS, user, 5000e18);
        deal(PHUSD, user, 1000e18);
        vm.startPrank(user);
        IERC20(USDS).approve(address(helper), 5000e18);
        IERC20(PHUSD).approve(address(helper), 1000e18);
        (uint256 uUsed,, uint256 liq2) = helper.addLiquidityUSDS(5000e18, 1000e18, 0, 1000e18, user, block.timestamp);
        vm.stopPrank();
        assertLt(uUsed, 5000e18);
        assertEq(IERC20(USDS).balanceOf(user), 5000e18 - uUsed, "USDS refund");
        assertEq(IERC20(SUSDS).balanceOf(user), 0, "refund must be USDS");
        assertEq(IERC20(lp).balanceOf(user), liq1 + liq2);
        _assertHelperEmpty();

        // removeLiquidityUSDS: unwraps the sUSDS side.
        vm.startPrank(user);
        IERC20(lp).approve(address(helper), liq1 + liq2);
        (uint256 uOut, uint256 pOut) =
            helper.removeLiquidityUSDS(liq2, uUsed * 999 / 1000, 0, recipient, block.timestamp);
        assertApproxEqRel(uOut, uUsed, 1e15, "USDS back");
        assertApproxEqRel(pOut, 1000e18, 1e15, "phUSD back");
        assertEq(IERC20(USDS).balanceOf(recipient), uOut);
        assertEq(IERC20(SUSDS).balanceOf(recipient), 0, "sUSDS must be unwrapped");
        _assertHelperEmpty();

        // removeLiquiditySUSDS: plain removal.
        (uint256 sOut, uint256 pOut2) =
            helper.removeLiquiditySUSDS(liq1, sIn * 999 / 1000, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertApproxEqRel(sOut, sIn, 1e15, "sUSDS back");
        assertApproxEqRel(pOut2, pUsed, 1e15, "phUSD back");
        assertEq(IERC20(lp).balanceOf(user), 0, "all LP burned");
        _assertHelperEmpty();
    }

    // ---------------------------------------------------------------- Antimatter (story 120)

    function test_fork_amRoutes_everyStable_bothWays() public {
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 amt = 1000 * _unit(toks[i]);
            _fund(toks[i], user, amt);
            uint256 quote = helper.quoteToAM(toks[i], amt);
            vm.startPrank(user);
            IERC20(toks[i]).approve(address(helper), amt);
            uint256 out = helper.swapToAM(toks[i], amt, quote * 999 / 1000, recipient, block.timestamp);
            vm.stopPrank();
            console2.log("to AM from", IERC20Meta(toks[i]).symbol(), out);
            assertGt(out, 0, "no AM");
            assertApproxEqRel(out, quote, QUOTE_TOLERANCE, "quote != actual (to AM)");
            _assertHelperEmpty();

            uint256 amIn = 4000e18;
            deal(am, user, amIn);
            uint256 q2 = helper.quoteFromAM(toks[i], amIn);
            vm.startPrank(user);
            IERC20(am).approve(address(helper), amIn);
            uint256 back = helper.swapFromAM(toks[i], amIn, q2 * 999 / 1000, recipient, block.timestamp);
            vm.stopPrank();
            console2.log("from AM to", IERC20Meta(toks[i]).symbol(), back);
            assertGt(back, 0, "no output");
            assertApproxEqRel(back, q2, QUOTE_TOLERANCE, "quote != actual (from AM)");
            _assertHelperEmpty();
        }
    }

    function test_fork_amEthAndPhusdRoutes() public {
        vm.deal(user, 1 ether);
        uint256 q = helper.quoteETHToAM(1 ether);
        vm.prank(user);
        uint256 out = helper.swapETHToAM{value: 1 ether}(q * 999 / 1000, recipient, block.timestamp);
        assertApproxEqRel(out, q, QUOTE_TOLERANCE, "eth->AM quote");
        _assertHelperEmpty();

        uint256 amIn = 8000e18;
        deal(am, user, amIn);
        uint256 qe = helper.quoteAMToETH(amIn);
        vm.startPrank(user);
        IERC20(am).approve(address(helper), amIn);
        uint256 ethOut = helper.swapAMToETH(amIn, qe * 999 / 1000, payable(recipient), block.timestamp);
        vm.stopPrank();
        assertApproxEqRel(ethOut, qe, QUOTE_TOLERANCE, "AM->eth quote");
        _assertHelperEmpty();

        deal(PHUSD, user, 1000e18);
        uint256 qa = helper.quotePhUSDToAM(1000e18);
        vm.startPrank(user);
        IERC20(PHUSD).approve(address(helper), 1000e18);
        uint256 amOut = helper.swapPhUSDToAM(1000e18, qa, recipient, block.timestamp);
        vm.stopPrank();
        assertEq(amOut, qa, "phUSD->AM quote");
        _assertHelperEmpty();

        deal(am, user, 4000e18);
        uint256 qp = helper.quoteAMToPhUSD(4000e18);
        vm.startPrank(user);
        IERC20(am).approve(address(helper), 4000e18);
        uint256 phOut = helper.swapAMToPhUSD(4000e18, qp, recipient, block.timestamp);
        vm.stopPrank();
        assertEq(phOut, qp, "AM->phUSD quote");
        _assertHelperEmpty();
    }

    function test_fork_amLiquidity_addAndRemove() public {
        deal(USDS, user, 5000e18);
        deal(am, user, 4000e18);
        vm.startPrank(user);
        IERC20(USDS).approve(address(helper), 5000e18);
        IERC20(am).approve(address(helper), 4000e18);
        (uint256 uUsed,, uint256 liq) = helper.addLiquidityAMUSDS(5000e18, 4000e18, 0, 4000e18, user, block.timestamp);
        assertEq(IERC20(USDS).balanceOf(user), 5000e18 - uUsed, "USDS refund");
        assertEq(IERC20(amLp).balanceOf(user), liq, "AM LP to user");
        _assertHelperEmpty();

        IERC20(amLp).approve(address(helper), liq);
        (uint256 uOut, uint256 aOut) =
            helper.removeLiquidityAMUSDS(liq, uUsed * 999 / 1000, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertApproxEqRel(uOut, uUsed, 1e15, "USDS back");
        assertApproxEqRel(aOut, 4000e18, 1e15, "AM back");
        _assertHelperEmpty();
    }
}

interface IERC20Meta {
    function symbol() external view returns (string memory);
}
