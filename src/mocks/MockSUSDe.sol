// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MockUSDe.sol";

/**
 * @title MockSUSDe
 * @notice Mock ERC4626 savings vault wrapping MockUSDe, simulating sUSDe on mainnet
 * @dev Share price = totalAssets (USDe balance) / totalSupply (sUSDe shares)
 *      Use addYield() to increase totalAssets without minting shares, raising share price
 */
contract MockSUSDe is ERC4626 {
    constructor(address _usde) ERC4626(IERC20(_usde)) ERC20("Mock sUSDe", "msUSDe") {}

    /**
     * @notice Returns total USDe held by this vault
     * @dev ERC4626 uses this for share/asset conversions
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Manually add yield to the vault for testing
     * @param amount The amount of USDe to mint directly into the vault as yield
     * @dev Increases totalAssets without increasing totalSupply, raising share price
     *      Example: 100 USDe deposited = 100 shares. addYield(100) -> totalAssets=200, share price=2
     */
    function addYield(uint256 amount) external {
        require(amount > 0, "MockSUSDe: amount must be greater than zero");
        MockUSDe(asset()).mint(address(this), amount);
    }

    /**
     * @notice Convenience mint for testing - deposits USDe and returns sUSDe shares
     * @param usdeAmount The amount of USDe to deposit
     * @dev Caller must have approved this contract to spend their USDe first
     */
    function mintShares(uint256 usdeAmount) external returns (uint256 shares) {
        return deposit(usdeAmount, msg.sender);
    }
}
