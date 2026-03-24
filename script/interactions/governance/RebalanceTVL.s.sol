// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AutoPoolYieldStrategy} from "@vault/concreteYieldStrategies/AutoPoolYieldStrategy.sol";

interface IYieldStrategyPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
    function totalBalanceOf(address token, address account) external view returns (uint256);
    function principalOf(address token, address account) external view returns (uint256);
    function setClient(address client, bool _auth) external;
    function setWithdrawer(address withdrawer, bool _auth) external;
    function emergencyWithdraw(uint256 amount) external;
}

interface IMinterPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function noMintDeposit(address yieldStrategy, address inputToken, uint256 amount) external;
    function approveYS(address token, address yieldStrategy) external;
    function registerStablecoin(address stablecoin, address yieldStrategy, uint256 exchangeRate, uint8 decimals) external;
    function pauser() external view returns (address);
}

interface IAccumulator {
    function addYieldStrategy(address strategy, address token) external;
    function removeYieldStrategy(address strategy) external;
}

interface IPauser {
    function register(address pausableContract) external;
    function unregister(address pausableContract) external;
}

/**
 * @title RebalanceTVL
 * @notice Extracts 6984 DOLA from the Dola AutoPoolYieldStrategy, deploys a fresh
 *         YieldStrategy with clean accounting, and redeposits the remainder.
 *
 *         Steps:
 *         1. Temporarily swap pauser to owner on old YS + minter (avoids 1000 EYE burn)
 *         2. Unpause old YS + minter
 *         3. Withdraw all DOLA from old YS via minter
 *         4. Send 6984 DOLA to Balancer LP account
 *         5. Deploy new AutoPoolYieldStrategy
 *         6. Configure new YS (client, pauser, accumulator, etc.)
 *         7. Redeposit remainder into new YS via noMintDeposit
 *         8. Pause new YS + minter, restore pausers
 *         9. Register new YS with global pauser, unregister old YS
 *
 *         Old YS is left paused with owner as pauser (discarded).
 */
contract RebalanceTVL is Script {
    // Existing contracts
    address constant OLD_YIELD_STRATEGY  = 0x01d34d7EF3988C5b981ee06bF0Ba4485Bd8eA20C;
    address constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address constant GLOBAL_PAUSER       = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address constant ACCUMULATOR         = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;

    // AutoPoolYieldStrategy constructor args (same as original deployment)
    address constant DOLA             = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant TOKE             = 0x2e9d63788249371f1DFC918a52f8d799F4a38C94;
    address constant AUTO_DOLA_VAULT  = 0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d;
    address constant MAIN_REWARDER    = 0xDC39C67b38ecdA8a1974336c89B00F68667c91B7;

    // Accounts
    address constant BALANCER_LP_ACCOUNT = 0x64d3CbAB6100782a7839fC1af791027a2f1908D2;

    // Amount to extract
    uint256 constant EXTRACT_AMOUNT = 6984 ether;

    function run() external {
        IYieldStrategyPausable oldYS = IYieldStrategyPausable(OLD_YIELD_STRATEGY);
        IMinterPausable minter = IMinterPausable(PHUSD_STABLE_MINTER);

        // --- Pre-flight logging ---
        uint256 tvlBefore = oldYS.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 principalBefore = oldYS.principalOf(DOLA, PHUSD_STABLE_MINTER);
        address originalMinterPauser = minter.pauser();

        console.log("\n=== RebalanceTVL Pre-flight ===");
        console.log("Old YS TVL (totalBalanceOf):", tvlBefore);
        console.log("Old YS Principal:           ", principalBefore);
        if (tvlBefore >= principalBefore) {
            console.log("Yield (TVL - Principal):    ", tvlBefore - principalBefore);
        } else {
            console.log("Negative yield (gap):       ", principalBefore - tvlBefore);
        }
        console.log("Extract amount:             ", EXTRACT_AMOUNT);

        require(tvlBefore >= EXTRACT_AMOUNT, "TVL less than extract amount");

        vm.startBroadcast();

        // ============================================================
        // PHASE 1: Emergency withdraw from old YS (bypasses client accounting)
        // ============================================================

        // 1. Swap pauser to owner on old YS (to unpause without EYE burn)
        oldYS.setPauser(msg.sender);

        // 2. Unpause old YS
        oldYS.unpause();

        // 3. Emergency withdraw all DOLA from old YS directly to owner
        //    This bypasses clientBalances lookup — sends to owner() directly
        uint256 dolaBalanceBefore = IERC20(DOLA).balanceOf(msg.sender);
        oldYS.emergencyWithdraw(tvlBefore);
        uint256 totalWithdrawn = IERC20(DOLA).balanceOf(msg.sender) - dolaBalanceBefore;
        console.log("Total withdrawn:            ", totalWithdrawn);

        // 4. Pause old YS (owner is pauser). Leave pauser as owner — old YS is discarded.
        oldYS.pause();

        // 5. Send 6984 DOLA to Balancer LP account
        IERC20(DOLA).transfer(BALANCER_LP_ACCOUNT, EXTRACT_AMOUNT);

        // ============================================================
        // PHASE 2: Deploy and configure new YS
        // ============================================================

        // 6. Swap pauser to owner on minter and unpause (needed for noMintDeposit)
        minter.setPauser(msg.sender);
        minter.unpause();

        // 7. Deploy new AutoPoolYieldStrategy
        AutoPoolYieldStrategy newYS = new AutoPoolYieldStrategy(
            msg.sender,
            DOLA,
            TOKE,
            AUTO_DOLA_VAULT,
            MAIN_REWARDER
        );
        address newYSAddr = address(newYS);
        console.log("New YS deployed at:         ", newYSAddr);

        // 8. Authorize minter as client on new YS
        IYieldStrategyPausable(newYSAddr).setClient(PHUSD_STABLE_MINTER, true);

        // 9. Register DOLA with new YS on minter (overwrites old mapping)
        minter.registerStablecoin(DOLA, newYSAddr, 1e18, 18);

        // 10. Approve new YS to pull DOLA from minter
        minter.approveYS(DOLA, newYSAddr);

        // 11. Redeposit all remaining DOLA into new YS via noMintDeposit
        uint256 remainder = IERC20(DOLA).balanceOf(msg.sender) - dolaBalanceBefore;
        console.log("Remainder to redeposit:     ", remainder);
        IERC20(DOLA).approve(PHUSD_STABLE_MINTER, remainder);
        minter.noMintDeposit(newYSAddr, DOLA, remainder);

        // ============================================================
        // PHASE 3: Accumulator swap
        // ============================================================

        // 12. Remove old YS from accumulator, add new YS
        IAccumulator(ACCUMULATOR).removeYieldStrategy(OLD_YIELD_STRATEGY);
        IAccumulator(ACCUMULATOR).addYieldStrategy(newYSAddr, DOLA);

        // 13. Authorize accumulator as withdrawer on new YS
        IYieldStrategyPausable(newYSAddr).setWithdrawer(ACCUMULATOR, true);

        // ============================================================
        // PHASE 4: Pause and restore pauser state
        // ============================================================

        // 14. Set owner as pauser on new YS (constructor leaves _pauser as address(0))
        IYieldStrategyPausable(newYSAddr).setPauser(msg.sender);

        // 15. Pause new YS
        IYieldStrategyPausable(newYSAddr).pause();

        // 16. Set new YS pauser to global pauser
        IYieldStrategyPausable(newYSAddr).setPauser(GLOBAL_PAUSER);

        // 17. Pause minter (owner is still pauser from step 6)
        minter.pause();

        // 18. Restore minter pauser to global pauser
        minter.setPauser(originalMinterPauser);

        // ============================================================
        // PHASE 5: Global pauser registration
        // ============================================================

        // 18. Register new YS with global pauser (requires newYS.pauser() == GLOBAL_PAUSER)
        IPauser(GLOBAL_PAUSER).register(newYSAddr);

        // 19. Unregister old YS from global pauser
        //     Requires oldYS.pauser() != GLOBAL_PAUSER — satisfied since we set it to owner in step 1
        IPauser(GLOBAL_PAUSER).unregister(OLD_YIELD_STRATEGY);

        vm.stopBroadcast();

        // --- Post-flight verification ---
        uint256 newTVL = IYieldStrategyPausable(newYSAddr).totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 newPrincipal = IYieldStrategyPausable(newYSAddr).principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 balancerLPBalance = IERC20(DOLA).balanceOf(BALANCER_LP_ACCOUNT);

        console.log("\n=== RebalanceTVL Post-flight ===");
        console.log("New YS TVL:                 ", newTVL);
        console.log("New YS Principal:           ", newPrincipal);
        console.log("Balancer LP DOLA balance:   ", balancerLPBalance);
        if (tvlBefore >= newTVL) {
            console.log("TVL decline (old - new):    ", tvlBefore - newTVL);
        } else {
            console.log("TVL increase (new - old):   ", newTVL - tvlBefore);
        }
        console.log("New YS address:             ", newYSAddr);

        // Principal and TVL should be close on the new YS (fresh deposit)
        // Small gap expected: AutoDOLA vault share price can cause TVL < Principal
        // due to rounding in convertToAssets (same negative yield effect as old YS)
        uint256 principalTvlGap = newPrincipal > newTVL ? newPrincipal - newTVL : newTVL - newPrincipal;
        require(principalTvlGap <= 1 ether, "Principal/TVL gap too large on fresh YS");

        // New TVL should be close to old TVL minus extract amount
        // May be slightly higher (absorbed yield) or lower (convertToShares truncation)
        uint256 expectedNewTVL = tvlBefore - EXTRACT_AMOUNT;
        uint256 tvlDiff = newTVL > expectedNewTVL ? newTVL - expectedNewTVL : expectedNewTVL - newTVL;
        require(tvlDiff <= 50 ether, "New TVL deviates too much from expected");

        console.log("\n=== VERIFICATION PASSED ===");
        console.log("Old YS left paused and discarded.");
        console.log("Update mainnet-addresses.ts with new YS:", newYSAddr);
        console.log("");
    }
}
