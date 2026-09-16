// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {
    DolaStrategyWithdrawalBase,
    IDolaYieldStrategyLive,
    IPhusdStableMinterConfigs
} from "./InitiateDolaStrategyWithdrawal.s.sol";

/**
 * @title DolaStrategyWithdrawalStatus  (story 090)
 * @notice READ-ONLY status of the PhusdStableMinter's two-phase DOLA `totalWithdrawal` on the autoDOLA strategy
 *         0x1760. No prank, no broadcast, no state change - safe to run anytime:
 *           npm run dola-ys-withdrawal:status
 *         The stored status is LAZY (Executable/Expired are only written inside a totalWithdrawal call), so the
 *         effective phase is derived here from initiatedAt and block.timestamp.
 *
 *         AFTER THE CUTOVER (story 092): Phase 6b of script/CutoverStableStakerV2Mainnet.s.sol executes this withdrawal,
 *         repoints the minter's DOLA registration to the sDOLA strategy and retires 0x1760 (paused, unregistered). The
 *         script still reads cleanly then - status None, principal 0, strategy paused, registration no longer 0x1760 -
 *         and prints a `withdrawal completed / strategy retired` line instead of a pending phase. Kept, not obsoleted: it
 *         is the operator's check between the initiate broadcast and the cutover, and a post-cutover sanity read.
 */
contract DolaStrategyWithdrawalStatus is DolaStrategyWithdrawalBase {
    /// @notice Story 097: the effective-phase headline from live chain state (the same string `run()` prints).
    function _currentVerdict() internal view returns (string memory) {
        IDolaYieldStrategyLive strategy = _strategy();
        (uint256 initiatedAt, uint8 status,) = strategy.withdrawalStates(DOLA, PHUSD_STABLE_MINTER);
        return _phaseVerdict(_effectivePhase(status, initiatedAt, block.timestamp), strategy.paused());
    }

    function run() external view {
        IDolaYieldStrategyLive strategy = _strategy();
        (uint256 initiatedAt, uint8 status, uint256 balance) = strategy.withdrawalStates(DOLA, PHUSD_STABLE_MINTER);
        uint256 principal = strategy.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 nowTs = block.timestamp;

        console.log("=========================================");
        console.log("  DOLA strategy withdrawal status (read-only)");
        console.log("=========================================");
        console.log("chainid:            ", block.chainid);
        console.log("strategy:           ", YIELD_STRATEGY_DOLA);
        console.log("client (minter):    ", PHUSD_STABLE_MINTER);
        console.log("now (unix):         ", nowTs, _isoUtc(nowTs));
        console.log("strategy paused:    ", strategy.paused());
        console.log("stored status:      ", status, _statusName(status));
        console.log("principal now:      ", principal);
        console.log("snapshot balance:   ", balance);
        if (balance != 0 && principal != balance) {
            console.log("  note: principal moved since initiation (execution sweeps LIVE principal - nothing lost)");
        }

        // Story 097 (audit-35 status Q-01): phases honour the cutover's 6h start margin and the strategy pause.
        uint8 phase = _effectivePhase(status, initiatedAt, nowTs);
        if (status == STATUS_INITIATED || status == STATUS_EXECUTABLE) {
            uint256 executableAt = initiatedAt + WAITING_PERIOD;
            uint256 startDeadline = _startDeadline(initiatedAt);
            uint256 expiresAt = initiatedAt + TOTAL_DURATION;
            console.log("initiatedAt:        ", initiatedAt, _isoUtc(initiatedAt));
            console.log("executableAt:       ", executableAt, _isoUtc(executableAt));
            console.log("start deadline:     ", startDeadline, _isoUtc(startDeadline));
            console.log("  (= expiresAt - WINDOW_SAFETY_MARGIN 6h; the cutover must START strictly before it)");
            console.log("expiresAt:          ", expiresAt, _isoUtc(expiresAt));
        }
        console.log("effective phase:    ", _phaseVerdict(phase, strategy.paused()));
        if (phase == PHASE_WAITING) {
            console.log("                     seconds until executable:", initiatedAt + WAITING_PERIOD - nowTs);
            console.log("                     seconds until start deadline:", _startDeadline(initiatedAt) - nowTs);
        } else if (phase == PHASE_START_OK) {
            console.log("                     seconds until start deadline:", _startDeadline(initiatedAt) - nowTs);
            console.log("                     seconds until expiry:", initiatedAt + TOTAL_DURATION - nowTs);
        } else if (phase == PHASE_TOO_LATE_TO_START) {
            console.log("                     seconds until expiry (then re-initiate):", initiatedAt + TOTAL_DURATION - nowTs);
        }

        (address ys,,, bool enabled,,,) = IPhusdStableMinterConfigs(PHUSD_STABLE_MINTER).stablecoinConfigs(DOLA);
        console.log("minter DOLA yieldStrategy:", ys);
        console.log("minter DOLA enabled:      ", enabled);
        console.log("still registered to 0x1760:", ys == YIELD_STRATEGY_DOLA);
        if (status == STATUS_NONE && principal == 0 && ys != YIELD_STRATEGY_DOLA) {
            console.log(
                strategy.paused()
                    ? "RESULT: withdrawal completed / strategy retired (story 092 cutover Phase 6b) - nothing left to execute"
                    : "RESULT: withdrawal completed, minter repointed; strategy NOT yet paused (cutover Phase 6b retirement outstanding)"
            );
        }
    }
}
