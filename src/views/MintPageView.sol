// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPageView.sol";
import "@yield-claim-nft/interfaces/INFTMinter.sol";
import "@yield-claim-nft/BurnRecorder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title MintPageView
/// @notice IPageView implementation exposing NFT minting data for the mint page.
/// @dev Aggregates data for 5 NFTs across 3 dispatcher types, plus burn totals.
///
///      NFT Configuration (hardcoded):
///        Index 1: EYE   - Burner
///        Index 2: SCX   - Burner
///        Index 3: Flax  - Burner
///        Index 4: sUSDS - BalancerPooler
///        Index 5: WBTC  - Gather
///
///      Returns 28 fields total (5 per token + 3 burn totals).
contract MintPageView is IPageView {
    INFTMinter public immutable nftMinter;
    BurnRecorder public immutable burnRecorder;

    IERC20 public immutable eye;
    IERC20 public immutable scx;
    IERC20 public immutable flax;
    IERC20 public immutable susds;
    IERC20 public immutable wbtc;

    /// @notice Number of NFT configurations.
    uint256 private constant NUM_TOKENS = 5;
    /// @notice Fields per token: allowance, price, growthBasisPoints, balance, nftBalance.
    uint256 private constant FIELDS_PER_TOKEN = 5;
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
        address _susds,
        address _wbtc
    ) {
        nftMinter = _nftMinter;
        burnRecorder = _burnRecorder;
        eye = IERC20(_eye);
        scx = IERC20(_scx);
        flax = IERC20(_flax);
        susds = IERC20(_susds);
        wbtc = IERC20(_wbtc);
    }

    function getNames() external pure returns (string[] memory names) {
        names = new string[](TOTAL_FIELDS);

        // EYE fields (index 0-4)
        names[0] = "EYE-allowance";
        names[1] = "EYE-price";
        names[2] = "EYE-growthBasisPoints";
        names[3] = "EYE-balance";
        names[4] = "EYE-nftBalance";

        // SCX fields (index 5-9)
        names[5] = "SCX-allowance";
        names[6] = "SCX-price";
        names[7] = "SCX-growthBasisPoints";
        names[8] = "SCX-balance";
        names[9] = "SCX-nftBalance";

        // Flax fields (index 10-14)
        names[10] = "Flax-allowance";
        names[11] = "Flax-price";
        names[12] = "Flax-growthBasisPoints";
        names[13] = "Flax-balance";
        names[14] = "Flax-nftBalance";

        // sUSDS fields (index 15-19)
        names[15] = "sUSDS-allowance";
        names[16] = "sUSDS-price";
        names[17] = "sUSDS-growthBasisPoints";
        names[18] = "sUSDS-balance";
        names[19] = "sUSDS-nftBalance";

        // WBTC fields (index 20-24)
        names[20] = "WBTC-allowance";
        names[21] = "WBTC-price";
        names[22] = "WBTC-growthBasisPoints";
        names[23] = "WBTC-balance";
        names[24] = "WBTC-nftBalance";

        // Burn totals (index 25-27)
        names[25] = "EYE-totalBurnt";
        names[26] = "SCX-totalBurnt";
        names[27] = "Flax-totalBurnt";
    }

    function getData(address user) external view returns (uint256[] memory data) {
        data = new uint256[](TOTAL_FIELDS);

        // EYE (dispatcher index 1)
        _fillTokenData(data, 0, eye, 1, user);

        // SCX (dispatcher index 2)
        _fillTokenData(data, 5, scx, 2, user);

        // Flax (dispatcher index 3)
        _fillTokenData(data, 10, flax, 3, user);

        // sUSDS (dispatcher index 4)
        _fillTokenData(data, 15, susds, 4, user);

        // WBTC (dispatcher index 5)
        _fillTokenData(data, 20, wbtc, 5, user);

        // Burn totals
        data[25] = burnRecorder.getTotalBurnt(address(eye));
        data[26] = burnRecorder.getTotalBurnt(address(scx));
        data[27] = burnRecorder.getTotalBurnt(address(flax));
    }

    /// @dev Fills 5 fields for a given token starting at `offset` in the data array.
    function _fillTokenData(
        uint256[] memory data,
        uint256 offset,
        IERC20 token,
        uint256 dispatcherIndex,
        address user
    ) internal view {
        // Allowance of NFTMinter to spend user's token
        data[offset] = token.allowance(user, address(nftMinter));

        // Price and growthBasisPoints from config
        (, uint256 price, uint256 growthBasisPoints) = nftMinter.configs(dispatcherIndex);
        data[offset + 1] = price;
        data[offset + 2] = growthBasisPoints;

        // User's token balance
        data[offset + 3] = token.balanceOf(user);

        // User's NFT balance - resolve token ID via override
        (address dispatcher,,) = nftMinter.configs(dispatcherIndex);
        uint256 tokenId = nftMinter.dispatcherTokenIdOverride(dispatcher);
        if (tokenId == 0) {
            tokenId = dispatcherIndex;
        }
        data[offset + 4] = IERC1155(address(nftMinter)).balanceOf(user, tokenId);
    }
}
