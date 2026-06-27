// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/Vm.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../src/mocks/MockUSDS.sol";
import "../../src/mocks/MockSUSDS.sol";
import "../../src/mocks/MockRewardToken.sol";
import "../../src/mocks/MockSkyPSM.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/dispatchers/BalancerPoolerV2.sol";

/**
 * @title TestBalancerDonation
 * @notice End-to-end exercise of the BalancerPoolerV2 Sky-PSM batch-donation route on
 *         a fresh local devnet. Story 056 (rewritten from the story 045.5 swap-route
 *         version, which exercised the now-removed sUSDS->waUSDC Balancer swap donation
 *         and the two-arg `pool(minBPT, minUSDC)` signature).
 *
 *      The donation now lives inside the dispatcher's `_dispatch` (USDS -> USDC via the
 *      Sky PSM `buyGem`), isolated in a try/catch; `pool(uint256 minBPT)` is a pure LP
 *      add. Because `_dispatch` is internal and only reachable via a full NFTMinterV2
 *      mint, this script validates the wired Sky-route config and exercises the exact
 *      redeem->PSM->batchMinter path the contract uses, asserting USDC lands at the
 *      batch minter and the PSM math floors correctly (dust accrues to the protocol).
 *
 *      Flow:
 *        1. Load deployed contract addresses from progress.31337.json
 *        2. Assert the on-chain Sky-route config (psm, maxTout, batchDonationSize,
 *           batchMinter) matches what DeployMocks wired
 *        3. Drive the redeem(sUSDS)->USDS->PSM.buyGem(batchMinter)->USDC path with the
 *           same floored gemAmt math the contract uses, and assert batchMinter USDC
 *           increased by exactly the computed gemAmt
 */
contract TestBalancerDonation is Script {
    uint256 constant MOCK_BATCH_DONATION_SIZE = 30;
    uint256 constant WAD = 1e18;
    uint256 constant MAX_TOUT = 0.01e18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("  BALANCER POOLER SKY-PSM DONATION TEST");
        console.log("========================================\n");
        console.log("Deployer:", deployer);

        // --- Step 1: Load addresses from progress.json ---
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");

        address usdcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDC.address");
        address usdsAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDS.address");
        address susdsAddr = vm.parseJsonAddress(progressJson, ".contracts.MockSUSDS.address");
        address psmAddr = vm.parseJsonAddress(progressJson, ".contracts.MockSkyPSM.address");
        address poolerV2Addr = vm.parseJsonAddress(progressJson, ".contracts.BalancerPoolerV2.address");
        address batchNFTMinterAddr = vm.parseJsonAddress(progressJson, ".contracts.BatchNFTMinter.address");

        console.log("MockUSDC:", usdcAddr);
        console.log("MockUSDS:", usdsAddr);
        console.log("MockSUSDS:", susdsAddr);
        console.log("MockSkyPSM:", psmAddr);
        console.log("BalancerPoolerV2:", poolerV2Addr);
        console.log("BatchNFTMinter:", batchNFTMinterAddr);

        MockRewardToken usdc = MockRewardToken(usdcAddr);
        MockUSDS usds = MockUSDS(usdsAddr);
        MockSUSDS susds = MockSUSDS(susdsAddr);
        MockSkyPSM psm = MockSkyPSM(psmAddr);
        BalancerPoolerV2 pooler = BalancerPoolerV2(poolerV2Addr);

        // --- Step 2: Assert wired Sky-route donation config (defends against drift) ---
        uint256 onChainDonationSize = pooler.batchDonationSize();
        address onChainBatchMinter = pooler.batchMinter();
        address onChainPsm = pooler.psm();
        uint256 onChainMaxTout = pooler.maxTout();

        console.log("\n--- Wired Sky-route donation state (read from chain) ---");
        console.log("PV2.batchDonationSize:", onChainDonationSize);
        console.log("PV2.batchMinter:", onChainBatchMinter);
        console.log("PV2.psm:", onChainPsm);
        console.log("PV2.maxTout:", onChainMaxTout);

        require(onChainDonationSize == MOCK_BATCH_DONATION_SIZE, "donationSize drift");
        require(onChainBatchMinter == batchNFTMinterAddr, "batchMinter != BatchNFTMinter");
        require(onChainPsm == psmAddr, "psm wiring drift");
        require(onChainMaxTout == MAX_TOUT, "maxTout drift");

        // --- Step 3: Exercise the redeem -> PSM.buyGem -> batchMinter route ---
        console.log("\n--- Exercising redeem -> PSM.buyGem(batchMinter) -> USDC ---");

        // Seed deployer with sUSDS shares (deposit USDS into the ERC4626 wrapper).
        uint256 usdsSeed = 100 ether; // 100 USDS (18-dec)
        vm.startBroadcast(deployerPrivateKey);
        usds.mint(deployer, usdsSeed);
        usds.approve(susdsAddr, usdsSeed);
        uint256 shares = susds.deposit(usdsSeed, deployer);
        require(shares > 0, "no sUSDS shares minted");

        // Redeem the shares back to USDS (the donation slice the contract would carve).
        uint256 redeemedUsds = susds.redeem(shares, deployer, deployer);
        require(redeemedUsds > 0, "redeem returned 0 USDS");
        console.log("Redeemed USDS from sUSDS shares:", redeemedUsds);

        // Read the PSM fee/conv and size USDC out with the SAME floored math the
        // contract uses (dust accrues to the protocol, never over-credits).
        uint256 tout = psm.tout();
        require(tout <= MAX_TOUT, "tout above MAX_TOUT");
        uint256 conv = psm.to18ConversionFactor();
        uint256 gemAmt = (redeemedUsds * WAD) / (conv * (WAD + tout));
        require(gemAmt > 0, "donation dust");
        uint256 usdsSpent = gemAmt * conv * (WAD + tout) / WAD;
        console.log("tout:", tout);
        console.log("conv (to18ConversionFactor):", conv);
        console.log("gemAmt (USDC out, floored):", gemAmt);
        console.log("usdsSpent (<= redeemedUsds):", usdsSpent);
        require(usdsSpent <= redeemedUsds, "PSM would pull more USDS than available");

        uint256 initialBatchMinterUSDC = usdc.balanceOf(batchNFTMinterAddr);
        console.log("BatchNFTMinter USDC before buyGem:", initialBatchMinterUSDC);

        // forceApprove pattern: approve exact spend, buy, reset to 0.
        IERC20(usdsAddr).approve(psmAddr, usdsSpent);
        psm.buyGem(batchNFTMinterAddr, gemAmt);
        IERC20(usdsAddr).approve(psmAddr, 0);
        vm.stopBroadcast();

        uint256 postBatchMinterUSDC = usdc.balanceOf(batchNFTMinterAddr);
        uint256 usdcDelta = postBatchMinterUSDC - initialBatchMinterUSDC;
        console.log("BatchNFTMinter USDC after buyGem:", postBatchMinterUSDC);
        console.log("USDC delta (donation delivered):", usdcDelta);
        require(usdcDelta == gemAmt, "donation USDC mismatch");

        // --- Final summary ---
        console.log("\n========================================");
        console.log("    FINAL RESULTS");
        console.log("========================================");
        console.log("batchDonationSize (%%):", onChainDonationSize);
        console.log("Initial USDC at BatchNFTMinter:", initialBatchMinterUSDC);
        console.log("USDC delivered via Sky PSM:", usdcDelta);
        console.log("");
        console.log("PASS: BalancerPoolerV2 Sky-PSM donation route end-to-end");
        console.log("========================================\n");
    }
}
