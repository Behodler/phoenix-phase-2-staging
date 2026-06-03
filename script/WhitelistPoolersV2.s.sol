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

/// @title  WhitelistPoolersV2
/// @notice Authorizes a fixed set of addresses to call `pool(minBPT, minUSDC)`
///         on the live mainnet BalancerPoolerV2.
///
///         BalancerPoolerV2 gates `pool()` with `onlyAuthorizedPooler`, which
///         checks `poolerAuthVersion[msg.sender] == authVersion`
///         (lib/yield-claim-nft/src/V2/dispatchers/BalancerPoolerV2.sol:73-76).
///         `setAuthorizedPooler(pooler, true)` stamps the caller's slot with the
///         current `authVersion`, flipping the check from 0 → authVersion
///         (BalancerPoolerV2.sol:127-136). It is `onlyOwner`, so this script
///         MUST be signed by the pooler owner (0xCad1a7…, ledger HD index 46).
///
///         Note on safety scope: this script authorizes *who may call* pool().
///         The swap-slippage floors (minBPT / minUSDC) are NOT set here — they
///         are passed by the caller at call time on every pool() invocation, so
///         each authorized caller remains responsible for non-zero bounds.
///
///         Dry run (impersonates owner, no broadcast):
///           PREVIEW_MODE=true forge script \
///             script/WhitelistPoolersV2.s.sol:WhitelistPoolersV2 \
///             --rpc-url $RPC_MAINNET -vvv
///
///         Broadcast (owner ledger, HD index 46):
///           forge script script/WhitelistPoolersV2.s.sol:WhitelistPoolersV2 \
///             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
///             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
contract WhitelistPoolersV2 is Script {
    // Canonical live mainnet BalancerPoolerV2 (dispatcher index 4).
    // Source: server/deployments/mainnet-addresses.ts -> nftsV2.BalancerPooler.
    address constant POOLER = 0x26F89f4B46eB164303985795ee20b15BB1Edb38A;

    // Pooler owner / required signer for the onlyOwner setAuthorizedPooler call.
    // Source: server/deployments/mainnet-addresses.ts (ledger HD index 46).
    address constant OWNER_TARGET = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        // --- Hard environment gate: this is a mainnet-only operation. ---
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");

        // Addresses to authorize as poolers. Supplied explicitly by the operator
        // for this run; do NOT add or substitute addresses without sign-off.
        address[3] memory poolers = [
            0x186c77B80Bbfd21b01C7D7FA44bA27031322a77F,
            0x630966B668b321Cc6441754f96519a55F72Cd476,
            0x3E9003DA2ad56A7cc677b6b414AD475A0231Eb28
        ];

        IPoolerV2 pooler = IPoolerV2(POOLER);

        address poolerOwner = pooler.owner();
        uint256 currentAuthVersion = pooler.authVersion();

        console.log("BalancerPoolerV2:    ", POOLER);
        console.log("Pooler owner:        ", poolerOwner);
        console.log("Current authVersion: ", currentAuthVersion);

        // Safety: setAuthorizedPooler is onlyOwner, so the signer must be owner.
        require(
            poolerOwner == OWNER_TARGET,
            "Pooler owner != expected signer - setAuthorizedPooler requires owner"
        );
        // Safety: a zero authVersion would mean the contract is uninitialized /
        // wrong address; authorizing against it would be meaningless.
        require(currentAuthVersion > 0, "authVersion is 0 - unexpected pooler state");

        // Safety: reject zero-address entries before broadcasting (the contract
        // also reverts, but fail fast / loud here per Configuration Safety gate).
        for (uint256 i = 0; i < poolers.length; i++) {
            require(poolers[i] != address(0), "zero pooler in whitelist set");
        }

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            vm.startPrank(OWNER_TARGET);
        } else {
            vm.startBroadcast();
        }

        for (uint256 i = 0; i < poolers.length; i++) {
            uint256 prior = pooler.poolerAuthVersion(poolers[i]);
            if (prior == currentAuthVersion) {
                console.log("Already authorized, skipping:", poolers[i]);
                continue;
            }
            pooler.setAuthorizedPooler(poolers[i], true);
            console.log("Authorized pooler:           ", poolers[i]);
        }

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // --- Post-conditions: every target must now match authVersion. ---
        for (uint256 i = 0; i < poolers.length; i++) {
            require(
                pooler.poolerAuthVersion(poolers[i]) == currentAuthVersion,
                "Post-check failed: pooler not authorized at current authVersion"
            );
        }

        console.log("All poolers authorized at authVersion:", currentAuthVersion);
    }
}
