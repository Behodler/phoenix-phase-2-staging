// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IYieldStrategyPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
    function paused() external view returns (bool);
}

/**
 * @title UnPauseYS_USDe
 * @notice Unpauses the USDe ERC4626MarketYieldStrategy so that minting phUSD
 *         with USDe can proceed on mainnet.
 *
 *         The strategy was deployed paused under the global Pauser
 *         (see DeployUSDeMarketYieldStrategy.s.sol step 12). Calling
 *         `Pauser.unpause()` directly would unpause every contract registered
 *         with the global pauser at once, which is undesirable. Instead, we
 *         use the same pattern as UnPauseYS_Dola.s.sol:
 *
 *         1. Temporarily reclaim the pauser role on the strategy (OWNER)
 *         2. Unpause the strategy
 *         3. Restore the original pauser (the global Pauser)
 *
 *         The strategy remains registered with the global Pauser, so an
 *         emergency `Pauser.pause()` will still cover it afterwards.
 *
 *         Run via:
 *           npm run mainnet:unpause-ys-usde-dry  # dry-run, no broadcast
 *           npm run mainnet:unpause-ys-usde      # live broadcast via Ledger
 */
contract UnPauseYS_USDe is Script {
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ERC4626MarketYieldStrategy for USDe -> sUSDe
    // Source: server/deployments/mainnet-addresses.ts (YieldStrategyUSDe)
    address constant USDE_YS = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;

    function run() external {
        IYieldStrategyPausable usdeYS = IYieldStrategyPausable(USDE_YS);

        // --- Pre-flight ---
        address originalPauser = usdeYS.pauser();
        bool wasPaused = usdeYS.paused();

        console.log("\n=== UnPauseYS_USDe Pre-flight ===");
        console.log("USDe YS:           ", USDE_YS);
        console.log("Original pauser:   ", originalPauser);
        console.log("Currently paused:  ", wasPaused ? "YES" : "NO");

        require(wasPaused, "USDe YS is already unpaused");

        vm.startBroadcast(OWNER);

        // Step 1: Reclaim pauser role on the strategy
        usdeYS.setPauser(OWNER);
        console.log("\n[Step 1] setPauser(OWNER) on USDe YS");

        // Step 2: Unpause the strategy
        usdeYS.unpause();
        console.log("[Step 2] Unpaused USDe YS");

        // Step 3: Restore the original pauser (global Pauser)
        usdeYS.setPauser(originalPauser);
        console.log("[Step 3] Restored original pauser");

        vm.stopBroadcast();

        // --- Post-flight verification ---
        bool nowPaused = usdeYS.paused();
        address finalPauser = usdeYS.pauser();

        console.log("\n=== Post-flight Verification ===");
        console.log("Now paused:        ", nowPaused ? "YES" : "NO");
        console.log("Final pauser:      ", finalPauser);

        require(!nowPaused, "USDe YS still paused after unpause");
        require(finalPauser == originalPauser, "Pauser was not restored");

        console.log("\n=== UnPauseYS_USDe Complete ===");
        console.log("USDe YieldStrategy is now unpaused. Minting phUSD with USDe is enabled.");
    }
}
