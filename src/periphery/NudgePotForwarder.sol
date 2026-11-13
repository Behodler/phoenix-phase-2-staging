// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The two NudgeStreamer entry points the forwarder needs.
interface INudgeStreamerForwardTarget {
    function collectNudge(address recipientBatchMinter, address token, uint256 amount) external;
    function streams(address batchMinter, address token)
        external
        view
        returns (uint256 duration, uint256 buffer, uint256 rewardPerSecond, uint256 lastUpdate);
    function pendingStream(address batchMinter, address token) external view returns (uint256);
}

/// @title  NudgePotForwarder  (phStaging2 story 119)
/// @notice One-shot, contract-to-contract carrier for the old batch minter's nudge pot. The cutover script
///         (`script/DeployMainnetNudgeDiscount.s.sol`, Phase 4) rescues each old-minter balance HERE
///         (`oldMinter.rescueERC20(token, forwarder, bal)`), then calls `forward(token)`, which approves exactly the
///         held balance to the NudgeStreamer and calls `collectNudge(recipient, token, amount)`. The tokens go
///         old minter -> forwarder -> the new minter's stream buffer. The owner EOA is never a recipient, and
///         nothing is transferred straight onto a batch minter. A raw minter balance is standing bonus that the
///         next batcher takes whole.
///
/// @dev    Bound at construction, with no setters and no rescue:
///           - `operator`: the only caller of `forward`. This is the cutover's Ledger owner, which pays gas and
///             receives nothing.
///           - `streamer`, `recipient`: the only place funds can go is `streamer.collectNudge(recipient, ...)`.
///           - `token0..2`: the only tokens it forwards (USDC, phUSD, Kendu on mainnet).
///         Nobody, the operator included, can redirect a held balance anywhere else. If a run dies between the
///         rescue and the forward, the balance waits here until a re-run (or the operator by hand) calls
///         `forward(token)`. Every forward ends with a zero balance and a zero streamer allowance, and
///         the stream buffer grows by exactly the amount forwarded. All three are checked in-call.
contract NudgePotForwarder {
    using SafeERC20 for IERC20;

    address public immutable operator;
    address public immutable streamer;
    address public immutable recipient;
    address public immutable token0;
    address public immutable token1;
    address public immutable token2;

    event Forwarded(address indexed token, uint256 amount);

    error NudgePotForwarder__ZeroAddress();
    error NudgePotForwarder__NotOperator(address caller);
    error NudgePotForwarder__TokenNotBound(address token);
    error NudgePotForwarder__NothingToForward(address token);
    error NudgePotForwarder__BufferDeltaMismatch(uint256 expected, uint256 actual);
    error NudgePotForwarder__ResidualBalance(uint256 balance);

    constructor(
        address operator_,
        address streamer_,
        address recipient_,
        address token0_,
        address token1_,
        address token2_
    ) {
        if (
            operator_ == address(0) || streamer_ == address(0) || recipient_ == address(0) || token0_ == address(0)
                || token1_ == address(0) || token2_ == address(0)
        ) revert NudgePotForwarder__ZeroAddress();
        operator = operator_;
        streamer = streamer_;
        recipient = recipient_;
        token0 = token0_;
        token1 = token1_;
        token2 = token2_;
    }

    function isBoundToken(address token) public view returns (bool) {
        return token == token0 || token == token1 || token == token2;
    }

    /// @notice Push this contract's whole `token` balance into `recipient`'s NudgeStreamer stream.
    /// @return amount The amount forwarded and credited to the stream buffer.
    function forward(address token) external returns (uint256 amount) {
        if (msg.sender != operator) revert NudgePotForwarder__NotOperator(msg.sender);
        if (!isBoundToken(token)) revert NudgePotForwarder__TokenNotBound(token);
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NudgePotForwarder__NothingToForward(token);

        INudgeStreamerForwardTarget ns = INudgeStreamerForwardTarget(streamer);
        // collectNudge settles the accrued stream to `recipient` before crediting, so the buffer delta is
        // (amount - settled). The settled part is read right before the call.
        (, uint256 buf0,,) = ns.streams(recipient, token);
        uint256 settle = ns.pendingStream(recipient, token);

        IERC20(token).forceApprove(streamer, amount);
        ns.collectNudge(recipient, token, amount);
        IERC20(token).forceApprove(streamer, 0);

        (, uint256 buf1,,) = ns.streams(recipient, token);
        if (buf1 != buf0 - settle + amount) {
            revert NudgePotForwarder__BufferDeltaMismatch(buf0 - settle + amount, buf1);
        }
        uint256 residual = IERC20(token).balanceOf(address(this));
        if (residual != 0) revert NudgePotForwarder__ResidualBalance(residual);
        emit Forwarded(token, amount);
    }
}
