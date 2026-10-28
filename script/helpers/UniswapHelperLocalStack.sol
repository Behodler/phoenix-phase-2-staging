// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapHelper} from "../../src/periphery/UniswapHelper.sol";
import {IWETH} from "../../src/periphery/interfaces/IWETH.sol";
import {MockSkyPSM} from "../../src/mocks/MockSkyPSM.sol";
import {MockUniswapV3SwapRouter} from "../../src/mocks/MockUniswapV3SwapRouter.sol";
import {MockUniswapV3QuoterV2} from "../../src/mocks/MockUniswapV3QuoterV2.sol";
import {MockCurveDolaMetaPool} from "../../src/mocks/MockCurveDolaMetaPool.sol";
import {MockCurveStableSwapNG} from "../../src/mocks/MockCurveStableSwapNG.sol";

/// @notice The unrestricted `mint` every mock stable in `src/mocks/` exposes.
interface IMintableStable {
    function mint(address to, uint256 amount) external;
}

/// @title  UniswapHelperLocalStack
/// @notice Story 110. Deploys and funds the venue mocks `UniswapHelper` calls on a local chain
///         (Uniswap V3 SwapRouter + QuoterV2, Curve DOLA-3CRV metapool, Curve USDe/USDC
///         stableswap-ng), tops up the existing `MockSkyPSM` with a USDS reserve for `sellGem`, and
///         deploys `UniswapHelper` against them. Shared by `DeployMocks` (inside its broadcast) and
///         `test/UniswapHelperAnvil.t.sol`, so the forge test exercises exactly the anvil wiring.
/// @dev    A library of internal functions, inlined into the caller, like `UniswapV2Deployer`: every
///         `new` and every call is made by the calling contract, i.e. the broadcasting deployer in
///         the script. `deploy` needs `WETH_RESERVE` (or the supplied `wethReserve`) native ETH on the caller to wrap.
library UniswapHelperLocalStack {
    /// @dev Default V3 fee tier: the mainnet WETH/USDC 0.05% pool.
    uint24 internal constant V3_FEE = 500;
    /// @dev 2000 USDC per ETH, consistent with the USDC/WETH9 V2 routing pair seeded at 200k:100.
    ///      Raw-unit ratios scaled by 1e18: 1e18 wei -> 2000e6 USDC, and 1e6 USDC -> 5e14 wei.
    uint256 internal constant RATE_WETH_TO_USDC = 2000e6;
    uint256 internal constant RATE_USDC_TO_WETH = 5e26;

    /// @dev Venue reserves. USDC is 6dp, everything else 18dp.
    uint256 internal constant WETH_RESERVE = 100 ether; // = 200k USDC at the default rate
    uint256 internal constant CURVE_USDC_RESERVE = 1_000_000e6;
    uint256 internal constant CURVE_STABLE_RESERVE = 1_000_000e18; // DOLA / USDe side
    uint256 internal constant PSM_USDS_RESERVE = 1_000_000e18;

    /// @dev The token / existing-venue inputs. `skyPSM` must be a `MockSkyPSM` over (`usdc`, `usds`).
    struct Inputs {
        address phUSD;
        address sUSDS;
        address usds;
        address usdc;
        address dola;
        address usde;
        address weth;
        address skyPSM;
        address v2Router;
        address antimatter;
    }

    struct Venues {
        MockUniswapV3SwapRouter v3Router;
        MockUniswapV3QuoterV2 v3Quoter;
        MockCurveDolaMetaPool curveDola;
        MockCurveStableSwapNG curveUsde;
        UniswapHelper helper;
    }

    /// @notice Deploys the four venue mocks and `UniswapHelper`, sets the V3 rates and funds every
    ///         venue (both sides of each pair, plus the PSM's USDS reserve).
    function deploy(Inputs memory t) internal returns (Venues memory v) {
        return deploy(t, WETH_RESERVE);
    }

    /// @notice `deploy` with the V3 router's WETH reserve supplied by the caller (DeployUniswapHelperSepolia:
    ///         a faucet-sized `SEPOLIA_WETH_SEED` instead of 100 ETH). The router's USDC side is sized to the
    ///         same value at RATE_WETH_TO_USDC, so `wethReserve = WETH_RESERVE` gives the 200k USDC anvil uses.
    function deploy(Inputs memory t, uint256 wethReserve) internal returns (Venues memory v) {
        uint256 v3UsdcReserve = (wethReserve * RATE_WETH_TO_USDC) / 1e18;
        require(v3UsdcReserve > 0, "UniswapHelperLocalStack: WETH reserve too small");

        v.v3Router = new MockUniswapV3SwapRouter();
        v.v3Quoter = new MockUniswapV3QuoterV2(v.v3Router);
        v.curveDola = new MockCurveDolaMetaPool(t.dola, t.usdc);
        v.curveUsde = new MockCurveStableSwapNG(t.usde, t.usdc);

        v.v3Router.setRate(t.weth, t.usdc, RATE_WETH_TO_USDC);
        v.v3Router.setRate(t.usdc, t.weth, RATE_USDC_TO_WETH);

        // V3: both sides. WETH comes from wrapping the caller's own ETH.
        IWETH(t.weth).deposit{value: wethReserve}();
        require(IERC20(t.weth).transfer(address(v.v3Router), wethReserve), "story-110: WETH reserve");
        IMintableStable(t.usdc).mint(address(v.v3Router), v3UsdcReserve);

        // Curve: both sides of each pool.
        IMintableStable(t.dola).mint(address(v.curveDola), CURVE_STABLE_RESERVE);
        IMintableStable(t.usdc).mint(address(v.curveDola), CURVE_USDC_RESERVE);
        IMintableStable(t.usde).mint(address(v.curveUsde), CURVE_STABLE_RESERVE);
        IMintableStable(t.usdc).mint(address(v.curveUsde), CURVE_USDC_RESERVE);

        // Sky PSM: USDS reserve for `sellGem` (its USDC reserve for `buyGem` already exists).
        IMintableStable(t.usds).mint(t.skyPSM, PSM_USDS_RESERVE);

        v.helper = new UniswapHelper(
            t.phUSD,
            t.sUSDS,
            t.usds,
            t.usdc,
            t.dola,
            t.usde,
            t.weth,
            t.skyPSM,
            t.v2Router,
            address(v.v3Router),
            address(v.v3Quoter),
            address(v.curveDola),
            address(v.curveUsde),
            t.antimatter,
            V3_FEE
        );
    }

    /// @notice Tops `who` up to `amount18` of DOLA / USDe / USDS, `amount6` of USDC and `amount18`
    ///         sUSDS shares, minting only the shortfall so an existing balance is left as is.
    ///         sUSDS is minted by depositing freshly minted USDS from `funder`, which must be the
    ///         account the calls are sent from (the broadcasting deployer in a script, where
    ///         `address(this)` is NOT the sender).
    function topUpDemoBalances(Inputs memory t, address funder, address who, uint256 amount18, uint256 amount6)
        internal
    {
        _topUp(t.dola, who, amount18);
        _topUp(t.usde, who, amount18);
        _topUp(t.usds, who, amount18);
        _topUp(t.usdc, who, amount6);

        uint256 have = IERC20(t.sUSDS).balanceOf(who);
        if (have < amount18) {
            uint256 usdsNeeded = ISUSDSLike(t.sUSDS).previewMint(amount18 - have);
            IMintableStable(t.usds).mint(funder, usdsNeeded);
            IERC20(t.usds).approve(t.sUSDS, usdsNeeded);
            ISUSDSLike(t.sUSDS).mint(amount18 - have, who);
        }
    }

    function _topUp(address token, address who, uint256 target) private {
        uint256 have = IERC20(token).balanceOf(who);
        if (have < target) IMintableStable(token).mint(who, target - have);
    }
}

/// @dev The ERC4626 calls `topUpDemoBalances` needs from MockSUSDS.
interface ISUSDSLike {
    function previewMint(uint256 shares) external view returns (uint256 assets);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
}
