// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@vault/imports/IMainRewarder.sol";
import "./MockToke.sol";

/**
 * @title MockMainRewarder
 * @notice Mock implementation of IMainRewarder interface for testing AutoDolaYieldStrategy
 * @dev Implements Tokemak MainRewarder interface with time-based reward accumulation
 *
 * Reward Formula:
 * - Base rate: 0.01% per minute (same as MockAutoDOLA)
 * - Calculation: (staked_balance * minutes_elapsed) / 10000
 * - Rewards accumulate based on time elapsed since last update
 * - Updates occur on stake, withdraw, and getReward operations
 */
contract MockMainRewarder is IMainRewarder {
    address public immutable stakingToken;
    address private immutable _rewardToken;

    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _rewards;
    mapping(address => uint256) private _lastRewardTimestamp;
    uint256 private _totalSupply;

    constructor(address _stakingToken, address __rewardToken) {
        stakingToken = _stakingToken;
        _rewardToken = __rewardToken;
    }

    /**
     * @notice Stake tokens
     * @param account Account staking tokens
     * @param amount Amount to stake
     */
    function stake(address account, uint256 amount) external override {
        require(amount > 0, "MockMainRewarder: zero stake");

        // Update rewards before changing balance
        _updateRewards(account);

        // Transfer staking tokens from caller
        IERC20(stakingToken).transferFrom(msg.sender, address(this), amount);

        // Update balance
        _balances[account] += amount;
        _totalSupply += amount;
    }

    /**
     * @notice Withdraw staked tokens
     * @param account Account withdrawing tokens
     * @param amount Amount to withdraw
     * @param claim Whether to claim rewards
     */
    function withdraw(address account, uint256 amount, bool claim) external override {
        require(_balances[account] >= amount, "MockMainRewarder: insufficient balance");

        // Update rewards before changing balance
        _updateRewards(account);

        // Update balance
        _balances[account] -= amount;
        _totalSupply -= amount;

        // Transfer staking tokens back
        IERC20(stakingToken).transfer(msg.sender, amount);

        // Claim rewards if requested
        if (claim && _rewards[account] > 0) {
            uint256 reward = _rewards[account];
            _rewards[account] = 0;

            // Transfer reward tokens to caller
            IERC20(_rewardToken).transfer(msg.sender, reward);
        }
    }

    /**
     * @notice Get rewards for account
     * @param account Account to check
     * @param recipient Recipient of rewards
     * @param claimExtras Whether to claim extra rewards
     * @return success Whether claim was successful
     */
    function getReward(address account, address recipient, bool claimExtras) external override returns (bool success) {
        // Update rewards before claiming
        _updateRewards(account);

        uint256 reward = _rewards[account];
        if (reward > 0) {
            _rewards[account] = 0;

            // Transfer reward tokens to recipient
            IERC20(_rewardToken).transfer(recipient, reward);
        }
        return true;
    }

    /**
     * @notice Get staked balance
     * @param account Account to check
     * @return balance Staked balance
     */
    function balanceOf(address account) external view override returns (uint256 balance) {
        return _balances[account];
    }

    /**
     * @notice Get earned rewards including pending time-based rewards
     * @param account Account to check
     * @return reward Total earned rewards
     */
    function earned(address account) external view override returns (uint256 reward) {
        return _rewards[account] + _calculatePendingRewards(account);
    }

    /**
     * @notice Get the total supply of staked shares
     * @return The total amount of shares staked
     */
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @notice Get the reward token (TOKE) address
     * @return The address of the TOKE token
     */
    function rewardToken() external view override returns (address) {
        return _rewardToken;
    }

    /**
     * @notice Internal function to update reward accumulation based on time
     * @dev Calculates and adds time-based rewards since last update
     *      - First stake: records timestamp, no rewards added
     *      - Subsequent updates: calculates elapsed minutes and mints 0.01% per minute
     * @param account Account to update rewards for
     */
    function _updateRewards(address account) private {
        // First stake - record timestamp and return
        if (_lastRewardTimestamp[account] == 0) {
            _lastRewardTimestamp[account] = block.timestamp;
            return;
        }

        // Calculate pending rewards and add to balance
        uint256 pending = _calculatePendingRewards(account);
        if (pending > 0) {
            // Mint reward tokens directly to this contract
            MockToke(_rewardToken).mint(address(this), pending);
            _rewards[account] += pending;
        }

        // Update timestamp for next calculation
        _lastRewardTimestamp[account] = block.timestamp;
    }

    /**
     * @notice Calculate pending rewards based on time elapsed
     * @dev Returns pending rewards without updating state
     * @param account Account to calculate rewards for
     * @return pending Pending reward amount
     */
    function _calculatePendingRewards(address account) private view returns (uint256 pending) {
        // No rewards if never staked
        if (_lastRewardTimestamp[account] == 0) {
            return 0;
        }

        // Calculate elapsed time in minutes
        uint256 elapsed = block.timestamp - _lastRewardTimestamp[account];
        uint256 minutesPassed = elapsed / 60;

        // No rewards if less than 1 minute passed
        if (minutesPassed == 0) {
            return 0;
        }

        // Get current staked balance
        uint256 currentBalance = _balances[account];

        // Calculate rewards: 0.01% per minute = balance * minutesPassed * 0.0001
        // Using fixed-point math: (balance * minutesPassed * 1) / 10000
        if (currentBalance > 0) {
            return (currentBalance * minutesPassed) / 10000;
        }

        return 0;
    }
}
