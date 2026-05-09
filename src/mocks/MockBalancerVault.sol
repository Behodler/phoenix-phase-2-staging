// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@yield-claim-nft/interfaces/balancer/IBalancerVault.sol";
import "@yield-claim-nft/interfaces/balancer/IUnlockCallback.sol";
import "@yield-claim-nft/interfaces/balancer/BalancerTypes.sol";
import "./MockBalancerPool.sol";
import "./MockERC4626Wrapper.sol";

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

    /// @notice Configurable swap rate per (tokenIn, tokenOut) pair, expressed as
    ///         numerator/denominator. amountOut = amountIn * num / den. Default 1:1.
    /// @dev    Mock-only knob so dev scripts can deliberately produce a bad rate
    ///         (e.g., zero output) to exercise the BalancerPoolerV2 USDC slippage
    ///         revert. Mirrors the upstream pattern in
    ///         lib/yield-claim-nft/test/V2/BalancerPoolerV2.t.sol's MockBalancerVault.
    mapping(address => mapping(address => uint256)) private _swapRateNum;
    mapping(address => mapping(address => uint256)) private _swapRateDen;

    constructor(address pool_) {
        pool = MockBalancerPool(pool_);
    }

    /**
     * @notice Mock-only setter to configure the swap output rate for a given
     *         (tokenIn, tokenOut) pair. Output amount on swap is computed as
     *         `amountIn * rateNum / rateDen`. Setting `rateNum = 0` produces
     *         a zero output and is the canonical way to force the
     *         BalancerPoolerV2 USDC-slippage revert from a script.
     * @param tokenIn  The token sent into the swap.
     * @param tokenOut The token returned from the swap (must be a MockERC4626Wrapper).
     * @param rateNum  Numerator of the rate.
     * @param rateDen  Denominator of the rate. Must be > 0.
     */
    function setSwapRate(address tokenIn, address tokenOut, uint256 rateNum, uint256 rateDen) external {
        require(rateDen > 0, "MockBalancerVault: zero rate denominator");
        _swapRateNum[tokenIn][tokenOut] = rateNum;
        _swapRateDen[tokenIn][tokenOut] = rateDen;
    }

    function getSwapRate(address tokenIn, address tokenOut)
        external
        view
        returns (uint256 rateNum, uint256 rateDen)
    {
        rateNum = _swapRateNum[tokenIn][tokenOut];
        rateDen = _swapRateDen[tokenIn][tokenOut];
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

    /**
     * @notice Simulates a Balancer V3 EXACT_IN swap.
     * @dev    Caller (BalancerPoolerV2) has already transferred `amountGivenRaw`
     *         of `tokenIn` to this vault before invoking swap. We mint `amountOut`
     *         shares of `tokenOut` (a MockERC4626Wrapper) back to the caller.
     *         `amountOut = amountGivenRaw * rateNum / rateDen` for the configured
     *         (tokenIn, tokenOut) pair, defaulting to 1:1 when no rate is set.
     *         Mirrors the upstream test-mock pattern in
     *         lib/yield-claim-nft/test/V2/BalancerPoolerV2.t.sol.
     */
    function swap(VaultSwapParams memory params)
        external
        override
        returns (uint256 amountCalculatedRaw, uint256 amountInRaw, uint256 amountOutRaw)
    {
        amountInRaw = params.amountGivenRaw;
        uint256 rateNum = _swapRateNum[address(params.tokenIn)][address(params.tokenOut)];
        uint256 rateDen = _swapRateDen[address(params.tokenIn)][address(params.tokenOut)];
        if (rateDen == 0) {
            // Default 1:1 if not configured.
            amountOutRaw = amountInRaw;
        } else {
            amountOutRaw = (amountInRaw * rateNum) / rateDen;
        }
        amountCalculatedRaw = 0;

        // Mint tokenOut shares to the caller — caller is expected to have already
        // transferred tokenIn to this vault before invoking swap.
        if (amountOutRaw > 0) {
            MockERC4626Wrapper(address(params.tokenOut)).mintShares(msg.sender, amountOutRaw);
        }
    }
}
