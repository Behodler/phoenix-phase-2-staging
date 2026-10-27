// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {ICurveRouterNG} from "sya-harvester/interfaces/ICurveRouterNG.sol";
import {SyaHarvesterLocalStack} from "../script/helpers/SyaHarvesterLocalStack.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockDola} from "../src/mocks/MockDola.sol";
import {MockUSDe} from "../src/mocks/MockUSDe.sol";
import {MockCurveDolaMetaPool} from "../src/mocks/MockCurveDolaMetaPool.sol";

/// @notice The one SYA read `setRoute` / `setEthPool` make. Story 116 wires the real SYA.
contract RewardTokenOnlySYA {
    address public rewardToken;

    constructor(address usdc) {
        rewardToken = usdc;
    }
}

/// @title  SyaHarvesterLocalStackTest
/// @notice Story 115. Deploys the anvil harvester infrastructure through `SyaHarvesterLocalStack`, the SAME
///         library `DeployMocks` Phase 11.11 calls, and proves it is what SYAHarvester (lib/sya-harvester,
///         pin 6b862aa, compiled here under phStaging2's via_ir / solc 0.8.30 profile) needs:
///         - SYAHarvester's M-01-hardened `setRoute` accepts the local DOLA and USDe routes and its
///           `setEthPool` accepts the local ETH/USDC key;
///         - the router delivers USDC for both stored routes through the real pool mocks;
///         - the V4 ETH/USDC pool is initialised at 2000 USDC/ETH with the full-range seed, and a
///           harvest-sized USDC -> ETH swap pays far more ETH than `(gasUsed + 60_000) * tx.gasprice`
///           at a generous anvil gas price.
contract SyaHarvesterLocalStackTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockRewardToken internal usdc;
    MockDola internal dola;
    MockUSDe internal usde;
    MockCurveDolaMetaPool internal curveDola;
    SyaHarvesterLocalStack.Infra internal s;
    SYAHarvester internal harvester;

    address internal owner = makeAddr("owner");

    receive() external payable {}

    function setUp() public {
        usdc = new MockRewardToken();
        dola = new MockDola();
        usde = new MockUSDe();
        curveDola = new MockCurveDolaMetaPool(address(dola), address(usdc));
        dola.mint(address(curveDola), 1_000_000e18);
        usdc.mint(address(curveDola), 1_000_000e6);

        vm.deal(address(this), 1_000 ether);
        s = SyaHarvesterLocalStack.deploy(
            SyaHarvesterLocalStack.Inputs({
                usdc: address(usdc),
                dola: address(dola),
                usde: address(usde),
                curveDola: address(curveDola),
                poolManagerOwner: owner,
                payer: address(this)
            })
        );

        harvester = new SYAHarvester(
            owner,
            s.poolManager,
            IStableYieldAccumulator(address(new RewardTokenOnlySYA(address(usdc)))),
            ICurveRouterNG(address(s.router))
        );
    }

    function _usde() internal view returns (SyaHarvesterLocalStack.Route memory) {
        return SyaHarvesterLocalStack.usdeRoute(s, address(usde), address(usdc));
    }

    function _dola() internal view returns (SyaHarvesterLocalStack.Route memory) {
        return SyaHarvesterLocalStack.dolaRoute(address(curveDola), address(dola), address(usdc));
    }

    // ------------------------------------------------------------------
    // SYAHarvester accepts the local shapes
    // ------------------------------------------------------------------

    function test_harvesterAcceptsLocalRoutesAndEthPool() public {
        SyaHarvesterLocalStack.Route memory u = _usde();
        SyaHarvesterLocalStack.Route memory d = _dola();

        vm.startPrank(owner);
        harvester.setRoute(u.token, u.path, u.swapParams, u.pools);
        harvester.setRoute(d.token, d.path, d.swapParams, d.pools);
        harvester.setEthPool(s.ethPoolKey);
        vm.stopPrank();

        SYAHarvester.CurveRoute memory r = harvester.getRoute(address(usde));
        assertTrue(r.configured);
        assertEq(r.path[2], address(s.crvUSD), "two-hop USDe route stored");
        assertEq(r.path[4], address(usdc));
        assertTrue(harvester.getRoute(address(dola)).configured);
        PoolKey memory k = harvester.getEthPool();
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), address(usdc));
        assertEq(k.fee, 3000);
        assertEq(k.tickSpacing, 60);
        assertEq(address(k.hooks), address(0));
    }

    /// @notice The harvester's validator, run against the local stack, rejects the M-01 shape the router
    ///         mock would execute "successfully" (delivering crvUSD).
    function test_harvesterRejectsM01ShapeOnLocalStack() public {
        SyaHarvesterLocalStack.Route memory u = _usde();
        u.path[3] = address(0); // [USDe, pool, crvUSD, 0, USDC]
        u.swapParams[1] = [uint256(0), 0, 0, 0, 0];

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteGap.selector, uint256(4)));
        harvester.setRoute(u.token, u.path, u.swapParams, u.pools);
    }

    // ------------------------------------------------------------------
    // The stored routes execute through the router
    // ------------------------------------------------------------------

    function test_routerSellsBothRoutesToUsdc() public {
        SyaHarvesterLocalStack.Route memory u = _usde();
        SyaHarvesterLocalStack.Route memory d = _dola();
        address seller = makeAddr("seller");
        usde.mint(seller, 1_000e18);
        dola.mint(seller, 500e18);

        vm.startPrank(seller);
        usde.approve(address(s.router), type(uint256).max);
        dola.approve(address(s.router), type(uint256).max);
        uint256 outU = s.router.exchange(u.path, u.swapParams, 1_000e18, 0, u.pools, seller);
        uint256 outD = s.router.exchange(d.path, d.swapParams, 500e18, 0, d.pools, seller);
        vm.stopPrank();

        // 4 bps per hop: two hops for USDe, one for DOLA
        assertApproxEqAbs(outU, 999_200_000, 1_000, "~999.2 USDC");
        assertApproxEqAbs(outD, 499_800_000, 1_000, "~499.8 USDC");
        assertEq(usdc.balanceOf(seller), outU + outD);
        assertEq(usde.balanceOf(seller), 0);
        assertEq(dola.balanceOf(seller), 0);
    }

    // ------------------------------------------------------------------
    // Uniswap V4
    // ------------------------------------------------------------------

    function test_ethPool_initialisedAndSeeded() public view {
        PoolId id = s.ethPoolKey.toId();
        (uint160 sqrtPriceX96,,,) = s.poolManager.getSlot0(id);
        assertEq(sqrtPriceX96, SyaHarvesterLocalStack.SQRT_PRICE_2000_USDC_PER_ETH);
        assertEq(s.poolManager.getLiquidity(id), s.ethPoolLiquidity);
        assertGt(s.ethPoolLiquidity, 0);
        // The PoolManager holds the seed: ~100 ETH and ~200k USDC
        assertApproxEqRel(address(s.poolManager).balance, 100 ether, 0.001e18);
        assertApproxEqRel(usdc.balanceOf(address(s.poolManager)), 200_000e6, 0.001e18);
        assertEq(usdc.allowance(address(this), address(s.liquidityRouter)), 0, "no dangling allowance");
    }

    function test_poolManagerOwner() public view {
        (bool ok, bytes memory ret) = address(s.poolManager).staticcall(abi.encodeWithSignature("owner()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), owner);
    }

    /// @notice A harvest-sized sale (1,000 USDC) buys ~0.5 ETH, which dwarfs the harvester's gas floor
    ///         `(gasUsed + 60_000) * tx.gasprice` even at 1M gas and 50 gwei (0.053 ETH).
    function test_ethPool_harvestSizedSwap_isProfitable() public {
        PoolSwapTest swapRouter = new PoolSwapTest(s.poolManager);
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(swapRouter), 1_000e6);
        uint256 ethBefore = address(this).balance;

        swapRouter.swap(
            s.ethPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: false, // USDC (currency1) -> ETH (currency0)
                amountSpecified: -int256(1_000e6), // exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethOut = address(this).balance - ethBefore;
        assertApproxEqRel(ethOut, 0.5 ether, 0.01e18, "~0.5 ETH less the 0.3% fee");
        assertGt(ethOut, (1_000_000 + 60_000) * 50 gwei);
    }
}
