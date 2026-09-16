// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MockDola.sol";

/**
 * @title MockSDOLA
 * @notice Mock ERC4626 savings vault wrapping MockDola, standing in for Inverse's sDOLA on Anvil
 *         (mainnet sDOLA: 0xb45ad160634c528Cc3D2926d9807104FA3157305, asset() == DOLA
 *         0x865377367054516e17014CcdED1e7d814EDC9ce4, verified on mainnet in story 089).
 * @dev Same shape as MockSUSDS: a plain OZ ERC4626 whose share price is
 *      totalAssets (DOLA balance) / totalSupply (msDOLA shares). No delay, fee or oracle.
 *      Use addYield() to raise totalAssets without minting shares, raising the share price.
 *      It is the DESTINATION vault of the local autoDOLA -> sDOLA rehearsal; MockAutoDOLA stays
 *      the source.
 */
contract MockSDOLA is ERC4626 {
    constructor(address _dola) ERC4626(IERC20(_dola)) ERC20("Mock sDOLA", "msDOLA") {}

    /**
     * @notice Returns total DOLA held by this vault
     * @dev ERC4626 uses this for share/asset conversions
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Manually add yield to the vault for testing
     * @param amount The amount of DOLA to mint directly into the vault as yield
     * @dev Increases totalAssets without increasing totalSupply, raising share price
     */
    function addYield(uint256 amount) external {
        require(amount > 0, "MockSDOLA: amount must be greater than zero");
        MockDola(asset()).mint(address(this), amount);
    }

    /**
     * @notice Convenience mint for testing - deposits DOLA and returns msDOLA shares
     * @param dolaAmount The amount of DOLA to deposit
     * @dev Caller must have approved this contract to spend their DOLA first
     */
    function mintShares(uint256 dolaAmount) external returns (uint256 shares) {
        return deposit(dolaAmount, msg.sender);
    }
}
