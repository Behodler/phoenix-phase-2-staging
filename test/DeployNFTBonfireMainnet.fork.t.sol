// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NFTBonfire} from "@yield-claim-nft/NFTBonfire.sol";
import {DeployNFTBonfireMainnet} from "../script/DeployNFTBonfireMainnet.s.sol";
import {VerifyNFTBonfireMainnet} from "../script/VerifyNFTBonfireMainnet.s.sol";
import {VerifyPauserV2Migration} from "../script/VerifyPauserV2Migration.s.sol";
import {NFTBonfireMainnetBase} from "../script/helpers/NFTBonfireMainnetBase.sol";

interface INFTMinterV2Fork {
    function authorizedBurners(address b) external view returns (bool);
    function setAuthorizedBurner(address b, bool a) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IAntimatterFork {
    function isApprovedMinter(address m) external view returns (bool);
    function setApprovedMinter(address m, bool a) external;
}

interface IPauserV2Fork {
    function isRegistered(address c) external view returns (bool);
}

/// @dev Pins the mode, the progress path, the book's NFTBonfire value and the sender (never the process-wide env,
///      which races parallel suites, and never the real progress file). "Broadcast" mode sends as an OWNER prank:
///      a forge test cannot sign with the Ledger, and what is under test is the state gating and the progress file.
contract DeployNFTBonfireHarness is DeployNFTBonfireMainnet {
    bool internal immutable preview;
    string internal progressPath;
    address internal booked;
    bool public creditOwnerDuringWiring;

    constructor(bool preview_, string memory progressPath_, address booked_) {
        preview = preview_;
        progressPath = progressPath_;
        booked = booked_;
    }

    function setCreditOwnerDuringWiring(bool v) external {
        creditOwnerDuringWiring = v;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookBonfire() internal view override returns (address) {
        return booked;
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
        // Fault injection for the no-funds-to-Ledger test: something in the run credits OWNER with antimatter.
        if (creditOwnerDuringWiring) {
            deal(ANTIMATTER, OWNER, IERC20(ANTIMATTER).balanceOf(OWNER) + 1);
        }
    }
}

contract VerifyNFTBonfireHarness is VerifyNFTBonfireMainnet {
    string internal progressPath;
    address internal booked;

    constructor(string memory progressPath_, address booked_) {
        progressPath = progressPath_;
        booked = booked_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookBonfire() internal view override returns (address) {
        return booked;
    }
}

/// @dev `pauser-v2-verify` with the bonfire appended to postMigrationAdditions(), as the patcher will commit it.
contract VerifyPauserV2WithBonfire is VerifyPauserV2Migration {
    address[] internal extra;

    function add(address a) external {
        extra.push(a);
    }

    function postMigrationAdditions() public view override returns (address[] memory a) {
        address[] memory committed = super.postMigrationAdditions();
        a = new address[](committed.length + extra.length);
        for (uint256 i = 0; i < committed.length; i++) {
            a[i] = committed[i];
        }
        for (uint256 i = 0; i < extra.length; i++) {
            a[committed.length + i] = extra[i];
        }
    }
}

contract NFTBonfireBookHarness is NFTBonfireMainnetBase {
    function checkBook() external view {
        _requireBookMatchesConstants();
    }

    function bookKey(string memory key) external view returns (address) {
        return _bookAddress(vm.readFile(BOOK_FILE), key);
    }

    function hasBonfireKey() external view returns (bool) {
        return vm.indexOf(vm.readFile(BOOK_FILE), "\n  NFTBonfire: \"") != type(uint256).max;
    }
}

/**
 * @title NFTBonfireMainnetConfigTest  (story 129) - no RPC needed
 * @notice The script's pinned NFTMinterV2 / Antimatter / PauserV2 equal the book, and the book reader matches whole
 *         keys only. Deliberately does NOT assert the book's NFTBonfire value: the patcher fills it post-broadcast.
 */
contract NFTBonfireMainnetConfigTest is Test {
    function test_bookMatchesPinnedConstants() public {
        NFTBonfireBookHarness h = new NFTBonfireBookHarness();
        h.checkBook();
        assertTrue(h.hasBonfireKey(), "book has an NFTBonfire key");
        assertEq(h.bookKey("USDC"), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "whole-key USDC (not AutoUSDC)");
        assertEq(h.bookKey("Pauser"), 0x669Ebfa5309db66683c199Cfe22516DECBe1a154, "Pauser is PauserV2");
        assertEq(h.bookKey("NoSuchKey"), address(0), "absent key reads zero");
    }
}

/**
 * @title DeployNFTBonfireMainnetForkTest  (story 129, sprint nft-bonfire)
 * @notice Mainnet-fork rehearsal of the full cutover script against the LIVE NFTMinterV2, Antimatter and PauserV2:
 *         wiring order and read-backs, idempotent re-run, resume after an interrupted run, refusal when the rate is
 *         already non-zero with the cap unset, `pauser-v2-verify` passing with the bonfire appended, the read-only
 *         verifier, and the no-funds-to-Ledger invariant (OWNER balances unchanged; a credit reverts by name).
 *         Skipped without RPC_MAINNET. FORK_BLOCK is after the human's PauserV2 broadcast (2026-11-05).
 */
contract DeployNFTBonfireMainnetForkTest is Test {
    uint256 constant FORK_BLOCK = 26_351_700;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    address constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    string constant TMP_PREFIX = "server/deployments/progress.nft-bonfire.1.forktest-";

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

    function _writeProgress(string memory path, address b, string memory status) internal {
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"',
                status,
                '","contracts":{"NFTBonfire":{"address":"',
                vm.toString(b),
                '","createNonce":0,"deployed":true}}}'
            )
        );
    }

    function _markCompleted(string memory path) internal {
        address b = vm.parseJsonAddress(vm.readFile(path), ".contracts.NFTBonfire.address");
        _writeProgress(path, b, "completed");
    }

    function _assertWired(NFTBonfire b) internal view {
        assertEq(b.owner(), OWNER, "owner");
        assertEq(address(b.nftMinter()), NFT_MINTER, "nftMinter");
        assertEq(address(b.antimatter()), ANTIMATTER, "antimatter");
        assertEq(b.ratePerDay(), 10e18, "rate");
        assertEq(b.maxPayout(), 100e18, "cap");
        assertEq(b.pauser(), PAUSER_V2, "pauser");
        assertTrue(IPauserV2Fork(PAUSER_V2).isRegistered(address(b)), "registered");
        assertFalse(b.paused(), "not paused");
        assertTrue(INFTMinterV2Fork(NFT_MINTER).authorizedBurners(address(b)), "burner");
        assertTrue(IAntimatterFork(ANTIMATTER).isApprovedMinter(address(b)), "AM minter");
    }

    /// @dev Audit run 23 L-29 / Q-27 order, read off the first log of each step: burner grant (NFTMinterV2), AM
    ///      minter grant (Antimatter), bonfire.setPauser, PauserV2.register, setMaxPayout, setRatePerDay LAST.
    function _assertWiringOrder(address b, Vm.Log[] memory logs) internal pure {
        bytes32 pauserChanged = keccak256("PauserChanged(address,address)");
        bytes32 maxSet = keccak256("MaxPayoutUpdated(uint256,uint256)");
        bytes32 rateSet = keccak256("RatePerDayUpdated(uint256,uint256)");
        uint256 none = type(uint256).max;
        uint256[6] memory at = [none, none, none, none, none, none];
        for (uint256 i = 0; i < logs.length; i++) {
            address e = logs[i].emitter;
            bytes32 t = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (e == NFT_MINTER && at[0] == none) at[0] = i;
            else if (e == ANTIMATTER && at[1] == none) at[1] = i;
            else if (e == b && t == pauserChanged && at[2] == none) at[2] = i;
            else if (e == PAUSER_V2 && at[3] == none) at[3] = i;
            else if (e == b && t == maxSet && at[4] == none) at[4] = i;
            else if (e == b && t == rateSet && at[5] == none) at[5] = i;
        }
        for (uint256 k = 0; k < 6; k++) {
            require(at[k] != none, "wiring step emitted no log");
            if (k > 0) require(at[k - 1] < at[k], "wiring steps out of the audit-mandated order");
        }
    }

    // ---------------- preview ----------------

    function test_fork_preview_wiresInOrder_smokes_writesNoProgress() public {
        if (!_fork()) return;
        string memory path = _tmp("preview");
        uint256 amBefore = IERC20(ANTIMATTER).balanceOf(OWNER);
        uint256 phBefore = IERC20(PHUSD).balanceOf(OWNER);
        uint256 ethBefore = OWNER.balance;

        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(true, path, address(0));
        vm.recordLogs();
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        _assertWiringOrder(address(s.bonfire()), vm.getRecordedLogs());
        assertEq(s.txCount(), 7, "deploy + 6 wiring txs");
        _assertWired(s.bonfire());
        assertEq(s.smokeOneDayPayout(), 10e18, "1-day burn = 10 AM");
        assertEq(s.smokeThirtyDayPayout(), 100e18, "30-day burn capped at 100 AM");
        assertFalse(vm.exists(path), "preview must not write the progress file");

        assertEq(IERC20(ANTIMATTER).balanceOf(OWNER), amBefore, "OWNER AM unchanged");
        assertEq(IERC20(PHUSD).balanceOf(OWNER), phBefore, "OWNER phUSD unchanged");
        assertLe(OWNER.balance, ethBefore, "OWNER ETH non-increasing");
        for (uint256 id = 0; id < 9; id++) {
            assertEq(INFTMinterV2Fork(NFT_MINTER).balanceOf(OWNER, id), 0, "OWNER holds no claim NFT");
        }
    }

    // ---------------- broadcast mode: progress, idempotent re-run, verifiers ----------------

    function test_fork_broadcastMode_writesPending_rerunIsNoop_verifiersPass() public {
        if (!_fork()) return;
        string memory path = _tmp("broadcast");
        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(false, path, address(0));
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        assertEq(s.txCount(), 7, "deploy + 6 wiring txs");
        NFTBonfire b = s.bonfire();
        _assertWired(b);
        assertEq(s.smokeOneDayPayout(), 0, "no smoke outside preview");

        // The shape scripts/confirm-nft-bonfire-progress.js and the patcher read.
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1, "chainId");
        assertEq(vm.parseJsonString(json, ".networkName"), "mainnet", "networkName");
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "pending", "pending until confirmed");
        assertEq(vm.parseJsonAddress(json, ".contracts.NFTBonfire.address"), address(b), "address");
        assertTrue(vm.keyExistsJson(json, ".contracts.NFTBonfire.createNonce"), "createNonce recorded");
        assertFalse(vm.parseJsonBool(json, ".contracts.NFTBonfire.deployed"), "deployed=false until confirmed");

        // Re-run: adopts, sends nothing - before and after the patcher fills the book.
        DeployNFTBonfireHarness again = new DeployNFTBonfireHarness(false, path, address(0));
        again.run();
        assertFalse(again.deployedThisRun(), "re-run must not deploy");
        assertEq(again.txCount(), 0, "re-run sends nothing");
        assertEq(address(again.bonfire()), address(b), "adopted");
        DeployNFTBonfireHarness patched = new DeployNFTBonfireHarness(false, path, address(b));
        patched.run();
        assertEq(patched.txCount(), 0, "re-run after patch sends nothing");

        // Verifier: refuses a pending progress; passes once confirmed and the book is patched.
        VerifyNFTBonfireHarness v = new VerifyNFTBonfireHarness(path, address(b));
        vm.expectRevert(bytes("verify: progress.nft-bonfire.1.json is not completed - run the confirm step"));
        v.run();
        _markCompleted(path);
        v.run();
        VerifyNFTBonfireHarness unpatched = new VerifyNFTBonfireHarness(path, address(0));
        vm.expectRevert(
            bytes(
                "verify: address book NFTBonfire != bonfire - run node scripts/patch-mainnet-addresses-nft-bonfire.js"
            )
        );
        unpatched.run();

        // pauser-v2-verify: fails until the bonfire is committed to PauserV2Registry, passes once appended.
        VerifyPauserV2WithBonfire pv = new VerifyPauserV2WithBonfire();
        vm.expectRevert(
            bytes("verify: PauserV2 holds an address that is neither live nor a committed addition - see the log above")
        );
        pv.run();
        pv.add(address(b));
        pv.run();

        vm.removeFile(path);
    }

    function test_fork_verify_rejectsDisabledRate() public {
        if (!_fork()) return;
        string memory path = _tmp("verifyrate");
        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(false, path, address(0));
        s.run();
        NFTBonfire b = s.bonfire();
        _markCompleted(path);
        vm.prank(OWNER);
        b.setRatePerDay(0);
        VerifyNFTBonfireHarness v = new VerifyNFTBonfireHarness(path, address(b));
        vm.expectRevert(bytes("verify: ratePerDay != 10e18"));
        v.run();
        vm.removeFile(path);
    }

    // ---------------- resume and refusal ----------------

    /// @dev A run interrupted after the CREATE and steps 2-3 resumes with exactly the 4 remaining txs.
    function test_fork_interruptedRun_resumesRemainingSteps() public {
        if (!_fork()) return;
        string memory path = _tmp("resume");
        vm.startPrank(OWNER);
        NFTBonfire b = new NFTBonfire(OWNER, NFT_MINTER, ANTIMATTER);
        INFTMinterV2Fork(NFT_MINTER).setAuthorizedBurner(address(b), true);
        IAntimatterFork(ANTIMATTER).setApprovedMinter(address(b), true);
        vm.stopPrank();
        _writeProgress(path, address(b), "pending");

        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(false, path, address(0));
        s.run();
        assertFalse(s.deployedThisRun(), "adopted, not redeployed");
        assertEq(s.txCount(), 4, "setPauser, register, cap, rate");
        _assertWired(b);
        vm.removeFile(path);
    }

    /// @dev Audit L-29: the cap must be set before any non-zero rate. A bonfire whose rate is live with the cap
    ///      unset (unlimited) is refused, not "fixed" mid-flight.
    function test_fork_refuses_rateNonZero_capUnset() public {
        if (!_fork()) return;
        string memory path = _tmp("refuse");
        vm.startPrank(OWNER);
        NFTBonfire b = new NFTBonfire(OWNER, NFT_MINTER, ANTIMATTER);
        b.setRatePerDay(10e18);
        vm.stopPrank();
        _writeProgress(path, address(b), "pending");

        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(false, path, address(0));
        vm.expectRevert(
            bytes(
                "step 5: ratePerDay is already non-zero while the cap is unset - refusing (stop burns with setRatePerDay(0) first; runbook)"
            )
        );
        s.run();
        vm.removeFile(path);
    }

    function test_fork_refuses_bookFilledWithoutProgress() public {
        if (!_fork()) return;
        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(true, _tmp("filledbook"), makeAddr("someBonfire"));
        vm.expectRevert(
            bytes(
                "address book names an NFTBonfire but there is no progress file - restore progress.nft-bonfire.1.json"
            )
        );
        s.run();
    }

    function test_fork_refuses_progressWithoutCode_nonceConsumed() public {
        if (!_fork()) return;
        string memory path = _tmp("nocode");
        _writeProgress(path, makeAddr("ghostBonfire"), "pending"); // createNonce 0, long consumed by OWNER
        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(false, path, address(0));
        vm.expectRevert();
        s.run();
        vm.removeFile(path);
    }

    // ---------------- no funds to the Ledger ----------------

    function test_fork_ownerBalanceIncrease_revertsByName() public {
        if (!_fork()) return;
        DeployNFTBonfireHarness s = new DeployNFTBonfireHarness(false, _tmp("credit"), address(0));
        s.setCreditOwnerDuringWiring(true);
        uint256 before = IERC20(ANTIMATTER).balanceOf(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                NFTBonfireMainnetBase.OwnerBalanceIncreased.selector, ANTIMATTER, uint256(0), before, before + 7
            )
        );
        s.run();
        _tmp("credit");
    }
}
