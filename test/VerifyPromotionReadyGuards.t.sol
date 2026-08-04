// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/**
 * @title VerifyPromotionReadyGuardsTest
 * @notice Story 075 (script-audit run-22, M-01) guard proof for `script/VerifyPromotionReady.s.sol`.
 *
 *         SCOPE — CONSUMPTION ONLY. This pins how the verifier CONSUMES story 074's persisted
 *         BPT cutover baseline. The write-once rule, the monotonic adoption and the `baselines`
 *         JSON round-trip belong to story 074 and are already pinned by
 *         `test/BptBaselinePersistence.t.sol`; they are deliberately NOT duplicated here.
 *
 *         METHOD — follows the house pattern established by `YsSwapMigrationHardening.t.sol`:
 *         RE-MODEL the guards in a self-contained local model, do NOT instantiate the script.
 *         Instantiating `VerifyPromotionReady` would require live mainnet at every constant it
 *         inherits, which turns a guard test into a fork test and couples it to chain state.
 *
 *         WHY THIS TEST EXISTS AT ALL. The audit's conditional-Medium trigger is precisely that
 *         a standalone post-broadcast verifier which re-derives the BPT baseline from a LIVE
 *         read of the old pooler is vacuous: post-broadcast that balance is ALWAYS 0, so
 *         `balanceOf(newPooler) >= 0` passes no matter where the 16,338 BPT actually went. A
 *         green verifier run therefore proves nothing unless the no-fallback property is itself
 *         pinned. That is what the source-level assertions below do.
 *
 *         No mainnet RPC required — runs under plain `forge test`.
 */
contract VerifyPromotionReadyGuardsTest is Test {
    string constant VERIFIER_SRC = "script/VerifyPromotionReady.s.sol";
    /// @dev Story 078. The verifier inherits its progress-file parser from the cutover script,
    ///      so the two files must be read together to prove the parse/consume halves agree.
    string constant DEPLOY_SRC = "script/DeployMainnetPromotionReady.s.sol";

    // -----------------------------------------------------------------
    //  Local model of the verifier's baseline-consumption guard.
    // -----------------------------------------------------------------

    /// @dev Mirrors `VerifyPromotionReady._adoptPersistedBptBaseline()`. The ONLY input is the
    ///      persisted baseline and whether it was present; there is deliberately no parameter
    ///      carrying a live `balanceOf(OLD_POOLER)` reading, because the real function has no
    ///      access path to one either.
    function _adoptBaseline(uint256 persisted, bool present) internal pure returns (uint256) {
        require(present, "ABORT: progress file carries no baselines.bptAtCutover");
        require(persisted > 0, "ABORT: persisted baselines.bptAtCutover is 0");
        return persisted;
    }

    /// @dev Mirrors the Phase 7 BPT conservation assertion the verifier re-runs.
    function _assertConservation(uint256 newPoolerBpt, uint256 baseline) internal pure {
        require(newPoolerBpt >= baseline, "new pooler BPT below the cutover baseline");
    }

    // -----------------------------------------------------------------
    //  Absent baseline => loud failure, never a skip and never a fallback.
    // -----------------------------------------------------------------

    function test_absentBaseline_failsLoudly() public {
        vm.expectRevert("ABORT: progress file carries no baselines.bptAtCutover");
        this.adoptExternal(0, false);
    }

    /// @dev The specific regression: a baseline that is present but zero is indistinguishable
    ///      from a live read of an already-emptied old pooler, and must be rejected for the
    ///      same reason.
    function test_zeroBaseline_failsLoudly() public {
        vm.expectRevert("ABORT: persisted baselines.bptAtCutover is 0");
        this.adoptExternal(0, true);
    }

    function adoptExternal(uint256 persisted, bool present) external pure returns (uint256) {
        return _adoptBaseline(persisted, present);
    }

    // -----------------------------------------------------------------
    //  Wrong baseline => the conservation assertion must FAIL.
    //  This is the "not vacuous on the FRESH path" proof.
    // -----------------------------------------------------------------

    function test_correctBaseline_passes() public pure {
        uint256 baseline = 16_338_819_000_000_000_000_000;
        uint256 adopted = _adoptBaseline(baseline, true);
        _assertConservation(baseline, adopted); // new pooler holds exactly the moved position
    }

    function test_baselineTooHigh_failsConservation() public {
        uint256 adopted = _adoptBaseline(16_338_819_000_000_000_000_000, true);
        vm.expectRevert("new pooler BPT below the cutover baseline");
        this.assertConservationExternal(16_338_818_999_999_999_999_999, adopted);
    }

    /// @dev THE HEADLINE CASE. With the vacuous (live-read) baseline of 0, a new pooler holding
    ///      NOTHING still passes conservation — the whole 16,338 BPT could be on a third address
    ///      and the assertion would be green. With the persisted baseline it fails. This is the
    ///      difference story 074 + 075 exist to create.
    function test_zeroBaselineWouldBeVacuous_persistedBaselineIsNot() public {
        uint256 vacuous = 0;
        _assertConservation(0, vacuous); // passes — this is the bug, shown explicitly

        uint256 real = _adoptBaseline(16_338_819_000_000_000_000_000, true);
        vm.expectRevert("new pooler BPT below the cutover baseline");
        this.assertConservationExternal(0, real);
    }

    function assertConservationExternal(uint256 newPoolerBpt, uint256 baseline) external pure {
        _assertConservation(newPoolerBpt, baseline);
    }

    // -----------------------------------------------------------------
    //  Source-level guards. These pin properties of the real file that a
    //  behavioural model cannot reach.
    // -----------------------------------------------------------------

    /// @dev NO LIVE-READ FALLBACK. If anyone ever "helpfully" adds a
    ///      `balanceOf(OLD_POOLER)` fallback to the verifier, the baseline becomes 0
    ///      post-broadcast and every BPT assertion silently goes vacuous again.
    function test_verifierHasNoOldPoolerLiveRead() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        // The exact call that would reintroduce the vacuity. Note the verifier's own prose
        // deliberately never spells this literal out, so a hit here means real code.
        assertFalse(_contains(src, "balanceOf(OLD_POOLER)"), "verifier must never live-read the old pooler's BPT");
        assertFalse(_contains(src, "OLD_POOLER"), "verifier must not reference the old pooler at all");
    }

    /// @dev READ-ONLY. The verifier runs against live mainnet over RPC, not a fork, so any
    ///      state-mutating cheatcode is both meaningless and dangerous. `Test.sol` is banned
    ///      outright because it drags in `deal`/`prank` and made the sibling
    ///      `VerifyBalancerECLPPool.s.sol` fork-only.
    function test_verifierIsReadOnly() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        assertFalse(_contains(src, "startBroadcast"), "verifier must not broadcast");
        assertFalse(_contains(src, "startPrank"), "verifier must not prank");
        assertFalse(_contains(src, "vm.deal"), "verifier must not deal");
        assertFalse(_contains(src, "vm.warp"), "verifier must not warp");
        assertFalse(_contains(src, "forge-std/Test.sol"), "verifier must not import Test.sol");
    }

    /// @dev The absent-baseline abort must exist in the real file, not just in the model above.
    function test_verifierAbortsOnAbsentBaseline() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        assertTrue(_contains(src, "bptBaselineFromProgressFile"), "verifier must gate on baseline presence");
        assertTrue(
            _contains(src, "phusdMinterBaselineFromProgressFile"), "verifier must gate on the mint-authority baseline"
        );
    }

    // -----------------------------------------------------------------
    //  Story 078 regression. EVERY address the verifier demands from the
    //  progress file must actually be HYDRATED from it.
    // -----------------------------------------------------------------

    /// @dev THE BUG THIS PINS. Story 078 added `_requireResolved(newDepositPageViewV3, …)` to
    ///      the verifier but no matching `newDepositPageViewV3 = deployments["DepositPageViewV3"].addr;`
    ///      to `_parseProgressJson()`. The member is otherwise assigned only inside
    ///      `_phase4f_depositViewCutover()`, which the read-only verifier never runs — so the
    ///      verifier resolved `address(0)` and aborted on EVERY post-broadcast run, taking the
    ///      trailing verify leg of `promotion-ready:broadcast` with it. Nothing caught it: the
    ///      dry run writes no progress file and never invokes the verifier, and `forge build`
    ///      is perfectly happy with an unassigned member.
    ///
    ///      This is a CLASS of bug, not a one-off — the two halves live ~1500 lines apart in
    ///      two different files — so the check is derived from the source rather than from a
    ///      hardcoded list: it re-reads every `_requireResolved` call site and demands the
    ///      corresponding assignment, scoped to `_parseProgressJson`'s own body. Scoping is
    ///      load-bearing: the phase bodies assign these same members from the same map, and an
    ///      unscoped search would have passed on the broken code.
    function test_everyRequiredAddressIsHydratedFromProgressFile() public view {
        string memory verifier = vm.readFile(VERIFIER_SRC);
        string memory parseBody = _parseProgressJsonBody(vm.readFile(DEPLOY_SRC));

        uint256 checked;
        uint256 cursor;
        while (true) {
            (bool found, uint256 at) = _find(verifier, "_requireResolved(", cursor);
            if (!found) break;
            uint256 open = at + bytes("_requireResolved(").length;
            (bool closed, uint256 close) = _find(verifier, ")", open);
            require(closed, "unterminated _requireResolved call");
            cursor = close;

            string memory args = _slice(verifier, open, close);
            (bool split, uint256 comma) = _find(args, ",", 0);
            if (!split) continue;
            string memory member = _trim(_slice(args, 0, comma));
            string memory name = _unquote(_trim(_slice(args, comma + 1, bytes(args).length)));

            // Skip the declaration itself (`function _requireResolved(address a, string memory name)`).
            if (_contains(member, " ")) continue;

            assertTrue(
                _contains(parseBody, string.concat(member, ' = deployments["', name, '"].addr;')),
                string.concat(
                    "VerifyPromotionReady requires '",
                    name,
                    "' but _parseProgressJson never hydrates '",
                    member,
                    "' - the verifier will abort on address(0)"
                )
            );
            checked++;
        }
        assertEq(checked, 17, "expected 17 resolved runtime addresses; update this test if the lineup changed");
    }

    /// @dev Isolates `_parseProgressJson`'s body, terminated by the first function-level
    ///      closing brace (four-space indent). Keeps the assertion above from being satisfied
    ///      by an assignment that lives in a deployment phase the verifier never executes.
    function _parseProgressJsonBody(string memory src) internal pure returns (string memory) {
        (bool found, uint256 at) = _find(src, "function _parseProgressJson(", 0);
        require(found, "_parseProgressJson not found - was it renamed?");
        (bool ended, uint256 end) = _find(src, "\n    }", at);
        require(ended, "could not locate the end of _parseProgressJson");
        return _slice(src, at, end);
    }

    // -----------------------------------------------------------------

    function _find(string memory haystack, string memory needle, uint256 from)
        internal
        pure
        returns (bool, uint256)
    {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return (false, 0);
        for (uint256 i = from; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return (true, i);
        }
        return (false, 0);
    }

    function _slice(string memory s, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (end > b.length) end = b.length;
        if (start >= end) return "";
        bytes memory out = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 lo;
        uint256 hi = b.length;
        while (lo < hi && (b[lo] == 0x20 || b[lo] == 0x0a || b[lo] == 0x0d || b[lo] == 0x09)) {
            lo++;
        }
        while (hi > lo && (b[hi - 1] == 0x20 || b[hi - 1] == 0x0a || b[hi - 1] == 0x0d || b[hi - 1] == 0x09)) {
            hi--;
        }
        return _slice(s, lo, hi);
    }

    function _unquote(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= 2 && b[0] == 0x22 && b[b.length - 1] == 0x22) return _slice(s, 1, b.length - 1);
        return s;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
