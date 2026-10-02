// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";

/**
 * @title UniPoolerCutoverCore
 * @notice Story 100. The single shared implementation of the Balancexit index-4 cutover:
 *         `BalancerPoolerV2` (Balancer V3 phUSD/sUSDS pool) -> `UniPoolerV2` (Uniswap V2
 *         phUSD/sUSDS pair). The anvil dress rehearsal (101), the mainnet cutover script (103) and
 *         its fork test (103) all inherit THIS contract, as `StableStakerCutoverCore` is inherited
 *         by both the StableStaker cutover script and its test, so the three cannot drift.
 *
 * @dev SEQUENCE (docs/BalancerWinddownPlan.md §4 Stage 2, as corrected by phStaging2:108 for
 *      yield-claim-nft:051's canonical-pair constructor check). Each step is an internal function;
 *      `_runCutover` runs them strictly in this order:
 *
 *        0. Preconditions, all `require`d, before any state change: the old pooler's authorized-
 *           pooler set is revoked (each listed pooler fails `onlyAuthorizedPooler`, i.e.
 *           `poolerAuthVersion(p) != authVersion` — story 099's `incrementAuthVersion`); index 4,
 *           the hook and the old pooler point at each other; `minAmountsOut` has one non-zero
 *           entry per pool token; tolerances are tight. Every address and config value the core
 *           needs beyond the caller's inputs is read live from the old pooler and the hook.
 *        1. Create the canonical sUSDS/phUSD pair through the router's own factory if missing
 *           (reuse it if someone else created it).
 *        2. Make sure the pair is empty: `skim(OWNER)` any unsynced donation, then require
 *           reserves (0,0) AND balances (0,0).
 *        3. Deploy `UniPoolerV2` against that pair (not wired).
 *        4. `BalancerPoolerV2.withdrawBPT(OWNER, fullBalance)`.
 *        5. Exit the OWNER's WHOLE BPT balance through the Balancer V3 Router: proportional or
 *           recovery, chosen by the `exitMode` PARAMETER (never by the clock). `minAmountsOut` is
 *           checked against the live proportional share minus `exitToleranceBps`.
 *        6. Seed the pair with ALL the recovered sUSDS and phUSD in one Router02 `addLiquidity`,
 *           `to = UniPoolerV2`. Only tokens recovered from Balancer seed it (balance deltas).
 *        7. `hook.pull()`, then `require(mintDebt() == 0)`.
 *        8. `hook.setDispatcher(UniPoolerV2)`, THEN `UniPoolerV2.setHook(hook)`.
 *        9. Configure `UniPoolerV2`: `setMinter(NFTMinterV2)`; copy PSM, maxTout, batchMinter,
 *           batchDonationSize and nudgeStreamer (last) live from the old pooler; authorize the
 *           same poolers. NO Pauser registration (dispatchers have no `pauser()`).
 *       10. `NFTMinterV2.replaceDispatcher(4, UniPoolerV2)`, asserting price/growth/disabled for
 *           the index are unchanged.
 *       11. Move the old pooler's balances, read live after step 10: all sUSDS to `UniPoolerV2`;
 *           parked USDS to `UniPoolerV2` when its donation is live, otherwise to OWNER and then
 *           `sUSDS.deposit(amount, UniPoolerV2)` from OWNER.
 *       12. Retire the old pooler: `old.setMinter(OWNER)` then `old.pause()`. NO Pauser unregister.
 *      A closing `_assertRetired` re-checks the end state (old pooler drained and paused, owner
 *      holds no BPT, index 4 and the hook on the new pooler). The full verify is 103's.
 *
 *      EXECUTION CONTEXT is the caller's, as in `StableStakerCutoverCore`: every external call is
 *      made from the inheriting contract at its own call depth, so a script wraps `_runCutover` in
 *      `vm.startBroadcast(OWNER)` and a test makes the test contract the OWNER. `p.owner` must be
 *      that sender; step 0 checks it owns the old pooler, the hook and the NFT minter.
 *
 *      BALANCER INTERFACES are declared here on purpose (not imported from yield-claim-nft), so
 *      yield-claim-nft can delete its Balancer interfaces (story 050) without breaking this core.
 *      The Router signatures match the mainnet Balancer V3 Router
 *      `0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd` (selectors 0x51682750 and 0x08c04793 are in
 *      its deployed bytecode); the Router burns the caller's BPT by spending the ROUTER's BPT
 *      allowance (mainnet reverts `ERC20InsufficientAllowance(router, ...)` without it), so step 5
 *      approves the Router for exactly the BPT exited.
 */

/// @notice Balancer V3 Router exits (mainnet Router 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd).
interface IBalancerV3RouterExit {
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

/// @notice Balancer V3 Vault pool views (mainnet Vault 0xbA1333333333a1BA1108E8412f11850A5C319bA9).
interface IBalancerV3VaultViews {
    /// @dev Mirrors V3 `TokenInfo { TokenType tokenType; IRateProvider rateProvider; bool paysYieldFees; }`.
    struct TokenInfo {
        uint8 tokenType;
        address rateProvider;
        bool paysYieldFees;
    }

    function getPoolTokenInfo(address pool)
        external
        view
        returns (
            address[] memory tokens,
            TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );
}

/// @notice The live `BalancerPoolerV2` surface the cutover reads and drives.
interface ICutoverBalancerPooler {
    function owner() external view returns (address);
    function sUSDS() external view returns (address);
    function primeToken() external view returns (address);
    function pool() external view returns (address);
    function vault() external view returns (address);
    function hook() external view returns (address);
    function paused() external view returns (bool);
    function authVersion() external view returns (uint256);
    function poolerAuthVersion(address pooler) external view returns (uint256);
    function psm() external view returns (address);
    function maxTout() external view returns (uint256);
    function batchMinter() external view returns (address);
    function nudgeStreamer() external view returns (address);
    function batchDonationSize() external view returns (uint256);
    function withdrawBPT(address recipient, uint256 amount) external;
    function rescueERC20(address token, address to, uint256 amount) external;
    function setMinter(address minter_) external;
    function pause() external;
}

/// @notice `BalancerPoolerMintDebtHook`.
interface ICutoverMintDebtHook {
    function owner() external view returns (address);
    function dispatcher() external view returns (address);
    function phUSD() external view returns (address);
    function mintDebt() external view returns (uint256);
    function pull() external;
    function setDispatcher(address newDispatcher) external;
}

/// @notice `NFTMinterV2`.
interface ICutoverNFTMinter {
    function owner() external view returns (address);
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
    function replaceDispatcher(uint256 index, address newDispatcher) external;
}

interface ICutoverUniV2Router {
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

interface ICutoverUniV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface ICutoverUniV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function balanceOf(address account) external view returns (uint256);
    function skim(address to) external;
}

interface ICutoverERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICutoverERC4626 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

abstract contract UniPoolerCutoverCore {
    uint256 internal constant CUTOVER_MAX_BPS = 10_000;
    /// @notice Ceiling on both tolerances: "tight" means at most 1%.
    uint256 internal constant CUTOVER_MAX_TOLERANCE_BPS = 100;

    /// @notice Which Balancer V3 exit step 5 uses. A parameter, never derived from the clock:
    ///         PROPORTIONAL while the pool is live (before 30 Oct), RECOVERY once it is paused.
    enum ExitMode {
        PROPORTIONAL,
        RECOVERY
    }

    /// @notice Caller inputs. Everything else is read live (see `CutoverLive`).
    struct CutoverParams {
        address owner; // the sender of every call; owns old pooler, hook and NFT minter
        address oldPooler; // BalancerPoolerV2 at the index
        address mintDebtHook; // BalancerPoolerMintDebtHook
        address nftMinter; // NFTMinterV2
        uint256 dispatcherIndex; // 4
        address uniV2Router; // Router02; its factory() creates/locates the pair
        address balancerRouter; // Balancer V3 Router (not exposed by BalancerPoolerV2)
        address[] poolers; // the poolers to re-authorize on UniPoolerV2 (must be revoked on old)
        ExitMode exitMode;
        uint256[] minAmountsOut; // Balancer pool-token order; every entry > 0
        uint256 exitToleranceBps; // max gap of minAmountsOut below the live proportional share
        uint256 seedToleranceBps; // addLiquidity amountAMin/amountBMin below the recovered amounts
    }

    /// @notice Addresses read live in step 0.
    struct CutoverLive {
        address sUSDS;
        address usds;
        address phUSD;
        address bPool;
        address bVault;
        address factory;
        address pair;
        address newPooler;
    }

    struct CutoverResult {
        address newPooler;
        address pair;
        uint256 bptWithdrawn; // from the old pooler in step 4
        uint256 bptExited; // the owner's whole BPT balance in step 5
        uint256 sUSDSRecovered;
        uint256 phUSDRecovered;
        uint256 liquidity;
        uint256 sUSDSRescued;
        uint256 usdsRescued;
        bool usdsWrapped; // parked USDS wrapped into sUSDS for the new pooler (donation disabled)
        uint256 usdsWrappedShares;
    }

    // ---------------------------------------------------------------------------- orchestrator

    /// @notice Runs steps 0 -> 12 in order and returns what moved. Reverts loudly on any breach.
    function _runCutover(CutoverParams memory p) internal returns (CutoverResult memory r) {
        CutoverLive memory l = _step0Preconditions(p);
        l.pair = _step1CreatePair(l);
        _step2EnsurePairEmpty(p, l);
        l.newPooler = _step3DeployPooler(p, l);
        r.newPooler = l.newPooler;
        r.pair = l.pair;
        r.bptWithdrawn = _step4WithdrawBPT(p, l);
        (r.bptExited, r.sUSDSRecovered, r.phUSDRecovered) = _step5ExitBalancer(p, l);
        r.liquidity = _step6SeedPair(p, l, r.sUSDSRecovered, r.phUSDRecovered);
        _step7PullDebt(p);
        _step8RepointHook(p, l);
        _step9ConfigurePooler(p, l);
        _step10ReplaceDispatcher(p, l);
        (r.sUSDSRescued, r.usdsRescued, r.usdsWrapped, r.usdsWrappedShares) = _step11MoveBalances(p, l);
        _step12RetireOld(p);
        _assertRetired(p, l);
    }

    // ----------------------------------------------------------------------------------- steps

    /// @notice Step 0. Preconditions, all checked before any state change.
    function _step0Preconditions(CutoverParams memory p) internal view returns (CutoverLive memory l) {
        ICutoverBalancerPooler old = ICutoverBalancerPooler(p.oldPooler);
        ICutoverMintDebtHook hook = ICutoverMintDebtHook(p.mintDebtHook);

        require(p.owner != address(0), "UniPoolerCutoverCore: zero owner");
        require(old.owner() == p.owner, "UniPoolerCutoverCore: owner does not own old pooler");
        require(hook.owner() == p.owner, "UniPoolerCutoverCore: owner does not own hook");
        require(ICutoverNFTMinter(p.nftMinter).owner() == p.owner, "UniPoolerCutoverCore: owner does not own minter");

        require(
            p.exitToleranceBps <= CUTOVER_MAX_TOLERANCE_BPS && p.seedToleranceBps <= CUTOVER_MAX_TOLERANCE_BPS,
            "UniPoolerCutoverCore: tolerance too wide"
        );

        // The authorized-pooler set is revoked: every pooler fails `onlyAuthorizedPooler`.
        require(p.poolers.length > 0, "UniPoolerCutoverCore: no poolers");
        uint256 av = old.authVersion();
        for (uint256 i = 0; i < p.poolers.length; i++) {
            require(p.poolers[i] != address(0), "UniPoolerCutoverCore: zero pooler");
            require(old.poolerAuthVersion(p.poolers[i]) != av, "UniPoolerCutoverCore: pooler still authorized");
        }

        // Index, hook and old pooler point at each other.
        (address d,,,) = ICutoverNFTMinter(p.nftMinter).configs(p.dispatcherIndex);
        require(d == p.oldPooler, "UniPoolerCutoverCore: index not on old pooler");
        require(hook.dispatcher() == p.oldPooler, "UniPoolerCutoverCore: hook not on old pooler");
        require(old.hook() == p.mintDebtHook, "UniPoolerCutoverCore: old pooler hook mismatch");

        // Live reads.
        l.sUSDS = old.sUSDS();
        l.usds = old.primeToken();
        l.phUSD = hook.phUSD();
        l.bPool = old.pool();
        l.bVault = old.vault();
        l.factory = ICutoverUniV2Router(p.uniV2Router).factory();
        require(
            l.sUSDS != address(0) && l.usds != address(0) && l.phUSD != address(0) && l.bPool != address(0)
                && l.bVault != address(0) && l.factory != address(0),
            "UniPoolerCutoverCore: zero live address"
        );

        // The Balancer pool is exactly {sUSDS, phUSD}, and minAmountsOut has a non-zero floor for each.
        (address[] memory tokens,,,) = IBalancerV3VaultViews(l.bVault).getPoolTokenInfo(l.bPool);
        require(tokens.length == 2, "UniPoolerCutoverCore: pool not two-token");
        require(
            (tokens[0] == l.sUSDS && tokens[1] == l.phUSD) || (tokens[0] == l.phUSD && tokens[1] == l.sUSDS),
            "UniPoolerCutoverCore: pool tokens mismatch"
        );
        require(p.minAmountsOut.length == tokens.length, "UniPoolerCutoverCore: minAmountsOut length");
        for (uint256 i = 0; i < p.minAmountsOut.length; i++) {
            require(p.minAmountsOut[i] > 0, "UniPoolerCutoverCore: zero minAmountOut");
        }
    }

    /// @notice Step 1. The canonical pair, created through the router's own factory if missing.
    function _step1CreatePair(CutoverLive memory l) internal returns (address pair) {
        pair = ICutoverUniV2Factory(l.factory).getPair(l.sUSDS, l.phUSD);
        if (pair == address(0)) {
            pair = ICutoverUniV2Factory(l.factory).createPair(l.sUSDS, l.phUSD);
        }
        require(pair != address(0), "UniPoolerCutoverCore: no pair");
    }

    /// @notice Step 2. Skim any unsynced donation to OWNER, then require reserves AND balances (0,0).
    function _step2EnsurePairEmpty(CutoverParams memory p, CutoverLive memory l) internal {
        ICutoverUniV2Pair pair = ICutoverUniV2Pair(l.pair);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        require(r0 == 0 && r1 == 0, "UniPoolerCutoverCore: pair reserves not empty");
        if (ICutoverERC20(l.sUSDS).balanceOf(l.pair) > 0 || ICutoverERC20(l.phUSD).balanceOf(l.pair) > 0) {
            pair.skim(p.owner);
        }
        (r0, r1,) = pair.getReserves();
        require(r0 == 0 && r1 == 0, "UniPoolerCutoverCore: pair reserves not empty");
        require(
            ICutoverERC20(l.sUSDS).balanceOf(l.pair) == 0 && ICutoverERC20(l.phUSD).balanceOf(l.pair) == 0,
            "UniPoolerCutoverCore: pair balances not empty"
        );
    }

    /// @notice Step 3. Deploy UniPoolerV2 against the (now existing, empty) canonical pair.
    function _step3DeployPooler(CutoverParams memory p, CutoverLive memory l) internal returns (address) {
        UniPoolerV2 np = new UniPoolerV2(l.sUSDS, l.phUSD, p.uniV2Router, l.pair, p.owner);
        require(np.pair() == l.pair && np.owner() == p.owner, "UniPoolerCutoverCore: deploy mismatch");
        return address(np);
    }

    /// @notice Step 4. All BPT on the old pooler to OWNER.
    function _step4WithdrawBPT(CutoverParams memory p, CutoverLive memory l) internal returns (uint256 bal) {
        bal = ICutoverERC20(l.bPool).balanceOf(p.oldPooler);
        if (bal > 0) {
            ICutoverBalancerPooler(p.oldPooler).withdrawBPT(p.owner, bal);
        }
        require(ICutoverERC20(l.bPool).balanceOf(p.oldPooler) == 0, "UniPoolerCutoverCore: BPT left on old pooler");
    }

    /// @notice Step 5. Exit the OWNER's whole BPT balance. Returns the BPT exited and the sUSDS
    ///         and phUSD received, measured as OWNER balance deltas.
    function _step5ExitBalancer(CutoverParams memory p, CutoverLive memory l)
        internal
        returns (uint256 bptIn, uint256 sOut, uint256 pOut)
    {
        bptIn = ICutoverERC20(l.bPool).balanceOf(p.owner);
        require(bptIn > 0, "UniPoolerCutoverCore: owner holds no BPT");
        _checkMinAmountsOut(p, l, bptIn);

        uint256 sBefore = ICutoverERC20(l.sUSDS).balanceOf(p.owner);
        uint256 pBefore = ICutoverERC20(l.phUSD).balanceOf(p.owner);

        ICutoverERC20(l.bPool).approve(p.balancerRouter, bptIn);
        if (p.exitMode == ExitMode.PROPORTIONAL) {
            IBalancerV3RouterExit(p.balancerRouter)
                .removeLiquidityProportional(l.bPool, bptIn, p.minAmountsOut, false, "");
        } else {
            IBalancerV3RouterExit(p.balancerRouter).removeLiquidityRecovery(l.bPool, bptIn, p.minAmountsOut);
        }

        require(ICutoverERC20(l.bPool).balanceOf(p.owner) == 0, "UniPoolerCutoverCore: owner BPT not fully exited");
        sOut = ICutoverERC20(l.sUSDS).balanceOf(p.owner) - sBefore;
        pOut = ICutoverERC20(l.phUSD).balanceOf(p.owner) - pBefore;
        require(sOut > 0 && pOut > 0, "UniPoolerCutoverCore: exit returned nothing");
    }

    /// @dev Every `minAmountsOut[i]` must sit in [share_i * (1 - tol), share_i], where
    ///      share_i = balancesRaw_i * bptIn / totalSupply is the live proportional share.
    function _checkMinAmountsOut(CutoverParams memory p, CutoverLive memory l, uint256 bptIn) internal view {
        (,, uint256[] memory raw,) = IBalancerV3VaultViews(l.bVault).getPoolTokenInfo(l.bPool);
        uint256 supply = _totalSupply(l.bPool);
        require(supply > 0, "UniPoolerCutoverCore: zero BPT supply");
        for (uint256 i = 0; i < raw.length; i++) {
            uint256 share = (raw[i] * bptIn) / supply;
            require(p.minAmountsOut[i] <= share, "UniPoolerCutoverCore: minAmountOut above share");
            require(
                p.minAmountsOut[i] >= (share * (CUTOVER_MAX_BPS - p.exitToleranceBps)) / CUTOVER_MAX_BPS,
                "UniPoolerCutoverCore: minAmountOut below tolerance"
            );
        }
    }

    function _totalSupply(address token) private view returns (uint256 s) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok && data.length >= 32, "UniPoolerCutoverCore: totalSupply");
        s = abi.decode(data, (uint256));
    }

    /// @notice Step 6. Seed the empty pair with ALL the recovered tokens in one Router02 call.
    function _step6SeedPair(CutoverParams memory p, CutoverLive memory l, uint256 sAmt, uint256 pAmt)
        internal
        returns (uint256 liquidity)
    {
        uint256 sMin = (sAmt * (CUTOVER_MAX_BPS - p.seedToleranceBps)) / CUTOVER_MAX_BPS;
        uint256 pMin = (pAmt * (CUTOVER_MAX_BPS - p.seedToleranceBps)) / CUTOVER_MAX_BPS;
        require(sMin > 0 && pMin > 0, "UniPoolerCutoverCore: zero seed minimum");

        ICutoverERC20(l.sUSDS).approve(p.uniV2Router, sAmt);
        ICutoverERC20(l.phUSD).approve(p.uniV2Router, pAmt);
        uint256 a;
        uint256 b;
        (a, b, liquidity) = ICutoverUniV2Router(p.uniV2Router)
            .addLiquidity(l.sUSDS, l.phUSD, sAmt, pAmt, sMin, pMin, l.newPooler, block.timestamp);
        // Into an empty pair the router uses the desired amounts exactly: nothing is left behind.
        require(a == sAmt && b == pAmt, "UniPoolerCutoverCore: seed not exact");
        require(liquidity > 0, "UniPoolerCutoverCore: no LP minted");
        require(ICutoverUniV2Pair(l.pair).balanceOf(l.newPooler) == liquidity, "UniPoolerCutoverCore: LP not on pooler");

        (uint112 r0, uint112 r1,) = ICutoverUniV2Pair(l.pair).getReserves();
        bool s0 = ICutoverUniV2Pair(l.pair).token0() == l.sUSDS;
        require((s0 ? r0 : r1) == sAmt && (s0 ? r1 : r0) == pAmt, "UniPoolerCutoverCore: reserves != seeded amounts");
    }

    /// @notice Step 7. Settle every interim mint's debt, before the hook is repointed.
    function _step7PullDebt(CutoverParams memory p) internal {
        ICutoverMintDebtHook(p.mintDebtHook).pull();
        require(ICutoverMintDebtHook(p.mintDebtHook).mintDebt() == 0, "UniPoolerCutoverCore: mintDebt not zero");
    }

    /// @notice Step 8. hook -> new pooler, THEN new pooler -> hook.
    function _step8RepointHook(CutoverParams memory p, CutoverLive memory l) internal {
        ICutoverMintDebtHook(p.mintDebtHook).setDispatcher(l.newPooler);
        UniPoolerV2(l.newPooler).setHook(IDispatchHook(p.mintDebtHook));
        require(
            ICutoverMintDebtHook(p.mintDebtHook).dispatcher() == l.newPooler
                && address(UniPoolerV2(l.newPooler).hook()) == p.mintDebtHook,
            "UniPoolerCutoverCore: hook not repointed"
        );
    }

    /// @notice Step 9. Wire the minter, copy config live from the old pooler, authorize poolers.
    ///         No Pauser registration.
    function _step9ConfigurePooler(CutoverParams memory p, CutoverLive memory l) internal {
        ICutoverBalancerPooler old = ICutoverBalancerPooler(p.oldPooler);
        UniPoolerV2 np = UniPoolerV2(l.newPooler);

        np.setMinter(p.nftMinter);

        address psm_ = old.psm();
        if (psm_ != address(0)) np.setPSM(psm_);
        np.setMaxTout(old.maxTout());
        np.setBatchMinter(old.batchMinter());
        np.setBatchDonationSize(old.batchDonationSize());
        for (uint256 i = 0; i < p.poolers.length; i++) {
            np.setAuthorizedPooler(p.poolers[i], true);
        }
        // Wired last, as its NatSpec asks.
        address streamer = old.nudgeStreamer();
        if (streamer != address(0)) np.setNudgeStreamer(streamer);

        require(
            np.psm() == psm_ && np.maxTout() == old.maxTout() && np.batchMinter() == old.batchMinter()
                && np.batchDonationSize() == old.batchDonationSize() && np.nudgeStreamer() == streamer,
            "UniPoolerCutoverCore: config not copied"
        );
        uint256 av = np.authVersion();
        for (uint256 i = 0; i < p.poolers.length; i++) {
            require(np.poolerAuthVersion(p.poolers[i]) == av, "UniPoolerCutoverCore: pooler not authorized");
        }
    }

    /// @notice Step 10. Swap the index onto the new pooler; price, growth and disabled unchanged.
    function _step10ReplaceDispatcher(CutoverParams memory p, CutoverLive memory l) internal {
        ICutoverNFTMinter m = ICutoverNFTMinter(p.nftMinter);
        (, uint256 price, uint256 growth, bool disabled) = m.configs(p.dispatcherIndex);
        m.replaceDispatcher(p.dispatcherIndex, l.newPooler);
        (address d2, uint256 price2, uint256 growth2, bool disabled2) = m.configs(p.dispatcherIndex);
        require(d2 == l.newPooler, "UniPoolerCutoverCore: dispatcher not replaced");
        require(
            price2 == price && growth2 == growth && disabled2 == disabled, "UniPoolerCutoverCore: index config changed"
        );
    }

    /// @notice Step 11. Move the old pooler's sUSDS and parked USDS, read live after step 10.
    function _step11MoveBalances(CutoverParams memory p, CutoverLive memory l)
        internal
        returns (uint256 sUSDSRescued, uint256 usdsRescued, bool wrapped, uint256 wrappedShares)
    {
        ICutoverBalancerPooler old = ICutoverBalancerPooler(p.oldPooler);

        sUSDSRescued = ICutoverERC20(l.sUSDS).balanceOf(p.oldPooler);
        if (sUSDSRescued > 0) old.rescueERC20(l.sUSDS, l.newPooler, sUSDSRescued);

        usdsRescued = ICutoverERC20(l.usds).balanceOf(p.oldPooler);
        if (usdsRescued > 0) {
            UniPoolerV2 np = UniPoolerV2(l.newPooler);
            bool donationLive = np.batchDonationSize() > 0 && np.batchMinter() != address(0) && np.psm() != address(0);
            if (donationLive) {
                // The next index-4 dispatch sweeps and retries it.
                old.rescueERC20(l.usds, l.newPooler, usdsRescued);
            } else {
                // The new pooler would never sweep it: wrap it into sUSDS for the new pooler.
                uint256 ownerBefore = ICutoverERC20(l.usds).balanceOf(p.owner);
                old.rescueERC20(l.usds, p.owner, usdsRescued);
                require(
                    ICutoverERC20(l.usds).balanceOf(p.owner) - ownerBefore == usdsRescued,
                    "UniPoolerCutoverCore: USDS rescue short"
                );
                ICutoverERC20(l.usds).approve(l.sUSDS, usdsRescued);
                wrappedShares = ICutoverERC4626(l.sUSDS).deposit(usdsRescued, l.newPooler);
                wrapped = true;
            }
        }

        require(
            ICutoverERC20(l.sUSDS).balanceOf(p.oldPooler) == 0 && ICutoverERC20(l.usds).balanceOf(p.oldPooler) == 0,
            "UniPoolerCutoverCore: old pooler not drained"
        );
    }

    /// @notice Step 12. Retire the old pooler: minter -> OWNER, then pause. No Pauser unregister.
    function _step12RetireOld(CutoverParams memory p) internal {
        ICutoverBalancerPooler old = ICutoverBalancerPooler(p.oldPooler);
        old.setMinter(p.owner);
        if (!old.paused()) old.pause();
        require(old.paused(), "UniPoolerCutoverCore: old pooler not paused");
    }

    /// @notice Closing end-state check. The full verify (test mint, quotePool preview) is 103's.
    function _assertRetired(CutoverParams memory p, CutoverLive memory l) internal view {
        (address d,,,) = ICutoverNFTMinter(p.nftMinter).configs(p.dispatcherIndex);
        require(d == l.newPooler, "UniPoolerCutoverCore: index not on new pooler");
        require(ICutoverMintDebtHook(p.mintDebtHook).dispatcher() == l.newPooler, "UniPoolerCutoverCore: hook");
        require(
            ICutoverERC20(l.bPool).balanceOf(p.oldPooler) == 0 && ICutoverERC20(l.bPool).balanceOf(p.owner) == 0,
            "UniPoolerCutoverCore: BPT remains"
        );
        require(
            ICutoverERC20(l.sUSDS).balanceOf(p.oldPooler) == 0 && ICutoverERC20(l.usds).balanceOf(p.oldPooler) == 0,
            "UniPoolerCutoverCore: old pooler holds funds"
        );
        require(ICutoverBalancerPooler(p.oldPooler).paused(), "UniPoolerCutoverCore: old pooler live");
    }
}
