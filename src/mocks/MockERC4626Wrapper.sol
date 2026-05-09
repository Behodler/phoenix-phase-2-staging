// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC4626Wrapper
 * @notice Minimal ERC4626-shaped wrapper mock used to stand in for the on-chain
 *         "Wrapped Aave Ethereum USDC" (waUSDC) on dev/anvil. Exposes a
 *         configurable share-to-asset rate and only the methods
 *         BalancerPoolerV2 actually uses (`asset()` and
 *         `redeem(shares, receiver, owner)`).
 * @dev    Mirrors the upstream pattern at
 *         lib/yield-claim-nft/test/mocks/MockERC4626Wrapper.sol (commit 07d4530).
 *
 *         `decimals()` is configurable so a 6-decimal token like waUSDC can be
 *         modelled.
 *
 *         `rateBps`: 10000 = 1:1 (1 share == 1 asset). 5000 = 0.5 assets per
 *         share, etc. Asset payout = (shares * rateBps) / 10000.
 *
 *         The wrapper must hold underlying `asset()` balance to satisfy
 *         `redeem` payouts. Tests/dev scripts pre-fund the wrapper directly.
 */
contract MockERC4626Wrapper is ERC20 {
    address private immutable _asset;
    uint8 private immutable _decimals;
    uint256 public rateBps;

    constructor(string memory name_, string memory symbol_, address asset_, uint8 decimals_, uint256 rateBps_)
        ERC20(name_, symbol_)
    {
        _asset = asset_;
        _decimals = decimals_;
        rateBps = rateBps_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @dev Mock-only: tune the share-to-asset rate. 10000 = 1:1.
    function setRate(uint256 rateBps_) external {
        rateBps = rateBps_;
    }

    /// @dev Mock-only: mint shares to an address (no underlying transfer).
    ///      Called by MockBalancerVault.swap to deliver tokenOut shares.
    function mintShares(address to, uint256 shares) external {
        _mint(to, shares);
    }

    /**
     * @notice Burns `shares` from `owner` and transfers `(shares * rateBps / 10000)`
     *         of the underlying asset to `receiver`. Does not enforce ERC20
     *         allowance from `owner` -> `msg.sender` because the production caller
     *         (BalancerPoolerV2) always invokes with `owner == address(this)`.
     */
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        _burn(owner, shares);
        assets = (shares * rateBps) / 10000;
        IERC20(_asset).transfer(receiver, assets);
    }
}
