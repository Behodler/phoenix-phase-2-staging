// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {DeployNudgeDiscountHarness, NudgeDiscountConstants} from "../helpers/NudgeDiscountHarnesses.sol";

interface INFTMinterGate {
    function configs(uint256) external view returns (address, uint256, uint256, bool);
}

interface IUniPoolerGate {
    function batchDonationSize() external view returns (uint256);
    function setBatchDonationSize(uint256) external;
}

interface INudgeStreamerGate {
    function collectNudge(address m, address t, uint256 amt) external;
    function pendingStream(address m, address t) external view returns (uint256);
}

/**
 * @title NudgeDiscountCutoverGateForkTest  (story 119; audit-27 M-01 cutover gate, the human's decision 2026-11-12)
 * @notice Measures `batchMint` gas against the CUTOVER SCRIPT'S OWN deploy+configure output (the script run in its
 *         broadcast mode under an OWNER prank, as `test/DeployMainnetNudgeDiscount.fork.t.sol` does), not a hand-wired
 *         copy, and derives the parameters the script pins in `NudgeDiscountMainnetBase`:
 *           - osaka (`vm.setEvmVersion`): the live UniPoolerV2 halts under shanghai;
 *           - COLD accounts: warm-up under state-diff recording, revert, `vm.cool` every touched account, metered call
 *             with `2^24 - intrinsic` gas (method of nft-staking `test/fork/BatchNFTMinterNudgeDiscountGas.t.sol`);
 *           - UniPoolerV2 donation leg ON at max(live batchDonationSize, 10) (owner prank on the fork only);
 *           - d = 50 (MIN_DISCOUNT_PERCENT) whatever the operating percent;
 *           - three points: cap 25 / cap 50 at d = 50 (paid == free) and the max-boosted cap batch (effective
 *             50 + MAX_BOOST) give gFree, gPaid and the overhead; Fmax is the largest F with
 *             overhead + F*gFree + paid(F,50)*gPaid <= 0.9 * (2^24 - intrinsic), paid(F,50) = ceil(F*100/50) - F;
 *           - the Safeguard-4 minimum `overflowNFTsPerBoostPoint` (`_minSafePerPoint()` method of nft-staking
 *             `BatchNFTMinterNudgeDiscountBoost.t.sol`) at d = 50 and the chosen cap.
 *         Prints greppable `GATE|...` lines (`forge test --match-contract NudgeDiscountCutoverGate -vv`); the values are
 *         recorded in the story's gate parameter table. Every pot is funded through `collectNudge` + a stream warp,
 *         never a direct transfer. Skips cleanly without RPC_MAINNET (fallback MAINNET_RPC_URL).
 */
contract NudgeDiscountCutoverGateForkTest is Test {
    uint256 constant FORK_BLOCK = 26_403_500;
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant UNI_POOLER = 0x56997ea45091CBc01DB8a09E60DEDB8b3706a3D2;
    address constant NUDGE_STREAMER = 0xF7e26179D6971985107AF66b078932D6484eBEAA;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant KENDU = 0xaa95f26e30001251fb905d264Aa7b00eE9dF6C18;
    string constant PROGRESS = "server/deployments/progress.nudge-discount.1.forktest-gate.json";

    uint256 constant TX_GAS_CAP = 16_777_216; // EIP-7825
    uint256 constant TX_BASE = 21_000;
    uint256 constant HEADROOM_PCT = 10;

    BatchNFTMinterNudgeDiscount m;
    NudgeDiscountConstants k;
    address batcher;
    address donor;
    bool forked;

    struct Point {
        uint256 free;
        uint256 paid;
        uint256 used;
        uint256 intrinsic;
    }

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, FORK_BLOCK);
        vm.setEvmVersion("osaka");
        forked = true;

        if (vm.exists(PROGRESS)) vm.removeFile(PROGRESS);
        DeployNudgeDiscountHarness s = new DeployNudgeDiscountHarness(false, PROGRESS, address(0));
        s.run();
        vm.removeFile(PROGRESS);
        m = s.minter();
        k = new NudgeDiscountConstants();

        // Donation leg ON at max(live, 10). Story gate (g): the live value is only logged by the cutover, never set.
        uint256 live = IUniPoolerGate(UNI_POOLER).batchDonationSize();
        emit log_named_uint("GATE|live batchDonationSize", live);
        if (live < 10) {
            vm.prank(OWNER);
            IUniPoolerGate(UNI_POOLER).setBatchDonationSize(10);
        }
        require(m.discountPercent() == 50, "gate measured at d = 50");

        batcher = makeAddr("gate-batcher");
        donor = makeAddr("gate-donor");
        deal(USDS, batcher, 100_000_000e18);
        vm.prank(batcher);
        IERC20(USDS).approve(address(m), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _p0() internal view returns (uint256 p0) {
        (, p0,,) = INFTMinterGate(NFT_MINTER).configs(4);
    }

    function _collect(address token, uint256 amount) internal {
        deal(token, donor, amount);
        vm.startPrank(donor);
        IERC20(token).approve(NUDGE_STREAMER, amount);
        INudgeStreamerGate(NUDGE_STREAMER).collectNudge(address(m), token, amount);
        vm.stopPrank();
    }

    /// @dev Stream the pot to at least `k` free-equivalents (plus phUSD / Kendu bonus so the bonus legs run), all
    ///      through collectNudge, then warp past every window so the whole buffer is pending.
    function _fundTo(uint256 freeEq) internal {
        _collect(USDC, (freeEq * _p0() * 101) / 100 / 1e12 + 1);
        _collect(PHUSD, 10e18);
        _collect(KENDU, 1_000e18);
        vm.warp(block.timestamp + 31 days);
    }

    function _calldata(uint256 total, uint8 boost) internal view returns (bytes memory) {
        address[] memory bonusTokens = m.getBonusTokens();
        uint256[] memory mins = new uint256[](bonusTokens.length);
        return abi.encodeCall(
            BatchNFTMinterNudgeDiscount.batchMint, (total, boost, batcher, 100_000_000e18, bonusTokens, mins)
        );
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Cold-measured execution gas of the batch the current pot forces.
    function _measureCold() internal returns (Point memory p) {
        uint256 total;
        (p.free, total, p.paid,,,,) = m.previewBatch();
        (, uint8 boost,,) = m.previewBoost();
        bytes memory data = _calldata(total, boost);
        p.intrinsic = TX_BASE + _calldataGas(data);

        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(batcher);
        (bool ok,) = address(m).call{gas: 500_000_000}(data);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        require(ok, "warm-up batchMint failed");
        vm.revertToState(snap);
        for (uint256 i; i < acc.length; ++i) {
            vm.cool(acc[i].account);
            vm.cool(acc[i].accessor);
        }
        vm.prank(batcher);
        uint256 g0 = gasleft();
        (ok,) = address(m).call{gas: TX_GAS_CAP - p.intrinsic}(data);
        p.used = g0 - gasleft();
        require(ok, "metered batchMint failed under the EIP-7825 cap");
    }

    function _measureAtCap(uint256 cap, uint8 maxBoost, uint256 overflow) internal returns (Point memory p) {
        uint256 snap = vm.snapshotState();
        vm.startPrank(OWNER);
        m.setMaxFreePerBatch(cap);
        m.setMaxBoost(maxBoost);
        vm.stopPrank();
        _fundTo(cap + overflow);
        p = _measureCold();
        vm.revertToState(snap);
    }

    function _budget(uint256 intrinsic) internal pure returns (uint256) {
        return ((TX_GAS_CAP - intrinsic) * (100 - HEADROOM_PCT)) / 100;
    }

    function _minSafePerPoint() internal returns (uint256 pp) {
        uint256 snap = vm.snapshotState();
        for (pp = 1; pp < 1000; ++pp) {
            vm.prank(OWNER);
            m.setOverflowNFTsPerBoostPoint(pp);
            if (m.boostDonationSafe()) break;
        }
        vm.revertToState(snap);
        require(pp < 1000, "no safe perPoint");
    }

    // ------------------------------------------------------------------ the gate

    function test_Fork_gate_capAndMaxBoostedCap_fit_andDeriveFmax() public {
        if (!forked) vm.skip(true);
        (uint256 cap, uint256 perPoint, uint8 maxBoost, uint256 gateFmax) = k.gate();
        assertEq(m.maxFreePerBatch(), cap, "script configured the gate cap");
        assertEq(m.maxBoost(), maxBoost, "script configured the gate maxBoost");

        // (a) three points: cap 25 and cap 50 at d = 50 with no boost; the max-boosted cap batch.
        Point memory p25 = _measureAtCap(25, 0, 3);
        Point memory p50 = _measureAtCap(50, 0, 3);
        Point memory pb = _measureAtCap(cap, maxBoost, perPoint * maxBoost + perPoint);
        assertEq(p25.free, 25);
        assertEq(p25.paid, 25, "d = 50: paid == free");
        assertEq(p50.paid, 50);
        assertEq(pb.free, cap);
        assertEq(pb.paid, Math.ceilDiv(cap * 100, 50 + uint256(maxBoost)) - cap, "max-boosted paid count");

        uint256 perPair = (p50.used - p25.used) / 25; // gFree + gPaid
        uint256 gPaid = (p50.used - pb.used) / (p50.paid - pb.paid);
        uint256 gFree = perPair - gPaid;
        uint256 overhead = p50.used - 50 * perPair;
        uint256 fmax = (_budget(p50.intrinsic) - overhead) / perPair;

        emit log_named_uint("GATE|cap25 cold exec gas", p25.used);
        emit log_named_uint("GATE|cap50 cold exec gas", p50.used);
        emit log_named_uint("GATE|cap50 tx gas incl. intrinsic", p50.used + p50.intrinsic);
        emit log_named_uint("GATE|maxBoosted cap batch cold exec gas", pb.used);
        emit log_named_uint("GATE|maxBoosted cap batch paid", pb.paid);
        emit log_named_uint("GATE|gPaid", gPaid);
        emit log_named_uint("GATE|gFree", gFree);
        emit log_named_uint("GATE|overhead", overhead);
        emit log_named_uint("GATE|90% budget (2^24 - intrinsic)", _budget(p50.intrinsic));
        emit log_named_uint(
            "GATE|cap50 headroom bps", (TX_GAS_CAP - p50.intrinsic - p50.used) * 10_000 / (TX_GAS_CAP - p50.intrinsic)
        );
        emit log_named_uint(
            "GATE|maxBoosted headroom bps", (TX_GAS_CAP - pb.intrinsic - pb.used) * 10_000 / (TX_GAS_CAP - pb.intrinsic)
        );
        emit log_named_uint("GATE|Fmax", fmax);
        emit log_named_uint("GATE|P0", _p0());

        // (b) the configured cap batch fits with >= 10% headroom at d = 50, leg ON; so does the max-boosted one.
        Point memory pc = cap == 50 ? p50 : _measureAtCap(cap, 0, 3);
        assertLe(pc.used, _budget(pc.intrinsic), "cap batch fits under 2^24 - intrinsic with >= 10% headroom");
        assertLe(pb.used, _budget(pb.intrinsic), "max-boosted cap batch fits with >= 10% headroom");
        assertEq(cap, Math.min(50, fmax), "MAX_FREE_PER_BATCH == min(50, Fmax)");
        assertLe(gateFmax, fmax, "GATE_FMAX does not exceed the measured Fmax");
        assertGe(gateFmax, cap, "GATE_FMAX >= cap");

        // (c) Safeguard-4: perPoint at or above the fork's minimum at d = 50 and the chosen cap.
        uint256 minPP = _minSafePerPoint();
        emit log_named_uint("GATE|Safeguard-4 minimum perPoint", minPP);
        emit log_named_uint("GATE|perPoint", perPoint);
        assertGe(perPoint, minPP, "overflowNFTsPerBoostPoint >= Safeguard-4 minimum");
        assertTrue(m.boostDonationSafe(), "boostDonationSafe() at the configured values");

        // (d) maxBoost in the 10-15 target band, <= 49.
        assertGe(maxBoost, 10);
        assertLe(maxBoost, 15);
    }
}
