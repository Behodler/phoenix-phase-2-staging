// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ICurveStableSwapNG
/// @notice Minimal Curve stableswap-ng plain-pool surface (USDe/USDC, mainnet
///         0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72; coins 0 = USDe, 1 = USDC).
interface ICurveStableSwapNG {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);

    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);

    function coins(uint256 i) external view returns (address);
}
