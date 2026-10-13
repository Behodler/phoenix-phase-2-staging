// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IQuoterV2} from "../periphery/interfaces/IQuoterV2.sol";
import {MockUniswapV3SwapRouter} from "./MockUniswapV3SwapRouter.sol";

/// @title  MockUniswapV3QuoterV2
/// @notice Local (anvil) stand-in for Uniswap V3 QuoterV2. Story 110. `quoteExactInputSingle` reads
///         `MockUniswapV3SwapRouter.quote`, so every quote equals the swap the router would execute.
/// @dev    `view` here (the real QuoterV2 is not, because it simulates and reverts); a stricter
///         mutability satisfies the interface, and callers still use `eth_call` either way.
///         `sqrtPriceX96After` and `initializedTicksCrossed` are 0 (no tick curve); `gasEstimate`
///         is a nominal constant.
contract MockUniswapV3QuoterV2 is IQuoterV2 {
    MockUniswapV3SwapRouter public immutable router;

    uint256 internal constant GAS_ESTIMATE = 100_000;

    constructor(MockUniswapV3SwapRouter router_) {
        require(address(router_) != address(0), "MockQuoterV2: zero router");
        router = router_;
    }

    /// @inheritdoc IQuoterV2
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        view
        override
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        amountOut = router.quote(params.tokenIn, params.tokenOut, params.fee, params.amountIn);
        return (amountOut, 0, 0, GAS_ESTIMATE);
    }
}
