// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IDispatcherMinter {
    function setMinter(address minter_) external;
    function owner() external view returns (address);
}

/**
 * @title SetMinterOnIndex4Pooler
 * @notice Story-048 follow-up. Sets NFTMinterV2 as the authorized minter on
 *         the new BalancerPoolerV2 at dispatcher index 4. The cutover
 *         intentionally skipped this step (see DispatcherReplaceAtIndex4
 *         step 11 comment), but `ATokenDispatcherV2.dispatch` is gated by
 *         `onlyMinter` -- so mint(4, ...) reverts with
 *         "ATokenDispatcherV2: caller is not minter".
 *
 *         Dry run:
 *           PREVIEW_MODE=true forge script script/SetMinterOnIndex4Pooler.s.sol \
 *             --rpc-url $RPC_MAINNET -vvv
 *
 *         Broadcast (Ledger, index 46):
 *           forge script script/SetMinterOnIndex4Pooler.s.sol \
 *             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract SetMinterOnIndex4Pooler is Script {
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant NEW_POOLER    = 0x26F89f4B46eB164303985795ee20b15BB1Edb38A; // deployed by DispatcherReplaceAtIndex4
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        console.log("=========================================");
        console.log("  SET MINTER ON INDEX-4 POOLER");
        console.log("=========================================");
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        console.log("NFTMinterV2: ", NFT_MINTER_V2);
        console.log("New pooler:  ", NEW_POOLER);

        require(
            IDispatcherMinter(NEW_POOLER).owner() == OWNER_ADDRESS,
            "Unexpected pooler owner"
        );

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        IDispatcherMinter(NEW_POOLER).setMinter(NFT_MINTER_V2);
        console.log("BalancerPoolerV2.setMinter(NFT_MINTER_V2) -- sent");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("");
        console.log("=========================================");
        console.log("  DONE");
        console.log("=========================================");
    }
}
