// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*//////////////////////////////////////////////////////////////////////////
    USDeMockMarketSlippage
    ----------------------
    Unit test (no fork) for the DeployMocks USDe wiring after switching it from
    a plain 1:1 ERC4626YieldStrategy to ERC4626MarketYieldStrategy fronted by
    MockMarketAMMAdapter. Reproduces the exact local topology and parameters:

        MockUSDe (underlying) -> MockSUSDe (ERC4626 vault)
        MockMarketAMMAdapter  (ammSlippageBps = 50)
        ERC4626MarketYieldStrategy (slippageToleranceBps = 120)

    Asserts the behaviour the UI relies on:
      * Deposits are NOT perfectly preserved — principal is credited at a haircut
        and the value actually held is below the nominal amount (real slippage).
      * The strategy is solvent immediately after deposit (held value >= principal).
      * Withdrawals pay slippage (recipient receives less than principal).
      * Genuine vault yield still flows through and surfaces via totalBalanceOf.
//////////////////////////////////////////////////////////////////////////*/

import "@forge-std/Test.sol";
import "../src/mocks/MockUSDe.sol";
import "../src/mocks/MockSUSDe.sol";
import "../src/mocks/MockMarketAMMAdapter.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";

contract USDeMockMarketSlippageTest is Test {
    // Mirror DeployMocks Phase 2.7 parameters exactly.
    uint256 constant TOLERANCE_BPS = 120; // 1.2% principal haircut (mainnet parity)
    uint256 constant AMM_SLIPPAGE_BPS = 50; // 0.5% simulated AMM slippage per leg
    uint256 constant MAX_BPS = 10_000;

    MockUSDe usde;
    MockSUSDe susde;
    MockMarketAMMAdapter adapter;
    ERC4626MarketYieldStrategy strategy;

    address owner = address(this);
    address client = makeAddr("client"); // stands in for StableStaker
    address user = makeAddr("user"); // withdrawal recipient

    function setUp() public {
        usde = new MockUSDe(); // mints 1M USDe to this contract (owner)
        susde = new MockSUSDe(address(usde));

        // Establish a baseline of vault shares at price ~1.0, mirroring DeployMocks line 222.
        usde.approve(address(susde), 10_000e18);
        susde.deposit(10_000e18, owner);

        adapter = new MockMarketAMMAdapter(address(usde), address(susde), AMM_SLIPPAGE_BPS);
        strategy = new ERC4626MarketYieldStrategy(owner, address(usde), address(susde), address(adapter));
        strategy.setSlippageTolerance(TOLERANCE_BPS);
        strategy.setClient(client, true);

        // Fund the client and pre-approve the strategy (as StableStaker would).
        usde.mint(client, 1_000_000e18);
        vm.prank(client);
        usde.approve(address(strategy), type(uint256).max);
    }

    /// Held value = the strategy's vault shares valued at the current share price.
    function _heldValue() internal view returns (uint256) {
        return susde.convertToAssets(susde.balanceOf(address(strategy)));
    }

    function test_DepositCreditsHaircutPrincipal_NotPerfectPreservation() public {
        uint256 amount = 1_000e18;

        vm.prank(client);
        strategy.deposit(address(usde), amount, client);

        uint256 principal = strategy.principalOf(address(usde), client);
        uint256 expectedPrincipal = amount * (MAX_BPS - TOLERANCE_BPS) / MAX_BPS; // 988e18

        // Principal is the haircut amount, strictly below the nominal deposit.
        assertEq(principal, expectedPrincipal, "principal must be credited at the haircut");
        assertLt(principal, amount, "deposit must NOT be credited 1:1");

        // The total balance reported to the UI is below the nominal amount: real slippage
        // occurred (the AMM leg lost 0.5%), so this is no longer perfect preservation.
        uint256 total = strategy.totalBalanceOf(address(usde), client);
        assertLt(total, amount, "deposit must not be perfectly preserved (AMM slippage)");
    }

    function test_StrategyIsSolventAfterDeposit() public {
        uint256 amount = 1_000e18;

        vm.prank(client);
        strategy.deposit(address(usde), amount, client);

        // The core fix: held value must cover credited principal, so the strategy is not
        // underwater. With AMM slippage (50) < tolerance (120), held value exceeds principal
        // and the gap surfaces as yield.
        uint256 principal = strategy.principalOf(address(usde), client);
        assertGe(_heldValue(), principal, "strategy must be solvent (held value >= principal)");
        assertGt(strategy.totalBalanceOf(address(usde), client), principal, "haircut surplus should read as yield");
    }

    function test_WithdrawPaysSlippage() public {
        uint256 amount = 1_000e18;

        vm.prank(client);
        strategy.deposit(address(usde), amount, client);

        uint256 principal = strategy.principalOf(address(usde), client);

        // Debit the client's principal, pay a separate recipient (the SYA/owner withdrawer path).
        uint256 balBefore = usde.balanceOf(user);
        strategy.withdrawAsOwner(client, user, principal);
        uint256 received = usde.balanceOf(user) - balBefore;

        // Withdrawal routes back through the AMM and loses ~0.5% — recipient gets less than
        // the principal redeemed, but no less than the strategy's own minOut floor.
        assertLt(received, principal, "withdraw must incur slippage");
        uint256 minFloor = principal * (MAX_BPS - TOLERANCE_BPS) / MAX_BPS;
        assertGe(received, minFloor, "withdraw output must respect the slippage tolerance floor");
    }

    function test_VaultYieldStillFlowsThrough() public {
        uint256 amount = 1_000e18;

        vm.prank(client);
        strategy.deposit(address(usde), amount, client);

        uint256 totalBefore = strategy.totalBalanceOf(address(usde), client);

        // Simulate real yield accrual in the vault (share price rises).
        susde.addYield(2_000e18);

        uint256 totalAfter = strategy.totalBalanceOf(address(usde), client);
        assertGt(totalAfter, totalBefore, "vault yield must increase the user's total balance");
        assertGt(totalAfter, strategy.principalOf(address(usde), client), "yield must exceed principal");
    }
}
