// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IBalancerPoolerV2Like {
    function owner() external view returns (address);
    function batchDonationSize() external view returns (uint256);
    function setBatchDonationSize(uint256) external;
}

/**
 * @title SetBatchDonationSizeIndex4
 * @notice Story-048 follow-up. Sets batchDonationSize = 10 (= 10%) on the
 *         new index-4 BalancerPoolerV2. The cutover step 7 mirrored the
 *         bugged index-6 pooler's value, which had been zeroed at some
 *         point -- so the donation phase never fires and the batchMinter
 *         never receives USDC.
 *
 *         Dry run:
 *           PREVIEW_MODE=true forge script script/SetBatchDonationSizeIndex4.s.sol \
 *             --rpc-url $RPC_MAINNET -vvv
 *
 *         Broadcast (Ledger, index 46):
 *           forge script script/SetBatchDonationSizeIndex4.s.sol \
 *             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract SetBatchDonationSizeIndex4 is Script {
    address public constant NEW_POOLER    = 0x26F89f4B46eB164303985795ee20b15BB1Edb38A;
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    uint256 public constant TARGET_SIZE   = 10; // percent

    function run() external {
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        console.log("===========================================");
        console.log("  SET batchDonationSize ON INDEX-4 POOLER");
        console.log("===========================================");
        console.log("Pooler:    ", NEW_POOLER);
        console.log("Target %:  ", TARGET_SIZE);

        require(
            IBalancerPoolerV2Like(NEW_POOLER).owner() == OWNER_ADDRESS,
            "Unexpected pooler owner"
        );

        uint256 pre = IBalancerPoolerV2Like(NEW_POOLER).batchDonationSize();
        console.log("Pre value: ", pre);
        require(pre != TARGET_SIZE, "batchDonationSize already at target -- nothing to do");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        IBalancerPoolerV2Like(NEW_POOLER).setBatchDonationSize(TARGET_SIZE);
        console.log("setBatchDonationSize(", TARGET_SIZE, ") -- sent");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        uint256 post = IBalancerPoolerV2Like(NEW_POOLER).batchDonationSize();
        require(post == TARGET_SIZE, "batchDonationSize did not update");
        console.log("Post value:", post);

        console.log("");
        console.log("===========================================");
        console.log("  DONE");
        console.log("===========================================");
    }
}
