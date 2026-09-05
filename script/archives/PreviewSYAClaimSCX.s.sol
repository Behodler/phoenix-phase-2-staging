// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * PREVIEW ONLY — never broadcast this script.
 *
 * Simulates the deployer claiming on the live StableYieldAccumulator (yield funnel)
 * using the SCX NFT (NFTMinter dispatcher index 2), against a mainnet fork.
 *
 * Run:
 *   forge script script/PreviewSYAClaimSCX.s.sol:PreviewSYAClaimSCX --rpc-url $RPC_MAINNET -vvv
 *
 * Diagnosis context (2026-06-10): the deployed SYA (0x3bbe…7606a) is a pre-story-025
 * build — its claim() calls IYieldStrategy.withdrawFrom(token, minterAddress, yield,
 * claimer), but the story-055 strategies only expose skimSurplus(token, recipient).
 * This preview is expected to show the claim REVERTING on the withdrawFrom call,
 * independent of how much USDC is supplied.
 */
interface ISYA {
    function claim(uint256 nftIndex, uint256 minRewardTokenSupplied, address[] calldata exemptStrategies) external;
    function getYield(address strategy) external view returns (uint256);
    function getTotalYield() external view returns (uint256);
    function getYieldStrategies() external view returns (address[] memory);
    function strategyTokens(address strategy) external view returns (address);
    function getDiscountRate() external view returns (uint256);
    function rewardToken() external view returns (address);
}

interface IStrategyView {
    function totalBalanceOf(address token, address client) external view returns (uint256);
    function principalOf(address token, address client) external view returns (uint256);
    function getAuthorizedClients() external view returns (address[] memory);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function symbol() external view returns (string memory);
}

interface IERC1155Like {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

contract PreviewSYAClaimSCX is Script {
    // Default: the original (pre-story-025) SYA this diagnosis was written against.
    // After ReplaceSYAMainnet runs, re-run with SYA_ADDRESS=<new SYA> to verify the fix.
    address constant DEFAULT_SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant DEPLOYER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 constant SCX_NFT_INDEX = 2; // BurnerSCX dispatcher config in NFTMinter

    function run() external {
        require(block.chainid == 1, "preview must run against a mainnet fork");

        address syaAddr = vm.envOr("SYA_ADDRESS", DEFAULT_SYA);
        console.log("Target SYA:", syaAddr);
        ISYA sya = ISYA(syaAddr);
        address[] memory strategies = sya.getYieldStrategies();

        console.log("=== Pre-claim state ===");
        console.log("Deployer:", DEPLOYER);
        console.log("SCX NFT (index 2) balance:", IERC1155Like(NFT_MINTER).balanceOf(DEPLOYER, SCX_NFT_INDEX));
        console.log("Deployer USDC balance:", IERC20Like(USDC).balanceOf(DEPLOYER));
        console.log("Discount rate (bps):", sya.getDiscountRate());

        // Per-strategy view: what SYA *thinks* is pending vs the true all-client surplus
        uint256 trueTotalSurplus18; // all strategies are 18-decimal except USDC; logged per-strategy below
        for (uint256 i = 0; i < strategies.length; i++) {
            address strat = strategies[i];
            address token = sya.strategyTokens(strat);
            console.log("--- strategy:", strat);
            console.log("    token:", token);
            console.log("    SYA.getYield (minter-only on deployed build):", sya.getYield(strat));

            address[] memory clients = IStrategyView(strat).getAuthorizedClients();
            for (uint256 j = 0; j < clients.length; j++) {
                uint256 tb = IStrategyView(strat).totalBalanceOf(token, clients[j]);
                uint256 pr = IStrategyView(strat).principalOf(token, clients[j]);
                uint256 surplus = tb > pr ? tb - pr : 0;
                console.log("    client:", clients[j]);
                console.log("      surplus:", surplus);
                trueTotalSurplus18 += surplus;
            }
        }
        console.log("True all-client surplus (raw sum, mixed decimals):", trueTotalSurplus18);

        // Attempt the claim as the deployer with an effectively unlimited USDC approval,
        // proving the failure is NOT an approval/amount problem.
        vm.startPrank(DEPLOYER);
        IERC20Like(USDC).approve(syaAddr, type(uint256).max);
        address[] memory noExemptions = new address[](0);
        try sya.claim(SCX_NFT_INDEX, 0, noExemptions) {
            console.log("=== CLAIM SUCCEEDED ===");
            console.log("Deployer USDC after:", IERC20Like(USDC).balanceOf(DEPLOYER));
        } catch Error(string memory reason) {
            console.log("=== CLAIM REVERTED (string) ===");
            console.log(reason);
        } catch (bytes memory data) {
            console.log("=== CLAIM REVERTED (raw) ===");
            console.logBytes(data);
        }
        vm.stopPrank();
    }
}
