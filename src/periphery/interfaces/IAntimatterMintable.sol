// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IAntimatterMintable
/// @notice The slice of Antimatter (`lib/antimatter/src/Antimatter.sol`) AntimatterPoolSeeder uses:
///         the approved-minter-gated `mint` and the `isApprovedMinter` read.
interface IAntimatterMintable {
    function mint(address to, uint256 amount) external;
    function isApprovedMinter(address minter) external view returns (bool);
}
