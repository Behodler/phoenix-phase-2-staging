// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";

/**
 * @title ClaimWithdrawStableStaker
 * @notice Second half of the story-051 StableStaker config verification: after a day
 *         of elapsed time (advanced out-of-band via `cast rpc evm_increaseTime`), read
 *         pendingReward, claim phUSD, withdraw the full principal, and assert:
 *           - phUSD reward credited ~= the DOLA pool's daily rate (10 phUSD) within
 *             tolerance for the extra elapsed seconds;
 *           - the staked DOLA principal is fully returned;
 *           - the pool's totalStaked returns to its pre-stake baseline.
 * @dev Story 051. Companion to StakeStableStaker.s.sol. Modelled on
 *      ClaimPhlimboRewards.s.sol / TestNudgePayout.s.sol (AddressLoader-style address
 *      resolution from progress.31337.json).
 *
 *      Run AFTER StakeStableStaker + `cast rpc evm_increaseTime 86400` + `evm_mine`.
 */
contract ClaimWithdrawStableStaker is Script {
    uint256 constant STAKE_AMOUNT = 1_000 * 10 ** 18; // must match StakeStableStaker
    uint256 constant EXPECTED_DAILY_PHUSD = 10 * 10 ** 18; // DOLA pool = 10 phUSD/day

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("   STABLE STAKER VERIFY - CLAIM+WITHDRAW");
        console.log("========================================\n");
        console.log("Deployer:", deployer);

        // --- Load addresses ---
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");
        address stakerAddr = vm.parseJsonAddress(progressJson, ".contracts.StableStaker.address");
        address dolaAddr = vm.parseJsonAddress(progressJson, ".contracts.MockDola.address");
        address phusdAddr = vm.parseJsonAddress(progressJson, ".contracts.MockPhUSD.address");

        console.log("StableStaker:", stakerAddr);
        console.log("MockDola:", dolaAddr);
        console.log("MockPhUSD:", phusdAddr);

        StableStaker staker = StableStaker(stakerAddr);
        IERC20 dola = IERC20(dolaAddr);
        IERC20 phusd = IERC20(phusdAddr);

        // --- Baseline: pool totalStaked before our stake was STAKE_AMOUNT less ---
        (,,, uint256 totalStakedNow) = staker.poolInfo(dolaAddr);
        uint256 baseline = totalStakedNow - STAKE_AMOUNT; // pre-stake baseline
        console.log("\n--- Pre-exit state ---");
        console.log("DOLA pool totalStaked (incl. our stake):", totalStakedNow);
        console.log("Derived pre-stake baseline:", baseline);

        uint256 pending = staker.pendingReward(dolaAddr, deployer);
        uint256 phusdBefore = phusd.balanceOf(deployer);
        uint256 dolaBefore = dola.balanceOf(deployer);
        console.log("pendingReward (phUSD):", pending);
        console.log("Deployer phUSD before:", phusdBefore);
        console.log("Deployer DOLA before:", dolaBefore);
        require(pending > 0, "no reward accrued - did time advance via evm_increaseTime?");

        // --- Claim ---
        console.log("\n--- claim(DOLA) ---");
        vm.startBroadcast(deployerPrivateKey);
        staker.claim(dolaAddr);
        vm.stopBroadcast();

        uint256 phusdAfterClaim = phusd.balanceOf(deployer);
        uint256 rewardCredited = phusdAfterClaim - phusdBefore;
        console.log("Deployer phUSD after claim:", phusdAfterClaim);
        console.log("phUSD reward credited:", rewardCredited);

        // Assert reward ~= 10 phUSD. One full day = exactly 10 phUSD; allow a 1%
        // upper band for the handful of extra seconds (block mining between stake and
        // claim) and a tiny lower band for integer-division dust.
        uint256 lowerBound = EXPECTED_DAILY_PHUSD - (EXPECTED_DAILY_PHUSD / 100); // 9.9 phUSD
        uint256 upperBound = EXPECTED_DAILY_PHUSD + (EXPECTED_DAILY_PHUSD / 100); // 10.1 phUSD
        require(rewardCredited >= lowerBound, "reward below ~10 phUSD/day lower bound");
        require(rewardCredited <= upperBound, "reward above ~10 phUSD/day upper bound");
        console.log("Reward within [9.9, 10.1] phUSD band: OK");

        // --- Withdraw full principal ---
        console.log("\n--- withdraw(DOLA, STAKE_AMOUNT) ---");
        vm.startBroadcast(deployerPrivateKey);
        staker.withdraw(dolaAddr, STAKE_AMOUNT);
        vm.stopBroadcast();

        uint256 dolaAfter = dola.balanceOf(deployer);
        (uint256 userAmount,) = staker.userInfo(dolaAddr, deployer);
        (,,, uint256 totalStakedFinal) = staker.poolInfo(dolaAddr);

        console.log("\n--- Post-withdraw state ---");
        console.log("Deployer DOLA after withdraw:", dolaAfter);
        console.log("Deployer remaining staked principal:", userAmount);
        console.log("DOLA pool totalStaked (final):", totalStakedFinal);

        require(userAmount == 0, "principal not fully withdrawn");
        // Principal accounting is fully cleared (userAmount == 0, totalStaked back to
        // baseline). The tokens forwarded to the wallet may be a few wei short of the
        // requested principal: routing through the ERC4626 strategy converts
        // assets->shares->assets and that rounding is, by design, kept protocol-owned
        // (ERC4626YieldStrategy rounds in the protocol's favour; see StableStaker
        // _routeExit). Allow a tiny rounding tolerance rather than exact equality.
        uint256 returned = dolaAfter - dolaBefore;
        uint256 principalDust = STAKE_AMOUNT - returned; // >= 0 (never over-pays)
        console.log("Principal returned to wallet:", returned);
        console.log("Rounding dust retained by strategy (wei):", principalDust);
        require(returned <= STAKE_AMOUNT, "strategy over-paid principal");
        require(principalDust <= 10, "principal returned short by more than rounding dust");
        require(totalStakedFinal == baseline, "pool totalStaked did not return to baseline");

        console.log("\n========================================");
        console.log("   FINAL RESULTS");
        console.log("========================================");
        console.log("phUSD reward (~10/day expected):", rewardCredited);
        console.log("Principal returned (DOLA):", returned);
        console.log("Principal rounding dust kept by strategy (wei):", principalDust);
        console.log("Pool totalStaked baseline restored:", totalStakedFinal);
        console.log("");
        console.log("PASS: stake -> time -> claim -> withdraw verified.");
        console.log("========================================\n");
    }
}
