// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockRewardToken
 * @notice Simple ERC20 for testing reward distributions
 * @dev Simulates USDC with 6 decimals
 */
contract MockRewardToken is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        // Mint 1 million USDC (6 decimals) to deployer for testing
        _mint(msg.sender, 1_000_000 * 10**6);
    }

    /**
     * @notice Override decimals to match USDC (6 decimals)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Allow anyone to mint for testing purposes
     * @dev In production, this would be restricted
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
