// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////////////////////
                          MIGRATE SAGA 2 — STEP 2.4 (RESCUE)
//////////////////////////////////////////////////////////////////////////////

Non-time-critical cleanup, split out of saga 2.2 (MigrateSaga2Migrate.s.sol). It refunds the
InPlaceMigrator's leftover DOLA/USDC allotment (the surplus that funded migrateIn's top-ups but was
not consumed) back to the deployer/owner.

WHY THIS IS A SEPARATE SCRIPT:
  saga 2.2 is a multi-tx broadcast. forge runs the script once to simulate, then bakes each external
  call's concrete calldata and broadcasts them in order. The migrator's rescueERC20(token, to, amount)
  enforces `amount <= balanceOf(this) - totalParked[token]` with ZERO tolerance. Inside 2.2 the rescue
  amount would be baked from the simulated post-migrateIn balance, but migrateIn's surplus-funded
  top-up gross-up (Math.mulDiv) reads the live strategy haircut/rate, which ticks between forge's
  simulation block and the broadcast block — so the real leftover ends up a few wei BELOW the baked
  amount and rescueERC20 reverts ("cannot touch parked principal"). The migrator is live & immutable
  on mainnet, so we cannot add an on-chain sweep function.

  Run as its own single-purpose broadcast, the amount is read from the LIVE balance and sent within the
  same block window with nothing mutating the migrator's balance in between, so baked == live and the
  sweep lands exactly. Run this AFTER saga 2.2 has settled.

No contracts are deployed here, so mainnet-addresses.ts is NOT touched by this step.
*/

contract MigrateSaga2Rescue is Script {
    uint256 public constant CHAIN_ID = 1;

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant DOLA          = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC          = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    string public constant DEPLOYMENTS_JSON = "script/migration-inputs/saga2-deployments.json";

    bool public isPreview;
    address public migrator;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "saga2.4: wrong chain - expected mainnet (1)");
    }

    function run() external {
        isPreview = vm.envOr("PREVIEW_MODE", false);

        string memory raw = vm.readFile(DEPLOYMENTS_JSON);
        migrator = vm.parseJsonAddress(raw, ".migrator");
        require(migrator != address(0), "saga2.4: migrator missing from deployments JSON");
        require(IMigrator(migrator).owner() == OWNER_ADDRESS, "saga2.4: not migrator owner");

        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE ***");
            vm.startBroadcast();
        }

        _rescue(DOLA);
        _rescue(USDC);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _postAssert();
    }

    /// @dev Sweep the rescuable surplus (live balance above the parked floor) to the owner. Reading the
    ///      LIVE balance here — not a value carried over from 2.2 — is the whole point of the split.
    function _rescue(address token) internal {
        uint256 parked = IMigrator(migrator).totalParked(token);
        uint256 balance = IERC20(token).balanceOf(migrator);
        require(balance >= parked, "saga2.4: balance below parked floor");
        uint256 surplus = balance - parked; // exactly what rescueERC20 permits (amount <= balance - parked)
        if (surplus == 0) {
            console.log("rescue skipped (no surplus) for token:", token);
            return;
        }
        IMigrator(migrator).rescueERC20(token, OWNER_ADDRESS, surplus);
        console.log("rescued surplus to owner. token / amount:", token, surplus);
    }

    function _postAssert() internal view {
        // After the sweep the migrator holds exactly its parked floor (0 once 2.2's migrateIn completed).
        require(
            IERC20(DOLA).balanceOf(migrator) == IMigrator(migrator).totalParked(DOLA),
            "post: DOLA surplus not fully rescued"
        );
        require(
            IERC20(USDC).balanceOf(migrator) == IMigrator(migrator).totalParked(USDC),
            "post: USDC surplus not fully rescued"
        );
        console.log("==========================================");
        console.log("  SAGA 2.4 (rescue) post-asserts passed");
        console.log("==========================================");
    }
}

// ───────────────────────────── minimal interfaces ─────────────────────────────

interface IMigrator {
    function owner() external view returns (address);
    function totalParked(address token) external view returns (uint256);
    function rescueERC20(address token, address to, uint256 amount) external;
}
