// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "./MockDola.sol";

/**
 * @title MockAutoDOLA
 * @notice Generic ERC4626 vault mock used to stand in for production AutoDola /
 *         AutoUSDC-style vaults on Anvil and Sepolia.
 * @dev Pure ERC4626 with a simple time-based yield simulation. No external
 *      staking / reward layer — the going-forward ERC4626YieldStrategy wraps
 *      the vault directly.
 */
contract MockAutoDOLA is ERC4626 {
    // Yield simulation state
    uint256 private lastYieldTimestamp;

    constructor(address _asset) ERC4626(IERC20(_asset)) ERC20("Mock AutoDOLA", "mAutoDOLA") {
        // ERC4626 automatically handles the asset
    }

    // ============ ERC4626 Overrides for Yield Simulation ============

    /**
     * @notice Override totalAssets to include yield simulation
     * @dev ERC4626 uses this for share/asset conversions
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Override _deposit to update yield before processing
     * @dev Called by ERC4626's deposit function
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // Update yield before processing deposit
        _updateYield();

        // Call parent implementation
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @notice Override _withdraw to update yield before processing
     * @dev Called by ERC4626's withdraw and redeem functions
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        // Update yield before processing withdrawal
        _updateYield();

        // Call parent implementation
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ============ Yield Simulation ============

    /**
     * @notice Public function to manually trigger yield accrual for testing
     * @dev Allows simulating yield generation without requiring a deposit/withdraw
     *      Call this after time has passed to accumulate yield in the vault
     */
    function accrueYield() external {
        _updateYield();
    }

    /**
     * @notice Manually add yield to the vault for testing (mints DOLA directly)
     * @param amount The amount of DOLA to mint as yield
     * @dev Useful for immediately testing yield without waiting for time to pass
     */
    function addYield(uint256 amount) external {
        require(amount > 0, "MockAutoDOLA: amount must be greater than zero");
        MockDola(asset()).mint(address(this), amount);
    }

    /**
     * @notice Internal function to update yield simulation
     * @dev Mints new DOLA tokens based on elapsed time since last yield update
     *      - First deposit: records timestamp, no yield minted
     *      - Subsequent deposits: calculates elapsed minutes and mints 0.01% per minute
     */
    function _updateYield() private {
        // First deposit - record timestamp and return
        if (lastYieldTimestamp == 0) {
            lastYieldTimestamp = block.timestamp;
            return;
        }

        // Calculate elapsed time in minutes
        uint256 elapsed = block.timestamp - lastYieldTimestamp;
        uint256 minutesPassed = elapsed / 60;

        // No yield if less than 1 minute passed
        if (minutesPassed == 0) {
            return;
        }

        // Get current DOLA balance in vault
        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));

        // Calculate yield: 0.01% per minute = balance * minutesPassed * 0.0001
        // Using fixed-point math: (balance * minutesPassed * 1) / 10000
        if (currentBalance > 0) {
            uint256 yieldAmount = (currentBalance * minutesPassed) / 10000;

            // Mint new DOLA tokens directly into this vault
            if (yieldAmount > 0) {
                MockDola(asset()).mint(address(this), yieldAmount);
            }
        }

        // Update timestamp for next yield calculation
        lastYieldTimestamp = block.timestamp;
    }
}
