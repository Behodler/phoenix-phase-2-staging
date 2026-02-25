// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter} from "./BalancerECLPInterfaces.sol";

/**
 * @title InitializeBalancerECLPPool
 * @notice Seeds the already-deployed Balancer V3 Gyro E-CLP phUSD/sUSDS pool
 *         with initial liquidity.  All approvals (ERC20 → Permit2, Permit2 → Router)
 *         are already in place from the original CreateBalancerECLPPool run.
 *
 * @dev    Pool:   0x253f4a0307dd7f07ea7e743ed92eb4814b07c065
 *         Ledger index: 44  (HD path m/44'/60'/44'/0/0)
 */
contract InitializeBalancerECLPPool is Script {
    address public constant POOL   = 0x253F4A0307dD7F07eA7e743Ed92Eb4814b07c065;
    address public constant PHUSD  = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant SUSDS  = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant ROUTER = 0xAE563E3f8219521950555F5962419C8919758Ea2;

    uint256 internal constant SEED_SUSDS = 20000000000000000000;  // 20 sUSDS
    uint256 internal constant SEED_PHUSD = 21754000000000000000;  // ~21.754 phUSD

    function run() external {
        console.log("\n=== Initialize Balancer E-CLP Pool: phUSD/sUSDS ===");
        console.log("Pool:   ", POOL);
        console.log("Router: ", ROUTER);
        console.log("Seed sUSDS (wei):", SEED_SUSDS);
        console.log("Seed phUSD (wei):", SEED_PHUSD);
        console.log("");

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(SUSDS);
        tokens[1] = IERC20(PHUSD);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SEED_SUSDS;
        amounts[1] = SEED_PHUSD;

        vm.startBroadcast();

        console.log("Initializing pool with seed liquidity...");
        uint256 bptOut = IRouter(ROUTER).initialize(
            POOL,
            tokens,
            amounts,
            0,       // minBptAmountOut — accept any amount for seeding
            false,   // wethIsEth
            ""       // userData
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Pool Initialization Complete ===");
        console.log("BPT received:", bptOut);
        console.log("\n");
    }
}
