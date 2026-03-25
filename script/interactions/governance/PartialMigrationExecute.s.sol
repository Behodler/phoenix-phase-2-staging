// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";

interface IYieldStrategyPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
    function setClient(address client, bool _auth) external;
    function totalWithdrawal(address token, address client) external;
}

interface IMinterPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function noMintDeposit(address yieldStrategy, address inputToken, uint256 amount) external;
    function approveYS(address token, address yieldStrategy) external;
    function pauser() external view returns (address);
}

interface IPauser {
    function register(address pausableContract) external;
}

/**
 * @title PartialMigrationExecute
 * @notice Phase 2 of partial migration: executes the totalWithdrawal, re-deposits the bulk
 *         back into AutoPool, and seeds a new ERC4626YieldStrategy with 100 DOLA.
 *
 *         Prerequisites: PartialMigrationInitiate.s.sol must have been run >= 24h ago.
 *
 *         Steps:
 *         1. Log pre-flight state
 *         2. Unpause AutoPool YS and execute totalWithdrawal Phase 2 (funds go to owner)
 *         3. Re-deposit (totalReceived - 100 DOLA) back into AutoPool via noMintDeposit
 *         4. Deploy new ERC4626YieldStrategy wrapping autoDOLA vault
 *         5. Configure new YS (client, approveYS) and deposit 100 DOLA via noMintDeposit
 *         6. Set up pauser on new YS and register with global pauser
 *         7. Restore all pause states
 *         8. Log post-flight verification
 */
contract PartialMigrationExecute is Script {
    // Existing contracts
    address constant AUTO_POOL_YS        = 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4;
    address constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant GLOBAL_PAUSER       = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // Token and vault addresses
    address constant DOLA              = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant AUTO_DOLA_VAULT   = 0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d;

    // Accounts
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Migration amount: 100 DOLA
    uint256 constant MIGRATION_AMOUNT = 100 ether;

    function run() external {
        IYieldStrategyPausable autoPoolYS = IYieldStrategyPausable(AUTO_POOL_YS);
        IMinterPausable minter = IMinterPausable(PHUSD_STABLE_MINTER);

        // --- Pre-flight logging ---
        uint256 principalBefore = autoPoolYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 totalBalanceBefore = autoPoolYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        address originalMinterPauser = minter.pauser();

        console.log("\n=== PartialMigrationExecute Pre-flight ===");
        console.log("AutoPool YS:                ", AUTO_POOL_YS);
        console.log("Minter:                     ", PHUSD_STABLE_MINTER);
        console.log("Minter principal (wei):     ", principalBefore);
        console.log("Minter principal (DOLA):    ", principalBefore / 1e18);
        console.log("Minter totalBalance (wei):  ", totalBalanceBefore);
        console.log("Minter totalBalance (DOLA): ", totalBalanceBefore / 1e18);
        console.log("Migration amount:           ", MIGRATION_AMOUNT);
        console.log("Original minter pauser:     ", originalMinterPauser);

        vm.startBroadcast(OWNER);

        // ============================================================
        // PHASE 2: Execute totalWithdrawal (funds sent to owner)
        // ============================================================

        // 1. Temporarily swap pauser to owner on AutoPool YS and unpause
        autoPoolYS.setPauser(OWNER);
        autoPoolYS.unpause();

        // 2. Record owner's DOLA balance before withdrawal
        uint256 dolaBalanceBefore = IERC20(DOLA).balanceOf(OWNER);

        // 3. Execute totalWithdrawal Phase 2 (24h has passed, within execution window)
        autoPoolYS.totalWithdrawal(DOLA, PHUSD_STABLE_MINTER);

        // 4. Record total received
        uint256 totalReceived = IERC20(DOLA).balanceOf(OWNER) - dolaBalanceBefore;
        console.log("\nTotal DOLA received:        ", totalReceived);
        console.log("Total DOLA received (DOLA): ", totalReceived / 1e18);

        // 5. Sanity check: must have received more than migration amount
        require(totalReceived > MIGRATION_AMOUNT, "Received less DOLA than migration amount");

        // 6. Calculate re-deposit amount
        uint256 reDepositAmount = totalReceived - MIGRATION_AMOUNT;
        console.log("Re-deposit amount (wei):    ", reDepositAmount);
        console.log("Re-deposit amount (DOLA):   ", reDepositAmount / 1e18);

        // ============================================================
        // RE-DEPOSIT INTO AUTOPOOL
        // ============================================================

        // AutoPool YS is already unpaused from step 1 above (needed for deposit via noMintDeposit)

        // 7. Temporarily swap minter pauser to owner and unpause minter
        minter.setPauser(OWNER);
        minter.unpause();

        // 8. Approve DOLA to minter for re-deposit amount
        IERC20(DOLA).approve(PHUSD_STABLE_MINTER, reDepositAmount);

        // 9. Re-deposit into AutoPool via noMintDeposit
        minter.noMintDeposit(AUTO_POOL_YS, DOLA, reDepositAmount);
        console.log("Re-deposited into AutoPool: ", reDepositAmount / 1e18, "DOLA");

        // 10. Pause AutoPool YS and restore its pauser to global pauser
        autoPoolYS.pause();
        autoPoolYS.setPauser(GLOBAL_PAUSER);

        // ============================================================
        // DEPLOY AND CONFIGURE NEW ERC4626YieldStrategy
        // ============================================================

        // 11. Deploy new ERC4626YieldStrategy
        ERC4626YieldStrategy newYS = new ERC4626YieldStrategy(OWNER, DOLA, AUTO_DOLA_VAULT);
        address newYSAddr = address(newYS);
        console.log("\nNew ERC4626 YS deployed at: ", newYSAddr);

        // 12. Authorize minter as client on new YS
        IYieldStrategyPausable(newYSAddr).setClient(PHUSD_STABLE_MINTER, true);

        // 13. Approve new YS to pull DOLA from minter (minter is already unpaused from step 7)
        minter.approveYS(DOLA, newYSAddr);

        // 14. Approve DOLA to minter for migration amount
        IERC20(DOLA).approve(PHUSD_STABLE_MINTER, MIGRATION_AMOUNT);

        // 15. Deposit 100 DOLA into new YS via noMintDeposit
        minter.noMintDeposit(newYSAddr, DOLA, MIGRATION_AMOUNT);
        console.log("Deposited into new YS:      ", MIGRATION_AMOUNT / 1e18, "DOLA");

        // 16. Pause minter and restore its pauser to global pauser
        minter.pause();
        minter.setPauser(originalMinterPauser);

        // ============================================================
        // PAUSER SETUP FOR NEW YS
        // ============================================================

        // 17. Set pauser on new YS to owner, then pause, then set pauser to global pauser
        IYieldStrategyPausable(newYSAddr).setPauser(OWNER);
        IYieldStrategyPausable(newYSAddr).pause();
        IYieldStrategyPausable(newYSAddr).setPauser(GLOBAL_PAUSER);

        // 18. Register new YS with global pauser (requires newYS.pauser() == GLOBAL_PAUSER)
        IPauser(GLOBAL_PAUSER).register(newYSAddr);

        vm.stopBroadcast();

        // ============================================================
        // POST-FLIGHT VERIFICATION
        // ============================================================

        uint256 autoPoolPrincipalAfter = autoPoolYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 autoPoolTotalBalanceAfter = autoPoolYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 newYSPrincipal = IYieldStrategyPausable(newYSAddr).principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 newYSTotalBalance = IYieldStrategyPausable(newYSAddr).totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");
        console.log("--- AutoPool YS (after re-deposit) ---");
        console.log("Minter principal (wei):     ", autoPoolPrincipalAfter);
        console.log("Minter principal (DOLA):    ", autoPoolPrincipalAfter / 1e18);
        console.log("Minter totalBalance (wei):  ", autoPoolTotalBalanceAfter);
        console.log("Minter totalBalance (DOLA): ", autoPoolTotalBalanceAfter / 1e18);

        console.log("\n--- New ERC4626 YS ---");
        console.log("Deployed address:           ", newYSAddr);
        console.log("Minter principal (wei):     ", newYSPrincipal);
        console.log("Minter principal (DOLA):    ", newYSPrincipal / 1e18);
        console.log("Minter totalBalance (wei):  ", newYSTotalBalance);
        console.log("Minter totalBalance (DOLA): ", newYSTotalBalance / 1e18);

        // Assert AutoPool accounting is intact
        // The re-deposit amount should be close to (principalBefore - MIGRATION_AMOUNT)
        // but due to vault share price rounding, it may differ slightly
        uint256 expectedAutoPoolPrincipal = reDepositAmount;
        uint256 autoPoolDiff = autoPoolPrincipalAfter > expectedAutoPoolPrincipal
            ? autoPoolPrincipalAfter - expectedAutoPoolPrincipal
            : expectedAutoPoolPrincipal - autoPoolPrincipalAfter;
        require(autoPoolDiff <= 1 ether, "AutoPool principal deviates too much from re-deposit amount");

        // Assert new YS has ~100 DOLA deposited
        require(newYSPrincipal == MIGRATION_AMOUNT, "New YS principal should equal migration amount");
        uint256 newYSGap = newYSTotalBalance > MIGRATION_AMOUNT
            ? newYSTotalBalance - MIGRATION_AMOUNT
            : MIGRATION_AMOUNT - newYSTotalBalance;
        require(newYSGap <= 1 ether, "New YS totalBalance deviates too much from migration amount");

        console.log("\n=== VERIFICATION PASSED ===");
        console.log("AutoPool re-deposit intact. New ERC4626 YS seeded with 100 DOLA.");
        console.log("Update mainnet-addresses.ts with new ERC4626 YS:", newYSAddr);
        console.log("");
    }
}
