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

interface IAccumulatorPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
}

interface IPauser {
    function register(address pausableContract) external;
}

/**
 * @title FullMigrationExecute
 * @notice Phase 2 of full USDC migration: executes the totalWithdrawal and re-deposits
 *         ALL funds into a new ERC4626YieldStrategy wrapping the AutoUSDC vault.
 *
 *         Unlike the DOLA partial migration (which keeps the bulk in AutoPool and seeds
 *         the new YS with only 100 DOLA), this moves ALL USDC out of the AutoFinance
 *         YieldStrategy and into the new ERC4626YieldStrategy. The old AutoFinance YS
 *         is left paused and empty.
 *
 *         Prerequisites: FullMigrationInitiate.s.sol must have been run >= 24h ago.
 *
 *         Steps:
 *         1. Log pre-flight state
 *         2. Pause minter, AutoFinance YS, and accumulator (take ownership of pausers temporarily)
 *         3. Unpause AutoFinance YS and execute totalWithdrawal Phase 2 (funds go to owner)
 *         4. Deploy new ERC4626YieldStrategy wrapping AutoUSDC vault
 *         5. Configure new YS (client, approveYS) and deposit ALL received USDC via noMintDeposit
 *         6. Leave AutoFinance YS paused (now empty), restore minter and accumulator
 *         7. Set up pauser on new YS, register with global pauser, and unpause
 *         8. Log post-flight verification
 */
contract FullMigrationExecute is Script {
    // Existing contracts (from server/deployments/mainnet-addresses.ts)
    address constant AUTO_FINANCE_YS             = 0xf5F91E8240a0320CAC40b799B25F944a61090E5B;
    address constant PHUSD_STABLE_MINTER         = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant STABLE_YIELD_ACCUMULATOR    = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant GLOBAL_PAUSER               = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // Token and vault addresses
    address constant USDC                        = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant AUTO_USDC_VAULT             = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;

    // Accounts
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        IYieldStrategyPausable autoFinanceYS = IYieldStrategyPausable(AUTO_FINANCE_YS);
        IMinterPausable minter = IMinterPausable(PHUSD_STABLE_MINTER);
        IAccumulatorPausable accumulator = IAccumulatorPausable(STABLE_YIELD_ACCUMULATOR);

        // --- Pre-flight logging ---
        uint256 principalBefore = autoFinanceYS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 totalBalanceBefore = autoFinanceYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        address originalMinterPauser = minter.pauser();
        address originalAutoFinancePauser = autoFinanceYS.pauser();
        address originalAccumulatorPauser = accumulator.pauser();

        console.log("\n=== FullMigrationExecute (USDC) Pre-flight ===");
        console.log("AutoFinance YS:             ", AUTO_FINANCE_YS);
        console.log("Minter:                     ", PHUSD_STABLE_MINTER);
        console.log("Accumulator:                ", STABLE_YIELD_ACCUMULATOR);
        console.log("Minter principal (wei):     ", principalBefore);
        console.log("Minter principal (USDC):    ", principalBefore / 1e6);
        console.log("Minter totalBalance (wei):  ", totalBalanceBefore);
        console.log("Minter totalBalance (USDC): ", totalBalanceBefore / 1e6);
        console.log("Original minter pauser:     ", originalMinterPauser);
        console.log("Original AutoFinance pauser:", originalAutoFinancePauser);
        console.log("Original accumulator pauser:", originalAccumulatorPauser);

        vm.startBroadcast(OWNER);

        // ============================================================
        // PAUSE MINTER, AUTOFINANCE YS, AND ACCUMULATOR
        // ============================================================

        // 1. Take pauser ownership on all contracts and pause them
        autoFinanceYS.setPauser(OWNER);
        autoFinanceYS.pause();

        minter.setPauser(OWNER);
        minter.pause();

        accumulator.setPauser(OWNER);
        accumulator.pause();

        // ============================================================
        // PHASE 2: Execute totalWithdrawal (funds sent to owner)
        // ============================================================

        // 2. Unpause AutoFinance YS for totalWithdrawal (requires whenNotPaused)
        autoFinanceYS.unpause();

        // 3. Record owner's USDC balance before withdrawal
        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(OWNER);

        // 4. Execute totalWithdrawal Phase 2 (24h has passed, within execution window)
        autoFinanceYS.totalWithdrawal(USDC, PHUSD_STABLE_MINTER);

        // 5. Record total received
        uint256 totalReceived = IERC20(USDC).balanceOf(OWNER) - usdcBalanceBefore;
        console.log("\nTotal USDC received:        ", totalReceived);
        console.log("Total USDC received (USDC): ", totalReceived / 1e6);

        require(totalReceived > 0, "No USDC received from withdrawal");

        // 6. Pause AutoFinance YS — it is now empty and being retired
        autoFinanceYS.pause();
        autoFinanceYS.setPauser(originalAutoFinancePauser);

        // ============================================================
        // DEPLOY AND CONFIGURE NEW ERC4626YieldStrategy
        // ============================================================

        // 7. Deploy new ERC4626YieldStrategy wrapping AutoUSDC vault
        ERC4626YieldStrategy newYS = new ERC4626YieldStrategy(OWNER, USDC, AUTO_USDC_VAULT);
        address newYSAddr = address(newYS);
        console.log("\nNew ERC4626 YS deployed at: ", newYSAddr);

        // 8. Authorize minter as client on new YS
        IYieldStrategyPausable(newYSAddr).setClient(PHUSD_STABLE_MINTER, true);

        // 9. Unpause minter for noMintDeposit
        minter.unpause();

        // 10. Approve new YS to pull USDC from minter
        minter.approveYS(USDC, newYSAddr);

        // 11. Approve USDC to minter for full deposit
        IERC20(USDC).approve(PHUSD_STABLE_MINTER, totalReceived);

        // 12. Deposit ALL received USDC into new YS via noMintDeposit
        minter.noMintDeposit(newYSAddr, USDC, totalReceived);
        console.log("Deposited into new YS:      ", totalReceived / 1e6, "USDC");

        // ============================================================
        // RESTORE PAUSE STATES AND PAUSERS
        // ============================================================

        // 13. Minter is already unpaused — restore its pauser
        minter.setPauser(originalMinterPauser);

        // 14. Unpause accumulator and restore its pauser
        accumulator.unpause();
        accumulator.setPauser(originalAccumulatorPauser);

        // ============================================================
        // PAUSER SETUP FOR NEW YS
        // ============================================================

        // 15. Set pauser on new YS to owner, then pause, then set pauser to global pauser
        IYieldStrategyPausable(newYSAddr).setPauser(OWNER);
        IYieldStrategyPausable(newYSAddr).pause();
        IYieldStrategyPausable(newYSAddr).setPauser(GLOBAL_PAUSER);

        // 16. Register new YS with global pauser (requires newYS.pauser() == GLOBAL_PAUSER)
        IPauser(GLOBAL_PAUSER).register(newYSAddr);

        // 17. Unpause new YS: take pauser ownership, unpause, restore to GLOBAL_PAUSER
        IYieldStrategyPausable(newYSAddr).setPauser(OWNER);
        IYieldStrategyPausable(newYSAddr).unpause();
        IYieldStrategyPausable(newYSAddr).setPauser(GLOBAL_PAUSER);

        vm.stopBroadcast();

        // ============================================================
        // POST-FLIGHT VERIFICATION
        // ============================================================

        uint256 autoFinancePrincipalAfter = autoFinanceYS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 autoFinanceTotalBalanceAfter = autoFinanceYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        uint256 newYSPrincipal = IYieldStrategyPausable(newYSAddr).principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 newYSTotalBalance = IYieldStrategyPausable(newYSAddr).totalBalanceOf(USDC, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");
        console.log("--- AutoFinance YS (should be empty) ---");
        console.log("Minter principal (wei):     ", autoFinancePrincipalAfter);
        console.log("Minter totalBalance (wei):  ", autoFinanceTotalBalanceAfter);

        console.log("\n--- New ERC4626 YS ---");
        console.log("Deployed address:           ", newYSAddr);
        console.log("Minter principal (wei):     ", newYSPrincipal);
        console.log("Minter principal (USDC):    ", newYSPrincipal / 1e6);
        console.log("Minter totalBalance (wei):  ", newYSTotalBalance);
        console.log("Minter totalBalance (USDC): ", newYSTotalBalance / 1e6);

        // Assert AutoFinance YS is empty after full withdrawal
        require(autoFinancePrincipalAfter == 0, "AutoFinance YS should have zero principal after full migration");

        // Assert new YS has all the funds
        require(newYSPrincipal == totalReceived, "New YS principal should equal total received");
        uint256 newYSGap = newYSTotalBalance > totalReceived
            ? newYSTotalBalance - totalReceived
            : totalReceived - newYSTotalBalance;
        require(newYSGap <= 1e6, "New YS totalBalance deviates too much from deposit amount");

        console.log("\n=== VERIFICATION PASSED ===");
        console.log("AutoFinance YS is empty and paused. All USDC migrated to new ERC4626 YS.");
        console.log("Update mainnet-addresses.ts with new ERC4626 USDC YS:", newYSAddr);
        console.log("");
    }
}
