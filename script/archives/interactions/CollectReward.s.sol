// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPhlimboEA {
    function collectReward(uint256 amount) external;
    function rewardToken() external view returns (address);
    function rewardBalance() external view returns (uint256);
    function rewardPerSecond() external view returns (uint256);
    function depletionDuration() external view returns (uint256);
}

/**
 * @title CollectReward
 * @notice Script to collect rewards into Phlimbo by calling collectReward
 * @dev Deposits the caller's entire USDC balance as rewards for Phlimbo stakers
 *      Hardcoded for mainnet deployment
 */
contract CollectReward is Script {
    // Mainnet addresses from progress.1.json
    address public constant PHLIMBO = 0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4;

    // Mainnet USDC token
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Expected caller address (Ledger index 4)
    address public constant EXPECTED_CALLER = 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28;

    function run() external {
        // For Ledger signing, we use EXPECTED_CALLER as the signer
        address caller = EXPECTED_CALLER;

        // Get caller's entire USDC balance
        uint256 usdcBalance = IERC20(USDC).balanceOf(caller);

        // Query current state of Phlimbo
        IPhlimboEA phlimbo = IPhlimboEA(PHLIMBO);
        uint256 rewardBalanceBefore = phlimbo.rewardBalance();
        uint256 rewardPerSecondBefore = phlimbo.rewardPerSecond();
        uint256 depletionDuration = phlimbo.depletionDuration();

        console.log("\n=== CollectReward (Mainnet) ===");
        console.log("Caller:", caller);
        console.log("Phlimbo:", PHLIMBO);
        console.log("USDC token:", USDC);
        console.log("");
        console.log("--- Caller USDC Balance ---");
        console.log("USDC balance to deposit (wei):", usdcBalance);
        console.log("USDC balance to deposit:", usdcBalance / 1e6, "USDC");
        console.log("");
        console.log("--- Phlimbo State BEFORE ---");
        console.log("Reward balance (wei):", rewardBalanceBefore);
        console.log("Reward balance:", rewardBalanceBefore / 1e6, "USDC");
        console.log("Reward per second (scaled):", rewardPerSecondBefore);
        console.log("Depletion duration:", depletionDuration, "seconds");
        console.log("");
        console.log("--- Expected State AFTER ---");
        uint256 expectedRewardBalance = rewardBalanceBefore + usdcBalance;
        console.log("Expected reward balance:", expectedRewardBalance / 1e6, "USDC");

        require(usdcBalance > 0, "No USDC balance to deposit");

        vm.startBroadcast();

        // Step 1: Approve USDC for Phlimbo
        IERC20(USDC).approve(PHLIMBO, usdcBalance);
        console.log("");
        console.log("Approved USDC for Phlimbo");

        // Step 2: Call collectReward
        phlimbo.collectReward(usdcBalance);
        console.log("collectReward executed successfully");

        vm.stopBroadcast();

        // Query state after (will show expected values in dry run)
        uint256 rewardBalanceAfter = phlimbo.rewardBalance();
        uint256 rewardPerSecondAfter = phlimbo.rewardPerSecond();

        console.log("");
        console.log("--- Phlimbo State AFTER ---");
        console.log("Reward balance (wei):", rewardBalanceAfter);
        console.log("Reward balance:", rewardBalanceAfter / 1e6, "USDC");
        console.log("Reward per second (scaled):", rewardPerSecondAfter);
        console.log("");
        console.log("--- Changes ---");
        console.log("Reward balance increased by:", (rewardBalanceAfter - rewardBalanceBefore) / 1e6, "USDC");

        console.log("\n=== CollectReward Complete ===\n");
    }
}
