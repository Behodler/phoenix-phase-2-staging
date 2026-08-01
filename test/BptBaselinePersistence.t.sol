// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "@vault/mocks/MockERC20.sol";

/**
 * @title BptBaselinePersistenceTest
 * @notice Story 074 (script-audit run-22, finding L-02) hardening proof. Follows the
 *         `test/YsSwapMigrationHardening.t.sol` convention: build a SELF-CONTAINED model of the
 *         guards `script/DeployMainnetPromotionReady.s.sol` now relies on and exercise them
 *         directly. The script itself is NEVER instantiated — it is a mainnet one-shot whose
 *         Phase 0 reads seventeen live owners, so re-modelling is the only honest way to pin
 *         behaviour, and it lets the whole suite run under plain `forge test` with no RPC.
 *
 *         The defect being closed: Phase 0 used to re-derive the BPT baseline live on EVERY leg.
 *         On a resume where `_moveBPT()` had already landed, the old pooler is empty, the
 *         baseline reads 0, and Phase 7's conservation assertion degenerates to
 *         `balanceOf(newPooler) >= 0` — unconditionally true, even if the position had been
 *         moved to a third address entirely.
 *
 *         What is pinned here:
 *           (a) WRITE-ONCE / monotonic adoption — a later leg reading an emptied old pooler
 *               RETAINS the original baseline and never downgrades it.
 *           (b) NON-VACUITY — with the baseline in place, a shortfall on the new pooler makes
 *               the Phase 7 assertion FAIL. A green run proves nothing here, so the failure is
 *               demonstrated explicitly.
 *           (c) The `baselines` JSON round-trip, including the decimal-string encoding of the
 *               real 23-digit cutover value.
 *           (d) The LOUD-FAILURE path — `pooler_bpt` configured with no persisted baseline must
 *               revert, never fall back to a live read of zero.
 *           (e) The stopgap floor — once the move is recorded, the new pooler must hold
 *               something, so that branch is never fully vacuous.
 */

/// @dev Mirror of the script's baseline logic. Every `require` string and every arithmetic
///      decision below is a transcription of `_phase0_preconditions()` / `_parseBaselines()` /
///      `_phase7_wiringAssertions()`; if the script changes, this must be updated in lockstep.
contract BptBaselineModel {
    MockERC20 public immutable bpt;
    address public immutable oldPooler;
    address public newPooler;

    // Mirrors the script's state.
    uint256 public bptAtPhase0;
    uint256 public bptAtCutoverPersisted;
    bool public bptBaselineFromProgressFile;
    mapping(string => bool) internal configured;

    constructor(MockERC20 bpt_, address oldPooler_, address newPooler_) {
        bpt = bpt_;
        oldPooler = oldPooler_;
        newPooler = newPooler_;
    }

    function setConfigured(string memory key, bool value) external {
        configured[key] = value;
    }

    function _isConfigured(string memory key) internal view returns (bool) {
        return configured[key];
    }

    /// @dev Mirror of `_parseBaselines()`: the progress file carried a baseline.
    function loadPersistedBaseline(uint256 value) external {
        bptAtCutoverPersisted = value;
        bptBaselineFromProgressFile = true;
    }

    /// @dev Mirror of the BPT half of `_phase0_preconditions()`.
    function phase0() external {
        uint256 liveBpt = bpt.balanceOf(oldPooler);
        bptAtPhase0 = bptAtCutoverPersisted > liveBpt ? bptAtCutoverPersisted : liveBpt;

        require(
            !_isConfigured("pooler_bpt") || bptBaselineFromProgressFile,
            "RESUME ABORT: pooler_bpt is already configured but the progress file carries no baselines.bptAtCutover"
        );
        require(bptAtPhase0 > 0, "BPT baseline is 0");
    }

    /// @dev Mirror of the BPT half of `_phase7_wiringAssertions()`.
    function phase7() external view {
        require(bpt.balanceOf(oldPooler) == 0, "old pooler still holds BPT");
        require(bpt.balanceOf(newPooler) >= bptAtPhase0, "new pooler BPT below the cutover baseline");
        require(
            !_isConfigured("pooler_bpt") || bpt.balanceOf(newPooler) > 0,
            "pooler_bpt recorded as moved but the new pooler holds 0 BPT"
        );
    }
}

contract BptBaselinePersistenceTest is Test {
    // The live planning read: 16,338.8190 BPT — 23 digits in wei, which is exactly why the
    // encoding must be a decimal string and not a JSON number.
    uint256 constant CUTOVER_BPT = 16338819000000000000000;

    MockERC20 bpt;
    address constant OLD_POOLER = address(0x0001);
    address constant NEW_POOLER = address(0x0002);
    address constant THIRD_PARTY = address(0xdead);

    BptBaselineModel model;

    function setUp() public {
        bpt = new MockERC20("Balancer Pool Token", "BPT", 18);
        model = new BptBaselineModel(bpt, OLD_POOLER, NEW_POOLER);
    }

    function _fundOldPooler() internal {
        bpt.mint(OLD_POOLER, CUTOVER_BPT);
    }

    function _moveBptToNewPooler() internal {
        vm.prank(OLD_POOLER);
        bpt.transfer(NEW_POOLER, CUTOVER_BPT);
    }

    // ---------------------------------------------------------------------
    //  (a) Write-once / monotonic adoption
    // ---------------------------------------------------------------------

    /// A first leg with no progress file records the live reading.
    function testFreshLegRecordsLiveReading() public {
        _fundOldPooler();
        model.phase0();
        assertEq(model.bptAtPhase0(), CUTOVER_BPT, "fresh leg must record the live reading");
    }

    /// THE CORE REGRESSION. Second leg, `_moveBPT` already landed, old pooler empty: the
    /// baseline must be RETAINED, not re-derived as zero.
    function testResumeLegRetainsBaselineAfterOldPoolerEmptied() public {
        _fundOldPooler();
        model.phase0();
        uint256 recorded = model.bptAtPhase0();

        _moveBptToNewPooler();
        assertEq(bpt.balanceOf(OLD_POOLER), 0, "precondition: old pooler emptied");

        BptBaselineModel leg2 = new BptBaselineModel(bpt, OLD_POOLER, NEW_POOLER);
        leg2.loadPersistedBaseline(recorded);
        leg2.setConfigured("pooler_bpt", true);
        leg2.phase0();

        assertEq(leg2.bptAtPhase0(), CUTOVER_BPT, "resume leg must retain the persisted baseline");
    }

    /// A smaller live reading must never downgrade a non-zero persisted baseline.
    function testPersistedBaselineIsNeverDowngraded() public {
        bpt.mint(OLD_POOLER, 1 ether);
        model.loadPersistedBaseline(CUTOVER_BPT);
        model.phase0();
        assertEq(model.bptAtPhase0(), CUTOVER_BPT, "smaller live reading must not win");
    }

    /// If the old pooler somehow holds MORE than the record, the larger figure wins — the rule
    /// is monotonic, not merely "prefer the file".
    function testLargerLiveReadingRaisesTheBaseline() public {
        bpt.mint(OLD_POOLER, CUTOVER_BPT + 1 ether);
        model.loadPersistedBaseline(CUTOVER_BPT);
        model.phase0();
        assertEq(model.bptAtPhase0(), CUTOVER_BPT + 1 ether, "baseline must ratchet up, never down");
    }

    // ---------------------------------------------------------------------
    //  (b) Non-vacuity
    // ---------------------------------------------------------------------

    /// The honest happy path: full position on the new pooler, assertion passes.
    function testPhase7PassesWhenFullPositionLanded() public {
        _fundOldPooler();
        model.phase0();
        _moveBptToNewPooler();
        model.setConfigured("pooler_bpt", true);
        model.phase7();
    }

    /// DEMONSTRATED FAILURE, not an implied one: a shortfall on the new pooler must revert.
    function testPhase7FailsOnShortfallAgainstBaseline() public {
        _fundOldPooler();
        model.phase0();

        // The pathology the old code could not see: most of the position lands somewhere else.
        vm.startPrank(OLD_POOLER);
        bpt.transfer(NEW_POOLER, 1 ether);
        bpt.transfer(THIRD_PARTY, CUTOVER_BPT - 1 ether);
        vm.stopPrank();

        model.setConfigured("pooler_bpt", true);
        vm.expectRevert(bytes("new pooler BPT below the cutover baseline"));
        model.phase7();
    }

    /// Proof that the ZERO baseline is what made the old code vacuous: with the baseline left
    /// at 0 the very same misrouted state sails through the `>=` check, and only the stopgap
    /// floor catches it.
    function testZeroBaselineWouldHaveBeenVacuous() public {
        _fundOldPooler();
        vm.startPrank(OLD_POOLER);
        bpt.transfer(THIRD_PARTY, CUTOVER_BPT);
        vm.stopPrank();

        // Never called phase0(), so bptAtPhase0 == 0 — the pre-fix resume situation.
        assertEq(model.bptAtPhase0(), 0, "modelling the pre-fix zero baseline");
        assertTrue(bpt.balanceOf(NEW_POOLER) >= model.bptAtPhase0(), "the vacuous comparison holds");

        // The stopgap floor is the only thing standing between this state and a green Phase 7.
        model.setConfigured("pooler_bpt", true);
        vm.expectRevert(bytes("pooler_bpt recorded as moved but the new pooler holds 0 BPT"));
        model.phase7();
    }

    // ---------------------------------------------------------------------
    //  (c) JSON round-trip
    // ---------------------------------------------------------------------

    /// Mirrors `_writeProgressFileWithStatus()`'s emission and `_parseBaselines()`'s recovery,
    /// including the decimal-string encoding of the 23-digit value.
    function testBaselinesJsonRoundTrip() public view {
        string memory json = string.concat(
            "{",
            '"chainId": 1,',
            '"networkName": "mainnet",',
            '"deploymentStatus": "in_progress",',
            '"baselines": {"bptAtCutover": "',
            vm.toString(CUTOVER_BPT),
            '"},',
            '"contracts": {"BalancerPooler": {"address": "0x0000000000000000000000000000000000000002",',
            '"deployed": true,"configured": true,"deployGas": 0,"configGas": 0}}}'
        );

        assertTrue(vm.keyExistsJson(json, ".baselines.bptAtCutover"), "baselines key must exist");

        // Recovered as a STRING then parsed — proving the value is quoted, not a JSON number.
        string memory raw = vm.parseJsonString(json, ".baselines.bptAtCutover");
        assertEq(raw, "16338819000000000000000", "must serialise as a 23-digit decimal string");
        assertEq(vm.parseUint(raw), CUTOVER_BPT, "must round-trip losslessly");

        // The sibling placement must leave the patcher's `.contracts.<Name>` traversal intact.
        assertTrue(vm.keyExistsJson(json, ".contracts.BalancerPooler.address"), "contracts traversal unaffected");
    }

    /// An absent `baselines` block must parse (older binary / trimmed file), not brick the leg.
    /// It is Phase 0, not the parser, that turns the absence into a loud failure.
    function testMissingBaselinesBlockParsesWithoutReverting() public view {
        string memory json = '{"chainId": 1,"networkName": "mainnet","deploymentStatus": "in_progress","contracts": {}}';
        assertFalse(vm.keyExistsJson(json, ".baselines.bptAtCutover"), "absent key must simply read as absent");
    }

    // ---------------------------------------------------------------------
    //  (d) Loud failure
    // ---------------------------------------------------------------------

    /// `pooler_bpt` configured, old pooler emptied, no persisted baseline: ABORT. This is the
    /// hand-trimming hazard the `//promotion-ready:resume` doc key now carves out.
    function testConfiguredWithoutPersistedBaselineReverts() public {
        // Old pooler already empty — nothing minted.
        model.setConfigured("pooler_bpt", true);
        vm.expectRevert(
            bytes(
                "RESUME ABORT: pooler_bpt is already configured but the progress file carries no baselines.bptAtCutover"
            )
        );
        model.phase0();
    }

    /// A fresh run against a genuinely empty old pooler still fails — the tightened escape
    /// hatch no longer lets a non-zero `newPooler` wave a zero baseline through.
    function testFreshRunWithEmptyOldPoolerReverts() public {
        vm.expectRevert(bytes("BPT baseline is 0"));
        model.phase0();
    }
}
