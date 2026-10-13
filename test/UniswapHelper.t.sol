// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV2Deployer, IUniswapV2FactoryLike, IUniswapV2RouterLike} from "../script/helpers/UniswapV2Deployer.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSUSDS} from "../src/mocks/MockSUSDS.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";
import {IUniswapV3SwapRouter} from "../src/periphery/interfaces/IUniswapV3SwapRouter.sol";
import {IQuoterV2} from "../src/periphery/interfaces/IQuoterV2.sol";
import {IWETH} from "../src/periphery/interfaces/IWETH.sol";
import {IUniswapV2RouterPeriphery} from "../src/periphery/interfaces/IUniswapV2RouterPeriphery.sol";

// ============================================================================
// Local stubs. Deliberately test-only: story 110 owns src/mocks (MockSkyPSM, V3/Curve mocks).
// All venues are fixed-rate and mint their output, so quotes match swaps exactly.
// ============================================================================

contract StubToken is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, uint8 d) ERC20(n, n) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function burn(address from, uint256 amt) external {
        _burn(from, amt);
    }
}

/// @dev DssLitePsm math: sellGem out = gem*conv - fee(tin); buyGem in = gem*conv*(WAD+tout)/WAD.
contract StubPSM {
    uint256 internal constant WAD = 1e18;
    StubToken public immutable gemToken;
    MockUSDS public immutable usdsToken;
    uint256 public tin;
    uint256 public tout;

    constructor(StubToken gem_, MockUSDS usds_) {
        gemToken = gem_;
        usdsToken = usds_;
    }

    function to18ConversionFactor() external pure returns (uint256) {
        return 1e12;
    }

    function setFees(uint256 tin_, uint256 tout_) external {
        tin = tin_;
        tout = tout_;
    }

    function sellGem(address usr, uint256 gemAmt) external returns (uint256 out) {
        gemToken.transferFrom(msg.sender, address(this), gemAmt);
        out = gemAmt * 1e12;
        out -= out * tin / WAD;
        usdsToken.mint(usr, out);
    }

    function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsIn) {
        require(gemAmt > 0, "zero gemAmt");
        usdsIn = gemAmt * 1e12 * (WAD + tout) / WAD;
        usdsToken.transferFrom(msg.sender, address(this), usdsIn);
        gemToken.mint(usr, gemAmt);
    }
}

/// @dev Fixed-rate 18dp <-> 6dp stable venue with a 4 bps fee.
abstract contract StubCurveBase {
    StubToken public immutable t18;
    StubToken public immutable t6;

    constructor(StubToken a18, StubToken a6) {
        t18 = a18;
        t6 = a6;
    }

    function _dy(bool from18, uint256 dx) internal pure returns (uint256) {
        uint256 raw = from18 ? dx / 1e12 : dx * 1e12;
        return raw - raw * 4 / 10_000;
    }

    function _swap(bool from18, uint256 dx, uint256 minDy) internal returns (uint256 dy) {
        (StubToken a, StubToken b) = from18 ? (t18, t6) : (t6, t18);
        a.transferFrom(msg.sender, address(this), dx);
        dy = _dy(from18, dx);
        require(dy >= minDy, "curve slippage");
        b.mint(msg.sender, dy);
    }
}

contract StubCurveMeta is StubCurveBase {
    constructor(StubToken dola, StubToken usdc) StubCurveBase(dola, usdc) {}

    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256) {
        require((i == 0 && j == 2) || (i == 2 && j == 0), "bad idx");
        return _swap(i == 0, dx, minDy);
    }

    function get_dy_underlying(int128 i, int128, uint256 dx) external pure returns (uint256) {
        return _dy(i == 0, dx);
    }
}

contract StubCurveNG is StubCurveBase {
    constructor(StubToken usde, StubToken usdc) StubCurveBase(usde, usdc) {}

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? address(t18) : address(t6);
    }

    function exchange(int128 i, int128, uint256 dx, uint256 minDy) external returns (uint256) {
        return _swap(i == 0, dx, minDy);
    }

    function get_dy(int128 i, int128, uint256 dx) external pure returns (uint256) {
        return _dy(i == 0, dx);
    }
}

/// @dev Fixed 2000 USDC/ETH, 5 bps fee. Holds a WETH reserve for USDC -> WETH.
contract StubV3Router {
    address public immutable weth;
    StubToken public immutable usdc;

    constructor(address weth_, StubToken usdc_) {
        weth = weth_;
        usdc = usdc_;
    }

    function out(address tokenIn, uint256 amountIn) public view returns (uint256 o) {
        o = tokenIn == weth ? amountIn * 2000 / 1e12 : amountIn * 1e12 / 2000;
        o -= o * 5 / 10_000;
    }

    function exactInputSingle(IUniswapV3SwapRouter.ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 o)
    {
        require(block.timestamp <= p.deadline, "v3 expired");
        require(p.fee == 500, "fee tier");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        o = out(p.tokenIn, p.amountIn);
        require(o >= p.amountOutMinimum, "v3 slippage");
        if (p.tokenOut == weth) IERC20(weth).transfer(p.recipient, o);
        else usdc.mint(p.recipient, o);
    }
}

contract StubQuoter {
    StubV3Router public immutable router;

    constructor(StubV3Router r) {
        router = r;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory p)
        external
        view
        returns (uint256, uint160, uint32, uint256)
    {
        return (router.out(p.tokenIn, p.amountIn), 0, 0, 0);
    }
}

contract Rejecter {}

// ============================================================================

contract UniswapHelperTest is Test {
    uint256 internal constant SEED = 1_000_000e18;

    UniswapHelper internal helper;
    StubToken internal phUSD;
    StubToken internal usdc;
    StubToken internal dola;
    StubToken internal usde;
    MockUSDS internal usds;
    MockSUSDS internal susds;
    address internal weth;
    StubPSM internal psm;
    StubCurveMeta internal curveDola;
    StubCurveNG internal curveUsde;
    StubV3Router internal v3;
    StubQuoter internal quoter;
    IUniswapV2FactoryLike internal factory;
    IUniswapV2RouterLike internal router;
    address internal lp;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        (weth, factory, router) = UniswapV2Deployer.deploy(address(this));
        phUSD = new StubToken("phUSD", 18);
        usdc = new StubToken("USDC", 6);
        dola = new StubToken("DOLA", 18);
        usde = new StubToken("USDe", 18);
        usds = new MockUSDS();
        susds = new MockSUSDS(address(usds));
        psm = new StubPSM(usdc, usds);
        curveDola = new StubCurveMeta(dola, usdc);
        curveUsde = new StubCurveNG(usde, usdc);
        v3 = new StubV3Router(weth, usdc);
        quoter = new StubQuoter(v3);

        // WETH reserve for the V3 stub's USDC -> WETH leg.
        vm.deal(address(this), 1000 ether);
        IWETH(weth).deposit{value: 1000 ether}();
        IERC20(weth).transfer(address(v3), 1000 ether);

        // Non-unit sUSDS share price so previewDeposit/redeem rounding is exercised.
        usds.approve(address(susds), type(uint256).max);
        susds.deposit(100e18, address(this));
        susds.addYield(7e18 + 3);

        helper = _deployHelper(address(router));

        // Seed the phUSD/sUSDS pair (~1:1.07 value).
        usds.mint(address(this), 2 * SEED);
        uint256 shares = susds.deposit(2 * SEED, address(this));
        phUSD.mint(address(this), 2 * SEED);
        lp = factory.createPair(address(susds), address(phUSD));
        IERC20(address(susds)).approve(address(router), type(uint256).max);
        phUSD.approve(address(router), type(uint256).max);
        router.addLiquidity(address(susds), address(phUSD), shares, 2 * SEED, 0, 0, address(this), block.timestamp);

        vm.warp(1_000_000);
    }

    function _deployHelper(address v2) internal returns (UniswapHelper) {
        return new UniswapHelper(
            address(phUSD),
            address(susds),
            address(usds),
            address(usdc),
            address(dola),
            address(usde),
            weth,
            address(psm),
            v2,
            address(v3),
            address(quoter),
            address(curveDola),
            address(curveUsde),
            500
        );
    }

    // ---------------------------------------------------------------- helpers

    function _stables() internal view returns (address[5] memory) {
        return [address(susds), address(usds), address(usdc), address(dola), address(usde)];
    }

    function _fund(address token, address to, uint256 amt) internal {
        if (token == address(susds)) {
            usds.mint(address(this), amt * 2);
            uint256 s = susds.deposit(amt * 2, address(this));
            require(s >= amt, "fund");
            IERC20(address(susds)).transfer(to, amt);
        } else if (token == address(usds)) {
            usds.mint(to, amt);
        } else {
            StubToken(token).mint(to, amt);
        }
    }

    function _amount(address token) internal view returns (uint256) {
        return token == address(usdc) ? 1234_567891 : 1234_567891234567891234;
    }

    function _assertHelperEmpty() internal view {
        address h = address(helper);
        assertEq(address(h).balance, 0, "helper ETH");
        assertEq(phUSD.balanceOf(h), 0, "helper phUSD");
        assertEq(usdc.balanceOf(h), 0, "helper USDC");
        assertEq(dola.balanceOf(h), 0, "helper DOLA");
        assertEq(usde.balanceOf(h), 0, "helper USDe");
        assertEq(usds.balanceOf(h), 0, "helper USDS");
        assertEq(susds.balanceOf(h), 0, "helper sUSDS");
        assertEq(IERC20(weth).balanceOf(h), 0, "helper WETH");
        assertEq(IERC20(lp).balanceOf(h), 0, "helper LP");
    }

    function _swapIn(address token, uint256 amt, uint256 minOut) internal returns (uint256) {
        _fund(token, user, amt);
        vm.startPrank(user);
        IERC20(token).approve(address(helper), amt);
        uint256 out = helper.swapToPhUSD(token, amt, minOut, recipient, block.timestamp);
        vm.stopPrank();
        return out;
    }

    function _swapOut(address token, uint256 phusdIn, uint256 minOut) internal returns (uint256) {
        phUSD.mint(user, phusdIn);
        vm.startPrank(user);
        phUSD.approve(address(helper), phusdIn);
        uint256 out = helper.swapFromPhUSD(token, phusdIn, minOut, recipient, block.timestamp);
        vm.stopPrank();
        return out;
    }

    // ---------------------------------------------------------------- swaps

    function test_swapToPhUSD_everyStable_quoteMatches() public {
        psm.setFees(1e15, 0); // 0.1% tin
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 amt = _amount(toks[i]);
            uint256 quote = helper.quoteToPhUSD(toks[i], amt);
            uint256 before = phUSD.balanceOf(recipient);
            uint256 out = _swapIn(toks[i], amt, quote);
            assertGt(out, 0, "no phUSD");
            assertEq(out, quote, "quote != actual");
            assertEq(phUSD.balanceOf(recipient) - before, out, "recipient phUSD");
            _assertHelperEmpty();
        }
    }

    function test_swapFromPhUSD_everyStable_quoteMatches() public {
        psm.setFees(0, 1e15 + 7); // odd tout: exercises flooring
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 amt = 1000e18 + 123_456_789;
            uint256 quote = helper.quoteFromPhUSD(toks[i], amt);
            uint256 before = IERC20(toks[i]).balanceOf(recipient);
            uint256 out = _swapOut(toks[i], amt, quote);
            assertGt(out, 0, "no output");
            assertEq(out, quote, "quote != actual");
            if (toks[i] != address(usds)) {
                assertEq(IERC20(toks[i]).balanceOf(recipient) - before, out, "recipient out");
            }
            _assertHelperEmpty();
        }
    }

    function test_ethRoutes_bothDirections() public {
        vm.deal(user, 2 ether);
        uint256 q = helper.quoteETHToPhUSD(1 ether);
        vm.prank(user);
        uint256 out = helper.swapETHToPhUSD{value: 1 ether}(q, recipient, block.timestamp);
        assertEq(out, q, "eth->phUSD quote");
        assertEq(phUSD.balanceOf(recipient), out);
        _assertHelperEmpty();

        uint256 phIn = 3000e18;
        uint256 qe = helper.quotePhUSDToETH(phIn);
        phUSD.mint(user, phIn);
        vm.startPrank(user);
        phUSD.approve(address(helper), phIn);
        uint256 ethOut = helper.swapPhUSDToETH(phIn, qe, payable(recipient), block.timestamp);
        vm.stopPrank();
        assertGt(ethOut, 1 ether, "eth out");
        assertEq(ethOut, qe, "phUSD->eth quote");
        assertEq(recipient.balance, ethOut, "recipient ETH");
        _assertHelperEmpty();
    }

    function test_unsupportedToken_reverts() public {
        address[3] memory bad = [address(phUSD), weth, makeAddr("random")];
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(UniswapHelper.UnsupportedToken.selector, bad[i]));
            helper.swapToPhUSD(bad[i], 1e18, 0, recipient, block.timestamp);
            vm.expectRevert(abi.encodeWithSelector(UniswapHelper.UnsupportedToken.selector, bad[i]));
            helper.swapFromPhUSD(bad[i], 1e18, 0, recipient, block.timestamp);
            vm.expectRevert(abi.encodeWithSelector(UniswapHelper.UnsupportedToken.selector, bad[i]));
            helper.quoteToPhUSD(bad[i], 1e18);
            vm.expectRevert(abi.encodeWithSelector(UniswapHelper.UnsupportedToken.selector, bad[i]));
            helper.quoteFromPhUSD(bad[i], 1e18);
        }
    }

    function test_deadline_reverts() public {
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.swapToPhUSD(address(usds), 1e18, 0, recipient, past);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.swapFromPhUSD(address(usds), 1e18, 0, recipient, past);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.swapETHToPhUSD{value: 0}(0, recipient, past);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.swapPhUSDToETH(1e18, 0, payable(recipient), past);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.addLiquiditySUSDS(1, 1, 0, 0, recipient, past);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.addLiquidityUSDS(1, 1, 0, 0, recipient, past);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.removeLiquidityUSDS(1, 0, 0, recipient, past);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.Expired.selector, past, block.timestamp));
        helper.removeLiquiditySUSDS(1, 0, 0, recipient, past);
    }

    function test_minOut_reverts() public {
        uint256 amt = 500e18;
        uint256 q = helper.quoteToPhUSD(address(usds), amt);
        usds.mint(user, amt);
        vm.startPrank(user);
        usds.approve(address(helper), amt);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.InsufficientOutput.selector, q, q + 1));
        helper.swapToPhUSD(address(usds), amt, q + 1, recipient, block.timestamp);
        vm.stopPrank();

        uint256 qo = helper.quoteFromPhUSD(address(usdc), amt);
        phUSD.mint(user, amt);
        vm.startPrank(user);
        phUSD.approve(address(helper), amt);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.InsufficientOutput.selector, qo, qo + 1));
        helper.swapFromPhUSD(address(usdc), amt, qo + 1, recipient, block.timestamp);
        vm.stopPrank();

        vm.deal(user, 1 ether);
        uint256 qe = helper.quoteETHToPhUSD(1 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(UniswapHelper.InsufficientOutput.selector, qe, qe + 1));
        helper.swapETHToPhUSD{value: 1 ether}(qe + 1, recipient, block.timestamp);
    }

    function test_zeroAmountAndRecipient_revert() public {
        vm.expectRevert(UniswapHelper.ZeroAmount.selector);
        helper.swapToPhUSD(address(usds), 0, 0, recipient, block.timestamp);
        vm.expectRevert(UniswapHelper.ZeroAmount.selector);
        helper.swapETHToPhUSD{value: 0}(0, recipient, block.timestamp);
        vm.expectRevert(UniswapHelper.ZeroAddress.selector);
        helper.swapFromPhUSD(address(usds), 1, 0, address(0), block.timestamp);
    }

    // ---------------------------------------------------------------- PSM buyGem flooring

    /// @dev The gem amount must be the largest the USDS budget covers at `tout`, floored: the PSM
    ///      never pulls more than the budget, and one more gem unit would exceed it.
    function testFuzz_psmGemForUsds_floors(uint256 budget, uint256 tout) public {
        budget = bound(budget, 0, 1e30);
        tout = bound(tout, 0, 5e16);
        psm.setFees(0, tout);
        uint256 gem = helper.psmGemForUsds(budget);
        assertLe(gem * 1e12 * (1e18 + tout) / 1e18, budget, "over-requests USDS");
        assertGt((gem + 1) * 1e12 * (1e18 + tout) / 1e18, budget, "not the largest gem amount");
    }

    function test_buyGem_dustRefundedToRecipient() public {
        psm.setFees(0, 1e15 + 7);
        uint256 phIn = 777e18 + 1;
        uint256 shares = IUniswapV2RouterPeriphery(address(router)).getAmountsOut(phIn, _path())[1];
        uint256 usdsBudget = susds.previewRedeem(shares);
        uint256 gem = helper.psmGemForUsds(usdsBudget);
        uint256 spent = gem * 1e12 * (1e18 + 1e15 + 7) / 1e18;
        assertGt(usdsBudget - spent, 0, "test needs non-zero dust");

        uint256 psmBefore = usds.balanceOf(address(psm));
        uint256 out = _swapOut(address(usdc), phIn, 0);
        assertEq(out, gem, "USDC out");
        assertEq(usds.balanceOf(address(psm)) - psmBefore, spent, "PSM pulled more than floored amount");
        assertEq(usds.balanceOf(recipient), usdsBudget - spent, "dust not refunded");
        _assertHelperEmpty();
    }

    function _path() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(phUSD);
        p[1] = address(susds);
    }

    // ---------------------------------------------------------------- receive()

    function test_receive_rejectsNonWeth() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok, bytes memory ret) = address(helper).call{value: 1 ether}("");
        assertFalse(ok, "accepted ETH from non-WETH");
        assertEq(ret, abi.encodeWithSelector(UniswapHelper.ETHNotAccepted.selector, user));
    }

    function test_receive_acceptsWeth() public {
        vm.deal(weth, 1 ether);
        vm.prank(weth);
        (bool ok,) = address(helper).call{value: 1 ether}("");
        assertTrue(ok, "rejected WETH");
    }

    function test_swapPhUSDToETH_revertsIfRecipientRejectsETH() public {
        Rejecter r = new Rejecter();
        phUSD.mint(user, 3000e18);
        vm.startPrank(user);
        phUSD.approve(address(helper), 3000e18);
        vm.expectRevert(UniswapHelper.ETHTransferFailed.selector);
        helper.swapPhUSDToETH(3000e18, 0, payable(address(r)), block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- liquidity

    function test_liquidity_revertsWithoutPair() public {
        (, IUniswapV2FactoryLike f2, IUniswapV2RouterLike r2) = UniswapV2Deployer.deploy(address(this));
        UniswapHelper h2 = _deployHelper(address(r2));
        assertEq(h2.pair(), address(0));
        vm.expectRevert(UniswapHelper.PairNotFound.selector);
        h2.addLiquiditySUSDS(1e18, 1e18, 0, 0, recipient, block.timestamp);
        vm.expectRevert(UniswapHelper.PairNotFound.selector);
        h2.addLiquidityUSDS(1e18, 1e18, 0, 0, recipient, block.timestamp);
        vm.expectRevert(UniswapHelper.PairNotFound.selector);
        h2.removeLiquidityUSDS(1e18, 0, 0, recipient, block.timestamp);
        vm.expectRevert(UniswapHelper.PairNotFound.selector);
        h2.removeLiquiditySUSDS(1e18, 0, 0, recipient, block.timestamp);
        assertEq(f2.getPair(address(susds), address(phUSD)), address(0), "helper created the pair");
    }

    function test_addLiquiditySUSDS_refundsLeftovers() public {
        uint256 sDesired = 1000e18;
        uint256 pDesired = 5000e18; // far more phUSD than the ratio needs
        _fund(address(susds), user, sDesired);
        phUSD.mint(user, pDesired);
        vm.startPrank(user);
        IERC20(address(susds)).approve(address(helper), sDesired);
        phUSD.approve(address(helper), pDesired);
        (uint256 sUsed, uint256 pUsed, uint256 liq) =
            helper.addLiquiditySUSDS(sDesired, pDesired, sDesired, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertEq(sUsed, sDesired, "sUSDS used");
        assertLt(pUsed, pDesired, "phUSD should be partly unused");
        assertEq(IERC20(lp).balanceOf(recipient), liq, "LP to recipient");
        assertEq(susds.balanceOf(recipient), 0);
        assertEq(phUSD.balanceOf(recipient), pDesired - pUsed, "phUSD refund");
        _assertHelperEmpty();
    }

    function test_addLiquiditySUSDS_minEnforced() public {
        _fund(address(susds), user, 1000e18);
        phUSD.mint(user, 5000e18);
        vm.startPrank(user);
        IERC20(address(susds)).approve(address(helper), 1000e18);
        phUSD.approve(address(helper), 5000e18);
        vm.expectRevert(); // Router02: INSUFFICIENT_B_AMOUNT
        helper.addLiquiditySUSDS(1000e18, 5000e18, 0, 5000e18, recipient, block.timestamp);
        vm.stopPrank();
    }

    function test_addLiquidityUSDS_wrapsAndRefundsUSDS() public {
        uint256 uDesired = 5000e18; // far more USDS than the ratio needs
        uint256 pDesired = 1000e18;
        usds.mint(user, uDesired);
        phUSD.mint(user, pDesired);
        vm.startPrank(user);
        usds.approve(address(helper), uDesired);
        phUSD.approve(address(helper), pDesired);
        (uint256 uUsed, uint256 pUsed, uint256 liq) =
            helper.addLiquidityUSDS(uDesired, pDesired, 0, pDesired, recipient, block.timestamp);
        vm.stopPrank();
        assertEq(pUsed, pDesired, "phUSD used");
        assertLt(uUsed, uDesired, "USDS should be partly unused");
        assertEq(usds.balanceOf(recipient), uDesired - uUsed, "USDS refund");
        assertEq(susds.balanceOf(recipient), 0, "refund must be USDS, not sUSDS");
        assertEq(IERC20(lp).balanceOf(recipient), liq, "LP to recipient");
        _assertHelperEmpty();
    }

    function test_addLiquidityUSDS_usdsMinConvertedToShares() public {
        usds.mint(user, 5000e18);
        phUSD.mint(user, 1000e18);
        vm.startPrank(user);
        usds.approve(address(helper), 5000e18);
        phUSD.approve(address(helper), 1000e18);
        vm.expectRevert(); // Router02: INSUFFICIENT_A_AMOUNT (share min from previewDeposit(usdsMin))
        helper.addLiquidityUSDS(5000e18, 1000e18, 5000e18, 0, recipient, block.timestamp);
        vm.stopPrank();
    }

    function test_removeLiquidityUSDS() public {
        // Recipient-of-LP is `user` this time so it can remove.
        usds.mint(user, 1000e18);
        phUSD.mint(user, 1000e18);
        vm.startPrank(user);
        usds.approve(address(helper), 1000e18);
        phUSD.approve(address(helper), 1000e18);
        (,, uint256 liq) = helper.addLiquidityUSDS(1000e18, 1000e18, 0, 0, user, block.timestamp);

        IERC20(lp).approve(address(helper), liq);
        vm.expectPartialRevert(UniswapHelper.InsufficientOutput.selector);
        helper.removeLiquidityUSDS(liq, 0, type(uint256).max, recipient, block.timestamp);

        (uint256 uOut, uint256 pOut) = helper.removeLiquidityUSDS(liq, 0, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertGt(uOut, 0);
        assertGt(pOut, 0);
        assertEq(usds.balanceOf(recipient), uOut, "USDS to recipient");
        assertEq(phUSD.balanceOf(recipient), pOut, "phUSD to recipient");
        assertEq(susds.balanceOf(recipient), 0, "sUSDS must be unwrapped");
        _assertHelperEmpty();
    }

    function test_removeLiquidityUSDS_usdsMinEnforced() public {
        usds.mint(user, 1000e18);
        phUSD.mint(user, 1000e18);
        vm.startPrank(user);
        usds.approve(address(helper), 1000e18);
        phUSD.approve(address(helper), 1000e18);
        (,, uint256 liq) = helper.addLiquidityUSDS(1000e18, 1000e18, 0, 0, user, block.timestamp);
        IERC20(lp).approve(address(helper), liq);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapHelper.InsufficientOutput.selector, _previewRemoveUsds(liq), type(uint256).max
            )
        );
        helper.removeLiquidityUSDS(liq, type(uint256).max, 0, recipient, block.timestamp);
        vm.stopPrank();
    }

    function test_removeLiquiditySUSDS() public {
        _fund(address(susds), user, 1000e18);
        phUSD.mint(user, 2000e18);
        vm.startPrank(user);
        IERC20(address(susds)).approve(address(helper), 1000e18);
        phUSD.approve(address(helper), 2000e18);
        (,, uint256 liq) = helper.addLiquiditySUSDS(1000e18, 2000e18, 0, 0, user, block.timestamp);
        uint256 phusdBack = phUSD.balanceOf(user);
        IERC20(lp).approve(address(helper), liq);

        vm.expectPartialRevert(UniswapHelper.InsufficientOutput.selector);
        helper.removeLiquiditySUSDS(liq, type(uint256).max, 0, recipient, block.timestamp);
        vm.expectPartialRevert(UniswapHelper.InsufficientOutput.selector);
        helper.removeLiquiditySUSDS(liq, 0, type(uint256).max, recipient, block.timestamp);

        (uint256 sOut, uint256 pOut) = helper.removeLiquiditySUSDS(liq, 0, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertApproxEqAbs(sOut, 1000e18, 2, "sUSDS back");
        assertApproxEqAbs(pOut, 2000e18 - phusdBack, 2, "phUSD back");
        assertEq(susds.balanceOf(recipient), sOut, "sUSDS to recipient");
        assertEq(phUSD.balanceOf(recipient), pOut, "phUSD to recipient");
        assertEq(IERC20(lp).balanceOf(user), 0, "LP burned");
        _assertHelperEmpty();
    }

    function _previewRemoveUsds(uint256 liq) internal view returns (uint256) {
        uint256 bal = susds.balanceOf(lp);
        uint256 shares = liq * bal / IERC20(lp).totalSupply();
        return susds.previewRedeem(shares);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(UniswapHelper.ZeroAddress.selector);
        new UniswapHelper(
            address(0),
            address(susds),
            address(usds),
            address(usdc),
            address(dola),
            address(usde),
            weth,
            address(psm),
            address(router),
            address(v3),
            address(quoter),
            address(curveDola),
            address(curveUsde),
            500
        );
    }

    function test_constructor_rejectsCurveCoinMismatch() public {
        StubCurveNG swapped = new StubCurveNG(dola, usdc); // coin 0 = DOLA, not USDe
        vm.expectRevert(UniswapHelper.CurveCoinMismatch.selector);
        new UniswapHelper(
            address(phUSD),
            address(susds),
            address(usds),
            address(usdc),
            address(dola),
            address(usde),
            weth,
            address(psm),
            address(router),
            address(v3),
            address(quoter),
            address(curveDola),
            address(swapped),
            500
        );
    }

    receive() external payable {}
}
