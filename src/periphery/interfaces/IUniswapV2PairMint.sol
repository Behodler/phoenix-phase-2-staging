// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IUniswapV2PairMint
/// @notice The Uniswap V2 pair's `mint`, which the shared minimal `IUniswapV2Pair` omits. Both tokens
///         must be transferred to the pair first; `mint` credits `balance - reserve` of each to `to`.
interface IUniswapV2PairMint {
    function mint(address to) external returns (uint256 liquidity);
}
