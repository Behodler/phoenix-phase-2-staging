// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {BalancerHoldingBase} from "./RevokeBalancerPoolersHoldingPattern.s.sol";

/**
 * @title VerifyBalancerHolding  (story 099, sprint Balancexit)
 * @notice READ-ONLY verifier for the Balancer holding pattern: no --broadcast, no --sender, no prank/deal.
 *         Reads LIVE BalancerPoolerV2 0x7f68...11F1 and require()s that all four formerly authorized poolers fail the
 *         `onlyAuthorizedPooler` predicate (poolerAuthVersion[p] == authVersion). Fails with
 *         "verify: pooler still authorized" until `balancer-holding:broadcast` has landed.
 *
 * Usage: npm run balancer-holding:verify
 */
contract VerifyBalancerHolding is BalancerHoldingBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY BALANCER HOLDING PATTERN (story 099)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        _logPoolers();
        address[4] memory ps = poolers();
        for (uint256 i = 0; i < 4; i++) {
            if (_isAuthorized(ps[i])) console.log("STILL AUTHORIZED:", ps[i]);
        }
        for (uint256 i = 0; i < 4; i++) {
            require(!_isAuthorized(ps[i]), "verify: pooler still authorized");
        }
        console.log("OK: all four poolers unauthorized on chain.");
    }
}
