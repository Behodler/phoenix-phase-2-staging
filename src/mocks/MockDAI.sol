// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockDAI
 * @notice Simple ERC20 for testing yield strategy with DAI
 * @dev Simulates DAI with 18 decimals
 */
contract MockDAI is ERC20 {
    constructor() ERC20("Mock DAI", "mDAI") {
        // Mint 1 million DAI (18 decimals) to deployer for testing
        _mint(msg.sender, 1_000_000 * 10**18);
    }

    /**
     * @notice Override decimals to match DAI (18 decimals)
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /**
     * @notice Allow anyone to mint for testing purposes
     * @dev In production, this would be restricted
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
