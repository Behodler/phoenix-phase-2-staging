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
 * @notice Phase 1 of full USDC migration: initiates totalWithdrawal on the AutoFinance YieldStrategy.
 *
 *         This begins the 24-hour waiting period for the two-phase totalWithdrawal flow.
 *         After 24 hours, run FullMigrationExecute.s.sol to complete the migration.
 *
 *         Unlike the DOLA partial migration (which moves only 100 DOLA), this migrates
 *         ALL USDC from the AutoFinance YieldStrategy into a new ERC4626YieldStrategy.
 *
 *         Steps:
 *         1. Log pre-flight state (minter's principal and totalBalance on AutoFinance YS)
 *         2. Call totalWithdrawal(USDC, PHUSD_STABLE_MINTER) to initiate Phase 1
 *            (contract is unpaused, so no pause manipulation needed)
 *         3. Log confirmation and execution window timestamp
 *
 *         Note: Pausing of minter and AutoFinance YS happens in FullMigrationExecute,
 *         not here. The system remains unpaused during the 24h waiting period.
 */
contract FullMigrationInitiate is Script {
    // Mainnet addresses (from server/deployments/mainnet-addresses.ts)
    address constant AUTO_FINANCE_YS     = 0xf5F91E8240a0320CAC40b799B25F944a61090E5B;
    address constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant USDC                = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant OWNER               = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant GLOBAL_PAUSER       = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    function run() external {
        IYieldStrategyView autoFinanceYS = IYieldStrategyView(AUTO_FINANCE_YS);

        // --- Pre-flight logging ---
        uint256 principal = autoFinanceYS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 totalBalance = autoFinanceYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        address originalPauser = autoFinanceYS.pauser();

        console.log("\n=== FullMigrationInitiate (USDC) Pre-flight ===");
        console.log("AutoFinance YS:             ", AUTO_FINANCE_YS);
        console.log("Minter:                     ", PHUSD_STABLE_MINTER);
        console.log("Minter principal (wei):     ", principal);
        console.log("Minter principal (USDC):    ", principal / 1e6);
        console.log("Minter totalBalance (wei):  ", totalBalance);
        console.log("Minter totalBalance (USDC): ", totalBalance / 1e6);
        console.log("Current pauser:             ", originalPauser);

        if (totalBalance >= principal) {
            console.log("Yield (TVL - Principal):    ", totalBalance - principal);
        } else {
            console.log("Negative yield (gap):       ", principal - totalBalance);
        }

        require(principal > 0, "No principal to withdraw");

        vm.startBroadcast(OWNER);

        // Call totalWithdrawal to initiate Phase 1 (24h waiting period)
        // Contract is unpaused, so no pause manipulation needed here.
        // Pausing happens in FullMigrationExecute.
        autoFinanceYS.totalWithdrawal(USDC, PHUSD_STABLE_MINTER);

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
