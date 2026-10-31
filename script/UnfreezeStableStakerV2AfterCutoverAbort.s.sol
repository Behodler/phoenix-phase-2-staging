// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {AntimatterPoolMainnetOps, IAmCutoverAntimatter} from "./CutoverAntimatterPoolMainnet.s.sol";

/**
 * @title UnfreezeStableStakerV2AfterCutoverAbort  (story 124, sprint sya-antimatter-cutover, recovery only)
 * @notice Restores StableStakerV2 (SSV2) after the human has decided to ABANDON a freeze window - typically after
 *         Script B aborted with `Antimatter.totalSupply() != 0`. Up to three OWNER transactions, each skipped when
 *         already done, in the same order as B's own Step 10:
 *           1. `SSV2.unpause()`;
 *           2. `SSV2.setPauser(Pauser)`;
 *           3. `Pauser.register(SSV2)`                (unpause BEFORE register: the Pauser never holds a paused SSV2).
 *         End state, required: unpaused, `pauser == Pauser`, registered, and every Pauser registrant unpaused with
 *         `pauser == Pauser`. One transient one-tx coverage gap is inherent: between tx2 and tx3 a global pause
 *         succeeds but misses SSV2.
 *
 *         THE HUMAN'S CALL, NEVER CHAINED. No npm key runs this automatically. Unfreezing re-opens the AM source
 *         (`withdraw` + `autoAnnihilate` mint raw AM), which re-opens the M-02 dust-LP spoof against any later resume
 *         of B. So it REFUSES while the seeder named in B's progress file is still an approved Antimatter minter (B
 *         stopped between its grant and its revoke): revoke first (`Antimatter.setApprovedMinter(seeder, false)`),
 *         see the runbook.
 *
 * Preview:   npm run ssv2-unfreeze-after-cutover-abort:preview
 * Broadcast: npm run ssv2-unfreeze-after-cutover-abort:broadcast (Ledger)
 */
contract UnfreezeStableStakerV2AfterCutoverAbort is AntimatterPoolMainnetOps {
    function run() external {
        console.log("=================================================");
        console.log("  UNFREEZE StableStakerV2 after an aborted Antimatter cutover - MAINNET (story 124)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed)" : "Mode: BROADCAST (Ledger)");

        Config memory c = expectedConfig();
        _preflight(c);
        Progress memory p = _readProgress();
        if (p.seeder != address(0) && p.seeder.code.length > 0) {
            require(
                !IAmCutoverAntimatter(c.antimatter).isApprovedMinter(p.seeder),
                "unfreeze: the progress-file AntimatterPoolSeeder is STILL an approved Antimatter minter - revoke it first (Antimatter.setApprovedMinter(seeder, false)); see docs/SyaAntimatterMainnetCutover.md"
            );
        }

        _restoreSsv2(c);
        if (isPreview) _assertGlobalPauseWorks(c, "after-unfreeze");
        console.log("SSV2 restored: unpaused, pauser == Pauser, registered; registrant sweep OK");
        console.log("Transactions this run:", txCount);
    }
}
