// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {MigratePauserV2Mainnet} from "../script/MigratePauserV2Mainnet.s.sol";

contract ResolveHarness is MigratePauserV2Mainnet {
    function pick(address envV2, address recorded, bool recordedCompleted, bool preview)
        external
        pure
        returns (address)
    {
        return _pickPauserV2(envV2, recorded, recordedCompleted, preview);
    }
}

/// @notice Audit run 49 L-05: migrate took env PAUSER_V2 over the deploy progress file with no agreement check, so
///         a stale shell variable could rotate every registrant onto a PauserV2 the book and patcher never name.
contract PauserV2ResolveGuardTest is Test {
    ResolveHarness h;
    address constant A = address(0xA11CE);
    address constant B = address(0xB0B);

    function setUp() public {
        h = new ResolveHarness();
    }

    function test_envAndProgressAgree_returnsIt() public view {
        assertEq(h.pick(A, A, true, false), A);
    }

    function test_envDisagreesWithProgress_reverts() public {
        vm.expectRevert(bytes("migrate: PAUSER_V2 != progress.pauser-v2.1.json's PauserV2 - unset the stale env var"));
        h.pick(B, A, true, false);
    }

    function test_envDisagreesWithProgress_revertsInPreviewToo() public {
        vm.expectRevert(bytes("migrate: PAUSER_V2 != progress.pauser-v2.1.json's PauserV2 - unset the stale env var"));
        h.pick(B, A, true, true);
    }

    function test_envOnly_previewIsAllowed() public view {
        assertEq(h.pick(A, address(0), false, true), A);
    }

    function test_envOnly_broadcastReverts() public {
        vm.expectRevert(
            bytes("migrate: broadcast needs progress.pauser-v2.1.json - env PAUSER_V2 alone is a preview convenience")
        );
        h.pick(A, address(0), false, false);
    }

    function test_progressPending_broadcastReverts() public {
        vm.expectRevert(
            bytes(
                "migrate: progress.pauser-v2.1.json is not completed - run node scripts/confirm-pauser-v2-progress.js"
            )
        );
        h.pick(address(0), A, false, false);
    }

    function test_progressCompleted_broadcastReturnsIt() public view {
        assertEq(h.pick(address(0), A, true, false), A);
    }

    function test_neither_previewReturnsZero() public view {
        assertEq(h.pick(address(0), address(0), false, true), address(0));
    }

    function test_neither_broadcastReverts() public {
        vm.expectRevert(
            bytes(
                "No PauserV2: set PAUSER_V2 or run npm run pauser-v2-deploy:broadcast first (it writes server/deployments/progress.pauser-v2.1.json)"
            )
        );
        h.pick(address(0), address(0), false, false);
    }
}
