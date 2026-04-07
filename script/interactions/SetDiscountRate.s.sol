// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IStableYieldAccumulator {
    function discountRate() external view returns (uint256);
    function setDiscountRate(uint256 rate) external;
}

/**
 * @title SetDiscountRate
 * @notice Sets the discount rate on the mainnet StableYieldAccumulator from 20% to 30%.
 *
 * Usage (dry run):
 *   npm run mainnet:set-discount-rate-dry
 *
 * Usage (broadcast with Ledger index 46):
 *   npm run mainnet:set-discount-rate
 */
contract SetDiscountRate is Script {
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant STABLE_YIELD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;

    uint256 constant EXPECTED_CURRENT_RATE = 2000; // 20%
    uint256 constant NEW_RATE = 3000; // 30%

    function run() external {
        IStableYieldAccumulator sya = IStableYieldAccumulator(STABLE_YIELD_ACCUMULATOR);

        // --- Pre-flight ---
        uint256 currentRate = sya.discountRate();

        console.log("\n=== SetDiscountRate Pre-flight ===");
        console.log("StableYieldAccumulator:", STABLE_YIELD_ACCUMULATOR);
        console.log("Current discount rate (bps):", currentRate);
        console.log("Expected current rate (bps):", EXPECTED_CURRENT_RATE);
        console.log("New discount rate (bps):    ", NEW_RATE);

        require(currentRate == EXPECTED_CURRENT_RATE, "Current discount rate is not 20% (2000 bps) as expected");

        vm.startBroadcast(OWNER);

        sya.setDiscountRate(NEW_RATE);
        console.log("\n[Step 1] setDiscountRate(3000) called");

        vm.stopBroadcast();

        // --- Post-flight verification ---
        uint256 updatedRate = sya.discountRate();
        console.log("\n=== Post-flight Verification ===");
        console.log("Updated discount rate (bps):", updatedRate);
        require(updatedRate == NEW_RATE, "Discount rate was not updated to 30% (3000 bps)");

        console.log("\n=== SetDiscountRate Complete ===");
        console.log("Discount rate changed from 20% to 30%.");
    }
}
