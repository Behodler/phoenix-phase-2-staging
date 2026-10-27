// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {MockCurveRouterNG} from "../src/mocks/MockCurveRouterNG.sol";
import {MockCrvUSD} from "../src/mocks/MockCrvUSD.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockDola} from "../src/mocks/MockDola.sol";
import {MockUSDe} from "../src/mocks/MockUSDe.sol";
import {MockCurveStableSwapNG} from "../src/mocks/MockCurveStableSwapNG.sol";
import {MockCurveDolaMetaPool} from "../src/mocks/MockCurveDolaMetaPool.sol";

/// @title  MockCurveRouterNGTest
/// @notice Story 115. `MockCurveRouterNG` must deliver what Curve Router NG v1.1 delivers and revert the
///         way it reverts (sya-harvester audit 01, M-01 and its residual). Every hop runs through a real
///         pool mock, so each assertion is about real balances:
///         - an early-terminated path delivers the INTERMEDIATE token (`path[2k]` at the first empty pool
///           slot), and a trailing non-zero entry after the gap is ignored;
///         - a zero intermediate inside the executed prefix reverts with EMPTY revert data;
///         - swap_type 0 on an executed hop, and swap_type 9 (ERC4626), revert `Error("Bad swap type")`;
///         - rows / pools beyond the executed prefix are never read.
///         The route shapes are the mainnet ones: USDe -> crvUSD -> USDC (two hops) and DOLA -> USDC
///         (one hop, exchange_underlying).
contract MockCurveRouterNGTest is Test {
    MockCurveRouterNG internal router;
    MockRewardToken internal usdc;
    MockUSDe internal usde;
    MockDola internal dola;
    MockCrvUSD internal crvUSD;
    MockCurveStableSwapNG internal poolUsdeCrvusd; // coin0 USDe, coin1 crvUSD
    MockCurveStableSwapNG internal poolCrvusdUsdc; // coin0 USDC, coin1 crvUSD
    MockCurveDolaMetaPool internal poolDola; // underlying 0 DOLA, 2 USDC

    address internal receiver = makeAddr("receiver");
    uint256 internal constant AMOUNT = 1_000e18;

    function setUp() public {
        router = new MockCurveRouterNG();
        usdc = new MockRewardToken();
        usde = new MockUSDe();
        dola = new MockDola();
        crvUSD = new MockCrvUSD();
        poolUsdeCrvusd = new MockCurveStableSwapNG(address(usde), address(crvUSD));
        poolCrvusdUsdc = new MockCurveStableSwapNG(address(usdc), address(crvUSD));
        poolDola = new MockCurveDolaMetaPool(address(dola), address(usdc));

        usde.mint(address(poolUsdeCrvusd), 1_000_000e18);
        crvUSD.mint(address(poolUsdeCrvusd), 1_000_000e18);
        usdc.mint(address(poolCrvusdUsdc), 1_000_000e6);
        crvUSD.mint(address(poolCrvusdUsdc), 1_000_000e18);
        dola.mint(address(poolDola), 1_000_000e18);
        usdc.mint(address(poolDola), 1_000_000e6);

        usde.approve(address(router), type(uint256).max);
        dola.approve(address(router), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _usdePath() internal view returns (address[11] memory p) {
        p[0] = address(usde);
        p[1] = address(poolUsdeCrvusd);
        p[2] = address(crvUSD);
        p[3] = address(poolCrvusdUsdc);
        p[4] = address(usdc);
    }

    function _usdeParams() internal pure returns (uint256[5][5] memory s) {
        s[0] = [uint256(0), 1, 1, 10, 2];
        s[1] = [uint256(1), 0, 1, 1, 2];
    }

    function _call(address[11] memory path, uint256[5][5] memory params, uint256 expected)
        internal
        returns (bool ok, bytes memory ret)
    {
        address[5] memory pools;
        (ok, ret) = address(router)
            .call(abi.encodeCall(MockCurveRouterNG.exchange, (path, params, AMOUNT, expected, pools, receiver)));
    }

    function _expectedUsdeToUsdc(uint256 amount) internal view returns (uint256) {
        return poolCrvusdUsdc.get_dy(1, 0, poolUsdeCrvusd.get_dy(0, 1, amount));
    }

    // ------------------------------------------------------------------
    // happy paths: the mainnet route shapes
    // ------------------------------------------------------------------

    function test_usdeTwoHop_deliversUsdcThroughRealPools() public {
        uint256 expected = _expectedUsdeToUsdc(AMOUNT);
        uint256 usdeBefore = usde.balanceOf(address(this));
        address[5] memory pools;

        uint256 out = router.exchange(_usdePath(), _usdeParams(), AMOUNT, expected, pools, receiver);

        assertEq(out, expected, "two hops, 4 bps each, 18dp -> 6dp");
        assertEq(usdc.balanceOf(receiver), expected, "receiver paid USDC");
        assertEq(crvUSD.balanceOf(receiver), 0, "no intermediate delivered");
        assertEq(usde.balanceOf(address(this)), usdeBefore - AMOUNT, "input pulled");
        assertEq(usde.balanceOf(address(poolUsdeCrvusd)), 1_000_000e18 + AMOUNT, "hop 0 hit the USDe/crvUSD pool");
        assertEq(usdc.balanceOf(address(poolCrvusdUsdc)), 1_000_000e6 - expected, "hop 1 paid from crvUSD/USDC pool");
        assertEq(usdc.balanceOf(address(router)), 0, "router keeps nothing");
        assertEq(crvUSD.balanceOf(address(router)), 0, "router keeps nothing");
        assertEq(router.calls(address(usde)), 1);
    }

    function test_dolaOneHopExchangeUnderlying_deliversUsdc() public {
        address[11] memory path;
        path[0] = address(dola);
        path[1] = address(poolDola);
        path[2] = address(usdc);
        uint256[5][5] memory params;
        params[0] = [uint256(0), 2, 2, 1, 3];
        uint256 expected = poolDola.get_dy_underlying(0, 2, AMOUNT);
        address[5] memory pools;

        uint256 out = router.exchange(path, params, AMOUNT, expected, pools, receiver);

        assertEq(out, expected);
        assertEq(usdc.balanceOf(receiver), expected);
        assertEq(dola.balanceOf(address(poolDola)), 1_000_000e18 + AMOUNT, "exchange_underlying hit the metapool");
    }

    function test_resolveOutput_mainnetShapes() public view {
        (address out, uint256 hops) = router.resolveOutput(_usdePath());
        assertEq(out, address(usdc));
        assertEq(hops, 2);
    }

    // ------------------------------------------------------------------
    // M-01: the router stops at the FIRST empty pool slot
    // ------------------------------------------------------------------

    /// @notice `[USDe, pool, crvUSD, 0, ..., USDC]` (the M-01 shape): Router NG executes ONE hop and
    ///         delivers crvUSD. The trailing USDC in path[10] is never reached.
    function test_M01_earlyTerminatedPath_deliversIntermediate() public {
        address[11] memory path;
        path[0] = address(usde);
        path[1] = address(poolUsdeCrvusd);
        path[2] = address(crvUSD);
        path[10] = address(usdc);
        uint256[5][5] memory params;
        params[0] = [uint256(0), 1, 1, 10, 2];
        address[5] memory pools;

        (address resolved, uint256 hops) = router.resolveOutput(path);
        assertEq(resolved, address(crvUSD), "resolves the intermediate");
        assertEq(hops, 1);

        uint256 expected = poolUsdeCrvusd.get_dy(0, 1, AMOUNT);
        uint256 out = router.exchange(path, params, AMOUNT, 0, pools, receiver);

        assertEq(out, expected, "one hop's worth");
        assertEq(crvUSD.balanceOf(receiver), out, "delivered crvUSD, the intermediate");
        assertEq(usdc.balanceOf(receiver), 0, "the trailing USDC entry is never delivered");
        assertEq(usdc.balanceOf(address(poolCrvusdUsdc)), 1_000_000e6, "hop 1 never executed");
    }

    /// @notice A trailing non-zero AFTER a gap is ignored even when it sits right behind the gap:
    ///         `[USDe, pool, crvUSD, 0, USDC, 0...]` still delivers crvUSD, and a populated second
    ///         params row / pools slot is not read either.
    function test_M01_trailingNonZeroAfterGap_isIgnored() public {
        address[11] memory path;
        path[0] = address(usde);
        path[1] = address(poolUsdeCrvusd);
        path[2] = address(crvUSD);
        path[4] = address(usdc);
        uint256[5][5] memory params = _usdeParams(); // row 1 populated but unexecuted
        params[2] = [uint256(7), 7, 0, 7, 7]; // garbage in an unexecuted row, swap_type 0 included
        address[5] memory pools;
        pools[1] = address(0xdead);

        uint256 out = router.exchange(path, params, AMOUNT, 0, pools, receiver);

        assertEq(crvUSD.balanceOf(receiver), out, "delivered path[2]");
        assertEq(usdc.balanceOf(receiver), 0, "path[4] after the gap is ignored");
    }

    /// @notice A zero intermediate token inside the executed prefix reverts with EMPTY revert data,
    ///         exactly as the real router does (sya-harvester fork test
    ///         `test_fork_zeroIntermediate_realRouterReverts_mockAgrees`).
    function test_M01_zeroIntermediate_revertsWithEmptyData() public {
        address[11] memory path = _usdePath();
        path[2] = address(0); // [USDe, pool0, 0, pool1, USDC]

        (bool ok, bytes memory ret) = _call(path, _usdeParams(), 0);

        assertFalse(ok, "reverts");
        assertEq(ret.length, 0, "empty revert data");
        assertEq(usdc.balanceOf(receiver), 0);
        assertEq(crvUSD.balanceOf(receiver), 0);
    }

    function test_resolveOutput_zeroIntermediate_revertsWithEmptyData() public {
        address[11] memory path = _usdePath();
        path[2] = address(0);
        (bool ok, bytes memory ret) = address(router).call(abi.encodeCall(MockCurveRouterNG.resolveOutput, (path)));
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function test_zeroDeliveredToken_revertsWithEmptyData() public {
        address[11] memory path = _usdePath();
        path[4] = address(0); // [USDe, pool0, crvUSD, pool1, 0]: hop 1 outputs address(0)
        (bool ok, bytes memory ret) = _call(path, _usdeParams(), 0);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    // ------------------------------------------------------------------
    // swap_type dispatch
    // ------------------------------------------------------------------

    function test_swapTypeZeroOnExecutedHop_revertsBadSwapType() public {
        uint256[5][5] memory params = _usdeParams();
        params[1][2] = 0; // hop 1 (crvUSD -> USDC) executed with swap_type 0

        (bool ok, bytes memory ret) = _call(_usdePath(), params, 0);

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Bad swap type"), "Router NG's own revert");
    }

    function test_swapTypeNine_erc4626_rejected() public {
        uint256[5][5] memory params = _usdeParams();
        params[0][2] = 9;

        (bool ok, bytes memory ret) = _call(_usdePath(), params, 0);

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Bad swap type"));
    }

    function test_unmodelledSwapType_revertsLoudly() public {
        uint256[5][5] memory params = _usdeParams();
        params[0][2] = 4;
        (bool ok, bytes memory ret) = _call(_usdePath(), params, 0);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "MockCurveRouterNG: swap_type not modelled"));
    }

    // ------------------------------------------------------------------
    // misc
    // ------------------------------------------------------------------

    function test_slippage_reverts() public {
        uint256 expected = _expectedUsdeToUsdc(AMOUNT);
        (bool ok, bytes memory ret) = _call(_usdePath(), _usdeParams(), expected + 1);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Slippage"));
    }

    function test_noHop_reverts() public {
        address[11] memory path;
        path[0] = address(usdc);
        uint256[5][5] memory params;
        (bool ok, bytes memory ret) = _call(path, params, 0);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(MockCurveRouterNG.NoHop.selector));
    }

    function test_nativeEth_notModelled() public {
        address[5] memory pools;
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("MockCurveRouterNG: native ETH not modelled"));
        router.exchange{value: 1}(_usdePath(), _usdeParams(), AMOUNT, 0, pools, receiver);
    }
}
