// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@yield-claim-nft/interfaces/balancer/IBalancerRouter.sol";
import "./MockBalancerPool.sol";
import "./MockBalancerVault.sol";

/**
 * @title MockBalancerRouter
 * @notice Minimal mock implementing IBalancerRouter for BalancerPoolerV2 testing
 * @dev Returns a 1:1 BPT estimate for any input amounts.
 *      Story 100: also carries the Balancer V3 Router exit entry points, with the mainnet Router
 *      `0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd` signatures
 *      (`removeLiquidityProportional` 0x51682750, `removeLiquidityRecovery` 0x08c04793). As on
 *      mainnet, the caller must first approve THIS router on the BPT: the vault burns the BPT from
 *      the caller by spending the router's allowance, and pays the tokens to the caller.
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

    /// @notice Balancer V3 Router proportional exit of `exactBptAmountIn` of the caller's BPT.
    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory /*userData*/
    ) external payable returns (uint256[] memory amountsOut) {
        require(!wethIsEth, "MockBalancerRouter: wethIsEth unsupported");
        amountsOut = MockBalancerVault(MockBalancerPool(pool).vault())
            .removeLiquidityProportional(pool, msg.sender, msg.sender, exactBptAmountIn, minAmountsOut);
    }

    /// @notice Balancer V3 Router recovery exit of `exactBptAmountIn` of the caller's BPT.
    function removeLiquidityRecovery(address pool, uint256 exactBptAmountIn, uint256[] memory minAmountsOut)
        external
        payable
        returns (uint256[] memory amountsOut)
    {
        amountsOut = MockBalancerVault(MockBalancerPool(pool).vault())
            .removeLiquidityRecovery(pool, msg.sender, msg.sender, exactBptAmountIn, minAmountsOut);
    }
}
