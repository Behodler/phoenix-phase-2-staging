// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {NudgeDiscountMainnetBase} from "../script/helpers/NudgeDiscountMainnetBase.sol";
import {
    DeployNudgeDiscountHarness,
    VerifyNudgeDiscountHarness,
    VerifyPauserV2WithNudgeDiscount,
    NudgeDiscountConstants
} from "./helpers/NudgeDiscountHarnesses.sol";

interface INFTMinterOwnableFork {
    function transferOwnership(address newOwner) external;
    function authorizedMinters(address m) external view returns (bool);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface INudgeStreamerFork {
    function streams(address m, address t) external view returns (uint256, uint256, uint256, uint256);
}

interface IPauserV2Fork {
    function isRegistered(address c) external view returns (bool);
}

interface IOldMinterFork {
    function paused() external view returns (bool);
    function pauser() external view returns (address);
}

/**
 * @title NudgeDiscountMainnetConfigTest  (story 119) - no RPC needed
 * @notice The script's pinned addresses equal the book, the gate constants pass their own refusal rules, and the
 *         book still carries the NudgeDiscountBatchMinter ZERO placeholder (this story never edits the book).
 */
contract NudgeDiscountMainnetConfigTest is Test {
    function test_bookMatchesPinnedConstants_andPlaceholderIsZero() public {
        NudgeDiscountConstants c = new NudgeDiscountConstants();
        c.checkBook();
        assertEq(c.bookNewMinter(), address(0), "NudgeDiscountBatchMinter is still the zero placeholder");
        assertEq(c.bookKey("USDC"), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "whole-key USDC (not AutoUSDC)");
        assertEq(c.bookKey("Pauser"), 0x669Ebfa5309db66683c199Cfe22516DECBe1a154, "Pauser is PauserV2");
    }

    function test_gateConstants() public {
        NudgeDiscountConstants c = new NudgeDiscountConstants();
        c.checkGate();
        (uint256 cap, uint256 perPoint, uint8 maxBoost, uint256 fmax) = c.gate();
        assertGt(cap, 0);
        assertGt(perPoint, 0);
        assertGt(maxBoost, 0, "boost must not ship disabled");
        assertLe(maxBoost, 49);
        assertLe(cap, fmax, "cap <= GATE_FMAX");
        assertLe(cap, 50, "cap = min(50, Fmax)");
        assertGe(maxBoost, 10, "maxBoost within the 10-15 point target band");
        assertLe(maxBoost, 15, "maxBoost within the 10-15 point target band");
    }
}

/**
 * @title DeployMainnetNudgeDiscountForkTest  (story 119, sprint nudge-discount)
 * @notice Mainnet-fork rehearsal of the full cutover script against the LIVE old minter, NFTMinterV2, NudgeStreamer,
 *         donors and PauserV2: preview (with the smoke) writes nothing; broadcast mode writes `pending`, a re-run
 *         sends nothing, the verifier and `pauser-v2-verify` pass once the progress is confirmed and the registry
 *         carries the patcher's entries; a run interrupted after Phase 2 resumes idempotently; the old minter's
 *         stream buffer is released to zero and the whole old pot lands in the new stream; Phase 0 refuses a foreign
 *         NFTMinter owner; a book entry without a progress file is refused. Skipped without RPC_MAINNET.
 */
contract DeployMainnetNudgeDiscountForkTest is Test {
    uint256 constant FORK_BLOCK = 26_403_500;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant NUDGE_STREAMER = 0xF7e26179D6971985107AF66b078932D6484eBEAA;
    address constant OLD_MINTER = 0x068395556b8c43eDf257DC54D109EA5910aE15c7;
    address constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant KENDU = 0xaa95f26e30001251fb905d264Aa7b00eE9dF6C18;
    string constant TMP_PREFIX = "server/deployments/progress.nudge-discount.1.forktest-";

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("MAINNET_RPC_URL", string(""));
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

    function _markCompleted(string memory path) internal {
        // Flip exactly what scripts/confirm-nudge-discount-progress.js flips.
        vm.writeJson('"completed"', path, ".deploymentStatus");
        vm.writeJson("true", path, ".contracts.NudgeDiscountBatchMinter.deployed");
    }

    function _oldPot(address t) internal view returns (uint256) {
        (, uint256 buf,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(OLD_MINTER, t);
        return IERC20(t).balanceOf(OLD_MINTER) + buf;
    }

    // ---------------- preview ----------------

    function test_fork_preview_fullCutover_smoke_writesNoProgress() public {
        if (!_fork()) return;
        string memory path = _tmp("preview");
        uint256 usdcOwner = IERC20(USDC).balanceOf(OWNER);
        uint256 ethOwner = OWNER.balance;

        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(true, path, address(0));
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        assertTrue(s.smokeRan(), "preview smoke ran");
        assertGt(s.smokeUncappedFree(), 0, "uncapped batch had free NFTs");
        assertEq(s.smokeCappedFree(), 50, "capped batch free == cap");
        assertGt(s.smokeCappedBoost(), 0, "capped batch boosted");
        assertGt(s.smokeBuyPhusdOut(), 0, "buyAndBurn bought phUSD");
        assertFalse(vm.exists(path), "preview must not write the progress file");
        assertEq(IERC20(USDC).balanceOf(OWNER), usdcOwner, "OWNER USDC unchanged (transit closed)");
        assertLe(OWNER.balance, ethOwner, "OWNER ETH non-increasing");
    }

    // ---------------- broadcast mode: progress, idempotent re-run, verifiers ----------------

    function test_fork_broadcastMode_pending_rerunNoop_verifiersPass() public {
        if (!_fork()) return;
        string memory path = _tmp("broadcast");
        uint256 oldUsdcPot = _oldPot(USDC);
        assertGt(oldUsdcPot, 0, "the fork block has an old USDC pot to migrate");

        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, path, address(0));
        s.run();
        BatchNFTMinterNudgeDiscount m = s.minter();
        assertFalse(s.smokeRan(), "no smoke outside preview");
        uint256 nSteps = _checkPendingProgress(path, address(m), s.txCount());

        // Whole old pot (balance + buffer) now sits in the new minter's USDC stream; old side is empty.
        (, uint256 newBuf,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(address(m), USDC);
        assertEq(newBuf, oldUsdcPot, "new USDC stream buffer == old balance + old buffer");
        assertEq(_oldPot(USDC), 0, "old USDC pot empty");
        assertEq(IERC20(USDC).balanceOf(address(m)), 0, "nothing transferred straight onto the new minter");

        _checkRerunsSendNothing(path, address(m), nSteps);
        _checkVerifiers(path, address(m));
        vm.removeFile(path);
    }

    function _checkPendingProgress(string memory path, address m, uint256 txCount) internal returns (uint256) {
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1);
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "pending", "pending until confirmed");
        assertEq(vm.parseJsonAddress(json, ".contracts.NudgeDiscountBatchMinter.address"), m);
        assertEq(
            vm.parseJsonString(json, ".contracts.NudgeDiscountBatchMinter.contractName"), "BatchNFTMinterNudgeDiscount"
        );
        assertFalse(vm.parseJsonBool(json, ".contracts.NudgeDiscountBatchMinter.deployed"));
        assertTrue(vm.keyExistsJson(json, ".contracts.NudgeDiscountBatchMinter.createNonce"));
        assertEq(vm.parseJsonUint(json, ".baseline.block"), FORK_BLOCK);
        string[] memory steps = vm.parseJsonStringArray(json, ".configSteps");
        assertEq(steps.length, txCount, "every sent step recorded once");
        bool sawGrant;
        for (uint256 i = 0; i < steps.length; i++) {
            if (keccak256(bytes(steps[i])) == keccak256("nftMinter_setAuthorizedMinter")) sawGrant = true;
        }
        assertTrue(sawGrant, "configSteps include nftMinter_setAuthorizedMinter");
        return steps.length;
    }

    function _checkRerunsSendNothing(string memory path, address m, uint256 nSteps) internal {
        DeployNudgeDiscountHarness again = new DeployNudgeDiscountHarness(false, path, address(0));
        again.run();
        assertFalse(again.deployedThisRun(), "re-run must not deploy");
        assertEq(again.txCount(), 0, "re-run sends nothing");
        assertEq(address(again.minter()), m, "adopted");
        DeployNudgeDiscountHarness patched = new DeployNudgeDiscountHarness(false, path, m);
        patched.run();
        assertEq(patched.txCount(), 0, "re-run after the patch sends nothing");
        assertEq(vm.parseJsonStringArray(vm.readFile(path), ".configSteps").length, nSteps, "no duplicate steps");
    }

    function _checkVerifiers(string memory path, address m) internal {
        VerifyNudgeDiscountHarness v = new VerifyNudgeDiscountHarness(path, m);
        vm.expectRevert(bytes("verify: progress.nudge-discount.1.json is not completed - run the confirm step"));
        v.run();
        _markCompleted(path);
        v.run();
        VerifyNudgeDiscountHarness unpatched = new VerifyNudgeDiscountHarness(path, address(0));
        vm.expectRevert(
            bytes(
                "verify: address book NudgeDiscountBatchMinter != minter - run node scripts/patch-mainnet-addresses-nudge-discount.js"
            )
        );
        unpatched.run();

        // A re-run after the confirm step keeps `completed`.
        DeployNudgeDiscountHarness afterConfirm = new DeployNudgeDiscountHarness(false, path, m);
        afterConfirm.run();
        assertEq(vm.parseJsonString(vm.readFile(path), ".deploymentStatus"), "completed", "status preserved");

        // pauser-v2-verify: fails until the registry carries the patcher's entries, passes once it does.
        VerifyPauserV2WithNudgeDiscount pv = new VerifyPauserV2WithNudgeDiscount();
        vm.expectRevert();
        pv.run();
        pv.add(m);
        pv.remove(OLD_MINTER);
        pv.run();
    }

    // ---------------- resume ----------------

    /// @dev Phases 0-2 only, then the whole script again: it adopts the minter, re-sends no Phase 0-2 step, and
    ///      finishes Phases 3-4. A third run sends nothing.
    function test_fork_resumeAfterPhase2_isIdempotent() public {
        if (!_fork()) return;
        string memory path = _tmp("resume");
        DeployNudgeDiscountHarness first = new DeployNudgeDiscountHarness(false, path, address(0));
        first.setHaltAfterPhase2(true);
        first.run();
        BatchNFTMinterNudgeDiscount m = first.minter();
        assertTrue(INFTMinterOwnableFork(NFT_MINTER).authorizedMinters(address(m)), "phase 2 done");
        assertTrue(IOldMinterFork(OLD_MINTER).paused(), "phase 1 done");
        uint256 firstTx = first.txCount();

        DeployNudgeDiscountHarness second = new DeployNudgeDiscountHarness(false, path, address(0));
        second.run();
        assertFalse(second.deployedThisRun(), "adopted, not redeployed");
        assertEq(address(second.minter()), address(m));
        // 6 donor repoints + 2 buffer releases + rescue + approve + collectNudge.
        assertEq(second.txCount(), 11, "only Phases 3-4 sent on resume");
        assertGt(firstTx, second.txCount());

        DeployNudgeDiscountHarness third = new DeployNudgeDiscountHarness(false, path, address(0));
        third.run();
        assertEq(third.txCount(), 0, "finished cutover: nothing to send");
        vm.removeFile(path);
    }

    // ---------------- stream-buffer recovery ----------------

    function test_fork_bufferRecovery_leavesZeroBuffers() public {
        if (!_fork()) return;
        (, uint256 buf0,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(OLD_MINTER, USDC);
        assertGt(buf0, 0, "the fork block has an old USDC stream buffer");
        uint256 bal0 = IERC20(USDC).balanceOf(OLD_MINTER);
        string memory path = _tmp("buffers");
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, path, address(0));
        s.run();
        address[3] memory toks = [USDC, PHUSD, KENDU];
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 buf,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(OLD_MINTER, toks[i]);
            assertEq(buf, 0, "old buffer released");
            assertEq(IERC20(toks[i]).balanceOf(OLD_MINTER), 0, "old balance rescued");
        }
        assertEq(s.movedThisRun(0), buf0 + bal0, "moved == baseline balance + buffer (USDC)");
        vm.removeFile(path);
    }

    // ---------------- refusals ----------------

    function test_fork_phase0_refuses_foreignNFTMinterOwner() public {
        if (!_fork()) return;
        address other = makeAddr("someoneElse");
        vm.prank(OWNER);
        INFTMinterOwnableFork(NFT_MINTER).transferOwnership(other);
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(true, _tmp("owner"), address(0));
        vm.expectRevert(
            bytes(
                string.concat(
                    "preflight: NFTMinter.owner() != OWNER (actual ",
                    vm.toString(other),
                    ") - setAuthorizedMinter is onlyOwner; the cutover cannot be one Ledger session (blocker, see story Concern 2)"
                )
            )
        );
        s.run();
    }

    function test_fork_refuses_bookFilledWithoutProgress() public {
        if (!_fork()) return;
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(true, _tmp("filledbook"), makeAddr("someMinter"));
        vm.expectRevert(
            bytes(
                "address book names a NudgeDiscountBatchMinter but there is no progress file - refusing a double deployment (restore progress.nudge-discount.1.json)"
            )
        );
        s.run();
    }

    function test_fork_refuses_oldMinterOnV1Pauser() public {
        if (!_fork()) return;
        vm.prank(OWNER);
        (bool ok,) =
            OLD_MINTER.call(abi.encodeWithSignature("setPauser(address)", 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3));
        assertTrue(ok);
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(true, _tmp("v1"), address(0));
        vm.expectRevert(
            bytes("preflight: old minter pauser() is the RETIRED V1 Pauser - contradicts 128's migration record; stop")
        );
        s.run();
    }
}
