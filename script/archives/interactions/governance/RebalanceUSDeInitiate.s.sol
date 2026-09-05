// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IYieldStrategyView {
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
    function totalWithdrawal(address token, address client) external;
}

/**
 * @title RebalanceUSDeInitiate
 * @notice Phase 1 of USDe rebalance: initiates totalWithdrawal on BOTH USDCYieldStrategy
 *         and DolaYieldStrategy.
 *
 *         This begins the 24-hour waiting period for the two-phase totalWithdrawal flow
 *         on each strategy. After 24 hours, run RebalanceUSDeExecute.s.sol to complete
 *         the rebalance (withdraw, re-deposit 85%, swap 15% to USDe, deposit USDe).
 *
 *         Steps:
 *         1. Log pre-flight state (minter's principal and totalBalance on both strategies)
 *         2. Call totalWithdrawal(USDC, PHUSD_STABLE_MINTER) on USDCYieldStrategy
 *         3. Call totalWithdrawal(DOLA, PHUSD_STABLE_MINTER) on DolaYieldStrategy
 *         4. Log confirmation and execution window timestamps
 *
 *         Note: Strategies are normally unpaused, so no pause manipulation is needed here.
 */
contract RebalanceUSDeInitiate is Script {
    // Mainnet addresses
    address constant USDC_YS             = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address constant DOLA_YS             = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;
    address constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant USDC                = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DOLA                = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant OWNER               = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        IYieldStrategyView usdcYS = IYieldStrategyView(USDC_YS);
        IYieldStrategyView dolaYS = IYieldStrategyView(DOLA_YS);

        // --- Pre-flight logging ---
        uint256 usdcPrincipal = usdcYS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 usdcTotalBalance = usdcYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        uint256 dolaPrincipal = dolaYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 dolaTotalBalance = dolaYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);

        console.log("\n=== RebalanceUSDeInitiate Pre-flight ===");

        console.log("--- USDC YieldStrategy ---");
        console.log("Address:                    ", USDC_YS);
        console.log("Minter principal (wei):     ", usdcPrincipal);
        console.log("Minter principal (USDC):    ", usdcPrincipal / 1e6);
        console.log("Minter totalBalance (wei):  ", usdcTotalBalance);
        console.log("Minter totalBalance (USDC): ", usdcTotalBalance / 1e6);

        console.log("\n--- DOLA YieldStrategy ---");
        console.log("Address:                    ", DOLA_YS);
        console.log("Minter principal (wei):     ", dolaPrincipal);
        console.log("Minter principal (DOLA):    ", dolaPrincipal / 1e18);
        console.log("Minter totalBalance (wei):  ", dolaTotalBalance);
        console.log("Minter totalBalance (DOLA): ", dolaTotalBalance / 1e18);

        require(usdcPrincipal > 0, "No USDC principal to withdraw");
        require(dolaPrincipal > 0, "No DOLA principal to withdraw");

        vm.startBroadcast(OWNER);

        // Initiate Phase 1 on USDC YieldStrategy (24h waiting period)
        usdcYS.totalWithdrawal(USDC, PHUSD_STABLE_MINTER);

        // Initiate Phase 1 on DOLA YieldStrategy (24h waiting period)
        dolaYS.totalWithdrawal(DOLA, PHUSD_STABLE_MINTER);

        vm.stopBroadcast();

        // --- Post-flight logging ---
        uint256 executionWindowOpens = block.timestamp + 24 hours;
        uint256 executionWindowCloses = block.timestamp + 72 hours;

        console.log("\n=== Phase 1 Initiated Successfully on BOTH Strategies ===");
        console.log("Current timestamp:          ", block.timestamp);
        console.log("Execution window opens at:  ", executionWindowOpens);
        console.log("Execution window closes at: ", executionWindowCloses);
        console.log("");
        console.log("NEXT STEP: Run RebalanceUSDeExecute.s.sol after the 24h waiting period.");
        console.log("           The execution window is 48 hours after the waiting period expires.");
        console.log("");
    }
}
