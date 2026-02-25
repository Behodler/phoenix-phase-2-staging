// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter, IPermit2} from "./BalancerECLPInterfaces.sol";

/**
 * @title VerifyBalancerECLPPool
 * @notice Post-deploy verification script for the phUSD/sUSDS E-CLP pool.
 *         Runs on a forked Anvil ONLY -- uses `deal` to mint test tokens.
 *
 *         Executes small swaps in both directions and checks that:
 *           1. The effective exchange rate matches the expected fair rate.
 *           2. Slippage is approximately symmetric in both directions.
 *
 * @dev    Usage (preview on forked Anvil):
 *           anvil --fork-url $RPC_MAINNET
 *
 *           # Deploy pool on fork first:
 *           forge script script/interactions/CreateBalancerECLPPool.s.sol \
 *             --rpc-url http://localhost:8545 --broadcast --private-key $ANVIL_KEY
 *
 *           # Then verify (set POOL_ADDRESS from create output):
 *           POOL_ADDRESS=0x... forge script script/interactions/VerifyBalancerECLPPool.s.sol \
 *             --rpc-url http://localhost:8545 --broadcast --private-key $ANVIL_KEY
 */
contract VerifyBalancerECLPPool is Script, Test {
    // ──────────────────────────────────────────────
    //  Mainnet addresses (same as CreateBalancerECLPPool)
    // ──────────────────────────────────────────────
    address public constant PHUSD   = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant SUSDS   = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant ROUTER  = 0xAE563E3f8219521950555F5962419C8919758Ea2;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ──────────────────────────────────────────────
    //  Test parameters
    // ──────────────────────────────────────────────
    /// @dev Trade size for each test swap.  0.1 tokens is ~0.5% of the seed
    ///      liquidity so price impact is minimal -- lets us measure the
    ///      marginal rate rather than large-trade slippage.
    uint256 internal constant TRADE_AMOUNT = 100000000000000000; // 0.1 token

    /// @dev Expected fair rate: 1 sUSDS ≈ 1.0877 phUSD (snapshot at pool creation).
    ///      Selling 0.1 phUSD should yield ≈ 0.0919 sUSDS.
    ///      Selling 0.1 sUSDS should yield ≈ 0.1088 phUSD.
    ///      Both minus the 0.3% swap fee.
    uint256 internal constant EXPECTED_PHUSD_PER_SUSDS = 1087700000000000000; // 1.0877e18
    uint256 internal constant SWAP_FEE_BPS = 30; // 0.3%

    /// @dev Maximum allowed divergence between the two slippage values.
    ///      1e16 = 1% in 18-decimal.  Anything above this fails the check.
    uint256 internal constant MAX_SLIPPAGE_DIVERGENCE = 10000000000000000;

    function run() external {
        address pool = vm.envAddress("POOL_ADDRESS");

        console.log("\n=== Verify Balancer E-CLP Pool ===");
        console.log("Pool:   ", pool);
        console.log("Router: ", ROUTER);
        console.log("Trade:   0.1 tokens each direction");
        console.log("");

        // ── Deal test tokens to the sender ──
        deal(SUSDS, msg.sender, 10 ether);
        deal(PHUSD, msg.sender, 10 ether);

        vm.startBroadcast();

        // ── Approve Permit2 → Router ──
        IERC20(SUSDS).approve(PERMIT2, type(uint256).max);
        IERC20(PHUSD).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(SUSDS, ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(PHUSD, ROUTER, type(uint160).max, type(uint48).max);

        // ────────────────────────────────────────────
        //  Test 1: Sell 0.1 phUSD → sUSDS
        // ────────────────────────────────────────────
        uint256 susdsOut = IRouter(ROUTER).swapSingleTokenExactIn(
            pool,
            IERC20(PHUSD),
            IERC20(SUSDS),
            TRADE_AMOUNT,
            0,                  // minAmountOut -- accept anything for test
            block.timestamp,
            false,              // wethIsEth
            ""                  // userData
        );

        // ────────────────────────────────────────────
        //  Test 2: Sell 0.1 sUSDS → phUSD
        // ────────────────────────────────────────────
        uint256 phusdOut = IRouter(ROUTER).swapSingleTokenExactIn(
            pool,
            IERC20(SUSDS),
            IERC20(PHUSD),
            TRADE_AMOUNT,
            0,
            block.timestamp,
            false,
            ""
        );

        vm.stopBroadcast();

        // ────────────────────────────────────────────
        //  Analyse results
        // ────────────────────────────────────────────

        // Effective rates (scaled 1e18)
        // rate1 = sUSDS received per phUSD sold  (should be ≈ 1/1.0877 ≈ 0.9194)
        // rate2 = phUSD received per sUSDS sold  (should be ≈ 1.0877)
        uint256 rate_susds_per_phusd = (susdsOut * 1e18) / TRADE_AMOUNT;
        uint256 rate_phusd_per_susds = (phusdOut * 1e18) / TRADE_AMOUNT;

        // Expected rates (after 0.3% fee)
        uint256 expectedSusdsPerPhusd = (1e18 * 1e18 / EXPECTED_PHUSD_PER_SUSDS) * (10000 - SWAP_FEE_BPS) / 10000;
        uint256 expectedPhusdPerSusds = EXPECTED_PHUSD_PER_SUSDS * (10000 - SWAP_FEE_BPS) / 10000;

        console.log("--- Test 1: Sell 0.1 phUSD ---");
        console.log("  sUSDS received (wei):", susdsOut);
        console.log("  Effective rate (sUSDS/phUSD, 1e18):", rate_susds_per_phusd);
        console.log("  Expected rate  (sUSDS/phUSD, 1e18):", expectedSusdsPerPhusd);
        console.log("");

        console.log("--- Test 2: Sell 0.1 sUSDS ---");
        console.log("  phUSD received (wei):", phusdOut);
        console.log("  Effective rate (phUSD/sUSDS, 1e18):", rate_phusd_per_susds);
        console.log("  Expected rate  (phUSD/sUSDS, 1e18):", expectedPhusdPerSusds);
        console.log("");

        // ── Slippage from expected (basis points) ──
        // slippage = |actual - expected| / expected   (negative means worse than expected)
        uint256 slippage1;
        if (rate_susds_per_phusd >= expectedSusdsPerPhusd) {
            slippage1 = ((rate_susds_per_phusd - expectedSusdsPerPhusd) * 1e18) / expectedSusdsPerPhusd;
        } else {
            slippage1 = ((expectedSusdsPerPhusd - rate_susds_per_phusd) * 1e18) / expectedSusdsPerPhusd;
        }

        uint256 slippage2;
        if (rate_phusd_per_susds >= expectedPhusdPerSusds) {
            slippage2 = ((rate_phusd_per_susds - expectedPhusdPerSusds) * 1e18) / expectedPhusdPerSusds;
        } else {
            slippage2 = ((expectedPhusdPerSusds - rate_phusd_per_susds) * 1e18) / expectedPhusdPerSusds;
        }

        console.log("--- Slippage Analysis ---");
        console.log("  Slippage selling phUSD (1e18 = 100%):", slippage1);
        console.log("  Slippage selling sUSDS (1e18 = 100%):", slippage2);

        // ── Symmetry check ──
        uint256 divergence;
        if (slippage1 >= slippage2) {
            divergence = slippage1 - slippage2;
        } else {
            divergence = slippage2 - slippage1;
        }

        console.log("  Slippage divergence:                ", divergence);
        console.log("  Max allowed divergence (1%):        ", MAX_SLIPPAGE_DIVERGENCE);
        console.log("");

        // ── Rate sanity: product of rates should ≈ (1-fee)^2 ≈ 0.994 ──
        uint256 rateProduct = (rate_susds_per_phusd * rate_phusd_per_susds) / 1e18;
        uint256 expectedProduct = uint256(10000 - SWAP_FEE_BPS) * uint256(10000 - SWAP_FEE_BPS) * 1e18 / (10000 * 10000);

        console.log("--- Rate Product Sanity ---");
        console.log("  rate1 * rate2 (1e18):  ", rateProduct);
        console.log("  expected (1-fee)^2:    ", expectedProduct);
        console.log("");

        // ── Verdicts ──
        bool rateOk = rateProduct > 990000000000000000 && rateProduct < 1010000000000000000;
        bool symmetryOk = divergence <= MAX_SLIPPAGE_DIVERGENCE;

        if (rateOk && symmetryOk) {
            console.log("PASS: Pool rates are correct and slippage is symmetric.");
        } else {
            if (!rateOk) {
                console.log("FAIL: Rate product is outside [0.99, 1.01] -- pool may be mispriced.");
            }
            if (!symmetryOk) {
                console.log("FAIL: Slippage divergence exceeds 1% -- pool is asymmetric.");
            }
        }
        console.log("\n");
    }
}
