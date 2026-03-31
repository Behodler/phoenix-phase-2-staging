// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IYieldStrategyPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
    function paused() external view returns (bool);
    function setClient(address client, bool _auth) external;
    function totalWithdrawal(address token, address client) external;
}

interface IMinterPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function noMintDeposit(address yieldStrategy, address inputToken, uint256 amount) external;
    function approveYS(address token, address yieldStrategy) external;
    function paused() external view returns (bool);
    function pauser() external view returns (address);
}

interface IAccumulatorPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function pauser() external view returns (address);
}

/**
 * @title FullMigrationExecute
 * @notice Phase 2 of full DOLA migration: executes the totalWithdrawal and deposits
 *         ALL funds into the existing ERC4626YieldStrategy.
 *
 *         Unlike the partial migration (which kept the bulk in AutoPool and seeded
 *         the new YS with only 100 DOLA), this moves ALL remaining DOLA out of the
 *         AutoPool YieldStrategy and into the ERC4626YieldStrategy. The AutoPool YS
 *         is left paused and empty.
 *
 *         The ERC4626YieldStrategy is NOT deployed by this script — it was already
 *         deployed by PartialMigrationExecute and wired up by ActivateERC4626YieldStrategy.
 *
 *         Prerequisites:
 *         - PartialMigrationExecute has been run (ERC4626 YS deployed, configured, seeded)
 *         - ActivateERC4626YieldStrategy has been run (ERC4626 YS wired on minter/accumulator)
 *         - FullMigrationInitiate.s.sol must have been run >= 24h ago
 *         - AutoPool YS should be unpaused (left unpaused by FullMigrationInitiate)
 *
 *         Steps:
 *         1. Log pre-flight state
 *         2. Pause minter, AutoPool YS, and accumulator (take ownership of pausers temporarily)
 *         3. Unpause AutoPool YS and execute totalWithdrawal Phase 2 (funds go to owner)
 *         4. Pause AutoPool YS permanently (now empty, retired)
 *         5. Unpause ERC4626 YS for deposit
 *         6. Deposit ALL received DOLA into ERC4626 YS via noMintDeposit
 *         7. Re-pause ERC4626 YS, restore all pausers
 *         8. Restore minter and accumulator
 *         9. Log post-flight verification
 */
contract FullMigrationExecute is Script {
    // Existing contracts
    address constant AUTO_POOL_YS                = 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4;
    address constant PHUSD_STABLE_MINTER         = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant STABLE_YIELD_ACCUMULATOR    = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant GLOBAL_PAUSER               = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // Token address
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;

    // Accounts
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // TODO: Fill from PartialMigrationExecute broadcast output.
    // Run `mainnet:partial-migrate-execute` and look for console log:
    // "New ERC4626 YS deployed at: <address>"
    address constant ERC4626_YS = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;

    function run() external {
        // --- Guard: ERC4626_YS must be set before running ---
        require(ERC4626_YS != address(0), "ERC4626_YS not set: fill address from PartialMigrationExecute broadcast output");

        IYieldStrategyPausable autoPoolYS = IYieldStrategyPausable(AUTO_POOL_YS);
        IYieldStrategyPausable erc4626YS = IYieldStrategyPausable(ERC4626_YS);
        IMinterPausable minter = IMinterPausable(PHUSD_STABLE_MINTER);
        IAccumulatorPausable accumulator = IAccumulatorPausable(STABLE_YIELD_ACCUMULATOR);

        // --- Pre-flight logging ---
        uint256 principalBefore = autoPoolYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 totalBalanceBefore = autoPoolYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 erc4626PrincipalBefore = erc4626YS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        address originalMinterPauser = minter.pauser();
        address originalAutoPoolPauser = autoPoolYS.pauser();
        address originalAccumulatorPauser = accumulator.pauser();
        address originalERC4626Pauser = erc4626YS.pauser();

        console.log("\n=== FullMigrationExecute (DOLA) Pre-flight ===");
        console.log("AutoPool YS:                ", AUTO_POOL_YS);
        console.log("ERC4626 YS:                 ", ERC4626_YS);
        console.log("Minter:                     ", PHUSD_STABLE_MINTER);
        console.log("Accumulator:                ", STABLE_YIELD_ACCUMULATOR);
        console.log("AutoPool principal (wei):   ", principalBefore);
        console.log("AutoPool principal (DOLA):  ", principalBefore / 1e18);
        console.log("AutoPool totalBal (wei):    ", totalBalanceBefore);
        console.log("AutoPool totalBal (DOLA):   ", totalBalanceBefore / 1e18);
        console.log("ERC4626 principal (DOLA):   ", erc4626PrincipalBefore / 1e18);
        console.log("Original minter pauser:     ", originalMinterPauser);
        console.log("Original AutoPool pauser:   ", originalAutoPoolPauser);
        console.log("Original accumulator pauser:", originalAccumulatorPauser);
        console.log("Original ERC4626 pauser:    ", originalERC4626Pauser);

        vm.startBroadcast(OWNER);

        // ============================================================
        // PAUSE MINTER, AUTOPOOL YS, AND ACCUMULATOR
        // ============================================================

        // AutoPool YS was left unpaused by FullMigrationInitiate.
        autoPoolYS.setPauser(OWNER);
        autoPoolYS.pause();

        minter.setPauser(OWNER);
        minter.pause();

        accumulator.setPauser(OWNER);
        accumulator.pause();

        // ============================================================
        // PHASE 2: Execute totalWithdrawal on AutoPool (funds sent to owner)
        // ============================================================

        // Unpause AutoPool YS for totalWithdrawal (requires whenNotPaused)
        if (autoPoolYS.paused()) autoPoolYS.unpause();

        // Record owner's DOLA balance before withdrawal
        uint256 dolaBalanceBefore = IERC20(DOLA).balanceOf(OWNER);

        // Execute totalWithdrawal Phase 2 (24h has passed, within execution window)
        autoPoolYS.totalWithdrawal(DOLA, PHUSD_STABLE_MINTER);

        // Record total received
        uint256 totalReceived = IERC20(DOLA).balanceOf(OWNER) - dolaBalanceBefore;
        console.log("\nTotal DOLA received:        ", totalReceived);
        console.log("Total DOLA received (DOLA): ", totalReceived / 1e18);

        require(totalReceived > 0, "No DOLA received from withdrawal");

        // Restore AutoPool YS pauser
        autoPoolYS.setPauser(originalAutoPoolPauser);

        // ============================================================
        // DEPOSIT ALL DOLA INTO EXISTING ERC4626 YS
        // ============================================================

        // Take pauser ownership and unpause for deposit if currently paused.
        erc4626YS.setPauser(OWNER);
        if (erc4626YS.paused()) erc4626YS.unpause();

        // Unpause minter for noMintDeposit
        if (minter.paused()) minter.unpause();

        // Approve DOLA to minter for full deposit
        IERC20(DOLA).approve(PHUSD_STABLE_MINTER, totalReceived);

        // Deposit ALL received DOLA into ERC4626 YS via noMintDeposit
        minter.noMintDeposit(ERC4626_YS, DOLA, totalReceived);
        console.log("Deposited into ERC4626 YS:  ", totalReceived / 1e18, "DOLA");

        // ============================================================
        // RESTORE PAUSE STATES AND PAUSERS
        // ============================================================

        // Restore ERC4626 YS pauser
        erc4626YS.setPauser(originalERC4626Pauser);

        // Minter is already unpaused — restore its pauser
        minter.setPauser(originalMinterPauser);

        // Unpause accumulator (if paused) and restore its pauser
        if (accumulator.paused()) accumulator.unpause();
        accumulator.setPauser(originalAccumulatorPauser);

        vm.stopBroadcast();

        // ============================================================
        // POST-FLIGHT VERIFICATION
        // ============================================================

        uint256 autoPoolPrincipalAfter = autoPoolYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 autoPoolTotalBalanceAfter = autoPoolYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 newYSPrincipal = erc4626YS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 newYSTotalBalance = erc4626YS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");
        console.log("--- AutoPool YS (should be empty) ---");
        console.log("Minter principal (wei):     ", autoPoolPrincipalAfter);
        console.log("Minter totalBalance (wei):  ", autoPoolTotalBalanceAfter);

        console.log("\n--- ERC4626 YS (after deposit) ---");
        console.log("Address:                    ", ERC4626_YS);
        console.log("Minter principal (wei):     ", newYSPrincipal);
        console.log("Minter principal (DOLA):    ", newYSPrincipal / 1e18);
        console.log("Minter totalBalance (wei):  ", newYSTotalBalance);
        console.log("Minter totalBalance (DOLA): ", newYSTotalBalance / 1e18);

        // Assert AutoPool YS is empty after full withdrawal
        require(autoPoolPrincipalAfter == 0, "AutoPool YS should have zero principal after full migration");

        // Assert ERC4626 YS principal increased by totalReceived
        uint256 expectedPrincipal = erc4626PrincipalBefore + totalReceived;
        require(newYSPrincipal == expectedPrincipal, "ERC4626 YS principal should equal previous + total received");

        uint256 newYSGap = newYSTotalBalance > expectedPrincipal
            ? newYSTotalBalance - expectedPrincipal
            : expectedPrincipal - newYSTotalBalance;
        require(newYSGap <= 1 ether, "ERC4626 YS totalBalance deviates too much from expected");

        console.log("\n=== VERIFICATION PASSED ===");
        console.log("AutoPool YS is empty and paused. All DOLA migrated to ERC4626 YS.");
        console.log("ERC4626 YS now holds all DOLA for the minter.");
        console.log("");
    }
}
