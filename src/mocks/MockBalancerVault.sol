// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    using SafeERC20 for IERC20;

    /// @notice The MockBalancerPool that mints BPT tokens
    MockBalancerPool public pool;

    /// @notice Mirrors the Balancer V3 `TokenInfo` struct returned by `getPoolTokenInfo`
    ///         (`TokenType` enum encoded as uint8). The mock reports STANDARD tokens with no rate
    ///         provider, matching what mainnet returns for the phUSD/sUSDS pool.
    struct PoolTokenInfo {
        uint8 tokenType;
        address rateProvider;
        bool paysYieldFees;
    }

    /// @notice The pool's tokens in Balancer (address-sorted) order. Story 100: the exits pay
    ///         each of these pro rata from this vault's balance of it. Set once via `setPoolTokens`.
    address[] private _poolTokens;

    /// @notice Story 100 mock-only switch simulating the paused pool after 30 October: while true
    ///         the proportional exit reverts and the recovery exit works; while false the recovery
    ///         exit reverts, as mainnet reverts `PoolNotInRecoveryMode`. The existing add path is
    ///         unaffected.
    bool public poolPaused;

    event PoolTokensSet(address[] tokens);
    event PoolPausedSet(bool paused);
    event LiquidityRemoved(address indexed from, address indexed to, uint256 bptIn, uint256[] amountsOut, bool recovery);

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

    // ---------------------------------------------------------------------------------------
    // Story 100: proportional and recovery exits (Balancexit cutover rehearsal)
    // ---------------------------------------------------------------------------------------

    /**
     * @notice Mock-only: registers the pool's tokens, in Balancer (address-sorted) order.
     * @dev One-shot, like `MockBalancerPool.setVault`. The exits pay each listed token pro rata
     *      from this vault's balance of it, so the list must name exactly the tokens the pool holds.
     */
    function setPoolTokens(address[] calldata tokens) external {
        require(_poolTokens.length == 0, "MockBalancerVault: pool tokens already set");
        require(tokens.length > 0, "MockBalancerVault: no pool tokens");
        _poolTokens = tokens;
        emit PoolTokensSet(tokens);
    }

    /// @notice Mock-only: simulate the pool being paused (true) or live (false). See `poolPaused`.
    function setPoolPaused(bool paused_) external {
        poolPaused = paused_;
        emit PoolPausedSet(paused_);
    }

    /// @notice Balancer V3 `getPoolTokens(pool)`.
    function getPoolTokens(address pool_) external view returns (address[] memory tokens) {
        require(pool_ == address(pool), "MockBalancerVault: unknown pool");
        tokens = _poolTokens;
    }

    /**
     * @notice Balancer V3 `getPoolTokenInfo(pool)`: tokens, token infos, raw balances and last
     *         live balances. The mock's raw balances are this vault's ERC20 balances of each pool
     *         token, and its live balances equal them (no rate providers, 18-decimal tokens).
     */
    function getPoolTokenInfo(address pool_)
        external
        view
        returns (
            address[] memory tokens,
            PoolTokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        )
    {
        require(pool_ == address(pool), "MockBalancerVault: unknown pool");
        tokens = _poolTokens;
        tokenInfo = new PoolTokenInfo[](tokens.length);
        balancesRaw = _balances();
        lastBalancesLiveScaled18 = _balances();
    }

    /**
     * @notice Proportional exit. Burns `bptIn` from `from` (spending `msg.sender`'s BPT allowance
     *         unless `msg.sender == from`) and pays `to` each pool token pro rata,
     *         `amountOut_i = balance_i * bptIn / totalSupply`.
     * @dev Reverts while `poolPaused`, and if any `amountOut_i < minAmountsOut[i]`. Mainnet reaches
     *      this through the Router (see `MockBalancerRouter.removeLiquidityProportional`).
     */
    function removeLiquidityProportional(
        address pool_,
        address from,
        address to,
        uint256 bptIn,
        uint256[] memory minAmountsOut
    ) external returns (uint256[] memory amountsOut) {
        require(!poolPaused, "MockBalancerVault: pool paused");
        amountsOut = _exit(pool_, from, to, bptIn, minAmountsOut, false);
    }

    /**
     * @notice Recovery exit: same pro rata payout as the proportional exit, but only available
     *         while the pool is paused (in recovery mode).
     */
    function removeLiquidityRecovery(
        address pool_,
        address from,
        address to,
        uint256 bptIn,
        uint256[] memory minAmountsOut
    ) external returns (uint256[] memory amountsOut) {
        require(poolPaused, "MockBalancerVault: pool not in recovery mode");
        amountsOut = _exit(pool_, from, to, bptIn, minAmountsOut, true);
    }

    function _balances() internal view returns (uint256[] memory b) {
        b = new uint256[](_poolTokens.length);
        for (uint256 i = 0; i < b.length; i++) {
            b[i] = IERC20(_poolTokens[i]).balanceOf(address(this));
        }
    }

    function _exit(
        address pool_,
        address from,
        address to,
        uint256 bptIn,
        uint256[] memory minAmountsOut,
        bool recovery
    ) internal returns (uint256[] memory amountsOut) {
        require(pool_ == address(pool), "MockBalancerVault: unknown pool");
        require(_poolTokens.length > 0, "MockBalancerVault: pool tokens not set");
        require(minAmountsOut.length == _poolTokens.length, "MockBalancerVault: minAmountsOut length");
        require(bptIn > 0, "MockBalancerVault: zero BPT");

        uint256 supply = pool.totalSupply();
        uint256[] memory bal = _balances();
        amountsOut = new uint256[](bal.length);
        for (uint256 i = 0; i < bal.length; i++) {
            amountsOut[i] = (bal[i] * bptIn) / supply;
            require(amountsOut[i] >= minAmountsOut[i], "MockBalancerVault: amount out below minimum");
        }

        pool.burnFrom(from, msg.sender, bptIn);

        for (uint256 i = 0; i < bal.length; i++) {
            if (amountsOut[i] > 0) IERC20(_poolTokens[i]).safeTransfer(to, amountsOut[i]);
        }
        emit LiquidityRemoved(from, to, bptIn, amountsOut, recovery);
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
