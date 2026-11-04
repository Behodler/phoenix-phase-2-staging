// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {PauserV2MainnetBase, IPauserV1Registry} from "./helpers/PauserV2MainnetBase.sol";

/**
 * @title DeployPauserV2Mainnet  (story 128, sprint global-pauser-v2)
 * @notice Deploys the tolerant global `PauserV2` (lib/pauser, pauser-RM:003) on mainnet. TWO transactions from
 *         OWNER: `new PauserV2(EYE)`, then `config(1_000_000e18, EYE)` to make a griefing pause during the rotation
 *         window cost 1M EYE (audit 49 L-02; `MigratePauserV2Mainnet` lowers it to 1000e18 last). Registers
 *         nothing and touches no registrant - the rotation is `MigratePauserV2Mainnet`, run after this one lands.
 *
 *         Configuration safety (CLAUDE.md, Configuration Safety):
 *           - eyeToken      = EYE `0x155f...1c65`, the V1 Pauser's burn token (`V1.eyeToken()`, book key `EYE`);
 *           - eyeBurnAmount = 1000e18 FINAL (PauserV2's constructor default and V1's live value), asserted after
 *                             the CREATE; then 1_000_000e18 for the rotation window (product owner, audit 49
 *                             L-02), asserted after `config`. The migration restores 1000e18 and the verifier
 *                             requires it;
 *           - owner         = the deployer, required to be OWNER `0xCad1...D0B6` (the Ledger EOA that owns V1 and
 *                             every registrant). Asserted after deploy.
 *
 *         Idempotent: once a broadcast has written `server/deployments/progress.pauser-v2.1.json`, a re-run checks
 *         the recorded PauserV2 and sends nothing. The file is written `pending` (with the CREATE nonce) only when
 *         PAUSER_V2_BROADCAST=true, and `scripts/confirm-pauser-v2-progress.js` marks it `completed` (audit 49 L-06).
 *         Broadcast refuses unless PAUSER_V2_GAS_PRICE_WEI >= 2 x block.basefee (audit 49 L-03).
 *         The address book is NOT touched here; the human runs
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
            _requireRecordedPauserV2Landed(recorded);
            _checkPauserV2(recorded);
            pauserV2 = PauserV2(recorded);
            console.log("PauserV2 already deployed (progress file):", recorded);
            // Step 2 resumes here if the run died between the CREATE and the raise.
            if (!_raiseBurnIfFresh(isPreview)) {
                console.log(
                    "owner, eyeToken and eyeBurnAmount match - nothing to do, no transaction sent (idempotent)."
                );
            }
            return;
        }

        if (!isPreview) _requireBroadcastGasPriceHeadroom();
        // OWNER's next nonce is the CREATE's nonce: recorded so a later no-code re-run can tell pending from lost.
        uint256 createNonce = vm.getNonce(OWNER);

        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
        pauserV2 = new PauserV2(EYE);
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
        deployedThisRun = true;

        console.log("PauserV2:", address(pauserV2));
        require(pauserV2.eyeBurnAmount() == EYE_BURN_AMOUNT, "constructor eyeBurnAmount() != 1000e18");
        _checkPauserV2(address(pauserV2));
        require(pauserV2.getPausableContracts().length == 0, "fresh PauserV2 must have no registrants");
        console.log("OK: owner == OWNER, eyeToken == EYE, eyeBurnAmount == 1000e18, no registrants.");

        _raiseBurnIfFresh(isPreview);

        if (isPreview) {
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (a preview CREATE address is fork-local)."
            );
            return;
        }
        _recordPendingProgress(address(pauserV2), createNonce);
        console.log("Next: Etherscan verify (runbook), then npm run pauser-v2-migrate:preview.");
    }

    /// @notice Step 2 of the runbook (audit 49 L-02): `config(1_000_000e18, EYE)` while PauserV2 has no registrants,
    ///         so nobody can grief the rotation window with a 1000-EYE pause. The migration lowers it back to
    ///         1000e18 as its last transaction. Skipped once anything is registered, so a re-run after the
    ///         migration never raises it again. Returns true when it sent the tx.
    function _raiseBurnIfFresh(bool isPreview) internal returns (bool) {
        if (pauserV2.getPausableContracts().length != 0) return false;
        if (pauserV2.eyeBurnAmount() == EYE_BURN_AMOUNT_MIGRATION) return false;
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast();
        pauserV2.config(EYE_BURN_AMOUNT_MIGRATION, EYE);
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
        require(pauserV2.eyeBurnAmount() == EYE_BURN_AMOUNT_MIGRATION, "config(1_000_000e18) did not take");
        require(pauserV2.eyeToken() == EYE, "config changed eyeToken");
        console.log("config(1_000_000e18 EYE): burn raised for the rotation window (step 2)");
        return true;
    }

    /// @notice Audit run 49 L-06. Forge runs this in its LOCAL pass, before the CREATE is signed, so the script
    ///         cannot know the tx landed. It records `pending` plus the CREATE nonce; the :broadcast key's
    ///         `scripts/confirm-pauser-v2-progress.js` flips it to `completed` from a success receipt and live code.
    ///         Written only when PAUSER_V2_BROADCAST=true (set by the :broadcast key alone), so a dry run without
    ///         --broadcast never creates the file.
    function _recordPendingProgress(address v2, uint256 createNonce) internal {
        if (!_progressWriteEnabledFromEnv()) {
            console.log("PAUSER_V2_BROADCAST unset: dry run, progress file NOT written.");
            return;
        }
        vm.serializeAddress("s128.v2", "address", v2);
        vm.serializeUint("s128.v2", "createNonce", createNonce);
        string memory entry = vm.serializeBool("s128.v2", "deployed", false);
        string memory contracts = vm.serializeString("s128.contracts", "PauserV2", entry);
        vm.serializeUint("s128.root", "chainId", CHAIN_ID);
        vm.serializeString("s128.root", "networkName", NETWORK_NAME);
        vm.serializeString("s128.root", "deploymentStatus", "pending");
        string memory json = vm.serializeString("s128.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written (pending until confirmed):", _progressFile());
    }

    /// @notice A recorded PauserV2 with no code is either a CREATE still pending or one that never landed. OWNER's
    ///         confirmed nonce tells them apart: until it passes the recorded create nonce, that nonce may still
    ///         be in the mempool, and redeploying would put a second PauserV2 at the next nonce.
    function _requireRecordedPauserV2Landed(address recorded) internal view {
        if (recorded.code.length > 0) return;
        string memory json = vm.readFile(_progressFile());
        require(
            vm.keyExistsJson(json, ".contracts.PauserV2.createNonce"),
            "Progress file names a PauserV2 with NO CODE and records no createNonce: check OWNER's pending nonce by hand"
        );
        uint256 createNonce = vm.parseJsonUint(json, ".contracts.PauserV2.createNonce");
        string memory n = vm.toString(createNonce);
        if (vm.getNonce(OWNER) <= createNonce) {
            revert(
                string.concat(
                    "Progress file names a PauserV2 with NO CODE, but OWNER has not consumed its create nonce ",
                    n,
                    ": the deploy tx may be PENDING. Wait, or replace nonce ",
                    n,
                    " with a higher PAUSER_V2_GAS_PRICE_WEI. Do NOT delete the progress file."
                )
            );
        }
        revert(
            string.concat(
                "Progress file names a PauserV2 with NO CODE although OWNER consumed its create nonce ",
                n,
                ": the deploy never landed. Delete ",
                _progressFile(),
                " and re-run preview."
            )
        );
    }

    /// @dev Set only by the :broadcast key. `virtual` so tests can pin it (vm.setEnv is process-wide).
    function _progressWriteEnabledFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PAUSER_V2_BROADCAST", false);
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode
    ///      (`vm.setEnv` is process-wide and forge runs suites in parallel). Production always reads the env.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}

