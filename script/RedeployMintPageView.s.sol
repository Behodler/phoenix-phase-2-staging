// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/views/ViewRouter.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
import "@yield-claim-nft/interfaces/INFTMinter.sol";
import "@yield-claim-nft/BurnRecorder.sol";

/**
 * @title RedeployMintPageView
 * @notice Redeploys MintPageView (with updated sUSDS dispatcher index 4 -> 6)
 *         and registers it with the existing ViewRouter.
 *
 * LEDGER SIGNER:
 * - Index: 46
 * - Owner Address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 *
 * Preview:
 *   PREVIEW_MODE=true forge script script/RedeployMintPageView.s.sol:RedeployMintPageView --rpc-url $RPC_MAINNET -vvv
 *
 * Broadcast:
 *   forge script script/RedeployMintPageView.s.sol:RedeployMintPageView --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract RedeployMintPageView is Script {
    // Existing deployed contracts
    address public constant VIEW_ROUTER = 0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a;
    address public constant NFT_MINTER = 0xd936461f1C15eA9f34Ca1F20ecD54A0819068811;
    address public constant BURN_RECORDER = 0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F;

    // Token addresses
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLAX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Signer
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        console.log("=========================================");
        console.log("  Redeploy MintPageView (sUSDS idx 4->6)");
        console.log("=========================================");
        console.log("");
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 1, "Wrong chain - expected Mainnet (1)");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);

        if (isPreview) {
            console.log("*** PREVIEW MODE ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // Step 1: Deploy new MintPageView
        console.log("");
        console.log("=== Step 1: Deploy new MintPageView ===");
        MintPageView newMintPageView = new MintPageView(
            INFTMinter(NFT_MINTER),
            BurnRecorder(BURN_RECORDER),
            EYE,
            SCX,
            FLAX,
            SUSDS,
            WBTC
        );
        console.log("New MintPageView deployed at:", address(newMintPageView));

        // Step 2: Register with ViewRouter (replaces old MintPageView)
        console.log("");
        console.log("=== Step 2: Update ViewRouter ===");
        bytes32 pageKey = keccak256("mint");
        ViewRouter(VIEW_ROUTER).setPage(pageKey, IPageView(address(newMintPageView)));
        console.log("ViewRouter.setPage('mint') updated");

        // Step 3: Sanity check
        console.log("");
        console.log("=== Step 3: Sanity check ===");
        MintPageView(address(newMintPageView)).getData(OWNER_ADDRESS);
        console.log("getData() succeeded (no revert)");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("");
        console.log("=========================================");
        console.log("  SUMMARY");
        console.log("=========================================");
        console.log("New MintPageView:", address(newMintPageView));
        console.log("ViewRouter updated: keccak256('mint')");
        console.log("");
        console.log("ACTION REQUIRED: Update mainnet-addresses.ts:");
        console.log("  MintPageView:", address(newMintPageView));
    }
}
