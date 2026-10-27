// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "@forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockCrvUSD} from "../../src/mocks/MockCrvUSD.sol";
import {MockCurveStableSwapNG} from "../../src/mocks/MockCurveStableSwapNG.sol";
import {MockCurveRouterNG} from "../../src/mocks/MockCurveRouterNG.sol";

/// @notice The unrestricted `mint` every mock stable in `src/mocks/` exposes.
interface IMintableHarvestStable {
    function mint(address to, uint256 amount) external;
}

/// @title  SyaHarvesterLocalStack
/// @notice Story 115. The anvil infrastructure SYAHarvester (lib/sya-harvester, pin 6b862aa) needs to
///         actually execute, modelled on mainnet:
///
///         - Curve Router NG v1.1 -> `MockCurveRouterNG` (M-01-faithful route walk, real pool hops).
///         - crvUSD -> `MockCrvUSD`, plus the two stable pools of the mainnet USDe route
///           USDe -> crvUSD -> USDC: USDe/crvUSD (mainnet 0xF55B...0442, stableswap-ng, coin0 USDe,
///           coin1 crvUSD) and crvUSD/USDC (mainnet 0x4DEc...D69E, plain pool, coin0 USDC, coin1 crvUSD).
///           Both are `MockCurveStableSwapNG` instances (a coin0/coin1 1:1-less-4-bps pair; its revert
///           strings still say "USDe/USDC" from story 110, the logic is generic).
///         - The DOLA route reuses the EXISTING story-110 `MockCurveDolaMetaPool` (underlying 0 = DOLA,
///           2 = USDC), the local stand-in for mainnet's DOLA/FRAXBP metapool 0xE571...884d.
///         - Uniswap V4 `PoolManager` (v4-core v4.0.0) deployed as the unchanged
///           `src/mocks/LocalUniswapV4PoolManager.sol` subclass from its own 0.8.26 artifact,
///           v4-core's `PoolModifyLiquidityTest` router to seed it, and the mainnet ETH pool key: native ETH / USDC, fee 3000, tickSpacing 60, no
///           hooks, full-range liquidity at 2000 USDC per ETH (the rate every other local venue uses).
///
///         Shared by `DeployMocks` (Phase 11.11, inside its broadcast) and
///         `test/SyaHarvesterLocalStack.t.sol`, so the forge test exercises exactly the anvil wiring.
///         `usdeRoute` / `dolaRoute` / `ethPoolKey` are the shapes story 116 hands `SYAHarvester`.
/// @dev    Internal functions, inlined into the caller like `UniswapHelperLocalStack`: every `new` and
///         every call is made by the calling contract, i.e. the broadcasting deployer in the script.
///         The caller needs `ETH_SEED + ETH_SEED_MARGIN` native ETH; the unused margin is refunded to
///         it by the liquidity router, so a contract caller must be able to receive ETH.
library SyaHarvesterLocalStack {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The mainnet ETH/USDC V4 pool key's fee tier and tick spacing (sya-harvester MainnetRoutes).
    uint24 internal constant ETH_POOL_FEE = 3000;
    int24 internal constant ETH_POOL_TICK_SPACING = 60;

    /// @dev sqrt(2000e6 / 1e18) * 2^96: 1 ETH (1e18 wei) = 2000 USDC (2000e6 raw), currency0 = ETH.
    ///      Matches `UniswapHelperLocalStack.RATE_WETH_TO_USDC` and the USDC/WETH9 V2 routing pair.
    uint160 internal constant SQRT_PRICE_2000_USDC_PER_ETH = 3543191142285914205922034;

    /// @dev ETH side of the full-range seed (~200k USDC on the other side at 2000/ETH). Deep enough that
    ///      a realistic harvest's USDC -> ETH swap moves the price negligibly.
    uint256 internal constant ETH_SEED = 100 ether;
    /// @dev Sent on top of ETH_SEED to cover rounding; refunded by PoolModifyLiquidityTest.
    uint256 internal constant ETH_SEED_MARGIN = 1 ether;
    /// @dev USDC minted to the caller for the seed: the ~200k the pool takes, plus headroom.
    uint256 internal constant USDC_SEED_MINT = 250_000e6;

    /// @dev Reserves of each side of the two new Curve pool mocks (USDC 6dp, the rest 18dp).
    uint256 internal constant CURVE_STABLE_RESERVE = 1_000_000e18;
    uint256 internal constant CURVE_USDC_RESERVE = 1_000_000e6;

    struct Inputs {
        address usdc;
        address dola;
        address usde;
        /// @dev The existing story-110 MockCurveDolaMetaPool (DOLA = 0, USDC = 2).
        address curveDola;
        /// @dev Owner of the PoolManager (protocol-fee controller); the deployer.
        address poolManagerOwner;
        /// @dev Who the calls are sent FROM: the broadcasting deployer EOA in the script, the test
        ///      contract in a forge test. It is minted the USDC seed and pays it into the pool.
        address payer;
    }

    struct Infra {
        MockCrvUSD crvUSD;
        MockCurveStableSwapNG curveUsdeCrvusd;
        MockCurveStableSwapNG curveCrvusdUsdc;
        MockCurveRouterNG router;
        IPoolManager poolManager;
        PoolModifyLiquidityTest liquidityRouter;
        PoolKey ethPoolKey;
        uint128 ethPoolLiquidity;
    }

    /// @notice A Router NG route, in `SYAHarvester.setRoute` argument shape.
    struct Route {
        address token;
        address[11] path;
        uint256[5][5] swapParams;
        address[5] pools;
    }

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    /// @notice Deploys and funds everything above, initialises the ETH/USDC pool and seeds it.
    function deploy(Inputs memory t) internal returns (Infra memory s) {
        require(t.curveDola != address(0), "SyaHarvesterLocalStack: DOLA metapool missing");

        // --- Curve side ---
        s.crvUSD = new MockCrvUSD();
        s.curveUsdeCrvusd = new MockCurveStableSwapNG(t.usde, address(s.crvUSD));
        s.curveCrvusdUsdc = new MockCurveStableSwapNG(t.usdc, address(s.crvUSD));
        s.router = new MockCurveRouterNG();

        IMintableHarvestStable(t.usde).mint(address(s.curveUsdeCrvusd), CURVE_STABLE_RESERVE);
        s.crvUSD.mint(address(s.curveUsdeCrvusd), CURVE_STABLE_RESERVE);
        IMintableHarvestStable(t.usdc).mint(address(s.curveCrvusdUsdc), CURVE_USDC_RESERVE);
        s.crvUSD.mint(address(s.curveCrvusdUsdc), CURVE_STABLE_RESERVE);

        // --- Uniswap V4 side ---
        // PoolManager is pragma 0.8.26 EXACT: deployed from its own compilation unit's artifact rather
        // than `new`, so this library (and DeployMocks) stays on 0.8.30. See LocalUniswapV4PoolManager.
        s.poolManager = IPoolManager(
            vm.deployCode("LocalUniswapV4PoolManager.sol:LocalUniswapV4PoolManager", abi.encode(t.poolManagerOwner))
        );
        s.liquidityRouter = new PoolModifyLiquidityTest(s.poolManager);
        s.ethPoolKey = ethPoolKey(t.usdc);
        s.poolManager.initialize(s.ethPoolKey, SQRT_PRICE_2000_USDC_PER_ETH);

        // Full-range position sized so its ETH side is ~ETH_SEED: L = amount0 * sqrtP / 2^96.
        s.ethPoolLiquidity = uint128(ETH_SEED * uint256(SQRT_PRICE_2000_USDC_PER_ETH) / (1 << 96));
        IMintableHarvestStable(t.usdc).mint(t.payer, USDC_SEED_MINT);
        IERC20(t.usdc).approve(address(s.liquidityRouter), USDC_SEED_MINT);
        s.liquidityRouter.modifyLiquidity{value: ETH_SEED + ETH_SEED_MARGIN}(
            s.ethPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(ETH_POOL_TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(ETH_POOL_TICK_SPACING),
                liquidityDelta: int256(uint256(s.ethPoolLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        // Leave no dangling USDC allowance on the seeding router.
        IERC20(t.usdc).approve(address(s.liquidityRouter), 0);
    }

    // ------------------------------------------------------------------
    // Shapes story 116 hands SYAHarvester
    // ------------------------------------------------------------------

    /// @notice The mainnet ETH pool key: native ETH (currency0) / USDC, fee 3000, tickSpacing 60, no hooks.
    function ethPoolKey(address usdc) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(usdc),
            fee: ETH_POOL_FEE,
            tickSpacing: ETH_POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @notice USDe -> crvUSD -> USDC, two hops, mainnet params `[0,1,1,10,2]`, `[1,0,1,1,2]`
    ///         (sya-harvester `test/fork/MainnetRoutes.sol` `usdeRoute`).
    function usdeRoute(Infra memory s, address usde, address usdc) internal pure returns (Route memory r) {
        r.token = usde;
        r.path[0] = usde;
        r.path[1] = address(s.curveUsdeCrvusd);
        r.path[2] = address(s.crvUSD);
        r.path[3] = address(s.curveCrvusdUsdc);
        r.path[4] = usdc;
        // coin0 (USDe) -> coin1 (crvUSD), exchange, stableswap-ng (pool_type 10), 2 coins
        r.swapParams[0] = [uint256(0), 1, 1, 10, 2];
        // coin1 (crvUSD) -> coin0 (USDC), exchange, stable (pool_type 1), 2 coins
        r.swapParams[1] = [uint256(1), 0, 1, 1, 2];
    }

    /// @notice DOLA -> USDC, one hop, exchange_underlying on the DOLA metapool, mainnet params
    ///         `[0,2,2,1,3]` (sya-harvester `test/fork/MainnetRoutes.sol` `dolaRoute`).
    function dolaRoute(address curveDola, address dola, address usdc) internal pure returns (Route memory r) {
        r.token = dola;
        r.path[0] = dola;
        r.path[1] = curveDola;
        r.path[2] = usdc;
        // underlying 0 (DOLA) -> underlying 2 (USDC), exchange_underlying, stable metapool, 3 underlying coins
        r.swapParams[0] = [uint256(0), 2, 2, 1, 3];
    }
}
