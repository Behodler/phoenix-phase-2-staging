// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TransferBPTToPoolerV2
 * @notice Transfers the holder's entire balance of new-pool (50/50 phUSD/sUSDS) BPT
 *         to BalancerPoolerV2. Used after the BPT recipient unpools the old E-CLP
 *         BPT and repools into the new pool, returning the BPT "ownership" to the
 *         dispatcher.
 *
 * @dev BalancerPoolerV2 has no internal accounting for BPT and no transfer hooks,
 *      so a plain ERC20 transfer is sufficient. Owner can later move the BPT via
 *      `withdrawBPT` (since `_pool == NEW_POOL` post-migration).
 *
 * LEDGER SIGNER:
 * - Holder Address: 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28 (HD path index 48)
 *
 * Dry-run:
 *   forge script script/interactions/TransferBPTToPoolerV2.s.sol:TransferBPTToPoolerV2 --rpc-url $RPC_MAINNET --sender 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28 -vvv
 *
 * Broadcast:
 *   forge script script/interactions/TransferBPTToPoolerV2.s.sol:TransferBPTToPoolerV2 --rpc-url $RPC_MAINNET --broadcast --slow --ledger --hd-paths "m/44'/60'/48'/0/0" -vvv
 */
contract TransferBPTToPoolerV2 is Script {
    using SafeERC20 for IERC20;

    address public constant NEW_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04; // 50/50 phUSD/sUSDS BPT
    address public constant BPT_HOLDER = 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28;
    address public constant BALANCER_POOLER_V2 = 0x6e957842AFBCD01cE9DB296D173F39134b362771;

    function run() external {
        require(block.chainid == 1, "Wrong chain - expected Mainnet (1)");

        IERC20 bpt = IERC20(NEW_POOL);

        uint256 holderBefore = bpt.balanceOf(BPT_HOLDER);
        uint256 poolerBefore = bpt.balanceOf(BALANCER_POOLER_V2);

        console.log("=========================================");
        console.log("  TRANSFER NEW-POOL BPT -> BalancerPoolerV2");
        console.log("=========================================");
        console.log("BPT (NEW_POOL):       ", NEW_POOL);
        console.log("Holder:               ", BPT_HOLDER);
        console.log("Pooler:               ", BALANCER_POOLER_V2);
        console.log("");
        console.log("Holder balance (pre): ", holderBefore);
        console.log("Pooler balance (pre): ", poolerBefore);

        require(holderBefore > 0, "Holder has zero new-pool BPT; nothing to transfer");

        vm.startBroadcast();
        bpt.safeTransfer(BALANCER_POOLER_V2, holderBefore);
        vm.stopBroadcast();

        uint256 holderAfter = bpt.balanceOf(BPT_HOLDER);
        uint256 poolerAfter = bpt.balanceOf(BALANCER_POOLER_V2);

        console.log("");
        console.log("Transferred:          ", holderBefore);
        console.log("Holder balance (post):", holderAfter);
        console.log("Pooler balance (post):", poolerAfter);

        require(holderAfter == 0, "Holder balance not fully drained");
        require(poolerAfter == poolerBefore + holderBefore, "Pooler delta mismatch");
    }
}
