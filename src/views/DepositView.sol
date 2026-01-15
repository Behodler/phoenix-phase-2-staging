// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@phlimbo-ea/interfaces/IPhlimbo.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DepositView
 * @notice Aggregates all read-only data needed by the phlimbo-ui deposit page into a single view function call
 * @dev Enables efficient polling (one RPC call instead of many) and provides consistent data snapshots
 */
contract DepositView {
    /// @notice The Phlimbo staking contract
    IPhlimbo public immutable phlimbo;

    /// @notice The phUSD token
    IERC20 public immutable phUSD;

    /**
     * @notice Aggregated deposit page data for a user
     * @param userPhUSDBalance User's phUSD wallet balance
     * @param phUSDRewardsPerSecond Current phUSD emission rate from phlimbo
     * @param stableRewardsPerSecond Current USDC emission rate from phlimbo
     * @param pendingPhUSDRewards User's pending phUSD rewards
     * @param pendingStableRewards User's pending USDC rewards
     * @param stakedBalance User's staked phUSD amount
     * @param userAllowance User's phUSD allowance for phlimbo
     */
    struct DepositData {
        uint256 userPhUSDBalance;
        uint256 phUSDRewardsPerSecond;
        uint256 stableRewardsPerSecond;
        uint256 pendingPhUSDRewards;
        uint256 pendingStableRewards;
        uint256 stakedBalance;
        uint256 userAllowance;
    }

    /**
     * @notice Initializes the DepositView contract
     * @param _phlimbo Address of the Phlimbo staking contract
     * @param _phUSD Address of the phUSD token
     */
    constructor(IPhlimbo _phlimbo, IERC20 _phUSD) {
        require(address(_phlimbo) != address(0), "Invalid phlimbo address");
        require(address(_phUSD) != address(0), "Invalid phUSD address");
        phlimbo = _phlimbo;
        phUSD = _phUSD;
    }

    /**
     * @notice Returns all deposit-related data for a user in a single call
     * @param user Address of the user to query
     * @return data Aggregated deposit data struct
     */
    function getDepositData(address user) external view returns (DepositData memory data) {
        // Get user's phUSD wallet balance
        data.userPhUSDBalance = phUSD.balanceOf(user);

        // Get emission rates from phlimbo
        data.phUSDRewardsPerSecond = phlimbo.phUSDPerSecond();
        data.stableRewardsPerSecond = phlimbo.rewardPerSecond();

        // Get pending rewards for user
        data.pendingPhUSDRewards = phlimbo.pendingPhUSD(user);
        data.pendingStableRewards = phlimbo.pendingStable(user);

        // Get user's staked balance from userInfo
        (uint256 amount,,) = phlimbo.userInfo(user);
        data.stakedBalance = amount;

        // Get user's phUSD allowance for phlimbo
        data.userAllowance = phUSD.allowance(user, address(phlimbo));

        return data;
    }
}
