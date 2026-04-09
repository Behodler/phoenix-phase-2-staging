// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IYieldStrategy {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
    function totalWithdrawal(address token, address client) external;
}

interface IMinter {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
    function noMintDeposit(address yieldStrategy, address inputToken, uint256 amount) external;
}

interface IAccumulator {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
}

interface ICurveRouterNG {
    function exchange(
        address[11] calldata _route,
        uint256[5][5] calldata _swap_params,
        uint256 _amount,
        uint256 _expected,
        address[5] calldata _pools,
        address _receiver
    ) external payable returns (uint256);
}

/**
 * @title RebalanceUSDeExecute
 * @notice Phase 2 of USDe rebalance: completes withdrawals from USDCYieldStrategy and
 *         DolaYieldStrategy, re-deposits 85% back, swaps 15% to USDe via Curve Router NG,
 *         and deposits USDe into USDeYieldStrategy via noMintDeposit.
 *
 *         Prerequisites: RebalanceUSDeInitiate.s.sol must have been run >= 24h ago.
 *
 *         Phase A - Pause and take control of all 5 contracts
 *         Phase B - Execute withdrawals (funds go to OWNER)
 *         Phase C - Re-deposit 85% back into each strategy
 *         Phase D - Curve swaps: 15% USDC -> USDe, 15% DOLA -> USDe
 *         Phase E - Deposit total USDe into USDeYieldStrategy
 *         Phase F - Restore system state
 *         Phase G - Post-flight verification
 */
contract RebalanceUSDeExecute is Script {
    // ── Yield Strategies ──
    address constant USDC_YS = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address constant DOLA_YS = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;
    address constant USDE_YS = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;

    // ── Core Protocol ──
    address constant PHUSD_STABLE_MINTER     = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant STABLE_YIELD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant GLOBAL_PAUSER           = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // ── Tokens ──
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 decimals
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4; // 18 decimals
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3; // 18 decimals
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 decimals
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD; // verified on-chain

    // ── Curve Infrastructure ──
    address constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;

    // Curve Pools
    address constant POOL_USDC_USDE      = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72; // coin0=USDe, coin1=USDC
    address constant POOL_DOLA_SUSDS     = 0x8b83c4aA949254895507D09365229BC3a8c7f710; // coin0=DOLA, coin1=sUSDS
    address constant POOL_SUSDS_USDT     = 0x00836Fe54625BE242BcFA286207795405ca4fD10; // coin0=sUSDS, coin1=USDT
    address constant POOL_USDT_USDE      = 0x5B03CcCAb7BA3010fA5CAd23746cbf0794938e96; // coin0=USDT, coin1=USDe

    // ── Accounts ──
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        IYieldStrategy usdcYS = IYieldStrategy(USDC_YS);
        IYieldStrategy dolaYS = IYieldStrategy(DOLA_YS);
        IYieldStrategy usdeYS = IYieldStrategy(USDE_YS);
        IMinter minter = IMinter(PHUSD_STABLE_MINTER);
        IAccumulator accumulator = IAccumulator(STABLE_YIELD_ACCUMULATOR);
        ICurveRouterNG router = ICurveRouterNG(CURVE_ROUTER_NG);

        // ============================================================
        // PRE-FLIGHT LOGGING
        // ============================================================
        uint256 usdcPrincipalBefore = usdcYS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 usdcTotalBalBefore = usdcYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        uint256 dolaPrincipalBefore = dolaYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 dolaTotalBalBefore = dolaYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 usdePrincipalBefore = usdeYS.principalOf(USDE, PHUSD_STABLE_MINTER);
        uint256 usdeTotalBalBefore = usdeYS.totalBalanceOf(USDE, PHUSD_STABLE_MINTER);

        address originalUsdcYSPauser = usdcYS.pauser();
        address originalDolaYSPauser = dolaYS.pauser();
        address originalUsdeYSPauser = usdeYS.pauser();
        address originalMinterPauser = minter.pauser();
        address originalAccumulatorPauser = accumulator.pauser();

        uint256 ownerUsdcBefore = IERC20(USDC).balanceOf(OWNER);
        uint256 ownerDolaBefore = IERC20(DOLA).balanceOf(OWNER);
        uint256 ownerUsdeBefore = IERC20(USDE).balanceOf(OWNER);

        console.log("\n=== RebalanceUSDeExecute Pre-flight ===");
        console.log("--- USDC YieldStrategy ---");
        console.log("Principal (wei):            ", usdcPrincipalBefore);
        console.log("Principal (USDC):           ", usdcPrincipalBefore / 1e6);
        console.log("TotalBalance (wei):         ", usdcTotalBalBefore);
        console.log("TotalBalance (USDC):        ", usdcTotalBalBefore / 1e6);

        console.log("\n--- DOLA YieldStrategy ---");
        console.log("Principal (wei):            ", dolaPrincipalBefore);
        console.log("Principal (DOLA):           ", dolaPrincipalBefore / 1e18);
        console.log("TotalBalance (wei):         ", dolaTotalBalBefore);
        console.log("TotalBalance (DOLA):        ", dolaTotalBalBefore / 1e18);

        console.log("\n--- USDe YieldStrategy ---");
        console.log("Principal (wei):            ", usdePrincipalBefore);
        console.log("TotalBalance (wei):         ", usdeTotalBalBefore);

        console.log("\n--- Owner balances ---");
        console.log("USDC:                       ", ownerUsdcBefore);
        console.log("DOLA:                       ", ownerDolaBefore);
        console.log("USDe:                       ", ownerUsdeBefore);

        console.log("\n--- Original pausers ---");
        console.log("USDC YS pauser:             ", originalUsdcYSPauser);
        console.log("DOLA YS pauser:             ", originalDolaYSPauser);
        console.log("USDe YS pauser:             ", originalUsdeYSPauser);
        console.log("Minter pauser:              ", originalMinterPauser);
        console.log("Accumulator pauser:         ", originalAccumulatorPauser);

        vm.startBroadcast(OWNER);

        // ============================================================
        // PHASE A - PAUSE AND TAKE CONTROL
        // ============================================================
        // Take pauser ownership and pause all 5 contracts

        usdcYS.setPauser(OWNER);
        usdcYS.pause();

        dolaYS.setPauser(OWNER);
        dolaYS.pause();

        usdeYS.setPauser(OWNER);
        usdeYS.pause();

        minter.setPauser(OWNER);
        minter.pause();

        accumulator.setPauser(OWNER);
        accumulator.pause();

        // ============================================================
        // PHASE B - EXECUTE WITHDRAWALS (funds go to OWNER)
        // ============================================================

        // --- USDC withdrawal ---
        usdcYS.unpause();
        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(OWNER);
        usdcYS.totalWithdrawal(USDC, PHUSD_STABLE_MINTER);
        uint256 usdcReceived = IERC20(USDC).balanceOf(OWNER) - usdcBalanceBefore;
        usdcYS.pause();
        console.log("\nUSDC received from withdrawal:", usdcReceived);
        console.log("USDC received (USDC):        ", usdcReceived / 1e6);

        // --- DOLA withdrawal ---
        dolaYS.unpause();
        uint256 dolaBalanceBefore = IERC20(DOLA).balanceOf(OWNER);
        dolaYS.totalWithdrawal(DOLA, PHUSD_STABLE_MINTER);
        uint256 dolaReceived = IERC20(DOLA).balanceOf(OWNER) - dolaBalanceBefore;
        dolaYS.pause();
        console.log("DOLA received from withdrawal:", dolaReceived);
        console.log("DOLA received (DOLA):        ", dolaReceived / 1e18);

        // --- Calculate 85%/15% splits ---
        uint256 usdcRedeposit = usdcReceived * 85 / 100;
        uint256 usdcToSwap = usdcReceived - usdcRedeposit;
        uint256 dolaRedeposit = dolaReceived * 85 / 100;
        uint256 dolaToSwap = dolaReceived - dolaRedeposit;

        console.log("\nUSDC redeposit (85%):        ", usdcRedeposit);
        console.log("USDC to swap (15%):          ", usdcToSwap);
        console.log("DOLA redeposit (85%):        ", dolaRedeposit);
        console.log("DOLA to swap (15%):          ", dolaToSwap);

        // ============================================================
        // PHASE C - RE-DEPOSIT 85% BACK
        // ============================================================

        // Unpause minter (needed for noMintDeposit)
        minter.unpause();

        // --- Re-deposit 85% USDC ---
        usdcYS.unpause();
        IERC20(USDC).approve(PHUSD_STABLE_MINTER, usdcRedeposit);
        minter.noMintDeposit(USDC_YS, USDC, usdcRedeposit);
        usdcYS.pause();
        usdcYS.setPauser(originalUsdcYSPauser);
        console.log("\nRe-deposited USDC:           ", usdcRedeposit / 1e6);

        // --- Re-deposit 85% DOLA ---
        dolaYS.unpause();
        IERC20(DOLA).approve(PHUSD_STABLE_MINTER, dolaRedeposit);
        minter.noMintDeposit(DOLA_YS, DOLA, dolaRedeposit);
        dolaYS.pause();
        dolaYS.setPauser(originalDolaYSPauser);
        console.log("Re-deposited DOLA:           ", dolaRedeposit / 1e18);

        // ============================================================
        // PHASE D - CURVE SWAPS (15% USDC + 15% DOLA -> USDe)
        // ============================================================

        // --- USDC -> USDe (1-hop) ---
        // Pool: 0x02950460... coin0=USDe, coin1=USDC
        // USDC->USDe: i=1, j=0
        address[11] memory usdcPath;
        usdcPath[0] = USDC;
        usdcPath[1] = POOL_USDC_USDE;
        usdcPath[2] = USDE;

        uint256[5][5] memory usdcSwapParams;
        usdcSwapParams[0] = [uint256(1), 0, 1, 10, 2]; // i=1(USDC), j=0(USDe), exchange, stableswap-ng, 2 coins

        address[5] memory emptyPools;

        // Slippage: 0.1% with 6->18 decimal conversion
        uint256 minUsdeFromUsdc = uint256(usdcToSwap) * 1e12 * 999 / 1000;

        IERC20(USDC).approve(CURVE_ROUTER_NG, usdcToSwap);
        uint256 usdeFromUsdc = router.exchange(usdcPath, usdcSwapParams, usdcToSwap, minUsdeFromUsdc, emptyPools, OWNER);
        console.log("\nUSDe from USDC swap:         ", usdeFromUsdc);

        // --- DOLA -> USDe (3-hop: DOLA -> sUSDS -> USDT -> USDe) ---
        // Hop 1: Dola/sUSDS pool - coin0=DOLA, coin1=sUSDS - i=0, j=1
        // Hop 2: sUSDS/USDT pool - coin0=sUSDS, coin1=USDT - i=0, j=1
        // Hop 3: USDT/USDe pool  - coin0=USDT, coin1=USDe  - i=0, j=1
        address[11] memory dolaPath;
        dolaPath[0] = DOLA;
        dolaPath[1] = POOL_DOLA_SUSDS;
        dolaPath[2] = SUSDS;
        dolaPath[3] = POOL_SUSDS_USDT;
        dolaPath[4] = USDT;
        dolaPath[5] = POOL_USDT_USDE;
        dolaPath[6] = USDE;

        uint256[5][5] memory dolaSwapParams;
        dolaSwapParams[0] = [uint256(0), 1, 1, 10, 2]; // hop 1: DOLA(0)->sUSDS(1), exchange, stableswap-ng, 2
        dolaSwapParams[1] = [uint256(0), 1, 1, 10, 2]; // hop 2: sUSDS(0)->USDT(1), exchange, stableswap-ng, 2
        dolaSwapParams[2] = [uint256(0), 1, 1, 10, 2]; // hop 3: USDT(0)->USDe(1), exchange, stableswap-ng, 2

        // Slippage: 0.1% (both 18 decimals)
        uint256 minUsdeFromDola = dolaToSwap * 999 / 1000;

        IERC20(DOLA).approve(CURVE_ROUTER_NG, dolaToSwap);
        uint256 usdeFromDola = router.exchange(dolaPath, dolaSwapParams, dolaToSwap, minUsdeFromDola, emptyPools, OWNER);
        console.log("USDe from DOLA swap:         ", usdeFromDola);

        uint256 totalUsde = usdeFromUsdc + usdeFromDola;
        console.log("Total USDe from swaps:       ", totalUsde);

        // ============================================================
        // PHASE E - DEPOSIT USDe INTO USDeYieldStrategy
        // ============================================================

        usdeYS.unpause();
        IERC20(USDE).approve(PHUSD_STABLE_MINTER, totalUsde);
        minter.noMintDeposit(USDE_YS, USDE, totalUsde);
        usdeYS.pause();
        usdeYS.setPauser(originalUsdeYSPauser);
        console.log("\nDeposited USDe into USDeYS:  ", totalUsde);

        // ============================================================
        // PHASE F - RESTORE SYSTEM STATE
        // ============================================================

        // Minter is already unpaused from Phase C - restore its pauser
        minter.setPauser(originalMinterPauser);

        // Unpause accumulator and restore its pauser
        accumulator.unpause();
        accumulator.setPauser(originalAccumulatorPauser);

        vm.stopBroadcast();

        // ============================================================
        // PHASE G - POST-FLIGHT VERIFICATION
        // ============================================================

        uint256 usdcPrincipalAfter = usdcYS.principalOf(USDC, PHUSD_STABLE_MINTER);
        uint256 usdcTotalBalAfter = usdcYS.totalBalanceOf(USDC, PHUSD_STABLE_MINTER);
        uint256 dolaPrincipalAfter = dolaYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 dolaTotalBalAfter = dolaYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 usdePrincipalAfter = usdeYS.principalOf(USDE, PHUSD_STABLE_MINTER);
        uint256 usdeTotalBalAfter = usdeYS.totalBalanceOf(USDE, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");

        console.log("--- USDC YieldStrategy ---");
        console.log("Principal after (wei):      ", usdcPrincipalAfter);
        console.log("Principal after (USDC):     ", usdcPrincipalAfter / 1e6);
        console.log("TotalBalance after (wei):   ", usdcTotalBalAfter);
        console.log("TotalBalance after (USDC):  ", usdcTotalBalAfter / 1e6);

        console.log("\n--- DOLA YieldStrategy ---");
        console.log("Principal after (wei):      ", dolaPrincipalAfter);
        console.log("Principal after (DOLA):     ", dolaPrincipalAfter / 1e18);
        console.log("TotalBalance after (wei):   ", dolaTotalBalAfter);
        console.log("TotalBalance after (DOLA):  ", dolaTotalBalAfter / 1e18);

        console.log("\n--- USDe YieldStrategy ---");
        console.log("Principal after (wei):      ", usdePrincipalAfter);
        console.log("TotalBalance after (wei):   ", usdeTotalBalAfter);

        // Assert USDC YS principal == usdcRedeposit
        require(usdcPrincipalAfter == usdcRedeposit, "USDC YS principal mismatch: should be 85% of withdrawn");

        // Assert DOLA YS principal == dolaRedeposit
        require(dolaPrincipalAfter == dolaRedeposit, "DOLA YS principal mismatch: should be 85% of withdrawn");

        // Assert USDe YS principal increased
        require(usdePrincipalAfter > usdePrincipalBefore, "USDe YS principal did not increase");

        // --- TVL comparison ---
        // Normalize all to 18 decimals for comparison
        uint256 tvlBefore = uint256(usdcTotalBalBefore) * 1e12 + dolaTotalBalBefore + usdeTotalBalBefore;
        uint256 tvlAfter = uint256(usdcTotalBalAfter) * 1e12 + dolaTotalBalAfter + usdeTotalBalAfter;

        console.log("\n--- TVL Comparison (18-decimal normalized) ---");
        console.log("TVL before:                 ", tvlBefore);
        console.log("TVL after:                  ", tvlAfter);

        // 0.3% tolerance
        uint256 tolerance = tvlBefore * 3 / 1000;
        uint256 tvlDiff = tvlAfter > tvlBefore ? tvlAfter - tvlBefore : tvlBefore - tvlAfter;
        console.log("TVL difference:             ", tvlDiff);
        console.log("Tolerance (0.3%):           ", tolerance);
        require(tvlDiff <= tolerance, "TVL drift exceeds 0.3% tolerance");

        console.log("\n=== VERIFICATION PASSED ===");
        console.log("USDC YS re-deposited 85%. DOLA YS re-deposited 85%. USDe deposited into USDeYS.");
        console.log("");
    }
}
