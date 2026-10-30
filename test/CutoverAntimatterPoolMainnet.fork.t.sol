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
        seeder.seed(lp, 1, 1, OWNER, block.timestamp + 1 hours);
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
