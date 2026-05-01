// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@yield-claim-nft/interfaces/balancer/IBalancerVault.sol";
import "@yield-claim-nft/interfaces/balancer/IUnlockCallback.sol";
import "@yield-claim-nft/interfaces/balancer/BalancerTypes.sol";
import "./MockBalancerPool.sol";

/**
 * @title MockBalancerVault
 * @notice Simulates the Balancer V3 vault's unlock/addLiquidity pattern for testing
 * @dev Implements the IBalancerVault interface as expected by BalancerPooler.
 *
 *      Flow:
 *      1. BalancerPooler calls unlock(data) on this vault
 *      2. Vault calls IUnlockCallback(msg.sender).unlockCallback(data)
 *      3. Inside callback, BalancerPooler transfers tokens TO this vault and calls addLiquidity
 *      4. addLiquidity mints BPT at 1:1 ratio to the BalancerPooler (params.to)
 *      5. BalancerPooler calls settle() to finalize credit
 *      6. Control returns to unlock which returns
 */
contract MockBalancerVault is IBalancerVault {
    /// @notice The MockBalancerPool that mints BPT tokens
    MockBalancerPool public pool;

    constructor(address pool_) {
        pool = MockBalancerPool(pool_);
    }

    /**
     * @notice Simulates Balancer V3 unlock pattern
     * @dev Calls back into the caller's unlockCallback, then returns the result
     * @param data ABI-encoded data passed through to the callback
     * @return result The bytes returned from unlockCallback
     */
    function unlock(bytes calldata data) external override returns (bytes memory result) {
        // Real Balancer V3 forwards `data` as raw calldata. BalancerPoolerV2.pool()
        // pre-encodes `data` as `unlockCallback.selector + abi.encode(innerData)`, so
        // we must call back via low-level call to avoid double-wrapping the bytes.
        (bool success, bytes memory returnData) = msg.sender.call(data);
        require(success, "MockBalancerVault: unlock callback failed");
        result = returnData;
    }

    /**
     * @notice Simulates adding liquidity to a Balancer pool
     * @dev Mints BPT at 1:1 ratio for total tokens deposited.
     *      Tokens have already been transferred to this vault by the callback.
     * @param params The AddLiquidityParams struct
     * @return amountsIn Array of amounts actually deposited
     * @return bptAmountOut Amount of BPT minted
     * @return returnData Empty bytes
     */
    function addLiquidity(AddLiquidityParams memory params)
        external
        override
        returns (uint256[] memory amountsIn, uint256 bptAmountOut, bytes memory returnData)
    {
        // Calculate total tokens being added (sum of maxAmountsIn)
        uint256 totalIn = 0;
        amountsIn = new uint256[](params.maxAmountsIn.length);
        for (uint256 i = 0; i < params.maxAmountsIn.length; i++) {
            amountsIn[i] = params.maxAmountsIn[i];
            totalIn += params.maxAmountsIn[i];
        }

        // Mint BPT at 1:1 ratio to the recipient
        bptAmountOut = totalIn;
        require(bptAmountOut >= params.minBptAmountOut, "MockBalancerVault: BPT below minimum");
        pool.mint(params.to, bptAmountOut);

        returnData = "";
    }

    /**
     * @notice Simulates settling credit from token transfers
     * @dev In the real Balancer V3, this settles the accounting credit.
     *      In this mock, it's a no-op since tokens are already transferred.
     * @param token The token being settled
     * @param amountSettled The amount of credit to settle
     * @return credit The settled credit amount
     */
    function settle(IERC20 token, uint256 amountSettled) external override returns (uint256 credit) {
        // No-op in mock - tokens are already on this contract
        credit = amountSettled;
    }

    /**
     * @notice Simulates sending tokens from the vault to a recipient
     * @dev Transfers tokens held by this vault to the specified address
     * @param token The token to send
     * @param to The recipient address
     * @param amount The amount to send
     */
    function sendTo(IERC20 token, address to, uint256 amount) external override {
        token.transfer(to, amount);
    }
}
