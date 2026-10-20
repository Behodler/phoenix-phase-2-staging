// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {UniPoolerPool} from "../script/UniPoolerPool.s.sol";

/// @dev Exposes the script's internal checks. Calls go through `this.` so `vm.expectRevert` sees an external frame.
contract UniPoolerPoolHarness is UniPoolerPool {
    function requireInputs(uint256 a, uint256 b, uint256 c) external pure {
        _requireInputs(a, b, c);
    }

    function requireFloorInBand(uint256 floor, uint256 quote) external pure {
        _requireFloorInBand(floor, quote, "X");
    }

    function bookAddress(string memory book, string memory key) external pure returns (address) {
        return _bookAddress(book, key);
    }
}

/**
 * @title UniPoolerPoolGuardsTest  (story 105)
 * @notice No RPC needed. The `unipooler:pool:*` npm keys (appended at the end, :preview signs nothing, :broadcast is the
 *         Ledger template), the quote helper replacing compute-min-bpt-poolerv2.js, and the script's own guards:
 *         non-zero inputs, floors within MAX_TOLERANCE_BPS below the live quote, and the zero-placeholder UniPooler.
 */
contract UniPoolerPoolGuardsTest is Test {
    string constant PKG = "package.json";
    string constant BOOK = "server/deployments/mainnet-addresses.ts";

    string constant FORGE =
        "forge script script/UniPoolerPool.s.sol:UniPoolerPool --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6";

    UniPoolerPoolHarness h;

    function setUp() public {
        h = new UniPoolerPoolHarness();
    }

    function _key(string memory k) internal view returns (string memory) {
        return vm.parseJsonString(vm.readFile(PKG), string.concat(".scripts['", k, "']"));
    }

    function _at(string memory hay, string memory needle) internal pure returns (uint256 i) {
        i = vm.indexOf(hay, needle);
        assertTrue(i != type(uint256).max, string.concat("missing: ", needle));
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        return vm.indexOf(hay, needle) != type(uint256).max;
    }

    // --------------------------------------------------------------------------------------------- package.json

    function test_keys_appendedInOrder_afterTheCutoverKeys() public view {
        string memory pkg = vm.readFile(PKG);
        uint256 prev = _at(pkg, "\"unipooler-cutover:verify\":");
        uint256 c = _at(pkg, "\"//UniPoolerPool\":");
        uint256 p = _at(pkg, "\"unipooler:pool:preview\":");
        uint256 b = _at(pkg, "\"unipooler:pool:broadcast\":");
        assertLt(prev, c);
        assertLt(c, p);
        assertLt(p, b);
        assertLt(b, _at(pkg, "\"devDependencies\""));
    }

    function test_preview_signsNothing() public view {
        assertEq(_key("unipooler:pool:preview"), string.concat("PREVIEW_MODE=true ", FORGE, " --slow -vvv"));
    }

    function test_broadcast_ledgerTemplate_notPrefixedWithPreview() public view {
        string memory b = _key("unipooler:pool:broadcast");
        assertFalse(_has(b, "PREVIEW_MODE"), "no preview mode in broadcast");
        assertTrue(
            _has(
                b,
                string.concat(
                    FORGE,
                    " --broadcast --skip-simulation --slow --ledger --hd-paths \"m/44'/60'/46'/0/0\" --legacy --with-gas-price $UNIPOOLER_POOL_GAS_PRICE_WEI --gas-estimate-multiplier 200 -vvv"
                )
            ),
            "Ledger broadcast flags"
        );
        assertTrue(_has(b, "export UNIPOOLER_POOL_GAS_PRICE_WEI=${UNIPOOLER_POOL_GAS_PRICE_WEI:-300000000}"));
    }

    function test_commentKey_citesStory_quoteHelper_floors() public view {
        string memory c = _key("//UniPoolerPool");
        assertTrue(_has(c, "Story 105"));
        assertTrue(_has(c, "scripts/quote-unipooler-pool.js"));
        assertTrue(_has(c, "SUSDS_IN_WEI") && _has(c, "MIN_PHUSD_OUT_WEI") && _has(c, "MIN_LP_WEI"));
    }

    function test_retiredKeysAndHelperGone() public view {
        string memory pkg = vm.readFile(PKG);
        assertFalse(_has(pkg, "eclp"), "no E-CLP npm keys");
        assertFalse(_has(pkg, "compute-min-bpt-poolerv2"), "no key on the retired BPT quote helper");
        assertTrue(vm.exists("scripts/quote-unipooler-pool.js"), "zap-quote helper present");
    }

    // --------------------------------------------------------------------------------------------- script guards

    function test_requireInputs_rejectsEachZero() public {
        h.requireInputs(1, 1, 1);
        vm.expectRevert(bytes("input: SUSDS_IN_WEI unset or zero (quote with scripts/quote-unipooler-pool.js)"));
        h.requireInputs(0, 1, 1);
        vm.expectRevert(bytes("input: MIN_PHUSD_OUT_WEI unset or zero - refusing an unprotected swap"));
        h.requireInputs(1, 0, 1);
        vm.expectRevert(bytes("input: MIN_LP_WEI unset or zero - refusing an unprotected add"));
        h.requireInputs(1, 1, 0);
    }

    function test_floorBand_edges() public {
        h.requireFloorInBand(10_000, 10_000); // at the quote
        h.requireFloorInBand(9_900, 10_000); // exactly 1% below
        vm.expectRevert(bytes("quote: X above the live quote - pair moved, re-quote"));
        h.requireFloorInBand(10_001, 10_000);
        vm.expectRevert(bytes("quote: X more than MAX_TOLERANCE_BPS below the live quote - re-quote"));
        h.requireFloorInBand(9_899, 10_000);
        vm.expectRevert(bytes("quote: live X quote is zero"));
        h.requireFloorInBand(0, 0);
    }

    function test_bookReader_currentPlaceholderIsZero() public view {
        // Until the Stage 4 patch, the script's UniPooler resolves to address(0), which _resolvePooler refuses.
        assertEq(h.bookAddress(vm.readFile(BOOK), "UniPooler"), address(0));
        assertTrue(h.bookAddress(vm.readFile(BOOK), "NFTMinter") != address(0), "reader finds a live key");
    }
}
