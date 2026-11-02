// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {NFTBonfire} from "@yield-claim-nft/NFTBonfire.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {Pauser} from "@pauser/Pauser.sol";

/// @title  NFTBonfireLocalWiring
/// @notice Story 125. Deploys `NFTBonfire` (lib/yield-claim-nft, pin c5ad56d) and wires it in the
///         order audit run yield-claim-nft-23 mandates (L-29 / Q-27), with a loud `require`
///         read-back after every step:
///           1. NFTMinterV2.setAuthorizedBurner(bonfire, true)
///           2. Antimatter.setApprovedMinter(bonfire, true)   (silent no-op setter -> read-back essential)
///           3. bonfire.setPauser(pauser) THEN pauser.register(bonfire)
///           4. bonfire.setMaxPayout(MAX_PAYOUT)              (BEFORE the rate: the cap defaults to unlimited)
///           5. bonfire.setRatePerDay(RATE_PER_DAY)           (LAST: enables burning)
///         Pausing NFTMinterV2 does NOT stop bonfire burns (`NFTMinterV2.burn` has no pause check), so
///         the bonfire is registered with the global Pauser in its own right, and `setRatePerDay(0)`
///         is the owner's one-transaction stop.
///
///         Shared by `DeployMocks` (Phase 11.15, inside its broadcast) and
///         `test/NFTBonfireLocalWiring.t.sol`, so the forge test drives exactly the anvil wiring.
/// @dev    Internal functions, inlined into the caller like `SyaHarvesterLocalConfig`: every `new` and
///         every call is made by the calling contract (the broadcasting deployer in the script), so the
///         caller must own NFTMinterV2, Antimatter, Pauser, and is made owner of the bonfire.
library NFTBonfireLocalWiring {
    /// @dev The human's ask: a 10 antimatter/day top-up (Antimatter has 18 decimals).
    uint256 internal constant RATE_PER_DAY = 10e18;
    /// @dev The human's ask: a 100 antimatter maximum pot (10 days of accrual at RATE_PER_DAY).
    uint256 internal constant MAX_PAYOUT = 100e18;

    /// @notice Deploys an inert bonfire (rate 0, cap 0, pauser 0) owned by `owner`.
    function deploy(address owner, NFTMinterV2 nftMinter, Antimatter antimatter) internal returns (NFTBonfire bonfire) {
        bonfire = new NFTBonfire(owner, address(nftMinter), address(antimatter));
        require(address(bonfire.nftMinter()) == address(nftMinter), "story-125: bonfire nftMinter mismatch");
        require(address(bonfire.antimatter()) == address(antimatter), "story-125: bonfire antimatter mismatch");
        require(bonfire.ratePerDay() == 0, "story-125: bonfire must deploy inert (rate)");
        require(bonfire.maxPayout() == 0, "story-125: bonfire must deploy inert (cap)");
        require(bonfire.pauser() == address(0), "story-125: bonfire must deploy inert (pauser)");
    }

    /// @notice Grants and configures in the audit-mandated order. Burning goes live on the last call.
    function wire(NFTBonfire bonfire, NFTMinterV2 nftMinter, Antimatter antimatter, Pauser pauser) internal {
        // 1. Burner grant: NFTMinterV2 checks no holder approval, so the bonfire always burns from msg.sender.
        nftMinter.setAuthorizedBurner(address(bonfire), true);
        require(nftMinter.authorizedBurners(address(bonfire)), "story-125: bonfire is not an NFTMinterV2 burner");

        // 2. Minter grant. `setApprovedMinter` is a SILENT no-op on an unchanged value: read it back.
        antimatter.setApprovedMinter(address(bonfire), true);
        require(antimatter.isApprovedMinter(address(bonfire)), "story-125: bonfire is not an AM minter");

        // 3. Pauser BEFORE register: `Pauser.register` validates `pauser() == Pauser` (audit Q-27).
        bonfire.setPauser(address(pauser));
        pauser.register(address(bonfire));
        require(
            bonfire.pauser() == address(pauser) && pauser.isRegistered(address(bonfire)),
            "story-125: bonfire not wired to the global Pauser"
        );

        // 4. Cap BEFORE the rate (audit L-29): `maxPayout == 0` means unlimited.
        require(bonfire.ratePerDay() == 0, "story-125: rate must still be 0 when the cap is set");
        bonfire.setMaxPayout(MAX_PAYOUT);
        require(bonfire.maxPayout() == MAX_PAYOUT, "story-125: bonfire maxPayout not set");

        // 5. Rate LAST: this is the call that enables burning.
        bonfire.setRatePerDay(RATE_PER_DAY);
        require(bonfire.ratePerDay() == RATE_PER_DAY, "story-125: bonfire ratePerDay not set");
    }
}
