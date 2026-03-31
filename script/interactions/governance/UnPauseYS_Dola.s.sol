// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IYieldStrategyPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
}

/**
 * @title UnPauseYS_Dola
 * @notice Unpauses both DOLA YieldStrategy contracts (AutoPool and ERC4626).
 *
 *         Steps:
 *         1. Temporarily set pauser to OWNER on both YS contracts
 *         2. Unpause both
 *         3. Restore original pausers
 */
contract UnPauseYS_Dola is Script {
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    address constant AUTO_POOL_YS = 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4;
    address constant ERC4626_YS   = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;

    function run() external {
        IYieldStrategyPausable autoPoolYS = IYieldStrategyPausable(AUTO_POOL_YS);
        IYieldStrategyPausable erc4626YS  = IYieldStrategyPausable(ERC4626_YS);

        // --- Pre-flight ---
        address autoPoolPauser = autoPoolYS.pauser();
        address erc4626Pauser  = erc4626YS.pauser();

        console.log("\n=== UnPauseYS_Dola Pre-flight ===");
        console.log("AutoPool YS:       ", AUTO_POOL_YS);
        console.log("AutoPool pauser:   ", autoPoolPauser);
        console.log("ERC4626 YS:        ", ERC4626_YS);
        console.log("ERC4626 pauser:    ", erc4626Pauser);

        vm.startBroadcast(OWNER);

        // Step 1: Take pauser ownership on both
        autoPoolYS.setPauser(OWNER);
        erc4626YS.setPauser(OWNER);
        console.log("\n[Step 1] setPauser(OWNER) on both YS contracts");

        // Step 2: Unpause both
        autoPoolYS.unpause();
        erc4626YS.unpause();
        console.log("[Step 2] Unpaused both YS contracts");

        // Step 3: Restore original pausers
        autoPoolYS.setPauser(autoPoolPauser);
        erc4626YS.setPauser(erc4626Pauser);
        console.log("[Step 3] Restored original pausers");

        vm.stopBroadcast();

        console.log("\n=== UnPauseYS_Dola Complete ===");
        console.log("Both DOLA YieldStrategy contracts are now unpaused.");
    }
}
