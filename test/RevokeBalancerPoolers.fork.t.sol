// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    RevokeBalancerPoolersHoldingPattern,
    IBalancerPoolerV2Holding
} from "../script/RevokeBalancerPoolersHoldingPattern.s.sol";
import {VerifyBalancerHolding} from "../script/VerifyBalancerHolding.s.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Pins PREVIEW (OWNER prank, never the process-wide PREVIEW_MODE env, which races parallel suites).
contract RevokeBalancerPoolersHarness is RevokeBalancerPoolersHoldingPattern {
    function _previewModeFromEnv() internal pure override returns (bool) {
        return true;
    }
}

/**
 * @title RevokeBalancerPoolersForkTest  (story 099, sprint Balancexit)
 * @notice Drives the holding-pattern revocation against a mainnet fork of the live BalancerPoolerV2 0x7f68...11F1.
 *         Skips cleanly when RPC_MAINNET is unset (CI runs plain `forge test` with no RPC).
 *         Proves: before revocation all four poolers pass `onlyAuthorizedPooler`; after it each of them reverts with
 *         the exact auth string; NFTMinter `dispatch` (index 4) still wraps USDS -> sUSDS; a re-run is a no-op; the
 *         read-only verifier fails before and passes after.
 */
contract RevokeBalancerPoolersForkTest is Test {
    /// @dev Recent mainnet block (2026-10-01). authVersion == 1 and all four poolers authorized at this block.
    uint256 constant FORK_BLOCK = 26_094_200;

    string constant AUTH_ERROR = "BalancerPoolerV2: caller not authorized pooler";
    string constant NOTHING_TO_POOL = "BalancerPoolerV2: nothing to pool";

    RevokeBalancerPoolersHarness script;
    VerifyBalancerHolding verifier;
    IBalancerPoolerV2Holding pooler;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        script = new RevokeBalancerPoolersHarness();
        verifier = new VerifyBalancerHolding();
        pooler = IBalancerPoolerV2Holding(script.BALANCER_POOLER_V2());
        return true;
    }

    function _poolers() internal view returns (address[4] memory) {
        return script.poolers();
    }

    function test_fork_revocation_blocks_all_four_poolers() public {
        if (!_fork()) return;

        address[4] memory ps = _poolers();
        uint256 v0 = pooler.authVersion();

        // Positive control: before revocation every pooler PASSES the auth modifier and reaches the body.
        // The pooler holds no sUSDS at the fork block, so the body reverts "nothing to pool" (auth already passed).
        assertEq(IERC20Min(script.SUSDS()).balanceOf(address(pooler)), 0, "fork block: pooler holds no sUSDS");
        for (uint256 i = 0; i < 4; i++) {
            assertEq(pooler.poolerAuthVersion(ps[i]), v0, "fork block: pooler authorized");
            vm.prank(ps[i]);
            vm.expectRevert(bytes(NOTHING_TO_POOL));
            pooler.pool(0);
        }

        script.run();

        assertEq(pooler.authVersion(), v0 + 1, "authVersion bumped exactly once");
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(pooler.poolerAuthVersion(ps[i]) != pooler.authVersion(), "pooler unauthorized");
            vm.prank(ps[i]);
            vm.expectRevert(bytes(AUTH_ERROR));
            pooler.pool(0);
        }
    }

    function test_fork_mint_dispatch_unaffected_after_revocation() public {
        if (!_fork()) return;

        script.run();

        address usds = script.USDS();
        address susds = script.SUSDS();
        uint256 amount = 100e18;
        uint256 susdsBefore = IERC20Min(susds).balanceOf(address(pooler));

        // NFTMinterV2 transfers the USDS payment to the dispatcher, then calls dispatch (index 4).
        deal(usds, address(pooler), IERC20Min(usds).balanceOf(address(pooler)) + amount);
        // Cache first: `vm.prank` applies to the NEXT external call, and script.NFT_MINTER() is one.
        address minter = script.NFT_MINTER();
        vm.prank(minter);
        pooler.dispatch(minter, amount, "");

        assertGt(IERC20Min(susds).balanceOf(address(pooler)), susdsBefore, "dispatch wrapped USDS into sUSDS");

        // With sUSDS now on the pooler, a revoked pooler still cannot push it into the Balancer pool.
        address[4] memory ps = _poolers();
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(ps[i]);
            vm.expectRevert(bytes(AUTH_ERROR));
            pooler.pool(0);
        }
    }

    function test_fork_rerun_is_noop() public {
        if (!_fork()) return;

        script.run();
        uint256 v1 = pooler.authVersion();
        script.run();
        assertEq(pooler.authVersion(), v1, "second run must not bump authVersion again");
    }

    function test_fork_verify_fails_before_and_passes_after() public {
        if (!_fork()) return;

        vm.expectRevert(bytes("verify: pooler still authorized"));
        verifier.run();

        script.run();
        verifier.run();
    }
}
