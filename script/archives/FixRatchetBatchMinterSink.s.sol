// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title FixRatchetBatchMinterSink
 * @notice Additive, idempotent corrective follow-up to DeployMainnetNudgeRatchet.s.sol
 *         (story 069). Two owner-only state changes, no new deployments:
 *
 *           1. NudgeRatchet.setBatchMinter(ORIGINAL BatchNFTMinter 0x86866e…)
 *              The original deploy wired NudgeRatchet's USDC sink to the dedicated
 *              RatchetBatchNFTMinter (0x81896…). Because that contract is BOTH the
 *              ratchet-NFT batch-mint UI entrypoint AND the dispatcher sink, a ratchet
 *              batchMint swept its own USDC back in during the loop and then refunded
 *              it to the caller (self-refund: count < nudgeSize, USDC counted as
 *              "remaining"). Pointing the sink at the ORIGINAL BatchNFTMinter — whose
 *              nudge token is USDC and whose own batchMint pays USDS (index 4) — means
 *              ratchet USDC now lands and STAYS there as the whale-nudge bounty,
 *              growing the incentive to batch-mint >= 40 USDS BalancerPooler NFTs.
 *              Entrypoint (0x81896…) != sink (0x86866…) eliminates the self-refund.
 *
 *           2. NFTMinterV2.setPrice(7, 10 USDC)
 *              The single test mint ratcheted index-7's price 10 -> 10.1 USDC. Reset
 *              it to the genesis 10 USDC so the reservoir reopens at its intended price.
 *
 *         RatchetBatchNFTMinter (0x81896…) is INTENTIONALLY retained — it stays the UI
 *         batch-mint entrypoint for ratchet NFTs. Only the NudgeRatchet *sink* changes.
 *
 * LEDGER SIGNER:
 *   Owner: 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 (HD path m/44'/60'/46'/0/0)
 *   (Owns both NudgeRatchet and NFTMinterV2 — verified on-chain.)
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/FixRatchetBatchMinterSink.s.sol --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast:
 *   forge script script/FixRatchetBatchMinterSink.s.sol --rpc-url $RPC_MAINNET --broadcast
 *     --skip-simulation --slow --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */
interface INudgeRatchetSink {
    function owner() external view returns (address);
    function batchMinter() external view returns (address);
    function setBatchMinter(address newBatchMinter) external;
}

interface INFTMinterV2Price {
    function owner() external view returns (address);
    function getPrice(uint256 index) external view returns (uint256);
    function setPrice(uint256 index, uint256 newPrice) external;
}

interface IBatchMinterConfig {
    function nudgePaymentToken() external view returns (address);
    function dispatcherIndex() external view returns (uint256);
}

contract FixRatchetBatchMinterSink is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES (mainnet-addresses.ts)
    // ==========================================
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant NUDGE_RATCHET = 0x7A4eD11160A06bB1C5b59091575d59707BE97a72;

    // The CORRECT USDC sink: the original BatchNFTMinter. nudgePaymentToken == USDC,
    // dispatcherIndex == 4 (USDS BalancerPoolerV2), so incoming USDC accrues as the
    // whale-nudge bounty and is never self-swept (its own payment token is USDS).
    address public constant ORIGINAL_BATCH_MINTER = 0x86866e01a115C17892Ed04c548F2e8638851029d;

    // The dedicated ratchet batch minter (UI entrypoint) — the WRONG sink we are leaving.
    address public constant RATCHET_BATCH_MINTER = 0x81896F48a95AbeA255cd38a3010E985b6051A1C7;

    // Canonical mainnet USDC (6-decimal) — the ratchet prime token and the bounty token.
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ==========================================
    //   CONFIGURATION CONSTANTS
    //   (Configuration Safety: every value deliberately chosen, none a default.)
    // ==========================================
    /// @notice NudgeRatchet dispatcher index (index 6 is the disabled bugged pooler).
    uint256 public constant RATCHET_INDEX = 7;
    /// @notice Genesis reservoir mint price: 10 USDC (6-decimal). Confirmed by story spec.
    uint256 public constant RATCHET_RESET_PRICE = 10_000_000; // 10 * 1e6

    bool isPreview;

    function run() external {
        console.log("=========================================");
        console.log("  FIX RATCHET BATCHMINTER SINK + PRICE");
        console.log("=========================================");
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        // --- Configuration Safety guards: refuse to broadcast with unsafe values. ---
        require(NUDGE_RATCHET != address(0), "NudgeRatchet unset");
        require(ORIGINAL_BATCH_MINTER != address(0), "target batchMinter unset");
        require(ORIGINAL_BATCH_MINTER != RATCHET_BATCH_MINTER, "sink must differ from entrypoint (self-refund)");
        require(RATCHET_RESET_PRICE > 0, "reset price unset");

        // Correctness pre-checks against live state (read-only).
        require(INudgeRatchetSink(NUDGE_RATCHET).owner() == OWNER_ADDRESS, "NudgeRatchet owner mismatch");
        require(INFTMinterV2Price(NFT_MINTER_V2).owner() == OWNER_ADDRESS, "NFTMinterV2 owner mismatch");
        // The target sink MUST be a USDC-nudge batch minter so forwarded USDC accrues as
        // the bounty (and is never self-swept — its own payment token must NOT be USDC).
        require(
            IBatchMinterConfig(ORIGINAL_BATCH_MINTER).nudgePaymentToken() == USDC,
            "target batchMinter nudge token is not USDC"
        );
        require(
            IBatchMinterConfig(ORIGINAL_BATCH_MINTER).dispatcherIndex() != RATCHET_INDEX,
            "target batchMinter must not mint the ratchet index"
        );

        console.log("--- BEFORE ---");
        console.log("NudgeRatchet.batchMinter: ", INudgeRatchetSink(NUDGE_RATCHET).batchMinter());
        console.log("index-7 price (USDC 6dp): ", INFTMinterV2Price(NFT_MINTER_V2).getPrice(RATCHET_INDEX));
        console.log("target sink (original):   ", ORIGINAL_BATCH_MINTER);
        console.log("reset price (USDC 6dp):   ", RATCHET_RESET_PRICE);
        console.log("-----------------------------------------");

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner (no signing) ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // ====== Step 1: redirect NudgeRatchet USDC sink to the original BatchNFTMinter ======
        if (INudgeRatchetSink(NUDGE_RATCHET).batchMinter() == ORIGINAL_BATCH_MINTER) {
            console.log("Step 1: NudgeRatchet.batchMinter already correct - skipping");
        } else {
            INudgeRatchetSink(NUDGE_RATCHET).setBatchMinter(ORIGINAL_BATCH_MINTER);
            console.log("Step 1: NudgeRatchet.setBatchMinter -> original BatchNFTMinter");
        }

        // ====== Step 2: reset index-7 reservoir price to 10 USDC ======
        if (INFTMinterV2Price(NFT_MINTER_V2).getPrice(RATCHET_INDEX) == RATCHET_RESET_PRICE) {
            console.log("Step 2: index-7 price already 10 USDC - skipping");
        } else {
            INFTMinterV2Price(NFT_MINTER_V2).setPrice(RATCHET_INDEX, RATCHET_RESET_PRICE);
            console.log("Step 2: NFTMinterV2.setPrice(7, 10 USDC)");
        }

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ====== Post-change verification (read-only; safe in both modes) ======
        console.log("\n=== Verification ===");
        require(
            INudgeRatchetSink(NUDGE_RATCHET).batchMinter() == ORIGINAL_BATCH_MINTER,
            "verify: batchMinter not redirected"
        );
        require(
            INFTMinterV2Price(NFT_MINTER_V2).getPrice(RATCHET_INDEX) == RATCHET_RESET_PRICE,
            "verify: index-7 price not reset to 10 USDC"
        );
        console.log("  NudgeRatchet.batchMinter == original BatchNFTMinter: OK");
        console.log("  index-7 price == 10 USDC: OK");
        console.log("=========================================");
        console.log("  FIX COMPLETE");
        console.log("=========================================");
    }
}
