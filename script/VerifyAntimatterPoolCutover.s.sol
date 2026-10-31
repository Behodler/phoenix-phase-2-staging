// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";
import {
    AntimatterPoolMainnetBase,
    IAmCutoverAntimatter,
    IAmCutoverFactory,
    IAmCutoverPair
} from "./CutoverAntimatterPoolMainnet.s.sol";
import {IPausableLike, IPauserRegistry} from "./CutoverStableStakerV2Mainnet.s.sol";

/**
 * @title VerifyAntimatterPoolCutover  (story 122, Script B verifier)
 * @notice READ-ONLY on-chain verifier for the Antimatter/sUSDS cutover: no --broadcast, no --sender, no prank/deal.
 *
 *         WHICH ADDRESSES. The progress file `server/deployments/progress.antimatter-pool.1.json` and the
 *         `AntimatterPoolSeeder` / `AntimatterSusdsPair` keys of `mainnet-addresses.ts`. Whichever is non-zero is
 *         used per key; when both are, they must agree.
 *
 *         LIVE CHECKS (durable state, required): seeder owner and immutables; the seeder holds none of phUSD,
 *         Antimatter, sUSDS, phUSD/sUSDS LP or AM/sUSDS LP; the seeder is NOT an approved Antimatter minter; the
 *         pair is `factory.getPair(AM, sUSDS)` and `seeder.amSusdsPair()`; both reserves are non-zero; OWNER holds
 *         AM/sUSDS LP. Story 124: StableStakerV2 is RESTORED after the freeze - `paused() == false`,
 *         `pauser() == Pauser`, `Pauser.isRegistered(SSV2)` - and the registrant sweep passes (every Pauser registrant
 *         unpaused with `pauser == Pauser`, so the global breaker is live).
 *
 *         RECORDED CHECKS (required). Supplies, reserves and the pooler's LP keep moving after the cutover (AM is
 *         minted by StableStakerV2, phUSD by its minters, the pair trades, UniPoolerV2 pools), so the exact
 *         "phUSD supply fell by exactly the AM minted" family cannot be re-read later. The cutover script asserts
 *         them in-run, in the same block as the seed, and records the numbers; this verifier requires the record
 *         to be internally consistent (phUSD burned == AM minted == AM supply rise == pair AM reserve at seed).
 *         Drift since the cutover (current AM reserve, OWNER LP vs recorded liquidity) is logged, not required.
 *
 * Usage: npm run antimatter-pool:verify
 */
contract VerifyAntimatterPoolCutover is AntimatterPoolMainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY Antimatter/sUSDS cutover - MAINNET (story 122, Script B)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        Config memory c = expectedConfig();
        _preflight(c);
        Progress memory p = _readProgress();

        address seederAddr = _pick(p.seeder, _bookKey("AntimatterPoolSeeder"), "AntimatterPoolSeeder");
        address pairAddr = _pick(p.amPair, _bookKey("AntimatterSusdsPair"), "AntimatterSusdsPair");
        require(seederAddr != address(0), "verify: no AntimatterPoolSeeder address - broadcast first");
        require(pairAddr != address(0), "verify: no AntimatterSusdsPair address - broadcast first");

        AntimatterPoolSeeder seeder = AntimatterPoolSeeder(seederAddr);
        _checkSeeder(seeder, c);
        require(
            pairAddr == IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS),
            "verify: AntimatterSusdsPair != factory.getPair(AM, sUSDS)"
        );
        require(seeder.amSusdsPair() == pairAddr, "verify: seeder.amSusdsPair() != AntimatterSusdsPair");
        _requireSeederEmpty(seeder, c, pairAddr);
        require(
            !IAmCutoverAntimatter(c.antimatter).isApprovedMinter(seederAddr),
            "verify: seeder is STILL an approved Antimatter minter - revoke it"
        );
        (uint112 r0, uint112 r1,) = IAmCutoverPair(pairAddr).getReserves();
        require(r0 > 0 && r1 > 0, "verify: AM/sUSDS reserves are zero");
        uint256 ownerLp = IERC20(pairAddr).balanceOf(OWNER);
        require(ownerLp > 0, "verify: OWNER holds no AM/sUSDS LP");
        console.log("OK live: seeder", seederAddr);
        console.log("         pair  ", pairAddr);
        console.log("         seeder owner/immutables, empty, not an AM minter; canonical pair; OWNER holds LP");

        // Story 124: B's Step 10 (or the unfreeze key) restored SSV2 after the M-02 freeze.
        IPausableLike ssv2 = IPausableLike(c.stableStakerV2);
        require(!ssv2.paused(), "verify: StableStakerV2 is still PAUSED - B's Step 10 restore did not land");
        require(ssv2.pauser() == c.pauser, "verify: StableStakerV2 pauser != Pauser - B's Step 10 restore did not land");
        require(
            IPauserRegistry(c.pauser).isRegistered(c.stableStakerV2),
            "verify: StableStakerV2 is NOT registered with Pauser - B's Step 10 restore did not land"
        );
        _requireRegistrantsPausable(c, "verify: ");
        console.log("OK SSV2: unpaused, pauser == Pauser, registered; every registrant pausable");

        if (p.seeded) {
            require(p.lpAmount > 0 && p.amMinted > 0, "verify: progress seed record is empty");
            require(p.phusdSupplyBefore - p.phusdSupplyAfter == p.amMinted, "verify: record: phUSD burned != AM minted");
            require(p.amSupplyAfter - p.amSupplyBefore == p.amMinted, "verify: record: AM supply rise != AM minted");
            require(p.amReserve == p.amMinted, "verify: record: pair AM reserve at seed != AM minted");
            console.log("OK record: LP slice", p.lpAmount);
            console.log("           AM minted == phUSD burned", p.amMinted);
            console.log("           AM/sUSDS LP minted to OWNER", p.liquidity);
            console.log("           UniPoolerV2 LP before / after", p.poolerLpBefore, p.poolerLpAfter);
            console.log("  drift: current pair AM reserve", _amReserve(pairAddr, c.antimatter));
            console.log("  drift: current OWNER AM/sUSDS LP", ownerLp);
        } else {
            console.log("NOTE: no seed record in the progress file (address-book-only verification).");
        }
    }

    function _pick(address fromProgress, address fromBook, string memory key) internal pure returns (address) {
        if (fromProgress != address(0) && fromBook != address(0)) {
            require(
                fromProgress == fromBook,
                string.concat("verify: progress file and mainnet-addresses.ts disagree on ", key)
            );
        }
        return fromBook != address(0) ? fromBook : fromProgress;
    }

    /// @dev `virtual` only so fork tests pinned before the broadcast can stand in the zero placeholders.
    function _bookKey(string memory key) internal view virtual returns (address) {
        return _bookAddress(vm.readFile(ADDRESS_BOOK), key);
    }
}
