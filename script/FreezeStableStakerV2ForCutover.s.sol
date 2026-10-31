// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {AntimatterPoolMainnetOps} from "./CutoverAntimatterPoolMainnet.s.sol";

/**
 * @title FreezeStableStakerV2ForCutover  (story 124, sprint sya-antimatter-cutover, audit run-44 M-02 / pps44m2)
 * @notice The SEPARATE freeze step that must be MINED before Script B (`CutoverAntimatterPoolMainnet`) starts its local
 *         pass. Up to three OWNER transactions on StableStakerV2 (SSV2, the only approved Antimatter minter), each
 *         skipped when already done:
 *           1. `SSV2.setPauser(OWNER)`          - skipped if the pauser is already OWNER;
 *           2. `Pauser.unregister(SSV2)`        - skipped if SSV2 is not registered;
 *           3. `SSV2.pause()`                   - skipped if already paused.
 *         End state, required: `paused && pauser == OWNER && !Pauser.isRegistered(SSV2)`.
 *
 *         WHY a separate invocation: forge-script `require`s run only in the local pass. B broadcasts with
 *         `--skip-simulation --slow`, so its `Antimatter.totalSupply() == 0` check is meaningful only if the pause is
 *         already on chain when B's local pass reads it. `npm run antimatter-pool:broadcast` chains this step before B
 *         with `&&`; `--slow` makes this process exit only after its receipts. Both use the same RPC
 *         (`${ANTIMATTER_POOL_RPC_URL:-$RPC_MAINNET}`), so B never reads `paused()` from a lagging node.
 *
 *         WHY this order (and not `setPauser(OWNER) -> pause -> setPauser(Pauser)`): the global `Pauser.pause()` loops
 *         every registrant with no try/catch; a registered SSV2 that is already paused reverts `EnforcedPause` and
 *         bricks the breaker for all registrants, for the whole window. So SSV2 is UNREGISTERED BEFORE it is paused
 *         (rule of `CutoverStableStakerV2Mainnet` L44-58). One transient one-tx window remains: between tx1 and tx2
 *         the breaker reverts (a registrant whose pauser is OWNER rejects the Pauser). Never use `Pauser.pause()`
 *         itself here: it burns EYE and pauses all registrants, Antimatter included.
 *
 *         COMPLETED-B SHORT-CIRCUIT: if Script B has already completed on chain (`_bCompletedOnChain`: the progress
 *         pair exists, OWNER holds at least the recorded LP, the seeder is not an AM minter, SSV2 is unpaused with
 *         `pauser == Pauser` and registered) the run is a full no-op. This keeps the runbook's "A failed -> re-run
 *         the combined key" recovery from re-freezing SSV2.
 *
 *         While frozen: `stake`, `withdraw`, `claim`, `autoAnnihilate` revert `EnforcedPause` (UI in maintenance
 *         mode); `emergencyWithdraw` stays open and mints nothing. Do not initiate an SSV2 migration (`batchMigrate` /
 *         `userMigrate` mint ungated). Script B's last transactions restore SSV2; if B aborts, the human decides
 *         whether to run `npm run ssv2-unfreeze-after-cutover-abort:broadcast`.
 *
 * Preview:   npm run ssv2-freeze-for-cutover:preview   (OWNER prank on a fork; probes the global Pauser before and after)
 * Broadcast: npm run ssv2-freeze-for-cutover:broadcast (Ledger; chained by antimatter-pool:broadcast)
 */
contract FreezeStableStakerV2ForCutover is AntimatterPoolMainnetOps {
    bool public skippedBCompleted;

    function run() external {
        console.log("=================================================");
        console.log("  FREEZE StableStakerV2 for the Antimatter cutover - MAINNET (story 124, M-02)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed)" : "Mode: BROADCAST (Ledger)");

        Config memory c = expectedConfig();
        _preflight(c);
        console.log("Preflight OK: OWNER owns StableStakerV2 and Pauser");
        console.log("  StableStakerV2:", c.stableStakerV2);
        console.log("  Pauser:        ", c.pauser);

        if (_bCompletedOnChain(c, _readProgress())) {
            skippedBCompleted = true;
            console.log("Script B already COMPLETED on chain - freeze NOT applied (no-op). Transactions this run: 0");
            return;
        }

        if (isPreview && _ssv2Restored(c)) _assertGlobalPauseWorks(c, "before-freeze");
        _freezeSsv2(c);
        if (isPreview) _assertGlobalPauseWorks(c, "frozen");
        console.log("SSV2 frozen: paused, pauser == OWNER, not a Pauser registrant");
        console.log("Transactions this run:", txCount);
    }
}
