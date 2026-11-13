// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {NudgeDiscountMainnetBase} from "./helpers/NudgeDiscountMainnetBase.sol";

/**
 * @title NudgeDiscountBuyAndBurn  (story 119, sprint nudge-discount)
 * @notice ONE owner transaction: `BatchNFTMinterNudgeDiscount.buyAndBurn(usdcIn, minPhusdOut, deadline)` on the live
 *         nudge-discount minter. It spends reserved pot USDC (`pendingBuyUSDC`, reserved by discounted batches) along
 *         USDC -> Sky PSM `sellGem` -> USDS -> sUSDS `deposit` -> UniV2 sUSDS->phUSD on PhusdSusdsPair. The phUSD out
 *         first pays NFTStaker what it is owed for the free NFTs (`pendingStakerPhUSD`); the extra is split by
 *         `burnPercent` (100 at cutover) between a burn and NFTStaker.
 *
 *         WHY DEFERRED. A swap inside a user's `batchMint` could be sandwiched, so the buy is an authorised admin step
 *         with an off-chain floor (the MEV rule of docs/NFT/UniV2PriceTilting.md, mirroring `UniPoolerV2.pool`).
 *
 *         WHICH MINTER. `NudgeDiscountBatchMinter` from server/deployments/mainnet-addresses.ts (patched by the
 *         cutover). Refuses the ZERO placeholder, i.e. before the cutover is patched. Requires the minter's router and
 *         pair/phUSD to equal the book, its PSM and sUSDS to equal the pinned constants (no book key for the PSM), its
 *         nftStaker to equal the book, and OWNER to be an authorised buyer under the live `authVersion`.
 *
 *         INPUTS (all REQUIRED; CLAUDE.md "Configuration Safety"):
 *           USDC_IN_WEI        USDC (6dp) to spend; non-zero and <= pendingBuyUSDC
 *           MIN_PHUSD_OUT_WEI  floor on the phUSD bought; non-zero
 *           DEADLINE_SECS      optional, default 1800; added to the block timestamp
 *         Quote them in the SAME shell immediately before :preview and :broadcast, so both use identical floors:
 *             eval "$(node scripts/quote-nudge-discount-buy-and-burn.js all 50)"
 *         The script re-quotes the route live and requires the floor in [quote * (1 - 1%), quote]: above the quote
 *         the swap would revert anyway, and further below it no longer protects against a sandwich.
 *
 *         KILL SWITCH (independent of this script): `minter.incrementAuthVersion()` de-authorises every buyer.
 *         `buyAndBurn` is deliberately not pause-gated, so pausing the minter stops new reservations but still lets
 *         the reserve drain into phUSD.
 *
 *         NO FUNDS TO THE LEDGER: OWNER's USDC / phUSD / Kendu / USDS / sUSDS / EYE and claim-NFT balances must not
 *         rise (asserted), and ETH is non-increasing. No addresses change: no backup or patcher step.
 *
 * Preview:   npm run nudge-discount:buy-and-burn:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed)
 * Broadcast: npm run nudge-discount:buy-and-burn:broadcast   (Ledger m/44'/60'/46'/0/0)
 */
contract NudgeDiscountBuyAndBurn is NudgeDiscountMainnetBase {
    /// @dev Loosest floor accepted: 1% below the live quote. The quote helper caps its tolerance here.
    uint256 public constant MAX_TOLERANCE_BPS = 100;
    uint256 public constant DEFAULT_DEADLINE_SECS = 1800;

    /// @dev Results, read by the fork tests.
    uint256 public lastPhusdOut;
    uint256 public lastToStaker;
    uint256 public lastBurned;

    function run() external {
        console.log("=================================================");
        console.log("  NudgeDiscount buyAndBurn - MAINNET (story 119)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        bool isPreview = _previewModeFromEnv();
        console.log(isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed)" : "Mode: BROADCAST (Ledger)");
        if (!isPreview) require(_sender() == OWNER, "broadcast sender must be OWNER (--sender + Ledger)");

        (uint256 usdcIn, uint256 minOut, uint256 deadlineSecs) = _inputsFromEnv();
        require(
            usdcIn > 0, "input: USDC_IN_WEI unset or zero (quote with scripts/quote-nudge-discount-buy-and-burn.js)"
        );
        require(minOut > 0, "input: MIN_PHUSD_OUT_WEI unset or zero - refusing an unprotected swap");
        require(deadlineSecs > 0 && deadlineSecs <= 1 days, "input: DEADLINE_SECS must be in (0, 86400]");

        BatchNFTMinterNudgeDiscount m = BatchNFTMinterNudgeDiscount(_resolveMinter());
        _preflight(m);

        uint256 reserve = m.pendingBuyUSDC();
        require(reserve > 0, "preflight: pendingBuyUSDC is 0 - nothing reserved to buy with");
        require(usdcIn <= reserve, "preflight: USDC_IN_WEI exceeds pendingBuyUSDC");

        uint256 quote = _quoteRoute(m, usdcIn);
        require(quote > 0, "quote: live route quote is zero");
        require(minOut <= quote, "quote: MIN_PHUSD_OUT_WEI above the live quote - pair moved, re-quote");
        require(
            minOut >= (quote * (10000 - MAX_TOLERANCE_BPS)) / 10000,
            "quote: MIN_PHUSD_OUT_WEI more than MAX_TOLERANCE_BPS (1%) below the live quote - re-quote"
        );

        _logPre(m, usdcIn, minOut, quote, reserve);
        _snapshotOwnerBalances();
        _buy(m, usdcIn, minOut, deadlineSecs, reserve, isPreview);
        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast. Run nudge-discount:buy-and-burn:broadcast with the Ledger, same shell/env."
            );
        }
    }

    struct Before {
        uint256 reserve;
        uint256 owed;
        uint256 staker;
        uint256 supply;
    }

    function _logPre(BatchNFTMinterNudgeDiscount m, uint256 usdcIn, uint256 minOut, uint256 quote, uint256 reserve)
        internal
        view
    {
        console.log("  minter              :", address(m));
        console.log("  USDC_IN_WEI         :", usdcIn);
        console.log("  MIN_PHUSD_OUT_WEI   :", minOut);
        console.log("  live route quote    :", quote);
        console.log("  pendingBuyUSDC      :", reserve);
        console.log("  pendingStakerPhUSD  :", m.pendingStakerPhUSD());
        console.log("  NFTStaker phUSD     :", IERC20(PHUSD).balanceOf(NFT_STAKER));
        console.log("  phUSD totalSupply   :", IERC20(PHUSD).totalSupply());
    }

    function _buy(
        BatchNFTMinterNudgeDiscount m,
        uint256 usdcIn,
        uint256 minOut,
        uint256 deadlineSecs,
        uint256 reserve,
        bool isPreview
    ) internal {
        Before memory b = Before(
            reserve, m.pendingStakerPhUSD(), IERC20(PHUSD).balanceOf(NFT_STAKER), IERC20(PHUSD).totalSupply()
        );
        uint256 deadline = vm.getBlockTimestamp() + deadlineSecs;
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
        (uint256 out, uint256 toStaker, uint256 burned) = m.buyAndBurn(usdcIn, minOut, deadline);
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
        lastPhusdOut = out;
        lastToStaker = toStaker;
        lastBurned = burned;
        _checkSplit(m, b, usdcIn, minOut);
    }

    function _checkSplit(BatchNFTMinterNudgeDiscount m, Before memory b, uint256 usdcIn, uint256 minOut) internal view {
        uint256 out = lastPhusdOut;
        uint256 toStakerOwed = out < b.owed ? out : b.owed;
        uint256 extra = out - toStakerOwed;
        require(out >= minOut, "post: phUSD out below the floor");
        require(lastBurned == (extra * m.burnPercent()) / 100, "post: burned != extra * burnPercent / 100");
        require(lastToStaker == toStakerOwed + extra - lastBurned, "post: toStaker != owed + unburned extra");
        require(
            IERC20(PHUSD).balanceOf(NFT_STAKER) == b.staker + lastToStaker, "post: NFTStaker phUSD delta != toStaker"
        );
        require(IERC20(PHUSD).totalSupply() == b.supply - lastBurned, "post: phUSD supply did not fall by the burn");
        require(m.pendingBuyUSDC() == b.reserve - usdcIn, "post: pendingBuyUSDC did not fall by usdcIn");
        require(
            m.pendingStakerPhUSD() == b.owed - toStakerOwed, "post: pendingStakerPhUSD did not fall by toStakerOwed"
        );
        _assertOwnerBalancesNotIncreased("post");
        console.log("  phUSD out           :", out);
        console.log("  -> owed to NFTStaker:", toStakerOwed);
        console.log("  -> extra            :", extra);
        console.log("     burned           :", lastBurned);
        console.log("     toStaker (extra) :", extra - lastBurned);
        console.log("  pendingBuyUSDC after:", m.pendingBuyUSDC());
        console.log("  pendingStakerPhUSD after (carried forward):", m.pendingStakerPhUSD());
        console.log("  NFTStaker phUSD after:", IERC20(PHUSD).balanceOf(NFT_STAKER));
        console.log("  phUSD totalSupply after:", IERC20(PHUSD).totalSupply());
    }

    function _preflight(BatchNFTMinterNudgeDiscount m) internal view {
        string memory book = _book();
        require(m.owner() == OWNER, "preflight: minter owner() != OWNER");
        require(m.router() == _requireBook(book, "UniswapV2Router"), "preflight: minter router != book UniswapV2Router");
        require(m.pair() == _requireBook(book, "PhusdSusdsPair"), "preflight: minter pair != book PhusdSusdsPair");
        require(m.phUSD() == _requireBook(book, "PhUSD"), "preflight: minter phUSD != book PhUSD");
        require(m.nftStaker() == _requireBook(book, "NFTStaker"), "preflight: minter nftStaker != book NFTStaker");
        require(address(m.psm()) == PSM, "preflight: minter psm != pinned Sky PSM");
        require(address(m.sUSDS()) == SUSDS, "preflight: minter sUSDS != pinned sUSDS");
        require(address(m.discountToken()) == USDC, "preflight: minter discountToken != USDC");
        require(
            m.buyerAuthVersion(OWNER) == m.authVersion(), "preflight: OWNER is not an authorised buyer (authVersion)"
        );
    }

    /// @dev The ONE resolver of the minter. `virtual` so a fork harness can point it at a fork-deployed minter.
    function _resolveMinter() internal view virtual returns (address m) {
        m = _bookNewMinter();
        require(
            m != address(0),
            "preflight: mainnet-addresses.ts NudgeDiscountBatchMinter is the zero placeholder - run the cutover (nudge-discount:broadcast) first"
        );
        require(m.code.length > 0, "preflight: NudgeDiscountBatchMinter has no code");
    }

    /// @dev The ONE reader of USDC_IN_WEI / MIN_PHUSD_OUT_WEI / DEADLINE_SECS. `virtual` for fork harnesses.
    function _inputsFromEnv() internal view virtual returns (uint256 usdcIn, uint256 minOut, uint256 deadlineSecs) {
        usdcIn = vm.envOr("USDC_IN_WEI", uint256(0));
        minOut = vm.envOr("MIN_PHUSD_OUT_WEI", uint256(0));
        deadlineSecs = vm.envOr("DEADLINE_SECS", DEFAULT_DEADLINE_SECS);
    }

    function _sender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
