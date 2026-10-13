// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICurveMetaPool} from "../periphery/interfaces/ICurveMetaPool.sol";
import {MockCurveStablePair} from "./MockCurveStablePair.sol";

/// @title  MockCurveDolaMetaPool
/// @notice Local (anvil) stand-in for the Curve DOLA-3CRV metapool's underlying swap, as
///         `UniswapHelper` uses it. Story 110. Only the DOLA <-> USDC underlying route exists:
///         underlying index 0 = DOLA, 2 = USDC (1 = DAI and 3 = USDT are not modelled and revert).
/// @dev    1:1 across decimals (18dp DOLA <-> 6dp USDC), less `feeBps`, reserve-backed.
contract MockCurveDolaMetaPool is ICurveMetaPool, MockCurveStablePair {
    int128 public constant DOLA_INDEX = 0;
    int128 public constant USDC_INDEX = 2;

    constructor(address dola, address usdc) MockCurveStablePair(dola, usdc) {}

    /// @inheritdoc ICurveMetaPool
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external override returns (uint256) {
        return _exchange(_direction(i, j), dx, minDy);
    }

    /// @inheritdoc ICurveMetaPool
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view override returns (uint256) {
        return _dy(_direction(i, j), dx);
    }

    /// @dev true = DOLA -> USDC.
    function _direction(int128 i, int128 j) internal pure returns (bool) {
        if (i == DOLA_INDEX && j == USDC_INDEX) return true;
        if (i == USDC_INDEX && j == DOLA_INDEX) return false;
        revert("MockCurveDolaMetaPool: only DOLA(0) <-> USDC(2)");
    }
}
