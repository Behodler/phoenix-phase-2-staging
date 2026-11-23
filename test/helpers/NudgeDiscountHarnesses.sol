// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployMainnetNudgeDiscount} from "../../script/DeployMainnetNudgeDiscount.s.sol";
import {VerifyNudgeDiscountMainnet} from "../../script/VerifyNudgeDiscountMainnet.s.sol";
import {NudgeDiscountBuyAndBurn} from "../../script/NudgeDiscountBuyAndBurn.s.sol";
import {VerifyPauserV2Migration} from "../../script/VerifyPauserV2Migration.s.sol";
import {NudgeDiscountMainnetBase} from "../../script/helpers/NudgeDiscountMainnetBase.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";

/// @dev Story 119 test harnesses. They pin the mode, the progress path, the book's NudgeDiscountBatchMinter value
///      and the sender (never the process-wide env, which races parallel suites, and never the real progress file).
///      "Broadcast" mode sends as an OWNER prank: a forge test cannot sign with the Ledger, and what is under test is
///      the state gating, the progress file and the pot arithmetic.
contract DeployNudgeDiscountHarness is DeployMainnetNudgeDiscount {
    bool internal immutable preview;
    string internal progressPath;
    address internal booked;
    bool public haltAfterPhase2;
    /// @dev Story 140: false (default) models PauserV2Registry as committed at the 119 broadcast, before the
    ///      2026-11-19 revival of the old minter (every fork block these suites use is pre-revival). true reads the
    ///      committed postMigrationReadditions(), under which the cutover refuses to run.
    bool public useCommittedReadditions;

    constructor(bool preview_, string memory progressPath_, address booked_) {
        preview = preview_;
        progressPath = progressPath_;
        booked = booked_;
    }

    function setHaltAfterPhase2(bool v) external {
        haltAfterPhase2 = v;
    }

    function setUseCommittedReadditions(bool v) external {
        useCommittedReadditions = v;
    }

    function postMigrationReadditions() public view override returns (address[] memory a) {
        if (useCommittedReadditions) return super.postMigrationReadditions();
        a = new address[](0);
    }

    function _haltAfterPhase2() internal view override returns (bool) {
        return haltAfterPhase2;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookNewMinter() internal view override returns (address) {
        return booked;
    }

    function _sender() internal pure override returns (address) {
        return OWNER;
    }

    function _progressWriteEnabledFromEnv() internal pure override returns (bool) {
        return true;
    }

    function _gasPriceFromEnv() internal pure override returns (uint256) {
        return 300_000_000;
    }

    function _requireBroadcastGasPriceHeadroom() internal view override {}

    function _ownerEthOnChain() internal view override returns (uint256) {
        return OWNER.balance;
    }

    bool public haltAfterPotRescue;

    function setHaltAfterPotRescue(bool v) external {
        haltAfterPotRescue = v;
    }

    function _haltAfterPotRescue() internal view override returns (bool) {
        return haltAfterPotRescue;
    }

    // ---- independent per-step OWNER watch (the test's own check, separate from the script's invariant) ----
    bool public ownerWatch;
    uint256 public stepsWatched;
    address[] internal watchTokens;
    uint256[] internal watchBalances;
    uint256 internal watchEth;

    /// @dev Snapshot OWNER's USDC / phUSD / Kendu / USDS / sUSDS / EYE and ETH now; from then on every transaction
    ///      this harness closes reverts "TEST: step credited OWNER" if any of them rose.
    function watchOwner(address[] calldata tokens) external {
        ownerWatch = true;
        watchEth = OWNER.balance;
        for (uint256 i = 0; i < tokens.length; i++) {
            watchTokens.push(tokens[i]);
            watchBalances.push(IERC20Balance(tokens[i]).balanceOf(OWNER));
        }
    }

    function _startTx() internal override {
        vm.startPrank(OWNER);
    }

    function _stopTx() internal override {
        vm.stopPrank();
        if (!ownerWatch) return;
        stepsWatched++;
        require(OWNER.balance <= watchEth, string.concat("TEST: step credited OWNER ETH: ", currentStep));
        for (uint256 i = 0; i < watchTokens.length; i++) {
            require(
                IERC20Balance(watchTokens[i]).balanceOf(OWNER) <= watchBalances[i],
                string.concat("TEST: step credited OWNER: ", currentStep)
            );
        }
    }
}

interface IERC20Balance {
    function balanceOf(address a) external view returns (uint256);
    function approve(address s, uint256 a) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
}

interface IOldMinterRescue {
    function rescueERC20(address token, address to, uint256 amount) external;
}

interface INudgeStreamerCollect {
    function collectNudge(address recipientBatchMinter, address token, uint256 amount) external;
}

/// @dev NEGATIVE-TEST ONLY: the REJECTED Phase 4 design (Decision 4, superseded 2026-11-13) - rescue the old pot to
///      OWNER, then collectNudge it from OWNER in the next tx. Net zero by the end of the run, but OWNER is credited
///      for one step. The fork tests prove the per-step invariant (and the test's own watch) refuse it.
contract DeployNudgeDiscountOwnerTransitHarness is DeployNudgeDiscountHarness {
    constructor(bool preview_, string memory progressPath_, address booked_)
        DeployNudgeDiscountHarness(preview_, progressPath_, booked_)
    {}

    function _phase4_migratePot() internal override {
        address[3] memory toks = _nudgeTokens();
        for (uint256 i = 0; i < 3; i++) {
            _releaseOldBuffer(toks[i]);
            uint256 bal = IERC20Balance(toks[i]).balanceOf(OLD_MINTER);
            if (bal == 0) continue;
            _begin("REJECTED_old_rescueToOwner");
            IOldMinterRescue(OLD_MINTER).rescueERC20(toks[i], OWNER, bal);
            _end();
            _begin("REJECTED_owner_approve");
            IERC20Balance(toks[i]).approve(NUDGE_STREAMER, bal);
            _end();
            _begin("REJECTED_owner_collectNudge");
            INudgeStreamerCollect(NUDGE_STREAMER).collectNudge(address(minter), toks[i], bal);
            _end();
            movedThisRun[i] += bal;
        }
    }
}

contract VerifyNudgeDiscountHarness is VerifyNudgeDiscountMainnet {
    string internal progressPath;
    address internal booked;
    /// @dev Story 140: see DeployNudgeDiscountHarness.useCommittedReadditions. false = the 119-frozen expectation.
    bool public useCommittedReadditions;

    constructor(string memory progressPath_, address booked_) {
        progressPath = progressPath_;
        booked = booked_;
    }

    function setUseCommittedReadditions(bool v) external {
        useCommittedReadditions = v;
    }

    function postMigrationReadditions() public view override returns (address[] memory a) {
        if (useCommittedReadditions) return super.postMigrationReadditions();
        a = new address[](0);
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _bookNewMinter() internal view override returns (address) {
        return booked;
    }
}

/// @dev The buy-and-burn script pointed at a fork-deployed minter through the virtual resolver, with injected inputs.
contract BuyAndBurnHarness is NudgeDiscountBuyAndBurn {
    address internal target;
    uint256 internal usdcIn;
    uint256 internal minOut;
    address internal sender;
    bool internal immutable preview;

    constructor(address target_, bool preview_) {
        target = target_;
        preview = preview_;
        sender = OWNER;
    }

    function setInputs(uint256 usdcIn_, uint256 minOut_) external {
        usdcIn = usdcIn_;
        minOut = minOut_;
    }

    function setSender(address s) external {
        sender = s;
    }

    /// @dev address(0) target = the production resolver (reads the real book).
    function _resolveMinter() internal view override returns (address) {
        if (target == address(0)) return super._resolveMinter();
        return target;
    }

    function quote(uint256 usdcIn_) external view returns (uint256) {
        return _quoteRoute(BatchNFTMinterNudgeDiscount(target), usdcIn_);
    }

    function _inputsFromEnv() internal view override returns (uint256, uint256, uint256) {
        return (usdcIn, minOut, 1800);
    }

    function _sender() internal view override returns (address) {
        return sender;
    }

    function _previewModeFromEnv() internal view override returns (bool) {
        return preview;
    }
}

/// @dev `pauser-v2-verify` with the registry entries the patcher will commit at broadcast time.
contract VerifyPauserV2WithNudgeDiscount is VerifyPauserV2Migration {
    address[] internal extraAdd;
    address[] internal extraRemove;

    /// @dev Story 140: the registry as committed BEFORE the 119 cutover: additions [129 bonfire, 131 SYA], removals
    ///      [131 old SYA], no re-additions. The 119 patcher's own entries (the new minter, the 0x0683 removal) are
    ///      appended by the test from its fork deploy; the committed 0xD412 has no code at the pre-119 FORK_BLOCK,
    ///      and the 0x0683 re-addition (2026-11-19) is later still.
    uint256 internal constant ADDITIONS_BEFORE = 2;
    uint256 internal constant REMOVALS_BEFORE = 1;

    function postMigrationReadditions() public pure override returns (address[] memory a) {
        a = new address[](0);
    }

    /// @dev First `n` entries of an append-only registry list: the list as committed before a later cutover.
    function _prefix(address[] memory x, uint256 n) internal pure returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = x[i];
        }
    }

    function add(address a) external {
        extraAdd.push(a);
    }

    function remove(address a) external {
        extraRemove.push(a);
    }

    function postMigrationAdditions() public view override returns (address[] memory a) {
        a = _concat(_prefix(super.postMigrationAdditions(), ADDITIONS_BEFORE), extraAdd);
    }

    function postMigrationRemovals() public view override returns (address[] memory a) {
        a = _concat(_prefix(super.postMigrationRemovals(), REMOVALS_BEFORE), extraRemove);
    }

    function _concat(address[] memory x, address[] memory y) internal pure returns (address[] memory z) {
        z = new address[](x.length + y.length);
        for (uint256 i = 0; i < x.length; i++) {
            z[i] = x[i];
        }
        for (uint256 i = 0; i < y.length; i++) {
            z[x.length + i] = y[i];
        }
    }
}

/// @dev Exposes the base's pinned / gate constants and book reader to the tests.
contract NudgeDiscountConstants is NudgeDiscountMainnetBase {
    function checkBook() external view {
        _requireBookMatchesConstants();
    }

    function checkGate() external pure {
        _requireGateConstants();
    }

    function bookNewMinter() external view returns (address) {
        return _bookNewMinter();
    }

    function bookKey(string memory key) external view returns (address) {
        return _bookAddress(vm.readFile(BOOK_FILE), key);
    }

    /// @dev Story 135: `day1MaxBoost` is what the cutover sets (0, boost disabled); `ceiling` is the gas-safe value the
    ///      gate measures (MAX_BOOST_GAS_CEILING, 15).
    function gate()
        external
        pure
        returns (uint256 cap, uint256 perPoint, uint8 day1MaxBoost, uint8 ceiling, uint256 fmax)
    {
        return (MAX_FREE_PER_BATCH, OVERFLOW_NFTS_PER_BOOST_POINT, DAY1_MAX_BOOST, MAX_BOOST_GAS_CEILING, GATE_FMAX);
    }

    function ratchet() external pure returns (uint256 index, address nudgeRatchet, address staker, address batchMinter) {
        return (RATCHET_INDEX, NUDGE_RATCHET, RATCHET_NFT_STAKER, RATCHET_BATCH_MINTER);
    }
}
