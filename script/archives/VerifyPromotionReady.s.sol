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
 *         STORY 076 EXTENDED IT. The cutover now includes a PhlimboV3 deployment and a
 *         PhlimboV2 user-base migration (Phase 4e), so this verifier gained two runtime
 *         addresses, a second persisted baseline (`baselines.phlimboV2StakedAtCutover`) and a
 *         RESTATED mint-authority claim. That last one matters: story 075 asserted phUSD
 *         mint-authority INVARIANCE because story 072 made zero `setMinter` calls. Phase 4e
 *         makes two — grant PhlimboV3, revoke PhlimboV2 — so invariance would now FAIL on a
 *         correct cutover. It is replaced by an expected TWO-SIDED DELTA plus a POSITIVE
 *         assertion on PhlimboV3. See `_verifyMintAuthorityInvariance`.
 *
 *         STORY 078 EXTENDED IT AGAIN, and cheaply: Phase 4f's deposit-page cutover adds one
 *         runtime address (`DepositPageViewV3`) and a `view`-only assertion block inside Phase 7,
 *         so this verifier inherits the whole of it. The only edits here are resolving that
 *         address from the progress file — the ONLY off-chain record of it, since the story
 *         deliberately mints no address-book key — and adding it to the mint-authority sweep.
 *
 *         INHERITANCE, NOT DUPLICATION. Deriving from the deploy script gives this file all
 *         ~200 address constants, the 17 runtime address members, `_loadProgressFile()`,
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
 *         THE SAME ARGUMENT APPLIES VERBATIM TO STORY 076's SECOND BASELINE. Post-broadcast
 *         PhlimboV2 is ALWAYS empty — the cutover's own completeness gate demands
 *         `totalStaked() == 0` — so re-deriving the migration baseline from a live read gives
 *         0, and the conservation assertion collapses to `phlimboV3.totalStaked() >= 0`. It is
 *         consumed from `baselines.phlimboV2StakedAtCutover` and aborts if absent or zero. Do
 *         not add a fallback there either.
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
        _adoptPersistedPhlimboBaseline();

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
        // Story 076. `MigratorV2V3` is resolved here even though it is transient and gets no
        // `mainnet-addresses.ts` key: Phase 7 asserts its cursor, its seed flag and both of
        // its immutable endpoints, all of which need the address.
        _requireResolved(newPhlimboV3, "PhlimboV3");
        _requireResolved(migratorV2V3, "MigratorV2V3");
        // Story 078. `DepositPageViewV3` is resolved here even though it deliberately gets NO
        // `mainnet-addresses.ts` key — the progress file is the ONLY off-chain record of its
        // address, and Phase 7 asserts its two immutables and the router slot that names it.
        _requireResolved(newDepositPageViewV3, "DepositPageViewV3");
        console.log("Progress file resolved all 17 runtime addresses.");

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

    /// @dev Story 076, exactly the same crux as `_adoptPersistedBptBaseline` applied to the
    ///      PhlimboV2 -> PhlimboV3 stake migration.
    ///
    ///      DO NOT add a live-read fallback here either. Post-broadcast PhlimboV2 is ALWAYS
    ///      empty — the cutover's own completeness gate requires `totalStaked() == 0` — so a
    ///      re-derived baseline is 0 and Phase 7's conservation assertion collapses to
    ///      `phlimboV3.totalStaked() >= 0`, which passes no matter where the migrated stake
    ///      actually went. An absent or zero baseline therefore ABORTS.
    function _adoptPersistedPhlimboBaseline() internal {
        require(
            phlimboBaselineFromProgressFile,
            "ABORT: progress file carries no baselines.phlimboV2StakedAtCutover. Without it the PhlimboV3 stake-conservation assertion is vacuous (totalStaked >= 0). Restore the baselines block verbatim from the broadcast run - NEVER hand-trim it - or re-derive it from the pre-migration PhlimboV2 totalStaked recorded in the run logs"
        );
        require(
            phlimboV2StakedAtCutover > 0,
            "ABORT: persisted baselines.phlimboV2StakedAtCutover is 0 - that cannot be the real pre-migration PhlimboV2 stake, and a 0 baseline makes the conservation assertion vacuous"
        );
        console.log("Adopted persisted PhlimboV2 migration baseline:", phlimboV2StakedAtCutover);
    }

    /// @dev Story 075 stage 3, RESTATED BY STORY 076. Three claims now:
    ///
    ///        1. EXPECTED TWO-SIDED DELTA over the fixed candidate set. Story 075's claim was
    ///           INVARIANCE — byte-identical membership — because story 072 made zero
    ///           `phUSD.setMinter` calls. Phase 4e makes two, so invariance is now the WRONG
    ///           claim and would fail on a correct cutover. The right claim is that the mask
    ///           lost EXACTLY the PhlimboV2 bit and NOTHING ELSE moved. Asserting both
    ///           directions is what keeps the control meaningful: a one-sided "V2 was revoked"
    ///           check would not notice an unintended grant or revoke elsewhere in the set.
    ///
    ///           phUSD's global `mintVersion` is still asserted UNCHANGED. `setMinter` does
    ///           not touch it (`FlaxToken.sol:44-51`); only `revokeAllMintPrivileges` does
    ///           (`:88-90`), and the cutover never calls that.
    ///
    ///        2. POSITIVE, for PhlimboV3. It is a runtime CREATE, so it cannot live in the
    ///           `pure` compile-time candidate set and its grant cannot be expressed as a mask
    ///           bit. It is asserted directly instead — and it MUST be asserted somewhere,
    ///           because a missing grant fails SILENTLY: `PhlimboV3._claimRewards` banks a
    ///           failed mint rather than reverting (`PhlimboV3.sol:913`).
    ///
    ///        3. ABSOLUTE, for the other 16 newly deployed contracts — none may hold phUSD
    ///           mint authority. PhlimboV3 is the ONE declared exclusion; every other new
    ///           contract, `MigratorV2V3` and (story 078) `DepositPageViewV3` included, stays
    ///           in the sweep. `MigratorV2V3` genuinely needs no mint role: V2 itself mints the
    ///           pending phUSD rewards during `withdraw` (`MigratorV2V3.sol:54-56`);
    ///           `DepositPageViewV3` is a pure view. A blanket relaxation to accommodate
    ///           PhlimboV3 would silently discard a real control.
    function _verifyMintAuthorityInvariance() internal view {
        console.log("\n=== phUSD mint-authority delta (story 075, restated by story 076) ===");
        require(
            phusdMinterBaselineFromProgressFile,
            "ABORT: progress file carries no baselines.phusdMinterMask/phusdMintVersion. The phUSD mint-authority delta is verified NOWHERE ELSE (story-072 checklist line 1195 is unticked) - either the cutover predates story 075, or phUSD exposed no readable minter set at Phase 0. Verify line 1195 BY HAND before disconnecting the Ledger"
        );
        // Cheap guard against a reordered candidate array silently repointing the bit below.
        _requirePhlimboV2BitIndex();

        (bool ok, uint256 liveMask, uint256 liveVersion) = _livePhusdMinterMask();
        require(
            ok,
            "phUSD exposes no readable minter set now, but did at Phase 0 - the live bytecode changed under us. STOP"
        );
        require(
            liveVersion == phusdMintVersionAtPhase0,
            "phUSD global mintVersion changed across the cutover - every existing mint grant was revoked or re-issued. STOP"
        );

        // THE TWO-SIDED DELTA. Clearing exactly one known bit from the baseline and requiring
        // byte-equality with the live mask asserts both directions at once: nothing else may
        // have been revoked, and nothing at all may have been granted.
        uint256 v2Bit = 1 << PHUSD_MINTER_BIT_PHLIMBO_V2;
        require(
            liveMask == (phusdMinterMaskAtPhase0 & ~v2Bit),
            "phUSD minter-set membership does not match the EXPECTED delta. The cutover may clear exactly the PhlimboV2 bit and change nothing else; any other movement is unexplained. STOP"
        );
        // A baseline whose PhlimboV2 bit was never set means the revoke was a no-op, which
        // makes the delta above degenerate into the old invariance check. Not an error - V2
        // may legitimately never have held the grant - but say so rather than let a green run
        // imply a revoke was verified.
        if (phusdMinterMaskAtPhase0 & v2Bit == 0) {
            console.log("  NOTE: PhlimboV2 did not hold phUSD mint authority at Phase 0 - the revoke was a no-op.");
        } else {
            console.log("  PhlimboV2's phUSD mint authority was revoked, and nothing else in the set moved.");
        }
        console.log("  mintVersion unchanged; baseline / live mask:", phusdMinterMaskAtPhase0, liveMask);

        // The POSITIVE half (story 076). PhlimboV3 MUST hold mint authority.
        {
            (bool okV3, bool canMint, uint256 grantedAt) = _readPhusdMinter(newPhlimboV3);
            require(okV3, "phUSD minter read failed for PhlimboV3");
            require(
                canMint && grantedAt == liveVersion,
                "PhlimboV3 does NOT hold phUSD mint authority. Its reward mints will silently bank as unpayable instead of reverting (PhlimboV3.sol:913), so nothing else would ever surface this. STOP"
            );
            console.log("  PhlimboV3 holds phUSD mint authority at the current mintVersion");
        }

        // The absolute half. No baseline needed - these contracts did not exist at Phase 0.
        // PhlimboV3 is deliberately ABSENT from this sweep and asserted positively above; it
        // is the ONLY exclusion.
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
        // Story 076: MigratorV2V3 stays IN the sweep. It needs no mint role - V2 itself mints
        // the pending phUSD rewards during `withdraw` (MigratorV2V3.sol:54-56).
        _requireNotPhusdMinter(migratorV2V3, "MigratorV2V3");
        // Story 078: DepositPageViewV3 is a newly deployed contract, so it joins the sweep. It is
        // a pure view with no mint call anywhere in it, which is exactly why the sweep — not a
        // judgement call — is what proves it holds no authority. 15 -> 16 swept, 17 new contracts
        // in total once the positively-asserted PhlimboV3 is counted.
        _requireNotPhusdMinter(newDepositPageViewV3, "DepositPageViewV3");
        console.log("  none of the other 16 newly deployed contracts holds phUSD mint authority");
        console.log("phUSD mint-authority delta: PASS");
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
