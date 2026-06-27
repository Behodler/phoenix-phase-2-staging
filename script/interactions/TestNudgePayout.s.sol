// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "../../src/mocks/MockDola.sol";
import "../../src/mocks/MockEYE.sol";
import "../../src/mocks/MockRewardToken.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {ITokenMinterV2} from "@yield-claim-nft/interfaces/ITokenMinterV2.sol";

/**
 * @title TestNudgePayout
 * @notice End-to-end exercise of the nudge payout flow on a fresh local devnet.
 * @dev Story 045.5. Modelled on TestNFTMintAndClaimFlow.s.sol.
 *
 *      Flow:
 *        1. Load deployed contract addresses from progress.31337.json
 *        2. Top up DOLA + USDC yield in the strategy vaults so claim() always has
 *           fresh yield to forward (defensive top-up; deploy already seeds 1000 each)
 *        3. Mint a V2 NFT at BurnerEYEV2 (index 1) so the deployer holds an NFT
 *           the SYA will accept as claim gate
 *        4. Record initialNudgeBalance := USDC.balanceOf(BatchNFTMinter)
 *        5. Approve SYA to pull USDC, call claim(1, 0, []) — splits the discounted
 *           USDC payment: 30% (nudgeSplit) → BatchNFTMinter, 70% → Phlimbo
 *        6. Assert nudgeDelta := USDC.balanceOf(BatchNFTMinter) - initialNudgeBalance > 0
 *        7. Pre-fund deployer with EYE, approve BatchNFTMinter to spend EYE,
 *           call batchMint(NFTMinterV2, EYE, 1, MOCK_NUDGE_SIZE+1, vm.addr(2), payment)
 *           — count exceeds nudgeSize threshold so the helper sweeps its USDC balance
 *           to the recipient
 *        8. Assert recipient (vm.addr(2)) USDC balance == nudgeDelta (full sweep)
 *        9. Console-log a summary block
 *
 *      Constraints:
 *        - nudgePaymentToken (USDC) != paymentToken (EYE) — the BatchNFTMinter
 *          guard at lib/nft-staking/src/BatchNFTMinter.sol:122-126 holds.
 *        - Recipient is vm.addr(2) (deterministic non-deployer key) so the
 *          balance assertion compares fresh balances.
 */
contract TestNudgePayout is Script {
    // Mirror DeployMocks constants — keep in sync if the dev devnet tunes them.
    uint256 constant MOCK_NUDGE_SPLIT = 30;
    uint256 constant MOCK_NUDGE_SIZE = 3;

    // BurnerEYEV2 is registered at index 1 on NFTMinterV2 (see DeployMocks Phase 3.6).
    uint256 constant BURNER_EYE_V2_INDEX = 1;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address recipient = vm.addr(2);

        console.log("\n========================================");
        console.log("    NUDGE PAYOUT END-TO-END TEST");
        console.log("========================================\n");
        console.log("Deployer:", deployer);
        console.log("Recipient (vm.addr(2)):", recipient);

        // --- Step 1: Load addresses from progress.json ---
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");

        address usdcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDC.address");
        address dolaAddr = vm.parseJsonAddress(progressJson, ".contracts.MockDola.address");
        address eyeAddr = vm.parseJsonAddress(progressJson, ".contracts.MockEYE.address");
        address mockAutoDolaAddr = vm.parseJsonAddress(progressJson, ".contracts.MockAutoDOLA.address");
        address mockAutoUsdcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockAutoUSDC.address");
        address accumulatorAddr = vm.parseJsonAddress(progressJson, ".contracts.StableYieldAccumulator.address");
        address nftMinterV2Addr = vm.parseJsonAddress(progressJson, ".contracts.NFTMinterV2.address");
        address batchNFTMinterAddr = vm.parseJsonAddress(progressJson, ".contracts.BatchNFTMinter.address");

        console.log("MockUSDC:", usdcAddr);
        console.log("MockEYE:", eyeAddr);
        console.log("StableYieldAccumulator:", accumulatorAddr);
        console.log("NFTMinterV2:", nftMinterV2Addr);
        console.log("BatchNFTMinter:", batchNFTMinterAddr);

        MockRewardToken usdc = MockRewardToken(usdcAddr);
        MockDola dola = MockDola(dolaAddr);
        MockEYE eye = MockEYE(eyeAddr);
        StableYieldAccumulator accumulator = StableYieldAccumulator(accumulatorAddr);
        NFTMinterV2 nftMinterV2 = NFTMinterV2(nftMinterV2Addr);
        BatchNFTMinter batchNFTMinter = BatchNFTMinter(batchNFTMinterAddr);

        // Read configured nudge state from chain to keep this script robust
        // to constant tuning in DeployMocks.
        uint256 onChainNudgeSplit = accumulator.nudgeSplit();
        address onChainNudgeAddr = accumulator.nudge();
        uint256 onChainNudgeSize = batchNFTMinter.nudgeSize();
        address onChainNudgeToken = batchNFTMinter.nudgePaymentToken();

        console.log("\n--- Wired Nudge State (read from chain) ---");
        console.log("SYA.nudgeSplit:", onChainNudgeSplit);
        console.log("SYA.nudge:", onChainNudgeAddr);
        console.log("BatchNFTMinter.nudgeSize:", onChainNudgeSize);
        console.log("BatchNFTMinter.nudgePaymentToken:", onChainNudgeToken);

        require(onChainNudgeSplit == MOCK_NUDGE_SPLIT, "nudgeSplit drift vs constant");
        require(onChainNudgeAddr == address(batchNFTMinter), "nudge != BatchNFTMinter");
        require(onChainNudgeSize == MOCK_NUDGE_SIZE, "nudgeSize drift vs constant");
        require(onChainNudgeToken == address(usdc), "nudgePaymentToken != USDC");

        // --- Step 2: Top up vault yield (mirror simulate-yield.sh, defensive) ---
        console.log("\n--- Step 1: Top Up Yield ---");
        vm.startBroadcast(deployerPrivateKey);
        // Mint DOLA directly to MockAutoDOLA: inflates totalAssets without minting shares.
        dola.mint(mockAutoDolaAddr, 500 * 10 ** 18);
        console.log("Minted 500 DOLA directly to MockAutoDOLA (yield top-up)");
        // Same pattern for USDC into MockAutoUSDC (6 decimals).
        usdc.mint(mockAutoUsdcAddr, 500 * 10 ** 6);
        console.log("Minted 500 USDC directly to MockAutoUSDC (yield top-up)");
        vm.stopBroadcast();

        // --- Step 3: Mint a V2 NFT at index 1 (BurnerEYEV2) for the claim gate ---
        console.log("\n--- Step 2: Mint V2 NFT (BurnerEYEV2 index 1) ---");
        uint256 mintPrice = nftMinterV2.getPrice(BURNER_EYE_V2_INDEX);
        console.log("V2 NFT mint price (EYE):", mintPrice);

        vm.startBroadcast(deployerPrivateKey);
        // Mint enough EYE for the claim-gate NFT plus the later batchMint loop.
        // batchMint count = MOCK_NUDGE_SIZE + 1 mints, prices ramp at 2% growth.
        // Allocate generous headroom; surplus is refunded by BatchNFTMinter.
        uint256 totalEyeBudget = mintPrice * (MOCK_NUDGE_SIZE + 5);
        eye.mint(deployer, totalEyeBudget);
        console.log("Minted EYE budget to deployer:", totalEyeBudget);

        eye.approve(nftMinterV2Addr, mintPrice);
        bool minted = nftMinterV2.mint(BURNER_EYE_V2_INDEX, deployer);
        require(minted, "mint() returned false");
        vm.stopBroadcast();

        uint256 nftBalance = IERC1155(nftMinterV2Addr).balanceOf(deployer, BURNER_EYE_V2_INDEX);
        console.log("Deployer NFT balance (id=1):", nftBalance);
        require(nftBalance >= 1, "NFT not minted");

        // --- Step 4: Record initial nudge balance ---
        uint256 initialNudgeBalance = usdc.balanceOf(batchNFTMinterAddr);
        console.log("\n--- Step 3: Record Initial Nudge Balance ---");
        console.log("BatchNFTMinter USDC balance before claim:", initialNudgeBalance);

        // --- Step 5: Approve USDC and claim ---
        console.log("\n--- Step 4: Claim (split routes nudge%% to BatchNFTMinter) ---");
        uint256 claimAmount = accumulator.calculateClaimAmount(new address[](0));
        console.log("Calculated claim payment (USDC):", claimAmount);

        // Make sure deployer has enough USDC for the claim payment.
        vm.startBroadcast(deployerPrivateKey);
        if (usdc.balanceOf(deployer) < claimAmount) {
            usdc.mint(deployer, claimAmount);
            console.log("Topped up deployer USDC to cover claim payment");
        }
        usdc.approve(accumulatorAddr, type(uint256).max);
        accumulator.claim(BURNER_EYE_V2_INDEX, 0, new address[](0));
        vm.stopBroadcast();

        uint256 postClaimNudgeBalance = usdc.balanceOf(batchNFTMinterAddr);
        uint256 nudgeDelta = postClaimNudgeBalance - initialNudgeBalance;
        console.log("BatchNFTMinter USDC balance after claim:", postClaimNudgeBalance);
        console.log("Nudge delta (split routed to BatchNFTMinter):", nudgeDelta);
        require(nudgeDelta > 0, "nudge split did not route any USDC to BatchNFTMinter");
        // The split is computed on `actualPayment * nudgeSplit / 100` in SYA, where
        // actualPayment may differ from `claimAmount` if other interactions happen.
        // Sanity-check the proportional invariant: nudgeDelta * 100 / nudgeSplit == actualPayment.
        // We don't have a direct "actualPayment" value, so we settle for nudgeDelta > 0.

        // --- Step 6: batchMint with count >= nudgeSize triggers the sweep ---
        console.log("\n--- Step 5: batchMint to trigger nudge sweep ---");
        uint256 batchCount = MOCK_NUDGE_SIZE + 1;

        // Sum prices across the batchCount iterations (price ramps at 2% growth on V2 BurnerEYEV2).
        // Re-read the ramped price from chain after the earlier mint.
        uint256 currentPrice = nftMinterV2.getPrice(BURNER_EYE_V2_INDEX);
        uint256 paymentBudget = currentPrice * batchCount * 110 / 100; // 10% headroom
        console.log("Current V2 mint price:", currentPrice);
        console.log("Batch count:", batchCount);
        console.log("Payment budget (EYE):", paymentBudget);

        // Verify recipient starts at 0 USDC for a clean assertion.
        uint256 recipientUsdcBefore = usdc.balanceOf(recipient);
        console.log("Recipient USDC before sweep:", recipientUsdcBefore);

        vm.startBroadcast(deployerPrivateKey);
        // Make sure deployer has enough EYE for the budget.
        if (eye.balanceOf(deployer) < paymentBudget) {
            eye.mint(deployer, paymentBudget);
        }
        eye.approve(batchNFTMinterAddr, paymentBudget);
        // batchMint was hardened: nftMinter/paymentToken/dispatcherIndex are now read
        // from contract state (set during deploy), plus a minReward slippage bound.
        // minReward = 0 here: local anvil test exercising the payout path.
        batchNFTMinter.batchMint(
            batchCount,
            recipient,
            paymentBudget,
            0
        );
        vm.stopBroadcast();

        // --- Step 7: Assert sweep ---
        uint256 recipientUsdcAfter = usdc.balanceOf(recipient);
        uint256 sweptToRecipient = recipientUsdcAfter - recipientUsdcBefore;
        uint256 batchMinterUsdcAfter = usdc.balanceOf(batchNFTMinterAddr);
        console.log("\n--- Step 6: Verify Sweep ---");
        console.log("Recipient USDC after sweep:", recipientUsdcAfter);
        console.log("Swept to recipient (delta):", sweptToRecipient);
        console.log("BatchNFTMinter USDC residual:", batchMinterUsdcAfter);

        // BatchNFTMinter.batchMint sweeps its FULL USDC balance to recipient when count >= nudgeSize.
        // sweptToRecipient must equal postClaimNudgeBalance (the entire pre-batchMint USDC balance,
        // including any pre-existing residual, not just our nudgeDelta).
        require(sweptToRecipient == postClaimNudgeBalance, "Sweep did not match BatchNFTMinter pre-batch balance");
        require(batchMinterUsdcAfter == 0, "BatchNFTMinter retained USDC after sweep");

        // Recipient ERC1155 balance also bumped by batchCount.
        uint256 recipientNftBalance = IERC1155(nftMinterV2Addr).balanceOf(recipient, BURNER_EYE_V2_INDEX);
        console.log("Recipient NFT balance (id=1):", recipientNftBalance);
        require(recipientNftBalance >= batchCount, "Recipient did not receive minted NFTs");

        // --- Final summary ---
        console.log("\n========================================");
        console.log("    FINAL RESULTS");
        console.log("========================================");
        console.log("nudgeSplit (%%):", onChainNudgeSplit);
        console.log("nudgeSize threshold:", onChainNudgeSize);
        console.log("Claim payment (USDC):", claimAmount);
        console.log("Nudge routed to BatchNFTMinter:", nudgeDelta);
        console.log("Swept to recipient:", sweptToRecipient);
        console.log("Recipient:", recipient);
        console.log("");
        console.log("PASS: nudge end-to-end (claim split + batchMint sweep)");
        console.log("========================================\n");
    }
}
