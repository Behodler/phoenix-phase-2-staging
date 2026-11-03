// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {DeployPauserV2Mainnet} from "../script/DeployPauserV2Mainnet.s.sol";
import {MigratePauserV2Mainnet} from "../script/MigratePauserV2Mainnet.s.sol";
import {VerifyPauserV2Migration} from "../script/VerifyPauserV2Migration.s.sol";
import {IPauserV2Pausable} from "../script/helpers/PauserV2MainnetBase.sol";

interface IV1PauserFork {
    function pause() external;
    function unregister(address c) external;
    function getPausableContracts() external view returns (address[] memory);
}

contract DeployPauserV2Harness is DeployPauserV2Mainnet {
    function _previewModeFromEnv() internal pure override returns (bool) {
        return true;
    }

    /// @dev Never read the real progress file from a test.
    function _progressPauserV2() internal pure override returns (address) {
        return address(0);
    }
}

contract MigratePauserV2Harness is MigratePauserV2Mainnet {
    address internal immutable injected;

    constructor(address v2) {
        injected = v2;
    }

    function _previewModeFromEnv() internal pure override returns (bool) {
        return true;
    }

    /// @dev Pinned to the PauserV2 the test deployed (env PAUSER_V2 and the progress file are process-wide).
    function _resolvePauserV2() internal view override returns (address) {
        return injected;
    }
}

contract VerifyPauserV2Harness is VerifyPauserV2Migration {
    address internal immutable injected;

    constructor(address v2) {
        injected = v2;
    }

    function _progressPauserV2() internal view override returns (address) {
        return injected;
    }

    /// @dev The book is patched only after the human's broadcast; on the fork it is as if patched.
    function _bookPauser() internal view override returns (address) {
        return injected;
    }
}

contract BookPauserReader is VerifyPauserV2Migration {
    function bookPauser() external view returns (address) {
        return _bookPauser();
    }
}

/**
 * @title MigratePauserV2MainnetForkTest  (story 128, sprint global-pauser-v2)
 * @notice Mainnet-fork rehearsal of `DeployPauserV2Mainnet` + `MigratePauserV2Mainnet` on the REAL registrants, then
 *         the design doc's brick triggers proven harmless against PauserV2:
 *           - trigger 1: owner `setPauser(address(0))` on a live registrant -> `V2.pause()` still pauses the rest;
 *           - trigger 2: owner pauses PhlimboV3 directly -> `V2.pause()` still succeeds;
 *           - trigger 3: owner unpauses Antimatter early after a global pause -> `V2.unpause()` unpauses the rest;
 *           - resumability: a second migration run is a no-op; a run interrupted mid-registrant resumes;
 *           - the preflight refuses a drifted V1 snapshot, and the verifier detects a registrant re-pointed at V1.
 *         Skipped without RPC_MAINNET. FORK_BLOCK is after the 27-registrant survey (~26,325,700) and after the
 *         classification sweep (26,333,708 was read live; StableStakerV2 is V1-registered at this block).
 */
contract MigratePauserV2MainnetForkTest is Test {
    uint256 constant FORK_BLOCK = 26_333_700;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant PAUSER_V1 = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address constant PHLIMBO_V3 = 0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca;
    address constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    address constant SSV2 = 0xA6d3fc83C91B8319D219cEB12B46e3dfF064B58F;

    PauserV2 v2;
    MigratePauserV2Harness migrator;
    address[] live;
    address[] retired;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(IV1PauserFork(PAUSER_V1).getPausableContracts().length, 27, "27 V1 registrants at FORK_BLOCK");

        DeployPauserV2Harness d = new DeployPauserV2Harness();
        d.run();
        assertTrue(d.deployedThisRun(), "deploy ran");
        v2 = d.pauserV2();
        assertEq(v2.owner(), OWNER);
        assertEq(v2.eyeToken(), EYE);
        assertEq(v2.eyeBurnAmount(), 1000e18);

        migrator = new MigratePauserV2Harness(address(v2));
        live = migrator.liveRegistrants();
        retired = migrator.retiredRegistrants();
        return true;
    }

    function _migrate() internal returns (uint256) {
        migrator = new MigratePauserV2Harness(address(v2));
        migrator.run();
        return migrator.txCount();
    }

    function _paused(address c) internal view returns (bool ok, bool p) {
        (bool success, bytes memory data) = c.staticcall(abi.encodeWithSignature("paused()"));
        if (!success || data.length < 32) return (false, false);
        uint256 w = abi.decode(data, (uint256));
        return (w <= 1, w == 1);
    }

    function _globalPause() internal {
        address actor = makeAddr("story128-test-eye-holder");
        deal(EYE, actor, 1000e18, false);
        vm.startPrank(actor);
        IERC20(EYE).approve(address(v2), 1000e18);
        v2.pause();
        vm.stopPrank();
    }

    // ------------------------------------------------------------------

    /// @dev No fork needed: the verifier's address-book parser reads the real, unpatched book (V1 until the human
    ///      runs scripts/patch-mainnet-addresses-pauser-v2.js after the broadcasts).
    function test_BookParser_ReadsUnpatchedV1Pauser() public {
        assertEq(new BookPauserReader().bookPauser(), PAUSER_V1);
    }

    function test_DeployAndMigrate_EndState() public {
        if (!_fork()) return;
        uint256 n = _migrate();
        assertEq(n, 2 * live.length, "one setPauser + one register per live registrant");

        assertEq(v2.getPausableContracts().length, live.length, "V2 holds exactly the live set");
        for (uint256 i = 0; i < live.length; i++) {
            assertEq(IPauserV2Pausable(live[i]).pauser(), address(v2), "live registrant on V2");
            assertTrue(v2.isRegistered(live[i]));
        }
        for (uint256 i = 0; i < retired.length; i++) {
            assertEq(IPauserV2Pausable(retired[i]).pauser(), PAUSER_V1, "retired registrant left on V1, untouched");
            assertFalse(v2.isRegistered(retired[i]));
        }
        (address[] memory notPauser, address[] memory alreadyPaused,, address[] memory unreachable) = v2.health();
        assertEq(notPauser.length + alreadyPaused.length + unreachable.length, 0, "V2 healthy");

        // As the design doc predicts, the V1 Pauser is now dead (trigger 1 on every rotated registrant).
        address actor = makeAddr("story128-v1-actor");
        deal(EYE, actor, 1000e18, false);
        vm.startPrank(actor);
        IERC20(EYE).approve(PAUSER_V1, 1000e18);
        vm.expectRevert();
        IV1PauserFork(PAUSER_V1).pause();
        vm.stopPrank();

        // The read-only verifier passes against the migrated fork.
        new VerifyPauserV2Harness(address(v2)).run();
    }

    function test_Resumable_SecondRunIsNoop() public {
        if (!_fork()) return;
        _migrate();
        assertEq(_migrate(), 0, "second run sends nothing");
    }

    function test_Resumable_InterruptedRunResumes() public {
        if (!_fork()) return;
        // Interrupted mid-way: the first two fully done, the third rotated but not yet registered.
        vm.startPrank(OWNER);
        IPauserV2Pausable(live[0]).setPauser(address(v2));
        v2.register(live[0]);
        IPauserV2Pausable(live[1]).setPauser(address(v2));
        v2.register(live[1]);
        IPauserV2Pausable(live[2]).setPauser(address(v2));
        vm.stopPrank();

        uint256 n = _migrate();
        assertEq(n, 2 * live.length - 5, "resume sends only the outstanding steps");
        assertEq(v2.getPausableContracts().length, live.length);
    }

    function test_Trigger1_SetPauserZero_PauseStillPausesTheRest() public {
        if (!_fork()) return;
        _migrate();

        // Owner disables one registrant's pauser - trigger 1, which bricks V1 for everyone.
        address victim = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b; // NFTStaker
        vm.prank(OWNER);
        IPauserV2Pausable(victim).setPauser(address(0));
        assertEq(IPauserV2Pausable(victim).pauser(), address(0));

        _globalPause();
        for (uint256 i = 0; i < live.length; i++) {
            (bool ok, bool p) = _paused(live[i]);
            if (!ok) continue;
            if (live[i] == victim) assertFalse(p, "the misconfigured registrant is skipped (NOT_PAUSER)");
            else assertTrue(p, "every other live registrant is paused");
        }
    }

    function test_Trigger2_OwnerPausedPhlimboV3_PauseSucceeds() public {
        if (!_fork()) return;
        _migrate();

        vm.prank(OWNER);
        IPauserV2Pausable(PHLIMBO_V3).pause();
        (, bool p) = _paused(PHLIMBO_V3);
        assertTrue(p, "owner paused PhlimboV3 directly");

        _globalPause();
        for (uint256 i = 0; i < live.length; i++) {
            (bool ok, bool isPaused) = _paused(live[i]);
            if (ok) assertTrue(isPaused, "every live registrant paused");
        }
    }

    function test_Trigger3_EarlyAntimatterUnpause_UnpauseStillUnpausesTheRest() public {
        if (!_fork()) return;
        _migrate();
        _globalPause();

        vm.prank(OWNER);
        IPauserV2Pausable(ANTIMATTER).unpause();
        (, bool amPaused) = _paused(ANTIMATTER);
        assertFalse(amPaused, "owner unpaused Antimatter early");

        vm.prank(OWNER);
        v2.unpause();
        for (uint256 i = 0; i < live.length; i++) {
            (bool ok, bool isPaused) = _paused(live[i]);
            if (ok) assertFalse(isPaused, "every live registrant unpaused");
        }
    }

    function test_Preflight_RefusesDriftedV1Snapshot() public {
        if (!_fork()) return;
        // Retire one more registrant from V1 by the documented order (setPauser away, then unregister).
        address gone = retired[0];
        vm.startPrank(OWNER);
        IPauserV2Pausable(gone).setPauser(OWNER);
        IV1PauserFork(PAUSER_V1).unregister(gone);
        vm.stopPrank();

        migrator = new MigratePauserV2Harness(address(v2));
        vm.expectRevert(
            bytes(
                "V1 registrant count differs from the story-128 snapshot - re-run the classification and update the live set"
            )
        );
        migrator.run();
    }

    function test_Verify_DetectsRegistrantRepointedAtV1() public {
        if (!_fork()) return;
        _migrate();
        // An old V1 recovery script (e.g. UnfreezeStableStakerV2AfterCutoverAbort) re-points SSV2 at V1.
        vm.prank(OWNER);
        IPauserV2Pausable(SSV2).setPauser(PAUSER_V1);

        VerifyPauserV2Harness verifier = new VerifyPauserV2Harness(address(v2));
        vm.expectRevert(bytes("verify: live registrant(s) not on PauserV2 - see the log above"));
        verifier.run();
    }
}
