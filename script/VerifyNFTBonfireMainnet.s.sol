// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {NFTBonfire} from "@yield-claim-nft/NFTBonfire.sol";
import {
    NFTBonfireMainnetBase,
    INFTMinterV2Bonfire,
    IAntimatterBonfire,
    IPauserV2Bonfire
} from "./helpers/NFTBonfireMainnetBase.sol";

/**
 * @title VerifyNFTBonfireMainnet  (story 129, sprint nft-bonfire) - READ-ONLY POST-BROADCAST VERIFIER
 * @notice No --broadcast, no --sender, no prank / deal / snapshot: reads LIVE mainnet and fails `verify: ...` on the
 *         first violated invariant. Chained at the end of `nft-bonfire:broadcast` (after the progress confirm and the
 *         book/PauserV2Registry patcher and `pauser-v2-verify`); re-run it any time as a health check.
 *
 *         The bonfire comes from the COMPLETED progress file (env NFT_BONFIRE, if set, must agree). Asserts:
 *           - owner() == OWNER; nftMinter / antimatter immutables == the book's NFTMinter / Antimatter;
 *           - ratePerDay == 10e18, maxPayout == 100e18;
 *           - pauser() == PauserV2 (== book Pauser), PauserV2.isRegistered(bonfire), not paused;
 *           - NFTMinterV2.authorizedBurners(bonfire), Antimatter.isApprovedMinter(bonfire);
 *           - book NFTBonfire == bonfire.
 *
 * Run: npm run nft-bonfire-verify
 */
contract VerifyNFTBonfireMainnet is NFTBonfireMainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY NFTBonfire - MAINNET (story 129) - READ-ONLY");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "verify: wrong chain ID - expected Mainnet (1)");
        _requireBookMatchesConstants();

        address recorded = _progressBonfire();
        require(recorded != address(0), "verify: no NFTBonfire in progress.nft-bonfire.1.json - broadcast first");
        require(_progressCompleted(), "verify: progress.nft-bonfire.1.json is not completed - run the confirm step");
        address envBonfire = vm.envOr("NFT_BONFIRE", address(0));
        require(
            envBonfire == address(0) || envBonfire == recorded, "verify: NFT_BONFIRE != the progress file's NFTBonfire"
        );
        NFTBonfire b = NFTBonfire(recorded);
        console.log("NFTBonfire:", recorded);

        require(recorded.code.length > 0, "verify: NFTBonfire has no code");
        require(b.owner() == OWNER, "verify: owner() != OWNER");
        require(address(b.nftMinter()) == NFT_MINTER, "verify: nftMinter() != book NFTMinter");
        require(address(b.antimatter()) == ANTIMATTER, "verify: antimatter() != book Antimatter");
        require(b.ratePerDay() == RATE_PER_DAY, "verify: ratePerDay != 10e18");
        require(b.maxPayout() == MAX_PAYOUT, "verify: maxPayout != 100e18");
        require(b.pauser() == PAUSER_V2, "verify: pauser() != PauserV2");
        require(IPauserV2Bonfire(PAUSER_V2).isRegistered(recorded), "verify: not registered with PauserV2");
        require(!b.paused(), "verify: NFTBonfire is paused");
        require(INFTMinterV2Bonfire(NFT_MINTER).authorizedBurners(recorded), "verify: not an NFTMinterV2 burner");
        require(IAntimatterBonfire(ANTIMATTER).isApprovedMinter(recorded), "verify: not an approved Antimatter minter");
        require(
            _bookBonfire() == recorded,
            "verify: address book NFTBonfire != bonfire - run node scripts/patch-mainnet-addresses-nft-bonfire.js"
        );
        console.log("VERIFY OK");
    }
}
