// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {ReplaceSYAGateOffMainnet} from "../script/ReplaceSYAGateOffMainnet.s.sol";
import {VerifySyaGateOffMainnet} from "../script/VerifySyaGateOffMainnet.s.sol";
import {VerifyPauserV2Migration} from "../script/VerifyPauserV2Migration.s.sol";
import {SyaGateOffMainnetBase, IOldSYA} from "../script/helpers/SyaGateOffMainnetBase.sol";
import {DeployNFTBonfireHarness} from "./DeployNFTBonfireMainnet.fork.t.sol";

interface IStrategyFork {
    function authorizedWithdrawers(address w) external view returns (bool);
}

interface IPauserV2Fork131 {
    function isRegistered(address c) external view returns (bool);
}

interface INFTMinterFork131 {
    function authorizedBurners(address b) external view returns (bool);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface INudgeStreamerFork {
    function streams(address batchMinter, address token) external view returns (uint256, uint256, uint256, uint256);
}

/// @dev Pins the mode, the progress path, the book's SYA / harvester keys and the sender (never the process-wide env,
///      never the real progress file). "Broadcast" mode sends as an OWNER prank: a forge test cannot sign with the
///      Ledger, and what is under test is the order, the state gating and the progress file.
contract ReplaceSYAGateOffHarness is ReplaceSYAGateOffMainnet {
    bool internal immutable preview;
    string internal progressPath;
    address internal bookedSya;
    address internal bookedHarvester;
    bool public creditOwnerOnce;

    constructor(bool preview_, string memory progressPath_, address bookedSya_, address bookedHarvester_) {
        preview = preview_;
        progressPath = progressPath_;
        bookedSya = bookedSya_;
        bookedHarvester = bookedHarvester_;
    }

    function setCreditOwnerOnce(bool v) external {
        creditOwnerOnce = v;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookSya() internal view override returns (address) {
        return bookedSya;
    }

    function _bookHarvester() internal view override returns (address) {
        return bookedHarvester;
    }

    function _sender() internal pure override returns (address) {
        return OWNER;
    }

    function _progressWriteEnabledFromEnv() internal pure override returns (bool) {
        return true;
    }

    function _requireBroadcastGasPriceHeadroom() internal view override {}

    function _begin() internal override {
        txCount++;
        vm.startPrank(OWNER);
    }

    function _end() internal override {
        vm.stopPrank();
        // Fault injection for the no-funds-to-Ledger test: something in the run credits OWNER with 1 wei of USDC.
        if (creditOwnerOnce) {
            creditOwnerOnce = false;
            deal(USDC, OWNER, IERC20(USDC).balanceOf(OWNER) + 1);
        }
    }
}

contract VerifySyaGateOffHarness is VerifySyaGateOffMainnet {
    string internal progressPath;
    address internal bookedSya;
    address internal bookedHarvester;

    constructor(string memory progressPath_, address bookedSya_, address bookedHarvester_) {
        progressPath = progressPath_;
        bookedSya = bookedSya_;
        bookedHarvester = bookedHarvester_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookSya() internal view override returns (address) {
        return bookedSya;
    }

    function _bookHarvester() internal view override returns (address) {
        return bookedHarvester;
    }
}

/// @dev `pauser-v2-verify` with PauserV2Registry entries appended, as the patchers will commit them.
contract VerifyPauserV2WithEntries is VerifyPauserV2Migration {
    address[] internal extraAdds;
    address[] internal extraRemovals;

    function add(address a) external {
        extraAdds.push(a);
    }

    function remove(address a) external {
        extraRemovals.push(a);
    }

    function _concat(address[] memory x, address[] storage y) internal view returns (address[] memory a) {
        a = new address[](x.length + y.length);
        for (uint256 i = 0; i < x.length; i++) {
            a[i] = x[i];
        }
        for (uint256 i = 0; i < y.length; i++) {
            a[x.length + i] = y[i];
        }
    }

    function postMigrationAdditions() public view override returns (address[] memory) {
        return _concat(super.postMigrationAdditions(), extraAdds);
    }

    function postMigrationRemovals() public view override returns (address[] memory) {
        return _concat(super.postMigrationRemovals(), extraRemovals);
    }
}

contract SyaGateOffBookHarness is SyaGateOffMainnetBase {
    function checkBook() external view {
        _requireBookMatchesConstants();
    }

    function bookKey(string memory key) external view returns (address) {
        return _bookAddress(vm.readFile(ADDRESS_BOOK), key);
    }
}

/**
 * @title SyaGateOffMainnetConfigTest  (story 131) - no RPC needed
 * @notice The pinned token constants / NFTMinterV2 / PauserV2 equal the book and the book reader matches whole keys.
 *         Deliberately does NOT assert the book's StableYieldAccumulator / SYAHarvester values: the patcher repoints
 *         them post-broadcast.
 */
contract SyaGateOffMainnetConfigTest is Test {
    function test_bookMatchesPinnedConstants() public {
        SyaGateOffBookHarness h = new SyaGateOffBookHarness();
        h.checkBook();
        assertEq(h.bookKey("USDC"), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "whole-key USDC (not AutoUSDC)");
        assertEq(h.bookKey("Dola"), 0x865377367054516e17014CcdED1e7d814EDC9ce4, "whole-key Dola (not AutoDOLA)");
        assertEq(h.bookKey("USDe"), 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3, "whole-key USDe (not SUSDe)");
        assertTrue(h.bookKey("StableYieldAccumulator") != address(0), "book has a StableYieldAccumulator key");
        assertTrue(h.bookKey("SYAHarvester") != address(0), "book has a SYAHarvester key");
        assertEq(h.bookKey("NoSuchKey"), address(0), "absent key reads zero");
    }
}

/**
 * @title ReplaceSYAGateOffMainnetForkTest  (story 131, sprint nft-bonfire)
 * @notice Mainnet-fork rehearsal of the full replacement against the LIVE old SYA, strategies, NFTMinterV2 and
 *         PauserV2: the 029 setter order end to end, the hard-coded token configs, the on-chain decimals check, the
 *         token set check (live pass + out-of-set revert), the negative ordering guard on a fresh 029 SYA, idempotent
 *         re-run, resume, live mirroring of a repointed nudge, the registry invariant with 129's NFTBonfire entry
 *         present, the read-only verifier and the no-funds-to-Ledger invariant. Skipped without RPC_MAINNET.
 */
contract ReplaceSYAGateOffMainnetForkTest is Test {
    /// @dev 2026-11-07, after the PauserV2 broadcast (2026-11-05); old SYA live and fully wired.
    uint256 constant FORK_BLOCK = 26_359_500;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant OLD_SYA = 0x0cD353bfda674D04823B2826ffafB83B560D21B6;
    address constant OLD_HARVESTER = 0xeE426A950Cb17D559F6391ef0D140715CD46703B;
    address constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    address constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant YS_USDC = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83;
    address constant YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;
    address constant YS_DOLA = 0x981c7BE1460c7C8Cb40B8EB5908B29510Ae0B7EE;
    address constant NUDGE_STREAMER = 0xF7e26179D6971985107AF66b078932D6484eBEAA;
    address constant RATCHET_BATCH_MINTER = 0x81896F48a95AbeA255cd38a3010E985b6051A1C7;
    string constant TMP_PREFIX = "server/deployments/progress.sya-gate-off.1.forktest-";
    uint256 constant FULL_RUN_TXS = 33;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        return true;
    }

    function _tmp(string memory name) internal returns (string memory path) {
        path = string.concat(TMP_PREFIX, name, ".json");
        if (vm.exists(path)) vm.removeFile(path);
    }

    function _fresh(bool preview, string memory path) internal returns (ReplaceSYAGateOffHarness) {
        return new ReplaceSYAGateOffHarness(preview, path, OLD_SYA, OLD_HARVESTER);
    }

    function _markCompleted(string memory path) internal {
        string memory json = vm.readFile(path);
        address sya = vm.parseJsonAddress(json, ".contracts.StableYieldAccumulator.address");
        address h = vm.parseJsonAddress(json, ".contracts.SYAHarvester.address");
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"completed","contracts":{"StableYieldAccumulator":{"address":"',
                vm.toString(sya),
                '","createNonce":0,"deployed":true},"SYAHarvester":{"address":"',
                vm.toString(h),
                '","createNonce":0,"deployed":true}}}'
            )
        );
    }

    /// @dev The hard-coded constants: configured, decimals 6 / 18 / 18, rate 1e18.
    function _assertTokenConfigs(StableYieldAccumulator s) internal view {
        address[3] memory t = [USDC, USDE, DOLA];
        uint8[3] memory d = [uint8(6), 18, 18];
        for (uint256 i = 0; i < 3; i++) {
            IStableYieldAccumulator.TokenConfig memory c = IStableYieldAccumulator(address(s)).getTokenConfig(t[i]);
            assertTrue(c.configured, "configured");
            assertEq(c.decimals, d[i], "decimals == hard-coded constant");
            assertEq(c.normalizedExchangeRate, 1e18, "rate 1e18");
            assertFalse(c.paused, "not paused");
        }
    }

    function _assertEndState(ReplaceSYAGateOffHarness r) internal view {
        StableYieldAccumulator s = r.newSya();
        assertEq(s.owner(), OWNER, "owner");
        _assertTokenConfigs(s);
        assertEq(s.rewardToken(), USDC, "rewardToken");
        assertEq(s.phlimbo(), IOldSYA(OLD_SYA).phlimbo(), "phlimbo mirrored");
        assertEq(s.nudge(), IOldSYA(OLD_SYA).nudge(), "nudge mirrored");
        assertEq(s.nudgeSplit(), IOldSYA(OLD_SYA).nudgeSplit(), "nudgeSplit mirrored");
        assertEq(s.nudgeStreamer(), IOldSYA(OLD_SYA).nudgeStreamer(), "nudgeStreamer mirrored");
        assertEq(s.nftMinter(), address(0), "gate OFF");
        assertEq(s.getDiscountRate(), 100, "1%");
        assertEq(s.pauser(), PAUSER_V2, "pauser");
        assertTrue(IPauserV2Fork131(PAUSER_V2).isRegistered(address(s)), "registered");
        address[3] memory st = [YS_USDC, YS_USDE, YS_DOLA];
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(s.isRegisteredStrategy(st[i]), "strategy on new SYA");
            assertTrue(IStrategyFork(st[i]).authorizedWithdrawers(address(s)), "withdrawer(new)");
            assertFalse(IStrategyFork(st[i]).authorizedWithdrawers(OLD_SYA), "withdrawer(old) revoked");
        }
        assertEq(IOldSYA(OLD_SYA).getYieldStrategies().length, 0, "old SYA stripped");
        assertFalse(IPauserV2Fork131(PAUSER_V2).isRegistered(OLD_SYA), "old SYA unregistered");
        assertEq(IOldSYA(OLD_SYA).pauser(), OWNER, "old SYA pauser moved off PauserV2");
        assertFalse(IOldSYA(OLD_SYA).paused(), "old SYA NOT paused");
        assertFalse(INFTMinterFork131(NFT_MINTER).authorizedBurners(OLD_SYA), "old SYA burner revoked");
        assertEq(IERC20(USDC).allowance(OLD_SYA, s.phlimbo()), 0, "old SYA phlimbo allowance 0");
        SYAHarvester h = r.harvester();
        assertTrue(address(h) != OLD_HARVESTER, "new harvester");
        assertEq(address(h.sya()), address(s), "harvester.sya == new SYA");
        assertEq(h.owner(), OWNER, "harvester owner");
        assertTrue(h.getRoute(USDE).configured && h.getRoute(DOLA).configured, "routes");
        assertFalse(h.getRoute(USDC).configured, "USDC unrouted");
    }

    /// @dev The 029 setter order, read off the new SYA's own events: TokenConfigSet x3 -> RewardTokenUpdated ->
    ///      PhlimboUpdated -> NudgeUpdated -> NudgeSplitUpdated -> NudgeStreamerUpdated -> YieldStrategyAdded x3 ->
    ///      DiscountRateSet -> PauserUpdated.
    function _assertSetterOrder(address s, Vm.Log[] memory logs) internal pure {
        bytes32[13] memory want = [
            keccak256("TokenConfigSet(address,uint8,uint256)"),
            keccak256("TokenConfigSet(address,uint8,uint256)"),
            keccak256("TokenConfigSet(address,uint8,uint256)"),
            keccak256("RewardTokenUpdated(address,address)"),
            keccak256("PhlimboUpdated(address,address)"),
            keccak256("NudgeUpdated(address,address)"),
            keccak256("NudgeSplitUpdated(uint256,uint256)"),
            keccak256("NudgeStreamerUpdated(address,address)"),
            keccak256("YieldStrategyAdded(address)"),
            keccak256("YieldStrategyAdded(address)"),
            keccak256("YieldStrategyAdded(address)"),
            keccak256("DiscountRateSet(uint256,uint256)"),
            keccak256("PauserUpdated(address,address)")
        ];
        uint256 k;
        for (uint256 i = 0; i < logs.length && k < want.length; i++) {
            if (logs[i].emitter != s || logs[i].topics.length == 0) continue;
            bytes32 t0 = logs[i].topics[0];
            if (t0 == keccak256("OwnershipTransferred(address,address)")) continue;
            require(t0 == want[k], "new SYA setter emitted out of the 029 order");
            k++;
        }
        require(k == want.length, "new SYA did not emit every expected setter event");
    }

    // ---------------- preview ----------------

    function test_fork_preview_fullRun_smokes_writesNoProgress() public {
        if (!_fork()) return;
        string memory path = _tmp("preview");
        uint256 usdcBefore = IERC20(USDC).balanceOf(OWNER);
        uint256 ethBefore = OWNER.balance;

        ReplaceSYAGateOffHarness r = _fresh(true, path);
        r.run();
        assertTrue(r.deployedSyaThisRun() && r.deployedHarvesterThisRun(), "both deployed");
        assertEq(r.txCount(), FULL_RUN_TXS, "full run tx count");
        _assertEndState(r);

        // claim(0) by a non-holder pays exactly yield x 99%.
        assertGt(r.smokeClaimPaid(), 0, "claim smoke paid");
        assertEq(r.smokeClaimPaid(), r.smokeClaimYieldNormalized() * 9900 / 10_000 / 1e12, "1% discount");
        assertGt(r.smokeHarvestEthOut(), 0, "harvest nftIndex 0 paid ETH");
        assertGt(r.smokePauseChecked(), 0, "pause round-trip checked registrants");
        // The retired old SYA still gates on the NFT, and its burner right is revoked: a holder's residual claim
        // reverts in the burn, before the (empty) strategy loop could reach ZeroAmount.
        assertEq(
            r.smokeOldClaimRevert(),
            abi.encodeWithSignature("Error(string)", "NFTMinterV2: caller is not authorized burner"),
            "old SYA residual claim reverts"
        );
        assertFalse(vm.exists(path), "preview must not write the progress file");
        assertEq(IERC20(USDC).balanceOf(OWNER), usdcBefore, "OWNER USDC unchanged");
        assertLe(OWNER.balance, ethBefore, "OWNER ETH non-increasing");
    }

    // ---------------- broadcast mode: order, progress, idempotent re-run, verifiers ----------------

    function test_fork_broadcastMode_029Order_progress_rerunNoop_verifiersPass() public {
        if (!_fork()) return;
        string memory path = _tmp("broadcast");
        ReplaceSYAGateOffHarness r = _fresh(false, path);
        vm.recordLogs();
        r.run();
        _assertSetterOrder(address(r.newSya()), vm.getRecordedLogs());
        assertEq(r.txCount(), FULL_RUN_TXS, "full run tx count");
        _assertEndState(r);
        assertEq(r.smokeClaimPaid(), 0, "no smoke outside preview");
        address sya = address(r.newSya());
        address h = address(r.harvester());

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1, "chainId");
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "pending", "pending until confirmed");
        assertEq(vm.parseJsonAddress(json, ".contracts.StableYieldAccumulator.address"), sya, "sya");
        assertEq(vm.parseJsonAddress(json, ".contracts.SYAHarvester.address"), h, "harvester");
        assertTrue(vm.keyExistsJson(json, ".contracts.StableYieldAccumulator.createNonce"), "sya createNonce");
        assertTrue(vm.keyExistsJson(json, ".contracts.SYAHarvester.createNonce"), "harvester createNonce");
        assertEq(vm.parseJsonAddress(json, ".oldStableYieldAccumulator"), OLD_SYA, "old SYA recorded");

        // Re-run adopts both and sends nothing: before and after the patcher repoints the book.
        ReplaceSYAGateOffHarness again = _fresh(false, path);
        again.run();
        assertFalse(again.deployedSyaThisRun() || again.deployedHarvesterThisRun(), "re-run must not deploy");
        assertEq(again.txCount(), 0, "re-run sends nothing");
        assertEq(address(again.newSya()), sya, "adopted SYA");
        ReplaceSYAGateOffHarness patched = new ReplaceSYAGateOffHarness(false, path, sya, h);
        patched.run();
        assertEq(patched.txCount(), 0, "re-run after patch sends nothing");

        // Verifier: refuses pending; passes once confirmed and patched; refuses an unpatched book.
        VerifySyaGateOffHarness v = new VerifySyaGateOffHarness(path, sya, h);
        vm.expectRevert(bytes("verify: progress.sya-gate-off.1.json is not completed - run the confirm step"));
        v.run();
        _markCompleted(path);
        v.run();
        VerifySyaGateOffHarness unpatched = new VerifySyaGateOffHarness(path, OLD_SYA, OLD_HARVESTER);
        vm.expectRevert(
            bytes(
                "verify: address book StableYieldAccumulator != new SYA - run node scripts/patch-mainnet-addresses-sya-gate-off.js"
            )
        );
        unpatched.run();

        // pauser-v2-verify: fails until the registry records both changes, passes once appended.
        VerifyPauserV2WithEntries pv = new VerifyPauserV2WithEntries();
        vm.expectRevert(bytes("verify: live registrant(s) not on PauserV2 - see the log above"));
        pv.run();
        pv.remove(OLD_SYA);
        vm.expectRevert(
            bytes("verify: PauserV2 holds an address that is neither live nor a committed addition - see the log above")
        );
        pv.run();
        pv.add(sya);
        pv.run();

        // A drifted discount fails the verifier by name.
        StableYieldAccumulator live = r.newSya(); // cached: a call between vm.prank and the target eats the prank
        vm.prank(OWNER);
        live.setDiscountRate(3000);
        vm.expectRevert(bytes("verify: new SYA discount != 100 bps"));
        v.run();
        vm.removeFile(path);
    }

    // ---------------- registry invariant with 129's NFTBonfire present ----------------

    function test_fork_registryInvariant_with129BonfireEntry() public {
        if (!_fork()) return;
        string memory bonfirePath = "server/deployments/progress.nft-bonfire.1.forktest-s131.json";
        if (vm.exists(bonfirePath)) vm.removeFile(bonfirePath);
        DeployNFTBonfireHarness b = new DeployNFTBonfireHarness(false, bonfirePath, address(0));
        b.run();
        address bonfire = address(b.bonfire());

        string memory path = _tmp("registry");
        ReplaceSYAGateOffHarness r = _fresh(false, path);
        r.run();
        _assertEndState(r);

        VerifyPauserV2WithEntries pv = new VerifyPauserV2WithEntries();
        pv.add(bonfire); // 129's entry, kept
        pv.add(address(r.newSya()));
        pv.remove(OLD_SYA);
        pv.run();
        vm.removeFile(path);
        vm.removeFile(bonfirePath);
    }

    // ---------------- live mirroring ----------------

    /// @dev phStaging2:119 may repoint the old SYA's nudge before this broadcasts: the new SYA must follow it.
    function test_fork_mirrorsRepointedNudge() public {
        if (!_fork()) return;
        vm.prank(OWNER);
        IOldSYAAdmin(OLD_SYA).setNudgeAddress(RATCHET_BATCH_MINTER);
        // The preflight requires a registered (nudge, USDC) stream; stand one in for the new nudge.
        vm.mockCall(
            NUDGE_STREAMER,
            abi.encodeWithSelector(INudgeStreamerFork.streams.selector, RATCHET_BATCH_MINTER, USDC),
            abi.encode(uint256(30 days), uint256(0), uint256(0), uint256(0))
        );
        string memory path = _tmp("mirror");
        ReplaceSYAGateOffHarness r = _fresh(false, path);
        r.run();
        assertEq(r.newSya().nudge(), RATCHET_BATCH_MINTER, "nudge mirrored live, not hard-coded");
        _assertEndState(r);
        vm.removeFile(path);
    }

    // ---------------- token set + decimals ----------------

    function test_fork_onChainDecimalsEqualConstants_liveTokenSetPasses() public {
        if (!_fork()) return;
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC 6");
        assertEq(IERC20Metadata(DOLA).decimals(), 18, "DOLA 18");
        assertEq(IERC20Metadata(USDE).decimals(), 18, "USDe 18");
        address[] memory list = IOldSYA(OLD_SYA).getYieldStrategies();
        assertEq(list.length, 3, "live list has 3 strategies");
        assertEq(IOldSYA(OLD_SYA).strategyTokens(YS_USDC), USDC, "USDC strategy");
        assertEq(IOldSYA(OLD_SYA).strategyTokens(YS_USDE), USDE, "USDe strategy");
        assertEq(IOldSYA(OLD_SYA).strategyTokens(YS_DOLA), DOLA, "DOLA strategy");
    }

    function test_fork_tokenSet_revertsOnOutOfSetToken() public {
        if (!_fork()) return;
        vm.mockCall(OLD_SYA, abi.encodeWithSelector(IOldSYA.strategyTokens.selector, YS_USDC), abi.encode(SUSDS));
        ReplaceSYAGateOffHarness r = _fresh(true, _tmp("tokenset"));
        vm.expectRevert(bytes("token set: a strategy's token is not one of USDC / DOLA / USDe"));
        r.run();
    }

    function test_fork_tokenSet_revertsOnWrongCount() public {
        if (!_fork()) return;
        address[] memory two = new address[](2);
        two[0] = YS_USDC;
        two[1] = YS_USDE;
        vm.mockCall(OLD_SYA, abi.encodeWithSelector(IOldSYA.getYieldStrategies.selector), abi.encode(two));
        ReplaceSYAGateOffHarness r = _fresh(true, _tmp("tokencount"));
        vm.expectRevert(bytes("token set: strategy list must have exactly 3 entries"));
        r.run();
    }

    function test_fork_decimals_revertsOnMismatch() public {
        if (!_fork()) return;
        vm.mockCall(DOLA, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(6)));
        ReplaceSYAGateOffHarness r = _fresh(true, _tmp("decimals"));
        vm.expectRevert(bytes("on-chain decimals() != hard-coded constant for DOLA"));
        r.run();
    }

    // ---------------- the 029 ordering guard is live in the deployed bytecode ----------------

    function test_fork_fresh029Sya_setRewardTokenBeforeConfig_revertsTokenNotConfigured() public {
        if (!_fork()) return;
        vm.startPrank(OWNER);
        StableYieldAccumulator s = new StableYieldAccumulator();
        vm.expectRevert(abi.encodeWithSelector(IStableYieldAccumulator.TokenNotConfigured.selector, USDC));
        s.setRewardToken(USDC);
        vm.expectRevert(abi.encodeWithSelector(IStableYieldAccumulator.TokenNotConfigured.selector, USDC));
        s.addYieldStrategy(YS_USDC, USDC);
        s.setTokenConfig(USDC, 6, 1e18);
        s.setRewardToken(USDC);
        vm.stopPrank();
        assertEq(s.rewardToken(), USDC, "configured first, then accepted");
    }

    // ---------------- resume and refusal ----------------

    /// @dev A run interrupted after the CREATE and the first setTokenConfig resumes with exactly the rest.
    function test_fork_interruptedRun_resumesRemainingSteps() public {
        if (!_fork()) return;
        string memory path = _tmp("resume");
        vm.startPrank(OWNER);
        StableYieldAccumulator s = new StableYieldAccumulator();
        s.setTokenConfig(USDC, 6, 1e18);
        vm.stopPrank();
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"pending","contracts":{"StableYieldAccumulator":{"address":"',
                vm.toString(address(s)),
                '","createNonce":0,"deployed":false}}}'
            )
        );
        ReplaceSYAGateOffHarness r = _fresh(false, path);
        r.run();
        assertFalse(r.deployedSyaThisRun(), "SYA adopted, not redeployed");
        assertTrue(r.deployedHarvesterThisRun(), "harvester deployed");
        assertEq(address(r.newSya()), address(s), "adopted");
        assertEq(r.txCount(), FULL_RUN_TXS - 2, "everything but the CREATE and the first token config");
        _assertEndState(r);
        assertEq(
            vm.parseJsonAddress(vm.readFile(path), ".contracts.StableYieldAccumulator.address"),
            address(s),
            "progress keeps the adopted SYA"
        );
        vm.removeFile(path);
    }

    function test_fork_refuses_bookRepointedWithoutProgress() public {
        if (!_fork()) return;
        ReplaceSYAGateOffHarness r =
            new ReplaceSYAGateOffHarness(true, _tmp("nobook"), makeAddr("someSya"), OLD_HARVESTER);
        vm.expectRevert(
            bytes(
                "address book StableYieldAccumulator is not the old SYA but there is no progress file - restore progress.sya-gate-off.1.json"
            )
        );
        r.run();
    }

    function test_fork_refuses_progressWithoutCode_nonceConsumed() public {
        if (!_fork()) return;
        string memory path = _tmp("nocode");
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"contracts":{"StableYieldAccumulator":{"address":"',
                vm.toString(makeAddr("ghostSya")),
                '","createNonce":0,"deployed":false}}}'
            )
        );
        ReplaceSYAGateOffHarness r = _fresh(false, path);
        vm.expectRevert();
        r.run();
        vm.removeFile(path);
    }

    // ---------------- no funds to the Ledger ----------------

    function test_fork_ownerBalanceIncrease_revertsByName() public {
        if (!_fork()) return;
        ReplaceSYAGateOffHarness r = _fresh(false, _tmp("credit"));
        r.setCreditOwnerOnce(true);
        uint256 before = IERC20(USDC).balanceOf(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                SyaGateOffMainnetBase.OwnerBalanceIncreased.selector, USDC, uint256(0), before, before + 1
            )
        );
        r.run();
        _tmp("credit");
    }
}

interface IOldSYAAdmin {
    function setNudgeAddress(address n) external;
}
