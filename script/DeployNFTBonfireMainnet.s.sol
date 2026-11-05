// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NFTBonfire} from "@yield-claim-nft/NFTBonfire.sol";
import {
    NFTBonfireMainnetBase,
    INFTMinterV2Bonfire,
    IAntimatterBonfire,
    IPauserV2Bonfire
} from "./helpers/NFTBonfireMainnetBase.sol";

/**
 * @title DeployNFTBonfireMainnet  (story 129, sprint nft-bonfire)
 * @notice Deploys yield-claim-nft's `NFTBonfire` (submodule pin c5ad56d; audited in yield-claim-nft run 23, no
 *         High/Medium) to mainnet and wires it in the order audit run 23 L-29 / Q-27 mandates. Mirrors
 *         `script/helpers/NFTBonfireLocalWiring.sol` (the anvil wiring, stories 125/126), with PauserV2 in place of
 *         the retired V1 Pauser:
 *           1. deploy `NFTBonfire(OWNER, NFTMinterV2, Antimatter)` (inert: rate 0, cap 0, pauser 0), or adopt the
 *              one recorded in server/deployments/progress.nft-bonfire.1.json;
 *           2. `NFTMinterV2.setAuthorizedBurner(bonfire, true)`;
 *           3. `Antimatter.setApprovedMinter(bonfire, true)` (SILENT no-op setter: always read back);
 *           4. `bonfire.setPauser(PauserV2)`, THEN `PauserV2.register(bonfire)` (register requires pauser() == V2);
 *           5. `require(ratePerDay() == 0)`, `bonfire.setMaxPayout(100e18)`: the cap goes on BEFORE any rate;
 *           6. `bonfire.setRatePerDay(10e18)` LAST: this is the call that enables burning.
 *         Every step is gated on chain state and read back with a `require`, so a re-run (after a gas stall, an RPC
 *         drop or a Ledger timeout) resumes where the chain stands and a finished run sends nothing.
 *
 *         Configuration safety: see `NFTBonfireMainnetBase` for the provenance of every value (rate, cap, owner).
 *
 *         NO FUNDS TO THE LEDGER (human requirement 2026-11-06). OWNER `0xCad1...D0B6` only pays gas. The script
 *         snapshots OWNER's ETH, Antimatter, phUSD, SYA reward-token (USDC/DOLA/USDe/sUSDe/USDS/sUSDS), EYE and every
 *         NFTMinterV2 ERC1155 balance BEFORE its first call and reverts `OwnerBalanceIncreased` AFTER its last call
 *         if any rose (ETH must be non-increasing). It never calls `antimatter.mint`, and no call names OWNER as a
 *         recipient, beneficiary or minter. Preview runs the same assertion, including inside the smoke.
 *
 *         PREVIEW ONLY (snapshot-reverted, never in a broadcast session): capability probes of the live
 *         NFTMinterV2/Antimatter getters, a burn by a pranked THIRD-PARTY NFT holder (never OWNER) after 1 day
 *         (= 10 AM) and after 30 days (capped at 100 AM), and a global PauserV2 pause round-trip including the
 *         bonfire (burn reverts while paused, works after unpause).
 *
 *         Progress: written `pending` with the CREATE nonce in forge's local pass, only when
 *         NFT_BONFIRE_BROADCAST=true (set by the :broadcast key alone); scripts/confirm-nft-bonfire-progress.js
 *         flips it to `completed` from a success receipt and live code. The address book and PauserV2Registry are
 *         NOT touched here: scripts/patch-mainnet-addresses-nft-bonfire.js does both after the broadcast.
 *
 * Preview:   npm run nft-bonfire:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written)
 * Broadcast: npm run nft-bonfire:broadcast   (the human only, Ledger m/44'/60'/46'/0/0)
 * Verify:    npm run nft-bonfire-verify      (read-only)
 * Runbook:   docs/runbooks/nft-bonfire-mainnet.md
 */
contract DeployNFTBonfireMainnet is NFTBonfireMainnetBase {
    /// @dev Token id of the claim NFT the preview smoke burns (index 4, UniPoolerV2), held by SMOKE_HOLDER.
    uint256 internal constant SMOKE_TOKEN_ID = 4;
    /// @dev A real third-party holder of SMOKE_TOKEN_ID on mainnet (40 units at block 26,351,739; found from the
    ///      minter's TransferSingle logs). NOT OWNER. Pranked in preview only, inside a reverted snapshot. If it no
    ///      longer holds enough units the smoke falls back to a throwaway actor credited with `deal` (logged).
    address internal constant SMOKE_HOLDER = 0x4B75d1CF8A07280249404Bf10aa1B844f0982aBC;
    /// @dev Burns the smoke needs: drain, 1-day, 30-day, plus one each side of the pause round-trip.
    uint256 internal constant SMOKE_UNITS = 5;

    NFTBonfire public bonfire;
    bool public deployedThisRun;
    /// @dev Transactions this run sent (or, in preview, would send). Read by the fork tests.
    uint256 public txCount;
    /// @dev Preview smoke results (read by the fork tests).
    uint256 public smokeOneDayPayout;
    uint256 public smokeThirtyDayPayout;

    bool internal isPreview;

    function run() external {
        console.log("=================================================");
        console.log("  DEPLOY + WIRE NFTBonfire - MAINNET (story 129)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );
        if (!isPreview) require(_sender() == OWNER, "broadcast sender must be OWNER (--sender + Ledger)");

        _preflight();
        _snapshotOwnerBalances();

        // ---- 1. Deploy, or adopt from the progress file ----
        address recorded = _progressBonfire();
        address booked = _bookBonfire();
        if (recorded != address(0)) {
            require(booked == address(0) || booked == recorded, "address book NFTBonfire != progress file NFTBonfire");
            _requireRecordedBonfireLanded(recorded);
            bonfire = NFTBonfire(recorded);
            _checkImmutables(bonfire);
            console.log("1. NFTBonfire adopted from progress file:", recorded);
        } else {
            require(
                booked == address(0),
                "address book names an NFTBonfire but there is no progress file - restore progress.nft-bonfire.1.json"
            );
            if (!isPreview) _requireBroadcastGasPriceHeadroom();
            uint256 createNonce = vm.getNonce(OWNER);
            _begin();
            bonfire = new NFTBonfire(OWNER, NFT_MINTER, ANTIMATTER);
            _end();
            deployedThisRun = true;
            _checkImmutables(bonfire);
            require(bonfire.ratePerDay() == 0, "fresh bonfire must deploy inert (rate)");
            require(bonfire.maxPayout() == 0, "fresh bonfire must deploy inert (cap)");
            require(bonfire.pauser() == address(0), "fresh bonfire must deploy inert (pauser)");
            console.log("1. NFTBonfire deployed:", address(bonfire));
            if (!isPreview) _recordPendingProgress(address(bonfire), createNonce);
        }

        if (!isPreview && !deployedThisRun && !_wiringComplete()) _requireBroadcastGasPriceHeadroom();
        _wire();
        _requireWired(bonfire);

        if (isPreview) {
            _assertOwnerBalancesNotIncreased("after wiring (preview)");
            _smoke();
            _globalPauseRoundTrip();
        }
        _assertOwnerBalancesNotIncreased("final");

        console.log("Transactions sent (or simulated):", txCount);
        if (txCount == 0) console.log("Nothing to do: bonfire fully wired, no transaction sent (idempotent).");
        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (a preview CREATE address is fork-local)."
            );
        } else {
            console.log("Next (chained by :broadcast): confirm progress, patch book + PauserV2Registry, verify.");
        }
    }

    // ============ Wiring (audit yield-claim-nft run 23, L-29 / Q-27) ============

    function _wire() internal {
        address b = address(bonfire);

        // 2. Burner grant. NFTMinterV2 checks no holder approval; the bonfire always burns from msg.sender.
        if (!INFTMinterV2Bonfire(NFT_MINTER).authorizedBurners(b)) {
            _begin();
            INFTMinterV2Bonfire(NFT_MINTER).setAuthorizedBurner(b, true);
            _end();
            console.log("2. NFTMinterV2.setAuthorizedBurner(bonfire, true)");
        } else {
            console.log("2. already an NFTMinterV2 burner - skipped");
        }
        require(INFTMinterV2Bonfire(NFT_MINTER).authorizedBurners(b), "step 2: bonfire is not an NFTMinterV2 burner");

        // 3. Minter grant. SILENT no-op on an unchanged value: always read back.
        if (!IAntimatterBonfire(ANTIMATTER).isApprovedMinter(b)) {
            _begin();
            IAntimatterBonfire(ANTIMATTER).setApprovedMinter(b, true);
            _end();
            console.log("3. Antimatter.setApprovedMinter(bonfire, true)");
        } else {
            console.log("3. already an approved Antimatter minter - skipped");
        }
        require(IAntimatterBonfire(ANTIMATTER).isApprovedMinter(b), "step 3: bonfire is not an approved AM minter");

        // 4. Pauser BEFORE register: PauserV2.register requires pauser() == PauserV2.
        if (bonfire.pauser() != PAUSER_V2) {
            _begin();
            bonfire.setPauser(PAUSER_V2);
            _end();
            console.log("4a. bonfire.setPauser(PauserV2)");
        } else {
            console.log("4a. pauser already PauserV2 - skipped");
        }
        require(bonfire.pauser() == PAUSER_V2, "step 4: bonfire.pauser() != PauserV2");
        if (!IPauserV2Bonfire(PAUSER_V2).isRegistered(b)) {
            _begin();
            IPauserV2Bonfire(PAUSER_V2).register(b);
            _end();
            console.log("4b. PauserV2.register(bonfire)");
        } else {
            console.log("4b. already registered with PauserV2 - skipped");
        }
        require(IPauserV2Bonfire(PAUSER_V2).isRegistered(b), "step 4: bonfire not registered with PauserV2");

        // 5. Cap BEFORE any non-zero rate: maxPayout == 0 means UNLIMITED.
        if (bonfire.maxPayout() != MAX_PAYOUT) {
            require(
                bonfire.ratePerDay() == 0,
                "step 5: ratePerDay is already non-zero while the cap is unset - refusing (stop burns with setRatePerDay(0) first; runbook)"
            );
            _begin();
            bonfire.setMaxPayout(MAX_PAYOUT);
            _end();
            console.log("5. bonfire.setMaxPayout(100e18)");
        } else {
            console.log("5. maxPayout already 100e18 - skipped");
        }
        require(bonfire.maxPayout() == MAX_PAYOUT, "step 5: bonfire maxPayout != 100e18");

        // 6. Rate LAST: enables burning. Only after steps 2-5 have landed (re-asserted here).
        if (bonfire.ratePerDay() != RATE_PER_DAY) {
            require(
                INFTMinterV2Bonfire(NFT_MINTER).authorizedBurners(b)
                    && IAntimatterBonfire(ANTIMATTER).isApprovedMinter(b) && bonfire.pauser() == PAUSER_V2
                    && IPauserV2Bonfire(PAUSER_V2).isRegistered(b) && bonfire.maxPayout() == MAX_PAYOUT,
                "step 6: steps 2-5 have not all landed - refusing to enable burning"
            );
            _begin();
            bonfire.setRatePerDay(RATE_PER_DAY);
            _end();
            console.log("6. bonfire.setRatePerDay(10e18) - burning ENABLED");
        } else {
            console.log("6. ratePerDay already 10e18 - skipped");
        }
        require(bonfire.ratePerDay() == RATE_PER_DAY, "step 6: bonfire ratePerDay != 10e18");
    }

    function _wiringComplete() internal view returns (bool) {
        address b = address(bonfire);
        return INFTMinterV2Bonfire(NFT_MINTER).authorizedBurners(b)
            && IAntimatterBonfire(ANTIMATTER).isApprovedMinter(b) && bonfire.pauser() == PAUSER_V2
            && IPauserV2Bonfire(PAUSER_V2).isRegistered(b) && bonfire.maxPayout() == MAX_PAYOUT
            && bonfire.ratePerDay() == RATE_PER_DAY;
    }

    /// @notice The finished state the verifier also checks (minus the address book, which is patched later).
    function _requireWired(NFTBonfire b) internal view {
        _checkImmutables(b);
        require(b.ratePerDay() == RATE_PER_DAY, "wired: ratePerDay != 10e18");
        require(b.maxPayout() == MAX_PAYOUT, "wired: maxPayout != 100e18");
        require(b.pauser() == PAUSER_V2, "wired: pauser != PauserV2");
        require(IPauserV2Bonfire(PAUSER_V2).isRegistered(address(b)), "wired: not registered with PauserV2");
        require(!b.paused(), "wired: bonfire is paused (pauser-v2-verify health() would fail)");
        require(INFTMinterV2Bonfire(NFT_MINTER).authorizedBurners(address(b)), "wired: not an NFTMinterV2 burner");
        require(IAntimatterBonfire(ANTIMATTER).isApprovedMinter(address(b)), "wired: not an approved AM minter");
        console.log("Wiring OK: burner, AM minter, PauserV2 registered, cap 100e18, rate 10e18, not paused.");
    }

    function _checkImmutables(NFTBonfire b) internal view {
        require(address(b).code.length > 0, "bonfire has no code");
        require(b.owner() == OWNER, "bonfire.owner() != OWNER");
        require(address(b.nftMinter()) == NFT_MINTER, "bonfire.nftMinter() != NFTMinterV2");
        require(address(b.antimatter()) == ANTIMATTER, "bonfire.antimatter() != Antimatter");
    }

    // ============ Preflight ============

    function _preflight() internal view {
        _requireBookMatchesConstants();
        require(NFT_MINTER.code.length > 0 && ANTIMATTER.code.length > 0 && PAUSER_V2.code.length > 0, "no code");
        require(INFTMinterV2Bonfire(NFT_MINTER).owner() == OWNER, "NFTMinterV2.owner() != OWNER");
        require(IAntimatterBonfire(ANTIMATTER).owner() == OWNER, "Antimatter.owner() != OWNER");
        require(IPauserV2Bonfire(PAUSER_V2).owner() == OWNER, "PauserV2.owner() != OWNER");
        // NFTMinterV2's own pauser (expected PauserV2 after the story 128 rotation) is not asserted here; Bonfire wiring does not depend on it.
        console.log("Preflight OK: book == pinned NFTMinterV2 / Antimatter / PauserV2; OWNER owns all three.");
    }

    // ============ Preview-only smoke (snapshot-reverted) ============

    /// @dev Never runs in a broadcast session (deal / prank / warp / snapshot). Uses a third-party holder only.
    function _smokeHolder() internal returns (address holder) {
        holder = SMOKE_HOLDER;
        if (INFTMinterV2Bonfire(NFT_MINTER).balanceOf(holder, SMOKE_TOKEN_ID) < SMOKE_UNITS) {
            holder = makeAddr("story129-bonfire-smoke-holder");
            dealERC1155(NFT_MINTER, holder, SMOKE_TOKEN_ID, SMOKE_UNITS, false);
            console.log("  SMOKE_HOLDER holds too few units; using a throwaway actor credited by deal:", holder);
        }
        require(holder != OWNER, "smoke holder must never be OWNER");
        require(
            INFTMinterV2Bonfire(NFT_MINTER).balanceOf(holder, SMOKE_TOKEN_ID) >= SMOKE_UNITS,
            "smoke: holder has too few NFTs"
        );
    }

    function _burnAs(address holder) internal returns (uint256 payout) {
        uint256 amBefore = IAntimatterBonfire(ANTIMATTER).balanceOf(holder);
        uint256 nftBefore = INFTMinterV2Bonfire(NFT_MINTER).balanceOf(holder, SMOKE_TOKEN_ID);
        vm.prank(holder);
        payout = bonfire.burn(SMOKE_TOKEN_ID, 0);
        require(
            IAntimatterBonfire(ANTIMATTER).balanceOf(holder) - amBefore == payout, "smoke: AM delta != reported payout"
        );
        require(
            INFTMinterV2Bonfire(NFT_MINTER).balanceOf(holder, SMOKE_TOKEN_ID) == nftBefore - 1,
            "smoke: exactly one NFT unit must burn"
        );
    }

    function _smoke() internal {
        console.log("\n=== Preview smoke (snapshot-reverted; third-party holder, never OWNER) ===");
        // Capability probes: the live minter / AM were deployed from older submodule commits.
        (bool ok1,) = NFT_MINTER.staticcall(abi.encodeWithSignature("authorizedBurners(address)", address(bonfire)));
        (bool ok2,) = ANTIMATTER.staticcall(abi.encodeWithSignature("isApprovedMinter(address)", address(bonfire)));
        require(ok1 && ok2, "smoke: live NFTMinterV2.authorizedBurners / Antimatter.isApprovedMinter probe failed");
        console.log("  probes OK: NFTMinterV2.authorizedBurners, Antimatter.isApprovedMinter");

        uint256 snap = vm.snapshotState();
        address holder = _smokeHolder();
        console.log("  holder:", holder);

        _burnAs(holder); // drain whatever pot exists, so the next burn measures exactly 1 day
        vm.warp(block.timestamp + 1 days);
        uint256 oneDay = _burnAs(holder);
        console.log("  1-day burn payout (wei):", oneDay);
        require(oneDay == RATE_PER_DAY, "smoke: 1-day burn must pay exactly 10e18 AM");

        vm.warp(block.timestamp + 30 days);
        uint256 thirtyDays = _burnAs(holder);
        console.log("  30-day burn payout (wei):", thirtyDays);
        require(thirtyDays == MAX_PAYOUT, "smoke: 30-day burn must be capped at 100e18 AM");

        _assertOwnerBalancesNotIncreased("smoke (before revert)");
        vm.revertToState(snap);
        // Recorded AFTER the revert, which would otherwise roll these storage writes back too.
        smokeOneDayPayout = oneDay;
        smokeThirtyDayPayout = thirtyDays;
        console.log("  smoke OK (reverted)");
    }

    /// @notice V2.pause() by a throwaway EYE holder -> every registrant with a paused() getter (incl. the bonfire)
    ///         reports paused and a bonfire burn reverts -> V2.unpause() as OWNER -> all unpaused and a burn works.
    function _globalPauseRoundTrip() internal {
        console.log("\n=== Preview global PauserV2 pause round-trip incl. bonfire (snapshot-reverted) ===");
        IPauserV2Bonfire p = IPauserV2Bonfire(PAUSER_V2);
        uint256 snap = vm.snapshotState();
        address holder = _smokeHolder();
        vm.warp(block.timestamp + 1 days);

        address actor = makeAddr("story129-global-pause-actor");
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
        require(bonfire.paused(), "pause round-trip: bonfire NOT paused after V2.pause()");
        vm.prank(holder);
        try bonfire.burn(SMOKE_TOKEN_ID, 0) {
            revert("pause round-trip: burn must revert while paused");
        } catch {}

        vm.prank(OWNER);
        p.unpause();
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bool isPaused) = _probePaused(regs[i]);
            if (!ok) continue;
            require(!isPaused, "pause round-trip: a registrant is still paused after V2.unpause()");
        }
        uint256 payout = _burnAs(holder);
        require(payout > 0, "pause round-trip: burn after unpause paid nothing");
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

    // ============ Broadcast plumbing ============

    function _begin() internal virtual {
        txCount++;
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
    }

    function _end() internal virtual {
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
    }

    /// @dev `virtual` only so fork tests can stand in for the `--sender` (the test contract is msg.sender there).
    function _sender() internal view virtual returns (address) {
        return msg.sender;
    }

    /// @dev Legacy txs at a fixed `--with-gas-price $NFT_BONFIRE_GAS_PRICE_WEI` stall while block.basefee exceeds it;
    ///      require 2x headroom at start (story 128 / audit 49 L-03 pattern). `tx.gasprice` does not reflect
    ///      --with-gas-price inside a forge script, so the env var is the source.
    function _requireBroadcastGasPriceHeadroom() internal view virtual {
        uint256 gasPriceWei = vm.envOr("NFT_BONFIRE_GAS_PRICE_WEI", uint256(0));
        require(gasPriceWei > 0, "NFT_BONFIRE_GAS_PRICE_WEI unset or 0");
        console.log("Gas price (wei):", gasPriceWei, " block.basefee (wei):", block.basefee);
        require(
            gasPriceWei >= block.basefee * 2,
            "NFT_BONFIRE_GAS_PRICE_WEI < 2 x block.basefee: raise it (runbook: Gas price)"
        );
    }

    // ============ Progress ============

    /// @notice Forge runs this in its LOCAL pass, before the CREATE is signed: record `pending` + the CREATE nonce.
    ///         `scripts/confirm-nft-bonfire-progress.js` flips it to `completed`. Written only under
    ///         NFT_BONFIRE_BROADCAST=true (the :broadcast key alone), so a dry run never creates the file.
    function _recordPendingProgress(address b, uint256 createNonce) internal {
        if (!_progressWriteEnabledFromEnv()) {
            console.log("NFT_BONFIRE_BROADCAST unset: dry run, progress file NOT written.");
            return;
        }
        vm.serializeAddress("s129.bonfire", "address", b);
        vm.serializeUint("s129.bonfire", "createNonce", createNonce);
        string memory entry = vm.serializeBool("s129.bonfire", "deployed", false);
        string memory contracts = vm.serializeString("s129.contracts", "NFTBonfire", entry);
        vm.serializeUint("s129.root", "chainId", CHAIN_ID);
        vm.serializeString("s129.root", "networkName", NETWORK_NAME);
        vm.serializeString("s129.root", "deploymentStatus", "pending");
        string memory json = vm.serializeString("s129.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written (pending until confirmed):", _progressFile());
    }

    /// @notice A recorded bonfire with no code is a CREATE still pending or one that never landed. OWNER's confirmed
    ///         nonce tells them apart; redeploying while the CREATE may be in the mempool would make two bonfires.
    function _requireRecordedBonfireLanded(address recorded) internal view {
        if (recorded.code.length > 0) return;
        string memory json = _progressJson();
        require(
            vm.keyExistsJson(json, ".contracts.NFTBonfire.createNonce"),
            "Progress file names an NFTBonfire with NO CODE and records no createNonce: check OWNER's pending nonce by hand"
        );
        uint256 createNonce = vm.parseJsonUint(json, ".contracts.NFTBonfire.createNonce");
        string memory n = vm.toString(createNonce);
        if (vm.getNonce(OWNER) <= createNonce) {
            revert(
                string.concat(
                    "Progress file names an NFTBonfire with NO CODE, but OWNER has not consumed its create nonce ",
                    n,
                    ": the deploy tx may be PENDING. Wait, or replace nonce ",
                    n,
                    " at a higher NFT_BONFIRE_GAS_PRICE_WEI. Do NOT delete the progress file."
                )
            );
        }
        revert(
            string.concat(
                "Progress file names an NFTBonfire with NO CODE although OWNER consumed its create nonce ",
                n,
                ": the deploy never landed. Delete ",
                _progressFile(),
                " and re-run preview."
            )
        );
    }

    /// @dev Set only by the :broadcast key. `virtual` so tests can pin it (vm.setEnv is process-wide).
    function _progressWriteEnabledFromEnv() internal view virtual returns (bool) {
        return vm.envOr("NFT_BONFIRE_BROADCAST", false);
    }

    /// @dev The ONE reader of PREVIEW_MODE; `virtual` only so fork-test harnesses can pin it.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
