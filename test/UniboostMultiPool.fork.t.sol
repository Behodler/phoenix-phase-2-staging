// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniboostMultiPool} from "../script/UniboostMultiPool.s.sol";

/// @dev The script with its I/O seams pinned: tolerance, per-row amounts and mode are injected, never read from the
///      process-wide env. The address book is the real mainnet-addresses.ts (the live keys are what is under test).
contract UniboostMultiPoolHarness is UniboostMultiPool {
    uint256 internal tol = 50;
    uint256 internal eye = type(uint256).max;
    uint256 internal scx = type(uint256).max;
    uint256 internal flx = type(uint256).max;

    function setTol(uint256 t) external {
        tol = t;
    }

    function setAmounts(uint256 e, uint256 s, uint256 f) external {
        (eye, scx, flx) = (e, s, f);
    }

    function _toleranceFromEnv() internal view override returns (uint256) {
        return tol;
    }

    function _amountsFromEnv() internal view override returns (uint256, uint256, uint256) {
        return (eye, scx, flx);
    }

    function _previewModeFromEnv() internal pure override returns (bool) {
        return true; // OWNER prank
    }
}

interface IUniboostLike {
    function targetPool() external view returns (address);
}

interface IMultiPoolerLike {
    function setPooler(address) external;
}

/**
 * @title UniboostMultiPoolForkTest
 * @notice Mainnet fork (skipped without RPC_MAINNET): the MultiPooler batch over the live Uniboost EYE/SCX/FLX
 *         dispatchers, with each dispatcher's USDC topped up by `deal`. The USDC is zapped into each target/WETH pair,
 *         the LP stays on the dispatcher, and OWNER's balances of USDC and every LP token are unchanged (the
 *         gas-only ledger position). Bad inputs and a revoked pooler are refused before anything is sent.
 */
contract UniboostMultiPoolForkTest is Test {
    uint256 constant FORK_BLOCK = 26_466_111;
    uint256 constant TOP_UP = 200e6; // 200 USDC per dispatcher

    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MULTIPOOLER = 0xd1E5774159381915f5579dFd68507E2614f67b51;
    address constant EYE = 0x9cd4E3EB3B519C925a0000239990E27F9019f3B3;
    address constant SCX = 0x665919d494b4294C643e4f3FA96EaC729b943585;
    address constant FLX = 0xBda3314052Ae46b912F22B6202F2c66641eEd183;

    UniboostMultiPoolHarness s;
    address[3] ubs;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        ubs = [EYE, SCX, FLX];
        for (uint256 i; i < 3; i++) {
            deal(USDC, ubs[i], IERC20(USDC).balanceOf(ubs[i]) + TOP_UP);
        }
        s = new UniboostMultiPoolHarness();
    }

    function test_fork_poolsAllThree_lpStaysOnDispatchers_ownerUntouched() public {
        uint256[3] memory lpBefore;
        uint256[3] memory ownerLpBefore;
        for (uint256 i; i < 3; i++) {
            address lp = IUniboostLike(ubs[i]).targetPool();
            lpBefore[i] = IERC20(lp).balanceOf(ubs[i]);
            ownerLpBefore[i] = IERC20(lp).balanceOf(OWNER);
        }
        uint256 ownerUsdc = IERC20(USDC).balanceOf(OWNER);

        s.run();

        for (uint256 i; i < 3; i++) {
            address lp = IUniboostLike(ubs[i]).targetPool();
            assertEq(IERC20(USDC).balanceOf(ubs[i]), 0, "all USDC pooled");
            assertGt(IERC20(lp).balanceOf(ubs[i]), lpBefore[i], "LP minted to the dispatcher");
            assertEq(IERC20(lp).balanceOf(OWNER), ownerLpBefore[i], "no LP to OWNER");
        }
        assertEq(IERC20(USDC).balanceOf(OWNER), ownerUsdc, "no USDC to/from OWNER");
    }

    function test_fork_partialAndSkippedRows() public {
        uint256 scxBal = IERC20(USDC).balanceOf(SCX);
        s.setAmounts(0, 50e6, type(uint256).max);
        s.run();
        assertEq(IERC20(USDC).balanceOf(SCX), scxBal - 50e6, "SCX pooled exactly the requested amount");
        assertEq(IERC20(USDC).balanceOf(FLX), 0, "FLX pooled in full");
        assertGt(IERC20(USDC).balanceOf(EYE), 0, "EYE skipped");
    }

    function test_fork_revert_toleranceTooLoose() public {
        s.setTol(101);
        vm.expectRevert(bytes("input: UNIBOOST_POOL_TOLERANCE_BPS must be 1..100"));
        s.run();
    }

    function test_fork_revert_zeroTolerance() public {
        s.setTol(0);
        vm.expectRevert(bytes("input: UNIBOOST_POOL_TOLERANCE_BPS must be 1..100"));
        s.run();
    }

    function test_fork_revert_moreThanBalance() public {
        s.setAmounts(IERC20(USDC).balanceOf(EYE) + 1, 0, 0);
        vm.expectRevert(bytes("input: UNIBOOST_POOL_EYE_USDC exceeds the balance"));
        s.run();
    }

    function test_fork_revert_nothingToPool() public {
        s.setAmounts(0, 0, 0);
        vm.expectRevert(bytes("preflight: no Uniboost has poolable USDC - nothing to pool"));
        s.run();
    }

    function test_fork_revert_poolerRevoked() public {
        vm.prank(OWNER);
        IMultiPoolerLike(MULTIPOOLER).setPooler(address(0));
        vm.expectRevert(bytes("preflight: MultiPooler.pooler() is not OWNER"));
        s.run();
    }
}
