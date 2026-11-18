// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {NudgeDiscountMainnetBase} from "../script/helpers/NudgeDiscountMainnetBase.sol";
import {NudgePotForwarder} from "../src/periphery/NudgePotForwarder.sol";
import {
    DeployNudgeDiscountHarness,
    DeployNudgeDiscountOwnerTransitHarness,
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

interface INFTMinterRatchetFork {
    function configs(uint256 index) external view returns (address, uint256, uint256, bool);
    function mint(uint256 index, address recipient) external returns (bool);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function setDispatcherDisabled(uint256 index, bool disabled) external;
    function replaceDispatcher(uint256 index, address newDispatcher) external;
    function nextIndex() external view returns (uint256);
}

interface IRatchetStakerFork {
    function users(address account) external view returns (uint256 amount, uint256 rewardDebt);
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claim() external;
    function runwaySeconds() external view returns (uint256);
}

interface IRatchetBatchMinterFork {
    function batchMint(uint256 count, address recipient, uint256 paymentAmount, uint256 minReward)
        external
        returns (uint256);
}

interface INudgeStreamerCollectFork {
    function collectNudge(address m, address t, uint256 amt) external;
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
        (uint256 cap, uint256 perPoint, uint8 day1MaxBoost, uint8 ceiling, uint256 fmax) = c.gate();
        assertGt(cap, 0);
        assertGt(perPoint, 0);
        // Story 135: the boost ships DISABLED on day 1; the measured gas-safe ceiling stays a named constant.
        assertEq(day1MaxBoost, 0, "story 135: day-1 maxBoost is 0 (boost disabled)");
        assertLe(day1MaxBoost, ceiling, "day-1 boost within the gas-safe ceiling");
        assertGt(ceiling, 0, "gas-safe ceiling non-zero");
        assertLe(ceiling, 49);
        assertLe(cap, fmax, "cap <= GATE_FMAX");
        assertLe(cap, 50, "cap = min(50, Fmax)");
        assertGe(ceiling, 10, "ceiling within the 10-15 point target band");
        assertLe(ceiling, 15, "ceiling within the 10-15 point target band");
    }

    function test_ratchetConstants() public {
        NudgeDiscountConstants c = new NudgeDiscountConstants();
        (uint256 index, address ratchet, address staker, address batchMinter) = c.ratchet();
        assertEq(index, 7, "ratchet is NFTMinterV2 index 7");
        assertEq(ratchet, 0x7E3fB41FD3E99312FBa8bfc71E79e635d526AA40, "NudgeRatchet pinned");
        assertEq(c.bookKey("NudgeRatchet"), ratchet, "book NudgeRatchet == pinned");
        assertEq(c.bookKey("RatchetNFTStaker"), staker, "book RatchetNFTStaker == pinned");
        assertEq(c.bookKey("RatchetBatchNFTMinter"), batchMinter, "book RatchetBatchNFTMinter == pinned");
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
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
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
        assertEq(s.smokeCappedBoost(), 0, "story 135: day-1 maxBoost 0 - an overflowing capped batch is not boosted");
        assertTrue(s.smokeRatchetMintRefused(), "story 135 smoke: mint(7) refused");
        assertTrue(s.smokeRatchetBatchMintRefused(), "story 135 smoke: RatchetBatchNFTMinter.batchMint refused");
        assertTrue(s.smokeRatchetStaker() != address(0), "story 135 smoke: a live staker claimed/unstaked/re-staked");
        assertGt(s.smokeBuyPhusdOut(), 0, "buyAndBurn bought phUSD");
        assertFalse(vm.exists(path), "preview must not write the progress file");
        assertEq(IERC20(USDC).balanceOf(OWNER), usdcOwner, "OWNER USDC unchanged");
        assertLe(OWNER.balance, ethOwner, "OWNER ETH non-increasing");
        address f = s.potForwarder();
        assertTrue(f != address(0) && f.code.length > 0, "pot migrated through the forwarder");
        assertEq(IERC20(USDC).balanceOf(f), 0, "forwarder empty");
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
        // Every nudge stream, USDC included, depletes over 30 days (human decision 2026-11-18).
        address[3] memory streamToks = [USDC, PHUSD, KENDU];
        for (uint256 i = 0; i < 3; i++) {
            (uint256 dur,,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(address(m), streamToks[i]);
            assertEq(dur, 30 days, "new minter stream duration == 30 days");
        }
        assertEq(_oldPot(USDC), 0, "old USDC pot empty");
        assertEq(IERC20(USDC).balanceOf(address(m)), 0, "nothing transferred straight onto the new minter");
        address f = s.potForwarder();
        assertTrue(f.code.length > 0, "forwarder deployed");
        assertEq(IERC20(USDC).balanceOf(f), 0, "forwarder empty");
        assertEq(
            vm.parseJsonAddress(vm.readFile(path), ".contracts.NudgePotForwarder.address"), f, "progress records it"
        );

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
    ///      finishes Phases 3, 3b and 4. A third run sends nothing.
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
        // 6 donor repoints + story 135's ratchet disable (Phase 3b) + 2 buffer releases + forwarder CREATE2 deploy
        // + rescue to forwarder + forward.
        assertEq(second.txCount(), 12, "only Phases 3, 3b and 4 sent on resume");
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

    // ---------------- no FUNDS TO THE LEDGER: per-step OWNER invariant (the human's ruling, 2026-11-13) ----------------

    function _watched() internal pure returns (address[] memory t) {
        t = new address[](6);
        t[0] = USDC;
        t[1] = PHUSD;
        t[2] = KENDU;
        t[3] = USDS;
        t[4] = SUSDS;
        t[5] = EYE;
    }

    /// @dev The test's OWN per-step watch (independent of the script's invariant) closes every transaction of a
    ///      full broadcast-mode cutover and finds no OWNER credit at any step; the script's own invariant ran after
    ///      every one of them too.
    function test_fork_noSingleStepCreditsOwner_broadcastMode() public {
        if (!_fork()) return;
        string memory path = _tmp("ownerwatch");
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, path, address(0));
        s.watchOwner(_watched());
        s.run();
        assertGt(s.txCount(), 30, "full cutover ran");
        assertEq(s.stepsWatched(), s.txCount(), "the test watched every transaction");
        assertGe(s.ownerInvariantChecks(), s.txCount(), "the script asserted the invariant after every transaction");
        vm.removeFile(path);
    }

    /// @dev Same watch over a full PREVIEW (cutover + snapshot-reverted smoke).
    function test_fork_noSingleStepCreditsOwner_preview() public {
        if (!_fork()) return;
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(true, _tmp("ownerwatch-preview"), address(0));
        s.watchOwner(_watched());
        s.run();
        assertTrue(s.smokeRan(), "smoke ran");
        assertEq(s.stepsWatched(), s.txCount(), "the test watched every transaction");
    }

    /// @dev NEGATIVE: the rejected OWNER-transit Phase 4 (rescue to OWNER, collectNudge from OWNER next tx) nets to
    ///      zero by the end of the run, yet the script's per-step invariant refuses it at the rescue itself.
    function test_fork_ownerTransitPhase4_refusedByPerStepInvariant() public {
        if (!_fork()) return;
        uint256 usdcBal = IERC20(USDC).balanceOf(OLD_MINTER);
        (, uint256 usdcBuf,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(OLD_MINTER, USDC);
        uint256 ownerUsdc = IERC20(USDC).balanceOf(OWNER);
        string memory path = _tmp("transit");
        DeployNudgeDiscountOwnerTransitHarness s = new DeployNudgeDiscountOwnerTransitHarness(false, path, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                NudgeDiscountMainnetBase.OwnerBalanceIncreased.selector,
                USDC,
                uint256(0),
                ownerUsdc,
                ownerUsdc + usdcBal + usdcBuf
            )
        );
        s.run();
        if (vm.exists(path)) vm.removeFile(path);
    }

    /// @dev NEGATIVE for the test's own watch: it fails the same rejected design at the step that credits OWNER.
    function test_fork_ownerTransitPhase4_refusedByTestWatch() public {
        if (!_fork()) return;
        string memory path = _tmp("transit-watch");
        DeployNudgeDiscountOwnerTransitHarness s = new DeployNudgeDiscountOwnerTransitHarness(false, path, address(0));
        s.watchOwner(_watched());
        vm.expectRevert(bytes("TEST: step credited OWNER: REJECTED_old_rescueToOwner"));
        s.run();
        if (vm.exists(path)) vm.removeFile(path);
    }

    // ---------------- pot forwarder ----------------

    /// @dev A run interrupted between the rescue to the forwarder and its forward leaves the pot on the forwarder
    ///      (never on OWNER); the re-run finds the forwarder from chain state, forwards it, and finishes. The whole
    ///      old pot ends in the new stream and the forwarder is empty.
    function test_fork_forwarderInterruptedMidPhase4_resumeSweeps() public {
        if (!_fork()) return;
        uint256 oldUsdcPot = _oldPot(USDC);
        uint256 ownerUsdc = IERC20(USDC).balanceOf(OWNER);
        string memory path = _tmp("fwd-halt");
        DeployNudgeDiscountHarness first = new DeployNudgeDiscountHarness(false, path, address(0));
        first.setHaltAfterPotRescue(true);
        first.run();
        assertTrue(first.haltedMidPhase4(), "halted after the rescue");
        address f = first.potForwarder();
        assertEq(IERC20(USDC).balanceOf(f), oldUsdcPot, "the pot waits on the forwarder");
        assertEq(IERC20(USDC).balanceOf(OWNER), ownerUsdc, "never on OWNER");

        DeployNudgeDiscountHarness second = new DeployNudgeDiscountHarness(false, path, address(0));
        second.run();
        assertEq(second.potForwarder(), f, "same CREATE2 forwarder adopted");
        assertEq(IERC20(USDC).balanceOf(f), 0, "forwarder swept");
        (, uint256 newBuf,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(address(second.minter()), USDC);
        assertEq(newBuf, oldUsdcPot, "whole old pot in the new stream");
        assertEq(IERC20(USDC).balanceOf(OWNER), ownerUsdc, "OWNER untouched");

        DeployNudgeDiscountHarness third = new DeployNudgeDiscountHarness(false, path, address(0));
        third.run();
        assertEq(third.txCount(), 0, "finished: nothing to send");
        vm.removeFile(path);
    }

    /// @dev The forwarder is bound: only OWNER may call forward, only the three nudge tokens, nothing to forward
    ///      reverts, and its funds can only reach NudgeStreamer.collectNudge(new minter).
    function test_fork_forwarder_isBound() public {
        if (!_fork()) return;
        string memory path = _tmp("fwd-bound");
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, path, address(0));
        s.run();
        NudgePotForwarder f = NudgePotForwarder(s.potForwarder());
        assertEq(f.operator(), OWNER);
        assertEq(f.streamer(), NUDGE_STREAMER);
        assertEq(f.recipient(), address(s.minter()));

        address stranger = makeAddr("stranger");
        deal(USDC, address(f), 5e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(NudgePotForwarder.NudgePotForwarder__NotOperator.selector, stranger));
        f.forward(USDC);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(NudgePotForwarder.NudgePotForwarder__TokenNotBound.selector, USDS));
        f.forward(USDS);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(NudgePotForwarder.NudgePotForwarder__NothingToForward.selector, KENDU));
        f.forward(KENDU);

        uint256 ownerUsdc = IERC20(USDC).balanceOf(OWNER);
        (, uint256 buf0,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(address(s.minter()), USDC);
        vm.prank(OWNER);
        f.forward(USDC);
        (, uint256 buf1,,) = INudgeStreamerFork(NUDGE_STREAMER).streams(address(s.minter()), USDC);
        assertEq(buf1, buf0 + 5e6, "into the new minter's stream (no time elapsed, nothing settled)");
        assertEq(IERC20(USDC).balanceOf(OWNER), ownerUsdc, "OWNER untouched");
        assertEq(IERC20(USDC).balanceOf(address(f)), 0);
        vm.removeFile(path);
    }

    /// @dev The verifier fails while the forwarder still holds part of the pot.
    function test_fork_verifier_refusesFundedForwarder() public {
        if (!_fork()) return;
        string memory path = _tmp("fwd-verify");
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, path, address(0));
        s.run();
        _markCompleted(path);
        address m = address(s.minter());
        VerifyNudgeDiscountHarness v = new VerifyNudgeDiscountHarness(path, m);
        v.run();
        deal(USDC, s.potForwarder(), 1);
        vm.expectRevert(bytes("post: pot forwarder still holds a nudge token"));
        v.run();
        vm.removeFile(path);
    }
    // ---------------- story 135: ratchet shutdown + day-1 maxBoost 0 ----------------

    address constant NUDGE_RATCHET = 0x7E3fB41FD3E99312FBa8bfc71E79e635d526AA40;
    address constant RATCHET_NFT_STAKER = 0x299b0071DEf42D35eaf5ea24CC0a71Cf10655A64;
    address constant RATCHET_BATCH_MINTER = 0x81896F48a95AbeA255cd38a3010E985b6051A1C7;
    /// @dev A live RatchetNFTStaker staker at FORK_BLOCK (1 id-7 NFT staked), a plain EOA, not OWNER.
    address constant RATCHET_HOLDER = 0xc25cCd4896917E9e31925755cEd674cBD7214E1A;

    struct OwnerSnap {
        uint256 eth;
        uint256[6] erc20;
        uint256[] nft;
    }

    function _ownerSnap() internal view returns (OwnerSnap memory o) {
        o.eth = OWNER.balance;
        address[] memory t = _watched();
        for (uint256 i = 0; i < 6; i++) {
            o.erc20[i] = IERC20(t[i]).balanceOf(OWNER);
        }
        uint256 next = INFTMinterRatchetFork(NFT_MINTER).nextIndex();
        o.nft = new uint256[](next + 1);
        for (uint256 i = 0; i <= next; i++) {
            o.nft[i] = INFTMinterRatchetFork(NFT_MINTER).balanceOf(OWNER, i);
        }
    }

    function _assertOwnerUnchanged(OwnerSnap memory b, string memory stage) internal view {
        OwnerSnap memory a = _ownerSnap();
        assertLe(a.eth, b.eth, string.concat(stage, ": OWNER ETH non-increasing"));
        for (uint256 i = 0; i < 6; i++) {
            assertEq(a.erc20[i], b.erc20[i], string.concat(stage, ": OWNER ERC20 balance unchanged"));
        }
        assertEq(a.nft.length, b.nft.length);
        for (uint256 i = 0; i < a.nft.length; i++) {
            assertEq(a.nft[i], b.nft[i], string.concat(stage, ": OWNER ERC1155 balance unchanged"));
        }
    }

    function _expectDisabledMint(address actor) internal {
        (, uint256 p7,,) = INFTMinterRatchetFork(NFT_MINTER).configs(7);
        deal(USDC, actor, p7 * 4);
        vm.startPrank(actor);
        IERC20(USDC).approve(NFT_MINTER, p7 * 2);
        IERC20(USDC).approve(RATCHET_BATCH_MINTER, p7 * 2);
        vm.expectRevert(bytes("NFTMinterV2: dispatcher is disabled"));
        INFTMinterRatchetFork(NFT_MINTER).mint(7, actor);
        vm.expectRevert(bytes("NFTMinterV2: dispatcher is disabled"));
        IRatchetBatchMinterFork(RATCHET_BATCH_MINTER).batchMint(2, actor, p7 * 2, 0);
        vm.stopPrank();
        assertEq(INFTMinterRatchetFork(NFT_MINTER).balanceOf(actor, 7), 0, "no id-7 NFT minted");
    }

    /// @dev claim -> unstake everything -> re-stake everything for a live holder; returns the phUSD claimed.
    function _cycleRatchetHolder(address holder) internal returns (uint256 claimed) {
        IRatchetStakerFork st = IRatchetStakerFork(RATCHET_NFT_STAKER);
        (uint256 staked,) = st.users(holder);
        assertGt(staked, 0, "holder is staked");
        uint256 nft0 = INFTMinterRatchetFork(NFT_MINTER).balanceOf(holder, 7);
        uint256 ph0 = IERC20(PHUSD).balanceOf(holder);
        vm.startPrank(holder);
        st.claim();
        claimed = IERC20(PHUSD).balanceOf(holder) - ph0;
        st.unstake(staked);
        assertEq(INFTMinterRatchetFork(NFT_MINTER).balanceOf(holder, 7), nft0 + staked, "unstake returned the NFTs");
        INFTMinterRatchetFork(NFT_MINTER).setApprovalForAll(RATCHET_NFT_STAKER, true);
        st.stake(staked);
        vm.stopPrank();
        (uint256 after_,) = st.users(holder);
        assertEq(after_, staked, "re-staked");
        assertEq(INFTMinterRatchetFork(NFT_MINTER).balanceOf(holder, 7), nft0, "re-stake took the NFTs");
    }

    /// @dev A full broadcast-mode run disables index 7 (state-gated step `nm_disableRatchet`), ships maxBoost 0
    ///      (previewBoost() 0 even with an overflowing pot), leaves RatchetNFTStaker fully usable for a live holder
    ///      (also once its reward budget is exhausted), and never changes an OWNER balance.
    function test_fork_story135_ratchetDisabled_maxBoostZero_stakingIntact() public {
        if (!_fork()) return;
        OwnerSnap memory o0 = _ownerSnap();
        (address d7,,, bool dis0) = INFTMinterRatchetFork(NFT_MINTER).configs(7);
        assertEq(d7, NUDGE_RATCHET, "fork: index 7 is the NudgeRatchet");
        assertFalse(dis0, "fork: ratchet minting is open before the cutover");

        string memory path = _tmp("story135");
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, path, address(0));
        s.run();
        BatchNFTMinterNudgeDiscount m = s.minter();

        // index 7 disabled; the step was recorded; price/growth/dispatcher untouched.
        (address d7b,,, bool dis1) = INFTMinterRatchetFork(NFT_MINTER).configs(7);
        assertTrue(dis1, "configs(7).disabled after the cutover");
        assertEq(d7b, NUDGE_RATCHET, "dispatcher untouched");
        string[] memory steps = vm.parseJsonStringArray(vm.readFile(path), ".configSteps");
        uint256 seen;
        for (uint256 i = 0; i < steps.length; i++) {
            if (keccak256(bytes(steps[i])) == keccak256("nm_disableRatchet")) seen++;
        }
        assertEq(seen, 1, "nm_disableRatchet sent exactly once");
        _assertOwnerUnchanged(o0, "after the cutover");

        // mint(7) and RatchetBatchNFTMinter.batchMint revert.
        _expectDisabledMint(makeAddr("story135-ratchet-minter"));

        // maxBoost 0: previewBoost() is 0 even with a pot overflowing the cap.
        assertEq(m.maxBoost(), 0, "day-1 maxBoost 0");
        (, uint256 p0,,) = INFTMinterRatchetFork(NFT_MINTER).configs(4);
        uint256 freeEq = m.maxFreePerBatch() + m.overflowNFTsPerBoostPoint() * 20;
        address donor = makeAddr("story135-donor");
        uint256 amt = (freeEq * p0 * 101) / 100 / 1e12 + 1;
        deal(USDC, donor, amt);
        vm.startPrank(donor);
        IERC20(USDC).approve(NUDGE_STREAMER, amt);
        INudgeStreamerCollectFork(NUDGE_STREAMER).collectNudge(address(m), USDC, amt);
        vm.stopPrank();
        vm.warp(block.timestamp + 31 days); // past the 30-day USDC stream window
        (uint256 overflowFree, uint8 boost, uint8 eff,) = m.previewBoost();
        assertGt(overflowFree, 0, "pot overflows the cap");
        assertEq(boost, 0, "previewBoost() boost 0 with maxBoost 0");
        assertEq(eff, m.discountPercent(), "effective discount == base discount");

        // RatchetNFTStaker: a live holder claims, unstakes and re-stakes.
        _cycleRatchetHolder(RATCHET_HOLDER);

        // Budget exhausted (no new hook debt once minting stops): warp far past the runway; exits still work.
        vm.warp(block.timestamp + IRatchetStakerFork(RATCHET_NFT_STAKER).runwaySeconds() + 3650 days);
        _cycleRatchetHolder(RATCHET_HOLDER);
        vm.startPrank(RATCHET_HOLDER);
        IRatchetStakerFork(RATCHET_NFT_STAKER).claim();
        (uint256 staked,) = IRatchetStakerFork(RATCHET_NFT_STAKER).users(RATCHET_HOLDER);
        IRatchetStakerFork(RATCHET_NFT_STAKER).unstake(staked);
        vm.stopPrank();
        (uint256 left,) = IRatchetStakerFork(RATCHET_NFT_STAKER).users(RATCHET_HOLDER);
        assertEq(left, 0, "exhausted budget: unstake still returns the position");

        _assertOwnerUnchanged(o0, "end");

        // The verifier asserts the ratchet disable too.
        _markCompleted(path);
        VerifyNudgeDiscountHarness v = new VerifyNudgeDiscountHarness(path, address(m));
        v.run();
        vm.prank(OWNER);
        INFTMinterRatchetFork(NFT_MINTER).setDispatcherDisabled(7, false);
        vm.expectRevert(bytes("post: NFTMinter configs(7).disabled is false - ratchet minting is still open"));
        v.run();
        vm.removeFile(path);
    }

    /// @dev Index 7 already disabled (e.g. a resumed run): the step is skipped, nothing else changes.
    function test_fork_story135_alreadyDisabled_skipsStep() public {
        if (!_fork()) return;
        vm.prank(OWNER);
        INFTMinterRatchetFork(NFT_MINTER).setDispatcherDisabled(7, true);
        string memory path = _tmp("story135-skip");
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, path, address(0));
        s.run();
        string[] memory steps = vm.parseJsonStringArray(vm.readFile(path), ".configSteps");
        for (uint256 i = 0; i < steps.length; i++) {
            assertTrue(keccak256(bytes(steps[i])) != keccak256("nm_disableRatchet"), "no disable tx when disabled");
        }
        (,,, bool dis) = INFTMinterRatchetFork(NFT_MINTER).configs(7);
        assertTrue(dis);
        vm.removeFile(path);
    }

    /// @dev Refuses (in preflight, before any transaction) when index 7 is not the NudgeRatchet.
    function test_fork_story135_refuses_index7NotNudgeRatchet() public {
        if (!_fork()) return;
        address impostor = makeAddr("story135-impostor-dispatcher");
        vm.etch(impostor, hex"00");
        vm.prank(OWNER);
        INFTMinterRatchetFork(NFT_MINTER).replaceDispatcher(7, impostor);
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(true, _tmp("story135-impostor"), address(0));
        vm.expectRevert(bytes("ratchet: NFTMinter configs(7).dispatcher != NudgeRatchet - refusing to disable"));
        s.run();
    }
}
