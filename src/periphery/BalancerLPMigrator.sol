// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ---------------------------------------------------------------------------------------------
// Minimal local interfaces. Balancer V3 is declared HERE, never imported from a submodule: story
// 107 removed the Balancer keys and yield-claim-nft:050 deleted its Balancer interfaces. The
// shapes mirror `UniPoolerCutoverEscrow.sol` and its fork test, and were re-checked against the
// mainnet Vault/Router on a fork (story 121).
// ---------------------------------------------------------------------------------------------

/// @notice The Balancer V3 Vault views and the one permissionless admin call the migrator uses.
interface IBalancerV3VaultMigrator {
    /// @dev Mirrors the Vault's per-token info struct (token type, rate provider, pays yield fees).
    struct TokenInfo {
        uint8 tokenType;
        address rateProvider;
        bool paysYieldFees;
    }

    function getPoolTokens(address pool) external view returns (address[] memory tokens);

    function getPoolTokenInfo(address pool)
        external
        view
        returns (
            address[] memory tokens,
            TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );

    function totalSupply(address token) external view returns (uint256);
    function isPoolInRecoveryMode(address pool) external view returns (bool);
    function isPoolPaused(address pool) external view returns (bool);
    function isVaultPaused() external view returns (bool);

    /// @dev Permissionless while the pool or the Vault is paused (VaultAdmin).
    function enableRecoveryMode(address pool) external;
}

/// @notice The two Balancer V3 Router exits (mainnet selectors `0x51682750`, `0x08c04793`).
interface IBalancerV3RouterMigrator {
    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external payable returns (uint256[] memory amountsOut);

    function removeLiquidityRecovery(address pool, uint256 exactBptAmountIn, uint256[] memory minAmountsOut)
        external
        payable
        returns (uint256[] memory amountsOut);
}

/// @notice The Uniswap V2 Router02 surface the migrator uses.
interface IUniV2RouterMigrator {
    function factory() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/// @notice The Uniswap V2 factory surface the migrator uses.
interface IUniV2FactoryMigrator {
    function getPair(address tokenA, address tokenB) external view returns (address);
    function feeTo() external view returns (address);
}

/// @notice The Uniswap V2 pair views `previewMigrate` reads.
interface IUniV2PairMigrator {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function kLast() external view returns (uint256);
}

/// @title  BalancerLPMigrator  (story 121, sprint balancer-lp-migrator)
/// @notice Moves a holder's Balancer V3 phUSD/sUSDS BPT into the Uniswap V2 phUSD/sUSDS pair in ONE
///         transaction: pull the BPT, exit the Balancer pool, add the proceeds to the V2 pair with the
///         LP going to `to`, and refund whichever token the V2 ratio left over to the caller.
/// @dev ### Exit mode is decided on-chain, never by the caller or the clock
///      - pool already in Recovery Mode           -> `removeLiquidityRecovery`;
///      - pool paused, or the whole Vault paused  -> `vault.enableRecoveryMode(pool)` (permissionless
///        while paused), then `removeLiquidityRecovery`;
///      - otherwise                               -> `removeLiquidityProportional`.
///      Balancer's BIP-928 wind-down pauses the pool from 30 Oct 2026 and the Vault from 30 Nov 2026;
///      the proportional exit reverts `PoolPaused` from the first date, the recovery exit keeps working.
///
///      ### Leftover
///      The Balancer and V2 ratios never match exactly, so Router02's `addLiquidity` consumes all of one
///      token and part of the other. The unused part is refunded to `msg.sender` as the raw token (no
///      sUSDS -> USDS redemption). `previewMigrate` reports which side that will be.
///
///      ### Custody
///      Stateless and ownerless: no admin, no setter, no storage beyond the immutables, no sweep. Every
///      transfer out uses the deltas of the current call only, and every allowance it grants is reset
///      to zero before returning, so after a call the contract holds no BPT, sUSDS, phUSD or LP.
///      The Balancer and V2 minimums (all four must be non-zero) are the caller's slippage guards.
contract BalancerLPMigrator {
    using SafeERC20 for IERC20;

    // ---- Immutables (every one public: the UI discovers the BPT only through `pool()`) ----

    /// @notice The Balancer V3 Vault.
    address public immutable vault;
    /// @notice The Balancer V3 Router used for the exit.
    address public immutable v3Router;
    /// @notice The Balancer V3 phUSD/sUSDS pool, which is also the BPT.
    address public immutable pool;
    /// @notice The Uniswap V2 Router02 used for the add.
    address public immutable uniRouter;
    /// @notice sUSDS (Sky savings USDS).
    address public immutable sUSDS;
    /// @notice phUSD.
    address public immutable phUSD;
    /// @notice The Uniswap V2 phUSD/sUSDS pair (`factory.getPair(sUSDS, phUSD)`), resolved at construction.
    address public immutable pair;
    /// @notice sUSDS's index in the Balancer pool's token order.
    uint256 public immutable sUSDSIndex;
    /// @notice phUSD's index in the Balancer pool's token order.
    uint256 public immutable phUSDIndex;

    /// @dev Uniswap V2's MINIMUM_LIQUIDITY, burnt on a pair's first mint.
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    /// @notice One migration.
    /// @param user The caller: paid the BPT and received the refunds.
    /// @param to The V2 LP recipient.
    /// @param bptAmount The BPT exited.
    /// @param recoveryMode True when the exit went through `removeLiquidityRecovery`.
    /// @param sUSDSOut sUSDS received from the Balancer exit.
    /// @param phUSDOut phUSD received from the Balancer exit.
    /// @param liquidity V2 LP minted to `to`.
    /// @param sUSDSRefund sUSDS refunded to `user`.
    /// @param phUSDRefund phUSD refunded to `user`.
    event Migrated(
        address indexed user,
        address indexed to,
        uint256 bptAmount,
        bool recoveryMode,
        uint256 sUSDSOut,
        uint256 phUSDOut,
        uint256 liquidity,
        uint256 sUSDSRefund,
        uint256 phUSDRefund
    );

    error ZeroAddress();
    error ZeroAmount();
    error ZeroMinimum();
    error Expired();
    error PoolTokensMismatch();
    error PairNotFound();

    constructor(address vault_, address v3Router_, address pool_, address uniRouter_, address sUSDS_, address phUSD_) {
        if (
            vault_ == address(0) || v3Router_ == address(0) || pool_ == address(0) || uniRouter_ == address(0)
                || sUSDS_ == address(0) || phUSD_ == address(0)
        ) revert ZeroAddress();

        address[] memory tokens = IBalancerV3VaultMigrator(vault_).getPoolTokens(pool_);
        if (tokens.length != 2) revert PoolTokensMismatch();
        uint256 sIdx;
        if (tokens[0] == sUSDS_ && tokens[1] == phUSD_) {
            sIdx = 0;
        } else if (tokens[0] == phUSD_ && tokens[1] == sUSDS_) {
            sIdx = 1;
        } else {
            revert PoolTokensMismatch();
        }

        address pair_ = IUniV2FactoryMigrator(IUniV2RouterMigrator(uniRouter_).factory()).getPair(sUSDS_, phUSD_);
        if (pair_ == address(0)) revert PairNotFound();

        vault = vault_;
        v3Router = v3Router_;
        pool = pool_;
        uniRouter = uniRouter_;
        sUSDS = sUSDS_;
        phUSD = phUSD_;
        pair = pair_;
        sUSDSIndex = sIdx;
        phUSDIndex = 1 - sIdx;
    }

    // ============ Migrate ============

    /// @notice Exit `bptAmount` BPT from Balancer and add the proceeds to the V2 phUSD/sUSDS pair.
    /// @param bptAmount BPT pulled from msg.sender (needs a plain ERC20 allowance on `pool()`).
    /// @param minSUSDSOut Floor on the sUSDS the Balancer exit returns.
    /// @param minPhUSDOut Floor on the phUSD the Balancer exit returns.
    /// @param amountSUSDSMin Router02 floor on the sUSDS added to the pair.
    /// @param amountPhUSDMin Router02 floor on the phUSD added to the pair.
    /// @param to The V2 LP recipient.
    /// @param deadline Last valid timestamp, also passed to Router02.
    /// @return sUSDSOut sUSDS received from the exit (balance delta).
    /// @return phUSDOut phUSD received from the exit (balance delta).
    /// @return liquidity V2 LP minted to `to`.
    /// @return sUSDSRefund sUSDS refunded to msg.sender.
    /// @return phUSDRefund phUSD refunded to msg.sender.
    function migrate(
        uint256 bptAmount,
        uint256 minSUSDSOut,
        uint256 minPhUSDOut,
        uint256 amountSUSDSMin,
        uint256 amountPhUSDMin,
        address to,
        uint256 deadline
    )
        external
        returns (uint256 sUSDSOut, uint256 phUSDOut, uint256 liquidity, uint256 sUSDSRefund, uint256 phUSDRefund)
    {
        if (bptAmount == 0) {
            revert ZeroAmount();
        }
        if (to == address(0)) revert ZeroAddress();
        if (deadline < block.timestamp) revert Expired();
        if (minSUSDSOut == 0 || minPhUSDOut == 0 || amountSUSDSMin == 0 || amountPhUSDMin == 0) {
            revert ZeroMinimum();
        }

        IERC20(pool).safeTransferFrom(msg.sender, address(this), bptAmount);

        bool recoveryMode = _prepareExitMode();
        (sUSDSOut, phUSDOut) = _exit(bptAmount, minSUSDSOut, minPhUSDOut, recoveryMode);

        uint256 sUSDSUsed;
        uint256 phUSDUsed;
        IERC20(sUSDS).forceApprove(uniRouter, sUSDSOut);
        IERC20(phUSD).forceApprove(uniRouter, phUSDOut);
        (sUSDSUsed, phUSDUsed, liquidity) = IUniV2RouterMigrator(uniRouter)
            .addLiquidity(sUSDS, phUSD, sUSDSOut, phUSDOut, amountSUSDSMin, amountPhUSDMin, to, deadline);
        IERC20(sUSDS).forceApprove(uniRouter, 0);
        IERC20(phUSD).forceApprove(uniRouter, 0);

        sUSDSRefund = sUSDSOut - sUSDSUsed;
        phUSDRefund = phUSDOut - phUSDUsed;
        if (sUSDSRefund > 0) IERC20(sUSDS).safeTransfer(msg.sender, sUSDSRefund);
        if (phUSDRefund > 0) IERC20(phUSD).safeTransfer(msg.sender, phUSDRefund);

        emit Migrated(msg.sender, to, bptAmount, recoveryMode, sUSDSOut, phUSDOut, liquidity, sUSDSRefund, phUSDRefund);
    }

    // ============ Preview ============

    /// @notice What `migrate(bptAmount, ...)` would do against the current state.
    /// @dev Balancer side: the proportional share `balancesRaw[i] * bptAmount / totalSupply`, rounded down,
    ///      which both exits pay for this rate-less pool. V2 side: Router02's optimal-amount logic against
    ///      `getReserves()`, and the pair's `mint` maths including the protocol fee (`feeTo` is live) that
    ///      `mint` accrues before pricing the new LP. Use it for the four slippage floors and to tell the
    ///      user which token will be left over.
    /// @return sUSDSOut Expected sUSDS from the exit.
    /// @return phUSDOut Expected phUSD from the exit.
    /// @return sUSDSUsed Expected sUSDS added to the pair.
    /// @return phUSDUsed Expected phUSD added to the pair.
    /// @return leftoverToken The token refunded to the caller (sUSDS or phUSD), or address(0) when none.
    /// @return leftoverAmount The amount of `leftoverToken` refunded.
    /// @return recoveryMode True when `migrate` would exit through `removeLiquidityRecovery`.
    /// @return expectedLiquidity Expected V2 LP minted to `to`.
    function previewMigrate(uint256 bptAmount)
        external
        view
        returns (
            uint256 sUSDSOut,
            uint256 phUSDOut,
            uint256 sUSDSUsed,
            uint256 phUSDUsed,
            address leftoverToken,
            uint256 leftoverAmount,
            bool recoveryMode,
            uint256 expectedLiquidity
        )
    {
        recoveryMode = _wouldUseRecovery();

        (,, uint256[] memory balancesRaw,) = IBalancerV3VaultMigrator(vault).getPoolTokenInfo(pool);
        uint256 supply = IBalancerV3VaultMigrator(vault).totalSupply(pool);
        if (supply > 0) {
            sUSDSOut = (balancesRaw[sUSDSIndex] * bptAmount) / supply;
            phUSDOut = (balancesRaw[phUSDIndex] * bptAmount) / supply;
        }

        (uint256 reserveS, uint256 reserveP, uint256 lpSupply) = _pairState();
        (sUSDSUsed, phUSDUsed) = _optimalAmounts(sUSDSOut, phUSDOut, reserveS, reserveP);

        if (sUSDSOut > sUSDSUsed) {
            leftoverToken = sUSDS;
            leftoverAmount = sUSDSOut - sUSDSUsed;
        } else if (phUSDOut > phUSDUsed) {
            leftoverToken = phUSD;
            leftoverAmount = phUSDOut - phUSDUsed;
        }

        if (lpSupply == 0) {
            uint256 root = Math.sqrt(sUSDSUsed * phUSDUsed);
            expectedLiquidity = root > MINIMUM_LIQUIDITY ? root - MINIMUM_LIQUIDITY : 0;
        } else {
            expectedLiquidity = Math.min((sUSDSUsed * lpSupply) / reserveS, (phUSDUsed * lpSupply) / reserveP);
        }
    }

    // ============ Internal ============

    /// @dev True when `migrate` will exit through recovery (already in recovery, or paused so it can enable it).
    function _wouldUseRecovery() internal view returns (bool) {
        IBalancerV3VaultMigrator v = IBalancerV3VaultMigrator(vault);
        return v.isPoolInRecoveryMode(pool) || v.isPoolPaused(pool) || v.isVaultPaused();
    }

    /// @dev Decides the exit on-chain and, when the pool or Vault is paused but recovery is not yet on,
    ///      enables Recovery Mode itself (permissionless while paused). Returns true for the recovery exit.
    function _prepareExitMode() internal returns (bool) {
        IBalancerV3VaultMigrator v = IBalancerV3VaultMigrator(vault);
        if (v.isPoolInRecoveryMode(pool)) return true;
        if (v.isPoolPaused(pool) || v.isVaultPaused()) {
            v.enableRecoveryMode(pool);
            return true;
        }
        return false;
    }

    /// @dev Burns `bptAmount` through the V3 Router (plain ERC20 allowance, no Permit2) and returns the
    ///      sUSDS/phUSD balance deltas. The router allowance is reset to zero afterwards.
    function _exit(uint256 bptAmount, uint256 minSUSDSOut, uint256 minPhUSDOut, bool recoveryMode)
        internal
        returns (uint256 sUSDSOut, uint256 phUSDOut)
    {
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[sUSDSIndex] = minSUSDSOut;
        minAmountsOut[phUSDIndex] = minPhUSDOut;

        uint256 sBefore = IERC20(sUSDS).balanceOf(address(this));
        uint256 pBefore = IERC20(phUSD).balanceOf(address(this));

        IERC20(pool).forceApprove(v3Router, bptAmount);
        if (recoveryMode) {
            IBalancerV3RouterMigrator(v3Router).removeLiquidityRecovery(pool, bptAmount, minAmountsOut);
        } else {
            IBalancerV3RouterMigrator(v3Router).removeLiquidityProportional(pool, bptAmount, minAmountsOut, false, "");
        }
        IERC20(pool).forceApprove(v3Router, 0);

        sUSDSOut = IERC20(sUSDS).balanceOf(address(this)) - sBefore;
        phUSDOut = IERC20(phUSD).balanceOf(address(this)) - pBefore;
    }

    /// @dev The pair's reserves ordered (sUSDS, phUSD), and its LP supply after the protocol fee `mint`
    ///      would accrue first (UniswapV2Pair `_mintFee`: 1/6 of sqrt(k) growth since `kLast`).
    function _pairState() internal view returns (uint256 reserveS, uint256 reserveP, uint256 lpSupply) {
        (uint112 r0, uint112 r1,) = IUniV2PairMigrator(pair).getReserves();
        (reserveS, reserveP) =
            IUniV2PairMigrator(pair).token0() == sUSDS ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        lpSupply = IUniV2PairMigrator(pair).totalSupply();

        address feeTo = IUniV2FactoryMigrator(IUniV2RouterMigrator(uniRouter).factory()).feeTo();
        uint256 kLast = IUniV2PairMigrator(pair).kLast();
        if (feeTo != address(0) && kLast != 0) {
            uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
            uint256 rootKLast = Math.sqrt(kLast);
            if (rootK > rootKLast) {
                lpSupply += (lpSupply * (rootK - rootKLast)) / (rootK * 5 + rootKLast);
            }
        }
    }

    /// @dev Router02 `_addLiquidity`: the amounts it actually takes from (sDesired, pDesired).
    function _optimalAmounts(uint256 sDesired, uint256 pDesired, uint256 reserveS, uint256 reserveP)
        internal
        pure
        returns (uint256 sUsed, uint256 pUsed)
    {
        if (reserveS == 0 && reserveP == 0) return (sDesired, pDesired);
        uint256 pOptimal = (sDesired * reserveP) / reserveS;
        if (pOptimal <= pDesired) return (sDesired, pOptimal);
        uint256 sOptimal = (pDesired * reserveS) / reserveP;
        return (sOptimal, pDesired);
    }
}
