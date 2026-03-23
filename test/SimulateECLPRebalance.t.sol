// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter, IPermit2} from "../script/interactions/BalancerECLPInterfaces.sol";

interface IERC4626 {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}

/**
 * @title SimulateECLPRebalance
 * @notice Simulates swapping $7,000 worth of sUSDS into the phUSD/sUSDS e-CLP pool
 *         on a mainnet fork to check if it moves the pool back into the flat range.
 *
 *         Run with: forge test --fork-url $RPC_MAINNET --match-contract SimulateECLPRebalance -vvv
 */
contract SimulateECLPRebalance is Test {
    // ── Mainnet addresses ──
    address constant POOL           = 0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58;
    address constant SUSDS          = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant PHUSD          = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant ROUTER         = 0xAE563E3f8219521950555F5962419C8919758Ea2;
    address constant PERMIT2        = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;

    // ── e-CLP price bounds (phUSD per sUSDS, 18-decimal) ──
    int256 constant ALPHA  = 1035905000000000000;  // lower bound ~1.0359
    int256 constant BETA   = 1144947000000000000;  // upper bound ~1.1449
    uint256 constant SWAP_FEE_BPS = 30;            // 0.3%

    // ── Tiny probe trade for measuring marginal rate ──
    uint256 constant PROBE_AMOUNT = 1e15; // 0.001 sUSDS

    address trader;

    function setUp() public {
        trader = makeAddr("rebalance-trader");
    }

    function testSimulateRebalance() public {
        // ────────────────────────────────────────
        //  1. Read PHUSD_BUY_DOLLAR_IN and convert to sUSDS
        // ────────────────────────────────────────
        uint256 dollarIn = vm.envUint("PHUSD_BUY_DOLLAR_IN");
        uint256 targetUSD = dollarIn * 1e18; // USDS amount (assuming USDS = $1)
        uint256 susdsAmount = IERC4626(SUSDS).convertToShares(targetUSD);
        uint256 susdsRate = IERC4626(SUSDS).convertToAssets(1e18);

        console.log("\n========================================");
        console.log("  e-CLP Rebalance Simulation (sUSDS -> phUSD)");
        console.log("========================================\n");
        console.log("PHUSD_BUY_DOLLAR_IN:       ", dollarIn);
        console.log("sUSDS rate (USDS per sUSDS):", susdsRate);
        console.log("sUSDS to swap:             ", susdsAmount);
        console.log("");

        // ────────────────────────────────────────
        //  2. Deal sUSDS to trader
        // ────────────────────────────────────────
        deal(SUSDS, trader, susdsAmount + PROBE_AMOUNT * 2);
        assertGt(IERC20(SUSDS).balanceOf(trader), susdsAmount, "deal failed for sUSDS");

        // ────────────────────────────────────────
        //  3. Set up approvals
        // ────────────────────────────────────────
        vm.startPrank(trader);
        IERC20(SUSDS).approve(PERMIT2, type(uint256).max);
        IERC20(PHUSD).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(SUSDS, ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(PHUSD, ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // ────────────────────────────────────────
        //  4. Measure BEFORE state
        // ────────────────────────────────────────
        console.log("--- BEFORE Swap ---");
        _logVaultBalances();
        (uint256 rateBefore, bool inRangeBefore) = _measureMarginalRate();
        console.log("Marginal rate (phUSD/sUSDS, 1e18):", rateBefore);
        console.log("In flat range:                    ", inRangeBefore ? "YES" : "NO");
        console.log("");

        // ────────────────────────────────────────
        //  5. Execute the $7k swap: sUSDS -> phUSD
        // ────────────────────────────────────────
        vm.startPrank(trader);
        uint256 phusdReceived = IRouter(ROUTER).swapSingleTokenExactIn(
            POOL,
            IERC20(SUSDS),
            IERC20(PHUSD),
            susdsAmount,
            0,                  // minAmountOut — simulation, accept anything
            block.timestamp + 300,
            false,              // wethIsEth
            ""
        );
        vm.stopPrank();

        console.log("--- SWAP RESULT ---");
        console.log("sUSDS sold:    ", susdsAmount);
        console.log("phUSD received:", phusdReceived);
        uint256 swapRate = (phusdReceived * 1e18) / susdsAmount;
        console.log("Effective rate (phUSD/sUSDS):", swapRate);
        console.log("");

        // ────────────────────────────────────────
        //  6. Measure AFTER state
        // ────────────────────────────────────────
        console.log("--- AFTER Swap ---");
        _logVaultBalances();
        (uint256 rateAfter, bool inRangeAfter) = _measureMarginalRate();
        console.log("Marginal rate (phUSD/sUSDS, 1e18):", rateAfter);
        console.log("In flat range:                    ", inRangeAfter ? "YES" : "NO");
        console.log("");

        // ────────────────────────────────────────
        //  7. Summary
        // ────────────────────────────────────────
        console.log("========================================");
        console.log("  SUMMARY");
        console.log("========================================");
        console.log("Alpha (lower bound): ", uint256(ALPHA));
        console.log("Beta  (upper bound): ", uint256(BETA));
        console.log("Rate BEFORE swap:    ", rateBefore);
        console.log("Rate AFTER  swap:    ", rateAfter);
        console.log("");

        // Midpoint of the flat range
        uint256 midpoint = (uint256(ALPHA) + uint256(BETA)) / 2;
        console.log("Flat range midpoint: ", midpoint);

        if (inRangeAfter) {
            // How close to midpoint? (as %)
            uint256 distFromMid;
            if (rateAfter > midpoint) {
                distFromMid = rateAfter - midpoint;
            } else {
                distFromMid = midpoint - rateAfter;
            }
            uint256 halfRange = (uint256(BETA) - uint256(ALPHA)) / 2;
            uint256 positionPct = (distFromMid * 100) / halfRange;
            console.log("Distance from midpoint (%% of half-range):", positionPct);
            console.log("");
            console.log("RESULT: Pool IS in the flat range after the swap.");
        } else {
            if (rateAfter > uint256(BETA)) {
                console.log("Pool is ABOVE the flat range (still too little sUSDS).");
                console.log("Need more sUSDS to push it into range.");
                // Estimate how much more is needed (rough)
                console.log("Overshot amount: rate still above beta");
            } else if (rateAfter < uint256(ALPHA)) {
                console.log("Pool is BELOW the flat range (too much sUSDS now).");
                console.log("$7k was too much - pool overshot.");
            }
            console.log("");
            console.log("RESULT: Pool is NOT in the flat range after the swap.");
        }
        console.log("========================================\n");
    }

    /// @dev Swaps a tiny amount of sUSDS -> phUSD to measure the marginal exchange rate.
    ///      Returns the fee-adjusted marginal rate and whether it's within [alpha, beta].
    function _measureMarginalRate() internal returns (uint256 marginalRate, bool inRange) {
        // Deal a small amount for the probe
        deal(SUSDS, trader, IERC20(SUSDS).balanceOf(trader) + PROBE_AMOUNT);

        vm.startPrank(trader);
        uint256 phusdOut = IRouter(ROUTER).swapSingleTokenExactIn(
            POOL,
            IERC20(SUSDS),
            IERC20(PHUSD),
            PROBE_AMOUNT,
            0,
            block.timestamp + 300,
            false,
            ""
        );
        vm.stopPrank();

        // Gross rate (before fee adjustment)
        uint256 grossRate = (phusdOut * 1e18) / PROBE_AMOUNT;
        // Adjust for 0.3% swap fee to get true marginal rate
        marginalRate = (grossRate * 10000) / (10000 - SWAP_FEE_BPS);

        inRange = (int256(marginalRate) >= ALPHA && int256(marginalRate) <= BETA);
    }

    function testFindExactPegAmount() public {
        uint256 susdsRate = IERC4626(SUSDS).convertToAssets(1e18);

        // Target marginal rate for phUSD = $1.00:
        //   1 sUSDS = susdsRate USD, and if 1 phUSD = $1 then 1 sUSDS = susdsRate phUSD
        uint256 targetRate = susdsRate;

        console.log("\n========================================");
        console.log("  Binary Search: sUSDS needed for phUSD = $1.00");
        console.log("========================================\n");
        console.log("sUSDS rate (USDS per sUSDS):", susdsRate);
        console.log("Target marginal rate:       ", targetRate);
        console.log("");

        // Binary search bounds (in sUSDS wei)
        // Low = 0, High = enough to push well past peg (~$20k worth)
        uint256 lo = 0;
        uint256 hi = (20000e18 * 1e18) / susdsRate;

        uint256 bestAmount;
        uint256 bestRate;
        uint256 iterations;

        // Converge to within 0.01 sUSDS
        while (hi - lo > 1e16) {
            uint256 mid = (lo + hi) / 2;
            uint256 rate = _simulateSwapAndMeasure(mid);
            iterations++;

            if (rate > targetRate) {
                // Rate too high = phUSD still below $1 = need more sUSDS
                lo = mid;
            } else {
                // Rate at or below target = phUSD at or above $1
                hi = mid;
                bestAmount = mid;
                bestRate = rate;
            }
        }

        // Final precise measurement
        bestRate = _simulateSwapAndMeasure(hi);
        bestAmount = hi;

        uint256 dollarValue = (bestAmount * susdsRate) / 1e18;
        uint256 phusdPrice = (susdsRate * 1e18) / bestRate;

        console.log("--- RESULT ---");
        console.log("sUSDS needed:           ", bestAmount);
        console.log("Dollar value:           ", dollarValue);
        console.log("Post-swap marginal rate:", bestRate);
        console.log("Implied phUSD price:    ", phusdPrice);
        console.log("Iterations:             ", iterations);
        console.log("");

        // Also show the post-swap pool state
        console.log("--- Post-swap pool state ---");
        // Do one final sim with the exact amount to show balances
        _setupTrader(bestAmount);
        vm.startPrank(trader);
        uint256 phusdReceived = IRouter(ROUTER).swapSingleTokenExactIn(
            POOL, IERC20(SUSDS), IERC20(PHUSD),
            bestAmount, 0, block.timestamp + 300, false, ""
        );
        vm.stopPrank();

        _logVaultBalances();
        console.log("phUSD received from swap:", phusdReceived);
        console.log("========================================\n");
    }

    /// @dev Snapshots state, simulates a swap of `amount` sUSDS, measures rate, then reverts.
    function _simulateSwapAndMeasure(uint256 amount) internal returns (uint256 marginalRate) {
        uint256 snap = vm.snapshotState();

        _setupTrader(amount + PROBE_AMOUNT);

        // Do the main swap
        vm.startPrank(trader);
        IRouter(ROUTER).swapSingleTokenExactIn(
            POOL, IERC20(SUSDS), IERC20(PHUSD),
            amount, 0, block.timestamp + 300, false, ""
        );
        vm.stopPrank();

        // Measure marginal rate after
        (marginalRate,) = _measureMarginalRate();

        vm.revertToState(snap);
    }

    function _setupTrader(uint256 susdsNeeded) internal {
        deal(SUSDS, trader, susdsNeeded);
        vm.startPrank(trader);
        IERC20(SUSDS).approve(PERMIT2, type(uint256).max);
        IERC20(PHUSD).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(SUSDS, ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(PHUSD, ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _logVaultBalances() internal view {
        uint256 vaultSusds = IERC20(SUSDS).balanceOf(BALANCER_VAULT);
        uint256 vaultPhusd = IERC20(PHUSD).balanceOf(BALANCER_VAULT);
        console.log("Vault sUSDS balance:", vaultSusds);
        console.log("Vault phUSD balance:", vaultPhusd);
    }
}
