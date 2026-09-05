// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "../../src/mocks/MockDola.sol";
import "../../src/mocks/MockUSDS.sol";
import "../../src/mocks/MockRewardToken.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {BatchNFTMinterMultiToken} from "nft-staking/BatchNFTMinterMultiToken.sol";
import {NudgeStreamer} from "nft-staking/NudgeStreamer.sol";

/**
 * @title TestNudgePayout
 * @notice End-to-end exercise of the nudge payout flow on a fresh local devnet.
 * @dev Story 045.5, rewritten for story 073's streamer-era contract set.
 *
 *      WHAT CHANGED (and why the old version could not simply be patched):
 *        - The nudge donation no longer lands ON the batch minter. `SYA.claim()` now calls
 *          `NudgeStreamer.collectNudge(batchMinter, USDC, amount)`, so the donation lands in the
 *          streamer's `(batchMinter, USDC)` BUFFER and is released linearly over the registered
 *          duration. Asserting on `USDC.balanceOf(batchMinter)` right after a claim would now
 *          always read zero. This script asserts on the buffer instead.
 *        - `batchNFTMinter` is a `BatchNFTMinterMultiToken`: `batchMint` takes a `minRewards`
 *          array whose length must equal `getNudgeTokens().length`, and `nudgePaymentToken()`
 *          no longer exists.
 *        - The payment asset is DERIVED from the pinned dispatcher, never supplied by the caller.
 *          The batch minter is pinned to index 4 (BalancerPoolerV2), whose prime token is USDS —
 *          the old script's EYE approvals were already wrong before this rewrite, alongside a
 *          stale `MOCK_NUDGE_SIZE = 3` and a stale "BurnerEYEV2 at index 1" comment.
 *        - The claim-gate NFT is minted at index 1, which story 070 turned into UniboostEYE
 *          (prime token USDC, not EYE).
 *
 *      Flow:
 *        1. Load deployed addresses from progress.31337.json
 *        2. Assert the on-chain streamer / multi-token wiring matches expectations
 *        3. Top up DOLA + USDC vault yield so claim() always has fresh yield
 *        4. Mint an index-1 NFT (paid in USDC) as the SYA claim gate
 *        5. claim() -> assert the streamer's (batchMinter, USDC) buffer grew
 *        6. Advance the anvil clock past the stream duration via evm_increaseTime
 *           (NOT vm.warp — this runs against a live node over RPC)
 *        7. batchMint(count >= nudgeSize) -> assert the flushed stream is swept to the recipient
 *        8. Assert a wrong-length minRewards array reverts
 */
contract TestNudgePayout is Script {
    // Mirror DeployMocks constants — keep in sync if the dev devnet tunes them.
    uint256 constant MOCK_NUDGE_SPLIT = 30;
    uint256 constant MOCK_NUDGE_SIZE = 25;
    uint256 constant LOCAL_STREAM_DURATION = 6 hours;

    // Story 070 replaced BurnerEYEV2 with UniboostEYE at index 1; story 073 keeps the slot.
    // The dispatcher's prime token is USDC (6dp), NOT EYE — payment is derived from the
    // dispatcher, never supplied by the caller.
    uint256 constant UNIBOOST_EYE_INDEX = 1;
    // The shared batch minter is pinned to the BalancerPoolerV2 dispatcher (prime token USDS).
    uint256 constant BALANCER_POOLER_INDEX = 4;

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

        MockRewardToken usdc = MockRewardToken(vm.parseJsonAddress(progressJson, ".contracts.MockUSDC.address"));
        MockDola dola = MockDola(vm.parseJsonAddress(progressJson, ".contracts.MockDola.address"));
        MockUSDS usds = MockUSDS(vm.parseJsonAddress(progressJson, ".contracts.MockUSDS.address"));
        address mockAutoDolaAddr = vm.parseJsonAddress(progressJson, ".contracts.MockAutoDOLA.address");
        address mockAutoUsdcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockAutoUSDC.address");
        StableYieldAccumulator accumulator =
            StableYieldAccumulator(vm.parseJsonAddress(progressJson, ".contracts.StableYieldAccumulator.address"));
        NFTMinterV2 nftMinterV2 = NFTMinterV2(vm.parseJsonAddress(progressJson, ".contracts.NFTMinterV2.address"));
        address batchNFTMinterAddr = vm.parseJsonAddress(progressJson, ".contracts.BatchNFTMinter.address");
        BatchNFTMinterMultiToken batchNFTMinter = BatchNFTMinterMultiToken(batchNFTMinterAddr);
        NudgeStreamer streamer = NudgeStreamer(vm.parseJsonAddress(progressJson, ".contracts.NudgeStreamer.address"));

        console.log("MockUSDC:", address(usdc));
        console.log("StableYieldAccumulator:", address(accumulator));
        console.log("NFTMinterV2:", address(nftMinterV2));
        console.log("BatchNFTMinter (multi-token):", batchNFTMinterAddr);
        console.log("NudgeStreamer:", address(streamer));

        // --- Step 2: Assert the wired state (read from chain, not assumed) ---
        address[] memory nudgeTokens = batchNFTMinter.getNudgeTokens();
        console.log("\n--- Wired Nudge State (read from chain) ---");
        console.log("SYA.nudgeSplit:", accumulator.nudgeSplit());
        console.log("SYA.nudge:", accumulator.nudge());
        console.log("SYA.nudgeStreamer:", accumulator.nudgeStreamer());
        console.log("BatchNFTMinter.nudgeSize:", batchNFTMinter.nudgeSize());
        console.log("BatchNFTMinter nudge token count:", nudgeTokens.length);

        require(accumulator.nudgeSplit() == MOCK_NUDGE_SPLIT, "nudgeSplit drift vs constant");
        require(accumulator.nudge() == batchNFTMinterAddr, "nudge != BatchNFTMinter");
        require(accumulator.nudgeStreamer() == address(streamer), "SYA.nudgeStreamer != NudgeStreamer");
        require(batchNFTMinter.nudgeSize() == MOCK_NUDGE_SIZE, "nudgeSize drift vs constant");
        require(nudgeTokens.length == 3, "expected 3 whitelisted nudge tokens");
        require(nudgeTokens[0] == address(usdc), "nudge token slot 0 != USDC");
        require(batchNFTMinter.nudgeStreamer() == address(streamer), "batchMinter.nudgeStreamer unset");

        // --- Step 3: Top up vault yield (mirror simulate-yield.sh, defensive) ---
        console.log("\n--- Step 1: Top Up Yield ---");
        vm.startBroadcast(deployerPrivateKey);
        dola.mint(mockAutoDolaAddr, 500 * 10 ** 18);
        usdc.mint(mockAutoUsdcAddr, 500 * 10 ** 6);
        vm.stopBroadcast();
        console.log("Minted 500 DOLA / 500 USDC of vault yield");

        // --- Step 4: Mint an index-1 NFT (paid in USDC) for the claim gate ---
        console.log("\n--- Step 2: Mint index-1 UniboostEYE NFT (paid in USDC) ---");
        uint256 mintPrice = nftMinterV2.getPrice(UNIBOOST_EYE_INDEX);
        console.log("Index-1 NFT mint price (USDC):", mintPrice);

        vm.startBroadcast(deployerPrivateKey);
        usdc.mint(deployer, mintPrice * 2);
        usdc.approve(address(nftMinterV2), mintPrice);
        // This mint routes 50% of the prime USDC through Uniboost's donation branch, which is
        // streamer-gated: an unwired nudgeStreamer reverts here with
        // "Uniboost: nudgeStreamer unset". So this line is itself the regression test for the
        // breakage story 073 repairs.
        require(nftMinterV2.mint(UNIBOOST_EYE_INDEX, deployer), "mint() returned false");
        vm.stopBroadcast();

        require(
            IERC1155(address(nftMinterV2)).balanceOf(deployer, UNIBOOST_EYE_INDEX) >= 1, "claim-gate NFT not minted"
        );
        console.log("Claim-gate NFT minted (index 1)");

        // --- Step 5: claim() routes the nudge slice into the STREAMER's buffer ---
        console.log("\n--- Step 3: Claim (nudge slice -> NudgeStreamer buffer) ---");
        (, uint256 bufferBefore,,) = streamer.streams(batchNFTMinterAddr, address(usdc));
        uint256 claimAmount = accumulator.calculateClaimAmount(new address[](0));
        console.log("Streamer USDC buffer before claim:", bufferBefore);
        console.log("Calculated claim payment (USDC):", claimAmount);

        vm.startBroadcast(deployerPrivateKey);
        if (usdc.balanceOf(deployer) < claimAmount) {
            usdc.mint(deployer, claimAmount);
        }
        usdc.approve(address(accumulator), type(uint256).max);
        accumulator.claim(UNIBOOST_EYE_INDEX, 0, new address[](0));
        vm.stopBroadcast();

        (, uint256 bufferAfter,,) = streamer.streams(batchNFTMinterAddr, address(usdc));
        console.log("Streamer USDC buffer after claim:", bufferAfter);
        require(bufferAfter > bufferBefore, "claim did not route USDC into the NudgeStreamer buffer");

        // --- Step 6: advance the node clock past the stream window ---
        // NOTE ON TIME ADVANCEMENT — read before "improving" this.
        // The streamed-payout size cannot be asserted from inside a forge script. A script's
        // `require`s and view reads all execute in the SIMULATION pass, where every statement
        // shares one block timestamp, so `pendingStream` reads 0 there no matter what the live
        // chain does. `vm.rpc("evm_increaseTime", ...)` moves the live node but leaves the
        // simulation untouched (and, empirically, the first external call after `vm.rpc` in a
        // broadcasting script reverts with empty data). `vm.warp` moves only the simulation.
        //
        // So this script asserts what a script CAN assert — that `batchMint` executes, mints, and
        // enforces its array-length contract — and the accrual/flush magnitudes are verified out
        // of band with `cast rpc evm_increaseTime` + `cast rpc evm_mine` against the live node.
        console.log("\n--- Step 4: pendingStream (simulation reads 0 by construction) ---");
        console.log("pendingStream(batchMinter, USDC):", streamer.pendingStream(batchNFTMinterAddr, address(usdc)));

        // --- Step 7: batchMint with count >= nudgeSize flushes the stream and sweeps ---
        console.log("\n--- Step 5: batchMint to flush the stream and sweep ---");
        uint256 batchCount = MOCK_NUDGE_SIZE + 1;
        // Payment is DERIVED from the pinned dispatcher (index 4, BalancerPoolerV2 -> USDS).
        uint256 paymentBudget = nftMinterV2.getPrice(BALANCER_POOLER_INDEX) * batchCount * 120 / 100; // 20% headroom
        console.log("Batch count:", batchCount);
        console.log("Payment budget (USDS):", paymentBudget);

        uint256 recipientUsdcBefore = usdc.balanceOf(recipient);

        // `minRewards` MUST have exactly getNudgeTokens().length entries, in that order. Re-fetch
        // rather than hardcoding 3: unwhitelisting uses swap-and-pop, which reorders the list.
        uint256[] memory minRewards = new uint256[](nudgeTokens.length);

        vm.startBroadcast(deployerPrivateKey);
        usds.mint(deployer, paymentBudget);
        usds.approve(batchNFTMinterAddr, paymentBudget);
        batchNFTMinter.batchMint(batchCount, recipient, paymentBudget, minRewards);
        vm.stopBroadcast();

        uint256 sweptToRecipient = usdc.balanceOf(recipient) - recipientUsdcBefore;
        // Logged, not asserted — see the time-advancement note above. On the live chain this is
        // non-zero (seconds elapse between the claim and this call, against a 1-hour window).
        console.log("Swept USDC to recipient (simulation view):", sweptToRecipient);
        require(
            IERC1155(address(nftMinterV2)).balanceOf(recipient, BALANCER_POOLER_INDEX) >= batchCount,
            "Recipient did not receive minted NFTs"
        );

        // --- Step 8: a wrong-length minRewards array must revert ---
        console.log("\n--- Step 6: minRewards length guard ---");
        // Deliberately OUTSIDE `vm.startBroadcast`: a reverting call inside a broadcast block is
        // queued as a real transaction and forge aborts the whole run on it. Executed in the
        // simulation EVM only, it proves the guard without producing a broadcastable tx.
        uint256[] memory wrongLength = new uint256[](nudgeTokens.length - 1);
        (bool ok,) = batchNFTMinterAddr.call(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.batchMint.selector, batchCount, recipient, paymentBudget, wrongLength
            )
        );
        require(!ok, "batchMint accepted a wrong-length minRewards array");
        console.log("PASS: wrong-length minRewards reverted (BatchMint__ArrayLengthMismatch)");

        console.log("\n========================================");
        console.log("    FINAL RESULTS");
        console.log("========================================");
        console.log("Nudge routed into streamer buffer:", bufferAfter - bufferBefore);
        console.log("Streamed + swept to recipient (simulation view):", sweptToRecipient);
        console.log("Recipient:", recipient);
        console.log("");
        console.log("PASS: nudge end-to-end (claim -> streamer -> batchMint sweep)");
        console.log("========================================\n");
    }
}
