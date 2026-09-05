// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";

/**
 * @title EvacuateAndReseedMinter
 * @notice Story 065 - Phase 6 (master-ordering step 6): evacuate the OLD minter's REMAINING
 *         position off each old strategy and re-seed it into the NEW minter's V2 position.
 *
 *         Runs AFTER: Phase 2 (new minter deployed), Phase 3 (old minter cut over / revoked),
 *         Phase 4 (staker shortfall already pulled from the minter's old-strategy allotment), and
 *         Phase 5 (staker migrated). At this point the OLD minter holds only its leftover position
 *         on YS_DOLA_OLD / YS_USDC_OLD.
 *
 *         Per token T, old strategy oldT, V2 strategy ysTV2:
 *           1. balBefore  = T.balanceOf(owner)
 *           2. p          = oldT.principalOf(T, OLD_MINTER)
 *           3. oldT.withdrawAsOwner(OLD_MINTER, owner, p)   (owner-gated; redeems backing shares,
 *              zeroes the old minter's principal; recovered may be < p if the autopool is below par)
 *           4. recovered  = T.balanceOf(owner) - balBefore
 *           5. T.approve(newMinter, recovered)              (noMintDeposit pulls from msg.sender)
 *           6. newMinter.noMintDeposit(ysTV2, T, recovered) (seed V2; NO new phUSD minted)
 *
 *         BELOW-PAR IS EXPECTED for the minter (it is the designated shock-absorber): if
 *         `recovered < p`, log a WARNING with recovered-vs-booked and DO NOT revert. The staker was
 *         already made whole in Phase 4; the minter knowingly eats the residual haircut.
 *
 *         Reads: script/migration-inputs/ys-swap-deployments.json (.newMinter, .ysDolaV2, .ysUsdcV2)
 *
 * PREVIEW:
 *   PREVIEW_MODE=true forge script script/EvacuateAndReseedMinter.s.sol:EvacuateAndReseedMinter \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * BROADCAST:
 *   forge script script/EvacuateAndReseedMinter.s.sol:EvacuateAndReseedMinter \
 *     --rpc-url $RPC_MAINNET --broadcast --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
contract EvacuateAndReseedMinter is Script {
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant OLD_MINTER    = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;

    address public constant DOLA          = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC          = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant YS_DOLA_OLD   = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant YS_USDC_OLD   = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;

    uint256 public constant CHAIN_ID = 1;

    bool    public isPreview;
    address public newMinter;
    address public ysDolaV2;
    address public ysUsdcV2;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "EvacuateAndReseedMinter: wrong chain - expected mainnet (1)");
    }

    function run() external {
        console.log("==========================================");
        console.log(" EvacuateAndReseedMinter (story 065, step 6)");
        console.log("==========================================");

        string memory raw = vm.readFile("script/migration-inputs/ys-swap-deployments.json");
        newMinter = vm.parseJsonAddress(raw, ".newMinter");
        ysDolaV2 = vm.parseJsonAddress(raw, ".ysDolaV2");
        ysUsdcV2 = vm.parseJsonAddress(raw, ".ysUsdcV2");
        require(newMinter != address(0) && newMinter.code.length > 0, "Preflight: .newMinter unset - Phase 2 first");
        require(ysDolaV2 != address(0) && ysUsdcV2 != address(0), "Preflight: V2 addresses zero");
        // The new minter must already be an authorized client on each V2 (Phase 2) for noMintDeposit.
        require(ERC4626YieldStrategy(ysDolaV2).authorizedClients(newMinter), "Preflight: newMinter not client on ysDolaV2");
        require(ERC4626YieldStrategy(ysUsdcV2).authorizedClients(newMinter), "Preflight: newMinter not client on ysUsdcV2");
        console.log("  newMinter:", newMinter);

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign ***");
            vm.startBroadcast();
        }

        _evacuate(DOLA, YS_DOLA_OLD, ysDolaV2);
        _evacuate(USDC, YS_USDC_OLD, ysUsdcV2);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        // ---- Post-assert: old minter principal zeroed on each old strategy ----
        require(ERC4626YieldStrategy(YS_DOLA_OLD).principalOf(DOLA, OLD_MINTER) == 0, "Post: old DOLA principal not zero");
        require(ERC4626YieldStrategy(YS_USDC_OLD).principalOf(USDC, OLD_MINTER) == 0, "Post: old USDC principal not zero");
        console.log("Evacuate + reseed OK - old minter position moved to new minter on V2.");
    }

    function _evacuate(address token, address oldYS, address ysV2) internal {
        uint256 booked = ERC4626YieldStrategy(oldYS).principalOf(token, OLD_MINTER);
        console.log("--- token:", token);
        console.log("  old minter booked principal:", booked);
        if (booked == 0) {
            console.log("  nothing to evacuate (booked == 0) - skip");
            return;
        }

        uint256 balBefore = IERC20(token).balanceOf(OWNER_ADDRESS);
        ERC4626YieldStrategy(oldYS).withdrawAsOwner(OLD_MINTER, OWNER_ADDRESS, booked);
        uint256 recovered = IERC20(token).balanceOf(OWNER_ADDRESS) - balBefore;
        console.log("  recovered to owner:", recovered);

        // Below-par is EXPECTED (minter is the shock-absorber). Log, do NOT revert.
        if (recovered < booked) {
            console.log("  WARNING: below-par recovery (accepted minter haircut). booked vs recovered:");
            console.log("    booked:   ", booked);
            console.log("    recovered:", recovered);
            console.log("    shortfall:", booked - recovered);
        }

        if (recovered == 0) {
            console.log("  recovered == 0 - nothing to re-seed; skip noMintDeposit");
            return;
        }

        uint256 v2Before = ERC4626YieldStrategy(ysV2).principalOf(token, newMinter);
        IERC20(token).approve(newMinter, recovered);
        PhusdStableMinter(newMinter).noMintDeposit(ysV2, token, recovered);
        uint256 v2After = ERC4626YieldStrategy(ysV2).principalOf(token, newMinter);
        console.log("  new minter V2 principal before/after:", v2Before, v2After);
        require(v2After > v2Before, "Re-seed: V2 principal did not increase");
    }
}
