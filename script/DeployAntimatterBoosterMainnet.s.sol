// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlax} from "@phUSD/IFlax.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {AntimatterBooster} from "antimatter/AntimatterBooster.sol";
import {
    AntimatterBoosterMainnetBase,
    IPhUSDBooster,
    IAntimatterBoosterView,
    IPhusdStableMinterBooster,
    IPauserV2Booster
} from "./helpers/AntimatterBoosterMainnetBase.sol";

/**
 * @title DeployAntimatterBoosterMainnet  (story 139, sprint antimatter-boost)
 * @notice Deploys antimatter:005's `AntimatterBooster` (submodule pin lib/antimatter 70ea8f3, built with phStaging2's
 *         settings) to mainnet at a 15% boost, and revokes OWNER's phUSD mint right as the very last step. Mirrors the
 *         anvil wiring in `DeployMocks._deployAntimatterBooster` (story 138) MINUS its anvil scaffolding (no
 *         `setClient` - the active minter is already a client of all three strategies - and no USDe seeding):
 *           0. deploy `AntimatterBooster(OWNER, Antimatter, phUSD)` (inert: boostBps 0, pauser 0, no stables), or
 *              adopt the one recorded in server/deployments/progress.antimatter-booster.1.json;
 *           1. `phUSD.setMinter(booster, true)` (read back as a LIVE minter at the current mintVersion);
 *           2. `addTrackedStable` DOLA, USDC, USDe (all three: the 1/6 POC denominator needs them);
 *           3. `booster.setPauser(PauserV2)`, THEN 4. `PauserV2.register(booster)` (register needs pauser() == V2);
 *           5. `setBoostBps(1_500)` - only after 1-4 are re-checked; this is the call that enables boosting;
 *           6. LAST: `phUSD.setMinter(OWNER, false)` - single-address revoke (human request, safety). NEVER
 *              `revokeAllMintPrivileges()`, which would bump mintVersion and kill every live minter. Steps 1-5 use
 *              OWNER's onlyOwner powers, which the revoke does not touch (re-grant: `phUSD.setMinter(OWNER, true)`).
 *         Every step is gated on chain state and read back with a `require`, so a re-run resumes where the chain
 *         stands and a finished run sends nothing.
 *
 *         POC: the booster (and this script's view asserts) read ONLY the active minter, `Antimatter.phUSDMinter()`,
 *         which preflight requires to equal the book's PhusdStableMinter (V2). The V1 minter's ~3,749.6 USDe in the
 *         shared USDe strategy is excluded by design. Eligibility is market state: if USDe has drifted out of the
 *         1/6 band, the script WARNS rather than reverts (the deploy is still valid).
 *
 *         NO FUNDS TO THE LEDGER. OWNER `0xCad1...D0B6` only pays gas. OWNER's ETH and the book ERC20s are
 *         snapshotted before the first call and `OwnerBalanceIncreased` reverts after EVERY transaction if any rose.
 *         Nothing here calls phUSD.mint, antimatter.mint or rescueERC20, and no call names OWNER as a recipient.
 *
 *         MINTER-SET INTEGRITY. Every address ever named in a phUSD `MinterSet` event is snapshotted with
 *         mintVersion; after wiring exactly two entries may differ - the booster (now live) and OWNER (revoked).
 *
 *         PREVIEW ONLY (snapshot-reverted, never in a broadcast session): a third-party actor (never OWNER) dealt AM
 *         and USDe calls `boostedAnnihilate(USDe)` and must receive base + 15%; a global PauserV2 pause round-trip
 *         shows the booster pauses (boostedAnnihilate reverts) and recovers.
 *
 *         Progress: written `pending` with the CREATE nonce in forge's local pass, only when
 *         ANTIMATTER_BOOSTER_BROADCAST=true (set by the :broadcast key alone); scripts/confirm-antimatter-booster-
 *         progress.js flips it to `completed`. The book and PauserV2Registry are patched afterwards by
 *         scripts/patch-mainnet-addresses-antimatter-booster.js.
 *
 * Preview:   npm run antimatter-booster:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed)
 * Broadcast: npm run antimatter-booster:broadcast   (the human only, Ledger m/44'/60'/46'/0/0)
 * Verify:    npm run antimatter-booster-verify      (read-only)
 * Runbook:   docs/runbooks/antimatter-booster-mainnet.md
 */
contract DeployAntimatterBoosterMainnet is AntimatterBoosterMainnetBase {
    /// @dev Smoke size: 10 AM against 10 USDe (USDe is 18dp, so any amount is representable). Well under the
    ///      active minter's 4,000e18/day cap.
    uint256 internal constant SMOKE_AMOUNT = 10e18;

    AntimatterBooster public booster;
    bool public deployedThisRun;
    /// @dev Transactions this run sent (or, in preview, would send). Read by the fork tests.
    uint256 public txCount;
    /// @dev Preview results (read by the fork tests).
    uint256 public smokeBase;
    uint256 public smokeBonus;
    uint256 public smokeReceived;
    bool public usdeEligible;

    bool internal isPreview;

    function run() external {
        console.log("=================================================");
        console.log("  DEPLOY + WIRE AntimatterBooster - MAINNET (story 139)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );
        if (!isPreview) require(_sender() == OWNER, "broadcast sender must be OWNER (--sender + Ledger)");

        _preflight();
        _snapshotOwnerBalances();
        _snapshotMinterSet();

        // ---- 0. Deploy, or adopt from the progress file ----
        address recorded = _progressBooster();
        address booked = _bookBooster();
        if (recorded != address(0)) {
            require(
                booked == address(0) || booked == recorded, "address book AntimatterBooster != progress file booster"
            );
            _requireRecordedBoosterLanded(recorded);
            booster = AntimatterBooster(recorded);
            _checkImmutables(booster);
            console.log("0. AntimatterBooster adopted from progress file:", recorded);
        } else {
            require(
                booked == address(0),
                "address book names an AntimatterBooster but there is no progress file - restore progress.antimatter-booster.1.json"
            );
            if (!isPreview) _requireBroadcastGasPriceHeadroom();
            uint256 createNonce = vm.getNonce(OWNER);
            _begin();
            booster = new AntimatterBooster(OWNER, Antimatter(ANTIMATTER), IFlax(PHUSD));
            _end("0. deploy");
            deployedThisRun = true;
            _checkImmutables(booster);
            require(booster.boostBps() == 0, "fresh booster must deploy inert (boostBps)");
            require(booster.pauser() == address(0), "fresh booster must deploy inert (pauser)");
            require(booster.trackedStables().length == 0, "fresh booster must deploy inert (stables)");
            console.log("0. AntimatterBooster deployed:", address(booster));
            if (!isPreview) _recordPendingProgress(address(booster), createNonce);
        }

        if (!isPreview && !deployedThisRun && !_wiringComplete()) _requireBroadcastGasPriceHeadroom();
        _wire();
        _requireWired(booster);
        _assertMinterSetDelta(address(booster));
        _assertEligibility();

        if (isPreview) {
            _smoke();
            _globalPauseRoundTrip();
        }
        _assertOwnerBalancesNotIncreased("final");

        console.log("Transactions sent (or simulated):", txCount);
        if (txCount == 0) console.log("Nothing to do: booster fully wired, OWNER revoked, no transaction sent.");
        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (a preview CREATE address is fork-local)."
            );
        } else {
            console.log("Next (chained by :broadcast): confirm progress, patch book + PauserV2Registry, verify.");
        }
    }

    // ============ Wiring ============

    function _stablesTracked() internal view returns (bool) {
        return booster.isTracked(DOLA) && booster.isTracked(USDC) && booster.isTracked(USDE)
            && booster.trackedStables().length == 3;
    }

    function _steps1to4Done() internal view returns (bool) {
        address b = address(booster);
        return _isLivePhusdMinter(b) && _stablesTracked() && booster.pauser() == PAUSER_V2
            && IPauserV2Booster(PAUSER_V2).isRegistered(b);
    }

    function _ownerCanMint() internal view returns (bool canMint) {
        (canMint,) = IPhUSDBooster(PHUSD).authorizedMinters(OWNER);
    }

    function _wire() internal {
        address b = address(booster);

        // 1. phUSD mint right for the bonus. Read back as LIVE (canMint && version == mintVersion).
        if (!_isLivePhusdMinter(b)) {
            _begin();
            IPhUSDBooster(PHUSD).setMinter(b, true);
            _end("1. phUSD.setMinter(booster, true)");
            console.log("1. phUSD.setMinter(booster, true)");
        } else {
            console.log("1. booster already a live phUSD minter - skipped");
        }
        require(_isLivePhusdMinter(b), "step 1: booster is not a live phUSD minter");

        // 2. Tracked stables, in the anvil order (DOLA, USDC, USDe).
        address[3] memory stables = [DOLA, USDC, USDE];
        string[3] memory names = ["DOLA", "USDC", "USDe"];
        for (uint256 i = 0; i < 3; i++) {
            if (!booster.isTracked(stables[i])) {
                _begin();
                booster.addTrackedStable(stables[i]);
                _end(string.concat("2. addTrackedStable(", names[i], ")"));
                console.log(string.concat("2. booster.addTrackedStable(", names[i], ")"));
            } else {
                console.log(string.concat("2. ", names[i], " already tracked - skipped"));
            }
        }
        require(_stablesTracked(), "step 2: tracked stables != {DOLA, USDC, USDe}");

        // 3. Pauser BEFORE register: PauserV2.register requires pauser() == PauserV2.
        if (booster.pauser() != PAUSER_V2) {
            _begin();
            booster.setPauser(PAUSER_V2);
            _end("3. setPauser(PauserV2)");
            console.log("3. booster.setPauser(PauserV2)");
        } else {
            console.log("3. pauser already PauserV2 - skipped");
        }
        require(booster.pauser() == PAUSER_V2, "step 3: booster.pauser() != PauserV2");

        // 4. Register with PauserV2.
        if (!IPauserV2Booster(PAUSER_V2).isRegistered(b)) {
            _begin();
            IPauserV2Booster(PAUSER_V2).register(b);
            _end("4. PauserV2.register(booster)");
            console.log("4. PauserV2.register(booster)");
        } else {
            console.log("4. already registered with PauserV2 - skipped");
        }
        require(IPauserV2Booster(PAUSER_V2).isRegistered(b), "step 4: booster not registered with PauserV2");

        // 5. Boost FIFTH: enables boosting, only once 1-4 have landed (re-asserted here).
        if (booster.boostBps() != BOOST_BPS) {
            require(_steps1to4Done(), "step 5: steps 1-4 have not all landed - refusing to enable boosting");
            _begin();
            booster.setBoostBps(BOOST_BPS);
            _end("5. setBoostBps(1_500)");
            console.log("5. booster.setBoostBps(1_500) - boosting ENABLED at 15%");
        } else {
            console.log("5. boostBps already 1_500 - skipped");
        }
        require(booster.boostBps() == BOOST_BPS, "step 5: booster boostBps != 1_500");

        // 6. LAST: revoke OWNER's phUSD mint right (single address; NEVER revokeAllMintPrivileges).
        if (_ownerCanMint()) {
            require(
                _steps1to4Done() && booster.boostBps() == BOOST_BPS,
                "step 6: steps 1-5 have not all landed - refusing to revoke OWNER yet"
            );
            _begin();
            IPhUSDBooster(PHUSD).setMinter(OWNER, false);
            _end("6. phUSD.setMinter(OWNER, false)");
            console.log("6. phUSD.setMinter(OWNER, false) - OWNER phUSD mint right REVOKED");
        } else {
            console.log("6. OWNER already not a phUSD minter - skipped");
        }
        require(!_ownerCanMint(), "step 6: OWNER still holds the phUSD mint right");
    }

    function _wiringComplete() internal view returns (bool) {
        return _steps1to4Done() && booster.boostBps() == BOOST_BPS && !_ownerCanMint();
    }

    /// @notice The finished state the verifier also checks (minus the address book, which is patched later).
    function _requireWired(AntimatterBooster b) internal view {
        _checkImmutables(b);
        require(_isLivePhusdMinter(address(b)), "wired: booster is not a live phUSD minter");
        require(b.trackedStables().length == 3, "wired: tracked stable count != 3");
        require(b.isTracked(DOLA) && b.isTracked(USDC) && b.isTracked(USDE), "wired: tracked stable missing");
        require(b.pauser() == PAUSER_V2, "wired: pauser != PauserV2");
        require(IPauserV2Booster(PAUSER_V2).isRegistered(address(b)), "wired: not registered with PauserV2");
        require(b.boostBps() == BOOST_BPS, "wired: boostBps != 1_500");
        require(!b.paused(), "wired: booster is paused");
        require(!_ownerCanMint(), "wired: OWNER still holds the phUSD mint right");
        require(IPhUSDBooster(PHUSD).mintVersion() == 0, "wired: phUSD mintVersion != 0");
        console.log("Wiring OK: live minter, DOLA/USDC/USDe tracked, PauserV2 registered, 15%, OWNER revoked.");
    }

    function _checkImmutables(AntimatterBooster b) internal view {
        require(address(b).code.length > 0, "booster has no code");
        require(b.owner() == OWNER, "booster.owner() != OWNER");
        require(address(b.antimatter()) == ANTIMATTER, "booster.antimatter() != Antimatter");
        require(address(b.phUSD()) == PHUSD, "booster.phUSD() != phUSD");
        require(b.MAX_BOOST_BPS() == MAX_BOOST_BPS, "booster.MAX_BOOST_BPS() != 2_500");
    }

    // ============ Eligibility (active-minter POC; view only) ============

    function _assertEligibility() internal {
        uint256 dolaQ = _minterPoc18(DOLA);
        uint256 usdcQ = _minterPoc18(USDC);
        uint256 usdeQ = _minterPoc18(USDE);
        uint256 total = dolaQ + usdcQ + usdeQ;
        console.log("Active-minter POC (18dp) DOLA / USDC / USDe:", dolaQ, usdcQ, usdeQ);
        console.log("  total / threshold (1/6):", total, total / 6);

        (bool ok, AntimatterBooster.Reason why, uint256 sQ, uint256 tQ, uint256 base, uint256 bonus) =
            booster.previewBoost(USDE, 1e18);
        // The booster's own POC reading must equal ours exactly (deterministic; same reads).
        require(sQ == usdeQ && tQ == total, "eligibility: booster POC != script POC (active minter mismatch?)");
        usdeEligible = ok;
        if (ok) {
            require(why == AntimatterBooster.Reason.None, "eligibility: eligible with a reason");
            require(bonus == base * BOOST_BPS / 10_000, "eligibility: USDe preview bonus is not 15% of base");
            console.log("  previewBoost USDe ELIGIBLE (1 AM -> base, bonus):", base, bonus);
        } else {
            console.log("  WARNING: USDe is NOT boost-eligible at this block (reason code below). The deploy is still");
            console.log(
                "  valid - eligibility is market state - but no stable can be boosted until it re-enters the band."
            );
            console.log("  reason:", uint256(why));
        }
        _expectAboveThreshold(DOLA, "DOLA");
        _expectAboveThreshold(USDC, "USDC");
    }

    function _expectAboveThreshold(address stable, string memory name) internal view {
        (bool ok, AntimatterBooster.Reason why,,,,) = booster.previewBoost(stable, 1e18);
        if (!ok && why == AntimatterBooster.Reason.AboveThreshold) {
            console.log(string.concat("  previewBoost ", name, ": AboveThreshold (ineligible, as planned)"));
        } else {
            console.log(
                string.concat("  WARNING: ", name, " is not AboveThreshold at this block; reason code:"), uint256(why)
            );
        }
    }

    // ============ Preview-only smoke (snapshot-reverted) ============

    function _smoke() internal {
        console.log("\n=== Preview smoke (snapshot-reverted; third-party actor, never OWNER) ===");
        if (!usdeEligible) {
            console.log("  SKIPPED: USDe not eligible at this block (see WARNING above).");
            return;
        }
        uint256 snap = vm.snapshotState();
        address actor = makeAddr("story139-booster-smoke-actor");
        require(actor != OWNER, "smoke actor must never be OWNER");
        (uint256 base, uint256 bonus, uint256 received) = _boostAs(actor, SMOKE_AMOUNT);
        console.log("  boostedAnnihilate(USDe, 10 AM): base / bonus / received:", base, bonus, received);
        require(bonus == base * BOOST_BPS / 10_000, "smoke: bonus != 15% of base");
        require(received == base + bonus, "smoke: actor phUSD delta != base + 15% bonus");
        _assertOwnerBalancesNotIncreased("smoke (before revert)");
        vm.revertToState(snap);
        // Recorded AFTER the revert, which would otherwise roll these storage writes back too.
        smokeBase = base;
        smokeBonus = bonus;
        smokeReceived = received;
        console.log("  smoke OK (reverted)");
    }

    /// @dev Deals `amount` AM and the matching USDe to `actor`, approves, boost-annihilates to itself.
    function _boostAs(address actor, uint256 amount) internal returns (uint256 base, uint256 bonus, uint256 received) {
        (bool ok,,,, uint256 expBase, uint256 expBonus) = booster.previewBoost(USDE, amount);
        require(ok, "smoke: previewBoost(USDe) not eligible");
        deal(ANTIMATTER, actor, amount, false);
        deal(USDE, actor, amount, false); // USDe is 18dp: stable amount == AM amount
        vm.startPrank(actor);
        IERC20(ANTIMATTER).approve(address(booster), amount);
        IERC20(USDE).approve(address(booster), amount);
        uint256 before = IERC20(PHUSD).balanceOf(actor);
        uint256 totalOut = booster.boostedAnnihilate(USDE, actor, amount, expBase + expBonus);
        vm.stopPrank();
        received = IERC20(PHUSD).balanceOf(actor) - before;
        require(totalOut == received, "smoke: returned total != actor phUSD delta");
        require(received == expBase + expBonus, "smoke: received != previewBoost base + bonus");
        base = expBase;
        bonus = expBonus;
    }

    /// @notice V2.pause() by a throwaway EYE holder -> every registrant with a paused() getter (incl. the booster)
    ///         reports paused and boostedAnnihilate reverts -> V2.unpause() as OWNER -> all unpaused, a boost works.
    function _globalPauseRoundTrip() internal {
        console.log("\n=== Preview global PauserV2 pause round-trip incl. booster (snapshot-reverted) ===");
        IPauserV2Booster p = IPauserV2Booster(PAUSER_V2);
        uint256 snap = vm.snapshotState();

        address actor = makeAddr("story139-global-pause-actor");
        uint256 burnAmt = p.eyeBurnAmount();
        address eye = p.eyeToken(); // cached: a view call between vm.prank and the target would consume the prank
        deal(eye, actor, burnAmt, false);
        vm.prank(actor);
        IERC20(eye).approve(PAUSER_V2, burnAmt);
        vm.prank(actor);
        p.pause();

        address[] memory regs = p.getPausableContracts();
        uint256 checked;
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bool isPaused) = _probePaused(regs[i]);
            if (!ok) continue;
            require(isPaused, "pause round-trip: a registrant is NOT paused after V2.pause()");
            checked++;
        }
        require(booster.paused(), "pause round-trip: booster NOT paused after V2.pause()");
        address user = makeAddr("story139-paused-user");
        deal(ANTIMATTER, user, 1e18, false);
        deal(USDE, user, 1e18, false);
        vm.startPrank(user);
        IERC20(ANTIMATTER).approve(address(booster), 1e18);
        IERC20(USDE).approve(address(booster), 1e18);
        try booster.boostedAnnihilate(USDE, user, 1e18, 0) {
            revert("pause round-trip: boostedAnnihilate must revert while paused");
        } catch {}
        vm.stopPrank();

        vm.prank(OWNER);
        p.unpause();
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bool isPaused) = _probePaused(regs[i]);
            if (!ok) continue;
            require(!isPaused, "pause round-trip: a registrant is still paused after V2.unpause()");
        }
        require(!booster.paused(), "pause round-trip: booster still paused after V2.unpause()");
        if (usdeEligible) {
            (,, uint256 received) = _boostAs(user, 1e18);
            require(received > 0, "pause round-trip: boost after unpause paid nothing");
        }
        _assertOwnerBalancesNotIncreased("pause round-trip (before revert)");
        vm.revertToState(snap);
        console.log("  pause round-trip OK; registrants with a paused() getter checked:", checked);
    }

    function _probePaused(address c) internal view returns (bool ok, bool isPaused) {
        (bool success, bytes memory data) = c.staticcall(abi.encodeWithSignature("paused()"));
        if (!success || data.length < 32) return (false, false);
        uint256 w = abi.decode(data, (uint256));
        if (w > 1) return (false, false);
        return (true, w == 1);
    }

    // ============ Preflight ============

    function _preflight() internal view {
        _requireBookMatchesConstants();
        require(
            PHUSD.code.length > 0 && ANTIMATTER.code.length > 0 && PAUSER_V2.code.length > 0
                && PHUSD_STABLE_MINTER.code.length > 0,
            "preflight: a target has no code"
        );
        require(IPhUSDBooster(PHUSD).owner() == OWNER, "preflight: phUSD.owner() != OWNER");
        require(IAntimatterBoosterView(ANTIMATTER).owner() == OWNER, "preflight: Antimatter.owner() != OWNER");
        require(IPauserV2Booster(PAUSER_V2).owner() == OWNER, "preflight: PauserV2.owner() != OWNER");
        require(
            IPhusdStableMinterBooster(PHUSD_STABLE_MINTER).owner() == OWNER,
            "preflight: PhusdStableMinter.owner() != OWNER"
        );
        require(IAntimatterBoosterView(ANTIMATTER).phUSD() == PHUSD, "preflight: Antimatter.phUSD() != phUSD");
        require(
            IAntimatterBoosterView(ANTIMATTER).phUSDMinter() == PHUSD_STABLE_MINTER,
            "preflight: Antimatter.phUSDMinter() != book PhusdStableMinter (V2)"
        );
        require(!IPhusdStableMinterBooster(PHUSD_STABLE_MINTER).paused(), "preflight: active minter is paused");
        _requireStableRegistered(DOLA, YS_DOLA, 18, "DOLA");
        _requireStableRegistered(USDC, YS_USDC, 6, "USDC");
        _requireStableRegistered(USDE, YS_USDE, 18, "USDe");
        require(IPhUSDBooster(PHUSD).mintVersion() == 0, "preflight: phUSD.mintVersion() != 0");
        console.log("Preflight OK: book == pinned; OWNER owns phUSD/Antimatter/minter/PauserV2; active minter == V2.");
    }

    function _requireStableRegistered(address stable, address ys, uint8 dec, string memory name) internal view {
        (address s,, uint8 d, bool enabled,,,) =
            IPhusdStableMinterBooster(PHUSD_STABLE_MINTER).stablecoinConfigs(stable);
        require(s == ys, string.concat("preflight: active minter's ", name, " strategy != book YieldStrategy"));
        require(d == dec, string.concat("preflight: active minter's ", name, " decimals unexpected"));
        require(enabled, string.concat("preflight: ", name, " is disabled on the active minter"));
    }

    // ============ Broadcast plumbing ============

    function _begin() internal virtual {
        txCount++;
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
    }

    /// @dev Ends a transaction and asserts the OWNER balance invariant AFTER EVERY ONE (not just at the end).
    function _end(string memory step) internal {
        _stop();
        _afterTx();
        _assertOwnerBalancesNotIncreased(step);
    }

    function _stop() internal virtual {
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
    }

    /// @dev Test seam (fault injection); a no-op in production.
    function _afterTx() internal virtual {}

    /// @dev `virtual` only so fork tests can stand in for the `--sender`.
    function _sender() internal view virtual returns (address) {
        return msg.sender;
    }

    /// @dev Legacy txs at a fixed `--with-gas-price $ANTIMATTER_BOOSTER_GAS_PRICE_WEI` stall while block.basefee
    ///      exceeds it; require 2x headroom at start (story 128 / audit 49 L-03 pattern).
    function _requireBroadcastGasPriceHeadroom() internal view virtual {
        uint256 gasPriceWei = vm.envOr("ANTIMATTER_BOOSTER_GAS_PRICE_WEI", uint256(0));
        require(gasPriceWei > 0, "ANTIMATTER_BOOSTER_GAS_PRICE_WEI unset or 0");
        console.log("Gas price (wei):", gasPriceWei, " block.basefee (wei):", block.basefee);
        require(
            gasPriceWei >= block.basefee * 2,
            "ANTIMATTER_BOOSTER_GAS_PRICE_WEI < 2 x block.basefee: raise it (runbook: Gas price)"
        );
    }

    // ============ Progress ============

    /// @notice Forge runs this in its LOCAL pass, before the CREATE is signed: record `pending` + the CREATE nonce.
    ///         Written only under ANTIMATTER_BOOSTER_BROADCAST=true (the :broadcast key alone).
    function _recordPendingProgress(address b, uint256 createNonce) internal {
        if (!_progressWriteEnabledFromEnv()) {
            console.log("ANTIMATTER_BOOSTER_BROADCAST unset: dry run, progress file NOT written.");
            return;
        }
        vm.serializeAddress("s139.booster", "address", b);
        vm.serializeUint("s139.booster", "createNonce", createNonce);
        string memory entry = vm.serializeBool("s139.booster", "deployed", false);
        string memory contracts = vm.serializeString("s139.contracts", "AntimatterBooster", entry);
        vm.serializeUint("s139.root", "chainId", CHAIN_ID);
        vm.serializeString("s139.root", "networkName", NETWORK_NAME);
        vm.serializeString("s139.root", "deploymentStatus", "pending");
        string memory json = vm.serializeString("s139.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written (pending until confirmed):", _progressFile());
    }

    /// @notice A recorded booster with no code is a CREATE still pending or one that never landed. OWNER's confirmed
    ///         nonce tells them apart; redeploying while the CREATE may be in the mempool would make two boosters.
    function _requireRecordedBoosterLanded(address recorded) internal view {
        if (recorded.code.length > 0) return;
        string memory json = _progressJson();
        require(
            vm.keyExistsJson(json, ".contracts.AntimatterBooster.createNonce"),
            "Progress file names an AntimatterBooster with NO CODE and records no createNonce: check OWNER's pending nonce by hand"
        );
        uint256 createNonce = vm.parseJsonUint(json, ".contracts.AntimatterBooster.createNonce");
        string memory n = vm.toString(createNonce);
        if (vm.getNonce(OWNER) <= createNonce) {
            revert(
                string.concat(
                    "Progress file names an AntimatterBooster with NO CODE, but OWNER has not consumed its create nonce ",
                    n,
                    ": the deploy tx may be PENDING. Wait, or replace nonce ",
                    n,
                    " at a higher ANTIMATTER_BOOSTER_GAS_PRICE_WEI. Do NOT delete the progress file."
                )
            );
        }
        revert(
            string.concat(
                "Progress file names an AntimatterBooster with NO CODE although OWNER consumed its create nonce ",
                n,
                ": the deploy never landed. Delete ",
                _progressFile(),
                " and re-run preview."
            )
        );
    }

    /// @dev Set only by the :broadcast key. `virtual` so tests can pin it (vm.setEnv is process-wide).
    function _progressWriteEnabledFromEnv() internal view virtual returns (bool) {
        return vm.envOr("ANTIMATTER_BOOSTER_BROADCAST", false);
    }

    /// @dev The ONE reader of PREVIEW_MODE; `virtual` only so fork-test harnesses can pin it.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
