// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Router02} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Router02.sol";

/// @title  IUniswapV2RouterPeriphery
/// @notice The shared minimal `IUniswapV2Router02` plus the Router02 function UniswapHelper
///         needs that the shared interface omits: `getAmountsOut` (quotes).
interface IUniswapV2RouterPeriphery is IUniswapV2Router02 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}
