// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ISkyPSM} from "@yield-claim-nft/interfaces/ISkyPSM.sol";
import {IUniswapV2Factory} from "@yield-claim-nft/interfaces/uniswap/IUniswapV2Factory.sol";
import {IUniswapV2RouterPeriphery} from "./interfaces/IUniswapV2RouterPeriphery.sol";
import {IUniswapV3SwapRouter} from "./interfaces/IUniswapV3SwapRouter.sol";
import {IQuoterV2} from "./interfaces/IQuoterV2.sol";
import {ICurveMetaPool} from "./interfaces/ICurveMetaPool.sol";
import {ICurveStableSwapNG} from "./interfaces/ICurveStableSwapNG.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IUniswapV2PairBurn} from "./interfaces/IUniswapV2PairBurn.sol";

/// @title  UniswapHelper
/// @notice One-transaction swaps into and out of phUSD and Antimatter (AM), and one-transaction
///         liquidity operations on the Uniswap V2 phUSD/sUSDS and AM/sUSDS pairs. Every route crosses
///         one of those pairs, with sUSDS as the hub. The "target" is phUSD or AM:
///
///         | Token  | Leg to/from sUSDS                                                         |
///         |--------|---------------------------------------------------------------------------|
///         | sUSDS  | none                                                                      |
///         | USDS   | ERC4626 `deposit` / `redeem`                                              |
///         | USDC   | Sky PSM `sellGem` (tin) / `buyGem` (tout, floored), then the USDS leg     |
///         | DOLA   | Curve DOLA-3CRV `exchange_underlying` (0 <-> 2), then the USDC leg        |
///         | USDe   | Curve USDe/USDC stableswap-ng `exchange` (0 <-> 1), then the USDC leg     |
///         | ETH    | WETH9 wrap/unwrap + Uniswap V3 WETH/USDC (`fee` tier), then the USDC leg  |
///
///         | Target | V2 leg from/to sUSDS                                                      |
///         |--------|---------------------------------------------------------------------------|
///         | phUSD  | phUSD/sUSDS pair (`pair()`)                                               |
///         | AM     | AM/sUSDS pair (`amPair()`)                                                |
///
///         phUSD <-> AM is one Router02 `swapExactTokensForTokens` over the 3-hop path
///         [phUSD, sUSDS, AM] (or the reverse): the sUSDS between the two pairs never touches the
///         helper. AM routes and AM liquidity revert `PairNotFound` while the AM/sUSDS pair does
///         not exist. There are no stable <-> stable routes.
///
/// @dev    Stateless and ownerless: no admin, no rescue, no upgradeability. Every external address is
///         an immutable constructor argument so the same bytecode deploys against anvil mocks and
///         mainnet alike. Neither V2 pair is passed in: swaps go through Router02 paths, and
///         liquidity functions resolve the pair at call time via `factory.getPair`, reverting
///         `PairNotFound` while it does not exist (so Router02 can never silently create it).
///
///         Slippage: intermediate legs take a 0 minimum; the single `minOut` on the final output is
///         the guard for the whole atomic route. After every call the helper holds zero of every
///         token and zero ETH — intermediate remainders (PSM `buyGem` flooring dust, `addLiquidity`
///         leftovers) are refunded to the recipient.
///
///         Approvals use `forceApprove` of the exact amount immediately before each pull, so the
///         helper keeps no standing allowance between calls (see story 109 Autonomous Decisions).
///
///         Events are shared between targets: on the AM liquidity functions the `phusdIn` /
///         `phusdOut` event fields carry the AM amount, and `tokenIn`/`tokenOut` (the pair) tells
///         the two pools apart.
contract UniswapHelper {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 internal constant WAD = 1e18;

    /// @notice Sentinel used in events for native ETH.
    address public constant ETH = address(0);

    /// @dev Curve DOLA-3CRV underlying indices.
    int128 internal constant CURVE_META_DOLA = 0;
    int128 internal constant CURVE_META_USDC = 2;

    /// @dev Curve USDe/USDC stableswap-ng coin indices.
    int128 internal constant CURVE_NG_USDE = 0;
    int128 internal constant CURVE_NG_USDC = 1;

    // ============ Immutables ============

    address public immutable phUSD;
    address public immutable sUSDS;
    address public immutable USDS;
    address public immutable USDC;
    address public immutable DOLA;
    address public immutable USDe;
    address public immutable WETH;
    address public immutable skyPSM;
    address public immutable v2Router;
    address public immutable v3SwapRouter;
    address public immutable v3Quoter;
    address public immutable curveDolaPool;
    address public immutable curveUsdePool;
    /// @notice The Antimatter (AM) token, the second V2 target alongside phUSD (story 120).
    address public immutable antimatter;
    uint24 public immutable v3Fee;

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error Expired(uint256 deadline, uint256 timestamp);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    error UnsupportedToken(address token);
    error PairNotFound();
    error ETHNotAccepted(address sender);
    error ETHTransferFailed();
    error CurveCoinMismatch();

    // ============ Events ============

    /// @notice A swap. `tokenIn`/`tokenOut` is `ETH` (address(0)) for native ETH.
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    /// @notice A two-sided add. `tokenIn` is sUSDS or USDS, `amountIn` the amount of it actually used;
    ///         `tokenOut` is the pair and `amountOut` the LP minted to `recipient`. `phusdIn` is the
    ///         target-side amount used (phUSD, or AM on the AM/sUSDS pair).
    event LiquidityAdded(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 phusdIn,
        uint256 amountOut,
        address recipient
    );

    /// @notice A remove. `tokenIn` is the pair and `amountIn` the LP burned; `tokenOut` is sUSDS or
    ///         USDS and `amountOut` the amount of it delivered, alongside `phusdOut` of the target
    ///         (phUSD, or AM on the AM/sUSDS pair).
    event LiquidityRemoved(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 phusdOut,
        address recipient
    );

    // ============ Modifiers ============

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired(deadline, block.timestamp);
        _;
    }

    // ============ Constructor ============

    /// @dev The USDe/USDC stableswap-ng coin order is sanity-checked here. The DOLA-3CRV metapool's
    ///      underlying order is not: its underlying coins live on the 3pool base, not the metapool,
    ///      and the indices (0 = DOLA, 2 = USDC) are fixed by the 3pool's immutable coin order.
    constructor(
        address phUSD_,
        address sUSDS_,
        address USDS_,
        address USDC_,
        address DOLA_,
        address USDe_,
        address WETH_,
        address skyPSM_,
        address v2Router_,
        address v3SwapRouter_,
        address v3Quoter_,
        address curveDolaPool_,
        address curveUsdePool_,
        address antimatter_,
        uint24 v3Fee_
    ) {
        if (
            phUSD_ == address(0) || sUSDS_ == address(0) || USDS_ == address(0) || USDC_ == address(0)
                || DOLA_ == address(0) || USDe_ == address(0) || WETH_ == address(0) || skyPSM_ == address(0)
                || v2Router_ == address(0) || v3SwapRouter_ == address(0) || v3Quoter_ == address(0)
                || curveDolaPool_ == address(0) || curveUsdePool_ == address(0) || antimatter_ == address(0)
        ) revert ZeroAddress();
        if (
            ICurveStableSwapNG(curveUsdePool_).coins(uint256(uint128(CURVE_NG_USDE))) != USDe_
                || ICurveStableSwapNG(curveUsdePool_).coins(uint256(uint128(CURVE_NG_USDC))) != USDC_
        ) revert CurveCoinMismatch();

        phUSD = phUSD_;
        sUSDS = sUSDS_;
        USDS = USDS_;
        USDC = USDC_;
        DOLA = DOLA_;
        USDe = USDe_;
        WETH = WETH_;
        skyPSM = skyPSM_;
        v2Router = v2Router_;
        v3SwapRouter = v3SwapRouter_;
        v3Quoter = v3Quoter_;
        curveDolaPool = curveDolaPool_;
        curveUsdePool = curveUsdePool_;
        antimatter = antimatter_;
        v3Fee = v3Fee_;
    }

    /// @notice Accepts ETH only from WETH9 (`WETH.withdraw` on the phUSD/AM -> ETH routes).
    receive() external payable {
        if (msg.sender != WETH) revert ETHNotAccepted(msg.sender);
    }

    // ============ Swaps: phUSD ============

    /// @notice Swap `amountIn` of `tokenIn` (DOLA, USDC, USDe, USDS or sUSDS) for phUSD.
    /// @return phusdOut phUSD delivered to `recipient`.
    function swapToPhUSD(address tokenIn, uint256 amountIn, uint256 minPhusdOut, address recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 phusdOut)
    {
        return _swapStableTo(phUSD, tokenIn, amountIn, minPhusdOut, recipient, deadline);
    }

    /// @notice Swap the attached ETH for phUSD (WETH -> V3 -> USDC -> PSM -> USDS -> sUSDS -> V2).
    /// @return phusdOut phUSD delivered to `recipient`.
    function swapETHToPhUSD(uint256 minPhusdOut, address recipient, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 phusdOut)
    {
        return _swapETHTo(phUSD, minPhusdOut, recipient, deadline);
    }

    /// @notice Swap `phusdIn` phUSD for `tokenOut` (DOLA, USDC, USDe, USDS or sUSDS).
    /// @dev    For USDC-based outputs, any USDS left over by the floored PSM `buyGem` is refunded to
    ///         `recipient` on top of `amountOut`.
    /// @return amountOut `tokenOut` delivered to `recipient`.
    function swapFromPhUSD(address tokenOut, uint256 phusdIn, uint256 minOut, address recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        return _swapStableFrom(phUSD, tokenOut, phusdIn, minOut, recipient, deadline);
    }

    /// @notice Swap `phusdIn` phUSD for native ETH (V2 -> sUSDS -> USDS -> PSM -> USDC -> V3 -> WETH).
    /// @dev    USDS dust from the floored PSM `buyGem` is refunded to `recipient`.
    /// @return ethOut ETH sent to `recipient`.
    function swapPhUSDToETH(uint256 phusdIn, uint256 minEthOut, address payable recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        return _swapToETH(phUSD, phusdIn, minEthOut, recipient, deadline);
    }

    // ============ Swaps: Antimatter ============

    /// @notice Swap `amountIn` of `tokenIn` (DOLA, USDC, USDe, USDS or sUSDS) for AM.
    /// @return amOut AM delivered to `recipient`.
    function swapToAM(address tokenIn, uint256 amountIn, uint256 minAmOut, address recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 amOut)
    {
        _requirePair(antimatter);
        return _swapStableTo(antimatter, tokenIn, amountIn, minAmOut, recipient, deadline);
    }

    /// @notice Swap the attached ETH for AM (WETH -> V3 -> USDC -> PSM -> USDS -> sUSDS -> V2).
    /// @return amOut AM delivered to `recipient`.
    function swapETHToAM(uint256 minAmOut, address recipient, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (uint256 amOut)
    {
        _requirePair(antimatter);
        return _swapETHTo(antimatter, minAmOut, recipient, deadline);
    }

    /// @notice Swap `amIn` AM for `tokenOut` (DOLA, USDC, USDe, USDS or sUSDS). USDS dust from the
    ///         floored PSM `buyGem` is refunded to `recipient` on top of `amountOut`.
    /// @return amountOut `tokenOut` delivered to `recipient`.
    function swapFromAM(address tokenOut, uint256 amIn, uint256 minOut, address recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        _requirePair(antimatter);
        return _swapStableFrom(antimatter, tokenOut, amIn, minOut, recipient, deadline);
    }

    /// @notice Swap `amIn` AM for native ETH (V2 -> sUSDS -> USDS -> PSM -> USDC -> V3 -> WETH). USDS
    ///         dust from the floored PSM `buyGem` is refunded to `recipient`.
    /// @return ethOut ETH sent to `recipient`.
    function swapAMToETH(uint256 amIn, uint256 minEthOut, address payable recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        _requirePair(antimatter);
        return _swapToETH(antimatter, amIn, minEthOut, recipient, deadline);
    }

    /// @notice Swap `phusdIn` phUSD for AM in ONE Router02 call over [phUSD, sUSDS, AM].
    /// @return amOut AM delivered to `recipient`.
    function swapPhUSDToAM(uint256 phusdIn, uint256 minAmOut, address recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 amOut)
    {
        return _swapAcross(phUSD, antimatter, phusdIn, minAmOut, recipient, deadline);
    }

    /// @notice Swap `amIn` AM for phUSD in ONE Router02 call over [AM, sUSDS, phUSD].
    /// @return phusdOut phUSD delivered to `recipient`.
    function swapAMToPhUSD(uint256 amIn, uint256 minPhusdOut, address recipient, uint256 deadline)
        external
        checkDeadline(deadline)
        returns (uint256 phusdOut)
    {
        return _swapAcross(antimatter, phUSD, amIn, minPhusdOut, recipient, deadline);
    }

    // ============ Liquidity: phUSD/sUSDS ============

    /// @notice Two-sided add of sUSDS + phUSD. LP goes to `recipient`; unused sUSDS/phUSD is refunded
    ///         to `recipient`. The mins are enforced by Router02 against the optimal amounts.
    function addLiquiditySUSDS(
        uint256 susdsDesired,
        uint256 phusdDesired,
        uint256 susdsMin,
        uint256 phusdMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 susdsUsed, uint256 phusdUsed, uint256 liquidity) {
        return _addLiquiditySUSDS(phUSD, susdsDesired, phusdDesired, susdsMin, phusdMin, recipient, deadline);
    }

    /// @notice Two-sided add of USDS + phUSD: the USDS is wrapped to sUSDS in the same transaction.
    ///         The USDS minimum is converted to a share minimum with `previewDeposit` (flooring).
    ///         Unused sUSDS is redeemed back to USDS; it and unused phUSD are refunded to `recipient`.
    /// @return usdsUsed  USDS consumed (`usdsDesired` minus the USDS refunded).
    /// @return phusdUsed phUSD consumed.
    /// @return liquidity LP minted to `recipient`.
    function addLiquidityUSDS(
        uint256 usdsDesired,
        uint256 phusdDesired,
        uint256 usdsMin,
        uint256 phusdMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 usdsUsed, uint256 phusdUsed, uint256 liquidity) {
        return _addLiquidityUSDS(phUSD, usdsDesired, phusdDesired, usdsMin, phusdMin, recipient, deadline);
    }

    /// @notice Remove `liquidity` LP for sUSDS + phUSD, both to `recipient`.
    /// @dev    Burns directly against the factory-resolved pair (exactly what Router02's
    ///         `removeLiquidity` does internally) rather than calling Router02: the vendored anvil
    ///         Router02 artifact (`script/uniswap-artifacts/`) has no `removeLiquidity`, so this keeps
    ///         plain removal one transaction on anvil as well as mainnet.
    function removeLiquiditySUSDS(
        uint256 liquidity,
        uint256 susdsMin,
        uint256 phusdMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 susdsOut, uint256 phusdOut) {
        return _removeLiquiditySUSDS(phUSD, liquidity, susdsMin, phusdMin, recipient);
    }

    /// @notice Remove `liquidity` LP and unwrap the sUSDS side to USDS, in one transaction. Both
    ///         USDS and phUSD go to `recipient`. Burns directly against the pair (see
    ///         `removeLiquiditySUSDS`).
    function removeLiquidityUSDS(
        uint256 liquidity,
        uint256 usdsMin,
        uint256 phusdMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 usdsOut, uint256 phusdOut) {
        return _removeLiquidityUSDS(phUSD, liquidity, usdsMin, phusdMin, recipient);
    }

    // ============ Liquidity: AM/sUSDS ============

    /// @notice Two-sided add of sUSDS + AM on the AM/sUSDS pair; mirrors `addLiquiditySUSDS`.
    function addLiquidityAMSUSDS(
        uint256 susdsDesired,
        uint256 amDesired,
        uint256 susdsMin,
        uint256 amMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 susdsUsed, uint256 amUsed, uint256 liquidity) {
        return _addLiquiditySUSDS(antimatter, susdsDesired, amDesired, susdsMin, amMin, recipient, deadline);
    }

    /// @notice Two-sided add of USDS + AM on the AM/sUSDS pair, wrapping the USDS to sUSDS; unused
    ///         sUSDS is refunded as USDS. Mirrors `addLiquidityUSDS`.
    function addLiquidityAMUSDS(
        uint256 usdsDesired,
        uint256 amDesired,
        uint256 usdsMin,
        uint256 amMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 usdsUsed, uint256 amUsed, uint256 liquidity) {
        return _addLiquidityUSDS(antimatter, usdsDesired, amDesired, usdsMin, amMin, recipient, deadline);
    }

    /// @notice Remove `liquidity` AM/sUSDS LP for sUSDS + AM, both to `recipient`. Burns directly
    ///         against the pair (see `removeLiquiditySUSDS`).
    function removeLiquidityAMSUSDS(
        uint256 liquidity,
        uint256 susdsMin,
        uint256 amMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 susdsOut, uint256 amOut) {
        return _removeLiquiditySUSDS(antimatter, liquidity, susdsMin, amMin, recipient);
    }

    /// @notice Remove `liquidity` AM/sUSDS LP and unwrap the sUSDS side to USDS. Both USDS and AM go
    ///         to `recipient`. Burns directly against the pair (see `removeLiquiditySUSDS`).
    function removeLiquidityAMUSDS(
        uint256 liquidity,
        uint256 usdsMin,
        uint256 amMin,
        address recipient,
        uint256 deadline
    ) external checkDeadline(deadline) returns (uint256 usdsOut, uint256 amOut) {
        return _removeLiquidityUSDS(antimatter, liquidity, usdsMin, amMin, recipient);
    }

    // ============ Quotes ============

    /// @notice Expected phUSD out for `amountIn` of `tokenIn` (DOLA, USDC, USDe, USDS or sUSDS).
    function quoteToPhUSD(address tokenIn, uint256 amountIn) external view returns (uint256 phusdOut) {
        if (!_isStable(tokenIn)) revert UnsupportedToken(tokenIn);
        return _quoteSusdsTo(phUSD, _quoteToSusds(tokenIn, amountIn));
    }

    /// @notice Expected `tokenOut` (DOLA, USDC, USDe, USDS or sUSDS) out for `phusdIn` phUSD.
    function quoteFromPhUSD(address tokenOut, uint256 phusdIn) external view returns (uint256 amountOut) {
        if (!_isStable(tokenOut)) revert UnsupportedToken(tokenOut);
        return _quoteFromSusds(tokenOut, _quoteToSusdsFrom(phUSD, phusdIn));
    }

    /// @notice Expected phUSD out for `ethIn` ETH.
    /// @dev    NOT view: QuoterV2 cannot be static-called. Intended for `eth_call` /
    ///         `simulateContract` only — never send it as a transaction.
    function quoteETHToPhUSD(uint256 ethIn) external returns (uint256 phusdOut) {
        uint256 usdc = _quoteV3(WETH, USDC, ethIn);
        return _quoteSusdsTo(phUSD, _quoteToSusds(USDC, usdc));
    }

    /// @notice Expected ETH out for `phusdIn` phUSD.
    /// @dev    NOT view: QuoterV2 cannot be static-called. Intended for `eth_call` /
    ///         `simulateContract` only — never send it as a transaction.
    function quotePhUSDToETH(uint256 phusdIn) external returns (uint256 ethOut) {
        uint256 usdc = _quoteFromSusds(USDC, _quoteToSusdsFrom(phUSD, phusdIn));
        return usdc == 0 ? 0 : _quoteV3(USDC, WETH, usdc);
    }

    /// @notice Expected AM out for `amountIn` of `tokenIn` (DOLA, USDC, USDe, USDS or sUSDS).
    function quoteToAM(address tokenIn, uint256 amountIn) external view returns (uint256 amOut) {
        _requirePair(antimatter);
        if (!_isStable(tokenIn)) revert UnsupportedToken(tokenIn);
        return _quoteSusdsTo(antimatter, _quoteToSusds(tokenIn, amountIn));
    }

    /// @notice Expected `tokenOut` (DOLA, USDC, USDe, USDS or sUSDS) out for `amIn` AM.
    function quoteFromAM(address tokenOut, uint256 amIn) external view returns (uint256 amountOut) {
        _requirePair(antimatter);
        if (!_isStable(tokenOut)) revert UnsupportedToken(tokenOut);
        return _quoteFromSusds(tokenOut, _quoteToSusdsFrom(antimatter, amIn));
    }

    /// @notice Expected AM out for `ethIn` ETH.
    /// @dev    NOT view: QuoterV2 cannot be static-called. Intended for `eth_call` /
    ///         `simulateContract` only — never send it as a transaction.
    function quoteETHToAM(uint256 ethIn) external returns (uint256 amOut) {
        _requirePair(antimatter);
        uint256 usdc = _quoteV3(WETH, USDC, ethIn);
        return _quoteSusdsTo(antimatter, _quoteToSusds(USDC, usdc));
    }

    /// @notice Expected ETH out for `amIn` AM.
    /// @dev    NOT view: QuoterV2 cannot be static-called. Intended for `eth_call` /
    ///         `simulateContract` only — never send it as a transaction.
    function quoteAMToETH(uint256 amIn) external returns (uint256 ethOut) {
        _requirePair(antimatter);
        uint256 usdc = _quoteFromSusds(USDC, _quoteToSusdsFrom(antimatter, amIn));
        return usdc == 0 ? 0 : _quoteV3(USDC, WETH, usdc);
    }

    /// @notice Expected AM out for `phusdIn` phUSD over [phUSD, sUSDS, AM].
    function quotePhUSDToAM(uint256 phusdIn) external view returns (uint256 amOut) {
        return _quoteAcross(phUSD, antimatter, phusdIn);
    }

    /// @notice Expected phUSD out for `amIn` AM over [AM, sUSDS, phUSD].
    function quoteAMToPhUSD(uint256 amIn) external view returns (uint256 phusdOut) {
        return _quoteAcross(antimatter, phUSD, amIn);
    }

    /// @notice The phUSD/sUSDS pair, or address(0) if it does not exist yet.
    function pair() public view returns (address) {
        return _pairOf(phUSD);
    }

    /// @notice The AM/sUSDS pair, or address(0) if it does not exist yet.
    function amPair() public view returns (address) {
        return _pairOf(antimatter);
    }

    /// @notice The largest USDC (6dp) amount the PSM's `buyGem` delivers for a `usdsBudget` (18dp).
    /// @dev    DssLitePsm pulls `cost(g) = g*conv + floor(g*conv*tout/WAD) = floor(g*conv*(WAD+tout)/WAD)`.
    ///         `cost(g) <= budget` iff `g*conv*(WAD+tout) < (budget+1)*WAD`, so the largest such g is
    ///         `floor(((budget+1)*WAD - 1) / (conv*(WAD+tout)))`. Floors: never over-requests USDS.
    function psmGemForUsds(uint256 usdsBudget) public view returns (uint256 gemAmt) {
        uint256 conv = ISkyPSM(skyPSM).to18ConversionFactor();
        uint256 tout = ISkyPSM(skyPSM).tout();
        gemAmt = ((usdsBudget + 1) * WAD - 1) / (conv * (WAD + tout));
    }

    // ============ Internal: target-parameterised routes ============
    // `target` is phUSD or antimatter; the V2 leg is always sUSDS <-> target.

    function _swapStableTo(
        address target,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        _checkSwapArgs(amountIn, recipient);
        if (!_isStable(tokenIn)) revert UnsupportedToken(tokenIn);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        amountOut = _v2Swap(sUSDS, target, _toSusds(tokenIn, amountIn), recipient, deadline);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        emit Swapped(msg.sender, tokenIn, target, amountIn, amountOut, recipient);
    }

    function _swapETHTo(address target, uint256 minOut, address recipient, uint256 deadline)
        internal
        returns (uint256 amountOut)
    {
        _checkSwapArgs(msg.value, recipient);
        IWETH(WETH).deposit{value: msg.value}();
        uint256 usdc = _v3Swap(WETH, USDC, msg.value, deadline);

        amountOut = _v2Swap(sUSDS, target, _toSusds(USDC, usdc), recipient, deadline);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        emit Swapped(msg.sender, ETH, target, msg.value, amountOut, recipient);
    }

    function _swapStableFrom(
        address target,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        _checkSwapArgs(amountIn, recipient);
        if (!_isStable(tokenOut)) revert UnsupportedToken(tokenOut);
        IERC20(target).safeTransferFrom(msg.sender, address(this), amountIn);

        if (tokenOut == sUSDS) {
            amountOut = _v2Swap(target, sUSDS, amountIn, recipient, deadline);
        } else {
            uint256 shares = _v2Swap(target, sUSDS, amountIn, address(this), deadline);
            amountOut = _fromSusds(tokenOut, shares, recipient);
        }
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        emit Swapped(msg.sender, target, tokenOut, amountIn, amountOut, recipient);
    }

    function _swapToETH(
        address target,
        uint256 amountIn,
        uint256 minEthOut,
        address payable recipient,
        uint256 deadline
    ) internal returns (uint256 ethOut) {
        _checkSwapArgs(amountIn, recipient);
        IERC20(target).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 shares = _v2Swap(target, sUSDS, amountIn, address(this), deadline);
        uint256 usds = IERC4626(sUSDS).redeem(shares, address(this), address(this));
        uint256 usdc = _usdsToUsdc(usds, address(this), recipient);
        ethOut = usdc == 0 ? 0 : _v3Swap(USDC, WETH, usdc, deadline);
        if (ethOut < minEthOut) revert InsufficientOutput(ethOut, minEthOut);

        if (ethOut > 0) {
            IWETH(WETH).withdraw(ethOut);
            (bool ok,) = recipient.call{value: ethOut}("");
            if (!ok) revert ETHTransferFailed();
        }
        emit Swapped(msg.sender, target, ETH, amountIn, ethOut, recipient);
    }

    /// @dev phUSD <-> AM: exactly one Router02 call over [tokenIn, sUSDS, tokenOut]. The sUSDS hop
    ///      moves pair-to-pair inside the router and never reaches this contract.
    function _swapAcross(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        _checkSwapArgs(amountIn, recipient);
        _requirePair(antimatter);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        IERC20(tokenIn).forceApprove(v2Router, amountIn);
        uint256[] memory amounts = IUniswapV2RouterPeriphery(v2Router)
            .swapExactTokensForTokens(amountIn, 0, _path3(tokenIn, tokenOut), recipient, deadline);
        amountOut = amounts[2];
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, recipient);
    }

    function _addLiquiditySUSDS(
        address target,
        uint256 susdsDesired,
        uint256 targetDesired,
        uint256 susdsMin,
        uint256 targetMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 susdsUsed, uint256 targetUsed, uint256 liquidity) {
        if (recipient == address(0)) revert ZeroAddress();
        address lp = _requirePair(target);
        IERC20(sUSDS).safeTransferFrom(msg.sender, address(this), susdsDesired);
        IERC20(target).safeTransferFrom(msg.sender, address(this), targetDesired);

        (susdsUsed, targetUsed, liquidity) =
            _addLiquidity(target, susdsDesired, targetDesired, susdsMin, targetMin, recipient, deadline);

        if (susdsDesired > susdsUsed) IERC20(sUSDS).safeTransfer(recipient, susdsDesired - susdsUsed);
        if (targetDesired > targetUsed) IERC20(target).safeTransfer(recipient, targetDesired - targetUsed);
        emit LiquidityAdded(msg.sender, sUSDS, lp, susdsUsed, targetUsed, liquidity, recipient);
    }

    function _addLiquidityUSDS(
        address target,
        uint256 usdsDesired,
        uint256 targetDesired,
        uint256 usdsMin,
        uint256 targetMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 usdsUsed, uint256 targetUsed, uint256 liquidity) {
        if (recipient == address(0)) revert ZeroAddress();
        address lp = _requirePair(target);
        IERC20(USDS).safeTransferFrom(msg.sender, address(this), usdsDesired);
        IERC20(target).safeTransferFrom(msg.sender, address(this), targetDesired);

        // Same block, same rate: previewDeposit before deposit floors exactly as deposit will.
        uint256 sharesMin = IERC4626(sUSDS).previewDeposit(usdsMin);
        uint256 shares = _depositUsds(usdsDesired);

        uint256 sharesUsed;
        (sharesUsed, targetUsed, liquidity) =
            _addLiquidity(target, shares, targetDesired, sharesMin, targetMin, recipient, deadline);

        uint256 usdsRefunded;
        if (shares > sharesUsed) usdsRefunded = IERC4626(sUSDS).redeem(shares - sharesUsed, recipient, address(this));
        if (targetDesired > targetUsed) IERC20(target).safeTransfer(recipient, targetDesired - targetUsed);
        usdsUsed = usdsDesired - usdsRefunded;
        emit LiquidityAdded(msg.sender, USDS, lp, usdsUsed, targetUsed, liquidity, recipient);
    }

    function _removeLiquiditySUSDS(
        address target,
        uint256 liquidity,
        uint256 susdsMin,
        uint256 targetMin,
        address recipient
    ) internal returns (uint256 susdsOut, uint256 targetOut) {
        if (recipient == address(0)) revert ZeroAddress();
        if (liquidity == 0) revert ZeroAmount();
        address lp = _requirePair(target);
        (susdsOut, targetOut) = _burnLiquidity(lp, target, liquidity, recipient);
        if (susdsOut < susdsMin) revert InsufficientOutput(susdsOut, susdsMin);
        if (targetOut < targetMin) revert InsufficientOutput(targetOut, targetMin);
        emit LiquidityRemoved(msg.sender, lp, sUSDS, liquidity, susdsOut, targetOut, recipient);
    }

    function _removeLiquidityUSDS(
        address target,
        uint256 liquidity,
        uint256 usdsMin,
        uint256 targetMin,
        address recipient
    ) internal returns (uint256 usdsOut, uint256 targetOut) {
        if (recipient == address(0)) revert ZeroAddress();
        if (liquidity == 0) revert ZeroAmount();
        address lp = _requirePair(target);
        uint256 shares;
        (shares, targetOut) = _burnLiquidity(lp, target, liquidity, address(this));
        if (targetOut < targetMin) revert InsufficientOutput(targetOut, targetMin);

        usdsOut = shares == 0 ? 0 : IERC4626(sUSDS).redeem(shares, recipient, address(this));
        if (usdsOut < usdsMin) revert InsufficientOutput(usdsOut, usdsMin);
        IERC20(target).safeTransfer(recipient, targetOut);
        emit LiquidityRemoved(msg.sender, lp, USDS, liquidity, usdsOut, targetOut, recipient);
    }

    // ============ Internal: legs ============

    function _checkSwapArgs(uint256 amountIn, address recipient) internal pure {
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
    }

    function _isStable(address token) internal view returns (bool) {
        return token == sUSDS || token == USDS || token == USDC || token == DOLA || token == USDe;
    }

    function _pairOf(address target) internal view returns (address) {
        return IUniswapV2Factory(IUniswapV2RouterPeriphery(v2Router).factory()).getPair(sUSDS, target);
    }

    function _requirePair(address target) internal view returns (address p) {
        p = _pairOf(target);
        if (p == address(0)) revert PairNotFound();
    }

    /// @dev Converts `amount` of a supported stable held by this contract into sUSDS held by this contract.
    function _toSusds(address token, uint256 amount) internal returns (uint256 shares) {
        if (token == sUSDS) return amount;
        if (token == USDS) return _depositUsds(amount);
        uint256 usdc = amount;
        if (token == DOLA) {
            IERC20(DOLA).forceApprove(curveDolaPool, amount);
            usdc = ICurveMetaPool(curveDolaPool).exchange_underlying(CURVE_META_DOLA, CURVE_META_USDC, amount, 0);
        } else if (token == USDe) {
            IERC20(USDe).forceApprove(curveUsdePool, amount);
            usdc = ICurveStableSwapNG(curveUsdePool).exchange(CURVE_NG_USDE, CURVE_NG_USDC, amount, 0);
        }
        // token is now USDC
        IERC20(USDC).forceApprove(skyPSM, usdc);
        uint256 usds = ISkyPSM(skyPSM).sellGem(address(this), usdc);
        return _depositUsds(usds);
    }

    /// @dev Converts `shares` sUSDS held by this contract into `token`, delivered to `recipient`.
    function _fromSusds(address token, uint256 shares, address recipient) internal returns (uint256 amountOut) {
        if (token == USDS) return IERC4626(sUSDS).redeem(shares, recipient, address(this));

        uint256 usds = IERC4626(sUSDS).redeem(shares, address(this), address(this));
        if (token == USDC) return _usdsToUsdc(usds, recipient, recipient);

        uint256 usdc = _usdsToUsdc(usds, address(this), recipient);
        if (usdc == 0) return 0;
        if (token == DOLA) {
            IERC20(USDC).forceApprove(curveDolaPool, usdc);
            amountOut = ICurveMetaPool(curveDolaPool).exchange_underlying(CURVE_META_USDC, CURVE_META_DOLA, usdc, 0);
        } else {
            IERC20(USDC).forceApprove(curveUsdePool, usdc);
            amountOut = ICurveStableSwapNG(curveUsdePool).exchange(CURVE_NG_USDC, CURVE_NG_USDE, usdc, 0);
        }
        IERC20(token).safeTransfer(recipient, amountOut);
    }

    /// @dev USDS held by this contract -> USDC via PSM `buyGem`, floored; USDC goes to `usdcTo`, any
    ///      USDS remainder is refunded to `dustTo`.
    function _usdsToUsdc(uint256 usds, address usdcTo, address dustTo) internal returns (uint256 gemAmt) {
        gemAmt = psmGemForUsds(usds);
        uint256 spent;
        if (gemAmt > 0) {
            IERC20(USDS).forceApprove(skyPSM, usds);
            spent = ISkyPSM(skyPSM).buyGem(usdcTo, gemAmt);
            IERC20(USDS).forceApprove(skyPSM, 0);
        }
        if (usds > spent) IERC20(USDS).safeTransfer(dustTo, usds - spent);
    }

    function _depositUsds(uint256 usds) internal returns (uint256 shares) {
        IERC20(USDS).forceApprove(sUSDS, usds);
        shares = IERC4626(sUSDS).deposit(usds, address(this));
    }

    function _v2Swap(address tokenIn, address tokenOut, uint256 amountIn, address to, uint256 deadline)
        internal
        returns (uint256)
    {
        IERC20(tokenIn).forceApprove(v2Router, amountIn);
        uint256[] memory amounts = IUniswapV2RouterPeriphery(v2Router)
            .swapExactTokensForTokens(amountIn, 0, _path(tokenIn, tokenOut), to, deadline);
        return amounts[1];
    }

    function _v3Swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 deadline) internal returns (uint256) {
        IERC20(tokenIn).forceApprove(v3SwapRouter, amountIn);
        return IUniswapV3SwapRouter(v3SwapRouter)
            .exactInputSingle(
                IUniswapV3SwapRouter.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: v3Fee,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    /// @dev Moves `liquidity` LP from msg.sender straight to the sUSDS/`target` pair and burns it,
    ///      sending both tokens to `to`. Returns the amounts ordered (sUSDS, target).
    function _burnLiquidity(address lp, address target, uint256 liquidity, address to)
        internal
        returns (uint256 susdsOut, uint256 targetOut)
    {
        IERC20(lp).safeTransferFrom(msg.sender, lp, liquidity);
        (uint256 amount0, uint256 amount1) = IUniswapV2PairBurn(lp).burn(to);
        (susdsOut, targetOut) = sUSDS < target ? (amount0, amount1) : (amount1, amount0);
    }

    /// @dev Router02 add of sUSDS + `target` already held by this contract; LP to `recipient`. Resets
    ///      both allowances afterwards, since the router may not consume the full desired amounts.
    function _addLiquidity(
        address target,
        uint256 susdsDesired,
        uint256 targetDesired,
        uint256 susdsMin,
        uint256 targetMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 susdsUsed, uint256 targetUsed, uint256 liquidity) {
        IERC20(sUSDS).forceApprove(v2Router, susdsDesired);
        IERC20(target).forceApprove(v2Router, targetDesired);
        (susdsUsed, targetUsed, liquidity) = IUniswapV2RouterPeriphery(v2Router)
            .addLiquidity(sUSDS, target, susdsDesired, targetDesired, susdsMin, targetMin, recipient, deadline);
        IERC20(sUSDS).forceApprove(v2Router, 0);
        IERC20(target).forceApprove(v2Router, 0);
    }

    // ============ Internal: quotes ============

    function _quoteToSusds(address token, uint256 amount) internal view returns (uint256) {
        if (token == sUSDS) return amount;
        if (token == USDS) return IERC4626(sUSDS).previewDeposit(amount);
        uint256 usdc = amount;
        if (token == DOLA) {
            usdc = ICurveMetaPool(curveDolaPool).get_dy_underlying(CURVE_META_DOLA, CURVE_META_USDC, amount);
        } else if (token == USDe) {
            usdc = ICurveStableSwapNG(curveUsdePool).get_dy(CURVE_NG_USDE, CURVE_NG_USDC, amount);
        }
        // DssLitePsm._sellGem: usdsOut = gemAmt * conv; usdsOut -= usdsOut * tin / WAD.
        uint256 usds = usdc * ISkyPSM(skyPSM).to18ConversionFactor();
        usds -= (usds * ISkyPSM(skyPSM).tin()) / WAD;
        return IERC4626(sUSDS).previewDeposit(usds);
    }

    function _quoteFromSusds(address token, uint256 shares) internal view returns (uint256) {
        if (token == sUSDS) return shares;
        uint256 usds = IERC4626(sUSDS).previewRedeem(shares);
        if (token == USDS) return usds;
        uint256 usdc = psmGemForUsds(usds);
        if (token == USDC || usdc == 0) return usdc;
        if (token == DOLA) {
            return ICurveMetaPool(curveDolaPool).get_dy_underlying(CURVE_META_USDC, CURVE_META_DOLA, usdc);
        }
        return ICurveStableSwapNG(curveUsdePool).get_dy(CURVE_NG_USDC, CURVE_NG_USDE, usdc);
    }

    /// @dev sUSDS -> `target` over the sUSDS/target pair.
    function _quoteSusdsTo(address target, uint256 shares) internal view returns (uint256) {
        if (shares == 0) return 0;
        return IUniswapV2RouterPeriphery(v2Router).getAmountsOut(shares, _path(sUSDS, target))[1];
    }

    /// @dev `target` -> sUSDS over the sUSDS/target pair.
    function _quoteToSusdsFrom(address target, uint256 amountIn) internal view returns (uint256) {
        if (amountIn == 0) return 0;
        return IUniswapV2RouterPeriphery(v2Router).getAmountsOut(amountIn, _path(target, sUSDS))[1];
    }

    /// @dev phUSD <-> AM over the 3-hop path, matching `_swapAcross`.
    function _quoteAcross(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        _requirePair(antimatter);
        if (amountIn == 0) return 0;
        return IUniswapV2RouterPeriphery(v2Router).getAmountsOut(amountIn, _path3(tokenIn, tokenOut))[2];
    }

    function _quoteV3(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        (amountOut,,,) = IQuoterV2(v3Quoter)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: v3Fee, sqrtPriceLimitX96: 0
                })
            );
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    /// @dev [a, sUSDS, b]: the two-pair path through the sUSDS hub.
    function _path3(address a, address b) internal view returns (address[] memory p) {
        p = new address[](3);
        p[0] = a;
        p[1] = sUSDS;
        p[2] = b;
    }
}
