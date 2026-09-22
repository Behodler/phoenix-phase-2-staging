// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {VmSafe} from "@forge-std/Vm.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";
import {CutoverStableStakerV2Mainnet, IPausableLike, IPauserRegistry} from "./CutoverStableStakerV2Mainnet.s.sol";
import {ICutoverStaker} from "./helpers/StableStakerCutoverCore.sol";

/**
 * @title  VerifyStableStakerV2Cutover  (story 086, audit L-02 `pps31l2`)
 * @notice READ-ONLY post-broadcast verifier for the StableStaker V1 -> V2 cutover.
 *
 *         THE DEFECT IT CLOSES. The cutover's old post-broadcast check was `:preview`, which re-enters the
 *         full cutover `run()` under an OWNER prank. Every phase there is `if (!done) do();`, so a step that
 *         never landed on mainnet is silently PERFORMED inside the simulation, and Phase 8 then asserts the
 *         simulated state. Fork tests proved preview passes while V1's phUSD mint is still live, while V2 is
 *         still paused, and while V1 is registered and unpaused.
 *
 *         THIS CONTRACT NEVER PERFORMS A STEP. For every phase it `require`s the phase's done-condition
 *         from LIVE chain state, using the same `_done*` / `_v1*` predicates the cutover's phase gates use,
 *         and fails with `verify: <phase>: <step> not on chain` naming the first missing step.
 *
 *         GATED ON CHAIN, NOT ON THE PROGRESS FILE. The progress file supplies only addresses (Antimatter,
 *         StableStakerV2, CrossVersionMigrator), the persisted phUSD minter baseline and the cutover start
 *         block. Its status field is never read: the file is written during forge's LOCAL pass and can mark
 *         a session finished although its transactions never landed. Every loaded address must have code.
 *
 *         READ-ONLY CONTRACT. No broadcast context, no prank, no balance cheat, no time warp, no state
 *         snapshot, no storage write, no file write, no forge-std test import. Inherited mutators of the
 *         cutover script (the phase bodies, the preview smoke tests, the simulated global pause, the progress
 *         writer) are never called. `test/VerifyStableStakerV2CutoverGuards.t.sol` pins all of this at
 *         source level, so those identifiers are deliberately never spelled out in this file.
 *
 *         Phase 0 of the cutover script IS called: it only reads chain state (it fills this contract's own
 *         `tokens` / `cPerDay` / `v1BufferPct` memory, which Phase 4 and Phase 8 need) and adopts the persisted
 *         minter baseline. A live re-read of that baseline would be vacuous post-broadcast, so the verifier
 *         aborts before Phase 0 when the persisted baseline is absent (story 075 precedent).
 *
 *         LOSS GATES AND SELF-EXITS (story 087, audit-33 L-06). Any V1 staker may call the permissionless
 *         `V1.userMigrate` once a pool is Migrating - including between the broadcast `initiateMigration` and
 *         `migrate` transactions - and take their credit to their own wallet. That is a designed exit, never a
 *         loss, and no check here may count it as one:
 *           1. Phase 6 (view, shared with the cutover): the EXIT-REALIZATION BOUND on V1's immutable
 *              `migrationInfo` - `(min(R, P) + weiSlack) * MAX_BPS >= P * (MAX_BPS - bps)`. It bounds the pre -> credit
 *              haircut of every staker however they exit and reads nothing a self-exit can move, so a self-exit
 *              no longer reverts Phase 6 and the verifier always reaches Phase 7, the per-user re-check, the
 *              registrant sweep and Phase 8.
 *           2. Per user: the credit -> credited leg is re-checked per `(token, user)` from V1 `MigratedOut` and
 *              V2 `DepositedFor` logs fetched with `vm.eth_getLogs` from the persisted cutover start block (env
 *              `CUTOVER_START_BLOCK` overrides it), in `LOG_CHUNK_BLOCKS` windows to stay under RPC range
 *              limits. Self-exits (which also emit `MigratedOut` but never deposit into V2) are excluded by
 *              their `UserMigrated` event.
 *           3. Per pool, defence in depth (subtract-from-total): V2's booked total must be at least
 *              `(P - v1Staked - selfExitedPrincipal) * (MAX_BPS - bps) / MAX_BPS - nMigrated * WEI_SLACK`,
 *              where `selfExitedPrincipal` is rebuilt from the `UserMigrated` credits as an UPPER bound on each
 *              exiter's principal (`ceil((credit + 1) * P / min(R, P))`), so the subtraction can never
 *              under-count an exit into a false alarm. Only this verifier has the logs; the broadcast script
 *              cannot see a self-exit from state and relies on (1) plus its in-leg per-user bound.
 *
 *         SOURCE / DESTINATION (story 091). V1 exited through the hard-coded SOURCE strategies; V2 deposits into
 *         the DESTINATION strategies, which differ only for DOLA (the sDOLA strategy recovered from the progress file
 *         key `contracts.ERC4626YieldStrategySDOLA`, exactly as the cutover recovers it). The exit-realization bound
 *         uses the source bound; the per-user re-check and the per-pool aggregate use the per-user bound (source +
 *         destination bps, counted once when they are the same strategy), the same rule as the cutover's in-leg check.
 *
 *         MINTER COLLATERAL / SYA / RETIRED SOURCE (story 092). Phase 6b's records - the pre-repoint minter DOLA config
 *         and R, the DOLA the minter's `totalWithdrawal` delivered - come from the progress file key `minterMove` (the
 *         verifier refuses to run without them); every property is read from chain: the minter's DOLA registration is
 *         the sDOLA strategy with the previous exchangeRate / decimals / maxMintPerDay / enabled, the minter is its client
 *         with principal within the destination bound of R, SYA lists the sDOLA strategy and not the autoDOLA one, SYA
 *         is a withdrawer on the sDOLA strategy only, and the autoDOLA strategy has no clients, no V1 / minter principal,
 *         pauser OWNER, is unregistered from the Pauser and paused. Story 094 (audit-35 L-09): OWNER's DOLA must equal
 *         its persisted pre-execution balance, and the minter's sDOLA principal is bounded against the MINED R read from
 *         the execute's DOLA `Transfer(autoDOLA strategy -> OWNER)` log, never against the recorded (possibly local-pass) R.
 *
 *         PENDING 6b (story 096, audit-35 L-11). A resume past Phase 6 with a lapsed minter window finalizes V2 and leaves
 *         Phase 6b pending (progress status `awaiting_minter_window`). The verifier REFUSES that state with
 *         `verify: Phase6b: PENDING` - it never reports success until the minter withdrawal has executed and 6b is complete.
 *         It does not stop at the first 6b check, though: it skips the 6b block, verifies Phase 7, the per-user credits
 *         (INCLUDING the live `V2 userInfo >= credited` and per-pool aggregate checks - this run is the one chained
 *         immediately after V2 went live) and Phase 8's pending shape, and only THEN reverts `verify: Phase6b: PENDING`.
 *         Once 6b completes (V2 has then been live for >= 6h: expiry, re-initiate, 6h wait), the progress file's sticky
 *         `minterMove.v2LiveBeforeMinterMove` makes the verifier SKIP exactly those two live-balance comparisons - migrated
 *         users may legitimately have withdrawn - and keep every event-based check (a `DepositedFor` per `MigratedOut`,
 *         the per-user loss bound, the vacuity guard) plus the full 6b block. Without the marker the live checks run as
 *         before, so a normal cutover is verified exactly as strictly as it was.
 *
 *         RUN IT IMMEDIATELY AFTER THE BROADCAST. The per-pool aggregate and the `V2 userInfo >= credited`
 *         check read live V2 balances; once migrated users start withdrawing from V2 they can legitimately
 *         fall below what the cutover credited. The `:broadcast` npm key chains this verifier straight after
 *         the address patch, before `:preview`.
 *
 *         Usage: `npm run stable-staker-v2-cutover:verify`
 */
contract VerifyStableStakerV2Cutover is CutoverStableStakerV2Mainnet {
    /// @dev Block window per `eth_getLogs` request. Conservative against common provider range caps.
    uint256 public constant LOG_CHUNK_BLOCKS = 5000;

    bytes32 internal constant MIGRATED_OUT_TOPIC = keccak256("MigratedOut(address,address,uint256,uint256)");
    bytes32 internal constant USER_MIGRATED_TOPIC = keccak256("UserMigrated(address,address,uint256)");
    bytes32 internal constant DEPOSITED_FOR_TOPIC = keccak256("DepositedFor(address,address,uint256)");
    /// @dev Story 094: ERC20 Transfer. `WithdrawalExecuted` emits the principal snapshot P, not the DOLA received, so the
    ///      MINED R is only visible as the DOLA `Transfer(autoDOLA strategy -> OWNER)` of the execute.
    bytes32 internal constant ERC20_TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    /// @dev A decoded `(token, user, amount)` event row. `token` and `user` are the two indexed topics.
    struct CutoverEvent {
        address token;
        address user;
        uint256 amount;
    }

    /// @dev Transport-neutral log row, so the fetch can be swapped (live RPC vs recorded logs in tests).
    struct CutoverLog {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    uint256 public verifiedUserCount;
    /// @dev Story 094: the mined R (sum of DOLA Transfer(autoDOLA strategy -> OWNER) since the cutover start block) and
    ///      the number of such transfers.
    uint256 public verifiedMinedRecovered;
    uint256 public verifiedMinedTransfers;

    function run() external override {
        console.log("=================================================");
        console.log("  STABLESTAKER V2 CUTOVER - READ-ONLY VERIFICATION");
        console.log("  (story 086 / audit L-02)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        require(!_previewModeFromEnv(), "PREVIEW_MODE is meaningless here - the verifier reads LIVE state only");

        _hydrateDeployment();

        _verifyPhase1_v1Retired();
        _verifyPhase2_antimatter();
        _verifyPhase3_stakerV2();
        _verifyPhase3b_sdolaStrategy();

        require(
            phusdBaselineRecorded,
            "verify: Phase0: persisted phUSD minter baseline (baselines.phusdMinterMask) absent from the progress file - refusing to re-derive it from post-broadcast state"
        );
        _phase0_preconditions();

        _verifyPhase4_pools();
        _verifyPhase5_mintRights();
        _verifyPhase6_migration();
        _verifyPhase6b_minterMove();
        _verifyPhase7_finalize();
        _verifyPerUserCredits();

        // Absolute end-state wiring (view-only), including story 084's registrant sweep. While 6b is pending it asserts
        // the pending shape (config recorded, DOLA minting disabled, source still registered).
        _phase8_wiringAssertions();

        // Story 096: everything but 6b verified - still NOT a verified cutover.
        require(
            !minterMovePending,
            string.concat(
                "verify: Phase6b: PENDING - the minter DOLA totalWithdrawal has not executed (story 096 lapsed-window resume: V2 is live, DOLA minting disabled). Phases 1-7, Phase 8's pending shape and ",
                vm.toString(verifiedUserCount),
                " per-user credits (incl. live V2 balances) verified. Re-initiate (initiate-dola-ys-withdrawal:broadcast), wait 6h, run :preview + :broadcast to complete 6b, then verify again"
            )
        );

        console.log("");
        console.log("=================================================");
        console.log("  CUTOVER VERIFIED ON CHAIN: every phase 1-7 done-condition holds");
        console.log("=================================================");
        console.log("Antimatter:           ", address(antimatter));
        console.log("StableStakerV2:       ", address(v2));
        console.log("CrossVersionMigrator: ", address(migrator));
        console.log("sDOLA strategy:       ", address(sdolaStrategy));
        console.log("Per-user credits re-checked:", verifiedUserCount);
    }

    // =====================================================================
    //  Hydration (addresses + baselines only)
    // =====================================================================

    /// @dev `virtual` so the fork tests can inject the addresses of a fork-local cutover instead of reading
    ///      the real progress file. Loads addresses (each required to have code by `_loadAddress`), the
    ///      persisted minter baseline and the cutover start block. Nothing here is evidence of completion.
    function _hydrateDeployment() internal virtual {
        _loadProgressFile();
        uint256 envStart = vm.envOr("CUTOVER_START_BLOCK", uint256(0));
        if (envStart != 0) {
            console.log("  CUTOVER_START_BLOCK env override:", envStart);
            cutoverStartBlock = envStart;
        }
    }

    // =====================================================================
    //  Phase 1-3
    // =====================================================================

    function _verifyPhase1_v1Retired() internal view {
        console.log("\n=== verify Phase 1: V1 retired ===");
        require(_v1PauserIsOwner(), "verify: Phase1: V1 setPauser(OWNER) not on chain");
        require(_v1UnregisteredFromPauser(), "verify: Phase1: Pauser.unregister(V1) not on chain");
        require(_v1Paused(), "verify: Phase1: V1 pause not on chain");
        console.log("  V1 pauser OWNER, unregistered from Pauser, paused");
    }

    function _verifyPhase2_antimatter() internal view {
        console.log("\n=== verify Phase 2: Antimatter ===");
        require(
            address(antimatter) != address(0),
            "verify: Phase2: Antimatter deployment not on chain (no address in server/deployments/progress.stable-staker-v2-cutover.1.json)"
        );
        require(_doneAntimatterIdentity(), "verify: Phase2: Antimatter name/symbol/owner not on chain");
        require(address(antimatter.phUSD()) == PHUSD, "verify: Phase2: Antimatter.setPhUSD not on chain");
        require(_doneAntimatterWired(), "verify: Phase2: Antimatter.setPhUSDMinter not on chain");
        console.log("  Antimatter:", address(antimatter));
    }

    function _verifyPhase3_stakerV2() internal view {
        console.log("\n=== verify Phase 3: StableStakerV2 ===");
        require(
            address(v2) != address(0),
            "verify: Phase3: StableStakerV2 deployment not on chain (no address in the progress file)"
        );
        require(_doneStakerV2Identity(), "verify: Phase3: StableStakerV2 version/antimatter/owner not on chain");
        console.log("  StableStakerV2:", address(v2));
    }

    /// @dev Story 091: the sDOLA destination strategy. Address from the progress file only (code required by the
    ///      loader); every property from chain. V2 client + V2 buffer are Phase 4's `_donePoolClientSet` /
    ///      `_donePoolBufferCopied`, which read the destination. On THIS strategy the buffer target is ZERO
    ///      (`_targetBufferPct`), so Phase 4 here asserts `setAsideBufferSize(V2) == 0`, not V1's pct.
    function _verifyPhase3b_sdolaStrategy() internal view {
        console.log("\n=== verify Phase 3b: sDOLA destination strategy ===");
        require(
            address(sdolaStrategy) != address(0),
            "verify: Phase3b: sDOLA strategy deployment not on chain (no contracts.ERC4626YieldStrategySDOLA address in the progress file)"
        );
        require(
            _doneSdolaStrategyIdentity(),
            "verify: Phase3b: sDOLA strategy owner/underlyingToken/vault != OWNER/DOLA/sDOLA on chain"
        );
        require(
            _doneSdolaStrategyPauseWired(),
            "verify: Phase3b: sDOLA strategy setPauser(Pauser) + Pauser.register not on chain"
        );
        require(_doneSdolaStrategyWithdrawer(), "verify: Phase3b: sDOLA strategy setWithdrawer(SYA) not on chain");
        console.log("  sDOLA strategy:", address(sdolaStrategy));
    }

    // =====================================================================
    //  Phase 4-5
    // =====================================================================

    function _verifyPhase4_pools() internal view {
        console.log("\n=== verify Phase 4: V2 pools ===");
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            string memory sym = IERC20Metadata(t).symbol();
            require(_donePoolTokenAdded(t), string.concat("verify: Phase4: V2.addToken(", sym, ") not on chain"));
            require(_donePoolClientSet(t), string.concat("verify: Phase4: strategy.setClient(V2) for ", sym, " not on chain"));
            require(
                _donePoolStrategySet(t), string.concat("verify: Phase4: V2.setYieldStrategy(", sym, ") not on chain")
            );
            // Target pct, not V1's: zero on the sDOLA destination (DOLA), V1's pct on USDC / USDe.
            require(
                _donePoolBufferCopied(t),
                string.concat(
                    "verify: Phase4: setAsideBufferSize(V2) for ",
                    sym,
                    " != target on chain (ZERO on the sDOLA strategy, V1's pct elsewhere)"
                )
            );
            require(_donePoolRateSet(t), string.concat("verify: Phase4: V2.antimatterPerDay(", sym, ") not on chain"));
            console.log("  pool configured:", t, sym);
        }
    }

    function _verifyPhase5_mintRights() internal view {
        console.log("\n=== verify Phase 5: mint rights ===");
        require(_doneV2AntimatterMinter(), "verify: Phase5: Antimatter.setApprovedMinter(V2) not on chain");
        require(_doneV2PhusdMinter(), "verify: Phase5: phUSD.setMinter(V2) not on chain");
        if (GRANT_ANTIMATTER_PHUSD_MINT) {
            require(_doneAntimatterPhusdMinter(), "verify: Phase5: phUSD.setMinter(Antimatter) not on chain");
        }
        console.log("  V2 Antimatter + phUSD mint, Antimatter phUSD mint");
    }

    // =====================================================================
    //  Phase 6 - migration, race detection, exit-realization bound
    // =====================================================================

    function _verifyPhase6_migration() internal view {
        console.log("\n=== verify Phase 6: migration ===");
        require(
            address(migrator) != address(0),
            "verify: Phase6: CrossVersionMigrator deployment not on chain (no address in the progress file)"
        );
        require(_doneMigratorIdentity(), "verify: Phase6: CrossVersionMigrator oldStaker/newStaker/owner not on chain");
        require(_doneMigratorWired(), "verify: Phase6: setMigrator on V1 and V2 not on chain");

        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            address src = _sourceStrategyFor(t);
            address dst = _destinationStrategyFor(t);
            string memory sym = IERC20Metadata(t).symbol();
            require(
                _doneV1PoolMigrating(t), string.concat("verify: Phase6: V1 initiateMigration(", sym, ") not on chain")
            );

            // Live re-plan. After a clean cutover `migratable` is empty and only sub-cap stragglers remain.
            PoolPlan memory plan = _planPool(v1, t, dst);
            _requireNoUnmigratedStaker(t, sym, plan);
            require(
                plan.stragglerAmountTotal < _stragglerCap(t),
                string.concat(
                    "verify: Phase6: V1 straggler principal for ", sym, " is ", vm.toString(plan.stragglerAmountTotal),
                    ", at or above the dust cap - a non-dust V1 position was not migrated on chain"
                )
            );

            // Shared post-condition with the empty plan built from live state: per-user loop is a no-op, V1
            // stakerCount / totalStaked must equal the stragglers, V2 books == sum of its stakers, the lockstep, and
            // story 087's exit-realization bound on V1's immutable R / P (self-exit-proof, audit-33 L-06). The
            // self-exit-aware aggregate on V2's booked total needs logs and runs in `_verifyPerUserCredits`.
            _assertPoolPostMigration(
                v1, ICutoverStaker(address(v2)), t, src, dst, plan, _maxLossBps(src), _maxLossBps(dst), WEI_SLACK
            );
            console.log("  pool migrated (token / V1 stragglers):", t, plan.stragglers.length);
        }
    }

    /// @dev RACE DETECTION. A V1 stake that lands between forge's local planning pass and the Phase-1 pause
    ///      transaction is not in any broadcast `migrate` batch, so it stays on V1 - and Phase 7 then revokes
    ///      the V1 phUSD mint that its exit needs. The live plan shows it as migratable.
    function _requireNoUnmigratedStaker(address t, string memory sym, PoolPlan memory plan) internal pure {
        if (plan.migratable.length == 0) return;
        revert(
            string.concat(
                "verify: Phase6: migrate of V1 staker ", vm.toString(plan.migratable[0]), " (", sym, " amount ",
                vm.toString(plan.migratablePre[0]), ", ", vm.toString(plan.migratable.length),
                " unmigrated in this pool) not on chain - likely staked after planning and before the Phase-1 pause.",
                " REMEDIATION: re-grant the V1 phUSD mint (phUSD.setMinter(V1, true)) so their frozen pending phUSD can",
                " be minted, then migrate them via CrossVersionMigrator.migrate (or they call V1.userMigrate), then revoke",
                " the V1 mint again. Token: ", vm.toString(t)
            )
        );
    }

    // =====================================================================
    //  Phase 6b - minter collateral, SYA, retired autoDOLA source (story 092)
    // =====================================================================

    function _verifyPhase6b_minterMove() internal {
        console.log("\n=== verify Phase 6b: minter DOLA collateral, SYA, retired autoDOLA strategy ===");
        // Story 096 (audit-35 L-11): a lapsed-window resume finalizes V2 (Phase 7) while 6b waits for a re-initiated minter
        // window. That state is NOT a verified cutover: the 6b block is skipped here and `run()` reverts
        // `verify: Phase6b: PENDING` after the remaining phases and the live per-user checks have been verified.
        if (minterMovePending) {
            console.log("  Phase 6b PENDING (story 096) - 6b checks deferred; this run WILL end with verify: Phase6b: PENDING");
            return;
        }
        require(
            minterConfigRecorded && minterRecoveredRecorded && minterExecRecorded,
            "verify: Phase6b: minterMove records (pre-repoint minter config / execution record / recovered R) absent from the progress file - refusing to guess them"
        );
        require(
            _doneMinterWithdrawalExecuted(), "verify: Phase6b: autoDOLA totalWithdrawal(DOLA, minter) execution not on chain"
        );
        require(_doneMinterClientOnSdola(), "verify: Phase6b: sDOLA strategy setClient(minter) not on chain");
        require(_doneMinterApprovedSdola(), "verify: Phase6b: minter approveYS(DOLA, sDOLA strategy) not on chain");
        require(
            _doneMinterReseeded(),
            string.concat(
                "verify: Phase6b: minter noMintDeposit into the sDOLA strategy not on chain (principal below the bound of R ",
                vm.toString(minterRecovered), ")"
            )
        );
        require(
            _doneMinterRepointed(),
            "verify: Phase6b: minter registerStablecoin(DOLA, sDOLA strategy) with previous rate / decimals + maxMintPerDay + enabled restore not on chain"
        );
        require(_doneSyaListRepointed(), "verify: Phase6b: SYA addYieldStrategy(sDOLA strategy) / removeYieldStrategy(autoDOLA strategy) not on chain");
        require(_doneSourceWithdrawerRevoked(), "verify: Phase6b: autoDOLA strategy setWithdrawer(SYA, false) not on chain");
        require(_doneSdolaStrategyWithdrawer(), "verify: Phase6b: SYA is not a withdrawer on the sDOLA strategy");
        require(_sourceDolaRetirementStarted(), "verify: Phase6b: autoDOLA strategy setClient(V1 / minter, false) not on chain");
        require(_doneSourceDolaRetired(), "verify: Phase6b: autoDOLA strategy setPauser(OWNER) + Pauser.unregister + pause not on chain");
        _verifyPhase6b_minedRecovery();
        console.log("  minter DOLA -> sDOLA strategy (R / minter principal):", minterRecovered, sdolaStrategy.principalOf(DOLA, PHUSD_STABLE_MINTER));
    }

    /// @dev Story 094 (audit-35 L-09). The recorded `minterRecovered` can be a forge local-pass value, so it proves nothing
    ///      about what mined. Two chain-side checks instead:
    ///        1. OWNER RESIDUAL: OWNER's DOLA is exactly its persisted pre-execution balance - no collateral left on the EOA
    ///           (the excess branch, mined R above the re-seeded amount).
    ///        2. MINED-R BOUND: the minter's sDOLA principal is within the destination loss bound of the R the execute
    ///           actually delivered, summed from DOLA `Transfer(autoDOLA strategy -> OWNER)` logs since the cutover start
    ///           block. The lower side only: organic DOLA mints after the repoint only add principal.
    function _verifyPhase6b_minedRecovery() internal {
        require(
            IERC20Metadata(DOLA).balanceOf(OWNER) == ownerDolaBeforeExec,
            string.concat(
                "verify: Phase6b: OWNER DOLA residual - OWNER holds ", vm.toString(IERC20Metadata(DOLA).balanceOf(OWNER)),
                " DOLA, expected its pre-execution balance ", vm.toString(ownerDolaBeforeExec),
                " (minter collateral left on the EOA, or OWNER's DOLA moved since)"
            )
        );
        require(
            cutoverStartBlock != 0 && cutoverStartBlock <= block.number,
            "verify: Phase6b: no usable cutover start block for the mined-R Transfer scan"
        );
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = ERC20_TRANSFER_TOPIC;
        topics[1] = bytes32(uint256(uint160(YS_DOLA)));
        topics[2] = bytes32(uint256(uint160(OWNER)));
        CutoverLog[] memory logs = _fetchTopicLogs(DOLA, topics);
        uint256 minedR;
        for (uint256 i = 0; i < logs.length; i++) {
            require(logs[i].data.length >= 32, "verify: Phase6b: malformed DOLA Transfer log");
            minedR += abi.decode(logs[i].data, (uint256));
        }
        require(
            logs.length > 0 && minedR > 0,
            "verify: Phase6b: no DOLA Transfer(autoDOLA strategy -> OWNER) since the cutover start block - the mined R is unknown"
        );
        uint256 principal = sdolaStrategy.principalOf(DOLA, PHUSD_STABLE_MINTER);
        require(
            principal + minedR * _maxLossBps(address(sdolaStrategy)) / CUTOVER_MAX_BPS + WEI_SLACK >= minedR,
            string.concat(
                "verify: Phase6b: minter principal on the sDOLA strategy below the bound of the MINED R (principal ",
                vm.toString(principal), ", mined R ", vm.toString(minedR), ", recorded R ", vm.toString(minterRecovered), ")"
            )
        );
        verifiedMinedRecovered = minedR;
        verifiedMinedTransfers = logs.length;
        console.log("  OWNER DOLA residual 0; mined R (Transfer logs) / transfers:", minedR, logs.length);
    }

    // =====================================================================
    //  Phase 7 - finalize
    // =====================================================================

    function _verifyPhase7_finalize() internal view {
        console.log("\n=== verify Phase 7: finalize ===");
        for (uint256 i = 0; i < tokens.length; i++) {
            address ys = _destinationStrategyFor(tokens[i]);
            require(
                _doneBufferRecipientV2(ys),
                string.concat("verify: Phase7: setSetAsideBufferRecipient(V2) not on chain for strategy ", vm.toString(ys))
            );
        }
        require(_v1MintRevoked(), "verify: Phase7: phUSD.setMinter(V1, false) revoke not on chain");
        // Phase 7 re-runs the V1 retirement triple as a backstop; Phase 1's checks above already cover it.
        // Order on chain (story 087, audit-33 L-05): V2 setPauser(Pauser) -> unpause -> register, so V2 was never
        // registered while paused; the end state checked here is the same either way, and the registrant sweep
        // below is what proves the breaker is live now.
        require(_doneV2PauseWired(), "verify: Phase7: V2 setPauser(Pauser) + Pauser.register(V2) not on chain");
        require(
            _doneAntimatterPauseWired(), "verify: Phase7: Antimatter setPauser(Pauser) + Pauser.register(Antimatter) not on chain"
        );
        require(_doneV2Unpaused(), "verify: Phase7: V2 unpause not on chain");
        require(_doneClaimStillDisabled(), "verify: Phase7: V2 claimEnabled is true - must stay false");
        _requireRegistrantsPausable();
        console.log("  buffer recipients, V1 mint revoked, V2/Antimatter pause wiring, V2 unpaused");
    }

    /// @dev Story 084's registrant sweep, restated with verifier messages (Phase 8 repeats it).
    function _requireRegistrantsPausable() internal view {
        address[] memory registrants = IPauserRegistry(PAUSER).getPausableContracts();
        for (uint256 i = 0; i < registrants.length; i++) {
            address r = registrants[i];
            require(
                IPausableLike(r).pauser() == PAUSER,
                string.concat("verify: Phase7: Pauser registrant pauser != Pauser (bricks global pause): ", vm.toString(r))
            );
            require(
                !IPausableLike(r).paused(),
                string.concat("verify: Phase7: Pauser registrant already paused (bricks global pause): ", vm.toString(r))
            );
        }
    }

    // =====================================================================
    //  Per-user credit re-check from events
    // =====================================================================

    function _verifyPerUserCredits() internal {
        console.log("\n=== verify per-user credits (MigratedOut -> DepositedFor) ===");
        require(
            cutoverStartBlock != 0,
            "verify: per-user: no cutover start block (baselines.cutoverStartBlock absent and CUTOVER_START_BLOCK unset)"
        );
        require(cutoverStartBlock <= block.number, "verify: per-user: cutover start block is in the future");
        if (v2LiveBeforeMinterMove && !minterMovePending) {
            console.log("  story 096: V2 went live before Phase 6b completed (minterMove.v2LiveBeforeMinterMove) - live");
            console.log("  V2 userInfo >= credited and V2 totalStaked >= floor SKIPPED (checked on the pending-state verify);");
            console.log("  event-based credit checks (DepositedFor per MigratedOut, loss bound, vacuity guard) still enforced");
        }

        CutoverEvent[] memory outs = _decode(_fetchLogs(STABLE_STAKER_V1, MIGRATED_OUT_TOPIC));
        CutoverEvent[] memory selfExits = _decode(_fetchLogs(STABLE_STAKER_V1, USER_MIGRATED_TOPIC));
        CutoverEvent[] memory deposits = _decode(_fetchLogs(address(v2), DEPOSITED_FOR_TOPIC));
        console.log("  events (MigratedOut / UserMigrated / DepositedFor):", outs.length, selfExits.length, deposits.length);

        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint256 matched = _checkPoolCredits(t, outs, selfExits, deposits);

            // Vacuity guard: a pool that owed principal to V2 must show at least one migrated credit, so an empty
            // log fetch (wrong start block, a silently truncating RPC) cannot pass. Story 087 sibling sweep: keyed
            // on the principal due NET OF SELF-EXITS, not on `v2.stakerCount` - organic V2 stakes (a quantity any
            // user moves) must not make a pool whose V1 stakers ALL self-exited look like a vacuous fetch. An empty
            // fetch also yields no `UserMigrated` rows, so it still trips this guard.
            (uint256 realized, uint256 principalSnapshot) = v1.migrationInfo(t);
            (,,, uint256 v1Staked) = v1.poolInfo(t);
            uint256 selfExited = _selfExitedPrincipalUpperBound(
                t, selfExits, principalSnapshot, realized < principalSnapshot ? realized : principalSnapshot
            );
            // Below the 1-cent straggler cap the "due" can be all zero-credit dust, which never deposits.
            if (principalSnapshot > v1Staked + selfExited + _stragglerCap(t)) {
                require(
                    matched > 0,
                    string.concat(
                        "verify: per-user: no MigratedOut/DepositedFor pair found for ",
                        IERC20Metadata(t).symbol(),
                        " although principal moved - check the cutover start block"
                    )
                );
            }
            verifiedUserCount += matched;
            console.log("  per-user credits OK (token / users):", t, matched);

            _requirePoolAggregateNetOfSelfExits(t, outs, selfExits);
        }
    }

    function _checkPoolCredits(
        address t,
        CutoverEvent[] memory outs,
        CutoverEvent[] memory selfExits,
        CutoverEvent[] memory deposits
    ) internal view returns (uint256 matched) {
        uint256 bps = _perUserLossBpsFor(t); // story 091: source + destination, once when equal
        for (uint256 j = 0; j < outs.length; j++) {
            CutoverEvent memory o = outs[j];
            if (o.token != t || o.amount == 0) continue;
            if (_hasEvent(selfExits, t, o.user)) continue; // V1.userMigrate: paid to the wallet, never to V2

            (bool found, uint256 credited) = _sumFor(deposits, t, o.user);
            require(
                found,
                string.concat(
                    "verify: per-user: V2 DepositedFor for user ", vm.toString(o.user), " (credit ", vm.toString(o.amount),
                    ") not on chain"
                )
            );
            uint256 loss = o.amount > credited ? o.amount - credited : 0;
            require(
                loss <= o.amount * bps / CUTOVER_MAX_BPS + WEI_SLACK,
                string.concat(
                    "verify: per-user: user ", vm.toString(o.user), " credit ", vm.toString(o.amount), " -> credited ",
                    vm.toString(credited), " exceeds the strategy loss bound"
                )
            );
            matched++;
            // Story 096: V2 went live before 6b completed - the live balance comparison ran on the pending-state verify.
            if (v2LiveBeforeMinterMove && !minterMovePending) continue;
            (uint256 held,) = v2.userInfo(t, o.user);
            require(
                held >= credited,
                string.concat(
                    "verify: per-user: V2 userInfo for ", vm.toString(o.user), " is ", vm.toString(held),
                    " < credited ", vm.toString(credited)
                )
            );
        }
    }

    /// @dev Story 087 (audit-33 L-06, option b), defence in depth behind the realization bound. See the contract
    ///      NatSpec, LOSS GATES AND SELF-EXITS (3). `nMigrated` counts this pool's non-self-exit `MigratedOut` rows
    ///      (zero-credit users included), one `WEI_SLACK` each.
    function _requirePoolAggregateNetOfSelfExits(
        address t,
        CutoverEvent[] memory outs,
        CutoverEvent[] memory selfExits
    ) internal view {
        (uint256 R, uint256 P) = ICutoverStaker(STABLE_STAKER_V1).migrationInfo(t);
        uint256 S = R < P ? R : P;
        require(S > 0, "verify: aggregate: V1 realized nothing for a Migrating pool (min(R, P) == 0)");
        (,,, uint256 v1Staked) = ICutoverStaker(STABLE_STAKER_V1).poolInfo(t);
        (,,, uint256 v2Staked) = v2.poolInfo(t);

        uint256 selfExited = _selfExitedPrincipalUpperBound(t, selfExits, P, S);
        uint256 nMigrated;
        for (uint256 j = 0; j < outs.length; j++) {
            if (outs[j].token == t && !_hasEvent(selfExits, t, outs[j].user)) nMigrated++;
        }
        uint256 due = P > v1Staked + selfExited ? P - v1Staked - selfExited : 0;
        uint256 floor = due * (CUTOVER_MAX_BPS - _perUserLossBpsFor(t)) / CUTOVER_MAX_BPS; // story 091: same rule as per user
        uint256 slack = nMigrated * WEI_SLACK;
        floor = floor > slack ? floor - slack : 0;
        console.log("  aggregate net of self-exits (token / floor / V2 totalStaked):", t, floor, v2Staked);
        console.log("    P / V1 stragglers / self-exited principal (upper bound):", P, v1Staked, selfExited);
        if (v2LiveBeforeMinterMove && !minterMovePending) {
            // Story 096: V2 was live for >= 6h before 6b completed; migrated users may have withdrawn. The aggregate ran
            // on the pending-state verify chained immediately after V2 went live.
            console.log("    SKIPPED (story 096 v2LiveBeforeMinterMove): live V2 total vs floor - checked on the pending-state verify");
            return;
        }
        require(
            v2Staked >= floor,
            string.concat(
                "verify: aggregate: V2 booked total ", vm.toString(v2Staked), " below the principal due net of self-exits (floor ",
                vm.toString(floor), ") for ", IERC20Metadata(t).symbol()
            )
        );
    }

    /// @dev Sum over this pool's `UserMigrated` rows of an UPPER bound on each exiter's V1 principal. V1 credits
    ///      `credit = floor(amount * S / P)`, so `amount * S < (credit + 1) * P`, i.e.
    ///      `amount <= ceil((credit + 1) * P / S)`. Rounding up only ever LOOSENS the floor above.
    function _selfExitedPrincipalUpperBound(address t, CutoverEvent[] memory selfExits, uint256 P, uint256 S)
        internal
        pure
        returns (uint256 total)
    {
        for (uint256 k = 0; k < selfExits.length; k++) {
            if (selfExits[k].token != t) continue;
            if (S == 0) return P; // nothing realized: any exiter may have held the whole snapshot
            total += ((selfExits[k].amount + 1) * P + S - 1) / S;
        }
    }

    function _hasEvent(CutoverEvent[] memory evs, address t, address user) internal pure returns (bool) {
        for (uint256 k = 0; k < evs.length; k++) {
            if (evs[k].token == t && evs[k].user == user) return true;
        }
        return false;
    }

    function _sumFor(CutoverEvent[] memory evs, address t, address user)
        internal
        pure
        returns (bool found, uint256 total)
    {
        for (uint256 k = 0; k < evs.length; k++) {
            if (evs[k].token == t && evs[k].user == user) {
                found = true;
                total += evs[k].amount;
            }
        }
    }

    /// @dev Decodes `(indexed token, indexed user, uint256 amount, ...)` rows. `MigratedOut` carries a
    ///      second data word (reward), ignored here.
    function _decode(CutoverLog[] memory logs) internal pure returns (CutoverEvent[] memory evs) {
        evs = new CutoverEvent[](logs.length);
        for (uint256 i = 0; i < logs.length; i++) {
            require(logs[i].topics.length >= 3 && logs[i].data.length >= 32, "verify: per-user: malformed log");
            evs[i] = CutoverEvent({
                token: address(uint160(uint256(logs[i].topics[1]))),
                user: address(uint160(uint256(logs[i].topics[2]))),
                amount: abi.decode(logs[i].data, (uint256))
            });
        }
    }

    /// @dev Live `eth_getLogs` over `[cutoverStartBlock, block.number]` in `LOG_CHUNK_BLOCKS` windows.
    ///      `virtual` so fork tests can feed logs recorded from a fork-local cutover (a fork's RPC cannot
    ///      return logs emitted by locally executed transactions).
    function _fetchLogs(address emitter, bytes32 topic0) internal virtual returns (CutoverLog[] memory out) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = topic0;
        return _fetchTopicLogs(emitter, topics);
    }

    /// @dev Story 094: the same chunked live fetch filtered on positional topics (topic0, topic1, ...), so a Transfer scan
    ///      on a busy token asks the RPC only for the rows it needs. `virtual` for the same test seam as `_fetchLogs`.
    function _fetchTopicLogs(address emitter, bytes32[] memory topics) internal virtual returns (CutoverLog[] memory out) {
        for (uint256 from = cutoverStartBlock; from <= block.number; from += LOG_CHUNK_BLOCKS) {
            uint256 to = from + LOG_CHUNK_BLOCKS - 1;
            if (to > block.number) to = block.number;
            VmSafe.EthGetLogs[] memory got = vm.eth_getLogs(from, to, emitter, topics);
            CutoverLog[] memory merged = new CutoverLog[](out.length + got.length);
            for (uint256 i = 0; i < out.length; i++) {
                merged[i] = out[i];
            }
            for (uint256 i = 0; i < got.length; i++) {
                merged[out.length + i] = CutoverLog({emitter: got[i].emitter, topics: got[i].topics, data: got[i].data});
            }
            out = merged;
        }
    }
}
