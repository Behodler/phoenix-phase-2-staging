// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "./AddressLoader.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title RegisterStablecoin
 * @notice Script to register a new stablecoin with the minter
 * @dev Admin-only operation to configure new stablecoin support
 */
contract RegisterStablecoin is Script {
    using AddressLoader for *;

    function run() external {
        // Load addresses
        address minter = AddressLoader.getMinter();
        address yieldStrategy = AddressLoader.getYieldStrategy();
        uint256 deployerKey = AddressLoader.getDefaultPrivateKey();

        // Example: Register a new mock stablecoin
        // In practice, this would be a new ERC20 token address
        address newStablecoin = address(0x1234567890123456789012345678901234567890);
        uint256 exchangeRate = 1e18; // 1:1 ratio
        uint8 decimals = 6; // Like USDC

        console.log("\n=== Registering New Stablecoin ===");
        console.log("Stablecoin address:", newStablecoin);
        console.log("Yield strategy:", yieldStrategy);
        console.log("Exchange rate:", exchangeRate);
        console.log("Decimals:", uint256(decimals));

        vm.startBroadcast(deployerKey);

        // Register the stablecoin
        PhusdStableMinter(minter).registerStablecoin(
            newStablecoin,
            yieldStrategy,
            exchangeRate,
            decimals
        );

        console.log("Stablecoin registered successfully");

        vm.stopBroadcast();

        // Verify registration
        (address configYS, uint256 configRate, uint8 configDecimals, bool enabled) =
            PhusdStableMinter(minter).stablecoinConfigs(newStablecoin);

        console.log("\n--- Verification ---");
        console.log("Configured yield strategy:", configYS);
        console.log("Configured exchange rate:", configRate);
        console.log("Configured decimals:", uint256(configDecimals));
        console.log("Enabled:", enabled ? "YES" : "NO");

        console.log("=== Registration Complete ===\n");
    }
}
