// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IFlax} from "@flax-token/IFlax.sol";

/**
 * @title MintPhUSDMainnet
 * @notice Mints phUSD (FlaxToken) on mainnet via owner's authorized minter role
 *
 * Usage (dry run):
 *   npm run mainnet:mint-phusd-dry
 *
 * Usage (broadcast with Ledger index 46):
 *   yarn mint-phusd
 */
contract MintPhUSDMainnet is Script {
    // Mainnet phUSD (FlaxToken)
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;

    // Owner / Ledger index 46
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run(uint256 ethUnits) external {
        uint256 amount = ethUnits * 1e18;
        address recipient = vm.envAddress("MINT_RECIPIENT");

        console.log("=========================================");
        console.log("  MINT phUSD (MAINNET)");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        IFlax phUSD = IFlax(PHUSD);

        // Check current state
        uint256 balanceBefore = phUSD.balanceOf(recipient);
        uint256 totalSupplyBefore = phUSD.totalSupply();

        console.log("phUSD token:", PHUSD);
        console.log("Recipient:", recipient);
        console.log("");
        console.log("--- Mint Parameters ---");
        console.log("ETH units requested:", ethUnits);
        console.log("Amount (wei):", amount);
        console.log("");
        console.log("--- Current State ---");
        console.log("Recipient balance:", balanceBefore / 1e18, "phUSD");
        console.log("Total supply:", totalSupplyBefore / 1e18, "phUSD");
        console.log("");
        console.log("--- Expected After ---");
        console.log("Recipient balance:", (balanceBefore + amount) / 1e18, "phUSD");
        console.log("Total supply:", (totalSupplyBefore + amount) / 1e18, "phUSD");

        // Check minter authorization
        IFlax.MinterInfo memory minterInfo = phUSD.authorizedMinters(OWNER_ADDRESS);
        console.log("");
        console.log("--- Minter Status ---");
        console.log("Is authorized minter:", minterInfo.canMint);

        vm.startBroadcast();

        // If owner is not yet an authorized minter, authorize first
        if (!minterInfo.canMint) {
            console.log("Owner not yet authorized as minter - calling setMinter...");
            phUSD.setMinter(OWNER_ADDRESS, true);
            console.log("Owner authorized as minter");
        }

        // Mint phUSD to recipient
        phUSD.mint(recipient, amount);
        console.log("");
        console.log("Minted", ethUnits, "phUSD successfully");

        vm.stopBroadcast();

        // Verify
        uint256 balanceAfter = phUSD.balanceOf(recipient);
        uint256 totalSupplyAfter = phUSD.totalSupply();

        console.log("");
        console.log("--- Actual After ---");
        console.log("Recipient balance:", balanceAfter / 1e18, "phUSD");
        console.log("Total supply:", totalSupplyAfter / 1e18, "phUSD");

        console.log("");
        console.log("=========================================");
        console.log("  MINT COMPLETE");
        console.log("=========================================");
    }
}
