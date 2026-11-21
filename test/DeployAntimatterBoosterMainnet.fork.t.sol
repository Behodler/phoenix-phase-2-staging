// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlax} from "@phUSD/IFlax.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {AntimatterBooster} from "antimatter/AntimatterBooster.sol";
import {DeployAntimatterBoosterMainnet} from "../script/DeployAntimatterBoosterMainnet.s.sol";
import {VerifyAntimatterBoosterMainnet} from "../script/VerifyAntimatterBoosterMainnet.s.sol";
import {VerifyPauserV2Migration} from "../script/VerifyPauserV2Migration.s.sol";
import {AntimatterBoosterMainnetBase} from "../script/helpers/AntimatterBoosterMainnetBase.sol";
import {CutoverStableStakerV2Mainnet} from "../script/CutoverStableStakerV2Mainnet.s.sol";

interface IPhUSDFork {
    function authorizedMinters(address m) external view returns (bool canMint, uint256 version);
    function setMinter(address m, bool canMint) external;
    function mintVersion() external view returns (uint256);
    function mint(address recipient, uint256 amount) external;
}

interface IPauserV2Fork {
    function isRegistered(address c) external view returns (bool);
    function register(address c) external;
    function unregister(address c) external;
}

/// @dev Pins the mode, the progress path, the book file / booster value and the sender (never the process-wide env,
///      which races parallel suites, and never the real progress file). "Broadcast" mode sends as an OWNER prank: a
///      forge test cannot sign with the Ledger; what is under test is the state gating and the progress file.
contract DeployAntimatterBoosterHarness is DeployAntimatterBoosterMainnet {
    bool internal immutable preview;
    string internal progressPath;
    address internal booked;
    string internal bookPath;
    address internal sender;

    bool public creditOwnerAfterTx;
    address public faultRevokeMinter; // revoke this address's phUSD mint right after the first tx
    address public faultGrantMinter; // grant this address a phUSD mint right after the first tx

    constructor(bool preview_, string memory progressPath_, address booked_) {
        preview = preview_;
        progressPath = progressPath_;
        booked = booked_;
        bookPath = BOOK_FILE;
        sender = OWNER;
    }

    function setCreditOwnerAfterTx(bool v) external {
        creditOwnerAfterTx = v;
    }

    function setFaultRevoke(address a) external {
        faultRevokeMinter = a;
    }

    function setFaultGrant(address a) external {
        faultGrantMinter = a;
    }

    function setBookPath(string memory p) external {
        bookPath = p;
    }

    function setSender(address s) external {
        sender = s;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookBooster() internal view override returns (address) {
        return booked;
    }

    function _bookFile() internal view override returns (string memory) {
        return bookPath;
    }

    function _sender() internal view override returns (address) {
        return sender;
    }

    function _progressWriteEnabledFromEnv() internal pure override returns (bool) {
        return true;
    }

    function _requireBroadcastGasPriceHeadroom() internal view override {}

    function _begin() internal override {
        txCount++;
        vm.startPrank(OWNER);
    }

    function _stop() internal override {
        vm.stopPrank();
    }

    function _afterTx() internal override {
        if (creditOwnerAfterTx) deal(ANTIMATTER, OWNER, IERC20(ANTIMATTER).balanceOf(OWNER) + 1);
        if (faultRevokeMinter != address(0)) {
            vm.prank(OWNER);
            IPhUSDFork(PHUSD).setMinter(faultRevokeMinter, false);
            faultRevokeMinter = address(0);
        }
        if (faultGrantMinter != address(0)) {
            vm.prank(OWNER);
            IPhUSDFork(PHUSD).setMinter(faultGrantMinter, true);
            faultGrantMinter = address(0);
        }
    }
}

contract VerifyAntimatterBoosterHarness is VerifyAntimatterBoosterMainnet {
    string internal progressPath;
    address internal booked;

    constructor(string memory progressPath_, address booked_) {
        progressPath = progressPath_;
        booked = booked_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookBooster() internal view override returns (address) {
        return booked;
    }
}

/// @dev `pauser-v2-verify` with the booster appended to postMigrationAdditions(), as the patcher will commit it.
contract VerifyPauserV2WithBooster is VerifyPauserV2Migration {
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

/// @dev The stable-staker-v2 cutover's two-sided phUSD minter delta, against the REAL persisted baseline (511).
contract SSV2MinterDeltaHarness is CutoverStableStakerV2Mainnet {
    function loadAndAssertDelta() external {
        _loadProgressFile();
        require(phusdBaselineRecorded, "harness: no persisted baseline");
        _assertPhusdMinterDelta(true);
    }
}

contract AntimatterBoosterBookHarness is AntimatterBoosterMainnetBase {
    function checkBook() external view {
        _requireBookMatchesConstants();
    }

    function bookKey(string memory key) external view returns (address) {
        return _bookAddress(vm.readFile(BOOK_FILE), key);
    }

    function hasBoosterKey() external view returns (bool) {
        return vm.indexOf(vm.readFile(BOOK_FILE), "\n  AntimatterBooster: \"") != type(uint256).max;
    }

    function boostBps() external pure returns (uint256) {
        return BOOST_BPS;
    }
}

/**
 * @title AntimatterBoosterMainnetConfigTest  (story 139) - no RPC needed
 * @notice Pinned constants equal the book; the book reader matches whole keys only; BOOST_BPS is 1_500.
 *         Deliberately does NOT assert the book's AntimatterBooster value: the patcher fills it post-broadcast.
 */
contract AntimatterBoosterMainnetConfigTest is Test {
    function test_bookMatchesPinnedConstants() public {
        AntimatterBoosterBookHarness h = new AntimatterBoosterBookHarness();
        h.checkBook();
        assertTrue(h.hasBoosterKey(), "book has an AntimatterBooster key");
        assertEq(h.boostBps(), 1_500, "15% boost");
        assertEq(h.bookKey("USDC"), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "whole-key USDC (not AutoUSDC)");
        assertEq(h.bookKey("NoSuchKey"), address(0), "absent key reads zero");
    }
}

/**
 * @title DeployAntimatterBoosterMainnetForkTest  (story 139, sprint antimatter-boost)
 * @notice Mainnet-fork rehearsal of the booster cutover against the LIVE phUSD, Antimatter, PhusdStableMinter V2
 *         and PauserV2: wiring order (boostBps fifth, OWNER revoke last), idempotent re-run, resume after an
 *         interrupt at every step, refusals, the no-funds-to-Ledger invariant (per tx), the minter-set integrity
 *         assert, the 15% smoke, OWNER unable to mint afterwards, the read-only verifier, pauser-v2-verify with the
 *         booster appended, and the stable-staker-v2 minter delta tolerating the OWNER revoke.
 *         Skipped without RPC_MAINNET.
 */
contract DeployAntimatterBoosterMainnetForkTest is Test {
    uint256 constant FORK_BLOCK = 26_466_600;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    address constant PAUSER_V2 = 0x669Ebfa5309db66683c199Cfe22516DECBe1a154;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant HOOK_EYE = 0x0F05c34d458dd8953864a56857a2bb67ecb22683;
    address constant MINTER_V1 = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant BATCH_MINTER_RETIRED = 0x068395556b8c43eDf257DC54D109EA5910aE15c7;
    string constant TMP_PREFIX = "server/deployments/progress.antimatter-booster.1.forktest-";

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
                '","contracts":{"AntimatterBooster":{"address":"',
                vm.toString(b),
                '","createNonce":0,"deployed":true}}}'
            )
        );
    }

    function _markCompleted(string memory path) internal {
        address b = vm.parseJsonAddress(vm.readFile(path), ".contracts.AntimatterBooster.address");
        _writeProgress(path, b, "completed");
    }

    function _ownerCanMint() internal view returns (bool c) {
        (c,) = IPhUSDFork(PHUSD).authorizedMinters(OWNER);
    }

    function _isLive(address a) internal view returns (bool) {
        (bool c, uint256 v) = IPhUSDFork(PHUSD).authorizedMinters(a);
        return c && v == IPhUSDFork(PHUSD).mintVersion();
    }

    function _assertWired(AntimatterBooster b) internal view {
        assertEq(b.owner(), OWNER, "owner");
        assertEq(address(b.antimatter()), ANTIMATTER, "antimatter");
        assertEq(address(b.phUSD()), PHUSD, "phUSD");
        assertEq(b.boostBps(), 1_500, "15%");
        assertEq(b.pauser(), PAUSER_V2, "pauser");
        assertTrue(IPauserV2Fork(PAUSER_V2).isRegistered(address(b)), "registered");
        assertFalse(b.paused(), "not paused");
        assertEq(b.trackedStables().length, 3, "3 stables");
        assertTrue(b.isTracked(DOLA) && b.isTracked(USDC) && b.isTracked(USDE), "DOLA/USDC/USDe tracked");
        assertTrue(_isLive(address(b)), "booster live minter");
        assertFalse(_ownerCanMint(), "OWNER revoked");
        assertEq(IPhUSDFork(PHUSD).mintVersion(), 0, "mintVersion untouched");
    }

    /// @dev Order read off the logs: phUSD MinterSet(booster) -> TrackedStableAdded -> PauserChanged -> PauserV2
    ///      ContractRegistered -> BoostBpsChanged (FIFTH) -> phUSD MinterSet(OWNER, false) (LAST).
    function _assertWiringOrder(address b, Vm.Log[] memory logs) internal pure {
        bytes32 minterSet = keccak256("MinterSet(address,bool,uint256)");
        bytes32 tracked = keccak256("TrackedStableAdded(address)");
        bytes32 pauserChanged = keccak256("PauserChanged(address,address)");
        bytes32 registered = keccak256("ContractRegistered(address)");
        bytes32 boostSet = keccak256("BoostBpsChanged(uint256,uint256)");
        uint256 none = type(uint256).max;
        uint256[6] memory at = [none, none, none, none, none, none];
        uint256 lastWiringLog;
        for (uint256 i = 0; i < logs.length; i++) {
            address e = logs[i].emitter;
            bytes32 t = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            bytes32 t1 = logs[i].topics.length > 1 ? logs[i].topics[1] : bytes32(0);
            bool hit;
            if (e == PHUSD && t == minterSet && t1 == bytes32(uint256(uint160(b))) && at[0] == none) {
                at[0] = i;
                hit = true;
            } else if (e == b && t == tracked && at[1] == none) {
                at[1] = i;
                hit = true;
            } else if (e == b && t == pauserChanged && at[2] == none) {
                at[2] = i;
                hit = true;
            } else if (e == PAUSER_V2 && t == registered && at[3] == none) {
                at[3] = i;
                hit = true;
            } else if (e == b && t == boostSet && at[4] == none) {
                at[4] = i;
                hit = true;
            } else if (e == PHUSD && t == minterSet && t1 == bytes32(uint256(uint160(OWNER))) && at[5] == none) {
                at[5] = i;
                hit = true;
            }
            if (hit) lastWiringLog = i;
        }
        for (uint256 k = 0; k < 6; k++) {
            require(at[k] != none, "wiring step emitted no log");
            if (k > 0) require(at[k - 1] < at[k], "wiring steps out of order");
        }
        require(lastWiringLog == at[5], "OWNER revoke must be the last wiring step");
    }

    // ---------------- preview ----------------

    function test_fork_preview_wiresInOrder_smokes15pct_writesNoProgress() public {
        if (!_fork()) return;
        string memory path = _tmp("preview");
        uint256 amBefore = IERC20(ANTIMATTER).balanceOf(OWNER);
        uint256 phBefore = IERC20(PHUSD).balanceOf(OWNER);
        uint256 usdeBefore = IERC20(USDE).balanceOf(OWNER);
        uint256 ethBefore = OWNER.balance;
        assertTrue(_ownerCanMint(), "precondition: OWNER is a phUSD minter at the fork block");

        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, path, address(0));
        vm.recordLogs();
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        _assertWiringOrder(address(s.booster()), vm.getRecordedLogs());
        assertEq(s.txCount(), 9, "deploy + 8 wiring txs");
        _assertWired(s.booster());
        assertFalse(vm.exists(path), "preview must not write the progress file");

        // 15% smoke: 10 AM + 10 USDe -> base 20 phUSD, bonus 3 phUSD.
        assertTrue(s.usdeEligible(), "USDe eligible at the fork block");
        assertEq(s.smokeBase(), 20e18, "base = 10 AM + 10 USDe");
        assertEq(s.smokeBonus(), s.smokeBase() * 1_500 / 10_000, "bonus = 15% of base");
        assertEq(s.smokeBonus(), 3e18, "bonus = 3 phUSD");
        assertEq(s.smokeReceived(), s.smokeBase() + s.smokeBonus(), "received = base + bonus");

        assertEq(IERC20(ANTIMATTER).balanceOf(OWNER), amBefore, "OWNER AM unchanged");
        assertEq(IERC20(PHUSD).balanceOf(OWNER), phBefore, "OWNER phUSD unchanged");
        assertEq(IERC20(USDE).balanceOf(OWNER), usdeBefore, "OWNER USDe unchanged");
        assertLe(OWNER.balance, ethBefore, "OWNER ETH non-increasing");
    }

    /// @dev After wiring OWNER can no longer mint phUSD. The mint targets a throwaway recipient (never OWNER), and
    ///      OWNER's balances are asserted unchanged anyway.
    function test_fork_ownerCannotMintAfterWiring() public {
        if (!_fork()) return;
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, _tmp("ownermint"), address(0));
        s.run();
        uint256 phBefore = IERC20(PHUSD).balanceOf(OWNER);
        address someone = makeAddr("story139-mint-target");
        vm.prank(OWNER);
        vm.expectRevert();
        IPhUSDFork(PHUSD).mint(someone, 1e18);
        assertEq(IERC20(PHUSD).balanceOf(someone), 0, "nothing minted");
        assertEq(IERC20(PHUSD).balanceOf(OWNER), phBefore, "OWNER phUSD unchanged");
        // OWNER keeps its onlyOwner powers over phUSD (the documented rollback works).
        vm.prank(OWNER);
        IPhUSDFork(PHUSD).setMinter(OWNER, true);
        assertTrue(_ownerCanMint(), "rollback: OWNER re-granted");
    }

    // ---------------- broadcast mode: progress, idempotent re-run, verifiers ----------------

    function test_fork_broadcastMode_writesPending_rerunIsNoop_verifiersPass() public {
        if (!_fork()) return;
        string memory path = _tmp("broadcast");
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(false, path, address(0));
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        assertEq(s.txCount(), 9, "deploy + 8 wiring txs");
        AntimatterBooster b = s.booster();
        _assertWired(b);
        assertEq(s.smokeBase(), 0, "no smoke outside preview");

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1, "chainId");
        assertEq(vm.parseJsonString(json, ".networkName"), "mainnet", "networkName");
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "pending", "pending until confirmed");
        assertEq(vm.parseJsonAddress(json, ".contracts.AntimatterBooster.address"), address(b), "address");
        assertTrue(vm.keyExistsJson(json, ".contracts.AntimatterBooster.createNonce"), "createNonce recorded");
        assertFalse(vm.parseJsonBool(json, ".contracts.AntimatterBooster.deployed"), "deployed=false until confirmed");

        DeployAntimatterBoosterHarness again = new DeployAntimatterBoosterHarness(false, path, address(0));
        again.run();
        assertFalse(again.deployedThisRun(), "re-run must not deploy");
        assertEq(again.txCount(), 0, "re-run sends nothing");
        assertEq(address(again.booster()), address(b), "adopted");
        DeployAntimatterBoosterHarness patched = new DeployAntimatterBoosterHarness(false, path, address(b));
        patched.run();
        assertEq(patched.txCount(), 0, "re-run after patch sends nothing");

        VerifyAntimatterBoosterHarness v = new VerifyAntimatterBoosterHarness(path, address(b));
        vm.expectRevert(bytes("verify: progress.antimatter-booster.1.json is not completed - run the confirm step"));
        v.run();
        _markCompleted(path);
        v.run();
        VerifyAntimatterBoosterHarness unpatched = new VerifyAntimatterBoosterHarness(path, address(0));
        vm.expectRevert(
            bytes(
                "verify: address book AntimatterBooster != booster - run node scripts/patch-mainnet-addresses-antimatter-booster.js"
            )
        );
        unpatched.run();

        // PRE-EXISTING mainnet state (not this story's): BatchNFTMinterMultiToken 0x0683...15c7 is committed to
        // PauserV2Registry.postMigrationRemovals() by story 119 but is still registered on PauserV2 at the fork
        // block, so the live `pauser-v2-verify` fails on it regardless of the booster. Model the pending retirement
        // (PauserV2.unregister is unconditional) so this test isolates the booster's own registry entry.
        if (IPauserV2Fork(PAUSER_V2).isRegistered(BATCH_MINTER_RETIRED)) {
            vm.prank(OWNER);
            IPauserV2Fork(PAUSER_V2).unregister(BATCH_MINTER_RETIRED);
        }
        VerifyPauserV2WithBooster pv = new VerifyPauserV2WithBooster();
        vm.expectRevert(
            bytes("verify: PauserV2 holds an address that is neither live nor a committed addition - see the log above")
        );
        pv.run();
        pv.add(address(b));
        pv.run();

        vm.removeFile(path);
    }

    function test_fork_verifier_passesAfterPreviewWiring_andRejectsOwnerReGrant() public {
        if (!_fork()) return;
        string memory path = _tmp("verifypreview");
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, path, address(0));
        s.run();
        address b = address(s.booster());
        _writeProgress(path, b, "completed");
        VerifyAntimatterBoosterHarness v = new VerifyAntimatterBoosterHarness(path, b);
        v.run();

        vm.prank(OWNER);
        IPhUSDFork(PHUSD).setMinter(OWNER, true);
        vm.expectRevert(bytes("verify: OWNER is still a phUSD minter"));
        v.run();
        vm.prank(OWNER);
        IPhUSDFork(PHUSD).setMinter(OWNER, false);

        vm.prank(OWNER);
        AntimatterBooster(b).setBoostBps(0);
        vm.expectRevert(bytes("verify: boostBps != 1_500"));
        v.run();
        vm.removeFile(path);
    }

    // ---------------- resume after an interrupt at each step ----------------

    /// @dev Performs the first `k` wiring steps by hand (1 = minter grant, 2 = stables, 3 = setPauser, 4 = register,
    ///      5 = boost), then resumes with the script; `expectedTx` remaining txs.
    function _resumeAfter(uint256 k, uint256 expectedTx) internal {
        string memory path = _tmp(string.concat("resume", vm.toString(k)));
        vm.startPrank(OWNER);
        AntimatterBooster b = new AntimatterBooster(OWNER, Antimatter(ANTIMATTER), IFlax(PHUSD));
        if (k >= 1) IPhUSDFork(PHUSD).setMinter(address(b), true);
        if (k >= 2) {
            b.addTrackedStable(DOLA);
            b.addTrackedStable(USDC);
            b.addTrackedStable(USDE);
        }
        if (k >= 3) b.setPauser(PAUSER_V2);
        if (k >= 4) IPauserV2Fork(PAUSER_V2).register(address(b));
        if (k >= 5) b.setBoostBps(1_500);
        vm.stopPrank();
        _writeProgress(path, address(b), "pending");

        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(false, path, address(0));
        s.run();
        assertFalse(s.deployedThisRun(), "adopted, not redeployed");
        assertEq(s.txCount(), expectedTx, "remaining txs only");
        _assertWired(b);
        vm.removeFile(path);
    }

    function test_fork_resume_afterDeployOnly() public {
        if (!_fork()) return;
        _resumeAfter(0, 8);
    }

    function test_fork_resume_afterMinterGrant() public {
        if (!_fork()) return;
        _resumeAfter(1, 7);
    }

    function test_fork_resume_afterStables() public {
        if (!_fork()) return;
        _resumeAfter(2, 4);
    }

    function test_fork_resume_afterSetPauser() public {
        if (!_fork()) return;
        _resumeAfter(3, 3);
    }

    function test_fork_resume_afterRegister() public {
        if (!_fork()) return;
        _resumeAfter(4, 2);
    }

    /// @dev Interrupted AT the revoke: steps 1-5 done, OWNER still a minter. The resume sends exactly the revoke, and
    ///      the minter-set assert accepts the booster as "already changed before this run".
    function test_fork_resume_interruptedAtRevoke() public {
        if (!_fork()) return;
        assertTrue(_ownerCanMint(), "precondition");
        _resumeAfter(5, 1);
    }

    function test_fork_resume_partialStables() public {
        if (!_fork()) return;
        string memory path = _tmp("resumepartial");
        vm.startPrank(OWNER);
        AntimatterBooster b = new AntimatterBooster(OWNER, Antimatter(ANTIMATTER), IFlax(PHUSD));
        IPhUSDFork(PHUSD).setMinter(address(b), true);
        b.addTrackedStable(DOLA);
        vm.stopPrank();
        _writeProgress(path, address(b), "pending");
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(false, path, address(0));
        s.run();
        assertEq(s.txCount(), 6, "USDC, USDe, setPauser, register, boost, revoke");
        _assertWired(b);
        vm.removeFile(path);
    }

    // ---------------- refusals ----------------

    function test_fork_refuses_wrongChain() public {
        if (!_fork()) return;
        vm.chainId(5);
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, _tmp("chain"), address(0));
        vm.expectRevert(bytes("Wrong chain ID - expected Mainnet (1)"));
        s.run();
    }

    function test_fork_refuses_wrongSender() public {
        if (!_fork()) return;
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(false, _tmp("sender"), address(0));
        s.setSender(makeAddr("notOwner"));
        vm.expectRevert(bytes("broadcast sender must be OWNER (--sender + Ledger)"));
        s.run();
    }

    function test_fork_refuses_bookMismatch() public {
        if (!_fork()) return;
        string memory scratchBook = "server/deployments/mainnet-addresses.forktest-story139.ts";
        string memory book = vm.readFile("server/deployments/mainnet-addresses.ts");
        string memory bad = vm.replace(
            book,
            'PhusdStableMinter: "0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C"',
            'PhusdStableMinter: "0x435B0A1884bd0fb5667677C9eb0e59425b1477E5"'
        );
        vm.writeFile(scratchBook, bad);
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, _tmp("book"), address(0));
        s.setBookPath(scratchBook);
        vm.expectRevert(bytes("address book PhusdStableMinter != pinned active minter (V2)"));
        s.run();
        vm.removeFile(scratchBook);
    }

    function test_fork_refuses_antimatterMinterNotBookMinter() public {
        if (!_fork()) return;
        vm.mockCall(ANTIMATTER, abi.encodeWithSignature("phUSDMinter()"), abi.encode(MINTER_V1));
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, _tmp("minter"), address(0));
        vm.expectRevert(bytes("preflight: Antimatter.phUSDMinter() != book PhusdStableMinter (V2)"));
        s.run();
    }

    function test_fork_refuses_bookFilledWithoutProgress() public {
        if (!_fork()) return;
        DeployAntimatterBoosterHarness s =
            new DeployAntimatterBoosterHarness(true, _tmp("filledbook"), makeAddr("someBooster"));
        vm.expectRevert(
            bytes(
                "address book names an AntimatterBooster but there is no progress file - restore progress.antimatter-booster.1.json"
            )
        );
        s.run();
    }

    function test_fork_refuses_progressWithoutCode_nonceConsumed() public {
        if (!_fork()) return;
        string memory path = _tmp("nocode");
        _writeProgress(path, makeAddr("ghostBooster"), "pending"); // createNonce 0, long consumed by OWNER
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(false, path, address(0));
        vm.expectRevert();
        s.run();
        vm.removeFile(path);
    }

    // ---------------- no funds to the Ledger (per tx) ----------------

    /// @dev The fault fires after the FIRST transaction (the deploy), proving the assert runs per tx, not just at the end.
    function test_fork_ownerBalanceIncrease_revertsByName_afterFirstTx() public {
        if (!_fork()) return;
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(false, _tmp("credit"), address(0));
        s.setCreditOwnerAfterTx(true);
        uint256 before = IERC20(ANTIMATTER).balanceOf(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                AntimatterBoosterMainnetBase.OwnerBalanceIncreased.selector, ANTIMATTER, before, before + 1
            )
        );
        s.run();
        _tmp("credit");
    }

    // ---------------- minter-set integrity ----------------

    function test_fork_minterSet_unexpectedRevoke_revertsByName() public {
        if (!_fork()) return;
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, _tmp("revoke"), address(0));
        s.setFaultRevoke(HOOK_EYE);
        vm.expectRevert(
            abi.encodeWithSelector(
                AntimatterBoosterMainnetBase.MinterSetChanged.selector, HOOK_EYE, true, uint256(0), false, uint256(0)
            )
        );
        s.run();
    }

    function test_fork_minterSet_unexpectedGrant_revertsByName() public {
        if (!_fork()) return;
        (bool c0, uint256 v0) = IPhUSDFork(PHUSD).authorizedMinters(MINTER_V1);
        assertFalse(c0, "precondition: V1 minter revoked");
        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, _tmp("grant"), address(0));
        s.setFaultGrant(MINTER_V1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AntimatterBoosterMainnetBase.MinterSetChanged.selector, MINTER_V1, false, v0, true, uint256(0)
            )
        );
        s.run();
    }

    // ---------------- stable-staker-v2 cutover minter delta (story 139 amendment) ----------------

    function test_fork_ssv2MinterDelta_passesBeforeAndAfterOwnerRevoke() public {
        if (!_fork()) return;
        SSV2MinterDeltaHarness h = new SSV2MinterDeltaHarness();
        h.loadAndAssertDelta(); // live mask 510: OWNER still a minter

        DeployAntimatterBoosterHarness s = new DeployAntimatterBoosterHarness(true, _tmp("ssv2"), address(0));
        s.run();
        assertFalse(_ownerCanMint(), "OWNER revoked by the booster cutover");
        SSV2MinterDeltaHarness h2 = new SSV2MinterDeltaHarness();
        h2.loadAndAssertDelta(); // live mask 508: OWNER bit tolerated
    }

    function test_fork_ssv2MinterDelta_stillRejectsOtherChanges() public {
        if (!_fork()) return;
        // OWNER revoked AND another candidate (HOOK_EYE, bit 4) revoked -> reject.
        vm.startPrank(OWNER);
        IPhUSDFork(PHUSD).setMinter(OWNER, false);
        IPhUSDFork(PHUSD).setMinter(HOOK_EYE, false);
        vm.stopPrank();
        SSV2MinterDeltaHarness h = new SSV2MinterDeltaHarness();
        vm.expectRevert(bytes("minter-delta: phUSD minter candidate set changed beyond the expected V1 revoke"));
        h.loadAndAssertDelta();

        // Only HOOK_EYE revoked (OWNER re-granted) -> reject.
        vm.prank(OWNER);
        IPhUSDFork(PHUSD).setMinter(OWNER, true);
        SSV2MinterDeltaHarness h2 = new SSV2MinterDeltaHarness();
        vm.expectRevert(bytes("minter-delta: phUSD minter candidate set changed beyond the expected V1 revoke"));
        h2.loadAndAssertDelta();

        // HOOK_EYE restored, V1 staker (bit 0) re-granted -> reject, with or without the OWNER revoke.
        vm.startPrank(OWNER);
        IPhUSDFork(PHUSD).setMinter(HOOK_EYE, true);
        IPhUSDFork(PHUSD).setMinter(0xbce8ABC09BaEDCabE93419bF875f6186e182079A, true);
        IPhUSDFork(PHUSD).setMinter(OWNER, false);
        vm.stopPrank();
        SSV2MinterDeltaHarness h3 = new SSV2MinterDeltaHarness();
        vm.expectRevert(bytes("minter-delta: phUSD minter candidate set changed beyond the expected V1 revoke"));
        h3.loadAndAssertDelta();
    }
}
