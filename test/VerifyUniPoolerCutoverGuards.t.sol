// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";

/**
 * @title VerifyUniPoolerCutoverGuardsTest  (story 103)
 * @notice Source-level guards no behavioural test can reach, by analogy with story 086's (retired)
 *         VerifyStableStakerV2CutoverGuards. No RPC needed.
 *
 *         package.json: the `unipooler-cutover:*` keys exist, are appended in the order
 *         `//UniPoolerCutover`, `:preview`, `:broadcast`, `:verify` (repo rule: new keys go at the END of
 *         `scripts`); `:broadcast` starts with the `backup-mainnet-addresses` head, is NOT prefixed with the
 *         preview, signs on the Ledger, and ends with the mandatory patcher -> `:verify` -> `:preview` tail;
 *         `:preview` and `:verify` never broadcast.
 *
 *         Helpers and source: the patcher and the quote helper exist; the cutover script states the
 *         poisoned-progress-file rule and the L-27 `setPool` rule; the core calls `withdrawBPT` from exactly one
 *         place, the guarded `_fundEscrow`.
 */
contract VerifyUniPoolerCutoverGuardsTest is Test {
    string constant PKG = "package.json";
    string constant SCRIPT = "script/DeployMainnetUniPoolerCutover.s.sol";
    string constant CORE = "script/helpers/UniPoolerCutoverCore.sol";

    string constant PREVIEW =
        "PREVIEW_MODE=true forge script script/DeployMainnetUniPoolerCutover.s.sol:DeployMainnetUniPoolerCutover --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --slow -vvv";
    string constant BROADCAST_HEAD = "node scripts/backup-mainnet-addresses.js && ";
    string constant BROADCAST_FORGE =
        "forge script script/DeployMainnetUniPoolerCutover.s.sol:DeployMainnetUniPoolerCutover --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --broadcast --skip-simulation --slow --ledger --hd-paths \"m/44'/60'/46'/0/0\" --legacy --with-gas-price $CUTOVER_GAS_PRICE_WEI --gas-estimate-multiplier 200 -vvv";
    string constant BROADCAST_TAIL =
        " && node scripts/patch-mainnet-addresses-unipooler-cutover.js && npm run unipooler-cutover:verify && npm run unipooler-cutover:preview";
    string constant VERIFY =
        "forge script script/VerifyUniPoolerCutover.s.sol:VerifyUniPoolerCutover --rpc-url $RPC_MAINNET -vvv";

    function _pkg() internal view returns (string memory) {
        return vm.readFile(PKG);
    }

    function _key(string memory k) internal view returns (string memory) {
        return vm.parseJsonString(_pkg(), string.concat(".scripts['", k, "']"));
    }

    function _at(string memory hay, string memory needle) internal pure returns (uint256 i) {
        i = vm.indexOf(hay, needle);
        assertTrue(i != type(uint256).max, string.concat("missing: ", needle));
    }

    function _has(string memory hay, string memory needle) internal pure returns (bool) {
        return vm.indexOf(hay, needle) != type(uint256).max;
    }

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(prefix);
        if (b.length > a.length) return false;
        for (uint256 i; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _endsWith(string memory s, string memory suffix) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(suffix);
        if (b.length > a.length) return false;
        for (uint256 i; i < b.length; i++) {
            if (a[a.length - b.length + i] != b[i]) return false;
        }
        return true;
    }

    function _count(string memory hay, string memory needle) internal pure returns (uint256 n) {
        bytes memory h = bytes(hay);
        bytes memory nd = bytes(needle);
        for (uint256 i; i + nd.length <= h.length; i++) {
            bool m = true;
            for (uint256 j; j < nd.length; j++) {
                if (h[i + j] != nd[j]) {
                    m = false;
                    break;
                }
            }
            if (m) n++;
        }
    }

    // --------------------------------------------------------------------------------------------- package.json

    function test_keys_appendedInOrder_atTheEnd() public view {
        string memory pkg = _pkg();
        uint256 prev = _at(pkg, "\"uniswap-helper:verify\":");
        uint256 c = _at(pkg, "\"//UniPoolerCutover\":");
        uint256 p = _at(pkg, "\"unipooler-cutover:preview\":");
        uint256 b = _at(pkg, "\"unipooler-cutover:broadcast\":");
        uint256 v = _at(pkg, "\"unipooler-cutover:verify\":");
        assertLt(prev, c, "appended after the previous last key");
        assertLt(c, p, "//UniPoolerCutover before :preview");
        assertLt(p, b, ":preview before :broadcast");
        assertLt(b, v, ":broadcast before :verify");
        // :verify is the last scripts entry.
        uint256 end = _at(pkg, "\"devDependencies\"");
        assertLt(v, end);
        assertEq(_count(pkg, "\"unipooler-cutover:"), 3, "exactly three unipooler-cutover:* keys");
    }

    function test_commentKey_citesStory_recoveryExit_quoteHelper() public view {
        string memory c = _key("//UniPoolerCutover");
        assertTrue(_has(c, "Story 103"), "cites story 103");
        assertTrue(_has(c, "RECOVERY_EXIT"), "documents RECOVERY_EXIT");
        assertTrue(_has(c, "scripts/quote-balancer-exit-min-amounts.js"), "documents the quote helper");
        assertTrue(_has(c, "MIN_SUSDS_OUT_WEI") && _has(c, "MIN_PHUSD_OUT_WEI"), "documents the floors");
        assertTrue(_has(c, "POISONED"), "documents the poisoned progress file");
    }

    function test_broadcast_head_ledger_tail_notPrefixedWithPreview() public view {
        string memory b = _key("unipooler-cutover:broadcast");
        assertTrue(_startsWith(b, BROADCAST_HEAD), "starts with the backup-mainnet-addresses head");
        assertFalse(_startsWith(b, "PREVIEW_MODE"), "not prefixed with a preview run");
        assertFalse(_startsWith(b, "npm run unipooler-cutover:preview"), "not prefixed with :preview");
        assertTrue(_has(b, BROADCAST_FORGE), "Ledger broadcast flags as in the template");
        assertTrue(_endsWith(b, BROADCAST_TAIL), "patcher -> :verify -> :preview tail");
        assertEq(_count(b, "npm run unipooler-cutover:preview"), 1, "preview only in the tail");
        assertLt(_at(b, "--broadcast"), _at(b, "node scripts/patch-mainnet-addresses-unipooler-cutover.js"));
        assertTrue(_has(b, "export CUTOVER_GAS_PRICE_WEI=${CUTOVER_GAS_PRICE_WEI:-300000000}"), "gas price default");
    }

    function test_preview_and_verify_neverBroadcast() public view {
        assertEq(_key("unipooler-cutover:preview"), PREVIEW, ":preview");
        assertEq(_key("unipooler-cutover:verify"), VERIFY, ":verify");
        string memory v = _key("unipooler-cutover:verify");
        assertFalse(_has(v, "--broadcast") || _has(v, "--ledger") || _has(v, "--sender"), ":verify is read-only");
        string memory p = _key("unipooler-cutover:preview");
        assertFalse(_has(p, "--broadcast") || _has(p, "--ledger"), ":preview signs nothing");
    }

    // -------------------------------------------------------------------------------------- helpers and source

    function test_helpers_present() public view {
        assertTrue(vm.exists("scripts/patch-mainnet-addresses-unipooler-cutover.js"), "patcher present");
        assertTrue(vm.exists("scripts/quote-balancer-exit-min-amounts.js"), "quote helper present");
    }

    function test_scriptHeader_statesPoisonedProgressAndL27Rules() public view {
        string memory s = vm.readFile(SCRIPT);
        assertTrue(
            _has(
                s,
                "A CRASH MID-BROADCAST POISONS THE PROGRESS FILE: resume from broadcast receipts, not the progress file, and"
            ),
            "poisoned-progress-file note"
        );
        assertTrue(_has(s, "progress.unipooler-cutover.1.POISONED.<ts>.bak"), "poisoned file rename");
        assertTrue(
            _has(
                s,
                "NEVER CALL `BalancerPoolerV2.setPool` ON THE OLD POOLER (0x7f6874332c4629429d70D15f685A8230323F11F1)"
            ),
            "L-27 operational rule"
        );
        assertTrue(_has(s, "server/deployments/progress.unipooler-cutover.1.json"), "progress file path");
    }

    function test_core_withdrawBPT_onlyInGuardedFundEscrow() public view {
        string memory c = vm.readFile(CORE);
        assertEq(_count(c, ").withdrawBPT("), 1, "exactly one withdrawBPT call site");
        uint256 fn = _at(c, "function _fundEscrow(");
        uint256 guard = _at(c, "require(livePool == ICutoverEscrow(escrow).bpt(), CUTOVER_BPT_GUARD_MESSAGE);");
        uint256 call = _at(c, ".withdrawBPT(escrow, bal)");
        assertLt(fn, guard, "guard inside _fundEscrow");
        assertLt(guard, call, "guard before withdrawBPT");
        assertTrue(_has(c, "function bpt() external view returns (address);"), "local escrow interface declares bpt()");
        assertEq(_count(c, ".skim("), 0, "no skim in the core (the escrow skims to the new pooler)");
    }

    /// @dev Story 103 revision 2: the escrow's address is predictable (a CREATE from OWNER's public nonce), so no
    ///      check may require an ABSOLUTE escrow balance - a donation would revert the cutover's local pass or fail
    ///      :verify forever. The core compares deltas; verify only reports escrow residuals; the old pooler being
    ///      empty stays a hard require in both.
    function test_noAbsoluteEscrowBalanceRequirement_escrowResidualIsAWarning() public view {
        string memory c = vm.readFile(CORE);
        assertEq(_count(c, "balanceOf(l.escrow) == "), 0, "core: no absolute escrow-balance equality");
        assertEq(
            _count(c, "balanceOf(l.escrow) - "), 0, "core: no escrow balance used as a delta minuend unsnapshotted"
        );
        assertTrue(_has(c, "escrowUsdsAfterRescue - escrowUsdsBefore == usdsRescued"), "core: step-11 USDS delta check");
        assertTrue(_has(c, "_checkMinAmountsOut(p, l, bptWithdrawn);"), "core: floors sized on the BPT step 4 moved");
        assertTrue(
            _has(
                c, "require(ICutoverERC20(l.bPool).balanceOf(p.oldPooler) == 0, \"UniPoolerCutoverCore: BPT remains\");"
            ),
            "core: old pooler BPT still a hard require"
        );

        string memory s = vm.readFile(SCRIPT);
        uint256 fn = _at(s, "function _checkDrained(address escrow)");
        uint256 end = _at(s, "function _reportEscrowResidual(");
        assertLt(fn, end, "_checkDrained precedes its reporter");
        assertEq(_count(s, ").balanceOf(escrow) == 0"), 0, "verify: no required-empty escrow");
        assertTrue(_has(s, "\"verify: old pooler holds BPT\""), "verify: old pooler BPT still required");
        assertTrue(_has(s, "\"verify: old pooler holds sUSDS\""), "verify: old pooler sUSDS still required");
        assertTrue(_has(s, "WARNING: escrow holds "), "verify: escrow residual is a warning");
    }
}
