// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@phUSD-stable-minter/PhusdStableMinter.sol";

interface IYieldStrategyQuery {
    function principalOf(address token, address account) external view returns (uint256);
    function totalBalanceOf(address token, address account) external view returns (uint256);
}

/**
 * @title NoMintDeposit
 * @notice Script to deposit DOLA into PhusdStableMinter via noMintDeposit (seeding)
 * @dev Deposits the caller's entire DOLA balance without minting phUSD
 *      Hardcoded for mainnet deployment
 */
contract NoMintDeposit is Script {
    // Mainnet addresses from progress.1.json
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant AUTO_DOLA_YIELD_STRATEGY = 0x01d34d7EF3988C5b981ee06bF0Ba4485Bd8eA20C;

    // Mainnet DOLA token
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;

    // Expected caller address (Ledger index 46)
    address public constant EXPECTED_CALLER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        // For Ledger signing, we use EXPECTED_CALLER as the signer
        // msg.sender before vm.startBroadcast() is NOT the Ledger address
        address caller = EXPECTED_CALLER;

        // Get caller's entire DOLA balance
        uint256 dolaBalance = IERC20(DOLA).balanceOf(caller);

        // Query current state of YieldStrategy for minter
        IYieldStrategyQuery ys = IYieldStrategyQuery(AUTO_DOLA_YIELD_STRATEGY);
        uint256 principalBefore = ys.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 totalBalanceBefore = ys.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);

        console.log("\n=== NoMintDeposit (Mainnet) ===");
        console.log("Caller:", caller);
        console.log("PhusdStableMinter:", PHUSD_STABLE_MINTER);
        console.log("AutoDolaYieldStrategy:", AUTO_DOLA_YIELD_STRATEGY);
        console.log("DOLA token:", DOLA);
        console.log("");
        console.log("--- Caller DOLA Balance ---");
        console.log("DOLA balance to deposit (wei):", dolaBalance);
        console.log("DOLA balance to deposit:", dolaBalance / 1e18, "DOLA");
        console.log("");
        console.log("--- YieldStrategy State BEFORE ---");
        console.log("Minter principal (wei):", principalBefore);
        console.log("Minter principal:", principalBefore / 1e18, "DOLA");
        console.log("Minter totalBalance (wei):", totalBalanceBefore);
        console.log("Minter totalBalance:", totalBalanceBefore / 1e18, "DOLA");
        console.log("");
        console.log("--- Expected State AFTER ---");
        console.log("Expected minter principal:", (principalBefore + dolaBalance) / 1e18, "DOLA");
        console.log("Expected minter totalBalance:", (totalBalanceBefore + dolaBalance) / 1e18, "DOLA");

        require(dolaBalance > 0, "No DOLA balance to deposit");

        vm.startBroadcast();

        // Step 1: Approve DOLA for minter
        IERC20(DOLA).approve(PHUSD_STABLE_MINTER, dolaBalance);
        console.log("");
        console.log("Approved DOLA for minter");

        // Step 2: Call noMintDeposit
        PhusdStableMinter(PHUSD_STABLE_MINTER).noMintDeposit(
            AUTO_DOLA_YIELD_STRATEGY,
            DOLA,
            dolaBalance
        );
        console.log("noMintDeposit executed successfully");

        vm.stopBroadcast();

        // Query state after (will show expected values in dry run)
        uint256 principalAfter = ys.principalOf(DOLA, PHUSD_STABLE_MINTER);
        uint256 totalBalanceAfter = ys.totalBalanceOf(DOLA, PHUSD_STABLE_MINTER);

        console.log("");
        console.log("--- YieldStrategy State AFTER ---");
        console.log("Minter principal (wei):", principalAfter);
        console.log("Minter principal:", principalAfter / 1e18, "DOLA");
        console.log("Minter totalBalance (wei):", totalBalanceAfter);
        console.log("Minter totalBalance:", totalBalanceAfter / 1e18, "DOLA");
        console.log("");
        console.log("--- Changes ---");
        console.log("Principal increased by:", (principalAfter - principalBefore) / 1e18, "DOLA");
        console.log("TotalBalance increased by:", (totalBalanceAfter - totalBalanceBefore) / 1e18, "DOLA");

        console.log("\n=== NoMintDeposit Complete ===\n");
    }
}
