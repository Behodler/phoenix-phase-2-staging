// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";
import {StableStakerMigrator} from "stable-staker/StableStakerMigrator.sol";
import {IStableStaker} from "stable-staker/interfaces/IStableStaker.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {IFlax as IFlaxStaker} from "flax-token/IFlax.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployTempStableStakerAndMigrators
 * @notice Story 060 - Step 1 of the yield-strategy swap migration.
 *
 *         Deploys:
 *           1. ysDolaV2  - fresh ERC4626YieldStrategy(owner, DOLA,  AUTODOLA_VAULT)
 *           2. ysUsdcV2  - fresh ERC4626YieldStrategy(owner, USDC,  AUTOUSDC_VAULT)
 *           3. tempStaker - fresh StableStaker(phUSD, owner) - used as a holding pen during the swap
 *           4. migrator1  - StableStakerMigrator(original → temp) - leg 1: drain original into temp
 *           5. migrator2  - StableStakerMigrator(temp → original) - leg 2: pour back into original
 *
 *         Wires:
 *           - phUSD.setMinter(tempStaker, true)
 *           - tempStaker.addToken(DOLA / USDC)
 *           - tempStaker.setMigrator(migrator1)
 *           - original.setMigrator(migrator1)        [via ISetMigrator minimal interface]
 *           - ysDolaV2 / ysUsdcV2: setClient(original, true), setSetAsideBufferRecipient(original),
 *             setSetAsideBuffer(original, 10)
 *           (The new strategies are wired to the ORIGINAL staker so that after leg 2 the original
 *            staker's strategy swap is done and users are back on the healthy strategies.)
 *
 *         Writes deployment addresses to:
 *           - broadcast:  script/migration-inputs/ys-swap-deployments.json
 *           - preview:    script/migration-inputs/ys-swap-deployments-preview.json
 *
 * PREVIEW (no broadcast - owner impersonated):
 *   PREVIEW_MODE=true forge script script/DeployTempStableStakerAndMigrators.s.sol:DeployTempStableStakerAndMigrators \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST (ledger):
 *   forge script script/DeployTempStableStakerAndMigrators.s.sol:DeployTempStableStakerAndMigrators \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

/// @dev Minimal interface for onlyOwner calls on the already-deployed original StableStaker.
interface IStakerOwnable {
    function owner() external view returns (address);
    function setMigrator(address _migrator) external;
    function addToken(address token) external;
    function setYieldStrategy(address token, IYieldStrategy strategy) external;
    function finalizeAndReset(address token) external;
    function stakerCount(address token) external view returns (uint256);
    function migrator() external view returns (address);
    function poolInfo(address token) external view returns (uint256, uint256, uint256, uint256);
    function withdrawDisabled(address token) external view returns (bool);
}

/// @dev Minimal interface for phUSD minter gating.
interface IPhUSDSetMinter {
    function owner() external view returns (address);
    function setMinter(address minter, bool canMint) external;
}

/// @dev Minimal admin/view interface for the live StableYieldAccumulator (SYA).
///      Mirrors the local-interface pattern used in ReplaceSYAMainnet.s.sol (IStrategyAdmin et al.)
///      rather than heavy-importing the whole StableYieldAccumulator contract. YS-03.
interface ISYAAdmin {
    function owner() external view returns (address);
    function addYieldStrategy(address strategy, address token) external;
    function getYieldStrategies() external view returns (address[] memory);
}

contract DeployTempStableStakerAndMigrators is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES
    // ==========================================

    address public constant OWNER_ADDRESS        = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant ORIGINAL_STABLE_STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    address public constant PHUSD                = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;

    address public constant DOLA                 = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC                 = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address public constant AUTODOLA_VAULT       = 0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d;
    address public constant AUTOUSDC_VAULT       = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;

    // YS-03: live StableYieldAccumulator (replace-sya deployment; mainnet-addresses.ts:34).
    // The SYA is the only authorized withdrawer in the yield pipeline; after migration it must
    // be able to see + skim the V2 strategies. Owner == OWNER_ADDRESS, so addYieldStrategy on it
    // is callable in this script's single broadcast.
    address public constant SYA                  = 0x3C690EC3B2524104dE269bf0F9baa7f045eF8270;

    uint256 public constant CHAIN_ID             = 1;
    uint256 public constant SETASIDE_BUFFER      = 10;

    // ==========================================
    //   RUNTIME STATE
    // ==========================================

    bool public isPreview;

    ERC4626YieldStrategy   public ysDolaV2;
    ERC4626YieldStrategy   public ysUsdcV2;
    StableStaker           public tempStaker;
    StableStakerMigrator   public migrator1;
    StableStakerMigrator   public migrator2;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "DeployTempStableStakerAndMigrators: wrong chain - expected mainnet (1)");
    }

    function _globalPreflight() internal view {
        require(
            IStakerOwnable(ORIGINAL_STABLE_STAKER).owner() == OWNER_ADDRESS,
            "Preflight: ORIGINAL_STABLE_STAKER owner != OWNER_ADDRESS"
        );
        require(
            IPhUSDSetMinter(PHUSD).owner() == OWNER_ADDRESS,
            "Preflight: phUSD owner != OWNER_ADDRESS"
        );
        require(OWNER_ADDRESS != address(0), "Preflight: OWNER_ADDRESS is zero");
        require(ORIGINAL_STABLE_STAKER != address(0), "Preflight: ORIGINAL_STABLE_STAKER is zero");
        require(PHUSD != address(0), "Preflight: PHUSD is zero");
        require(AUTODOLA_VAULT != address(0), "Preflight: AUTODOLA_VAULT is zero");
        require(AUTOUSDC_VAULT != address(0), "Preflight: AUTOUSDC_VAULT is zero");
        require(SETASIDE_BUFFER == 10 && SETASIDE_BUFFER <= 100, "Preflight: buffer must be 10");
    }

    function run() external {
        console.log("==========================================");
        console.log(" DeployTempStableStakerAndMigrators (story 060, step 1)");
        console.log("==========================================");
        console.log("Chain ID:          ", block.chainid);
        console.log("Owner (ledger):    ", OWNER_ADDRESS);
        console.log("Original staker:   ", ORIGINAL_STABLE_STAKER);
        console.log("");

        _globalPreflight();

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            console.log("");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***");
            console.log("");
            vm.startBroadcast();
        }

        // ---- Step 1: deploy new V2 yield strategies ----
        console.log("--- deploying ysDolaV2 ---");
        ysDolaV2 = new ERC4626YieldStrategy(OWNER_ADDRESS, DOLA, AUTODOLA_VAULT);
        console.log("  ysDolaV2:    ", address(ysDolaV2));

        console.log("--- deploying ysUsdcV2 ---");
        ysUsdcV2 = new ERC4626YieldStrategy(OWNER_ADDRESS, USDC, AUTOUSDC_VAULT);
        console.log("  ysUsdcV2:    ", address(ysUsdcV2));

        // ---- Step 2: deploy temp staker and migrators ----
        console.log("--- deploying tempStaker ---");
        tempStaker = new StableStaker(IFlaxStaker(PHUSD), OWNER_ADDRESS);
        console.log("  tempStaker:  ", address(tempStaker));

        console.log("--- deploying migrator1 (original -> temp) ---");
        migrator1 = new StableStakerMigrator(
            IStableStaker(ORIGINAL_STABLE_STAKER),
            IStableStaker(address(tempStaker)),
            OWNER_ADDRESS
        );
        console.log("  migrator1:   ", address(migrator1));

        console.log("--- deploying migrator2 (temp -> original) ---");
        migrator2 = new StableStakerMigrator(
            IStableStaker(address(tempStaker)),
            IStableStaker(ORIGINAL_STABLE_STAKER),
            OWNER_ADDRESS
        );
        console.log("  migrator2:   ", address(migrator2));

        // ---- Step 3: wiring ----
        console.log("--- wiring phUSD minter for tempStaker ---");
        IPhUSDSetMinter(PHUSD).setMinter(address(tempStaker), true);

        console.log("--- registering tokens on tempStaker ---");
        tempStaker.addToken(DOLA);
        tempStaker.addToken(USDC);

        console.log("--- setting migrator1 on tempStaker ---");
        tempStaker.setMigrator(address(migrator1));

        console.log("--- setting migrator1 on original staker ---");
        IStakerOwnable(ORIGINAL_STABLE_STAKER).setMigrator(address(migrator1));

        console.log("--- wiring ysDolaV2 to original staker (setClient + buffer) ---");
        ysDolaV2.setClient(ORIGINAL_STABLE_STAKER, true);
        ysDolaV2.setSetAsideBufferRecipient(ORIGINAL_STABLE_STAKER);
        ysDolaV2.setSetAsideBuffer(ORIGINAL_STABLE_STAKER, SETASIDE_BUFFER);

        // YS-03: authorize the live SYA to skim surplus from ysDolaV2, and register it in the
        // SYA's strategy list. Without these the migrated principal is invisible/un-skimmable to
        // the SYA and the 10% buffer above can never trigger (a buffer with no consumer is dead).
        console.log("--- YS-03: authorizing + registering ysDolaV2 on SYA ---");
        ysDolaV2.setWithdrawer(SYA, true);
        ISYAAdmin(SYA).addYieldStrategy(address(ysDolaV2), DOLA);

        console.log("--- wiring ysUsdcV2 to original staker (setClient + buffer) ---");
        ysUsdcV2.setClient(ORIGINAL_STABLE_STAKER, true);
        ysUsdcV2.setSetAsideBufferRecipient(ORIGINAL_STABLE_STAKER);
        ysUsdcV2.setSetAsideBuffer(ORIGINAL_STABLE_STAKER, SETASIDE_BUFFER);

        // YS-03: same for ysUsdcV2.
        console.log("--- YS-03: authorizing + registering ysUsdcV2 on SYA ---");
        ysUsdcV2.setWithdrawer(SYA, true);
        ISYAAdmin(SYA).addYieldStrategy(address(ysUsdcV2), USDC);

        // ---- Step 4: write deployments JSON ----
        string memory json = string(
            abi.encodePacked(
                '{"tempStaker":"', vm.toString(address(tempStaker)), '"',
                ',"migrator1":"', vm.toString(address(migrator1)), '"',
                ',"migrator2":"', vm.toString(address(migrator2)), '"',
                ',"ysDolaV2":"', vm.toString(address(ysDolaV2)), '"',
                ',"ysUsdcV2":"', vm.toString(address(ysUsdcV2)), '"}'
            )
        );

        if (!isPreview) {
            vm.writeJson(json, "script/migration-inputs/ys-swap-deployments.json");
            console.log("  Written: script/migration-inputs/ys-swap-deployments.json");
        } else {
            vm.writeJson(json, "script/migration-inputs/ys-swap-deployments-preview.json");
            console.log("  Written: script/migration-inputs/ys-swap-deployments-preview.json");
        }

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _verifySyaWiring();

        _printSummary();
    }

    /// @dev YS-03 post-asserts: mirror ReplaceSYAMainnet.s.sol:295-301. The SYA must be an
    ///      authorized withdrawer on both V2 strategies and both must appear in its strategy list.
    ///      Never assert a buffer size (done above) without asserting a consumer for it.
    function _verifySyaWiring() internal view {
        require(ysDolaV2.authorizedWithdrawers(SYA), "ysDolaV2: SYA not authorized withdrawer");
        require(ysUsdcV2.authorizedWithdrawers(SYA), "ysUsdcV2: SYA not authorized withdrawer");

        address[] memory registered = ISYAAdmin(SYA).getYieldStrategies();
        bool dolaRegistered;
        bool usdcRegistered;
        for (uint256 i = 0; i < registered.length; i++) {
            if (registered[i] == address(ysDolaV2)) dolaRegistered = true;
            if (registered[i] == address(ysUsdcV2)) usdcRegistered = true;
        }
        require(dolaRegistered, "SYA: ysDolaV2 not registered in strategy list");
        require(usdcRegistered, "SYA: ysUsdcV2 not registered in strategy list");
        console.log("YS-03: SYA wiring verified (both V2 strategies authorized + registered)");
    }

    function _printSummary() internal view {
        console.log("==========================================");
        console.log("  DEPLOYMENT SUMMARY (story 060 step 1)");
        console.log("==========================================");
        console.log("ysDolaV2:    ", address(ysDolaV2));
        console.log("ysUsdcV2:    ", address(ysUsdcV2));
        console.log("tempStaker:  ", address(tempStaker));
        console.log("migrator1:   ", address(migrator1));
        console.log("migrator2:   ", address(migrator2));
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
        } else {
            console.log("BROADCAST complete.");
        }
        console.log("==========================================");
    }
}
