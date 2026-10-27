// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockCrvUSD
 * @notice Story 115. Local (anvil) stand-in for Curve's crvUSD (18 decimals), the intermediate
 *         token of the mainnet SYAHarvester USDe route USDe -> crvUSD -> USDC.
 * @dev Same shape as the other mock stables in `src/mocks/`: plain ERC20 with a permissionless
 *      `mint`. Nothing is pre-minted; DeployMocks funds the Curve pool mocks explicitly.
 */
contract MockCrvUSD is ERC20 {
    constructor() ERC20("Mock crvUSD", "mcrvUSD") {}

    /// @notice Allow anyone to mint for testing purposes.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
