// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IYieldStrategyView {
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
    function setPauser(address newPauser) external;
    function pauser() external view returns (address);
    function unpause() external;
    function pause() external;
    function totalWithdrawal(address token, address client) external;
}

/**
 * @title FullMigrationInitiate
 * @notice Phase 1 of full DOLA migration: initiates totalWithdrawal on the AutoPool YieldStrategy.
 *
 *         This begins the 24-hour waiting period for the two-phase totalWithdrawal flow.
 *         After 24 hours, run FullMigrationExecute.s.sol to complete the migration.
 *
 *         This script migrates ALL remaining DOLA from the AutoPool YieldStrategy into
 *         the existing ERC4626YieldStrategy (deployed by PartialMigrationExecute).
 *
 *         Prerequisites:
 *         - PartialMigrationExecute has been run (ERC4626 YS deployed and seeded)
 *         - ActivateERC4626YieldStrategy has been run (ERC4626 YS wired up on minter/accumulator)
 *         - AutoPool YS is paused (left paused by PartialMigrationExecute)
 *
 *         Steps:
 *         1. Log pre-flight state (minter's principal and totalBalance on AutoPool YS)
 *         2. Take pauser ownership, unpause AutoPool YS for totalWithdrawal
 *         3. Call totalWithdrawal(DOLA, PHUSD_STABLE_MINTER) to initiate Phase 1
 *         4. Restore pauser ownership (leave unpaused for 24h waiting period)
 *         5. Log confirmation and execution window timestamp
 *
 *         Note: The AutoPool YS is paused from PartialMigrationExecute, so this script
 *         must take pauser ownership and unpause before calling totalWithdrawal.
 *         The system is left unpaused during the 24h waiting period since the minter
 *         routes new DOLA deposits to ERC4626 YS (not AutoPool).
 */
contract FullMigrationInitiate is Script {
    // Mainnet addresses
    address constant AUTO_POOL_YS        = 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4;
    address constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant DOLA                = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant OWNER               = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant GLOBAL_PAUSER       = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    function run() external {
        IYieldStrategyView autoPoolYS = IYieldStrategyView(AUTO_POOL_YS);

        // --- Pre-flight logging ---
        uint256 principal = autoPoolYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 totalBalance = autoPoolYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        address originalPauser = autoPoolYS.pauser();

        console.log("\n=== FullMigrationInitiate (DOLA) Pre-flight ===");
        console.log("AutoPool YS:                ", AUTO_POOL_YS);
        console.log("Minter:                     ", PHUSD_STABLE_MINTER);
        console.log("Minter principal (wei):     ", principal);
        console.log("Minter principal (DOLA):    ", principal / 1e18);
        console.log("Minter totalBalance (wei):  ", totalBalance);
        console.log("Minter totalBalance (DOLA): ", totalBalance / 1e18);
        console.log("Current pauser:             ", originalPauser);

        if (totalBalance >= principal) {
            console.log("Yield (TVL - Principal):    ", totalBalance - principal);
        } else {
            console.log("Negative yield (gap):       ", principal - totalBalance);
        }

        require(principal > 0, "No principal to withdraw");

        vm.startBroadcast(OWNER);

        // AutoPool YS is paused (from PartialMigrationExecute).
        // Take pauser ownership and unpause for totalWithdrawal.
        autoPoolYS.setPauser(OWNER);
        autoPoolYS.unpause();

        // Call totalWithdrawal to initiate Phase 1 (24h waiting period)
        autoPoolYS.totalWithdrawal(DOLA, PHUSD_STABLE_MINTER);

        // Restore pauser. Leave unpaused during 24h wait — minter routes
        // new DOLA deposits to ERC4626 YS, so AutoPool is inactive.
        autoPoolYS.setPauser(originalPauser);

        vm.stopBroadcast();

        // --- Post-flight logging ---
        uint256 executionWindowOpens = block.timestamp + 24 hours;
        uint256 executionWindowCloses = block.timestamp + 72 hours;

        console.log("\n=== Phase 1 Initiated Successfully ===");
        console.log("Current timestamp:          ", block.timestamp);
        console.log("Execution window opens at:  ", executionWindowOpens);
        console.log("Execution window closes at: ", executionWindowCloses);
        console.log("");
        console.log("NEXT STEP: Run FullMigrationExecute.s.sol after the 24h waiting period.");
        console.log("           The execution window is 48 hours after the waiting period expires.");
        console.log("");
    }
}
