// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";

/**
 * @title DeployNewAccumulator
 * @notice Mainnet deployment script for a new StableYieldAccumulator
 * @dev This script deploys a fresh StableYieldAccumulator with the latest contract code
 *      and configures it to replace the existing outdated deployment.
 *
 * IMPORTANT: This script creates and configures the deployment, but must be run with
 * --broadcast flag to actually execute. Human review required before execution.
 *
 * Configuration Sequence:
 * 1. Deploy StableYieldAccumulator
 * 2. setRewardToken(USDC)
 * 3. setPhlimbo(phlimboEA)
 * 4. setMinter(minter)
 * 5. setTokenConfig(USDC, 6, 1e18)
 * 6. setTokenConfig(DOLA, 18, 1e18)
 * 7. addYieldStrategy(yieldStrategyDola, DOLA)
 * 8. addYieldStrategy(yieldStrategyUSDC, USDC)
 * 9. setDiscountRate(200) - 2% discount
 * 10. approvePhlimbo(type(uint256).max)
 * 11. setWithdrawer on each YieldStrategy for the new accumulator
 *
 * Note: PhlimboEA no longer stores a yieldAccumulator reference (per story phStaging2:015).
 * The accumulator simply calls collectReward() on PhlimboEA, which is now open to any caller.
 *
 * LEDGER SIGNER:
 * - Index: 46
 * - Owner Address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
contract DeployNewAccumulator is Script {
    // ==========================================
    //         MAINNET ADDRESSES
    // ==========================================

    // External Token Contracts
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;

    // Deployed Phoenix Phase 2 Contracts
    address public constant PHLIMBO_EA = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant YIELD_STRATEGY_DOLA = 0x01d34d7EF3988C5b981ee06bF0Ba4485Bd8eA20C;
    address public constant YIELD_STRATEGY_USDC = 0xf5F91E8240a0320CAC40b799B25F944a61090E5B;

    // Old accumulator (for reference only - will be replaced)
    address public constant OLD_ACCUMULATOR = 0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f;

    // Ledger Signer Configuration
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Configuration constants
    uint256 public constant DISCOUNT_RATE_BPS = 200; // 2% discount

    // ==========================================
    //         DEPLOYMENT STATE
    // ==========================================

    // Newly deployed contract address
    address public newAccumulator;

    // Chain configuration
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    function run() external {
        console.log("=========================================");
        console.log("  NEW STABLEYIELDACCUMULATOR DEPLOYMENT");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        console.log("Expected Chain ID:", CHAIN_ID);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- MAINNET ADDRESSES (VERIFY BEFORE DEPLOYMENT) ---");
        console.log("USDC:                ", USDC);
        console.log("DOLA:                ", DOLA);
        console.log("PhlimboEA:           ", PHLIMBO_EA);
        console.log("PhusdStableMinter:   ", PHUSD_STABLE_MINTER);
        console.log("YieldStrategyDola:   ", YIELD_STRATEGY_DOLA);
        console.log("YieldStrategyUSDC:   ", YIELD_STRATEGY_USDC);
        console.log("Old Accumulator:     ", OLD_ACCUMULATOR);
        console.log("Owner Address:       ", OWNER_ADDRESS);
        console.log("------------------------------------------------------");

        vm.startBroadcast();

        // ====== STEP 1: Deploy StableYieldAccumulator ======
        console.log("\n=== Step 1: Deploy StableYieldAccumulator ===");
        _deployAccumulator();

        // ====== STEP 2: Set Reward Token (USDC) ======
        console.log("\n=== Step 2: Set Reward Token (USDC) ===");
        _setRewardToken();

        // ====== STEP 3: Set Phlimbo ======
        console.log("\n=== Step 3: Set Phlimbo ===");
        _setPhlimbo();

        // ====== STEP 4: Set Minter ======
        console.log("\n=== Step 4: Set Minter ===");
        _setMinter();

        // ====== STEP 5: Set Token Config for USDC ======
        console.log("\n=== Step 5: Set Token Config for USDC ===");
        _setTokenConfigUSDC();

        // ====== STEP 6: Set Token Config for DOLA ======
        console.log("\n=== Step 6: Set Token Config for DOLA ===");
        _setTokenConfigDOLA();

        // ====== STEP 7: Add YieldStrategy for DOLA ======
        console.log("\n=== Step 7: Add YieldStrategy for DOLA ===");
        _addYieldStrategyDola();

        // ====== STEP 8: Add YieldStrategy for USDC ======
        console.log("\n=== Step 8: Add YieldStrategy for USDC ===");
        _addYieldStrategyUSDC();

        // ====== STEP 9: Set Discount Rate ======
        console.log("\n=== Step 9: Set Discount Rate ===");
        _setDiscountRate();

        // ====== STEP 10: Approve Phlimbo ======
        console.log("\n=== Step 10: Approve Phlimbo for Reward Transfers ===");
        _approvePhlimbo();

        // ====== STEP 11: Authorize Accumulator as Withdrawer on YieldStrategies ======
        console.log("\n=== Step 11: Authorize Accumulator as Withdrawer ===");
        _authorizeWithdrawers();

        vm.stopBroadcast();

        // ====== Print Summary ======
        _printDeploymentSummary();
    }

    // ========================================
    // STEP 1: Deploy StableYieldAccumulator
    // ========================================

    function _deployAccumulator() internal {
        StableYieldAccumulator accumulator = new StableYieldAccumulator();
        newAccumulator = address(accumulator);

        console.log("StableYieldAccumulator deployed at:", newAccumulator);
        console.log("  - Owner:", OWNER_ADDRESS);
    }

    // ========================================
    // STEP 2: Set Reward Token (USDC)
    // ========================================

    function _setRewardToken() internal {
        StableYieldAccumulator(newAccumulator).setRewardToken(USDC);
        console.log("Reward token set to USDC:", USDC);
    }

    // ========================================
    // STEP 3: Set Phlimbo
    // ========================================

    function _setPhlimbo() internal {
        StableYieldAccumulator(newAccumulator).setPhlimbo(PHLIMBO_EA);
        console.log("Phlimbo set to:", PHLIMBO_EA);
    }

    // ========================================
    // STEP 4: Set Minter
    // ========================================

    function _setMinter() internal {
        StableYieldAccumulator(newAccumulator).setMinter(PHUSD_STABLE_MINTER);
        console.log("Minter set to:", PHUSD_STABLE_MINTER);
    }

    // ========================================
    // STEP 5: Set Token Config for USDC
    // ========================================

    function _setTokenConfigUSDC() internal {
        // USDC: 6 decimals, 1:1 exchange rate (1e18)
        StableYieldAccumulator(newAccumulator).setTokenConfig(USDC, 6, 1e18);
        console.log("USDC token config set:");
        console.log("  - Decimals: 6");
        console.log("  - Exchange rate: 1e18 (1:1)");
    }

    // ========================================
    // STEP 6: Set Token Config for DOLA
    // ========================================

    function _setTokenConfigDOLA() internal {
        // DOLA: 18 decimals, 1:1 exchange rate (1e18)
        StableYieldAccumulator(newAccumulator).setTokenConfig(DOLA, 18, 1e18);
        console.log("DOLA token config set:");
        console.log("  - Decimals: 18");
        console.log("  - Exchange rate: 1e18 (1:1)");
    }

    // ========================================
    // STEP 7: Add YieldStrategy for DOLA
    // ========================================

    function _addYieldStrategyDola() internal {
        StableYieldAccumulator(newAccumulator).addYieldStrategy(YIELD_STRATEGY_DOLA, DOLA);
        console.log("YieldStrategyDola added:");
        console.log("  - Strategy:", YIELD_STRATEGY_DOLA);
        console.log("  - Token: DOLA");
    }

    // ========================================
    // STEP 8: Add YieldStrategy for USDC
    // ========================================

    function _addYieldStrategyUSDC() internal {
        StableYieldAccumulator(newAccumulator).addYieldStrategy(YIELD_STRATEGY_USDC, USDC);
        console.log("YieldStrategyUSDC added:");
        console.log("  - Strategy:", YIELD_STRATEGY_USDC);
        console.log("  - Token: USDC");
    }

    // ========================================
    // STEP 9: Set Discount Rate
    // ========================================

    function _setDiscountRate() internal {
        StableYieldAccumulator(newAccumulator).setDiscountRate(DISCOUNT_RATE_BPS);
        console.log("Discount rate set to:", DISCOUNT_RATE_BPS, "bps (2%)");
    }

    // ========================================
    // STEP 10: Approve Phlimbo
    // ========================================

    function _approvePhlimbo() internal {
        StableYieldAccumulator(newAccumulator).approvePhlimbo(type(uint256).max);
        console.log("Phlimbo approved for max USDC transfer");
    }

    // ========================================
    // STEP 11: Authorize Withdrawers
    // ========================================

    function _authorizeWithdrawers() internal {
        // Authorize new accumulator as withdrawer on DOLA YieldStrategy
        AYieldStrategy(YIELD_STRATEGY_DOLA).setWithdrawer(newAccumulator, true);
        console.log("Authorized new accumulator as withdrawer on YieldStrategyDola");

        // Authorize new accumulator as withdrawer on USDC YieldStrategy
        AYieldStrategy(YIELD_STRATEGY_USDC).setWithdrawer(newAccumulator, true);
        console.log("Authorized new accumulator as withdrawer on YieldStrategyUSDC");
    }

    // ========================================
    // Deployment Summary
    // ========================================

    function _printDeploymentSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("       DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("");
        console.log("NEW StableYieldAccumulator:", newAccumulator);
        console.log("");
        console.log("Configuration:");
        console.log("  - Reward Token: USDC (", USDC, ")");
        console.log("  - Phlimbo:      ", PHLIMBO_EA);
        console.log("  - Minter:       ", PHUSD_STABLE_MINTER);
        console.log("  - Discount Rate: 200 bps (2%)");
        console.log("");
        console.log("Token Configs:");
        console.log("  - USDC: 6 decimals, 1:1 rate");
        console.log("  - DOLA: 18 decimals, 1:1 rate");
        console.log("");
        console.log("Yield Strategies:");
        console.log("  - YieldStrategyDola:", YIELD_STRATEGY_DOLA, "-> DOLA");
        console.log("  - YieldStrategyUSDC:", YIELD_STRATEGY_USDC, "-> USDC");
        console.log("");
        console.log("Withdrawer Authorization:");
        console.log("  - New accumulator authorized on both YieldStrategies");
        console.log("");
        console.log("OLD Accumulator (to be deprecated):", OLD_ACCUMULATOR);
        console.log("");
        console.log("=========================================");
        console.log("  NEXT STEPS (Manual)");
        console.log("=========================================");
        console.log("");
        console.log("1. Verify deployment on Etherscan");
        console.log("2. Update server/deployments/mainnet-addresses.ts");
        console.log("3. Update server/deployments/mainnet.json");
        console.log("4. Call getTotalYield() to verify (should return 0 initially)");
        console.log("5. Consider revoking old accumulator's withdrawer permissions");
        console.log("=========================================");
    }
}
