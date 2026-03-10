// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockWBTC
 * @notice Mock WBTC token for testing NFTMinter Gather dispatcher
 * @dev WBTC uses 8 decimals (matching real WBTC on mainnet)
 *      No IBurnable needed since Gather only calls IERC20.transfer()
 */
contract MockWBTC is ERC20 {
    constructor() ERC20("Mock WBTC", "mWBTC") {
        // Mint 100 WBTC (8 decimals) to deployer for testing
        _mint(msg.sender, 100 * 10 ** 8);
    }

    /**
     * @notice Override decimals to match real WBTC (8 decimals)
     */
    function decimals() public pure override returns (uint8) {
        return 8;
    }

    /**
     * @notice Allow anyone to mint for testing purposes
     * @dev In production, WBTC minting would be restricted
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
