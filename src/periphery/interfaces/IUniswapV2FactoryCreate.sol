// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Factory} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Factory.sol";

/// @title  IUniswapV2FactoryCreate
/// @notice The shared minimal `IUniswapV2Factory` plus `createPair`, which AntimatterPoolSeeder
///         needs to open the Antimatter/sUSDS pair on first use.
interface IUniswapV2FactoryCreate is IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}
