// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The two Curve pool entry points the local pool mocks (`MockCurveStableSwapNG`,
///         `MockCurveDolaMetaPool`) implement, i.e. the stable-pool `int128` signatures.
interface ICurveStablePoolLike {
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
}

/// @title  MockCurveRouterNG
/// @notice Story 115. Local (anvil) stand-in for Curve Router NG v1.1
///         (`0x16C6521Dff6baB339122a0FE25a9116693265353`), the router SYAHarvester sells yield through.
///         Ported from sya-harvester `test/mocks/MockCurveRouter.sol` (the audit-01 M-01-faithful test
///         double, pin 6b862aa), with two deliberate upgrades:
///
///         1. Hops are EXECUTED against real pool contracts instead of paid from a pre-funded rate
///            table, so every output is a real balance moved by a real pool mock. `swap_type` 1 calls
///            `pool.exchange(i, j, dx, 0)`, `swap_type` 2 calls `pool.exchange_underlying(i, j, dx, 0)`,
///            exactly as Router NG dispatches them for stable pools.
///         2. Its reverts reproduce Router NG's observed revert DATA, not just the fact of a revert
///            (sya-harvester fork tests `test/fork/SYAHarvester.fork.t.sol`):
///            - a zero token inside the executed prefix reverts with EMPTY revert data (the real router
///              calls the code-less `address(0)`);
///            - an executed hop with an unknown `swap_type` (0, or 9 = ERC4626, which v1.1 rejects)
///              reverts `Error("Bad swap type")`;
///            - a delivered amount below `_expected` reverts `Error("Slippage")`.
///
/// @dev    Route walk, identical to Router NG v1.1: hop k runs while `_route[2k+1] != 0` and outputs
///         `_route[2k+2]`; the walk stops after hop k when `k == 4 || _route[2k+3] == 0`. So the
///         delivered token is `_route[2k]` at the FIRST empty pool slot `_route[2k+1]` (or `_route[10]`
///         after five hops), NOT the route's last non-zero entry (audit 01, M-01): any entry after the
///         first gap is ignored. Rows of `_swap_params` and slots of `_pools` beyond the executed prefix
///         are ignored, as the real router ignores them.
///
///         Not modelled (revert with a `MockCurveRouterNG:` message rather than silently misbehaving):
///         swap_types 3-8 (zaps, crypto pools, wrappers), native-ETH legs, `_pools`. `pool_type` and
///         `n_coins` are not read, since the stable-pool mocks all take the `int128` signatures.
///         A route with no hop at all (`_route[1] == 0`) reverts `NoHop()`; SYAHarvester never executes
///         one (its k = 0 reward-token route is accepted by `setRoute` but skipped by `_sellYield`).
contract MockCurveRouterNG {
    using SafeERC20 for IERC20;

    /// @dev `_route[1] == address(0)`: no hop to execute (mock-specific; see contract NatSpec)
    error NoHop();

    /// @dev Swap types this mock executes.
    uint256 internal constant SWAP_TYPE_EXCHANGE = 1;
    uint256 internal constant SWAP_TYPE_EXCHANGE_UNDERLYING = 2;
    /// @dev Highest swap type Router NG v1.1 knows; above it (e.g. 9, ERC4626) is "Bad swap type".
    uint256 internal constant MAX_KNOWN_SWAP_TYPE = 8;

    /// @dev tokenIn => number of successful `exchange` calls (mirrors the ported mock's counter).
    mapping(address => uint256) public calls;

    event Exchange(
        address indexed sender, address indexed receiver, address[11] route, uint256 amountIn, uint256 amountOut
    );

    /// @notice Token Router NG delivers for `_route`, and the number of hops it executes.
    /// @dev Reverts with empty data on a zero token inside the executed prefix, as the real router does.
    function resolveOutput(address[11] calldata _route) public pure returns (address tokenOut, uint256 hops) {
        if (_route[1] == address(0)) revert NoHop();
        for (uint256 i = 0; i < 5; i++) {
            tokenOut = _route[2 * i + 2];
            hops = i + 1;
            if (tokenOut == address(0)) _revertEmpty();
            if (i == 4 || _route[2 * i + 3] == address(0)) break;
        }
    }

    /// @notice Router NG v1.1 `exchange`. Pulls `_amount` of `_route[0]` from the caller, executes each
    ///         hop of the executed prefix against its pool, and pays the delivered token to `_receiver`.
    function exchange(
        address[11] calldata _route,
        uint256[5][5] calldata _swap_params,
        uint256 _amount,
        uint256 _expected,
        address[5] calldata,
        address _receiver
    ) external payable returns (uint256 amount) {
        require(msg.value == 0, "MockCurveRouterNG: native ETH not modelled");
        (address tokenOut, uint256 hops) = resolveOutput(_route);
        address tokenIn = _route[0];
        if (tokenIn == address(0)) _revertEmpty();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), _amount);
        amount = _amount;
        address input = tokenIn;
        for (uint256 h = 0; h < hops; h++) {
            amount = _hop(_route[2 * h + 1], input, _route[2 * h + 2], _swap_params[h], amount);
            input = _route[2 * h + 2];
        }

        require(amount >= _expected, "Slippage");
        calls[tokenIn]++;
        IERC20(tokenOut).safeTransfer(_receiver, amount);
        emit Exchange(msg.sender, _receiver, _route, _amount, amount);
    }

    /// @dev One hop: `amountIn` of `input` -> `output` through `pool`. The amount delivered is the
    ///      router's balance delta of `output`, as Router NG measures it.
    function _hop(address pool, address input, address output, uint256[5] calldata params, uint256 amountIn)
        internal
        returns (uint256)
    {
        uint256 swapType = params[2];
        if (swapType == 0 || swapType > MAX_KNOWN_SWAP_TYPE) revert("Bad swap type");
        require(
            swapType == SWAP_TYPE_EXCHANGE || swapType == SWAP_TYPE_EXCHANGE_UNDERLYING,
            "MockCurveRouterNG: swap_type not modelled"
        );

        int128 i = int128(int256(params[0]));
        int128 j = int128(int256(params[1]));
        uint256 before = IERC20(output).balanceOf(address(this));
        IERC20(input).forceApprove(pool, amountIn);
        if (swapType == SWAP_TYPE_EXCHANGE) {
            ICurveStablePoolLike(pool).exchange(i, j, amountIn, 0);
        } else {
            ICurveStablePoolLike(pool).exchange_underlying(i, j, amountIn, 0);
        }
        return IERC20(output).balanceOf(address(this)) - before;
    }

    function _revertEmpty() private pure {
        assembly {
            revert(0, 0)
        }
    }
}
