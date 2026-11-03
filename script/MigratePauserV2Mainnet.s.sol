// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {PauserV2MainnetBase, IPauserV1Registry, IPauserV2Pausable, IOwnedV2} from "./helpers/PauserV2MainnetBase.sol";

/**
 * @title MigratePauserV2Mainnet  (story 128, sprint global-pauser-v2)
 * @notice Rotates every LIVE V1 Pauser registrant onto PauserV2 and registers it there. Per live registrant, in
 *         value-at-risk order (`liveRegistrants()`), up to two OWNER transactions, each skipped when already done
 *         (pattern `FreezeStableStakerV2ForCutover.s.sol` L12-32):
 *           1. `c.setPauser(V2)`   - skipped if `c.pauser() == V2`;
 *           2. `V2.register(c)`    - skipped if `V2.isRegistered(c)`. Must follow 1: register checks pauser() == V2.
 *         RETIRED registrants (`retiredRegistrants()`) get NO transaction and stay on the dead V1.
 *
 *         THE ROTATION WINDOW. The first `setPauser(V2)` on any registrant bricks the V1 Pauser (trigger 1 of the
 *         design doc: V1's `pause()` loops every registrant with no try/catch, and a registrant whose pauser is no
 *         longer V1 rejects it). From that transaction on, V2 covers every contract already rotated and nothing
 *         else, so contracts not yet rotated have NO working emergency stop until their turn. The owner is an EOA,
 *         so the window cannot be closed by batching; it is bounded by ONE continuous `--slow` run ordered by
 *         value at risk. Do not interrupt it. If it is interrupted, re-run the same key at once: every step is
 *         state-gated, so a re-run resumes where the chain stands and a completed run is a no-op.
 *
 *         PauserV2 address: env `PAUSER_V2`, else `server/deployments/progress.pauser-v2.1.json` (written by
 *         `DeployPauserV2Mainnet`'s broadcast). In PREVIEW only, when neither exists, a PauserV2 is deployed in the
 *         preview fork (OWNER prank) so the whole migration can be rehearsed before the deploy broadcast.
 *
 *         Preflight (refuses before any transaction):
 *           - the live `V1.getPausableContracts()` equals the classified 27-address snapshot (fails loudly if, for
 *             example, phStaging2:119 registered a new minter with V1 first - re-classify, do not migrate stale);
 *           - StableStakerV2 is registered with V1 (re-registered after the story-124 freeze/unfreeze cycle);
 *           - every live registrant has code, `owner() == OWNER`, and `pauser()` is V1 or (on a resume) V2;
 *           - PauserV2 has OWNER as owner, EYE as eyeToken and a 1000e18 burn amount, and every address it already
 *             holds is in the live set.
 *         Postconditions (`_requirePostconditions`): V2.health() notPauser / alreadyPaused / unreachable empty;
 *         V2's registrant set == the live set; no live registrant's pauser() is V1; no retired one on V2.
 *         Preview additionally runs a snapshot-reverted global pause round-trip against V2.
 *
 * Preview:   npm run pauser-v2-migrate:preview    (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed)
 * Broadcast: npm run pauser-v2-migrate:broadcast  (Ledger; the human only; ONE continuous session)
 */
contract MigratePauserV2Mainnet is PauserV2MainnetBase {
    bool public isPreview;
    uint256 public txCount;
    address public pauserV2;
    bool public deployedV2InPreview;

    function run() external {
        console.log("=================================================");
        console.log("  MIGRATE V1 Pauser registrants -> PauserV2 - MAINNET (story 128)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed)" : "Mode: BROADCAST (Ledger)");
        if (!isPreview) require(msg.sender == OWNER, "broadcast sender must be OWNER (--sender + Ledger)");

        pauserV2 = _resolvePauserV2();
        console.log("PauserV2:", pauserV2);
        _checkPauserV2(pauserV2);

        _preflight();
        console.log("Preflight OK: V1 snapshot matches (27), StableStakerV2 on V1, OWNER owns every live registrant.");

        _migrate();

        _requirePostconditions(pauserV2, "migrate");
        if (isPreview) _assertGlobalPauseRoundTrip(pauserV2, "migrate");
        console.log("Transactions this run:", txCount);
        if (txCount == 0) console.log("Nothing to do: every live registrant was already on PauserV2 (no-op).");
    }

    /// @notice env PAUSER_V2 -> progress file -> (preview only) deploy one in the fork.
    function _resolvePauserV2() internal virtual returns (address v2) {
        v2 = vm.envOr("PAUSER_V2", address(0));
        if (v2 != address(0)) {
            console.log("PauserV2 from env PAUSER_V2");
            return v2;
        }
        v2 = _progressPauserV2();
        if (v2 != address(0)) {
            console.log("PauserV2 from", _progressFile());
            return v2;
        }
        require(
            isPreview,
            "No PauserV2: set PAUSER_V2 or run npm run pauser-v2-deploy:broadcast first (it writes server/deployments/progress.pauser-v2.1.json)"
        );
        vm.prank(OWNER);
        v2 = address(new PauserV2(EYE));
        deployedV2InPreview = true;
        console.log("PREVIEW: no PauserV2 deployed yet - deployed a fork-local one (OWNER prank) to rehearse against");
    }

    function _preflight() internal view {
        _requireV1Snapshot();
        require(
            IPauserV1Registry(PAUSER_V1).isRegistered(STABLE_STAKER_V2),
            "StableStakerV2 is not registered with V1 - expected after the story-124 unfreeze; investigate before migrating"
        );

        address[] memory live = liveRegistrants();
        for (uint256 i = 0; i < live.length; i++) {
            address c = live[i];
            require(c.code.length > 0, "a live registrant has no code");
            require(IOwnedV2(c).owner() == OWNER, "a live registrant's owner() != OWNER");
            address cur = IPauserV2Pausable(c).pauser();
            require(
                cur == PAUSER_V1 || cur == pauserV2,
                "a live registrant's pauser() is neither V1 nor PauserV2 - someone re-pointed it; resolve by hand first"
            );
        }

        address[] memory onV2 = PauserV2(pauserV2).getPausableContracts();
        for (uint256 i = 0; i < onV2.length; i++) {
            require(_isLive(onV2[i]), "PauserV2 already holds an address outside the live set");
        }
    }

    function _migrate() internal {
        PauserV2 p = PauserV2(pauserV2);
        address[] memory live = liveRegistrants();
        for (uint256 i = 0; i < live.length; i++) {
            address c = live[i];
            if (IPauserV2Pausable(c).pauser() != pauserV2) {
                _begin();
                IPauserV2Pausable(c).setPauser(pauserV2);
                _end();
                txCount++;
                require(IPauserV2Pausable(c).pauser() == pauserV2, "setPauser(PauserV2) did not take");
                console.log("  setPauser(PauserV2):", c);
            }
            if (!p.isRegistered(c)) {
                _begin();
                p.register(c);
                _end();
                txCount++;
                console.log("  PauserV2.register:  ", c);
            }
        }
    }

    function _isLive(address a) internal pure returns (bool) {
        address[] memory live = liveRegistrants();
        for (uint256 i = 0; i < live.length; i++) {
            if (live[i] == a) return true;
        }
        return false;
    }

    function _begin() internal {
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
    }

    function _end() internal {
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
