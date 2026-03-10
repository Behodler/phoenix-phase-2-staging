// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "../../src/mocks/MockUSDS.sol";
import "../../src/mocks/MockRewardToken.sol";
import "../../src/mocks/MockAutoDOLA.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {NFTMinter} from "@yield-claim-nft/NFTMinter.sol";

/**
 * @title TestNFTMintAndClaimFlow
 * @notice End-to-end test of NFT minting via BalancerPooler dispatcher and yield claiming
 * @dev Flow:
 *      1. Load deployed contract addresses from progress.json
 *      2. Deployer approves NFTMinter to spend sUSDS
 *      3. Mint NFT via BalancerPooler dispatcher (index 3) using sUSDS
 *      4. Verify NFT balance is 1
 *      5. Advance time and accrue yield on MockAutoDola and MockAutoUSDC
 *      6. Approve StableYieldAccumulator to spend USDC for claim payment
 *      7. Claim yield on StableYieldAccumulator (burns NFT)
 *      8. Verify NFT balance is 0
 *      9. Console.log all results
 */
contract TestNFTMintAndClaimFlow is Script {
    // Struct for parsing progress.json contract entries
    struct ContractInfo {
        address addr;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("    NFT MINT AND CLAIM FLOW TEST");
        console.log("========================================\n");
        console.log("Deployer:", deployer);

        // Load contract addresses from progress.json
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");

        address nftMinterAddr = vm.parseJsonAddress(progressJson, ".contracts.NFTMinter.address");
        address usdsAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDS.address");
        address usdcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDC.address");
        address accumulatorAddr = vm.parseJsonAddress(progressJson, ".contracts.StableYieldAccumulator.address");
        address mockAutoDOLAAddr = vm.parseJsonAddress(progressJson, ".contracts.MockAutoDOLA.address");
        address mockAutoUSDCAddr = vm.parseJsonAddress(progressJson, ".contracts.MockAutoUSDC.address");

        console.log("NFTMinter:", nftMinterAddr);
        console.log("MockUSDS (sUSDS):", usdsAddr);
        console.log("MockUSDC:", usdcAddr);
        console.log("StableYieldAccumulator:", accumulatorAddr);

        NFTMinter nftMinter = NFTMinter(nftMinterAddr);
        MockUSDS usds = MockUSDS(usdsAddr);
        MockRewardToken usdc = MockRewardToken(usdcAddr);
        StableYieldAccumulator accumulator = StableYieldAccumulator(accumulatorAddr);
        MockAutoDOLA mockAutoDola = MockAutoDOLA(mockAutoDOLAAddr);
        MockAutoDOLA mockAutoUSDC = MockAutoDOLA(mockAutoUSDCAddr);

        // The BalancerPooler dispatcher is at index 3 (registered after BurnerEYE=1, BurnerSCX=2)
        uint256 balancerPoolerIndex = 3;

        // Get current NFT mint price for the BalancerPooler dispatcher
        uint256 mintPrice = nftMinter.getPrice(balancerPoolerIndex);
        console.log("\n--- Step 1: Approve & Mint NFT ---");
        console.log("BalancerPooler dispatcher index:", balancerPoolerIndex);
        console.log("Mint price (sUSDS):", mintPrice);

        // Record balances before
        uint256 usdsBalanceBefore = usds.balanceOf(deployer);
        uint256 usdcBalanceBefore = usdc.balanceOf(deployer);
        console.log("Deployer sUSDS balance before:", usdsBalanceBefore);
        console.log("Deployer USDC balance before:", usdcBalanceBefore);

        vm.startBroadcast(deployerPrivateKey);

        // Step 2: Approve NFTMinter to spend sUSDS
        usds.approve(nftMinterAddr, mintPrice);
        console.log("Approved NFTMinter to spend", mintPrice, "sUSDS");

        // Step 3: Mint NFT via BalancerPooler dispatcher (sUSDS single-sided add boosts phUSD price)
        nftMinter.mint(address(usds), balancerPoolerIndex, deployer);
        console.log("Minted 1 NFT via BalancerPooler dispatcher");

        vm.stopBroadcast();

        // Step 4: Verify NFT balance is 1
        // Token ID for dispatcher at index 3 (no override, so tokenId = index)
        uint256 nftTokenId = balancerPoolerIndex;
        uint256 nftBalance = IERC1155(nftMinterAddr).balanceOf(deployer, nftTokenId);
        console.log("\n--- Step 2: Verify NFT Balance ---");
        console.log("NFT token ID:", nftTokenId);
        console.log("Deployer NFT balance:", nftBalance);
        require(nftBalance == 1, "NFT balance should be 1 after minting");
        console.log("PASS: NFT balance is 1");

        uint256 usdsBalanceAfterMint = usds.balanceOf(deployer);
        console.log("Deployer sUSDS balance after mint:", usdsBalanceAfterMint);
        console.log("sUSDS spent on mint:", usdsBalanceBefore - usdsBalanceAfterMint);

        // Step 5: Advance time and accrue yield
        console.log("\n--- Step 3: Advance Time & Accrue Yield ---");
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 300);

        vm.startBroadcast(deployerPrivateKey);
        mockAutoDola.accrueYield();
        mockAutoUSDC.accrueYield();
        vm.stopBroadcast();

        console.log("Advanced time by 1 hour");
        console.log("Called accrueYield() on MockAutoDola and MockAutoUSDC");

        // Check pending yield
        uint256 totalYield = accumulator.getTotalYield();
        uint256 claimAmount = accumulator.calculateClaimAmount();
        console.log("Total normalized yield:", totalYield);
        console.log("Claim amount (USDC to pay):", claimAmount);

        // Step 6-8: Approve USDC and claim
        console.log("\n--- Step 4: Claim Yield (Burns NFT) ---");
        console.log("Deployer USDC balance before claim:", usdc.balanceOf(deployer));

        vm.startBroadcast(deployerPrivateKey);

        // Approve StableYieldAccumulator to spend deployer's USDC for claim payment
        usdc.approve(accumulatorAddr, type(uint256).max);
        console.log("Approved StableYieldAccumulator to spend USDC");

        // Claim yield - this burns 1 NFT and withdraws yield
        // nftIndex is the dispatcher config index (3 for BalancerPooler)
        // minRewardTokenSupplied = 0 for testing (no slippage protection)
        accumulator.claim(balancerPoolerIndex, 0);
        console.log("Called claim() on StableYieldAccumulator");

        vm.stopBroadcast();

        // Step 9: Verify NFT balance is 0
        uint256 nftBalanceAfterClaim = IERC1155(nftMinterAddr).balanceOf(deployer, nftTokenId);
        console.log("\n--- Step 5: Verify Results ---");
        console.log("NFT balance after claim:", nftBalanceAfterClaim);
        require(nftBalanceAfterClaim == 0, "NFT balance should be 0 after claim");
        console.log("PASS: NFT balance is 0 (burned during claim)");

        // Step 10: Log all final results
        uint256 usdsBalanceAfterClaim = usds.balanceOf(deployer);
        uint256 usdcBalanceAfterClaim = usdc.balanceOf(deployer);

        console.log("\n========================================");
        console.log("    FINAL RESULTS");
        console.log("========================================");
        console.log("sUSDS balance:  before=%d  afterMint=%d  afterClaim=%d", usdsBalanceBefore, usdsBalanceAfterMint, usdsBalanceAfterClaim);
        console.log("USDC balance:   before=%d  afterClaim=%d", usdcBalanceBefore, usdcBalanceAfterClaim);
        console.log("NFT balance:    afterMint=%d  afterClaim=%d", nftBalance, nftBalanceAfterClaim);
        console.log("Total yield claimed (normalized):", totalYield);
        console.log("USDC paid for claim:", claimAmount);
        console.log("");
        console.log("PASS: Full NFT mint and claim flow completed successfully!");
        console.log("========================================\n");
    }
}
