// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title PhusdMinterRepoint
 * @notice Story 064 - YS-12 resolution: repoint the EXISTING PhusdStableMinter
 *         (0x435B…77E5) off the old, buggy ERC4626YieldStrategy builds
 *         (YS_DOLA_OLD 0x90ce…7F9 / YS_USDC_OLD 0x90af…470) and onto the
 *         story-060 V2 strategies (ysDolaV2 / ysUsdcV2), then evacuate the
 *         minter's existing position off the old strategies and re-seed it on V2.
 *
 *         Run AFTER the full story-060 suite (SkimAndLeg1Migration → ResetAndRewire →
 *         Leg2Migration → PostMigrationCleanup) — the minter must be the SOLE remaining
 *         client on each old strategy so withdrawAsOwner cleanly returns all residual
 *         real value with no cross-client dilution.
 *
 *         Reads: script/migration-inputs/ys-swap-deployments.json (ysDolaV2 / ysUsdcV2)
 *
 *         Phase A (per token T ∈ {DOLA, USDC}) — repoint future mints:
 *           1. read live config (exchangeRate, decimals, maxMintPerDay) BEFORE registering
 *           2. ysTV2.setClient(minter, true)            (authorize minter on V2)
 *           3. minter.registerStablecoin(T, ysTV2, …)   (resets maxMintPerDay to 0, enabled=true)
 *           4. minter.approveYS(T, ysTV2)               (max-approve V2 to pull T from minter)
 *           5. minter.setMaxMintPerDay(T, savedCap)     (restore the cap zeroed in step 3)
 *
 *         Phase B (per token T, old strategy oldT) — evacuate existing position:
 *           1. balBefore = T.balanceOf(owner)
 *           2. p = oldT.principalOf(T, minter); oldT.withdrawAsOwner(minter, owner, p)
 *           3. recovered = T.balanceOf(owner) - balBefore  (may be < p if autopool below par)
 *           4. T.approve(minter, recovered)              (noMintDeposit pulls from msg.sender)
 *           5. minter.noMintDeposit(ysTV2, T, recovered) (re-seed V2, NO new phUSD minted)
 *
 *         Post-verify (per token, revert on any mismatch):
 *           - ysTV2.authorizedClients(minter) == true
 *           - T.allowance(minter, ysTV2) == type(uint256).max
 *           - getStablecoinConfig(T).yieldStrategy == ysTV2
 *           - getStablecoinConfig(T).maxMintPerDay == savedCap
 *           - oldT.principalOf(T, minter) == 0
 *           - ysTV2.principalOf(T, minter) > 0
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/PhusdMinterRepoint.s.sol:PhusdMinterRepoint \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/PhusdMinterRepoint.s.sol:PhusdMinterRepoint \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
contract PhusdMinterRepoint is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES (confirmed in sibling migration scripts)
    // ==========================================

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant PHUSD_MINTER   = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;

    // Old (buggy) yield strategies the minter still routes mints into.
    address public constant YS_DOLA_OLD    = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant YS_USDC_OLD    = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;

    address public constant DOLA           = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC           = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant CHAIN_ID       = 1;

    // ==========================================
    //   RUNTIME STATE
    // ==========================================

    bool    public isPreview;

    // Daily mint caps captured live in Phase A BEFORE registerStablecoin zeroes them,
    // restored in Phase A step 5 and asserted in post-verify.
    uint256 public dolaSavedCap;
    uint256 public usdcSavedCap;

    function run() external {
        require(block.chainid == CHAIN_ID, "mainnet only");

        console.log("==========================================");
        console.log(" PhusdMinterRepoint (story 064, YS-12)");
        console.log("==========================================");
        console.log("Chain ID:       ", block.chainid);
        console.log("Owner (ledger): ", OWNER_ADDRESS);
        console.log("phUSD minter:   ", PHUSD_MINTER);
        console.log("");

        // Read V2 strategy addresses from the story-060 deployments JSON.
        string memory deploymentsRaw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address ysDolaV2 = vm.parseJsonAddress(deploymentsRaw, ".ysDolaV2");
        address ysUsdcV2 = vm.parseJsonAddress(deploymentsRaw, ".ysUsdcV2");

        console.log("ysDolaV2: ", ysDolaV2);
        console.log("ysUsdcV2: ", ysUsdcV2);
        console.log("");

        _preflight(ysDolaV2, ysUsdcV2);

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

        // Phase A must complete before Phase B: noMintDeposit's deposit() checks
        // _authorizedClients.contains(minter), which Phase A step 2 establishes.
        _phaseA(ysDolaV2, ysUsdcV2);
        _phaseB(ysDolaV2, ysUsdcV2);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _postVerify(ysDolaV2, ysUsdcV2);
        _printSummary(ysDolaV2, ysUsdcV2);
    }

    // ==========================================
    //   PREFLIGHT (read-only, before prank/broadcast)
    // ==========================================

    function _preflight(address ysDolaV2, address ysUsdcV2) internal view {
        console.log("=== Preflight ===");

        require(ysDolaV2 != address(0), "Preflight: ysDolaV2 address is zero in deployments JSON");
        require(ysUsdcV2 != address(0), "Preflight: ysUsdcV2 address is zero in deployments JSON");

        // Owner gates: every state-changing call below is onlyOwner on the minter / strategies.
        require(
            PhusdStableMinter(PHUSD_MINTER).owner() == OWNER_ADDRESS,
            "Preflight: phUSD minter owner != OWNER_ADDRESS"
        );
        require(
            ERC4626YieldStrategy(ysDolaV2).owner() == OWNER_ADDRESS,
            "Preflight: ysDolaV2 owner != OWNER_ADDRESS"
        );
        require(
            ERC4626YieldStrategy(ysUsdcV2).owner() == OWNER_ADDRESS,
            "Preflight: ysUsdcV2 owner != OWNER_ADDRESS"
        );
        require(
            ERC4626YieldStrategy(YS_DOLA_OLD).owner() == OWNER_ADDRESS,
            "Preflight: YS_DOLA_OLD owner != OWNER_ADDRESS"
        );
        require(
            ERC4626YieldStrategy(YS_USDC_OLD).owner() == OWNER_ADDRESS,
            "Preflight: YS_USDC_OLD owner != OWNER_ADDRESS"
        );

        // Log live config so the operator can confirm before broadcast.
        _logLiveConfig("DOLA", DOLA);
        _logLiveConfig("USDC", USDC);

        console.log("Preflight OK");
        console.log("");
    }

    function _logLiveConfig(string memory label, address token) internal view {
        // Public mapping getter returns the full StablecoinConfig tuple.
        (
            address yieldStrategy,
            uint256 exchangeRate,
            uint8 decimals,
            ,
            uint256 maxMintPerDay,
            ,
        ) = PhusdStableMinter(PHUSD_MINTER).stablecoinConfigs(token);
        console.log(string.concat("  live config ", label, ":"));
        console.log("    yieldStrategy: ", yieldStrategy);
        console.log("    exchangeRate:  ", exchangeRate);
        console.log("    decimals:      ", uint256(decimals));
        console.log("    maxMintPerDay: ", maxMintPerDay);
    }

    // ==========================================
    //   PHASE A — repoint future mints
    // ==========================================

    function _phaseA(address ysDolaV2, address ysUsdcV2) internal {
        console.log("=== Phase A: repoint future mints ===");
        dolaSavedCap = _phaseAToken("DOLA", DOLA, ysDolaV2);
        usdcSavedCap = _phaseAToken("USDC", USDC, ysUsdcV2);
        console.log("");
    }

    function _phaseAToken(string memory label, address token, address ysTV2)
        internal
        returns (uint256 savedCap)
    {
        // 1. Read live config BEFORE registering (registerStablecoin zeros maxMintPerDay).
        //    exchangeRate / decimals are replicated from the live config (Configuration Safety:
        //    do NOT assume 1e18 / defaults — re-use exactly what the live minter has).
        (
            ,
            uint256 exchangeRate,
            uint8 decimals,
            ,
            uint256 maxMintPerDay,
            ,
        ) = PhusdStableMinter(PHUSD_MINTER).stablecoinConfigs(token);
        savedCap = maxMintPerDay;

        // 2. Authorize the minter on the V2 strategy (required before noMintDeposit in Phase B).
        ERC4626YieldStrategy(ysTV2).setClient(PHUSD_MINTER, true);

        // 3. Repoint config to V2 (sets enabled=true, resets maxMintPerDay/mintedToday/lastMint to 0).
        PhusdStableMinter(PHUSD_MINTER).registerStablecoin(token, ysTV2, exchangeRate, decimals);

        // 4. Max-approve the V2 strategy to pull `token` from the minter.
        PhusdStableMinter(PHUSD_MINTER).approveYS(token, ysTV2);

        // 5. Restore the daily cap zeroed in step 3 (savedCap == 0 is a harmless no-op = unlimited).
        PhusdStableMinter(PHUSD_MINTER).setMaxMintPerDay(token, savedCap);

        console.log(string.concat("  ", label, " repointed -> V2; savedCap restored:"), savedCap);
    }

    // ==========================================
    //   PHASE B — evacuate existing position
    // ==========================================

    function _phaseB(address ysDolaV2, address ysUsdcV2) internal {
        console.log("=== Phase B: evacuate existing position off old strategies ===");
        _phaseBToken("DOLA", DOLA, YS_DOLA_OLD, ysDolaV2);
        _phaseBToken("USDC", USDC, YS_USDC_OLD, ysUsdcV2);
        console.log("");
    }

    function _phaseBToken(string memory label, address token, address oldT, address ysTV2) internal {
        // 1. Record owner balance before the withdrawal.
        uint256 balBefore = IERC20(token).balanceOf(OWNER_ADDRESS);

        // 2. Withdraw the minter's entire principal from the old strategy to the owner. withdrawAsOwner
        //    redeems backing shares (capped to available shares) and zeroes the minter's stale accounting
        //    on the old strategy, so the owner receives the REAL residual value (which may be < p if the
        //    autopool is genuinely below par).
        uint256 p = ERC4626YieldStrategy(oldT).principalOf(token, PHUSD_MINTER);
        ERC4626YieldStrategy(oldT).withdrawAsOwner(PHUSD_MINTER, OWNER_ADDRESS, p);

        // 3. Compute the real recovered amount.
        uint256 recovered = IERC20(token).balanceOf(OWNER_ADDRESS) - balBefore;
        if (recovered < p) {
            // Pre-existing phUSD-collateralization shortfall — NOT caused by this migration.
            // Log prominently and surface to treasury; do NOT revert.
            console.log(string.concat("  WARNING ", label, ": BELOW PAR - recovered < recorded principal"));
            console.log("    recorded principal (p): ", p);
            console.log("    recovered (real):       ", recovered);
            console.log("    shortfall:              ", p - recovered);
        } else {
            console.log(string.concat("  ", label, " recovered == recorded principal:"), recovered);
        }

        // 4. Approve the minter to pull the recovered tokens (noMintDeposit uses safeTransferFrom(msg.sender)).
        IERC20(token).approve(PHUSD_MINTER, recovered);

        // 5. Re-deposit into V2 without minting new phUSD (seeding, not minting).
        PhusdStableMinter(PHUSD_MINTER).noMintDeposit(ysTV2, token, recovered);
        console.log(string.concat("  ", label, " re-seeded into V2:"), recovered);
    }

    // ==========================================
    //   POST-VERIFY (read-only, no more txs)
    // ==========================================

    function _postVerify(address ysDolaV2, address ysUsdcV2) internal view {
        console.log("=== Post-verify ===");
        _postVerifyToken("DOLA", DOLA, YS_DOLA_OLD, ysDolaV2, dolaSavedCap);
        _postVerifyToken("USDC", USDC, YS_USDC_OLD, ysUsdcV2, usdcSavedCap);
        console.log("Post-verify OK");
        console.log("");
    }

    function _postVerifyToken(
        string memory label,
        address token,
        address oldT,
        address ysTV2,
        uint256 savedCap
    ) internal view {
        // Phase A post-conditions.
        require(
            ERC4626YieldStrategy(ysTV2).authorizedClients(PHUSD_MINTER),
            string.concat(label, ": minter not authorized on V2")
        );
        require(
            IERC20(token).allowance(PHUSD_MINTER, ysTV2) == type(uint256).max,
            string.concat(label, ": minter allowance wrong")
        );
        require(
            PhusdStableMinter(PHUSD_MINTER).getStablecoinConfig(token).yieldStrategy == ysTV2,
            string.concat(label, ": config not repointed")
        );
        require(
            PhusdStableMinter(PHUSD_MINTER).getStablecoinConfig(token).maxMintPerDay == savedCap,
            string.concat(label, ": cap not restored")
        );

        // Phase B post-conditions.
        require(
            ERC4626YieldStrategy(oldT).principalOf(token, PHUSD_MINTER) == 0,
            string.concat(label, ": old principal not zeroed")
        );
        require(
            ERC4626YieldStrategy(ysTV2).principalOf(token, PHUSD_MINTER) > 0,
            string.concat(label, ": V2 principal not seeded")
        );

        console.log(string.concat("  ", label, " post-conditions OK"));
        console.log("    V2 principal: ", ERC4626YieldStrategy(ysTV2).principalOf(token, PHUSD_MINTER));
    }

    // ==========================================
    //   SUMMARY
    // ==========================================

    function _printSummary(address ysDolaV2, address ysUsdcV2) internal view {
        console.log("==========================================");
        console.log("  SUMMARY (story 064, YS-12)");
        console.log("==========================================");
        console.log("phUSD minter:        ", PHUSD_MINTER);
        console.log("DOLA repointed to:   ", ysDolaV2);
        console.log("USDC repointed to:   ", ysUsdcV2);
        console.log("DOLA cap restored:   ", dolaSavedCap);
        console.log("USDC cap restored:   ", usdcSavedCap);
        console.log("");
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
        } else {
            console.log("BROADCAST complete. Minter now mints into V2 strategies; old positions evacuated.");
        }
        console.log("==========================================");
    }
}
