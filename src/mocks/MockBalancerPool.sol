// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockBalancerPool
 * @notice Simple ERC20 BPT (Balancer Pool Token) for testing BalancerPooler dispatcher
 * @dev Represents the BPT token that would be minted by a Balancer V3 pool.
 *      The MockBalancerVault mints these tokens when addLiquidity is called.
 */
contract MockBalancerPool is ERC20 {
    /// @notice The MockBalancerVault address authorized to mint BPT
    address public vault;

    constructor() ERC20("Mock BPT phUSD-sUSDS Pool", "mBPT-phUSD-sUSDS") {}

    /**
     * @notice Sets the vault address authorized to mint BPT
     * @dev Must be called after MockBalancerVault deployment
     * @param vault_ The MockBalancerVault address
     */
    function setVault(address vault_) external {
        require(vault == address(0), "MockBalancerPool: vault already set");
        vault = vault_;
    }

    /**
     * @notice Mints BPT tokens to a recipient
     * @dev Only callable by the authorized vault
     * @param to The recipient address
     * @param amount The amount of BPT to mint
     */
    function mint(address to, uint256 amount) external {
        require(msg.sender == vault, "MockBalancerPool: only vault can mint");
        _mint(to, amount);
    }
}
