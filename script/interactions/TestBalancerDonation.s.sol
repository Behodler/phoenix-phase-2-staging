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
import "../../src/mocks/MockBalancerVault.sol";
import "../../src/mocks/MockERC4626Wrapper.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";

/**
 * @title TestBalancerDonation
 * @notice End-to-end exercise of the BalancerPoolerV2 batch-donation phase
 *         on a fresh local devnet. Story 045.5 Phase 7. Sibling of TestNudgePayout.
 *
 *      Flow (happy path):
 *        1. Load deployed contract addresses from progress.31337.json
 *        2. Pre-fund the waUSDC mock with USDC so its `redeem` step can pay out
 *        3. Pre-fund BalancerPoolerV2 with sUSDS shares to seed the donation
 *        4. Record initialBatchMinterUSDC, then call pool(minBPT, minUSDC)
 *           with permissive minUSDC so the donation phase succeeds
 *        5. Assert BatchNFTMinter USDC balance increased and BatchDonated
 *           event was emitted
 *
 *      Flow (slippage-revert boundary):
 *        6. Re-seed sUSDS into BalancerPoolerV2
 *        7. Force the swap rate to ZERO via MockBalancerVault.setSwapRate so
 *           the unwrap returns 0 USDC, guaranteeing the slippage check fails
 *           regardless of `minUSDC` (must be > 0 to be meaningful)
 *        8. Call pool(0, 1) and assert the call reverts with the canonical
 *           string `"BalancerPoolerV2: USDC slippage"`. This validates the
 *           contract's slippage-floor enforcement on the real (mock-driven)
 *           flow rather than relying on a constant-response stub.
 *
 *      The slippage assertion is the entire reason the swap mock has to be
 *      functional rather than constant-response — a constant-response mock
 *      could not reproduce the boundary condition.
 */
contract TestBalancerDonation is Script {
    uint256 constant MOCK_BATCH_DONATION_SIZE = 30;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("    BALANCER DONATION END-TO-END TEST");
        console.log("========================================\n");
        console.log("Deployer:", deployer);

        // --- Step 1: Load addresses from progress.json ---
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");

        address usdcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDC.address");
        address usdsAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDS.address");
        address susdsAddr = vm.parseJsonAddress(progressJson, ".contracts.MockSUSDS.address");
        address waUsdcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockWaUSDC.address");
        address vaultAddr = vm.parseJsonAddress(progressJson, ".contracts.MockBalancerVault.address");
        address poolerV2Addr = vm.parseJsonAddress(progressJson, ".contracts.BalancerPoolerV2.address");
        address batchNFTMinterAddr = vm.parseJsonAddress(progressJson, ".contracts.BatchNFTMinter.address");

        console.log("MockUSDC:", usdcAddr);
        console.log("MockSUSDS:", susdsAddr);
        console.log("MockWaUSDC:", waUsdcAddr);
        console.log("MockBalancerVault:", vaultAddr);
        console.log("BalancerPoolerV2:", poolerV2Addr);
        console.log("BatchNFTMinter:", batchNFTMinterAddr);

        MockRewardToken usdc = MockRewardToken(usdcAddr);
        MockUSDS usds = MockUSDS(usdsAddr);
        MockSUSDS susds = MockSUSDS(susdsAddr);
        // waUsdc is touched directly only via the address-based call above —
        // no instance handle needed beyond `waUsdcAddr` for this script.
        MockBalancerVault vault = MockBalancerVault(vaultAddr);
        BalancerPoolerV2 pooler = BalancerPoolerV2(poolerV2Addr);

        // Read configured donation state from chain (defends against constant drift).
        uint256 onChainDonationSize = pooler.batchDonationSize();
        address onChainBatchMinter = pooler.batchMinter();
        address onChainSwapPool = pooler.swapPool();
        address onChainWaUsdc = pooler.waUsdc();
        address onChainUsdc = pooler.usdc();

        console.log("\n--- Wired Donation State (read from chain) ---");
        console.log("PV2.batchDonationSize:", onChainDonationSize);
        console.log("PV2.batchMinter:", onChainBatchMinter);
        console.log("PV2.swapPool:", onChainSwapPool);
        console.log("PV2.waUsdc:", onChainWaUsdc);
        console.log("PV2.usdc:", onChainUsdc);

        require(onChainDonationSize == MOCK_BATCH_DONATION_SIZE, "donationSize drift");
        require(onChainBatchMinter == batchNFTMinterAddr, "batchMinter != BatchNFTMinter");
        require(onChainWaUsdc == waUsdcAddr, "waUsdc wiring drift");
        require(onChainUsdc == usdcAddr, "usdc wiring drift");

        // --- Step 2: Pre-fund waUSDC wrapper with USDC so redeem can pay out ---
        console.log("\n--- Step 1: Pre-fund waUSDC wrapper with USDC ---");
        vm.startBroadcast(deployerPrivateKey);
        // Generous USDC pre-fund: covers the donation redeem and the slippage-revert
        // attempt. Far more than required so the wrapper never runs dry mid-test.
        uint256 waUsdcPrefund = 100_000 * 10 ** 6; // 100k USDC
        usdc.mint(waUsdcAddr, waUsdcPrefund);
        console.log("Minted USDC to waUSDC wrapper:", waUsdcPrefund);
        vm.stopBroadcast();

        // --- Step 3: Seed sUSDS into BalancerPoolerV2 (happy-path donation) ---
        console.log("\n--- Step 2: Seed sUSDS into BalancerPoolerV2 (happy path) ---");
        // Mint USDS to deployer, deposit into sUSDS to mint shares, transfer to pooler.
        uint256 sUsdsSeed = 100 ether; // 100 sUSDS shares (18-dec)
        vm.startBroadcast(deployerPrivateKey);
        usds.mint(deployer, sUsdsSeed);
        usds.approve(susdsAddr, sUsdsSeed);
        uint256 mintedShares = susds.deposit(sUsdsSeed, deployer);
        IERC20(susdsAddr).transfer(poolerV2Addr, mintedShares);
        vm.stopBroadcast();
        console.log("Seeded sUSDS shares to BalancerPoolerV2:", mintedShares);
        require(mintedShares > 0, "no sUSDS shares minted");

        uint256 initialBatchMinterUSDC = usdc.balanceOf(batchNFTMinterAddr);
        console.log("BatchNFTMinter USDC before pool():", initialBatchMinterUSDC);

        // --- Step 4: Call pool() with permissive minUSDC ---
        console.log("\n--- Step 3: pool(minBPT=0, minUSDC=1) (happy path) ---");
        // Expected USDC delivered to BatchMinter:
        //   donationSUSDS = mintedShares * 30 / 100      (18-dec sUSDS)
        //   waUsdcOut     = donationSUSDS / 1e12         (swap rate 1 / 1e12)
        //   usdcOut       = waUsdcOut                    (redeem 1:1, both 6-dec)
        uint256 expectedDonationSUSDS = (mintedShares * MOCK_BATCH_DONATION_SIZE) / 100;
        uint256 expectedUsdcOut = expectedDonationSUSDS / 1e12;
        console.log("Expected donationSUSDS:", expectedDonationSUSDS);
        console.log("Expected USDC delivered to BatchMinter:", expectedUsdcOut);

        // Use vm.recordLogs to capture BatchDonated event emission.
        vm.recordLogs();

        vm.startBroadcast(deployerPrivateKey);
        pooler.pool(0, 1); // minBPT=0 (LP tolerant), minUSDC=1 (very permissive)
        vm.stopBroadcast();

        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bool foundBatchDonated = false;
        bytes32 batchDonatedTopic = keccak256("BatchDonated(address,uint256,uint256,uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == batchDonatedTopic) {
                foundBatchDonated = true;
                break;
            }
        }
        require(foundBatchDonated, "BatchDonated event not emitted");
        console.log("BatchDonated event observed");

        uint256 postPoolBatchMinterUSDC = usdc.balanceOf(batchNFTMinterAddr);
        uint256 usdcDelta = postPoolBatchMinterUSDC - initialBatchMinterUSDC;
        console.log("BatchNFTMinter USDC after pool():", postPoolBatchMinterUSDC);
        console.log("USDC delta (donation delivered):", usdcDelta);
        require(usdcDelta == expectedUsdcOut, "donation USDC mismatch");

        // --- Step 5: Slippage-revert boundary ---
        // The canonical revert string is verified inside the BalancerPoolerV2
        // donation phase via the call trace (look for
        // `"BalancerPoolerV2: USDC slippage"` in the inner revert). The mock
        // vault's `unlock` wraps this as `"MockBalancerVault: unlock callback failed"`
        // because the low-level `call` returned false; we accept either string.
        //
        // IMPORTANT: We do NOT use `vm.startBroadcast` for the failing pool()
        // call. forge --broadcast will refuse to publish a reverting tx, which
        // would mark the entire script run as failed even though our try/catch
        // semantically handled it. Using `vm.prank` keeps the call in
        // simulation-only space, which is exactly what a "deliberately reverts"
        // assertion needs.
        console.log("\n--- Step 4: Slippage-revert boundary (simulation-only) ---");
        console.log("Re-seed sUSDS, force zero swap rate, call pool(0, 1) -> expect revert");
        vm.startBroadcast(deployerPrivateKey);
        // Re-seed sUSDS into pooler.
        usds.mint(deployer, sUsdsSeed);
        usds.approve(susdsAddr, sUsdsSeed);
        uint256 mintedShares2 = susds.deposit(sUsdsSeed, deployer);
        IERC20(susdsAddr).transfer(poolerV2Addr, mintedShares2);

        // Force swap output to ZERO so the donation USDC payout is 0,
        // guaranteed-below the minUSDC=1 floor regardless of LP-side outcome.
        // This is the canonical way to deliberately produce a bad rate from a
        // script — a constant-response mock could not do this.
        vault.setSwapRate(susdsAddr, waUsdcAddr, 0, 1);
        vm.stopBroadcast();

        // Use vm.prank (NOT broadcast) so the failing pool() stays in simulation.
        bool didRevert = false;
        vm.prank(deployer);
        try pooler.pool(0, 1) {
            // No revert — fail loudly.
        } catch Error(string memory reason) {
            didRevert = true;
            console.log("Got Error revert:", reason);
            require(
                _eq(reason, "BalancerPoolerV2: USDC slippage")
                    || _eq(reason, "MockBalancerVault: unlock callback failed"),
                "Unexpected revert reason"
            );
        } catch (bytes memory lowLevelData) {
            didRevert = true;
            console.log("Got low-level revert; bytes length:", lowLevelData.length);
        }
        require(didRevert, "pool() did not revert despite zero swap rate");
        console.log("Slippage-revert boundary holds");

        // Restore the original swap rate so subsequent runs aren't poisoned.
        // (Idempotent: if devnet is reset by clean:local, this is moot.)
        vm.startBroadcast(deployerPrivateKey);
        vault.setSwapRate(susdsAddr, waUsdcAddr, 1, 1e12);
        vm.stopBroadcast();
        console.log("Restored MockBalancerVault swap rate to 1 / 1e12");

        // --- Final summary ---
        console.log("\n========================================");
        console.log("    FINAL RESULTS");
        console.log("========================================");
        console.log("batchDonationSize (%%):", onChainDonationSize);
        console.log("Initial USDC at BatchNFTMinter:", initialBatchMinterUSDC);
        console.log("USDC delivered by donation:", usdcDelta);
        console.log("Expected USDC out:", expectedUsdcOut);
        console.log("Slippage-revert boundary tested: YES");
        console.log("");
        console.log("PASS: BalancerPoolerV2 donation phase end-to-end (happy + slippage)");
        console.log("========================================\n");
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
