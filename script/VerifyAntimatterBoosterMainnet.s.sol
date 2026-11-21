// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {AntimatterBooster} from "antimatter/AntimatterBooster.sol";
import {
    AntimatterBoosterMainnetBase,
    IPhUSDBooster,
    IPauserV2Booster
} from "./helpers/AntimatterBoosterMainnetBase.sol";

/**
 * @title VerifyAntimatterBoosterMainnet  (story 139, sprint antimatter-boost) - READ-ONLY POST-BROADCAST VERIFIER
 * @notice No --broadcast, no --sender, no prank / deal / snapshot: reads LIVE mainnet and fails `verify: ...` on the
 *         first violated invariant. Chained at the end of `antimatter-booster:broadcast` (after the progress confirm,
 *         the book/PauserV2Registry patcher and `pauser-v2-verify`); re-run it any time as a health check.
 *
 *         The booster comes from the COMPLETED progress file (env ANTIMATTER_BOOSTER, if set, must agree). Asserts:
 *           - code; owner() == OWNER; antimatter / phUSD immutables == the book;
 *           - a LIVE phUSD minter (canMint at the current mintVersion), and mintVersion == 0;
 *           - tracked stables are exactly DOLA, USDC, USDe;
 *           - pauser() == PauserV2 and PauserV2.isRegistered(booster); not paused;
 *           - boostBps == 1_500;
 *           - OWNER is NOT a phUSD minter (`authorizedMinters(OWNER).canMint == false`);
 *           - book AntimatterBooster == booster.
 *         Then prints `previewBoost(stable, 1e18)` for each tracked stable (informational: eligibility is market state).
 *
 * Run: npm run antimatter-booster-verify
 */
contract VerifyAntimatterBoosterMainnet is AntimatterBoosterMainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY AntimatterBooster - MAINNET (story 139) - READ-ONLY");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "verify: wrong chain ID - expected Mainnet (1)");
        _requireBookMatchesConstants();

        address recorded = _progressBooster();
        require(
            recorded != address(0),
            "verify: no AntimatterBooster in progress.antimatter-booster.1.json - broadcast first"
        );
        require(
            _progressCompleted(), "verify: progress.antimatter-booster.1.json is not completed - run the confirm step"
        );
        address envBooster = vm.envOr("ANTIMATTER_BOOSTER", address(0));
        require(
            envBooster == address(0) || envBooster == recorded,
            "verify: ANTIMATTER_BOOSTER != the progress file's booster"
        );
        AntimatterBooster b = AntimatterBooster(recorded);
        console.log("AntimatterBooster:", recorded);

        require(recorded.code.length > 0, "verify: AntimatterBooster has no code");
        require(b.owner() == OWNER, "verify: owner() != OWNER");
        require(address(b.antimatter()) == ANTIMATTER, "verify: antimatter() != book Antimatter");
        require(address(b.phUSD()) == PHUSD, "verify: phUSD() != book PhUSD");
        require(IPhUSDBooster(PHUSD).mintVersion() == 0, "verify: phUSD mintVersion != 0");
        require(_isLivePhusdMinter(recorded), "verify: booster is not a live phUSD minter");
        require(b.trackedStables().length == 3, "verify: tracked stable count != 3");
        require(b.isTracked(DOLA) && b.isTracked(USDC) && b.isTracked(USDE), "verify: DOLA/USDC/USDe not all tracked");
        require(b.pauser() == PAUSER_V2, "verify: pauser() != PauserV2");
        require(IPauserV2Booster(PAUSER_V2).isRegistered(recorded), "verify: not registered with PauserV2");
        require(!b.paused(), "verify: AntimatterBooster is paused");
        require(b.boostBps() == BOOST_BPS, "verify: boostBps != 1_500");
        (bool ownerCanMint,) = IPhUSDBooster(PHUSD).authorizedMinters(OWNER);
        require(!ownerCanMint, "verify: OWNER is still a phUSD minter");
        require(
            _bookBooster() == recorded,
            "verify: address book AntimatterBooster != booster - run node scripts/patch-mainnet-addresses-antimatter-booster.js"
        );

        _printPreview(b, DOLA, "DOLA");
        _printPreview(b, USDC, "USDC");
        _printPreview(b, USDE, "USDe");
        console.log("VERIFY OK");
    }

    function _printPreview(AntimatterBooster b, address stable, string memory name) internal view {
        (bool ok, AntimatterBooster.Reason why, uint256 sQ, uint256 tQ, uint256 base, uint256 bonus) =
            b.previewBoost(stable, 1e18);
        console.log(string.concat("previewBoost(", name, ", 1 AM): eligible / reason"), ok, uint256(why));
        console.log("  stableQty18 / totalQty18:", sQ, tQ);
        console.log("  expectedBase / expectedBonus:", base, bonus);
    }
}
