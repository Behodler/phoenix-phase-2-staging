// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";

/**
 * @title StakeStableStaker
 * @notice Stake a fixed amount of the DOLA pool's token into the locally deployed
 *         StableStaker, as the first half of the story-051 config verification.
 * @dev Story 051. Companion to ClaimWithdrawStableStaker.s.sol. Reads the deployed
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
        address stakerAddr = vm.parseJsonAddress(progressJson, ".contracts.StableStaker.address");
        address dolaAddr = vm.parseJsonAddress(progressJson, ".contracts.MockDola.address");

        console.log("StableStaker:", stakerAddr);
        console.log("MockDola:", dolaAddr);

        StableStaker staker = StableStaker(stakerAddr);
        IERC20 dola = IERC20(dolaAddr);

        // --- Sanity: pool is configured at 10 phUSD/day ---
        (uint256 phusdPerSecond,,, uint256 totalStakedBefore) = staker.poolInfo(dolaAddr);
        console.log("\n--- Pre-stake pool state ---");
        console.log("DOLA pool phusdPerSecond:", phusdPerSecond);
        console.log("DOLA pool totalStaked (baseline):", totalStakedBefore);
        // 10 phUSD/day = 10e18 / 86400 (floored) = 115740740740740
        require(phusdPerSecond == uint256(10 ether) / 86400, "DOLA pool rate != 10 phUSD/day");

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

        require(userAmount == STAKE_AMOUNT, "staked principal mismatch");
        require(totalStakedAfter == totalStakedBefore + STAKE_AMOUNT, "totalStaked did not increase by stake");
        require(dolaBefore - dolaAfter == STAKE_AMOUNT, "DOLA debit mismatch");

        console.log("\nPASS: stake recorded. Advance time, then run ClaimWithdrawStableStaker.\n");
    }
}
