// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV2Router02} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Pair.sol";
import {IPhusdBurnable} from "@yield-claim-nft/interfaces/IPhusdBurnable.sol";
import {IUniswapV2FactoryCreate} from "./interfaces/IUniswapV2FactoryCreate.sol";
import {IUniswapV2PairBurn} from "./interfaces/IUniswapV2PairBurn.sol";
import {IUniswapV2PairMint} from "./interfaces/IUniswapV2PairMint.sol";
import {IAntimatterMintable} from "./interfaces/IAntimatterMintable.sol";

/// @title  AntimatterPoolSeeder
/// @notice Converts a slice of protocol-owned phUSD/sUSDS Uniswap V2 LP into Antimatter/sUSDS LP,
///         tax-neutrally. In one transaction `seed`:
///
///         1. pulls `lpAmount` phUSD/sUSDS LP from the owner and unwraps it into phUSD + sUSDS;
///         2. mints Antimatter equal in QUANTITY to the phUSD unwrapped (1 AM == 1 phUSD — Antimatter
///            has no oracle, and `annihilate` is 1:1 by quantity);
///         3. creates the AM/sUSDS pair if absent and adds ALL of that Antimatter plus up to all of the
///            unwrapped sUSDS, minting the new LP to `lpRecipient`; unused sUSDS also goes there;
///         4. burns the unwrapped phUSD, so phUSD supply falls by exactly the AM minted.
///
/// @dev    Every external address is an immutable constructor argument, so the same bytecode deploys
///         against anvil mocks and mainnet alike (precedent: `UniswapHelper`).
///
///         The protocol LP sits on UniPoolerV2, whose only exit is its owner's `rescueERC20`. The
///         seeder is therefore never given ownership of the pooler: the owner rescues the LP, approves
///         this contract and calls `seed` with an explicit `lpAmount`. `lpForBps` is a read-only helper
///         for sizing that amount as a share of the pooler's holding.
///
///         Required grants (owner-side, before `seed`):
///         - `Antimatter.setApprovedMinter(seeder, true)`. That call is a SILENT no-op when the value
///           is unchanged, so confirm with `Antimatter.isApprovedMinter(seeder)`.
///         - None on phUSD: FlaxToken's `burn(holder, amount)` is permissionless and allowance-gated,
///           and the seeder holds an infinite self-allowance granted in the constructor.
///
///         Antimatter has no public burn, so stray AM would break the burned == minted invariant: the
///         AM side must be consumed in full, or `seed` reverts `AntimatterNotFullyConsumed`.
///
///         One-sided AM/sUSDS pair: anyone can create the pair, donate a dust amount of ONE token and
///         `sync()`, leaving one reserve zero. Router02 cannot add into that state (its quote divides by
///         the zero reserve, or reverts `INSUFFICIENT_LIQUIDITY`). `seed` therefore bypasses the router
///         when exactly one reserve is zero and the pair has no LP supply: it transfers ALL the Antimatter
///         and ALL the sUSDS straight to the pair and calls `pair.mint(lpRecipient)`. The pair mints
///         `sqrt(amAdded * susdsAdded) - MINIMUM_LIQUIDITY` and absorbs the donated dust into the reserves,
///         so the donation accrues to the protocol-owned LP and burned == minted still holds.
contract AntimatterPoolSeeder is Ownable {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ============ Immutables ============

    address public immutable phUSD;
    address public immutable sUSDS;
    address public immutable antimatter;
    address public immutable router;
    address public immutable factory;
    address public immutable phusdSusdsPair;
    /// @notice The holder of the protocol-owned phUSD/sUSDS LP (UniPoolerV2). Read only by `lpForBps`.
    address public immutable lpSource;

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidBps(uint256 bps);
    error Expired(uint256 deadline, uint256 timestamp);
    error PairMismatch(address expected, address actual);
    error InsufficientPhUSD(uint256 phusdOut, uint256 minPhUSD);
    error InsufficientSUSDS(uint256 susdsOut, uint256 minSUSDS);
    error AntimatterNotFullyConsumed(uint256 amMinted, uint256 susdsRequired, uint256 susdsAvailable);
    error ResidualBalance(address token, uint256 before, uint256 afterwards);
    /// @dev A one-sided pair that already has LP supply. Unreachable with canonical UniswapV2Pair
    ///      bytecode (a minted pair can never drain a reserve to zero); guarded loudly regardless.
    error OneSidedPair(uint256 reserveAm, uint256 reserveSusds, uint256 totalSupply);

    // ============ Events ============

    /// @notice A completed seed. `phusdBurned == amMinted` always.
    event Seeded(
        uint256 lpAmount,
        uint256 phusdBurned,
        uint256 amMinted,
        uint256 susdsPaired,
        uint256 liquidity,
        address indexed lpRecipient
    );

    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address owner_,
        address phUSD_,
        address sUSDS_,
        address antimatter_,
        address uniV2Router_,
        address phusdSusdsPair_,
        address lpSource_
    ) Ownable(owner_) {
        if (
            phUSD_ == address(0) || sUSDS_ == address(0) || antimatter_ == address(0) || uniV2Router_ == address(0)
                || phusdSusdsPair_ == address(0) || lpSource_ == address(0)
        ) revert ZeroAddress();

        address factory_ = IUniswapV2Router02(uniV2Router_).factory();
        if (factory_ == address(0)) revert ZeroAddress();
        // The pair must be the router's canonical phUSD/sUSDS pair, not merely some LP token.
        address canonical = IUniswapV2FactoryCreate(factory_).getPair(phUSD_, sUSDS_);
        if (canonical != phusdSusdsPair_) revert PairMismatch(canonical, phusdSusdsPair_);

        phUSD = phUSD_;
        sUSDS = sUSDS_;
        antimatter = antimatter_;
        router = uniV2Router_;
        factory = factory_;
        phusdSusdsPair = phusdSusdsPair_;
        lpSource = lpSource_;

        // FlaxToken.burn spends msg.sender's allowance over `holder`, even when holder == msg.sender.
        // Precedent: PromotionUniV2_Eth (yield-claim-nft) constructor self-approve.
        IERC20(phUSD_).forceApprove(address(this), type(uint256).max);
    }

    // ============ Views ============

    /// @notice `bps` basis points of the phUSD/sUSDS LP currently held by `lpSource`, rounded down.
    function lpForBps(uint256 bps) external view returns (uint256) {
        if (bps > BPS_DENOMINATOR) revert InvalidBps(bps);
        return IERC20(phusdSusdsPair).balanceOf(lpSource) * bps / BPS_DENOMINATOR;
    }

    /// @notice The canonical Antimatter/sUSDS pair, or address(0) before the first seed creates it.
    function amSusdsPair() public view returns (address) {
        return IUniswapV2FactoryCreate(factory).getPair(antimatter, sUSDS);
    }

    // ============ Seed ============

    /// @notice Unwraps `lpAmount` phUSD/sUSDS LP pulled from the owner, mints the same quantity of
    ///         Antimatter as the phUSD released, pairs that Antimatter with the released sUSDS in the
    ///         AM/sUSDS pair (LP and any unused sUSDS to `lpRecipient`) and burns the released phUSD.
    /// @param lpAmount   phUSD/sUSDS LP to unwrap; the owner must have approved this contract for it.
    /// @param minPhUSD   Floor on phUSD released by the unwrap.
    /// @param minSUSDS   Floor on sUSDS released by the unwrap.
    /// @param lpRecipient Receives the AM/sUSDS LP and any sUSDS not needed to pair the Antimatter.
    /// @param deadline   Unix timestamp after which the call reverts.
    /// @return amBurnedEquivalent The phUSD burned, equal to the Antimatter minted.
    /// @return liquidity  AM/sUSDS LP minted to `lpRecipient`.
    function seed(uint256 lpAmount, uint256 minPhUSD, uint256 minSUSDS, address lpRecipient, uint256 deadline)
        external
        onlyOwner
        returns (uint256 amBurnedEquivalent, uint256 liquidity)
    {
        if (lpAmount == 0) revert ZeroAmount();
        if (lpRecipient == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);

        address amPair = amSusdsPair();
        uint256[5] memory before = _snapshot(amPair);

        // 1-2. Unwrap: LP straight from the owner to the pair, then burn it to this contract.
        IERC20(phusdSusdsPair).safeTransferFrom(msg.sender, phusdSusdsPair, lpAmount);
        (uint256 amount0, uint256 amount1) = IUniswapV2PairBurn(phusdSusdsPair).burn(address(this));
        (uint256 phusdOut, uint256 susdsOut) = phUSD < sUSDS ? (amount0, amount1) : (amount1, amount0);
        if (phusdOut < minPhUSD) revert InsufficientPhUSD(phusdOut, minPhUSD);
        if (susdsOut < minSUSDS) revert InsufficientSUSDS(susdsOut, minSUSDS);
        if (phusdOut == 0) revert ZeroAmount();

        // 3. Antimatter 1:1 by quantity with the phUSD released.
        IAntimatterMintable(antimatter).mint(address(this), phusdOut);

        // 4. Pair it. Create the pair explicitly when absent; a one-sided (griefed) pair is minted into
        //    directly; otherwise the AM side must fit in full at the existing ratio.
        bool direct;
        if (amPair == address(0)) {
            amPair = IUniswapV2FactoryCreate(factory).createPair(antimatter, sUSDS);
        } else {
            direct = _requireFullConsumption(amPair, phusdOut, susdsOut);
        }
        uint256 susdsPaired;
        if (direct) {
            (susdsPaired, liquidity) = _mintDirect(amPair, phusdOut, susdsOut, lpRecipient);
        } else {
            (susdsPaired, liquidity) = _addLiquidity(phusdOut, susdsOut, lpRecipient, deadline);
        }
        if (susdsOut > susdsPaired) IERC20(sUSDS).safeTransfer(lpRecipient, susdsOut - susdsPaired);

        // 5. Burn the phUSD released (allowance-gated; self-allowance granted in the constructor).
        IPhusdBurnable(phUSD).burn(address(this), phusdOut);

        _requireUnchanged(before, _snapshot(amPair));

        amBurnedEquivalent = phusdOut;
        emit Seeded(lpAmount, phusdOut, phusdOut, susdsPaired, liquidity, lpRecipient);
    }

    // ============ Recovery ============

    /// @notice Sends `amount` of `token` held by this contract to `to`. Owner only.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ============ Internals ============

    /// @dev Router02 would otherwise fall back to pairing LESS than all of the Antimatter (and then
    ///      revert on `amountAMin`); this check surfaces that case with the numbers attached.
    ///      Mirrors `UniswapV2Library.quote`.
    /// @return direct True when exactly one reserve is zero (and the pair has no LP supply), so the
    ///         router cannot be used and `seed` must mint into the pair directly.
    function _requireFullConsumption(address amPair, uint256 amAmount, uint256 susdsAvailable)
        internal
        view
        returns (bool direct)
    {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(amPair).getReserves();
        if (r0 == 0 && r1 == 0) return false; // empty pair: the router add sets the ratio
        (uint256 rAm, uint256 rSusds) = antimatter < sUSDS ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (rAm == 0 || rSusds == 0) {
            uint256 supply = IUniswapV2Pair(amPair).totalSupply();
            if (supply != 0) revert OneSidedPair(rAm, rSusds, supply);
            return true; // one-sided dust, no LP: the direct mint sets the ratio and absorbs the dust
        }
        uint256 susdsRequired = amAmount * rSusds / rAm;
        if (susdsRequired > susdsAvailable) {
            revert AntimatterNotFullyConsumed(amAmount, susdsRequired, susdsAvailable);
        }
    }

    function _addLiquidity(uint256 amAmount, uint256 susdsDesired, address lpRecipient, uint256 deadline)
        internal
        returns (uint256 susdsUsed, uint256 liquidity)
    {
        IERC20(antimatter).forceApprove(router, amAmount);
        IERC20(sUSDS).forceApprove(router, susdsDesired);
        uint256 amUsed;
        (amUsed, susdsUsed, liquidity) = IUniswapV2Router02(router)
            .addLiquidity(antimatter, sUSDS, amAmount, susdsDesired, amAmount, 0, lpRecipient, deadline);
        if (amUsed != amAmount) revert AntimatterNotFullyConsumed(amAmount, susdsUsed, susdsDesired);
        IERC20(antimatter).forceApprove(router, 0);
        IERC20(sUSDS).forceApprove(router, 0);
    }

    /// @dev First mint into a pair with no LP supply but a one-sided reserve. The pair credits
    ///      `balance - reserve` of each token, i.e. exactly what is sent here, so every unit of AM and
    ///      sUSDS is consumed; the donated reserve is absorbed into the pool owned by `lpRecipient`.
    function _mintDirect(address amPair, uint256 amAmount, uint256 susdsAmount, address lpRecipient)
        internal
        returns (uint256 susdsUsed, uint256 liquidity)
    {
        IERC20(antimatter).safeTransfer(amPair, amAmount);
        IERC20(sUSDS).safeTransfer(amPair, susdsAmount);
        liquidity = IUniswapV2PairMint(amPair).mint(lpRecipient);
        susdsUsed = susdsAmount;
    }

    /// @dev Balances this contract holds of every token `seed` touches.
    function _snapshot(address amPair) internal view returns (uint256[5] memory s) {
        s[0] = IERC20(phUSD).balanceOf(address(this));
        s[1] = IERC20(antimatter).balanceOf(address(this));
        s[2] = IERC20(sUSDS).balanceOf(address(this));
        s[3] = IERC20(phusdSusdsPair).balanceOf(address(this));
        s[4] = amPair == address(0) ? 0 : IERC20(amPair).balanceOf(address(this));
    }

    /// @dev `seed` must leave nothing behind: every balance ends where it started (zero, unless
    ///      something was sent here out of band, which `rescueERC20` recovers).
    function _requireUnchanged(uint256[5] memory before, uint256[5] memory afterwards) internal view {
        address[5] memory tokens = [phUSD, antimatter, sUSDS, phusdSusdsPair, amSusdsPair()];
        for (uint256 i; i < 5; ++i) {
            if (before[i] != afterwards[i]) revert ResidualBalance(tokens[i], before[i], afterwards[i]);
        }
    }
}
