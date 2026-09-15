// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockRewardToken.sol";

/**
 * @title MockAutoDOLAInflationTest
 * @notice Reproduces the Anvil dev-deploy failure where `StableStakerV2.autoAnnihilate` reverted
 *         with "ERC4626YieldStrategy: no shares received".
 *
 *         WHY. `MockAutoDOLA` accrues simulated yield into its own balance. When every share was
 *         redeemed, that yield stayed behind as dust against a zero share supply. With no decimals
 *         offset, the next deposit was priced against the dust, so one share came to be worth
 *         ~0.14 USDC and any smaller deposit minted zero shares. Real Tokemak Autopools are deep
 *         enough that this cannot happen on mainnet; the mock must not make it happen on Anvil.
 */
contract MockAutoDOLAInflationTest is Test {
    MockRewardToken usdc;
    MockAutoDOLA vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new MockRewardToken();
        vault = new MockAutoDOLA(address(usdc));
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// The dev-deploy sequence: deposit, accrue yield, redeem everything (leaving yield dust),
    /// donate, re-deposit, accrue for a day. A sub-dollar deposit must still mint shares.
    function test_fullRedeemLeavingDust_doesNotInflateSharePrice() public {
        vm.prank(alice);
        vault.deposit(1200e6, alice);

        vm.warp(block.timestamp + 1 minutes);
        vault.accrueYield();

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        assertEq(vault.totalSupply(), 0, "all shares redeemed");
        assertGt(vault.totalAssets(), 0, "yield dust left behind");

        usdc.mint(address(vault), 1000e6); // DeployMocks Phase 9.6 donation
        vm.prank(bob);
        vault.deposit(5000e6, bob);

        vm.warp(block.timestamp + 1 days);
        vault.accrueYield();

        // The exact annihilation that failed on Anvil: 0.139524 USDC.
        vm.prank(bob);
        uint256 shares = vault.deposit(139_524, bob);
        assertGt(shares, 0, "annihilation-sized deposit minted zero shares");

        // A thousandth of a USDC still mints shares. (A single raw unit legitimately rounds to zero
        // on any vault whose shares are worth more than one raw unit, so it is not the bar.)
        assertGt(vault.previewDeposit(0.001e6), 0, "0.001 USDC rounds to zero shares");
    }

    /// A small round trip through the vault must not lose a whole share's worth of value, which is
    /// what turned the StableStakerV2 exit-then-redeposit into a zero-share deposit.
    function test_smallRedeemThenRedeposit_mintsShares() public {
        vm.prank(alice);
        vault.deposit(0.12e6, alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);
        usdc.mint(address(vault), 1000e6);
        vm.prank(bob);
        vault.deposit(100e6, bob);

        uint256 sharesOut = vault.previewWithdraw(0.2e6);
        vm.prank(bob);
        uint256 assets = vault.redeem(sharesOut, bob, bob);
        vm.prank(bob);
        assertGt(vault.deposit(assets, bob), 0, "redeposit of a redeemed amount minted zero shares");
    }
}
