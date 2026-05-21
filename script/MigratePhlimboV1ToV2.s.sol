// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {PhlimboEA} from "@phlimbo-ea/Phlimbo.sol";
import {PhlimboV2} from "@phlimbo-ea/PhlimboV2.sol";
import {MigratorV1V2} from "@phlimbo-ea/MigratorV1V2.sol";

/// @title MigratePhlimboV1ToV2
/// @notice Single owner-signed Foundry broadcast performing the full PhlimboEA
///         (V1) -> PhlimboV2 user migration. Reads an off-chain snapshot
///         produced by `scripts/snapshot-phlimbo-v1-stakers.js` and orchestrates
///         the on-chain deploy + wire + fund + settle + migrate flow.
///
///         Lifecycle (mirrors story 049 § Required owner-call sequence):
///           1. Pause + drain V1 via `emergencyTransfer(OWNER)`
///              (single owner call -- emergencyTransfer internally calls
///              _pause(), so V1 is paused atomically with the drain).
///           2. Deploy PhlimboV2 with V1's depletionDuration.
///           3. Deploy MigratorV1V2(USDC, phUSD, PhlimboV2).
///           4. migrator.seedObligations(users, deposits, usdcOwed, phUSDOwed).
///           5. phUSD.setMinter(migrator, true)
///           6. phlimboV2.setMigrator(migrator)
///           7. Fund migrator: USDC totalUSDC + phUSD totalPHUSDDeposited
///              (the phUSD funding comes from the owner's recovered V1
///              balance from step 1; if recovered < required, the script
///              additionally mints the shortfall via phUSD.mint).
///           8. settleDebt(BATCH_SIZE) loop until iterator == -1.
///           9. migrateDeposits(BATCH_SIZE) loop until iterator == -1.
///          10. migrator.withdrawAll() to sweep any leftover.
///          11. phUSD.setMinter(migrator, false) (cleanup).
///          12. phlimboV2.setPauser(V1_PAUSER) (mirror V1 governance).
///
///         Snapshot JSON shape (consumed via vm.readFile + vm.parseJson):
///         see scripts/snapshot-phlimbo-v1-stakers.js header for full spec.
///         Key fields:
///           - phlimboV1:           address (must match V1_PHLIMBO_EA)
///           - blockNumber:         uint    (must be >= V1 pause block)
///           - users[]:             address[] (passed to seedObligations)
///           - deposits[]:          uint256[]
///           - usdcOwed[]:          uint256[]
///           - phUSDOwed[]:         uint256[]
///           - totalUSDC:           uint256 (for sanity invariant check)
///           - totalPHUSDDeposited: uint256 (for sanity + funding amount)
///           - totalPHUSDPending:   uint256 (for sanity check; not used to fund)
///
///         Modes:
///           PREVIEW_MODE=true  -> vm.startPrank(OWNER_ADDRESS), no broadcast
///           PREVIEW_MODE=false -> vm.startBroadcast() (ledger-signed)
///
///         Optional env:
///           SNAPSHOT_FILE   Path to snapshot JSON (default:
///                           scripts/snapshots/phlimbo-v1-snapshot-latest.json)
///           BATCH_SIZE      Users per settle/migrate batch (default 25)
///
///         Dry run:
///           PREVIEW_MODE=true forge script script/MigratePhlimboV1ToV2.s.sol \
///             --rpc-url $RPC_MAINNET --slow -vvv
///
///         Broadcast (ledger, index 46):
///           forge script script/MigratePhlimboV1ToV2.s.sol \
///             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
///             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
contract MigratePhlimboV1ToV2 is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    // From server/deployments/mainnet-addresses.ts (post-story-048).
    address public constant V1_PHLIMBO_EA = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;
    address public constant PHUSD         = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant USDC          = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // V1 owner = ledger key at HD path m/44'/60'/46'/0/0 (see DeployMainnet.s.sol:75).
    // Same key signs this script's broadcast.
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // V1 pauser = global Pauser contract (mainnet-addresses.ts:26). After
    // migration we set the V2 pauser to the same address to mirror governance.
    // NOTE: registering V2 with the Pauser contract requires Pauser.register()
    // which is owner-gated and validates the pauser() callback. That step is
    // OUT OF SCOPE for this script -- the Pauser is a separately owned contract
    // and registration is a downstream action. We just point V2 at it.
    address public constant V1_PAUSER     = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // ==========================================
    //              SCRIPT CONFIG
    // ==========================================

    /// @dev Default batch size for settleDebt / migrateDeposits.
    uint256 public constant DEFAULT_BATCH_SIZE = 25;

    /// @dev Default snapshot path (overridable via SNAPSHOT_FILE env).
    string public constant DEFAULT_SNAPSHOT_FILE = "scripts/snapshots/phlimbo-v1-snapshot-latest.json";

    // ==========================================
    //         RUNTIME-CAPTURED STATE
    // ==========================================

    PhlimboEA public v1;
    PhlimboV2 public v2;
    MigratorV1V2 public migrator;

    // Snapshot fields.
    address[] public snapUsers;
    uint256[] public snapDeposits;
    uint256[] public snapUSDC;
    uint256[] public snapPHUSD;
    uint256 public snapTotalUSDC;
    uint256 public snapTotalPHUSDDeposited;
    uint256 public snapTotalPHUSDPending;
    uint256 public snapBlockNumber;
    address public snapPhlimboV1;

    // V1 state captured pre-broadcast.
    uint256 public v1DepletionDuration;
    uint256 public v1TotalStakedPre;
    uint256 public ownerPhUSDBalanceAfterDrain;

    // Tuning.
    uint256 public batchSize;
    string public snapshotFile;

    bool internal isPreview;

    // ==========================================
    //                   ENTRY
    // ==========================================

    function setUp() public {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");
    }

    function run() external {
        console.log("==================================================");
        console.log(" MigratePhlimboV1ToV2 -- V1 stakers -> V2 silent ");
        console.log("==================================================");
        console.log("Chain id:                ", block.chainid);
        console.log("V1 PhlimboEA:            ", V1_PHLIMBO_EA);
        console.log("phUSD:                   ", PHUSD);
        console.log("USDC:                    ", USDC);
        console.log("Owner (ledger signer):   ", OWNER_ADDRESS);
        console.log("V1 Pauser (mirrored):    ", V1_PAUSER);

        isPreview = vm.envOr("PREVIEW_MODE", false);
        batchSize = vm.envOr("BATCH_SIZE", DEFAULT_BATCH_SIZE);
        snapshotFile = vm.envOr("SNAPSHOT_FILE", DEFAULT_SNAPSHOT_FILE);
        console.log("PREVIEW_MODE:            ", isPreview);
        console.log("BATCH_SIZE:              ", batchSize);
        console.log("SNAPSHOT_FILE:           ", snapshotFile);

        // ===== Pre-flight (no broadcast) =====
        _loadSnapshot();
        _preFlightV1Checks();

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE -- impersonating owner via prank ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        _step1_pauseAndDrainV1();
        _step2_deployV2();
        _step3_deployMigrator();
        _step4_seedObligations();
        _step5_grantPhUSDMint();
        _step6_setMigratorOnV2();
        _step7_fundMigrator();
        _step8_settleDebtLoop();
        _step9_migrateDepositsLoop();
        _step10_withdrawAll();
        _step11_revokePhUSDMint();
        _step12_mirrorPauserOnV2();
        _step13_postStateLog();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("");
        console.log("==================================================");
        console.log(" Migration complete (in-memory only if preview)   ");
        console.log("==================================================");
    }

    // ==========================================
    // Pre-flight: load snapshot from JSON
    // ==========================================

    function _loadSnapshot() internal {
        console.log("");
        console.log("=== Load snapshot from disk ===");
        string memory raw = vm.readFile(snapshotFile);

        // Parse fields. vm.parseJson* return uniform types; we use the
        // dedicated array helpers for the four parallel arrays and individual
        // helpers for scalars.
        snapPhlimboV1            = vm.parseJsonAddress(raw, ".phlimboV1");
        snapBlockNumber          = vm.parseJsonUint(raw, ".blockNumber");
        snapUsers                = vm.parseJsonAddressArray(raw, ".users");
        snapDeposits             = vm.parseJsonUintArray(raw, ".deposits");
        snapUSDC                 = vm.parseJsonUintArray(raw, ".usdcOwed");
        snapPHUSD                = vm.parseJsonUintArray(raw, ".phUSDOwed");
        snapTotalUSDC            = vm.parseJsonUint(raw, ".totalUSDC");
        snapTotalPHUSDDeposited  = vm.parseJsonUint(raw, ".totalPHUSDDeposited");
        snapTotalPHUSDPending    = vm.parseJsonUint(raw, ".totalPHUSDPending");

        console.log("snapPhlimboV1:           ", snapPhlimboV1);
        console.log("snapBlockNumber:         ", snapBlockNumber);
        console.log("snapUsers.length:        ", snapUsers.length);
        console.log("snapDeposits.length:     ", snapDeposits.length);
        console.log("snapUSDC.length:         ", snapUSDC.length);
        console.log("snapPHUSD.length:        ", snapPHUSD.length);
        console.log("snapTotalUSDC:           ", snapTotalUSDC);
        console.log("snapTotalPHUSDDeposited: ", snapTotalPHUSDDeposited);
        console.log("snapTotalPHUSDPending:   ", snapTotalPHUSDPending);

        require(snapUsers.length > 0, "snapshot has zero users");
        require(snapDeposits.length == snapUsers.length, "deposits length mismatch");
        require(snapUSDC.length == snapUsers.length, "usdcOwed length mismatch");
        require(snapPHUSD.length == snapUsers.length, "phUSDOwed length mismatch");
        require(snapPhlimboV1 == V1_PHLIMBO_EA, "snapshot V1 address does not match constant");

        // Sanity: in-script sums match snapshot-reported totals.
        uint256 sumUSDC;
        uint256 sumDep;
        uint256 sumPHUSDpending;
        for (uint256 i = 0; i < snapUsers.length; i++) {
            sumUSDC += snapUSDC[i];
            sumDep  += snapDeposits[i];
            sumPHUSDpending += snapPHUSD[i];
        }
        require(sumUSDC == snapTotalUSDC, "sum(usdcOwed) != totalUSDC");
        require(sumDep  == snapTotalPHUSDDeposited, "sum(deposits) != totalPHUSDDeposited");
        require(sumPHUSDpending == snapTotalPHUSDPending, "sum(phUSDOwed) != totalPHUSDPending");
        console.log("OK -- per-row sums match reported totals");
    }

    // ==========================================
    // Pre-flight: V1 state checks
    // ==========================================

    function _preFlightV1Checks() internal {
        console.log("");
        console.log("=== Pre-flight V1 state checks ===");

        v1 = PhlimboEA(V1_PHLIMBO_EA);
        address ownerOnChain = v1.owner();
        v1DepletionDuration = v1.depletionDuration();
        v1TotalStakedPre    = v1.totalStaked();

        console.log("v1.owner():            ", ownerOnChain);
        console.log("v1.depletionDuration():", v1DepletionDuration);
        console.log("v1.totalStaked():      ", v1TotalStakedPre);

        require(ownerOnChain == OWNER_ADDRESS, "V1 owner != OWNER_ADDRESS constant");
        require(v1DepletionDuration > 0, "V1 depletionDuration must be > 0");

        // Snapshot block sanity: blockNumber must not be in the future and
        // must be >= the V1 pause/drain block. We can't know the pause block
        // here (single-script flow pauses below), but we can require the
        // snapshot is reasonably recent vs the current head -- if the
        // snapshot is older than 24h on mainnet (~7200 blocks) we warn.
        uint256 head = block.number;
        if (snapBlockNumber < head && head - snapBlockNumber > 7200) {
            console.log("WARNING: snapshot is more than ~24h old:");
            console.log("  snapBlockNumber:", snapBlockNumber);
            console.log("  head:          ", head);
            console.log("  delta blocks:  ", head - snapBlockNumber);
            console.log("  Consider regenerating the snapshot post-pause for accuracy.");
        }

        // Sum-of-deposits cross-check: snapshot totalPHUSDDeposited must
        // equal V1.totalStaked at snapshot block. If V1 has had no
        // stake/withdraw activity since the snapshot, this still holds at
        // current head. We log and warn rather than revert -- the migrator
        // contract enforces the strict balance invariant at funding time.
        if (snapTotalPHUSDDeposited != v1TotalStakedPre) {
            console.log("WARNING: snapshot totalPHUSDDeposited != v1.totalStaked()");
            console.log("  snapshot:      ", snapTotalPHUSDDeposited);
            console.log("  v1 totalStaked:", v1TotalStakedPre);
            console.log("  This is expected if V1 had stake/withdraw activity between");
            console.log("  the snapshot block and current head. After step 1 pauses V1,");
            console.log("  v1.totalStaked() will be unchanged; the snapshot must match");
            console.log("  the post-pause totalStaked for the migration to be correct.");
        }
    }

    // ==========================================
    // Step 1: pause + drain V1
    // ==========================================

    function _step1_pauseAndDrainV1() internal {
        console.log("");
        console.log("=== Step 1: emergencyTransfer(owner) on V1 (drains + pauses) ===");

        uint256 ownerPhUSDBefore = IERC20Minimal(PHUSD).balanceOf(OWNER_ADDRESS);
        uint256 ownerUSDCBefore  = IERC20Minimal(USDC).balanceOf(OWNER_ADDRESS);
        uint256 v1PhUSDBefore    = IERC20Minimal(PHUSD).balanceOf(V1_PHLIMBO_EA);
        uint256 v1USDCBefore     = IERC20Minimal(USDC).balanceOf(V1_PHLIMBO_EA);

        console.log("Pre-drain owner phUSD: ", ownerPhUSDBefore);
        console.log("Pre-drain owner USDC:  ", ownerUSDCBefore);
        console.log("Pre-drain V1 phUSD:    ", v1PhUSDBefore);
        console.log("Pre-drain V1 USDC:     ", v1USDCBefore);

        v1.emergencyTransfer(OWNER_ADDRESS);

        uint256 ownerPhUSDAfter = IERC20Minimal(PHUSD).balanceOf(OWNER_ADDRESS);
        uint256 ownerUSDCAfter  = IERC20Minimal(USDC).balanceOf(OWNER_ADDRESS);
        ownerPhUSDBalanceAfterDrain = ownerPhUSDAfter;

        console.log("Post-drain owner phUSD:", ownerPhUSDAfter);
        console.log("Post-drain owner USDC: ", ownerUSDCAfter);
        console.log("V1 paused:             ", v1.paused());

        // Sanity: owner received the V1 phUSD + USDC balances.
        require(
            ownerPhUSDAfter == ownerPhUSDBefore + v1PhUSDBefore,
            "owner phUSD delta != V1 phUSD drained"
        );
        require(
            ownerUSDCAfter == ownerUSDCBefore + v1USDCBefore,
            "owner USDC delta != V1 USDC drained"
        );
        require(v1.paused(), "V1 not paused after emergencyTransfer");

        // Recovered phUSD must cover the migrator's phUSD funding need
        // (sum of deposits). Per story Implementation Notes: V1 holds
        // exactly sum(deposits) phUSD at any point because every stake/
        // withdraw matches user.amount one-for-one. After drain the owner
        // therefore holds exactly enough phUSD to re-stake into V2 via the
        // migrator. Pending phUSD rewards are MINTED by the migrator (not
        // transferred) so no extra phUSD is needed for the pending side.
        require(
            ownerPhUSDAfter >= snapTotalPHUSDDeposited,
            "Recovered phUSD < snap totalPHUSDDeposited -- cannot fund migrator"
        );
    }

    // ==========================================
    // Step 2: deploy PhlimboV2
    // ==========================================

    function _step2_deployV2() internal {
        console.log("");
        console.log("=== Step 2: deploy PhlimboV2 ===");
        // Mirror V1's depletionDuration so the rate semantics are continuous
        // across the migration. The V2 owner is whoever broadcasts this
        // script (OWNER_ADDRESS) per the Ownable(msg.sender) constructor.
        v2 = new PhlimboV2(PHUSD, USDC, v1DepletionDuration);
        console.log("PhlimboV2 deployed at:", address(v2));
        console.log("  phUSD:             ", PHUSD);
        console.log("  rewardToken (USDC):", USDC);
        console.log("  depletionDuration: ", v1DepletionDuration);
    }

    // ==========================================
    // Step 3: deploy MigratorV1V2
    // ==========================================

    function _step3_deployMigrator() internal {
        console.log("");
        console.log("=== Step 3: deploy MigratorV1V2 ===");
        migrator = new MigratorV1V2(USDC, PHUSD, address(v2));
        console.log("MigratorV1V2 deployed at:", address(migrator));
    }

    // ==========================================
    // Step 4: seedObligations
    // ==========================================

    function _step4_seedObligations() internal {
        console.log("");
        console.log("=== Step 4: migrator.seedObligations(...) ===");
        migrator.seedObligations(snapUsers, snapDeposits, snapUSDC, snapPHUSD);

        // Post-seed invariants: totals returned by the migrator must equal
        // the snapshot totals exactly.
        require(migrator.totalUSDC() == snapTotalUSDC, "migrator.totalUSDC mismatch");
        require(migrator.totalPHUSD_deposited() == snapTotalPHUSDDeposited, "migrator.totalPHUSD_deposited mismatch");
        require(migrator.totalPHUSD_pending() == snapTotalPHUSDPending, "migrator.totalPHUSD_pending mismatch");
        require(migrator.userCount() == snapUsers.length, "migrator.userCount mismatch");
        console.log("Post-seed totals match snapshot. userCount:", migrator.userCount());
    }

    // ==========================================
    // Step 5: grant phUSD mint role to migrator
    // ==========================================

    function _step5_grantPhUSDMint() internal {
        console.log("");
        console.log("=== Step 5: phUSD.setMinter(migrator, true) ===");
        IFlaxMinimal(PHUSD).setMinter(address(migrator), true);
    }

    // ==========================================
    // Step 6: set migrator role on V2
    // ==========================================

    function _step6_setMigratorOnV2() internal {
        console.log("");
        console.log("=== Step 6: phlimboV2.setMigrator(migrator) ===");
        v2.setMigrator(address(migrator));
        require(v2.migrator() == address(migrator), "v2.migrator != migrator");
    }

    // ==========================================
    // Step 7: fund migrator atomically with USDC + phUSD
    // ==========================================

    function _step7_fundMigrator() internal {
        console.log("");
        console.log("=== Step 7: fund migrator (USDC + phUSD) ===");

        uint256 needUSDC = snapTotalUSDC;
        uint256 needPHUSD = snapTotalPHUSDDeposited;

        uint256 ownerUSDC = IERC20Minimal(USDC).balanceOf(OWNER_ADDRESS);
        uint256 ownerPHUSD = IERC20Minimal(PHUSD).balanceOf(OWNER_ADDRESS);

        console.log("Need USDC:     ", needUSDC);
        console.log("Need phUSD:    ", needPHUSD);
        console.log("Owner USDC:    ", ownerUSDC);
        console.log("Owner phUSD:   ", ownerPHUSD);

        require(ownerUSDC >= needUSDC, "Owner USDC insufficient to fund migrator");
        // phUSD recovered in step 1 plus any pre-existing owner balance
        // must cover the migrator's deposit-float requirement. If short
        // (should not happen given V1 invariant), mint the shortfall via
        // the migrator's just-granted mint role -- but route the mint to
        // OWNER first, then transfer, so the migrator balance lands as a
        // SafeERC20.transfer (not a mint-to-this) -- this preserves the
        // settleDebt() == strict-equality invariant.
        if (ownerPHUSD < needPHUSD) {
            uint256 shortfall = needPHUSD - ownerPHUSD;
            console.log("phUSD shortfall (will mint to owner):", shortfall);
            IFlaxMinimal(PHUSD).mint(OWNER_ADDRESS, shortfall);
            ownerPHUSD = IERC20Minimal(PHUSD).balanceOf(OWNER_ADDRESS);
            require(ownerPHUSD >= needPHUSD, "phUSD shortfall mint failed");
        }

        // Transfer EXACT amounts -- not more, not less.
        require(
            IERC20Minimal(USDC).transfer(address(migrator), needUSDC),
            "USDC transfer to migrator failed"
        );
        require(
            IERC20Minimal(PHUSD).transfer(address(migrator), needPHUSD),
            "phUSD transfer to migrator failed"
        );

        // Strict equality invariants the migrator will re-check internally.
        require(
            IERC20Minimal(USDC).balanceOf(address(migrator)) == migrator.totalUSDC(),
            "migrator USDC balance != totalUSDC"
        );
        require(
            IERC20Minimal(PHUSD).balanceOf(address(migrator)) == migrator.totalPHUSD_deposited(),
            "migrator phUSD balance != totalPHUSD_deposited"
        );
        console.log("Funding OK -- balances match migrator totals exactly.");
    }

    // ==========================================
    // Step 8: settleDebt loop
    // ==========================================

    function _step8_settleDebtLoop() internal {
        console.log("");
        console.log("=== Step 8: settleDebt loop ===");
        uint256 i = 0;
        while (migrator.settleIterator() >= 0) {
            i++;
            console.log("  iter", i, "calling settleDebt(BATCH_SIZE)...");
            migrator.settleDebt(batchSize);
            _logIterator("    settleIterator:    ", migrator.settleIterator());
            console.log("    totalUSDC left:    ", migrator.totalUSDC());
            console.log("    totalPHUSD_pending:", migrator.totalPHUSD_pending());

            // Safety: hard cap to avoid runaway loops if something is wrong.
            require(i < 1000, "settleDebt loop exceeded 1000 iterations -- aborting");
        }
        require(migrator.settleIterator() == -1, "settleDebt did not complete");
        require(migrator.totalUSDC() == 0, "totalUSDC != 0 after settle");
        require(migrator.totalPHUSD_pending() == 0, "totalPHUSD_pending != 0 after settle");
        console.log("settleDebt complete: iterator == -1, all USDC distributed, all phUSD pending minted.");
    }

    // ==========================================
    // Step 9: migrateDeposits loop
    // ==========================================

    function _step9_migrateDepositsLoop() internal {
        console.log("");
        console.log("=== Step 9: migrateDeposits loop ===");
        uint256 i = 0;
        while (migrator.migrateIterator() >= 0) {
            i++;
            console.log("  iter", i, "calling migrateDeposits(BATCH_SIZE)...");
            migrator.migrateDeposits(batchSize);
            _logIterator("    migrateIterator:        ", migrator.migrateIterator());
            console.log("    totalPHUSD_deposited:   ", migrator.totalPHUSD_deposited());

            require(i < 1000, "migrateDeposits loop exceeded 1000 iterations -- aborting");
        }
        require(migrator.migrateIterator() == -1, "migrateDeposits did not complete");
        require(migrator.totalPHUSD_deposited() == 0, "totalPHUSD_deposited != 0 after migrate");
        console.log("migrateDeposits complete: iterator == -1, all V1 deposits re-staked into V2.");
    }

    // ==========================================
    // Step 10: withdrawAll (sweep leftover)
    // ==========================================

    function _step10_withdrawAll() internal {
        console.log("");
        console.log("=== Step 10: migrator.withdrawAll() ===");
        uint256 migUSDC = IERC20Minimal(USDC).balanceOf(address(migrator));
        uint256 migPHUSD = IERC20Minimal(PHUSD).balanceOf(address(migrator));
        console.log("Pre-sweep migrator USDC:", migUSDC);
        console.log("Pre-sweep migrator phUSD:", migPHUSD);
        migrator.withdrawAll();
        require(IERC20Minimal(USDC).balanceOf(address(migrator)) == 0, "migrator USDC not swept");
        require(IERC20Minimal(PHUSD).balanceOf(address(migrator)) == 0, "migrator phUSD not swept");
        console.log("Migrator drained.");
    }

    // ==========================================
    // Step 11: revoke phUSD mint role
    // ==========================================

    function _step11_revokePhUSDMint() internal {
        console.log("");
        console.log("=== Step 11: phUSD.setMinter(migrator, false) ===");
        IFlaxMinimal(PHUSD).setMinter(address(migrator), false);
    }

    // ==========================================
    // Step 12: mirror V1 pauser on V2
    // ==========================================

    function _step12_mirrorPauserOnV2() internal {
        console.log("");
        console.log("=== Step 12: phlimboV2.setPauser(V1_PAUSER) ===");
        v2.setPauser(V1_PAUSER);
        require(v2.pauser() == V1_PAUSER, "v2.pauser != V1_PAUSER after setPauser");
        console.log("NOTE: Pauser.register(v2) must be performed separately by Pauser.owner.");
    }

    // ==========================================
    // Step 13: post-state log + invariants
    // ==========================================

    function _step13_postStateLog() internal view {
        console.log("");
        console.log("=== Step 13: post-state log + invariants ===");

        // V2 should now hold exactly the original V1 totalStaked in phUSD.
        uint256 v2PhUSDHeld = IERC20Minimal(PHUSD).balanceOf(address(v2));
        uint256 v2TotalStaked = v2.totalStaked();
        console.log("V2 phUSD balance:        ", v2PhUSDHeld);
        console.log("V2 totalStaked:          ", v2TotalStaked);
        console.log("V2 migrator:             ", v2.migrator());
        console.log("V2 pauser:               ", v2.pauser());
        console.log("V2 depletionDuration:    ", v2.depletionDuration());
        _logIterator("migrator settleIterator: ", migrator.settleIterator());
        _logIterator("migrator migrateIterator:", migrator.migrateIterator());

        require(v2TotalStaked == snapTotalPHUSDDeposited, "v2.totalStaked != snap totalPHUSDDeposited");
        require(v2PhUSDHeld   == snapTotalPHUSDDeposited, "v2 phUSD balance != snap totalPHUSDDeposited");
        require(v2.migrator() == address(migrator),       "v2.migrator != migrator (sanity)");
        require(v2.pauser()   == V1_PAUSER,               "v2.pauser != V1_PAUSER");

        console.log("");
        console.log("--- For patcher / human reference ---");
        console.log("PhlimboV2:               ", address(v2));
        console.log("MigratorV1V2:            ", address(migrator));
        console.log("Snapshot block:          ", snapBlockNumber);
        console.log("Migrated user count:     ", snapUsers.length);
    }

    // ==========================================
    //          INTERNAL HELPERS
    // ==========================================

    /// @dev Pretty-print an int256 iterator that terminates at -1. console.log
    ///      lacks a native int256 sink, so for the sentinel we substitute a
    ///      readable string; for non-negative values we print the uint cast.
    function _logIterator(string memory label, int256 x) internal pure {
        if (x < 0) {
            console.log(label, "-1 (DONE)");
        } else {
            console.log(label, uint256(x));
        }
    }
}

// ==========================================
//   MINIMAL EXTERNAL TYPE INTERFACES
// ==========================================

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev IFlax surface used by this script. The phUSD token implements IFlax
///      (see lib/phlimbo-ea/src/IFlax.sol).
interface IFlaxMinimal {
    function setMinter(address minter, bool canMint) external;
    function mint(address recipient, uint256 amount) external;
}
