// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";

/**
 * @title DebugClaimE2E
 * @notice Fork test: removes paused AutoPool DOLA YS then claims, proving the fix works.
 * @dev Run: forge test --fork-url $RPC_MAINNET --match-test testClaimSucceedsAfterRemoval -vvv
 */
contract DebugClaimE2E is Test {
    address constant ACCUMULATOR        = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant AUTO_POOL_DOLA_YS  = 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4;
    address constant OWNER              = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant CALLER             = 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28;
    address constant USDC               = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function testClaimSucceedsAfterRemoval() external {
        StableYieldAccumulator acc = StableYieldAccumulator(ACCUMULATOR);

        // Confirm claim reverts before fix
        vm.prank(CALLER);
        vm.expectRevert();
        acc.claim(5, 0);

        // Owner removes the paused strategy
        vm.prank(OWNER);
        acc.removeYieldStrategy(AUTO_POOL_DOLA_YS);

        // Verify remaining strategies
        address[] memory strategies = acc.getYieldStrategies();
        assertEq(strategies.length, 2);
        assertFalse(acc.isRegisteredStrategy(AUTO_POOL_DOLA_YS));

        // Claim should now succeed
        uint256 usdcBefore = IERC20(USDC).balanceOf(CALLER);
        vm.prank(CALLER);
        acc.claim(5, 0);
        uint256 usdcAfter = IERC20(USDC).balanceOf(CALLER);

        // Caller paid USDC (balance decreased)
        assertLt(usdcAfter, usdcBefore, "USDC should decrease (payment to Phlimbo)");
    }
}
