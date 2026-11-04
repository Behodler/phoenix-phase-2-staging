// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {PauserV2MainnetBase, IPauserV1Registry, IPauserV2Pausable} from "./helpers/PauserV2MainnetBase.sol";

/**
 * @title VerifyPauserV2Migration  (story 128, sprint global-pauser-v2) - READ-ONLY POST-BROADCAST VERIFIER
 * @notice No --broadcast, no --sender, no prank / deal / snapshot: it reads LIVE mainnet over RPC and fails with
 *         `verify: ...` on the first violated invariant. Chained after `pauser-v2-migrate:broadcast` and the
 *         address-book patcher (audit 49 L-04); re-run it any time as a health check.
 *
 *         It checks INVARIANTS, not the frozen 18-address snapshot (audit 49 L-07). The live set is
 *           (liveRegistrants() - postMigrationRemovals()) + postMigrationAdditions()   (script/helpers/PauserV2Registry.sol)
 *         so a registry change the runbook prescribes (bonfire, new minter, retirement) stays green once it is
 *         committed to PauserV2Registry, and any uncommitted change fails by name.
 *
 *         Checks:
 *           - PauserV2 (progress file; env `PAUSER_V2` must agree) has OWNER / EYE and the FINAL 1000e18 burn
 *             (the migration's last tx; a 1_000_000e18 burn means the migration did not finish);
 *           - the address book `Pauser` key is PauserV2 and agrees with the progress file;
 *           - V1's registrant list is a subset of the story-128 snapshot: any NEW contract registered with the dead
 *             V1 (which has no working stop) is named and fails;
 *           - every live-set member is on PauserV2 with `pauser() == PauserV2` - names any re-pointed at V1, e.g.
 *             by an old V1 recovery script such as `UnfreezeStableStakerV2AfterCutoverAbort.s.sol`;
 *           - every PauserV2 registrant is in the live set (names any uncommitted addition);
 *           - committed removals and every RETIRED registrant are NOT on PauserV2;
 *           - PauserV2.health(): notPauser / alreadyPaused / unreachable empty.
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
        require(
            PauserV2(v2).eyeBurnAmount() == EYE_BURN_AMOUNT,
            "verify: PauserV2.eyeBurnAmount() != 1000e18 - the migration lowers it last"
        );

        address booked = _bookPauser();
        require(
            booked != PAUSER_V1,
            "verify: address book Pauser is still V1 - run node scripts/patch-mainnet-addresses-pauser-v2.js"
        );
        require(booked == v2, "verify: address book Pauser != PauserV2");
        console.log("Address book Pauser == PauserV2");

        _requireNoNewV1Registrants();
        _requireRegistryInvariant(PauserV2(v2));

        // Informational: the retired set, which stays on the dead V1 by design.
        address[] memory retired = retiredRegistrants();
        for (uint256 i = 0; i < retired.length; i++) {
            console.log("  retired (left on V1, not on V2):", retired[i], IPauserV2Pausable(retired[i]).pauser());
        }
        console.log("VERIFY OK");
    }

    /// @notice V1 is bricked after the migration, so any contract registered with it has no stop. Its list may only
    ///         ever shrink from the story-128 snapshot.
    function _requireNoNewV1Registrants() internal view {
        address[] memory onV1 = IPauserV1Registry(PAUSER_V1).getPausableContracts();
        address[] memory snapshot = expectedV1Registrants();
        uint256 bad;
        for (uint256 i = 0; i < onV1.length; i++) {
            if (_contains(snapshot, onV1[i])) continue;
            bad++;
            console.log("  NEW REGISTRANT ON DEAD V1 (no working stop):", onV1[i]);
        }
        require(bad == 0, "verify: V1 holds a registrant outside the story-128 snapshot - see the log above");
    }

    function _requireRegistryInvariant(PauserV2 p) internal view {
        address v2 = address(p);
        address[] memory live = liveRegistrants();
        address[] memory additions = postMigrationAdditions();
        address[] memory removals = postMigrationRemovals();

        // 1. Every live-set member is on V2. Name each one that is not, before the generic require fails.
        uint256 bad;
        for (uint256 i = 0; i < live.length + additions.length; i++) {
            address c = i < live.length ? live[i] : additions[i - live.length];
            if (_contains(removals, c)) continue;
            address cur = IPauserV2Pausable(c).pauser();
            if (cur == v2 && p.isRegistered(c)) continue;
            bad++;
            if (cur == PAUSER_V1) console.log("  RE-POINTED AT V1 (old recovery script?):", c);
            else if (cur != v2) console.log("  pauser() is neither PauserV2 nor V1:", c, cur);
            else console.log("  pauser() is PauserV2 but not registered there:", c);
        }
        require(bad == 0, "verify: live registrant(s) not on PauserV2 - see the log above");

        // 2. Every V2 registrant is in the live set.
        address[] memory onV2 = p.getPausableContracts();
        for (uint256 i = 0; i < onV2.length; i++) {
            address c = onV2[i];
            bool listed = (_contains(live, c) || _contains(additions, c)) && !_contains(removals, c);
            if (listed) continue;
            bad++;
            console.log("  ON PauserV2 BUT NOT COMMITTED to PauserV2Registry (or listed as removed):", c);
        }
        require(
            bad == 0,
            "verify: PauserV2 holds an address that is neither live nor a committed addition - see the log above"
        );

        // 3. Retired never on V2.
        address[] memory retired = retiredRegistrants();
        for (uint256 i = 0; i < retired.length; i++) {
            require(!p.isRegistered(retired[i]), "verify: a RETIRED registrant is registered with PauserV2");
        }

        // 4. Health.
        (
            address[] memory notPauser,
            address[] memory alreadyPaused,
            address[] memory noGetter,
            address[] memory unreachable
        ) = p.health();
        require(notPauser.length == 0, "verify: PauserV2.health() notPauser is not empty");
        require(alreadyPaused.length == 0, "verify: PauserV2.health() alreadyPaused is not empty");
        require(unreachable.length == 0, "verify: PauserV2.health() unreachable is not empty");
        console.log("verify: registry invariant OK. Registrants on PauserV2:", onV2.length);
        console.log(
            "  health(): notPauser 0, alreadyPaused 0, unreachable 0, noPausedGetter (informational):", noGetter.length
        );
    }

    function _contains(address[] memory set, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == a) return true;
        }
        return false;
    }
}
