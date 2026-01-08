// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@pauser/interfaces/IBurnable.sol";

/**
 * @title MockEYE
 * @notice Mock EYE token for testing the Global Pauser system
 * @dev Implements IBurnable interface required by the Pauser contract
 *      EYE token uses 18 decimals
 */
contract MockEYE is ERC20, IBurnable {
    constructor() ERC20("Mock EYE", "mEYE") {
        // Mint 1 million EYE (18 decimals) to deployer for testing
        _mint(msg.sender, 1_000_000 * 10**18);
    }

    /**
     * @notice Burn tokens from the caller's balance
     * @dev Required by IBurnable interface for Pauser contract
     * @param value Amount of tokens to burn
     */
    function burn(uint256 value) external override {
        _burn(msg.sender, value);
    }

    /**
     * @notice Allow anyone to mint for testing purposes
     * @dev In production, EYE token minting would be restricted
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
