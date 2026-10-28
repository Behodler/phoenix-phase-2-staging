// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV2Deployer, IUniswapV2FactoryLike, IUniswapV2RouterLike} from "../script/helpers/UniswapV2Deployer.sol";
import {UniswapHelperLocalStack} from "../script/helpers/UniswapHelperLocalStack.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSUSDS} from "../src/mocks/MockSUSDS.sol";
import {MockDola} from "../src/mocks/MockDola.sol";
import {MockUSDe} from "../src/mocks/MockUSDe.sol";
import {MockSkyPSM} from "../src/mocks/MockSkyPSM.sol";
import {MockUniswapV3SwapRouter} from "../src/mocks/MockUniswapV3SwapRouter.sol";
import {MockUniswapV3QuoterV2} from "../src/mocks/MockUniswapV3QuoterV2.sol";
import {MockCurveDolaMetaPool} from "../src/mocks/MockCurveDolaMetaPool.sol";
import {MockCurveStableSwapNG} from "../src/mocks/MockCurveStableSwapNG.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";
import {IUniswapV3SwapRouter} from "../src/periphery/interfaces/IUniswapV3SwapRouter.sol";
import {IQuoterV2} from "../src/periphery/interfaces/IQuoterV2.sol";
import {Antimatter} from "antimatter/Antimatter.sol";

/// @title  UniswapHelperAnvilTest
/// @notice Story 110. Deploys the anvil mock set through `UniswapHelperLocalStack` — the SAME
///         library `DeployMocks` Phase 11.8 calls — over the real `src/mocks` tokens, `MockSkyPSM`
///         and the canonical Uniswap V2 stack, seeds the phUSD/sUSDS pair, then drives every
///         UniswapHelper route in both directions plus all four liquidity operations, asserting
///         quote == actual where the helper quotes, and that the helper holds nothing afterwards.
///         Story 120: the real `Antimatter` token, with the AM/sUSDS pair created AFTER the helper is
///         deployed (DeployMocks order: helper at 11.8, AM pair at 11.10) to prove lazy resolution.
contract UniswapHelperAnvilTest is Test {
    uint256 internal constant PAIR_SEED = 50_000e18;

    MockPhUSD internal phUSD;
    MockRewardToken internal usdc;
    MockUSDS internal usds;
    MockSUSDS internal susds;
    MockDola internal dola;
    MockUSDe internal usde;
    MockSkyPSM internal psm;
    address internal weth;
    IUniswapV2FactoryLike internal factory;
    IUniswapV2RouterLike internal router;
    address internal lp;
    Antimatter internal am;
    address internal amLp;

    UniswapHelperLocalStack.Inputs internal inputs;
    MockUniswapV3SwapRouter internal v3Router;
    MockUniswapV3QuoterV2 internal v3Quoter;
    MockCurveDolaMetaPool internal curveDola;
    MockCurveStableSwapNG internal curveUsde;
    UniswapHelper internal helper;

    address internal user = makeAddr("user");
    address internal recipient = makeAddr("recipient");

    function setUp() public {
        vm.deal(address(this), 1_000 ether);
        (weth, factory, router) = UniswapV2Deployer.deploy(address(this));
        phUSD = new MockPhUSD();
        phUSD.setMinter(address(this), true);
        usdc = new MockRewardToken();
        usds = new MockUSDS();
        susds = new MockSUSDS(address(usds));
        dola = new MockDola();
        usde = new MockUSDe();
        // Same construction and USDC reserve as DeployMocks Phase 3.6.
        psm = new MockSkyPSM(address(usdc), address(usds));
        usdc.mint(address(psm), 1_000_000e6);

        // Non-unit sUSDS share price, so the ERC4626 legs round like a live vault.
        usds.approve(address(susds), type(uint256).max);
        susds.deposit(10_000e18, address(this));
        susds.addYield(537e18 + 7);

        // Seed the phUSD/sUSDS pair (DeployMocks Phase 11.7 does this on anvil, story 106).
        usds.mint(address(this), PAIR_SEED);
        uint256 shares = susds.deposit(PAIR_SEED, address(this));
        phUSD.mint(address(this), PAIR_SEED);
        lp = factory.createPair(address(susds), address(phUSD));
        IERC20(address(susds)).approve(address(router), type(uint256).max);
        phUSD.approve(address(router), type(uint256).max);
        router.addLiquidity(address(susds), address(phUSD), shares, PAIR_SEED, 0, 0, address(this), block.timestamp);

        am = new Antimatter(address(this));

        inputs = UniswapHelperLocalStack.Inputs({
            phUSD: address(phUSD),
            sUSDS: address(susds),
            usds: address(usds),
            usdc: address(usdc),
            dola: address(dola),
            usde: address(usde),
            weth: weth,
            skyPSM: address(psm),
            v2Router: address(router),
            antimatter: address(am)
        });
        UniswapHelperLocalStack.Venues memory v = UniswapHelperLocalStack.deploy(inputs);
        v3Router = v.v3Router;
        v3Quoter = v.v3Quoter;
        curveDola = v.curveDola;
        curveUsde = v.curveUsde;
        helper = v.helper;

        // AM/sUSDS pair AFTER the helper, as on anvil (Phase 11.10 after 11.8): ~3 AM per share.
        require(helper.amPair() == address(0), "AM pair must not exist yet");
        usds.mint(address(this), PAIR_SEED);
        uint256 amShares = susds.deposit(PAIR_SEED, address(this));
        am.mint(address(this), 3 * PAIR_SEED);
        amLp = factory.createPair(address(susds), address(am));
        am.approve(address(router), type(uint256).max);
        router.addLiquidity(address(susds), address(am), amShares, 3 * PAIR_SEED, 0, 0, address(this), block.timestamp);

        vm.warp(1_000_000);
    }

    // ---------------------------------------------------------------- helpers

    function _stables() internal view returns (address[5] memory) {
        return [address(susds), address(usds), address(usdc), address(dola), address(usde)];
    }

    function _amount(address token) internal view returns (uint256) {
        return token == address(usdc) ? 250_123456 : 250_123456789012345678;
    }

    function _fund(address token, address to, uint256 amt) internal {
        if (token == address(susds)) {
            uint256 assets = susds.previewMint(amt);
            usds.mint(address(this), assets);
            susds.mint(amt, to);
        } else {
            MockUSDS(token).mint(to, amt); // every mock stable shares the unrestricted mint
        }
    }

    function _assertHelperEmpty() internal view {
        address h = address(helper);
        assertEq(h.balance, 0, "helper ETH");
        assertEq(phUSD.balanceOf(h), 0, "helper phUSD");
        assertEq(usdc.balanceOf(h), 0, "helper USDC");
        assertEq(dola.balanceOf(h), 0, "helper DOLA");
        assertEq(usde.balanceOf(h), 0, "helper USDe");
        assertEq(usds.balanceOf(h), 0, "helper USDS");
        assertEq(susds.balanceOf(h), 0, "helper sUSDS");
        assertEq(IERC20(weth).balanceOf(h), 0, "helper WETH");
        assertEq(IERC20(lp).balanceOf(h), 0, "helper LP");
        assertEq(am.balanceOf(h), 0, "helper AM");
        assertEq(IERC20(amLp).balanceOf(h), 0, "helper AM LP");
    }

    // ---------------------------------------------------------------- wiring

    function test_wiring_matchesAnvilDeploy() public view {
        assertEq(helper.pair(), lp, "pair");
        assertEq(helper.antimatter(), address(am), "antimatter");
        assertEq(helper.amPair(), amLp, "amPair resolves lazily");
        assertEq(helper.skyPSM(), address(psm));
        assertEq(helper.v2Router(), address(router));
        assertEq(helper.v3SwapRouter(), address(v3Router));
        assertEq(helper.v3Quoter(), address(v3Quoter));
        assertEq(helper.curveDolaPool(), address(curveDola));
        assertEq(helper.curveUsdePool(), address(curveUsde));
        assertEq(helper.WETH(), weth);
        assertEq(helper.v3Fee(), 500);
        assertEq(curveUsde.coins(0), address(usde), "NG coin 0");
        assertEq(curveUsde.coins(1), address(usdc), "NG coin 1");
        // Both sides of every venue prefunded.
        assertEq(IERC20(weth).balanceOf(address(v3Router)), 100 ether);
        assertEq(usdc.balanceOf(address(v3Router)), 200_000e6);
        assertEq(dola.balanceOf(address(curveDola)), 1_000_000e18);
        assertEq(usdc.balanceOf(address(curveDola)), 1_000_000e6);
        assertEq(usde.balanceOf(address(curveUsde)), 1_000_000e18);
        assertEq(usdc.balanceOf(address(curveUsde)), 1_000_000e6);
        assertEq(usds.balanceOf(address(psm)), 1_000_000e18, "PSM USDS reserve");
    }

    // ---------------------------------------------------------------- swaps in

    function test_swapToPhUSD_everyStable() public {
        psm.setTin(1e15); // 0.1%: exercises the sellGem fee on the USDC-based routes
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 amt = _amount(toks[i]);
            uint256 quote = helper.quoteToPhUSD(toks[i], amt);
            _fund(toks[i], user, amt);
            uint256 before = phUSD.balanceOf(recipient);
            vm.startPrank(user);
            IERC20(toks[i]).approve(address(helper), amt);
            uint256 out = helper.swapToPhUSD(toks[i], amt, quote, recipient, block.timestamp);
            vm.stopPrank();
            assertGt(out, 0, "no phUSD");
            assertEq(out, quote, "quote != actual");
            assertEq(phUSD.balanceOf(recipient) - before, out, "recipient phUSD");
            assertEq(IERC20(toks[i]).balanceOf(user), 0, "input not pulled");
            _assertHelperEmpty();
        }
    }

    function test_swapETHToPhUSD() public {
        uint256 ethIn = 0.1 ether;
        uint256 quote = helper.quoteETHToPhUSD(ethIn);
        vm.deal(user, ethIn);
        vm.prank(user);
        uint256 out = helper.swapETHToPhUSD{value: ethIn}(quote, recipient, block.timestamp);
        assertGt(out, 0);
        assertEq(out, quote, "quote != actual");
        assertEq(phUSD.balanceOf(recipient), out);
        // 0.1 ETH at 2000 USDC/ETH less the 0.05% tier is ~199.9 USDC; through a ~1.05 sUSDS
        // share price and the ~1:1 pair that lands in a narrow phUSD band.
        assertGt(out, 180e18, "ETH value too low");
        assertLt(out, 200e18, "ETH value too high");
        _assertHelperEmpty();
    }

    // ---------------------------------------------------------------- swaps out

    function test_swapFromPhUSD_everyStable() public {
        psm.setTout(1e15); // 0.1%: exercises buyGem flooring + USDS dust refund
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 phusdIn = 250_123456789012345678;
            uint256 quote = helper.quoteFromPhUSD(toks[i], phusdIn);
            phUSD.mint(user, phusdIn);
            uint256 before = IERC20(toks[i]).balanceOf(recipient);
            vm.startPrank(user);
            phUSD.approve(address(helper), phusdIn);
            uint256 out = helper.swapFromPhUSD(toks[i], phusdIn, quote, recipient, block.timestamp);
            vm.stopPrank();
            assertGt(out, 0, "no output");
            assertEq(out, quote, "quote != actual");
            // USDC-based outputs may also refund USDS dust to the recipient, so for USDS itself
            // the recipient delta is exactly `out`; for the rest it is at least `out`.
            assertGe(IERC20(toks[i]).balanceOf(recipient) - before, out, "recipient output");
            _assertHelperEmpty();
        }
    }

    function test_swapPhUSDToETH() public {
        uint256 phusdIn = 300e18;
        uint256 quote = helper.quotePhUSDToETH(phusdIn);
        phUSD.mint(user, phusdIn);
        vm.startPrank(user);
        phUSD.approve(address(helper), phusdIn);
        uint256 out = helper.swapPhUSDToETH(phusdIn, quote, payable(recipient), block.timestamp);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(out, quote, "quote != actual");
        assertEq(recipient.balance, out, "recipient ETH");
        _assertHelperEmpty();
    }

    // ---------------------------------------------------------------- liquidity

    function test_addAndRemoveLiquidity_sUSDS() public {
        uint256 susdsAmt = 1_000e18;
        uint256 phusdAmt = 2_000e18; // over-supplied: the excess phUSD is refunded
        _fund(address(susds), user, susdsAmt);
        phUSD.mint(user, phusdAmt);

        vm.startPrank(user);
        IERC20(address(susds)).approve(address(helper), susdsAmt);
        phUSD.approve(address(helper), phusdAmt);
        (uint256 sUsed, uint256 pUsed, uint256 liq) =
            helper.addLiquiditySUSDS(susdsAmt, phusdAmt, 0, 0, user, block.timestamp);
        assertGt(liq, 0, "no LP");
        assertEq(IERC20(lp).balanceOf(user), liq);
        assertEq(susds.balanceOf(user), susdsAmt - sUsed, "sUSDS refund");
        assertEq(phUSD.balanceOf(user), phusdAmt - pUsed, "phUSD refund");
        _assertHelperEmpty();

        IERC20(lp).approve(address(helper), liq);
        (uint256 sOut, uint256 pOut) = helper.removeLiquiditySUSDS(liq, 0, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertApproxEqAbs(sOut, sUsed, 1e6, "sUSDS back");
        assertApproxEqAbs(pOut, pUsed, 1e6, "phUSD back");
        assertEq(susds.balanceOf(recipient), sOut);
        assertEq(phUSD.balanceOf(recipient), pOut);
        _assertHelperEmpty();
    }

    function test_addAndRemoveLiquidity_USDS() public {
        uint256 usdsAmt = 1_000e18;
        uint256 phusdAmt = 2_000e18;
        usds.mint(user, usdsAmt);
        phUSD.mint(user, phusdAmt);

        vm.startPrank(user);
        usds.approve(address(helper), usdsAmt);
        phUSD.approve(address(helper), phusdAmt);
        (uint256 uUsed, uint256 pUsed, uint256 liq) =
            helper.addLiquidityUSDS(usdsAmt, phusdAmt, 990e18, 0, user, block.timestamp);
        assertGt(liq, 0, "no LP");
        assertEq(IERC20(lp).balanceOf(user), liq);
        assertEq(usds.balanceOf(user), usdsAmt - uUsed, "USDS refund");
        assertEq(phUSD.balanceOf(user), phusdAmt - pUsed, "phUSD refund");
        _assertHelperEmpty();

        IERC20(lp).approve(address(helper), liq);
        (uint256 uOut, uint256 pOut) = helper.removeLiquidityUSDS(liq, 0, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertApproxEqRel(uOut, uUsed, 1e12, "USDS back");
        assertApproxEqAbs(pOut, pUsed, 1e6, "phUSD back");
        assertEq(usds.balanceOf(recipient), uOut);
        assertEq(phUSD.balanceOf(recipient), pOut);
        _assertHelperEmpty();
    }

    // ---------------------------------------------------------------- Antimatter (story 120)

    function test_swapToAM_everyStable() public {
        psm.setTin(1e15);
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 amt = _amount(toks[i]);
            uint256 quote = helper.quoteToAM(toks[i], amt);
            _fund(toks[i], user, amt);
            uint256 before = am.balanceOf(recipient);
            vm.startPrank(user);
            IERC20(toks[i]).approve(address(helper), amt);
            uint256 out = helper.swapToAM(toks[i], amt, quote, recipient, block.timestamp);
            vm.stopPrank();
            assertGt(out, 0, "no AM");
            assertEq(out, quote, "quote != actual");
            assertEq(am.balanceOf(recipient) - before, out, "recipient AM");
            assertEq(IERC20(toks[i]).balanceOf(user), 0, "input not pulled");
            _assertHelperEmpty();
        }
    }

    function test_swapFromAM_everyStable() public {
        psm.setTout(1e15);
        address[5] memory toks = _stables();
        for (uint256 i; i < toks.length; i++) {
            uint256 amIn = 750_123456789012345678;
            uint256 quote = helper.quoteFromAM(toks[i], amIn);
            am.mint(user, amIn);
            uint256 before = IERC20(toks[i]).balanceOf(recipient);
            vm.startPrank(user);
            am.approve(address(helper), amIn);
            uint256 out = helper.swapFromAM(toks[i], amIn, quote, recipient, block.timestamp);
            vm.stopPrank();
            assertGt(out, 0, "no output");
            assertEq(out, quote, "quote != actual");
            assertGe(IERC20(toks[i]).balanceOf(recipient) - before, out, "recipient output");
            _assertHelperEmpty();
        }
    }

    function test_amEthRoutes() public {
        uint256 ethIn = 0.1 ether;
        uint256 quote = helper.quoteETHToAM(ethIn);
        vm.deal(user, ethIn);
        vm.prank(user);
        uint256 out = helper.swapETHToAM{value: ethIn}(quote, recipient, block.timestamp);
        assertGt(out, 0);
        assertEq(out, quote, "eth->AM quote != actual");
        assertEq(am.balanceOf(recipient), out);
        _assertHelperEmpty();

        uint256 amIn = 900e18;
        uint256 qe = helper.quoteAMToETH(amIn);
        am.mint(user, amIn);
        vm.startPrank(user);
        am.approve(address(helper), amIn);
        uint256 ethOut = helper.swapAMToETH(amIn, qe, payable(recipient), block.timestamp);
        vm.stopPrank();
        assertGt(ethOut, 0);
        assertEq(ethOut, qe, "AM->eth quote != actual");
        assertEq(recipient.balance, ethOut, "recipient ETH");
        _assertHelperEmpty();
    }

    function test_phusdToAM() public {
        uint256 phIn = 250e18;
        uint256 q = helper.quotePhUSDToAM(phIn);
        phUSD.mint(user, phIn);
        vm.startPrank(user);
        phUSD.approve(address(helper), phIn);
        vm.expectCall(
            address(router), abi.encodeWithSelector(IUniswapV2RouterLike.swapExactTokensForTokens.selector), 1
        );
        uint256 out = helper.swapPhUSDToAM(phIn, q, recipient, block.timestamp);
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(out, q, "phUSD->AM quote != actual");
        assertEq(am.balanceOf(recipient), out);
        _assertHelperEmpty();
    }

    function test_amToPhusd() public {
        uint256 amIn = 750e18;
        uint256 qb = helper.quoteAMToPhUSD(amIn);
        am.mint(user, amIn);
        vm.startPrank(user);
        am.approve(address(helper), amIn);
        vm.expectCall(
            address(router), abi.encodeWithSelector(IUniswapV2RouterLike.swapExactTokensForTokens.selector), 1
        );
        uint256 back = helper.swapAMToPhUSD(amIn, qb, recipient, block.timestamp);
        vm.stopPrank();
        assertGt(back, 0);
        assertEq(back, qb, "AM->phUSD quote != actual");
        assertEq(phUSD.balanceOf(recipient), back);
        _assertHelperEmpty();
    }

    function test_amLiquidity_sUSDS_and_USDS() public {
        // sUSDS variant, AM over-supplied.
        _fund(address(susds), user, 1_000e18);
        am.mint(user, 6_000e18);
        vm.startPrank(user);
        IERC20(address(susds)).approve(address(helper), 1_000e18);
        am.approve(address(helper), 6_000e18);
        (uint256 sUsed, uint256 aUsed, uint256 liq) =
            helper.addLiquidityAMSUSDS(1_000e18, 6_000e18, 0, 0, user, block.timestamp);
        assertGt(liq, 0, "no AM LP");
        assertEq(IERC20(amLp).balanceOf(user), liq);
        assertEq(am.balanceOf(user), 6_000e18 - aUsed, "AM refund");
        _assertHelperEmpty();
        IERC20(amLp).approve(address(helper), liq);
        (uint256 sOut, uint256 aOut) = helper.removeLiquidityAMSUSDS(liq, 0, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertApproxEqAbs(sOut, sUsed, 1e6, "sUSDS back");
        assertApproxEqAbs(aOut, aUsed, 1e6, "AM back");
        _assertHelperEmpty();

        // USDS variant, USDS over-supplied.
        usds.mint(user, 5_000e18);
        am.mint(user, 1_500e18);
        vm.startPrank(user);
        usds.approve(address(helper), 5_000e18);
        am.approve(address(helper), 1_500e18);
        uint256 usdsBefore = usds.balanceOf(user);
        (uint256 uUsed, uint256 aUsed2, uint256 liq2) =
            helper.addLiquidityAMUSDS(5_000e18, 1_500e18, 0, 0, user, block.timestamp);
        assertEq(aUsed2, 1_500e18, "all AM used");
        assertEq(usdsBefore - usds.balanceOf(user), uUsed, "USDS refund");
        assertEq(susds.allowance(address(helper), address(router)), 0, "sUSDS allowance reset");
        assertEq(am.allowance(address(helper), address(router)), 0, "AM allowance reset");
        _assertHelperEmpty();
        IERC20(amLp).approve(address(helper), liq2);
        uint256 recipientUsds = usds.balanceOf(recipient);
        (uint256 uOut, uint256 aOut2) = helper.removeLiquidityAMUSDS(liq2, 0, 0, recipient, block.timestamp);
        vm.stopPrank();
        assertApproxEqRel(uOut, uUsed, 1e12, "USDS back");
        assertApproxEqAbs(aOut2, aUsed2, 1e6, "AM back");
        assertEq(usds.balanceOf(recipient) - recipientUsds, uOut);
        _assertHelperEmpty();
    }

    // ---------------------------------------------------------------- venue mocks

    function test_skyPSM_sellGem_tin() public {
        usdc.mint(user, 100e6);
        vm.startPrank(user);
        usdc.approve(address(psm), 100e6);
        assertEq(psm.sellGem(recipient, 40e6), 40e18, "tin 0");
        vm.stopPrank();
        psm.setTin(1e16); // 1%
        vm.prank(user);
        assertEq(psm.sellGem(recipient, 60e6), 59.4e18, "tin 1%");
        assertEq(usds.balanceOf(recipient), 99.4e18);
        assertEq(psm.tin(), 1e16);
    }

    function test_skyPSM_buyGem_unchanged() public {
        psm.setTout(2e16); // 2%
        usds.mint(user, 1_000e18);
        vm.startPrank(user);
        usds.approve(address(psm), 1_000e18);
        uint256 paid = psm.buyGem(recipient, 100e6);
        vm.stopPrank();
        assertEq(paid, 102e18, "usdsIn = gem*conv*(1+tout)");
        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(usds.balanceOf(user), 898e18);
    }

    function test_v3_quoteMatchesSwap_bothDirections() public {
        IQuoterV2.QuoteExactInputSingleParams memory q = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: weth, tokenOut: address(usdc), amountIn: 1 ether, fee: 500, sqrtPriceLimitX96: 0
        });
        (uint256 quoted,,,) = v3Quoter.quoteExactInputSingle(q);
        assertEq(quoted, 1999e6, "2000 USDC/ETH less 0.05%");

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        (bool ok,) = weth.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        IERC20(weth).approve(address(v3Router), 1 ether);
        uint256 out = v3Router.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: address(usdc),
                fee: 500,
                recipient: user,
                deadline: block.timestamp,
                amountIn: 1 ether,
                amountOutMinimum: quoted,
                sqrtPriceLimitX96: 0
            })
        );
        assertEq(out, quoted, "swap != quote");

        q = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: address(usdc), tokenOut: weth, amountIn: out, fee: 500, sqrtPriceLimitX96: 0
        });
        (quoted,,,) = v3Quoter.quoteExactInputSingle(q);
        usdc.approve(address(v3Router), out);
        uint256 back = v3Router.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: weth,
                fee: 500,
                recipient: user,
                deadline: block.timestamp,
                amountIn: out,
                amountOutMinimum: quoted,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertEq(back, quoted, "reverse swap != quote");
        assertEq(back, uint256(1999e6) * 5e26 / 1e18 * 9995 / 10_000, "round trip");
    }

    function test_v3_unconfiguredPairReverts() public {
        vm.expectRevert(bytes("MockV3Router: pair not configured"));
        v3Router.quote(address(dola), weth, 500, 1e18);
        vm.expectRevert(bytes("MockV3Router: not owner"));
        vm.prank(user);
        v3Router.setRate(weth, address(usdc), 1);
    }

    function test_curve_indicesAndDecimals() public {
        // DOLA (18dp) -> USDC (6dp), 4 bps fee.
        assertEq(curveDola.get_dy_underlying(0, 2, 100e18), 99.96e6);
        assertEq(curveDola.get_dy_underlying(2, 0, 100e6), 99.96e18);
        assertEq(curveUsde.get_dy(0, 1, 100e18), 99.96e6);
        assertEq(curveUsde.get_dy(1, 0, 100e6), 99.96e18);

        vm.expectRevert(bytes("MockCurveDolaMetaPool: only DOLA(0) <-> USDC(2)"));
        curveDola.get_dy_underlying(0, 1, 1e18);
        vm.expectRevert(bytes("MockCurveStableSwapNG: only USDe(0) <-> USDC(1)"));
        curveUsde.get_dy(0, 2, 1e18);
        vm.expectRevert(bytes("MockCurveStableSwapNG: bad coin index"));
        curveUsde.coins(2);

        dola.mint(user, 100e18);
        vm.startPrank(user);
        dola.approve(address(curveDola), 100e18);
        assertEq(curveDola.exchange_underlying(0, 2, 100e18, 99.96e6), 99.96e6);
        usdc.approve(address(curveUsde), 99.96e6);
        assertEq(curveUsde.exchange(1, 0, 99.96e6, 0), uint256(99.96e18) * 9996 / 10_000);
        vm.stopPrank();
        assertEq(usde.balanceOf(user), uint256(99.96e18) * 9996 / 10_000);
    }

    // ---------------------------------------------------------------- demo balances

    function test_topUpDemoBalances_mintsOnlyTheShortfall() public {
        address who = makeAddr("demo");
        dola.mint(who, 4_000e18); // partial existing balance
        UniswapHelperLocalStack.topUpDemoBalances(inputs, address(this), who, 10_000e18, 10_000e6);
        assertEq(dola.balanceOf(who), 10_000e18, "DOLA");
        assertEq(usde.balanceOf(who), 10_000e18, "USDe");
        assertEq(usds.balanceOf(who), 10_000e18, "USDS");
        assertEq(usdc.balanceOf(who), 10_000e6, "USDC");
        assertEq(susds.balanceOf(who), 10_000e18, "sUSDS");

        // Idempotent: a second call mints nothing.
        UniswapHelperLocalStack.topUpDemoBalances(inputs, address(this), who, 10_000e18, 10_000e6);
        assertEq(dola.balanceOf(who), 10_000e18);
        assertEq(susds.balanceOf(who), 10_000e18);
    }
}
