// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IWETH
/// @notice Minimal WETH9 surface: wrap and unwrap native ETH.
interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
