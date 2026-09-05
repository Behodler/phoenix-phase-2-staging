// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title UnpauseStakerBreakGlass
 * @notice Story 065 - YS-21 break-glass: a STANDALONE, single-purpose script that unpauses the
 *         LIVE original StableStaker (0xbce8…079A).
 *
 *         WHY: the YS-swap suite contract-globally pauses the live staker, which also freezes the
 *         unrelated live USDe pool. If the multi-step suite halts mid-run (mainnet incident, gas,
 *         operator stop), live USDe users would be stranded behind the pause until the whole suite
 *         is resumed. This script lets an operator restore the staker IMMEDIATELY and independently,
 *         without touching the migration state machine.
 *
 *         `StableStaker.unpause()` is callable by EITHER owner OR pauser (StableStaker.sol:281-282).
 *         The owner `0xCad1…D0B6` is used here. This does NOT advance/rewind the migration; the
 *         migration hooks (initiateMigration/migrate/depositFor) are deliberately callable while
 *         paused, so a later resume is unaffected by an interim unpause.
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/UnpauseStakerBreakGlass.s.sol:UnpauseStakerBreakGlass \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/UnpauseStakerBreakGlass.s.sol:UnpauseStakerBreakGlass \
 *     --rpc-url $RPC_MAINNET --broadcast --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
interface IStakerPause {
    function owner() external view returns (address);
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function unpause() external;
}

contract UnpauseStakerBreakGlass is Script {
    address public constant OWNER_ADDRESS          = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant ORIGINAL_STABLE_STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    uint256 public constant CHAIN_ID               = 1;

    bool public isPreview;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "UnpauseStakerBreakGlass: wrong chain - expected mainnet (1)");
    }

    function run() external {
        console.log("==========================================");
        console.log(" UnpauseStakerBreakGlass (story 065, YS-21)");
        console.log("==========================================");
        console.log("staker:        ", ORIGINAL_STABLE_STAKER);
        console.log("owner (ledger):", OWNER_ADDRESS);

        IStakerPause staker = IStakerPause(ORIGINAL_STABLE_STAKER);
        // Owner must be able to unpause (owner OR pauser per StableStaker.unpause()).
        require(staker.owner() == OWNER_ADDRESS, "Preflight: signer is not staker owner");

        bool pausedBefore = staker.paused();
        console.log("paused (before):", pausedBefore);
        if (!pausedBefore) {
            console.log("Staker already unpaused - nothing to do.");
            return;
        }

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***");
            vm.startBroadcast();
        }

        staker.unpause();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        bool pausedAfter = staker.paused();
        console.log("paused (after): ", pausedAfter);
        require(!pausedAfter, "Break-glass: staker still paused after unpause()");
        console.log("Break-glass unpause OK - live staker restored.");
    }
}
