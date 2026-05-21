// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface IPoolerV2 {
    function owner() external view returns (address);
    function authVersion() external view returns (uint256);
    function poolerAuthVersion(address) external view returns (uint256);
    function setAuthorizedPooler(address pooler, bool authorized) external;
}

/// @notice Authorizes the pooler-V2 owner (0xCad1a7…) as a pooler so the
///         owner ledger can call `pool(minBPT, minUSDC)` directly. The
///         onlyAuthorizedPooler modifier checks
///         `poolerAuthVersion[msg.sender] == authVersion`, which is 0 → 1
///         after this call.
contract AuthorizeOwnerAsPoolerV2 is Script {
    address constant POOLER       = 0x4da153dc02bB084528D10335759f2C4447e6f73d;
    address constant OWNER_TARGET = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");

        IPoolerV2 pooler = IPoolerV2(POOLER);

        address poolerOwner = pooler.owner();
        uint256 currentAuthVersion = pooler.authVersion();
        uint256 priorTargetVersion = pooler.poolerAuthVersion(OWNER_TARGET);

        console.log("BalancerPoolerV2:                ", POOLER);
        console.log("Pooler owner:                    ", poolerOwner);
        console.log("Authorizing address:             ", OWNER_TARGET);
        console.log("Current authVersion:             ", currentAuthVersion);
        console.log("Target's prior poolerAuthVersion:", priorTargetVersion);

        require(poolerOwner == OWNER_TARGET, "Pooler owner != target - setAuthorizedPooler requires owner signer");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner ***");
            vm.startPrank(OWNER_TARGET);
        } else {
            vm.startBroadcast();
        }

        pooler.setAuthorizedPooler(OWNER_TARGET, true);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("setAuthorizedPooler submitted.");
    }
}
