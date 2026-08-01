// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {DeployMainnetPromotionReady} from "./DeployMainnetPromotionReady.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  VerifyPromotionReady
 * @notice Story 075. Read-only post-broadcast verification entry point for the
 *         promotion-ready cutover — the PRIMARY mitigation for script-audit run-22 finding
 *         M-01 (`pps22m1`, Medium).
 *
 *         THE DEFECT IT CLOSES. `forge script` executes the entire Solidity body ONCE,
 *         LOCALLY, collecting calldata; the ~60 transactions are signed and dispatched
 *         AFTERWARDS. `--skip-simulation` removes the pre-send sanity check, not the local
 *         pass. So every assertion in `DeployMainnetPromotionReady` — Phase 0's ownership
 *         gate, every in-phase post-condition, and the whole of `_phase7_wiringAssertions()`
 *         — has already evaluated against local PRE-broadcast state before transaction #1
 *         leaves the machine. They assert the PLAN is internally consistent; they never
 *         assert the CHAIN matches it. Phase 8, which holds the BLOCKING probes, is gated off
 *         entirely under broadcast. Net: on the broadcast path there was no outcome
 *         verification of any kind.
 *
 *         This script is a separate `forge script` invocation with NO `--broadcast`. It runs
 *         after the dispatch has settled, so every read it performs is a read of real,
 *         post-broadcast mainnet state.
 *
 *         INHERITANCE, NOT DUPLICATION. Deriving from the deploy script gives this file all
 *         ~200 address constants, the 14 runtime address members, `_loadProgressFile()`,
 *         `_phase7_wiringAssertions()` and its `_assertSlot`/`_assertHookPair`/`_assertStream`
 *         helpers for free. Copying them into a second file would guarantee eventual drift,
 *         and drift in exactly this file is what audit run-22 was cleaning up.
 *
 *         READ-ONLY CONTRACT. No broadcast cheatcode, no prank, no deal, no warp, no
 *         `Test.sol` import, no cheatcode that mutates state. Unlike the sibling
 *         `script/interactions/VerifyBalancerECLPPool.s.sol`, this one runs against live
 *         mainnet over RPC, not a fork, so a state-mutating cheatcode would simply revert.
 *
 *         FAIL-LOUD. Every check is a `require`. A failed `require` aborts the script with a
 *         non-zero exit code, which is what makes the `&&` in the npm chain halt.
 *
 *         WHY THE BPT BASELINE IS READ, NEVER RE-DERIVED. `bptAtPhase0` was historically a
 *         live read of the OLD pooler's BPT balance. Post-broadcast the old pooler is ALWAYS
 *         empty, so a live read yields 0 and Phase 7's conservation assertion collapses to
 *         `balanceOf(newPooler) >= 0` — trivially true even if the position had been moved to
 *         a third address. The audit is explicit that relocating Phase 7 to a standalone
 *         verifier without a persisted baseline ACTIVELY WORSENS finding L-02 and
 *         re-classifies it from Low to Medium. Story 074 persists `baselines.bptAtCutover`;
 *         this script CONSUMES it and aborts if it is absent. There is deliberately no
 *         live-read fallback. (`test/VerifyPromotionReadyGuards.t.sol` scans this file's source
 *         for the forbidden call and for state-mutating cheatcodes, so those literals are
 *         deliberately never spelled out verbatim anywhere in this file.)
 *
 *         Usage: `npm run promotion-ready:verify`
 */
contract VerifyPromotionReady is DeployMainnetPromotionReady {
    /// @dev Overrides the cutover entry point. The base `run()` is `virtual` for exactly this
    ///      reason; both cutover npm keys name `:DeployMainnetPromotionReady` explicitly, so
    ///      adding this contract to the compilation unit changes nothing for them.
    function run() external override {
        console.log("=================================================");
        console.log("  PROMOTION-READY POST-BROADCAST VERIFICATION");
        console.log("  (story 075 / script-audit run-22 M-01)");
        console.log("=================================================");
        console.log("Chain ID:               ", block.chainid);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        _requireNoBroadcastFlag();
        _loadAndValidateProgressFile();
        _adoptPersistedBptBaseline();

        // The whole point: Phase 7's absolute wiring assertions, re-run against LIVE
        // post-broadcast state rather than the local pre-broadcast pass.
        _phase7_wiringAssertions();

        _verifyMintAuthorityInvariance();

        _printSummary();
        console.log("");
        console.log("=================================================");
        console.log("  POST-BROADCAST VERIFICATION: ALL CHECKS PASS");
        console.log("=================================================");
        console.log("Verified against LIVE mainnet state, after dispatch - not the local pass.");
        console.log("STILL A HUMAN STEP (cannot be discharged read-only): story-072 checklist");
        console.log("line 1197 - trigger one index-4 mint and assert BatchDonatedViaPSM fired.");
    }

    /// @dev A verifier invoked with `--broadcast` would be a contradiction, and the operator
    ///      would have no signal that their verification was meaningless. There is no
    ///      cheatcode that reports the flag, so the check that actually holds the line is
    ///      structural: this contract opens no broadcast context anywhere, pinned at source
    ///      level by `test/VerifyPromotionReadyGuards.t.sol`. What IS worth rejecting here is
    ///      `PREVIEW_MODE`, which an operator may set out of habit from the dry-run key and
    ///      which means nothing on a live read-only pass.
    function _requireNoBroadcastFlag() internal view {
        require(!vm.envOr("PREVIEW_MODE", false), "PREVIEW_MODE is meaningless here - this reads LIVE state only");
    }

    /// @dev A partial progress file must fail loudly rather than silently skip assertions: a
    ///      zero address would make several Phase 7 checks read against `address(0)` and
    ///      revert with a confusing message, or worse, pass vacuously.
    function _loadAndValidateProgressFile() internal {
        _loadProgressFile();
        require(
            progressFileExists,
            "No progress file at server/deployments/progress.promotion-ready.1.json - the cutover has not been broadcast, or the file was moved. Nothing to verify"
        );

        _requireResolved(nudgeStreamer, "NudgeStreamer");
        _requireResolved(newBatchMinter, "BatchNFTMinter");
        _requireResolved(newPooler, "BalancerPooler");
        _requireResolved(newUniboostEYE, "UniboostEYE");
        _requireResolved(newUniboostSCX, "UniboostSCX");
        _requireResolved(newUniboostFLX, "UniboostFLX");
        _requireResolved(newRatchet, "NudgeRatchet");
        _requireResolved(newSYA, "StableYieldAccumulator");
        _requireResolved(v2StakerEYE, "UniboostStakerEYE");
        _requireResolved(v2StakerSCX, "UniboostStakerSCX");
        _requireResolved(v2StakerFLX, "UniboostStakerFLX");
        _requireResolved(migratorEYE, "NFTStakerMigratorEYE");
        _requireResolved(migratorSCX, "NFTStakerMigratorSCX");
        _requireResolved(migratorFLX, "NFTStakerMigratorFLX");
        console.log("Progress file resolved all 14 runtime addresses.");

        // A verifier run against a file the cutover never finished writing is a false
        // negative waiting to happen: the run may simply not be over yet.
        require(
            _isDeployed("NudgeStreamer") && _isDeployed("BatchNFTMinter"),
            "Progress file is missing core deployment records - the cutover did not complete. Resume it before verifying"
        );
    }

    function _requireResolved(address a, string memory name) internal pure {
        require(a != address(0), string.concat("Progress file carries no address for ", name, " - it is partial"));
    }

    /// @dev THE CRUX (audit run-22, L-02's conditional-Medium trigger). Story 074 persists the
    ///      write-once cutover baseline; this adopts it verbatim.
    ///
    ///      DO NOT "helpfully" add a live-balance fallback here reading the OLD pooler's BPT.
    ///      Post-broadcast that read is ALWAYS 0, and a 0 baseline turns the conservation
    ///      assertion into
    ///      `balanceOf(newPooler) >= 0`. That is precisely the vacuity this story exists to
    ///      prevent, and it would make a green verifier run prove nothing at all.
    function _adoptPersistedBptBaseline() internal {
        require(
            bptBaselineFromProgressFile,
            "ABORT: progress file carries no baselines.bptAtCutover. Without it the BPT conservation assertion is vacuous (balanceOf(newPooler) >= 0). Restore the baselines block verbatim from the broadcast run - NEVER hand-trim it - or re-derive it from the pre-cutover BPT balance of the old pooler recorded in the run logs"
        );
        require(
            bptAtCutoverPersisted > 0,
            "ABORT: persisted baselines.bptAtCutover is 0 - that cannot be the real pre-cutover BPT balance, and a 0 baseline makes the conservation assertion vacuous"
        );
        bptAtPhase0 = bptAtCutoverPersisted;
        console.log("Adopted persisted BPT cutover baseline:", bptAtPhase0);
        console.log("  new pooler BPT (live):              ", IERC20(BALANCER_POOL).balanceOf(newPooler));
    }

    /// @dev Story 075 stage 3. Two independent claims:
    ///
    ///        1. INVARIANCE over the fixed candidate set — membership and phUSD's global
    ///           `mintVersion` must be byte-identical to the Phase 0 snapshot. The cutover
    ///           makes zero `phUSD.setMinter` calls, so any drift is unexplained.
    ///        2. ABSOLUTE, for the 14 newly deployed contracts — none of them may hold phUSD
    ///           mint authority. This needs no baseline (they did not exist at Phase 0) and is
    ///           the stronger of the two claims: it is what "the cutover granted no new mint
    ///           authority" actually means.
    function _verifyMintAuthorityInvariance() internal view {
        console.log("\n=== phUSD mint-authority invariance (story 075) ===");
        require(
            phusdMinterBaselineFromProgressFile,
            "ABORT: progress file carries no baselines.phusdMinterMask/phusdMintVersion. phUSD mint-authority invariance is verified NOWHERE ELSE (story-072 checklist line 1195 is unticked) - either the cutover predates story 075, or phUSD exposed no readable minter set at Phase 0. Verify line 1195 BY HAND before disconnecting the Ledger"
        );

        (bool ok, uint256 liveMask, uint256 liveVersion) = _livePhusdMinterMask();
        require(
            ok,
            "phUSD exposes no readable minter set now, but did at Phase 0 - the live bytecode changed under us. STOP"
        );
        require(
            liveVersion == phusdMintVersionAtPhase0,
            "phUSD global mintVersion changed across the cutover - every existing mint grant was revoked or re-issued. STOP"
        );
        require(
            liveMask == phusdMinterMaskAtPhase0,
            "phUSD minter-set membership changed across the cutover. The cutover makes zero phUSD.setMinter calls, so this is unexplained. STOP"
        );
        console.log("  candidate-set membership and mintVersion unchanged; mask:", liveMask);

        // The absolute half. No baseline needed - these contracts did not exist at Phase 0.
        _requireNotPhusdMinter(nudgeStreamer, "NudgeStreamer");
        _requireNotPhusdMinter(newBatchMinter, "BatchNFTMinter");
        _requireNotPhusdMinter(newPooler, "BalancerPooler");
        _requireNotPhusdMinter(newUniboostEYE, "UniboostEYE");
        _requireNotPhusdMinter(newUniboostSCX, "UniboostSCX");
        _requireNotPhusdMinter(newUniboostFLX, "UniboostFLX");
        _requireNotPhusdMinter(newRatchet, "NudgeRatchet");
        _requireNotPhusdMinter(newSYA, "StableYieldAccumulator");
        _requireNotPhusdMinter(v2StakerEYE, "UniboostStakerEYE");
        _requireNotPhusdMinter(v2StakerSCX, "UniboostStakerSCX");
        _requireNotPhusdMinter(v2StakerFLX, "UniboostStakerFLX");
        _requireNotPhusdMinter(migratorEYE, "NFTStakerMigratorEYE");
        _requireNotPhusdMinter(migratorSCX, "NFTStakerMigratorSCX");
        _requireNotPhusdMinter(migratorFLX, "NFTStakerMigratorFLX");
        console.log("  none of the 14 newly deployed contracts holds phUSD mint authority");
        console.log("phUSD mint-authority invariance: PASS");
    }

    function _requireNotPhusdMinter(address who, string memory label) internal view {
        (bool ok, bool canMint, uint256 grantedAt) = _readPhusdMinter(who);
        require(ok, string.concat("phUSD minter read failed for ", label));
        // Mirrors `_livePhusdMinterMask`: a grant against a superseded version is inert.
        require(
            !canMint || grantedAt != phusdMintVersionAtPhase0,
            string.concat(label, " holds phUSD mint authority - the cutover was never supposed to grant it. STOP")
        );
    }
}
