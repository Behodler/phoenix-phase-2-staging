// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAMMAdapter} from "@vault/AMMAdapters/IAMMAdapter.sol";

/**
 * @title MockMarketAMMAdapter
 * @notice Anvil-only mock that mimics the mainnet Curve USDe<->sUSDe AMM path consumed by
 *         ERC4626MarketYieldStrategy. On mainnet, sUSDe is reached through an AMM (Curve
 *         Router NG via CurveAMMAdapter), so every deposit and withdrawal pays inherent
 *         slippage. A plain 1:1 MockSUSDe behind ERC4626YieldStrategy preserves deposits
 *         perfectly, which is unrealistic and masks the protocol's conservative principal
 *         accounting from the UI. This adapter restores that realism locally.
 *
 * @dev Unlike a fixed-exchange-rate mock, this adapter ROUTES THROUGH THE ACTUAL VAULT, so
 *      share pricing stays consistent with vault.convertToShares / convertToAssets at any
 *      share price. A fixed-rate mock would silently mis-price the moment the vault accrues
 *      yield. A configurable slippage haircut is applied to each leg; the value lost is
 *      retained by the adapter, simulating value captured by AMM LPs.
 *
 *      - Deposit leg (underlying -> shares): deposits (1 - ammSlippageBps) * amountIn into
 *        the vault, minting shares directly to the strategy; the remainder stays here.
 *      - Withdraw leg (shares -> underlying): redeems all shares, returns
 *        (1 - ammSlippageBps) of the proceeds to the strategy; the remainder stays here.
 *
 *      SOLVENCY INVARIANT: ammSlippageBps MUST be <= the strategy's slippageToleranceBps.
 *      The strategy derives its swap minOut from the haircut principal it credits; if the
 *      AMM slips more than the strategy's tolerance, deposits revert on the minOut check.
 *      DeployMocks asserts this relationship at deploy time.
 *
 *      LOCAL TESTING ONLY — never deploy to Sepolia or Mainnet (those use CurveAMMAdapter).
 */
contract MockMarketAMMAdapter is IAMMAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BPS = 10_000;

    /// @notice The underlying token (e.g. USDe) swapped into and out of the vault.
    IERC20 public immutable underlying;

    /// @notice The ERC4626 vault (e.g. MockSUSDe) whose shares are the other side of the swap.
    IERC4626 public immutable vault;

    /// @notice Simulated per-leg AMM slippage in basis points (e.g. 50 = 0.5%).
    uint256 public ammSlippageBps;

    event Swapped(
        address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut, uint256 slippageLost
    );

    constructor(address _underlying, address _vault, uint256 _ammSlippageBps) {
        require(_underlying != address(0), "MockMarketAMMAdapter: underlying zero");
        require(_vault != address(0), "MockMarketAMMAdapter: vault zero");
        require(_ammSlippageBps < MAX_BPS, "MockMarketAMMAdapter: slippage >= 100%");
        underlying = IERC20(_underlying);
        vault = IERC4626(_vault);
        ammSlippageBps = _ammSlippageBps;
    }

    /**
     * @notice Swap underlying<->vault shares through the real vault with a slippage haircut.
     * @dev Only the two supported directions are routable; any other pair reverts so a
     *      mis-wired strategy fails loudly rather than silently no-op'ing.
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "MockMarketAMMAdapter: amountIn zero");

        if (tokenIn == address(underlying) && tokenOut == address(vault)) {
            // Deposit leg: underlying -> vault shares. Pull the full input, lose a slice to
            // "slippage", deposit the remainder into the vault (shares minted to the strategy).
            underlying.safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 effectiveIn = amountIn * (MAX_BPS - ammSlippageBps) / MAX_BPS;
            underlying.forceApprove(address(vault), effectiveIn);
            amountOut = vault.deposit(effectiveIn, msg.sender);
            emit Swapped(tokenIn, tokenOut, amountIn, amountOut, amountIn - effectiveIn);
        } else if (tokenIn == address(vault) && tokenOut == address(underlying)) {
            // Withdraw leg: vault shares -> underlying. Pull the shares, redeem them in full,
            // then return all but the slippage slice to the strategy.
            IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), amountIn);
            uint256 grossAssets = vault.redeem(amountIn, address(this), address(this));
            amountOut = grossAssets * (MAX_BPS - ammSlippageBps) / MAX_BPS;
            underlying.safeTransfer(msg.sender, amountOut);
            emit Swapped(tokenIn, tokenOut, amountIn, amountOut, grossAssets - amountOut);
        } else {
            revert("MockMarketAMMAdapter: unsupported pair");
        }

        // Mirror the real adapter's slippage protection: honour the caller's minOut.
        require(amountOut >= minAmountOut, "MockMarketAMMAdapter: insufficient output");
        return amountOut;
    }
}
