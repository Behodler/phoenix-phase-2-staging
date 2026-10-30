// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";
import {
    CutoverAntimatterPoolMainnet,
    AntimatterPoolMainnetBase,
    IAmCutoverPooler,
    IAmCutoverAntimatter,
    IAmCutoverFactory
} from "../script/CutoverAntimatterPoolMainnet.s.sol";
import {VerifyAntimatterPoolCutover} from "../script/VerifyAntimatterPoolCutover.s.sol";

/// @dev Pins the mode and the progress path (never the process-wide PREVIEW_MODE env, never the real progress file).
contract CutoverAntimatterPoolHarness is CutoverAntimatterPoolMainnet {
    bool internal immutable preview;
    string internal progressPath;

    constructor(bool preview_, string memory progressPath_) {
        preview = preview_;
        progressPath = progressPath_;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }
}

/// @dev Before the broadcast the live address book keeps zero placeholders: only the scratch progress file counts.
contract VerifyAntimatterPoolHarness is VerifyAntimatterPoolCutover {
    string internal progressPath;

    constructor(string memory progressPath_) {
        progressPath = progressPath_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookKey(string memory) internal pure override returns (address) {
        return address(0);
    }
}

/**
 * @title CutoverAntimatterPoolMainnetForkTest  (story 122, Script B)
 * @notice The cutover script's own logic against a mainnet fork (skipped without RPC_MAINNET): happy path at 10%,
 *         resume after the rescue, resume after the seed (revoke still runs), pair-already-exists abort, end state
 *         and the verifier.
 */
contract CutoverAntimatterPoolMainnetForkTest is Test {
    /// @dev Recent block (2026-10-30): the AM/sUSDS pair does not exist, UniPoolerV2 holds the protocol LP.
    uint256 constant FORK_BLOCK = 26_303_500;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    string constant TMP_PREFIX = "server/deployments/progress.antimatter-pool.1.forktest-";

    AntimatterPoolMainnetBase.Config c;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        c = new CutoverAntimatterPoolMainnet().expectedConfig();
        assertEq(
            IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS), address(0), "AM/sUSDS pair absent at fork"
        );
        return true;
    }

    function _tmp(string memory name) internal returns (string memory path) {
        path = string.concat(TMP_PREFIX, name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    function _assertEndState(CutoverAntimatterPoolMainnet s, uint256 poolerLpBefore, uint256 lp) internal view {
        AntimatterPoolSeeder seeder = s.seeder();
        address pair = s.amSusdsPair();
        assertEq(pair, IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS), "canonical pair");
        assertFalse(IAmCutoverAntimatter(c.antimatter).isApprovedMinter(address(seeder)), "minter revoked");
        assertGt(IERC20(pair).balanceOf(OWNER), 0, "OWNER holds AM/sUSDS LP");
        assertEq(IERC20(c.phusdSusdsPair).balanceOf(c.uniPooler), poolerLpBefore - lp, "pooler LP minus slice");
        assertEq(IERC20(c.phUSD).balanceOf(address(seeder)), 0, "seeder phUSD");
        assertEq(IERC20(c.antimatter).balanceOf(address(seeder)), 0, "seeder AM");
        assertEq(IERC20(c.sUSDS).balanceOf(address(seeder)), 0, "seeder sUSDS");
        assertEq(IERC20(c.phusdSusdsPair).balanceOf(address(seeder)), 0, "seeder old LP");
        assertEq(IERC20(pair).balanceOf(address(seeder)), 0, "seeder new LP");
    }

    function test_fork_preview_tenPercent_endState() public {
        if (!_fork()) return;
        uint256 poolerLp = IERC20(c.phusdSusdsPair).balanceOf(c.uniPooler);
        uint256 phSupply = IERC20(c.phUSD).totalSupply();
        uint256 amSupply = IERC20(c.antimatter).totalSupply();
        string memory path = _tmp("preview");

        CutoverAntimatterPoolHarness s = new CutoverAntimatterPoolHarness(true, path);
        s.run();

        (,, uint256 lp,,,, uint256 amMinted, uint256 liquidity,,,,,,) = s.progress();
        assertEq(lp, poolerLp * 1_000 / 10_000, "10% slice");
        assertGt(amMinted, 0, "AM minted");
        assertEq(phSupply - IERC20(c.phUSD).totalSupply(), amMinted, "phUSD fell by AM minted");
        assertEq(IERC20(c.antimatter).totalSupply() - amSupply, amMinted, "AM rose by AM minted");
        assertEq(IERC20(c.antimatter).balanceOf(s.amSusdsPair()), amMinted, "all AM in the pair");
        assertEq(IERC20(s.amSusdsPair()).balanceOf(OWNER), liquidity, "OWNER LP == liquidity");
        assertEq(s.txCount(), 6, "deploy, rescue, approve, grant, seed, revoke");
        _assertEndState(s, poolerLp, lp);
        assertFalse(vm.exists(path), "preview must not write the progress file");
    }

    function test_fork_broadcastMode_progress_rerunIsNoop_verifyPasses() public {
        if (!_fork()) return;
        uint256 poolerLp = IERC20(c.phusdSusdsPair).balanceOf(c.uniPooler);
        string memory path = _tmp("broadcast");
        CutoverAntimatterPoolHarness s = new CutoverAntimatterPoolHarness(false, path);
        s.run();

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "completed", "status");
        assertTrue(vm.parseJsonBool(json, ".cutover.seeded"), "seeded");
        assertEq(vm.parseJsonAddress(json, ".contracts.AntimatterPoolSeeder.address"), address(s.seeder()), "seeder");
        assertEq(vm.parseJsonAddress(json, ".contracts.AntimatterSusdsPair.address"), s.amSusdsPair(), "pair");
        uint256 lp = vm.parseJsonUint(json, ".cutover.lpAmount");
        _assertEndState(s, poolerLp, lp);

        CutoverAntimatterPoolHarness again = new CutoverAntimatterPoolHarness(false, path);
        again.run();
        assertEq(again.txCount(), 0, "re-run sends nothing");
        assertFalse(again.deployedThisRun(), "re-run must not deploy");
        assertFalse(again.seededThisRun(), "re-run must not seed");

        new VerifyAntimatterPoolHarness(path).run();
        vm.removeFile(path);
    }

    /// @dev The run died after step 4: the LP sits on OWNER. The resume continues at step 5.
    function test_fork_resume_afterRescue() public {
        if (!_fork()) return;
        uint256 poolerLp = IERC20(c.phusdSusdsPair).balanceOf(c.uniPooler);
        uint256 ownerLp = IERC20(c.phusdSusdsPair).balanceOf(OWNER);
        string memory path = _tmp("resume-rescue");

        vm.startPrank(OWNER);
        AntimatterPoolSeeder seeder =
            new AntimatterPoolSeeder(OWNER, c.phUSD, c.sUSDS, c.antimatter, c.router, c.phusdSusdsPair, c.uniPooler);
        uint256 lp = seeder.lpForBps(1_000);
        IAmCutoverPooler(c.uniPooler).rescueERC20(c.phusdSusdsPair, OWNER, lp);
        vm.stopPrank();
        _writePartialProgress(path, address(seeder), lp, poolerLp, ownerLp);

        CutoverAntimatterPoolHarness s = new CutoverAntimatterPoolHarness(false, path);
        s.run();
        assertFalse(s.deployedThisRun(), "seeder adopted");
        assertFalse(s.rescuedThisRun(), "rescue not repeated");
        assertTrue(s.seededThisRun(), "seeded");
        assertEq(s.txCount(), 4, "approve, grant, seed, revoke");
        _assertEndState(s, poolerLp, lp);
        new VerifyAntimatterPoolHarness(path).run();
        vm.removeFile(path);
    }

    /// @dev The run died after the seed, before the revoke: the resume ONLY revokes.
    function test_fork_resume_afterSeed_revokeAlwaysRuns() public {
        if (!_fork()) return;
        uint256 poolerLp = IERC20(c.phusdSusdsPair).balanceOf(c.uniPooler);
        uint256 ownerLp = IERC20(c.phusdSusdsPair).balanceOf(OWNER);
        string memory path = _tmp("resume-seed");

        vm.startPrank(OWNER);
        AntimatterPoolSeeder seeder =
            new AntimatterPoolSeeder(OWNER, c.phUSD, c.sUSDS, c.antimatter, c.router, c.phusdSusdsPair, c.uniPooler);
        uint256 lp = seeder.lpForBps(1_000);
        IAmCutoverPooler(c.uniPooler).rescueERC20(c.phusdSusdsPair, OWNER, lp);
        IERC20(c.phusdSusdsPair).approve(address(seeder), lp);
        IAmCutoverAntimatter(c.antimatter).setApprovedMinter(address(seeder), true);
        seeder.seed(lp, 1, 1, 1, OWNER, block.timestamp + 1 hours);
        vm.stopPrank();
        assertTrue(IAmCutoverAntimatter(c.antimatter).isApprovedMinter(address(seeder)), "still a minter");
        _writePartialProgress(path, address(seeder), lp, poolerLp, ownerLp);

        CutoverAntimatterPoolHarness s = new CutoverAntimatterPoolHarness(false, path);
        s.run();
        assertFalse(s.seededThisRun(), "no second seed");
        assertEq(s.txCount(), 1, "revoke only");
        _assertEndState(s, poolerLp, lp);
        vm.removeFile(path);
    }

    /// @dev Griefing risk R1: a pre-existing AM/sUSDS pair (here created by a stranger) aborts the cutover.
    function test_fork_pairAlreadyExists_aborts() public {
        if (!_fork()) return;
        vm.prank(makeAddr("griefer"));
        IAmCutoverFactoryCreate(c.factory).createPair(c.antimatter, c.sUSDS);

        CutoverAntimatterPoolHarness s = new CutoverAntimatterPoolHarness(true, _tmp("griefed"));
        vm.expectRevert(
            bytes(
                "Step 0: the AM/sUSDS pair ALREADY EXISTS and this cutover did not create it - ABORT (griefing risk R1, story 113). Do not seed into a pair someone else created; investigate first."
            )
        );
        s.run();
    }

    function test_fork_verify_failsBeforeBroadcast() public {
        if (!_fork()) return;
        VerifyAntimatterPoolHarness v = new VerifyAntimatterPoolHarness(_tmp("absent"));
        vm.expectRevert(bytes("verify: no AntimatterPoolSeeder address - broadcast first"));
        v.run();
    }

    function _writePartialProgress(string memory path, address seeder, uint256 lp, uint256 poolerLp, uint256 ownerLp)
        internal
    {
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"in_progress","contracts":{"AntimatterPoolSeeder":{"address":"',
                vm.toString(seeder),
                '","deployed":true}},"cutover":{"bps":1000,"lpAmount":"',
                vm.toString(lp),
                '","poolerLpBefore":"',
                vm.toString(poolerLp),
                '","ownerLpBefore":"',
                vm.toString(ownerLp),
                '","seeded":false}}'
            )
        );
    }
}

interface IAmCutoverFactoryCreate {
    function createPair(address, address) external returns (address);
}

interface IM01Am {
    function setApprovedMinter(address, bool) external;
    function isApprovedMinter(address) external view returns (bool);
}

interface IM01Pair {
    function mint(address) external returns (uint256);
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
}

interface IM01Router {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
}

interface IM01Staker {
    function setClaimEnabled(bool) external;
    function claim(address) external;
}

/// @dev Exposes the script's own floor computation, so the regression seeds with exactly what Script B would pass.
contract CutoverAntimatterPoolFloorsHarness is CutoverAntimatterPoolHarness {
    constructor(bool preview_, string memory progressPath_) CutoverAntimatterPoolHarness(preview_, progressPath_) {}

    function floors(Config memory cfg, uint256 lp) external view returns (uint256, uint256, uint256) {
        return _floors(cfg, lp);
    }
}

/**
 * @title CutoverAntimatterPoolM01RegressionForkTest  (story 123, audit run-44 M-01)
 * @notice Ported from the audit PoC `AntimatterPoolPoC44.fork.t.sol` (`test_PoC_M01_frontRunStealsSeededAM` and
 *         `test_PoC_M01_control_noScriptA_cannotReproduce`). Under `--broadcast --skip-simulation --slow`, tx1-tx4
 *         (seeder CREATE, LP rescue, approve, setApprovedMinter) are mined publicly before tx5 `seed()`. Once Script
 *         A has opened claims, an AM holder can create the AM/sUSDS pair AM-cheap in that window. Before story 123
 *         tx5 then poured all ~2,457.70 protocol AM in against ~2.46e-9 sUSDS. With the on-chain `minSUSDSPaired`
 *         floor Script B now passes, tx5 reverts `InsufficientSUSDSPaired` instead.
 *         Fork block 26_303_964: AM `pendingReward` exists for the claim-then-attack setup. Skipped without
 *         RPC_MAINNET.
 */
contract CutoverAntimatterPoolM01RegressionForkTest is Test {
    uint256 constant FORK_BLOCK = 26_303_964;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant SSV2 = 0xA6d3fc83C91B8319D219cEB12B46e3dfF064B58F;
    address constant STAKER = 0xD57e5f043cB3C05be4E8138886cCEF2448a07C66;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant PREDICTED_PAIR = 0xb6da5138C761Eb7a3Ef7030212bfc9e2EAB8a4DA;
    string constant TMP = "server/deployments/progress.antimatter-pool.1.forktest-m01-";

    // The audit's dry-run figures at the fork block.
    uint256 constant DRY_LP = 2_258_927_005_521_607_781_703;
    uint256 constant DRY_MIN_PHUSD = 2_455_249_284_981_865_527_557;
    uint256 constant DRY_MIN_SUSDS = 2_075_083_110_422_466_836_443;
    uint256 constant AM_MINTED = 2_457_703_431_673_592_711_190;
    uint256 constant SUSDS_OUT = 2_077_157_261_663_097_322_856;

    AntimatterPoolMainnetBase.Config c;
    address attacker;
    AntimatterPoolSeeder seeder;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        c = new CutoverAntimatterPoolMainnet().expectedConfig();
        attacker = makeAddr("attacker");
    }

    function _tmp(string memory name) internal returns (string memory path) {
        path = string.concat(TMP, name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    /// Script A's last tx opens claims; a real SSV2 staker claims AM and the attacker acquires `amt` of it.
    function _scriptA_attackerAcquiresAM(uint256 amt) internal {
        vm.prank(OWNER);
        IM01Staker(SSV2).setClaimEnabled(true);
        vm.prank(STAKER);
        IM01Staker(SSV2).claim(DOLA);
        vm.prank(STAKER);
        IERC20(c.antimatter).transfer(attacker, amt);
        assertEq(IERC20(c.antimatter).balanceOf(attacker), amt, "attacker holds real, claimed AM");
    }

    /// forge's LOCAL pass of `:broadcast` (pair absent, every step simulated), rolled back. Returns the predicted
    /// seeder and the floors the script itself computes right before the seed.
    function _localPass(string memory path)
        internal
        returns (address seederAddr, uint256 minP, uint256 minS, uint256 minSPaired)
    {
        uint256 snap = vm.snapshotState();
        CutoverAntimatterPoolFloorsHarness h = new CutoverAntimatterPoolFloorsHarness(false, path);
        // The rescue moves LP to OWNER without burning it, so the pair's balances (and the floors) are the same
        // before and after it.
        (minP, minS, minSPaired) = h.floors(c, DRY_LP);
        h.run();
        seederAddr = address(h.seeder());
        vm.revertToState(snap);
        if (vm.exists(path)) vm.removeFile(path);
    }

    /// On-chain tx1..tx4 exactly as the broadcast sends them.
    function _tx1to4() internal {
        vm.startPrank(OWNER);
        seeder =
            new AntimatterPoolSeeder(OWNER, c.phUSD, c.sUSDS, c.antimatter, c.router, c.phusdSusdsPair, c.uniPooler);
        assertEq(seeder.lpForBps(1_000), DRY_LP, "lp slice == dry-run arg");
        IAmCutoverPooler(c.uniPooler).rescueERC20(c.phusdSusdsPair, OWNER, DRY_LP);
        IERC20(c.phusdSusdsPair).approve(address(seeder), DRY_LP);
        IM01Am(c.antimatter).setApprovedMinter(address(seeder), true);
        vm.stopPrank();
    }

    function _reserves(address pair) internal view returns (uint256 rAm, uint256 rS) {
        (uint112 r0, uint112 r1,) = IM01Pair(pair).getReserves();
        (rAm, rS) = IM01Pair(pair).token0() == c.antimatter ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// M-01 regression: the front-run that used to steal the seeded AM now makes tx5 revert at the floor.
    function test_PoC_M01_frontRunStealsSeededAM() public {
        _scriptA_attackerAcquiresAM(1e18);

        (address predicted, uint256 minP, uint256 minS, uint256 minSPaired) = _localPass(_tmp("attack"));
        assertEq(minP, DRY_MIN_PHUSD, "script minPhUSD == audit dry run");
        assertEq(minS, DRY_MIN_SUSDS, "script minSUSDS == audit dry run");
        assertEq(minSPaired, DRY_MIN_SUSDS, "script minSUSDSPaired == the audit tripwire (2,075.083 sUSDS)");
        _tx1to4();
        assertEq(address(seeder), predicted, "tx1 seeder == local-pass prediction (public, predictable)");

        // Attacker, between tx4 and tx5: create the pair at 1 AM : 1e-12 sUSDS.
        deal(c.sUSDS, attacker, 1_000e18);
        vm.startPrank(attacker);
        address pair = IAmCutoverFactoryCreate(c.factory).createPair(c.antimatter, c.sUSDS);
        IERC20(c.antimatter).transfer(pair, 1e18);
        IERC20(c.sUSDS).transfer(pair, 1e6);
        IM01Pair(pair).mint(attacker);
        vm.stopPrank();
        assertEq(pair, PREDICTED_PAIR, "attacker created the canonical AM/sUSDS pair");

        uint256 amSupply = IERC20(c.antimatter).totalSupply();
        uint256 paired = AM_MINTED * 1e6 / 1e18; // Router02 quote at the attacker's price: 2.46e-9 sUSDS
        assertEq(paired, 2_457_703_431);

        // tx5 with the script's floors: reverts loudly instead of leaking the AM.
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(AntimatterPoolSeeder.InsufficientSUSDSPaired.selector, paired, minSPaired)
        );
        seeder.seed(DRY_LP, minP, minS, minSPaired, OWNER, block.timestamp + 1 hours);

        // Nothing leaked: no AM minted, the attacker's pair is untouched, the slice still sits on OWNER.
        assertEq(IERC20(c.antimatter).totalSupply(), amSupply, "no AM minted");
        (uint256 rAm, uint256 rS) = _reserves(pair);
        assertEq(rAm, 1e18, "pair holds only the attacker's AM");
        assertEq(rS, 1e6, "pair holds only the attacker's sUSDS");
        assertEq(IERC20(c.phusdSusdsPair).balanceOf(OWNER), DRY_LP, "LP slice still on OWNER");
        assertEq(IERC20(c.antimatter).balanceOf(address(seeder)), 0, "seeder holds no AM");
    }

    /// Control: Script A NOT run - AM supply is 0, nobody can pre-price the pair, and tx5 with the script's floors
    /// pairs the AM with the full sUSDS.
    function test_PoC_M01_control_noScriptA_cannotReproduce() public {
        assertEq(IERC20(c.antimatter).totalSupply(), 0, "pre-A: AM supply is 0");
        (address predicted, uint256 minP, uint256 minS, uint256 minSPaired) = _localPass(_tmp("control"));
        _tx1to4();
        assertEq(address(seeder), predicted);

        deal(c.sUSDS, attacker, 1_000e18);
        vm.startPrank(attacker);
        address pair = IAmCutoverFactoryCreate(c.factory).createPair(c.antimatter, c.sUSDS);
        vm.expectRevert();
        IERC20(c.antimatter).transfer(pair, 1e18);
        IERC20(c.sUSDS).transfer(pair, 1e6);
        vm.expectRevert(); // UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED (one-sided)
        IM01Pair(pair).mint(attacker);
        vm.stopPrank();

        uint256 ownerS0 = IERC20(c.sUSDS).balanceOf(OWNER);
        vm.prank(OWNER);
        (uint256 am, uint256 liq) = seeder.seed(DRY_LP, minP, minS, minSPaired, OWNER, block.timestamp + 1 hours);
        vm.prank(OWNER);
        IM01Am(c.antimatter).setApprovedMinter(address(seeder), false);
        (uint256 rAm, uint256 rS) = _reserves(pair);
        assertEq(am, AM_MINTED);
        assertEq(rAm, AM_MINTED, "pair holds exactly the protocol AM");
        assertEq(rS, SUSDS_OUT + 1e6, "full sUSDS paired (+ the attacker's 1e6 wei donation, absorbed)");
        assertEq(IERC20(c.sUSDS).balanceOf(OWNER), ownerS0, "nothing returned: AM priced at the seed ratio");
        assertEq(IM01Pair(pair).totalSupply(), liq + 1000, "OWNER owns the pool");
    }
}
