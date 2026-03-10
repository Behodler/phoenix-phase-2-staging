// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../../src/views/ViewRouter.sol";
import "../../src/views/MintPageView.sol";
import "@yield-claim-nft/interfaces/INFTMinter.sol";
import "@yield-claim-nft/BurnRecorder.sol";

/**
 * @title RegisterMintPageView
 * @notice Deploys MintPageView and registers it with the ViewRouter.
 * @dev Reads contract addresses from the progress JSON file.
 *
 *      Usage:
 *        source .envrc && forge script script/interactions/RegisterMintPageView.s.sol:RegisterMintPageView \
 *          --rpc-url http://localhost:8545 --broadcast
 */
contract RegisterMintPageView is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("    REGISTER MINT PAGE VIEW");
        console.log("========================================\n");
        console.log("Deployer:", deployer);

        // Load contract addresses from progress.json
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");

        address viewRouterAddr = vm.parseJsonAddress(progressJson, ".contracts.ViewRouter.address");
        address nftMinterAddr = vm.parseJsonAddress(progressJson, ".contracts.NFTMinter.address");
        address burnRecorderAddr = vm.parseJsonAddress(progressJson, ".contracts.BurnRecorder.address");

        // Token addresses
        address eyeAddr = vm.parseJsonAddress(progressJson, ".contracts.MockEYE.address");
        address scxAddr = vm.parseJsonAddress(progressJson, ".contracts.MockSCX.address");
        address flaxAddr = vm.parseJsonAddress(progressJson, ".contracts.MockFlax.address");
        address susdsAddr = vm.parseJsonAddress(progressJson, ".contracts.MockUSDS.address");
        address wbtcAddr = vm.parseJsonAddress(progressJson, ".contracts.MockWBTC.address");

        console.log("ViewRouter:", viewRouterAddr);
        console.log("NFTMinter:", nftMinterAddr);
        console.log("BurnRecorder:", burnRecorderAddr);
        console.log("EYE:", eyeAddr);
        console.log("SCX:", scxAddr);
        console.log("Flax:", flaxAddr);
        console.log("sUSDS:", susdsAddr);
        console.log("WBTC:", wbtcAddr);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MintPageView
        MintPageView mintPageView = new MintPageView(
            INFTMinter(nftMinterAddr),
            BurnRecorder(burnRecorderAddr),
            eyeAddr,
            scxAddr,
            flaxAddr,
            susdsAddr,
            wbtcAddr
        );

        console.log("\nMintPageView deployed at:", address(mintPageView));

        // Register with ViewRouter
        bytes32 pageKey = keccak256("mint");
        ViewRouter(viewRouterAddr).setPage(pageKey, IPageView(address(mintPageView)));

        console.log("Registered MintPageView with ViewRouter under key: mint");
        console.log("Page key (bytes32):", vm.toString(pageKey));

        vm.stopBroadcast();

        console.log("\n========================================");
        console.log("    REGISTRATION COMPLETE");
        console.log("========================================\n");
    }
}
