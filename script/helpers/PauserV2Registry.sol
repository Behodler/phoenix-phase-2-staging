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
        a = new address[](3);
        a[0] = 0xE5983721f009AB57d464e611C9A06B148cEC3Acc; // NFTBonfire (story 129)
        a[1] = 0x9d69c68F354575B95c1ebf7E87DB85BF3BFF2cE8; // StableYieldAccumulator, gate-free (story 131)
        a[2] = 0xD41235bC400BAEDD23aA416Db1F62c944981C42a; // BatchNFTMinterNudgeDiscount (story 119)
    }

    /// @notice Migration-set or added contracts later retired with `PauserV2.unregister`.
    function postMigrationRemovals() public view virtual returns (address[] memory a) {
        a = new address[](2);
        a[0] = 0x0cD353bfda674D04823B2826ffafB83B560D21B6; // StableYieldAccumulator, retired (story 131)
        a[1] = 0x068395556b8c43eDf257DC54D109EA5910aE15c7; // BatchNFTMinterMultiToken, retired (story 119)
    }
}
