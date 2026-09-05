// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {ViewRouter} from "../src/views/ViewRouter.sol";
import {IPageView} from "../src/views/IPageView.sol";

interface INFTMinterV2Disable {
    function setDispatcherDisabled(uint256 index, bool disabled) external;
    function configs(uint256 index) external view returns (address, uint256, uint256, bool);
}

/**
 * @title RestoreMintAtIndex4
 * @notice Story-048 follow-up. Two owner-signed txs in one broadcast:
 *
 *           1) NFTMinterV2.setDispatcherDisabled(4, false)
 *              -- story-047 set configs[4].disabled = true to push minting
 *              onto the bugged index-6 pooler. The story-048 cutover
 *              replaceDispatcher(4, newPooler) does NOT touch the disabled
 *              flag, so mint(4, ...) still reverts with
 *              "NFTMinterV2: dispatcher is disabled".
 *
 *           2) ViewRouter.setPage(keccak256("mint"), 0x64FE63ca...)
 *              -- re-points the "mint" page at the older MintPageView that
 *              hardcodes USDS at dispatcher index 4. Currently registered:
 *              0xebec50cd... (hardcodes index 6, now disabled).
 *
 *         Dry run:
 *           PREVIEW_MODE=true forge script script/RestoreMintAtIndex4.s.sol \
 *             --rpc-url $RPC_MAINNET -vvv
 *
 *         Broadcast (Ledger, index 46):
 *           forge script script/RestoreMintAtIndex4.s.sol \
 *             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract RestoreMintAtIndex4 is Script {
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant VIEW_ROUTER   = 0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a;
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // The MintPageView that hardcodes USDS at dispatcher index 4 (live on-chain).
    address public constant TARGET_MINT_PAGE_VIEW = 0x64FE63ca7BA456a9Bb190140e35DF2e437AbD119;

    // The MintPageView currently registered on ViewRouter (hardcodes index 6).
    address public constant CURRENT_MINT_PAGE_VIEW = 0xeBEc50cD19310e6ed59D8153313Ec7C888152c1A;

    function run() external {
        console.log("=========================================");
        console.log("  RESTORE MINT AT INDEX 4");
        console.log("=========================================");
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        console.log("NFTMinterV2:          ", NFT_MINTER_V2);
        console.log("ViewRouter:           ", VIEW_ROUTER);
        console.log("Target MintPageView:  ", TARGET_MINT_PAGE_VIEW);
        console.log("Current MintPageView: ", CURRENT_MINT_PAGE_VIEW);

        // ====== Pre-flight (no broadcast) ======
        require(ViewRouter(VIEW_ROUTER).owner() == OWNER_ADDRESS, "Unexpected ViewRouter owner");

        bytes32 pageKey = keccak256("mint");
        address currentlyRegistered = address(ViewRouter(VIEW_ROUTER).pages(pageKey));
        console.log("Currently registered 'mint' page:", currentlyRegistered);
        require(
            currentlyRegistered == CURRENT_MINT_PAGE_VIEW,
            "Unexpected current mint page (state has drifted; review before running)"
        );

        uint256 targetSize;
        address t = TARGET_MINT_PAGE_VIEW;
        assembly { targetSize := extcodesize(t) }
        require(targetSize > 0, "Target MintPageView has no code");

        (address d4,,, bool disabled4Pre) = INFTMinterV2Disable(NFT_MINTER_V2).configs(4);
        console.log("configs(4).dispatcher (pre):", d4);
        console.log("configs(4).disabled   (pre):", disabled4Pre);
        require(d4 != address(0), "configs(4) not registered");
        require(disabled4Pre, "configs(4).disabled already false -- nothing to enable");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // 1) Re-enable dispatcher index 4
        INFTMinterV2Disable(NFT_MINTER_V2).setDispatcherDisabled(4, false);
        console.log("NFTMinterV2.setDispatcherDisabled(4, false) -- sent");

        // 2) Re-point ViewRouter 'mint' page at the index-4 MintPageView
        ViewRouter(VIEW_ROUTER).setPage(pageKey, IPageView(TARGET_MINT_PAGE_VIEW));
        console.log("ViewRouter.setPage('mint', TARGET) -- sent");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ====== Post-state asserts ======
        (,,, bool disabled4Post) = INFTMinterV2Disable(NFT_MINTER_V2).configs(4);
        require(!disabled4Post, "configs(4).disabled still true after setDispatcherDisabled");
        console.log("configs(4).disabled (post):", disabled4Post);

        address nowRegistered = address(ViewRouter(VIEW_ROUTER).pages(pageKey));
        require(nowRegistered == TARGET_MINT_PAGE_VIEW, "ViewRouter 'mint' not updated");
        console.log("ViewRouter 'mint' now registered to:", nowRegistered);

        // Smoke test: getData must not revert.
        IPageView(TARGET_MINT_PAGE_VIEW).getData(OWNER_ADDRESS);
        console.log("MintPageView.getData(owner) OK");

        console.log("");
        console.log("=========================================");
        console.log("  RESTORE COMPLETE");
        console.log("=========================================");
    }
}
