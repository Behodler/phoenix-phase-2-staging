// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/**
 * @title PhusdMinterDeltaGuardsTest
 * @notice Story 076 guard proof for the RESTATED phUSD mint-authority claim in
 *         `script/VerifyPromotionReady.s.sol`.
 *
 *         WHY THIS TEST EXISTS. Story 075 asserted INVARIANCE over a fixed candidate set:
 *         the live minter-set mask had to be byte-identical to the Phase 0 baseline, because
 *         story 072's cutover made zero `phUSD.setMinter` calls. Story 076's Phase 4e makes
 *         two — `setMinter(phlimboV3, true)` and `setMinter(PHLIMBO_V2, false)` — so the old
 *         claim is not merely weakened, it is WRONG: it would fail on a correct cutover.
 *
 *         Replacing a failing assertion is exactly the moment a control quietly dies. The
 *         obvious "fixes" are both silent downgrades:
 *
 *           * relax to `liveMask != 0`, or drop the mask check entirely; or
 *           * assert only "the PhlimboV2 bit was cleared" (one-sided), which passes happily
 *             while some OTHER address in the set gains or loses mint authority.
 *
 *         The shipped form is a TWO-SIDED DELTA — `liveMask == baseline & ~v2Bit` — and the
 *         tests below prove it rejects both of those, in both directions.
 *
 *         METHOD. Follows the house pattern set by `VerifyPromotionReadyGuards.t.sol`:
 *         RE-MODEL the assertion in a self-contained local model rather than instantiating
 *         the script, which would need live mainnet at every constant it inherits and turn a
 *         guard test into a fork test. Source-level assertions pin the properties the model
 *         cannot reach.
 *
 *         No mainnet RPC required — runs under plain `forge test`.
 */
contract PhusdMinterDeltaGuardsTest is Test {
    string constant VERIFIER_SRC = "script/VerifyPromotionReady.s.sol";
    string constant DEPLOY_SRC = "script/DeployMainnetPromotionReady.s.sol";

    /// @dev Mirrors `_phusdMinterCandidates()`'s index for `PHLIMBO_V2` (appended at 19 by
    ///      story 076). Kept in sync by `test_deployScriptDeclaresTheV2Bit` below.
    uint256 constant V2_BIT_INDEX = 19;

    // -----------------------------------------------------------------
    //  Local model of the shipped assertion.
    // -----------------------------------------------------------------

    /// @dev Mirrors the mask half of `VerifyPromotionReady._verifyMintAuthorityInvariance()`.
    function _assertExpectedDelta(uint256 baselineMask, uint256 liveMask) internal pure {
        uint256 v2Bit = 1 << V2_BIT_INDEX;
        require(liveMask == (baselineMask & ~v2Bit), "phUSD minter-set membership does not match the EXPECTED delta");
    }

    function assertDeltaExternal(uint256 baselineMask, uint256 liveMask) external pure {
        _assertExpectedDelta(baselineMask, liveMask);
    }

    // -----------------------------------------------------------------
    //  The happy path: exactly the PhlimboV2 bit cleared.
    // -----------------------------------------------------------------

    function test_revokingOnlyPhlimboV2_passes() public pure {
        uint256 baseline = (1 << V2_BIT_INDEX) | (1 << 0) | (1 << 3) | (1 << 18);
        uint256 live = baseline & ~(uint256(1) << V2_BIT_INDEX);
        _assertExpectedDelta(baseline, live);
    }

    /// @dev A baseline in which PhlimboV2 was never a minter is legitimate — the revoke is
    ///      then a no-op — and must still pass. The verifier logs a NOTE in this case rather
    ///      than implying it verified a revoke that never happened.
    function test_v2NotAMinterAtBaseline_stillPasses() public pure {
        uint256 baseline = (1 << 0) | (1 << 7);
        _assertExpectedDelta(baseline, baseline);
    }

    // -----------------------------------------------------------------
    //  THE HEADLINE CASES. Both silent-downgrade shapes must FAIL.
    // -----------------------------------------------------------------

    /// @dev An unexplained GRANT elsewhere in the set. A one-sided "V2 was revoked" check
    ///      would pass this; the two-sided delta must not.
    function test_unexpectedGrantElsewhere_fails() public {
        uint256 baseline = (1 << V2_BIT_INDEX) | (1 << 2);
        uint256 live = (baseline & ~(uint256(1) << V2_BIT_INDEX)) | (1 << 11); // someone gained
        vm.expectRevert("phUSD minter-set membership does not match the EXPECTED delta");
        this.assertDeltaExternal(baseline, live);
    }

    /// @dev An unexplained SECOND REVOKE. This is the direction the story calls out
    ///      explicitly: asserting only "gained V3" would not notice it.
    function test_unexpectedRevokeElsewhere_fails() public {
        uint256 baseline = (1 << V2_BIT_INDEX) | (1 << 2) | (1 << 5);
        uint256 live = baseline & ~((uint256(1) << V2_BIT_INDEX) | (1 << 5)); // 5 also lost
        vm.expectRevert("phUSD minter-set membership does not match the EXPECTED delta");
        this.assertDeltaExternal(baseline, live);
    }

    /// @dev The revoke simply not landing must fail too — otherwise PhlimboV2 keeps mint
    ///      authority it is no longer supposed to hold and nothing says so.
    function test_v2RevokeDidNotLand_fails() public {
        uint256 baseline = (1 << V2_BIT_INDEX) | (1 << 2);
        vm.expectRevert("phUSD minter-set membership does not match the EXPECTED delta");
        this.assertDeltaExternal(baseline, baseline); // V2 bit still set
    }

    /// @dev Shows the downgrade explicitly: the naive one-sided check passes every case above
    ///      that the shipped two-sided check rejects. This is the difference story 076 exists
    ///      to create, stated as a test rather than as a comment.
    function test_oneSidedCheckWouldBeVacuous_twoSidedIsNot() public {
        uint256 baseline = (1 << V2_BIT_INDEX) | (1 << 2);
        uint256 liveWithStrayGrant = (baseline & ~(uint256(1) << V2_BIT_INDEX)) | (1 << 11);

        // The naive check: "the PhlimboV2 bit is clear". Passes — this is the bug.
        assertEq(liveWithStrayGrant & (1 << V2_BIT_INDEX), 0, "one-sided check passes the stray grant");

        // The shipped check rejects it.
        vm.expectRevert("phUSD minter-set membership does not match the EXPECTED delta");
        this.assertDeltaExternal(baseline, liveWithStrayGrant);
    }

    // -----------------------------------------------------------------
    //  Source-level guards on the real files.
    // -----------------------------------------------------------------

    /// @dev The candidate set's encoding is positional — index i is bit i — so an entry may
    ///      only ever be APPENDED. A removal or reorder silently repoints every persisted
    ///      mask, including ones already written to a live progress file.
    function test_deployScriptDeclaresTheV2Bit() public view {
        string memory src = vm.readFile(DEPLOY_SRC);
        assertTrue(
            _contains(src, "uint256 public constant PHUSD_MINTER_BIT_PHLIMBO_V2 = 19"),
            "the PhlimboV2 candidate-set bit index must stay 19 (append-only encoding)"
        );
        assertTrue(
            _contains(src, "require(i == 20,"), "candidate set must hold 20 entries after story 076 appended PHLIMBO_V2"
        );
    }

    /// @dev PhlimboV3's grant CANNOT be expressed as a mask bit (it is a runtime CREATE, and
    ///      the candidate set is `pure` over compile-time constants), so the positive
    ///      assertion is the only thing standing between a forgotten grant and a silent
    ///      failure: `PhlimboV3._claimRewards` banks a failed mint instead of reverting.
    function test_verifierAssertsPhlimboV3PositivelyHoldsMintAuthority() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        assertTrue(_contains(src, "PhlimboV3 does NOT hold phUSD mint authority"), "missing the positive V3 assertion");
        // And it must NOT have been swept in with the negatives, which would contradict it.
        assertFalse(
            _contains(src, '_requireNotPhusdMinter(newPhlimboV3'),
            "PhlimboV3 must be EXCLUDED from the not-a-minter sweep, not included in it"
        );
        // Every other new contract stays in the sweep. MigratorV2V3 is the one story 076 added.
        assertTrue(
            _contains(src, '_requireNotPhusdMinter(migratorV2V3'),
            "MigratorV2V3 must stay in the not-a-minter sweep - it needs no mint role"
        );
    }

    /// @dev The blanket relaxation this story must never become: dropping the mask assertion
    ///      altogether, or the global `mintVersion` check that makes an inert grant readable
    ///      as inert.
    function test_verifierStillAssertsMintVersionAndTheMask() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        assertTrue(_contains(src, "phusdMintVersionAtPhase0"), "mintVersion invariance must survive the restatement");
        assertTrue(_contains(src, "PHUSD_MINTER_BIT_PHLIMBO_V2"), "the mask delta must be expressed via the named bit");
        assertTrue(_contains(src, "phusdMinterMaskAtPhase0 & ~v2Bit"), "the mask check must be the two-sided delta");
    }

    // -----------------------------------------------------------------

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
