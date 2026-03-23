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
}

interface IMinterPausable {
    function setPauser(address newPauser) external;
    function pause() external;
    function unpause() external;
    function withdraw(address yieldStrategy, address recipient) external;
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
        // PHASE 1: Withdraw from old YS
        // ============================================================

        // 1. Swap pauser to owner on old YS and minter
        oldYS.setPauser(msg.sender);
        minter.setPauser(msg.sender);

        // 2. Unpause both (owner is pauser, no EYE burn)
        oldYS.unpause();
        minter.unpause();

        // 3. Withdraw all DOLA from old YS via minter
        uint256 dolaBalanceBefore = IERC20(DOLA).balanceOf(msg.sender);
        minter.withdraw(OLD_YIELD_STRATEGY, msg.sender);
        uint256 totalWithdrawn = IERC20(DOLA).balanceOf(msg.sender) - dolaBalanceBefore;
        console.log("Total withdrawn:            ", totalWithdrawn);

        // 4. Send 6984 DOLA to Balancer LP account
        IERC20(DOLA).transfer(BALANCER_LP_ACCOUNT, EXTRACT_AMOUNT);

        // 5. Pause old YS (owner is pauser). Leave pauser as owner — old YS is discarded.
        oldYS.pause();

        // ============================================================
        // PHASE 2: Deploy and configure new YS
        // ============================================================

        // 6. Deploy new AutoPoolYieldStrategy
        AutoPoolYieldStrategy newYS = new AutoPoolYieldStrategy(
            msg.sender,
            DOLA,
            TOKE,
            AUTO_DOLA_VAULT,
            MAIN_REWARDER
        );
        address newYSAddr = address(newYS);
        console.log("New YS deployed at:         ", newYSAddr);

        // 7. Authorize minter as client on new YS
        IYieldStrategyPausable(newYSAddr).setClient(PHUSD_STABLE_MINTER, true);

        // 8. Register DOLA with new YS on minter (overwrites old mapping)
        minter.registerStablecoin(DOLA, newYSAddr, 1e18, 18);

        // 9. Approve new YS to pull DOLA from minter
        minter.approveYS(DOLA, newYSAddr);

        // 10. Redeposit remainder into new YS via noMintDeposit
        uint256 remainder = totalWithdrawn - EXTRACT_AMOUNT;
        console.log("Remainder to redeposit:     ", remainder);
        IERC20(DOLA).approve(PHUSD_STABLE_MINTER, remainder);
        minter.noMintDeposit(newYSAddr, DOLA, remainder);

        // ============================================================
        // PHASE 3: Accumulator swap
        // ============================================================

        // 11. Remove old YS from accumulator, add new YS
        IAccumulator(ACCUMULATOR).removeYieldStrategy(OLD_YIELD_STRATEGY);
        IAccumulator(ACCUMULATOR).addYieldStrategy(newYSAddr, DOLA);

        // 12. Authorize accumulator as withdrawer on new YS
        IYieldStrategyPausable(newYSAddr).setWithdrawer(ACCUMULATOR, true);

        // ============================================================
        // PHASE 4: Pause and restore pauser state
        // ============================================================

        // 13. Pause new YS (owner is currently pauser by default from constructor)
        IYieldStrategyPausable(newYSAddr).pause();

        // 14. Set new YS pauser to global pauser
        IYieldStrategyPausable(newYSAddr).setPauser(GLOBAL_PAUSER);

        // 15. Pause minter (owner is still pauser from step 1)
        minter.pause();

        // 16. Restore minter pauser to global pauser
        minter.setPauser(originalMinterPauser);

        // ============================================================
        // PHASE 5: Global pauser registration
        // ============================================================

        // 17. Register new YS with global pauser (requires newYS.pauser() == GLOBAL_PAUSER)
        IPauser(GLOBAL_PAUSER).register(newYSAddr);

        // 18. Unregister old YS from global pauser
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
        console.log("TVL decline (old - new):    ", tvlBefore - newTVL);
        console.log("New YS address:             ", newYSAddr);

        // Principal should equal TVL on the new YS (fresh deposit, no yield yet)
        require(newPrincipal == newTVL, "Principal != TVL on fresh YS");

        // TVL decline should be approximately EXTRACT_AMOUNT (within 1 DOLA for rounding)
        uint256 tvlDecline = tvlBefore - newTVL;
        require(tvlDecline >= EXTRACT_AMOUNT - 1 ether, "TVL did not decline enough");
        require(tvlDecline <= EXTRACT_AMOUNT + 1 ether, "TVL declined too much");

        console.log("\n=== VERIFICATION PASSED ===");
        console.log("Old YS left paused and discarded.");
        console.log("Update mainnet-addresses.ts with new YS:", newYSAddr);
        console.log("");
    }
}
