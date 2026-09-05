// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {BalancerPooler} from "@yield-claim-nft/dispatchers/BalancerPooler.sol";
import {NFTMinter} from "@yield-claim-nft/NFTMinter.sol";

/**
 * @title FixBalancerPoolerMainnet
 * @notice Redeploys BalancerPooler with the vault unlock callback fix and updates WBTC price.
 * @dev Steps:
 *      1. Deploy new BalancerPooler (assumes lib/yield-claim-nft has the fix)
 *      2. Set NFTMinter as minter on the new BalancerPooler
 *      3. Disable old BalancerPooler dispatcher (index 4)
 *      4. Register new BalancerPooler dispatcher on NFTMinter
 *      5. Fix WBTC GatherWBTC price (index 5): 712 -> 7120 ($0.50 -> $5)
 *
 * LEDGER SIGNER:
 * - Index: 46
 * - Owner Address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 *
 * Preview:
 *   PREVIEW_MODE=true forge script script/FixBalancerPoolerMainnet.s.sol:FixBalancerPoolerMainnet --rpc-url $RPC_MAINNET -vvv
 *
 * Broadcast:
 *   forge script script/FixBalancerPoolerMainnet.s.sol:FixBalancerPoolerMainnet --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract FixBalancerPoolerMainnet is Script {
    // Existing deployed contracts
    address public constant NFT_MINTER = 0xd936461f1C15eA9f34Ca1F20ecD54A0819068811;
    address public constant OLD_BALANCER_POOLER = 0xbA695B524e669e1c419CDE3A3e569fdE87a29193;
    uint256 public constant OLD_DISPATCHER_INDEX = 4;
    uint256 public constant WBTC_DISPATCHER_INDEX = 5;

    // Constructor args for BalancerPooler
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant BALANCER_POOL = 0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58;
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    bool public constant PRIME_TOKEN_IS_FIRST = true; // sUSDS is token[0] in pool

    // Signer
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Dispatcher config (same growth rate as original; price carried from current on-chain value)
    uint256 public constant GROWTH_BALANCER_POOLER = 500; // 5%

    // WBTC price fix: 712 -> 7120 (8 decimals, $0.50 -> $5)
    uint256 public constant CORRECTED_WBTC_PRICE = 7120;

    function run() external {
        console.log("=========================================");
        console.log("  FIX: BalancerPooler + WBTC Price");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 1, "Wrong chain - expected Mainnet (1)");

        NFTMinter minter = NFTMinter(NFT_MINTER);

        // Read current price from old dispatcher before disabling
        (, uint256 currentPrice, uint256 currentGrowthBP,) = minter.configs(OLD_DISPATCHER_INDEX);
        console.log("Old BalancerPooler (index 4):");
        console.log("  address:", OLD_BALANCER_POOLER);
        console.log("  current price:", currentPrice);
        console.log("  growth BP:", currentGrowthBP);

        // Read current WBTC price
        (, uint256 currentWbtcPrice,,) = minter.configs(WBTC_DISPATCHER_INDEX);
        console.log("");
        console.log("WBTC GatherWBTC (index 5):");
        console.log("  current price:", currentWbtcPrice);
        console.log("  corrected price:", CORRECTED_WBTC_PRICE);

        bool isPreview = vm.envOr("PREVIEW_MODE", false);

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // Step 1: Deploy new BalancerPooler
        console.log("");
        console.log("=== Step 1: Deploy new BalancerPooler ===");
        BalancerPooler newPooler = new BalancerPooler(
            SUSDS,
            BALANCER_POOL,
            BALANCER_VAULT,
            PRIME_TOKEN_IS_FIRST,
            OWNER_ADDRESS
        );
        console.log("New BalancerPooler deployed at:", address(newPooler));

        // Step 2: Set NFTMinter as minter on new BalancerPooler
        console.log("");
        console.log("=== Step 2: Set minter on new BalancerPooler ===");
        newPooler.setMinter(NFT_MINTER);
        console.log("setMinter -> NFTMinter");

        // Step 3: Disable old BalancerPooler dispatcher
        console.log("");
        console.log("=== Step 3: Disable old BalancerPooler (index 4) ===");
        minter.setDispatcherDisabled(OLD_DISPATCHER_INDEX, true);
        console.log("Old dispatcher disabled");

        // Step 4: Register new BalancerPooler on NFTMinter
        console.log("");
        console.log("=== Step 4: Register new BalancerPooler ===");
        minter.registerDispatcher(address(newPooler), currentPrice, GROWTH_BALANCER_POOLER);
        uint256 newIndex = minter.nextIndex() - 1;
        console.log("New dispatcher registered at index:", newIndex);
        console.log("  price:", currentPrice);
        console.log("  growth BP:", GROWTH_BALANCER_POOLER);

        // Step 5: Fix WBTC price
        console.log("");
        console.log("=== Step 5: Fix WBTC GatherWBTC price (index 5) ===");
        minter.setPrice(WBTC_DISPATCHER_INDEX, CORRECTED_WBTC_PRICE);
        console.log("WBTC price updated:", currentWbtcPrice, "->", CORRECTED_WBTC_PRICE);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // Summary
        console.log("");
        console.log("=========================================");
        console.log("  DEPLOYMENT SUMMARY");
        console.log("=========================================");
        console.log("New BalancerPooler:     ", address(newPooler));
        console.log("New dispatcher index:   ", newIndex);
        console.log("Old dispatcher (idx 4): DISABLED");
        console.log("WBTC price (idx 5):     ", currentWbtcPrice, "->", CORRECTED_WBTC_PRICE);
        console.log("");
        console.log("ACTION REQUIRED: Update mainnet-addresses.ts:");
        console.log("  BalancerPooler:", address(newPooler));
    }
}
