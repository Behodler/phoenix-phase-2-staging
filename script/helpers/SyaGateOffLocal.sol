// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";

/// @title  SyaGateOffLocal
/// @notice Story 130. Turns the StableYieldAccumulator NFT claim gate OFF (yield-accumulator:028:
///         `nftMinter == address(0)` means `claim()` skips the NFT check and burn and `canClaim` is
///         true for everyone), and revokes the SYA's now-unused burner right on NFTMinterV2.
///
///         Shared by `DeployMocks` (the terminal Phase 11.17, inside its broadcast) and
///         `test/SyaGateOffLocal.t.sol`, so the forge test drives exactly the anvil sequence.
/// @dev    Internal functions, inlined into the caller: every call is made by the calling contract
///         (the broadcasting deployer in the script), which must own both the SYA and NFTMinterV2.
///         Transactions only, no CREATE, so it never moves a deployment address.
library SyaGateOffLocal {
    /// @param sya          The SYA whose gate is currently set to `nftMinterV2` (Phase 8.7).
    /// @param nftMinterV2  The NFT minter the gate currently points at.
    /// @param probe        Any EOA that holds no claim NFT; `canClaim(probe)` must be true afterwards.
    function turnGateOff(IStableYieldAccumulator sya, NFTMinterV2 nftMinterV2, address probe) internal {
        require(sya.nftMinter() == address(nftMinterV2), "story-130: SYA gate is not set to NFTMinterV2");

        sya.setNFTMinter(address(0));
        require(sya.nftMinter() == address(0), "story-130: SYA nftMinter read-back is not zero");

        nftMinterV2.setAuthorizedBurner(address(sya), false);
        require(!nftMinterV2.authorizedBurners(address(sya)), "story-130: SYA still an authorized burner");

        require(sya.canClaim(probe), "story-130: canClaim(probe) must be true with the gate off");
    }
}
