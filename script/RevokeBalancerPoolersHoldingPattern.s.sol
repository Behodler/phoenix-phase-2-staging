// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title RevokeBalancerPoolersHoldingPattern  (story 099, sprint Balancexit)
 * @notice Holding pattern until the Balancer exit cutover (docs/BalancerWinddownPlan.md section 4).
 *         ONE owner transaction, `BalancerPoolerV2.incrementAuthVersion()` on the live pooler
 *         0x7f6874332c4629429d70D15f685A8230323F11F1, revokes all four authorized poolers at once:
 *           - OWNER        0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 *           - MultiPooler  0xd1E5774159381915f5579dFd68507E2614f67b51
 *           - 0x186c77B80Bbfd21b01C7D7FA44bA27031322a77F (7702-delegated EOA, WhitelistPoolersV2)
 *           - 0x630966B668b321Cc6441754f96519a55F72Cd476 (EOA, WhitelistPoolersV2)
 *         After it, nobody can call `pool(minBPT)` and push sUSDS into the dying Balancer pool. Mints are unaffected:
 *         `dispatch` is `onlyMinter` and does not consult pooler auth; sUSDS simply accumulates on the pooler.
 *
 *         AUTH MODEL (lib/yield-claim-nft/src/dispatchers/BalancerPoolerV2.sol): `onlyAuthorizedPooler` is
 *         `require(poolerAuthVersion[msg.sender] == authVersion, ...)`. A pooler is authorized iff its stored version
 *         equals the current `authVersion`; bumping `authVersion` therefore revokes every pooler. This script and the
 *         verifier read auth with exactly that predicate (`_isAuthorized`).
 *
 *         IDEMPOTENT: if all four poolers are already unauthorized, the script logs that and sends NOTHING (it does not
 *         bump the version again). A bump is only sent when at least one of the four still passes the predicate.
 *         Rationale: the cutover (story 103) requires "revoked", not a particular version number, so a second bump
 *         would be a pointless owner transaction.
 *
 *         This script changes no addresses: there is no mainnet-addresses.ts backup or patcher step.
 *
 * Preview:   npm run balancer-holding:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed)
 * Broadcast: npm run balancer-holding:broadcast   (Ledger m/44'/60'/46'/0/0, then runs :verify)
 * Verify:    npm run balancer-holding:verify      (read-only, script/VerifyBalancerHolding.s.sol)
 */

/// @notice Minimal interface for the live BalancerPoolerV2 (copied, not imported, per repo script precedent).
interface IBalancerPoolerV2Holding {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function authVersion() external view returns (uint256);
    function poolerAuthVersion(address pooler) external view returns (uint256);
    function incrementAuthVersion() external;
    function pool(uint256 minBPT) external;
    function dispatch(address minter, uint256 amount, bytes calldata extraData) external;
}

/// @notice Shared constants + the auth predicate for the revoke and verify scripts.
abstract contract BalancerHoldingBase is Script {
    uint256 public constant CHAIN_ID = 1;

    // mainnet-addresses.ts `BalancerPooler` (V2, NFTMinter index 4)
    address public constant BALANCER_POOLER_V2 = 0x7f6874332c4629429d70D15f685A8230323F11F1;
    // Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0); also authorized pooler #1
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    // Authorized poolers #2..#4
    address public constant MULTI_POOLER = 0xd1E5774159381915f5579dFd68507E2614f67b51;
    address public constant POOLER_7702_EOA = 0x186c77B80Bbfd21b01C7D7FA44bA27031322a77F;
    address public constant POOLER_EOA = 0x630966B668b321Cc6441754f96519a55F72Cd476;

    // Used by the fork test (mint path unaffected)
    address public constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    function poolers() public pure returns (address[4] memory ps) {
        ps[0] = OWNER;
        ps[1] = MULTI_POOLER;
        ps[2] = POOLER_7702_EOA;
        ps[3] = POOLER_EOA;
    }

    function _pooler() internal pure returns (IBalancerPoolerV2Holding) {
        return IBalancerPoolerV2Holding(BALANCER_POOLER_V2);
    }

    /// @dev EXACTLY the `onlyAuthorizedPooler` predicate: poolerAuthVersion[p] == authVersion.
    function _isAuthorized(address p) internal view returns (bool) {
        return _pooler().poolerAuthVersion(p) == _pooler().authVersion();
    }

    function _countAuthorized() internal view returns (uint256 n) {
        address[4] memory ps = poolers();
        for (uint256 i = 0; i < 4; i++) {
            if (_isAuthorized(ps[i])) n++;
        }
    }

    function _logPoolers() internal view {
        address[4] memory ps = poolers();
        console.log("  authVersion:", _pooler().authVersion());
        for (uint256 i = 0; i < 4; i++) {
            console.log("  pooler", ps[i]);
            console.log("    poolerAuthVersion:", _pooler().poolerAuthVersion(ps[i]));
            console.log(_isAuthorized(ps[i]) ? "    -> AUTHORIZED" : "    -> unauthorized");
        }
    }
}

contract RevokeBalancerPoolersHoldingPattern is BalancerHoldingBase {
    function run() external {
        console.log("=================================================");
        console.log("  BALANCER HOLDING PATTERN: revoke poolers (story 099)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        require(BALANCER_POOLER_V2.code.length > 0, "preflight: BalancerPoolerV2 has no code");
        require(_pooler().owner() == OWNER, "preflight: BalancerPoolerV2 owner is not OWNER");

        bool isPreview = _previewModeFromEnv();
        console.log(isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed)" : "Mode: BROADCAST (Ledger)");

        uint256 versionBefore = _pooler().authVersion();
        console.log("BEFORE:");
        _logPoolers();
        console.log("authVersion before:", versionBefore);

        if (_countAuthorized() == 0) {
            console.log("All four poolers already unauthorized - nothing to do, no transaction sent (idempotent).");
            return;
        }

        if (isPreview) {
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }
        _pooler().incrementAuthVersion();
        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        uint256 versionAfter = _pooler().authVersion();
        console.log("AFTER:");
        _logPoolers();
        console.log("authVersion after:", versionAfter);

        require(versionAfter == versionBefore + 1, "post: authVersion not bumped exactly once");
        address[4] memory ps = poolers();
        for (uint256 i = 0; i < 4; i++) {
            require(!_isAuthorized(ps[i]), "post: pooler still authorized");
        }
        console.log("OK: all four poolers unauthorized (poolerAuthVersion != authVersion).");
        if (isPreview) {
            console.log("PREVIEW: nothing broadcast. Run balancer-holding:broadcast with the Ledger to apply.");
        }
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode
    ///      (`vm.setEnv` is process-wide and forge runs suites in parallel). Production always reads the env.
    ///      Copied from script/CutoverStableStakerV2Mainnet.s.sol.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
