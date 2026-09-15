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
 *              `migrationInfo` - `min(R, P) * MAX_BPS >= P * (MAX_BPS - bps)`. It bounds the pre -> credit
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

        require(
            phusdBaselineRecorded,
            "verify: Phase0: persisted phUSD minter baseline (baselines.phusdMinterMask) absent from the progress file - refusing to re-derive it from post-broadcast state"
        );
        _phase0_preconditions();

        _verifyPhase4_pools();
        _verifyPhase5_mintRights();
        _verifyPhase6_migration();
        _verifyPhase7_finalize();
        _verifyPerUserCredits();

        // Absolute end-state wiring (view-only), including story 084's registrant sweep.
        _phase8_wiringAssertions();

        console.log("");
        console.log("=================================================");
        console.log("  CUTOVER VERIFIED ON CHAIN: every phase 1-7 done-condition holds");
        console.log("=================================================");
        console.log("Antimatter:           ", address(antimatter));
        console.log("StableStakerV2:       ", address(v2));
        console.log("CrossVersionMigrator: ", address(migrator));
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
            require(
                _donePoolBufferCopied(t), string.concat("verify: Phase4: setSetAsideBuffer(V2) for ", sym, " not on chain")
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
            address ys = _strategyFor(t);
            string memory sym = IERC20Metadata(t).symbol();
            require(
                _doneV1PoolMigrating(t), string.concat("verify: Phase6: V1 initiateMigration(", sym, ") not on chain")
            );

            // Live re-plan. After a clean cutover `migratable` is empty and only sub-cap stragglers remain.
            PoolPlan memory plan = _planPool(v1, t, ys);
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
            _assertPoolPostMigration(v1, ICutoverStaker(address(v2)), t, ys, plan, _maxLossBps(ys), WEI_SLACK);
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
    //  Phase 7 - finalize
    // =====================================================================

    function _verifyPhase7_finalize() internal view {
        console.log("\n=== verify Phase 7: finalize ===");
        for (uint256 i = 0; i < tokens.length; i++) {
            address ys = _strategyFor(tokens[i]);
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

        CutoverEvent[] memory outs = _decode(_fetchLogs(STABLE_STAKER_V1, MIGRATED_OUT_TOPIC));
        CutoverEvent[] memory selfExits = _decode(_fetchLogs(STABLE_STAKER_V1, USER_MIGRATED_TOPIC));
        CutoverEvent[] memory deposits = _decode(_fetchLogs(address(v2), DEPOSITED_FOR_TOPIC));
        console.log("  events (MigratedOut / UserMigrated / DepositedFor):", outs.length, selfExits.length, deposits.length);

        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            address ys = _strategyFor(t);
            uint256 matched = _checkPoolCredits(t, ys, outs, selfExits, deposits);

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

            _requirePoolAggregateNetOfSelfExits(t, ys, outs, selfExits);
        }
    }

    function _checkPoolCredits(
        address t,
        address ys,
        CutoverEvent[] memory outs,
        CutoverEvent[] memory selfExits,
        CutoverEvent[] memory deposits
    ) internal view returns (uint256 matched) {
        uint256 bps = _maxLossBps(ys);
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
            (uint256 held,) = v2.userInfo(t, o.user);
            require(
                held >= credited,
                string.concat(
                    "verify: per-user: V2 userInfo for ", vm.toString(o.user), " is ", vm.toString(held),
                    " < credited ", vm.toString(credited)
                )
            );
            matched++;
        }
    }

    /// @dev Story 087 (audit-33 L-06, option b), defence in depth behind the realization bound. See the contract
    ///      NatSpec, LOSS GATES AND SELF-EXITS (3). `nMigrated` counts this pool's non-self-exit `MigratedOut` rows
    ///      (zero-credit users included), one `WEI_SLACK` each.
    function _requirePoolAggregateNetOfSelfExits(
        address t,
        address ys,
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
        uint256 floor = due * (CUTOVER_MAX_BPS - _maxLossBps(ys)) / CUTOVER_MAX_BPS;
        uint256 slack = nMigrated * WEI_SLACK;
        floor = floor > slack ? floor - slack : 0;
        console.log("  aggregate net of self-exits (token / floor / V2 totalStaked):", t, floor, v2Staked);
        console.log("    P / V1 stragglers / self-exited principal (upper bound):", P, v1Staked, selfExited);
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
