// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../src/mocks/MockPhUSD.sol";
import "../../src/mocks/MockUSDT.sol";
import "../../src/mocks/MockUSDS.sol";
import "../../src/mocks/MockRewardToken.sol";
import "../../src/mocks/MockYieldStrategy.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title FullFlowTest
 * @notice Complete test of the Phase 2 architecture with 2 stakers
 * @dev Tests (simplified after StableYieldAccumulator removal):
 *      1. Two users mint phUSD using USDT
 *      2. Both users stake phUSD in Phlimbo
 *      3. Yield accumulates in strategies
 *      4. Rewards are injected into Phlimbo via collectReward()
 *      5. Both stakers claim their rewards
 */
contract FullFlowTest is Script {
    using AddressLoader for *;

    // Contract instances
    MockPhUSD phUSD;
    MockRewardToken usdc;
    MockUSDT usdt;
    MockUSDS usds;
    MockYieldStrategy ysUSDT;
    MockYieldStrategy ysUSDS;
    PhusdStableMinter minter;
    PhlimboEA phlimbo;

    // Users
    address user1;
    address user2;
    uint256 user1Key;
    uint256 user2Key;

    function run() external {
        _loadContracts();
        _loadUsers();

        console.log("\n========================================");
        console.log("    FULL FLOW TEST - 2 STAKERS");
        console.log("========================================\n");

        // Step 1: Fund users with USDT for minting
        _step1_fundUsers();

        // Step 2: Both users mint phUSD
        _step2_mintPhUSD();

        // Step 3: Both users stake in Phlimbo
        _step3_stakeInPhlimbo();

        // Step 4: Simulate yield in both strategies
        _step4_simulateYield();

        // Step 5: Inject rewards via collectReward (simulating external reward injection)
        _step5_injectRewards();

        // Step 6: Check and claim Phlimbo rewards
        _step6_claimPhlimboRewards();

        console.log("\n========================================");
        console.log("    TEST COMPLETE!");
        console.log("========================================\n");
    }

    function _loadContracts() internal {
        phUSD = MockPhUSD(AddressLoader.getPhUSD());
        usdc = MockRewardToken(AddressLoader.getUSDC());
        usdt = MockUSDT(AddressLoader.getUSDT());
        usds = MockUSDS(AddressLoader.getUSDS());
        ysUSDT = MockYieldStrategy(AddressLoader.getYieldStrategyUSDT());
        ysUSDS = MockYieldStrategy(AddressLoader.getYieldStrategyUSDS());
        minter = PhusdStableMinter(AddressLoader.getMinter());
        phlimbo = PhlimboEA(AddressLoader.getPhlimbo());
    }

    function _loadUsers() internal {
        user1 = AddressLoader.getDefaultUser();
        user2 = AddressLoader.getSecondUser();
        user1Key = AddressLoader.getDefaultPrivateKey();
        user2Key = AddressLoader.getSecondPrivateKey();

        console.log("User 1:", user1);
        console.log("User 2:", user2);
    }

    function _step1_fundUsers() internal {
        console.log("\n--- Step 1: Funding Users with USDT ---");

        uint256 usdtAmount = 1000 * 10**6; // 1000 USDT each

        vm.startBroadcast(user1Key);
        // User1 (deployer) already has USDT from deployment
        // Transfer some to user2
        usdt.transfer(user2, usdtAmount);
        console.log("Transferred 1000 USDT to User2");
        vm.stopBroadcast();

        console.log("User1 USDT:", usdt.balanceOf(user1));
        console.log("User2 USDT:", usdt.balanceOf(user2));
    }

    function _step2_mintPhUSD() internal {
        console.log("\n--- Step 2: Both Users Mint phUSD ---");

        uint256 mintAmount = 500 * 10**6; // 500 USDT each

        // User1 mints
        vm.startBroadcast(user1Key);
        usdt.approve(address(minter), mintAmount);
        minter.mint(address(usdt), mintAmount);
        vm.stopBroadcast();
        console.log("User1 minted phUSD. Balance:", phUSD.balanceOf(user1));

        // User2 mints
        vm.startBroadcast(user2Key);
        usdt.approve(address(minter), mintAmount);
        minter.mint(address(usdt), mintAmount);
        vm.stopBroadcast();
        console.log("User2 minted phUSD. Balance:", phUSD.balanceOf(user2));
    }

    function _step3_stakeInPhlimbo() internal {
        console.log("\n--- Step 3: Both Users Stake in Phlimbo ---");

        // User1 stakes 300 phUSD
        uint256 stake1 = 300 * 10**18;
        vm.startBroadcast(user1Key);
        phUSD.approve(address(phlimbo), stake1);
        phlimbo.stake(stake1, user1);
        vm.stopBroadcast();
        console.log("User1 staked:", stake1 / 1e18, "phUSD");

        // User2 stakes 200 phUSD
        uint256 stake2 = 200 * 10**18;
        vm.startBroadcast(user2Key);
        phUSD.approve(address(phlimbo), stake2);
        phlimbo.stake(stake2, user2);
        vm.stopBroadcast();
        console.log("User2 staked:", stake2 / 1e18, "phUSD");

        console.log("\nTotal staked in Phlimbo:", phlimbo.totalStaked() / 1e18, "phUSD");
        console.log("User1 share: 60%");
        console.log("User2 share: 40%");
    }

    function _step4_simulateYield() internal {
        console.log("\n--- Step 4: Simulating Yield in Strategies ---");

        // Add 500 USDT yield
        uint256 usdtYield = 500 * 10**6;
        // Add 500 USDS yield
        uint256 usdsYield = 500 * 10**18;

        vm.startBroadcast(user1Key);

        // First, transfer actual tokens to the strategies so they can be withdrawn
        // The strategies need actual tokens, not just accounting entries
        usdt.transfer(address(ysUSDT), usdtYield);
        usds.transfer(address(ysUSDS), usdsYield);

        // Then add the yield to the internal accounting
        ysUSDT.addYield(address(usdt), address(minter), usdtYield);
        ysUSDS.addYield(address(usds), address(minter), usdsYield);

        vm.stopBroadcast();

        console.log("Added 500 USDT yield to YieldStrategyUSDT");
        console.log("Added 500 USDS yield to YieldStrategyUSDS");
        console.log("Total yield: ~1000 USD equivalent");
    }

    function _step5_injectRewards() internal {
        console.log("\n--- Step 5: Inject Rewards via collectReward ---");

        // Simulate external reward injection into Phlimbo
        // In the new architecture, rewards are injected directly via collectReward()
        uint256 rewardAmount = 500 * 10**6; // 500 USDC

        console.log("Injecting USDC rewards into Phlimbo...");
        console.log("Phlimbo USDC before:", usdc.balanceOf(address(phlimbo)));

        vm.startBroadcast(user1Key);
        // Approve Phlimbo to pull USDC from user1
        usdc.approve(address(phlimbo), rewardAmount);
        // Transfer and collect reward - anyone can inject rewards
        usdc.transfer(address(phlimbo), rewardAmount);
        // Call collectReward to update internal accounting
        phlimbo.collectReward(rewardAmount);
        vm.stopBroadcast();

        console.log("\n--- After Reward Injection ---");
        console.log("Phlimbo USDC after:", usdc.balanceOf(address(phlimbo)));
        console.log("Rewards injected:", rewardAmount, "USDC");
    }

    function _step6_claimPhlimboRewards() internal {
        console.log("\n--- Step 6: Check and Claim Phlimbo Rewards ---");

        // Fast forward time to allow rewards to accumulate
        // Phlimbo uses EMA smoothing, so rewards need time to become claimable
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200); // ~1 day of blocks at 12s/block

        console.log("Fast-forwarded 1 day for reward accumulation");

        // Check pending rewards
        uint256 user1PhUSDPending = phlimbo.pendingPhUSD(user1);
        uint256 user1StablePending = phlimbo.pendingStable(user1);
        uint256 user2PhUSDPending = phlimbo.pendingPhUSD(user2);
        uint256 user2StablePending = phlimbo.pendingStable(user2);

        console.log("\nPending rewards:");
        console.log("User1 - phUSD:", user1PhUSDPending, "Stablecoin:", user1StablePending);
        console.log("User2 - phUSD:", user2PhUSDPending, "Stablecoin:", user2StablePending);

        // Get balances before
        uint256 u1PhUSDBefore = phUSD.balanceOf(user1);
        uint256 u2PhUSDBefore = phUSD.balanceOf(user2);
        uint256 u1USDCBefore = usdc.balanceOf(user1);
        uint256 u2USDCBefore = usdc.balanceOf(user2);

        // User1 claims (withdraw 0 to just claim rewards)
        vm.startBroadcast(user1Key);
        phlimbo.withdraw(0);
        vm.stopBroadcast();

        // User2 claims
        vm.startBroadcast(user2Key);
        phlimbo.withdraw(0);
        vm.stopBroadcast();

        console.log("\n--- After Claiming Phlimbo Rewards ---");
        console.log("User1 phUSD gained:", phUSD.balanceOf(user1) - u1PhUSDBefore);
        console.log("User1 USDC gained:", usdc.balanceOf(user1) - u1USDCBefore);
        console.log("User2 phUSD gained:", phUSD.balanceOf(user2) - u2PhUSDBefore);
        console.log("User2 USDC gained:", usdc.balanceOf(user2) - u2USDCBefore);

        // Final summary
        console.log("\n--- Final State ---");
        console.log("User1 total phUSD:", phUSD.balanceOf(user1));
        console.log("User2 total phUSD:", phUSD.balanceOf(user2));
        console.log("Phlimbo remaining USDC:", usdc.balanceOf(address(phlimbo)));
    }
}
