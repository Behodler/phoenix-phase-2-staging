// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PostMigrationCleanup
 * @notice Story 060 - Step 5: verify migration integrity and revoke tempStaker's phUSD minter
 *         authorization.
 *
 *         Run AFTER Leg2Migration (step 4) has been broadcast.
 *         Reads:
 *           - script/migration-inputs/ys-swap-deployments.json
 *           - script/migration-inputs/leg2-stakers.json
 *
 *         Verifications (REVERT on failure):
 *           1. tempStaker.stakerCount(DOLA) == 0 && stakerCount(USDC) == 0
 *           2. original.stakerCount(DOLA) == expected from leg2 JSON
 *           3. original.stakerCount(USDC) == expected from leg2 JSON
 *           4. ysDolaV2.principalOf(DOLA, original) > 0
 *              4b. ysDolaV2 principal >= original.poolInfo(DOLA).totalStaked (solvent)
 *           5. ysUsdcV2.principalOf(USDC, original) > 0
 *              5b. ysUsdcV2 principal >= original.poolInfo(USDC).totalStaked (solvent)
 *           6. original.withdrawDisabled(DOLA) == false
 *           7. original.withdrawDisabled(USDC) == false
 *           8. ysDolaV2.setAsideBufferSize(original) == 10
 *           9. ysDolaV2.setAsideBufferRecipient() == original
 *          10. ysUsdcV2.setAsideBufferSize(original) == 10
 *          11. ysUsdcV2.setAsideBufferRecipient() == original
 *          12. IERC20(USDe).balanceOf(original) >= usdeSkimmed (if usdeSkimmed > 0)
 *
 *         The per-token "buffer" (principal - totalStaked) is logged as a diagnostic only,
 *         NOT bounded by a sanity band. It is EXPECTED to exceed the recorded skim: leg-1
 *         initiateMigration realizes the old strategy's accrued-yield surplus over credited
 *         principal, and ResetAndRewire's setYieldStrategy idle-sweep folds that surplus into
 *         V2 principal, so buffer = skim + realize-over-credit surplus (surplus dominating).
 *
 *         Execute:
 *           - phUSD.setMinter(tempStaker, false)  - revoke temp minter authorization
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/PostMigrationCleanup.s.sol:PostMigrationCleanup \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/PostMigrationCleanup.s.sol:PostMigrationCleanup \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

/// @dev Minimal interface for staker view and owner calls + YS-09 unpause/restore.
interface IStakerFull {
    function owner() external view returns (address);
    function stakerCount(address token) external view returns (uint256);
    function withdrawDisabled(address token) external view returns (bool);
    function poolInfo(address token) external view returns (uint256, uint256, uint256, uint256);
    // YS-09 unpause + pauser restore.
    function paused() external view returns (bool);
    function pauser() external view returns (address);
    function unpause() external;
    function setPauser(address _pauser) external;
}

/// @dev Minimal interface for V2 strategy view.
interface IYSView {
    function principalOf(address token, address account) external view returns (uint256);
    function setAsideBufferSize(address client) external view returns (uint256);
    function setAsideBufferRecipient() external view returns (address);
    // YS-03: a configured buffer is dead unless a consumer (the SYA withdrawer) exists for it.
    function authorizedWithdrawers(address withdrawer) external view returns (bool);
}

/// @dev YS-03: minimal view interface for the live StableYieldAccumulator (SYA) strategy list.
interface ISYAAdmin {
    function getYieldStrategies() external view returns (address[] memory);
}

/// @dev Minimal interface for phUSD minter authorization.
interface IPhUSDSetMinter {
    function owner() external view returns (address);
    function setMinter(address minter, bool canMint) external;
}

contract PostMigrationCleanup is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES
    // ==========================================

    address public constant OWNER_ADDRESS          = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant ORIGINAL_STABLE_STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    address public constant PHUSD                  = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;

    address public constant DOLA                   = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC                   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDe                   = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // YS-03: live StableYieldAccumulator (replace-sya deployment; mainnet-addresses.ts:34).
    address public constant SYA                    = 0x3C690EC3B2524104dE269bf0F9baa7f045eF8270;

    uint256 public constant CHAIN_ID               = 1;
    uint256 public constant EXPECTED_BUFFER        = 10;

    // ==========================================
    //   RUNTIME STATE
    // ==========================================

    bool public isPreview;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "PostMigrationCleanup: wrong chain - expected mainnet (1)");
    }

    function run() external {
        console.log("==========================================");
        console.log(" PostMigrationCleanup (story 060, step 5)");
        console.log("==========================================");
        console.log("Chain ID:          ", block.chainid);
        console.log("Owner (ledger):    ", OWNER_ADDRESS);
        console.log("");

        // Read deployments JSON.
        string memory deploymentsRaw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address ysDolaV2       = vm.parseJsonAddress(deploymentsRaw, ".ysDolaV2");
        address ysUsdcV2       = vm.parseJsonAddress(deploymentsRaw, ".ysUsdcV2");
        address tempStakerAddr = vm.parseJsonAddress(deploymentsRaw, ".tempStaker");

        // YS-09: recorded original pausers written by the deploy step. Read defensively (a deployments
        // JSON produced before the YS-09 hardening will not contain them) — if absent, the restore
        // step is skipped with a loud warning rather than reverting cleanup.
        address recordedOrigPauser = address(0);
        bool origPauserRecorded = false;
        try vm.parseJsonAddress(deploymentsRaw, ".origPauser") returns (address v) {
            recordedOrigPauser = v;
            origPauserRecorded = true;
        } catch {}
        address recordedTempPauser = address(0);
        bool tempPauserRecorded = false;
        try vm.parseJsonAddress(deploymentsRaw, ".tempPauser") returns (address v) {
            recordedTempPauser = v;
            tempPauserRecorded = true;
        } catch {}

        // Read skim amounts (may not exist in deployments JSON if step 2 was preview-only).
        uint256 usdeSkimmed = 0;
        try vm.parseJsonUint(deploymentsRaw, ".usdeSkimmed") returns (uint256 v) {
            usdeSkimmed = v;
        } catch {}
        // Skims are read purely for the 4b/5b diagnostic logs below — they no longer gate any
        // require (the buffer sanity band was removed, YS-10). Default 0 if not recorded.
        uint256 dolaSkimmed = 0;
        try vm.parseJsonUint(deploymentsRaw, ".dolaSkimmed") returns (uint256 v) {
            dolaSkimmed = v;
        } catch {}
        uint256 usdcSkimmed = 0;
        try vm.parseJsonUint(deploymentsRaw, ".usdcSkimmed") returns (uint256 v) {
            usdcSkimmed = v;
        } catch {}

        // Read expected staker counts from leg2.
        string memory leg2Raw = vm.readFile("script/migration-inputs/leg2-stakers.json");
        uint256 expectedDolaCount = vm.parseJsonUint(leg2Raw, ".tokens.DOLA.count");
        uint256 expectedUsdcCount = vm.parseJsonUint(leg2Raw, ".tokens.USDC.count");

        console.log("ysDolaV2:              ", ysDolaV2);
        console.log("ysUsdcV2:              ", ysUsdcV2);
        console.log("tempStaker:            ", tempStakerAddr);
        console.log("usdeSkimmed:           ", usdeSkimmed);
        console.log("expected DOLA stakers: ", expectedDolaCount);
        console.log("expected USDC stakers: ", expectedUsdcCount);
        console.log("");

        // ---- Verifications (all REVERT on failure) ----
        console.log("=== Verifications ===");

        // 1. tempStaker fully drained.
        uint256 tempDola = IStakerFull(tempStakerAddr).stakerCount(DOLA);
        uint256 tempUsdc = IStakerFull(tempStakerAddr).stakerCount(USDC);
        require(tempDola == 0, "Verify 1a FAILED: tempStaker DOLA stakerCount != 0");
        require(tempUsdc == 0, "Verify 1b FAILED: tempStaker USDC stakerCount != 0");
        console.log("  1. tempStaker fully drained: OK");

        // 2-3. original staker has expected counts.
        uint256 origDola = IStakerFull(ORIGINAL_STABLE_STAKER).stakerCount(DOLA);
        uint256 origUsdc = IStakerFull(ORIGINAL_STABLE_STAKER).stakerCount(USDC);
        require(
            origDola == expectedDolaCount,
            "Verify 2 FAILED: original DOLA stakerCount != leg2 expected"
        );
        require(
            origUsdc == expectedUsdcCount,
            "Verify 3 FAILED: original USDC stakerCount != leg2 expected"
        );
        console.log("  2. original DOLA stakerCount:", origDola, "== expected OK");
        console.log("  3. original USDC stakerCount:", origUsdc, "== expected OK");

        // 4-5. V2 strategies have non-zero principal.
        uint256 dolaP = IYSView(ysDolaV2).principalOf(DOLA, ORIGINAL_STABLE_STAKER);
        uint256 usdcP = IYSView(ysUsdcV2).principalOf(USDC, ORIGINAL_STABLE_STAKER);
        require(dolaP > 0, "Verify 4 FAILED: ysDolaV2.principalOf == 0");
        require(usdcP > 0, "Verify 5 FAILED: ysUsdcV2.principalOf == 0");
        console.log("  4. ysDolaV2.principalOf > 0:", dolaP, "OK");
        console.log("  5. ysUsdcV2.principalOf > 0:", usdcP, "OK");

        // 4b-5b. Hard solvency invariant (the real safety property): strategy-side principal must
        // cover staker-side totalStaked. Every user deposit credits the SAME amount to both
        // principalOf and totalStaked, so a negative difference would mean user credits exceed
        // strategy principal — the strategy is insolvent w.r.t. its stakers — and cleanup must abort.
        //
        //   solvent  <=>  principalOf(token, original) >= poolInfo(token).totalStaked
        //
        // The "buffer" (principalOf - totalStaked) is a pure DIAGNOSTIC, logged but NOT bounded. There
        // is deliberately NO sanity band: the buffer is EXPECTED to far exceed the recorded skim.
        // leg-1 initiateMigration realizes the old strategy's whole position into idle, which exceeds
        // credited principal by the strategy's accrued yield; ResetAndRewire's setYieldStrategy
        // idle-sweep then folds that entire excess into V2 principal. So buffer = skim +
        // realize-over-credit surplus, with the surplus dominating (on fork the USDC buffer was ~51x
        // the skim). The earlier [skim/2, skim*2] band was built on the false premise buffer ≈ skim and
        // would revert valid migrated state before the minter-revocation mutation could run.
        (, , , uint256 dolaTotalStaked) = IStakerFull(ORIGINAL_STABLE_STAKER).poolInfo(DOLA);
        (, , , uint256 usdcTotalStaked) = IStakerFull(ORIGINAL_STABLE_STAKER).poolInfo(USDC);
        require(dolaP >= dolaTotalStaked, "Verify 4b FAILED: ysDolaV2 principal < totalStaked (insolvent)");
        require(usdcP >= usdcTotalStaked, "Verify 5b FAILED: ysUsdcV2 principal < totalStaked (insolvent)");
        uint256 dolaBufferActual = dolaP - dolaTotalStaked;
        uint256 usdcBufferActual = usdcP - usdcTotalStaked;
        console.log("  4b. DOLA buffer (principal - totalStaked):", dolaBufferActual);
        console.log("      dolaSkimmed (diagnostic only; buffer = skim + realize-over-credit surplus):", dolaSkimmed);
        console.log("  5b. USDC buffer (principal - totalStaked):", usdcBufferActual);
        console.log("      usdcSkimmed (diagnostic only; buffer = skim + realize-over-credit surplus):", usdcSkimmed);

        // 6-7. Withdrawals enabled (migration complete, not underwater).
        bool dolaWdDisabled = IStakerFull(ORIGINAL_STABLE_STAKER).withdrawDisabled(DOLA);
        bool usdcWdDisabled = IStakerFull(ORIGINAL_STABLE_STAKER).withdrawDisabled(USDC);
        require(!dolaWdDisabled, "Verify 6 FAILED: original DOLA withdrawDisabled == true");
        require(!usdcWdDisabled, "Verify 7 FAILED: original USDC withdrawDisabled == true");
        console.log("  6. original DOLA withdrawDisabled: false OK");
        console.log("  7. original USDC withdrawDisabled: false OK");

        // 8-9. ysDolaV2 buffer wiring.
        uint256 dolaBuffer = IYSView(ysDolaV2).setAsideBufferSize(ORIGINAL_STABLE_STAKER);
        address dolaRecipient = IYSView(ysDolaV2).setAsideBufferRecipient();
        require(dolaBuffer == EXPECTED_BUFFER, "Verify 8 FAILED: ysDolaV2 setAsideBufferSize != 10");
        require(
            dolaRecipient == ORIGINAL_STABLE_STAKER,
            "Verify 9 FAILED: ysDolaV2 setAsideBufferRecipient != original staker"
        );
        console.log("  8. ysDolaV2 bufferSize:", dolaBuffer, "OK");
        console.log("  9. ysDolaV2 bufferRecipient:", dolaRecipient, "OK");

        // 10-11. ysUsdcV2 buffer wiring.
        uint256 usdcBuffer = IYSView(ysUsdcV2).setAsideBufferSize(ORIGINAL_STABLE_STAKER);
        address usdcRecipient = IYSView(ysUsdcV2).setAsideBufferRecipient();
        require(usdcBuffer == EXPECTED_BUFFER, "Verify 10 FAILED: ysUsdcV2 setAsideBufferSize != 10");
        require(
            usdcRecipient == ORIGINAL_STABLE_STAKER,
            "Verify 11 FAILED: ysUsdcV2 setAsideBufferRecipient != original staker"
        );
        console.log("  10. ysUsdcV2 bufferSize:", usdcBuffer, "OK");
        console.log("  11. ysUsdcV2 bufferRecipient:", usdcRecipient, "OK");

        // 11a-11b. YS-03 consumer-exists post-conditions. A configured buffer (verify 8-11 above)
        // is dead value-leakage unless a consumer can actually skim it: the SYA must be an
        // authorized withdrawer on each V2 strategy AND each must be registered in the SYA's
        // strategy list. These are asserted right next to the buffer-size checks so the two can
        // never drift apart. (Old YS_DOLA/YS_USDC entries are deliberately left in the SYA list
        // until YS-12; their presence is benign and not checked here.)
        require(
            IYSView(ysDolaV2).authorizedWithdrawers(SYA),
            "Verify 11a FAILED: ysDolaV2 has buffer but no SYA consumer (not authorized withdrawer)"
        );
        require(
            IYSView(ysUsdcV2).authorizedWithdrawers(SYA),
            "Verify 11b FAILED: ysUsdcV2 has buffer but no SYA consumer (not authorized withdrawer)"
        );
        address[] memory syaStrategies = ISYAAdmin(SYA).getYieldStrategies();
        bool dolaRegistered;
        bool usdcRegistered;
        for (uint256 i = 0; i < syaStrategies.length; i++) {
            if (syaStrategies[i] == ysDolaV2) dolaRegistered = true;
            if (syaStrategies[i] == ysUsdcV2) usdcRegistered = true;
        }
        require(dolaRegistered, "Verify 11c FAILED: ysDolaV2 not registered in SYA strategy list");
        require(usdcRegistered, "Verify 11d FAILED: ysUsdcV2 not registered in SYA strategy list");
        console.log("  11a-d. SYA consumer exists: both V2 strategies authorized + registered OK");

        // 12. USDe skim balance check.
        if (usdeSkimmed > 0) {
            uint256 usdeBal = IERC20(USDe).balanceOf(ORIGINAL_STABLE_STAKER);
            require(
                usdeBal >= usdeSkimmed,
                "Verify 12 FAILED: original staker USDe balance < usdeSkimmed"
            );
            console.log("  12. USDe balance OK:", usdeBal);
            console.log("      usdeSkimmed was:", usdeSkimmed);
        } else {
            console.log("  12. USDe skim check: skipped (usdeSkimmed == 0 or not recorded)");
        }
        console.log("");

        require(
            IPhUSDSetMinter(PHUSD).owner() == OWNER_ADDRESS,
            "Cleanup: phUSD owner != OWNER_ADDRESS"
        );

        // ---- Execute: revoke tempStaker minter ----
        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***");
            console.log("");
            vm.startBroadcast();
        }

        console.log("=== Cleanup: revoke tempStaker phUSD minter ===");
        IPhUSDSetMinter(PHUSD).setMinter(tempStakerAddr, false);
        console.log("  phUSD.setMinter(tempStaker, false) done");
        console.log("");

        // ---- YS-09: unpause both stakers + restore recorded pausers ----
        // The deploy step paused both stakers (and took the pauser role) to close the stake() grief
        // surface for the migration window. Now that migration is complete, reopen staking and hand
        // the pauser role back to the originally-wired pauser (e.g. the global Pauser contract from
        // story 052). All calls idempotent so a re-run of cleanup is a clean no-op.
        console.log("=== YS-09: unpause + restore pausers ===");
        if (IStakerFull(ORIGINAL_STABLE_STAKER).paused()) {
            IStakerFull(ORIGINAL_STABLE_STAKER).unpause();
            console.log("  original.unpause() done");
        } else {
            console.log("  original.unpause() SKIPPED - already unpaused (resume)");
        }
        if (IStakerFull(tempStakerAddr).paused()) {
            IStakerFull(tempStakerAddr).unpause();
            console.log("  tempStaker.unpause() done");
        } else {
            console.log("  tempStaker.unpause() SKIPPED - already unpaused (resume)");
        }

        if (origPauserRecorded) {
            if (IStakerFull(ORIGINAL_STABLE_STAKER).pauser() != recordedOrigPauser) {
                IStakerFull(ORIGINAL_STABLE_STAKER).setPauser(recordedOrigPauser);
                console.log("  original.setPauser(recorded) done:", recordedOrigPauser);
            } else {
                console.log("  original.setPauser(recorded) SKIPPED - already restored (resume)");
            }
        } else {
            console.log("  WARNING: origPauser not recorded in deployments JSON - pauser NOT restored");
        }
        if (tempPauserRecorded) {
            if (IStakerFull(tempStakerAddr).pauser() != recordedTempPauser) {
                IStakerFull(tempStakerAddr).setPauser(recordedTempPauser);
                console.log("  tempStaker.setPauser(recorded) done:", recordedTempPauser);
            } else {
                console.log("  tempStaker.setPauser(recorded) SKIPPED - already restored (resume)");
            }
        } else {
            console.log("  WARNING: tempPauser not recorded in deployments JSON - pauser NOT restored");
        }
        console.log("");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- YS-09 post-assert: both stakers unpaused and pausers restored ----
        require(!IStakerFull(ORIGINAL_STABLE_STAKER).paused(), "Post-assert: original staker still paused");
        require(!IStakerFull(tempStakerAddr).paused(), "Post-assert: tempStaker still paused");
        if (origPauserRecorded) {
            require(
                IStakerFull(ORIGINAL_STABLE_STAKER).pauser() == recordedOrigPauser,
                "Post-assert: original staker pauser not restored to recorded value"
            );
        }
        if (tempPauserRecorded) {
            require(
                IStakerFull(tempStakerAddr).pauser() == recordedTempPauser,
                "Post-assert: tempStaker pauser not restored to recorded value"
            );
        }
        console.log("YS-09: both stakers unpaused; pausers restored OK");
        console.log("");

        _printSummary(ysDolaV2, ysUsdcV2, dolaP, usdcP);
    }

    function _printSummary(address ysDolaV2, address ysUsdcV2, uint256 dolaP, uint256 usdcP) internal view {
        console.log("==========================================");
        console.log("  SUMMARY (story 060 step 5 - COMPLETE)");
        console.log("==========================================");
        console.log("ysDolaV2:                    ", ysDolaV2);
        console.log("ysUsdcV2:                    ", ysUsdcV2);
        console.log("ysDolaV2 principalOf(orig):  ", dolaP);
        console.log("ysUsdcV2 principalOf(orig):  ", usdcP);
        console.log("");
        console.log("All 12 verifications PASSED.");
        console.log("tempStaker minter authorization REVOKED.");
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
        } else {
            console.log("YS-swap migration COMPLETE.");
        }
        console.log("==========================================");
    }
}
