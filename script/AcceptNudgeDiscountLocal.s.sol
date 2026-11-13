// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "@forge-std/Script.sol";
import {Vm} from "@forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {NudgeStreamer} from "nft-staking/NudgeStreamer.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {IUniswapV2Pair} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Pair.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSkyPSM} from "../src/mocks/MockSkyPSM.sol";

/// @dev The one Router02 view this script needs that the repo's minimal router interfaces omit.
interface IUniswapV2RouterAmountsOut {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/// @dev `BalancerPoolerMintDebtHook.ratio()`, read live as the minter does.
interface IMintDebtRatioView {
    function ratio() external view returns (uint8);
}

/// @title  AcceptNudgeDiscountLocal
/// @notice Story 118. Anvil acceptance for DeployMocks Phase 11.18 (BatchNFTMinterNudgeDiscount), run
///         against a live anvil after `npm run dev` (`npm run nudge-discount:acceptance-local`).
///         SIMULATION ONLY - never pass --broadcast: forge forks the anvil state, so the chain is left
///         exactly as DeployMocks left it, and `vm.warp` / `vm.prank` act on the fork only.
///
///         Every expected value is recomputed HERE from the spec maths (P0 = `configs(4).price`, the PSM
///         `tin` and conversion factor, `discountPercent`, `hook.ratio()`, `total = ceilDiv(free * 100, d)`)
///         and compared with what the contract previews and does:
///           1. the phUSD/sUSDS pair has non-zero reserves on both sides;
///           2. pots of 1.0, 1.5 and 2.0 x P0 at d = 50 -> 1+1, 1+1, 2+2 (free + paid), and a pot of
///              2 x P0 at d = 75 -> total 3 = ceil(200 / 75), paid 1 (d = 30 is no longer settable:
///              nft-staking:034 bounds discountPercent to {0} or 50..99);
///           3. each `batchMint`: NFTs +total, price moved by exactly `paid` growth steps, the caller paid
///              `paidCost` and got no USDC, every bonus token paid >= its floor and drained, the reserve
///              rose by the whole pot and the owed balance by `owed`; a stale `expectedTotal` and an
///              immediate second batch both revert. Every batch quotes `previewBoost().boost` and signs
///              `bonusTokens` + `bonusMinRewards` (balance + pending stream) from one `getBonusTokens()` read;
///           2b. revert probes: swapped `bonusTokens` (BonusTokenMismatch), a short `bonusMinRewards`
///              (ArrayLengthMismatch), a quote above the live boost (BoostNotAvailable), and
///              `setDiscountPercent` 30 / 100 (PercentTooLow / PercentTooHigh);
///           5. cap/boost: a pot above a lowered `maxFreePerBatch` gives `free == cap`, the overflow boost,
///              `TempDiscountApplied`, the capped `mulDiv` reserve with the remainder left as pot, and a
///              quote of `liveBoost - 1` honoured at the quoted terms; then 50/3/0 are restored;
///           4. `buyAndBurn`: a non-buyer is refused; a partial buy at burnPercent 50 and the remainder
///              at the default 100 move NFTStaker's phUSD, the phUSD supply and both reserves exactly
///              by the documented split.
contract AcceptNudgeDiscountLocal is Script {
    uint256 internal constant IDX = 4;
    uint256 internal constant WAD = 1e18;

    struct Env {
        BatchNFTMinterNudgeDiscount m;
        NFTMinterV2 nft;
        NudgeStreamer streamer;
        MockRewardToken usdc;
        MockUSDS usds;
        IERC20 phUSD;
        IERC4626 susds;
        MockSkyPSM psm;
        address hook;
        address nftStaker;
        address router;
        address pair;
        address owner;
    }

    /// @dev `previewBoost()`'s return tuple, field for field in the contract's order.
    struct Boost {
        uint256 overflowFree;
        uint8 boost;
        uint8 effectivePercent;
        uint256 reservedUSDC;
    }

    /// @dev The spec-maths expectation for one batch.
    struct Expect {
        uint256 p0;
        uint256 g;
        uint256 potUSDC;
        uint256 potUSD;
        uint256 free;
        uint256 total;
        uint256 paid;
        uint256 paidCost;
        uint256 owed;
    }

    Env internal e;
    address internal donor = vm.addr(uint256(keccak256("story-118 nudge-discount donor")));
    address internal user = vm.addr(uint256(keccak256("story-118 nudge-discount batcher")));
    address internal stranger = vm.addr(uint256(keccak256("story-118 nudge-discount non-buyer")));

    function run() external {
        require(block.chainid == 31337, "AcceptNudgeDiscountLocal: local only");
        _load();

        _checkPair();
        console.log("1. phUSD/sUSDS pair reserves non-zero on both sides");

        // 2 + 3. Pot examples at the default d = 50 (scaled to the live P0).
        require(e.m.discountPercent() == 50 && e.m.burnPercent() == 100, "defaults: discount 50 / burn 100");
        require(e.m.maxBoost() == 0, "boost ships disabled (nft-staking:034 default)");
        _scenario(2, 1, true); //   pot 1.0 x P0 -> 1 free + 1 paid (stale-total + second-batch reverts)
        _scenario(3, 1, false); //  pot 1.5 x P0 -> still 1 free + 1 paid; the whole pot is reserved
        _scenario(4, 2, false); //  pot 2.0 x P0 -> 2 free + 2 paid

        // d = 75, pot 2 x P0: total = ceil(200 / 75) = 3 (a floor would give 2 and no paid mint).
        vm.prank(e.owner);
        e.m.setDiscountPercent(75);
        _scenario(4, 2, false);
        vm.prank(e.owner);
        e.m.setDiscountPercent(50);
        console.log("2-3. previewBatch matches the spec maths; batchMint free/paid, price, bonus, reserves all exact");

        // Owner-side percent bounds (nft-staking:034 L-04): {0} or 50..99.
        _probePercentBounds();

        // Cap / overflow-boost scenario (nft-staking:034 M-01), then the 50/3/0 defaults restored.
        _capBoostScenario();

        // 4. buyAndBurn.
        _buyAndBurnChecks();
        console.log("ACCEPTANCE PASSED");
    }

    // ------------------------------------------------------------------ setup

    function _load() internal {
        string memory json = vm.readFile("server/deployments/progress.31337.json");
        e.m = BatchNFTMinterNudgeDiscount(_addr(json, "NudgeDiscountBatchMinter"));
        e.nft = NFTMinterV2(_addr(json, "NFTMinterV2"));
        e.streamer = NudgeStreamer(_addr(json, "NudgeStreamer"));
        e.usdc = MockRewardToken(_addr(json, "MockUSDC"));
        e.usds = MockUSDS(_addr(json, "MockUSDS"));
        e.phUSD = IERC20(_addr(json, "MockPhUSD"));
        e.susds = IERC4626(_addr(json, "MockSUSDS"));
        e.psm = MockSkyPSM(_addr(json, "MockSkyPSM"));
        e.hook = _addr(json, "BalancerPoolerMintDebtHook");
        e.nftStaker = _addr(json, "NFTStaker");
        e.router = _addr(json, "UniswapV2Router02");
        e.pair = _addr(json, "PhusdSusdsPair");
        e.owner = e.m.owner();

        require(address(e.m).code.length > 0, "no code at NudgeDiscountBatchMinter");
        require(address(e.m.discountToken()) == address(e.usdc), "discount token is not MockUSDC");
        require(address(e.m.psm()) == address(e.psm) && address(e.m.sUSDS()) == address(e.susds), "psm / sUSDS");
        require(e.m.router() == e.router && e.m.pair() == e.pair && e.m.phUSD() == address(e.phUSD), "swap route");
        require(address(e.m.mintDebtHook()) == e.hook && e.m.nftStaker() == e.nftStaker, "hook / staker");
        require(e.nft.authorizedMinters(address(e.m)), "minter lacks mintFor authority");
        console.log("NudgeDiscountBatchMinter:", address(e.m));
    }

    function _addr(string memory json, string memory key) internal pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(".contracts.", key, ".address"));
    }

    function _checkPair() internal view {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(e.pair).getReserves();
        require(r0 > 0 && r1 > 0, "phUSD/sUSDS pair has an empty side");
        console.log("  pair reserves:", uint256(r0), uint256(r1));
    }

    // ------------------------------------------------------------------ pot control

    /// @dev Advance past every stream window, so the whole buffer is pending.
    function _drainStreams() internal {
        // Stream is (duration, buffer, rewardPerSecond, lastUpdate): the window is the FIRST field.
        (uint256 duration,,,) = e.streamer.streams(address(e.m), address(e.usdc));
        require(duration > 0 && duration <= 30 days, "USDC stream duration out of range");
        vm.warp(vm.getBlockTimestamp() + 2 * duration + 1);
    }

    /// @dev The live pot exactly as the minter computes it for a batch: balance - reserve + pending.
    function _livePotUSDC() internal view returns (uint256) {
        return e.usdc.balanceOf(address(e.m)) - e.m.pendingBuyUSDC()
            + e.streamer.pendingStream(address(e.m), address(e.usdc));
    }

    /// @dev Brings the pot to exactly `ceil(halfSteps * P0 / 2)` USD of USDC: drains any organic pot
    ///      (donor inflow since the deploy, and this script's own paid-mint donations) through
    ///      throwaway batches until it is below one step, then tops it up through the stream.
    function _setPot(uint256 halfSteps) internal {
        _drainStreams();
        for (uint256 guard; guard < 8; ++guard) {
            (uint256 free, uint256 total,, uint256 paidCost,,,) = e.m.previewBatch();
            if (free == 0) break;
            _batch(total, _boost().boost, paidCost);
            _drainStreams();
        }
        uint256 pot = _livePotUSDC();
        (, uint256 p0,,) = e.nft.configs(IDX);
        uint256 conv = e.psm.to18ConversionFactor();
        uint256 tin = e.psm.tin();
        // Smallest USDC whose net PSM USD reaches halfSteps * P0 / 2.
        uint256 targetUSD = Math.ceilDiv(halfSteps * p0, 2);
        uint256 target = Math.ceilDiv(Math.mulDiv(targetUSD, WAD, WAD - tin, Math.Rounding.Ceil), conv);
        require(target > pot, "organic pot already above the scenario target");
        uint256 topUp = target - pot;

        e.usdc.mint(donor, topUp);
        vm.startPrank(donor);
        e.usdc.approve(address(e.streamer), topUp);
        e.streamer.collectNudge(address(e.m), address(e.usdc), topUp);
        vm.stopPrank();
        _drainStreams();
        require(_livePotUSDC() == target, "pot did not land at the scenario target");
    }

    /// @dev `previewBoost()` in the contract's own field order.
    function _boost() internal view returns (Boost memory b) {
        (b.overflowFree, b.boost, b.effectivePercent, b.reservedUSDC) = e.m.previewBoost();
    }

    // ------------------------------------------------------------------ batch scenarios

    /// @dev Spec maths, independent of the contract's own `_computeBatch`.
    function _expect() internal view returns (Expect memory x) {
        (, x.p0, x.g,) = e.nft.configs(IDX);
        x.potUSDC = _livePotUSDC();
        uint256 gross = x.potUSDC * e.psm.to18ConversionFactor();
        x.potUSD = gross - (gross * e.psm.tin()) / WAD;
        uint256 d = e.m.discountPercent();
        x.free = x.potUSD / x.p0;
        uint256 cap = e.m.maxFreePerBatch();
        require(x.free <= cap, "scenario pot exceeds maxFreePerBatch");
        x.total = Math.ceilDiv(x.free * 100, d);
        x.paid = x.total - x.free;
        uint256 price = x.p0;
        for (uint256 i; i < x.paid; ++i) {
            x.paidCost += price;
            price = price + (price * x.g) / 10_000;
        }
        x.owed = (x.free * x.p0 * IMintDebtRatioView(e.hook).ratio()) / 100;
    }

    function _scenario(uint256 halfSteps, uint256 wantFree, bool probeReverts) internal {
        _setPot(halfSteps);
        Expect memory x = _expect();
        require(x.free == wantFree, "scenario free count");
        if (e.m.discountPercent() == 50) {
            require(x.total == 2 * wantFree, "d=50: total must be 2 x free");
        } else {
            require(x.total == 3 && x.paid == 1, "d=75, 2 free: ceil(200/75) = 3, paid 1");
        }

        // previewBatch == spec maths.
        (uint256 free, uint256 total, uint256 paid, uint256 paidCost, uint256 owed, uint256 potUSD,) =
            e.m.previewBatch();
        require(free == x.free && total == x.total && paid == x.paid, "previewBatch counts != spec");
        require(paidCost == x.paidCost, "previewBatch paidCost != spec");
        require(owed == x.owed, "previewBatch owed != spec");
        require(potUSD == x.potUSD, "previewBatch potUSD != spec");
        Boost memory b = _boost();
        require(b.overflowFree == 0 && b.boost == 0, "no overflow / boost below the cap");
        require(b.effectivePercent == e.m.discountPercent(), "effective percent == discountPercent");
        require(b.reservedUSDC == x.potUSDC, "below the cap the whole pot is reserved");

        if (probeReverts) {
            _probeStaleTotal(x);
            _probeBatchReverts(x);
        }

        uint256 reserveBefore = e.m.pendingBuyUSDC();
        uint256 owedBefore = e.m.pendingStakerPhUSD();
        uint256 nftBefore = IERC1155(address(e.nft)).balanceOf(user, IDX);
        uint256 usdcBefore = e.usdc.balanceOf(user);
        (, uint256[] memory floors, uint256[] memory bonusBefore) = _bonusFloors();

        // The LIVE quote, never a literal: previewBoost().boost.
        uint256 spent = _batch(x.total, _boost().boost, x.paidCost);

        require(IERC1155(address(e.nft)).balanceOf(user, IDX) == nftBefore + x.total, "NFTs != free + paid");
        (, uint256 priceAfter,,) = e.nft.configs(IDX);
        uint256 p = x.p0;
        for (uint256 i; i < x.paid; ++i) {
            p = p + (p * x.g) / 10_000;
        }
        require(priceAfter == p, "price must move by exactly `paid` growth steps (free mints do not move it)");
        require(spent == x.paidCost, "caller must pay exactly paidCost");
        require(e.usdc.balanceOf(user) == usdcBefore, "the batcher must receive no USDC");
        _checkBonusPaid(floors, bonusBefore);
        require(e.m.pendingBuyUSDC() == reserveBefore + x.potUSDC, "reserve must rise by the whole pot");
        require(e.m.pendingStakerPhUSD() == owedBefore + x.owed, "owed must rise by `owed`");
        require(e.usdc.balanceOf(address(e.m)) == e.m.pendingBuyUSDC(), "minter USDC must equal the reserve");

        if (probeReverts) _probeSecondBatch();
        console.log("  batch ok: free / paid", x.free, x.paid);
    }

    /// @dev Mints a batch for `user` at `maxPayment = paidCost * 101%`; returns the measured spend.
    ///      `bonusTokens` and `bonusMinRewards` come from the SAME `getBonusTokens()` read; each floor
    ///      is the token's on-chain balance plus its pending stream (what step 3's flush delivers).
    function _batch(uint256 total, uint8 boost, uint256 paidCost) internal returns (uint256 spent) {
        (spent,,) = _batchFull(total, boost, paidCost);
    }

    /// @dev `_batch`, also returning `batchMint`'s `free` and `paid`.
    function _batchFull(uint256 total, uint8 boost, uint256 paidCost)
        internal
        returns (uint256 spent, uint256 free, uint256 paid)
    {
        uint256 maxPayment = paidCost + paidCost / 100;
        e.usds.mint(user, maxPayment);
        (address[] memory tokens, uint256[] memory mins,) = _bonusFloors();
        uint256 before = e.usds.balanceOf(user);
        vm.startPrank(user);
        e.usds.approve(address(e.m), maxPayment);
        uint256 totalPaid;
        (totalPaid, free, paid) = e.m.batchMint(total, boost, user, maxPayment, tokens, mins);
        vm.stopPrank();
        spent = before - e.usds.balanceOf(user);
        require(totalPaid == spent, "batchMint totalPaid != measured spend");
    }

    /// @dev Floors = on-chain balance + pending stream, per `getBonusTokens()` entry.
    function _bonusFloors()
        internal
        view
        returns (address[] memory tokens, uint256[] memory floors, uint256[] memory userBefore)
    {
        tokens = e.m.getBonusTokens();
        floors = new uint256[](tokens.length);
        userBefore = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            floors[i] = IERC20(tokens[i]).balanceOf(address(e.m)) + e.streamer.pendingStream(address(e.m), tokens[i]);
            userBefore[i] = IERC20(tokens[i]).balanceOf(user);
        }
    }

    function _checkBonusPaid(uint256[] memory floors, uint256[] memory userBefore) internal view {
        address[] memory tokens = e.m.getBonusTokens();
        for (uint256 i; i < tokens.length; ++i) {
            require(IERC20(tokens[i]).balanceOf(user) - userBefore[i] >= floors[i], "bonus paid below its floor");
            require(
                IERC20(tokens[i]).balanceOf(address(e.m)) + e.streamer.pendingStream(address(e.m), tokens[i]) == 0,
                "bonus balance + pending stream must be zero after a batch"
            );
        }
    }

    function _probeStaleTotal(Expect memory x) internal {
        uint256 maxPayment = x.paidCost * 2;
        e.usds.mint(user, maxPayment);
        address[] memory tokens = e.m.getBonusTokens();
        uint256[] memory mins = new uint256[](tokens.length);
        vm.startPrank(user);
        e.usds.approve(address(e.m), maxPayment);
        try e.m.batchMint(x.total + 1, 0, user, maxPayment, tokens, mins) {
            revert("stale expectedTotal must revert");
        } catch (bytes memory err) {
            require(bytes4(err) == BatchNFTMinterNudgeDiscount.BatchMint__TotalMismatch.selector, "want TotalMismatch");
        }
        e.usds.approve(address(e.m), 0);
        vm.stopPrank();
        console.log("  stale expectedTotal reverts TotalMismatch");
    }

    function _probeSecondBatch() internal {
        (uint256 free,,,,,,) = e.m.previewBatch();
        require(free == 0, "pot must be fully consumed by the batch");
        address[] memory tokens = e.m.getBonusTokens();
        uint256[] memory mins = new uint256[](tokens.length);
        vm.prank(user);
        try e.m.batchMint(1, 0, user, 0, tokens, mins) {
            revert("an immediate second batch must revert");
        } catch (bytes memory err) {
            require(
                bytes4(err) == BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector,
                "want NoDiscountAvailable"
            );
        }
        console.log("  immediate second batch reverts NoDiscountAvailable (free == 0)");
    }


    /// @dev Reverts a pranked call must hit, matched on the custom-error selector.
    function _expectRevert(address caller, bytes memory data, bytes4 want, string memory what) internal {
        vm.prank(caller);
        (bool ok, bytes memory err) = address(e.m).call(data);
        require(!ok, string.concat(what, ": call must revert"));
        require(err.length >= 4 && bytes4(err) == want, string.concat(what, ": wrong revert"));
        console.log("  reverts as required:", what);
    }

    /// @dev Gap 9: the batchMint argument probes, with a funded pot and the live boost at 0.
    function _probeBatchReverts(Expect memory x) internal {
        address[] memory tokens = e.m.getBonusTokens();
        require(tokens.length == 2, "expected two bonus tokens [phUSD, Kendu]");
        uint256[] memory mins = new uint256[](2);

        address[] memory swapped = new address[](2);
        swapped[0] = tokens[1];
        swapped[1] = tokens[0];
        _expectRevert(
            user,
            abi.encodeCall(e.m.batchMint, (x.total, 0, user, x.paidCost * 2, swapped, mins)),
            BatchNFTMinterNudgeDiscount.BatchMint__BonusTokenMismatch.selector,
            "bonusTokens in swapped order -> BatchMint__BonusTokenMismatch"
        );

        uint256[] memory shortMins = new uint256[](1);
        _expectRevert(
            user,
            abi.encodeCall(e.m.batchMint, (x.total, 0, user, x.paidCost * 2, tokens, shortMins)),
            BatchNFTMinterNudgeDiscount.BatchMint__ArrayLengthMismatch.selector,
            "bonusMinRewards one short -> BatchMint__ArrayLengthMismatch"
        );

        require(_boost().boost == 0, "live boost must be 0 for the BoostNotAvailable probe");
        _expectRevert(
            user,
            abi.encodeCall(e.m.batchMint, (x.total, 1, user, x.paidCost * 2, tokens, mins)),
            BatchNFTMinterNudgeDiscount.BatchMint__BoostNotAvailable.selector,
            "quotedBoost 1 above live 0 -> BatchMint__BoostNotAvailable"
        );
    }

    /// @dev Gap 9: `setDiscountPercent` is bounded to {0} or 50..99.
    function _probePercentBounds() internal {
        _expectRevert(
            e.owner,
            abi.encodeCall(e.m.setDiscountPercent, (30)),
            BatchNFTMinterNudgeDiscount.BatchMint__PercentTooLow.selector,
            "setDiscountPercent(30) -> BatchMint__PercentTooLow"
        );
        _expectRevert(
            e.owner,
            abi.encodeCall(e.m.setDiscountPercent, (100)),
            BatchNFTMinterNudgeDiscount.BatchMint__PercentTooHigh.selector,
            "setDiscountPercent(100) -> BatchMint__PercentTooHigh"
        );
        require(e.m.discountPercent() == 50, "discountPercent unchanged by the refused setters");
        console.log("2b. percent bounds enforced: 30 and 100 refused");
    }

    // ------------------------------------------------------------------ cap / boost

    uint256 internal constant CAP_SCENARIO_CAP = 2;
    uint256 internal constant CAP_SCENARIO_PER_POINT = 1;
    uint8 internal constant CAP_SCENARIO_MAX_BOOST = 10;
    uint256 internal constant CAP_SCENARIO_HALF_STEPS = 10; // pot = 5 x P0 -> potFree 5, overflow 3

    /// @dev Spec maths for a capped batch at an arbitrary boost.
    struct CapExpect {
        uint256 p0;
        uint256 g;
        uint256 potUSDC;
        uint256 potUSD;
        uint256 overflowFree;
        uint8 liveBoost;
        uint256 reserved;
    }

    function _capExpect() internal view returns (CapExpect memory c) {
        (, c.p0, c.g,) = e.nft.configs(IDX);
        c.potUSDC = _livePotUSDC();
        uint256 gross = c.potUSDC * e.psm.to18ConversionFactor();
        c.potUSD = gross - (gross * e.psm.tin()) / WAD;
        uint256 potFree = c.potUSD / c.p0;
        require(potFree > CAP_SCENARIO_CAP, "cap scenario: pot must exceed the cap");
        c.overflowFree = potFree - CAP_SCENARIO_CAP;
        uint256 live = c.overflowFree / CAP_SCENARIO_PER_POINT;
        if (live > CAP_SCENARIO_MAX_BOOST) live = CAP_SCENARIO_MAX_BOOST;
        c.liveBoost = uint8(live);
        c.reserved = Math.mulDiv(c.potUSDC, CAP_SCENARIO_CAP * c.p0, c.potUSD, Math.Rounding.Ceil);
    }

    function _effective(uint256 boost) internal view returns (uint8) {
        uint256 eff = uint256(e.m.discountPercent()) + boost;
        return uint8(eff > 99 ? 99 : eff);
    }

    function _rampCost(uint256 p0, uint256 g, uint256 n) internal pure returns (uint256 cost) {
        uint256 price = p0;
        for (uint256 i; i < n; ++i) {
            cost += price;
            price = price + (price * g) / 10_000;
        }
    }

    /// @dev Finds `TempDiscountApplied` from the minter in the recorded logs.
    function _tempDiscount(Vm.Log[] memory logs)
        internal
        view
        returns (bool found, uint256 overflowFree, uint8 boost, uint8 effective)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(e.m) && logs[i].topics.length > 0
                    && logs[i].topics[0] == BatchNFTMinterNudgeDiscount.TempDiscountApplied.selector
            ) {
                require(!found, "TempDiscountApplied emitted twice");
                found = true;
                (overflowFree, boost, effective) = abi.decode(logs[i].data, (uint256, uint8, uint8));
            }
        }
    }

    /// @dev Gap 10 (story 118 §5 step 6): a pot above a lowered cap, with a non-zero boost.
    function _capBoostScenario() internal {
        _setPot(CAP_SCENARIO_HALF_STEPS); // at the 50-cap defaults: an ordinary 5 x P0 pot
        vm.startPrank(e.owner);
        e.m.setMaxFreePerBatch(CAP_SCENARIO_CAP);
        e.m.setOverflowNFTsPerBoostPoint(CAP_SCENARIO_PER_POINT);
        e.m.setMaxBoost(CAP_SCENARIO_MAX_BOOST);
        vm.stopPrank();

        CapExpect memory c = _capExpect();
        require(c.liveBoost >= 1, "cap scenario: live boost must be at least 1");
        uint8 eff = _effective(c.liveBoost);
        uint256 total = Math.ceilDiv(CAP_SCENARIO_CAP * 100, eff);

        Boost memory b = _boost();
        require(b.overflowFree == c.overflowFree, "previewBoost overflowFree != spec");
        require(b.boost == c.liveBoost, "previewBoost boost != min(maxBoost, overflowFree / perPoint)");
        require(b.effectivePercent == eff, "previewBoost effectivePercent != min(d + boost, 99)");
        require(b.reservedUSDC == c.reserved, "previewBoost reservedUSDC != mulDiv(pot, cap * P0, potUSD, Ceil)");
        require(c.reserved < c.potUSDC, "capped reserve must be less than the whole pot");
        (uint256 pFree, uint256 pTotal, uint256 pPaid, uint256 pCost,,,) = e.m.previewBatch();
        require(pFree == CAP_SCENARIO_CAP && pTotal == total && pPaid == total - pFree, "previewBatch capped counts");
        require(pCost == _rampCost(c.p0, c.g, pPaid), "previewBatch capped paidCost");
        console.log("5. cap scenario: overflowFree / liveBoost", c.overflowFree, uint256(c.liveBoost));

        _lowerQuoteHonoured(c);

        // The boosted batch at the live quote.
        uint256 reserveBefore = e.m.pendingBuyUSDC();
        uint256 nftBefore = IERC1155(address(e.nft)).balanceOf(user, IDX);
        vm.recordLogs();
        (, uint256 free, uint256 paid) = _batchFull(total, b.boost, pCost);
        (bool found, uint256 lOverflow, uint8 lBoost, uint8 lEff) = _tempDiscount(vm.getRecordedLogs());
        require(free == CAP_SCENARIO_CAP, "free must equal maxFreePerBatch");
        require(free + paid == total, "batch total at the live boost");
        require(IERC1155(address(e.nft)).balanceOf(user, IDX) == nftBefore + total, "NFTs != capped total");
        require(found, "TempDiscountApplied must be emitted for a non-zero boost");
        require(lOverflow == c.overflowFree && lBoost == c.liveBoost && lEff == eff, "TempDiscountApplied args");
        require(e.m.pendingBuyUSDC() == reserveBefore + c.reserved, "reserve must rise by the capped mulDiv");
        require(e.m.availablePotUSDC() == c.potUSDC - c.reserved, "the unreserved remainder must stay as pot");
        console.log("  capped batch ok: total / reserved / remainder", total, c.reserved, c.potUSDC - c.reserved);

        // Restore the mainnet day-one defaults and read them back.
        vm.startPrank(e.owner);
        e.m.setMaxBoost(0);
        e.m.setOverflowNFTsPerBoostPoint(3);
        e.m.setMaxFreePerBatch(50);
        vm.stopPrank();
        require(
            e.m.maxFreePerBatch() == 50 && e.m.overflowNFTsPerBoostPoint() == 3 && e.m.maxBoost() == 0,
            "cap/boost defaults 50/3/0 not restored"
        );
        console.log("  cap/boost restored and read back: 50 / 3 / 0");
    }

    /// @dev A quote of `liveBoost - 1` is honoured at the quoted (worse) terms; run inside a state
    ///      snapshot so the boosted batch that follows sees the same pot.
    function _lowerQuoteHonoured(CapExpect memory c) internal {
        uint256 snap = vm.snapshotState();
        uint8 q = c.liveBoost - 1;
        uint8 qEff = _effective(q);
        uint256 qTotal = Math.ceilDiv(CAP_SCENARIO_CAP * 100, qEff);
        uint256 qCost = _rampCost(c.p0, c.g, qTotal - CAP_SCENARIO_CAP);
        uint256 nftBefore = IERC1155(address(e.nft)).balanceOf(user, IDX);

        vm.recordLogs();
        (uint256 spent, uint256 free, uint256 paid) = _batchFull(qTotal, q, qCost);
        (bool found,, uint8 lBoost, uint8 lEff) = _tempDiscount(vm.getRecordedLogs());
        require(free == CAP_SCENARIO_CAP, "lower quote: free unchanged");
        require(free + paid == qTotal, "lower quote: total at the quoted terms");
        require(spent == qCost, "lower quote: paid the quoted paidCost");
        require(IERC1155(address(e.nft)).balanceOf(user, IDX) == nftBefore + qTotal, "lower quote: NFTs");
        if (q == 0) {
            require(!found, "lower quote 0: TempDiscountApplied must NOT be emitted");
        } else {
            require(found && lBoost == q && lEff == qEff, "lower quote: TempDiscountApplied at the quoted boost");
        }
        console.log("  lower quote honoured: quotedBoost / total", uint256(q), qTotal);
        require(vm.revertToState(snap), "snapshot revert failed");
    }

    // ------------------------------------------------------------------ buyAndBurn

    function _buyAndBurnChecks() internal {
        uint256 reserve = e.m.pendingBuyUSDC();
        require(reserve > 0 && e.m.pendingStakerPhUSD() > 0, "nothing reserved to buy");
        uint256 minterUsdcBefore = e.usdc.balanceOf(address(e.m));

        // A non-buyer is refused.
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        vm.prank(stranger);
        try e.m.buyAndBurn(reserve, 1, deadline) {
            revert("a non-buyer must be refused");
        } catch (bytes memory err) {
            require(
                bytes4(err) == BatchNFTMinterNudgeDiscount.BatchMint__UnauthorizedBuyer.selector, "want UnauthorizedBuyer"
            );
        }
        console.log("4. non-buyer buyAndBurn reverts UnauthorizedBuyer");

        // Partial buy at burnPercent 50 exercises the split, then the rest at the default 100.
        vm.prank(e.owner);
        e.m.setBurnPercent(50);
        _buy(reserve / 2, 50);
        vm.prank(e.owner);
        e.m.setBurnPercent(100);
        _buy(e.m.pendingBuyUSDC(), 100);
        require(e.m.pendingBuyUSDC() == 0, "reserve fully spent");
        // Only the reserve is spent; the unreserved remainder left by the capped batch stays as pot.
        require(
            e.usdc.balanceOf(address(e.m)) == minterUsdcBefore - reserve, "buyAndBurn must spend exactly the reserve"
        );
    }

    function _buy(uint256 usdcIn, uint256 burnPct) internal {
        uint256 expectedOut = _quote(usdcIn);
        uint256 minOut = (expectedOut * 99) / 100;
        uint256 owedBefore = e.m.pendingStakerPhUSD();
        uint256 reserveBefore = e.m.pendingBuyUSDC();
        uint256 stakerBefore = e.phUSD.balanceOf(e.nftStaker);
        uint256 supplyBefore = e.phUSD.totalSupply();
        uint256 minterPhBefore = e.phUSD.balanceOf(address(e.m));

        vm.prank(e.owner); // the deployer is the authorised buyer
        (uint256 out, uint256 toStaker, uint256 burned) =
            e.m.buyAndBurn(usdcIn, minOut, vm.getBlockTimestamp() + 1 hours);

        uint256 toStakerOwed = out < owedBefore ? out : owedBefore;
        uint256 extra = out - toStakerOwed;
        uint256 wantBurn = (extra * burnPct) / 100;
        require(out == expectedOut, "phUSD out != router quote");
        require(out >= minOut, "out below the 1% floor");
        require(burned == wantBurn, "burned != extra * burnPercent / 100");
        require(toStaker == toStakerOwed + (extra - wantBurn), "toStaker != owed + unburned extra");
        require(e.phUSD.balanceOf(e.nftStaker) - stakerBefore == toStaker, "NFTStaker phUSD delta");
        require(supplyBefore - e.phUSD.totalSupply() == wantBurn, "phUSD supply must fall by the burn");
        require(e.m.pendingBuyUSDC() == reserveBefore - usdcIn, "reserve must fall by usdcIn");
        require(e.m.pendingStakerPhUSD() == owedBefore - toStakerOwed, "owed must fall by toStakerOwed");
        require(e.phUSD.balanceOf(address(e.m)) == minterPhBefore, "bought phUSD must not stay on the minter");
        console.log("  buyAndBurn ok: usdcIn / phUSD out", usdcIn, out);
        console.log("    to NFTStaker / burned", toStaker, burned);
    }

    /// @dev USDC -> PSM (tin) -> USDS -> sUSDS deposit -> UniV2 quote, all at this block.
    function _quote(uint256 usdcIn) internal view returns (uint256) {
        uint256 gross = usdcIn * e.psm.to18ConversionFactor();
        uint256 usdsOut = gross - (gross * e.psm.tin()) / WAD;
        uint256 shares = e.susds.previewDeposit(usdsOut);
        address[] memory path = new address[](2);
        path[0] = address(e.susds);
        path[1] = address(e.phUSD);
        return IUniswapV2RouterAmountsOut(e.router).getAmountsOut(shares, path)[1];
    }
}
