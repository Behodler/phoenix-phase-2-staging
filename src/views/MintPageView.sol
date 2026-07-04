// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPageView.sol";
// yield-claim-nft story-039 removed the V1 INFTMinter interface (V1 decommissioned). The view
// only reads `configs(index)`, which INFTMinterV2 exposes with the identical tuple shape.
import {INFTMinterV2 as INFTMinter} from "@yield-claim-nft/interfaces/INFTMinterV2.sol";
import {ITokenDispatcherV2} from "@yield-claim-nft/interfaces/ITokenDispatcherV2.sol";
import "@yield-claim-nft/BurnRecorder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title MintPageView
/// @notice IPageView implementation exposing NFT minting data for the mint page.
/// @dev Aggregates data for 6 NFTs across 4 dispatcher types, plus burn totals.
///
///      NFT Configuration (dispatcher index -> boosted/label token):
///        Index 1: EYE     - Uniboost (story-070; replaced the EYE Burner)
///        Index 2: SCX     - Uniboost (story-070; replaced the SCX Burner)
///        Index 3: Flax    - Uniboost (story-070; replaced the Flax Burner)
///        Index 4: USDS    - BalancerPoolerV2 (restored to index 4 by story-048 cutover)
///        Index 5: WBTC    - Gather
///        Index 6: (skipped) - disabled "bugged pooler" slot on mainnet (story-048); a
///                             disabled placeholder dispatcher mirrors it on Anvil so that
///                             dispatcher indices line up across networks. Not user-facing.
///        Index 7: USDC    - NudgeRatchet (story-068; underlying token is 6-decimal USDC)
///
///      MINT-TOKEN SOURCING: the per-token `allowance` and `balance` fields report the
///      user's position in each dispatcher's ACTUAL mint token, read live from
///      `dispatcher.primeToken()` — never a hardcoded label token. This is what keeps the
///      view correct across dispatcher reconfigurations. Post-story-070 the Uniboost
///      dispatchers at indices 1/2/3 charge USDC (their primeToken), not EYE/SCX/Flax, so
///      the "EYE/SCX/Flax" allowance/balance fields now report the user's USDC — which is
///      what actually gates the mint. Field NAMES are retained verbatim for ABI/consumer
///      stability; only the sourced values changed. Indices 4/5/7 are unaffected because
///      their primeToken already equals the label token (USDS/WBTC/USDC).
///
///      Burn totals (EYE/SCX/Flax) are read from BurnRecorder and retained for ABI
///      compatibility; because Uniboost does not burn, these now read 0 on Anvil.
///
///      Returns 39 fields total (6 per token + 3 burn totals). The ratchet entry reads
///      dispatcher index 7 to stay consistent with mainnet, where the disabled bugged
///      pooler permanently occupies index 6.
contract MintPageView is IPageView {
    INFTMinter public immutable nftMinter;
    BurnRecorder public immutable burnRecorder;

    /// @notice EYE/SCX/Flax token addresses. Still used to key the BurnRecorder burn-total
    ///         lookups (fields 36-38). No longer used for allowance/balance, which are now
    ///         sourced from each dispatcher's live `primeToken()` (see `_fillTokenData`).
    IERC20 public immutable eye;
    IERC20 public immutable scx;
    IERC20 public immutable flax;
    /// @notice Retained for constructor-ABI stability with the existing mainnet deploy
    ///         scripts. These no longer drive any field — allowance/balance for every slot
    ///         come from `dispatcher.primeToken()` — but removing them would change the
    ///         constructor signature callers rely on.
    IERC20 public immutable usds;
    IERC20 public immutable wbtc;
    /// @notice The NudgeRatchet's underlying token (6-decimal USDC). Maps to dispatcher index 7.
    IERC20 public immutable usdc;

    /// @notice Number of NFT configurations.
    uint256 private constant NUM_TOKENS = 6;
    /// @notice Fields per token: allowance, price, growthBasisPoints, balance, nftBalance, dispatcherIndex.
    uint256 private constant FIELDS_PER_TOKEN = 6;
    /// @notice Number of burn total fields (EYE, SCX, Flax only).
    uint256 private constant BURN_FIELDS = 3;
    /// @notice Total fields returned.
    uint256 private constant TOTAL_FIELDS = NUM_TOKENS * FIELDS_PER_TOKEN + BURN_FIELDS;

    constructor(
        INFTMinter _nftMinter,
        BurnRecorder _burnRecorder,
        address _eye,
        address _scx,
        address _flax,
        address _usds,
        address _wbtc,
        address _usdc
    ) {
        nftMinter = _nftMinter;
        burnRecorder = _burnRecorder;
        eye = IERC20(_eye);
        scx = IERC20(_scx);
        flax = IERC20(_flax);
        usds = IERC20(_usds);
        wbtc = IERC20(_wbtc);
        usdc = IERC20(_usdc);
    }

    function getNames() external pure returns (string[] memory names) {
        names = new string[](TOTAL_FIELDS);

        // EYE fields (index 0-5)
        names[0] = "EYE-allowance";
        names[1] = "EYE-price";
        names[2] = "EYE-growthBasisPoints";
        names[3] = "EYE-balance";
        names[4] = "EYE-nftBalance";
        names[5] = "EYE-dispatcherIndex";

        // SCX fields (index 6-11)
        names[6] = "SCX-allowance";
        names[7] = "SCX-price";
        names[8] = "SCX-growthBasisPoints";
        names[9] = "SCX-balance";
        names[10] = "SCX-nftBalance";
        names[11] = "SCX-dispatcherIndex";

        // Flax fields (index 12-17)
        names[12] = "Flax-allowance";
        names[13] = "Flax-price";
        names[14] = "Flax-growthBasisPoints";
        names[15] = "Flax-balance";
        names[16] = "Flax-nftBalance";
        names[17] = "Flax-dispatcherIndex";

        // USDS fields (index 18-23)
        names[18] = "USDS-allowance";
        names[19] = "USDS-price";
        names[20] = "USDS-growthBasisPoints";
        names[21] = "USDS-balance";
        names[22] = "USDS-nftBalance";
        names[23] = "USDS-dispatcherIndex";

        // WBTC fields (index 24-29)
        names[24] = "WBTC-allowance";
        names[25] = "WBTC-price";
        names[26] = "WBTC-growthBasisPoints";
        names[27] = "WBTC-balance";
        names[28] = "WBTC-nftBalance";
        names[29] = "WBTC-dispatcherIndex";

        // Ratchet fields (index 30-35) — NudgeRatchet dispatcher, USDC-denominated, index 7
        names[30] = "Ratchet-allowance";
        names[31] = "Ratchet-price";
        names[32] = "Ratchet-growthBasisPoints";
        names[33] = "Ratchet-balance";
        names[34] = "Ratchet-nftBalance";
        names[35] = "Ratchet-dispatcherIndex";

        // Burn totals (index 36-38)
        names[36] = "EYE-totalBurnt";
        names[37] = "SCX-totalBurnt";
        names[38] = "Flax-totalBurnt";
    }

    function getData(address user) external view returns (uint256[] memory data) {
        data = new uint256[](TOTAL_FIELDS);

        // EYE (dispatcher index 1 — Uniboost; mint token USDC via primeToken())
        _fillTokenData(data, 0, 1, user);

        // SCX (dispatcher index 2 — Uniboost; mint token USDC via primeToken())
        _fillTokenData(data, 6, 2, user);

        // Flax (dispatcher index 3 — Uniboost; mint token USDC via primeToken())
        _fillTokenData(data, 12, 3, user);

        // USDS (dispatcher index 4 — BalancerPoolerV2 restored to index 4 by the
        //                          story-048 cutover; the bugged index-6 pooler is disabled).
        _fillTokenData(data, 18, 4, user);

        // WBTC (dispatcher index 5)
        _fillTokenData(data, 24, 5, user);

        // Ratchet (dispatcher index 7 — NudgeRatchet. Index 6 is skipped because on
        //                          mainnet it is the permanently-disabled bugged pooler;
        //                          a disabled placeholder occupies index 6 on Anvil so the
        //                          ratchet lands at the same index 7 on every network).
        _fillTokenData(data, 30, 7, user);

        // Burn totals
        data[36] = burnRecorder.getTotalBurnt(address(eye));
        data[37] = burnRecorder.getTotalBurnt(address(scx));
        data[38] = burnRecorder.getTotalBurnt(address(flax));
    }

    /// @dev Fills 6 fields for the NFT at `dispatcherIndex`, starting at `offset` in `data`.
    ///      `allowance` and `balance` are read in the dispatcher's live `primeToken()` — the
    ///      token the user actually pays to mint — rather than a hardcoded per-index token, so
    ///      the fields stay correct across dispatcher reconfigurations (e.g. the story-070
    ///      Burner -> Uniboost swap, which moved the mint token at indices 1/2/3 to USDC).
    function _fillTokenData(uint256[] memory data, uint256 offset, uint256 dispatcherIndex, address user)
        internal
        view
    {
        // Dispatcher address (for the primeToken lookup), price, and growth. `disabled` unused.
        (address dispatcher, uint256 price, uint256 growthBasisPoints,) = nftMinter.configs(dispatcherIndex);

        // The token the user actually pays to mint this NFT (e.g. USDC for the Uniboost slots).
        IERC20 payToken = IERC20(ITokenDispatcherV2(dispatcher).primeToken());

        // Allowance of NFTMinter to spend the user's mint token
        data[offset] = payToken.allowance(user, address(nftMinter));

        data[offset + 1] = price;
        data[offset + 2] = growthBasisPoints;

        // User's mint-token balance
        data[offset + 3] = payToken.balanceOf(user);

        // User's NFT balance (tokenId == dispatcherIndex always)
        data[offset + 4] = IERC1155(address(nftMinter)).balanceOf(user, dispatcherIndex);

        // Dispatcher index
        data[offset + 5] = dispatcherIndex;
    }
}
