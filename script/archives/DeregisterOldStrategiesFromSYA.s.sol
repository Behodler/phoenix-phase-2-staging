// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";

/**
 * @title DeregisterOldStrategiesFromSYA
 * @notice Story 065 - Phase 7 (master-ordering step 7): remove the old DOLA/USDC strategies from
 *         the live StableYieldAccumulator so it references only the V2 strategies.
 *
 *         Story-061 wired the V2 strategies into the SYA but LEFT the old YS_DOLA_OLD/YS_USDC_OLD
 *         registrations (deferred to YS-12). This removes them.
 *
 *         API CORRECTION (Q-SYA-SEL, confirmed against StableYieldAccumulator.sol:243):
 *         `removeYieldStrategy(address strategy)` takes the **STRATEGY address**, NOT the token.
 *         It reverts `StrategyNotRegistered` if the strategy is not in the registry, so this script
 *         reads `getYieldStrategies()` and only removes strategies that are actually registered
 *         (idempotent / re-run-safe). There is NO `setWithdrawer` on the SYA (that is an
 *         AYieldStrategy method) — the story's "setWithdrawer cleanup" sub-step does not apply here.
 *
 *         LIVE SYA ADDRESS (Q-SYA-SEL, unresolved at planning): set via LIVE_SYA below. Story-058
 *         replaced the SYA; verify this is the live instance before broadcast. The script asserts
 *         owner == OWNER_ADDRESS and that the contract has code, and is a no-op for any old strategy
 *         already absent — so a wrong-but-owned address fails loud on the owner check, and a correct
 *         address with nothing to remove is a clean no-op.
 *
 *         Reads: script/migration-inputs/ys-swap-deployments.json (ysDolaV2 / ysUsdcV2) to assert
 *                the V2 strategies SURVIVE the cleanup.
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/DeregisterOldStrategiesFromSYA.s.sol:DeregisterOldStrategiesFromSYA \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/DeregisterOldStrategiesFromSYA.s.sol:DeregisterOldStrategiesFromSYA \
 *     --rpc-url $RPC_MAINNET --broadcast --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
contract DeregisterOldStrategiesFromSYA is Script {
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Live StableYieldAccumulator. VERIFY this is the live instance at execution (story-058 replaced
    // the SYA; this is the address used by RewireSYAToPhlimboV2.s.sol). See Q-SYA-SEL.
    address public constant LIVE_SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;

    address public constant YS_DOLA_OLD = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant YS_USDC_OLD = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;
    // YS_USDE is intentionally NOT removed — the USDe pool stays live.

    uint256 public constant CHAIN_ID = 1;

    bool public isPreview;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "DeregisterOldStrategiesFromSYA: wrong chain - expected mainnet (1)");
    }

    function run() external {
        console.log("==========================================");
        console.log(" DeregisterOldStrategiesFromSYA (story 065, step 7)");
        console.log("==========================================");
        console.log("SYA:           ", LIVE_SYA);
        console.log("owner (ledger):", OWNER_ADDRESS);

        require(LIVE_SYA.code.length > 0, "Preflight: LIVE_SYA has no code");
        StableYieldAccumulator sya = StableYieldAccumulator(LIVE_SYA);
        require(sya.owner() == OWNER_ADDRESS, "Preflight: SYA owner != OWNER_ADDRESS - wrong SYA?");

        // Read V2 addresses to assert they survive.
        string memory raw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address ysDolaV2 = vm.parseJsonAddress(raw, ".ysDolaV2");
        address ysUsdcV2 = vm.parseJsonAddress(raw, ".ysUsdcV2");
        require(ysDolaV2 != address(0) && ysUsdcV2 != address(0), "Preflight: V2 addresses zero");

        _logStrategies("before", sya);

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***");
            vm.startBroadcast();
        }

        _removeIfRegistered(sya, YS_DOLA_OLD);
        _removeIfRegistered(sya, YS_USDC_OLD);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- Post-assert ----
        _logStrategies("after", sya);
        require(!_isRegistered(sya, YS_DOLA_OLD), "Post-assert: YS_DOLA_OLD still registered");
        require(!_isRegistered(sya, YS_USDC_OLD), "Post-assert: YS_USDC_OLD still registered");
        require(_isRegistered(sya, ysDolaV2), "Post-assert: ysDolaV2 no longer registered (over-removed!)");
        require(_isRegistered(sya, ysUsdcV2), "Post-assert: ysUsdcV2 no longer registered (over-removed!)");
        console.log("Deregister OK - old DOLA/USDC strategies removed; V2 intact.");
    }

    function _removeIfRegistered(StableYieldAccumulator sya, address strategy) internal {
        if (_isRegistered(sya, strategy)) {
            sya.removeYieldStrategy(strategy);
            console.log("  removed strategy:", strategy);
        } else {
            console.log("  strategy not registered (skip):", strategy);
        }
    }

    function _isRegistered(StableYieldAccumulator sya, address strategy) internal view returns (bool) {
        address[] memory strategies = sya.getYieldStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == strategy) return true;
        }
        return false;
    }

    function _logStrategies(string memory label, StableYieldAccumulator sya) internal view {
        address[] memory strategies = sya.getYieldStrategies();
        console.log(string(abi.encodePacked("getYieldStrategies() ", label, " (count):")), strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            console.log("   ", strategies[i]);
        }
    }
}
