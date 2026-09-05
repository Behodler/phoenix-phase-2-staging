// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IPhusdStableMinter {
    function mint(address stablecoin, uint256 amount) external;
}

interface IERC4626MarketYieldStrategy {
    function principalOf(address token, address account) external view returns (uint256);
    function paused() external view returns (bool);
    function pauser() external view returns (address);
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
}

/**
 * @title MintPhUSDWithUSDeMainnet
 * @notice Test-mints 10 phUSD by depositing 10 USDe through the freshly deployed
 *         ERC4626MarketYieldStrategy (USDe -> sUSDe via CurveAMMAdapter).
 *
 *         The strategy is currently paused under the GLOBAL_PAUSER. To exercise
 *         the mint without permanently changing the protocol's pause state, the
 *         script unpauses, mints, and then repauses — restoring the strategy's
 *         GLOBAL_PAUSER assignment so the global pauser still controls it.
 *
 *         Pre-flight assertions:
 *           - chain id is mainnet (1)
 *           - YieldStrategyUSDe.principalOf(USDe, minter) == 0
 *           - owner holds at least 10 USDe
 *
 *         Steps (single broadcast as OWNER / Ledger index 46):
 *           1. strategy.unpause()                       — owner is allowed
 *           2. usde.approve(minter, 10e18)
 *           3. minter.mint(USDe, 10e18)
 *           4. strategy.setPauser(OWNER)                — temp handoff
 *           5. strategy.pause()                          — owner is now pauser
 *           6. strategy.setPauser(GLOBAL_PAUSER)         — restore handoff
 *
 *         Post-flight assertions:
 *           - owner USDe decreased by exactly 10e18
 *           - strategy sUSDe share balance increased; the asset-equivalent of the
 *             received shares is within slippage of 10e18 USDe
 *           - owner phUSD increased by exactly 10e18
 *           - strategy is paused again
 *           - strategy.pauser() == GLOBAL_PAUSER
 *
 *         Run via:
 *           npm run mainnet:mint-phusd-usde-dry  # dry-run, no broadcast
 *           npm run mainnet:mint-phusd-usde      # live broadcast via Ledger
 */
contract MintPhUSDWithUSDeMainnet is Script {
    // ── Token addresses ──
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;

    // ── Existing protocol contracts ──
    address constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant YIELD_STRATEGY_USDE = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;
    address constant GLOBAL_PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    // ── Owner / Ledger index 46 ──
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ── Test amount ──
    uint256 constant USDE_AMOUNT = 10e18;
    uint256 constant EXPECTED_PHUSD = 10e18;

    // ── Slippage tolerance for asset-equivalent assertion ──
    // Strategy is configured with 120 bps; we use 150 bps for the assertion to
    // give a small headroom on top of the strategy-level cap.
    uint256 constant ASSERT_SLIPPAGE_BPS = 150;
    uint256 constant MAX_BPS = 10_000;

    function run() external {
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        IERC20 usde = IERC20(USDE);
        IERC20 phUSD = IERC20(PHUSD);
        IERC20 sUSDe = IERC20(SUSDE);
        IERC4626 sUSDeVault = IERC4626(SUSDE);
        IPhusdStableMinter minter = IPhusdStableMinter(PHUSD_STABLE_MINTER);
        IERC4626MarketYieldStrategy strategy = IERC4626MarketYieldStrategy(YIELD_STRATEGY_USDE);

        // ============================================================
        // PRE-FLIGHT
        // ============================================================
        console.log("\n=== MintPhUSDWithUSDeMainnet Pre-flight ===");
        console.log("OWNER:                ", OWNER);
        console.log("USDe:                 ", USDE);
        console.log("sUSDe:                ", SUSDE);
        console.log("phUSD:                ", PHUSD);
        console.log("PhusdStableMinter:    ", PHUSD_STABLE_MINTER);
        console.log("YieldStrategyUSDe:    ", YIELD_STRATEGY_USDE);
        console.log("Mint amount (USDe):   ", USDE_AMOUNT);

        bool isPausedBefore = strategy.paused();
        address pauserBefore = strategy.pauser();
        console.log("Strategy paused (before):", isPausedBefore);
        console.log("Strategy pauser (before):", pauserBefore);
        require(
            pauserBefore == GLOBAL_PAUSER,
            "Strategy pauser is not GLOBAL_PAUSER - aborting to avoid corrupting pauser state"
        );

        uint256 strategyMinterPrincipalBefore = strategy.principalOf(USDE, PHUSD_STABLE_MINTER);
        console.log("strategy.principalOf(USDe, minter) (before):", strategyMinterPrincipalBefore);
        require(
            strategyMinterPrincipalBefore == 0,
            "Strategy minter principal must be zero before first mint"
        );

        uint256 ownerUsdeBefore = usde.balanceOf(OWNER);
        uint256 ownerPhUSDBefore = phUSD.balanceOf(OWNER);
        uint256 strategySUsdeBefore = sUSDe.balanceOf(YIELD_STRATEGY_USDE);

        console.log("owner USDe balance (before):  ", ownerUsdeBefore);
        console.log("owner phUSD balance (before): ", ownerPhUSDBefore);
        console.log("strategy sUSDe balance (before):", strategySUsdeBefore);

        require(ownerUsdeBefore >= USDE_AMOUNT, "Owner does not hold enough USDe");

        // ============================================================
        // BROADCAST
        // ============================================================
        vm.startBroadcast(OWNER);

        // Step 1: unpause the strategy (owner is allowed by AYieldStrategy.unpause())
        if (isPausedBefore) {
            strategy.unpause();
            console.log("\n[Step 1] strategy.unpause()");
        } else {
            console.log("\n[Step 1] strategy already unpaused - skipping");
        }

        // Step 2: approve minter to pull 10 USDe
        usde.approve(PHUSD_STABLE_MINTER, USDE_AMOUNT);
        console.log("[Step 2] usde.approve(minter, 10e18)");

        // Step 3: mint phUSD via the stable minter
        minter.mint(USDE, USDE_AMOUNT);
        console.log("[Step 3] minter.mint(USDe, 10e18)");

        // Step 4-6: repause via the same handoff dance the deploy script used.
        // The strategy must end up under GLOBAL_PAUSER control again. Owner
        // temporarily becomes the pauser to satisfy onlyPauser on pause(),
        // then hands control back. The strategy stays registered with the
        // global pauser throughout (registration is independent of `_pauser`).
        if (isPausedBefore) {
            strategy.setPauser(OWNER);
            console.log("[Step 4] strategy.setPauser(OWNER)");
            strategy.pause();
            console.log("[Step 5] strategy.pause()");
            strategy.setPauser(GLOBAL_PAUSER);
            console.log("[Step 6] strategy.setPauser(GLOBAL_PAUSER)");
        } else {
            console.log("[Step 4-6] strategy was not paused before - leaving unpaused");
        }

        vm.stopBroadcast();

        // ============================================================
        // POST-FLIGHT VERIFICATION
        // ============================================================
        uint256 ownerUsdeAfter = usde.balanceOf(OWNER);
        uint256 ownerPhUSDAfter = phUSD.balanceOf(OWNER);
        uint256 strategySUsdeAfter = sUSDe.balanceOf(YIELD_STRATEGY_USDE);
        uint256 strategyMinterPrincipalAfter = strategy.principalOf(USDE, PHUSD_STABLE_MINTER);

        console.log("\n=== Post-flight Verification ===");
        console.log("owner USDe balance (after):   ", ownerUsdeAfter);
        console.log("owner phUSD balance (after):  ", ownerPhUSDAfter);
        console.log("strategy sUSDe balance (after):", strategySUsdeAfter);
        console.log("strategy.principalOf(USDe, minter) (after):", strategyMinterPrincipalAfter);

        // 1. owner USDe decreased by exactly 10e18
        require(
            ownerUsdeBefore - ownerUsdeAfter == USDE_AMOUNT,
            "Owner USDe balance did not decrease by exactly 10 USDe"
        );
        console.log("[OK] Owner USDe decreased by exactly 10 USDe");

        // 2. strategy sUSDe shares increased, and the asset-equivalent of the
        //    new shares is within slippage of 10 USDe
        require(
            strategySUsdeAfter > strategySUsdeBefore,
            "Strategy sUSDe balance did not increase"
        );
        uint256 sUSDeSharesGained = strategySUsdeAfter - strategySUsdeBefore;
        uint256 assetEquivalent = sUSDeVault.convertToAssets(sUSDeSharesGained);
        uint256 tolerance = (USDE_AMOUNT * ASSERT_SLIPPAGE_BPS) / MAX_BPS;

        console.log("sUSDe shares gained:                  ", sUSDeSharesGained);
        console.log("asset-equivalent (USDe) of new shares:", assetEquivalent);
        console.log("tolerance (USDe):                     ", tolerance);

        uint256 diff = assetEquivalent > USDE_AMOUNT
            ? assetEquivalent - USDE_AMOUNT
            : USDE_AMOUNT - assetEquivalent;
        require(
            diff <= tolerance,
            "sUSDe asset-equivalent not within slippage tolerance of 10 USDe"
        );
        console.log("[OK] sUSDe shares correspond to ~10 USDe (within 150 bps)");

        // 3. owner phUSD increased by exactly 10e18
        require(
            ownerPhUSDAfter - ownerPhUSDBefore == EXPECTED_PHUSD,
            "Owner phUSD balance did not increase by exactly 10 phUSD"
        );
        console.log("[OK] Owner phUSD increased by exactly 10 phUSD");

        // 4. principal accounting on the strategy reflects the deposit
        require(
            strategyMinterPrincipalAfter == USDE_AMOUNT,
            "Strategy minter principal should equal 10 USDe after first mint"
        );
        console.log("[OK] strategy.principalOf(USDe, minter) == 10 USDe");

        // 5. pause state restored
        bool isPausedAfter = strategy.paused();
        address pauserAfter = strategy.pauser();
        console.log("strategy paused (after):", isPausedAfter);
        console.log("strategy pauser (after):", pauserAfter);
        require(
            isPausedAfter == isPausedBefore,
            "Strategy pause state was not restored"
        );
        require(
            pauserAfter == GLOBAL_PAUSER,
            "Strategy pauser was not restored to GLOBAL_PAUSER"
        );
        console.log("[OK] Pause state and pauser restored to GLOBAL_PAUSER");

        console.log("\n=== MINT TEST COMPLETE ===");
    }
}
