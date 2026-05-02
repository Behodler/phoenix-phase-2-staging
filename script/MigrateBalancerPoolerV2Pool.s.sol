// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";

/**
 * @title MigrateBalancerPoolerV2Pool
 * @notice Withdraws all BPT held by the live BalancerPoolerV2 to a recipient,
 *         then repoints the dispatcher to the new phUSD/sUSDS 50/50 pool.
 * @dev Order matters: `withdrawBPT` reads the current `_pool` to decide which
 *      BPT token to transfer. Eject first (old E-CLP BPT), then `setPool`
 *      (new 50/50 pool). The immutable `_sUSDSIsFirst` flag stays valid because
 *      both pools order tokens as [sUSDS, phUSD].
 *
 * LEDGER SIGNER:
 * - Owner Address: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 *
 * Preview:
 *   PREVIEW_MODE=true forge script script/MigrateBalancerPoolerV2Pool.s.sol:MigrateBalancerPoolerV2Pool --rpc-url $RPC_MAINNET -vvv
 *
 * Broadcast:
 *   forge script script/MigrateBalancerPoolerV2Pool.s.sol:MigrateBalancerPoolerV2Pool --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
contract MigrateBalancerPoolerV2Pool is Script {
    address public constant BALANCER_POOLER_V2 = 0x6e957842AFBCD01cE9DB296D173F39134b362771;
    address public constant OLD_POOL = 0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58; // Gyro E-CLP phUSD/sUSDS
    address public constant NEW_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04; // 50/50 phUSD/sUSDS
    address public constant BPT_RECIPIENT = 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28;

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        console.log("=========================================");
        console.log("  MIGRATE BalancerPoolerV2 -> new pool");
        console.log("=========================================");
        require(block.chainid == 1, "Wrong chain - expected Mainnet (1)");

        BalancerPoolerV2 pooler = BalancerPoolerV2(BALANCER_POOLER_V2);

        // Sanity: confirm we're operating on the expected dispatcher and old pool
        address currentPool = pooler.pool();
        console.log("BalancerPoolerV2:    ", BALANCER_POOLER_V2);
        console.log("Current pool:        ", currentPool);
        console.log("Expected old pool:   ", OLD_POOL);
        console.log("Target new pool:     ", NEW_POOL);
        console.log("BPT recipient:       ", BPT_RECIPIENT);
        require(currentPool == OLD_POOL, "Current pool != expected OLD_POOL; aborting");

        uint256 bptBalance = IERC20(OLD_POOL).balanceOf(BALANCER_POOLER_V2);
        console.log("");
        console.log("Old-pool BPT held:   ", bptBalance);

        bool isPreview = vm.envOr("PREVIEW_MODE", false);

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // Step 1: eject ALL old-pool BPT to recipient (must run before setPool)
        if (bptBalance > 0) {
            console.log("");
            console.log("=== Step 1: withdrawBPT(recipient, balance) ===");
            pooler.withdrawBPT(BPT_RECIPIENT, bptBalance);
            console.log("Withdrawn BPT:       ", bptBalance);
            console.log("To:                  ", BPT_RECIPIENT);
        } else {
            console.log("");
            console.log("=== Step 1: SKIPPED (zero BPT balance) ===");
        }

        // Step 2: repoint dispatcher to new pool
        console.log("");
        console.log("=== Step 2: setPool(NEW_POOL) ===");
        pooler.setPool(NEW_POOL);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // Post-checks
        address newCurrentPool = pooler.pool();
        uint256 recipientBpt = IERC20(OLD_POOL).balanceOf(BPT_RECIPIENT);
        uint256 leftoverBpt = IERC20(OLD_POOL).balanceOf(BALANCER_POOLER_V2);

        console.log("");
        console.log("=========================================");
        console.log("  POST-MIGRATION STATE");
        console.log("=========================================");
        console.log("pool() now:          ", newCurrentPool);
        console.log("Recipient BPT bal:   ", recipientBpt);
        console.log("Pooler BPT leftover: ", leftoverBpt);

        require(newCurrentPool == NEW_POOL, "setPool did not take effect");
        require(leftoverBpt == 0, "Pooler still holds old-pool BPT");
    }
}
