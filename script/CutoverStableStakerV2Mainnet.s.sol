// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {IFlax as IFlaxAntimatter} from "@phUSD/IFlax.sol";
import {PhusdStableMinter} from "@phUSDMinter/PhusdStableMinter.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";
import {CrossVersionMigrator} from "stable-staker/CrossVersionMigrator.sol";
import {IStableStakerMigratable} from "stable-staker/interfaces/IStableStakerMigratable.sol";
import {IAntimatter} from "stable-staker/interfaces/IAntimatter.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {
    StableStakerCutoverCore,
    ICutoverStaker,
    ICutoverMigrator,
    ICutoverStrategy,
    ICutoverVault
} from "./helpers/StableStakerCutoverCore.sol";

/**
 * @title CutoverStableStakerV2Mainnet  (story 082)
 * @notice ONE resumable mainnet run that retires StableStakerV1 in favour of StableStakerV2 paying
 *         Antimatter. The Anvil rehearsal it mirrors is story 080's
 *         `DeployMocks._deployAntimatterAndStableStakerV2` + `_rehearseStableStakerCutover`.
 *
 * ================================= PHASES =================================================
 *   0  Preconditions (require-gated, no mutation). Live token list off V1, per-token reads,
 *      owners, V1 phUSD mint, PhusdStableMinter registration, strategy map, phUSD minter baseline.
 *      Story 092: the PhusdStableMinter's DOLA `totalWithdrawal` on the autoDOLA strategy (story 090's initiate) must be
 *      Initiated with `initiatedAt + 6h <= now < initiatedAt + 78h - WINDOW_SAFETY_MARGIN`; skipped once it has
 *      executed (minter principal on the autoDOLA strategy == 0). The minter's DOLA registration may point at the
 *      autoDOLA strategy (before the Phase 6b repoint) or the sDOLA strategy (after it); a retired DOLA source is
 *      accepted unpaused-check-free.
 *   1  Retire V1 for the window (story 084, audit L-04): setPauser(OWNER) -> Pauser.unregister(V1) ->
 *      pause(), each step state-gated. V1 is UNREGISTERED BEFORE it is paused so the permissionless
 *      global `Pauser.pause()` (which loops every registrant with no try/catch) is not bricked by V1.
 *      BREAKER LIVENESS (stories 084 + 087 + 088, audit L-04 / audit-33 L-05): `Pauser.pause()` never REVERTS
 *      after any transaction of the session EXCEPT ONE forced window - the single tx between
 *      `V1.setPauser(OWNER)` and `Pauser.unregister(V1)` (unregister requires V1.pauser() != Pauser, and a
 *      registered V1 whose pauser is OWNER reverts `only pauser`). A live breaker only pauses REGISTRANTS,
 *      though, and Phase 7 has two further one-tx COVERAGE gaps where a contract is unpaused, its pauser is
 *      already the Pauser, and it is not yet registered, so a global pause succeeds but MISSES it (story 088):
 *      V2 between its unpause and Pauser.register(V2), and Antimatter between its setPauser(Pauser) and
 *      Pauser.register(Antimatter). See HALTED RUNS below for why nothing is exposed and the remedy.
 *      The rule on both sides: never leave a
 *      registrant paused or un-pausable by the Pauser - unregister BEFORE pause (Phase 1), unpause BEFORE
 *      register (Phase 7). `test/CutoverStableStakerV2Mainnet.fork.t.sol` probes this per transaction.
 *      PREVIEW additionally proves the breaker with a simulated EYE-funded `Pauser.pause()` inside a
 *      state snapshot at: end of Phase 0 (V1-only tolerant), then STRICTLY after every phase 1..7 and after
 *      Phase 8 (log `GLOBAL_PAUSE|<stage>|SUCCEEDED|registered=<n>`, stages phase0, after-phase1 ..
 *      after-phase8).
 *   2  Deploy Antimatter (name "Antimatter", symbol "AM" - hard-coded in its constructor), owner
 *      OWNER; setPhUSD then setPhUSDMinter; read back.
 *   3  Deploy StableStakerV2(antimatter, OWNER); setPauser(OWNER) + pause() BEFORE any addToken.
 *   3b (story 091) Deploy the sDOLA DESTINATION strategy: preflight sDOLA asset() == DOLA and maxDeposit >= V1's
 *      DOLA principal; `new ERC4626YieldStrategy(OWNER, DOLA, SDOLA)` (address persisted in the progress file,
 *      recovered on resume, fail closed on an unidentified on-chain candidate); setPauser(Pauser) ->
 *      Pauser.register (registered while UNPAUSED, before any V2 deposit) -> setWithdrawer(SYA). Minter
 *      client wiring is NOT here (story 092).
 *   4  Per V1 token, on the DESTINATION strategy: addToken, strategy.setClient(V2), idle-balance guard,
 *      setYieldStrategy, setSetAsideBuffer(V2, <V1's pct on the SOURCE>), antimatterPerDay(C * 21 / 10),
 *      autoAnnihilateAvailable.
 *   5  Mint rights: Antimatter.setApprovedMinter(V2), phUSD.setMinter(V2), phUSD.setMinter(Antimatter)
 *      (see the Phase 5 NatSpec for why the third grant exists), two-sided minter delta.
 *   6  CrossVersionMigrator; setMigrator on both; per token: relinquish surplus + initiate on the SOURCE,
 *      plan (dust predicate) + batch-migrate into the DESTINATION, allow-list stragglers under a cap,
 *      post-conditions (exit bound on the source, per-user bound source + destination).
 *   6b (story 092) Minter collateral, SYA, retire the autoDOLA source - AFTER Phase 6 (V1 must be drained first:
 *      `_totalWithdraw` redeems pro-rata of ALL the strategy's shares). Record the minter's DOLA config (rate, decimals,
 *      enabled, maxMintPerDay) -> setStablecoinEnabled(DOLA, false) -> source.totalWithdrawal(DOLA, minter) EXECUTES
 *      (DOLA R lands on OWNER, bounded against the principal P) -> [BROADCAST LEG 1 ENDS HERE, story 094: progress status
 *      `awaiting_reseed`; after the execute mines, run :preview + :broadcast again - leg 2 reads the MINED R] ->
 *      sDOLA strategy setClient(minter) -> minter.approveYS -> OWNER approve ceil(1.5R) (only when the allowance is below R)
 *      + minter.noMintDeposit(sDOLA strategy, DOLA, R) (OWNER back to its pre-execution DOLA) ->
 *      registerStablecoin(DOLA, sDOLA strategy, same rate, same decimals) -> setMaxMintPerDay(previous) -> restore
 *      enabled -> SYA addYieldStrategy(sDOLA strategy) / removeYieldStrategy(autoDOLA strategy) -> source
 *      setWithdrawer(SYA, false) -> source setClient(V1 / minter, false) -> source setPauser(OWNER) ->
 *      Pauser.unregister(source) -> source pause(). Each step `if (!done) do();`, resumable; P / OWNER's pre-execution
 *      DOLA / R and the pre-repoint minter config are persisted in the progress file (`minterMove`). repoint set-aside buffer recipient on the DESTINATION, revoke V1 phUSD mint, V1 retirement BACKSTOP (the
 *      same state-gated triple Phase 1 ran; normally every step skips - story 083/084), then (story 087,
 *      audit-33 L-05) V2 setPauser(Pauser) -> V2 unpause -> Pauser.register(V2) -> Antimatter
 *      setPauser(Pauser) -> Pauser.register(Antimatter). V2 is never registered while paused. Consequence
 *      (story 088): after the V2 unpause and after the Antimatter setPauser, that contract is briefly
 *      unpaused, Pauser-owned and unregistered - a global pause misses it for one tx (HALTED RUNS).
 *   8  Wiring assertions (both modes), incl. a static sweep: every Pauser registrant unpaused with
 *      pauser == Pauser (story 084, audit L-03).
 *   -  PREVIEW_MODE only: smoke tests (Antimatter mint-revocation proof, V2 stake/withdraw on every
 *      pool, autoAnnihilate on DOLA). Prank-only, never broadcast.
 *
 * ================================ RUNNING IT ==============================================
 *   npm run stable-staker-v2-cutover:preview     (impersonates OWNER on live mainnet state)
 *   npm run stable-staker-v2-cutover:broadcast   (Ledger m/44'/60'/46'/0/0; chains :verify && :preview)
 *
 *   TWO BROADCAST LEGS (story 094, audit-35 L-09). The broadcast that executes the minter's DOLA totalWithdrawal ends
 *   right after that execute (progress status `awaiting_reseed`); its patch tail stops loudly by design. Once the execute
 *   has mined, run :preview then :broadcast again: leg 2's local pass reads the MINED R, re-seeds it and finishes.
 *
 *   OWNER ETH (story 087, audit-33 L-07): broadcast mode refuses to start unless OWNER's ON-CHAIN balance (read
 *   with `eth_getBalance`, never the in-EVM one - forge pre-funds the script sender) is at least
 *   CUTOVER_GAS_BUDGET * CUTOVER_GAS_PRICE_WEI * 12 / 10, the price every transaction is signed at.
 *   `:broadcast` exports CUTOVER_GAS_PRICE_WEI (default 300000000 = 0.3 gwei) and passes the same value to
 *   `--with-gas-price`. Preview logs the budget and the surplus/shortfall (`ETH_BUDGET|...`) and never reverts.
 *
 *   npm run stable-staker-v2-cutover:verify      (story 086: read-only, asserts every phase on chain)
 *
 *   PREVIEW IS NOT THE POST-BROADCAST VERIFICATION (story 086, audit L-02). Preview READS the progress
 *   file when one exists (never writes it) and re-enters this whole run() under a prank, and every phase
 *   has the form `if (!done) do();` - so a step that never landed on chain is silently PERFORMED inside
 *   the simulation and Phase 8 then asserts the simulated state. The post-broadcast verification is
 *   `script/VerifyStableStakerV2Cutover.s.sol`, which requires each phase's done-condition from live
 *   chain state and never mutates. The done-conditions are the `_done*` / `_v1*` predicates below,
 *   shared by this script's phase gates and by the verifier so the two cannot drift. After verify has
 *   passed, preview is a smoke test of the live deployment.
 *
 *   The progress file is written during forge's LOCAL execution pass, before any transaction is
 *   sent. After a crashed broadcast it can therefore name a contract that never landed. Every
 *   address loaded from it is required to have code; one that does not aborts with an instruction
 *   to trim the file to the on-chain-confirmed deployments (run-latest.json receipts + `cast nonce`).
 *
 *   HALTED RUNS (stories 084 + 087): the ONE halt point that leaves the global permissionless pause DEAD is
 *   between Phase 1's `V1.setPauser(OWNER)` and `Pauser.unregister(V1)` (or a V1 paused manually while still
 *   registered). Do not walk away from such a halt: resume it (Phase 1 converges from any partial state), or
 *   at minimum have OWNER call `Pauser.unregister(V1)`. A preview on such a state reports
 *   `GLOBAL_PAUSE|phase0|BROKEN_BY_V1`. Every Phase 7 halt point keeps `Pauser.pause()` from reverting, because
 *   V2 is unpaused before it is registered (audit-33 L-05), and a resume from any of them converges.
 *
 *   PHASE 3b HALT POINTS (story 091, 088's pattern). Nothing in Phase 3b makes `Pauser.pause()` revert: the new
 *   strategy is never paused and is registered only once its pauser is the Pauser. Halts:
 *     (a) after the CREATE, before setPauser(Pauser): the strategy's pauser is address(0), it is unregistered, and it
 *         has NO client and NO principal (V2 is paused and not wired to it until Phase 4). A global pause misses it,
 *         which exposes nothing - there is nothing to deposit or withdraw. Resume recovers it from the progress file.
 *     (b) after setPauser(Pauser), before Pauser.register: the one-tx COVERAGE gap shape (unpaused, pauser ==
 *         Pauser, unregistered), again with no client and no principal - nothing is exposed. REMEDY if needed:
 *         OWNER Pauser.register(<strategy>) (valid, its pauser is already the Pauser), or simply resume.
 *     (c) after register, before setWithdrawer(SYA): fully under the breaker; SYA cannot yet skim it (no yield yet).
 *   V2 never deposits into an unregistered strategy: Phase 4 requires the destination registered before
 *   `setYieldStrategy`, and Phase 6 is the first deposit.
 *
 *   PHASE 7 COVERAGE GAPS (story 088). Two Phase 7 halt points leave ONE contract outside the global pause:
 *     (a) V2, halted after its unpause and before Pauser.register(V2): V2 is unpaused, pauser == Pauser,
 *         unregistered. `Pauser.pause()` loops registrants only, so it succeeds and leaves V2 unpaused.
 *     (b) Antimatter, halted after its setPauser(Pauser) and before Pauser.register(Antimatter): same shape.
 *   Why (a) exposes nothing: every strategy V2 routes through - the sDOLA destination (Phase 3b registers it and
 *   Phase 4 re-asserts it) plus YS_USDC and YS_USDE (Phase 0 asserts them) - is registered with the Pauser with
 *   pauser == Pauser, and every V2 user action reverts under a strategy pause -
 *   stake -> strategy.deposit and withdraw / autoAnnihilate / emergencyWithdraw -> strategy.withdraw are
 *   whenNotPaused (the underwater relinquishPrincipal edge needs idle V2 balance, ~0 after migration); claim
 *   also needs claimEnabled (false); userMigrate needs a Migrating V2 pool (all Active). For (b) Antimatter's
 *   pause gates only annihilate.
 *   REMEDY at either gap (OWNER): calling pause() on the contract directly REVERTS - it is onlyPauser
 *   (V2 reverts "StableStaker: only pauser"; Antimatter reverts with the custom error OnlyPauser()) and
 *   the pauser is already the Pauser. Instead run setPauser(OWNER) then
 *   pause() on that contract (setPauser is onlyOwner). Alternative: OWNER calls Pauser.register(<contract>)
 *   (valid, the pauser is already the Pauser) and then triggers the global pause (burns EYE).
 *   RESUME HAZARD after the setPauser(OWNER) remedy on V2: the finalized marker (`_doneCutoverFinalized`,
 *   V2 pauser == Pauser) is cleared, so a resume re-runs Phase 7 from the pauser hand-back and UNPAUSES V2.
 *   Do not resume until the incident is cleared; then a resume converges.
 *
 *   PHASE 6b HALT POINTS (story 092, 088's pattern). Timing first: the minter's `totalWithdrawal` executes only inside
 *   [initiatedAt + 6h, initiatedAt + 78h] and is whenNotPaused, so a halt that outlives the window (or a global pause
 *   during it) leaves the step undone: wait for expiry, rerun `initiate-dola-ys-withdrawal:broadcast`, wait 6h, resume.
 *     (a) after setStablecoinEnabled(DOLA, false), before the execute: DOLA minting is off (V2's autoAnnihilate(DOLA)
 *         reverts - V2 is still paused, so nobody can call it). Nothing is exposed. Resume.
 *     (b) after the execute, before noMintDeposit: THE MINTER'S DOLA COLLATERAL SITS ON THE OWNER EOA. Since story 094
 *         (audit-35 L-09) this is the DELIBERATE end of every broadcast that executes: forge's local pass computes R
 *         before the execute mines at the live autoDOLA price, so an amount signed in the same session could strand
 *         dust on OWNER (mined R higher) or revert noMintDeposit (mined R lower). The leg writes progress status
 *         `awaiting_reseed` and stops. After the execute has mined, run :preview then :broadcast (leg 2) promptly:
 *         its local pass re-derives R ON CHAIN as OWNER's DOLA balance minus the persisted pre-execution balance
 *         (`minterMove.ownerDolaBeforeExec`), bounded against the persisted P, and re-seeds exactly that. Do not move
 *         OWNER's DOLA before leg 2. The script FAILS CLOSED if the progress file lacks the execution record or OWNER
 *         holds less DOLA than before execution. :verify then requires OWNER's DOLA == ownerDolaBeforeExec and bounds
 *         the minter's sDOLA principal against the DOLA Transfer the execute actually mined.
 *     (c) after setClient / approveYS / the OWNER approve, before noMintDeposit: same as (b); every call is idempotent,
 *         and an OWNER allowance that already covers R is kept (not zeroed or re-approved).
 *     (d) after noMintDeposit, before registerStablecoin: the collateral is in the sDOLA strategy booked to the minter,
 *         DOLA minting is still off. Nothing is exposed.
 *     (e) after registerStablecoin, before setMaxMintPerDay: ONE-TX GAP - registration re-enables DOLA minting with
 *         maxMintPerDay reset to 0 (uncapped). Mints land in the correct (sDOLA) strategy; only the daily cap is
 *         missing. The previous cap is persisted (`minterMove.prevMaxMintPerDay`) and a resume restores it.
 *     (f) during the SYA / withdrawer / client steps: SYA may list both strategies or neither for a tx; `claim` skims
 *         every listed strategy and the source is still unpaused, so nothing reverts.
 *     (g) between source setPauser(OWNER) and Pauser.unregister(source): the SECOND forced dead window of the session
 *         (Phase 1's V1 rule, audit L-04): the global `Pauser.pause()` REVERTS for one tx because a registrant's pauser
 *         is OWNER. The source holds no client and no principal by then. Do not walk away. REMEDY FIRST: OWNER calls
 *         Pauser.unregister(<autoDOLA strategy>) (valid: its pauser is already OWNER). A PREVIEW on the un-remedied halt
 *         REVERTS `globalPause(phase0)` naming 0x1760 - deliberately not tolerated like V1's Phase 1 halt, because the
 *         source would stay unpausable through every strict stage up to Phase 6b. A broadcast resume (no simulation)
 *         converges either way; after the remedy, preview and resume both converge.
 *     (h) after unregister, before pause: the source is unregistered and unpaused with no clients - nothing to pause.
 *   Pausing the source makes its `totalWithdrawal` unusable; the minter's withdrawal has already executed by then.
 */
contract CutoverStableStakerV2Mainnet is Script, StdCheats, StableStakerCutoverCore {
    // =====================================================================
    //  LIVE MAINNET ADDRESSES (server/deployments/mainnet-addresses.ts; each re-read on-chain
    //  during planning 2026-09-14 @ block ~25975061; Phase 0 re-asserts them at execution time)
    // =====================================================================
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant STABLE_STAKER_V1 = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant PHUSD_STABLE_MINTER = 0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C;

    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    /// @dev The SOURCE strategy map (`_sourceStrategyFor`, V1's exit side) is HARD-CODED rather than read off V1
    ///      because `initiateMigration` clears `V1.yieldStrategy(token)`; a resume leg past initiation could
    ///      otherwise not recover it. Phase 0 asserts each entry against V1 (while Active). The DESTINATION map
    ///      (`_destinationStrategyFor`, V2's side) is the same for USDC / USDe; DOLA goes to the sDOLA strategy
    ///      Phase 3b deploys (story 091), which cannot be a constant.
    address public constant YS_DOLA = 0x1760E05356Ec1FBBA159C730781dCfB9920524e2; // ERC4626YieldStrategy (autoDOLA)
    address public constant YS_USDC = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83; // ERC4626YieldStrategy (autoUSDC)
    address public constant YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95; // ERC4626MarketYieldStrategy (sUSDe, 30 bps)
    /// @dev Story 091: Inverse Finance sDOLA (ERC4626 over DOLA), the vault of V2's DOLA destination strategy.
    ///      Read on-chain 2026-09-16: asset() == DOLA, maxDeposit == type(uint256).max. Phase 3b re-asserts both.
    address public constant SDOLA = 0xb45ad160634c528Cc3D2926d9807104FA3157305;

    // ---- phUSD minter candidate set (story 076 two-sided delta). APPEND-ONLY: bit i == index i. ----
    address public constant PHLIMBO_V3 = 0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca;
    address public constant HOOK_EYE = 0x0F05c34d458dd8953864a56857a2bb67ecb22683;
    address public constant HOOK_SCX = 0xfe4Ed16a8450c76768e1EB5FF8292806E2204a2A;
    address public constant HOOK_FLX = 0x8F48E5431814FfaC9c35cf934Aa2556A946Fb33C;
    address public constant HOOK_POOLER = 0x4A26ad83306a2F17155799fDD9449f77eb3F8bD7;
    address public constant HOOK_RATCHET = 0x09AceB96337df1316e0D2d7EEEa44d754D1f8d05;
    address public constant STABLE_YIELD_ACCUMULATOR = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;
    uint256 public constant PHUSD_MINTER_BIT_V1 = 0;

    // =====================================================================
    //  CONFIGURATION (every value sourced; see CLAUDE.md "Configuration Safety")
    // =====================================================================
    /// @dev User requirement (story 082): V2 Antimatter emission = 2.1x the token's CURRENT V1 phUSD
    ///      rate. C is the on-chain floored `phusdPerSecond * 86400`; the product floors (protocol-favouring).
    uint256 public constant RATE_NUMERATOR = 21;
    uint256 public constant RATE_DENOMINATOR = 10;
    /// @dev Page size for `CrossVersionMigrator.migrate`. Story cap <= 50. Live counts at planning were
    ///      9 / 13 / 7, so every pool fits one batch; 25 mirrors story 076's MIGRATE_CHUNK.
    uint256 public constant MIGRATE_CHUNK = 25;
    /// @dev Straggler cap: summed straggler V1 principal must be < 1 cent, token-decimal aware.
    uint256 public constant STRAGGLER_CAP_CENTS = 1;
    /// @dev Absolute rounding slack, additive to the bps bound (`_maxLossBps`): per user in the per-user bound, once
    ///      per pool in the story-087 exit-realization bound (a single V1 exit). Story 083 raised it
    ///      from 080's 2-wei floor to 1000 wei: simulated round trips (V1 exit + V2 re-deposit) lost more
    ///      than 2 wei per user and tripped the Phase 6 post-migration assert. 1000 wei is at most $0.001
    ///      per user even on a 6-decimal token (USDC), so the looser bound is economically negligible.
    uint256 public constant WEI_SLACK = 1000;
    /// @dev Per-user loss bound on the 1:1 ERC4626 strategies (autoDOLA, autoUSDC). The story planned 0 bps,
    ///      but the live autopools are NOT loss-free on either leg. Story 082's planning preview (block
    ///      ~25975061) measured autoDOLA ~0.034 bps and autoUSDC ~0.86 bps per round trip, and set 2 bps.
    ///      Story 087's live preview (block 25985945) then measured the autoDOLA EXIT leg alone at ~1.035 bps,
    ///      and the full per-user round trip failed the Phase 6 check at 2 bps: the autopools' valuation spread
    ///      moves day to day. Story 088 (human request) raises it to 5 bps: ~4.8x the worst single-leg
    ///      observation and ~5.8x the autoUSDC round trip, so the spread does not trip the run, while a real
    ///      vault loss (a haircut beyond 5 bps + WEI_SLACK) still stops it. Script-only: never passed to a
    ///      constructor or setter, nothing on chain stores it; the market strategy bound (`_maxLossBps`) is
    ///      unaffected.
    uint256 public constant ERC4626_MAX_LOSS_BPS = 5;

    /// @dev Story 092. The autoDOLA strategy's two-phase `totalWithdrawal` delays, lib/vault/src/AYieldStrategy.sol
    ///      `WAITING_PERIOD` / `EXECUTION_WINDOW` (vault story-048; story 090 verified them against the 0x1760 bytecode).
    ///      Phase 0 re-asserts both on chain. Execution is valid while `initiatedAt + 6h <= now <= initiatedAt + 78h`.
    uint256 public constant DOLA_WITHDRAWAL_WAITING_PERIOD = 6 hours;
    uint256 public constant DOLA_WITHDRAWAL_EXECUTION_WINDOW = 72 hours;
    /// @dev Story 092. Phase 0 refuses to START the session unless at least this long remains before the minter's
    ///      execution window closes. Phase 6b's execute is transaction ~40 of a `--slow` Ledger session (46 transactions,
    ///      each needing a physical confirmation; story 087 measured the rehearsal) and a halted session may need a
    ///      resume leg; 6 hours covers a slow session plus one halt-and-resume with room to spare, and still leaves a
    ///      66-hour start window. Too late to start means: wait for expiry, re-initiate, wait 6h.
    uint256 public constant WINDOW_SAFETY_MARGIN = 6 hours;
    /// @dev AYieldStrategy.WithdrawalStatus ordinals (enum { None, Initiated, Executable, Expired }).
    uint8 internal constant WITHDRAWAL_INITIATED = 1;
    uint8 internal constant WITHDRAWAL_EXECUTABLE = 2;

    string constant PROGRESS_FILE = "server/deployments/progress.stable-staker-v2-cutover.1.json";
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    // =====================================================================
    //  RUN STATE
    // =====================================================================
    bool public isPreview;
    Antimatter public antimatter;
    StableStakerV2 public v2;
    CrossVersionMigrator public migrator;
    /// @dev Story 091: V2's DOLA destination, `ERC4626YieldStrategy(OWNER, DOLA, SDOLA)`, deployed in Phase 3b and
    ///      persisted in the progress file as `contracts.ERC4626YieldStrategySDOLA`.
    ERC4626YieldStrategy public sdolaStrategy;
    address[] public tokens;

    bool public phusdBaselineRecorded;
    uint256 public phusdMaskAtPhase0;
    uint256 public phusdMintVersionAtPhase0;

    mapping(address => uint256) public cPerDay; // token -> V1 phUSD per day (floored)
    mapping(address => uint256) public v1BufferPct; // token -> V1 setAsideBufferSize on its strategy

    /// @dev Story 092 - Phase 6b records, persisted under `minterMove` in the progress file and adopted on resume.
    ///      Pre-repoint minter DOLA config: `registerStablecoin` resets maxMintPerDay to 0 and enabled to true, so the
    ///      previous values must survive a halt after the re-registration.
    bool public minterConfigRecorded;
    uint256 public minterPrevExchangeRate;
    uint8 public minterPrevDecimals;
    bool public minterPrevEnabled;
    uint256 public minterPrevMaxMintPerDay;
    /// @dev Execution record, taken immediately before the execute (re-taken while the minter's source principal is
    ///      still non-zero, i.e. while the execute has provably not landed): the minter principal P and OWNER's DOLA.
    bool public minterExecRecorded;
    uint256 public minterPrincipalBeforeExec;
    uint256 public ownerDolaBeforeExec;
    /// @dev R: the DOLA the execute delivered to OWNER and noMintDeposit re-seeds (OWNER's balance delta).
    bool public minterRecoveredRecorded;
    uint256 public minterRecovered;
    /// @dev Story 094 (audit-35 L-09): set when THIS run executed the minter withdrawal in broadcast mode; run() then ends
    ///      the leg before the re-seed. Reset at the start of every run(), never persisted.
    bool public minterLegEndedAfterExecute;
    /// @dev Story 094: progress status of a broadcast leg that ended deliberately after the minter execute.
    string public constant PROGRESS_STATUS_AWAITING_RESEED = "awaiting_reseed";
    /// @dev Story 094: the last status `_writeProgress` serialised (also in preview, where nothing is written).
    string public lastProgressStatus;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "Wrong chain id - expected Mainnet (1)");
    }

    /// @dev Story 086: first block the cutover session could have landed a transaction in. Write-once: taken
    ///      from `block.number` the first time the progress file is written (forge's LOCAL pass starts at or
    ///      before every broadcast transaction's block) and adopted verbatim from the file thereafter.
    ///      `VerifyStableStakerV2Cutover` uses it as the `fromBlock` of its per-user event re-check.
    uint256 public cutoverStartBlock;

    /// @dev `virtual` since story 086 so `VerifyStableStakerV2Cutover` can replace the entry point with a
    ///      read-only one. The cutover npm keys name `:CutoverStableStakerV2Mainnet` explicitly.
    function run() external virtual {
        console.log("=================================================");
        console.log("  MAINNET STABLESTAKER V1 -> V2 CUTOVER (story 082)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        require(RATE_NUMERATOR == 21 && RATE_DENOMINATOR == 10, "rate multiplier must be 2.1x (user decision)");
        require(MIGRATE_CHUNK > 0 && MIGRATE_CHUNK <= 50, "MIGRATE_CHUNK out of range (1..50)");
        require(STRAGGLER_CAP_CENTS > 0 && STRAGGLER_CAP_CENTS <= 1, "straggler cap must be (0, 1 cent]");

        isPreview = _previewModeFromEnv();
        minterLegEndedAfterExecute = false;
        _loadProgressFile();

        _phase0_preconditions();
        // Story 084: simulated EYE-funded global pause, PREVIEW ONLY (deal/prank/snapshot never run in a
        // broadcast session). Before any prank.
        if (isPreview) _assertGlobalPauseWorks("phase0", true);

        if (isPreview) {
            // Story 087 (audit-33 L-07): informational only in preview - the operator sees the ETH budget
            // before signing. Never a revert here.
            _logOwnerEthBudget();
            console.log("");
            console.log("*** PREVIEW MODE - impersonating OWNER, nothing signed, nothing broadcast ***");
            console.log("*** Progress file is READ if present, NEVER written ***");
            vm.startPrank(OWNER);
        } else {
            // Story 087 (audit-33 L-07): refuse to start a Ledger session OWNER cannot pay for. Deliberately
            // NOT inside `_phase0_preconditions`, which the post-broadcast verifier also calls.
            _preflightOwnerEth();
            vm.startBroadcast();
        }

        // Story 087 (audit-33 L-05, the class check): the breaker is proved STRICTLY after EVERY phase, not
        // only after Phases 1 and 8. Story 084 sampled three stages and missed the Phase 7 window.
        _phase1_pauseV1();
        _previewBreakerStage("after-phase1");
        _phase2_antimatter();
        _previewBreakerStage("after-phase2");
        _phase3_stakerV2();
        _previewBreakerStage("after-phase3");
        _phase3b_sdolaStrategy();
        _previewBreakerStage("after-phase3b");
        _phase4_pools();
        _previewBreakerStage("after-phase4");
        _phase5_mintRights();
        _previewBreakerStage("after-phase5");
        _phase6_migration();
        _previewBreakerStage("after-phase6");
        _phase6b_minterSyaRetireSource();
        if (minterLegEndedAfterExecute) {
            // Story 094 (audit-35 L-09): deliberate end of broadcast leg 1. Nothing after the execute is recorded.
            _endLegAfterMinterExecute();
            return;
        }
        _previewBreakerStage("after-phase6b");
        _phase7_finalize();
        _previewBreakerStage("after-phase7");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _phase8_wiringAssertions();

        if (!isPreview) {
            _writeProgress("completed");
        } else {
            console.log("");
            console.log("PREVIEW: progress file NOT written (by design).");
            // BEFORE the smoke tests: they mutate fork state with no snapshot isolation.
            _assertGlobalPauseWorks("after-phase8", false);
            _previewSmokeTests();
        }
        _printSummary();
    }

    /// @dev The ONE reader of PREVIEW_MODE, shared with the verifier. `virtual` (story 087) only so fork-test harnesses
    ///      can pin the mode: `vm.setEnv` is process-wide and forge runs suites in parallel, so a test reading the
    ///      env raced other suites flipping it. Production always reads the env.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }

    /// @dev PREVIEW ONLY, no-op in broadcast. Called with OWNER's startPrank active: Foundry refuses vm.prank
    ///      while a startPrank is active, so drop OWNER, run the strict simulated global pause, resume OWNER.
    function _previewBreakerStage(string memory stage) internal {
        if (!isPreview) return;
        vm.stopPrank();
        _assertGlobalPauseWorks(stage, false);
        vm.startPrank(OWNER);
    }

    /// @dev Story 094 (audit-35 L-09). Leg 1 of a broadcast ends here, right after the minter execute was recorded in
    ///      this run: the re-seed amount must be read from the MINED execute, which only the next leg's local pass sees.
    ///      The progress file already says `PROGRESS_STATUS_AWAITING_RESEED` (written by `_minterExecuteWithdrawal`).
    function _endLegAfterMinterExecute() internal {
        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }
        console.log("");
        console.log("=================================================");
        console.log("  LEG 1 ENDED DELIBERATELY AFTER THE MINTER EXECUTE (story 094)");
        console.log("=================================================");
        console.log("  Progress status:", PROGRESS_STATUS_AWAITING_RESEED);
        console.log("  Local-pass R (NOT signed; leg 2 re-reads the mined R) / OWNER DOLA before execute:", minterRecovered, ownerDolaBeforeExec);
        console.log("  THE MINTER'S DOLA COLLATERAL SITS ON OWNER UNTIL LEG 2. Do not move OWNER's DOLA.");
        console.log("  NEXT: once the execute has MINED, run  npm run stable-staker-v2-cutover:preview");
        console.log("        then  npm run stable-staker-v2-cutover:broadcast  (leg 2 re-seeds the mined R and finishes).");
        console.log("  The :broadcast tail (address patch -> :verify -> :preview) is EXPECTED to stop now with");
        console.log("  deploymentStatus awaiting_reseed - that is leg 1 ending, not a failure.");
    }

    /// @dev Story 094: only a BROADCAST ends its leg after the execute - forge's local pass cannot know the mined R, so
    ///      nothing derived from it may be signed in the same session. PREVIEW rehearses the whole session (its local R is
    ///      the only R it has) and logs where a broadcast will stop. `virtual` only so fork tests can force the broadcast
    ///      rule while staying in preview.
    function _legEndsAfterExecute() internal view virtual returns (bool) {
        return !isPreview;
    }

    // =====================================================================
    //  STORY 087 - OWNER ETH preflight (audit-33 L-07)
    // =====================================================================

    /// @dev Gas budget for the WHOLE cutover, in gas units. Derived from the audit-33 anvil rehearsal
    ///      (fork block 25981150, `fork-logs/anvil-broadcast-gas-budget.txt`): 46 transactions, total
    ///      gasUsed 18,317,077. A node checks `balance >= gasLimit * price` UPFRONT per transaction, and
    ///      `--gas-estimate-multiplier 200` roughly doubles each limit, so the balance must also cover the
    ///      unused limit headroom of the largest LATE transaction: #37 USDe `migrate`, actual limit 3,383,096.
    ///      18,317,077 + 3,383,096 = 21,700,173, rounded UP to 22,000,000. The preflight then adds 20% on top.
    ///      A RESUME requires the full budget too (conservative: a top-up is cheap, a second halt is not).
    uint256 public constant CUTOVER_GAS_BUDGET = 22_000_000;
    /// @dev Env var carrying the broadcast gas price in wei. `:broadcast` exports it and feeds the SAME value to
    ///      forge's `--with-gas-price`, so the preflight and the signed transactions cannot disagree.
    string public constant GAS_PRICE_ENV = "CUTOVER_GAS_PRICE_WEI";
    /// @dev Preview-only fallback when the env var is unset (the `:broadcast` default, 0.3 gwei).
    uint256 public constant PREVIEW_DEFAULT_GAS_PRICE_WEI = 300_000_000;

    /// @dev OWNER's TRUE on-chain ETH, read with a raw `eth_getBalance` over the script's own RPC.
    ///      The Solidity `balance` member of OWNER MUST NOT be used here (story 087; the audit's suggested
    ///      mitigation says otherwise): forge PRE-FUNDS the script's `--sender` inside its local EVM, so that read
    ///      is not the chain's. Measured 2026-09-15 at mainnet block 25986108: the in-EVM read reported
    ///      61184840209543666 wei while `eth_getBalance` reported 6424919451687286 wei - a ~10x overstatement, in
    ///      the direction that makes this check pass exactly when it should fail, i.e. it would be worse than no
    ///      check at all. `vm.rpc` issues the JSON-RPC call directly and bypasses the local EVM.
    ///      `virtual` so fork tests can stub the on-chain balance (`vm.deal` moves the local EVM, not the chain).
    function _ownerEthOnChain() internal virtual returns (uint256) {
        bytes memory raw = vm.rpc("eth_getBalance", string.concat('["', vm.toString(OWNER), '","latest"]'));
        require(raw.length <= 32, "Preflight: eth_getBalance returned an unusable response");
        if (raw.length == 0) return 0;
        return uint256(bytes32(raw)) >> (8 * (32 - raw.length));
    }

    /// @dev ETH OWNER must hold before the run: CUTOVER_GAS_BUDGET * price * 12 / 10.
    function _requiredOwnerEth(uint256 gasPriceWei) internal pure returns (uint256) {
        return CUTOVER_GAS_BUDGET * gasPriceWei * 12 / 10;
    }

    /// @dev BROADCAST ONLY. Loud revert when the gas-price env var is missing or OWNER's on-chain balance is below
    ///      the budget AT THE PRICE THE TRANSACTIONS ARE SIGNED WITH. `:broadcast` pins `--legacy --with-gas-price
    ///      $CUTOVER_GAS_PRICE_WEI`, so every transaction costs exactly that price and the env value - not
    ///      `tx.gasprice`, which in forge's local pass is the node's base fee - is what the budget must be priced
    ///      at. A node price above the pinned one is a DIFFERENT hazard (story 071: transactions that will not be
    ///      mined), so it is logged loudly here rather than silently inflating the ETH requirement.
    ///      Never called from `_phase0_preconditions` (the verifier runs that post-broadcast, when OWNER's ETH is
    ///      irrelevant).
    function _preflightOwnerEth() internal {
        uint256 envPrice = vm.envOr(GAS_PRICE_ENV, uint256(0));
        require(
            envPrice > 0,
            "Preflight: CUTOVER_GAS_PRICE_WEI is unset - run via npm run stable-staker-v2-cutover:broadcast (it exports the price it passes to --with-gas-price)"
        );
        uint256 required = _requiredOwnerEth(envPrice);
        uint256 balance = _ownerEthOnChain();
        console.log("  OWNER ETH preflight (gas price wei / required wei / OWNER balance wei):", envPrice, required, balance);
        if (tx.gasprice > envPrice) {
            console.log("  WARNING: node gas price is ABOVE the pinned CUTOVER_GAS_PRICE_WEI (node / pinned):", tx.gasprice, envPrice);
            console.log("  The run is budgeted at the pinned price, but transactions signed below the base fee may not be mined (story 071) - consider raising CUTOVER_GAS_PRICE_WEI.");
        }
        require(
            balance >= required,
            string.concat(
                "Preflight: OWNER ETH below cutover gas budget - need ", vm.toString(required), " wei at ",
                vm.toString(envPrice), " wei/gas, have ", vm.toString(balance), ". Top up OWNER before signing."
            )
        );
    }

    /// @dev PREVIEW ONLY. Logs budget, balance and surplus/shortfall; never reverts.
    function _logOwnerEthBudget() internal {
        uint256 price = vm.envOr(GAS_PRICE_ENV, uint256(0));
        if (price == 0) price = PREVIEW_DEFAULT_GAS_PRICE_WEI;
        uint256 required = _requiredOwnerEth(price);
        uint256 bal = _ownerEthOnChain();
        console.log("  ETH_BUDGET|gasBudget / gasPriceWei / requiredWei:", CUTOVER_GAS_BUDGET, price, required);
        if (bal >= required) {
            console.log("  ETH_BUDGET|OK|OWNER balance / surplus wei:", bal, bal - required);
        } else {
            console.log("  ETH_BUDGET|SHORTFALL|OWNER balance / shortfall wei (TOP UP BEFORE :broadcast):", bal, required - bal);
        }
    }

    // =====================================================================
    //  PHASE 0 - Preconditions
    // =====================================================================

    /// @dev Story 092: the read-only checks, then the minter withdrawal-window preflight. Split only so a fork test can
    ///      drive the V1 exit during the 6h waiting period (story 092 cases a-c) without the window gate; production and
    ///      the verifier always call this function, never the halves.
    function _phase0_preconditions() internal {
        _phase0_readChecks();
        _phase0_minterWithdrawalWindow();
    }

    function _phase0_readChecks() internal {
        console.log("\n=== Phase 0: preconditions ===");
        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);

        require(_owner(STABLE_STAKER_V1) == OWNER, "Phase0: V1 owner != OWNER");
        require(_owner(PHUSD) == OWNER, "Phase0: phUSD owner != OWNER");
        require(_owner(PAUSER) == OWNER, "Phase0: Pauser owner != OWNER");
        require(_owner(PHUSD_STABLE_MINTER) == OWNER, "Phase0: PhusdStableMinter owner != OWNER");
        require(_owner(STABLE_YIELD_ACCUMULATOR) == OWNER, "Phase0: StableYieldAccumulator owner != OWNER (story 092 repoints its strategy list)");
        address v1Pauser = IPausableLike(STABLE_STAKER_V1).pauser();
        require(v1Pauser == PAUSER || v1Pauser == OWNER, "Phase0: V1 pauser is neither Pauser nor OWNER");
        // Story 092: the delays the Phase 0 window preflight and the Phase 6b execute rely on, read off the live source.
        require(
            ISourceDolaStrategy(YS_DOLA).WAITING_PERIOD() == DOLA_WITHDRAWAL_WAITING_PERIOD
                && ISourceDolaStrategy(YS_DOLA).EXECUTION_WINDOW() == DOLA_WITHDRAWAL_EXECUTION_WINDOW,
            "Phase0: autoDOLA strategy WAITING_PERIOD / EXECUTION_WINDOW != 6h / 72h"
        );

        address[] memory live = IStakerTokens(STABLE_STAKER_V1).getStakedTokens();
        require(live.length > 0, "Phase0: V1 has no staked tokens");
        bool anyActive;
        for (uint256 i = 0; i < live.length; i++) {
            address t = live[i];
            tokens.push(t);
            address ys = _sourceStrategyFor(t); // V1's exit side; reverts on a token with no known strategy
            require(_owner(ys) == OWNER, "Phase0: strategy owner != OWNER");
            if (t == DOLA && _sourceDolaRetirementStarted()) {
                // Story 092 resume / verifier: Phase 6b already drained both clients off the autoDOLA source and is
                // retiring it (pauser OWNER -> unregistered -> paused). V2 routes nothing through it, so the
                // unpaused / registered checks below no longer apply; Phase 6b and Phase 8 assert the retired state.
                console.log("  autoDOLA source strategy retirement started (no clients) - pause/registration checks skipped");
            } else {
                require(!IPausableLike(ys).paused(), "Phase0: strategy paused - its withdraw/deposit are whenNotPaused");
                // Story 088: the Phase 7 V2 coverage gap (V2 unpaused, unregistered for one tx) exposes nothing ONLY
                // because a global pause stops every strategy V2 routes through. Assert that, read-only.
                require(IPauserRegistry(PAUSER).isRegistered(ys), "Phase0: strategy not registered with the global Pauser");
                require(IPausableLike(ys).pauser() == PAUSER, "Phase0: strategy pauser != Pauser");
            }

            (uint256 perSecond,,, uint256 staked) = v1.poolInfo(t);
            uint8 state = v1.poolState(t);
            if (state == POOL_ACTIVE) {
                anyActive = true;
                require(
                    IYieldStrategyGetter(STABLE_STAKER_V1).yieldStrategy(t) == ys,
                    "Phase0: V1 yieldStrategy(token) != hard-coded strategy map"
                );
            }
            cPerDay[t] = perSecond * 86400;
            v1BufferPct[t] = ICutoverBuffer(ys).setAsideBufferSize(STABLE_STAKER_V1);

            (address minterYs,, uint8 dec,,,,) = PhusdStableMinter(PHUSD_STABLE_MINTER).stablecoinConfigs(t);
            // Fail loudly, never silently register: V2 `autoAnnihilateAvailable` needs every pool
            // token registered on the stable minter. All three were registered at planning time.
            require(minterYs != address(0), "Phase0: token NOT registered on PhusdStableMinter - STOP (do not register silently)");
            require(dec == IERC20Metadata(t).decimals(), "Phase0: PhusdStableMinter decimals != token decimals");
            if (t == DOLA) {
                // Story 092 resume: before the Phase 6b repoint the minter's DOLA points at the autoDOLA source; after it,
                // at the sDOLA strategy (recovered from the progress file). Anything else is out-of-band: STOP.
                require(
                    minterYs == YS_DOLA || (address(sdolaStrategy) != address(0) && minterYs == address(sdolaStrategy)),
                    "Phase0: PhusdStableMinter DOLA registration is neither the autoDOLA strategy nor the recorded sDOLA strategy - STOP"
                );
            }

            console.log("  token:", t, IERC20Metadata(t).symbol());
            console.log("    V1 poolState / stakerCount / totalStaked:", uint256(state), v1.stakerCount(t), staked);
            console.log("    strategy / principalOf(V1):", ys, ICutoverStrategy(ys).principalOf(t, STABLE_STAKER_V1));
            console.log("    V1 phusdPerSecond / C (phUSD per day):", perSecond, cPerDay[t]);
            console.log("    setAsideBufferSize(V1) %:", v1BufferPct[t]);
            (bool hasRecipient, address recipient) = _bufferRecipient(ys);
            if (hasRecipient) {
                console.log("    setAsideBufferRecipient:", recipient);
            } else {
                console.log("    setAsideBufferRecipient: NONE (pre-story-047 strategy: buffer is paid to each client)");
            }
            console.log("    V1 idle token balance (buffer, stays on V1):", IERC20(t).balanceOf(STABLE_STAKER_V1));
            console.log("    PhusdStableMinter registration: strategy", minterYs);
        }

        // V1 must still be able to mint phUSD while any pool is un-initiated: `batchMigrate` mints each
        // user's frozen pending reward, and a premature revoke bricks the exit.
        if (anyActive) {
            require(_canMintPhUSD(STABLE_STAKER_V1), "Phase0: V1 cannot mint phUSD - revoking before migration bricks exits");
        }
        console.log("  V1 phUSD mint authorized:", _canMintPhUSD(STABLE_STAKER_V1));

        _snapshotPhusdMinterSet();
    }

    /// @dev Story 092. Skipped once the minter's withdrawal has executed (its autoDOLA principal is 0), which covers every
    ///      resume past the execute and the post-broadcast verifier. Otherwise the session may only START with at least
    ///      WINDOW_SAFETY_MARGIN left in the execution window.
    function _phase0_minterWithdrawalWindow() internal view {
        if (_doneMinterWithdrawalExecuted()) {
            console.log("  minter DOLA withdrawal already executed (autoDOLA principal 0) - window preflight skipped");
            return;
        }
        _requireMinterWithdrawalExecutable("Phase0", WINDOW_SAFETY_MARGIN);
        (uint256 initiatedAt,,) = ISourceDolaStrategy(YS_DOLA).withdrawalStates(DOLA, PHUSD_STABLE_MINTER);
        console.log("  minter DOLA withdrawal window OK (initiatedAt / closes at):", initiatedAt, initiatedAt + DOLA_WITHDRAWAL_WAITING_PERIOD + DOLA_WITHDRAWAL_EXECUTION_WINDOW);
    }

    /// @dev Reverts with operator guidance unless the minter's `totalWithdrawal` would EXECUTE now and stays executable for
    ///      `margin` more seconds. A None / Expired state is fatal, not merely late: a `totalWithdrawal` call there would
    ///      silently INITIATE (and move nothing).
    function _requireMinterWithdrawalExecutable(string memory phase, uint256 margin) internal view {
        (uint256 initiatedAt, uint8 status,) = ISourceDolaStrategy(YS_DOLA).withdrawalStates(DOLA, PHUSD_STABLE_MINTER);
        require(
            status == WITHDRAWAL_INITIATED || status == WITHDRAWAL_EXECUTABLE,
            string.concat(
                phase,
                ": PhusdStableMinter DOLA totalWithdrawal is NOT initiated on the autoDOLA strategy - run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status)"
            )
        );
        uint256 closesAt = initiatedAt + DOLA_WITHDRAWAL_WAITING_PERIOD + DOLA_WITHDRAWAL_EXECUTION_WINDOW;
        require(
            block.timestamp >= initiatedAt + DOLA_WITHDRAWAL_WAITING_PERIOD,
            string.concat(
                phase,
                ": minter DOLA withdrawal still in its 6h waiting period - run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status); executable at ",
                vm.toString(initiatedAt + DOLA_WITHDRAWAL_WAITING_PERIOD)
            )
        );
        require(
            block.timestamp <= closesAt,
            string.concat(
                phase,
                ": minter DOLA withdrawal window EXPIRED - run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status)"
            )
        );
        require(
            block.timestamp + margin < closesAt || margin == 0,
            string.concat(
                phase,
                ": fewer than WINDOW_SAFETY_MARGIN seconds left in the minter DOLA withdrawal window - too late to start the session. Wait for expiry at ",
                vm.toString(closesAt),
                ", then run initiate-dola-ys-withdrawal:broadcast and wait (see dola-ys-withdrawal:status)"
            )
        );
    }

    // =====================================================================
    //  PHASE 1 - pause V1
    // =====================================================================

    /// @dev Stakes into V1 revert once paused, so no new position (and no new dust) can enter during
    ///      the window. `initiateMigration` / `batchMigrate` carry no `whenNotPaused`, so the pause does
    ///      not obstruct the cutover.
    ///      STORY 084 (audit L-04): Phase 1 now RETIRES V1 in full - pauser -> OWNER, Pauser.unregister(V1),
    ///      then pause() - instead of pausing V1 while it stays registered until Phase 7. `Pauser.pause()`
    ///      loops `pause()` over every registrant with no try/catch; a registered V1 whose pauser is OWNER
    ///      reverts `StableStaker: only pauser` and takes the whole permissionless breaker down with it.
    ///      Unregistering BEFORE pausing keeps the global breaker live for the rest of the Ledger session; the
    ///      only forced dead window is the single tx between `setPauser(OWNER)` and `unregister` (the unregister
    ///      precondition). Phase 7 applies the mirror rule to V2: unpause BEFORE register (story 087).
    ///      Each step is independently state-gated (no "already paused - skip" shortcut), so a resume from
    ///      "V1 paused but still registered" (a run halted under the old ordering, or a manual owner pause)
    ///      still unregisters V1. Phase 7 calls the same helper as an idempotent backstop.
    function _phase1_pauseV1() internal {
        console.log("\n=== Phase 1: retire V1 (pauser OWNER, unregister, pause) ===");
        if (_doneCutoverFinalized()) {
            console.log("  cutover already finalized (V2 pauser == Pauser) - V1 retirement skipped (Phase 7/8 assert it)");
            return;
        }
        _retireV1("Phase1");
        console.log("  V1 pauser OWNER, unregistered from Pauser, paused - global Pauser.pause() live again");
    }

    /// @dev V1 retirement triple. ORDER IS FORCED: `Pauser.unregister` reverts while V1.pauser() == PAUSER,
    ///      so setPauser first; and V1 must be unregistered BEFORE it is paused (story 084, audit L-04).
    ///      `unregister` is onlyOwner (Phase 0 asserts Pauser owner == OWNER). Every step is gated on
    ///      on-chain state and followed by a read-back require, so any resume converges.
    function _retireV1(string memory phase) internal {
        IPausableLike v1p = IPausableLike(STABLE_STAKER_V1);
        if (!_v1PauserIsOwner()) {
            v1p.setPauser(OWNER);
        }
        require(_v1PauserIsOwner(), string.concat(phase, ": V1 pauser not moved to OWNER"));
        if (!_v1UnregisteredFromPauser()) {
            IPauserRegistry(PAUSER).unregister(STABLE_STAKER_V1);
            console.log("  Pauser.unregister(V1) - retired staker removed from the global pause registry");
        } else {
            console.log("  V1 already unregistered from Pauser - skipped");
        }
        require(_v1UnregisteredFromPauser(), string.concat(phase, ": V1 still registered with Pauser"));
        if (!_v1Paused()) {
            v1p.pause();
        } else {
            console.log("  V1 already paused - pause step skipped");
        }
        require(_v1Paused(), string.concat(phase, ": V1 not paused"));
    }

    // =====================================================================
    //  PHASE 2 - Antimatter
    // =====================================================================

    function _phase2_antimatter() internal {
        console.log("\n=== Phase 2: Antimatter ===");
        if (address(antimatter) == address(0)) {
            antimatter = new Antimatter(OWNER);
            console.log("  Antimatter deployed at:", address(antimatter));
            _writeProgress("in_progress");
        } else {
            console.log("  Antimatter loaded from progress file:", address(antimatter));
        }
        require(_doneAntimatterIdentity(), "Phase2: Antimatter name / symbol / owner != Antimatter / AM / OWNER");

        // ORDER IS LOAD-BEARING: setPhUSDMinter reverts PhUSDNotSet otherwise.
        if (address(antimatter.phUSD()) != PHUSD) {
            antimatter.setPhUSD(IFlaxAntimatter(PHUSD));
        }
        if (address(antimatter.phUSDMinter()) != PHUSD_STABLE_MINTER) {
            antimatter.setPhUSDMinter(PhusdStableMinter(PHUSD_STABLE_MINTER));
        }
        require(address(antimatter.phUSD()) == PHUSD, "Phase2: Antimatter.phUSD did not land");
        require(_doneAntimatterWired(), "Phase2: Antimatter.phUSDMinter did not land");
        console.log("  Antimatter wired to phUSD + PhusdStableMinter (read back)");
    }

    // =====================================================================
    //  PHASE 3 - StableStakerV2, paused before any addToken
    // =====================================================================

    /// @dev Pause BEFORE addToken: between `addToken` and `setYieldStrategy` anyone could stake into
    ///      the strategy-less pool, after which `setYieldStrategy` reverts "pool not empty". `depositFor`
    ///      is not `whenNotPaused`, so V2 can stay paused through the whole migration.
    ///      `v2.pauser() == PAUSER` is the finalized marker (set in Phase 7 only), so a verification
    ///      preview after a completed broadcast never re-pauses a live V2.
    function _phase3_stakerV2() internal {
        console.log("\n=== Phase 3: StableStakerV2 ===");
        if (address(v2) == address(0)) {
            v2 = new StableStakerV2(IAntimatter(address(antimatter)), OWNER);
            console.log("  StableStakerV2 deployed at:", address(v2));
            _writeProgress("in_progress");
        } else {
            console.log("  StableStakerV2 loaded from progress file:", address(v2));
        }
        require(v2.STAKER_VERSION() == 2, "Phase3: deployed staker is not version 2");
        require(address(v2.antimatter()) == address(antimatter), "Phase3: V2.antimatter != Antimatter");
        require(_doneStakerV2Identity(), "Phase3: V2 owner != OWNER");

        if (_doneCutoverFinalized()) {
            console.log("  V2 already finalized (pauser == Pauser) - pause step skipped");
            return;
        }
        if (!v2.paused()) {
            if (v2.pauser() != OWNER) v2.setPauser(OWNER);
            v2.pause();
        }
        require(v2.paused(), "Phase3: V2 not paused before pool setup");
        console.log("  V2 paused (pauser temporarily OWNER)");
    }

    // =====================================================================
    //  PHASE 3b - sDOLA destination strategy (story 091)
    // =====================================================================

    /// @dev Deploys and wires V2's DOLA destination BEFORE Phase 4 wires V2 to it. Every step is `if (!done) do();`
    ///      with a done-predicate read from chain (`_doneSdolaStrategy*`), shared with the verifier. HALT POINTS: see
    ///      PHASE 3b HALT POINTS in the header - none makes `Pauser.pause()` revert and none exposes principal (the
    ///      strategy has no client until Phase 4). Minter client wiring is story 092's.
    function _phase3b_sdolaStrategy() internal {
        console.log("\n=== Phase 3b: sDOLA destination strategy (story 091) ===");
        require(_contains(tokens, DOLA), "Phase3b: V1 stakes no DOLA - the sDOLA destination has no pool (STOP AND REPORT)");
        require(IERC4626AssetLike(SDOLA).asset() == DOLA, "Phase3b: sDOLA asset() != DOLA - refusing to deploy over the wrong vault");

        if (address(sdolaStrategy) == address(0)) {
            _requireNoUnrecordedSdolaStrategy();
            sdolaStrategy = new ERC4626YieldStrategy(OWNER, DOLA, SDOLA);
            console.log("  ERC4626YieldStrategy(OWNER, DOLA, sDOLA) deployed at:", address(sdolaStrategy));
            _writeProgress("in_progress");
        } else {
            console.log("  sDOLA strategy loaded from progress file:", address(sdolaStrategy));
        }
        require(_doneSdolaStrategyIdentity(), "Phase3b: sDOLA strategy owner / underlyingToken / vault != OWNER / DOLA / sDOLA");

        // Capacity preflight against V1's whole DOLA principal (the larger of V1's book and the source strategy's).
        uint256 v1Dola = _v1DolaPrincipal();
        uint256 cap = ICutoverVault(SDOLA).maxDeposit(address(sdolaStrategy));
        console.log("  sDOLA maxDeposit(strategy) / V1 DOLA principal:", cap, v1Dola);
        require(cap >= v1Dola, "Phase3b: sDOLA maxDeposit below V1's DOLA principal - STOP AND REPORT");

        // Pauser BEFORE any V2 deposit, and never register a paused contract (story 087 rule).
        if (sdolaStrategy.pauser() != PAUSER) sdolaStrategy.setPauser(PAUSER);
        if (!IPauserRegistry(PAUSER).isRegistered(address(sdolaStrategy))) {
            require(!sdolaStrategy.paused(), "Phase3b: sDOLA strategy is paused - refusing to register a paused contract");
            IPauserRegistry(PAUSER).register(address(sdolaStrategy));
        }
        require(_doneSdolaStrategyPauseWired(), "Phase3b: sDOLA strategy pauser / Pauser registration did not land");

        if (!_doneSdolaStrategyWithdrawer()) sdolaStrategy.setWithdrawer(STABLE_YIELD_ACCUMULATOR, true);
        require(_doneSdolaStrategyWithdrawer(), "Phase3b: StableYieldAccumulator is not a withdrawer on the sDOLA strategy");
        console.log("  sDOLA strategy: pauser Pauser, registered, SYA withdrawer (minter client is story 092)");
    }

    /// @dev FAIL CLOSED before a CREATE (story 091). The progress file names no sDOLA strategy, so a deployment is
    ///      about to happen. Refuse if the chain already shows one the file does not name: V2 already routing DOLA
    ///      to a strategy, or a Pauser registrant that IS an `ERC4626YieldStrategy(OWNER, DOLA, sDOLA)`. Deploying a
    ///      second one would split the pool. A CREATE that landed but was never registered cannot be seen here; the
    ///      progress file records every CREATE in forge's local pass before sending, so that shape only arises from
    ///      a hand-trimmed file - trim to run-latest.json receipts, which include the CREATE.
    function _requireNoUnrecordedSdolaStrategy() internal view {
        if (address(v2) != address(0) && address(v2).code.length > 0 && _contains(v2.getStakedTokens(), DOLA)) {
            require(
                address(v2.yieldStrategy(DOLA)) == address(0),
                "Phase3b: V2 already routes DOLA to a strategy the progress file does not name - STOP (add contracts.ERC4626YieldStrategySDOLA to the progress file; never deploy a second one)"
            );
        }
        address[] memory registrants = IPauserRegistry(PAUSER).getPausableContracts();
        for (uint256 i = 0; i < registrants.length; i++) {
            require(
                !_isSdolaStrategyShape(registrants[i]),
                string.concat(
                    "Phase3b: Pauser registrant ", vm.toString(registrants[i]),
                    " is an ERC4626YieldStrategy(OWNER, DOLA, sDOLA) the progress file does not name - STOP (record it; never deploy a second one)"
                )
            );
        }
    }

    function _isSdolaStrategyShape(address c) internal view returns (bool) {
        (bool okV, bytes memory v) = c.staticcall(abi.encodeWithSignature("vault()"));
        if (!okV || v.length < 32 || abi.decode(v, (address)) != SDOLA) return false;
        (bool okU, bytes memory u) = c.staticcall(abi.encodeWithSignature("underlyingToken()"));
        if (!okU || u.length < 32 || abi.decode(u, (address)) != DOLA) return false;
        (bool okO, bytes memory o) = c.staticcall(abi.encodeWithSignature("owner()"));
        return okO && o.length >= 32 && abi.decode(o, (address)) == OWNER;
    }

    function _v1DolaPrincipal() internal view returns (uint256) {
        (,,, uint256 staked) = ICutoverStaker(STABLE_STAKER_V1).poolInfo(DOLA);
        uint256 booked = ICutoverStrategy(YS_DOLA).principalOf(DOLA, STABLE_STAKER_V1);
        return booked > staked ? booked : staked;
    }

    // =====================================================================
    //  PHASE 4 - per-token pool setup, copied from V1's LIVE config
    // =====================================================================

    function _phase4_pools() internal {
        console.log("\n=== Phase 4: V2 pools (from V1 live config) ===");
        for (uint256 i = 0; i < tokens.length; i++) {
            _setupPool(tokens[i]);
        }
    }

    function _setupPool(address t) internal {
        address ys = _destinationStrategyFor(t); // V2's side (story 091: DOLA -> sDOLA strategy)
        // Story 091: V2 must never deposit into a strategy outside the global breaker.
        require(
            IPauserRegistry(PAUSER).isRegistered(ys) && IPausableLike(ys).pauser() == PAUSER,
            "Phase4: destination strategy not registered with the Pauser - refusing to wire V2 to it"
        );
        console.log("  -- pool", t, IERC20Metadata(t).symbol());

        if (!_donePoolTokenAdded(t)) {
            v2.addToken(t);
        }
        if (!_donePoolClientSet(t)) {
            IYieldStrategy(ys).setClient(address(v2), true);
        }
        require(_donePoolClientSet(t), "Phase4: strategy.setClient(V2) did not land");

        if (!_donePoolStrategySet(t)) {
            // Idle-balance guard. `setYieldStrategy` sweeps any idle token balance into a strategy
            // deposit. A donated dust balance to the predictable V2 address could make that deposit
            // revert ("no shares received") and brick the pool setup. Rescue it to OWNER first -
            // allowed because with no strategy and totalStaked == 0 nothing is reserved.
            (,,, uint256 staked) = v2.poolInfo(t);
            require(staked == 0, "Phase4: V2 pool not empty before setYieldStrategy");
            uint256 idle = IERC20(t).balanceOf(address(v2));
            if (idle > 0) {
                console.log("    WARNING: idle balance on V2 before setYieldStrategy - rescued to OWNER:", idle);
                v2.rescueERC20(t, OWNER, idle);
            }
            require(IERC20(t).balanceOf(address(v2)) == 0, "Phase4: V2 idle balance != 0 immediately before setYieldStrategy");
            v2.setYieldStrategy(t, IYieldStrategy(ys));
        }
        require(_donePoolStrategySet(t), "Phase4: V2 yieldStrategy did not land");

        uint256 buf = v1BufferPct[t];
        if (!_donePoolBufferCopied(t)) {
            IYieldStrategy(ys).setSetAsideBuffer(address(v2), buf);
        }
        require(_donePoolBufferCopied(t), "Phase4: V2 set-aside buffer != V1's");

        uint256 c = cPerDay[t];
        require(c > 0, "Phase4: V1 phUSD rate for token is 0 - refusing a zero Antimatter emission");
        uint256 newPerDay = c * RATE_NUMERATOR / RATE_DENOMINATOR;
        if (!_donePoolRateSet(t)) {
            v2.antimatterPerDay(t, newPerDay);
        }
        require(_donePoolRateSet(t), "Phase4: V2 antimatterPerSecond != (C * 21 / 10) / 86400");
        (uint256 perSecond,,,) = v2.poolInfo(t);
        console.log("    C (V1 phUSD/day) / Antimatter/day (2.1x):", c, newPerDay);
        console.log("    antimatterPerSecond / setAsideBuffer %:", perSecond, buf);

        require(v2.autoAnnihilateAvailable(t), "Phase4: autoAnnihilateAvailable(token) false - token not annihilatable");
    }

    // =====================================================================
    //  PHASE 5 - mint rights
    // =====================================================================

    /// @dev THREE grants, and the third is not in the story's list:
    ///       - Antimatter.setApprovedMinter(V2)  : V2 mints the reward token.
    ///       - phUSD.setMinter(V2)               : V2 covers an autoAnnihilate shortfall.
    ///       - phUSD.setMinter(Antimatter)       : `Antimatter.annihilate` pays its antimatter half with
    ///         `_phUSD.mint(recipient, amount)` (lib/antimatter Antimatter.sol). `claimEnabled` stays
    ///         false, so `autoAnnihilate` is V2's ONLY reward path, and without this grant every call
    ///         reverts - every migrated staker would accrue Antimatter nobody can redeem. Both upstream
    ///         test suites grant it (antimatter Annihilation.t.sol, stable-staker AutoAnnihilate.t.sol).
    ///         Recorded as an Autonomous Decision in story 082; flip GRANT_ANTIMATTER_PHUSD_MINT to
    ///         false to drop it.
    ///      Both silent-no-op setters are verified by READ-BACK, never by event.
    bool public constant GRANT_ANTIMATTER_PHUSD_MINT = true;

    function _phase5_mintRights() internal {
        console.log("\n=== Phase 5: mint rights ===");
        if (!_doneV2AntimatterMinter()) {
            antimatter.setApprovedMinter(address(v2), true);
        }
        require(_doneV2AntimatterMinter(), "Phase5: V2 is not an approved Antimatter minter");
        console.log("  Antimatter.setApprovedMinter(V2) - VERIFIED by read-back");

        if (!_doneV2PhusdMinter()) {
            IPhUSDOwner(PHUSD).setMinter(address(v2), true);
        }
        require(_doneV2PhusdMinter(), "Phase5: V2 cannot mint phUSD (autoAnnihilate shortfall cover dead)");
        console.log("  phUSD.setMinter(V2) - VERIFIED via phUSDMintAvailable()");

        if (GRANT_ANTIMATTER_PHUSD_MINT) {
            if (!_doneAntimatterPhusdMinter()) {
                IPhUSDOwner(PHUSD).setMinter(address(antimatter), true);
            }
            require(_doneAntimatterPhusdMinter(), "Phase5: Antimatter cannot mint phUSD (annihilate dead)");
            console.log("  phUSD.setMinter(Antimatter) - VERIFIED at current mintVersion");
        }

        _assertPhusdMinterDelta(!_canMintPhUSD(STABLE_STAKER_V1));
    }

    // =====================================================================
    //  PHASE 6 - migration
    // =====================================================================

    function _phase6_migration() internal {
        console.log("\n=== Phase 6: V1 -> V2 migration ===");
        if (address(migrator) == address(0)) {
            migrator = new CrossVersionMigrator(
                IStableStakerMigratable(STABLE_STAKER_V1), IStableStakerMigratable(address(v2)), OWNER
            );
            console.log("  CrossVersionMigrator deployed at:", address(migrator));
            _writeProgress("in_progress");
        } else {
            console.log("  CrossVersionMigrator loaded from progress file:", address(migrator));
        }
        require(_doneMigratorIdentity(), "Phase6: migrator oldStaker / newStaker / owner != V1 / V2 / OWNER");

        if (IMigratorRole(STABLE_STAKER_V1).migrator() != address(migrator)) {
            IMigratorRole(STABLE_STAKER_V1).setMigrator(address(migrator));
        }
        if (v2.migrator() != address(migrator)) {
            v2.setMigrator(address(migrator));
        }
        require(_doneMigratorWired(), "Phase6: V1 / V2 migrator not wired");
        require(migrator.versionOf(STABLE_STAKER_V1) == 1, "Phase6: source staker did not probe as version 1");
        require(migrator.versionOf(address(v2)) == 2, "Phase6: destination staker is not version 2");

        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            address src = _sourceStrategyFor(t); // V1 exits here
            address dst = _destinationStrategyFor(t); // V2 deposits here
            console.log("  -- migrating pool", t, IERC20Metadata(t).symbol());

            _initiatePool(ICutoverMigrator(address(migrator)), v1, t, src);

            PoolPlan memory preview = _planPool(v1, t, dst);
            if (preview.migratable.length > 0) {
                // Pending phUSD is minted inside batchMigrate; a revoked V1 would brick every exit.
                require(_canMintPhUSD(STABLE_STAKER_V1), "Phase6: V1 phUSD mint revoked while stakers remain to migrate");
            }
            PoolPlan memory plan =
                _migratePool(ICutoverMigrator(address(migrator)), v1, t, dst, MIGRATE_CHUNK, _stragglerCap(t));

            _assertPoolPostMigration(
                v1, ICutoverStaker(address(v2)), t, src, dst, plan, _maxLossBps(src), _maxLossBps(dst), WEI_SLACK
            );
        }
    }

    // =====================================================================
    //  PHASE 6b - minter DOLA collateral + SYA onto the sDOLA strategy, retire the autoDOLA source (story 092)
    // =====================================================================

    /// @dev Runs after Phase 6 and before Phase 7 (Phase 7's order is untouched). Every sub-step is `if (!done) do();`
    ///      over a shared on-chain predicate; see PHASE 6b HALT POINTS in the header.
    function _phase6b_minterSyaRetireSource() internal {
        console.log("\n=== Phase 6b: minter DOLA collateral -> sDOLA strategy, SYA repoint, retire autoDOLA strategy (story 092) ===");
        require(address(sdolaStrategy) != address(0), "Phase6b: sDOLA strategy unknown - Phase 3b has not run");
        // ORDER IS LOAD-BEARING (script/archives/MigrateSaga2Migrate.s.sol precedent). `ERC4626YieldStrategy._totalWithdraw`
        // redeems `totalShares * minterPrincipal / totalDeposited` - a pro-rata cut of ALL the strategy's shares. Run while
        // V1 still booked principal here, it would pull V1 stakers' value to OWNER. Phase 6 must have drained V1 first.
        require(_doneV1PoolMigrating(DOLA), "Phase6b: V1 DOLA pool is not Migrating - Phase 6 has not drained V1");
        require(
            ICutoverStrategy(YS_DOLA).principalOf(DOLA, STABLE_STAKER_V1) == 0,
            "Phase6b: V1 still books DOLA principal on the autoDOLA strategy - the minter totalWithdrawal must run AFTER Phase 6"
        );
        _minterRecordConfigAndDisable();
        _minterExecuteWithdrawal();
        // Story 094 (audit-35 L-09): a broadcast that executed in THIS run stops here; the next leg re-seeds the mined R.
        if (minterLegEndedAfterExecute) return;
        _minterReseedSdola();
        _minterRegisterSdola();
        _syaRepointDola();
        _retireSourceDola();
    }

    /// @dev Step 1-2: persist the pre-repoint DOLA config (write-once), then stop new DOLA deposits into the source.
    ///      `setStablecoinEnabled` is the minter's real toggle (lib/phUSD-stable-minter PhusdStableMinter.sol); `mint`
    ///      requires `config.enabled`. V2 is paused through Phase 6b, so its autoAnnihilate(DOLA) is not affected.
    function _minterRecordConfigAndDisable() internal {
        (address ys, uint256 rate, uint8 dec, bool enabled, uint256 maxPerDay,,) =
            PhusdStableMinter(PHUSD_STABLE_MINTER).stablecoinConfigs(DOLA);
        if (!minterConfigRecorded) {
            require(
                ys == YS_DOLA,
                "Phase6b: minter DOLA registration already moved but the progress file holds no pre-repoint config (minterMove) - STOP: recover exchangeRate / decimals / enabled / maxMintPerDay from the minter's event history and add them before resuming"
            );
            require(rate > 0, "Phase6b: minter DOLA exchangeRate is 0 - refusing to carry a zero rate onto the sDOLA strategy");
            minterPrevExchangeRate = rate;
            minterPrevDecimals = dec;
            minterPrevEnabled = enabled;
            minterPrevMaxMintPerDay = maxPerDay;
            minterConfigRecorded = true;
            _writeProgress("in_progress");
            console.log("  recorded minter DOLA config (exchangeRate / decimals / maxMintPerDay):", rate, dec, maxPerDay);
            console.log("  recorded minter DOLA enabled:", enabled);
        }
        if (ys != YS_DOLA) {
            console.log("  minter DOLA already repointed - disable step skipped");
            return;
        }
        if (enabled) PhusdStableMinter(PHUSD_STABLE_MINTER).setStablecoinEnabled(DOLA, false);
        require(!_minterDolaEnabled(), "Phase6b: setStablecoinEnabled(DOLA, false) did not land");
        console.log("  minter DOLA minting disabled for the collateral move");
    }

    /// @dev Step 3: EXECUTE the delayed withdrawal. DOLA R goes to `owner()` (OWNER). Bounded against P with the source's
    ///      loss bound: `P - R <= P * _maxLossBps(source) / MAX_BPS + WEI_SLACK`. R above P (the V1-drained strategy's
    ///      remaining surplus shares all belong to the minter now) is not a loss.
    function _minterExecuteWithdrawal() internal {
        if (_doneMinterWithdrawalExecuted()) {
            console.log("  minter DOLA withdrawal already executed - skipped");
            return;
        }
        _requireMinterWithdrawalExecutable("Phase6b", 0);
        // (Re-)taken while the minter's source principal is non-zero, i.e. while the execute has provably not landed.
        minterPrincipalBeforeExec = ICutoverStrategy(YS_DOLA).principalOf(DOLA, PHUSD_STABLE_MINTER);
        ownerDolaBeforeExec = IERC20(DOLA).balanceOf(OWNER);
        minterExecRecorded = true;
        minterRecoveredRecorded = false;
        minterRecovered = 0;
        _writeProgress("in_progress");
        console.log("  execute: minter principal P / OWNER DOLA before:", minterPrincipalBeforeExec, ownerDolaBeforeExec);

        ISourceDolaStrategy(YS_DOLA).totalWithdrawal(DOLA, PHUSD_STABLE_MINTER);

        require(
            _doneMinterWithdrawalExecuted(),
            "Phase6b: totalWithdrawal did not zero the minter's autoDOLA principal - it did not EXECUTE (see dola-ys-withdrawal:status)"
        );
        (, uint8 status,) = ISourceDolaStrategy(YS_DOLA).withdrawalStates(DOLA, PHUSD_STABLE_MINTER);
        require(status == 0, "Phase6b: minter withdrawal state not reset to None after execution");
        uint256 r = _recoveredDolaOnChain();
        _requireRecoveryWithinBound(r);
        minterRecovered = r;
        minterRecoveredRecorded = true;
        // Story 094 (audit-35 L-09): in a broadcast this R is the LOCAL pass's, and the execute mines later at the live
        // autoDOLA price. End the leg so no amount derived from it is signed; leg 2 re-derives R from the mined state.
        if (_legEndsAfterExecute()) {
            minterLegEndedAfterExecute = true;
            _writeProgress(PROGRESS_STATUS_AWAITING_RESEED);
        } else {
            _writeProgress("in_progress");
            console.log("  PREVIEW: a BROADCAST ends its leg here (story 094) - re-run :preview + :broadcast after the execute mines");
        }
        console.log("  executed: R (DOLA delivered to OWNER) / P:", r, minterPrincipalBeforeExec);
    }

    /// @dev R re-derived from chain: OWNER's DOLA now minus its persisted pre-execution balance. FAILS CLOSED when the
    ///      execution record is missing or OWNER holds less DOLA than before (the collateral moved out of band).
    function _recoveredDolaOnChain() internal view returns (uint256 r) {
        require(
            minterExecRecorded,
            "Phase6b: minter withdrawal executed but the progress file has no execution record (minterMove.ownerDolaBeforeExec) - R cannot be recovered. STOP: reconstruct it from the WithdrawalExecuted tx before resuming"
        );
        uint256 bal = IERC20(DOLA).balanceOf(OWNER);
        require(
            bal > ownerDolaBeforeExec,
            "Phase6b: OWNER holds no DOLA above its pre-execution balance - the recovered collateral is not on OWNER. STOP"
        );
        r = bal - ownerDolaBeforeExec;
    }

    function _requireRecoveryWithinBound(uint256 r) internal view {
        uint256 p = minterPrincipalBeforeExec;
        require(p > 0, "Phase6b: recorded minter principal P is 0");
        if (r < p) {
            require(
                p - r <= p * _maxLossBps(YS_DOLA) / CUTOVER_MAX_BPS + WEI_SLACK,
                "Phase6b: minter totalWithdrawal recovered less DOLA than the autoDOLA loss bound allows - STOP AND REPORT"
            );
        }
    }

    /// @dev Steps 4 (client + approval) and 5 (re-seed), deliberately BEFORE the registration: `noMintDeposit` takes the
    ///      strategy as an argument and needs only client + approval, so the collateral leaves the OWNER EOA one
    ///      transaction sooner and the registration never points the minter at an empty strategy.
    function _minterReseedSdola() internal {
        if (_doneMinterReseeded()) {
            console.log("  minter collateral already re-seeded into the sDOLA strategy - skipped");
            return;
        }
        require(_doneMinterWithdrawalExecuted(), "Phase6b: re-seed before the minter withdrawal executed");
        if (!_doneMinterClientOnSdola()) sdolaStrategy.setClient(PHUSD_STABLE_MINTER, true);
        require(_doneMinterClientOnSdola(), "Phase6b: sDOLA strategy setClient(minter) did not land");
        if (!_doneMinterApprovedSdola()) PhusdStableMinter(PHUSD_STABLE_MINTER).approveYS(DOLA, address(sdolaStrategy));
        require(_doneMinterApprovedSdola(), "Phase6b: minter approveYS(DOLA, sDOLA strategy) did not land");

        uint256 r = _recoveredDolaOnChain();
        _requireRecoveryWithinBound(r);
        if (minterRecoveredRecorded && minterRecovered != r) {
            console.log("  NOTE: recorded R differs from OWNER's live DOLA delta - re-seeding the live delta (recorded / live):", minterRecovered, r);
        }
        minterRecovered = r;
        minterRecoveredRecorded = true;
        _writeProgress("in_progress");

        // Story 094 (human decision): approve ceil(1.5 * R) as headroom; the deposit stays exactly R (noMintDeposit pulls
        // the literal amount, so the headroom neither sweeps nor strands anything). Re-approve only when the allowance
        // does not already cover R, so a resume after a landed approve keeps its headroom; a non-zero allowance below R is
        // zeroed first (forceApprove semantics by hand: OWNER is an EOA, SafeERC20 is a library for contracts). The ~0.5R
        // left as allowance is harmless - noMintDeposit is onlyOwner and pulls only from msg.sender - and is not zeroed,
        // to save a transaction.
        uint256 allowance = IERC20(DOLA).allowance(OWNER, PHUSD_STABLE_MINTER);
        if (allowance < r) {
            if (allowance != 0) IERC20(DOLA).approve(PHUSD_STABLE_MINTER, 0);
            IERC20(DOLA).approve(PHUSD_STABLE_MINTER, (r * 3 + 1) / 2);
        }
        PhusdStableMinter(PHUSD_STABLE_MINTER).noMintDeposit(address(sdolaStrategy), DOLA, r);

        require(_doneMinterReseeded(), "Phase6b: minter principal on the sDOLA strategy not within bound of R after noMintDeposit");
        require(IERC20(DOLA).balanceOf(OWNER) == ownerDolaBeforeExec, "Phase6b: OWNER DOLA not back to its pre-execution level");
        console.log("  re-seeded (R / minter principal on sDOLA strategy):", r, sdolaStrategy.principalOf(DOLA, PHUSD_STABLE_MINTER));
    }

    /// @dev Step 4 (registration): same exchangeRate and decimals, then restore maxMintPerDay (reset to 0 by
    ///      registerStablecoin) and the previous enabled flag (registerStablecoin sets true).
    function _minterRegisterSdola() internal {
        require(minterConfigRecorded, "Phase6b: no recorded pre-repoint minter config - STOP");
        require(_doneMinterReseeded(), "Phase6b: refusing to register the minter on the sDOLA strategy before its collateral is re-seeded");
        PhusdStableMinter m = PhusdStableMinter(PHUSD_STABLE_MINTER);
        (address ys,,,,,,) = m.stablecoinConfigs(DOLA);
        if (ys != address(sdolaStrategy)) {
            m.registerStablecoin(DOLA, address(sdolaStrategy), minterPrevExchangeRate, minterPrevDecimals);
            console.log("  registerStablecoin(DOLA, sDOLA strategy, previous rate, previous decimals)");
        }
        (, , , bool enabled, uint256 maxPerDay,,) = m.stablecoinConfigs(DOLA);
        if (maxPerDay != minterPrevMaxMintPerDay) m.setMaxMintPerDay(DOLA, minterPrevMaxMintPerDay);
        if (enabled != minterPrevEnabled) m.setStablecoinEnabled(DOLA, minterPrevEnabled);
        require(_doneMinterRepointed(), "Phase6b: minter DOLA registration / rate / decimals / maxMintPerDay / enabled not restored on the sDOLA strategy");
        console.log("  minter DOLA -> sDOLA strategy; maxMintPerDay restored:", minterPrevMaxMintPerDay);
    }

    /// @dev SYA: add the sDOLA strategy, remove the autoDOLA source (SYA's removeYieldStrategy finds it BY VALUE and
    ///      swap-and-pops - no index is assumed here), then revoke SYA as a withdrawer on the source. `claim` skims every
    ///      listed strategy with a whenNotPaused `skimSurplus`, so the source must leave the list BEFORE it is paused.
    function _syaRepointDola() internal {
        ISyaStrategyList sya = ISyaStrategyList(STABLE_YIELD_ACCUMULATOR);
        if (!sya.isRegisteredStrategy(address(sdolaStrategy))) sya.addYieldStrategy(address(sdolaStrategy), DOLA);
        if (sya.isRegisteredStrategy(YS_DOLA)) sya.removeYieldStrategy(YS_DOLA);
        require(_doneSyaListRepointed(), "Phase6b: SYA strategy list does not hold the sDOLA strategy (token DOLA) without the autoDOLA strategy");
        if (ISourceDolaStrategy(YS_DOLA).authorizedWithdrawers(STABLE_YIELD_ACCUMULATOR)) {
            ISourceDolaStrategy(YS_DOLA).setWithdrawer(STABLE_YIELD_ACCUMULATOR, false);
        }
        require(_doneSourceWithdrawerRevoked(), "Phase6b: SYA still a withdrawer on the autoDOLA strategy");
        require(_doneSdolaStrategyWithdrawer(), "Phase6b: SYA is not a withdrawer on the sDOLA strategy (Phase 3b)");
        console.log("  SYA: +sDOLA strategy, -autoDOLA strategy; autoDOLA withdrawer revoked");
    }

    /// @dev Retire the source (recorded decision, story 092): clients off, then the story-084 rule - setPauser(OWNER) ->
    ///      Pauser.unregister -> pause. The unregister requires the pauser to have left the Pauser, which forces ONE tx
    ///      where the global pause reverts (halt point g).
    function _retireSourceDola() internal {
        ISourceDolaStrategy src = ISourceDolaStrategy(YS_DOLA);
        if (src.authorizedClients(STABLE_STAKER_V1)) src.setClient(STABLE_STAKER_V1, false);
        if (src.authorizedClients(PHUSD_STABLE_MINTER)) src.setClient(PHUSD_STABLE_MINTER, false);
        require(_sourceDolaRetirementStarted(), "Phase6b: autoDOLA strategy clients V1 / minter not revoked");
        require(
            src.principalOf(DOLA, STABLE_STAKER_V1) == 0 && src.principalOf(DOLA, PHUSD_STABLE_MINTER) == 0,
            "Phase6b: autoDOLA strategy still books V1 / minter principal"
        );
        console.log("  autoDOLA strategy residual vault shares (expect dust):", ICutoverVault(src.vault()).balanceOf(YS_DOLA));

        if (IPausableLike(YS_DOLA).pauser() != OWNER) IPausableLike(YS_DOLA).setPauser(OWNER);
        require(IPausableLike(YS_DOLA).pauser() == OWNER, "Phase6b: autoDOLA strategy pauser not moved to OWNER");
        if (IPauserRegistry(PAUSER).isRegistered(YS_DOLA)) IPauserRegistry(PAUSER).unregister(YS_DOLA);
        require(!IPauserRegistry(PAUSER).isRegistered(YS_DOLA), "Phase6b: autoDOLA strategy still registered with Pauser");
        if (!IPausableLike(YS_DOLA).paused()) IPausableLike(YS_DOLA).pause();
        require(_doneSourceDolaRetired(), "Phase6b: autoDOLA strategy not retired (pauser OWNER, unregistered, paused)");
        console.log("  autoDOLA strategy retired: no clients, pauser OWNER, unregistered from Pauser, paused");
    }

    // =====================================================================
    //  PHASE 7 - finalize
    // =====================================================================

    function _phase7_finalize() internal {
        console.log("\n=== Phase 7: finalize ===");
        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);

        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            address ys = _destinationStrategyFor(t); // V2's side: plan + buffer recipient
            require(_doneV1PoolMigrating(t), "Phase7: a V1 pool is not Migrating");
            PoolPlan memory rest = _planPool(v1, t, ys);
            require(rest.migratable.length == 0, "Phase7: migratable V1 stakers remain - refusing to finalize");

            // The recipient is GLOBAL per strategy. Repointed AFTER migration: skimSurplus is the only
            // reader, the migration never skims, and V1 is drained. A pre-story-047 strategy (the live
            // USDe one) has no recipient and pays each client its own buffer, so V2 already receives it.
            // Story 091: repointed on the DESTINATION only. The DOLA source (autoDOLA strategy) keeps recipient V1:
            // it is being drained, and story 092 retires it.
            if (!_doneBufferRecipientV2(ys)) {
                IYieldStrategy(ys).setSetAsideBufferRecipient(address(v2));
                require(_doneBufferRecipientV2(ys), "Phase7: setAsideBufferRecipient not repointed to V2");
                console.log("  setAsideBufferRecipient -> V2 on strategy:", ys);
            }
        }

        // Revoke only after every non-straggler has migrated (asserted just above). A straggler's own
        // later `userMigrate` would need to mint its frozen pending phUSD and will revert while that
        // pending is non-zero: accepted, stragglers are sub-cent dust and protocol safety comes first.
        if (!_v1MintRevoked()) {
            IPhUSDOwner(PHUSD).setMinter(STABLE_STAKER_V1, false);
            console.log("  phUSD.setMinter(V1, false) - retired staker's mint authority REVOKED");
        } else {
            console.log("  V1 phUSD mint already revoked - skipped");
        }
        require(_v1MintRevoked(), "Phase7: V1 phUSD mint not revoked");

        // V1 retirement BACKSTOP. Story 084 (audit L-04) moved the retirement itself into Phase 1: V1's
        // pauser moves to OWNER, V1 is UNREGISTERED from the Pauser and only THEN paused, so the global
        // `Pauser.pause()` loop (no try/catch) never reaches a registered V1 it cannot pause. On a normal
        // run every step of `_retireV1` below is already satisfied and skips; it stays here, idempotent,
        // so a state that drifted after Phase 1 is still corrected and asserted before finalizing.
        // V1 is left PAUSED (story 083); stragglers keep `userMigrate`, which is not pause-gated.
        // Must run BEFORE V2's pauser hand-back (the finalized marker).
        _retireV1("Phase7");

        // STORY 087 (audit-33 L-05): the mirror of Phase 1's rule - NEVER REGISTER A PAUSED CONTRACT. A paused
        // registrant makes `Pauser.pause()` revert `EnforcedPause()` for every registrant. Order:
        //   setPauser(PAUSER) -> unpause() -> register(V2) -> Antimatter setPauser(PAUSER) -> register(Antimatter)
        // The pauser hand-back stays FIRST: it is the finalized marker (`_doneCutoverFinalized`), so a resume
        // that halted after it skips Phase 3's re-pause and converges here. Unpausing before the hand-back
        // would leave "unpaused, pauser OWNER" and a resume would re-pause V2 in Phase 3. `unpause` is
        // owner-or-pauser, so it works after the hand-back. No tx in this block makes Pauser.pause() revert, but
        // two halts leave one contract OUTSIDE it for one tx (story 088): V2 after its unpause and before its
        // registration, Antimatter after its pauser hand-back and before its registration - unpaused, pauser
        // already the Pauser, unregistered. Remedy there is OWNER setPauser(OWNER) then pause() on that contract
        // (a direct pause() reverts onlyPauser); do not resume until cleared. See HALTED RUNS in the header.
        if (v2.pauser() != PAUSER) v2.setPauser(PAUSER);
        // Unpause BEFORE registering: a paused registrant makes Pauser.pause() revert EnforcedPause (audit-33 L-05).
        if (!_doneV2Unpaused()) v2.unpause();
        require(_doneV2Unpaused(), "Phase7: V2 still paused");
        if (!IPauserRegistry(PAUSER).isRegistered(address(v2))) IPauserRegistry(PAUSER).register(address(v2));
        if (antimatter.pauser() != PAUSER) antimatter.setPauser(PAUSER);
        if (!IPauserRegistry(PAUSER).isRegistered(address(antimatter))) {
            // Antimatter's pauser is address(0) from deployment until the line above, so nothing can pause it
            // before this point (`pause` is onlyPauser, and the Pauser only pauses registrants). A paused
            // Antimatter here means an out-of-band emergency: STOP rather than unpause it or register it paused.
            require(!antimatter.paused(), "Phase7: Antimatter is paused - refusing to register a paused contract (audit-33 L-05)");
            IPauserRegistry(PAUSER).register(address(antimatter));
        }
        require(_doneV2PauseWired(), "Phase7: V2 pauser / Pauser registration did not land");
        require(_doneAntimatterPauseWired(), "Phase7: Antimatter pauser / Pauser registration did not land");
        require(_doneClaimStillDisabled(), "Phase7: claimEnabled must stay false");
        console.log("  V1 pauser -> OWNER, unregistered from Pauser, left paused; V2 unpaused THEN registered; Antimatter registered");
    }

    // =====================================================================
    //  PHASE 8 - wiring assertions (both modes)
    // =====================================================================

    function _phase8_wiringAssertions() internal view {
        console.log("\n=== Phase 8: wiring assertions ===");
        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);

        require(antimatter.owner() == OWNER, "Phase8: Antimatter owner");
        require(keccak256(bytes(antimatter.name())) == keccak256("Antimatter"), "Phase8: Antimatter name");
        require(keccak256(bytes(antimatter.symbol())) == keccak256("AM"), "Phase8: Antimatter symbol");
        require(address(antimatter.phUSD()) == PHUSD, "Phase8: Antimatter.phUSD");
        require(address(antimatter.phUSDMinter()) == PHUSD_STABLE_MINTER, "Phase8: Antimatter.phUSDMinter");
        require(antimatter.isApprovedMinter(address(v2)), "Phase8: V2 not an Antimatter minter");
        require(!antimatter.isApprovedMinter(STABLE_STAKER_V1), "Phase8: V1 is an Antimatter minter");
        require(!antimatter.isApprovedMinter(address(migrator)), "Phase8: migrator is an Antimatter minter");
        require(antimatter.approvedMinterCount() == 1, "Phase8: Antimatter approved-minter set is not exactly {V2}");

        require(v2.phUSDMintAvailable(), "Phase8: V2 phUSD mint unavailable");
        require(!_canMintPhUSD(STABLE_STAKER_V1), "Phase8: V1 phUSD mint NOT revoked");
        if (GRANT_ANTIMATTER_PHUSD_MINT) require(_canMintPhUSD(address(antimatter)), "Phase8: Antimatter phUSD mint");
        _assertPhusdMinterDelta(true);

        address[] memory v2Tokens = v2.getStakedTokens();
        require(v2Tokens.length == tokens.length, "Phase8: V2 token set size != V1 token set size");
        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            address ys = _destinationStrategyFor(t);
            address src = _sourceStrategyFor(t);
            require(_contains(v2Tokens, t), "Phase8: V2 token set != V1 token set");
            require(address(v2.yieldStrategy(t)) == ys, "Phase8: V2 strategy");
            require(IClientGetter(ys).authorizedClients(address(v2)), "Phase8: V2 not a strategy client");
            require(ICutoverBuffer(ys).setAsideBufferSize(address(v2)) == v1BufferPct[t], "Phase8: V2 buffer %");
            (bool hasRecipient, address recipient) = _bufferRecipient(ys);
            if (hasRecipient) require(recipient == address(v2), "Phase8: buffer recipient != V2");
            (uint256 perSecond,,,) = v2.poolInfo(t);
            require(
                perSecond == (cPerDay[t] * RATE_NUMERATOR / RATE_DENOMINATOR) / 86400,
                "Phase8: V2 rate != 2.1x V1 rate"
            );
            require(v2.poolState(t) == StableStakerV2.PoolState.Active, "Phase8: V2 pool not Active");
            require(v2.autoAnnihilateAvailable(t), "Phase8: autoAnnihilate unavailable");
            require(v1.poolState(t) == POOL_MIGRATING, "Phase8: V1 pool not Migrating");
            require(
                ICutoverStrategy(src).principalOf(t, STABLE_STAKER_V1) == 0, "Phase8: V1 still books source strategy principal"
            );
            require(IPauserRegistry(PAUSER).isRegistered(ys), "Phase8: V2's destination strategy not registered with Pauser");
            (,,, uint256 v1Staked) = v1.poolInfo(t);
            require(v1Staked < _stragglerCap(t), "Phase8: V1 totalStaked is not sub-cap straggler dust");
            console.log("  pool OK (token / V2 stakers / V1 stragglers):", t, v2.stakerCount(t), v1.stakerCount(t));
        }

        require(_doneSdolaStrategyIdentity(), "Phase8: sDOLA strategy owner / underlyingToken / vault");
        require(_doneSdolaStrategyPauseWired(), "Phase8: sDOLA strategy pauser / Pauser registration");
        require(_doneSdolaStrategyWithdrawer(), "Phase8: StableYieldAccumulator not a withdrawer on the sDOLA strategy");
        require(address(v2.yieldStrategy(DOLA)) == address(sdolaStrategy), "Phase8: V2 DOLA strategy != sDOLA strategy");
        require(!sdolaStrategy.paused(), "Phase8: sDOLA strategy paused");

        // Story 092: minter collateral, SYA, retired source.
        require(minterConfigRecorded && minterRecoveredRecorded, "Phase8: minterMove records (pre-repoint config / R) absent");
        require(_doneMinterRepointed(), "Phase8: minter DOLA registration != sDOLA strategy with previous rate / decimals / maxMintPerDay / enabled");
        require(_doneMinterClientOnSdola(), "Phase8: minter not a client of the sDOLA strategy");
        require(sdolaStrategy.principalOf(DOLA, PHUSD_STABLE_MINTER) > 0, "Phase8: minter has no principal on the sDOLA strategy");
        require(_doneMinterReseeded(), "Phase8: minter principal on the sDOLA strategy below the bound of the recorded R");
        require(_doneSyaListRepointed(), "Phase8: SYA strategy list != (+sDOLA strategy, -autoDOLA strategy)");
        require(_doneSourceWithdrawerRevoked(), "Phase8: SYA still a withdrawer on the autoDOLA strategy");
        require(_sourceDolaRetirementStarted(), "Phase8: autoDOLA strategy clients V1 / minter not revoked");
        require(_doneMinterWithdrawalExecuted(), "Phase8: minter still books principal on the autoDOLA strategy");
        require(_doneSourceDolaRetired(), "Phase8: autoDOLA strategy not retired (pauser OWNER, unregistered, paused)");

        require(v2.pauser() == PAUSER, "Phase8: V2 pauser");
        require(antimatter.pauser() == PAUSER, "Phase8: Antimatter pauser");
        require(IPausableLike(STABLE_STAKER_V1).pauser() == OWNER, "Phase8: V1 pauser");
        require(!IPauserRegistry(PAUSER).isRegistered(STABLE_STAKER_V1), "Phase8: V1 still registered with Pauser");
        require(IPausableLike(STABLE_STAKER_V1).paused(), "Phase8: V1 not paused");
        require(IPauserRegistry(PAUSER).isRegistered(address(v2)), "Phase8: V2 not registered with Pauser");
        require(IPauserRegistry(PAUSER).isRegistered(address(antimatter)), "Phase8: Antimatter not registered");
        require(!v2.paused(), "Phase8: V2 paused");
        require(!v2.claimEnabled(), "Phase8: claimEnabled must be false");

        // Story 084 (audit L-03 option a): static registry sweep, view-compatible so BROADCAST mode gets
        // an end-state guarantee too. `Pauser.pause()` calls `pause()` on every registrant with no
        // try/catch, so ONE registrant that is already paused or whose pauser is not the Pauser bricks the
        // whole breaker. Preview additionally runs the real EYE-funded pause (`_assertGlobalPauseWorks`).
        // Story 092: the retired autoDOLA strategy is expected OUTSIDE the registry (unregistered, paused, pauser OWNER).
        address[] memory registrants = IPauserRegistry(PAUSER).getPausableContracts();
        require(registrants.length > 0, "Phase8: Pauser has no registrants");
        for (uint256 i = 0; i < registrants.length; i++) {
            address r = registrants[i];
            require(r != STABLE_STAKER_V1, "Phase8: V1 is listed by Pauser.getPausableContracts()");
            require(r != YS_DOLA, "Phase8: retired autoDOLA strategy is listed by Pauser.getPausableContracts()");
            require(
                IPausableLike(r).pauser() == PAUSER,
                string.concat("Phase8: registrant pauser != Pauser (bricks global pause): ", vm.toString(r))
            );
            require(
                !IPausableLike(r).paused(),
                string.concat("Phase8: registrant already paused (bricks global pause): ", vm.toString(r))
            );
        }
        console.log("  Pauser registrant sweep OK (every registrant unpaused, pauser == Pauser):", registrants.length);
        console.log("  all wiring assertions passed");
    }

    // =====================================================================
    //  STORY 084 - simulated global pause (PREVIEW ONLY)
    // =====================================================================

    /// @dev Stages (in order) at which the simulated EYE-funded `Pauser.pause()` succeeded. Recorded AFTER
    ///      the snapshot is reverted so the record survives; the test harness reads it.
    string[] public globalPauseStagesPassed;

    function globalPauseStageCount() external view returns (uint256) {
        return globalPauseStagesPassed.length;
    }

    /// @dev Proves "registered means actually pausable" (audit L-03 clause b, L-04): inside a state snapshot,
    ///      funds a throwaway actor with the Pauser's EYE burn amount, has it call the permissionless
    ///      `Pauser.pause()` and requires every registrant to report paused, then reverts the snapshot.
    ///      PREVIEW ONLY - never deal/prank/snapshot in a broadcast session. The caller must not have an
    ///      active `startPrank`.
    ///      `tolerateV1Only`: at Phase 0 of a RESUME from "V1 paused, pauser OWNER, still registered" the
    ///      breaker is genuinely dead until Phase 1 unregisters V1. That exact, self-healing case is
    ///      reported loudly and allowed through; any other broken registrant still reverts. Every later call
    ///      (after each of Phases 1-8, story 087) passes `false` and is strict.
    function _assertGlobalPauseWorks(string memory stage, bool tolerateV1Only) internal {
        require(isPreview, "simulated global pause is preview-only");
        IPauserRegistry pauser = IPauserRegistry(PAUSER);
        address eye = pauser.eyeToken();
        uint256 burn = pauser.eyeBurnAmount();
        address[] memory registrants = pauser.getPausableContracts();

        uint256 snap = vm.snapshotState();
        address actor = makeAddr("story084-global-pause-actor");
        deal(eye, actor, burn, false);
        require(IERC20(eye).balanceOf(actor) >= burn, "globalPause: could not fund actor with EYE (deal failed)");
        vm.prank(actor);
        IERC20(eye).approve(PAUSER, burn);
        vm.prank(actor);
        (bool ok,) = PAUSER.call(abi.encodeWithSignature("pause()"));
        bool allPaused = ok;
        if (ok) {
            for (uint256 i = 0; i < registrants.length; i++) {
                if (!IPausableLike(registrants[i]).paused()) {
                    allPaused = false;
                    break;
                }
            }
        }
        vm.revertToState(snap);

        if (ok && allPaused) {
            globalPauseStagesPassed.push(stage);
            console.log(string.concat("GLOBAL_PAUSE|", stage, "|SUCCEEDED|registered=", vm.toString(registrants.length)));
            return;
        }

        // Diagnose: probe each registrant's own pause() as the Pauser, in order, inside a fresh snapshot,
        // exactly as the Pauser loop would reach them.
        address culprit = address(0);
        snap = vm.snapshotState();
        for (uint256 i = 0; i < registrants.length; i++) {
            vm.prank(PAUSER);
            (bool pOk,) = registrants[i].call(abi.encodeWithSignature("pause()"));
            if (!pOk || !IPausableLike(registrants[i]).paused()) {
                culprit = registrants[i];
                break;
            }
        }
        vm.revertToState(snap);

        if (tolerateV1Only && culprit == STABLE_STAKER_V1 && _onlyV1BreaksPause(registrants)) {
            console.log(
                string.concat(
                    "GLOBAL_PAUSE|", stage, "|BROKEN_BY_V1|registered=", vm.toString(registrants.length),
                    " - WARNING: the permissionless breaker is DEAD right now; Phase 1 unregisters V1 and the post-Phase-1 check is strict"
                )
            );
            return;
        }
        console.log(string.concat("GLOBAL_PAUSE|", stage, "|REVERTED|registered=", vm.toString(registrants.length)));
        revert(
            string.concat(
                "globalPause(", stage, "): Pauser.pause() does not pause every registrant; first failing registrant: ",
                vm.toString(culprit)
            )
        );
    }

    /// @dev True iff V1 is the ONLY registrant whose own pause() fails when called by the Pauser.
    function _onlyV1BreaksPause(address[] memory registrants) internal returns (bool) {
        uint256 snap = vm.snapshotState();
        bool onlyV1 = true;
        for (uint256 i = 0; i < registrants.length; i++) {
            if (registrants[i] == STABLE_STAKER_V1) continue;
            vm.prank(PAUSER);
            (bool pOk,) = registrants[i].call(abi.encodeWithSignature("pause()"));
            if (!pOk || !IPausableLike(registrants[i]).paused()) {
                onlyV1 = false;
                break;
            }
        }
        vm.revertToState(snap);
        return onlyV1;
    }

    // =====================================================================
    //  PREVIEW-ONLY smoke tests (prank, never broadcast)
    // =====================================================================

    function _previewSmokeTests() internal {
        require(isPreview, "smoke tests are preview-only");
        console.log("\n=== Preview smoke tests ===");
        _probeAntimatterMintRevocation();
        for (uint256 i = 0; i < tokens.length; i++) {
            _probeStakeWithdraw(tokens[i]);
        }
        _probeAutoAnnihilate(DOLA);
        console.log("  all smoke tests passed");
    }

    /// @dev USER-MANDATED: "please double check that antimatter mint rights can be revoked".
    function _probeAntimatterMintRevocation() internal {
        address throwaway = makeAddr("story082-throwaway-minter");
        vm.prank(OWNER);
        antimatter.setApprovedMinter(throwaway, true);
        vm.prank(throwaway);
        antimatter.mint(throwaway, 1);
        require(antimatter.balanceOf(throwaway) == 1, "smoke: approved throwaway could not mint");
        vm.prank(OWNER);
        antimatter.setApprovedMinter(throwaway, false);
        vm.prank(throwaway);
        try antimatter.mint(throwaway, 1) {
            revert("smoke: REVOKED throwaway minter could still mint Antimatter");
        } catch {}
        console.log("  Antimatter: throwaway approved -> minted -> revoked -> mint REVERTS");

        vm.prank(OWNER);
        antimatter.setApprovedMinter(address(v2), false);
        vm.prank(address(v2));
        try antimatter.mint(address(v2), 1) {
            revert("smoke: REVOKED V2 could still mint Antimatter");
        } catch {}
        vm.prank(OWNER);
        antimatter.setApprovedMinter(address(v2), true);
        require(antimatter.isApprovedMinter(address(v2)), "smoke: V2 minter not restored");
        console.log("  Antimatter: V2 revoked -> mint REVERTS -> V2 re-approved");
    }

    function _probeStakeWithdraw(address t) internal {
        address actor = makeAddr(string.concat("story082-staker-", IERC20Metadata(t).symbol()));
        uint256 amount = 100 * 10 ** IERC20Metadata(t).decimals();
        deal(t, actor, amount);
        vm.startPrank(actor);
        IERC20(t).approve(address(v2), amount);
        v2.stake(t, amount);
        (uint256 principal,) = v2.userInfo(t, actor);
        require(principal > 0, "smoke: V2 stake credited nothing");
        v2.withdraw(t, principal);
        vm.stopPrank();
        (uint256 left,) = v2.userInfo(t, actor);
        require(left == 0, "smoke: V2 withdraw left principal");
        console.log("  V2 stake/withdraw OK (token / credited / returned):", t, principal, IERC20(t).balanceOf(actor));
    }

    function _probeAutoAnnihilate(address t) internal {
        address actor = makeAddr("story082-annihilator");
        uint256 amount = 1000 * 10 ** IERC20Metadata(t).decimals();
        deal(t, actor, amount);
        vm.startPrank(actor);
        IERC20(t).approve(address(v2), amount);
        v2.stake(t, amount);
        vm.stopPrank();
        // 10 minutes, NOT a day: the autoDOLA autopool values through Tokemak's root price oracle,
        // whose Chainlink feeds revert as stale after a long warp. The probe is about wiring, not
        // accrual size - any non-zero accrual exercises the full annihilate path.
        vm.warp(block.timestamp + 10 minutes);
        uint256 owed = v2.claimableReward(t, actor);
        require(owed > 0, "smoke: no Antimatter accrued after the warp");
        uint256 phBefore = IERC20(PHUSD).balanceOf(actor);
        address minterYs = _minterYieldStrategy(t);
        uint256 minterPrincipalBefore = ICutoverStrategy(minterYs).principalOf(t, PHUSD_STABLE_MINTER);
        vm.prank(actor);
        v2.autoAnnihilate(t);
        uint256 phAfter = IERC20(PHUSD).balanceOf(actor);
        require(phAfter > phBefore, "smoke: autoAnnihilate paid no phUSD");
        // Story 092: the annihilation's minter.mint deposit must land in the sDOLA strategy for DOLA.
        if (t == DOLA) require(minterYs == address(sdolaStrategy), "smoke: minter DOLA registration is not the sDOLA strategy");
        require(
            ICutoverStrategy(minterYs).principalOf(t, PHUSD_STABLE_MINTER) > minterPrincipalBefore,
            "smoke: autoAnnihilate did not deposit into the minter's registered strategy"
        );
        console.log("  autoAnnihilate OK (Antimatter owed / phUSD paid):", owed, phAfter - phBefore);
    }

    // =====================================================================
    //  phUSD minter set - two-sided delta (story 076 style)
    // =====================================================================

    function _phusdMinterCandidates() internal pure returns (address[] memory set) {
        set = new address[](9);
        set[0] = STABLE_STAKER_V1; // PHUSD_MINTER_BIT_V1 - the ONLY bit this cutover may clear
        set[1] = OWNER;
        set[2] = PHUSD_STABLE_MINTER;
        set[3] = PHLIMBO_V3;
        set[4] = HOOK_EYE;
        set[5] = HOOK_SCX;
        set[6] = HOOK_FLX;
        set[7] = HOOK_POOLER;
        set[8] = HOOK_RATCHET;
    }

    function _liveMinterMask() internal view returns (uint256 mask) {
        address[] memory set = _phusdMinterCandidates();
        for (uint256 i = 0; i < set.length; i++) {
            if (_canMintPhUSD(set[i])) mask |= (1 << i);
        }
    }

    /// @dev Write-once: a persisted baseline always wins so a resume leg can never overwrite the true
    ///      pre-cutover reading with a post-cutover one.
    function _snapshotPhusdMinterSet() internal {
        if (phusdBaselineRecorded) {
            console.log("  phUSD minter baseline (from progress file) mask / mintVersion:", phusdMaskAtPhase0, phusdMintVersionAtPhase0);
            return;
        }
        phusdMaskAtPhase0 = _liveMinterMask();
        phusdMintVersionAtPhase0 = IPhUSDOwner(PHUSD).mintVersion();
        phusdBaselineRecorded = true;
        console.log("  phUSD minter baseline (live) mask / mintVersion:", phusdMaskAtPhase0, phusdMintVersionAtPhase0);
        require(
            phusdMaskAtPhase0 & (1 << PHUSD_MINTER_BIT_V1) != 0 || _allV1PoolsMigrating(),
            "Phase0: V1 phUSD mint absent at baseline while V1 pools are un-initiated"
        );
    }

    /// @dev Candidate mask must equal the baseline, except the V1 bit which must be cleared iff
    ///      `expectV1Revoked`. Plus the positives (V2, Antimatter) and the negatives (migrator,
    ///      StableYieldAccumulator unchanged-false), and an unchanged global mintVersion.
    function _assertPhusdMinterDelta(bool expectV1Revoked) internal view {
        require(IPhUSDOwner(PHUSD).mintVersion() == phusdMintVersionAtPhase0, "minter-delta: phUSD mintVersion moved");
        uint256 expected = phusdMaskAtPhase0;
        if (expectV1Revoked) expected &= ~(uint256(1) << PHUSD_MINTER_BIT_V1);
        uint256 live = _liveMinterMask();
        require(live == expected, "minter-delta: phUSD minter candidate set changed beyond the expected V1 revoke");
        require(_canMintPhUSD(address(v2)), "minter-delta: V2 must hold phUSD mint");
        if (GRANT_ANTIMATTER_PHUSD_MINT) require(_canMintPhUSD(address(antimatter)), "minter-delta: Antimatter must hold phUSD mint");
        if (address(migrator) != address(0)) {
            require(!_canMintPhUSD(address(migrator)), "minter-delta: CrossVersionMigrator must NOT hold phUSD mint");
        }
        require(!_canMintPhUSD(STABLE_YIELD_ACCUMULATOR), "minter-delta: StableYieldAccumulator gained phUSD mint");
        console.log("  phUSD minter delta OK (live mask / V1 revoked):", live, expectV1Revoked);
    }

    // =====================================================================
    //  STORY 086 - on-chain DONE predicates (audit L-02)
    // =====================================================================
    //  Every phase gate above has the form `if (!done) do();`. The `done` half lives here, as a
    //  `view` predicate over LIVE chain state, and is shared verbatim by
    //  `script/VerifyStableStakerV2Cutover.s.sol`, which `require`s each one instead of performing the
    //  step. One definition per condition, so the gate and the verifier cannot drift apart.
    //  Predicates that dereference `antimatter` / `v2` / `migrator` return false while that address is
    //  unset, so the verifier reports "not on chain" rather than reverting on a call to address(0).

    // ---- Phase 1 / Phase 7 backstop: V1 retirement triple ----
    function _v1PauserIsOwner() internal view returns (bool) {
        return IPausableLike(STABLE_STAKER_V1).pauser() == OWNER;
    }

    function _v1UnregisteredFromPauser() internal view returns (bool) {
        return !IPauserRegistry(PAUSER).isRegistered(STABLE_STAKER_V1);
    }

    function _v1Paused() internal view returns (bool) {
        return IPausableLike(STABLE_STAKER_V1).paused();
    }

    /// @dev The finalized marker: V2's pauser is handed to the Pauser in Phase 7 only.
    function _doneCutoverFinalized() internal view returns (bool) {
        return address(v2) != address(0) && v2.pauser() == PAUSER;
    }

    // ---- Phase 2: Antimatter ----
    function _doneAntimatterIdentity() internal view returns (bool) {
        return address(antimatter).code.length > 0 && keccak256(bytes(antimatter.name())) == keccak256("Antimatter")
            && keccak256(bytes(antimatter.symbol())) == keccak256("AM") && antimatter.owner() == OWNER;
    }

    function _doneAntimatterWired() internal view returns (bool) {
        return address(antimatter).code.length > 0 && address(antimatter.phUSD()) == PHUSD
            && address(antimatter.phUSDMinter()) == PHUSD_STABLE_MINTER;
    }

    // ---- Phase 3: StableStakerV2 ----
    function _doneStakerV2Identity() internal view returns (bool) {
        return address(v2).code.length > 0 && v2.STAKER_VERSION() == 2 && address(v2.antimatter()) == address(antimatter)
            && v2.owner() == OWNER;
    }

    // ---- Phase 3b: sDOLA destination strategy (story 091) ----
    function _doneSdolaStrategyIdentity() internal view returns (bool) {
        return address(sdolaStrategy).code.length > 0 && sdolaStrategy.owner() == OWNER
            && address(sdolaStrategy.underlyingToken()) == DOLA && address(sdolaStrategy.vault()) == SDOLA;
    }

    function _doneSdolaStrategyPauseWired() internal view returns (bool) {
        return address(sdolaStrategy).code.length > 0 && sdolaStrategy.pauser() == PAUSER
            && IPauserRegistry(PAUSER).isRegistered(address(sdolaStrategy));
    }

    function _doneSdolaStrategyWithdrawer() internal view returns (bool) {
        return address(sdolaStrategy).code.length > 0 && sdolaStrategy.authorizedWithdrawers(STABLE_YIELD_ACCUMULATOR);
    }

    // ---- Phase 4: per-token pool setup ----
    function _donePoolTokenAdded(address t) internal view returns (bool) {
        return _contains(v2.getStakedTokens(), t);
    }

    function _donePoolClientSet(address t) internal view returns (bool) {
        return IClientGetter(_destinationStrategyFor(t)).authorizedClients(address(v2));
    }

    function _donePoolStrategySet(address t) internal view returns (bool) {
        return address(v2.yieldStrategy(t)) == _destinationStrategyFor(t);
    }

    function _donePoolBufferCopied(address t) internal view returns (bool) {
        return ICutoverBuffer(_destinationStrategyFor(t)).setAsideBufferSize(address(v2)) == v1BufferPct[t];
    }

    /// @dev Requires `cPerDay[t]` hydrated by Phase 0.
    function _donePoolRateSet(address t) internal view returns (bool) {
        (uint256 perSecond,,,) = v2.poolInfo(t);
        return perSecond == (cPerDay[t] * RATE_NUMERATOR / RATE_DENOMINATOR) / 86400;
    }

    // ---- Phase 5: mint rights ----
    function _doneV2AntimatterMinter() internal view returns (bool) {
        return antimatter.isApprovedMinter(address(v2));
    }

    function _doneV2PhusdMinter() internal view returns (bool) {
        return v2.phUSDMintAvailable();
    }

    function _doneAntimatterPhusdMinter() internal view returns (bool) {
        return _canMintPhUSD(address(antimatter));
    }

    // ---- Phase 6: migration ----
    function _doneMigratorIdentity() internal view returns (bool) {
        return address(migrator).code.length > 0 && address(migrator.oldStaker()) == STABLE_STAKER_V1
            && address(migrator.newStaker()) == address(v2) && migrator.owner() == OWNER;
    }

    function _doneMigratorWired() internal view returns (bool) {
        return address(migrator) != address(0) && IMigratorRole(STABLE_STAKER_V1).migrator() == address(migrator)
            && v2.migrator() == address(migrator);
    }

    function _doneV1PoolMigrating(address t) internal view returns (bool) {
        return ICutoverStaker(STABLE_STAKER_V1).poolState(t) == POOL_MIGRATING;
    }

    // ---- Phase 7: finalize ----
    /// @dev A pre-story-047 strategy has no recipient getter and pays each client directly: done by construction.
    function _doneBufferRecipientV2(address ys) internal view returns (bool) {
        (bool hasRecipient, address recipient) = _bufferRecipient(ys);
        return !hasRecipient || recipient == address(v2);
    }

    function _v1MintRevoked() internal view returns (bool) {
        return !_canMintPhUSD(STABLE_STAKER_V1);
    }

    function _doneV2PauseWired() internal view returns (bool) {
        return v2.pauser() == PAUSER && IPauserRegistry(PAUSER).isRegistered(address(v2));
    }

    function _doneAntimatterPauseWired() internal view returns (bool) {
        return antimatter.pauser() == PAUSER && IPauserRegistry(PAUSER).isRegistered(address(antimatter));
    }

    function _doneV2Unpaused() internal view returns (bool) {
        return !v2.paused();
    }

    function _doneClaimStillDisabled() internal view returns (bool) {
        return !v2.claimEnabled();
    }

    // ---- Phase 6b: minter collateral, SYA, retired source (story 092) ----
    function _minterYieldStrategy(address t) internal view returns (address ys) {
        (ys,,,,,,) = PhusdStableMinter(PHUSD_STABLE_MINTER).stablecoinConfigs(t);
    }

    function _minterDolaEnabled() internal view returns (bool enabled) {
        (,,, enabled,,,) = PhusdStableMinter(PHUSD_STABLE_MINTER).stablecoinConfigs(DOLA);
    }

    /// @dev The minter's autoDOLA principal is zero. True only after the execute: Phase 0 of a fresh run requires it
    ///      non-zero implicitly (the window preflight), and DOLA minting is disabled before the execute.
    function _doneMinterWithdrawalExecuted() internal view returns (bool) {
        return ICutoverStrategy(YS_DOLA).principalOf(DOLA, PHUSD_STABLE_MINTER) == 0;
    }

    function _doneMinterClientOnSdola() internal view returns (bool) {
        return address(sdolaStrategy).code.length > 0 && sdolaStrategy.authorizedClients(PHUSD_STABLE_MINTER);
    }

    /// @dev approveYS grants type(uint256).max; half of it tolerates a token that decrements max allowances.
    function _doneMinterApprovedSdola() internal view returns (bool) {
        return address(sdolaStrategy) != address(0)
            && IERC20(DOLA).allowance(PHUSD_STABLE_MINTER, address(sdolaStrategy)) >= type(uint256).max / 2;
    }

    /// @dev R recorded and the minter's sDOLA principal is within the destination's loss bound of it (the lower side
    ///      only: organic DOLA mints after the repoint only add principal).
    function _doneMinterReseeded() internal view returns (bool) {
        if (!minterRecoveredRecorded || address(sdolaStrategy).code.length == 0) return false;
        uint256 principal = sdolaStrategy.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 r = minterRecovered;
        return principal > 0 && principal + r * _maxLossBps(address(sdolaStrategy)) / CUTOVER_MAX_BPS + WEI_SLACK >= r;
    }

    function _doneMinterRepointed() internal view returns (bool) {
        if (!minterConfigRecorded || address(sdolaStrategy) == address(0)) return false;
        (address ys, uint256 rate, uint8 dec, bool enabled, uint256 maxPerDay,,) =
            PhusdStableMinter(PHUSD_STABLE_MINTER).stablecoinConfigs(DOLA);
        return ys == address(sdolaStrategy) && rate == minterPrevExchangeRate && dec == minterPrevDecimals
            && enabled == minterPrevEnabled && maxPerDay == minterPrevMaxMintPerDay;
    }

    function _doneSyaListRepointed() internal view returns (bool) {
        ISyaStrategyList sya = ISyaStrategyList(STABLE_YIELD_ACCUMULATOR);
        address[] memory list = sya.getYieldStrategies();
        return address(sdolaStrategy) != address(0) && _contains(list, address(sdolaStrategy)) && !_contains(list, YS_DOLA)
            && sya.strategyTokens(address(sdolaStrategy)) == DOLA;
    }

    function _doneSourceWithdrawerRevoked() internal view returns (bool) {
        return !ISourceDolaStrategy(YS_DOLA).authorizedWithdrawers(STABLE_YIELD_ACCUMULATOR);
    }

    /// @dev Neither V1 nor the minter is a client of the autoDOLA source any more: its retirement has begun.
    function _sourceDolaRetirementStarted() internal view returns (bool) {
        ISourceDolaStrategy src = ISourceDolaStrategy(YS_DOLA);
        return !src.authorizedClients(STABLE_STAKER_V1) && !src.authorizedClients(PHUSD_STABLE_MINTER);
    }

    function _doneSourceDolaRetired() internal view returns (bool) {
        return _sourceDolaRetirementStarted() && IPausableLike(YS_DOLA).pauser() == OWNER
            && !IPauserRegistry(PAUSER).isRegistered(YS_DOLA) && IPausableLike(YS_DOLA).paused();
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    /// @dev Story 091: V1's EXIT side - the strategy V1 staked through. Hard-coded (see the constants' NatSpec).
    ///      Use for: Phase 0 V1 checks + V1 buffer pct, `_initiatePool` (relinquish, maxRedeem), the exit-realization
    ///      bound, and `principalOf(token, V1) == 0`.
    function _sourceStrategyFor(address t) internal pure returns (address) {
        if (t == DOLA) return YS_DOLA;
        if (t == USDC) return YS_USDC;
        if (t == USDE) return YS_USDE;
        revert("V1 stakes a token with no known strategy - STOP AND REPORT (update the strategy map deliberately)");
    }

    /// @dev Story 091: V2's DEPOSIT side. USDC / USDe: the same strategy as the source. DOLA: the sDOLA strategy
    ///      Phase 3b deploys, recovered from the progress file on resume; reverts while it is unknown so no V2 step
    ///      can silently fall back to the autoDOLA strategy.
    ///      Use for: Phase 4 wiring, `_planPool` / `_depositWouldFail` / maxDeposit, Phase 7 buffer recipient, Phase 8.
    function _destinationStrategyFor(address t) internal view returns (address) {
        if (t == DOLA) {
            require(
                address(sdolaStrategy) != address(0),
                "DOLA destination (sDOLA strategy) unknown - Phase 3b has not deployed it and the progress file does not name it"
            );
            return address(sdolaStrategy);
        }
        return _sourceStrategyFor(t);
    }

    /// @dev Story 091: per-user pre -> credited loss bound for `t` (source + destination bps, once when equal).
    ///      The verifier's per-user re-check and per-pool aggregate use the same rule.
    function _perUserLossBpsFor(address t) internal view returns (uint256) {
        address src = _sourceStrategyFor(t);
        address dst = _destinationStrategyFor(t);
        return _perUserLossBps(src, dst, _maxLossBps(src), _maxLossBps(dst));
    }

    /// @dev Loss bound of ONE strategy, bps part (Phase 6 adds the absolute WEI_SLACK = 1000 wei on top, story 083).
    ///      Story 091: the pool's exit-realization bound (pre -> credit, on V1's immutable R / P) uses the SOURCE
    ///      strategy's bound; the per-user bound (pre -> credited) is `_perUserLossBpsFor` - source + destination when
    ///      they differ (DOLA: autoDOLA exit + sDOLA entry = 10), this bound once when they are the same strategy.
    ///      ERC4626 strategies: ERC4626_MAX_LOSS_BPS (WEI_SLACK is a separate wei term, not added here). The market strategy
    ///      haircuts TWICE: the V1 exit sells shares with minOut = ideal * (1 - bps) and the V2 re-deposit
    ///      books credited = credit * (1 - bps). Worst case 1 - (1 - bps)^2 < 2 * bps; +1 bps slack.
    function _maxLossBps(address ys) internal view returns (uint256) {
        if (_marketAdapter(ys) == address(0)) return ERC4626_MAX_LOSS_BPS;
        return 2 * ICutoverStrategy(ys).slippageToleranceBps() + 1;
    }

    function _stragglerCap(address t) internal view returns (uint256) {
        return 10 ** IERC20Metadata(t).decimals() * STRAGGLER_CAP_CENTS / 100;
    }

    function _canMintPhUSD(address who) internal view returns (bool) {
        (bool ok, bytes memory ret) = PHUSD.staticcall(abi.encodeWithSignature("authorizedMinters(address)", who));
        if (!ok || ret.length < 64) return false;
        (bool canMint, uint256 version) = abi.decode(ret, (bool, uint256));
        return canMint && version == IPhUSDOwner(PHUSD).mintVersion();
    }

    function _bufferRecipient(address ys) internal view returns (bool exists, address recipient) {
        (bool ok, bytes memory data) = ys.staticcall(abi.encodeWithSignature("setAsideBufferRecipient()"));
        if (!ok || data.length < 32) return (false, address(0));
        return (true, abi.decode(data, (address)));
    }

    function _allV1PoolsMigrating() internal view returns (bool) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (ICutoverStaker(STABLE_STAKER_V1).poolState(tokens[i]) != POOL_MIGRATING) return false;
        }
        return true;
    }

    function _owner(address c) internal view returns (address) {
        return IOwnableLike(c).owner();
    }

    function _contains(address[] memory set, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == a) return true;
        }
        return false;
    }

    // =====================================================================
    //  Progress file
    // =====================================================================

    function _loadProgressFile() internal {
        string memory json;
        try vm.readFile(PROGRESS_FILE) returns (string memory j) {
            json = j;
        } catch {
            console.log("No progress file - starting fresh");
            return;
        }
        if (bytes(json).length == 0) return;
        console.log("Found progress file, loading:", PROGRESS_FILE);
        antimatter = Antimatter(_loadAddress(json, "Antimatter"));
        v2 = StableStakerV2(_loadAddress(json, "StableStakerV2"));
        migrator = CrossVersionMigrator(_loadAddress(json, "CrossVersionMigrator"));
        sdolaStrategy = ERC4626YieldStrategy(_loadAddress(json, "ERC4626YieldStrategySDOLA"));
        if (vm.keyExistsJson(json, ".baselines.cutoverStartBlock")) {
            cutoverStartBlock = vm.parseUint(vm.parseJsonString(json, ".baselines.cutoverStartBlock"));
        }
        if (vm.keyExistsJson(json, ".baselines.phusdMinterMask")) {
            phusdMaskAtPhase0 = vm.parseUint(vm.parseJsonString(json, ".baselines.phusdMinterMask"));
            phusdMintVersionAtPhase0 = vm.parseUint(vm.parseJsonString(json, ".baselines.phusdMintVersion"));
            phusdBaselineRecorded = true;
        }
        // Story 092: Phase 6b records. Each group is adopted only when its flag says it was recorded.
        if (vm.keyExistsJson(json, ".minterMove.configRecorded") && _jsonFlag(json, ".minterMove.configRecorded")) {
            minterPrevExchangeRate = vm.parseUint(vm.parseJsonString(json, ".minterMove.prevExchangeRate"));
            minterPrevDecimals = uint8(vm.parseUint(vm.parseJsonString(json, ".minterMove.prevDecimals")));
            minterPrevEnabled = _jsonFlag(json, ".minterMove.prevEnabled");
            minterPrevMaxMintPerDay = vm.parseUint(vm.parseJsonString(json, ".minterMove.prevMaxMintPerDay"));
            minterConfigRecorded = true;
        }
        if (vm.keyExistsJson(json, ".minterMove.execRecorded") && _jsonFlag(json, ".minterMove.execRecorded")) {
            minterPrincipalBeforeExec = vm.parseUint(vm.parseJsonString(json, ".minterMove.principalBeforeExec"));
            ownerDolaBeforeExec = vm.parseUint(vm.parseJsonString(json, ".minterMove.ownerDolaBeforeExec"));
            minterExecRecorded = true;
        }
        if (vm.keyExistsJson(json, ".minterMove.recoveredRecorded") && _jsonFlag(json, ".minterMove.recoveredRecorded")) {
            minterRecovered = vm.parseUint(vm.parseJsonString(json, ".minterMove.recovered"));
            minterRecoveredRecorded = true;
        }
    }

    function _jsonFlag(string memory json, string memory key) internal pure returns (bool) {
        return keccak256(bytes(vm.parseJsonString(json, key))) == keccak256("true");
    }

    function _loadAddress(string memory json, string memory name) internal view returns (address addr) {
        string memory key = string.concat(".contracts.", name, ".address");
        if (!vm.keyExistsJson(json, key)) return address(0);
        addr = vm.parseJsonAddress(json, key);
        if (addr == address(0)) return address(0);
        require(
            addr.code.length > 0,
            string.concat(
                "Progress file names ", name,
                " at an address with NO CODE - it was recorded in forge's local pass but never landed. Trim the progress file to on-chain-confirmed deployments (run-latest.json receipts + cast nonce) and re-run preview."
            )
        );
        console.log("  loaded", name, addr);
    }

    function _writeProgress(string memory status) internal {
        lastProgressStatus = status;
        string memory c;
        c = _serializeEntry("Antimatter", address(antimatter));
        c = _serializeEntry("StableStakerV2", address(v2));
        c = _serializeEntry("CrossVersionMigrator", address(migrator));
        c = _serializeEntry("ERC4626YieldStrategySDOLA", address(sdolaStrategy));

        // Story 086: write-once lower bound for the verifier's per-user event scan.
        if (cutoverStartBlock == 0) cutoverStartBlock = block.number;
        vm.serializeString("s082.baselines", "cutoverStartBlock", vm.toString(cutoverStartBlock));
        vm.serializeString("s082.baselines", "phusdMinterMask", vm.toString(phusdMaskAtPhase0));
        string memory b = vm.serializeString("s082.baselines", "phusdMintVersion", vm.toString(phusdMintVersionAtPhase0));

        // Story 092: Phase 6b records (strings, flag-gated on load).
        vm.serializeString("s092.minter", "configRecorded", minterConfigRecorded ? "true" : "false");
        vm.serializeString("s092.minter", "prevExchangeRate", vm.toString(minterPrevExchangeRate));
        vm.serializeString("s092.minter", "prevDecimals", vm.toString(uint256(minterPrevDecimals)));
        vm.serializeString("s092.minter", "prevEnabled", minterPrevEnabled ? "true" : "false");
        vm.serializeString("s092.minter", "prevMaxMintPerDay", vm.toString(minterPrevMaxMintPerDay));
        vm.serializeString("s092.minter", "execRecorded", minterExecRecorded ? "true" : "false");
        vm.serializeString("s092.minter", "principalBeforeExec", vm.toString(minterPrincipalBeforeExec));
        vm.serializeString("s092.minter", "ownerDolaBeforeExec", vm.toString(ownerDolaBeforeExec));
        vm.serializeString("s092.minter", "recoveredRecorded", minterRecoveredRecorded ? "true" : "false");
        string memory mm = vm.serializeString("s092.minter", "recovered", vm.toString(minterRecovered));

        vm.serializeUint("s082.root", "chainId", CHAIN_ID);
        vm.serializeString("s082.root", "networkName", NETWORK_NAME);
        vm.serializeString("s082.root", "deploymentStatus", status);
        vm.serializeString("s082.root", "baselines", b);
        vm.serializeString("s082.root", "minterMove", mm);
        string memory json = vm.serializeString("s082.root", "contracts", c);

        // Preview serialises (same code path, same cost) but NEVER writes: a preview CREATE address is
        // fork-local fiction that would poison the patcher.
        if (isPreview) {
            console.log("  progress serialised (preview: NOT written); bytes:", bytes(json).length);
            return;
        }
        vm.writeFile(PROGRESS_FILE, json);
        console.log("  progress file updated:", status);
    }

    function _serializeEntry(string memory name, address addr) internal returns (string memory contractsJson) {
        string memory k = string.concat("s082.e.", name);
        vm.serializeAddress(k, "address", addr);
        string memory entry = vm.serializeBool(k, "deployed", addr != address(0));
        contractsJson = vm.serializeString("s082.contracts", name, entry);
    }

    function _printSummary() internal view {
        console.log("");
        console.log("=================================================");
        console.log("        STABLESTAKER V2 CUTOVER SUMMARY");
        console.log("=================================================");
        console.log("Antimatter:           ", address(antimatter));
        console.log("StableStakerV2:       ", address(v2));
        console.log("CrossVersionMigrator: ", address(migrator), "(transient, no address-book key)");
        console.log("sDOLA strategy:       ", address(sdolaStrategy), "(V2 DOLA destination + minter DOLA collateral; patched into YieldStrategyDola)");
        string memory mode = isPreview ? string("PREVIEW") : string("BROADCAST");
        console.log("Mode:                 ", mode);
    }
}

// =====================================================================
//  Minimal interfaces (all reads declared `view` so broadcast never records them as transactions)
// =====================================================================

interface IOwnableLike {
    function owner() external view returns (address);
}

interface IPausableLike {
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
}

interface IStakerTokens {
    function getStakedTokens() external view returns (address[] memory);
}

interface IYieldStrategyGetter {
    function yieldStrategy(address token) external view returns (address);
}

interface IMigratorRole {
    function migrator() external view returns (address);
    function setMigrator(address m) external;
}

interface ICutoverBuffer {
    function setAsideBufferSize(address client) external view returns (uint256);
}

interface IClientGetter {
    function authorizedClients(address client) external view returns (bool);
}

interface IERC4626AssetLike {
    function asset() external view returns (address);
}

interface IPhUSDOwner {
    function setMinter(address minter, bool canMint) external;
    function mintVersion() external view returns (uint256);
}

interface IPauserRegistry {
    function isRegistered(address c) external view returns (bool);
    function register(address c) external;
    function unregister(address pausableContract) external;
    function getPausableContracts() external view returns (address[] memory);
    function eyeToken() external view returns (address);
    function eyeBurnAmount() external view returns (uint256);
    function pause() external;
}

/// @dev Story 092: the live autoDOLA strategy 0x1760 (plain ERC4626YieldStrategy). Copied, not imported (archive precedent).
interface ISourceDolaStrategy {
    function WAITING_PERIOD() external view returns (uint256);
    function EXECUTION_WINDOW() external view returns (uint256);
    function withdrawalStates(address token, address client)
        external
        view
        returns (uint256 initiatedAt, uint8 status, uint256 balance);
    function totalWithdrawal(address token, address client) external;
    function principalOf(address token, address account) external view returns (uint256);
    function authorizedClients(address client) external view returns (bool);
    function authorizedWithdrawers(address withdrawer) external view returns (bool);
    function setClient(address client, bool auth) external;
    function setWithdrawer(address withdrawer, bool auth) external;
    function vault() external view returns (address);
}

/// @dev Story 092: lib/stable-yield-accumulator StableYieldAccumulator strategy registry.
interface ISyaStrategyList {
    function addYieldStrategy(address strategy, address token) external;
    function removeYieldStrategy(address strategy) external;
    function getYieldStrategies() external view returns (address[] memory);
    function isRegisteredStrategy(address strategy) external view returns (bool);
    function strategyTokens(address strategy) external view returns (address);
}
