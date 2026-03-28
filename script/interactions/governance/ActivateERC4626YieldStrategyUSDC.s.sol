// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IYieldStrategyPausable {
    function setWithdrawer(address withdrawer, bool _auth) external;
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
}

interface IMinterPausable {
    function registerStablecoin(address stablecoin, address yieldStrategy, uint256 exchangeRate, uint8 decimals) external;
}

interface IAccumulator {
    function addYieldStrategy(address strategy, address token) external;
}

/**
 * @title ActivateERC4626YieldStrategyUSDC
 * @notice Wires up the deployed ERC4626YieldStrategy as the primary USDC yield strategy
 *         on the PhusdStableMinter and StableYieldAccumulator.
 *
 *         Prerequisites: FullMigrationExecute.s.sol (AutoUSDC) must have been run successfully.
 *         The ERC4626YieldStrategy for USDC must already be deployed, configured with the
 *         minter as client, and funded with USDC.
 *
 *         Steps:
 *         1. Log pre-flight state
 *         2. Register USDC -> ERC4626_YS mapping on minter (overwrites AutoFinance mapping)
 *         3. Add ERC4626 YS to accumulator (coexists with AutoFinance YS)
 *         4. Authorize accumulator as withdrawer on ERC4626 YS
 *         5. Log post-flight verification
 */
contract ActivateERC4626YieldStrategyUSDC is Script {
    // Existing contracts
    address constant PHUSD_STABLE_MINTER     = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant STABLE_YIELD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;

    // Token addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Accounts
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // TODO: Fill from FullMigrationExecute (AutoUSDC) broadcast output.
    // Run `mainnet:autousdc-migrate-execute` and look for console log:
    // "New ERC4626 YS deployed at: <address>"
    address constant ERC4626_YS = address(0);

    function run() external {
        // --- Guard: ERC4626_YS must be set before running ---
        require(ERC4626_YS != address(0), "ERC4626_YS not set: fill address from FullMigrationExecute (AutoUSDC) broadcast output");

        IMinterPausable minter = IMinterPausable(PHUSD_STABLE_MINTER);
        IAccumulator accumulator = IAccumulator(STABLE_YIELD_ACCUMULATOR);
        IYieldStrategyPausable erc4626YS = IYieldStrategyPausable(ERC4626_YS);

        // --- Pre-flight logging ---
        uint256 erc4626Principal = erc4626YS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 erc4626TotalBalance = erc4626YS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);

        console.log("\n=== ActivateERC4626YieldStrategyUSDC Pre-flight ===");
        console.log("ERC4626 YS address:         ", ERC4626_YS);
        console.log("Minter:                     ", PHUSD_STABLE_MINTER);
        console.log("Accumulator:                ", STABLE_YIELD_ACCUMULATOR);
        console.log("USDC:                       ", USDC);
        console.log("ERC4626 principal (wei):    ", erc4626Principal);
        console.log("ERC4626 principal (USDC):   ", erc4626Principal / 1e6);
        console.log("ERC4626 totalBalance (wei): ", erc4626TotalBalance);
        console.log("ERC4626 totalBalance (USDC):", erc4626TotalBalance / 1e6);

        vm.startBroadcast(OWNER);

        // ============================================================
        // STEP 1: Register USDC -> ERC4626 YS on minter
        // ============================================================
        // This overwrites the existing USDC -> AutoFinance mapping.
        // New USDC deposits via mint() will route to ERC4626 after this.
        minter.registerStablecoin(USDC, ERC4626_YS, 1e18, 6);
        console.log("\n[Step 1] registerStablecoin: USDC -> ERC4626_YS (1e18 rate, 6 decimals)");

        // ============================================================
        // STEP 2: Add ERC4626 YS to accumulator
        // ============================================================
        // The accumulator supports multiple yield strategies per token.
        // AutoFinance YS remains registered — both coexist.
        accumulator.addYieldStrategy(ERC4626_YS, USDC);
        console.log("[Step 2] addYieldStrategy: ERC4626_YS registered with accumulator for USDC");

        // ============================================================
        // STEP 3: Authorize accumulator as withdrawer on ERC4626 YS
        // ============================================================
        erc4626YS.setWithdrawer(STABLE_YIELD_ACCUMULATOR, true);
        console.log("[Step 3] setWithdrawer: accumulator authorized on ERC4626_YS");

        vm.stopBroadcast();

        // ============================================================
        // POST-FLIGHT VERIFICATION
        // ============================================================
        uint256 postPrincipal = erc4626YS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 postTotalBalance = erc4626YS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");
        console.log("ERC4626 principal (wei):    ", postPrincipal);
        console.log("ERC4626 principal (USDC):   ", postPrincipal / 1e6);
        console.log("ERC4626 totalBalance (wei): ", postTotalBalance);
        console.log("ERC4626 totalBalance (USDC):", postTotalBalance / 1e6);

        // Principal should be unchanged (no deposits/withdrawals in this script)
        require(postPrincipal == erc4626Principal, "Principal changed unexpectedly");

        console.log("\n=== ACTIVATION COMPLETE ===");
        console.log("USDC deposits now route to ERC4626 YS:", ERC4626_YS);
        console.log("Accumulator can withdraw yield from ERC4626 YS.");
        console.log("AutoFinance YS remains in accumulator with existing funds.");
        console.log("Verify: call minter.stablecoinConfigs(USDC) to confirm new YS address.");
        console.log("");
    }
}
