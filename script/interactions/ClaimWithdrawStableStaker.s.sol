// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";

/**
 * @title ClaimWithdrawStableStaker
 * @notice Second half of the story-051 StableStaker config verification: after a day
 *         of elapsed time (advanced out-of-band via `cast rpc evm_increaseTime`), read
 *         the accrued reward, withdraw the full principal, and assert:
 *           - reward accrued ~= the DOLA pool's daily rate (10 Antimatter) within
 *             tolerance for the extra elapsed seconds;
 *           - the staked DOLA principal is fully returned;
 *           - the pool's totalStaked returns to its pre-stake baseline.
 * @dev Story 051, retargeted onto StableStakerV2 by story 080. TWO THINGS CHANGED WITH THE
 *      VERSION, and both are asserted rather than assumed:
 *        1. The reward token is ANTIMATTER, not phUSD. V2 is a reward-token pivot, not an added
 *           reward, so the old "deployer's phUSD balance rose by ~10" check would now measure a
 *           balance nothing credits.
 *        2. `claim` is CLOSED. `claimEnabled` starts false and the deploy deliberately leaves it
 *           false — the teaching phase steers users to `autoAnnihilate` instead — so calling
 *           `claim` here would revert "StableStaker: claim disabled". The reward leg therefore
 *           asserts the ACCRUAL (`claimableReward`) and that the closed door is really closed,
 *           and the withdraw leg asserts that withdrawing banks the accrual into
 *           `unclaimedReward` rather than forfeiting it.
 *      Companion to StakeStableStaker.s.sol. Modelled on
 *      ClaimPhlimboRewards.s.sol / TestNudgePayout.s.sol (AddressLoader-style address
 *      resolution from progress.31337.json).
 *
 *      Run AFTER StakeStableStaker + `cast rpc evm_increaseTime 86400` + `evm_mine`.
 */
contract ClaimWithdrawStableStaker is Script {
    uint256 constant STAKE_AMOUNT = 1_000 * 10 ** 18; // must match StakeStableStaker
    uint256 constant EXPECTED_DAILY_REWARD = 10 * 10 ** 18; // DOLA pool = 10 Antimatter/day

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n========================================");
        console.log("   STABLE STAKER VERIFY - CLAIM+WITHDRAW");
        console.log("========================================\n");
        console.log("Deployer:", deployer);

        // --- Load addresses ---
        string memory progressJson = vm.readFile("server/deployments/progress.31337.json");
        address stakerAddr = vm.parseJsonAddress(progressJson, ".contracts.StableStakerV2.address");
        address dolaAddr = vm.parseJsonAddress(progressJson, ".contracts.MockDola.address");
        address antimatterAddr = vm.parseJsonAddress(progressJson, ".contracts.Antimatter.address");

        console.log("StableStakerV2:", stakerAddr);
        console.log("MockDola:", dolaAddr);
        console.log("Antimatter:", antimatterAddr);

        StableStakerV2 staker = StableStakerV2(stakerAddr);
        IERC20 dola = IERC20(dolaAddr);
        IERC20 antimatter = IERC20(antimatterAddr);

        // --- Baseline: pool totalStaked before our stake was our CREDITED principal less ---
        // STORY 080: read the credited principal rather than assuming it equals STAKE_AMOUNT.
        // The pool is not empty when this flow runs (the cutover rehearsal leaves 12 migrated
        // positions in it), so the deposit's ERC4626 round trip can credit a wei or two less
        // than requested — and withdrawing STAKE_AMOUNT would then revert "insufficient stake".
        (uint256 stakedPrincipal,) = staker.userInfo(dolaAddr, deployer);
        require(stakedPrincipal > 0, "no staked position - run StakeStableStaker first");
        uint256 principalDrift =
            stakedPrincipal > STAKE_AMOUNT ? stakedPrincipal - STAKE_AMOUNT : STAKE_AMOUNT - stakedPrincipal;
        require(principalDrift <= STAKE_AMOUNT / 1000, "staked principal is not the one StakeStableStaker created");
        (,,, uint256 totalStakedNow) = staker.poolInfo(dolaAddr);
        uint256 baseline = totalStakedNow - stakedPrincipal; // pre-stake baseline
        console.log("\n--- Pre-exit state ---");
        console.log("DOLA pool totalStaked (incl. our stake):", totalStakedNow);
        console.log("Derived pre-stake baseline:", baseline);

        uint256 accrued = staker.claimableReward(dolaAddr, deployer);
        uint256 antimatterBefore = antimatter.balanceOf(deployer);
        uint256 dolaBefore = dola.balanceOf(deployer);
        console.log("claimableReward (Antimatter):", accrued);
        console.log("Deployer Antimatter before:", antimatterBefore);
        console.log("Deployer DOLA before:", dolaBefore);
        require(accrued > 0, "no reward accrued - did time advance via evm_increaseTime?");

        // STORY 080: the expected figure is now the caller's PRO-RATA share of the pool's daily
        // emission, not the whole 10/day. The DOLA pool is no longer exclusively this flow's —
        // the cutover rehearsal leaves 12 migrated positions in it — and a MasterChef emission is
        // split across `totalStaked`. Asserting the flat 10/day here would fail against the real
        // deployment for the wrong reason, and asserting nothing would let a genuinely broken
        // rate through.
        uint256 expected = (EXPECTED_DAILY_REWARD * stakedPrincipal) / totalStakedNow;
        console.log("Expected pro-rata daily reward (Antimatter):", expected);
        uint256 lowerBound = expected - (expected / 100);
        uint256 upperBound = expected + (expected / 100);
        require(accrued >= lowerBound, "reward below the pro-rata daily lower bound");
        require(accrued <= upperBound, "reward above the pro-rata daily upper bound");
        console.log("Reward within +/-1% of the pro-rata daily emission: OK");

        // --- The closed door is really closed ---
        // `claimEnabled` is false by deployment and the deploy script deliberately never opens
        // it, so no Antimatter can be minted through `claim` during the teaching phase. A silent
        // regression here (someone enabling claims in DeployMocks) would otherwise go unnoticed
        // until it changed the reward the UI shows.
        require(!staker.claimEnabled(), "claimEnabled is TRUE - the teaching phase has been broken");
        console.log("claimEnabled is false: OK (reward path under test is autoAnnihilate)");

        // --- Withdraw full principal ---
        console.log("\n--- withdraw(DOLA, credited principal) ---");
        vm.startBroadcast(deployerPrivateKey);
        staker.withdraw(dolaAddr, stakedPrincipal);
        vm.stopBroadcast();

        uint256 dolaAfter = dola.balanceOf(deployer);
        (uint256 userAmount,) = staker.userInfo(dolaAddr, deployer);
        // Withdrawing does NOT forfeit the accrual: `withdraw` settles pending into the
        // `unclaimedReward` backlog, which `claimableReward` keeps reporting for a caller with no
        // position left. Assert the backlog is at least what had accrued before the exit.
        uint256 backlog = staker.claimableReward(dolaAddr, deployer);
        require(backlog >= accrued, "withdraw forfeited the accrued Antimatter backlog");
        require(
            antimatter.balanceOf(deployer) == antimatterBefore, "Antimatter was minted despite claims being disabled"
        );
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
        uint256 principalDust = stakedPrincipal - returned; // >= 0 (never over-pays)
        console.log("Principal returned to wallet:", returned);
        console.log("Rounding dust retained by strategy (wei):", principalDust);
        require(returned <= stakedPrincipal, "strategy over-paid principal");
        // Story 080: 0.1%, matching the deposit-leg band. The exit routes through a strategy that
        // is carrying other clients' principal, so the shortfall is share rounding rather than
        // the couple of wei an exclusive pool produced.
        require(principalDust <= stakedPrincipal / 1000, "principal returned short by more than 0.1%");
        require(totalStakedFinal == baseline, "pool totalStaked did not return to baseline");

        console.log("\n========================================");
        console.log("   FINAL RESULTS");
        console.log("========================================");
        console.log("Antimatter reward accrued (pro-rata share of 10/day):", accrued);
        console.log("Unclaimable backlog after withdraw (Antimatter):", backlog);
        console.log("Principal returned (DOLA):", returned);
        console.log("Principal rounding dust kept by strategy (wei):", principalDust);
        console.log("Pool totalStaked baseline restored:", totalStakedFinal);
        console.log("");
        console.log("PASS: stake -> time -> accrue -> withdraw verified on StableStakerV2.");
        console.log("========================================\n");
    }
}
