// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

interface ISetMinter {
    function setMinter(address) external;
    function owner() external view returns (address);
}

/// @notice Story-047 fix: the new BalancerPoolerV2 (dispatcher index 6 on the
///         live NFTMinterV2) was deployed and registered, but its `_minter`
///         field was never wired, so every mint reverts with
///         "ATokenDispatcherV2: caller is not minter". This script calls
///         setMinter(NFTMinterV2) on the new pooler.
contract FixBalancerPoolerV2SetMinter is Script {
    address constant NEW_POOLER     = 0x4da153dc02bB084528D10335759f2C4447e6f73d;
    address constant NFT_MINTER_V2  = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address constant OWNER_ADDRESS  = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");

        address poolerOwner = ISetMinter(NEW_POOLER).owner();
        console.log("BalancerPoolerV2:", NEW_POOLER);
        console.log("Pooler owner:    ", poolerOwner);
        console.log("Expected owner:  ", OWNER_ADDRESS);
        console.log("NFTMinterV2:     ", NFT_MINTER_V2);
        require(poolerOwner == OWNER_ADDRESS, "Pooler owner mismatch");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        ISetMinter(NEW_POOLER).setMinter(NFT_MINTER_V2);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("setMinter(NFTMinterV2) submitted.");
    }
}
