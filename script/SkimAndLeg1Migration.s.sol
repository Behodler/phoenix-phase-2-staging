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
}

/// @dev Minimal interface for StableStakerMigrator (owner-facing).
interface IMinMigrator {
    function owner() external view returns (address);
    function initiateMigration(address token) external;
    function migrate(address token, address[] calldata users) external;
}

/// @dev Minimal interface for on-chain staker reads.
interface IStakerView {
    function migrator() external view returns (address);
    function stakerCount(address token) external view returns (uint256);
    function poolInfo(address token) external view returns (uint256, uint256, uint256, uint256);
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

        // ---- Step 1: skim all 3 old strategies ----
        console.log("=== Step 1: skim surplus from old strategies ===");
        dolaSkimmed = IOldYS(YS_DOLA_OLD).skimSurplus(DOLA, ORIGINAL_STABLE_STAKER);
        console.log("  DOLA skimmed:  ", dolaSkimmed);
        usdcSkimmed = IOldYS(YS_USDC_OLD).skimSurplus(USDC, ORIGINAL_STABLE_STAKER);
        console.log("  USDC skimmed:  ", usdcSkimmed);
        usdeSkimmed = IOldYS(YS_USDE).skimSurplus(USDe, ORIGINAL_STABLE_STAKER);
        console.log("  USDe skimmed:  ", usdeSkimmed);
        console.log("");

        // ---- Step 2: USDC approve + PhlimboV2 collectReward ----
        console.log("=== Step 2: PhlimboV2.collectReward(60 USDC) ===");
        IERC20(USDC).approve(PHLIMBO_V2, PHLIMBO_COLLECT_AMOUNT);
        IPhlimbo(PHLIMBO_V2).collectReward(PHLIMBO_COLLECT_AMOUNT);
        console.log("  collectReward called with", PHLIMBO_COLLECT_AMOUNT, "USDC");
        console.log("");

        // ---- Step 3: initiate migration for DOLA and USDC ----
        console.log("=== Step 3: initiateMigration (DOLA + USDC) ===");
        IMinMigrator(migrator1Addr).initiateMigration(DOLA);
        console.log("  initiateMigration(DOLA) called");
        IMinMigrator(migrator1Addr).initiateMigration(USDC);
        console.log("  initiateMigration(USDC) called");
        console.log("");

        // ---- Step 4: chunk loop from leg1-stakers.json ----
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
            console.log("  Skim amounts written to ys-swap-deployments.json");
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

    function _printSummary() internal view {
        console.log("==========================================");
        console.log("  SUMMARY (story 060 step 2)");
        console.log("==========================================");
        console.log("DOLA skimmed:  ", dolaSkimmed);
        console.log("USDC skimmed:  ", usdcSkimmed);
        console.log("USDe skimmed:  ", usdeSkimmed);
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
        } else {
            console.log("BROADCAST complete. Proceed to ResetAndRewire (step 3).");
        }
        console.log("==========================================");
    }
}
