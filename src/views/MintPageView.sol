// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPageView.sol";
import "@yield-claim-nft/interfaces/INFTMinter.sol";
import "@yield-claim-nft/BurnRecorder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title MintPageView
/// @notice IPageView implementation exposing NFT minting data for the mint page.
/// @dev Aggregates data for 6 NFTs across 4 dispatcher types, plus burn totals.
///
///      NFT Configuration (hardcoded):
///        Index 1: EYE     - Burner
///        Index 2: SCX     - Burner
///        Index 3: Flax    - Burner
///        Index 4: USDS    - BalancerPoolerV2 (restored to index 4 by story-048 cutover)
///        Index 5: WBTC    - Gather
///        Index 6: (skipped) - disabled "bugged pooler" slot on mainnet (story-048); a
///                             disabled placeholder dispatcher mirrors it on Anvil so that
///                             dispatcher indices line up across networks. Not user-facing.
///        Index 7: USDC    - NudgeRatchet (story-068; underlying token is 6-decimal USDC)
///
///      Returns 39 fields total (6 per token + 3 burn totals). The ratchet entry reads
///      dispatcher index 7 to stay consistent with mainnet, where the disabled bugged
///      pooler permanently occupies index 6.
contract MintPageView is IPageView {
    INFTMinter public immutable nftMinter;
    BurnRecorder public immutable burnRecorder;

    IERC20 public immutable eye;
    IERC20 public immutable scx;
    IERC20 public immutable flax;
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

        // EYE (dispatcher index 1)
        _fillTokenData(data, 0, eye, 1, user);

        // SCX (dispatcher index 2)
        _fillTokenData(data, 6, scx, 2, user);

        // Flax (dispatcher index 3)
        _fillTokenData(data, 12, flax, 3, user);

        // USDS (dispatcher index 4 — BalancerPoolerV2 restored to index 4 by the
        //                          story-048 cutover; the bugged index-6 pooler is disabled).
        _fillTokenData(data, 18, usds, 4, user);

        // WBTC (dispatcher index 5)
        _fillTokenData(data, 24, wbtc, 5, user);

        // Ratchet (dispatcher index 7 — NudgeRatchet. Index 6 is skipped because on
        //                          mainnet it is the permanently-disabled bugged pooler;
        //                          a disabled placeholder occupies index 6 on Anvil so the
        //                          ratchet lands at the same index 7 on every network).
        _fillTokenData(data, 30, usdc, 7, user);

        // Burn totals
        data[36] = burnRecorder.getTotalBurnt(address(eye));
        data[37] = burnRecorder.getTotalBurnt(address(scx));
        data[38] = burnRecorder.getTotalBurnt(address(flax));
    }

    /// @dev Fills 6 fields for a given token starting at `offset` in the data array.
    function _fillTokenData(uint256[] memory data, uint256 offset, IERC20 token, uint256 dispatcherIndex, address user)
        internal
        view
    {
        // Allowance of NFTMinter to spend user's token
        data[offset] = token.allowance(user, address(nftMinter));

        // Price and growthBasisPoints from config
        (, uint256 price, uint256 growthBasisPoints,) = nftMinter.configs(dispatcherIndex);
        data[offset + 1] = price;
        data[offset + 2] = growthBasisPoints;

        // User's token balance
        data[offset + 3] = token.balanceOf(user);

        // User's NFT balance (tokenId == dispatcherIndex always)
        data[offset + 4] = IERC1155(address(nftMinter)).balanceOf(user, dispatcherIndex);

        // Dispatcher index
        data[offset + 5] = dispatcherIndex;
    }
}
