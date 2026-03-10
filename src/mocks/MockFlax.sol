// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@pauser/interfaces/IBurnable.sol";

/**
 * @title MockFlax
 * @notice Mock Flax token for testing NFTMinter Burner dispatcher
 * @dev Implements IBurnable interface required by the Burner dispatcher
 *      Flax token uses 18 decimals
 */
contract MockFlax is ERC20, IBurnable {
    constructor() ERC20("Mock Flax", "mFLAX") {
        // Mint 1 million Flax (18 decimals) to deployer for testing
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    /**
     * @notice Burn tokens from the caller's balance
     * @dev Required by IBurnable interface for Burner dispatcher
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Allow anyone to mint for testing purposes
     * @dev In production, Flax token minting would be restricted
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
