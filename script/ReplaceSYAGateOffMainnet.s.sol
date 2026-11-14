// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {Vm} from "@forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {ICurveRouterNG} from "sya-harvester/interfaces/ICurveRouterNG.sol";
import {
    SyaGateOffMainnetBase,
    IOldSYA,
    ISyaStrategyAdmin,
    INFTMinterV2SyaGateOff,
    IPauserV2SyaGateOff
} from "./helpers/SyaGateOffMainnetBase.sol";

/// @dev NudgeStreamer stream lookup (same shape the 029 SYA's setRewardToken guard reads).
interface INudgeStreamerStreamsView {
    function streams(address batchMinter, address token)
        external
        view
        returns (uint256 duration, uint256 a, uint256 b, uint256 c);
}

/// @dev Curve pool coin views for the harvester route preflight.
interface ICurvePoolCoins {
    function coins(uint256 i) external view returns (address);
}

/**
 * @title ReplaceSYAGateOffMainnet  (story 131, sprint nft-bonfire)
 * @notice Replaces the live mainnet StableYieldAccumulator `0x0cD3...21B6` (not upgradeable, NFT claim gate
 *         hard-coded) with a gate-free SYA built from the 130 pin (yield-accumulator:029 `105f22b`, which includes
 *         028's optional gate and 029's fail-closed `TokenConfig.configured`), retires the old SYA, and redeploys
 *         SYAHarvester (its `sya` is immutable). Steps, each state-gated and read back with a `require`:
 *           1. PREFLIGHT. Wiring + strategy list mirrored LIVE from the old SYA; old `owner() == OWNER`; token
 *              configs HARD-CODED (USDC 6 / DOLA 18 / USDe 18, rate 1e18), each checked against on-chain
 *              `decimals()`; token set check (exactly 3 strategies -> USDC, DOLA, USDe, one each) - all BEFORE any
 *              deploy or config call. The old SYA's `tokenConfigs` / `getTokenConfig` are never read.
 *           2. DEPLOY the new SYA, or adopt it from server/deployments/progress.sya-gate-off.1.json.
 *           COMPLETION GATE (story 134, audit pps56m1 / pps56l4). After completion, any re-run that would send a
 *              transaction refuses, naming the step; with nothing to change it sends nothing; a pending (interrupted)
 *              run resumes, guarded by the value check against later changes. Every write goes through the non-virtual
 *              `_send(step)`, which refuses when progress.sya-gate-off.1.json is `completed` and the SYA was adopted,
 *              before anything is sent, in PREVIEW and broadcast alike.
 *           VALUE CHECK (story 133, audit pps55m1), the pending-resume guard. On an ADOPTED SYA, step 3 first checks
 *              every value it would write; one that is already set and differs from its target (a later deliberate
 *              change landing before an interrupted run is resumed - story 119's nudge repoint, a discount retune)
 *              makes the run REVERT by name before step 3 sends anything. Default (unset) values are still filled in,
 *              so a resume works; a freshly deployed SYA is never refused. It cannot see a value reset to its default,
 *              nor steps 4-6; after completion the gate above covers those. Mirroring the old SYA does NOT carry a
 *              119 repoint: 119 repoints only the live SYA and leaves the old one on the paused old minter.
 *           3. CONFIGURE in the 029 order: setTokenConfig x3 (read back configured / decimals / rate) ->
 *              setRewardToken(USDC) (before the nudge setters, story-027 guard) -> setPhlimbo + approvePhlimbo(max)
 *              -> setNudgeAddress / setNudgeSplit / setNudgeStreamer -> addYieldStrategy x3 -> setDiscountRate(100)
 *              -> nftMinter asserted ZERO -> setPauser(PauserV2) -> PauserV2.register.
 *           4. STRATEGIES: setWithdrawer(newSYA, true) on all three (setAsideBuffer untouched).
 *           5. RETIRE the old SYA: PauserV2.unregister FIRST; setPauser(OWNER) (phStaging2 CLAUDE.md "Deregister
 *              Retired Contracts": pauser() != Pauser); strategies setWithdrawer(old, false) x3; removeYieldStrategy
 *              x3 over a snapshot (swap-and-pop); NFTMinterV2.setAuthorizedBurner(old, false); approvePhlimbo(0).
 *              NOT paused (its empty registry leaves nothing to claim). The V1 Pauser is never touched.
 *           6. HARVESTER: SYAHarvester(OWNER, PoolManager, newSYA, Router NG) with story 122's exact USDe and DOLA
 *              routes and ETH pool, after the same story-052 payload check and bidirectional fork dry run. A new
 *              progress entry: the old harvester `0xeE42...` is never adopted.
 *           7. POSTCONDITIONS: the full end state, re-read.
 *
 *         NO FUNDS TO THE LEDGER (human requirement 2026-11-06). OWNER `0xCad1...D0B6` only pays gas. OWNER's ETH,
 *         Antimatter, phUSD, USDC/DOLA/USDe/sUSDe/USDS/sUSDS, EYE and every NFTMinterV2 id balance are snapshot
 *         before the first call and asserted not to have risen after the last (`OwnerBalanceIncreased`), in preview
 *         too. OWNER is never a claimer, harvest caller or recipient.
 *
 *         PREVIEW ONLY (snapshot-reverted, never in a broadcast session): a non-NFT-holding EOA claims `claim(0)` on
 *         the new SYA and pays at the 1% discount; a non-OWNER caller harvests through the new harvester with
 *         `nftIndex 0` and no NFT moves; a residual claim on the old SYA reverts; a global PauserV2 pause
 *         round-trip includes the new SYA.
 *
 *         Progress: `pending` + each CREATE nonce, written in forge's local pass only under SYA_GATE_OFF_BROADCAST
 *         =true (the :broadcast key alone); scripts/confirm-sya-gate-off-progress.js flips it to `completed`. The
 *         address book and PauserV2Registry are patched AFTER the broadcast by
 *         scripts/patch-mainnet-addresses-sya-gate-off.js, never here.
 *
 * Preview:   npm run sya-gate-off:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written)
 * Broadcast: npm run sya-gate-off:broadcast   (the human only, Ledger m/44'/60'/46'/0/0)
 * Verify:    npm run sya-gate-off-verify      (read-only)
 * Runbook:   docs/runbooks/sya-gate-off-mainnet.md
 */
contract ReplaceSYAGateOffMainnet is SyaGateOffMainnetBase {
    /// @dev The old SYA's wiring, read live in preflight.
    struct Wiring {
        address rewardToken;
        address phlimbo;
        address nudge;
        uint256 nudgeSplit;
        address nudgeStreamer;
    }

    /// @dev Accrual window for the preview smokes. Kept SHORT on purpose: YieldStrategyUSDC values autoUSD through a
    ///      Tokemak root price oracle with a Chainlink staleness check, so a multi-day warp makes every claim revert
    ///      on a stale feed (custom error 0x8d54ba1f) - a fork artefact, not a cutover fault.
    uint256 internal constant SMOKE_WARP = 1 hours;

    StableYieldAccumulator public newSya;
    SYAHarvester public harvester;
    bool public deployedSyaThisRun;
    bool public deployedHarvesterThisRun;
    /// @dev Transactions this run sent (or, in preview, would send). Read by the fork tests.
    uint256 public txCount;

    Wiring public wiring;
    address[] internal strategies;
    address[] internal strategyTokenList;

    uint256 internal syaCreateNonce;
    uint256 internal harvesterCreateNonce;

    // Preview smoke results (read by the fork tests; recorded after each snapshot revert).
    uint256 public smokeClaimPaid;
    uint256 public smokeClaimYieldNormalized;
    uint256 public smokeHarvestEthOut;
    bytes public smokeOldClaimRevert;
    uint256 public smokePauseChecked;

    // Dry-run deltas (route safety; read by the fork tests).
    uint256 public dryUsdeToUsdc;
    uint256 public dryUsdcToUsde;
    uint256 public dryDolaToUsdc;
    uint256 public dryUsdcToDola;

    bool internal isPreview;

    function run() external {
        console.log("=================================================");
        console.log("  REPLACE SYA (gate OFF, 1%) + REDEPLOY SYAHarvester - MAINNET (story 131)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );
        if (!isPreview) require(_sender() == OWNER, "broadcast sender must be OWNER (--sender + Ledger)");

        // ---- 1. Preflight: nothing is deployed or configured before every check here has passed ----
        address recordedSya = _preflight();
        _routeSafety();
        _snapshotOwnerBalances();

        // ---- 2. Deploy, or adopt ----
        _deployOrAdoptSya(recordedSya);

        // ---- 3-5 ----
        _configureNewSya();
        _grantWithdrawers();
        _retireOldSya();

        // ---- 6 ----
        _deployOrAdoptHarvester();
        _configureHarvester();

        // ---- 7 ----
        _requireFinalState();

        if (isPreview) {
            _assertOwnerBalancesNotIncreased("after cutover (preview)");
            _smokeClaim();
            _smokeHarvest();
            _smokeOldSyaClaim();
            _globalPauseRoundTrip();
        }
        _assertOwnerBalancesNotIncreased("final");

        console.log("New SYA:       ", address(newSya));
        console.log("New harvester: ", address(harvester));
        console.log("Transactions sent (or simulated):", txCount);
        if (txCount == 0) console.log("Nothing to do: cutover complete, no transaction sent (idempotent).");
        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (preview CREATE addresses are fork-local)."
            );
        } else {
            console.log("Next (chained by :broadcast): confirm progress, patch book + PauserV2Registry, verify.");
        }
    }

    // ============================================================
    // 1. Preflight
    // ============================================================

    /// @return recorded The new SYA from the progress file (address(0) on a first run).
    function _preflight() internal returns (address recorded) {
        _requireBookMatchesConstants();
        IOldSYA old = IOldSYA(OLD_SYA);
        require(OLD_SYA.code.length > 0 && PAUSER_V2.code.length > 0 && NFT_MINTER.code.length > 0, "no code");
        require(old.owner() == OWNER, "preflight: old SYA owner() != OWNER");
        require(IPauserV2SyaGateOff(PAUSER_V2).owner() == OWNER, "preflight: PauserV2 owner() != OWNER");
        require(INFTMinterV2SyaGateOff(NFT_MINTER).owner() == OWNER, "preflight: NFTMinterV2 owner() != OWNER");

        // Book state: the SYA key is the old SYA (pre-patch) or the recorded new SYA (post-patch), nothing else.
        recorded = _progressSya();
        require(recorded != OLD_SYA, "progress file names the OLD SYA as the new one - investigate");
        address booked = _bookSya();
        if (recorded == address(0)) {
            require(
                booked == OLD_SYA,
                "address book StableYieldAccumulator is not the old SYA but there is no progress file - restore progress.sya-gate-off.1.json"
            );
        } else {
            require(
                booked == OLD_SYA || booked == recorded,
                "address book StableYieldAccumulator != old SYA or progress SYA"
            );
        }
        address bookedHarvester = _bookHarvester();
        address recordedHarvester = _progressHarvester();
        require(recordedHarvester != OLD_HARVESTER, "progress file names the OLD harvester as the new one");
        require(
            bookedHarvester == OLD_HARVESTER
                || (recordedHarvester != address(0) && bookedHarvester == recordedHarvester),
            "address book SYAHarvester != old harvester or progress harvester"
        );

        // Hard-coded token configs: on-chain decimals must equal the constants.
        _requireOnChainDecimals();
        console.log("Preflight: on-chain decimals() == constants (USDC 6, DOLA 18, USDe 18); rate 1e18 each");

        // Wiring, mirrored LIVE from the OLD SYA. Zero/default guards on every value. 119 never repoints the old SYA
        // (119 Decision 5): after 119 these are NOT the live SYA's values, and the step-3 re-run guard refuses rather
        // than write them over 119's (story 133, audit pps55m1).
        Wiring memory w = Wiring({
            rewardToken: old.rewardToken(),
            phlimbo: old.phlimbo(),
            nudge: old.nudge(),
            nudgeSplit: old.nudgeSplit(),
            nudgeStreamer: old.nudgeStreamer()
        });
        require(w.rewardToken == USDC, "preflight: old SYA rewardToken != USDC (the hard-coded reward token)");
        require(w.phlimbo != address(0) && w.phlimbo.code.length > 0, "preflight: old SYA phlimbo zero / no code");
        require(
            w.phlimbo == _requireBook(vm.readFile(ADDRESS_BOOK), "PhlimboV3"),
            "preflight: old SYA phlimbo != book PhlimboV3"
        );
        require(
            w.nudgeStreamer != address(0) && w.nudgeStreamer.code.length > 0, "preflight: nudgeStreamer zero / no code"
        );
        require(w.nudgeSplit <= 100, "preflight: nudgeSplit > 100");
        if (w.nudgeSplit > 0) {
            require(
                w.nudge != address(0) && w.nudge.code.length > 0, "preflight: nudgeSplit > 0 but nudge zero / no code"
            );
            (uint256 duration,,,) = INudgeStreamerStreamsView(w.nudgeStreamer).streams(w.nudge, USDC);
            require(duration > 0, "preflight: NudgeStreamer has no (nudge, USDC) stream - new SYA claims would revert");
        }
        wiring = w;
        console.log("Mirrored wiring: rewardToken USDC, phlimbo", w.phlimbo);
        console.log("  nudge", w.nudge, " nudgeSplit", w.nudgeSplit);
        console.log("  nudgeStreamer", w.nudgeStreamer);

        // Strategy list, mirrored LIVE. On a re-run after retirement the old list is (partly) stripped, so the
        // adopted new SYA's full registry is the reference and every remaining old entry must be in it.
        _resolveStrategies(recorded);
        _requireStrategyTokenSet(strategies, strategyTokenList);
        for (uint256 i = 0; i < strategies.length; i++) {
            ISyaStrategyAdmin s = ISyaStrategyAdmin(strategies[i]);
            require(s.owner() == OWNER, "preflight: strategy owner() != OWNER");
        }
        console.log("Token set check OK: 3 strategies -> USDC, DOLA, USDe (one each), each == its book key");
    }

    function _resolveStrategies(address recorded) internal {
        delete strategies;
        delete strategyTokenList;
        IOldSYA old = IOldSYA(OLD_SYA);
        address[] memory oldList = old.getYieldStrategies();
        if (recorded != address(0) && recorded.code.length > 0) {
            address[] memory newList = IStableYieldAccumulator(recorded).getYieldStrategies();
            if (newList.length == 3) {
                for (uint256 i = 0; i < 3; i++) {
                    strategies.push(newList[i]);
                    strategyTokenList.push(IStableYieldAccumulator(recorded).strategyTokens(newList[i]));
                }
                for (uint256 i = 0; i < oldList.length; i++) {
                    require(_contains(newList, oldList[i]), "preflight: old SYA lists a strategy the new SYA lacks");
                }
                console.log(
                    "Strategy list: taken from the adopted new SYA (old SYA entries remaining:", oldList.length, ")"
                );
                return;
            }
        }
        for (uint256 i = 0; i < oldList.length; i++) {
            strategies.push(oldList[i]);
            strategyTokenList.push(old.strategyTokens(oldList[i]));
        }
        console.log("Strategy list: mirrored live from the old SYA, entries:", oldList.length);
    }

    function _contains(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == a) return true;
        }
        return false;
    }

    // ============================================================
    // Route safety (story 122 / CLAUDE.md ryv18m5): BEFORE any broadcast, in both modes
    // ============================================================

    function _routeSafety() internal {
        Config memory c = _harvesterConfig(OLD_SYA); // routes do not depend on the SYA
        _harvesterPreflight(c);
        Route memory u = usdeRoute(c);
        Route memory d = dolaRoute(c);
        console.log("\n=== Route safety 1/2: off-chain story-052 payload check ===");
        require(checkRoutePayload(u, c.usde, c.usdc) == 2, "route check: USDe route must execute 2 hops");
        require(checkRoutePayload(d, c.dola, c.usdc) == 1, "route check: DOLA route must execute 1 hop");
        checkRoutePayload(reverseRoute(u, c.usdc), c.usdc, c.usde);
        checkRoutePayload(reverseRoute(d, c.usdc), c.usdc, c.dola);
        console.log("  USDe route 2 hops, DOLA route 1 hop: contiguous, deliver USDC   OK");
        console.log("\n=== Route safety 2/2: bidirectional fork dry run (balance deltas, snapshot-reverted) ===");
        (dryUsdeToUsdc, dryUsdcToUsde) = _dryRunBothWays(u, c, CRVUSD);
        (dryDolaToUsdc, dryUsdcToDola) = _dryRunBothWays(d, c, address(0));
    }

    /// @dev Story 122's `_preflight` minus its `SYA.nftMinter() == book NFTMinter` check (the new SYA's gate is off)
    ///      and minus the SYA reads (done against the new SYA in `_requireFinalState`).
    function _harvesterPreflight(Config memory c) internal view {
        _code(c.usdc, "USDC");
        _code(c.dola, "DOLA");
        _code(c.usde, "USDe");
        _code(CURVE_ROUTER_NG, "Curve Router NG");
        _code(POOL_MANAGER, "Uniswap V4 PoolManager");
        _code(CRVUSD, "crvUSD");
        require(ICurvePoolCoins(POOL_USDE_CRVUSD).coins(0) == c.usde, "preflight: USDe/crvUSD coins(0) != USDe");
        require(ICurvePoolCoins(POOL_USDE_CRVUSD).coins(1) == CRVUSD, "preflight: USDe/crvUSD coins(1) != crvUSD");
        require(ICurvePoolCoins(POOL_CRVUSD_USDC).coins(0) == c.usdc, "preflight: crvUSD/USDC coins(0) != USDC");
        require(ICurvePoolCoins(POOL_CRVUSD_USDC).coins(1) == CRVUSD, "preflight: crvUSD/USDC coins(1) != crvUSD");
        require(ICurvePoolCoins(POOL_DOLA_FRAXBP).coins(0) == c.dola, "preflight: DOLA/FRAXBP coins(0) != DOLA");
        require(ICurvePoolCoins(POOL_FRAXBP).coins(1) == c.usdc, "preflight: FRAXBP coins(1) != USDC");
    }

    /// @dev Copied from DeploySyaHarvesterMainnet (story 122): tokenIn -> USDC, then USDC -> tokenIn on the reverse
    ///      route, measured by balance deltas inside one snapshot bracket.
    function _dryRunBothWays(Route memory r, Config memory c, address intermediate)
        internal
        returns (uint256 usdcOut, uint256 tokenBack)
    {
        uint256 snap = vm.snapshotState();
        address tokenIn = r.token;
        address fwd = address(uint160(uint256(keccak256(abi.encode("story131.dryrun.fwd", tokenIn)))));
        usdcOut = _exchange(r, tokenIn, c.usdc, DRY_RUN_UNITS * 1e18, fwd, intermediate);
        console.log(string.concat("  1000 ", _tokenName(tokenIn), " -> USDC: USDC balance delta"), usdcOut);
        require(
            usdcOut >= DRY_RUN_UNITS * 1e6 * DRY_RUN_MIN_BPS / 10_000,
            "dry run: forward USDC balance delta below the floor - route delivers the wrong token or misprices"
        );
        Route memory rev = reverseRoute(r, c.usdc);
        address bwd = address(uint160(uint256(keccak256(abi.encode("story131.dryrun.bwd", tokenIn)))));
        tokenBack = _exchange(rev, c.usdc, tokenIn, DRY_RUN_UNITS * 1e6, bwd, intermediate);
        console.log(string.concat("  1000 USDC -> ", _tokenName(tokenIn), ": tokenIn balance delta"), tokenBack);
        require(
            tokenBack >= DRY_RUN_UNITS * 1e18 * DRY_RUN_MIN_BPS / 10_000,
            "dry run: reverse tokenIn balance delta below the floor - pool indices wrong in the reverse direction"
        );
        vm.revertToState(snap);
    }

    function _exchange(
        Route memory r,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address who,
        address intermediate
    ) internal returns (uint256 delta) {
        deal(tokenIn, who, amountIn);
        uint256 outBefore = IERC20(tokenOut).balanceOf(who);
        uint256 midBefore = intermediate == address(0) ? 0 : IERC20(intermediate).balanceOf(who);
        vm.startPrank(who);
        IERC20(tokenIn).approve(CURVE_ROUTER_NG, amountIn);
        ICurveRouterNG(CURVE_ROUTER_NG).exchange(r.path, r.swapParams, amountIn, 1, r.pools, who);
        vm.stopPrank();
        require(IERC20(tokenIn).balanceOf(who) == 0, "dry run: router did not pull exactly amountIn");
        if (intermediate != address(0)) {
            require(
                IERC20(intermediate).balanceOf(who) == midBefore,
                "dry run: receiver got the INTERMEDIATE token - gapped-route failure (audit ryv18m5)"
            );
        }
        delta = IERC20(tokenOut).balanceOf(who) - outBefore;
    }

    // ============================================================
    // 2. Deploy or adopt the new SYA
    // ============================================================

    function _deployOrAdoptSya(address recorded) internal {
        if (recorded != address(0)) {
            _requireRecordedLanded(recorded, "StableYieldAccumulator");
            newSya = StableYieldAccumulator(recorded);
            (, syaCreateNonce) = _progressNonce("StableYieldAccumulator");
            require(newSya.owner() == OWNER, "adopted SYA owner() != OWNER");
            console.log("2. new SYA adopted from progress file:", recorded);
            return;
        }
        syaCreateNonce = vm.getNonce(OWNER);
        _send("2 new StableYieldAccumulator");
        newSya = new StableYieldAccumulator();
        _end();
        deployedSyaThisRun = true;
        require(newSya.owner() == OWNER, "fresh SYA owner() != OWNER");
        require(newSya.nftMinter() == address(0), "fresh SYA must deploy with the gate OFF");
        require(newSya.pauser() == address(0), "fresh SYA must deploy with no pauser");
        console.log("2. new SYA deployed:", address(newSya));
        if (!isPreview) _writePendingProgress();
    }

    // ============================================================
    // 3. Configure the new SYA (yield-accumulator:029 order)
    // ============================================================

    function _configureNewSya() internal {
        StableYieldAccumulator s = newSya;
        address[3] memory t = _targetTokens();

        // Re-run guard (story 133, audit pps55m1): on an ADOPTED SYA, refuse - before any transaction of this step is
        // sent - to overwrite a value that is already set and differs from its target.
        _refuseRollbacksOnAdoptedSya();

        // 3.1 setTokenConfig x3 FIRST, from the hard-coded constants (029: setRewardToken / addYieldStrategy revert
        //     TokenNotConfigured otherwise). Each read back: configured, decimals == constant, rate == 1e18.
        for (uint256 i = 0; i < 3; i++) {
            uint8 dec = _expectedDecimals(t[i]);
            if (!_tokenConfigured(t[i])) {
                _send(string.concat("3.1 setTokenConfig(", _tokenName(t[i]), ")"));
                s.setTokenConfig(t[i], dec, RATE_1_TO_1);
                _end();
                console.log(string.concat("3.1 setTokenConfig(", _tokenName(t[i]), ", decimals, 1e18)"), dec);
            } else {
                console.log(string.concat("3.1 ", _tokenName(t[i]), " already configured - skipped"));
            }
            require(_tokenConfigured(t[i]), string.concat("3.1: token config read-back failed for ", _tokenName(t[i])));
        }

        // 3.2 setRewardToken(USDC), still BEFORE the nudge setters (story-027 guard; while the nudge rail is unset
        //     the stream check does not fire).
        if (s.rewardToken() != USDC) {
            _send("3.2 setRewardToken");
            s.setRewardToken(USDC);
            _end();
            console.log("3.2 setRewardToken(USDC)");
        } else {
            console.log("3.2 rewardToken already USDC - skipped");
        }
        require(s.rewardToken() == USDC, "3.2: rewardToken != USDC");

        // 3.3 setPhlimbo + approvePhlimbo(max). PhlimboV3.collectReward pulls from the SYA.
        if (s.phlimbo() != wiring.phlimbo) {
            _send("3.3 setPhlimbo");
            s.setPhlimbo(wiring.phlimbo);
            _end();
            console.log("3.3 setPhlimbo", wiring.phlimbo);
        } else {
            console.log("3.3 phlimbo already set - skipped");
        }
        require(s.phlimbo() == wiring.phlimbo, "3.3: phlimbo != mirrored phlimbo");
        if (IERC20(USDC).allowance(address(s), wiring.phlimbo) < type(uint128).max) {
            _send("3.3 approvePhlimbo");
            s.approvePhlimbo(type(uint256).max);
            _end();
            console.log("3.3 approvePhlimbo(max)");
        } else {
            console.log("3.3 phlimbo allowance already ~max - skipped");
        }
        require(
            IERC20(USDC).allowance(address(s), wiring.phlimbo) >= type(uint128).max, "3.3: phlimbo allowance not max"
        );

        // 3.4 nudge rail, mirrored.
        if (s.nudge() != wiring.nudge) {
            _send("3.4 setNudgeAddress");
            s.setNudgeAddress(wiring.nudge);
            _end();
            console.log("3.4 setNudgeAddress", wiring.nudge);
        }
        require(s.nudge() == wiring.nudge, "3.4: nudge != mirrored nudge");
        if (s.nudgeSplit() != wiring.nudgeSplit) {
            _send("3.4 setNudgeSplit");
            s.setNudgeSplit(wiring.nudgeSplit);
            _end();
            console.log("3.4 setNudgeSplit", wiring.nudgeSplit);
        }
        require(s.nudgeSplit() == wiring.nudgeSplit, "3.4: nudgeSplit != mirrored nudgeSplit");
        if (s.nudgeStreamer() != wiring.nudgeStreamer) {
            _send("3.4 setNudgeStreamer");
            s.setNudgeStreamer(wiring.nudgeStreamer);
            _end();
            console.log("3.4 setNudgeStreamer", wiring.nudgeStreamer);
        }
        require(s.nudgeStreamer() == wiring.nudgeStreamer, "3.4: nudgeStreamer != mirrored nudgeStreamer");

        // 3.5 addYieldStrategy x3 from the live-mirrored list that passed the token set check.
        for (uint256 i = 0; i < strategies.length; i++) {
            if (!s.isRegisteredStrategy(strategies[i])) {
                _send(string.concat("3.5 addYieldStrategy(", _tokenName(strategyTokenList[i]), ")"));
                s.addYieldStrategy(strategies[i], strategyTokenList[i]);
                _end();
                console.log(
                    string.concat("3.5 addYieldStrategy(", _tokenName(strategyTokenList[i]), ")"), strategies[i]
                );
            }
            require(s.isRegisteredStrategy(strategies[i]), "3.5: strategy not registered");
            require(s.strategyTokens(strategies[i]) == strategyTokenList[i], "3.5: strategy token mismatch");
        }
        require(s.getYieldStrategies().length == 3, "3.5: new SYA must hold exactly 3 strategies");

        // 3.6 discount 100 bps - human decision 2026-11-06.
        if (s.getDiscountRate() != NEW_DISCOUNT_BPS) {
            _send("3.6 setDiscountRate");
            s.setDiscountRate(NEW_DISCOUNT_BPS);
            _end();
            console.log("3.6 setDiscountRate(100) - 1%, human decision 2026-11-06");
        }
        require(s.getDiscountRate() == NEW_DISCOUNT_BPS, "3.6: discount != 100 bps");

        // nftMinter stays ZERO: the gate is OFF (yield-accumulator:028). Never set here.
        require(s.nftMinter() == address(0), "3.6: nftMinter must be ZERO (claim gate off)");

        // 3.7 Pauser BEFORE register (PauserV2.register requires pauser() == PauserV2).
        if (s.pauser() != PAUSER_V2) {
            _send("3.7 setPauser");
            s.setPauser(PAUSER_V2);
            _end();
            console.log("3.7 setPauser(PauserV2)");
        }
        require(s.pauser() == PAUSER_V2, "3.7: pauser != PauserV2");
        if (!IPauserV2SyaGateOff(PAUSER_V2).isRegistered(address(s))) {
            _send("3.7 PauserV2.register");
            IPauserV2SyaGateOff(PAUSER_V2).register(address(s));
            _end();
            console.log("3.7 PauserV2.register(newSYA)");
        }
        require(IPauserV2SyaGateOff(PAUSER_V2).isRegistered(address(s)), "3.7: new SYA not registered with PauserV2");
    }

    // ============================================================
    // 3.0 Value check (story 133, audit pps55m1) - the PENDING-RESUME guard
    // ============================================================

    string internal constant REFUSE_POINTER =
        "value check: a re-run must not roll back a later change (pps55m1). See runbook docs/runbooks/sya-gate-off-mainnet.md";

    /// @notice Every value step 3 would write is checked here, in one pass, BEFORE the first step-3 transaction.
    /// @dev Scope (story 134): this is the guard for an INTERRUPTED (`pending`) run that is resumed after a later
    ///      change landed - there it is the only protection. It still runs on every adopted re-run, before step 3's
    ///      first write; on a `completed` run it is redundant with the completion gate in `_send` (either refuses,
    ///      naming the step, before anything is sent), and the gate also covers what this check cannot see. Steps 3.1-3.4, 3.6 and 3.7 write either a value mirrored LIVE from
    ///      the retired SYA or a hard-coded constant. On an ADOPTED SYA a value that is still at its default is one
    ///      this script has not written yet, and is filled in as before (resume keeps working). A value that is SET and
    ///      differs from the target was written by someone else after this script - story 119's nudge repoint, or a
    ///      manual retune - and writing the target over it would be a silent rollback. So the run refuses, naming the
    ///      step, the live value and the target. A freshly deployed SYA is never refused (every value starts at its
    ///      default). PREVIEW and broadcast take this path identically; nothing is sent first.
    ///      Not covered by THIS check (undetectable by value): a value deliberately reset to its default, 3.3
    ///      approvePhlimbo (an allowance top-up, which can undo an `approvePhlimbo(0)`), step 4's withdrawer grants
    ///      and step 6's harvester routes and ETH pool. On a pending resume those are written as before; after
    ///      completion the gate refuses them.
    function _refuseRollbacksOnAdoptedSya() internal view {
        if (deployedSyaThisRun) return;
        StableYieldAccumulator s = newSya;

        // 3.1 token configs: configured but not the hard-coded (decimals, rate 1e18).
        address[3] memory t = _targetTokens();
        for (uint256 i = 0; i < 3; i++) {
            IStableYieldAccumulator.TokenConfig memory cfg = IStableYieldAccumulator(address(s)).getTokenConfig(t[i]);
            uint8 dec = _expectedDecimals(t[i]);
            if (cfg.configured && (cfg.decimals != dec || cfg.normalizedExchangeRate != RATE_1_TO_1)) {
                _refuse(
                    string.concat("3.1 setTokenConfig(", _tokenName(t[i]), ")"),
                    string.concat(
                        "decimals ",
                        vm.toString(uint256(cfg.decimals)),
                        " rate ",
                        vm.toString(cfg.normalizedExchangeRate)
                    ),
                    string.concat("decimals ", vm.toString(uint256(dec)), " rate ", vm.toString(RATE_1_TO_1))
                );
            }
        }
        _refuseOverwrite("3.2 setRewardToken", s.rewardToken(), USDC);
        _refuseOverwrite("3.3 setPhlimbo", s.phlimbo(), wiring.phlimbo);
        _refuseOverwrite("3.4 setNudgeAddress", s.nudge(), wiring.nudge);
        _refuseOverwrite("3.4 setNudgeSplit", s.nudgeSplit(), wiring.nudgeSplit);
        _refuseOverwrite("3.4 setNudgeStreamer", s.nudgeStreamer(), wiring.nudgeStreamer);
        _refuseOverwrite("3.6 setDiscountRate", s.getDiscountRate(), NEW_DISCOUNT_BPS);
        _refuseOverwrite("3.7 setPauser", s.pauser(), PAUSER_V2);
    }

    /// @dev Reverts when the adopted SYA's `live` value is set (non-zero) and differs from `target`.
    function _refuseOverwrite(string memory step, address live, address target) internal view {
        if (deployedSyaThisRun || live == address(0) || live == target) return;
        _refuse(step, vm.toString(live), vm.toString(target));
    }

    /// @dev uint overload of `_refuseOverwrite`.
    function _refuseOverwrite(string memory step, uint256 live, uint256 target) internal view {
        if (deployedSyaThisRun || live == 0 || live == target) return;
        _refuse(step, vm.toString(live), vm.toString(target));
    }

    function _refuse(string memory step, string memory live, string memory target) internal pure {
        revert(
            string.concat(
                "re-run guard: refusing step ",
                step,
                " on the adopted SYA: live ",
                live,
                " != target ",
                target,
                ". ",
                REFUSE_POINTER
            )
        );
    }

    function _tokenConfigured(address token) internal view returns (bool) {
        IStableYieldAccumulator.TokenConfig memory cfg = IStableYieldAccumulator(address(newSya)).getTokenConfig(token);
        return cfg.configured && cfg.decimals == _expectedDecimals(token) && cfg.normalizedExchangeRate == RATE_1_TO_1;
    }

    // ============================================================
    // 4. Strategies: withdrawer granted to the new SYA
    // ============================================================

    function _grantWithdrawers() internal {
        for (uint256 i = 0; i < strategies.length; i++) {
            ISyaStrategyAdmin st = ISyaStrategyAdmin(strategies[i]);
            if (!st.authorizedWithdrawers(address(newSya))) {
                _send("4 setWithdrawer(newSYA, true)");
                st.setWithdrawer(address(newSya), true);
                _end();
                console.log("4. setWithdrawer(newSYA, true) on", strategies[i]);
            }
            require(st.authorizedWithdrawers(address(newSya)), "4: new SYA is not a withdrawer");
        }
    }

    // ============================================================
    // 5. Retire the old SYA
    // ============================================================

    function _retireOldSya() internal {
        IOldSYA old = IOldSYA(OLD_SYA);
        IPauserV2SyaGateOff p = IPauserV2SyaGateOff(PAUSER_V2);

        // 5.1 Unregister FIRST so PauserV2.health() stays clean, then move pauser() off PauserV2 (CLAUDE.md).
        if (p.isRegistered(OLD_SYA)) {
            _send("5.1 PauserV2.unregister(oldSYA)");
            p.unregister(OLD_SYA);
            _end();
            console.log("5.1 PauserV2.unregister(oldSYA)");
        }
        require(!p.isRegistered(OLD_SYA), "5.1: old SYA still registered with PauserV2");
        if (old.pauser() == PAUSER_V2) {
            _send("5.1 oldSYA.setPauser(OWNER)");
            old.setPauser(OWNER);
            _end();
            console.log("5.1 oldSYA.setPauser(OWNER) - pauser() off PauserV2 (CLAUDE.md retirement rule)");
        }
        require(old.pauser() != PAUSER_V2 && old.pauser() != PAUSER_V1, "5.1: old SYA pauser still a global Pauser");

        // 5.2 Revoke the old SYA's withdrawer right on every strategy.
        for (uint256 i = 0; i < strategies.length; i++) {
            ISyaStrategyAdmin st = ISyaStrategyAdmin(strategies[i]);
            if (st.authorizedWithdrawers(OLD_SYA)) {
                _send("5.2 setWithdrawer(oldSYA, false)");
                st.setWithdrawer(OLD_SYA, false);
                _end();
                console.log("5.2 setWithdrawer(oldSYA, false) on", strategies[i]);
            }
            require(!st.authorizedWithdrawers(OLD_SYA), "5.2: old SYA still a withdrawer");
        }

        // 5.3 Remove every strategy from the old SYA, over a snapshot (removal is swap-and-pop).
        address[] memory snap = old.getYieldStrategies();
        for (uint256 i = 0; i < snap.length; i++) {
            if (old.isRegisteredStrategy(snap[i])) {
                _send("5.3 oldSYA.removeYieldStrategy");
                old.removeYieldStrategy(snap[i]);
                _end();
                console.log("5.3 oldSYA.removeYieldStrategy", snap[i]);
            }
        }
        require(old.getYieldStrategies().length == 0, "5.3: old SYA still lists strategies");

        // 5.4 Burner right on NFTMinterV2.
        if (INFTMinterV2SyaGateOff(NFT_MINTER).authorizedBurners(OLD_SYA)) {
            _send("5.4 NFTMinterV2.setAuthorizedBurner(oldSYA, false)");
            INFTMinterV2SyaGateOff(NFT_MINTER).setAuthorizedBurner(OLD_SYA, false);
            _end();
            console.log("5.4 NFTMinterV2.setAuthorizedBurner(oldSYA, false)");
        }
        require(!INFTMinterV2SyaGateOff(NFT_MINTER).authorizedBurners(OLD_SYA), "5.4: old SYA still a burner");

        // 5.5 Phlimbo allowance to zero.
        if (IERC20(USDC).allowance(OLD_SYA, wiring.phlimbo) != 0) {
            _send("5.5 oldSYA.approvePhlimbo(0)");
            old.approvePhlimbo(0);
            _end();
            console.log("5.5 oldSYA.approvePhlimbo(0)");
        }
        require(IERC20(USDC).allowance(OLD_SYA, wiring.phlimbo) == 0, "5.5: old SYA phlimbo allowance != 0");
        // Deliberately NOT paused, and the V1 Pauser is never called.
    }

    // ============================================================
    // 6. SYAHarvester redeploy
    // ============================================================

    function _deployOrAdoptHarvester() internal {
        Config memory c = _harvesterConfig(address(newSya));
        address recorded = _progressHarvester();
        if (recorded != address(0)) {
            require(recorded != OLD_HARVESTER, "6: refusing to adopt the OLD harvester");
            _requireRecordedLanded(recorded, "SYAHarvester");
            harvester = SYAHarvester(payable(recorded));
            (, harvesterCreateNonce) = _progressNonce("SYAHarvester");
            _checkImmutables(harvester, c);
            console.log("6. new SYAHarvester adopted from progress file:", recorded);
            return;
        }
        harvesterCreateNonce = vm.getNonce(OWNER);
        _send("6 new SYAHarvester");
        harvester = new SYAHarvester(
            OWNER, IPoolManager(POOL_MANAGER), IStableYieldAccumulator(address(newSya)), ICurveRouterNG(CURVE_ROUTER_NG)
        );
        _end();
        deployedHarvesterThisRun = true;
        _checkImmutables(harvester, c);
        console.log("6. new SYAHarvester deployed:", address(harvester));
        if (!isPreview) _writePendingProgress();
    }

    function _configureHarvester() internal {
        Config memory c = _harvesterConfig(address(newSya));
        _setRouteIfNeeded(usdeRoute(c), "USDe");
        _setRouteIfNeeded(dolaRoute(c), "DOLA");
        if (!_ethPoolStored(harvester, c)) {
            _send("6 setEthPool");
            harvester.setEthPool(ethPoolKey(c));
            _end();
            console.log("6. setEthPool(ETH/USDC, fee 3000, tickSpacing 60, no hooks)");
        }
        _checkConfigured(harvester, c);
    }

    function _setRouteIfNeeded(Route memory r, string memory name) internal {
        if (_routeStored(harvester, r)) return;
        _send(string.concat("6 setRoute(", name, ")"));
        harvester.setRoute(r.token, r.path, r.swapParams, r.pools);
        _end();
        console.log(string.concat("6. setRoute(", name, ")"));
    }

    // ============================================================
    // 7. Postconditions
    // ============================================================

    function _requireFinalState() internal view {
        StableYieldAccumulator s = newSya;
        require(s.owner() == OWNER, "final: new SYA owner != OWNER");
        address[3] memory t = _targetTokens();
        for (uint256 i = 0; i < 3; i++) {
            require(_tokenConfigured(t[i]), "final: new SYA token config != hard-coded constant");
        }
        require(s.rewardToken() == USDC, "final: rewardToken != USDC");
        require(s.phlimbo() == wiring.phlimbo, "final: phlimbo mismatch");
        require(s.nudge() == wiring.nudge, "final: nudge mismatch");
        require(s.nudgeSplit() == wiring.nudgeSplit, "final: nudgeSplit mismatch");
        require(s.nudgeStreamer() == wiring.nudgeStreamer, "final: nudgeStreamer mismatch");
        require(s.nftMinter() == address(0), "final: nftMinter != 0");
        require(s.getDiscountRate() == NEW_DISCOUNT_BPS, "final: discount != 100");
        require(s.pauser() == PAUSER_V2, "final: pauser != PauserV2");
        require(IPauserV2SyaGateOff(PAUSER_V2).isRegistered(address(s)), "final: new SYA not registered");
        require(!s.paused(), "final: new SYA is paused");
        address[] memory list = s.getYieldStrategies();
        address[] memory toks = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            toks[i] = s.strategyTokens(list[i]);
            require(ISyaStrategyAdmin(list[i]).authorizedWithdrawers(address(s)), "final: new SYA not a withdrawer");
            require(!ISyaStrategyAdmin(list[i]).authorizedWithdrawers(OLD_SYA), "final: old SYA still a withdrawer");
        }
        _requireStrategyTokenSet(list, toks);

        IOldSYA old = IOldSYA(OLD_SYA);
        require(old.getYieldStrategies().length == 0, "final: old SYA strategy list not empty");
        require(!IPauserV2SyaGateOff(PAUSER_V2).isRegistered(OLD_SYA), "final: old SYA still registered");
        require(old.pauser() != PAUSER_V2, "final: old SYA pauser() is still PauserV2");
        require(!INFTMinterV2SyaGateOff(NFT_MINTER).authorizedBurners(OLD_SYA), "final: old SYA still a burner");
        require(IERC20(USDC).allowance(OLD_SYA, wiring.phlimbo) == 0, "final: old SYA phlimbo allowance != 0");

        Config memory c = _harvesterConfig(address(s));
        _checkConfigured(harvester, c);
        require(address(harvester) != OLD_HARVESTER, "final: harvester is the old one");
        console.log("Postconditions OK: new SYA wired (gate off, 1%, PauserV2), old SYA retired, harvester configured.");
    }

    // ============================================================
    // Preview-only smoke (snapshot-reverted; never OWNER as caller)
    // ============================================================

    /// @dev A non-NFT-holding EOA claims on the new SYA after SMOKE_WARP of accrual and pays exactly the 1%-discounted
    ///      price; Phlimbo receives the payment minus the nudge share, the NudgeStreamer pulls the rest.
    function _smokeClaim() internal {
        console.log("\n=== Preview smoke: claim(0) by a non-NFT-holder (snapshot-reverted) ===");
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + SMOKE_WARP);
        address claimer = makeAddr("story131-claim-smoke");
        require(claimer != OWNER, "smoke: claimer must never be OWNER");
        uint256 next = INFTMinterV2SyaGateOff(NFT_MINTER).nextIndex();
        for (uint256 id = 0; id <= next; id++) {
            require(INFTMinterV2SyaGateOff(NFT_MINTER).balanceOf(claimer, id) == 0, "smoke: claimer holds a claim NFT");
        }
        require(newSya.canClaim(claimer), "smoke: canClaim(non-holder) must be true with the gate off");
        deal(USDC, claimer, 1_000_000e6);
        vm.prank(claimer);
        IERC20(USDC).approve(address(newSya), type(uint256).max);

        uint256 phBefore = IERC20(USDC).balanceOf(wiring.phlimbo);
        vm.recordLogs();
        vm.prank(claimer);
        newSya.claim(0, 0, new address[](0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 normalized;
        uint256 paid;
        bytes32 collected = keccak256("RewardsCollected(address,uint256)");
        bytes32 claimed = keccak256("RewardsClaimed(address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(newSya) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == collected) {
                address strat = address(uint160(uint256(logs[i].topics[1])));
                uint256 amt = abi.decode(logs[i].data, (uint256));
                uint8 dec = _expectedDecimals(newSya.strategyTokens(strat));
                normalized += amt * 10 ** (18 - dec);
            } else if (logs[i].topics[0] == claimed) {
                (paid,) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        require(normalized > 0 && paid > 0, "smoke: claim collected no yield");
        uint256 expected = (normalized * (10_000 - NEW_DISCOUNT_BPS) / 10_000) / 1e12;
        console.log("  yield (18-dec normalized):", normalized);
        console.log("  paid (USDC, 6 dec):       ", paid);
        require(paid == expected, "smoke: payment != yield x 99% (1% discount)");
        // Phlimbo gets the payment minus the nudge share; the NudgeStreamer pulls the nudge share (it may stream
        // part of its buffer onward in the same call, so its own balance is not a clean measure); the SYA keeps 0.
        uint256 nudgeShare = paid * wiring.nudgeSplit / 100;
        require(
            IERC20(USDC).balanceOf(wiring.phlimbo) - phBefore == paid - nudgeShare,
            "smoke: Phlimbo did not receive payment minus the nudge share"
        );
        require(IERC20(USDC).balanceOf(address(newSya)) == 0, "smoke: new SYA kept USDC after the claim");
        require(IERC20(USDC).allowance(address(newSya), wiring.nudgeStreamer) == 0, "smoke: streamer allowance left");
        _assertOwnerBalancesNotIncreased("claim smoke (before revert)");
        vm.revertToState(snap);
        smokeClaimPaid = paid;
        smokeClaimYieldNormalized = normalized;
        console.log("  claim smoke OK (reverted)");
    }

    /// @dev A non-OWNER caller harvests through the new harvester with nftIndex 0: ETH out, no NFT moves.
    function _smokeHarvest() internal {
        console.log("\n=== Preview smoke: harvest(nftIndex 0) by a non-OWNER caller (snapshot-reverted) ===");
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + SMOKE_WARP);
        address caller = makeAddr("story131-harvest-smoke");
        require(caller != OWNER, "smoke: harvest caller must never be OWNER");
        uint256 next = INFTMinterV2SyaGateOff(NFT_MINTER).nextIndex();
        uint256[] memory hBal = new uint256[](next + 1);
        for (uint256 id = 0; id <= next; id++) {
            hBal[id] = INFTMinterV2SyaGateOff(NFT_MINTER).balanceOf(address(harvester), id);
            require(INFTMinterV2SyaGateOff(NFT_MINTER).balanceOf(caller, id) == 0, "smoke: harvest caller holds an NFT");
        }
        uint256 claimBefore = newSya.calculateClaimAmount(new address[](0));
        require(claimBefore > 0, "smoke: new SYA has no claimable yield");
        uint256 ethBefore = caller.balance;
        uint256 gasPriceBefore = tx.gasprice;
        vm.txGasPrice(0);
        vm.prank(caller, caller);
        harvester.harvest(new address[](0), 0, 1);
        vm.txGasPrice(gasPriceBefore);
        uint256 ethOut = caller.balance - ethBefore;
        console.log("  harvest ETH balance delta (wei):", ethOut);
        require(ethOut > 0, "smoke: harvest paid no ETH");
        for (uint256 id = 0; id <= next; id++) {
            require(INFTMinterV2SyaGateOff(NFT_MINTER).balanceOf(caller, id) == 0, "smoke: an NFT moved to the caller");
            require(
                INFTMinterV2SyaGateOff(NFT_MINTER).balanceOf(address(harvester), id) == hBal[id],
                "smoke: an NFT moved through the harvester"
            );
        }
        require(newSya.calculateClaimAmount(new address[](0)) < claimBefore, "smoke: yield not consumed");
        require(address(harvester).balance == 0, "smoke: harvester kept ETH");
        require(IERC20(USDC).balanceOf(address(harvester)) == 0, "smoke: harvester kept USDC");
        require(IERC20(DOLA).balanceOf(address(harvester)) == 0, "smoke: harvester kept DOLA");
        require(IERC20(USDE).balanceOf(address(harvester)) == 0, "smoke: harvester kept USDe");
        require(IERC20(CRVUSD).balanceOf(address(harvester)) == 0, "smoke: harvester kept crvUSD");
        _assertOwnerBalancesNotIncreased("harvest smoke (before revert)");
        vm.revertToState(snap);
        smokeHarvestEthOut = ethOut;
        console.log("  harvest smoke OK (reverted)");
    }

    /// @dev A residual claim on the retired old SYA reverts. Probed by a throwaway NFT holder (the old SYA still
    ///      gates on the NFT) after SMOKE_WARP of accrual. The revert data is logged and recorded.
    function _smokeOldSyaClaim() internal {
        console.log("\n=== Preview smoke: residual claim on the OLD SYA reverts (snapshot-reverted) ===");
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + SMOKE_WARP);
        address holder = makeAddr("story131-old-sya-claimer");
        dealERC1155(NFT_MINTER, holder, 4, 1, false);
        deal(USDC, holder, 1_000_000e6);
        vm.prank(holder);
        IERC20(USDC).approve(OLD_SYA, type(uint256).max);
        bool ok;
        bytes memory ret;
        vm.prank(holder);
        (ok, ret) = OLD_SYA.call(abi.encodeCall(IOldSYA.claim, (4, 0, new address[](0))));
        require(!ok, "smoke: a claim on the retired old SYA SUCCEEDED");
        console.log("  old SYA claim reverted; revert data:");
        console.logBytes(ret);
        vm.revertToState(snap);
        smokeOldClaimRevert = ret;
    }

    /// @notice V2.pause() by a throwaway EYE holder -> every registrant with a paused() getter (incl. the new SYA)
    ///         reports paused and a new-SYA claim reverts -> V2.unpause() as OWNER -> all unpaused, claim works.
    function _globalPauseRoundTrip() internal {
        console.log("\n=== Preview global PauserV2 pause round-trip incl. the new SYA (snapshot-reverted) ===");
        IPauserV2SyaGateOff p = IPauserV2SyaGateOff(PAUSER_V2);
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + SMOKE_WARP);
        address actor = makeAddr("story131-global-pause-actor");
        uint256 burnAmt = p.eyeBurnAmount();
        address eye = p.eyeToken();
        deal(eye, actor, burnAmt, false);
        vm.prank(actor);
        IERC20(eye).approve(PAUSER_V2, burnAmt);
        vm.prank(actor);
        p.pause();

        address[] memory regs = p.getPausableContracts();
        require(_contains(regs, address(newSya)), "pause round-trip: new SYA is not a PauserV2 registrant");
        require(!_contains(regs, OLD_SYA), "pause round-trip: old SYA is still a PauserV2 registrant");
        uint256 checked;
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bool isPaused) = _probePaused(regs[i]);
            if (!ok) continue;
            require(isPaused, "pause round-trip: a registrant is NOT paused after V2.pause()");
            checked++;
        }
        require(newSya.paused(), "pause round-trip: new SYA NOT paused after V2.pause()");

        address claimer = makeAddr("story131-pause-claimer");
        deal(USDC, claimer, 1_000_000e6);
        vm.prank(claimer);
        IERC20(USDC).approve(address(newSya), type(uint256).max);
        vm.prank(claimer);
        try newSya.claim(0, 0, new address[](0)) {
            revert("pause round-trip: claim must revert while paused");
        } catch {}

        vm.prank(OWNER);
        p.unpause();
        for (uint256 i = 0; i < regs.length; i++) {
            (bool ok, bool isPaused) = _probePaused(regs[i]);
            if (!ok) continue;
            require(!isPaused, "pause round-trip: a registrant is still paused after V2.unpause()");
        }
        vm.prank(claimer);
        newSya.claim(0, 0, new address[](0));
        _assertOwnerBalancesNotIncreased("pause round-trip (before revert)");
        vm.revertToState(snap);
        smokePauseChecked = checked;
        console.log("  pause round-trip OK; registrants with a paused() getter checked:", checked);
    }

    function _probePaused(address c) internal view returns (bool ok, bool isPaused) {
        (bool success, bytes memory data) = c.staticcall(abi.encodeWithSignature("paused()"));
        if (!success || data.length < 32) return (false, false);
        uint256 w = abi.decode(data, (uint256));
        if (w > 1) return (false, false);
        return (true, w == 1);
    }

    // ============================================================
    // Broadcast plumbing
    // ============================================================

    /// @dev Completion gate pointer (story 134, audit pps56m1 / pps56l4).
    string internal constant COMPLETED_POINTER =
        ": sya-gate-off has completed (progress deploymentStatus == completed), so a re-run must send nothing (pps56m1). To finish a run that was wrongly marked completed, see runbook docs/runbooks/sya-gate-off-mainnet.md";

    /// @notice COMPLETION GATE (story 134, audit pps56m1 / pps56l4). Every broadcastable write in this script goes
    ///         through `_send`, which calls this first. Once the progress file is `completed` (set only by
    ///         scripts/confirm-sya-gate-off-progress.js after a forge run exited 0) and the SYA was adopted, ANY write
    ///         refuses, naming the step, before it is sent - in PREVIEW and broadcast alike. Forge broadcasts nothing
    ///         when `run()` reverts, so no earlier step leaks either. A completed re-run with nothing to change never
    ///         reaches a write and stays a quiet 0-tx no-op. A `pending` (interrupted) run is not gated; it resumes,
    ///         guarded by the story-133 value check (`_refuseRollbacksOnAdoptedSya`).
    /// @dev NOT virtual, and deliberately not inside `_begin()`: fork-test harnesses override `_begin` without calling
    ///      super, which would silently bypass a gate placed there. A recorded SYA forces adoption, so `completed`
    ///      implies `!deployedSyaThisRun`; the flag is checked anyway so a fresh deploy can never be gated.
    function _requireNotCompleted(string memory step) internal view {
        if (!deployedSyaThisRun && _progressCompleted()) {
            revert(string.concat("re-run guard: refusing step ", step, COMPLETED_POINTER));
        }
    }

    /// @dev The single entry point for every write: completion gate first, then `_begin()` (gas headroom, prank or
    ///      broadcast). NOT virtual, so no harness can bypass the gate.
    function _send(string memory step) internal {
        _requireNotCompleted(step);
        _begin();
    }

    function _begin() internal virtual {
        if (!isPreview && txCount == 0) _requireBroadcastGasPriceHeadroom();
        txCount++;
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

    /// @dev Legacy txs at a fixed `--with-gas-price $SYA_GATE_OFF_GAS_PRICE_WEI` stall while basefee exceeds it;
    ///      require 2x headroom before the first tx of a broadcast (story 128 / audit 49 L-03 pattern).
    function _requireBroadcastGasPriceHeadroom() internal view virtual {
        uint256 gasPriceWei = vm.envOr("SYA_GATE_OFF_GAS_PRICE_WEI", uint256(0));
        require(gasPriceWei > 0, "SYA_GATE_OFF_GAS_PRICE_WEI unset or 0");
        console.log("Gas price (wei):", gasPriceWei, " block.basefee (wei):", block.basefee);
        require(
            gasPriceWei >= block.basefee * 2,
            "SYA_GATE_OFF_GAS_PRICE_WEI < 2 x block.basefee: raise it (runbook: Gas stall)"
        );
    }

    // ============================================================
    // Progress
    // ============================================================

    /// @notice Forge runs this in its LOCAL pass, before the CREATE is signed: record `pending` + each CREATE nonce.
    ///         Written only under SYA_GATE_OFF_BROADCAST=true (the :broadcast key alone).
    function _writePendingProgress() internal {
        if (!_progressWriteEnabledFromEnv()) {
            console.log("SYA_GATE_OFF_BROADCAST unset: dry run, progress file NOT written.");
            return;
        }
        vm.serializeAddress("s131.sya", "address", address(newSya));
        vm.serializeUint("s131.sya", "createNonce", syaCreateNonce);
        string memory syaEntry = vm.serializeBool("s131.sya", "deployed", false);
        string memory contracts = vm.serializeString("s131.contracts", "StableYieldAccumulator", syaEntry);
        if (address(harvester) != address(0)) {
            vm.serializeAddress("s131.harvester", "address", address(harvester));
            vm.serializeUint("s131.harvester", "createNonce", harvesterCreateNonce);
            string memory hEntry = vm.serializeBool("s131.harvester", "deployed", false);
            contracts = vm.serializeString("s131.contracts", "SYAHarvester", hEntry);
        }
        vm.serializeUint("s131.root", "chainId", CHAIN_ID);
        vm.serializeString("s131.root", "networkName", NETWORK_NAME);
        vm.serializeAddress("s131.root", "oldStableYieldAccumulator", OLD_SYA);
        vm.serializeAddress("s131.root", "oldSYAHarvester", OLD_HARVESTER);
        vm.serializeString("s131.root", "deploymentStatus", "pending");
        string memory json = vm.serializeString("s131.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written (pending until confirmed):", _progressFile());
    }

    /// @notice A recorded address with no code is a CREATE still pending or one that never landed. OWNER's confirmed
    ///         nonce tells them apart; redeploying while the CREATE may be in the mempool would make two contracts.
    function _requireRecordedLanded(address recorded, string memory key) internal view {
        if (recorded.code.length > 0) return;
        (bool has, uint256 createNonce) = _progressNonce(key);
        require(
            has,
            string.concat(
                "Progress file names a ", key, " with NO CODE and records no createNonce: check OWNER's nonce by hand"
            )
        );
        string memory n = vm.toString(createNonce);
        if (vm.getNonce(OWNER) <= createNonce) {
            revert(
                string.concat(
                    "Progress file names a ",
                    key,
                    " with NO CODE, but OWNER has not consumed its create nonce ",
                    n,
                    ": the deploy tx may be PENDING. Wait, or replace that nonce at a higher SYA_GATE_OFF_GAS_PRICE_WEI. Do NOT delete the progress file."
                )
            );
        }
        revert(
            string.concat(
                "Progress file names a ",
                key,
                " with NO CODE although OWNER consumed its create nonce ",
                n,
                ": the deploy never landed. Remove that entry from ",
                _progressFile(),
                " and re-run preview."
            )
        );
    }

    /// @dev Set only by the :broadcast key. `virtual` so tests can pin it (vm.setEnv is process-wide).
    function _progressWriteEnabledFromEnv() internal view virtual returns (bool) {
        return vm.envOr("SYA_GATE_OFF_BROADCAST", false);
    }

    /// @dev The ONE reader of PREVIEW_MODE; `virtual` only so fork-test harnesses can pin it.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }

    // ---- Views for the fork tests ----

    function strategyList() external view returns (address[] memory) {
        return strategies;
    }
}
