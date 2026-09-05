// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import {CurveAMMAdapter} from "@vault/AMMAdapters/CurveAMMAdapter.sol";

interface IMinterPausable {
    function registerStablecoin(address stablecoin, address yieldStrategy, uint256 exchangeRate, uint8 decimals)
        external;
    function approveYS(address token, address yieldStrategy) external;
}

interface IAccumulator {
    function addYieldStrategy(address strategy, address token) external;
    function setTokenConfig(address token, uint8 decimals, uint256 normalizedExchangeRate) external;
    function getTotalYield() external view returns (uint256);
}

interface IPauser {
    function register(address pausableContract) external;
}

/**
 * @title DeployUSDeMarketYieldStrategy
 * @notice Deploys a new ERC4626MarketYieldStrategy for USDe -> sUSDe via the
 *         CurveAMMAdapter (USDe/crvUSD -> crvUSD/sUSDe), and wires it into the
 *         existing PhusdStableMinter, StableYieldAccumulator, and global Pauser.
 *
 *         This is a fresh deployment — USDe is not currently a registered
 *         stablecoin on the minter, and there is no existing USDe yield
 *         strategy to migrate from.
 *
 *         Ordered call sequence (all under a single vm.startBroadcast(OWNER)):
 *           1.  Deploy CurveAMMAdapter
 *           2.  Deploy ERC4626MarketYieldStrategy
 *           3.  adapter.setRoute(USDe -> sUSDe)        — forward route
 *           4.  adapter.setRoute(sUSDe -> USDe)        — reverse route
 *           5.  strategy.setSlippageTolerance(120)     — 120 bps = 1.2%
 *           6.  strategy.setClient(minter, true)       — minter is the deposit client
 *           7.  strategy.setWithdrawer(accumulator,true) — accumulator can pull yield
 *           8.  minter.registerStablecoin(USDe, strategy, 1e18, 18)
 *           9.  minter.approveYS(USDe, strategy)       — minter approves the strategy
 *           10. accumulator.setTokenConfig(USDe, 18, 1e18) — REQUIRED for new token
 *           11. accumulator.addYieldStrategy(strategy, USDe)
 *           12. setPauser(OWNER) -> pause() -> setPauser(GLOBAL_PAUSER) -> register(strategy)
 *
 *         The strategy ends up paused under the global pauser. An operator must
 *         run `pauser.unpause(<strategy>)` separately before users can mint phUSD
 *         with USDe — this is the same safety pattern used by every other strategy
 *         on mainnet.
 *
 *         Run via:
 *           npm run mainnet:deploy-usde-ys-dry  # dry-run, no broadcast
 *           npm run mainnet:deploy-usde-ys      # live broadcast via Ledger
 */
contract DeployUSDeMarketYieldStrategy is Script {
    // ── Token addresses ──
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant CRV_USD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;

    // ── Curve infrastructure ──
    address constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;
    // coin0=USDe, coin1=crvUSD
    address constant POOL_USDE_CRVUSD = 0xF55B0f6F2Da5ffDDb104b58a60F2862745960442;
    // coin0=crvUSD, coin1=sUSDe
    address constant POOL_CRVUSD_SUSDE = 0x57064F49Ad7123C92560882a45518374ad982e85;

    // ── Existing protocol contracts ──
    address constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant STABLE_YIELD_ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant GLOBAL_PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // ── Accounts ──
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ── Slippage ──
    // 120 bps = 1.2%; +20 bps over the validated test value for live-pool depth headroom
    uint256 constant SLIPPAGE_BPS = 120;

    function run() external {
        IMinterPausable minter = IMinterPausable(PHUSD_STABLE_MINTER);
        IAccumulator accumulator = IAccumulator(STABLE_YIELD_ACCUMULATOR);

        // ============================================================
        // PRE-FLIGHT LOGGING
        // ============================================================
        console.log("\n=== DeployUSDeMarketYieldStrategy Pre-flight ===");
        console.log("OWNER:                      ", OWNER);
        console.log("USDe:                       ", USDE);
        console.log("sUSDe:                      ", SUSDE);
        console.log("crvUSD:                     ", CRV_USD);
        console.log("Curve Router NG:            ", CURVE_ROUTER_NG);
        console.log("Pool USDe/crvUSD:           ", POOL_USDE_CRVUSD);
        console.log("Pool crvUSD/sUSDe:          ", POOL_CRVUSD_SUSDE);
        console.log("PhusdStableMinter:          ", PHUSD_STABLE_MINTER);
        console.log("StableYieldAccumulator:     ", STABLE_YIELD_ACCUMULATOR);
        console.log("Global Pauser:              ", GLOBAL_PAUSER);
        console.log("Slippage tolerance (bps):   ", SLIPPAGE_BPS);
        console.log("Note: 'uUSDe' in the user request is interpreted as USDe (0x4c9E...68B3).");

        uint256 totalYieldBefore = accumulator.getTotalYield();
        console.log("Accumulator getTotalYield (before):", totalYieldBefore);

        vm.startBroadcast(OWNER);

        // ============================================================
        // STEP 1: Deploy CurveAMMAdapter
        // ============================================================
        CurveAMMAdapter adapter = new CurveAMMAdapter(OWNER, CURVE_ROUTER_NG);
        console.log("\n[Step 1] Deployed CurveAMMAdapter at:", address(adapter));

        // ============================================================
        // STEP 2: Deploy ERC4626MarketYieldStrategy
        // ============================================================
        ERC4626MarketYieldStrategy strategy =
            new ERC4626MarketYieldStrategy(OWNER, USDE, SUSDE, address(adapter));
        console.log("[Step 2] Deployed ERC4626MarketYieldStrategy at:", address(strategy));

        // ============================================================
        // STEP 3: Configure adapter forward route (USDe -> sUSDe)
        // ============================================================
        // keep in sync with AMMRoutes.json
        // path[0] = USDe, path[1] = pool USDe/crvUSD, path[2] = crvUSD,
        // path[3] = pool crvUSD/sUSDe, path[4] = sUSDe
        // swapParams[0] = [0,1,1,10,2] — pool1: coin0(USDe) -> coin1(crvUSD), stableswap-ng exchange
        // swapParams[1] = [0,1,1,10,2] — pool2: coin0(crvUSD) -> coin1(sUSDe), stableswap-ng exchange
        address[11] memory fwdPath;
        fwdPath[0] = USDE;
        fwdPath[1] = POOL_USDE_CRVUSD;
        fwdPath[2] = CRV_USD;
        fwdPath[3] = POOL_CRVUSD_SUSDE;
        fwdPath[4] = SUSDE;

        uint256[5][5] memory fwdParams;
        fwdParams[0] = [uint256(0), 1, 1, 10, 2];
        fwdParams[1] = [uint256(0), 1, 1, 10, 2];

        address[5] memory emptyPools;

        adapter.setRoute(USDE, SUSDE, fwdPath, fwdParams, emptyPools);
        console.log("[Step 3] adapter.setRoute: USDe -> sUSDe configured");

        // ============================================================
        // STEP 4: Configure adapter reverse route (sUSDe -> USDe)
        // ============================================================
        // keep in sync with AMMRoutes.json
        // path[0] = sUSDe, path[1] = pool crvUSD/sUSDe, path[2] = crvUSD,
        // path[3] = pool USDe/crvUSD, path[4] = USDe
        // swapParams[0] = [1,0,1,10,2] — pool2: coin1(sUSDe) -> coin0(crvUSD)
        // swapParams[1] = [1,0,1,10,2] — pool1: coin1(crvUSD) -> coin0(USDe)
        address[11] memory revPath;
        revPath[0] = SUSDE;
        revPath[1] = POOL_CRVUSD_SUSDE;
        revPath[2] = CRV_USD;
        revPath[3] = POOL_USDE_CRVUSD;
        revPath[4] = USDE;

        uint256[5][5] memory revParams;
        revParams[0] = [uint256(1), 0, 1, 10, 2];
        revParams[1] = [uint256(1), 0, 1, 10, 2];

        adapter.setRoute(SUSDE, USDE, revPath, revParams, emptyPools);
        console.log("[Step 4] adapter.setRoute: sUSDe -> USDe configured");

        // ============================================================
        // STEP 5: Set strategy slippage tolerance
        // ============================================================
        // 120 bps = 1.2%; +20 bps over the validated test value for live-pool depth headroom
        strategy.setSlippageTolerance(SLIPPAGE_BPS);
        console.log("[Step 5] strategy.setSlippageTolerance: 120 bps");

        // ============================================================
        // STEP 6: Authorize minter as client on the strategy
        // ============================================================
        strategy.setClient(PHUSD_STABLE_MINTER, true);
        console.log("[Step 6] strategy.setClient: PhusdStableMinter authorized");

        // ============================================================
        // STEP 7: Authorize accumulator as withdrawer on the strategy
        // ============================================================
        strategy.setWithdrawer(STABLE_YIELD_ACCUMULATOR, true);
        console.log("[Step 7] strategy.setWithdrawer: StableYieldAccumulator authorized");

        // ============================================================
        // STEP 8: Register USDe -> strategy mapping on the minter
        // ============================================================
        minter.registerStablecoin(USDE, address(strategy), 1e18, 18);
        console.log("[Step 8] minter.registerStablecoin: USDe -> strategy (1e18 rate, 18 decimals)");

        // ============================================================
        // STEP 9: Minter approves the strategy to pull USDe
        // ============================================================
        minter.approveYS(USDE, address(strategy));
        console.log("[Step 9] minter.approveYS: strategy approved to pull USDe from minter");

        // ============================================================
        // STEP 10: Register USDe token config on the accumulator
        // ============================================================
        // REQUIRED for new tokens. addYieldStrategy only writes
        // strategyTokens[strategy] = token; it does NOT populate
        // tokenConfigs[token] (decimals + normalized exchange rate). Without
        // this call, the accumulator's claim path silently breaks normalization.
        accumulator.setTokenConfig(USDE, 18, 1e18);
        console.log("[Step 10] accumulator.setTokenConfig: USDe (18 decimals, 1e18 rate)");

        // ============================================================
        // STEP 11: Register strategy with accumulator for USDe
        // ============================================================
        accumulator.addYieldStrategy(address(strategy), USDE);
        console.log("[Step 11] accumulator.addYieldStrategy: strategy registered for USDe");

        // ============================================================
        // STEP 12: Pauser handoff (pause-then-handoff dance)
        // ============================================================
        // Mirrors PartialMigrationExecute.s.sol lines 202-207. The strategy
        // ends up paused under global-pauser control; admin can unpause via
        // the existing pauser tooling once verification is complete.
        strategy.setPauser(OWNER);
        strategy.pause();
        strategy.setPauser(GLOBAL_PAUSER);
        IPauser(GLOBAL_PAUSER).register(address(strategy));
        console.log("[Step 12] Pauser handoff complete: strategy paused under GLOBAL_PAUSER");

        vm.stopBroadcast();

        // ============================================================
        // POST-FLIGHT VERIFICATION
        // ============================================================
        uint256 totalYieldAfter = accumulator.getTotalYield();
        uint256 strategyPrincipal = strategy.principalOf(USDE, PHUSD_STABLE_MINTER);
        uint256 strategyTotalBalance = strategy.totalBalanceOf(USDE, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");
        console.log("Adapter address:                     ", address(adapter));
        console.log("Strategy address:                    ", address(strategy));
        console.log("accumulator.getTotalYield (after):   ", totalYieldAfter);
        console.log("strategy.principalOf(USDe, minter):  ", strategyPrincipal);
        console.log("strategy.totalBalanceOf(USDe,minter):", strategyTotalBalance);

        require(strategyPrincipal == 0, "Strategy principal should be 0 (no seed deposit)");
        require(strategyTotalBalance == 0, "Strategy totalBalance should be 0 (no seed deposit)");

        // ============================================================
        // DEPLOYMENT COMPLETE
        // ============================================================
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("CurveAMMAdapter:                     ", address(adapter));
        console.log("ERC4626MarketYieldStrategy (USDe):   ", address(strategy));
        console.log("Underlying token:                    ", USDE, "(USDe)");
        console.log("ERC4626 vault:                       ", SUSDE, "(sUSDe)");
        console.log("Slippage tolerance (bps):            ", SLIPPAGE_BPS);
        console.log("Minter (client):                     ", PHUSD_STABLE_MINTER);
        console.log("Accumulator (withdrawer):            ", STABLE_YIELD_ACCUMULATOR);
        console.log("Pauser:                              ", GLOBAL_PAUSER);
        console.log("");
        console.log("FOLLOW-UP: Update server/deployments/mainnet-addresses.ts with the deployed addresses.");
        console.log("");
        console.log("WARNING: Strategy is PAUSED. Run `pauser.unpause(", address(strategy), ")` before users can mint phUSD with USDe.");
        console.log("");
    }
}
