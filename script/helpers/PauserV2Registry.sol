// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PauserV2Registry  (audit run 49 L-07; re-additions: story 140, audit run 50 L-01 / run 61 pps61l2)
 * @notice The committed record of every PauserV2 registry change made AFTER the story-128 migration. The verifier
 *         (`VerifyPauserV2Migration`) treats the PauserV2 registry as the live set:
 *           live set = ((the migration's 18 `liveRegistrants()` ++ `postMigrationAdditions()`)
 *                       - `postMigrationRemovals()`)
 *                      ++ `postMigrationReadditions()`.
 *         Any script that calls `PauserV2.register` or `PauserV2.unregister` on mainnet (the NFTBonfire cutover,
 *         phStaging2:119's new minter, a retirement, a revival) MUST append the address here in the same change, or
 *         `npm run pauser-v2-verify` fails and names it.
 *
 *         Append only. Never delete an entry: an address that is added and later retired goes in both
 *         `postMigrationAdditions()` and `postMigrationRemovals()`.
 *
 *         Re-additions (retire, then deliberately revive). An address that a cutover retired (so it is in
 *         `postMigrationRemovals()`) and that the owner later re-registers on PauserV2 goes in
 *         `postMigrationReadditions()`. Its removal entry stays where it is (append only, history kept); the
 *         re-addition overrides it. Rules, enforced by the verifier:
 *           - a re-addition is ONLY for an address already in `postMigrationRemovals()` (a brand-new contract is a
 *             plain addition), and never for a `retiredRegistrants()` address (both revert `verify: ...`);
 *           - every re-added address must have `pauser() == PauserV2` and be registered on PauserV2.
 *         Out of scope: re-retiring an address that has been re-added (add -> remove -> re-add -> remove). One
 *         override list cannot express it; it needs its own design (an ordered event list or a count-based tally)
 *         before it is ever done on mainnet.
 *
 *         The three list bodies are rewritten by the `scripts/patch-mainnet-addresses-*.js` patchers: keep each body
 *         as `a = new address[](N);` plus `a[i] = 0x...; // label` lines only (no blank lines or other comments).
 */
abstract contract PauserV2Registry {
    /// @notice Contracts registered with PauserV2 after the migration (each with `pauser() == PauserV2`).
    function postMigrationAdditions() public view virtual returns (address[] memory a) {
        a = new address[](4);
        a[0] = 0xE5983721f009AB57d464e611C9A06B148cEC3Acc; // NFTBonfire (story 129)
        a[1] = 0x9d69c68F354575B95c1ebf7E87DB85BF3BFF2cE8; // StableYieldAccumulator, gate-free (story 131)
        a[2] = 0xD41235bC400BAEDD23aA416Db1F62c944981C42a; // BatchNFTMinterNudgeDiscount (story 119)
        a[3] = 0xbb8bF9C05160bB45A2ef920AfD09Bc4ab0258a2C; // AntimatterBooster (story 139)
    }

    /// @notice Migration-set or added contracts later retired with `PauserV2.unregister`.
    function postMigrationRemovals() public view virtual returns (address[] memory a) {
        a = new address[](2);
        a[0] = 0x0cD353bfda674D04823B2826ffafB83B560D21B6; // StableYieldAccumulator, retired (story 131)
        a[1] = 0x068395556b8c43eDf257DC54D109EA5910aE15c7; // BatchNFTMinterMultiToken, retired (story 119)
    }

    /// @notice Addresses in `postMigrationRemovals()` that were later deliberately re-registered on PauserV2 (each
    ///         with `pauser() == PauserV2`). Overrides the removal; see the contract NatSpec for the rules.
    function postMigrationReadditions() public view virtual returns (address[] memory a) {
        a = new address[](1);
        a[0] = 0x068395556b8c43eDf257DC54D109EA5910aE15c7; // BatchNFTMinterMultiToken, re-added 2026-11-19 (UI batch mints, nudge off) (story 140)
    }
}
