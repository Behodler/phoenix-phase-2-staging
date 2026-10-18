// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
import {UniPoolerCutoverEscrow} from "@yield-claim-nft/migration/UniPoolerCutoverEscrow.sol";
import {DeployMainnetUniPoolerCutover} from "../script/DeployMainnetUniPoolerCutover.s.sol";
import {VerifyUniPoolerCutover} from "../script/VerifyUniPoolerCutover.s.sol";
import {UniPoolerCutoverCore} from "../script/helpers/UniPoolerCutoverCore.sol";

interface IForkVaultV3 {
    function isPoolPaused(address pool) external view returns (bool);
    function isPoolInRecoveryMode(address pool) external view returns (bool);
    function pausePool(address pool) external;
    function enableRecoveryMode(address pool) external;
}

/// @dev Raw view of the vault's pool tokens and raw balances (the TokenInfo tuple is skipped by re-declaring it).
interface IForkVaultTokens {
    struct TokenInfo {
        uint8 tokenType;
        address rateProvider;
        bool paysYieldFees;
    }

    function getPoolTokenInfo(address pool)
        external
        view
        returns (address[] memory tokens, TokenInfo[] memory, uint256[] memory balancesRaw, uint256[] memory);
}

interface IForkOldPooler {
    function authVersion() external view returns (uint256);
    function poolerAuthVersion(address) external view returns (uint256);
    function incrementAuthVersion() external;
    function setAuthorizedPooler(address, bool) external;
    function paused() external view returns (bool);
}

interface IForkHook {
    function mintDebt() external view returns (uint256);
}

interface IForkMinter {
    function configs(uint256) external view returns (address, uint256, uint256, bool);
    function mint(uint256 index, address recipient) external returns (bool);
}

/// @dev The cutover script with its I/O seams pinned: mode, progress path and inputs are injected (never the
///      process-wide env, which races parallel suites, and never the real progress file). The OWNER session is a
///      prank in BOTH modes, so the broadcast-mode path (progress writing) runs on the fork. `_afterCutoverStep`
///      records the owner's four balances after every step for the test's own invariant check.
contract UniPoolerCutoverHarness is DeployMainnetUniPoolerCutover {
    bool internal immutable preview;
    string internal progressPath;
    ExitMode internal mode;
    uint256 internal minS;
    uint256 internal minP;

    uint256[] public stepIds;
    uint256[4][] internal ownerAfter; // BPT, sUSDS, phUSD, USDS
    uint256 public escrowBptAfterFunding;

    constructor(bool preview_, string memory progressPath_) {
        preview = preview_;
        progressPath = progressPath_;
    }

    function setInputs(ExitMode mode_, uint256 minS_, uint256 minP_) external {
        mode = mode_;
        minS = minS_;
        minP = minP_;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _exitModeFromEnv() internal view override returns (ExitMode) {
        return mode;
    }

    function _minAmountsFromEnv() internal view override returns (uint256, uint256) {
        return (minS, minP);
    }

    function _beginOwnerSession(bool) internal override {
        vm.startPrank(OWNER);
    }

    function _endOwnerSession(bool) internal override {
        vm.stopPrank();
    }

    function _afterCutoverStep(uint256 step, CutoverParams memory, CutoverLive memory l) internal override {
        stepIds.push(step);
        ownerAfter.push(
            [
                IERC20(BPT).balanceOf(OWNER),
                IERC20(SUSDS).balanceOf(OWNER),
                IERC20(PHUSD).balanceOf(OWNER),
                IERC20(USDS).balanceOf(OWNER)
            ]
        );
        if (step == CUTOVER_STEP_FUND_ESCROW) escrowBptAfterFunding = IERC20(BPT).balanceOf(l.escrow);
    }

    function stepCount() external view returns (uint256) {
        return stepIds.length;
    }

    function ownerAfterStep(uint256 i) external view returns (uint256[4] memory) {
        return ownerAfter[i];
    }

    function minterOf(address d) external view returns (address) {
        return _minterOf(d);
    }
}

contract VerifyUniPoolerCutoverHarness is VerifyUniPoolerCutover {
    string internal progressPath;

    constructor(string memory progressPath_) {
        progressPath = progressPath_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }
}

/**
 * @title UniPoolerCutoverMainnetForkTest  (story 103)
 * @notice The WHOLE mainnet cutover script against a mainnet fork. Skips cleanly when RPC_MAINNET is unset.
 *
 *         Case 1 (PROPORTIONAL): full cutover through `UniPoolerCutoverEscrow`; floors computed over the escrow's BPT
 *         after `withdrawBPT(escrow, bal)` (the old pooler's BPT only, read live); the owner's live BPT is recorded
 *         (expected 0) and never moved; the owner's BPT/sUSDS/phUSD/USDS never rise at any step; progress written;
 *         verify passes; a test mint at index 4 dispatches, wraps and accrues debt.
 *         Case 2 (RECOVERY): the pool is paused and put in Recovery Mode through Balancer governance (as
 *         yield-claim-nft:052's fork test does); the PROPORTIONAL run reverts `PoolPaused(BPT)`, the RECOVERY run
 *         succeeds and verifies.
 *
 *         FORK BLOCK. Pinned AFTER story 099's revoke broadcast (2026-10-01): at 26,215,000 all four poolers are
 *         already unauthorized (authVersion 2, each poolerAuthVersion 1), the old pooler holds 20,401.809 BPT, the
 *         owner holds 0 BPT, the pair does not exist and the pool is live. `_revokeIfNeeded` still performs 099's
 *         revoke (OWNER `incrementAuthVersion`) whenever any pooler is authorized, so a re-pin to an earlier block
 *         keeps working.
 */
contract UniPoolerCutoverMainnetForkTest is Test {
    uint256 constant FORK_BLOCK = 26_215_000;
    string constant TMP_PREFIX = "server/deployments/progress.unipooler-cutover.1.forktest-";
    /// @dev The quote helper's default tolerance (10 bps), inside the script's 50 bps.
    uint256 constant QUOTE_TOL_BPS = 10;

    /// @dev Sole holder of the Vault authorizer's `pausePool` / `enableRecoveryMode` action ids (yield-claim-nft:052
    ///      fork test, Autonomous Decision 3); the pool itself has no pause manager.
    address constant V3_GOVERNANCE = 0xA29F61256e948F3FB707b4b3B138C5cCb9EF9888;

    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant OLD_POOLER = 0x7f6874332c4629429d70D15f685A8230323F11F1;
    address constant HOOK = 0x4A26ad83306a2F17155799fDD9449f77eb3F8bD7;
    address constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address constant BPT = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant MULTI_POOLER = 0xd1E5774159381915f5579dFd68507E2614f67b51;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        _revokeIfNeeded();
        return true;
    }

    function _tmp(string memory name) internal returns (string memory path) {
        path = string.concat(TMP_PREFIX, name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    /// @dev Story 099's holding pattern, performed only if any of the four poolers is still authorized.
    function _revokeIfNeeded() internal {
        IForkOldPooler old = IForkOldPooler(OLD_POOLER);
        address[4] memory ps = [
            OWNER, MULTI_POOLER, 0x186c77B80Bbfd21b01C7D7FA44bA27031322a77F, 0x630966B668b321Cc6441754f96519a55F72Cd476
        ];
        for (uint256 i; i < 4; i++) {
            if (old.poolerAuthVersion(ps[i]) == old.authVersion()) {
                vm.prank(OWNER);
                old.incrementAuthVersion();
                return;
            }
        }
    }

    /// @dev The quote helper's computation, in-test: the live proportional share of the old pooler's whole BPT
    ///      balance (== the escrow's after `withdrawBPT(escrow, bal)`), minus QUOTE_TOL_BPS, keyed by token.
    function _floors() internal view returns (uint256 minS, uint256 minP) {
        uint256 bal = IERC20(BPT).balanceOf(OLD_POOLER);
        (address[] memory tokens,, uint256[] memory raw,) = IForkVaultTokens(VAULT).getPoolTokenInfo(BPT);
        uint256 supply = IERC20(BPT).totalSupply();
        for (uint256 i; i < 2; i++) {
            uint256 floor_ = ((raw[i] * bal) / supply) * (10_000 - QUOTE_TOL_BPS) / 10_000;
            if (tokens[i] == SUSDS) minS = floor_;
            else minP = floor_;
        }
        assertGt(minS, 0, "sUSDS floor");
        assertGt(minP, 0, "phUSD floor");
    }

    function _ownerBalances() internal view returns (uint256[4] memory b) {
        b = [
            IERC20(BPT).balanceOf(OWNER),
            IERC20(SUSDS).balanceOf(OWNER),
            IERC20(PHUSD).balanceOf(OWNER),
            IERC20(USDS).balanceOf(OWNER)
        ];
    }

    function _assertOwnerNeverCredited(UniPoolerCutoverHarness h, uint256[4] memory start) internal view {
        assertEq(h.stepCount(), 13, "every cutover step observed");
        string[4] memory names = ["BPT", "sUSDS", "phUSD", "USDS"];
        for (uint256 i; i < h.stepCount(); i++) {
            uint256[4] memory b = h.ownerAfterStep(i);
            for (uint256 k; k < 4; k++) {
                assertLe(b[k], start[k], string.concat("owner ", names[k], " rose at a cutover step"));
            }
        }
    }

    function _runCutover(UniPoolerCutoverHarness h, UniPoolerCutoverCore.ExitMode mode)
        internal
        returns (UniPoolerCutoverCore.CutoverResult memory r)
    {
        (uint256 minS, uint256 minP) = _floors();
        h.setInputs(mode, minS, minP);
        h.run();
        assertTrue(h.cutoverRanThisRun(), "cutover ran");
        r = h.result();
    }

    /// @dev The end state every successful run must leave (independent of the script's own checks).
    function _assertCutover(UniPoolerCutoverCore.CutoverResult memory r, uint256 oldBpt, uint256 oldSUSDS)
        internal
        view
    {
        (address d,,, bool disabled) = IForkMinter(NFT_MINTER).configs(4);
        assertEq(d, r.newPooler, "configs(4).dispatcher == UniPooler");
        assertFalse(disabled);
        UniPoolerV2 np = UniPoolerV2(r.newPooler);
        assertEq(np.pair(), r.pair, "pair");
        assertEq(address(np.hook()), HOOK, "UniPooler hook");
        assertEq(r.bptWithdrawn, oldBpt, "old pooler's whole BPT -> escrow");
        assertEq(r.bptExited, oldBpt, "escrow exited exactly the old pooler's BPT");
        assertEq(IERC20(r.pair).balanceOf(r.newPooler), r.liquidity, "UniPooler holds the LP");
        assertEq(r.sUSDSRescued, oldSUSDS, "interim sUSDS rescued");
        assertTrue(IForkOldPooler(OLD_POOLER).paused(), "old paused");
        assertEq(IERC20(BPT).balanceOf(OLD_POOLER), 0, "old BPT 0");
        assertEq(IERC20(SUSDS).balanceOf(OLD_POOLER), 0, "old sUSDS 0");
        assertEq(IERC20(USDS).balanceOf(OLD_POOLER), 0, "old USDS 0");
        address e = r.escrow;
        assertEq(UniPoolerCutoverEscrow(e).operator(), OWNER, "escrow operator");
        assertEq(
            IERC20(BPT).balanceOf(e) + IERC20(SUSDS).balanceOf(e) + IERC20(PHUSD).balanceOf(e)
                + IERC20(USDS).balanceOf(e),
            0,
            "escrow empty"
        );
        console2.log("UniPoolerV2:", r.newPooler);
        console2.log("pair:", r.pair);
        console2.log("escrow:", r.escrow);
        console2.log("BPT exited:", r.bptExited);
        console2.log("seeded sUSDS:", r.sUSDSSeeded);
        console2.log("seeded phUSD:", r.phUSDSeeded);
        console2.log("LP:", r.liquidity);
        console2.log("USDS parked -> wrapped:", r.usdsRescued, r.usdsWrappedShares);
    }

    /// @dev A post-cutover mint at index 4 dispatches through UniPoolerV2, wraps and accrues mint debt.
    function _assertTestMint(address newPooler) internal {
        address user = makeAddr("forkMinter");
        (, uint256 price,,) = IForkMinter(NFT_MINTER).configs(4);
        address prime = UniPoolerV2(newPooler).primeToken();
        assertEq(prime, USDS, "index-4 prime token is USDS");
        deal(USDS, user, price);
        uint256 sBefore = IERC20(SUSDS).balanceOf(newPooler);
        uint256 debtBefore = IForkHook(HOOK).mintDebt();
        vm.startPrank(user);
        IERC20(USDS).approve(NFT_MINTER, price);
        IForkMinter(NFT_MINTER).mint(4, user);
        vm.stopPrank();
        assertGt(IERC20(SUSDS).balanceOf(newPooler), sBefore, "mint wrapped USDS into sUSDS on UniPoolerV2");
        assertGt(IForkHook(HOOK).mintDebt(), debtBefore, "mint accrued debt on the hook");
        assertEq(IERC20(USDS).balanceOf(newPooler), 0, "no raw USDS parked on UniPoolerV2");
    }

    // ------------------------------------------------------------------------------------------------- case 1

    function test_fork_case1_proportional_fullCutover_progress_verify_testMint() public {
        if (!_fork()) return;
        uint256 ownerBpt = IERC20(BPT).balanceOf(OWNER);
        console2.log("owner BPT at the fork block (expected 0, F-02-052):", ownerBpt);
        assertEq(ownerBpt, 0, "owner holds no BPT at the fork block");
        uint256 oldBpt = IERC20(BPT).balanceOf(OLD_POOLER);
        uint256 oldSUSDS = IERC20(SUSDS).balanceOf(OLD_POOLER);
        console2.log("old pooler BPT (the escrow's after withdrawBPT):", oldBpt);
        assertGt(oldBpt, 20_000e18, "old pooler holds ~20.4k BPT");
        assertEq(IForkOldPooler(OLD_POOLER).paused(), false);
        uint256[4] memory start = _ownerBalances();

        string memory path = _tmp("case1");
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(false, path);
        // The minter slot read the script relies on, pinned against the live wiring.
        assertEq(h.minterOf(OLD_POOLER), NFT_MINTER, "dispatcher _minter slot");

        UniPoolerCutoverCore.CutoverResult memory r = _runCutover(h, UniPoolerCutoverCore.ExitMode.PROPORTIONAL);
        _assertCutover(r, oldBpt, oldSUSDS);
        assertEq(h.escrowBptAfterFunding(), oldBpt, "floors were sized on the escrow's BPT == the old pooler's");
        assertEq(r.ownerBptAtStart, 0, "owner BPT recorded");
        assertEq(IERC20(BPT).balanceOf(OWNER), ownerBpt, "no owner BPT moved");
        _assertOwnerNeverCredited(h, start);
        assertEq(h.minterOf(OLD_POOLER), OWNER, "old pooler minter -> OWNER");

        // The progress file the patcher reads.
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1);
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "completed");
        assertEq(vm.parseJsonAddress(json, ".contracts.UniPooler.address"), r.newPooler);
        assertEq(vm.parseJsonAddress(json, ".contracts.PhusdSusdsPair.address"), r.pair);
        assertEq(vm.parseJsonAddress(json, ".contracts.UniPoolerCutoverEscrow.address"), r.escrow);
        assertEq(vm.parseJsonString(json, ".cutover.exitMode"), "PROPORTIONAL");

        new VerifyUniPoolerCutoverHarness(path).run();

        // A re-run on the completed, live progress file sends nothing.
        UniPoolerCutoverHarness again = new UniPoolerCutoverHarness(false, path);
        again.run();
        assertFalse(again.cutoverRanThisRun(), "re-run is a no-op");

        _assertTestMint(r.newPooler);
        vm.removeFile(path);
    }

    function test_fork_case1_preview_runsE2E_writesNoProgress() public {
        if (!_fork()) return;
        string memory path = _tmp("preview");
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(true, path);
        uint256 oldBpt = IERC20(BPT).balanceOf(OLD_POOLER);
        uint256 oldSUSDS = IERC20(SUSDS).balanceOf(OLD_POOLER);
        UniPoolerCutoverCore.CutoverResult memory r = _runCutover(h, UniPoolerCutoverCore.ExitMode.PROPORTIONAL);
        _assertCutover(r, oldBpt, oldSUSDS);
        assertFalse(vm.exists(path), "preview must not write the progress file");
        // The preview-only E2E mint ran: UniPoolerV2 accrued sUSDS beyond the rescue (then pool() was reverted).
        assertGt(IERC20(SUSDS).balanceOf(r.newPooler), r.sUSDSRescued + r.usdsWrappedShares, "preview test mint");
    }

    /// @dev Owner BPT is out of scope: a BPT donation to the owner neither moves nor reverts (F-02-052).
    function test_fork_ownerBptDonation_isNotMoved_andReported() public {
        if (!_fork()) return;
        vm.prank(OLD_POOLER);
        IERC20(BPT).transfer(OWNER, 1e18);
        uint256 oldBpt = IERC20(BPT).balanceOf(OLD_POOLER);
        uint256 oldSUSDS = IERC20(SUSDS).balanceOf(OLD_POOLER);
        uint256[4] memory start = _ownerBalances();
        string memory path = _tmp("donation");
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(false, path);
        UniPoolerCutoverCore.CutoverResult memory r = _runCutover(h, UniPoolerCutoverCore.ExitMode.PROPORTIONAL);
        _assertCutover(r, oldBpt, oldSUSDS);
        assertEq(r.ownerBptAtStart, 1e18);
        assertEq(IERC20(BPT).balanceOf(OWNER), 1e18, "owner BPT untouched");
        _assertOwnerNeverCredited(h, start);
        new VerifyUniPoolerCutoverHarness(path).run(); // reports it, does not fail
        vm.removeFile(path);
    }

    // ------------------------------------------------------------------------------------------------- case 2

    /// @notice yield-claim-nft:052: on a paused pool `removeLiquidityProportional` reverts and
    ///         `removeLiquidityRecovery` succeeds, through the real script.
    function test_fork_case2_pausedPool_proportionalReverts_recoverySucceeds() public {
        if (!_fork()) return;
        vm.prank(V3_GOVERNANCE);
        IForkVaultV3(VAULT).pausePool(BPT);
        assertTrue(IForkVaultV3(VAULT).isPoolPaused(BPT), "pool paused");
        IForkVaultV3(VAULT).enableRecoveryMode(BPT); // permissionless once paused
        assertTrue(IForkVaultV3(VAULT).isPoolInRecoveryMode(BPT), "recovery mode");

        string memory path = _tmp("case2");
        UniPoolerCutoverHarness bad = new UniPoolerCutoverHarness(false, path);
        (uint256 minS, uint256 minP) = _floors();
        bad.setInputs(UniPoolerCutoverCore.ExitMode.PROPORTIONAL, minS, minP);
        vm.expectRevert(abi.encodeWithSignature("PoolPaused(address)", BPT));
        bad.run();
        assertFalse(vm.exists(path), "a reverted run writes nothing");

        uint256 oldBpt = IERC20(BPT).balanceOf(OLD_POOLER);
        uint256 oldSUSDS = IERC20(SUSDS).balanceOf(OLD_POOLER);
        uint256[4] memory start = _ownerBalances();
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(false, path);
        UniPoolerCutoverCore.CutoverResult memory r = _runCutover(h, UniPoolerCutoverCore.ExitMode.RECOVERY);
        _assertCutover(r, oldBpt, oldSUSDS);
        _assertOwnerNeverCredited(h, start);
        assertEq(vm.parseJsonString(vm.readFile(path), ".cutover.exitMode"), "RECOVERY");
        new VerifyUniPoolerCutoverHarness(path).run();
        _assertTestMint(r.newPooler);
        vm.removeFile(path);
    }

    /// @dev The live pool is NOT paused at the fork block: RECOVERY reverts (it is never chosen by the clock).
    function test_fork_recoveryOnLivePool_reverts() public {
        if (!_fork()) return;
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(true, _tmp("recoveryLive"));
        (uint256 minS, uint256 minP) = _floors();
        h.setInputs(UniPoolerCutoverCore.ExitMode.RECOVERY, minS, minP);
        vm.expectRevert();
        h.run();
    }

    // ------------------------------------------------------------------------------------------ preconditions

    function test_fork_revert_poolerStillAuthorized() public {
        if (!_fork()) return;
        vm.prank(OWNER);
        IForkOldPooler(OLD_POOLER).setAuthorizedPooler(MULTI_POOLER, true);
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(true, _tmp("auth"));
        (uint256 minS, uint256 minP) = _floors();
        h.setInputs(UniPoolerCutoverCore.ExitMode.PROPORTIONAL, minS, minP);
        vm.expectRevert(bytes("UniPoolerCutoverCore: pooler still authorized"));
        h.run();
    }

    function test_fork_revert_zeroFloors() public {
        if (!_fork()) return;
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(true, _tmp("zero"));
        (uint256 minS,) = _floors();
        h.setInputs(UniPoolerCutoverCore.ExitMode.PROPORTIONAL, minS, 0);
        vm.expectRevert(
            bytes(
                "MIN_SUSDS_OUT_WEI and MIN_PHUSD_OUT_WEI must both be set and non-zero: eval \"$(node scripts/quote-balancer-exit-min-amounts.js 10)\""
            )
        );
        h.run();
    }

    function test_fork_revert_floorAboveLiveShare() public {
        if (!_fork()) return;
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(true, _tmp("above"));
        (uint256 minS, uint256 minP) = _floors();
        h.setInputs(UniPoolerCutoverCore.ExitMode.PROPORTIONAL, minS * 2, minP);
        vm.expectRevert(bytes("UniPoolerCutoverCore: minAmountOut above share"));
        h.run();
    }

    function test_fork_revert_poisonedProgressFile() public {
        if (!_fork()) return;
        string memory path = _tmp("poisoned");
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"completed","contracts":{"UniPooler":{"address":"',
                vm.toString(makeAddr("neverLanded")),
                '","deployed":true}}}'
            )
        );
        UniPoolerCutoverHarness h = new UniPoolerCutoverHarness(false, path);
        (uint256 minS, uint256 minP) = _floors();
        h.setInputs(UniPoolerCutoverCore.ExitMode.PROPORTIONAL, minS, minP);
        vm.expectRevert(
            bytes(
                "Progress file server/deployments/progress.unipooler-cutover.1.json exists but the cutover is not live on chain - it is POISONED (forge writes it in its local pass). Resume from broadcast receipts, not the progress file, and rename it to progress.unipooler-cutover.1.POISONED.<ts>.bak"
            )
        );
        h.run();
        vm.removeFile(path);
    }
}
