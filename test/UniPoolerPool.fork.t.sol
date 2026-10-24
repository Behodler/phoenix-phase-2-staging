// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
import {UniPoolerPool} from "../script/UniPoolerPool.s.sol";

/// @dev The pool script with its I/O seams pinned: the address book (a post-cutover `UniPooler` entry), the inputs
///      and the mode are injected, never read from the process-wide env or the real mainnet-addresses.ts.
contract UniPoolerPoolHarnessFork is UniPoolerPool {
    string internal book;
    uint256 internal sIn;
    uint256 internal minP;
    uint256 internal minL;

    function set(string memory book_, uint256 sIn_, uint256 minP_, uint256 minL_) external {
        book = book_;
        sIn = sIn_;
        minP = minP_;
        minL = minL_;
    }

    function _addressBook() internal view override returns (string memory) {
        return book;
    }

    function _inputsFromEnv() internal view override returns (uint256, uint256, uint256) {
        return (sIn, minP, minL);
    }

    function _previewModeFromEnv() internal pure override returns (bool) {
        return true; // OWNER prank
    }
}

/**
 * @title UniPoolerPoolForkTest  (story 105; repointed by story 107)
 * @notice Mainnet fork (skipped without RPC_MAINNET) at a block AFTER the Stage 4 cutover: the story-105 `pool()`
 *         script runs against the LIVE index-4 UniPooler with `quotePool`-derived floors (the quote helper's
 *         computation, in-test). Story 107 archived the cutover script and retired its fork harness, so the pooler's
 *         sUSDS is topped up with `deal` instead of being produced by an in-fork cutover. The sUSDS is zapped into the
 *         pair and the LP stays on the pooler; a floor above the live quote, a floor too far below it, and the zero
 *         placeholder are each refused before anything is sent.
 */
contract UniPoolerPoolForkTest is Test {
    /// @dev The block the human's wind-down check read (story 107 gate); the cutover landed at 26_254_520.
    uint256 constant FORK_BLOCK = 26_260_804;
    uint256 constant TOL_BPS = 50; // quote-unipooler-pool.js default
    uint256 constant SUSDS_TOP_UP = 500 ether;

    address constant LIVE_UNIPOOLER = 0x56997ea45091CBc01DB8a09E60DEDB8b3706a3D2;
    address constant RETIRED_POOLER = 0x7f6874332c4629429d70D15f685A8230323F11F1;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    UniPoolerPoolHarnessFork pool;
    UniPoolerV2 np;
    string book;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        np = UniPoolerV2(LIVE_UNIPOOLER);
        deal(SUSDS, address(np), IERC20(SUSDS).balanceOf(address(np)) + SUSDS_TOP_UP);
        book = string.concat("\n  UniPooler: \"", vm.toString(address(np)), "\",\n");
        pool = new UniPoolerPoolHarnessFork();
    }

    /// @dev scripts/quote-unipooler-pool.js, in-test.
    function _quote(uint256 sIn) internal view returns (uint256 minP, uint256 minL) {
        (, uint256 phusdOut, uint256 lp) = np.quotePool(sIn);
        minP = (phusdOut * (10_000 - TOL_BPS)) / 10_000;
        minL = (lp * (10_000 - TOL_BPS)) / 10_000;
    }

    function test_fork_pool_zapsAccumulatedSUSDS_lpStaysOnPooler() public {
        uint256 bal = IERC20(SUSDS).balanceOf(address(np));
        assertGt(bal, 0, "pooler holds sUSDS to zap");
        uint256 lpBefore = IERC20(np.pair()).balanceOf(address(np));
        (uint256 minP, uint256 minL) = _quote(bal);
        pool.set(book, bal, minP, minL);
        pool.run();
        assertLt(IERC20(SUSDS).balanceOf(address(np)), bal / 1000, "all but router dust pooled");
        assertGe(IERC20(np.pair()).balanceOf(address(np)) - lpBefore, minL, "LP minted to the pooler");
    }

    function test_fork_pool_partialAmount() public {
        uint256 bal = IERC20(SUSDS).balanceOf(address(np));
        uint256 half = bal / 2;
        (uint256 minP, uint256 minL) = _quote(half);
        pool.set(book, half, minP, minL);
        pool.run();
        uint256 left = IERC20(SUSDS).balanceOf(address(np));
        assertGe(left, bal - half, "never spends more than asked");
        assertLt(left - (bal - half), half / 1000, "at most router dust of the half stays");
    }

    function test_fork_revert_floorAboveQuote() public {
        uint256 bal = IERC20(SUSDS).balanceOf(address(np));
        (, uint256 phusdOut, uint256 lp) = np.quotePool(bal);
        pool.set(book, bal, phusdOut + 1, lp);
        vm.expectRevert(bytes("quote: MIN_PHUSD_OUT_WEI above the live quote - pair moved, re-quote"));
        pool.run();
    }

    function test_fork_revert_floorTooLoose() public {
        uint256 bal = IERC20(SUSDS).balanceOf(address(np));
        (, uint256 phusdOut, uint256 lp) = np.quotePool(bal);
        pool.set(book, bal, phusdOut, lp / 2);
        vm.expectRevert(bytes("quote: MIN_LP_WEI more than MAX_TOLERANCE_BPS below the live quote - re-quote"));
        pool.run();
    }

    function test_fork_revert_moreThanBalance() public {
        uint256 bal = IERC20(SUSDS).balanceOf(address(np));
        pool.set(book, bal + 1, 1, 1);
        vm.expectRevert(bytes("preflight: SUSDS_IN_WEI exceeds the pooler's sUSDS balance"));
        pool.run();
    }

    function test_fork_revert_zeroPlaceholder() public {
        pool.set("\n  UniPooler: \"0x0000000000000000000000000000000000000000\",\n", 1, 1, 1);
        vm.expectRevert(
            bytes("preflight: mainnet-addresses.ts UniPooler is the zero placeholder - run the Stage 4 cutover first")
        );
        pool.run();
    }

    function test_fork_revert_bookNotLiveDispatcher() public {
        pool.set(string.concat("\n  UniPooler: \"", vm.toString(RETIRED_POOLER), "\",\n"), 1, 1, 1);
        vm.expectRevert(bytes("preflight: mainnet-addresses.ts UniPooler is not NFTMinter configs(4).dispatcher"));
        pool.run();
    }
}
