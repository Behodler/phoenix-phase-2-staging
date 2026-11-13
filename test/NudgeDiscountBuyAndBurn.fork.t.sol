// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {DeployNudgeDiscountHarness, BuyAndBurnHarness} from "./helpers/NudgeDiscountHarnesses.sol";

interface INudgeStreamerBB {
    function pendingStream(address m, address t) external view returns (uint256);
}

/**
 * @title NudgeDiscountBuyAndBurnForkTest  (story 119, sprint nudge-discount)
 * @notice After the cutover simulation (the script's own deploy + configure + pot migration) and a discounted
 *         6-arg `batchMint` by a third party, runs `NudgeDiscountBuyAndBurn` against the fork-deployed minter through
 *         its virtual resolver, with the floor from the same route maths the quote helper uses. Asserts the split and
 *         the refusals: a floor more than 1% below the quote, a floor above it, a zero input, a non-OWNER broadcast
 *         sender, a de-authorised OWNER, and the zero book placeholder. Skipped without RPC_MAINNET.
 */
contract NudgeDiscountBuyAndBurnForkTest is Test {
    uint256 constant FORK_BLOCK = 26_403_500;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant NUDGE_STREAMER = 0xF7e26179D6971985107AF66b078932D6484eBEAA;
    address constant NFT_STAKER = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    string constant PROGRESS = "server/deployments/progress.nudge-discount.1.forktest-buyandburn.json";

    BatchNFTMinterNudgeDiscount m;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;
        if (vm.exists(PROGRESS)) vm.removeFile(PROGRESS);
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, PROGRESS, address(0));
        s.run();
        vm.removeFile(PROGRESS);
        m = s.minter();

        // Let the migrated pot stream for two days, then one discounted batch by a third party.
        vm.warp(block.timestamp + 2 days);
        address batcher = makeAddr("bb-batcher");
        deal(USDS, batcher, 1_000_000e18);
        vm.prank(batcher);
        IERC20(USDS).approve(address(m), type(uint256).max);
        (, uint256 total,, uint256 paidCost,,,) = m.previewBatch();
        (, uint8 boost,,) = m.previewBoost();
        assertGt(total, 0, "batchable after two days of stream");
        address[] memory bonusTokens = m.getBonusTokens();
        uint256[] memory floors = new uint256[](bonusTokens.length);
        for (uint256 i = 0; i < bonusTokens.length; i++) {
            floors[i] = IERC20(bonusTokens[i]).balanceOf(address(m))
                + INudgeStreamerBB(NUDGE_STREAMER).pendingStream(address(m), bonusTokens[i]);
        }
        vm.prank(batcher);
        m.batchMint(total, boost, batcher, paidCost, bonusTokens, floors);
        assertGt(m.pendingBuyUSDC(), 0, "batch reserved pot USDC");
        assertGt(m.pendingStakerPhUSD(), 0, "batch recorded owed phUSD");
    }

    function _harness(bool preview) internal returns (BuyAndBurnHarness h) {
        h = new BuyAndBurnHarness(address(m), preview);
    }

    function test_fork_buyAndBurn_split() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = _harness(true);
        uint256 usdcIn = m.pendingBuyUSDC();
        uint256 q = h.quote(usdcIn);
        uint256 owed = m.pendingStakerPhUSD();
        uint256 staker0 = IERC20(PHUSD).balanceOf(NFT_STAKER);
        uint256 supply0 = IERC20(PHUSD).totalSupply();
        h.setInputs(usdcIn, (q * 9950) / 10000); // the helper's default 50 bps
        h.run();
        uint256 out = h.lastPhusdOut();
        assertEq(out, q, "no trade in between: out == quote");
        uint256 owedPaid = out < owed ? out : owed;
        assertEq(h.lastToStaker(), owedPaid, "burnPercent 100: NFTStaker gets exactly the owed share");
        assertEq(h.lastBurned(), out - owedPaid, "the whole extra is burned");
        assertEq(IERC20(PHUSD).balanceOf(NFT_STAKER), staker0 + owedPaid);
        assertEq(IERC20(PHUSD).totalSupply(), supply0 - (out - owedPaid));
        assertEq(m.pendingBuyUSDC(), 0, "reserve drained");
        assertEq(m.pendingStakerPhUSD(), owed - owedPaid, "owed reserve reduced");
    }

    function test_fork_partialBuy() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = _harness(true);
        uint256 usdcIn = m.pendingBuyUSDC() / 2;
        h.setInputs(usdcIn, (h.quote(usdcIn) * 9990) / 10000);
        uint256 reserve = m.pendingBuyUSDC();
        h.run();
        assertEq(m.pendingBuyUSDC(), reserve - usdcIn);
    }

    function test_fork_refuses_floorMoreThanOnePercentBelowQuote() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = _harness(true);
        uint256 usdcIn = m.pendingBuyUSDC();
        h.setInputs(usdcIn, (h.quote(usdcIn) * 9899) / 10000);
        vm.expectRevert(
            bytes("quote: MIN_PHUSD_OUT_WEI more than MAX_TOLERANCE_BPS (1%) below the live quote - re-quote")
        );
        h.run();
    }

    function test_fork_refuses_floorAboveQuote() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = _harness(true);
        uint256 usdcIn = m.pendingBuyUSDC();
        h.setInputs(usdcIn, h.quote(usdcIn) + 1);
        vm.expectRevert(bytes("quote: MIN_PHUSD_OUT_WEI above the live quote - pair moved, re-quote"));
        h.run();
    }

    function test_fork_refuses_zeroInputs() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = _harness(true);
        h.setInputs(0, 1);
        vm.expectRevert(
            bytes("input: USDC_IN_WEI unset or zero (quote with scripts/quote-nudge-discount-buy-and-burn.js)")
        );
        h.run();
        h.setInputs(1, 0);
        vm.expectRevert(bytes("input: MIN_PHUSD_OUT_WEI unset or zero - refusing an unprotected swap"));
        h.run();
    }

    function test_fork_refuses_inputAboveReserve() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = _harness(true);
        h.setInputs(m.pendingBuyUSDC() + 1, 1);
        vm.expectRevert(bytes("preflight: USDC_IN_WEI exceeds pendingBuyUSDC"));
        h.run();
    }

    function test_fork_refuses_nonOwnerBroadcastSender() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = _harness(false);
        h.setSender(makeAddr("notTheBuyer"));
        h.setInputs(1, 1);
        vm.expectRevert(bytes("broadcast sender must be OWNER (--sender + Ledger)"));
        h.run();
    }

    function test_fork_refuses_deauthorisedBuyer() public {
        if (!forked) vm.skip(true);
        vm.prank(OWNER);
        m.incrementAuthVersion(); // the kill switch
        BuyAndBurnHarness h = _harness(true);
        uint256 usdcIn = m.pendingBuyUSDC();
        h.setInputs(usdcIn, (h.quote(usdcIn) * 9950) / 10000);
        vm.expectRevert(bytes("preflight: OWNER is not an authorised buyer (authVersion)"));
        h.run();
    }

    function test_fork_refuses_zeroBookPlaceholder() public {
        if (!forked) vm.skip(true);
        BuyAndBurnHarness h = new BuyAndBurnHarness(address(0), true); // production resolver: the real book
        h.setInputs(1, 1);
        vm.expectRevert(
            bytes(
                "preflight: mainnet-addresses.ts NudgeDiscountBatchMinter is the zero placeholder - run the cutover (nudge-discount:broadcast) first"
            )
        );
        h.run();
    }
}
