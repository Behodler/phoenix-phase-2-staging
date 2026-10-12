// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IQuoterV2
/// @notice Minimal Uniswap V3 QuoterV2 (mainnet 0x61fFE014bA17989E743c5F6cB21bF9697530B21e).
/// @dev    Not `view`: QuoterV2 simulates the swap and reverts internally to read the result, so it
///         cannot be STATICCALLed. Call it via `eth_call` / `simulateContract` only.
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
