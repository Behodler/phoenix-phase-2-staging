// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "@forge-std/Test.sol";
import {DeployMocksSepolia} from "../script/DeployMocksSepolia.s.sol";
import {NudgeDiscountMainnetBase} from "../script/helpers/NudgeDiscountMainnetBase.sol";

/// @dev Exposes the mainnet cutover's parameter constants (internal in the base).
contract NudgeDiscountMainnetParams is NudgeDiscountMainnetBase {
    function discountPercent() external pure returns (uint8) {
        return DISCOUNT_PERCENT;
    }

    function burnPercent() external pure returns (uint8) {
        return BURN_PERCENT;
    }

    function hookRatio() external pure returns (uint8) {
        return HOOK_RATIO;
    }

    function maxFreePerBatch() external pure returns (uint256) {
        return MAX_FREE_PER_BATCH;
    }

    function overflowNFTsPerBoostPoint() external pure returns (uint256) {
        return OVERFLOW_NFTS_PER_BOOST_POINT;
    }

    function day1MaxBoost() external pure returns (uint8) {
        return DAY1_MAX_BOOST;
    }

    function dispatcherIndex() external pure returns (uint256) {
        return DISPATCHER_INDEX;
    }

    function ratchetIndex() external pure returns (uint256) {
        return RATCHET_INDEX;
    }
}

/// @title DeployMocksSepoliaNudgeDiscountParamsTest
/// @notice Story 137: the Sepolia nudge-discount minter must carry the mainnet cutover's parameters
///         (`NudgeDiscountMainnetBase.sol` is the source of truth). A mainnet change not carried into
///         `DeployMocksSepolia` fails here. The stream duration is a documented Sepolia divergence and
///         is pinned to its own bound instead.
contract DeployMocksSepoliaNudgeDiscountParamsTest is Test {
    DeployMocksSepolia internal sepolia;
    NudgeDiscountMainnetParams internal mainnet;

    function setUp() public {
        sepolia = new DeployMocksSepolia();
        mainnet = new NudgeDiscountMainnetParams();
    }

    function test_parametersMatchTheMainnetCutover() public view {
        assertEq(sepolia.NUDGE_DISCOUNT_PERCENT(), mainnet.discountPercent(), "discount percent");
        assertEq(sepolia.NUDGE_DISCOUNT_BURN_PERCENT(), mainnet.burnPercent(), "burn percent");
        assertEq(sepolia.NUDGE_DISCOUNT_HOOK_RATIO(), mainnet.hookRatio(), "hook ratio");
        assertEq(sepolia.NUDGE_DISCOUNT_MAX_FREE_PER_BATCH(), mainnet.maxFreePerBatch(), "max free per batch");
        assertEq(
            sepolia.NUDGE_DISCOUNT_OVERFLOW_NFTS_PER_BOOST_POINT(),
            mainnet.overflowNFTsPerBoostPoint(),
            "overflow NFTs per boost point"
        );
        assertEq(sepolia.NUDGE_DISCOUNT_DAY1_MAX_BOOST(), mainnet.day1MaxBoost(), "day-1 max boost");
        assertEq(sepolia.RATCHET_INDEX(), mainnet.ratchetIndex(), "ratchet index");
        assertEq(mainnet.dispatcherIndex(), 4, "the Sepolia minter pins UNI_POOLER_INDEX (4)");
    }

    /// @dev The documented divergence: short enough that the seeded pot enables a batch within the first
    ///      hour (P0 = 10 USDS at index 4), non-zero (the streamer rejects 0).
    function test_sepoliaStreamIsShortAndPotSeedEnablesABatchWithinAnHour() public view {
        uint256 d = sepolia.SEPOLIA_NUDGE_DISCOUNT_STREAM_DURATION();
        assertGt(d, 0, "zero duration");
        assertLe(d, 1 days, "stream window must be <= 1 day on Sepolia");
        // USDC (6dp) streamed after one hour, in 18dp USD, over the 10 USDS index-4 price.
        uint256 usdAfterAnHour = sepolia.SEPOLIA_POT_USDC_SEED() * 1 hours / d * 1e12;
        assertGe(usdAfterAnHour / 10e18, 1, "free >= 1 within an hour of the seed");
        assertEq(sepolia.SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS(), 5, "5 pre-shutdown ratchets (story decision)");
    }
}
