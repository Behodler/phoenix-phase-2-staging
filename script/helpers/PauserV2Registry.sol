// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PauserV2Registry  (audit run 49 L-07)
 * @notice The committed record of every PauserV2 registry change made AFTER the story-128 migration. The verifier
 *         (`VerifyPauserV2Migration`) treats the PauserV2 registry as the live set:
 *           live set = (the migration's 18 `liveRegistrants()` - `postMigrationRemovals()`) + `postMigrationAdditions()`.
 *         Any script that calls `PauserV2.register` or `PauserV2.unregister` on mainnet (the NFTBonfire cutover,
 *         phStaging2:119's new minter, a retirement) MUST append the address here in the same change, or
 *         `npm run pauser-v2-verify` fails and names it.
 *
 *         Append only. Never delete an entry: an address that is added and later retired goes in both lists.
 */
abstract contract PauserV2Registry {
    /// @notice Contracts registered with PauserV2 after the migration (each with `pauser() == PauserV2`).
    function postMigrationAdditions() public view virtual returns (address[] memory a) {
        a = new address[](1);
        a[0] = 0xE5983721f009AB57d464e611C9A06B148cEC3Acc; // NFTBonfire (story 129)
    }

    /// @notice Migration-set or added contracts later retired with `PauserV2.unregister`.
    function postMigrationRemovals() public view virtual returns (address[] memory a) {
        a = new address[](0);
    }
}
