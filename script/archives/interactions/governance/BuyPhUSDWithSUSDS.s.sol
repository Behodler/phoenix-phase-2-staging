// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter, IPermit2} from "../BalancerECLPInterfaces.sol";

interface IERC4626 {
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/**
 * @title BuyPhUSDWithSUSDS
 * @notice Swaps sUSDS for phUSD on the Balancer V3 e-CLP pool.
 *
 *         Env vars:
 *           PHUSD_BUY_DOLLAR_IN  - Dollar amount to spend (1 = $1, assumes USDS = $1)
 *           PHUSD_BUY_MIN_OUT    - Minimum phUSD to receive in ether units (1 = 1 phUSD)
 *
 *         Forge simulates the tx before broadcasting. If phUSD received < min out,
 *         the simulation reverts and nothing is sent.
 */
contract BuyPhUSDWithSUSDS is Script {
    address constant POOL    = 0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58;
    address constant SUSDS   = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant PHUSD   = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant ROUTER  = 0xAE563E3f8219521950555F5962419C8919758Ea2;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        uint256 dollarIn = vm.envUint("PHUSD_BUY_DOLLAR_IN");
        uint256 minOutEther = vm.envUint("PHUSD_BUY_MIN_OUT");
        uint256 minAmountOut = minOutEther * 1e18;

        uint256 usdsAmount = dollarIn * 1e18;
        uint256 susdsAmount = IERC4626(SUSDS).convertToShares(usdsAmount);
        uint256 susdsRate = IERC4626(SUSDS).convertToAssets(1e18);

        console.log("\n=== Buy phUSD with sUSDS ===");
        console.log("PHUSD_BUY_DOLLAR_IN:", dollarIn);
        console.log("PHUSD_BUY_MIN_OUT:  ", minOutEther, "phUSD");
        console.log("sUSDS rate (USDS/sUSDS):", susdsRate);
        console.log("sUSDS to spend:     ", susdsAmount);
        console.log("Min phUSD out (wei):", minAmountOut);

        uint256 senderBalance = IERC20(SUSDS).balanceOf(msg.sender);
        console.log("Sender sUSDS balance:", senderBalance);
        require(senderBalance >= susdsAmount, "Insufficient sUSDS balance");

        vm.startBroadcast();

        // Approvals: ERC20 -> Permit2 -> Router
        IERC20(SUSDS).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(SUSDS, ROUTER, type(uint160).max, type(uint48).max);

        uint256 phusdReceived = IRouter(ROUTER).swapSingleTokenExactIn(
            POOL,
            IERC20(SUSDS),
            IERC20(PHUSD),
            susdsAmount,
            minAmountOut,
            block.timestamp + 300,
            false,
            ""
        );

        vm.stopBroadcast();

        console.log("\n=== Swap Complete ===");
        console.log("phUSD received:", phusdReceived);
        console.log("Effective rate (phUSD/sUSDS):", (phusdReceived * 1e18) / susdsAmount);
        console.log("\n");
    }
}
