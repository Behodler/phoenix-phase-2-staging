// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniswapV2Deployer, IUniswapV2FactoryLike, IUniswapV2RouterLike} from "../script/helpers/UniswapV2Deployer.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSUSDS} from "../src/mocks/MockSUSDS.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";

/// @title  AntimatterPoolSeederTest
/// @notice Story 113. The seeder against the canonical Uniswap V2 bytecode, the real Antimatter,
///         MockPhUSD (FlaxToken burn semantics) and MockSUSDS (non-unit share price).
contract AntimatterPoolSeederTest is Test {
    uint256 internal constant SEED_PHUSD = 200_000e18;
    uint256 internal constant SEED_USDS = 190_000e18;

    MockPhUSD internal phUSD;
    MockUSDS internal usds;
    MockSUSDS internal susds;
    Antimatter internal am;
    IUniswapV2FactoryLike internal factory;
    IUniswapV2RouterLike internal router;
    address internal pair;
    AntimatterPoolSeeder internal seeder;

    address internal owner = makeAddr("owner");
    address internal pooler = makeAddr("pooler"); // stands in for UniPoolerV2 (the LP holder)
    address internal recipient = makeAddr("recipient");

    event Seeded(
        uint256 lpAmount,
        uint256 phusdBurned,
        uint256 amMinted,
        uint256 susdsPaired,
        uint256 liquidity,
        address indexed lpRecipient
    );

    function setUp() public {
        (, factory, router) = UniswapV2Deployer.deploy(address(this));
        phUSD = new MockPhUSD();
        phUSD.setMinter(address(this), true);
        usds = new MockUSDS();
        susds = new MockSUSDS(address(usds));
        am = new Antimatter(address(this));

        // Non-unit sUSDS share price, as on mainnet.
        usds.mint(address(this), 1_000_000e18);
        usds.approve(address(susds), type(uint256).max);
        susds.deposit(10_000e18, address(this));
        susds.addYield(537e18 + 7);

        // Protocol-owned phUSD/sUSDS LP, held by the pooler stand-in.
        uint256 shares = susds.deposit(SEED_USDS, address(this));
        phUSD.mint(address(this), SEED_PHUSD);
        pair = factory.createPair(address(susds), address(phUSD));
        IERC20(address(susds)).approve(address(router), type(uint256).max);
        phUSD.approve(address(router), type(uint256).max);
        router.addLiquidity(address(susds), address(phUSD), shares, SEED_PHUSD, 0, 0, pooler, block.timestamp);

        seeder =
            new AntimatterPoolSeeder(owner, address(phUSD), address(susds), address(am), address(router), pair, pooler);
        am.setApprovedMinter(address(seeder), true);
        assertTrue(am.isApprovedMinter(address(seeder)));
    }

    // ============ helpers ============

    /// @dev Mirrors the mainnet owner sequence: rescue LP from the pooler, approve the seeder.
    function _rescueAndApprove(uint256 lpAmount) internal {
        vm.prank(pooler);
        IERC20(pair).transfer(owner, lpAmount);
        vm.prank(owner);
        IERC20(pair).approve(address(seeder), lpAmount);
    }

    function _seed(uint256 lpAmount) internal returns (uint256 burned, uint256 liquidity) {
        _rescueAndApprove(lpAmount);
        vm.prank(owner);
        (burned, liquidity) = seeder.seed(lpAmount, 0, 0, recipient, block.timestamp);
    }

    /// @dev phUSD and sUSDS a burn of `lpAmount` would release (UniswapV2Pair.burn arithmetic, no fee-on).
    function _expectedOut(uint256 lpAmount) internal view returns (uint256 phusdOut, uint256 susdsOut) {
        uint256 supply = IERC20(pair).totalSupply();
        phusdOut = lpAmount * phUSD.balanceOf(pair) / supply;
        susdsOut = lpAmount * susds.balanceOf(pair) / supply;
    }

    function _assertSeederEmpty() internal view {
        assertEq(phUSD.balanceOf(address(seeder)), 0, "seeder phUSD");
        assertEq(am.balanceOf(address(seeder)), 0, "seeder AM");
        assertEq(susds.balanceOf(address(seeder)), 0, "seeder sUSDS");
        assertEq(IERC20(pair).balanceOf(address(seeder)), 0, "seeder old LP");
        address amPair = seeder.amSusdsPair();
        if (amPair != address(0)) assertEq(IERC20(amPair).balanceOf(address(seeder)), 0, "seeder new LP");
    }

    // ============ happy path ============

    function test_seed_createsPair_burnsPhUSD_mintsAM_oneToOne() public {
        uint256 lpAmount = seeder.lpForBps(2_500);
        (uint256 phusdOut, uint256 susdsOut) = _expectedOut(lpAmount);
        uint256 phSupply = phUSD.totalSupply();
        uint256 amSupply = am.totalSupply();
        assertEq(seeder.amSusdsPair(), address(0), "pair absent before");

        _rescueAndApprove(lpAmount);
        // First mint into an empty pair: sqrt(a*b) - MINIMUM_LIQUIDITY.
        uint256 expectedLiquidity = Math.sqrt(phusdOut * susdsOut) - 1_000;
        vm.expectEmit(true, false, false, true, address(seeder));
        emit Seeded(lpAmount, phusdOut, phusdOut, susdsOut, expectedLiquidity, recipient);
        vm.prank(owner);
        (uint256 burned, uint256 liquidity) = seeder.seed(lpAmount, phusdOut, susdsOut, recipient, block.timestamp);

        address amPair = seeder.amSusdsPair();
        assertTrue(amPair != address(0), "pair created");
        assertEq(amPair, factory.getPair(address(susds), address(am)), "canonical pair");
        assertEq(burned, phusdOut, "burned == phUSD out");
        assertEq(phSupply - phUSD.totalSupply(), burned, "phUSD supply drops by exactly AM minted");
        assertEq(am.totalSupply() - amSupply, phusdOut, "AM supply rises by exactly phUSD out");
        assertEq(am.balanceOf(amPair), phusdOut, "all AM in the pair");
        assertEq(susds.balanceOf(amPair), susdsOut, "all sUSDS in the new pair (empty pair)");
        assertEq(liquidity, expectedLiquidity);
        assertEq(IERC20(amPair).balanceOf(recipient), liquidity, "recipient holds the new LP");
        // AM/sUSDS opens at the phUSD/sUSDS market price.
        assertApproxEqRel(
            am.balanceOf(amPair) * 1e18 / susds.balanceOf(amPair),
            phUSD.balanceOf(pair) * 1e18 / susds.balanceOf(pair),
            1e12
        );
        _assertSeederEmpty();
    }

    function test_seed_secondSeedIntoExistingPair() public {
        _seed(seeder.lpForBps(1_000));
        address amPair = seeder.amSusdsPair();
        uint256 lpBefore = IERC20(amPair).balanceOf(recipient);
        uint256 amInPair = am.balanceOf(amPair);
        uint256 phSupply = phUSD.totalSupply();

        uint256 lpAmount = seeder.lpForBps(1_000);
        (uint256 phusdOut,) = _expectedOut(lpAmount);
        (uint256 burned, uint256 liquidity) = _seed(lpAmount);

        assertEq(seeder.amSusdsPair(), amPair, "same pair");
        assertEq(burned, phusdOut);
        assertEq(phSupply - phUSD.totalSupply(), burned);
        assertEq(am.balanceOf(amPair) - amInPair, phusdOut, "AM fully consumed");
        assertEq(IERC20(amPair).balanceOf(recipient), lpBefore + liquidity);
        _assertSeederEmpty();
    }

    function test_seed_unusedSUSDS_goesToRecipient() public {
        _seed(seeder.lpForBps(1_000));
        address amPair = seeder.amSusdsPair();
        // Make AM cheaper in sUSDS: sell AM into the AM/sUSDS pair (this test owns Antimatter).
        am.mint(address(this), 5_000e18);
        am.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(am);
        path[1] = address(susds);
        router.swapExactTokensForTokens(5_000e18, 0, path, address(this), block.timestamp);

        uint256 lpAmount = seeder.lpForBps(1_000);
        (uint256 phusdOut, uint256 susdsOut) = _expectedOut(lpAmount);
        uint256 recipientSusds = susds.balanceOf(recipient);
        uint256 susdsInPair = susds.balanceOf(amPair);
        _seed(lpAmount);

        uint256 paired = susds.balanceOf(amPair) - susdsInPair;
        assertLt(paired, susdsOut, "less sUSDS needed");
        assertEq(susds.balanceOf(recipient) - recipientSusds, susdsOut - paired, "leftover sUSDS to recipient");
        assertEq(am.balanceOf(address(seeder)), 0);
        assertGe(am.balanceOf(amPair), phusdOut);
        _assertSeederEmpty();
    }

    // ============ reverts ============

    function test_seed_revertsBelowMinPhUSD() public {
        uint256 lpAmount = seeder.lpForBps(1_000);
        (uint256 phusdOut,) = _expectedOut(lpAmount);
        _rescueAndApprove(lpAmount);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AntimatterPoolSeeder.InsufficientPhUSD.selector, phusdOut, phusdOut + 1));
        seeder.seed(lpAmount, phusdOut + 1, 0, recipient, block.timestamp);
    }

    function test_seed_revertsBelowMinSUSDS() public {
        uint256 lpAmount = seeder.lpForBps(1_000);
        (, uint256 susdsOut) = _expectedOut(lpAmount);
        _rescueAndApprove(lpAmount);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AntimatterPoolSeeder.InsufficientSUSDS.selector, susdsOut, susdsOut + 1));
        seeder.seed(lpAmount, 0, susdsOut + 1, recipient, block.timestamp);
    }

    function test_seed_revertsForNonOwner() public {
        uint256 lpAmount = seeder.lpForBps(1_000);
        vm.prank(pooler);
        IERC20(pair).approve(address(seeder), lpAmount);
        vm.prank(pooler);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pooler));
        seeder.seed(lpAmount, 0, 0, recipient, block.timestamp);
    }

    function test_rescue_revertsForNonOwner() public {
        vm.prank(pooler);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pooler));
        seeder.rescueERC20(address(phUSD), pooler, 0);
    }

    function test_seed_revertsWithoutApprovedMinter() public {
        am.setApprovedMinter(address(seeder), false);
        assertFalse(am.isApprovedMinter(address(seeder)));
        uint256 lpAmount = seeder.lpForBps(1_000);
        _rescueAndApprove(lpAmount);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Antimatter.NotApprovedMinter.selector, address(seeder)));
        seeder.seed(lpAmount, 0, 0, recipient, block.timestamp);
    }

    function test_seed_revertsWhenAntimatterNotFullyConsumed() public {
        _seed(seeder.lpForBps(1_000));
        address amPair = seeder.amSusdsPair();
        // Make AM dearer in sUSDS: buy AM out of the pair with sUSDS.
        address[] memory path = new address[](2);
        path[0] = address(susds);
        path[1] = address(am);
        router.swapExactTokensForTokens(susds.balanceOf(amPair) / 2, 0, path, address(this), block.timestamp);

        uint256 lpAmount = seeder.lpForBps(1_000);
        (uint256 phusdOut, uint256 susdsOut) = _expectedOut(lpAmount);
        (uint112 r0, uint112 r1,) = IUniswapV2PairReserves(amPair).getReserves();
        (uint256 rAm, uint256 rS) = address(am) < address(susds) ? (r0, r1) : (r1, r0);
        uint256 required = phusdOut * rS / rAm;
        assertGt(required, susdsOut);

        _rescueAndApprove(lpAmount);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AntimatterPoolSeeder.AntimatterNotFullyConsumed.selector, phusdOut, required, susdsOut
            )
        );
        seeder.seed(lpAmount, 0, 0, recipient, block.timestamp);
    }

    function test_seed_revertsAfterDeadline() public {
        uint256 lpAmount = seeder.lpForBps(1_000);
        _rescueAndApprove(lpAmount);
        vm.warp(1_000);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AntimatterPoolSeeder.Expired.selector, 999, 1_000));
        seeder.seed(lpAmount, 0, 0, recipient, 999);
    }

    function test_seed_revertsOnZeroInputs() public {
        vm.startPrank(owner);
        vm.expectRevert(AntimatterPoolSeeder.ZeroAmount.selector);
        seeder.seed(0, 0, 0, recipient, block.timestamp);
        vm.expectRevert(AntimatterPoolSeeder.ZeroAddress.selector);
        seeder.seed(1, 0, 0, address(0), block.timestamp);
        vm.stopPrank();
    }

    function test_constructor_rejectsNonCanonicalPair() public {
        vm.expectRevert(abi.encodeWithSelector(AntimatterPoolSeeder.PairMismatch.selector, pair, address(0xBEEF)));
        new AntimatterPoolSeeder(
            owner, address(phUSD), address(susds), address(am), address(router), address(0xBEEF), pooler
        );
    }

    // ============ one-sided (griefed) AM/sUSDS pair ============

    /// @dev The griefing front-run: create the AM/sUSDS pair, donate 1 wei of ONE token, sync().
    function _griefPair(bool donateSusds) internal returns (address amPair) {
        amPair = factory.createPair(address(am), address(susds));
        if (donateSusds) {
            IERC20(address(susds)).transfer(amPair, 1);
        } else {
            am.mint(address(this), 1); // test contract owns Antimatter
            IERC20(address(am)).transfer(amPair, 1);
        }
        IUniswapV2PairReserves(amPair).sync();
        (uint112 r0, uint112 r1,) = IUniswapV2PairReserves(amPair).getReserves();
        (uint256 rAm, uint256 rS) = address(am) < address(susds) ? (r0, r1) : (r1, r0);
        if (donateSusds) {
            assertEq(rAm, 0, "griefed: no AM reserve");
            assertEq(rS, 1, "griefed: 1 wei sUSDS reserve");
        } else {
            assertEq(rAm, 1, "griefed: 1 wei AM reserve");
            assertEq(rS, 0, "griefed: no sUSDS reserve");
        }
        assertEq(IERC20(amPair).totalSupply(), 0, "griefed: no LP supply");
        assertEq(seeder.amSusdsPair(), amPair);
    }

    function _assertGriefedSeed(bool donateSusds) internal {
        address amPair = _griefPair(donateSusds);
        uint256 lpAmount = seeder.lpForBps(2_500);
        (uint256 phusdOut, uint256 susdsOut) = _expectedOut(lpAmount);
        uint256 phSupply = phUSD.totalSupply();
        uint256 amSupply = am.totalSupply();
        uint256 amInPairBefore = am.balanceOf(amPair);
        uint256 susdsInPairBefore = susds.balanceOf(amPair);

        _rescueAndApprove(lpAmount);
        // The pair mints on balance - reserve, i.e. exactly what the seeder sends; the dust is ignored.
        uint256 expectedLiquidity = Math.sqrt(phusdOut * susdsOut) - 1_000;
        vm.expectEmit(true, false, false, true, address(seeder));
        emit Seeded(lpAmount, phusdOut, phusdOut, susdsOut, expectedLiquidity, recipient);
        vm.prank(owner);
        (uint256 burned, uint256 liquidity) = seeder.seed(lpAmount, phusdOut, susdsOut, recipient, block.timestamp);

        // Tax-neutral: phUSD burned == AM minted, with no AM minted outside the seed.
        assertEq(burned, phusdOut, "burned == phUSD out");
        assertEq(phSupply - phUSD.totalSupply(), burned, "phUSD supply drops by exactly AM minted");
        assertEq(am.totalSupply() - amSupply, burned, "AM supply rises by exactly phUSD burned");
        // Every unit consumed; donated dust absorbed into the pool.
        assertEq(am.balanceOf(amPair), amInPairBefore + phusdOut, "all AM in the pair");
        assertEq(susds.balanceOf(amPair), susdsInPairBefore + susdsOut, "all sUSDS in the pair");
        assertEq(liquidity, expectedLiquidity, "first-mint liquidity");
        assertEq(IERC20(amPair).balanceOf(recipient), liquidity, "recipient holds the new LP");
        assertEq(IERC20(amPair).totalSupply(), liquidity + 1_000, "recipient owns all non-locked LP");
        assertEq(susds.balanceOf(recipient), 0, "no unused sUSDS");
        _assertSeederEmpty();

        // The pair is now two-sided: a later seed goes through the router as normal.
        uint256 lp2 = seeder.lpForBps(1_000);
        (uint256 phusdOut2,) = _expectedOut(lp2);
        uint256 phSupply2 = phUSD.totalSupply();
        uint256 amSupply2 = am.totalSupply();
        (uint256 burned2, uint256 liquidity2) = _seed(lp2);
        assertEq(burned2, phusdOut2);
        assertEq(phSupply2 - phUSD.totalSupply(), burned2, "second seed: phUSD burned == AM minted");
        assertEq(am.totalSupply() - amSupply2, burned2, "second seed: AM minted == phUSD burned");
        assertGt(liquidity2, 0);
        _assertSeederEmpty();
    }

    function test_seed_oneSidedPair_susdsDust_mintsDirect() public {
        _assertGriefedSeed(true);
    }

    function test_seed_oneSidedPair_amDust_mintsDirect() public {
        _assertGriefedSeed(false);
    }

    /// @dev Canonical bytecode can never reach a one-sided reserve with LP outstanding; the guard is
    ///      exercised by mocking the pair's views.
    function test_seed_oneSidedPairWithSupply_revertsLoudly() public {
        address amPair = factory.createPair(address(am), address(susds));
        (uint112 r0, uint112 r1) = address(am) < address(susds) ? (uint112(0), uint112(5)) : (uint112(5), uint112(0));
        vm.mockCall(amPair, abi.encodeWithSignature("getReserves()"), abi.encode(r0, r1, uint32(0)));
        vm.mockCall(amPair, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(42)));

        uint256 lpAmount = seeder.lpForBps(1_000);
        _rescueAndApprove(lpAmount);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AntimatterPoolSeeder.OneSidedPair.selector, 0, 5, 42));
        seeder.seed(lpAmount, 0, 0, recipient, block.timestamp);
    }

    // ============ out-of-band balances and rescue ============

    function test_seed_toleratesDonations_andRescueRecovers() public {
        phUSD.mint(address(seeder), 7);
        uint256 lpAmount = seeder.lpForBps(1_000);
        (uint256 phusdOut,) = _expectedOut(lpAmount);
        (uint256 burned,) = _seed(lpAmount);
        assertEq(burned, phusdOut, "donation is not burned");
        assertEq(phUSD.balanceOf(address(seeder)), 7);
        vm.prank(owner);
        seeder.rescueERC20(address(phUSD), owner, 7);
        assertEq(phUSD.balanceOf(owner), 7);
        _assertSeederEmpty();
    }

    // ============ lpForBps ============

    function test_lpForBps_floors() public {
        address src = makeAddr("smallSource");
        vm.prank(pooler);
        IERC20(pair).transfer(src, 19_999);
        AntimatterPoolSeeder s =
            new AntimatterPoolSeeder(owner, address(phUSD), address(susds), address(am), address(router), pair, src);
        assertEq(s.lpForBps(1), 1, "19_999 * 1 / 10_000 floors to 1");
        assertEq(s.lpForBps(5_000), 9_999, "half floors down");
        assertEq(s.lpForBps(10_000), 19_999);
        assertEq(s.lpForBps(0), 0);
        vm.expectRevert(abi.encodeWithSelector(AntimatterPoolSeeder.InvalidBps.selector, 10_001));
        s.lpForBps(10_001);
    }

    function test_lpForBps_readsSourceBalance() public view {
        assertEq(seeder.lpForBps(2_500), IERC20(pair).balanceOf(pooler) * 2_500 / 10_000);
    }
}

interface IUniswapV2PairReserves {
    function getReserves() external view returns (uint112, uint112, uint32);
    function sync() external;
}
