// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3SwapRouter} from "../periphery/interfaces/IUniswapV3SwapRouter.sol";

/// @title  MockUniswapV3SwapRouter
/// @notice Local (anvil) stand-in for the Uniswap V3 SwapRouter (v1) that `UniswapHelper` calls for
///         its WETH <-> USDC leg. Story 110. Implements only `exactInputSingle` with the v1 params
///         struct (which carries `deadline`).
/// @dev    Fixed-rate and reserve-backed: there is no tick curve and no price impact. The output is
///         `amountIn * rate[tokenIn][tokenOut] / 1e18`, less the pool fee tier passed in `fee`
///         (hundredths of a bip, exactly like a real V3 pool: 500 = 0.05%). Rates are raw-unit
///         ratios, so they absorb the decimals difference: 2000 USDC per ETH is
///         `rate[WETH][USDC] = 2000e6` and `rate[USDC][WETH] = 5e26`. The output is paid from this
///         contract's balance, which the deploy script prefunds with both sides of the pair.
///         `MockUniswapV3QuoterV2` reads `quote` so quotes always equal swaps.
contract MockUniswapV3SwapRouter is IUniswapV3SwapRouter {
    using SafeERC20 for IERC20;

    uint256 internal constant RATE_SCALE = 1e18;
    uint256 internal constant FEE_DENOMINATOR = 1e6;

    address public owner;

    /// @notice tokenIn => tokenOut => raw output per 1e18 raw input units (before the fee tier).
    mapping(address => mapping(address => uint256)) public rate;

    event RateSet(address indexed tokenIn, address indexed tokenOut, uint256 rate);

    constructor() {
        owner = msg.sender;
    }

    /// @notice Set the fixed rate for one direction of a pair. Owner only.
    function setRate(address tokenIn, address tokenOut, uint256 newRate) external {
        require(msg.sender == owner, "MockV3Router: not owner");
        rate[tokenIn][tokenOut] = newRate;
        emit RateSet(tokenIn, tokenOut, newRate);
    }

    /// @notice The output `exactInputSingle` would deliver. Reverts for an unconfigured direction.
    function quote(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        public
        view
        returns (uint256 amountOut)
    {
        uint256 r = rate[tokenIn][tokenOut];
        require(r != 0, "MockV3Router: pair not configured");
        require(fee < FEE_DENOMINATOR, "MockV3Router: bad fee");
        amountOut = amountIn * r / RATE_SCALE;
        amountOut -= amountOut * fee / FEE_DENOMINATOR;
    }

    /// @inheritdoc IUniswapV3SwapRouter
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        require(block.timestamp <= params.deadline, "Transaction too old");
        require(msg.value == 0, "MockV3Router: no native ETH");
        amountOut = quote(params.tokenIn, params.tokenOut, params.fee, params.amountIn);
        require(amountOut >= params.amountOutMinimum, "Too little received");
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
    }
}
