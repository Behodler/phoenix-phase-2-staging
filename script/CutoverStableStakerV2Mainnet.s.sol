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
import {
    StableStakerCutoverCore,
    ICutoverStaker,
    ICutoverMigrator,
    ICutoverStrategy
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
 *   4  Per V1 token: addToken, strategy.setClient(V2), idle-balance guard, setYieldStrategy,
 *      setSetAsideBuffer(V2, <V1's>), antimatterPerDay(C * 21 / 10), autoAnnihilateAvailable.
 *   5  Mint rights: Antimatter.setApprovedMinter(V2), phUSD.setMinter(V2), phUSD.setMinter(Antimatter)
 *      (see the Phase 5 NatSpec for why the third grant exists), two-sided minter delta.
 *   6  CrossVersionMigrator; setMigrator on both; per token: relinquish surplus, initiate, plan
 *      (dust predicate), batch-migrate non-dust, allow-list stragglers under a cap, post-conditions.
 *   7  Finalize: repoint set-aside buffer recipient, revoke V1 phUSD mint, V1 retirement BACKSTOP (the
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
 *   PHASE 7 COVERAGE GAPS (story 088). Two Phase 7 halt points leave ONE contract outside the global pause:
 *     (a) V2, halted after its unpause and before Pauser.register(V2): V2 is unpaused, pauser == Pauser,
 *         unregistered. `Pauser.pause()` loops registrants only, so it succeeds and leaves V2 unpaused.
 *     (b) Antimatter, halted after its setPauser(Pauser) and before Pauser.register(Antimatter): same shape.
 *   Why (a) exposes nothing: all three strategies (YS_DOLA, YS_USDC, YS_USDE) are registered with the Pauser
 *   with pauser == Pauser (Phase 0 asserts it), and every V2 user action reverts under a strategy pause -
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

    /// @dev The strategy map is HARD-CODED rather than read off V1 because `initiateMigration` clears
    ///      `V1.yieldStrategy(token)`; a resume leg past initiation could otherwise not recover it.
    ///      Phase 0 asserts each entry against V1 (while Active) and V2 (once wired).
    address public constant YS_DOLA = 0x1760E05356Ec1FBBA159C730781dCfB9920524e2; // ERC4626YieldStrategy (autoDOLA)
    address public constant YS_USDC = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83; // ERC4626YieldStrategy (autoUSDC)
    address public constant YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95; // ERC4626MarketYieldStrategy (sUSDe, 30 bps)

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
    address[] public tokens;

    bool public phusdBaselineRecorded;
    uint256 public phusdMaskAtPhase0;
    uint256 public phusdMintVersionAtPhase0;

    mapping(address => uint256) public cPerDay; // token -> V1 phUSD per day (floored)
    mapping(address => uint256) public v1BufferPct; // token -> V1 setAsideBufferSize on its strategy

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
        _phase4_pools();
        _previewBreakerStage("after-phase4");
        _phase5_mintRights();
        _previewBreakerStage("after-phase5");
        _phase6_migration();
        _previewBreakerStage("after-phase6");
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

    function _phase0_preconditions() internal {
        console.log("\n=== Phase 0: preconditions ===");
        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);

        require(_owner(STABLE_STAKER_V1) == OWNER, "Phase0: V1 owner != OWNER");
        require(_owner(PHUSD) == OWNER, "Phase0: phUSD owner != OWNER");
        require(_owner(PAUSER) == OWNER, "Phase0: Pauser owner != OWNER");
        require(_owner(PHUSD_STABLE_MINTER) == OWNER, "Phase0: PhusdStableMinter owner != OWNER");
        address v1Pauser = IPausableLike(STABLE_STAKER_V1).pauser();
        require(v1Pauser == PAUSER || v1Pauser == OWNER, "Phase0: V1 pauser is neither Pauser nor OWNER");

        address[] memory live = IStakerTokens(STABLE_STAKER_V1).getStakedTokens();
        require(live.length > 0, "Phase0: V1 has no staked tokens");
        bool anyActive;
        for (uint256 i = 0; i < live.length; i++) {
            address t = live[i];
            tokens.push(t);
            address ys = _strategyFor(t); // reverts on a token with no known strategy
            require(_owner(ys) == OWNER, "Phase0: strategy owner != OWNER");
            require(!IPausableLike(ys).paused(), "Phase0: strategy paused - its withdraw/deposit are whenNotPaused");
            // Story 088: the Phase 7 V2 coverage gap (V2 unpaused, unregistered for one tx) exposes nothing ONLY
            // because a global pause stops every strategy V2 routes through. Assert that, read-only.
            require(IPauserRegistry(PAUSER).isRegistered(ys), "Phase0: strategy not registered with the global Pauser");
            require(IPausableLike(ys).pauser() == PAUSER, "Phase0: strategy pauser != Pauser");

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
    //  PHASE 4 - per-token pool setup, copied from V1's LIVE config
    // =====================================================================

    function _phase4_pools() internal {
        console.log("\n=== Phase 4: V2 pools (from V1 live config) ===");
        for (uint256 i = 0; i < tokens.length; i++) {
            _setupPool(tokens[i]);
        }
    }

    function _setupPool(address t) internal {
        address ys = _strategyFor(t);
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
            address ys = _strategyFor(t);
            console.log("  -- migrating pool", t, IERC20Metadata(t).symbol());

            _initiatePool(ICutoverMigrator(address(migrator)), v1, t, ys);

            PoolPlan memory preview = _planPool(v1, t, ys);
            if (preview.migratable.length > 0) {
                // Pending phUSD is minted inside batchMigrate; a revoked V1 would brick every exit.
                require(_canMintPhUSD(STABLE_STAKER_V1), "Phase6: V1 phUSD mint revoked while stakers remain to migrate");
            }
            PoolPlan memory plan =
                _migratePool(ICutoverMigrator(address(migrator)), v1, t, ys, MIGRATE_CHUNK, _stragglerCap(t));

            _assertPoolPostMigration(v1, ICutoverStaker(address(v2)), t, ys, plan, _maxLossBps(ys), WEI_SLACK);
        }
    }

    // =====================================================================
    //  PHASE 7 - finalize
    // =====================================================================

    function _phase7_finalize() internal {
        console.log("\n=== Phase 7: finalize ===");
        ICutoverStaker v1 = ICutoverStaker(STABLE_STAKER_V1);

        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            address ys = _strategyFor(t);
            require(_doneV1PoolMigrating(t), "Phase7: a V1 pool is not Migrating");
            PoolPlan memory rest = _planPool(v1, t, ys);
            require(rest.migratable.length == 0, "Phase7: migratable V1 stakers remain - refusing to finalize");

            // The recipient is GLOBAL per strategy. Repointed AFTER migration: skimSurplus is the only
            // reader, the migration never skims, and V1 is drained. A pre-story-047 strategy (the live
            // USDe one) has no recipient and pays each client its own buffer, so V2 already receives it.
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
            address ys = _strategyFor(t);
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
                ICutoverStrategy(ys).principalOf(t, STABLE_STAKER_V1) == 0, "Phase8: V1 still books strategy principal"
            );
            (,,, uint256 v1Staked) = v1.poolInfo(t);
            require(v1Staked < _stragglerCap(t), "Phase8: V1 totalStaked is not sub-cap straggler dust");
            console.log("  pool OK (token / V2 stakers / V1 stragglers):", t, v2.stakerCount(t), v1.stakerCount(t));
        }

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
        address[] memory registrants = IPauserRegistry(PAUSER).getPausableContracts();
        require(registrants.length > 0, "Phase8: Pauser has no registrants");
        for (uint256 i = 0; i < registrants.length; i++) {
            address r = registrants[i];
            require(r != STABLE_STAKER_V1, "Phase8: V1 is listed by Pauser.getPausableContracts()");
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
        vm.prank(actor);
        v2.autoAnnihilate(t);
        uint256 phAfter = IERC20(PHUSD).balanceOf(actor);
        require(phAfter > phBefore, "smoke: autoAnnihilate paid no phUSD");
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

    // ---- Phase 4: per-token pool setup ----
    function _donePoolTokenAdded(address t) internal view returns (bool) {
        return _contains(v2.getStakedTokens(), t);
    }

    function _donePoolClientSet(address t) internal view returns (bool) {
        return IClientGetter(_strategyFor(t)).authorizedClients(address(v2));
    }

    function _donePoolStrategySet(address t) internal view returns (bool) {
        return address(v2.yieldStrategy(t)) == _strategyFor(t);
    }

    function _donePoolBufferCopied(address t) internal view returns (bool) {
        return ICutoverBuffer(_strategyFor(t)).setAsideBufferSize(address(v2)) == v1BufferPct[t];
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

    // =====================================================================
    //  Helpers
    // =====================================================================

    function _strategyFor(address t) internal pure returns (address) {
        if (t == DOLA) return YS_DOLA;
        if (t == USDC) return YS_USDC;
        if (t == USDE) return YS_USDE;
        revert("V1 stakes a token with no known strategy - STOP AND REPORT (update the strategy map deliberately)");
    }

    /// @dev Loss bound, bps part (Phase 6 adds the absolute WEI_SLACK = 1000 wei on top, story 083). Used per user
    ///      (pre -> credited) AND, since story 087, for the pool's exit-realization bound (pre -> credit, on V1's
    ///      immutable R / P), which is a sub-leg of the per-user total and so is bounded by the same allowance.
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
        if (vm.keyExistsJson(json, ".baselines.cutoverStartBlock")) {
            cutoverStartBlock = vm.parseUint(vm.parseJsonString(json, ".baselines.cutoverStartBlock"));
        }
        if (vm.keyExistsJson(json, ".baselines.phusdMinterMask")) {
            phusdMaskAtPhase0 = vm.parseUint(vm.parseJsonString(json, ".baselines.phusdMinterMask"));
            phusdMintVersionAtPhase0 = vm.parseUint(vm.parseJsonString(json, ".baselines.phusdMintVersion"));
            phusdBaselineRecorded = true;
        }
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
        string memory c;
        c = _serializeEntry("Antimatter", address(antimatter));
        c = _serializeEntry("StableStakerV2", address(v2));
        c = _serializeEntry("CrossVersionMigrator", address(migrator));

        // Story 086: write-once lower bound for the verifier's per-user event scan.
        if (cutoverStartBlock == 0) cutoverStartBlock = block.number;
        vm.serializeString("s082.baselines", "cutoverStartBlock", vm.toString(cutoverStartBlock));
        vm.serializeString("s082.baselines", "phusdMinterMask", vm.toString(phusdMaskAtPhase0));
        string memory b = vm.serializeString("s082.baselines", "phusdMintVersion", vm.toString(phusdMintVersionAtPhase0));

        vm.serializeUint("s082.root", "chainId", CHAIN_ID);
        vm.serializeString("s082.root", "networkName", NETWORK_NAME);
        vm.serializeString("s082.root", "deploymentStatus", status);
        vm.serializeString("s082.root", "baselines", b);
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
