// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SkimAndLeg1Migration
 * @notice Story 060 - Step 2: skim surplus from old strategies, pay Phlimbo collectReward for
 *         the upcoming USDC drain coverage, then initiate + execute leg-1 migration
 *         (original staker → tempStaker) for DOLA and USDC.
 *
 *         Run AFTER DeployTempStableStakerAndMigrators (step 1) has been broadcast and the
 *         deployment JSON written to script/migration-inputs/ys-swap-deployments.json.
 *
 *         This script reads:
 *           - script/migration-inputs/ys-swap-deployments.json  (migrator1 address)
 *           - script/migration-inputs/leg1-stakers.json          (staker counts + chunks)
 *
 *         Order CRITICAL:
 *           1. _globalPreflight (60 USDC check as FIRST line)
 *           2. skim all 3 old strategies
 *           3. USDC approve + PhlimboV2 collectReward(60e6)
 *           4. initiateMigration for DOLA + USDC
 *           5. batchMigrate chunks from leg1-stakers.json
 *           6. Persist skim amounts to deployments JSON
 *           7. Post-assert
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/SkimAndLeg1Migration.s.sol:SkimAndLeg1Migration \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/SkimAndLeg1Migration.s.sol:SkimAndLeg1Migration \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

/// @dev Minimal interface for old yield strategies - compatible with the pre-story-025 deployed bytecode.
interface IOldYS {
    function owner() external view returns (address);
    function skimSurplus(address token, address recipient) external returns (uint256);
    // YS-02: owner must be an authorized withdrawer for skimSurplus (onlyAuthorizedWithdrawer).
    function authorizedWithdrawers(address) external view returns (bool);
    function setWithdrawer(address withdrawer, bool _auth) external; // onlyOwner
    // Phase 4 shortfall pre-fund (story-065): read staker/minter positions + owner-evacuate.
    function principalOf(address token, address account) external view returns (uint256);
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function withdrawAsOwner(address client, address recipient, uint256 amount) external; // onlyOwner
}

/// @dev StableStaker pool lifecycle (StableStaker.sol: enum PoolState { Active, Migrating }).
///      Default 0 == Active. Used for the YS-09 resume/idempotency guards.
enum PoolState {
    Active,
    Migrating
}

/// @dev Minimal interface for StableStakerMigrator (owner-facing).
interface IMinMigrator {
    function owner() external view returns (address);
    function initiateMigration(address token) external;
    function migrate(address token, address[] calldata users) external;
}

/// @dev Minimal interface for on-chain staker reads + YS-09 pause/resume guards.
interface IStakerView {
    function migrator() external view returns (address);
    function stakerCount(address token) external view returns (uint256);
    function poolInfo(address token) external view returns (uint256, uint256, uint256, uint256);
    // YS-09 guards.
    function poolState(address token) external view returns (PoolState);
    function paused() external view returns (bool);
}

/// @dev PhlimboV2 collectReward (USDC → reward pot).
interface IPhlimbo {
    function collectReward(uint256 amount) external;
}

contract SkimAndLeg1Migration is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES
    // ==========================================

    address public constant OWNER_ADDRESS          = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant ORIGINAL_STABLE_STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    // Phase 4 (story-065): old phUSD minter — the shortfall shock-absorber the pre-fund draws from.
    address public constant OLD_MINTER             = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;

    // Old (buggy) yield strategies to skim before the swap.
    address public constant YS_DOLA_OLD            = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant YS_USDC_OLD            = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;
    address public constant YS_USDE                = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;

    address public constant DOLA                   = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC                   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDe                   = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    address public constant PHLIMBO_V2             = 0x6084a02C2Ac0127ddF1e617De257c61480A2AeE0;

    uint256 public constant CHAIN_ID               = 1;
    uint256 public constant PHLIMBO_COLLECT_AMOUNT = 60e6; // 60 USDC

    // ==========================================
    //   RUNTIME STATE
    // ==========================================

    bool    public isPreview;
    uint256 public dolaSkimmed;
    uint256 public usdcSkimmed;
    uint256 public usdeSkimmed;
    // Phase 4 (story-065): shortfall pre-funded from the minter onto the original staker as idle
    // balance (swept into V2 by ResetAndRewire's setYieldStrategy).
    uint256 public dolaPrefunded;
    uint256 public usdcPrefunded;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "SkimAndLeg1Migration: wrong chain - expected mainnet (1)");
    }

    function _globalPreflight() internal view {
        // CRITICAL: 60-USDC check is FIRST - must execute before any prank/broadcast.
        require(
            IERC20(USDC).balanceOf(OWNER_ADDRESS) >= PHLIMBO_COLLECT_AMOUNT,
            "Pre-flight: deployer needs >= 60 USDC for Phlimbo collectReward"
        );

        // Read deployments JSON to validate migrator1 is wired.
        string memory deploymentsRaw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address migrator1Addr = vm.parseJsonAddress(deploymentsRaw, ".migrator1");
        require(migrator1Addr != address(0), "Preflight: migrator1 address is zero in deployments JSON");

        // Verify migrator1 is set on both stakers.
        address origMigrator = IStakerView(ORIGINAL_STABLE_STAKER).migrator();
        require(
            origMigrator == migrator1Addr,
            "Preflight: migrator1 not set on original staker - re-run step 1"
        );

        address tempStakerAddr = vm.parseJsonAddress(deploymentsRaw, ".tempStaker");
        address tempMigrator = IStakerView(tempStakerAddr).migrator();
        require(
            tempMigrator == migrator1Addr,
            "Preflight: migrator1 not set on tempStaker - re-run step 1"
        );

        // YS-09 hard pause gate: BOTH stakers must be paused before leg1 migrates, so the
        // empty-pool gate (totalStaked == 0) cannot be re-locked by a stake() grief during the
        // leg1->leg2 halt window. The deploy step performs the pause; this is the loud backstop
        // that proves the grief surface is closed for the whole migration span. initiateMigration /
        // batchMigrate / depositFor are deliberately NOT whenNotPaused, so the runbook still runs.
        require(
            IStakerView(ORIGINAL_STABLE_STAKER).paused(),
            "Preflight: original staker NOT paused - run deploy step (pause) first"
        );
        require(
            IStakerView(tempStakerAddr).paused(),
            "Preflight: tempStaker NOT paused - run deploy step (pause) first"
        );

        // Verify old strategy owners.
        require(
            IOldYS(YS_DOLA_OLD).owner() == OWNER_ADDRESS,
            "Preflight: YS_DOLA_OLD owner != OWNER_ADDRESS"
        );
        require(
            IOldYS(YS_USDC_OLD).owner() == OWNER_ADDRESS,
            "Preflight: YS_USDC_OLD owner != OWNER_ADDRESS"
        );
        require(
            IOldYS(YS_USDE).owner() == OWNER_ADDRESS,
            "Preflight: YS_USDE owner != OWNER_ADDRESS"
        );

        // Verify migrator1 owner.
        require(
            IMinMigrator(migrator1Addr).owner() == OWNER_ADDRESS,
            "Preflight: migrator1 owner != OWNER_ADDRESS"
        );

        // Check leg1-stakers.json exists and counts match on-chain.
        string memory leg1Raw = vm.readFile("script/migration-inputs/leg1-stakers.json");
        uint256 dolaCount = vm.parseJsonUint(leg1Raw, ".tokens.DOLA.count");
        uint256 usdcCount = vm.parseJsonUint(leg1Raw, ".tokens.USDC.count");
        require(
            dolaCount == IStakerView(ORIGINAL_STABLE_STAKER).stakerCount(DOLA),
            "Preflight: stale DOLA staker count in leg1-stakers.json - re-run gather"
        );
        require(
            usdcCount == IStakerView(ORIGINAL_STABLE_STAKER).stakerCount(USDC),
            "Preflight: stale USDC staker count in leg1-stakers.json - re-run gather"
        );

        console.log("Preflight OK - deployer USDC balance:", IERC20(USDC).balanceOf(OWNER_ADDRESS));
        console.log("leg1 DOLA stakers:", dolaCount);
        console.log("leg1 USDC stakers:", usdcCount);
    }

    function run() external {
        console.log("==========================================");
        console.log(" SkimAndLeg1Migration (story 060, step 2)");
        console.log("==========================================");
        console.log("Chain ID:          ", block.chainid);
        console.log("Owner (ledger):    ", OWNER_ADDRESS);
        console.log("");

        // Preflight BEFORE prank/broadcast.
        _globalPreflight();

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

        // Read deployment addresses.
        string memory deploymentsRaw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address migrator1Addr = vm.parseJsonAddress(deploymentsRaw, ".migrator1");
        address tempStakerAddr = vm.parseJsonAddress(deploymentsRaw, ".tempStaker");
        console.log("migrator1:   ", migrator1Addr);
        console.log("tempStaker:  ", tempStakerAddr);
        console.log("");

        // ---- Step 0 (YS-02): ensure owner is an authorized WITHDRAWER on all 3 old strategies ----
        // skimSurplus is onlyAuthorizedWithdrawer; without this the leg-1 skim is DOA (YS-02). The
        // grant is onlyOwner and idempotent (setting true when already true is harmless).
        console.log("=== Step 0 (YS-02): grant owner authorizedWithdrawer on old strategies ===");
        _ensureWithdrawer(YS_DOLA_OLD);
        _ensureWithdrawer(YS_USDC_OLD);
        _ensureWithdrawer(YS_USDE);
        // Assert WITHDRAWER status (not just owner()) per YS-02 before skimming.
        require(IOldYS(YS_DOLA_OLD).authorizedWithdrawers(OWNER_ADDRESS), "YS-02: owner not withdrawer on YS_DOLA_OLD");
        require(IOldYS(YS_USDC_OLD).authorizedWithdrawers(OWNER_ADDRESS), "YS-02: owner not withdrawer on YS_USDC_OLD");
        require(IOldYS(YS_USDE).authorizedWithdrawers(OWNER_ADDRESS), "YS-02: owner not withdrawer on YS_USDE");
        console.log("");

        // ---- Step 1: skim all 3 old strategies ----
        console.log("=== Step 1: skim surplus from old strategies ===");
        dolaSkimmed = IOldYS(YS_DOLA_OLD).skimSurplus(DOLA, ORIGINAL_STABLE_STAKER);
        console.log("  DOLA skimmed:  ", dolaSkimmed);
        usdcSkimmed = IOldYS(YS_USDC_OLD).skimSurplus(USDC, ORIGINAL_STABLE_STAKER);
        console.log("  USDC skimmed:  ", usdcSkimmed);
        usdeSkimmed = IOldYS(YS_USDE).skimSurplus(USDe, ORIGINAL_STABLE_STAKER);
        console.log("  USDe skimmed:  ", usdeSkimmed);
        console.log("");

        // ---- Step 1.5 (Phase 4 / story-065): shortfall pre-fund — THE SAFETY CRUX ----
        // ⚠️ FORK-VALIDATE BEFORE BROADCAST. Getting this wrong harms staker users. Below-par on the
        // staker must be IMPOSSIBLE after this step; the minter (parked TVL) absorbs the deficit.
        //
        // After the skim, the original staker still holds its FULL client position on each old
        // strategy. If the strategy is below par (over-credit bug), the staker's realizable value
        // (totalBalanceOf = its pro-rata share of real vault value) is less than its booked principal
        // (principalOf). That gap is the stakerShortfall. We withdraw exactly that gap from the
        // MINTER's allotment (owner-gated withdrawAsOwner; works even though Phase 3 already revoked
        // the minter's client/mint roles) and deliver it to the original staker as idle balance.
        // ResetAndRewire's setYieldStrategy then sweeps that idle into V2 as principal buffer, so the
        // staker realizes 100% of booked principal with zero haircut. HARD-REVERT if the minter
        // cannot cover the shortfall — never silently socialize onto staker users.
        console.log("=== Step 1.5 (Phase 4): shortfall pre-fund from minter -> staker ===");
        dolaPrefunded = _prefundShortfall(YS_DOLA_OLD, DOLA);
        usdcPrefunded = _prefundShortfall(YS_USDC_OLD, USDC);
        console.log("  DOLA pre-funded:", dolaPrefunded);
        console.log("  USDC pre-funded:", usdcPrefunded);
        console.log("");

        // ---- Step 2: USDC approve + PhlimboV2 collectReward ----
        console.log("=== Step 2: PhlimboV2.collectReward(60 USDC) ===");
        IERC20(USDC).approve(PHLIMBO_V2, PHLIMBO_COLLECT_AMOUNT);
        IPhlimbo(PHLIMBO_V2).collectReward(PHLIMBO_COLLECT_AMOUNT);
        console.log("  collectReward called with", PHLIMBO_COLLECT_AMOUNT, "USDC");
        console.log("");

        // ---- Step 3: initiate migration for DOLA and USDC ----
        // YS-09 resume guard: initiateMigration requires PoolState.Active and reverts
        // "pool not active" once Migrating, so on a re-run we skip pools already engaged. The
        // chunked migrate loop below is independently re-run-safe (already-migrated users return 0
        // credit from batchMigrate and are skipped, so re-passing a completed chunk is a no-op).
        console.log("=== Step 3: initiateMigration (DOLA + USDC) ===");
        if (IStakerView(ORIGINAL_STABLE_STAKER).poolState(DOLA) == PoolState.Active) {
            IMinMigrator(migrator1Addr).initiateMigration(DOLA);
            console.log("  initiateMigration(DOLA) called");
        } else {
            console.log("  initiateMigration(DOLA) SKIPPED - already Migrating (resume)");
        }
        if (IStakerView(ORIGINAL_STABLE_STAKER).poolState(USDC) == PoolState.Active) {
            IMinMigrator(migrator1Addr).initiateMigration(USDC);
            console.log("  initiateMigration(USDC) called");
        } else {
            console.log("  initiateMigration(USDC) SKIPPED - already Migrating (resume)");
        }
        console.log("");

        // ---- Step 4: chunk loop from leg1-stakers.json ----
        // YS-09 re-run-safe: StableStaker.batchMigrate returns 0 for an already-migrated/empty
        // position (no per-user flag, no revert) and StableStakerMigrator.migrate early-returns when
        // the chunk total is 0, so re-passing a chunk that already completed on a prior run is a clean
        // no-op. No per-chunk progress marker is needed (verified by the YS-09 fork test).
        console.log("=== Step 4: batch migrate from leg1-stakers.json ===");
        string memory leg1Raw = vm.readFile("script/migration-inputs/leg1-stakers.json");

        uint256 dolaChunkCount = vm.parseJsonUint(leg1Raw, ".tokens.DOLA.chunkCount");
        console.log("  DOLA chunks:", dolaChunkCount);
        for (uint256 i = 0; i < dolaChunkCount; i++) {
            address[] memory chunk = vm.parseJsonAddressArray(
                leg1Raw,
                string(abi.encodePacked(".tokens.DOLA.chunks[", vm.toString(i), "]"))
            );
            IMinMigrator(migrator1Addr).migrate(DOLA, chunk);
            console.log("  DOLA chunk migrated users:", chunk.length);
        }

        uint256 usdcChunkCount = vm.parseJsonUint(leg1Raw, ".tokens.USDC.chunkCount");
        console.log("  USDC chunks:", usdcChunkCount);
        for (uint256 i = 0; i < usdcChunkCount; i++) {
            address[] memory chunk = vm.parseJsonAddressArray(
                leg1Raw,
                string(abi.encodePacked(".tokens.USDC.chunks[", vm.toString(i), "]"))
            );
            IMinMigrator(migrator1Addr).migrate(USDC, chunk);
            console.log("  USDC chunk migrated users:", chunk.length);
        }
        console.log("");

        // ---- Step 5: persist skim amounts to deployments JSON ----
        if (!isPreview) {
            // Append skim amounts to the deployments JSON.
            vm.writeJson(
                vm.toString(dolaSkimmed),
                "script/migration-inputs/ys-swap-deployments.json",
                ".dolaSkimmed"
            );
            vm.writeJson(
                vm.toString(usdcSkimmed),
                "script/migration-inputs/ys-swap-deployments.json",
                ".usdcSkimmed"
            );
            vm.writeJson(
                vm.toString(usdeSkimmed),
                "script/migration-inputs/ys-swap-deployments.json",
                ".usdeSkimmed"
            );
            // Phase 4 (story-065): persist pre-funded shortfall amounts for the audit trail.
            vm.writeJson(
                vm.toString(dolaPrefunded),
                "script/migration-inputs/ys-swap-deployments.json",
                ".dolaPrefunded"
            );
            vm.writeJson(
                vm.toString(usdcPrefunded),
                "script/migration-inputs/ys-swap-deployments.json",
                ".usdcPrefunded"
            );
            console.log("  Skim + pre-fund amounts written to ys-swap-deployments.json");
        }

        // ---- Post-assert ----
        console.log("=== Post-assert ===");
        uint256 origDolaCount = IStakerView(ORIGINAL_STABLE_STAKER).stakerCount(DOLA);
        uint256 origUsdcCount = IStakerView(ORIGINAL_STABLE_STAKER).stakerCount(USDC);
        require(
            origDolaCount == 0,
            "Post-assert: original staker DOLA stakerCount != 0 after leg1"
        );
        require(
            origUsdcCount == 0,
            "Post-assert: original staker USDC stakerCount != 0 after leg1"
        );
        console.log("  original staker DOLA stakerCount: 0 OK");
        console.log("  original staker USDC stakerCount: 0 OK");

        // Surplus must still be parked on the original staker: the skim sent it straight there as idle
        // balance, and leg1's batchMigrate only pays out min(R,P) user credits (≤ realized principal),
        // so the parked surplus cannot have leaked to exiting users. ResetAndRewire's setYieldStrategy
        // sweep later folds this idle balance into the V2 strategies as the principal buffer.
        // Idle balance must hold BOTH the skim surplus AND the Phase-4 shortfall pre-fund — both are
        // parked on the original staker for ResetAndRewire's setYieldStrategy to sweep into V2.
        require(
            IERC20(DOLA).balanceOf(ORIGINAL_STABLE_STAKER) >= dolaSkimmed + dolaPrefunded,
            "Post-assert: original DOLA balance < dolaSkimmed + dolaPrefunded - idle leaked"
        );
        require(
            IERC20(USDC).balanceOf(ORIGINAL_STABLE_STAKER) >= usdcSkimmed + usdcPrefunded,
            "Post-assert: original USDC balance < usdcSkimmed + usdcPrefunded - idle leaked"
        );
        require(
            IERC20(USDe).balanceOf(ORIGINAL_STABLE_STAKER) >= usdeSkimmed,
            "Post-assert: original USDe balance < usdeSkimmed - surplus leaked"
        );
        console.log("  original staker DOLA balance >= dolaSkimmed OK");
        console.log("  original staker USDC balance >= usdcSkimmed OK");
        console.log("  original staker USDe balance >= usdeSkimmed OK");

        uint256 tempDolaCount = IStakerView(tempStakerAddr).stakerCount(DOLA);
        uint256 tempUsdcCount = IStakerView(tempStakerAddr).stakerCount(USDC);
        console.log("  tempStaker DOLA stakerCount:", tempDolaCount);
        console.log("  tempStaker USDC stakerCount:", tempUsdcCount);
        console.log("");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _printSummary();
    }

    /// @dev YS-02: idempotently grant the owner authorizedWithdrawer on an old strategy.
    function _ensureWithdrawer(address ys) internal {
        if (!IOldYS(ys).authorizedWithdrawers(OWNER_ADDRESS)) {
            IOldYS(ys).setWithdrawer(OWNER_ADDRESS, true);
            console.log("  granted withdrawer on:", ys);
        } else {
            console.log("  already withdrawer on:", ys);
        }
    }

    /// @dev Phase 4 (story-065): pre-fund the staker's below-par shortfall from the minter.
    ///      Returns the underlying amount delivered to the original staker (idle balance).
    ///
    ///      ⚠️ SAFETY CRUX — FORK-VALIDATE. The minter is itself below par on the shared pool, so
    ///      withdrawing `shortfall` in PRINCIPAL terms would deliver LESS than `shortfall` underlying.
    ///      We therefore scale the withdrawn principal by the minter's booked/realizable ratio so the
    ///      staker receives ~`shortfall` actual underlying. The exact delivered amount must be
    ///      confirmed on a mainnet fork (and the Phase-5 `staker_realized == staker_booked` assert is
    ///      the ultimate gate). HARD-REVERT if the minter's realizable cannot cover the shortfall.
    function _prefundShortfall(address oldYS, address token) internal returns (uint256 injected) {
        uint256 stakerBooked     = IOldYS(oldYS).principalOf(token, ORIGINAL_STABLE_STAKER);
        uint256 stakerRealizable = IOldYS(oldYS).totalBalanceOf(token, ORIGINAL_STABLE_STAKER);
        if (stakerBooked <= stakerRealizable) {
            console.log("  no staker shortfall (booked <= realizable), token:", token);
            return 0;
        }
        uint256 shortfall = stakerBooked - stakerRealizable;

        uint256 minterBooked     = IOldYS(oldYS).principalOf(token, OLD_MINTER);
        uint256 minterRealizable = IOldYS(oldYS).totalBalanceOf(token, OLD_MINTER);
        // The minter (parked TVL) must be able to cover the shortfall in REAL underlying terms.
        require(
            minterRealizable >= shortfall,
            "Phase 4: staker shortfall exceeds minter realizable allotment - OPERATOR ESCALATION (never socialize onto stakers)"
        );
        require(minterRealizable > 0, "Phase 4: minter has zero realizable - cannot pre-fund");

        // Principal to withdraw so the delivered underlying ~= shortfall:
        //   principalToWithdraw = shortfall * minterBooked / minterRealizable  (>= shortfall when below par)
        // Bounded above by minterBooked (since shortfall <= minterRealizable <= minterBooked).
        uint256 principalToWithdraw = (shortfall * minterBooked) / minterRealizable;
        if (principalToWithdraw > minterBooked) {
            principalToWithdraw = minterBooked;
        }

        uint256 balBefore = IERC20(token).balanceOf(ORIGINAL_STABLE_STAKER);
        IOldYS(oldYS).withdrawAsOwner(OLD_MINTER, ORIGINAL_STABLE_STAKER, principalToWithdraw);
        injected = IERC20(token).balanceOf(ORIGINAL_STABLE_STAKER) - balBefore;

        console.log("  [PHASE4] token                 :", token);
        console.log("  [PHASE4] staker booked         :", stakerBooked);
        console.log("  [PHASE4] staker realizable     :", stakerRealizable);
        console.log("  [PHASE4] staker SHORTFALL       :", shortfall);
        console.log("  [PHASE4] minter booked         :", minterBooked);
        console.log("  [PHASE4] minter realizable     :", minterRealizable);
        console.log("  [PHASE4] principal pulled (mntr):", principalToWithdraw);
        console.log("  [PHASE4] underlying injected    :", injected);
        require(injected > 0, "Phase 4: injection delivered 0 underlying to staker");
        // Loud flag if we under-delivered vs the target shortfall (fork test must confirm sufficiency).
        if (injected < shortfall) {
            console.log("  [PHASE4] *** WARNING: injected < shortfall by:", shortfall - injected);
            console.log("  [PHASE4] *** rounding/below-par dust - CONFIRM staker whole on fork before broadcast");
        } else {
            console.log("  [PHASE4] OK: injected >= shortfall (staker shortfall fully covered)");
        }
        return injected;
    }

    function _printSummary() internal view {
        console.log("==========================================");
        console.log("  SUMMARY (story 060 step 2 + story 065 Phase 4)");
        console.log("==========================================");
        console.log("DOLA skimmed:      ", dolaSkimmed);
        console.log("USDC skimmed:      ", usdcSkimmed);
        console.log("USDe skimmed:      ", usdeSkimmed);
        console.log("DOLA pre-funded:   ", dolaPrefunded);
        console.log("USDC pre-funded:   ", usdcPrefunded);
        console.log("");
        console.log("--- PHASE 4 OPERATOR VERIFICATION (story 065 safety crux) ---");
        console.log("The pre-funded amounts above are now IDLE on the original staker. They are NOT");
        console.log("yet booked as principal. The chain of custody to verify on this fork run:");
        console.log("  1. [HERE] staker idle balance increased by dola/usdcPrefunded (post-assert above).");
        console.log("  2. [ResetAndRewire] setYieldStrategy sweeps that idle into V2 as staker principal.");
        console.log("  3. [Leg2Migration] users migrate back onto V2; CONFIRM each token's");
        console.log("     staker_realized == staker_booked (zero haircut). THIS is the definitive gate.");
        console.log("If any [PHASE4] WARNING above fired (injected < shortfall), step 3 may NOT hold -");
        console.log("do not broadcast; revisit _prefundShortfall scaling. See handoff doc in story 065.");
        console.log("-------------------------------------------------------------");
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
        } else {
            console.log("BROADCAST complete. Proceed to ResetAndRewire (step 3).");
        }
        console.log("==========================================");
    }
}
