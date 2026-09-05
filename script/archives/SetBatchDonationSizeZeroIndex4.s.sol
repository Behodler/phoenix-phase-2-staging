// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IBalancerPoolerV2Like {
    function owner() external view returns (address);
    function batchDonationSize() external view returns (uint256);
    function setBatchDonationSize(uint256) external;
}

/**
 * @title SetBatchDonationSizeZeroIndex4
 * @notice Reversible bleed-stop for the BatchNFTMinter self-refund bug
 *         (see docs/BatchNFTMint/self-refund-fix-and-migration-plan.md).
 *
 *         Sets `batchDonationSize` on the CURRENT live index-4 Sky-route
 *         BalancerPoolerV2 (story 056, `0x7f74388b…786b`). Defaults to 0,
 *         which halts the per-mint 10% USDS→USDC PSM donation so a 40-batch
 *         can no longer refund itself out of the nudge pot while the patched
 *         BatchNFTMinter is built & deployed.
 *
 *         The target is parameterized via the `DONATION_SIZE` env var (0..100,
 *         default 0) so this SAME script restores the donation after migration:
 *
 *           STOP  (set to 0):   DONATION_SIZE unset  (or =0)
 *           RESTORE (set to 10): DONATION_SIZE=10     ← run AFTER the new
 *                                BatchNFTMinter is live and wired (pooler
 *                                setBatchMinter + SYA setNudgeAddress).
 *
 *         Dry run (STOP):
 *           PREVIEW_MODE=true forge script script/SetBatchDonationSizeZeroIndex4.s.sol \
 *             --rpc-url $RPC_MAINNET -vvv
 *
 *         Broadcast STOP (Ledger, index 46):
 *           forge script script/SetBatchDonationSizeZeroIndex4.s.sol \
 *             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 *         Broadcast RESTORE to 10% (Ledger, index 46):
 *           DONATION_SIZE=10 forge script script/SetBatchDonationSizeZeroIndex4.s.sol \
 *             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract SetBatchDonationSizeZeroIndex4 is Script {
    // CURRENT live index-4 Sky-route BalancerPoolerV2 (story 056).
    // nftsV2.BalancerPooler in server/deployments/mainnet-addresses.ts.
    address public constant POOLER        = 0x7f74388bc970dE5e2822036A1aD06fCCd156786b;
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        // Default 0 = STOP donation. Override DONATION_SIZE=10 to RESTORE.
        uint256 targetSize = vm.envOr("DONATION_SIZE", uint256(0));
        require(targetSize <= 100, "DONATION_SIZE must be 0..100");

        console.log("===========================================");
        console.log("  SET batchDonationSize ON INDEX-4 POOLER");
        console.log("===========================================");
        console.log("Pooler:    ", POOLER);
        console.log("Target %:  ", targetSize);

        require(
            IBalancerPoolerV2Like(POOLER).owner() == OWNER_ADDRESS,
            "Unexpected pooler owner"
        );

        uint256 pre = IBalancerPoolerV2Like(POOLER).batchDonationSize();
        console.log("Pre value: ", pre);
        require(pre != targetSize, "batchDonationSize already at target -- nothing to do");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        IBalancerPoolerV2Like(POOLER).setBatchDonationSize(targetSize);
        console.log("setBatchDonationSize -- sent, target:", targetSize);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        uint256 post = IBalancerPoolerV2Like(POOLER).batchDonationSize();
        require(post == targetSize, "batchDonationSize did not update");
        console.log("Post value:", post);

        console.log("");
        console.log("===========================================");
        console.log("  DONE");
        console.log("===========================================");
    }
}
