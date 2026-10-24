// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {UniPoolerCutoverMainnetBase} from "./DeployMainnetUniPoolerCutover.s.sol";
import {ICutoverUniV2Pair} from "./helpers/UniPoolerCutoverCore.sol";

/**
 * @title VerifyUniPoolerCutover  (story 103, sprint Balancexit)
 * @notice READ-ONLY post-broadcast verifier for the index-4 UniPoolerV2 cutover
 *         (`script/DeployMainnetUniPoolerCutover.s.sol`). No --broadcast, no --sender. The only state it touches is
 *         a reverted local snapshot for the `pool()` simulation; nothing is ever sent.
 *
 *         WHICH CONTRACTS. `UniPooler`, `PhusdSusdsPair` and `UniPoolerCutoverEscrow` come from
 *         `server/deployments/progress.unipooler-cutover.1.json` (the cutover's own record, with the seeded amounts).
 *         Where `mainnet-addresses.ts` already carries a non-zero `UniPooler` / `PhusdSusdsPair` (the patcher ran),
 *         it must agree with the progress file.
 *
 *         WHAT IT CHECKS (docs/BalancerWinddownPlan.md §4 Stage 2 step 11):
 *           - `configs(4).dispatcher` is the new pooler; `hook.dispatcher()` is the new pooler (and back);
 *           - the pair is canonical and its reserves EQUAL what was seeded (progress `cutover.sUSDSSeeded` /
 *             `cutover.phUSDSeeded`). A later `pool()` or swap legitimately moves the reserves, so
 *             `VERIFY_ALLOW_RESERVE_DRIFT=true` downgrades only this check to a logged warning;
 *           - the new pooler holds the LP (at least the seeded `cutover.liquidity`);
 *           - the new pooler's config equals the old pooler's (live) and all four poolers are authorized;
 *           - the old pooler is paused, its minter is OWNER, and it holds 0 sUSDS, 0 BPT and 0 USDS;
 *           - the escrow's BPT, sUSDS, phUSD and USDS are REPORTED (a warning if non-zero) - never required,
 *             because its address is predictable and anyone can donate to it (story 103 revision 2);
 *           - owner BPT is REPORTED (logged; a warning if non-zero) - never required (F-02-052);
 *           - a `quotePool`-floored `pool()` succeeds (simulated as OWNER inside a reverted snapshot).
 *
 * Usage: npm run unipooler-cutover:verify
 */
contract VerifyUniPoolerCutover is UniPoolerCutoverMainnetBase {
    function run() external {
        console.log("=================================================");
        console.log("  VERIFY index-4 UniPoolerV2 cutover - MAINNET (story 103)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        (bool exists, string memory json) = _readProgress();
        require(
            exists, "verify: no progress file server/deployments/progress.unipooler-cutover.1.json - broadcast first"
        );
        require(vm.parseJsonUint(json, ".chainId") == CHAIN_ID, "verify: progress chainId != 1");
        require(
            keccak256(bytes(vm.parseJsonString(json, ".deploymentStatus"))) == keccak256("completed"),
            "verify: progress deploymentStatus != completed"
        );
        address np = _progressAddress(json, "UniPooler");
        address pair = _progressAddress(json, "PhusdSusdsPair");
        address escrow = _progressAddress(json, "UniPoolerCutoverEscrow");
        require(
            np != address(0) && pair != address(0) && escrow != address(0), "verify: progress file missing addresses"
        );
        console.log("  UniPooler              :", np);
        console.log("  PhusdSusdsPair         :", pair);
        console.log("  UniPoolerCutoverEscrow :", escrow);

        string memory book = vm.readFile(ADDRESS_BOOK);
        address bookNp = _bookAddress(book, "UniPooler");
        address bookPair = _bookAddress(book, "PhusdSusdsPair");
        if (bookNp != address(0)) require(bookNp == np, "verify: mainnet-addresses.ts UniPooler != progress file");
        if (bookPair != address(0)) {
            require(bookPair == pair, "verify: mainnet-addresses.ts PhusdSusdsPair != progress file");
        }
        require(
            _bookAddress(book, "BalancerPooler") == OLD_POOLER, "verify: mainnet-addresses.ts BalancerPooler changed"
        );

        _checkWiring(np, pair);
        console.log("OK: configs(4).dispatcher, hook.dispatcher(), UniPooler hook/owner/minter/pair/config, poolers.");

        _checkReserves(json, pair);
        uint256 lp = ICutoverUniV2Pair(pair).balanceOf(np);
        require(lp > 0 && lp >= _progressUint(json, "liquidity"), "verify: UniPooler does not hold the seeded LP");
        console.log("OK: UniPooler holds the LP:", lp);

        _checkDrained(escrow);
        console.log("OK: old pooler paused, minter OWNER, 0 sUSDS / 0 BPT / 0 USDS (escrow residuals reported above).");

        _reportOwnerBpt();
        _simulateQuotedPool(np);
        console.log("VERIFY PASSED");
    }

    function _checkReserves(string memory json, address pair) internal view {
        uint256 seedS = _progressUint(json, "sUSDSSeeded");
        uint256 seedP = _progressUint(json, "phUSDSeeded");
        (uint256 rS, uint256 rP) = _reservesSP(pair);
        console.log("  pair reserves sUSDS / seeded:", rS, seedS);
        console.log("  pair reserves phUSD / seeded:", rP, seedP);
        if (rS == seedS && rP == seedP) {
            console.log("OK: pair reserves == seeded amounts.");
            return;
        }
        if (vm.envOr("VERIFY_ALLOW_RESERVE_DRIFT", false)) {
            console.log(
                "WARNING: pair reserves != seeded amounts (VERIFY_ALLOW_RESERVE_DRIFT=true: pool()/swaps since)."
            );
            return;
        }
        revert(
            "verify: pair reserves != seeded amounts (set VERIFY_ALLOW_RESERVE_DRIFT=true only if pool()/swaps ran since the cutover)"
        );
    }
}
