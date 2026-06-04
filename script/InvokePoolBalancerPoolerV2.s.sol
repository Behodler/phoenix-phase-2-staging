// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";

/// @title InvokePoolBalancerPoolerV2
/// @notice Operational mainnet script: invoke `pool(minBPT)` on the live Sky-PSM
///         BalancerPoolerV2, LP-adding the sUSDS the pooler has accumulated from
///         index-4 mints into the canonical phUSD/sUSDS Balancer V3 pool.
///
/// @dev The slippage-protected `minBPT` floor is computed OFF-CHAIN by
///      `scripts/compute-min-bpt-poolerv2.js` (which `eth_call`s the pooler's
///      `getIdealBPT()` router quote — the only frame Balancer V3 lets that query
///      run in — then subtracts the slippage tolerance) and passed in via the
///      `MIN_BPT_WEI` env var. This script REFUSES to broadcast an unprotected
///      pool() (minBPT == 0) on a real network. See the Configuration Safety gate
///      in CLAUDE.md: a zero slippage bound is an open sandwich/MEV invitation.
///
///      Driven by package.json:
///        PoolBalancerPoolerV2:dry        PREVIEW_MODE=true -> startPrank(OWNER), no broadcast
///        PoolBalancerPoolerV2:broadcast  ledger-signed (owner is an authorized pooler)
contract InvokePoolBalancerPoolerV2 is Script {
    // Live Sky-PSM BalancerPoolerV2 (index-4 dispatcher, story 056, 2026-06-04).
    // Source: server/deployments/mainnet-addresses.ts -> nftsV2.BalancerPooler,
    // cross-checked vs broadcast/DispatcherReplaceSkyPoolerAtIndex4.s.sol/1/run-latest.json.
    address public constant POOLER = 0x7f74388bc970dE5e2822036A1aD06fCCd156786b;

    // Pooler owner + authorized pooler (verified on-chain: poolerAuthVersion[OWNER]==authVersion).
    // Also the ledger signer for the broadcast (HD path m/44'/60'/46'/0/0).
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        bool isPreview = vm.envOr("PREVIEW_MODE", false);

        // Off-chain-derived slippage floor (base-1e18 BPT). Default 0 so a missing /
        // failed computation is caught by the require below rather than silently
        // broadcasting an unprotected pool(). See compute-min-bpt-poolerv2.js.
        uint256 minBPT = vm.envOr("MIN_BPT_WEI", uint256(0));

        BalancerPoolerV2 pooler = BalancerPoolerV2(POOLER);

        address sUSDS = pooler.sUSDS();
        address bpt = pooler.pool();
        uint256 sUSDSBal = IERC20Minimal(sUSDS).balanceOf(POOLER);

        console.log("=== InvokePoolBalancerPoolerV2 ===");
        console.log("chainid:           ", block.chainid);
        console.log("pooler:            ", POOLER);
        console.log("owner/pooler/signer:", OWNER_ADDRESS);
        console.log("sUSDS:             ", sUSDS);
        console.log("BPT (pool):        ", bpt);
        console.log("sUSDS balance:     ", sUSDSBal);
        console.log("MIN_BPT_WEI:       ", minBPT);
        console.log("preview:           ", isPreview);

        // ---- Safety gate (CLAUDE.md Configuration Safety) ----
        if (block.chainid == 31337) {
            // Anvil-only relaxation, gated + commented: a forked/local router quote may
            // not match the mainnet-derived floor. Real networks MUST enforce minBPT > 0.
            if (minBPT == 0) {
                console.log("  (Anvil) minBPT == 0 -- relaxing to 1 for local run");
                minBPT = 1;
            }
        } else {
            require(
                minBPT > 0, "MIN_BPT_WEI resolved to 0 -- refusing unprotected pool(). Run compute-min-bpt-poolerv2.js."
            );
        }

        // pool() reverts "nothing to pool" when sUSDS == 0; fail early with a clearer message
        // so we never waste a broadcast (sUSDS accrues from index-4 mints over time).
        require(sUSDSBal > 0, "pooler holds 0 sUSDS -- nothing to pool yet (wait for mints to accrue)");

        // Caller must be an authorized pooler and the pooler unpaused, or pool() reverts.
        require(
            pooler.poolerAuthVersion(OWNER_ADDRESS) == pooler.authVersion(),
            "OWNER is not an authorized pooler -- run AuthorizeOwnerAsPoolerV2 first"
        );
        require(!pooler.paused(), "pooler is paused -- cannot pool()");

        uint256 bptBefore = IERC20Minimal(bpt).balanceOf(POOLER);

        if (isPreview) {
            console.log("*** PREVIEW MODE -- impersonating owner via prank, no broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // pool() enforces the minBPT slippage floor on-chain: it reverts if the LP add
        // would mint fewer than minBPT, and consumes the full sUSDS balance on success.
        pooler.pool(minBPT);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        uint256 bptAfter = IERC20Minimal(bpt).balanceOf(POOLER);
        console.log("BPT.balanceOf(pooler) before:", bptBefore);
        console.log("BPT.balanceOf(pooler) after: ", bptAfter);
        console.log("BPT minted (>= minBPT floor):", bptAfter - bptBefore);
        console.log("sUSDS remaining (must be 0): ", IERC20Minimal(sUSDS).balanceOf(POOLER));

        require(bptAfter - bptBefore >= minBPT, "pool() minted fewer BPT than the minBPT floor");
        require(IERC20Minimal(sUSDS).balanceOf(POOLER) == 0, "pooler still holds sUSDS after pool()");
        console.log("pool() succeeded: sUSDS consumed, BPT increased above the slippage floor.");
    }
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}
