// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DolaStrategyWithdrawalStatus} from "../script/DolaStrategyWithdrawalStatus.s.sol";
import {IDolaYieldStrategyLive} from "../script/InitiateDolaStrategyWithdrawal.s.sol";
import {CutoverStableStakerV2Mainnet} from "../script/CutoverStableStakerV2Mainnet.s.sol";

/// @dev Exposes the status script's pure phase decision and its chain-reading verdict.
contract DolaStrategyWithdrawalStatusHarness is DolaStrategyWithdrawalStatus {
    function phase(uint8 status, uint256 initiatedAt, uint256 nowTs) external pure returns (uint8) {
        return _effectivePhase(status, initiatedAt, nowTs);
    }

    function verdict(uint8 p, bool paused) external pure returns (string memory) {
        return _phaseVerdict(p, paused);
    }

    function startDeadline(uint256 initiatedAt) external pure returns (uint256) {
        return _startDeadline(initiatedAt);
    }

    function currentVerdict() external view returns (string memory) {
        return _currentVerdict();
    }

    function PHASE_NONE_() external pure returns (uint8) { return PHASE_NONE; }
    function PHASE_WAITING_() external pure returns (uint8) { return PHASE_WAITING; }
    function PHASE_START_OK_() external pure returns (uint8) { return PHASE_START_OK; }
    function PHASE_TOO_LATE_() external pure returns (uint8) { return PHASE_TOO_LATE_TO_START; }
    function PHASE_EXPIRED_() external pure returns (uint8) { return PHASE_EXPIRED; }
}

/**
 * @title DolaStrategyWithdrawalStatusTest  (story 097, audit-35 status Q-01 / initiate Q-01)
 * @notice Non-fork: the 6h WINDOW_SAFETY_MARGIN drift guard against the cutover and the status phase table
 *         (incl. the last-6h and paused cases). One fork test drives `_currentVerdict` against live 0x1760 with
 *         the withdrawal state and `paused()` mocked; it skips without RPC_MAINNET.
 */
contract DolaStrategyWithdrawalStatusTest is Test {
    DolaStrategyWithdrawalStatusHarness s;
    uint256 constant T = 1_789_569_551; // fork-era initiatedAt from the audit
    uint8 constant NONE = 0;
    uint8 constant INITIATED = 1;
    uint8 constant EXECUTABLE = 2;
    uint8 constant EXPIRED = 3;

    function setUp() public {
        s = new DolaStrategyWithdrawalStatusHarness();
    }

    // ---------------------------------------------------------------- drift guard

    function test_windowSafetyMargin_matches_cutover() public {
        CutoverStableStakerV2Mainnet cutover = new CutoverStableStakerV2Mainnet();
        assertEq(s.WINDOW_SAFETY_MARGIN(), cutover.WINDOW_SAFETY_MARGIN(), "base margin drifted from cutover");
        assertEq(s.WINDOW_SAFETY_MARGIN(), 6 hours, "margin is 6h");
        assertEq(s.WAITING_PERIOD(), cutover.DOLA_WITHDRAWAL_WAITING_PERIOD(), "waiting period drifted from cutover");
        assertEq(s.EXECUTION_WINDOW(), cutover.DOLA_WITHDRAWAL_EXECUTION_WINDOW(), "execution window drifted from cutover");
    }

    function test_startDeadline_is_expiry_minus_margin() public view {
        assertEq(s.startDeadline(T), T + 78 hours - 6 hours);
    }

    // ---------------------------------------------------------------- phase table

    function test_phase_none_when_not_initiated() public view {
        assertEq(s.phase(NONE, 0, T), s.PHASE_NONE_());
    }

    function test_phase_waiting() public view {
        assertEq(s.phase(INITIATED, T, T), s.PHASE_WAITING_());
        assertEq(s.phase(INITIATED, T, T + 6 hours - 1), s.PHASE_WAITING_());
    }

    function test_phase_start_ok_from_executableAt_until_margin() public view {
        assertEq(s.phase(INITIATED, T, T + 6 hours), s.PHASE_START_OK_());
        assertEq(s.phase(EXECUTABLE, T, T + 40 hours), s.PHASE_START_OK_());
        // cutover gate: now + 6h < closesAt  =>  last start second is closesAt - 6h - 1
        assertEq(s.phase(INITIATED, T, T + 72 hours - 1), s.PHASE_START_OK_());
    }

    function test_phase_too_late_in_last_6h() public view {
        assertEq(s.phase(INITIATED, T, T + 72 hours), s.PHASE_TOO_LATE_());
        assertEq(s.phase(INITIATED, T, T + 75 hours), s.PHASE_TOO_LATE_());
        assertEq(s.phase(EXECUTABLE, T, T + 78 hours), s.PHASE_TOO_LATE_()); // execute still valid at <= closesAt
    }

    function test_phase_expired() public view {
        assertEq(s.phase(INITIATED, T, T + 78 hours + 1), s.PHASE_EXPIRED_());
        assertEq(s.phase(EXPIRED, T, T + 10 hours), s.PHASE_EXPIRED_()); // stored Expired
    }

    // ---------------------------------------------------------------- verdict strings

    function test_verdict_start_ok_unpaused() public view {
        assertEq(s.verdict(s.PHASE_START_OK_(), false), "EXECUTABLE - cutover may START (>6h left)");
    }

    function test_verdict_too_late_unpaused() public view {
        assertEq(
            s.verdict(s.PHASE_TOO_LATE_(), false),
            "EXECUTABLE but too late to START a cutover (<6h left): wait for expiry, then re-initiate"
        );
    }

    function test_verdict_paused_overrides_every_pending_phase() public view {
        uint8[4] memory ps = [s.PHASE_WAITING_(), s.PHASE_START_OK_(), s.PHASE_TOO_LATE_(), s.PHASE_EXPIRED_()];
        for (uint256 i = 0; i < ps.length; i++) {
            string memory v = s.verdict(ps[i], true);
            assertTrue(_startsWith(v, "strategy PAUSED - execute will revert"), "paused override first");
            assertFalse(_startsWith(v, "EXECUTABLE"), "no executable headline while paused");
        }
        assertEq(
            s.verdict(s.PHASE_START_OK_(), true),
            "strategy PAUSED - execute will revert (underlying phase: EXECUTABLE - cutover may START (>6h left))"
        );
    }

    function test_verdict_none_not_overridden_by_pause() public view {
        // after the cutover 0x1760 is retired paused with nothing pending: the pause is expected there
        assertEq(s.verdict(s.PHASE_NONE_(), true), s.verdict(s.PHASE_NONE_(), false));
    }

    // ---------------------------------------------------------------- fork (mocked state on live 0x1760)

    function test_fork_status_last6h_and_paused() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 25_978_784);
        s = new DolaStrategyWithdrawalStatusHarness();
        address ys = s.YIELD_STRATEGY_DOLA();
        uint256 ia = block.timestamp - 75 hours; // 3h before expiry
        vm.mockCall(
            ys,
            abi.encodeWithSelector(IDolaYieldStrategyLive.withdrawalStates.selector, s.DOLA(), s.PHUSD_STABLE_MINTER()),
            abi.encode(ia, INITIATED, uint256(1e18))
        );
        vm.mockCall(ys, abi.encodeWithSelector(IDolaYieldStrategyLive.paused.selector), abi.encode(false));
        assertEq(
            s.currentVerdict(),
            "EXECUTABLE but too late to START a cutover (<6h left): wait for expiry, then re-initiate"
        );
        s.run(); // prints without reverting

        vm.mockCall(ys, abi.encodeWithSelector(IDolaYieldStrategyLive.paused.selector), abi.encode(true));
        assertTrue(_startsWith(s.currentVerdict(), "strategy PAUSED - execute will revert"));
        s.run();
    }

    function _startsWith(string memory a, string memory p) internal pure returns (bool) {
        bytes memory ab = bytes(a);
        bytes memory pb = bytes(p);
        if (ab.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; i++) {
            if (ab[i] != pb[i]) return false;
        }
        return true;
    }
}
