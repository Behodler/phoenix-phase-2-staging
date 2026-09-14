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
 *   1  Pause V1 for the window (story 062 pattern: setPauser(OWNER) + pause()).
 *   2  Deploy Antimatter (name "Antimatter", symbol "AM" - hard-coded in its constructor), owner
 *      OWNER; setPhUSD then setPhUSDMinter; read back.
 *   3  Deploy StableStakerV2(antimatter, OWNER); setPauser(OWNER) + pause() BEFORE any addToken.
 *   4  Per V1 token: addToken, strategy.setClient(V2), idle-balance guard, setYieldStrategy,
 *      setSetAsideBuffer(V2, <V1's>), antimatterPerDay(C * 21 / 10), autoAnnihilateAvailable.
 *   5  Mint rights: Antimatter.setApprovedMinter(V2), phUSD.setMinter(V2), phUSD.setMinter(Antimatter)
 *      (see the Phase 5 NatSpec for why the third grant exists), two-sided minter delta.
 *   6  CrossVersionMigrator; setMigrator on both; per token: relinquish surplus, initiate, plan
 *      (dust predicate), batch-migrate non-dust, allow-list stragglers under a cap, post-conditions.
 *   7  Finalize: repoint set-aside buffer recipient, revoke V1 phUSD mint, V1 retired (pauser -> OWNER,
 *      Pauser.unregister(V1), V1 left PAUSED - story 083), V2 + Antimatter pauser -> Pauser and
 *      registered, V2 unpaused.
 *   8  Wiring assertions (both modes).
 *   -  PREVIEW_MODE only: smoke tests (Antimatter mint-revocation proof, V2 stake/withdraw on every
 *      pool, autoAnnihilate on DOLA). Prank-only, never broadcast.
 *
 * ================================ RUNNING IT ==============================================
 *   npm run stable-staker-v2-cutover:preview     (impersonates OWNER on live mainnet state)
 *   npm run stable-staker-v2-cutover:broadcast   (Ledger m/44'/60'/46'/0/0; chains to :preview)
 *
 *   PREVIEW DOUBLES AS POST-BROADCAST VERIFICATION. Preview READS the progress file when one exists
 *   (never writes it). After a completed broadcast every phase below detects - from ON-CHAIN state,
 *   with the progress file supplying only the three deployed addresses - that it is already done and
 *   skips, so Phase 8 and the smoke tests then run against the live deployment.
 *
 *   The progress file is written during forge's LOCAL execution pass, before any transaction is
 *   sent. After a crashed broadcast it can therefore name a contract that never landed. Every
 *   address loaded from it is required to have code; one that does not aborts with an instruction
 *   to trim the file to the on-chain-confirmed deployments (run-latest.json receipts + `cast nonce`).
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
    /// @dev Per-user absolute rounding slack, additive to the bps bound (`_maxLossBps`). Story 083 raised it
    ///      from 080's 2-wei floor to 1000 wei: simulated round trips (V1 exit + V2 re-deposit) lost more
    ///      than 2 wei per user and tripped the Phase 6 post-migration assert. 1000 wei is at most $0.001
    ///      per user even on a 6-decimal token (USDC), so the looser bound is economically negligible.
    uint256 public constant WEI_SLACK = 1000;
    /// @dev Per-user loss bound on the 1:1 ERC4626 strategies. The story planned 0 bps, but the live
    ///      autoDOLA autopool is NOT loss-free on either leg: the planning preview (block ~25975061)
    ///      measured, per leg, autoDOLA: exit R/P = 1 - 1.70e-6, re-deposit x * (1 - 1.73e-6)
    ///      (~0.034 bps round trip); autoUSDC: exit R/P = 1 - 4.32e-5, re-deposit ~ 1 - 4.3e-5
    ///      (~0.86 bps round trip). 2 bps is ~2.3x the worst observation: loose enough not to trip on
    ///      the autopools' own valuation spread, tight enough that a real vault loss still stops the
    ///      run. Recorded in story 082's Autonomous Decisions.
    uint256 public constant ERC4626_MAX_LOSS_BPS = 2;

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

    function run() external {
        console.log("=================================================");
        console.log("  MAINNET STABLESTAKER V1 -> V2 CUTOVER (story 082)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        require(RATE_NUMERATOR == 21 && RATE_DENOMINATOR == 10, "rate multiplier must be 2.1x (user decision)");
        require(MIGRATE_CHUNK > 0 && MIGRATE_CHUNK <= 50, "MIGRATE_CHUNK out of range (1..50)");
        require(STRAGGLER_CAP_CENTS > 0 && STRAGGLER_CAP_CENTS <= 1, "straggler cap must be (0, 1 cent]");

        isPreview = vm.envOr("PREVIEW_MODE", false);
        _loadProgressFile();

        _phase0_preconditions();

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating OWNER, nothing signed, nothing broadcast ***");
            console.log("*** Progress file is READ if present, NEVER written ***");
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }

        _phase1_pauseV1();
        _phase2_antimatter();
        _phase3_stakerV2();
        _phase4_pools();
        _phase5_mintRights();
        _phase6_migration();
        _phase7_finalize();

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
            _previewSmokeTests();
        }
        _printSummary();
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
    ///      not obstruct the cutover. Phase 7 retires V1: its pauser stays OWNER, it is unregistered from
    ///      the Pauser and it is LEFT PAUSED (story 083). On a resumed or verification leg V1 is therefore
    ///      already paused (or the cutover is finalized, V2 pauser == Pauser) and this phase skips.
    function _phase1_pauseV1() internal {
        console.log("\n=== Phase 1: pause V1 ===");
        if (address(v2) != address(0) && v2.pauser() == PAUSER) {
            console.log("  cutover already finalized (V2 pauser == Pauser) - V1 pause window skipped");
            return;
        }
        if (IPausableLike(STABLE_STAKER_V1).paused()) {
            console.log("  V1 already paused - skipped");
            return;
        }
        if (IPausableLike(STABLE_STAKER_V1).pauser() != OWNER) {
            IPausableLike(STABLE_STAKER_V1).setPauser(OWNER);
        }
        IPausableLike(STABLE_STAKER_V1).pause();
        require(IPausableLike(STABLE_STAKER_V1).paused(), "Phase1: V1 did not pause");
        console.log("  V1 paused (pauser OWNER; V1 stays paused and is unregistered in Phase 7)");
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
        require(keccak256(bytes(antimatter.name())) == keccak256("Antimatter"), "Phase2: Antimatter name");
        require(keccak256(bytes(antimatter.symbol())) == keccak256("AM"), "Phase2: Antimatter symbol");
        require(antimatter.owner() == OWNER, "Phase2: Antimatter owner != OWNER");

        // ORDER IS LOAD-BEARING: setPhUSDMinter reverts PhUSDNotSet otherwise.
        if (address(antimatter.phUSD()) != PHUSD) {
            antimatter.setPhUSD(IFlaxAntimatter(PHUSD));
        }
        if (address(antimatter.phUSDMinter()) != PHUSD_STABLE_MINTER) {
            antimatter.setPhUSDMinter(PhusdStableMinter(PHUSD_STABLE_MINTER));
        }
        require(address(antimatter.phUSD()) == PHUSD, "Phase2: Antimatter.phUSD did not land");
        require(address(antimatter.phUSDMinter()) == PHUSD_STABLE_MINTER, "Phase2: Antimatter.phUSDMinter did not land");
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
        require(v2.owner() == OWNER, "Phase3: V2 owner != OWNER");

        if (v2.pauser() == PAUSER) {
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

        if (!_contains(v2.getStakedTokens(), t)) {
            v2.addToken(t);
        }
        if (!IClientGetter(ys).authorizedClients(address(v2))) {
            IYieldStrategy(ys).setClient(address(v2), true);
        }
        require(IClientGetter(ys).authorizedClients(address(v2)), "Phase4: strategy.setClient(V2) did not land");

        if (address(v2.yieldStrategy(t)) != ys) {
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
        require(address(v2.yieldStrategy(t)) == ys, "Phase4: V2 yieldStrategy did not land");

        uint256 buf = v1BufferPct[t];
        if (ICutoverBuffer(ys).setAsideBufferSize(address(v2)) != buf) {
            IYieldStrategy(ys).setSetAsideBuffer(address(v2), buf);
        }
        require(ICutoverBuffer(ys).setAsideBufferSize(address(v2)) == buf, "Phase4: V2 set-aside buffer != V1's");

        uint256 c = cPerDay[t];
        require(c > 0, "Phase4: V1 phUSD rate for token is 0 - refusing a zero Antimatter emission");
        uint256 newPerDay = c * RATE_NUMERATOR / RATE_DENOMINATOR;
        (uint256 perSecond,,,) = v2.poolInfo(t);
        if (perSecond != newPerDay / 86400) {
            v2.antimatterPerDay(t, newPerDay);
        }
        (perSecond,,,) = v2.poolInfo(t);
        require(perSecond == newPerDay / 86400, "Phase4: V2 antimatterPerSecond != (C * 21 / 10) / 86400");
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
        if (!antimatter.isApprovedMinter(address(v2))) {
            antimatter.setApprovedMinter(address(v2), true);
        }
        require(antimatter.isApprovedMinter(address(v2)), "Phase5: V2 is not an approved Antimatter minter");
        console.log("  Antimatter.setApprovedMinter(V2) - VERIFIED by read-back");

        if (!v2.phUSDMintAvailable()) {
            IPhUSDOwner(PHUSD).setMinter(address(v2), true);
        }
        require(v2.phUSDMintAvailable(), "Phase5: V2 cannot mint phUSD (autoAnnihilate shortfall cover dead)");
        console.log("  phUSD.setMinter(V2) - VERIFIED via phUSDMintAvailable()");

        if (GRANT_ANTIMATTER_PHUSD_MINT) {
            if (!_canMintPhUSD(address(antimatter))) {
                IPhUSDOwner(PHUSD).setMinter(address(antimatter), true);
            }
            require(_canMintPhUSD(address(antimatter)), "Phase5: Antimatter cannot mint phUSD (annihilate dead)");
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
        require(address(migrator.oldStaker()) == STABLE_STAKER_V1, "Phase6: migrator.oldStaker != V1");
        require(address(migrator.newStaker()) == address(v2), "Phase6: migrator.newStaker != V2");
        require(migrator.owner() == OWNER, "Phase6: migrator owner != OWNER");

        if (IMigratorRole(STABLE_STAKER_V1).migrator() != address(migrator)) {
            IMigratorRole(STABLE_STAKER_V1).setMigrator(address(migrator));
        }
        if (v2.migrator() != address(migrator)) {
            v2.setMigrator(address(migrator));
        }
        require(IMigratorRole(STABLE_STAKER_V1).migrator() == address(migrator), "Phase6: V1 migrator not wired");
        require(v2.migrator() == address(migrator), "Phase6: V2 migrator not wired");
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
            require(v1.poolState(t) == POOL_MIGRATING, "Phase7: a V1 pool is not Migrating");
            PoolPlan memory rest = _planPool(v1, t, ys);
            require(rest.migratable.length == 0, "Phase7: migratable V1 stakers remain - refusing to finalize");

            // The recipient is GLOBAL per strategy. Repointed AFTER migration: skimSurplus is the only
            // reader, the migration never skims, and V1 is drained. A pre-story-047 strategy (the live
            // USDe one) has no recipient and pays each client its own buffer, so V2 already receives it.
            (bool hasRecipient, address recipient) = _bufferRecipient(ys);
            if (hasRecipient && recipient != address(v2)) {
                IYieldStrategy(ys).setSetAsideBufferRecipient(address(v2));
                (, recipient) = _bufferRecipient(ys);
                require(recipient == address(v2), "Phase7: setAsideBufferRecipient not repointed to V2");
                console.log("  setAsideBufferRecipient -> V2 on strategy:", ys);
            }
        }

        // Revoke only after every non-straggler has migrated (asserted just above). A straggler's own
        // later `userMigrate` would need to mint its frozen pending phUSD and will revert while that
        // pending is non-zero: accepted, stragglers are sub-cent dust and protocol safety comes first.
        if (_canMintPhUSD(STABLE_STAKER_V1)) {
            IPhUSDOwner(PHUSD).setMinter(STABLE_STAKER_V1, false);
            console.log("  phUSD.setMinter(V1, false) - retired staker's mint authority REVOKED");
        } else {
            console.log("  V1 phUSD mint already revoked - skipped");
        }
        require(!_canMintPhUSD(STABLE_STAKER_V1), "Phase7: V1 phUSD mint not revoked");

        // V1 is retired (story 083, superseding 082's Decision 9 which handed V1's pauser back to the
        // Pauser and unpaused it). V1's pauser moves to OWNER, V1 is UNREGISTERED from the Pauser, and
        // V1 is left PAUSED. Decision 9 unpaused V1 because `Pauser.pause()` loops `pause()` over every
        // registered contract with no try/catch and OZ `_pause` reverts on an already-paused contract;
        // once V1 is no longer registered that brick risk is gone, so V1 stays paused. Stragglers keep
        // `userMigrate`, which is not pause-gated.
        // ORDER IS FORCED: `Pauser.unregister` reverts while V1.pauser() == PAUSER, so setPauser first.
        // `unregister` is onlyOwner (Phase 0 asserts Pauser owner == OWNER). Every step is gated on
        // on-chain state so a resumed run converges. Must run BEFORE V2's pauser hand-back (the
        // finalized marker).
        if (IPausableLike(STABLE_STAKER_V1).pauser() != OWNER) {
            IPausableLike(STABLE_STAKER_V1).setPauser(OWNER);
        }
        require(IPausableLike(STABLE_STAKER_V1).pauser() == OWNER, "Phase7: V1 pauser not moved to OWNER");
        if (IPauserRegistry(PAUSER).isRegistered(STABLE_STAKER_V1)) {
            IPauserRegistry(PAUSER).unregister(STABLE_STAKER_V1);
            console.log("  Pauser.unregister(V1) - retired staker removed from the global pause registry");
        } else {
            console.log("  V1 already unregistered from Pauser - skipped");
        }
        require(!IPauserRegistry(PAUSER).isRegistered(STABLE_STAKER_V1), "Phase7: V1 still registered with Pauser");
        if (!IPausableLike(STABLE_STAKER_V1).paused()) {
            IPausableLike(STABLE_STAKER_V1).pause();
        }
        require(IPausableLike(STABLE_STAKER_V1).paused(), "Phase7: V1 not paused");

        if (v2.pauser() != PAUSER) v2.setPauser(PAUSER);
        if (!IPauserRegistry(PAUSER).isRegistered(address(v2))) IPauserRegistry(PAUSER).register(address(v2));
        if (antimatter.pauser() != PAUSER) antimatter.setPauser(PAUSER);
        if (!IPauserRegistry(PAUSER).isRegistered(address(antimatter))) {
            IPauserRegistry(PAUSER).register(address(antimatter));
        }
        // unpause is owner-or-pauser, so it works after the pauser hand-back.
        if (v2.paused()) v2.unpause();
        require(!v2.paused(), "Phase7: V2 still paused");
        require(!v2.claimEnabled(), "Phase7: claimEnabled must stay false");
        console.log("  V1 pauser -> OWNER, unregistered from Pauser, left paused; V2 + Antimatter registered with Pauser; V2 unpaused");
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
        console.log("  all wiring assertions passed");
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
    //  Helpers
    // =====================================================================

    function _strategyFor(address t) internal pure returns (address) {
        if (t == DOLA) return YS_DOLA;
        if (t == USDC) return YS_USDC;
        if (t == USDE) return YS_USDE;
        revert("V1 stakes a token with no known strategy - STOP AND REPORT (update the strategy map deliberately)");
    }

    /// @dev Per-user loss bound (bps part; Phase 6 adds the absolute WEI_SLACK = 1000 wei on top, story 083).
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
}
