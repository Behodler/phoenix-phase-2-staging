// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";
import {CrossVersionMigrator} from "stable-staker/CrossVersionMigrator.sol";
import {
    CutoverStableStakerV2Mainnet,
    IPausableLike,
    IPauserRegistry,
    IPhUSDOwner
} from "../script/CutoverStableStakerV2Mainnet.s.sol";
import {VerifyStableStakerV2Cutover} from "../script/VerifyStableStakerV2Cutover.s.sol";
import {ICutoverStaker} from "../script/helpers/StableStakerCutoverCore.sol";

interface IV1Admin {
    function finalizeAndReset(address token) external;
    function initiateMigration(address token) external;
    function stake(address token, uint256 amount) external;
    function register(address c) external;
}

/// @dev Verifier with the two I/O seams replaced: addresses/baselines are injected from a fork-local cutover
///      (the real progress file is never read or written by the tests), and logs come from `vm.recordLogs`
///      (a fork's RPC cannot return logs emitted by locally executed transactions).
contract VerifyStableStakerV2CutoverHarness is VerifyStableStakerV2Cutover {
    struct Row {
        address emitter;
        bytes32 topic0;
        bytes32 topic1;
        bytes32 topic2;
        bytes data;
    }

    Row[] internal rows;
    address internal injAntimatter;
    address internal injV2;
    address internal injMigrator;
    uint256 internal injMask;
    uint256 internal injVersion;

    function inject(address a, address s, address m, uint256 mask, uint256 version) external {
        injAntimatter = a;
        injV2 = s;
        injMigrator = m;
        injMask = mask;
        injVersion = version;
    }

    function addLog(address emitter, bytes32 t0, bytes32 t1, bytes32 t2, bytes memory data) external {
        rows.push(Row(emitter, t0, t1, t2, data));
    }

    function _hydrateDeployment() internal override {
        antimatter = Antimatter(injAntimatter);
        v2 = StableStakerV2(injV2);
        migrator = CrossVersionMigrator(injMigrator);
        phusdMaskAtPhase0 = injMask;
        phusdMintVersionAtPhase0 = injVersion;
        phusdBaselineRecorded = true;
        cutoverStartBlock = block.number;
    }

    function _fetchLogs(address emitter, bytes32 topic0) internal view override returns (CutoverLog[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < rows.length; i++) {
            if (rows[i].emitter == emitter && rows[i].topic0 == topic0) n++;
        }
        out = new CutoverLog[](n);
        uint256 k;
        for (uint256 i = 0; i < rows.length; i++) {
            if (rows[i].emitter != emitter || rows[i].topic0 != topic0) continue;
            bytes32[] memory topics = new bytes32[](3);
            topics[0] = rows[i].topic0;
            topics[1] = rows[i].topic1;
            topics[2] = rows[i].topic2;
            out[k++] = CutoverLog({emitter: emitter, topics: topics, data: rows[i].data});
        }
    }
}

/// @dev Exposes the verifier's REAL (live `vm.eth_getLogs`, chunked) log fetch.
contract VerifyStableStakerV2CutoverLogProbe is VerifyStableStakerV2Cutover {
    function probe(uint256 fromBlock, address emitter, bytes32 topic0) external returns (uint256 count, bytes32 first) {
        cutoverStartBlock = fromBlock;
        CutoverLog[] memory logs = _fetchLogs(emitter, topic0);
        count = logs.length;
        if (count > 0) first = logs[0].topics[0];
    }
}

/**
 * @title VerifyStableStakerV2CutoverGuardsTest  (story 086, audit L-02)
 * @notice Two layers:
 *         1. SOURCE GUARDS (no RPC): the verifier is read-only and never calls an inherited mutator; it never
 *            trusts the progress file's status field; the broadcast npm key runs :verify before :preview.
 *         2. FORK SCENARIOS (skip without RPC_MAINNET; fork at 25_978_784): run the real cutover in preview on
 *            the fork to reach the completed state, then tamper and run the verifier. These reproduce audit
 *            tests test_C / C2 / C3 as verifier FAILURES, plus the race (a V1 staker left unmigrated) and a
 *            missing per-user V2 credit. Setup uses prank/deal - the read-only rule binds the verifier, not
 *            this test.
 */
contract VerifyStableStakerV2CutoverGuardsTest is Test {
    string constant VERIFIER_SRC = "script/VerifyStableStakerV2Cutover.s.sol";
    uint256 constant FORK_BLOCK = 25_978_784;

    bytes32 constant MIGRATED_OUT = keccak256("MigratedOut(address,address,uint256,uint256)");
    bytes32 constant USER_MIGRATED = keccak256("UserMigrated(address,address,uint256)");
    bytes32 constant DEPOSITED_FOR = keccak256("DepositedFor(address,address,uint256)");

    CutoverStableStakerV2Mainnet cut;
    VerifyStableStakerV2CutoverHarness vf;
    address OWNER;
    address V1;
    address PAUSER;
    address PHUSD;

    // =====================================================================
    //  Source guards (no RPC)
    // =====================================================================

    function test_verifierIsReadOnly() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        string[16] memory banned = [
            "startBroadcast",
            "vm.broadcast",
            "startPrank",
            "vm.prank",
            "deal(",
            "vm.warp",
            "vm.roll",
            "snapshotState",
            "revertToState",
            "vm.store",
            "vm.etch",
            "writeFile",
            "forge-std/Test.sol",
            "StdCheats",
            "setEnv",
            "isPreview = true"
        ];
        for (uint256 i = 0; i < banned.length; i++) {
            assertFalse(_contains(src, banned[i]), string.concat("verifier source contains banned token: ", banned[i]));
        }
    }

    /// @dev The inherited cutover mutators must never be reached from the verifier.
    function test_verifierNeverCallsInheritedMutators() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        string[12] memory banned = [
            "_phase1_pauseV1",
            "_retireV1",
            "_phase2_antimatter",
            "_phase3_stakerV2",
            "_phase4_pools",
            "_setupPool",
            "_phase5_mintRights",
            "_phase6_migration",
            "_phase7_finalize",
            "_previewSmokeTests",
            "_assertGlobalPauseWorks",
            "_writeProgress"
        ];
        for (uint256 i = 0; i < banned.length; i++) {
            assertFalse(_contains(src, banned[i]), string.concat("verifier calls inherited mutator: ", banned[i]));
        }
        assertFalse(_contains(src, "_initiatePool"), "verifier must not initiate");
        assertFalse(_contains(src, "_migratePool"), "verifier must not migrate");
    }

    /// @dev Gate on chain, never on the progress file's status field (it is stamped in forge's local pass).
    function test_verifierNeverTrustsProgressStatus() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        assertFalse(_contains(src, "deploymentStatus"), "verifier must not read the progress status field");
        assertFalse(_contains(src, "\"completed\""), "verifier must not compare against a completed status");
    }

    /// @dev The verifier re-uses the shared predicates and the story 084 / 085 checks, and rejects PREVIEW_MODE.
    function test_verifierWiresSharedChecks() public view {
        string memory src = vm.readFile(VERIFIER_SRC);
        assertTrue(_contains(src, "_phase8_wiringAssertions();"), "Phase 8 wiring assertions");
        assertTrue(_contains(src, "_assertPoolPostMigration("), "story 085 aggregate floor");
        assertTrue(_contains(src, "getPausableContracts()"), "story 084 registrant sweep");
        assertTrue(_contains(src, "_planPool("), "live re-plan");
        assertTrue(_contains(src, "_v1MintRevoked()"), "shared V1 mint predicate");
        assertTrue(_contains(src, "_doneV2Unpaused()"), "shared V2 unpause predicate");
        assertTrue(_contains(src, "!vm.envOr(\"PREVIEW_MODE\", false)"), "rejects PREVIEW_MODE");
        assertTrue(_contains(src, "eth_getLogs"), "per-user re-check from logs");
    }

    /// @dev The broadcast chain must verify on chain BEFORE the preview smoke test.
    function test_broadcastChainsVerifyBeforePreview() public view {
        string memory pkg = vm.readFile("package.json");
        assertTrue(
            _contains(pkg, "npm run stable-staker-v2-cutover:verify && npm run stable-staker-v2-cutover:preview\""),
            ":broadcast must end with :verify && :preview"
        );
        assertTrue(
            _contains(
                pkg,
                "\"stable-staker-v2-cutover:verify\": \"forge script script/VerifyStableStakerV2Cutover.s.sol:VerifyStableStakerV2Cutover --rpc-url $RPC_MAINNET -vvv\""
            ),
            ":verify key"
        );
    }

    // =====================================================================
    //  Fork scenarios
    // =====================================================================

    function _forkAndCutover() internal returns (bool) {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.setEnv("PREVIEW_MODE", "true");
        cut = new CutoverStableStakerV2Mainnet();
        OWNER = cut.OWNER();
        V1 = cut.STABLE_STAKER_V1();
        PAUSER = cut.PAUSER();
        PHUSD = cut.PHUSD();

        vm.recordLogs();
        cut.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        vm.setEnv("PREVIEW_MODE", "false");
        vf = new VerifyStableStakerV2CutoverHarness();
        vf.inject(
            address(cut.antimatter()),
            address(cut.v2()),
            address(cut.migrator()),
            cut.phusdMaskAtPhase0(),
            cut.phusdMintVersionAtPhase0()
        );
        _feed(logs, bytes32(0), address(0));
        return true;
    }

    /// @dev Feeds the cutover's V1/V2 migration logs to the verifier, optionally dropping one DepositedFor
    ///      (matched by user) to simulate a credit that never landed.
    function _feed(Vm.Log[] memory logs, bytes32 dropUser, address dropToken) internal {
        address v2 = address(cut.v2());
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.topics.length < 3) continue;
            bool v1Evt = l.emitter == V1 && (l.topics[0] == MIGRATED_OUT || l.topics[0] == USER_MIGRATED);
            bool v2Evt = l.emitter == v2 && l.topics[0] == DEPOSITED_FOR;
            if (!v1Evt && !v2Evt) continue;
            if (v2Evt && l.topics[2] == dropUser && address(uint160(uint256(l.topics[1]))) == dropToken) continue;
            vf.addLog(l.emitter, l.topics[0], l.topics[1], l.topics[2], l.data);
        }
    }

    function _reason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "";
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = ret[i + 4];
        }
        return abi.decode(body, (string));
    }

    function _runExpectingRevertContaining(string memory needle) internal returns (string memory reason) {
        try vf.run() {
            revert(string.concat("verifier PASSED but was expected to revert with: ", needle));
        } catch (bytes memory ret) {
            reason = _reason(ret);
        }
        assertTrue(_contains(reason, needle), string.concat("unexpected revert reason: ", reason));
    }

    /// Clean completed cutover state -> verifier passes, and actually re-checked per-user credits.
    function test_fork_cleanCompletedState_verifierPasses() public {
        if (!_forkAndCutover()) return;
        vf.run();
        assertGt(vf.verifiedUserCount(), 0, "per-user re-check must not be vacuous");
        console.log("per-user credits re-checked:", vf.verifiedUserCount());
    }

    /// test_C (MASK_REVOKE): V1 phUSD mint still live on chain -> verifier reverts.
    function test_fork_v1MintRegranted_verifierReverts() public {
        if (!_forkAndCutover()) return;
        vm.prank(OWNER);
        IPhUSDOwner(PHUSD).setMinter(V1, true);
        _runExpectingRevertContaining("verify: Phase7: phUSD.setMinter(V1, false) revoke not on chain");
    }

    /// test_C2 (MASK_PAUSED_V2): V2 still paused on chain -> verifier reverts.
    function test_fork_v2Paused_verifierReverts() public {
        if (!_forkAndCutover()) return;
        address v2 = address(cut.v2()); // resolved BEFORE the prank, which the next external call consumes
        vm.prank(PAUSER);
        IPausableLike(v2).pause();
        _runExpectingRevertContaining("verify: Phase7: V2 unpause not on chain");
    }

    /// test_C3 (MASK_V1_RETIRE): V1 unpaused, pauser back to Pauser, re-registered -> verifier reverts.
    function test_fork_v1Unretired_verifierReverts() public {
        if (!_forkAndCutover()) return;
        vm.startPrank(OWNER);
        IPausableLike(V1).unpause();
        IPausableLike(V1).setPauser(PAUSER);
        IPauserRegistry(PAUSER).register(V1);
        vm.stopPrank();
        _runExpectingRevertContaining("verify: Phase1: V1 setPauser(OWNER) not on chain");
    }

    /// RACE: a V1 staker left unmigrated on chain -> verifier reverts naming the user, the amount and the
    ///       remediation. Planted by reviving an EMPTY V1 pool (finalizeAndReset), staking, and re-initiating,
    ///       which leaves exactly the on-chain shape of a stake that raced the Phase-1 pause.
    function test_fork_plantedV1Staker_verifierRevertsNamingUser() public {
        if (!_forkAndCutover()) return;
        address[] memory toks = IStakerTokensLike(V1).getStakedTokens();
        address t;
        for (uint256 i = 0; i < toks.length; i++) {
            (,,, uint256 staked) = ICutoverStaker(V1).poolInfo(toks[i]);
            if (ICutoverStaker(V1).stakerCount(toks[i]) == 0 && staked == 0) {
                t = toks[i];
                break;
            }
        }
        require(t != address(0), "test setup: no fully drained V1 pool to revive");

        address racer = makeAddr("story086-racer");
        uint256 amount = 5_000 * 10 ** IERC20MetadataLike(t).decimals();
        deal(t, racer, amount);

        vm.startPrank(OWNER);
        IV1Admin(V1).finalizeAndReset(t);
        IPausableLike(V1).unpause();
        vm.stopPrank();
        vm.startPrank(racer);
        IERC20(t).approve(V1, amount);
        IV1Admin(V1).stake(t, amount);
        vm.stopPrank();
        vm.prank(OWNER);
        IPausableLike(V1).pause();
        vm.prank(address(cut.migrator()));
        IV1Admin(V1).initiateMigration(t);

        string memory reason = _runExpectingRevertContaining(string.concat("V1 staker ", vm.toString(racer)));
        assertTrue(_contains(reason, vm.toString(amount)), "reason names the amount");
        assertTrue(_contains(reason, "re-grant the V1 phUSD mint"), "reason names the remediation");
    }

    /// PER-USER: a V1 MigratedOut credit with no V2 DepositedFor -> verifier reverts naming the user.
    function test_fork_missingDepositedFor_verifierReverts() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.setEnv("PREVIEW_MODE", "true");
        cut = new CutoverStableStakerV2Mainnet();
        OWNER = cut.OWNER();
        V1 = cut.STABLE_STAKER_V1();
        PAUSER = cut.PAUSER();
        PHUSD = cut.PHUSD();
        vm.recordLogs();
        cut.run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.setEnv("PREVIEW_MODE", "false");

        // Pick the first migrated user with a non-zero credit.
        bytes32 user;
        address token;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != V1 || logs[i].topics.length < 3 || logs[i].topics[0] != MIGRATED_OUT) continue;
            (uint256 credit,) = abi.decode(logs[i].data, (uint256, uint256));
            if (credit == 0) continue;
            user = logs[i].topics[2];
            token = address(uint160(uint256(logs[i].topics[1])));
            break;
        }
        require(user != bytes32(0), "test setup: no migrated user");

        vf = new VerifyStableStakerV2CutoverHarness();
        vf.inject(
            address(cut.antimatter()),
            address(cut.v2()),
            address(cut.migrator()),
            cut.phusdMaskAtPhase0(),
            cut.phusdMintVersionAtPhase0()
        );
        _feed(logs, user, token);
        _runExpectingRevertContaining(
            string.concat("verify: per-user: V2 DepositedFor for user ", vm.toString(address(uint160(uint256(user)))))
        );
    }

    /// The live log path works on this forge / forge-std / RPC: a chunked `vm.eth_getLogs` over a range spanning
    /// more than one LOG_CHUNK_BLOCKS window returns V1's real events (2 events at block 25_972_442).
    function test_fork_liveEthGetLogsChunkedFetchWorks() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        VerifyStableStakerV2CutoverLogProbe p = new VerifyStableStakerV2CutoverLogProbe();
        bytes32 topic = 0xf7a40077ff7a04c7e61f6f26fb13774259ddf1b6bce9ecf26a8276cdd3992683;
        (uint256 count, bytes32 first) = p.probe(25_968_000, 0xbce8ABC09BaEDCabE93419bF875f6186e182079A, topic);
        assertGe(count, 2, "chunked eth_getLogs returned V1's events");
        assertEq(first, topic, "topic filter applied");
    }

    // =====================================================================
    //  Helpers
    // =====================================================================

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}

interface IStakerTokensLike {
    function getStakedTokens() external view returns (address[] memory);
}

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}
