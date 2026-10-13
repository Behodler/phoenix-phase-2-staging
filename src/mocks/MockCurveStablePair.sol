// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  MockCurveStablePair
/// @notice Shared core of the story-110 Curve mocks (`MockCurveDolaMetaPool`,
///         `MockCurveStableSwapNG`): a reserve-backed 1:1 swap between two dollar stables of any
///         decimals, less an owner-settable fee in basis points. No curve, no imbalance pricing.
/// @dev    `tokenA` is the 18-decimal side in both concrete mocks (DOLA / USDe) and `tokenB` the
///         6-decimal USDC side, but nothing here assumes that: the conversion is
///         `dx * 10**decimals(out) / 10**decimals(in)`, floored. The deploy script prefunds both
///         sides; output is paid from that reserve.
abstract contract MockCurveStablePair {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    address public immutable tokenA;
    address public immutable tokenB;
    uint256 internal immutable _scaleA;
    uint256 internal immutable _scaleB;

    address public owner;

    /// @notice Swap fee in basis points, taken from the output. Defaults to 4 bps (Curve-like).
    uint256 public feeBps = 4;

    event TokenExchange(
        address indexed buyer, address soldId, uint256 tokensSold, address boughtId, uint256 tokensBought
    );

    constructor(address tokenA_, address tokenB_) {
        require(tokenA_ != address(0) && tokenB_ != address(0), "MockCurve: zero token");
        require(tokenA_ != tokenB_, "MockCurve: same token");
        tokenA = tokenA_;
        tokenB = tokenB_;
        _scaleA = 10 ** IERC20Metadata(tokenA_).decimals();
        _scaleB = 10 ** IERC20Metadata(tokenB_).decimals();
        owner = msg.sender;
    }

    /// @notice Owner only. Fee in basis points, below 100%.
    function setFeeBps(uint256 newFeeBps) external {
        require(msg.sender == owner, "MockCurve: not owner");
        require(newFeeBps < BPS, "MockCurve: fee too high");
        feeBps = newFeeBps;
    }

    function _dy(bool aToB, uint256 dx) internal view returns (uint256 dy) {
        dy = aToB ? dx * _scaleB / _scaleA : dx * _scaleA / _scaleB;
        dy -= dy * feeBps / BPS;
    }

    function _exchange(bool aToB, uint256 dx, uint256 minDy) internal returns (uint256 dy) {
        (address tIn, address tOut) = aToB ? (tokenA, tokenB) : (tokenB, tokenA);
        dy = _dy(aToB, dx);
        require(dy >= minDy, "Exchange resulted in fewer coins than expected");
        IERC20(tIn).safeTransferFrom(msg.sender, address(this), dx);
        IERC20(tOut).safeTransfer(msg.sender, dy);
        emit TokenExchange(msg.sender, tIn, dx, tOut, dy);
    }
}
