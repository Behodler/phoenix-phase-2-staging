// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";

/**
 * @title StakeStableStaker
 * @notice Stake a fixed amount of the DOLA pool's token into the locally deployed
 *         StableStaker, as the first half of the story-051 config verification.
 * @dev Story 051; retargeted onto StableStakerV2 by story 080, which renamed the address-book
 *      key from `StableStaker` to `StableStakerV2` and left the local V1 untracked. The stake
 *      leg itself is unchanged — `stake` has the same signature and the same semantics on both
 *      versions; only the reward token behind it moved from phUSD to Antimatter.
 *      Companion to ClaimWithdrawStableStaker.s.sol. Reads the deployed
 *      addresses from progress.31337.json (same pattern as TestNudgePayout.s.sol).
 *
 *      Verification flow (orchestrated by verify-stable-staker.sh):
 *        1. deploy:local  -> StableStaker on Anvil with 3 pools (DOLA/USDe = 10/day,
 *           USDC = 5/day).
 *        2. THIS SCRIPT   -> stake STAKE_AMOUNT of DOLA for the deployer; record
 *           baseline totalStaked and the deployer's DOLA balance.
 *        3. evm_increaseTime 86400 + evm_mine (one day) via cast rpc.
 *        4. ClaimWithdrawStableStaker -> claim + withdraw, assert ~10 phUSD reward,
 *           full principal returned, totalStaked back to baseline.
 *
 *      The DOLA pool (10 phUSD/day) is used because the deployer is minted 1,000,000
 *      DOLA at deploy, so no extra seeding is needed.
 */
contract StakeStableStaker is Script {
    // 1,000 DOLA staked (18 decimals). Small relative to the deployer's 1M balance.
    uint256 constant STAKE_AMOUNT = 1_000 * 10 ** 18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("   STABLE STAKER VERIFY - STAKE");
        console.log("========================================\n");
        console.log("Deployer:", deployer);

        // --- Load addresses from progress.json ---
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");
        address stakerAddr = vm.parseJsonAddress(progressJson, ".contracts.StableStakerV2.address");
        address dolaAddr = vm.parseJsonAddress(progressJson, ".contracts.MockDola.address");

        console.log("StableStakerV2:", stakerAddr);
        console.log("MockDola:", dolaAddr);

        StableStakerV2 staker = StableStakerV2(stakerAddr);
        IERC20 dola = IERC20(dolaAddr);

        // --- Sanity: pool is configured at 10 Antimatter/day ---
        // Field 0 of `PoolInfo` is `antimatterPerSecond` on V2 (it was `phusdPerSecond` on V1);
        // the tuple shape is otherwise identical, so this positional read is unchanged.
        (uint256 antimatterPerSecond,,, uint256 totalStakedBefore) = staker.poolInfo(dolaAddr);
        console.log("\n--- Pre-stake pool state ---");
        console.log("DOLA pool antimatterPerSecond:", antimatterPerSecond);
        console.log("DOLA pool totalStaked (baseline):", totalStakedBefore);
        // 10 Antimatter/day = 10e18 / 86400 (floored) = 115740740740740
        require(antimatterPerSecond == uint256(10 ether) / 86400, "DOLA pool rate != 10 Antimatter/day");

        uint256 dolaBefore = dola.balanceOf(deployer);
        console.log("Deployer DOLA before stake:", dolaBefore);
        require(dolaBefore >= STAKE_AMOUNT, "deployer lacks DOLA to stake");

        // --- Stake ---
        console.log("\n--- Staking", STAKE_AMOUNT, "DOLA ---");
        vm.startBroadcast(deployerPrivateKey);
        dola.approve(stakerAddr, STAKE_AMOUNT);
        staker.stake(dolaAddr, STAKE_AMOUNT);
        vm.stopBroadcast();

        (,,, uint256 totalStakedAfter) = staker.poolInfo(dolaAddr);
        uint256 dolaAfter = dola.balanceOf(deployer);
        (uint256 userAmount,) = staker.userInfo(dolaAddr, deployer);

        console.log("\n--- Post-stake state ---");
        console.log("Deployer DOLA after stake:", dolaAfter);
        console.log("Deployer staked principal:", userAmount);
        console.log("DOLA pool totalStaked:", totalStakedAfter);

        // STORY 080: credited principal is asserted within a band rather than exactly, and the
        // band is TWO-SIDED. The pool is NO LONGER EMPTY when this runs — the cutover rehearsal
        // leaves 12 migrated positions in it — so the deposit routes through a strategy that is
        // already carrying a client position, and two effects that used to be absent now apply:
        // the assets->shares->assets round trip rounds, and the 10% set-aside buffer credits a
        // share of realised surplus back to the staker on the way in. The credit is therefore
        // within a whisker of the amount staked in either direction, not exactly equal to it.
        // The DEBIT, by contrast, is exact and is still asserted exactly — that is the number the
        // user actually paid.
        uint256 credited = userAmount > STAKE_AMOUNT ? userAmount - STAKE_AMOUNT : STAKE_AMOUNT - userAmount;
        require(credited <= STAKE_AMOUNT / 1000, "staked principal differs from the stake by more than 0.1%");
        require(totalStakedAfter == totalStakedBefore + userAmount, "totalStaked did not increase by the credit");
        require(dolaBefore - dolaAfter == STAKE_AMOUNT, "DOLA debit mismatch");

        console.log("\nPASS: stake recorded. Advance time, then run ClaimWithdrawStableStaker.\n");
    }
}
