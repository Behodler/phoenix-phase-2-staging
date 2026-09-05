// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/*//////////////////////////////////////////////////////////////////////////////
                    MIGRATE SAGA 2 — STEP 2.3 (ACCUMULATOR REWIRE & VERIFY)
//////////////////////////////////////////////////////////////////////////////

Repoints the StableYieldAccumulator from the old DOLA/USDC strategies to the new ones and runs the
final verification gates. The accumulator address is UNCHANGED (repoint = registry setters), so this
step does NOT touch mainnet-addresses.ts. The accumulator was already authorized as a withdrawer on
the new strategies in 2.1, so it can skim them immediately. USDe's market strategy is untouched.

Idempotent: add/remove are guarded on isRegisteredStrategy so a re-run is a no-op.
See docs/stable-staker-migrations/combined-inplace-and-minter-v2-migration-plan.md §5 (Script 2.3).
*/

contract MigrateSaga2Rewire is Script {
    uint256 public constant CHAIN_ID = 1;

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant STAKER        = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    address public constant MINTER_V1     = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant ACCUMULATOR   = 0x3C690EC3B2524104dE269bf0F9baa7f045eF8270;

    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Old strategies being decommissioned (verify against server/deployments/mainnet-addresses.ts).
    address public constant OLD_DOLA_YS = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant OLD_USDC_YS = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;

    string public constant DEPLOYMENTS_JSON = "script/migration-inputs/saga2-deployments.json";

    bool public isPreview;
    address public ysDolaV2;
    address public ysUsdcV2;
    address public minterV2;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "saga2.3: wrong chain - expected mainnet (1)");
    }

    function run() external {
        isPreview = vm.envOr("PREVIEW_MODE", false);
        _loadDeployments();
        require(IAcc(ACCUMULATOR).owner() == OWNER_ADDRESS, "saga2.3 preflight: not accumulator owner");
        require(IStaker(STAKER).yieldStrategy(DOLA) == ysDolaV2, "saga2.3 preflight: DOLA not rewired - run 2.2");
        require(IStaker(STAKER).yieldStrategy(USDC) == ysUsdcV2, "saga2.3 preflight: USDC not rewired - run 2.2");

        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE ***");
            vm.startBroadcast();
        }

        // Register the new strategies (guarded for idempotency).
        if (!IAcc(ACCUMULATOR).isRegisteredStrategy(ysDolaV2)) IAcc(ACCUMULATOR).addYieldStrategy(ysDolaV2, DOLA);
        if (!IAcc(ACCUMULATOR).isRegisteredStrategy(ysUsdcV2)) IAcc(ACCUMULATOR).addYieldStrategy(ysUsdcV2, USDC);

        // Retire the old strategies (guarded — only remove if currently registered).
        if (IAcc(ACCUMULATOR).isRegisteredStrategy(OLD_DOLA_YS)) IAcc(ACCUMULATOR).removeYieldStrategy(OLD_DOLA_YS);
        if (IAcc(ACCUMULATOR).isRegisteredStrategy(OLD_USDC_YS)) IAcc(ACCUMULATOR).removeYieldStrategy(OLD_USDC_YS);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _verify();
    }

    function _loadDeployments() internal {
        string memory raw = vm.readFile(DEPLOYMENTS_JSON);
        ysDolaV2 = vm.parseJsonAddress(raw, ".ysDolaV2");
        ysUsdcV2 = vm.parseJsonAddress(raw, ".ysUsdcV2");
        minterV2 = vm.parseJsonAddress(raw, ".minterV2");
        require(ysDolaV2 != address(0) && ysUsdcV2 != address(0) && minterV2 != address(0), "saga2.3: deployments JSON incomplete");
    }

    function _verify() internal view {
        // Accumulator registry.
        require(IAcc(ACCUMULATOR).isRegisteredStrategy(ysDolaV2), "verify: ysDolaV2 not registered");
        require(IAcc(ACCUMULATOR).isRegisteredStrategy(ysUsdcV2), "verify: ysUsdcV2 not registered");
        require(!IAcc(ACCUMULATOR).isRegisteredStrategy(OLD_DOLA_YS), "verify: old DOLA still registered");
        require(!IAcc(ACCUMULATOR).isRegisteredStrategy(OLD_USDC_YS), "verify: old USDC still registered");

        // Staker is healthy on the new strategies.
        require(!IStaker(STAKER).withdrawDisabled(DOLA), "verify: DOLA withdraw disabled (underwater)");
        require(!IStaker(STAKER).withdrawDisabled(USDC), "verify: USDC withdraw disabled (underwater)");
        require(IYS(ysDolaV2).principalOf(DOLA, STAKER) > 0, "verify: staker DOLA principal == 0");
        require(IYS(ysUsdcV2).principalOf(USDC, STAKER) > 0, "verify: staker USDC principal == 0");

        // Set-aside buffer carried forward (10%) for the staker on the new strategies.
        require(IYS(ysDolaV2).setAsideBufferSize(STAKER) == 10, "verify: DOLA set-aside buffer != 10");
        require(IYS(ysUsdcV2).setAsideBufferSize(STAKER) == 10, "verify: USDC set-aside buffer != 10");

        // Minter V1 fully drained from the old strategies; minter V2 seeded (log only — may be 0 if the
        // minter had no DOLA/USDC position to recover).
        require(IYS(OLD_DOLA_YS).principalOf(DOLA, MINTER_V1) == 0, "verify: minter V1 DOLA not drained");
        require(IYS(OLD_USDC_YS).principalOf(USDC, MINTER_V1) == 0, "verify: minter V1 USDC not drained");

        console.log("==========================================");
        console.log("  SAGA 2.3 verify passed");
        console.log("  staker DOLA principal:", IYS(ysDolaV2).principalOf(DOLA, STAKER));
        console.log("  staker USDC principal:", IYS(ysUsdcV2).principalOf(USDC, STAKER));
        console.log("  minterV2 DOLA principal:", IYS(ysDolaV2).principalOf(DOLA, minterV2));
        console.log("  minterV2 USDC principal:", IYS(ysUsdcV2).principalOf(USDC, minterV2));
        console.log("==========================================");
    }
}

interface IAcc {
    function owner() external view returns (address);
    function isRegisteredStrategy(address strategy) external view returns (bool);
    function addYieldStrategy(address strategy, address token) external;
    function removeYieldStrategy(address strategy) external;
}

interface IStaker {
    function yieldStrategy(address token) external view returns (address);
    function withdrawDisabled(address token) external view returns (bool);
}

interface IYS {
    function principalOf(address token, address account) external view returns (uint256);
    function setAsideBufferSize(address client) external view returns (uint256);
}
