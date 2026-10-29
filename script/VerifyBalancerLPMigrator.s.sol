// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {BalancerLPMigrator} from "../src/periphery/BalancerLPMigrator.sol";
import {BalancerLPMigratorMainnetBase} from "./DeployBalancerLPMigratorMainnet.s.sol";

/**
 * @title VerifyBalancerLPMigrator  (story 121, sprint balancer-lp-migrator)
 * @notice READ-ONLY verifier for the mainnet BalancerLPMigrator: no --broadcast, no --sender, no prank/deal.
 *
 *         WHICH MIGRATOR. `server/deployments/progress.balancer-lp-migrator.1.json` (written by the deploy) and the
 *         `BalancerLPMigrator` key of `mainnet-addresses.ts` (filled by the patcher). Whichever is non-zero is used;
 *         when both are, they must agree. With neither it fails "verify: no BalancerLPMigrator address".
 *
 *         WHAT IT CHECKS. The preflight still holds (code everywhere, `factory.getPair(sUSDS, phUSD)` ==
 *         `PhusdSusdsPair`, pool tokens == {sUSDS, phUSD}); every immutable equals the expected constructor input
 *         and the stored token indices match the Vault's order; and `previewMigrate(1 BPT)` returns non-zero
 *         amounts and LP. It logs which exit (proportional or recovery) `migrate` would take right now.
 *
 * Usage: npm run balancer-lp-migrator:verify
 */
contract VerifyBalancerLPMigrator is BalancerLPMigratorMainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY BalancerLPMigrator - MAINNET (story 121)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        MigratorConfig memory c = expectedConfig();
        _preflight(c);

        address fromProgress = _progressMigrator();
        address fromBook = _bookMigrator();
        console.log("  progress file :", fromProgress);
        console.log("  address book  :", fromBook);
        if (fromProgress != address(0) && fromBook != address(0)) {
            require(fromProgress == fromBook, "verify: progress file and mainnet-addresses.ts name different migrators");
        }
        address a = fromBook != address(0) ? fromBook : fromProgress;
        require(
            a != address(0),
            "verify: no BalancerLPMigrator address (no progress file and the address-book key is zero) - broadcast first"
        );

        BalancerLPMigrator m = BalancerLPMigrator(a);
        _checkImmutables(m, c);
        console.log("OK: BalancerLPMigrator", a, "- every immutable matches.");

        (
            uint256 sOut,
            uint256 pOut,
            uint256 sUsed,
            uint256 pUsed,
            address leftoverToken,
            uint256 leftoverAmount,
            bool recoveryMode,
            uint256 lp
        ) = m.previewMigrate(1e18);
        console.log("previewMigrate(1 BPT):");
        console.log("  sUSDS out / used", sOut, sUsed);
        console.log("  phUSD out / used", pOut, pUsed);
        console.log("  leftover token  ", leftoverToken);
        console.log("  leftover amount ", leftoverAmount);
        console.log("  expected LP     ", lp);
        console.log(recoveryMode ? "  exit: RECOVERY (pool/Vault paused or in recovery)" : "  exit: PROPORTIONAL");
        require(sOut > 0 && pOut > 0, "verify: previewMigrate returned a zero Balancer exit");
        require(lp > 0, "verify: previewMigrate returned zero LP");
        console.log("OK: preview smoke test passed.");
    }
}
