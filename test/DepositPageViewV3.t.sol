// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Test.sol";
import "../src/views/DepositPageViewV3.sol";
import "../src/views/DepositPageView.sol";
import "../src/views/IPageView.sol";
import "../src/views/ViewRouter.sol";
import {PhlimboV3} from "@phlimbo-ea/PhlimboV3.sol";
import {IPhlimboV3} from "@phlimbo-ea/interfaces/IPhlimboV3.sol";
import {IPhlimbo} from "@phlimbo-ea/interfaces/IPhlimbo.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlax} from "@phlimbo-ea/IFlax.sol";

// ============================================================================
// Local mocks
//
// Deliberately local rather than imported from `lib/phlimbo-ea/test/Mocks.sol`:
// this suite needs a token with NO `decimals()` at all, which no shared mock
// provides, and importing a submodule's test tree into this repo's compilation
// unit risks duplicate-identifier collisions across the diamond remappings.
// ============================================================================

/// @dev Mock phUSD: an ERC20 that anyone may mint, satisfying the IFlax surface
///      PhlimboV3 calls (`mint`, `authorizedMinters`).
contract MockFlaxToken is ERC20 {
    mapping(address => bool) public minters;
    bool public mintReverts;

    constructor() ERC20("Mock phUSD", "mphUSD") {}

    function setMinter(address minter, bool canMint) external {
        minters[minter] = canMint;
    }

    function setMintReverts(bool value) external {
        mintReverts = value;
    }

    function mint(address recipient, uint256 amount) external {
        require(!mintReverts, "mint not authorized");
        _mint(recipient, amount);
    }

    function burn(address holder, uint256 amount) external {
        _burn(holder, amount);
    }

    function authorizedMinters(address minter) external view returns (IFlax.MinterInfo memory) {
        return IFlax.MinterInfo({canMint: minters[minter], mintVersion: 1});
    }

    function mintVersion() external pure returns (uint256) {
        return 1;
    }

    function revokeAllMintPrivileges() external {}
}

/// @dev Plain 18-decimal ERC20.
contract MockStableToken is ERC20 {
    constructor() ERC20("Mock Stable", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev USDC-shaped 6-decimal ERC20 — the realistic partner-token case.
contract MockUSDC6Token is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev USDT-style recipient blocklist: transfers to a blocked address revert, so a
///      flush/claim transfer fails and PhlimboV3 banks it instead of reverting.
contract MockBlocklistERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Mock Blocklist", "mBLK") {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "recipient blocked");
        super._update(from, to, value);
    }
}

/// @dev A conforming ERC20 that deliberately does NOT implement the optional
///      `decimals()` extension. Hand-rolled because every OZ ERC20 supplies one.
///      Exercises the view's try/catch fallback to 18.
contract MockNoDecimalsERC20 {
    string public name = "No Decimals";
    string public symbol = "NODEC";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

// ============================================================================
// Main suite
// ============================================================================

contract DepositPageViewV3Test is Test {
    // Field indices — mirrored from the contract so a reorder fails loudly here.
    uint256 constant I_USER_PHUSD_BALANCE = 0;
    uint256 constant I_PHUSD_PER_SECOND = 1;
    uint256 constant I_STABLE_PER_SECOND = 2;
    uint256 constant I_PENDING_PHUSD = 3;
    uint256 constant I_PENDING_STABLE = 4;
    uint256 constant I_STAKED_BALANCE = 5;
    uint256 constant I_USER_ALLOWANCE = 6;
    uint256 constant I_PRECISION = 7;
    uint256 constant I_MINIMUM_STAKE = 8;
    uint256 constant I_TOTAL_STAKED = 9;
    uint256 constant I_PAUSED = 10;
    uint256 constant I_PROMO_TOKEN = 11;
    uint256 constant I_PROMO_DECIMALS = 12;
    uint256 constant I_PROMO_RATE = 13;
    uint256 constant I_PROMO_BALANCE = 14;
    uint256 constant I_PROMO_DURATION_F = 15;
    uint256 constant I_PROMO_PHASE = 16;
    uint256 constant I_FLUSH_CURSOR = 17;
    uint256 constant I_STAKER_COUNT = 18;
    uint256 constant I_PENDING_PROMO = 19;
    uint256 constant I_UNCLAIMABLE_PROMO = 20;
    uint256 constant I_UNCLAIMABLE_STABLE = 21;
    uint256 constant I_UNCLAIMABLE_PHUSD = 22;

    PhlimboV3 public phlimbo;
    MockFlaxToken public phUSD;
    MockStableToken public stable;
    DepositPageViewV3 public view_;

    address public owner = address(this);
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public rewardDonor = address(0x3);
    address public neverStaked = address(0xBEEF);

    uint256 constant INITIAL_BALANCE = 10_000 ether;
    uint256 constant STAKE_AMOUNT = 1_000 ether;
    uint256 constant DEPLETION_DURATION = 604800; // 1 week
    uint256 constant PROMO_AMOUNT = 1_000 ether;
    uint256 constant PROMO_DURATION = 1_000_000;

    function setUp() public {
        phUSD = new MockFlaxToken();
        stable = new MockStableToken();

        phlimbo = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        phUSD.setMinter(address(phlimbo), true);

        phUSD.mint(alice, INITIAL_BALANCE);
        phUSD.mint(bob, INITIAL_BALANCE);
        stable.mint(rewardDonor, INITIAL_BALANCE);

        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(bob);
        phUSD.approve(address(phlimbo), type(uint256).max);
        vm.prank(rewardDonor);
        stable.approve(address(phlimbo), type(uint256).max);

        // Non-zero APY so the phUSD leg actually streams (two-step commit).
        phlimbo.setDesiredAPY(500);
        phlimbo.setDesiredAPY(500);

        view_ = new DepositPageViewV3(IPhlimboV3(address(phlimbo)), IERC20(address(phUSD)));
    }

    function _stakeBoth() internal {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.prank(bob);
        phlimbo.stake(STAKE_AMOUNT, bob);
    }

    function _fundStable(uint256 amount) internal {
        vm.prank(rewardDonor);
        phlimbo.collectReward(amount);
    }

    // ========================================================================
    // 1. Wire contract: names/data length and the literal name strings
    // ========================================================================

    function test_names_and_data_lengths_are_23() public view {
        string[] memory names = view_.getNames();
        uint256[] memory data = view_.getData(alice);
        assertEq(names.length, 23, "getNames must return 23 entries");
        assertEq(data.length, 23, "getData must return 23 entries");
        assertEq(names.length, data.length, "arrays must stay parallel");
        assertEq(view_.FIELD_COUNT(), 23, "FIELD_COUNT must agree");
    }

    function test_names_match_the_wire_contract_exactly() public view {
        string[] memory n = view_.getNames();
        assertEq(n[0], "userPhUSDBalance");
        assertEq(n[1], "phUSDRewardsPerSecond");
        assertEq(n[2], "stableRewardsPerSecond");
        assertEq(n[3], "pendingPhUSDRewards");
        assertEq(n[4], "pendingStableRewards");
        assertEq(n[5], "stakedBalance");
        assertEq(n[6], "userAllowance");
        assertEq(n[7], "precision");
        assertEq(n[8], "minimumStake");
        assertEq(n[9], "totalStaked");
        assertEq(n[10], "paused");
        assertEq(n[11], "promoToken");
        assertEq(n[12], "promoTokenDecimals");
        assertEq(n[13], "promoRewardPerSecond");
        assertEq(n[14], "promoRewardBalance");
        assertEq(n[15], "promoDepletionDuration");
        assertEq(n[16], "promoPhase");
        assertEq(n[17], "flushCursor");
        assertEq(n[18], "stakerCount");
        assertEq(n[19], "pendingPromoRewards");
        assertEq(n[20], "unclaimablePromo");
        assertEq(n[21], "unclaimableStable");
        assertEq(n[22], "unclaimablePhUSD");
    }

    // ========================================================================
    // 2. Indices 0-6 parity with the predecessor DepositPageView
    //
    // The predecessor is force-cast onto V3 exactly as `RewireSYAToPhlimboV2`
    // did for V1->V2. That cast is precisely the undefined-by-accident decode
    // this story replaces — here it serves only as the reference oracle proving
    // the migration is strictly additive for fields 0-6.
    // ========================================================================

    function test_indices_0_to_6_parity_with_DepositPageView() public {
        _stakeBoth();
        _fundStable(1_000 ether);
        vm.warp(block.timestamp + 100_000);

        DepositPageView old = new DepositPageView(IPhlimbo(address(phlimbo)), IERC20(address(phUSD)));

        string[] memory oldNames = old.getNames();
        string[] memory newNames = view_.getNames();
        uint256[] memory oldData = old.getData(alice);
        uint256[] memory newData = view_.getData(alice);

        assertEq(oldData.length, 7, "predecessor is 7 fields");
        for (uint256 i = 0; i < 7; i++) {
            assertEq(newNames[i], oldNames[i], "name drift in the preserved prefix");
            assertEq(newData[i], oldData[i], "value drift in the preserved prefix");
        }

        // And the values are genuinely non-trivial, so the parity is meaningful.
        assertGt(newData[I_STAKED_BALANCE], 0, "alice is staked");
        assertGt(newData[I_PENDING_STABLE], 0, "stable accrued");
        assertGt(newData[I_PENDING_PHUSD], 0, "phUSD accrued");
        assertGt(newData[I_USER_ALLOWANCE], 0, "allowance set");
    }

    function test_preserved_fields_match_their_sources() public {
        _stakeBoth();
        _fundStable(1_000 ether);
        vm.warp(block.timestamp + 100_000);

        uint256[] memory d = view_.getData(alice);
        (uint256 amount,,,) = phlimbo.userInfo(alice);

        assertEq(d[I_USER_PHUSD_BALANCE], phUSD.balanceOf(alice));
        assertEq(d[I_PHUSD_PER_SECOND], phlimbo.phUSDPerSecond());
        assertEq(d[I_STABLE_PER_SECOND], phlimbo.rewardPerSecond());
        assertEq(d[I_PENDING_PHUSD], phlimbo.pendingPhUSD(alice));
        assertEq(d[I_PENDING_STABLE], phlimbo.pendingStable(alice));
        assertEq(d[I_STAKED_BALANCE], amount);
        assertEq(d[I_USER_ALLOWANCE], phUSD.allowance(alice, address(phlimbo)));
    }

    /// @dev Pins Concerns §1: field 1 is RAW and field 2 is PRECISION-scaled, and
    ///      neither is silently normalised behind an unchanged name.
    function test_scaling_asymmetry_is_preserved_not_normalised() public {
        _stakeBoth();
        _fundStable(1_000 ether);

        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_PRECISION], phlimbo.PRECISION(), "precision exposed for descaling");
        assertEq(d[I_PRECISION], 1e18);
        // Field 2 is the raw storage value, NOT divided by PRECISION.
        assertEq(d[I_STABLE_PER_SECOND], phlimbo.rewardPerSecond(), "field 2 not descaled");
        // Field 1 is the raw storage value, NOT multiplied by PRECISION.
        assertEq(d[I_PHUSD_PER_SECOND], phlimbo.phUSDPerSecond(), "field 1 not scaled up");
    }

    function test_pool_constants_fields_7_8_9() public {
        _stakeBoth();
        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_PRECISION], phlimbo.PRECISION());
        assertEq(d[I_MINIMUM_STAKE], phlimbo.MINIMUM_STAKE());
        assertEq(d[I_MINIMUM_STAKE], 1e15, "MINIMUM_STAKE is 0.001 phUSD");
        assertEq(d[I_TOTAL_STAKED], phlimbo.totalStaked());
        assertEq(d[I_TOTAL_STAKED], STAKE_AMOUNT * 2);
        assertEq(d[I_STAKER_COUNT], phlimbo.stakerCount());
        assertEq(d[I_STAKER_COUNT], 2);
    }

    // ========================================================================
    // 3. No promotion (PromoPhase.None)
    // ========================================================================

    function test_no_promo_zeroes_promo_fields_and_does_not_revert() public {
        _stakeBoth();
        _fundStable(1_000 ether);
        vm.warp(block.timestamp + 50_000);

        uint256[] memory d = view_.getData(alice);

        assertEq(d[I_PROMO_TOKEN], 0, "promoToken widens to 0 when unset");
        assertEq(d[I_PROMO_DECIMALS], 0, "no decimals read against address(0)");
        assertEq(d[I_PROMO_RATE], 0);
        assertEq(d[I_PROMO_BALANCE], 0);
        assertEq(d[I_PROMO_PHASE], 0, "PromoPhase.None == 0");
        assertEq(d[I_FLUSH_CURSOR], 0);
        assertEq(d[I_PENDING_PROMO], 0);
        assertEq(d[I_UNCLAIMABLE_PROMO], 0);
        assertEq(d[I_PAUSED], 0, "not paused");
        // The rest of the page still works.
        assertGt(d[I_STAKED_BALANCE], 0);
    }

    // ========================================================================
    // 4. Active promo with a 6-decimal partner token
    // ========================================================================

    function test_active_promo_6_decimal_partner_token() public {
        MockUSDC6Token usdc = new MockUSDC6Token();
        uint256 q = 1000e6; // 1000 USDC, native 6 dp
        usdc.mint(owner, q);
        usdc.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        phlimbo.startPromotion(address(usdc), q, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256[] memory d = view_.getData(alice);

        assertEq(d[I_PROMO_TOKEN], uint256(uint160(address(usdc))), "promo token address widened");
        assertEq(d[I_PROMO_DECIMALS], 6, "native decimals surfaced, not assumed 18");
        assertEq(d[I_PROMO_PHASE], 1, "PromoPhase.Active == 1");
        assertEq(d[I_PROMO_RATE], phlimbo.promoRewardPerSecond());
        assertEq(d[I_PROMO_BALANCE], phlimbo.promoRewardBalance());
        assertEq(d[I_PROMO_DURATION_F], phlimbo.promoDepletionDuration());
        assertEq(d[I_PROMO_DURATION_F], PROMO_DURATION);
        assertEq(d[I_FLUSH_CURSOR], 0, "no flush in progress");
        assertEq(d[I_PENDING_PROMO], phlimbo.pendingPromo(alice));
        // Equal stakes at the half window: ~q/4 each, in native 6 dp.
        assertApproxEqAbs(d[I_PENDING_PROMO], q / 4, 2, "pending promo is in native 6dp units");
        assertEq(d[I_UNCLAIMABLE_PROMO], 0, "nothing banked yet");
    }

    /// @dev Fields 13-17 must come from a single getPromoInfo() call and agree with
    ///      the individual getters at the same block.
    function test_promo_fields_agree_with_getPromoInfo() public {
        MockStableToken partner = new MockStableToken();
        partner.mint(owner, PROMO_AMOUNT);
        partner.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 3);

        (
            address t,
            uint256 bal,
            uint256 rate,
            uint256 dur,
            IPhlimboV3.PromoPhase phase,
            uint256 cursor
        ) = IPhlimboV3(address(phlimbo)).getPromoInfo();

        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_PROMO_TOKEN], uint256(uint160(t)));
        assertEq(d[I_PROMO_BALANCE], bal);
        assertEq(d[I_PROMO_RATE], rate);
        assertEq(d[I_PROMO_DURATION_F], dur);
        assertEq(d[I_PROMO_PHASE], uint256(uint8(phase)));
        assertEq(d[I_FLUSH_CURSOR], cursor);
        assertEq(d[I_PROMO_DECIMALS], 18, "MockStableToken is 18 dp");
    }

    // ========================================================================
    // 5. Promo token with no decimals() -> fallback to 18, no revert
    // ========================================================================

    function test_promo_token_without_decimals_falls_back_to_18() public {
        MockNoDecimalsERC20 odd = new MockNoDecimalsERC20();
        odd.mint(owner, PROMO_AMOUNT);
        odd.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        phlimbo.startPromotion(address(odd), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256[] memory d = view_.getData(alice); // must not revert
        assertEq(d[I_PROMO_TOKEN], uint256(uint160(address(odd))));
        assertEq(d[I_PROMO_DECIMALS], 18, "missing decimals() falls back to 18");
        assertEq(d[I_PROMO_PHASE], 1);
        assertGt(d[I_PENDING_PROMO], 0, "promo still streams");
    }

    // ========================================================================
    // 6. Flushing phase: phase == 2, paused == 1, pendingPromo frozen
    // ========================================================================

    function test_flushing_phase_reports_paused_and_freezes_pending_promo() public {
        MockStableToken partner = new MockStableToken();
        partner.mint(owner, PROMO_AMOUNT);
        partner.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);

        uint256 t0 = block.timestamp;
        vm.warp(t0 + PROMO_DURATION / 2);

        phlimbo.beginFlush(); // accrues, then pauses and enters Flushing

        uint256[] memory before = view_.getData(alice);
        assertEq(before[I_PROMO_PHASE], 2, "PromoPhase.Flushing == 2");
        assertEq(before[I_PAUSED], 1, "beginFlush pauses the contract");
        assertGt(before[I_PENDING_PROMO], 0, "pending accrued before the freeze");

        vm.warp(t0 + (PROMO_DURATION * 3) / 4);

        uint256[] memory afterWarp = view_.getData(alice);
        assertEq(afterWarp[I_PROMO_PHASE], 2, "still flushing");
        assertEq(afterWarp[I_PAUSED], 1, "still paused");
        assertEq(
            afterWarp[I_PENDING_PROMO],
            before[I_PENDING_PROMO],
            "promo accrual is frozen while Flushing"
        );
    }

    function test_flush_progress_is_cursor_over_stakerCount() public {
        MockStableToken partner = new MockStableToken();
        partner.mint(owner, PROMO_AMOUNT);
        partner.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        phlimbo.startPromotion(address(partner), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        phlimbo.beginFlush();
        assertEq(view_.getData(alice)[I_FLUSH_CURSOR], 0, "cursor starts at 0");
        assertEq(view_.getData(alice)[I_STAKER_COUNT], 2, "two stakers to flush");

        phlimbo.batchClaim(1);
        assertEq(view_.getData(alice)[I_FLUSH_CURSOR], 1, "cursor advanced one staker");

        phlimbo.batchClaim(10);
        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_FLUSH_CURSOR], 2, "flush complete");
        assertEq(d[I_STAKER_COUNT], 2);
    }

    // ========================================================================
    // 7a. Banked promo: pendingPromo == 0 while the bank is > 0
    // ========================================================================

    function test_banked_promo_shows_zero_pending_and_positive_bank() public {
        MockBlocklistERC20 blk = new MockBlocklistERC20();
        blk.mint(owner, PROMO_AMOUNT);
        blk.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        phlimbo.startPromotion(address(blk), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256 alicePending = phlimbo.pendingPromo(alice);
        assertGt(alicePending, 0, "alice accrued promo");

        blk.setBlocked(alice, true);
        phlimbo.beginFlush();
        phlimbo.batchClaim(10);

        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_PENDING_PROMO], 0, "pendingPromo realigned to zero on a banked failure");
        assertEq(d[I_UNCLAIMABLE_PROMO], alicePending, "the entitlement lives in the bank");
        assertEq(d[I_UNCLAIMABLE_PROMO], phlimbo.unclaimablePromoOf(address(blk), alice));

        // Bob was paid normally: no bank, no pending.
        uint256[] memory db = view_.getData(bob);
        assertEq(db[I_UNCLAIMABLE_PROMO], 0, "bob has nothing banked");
    }

    // ========================================================================
    // 8. Never-staked user and address(0) -> all zeros, no revert
    // ========================================================================

    function test_never_staked_user_returns_zeros_without_reverting() public {
        _stakeBoth();
        _fundStable(1_000 ether);
        vm.warp(block.timestamp + 100_000);

        uint256[] memory d = view_.getData(neverStaked);
        assertEq(d.length, 23);
        assertEq(d[I_USER_PHUSD_BALANCE], 0);
        assertEq(d[I_PENDING_PHUSD], 0);
        assertEq(d[I_PENDING_STABLE], 0);
        assertEq(d[I_STAKED_BALANCE], 0);
        assertEq(d[I_USER_ALLOWANCE], 0);
        assertEq(d[I_PENDING_PROMO], 0);
        assertEq(d[I_UNCLAIMABLE_PROMO], 0);
        assertEq(d[I_UNCLAIMABLE_STABLE], 0);
        assertEq(d[I_UNCLAIMABLE_PHUSD], 0);
        // Pool-wide fields are still populated.
        assertEq(d[I_TOTAL_STAKED], phlimbo.totalStaked());
    }

    function test_zero_address_user_does_not_revert() public {
        _stakeBoth();
        _fundStable(1_000 ether);
        vm.warp(block.timestamp + 100_000);

        uint256[] memory d = view_.getData(address(0));
        assertEq(d.length, 23);
        assertEq(d[I_STAKED_BALANCE], 0);
        assertEq(d[I_PENDING_PHUSD], 0);
        assertEq(d[I_PENDING_STABLE], 0);
        assertEq(d[I_USER_ALLOWANCE], 0);
    }

    function test_empty_pool_returns_zeros_without_reverting() public view {
        // Nothing staked, no promo, no rewards collected.
        uint256[] memory d = view_.getData(alice);
        assertEq(d.length, 23);
        assertEq(d[I_TOTAL_STAKED], 0);
        assertEq(d[I_STAKER_COUNT], 0);
        assertEq(d[I_PROMO_PHASE], 0);
        assertEq(d[I_PROMO_DECIMALS], 0);
    }

    // ========================================================================
    // 9. getRetiredPromoBanks across a promotion rotation
    // ========================================================================

    function test_getRetiredPromoBanks_survives_rotation() public {
        MockBlocklistERC20 blk = new MockBlocklistERC20();
        blk.mint(owner, PROMO_AMOUNT);
        blk.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        phlimbo.startPromotion(address(blk), PROMO_AMOUNT, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        uint256 alicePending = phlimbo.pendingPromo(alice);
        blk.setBlocked(alice, true);

        phlimbo.beginFlush();
        phlimbo.batchClaim(10);
        phlimbo.finalizePromotion(address(0x99)); // slot rotates back to None

        // The live slot is empty again...
        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_PROMO_PHASE], 0, "back to PromoPhase.None");
        assertEq(d[I_PROMO_TOKEN], 0, "slot cleared");
        assertEq(d[I_UNCLAIMABLE_PROMO], 0, "field 20 tracks the LIVE slot only");

        // ...but the bank against the RETIRED token is still discoverable.
        address[] memory tokens = new address[](2);
        tokens[0] = address(blk);
        tokens[1] = address(stable);
        uint256[] memory banks = view_.getRetiredPromoBanks(alice, tokens);
        assertEq(banks.length, 2);
        assertEq(banks[0], alicePending, "retired-token bank survives the rotation");
        assertEq(banks[1], 0, "unrelated token has no bank");

        // Bob was paid, so he has nothing banked for the retired token.
        uint256[] memory bobBanks = view_.getRetiredPromoBanks(bob, tokens);
        assertEq(bobBanks[0], 0);
    }

    function test_getRetiredPromoBanks_empty_list_returns_empty() public view {
        address[] memory none = new address[](0);
        uint256[] memory banks = view_.getRetiredPromoBanks(alice, none);
        assertEq(banks.length, 0, "empty in, empty out");
    }

    function test_getRetiredPromoBanks_tolerates_zero_address_entries() public view {
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(0);
        uint256[] memory banks = view_.getRetiredPromoBanks(alice, tokens);
        assertEq(banks.length, 2);
        assertEq(banks[0], 0);
        assertEq(banks[1], 0);
    }

    // ========================================================================
    // 10. Through the ViewRouter — the only access path story 078 leaves in place
    // ========================================================================

    function test_router_round_trips_getNames_and_getData() public {
        MockUSDC6Token usdc = new MockUSDC6Token();
        usdc.mint(owner, 1000e6);
        usdc.approve(address(phlimbo), type(uint256).max);

        _stakeBoth();
        _fundStable(1_000 ether);
        phlimbo.startPromotion(address(usdc), 1000e6, PROMO_DURATION);
        vm.warp(block.timestamp + PROMO_DURATION / 2);

        ViewRouter router = new ViewRouter();
        bytes32 key = keccak256("deposit");
        router.setPage(key, IPageView(address(view_)));

        assertEq(address(router.pages(key)), address(view_), "impl resolvable for the two-step read");

        string[] memory routed = router.getNames(key);
        string[] memory direct = view_.getNames();
        assertEq(routed.length, direct.length);
        for (uint256 i = 0; i < direct.length; i++) {
            assertEq(routed[i], direct[i], "router getNames must round-trip");
        }

        uint256[] memory routedData = router.getData(key, alice);
        uint256[] memory directData = view_.getData(alice);
        assertEq(routedData.length, directData.length);
        for (uint256 i = 0; i < directData.length; i++) {
            assertEq(routedData[i], directData[i], "router getData must round-trip");
        }
        assertGt(directData[I_PENDING_PROMO], 0, "round-trip covers non-trivial data");
    }

    // ========================================================================
    // 11. Constructor zero-address guards
    // ========================================================================

    function test_constructor_rejects_zero_phlimbo() public {
        vm.expectRevert("Invalid phlimbo address");
        new DepositPageViewV3(IPhlimboV3(address(0)), IERC20(address(phUSD)));
    }

    function test_constructor_rejects_zero_phUSD() public {
        vm.expectRevert("Invalid phUSD address");
        new DepositPageViewV3(IPhlimboV3(address(phlimbo)), IERC20(address(0)));
    }

    function test_constructor_sets_immutables() public view {
        assertEq(address(view_.phlimbo()), address(phlimbo));
        assertEq(address(view_.phUSD()), address(phUSD));
    }
}

// ============================================================================
// 7b. Banked STABLE — needs a blocklisting reward token, fixed at construction,
//     so it requires its own harness.
// ============================================================================

contract DepositPageViewV3StableBankTest is Test {
    uint256 constant I_PENDING_STABLE = 4;
    uint256 constant I_UNCLAIMABLE_STABLE = 21;

    PhlimboV3 public phlimbo;
    MockFlaxToken public phUSD;
    MockBlocklistERC20 public stable;
    DepositPageViewV3 public view_;

    address public alice = address(0x1);
    address public rewardDonor = address(0x3);

    uint256 constant STAKE_AMOUNT = 1_000 ether;
    uint256 constant DEPLETION_DURATION = 604800;

    function setUp() public {
        phUSD = new MockFlaxToken();
        stable = new MockBlocklistERC20();
        phlimbo = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        phUSD.setMinter(address(phlimbo), true);

        phUSD.mint(alice, 10_000 ether);
        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);

        stable.mint(rewardDonor, 100_000 ether);
        vm.prank(rewardDonor);
        stable.approve(address(phlimbo), type(uint256).max);

        view_ = new DepositPageViewV3(IPhlimboV3(address(phlimbo)), IERC20(address(phUSD)));
    }

    function test_banked_stable_shows_zero_pending_and_positive_bank() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);

        vm.prank(rewardDonor);
        phlimbo.collectReward(1_000 ether);
        vm.warp(block.timestamp + 100_000);

        uint256 pending = phlimbo.pendingStable(alice);
        assertGt(pending, 0, "alice accrued stable");
        assertEq(view_.getData(alice)[I_PENDING_STABLE], pending, "pending surfaced before the failure");

        stable.setBlocked(alice, true);
        vm.prank(alice);
        phlimbo.claim(alice); // stable transfer fails and is banked, no revert

        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_PENDING_STABLE], 0, "pendingStable realigned to zero");
        assertEq(d[I_UNCLAIMABLE_STABLE], pending, "entitlement moved into the stable bank");
        assertEq(d[I_UNCLAIMABLE_STABLE], phlimbo.unclaimableStableOf(alice));
    }
}

// ============================================================================
// 7c. Banked phUSD — needs a phUSD whose mint can be made to revert, modelling
//     PhlimboV3 losing mint authority.
// ============================================================================

contract DepositPageViewV3PhusdBankTest is Test {
    uint256 constant I_PENDING_PHUSD = 3;
    uint256 constant I_UNCLAIMABLE_PHUSD = 22;

    PhlimboV3 public phlimbo;
    MockFlaxToken public phUSD;
    MockStableToken public stable;
    DepositPageViewV3 public view_;

    address public alice = address(0x1);

    uint256 constant STAKE_AMOUNT = 1_000 ether;
    uint256 constant DEPLETION_DURATION = 604800;

    function setUp() public {
        phUSD = new MockFlaxToken();
        stable = new MockStableToken();
        phlimbo = new PhlimboV3(address(phUSD), address(stable), DEPLETION_DURATION);
        phUSD.setMinter(address(phlimbo), true);

        phUSD.mint(alice, 10_000 ether);
        vm.prank(alice);
        phUSD.approve(address(phlimbo), type(uint256).max);

        phlimbo.setDesiredAPY(500);
        phlimbo.setDesiredAPY(500);

        view_ = new DepositPageViewV3(IPhlimboV3(address(phlimbo)), IERC20(address(phUSD)));
    }

    function test_banked_phUSD_shows_zero_pending_and_positive_bank() public {
        vm.prank(alice);
        phlimbo.stake(STAKE_AMOUNT, alice);
        vm.warp(block.timestamp + 100_000);

        uint256 pending = phlimbo.pendingPhUSD(alice);
        assertGt(pending, 0, "alice accrued phUSD");
        assertEq(view_.getData(alice)[I_PENDING_PHUSD], pending, "pending surfaced before the failure");

        phUSD.setMintReverts(true); // PhlimboV3 loses mint authority
        vm.prank(alice);
        phlimbo.claim(alice); // must not revert; mint is banked

        uint256[] memory d = view_.getData(alice);
        assertEq(d[I_PENDING_PHUSD], 0, "pendingPhUSD realigned to zero");
        assertEq(d[I_UNCLAIMABLE_PHUSD], pending, "entitlement moved into the phUSD bank");
        assertEq(d[I_UNCLAIMABLE_PHUSD], phlimbo.unclaimablePhUSDOf(alice));
    }
}
