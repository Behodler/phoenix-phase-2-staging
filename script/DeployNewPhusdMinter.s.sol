// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title DeployNewPhusdMinter
 * @notice Story 065 - Phase 2 (master-ordering step 2): stand up a FRESH PhusdStableMinter
 *         wired to the story-060 V2 strategies (ysDolaV2 / ysUsdcV2) from birth, with the
 *         per-stablecoin daily mint cap enabled.
 *
 *         WHY a fresh deploy and not story-064's repoint (Q-OLDMINTER, resolved on-chain
 *         2026-06-13): the LIVE minter 0x435B…77E5 is the pre-`story-007` 4-field build —
 *         its `StablecoinConfig` has only {yieldStrategy, exchangeRate, decimals, enabled}
 *         and it has NO `setMaxMintPerDay` (the daily mint cap was added in minter commit
 *         6606057). A mint limit cannot be retrofitted into deployed bytecode, so the only
 *         way to obtain it is a fresh `d6ed115` build. This script delivers exactly that.
 *
 *         This step DOES NOT move any funds and DOES NOT revoke the old minter. Cutover and
 *         revocation happen in Phase 3 (CutoverAndRevokeOldMinter); position evacuation in
 *         Phase 6 (EvacuateAndReseedMinter).
 *
 *         Reads:  script/migration-inputs/ys-swap-deployments.json (ysDolaV2 / ysUsdcV2)
 *         Writes: .newMinter into the same JSON (broadcast only)
 *
 *         Ordered actions (registerStablecoin FOOTGUN: it zeroes maxMintPerDay, so the cap is
 *         ALWAYS set AFTER register):
 *           1. deploy new PhusdStableMinter(phUSD)
 *           2. ysDolaV2.setClient(newMinter, true) ; ysUsdcV2.setClient(newMinter, true)
 *           3. per token T:  registerStablecoin(T, ysTV2, rate, decimals)
 *           4. per token T:  approveYS(T, ysTV2)
 *           5. per token T:  setMaxMintPerDay(T, 4000e18)   (AFTER register)
 *           6. IFlax(phUSD).setMinter(newMinter, true)      (grant mint authority)
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/DeployNewPhusdMinter.s.sol:DeployNewPhusdMinter \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/DeployNewPhusdMinter.s.sol:DeployNewPhusdMinter \
 *     --rpc-url $RPC_MAINNET --broadcast --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */

/// @dev Minimal phUSD (Flax) mint-authority surface. setMinter is onlyOwner on FlaxToken.
interface IFlaxMinter {
    struct MinterInfo {
        bool canMint;
        uint256 mintVersion;
    }
    function setMinter(address minter, bool canMint) external;
    function authorizedMinters(address minter) external view returns (MinterInfo memory);
    function owner() external view returns (address);
}

contract DeployNewPhusdMinter is Script {
    // ==========================================
    //   LIVE MAINNET ADDRESSES / CONSTANTS
    // ==========================================

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // phUSD token (confirmed on-chain: live minter.phUSD() and phUSD.owner() == OWNER_ADDRESS).
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;

    // Live minter (the old 4-field build being replaced) — referenced for the canMint sanity log.
    address public constant OLD_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;

    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Live config mirrored from the old minter (read on-chain 2026-06-13):
    //   DOLA: exchangeRate 1e18, decimals 18 ; USDC: exchangeRate 1e18, decimals 6.
    uint256 public constant DOLA_RATE = 1e18;
    uint8   public constant DOLA_DECIMALS = 18;
    uint256 public constant USDC_RATE = 1e18;
    uint8   public constant USDC_DECIMALS = 6;

    // Daily mint cap (Q-CAP, resolved): cap is in phUSD 18-dec units (see PhusdStableMinter.sol:30
    // "cap in phUSD (18 decimals); 0 = no limit"; mint() compares against phUSDAmount). The whole
    // point of the redeploy is to HAVE a cap, so a zero value here is a configuration error.
    uint256 public constant MAX_MINT_PER_DAY = 4000e18; // 4000 phUSD/token/day

    uint256 public constant CHAIN_ID = 1;

    // ==========================================
    //   RUNTIME STATE
    // ==========================================

    bool    public isPreview;
    address public newMinter;
    address public ysDolaV2;
    address public ysUsdcV2;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "DeployNewPhusdMinter: wrong chain - expected mainnet (1)");
    }

    function _preflight() internal {
        // --- Configuration Safety gate: refuse to broadcast with unsafe defaults ---
        require(MAX_MINT_PER_DAY > 0, "Config: MAX_MINT_PER_DAY is 0 (no limit) - the cap is the point");
        require(DOLA_RATE > 0 && USDC_RATE > 0, "Config: zero exchange rate");
        require(PHUSD != address(0), "Config: phUSD address unset");

        // V2 strategies must be live and non-zero.
        string memory raw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        ysDolaV2 = vm.parseJsonAddress(raw, ".ysDolaV2");
        ysUsdcV2 = vm.parseJsonAddress(raw, ".ysUsdcV2");
        require(ysDolaV2 != address(0), "Preflight: ysDolaV2 zero in deployments JSON");
        require(ysUsdcV2 != address(0), "Preflight: ysUsdcV2 zero in deployments JSON");
        require(ysDolaV2.code.length > 0, "Preflight: ysDolaV2 has no code");
        require(ysUsdcV2.code.length > 0, "Preflight: ysUsdcV2 has no code");

        // Owner alignment: this signer must own both the V2 strategies and the phUSD token,
        // otherwise setClient / setMinter will revert.
        require(
            ERC4626YieldStrategy(ysDolaV2).owner() == OWNER_ADDRESS,
            "Preflight: ysDolaV2 owner != OWNER_ADDRESS"
        );
        require(
            ERC4626YieldStrategy(ysUsdcV2).owner() == OWNER_ADDRESS,
            "Preflight: ysUsdcV2 owner != OWNER_ADDRESS"
        );
        require(
            IFlaxMinter(PHUSD).owner() == OWNER_ADDRESS,
            "Preflight: phUSD owner != OWNER_ADDRESS - cannot grant mint authority"
        );

        console.log("Preflight OK");
        console.log("  ysDolaV2:        ", ysDolaV2);
        console.log("  ysUsdcV2:        ", ysUsdcV2);
        console.log("  old minter canMint (pre-revoke, informational):",
            IFlaxMinter(PHUSD).authorizedMinters(OLD_MINTER).canMint);
    }

    function run() external {
        console.log("==========================================");
        console.log(" DeployNewPhusdMinter (story 065, step 2)");
        console.log("==========================================");
        console.log("Chain ID:       ", block.chainid);
        console.log("Owner (ledger): ", OWNER_ADDRESS);
        console.log("phUSD token:    ", PHUSD);
        console.log("");

        _preflight();

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***\n");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***\n");
            vm.startBroadcast();
        }

        // ---- 1. deploy fresh minter (d6ed115 build: has setMaxMintPerDay) ----
        PhusdStableMinter minter = new PhusdStableMinter(PHUSD);
        newMinter = address(minter);
        console.log("=== Deployed PhusdStableMinter ===");
        console.log("  newMinter:", newMinter);
        require(minter.phUSD() == PHUSD, "Deploy: minter.phUSD mismatch");

        // ---- 2. authorize the new minter as a client on each V2 strategy ----
        ERC4626YieldStrategy(ysDolaV2).setClient(newMinter, true);
        ERC4626YieldStrategy(ysUsdcV2).setClient(newMinter, true);
        console.log("  setClient(newMinter,true) on ysDolaV2 + ysUsdcV2");

        // ---- 3/4/5. register -> approve -> cap (cap AFTER register: footgun) ----
        _wireToken(minter, DOLA, ysDolaV2, DOLA_RATE, DOLA_DECIMALS);
        _wireToken(minter, USDC, ysUsdcV2, USDC_RATE, USDC_DECIMALS);

        // ---- 6. grant phUSD mint authority to the new minter ----
        IFlaxMinter(PHUSD).setMinter(newMinter, true);
        console.log("  IFlax.setMinter(newMinter, true)");

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
            vm.writeJson(vm.toString(newMinter), "script/migration-inputs/ys-swap-deployments.json", ".newMinter");
            console.log("  newMinter written to ys-swap-deployments.json");
        }

        _postVerify(minter);
        _printSummary();
    }

    function _wireToken(
        PhusdStableMinter minter,
        address token,
        address ys,
        uint256 rate,
        uint8 decimals
    ) internal {
        ERC4626YieldStrategy(ys).setClient(address(minter), true); // idempotent; already done in step 2 for these YS
        minter.registerStablecoin(token, ys, rate, decimals);      // sets enabled=true, zeroes cap
        minter.approveYS(token, ys);                               // max-approve YS to pull token from minter
        minter.setMaxMintPerDay(token, MAX_MINT_PER_DAY);          // AFTER register (footgun)
        console.log("  wired token (register+approve+cap):", token);
    }

    function _postVerify(PhusdStableMinter minter) internal view {
        // mint authority granted
        require(
            IFlaxMinter(PHUSD).authorizedMinters(address(minter)).canMint,
            "Verify: new minter lacks phUSD mint authority"
        );
        // DOLA wiring
        _verifyToken(minter, DOLA, ysDolaV2, DOLA_RATE, DOLA_DECIMALS);
        // USDC wiring
        _verifyToken(minter, USDC, ysUsdcV2, USDC_RATE, USDC_DECIMALS);
        console.log("=== Post-verify PASSED ===");
    }

    function _verifyToken(
        PhusdStableMinter minter,
        address token,
        address ys,
        uint256 rate,
        uint8 decimals
    ) internal view {
        PhusdStableMinter.StablecoinConfig memory c = minter.getStablecoinConfig(token);
        require(c.yieldStrategy == ys, "Verify: config.yieldStrategy != V2");
        require(c.exchangeRate == rate, "Verify: config.exchangeRate mismatch");
        require(c.decimals == decimals, "Verify: config.decimals mismatch");
        require(c.enabled, "Verify: config not enabled");
        require(c.maxMintPerDay == MAX_MINT_PER_DAY, "Verify: cap not set (footgun: cap before register?)");
        require(ERC4626YieldStrategy(ys).authorizedClients(address(minter)), "Verify: minter not authorized on V2");
        require(IERC20(token).allowance(address(minter), ys) == type(uint256).max, "Verify: minter->YS allowance not max");
    }

    function _printSummary() internal view {
        console.log("\n==========================================");
        console.log("  SUMMARY (story 065 step 2)");
        console.log("==========================================");
        console.log("new minter:      ", newMinter);
        console.log("DOLA cap (phUSD): ", MAX_MINT_PER_DAY);
        console.log("USDC cap (phUSD): ", MAX_MINT_PER_DAY);
        if (isPreview) {
            console.log("PREVIEW complete. No on-chain state changed.");
            console.log("NOTE: old minter NOT revoked here - that is Phase 3 (CutoverAndRevokeOldMinter).");
        } else {
            console.log("BROADCAST complete. newMinter recorded. Proceed to Phase 3 cutover.");
        }
        console.log("==========================================");
    }
}
