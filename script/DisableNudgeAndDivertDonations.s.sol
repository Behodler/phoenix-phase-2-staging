// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IStableYieldAccumulatorLike {
    function owner() external view returns (address);
    function nudge() external view returns (address);
    function nudgeSplit() external view returns (uint256);
    function rewardToken() external view returns (address);
    function setNudgeSplit(uint256) external;
}

interface IBatchNFTMinterLike {
    function owner() external view returns (address);
    function nudgeSize() external view returns (uint256);
    function nudgePaymentToken() external view returns (address);
    function setNudgeSize(uint256) external;
    function setNudgePaymentToken(address) external;
}

interface IBalancerPoolerV2Like {
    function owner() external view returns (address);
    function batchMinter() external view returns (address);
    function setBatchMinter(address) external;
}

/**
 * @title DisableNudgeAndDivertDonations
 * @notice Stop-gap mitigation for the BatchNFTMinter nudge drain
 *         (see docs/batch-nft-minter-nudge-drain-fix.md). Holds the line until
 *         the fixed, minter-pinned BatchNFTMinter is deployed upstream.
 *
 *         WHY DISABLING THE BATCHMINTER NUDGE IS NOT ENOUGH ON ITS OWN:
 *         clearing nudgePaymentToken removes the `paymentToken == nudgeToken`
 *         guard, so a caller can pass paymentToken = USDC and the end-of-batch
 *         dust sweep (`paymentToken.safeTransfer(msg.sender, remaining)`) hands
 *         the whole USDC balance to any caller -- the same drain via a different
 *         line. The contract has no owner-withdraw, so anything that lands there
 *         is either swept by an attacker or stuck. The only robust stop-gap is
 *         to STOP FUNDS REACHING THE CONTRACT. This script does that.
 *
 *         Actions (all from the shared owner EOA):
 *           1. SYA.setNudgeSplit(0)              -- PRIMARY. The accumulator's
 *              permissionless claim() routes nudgeSplit% (currently 30%) of each
 *              claim's USDC to `nudge`, which is the drainable BatchNFTMinter.
 *              Zeroing the split stops the diversion entirely: the full claim
 *              payment flows to Phlimbo as normal rewards and nothing reaches the
 *              BatchNFTMinter. claim() keeps working (the `nudgeSplit > 0 &&
 *              nudge == address(0)` guard only bites while the split is > 0). The
 *              `nudge` address is left untouched -- it is inert while split == 0.
 *           2. BalancerPoolerV2.setBatchMinter(OWNER) -- secondary. Redirects the
 *              pool() donation USDC to the owner so it is set aside. Belt-and-
 *              suspenders: the operator does not intend to call pool(), but this
 *              keeps a stray authorized pool() call from refunding the drainable
 *              contract.
 *           3. BatchNFTMinter nudge disable (setNudgePaymentToken(0),
 *              setNudgeSize(0)) -- defense in depth per the original request.
 *              NOTE: see caveat above; this is not the protection -- (1)/(2) are.
 *
 *         Dry run (impersonates owner, no broadcast):
 *           npm run DisableNudgeAndDivertDonations:preview
 *
 *         Broadcast (Ledger, owner key m/44'/60'/46'/0/0):
 *           npm run DisableNudgeAndDivertDonations
 */
contract DisableNudgeAndDivertDonations is Script {
    address public constant SYA            = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address public constant BATCH_MINTER   = 0x4ef0fDe49360ed31c68ED442Ff263CC6291041f3;
    address public constant POOLER         = 0x26F89f4B46eB164303985795ee20b15BB1Edb38A;
    address public constant OWNER_ADDRESS  = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant USDC           = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Pool donations are diverted here to be set aside until the fixed contract ships.
    address public constant SINK = OWNER_ADDRESS;

    function run() external {
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");

        IStableYieldAccumulatorLike sya = IStableYieldAccumulatorLike(SYA);
        IBatchNFTMinterLike batch = IBatchNFTMinterLike(BATCH_MINTER);
        IBalancerPoolerV2Like pooler = IBalancerPoolerV2Like(POOLER);

        console.log("===========================================");
        console.log("  STOP-GAP: CUT FUNDING TO DRAINABLE BATCHMINTER");
        console.log("===========================================");
        console.log("SYA:           ", SYA);
        console.log("BatchNFTMinter:", BATCH_MINTER);
        console.log("Pooler:        ", POOLER);
        console.log("Pool sink:     ", SINK);

        require(sya.owner() == OWNER_ADDRESS, "Unexpected SYA owner");
        require(batch.owner() == OWNER_ADDRESS, "Unexpected BatchNFTMinter owner");
        require(pooler.owner() == OWNER_ADDRESS, "Unexpected Pooler owner");

        // Sanity: this mitigation targets the USDC drip. If the reward token ever
        // changed out from under us, stop and re-audit before broadcasting.
        require(sya.rewardToken() == USDC, "SYA rewardToken changed - re-audit");

        // Pre-state
        uint256 preSyaSplit   = sya.nudgeSplit();
        address prePoolMinter = pooler.batchMinter();
        uint256 preNudgeSize  = batch.nudgeSize();
        address preNudgeTok   = batch.nudgePaymentToken();

        console.log("");
        console.log("-- Pre-state --");
        console.log("SYA.nudgeSplit:      ", preSyaSplit);
        console.log("SYA.nudge (inert):   ", sya.nudge());
        console.log("pooler.batchMinter:  ", prePoolMinter);
        console.log("batch.nudgeSize:     ", preNudgeSize);
        console.log("batch.nudgePaymentTk:", preNudgeTok);

        require(
            preSyaSplit != 0
                || prePoolMinter != SINK
                || preNudgeTok != address(0)
                || preNudgeSize != 0,
            "Already mitigated -- nothing to do"
        );

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        // 1. PRIMARY: stop the SYA claim() drip into the BatchNFTMinter entirely.
        //    Full claim payment now flows to Phlimbo; claim() stays functional.
        if (preSyaSplit != 0) {
            sya.setNudgeSplit(0);
            console.log("SYA.setNudgeSplit(0) -- sent");
        }

        // 2. Secondary: redirect pool() donation USDC to the owner (set aside).
        if (prePoolMinter != SINK) {
            pooler.setBatchMinter(SINK);
            console.log("pooler.setBatchMinter(owner) -- sent");
        }

        // 3. Defense in depth: disable the BatchNFTMinter nudge (see caveat in header).
        if (preNudgeTok != address(0)) {
            batch.setNudgePaymentToken(address(0));
            console.log("batch.setNudgePaymentToken(0) -- sent");
        }
        if (preNudgeSize != 0) {
            batch.setNudgeSize(0);
            console.log("batch.setNudgeSize(0) -- sent");
        }

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // Post-state verification
        uint256 postSyaSplit   = sya.nudgeSplit();
        address postPoolMinter = pooler.batchMinter();
        uint256 postNudgeSize  = batch.nudgeSize();
        address postNudgeTok   = batch.nudgePaymentToken();

        console.log("");
        console.log("-- Post-state --");
        console.log("SYA.nudgeSplit:      ", postSyaSplit);
        console.log("pooler.batchMinter:  ", postPoolMinter);
        console.log("batch.nudgeSize:     ", postNudgeSize);
        console.log("batch.nudgePaymentTk:", postNudgeTok);

        require(postSyaSplit == 0, "SYA nudgeSplit not zeroed");
        require(postPoolMinter == SINK, "pooler batchMinter not redirected");
        require(postNudgeTok == address(0), "batch nudgePaymentToken not cleared");
        require(postNudgeSize == 0, "batch nudgeSize not cleared");
        // No funding path reaches the drainable BatchNFTMinter anymore.

        console.log("");
        console.log("===========================================");
        console.log("  DONE - SYA drip stopped; pool donations set aside");
        console.log("===========================================");
    }
}
