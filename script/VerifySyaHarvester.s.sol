// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {SyaHarvesterMainnetBase, IStableStakerV2ClaimGate} from "./DeploySyaHarvesterMainnet.s.sol";

/**
 * @title VerifySyaHarvester  (story 122, Script A verifier)
 * @notice READ-ONLY on-chain verifier: no --broadcast, no --sender, no prank/deal.
 *
 *         WHICH HARVESTER. `server/deployments/progress.sya-harvester.1.json` (written by the deploy) and the
 *         `SYAHarvester` key of `mainnet-addresses.ts` (filled by the patcher). Whichever is non-zero is used;
 *         when both are, they must agree. With neither it fails "verify: no SYAHarvester address".
 *
 *         CHECKS. Owner == OWNER; immutables (PoolManager, SYA, Router NG); the USDe and DOLA routes stored
 *         byte-equal to the script's payloads and contiguous under the story-052 rules as stored; USDC (the
 *         reward token) unrouted; the ETH pool key exact; `StableStakerV2.claimEnabled() == true`; the same
 *         preflight the deploy ran (pool coin indices, SYA reward token, route coverage of SYA's strategies).
 *
 * Usage: npm run sya-harvester:verify
 */
contract VerifySyaHarvester is SyaHarvesterMainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY SYAHarvester + claim enable - MAINNET (story 122, Script A)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        Config memory c = expectedConfig();
        _preflight(c);

        address fromProgress = _progressHarvester();
        address fromBook = _bookHarvester();
        console.log("  progress file :", fromProgress);
        console.log("  address book  :", fromBook);
        if (fromProgress != address(0) && fromBook != address(0)) {
            require(
                fromProgress == fromBook, "verify: progress file and mainnet-addresses.ts name different harvesters"
            );
        }
        address h = fromBook != address(0) ? fromBook : fromProgress;
        require(
            h != address(0),
            "verify: no SYAHarvester address (no progress file and the address-book key is zero) - broadcast first"
        );

        _checkConfigured(SYAHarvester(payable(h)), c);
        console.log("OK: SYAHarvester", h);
        console.log(
            "    owner/immutables, USDe route (2 hops) + DOLA route (1 hop) contiguous and exact, USDC unrouted, ETH pool exact"
        );

        require(
            IStableStakerV2ClaimGate(c.stableStakerV2).claimEnabled(), "verify: StableStakerV2.claimEnabled() is false"
        );
        console.log("OK: StableStakerV2.claimEnabled() == true");
    }

    /// @dev `virtual` only so fork tests pinned before the broadcast can stand in the zero placeholder.
    function _bookHarvester() internal view virtual returns (address) {
        return _bookAddress(vm.readFile(ADDRESS_BOOK), "SYAHarvester");
    }
}
