// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm, console2} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalancerLPMigrator} from "../src/periphery/BalancerLPMigrator.sol";

/// @dev The Balancer V3 Vault admin calls the fork pranks (the mainnet Vault proxies them to VaultAdmin).
interface IForkV3VaultAdmin121 {
    function pausePool(address pool) external;
    function pauseVault() external;
    function enableRecoveryMode(address pool) external;
    function isPoolInRecoveryMode(address pool) external view returns (bool);
    function isPoolPaused(address pool) external view returns (bool);
    function isVaultPaused() external view returns (bool);
}

interface IForkV3Router121 {
    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsOut);
}

interface IForkUniV2Router121 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IForkUniV2Pair121 {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

/**
 * @title BalancerLPMigratorForkTest  (story 121, sprint balancer-lp-migrator)
 * @notice Runs `BalancerLPMigrator` against the live Balancer V3 phUSD/sUSDS pool, the real V3 Vault and Router,
 *         and the live Uniswap V2 phUSD/sUSDS pair (factory `feeTo` LIVE). Skips cleanly when RPC_MAINNET is unset,
 *         matching test/UniswapHelper.fork.t.sol.
 *
 *         Exit modes covered: proportional (live pool), pool paused and not yet in recovery (the migrator enables
 *         recovery itself), pool already in recovery, and Vault-level pause. Pauses are governance pranks from the
 *         holder of the `pausePool` / `pauseVault` action ids (checked against the Authorizer on mainnet).
 *
 *         PREVIEW TOLERANCE. `previewMigrate` must match `migrate` to within `PREVIEW_TOL_WEI` (2 wei) on every
 *         amount: the Balancer share is `balanceRaw * bpt / supply` rounded down (the Vault's own maths may round
 *         its intermediate ratio differently by at most a wei), and the V2 side replicates Router02 and the pair's
 *         `mint`, including the protocol-fee mint that precedes it.
 */
contract BalancerLPMigratorForkTest is Test {
    // ---- Mainnet (story 121 table) ----
    address constant VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address constant V3_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address constant POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address constant UNI_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant PAIR = 0x0b96b8ab66d40ba3C7501aa8C28Cdc37688F6F7f;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    /// @dev Holds the `pausePool`, `pauseVault` and `enableRecoveryMode` action ids via the Authorizer
    ///      0xA331D84eC860Bf466b4CdCcFb4aC09a1B43F3aE6 (checked with `canPerform` at FORK_BLOCK).
    address constant V3_GOVERNANCE = 0xA29F61256e948F3FB707b4b3B138C5cCb9EF9888;
    /// @dev The largest third-party BPT holder (~12,037 BPT, every BPT but the pool's 1e6 minimum supply).
    address constant HOLDER = 0xC65faaAFbbDa520791f344d33497485EDf58E8Db;

    /// @dev After the Balancexit cutover (block 26,254,520), before the BIP-928 pause: the pool is live, neither
    ///      paused nor in recovery, the HOLDER still holds its BPT and the V2 pair is seeded.
    uint256 constant FORK_BLOCK = 26_300_000;

    uint256 constant PREVIEW_TOL_WEI = 2;
    /// @dev Exit/add floors used by the happy paths: the preview less 1 bp.
    uint256 constant FLOOR_BPS = 1;

    BalancerLPMigrator internal m;
    address internal user;
    address internal lpTo;

    struct Preview {
        uint256 sOut;
        uint256 pOut;
        uint256 sUsed;
        uint256 pUsed;
        address leftoverToken;
        uint256 leftoverAmount;
        bool recovery;
        uint256 lp;
    }

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        m = new BalancerLPMigrator(VAULT, V3_ROUTER, POOL, UNI_ROUTER, SUSDS, PHUSD);
        user = makeAddr("user");
        lpTo = makeAddr("lpTo");
        // Real BPT, moved by a prank transfer from the live holder (never by writing BPT supply).
        vm.prank(HOLDER);
        IERC20(POOL).transfer(user, 2_000e18);
    }

    // ------------------------------------------------------------------ helpers

    function _preview(uint256 bpt) internal view returns (Preview memory p) {
        (p.sOut, p.pOut, p.sUsed, p.pUsed, p.leftoverToken, p.leftoverAmount, p.recovery, p.lp) = m.previewMigrate(bpt);
    }

    function _floor(uint256 x) internal pure returns (uint256) {
        return x - (x * FLOOR_BPS) / 10_000;
    }

    function _migrate(uint256 bpt, Preview memory p)
        internal
        returns (uint256 sOut, uint256 pOut, uint256 liq, uint256 sRef, uint256 pRef)
    {
        vm.startPrank(user);
        IERC20(POOL).approve(address(m), bpt);
        (sOut, pOut, liq, sRef, pRef) = m.migrate(
            bpt, _floor(p.sOut), _floor(p.pOut), _floor(p.sUsed), _floor(p.pUsed), lpTo, block.timestamp + 1 hours
        );
        vm.stopPrank();
    }

    function _assertMigratorEmpty() internal view {
        assertEq(IERC20(POOL).balanceOf(address(m)), 0, "migrator BPT");
        assertEq(IERC20(SUSDS).balanceOf(address(m)), 0, "migrator sUSDS");
        assertEq(IERC20(PHUSD).balanceOf(address(m)), 0, "migrator phUSD");
        assertEq(IERC20(PAIR).balanceOf(address(m)), 0, "migrator LP");
        assertEq(IERC20(POOL).allowance(address(m), V3_ROUTER), 0, "BPT allowance survives");
        assertEq(IERC20(SUSDS).allowance(address(m), UNI_ROUTER), 0, "sUSDS allowance survives");
        assertEq(IERC20(PHUSD).allowance(address(m), UNI_ROUTER), 0, "phUSD allowance survives");
    }

    /// @dev Full happy-path run: preview, migrate, and every post-condition. Returns the preview for extra checks.
    function _runAndAssert(uint256 bpt, bool expectRecovery) internal returns (Preview memory p) {
        p = _preview(bpt);
        assertEq(p.recovery, expectRecovery, "preview mode");

        uint256 userBptBefore = IERC20(POOL).balanceOf(user);
        uint256 userSBefore = IERC20(SUSDS).balanceOf(user);
        uint256 userPBefore = IERC20(PHUSD).balanceOf(user);
        uint256 lpBefore = IERC20(PAIR).balanceOf(lpTo);

        vm.recordLogs();
        (uint256 sOut, uint256 pOut, uint256 liq, uint256 sRef, uint256 pRef) = _migrate(bpt, p);

        console2.log("BPT in", bpt);
        console2.log("recovery mode", expectRecovery);
        console2.log("sUSDS out / refund", sOut, sRef);
        console2.log("phUSD out / refund", pOut, pRef);
        console2.log("LP minted", liq);

        // The mode the event reported.
        _assertEventMode(expectRecovery, bpt, sOut, pOut, liq, sRef, pRef);

        // LP to `to`, leftovers to the caller, BPT spent.
        assertGt(liq, 0, "LP minted");
        assertEq(IERC20(PAIR).balanceOf(lpTo) - lpBefore, liq, "LP to `to`");
        if (user != lpTo) assertEq(IERC20(PAIR).balanceOf(user), 0, "no LP to the caller");
        assertEq(userBptBefore - IERC20(POOL).balanceOf(user), bpt, "BPT pulled");
        assertEq(IERC20(SUSDS).balanceOf(user) - userSBefore, sRef, "sUSDS refund to caller");
        assertEq(IERC20(PHUSD).balanceOf(user) - userPBefore, pRef, "phUSD refund to caller");
        assertTrue(sRef == 0 || pRef == 0, "at most one side is left over");
        _assertMigratorEmpty();

        // Preview == actual, within PREVIEW_TOL_WEI.
        assertApproxEqAbs(sOut, p.sOut, PREVIEW_TOL_WEI, "preview sUSDSOut");
        assertApproxEqAbs(pOut, p.pOut, PREVIEW_TOL_WEI, "preview phUSDOut");
        assertApproxEqAbs(sOut - sRef, p.sUsed, PREVIEW_TOL_WEI, "preview sUSDSUsed");
        assertApproxEqAbs(pOut - pRef, p.pUsed, PREVIEW_TOL_WEI, "preview phUSDUsed");
        assertApproxEqAbs(liq, p.lp, PREVIEW_TOL_WEI, "preview LP");
        if (p.leftoverToken == SUSDS) {
            assertApproxEqAbs(sRef, p.leftoverAmount, PREVIEW_TOL_WEI, "preview sUSDS leftover");
        } else if (p.leftoverToken == PHUSD) {
            assertApproxEqAbs(pRef, p.leftoverAmount, PREVIEW_TOL_WEI, "preview phUSD leftover");
        }
    }

    function _assertEventMode(
        bool expectRecovery,
        uint256 bpt,
        uint256 sOut,
        uint256 pOut,
        uint256 liq,
        uint256 sRef,
        uint256 pRef
    ) internal view {
        bytes32 topic = keccak256("Migrated(address,address,uint256,bool,uint256,uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(m) || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))), "event user");
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(lpTo))), "event to");
            (uint256 b, bool rec, uint256 s, uint256 p, uint256 l, uint256 sr, uint256 pr) =
                abi.decode(logs[i].data, (uint256, bool, uint256, uint256, uint256, uint256, uint256));
            assertEq(b, bpt, "event bpt");
            assertEq(rec, expectRecovery, "event recoveryMode");
            assertEq(s, sOut, "event sUSDSOut");
            assertEq(p, pOut, "event phUSDOut");
            assertEq(l, liq, "event liquidity");
            assertEq(sr, sRef, "event sUSDSRefund");
            assertEq(pr, pRef, "event phUSDRefund");
            found = true;
        }
        assertTrue(found, "Migrated emitted");
    }

    /// @dev Swaps `amount` of `tokenIn` through the V2 pair to shift its ratio.
    function _skewPair(address tokenIn, uint256 amount) internal {
        address whale = makeAddr("whale");
        deal(tokenIn, whale, amount);
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenIn == SUSDS ? PHUSD : SUSDS;
        vm.startPrank(whale);
        IERC20(tokenIn).approve(UNI_ROUTER, amount);
        IForkUniV2Router121(UNI_ROUTER).swapExactTokensForTokens(amount, 1, path, whale, block.timestamp);
        vm.stopPrank();
    }

    function _assertForked() internal view {
        assertEq(block.chainid, 1, "not mainnet");
        assertEq(block.number, FORK_BLOCK, "not at FORK_BLOCK");
        assertGt(POOL.code.length, 0, "no pool code");
    }

    // ------------------------------------------------------------------ construction

    function test_fork_constructor_resolvesPoolOrderAndPair() public view {
        _assertForked();
        assertEq(m.vault(), VAULT);
        assertEq(m.v3Router(), V3_ROUTER);
        assertEq(m.pool(), POOL);
        assertEq(m.uniRouter(), UNI_ROUTER);
        assertEq(m.sUSDS(), SUSDS);
        assertEq(m.phUSD(), PHUSD);
        assertEq(m.pair(), PAIR, "pair resolved via factory.getPair");
        assertEq(m.sUSDSIndex(), 0, "pool token order [sUSDS, phUSD]");
        assertEq(m.phUSDIndex(), 1);
    }

    function test_fork_constructor_rejectsBadInputs() public {
        _assertForked();
        vm.expectRevert(BalancerLPMigrator.ZeroAddress.selector);
        new BalancerLPMigrator(address(0), V3_ROUTER, POOL, UNI_ROUTER, SUSDS, PHUSD);
        vm.expectRevert(BalancerLPMigrator.ZeroAddress.selector);
        new BalancerLPMigrator(VAULT, V3_ROUTER, POOL, UNI_ROUTER, SUSDS, address(0));
        // The pool's tokens must be exactly {sUSDS, phUSD}.
        address usds = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
        vm.expectRevert(BalancerLPMigrator.PoolTokensMismatch.selector);
        new BalancerLPMigrator(VAULT, V3_ROUTER, POOL, UNI_ROUTER, usds, PHUSD);
    }

    // ------------------------------------------------------------------ exit modes

    function test_fork_proportional_liveVault() public {
        _assertForked();
        assertFalse(IForkV3VaultAdmin121(VAULT).isPoolPaused(POOL));
        assertFalse(IForkV3VaultAdmin121(VAULT).isPoolInRecoveryMode(POOL));
        _runAndAssert(1_000e18, false);
        assertFalse(IForkV3VaultAdmin121(VAULT).isPoolInRecoveryMode(POOL), "proportional left recovery off");
    }

    function test_fork_holderMigratesWholeBalance() public {
        _assertForked();
        // The real holder migrates everything it has left, proportional path.
        uint256 bal = IERC20(POOL).balanceOf(HOLDER);
        assertGt(bal, 9_000e18, "holder BPT at FORK_BLOCK");
        Preview memory p = _preview(bal);
        lpTo = HOLDER;
        user = HOLDER;
        _runAndAssert(bal, false);
        assertEq(IERC20(POOL).balanceOf(HOLDER), 0, "holder fully migrated");
        assertGt(p.lp, 0);
    }

    function test_fork_pausedPool_migratorEnablesRecovery() public {
        _assertForked();
        vm.prank(V3_GOVERNANCE);
        IForkV3VaultAdmin121(VAULT).pausePool(POOL);
        assertTrue(IForkV3VaultAdmin121(VAULT).isPoolPaused(POOL), "pool paused");
        assertFalse(IForkV3VaultAdmin121(VAULT).isPoolInRecoveryMode(POOL), "recovery not yet on");

        // The proportional exit is dead once paused (what the migrator must route around).
        _assertProportionalReverts(1e18);

        _runAndAssert(1_000e18, true);
        assertTrue(IForkV3VaultAdmin121(VAULT).isPoolInRecoveryMode(POOL), "migrator enabled recovery mode");
    }

    function test_fork_alreadyInRecovery_recoveryPath() public {
        _assertForked();
        vm.prank(V3_GOVERNANCE);
        IForkV3VaultAdmin121(VAULT).pausePool(POOL);
        vm.prank(address(0xA11CE)); // permissionless once paused
        IForkV3VaultAdmin121(VAULT).enableRecoveryMode(POOL);
        assertTrue(IForkV3VaultAdmin121(VAULT).isPoolInRecoveryMode(POOL));
        _runAndAssert(1_000e18, true);
    }

    function test_fork_recoveryWithoutPause_recoveryPath() public {
        _assertForked();
        // Governance can turn recovery on without pausing; the migrator must still take the recovery exit.
        vm.prank(V3_GOVERNANCE);
        IForkV3VaultAdmin121(VAULT).enableRecoveryMode(POOL);
        assertFalse(IForkV3VaultAdmin121(VAULT).isPoolPaused(POOL));
        _runAndAssert(1_000e18, true);
    }

    function test_fork_vaultPaused_recoveryPath() public {
        _assertForked();
        vm.prank(V3_GOVERNANCE);
        IForkV3VaultAdmin121(VAULT).pauseVault();
        assertTrue(IForkV3VaultAdmin121(VAULT).isVaultPaused(), "vault paused");
        assertFalse(IForkV3VaultAdmin121(VAULT).isPoolPaused(POOL), "pool itself not paused");
        _runAndAssert(1_000e18, true);
        assertTrue(IForkV3VaultAdmin121(VAULT).isPoolInRecoveryMode(POOL), "migrator enabled recovery mode");
    }

    function _assertProportionalReverts(uint256 bpt) internal {
        vm.prank(HOLDER);
        IERC20(POOL).approve(V3_ROUTER, bpt);
        uint256[] memory mins = new uint256[](2);
        mins[0] = 1;
        mins[1] = 1;
        vm.prank(HOLDER);
        vm.expectRevert(abi.encodeWithSignature("PoolPaused(address)", POOL));
        IForkV3Router121(V3_ROUTER).removeLiquidityProportional(POOL, bpt, mins, false, "");
    }

    // ------------------------------------------------------------------ leftover direction

    function test_fork_leftover_phUSD() public {
        _assertForked();
        // Sell sUSDS into the pair: phUSD becomes scarce there, so sUSDS binds and phUSD is left over.
        _skewPair(SUSDS, 2_000e18);
        Preview memory p = _runAndAssert(1_000e18, false);
        assertEq(p.leftoverToken, PHUSD, "phUSD leftover");
        assertGt(p.leftoverAmount, 0);
    }

    function test_fork_leftover_sUSDS() public {
        _assertForked();
        // Sell phUSD into the pair: sUSDS becomes scarce there, so phUSD binds and sUSDS is left over.
        _skewPair(PHUSD, 2_000e18);
        Preview memory p = _runAndAssert(1_000e18, false);
        assertEq(p.leftoverToken, SUSDS, "sUSDS leftover");
        assertGt(p.leftoverAmount, 0);
    }

    function test_fork_leftover_sUSDS_inRecovery() public {
        _assertForked();
        _skewPair(PHUSD, 2_000e18);
        vm.prank(V3_GOVERNANCE);
        IForkV3VaultAdmin121(VAULT).pausePool(POOL);
        Preview memory p = _runAndAssert(1_000e18, true);
        assertEq(p.leftoverToken, SUSDS, "sUSDS leftover");
    }

    // ------------------------------------------------------------------ guards

    function _approve(uint256 bpt) internal {
        vm.prank(user);
        IERC20(POOL).approve(address(m), bpt);
    }

    function test_fork_reverts_zeroMinimums() public {
        _assertForked();
        uint256 bpt = 100e18;
        _approve(bpt);
        uint256 d = block.timestamp + 1 hours;
        vm.startPrank(user);
        vm.expectRevert(BalancerLPMigrator.ZeroMinimum.selector);
        m.migrate(bpt, 0, 1, 1, 1, lpTo, d);
        vm.expectRevert(BalancerLPMigrator.ZeroMinimum.selector);
        m.migrate(bpt, 1, 0, 1, 1, lpTo, d);
        vm.expectRevert(BalancerLPMigrator.ZeroMinimum.selector);
        m.migrate(bpt, 1, 1, 0, 1, lpTo, d);
        vm.expectRevert(BalancerLPMigrator.ZeroMinimum.selector);
        m.migrate(bpt, 1, 1, 1, 0, lpTo, d);
        vm.stopPrank();
    }

    function test_fork_reverts_zeroBptAndZeroTo() public {
        _assertForked();
        _approve(100e18);
        uint256 d = block.timestamp + 1 hours;
        vm.startPrank(user);
        vm.expectRevert(BalancerLPMigrator.ZeroAmount.selector);
        m.migrate(0, 1, 1, 1, 1, lpTo, d);
        vm.expectRevert(BalancerLPMigrator.ZeroAddress.selector);
        m.migrate(100e18, 1, 1, 1, 1, address(0), d);
        vm.stopPrank();
    }

    function test_fork_reverts_expiredDeadline() public {
        _assertForked();
        _approve(100e18);
        // via_ir may cache block.timestamp, so expire by construction rather than vm.warp.
        uint256 d = block.timestamp - 1;
        vm.prank(user);
        vm.expectRevert(BalancerLPMigrator.Expired.selector);
        m.migrate(100e18, 1, 1, 1, 1, lpTo, d);
    }

    function test_fork_reverts_balancerSlippage() public {
        _assertForked();
        uint256 bpt = 100e18;
        Preview memory p = _preview(bpt);
        _approve(bpt);
        uint256 d = block.timestamp + 1 hours;
        vm.startPrank(user);
        vm.expectRevert(); // Vault AmountOutBelowMin (sUSDS)
        m.migrate(bpt, p.sOut + 1e15, _floor(p.pOut), 1, 1, lpTo, d);
        vm.expectRevert(); // Vault AmountOutBelowMin (phUSD)
        m.migrate(bpt, _floor(p.sOut), p.pOut + 1e15, 1, 1, lpTo, d);
        vm.stopPrank();
    }

    function test_fork_reverts_balancerSlippage_recovery() public {
        _assertForked();
        vm.prank(V3_GOVERNANCE);
        IForkV3VaultAdmin121(VAULT).pausePool(POOL);
        uint256 bpt = 100e18;
        Preview memory p = _preview(bpt);
        _approve(bpt);
        vm.prank(user);
        vm.expectRevert();
        m.migrate(bpt, p.sOut + 1e15, _floor(p.pOut), 1, 1, lpTo, block.timestamp + 1 hours);
    }

    function test_fork_reverts_uniSlippage() public {
        _assertForked();
        uint256 bpt = 100e18;
        Preview memory p = _preview(bpt);
        _approve(bpt);
        uint256 d = block.timestamp + 1 hours;
        vm.startPrank(user);
        // The binding side is used in full; ask for more than the optimal amount of the other side.
        if (p.leftoverToken == PHUSD) {
            vm.expectRevert(bytes("UniswapV2Router: INSUFFICIENT_B_AMOUNT"));
            m.migrate(bpt, _floor(p.sOut), _floor(p.pOut), _floor(p.sUsed), p.pUsed + 1e15, lpTo, d);
        } else {
            vm.expectRevert(bytes("UniswapV2Router: INSUFFICIENT_A_AMOUNT"));
            m.migrate(bpt, _floor(p.sOut), _floor(p.pOut), p.sUsed + 1e15, _floor(p.pUsed), lpTo, d);
        }
        vm.stopPrank();
    }

    function test_fork_reverts_withoutBptAllowance() public {
        _assertForked();
        vm.prank(user);
        vm.expectRevert();
        m.migrate(100e18, 1, 1, 1, 1, lpTo, block.timestamp + 1 hours);
    }
}
