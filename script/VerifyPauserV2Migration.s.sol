// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {PauserV2MainnetBase, IPauserV2Pausable} from "./helpers/PauserV2MainnetBase.sol";

/**
 * @title VerifyPauserV2Migration  (story 128, sprint global-pauser-v2) - READ-ONLY POST-BROADCAST VERIFIER
 * @notice No --broadcast, no --sender, no prank / deal / snapshot: it reads LIVE mainnet over RPC and fails with
 *         `verify: ...` on the first violated postcondition. Pattern: the registrant sweep of
 *         `VerifyStableStakerV2Cutover.s.sol` (L477-486).
 *
 *         Checks:
 *           - PauserV2 (env `PAUSER_V2`, else the deploy progress file) has OWNER / EYE / 1000e18;
 *           - the address book `Pauser` key is PauserV2 (run `scripts/patch-mainnet-addresses-pauser-v2.js` first),
 *             and agrees with the progress file;
 *           - the migration postconditions (`_requirePostconditions`): health() notPauser / alreadyPaused /
 *             unreachable empty, V2 set == live set, no RETIRED registrant on V2, and every live registrant's
 *             pauser() is V2. That last check is what DETECTS A LIVE REGISTRANT RE-POINTED AT V1 - e.g. by an old
 *             V1 recovery script such as `UnfreezeStableStakerV2AfterCutoverAbort.s.sol`, which does
 *             `setPauser(Pauser V1)` -> `V1.register`. It reports such a registrant by name before failing.
 *
 *         Re-run it any time after the migration as a health check.
 *
 * Run: npm run pauser-v2-verify
 */
contract VerifyPauserV2Migration is PauserV2MainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY PauserV2 migration - MAINNET (story 128) - READ-ONLY");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "verify: wrong chain ID - expected Mainnet (1)");

        address recorded = _progressPauserV2();
        address v2 = vm.envOr("PAUSER_V2", address(0));
        if (v2 == address(0)) v2 = recorded;
        require(v2 != address(0), "verify: no PauserV2 - set PAUSER_V2 or deploy first (progress.pauser-v2.1.json)");
        require(recorded == address(0) || recorded == v2, "verify: PAUSER_V2 != the deploy progress file's PauserV2");
        console.log("PauserV2:", v2);
        _checkPauserV2(v2);

        address booked = _bookPauser();
        require(
            booked != PAUSER_V1,
            "verify: address book Pauser is still V1 - run node scripts/patch-mainnet-addresses-pauser-v2.js"
        );
        require(booked == v2, "verify: address book Pauser != PauserV2");
        console.log("Address book Pauser == PauserV2");

        // Name every live registrant re-pointed at V1 (or anywhere else) before the generic require fails.
        address[] memory live = liveRegistrants();
        uint256 bad;
        for (uint256 i = 0; i < live.length; i++) {
            address cur = IPauserV2Pausable(live[i]).pauser();
            if (cur == v2) continue;
            bad++;
            if (cur == PAUSER_V1) console.log("  RE-POINTED AT V1 (old recovery script?):", live[i]);
            else console.log("  pauser() is neither PauserV2 nor V1:", live[i], cur);
        }
        require(bad == 0, "verify: live registrant(s) not on PauserV2 - see the log above");

        _requirePostconditions(v2, "verify");

        // Informational: the retired set, which stays on the dead V1 by design.
        address[] memory retired = retiredRegistrants();
        for (uint256 i = 0; i < retired.length; i++) {
            console.log("  retired (left on V1, not on V2):", retired[i], IPauserV2Pausable(retired[i]).pauser());
        }
        console.log("VERIFY OK");
    }
}
