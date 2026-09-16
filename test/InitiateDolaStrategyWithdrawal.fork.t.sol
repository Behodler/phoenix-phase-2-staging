// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    InitiateDolaStrategyWithdrawal,
    IDolaYieldStrategyLive
} from "../script/InitiateDolaStrategyWithdrawal.s.sol";

/// @dev Pins PREVIEW (OWNER prank, never the process-wide PREVIEW_MODE env).
contract InitiateDolaStrategyWithdrawalHarness is InitiateDolaStrategyWithdrawal {
    function _previewModeFromEnv() internal pure override returns (bool) {
        return true;
    }
}

/// @dev Same, but aims the script at StableStaker V1 to prove the client guard.
contract InitiateDolaStrategyWithdrawalV1Harness is InitiateDolaStrategyWithdrawalHarness {
    function _client() internal pure override returns (address) {
        return STABLE_STAKER_V1;
    }
}

/**
 * @title InitiateDolaStrategyWithdrawalForkTest  (story 090)
 * @notice Drives the initiate-only script against a mainnet fork of the live autoDOLA strategy 0x1760.
 *         Skips cleanly when RPC_MAINNET is unset (CI runs plain `forge test` with no RPC).
 *         Anchor timestamps live in STORAGE: under via_ir a local copy of block.timestamp is re-read after vm.warp.
 */
contract InitiateDolaStrategyWithdrawalForkTest is Test {
    uint256 constant FORK_BLOCK = 25_978_784;

    InitiateDolaStrategyWithdrawalHarness script;
    IDolaYieldStrategyLive strategy;
    address DOLA;
    address MINTER;
    /// @dev Storage, not a local: via_ir folds a `uint256 t = block.timestamp` local into later reads (after warps).
    uint256 t0;
    uint256 t4;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        script = new InitiateDolaStrategyWithdrawalHarness();
        strategy = IDolaYieldStrategyLive(script.YIELD_STRATEGY_DOLA());
        DOLA = script.DOLA();
        MINTER = script.PHUSD_STABLE_MINTER();
        return true;
    }

    function _state() internal view returns (uint256 initiatedAt, uint8 status, uint256 balance) {
        return strategy.withdrawalStates(DOLA, MINTER);
    }

    function test_fork_initiate_then_refuses_in_wait_and_window_then_reinitiates_after_expiry() public {
        if (!_fork()) return;

        uint256 principal = strategy.principalOf(DOLA, MINTER);
        assertGt(principal, 0, "fork block: minter has DOLA principal");
        (, uint8 s0,) = _state();
        assertEq(s0, 0, "fork block: no withdrawal pending");

        // 1. first run initiates
        t0 = block.timestamp;
        script.run();
        (uint256 initiatedAt, uint8 s1, uint256 bal1) = _state();
        assertEq(s1, 1, "status Initiated");
        assertEq(bal1, principal, "snapshot == principal");
        assertEq(initiatedAt, t0, "initiatedAt == now");
        assertEq(strategy.principalOf(DOLA, MINTER), principal, "initiate moves nothing");

        // 2. re-run inside the waiting period reverts at the script preflight
        vm.warp(t0 + 1 hours);
        vm.expectRevert(
            bytes(
                "preflight: DOLA withdrawal ALREADY PENDING (in 6h waiting period) - do not re-run; check npm run dola-ys-withdrawal:status"
            )
        );
        script.run();

        // 3. inside the execution window the script still refuses (the strategy WOULD execute) and nothing moves
        vm.warp(t0 + 6 hours + 1);
        vm.expectRevert(
            bytes(
                "preflight: DOLA withdrawal ALREADY PENDING and INSIDE its execution window - a second totalWithdrawal would EXECUTE and move the minter's DOLA to OWNER; that belongs only to story 092's cutover. Check npm run dola-ys-withdrawal:status"
            )
        );
        script.run();
        assertEq(strategy.principalOf(DOLA, MINTER), principal, "window refusal: principal unchanged");
        (uint256 ia3, uint8 s3, uint256 bal3) = _state();
        assertEq(ia3, t0, "window refusal: initiatedAt unchanged");
        assertEq(s3, 1, "window refusal: status unchanged");
        assertEq(bal3, principal, "window refusal: snapshot unchanged");

        // also refuses at the last second of the window (contract uses <= initiatedAt + 78h)
        vm.warp(t0 + 78 hours);
        vm.expectRevert();
        script.run();

        // 4. past 78h: lazy expiry, the script re-initiates
        t4 = t0 + 78 hours + 1;
        vm.warp(t4);
        script.run();
        (uint256 ia4, uint8 s4, uint256 bal4) = _state();
        assertEq(s4, 1, "re-initiated: status Initiated");
        assertEq(ia4, t4, "re-initiated: fresh initiatedAt");
        assertEq(bal4, strategy.principalOf(DOLA, MINTER), "re-initiated: snapshot == principal");
        assertEq(strategy.principalOf(DOLA, MINTER), principal, "re-initiate moves nothing");
    }

    function test_fork_refuses_stable_staker_v1_as_client() public {
        if (!_fork()) return;
        InitiateDolaStrategyWithdrawalV1Harness v1Script = new InitiateDolaStrategyWithdrawalV1Harness();
        vm.expectRevert(
            bytes("preflight: client is StableStaker V1 - V1 exits synchronously via initiateMigration in the cutover")
        );
        v1Script.run();
    }
}
