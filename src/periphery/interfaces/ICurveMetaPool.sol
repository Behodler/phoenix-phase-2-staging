// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ICurveMetaPool
/// @notice Minimal Curve factory metapool surface (DOLA-3CRV, mainnet
///         0xAA5A67c256e27A5d80712c51971408db3370927D). Underlying indices: 0 = DOLA, 1 = DAI,
///         2 = USDC, 3 = USDT.
interface ICurveMetaPool {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);

    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
}
