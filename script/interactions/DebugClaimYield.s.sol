// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "vault/interfaces/IYieldStrategy.sol";

interface INFTMinterView {
    function nextIndex() external view returns (uint256);
    function getPrice(uint256 index) external view returns (uint256);
}

/**
 * @title DebugClaimYield
 * @notice Diagnostic script to debug a failed yield claim on StableYieldAccumulator (mainnet)
 * @dev Reads all relevant on-chain state and then attempts claim() via vm.prank
 *      to surface the exact revert reason.
 *
 * Usage (dry-run on mainnet fork):
 *   forge script script/interactions/DebugClaimYield.s.sol:DebugClaimYield \
 *       --rpc-url $RPC_MAINNET --sender 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28 -vvvv
 */
contract DebugClaimYield is Script {
    // Mainnet addresses
    address constant ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant USDC        = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CALLER      = 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28;

    function run() external view {
        StableYieldAccumulator acc = StableYieldAccumulator(ACCUMULATOR);

        console.log("\n============================================");
        console.log("  DEBUG CLAIM YIELD (Mainnet Fork)");
        console.log("============================================\n");
        console.log("Caller:      ", CALLER);
        console.log("Accumulator: ", ACCUMULATOR);
        console.log("Chain ID:    ", block.chainid);

        // ---- 1. Contract configuration ----
        console.log("\n--- 1. Accumulator Config ---");
        address rewardToken = acc.rewardToken();
        address minter = acc.minterAddress();
        address phlimbo = acc.phlimbo();
        address nftMinterAddr = acc.nftMinter();
        uint256 discount = acc.discountRate();
        bool isPaused = acc.paused();

        console.log("Reward token:  ", rewardToken);
        console.log("Minter:        ", minter);
        console.log("Phlimbo:       ", phlimbo);
        console.log("NFT Minter:    ", nftMinterAddr);
        console.log("Discount (bps):", discount);
        console.log("Paused:        ", isPaused);

        // Check zero-address guards
        if (phlimbo == address(0)) console.log("!! FAIL: phlimbo is zero address");
        if (rewardToken == address(0)) console.log("!! FAIL: rewardToken is zero address");
        if (minter == address(0)) console.log("!! FAIL: minterAddress is zero address");
        if (nftMinterAddr == address(0)) console.log("!! FAIL: nftMinter is zero address");

        // ---- 2. NFT state ----
        console.log("\n--- 2. NFT Holdings ---");
        if (nftMinterAddr != address(0)) {
            INFTMinterView nftMinter = INFTMinterView(nftMinterAddr);
            uint256 nextIdx = nftMinter.nextIndex();
            console.log("NFTMinter nextIndex:", nextIdx);

            bool hasAnyNFT = false;
            for (uint256 i = 1; i < nextIdx; i++) {
                uint256 bal = IERC1155(nftMinterAddr).balanceOf(CALLER, i);
                if (bal > 0) {
                    console.log("  Token ID", i, "balance:", bal);
                    hasAnyNFT = true;
                }
            }
            if (!hasAnyNFT) {
                console.log("!! FAIL: Caller holds NO NFTs from NFTMinter");
            }

            // Also check canClaim
            bool can = acc.canClaim(CALLER);
            console.log("canClaim(caller):", can);
        }

        // ---- 3. Yield strategies ----
        console.log("\n--- 3. Yield Strategies ---");
        address[] memory strategies = acc.getYieldStrategies();
        console.log("Registered strategies:", strategies.length);

        for (uint256 i = 0; i < strategies.length; i++) {
            address strategy = strategies[i];
            address token = acc.strategyTokens(strategy);
            console.log("\n  Strategy", i, ":", strategy);
            console.log("    Token:", token);

            // Token config
            IStableYieldAccumulator.TokenConfig memory tc = acc.getTokenConfig(token);
            console.log("    Decimals:", tc.decimals);
            console.log("    Exchange rate:", tc.normalizedExchangeRate);
            console.log("    Token paused:", tc.paused);

            if (token != address(0) && !tc.paused) {
                IYieldStrategy ys = IYieldStrategy(strategy);
                uint256 totalBal = ys.totalBalanceOf(token, minter);
                uint256 principal = ys.principalOf(token, minter);
                uint256 yieldAmt = totalBal > principal ? totalBal - principal : 0;

                console.log("    totalBalanceOf(minter):", totalBal);
                console.log("    principalOf(minter):   ", principal);
                console.log("    Yield (native):        ", yieldAmt);

                // Try to get normalized yield via accumulator view
                uint256 stratYield = acc.getYield(strategy);
                console.log("    getYield() (native):   ", stratYield);
            }
        }

        // Overall totals
        uint256 totalYield = acc.getTotalYield();
        console.log("\n  getTotalYield() (18 dec):", totalYield);

        uint256 claimAmount = acc.calculateClaimAmount();
        console.log("  calculateClaimAmount():  ", claimAmount);
        if (claimAmount > 0) {
            console.log("  (claim payment ~", claimAmount / 1e6, "USDC)");
        }

        if (totalYield == 0) {
            console.log("!! FAIL: No yield available to claim (ZeroAmount revert)");
        }

        // ---- 4. Caller's USDC state ----
        console.log("\n--- 4. Caller USDC State ---");
        uint256 usdcBal = IERC20(USDC).balanceOf(CALLER);
        uint256 usdcAllowance = IERC20(USDC).allowance(CALLER, ACCUMULATOR);
        console.log("USDC balance:   ", usdcBal);
        console.log("  (~", usdcBal / 1e6, "USDC)");
        console.log("USDC allowance to accumulator:", usdcAllowance);
        console.log("  (~", usdcAllowance / 1e6, "USDC)");

        if (claimAmount > 0) {
            if (usdcBal < claimAmount) {
                console.log("!! FAIL: Insufficient USDC balance. Need", claimAmount, "have", usdcBal);
            }
            if (usdcAllowance < claimAmount) {
                console.log("!! FAIL: Insufficient USDC allowance. Need", claimAmount, "have", usdcAllowance);
            }
        }

        // ---- 5. Phlimbo USDC allowance from accumulator ----
        console.log("\n--- 5. Accumulator -> Phlimbo Approval ---");
        uint256 accToPhlimbo = IERC20(USDC).allowance(ACCUMULATOR, phlimbo);
        console.log("Accumulator USDC allowance to Phlimbo:", accToPhlimbo);
        if (claimAmount > 0 && accToPhlimbo < claimAmount) {
            console.log("!! FAIL: Accumulator has insufficient USDC allowance to Phlimbo");
        }

        // ---- 6. Summary ----
        console.log("\n============================================");
        console.log("  DIAGNOSIS SUMMARY");
        console.log("============================================");
        if (isPaused) console.log("BLOCKED: Contract is paused");
        if (nftMinterAddr == address(0)) console.log("BLOCKED: NFT minter not set");
        if (totalYield == 0) console.log("BLOCKED: Zero yield across all strategies");
        if (claimAmount > usdcBal) console.log("BLOCKED: Insufficient USDC balance");
        if (claimAmount > usdcAllowance) console.log("BLOCKED: Insufficient USDC allowance to accumulator");
        if (accToPhlimbo < claimAmount) console.log("BLOCKED: Accumulator->Phlimbo allowance too low");

        console.log("\nDone. Review above for !! FAIL markers.\n");
    }
}

/**
 * @title DebugClaimYieldSim
 * @notice Actually attempts claim() on a mainnet fork to surface the exact revert reason
 * @dev Usage:
 *   forge script script/interactions/DebugClaimYield.s.sol:DebugClaimYieldSim \
 *       --rpc-url $RPC_MAINNET --sender 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28 -vvvv
 */
contract DebugClaimYieldSim is Script {
    address constant ACCUMULATOR = 0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E;
    address constant CALLER      = 0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28;

    function run() external {
        StableYieldAccumulator acc = StableYieldAccumulator(ACCUMULATOR);

        // NFT token ID 5 (found in diagnostic)
        uint256 nftIndex = 5;

        console.log("\n=== Simulating claim(nftIndex=%d, minReward=0) ===", nftIndex);
        console.log("Caller:", CALLER);

        vm.startBroadcast(CALLER);
        acc.claim(nftIndex, 0);
        vm.stopBroadcast();

        console.log("Claim succeeded!");
    }
}
