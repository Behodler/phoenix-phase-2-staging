// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Pauser} from "@pauser/Pauser.sol";
import {PauserV2} from "@pauser/PauserV2.sol";
import {IPausable} from "@pauser/interfaces/IPausable.sol";

/// @dev Every Phoenix pausable exposes an owner-only `setPauser(address)`; it is not part of
///      `IPausable`, so it gets its own one-function interface here.
interface ISetPauserLocal {
    function setPauser(address newPauser) external;
}

/// @title  PauserV2LocalMigration
/// @notice Story 127. Rotates every live V1 `Pauser` registrant onto `PauserV2` and asserts the V2
///         end state. The registrant set is DERIVED from `v1.getPausableContracts()` minus the one
///         retired registrant (StableStaker V1), never hand-copied, so a registrant added to V1 by a
///         future phase is migrated automatically. V1 is left deployed and untouched: it keeps every
///         registration it had, so it is orphaned exactly as the mainnet V1 will be.
///
///         Shared by `DeployMocks` (Phase 11.16, inside its broadcast) and
///         `test/PauserV2LocalMigration.t.sol`, so the forge test drives exactly the anvil rotation.
/// @dev    Internal functions, inlined into the caller like `NFTBonfireLocalWiring`: every call is made
///         by the calling contract (the broadcasting deployer in the script), which must own every
///         registrant and `v2`. Each step is skipped when already done, so a re-run is a no-op.
library PauserV2LocalMigration {
    /// @notice setPauser(v2) THEN v2.register(c), for every V1 registrant except `retired`, in V1
    ///         registration order. `register` validates `pauser() == v2`, so the order is load-bearing.
    /// @return migrated The number of registrants now on V2 (V1 count minus the retired one).
    function migrate(Pauser v1, PauserV2 v2, address retired) internal returns (uint256 migrated) {
        require(v1.isRegistered(retired), "story-127: retired registrant is not on Pauser V1");

        address[] memory regs = v1.getPausableContracts();
        for (uint256 i = 0; i < regs.length; i++) {
            address c = regs[i];
            if (c == retired) continue;

            if (IPausable(c).pauser() != address(v2)) {
                ISetPauserLocal(c).setPauser(address(v2));
            }
            require(IPausable(c).pauser() == address(v2), "story-127: setPauser(PauserV2) did not take");
            if (!v2.isRegistered(c)) {
                v2.register(c);
            }
            migrated++;
        }

        requireMigrated(v1, v2, retired);
    }

    /// @notice The V2 registrant list equals V1's minus `retired`, element for element and in order,
    ///         and `retired` is not on V2.
    function requireMigrated(Pauser v1, PauserV2 v2, address retired) internal view {
        address[] memory regs = v1.getPausableContracts();
        address[] memory onV2 = v2.getPausableContracts();
        require(onV2.length + 1 == regs.length, "story-127: PauserV2 registrant count != V1 count - 1");
        require(!v2.isRegistered(retired), "story-127: retired registrant must stay off PauserV2");

        uint256 j;
        for (uint256 i = 0; i < regs.length; i++) {
            if (regs[i] == retired) continue;
            require(onV2[j] == regs[i], "story-127: PauserV2 registrant set/order differs from V1");
            j++;
        }
    }

    /// @notice `health()` reports nothing that would make `pause()` miss or revert: no registrant
    ///         with another pauser, none already paused, none unreachable. `noPausedGetter` is
    ///         informational (pause() still calls those) and is returned for logging.
    function requireHealthy(PauserV2 v2) internal view returns (uint256 noPausedGetterCount) {
        (
            address[] memory notPauser,
            address[] memory alreadyPaused,
            address[] memory noPausedGetter,
            address[] memory unreachable
        ) = v2.health();
        require(notPauser.length == 0, "story-127: PauserV2 health: notPauser is not empty");
        require(alreadyPaused.length == 0, "story-127: PauserV2 health: alreadyPaused is not empty");
        require(unreachable.length == 0, "story-127: PauserV2 health: unreachable is not empty");
        return noPausedGetter.length;
    }
}
