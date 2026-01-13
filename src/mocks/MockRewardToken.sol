// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title MockRewardToken
 * @notice Simple ERC20 for testing reward distributions
 * @dev Simulates USDC with 6 decimals. Implements ERC-165 to prevent reverts
 *      when wallets/dapps check for NFT interfaces (ERC-721, ERC-1155).
 */
contract MockRewardToken is ERC20, IERC165 {
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

    /**
     * @notice ERC-165 interface detection
     * @dev Returns true only for ERC-165 itself. Returns false for ERC-721/ERC-1155
     *      to prevent wallet UIs from treating this as an NFT contract.
     */
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        // Only support ERC-165 interface detection itself
        return interfaceId == type(IERC165).interfaceId;
    }
}
