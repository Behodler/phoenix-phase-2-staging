// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MockUSDS.sol";

/**
 * @title MockSUSDS
 * @notice Mock ERC4626 savings vault wrapping MockUSDS, simulating sUSDS on mainnet
 * @dev Share price = totalAssets (USDS balance) / totalSupply (sUSDS shares)
 *      Use addYield() to increase totalAssets without minting shares, raising share price
 */
contract MockSUSDS is ERC4626 {
    constructor(address _usds) ERC4626(IERC20(_usds)) ERC20("Mock sUSDS", "msUSDS") {}

    /**
     * @notice Returns total USDS held by this vault
     * @dev ERC4626 uses this for share/asset conversions
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Manually add yield to the vault for testing
     * @param amount The amount of USDS to mint directly into the vault as yield
     * @dev Increases totalAssets without increasing totalSupply, raising share price
     *      Example: 100 USDS deposited = 100 shares. addYield(100) -> totalAssets=200, share price=2
     */
    function addYield(uint256 amount) external {
        require(amount > 0, "MockSUSDS: amount must be greater than zero");
        MockUSDS(asset()).mint(address(this), amount);
    }

    /**
     * @notice Convenience mint for testing - deposits USDS and returns sUSDS shares
     * @param usdsAmount The amount of USDS to deposit
     * @dev Caller must have approved this contract to spend their USDS first
     */
    function mintShares(uint256 usdsAmount) external returns (uint256 shares) {
        return deposit(usdsAmount, msg.sender);
    }
}
