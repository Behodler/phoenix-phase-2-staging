// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockBalancerPool} from "../src/mocks/MockBalancerPool.sol";
import {MockBalancerVault} from "../src/mocks/MockBalancerVault.sol";
import {MockBalancerRouter} from "../src/mocks/MockBalancerRouter.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSUSDS} from "../src/mocks/MockSUSDS.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";
import {AddLiquidityParams, AddLiquidityKind} from "@yield-claim-nft/interfaces/balancer/BalancerTypes.sol";

/**
 * @title MockBalancerVaultExitTest  (story 100)
 * @notice The Balancer mocks' proportional and recovery exits, which the Balancexit cutover core
 *         (`script/helpers/UniPoolerCutoverCore.sol`) drives on anvil. They model the mainnet V3
 *         call path: the caller approves the ROUTER on the BPT, the router calls into the vault,
 *         the vault burns the BPT (spending the router's allowance) and pays each pool token
 *         pro rata, `amountOut_i = balance_i * bptIn / totalSupply`, reverting below
 *         `minAmountsOut`. A pause switch makes the proportional exit revert while the recovery
 *         exit works, as on mainnet after 30 October; an unpaused pool rejects the recovery exit,
 *         as mainnet's `PoolNotInRecoveryMode` does.
 */
contract MockBalancerVaultExitTest is Test {
    MockBalancerPool bpt;
    MockBalancerVault vault;
    MockBalancerRouter router;
    MockUSDS usds;
    MockSUSDS susds;
    MockPhUSD phusd;

    address lp = makeAddr("lp");
    address other = makeAddr("other");

    uint256 constant S_BAL = 30_000e18;
    uint256 constant P_BAL = 35_000e18;
    uint256 constant LP_BPT = 20_000e18;
    uint256 constant OTHER_BPT = 12_000e18;

    function setUp() public {
        bpt = new MockBalancerPool();
        vault = new MockBalancerVault(address(bpt));
        bpt.setVault(address(vault));
        router = new MockBalancerRouter();

        usds = new MockUSDS();
        susds = new MockSUSDS(address(usds));
        phusd = new MockPhUSD();
        phusd.setMinter(address(this), true);

        address[] memory tokens = new address[](2);
        tokens[0] = address(susds);
        tokens[1] = address(phusd);
        vault.setPoolTokens(tokens);

        // Pool reserves held by the vault.
        usds.approve(address(susds), S_BAL);
        susds.deposit(S_BAL, address(vault));
        phusd.mint(address(vault), P_BAL);

        // BPT supply via the existing addLiquidity path (1:1 mint), split between two holders.
        _mintBpt(lp, LP_BPT);
        _mintBpt(other, OTHER_BPT);
    }

    function _mintBpt(address to, uint256 amount) internal {
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = amount;
        vault.addLiquidity(
            AddLiquidityParams({
                pool: address(bpt),
                to: to,
                maxAmountsIn: maxIn,
                minBptAmountOut: 0,
                kind: AddLiquidityKind.UNBALANCED,
                userData: ""
            })
        );
    }

    function _share(uint256 bal, uint256 bptIn) internal view returns (uint256) {
        return (bal * bptIn) / bpt.totalSupply();
    }

    function _mins(uint256 a, uint256 b) internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = a;
        m[1] = b;
    }

    // ------------------------------------------------------------------ views

    function test_getPoolTokenInfo_reportsTokensAndRawBalances() public view {
        (address[] memory tokens,, uint256[] memory raw,) = vault.getPoolTokenInfo(address(bpt));
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(susds));
        assertEq(tokens[1], address(phusd));
        assertEq(raw[0], S_BAL);
        assertEq(raw[1], P_BAL);
        address[] memory t2 = vault.getPoolTokens(address(bpt));
        assertEq(t2[0], address(susds));
        assertEq(t2[1], address(phusd));
    }

    function test_setPoolTokens_onlyOnce() public {
        address[] memory tokens = new address[](2);
        vm.expectRevert("MockBalancerVault: pool tokens already set");
        vault.setPoolTokens(tokens);
    }

    // ------------------------------------------------------------- proportional

    function test_proportional_paysProRata_burnsBpt_spendsRouterAllowance() public {
        uint256 bptIn = 5_000e18;
        uint256 eS = _share(S_BAL, bptIn);
        uint256 eP = _share(P_BAL, bptIn);
        uint256 supplyBefore = bpt.totalSupply();

        vm.startPrank(lp);
        bpt.approve(address(router), bptIn);
        uint256[] memory out = router.removeLiquidityProportional(address(bpt), bptIn, _mins(eS, eP), false, "");
        vm.stopPrank();

        assertEq(out[0], eS, "sUSDS out");
        assertEq(out[1], eP, "phUSD out");
        assertEq(susds.balanceOf(lp), eS);
        assertEq(phusd.balanceOf(lp), eP);
        assertEq(bpt.balanceOf(lp), LP_BPT - bptIn, "BPT burned from caller");
        assertEq(bpt.totalSupply(), supplyBefore - bptIn, "supply reduced");
        assertEq(bpt.allowance(lp, address(router)), 0, "router allowance spent");
        assertEq(susds.balanceOf(address(vault)), S_BAL - eS);
        assertEq(phusd.balanceOf(address(vault)), P_BAL - eP);
    }

    function test_proportional_revertsWithoutRouterApproval() public {
        vm.prank(lp);
        vm.expectRevert();
        router.removeLiquidityProportional(address(bpt), 1e18, _mins(1, 1), false, "");
    }

    function test_proportional_revertsBelowMinAmountsOut() public {
        uint256 bptIn = 1_000e18;
        uint256 eS = _share(S_BAL, bptIn);
        uint256 eP = _share(P_BAL, bptIn);
        vm.startPrank(lp);
        bpt.approve(address(router), bptIn);
        vm.expectRevert("MockBalancerVault: amount out below minimum");
        router.removeLiquidityProportional(address(bpt), bptIn, _mins(eS + 1, eP), false, "");
        vm.expectRevert("MockBalancerVault: amount out below minimum");
        router.removeLiquidityProportional(address(bpt), bptIn, _mins(eS, eP + 1), false, "");
        vm.stopPrank();
    }

    function test_proportional_revertsOnWrongPoolOrLength() public {
        vm.startPrank(lp);
        bpt.approve(address(router), 1e18);
        vm.expectRevert("MockBalancerVault: minAmountsOut length");
        router.removeLiquidityProportional(address(bpt), 1e18, new uint256[](1), false, "");
        vm.stopPrank();
        vm.expectRevert("MockBalancerVault: unknown pool");
        vault.removeLiquidityProportional(address(0xdead), lp, lp, 1e18, _mins(0, 0));
    }

    function test_proportional_revertsWhenPaused() public {
        vault.setPoolPaused(true);
        vm.startPrank(lp);
        bpt.approve(address(router), 1e18);
        vm.expectRevert("MockBalancerVault: pool paused");
        router.removeLiquidityProportional(address(bpt), 1e18, _mins(1, 1), false, "");
        vm.stopPrank();
    }

    function test_vaultDirect_selfExitNeedsNoAllowance() public {
        uint256 bptIn = 100e18;
        vm.prank(lp);
        vault.removeLiquidityProportional(address(bpt), lp, lp, bptIn, _mins(1, 1));
        assertEq(bpt.balanceOf(lp), LP_BPT - bptIn);
    }

    function test_vaultDirect_thirdPartyCannotBurnWithoutAllowance() public {
        vm.prank(other);
        vm.expectRevert();
        vault.removeLiquidityProportional(address(bpt), lp, other, 1e18, _mins(1, 1));
    }

    function test_burn_onlyVault() public {
        vm.expectRevert("MockBalancerPool: only vault can burn");
        bpt.burnFrom(lp, lp, 1);
    }

    // ----------------------------------------------------------------- recovery

    function test_recovery_worksWhenPaused_paysProRata() public {
        vault.setPoolPaused(true);
        uint256 bptIn = LP_BPT; // whole position
        uint256 eS = _share(S_BAL, bptIn);
        uint256 eP = _share(P_BAL, bptIn);

        vm.startPrank(lp);
        bpt.approve(address(router), bptIn);
        uint256[] memory out = router.removeLiquidityRecovery(address(bpt), bptIn, _mins(eS, eP));
        vm.stopPrank();

        assertEq(out[0], eS);
        assertEq(out[1], eP);
        assertEq(susds.balanceOf(lp), eS);
        assertEq(phusd.balanceOf(lp), eP);
        assertEq(bpt.balanceOf(lp), 0);
        assertEq(bpt.totalSupply(), OTHER_BPT);
    }

    function test_recovery_revertsWhenNotInRecoveryMode() public {
        vm.startPrank(lp);
        bpt.approve(address(router), 1e18);
        vm.expectRevert("MockBalancerVault: pool not in recovery mode");
        router.removeLiquidityRecovery(address(bpt), 1e18, _mins(1, 1));
        vm.stopPrank();
    }

    function test_recovery_revertsBelowMinAmountsOut() public {
        vault.setPoolPaused(true);
        uint256 bptIn = 1_000e18;
        uint256 eS = _share(S_BAL, bptIn);
        vm.startPrank(lp);
        bpt.approve(address(router), bptIn);
        vm.expectRevert("MockBalancerVault: amount out below minimum");
        router.removeLiquidityRecovery(address(bpt), bptIn, _mins(eS + 1, 1));
        vm.stopPrank();
    }

    function test_unpause_restoresProportional() public {
        vault.setPoolPaused(true);
        vault.setPoolPaused(false);
        vm.startPrank(lp);
        bpt.approve(address(router), 1e18);
        router.removeLiquidityProportional(address(bpt), 1e18, _mins(1, 1), false, "");
        vm.stopPrank();
    }

    // ------------------------------------------------- existing behaviour intact

    function test_existingAddLiquidityAndQueryUnchanged() public {
        uint256 before = bpt.balanceOf(lp);
        _mintBpt(lp, 7e18);
        assertEq(bpt.balanceOf(lp), before + 7e18);
        uint256[] memory amts = _mins(3e18, 4e18);
        assertEq(router.queryAddLiquidityUnbalanced(address(bpt), amts, address(0), ""), 7e18);
    }

    function test_existingAddLiquidityStillWorksWhilePaused() public {
        // The pause switch only governs the exits; the existing add path is untouched.
        vault.setPoolPaused(true);
        _mintBpt(lp, 1e18);
    }
}
