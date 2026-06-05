// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// [story-057] Migrate the BatchNFTMinter to the self-refund-fixed instance (nft-staking 5f863d2,
// "snapshot nudge pot before mint loop"). Deploy a new (fixed) BatchNFTMinter, configure it
// identically to the live one, repoint the two real funders (SYA nudge + Sky-route
// BalancerPoolerV2 batchMinter), drain the old instance's residual USDC into the new pot
// (plain rescueERC20 — NO BPT exit/swap dance), restore the pooler batchDonationSize to 10%
// (zeroed as the interim bleed-stop), and retire the old contract. Single owner-signed broadcast,
// PREVIEW_MODE-aware fork dry-run. Primary template: script/ReplaceBatchNFTMinter.s.sol (story 050);
// donation-restore pattern: script/SetBatchDonationSizeIndex4.s.sol (retargeted to the live Sky pooler).

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {ITokenMinterV2} from "@yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";

/**
 * @title MigrateBatchNFTMinter
 * @notice One-shot mainnet migration (story 057 / self-refund-fix-and-migration-plan §6): deploys
 *         the self-refund-fixed BatchNFTMinter (nft-staking 5f863d2 snapshots the nudge pot BEFORE
 *         the mint loop, so a 40-batcher receives only the PRIOR pot and their own per-mint
 *         donations seed the next claimant), repoints its two real funders, seeds the new USDC
 *         nudge pot by draining the old instance (rescueERC20), restores the Sky-route pooler's
 *         batchDonationSize to 10%, and neutralizes the old (buggy) contract.
 *
 * Flow (single owner-signed broadcast; order matters):
 *   1. Pre-flight snapshot (old USDC balance, pooler.batchMinter, SYA.nudge, pooler.batchDonationSize).
 *   2. Deploy new BatchNFTMinter(OWNER).
 *   3. Configure (minter first): setTokenMinter -> setDispatcherIndex(4) -> setNudgePaymentToken(USDC)
 *                 -> setNudgeSize(40) -> (optional) setPauser (default: leave 0, matching current).
 *   4. Guards (config invariants) before any funds/pointers move.
 *   5. Repoint funders: SYA.setNudgeAddress(new) + BalancerPoolerV2.setBatchMinter(new).
 *      (nudgeSplit is LEFT at 30 — only the address is repointed; zeroing it while split>0 DoSes claim().)
 *   6. Drain + seed: if old USDC balance > 0, oldBatch.rescueERC20(USDC, new, bal) -> seeds the new pot.
 *   7. Restore donation: pooler.setBatchDonationSize(10) (skip if already 10) — AFTER the repoint so
 *      restored donations flow to the NEW minter.
 *   8. Retire old contract: assert USDC balance == 0; zero its nudge config (idempotent).
 *   9. Persist progress JSON (broadcast only).
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/MigrateBatchNFTMinter.s.sol:MigrateBatchNFTMinter \
 *     --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --slow -vvv
 *
 * Broadcast:
 *   forge script script/MigrateBatchNFTMinter.s.sol:MigrateBatchNFTMinter \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

interface ISYANudge {
    function setNudgeAddress(address) external;
    // NOTE: the getter is the public state var `nudge` (StableYieldAccumulator.sol:
    // `address public nudge;`), NOT `nudgeAddress`. The setter is `setNudgeAddress`. (story 050 quirk)
    function nudge() external view returns (address);
    // nudgeSplit (percent [0,100]) is LEFT UNTOUCHED at 30 by this migration — only the nudge address
    // is repointed. SYA.claim() reverts whenever nudgeSplit>0 && nudge==address(0), so the pointer
    // must remain live; we never zero it.
    function nudgeSplit() external view returns (uint256);
}

interface IBalancerPoolerV2Min {
    function setBatchMinter(address) external;
    function batchMinter() external view returns (address);
    function setBatchDonationSize(uint256) external;
    function batchDonationSize() external view returns (uint256);
    function owner() external view returns (address);
}

interface IOldBatchMinter {
    function setNudgePaymentToken(address) external;
    function setNudgeSize(uint256) external;
    function nudgeSize() external view returns (uint256);
    function nudgePaymentToken() external view returns (address);
    function rescueERC20(IERC20 token, address to, uint256 amount) external;
}

interface INFTMinterV2Configs {
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

interface ITokenDispatcherV2Prime {
    function primeToken() external view returns (address);
}

contract MigrateBatchNFTMinter is Script {
    // ============ Mainnet addresses (hardcoded constants, per repo convention) ============
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    // Story-056 deploy, current/live, self-refund bug — drain its residual USDC and retire it.
    address public constant OLD_BATCH_MINTER = 0x6e9886AfDF07DD67dc70b8335E4e9DF14B445071;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    // The LIVE Sky-route BalancerPoolerV2 (story 056, index-4) — repoint + restore donation.
    // NOT the stale 0x26F89f… pooler that SetBatchDonationSizeIndex4.s.sol hardcodes.
    address public constant POOLER = 0x7f74388bc970dE5e2822036A1aD06fCCd156786b;
    address public constant SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Derived prime/payment token of dispatcher index 4 (must differ from the USDC nudge token).
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    uint256 public constant DISPATCHER_INDEX = 4;
    uint256 public constant NUDGE_SIZE = 40;
    // Pooler donation rate (percent) to restore after the migration. Source: plan §"Interim
    // bleed-stop" — it was zeroed to halt the self-refund bleed; the canonical operating value is 10%.
    uint256 public constant DONATION_SIZE = 10;

    address public newMinter;

    string public constant PROGRESS_PATH = "server/deployments/progress.batch-minter-migrate.1.json";

    function run() external {
        bool preview = vm.envOr("PREVIEW_MODE", false);

        if (preview) {
            console.log("=== PREVIEW MODE (fork dry-run) ===");
            vm.startPrank(OWNER);
        } else {
            console.log("=== BROADCAST MODE ===");
            vm.startBroadcast();
        }

        _preflight();
        _deployAndConfigure();
        _guards();
        _repoint();
        uint256 usdcSeeded = _drainAndSeed();
        _restoreDonation();
        _retireOld();
        _postflight(usdcSeeded);

        if (preview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
            _persist(usdcSeeded);
        }
    }

    // ============ 1. Pre-flight snapshot ============
    function _preflight() internal view {
        console.log("==== PRE-FLIGHT ====");
        console.log("old batchMinter:       ", OLD_BATCH_MINTER);
        console.log("old USDC balance:      ", IERC20(USDC).balanceOf(OLD_BATCH_MINTER));
        console.log("SYA nudge:             ", ISYANudge(SYA).nudge());
        console.log("SYA nudgeSplit:        ", ISYANudge(SYA).nudgeSplit());
        console.log("pooler batchMinter:    ", IBalancerPoolerV2Min(POOLER).batchMinter());
        console.log("pooler batchDonation%: ", IBalancerPoolerV2Min(POOLER).batchDonationSize());
    }

    // ============ 2-3. Deploy + configure ============
    function _deployAndConfigure() internal {
        BatchNFTMinter m = new BatchNFTMinter(OWNER);
        newMinter = address(m);
        console.log("Deployed new BatchNFTMinter:", newMinter);

        // order matters — minter first, then index, payment token, size
        m.setTokenMinter(ITokenMinterV2(NFT_MINTER_V2));
        m.setDispatcherIndex(DISPATCHER_INDEX);
        m.setNudgePaymentToken(USDC);
        m.setNudgeSize(NUDGE_SIZE);
        // Pauser: default to matching the current live instance (pauser == address(0), minimal
        // change). Wiring the global Pauser is flagged to the operator as an option (plan §4 Q1),
        // not assumed here.
        console.log("Configured: tokenMinter, dispatcherIndex=4, nudgeToken=USDC, nudgeSize=40");
    }

    // ============ 4. Config-invariant guards (before any funds/pointers move) ============
    function _guards() internal view {
        BatchNFTMinter m = BatchNFTMinter(newMinter);
        require(address(m.tokenMinter()) != address(0), "tokenMinter not set");
        require(m.dispatcherIndex() == DISPATCHER_INDEX, "dispatcherIndex != 4");
        require(m.nudgePaymentToken() == USDC, "nudge token != USDC");

        // resolve the pinned index-4 dispatcher via the live NFTMinterV2 and check its prime token
        (address dispatcher,,,) = INFTMinterV2Configs(NFT_MINTER_V2).configs(DISPATCHER_INDEX);
        require(dispatcher != address(0), "index-4 dispatcher missing");
        address primeToken = ITokenDispatcherV2Prime(dispatcher).primeToken();
        console.log("index-4 dispatcher: ", dispatcher);
        console.log("index-4 primeToken: ", primeToken);
        // index-4 is the USDS / BalancerPoolerV2 path (confirmed on-chain 2026-06-05:
        // configs(4).primeToken == USDS 0xdC03...384F).
        require(primeToken == USDS, "index-4 primeToken != USDS");
        // The security-critical exploit guard: nudge payout token MUST differ from the dispatcher's
        // prime (mint payment) token, else batchMint would revert up-front.
        require(m.nudgePaymentToken() != primeToken, "nudge token == prime token");
        console.log("Guards passed.");
    }

    // ============ 5. Repoint dependencies ============
    function _repoint() internal {
        // Only the nudge ADDRESS is repointed; nudgeSplit stays 30 (the intended incentive). Zeroing
        // the split is NOT done — and we never zero the address while split>0 (would DoS claim()).
        ISYANudge(SYA).setNudgeAddress(newMinter);
        IBalancerPoolerV2Min(POOLER).setBatchMinter(newMinter);
        require(ISYANudge(SYA).nudge() == newMinter, "SYA repoint failed");
        require(IBalancerPoolerV2Min(POOLER).batchMinter() == newMinter, "pooler repoint failed");
        console.log("Repointed SYA + BalancerPoolerV2 to new minter");
    }

    // ============ 6. Drain old USDC + seed new pot ============
    function _drainAndSeed() internal returns (uint256 usdcSeeded) {
        // Seeding is a plain drain (the predecessor already holds USDC) — NOT the BPT exit/swap dance
        // from story 050. Read the rescue amount LIVE (USDC is 6-dp; don't hardcode).
        uint256 oldBal = IERC20(USDC).balanceOf(OLD_BATCH_MINTER);
        uint256 potBefore = IERC20(USDC).balanceOf(newMinter);
        if (oldBal > 0) {
            IOldBatchMinter(OLD_BATCH_MINTER).rescueERC20(IERC20(USDC), newMinter, oldBal);
        }
        usdcSeeded = IERC20(USDC).balanceOf(newMinter) - potBefore;
        require(usdcSeeded == oldBal, "seed amount mismatch");
        console.log("Drained old USDC into new pot:", usdcSeeded);
    }

    // ============ 7. Restore pooler donation (AFTER repoint) ============
    function _restoreDonation() internal {
        require(IBalancerPoolerV2Min(POOLER).owner() == OWNER, "unexpected pooler owner");
        uint256 cur = IBalancerPoolerV2Min(POOLER).batchDonationSize();
        if (cur != DONATION_SIZE) {
            IBalancerPoolerV2Min(POOLER).setBatchDonationSize(DONATION_SIZE);
        }
        require(IBalancerPoolerV2Min(POOLER).batchDonationSize() == DONATION_SIZE, "donation restore failed");
        console.log("pooler batchDonationSize restored to:", DONATION_SIZE);
    }

    // ============ 8. Retire old contract (defense-in-depth) ============
    function _retireOld() internal {
        uint256 oldUsdc = IERC20(USDC).balanceOf(OLD_BATCH_MINTER);
        console.log("Old contract USDC balance:", oldUsdc);
        require(oldUsdc == 0, "old contract still holds USDC");

        // idempotent — zero the old nudge config so it can never pay out again.
        if (IOldBatchMinter(OLD_BATCH_MINTER).nudgePaymentToken() != address(0)) {
            IOldBatchMinter(OLD_BATCH_MINTER).setNudgePaymentToken(address(0));
        }
        if (IOldBatchMinter(OLD_BATCH_MINTER).nudgeSize() != 0) {
            IOldBatchMinter(OLD_BATCH_MINTER).setNudgeSize(0);
        }
        console.log("Old contract neutralized (nudge token=0, size=0)");
    }

    // ============ Post-flight + persist ============
    function _postflight(uint256 usdcSeeded) internal view {
        console.log("==== POST-FLIGHT ====");
        console.log("new batchMinter:       ", newMinter);
        console.log("new USDC (nudge pot):  ", IERC20(USDC).balanceOf(newMinter));
        console.log("usdc seeded:           ", usdcSeeded);
        console.log("SYA nudge:             ", ISYANudge(SYA).nudge());
        console.log("SYA nudgeSplit:        ", ISYANudge(SYA).nudgeSplit());
        console.log("pooler batchMinter:    ", IBalancerPoolerV2Min(POOLER).batchMinter());
        console.log("pooler batchDonation%: ", IBalancerPoolerV2Min(POOLER).batchDonationSize());
    }

    function _persist(uint256 usdcSeeded) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": 1,');
        json = string.concat(json, '"networkName": "mainnet",');
        json = string.concat(json, '"batchMinter": "', vm.toString(newMinter), '",');
        json = string.concat(json, '"oldBatchMinter": "', vm.toString(OLD_BATCH_MINTER), '",');
        json = string.concat(json, '"usdcSeeded": ', vm.toString(usdcSeeded), ",");
        json = string.concat(json, '"donationSize": ', vm.toString(DONATION_SIZE), ",");
        json = string.concat(json, '"timestamp": ', vm.toString(block.timestamp));
        json = string.concat(json, "}");
        vm.writeFile(PROGRESS_PATH, json);
        console.log("Progress file written:", PROGRESS_PATH);
    }
}
