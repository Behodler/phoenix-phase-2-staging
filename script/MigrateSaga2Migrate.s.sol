// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*//////////////////////////////////////////////////////////////////////////////
                          MIGRATE SAGA 2 — STEP 2.2 (MIGRATE)
//////////////////////////////////////////////////////////////////////////////

The time-critical leg. Must run inside the in-flight totalWithdrawal execution window on the OLD
DOLA/USDC strategies: [initiatedAt + 24h, initiatedAt + 72h] (deployed bytecode uses the OLD
24h-wait / 48h-window timing, NOT the 6h/72h in current lib source). See
docs/stable-staker-migrations/combined-inplace-and-minter-v2-migration-plan.md §4.

ORDER IS LOAD-BEARING (plan §3.2): the staker must drain BEFORE the minter's totalWithdrawal so the
minter absorbs any haircut and stakers stay whole. Sequence (all as owner):

  1. Capture old strategies + real pauser. Pause the staker (setPauser(owner) + pause()).
  2. skimSurplus old DOLA/USDC -> owner (measured), USDe -> staker (buffer, no sweep risk).
  3. initiateMigration + migrateOut DOLA/USDC  (STAKER DRAINS FIRST; principal parked in migrator).
  4. oldYS.totalWithdrawal(token, minterV1) phase-2 DOLA/USDC (MINTER DRAINS SECOND -> owner).
  5. finalizeAndReset + setYieldStrategy(new) DOLA/USDC.
  6. migrateIn DOLA/USDC (re-credit parked stakers into the new strategies).
  7. Seed V2 with the recovered minter funds via noMintDeposit (amount = what the owner actually
     received in step 4 — minter bears the haircut; NOT the 2.1-recorded principal).
  8. Transfer the skimmed DOLA/USDC surplus to the staker as a set-aside buffer (AFTER the rewire,
     so setYieldStrategy never sweeps it into the YS).
  9. unpause + restore the real pauser.

No new contracts are deployed here, so mainnet-addresses.ts is NOT touched by this step.
*/

contract MigrateSaga2Migrate is Script {
    using SafeERC20 for IERC20;

    uint256 public constant CHAIN_ID = 1;

    address public constant OWNER_ADDRESS  = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant STAKER         = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    address public constant MINTER_V1      = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant DOLA           = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC           = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDE           = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant USDE_MARKET_YS = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;
    address public constant PHLIMBO_V2     = 0x6084a02C2Ac0127ddF1e617De257c61480A2AeE0;

    uint256 public constant PHLIMBO_COLLECT_AMOUNT = 60e6; // 60 USDC, from the deployer's wallet

    string public constant DEPLOYMENTS_JSON = "script/migration-inputs/saga2-deployments.json";

    bool public isPreview;

    // from 2.1
    address public migrator;
    address public ysDolaV2;
    address public ysUsdcV2;
    address public minterV2;

    // captured old strategies (read BEFORE initiateMigration zeroes them on the staker)
    address public oldDolaYS;
    address public oldUsdcYS;
    address public realPauser;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "saga2.2: wrong chain - expected mainnet (1)");
    }

    function run() external {
        isPreview = vm.envOr("PREVIEW_MODE", false);
        _loadDeployments();
        _preflight();

        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE ***");
            vm.startBroadcast();
        }

        // 1. Pause the staker (capture & restore the real pauser at the end).
        realPauser = IStaker(STAKER).pauser();
        IStaker(STAKER).setPauser(OWNER_ADDRESS);
        IStaker(STAKER).pause();

        // 1b. Top up Phlimbo's reward pot from the deployer (60 USDC). The yield accumulator has been
        //     on hold, so Phlimbo's linear-depletion window is almost consumed; refill it here.
        IERC20(USDC).forceApprove(PHLIMBO_V2, PHLIMBO_COLLECT_AMOUNT);
        IPhlimbo(PHLIMBO_V2).collectReward(PHLIMBO_COLLECT_AMOUNT);
        console.log("Phlimbo topped up with USDC:", PHLIMBO_COLLECT_AMOUNT);

        // 2. Skim surplus. Ensure owner is an authorized withdrawer first. DOLA/USDC go to the owner
        //    (measured, transferred to the staker only AFTER the rewire); USDe goes straight to the
        //    staker as buffer (its pool is not rewired, so there is no setYieldStrategy sweep risk).
        _ensureWithdrawer(oldDolaYS);
        _ensureWithdrawer(oldUsdcYS);
        _ensureWithdrawer(USDE_MARKET_YS);
        uint256 dolaSkim = IOldYS(oldDolaYS).skimSurplus(DOLA, OWNER_ADDRESS);
        uint256 usdcSkim = IOldYS(oldUsdcYS).skimSurplus(USDC, OWNER_ADDRESS);
        uint256 usdeSkim = IOldYS(USDE_MARKET_YS).skimSurplus(USDE, STAKER);
        console.log("skim DOLA/USDC->owner, USDe->staker:", dolaSkim, usdcSkim);
        console.log("   USDe skim:", usdeSkim);

        // 3. STAKER DRAINS FIRST.
        _drainStaker(DOLA);
        _drainStaker(USDC);

        // 4. MINTER DRAINS SECOND (totalWithdrawal phase-2 -> owner). Measure recovered by balance delta.
        uint256 recoveredDola = _executeMinterWithdrawal(oldDolaYS, DOLA);
        uint256 recoveredUsdc = _executeMinterWithdrawal(oldUsdcYS, USDC);
        console.log("recovered minter DOLA/USDC:", recoveredDola, recoveredUsdc);

        // 5. Rewire the now-empty pools onto the new strategies.
        IStaker(STAKER).finalizeAndReset(DOLA);
        IStaker(STAKER).finalizeAndReset(USDC);
        IStaker(STAKER).setYieldStrategy(DOLA, ysDolaV2);
        IStaker(STAKER).setYieldStrategy(USDC, ysUsdcV2);

        // 6. Re-inject the parked stakers into the new strategies (one slice; clamps internally).
        IMigrator(migrator).migrateIn(DOLA, 0, type(uint256).max);
        IMigrator(migrator).migrateIn(USDC, 0, type(uint256).max);

        // 7. Seed V2 with the recovered minter funds (minter eats the haircut).
        _seedV2(DOLA, ysDolaV2, recoveredDola);
        _seedV2(USDC, ysUsdcV2, recoveredUsdc);

        // 8. Transfer skimmed surplus to the staker as a set-aside buffer (AFTER the rewire).
        if (dolaSkim > 0) IERC20(DOLA).safeTransfer(STAKER, dolaSkim);
        if (usdcSkim > 0) IERC20(USDC).safeTransfer(STAKER, usdcSkim);

        // 8b. Refund any unused in-place allotment to the deployer. migrateIn is complete so
        //     totalParked == 0 (post-asserted below) and the migrator's whole DOLA/USDC balance is
        //     rescuable surplus; rescueERC20 is fenced below the parked floor regardless.
        uint256 leftDola = IERC20(DOLA).balanceOf(migrator);
        uint256 leftUsdc = IERC20(USDC).balanceOf(migrator);
        if (leftDola > 0) IMigrator(migrator).rescueERC20(DOLA, OWNER_ADDRESS, leftDola);
        if (leftUsdc > 0) IMigrator(migrator).rescueERC20(USDC, OWNER_ADDRESS, leftUsdc);
        console.log("refunded unused allotment DOLA/USDC:", leftDola, leftUsdc);

        // 9. Unpause and restore the original pauser.
        IStaker(STAKER).unpause();
        IStaker(STAKER).setPauser(realPauser);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _postAssert();
    }

    function _drainStaker(address token) internal {
        address[] memory users = IStaker(STAKER).getStakers(token);
        IMigrator(migrator).initiateMigration(token);
        IMigrator(migrator).migrateOut(token, users);
        require(IStaker(STAKER).stakerCount(token) == 0, "saga2.2: staker pool not fully drained");
        console.log("drained staker users:", users.length);
    }

    function _executeMinterWithdrawal(address oldYS, address token) internal returns (uint256 recovered) {
        uint256 before = IERC20(token).balanceOf(OWNER_ADDRESS);
        // Phase-2 execute of the in-flight totalWithdrawal (must be in the Executable window). Redeems
        // the minter's live proportional share of the now-residual pool to the strategy owner.
        IOldYS(oldYS).totalWithdrawal(token, MINTER_V1);
        recovered = IERC20(token).balanceOf(OWNER_ADDRESS) - before;
    }

    function _seedV2(address token, address newYS, uint256 amount) internal {
        if (amount == 0) {
            console.log("seed V2 skipped (0 recovered) for token:", token);
            return;
        }
        IERC20(token).forceApprove(minterV2, amount);
        IMinterV2(minterV2).noMintDeposit(newYS, token, amount);
        console.log("seeded V2 newYS with recovered:", amount);
    }

    function _ensureWithdrawer(address ys) internal {
        if (!IOldYS(ys).authorizedWithdrawers(OWNER_ADDRESS)) {
            IOldYS(ys).setWithdrawer(OWNER_ADDRESS, true);
        }
    }

    function _loadDeployments() internal {
        string memory raw = vm.readFile(DEPLOYMENTS_JSON);
        migrator = vm.parseJsonAddress(raw, ".migrator");
        ysDolaV2 = vm.parseJsonAddress(raw, ".ysDolaV2");
        ysUsdcV2 = vm.parseJsonAddress(raw, ".ysUsdcV2");
        minterV2 = vm.parseJsonAddress(raw, ".minterV2");
        require(
            migrator != address(0) && ysDolaV2 != address(0) && ysUsdcV2 != address(0) && minterV2 != address(0),
            "saga2.2: deployments JSON incomplete - run saga 2.1 broadcast first"
        );
    }

    function _preflight() internal {
        require(IStaker(STAKER).owner() == OWNER_ADDRESS, "saga2.2 preflight: not staker owner");
        require(
            IERC20(USDC).balanceOf(OWNER_ADDRESS) >= PHLIMBO_COLLECT_AMOUNT,
            "saga2.2 preflight: owner needs >= 60 USDC for Phlimbo collectReward"
        );
        // The migrator must already be wired (2.1).
        require(IStaker(STAKER).migrator() == migrator, "saga2.2 preflight: migrator not set - run 2.1");

        // Capture the old strategies BEFORE any drain (initiateMigration zeroes staker.yieldStrategy).
        oldDolaYS = IStaker(STAKER).yieldStrategy(DOLA);
        oldUsdcYS = IStaker(STAKER).yieldStrategy(USDC);
        require(oldDolaYS != address(0) && oldUsdcYS != address(0), "saga2.2 preflight: old strategy already cleared");

        // The minter V1 must hold its position on the SAME strategy we will totalWithdrawal from.
        require(
            IOldYS(oldDolaYS).principalOf(DOLA, MINTER_V1) >= 0 && IOldYS(oldUsdcYS).principalOf(USDC, MINTER_V1) >= 0,
            "saga2.2 preflight: minter principal read failed"
        );
    }

    function _postAssert() internal view {
        require(IStaker(STAKER).yieldStrategy(DOLA) == ysDolaV2, "post: DOLA strategy != ysDolaV2");
        require(IStaker(STAKER).yieldStrategy(USDC) == ysUsdcV2, "post: USDC strategy != ysUsdcV2");
        require(IMigrator(migrator).parkedUserCount(DOLA) == 0, "post: DOLA users still parked");
        require(IMigrator(migrator).parkedUserCount(USDC) == 0, "post: USDC users still parked");
        require(IERC20(DOLA).balanceOf(migrator) == 0, "post: DOLA allotment not refunded");
        require(IERC20(USDC).balanceOf(migrator) == 0, "post: USDC allotment not refunded");
        require(!IStaker(STAKER).paused(), "post: staker still paused");
        require(IStaker(STAKER).pauser() == realPauser, "post: pauser not restored");
        require(IOldYS(oldDolaYS).principalOf(DOLA, MINTER_V1) == 0, "post: minter V1 DOLA not drained");
        require(IOldYS(oldUsdcYS).principalOf(USDC, MINTER_V1) == 0, "post: minter V1 USDC not drained");
        console.log("==========================================");
        console.log("  SAGA 2.2 (migrate) post-asserts passed");
        console.log("==========================================");
    }
}

// ───────────────────────────── minimal interfaces ─────────────────────────────

interface IStaker {
    function owner() external view returns (address);
    function pauser() external view returns (address);
    function migrator() external view returns (address);
    function setPauser(address) external;
    function pause() external;
    function unpause() external;
    function getStakers(address token) external view returns (address[] memory);
    function stakerCount(address token) external view returns (uint256);
    function finalizeAndReset(address token) external;
    function setYieldStrategy(address token, address strategy) external;
    function yieldStrategy(address token) external view returns (address);
    function paused() external view returns (bool);
}

interface IOldYS {
    function skimSurplus(address token, address recipient) external returns (uint256);
    function totalWithdrawal(address token, address client) external;
    function principalOf(address token, address account) external view returns (uint256);
    function authorizedWithdrawers(address) external view returns (bool);
    function setWithdrawer(address withdrawer, bool auth) external;
}

interface IMigrator {
    function initiateMigration(address token) external;
    function migrateOut(address token, address[] calldata users) external;
    function migrateIn(address token, uint256 start, uint256 end) external;
    function parkedUserCount(address token) external view returns (uint256);
    function rescueERC20(address token, address to, uint256 amount) external;
}

interface IMinterV2 {
    function noMintDeposit(address yieldStrategy, address inputToken, uint256 amount) external;
}

interface IPhlimbo {
    function collectReward(uint256 amount) external;
}
