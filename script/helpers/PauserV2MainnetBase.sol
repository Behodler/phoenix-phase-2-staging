// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {StdCheats} from "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {PauserV2Registry} from "./PauserV2Registry.sol";

/// @dev Shape of `IPausableLike` (CutoverStableStakerV2Mainnet.s.sol L2327). Every Phoenix pausable exposes an
///      owner-only `setPauser(address)`; `paused()` is NOT universal, so it is always probed low-level.
interface IPauserV2Pausable {
    function pauser() external view returns (address);
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
}

/// @dev Shape of `IPauserRegistry` (CutoverStableStakerV2Mainnet.s.sol L2365) for the V1 mainnet Pauser.
interface IPauserV1Registry {
    function owner() external view returns (address);
    function isRegistered(address c) external view returns (bool);
    function getPausableContracts() external view returns (address[] memory);
    function eyeToken() external view returns (address);
    function eyeBurnAmount() external view returns (uint256);
}

interface IOwnedV2 {
    function owner() external view returns (address);
}

/**
 * @title PauserV2MainnetBase  (story 128, sprint global-pauser-v2)
 * @notice Shared constants, registrant sets and checks for the mainnet PauserV2 deploy
 *         (`DeployPauserV2Mainnet`), migration (`MigratePauserV2Mainnet`) and read-only verifier
 *         (`VerifyPauserV2Migration`).
 *
 *         The LIVE / RETIRED split comes from the committed classification `docs/pauser-v2-registrants.md`
 *         (sweep `script/ClassifyPauserV2Registrants.s.sol` + `scripts/pauser-v2-registrant-labels.js`, mainnet
 *         block 26,333,708). It is a HAND-COPIED SNAPSHOT on purpose: the migration preflight asserts it against
 *         the live `V1.getPausableContracts()` and refuses on any drift, so the operator re-classifies instead of
 *         migrating a stale list (e.g. if phStaging2:119 registers a new minter with V1 first).
 */
abstract contract PauserV2MainnetBase is Script, StdCheats, PauserV2Registry {
    uint256 internal constant CHAIN_ID = 1;
    string internal constant NETWORK_NAME = "mainnet";

    /// @dev Owner of the V1 Pauser and of every registrant (an EOA on a Ledger, hd path m/44'/60'/46'/0/0).
    address internal constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    /// @dev The V1 mainnet Pauser (`server/deployments/mainnet-addresses.ts` L69 before the patch).
    address internal constant PAUSER_V1 = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    /// @dev EYE, the V1 Pauser's burn token (`mainnet-addresses.ts` `EYE`, and `V1.eyeToken()`).
    address internal constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    /// @dev 1000 EYE: V1's live `eyeBurnAmount()` and PauserV2's constructor default. The FINAL burn: the migration
    ///      sets it back as its last transaction, and the verifier requires it.
    uint256 internal constant EYE_BURN_AMOUNT = 1000e18;
    /// @dev 1,000,000 EYE (product owner, audit 49 L-02): the burn while the rotation window is open. At 1000 EYE
    ///      anyone could V2.pause() mid-window (~$12), and the paused registrants block the scripted resume while
    ///      the unrotated ones sit on the bricked V1. 1M EYE is ~10% of EYE's 9.73M supply. Set by the deploy
    ///      right after the CREATE (or by the migration before its first rotation, if the deploy did not).
    uint256 internal constant EYE_BURN_AMOUNT_MIGRATION = 1_000_000e18;
    /// @dev StableStakerV2; re-registered with V1 after the story-124 freeze/unfreeze cycle.
    address internal constant STABLE_STAKER_V2 = 0xA6d3fc83C91B8319D219cEB12B46e3dfF064B58F;

    /// @dev Written by `DeployPauserV2Mainnet` after a real broadcast; read by the migration and the verifier.
    string internal constant PROGRESS_FILE = "server/deployments/progress.pauser-v2.1.json";
    string internal constant BOOK_FILE = "server/deployments/mainnet-addresses.ts";

    // ============ Registrant sets ============

    /// @notice The 18 LIVE registrants, in rotation order: value at risk first (StableStakerV2, Antimatter,
    ///         PhlimboV3, yield strategies, minters, stakers, rest). Rationale per address in
    ///         docs/pauser-v2-registrants.md.
    function liveRegistrants() public pure returns (address[] memory a) {
        a = new address[](18);
        a[0] = 0xA6d3fc83C91B8319D219cEB12B46e3dfF064B58F; // StableStakerV2
        a[1] = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151; // Antimatter
        a[2] = 0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca; // PhlimboV3
        a[3] = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83; // YieldStrategyUSDC (autoUSD)
        a[4] = 0x981c7BE1460c7C8Cb40B8EB5908B29510Ae0B7EE; // YieldStrategyDola (sDOLA)
        a[5] = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95; // YieldStrategyUSDe (sUSDe)
        a[6] = 0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C; // PhusdStableMinter
        a[7] = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5; // PhusdStableMinter (old; ~3,750 USDe principal in YS-USDe)
        a[8] = 0x39Af088408e815844c567037C157B31d48d2E10F; // NFTMinter (V2)
        a[9] = 0x068395556b8c43eDf257DC54D109EA5910aE15c7; // BatchNFTMinter
        a[10] = 0xd936461f1C15eA9f34Ca1F20ecD54A0819068811; // NFTMinter (V1; dispatchers still enabled - ambiguous)
        a[11] = 0x4Bf42BD098774a3b3e844cd42149ebBB1108E541; // NFTMinter (pre-V1; dispatchers still enabled - ambiguous)
        a[12] = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b; // NFTStaker
        a[13] = 0x299b0071DEf42D35eaf5ea24CC0a71Cf10655A64; // RatchetNFTStaker
        a[14] = 0xE9067f37f6D0bb116233194690fb600Add8fD052; // UniboostStakerEYE
        a[15] = 0x541b912B5451FfE2c04D5Ea8D317081718683242; // UniboostStakerSCX
        a[16] = 0x17E25Cca844bC71c1E663E089fF11aFD266B5795; // UniboostStakerFLX
        a[17] = 0x0cD353bfda674D04823B2826ffafB83B560D21B6; // StableYieldAccumulator
    }

    /// @notice The 9 RETIRED registrants. They stay on the dead V1 with NO transaction; V2 never covers them.
    function retiredRegistrants() public pure returns (address[] memory a) {
        a = new address[](9);
        a[0] = 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4; // Old YieldStrategyDola (0 shares)
        a[1] = 0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f; // StableYieldAccumulator (Jan 2026; no funds)
        a[2] = 0xdd8cE46ea31d51f38279886a81cFc4c1a90d5E19; // StableYieldAccumulator (no funds)
        a[3] = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E; // StableYieldAccumulator (no funds)
        a[4] = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78; // YieldStrategyDola (0 shares)
        a[5] = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952; // YieldStrategyUSDC (0 shares)
        a[6] = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3; // YieldStrategyUSDe (0 shares)
        a[7] = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9; // YieldStrategyDola (0 shares)
        a[8] = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470; // YieldStrategyUSDC (0 shares)
    }

    /// @notice The V1 registrant snapshot (LIVE + RETIRED = 27) the migration preflight expects on chain.
    function expectedV1Registrants() public pure returns (address[] memory a) {
        address[] memory live = liveRegistrants();
        address[] memory retired = retiredRegistrants();
        a = new address[](live.length + retired.length);
        for (uint256 i = 0; i < live.length; i++) {
            a[i] = live[i];
        }
        for (uint256 i = 0; i < retired.length; i++) {
            a[live.length + i] = retired[i];
        }
    }

    // ============ Checks ============

    /// @notice Refuses unless the on-chain V1 registrant set equals the classified snapshot (as sets).
    function _requireV1Snapshot() internal view {
        address[] memory onChain = IPauserV1Registry(PAUSER_V1).getPausableContracts();
        address[] memory expected = expectedV1Registrants();
        require(
            onChain.length == expected.length,
            "V1 registrant count differs from the story-128 snapshot - re-run the classification and update the live set"
        );
        for (uint256 i = 0; i < expected.length; i++) {
            require(
                IPauserV1Registry(PAUSER_V1).isRegistered(expected[i]),
                "V1 registrant set differs from the story-128 snapshot - re-run the classification and update the live set"
            );
        }
    }

    /// @notice The PauserV2 at `v2` is the one this migration expects: code, owner, EYE token, and a burn amount
    ///         that is one of the two states the migration uses (final or rotation-window).
    function _checkPauserV2(address v2) internal view {
        require(v2 != address(0), "PauserV2 address is zero");
        require(v2 != PAUSER_V1, "PauserV2 address is the V1 Pauser");
        require(v2.code.length > 0, "PauserV2 has no code");
        PauserV2 p = PauserV2(v2);
        require(p.owner() == OWNER, "PauserV2.owner() != OWNER");
        require(p.eyeToken() == EYE, "PauserV2.eyeToken() != EYE");
        uint256 burn = p.eyeBurnAmount();
        require(
            burn == EYE_BURN_AMOUNT || burn == EYE_BURN_AMOUNT_MIGRATION,
            "PauserV2.eyeBurnAmount() is neither 1000e18 (final) nor 1_000_000e18 (rotation window)"
        );
        // health() exists only on V2: a V1 Pauser at this address fails here.
        p.health();
    }

    /// @notice The end state, against whatever chain state this runs on (local pass, fork or live):
    ///         V2.health() notPauser / alreadyPaused / unreachable are empty; V2's registrant set equals the live
    ///         set; every live registrant's pauser() is V2 (so none is on V1); no retired registrant is on V2.
    function _requirePostconditions(address v2, string memory tag) internal view {
        PauserV2 p = PauserV2(v2);
        address[] memory live = liveRegistrants();

        for (uint256 i = 0; i < live.length; i++) {
            address cur = IPauserV2Pausable(live[i]).pauser();
            require(
                cur != PAUSER_V1,
                string.concat(tag, ": a live registrant points at the dead V1 Pauser (an old V1 recovery script?)")
            );
            require(cur == v2, string.concat(tag, ": a live registrant's pauser() is not PauserV2"));
            require(p.isRegistered(live[i]), string.concat(tag, ": a live registrant is not registered with PauserV2"));
        }

        address[] memory onV2 = p.getPausableContracts();
        require(onV2.length == live.length, string.concat(tag, ": PauserV2 registrant count != live set size"));

        address[] memory retired = retiredRegistrants();
        for (uint256 i = 0; i < retired.length; i++) {
            require(
                !p.isRegistered(retired[i]), string.concat(tag, ": a RETIRED registrant is registered with PauserV2")
            );
        }

        (
            address[] memory notPauser,
            address[] memory alreadyPaused,
            address[] memory noGetter,
            address[] memory unreachable
        ) = p.health();
        require(notPauser.length == 0, string.concat(tag, ": PauserV2.health() notPauser is not empty"));
        require(alreadyPaused.length == 0, string.concat(tag, ": PauserV2.health() alreadyPaused is not empty"));
        require(unreachable.length == 0, string.concat(tag, ": PauserV2.health() unreachable is not empty"));
        console.log(string.concat(tag, ": postconditions OK. Live registrants on PauserV2:"), onV2.length);
        console.log(
            "  health(): notPauser 0, alreadyPaused 0, unreachable 0, noPausedGetter (informational):", noGetter.length
        );
        for (uint256 i = 0; i < noGetter.length; i++) {
            console.log("    no paused() getter:", noGetter[i]);
        }
    }

    // ============ Broadcast gas price (audit run 49 L-03) ============

    /// @dev The :broadcast keys send LEGACY txs at a fixed `--with-gas-price $PAUSER_V2_GAS_PRICE_WEI` (default
    ///      0.3 gwei). A legacy tx pays its full gas price, and it cannot be included while block.basefee exceeds
    ///      that price. It also cannot be replaced by re-running at the same price. Requiring 2x headroom at start
    ///      means the base fee must more than double during the --slow Ledger session before a tx can stall.
    ///      `tx.gasprice` inside a forge script does NOT reflect --with-gas-price, so the env var is the source.
    uint256 internal constant GAS_PRICE_BASEFEE_MULTIPLE = 2;

    function _requireBroadcastGasPriceHeadroom() internal view {
        _requireGasPriceHeadroom(vm.envOr("PAUSER_V2_GAS_PRICE_WEI", uint256(0)));
    }

    function _requireGasPriceHeadroom(uint256 gasPriceWei) internal view {
        require(gasPriceWei > 0, "PAUSER_V2_GAS_PRICE_WEI unset or 0");
        console.log("Gas price (wei):", gasPriceWei);
        console.log("block.basefee (wei):", block.basefee);
        require(
            gasPriceWei >= block.basefee * GAS_PRICE_BASEFEE_MULTIPLE,
            "PAUSER_V2_GAS_PRICE_WEI < 2 x block.basefee: raise it (runbook: Gas price)"
        );
    }

    // ============ Address sources ============

    /// @notice The PauserV2 recorded by `DeployPauserV2Mainnet`'s broadcast, or address(0) when none.
    function _progressPauserV2() internal view virtual returns (address) {
        string memory json;
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            return address(0);
        }
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".contracts.PauserV2.address")) return address(0);
        return vm.parseJsonAddress(json, ".contracts.PauserV2.address");
    }

    /// @notice True when the deploy progress file says `completed` (set by scripts/confirm-pauser-v2-progress.js
    ///         after a success receipt and live code; audit 49 L-06).
    function _progressCompleted() internal view virtual returns (bool) {
        string memory json;
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            return false;
        }
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".deploymentStatus")) return false;
        return keccak256(bytes(vm.parseJsonString(json, ".deploymentStatus"))) == keccak256("completed");
    }

    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    /// @notice The `Pauser` key of the hand-maintained address book.
    function _bookPauser() internal view virtual returns (address) {
        string memory book = vm.readFile(BOOK_FILE);
        string[] memory parts = vm.split(book, "\n  Pauser: \"");
        require(parts.length == 2, "address book: expected exactly one `Pauser:` key");
        bytes memory tail = bytes(parts[1]);
        require(tail.length >= 42, "address book: truncated Pauser value");
        bytes memory a = new bytes(42);
        for (uint256 i = 0; i < 42; i++) {
            a[i] = tail[i];
        }
        return vm.parseAddress(string(a));
    }

    /// @notice Low-level `paused()` probe: (false, _) when the getter is missing or returns a non-bool word.
    function _probePaused(address c) internal view returns (bool ok, bool isPaused) {
        (bool success, bytes memory data) = c.staticcall(abi.encodeWithSignature("paused()"));
        if (!success || data.length < 32) return (false, false);
        uint256 w = abi.decode(data, (uint256));
        if (w > 1) return (false, false);
        return (true, w == 1);
    }

    // ============ Preview-only global pause probe ============

    /// @notice Adapted from `CutoverStableStakerV2Mainnet._assertGlobalPauseWorks` (L1609ff). Snapshots state,
    ///         funds a throwaway actor with the burn amount of EYE, has it call the permissionless `V2.pause()`,
    ///         requires every live registrant with a `paused()` getter to report paused, then `V2.unpause()` as
    ///         OWNER and requires every one to report unpaused, then reverts the snapshot.
    ///         PREVIEW / FORK ONLY - never deal/prank/snapshot in a broadcast session. No active prank allowed.
    function _assertGlobalPauseRoundTrip(address v2, string memory stage) internal {
        PauserV2 p = PauserV2(v2);
        address[] memory live = liveRegistrants();
        uint256 snap = vm.snapshotState();

        address actor = makeAddr("story128-global-pause-actor");
        deal(EYE, actor, EYE_BURN_AMOUNT, false);
        require(IERC20(EYE).balanceOf(actor) >= EYE_BURN_AMOUNT, "globalPause: could not fund actor with EYE");
        vm.prank(actor);
        IERC20(EYE).approve(v2, EYE_BURN_AMOUNT);
        vm.prank(actor);
        p.pause();

        uint256 checked;
        for (uint256 i = 0; i < live.length; i++) {
            (bool ok, bool isPaused) = _probePaused(live[i]);
            if (!ok) continue;
            require(isPaused, string.concat(stage, ": globalPause: a live registrant is NOT paused after V2.pause()"));
            checked++;
        }

        vm.prank(OWNER);
        p.unpause();
        for (uint256 i = 0; i < live.length; i++) {
            (bool ok, bool isPaused) = _probePaused(live[i]);
            if (!ok) continue;
            require(
                !isPaused, string.concat(stage, ": globalPause: a live registrant is still paused after V2.unpause()")
            );
        }

        vm.revertToState(snap);
        console.log(
            string.concat(
                stage,
                ": global pause round-trip OK (V2.pause -> all paused -> V2.unpause -> all unpaused); registrants checked:"
            ),
            checked
        );
    }
}
