// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPageView.sol";
import "@phlimbo-ea/interfaces/IPhlimboV3.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal local view of OpenZeppelin `Pausable.paused()`.
/// @dev `paused()` is inherited by the concrete `PhlimboV3` but is NOT declared on
///      `IPhlimboV3`, which lives in `lib/` and must not be modified. Casting through
///      this local interface keeps the submodule untouched.
interface IPausedLike {
    function paused() external view returns (bool);
}

/// @notice Minimal local view of the optional ERC20 `decimals()` extension.
/// @dev `decimals()` is optional in ERC20 and the promo token is an arbitrary partner
///      token, so every call site must be wrapped in try/catch.
interface IERC20DecimalsLike {
    function decimals() external view returns (uint8);
}

/**
 * @title DepositPageViewV3
 * @notice `IPageView` implementation for the deposit page, typed against `IPhlimboV3`.
 *
 * @dev ## Why a new contract rather than a re-cast
 *
 *      `PhlimboV3.userInfo(address)` returns a **4**-tuple (`amount`, `phUSDDebt`,
 *      `stableDebt`, `promoDebt`); V1/V2 returned a 3-tuple. Force-casting a V1-typed
 *      view onto V3 does not revert — Solidity's decoder tolerates extra trailing
 *      returndata for static types — so the old view *appears* to work while being
 *      undefined-by-accident and carrying none of the promotional-reward data. This
 *      contract types against `IPhlimboV3` and destructures the 4-tuple explicitly so
 *      the compiler enforces the shape.
 *
 * @dev ## APPEND-ONLY FIELD RULE (load-bearing)
 *
 *      `getNames()` is the wire contract. The arrays returned by `getNames()` and
 *      `getData()` are parallel and are **append-only**: never reorder, rename or
 *      repurpose an existing index. Consumers may cache indices rather than resolving
 *      by name, so a reorder is a silent breaking change with no compile failure and no
 *      revert. New data is added at the end and the length grows. Indices 0–6 are
 *      byte-for-byte the names, order and semantics of the predecessor
 *      `DepositPageView`, so migrating a consumer is strictly additive.
 *
 * @dev ## SCALING ASYMMETRY BETWEEN FIELD 1 AND FIELD 2 (read before doing arithmetic)
 *
 *      `PRECISION` (field 7, `1e18`) is a fixed-point scaling factor, not a decimals
 *      assumption. Amounts are always in the token's own native decimals with no
 *      normalisation. **Rates are inconsistent:**
 *
 *      - field 1 `phUSDRewardsPerSecond` — **RAW**, phUSD wei per second, NOT scaled by
 *        PRECISION. Consumed on-chain as `timeElapsed * phUSDPerSecond`.
 *      - field 2 `stableRewardsPerSecond` — **PRECISION-scaled**. Consumed on-chain as
 *        `(rewardPerSecond * timeElapsed) / PRECISION`.
 *      - field 13 `promoRewardPerSecond` — **PRECISION-scaled**, same as field 2.
 *
 *      The two are returned adjacently and are off by a factor of `1e18`. Both
 *      semantics are preserved exactly as the predecessor exposed them: silently
 *      descaling field 2 behind an unchanged name would break every existing consumer
 *      by `1e18` with no error. Field 7 is exposed so a consumer can descale without
 *      hardcoding a constant.
 *
 * @dev ## `pendingX` IS NOT THE USER'S ENTITLEMENT
 *
 *      V3 made `_claimRewards` non-reverting: a failed transfer or mint is *banked*
 *      per user and `pendingX` then returns **zero** for that amount by design. True
 *      entitlement is `pendingX + bank`. All three banks are therefore first-class
 *      fields (20 `unclaimablePromo`, 21 `unclaimableStable`, 22 `unclaimablePhUSD`).
 *      A UI that reads only `pendingX` will tell a banked user they have nothing.
 *
 * @dev ## PROMO SLOT
 *
 *      V3 adds a **single** rotating promotional slot — there is no reward-token
 *      registry or array. `promoPhase` (field 16) is `0 = None`, `1 = Active`,
 *      `2 = Flushing`. While `Flushing` the contract is paused (field 10 == 1) and
 *      `pendingPromo` is frozen; read fields 19, 16 and 10 together or a UI will show
 *      a stalled counter with no explanation. Flush progress is
 *      `flushCursor / stakerCount` (fields 17 and 18). A depleted promotion stays
 *      `Active` with `promoRewardBalance == 0` — "dormant" is not a distinct phase.
 *
 * @dev ## ROUTER RESOLUTION FOR THE SUPPLEMENTARY READ
 *
 *      `ViewRouter` is a *page* router, not a general proxy: it forwards only
 *      `getNames` and `getData`. `getRetiredPromoBanks` is therefore NOT reachable
 *      through the router. Consumers resolve the implementation in two steps:
 *
 *      ```
 *      address impl = address(router.pages(keccak256("deposit")));
 *      DepositPageViewV3(impl).getRetiredPromoBanks(user, tokens);
 *      ```
 *
 * @dev ## NEVER REVERTS
 *
 *      This is the entire deposit page behind one call; a revert blanks the screen.
 *      A never-staked user, `address(0)`, an absent promotion and a promo token with no
 *      `decimals()` all return data rather than reverting.
 */
contract DepositPageViewV3 is IPageView {
    /// @notice Number of parallel entries returned by `getNames()` / `getData()`.
    /// @dev Append-only: this may grow, never shrink, and existing indices never move.
    uint256 public constant FIELD_COUNT = 23;

    IPhlimboV3 public immutable phlimbo;
    IERC20 public immutable phUSD;

    constructor(IPhlimboV3 _phlimbo, IERC20 _phUSD) {
        require(address(_phlimbo) != address(0), "Invalid phlimbo address");
        require(address(_phUSD) != address(0), "Invalid phUSD address");
        phlimbo = _phlimbo;
        phUSD = _phUSD;
    }

    /// @inheritdoc IPageView
    /// @dev APPEND-ONLY. See the contract header before touching this array.
    function getNames() external pure returns (string[] memory names) {
        names = new string[](FIELD_COUNT);
        names[0] = "userPhUSDBalance";
        names[1] = "phUSDRewardsPerSecond";
        names[2] = "stableRewardsPerSecond";
        names[3] = "pendingPhUSDRewards";
        names[4] = "pendingStableRewards";
        names[5] = "stakedBalance";
        names[6] = "userAllowance";
        names[7] = "precision";
        names[8] = "minimumStake";
        names[9] = "totalStaked";
        names[10] = "paused";
        names[11] = "promoToken";
        names[12] = "promoTokenDecimals";
        names[13] = "promoRewardPerSecond";
        names[14] = "promoRewardBalance";
        names[15] = "promoDepletionDuration";
        names[16] = "promoPhase";
        names[17] = "flushCursor";
        names[18] = "stakerCount";
        names[19] = "pendingPromoRewards";
        names[20] = "unclaimablePromo";
        names[21] = "unclaimableStable";
        names[22] = "unclaimablePhUSD";
    }

    /// @inheritdoc IPageView
    /// @dev Indices 0–6 are semantically identical to `DepositPageView`. See the
    ///      contract header for the field-1/field-2 scaling asymmetry.
    function getData(address user) external view returns (uint256[] memory data) {
        data = new uint256[](FIELD_COUNT);

        // --- indices 0-6: unchanged from DepositPageView ------------------------
        data[0] = phUSD.balanceOf(user);
        data[1] = phlimbo.phUSDPerSecond(); // RAW wei/sec, NOT PRECISION-scaled
        data[2] = phlimbo.rewardPerSecond(); // PRECISION-scaled
        data[3] = phlimbo.pendingPhUSD(user);
        data[4] = phlimbo.pendingStable(user);
        (uint256 amount,,,) = phlimbo.userInfo(user); // 4-tuple in V3
        data[5] = amount;
        data[6] = phUSD.allowance(user, address(phlimbo));

        // --- indices 7-10: pool constants and pause state -----------------------
        data[7] = phlimbo.PRECISION();
        data[8] = phlimbo.MINIMUM_STAKE();
        data[9] = phlimbo.totalStaked();
        data[10] = IPausedLike(address(phlimbo)).paused() ? 1 : 0;

        // --- indices 11-17: the promo slot, from a single getPromoInfo() call ----
        (
            address promoToken_,
            uint256 promoRewardBalance_,
            uint256 promoRewardPerSecond_,
            uint256 promoDepletionDuration_,
            IPhlimboV3.PromoPhase promoPhase_,
            uint256 flushCursor_
        ) = phlimbo.getPromoInfo();

        data[11] = uint256(uint160(promoToken_));
        data[12] = promoToken_ == address(0) ? 0 : _promoDecimals(promoToken_);
        data[13] = promoRewardPerSecond_; // PRECISION-scaled
        data[14] = promoRewardBalance_;
        data[15] = promoDepletionDuration_;
        data[16] = uint256(uint8(promoPhase_));
        data[17] = flushCursor_;

        // --- indices 18-22: enumeration, pending promo, and the three banks ------
        data[18] = phlimbo.stakerCount();
        data[19] = phlimbo.pendingPromo(user);
        data[20] = promoToken_ == address(0) ? 0 : phlimbo.unclaimablePromoOf(promoToken_, user);
        data[21] = phlimbo.unclaimableStableOf(user);
        data[22] = phlimbo.unclaimablePhUSDOf(user);
    }

    /**
     * @notice Banked promo amounts for `user` across arbitrary (typically retired) promo tokens.
     * @dev `unclaimablePromoOf` is keyed **by token** precisely because the promo slot
     *      rotates. After `finalizePromotion` the slot is zeroed but a user's bank for
     *      the *retired* token survives and stays pullable via
     *      `claimUnclaimablePromo(token)`. There is no on-chain enumeration of
     *      historical promo tokens — only the `PromotionStarted` /
     *      `PromotionFinalized` / `PromoClaimFailed` event log — so the caller supplies
     *      the token list.
     *
     *      NOT part of `IPageView` and therefore **NOT reachable through ViewRouter's
     *      proxy reads**, which forward only `getNames` and `getData`. Resolve the
     *      implementation with `router.pages(keccak256("deposit"))` and call it directly.
     *
     * @param user The account whose banked balances are being read.
     * @param tokens Promo tokens to query; typically retired ones recovered from the log.
     * @return amounts Banked amount per token, in that token's native decimals,
     *         index-aligned with `tokens`. An empty `tokens` returns an empty array.
     */
    function getRetiredPromoBanks(address user, address[] calldata tokens)
        external
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) continue;
            amounts[i] = phlimbo.unclaimablePromoOf(tokens[i], user);
        }
    }

    /// @dev `decimals()` is an optional ERC20 extension and the promo token is an
    ///      arbitrary partner token. Falls back to 18 rather than reverting or letting
    ///      the call bubble up and blank the deposit page.
    function _promoDecimals(address token) private view returns (uint256) {
        try IERC20DecimalsLike(token).decimals() returns (uint8 d) {
            return uint256(d);
        } catch {
            return 18;
        }
    }
}
