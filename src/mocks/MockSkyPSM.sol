// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  MockSkyPSM
/// @notice Local mock of the Sky USDS↔USDC PSM (`UsdsPsmWrapper`) used by
///         `BalancerPoolerV2`'s Sky-route batch donation on Anvil. It mirrors the
///         minimal `ISkyPSM` surface the pooler consumes: `buyGem` (USDS→USDC),
///         `tout`, `to18ConversionFactor`, `gem`, `usds`.
/// @dev    Reserve-backed and fixed-rate, matching the real PSM's behaviour: there
///         is no price curve, slippage, or imbalance ceiling — only the `tout` fee.
///         `buyGem(usr, gemAmt)` pulls `gemAmt * to18ConversionFactor * (1e18 + tout) / 1e18`
///         USDS from `msg.sender` and delivers `gemAmt` USDC (6dp) to `usr` from the
///         mock's pre-funded USDC reserve. The mock's USDC reserve must be seeded by
///         the deploy script (`gem().mint(address(mockPSM), ...)`).
contract MockSkyPSM {
    uint256 internal constant WAD = 1e18;

    /// @notice The gem token delivered by `buyGem` (USDC, 6dp).
    address public immutable gem;

    /// @notice The Sky stablecoin pulled by `buyGem` (USDS, 18dp).
    address public immutable usds;

    /// @notice 10**(18 - gem.decimals()); 1e12 for 6-decimal USDC.
    uint256 internal immutable _conv;

    /// @notice Buy-side fee, WAD-scaled (1e18 == 100%). Owner-settable for testing
    ///         fee-spike scenarios; defaults to 0 to match the live PSM's ~0 tout.
    uint256 public tout;

    /// @param gem_  The USDC mock (6dp).
    /// @param usds_ The USDS mock (18dp).
    constructor(address gem_, address usds_) {
        require(gem_ != address(0), "MockSkyPSM: zero gem");
        require(usds_ != address(0), "MockSkyPSM: zero usds");
        gem = gem_;
        usds = usds_;
        _conv = 10 ** (18 - IERC20Decimals(gem_).decimals());
    }

    /// @notice 10**(18 - gem.decimals()).
    function to18ConversionFactor() external view returns (uint256) {
        return _conv;
    }

    /// @notice Test helper: set the buy-side fee.
    function setTout(uint256 newTout) external {
        tout = newTout;
    }

    /// @notice Buy `gemAmt` USDC for `usr`, pulling USDS (incl. tout fee) from msg.sender.
    /// @dev    Mirrors DssLitePsm._buyGem: usdsIn = gemAmt * conv * (WAD + tout) / WAD.
    ///         Delivers `gemAmt` USDC from this mock's pre-funded reserve.
    /// @return usdsInWad The USDS (18dp) pulled from msg.sender.
    function buyGem(address usr, uint256 gemAmt) external returns (uint256 usdsInWad) {
        require(gemAmt > 0, "MockSkyPSM: zero gemAmt");
        usdsInWad = gemAmt * _conv * (WAD + tout) / WAD;
        require(
            IERC20(usds).transferFrom(msg.sender, address(this), usdsInWad),
            "MockSkyPSM: USDS pull failed"
        );
        require(
            IERC20(gem).transfer(usr, gemAmt),
            "MockSkyPSM: USDC reserve short"
        );
    }
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}
