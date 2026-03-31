// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IAccumulator {
    function removeYieldStrategy(address strategy) external;
    function getYieldStrategies() external view returns (address[] memory);
    function isRegisteredStrategy(address strategy) external view returns (bool);
    function strategyTokens(address strategy) external view returns (address);
    function getTotalYield() external view returns (uint256);
    function calculateClaimAmount() external view returns (uint256);
}

/**
 * @title RemoveAutoPoolDolaFromAccumulator
 * @notice Deregisters the paused AutoPool DOLA YieldStrategy from the StableYieldAccumulator.
 *
 *         The old AutoPool YS (0x5cBAd...) is paused at the contract level, which causes
 *         claim() on the accumulator to revert with EnforcedPause() when it tries to
 *         call withdrawFrom(). Removing it unblocks claims on the remaining strategies.
 *
 *         This does NOT affect the FullMigrationInitiate / FullMigrationExecute scripts,
 *         which interact directly with the AutoPool YS contract and do not depend on
 *         accumulator registration.
 *
 * Usage:
 *   Dry-run:  forge script script/interactions/governance/RemoveAutoPoolDolaFromAccumulator.s.sol:RemoveAutoPoolDolaFromAccumulator \
 *                 --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 -vvv
 *
 *   Broadcast: forge script script/interactions/governance/RemoveAutoPoolDolaFromAccumulator.s.sol:RemoveAutoPoolDolaFromAccumulator \
 *                  --rpc-url $RPC_MAINNET --broadcast --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract RemoveAutoPoolDolaFromAccumulator is Script {
    address constant STABLE_YIELD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant AUTO_POOL_DOLA_YS        = 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4;
    address constant OWNER                    = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        IAccumulator acc = IAccumulator(STABLE_YIELD_ACCUMULATOR);

        // --- Pre-flight ---
        address[] memory strategiesBefore = acc.getYieldStrategies();
        bool isRegistered = acc.isRegisteredStrategy(AUTO_POOL_DOLA_YS);
        uint256 totalYieldBefore = acc.getTotalYield();

        console.log("\n=== RemoveAutoPoolDolaFromAccumulator ===");
        console.log("Accumulator:          ", STABLE_YIELD_ACCUMULATOR);
        console.log("Strategy to remove:   ", AUTO_POOL_DOLA_YS);
        console.log("Is registered:        ", isRegistered);
        console.log("Strategies before:    ", strategiesBefore.length);
        for (uint256 i = 0; i < strategiesBefore.length; i++) {
            console.log("  [%d] %s", i, strategiesBefore[i]);
        }
        console.log("Total yield before (18 dec):", totalYieldBefore);

        require(isRegistered, "Strategy is not registered - nothing to remove");

        vm.startBroadcast(OWNER);
        acc.removeYieldStrategy(AUTO_POOL_DOLA_YS);
        vm.stopBroadcast();

        // --- Post-flight ---
        address[] memory strategiesAfter = acc.getYieldStrategies();
        bool stillRegistered = acc.isRegisteredStrategy(AUTO_POOL_DOLA_YS);
        uint256 totalYieldAfter = acc.getTotalYield();
        uint256 claimAmountAfter = acc.calculateClaimAmount();

        console.log("\n--- Post-flight ---");
        console.log("Strategies after:     ", strategiesAfter.length);
        for (uint256 i = 0; i < strategiesAfter.length; i++) {
            console.log("  [%d] %s", i, strategiesAfter[i]);
        }
        console.log("Still registered:     ", stillRegistered);
        console.log("Total yield after (18 dec):", totalYieldAfter);
        console.log("Claim amount after (USDC):", claimAmountAfter);
        console.log("  (~%d USDC)", claimAmountAfter / 1e6);

        require(!stillRegistered, "Strategy should no longer be registered");
        require(strategiesAfter.length == strategiesBefore.length - 1, "Strategy count should decrease by 1");

        console.log("\n=== REMOVAL COMPLETE ===");
        console.log("claim() should now succeed without hitting EnforcedPause().");
        console.log("FullMigrationInitiate/Execute scripts are unaffected.\n");
    }
}
