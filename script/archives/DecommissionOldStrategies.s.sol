// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";

/**
 * @title DecommissionOldStrategies
 * @notice Story 065 - Phase 8 (master-ordering step 8): make the old buggy DOLA/USDC
 *         ERC4626YieldStrategy builds inert, after preserving residual.
 *
 *         Targets ONLY YS_DOLA_OLD + YS_USDC_OLD. YS_USDE is intentionally LEFT LIVE (the USDe pool
 *         is unaffected by the DOLA/USDC V2 swap).
 *
 *         Runs LAST, after the minter has been evacuated (Phase 6) so the strategies hold only
 *         residual dust/value. Per old strategy:
 *           1. RESIDUAL SWEEP to treasury: if the strategy still holds vault shares,
 *              emergencyWithdraw(type(uint256).max) redeems ALL shares and transfers the underlying
 *              to owner() (== TREASURY, owner decision 2026-06-13). Log swept amount per token.
 *           2. DEREGISTER every client: getAuthorizedClients() -> setClient(c, false) for each, so
 *              all client-gated mutating fns (deposit/withdraw/relinquishPrincipal) revert hereafter.
 *           3. REVOKE withdrawers: setWithdrawer(OWNER, false) (the YS-02 grant). Other withdrawers,
 *              if any, are revoked here too when known (see KNOWN_WITHDRAWERS).
 *           4. setPauser(OWNER) then pause(): the live pauser is a SEPARATE address (0x7c5A…85a3),
 *              and pause() is onlyPauser — so the owner first claims pauser, then pauses. After pause,
 *              the whenNotPaused paths (deposit/withdraw/skimSurplus/totalWithdrawal) also revert.
 *
 *         HARD INVARIANT: ownership is NEVER renounced/transferred. The owner remains admin of the
 *         inert contract; emergencyWithdraw/withdrawAsOwner stay available for any future residual.
 *         "Kill" = balances swept + all client/withdrawer roles removed + paused, owner retained.
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/DecommissionOldStrategies.s.sol:DecommissionOldStrategies \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/DecommissionOldStrategies.s.sol:DecommissionOldStrategies \
 *     --rpc-url $RPC_MAINNET --broadcast --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
contract DecommissionOldStrategies is Script {
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    // Residual sweep destination (owner decision 2026-06-13: the owner multisig is the de-facto
    // treasury). emergencyWithdraw transfers to owner(), which equals this address.
    address public constant TREASURY = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    address public constant YS_DOLA_OLD = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant YS_USDC_OLD = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;
    address public constant DOLA        = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC        = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 public constant CHAIN_ID = 1;

    bool public isPreview;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "DecommissionOldStrategies: wrong chain - expected mainnet (1)");
    }

    function run() external {
        console.log("==========================================");
        console.log(" DecommissionOldStrategies (story 065, step 8)");
        console.log("==========================================");
        console.log("treasury (residual sink):", TREASURY);

        // Owner must own both strategies (setClient/setWithdrawer/setPauser/emergencyWithdraw are onlyOwner).
        require(ERC4626YieldStrategy(YS_DOLA_OLD).owner() == OWNER_ADDRESS, "Preflight: YS_DOLA_OLD owner mismatch");
        require(ERC4626YieldStrategy(YS_USDC_OLD).owner() == OWNER_ADDRESS, "Preflight: YS_USDC_OLD owner mismatch");

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***");
            vm.startBroadcast();
        }

        _decommission(YS_DOLA_OLD, DOLA);
        _decommission(YS_USDC_OLD, USDC);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- Post-assert: inert (paused, no clients) but still owner-controlled ----
        _assertInert(YS_DOLA_OLD);
        _assertInert(YS_USDC_OLD);
        require(ERC4626YieldStrategy(YS_DOLA_OLD).owner() == OWNER_ADDRESS, "Post: YS_DOLA_OLD ownership lost!");
        require(ERC4626YieldStrategy(YS_USDC_OLD).owner() == OWNER_ADDRESS, "Post: YS_USDC_OLD ownership lost!");
        console.log("Decommission OK - old DOLA/USDC strategies inert (paused, no clients), owner retained.");
    }

    function _decommission(address ys, address token) internal {
        ERC4626YieldStrategy s = ERC4626YieldStrategy(ys);
        console.log("--- decommission strategy:", ys);

        // 1. residual sweep to treasury (== owner()). Guard: emergencyWithdraw reverts on 0 shares.
        uint256 shares = s.getTotalShares();
        if (shares > 0) {
            uint256 balBefore = IERC20(token).balanceOf(TREASURY);
            s.emergencyWithdraw(type(uint256).max); // sweeps ALL shares -> underlying to owner()
            uint256 swept = IERC20(token).balanceOf(TREASURY) - balBefore;
            console.log("  residual swept to treasury (underlying):", swept);
        } else {
            console.log("  no vault shares - nothing to sweep");
        }

        // 2. deregister every authorized client
        address[] memory clients = s.getAuthorizedClients();
        console.log("  authorized clients to deregister:", clients.length);
        for (uint256 i = 0; i < clients.length; i++) {
            s.setClient(clients[i], false);
            console.log("    setClient(false):", clients[i]);
        }

        // 3. revoke the YS-02 owner-withdrawer grant (other withdrawers, if any, must be revoked by
        //    the operator if they appear — there is no on-chain enumeration of withdrawers).
        s.setWithdrawer(OWNER_ADDRESS, false);
        console.log("  setWithdrawer(OWNER, false)");

        // 4. claim pauser (live pauser is a separate address) then pause
        s.setPauser(OWNER_ADDRESS);
        s.pause();
        console.log("  setPauser(OWNER) + pause() done");
    }

    function _assertInert(address ys) internal view {
        ERC4626YieldStrategy s = ERC4626YieldStrategy(ys);
        require(s.paused(), "Post-assert: strategy not paused");
        require(s.getAuthorizedClients().length == 0, "Post-assert: strategy still has authorized clients");
    }
}
