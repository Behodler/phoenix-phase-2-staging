// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IUniswapV2PairBurn
/// @notice The Uniswap V2 pair's `burn`, which the shared minimal `IUniswapV2Pair` omits. LP must be
///         transferred to the pair first; `burn` then sends both reserves' share to `to`.
interface IUniswapV2PairBurn {
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}
