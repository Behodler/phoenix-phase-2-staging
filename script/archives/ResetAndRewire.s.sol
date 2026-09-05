// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";

/**
 * @title ResetAndRewire
 * @notice Story 060 - Step 3: finalizeAndReset the original staker pools, wire new V2 yield
 *         strategies, and set up migrator2 for the return leg.
 *
 *         Run AFTER SkimAndLeg1Migration (step 2) has been broadcast.
 *         Reads: script/migration-inputs/ys-swap-deployments.json
 *
 *         Actions:
 *           1. finalizeAndReset(DOLA) + finalizeAndReset(USDC) on original staker
 *           2. setYieldStrategy(DOLA, ysDolaV2) + setYieldStrategy(USDC, ysUsdcV2)
 *           3. Wire migrator2: setMigrator(migrator2) on BOTH stakers
 *
 *         Post-assert (after broadcast/prank stop):
 *           - ysDolaV2.principalOf(DOLA, original) > 0  (set-aside buffer deposited by staker)
 *           - original.poolInfo(DOLA).totalStaked == 0
 *           - ysUsdcV2.principalOf(USDC, original) > 0
 *           - original.poolInfo(USDC).totalStaked == 0
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/ResetAndRewire.s.sol:ResetAndRewire \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST (run patch-mainnet-addresses-ys-swap.js after):
 *   node scripts/backup-mainnet-addresses.js && \
 *   forge script script/ResetAndRewire.s.sol:ResetAndRewire \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv && \
 *   node scripts/patch-mainnet-addresses-ys-swap.js
 */

/// @dev StableStaker pool lifecycle (StableStaker.sol: enum PoolState { Active, Migrating }).
///      Default 0 == Active. Used for the YS-09 resume/idempotency guards.
enum PoolState {
    Active,
    Migrating
}

/// @dev Minimal interface for owner calls + idempotency reads on the original StableStaker.
interface IStakerOwnable {
    function owner() external view returns (address);
    function migrator() external view returns (address);
    function setMigrator(address _migrator) external;
    function finalizeAndReset(address token) external;
    function setYieldStrategy(address token, IYieldStrategy strategy) external;
    function stakerCount(address token) external view returns (uint256);
    function poolInfo(address token) external view returns (uint256, uint256, uint256, uint256);
    // YS-09 resume guards.
    function poolState(address token) external view returns (PoolState);
    function yieldStrategy(address token) external view returns (IYieldStrategy);
}

/// @dev Minimal interface for owner calls on the temp staker.
interface ITempStakerOwnable {
    function owner() external view returns (address);
    function migrator() external view returns (address);
    function setMigrator(address _migrator) external;
}

/// @dev Minimal interface for principalOf on V2 strategies.
interface IYSView {
    function principalOf(address token, address account) external view returns (uint256);
    function setAsideBufferSize(address client) external view returns (uint256);
    function setAsideBufferRecipient() external view returns (address);
}

/// @dev Minimal interface for migrator owner.
interface IMigratorOwnable {
    function owner() external view returns (address);
}

contract ResetAndRewire is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES
    // ==========================================

    address public constant OWNER_ADDRESS          = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant ORIGINAL_STABLE_STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;

    address public constant DOLA                   = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC                   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant CHAIN_ID               = 1;

    // ==========================================
    //   RUNTIME STATE
    // ==========================================

    bool public isPreview;
    // Idle base-token balances swept into the V2 strategies by setYieldStrategy (captured in Step 2,
    // verified against strategy principalOf in the post-assert).
    uint256 public dolaIdleSwept;
    uint256 public usdcIdleSwept;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "ResetAndRewire: wrong chain - expected mainnet (1)");
    }

    function _globalPreflight(
        address ysDolaV2,
        address ysUsdcV2,
        address tempStakerAddr,
        address migrator2Addr
    ) internal view {
        // Original staker must be empty: leg1 must have completed.
        (, , , uint256 dolaTotalStaked) = IStakerOwnable(ORIGINAL_STABLE_STAKER).poolInfo(DOLA);
        require(
            IStakerOwnable(ORIGINAL_STABLE_STAKER).stakerCount(DOLA) == 0,
            "Preflight: original staker DOLA stakerCount != 0 - complete leg1 first"
        );
        require(
            dolaTotalStaked == 0,
            "Preflight: original staker DOLA totalStaked != 0 - complete leg1 first"
        );
        (, , , uint256 usdcTotalStaked) = IStakerOwnable(ORIGINAL_STABLE_STAKER).poolInfo(USDC);
        require(
            IStakerOwnable(ORIGINAL_STABLE_STAKER).stakerCount(USDC) == 0,
            "Preflight: original staker USDC stakerCount != 0 - complete leg1 first"
        );
        require(
            usdcTotalStaked == 0,
            "Preflight: original staker USDC totalStaked != 0 - complete leg1 first"
        );

        // Migrator1 must be set on original (set in step 1).
        address origMigrator = IStakerOwnable(ORIGINAL_STABLE_STAKER).migrator();
        require(origMigrator != address(0), "Preflight: migrator not set on original staker");

        require(ysDolaV2 != address(0), "Preflight: ysDolaV2 address is zero in deployments JSON");
        require(ysUsdcV2 != address(0), "Preflight: ysUsdcV2 address is zero in deployments JSON");
        require(tempStakerAddr != address(0), "Preflight: tempStaker address is zero in deployments JSON");
        require(migrator2Addr != address(0), "Preflight: migrator2 address is zero in deployments JSON");

        require(
            IMigratorOwnable(migrator2Addr).owner() == OWNER_ADDRESS,
            "Preflight: migrator2 owner != OWNER_ADDRESS"
        );
        require(
            ITempStakerOwnable(tempStakerAddr).owner() == OWNER_ADDRESS,
            "Preflight: tempStaker owner != OWNER_ADDRESS"
        );
        require(
            IStakerOwnable(ORIGINAL_STABLE_STAKER).owner() == OWNER_ADDRESS,
            "Preflight: original staker owner != OWNER_ADDRESS"
        );

        console.log("Preflight OK");
        console.log("  original DOLA stakers: 0, totalStaked: 0");
        console.log("  original USDC stakers: 0, totalStaked: 0");
    }

    function run() external {
        console.log("==========================================");
        console.log(" ResetAndRewire (story 060, step 3)");
        console.log("==========================================");
        console.log("Chain ID:          ", block.chainid);
        console.log("Owner (ledger):    ", OWNER_ADDRESS);
        console.log("");

        // Read deployments JSON.
        string memory deploymentsRaw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address ysDolaV2     = vm.parseJsonAddress(deploymentsRaw, ".ysDolaV2");
        address ysUsdcV2     = vm.parseJsonAddress(deploymentsRaw, ".ysUsdcV2");
        address tempStakerAddr = vm.parseJsonAddress(deploymentsRaw, ".tempStaker");
        address migrator2Addr  = vm.parseJsonAddress(deploymentsRaw, ".migrator2");

        console.log("ysDolaV2:    ", ysDolaV2);
        console.log("ysUsdcV2:    ", ysUsdcV2);
        console.log("tempStaker:  ", tempStakerAddr);
        console.log("migrator2:   ", migrator2Addr);
        console.log("");

        _globalPreflight(ysDolaV2, ysUsdcV2, tempStakerAddr, migrator2Addr);

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

        // ---- Step 1: finalizeAndReset ----
        // YS-09 resume guard: finalizeAndReset requires PoolState.Migrating and reverts
        // "pool not migrating" once Active, so on a re-run after a mid-suite halt we must skip
        // the pools that were already revived to Active. Skipping is a true no-op (the pool is
        // already in the post-finalize state).
        console.log("=== Step 1: finalizeAndReset ===");
        if (IStakerOwnable(ORIGINAL_STABLE_STAKER).poolState(DOLA) == PoolState.Migrating) {
            IStakerOwnable(ORIGINAL_STABLE_STAKER).finalizeAndReset(DOLA);
            console.log("  finalizeAndReset(DOLA) done");
        } else {
            console.log("  finalizeAndReset(DOLA) SKIPPED - pool already Active (resume)");
        }
        if (IStakerOwnable(ORIGINAL_STABLE_STAKER).poolState(USDC) == PoolState.Migrating) {
            IStakerOwnable(ORIGINAL_STABLE_STAKER).finalizeAndReset(USDC);
            console.log("  finalizeAndReset(USDC) done");
        } else {
            console.log("  finalizeAndReset(USDC) SKIPPED - pool already Active (resume)");
        }
        console.log("");

        // ---- Step 2: wire new V2 yield strategies ----
        // Capture the idle base-token balance sitting on the original staker IMMEDIATELY before each
        // setYieldStrategy call. `setYieldStrategy` synchronously sweeps this idle balance into the new
        // strategy (StableStaker.setYieldStrategy: `strategy.deposit(token, idleBalance, this)`), so the
        // post-assert can deterministically check the swept amount became strategy principal. This idle
        // balance is the skim surplus parked during leg1 (plus any leg1 migration dust left behind).
        // YS-09 resume guards: setYieldStrategy is the YS-01 brick point. On a re-run after a halt
        // here, the pool may already be wired to V2 (the call landed) — re-calling would attempt to
        // swap an already-set strategy (and, with idle already swept, mis-account). Skip when the live
        // wiring already points at the V2 address. `*Wired` records whether THIS run performed the
        // sweep so the post-assert only applies the swept-amount invariant to freshly-wired pools.
        console.log("=== Step 2: setYieldStrategy (V2) ===");
        bool dolaWired;
        bool usdcWired;
        if (address(IStakerOwnable(ORIGINAL_STABLE_STAKER).yieldStrategy(DOLA)) != ysDolaV2) {
            dolaIdleSwept = IERC20(DOLA).balanceOf(ORIGINAL_STABLE_STAKER);
            IStakerOwnable(ORIGINAL_STABLE_STAKER).setYieldStrategy(DOLA, IYieldStrategy(ysDolaV2));
            dolaWired = true;
            console.log("  setYieldStrategy(DOLA, ysDolaV2) done; idle swept:", dolaIdleSwept);
        } else {
            console.log("  setYieldStrategy(DOLA, ysDolaV2) SKIPPED - already V2 (resume)");
        }
        if (address(IStakerOwnable(ORIGINAL_STABLE_STAKER).yieldStrategy(USDC)) != ysUsdcV2) {
            usdcIdleSwept = IERC20(USDC).balanceOf(ORIGINAL_STABLE_STAKER);
            IStakerOwnable(ORIGINAL_STABLE_STAKER).setYieldStrategy(USDC, IYieldStrategy(ysUsdcV2));
            usdcWired = true;
            console.log("  setYieldStrategy(USDC, ysUsdcV2) done; idle swept:", usdcIdleSwept);
        } else {
            console.log("  setYieldStrategy(USDC, ysUsdcV2) SKIPPED - already V2 (resume)");
        }
        console.log("");

        // ---- Step 3: wire migrator2 for the return leg ----
        // YS-09 resume guards: setMigrator is idempotent-by-value (re-setting the same migrator is
        // harmless) but we skip+log to keep the re-run loud and side-effect-free.
        console.log("=== Step 3: setMigrator(migrator2) on both stakers ===");
        if (ITempStakerOwnable(tempStakerAddr).migrator() != migrator2Addr) {
            ITempStakerOwnable(tempStakerAddr).setMigrator(migrator2Addr);
            console.log("  tempStaker.setMigrator(migrator2) done");
        } else {
            console.log("  tempStaker.setMigrator(migrator2) SKIPPED - already migrator2 (resume)");
        }
        if (IStakerOwnable(ORIGINAL_STABLE_STAKER).migrator() != migrator2Addr) {
            IStakerOwnable(ORIGINAL_STABLE_STAKER).setMigrator(migrator2Addr);
            console.log("  original.setMigrator(migrator2) done");
        } else {
            console.log("  original.setMigrator(migrator2) SKIPPED - already migrator2 (resume)");
        }
        console.log("");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- Post-assert (reads only, no more txs) ----
        console.log("=== Post-assert ===");

        // The setYieldStrategy idle sweep is SYNCHRONOUS: it deposited `*IdleSwept` into the V2 strategy,
        // crediting `vault.previewRedeem(sharesReceived)` as principal (fixed ERC4626YieldStrategy). So
        // principalOf must equal the swept amount minus only ERC4626 round-trip rounding dust — never more,
        // and never zero when a non-zero balance was swept. This deterministically proves the sweep fired
        // and folded the skim surplus into the V2 strategy as the unattributed principal buffer. (If the
        // skim found no surplus, *IdleSwept == 0 and principalOf == 0 — the checks still hold.)
        // The swept-amount invariant (principal == swept ± dust) only holds for a pool THIS run wired:
        // dolaIdleSwept is captured immediately before the sweep. On a resume-skip the sweep already
        // happened on a prior run, dolaIdleSwept reads 0, and principal is non-zero — so the swept-amount
        // check is gated on dolaWired/usdcWired. The strategy is V2 in either case (asserted below).
        uint256 dolaP = IYSView(ysDolaV2).principalOf(DOLA, ORIGINAL_STABLE_STAKER);
        if (dolaWired) {
            require(dolaP <= dolaIdleSwept, "Post-assert: DOLA principal > swept idle (over-credit)");
            require(dolaIdleSwept == 0 || dolaP > 0, "Post-assert: DOLA idle swept but principal == 0 (sweep failed)");
        }
        require(
            address(IStakerOwnable(ORIGINAL_STABLE_STAKER).yieldStrategy(DOLA)) == ysDolaV2,
            "Post-assert: original DOLA strategy != ysDolaV2"
        );
        console.log("  ysDolaV2.principalOf(DOLA, original): ", dolaP);

        uint256 usdcP = IYSView(ysUsdcV2).principalOf(USDC, ORIGINAL_STABLE_STAKER);
        if (usdcWired) {
            require(usdcP <= usdcIdleSwept, "Post-assert: USDC principal > swept idle (over-credit)");
            require(usdcIdleSwept == 0 || usdcP > 0, "Post-assert: USDC idle swept but principal == 0 (sweep failed)");
        }
        require(
            address(IStakerOwnable(ORIGINAL_STABLE_STAKER).yieldStrategy(USDC)) == ysUsdcV2,
            "Post-assert: original USDC strategy != ysUsdcV2"
        );
        console.log("  ysUsdcV2.principalOf(USDC, original): ", usdcP);

        (, , , uint256 dolaTotalStaked) = IStakerOwnable(ORIGINAL_STABLE_STAKER).poolInfo(DOLA);
        require(dolaTotalStaked == 0, "Post-assert: original DOLA totalStaked != 0 after reset");
        console.log("  original DOLA totalStaked: 0 OK");

        (, , , uint256 usdcTotalStaked) = IStakerOwnable(ORIGINAL_STABLE_STAKER).poolInfo(USDC);
        require(usdcTotalStaked == 0, "Post-assert: original USDC totalStaked != 0 after reset");
        console.log("  original USDC totalStaked: 0 OK");

        uint256 dolaBuffer = IYSView(ysDolaV2).setAsideBufferSize(ORIGINAL_STABLE_STAKER);
        address dolaRecipient = IYSView(ysDolaV2).setAsideBufferRecipient();
        console.log("  ysDolaV2 setAsideBufferSize:", dolaBuffer);
        console.log("  ysDolaV2 setAsideBufferRecipient:", dolaRecipient);

        uint256 usdcBuffer = IYSView(ysUsdcV2).setAsideBufferSize(ORIGINAL_STABLE_STAKER);
        address usdcRecipient = IYSView(ysUsdcV2).setAsideBufferRecipient();
        console.log("  ysUsdcV2 setAsideBufferSize:", usdcBuffer);
        console.log("  ysUsdcV2 setAsideBufferRecipient:", usdcRecipient);
        console.log("");

        _printSummary(ysDolaV2, ysUsdcV2, migrator2Addr);
    }

    function _printSummary(address ysDolaV2, address ysUsdcV2, address migrator2Addr) internal view {
        console.log("==========================================");
        console.log("  SUMMARY (story 060 step 3)");
        console.log("==========================================");
        console.log("ysDolaV2 wired to original: ", ysDolaV2);
        console.log("ysUsdcV2 wired to original: ", ysUsdcV2);
        console.log("migrator2 set on both:      ", migrator2Addr);
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
        } else {
            console.log("BROADCAST complete. Run patch-mainnet-addresses-ys-swap.js then proceed to Leg2Migration (step 4).");
        }
        console.log("==========================================");
    }
}
