// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "@forge-std/Vm.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {ISkyPSM} from "nft-staking/interfaces/ISkyPSM.sol";
import {IMintDebtRatio} from "nft-staking/interfaces/IMintDebtRatio.sol";
import {
    NudgeDiscountMainnetBase,
    INFTMinterV2ND,
    IOldBatchMinterND,
    IPauserV2ND,
    INudgeStreamerND,
    IMintDebtHookND,
    INFTStakerND,
    IOwnableND,
    IUniV2RouterND,
    IUniV2FactoryND,
    IUniV2PairND,
    ISkyPSMND,
    IUniPoolerV2ND,
    IDonorBatchMinterND,
    IDonorRecipientND,
    IDonorNudgeND
} from "./helpers/NudgeDiscountMainnetBase.sol";

/**
 * @title DeployMainnetNudgeDiscount  (story 119, sprint nudge-discount)
 * @notice MAINNET cutover from the live `BatchNFTMinterMultiToken` (`0x0683...15c7`, book key `BatchNFTMinter`) to
 *         nft-staking 033-035's `BatchNFTMinterNudgeDiscount` (submodule pin d7eb782, set by phStaging2:118; new book
 *         key `NudgeDiscountBatchMinter`). The pot no longer pays a winner-take-all USDC nudge: it sets a capped,
 *         discrete discount batch and is reserved for a deferred `buyAndBurn` (see `NudgeDiscountBuyAndBurn.s.sol`).
 *
 * PHASES (every step is gated on CHAIN STATE and read back with a `require`, so a re-run after a gas stall, an RPC
 * drop or a Ledger timeout resumes where the chain stands, and a finished run sends nothing):
 *   0. Preflight, view only: book == pinned constants; NFTMinter configs(4) == UniPooler with prime token USDS;
 *      NFTMinter.owner() == OWNER (the `setAuthorizedMinter` grant is onlyOwner - a different owner fails HERE, with
 *      the actual owner printed, not halfway through Phase 2); authorizedMinters(old) == false; hook ratio 50 and
 *      recipient NFTStaker; NFTStaker reward token phUSD; router factory pair == PhusdSusdsPair with non-zero
 *      reserves; every touched contract owned by OWNER; Pauser == PauserV2 with a clean health(); old minter on
 *      PauserV2, registered and unpaused (or a resumable partial Phase 1); PSM tin == 0; UniPoolerV2
 *      batchDonationSize logged (never changed: gate g); the new-minter book entry is zero or equals the progress
 *      file; write-once baseline (old balances + stream buffers); the on-chain donor inventory; the ETH budget.
 *   1. Freeze the old minter FIRST (the whale must not claim the old pot mid-session): PauserV2.unregister(old) ->
 *      old.setPauser(OWNER) -> old.pause(). NO DEAD WINDOW: PauserV2.unregister is unconditional and PauserV2.pause()
 *      skips registrants that are not on it or already paused, so no intermediate state can make the global pause
 *      revert. Preview proves PauserV2.pause() succeeds after this phase (GLOBAL_PAUSE|after-phase1).
 *   2. Deploy (or adopt from the progress file) and configure, in the pinned contract's revert order: tokenMinter,
 *      index 4; whitelist USDC, phUSD, Kendu (before setDiscountToken, which needs a whitelisted token); discount
 *      USDC / 50%, burn 100%, NFTStaker, mint-debt hook, PSM, sUSDS, then setSwapRoute (validates the pair against
 *      sUSDS); OWNER as authorised buyer; the cap/boost gate constants + require(boostDonationSafe()); setPauser
 *      (PauserV2) THEN PauserV2.register (register requires pauser() == PauserV2); streams USDC 10d / phUSD 30d /
 *      Kendu 30d; setNudgeStreamer; and LAST NFTMinter.setAuthorizedMinter(new, true) - after the pause wiring (the
 *      minter's own pause is the only kill switch for free mints: mintFor ignores the NFTMinter pause) and before
 *      any donor is repointed (the first donation must never reach a minter that cannot mint).
 *      COVERAGE GAP: between `setPauser(PauserV2)` and `PauserV2.register(new)` the new minter is not covered by
 *      the global pause for one transaction. It cannot break the global pause (unregistered contracts are ignored)
 *      and nothing is batchable yet (no streams, no pot). Remedy if interrupted there: re-run; the register step is
 *      gated and lands next.
 *   3. Repoint every inventoried donor (UniPoolerV2/NudgeRatchet `setBatchMinter`, Uniboost `setRecipient`, SYA
 *      `setNudgeAddress`), then require that NO inventoried contract still targets the old minter.
 *   4. Migrate the old pot, never as a direct transfer onto a batch minter:
 *      a. stream buffers still on NudgeStreamer for the old minter: `registerStream(old, token, 1)` settles accrued
 *         at the old rate and sets rate = buffer/1s; in a LATER block a second `registerStream(old, token, 1)`
 *         settles the whole remaining buffer to the old minter (`_accrued = min(rate * elapsed, buffer)`).
 *         The block gap is real on mainnet under `--slow` (each tx waits for the previous receipt). Forge computes
 *         every call argument in its LOCAL pass, at one fork block, so the script models that gap there with
 *         `vm.warp` + `vm.roll` (in PREVIEW and in the broadcast's local pass alike: without it the local pass would
 *         rescue only the pre-settle balance). No transaction carries a timestamp, so the warp changes nothing that
 *         is signed. Fork evidence: `test/DeployMainnetNudgeDiscount.fork.t.sol`. This relies on mainnet's strictly
 *         increasing slot timestamps; an anvil rehearsal must mine with `--block-time` (automine reuses one
 *         timestamp, the second release settles nothing and the rescue reverts). That failure is safe: the
 *         rescue reverts before any value moves and a re-run finishes Phase 4 from chain state (rehearsed).
 *      b. balances held by the old minter: `old.rescueERC20(token, OWNER, bal)` then `forceApprove(streamer, bal)` +
 *         `collectNudge(new, token, bal)` from OWNER. OWNER is a TRANSIT only: its balance is asserted back to the
 *         pre-rescue value after each token, and the end-of-run OWNER balance invariant must hold.
 *      Late donations that land on chain between the local pass and the repoint stay on the old minter / its
 *      stream (the amounts were fixed in the local pass); the verifier names them and a re-run sweeps them.
 *   5. PREVIEW ONLY, snapshot-reverted (never in a broadcast session): an uncapped discounted 6-arg batchMint, a
 *      capped batch funded through the stream (collectNudge + warp, never a direct transfer), buyAndBurn as OWNER
 *      with a 1% route-quote floor, and PauserV2.pause() pausing the new minter; then the GLOBAL_PAUSE|SUCCEEDED
 *      sweep.
 *
 * RESUME. State-gated: re-run `:broadcast`. If a run died mid-flight, trim nothing - the chain is the source of
 * truth for every step. The progress file only pins the deployed address (with its CREATE nonce) and the write-once
 * baseline; if it names an address with no code, the script compares OWNER's nonce with the recorded CREATE nonce
 * (`cast nonce`, `broadcast/DeployMainnetNudgeDiscount.s.sol/1/run-latest.json`) and refuses to redeploy while the
 * CREATE may still be pending.
 *
 * MANUAL phUSD / Kendu TOP-UP (no donor contract; 30-day streams): from OWNER,
 *   `IERC20(token).forceApprove(NudgeStreamer, amt)` then `NudgeStreamer.collectNudge(newMinter, token, amt)`.
 *   Never transfer straight onto the minter: a raw balance is standing bonus the next batcher takes whole.
 *
 * RETIREMENT of the new minter (later): `newMinter.setPauser(OWNER)`, `PauserV2.unregister(newMinter)` (record it in
 *   PauserV2Registry.postMigrationRemovals()), `newMinter.pause()`; then `NFTMinter.setAuthorizedMinter(newMinter,
 *   false)` (revoke the free-mint power) and `newMinter.incrementAuthVersion()` (no buyer can still `buyAndBurn`).
 *
 * RESERVED USDC. The reserve (`pendingBuyUSDC`) and the live pot share one USDC balance; the pinned source's
 *   `rescueERC20` refuses to take more than `balance - pendingBuyUSDC` (`Rescue__ReservedFunds`), so reserved USDC
 *   leaves only via `buyAndBurn`.
 *
 * Progress: `server/deployments/progress.nudge-discount.1.json` (address, CREATE nonce, write-once baseline and
 * `configSteps`: the steps each run's LOCAL PASS emitted - an audit trail, not proof of landing; the chain is the
 * source of truth for every step), written ONLY under NUDGE_DISCOUNT_BROADCAST=true
 * (set by the :broadcast key alone), as `pending` with the CREATE nonce; scripts/confirm-nudge-discount-progress.js
 * flips it to `completed` from a success receipt and live code. The address book and PauserV2Registry are NOT
 * touched here: scripts/patch-mainnet-addresses-nudge-discount.js does both after the broadcast.
 *
 * Preview:   npm run nudge-discount:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written)
 * Broadcast: npm run nudge-discount:broadcast   (the human only, Ledger m/44'/60'/46'/0/0)
 * Verify:    npm run nudge-discount:verify      (read-only)
 */
contract DeployMainnetNudgeDiscount is NudgeDiscountMainnetBase {
    /// @dev Gas budget of a fresh run. Measured on an anvil mainnet-fork rehearsal (2026-11-13): 39 txs, ~6.3M gas
    ///      in total (the CREATE ~4.22M). 9M leaves ~40% for a resume and price drift; `_requiredOwnerEth` adds 20%.
    uint256 internal constant CUTOVER_GAS_BUDGET = 9_000_000;
    uint256 internal constant PREVIEW_DEFAULT_GAS_PRICE_WEI = 300_000_000;
    /// @dev Seconds the local pass advances between the two `registerStream(old, token, 1)` calls (one slot).
    uint256 internal constant BLOCK_GAP_SECS = 12;

    BatchNFTMinterNudgeDiscount public minter;
    bool public deployedThisRun;
    /// @dev Transactions this run sent (or, in preview, would send). Read by the fork tests.
    uint256 public txCount;
    /// @dev Total moved out of the old minter (balance + buffer) per nudge token this run [USDC, phUSD, Kendu].
    uint256[3] public movedThisRun;
    /// @dev Preview smoke results (read by the fork tests).
    uint256 public smokeUncappedFree;
    uint256 public smokeCappedFree;
    uint8 public smokeCappedBoost;
    uint256 public smokeBuyPhusdOut;
    uint256 public smokeBuyBurned;
    bool public smokeRan;

    bool internal isPreview;
    string[] internal stepsSent;
    string[] internal priorSteps;

    struct Baseline {
        uint256 blockNumber;
        uint256[3] balance;
        uint256[3] buffer;
        bool fromProgress;
    }

    Baseline internal baseline;

    function run() external {
        console.log("=================================================");
        console.log("  NUDGE-DISCOUNT MINTER CUTOVER - MAINNET (story 119)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );
        if (!isPreview) require(_sender() == OWNER, "broadcast sender must be OWNER (--sender + Ledger)");
        _requireGateConstants();

        // ---- resolve the new minter: adopt from progress, or refuse a book entry with no progress ----
        address recorded = _progressMinter();
        address booked = _bookNewMinter();
        if (recorded != address(0)) {
            require(
                booked == address(0) || booked == recorded,
                "address book NudgeDiscountBatchMinter != progress file NudgeDiscountBatchMinter"
            );
            _requireRecordedMinterLanded(recorded);
            minter = BatchNFTMinterNudgeDiscount(recorded);
            _loadPriorSteps();
            console.log("New minter adopted from progress file:", recorded);
        } else {
            require(
                booked == address(0),
                "address book names a NudgeDiscountBatchMinter but there is no progress file - refusing a double deployment (restore progress.nudge-discount.1.json)"
            );
        }

        _phase0_preflight();
        _snapshotOwnerBalances();
        if (isPreview) _logOwnerEthBudget();
        else _requireBroadcastBudget();

        _phase1_freezeOldMinter();
        _phase2_deployAndConfigure();
        if (_haltAfterPhase2()) {
            console.log("HALT after Phase 2 (test harness only).");
            return;
        }
        _phase3_repointDonors();
        _phase4_migratePot();

        _requireCutoverState(minter);
        _requirePotMigrated();

        if (isPreview) {
            _assertOwnerBalancesNotIncreased("after cutover (preview)");
            _phase5_smoke();
            _finalGlobalPauseSweep();
        }
        _assertOwnerBalancesNotIncreased("final");
        if (!isPreview) _writeProgress();

        console.log("Transactions sent (or simulated):", txCount);
        if (txCount == 0) console.log("Nothing to do: cutover complete, no transaction sent (idempotent).");
        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (a preview CREATE address is fork-local)."
            );
        } else {
            console.log("Next (chained by :broadcast): confirm progress, patch book + PauserV2Registry, verify.");
        }
    }

    // =====================================================================
    // Phase 0 - preflight (view only) + baseline + inventory
    // =====================================================================

    function _phase0_preflight() internal {
        console.log("\n=== Phase 0: preflight ===");
        _requireBookMatchesConstants();

        INFTMinterV2ND nm = INFTMinterV2ND(NFT_MINTER);
        address nmOwner = nm.owner();
        if (nmOwner != OWNER) {
            console.log("NFTMinter.owner() is NOT OWNER:", nmOwner);
            revert(
                string.concat(
                    "preflight: NFTMinter.owner() != OWNER (actual ",
                    vm.toString(nmOwner),
                    ") - setAuthorizedMinter is onlyOwner; the cutover cannot be one Ledger session (blocker, see story Concern 2)"
                )
            );
        }
        (address d4,,,) = nm.configs(DISPATCHER_INDEX);
        require(d4 == UNI_POOLER, "preflight: NFTMinter configs(4).dispatcher != UniPooler");
        (bool ok, bytes memory data) = d4.staticcall(abi.encodeWithSignature("primeToken()"));
        require(ok && abi.decode(data, (address)) == USDS, "preflight: index-4 prime token is not USDS");
        bool oldAuth = nm.authorizedMinters(OLD_MINTER);
        console.log("AUTHORIZED_MINTER|old", oldAuth ? "true" : "false");
        require(!oldAuth, "preflight: the old minter has mintFor rights - nothing in this cutover revokes them");

        uint8 ratio = IMintDebtHookND(MINT_DEBT_HOOK).ratio();
        console.log("HOOK_RATIO|", ratio);
        require(
            ratio == HOOK_RATIO || vm.envOr("NUDGE_DISCOUNT_ACCEPT_HOOK_RATIO", false), "preflight: hook.ratio() != 50"
        );
        require(IMintDebtHookND(MINT_DEBT_HOOK).recipient() == NFT_STAKER, "preflight: hook.recipient() != NFTStaker");
        require(INFTStakerND(NFT_STAKER).rewardToken() == PHUSD, "preflight: NFTStaker reward token != phUSD");

        require(
            IUniV2FactoryND(IUniV2RouterND(UNI_ROUTER).factory()).getPair(SUSDS, PHUSD) == PAIR,
            "preflight: factory pair != PhusdSusdsPair"
        );
        (uint112 r0, uint112 r1,) = IUniV2PairND(PAIR).getReserves();
        require(r0 > 0 && r1 > 0, "preflight: PhusdSusdsPair has an empty reserve");

        require(IOwnableND(NUDGE_STREAMER).owner() == OWNER, "preflight: NudgeStreamer.owner() != OWNER");
        require(IOwnableND(UNI_POOLER).owner() == OWNER, "preflight: UniPooler.owner() != OWNER");
        require(IOwnableND(OLD_MINTER).owner() == OWNER, "preflight: old minter owner() != OWNER");
        require(IPauserV2ND(PAUSER_V2).owner() == OWNER, "preflight: PauserV2.owner() != OWNER");
        require(PAUSER_V2.code.length > 0, "preflight: PauserV2 has no code");

        // Old minter: the state master predicts (128 migrated it onto PauserV2) or a resumable partial Phase 1.
        IOldBatchMinterND old = IOldBatchMinterND(OLD_MINTER);
        address oldPauser = old.pauser();
        bool reg = IPauserV2ND(PAUSER_V2).isRegistered(OLD_MINTER);
        bool oldPaused = old.paused();
        console.log("OLD_MINTER|pauser", oldPauser);
        console.log("OLD_MINTER|registeredOnPauserV2", reg ? "true" : "false");
        console.log("OLD_MINTER|paused", oldPaused ? "true" : "false");
        require(
            oldPauser != PAUSER_V1,
            "preflight: old minter pauser() is the RETIRED V1 Pauser - contradicts 128's migration record; stop"
        );
        require(
            oldPauser == PAUSER_V2 || oldPauser == OWNER, "preflight: old minter pauser() is neither PauserV2 nor OWNER"
        );
        if (oldPauser == PAUSER_V2 && reg && !oldPaused) {
            console.log("OLD_MINTER|state: live on PauserV2 (fresh cutover)");
        } else {
            console.log("OLD_MINTER|state: partial or finished Phase 1 (resume)");
        }
        _requirePauserHealthClean("preflight");

        uint256 tin = ISkyPSMND(PSM).tin();
        console.log("PSM_TIN|", tin);
        require(tin == 0 || vm.envOr("NUDGE_DISCOUNT_ACCEPT_PSM_TIN", false), "preflight: PSM tin != 0");
        require(ISkyPSMND(PSM).gem() == USDC && ISkyPSMND(PSM).usds() == USDS, "preflight: PSM gem/usds mismatch");
        require(IERC4626(SUSDS).asset() == USDS, "preflight: sUSDS asset != USDS");

        console.log("DONATION_SIZE|", IUniPoolerV2ND(UNI_POOLER).batchDonationSize());

        (, uint256 p0, uint256 g,) = nm.configs(DISPATCHER_INDEX);
        console.log("P0|", p0);
        console.log("GROWTH_BPS|", g);

        _takeBaseline();

        Donor[] memory donors = _donorInventory(OLD_MINTER);
        _printInventory("DONOR", donors);
        for (uint256 i = 0; i < donors.length; i++) {
            _requireRecipientIsNudgeTarget(donors[i]);
            if (donors[i].kind == DonorKind.Recipient) {
                console.log(string.concat("UNIBOOST_RECIPIENT_IS_NUDGE_TARGET|", vm.toString(donors[i].addr)));
            }
        }
        (bool rok, bytes memory rdata) = RETIRED_SYA.staticcall(abi.encodeWithSignature("nudge()"));
        if (rok && rdata.length == 32 && abi.decode(rdata, (address)) == OLD_MINTER) {
            console.log(
                "DONOR_RETIRED|StableYieldAccumulator (retired, story 131, no strategies; excluded)|", RETIRED_SYA
            );
        }
        console.log("Preflight OK.");
    }

    function _takeBaseline() internal {
        address[3] memory toks = _nudgeTokens();
        string memory json = _progressJson();
        if (bytes(json).length != 0 && vm.keyExistsJson(json, ".baseline.block")) {
            baseline.blockNumber = vm.parseJsonUint(json, ".baseline.block");
            uint256[] memory bal = vm.parseJsonUintArray(json, ".baseline.balance");
            uint256[] memory buf = vm.parseJsonUintArray(json, ".baseline.buffer");
            require(bal.length == 3 && buf.length == 3, "progress: malformed baseline");
            for (uint256 i = 0; i < 3; i++) {
                baseline.balance[i] = bal[i];
                baseline.buffer[i] = buf[i];
            }
            baseline.fromProgress = true;
            console.log("BASELINE|from progress file (write-once), block", baseline.blockNumber);
        } else {
            baseline.blockNumber = block.number;
            for (uint256 i = 0; i < 3; i++) {
                baseline.balance[i] = IERC20(toks[i]).balanceOf(OLD_MINTER);
                (, baseline.buffer[i],,) = INudgeStreamerND(NUDGE_STREAMER).streams(OLD_MINTER, toks[i]);
            }
            console.log("BASELINE|taken at block", baseline.blockNumber);
        }
        for (uint256 i = 0; i < 3; i++) {
            console.log(
                string.concat("BASELINE|", vm.toString(toks[i]), "|balance|buffer"),
                baseline.balance[i],
                baseline.buffer[i]
            );
        }
    }

    // =====================================================================
    // Phase 1 - freeze the old minter (PauserV2: no dead window)
    // =====================================================================

    function _phase1_freezeOldMinter() internal {
        console.log("\n=== Phase 1: freeze the old minter ===");
        IOldBatchMinterND old = IOldBatchMinterND(OLD_MINTER);
        IPauserV2ND p = IPauserV2ND(PAUSER_V2);
        if (p.isRegistered(OLD_MINTER)) {
            _begin("old_pauserV2Unregister");
            p.unregister(OLD_MINTER);
            _end();
            console.log("1a. PauserV2.unregister(old)");
        } else {
            console.log("1a. old minter not registered with PauserV2 - skipped");
        }
        require(!p.isRegistered(OLD_MINTER), "phase 1: old minter still registered with PauserV2");

        if (old.pauser() != OWNER) {
            _begin("old_setPauserOwner");
            old.setPauser(OWNER);
            _end();
            console.log("1b. old.setPauser(OWNER)");
        } else {
            console.log("1b. old pauser already OWNER - skipped");
        }
        require(old.pauser() == OWNER, "phase 1: old.pauser() != OWNER");

        if (!old.paused()) {
            _begin("old_pause");
            old.pause();
            _end();
            console.log("1c. old.pause()");
        } else {
            console.log("1c. old minter already paused - skipped");
        }
        require(old.paused(), "phase 1: old minter not paused");
        _requirePauserHealthClean("after-phase1");
        if (isPreview) _proveGlobalPause("after-phase1");
    }

    // =====================================================================
    // Phase 2 - deploy and configure
    // =====================================================================

    function _phase2_deployAndConfigure() internal {
        console.log("\n=== Phase 2: deploy and configure the new minter ===");
        if (address(minter) == address(0)) {
            if (!isPreview) _requireBroadcastGasPriceHeadroom();
            uint256 createNonce = vm.getNonce(OWNER);
            _begin("deploy_BatchNFTMinterNudgeDiscount");
            minter = new BatchNFTMinterNudgeDiscount(OWNER);
            _end();
            deployedThisRun = true;
            console.log("2.0 BatchNFTMinterNudgeDiscount deployed:", address(minter));
            if (!isPreview) _recordPendingProgress(createNonce);
        }
        BatchNFTMinterNudgeDiscount m = minter;
        require(m.owner() == OWNER, "phase 2: new minter owner() != OWNER");

        if (address(m.tokenMinter()) != NFT_MINTER) {
            _begin("bm_setTokenMinter");
            m.setTokenMinter(ITokenMinterV2(NFT_MINTER));
            _end();
        }
        require(address(m.tokenMinter()) == NFT_MINTER, "phase 2: tokenMinter");
        if (m.dispatcherIndex() != DISPATCHER_INDEX) {
            _begin("bm_setDispatcherIndex");
            m.setDispatcherIndex(DISPATCHER_INDEX);
            _end();
        }
        require(m.dispatcherIndex() == DISPATCHER_INDEX, "phase 2: dispatcherIndex");

        // Whitelist BEFORE setDiscountToken (it reverts DiscountTokenNotWhitelisted otherwise).
        address[3] memory toks = _nudgeTokens();
        for (uint256 i = 0; i < 3; i++) {
            if (!m.isNudgeToken(toks[i])) {
                _begin(string.concat("bm_whitelist_", vm.toString(toks[i])));
                m.setNudgeTokenWhitelist(toks[i], true);
                _end();
            }
            require(m.isNudgeToken(toks[i]), "phase 2: whitelist");
        }

        if (address(m.discountToken()) != USDC) {
            _begin("bm_setDiscountToken");
            m.setDiscountToken(USDC);
            _end();
        }
        require(address(m.discountToken()) == USDC, "phase 2: discountToken");
        if (deployedThisRun || m.discountPercent() != DISCOUNT_PERCENT) {
            _begin("bm_setDiscountPercent");
            m.setDiscountPercent(DISCOUNT_PERCENT);
            _end();
        }
        require(m.discountPercent() == DISCOUNT_PERCENT, "phase 2: discountPercent");
        if (deployedThisRun || m.burnPercent() != BURN_PERCENT) {
            _begin("bm_setBurnPercent");
            m.setBurnPercent(BURN_PERCENT);
            _end();
        }
        require(m.burnPercent() == BURN_PERCENT, "phase 2: burnPercent");
        if (m.nftStaker() != NFT_STAKER) {
            _begin("bm_setNFTStaker");
            m.setNFTStaker(NFT_STAKER);
            _end();
        }
        require(m.nftStaker() == NFT_STAKER, "phase 2: nftStaker");
        if (address(m.mintDebtHook()) != MINT_DEBT_HOOK) {
            _begin("bm_setMintDebtHook");
            m.setMintDebtHook(IMintDebtRatio(MINT_DEBT_HOOK));
            _end();
        }
        require(address(m.mintDebtHook()) == MINT_DEBT_HOOK, "phase 2: mintDebtHook");
        if (address(m.psm()) != PSM) {
            _begin("bm_setPSM");
            m.setPSM(ISkyPSM(PSM));
            _end();
        }
        require(address(m.psm()) == PSM, "phase 2: psm");
        if (address(m.sUSDS()) != SUSDS) {
            _begin("bm_setSUSDS");
            m.setSUSDS(IERC4626(SUSDS));
            _end();
        }
        require(address(m.sUSDS()) == SUSDS, "phase 2: sUSDS");
        // AFTER setSUSDS: the contract validates the pair's tokens against sUSDS and phUSD.
        if (m.router() != UNI_ROUTER || m.pair() != PAIR || m.phUSD() != PHUSD) {
            _begin("bm_setSwapRoute");
            m.setSwapRoute(UNI_ROUTER, PAIR, PHUSD);
            _end();
        }
        require(m.router() == UNI_ROUTER && m.pair() == PAIR && m.phUSD() == PHUSD, "phase 2: swap route");
        if (m.buyerAuthVersion(OWNER) != m.authVersion()) {
            _begin("bm_setAuthorizedBuyerOwner");
            m.setAuthorizedBuyer(OWNER, true);
            _end();
        }
        require(m.buyerAuthVersion(OWNER) == m.authVersion(), "phase 2: OWNER not an authorised buyer");

        // Cutover gate (e): each its own step, set explicitly on a fresh deploy even where the value equals the
        // contract default (never left at defaults), read back, then the Safeguard-4 donation constraint.
        if (deployedThisRun || m.maxFreePerBatch() != MAX_FREE_PER_BATCH) {
            _begin("bm_setMaxFreePerBatch");
            m.setMaxFreePerBatch(MAX_FREE_PER_BATCH);
            _end();
        }
        require(m.maxFreePerBatch() == MAX_FREE_PER_BATCH, "phase 2: maxFreePerBatch");
        if (deployedThisRun || m.overflowNFTsPerBoostPoint() != OVERFLOW_NFTS_PER_BOOST_POINT) {
            _begin("bm_setOverflowNFTsPerBoostPoint");
            m.setOverflowNFTsPerBoostPoint(OVERFLOW_NFTS_PER_BOOST_POINT);
            _end();
        }
        require(m.overflowNFTsPerBoostPoint() == OVERFLOW_NFTS_PER_BOOST_POINT, "phase 2: overflowNFTsPerBoostPoint");
        if (deployedThisRun || m.maxBoost() != MAX_BOOST) {
            _begin("bm_setMaxBoost");
            m.setMaxBoost(MAX_BOOST);
            _end();
        }
        require(m.maxBoost() == MAX_BOOST, "phase 2: maxBoost");
        require(m.boostDonationSafe(), "gate: boostDonationSafe() is false after configuration - refusing");
        console.log("GATE|cap / perPoint / maxBoost:", MAX_FREE_PER_BATCH, OVERFLOW_NFTS_PER_BOOST_POINT, MAX_BOOST);

        // Pauser BEFORE register (PauserV2.register requires pauser() == PauserV2). One-tx coverage gap: see header.
        if (m.pauser() != PAUSER_V2) {
            _begin("bm_setPauser");
            m.setPauser(PAUSER_V2);
            _end();
        }
        require(m.pauser() == PAUSER_V2, "phase 2: pauser != PauserV2");
        if (!IPauserV2ND(PAUSER_V2).isRegistered(address(m))) {
            _begin("bm_pauserV2Register");
            IPauserV2ND(PAUSER_V2).register(address(m));
            _end();
        }
        require(IPauserV2ND(PAUSER_V2).isRegistered(address(m)), "phase 2: not registered with PauserV2");

        for (uint256 i = 0; i < 3; i++) {
            uint256 dur = _streamDuration(toks[i]);
            (uint256 cur,,,) = INudgeStreamerND(NUDGE_STREAMER).streams(address(m), toks[i]);
            if (cur != dur) {
                _begin(string.concat("stream_", vm.toString(toks[i])));
                INudgeStreamerND(NUDGE_STREAMER).registerStream(address(m), toks[i], dur);
                _end();
            }
            (cur,,,) = INudgeStreamerND(NUDGE_STREAMER).streams(address(m), toks[i]);
            require(cur == dur, "phase 2: stream duration");
        }
        if (m.nudgeStreamer() != NUDGE_STREAMER) {
            _begin("bm_setNudgeStreamer");
            m.setNudgeStreamer(NUDGE_STREAMER);
            _end();
        }
        require(m.nudgeStreamer() == NUDGE_STREAMER, "phase 2: nudgeStreamer");

        // LAST: the free-mint grant. Pause wiring is live (the only kill switch for free mints); no donor yet.
        if (!INFTMinterV2ND(NFT_MINTER).authorizedMinters(address(m))) {
            _begin("nftMinter_setAuthorizedMinter");
            INFTMinterV2ND(NFT_MINTER).setAuthorizedMinter(address(m), true);
            _end();
        }
        require(INFTMinterV2ND(NFT_MINTER).authorizedMinters(address(m)), "phase 2: authorizedMinters(new) is false");
        _requireNewMinterConfigured(m);
        _requirePauserHealthClean("after-phase2");
        console.log("Phase 2 OK: configured, registered with PauserV2, authorised NFTMinterV2 minter.");
    }

    // =====================================================================
    // Phase 3 - repoint donors
    // =====================================================================

    function _phase3_repointDonors() internal {
        console.log("\n=== Phase 3: repoint donors ===");
        Donor[] memory donors = _donorInventory(OLD_MINTER);
        address n = address(minter);
        for (uint256 i = 0; i < donors.length; i++) {
            Donor memory d = donors[i];
            _requireRecipientIsNudgeTarget(d);
            _begin(string.concat("donor_", _setterName(d.kind), "_", vm.toString(d.addr)));
            if (d.kind == DonorKind.BatchMinter) IDonorBatchMinterND(d.addr).setBatchMinter(n);
            else if (d.kind == DonorKind.Recipient) IDonorRecipientND(d.addr).setRecipient(n);
            else IDonorNudgeND(d.addr).setNudgeAddress(n);
            _end();
            console.log(string.concat("REPOINTED|", d.label, "|", vm.toString(d.addr), "|", _setterName(d.kind)));
        }
        Donor[] memory stale = _donorInventory(OLD_MINTER);
        _printInventory("STALE_DONOR", stale);
        require(stale.length == 0, "phase 3: a donor still targets the old minter");
        _printInventory("DONOR_NEW", _donorInventory(n));
    }

    // =====================================================================
    // Phase 4 - migrate the old pot (through the streamer, never a direct transfer)
    // =====================================================================

    function _phase4_migratePot() internal {
        console.log("\n=== Phase 4: migrate the old pot ===");
        address[3] memory toks = _nudgeTokens();
        for (uint256 i = 0; i < 3; i++) {
            _releaseOldBuffer(toks[i]);
            movedThisRun[i] += _rescueAndRestream(toks[i]);
        }
    }

    /// @dev Phase 4a for one token: two `registerStream(old, token, 1)` one block apart release the whole buffer.
    function _releaseOldBuffer(address t) internal {
        INudgeStreamerND ns = INudgeStreamerND(NUDGE_STREAMER);
        (, uint256 buffer,,) = ns.streams(OLD_MINTER, t);
        if (buffer == 0) return;
        require(
            IOldBatchMinterND(OLD_MINTER).isNudgeToken(t),
            "phase 4: old minter no longer whitelists the token - cannot registerStream"
        );
        uint256 balBefore = IERC20(t).balanceOf(OLD_MINTER);
        _begin(string.concat("old_bufferRelease1_", vm.toString(t)));
        ns.registerStream(OLD_MINTER, t, 1);
        _end();
        _advanceOneBlock();
        (, uint256 left,,) = ns.streams(OLD_MINTER, t);
        if (left > 0) {
            _begin(string.concat("old_bufferRelease2_", vm.toString(t)));
            ns.registerStream(OLD_MINTER, t, 1);
            _end();
        }
        (, left,,) = ns.streams(OLD_MINTER, t);
        require(left == 0, "phase 4: old minter stream buffer not released");
        require(
            IERC20(t).balanceOf(OLD_MINTER) == balBefore + buffer,
            "phase 4: released buffer did not land on the old minter"
        );
        console.log(string.concat("BUFFER_RELEASED|", vm.toString(t)), buffer);
    }

    /// @dev Phase 4b for one token: rescue to OWNER (transit), then collectNudge into the new minter's stream.
    function _rescueAndRestream(address t) internal returns (uint256 bal) {
        bal = IERC20(t).balanceOf(OLD_MINTER);
        if (bal == 0) return 0;
        uint256 ownerBal0 = IERC20(t).balanceOf(OWNER);
        _begin(string.concat("old_rescue_", vm.toString(t)));
        IOldBatchMinterND(OLD_MINTER).rescueERC20(IERC20(t), OWNER, bal);
        _end();
        require(IERC20(t).balanceOf(OLD_MINTER) == 0, "phase 4: old minter balance not zero after rescue");
        require(IERC20(t).balanceOf(OWNER) == ownerBal0 + bal, "phase 4: rescue did not reach OWNER exactly");
        _collectNudgeFromOwner(t, bal);
        require(IERC20(t).balanceOf(OWNER) == ownerBal0, "phase 4: OWNER transit not closed (balance changed)");
        console.log(string.concat("POT_MIGRATED|", vm.toString(t)), bal);
    }

    /// @dev Approve EXACTLY `amount`, collectNudge into the new minter, require the buffer grew by exactly `amount`
    ///      (fee-on-transfer guard), the minter's raw balance rose by no more than the stream it settled, and the
    ///      allowance is back to zero.
    function _collectNudgeFromOwner(address token, uint256 amount) internal {
        INudgeStreamerND ns = INudgeStreamerND(NUDGE_STREAMER);
        address n = address(minter);
        require(IERC20(token).allowance(OWNER, NUDGE_STREAMER) == 0, "collect: OWNER already has a streamer allowance");
        uint256 settle = ns.pendingStream(n, token);
        (, uint256 buf0,,) = ns.streams(n, token);
        uint256 raw0 = IERC20(token).balanceOf(n);
        _begin(string.concat("collect_approve_", vm.toString(token)));
        IERC20(token).approve(NUDGE_STREAMER, amount);
        _end();
        _begin(string.concat("collect_nudge_", vm.toString(token)));
        ns.collectNudge(n, token, amount);
        _end();
        (, uint256 buf1,,) = ns.streams(n, token);
        require(buf1 == buf0 - settle + amount, "collect: buffer delta != amount (fee-on-transfer?)");
        require(IERC20(token).balanceOf(n) == raw0 + settle, "collect: new minter raw balance jumped");
        require(IERC20(token).allowance(OWNER, NUDGE_STREAMER) == 0, "collect: allowance not returned to 0");
    }

    /// @dev Local-pass model of the next block (see header, Phase 4a). Signs nothing.
    function _advanceOneBlock() internal {
        vm.warp(vm.getBlockTimestamp() + BLOCK_GAP_SECS);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @notice Fresh run: the sum moved out of the old minter equals the Phase 0 baseline exactly (the local pass is
    ///         one fork state, so no donation can land in between). Resume: residue sweeps are logged.
    function _requirePotMigrated() internal view {
        address[3] memory toks = _nudgeTokens();
        for (uint256 i = 0; i < 3; i++) {
            uint256 expected = baseline.balance[i] + baseline.buffer[i];
            console.log(
                string.concat("POT_TOTAL|", vm.toString(toks[i]), "|baseline|movedThisRun"), expected, movedThisRun[i]
            );
            if (!baseline.fromProgress) {
                require(movedThisRun[i] == expected, "phase 4: moved != baseline balance + buffer");
            }
        }
    }

    // =====================================================================
    // Phase 5 - PREVIEW-only smoke (snapshot-reverted)
    // =====================================================================

    struct Expect {
        uint256 p0;
        uint256 g;
        uint256 potUSDC;
        uint256 potUSD;
        uint256 free;
        uint256 overflowFree;
        uint256 boost;
        uint256 effective;
        uint256 total;
        uint256 paid;
        uint256 paidCost;
        uint256 owed;
        uint256 reserved;
    }

    /// @dev The spec maths, recomputed here from live inputs (story Phase 5 step 2).
    function _expected() internal view returns (Expect memory e) {
        BatchNFTMinterNudgeDiscount m = minter;
        (, e.p0, e.g,) = INFTMinterV2ND(NFT_MINTER).configs(DISPATCHER_INDEX);
        e.potUSDC = IERC20(USDC).balanceOf(address(m)) - m.pendingBuyUSDC()
            + INudgeStreamerND(NUDGE_STREAMER).pendingStream(address(m), USDC);
        uint256 gross = e.potUSDC * ISkyPSMND(PSM).to18ConversionFactor();
        e.potUSD = gross - (gross * ISkyPSMND(PSM).tin()) / WAD;
        uint256 potFree = e.potUSD / e.p0;
        uint256 cap = m.maxFreePerBatch();
        e.free = potFree > cap ? cap : potFree;
        e.overflowFree = potFree > cap ? potFree - cap : 0;
        e.boost = e.overflowFree / m.overflowNFTsPerBoostPoint();
        if (e.boost > m.maxBoost()) e.boost = m.maxBoost();
        e.effective = m.discountPercent() + e.boost;
        if (e.effective > 99) e.effective = 99;
        e.total = Math.ceilDiv(e.free * 100, e.effective);
        e.paid = e.total - e.free;
        uint256 price = e.p0;
        for (uint256 i; i < e.paid; ++i) {
            e.paidCost += price;
            price = price + (price * e.g) / 10000;
        }
        e.owed = (e.free * e.p0 * IMintDebtHookND(MINT_DEBT_HOOK).ratio()) / 100;
        e.reserved = potFree > cap ? Math.mulDiv(e.potUSDC, e.free * e.p0, e.potUSD, Math.Rounding.Ceil) : e.potUSDC;
    }

    function _requirePreviewMatches(Expect memory e) internal view {
        (uint256 free, uint256 total, uint256 paid, uint256 paidCost, uint256 owed,,) = minter.previewBatch();
        (uint256 overflowFree, uint8 boost, uint8 eff, uint256 reserved) = minter.previewBoost();
        require(free == e.free && total == e.total && paid == e.paid, "smoke: previewBatch counts != spec maths");
        require(paidCost == e.paidCost && owed == e.owed, "smoke: previewBatch cost/owed != spec maths");
        require(overflowFree == e.overflowFree && boost == e.boost && eff == e.effective, "smoke: previewBoost != spec");
        require(reserved == e.reserved, "smoke: previewBoost reservedUSDC != spec");
        require(free > 0 && free <= minter.maxFreePerBatch(), "smoke: free out of (0, cap]");
        require(paid >= 1, "smoke: paid < 1");
    }

    function _fundUsdcStream(address donor, uint256 amount) internal {
        deal(USDC, donor, amount);
        vm.startPrank(donor);
        IERC20(USDC).approve(NUDGE_STREAMER, amount);
        INudgeStreamerND(NUDGE_STREAMER).collectNudge(address(minter), USDC, amount);
        vm.stopPrank();
    }

    struct BatchBefore {
        uint256 nft;
        uint256 usdc;
        uint256 pendBuy;
        uint256 pendOwed;
        uint256[] bonus;
        uint256[] floors;
        address[] bonusTokens;
    }

    function _batchBefore(address batcher) internal view returns (BatchBefore memory bb) {
        BatchNFTMinterNudgeDiscount m = minter;
        bb.bonusTokens = m.getBonusTokens();
        bb.floors = new uint256[](bb.bonusTokens.length);
        bb.bonus = new uint256[](bb.bonusTokens.length);
        for (uint256 i = 0; i < bb.bonusTokens.length; i++) {
            bb.floors[i] = IERC20(bb.bonusTokens[i]).balanceOf(address(m))
                + INudgeStreamerND(NUDGE_STREAMER).pendingStream(address(m), bb.bonusTokens[i]);
            bb.bonus[i] = IERC20(bb.bonusTokens[i]).balanceOf(batcher);
        }
        bb.nft = INFTMinterV2ND(NFT_MINTER).balanceOf(batcher, DISPATCHER_INDEX);
        bb.usdc = IERC20(USDC).balanceOf(batcher);
        bb.pendBuy = m.pendingBuyUSDC();
        bb.pendOwed = m.pendingStakerPhUSD();
    }

    /// @dev One discounted 6-arg batchMint from a dealt third party, with every Phase 5 step 3 assertion.
    ///      `quotedBoost` and `expectedTotal` come from one preview read; `bonusTokens` and `bonusMinRewards`
    ///      (balance + pending stream) from one `getBonusTokens()` read.
    function _smokeBatch(address batcher, Expect memory e) internal returns (Vm.Log[] memory logs) {
        BatchBefore memory bb = _batchBefore(batcher);
        (, uint8 quotedBoost,,) = minter.previewBoost();
        vm.recordLogs();
        vm.prank(batcher);
        minter.batchMint(e.total, quotedBoost, batcher, e.paidCost + e.paidCost / 100 + 1, bb.bonusTokens, bb.floors);
        logs = vm.getRecordedLogs();
        _checkBatch(batcher, e, bb);
    }

    function _checkBatch(address batcher, Expect memory e, BatchBefore memory bb) internal view {
        BatchNFTMinterNudgeDiscount m = minter;
        require(
            INFTMinterV2ND(NFT_MINTER).balanceOf(batcher, DISPATCHER_INDEX) == bb.nft + e.total, "smoke: NFTs != total"
        );
        uint256 expPrice = e.p0;
        for (uint256 i; i < e.paid; ++i) {
            expPrice = expPrice + (expPrice * e.g) / 10000;
        }
        (, uint256 priceAfter,,) = INFTMinterV2ND(NFT_MINTER).configs(DISPATCHER_INDEX);
        require(priceAfter == expPrice, "smoke: price did not move by exactly `paid` growth steps");
        require(IERC20(USDC).balanceOf(batcher) == bb.usdc, "smoke: batcher received USDC");
        for (uint256 i = 0; i < bb.bonusTokens.length; i++) {
            require(
                IERC20(bb.bonusTokens[i]).balanceOf(batcher) >= bb.bonus[i] + bb.floors[i],
                "smoke: bonus below its floor"
            );
        }
        require(m.pendingBuyUSDC() == bb.pendBuy + e.reserved, "smoke: pendingBuyUSDC did not rise by reservedUSDC");
        require(m.pendingStakerPhUSD() == bb.pendOwed + e.owed, "smoke: pendingStakerPhUSD did not rise by owed");
        require(e.free <= m.maxFreePerBatch(), "smoke: free > cap");
    }

    function _phase5_smoke() internal {
        console.log("\n=== Phase 5: PREVIEW smoke (snapshot-reverted; third parties, never OWNER) ===");
        BatchNFTMinterNudgeDiscount m = minter;
        uint256 snap = vm.snapshotState();
        address batcher = makeAddr("story119-smoke-batcher");
        address donor = makeAddr("story119-smoke-donor");
        require(batcher != OWNER && donor != OWNER, "smoke actors must never be OWNER");
        deal(USDS, batcher, 10_000_000e18);
        vm.prank(batcher);
        IERC20(USDS).approve(address(m), type(uint256).max);
        (, uint256 p0,,) = INFTMinterV2ND(NFT_MINTER).configs(DISPATCHER_INDEX);

        // ---- 1-3. uncapped batch: stream ~5 free-equivalents (fund the stream first if it is empty) ----
        (, uint256 buf, uint256 rps,) = INudgeStreamerND(NUDGE_STREAMER).streams(address(m), USDC);
        if (buf < (8 * p0) / 1e12) {
            _fundUsdcStream(donor, (8 * p0) / 1e12);
            (, buf, rps,) = INudgeStreamerND(NUDGE_STREAMER).streams(address(m), USDC);
        }
        uint256 want = (5 * p0) / 1e12 + 1;
        vm.warp(vm.getBlockTimestamp() + (want * 1e18) / rps + 1);
        Expect memory e = _expected();
        require(e.free > 0 && e.free < m.maxFreePerBatch(), "smoke: uncapped batch sizing failed");
        _requirePreviewMatches(e);
        _smokeBatch(batcher, e);
        smokeUncappedFree = e.free;
        console.log("SMOKE|uncapped batch free / total / reservedUSDC:", e.free, e.total, e.reserved);

        // ---- 3b. capped batch: fund above the cap via collectNudge, stream it all (warp past the window) ----
        uint256 target = m.maxFreePerBatch() + m.overflowNFTsPerBoostPoint() * 5 + 1;
        _fundUsdcStream(donor, (target * p0 * 101) / 100 / 1e12 + 1);
        vm.warp(vm.getBlockTimestamp() + USDC_STREAM_DURATION + 1);
        e = _expected();
        require(e.free == m.maxFreePerBatch(), "smoke: capped batch free != cap");
        require(e.overflowFree > 0, "smoke: capped batch has no overflow");
        uint256 expectedBoost = e.overflowFree / m.overflowNFTsPerBoostPoint();
        if (expectedBoost > m.maxBoost()) expectedBoost = m.maxBoost();
        require(e.boost == expectedBoost, "smoke: boost != min(maxBoost, overflowFree / perPoint)");
        require(e.reserved < e.potUSDC, "smoke: capped batch reserves the whole pot");
        _requirePreviewMatches(e);
        Vm.Log[] memory logs = _smokeBatch(batcher, e);
        bool sawTemp;
        bytes32 tempTopic = keccak256("TempDiscountApplied(uint256,uint8,uint8)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(m) && logs[i].topics[0] == tempTopic) {
                (uint256 ovf, uint8 b, uint8 ef) = abi.decode(logs[i].data, (uint256, uint8, uint8));
                require(ovf == e.overflowFree && b == e.boost && ef == e.effective, "smoke: TempDiscountApplied args");
                sawTemp = true;
            }
        }
        require(sawTemp == (e.boost > 0), "smoke: TempDiscountApplied emitted iff boost > 0");
        require(m.availablePotUSDC() == e.potUSDC - e.reserved, "smoke: unreserved remainder did not stay as pot");
        smokeCappedFree = e.free;
        smokeCappedBoost = uint8(e.boost);
        console.log("SMOKE|capped batch free / overflowFree / boost:", e.free, e.overflowFree, e.boost);
        console.log("SMOKE|capped reservedUSDC / remainder left as pot:", e.reserved, e.potUSDC - e.reserved);

        // ---- 4. buyAndBurn as OWNER (the authorised buyer), floor = route quote - 1% ----
        _smokeBuyAndBurn();

        // ---- 5. PauserV2.pause() pauses the new minter; a paused minter refuses batchMint ----
        _pauseViaPauserV2("story119-smoke-pauser");
        require(m.paused(), "smoke: PauserV2.pause() did not pause the new minter");
        address[] memory bt = m.getBonusTokens();
        uint256[] memory zeros = new uint256[](bt.length);
        vm.prank(batcher);
        try m.batchMint(1, 0, batcher, 1, bt, zeros) {
            revert("smoke: paused new minter accepted batchMint");
        } catch {}
        console.log("SMOKE|PauserV2.pause() paused the new minter; batchMint refused while paused");

        _assertOwnerBalancesNotIncreased("smoke (before revert)");
        uint256 keepUncapped = smokeUncappedFree;
        uint256 keepCapped = smokeCappedFree;
        uint8 keepBoost = smokeCappedBoost;
        uint256 keepOut = smokeBuyPhusdOut;
        uint256 keepBurned = smokeBuyBurned;
        vm.revertToState(snap); // rolls back this contract's storage too: restore the recorded results after it
        smokeUncappedFree = keepUncapped;
        smokeCappedFree = keepCapped;
        smokeCappedBoost = keepBoost;
        smokeBuyPhusdOut = keepOut;
        smokeBuyBurned = keepBurned;
        smokeRan = true;
        console.log("Smoke OK (reverted).");
    }

    function _smokeBuyAndBurn() internal {
        BatchNFTMinterNudgeDiscount m = minter;
        uint256 usdcIn = m.pendingBuyUSDC();
        uint256 quote = _quoteRoute(m, usdcIn);
        uint256 minOut = (quote * 99) / 100;
        uint256 staker0 = IERC20(PHUSD).balanceOf(NFT_STAKER);
        uint256 supply0 = IERC20(PHUSD).totalSupply();
        uint256 owedPending = m.pendingStakerPhUSD();
        vm.prank(OWNER);
        (uint256 out, uint256 toStaker, uint256 burned) = m.buyAndBurn(usdcIn, minOut, vm.getBlockTimestamp() + 1800);
        uint256 toStakerOwed = out < owedPending ? out : owedPending;
        uint256 extra = out - toStakerOwed;
        require(out >= minOut, "smoke: buy output below the floor");
        require(burned == (extra * m.burnPercent()) / 100, "smoke: burned != extra * burnPercent / 100");
        require(toStaker == toStakerOwed + extra - burned, "smoke: toStaker split");
        require(IERC20(PHUSD).balanceOf(NFT_STAKER) == staker0 + toStaker, "smoke: NFTStaker phUSD delta != toStaker");
        require(IERC20(PHUSD).totalSupply() == supply0 - burned, "smoke: phUSD supply did not fall by the burn");
        require(m.pendingBuyUSDC() == 0, "smoke: reserve not drained by usdcIn");
        require(
            m.pendingStakerPhUSD() == owedPending - toStakerOwed, "smoke: owed reserve did not fall by toStakerOwed"
        );
        smokeBuyPhusdOut = out;
        smokeBuyBurned = burned;
        console.log("SMOKE|buyAndBurn usdcIn / phusdOut / quote:", usdcIn, out, quote);
        console.log("SMOKE|buyAndBurn toStakerOwed / extra / burned:", toStakerOwed, extra, burned);
    }

    // =====================================================================
    // Global pause proofs (PREVIEW only, snapshot-isolated, EYE dealt to a throwaway actor)
    // =====================================================================

    function _pauseViaPauserV2(string memory actorName) internal {
        IPauserV2ND p = IPauserV2ND(PAUSER_V2);
        address actor = makeAddr(actorName);
        uint256 burnAmt = p.eyeBurnAmount();
        address eye = p.eyeToken(); // cached: a view call between vm.prank and the target would consume the prank
        deal(eye, actor, burnAmt, false);
        vm.prank(actor);
        IERC20(eye).approve(PAUSER_V2, burnAmt);
        vm.prank(actor);
        p.pause();
    }

    function _proveGlobalPause(string memory stage) internal {
        uint256 snap = vm.snapshotState();
        _pauseViaPauserV2(string.concat("story119-pause-", stage));
        vm.revertToState(snap);
        console.log(string.concat("GLOBAL_PAUSE|", stage, "|SUCCEEDED"));
    }

    /// @notice Every PauserV2 registrant (the new minter included) unpaused with pauser() == PauserV2, the old minter
    ///         not registered, health() clean; then PauserV2.pause() succeeds and pauses the new minter.
    function _finalGlobalPauseSweep() internal {
        IPauserV2ND p = IPauserV2ND(PAUSER_V2);
        require(!p.isRegistered(OLD_MINTER), "sweep: old minter registered");
        address[] memory regs = p.getPausableContracts();
        bool sawNew;
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bytes memory d) = regs[i].staticcall(abi.encodeWithSignature("pauser()"));
            require(ok && abi.decode(d, (address)) == PAUSER_V2, "sweep: a registrant's pauser() != PauserV2");
            (ok, d) = regs[i].staticcall(abi.encodeWithSignature("paused()"));
            if (ok && d.length == 32) require(!abi.decode(d, (bool)), "sweep: a registrant is paused");
            if (regs[i] == address(minter)) sawNew = true;
        }
        require(sawNew, "sweep: new minter not among PauserV2 registrants");
        _requirePauserHealthClean("final-sweep");
        uint256 snap = vm.snapshotState();
        _pauseViaPauserV2("story119-pause-final");
        require(minter.paused(), "sweep: PauserV2.pause() did not pause the new minter");
        vm.revertToState(snap);
        console.log("GLOBAL_PAUSE|SUCCEEDED");
    }

    // =====================================================================
    // Broadcast plumbing
    // =====================================================================

    function _begin(string memory step) internal virtual {
        txCount++;
        stepsSent.push(step);
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
    }

    function _end() internal virtual {
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
    }

    /// @dev `virtual` only so fork tests can stand in for the `--sender`.
    function _sender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _gasPriceFromEnv() internal view virtual returns (uint256) {
        return vm.envOr("NUDGE_DISCOUNT_GAS_PRICE_WEI", uint256(0));
    }

    /// @dev Legacy txs at a fixed `--with-gas-price` stall while block.basefee exceeds it: require 2x headroom.
    function _requireBroadcastGasPriceHeadroom() internal view virtual {
        uint256 gasPriceWei = _gasPriceFromEnv();
        require(gasPriceWei > 0, "NUDGE_DISCOUNT_GAS_PRICE_WEI unset or 0");
        console.log("Gas price (wei):", gasPriceWei, " block.basefee (wei):", block.basefee);
        require(gasPriceWei >= block.basefee * 2, "NUDGE_DISCOUNT_GAS_PRICE_WEI < 2 x block.basefee: raise it");
    }

    /// @dev OWNER's ON-CHAIN balance (`eth_getBalance`; forge pre-funds the script sender in-EVM). `virtual` for
    ///      fork tests.
    function _ownerEthOnChain() internal virtual returns (uint256) {
        bytes memory raw = vm.rpc("eth_getBalance", string.concat('["', vm.toString(OWNER), '","latest"]'));
        require(raw.length <= 32, "eth_getBalance returned an unusable response");
        if (raw.length == 0) return 0;
        return uint256(bytes32(raw)) >> (8 * (32 - raw.length));
    }

    function _requiredOwnerEth(uint256 price) internal pure returns (uint256) {
        return (CUTOVER_GAS_BUDGET * price * 12) / 10;
    }

    function _logOwnerEthBudget() internal {
        uint256 price = _gasPriceFromEnv();
        if (price == 0) price = PREVIEW_DEFAULT_GAS_PRICE_WEI;
        uint256 required = _requiredOwnerEth(price);
        uint256 bal = _ownerEthOnChain();
        console.log("ETH_BUDGET|gasBudget / gasPriceWei / requiredWei:", CUTOVER_GAS_BUDGET, price, required);
        if (bal >= required) {
            console.log("ETH_BUDGET|OK|OWNER balance / surplus wei:", bal, bal - required);
        } else {
            console.log(
                "ETH_BUDGET|SHORTFALL|OWNER balance / shortfall wei (TOP UP BEFORE :broadcast):", bal, required - bal
            );
        }
    }

    function _requireBroadcastBudget() internal {
        uint256 price = _gasPriceFromEnv();
        require(price > 0, "NUDGE_DISCOUNT_GAS_PRICE_WEI unset or 0");
        uint256 required = _requiredOwnerEth(price);
        uint256 bal = _ownerEthOnChain();
        console.log("ETH_BUDGET|gasBudget / gasPriceWei / requiredWei:", CUTOVER_GAS_BUDGET, price, required);
        require(bal >= required, "OWNER ETH below the cutover gas budget - top up before signing");
        console.log("ETH_BUDGET|OK");
    }

    // =====================================================================
    // Progress file
    // =====================================================================

    /// @notice Forge runs this in its LOCAL pass, before the CREATE is signed: record `pending` + the CREATE nonce +
    ///         the baseline. Written only under NUDGE_DISCOUNT_BROADCAST=true (the :broadcast key alone). Never
    ///         `completed`: scripts/confirm-nudge-discount-progress.js does that from a receipt and live code.
    function _recordPendingProgress(uint256 createNonce) internal {
        if (!_progressWriteEnabledFromEnv()) {
            console.log("NUDGE_DISCOUNT_BROADCAST unset: dry run, progress file NOT written.");
            return;
        }
        _serializeProgress("pending", false, createNonce);
        console.log("Progress file written (pending until confirmed):", _progressFile());
    }

    /// @notice End of a broadcast run: rewrite the file with the steps sent so far, keeping the status the confirm
    ///         step may already have set, the CREATE nonce and the write-once baseline.
    function _writeProgress() internal {
        if (!_progressWriteEnabledFromEnv()) return;
        string memory json = _progressJson();
        if (bytes(json).length == 0) return; // nothing deployed by a broadcast (cannot happen: adopt needs a file)
        string memory status = vm.parseJsonString(json, ".deploymentStatus");
        bool deployed = vm.parseJsonBool(json, ".contracts.NudgeDiscountBatchMinter.deployed");
        uint256 nonce = vm.parseJsonUint(json, ".contracts.NudgeDiscountBatchMinter.createNonce");
        _serializeProgress(status, deployed, nonce);
    }

    /// @dev configSteps recorded by EARLIER runs, read once at the start of this run (so a re-serialisation within
    ///      the run never duplicates them).
    function _loadPriorSteps() internal {
        string memory json = _progressJson();
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".configSteps")) return;
        string[] memory prev = vm.parseJsonStringArray(json, ".configSteps");
        for (uint256 i = 0; i < prev.length; i++) {
            priorSteps.push(prev[i]);
        }
    }

    function _allSteps() internal view returns (string[] memory all) {
        all = new string[](priorSteps.length + stepsSent.length);
        for (uint256 i = 0; i < priorSteps.length; i++) {
            all[i] = priorSteps[i];
        }
        for (uint256 i = 0; i < stepsSent.length; i++) {
            all[priorSteps.length + i] = stepsSent[i];
        }
    }

    function _serializeProgress(string memory status, bool deployed, uint256 createNonce) internal {
        vm.serializeAddress("s119.minter", "address", address(minter));
        vm.serializeString("s119.minter", "contractName", "BatchNFTMinterNudgeDiscount");
        vm.serializeUint("s119.minter", "createNonce", createNonce);
        string memory entry = vm.serializeBool("s119.minter", "deployed", deployed);
        string memory contracts = vm.serializeString("s119.contracts", "NudgeDiscountBatchMinter", entry);

        uint256[] memory bal = new uint256[](3);
        uint256[] memory buf = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            bal[i] = baseline.balance[i];
            buf[i] = baseline.buffer[i];
        }
        address[3] memory t3 = _nudgeTokens();
        address[] memory toks = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            toks[i] = t3[i];
        }
        vm.serializeUint("s119.baseline", "block", baseline.blockNumber);
        vm.serializeAddress("s119.baseline", "tokens", toks);
        vm.serializeUint("s119.baseline", "balance", bal);
        string memory base = vm.serializeUint("s119.baseline", "buffer", buf);

        vm.serializeUint("s119.root", "chainId", CHAIN_ID);
        vm.serializeString("s119.root", "networkName", NETWORK_NAME);
        vm.serializeString("s119.root", "deploymentStatus", status);
        vm.serializeString("s119.root", "baseline", base);
        vm.serializeString("s119.root", "configSteps", _allSteps());
        string memory json = vm.serializeString("s119.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
    }

    /// @notice A recorded minter with no code is a CREATE still pending or one that never landed; OWNER's confirmed
    ///         nonce tells them apart. Redeploying while the CREATE may be in the mempool would make two minters.
    function _requireRecordedMinterLanded(address recorded) internal view {
        if (recorded.code.length > 0) return;
        string memory json = _progressJson();
        require(
            vm.keyExistsJson(json, ".contracts.NudgeDiscountBatchMinter.createNonce"),
            "Progress file names a minter with NO CODE and records no createNonce: check OWNER's pending nonce by hand"
        );
        uint256 createNonce = vm.parseJsonUint(json, ".contracts.NudgeDiscountBatchMinter.createNonce");
        string memory n = vm.toString(createNonce);
        if (vm.getNonce(OWNER) <= createNonce) {
            revert(
                string.concat(
                    "Progress file names a minter with NO CODE, but OWNER has not consumed its create nonce ",
                    n,
                    ": the deploy tx may be PENDING. Wait, or replace nonce ",
                    n,
                    " at a higher NUDGE_DISCOUNT_GAS_PRICE_WEI. Do NOT delete the progress file."
                )
            );
        }
        revert(
            string.concat(
                "Progress file names a minter with NO CODE although OWNER consumed its create nonce ",
                n,
                ": the deploy never landed. Delete ",
                _progressFile(),
                " and re-run preview."
            )
        );
    }

    /// @dev Set only by the :broadcast key. `virtual` so tests can pin it (vm.setEnv is process-wide).
    function _progressWriteEnabledFromEnv() internal view virtual returns (bool) {
        return vm.envOr("NUDGE_DISCOUNT_BROADCAST", false);
    }

    /// @dev Always false in production. `virtual` only so the fork tests can simulate a run interrupted after Phase 2.
    function _haltAfterPhase2() internal view virtual returns (bool) {
        return false;
    }

    /// @dev The ONE reader of PREVIEW_MODE; `virtual` only so fork-test harnesses can pin it.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
