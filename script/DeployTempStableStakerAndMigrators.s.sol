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

/// @dev Minimal interface for onlyOwner calls + idempotency/pause reads on a StableStaker.
///      Used for BOTH the original staker and the freshly-deployed temp staker.
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
    // YS-09 pause/restore + idempotent wiring reads.
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function setPauser(address _pauser) external;
    function pause() external;
    function getStakedTokens() external view returns (address[] memory);
}

/// @dev MinterInfo mirror for the phUSD authorizedMinters getter (flax-token IFlax.MinterInfo).
struct MinterInfo {
    bool canMint;
    uint256 mintVersion;
}

/// @dev Minimal interface for phUSD minter gating + idempotency read.
interface IPhUSDSetMinter {
    function owner() external view returns (address);
    function setMinter(address minter, bool canMint) external;
    function authorizedMinters(address minter) external view returns (MinterInfo memory);
}

/// @dev Minimal idempotency-read interface for the V2 yield strategies (AYieldStrategy getters).
interface IYSWiringView {
    function authorizedClients(address client) external view returns (bool);
    function setAsideBufferRecipient() external view returns (address);
    function setAsideBufferSize(address client) external view returns (uint256);
    function authorizedWithdrawers(address withdrawer) external view returns (bool);
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
        // YS-09: every wiring call is guarded to skip when already in the target state, so a re-run
        // of this step (against contracts/state that were partially wired on a prior attempt) is a
        // loud no-op rather than a revert or a duplicate. The freshly-deployed tempStaker / V2
        // strategies start virgin, so their guards normally fire the action; the guards on persistent
        // external state (phUSD minter, original.migrator, SYA strategy list) are the load-bearing ones.
        console.log("--- wiring phUSD minter for tempStaker ---");
        if (!IPhUSDSetMinter(PHUSD).authorizedMinters(address(tempStaker)).canMint) {
            IPhUSDSetMinter(PHUSD).setMinter(address(tempStaker), true);
        } else {
            console.log("  setMinter(tempStaker, true) SKIPPED - already minter (resume)");
        }

        console.log("--- registering tokens on tempStaker ---");
        _addTokenIdempotent(tempStaker, DOLA);
        _addTokenIdempotent(tempStaker, USDC);

        console.log("--- setting migrator1 on tempStaker ---");
        if (tempStaker.migrator() != address(migrator1)) {
            tempStaker.setMigrator(address(migrator1));
        } else {
            console.log("  tempStaker.setMigrator(migrator1) SKIPPED - already set (resume)");
        }

        console.log("--- setting migrator1 on original staker ---");
        if (IStakerOwnable(ORIGINAL_STABLE_STAKER).migrator() != address(migrator1)) {
            IStakerOwnable(ORIGINAL_STABLE_STAKER).setMigrator(address(migrator1));
        } else {
            console.log("  original.setMigrator(migrator1) SKIPPED - already set (resume)");
        }

        console.log("--- wiring ysDolaV2 to original staker (setClient + buffer) ---");
        _wireStrategyToOriginal(ysDolaV2, DOLA);

        console.log("--- wiring ysUsdcV2 to original staker (setClient + buffer) ---");
        _wireStrategyToOriginal(ysUsdcV2, USDC);

        // ---- Step 4: pause both stakers for the migration window (YS-09) ----
        // Record each staker's CURRENT pauser, take ownership of the pauser role (owner-only), and
        // pause both stakers so stake()'s whenNotPaused gate cannot be used to grief the empty-pool
        // gate (totalStaked == 0 re-lock) during the leg1->leg2 halt window. PostMigrationCleanup
        // unpauses and restores these recorded pausers. All three calls are idempotent.
        //
        // Pause is contract-global, so this also freezes the un-migrated USDe pool on the original
        // staker for the window — accepted (short window, anti-grief). The recorded pausers are
        // persisted into the deployments JSON so cleanup can restore the exact original wiring.
        console.log("--- YS-09: pausing both stakers for migration window ---");
        address origPauser = IStakerOwnable(ORIGINAL_STABLE_STAKER).pauser();
        address tempPauser = IStakerOwnable(address(tempStaker)).pauser();
        console.log("  recorded original pauser:", origPauser);
        console.log("  recorded temp pauser:    ", tempPauser);
        // Fail loudly if the original pauser is a contract we could not restore as-is. (A non-EOA
        // pauser is fine to restore — we just write the same address back — but a zero pauser would
        // mean restore is a no-op; flagged for the operator rather than silently accepted.)
        require(origPauser != address(0), "Pause: original staker pauser is zero - cannot restore");

        if (IStakerOwnable(ORIGINAL_STABLE_STAKER).pauser() != OWNER_ADDRESS) {
            IStakerOwnable(ORIGINAL_STABLE_STAKER).setPauser(OWNER_ADDRESS);
            console.log("  original.setPauser(deployer) done");
        } else {
            console.log("  original.setPauser(deployer) SKIPPED - already deployer (resume)");
        }
        if (IStakerOwnable(address(tempStaker)).pauser() != OWNER_ADDRESS) {
            IStakerOwnable(address(tempStaker)).setPauser(OWNER_ADDRESS);
            console.log("  tempStaker.setPauser(deployer) done");
        } else {
            console.log("  tempStaker.setPauser(deployer) SKIPPED - already deployer (resume)");
        }
        if (!IStakerOwnable(ORIGINAL_STABLE_STAKER).paused()) {
            IStakerOwnable(ORIGINAL_STABLE_STAKER).pause();
            console.log("  original.pause() done");
        } else {
            console.log("  original.pause() SKIPPED - already paused (resume)");
        }
        if (!IStakerOwnable(address(tempStaker)).paused()) {
            IStakerOwnable(address(tempStaker)).pause();
            console.log("  tempStaker.pause() done");
        } else {
            console.log("  tempStaker.pause() SKIPPED - already paused (resume)");
        }
        console.log("");

        // ---- Step 5: write deployments JSON ----
        // Persist recorded pausers so PostMigrationCleanup can restore the original wiring. A freshly
        // deployed tempStaker's pauser is address(0) by default; persist it anyway (cleanup treats a
        // zero recorded temp pauser as "restore to zero", which matches the as-deployed state and is
        // a harmless no-op since the temp staker is decommissioned at cleanup).
        string memory json = string(
            abi.encodePacked(
                '{"tempStaker":"', vm.toString(address(tempStaker)), '"',
                ',"migrator1":"', vm.toString(address(migrator1)), '"',
                ',"migrator2":"', vm.toString(address(migrator2)), '"',
                ',"ysDolaV2":"', vm.toString(address(ysDolaV2)), '"',
                ',"ysUsdcV2":"', vm.toString(address(ysUsdcV2)), '"',
                ',"origPauser":"', vm.toString(origPauser), '"',
                ',"tempPauser":"', vm.toString(tempPauser), '"}'
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

    /// @dev YS-09 idempotent addToken: addToken reverts "token exists" on a duplicate, so skip when
    ///      the token is already in the staker's registered set.
    function _addTokenIdempotent(StableStaker staker, address token) internal {
        address[] memory registered = IStakerOwnable(address(staker)).getStakedTokens();
        for (uint256 i = 0; i < registered.length; i++) {
            if (registered[i] == token) {
                console.log("  addToken SKIPPED - already registered (resume):", token);
                return;
            }
        }
        staker.addToken(token);
        console.log("  addToken done:", token);
    }

    /// @dev YS-09 idempotent strategy wiring: setClient / buffer recipient / buffer size / SYA
    ///      withdrawer / SYA strategy-list registration each skipped when already in target state.
    function _wireStrategyToOriginal(ERC4626YieldStrategy ys, address token) internal {
        IYSWiringView v = IYSWiringView(address(ys));

        if (!v.authorizedClients(ORIGINAL_STABLE_STAKER)) {
            ys.setClient(ORIGINAL_STABLE_STAKER, true);
        } else {
            console.log("  setClient SKIPPED - already client (resume)");
        }
        if (v.setAsideBufferRecipient() != ORIGINAL_STABLE_STAKER) {
            ys.setSetAsideBufferRecipient(ORIGINAL_STABLE_STAKER);
        } else {
            console.log("  setSetAsideBufferRecipient SKIPPED - already set (resume)");
        }
        if (v.setAsideBufferSize(ORIGINAL_STABLE_STAKER) != SETASIDE_BUFFER) {
            ys.setSetAsideBuffer(ORIGINAL_STABLE_STAKER, SETASIDE_BUFFER);
        } else {
            console.log("  setSetAsideBuffer SKIPPED - already 10 (resume)");
        }

        // YS-03: authorize + register the SYA as the buffer's consumer (a buffer with no consumer
        // is dead). Both guarded so a re-run is a no-op.
        if (!v.authorizedWithdrawers(SYA)) {
            ys.setWithdrawer(SYA, true);
        } else {
            console.log("  setWithdrawer(SYA) SKIPPED - already authorized (resume)");
        }
        address[] memory syaStrategies = ISYAAdmin(SYA).getYieldStrategies();
        bool registeredOnSya;
        for (uint256 i = 0; i < syaStrategies.length; i++) {
            if (syaStrategies[i] == address(ys)) registeredOnSya = true;
        }
        if (!registeredOnSya) {
            ISYAAdmin(SYA).addYieldStrategy(address(ys), token);
        } else {
            console.log("  SYA.addYieldStrategy SKIPPED - already registered (resume)");
        }
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
