// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {NudgeDiscountMainnetBase} from "./helpers/NudgeDiscountMainnetBase.sol";

/**
 * @title VerifyNudgeDiscountMainnet  (story 119, sprint nudge-discount) - READ-ONLY POST-BROADCAST VERIFIER
 * @notice No --broadcast, no --sender, no prank / deal / warp / snapshot: reads LIVE mainnet and fails on the first
 *         violated invariant. Chained at the end of `nudge-discount:broadcast` (after the progress confirm, the
 *         book + PauserV2Registry patcher and `pauser-v2-verify`); re-run it any time as the post-119 health check.
 *
 *         The new minter comes from the COMPLETED progress file (env NUDGE_DISCOUNT_MINTER, if set, must agree), and
 *         the book's `NudgeDiscountBatchMinter` must equal it. Asserts (`_requireCutoverState`):
 *           - config: index 4, discountToken USDC, discountPercent 50, burnPercent 100, nftStaker, mintDebtHook, psm,
 *             sUSDS, router, pair/phUSD, OWNER an authorised buyer, nudge tokens USDC/phUSD/Kendu whitelisted;
 *           - the cutover gate: maxFreePerBatch / overflowNFTsPerBoostPoint / maxBoost == the script's gate constants
 *             (all non-zero) and boostDonationSafe() == true;
 *           - NFTMinter.authorizedMinters(new) == true and authorizedMinters(old) == false;
 *           - streams registered (USDC 10d, phUSD 30d, Kendu 30d) and nudgeStreamer set;
 *           - every inventoried donor (all NFTMinter dispatchers + the book's SYA) points at the new minter, none at
 *             the old one;
 *           - old minter paused, not registered with PauserV2, pauser() == OWNER, zero balance and zero buffers;
 *           - book Pauser == PauserV2, PauserV2.isRegistered(new), new.pauser() == PauserV2, health() clean;
 *           - pendingBuyUSDC and pendingStakerPhUSD printed (informational).
 *
 * Run: npm run nudge-discount:verify
 */
contract VerifyNudgeDiscountMainnet is NudgeDiscountMainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY nudge-discount cutover - MAINNET (story 119) - READ-ONLY");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "verify: wrong chain ID - expected Mainnet (1)");
        _requireGateConstants();
        _requireBookMatchesConstants();

        address recorded = _progressMinter();
        require(recorded != address(0), "verify: no minter in progress.nudge-discount.1.json - broadcast first");
        require(_progressCompleted(), "verify: progress.nudge-discount.1.json is not completed - run the confirm step");
        address envMinter = vm.envOr("NUDGE_DISCOUNT_MINTER", address(0));
        require(
            envMinter == address(0) || envMinter == recorded,
            "verify: NUDGE_DISCOUNT_MINTER != the progress file's minter"
        );
        require(
            _bookNewMinter() == recorded,
            "verify: address book NudgeDiscountBatchMinter != minter - run node scripts/patch-mainnet-addresses-nudge-discount.js"
        );
        console.log("NudgeDiscountBatchMinter:", recorded);

        _requireCutoverState(BatchNFTMinterNudgeDiscount(recorded));
        console.log("VERIFY OK");
    }
}
