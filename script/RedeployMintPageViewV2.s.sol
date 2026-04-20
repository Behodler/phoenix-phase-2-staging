// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
import {ViewRouter} from "../src/views/ViewRouter.sol";
import {IPageView} from "../src/views/IPageView.sol";
import {INFTMinter} from "@yield-claim-nft/interfaces/INFTMinter.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";

/**
 * @title RedeployMintPageViewV2
 * @notice Redeploys MintPageView pointing at the V2 NFTMinter and re-registers it on the
 *         existing ViewRouter under keccak256("mint").
 * @dev The previously deployed MintPageView is immutably wired to the V1 NFTMinter
 *      (0xd936...8811), so users who have migrated to V2 appear to have no NFTs on the
 *      mint page. Redeploying with the V2 NFTMinter restores the correct view.
 *
 *      IMPORTANT — USDS vs sUSDS for tokenId 4:
 *      V1's BalancerPooler used sUSDS as primeToken.
 *      V2's BalancerPoolerV2 uses USDS as primeToken (it wraps USDS -> sUSDS internally).
 *      This script passes USDS (0xdC035D45...) so MintPageView reports the user's USDS
 *      balance and allowance, which is what the V2 mint flow actually spends.
 *
 *      Modes:
 *        PREVIEW_MODE=true  -> startPrank(OWNER_ADDRESS), no broadcast
 *        PREVIEW_MODE=false -> startBroadcast()
 *
 *      Dry run:
 *        PREVIEW_MODE=true forge script script/RedeployMintPageViewV2.s.sol --rpc-url $RPC_MAINNET
 *
 *      Broadcast (Ledger, index 46):
 *        forge script script/RedeployMintPageViewV2.s.sol \
 *          --rpc-url $RPC_MAINNET --broadcast --ledger --hd-paths "m/44'/60'/46'/0/0"
 */
contract RedeployMintPageViewV2 is Script {
    // ==========================================
    //    EXISTING MAINNET ADDRESSES
    // ==========================================

    // NFT V2 NFTMinter (from server/deployments/mainnet-addresses.ts: nftsV2.NFTMinter)
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;

    // Common NFT infrastructure (shared V1/V2)
    address public constant BURN_RECORDER = 0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F;
    address public constant VIEW_ROUTER   = 0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a;

    // Current MintPageView on ViewRouter (V1-wired — being replaced)
    address public constant OLD_MINT_PAGE_VIEW = 0x5122cb32aE42AcC2aD5C2071e977C95c08F70141;

    // Tokens consumed by the V2 mint flow (must match each V2 dispatcher's primeToken())
    address public constant EYE  = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX  = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLAX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // V2 uses USDS (not sUSDS)
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Ledger signer (index 46)
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        console.log("=========================================");
        console.log("  REDEPLOY MINT PAGE VIEW (V2 NFTMINTER)");
        console.log("=========================================");
        console.log("Chain ID:", block.chainid);
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        console.log("");
        console.log("--- Wiring ---");
        console.log("NFTMinter (V2):    ", NFT_MINTER_V2);
        console.log("BurnRecorder:      ", BURN_RECORDER);
        console.log("ViewRouter:        ", VIEW_ROUTER);
        console.log("Old MintPageView:  ", OLD_MINT_PAGE_VIEW);
        console.log("EYE:               ", EYE);
        console.log("SCX:               ", SCX);
        console.log("FLAX:              ", FLAX);
        console.log("USDS (V2 prime):   ", USDS);
        console.log("WBTC:              ", WBTC);
        console.log("");

        // Pre-flight sanity checks
        address routerOwner = ViewRouter(VIEW_ROUTER).owner();
        console.log("ViewRouter owner:  ", routerOwner);
        require(routerOwner == OWNER_ADDRESS, "Unexpected ViewRouter owner");

        bytes32 pageKey = keccak256("mint");
        address currentMintPage = address(ViewRouter(VIEW_ROUTER).pages(pageKey));
        console.log("Current 'mint' page:", currentMintPage);
        require(currentMintPage == OLD_MINT_PAGE_VIEW, "Unexpected current mint page");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // Deploy new MintPageView wired to V2 NFTMinter
        MintPageView mpv = new MintPageView(
            INFTMinter(NFT_MINTER_V2),
            BurnRecorder(BURN_RECORDER),
            EYE,
            SCX,
            FLAX,
            USDS,
            WBTC
        );
        console.log("New MintPageView deployed at:", address(mpv));

        // Register under keccak256("mint"), replacing the old V1-wired view
        ViewRouter(VIEW_ROUTER).setPage(pageKey, IPageView(address(mpv)));
        console.log("Registered new MintPageView on ViewRouter under key 'mint'");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // Verify wiring
        require(address(mpv.nftMinter()) == NFT_MINTER_V2, "MintPageView.nftMinter != V2");
        require(address(mpv.burnRecorder()) == BURN_RECORDER, "MintPageView.burnRecorder mismatch");

        address nowRegistered = address(ViewRouter(VIEW_ROUTER).pages(pageKey));
        require(nowRegistered == address(mpv), "ViewRouter 'mint' not updated");

        // Smoke test: getData must not revert
        console.log("");
        console.log("=== Sanity: MintPageView.getData(OWNER_ADDRESS) ===");
        mpv.getData(OWNER_ADDRESS);
        console.log("getData() succeeded (no revert)");

        console.log("");
        console.log("=========================================");
        console.log("  REDEPLOY COMPLETE");
        console.log("=========================================");
        console.log("New MintPageView: ", address(mpv));
        console.log("Update server/deployments/mainnet-addresses.ts MintPageView field.");
    }
}
