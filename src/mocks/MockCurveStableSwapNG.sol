// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICurveStableSwapNG} from "../periphery/interfaces/ICurveStableSwapNG.sol";
import {MockCurveStablePair} from "./MockCurveStablePair.sol";

/// @title  MockCurveStableSwapNG
/// @notice Local (anvil) stand-in for the Curve USDe/USDC stableswap-ng plain pool `UniswapHelper`
///         uses. Story 110. Coin 0 = USDe, coin 1 = USDC, matching mainnet; `UniswapHelper`'s
///         constructor checks this order through `coins`.
/// @dev    1:1 across decimals (18dp USDe <-> 6dp USDC), less `feeBps`, reserve-backed.
contract MockCurveStableSwapNG is ICurveStableSwapNG, MockCurveStablePair {
    constructor(address usde, address usdc) MockCurveStablePair(usde, usdc) {}

    /// @inheritdoc ICurveStableSwapNG
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external override returns (uint256) {
        return _exchange(_direction(i, j), dx, minDy);
    }

    /// @inheritdoc ICurveStableSwapNG
    function get_dy(int128 i, int128 j, uint256 dx) external view override returns (uint256) {
        return _dy(_direction(i, j), dx);
    }

    /// @inheritdoc ICurveStableSwapNG
    function coins(uint256 i) external view override returns (address) {
        if (i == 0) return tokenA;
        if (i == 1) return tokenB;
        revert("MockCurveStableSwapNG: bad coin index");
    }

    /// @dev true = USDe -> USDC.
    function _direction(int128 i, int128 j) internal pure returns (bool) {
        if (i == 0 && j == 1) return true;
        if (i == 1 && j == 0) return false;
        revert("MockCurveStableSwapNG: only USDe(0) <-> USDC(1)");
    }
}
