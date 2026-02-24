// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BalancerECLPInterfaces
 * @notice Inline interface definitions for Balancer V3 Gyro E-CLP pool creation.
 *         The project does not depend on Balancer V3 as a git submodule, so all
 *         required types and function signatures are defined here.
 */

/// @notice Placeholder interface for rate providers (unused for STANDARD tokens).
interface IRateProvider {}

/// @notice Token classification within Balancer V3.
enum TokenType {
    STANDARD,
    WITH_RATE
}

/// @notice Per-token configuration passed to pool factories.
struct TokenConfig {
    IERC20 token;
    TokenType tokenType;
    IRateProvider rateProvider;
    bool paysYieldFees;
}

/// @notice Privileged roles assigned at pool creation.
struct PoolRoleAccounts {
    address pauseManager;
    address swapFeeManager;
    address poolCreator;
}

/// @notice Structs used by the Gyro E-CLP pool for its elliptic invariant curve.
interface IGyroECLPPool {
    /// @notice 2D vector used in derived parameter calculations.
    struct Vector2 {
        int256 x;
        int256 y;
    }

    /// @notice Base parameters that define the E-CLP pricing ellipse.
    /// @param alpha  Lower price bound (18-decimal)
    /// @param beta   Upper price bound (18-decimal)
    /// @param c      cos(phi) rotation angle (18-decimal)
    /// @param s      sin(phi) rotation angle (18-decimal)
    /// @param lambda Stretching factor (18-decimal)
    struct EclpParams {
        int256 alpha;
        int256 beta;
        int256 c;
        int256 s;
        int256 lambda;
    }

    /// @notice Derived parameters computed off-chain at 38-decimal precision.
    /// @param tauAlpha Unit-circle point for the lower price bound
    /// @param tauBeta  Unit-circle point for the upper price bound
    /// @param u        Transformation component: (A * chi)_y = lambda * u + v
    /// @param v        Transformation component
    /// @param w        Transformation component: (A * chi)_x = w / lambda + z
    /// @param z        Transformation component
    /// @param dSq      Error-corrected c^2 + s^2 at 38-decimal precision (~1e38)
    struct DerivedEclpParams {
        Vector2 tauAlpha;
        Vector2 tauBeta;
        int256 u;
        int256 v;
        int256 w;
        int256 z;
        int256 dSq;
    }
}

/// @notice Factory for deploying Gyro E-CLP pools on Balancer V3.
interface IGyroECLPPoolFactory {
    function create(
        string memory name,
        string memory symbol,
        TokenConfig[] memory tokens,
        IGyroECLPPool.EclpParams memory eclpParams,
        IGyroECLPPool.DerivedEclpParams memory derivedEclpParams,
        PoolRoleAccounts memory roleAccounts,
        uint256 swapFeePercentage,
        address poolHooksContract,
        bool enableDonation,
        bool disableUnbalancedLiquidity,
        bytes32 salt
    ) external returns (address pool);
}

/// @notice Balancer V3 Router for pool initialization.
interface IRouter {
    function initialize(
        address pool,
        IERC20[] memory tokens,
        uint256[] memory exactAmountsIn,
        uint256 minBptAmountOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256 bptAmountOut);
}

/// @notice Uniswap Permit2 allowance-based approval.
interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}
