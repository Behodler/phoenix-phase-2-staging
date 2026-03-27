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
 * @title ActivateERC4626YieldStrategy
 * @notice Wires up the deployed ERC4626YieldStrategy as the primary DOLA yield strategy
 *         on the PhusdStableMinter and StableYieldAccumulator.
 *
 *         Prerequisites: PartialMigrationExecute.s.sol must have been run successfully.
 *         The ERC4626YieldStrategy must already be deployed, configured with the minter
 *         as client, and seeded with 100 DOLA.
 *
 *         Steps:
 *         1. Log pre-flight state
 *         2. Register DOLA -> ERC4626_YS mapping on minter (overwrites AutoPool mapping)
 *         3. Add ERC4626 YS to accumulator (coexists with AutoPool YS)
 *         4. Authorize accumulator as withdrawer on ERC4626 YS
 *         5. Log post-flight verification
 */
contract ActivateERC4626YieldStrategy is Script {
    // Existing contracts
    address constant PHUSD_STABLE_MINTER     = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant STABLE_YIELD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;

    // Token addresses
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;

    // Accounts
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // TODO: Fill from PartialMigrationExecute broadcast output.
    // Run `mainnet:partial-migrate-execute` and look for console log:
    // "New ERC4626 YS deployed at: <address>"
    address constant ERC4626_YS = address(0);

    function run() external {
        // --- Guard: ERC4626_YS must be set before running ---
        require(ERC4626_YS != address(0), "ERC4626_YS not set: fill address from PartialMigrationExecute broadcast output");

        IMinterPausable minter = IMinterPausable(PHUSD_STABLE_MINTER);
        IAccumulator accumulator = IAccumulator(STABLE_YIELD_ACCUMULATOR);
        IYieldStrategyPausable erc4626YS = IYieldStrategyPausable(ERC4626_YS);

        // --- Pre-flight logging ---
        uint256 erc4626Principal = erc4626YS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 erc4626TotalBalance = erc4626YS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);

        console.log("\n=== ActivateERC4626YieldStrategy Pre-flight ===");
        console.log("ERC4626 YS address:         ", ERC4626_YS);
        console.log("Minter:                     ", PHUSD_STABLE_MINTER);
        console.log("Accumulator:                ", STABLE_YIELD_ACCUMULATOR);
        console.log("DOLA:                       ", DOLA);
        console.log("ERC4626 principal (wei):    ", erc4626Principal);
        console.log("ERC4626 principal (DOLA):   ", erc4626Principal / 1e18);
        console.log("ERC4626 totalBalance (wei): ", erc4626TotalBalance);
        console.log("ERC4626 totalBalance (DOLA):", erc4626TotalBalance / 1e18);

        vm.startBroadcast(OWNER);

        // ============================================================
        // STEP 1: Register DOLA -> ERC4626 YS on minter
        // ============================================================
        // This overwrites the existing DOLA -> AutoPool mapping.
        // New DOLA deposits via mint() will route to ERC4626 after this.
        minter.registerStablecoin(DOLA, ERC4626_YS, 1e18, 18);
        console.log("\n[Step 1] registerStablecoin: DOLA -> ERC4626_YS (1e18 rate, 18 decimals)");

        // ============================================================
        // STEP 2: Add ERC4626 YS to accumulator
        // ============================================================
        // The accumulator supports multiple yield strategies per token.
        // AutoPool YS remains registered — both coexist.
        accumulator.addYieldStrategy(ERC4626_YS, DOLA);
        console.log("[Step 2] addYieldStrategy: ERC4626_YS registered with accumulator for DOLA");

        // ============================================================
        // STEP 3: Authorize accumulator as withdrawer on ERC4626 YS
        // ============================================================
        erc4626YS.setWithdrawer(STABLE_YIELD_ACCUMULATOR, true);
        console.log("[Step 3] setWithdrawer: accumulator authorized on ERC4626_YS");

        vm.stopBroadcast();

        // ============================================================
        // POST-FLIGHT VERIFICATION
        // ============================================================
        uint256 postPrincipal = erc4626YS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 postTotalBalance = erc4626YS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");
        console.log("ERC4626 principal (wei):    ", postPrincipal);
        console.log("ERC4626 principal (DOLA):   ", postPrincipal / 1e18);
        console.log("ERC4626 totalBalance (wei): ", postTotalBalance);
        console.log("ERC4626 totalBalance (DOLA):", postTotalBalance / 1e18);

        // Principal should be unchanged (no deposits/withdrawals in this script)
        require(postPrincipal == erc4626Principal, "Principal changed unexpectedly");

        console.log("\n=== ACTIVATION COMPLETE ===");
        console.log("DOLA deposits now route to ERC4626 YS:", ERC4626_YS);
        console.log("Accumulator can withdraw yield from ERC4626 YS.");
        console.log("AutoPool YS remains in accumulator with existing funds.");
        console.log("Verify: call minter.stablecoinConfigs(DOLA) to confirm new YS address.");
        console.log("");
    }
}
