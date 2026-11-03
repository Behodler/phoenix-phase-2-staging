// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {PauserV2MainnetBase, IPauserV1Registry} from "./helpers/PauserV2MainnetBase.sol";

/**
 * @title DeployPauserV2Mainnet  (story 128, sprint global-pauser-v2)
 * @notice Deploys the tolerant global `PauserV2` (lib/pauser, pauser-RM:003) on mainnet. ONE transaction from OWNER:
 *         `new PauserV2(EYE)`. Registers nothing and touches no registrant - the rotation is
 *         `MigratePauserV2Mainnet`, run after this one lands.
 *
 *         Configuration safety (CLAUDE.md, Configuration Safety):
 *           - eyeToken      = EYE `0x155f...1c65`, the V1 Pauser's burn token (`V1.eyeToken()`, book key `EYE`);
 *           - eyeBurnAmount = 1000e18, PauserV2's constructor default and V1's live value. Asserted after deploy,
 *                             never configured: the script refuses rather than leave a different amount;
 *           - owner         = the deployer, required to be OWNER `0xCad1...D0B6` (the Ledger EOA that owns V1 and
 *                             every registrant). Asserted after deploy.
 *
 *         Idempotent: once a broadcast has written `server/deployments/progress.pauser-v2.1.json`, a re-run checks
 *         the recorded PauserV2 and sends nothing. The address book is NOT touched here; the human runs
 *         `node scripts/patch-mainnet-addresses-pauser-v2.js` after the migration (runbook
 *         docs/runbooks/pauser-v2-migration.md).
 *
 * Preview:   npm run pauser-v2-deploy:preview    (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written)
 * Broadcast: npm run pauser-v2-deploy:broadcast  (Ledger; the human only)
 */
contract DeployPauserV2Mainnet is PauserV2MainnetBase {
    PauserV2 public pauserV2;
    bool public deployedThisRun;

    function run() external {
        console.log("=================================================");
        console.log("  DEPLOY PauserV2 - MAINNET (story 128)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        bool isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );

        // Inputs come from the live V1 Pauser, so V2 starts exactly where V1 is.
        require(IPauserV1Registry(PAUSER_V1).eyeToken() == EYE, "V1 Pauser eyeToken() != EYE");
        require(IPauserV1Registry(PAUSER_V1).eyeBurnAmount() == EYE_BURN_AMOUNT, "V1 eyeBurnAmount() != 1000e18");
        require(IPauserV1Registry(PAUSER_V1).owner() == OWNER, "V1 Pauser owner() != OWNER");
        require(EYE.code.length > 0, "EYE has no code");
        if (!isPreview) require(msg.sender == OWNER, "broadcast sender must be OWNER (--sender + Ledger)");

        address recorded = _progressPauserV2();
        if (recorded != address(0)) {
            require(
                recorded.code.length > 0,
                "Progress file names a PauserV2 with NO CODE - it was recorded but never landed. Delete server/deployments/progress.pauser-v2.1.json and re-run preview."
            );
            _checkPauserV2(recorded);
            pauserV2 = PauserV2(recorded);
            console.log("PauserV2 already deployed (progress file):", recorded);
            console.log("owner, eyeToken and eyeBurnAmount match - nothing to do, no transaction sent (idempotent).");
            return;
        }

        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
        pauserV2 = new PauserV2(EYE);
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
        deployedThisRun = true;

        console.log("PauserV2:", address(pauserV2));
        _checkPauserV2(address(pauserV2));
        require(pauserV2.getPausableContracts().length == 0, "fresh PauserV2 must have no registrants");
        console.log("OK: owner == OWNER, eyeToken == EYE, eyeBurnAmount == 1000e18, no registrants.");

        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (a preview CREATE address is fork-local)."
            );
            return;
        }
        _writeProgress();
        console.log("Next: Etherscan verify (runbook), then npm run pauser-v2-migrate:preview.");
    }

    function _writeProgress() internal {
        vm.serializeAddress("s128.v2", "address", address(pauserV2));
        string memory entry = vm.serializeBool("s128.v2", "deployed", true);
        string memory contracts = vm.serializeString("s128.contracts", "PauserV2", entry);
        vm.serializeUint("s128.root", "chainId", CHAIN_ID);
        vm.serializeString("s128.root", "networkName", NETWORK_NAME);
        vm.serializeString("s128.root", "deploymentStatus", "completed");
        string memory json = vm.serializeString("s128.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written:", _progressFile());
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode
    ///      (`vm.setEnv` is process-wide and forge runs suites in parallel). Production always reads the env.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}

