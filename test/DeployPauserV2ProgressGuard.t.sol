// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {DeployPauserV2Mainnet} from "../script/DeployPauserV2Mainnet.s.sol";

/// @dev Exposes the progress writer and the no-code diagnosis. Mode and output path are pinned per instance so
///      tests never read the process-wide env or touch the real progress file.
contract ProgressGuardHarness is DeployPauserV2Mainnet {
    string internal path;
    bool internal writeEnabled;

    constructor(string memory p, bool enabled) {
        path = p;
        writeEnabled = enabled;
    }

    function _progressFile() internal view override returns (string memory) {
        return path;
    }

    function _progressWriteEnabledFromEnv() internal view override returns (bool) {
        return writeEnabled;
    }

    function recordPending(address v2, uint256 createNonce) external {
        _recordPendingProgress(v2, createNonce);
    }

    function requireLanded(address recorded) external view {
        _requireRecordedPauserV2Landed(recorded);
    }
}

/// @notice Audit run 49 L-06: the deploy script wrote `deploymentStatus: completed` in forge's local pass, even on
///         a dry run without --broadcast, and its NO-CODE message told the operator to delete and redeploy while
///         the CREATE might only be pending.
contract DeployPauserV2ProgressGuardTest is Test {
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant V2 = address(0xBEEF);

    function _path(string memory tag) internal pure returns (string memory) {
        return string.concat("server/deployments/test-l06-", tag, ".json");
    }

    function _cleanup(string memory p) internal {
        if (vm.exists(p)) vm.removeFile(p);
    }

    function test_dryRun_doesNotWriteProgress() public {
        string memory p = _path("dryrun");
        _cleanup(p);
        new ProgressGuardHarness(p, false).recordPending(V2, 7);
        assertFalse(vm.exists(p), "a run without PAUSER_V2_BROADCAST must not write the progress file");
    }

    function test_broadcast_writesPendingWithCreateNonce() public {
        string memory p = _path("pending");
        _cleanup(p);
        new ProgressGuardHarness(p, true).recordPending(V2, 7);
        string memory json = vm.readFile(p);
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "pending");
        assertEq(vm.parseJsonAddress(json, ".contracts.PauserV2.address"), V2);
        assertEq(vm.parseJsonUint(json, ".contracts.PauserV2.createNonce"), 7);
        assertFalse(vm.parseJsonBool(json, ".contracts.PauserV2.deployed"));
        _cleanup(p);
    }

    function test_noCode_nonceNotConsumed_saysPendingAndKeepFile() public {
        string memory p = _path("nonce-pending");
        _cleanup(p);
        ProgressGuardHarness h = new ProgressGuardHarness(p, true);
        h.recordPending(V2, 7);
        vm.setNonce(OWNER, 7);
        vm.expectRevert(
            bytes(
                "Progress file names a PauserV2 with NO CODE, but OWNER has not consumed its create nonce 7: the deploy tx may be PENDING. Wait, or replace nonce 7 with a higher PAUSER_V2_GAS_PRICE_WEI. Do NOT delete the progress file."
            )
        );
        h.requireLanded(V2);
        _cleanup(p);
    }

    function test_noCode_nonceConsumed_saysNeverLanded() public {
        string memory p = _path("nonce-consumed");
        _cleanup(p);
        ProgressGuardHarness h = new ProgressGuardHarness(p, true);
        h.recordPending(V2, 7);
        vm.setNonce(OWNER, 8);
        vm.expectRevert(
            bytes(
                string.concat(
                    "Progress file names a PauserV2 with NO CODE although OWNER consumed its create nonce 7: the deploy never landed. Delete ",
                    p,
                    " and re-run preview."
                )
            )
        );
        h.requireLanded(V2);
        _cleanup(p);
    }

    function test_code_passes() public {
        string memory p = _path("landed");
        _cleanup(p);
        ProgressGuardHarness h = new ProgressGuardHarness(p, true);
        h.recordPending(V2, 7);
        vm.etch(V2, hex"00");
        h.requireLanded(V2);
        _cleanup(p);
    }
}
