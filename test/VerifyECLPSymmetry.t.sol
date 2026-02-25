// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Test.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IGyroECLPPool,
    IGyroECLPPoolFactory,
    IRouter,
    IPermit2,
    IRateProvider,
    TokenConfig,
    TokenType,
    PoolRoleAccounts
} from "../script/interactions/BalancerECLPInterfaces.sol";

/**
 * @title VerifyECLPSymmetry
 * @notice Fork test that deploys an E-CLP pool and verifies slippage symmetry.
 *
 *         Run with:
 *           source .envrc && forge test --fork-url $RPC_MAINNET \
 *             --match-contract VerifyECLPSymmetry -vvv
 */
contract VerifyECLPSymmetry is Test {
    // ── Mainnet addresses ──
    address constant PHUSD   = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant SUSDS   = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant FACTORY = 0xE9B0a3bc48178D7FE2F5453C8bc1415d73F966d0;
    address constant ROUTER  = 0xAE563E3f8219521950555F5962419C8919758Ea2;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // ── Pool parameters ──
    uint256 constant SWAP_FEE       = 3000000000000000;  // 0.3%
    uint256 constant SEED_SUSDS     = 20 ether;
    uint256 constant SEED_PHUSD     = 21754000000000000000; // ~21.754
    uint256 constant TRADE_AMOUNT   = 100000000000000000;   // 0.1 token

    // ── Expected fair rate: 1 sUSDS ≈ 1.0877 phUSD ──
    uint256 constant EXPECTED_RATE  = 1087700000000000000;

    address deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        deal(SUSDS, deployer, 100 ether);
        deal(PHUSD, deployer, 100 ether);
    }

    // ─────────────────────────────────────────────────────
    //  Helper: deploy a pool with the given alpha/beta
    // ─────────────────────────────────────────────────────
    function _deployPool(
        int256 alpha,
        int256 beta,
        IGyroECLPPool.DerivedEclpParams memory derived,
        bytes32 salt
    ) internal returns (address pool) {
        IGyroECLPPool.EclpParams memory params = IGyroECLPPool.EclpParams({
            alpha:  alpha,
            beta:   beta,
            c:      1e18,
            s:      0,
            lambda: 50e18
        });

        TokenConfig[] memory tokens = new TokenConfig[](2);
        tokens[0] = TokenConfig(IERC20(SUSDS), TokenType.STANDARD, IRateProvider(address(0)), false);
        tokens[1] = TokenConfig(IERC20(PHUSD), TokenType.STANDARD, IRateProvider(address(0)), false);

        PoolRoleAccounts memory roles = PoolRoleAccounts(address(0), address(0), address(0));

        vm.startPrank(deployer);

        pool = IGyroECLPPoolFactory(FACTORY).create(
            "test", "TEST", tokens, params, derived, roles,
            SWAP_FEE, address(0), true, false, salt
        );

        // Approve & seed
        IERC20(SUSDS).approve(PERMIT2, type(uint256).max);
        IERC20(PHUSD).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(SUSDS, ROUTER, type(uint160).max, type(uint48).max);
        IPermit2(PERMIT2).approve(PHUSD, ROUTER, type(uint160).max, type(uint48).max);

        IERC20[] memory poolTokens = new IERC20[](2);
        poolTokens[0] = IERC20(SUSDS);
        poolTokens[1] = IERC20(PHUSD);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SEED_SUSDS;
        amounts[1] = SEED_PHUSD;

        IRouter(ROUTER).initialize(pool, poolTokens, amounts, 0, false, "");
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    //  Helper: swap and return amount out
    // ─────────────────────────────────────────────────────
    function _swap(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal returns (uint256 amountOut)
    {
        vm.prank(deployer);
        amountOut = IRouter(ROUTER).swapSingleTokenExactIn(
            pool,
            IERC20(tokenIn),
            IERC20(tokenOut),
            amountIn,
            0,
            block.timestamp,
            false,
            ""
        );
    }

    // ─────────────────────────────────────────────────────
    //  Helper: analyse rates and print report
    // ─────────────────────────────────────────────────────
    function _analyseAndReport(
        string memory label,
        uint256 susdsOut,
        uint256 phusdOut
    ) internal pure returns (uint256 divergence) {
        uint256 rateSusdsPerPhusd = (susdsOut * 1e18) / TRADE_AMOUNT;
        uint256 ratePhusdPerSusds = (phusdOut * 1e18) / TRADE_AMOUNT;

        // After 0.3% fee, expected rates
        uint256 expectedSusds = (1e18 * 1e18 / EXPECTED_RATE) * 9970 / 10000;
        uint256 expectedPhusd = EXPECTED_RATE * 9970 / 10000;

        console.log(string.concat("\n--- ", label, " ---"));
        console.log("  Sell 0.1 phUSD -> sUSDS out (wei):", susdsOut);
        console.log("  Rate sUSDS/phUSD (1e18):          ", rateSusdsPerPhusd);
        console.log("  Expected (1e18):                  ", expectedSusds);
        console.log("");
        console.log("  Sell 0.1 sUSDS -> phUSD out (wei):", phusdOut);
        console.log("  Rate phUSD/sUSDS (1e18):          ", ratePhusdPerSusds);
        console.log("  Expected (1e18):                  ", expectedPhusd);

        // Slippage from expected
        uint256 slip1 = _absDiff(rateSusdsPerPhusd, expectedSusds) * 1e18 / expectedSusds;
        uint256 slip2 = _absDiff(ratePhusdPerSusds, expectedPhusd) * 1e18 / expectedPhusd;

        console.log("");
        console.log("  Slippage sell-phUSD (1e18=100%):  ", slip1);
        console.log("  Slippage sell-sUSDS (1e18=100%):  ", slip2);

        divergence = _absDiff(slip1, slip2);
        console.log("  Slippage divergence:              ", divergence);

        uint256 rateProduct = (rateSusdsPerPhusd * ratePhusdPerSusds) / 1e18;
        console.log("  Rate product (expect ~0.994):     ", rateProduct);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    // ═════════════════════════════════════════════════════
    //  TEST: Old (broken) parameters  -- expected to FAIL
    // ═════════════════════════════════════════════════════
    function testOldParams_asymmetric() public {
        IGyroECLPPool.DerivedEclpParams memory derived = IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({
                x: int256(99973793560945615441476363411540017610),
                y: int256(2289235906023885632801359324762630279)
            }),
            tauBeta: IGyroECLPPool.Vector2({
                x: int256(99978545790518769748260973171700762398),
                y: int256(2071323637952694691783284211815516557)
            }),
            u: 0,
            v: int256(2289235906023885632801359324762630279),
            w: 0,
            z: int256(99978545790518769748260973171700762398),
            dSq: int256(100000000000000000000000000000000000000)
        });

        address pool = _deployPool(
            873425000000000000,   // old alpha (sUSDS/phUSD -- WRONG convention)
            965359000000000000,   // old beta
            derived,
            keccak256("old-test")
        );

        uint256 susdsOut = _swap(pool, PHUSD, SUSDS, TRADE_AMOUNT);
        uint256 phusdOut = _swap(pool, SUSDS, PHUSD, TRADE_AMOUNT);

        _analyseAndReport("OLD PARAMS (expect asymmetric)", susdsOut, phusdOut);

        // Old params: selling phUSD gives ~1.083 sUSDS (should give ~0.917).
        // The rate is essentially the reciprocal of what it should be.
        // Check that the sUSDS/phUSD rate is >15% above expected.
        uint256 rateSusdsPerPhusd = (susdsOut * 1e18) / TRADE_AMOUNT;
        uint256 expectedSusds = (1e18 * 1e18 / EXPECTED_RATE) * 9970 / 10000;
        assertGt(
            rateSusdsPerPhusd,
            expectedSusds * 115 / 100,
            "Old params: selling phUSD should give >15% more sUSDS than fair (inverted convention)"
        );
        console.log("\n  CONFIRMED: Old params have inverted price convention (~18% mispricing)");
    }

    // ═════════════════════════════════════════════════════
    //  TEST: Large trades (1 token) to see price impact
    // ═════════════════════════════════════════════════════
    function testNewParams_largeTrade() public {
        IGyroECLPPool.DerivedEclpParams memory derived = IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({
                x: int256(99981367602332163269692323144458353703),
                y: int256(1930319239743647598374220090538386313)
            }),
            tauBeta: IGyroECLPPool.Vector2({
                x: int256(99984746838998994989324367248967173323),
                y: int256(1746539304247253278786255909644152494)
            }),
            u: 0,
            v: int256(1930319239743647598374220090538386313),
            w: 0,
            z: int256(99984746838998994989324367248967173323),
            dSq: int256(100000000000000000000000000000000000000)
        });

        address pool = _deployPool(
            1035905000000000000,
            1144947000000000000,
            derived,
            keccak256("large-test")
        );

        // Test with 1 token (5% of pool) instead of 0.1
        uint256 oneToken = 1 ether;

        uint256 susdsOut = _swap(pool, PHUSD, SUSDS, oneToken);
        uint256 phusdOut = _swap(pool, SUSDS, PHUSD, oneToken);

        uint256 rateSusdsPerPhusd = (susdsOut * 1e18) / oneToken;
        uint256 ratePhusdPerSusds = (phusdOut * 1e18) / oneToken;

        uint256 expectedSusds = (1e18 * 1e18 / EXPECTED_RATE) * 9970 / 10000;
        uint256 expectedPhusd = EXPECTED_RATE * 9970 / 10000;

        console.log("\n--- LARGE TRADE (1 token each) ---");
        console.log("  Pool has 20 sUSDS + 21.754 phUSD");
        console.log("");
        console.log("  Sell 1 phUSD -> sUSDS out (wei):", susdsOut);
        console.log("  Rate sUSDS/phUSD (1e18):        ", rateSusdsPerPhusd);
        console.log("  Expected (no impact, 1e18):     ", expectedSusds);
        console.log("");
        console.log("  Sell 1 sUSDS -> phUSD out (wei):", phusdOut);
        console.log("  Rate phUSD/sUSDS (1e18):        ", ratePhusdPerSusds);
        console.log("  Expected (no impact, 1e18):     ", expectedPhusd);

        uint256 impact1 = _absDiff(rateSusdsPerPhusd, expectedSusds) * 10000 / expectedSusds;
        uint256 impact2 = _absDiff(ratePhusdPerSusds, expectedPhusd) * 10000 / expectedPhusd;
        console.log("");
        console.log("  Price impact sell-phUSD (bps):  ", impact1);
        console.log("  Price impact sell-sUSDS (bps):  ", impact2);
    }

    // ═════════════════════════════════════════════════════
    //  TEST: New (fixed) parameters  -- expected to PASS
    // ═════════════════════════════════════════════════════
    function testNewParams_symmetric() public {
        IGyroECLPPool.DerivedEclpParams memory derived = IGyroECLPPool.DerivedEclpParams({
            tauAlpha: IGyroECLPPool.Vector2({
                x: int256(99981367602332163269692323144458353703),
                y: int256(1930319239743647598374220090538386313)
            }),
            tauBeta: IGyroECLPPool.Vector2({
                x: int256(99984746838998994989324367248967173323),
                y: int256(1746539304247253278786255909644152494)
            }),
            u: 0,
            v: int256(1930319239743647598374220090538386313),
            w: 0,
            z: int256(99984746838998994989324367248967173323),
            dSq: int256(100000000000000000000000000000000000000)
        });

        address pool = _deployPool(
            1035905000000000000,  // new alpha (phUSD/sUSDS -- CORRECT convention)
            1144947000000000000,  // new beta
            derived,
            keccak256("new-test")
        );

        uint256 susdsOut = _swap(pool, PHUSD, SUSDS, TRADE_AMOUNT);
        uint256 phusdOut = _swap(pool, SUSDS, PHUSD, TRADE_AMOUNT);

        uint256 divergence = _analyseAndReport("NEW PARAMS (expect symmetric)", susdsOut, phusdOut);

        // New params: divergence should be under 1%
        assertLt(divergence, 10000000000000000, "New params should be symmetric (divergence < 1%)");
        console.log("\n  CONFIRMED: New params are symmetric (divergence < 1%)");
    }
}
