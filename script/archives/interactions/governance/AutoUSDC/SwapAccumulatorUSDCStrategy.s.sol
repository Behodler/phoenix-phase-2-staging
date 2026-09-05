// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IAccumulator {
    function removeYieldStrategy(address strategy) external;
    function addYieldStrategy(address strategy, address token) external;
    function getYieldStrategies() external view returns (address[] memory);
    function isRegisteredStrategy(address strategy) external view returns (bool);
    function strategyTokens(address strategy) external view returns (address);
    function getTotalYield() external view returns (uint256);
    function calculateClaimAmount() external view returns (uint256);
    function getYield(address strategy) external view returns (uint256);
}

interface IYieldStrategy {
    function setWithdrawer(address withdrawer, bool _auth) external;
    function authorizedWithdrawers(address) external view returns (bool);
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
}

/**
 * @title SwapAccumulatorUSDCStrategy
 * @notice Replaces the old empty AutoFinance USDC YieldStrategy with the active
 *         ERC4626 USDC YieldStrategy on the StableYieldAccumulator.
 *
 *         After the USDC full migration (FullMigrationExecute), the old AutoFinance
 *         YS (0xf5F9...) was left registered in the accumulator despite being empty.
 *         The new ERC4626 YS (0x8b4A...) holds all USDC funds and has pending yield,
 *         but was never registered. This script fixes that by:
 *
 *         1. Removing the old AutoFinance USDC YS from the accumulator
 *         2. Registering the new ERC4626 USDC YS on the accumulator
 *         3. Authorizing the accumulator as a withdrawer on the new ERC4626 YS
 *
 * Usage:
 *   Dry-run:   npm run mainnet:autousdc-swap-accumulator-dry
 *   Broadcast:  npm run mainnet:autousdc-swap-accumulator
 */
contract SwapAccumulatorUSDCStrategy is Script {
    address constant STABLE_YIELD_ACCUMULATOR = 0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f;
    address constant OLD_USDC_YS              = 0xf5F91E8240a0320CAC40b799B25F944a61090E5B;
    address constant NEW_USDC_YS              = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address constant USDC                     = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PHUSD_STABLE_MINTER      = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant OWNER                    = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        IAccumulator acc = IAccumulator(STABLE_YIELD_ACCUMULATOR);
        IYieldStrategy oldYS = IYieldStrategy(OLD_USDC_YS);
        IYieldStrategy newYS = IYieldStrategy(NEW_USDC_YS);

        // --- Pre-flight ---
        address[] memory strategiesBefore = acc.getYieldStrategies();
        bool oldIsRegistered = acc.isRegisteredStrategy(OLD_USDC_YS);
        bool newIsRegistered = acc.isRegisteredStrategy(NEW_USDC_YS);
        bool accIsWithdrawer = newYS.authorizedWithdrawers(STABLE_YIELD_ACCUMULATOR);
        uint256 totalYieldBefore = acc.getTotalYield();

        uint256 oldTotal = oldYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        uint256 oldPrincipal = oldYS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 newTotal = newYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        uint256 newPrincipal = newYS.principalOf(USDC, PHUSD_STABLE_MINTER);

        console.log("\n=== SwapAccumulatorUSDCStrategy Pre-flight ===");
        console.log("Accumulator:              ", STABLE_YIELD_ACCUMULATOR);
        console.log("Old USDC YS (to remove):  ", OLD_USDC_YS);
        console.log("New USDC YS (to add):     ", NEW_USDC_YS);
        console.log("");
        console.log("Strategies registered:    ", strategiesBefore.length);
        for (uint256 i = 0; i < strategiesBefore.length; i++) {
            console.log("  [%d] %s", i, strategiesBefore[i]);
        }
        console.log("");
        console.log("Old YS registered:        ", oldIsRegistered);
        console.log("Old YS totalBalance:      ", oldTotal);
        console.log("Old YS principal:         ", oldPrincipal);
        console.log("");
        console.log("New YS registered:        ", newIsRegistered);
        console.log("New YS totalBalance (wei):", newTotal);
        console.log("New YS totalBalance (USDC):", newTotal / 1e6);
        console.log("New YS principal (wei):   ", newPrincipal);
        console.log("New YS principal (USDC):  ", newPrincipal / 1e6);
        console.log("New YS pending yield (wei):", newTotal - newPrincipal);
        console.log("New YS pending yield (USDC):", (newTotal - newPrincipal) / 1e6);
        console.log("");
        console.log("Acc is withdrawer on new: ", accIsWithdrawer);
        console.log("Total yield before (18d): ", totalYieldBefore);

        require(oldIsRegistered, "Old YS is not registered - nothing to remove");
        require(!newIsRegistered, "New YS is already registered");

        // --- Execute ---
        vm.startBroadcast(OWNER);

        // Step 1: Remove old empty AutoFinance USDC strategy
        acc.removeYieldStrategy(OLD_USDC_YS);
        console.log("\n[Step 1] Removed old USDC YS from accumulator");

        // Step 2: Register new ERC4626 USDC strategy
        acc.addYieldStrategy(NEW_USDC_YS, USDC);
        console.log("[Step 2] Added new USDC YS to accumulator");

        // Step 3: Authorize accumulator as withdrawer on new YS
        newYS.setWithdrawer(STABLE_YIELD_ACCUMULATOR, true);
        console.log("[Step 3] Authorized accumulator as withdrawer on new USDC YS");

        vm.stopBroadcast();

        // --- Post-flight ---
        address[] memory strategiesAfter = acc.getYieldStrategies();
        bool oldStillRegistered = acc.isRegisteredStrategy(OLD_USDC_YS);
        bool newNowRegistered = acc.isRegisteredStrategy(NEW_USDC_YS);
        bool accNowWithdrawer = newYS.authorizedWithdrawers(STABLE_YIELD_ACCUMULATOR);
        uint256 totalYieldAfter = acc.getTotalYield();
        uint256 newYSYield = acc.getYield(NEW_USDC_YS);
        uint256 claimAmountAfter = acc.calculateClaimAmount();

        console.log("\n--- Post-flight ---");
        console.log("Strategies after:         ", strategiesAfter.length);
        for (uint256 i = 0; i < strategiesAfter.length; i++) {
            console.log("  [%d] %s", i, strategiesAfter[i]);
        }
        console.log("");
        console.log("Old YS still registered:  ", oldStillRegistered);
        console.log("New YS now registered:    ", newNowRegistered);
        console.log("Acc is withdrawer on new: ", accNowWithdrawer);
        console.log("");
        console.log("New YS yield (wei):       ", newYSYield);
        console.log("New YS yield (USDC):      ", newYSYield / 1e6);
        console.log("Total yield after (18d):  ", totalYieldAfter);
        console.log("Claim amount (USDC wei):  ", claimAmountAfter);
        console.log("  (~%d USDC)", claimAmountAfter / 1e6);

        require(!oldStillRegistered, "Old YS should no longer be registered");
        require(newNowRegistered, "New YS should be registered");
        require(accNowWithdrawer, "Accumulator should be authorized withdrawer");
        require(strategiesAfter.length == strategiesBefore.length, "Strategy count should be unchanged (swap)");

        console.log("\n=== SWAP COMPLETE ===");
        console.log("Accumulator now tracks the active ERC4626 USDC YieldStrategy.");
        console.log("getTotalYield() and calculateClaimAmount() should now return non-zero.\n");
    }
}
