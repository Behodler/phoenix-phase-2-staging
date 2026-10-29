// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {BalancerLPMigrator} from "../src/periphery/BalancerLPMigrator.sol";
import {
    DeployBalancerLPMigratorMainnet,
    BalancerLPMigratorMainnetBase
} from "../script/DeployBalancerLPMigratorMainnet.s.sol";
import {VerifyBalancerLPMigrator} from "../script/VerifyBalancerLPMigrator.s.sol";

/// @dev Pins the mode, the progress path and the address-book `BalancerLPMigrator` value (never the process-wide
///      PREVIEW_MODE env, which races parallel suites, and never the real progress file).
contract DeployBalancerLPMigratorHarness is DeployBalancerLPMigratorMainnet {
    bool internal immutable preview;
    string internal progressPath;
    address internal booked;

    constructor(bool preview_, string memory progressPath_, address booked_) {
        preview = preview_;
        progressPath = progressPath_;
        booked = booked_;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookMigrator() internal view override returns (address) {
        return booked;
    }
}

contract VerifyBalancerLPMigratorHarness is VerifyBalancerLPMigrator {
    string internal progressPath;
    address internal booked;

    constructor(string memory progressPath_, address booked_) {
        progressPath = progressPath_;
        booked = booked_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookMigrator() internal view override returns (address) {
        return booked;
    }
}

/// @dev Exposes the real address-book readers for the no-RPC test.
contract BalancerLPMigratorBookHarness is BalancerLPMigratorMainnetBase {
    function bookAddress(string memory key) external view returns (address) {
        return _bookAddress(vm.readFile(ADDRESS_BOOK), key);
    }

    function bookMigrator() external view returns (address) {
        return _bookMigrator();
    }
}

/// @dev Story 121's address table, written out independently of the script so a drift in either the address
///      book or the script's constants fails here.
abstract contract Story121Table {
    address constant VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address constant V3_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address constant POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address constant UNI_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant PAIR = 0x0b96b8ab66d40ba3C7501aa8C28Cdc37688F6F7f;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
}

/**
 * @title DeployBalancerLPMigratorMainnetConfigTest  (story 121)
 * @notice No RPC needed: the deploy's inputs (address-book keys plus the Balancer constants) equal story 121's
 *         table, and the book's `BalancerLPMigrator` key exists and is still the zero placeholder.
 */
contract DeployBalancerLPMigratorMainnetConfigTest is Test, Story121Table {
    function test_expectedConfig_matchesStoryTable() public {
        DeployBalancerLPMigratorMainnet s = new DeployBalancerLPMigratorMainnet();
        BalancerLPMigratorMainnetBase.MigratorConfig memory c = s.expectedConfig();
        assertEq(c.vault, VAULT, "vault");
        assertEq(c.v3Router, V3_ROUTER, "v3Router");
        assertEq(c.pool, POOL, "pool");
        assertEq(c.uniRouter, UNI_ROUTER, "uniRouter");
        assertEq(c.sUSDS, SUSDS, "sUSDS");
        assertEq(c.phUSD, PHUSD, "phUSD");
        assertEq(c.pair, PAIR, "pair");
        assertEq(s.OWNER(), OWNER, "OWNER");
        assertEq(s.PROGRESS_FILE(), "server/deployments/progress.balancer-lp-migrator.1.json", "progress file");
    }

    function test_bookKey_isZeroPlaceholder() public {
        BalancerLPMigratorBookHarness b = new BalancerLPMigratorBookHarness();
        // Absent would revert; present and zero until the human broadcasts and the patcher fills it.
        assertEq(b.bookMigrator(), address(0), "BalancerLPMigrator is the zero placeholder");
        assertEq(b.bookAddress("PhusdSusdsPair"), PAIR, "PhusdSusdsPair");
    }
}

/**
 * @title DeployBalancerLPMigratorMainnetForkTest  (story 121)
 * @notice Runs the deploy script's own logic against a mainnet fork. Skips cleanly when RPC_MAINNET is unset.
 *         Proves: preview deploys a migrator whose immutables equal story 121's table and writes no progress file;
 *         broadcast mode writes the progress file the patcher reads, a re-run sends nothing, and the verifier
 *         passes (also once the book is filled with the same address); preflight refuses a filled book key with no
 *         progress, a progress address with no code, a mismatching book, and a mis-configured migrator.
 */
contract DeployBalancerLPMigratorMainnetForkTest is Test, Story121Table {
    /// @dev Same block as test/BalancerLPMigrator.fork.t.sol: post-cutover, pre-BIP-928 pause.
    uint256 constant FORK_BLOCK = 26_300_000;

    string constant TMP_PREFIX = "server/deployments/progress.balancer-lp-migrator.1.forktest-";

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

    function _writeProgress(string memory path, address a) internal {
        vm.writeFile(
            path,
            string.concat(
                '{"chainId":1,"networkName":"mainnet","deploymentStatus":"completed","contracts":{"BalancerLPMigrator":{"address":"',
                vm.toString(a),
                '","deployed":true}}}'
            )
        );
    }

    function _assertTable(BalancerLPMigrator m) internal view {
        assertEq(m.vault(), VAULT, "vault");
        assertEq(m.v3Router(), V3_ROUTER, "v3Router");
        assertEq(m.pool(), POOL, "pool");
        assertEq(m.uniRouter(), UNI_ROUTER, "uniRouter");
        assertEq(m.sUSDS(), SUSDS, "sUSDS");
        assertEq(m.phUSD(), PHUSD, "phUSD");
        assertEq(m.pair(), PAIR, "pair");
        assertEq(m.sUSDSIndex(), 0, "sUSDSIndex");
        assertEq(m.phUSDIndex(), 1, "phUSDIndex");
    }

    function test_fork_preview_deploysTableImmutables_writesNoProgress() public {
        if (!_fork()) return;
        string memory path = _tmp("preview");
        DeployBalancerLPMigratorHarness s = new DeployBalancerLPMigratorHarness(true, path, address(0));
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        _assertTable(s.migrator());
        assertFalse(vm.exists(path), "preview must not write the progress file");
    }

    function test_fork_broadcastMode_writesProgress_rerunIsNoop_verifyPasses() public {
        if (!_fork()) return;
        string memory path = _tmp("broadcast");

        DeployBalancerLPMigratorHarness s = new DeployBalancerLPMigratorHarness(false, path, address(0));
        s.run();
        assertTrue(s.deployedThisRun(), "deployed");
        address a = address(s.migrator());
        _assertTable(BalancerLPMigrator(a));

        // The shape scripts/patch-mainnet-addresses-balancer-lp-migrator.js reads.
        assertTrue(vm.exists(path), "progress written");
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonUint(json, ".chainId"), 1, "chainId");
        assertEq(vm.parseJsonString(json, ".networkName"), "mainnet", "networkName");
        assertEq(vm.parseJsonString(json, ".deploymentStatus"), "completed", "status");
        assertEq(vm.parseJsonAddress(json, ".contracts.BalancerLPMigrator.address"), a, "address");
        assertTrue(vm.parseJsonBool(json, ".contracts.BalancerLPMigrator.deployed"), "deployed flag");

        // Re-run: idempotent, nothing deployed - before and after the patcher fills the book.
        DeployBalancerLPMigratorHarness again = new DeployBalancerLPMigratorHarness(false, path, address(0));
        again.run();
        assertFalse(again.deployedThisRun(), "re-run must not deploy");
        assertEq(address(again.migrator()), a, "re-run adopts the recorded migrator");
        DeployBalancerLPMigratorHarness patched = new DeployBalancerLPMigratorHarness(false, path, a);
        patched.run();
        assertFalse(patched.deployedThisRun(), "re-run after patch must not deploy");

        // Verifier: from the progress file alone, then with the book filled.
        new VerifyBalancerLPMigratorHarness(path, address(0)).run();
        new VerifyBalancerLPMigratorHarness(path, a).run();
        vm.removeFile(path);
    }

    function test_fork_preflight_refusesFilledBookWithoutProgress() public {
        if (!_fork()) return;
        DeployBalancerLPMigratorHarness s =
            new DeployBalancerLPMigratorHarness(true, _tmp("filledbook"), makeAddr("somethingElse"));
        vm.expectRevert(
            bytes(
                "address book BalancerLPMigrator is already filled but no progress file records it - check it by hand"
            )
        );
        s.run();
    }

    function test_fork_deploy_refusesBookProgressMismatch() public {
        if (!_fork()) return;
        string memory path = _tmp("mismatch");
        BalancerLPMigrator real = new BalancerLPMigrator(VAULT, V3_ROUTER, POOL, UNI_ROUTER, SUSDS, PHUSD);
        _writeProgress(path, address(real));
        DeployBalancerLPMigratorHarness s = new DeployBalancerLPMigratorHarness(true, path, makeAddr("other"));
        vm.expectRevert(bytes("address book BalancerLPMigrator != the progress file's migrator"));
        s.run();
        VerifyBalancerLPMigratorHarness v = new VerifyBalancerLPMigratorHarness(path, makeAddr("other"));
        vm.expectRevert(bytes("verify: progress file and mainnet-addresses.ts name different migrators"));
        v.run();
        vm.removeFile(path);
    }

    function test_fork_deploy_abortsOnProgressAddressWithoutCode() public {
        if (!_fork()) return;
        string memory path = _tmp("nocode");
        _writeProgress(path, makeAddr("neverLanded"));
        DeployBalancerLPMigratorHarness s = new DeployBalancerLPMigratorHarness(true, path, address(0));
        vm.expectRevert(
            bytes(
                "Progress file names a BalancerLPMigrator with NO CODE - it was recorded in forge's local pass but never landed. Delete server/deployments/progress.balancer-lp-migrator.1.json and re-run preview."
            )
        );
        s.run();
        vm.removeFile(path);
    }

    function test_fork_verify_rejectsMisconfiguredMigrator() public {
        if (!_fork()) return;
        string memory path = _tmp("wrongrouter");
        // A live migrator wired to the same pool but a different (wrong) Balancer router address.
        BalancerLPMigrator wrong =
            new BalancerLPMigrator(VAULT, makeAddr("wrongRouter"), POOL, UNI_ROUTER, SUSDS, PHUSD);
        _writeProgress(path, address(wrong));
        VerifyBalancerLPMigratorHarness v = new VerifyBalancerLPMigratorHarness(path, address(0));
        vm.expectRevert(bytes("verify: v3Router mismatch"));
        v.run();
        // The deploy refuses to adopt it too, rather than silently skipping.
        DeployBalancerLPMigratorHarness s = new DeployBalancerLPMigratorHarness(true, path, address(0));
        vm.expectRevert(bytes("verify: v3Router mismatch"));
        s.run();
        vm.removeFile(path);
    }

    function test_fork_verify_failsWithNoMigrator() public {
        if (!_fork()) return;
        VerifyBalancerLPMigratorHarness v = new VerifyBalancerLPMigratorHarness(_tmp("absent"), address(0));
        vm.expectRevert(
            bytes(
                "verify: no BalancerLPMigrator address (no progress file and the address-book key is zero) - broadcast first"
            )
        );
        v.run();
    }
}
