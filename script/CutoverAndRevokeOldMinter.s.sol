// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title CutoverAndRevokeOldMinter
 * @notice Story 065 - Phase 3 (master-ordering step 3): cut the mint flow over to the new minter
 *         and revoke the old 4-field minter (0x435B…77E5) so no new collateral can land in the
 *         old buggy strategies.
 *
 *         Runs AFTER DeployNewPhusdMinter (Phase 2). Order within step 3:
 *           (off-chain, BEFORE this broadcast) repoint every old-minter REFERENCE to the new minter:
 *             - in-repo  server/deployments/mainnet-addresses.ts `PhusdStableMinter` field
 *               (handled by scripts/patch-mainnet-addresses-phusd-minter-replace.js post-broadcast)
 *             - phoenix-ui repo `mainnet-addresses.ts` (OUTSIDE this worktree — operator must edit
 *               + redeploy the UI; flagged as Q-REFS). There are no on-chain CONTRACT callers of
 *               minter.mint() — minting is user-facing only.
 *           (on-chain, this script):
 *             1. IFlax(phUSD).setMinter(OLD_MINTER, false)            (revoke mint authority)
 *             2. YS_DOLA_OLD.setClient(OLD_MINTER, false)             (deauthorize on old strategy)
 *             3. YS_USDC_OLD.setClient(OLD_MINTER, false)
 *
 *         The old minter can no longer mint (phUSD.mint reverts: not an authorized minter) nor
 *         deposit into the old strategies (deposit is onlyAuthorizedClient). Its EXISTING position
 *         on the old strategies is untouched here and is evacuated by the owner in Phase 6
 *         (withdrawAsOwner is owner-gated, so deauthorizing the client does not block evacuation).
 *
 *         Reads: script/migration-inputs/ys-swap-deployments.json (.newMinter from Phase 2)
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/CutoverAndRevokeOldMinter.s.sol:CutoverAndRevokeOldMinter \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/CutoverAndRevokeOldMinter.s.sol:CutoverAndRevokeOldMinter \
 *     --rpc-url $RPC_MAINNET --broadcast --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */

/// @dev Minimal phUSD (Flax) mint-authority surface.
interface IFlaxMinter {
    struct MinterInfo {
        bool canMint;
        uint256 mintVersion;
    }
    function setMinter(address minter, bool canMint) external;
    function authorizedMinters(address minter) external view returns (MinterInfo memory);
}

contract CutoverAndRevokeOldMinter is Script {
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant PHUSD         = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant OLD_MINTER    = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;

    address public constant DOLA          = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC          = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant YS_DOLA_OLD   = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant YS_USDC_OLD   = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;

    uint256 public constant CHAIN_ID = 1;

    bool public isPreview;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "CutoverAndRevokeOldMinter: wrong chain - expected mainnet (1)");
    }

    function run() external {
        console.log("==========================================");
        console.log(" CutoverAndRevokeOldMinter (story 065, step 3)");
        console.log("==========================================");

        // ---- Preflight: the NEW minter must be fully stood up before we cut the old one off ----
        string memory raw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        address newMinter = vm.parseJsonAddress(raw, ".newMinter");
        address ysDolaV2 = vm.parseJsonAddress(raw, ".ysDolaV2");
        address ysUsdcV2 = vm.parseJsonAddress(raw, ".ysUsdcV2");
        require(newMinter != address(0), "Preflight: .newMinter zero - run DeployNewPhusdMinter (Phase 2) first");
        require(newMinter.code.length > 0, "Preflight: newMinter has no code");
        require(
            IFlaxMinter(PHUSD).authorizedMinters(newMinter).canMint,
            "Preflight: new minter lacks mint authority - Phase 2 incomplete; refusing to revoke old"
        );
        require(
            PhusdStableMinter(newMinter).getStablecoinConfig(DOLA).yieldStrategy == ysDolaV2,
            "Preflight: new minter DOLA not pointed at ysDolaV2"
        );
        require(
            PhusdStableMinter(newMinter).getStablecoinConfig(USDC).yieldStrategy == ysUsdcV2,
            "Preflight: new minter USDC not pointed at ysUsdcV2"
        );
        require(
            IFlaxMinter(PHUSD).authorizedMinters(OLD_MINTER).canMint,
            "Preflight: old minter already lacks mint authority (already cut over?) - nothing to revoke"
        );
        console.log("Preflight OK - new minter live; old minter still authorized (will revoke)");
        console.log("  newMinter:", newMinter);

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***");
            vm.startBroadcast();
        }

        // 1. revoke mint authority on phUSD
        IFlaxMinter(PHUSD).setMinter(OLD_MINTER, false);
        // 2/3. deauthorize old minter as client on the OLD strategies (no new collateral lands there)
        ERC4626YieldStrategy(YS_DOLA_OLD).setClient(OLD_MINTER, false);
        ERC4626YieldStrategy(YS_USDC_OLD).setClient(OLD_MINTER, false);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- Post-assert ----
        require(
            !IFlaxMinter(PHUSD).authorizedMinters(OLD_MINTER).canMint,
            "Post-assert: old minter still has mint authority"
        );
        require(
            !ERC4626YieldStrategy(YS_DOLA_OLD).authorizedClients(OLD_MINTER),
            "Post-assert: old minter still a client on YS_DOLA_OLD"
        );
        require(
            !ERC4626YieldStrategy(YS_USDC_OLD).authorizedClients(OLD_MINTER),
            "Post-assert: old minter still a client on YS_USDC_OLD"
        );
        console.log("Cutover OK - old minter mint authority + client status revoked.");
        console.log("  old minter mint() now reverts (phUSD.mint: not authorized).");
        if (!isPreview) {
            console.log("NEXT: run scripts/patch-mainnet-addresses-phusd-minter-replace.js to repoint the");
            console.log("      in-repo mainnet-addresses.ts, and edit/redeploy the phoenix-ui mainnet-addresses.ts (Q-REFS).");
        }
    }
}
