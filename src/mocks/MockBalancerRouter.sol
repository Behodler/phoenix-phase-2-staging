// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@yield-claim-nft/interfaces/balancer/IBalancerRouter.sol";

/**
 * @title MockBalancerRouter
 * @notice Minimal mock implementing IBalancerRouter for BalancerPoolerV2 testing
 * @dev Returns a 1:1 BPT estimate for any input amounts
 */
contract MockBalancerRouter is IBalancerRouter {
    function queryAddLiquidityUnbalanced(
        address,
        uint256[] memory exactAmountsIn,
        address,
        bytes memory
    ) external pure returns (uint256 bptAmountOut) {
        for (uint256 i = 0; i < exactAmountsIn.length; i++) {
            bptAmountOut += exactAmountsIn[i];
        }
    }
}
