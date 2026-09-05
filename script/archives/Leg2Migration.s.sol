// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title Leg2Migration
 * @notice Story 060 - Step 4: migrate users back from tempStaker → original staker
 *         (now wired with fresh V2 yield strategies).
 *
 *         Run AFTER ResetAndRewire (step 3) has been broadcast.
 *         Reads:
 *           - script/migration-inputs/ys-swap-deployments.json  (migrator2, tempStaker, ysDolaV2, ysUsdcV2)
 *           - script/migration-inputs/leg2-stakers.json          (staker counts + chunks)
 *
 *         Actions:
 *           1. migrator2.initiateMigration(DOLA)
 *           2. migrator2.initiateMigration(USDC)
 *           3. Chunk-loop migrate DOLA from leg2-stakers.json
 *           4. Chunk-loop migrate USDC from leg2-stakers.json
 *
 *         Post-assert:
 *           - tempStaker.stakerCount(DOLA) == 0 && stakerCount(USDC) == 0
 *           - original.stakerCount(DOLA) == leg2 DOLA count
 *           - original.stakerCount(USDC) == leg2 USDC count
 *           - ysDolaV2.principalOf(DOLA, original) > 0
 *           - ysUsdcV2.principalOf(USDC, original) > 0
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/Leg2Migration.s.sol:Leg2Migration \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/Leg2Migration.s.sol:Leg2Migration \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

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

/// @dev Minimal interface for on-chain staker reads + YS-09 resume guard.
interface IStakerView {
    function owner() external view returns (address);
    function migrator() external view returns (address);
    function stakerCount(address token) external view returns (uint256);
    function poolState(address token) external view returns (PoolState);
}

/// @dev Minimal interface for V2 strategy view.
interface IYSView {
    function principalOf(address token, address account) external view returns (uint256);
    function setAsideBufferSize(address client) external view returns (uint256);
    function setAsideBufferRecipient() external view returns (address);
}

contract Leg2Migration is Script {
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

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "Leg2Migration: wrong chain - expected mainnet (1)");
    }

    function _globalPreflight(
        address migrator2Addr,
        address tempStakerAddr,
        address ysDolaV2,
        address ysUsdcV2,
        uint256 leg2DolaCount,
        uint256 leg2UsdcCount
    ) internal view {
        require(migrator2Addr != address(0), "Preflight: migrator2 is zero");
        require(tempStakerAddr != address(0), "Preflight: tempStaker is zero");
        require(ysDolaV2 != address(0), "Preflight: ysDolaV2 is zero");
        require(ysUsdcV2 != address(0), "Preflight: ysUsdcV2 is zero");

        require(
            IMinMigrator(migrator2Addr).owner() == OWNER_ADDRESS,
            "Preflight: migrator2 owner != OWNER_ADDRESS"
        );

        // Verify migrator2 is set on both stakers.
        address origMigrator = IStakerView(ORIGINAL_STABLE_STAKER).migrator();
        require(
            origMigrator == migrator2Addr,
            "Preflight: migrator2 not set on original staker - re-run step 3"
        );
        address tempMigrator = IStakerView(tempStakerAddr).migrator();
        require(
            tempMigrator == migrator2Addr,
            "Preflight: migrator2 not set on tempStaker - re-run step 3"
        );

        // Verify V2 strategies are wired to original (setAsideBufferRecipient set).
        address dolaRecipient = IYSView(ysDolaV2).setAsideBufferRecipient();
        require(
            dolaRecipient != address(0),
            "Preflight: ysDolaV2 setAsideBufferRecipient is zero - re-run step 1"
        );
        address usdcRecipient = IYSView(ysUsdcV2).setAsideBufferRecipient();
        require(
            usdcRecipient != address(0),
            "Preflight: ysUsdcV2 setAsideBufferRecipient is zero - re-run step 1"
        );

        // Validate leg2 staker counts match tempStaker on-chain.
        uint256 onchainDolaCount = IStakerView(tempStakerAddr).stakerCount(DOLA);
        uint256 onchainUsdcCount = IStakerView(tempStakerAddr).stakerCount(USDC);
        require(
            leg2DolaCount == onchainDolaCount,
            "Preflight: stale DOLA staker count in leg2-stakers.json - re-run gather"
        );
        require(
            leg2UsdcCount == onchainUsdcCount,
            "Preflight: stale USDC staker count in leg2-stakers.json - re-run gather"
        );

        console.log("Preflight OK");
        console.log("  tempStaker DOLA stakers:", leg2DolaCount);
        console.log("  tempStaker USDC stakers:", leg2UsdcCount);
        console.log("  ysDolaV2 bufferRecipient:", dolaRecipient);
        console.log("  ysUsdcV2 bufferRecipient:", usdcRecipient);
    }

    function run() external {
        console.log("==========================================");
        console.log(" Leg2Migration (story 060, step 4)");
        console.log("==========================================");
        console.log("Chain ID:          ", block.chainid);
        console.log("Owner (ledger):    ", OWNER_ADDRESS);
        console.log("");

        // Read deployments JSON.
        string memory deploymentsRaw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address migrator2Addr  = vm.parseJsonAddress(deploymentsRaw, ".migrator2");
        address tempStakerAddr = vm.parseJsonAddress(deploymentsRaw, ".tempStaker");
        address ysDolaV2       = vm.parseJsonAddress(deploymentsRaw, ".ysDolaV2");
        address ysUsdcV2       = vm.parseJsonAddress(deploymentsRaw, ".ysUsdcV2");

        // Read leg2-stakers.json.
        string memory leg2Raw = vm.readFile("script/migration-inputs/leg2-stakers.json");
        uint256 dolaCount      = vm.parseJsonUint(leg2Raw, ".tokens.DOLA.count");
        uint256 usdcCount      = vm.parseJsonUint(leg2Raw, ".tokens.USDC.count");
        uint256 dolaChunkCount = vm.parseJsonUint(leg2Raw, ".tokens.DOLA.chunkCount");
        uint256 usdcChunkCount = vm.parseJsonUint(leg2Raw, ".tokens.USDC.chunkCount");

        console.log("migrator2:   ", migrator2Addr);
        console.log("tempStaker:  ", tempStakerAddr);
        console.log("ysDolaV2:    ", ysDolaV2);
        console.log("ysUsdcV2:    ", ysUsdcV2);
        console.log("leg2 DOLA count:", dolaCount, "chunkCount:", dolaChunkCount);
        console.log("leg2 USDC count:", usdcCount, "chunkCount:", usdcChunkCount);
        console.log("");

        _globalPreflight(migrator2Addr, tempStakerAddr, ysDolaV2, ysUsdcV2, dolaCount, usdcCount);

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

        // ---- Step 1: initiate migration on tempStaker ----
        // YS-09 resume guard: migrator2.initiateMigration engages terminal migration on the
        // tempStaker (migrator2's oldStaker). It requires PoolState.Active and reverts once
        // Migrating, so on a re-run we skip pools already engaged. Read poolState on the TEMP staker
        // (not original). The chunked migrate loop below is independently re-run-safe.
        console.log("=== Step 1: initiateMigration on tempStaker ===");
        if (IStakerView(tempStakerAddr).poolState(DOLA) == PoolState.Active) {
            IMinMigrator(migrator2Addr).initiateMigration(DOLA);
            console.log("  initiateMigration(DOLA) called");
        } else {
            console.log("  initiateMigration(DOLA) SKIPPED - already Migrating (resume)");
        }
        if (IStakerView(tempStakerAddr).poolState(USDC) == PoolState.Active) {
            IMinMigrator(migrator2Addr).initiateMigration(USDC);
            console.log("  initiateMigration(USDC) called");
        } else {
            console.log("  initiateMigration(USDC) SKIPPED - already Migrating (resume)");
        }
        console.log("");

        // ---- Step 2: chunk loop DOLA ----
        // YS-09 re-run-safe: batchMigrate returns 0 for already-migrated/empty positions and
        // StableStakerMigrator.migrate early-returns on a zero-total chunk, so re-passing a chunk
        // that completed on a prior run is a clean no-op. No per-chunk progress marker needed.
        console.log("=== Step 2: batch migrate DOLA from leg2-stakers.json ===");
        for (uint256 i = 0; i < dolaChunkCount; i++) {
            address[] memory chunk = vm.parseJsonAddressArray(
                leg2Raw,
                string(abi.encodePacked(".tokens.DOLA.chunks[", vm.toString(i), "]"))
            );
            IMinMigrator(migrator2Addr).migrate(DOLA, chunk);
            console.log("  DOLA chunk migrated users:", chunk.length);
        }
        console.log("");

        // ---- Step 3: chunk loop USDC ----
        console.log("=== Step 3: batch migrate USDC from leg2-stakers.json ===");
        for (uint256 i = 0; i < usdcChunkCount; i++) {
            address[] memory chunk = vm.parseJsonAddressArray(
                leg2Raw,
                string(abi.encodePacked(".tokens.USDC.chunks[", vm.toString(i), "]"))
            );
            IMinMigrator(migrator2Addr).migrate(USDC, chunk);
            console.log("  USDC chunk migrated users:", chunk.length);
        }
        console.log("");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- Post-assert ----
        console.log("=== Post-assert ===");

        uint256 tempDolaCount = IStakerView(tempStakerAddr).stakerCount(DOLA);
        uint256 tempUsdcCount = IStakerView(tempStakerAddr).stakerCount(USDC);
        require(tempDolaCount == 0, "Post-assert: tempStaker DOLA stakerCount != 0 after leg2");
        require(tempUsdcCount == 0, "Post-assert: tempStaker USDC stakerCount != 0 after leg2");
        console.log("  tempStaker DOLA stakerCount: 0 OK");
        console.log("  tempStaker USDC stakerCount: 0 OK");

        uint256 origDolaCount = IStakerView(ORIGINAL_STABLE_STAKER).stakerCount(DOLA);
        uint256 origUsdcCount = IStakerView(ORIGINAL_STABLE_STAKER).stakerCount(USDC);
        require(
            origDolaCount == dolaCount,
            "Post-assert: original DOLA stakerCount != expected after leg2"
        );
        require(
            origUsdcCount == usdcCount,
            "Post-assert: original USDC stakerCount != expected after leg2"
        );
        console.log("  original DOLA stakerCount:", origDolaCount, "OK");
        console.log("  original USDC stakerCount:", origUsdcCount, "OK");

        uint256 dolaP = IYSView(ysDolaV2).principalOf(DOLA, ORIGINAL_STABLE_STAKER);
        uint256 usdcP = IYSView(ysUsdcV2).principalOf(USDC, ORIGINAL_STABLE_STAKER);
        require(dolaP > 0, "Post-assert: ysDolaV2.principalOf(DOLA, original) == 0 after leg2");
        require(usdcP > 0, "Post-assert: ysUsdcV2.principalOf(USDC, original) == 0 after leg2");
        console.log("  ysDolaV2.principalOf(DOLA, original):", dolaP, "OK (> 0)");
        console.log("  ysUsdcV2.principalOf(USDC, original):", usdcP, "OK (> 0)");
        console.log("");

        _printSummary(dolaCount, usdcCount);
    }

    function _printSummary(uint256 dolaCount, uint256 usdcCount) internal view {
        console.log("==========================================");
        console.log("  SUMMARY (story 060 step 4)");
        console.log("==========================================");
        console.log("Migrated DOLA users back: ", dolaCount);
        console.log("Migrated USDC users back: ", usdcCount);
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
        } else {
            console.log("BROADCAST complete. Proceed to PostMigrationCleanup (step 5).");
        }
        console.log("==========================================");
    }
}
