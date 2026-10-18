// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";
import {UniPoolerCutoverEscrow} from "@yield-claim-nft/migration/UniPoolerCutoverEscrow.sol";

/**
 * @title UniPoolerCutoverCore
 * @notice Story 100, rewired to the escrow flow by story 103 (yield-claim-nft:052). The single
 *         shared implementation of the Balancexit index-4 cutover: `BalancerPoolerV2` (Balancer V3
 *         phUSD/sUSDS pool) -> `UniPoolerV2` (Uniswap V2 phUSD/sUSDS pair). The anvil dress
 *         rehearsal (101), the mainnet cutover script (103) and its fork test (103) all inherit THIS
 *         contract, as `StableStakerCutoverCore` is inherited by both the StableStaker cutover
 *         script and its test, so the three cannot drift.
 *
 * @dev NO PROTOCOL FUNDS THROUGH ANY EOA (yield-claim-nft:052, human requirement for tax and
 *      accounting provability). BPT, sUSDS, phUSD and USDS move contract-to-contract only: old
 *      pooler -> `UniPoolerCutoverEscrow` -> pair / `UniPoolerV2`, or old pooler -> `UniPoolerV2`.
 *      The OWNER EOA only signs. `_runCutover` enforces it: after EVERY step it requires that the
 *      owner's BPT, sUSDS, phUSD and USDS balances have not increased since step 0.
 *
 *      OWNER BPT IS OUT OF SCOPE (amended 2026-10-10, F-02-052). The owner's former 202.30 BPT was
 *      exited and burned at block 25,985,119, so the owner holds none. The core never moves owner
 *      BPT and never reverts on a non-zero owner BPT balance (anyone can donate BPT to the owner, so
 *      such a revert would be a grief vector). The verify script reports any residual.
 *
 *      SEQUENCE (docs/BalancerWinddownPlan.md §4 Stage 2, as corrected by phStaging2:108 for
 *      yield-claim-nft:051's canonical-pair constructor check and by 052's escrow). Each step is an
 *      internal function; `_runCutover` runs them strictly in this order:
 *
 *        0. Preconditions, all `require`d, before any state change: the old pooler's authorized-
 *           pooler set is revoked (each listed pooler fails `onlyAuthorizedPooler`, i.e.
 *           `poolerAuthVersion(p) != authVersion` — story 099's `incrementAuthVersion`); index 4,
 *           the hook and the old pooler point at each other; `minAmountsOut` has one non-zero
 *           entry per pool token; the tolerance is tight. Every address and config value the core
 *           needs beyond the caller's inputs is read live from the old pooler and the hook.
 *        1. Create the canonical sUSDS/phUSD pair through the router's own factory if missing
 *           (reuse it if someone else created it).
 *        2. Require reserves (0,0) and RECORD the pair's token balances. No skim here: neither
 *           `UniPoolerV2` nor the escrow exists yet, and skimming to the owner would route funds
 *           through an EOA. An unsynced donation is skimmed to `UniPoolerV2` inside
 *           `escrow.exitAndSeed`; a synced one (non-zero reserves) reverts (DoS only).
 *        3. Deploy `UniPoolerV2` against that pair (not wired).
 *       3b. Deploy `UniPoolerCutoverEscrow(operator = OWNER, UniPoolerV2, old pooler, V3 Router)`.
 *           After 3, because its constructor reads `UniPoolerV2.pair()`; before 4, which needs it
 *           as the BPT recipient.
 *        4. BPT-address guard, then `BalancerPoolerV2.withdrawBPT(escrow, fullBalance)`. The guard
 *           `require(old.pool() == escrow.bpt())` (yield-claim-nft run 22, L-27) is read LIVE and
 *           sits inside `_fundEscrow`, the ONLY place the core calls `withdrawBPT`, so it guards a
 *           resume into an existing escrow (re-run after `escrow.abort()`) exactly as it guards the
 *           first funding.
 *        5. Check `minAmountsOut` against the live proportional share of the ESCROW's BPT balance
 *           (the old pooler's BPT only), then `escrow.exitAndSeed(mode, minAmountsOut, deadline)`:
 *           the escrow exits its whole BPT balance (proportional or recovery, chosen by the
 *           `exitMode` PARAMETER, never by the clock), skims any unsynced pair donation to
 *           `UniPoolerV2`, and seeds the pair with its whole sUSDS and phUSD, LP to `UniPoolerV2`.
 *           (Replaces the pre-052 steps 5 and 6, which ran through the owner.)
 *        7. `hook.pull()`, then `require(mintDebt() == 0)`.
 *        8. `hook.setDispatcher(UniPoolerV2)`, THEN `UniPoolerV2.setHook(hook)`.
 *        9. Configure `UniPoolerV2`: `setMinter(NFTMinterV2)`; copy PSM, maxTout, batchMinter,
 *           batchDonationSize and nudgeStreamer (last) live from the old pooler; authorize the
 *           same poolers. NO Pauser registration (dispatchers have no `pauser()`).
 *       10. `NFTMinterV2.replaceDispatcher(4, UniPoolerV2)`, asserting price/growth/disabled for
 *           the index are unchanged.
 *       11. Move the old pooler's balances, read live after step 10: all sUSDS
 *           `rescueERC20(sUSDS, UniPoolerV2)`; parked USDS `rescueERC20(USDS, escrow)` then
 *           `escrow.wrapUsds()` (sUSDS shares credited to `UniPoolerV2`); the old pooler is checked
 *           empty, and the escrow by before/after deltas only.
 *       12. Retire the old pooler: `old.setMinter(OWNER)` then `old.pause()`. NO Pauser unregister.
 *      A closing `_assertRetired` re-checks the end state (old pooler drained and paused, index 4
 *      and the hook on the new pooler). The full verify is 103's.
 *
 *      DONATIONS TO THE ESCROW never revert the cutover (story 103 revision 2, F-02-052's rule).
 *      The escrow is a CREATE from OWNER's public nonce, so its address is predictable and anyone
 *      can pre-fund it. Every escrow check is therefore a delta, the step-5 floors are sized on the
 *      BPT step 4 moved (not on the escrow's balance), and no step requires the escrow to end empty.
 *      Residual escrow balances are reported as warnings by the verifier.
 *
 *      OPERATIONAL RULE (L-27): never call `BalancerPoolerV2.setPool` on the old pooler while a
 *      `UniPoolerCutoverEscrow` pointing at it is live. The escrow snapshots the BPT address at
 *      construction and `abort()` only returns the snapshot tokens, so a repointed `withdrawBPT`
 *      would strand the other token in the escrow forever. The step-4 guard refuses that.
 *
 *      EXECUTION CONTEXT is the caller's, as in `StableStakerCutoverCore`: every external call is
 *      made from the inheriting contract at its own call depth, so a script wraps `_runCutover` in
 *      `vm.startBroadcast(OWNER)` and a test makes the test contract the OWNER. `p.owner` must be
 *      that sender; step 0 checks it owns the old pooler, the hook and the NFT minter. The escrow's
 *      operator is `p.owner`, so the same sender calls `exitAndSeed` and `wrapUsds`.
 *
 *      BALANCER INTERFACES are declared here on purpose (not imported from yield-claim-nft), so
 *      yield-claim-nft can delete its Balancer interfaces (story 050) without breaking this core.
 *      The escrow approves the V3 Router for exactly the BPT it exits (mainnet reverts
 *      `ERC20InsufficientAllowance(router, ...)` without it) and resets it.
 */

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
}

interface ICutoverERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice The `UniPoolerCutoverEscrow` surface the core drives (yield-claim-nft:052). Declared
///         locally; `bpt()` is the BPT the escrow snapshotted from `oldPooler.pool()` at deploy
///         (`UniPoolerCutoverEscrow.sol:326`), the operand of the L-27 BPT-address guard.
interface ICutoverEscrow {
    function operator() external view returns (address);
    function newPooler() external view returns (address);
    function oldPooler() external view returns (address);
    function v3Router() external view returns (address);
    function bpt() external view returns (address);
    function usds() external view returns (address);
    function sUSDS() external view returns (address);
    function phUSD() external view returns (address);
    function pair() external view returns (address);
    function uniRouter() external view returns (address);
    function exitAndSeed(uint8 mode, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        returns (uint256 liquidity);
    function wrapUsds() external returns (uint256 shares);
}

abstract contract UniPoolerCutoverCore {
    uint256 internal constant CUTOVER_MAX_BPS = 10_000;
    /// @notice Ceiling on the exit tolerance: "tight" means at most 1%.
    uint256 internal constant CUTOVER_MAX_TOLERANCE_BPS = 100;
    /// @notice Ceiling on how far ahead the seed deadline may sit. Long enough for a Ledger-signed
    ///         `--slow` broadcast, short enough that a signed-but-stuck seed cannot land days later.
    ///         Equal to the escrow's own `MAX_DEADLINE_WINDOW`.
    uint256 internal constant CUTOVER_MAX_SEED_DEADLINE_WINDOW = 1 days;

    /// @notice Step ids passed to `_afterCutoverStep` (and in the owner-invariant revert message).
    uint256 internal constant CUTOVER_STEP_PRECONDITIONS = 0;
    uint256 internal constant CUTOVER_STEP_CREATE_PAIR = 1;
    uint256 internal constant CUTOVER_STEP_PAIR_EMPTY = 2;
    uint256 internal constant CUTOVER_STEP_DEPLOY_POOLER = 3;
    uint256 internal constant CUTOVER_STEP_DEPLOY_ESCROW = 31; // "3b"
    uint256 internal constant CUTOVER_STEP_FUND_ESCROW = 4;
    uint256 internal constant CUTOVER_STEP_EXIT_AND_SEED = 5;
    uint256 internal constant CUTOVER_STEP_PULL_DEBT = 7;
    uint256 internal constant CUTOVER_STEP_REPOINT_HOOK = 8;
    uint256 internal constant CUTOVER_STEP_CONFIGURE = 9;
    uint256 internal constant CUTOVER_STEP_REPLACE_DISPATCHER = 10;
    uint256 internal constant CUTOVER_STEP_MOVE_BALANCES = 11;
    uint256 internal constant CUTOVER_STEP_RETIRE_OLD = 12;

    string internal constant CUTOVER_BPT_GUARD_MESSAGE =
        "UniPoolerCutoverCore: old pooler pool() != escrow.bpt() - setPool repointed the old pooler; withdrawBPT would strand the token in the escrow (L-27)";

    /// @notice Which Balancer V3 exit the escrow uses. A parameter, never derived from the clock:
    ///         PROPORTIONAL while the pool is live (before 30 Oct), RECOVERY once it is paused and in
    ///         Recovery Mode. Same ordinals as `UniPoolerCutoverEscrow.ExitMode`.
    enum ExitMode {
        PROPORTIONAL,
        RECOVERY
    }

    /// @notice Caller inputs. Everything else is read live (see `CutoverLive`).
    struct CutoverParams {
        address owner; // the sender of every call; owns old pooler, hook and NFT minter; escrow operator
        address oldPooler; // BalancerPoolerV2 at the index
        address mintDebtHook; // BalancerPoolerMintDebtHook
        address nftMinter; // NFTMinterV2
        uint256 dispatcherIndex; // 4
        address uniV2Router; // Router02; its factory() creates/locates the pair
        address balancerRouter; // Balancer V3 Router (not exposed by BalancerPoolerV2); the escrow's v3Router
        address[] poolers; // the poolers to re-authorize on UniPoolerV2 (must be revoked on old)
        ExitMode exitMode;
        uint256[] minAmountsOut; // Balancer pool-token order; every entry > 0
        uint256 exitToleranceBps; // max gap of minAmountsOut below the live proportional share
        // Router02 addLiquidity deadline (absolute unix time), forwarded to `escrow.exitAndSeed`.
        // Must be forward-dated by the caller: under `forge script --broadcast` the value is fixed
        // into the calldata at simulation time, so a raw `block.timestamp` would revert once the
        // seed is mined in any later block. Callers use e.g. `block.timestamp + 1 hours`.
        uint256 seedDeadline;
    }

    /// @notice Addresses read live in step 0, plus those the cutover creates.
    struct CutoverLive {
        address sUSDS;
        address usds;
        address phUSD;
        address bPool;
        address bVault;
        address factory;
        address pair;
        address newPooler;
        address escrow;
    }

    struct CutoverResult {
        address newPooler;
        address pair;
        address escrow;
        uint256 pairDonationSUSDS; // unsynced sUSDS on the empty pair at step 2 (skimmed to newPooler by the escrow)
        uint256 pairDonationPhUSD; // unsynced phUSD on the empty pair at step 2
        uint256 ownerBptAtStart; // reported only: owner BPT is out of scope (F-02-052)
        uint256 bptWithdrawn; // old pooler -> escrow in step 4
        uint256 bptExited; // the escrow's whole BPT balance, exited in step 5
        uint256 sUSDSSeeded; // pair sUSDS reserve after the seed (== the escrow's whole sUSDS)
        uint256 phUSDSeeded; // pair phUSD reserve after the seed (== the escrow's whole phUSD)
        uint256 liquidity; // LP minted to newPooler by the seed
        uint256 sUSDSRescued; // old pooler -> newPooler in step 11
        uint256 usdsRescued; // old pooler -> escrow in step 11, then wrapped
        uint256 usdsWrappedShares; // sUSDS shares the escrow's wrapUsds credited to newPooler
    }

    /// @dev The owner's balance of each moved token, taken after step 0 (see `_requireOwnerNotCredited`).
    struct OwnerBalances {
        uint256 bpt;
        uint256 sUSDS;
        uint256 phUSD;
        uint256 usds;
    }

    // ---------------------------------------------------------------------------- orchestrator

    /// @notice Runs steps 0 -> 12 in order and returns what moved. Reverts loudly on any breach,
    ///         including any step after which the owner EOA holds more of a moved token than it
    ///         did at step 0.
    function _runCutover(CutoverParams memory p) internal returns (CutoverResult memory r) {
        CutoverLive memory l = _step0Preconditions(p);
        OwnerBalances memory o = _ownerBalances(p, l);
        r.ownerBptAtStart = o.bpt;
        _afterStep(CUTOVER_STEP_PRECONDITIONS, p, l, o);

        l.pair = _step1CreatePair(l);
        r.pair = l.pair;
        _afterStep(CUTOVER_STEP_CREATE_PAIR, p, l, o);

        (r.pairDonationSUSDS, r.pairDonationPhUSD) = _step2EnsurePairEmpty(l);
        _afterStep(CUTOVER_STEP_PAIR_EMPTY, p, l, o);

        l.newPooler = _step3DeployPooler(p, l);
        r.newPooler = l.newPooler;
        _afterStep(CUTOVER_STEP_DEPLOY_POOLER, p, l, o);

        l.escrow = _step3bDeployEscrow(p, l);
        r.escrow = l.escrow;
        _afterStep(CUTOVER_STEP_DEPLOY_ESCROW, p, l, o);

        r.bptWithdrawn = _step4FundEscrow(p, l);
        _afterStep(CUTOVER_STEP_FUND_ESCROW, p, l, o);

        (r.bptExited, r.sUSDSSeeded, r.phUSDSeeded, r.liquidity) = _step5ExitAndSeed(p, l, r.bptWithdrawn);
        _afterStep(CUTOVER_STEP_EXIT_AND_SEED, p, l, o);

        _step7PullDebt(p);
        _afterStep(CUTOVER_STEP_PULL_DEBT, p, l, o);

        _step8RepointHook(p, l);
        _afterStep(CUTOVER_STEP_REPOINT_HOOK, p, l, o);

        _step9ConfigurePooler(p, l);
        _afterStep(CUTOVER_STEP_CONFIGURE, p, l, o);

        _step10ReplaceDispatcher(p, l);
        _afterStep(CUTOVER_STEP_REPLACE_DISPATCHER, p, l, o);

        (r.sUSDSRescued, r.usdsRescued, r.usdsWrappedShares) = _step11MoveBalances(p, l);
        _afterStep(CUTOVER_STEP_MOVE_BALANCES, p, l, o);

        _step12RetireOld(p);
        _afterStep(CUTOVER_STEP_RETIRE_OLD, p, l, o);

        _assertRetired(p, l);
    }

    /// @notice Observation hook, called after every step with the live addresses so far. Empty in
    ///         production; tests and the anvil rehearsal override it to record per-step state.
    function _afterCutoverStep(uint256 step, CutoverParams memory p, CutoverLive memory l) internal virtual {}

    function _afterStep(uint256 step, CutoverParams memory p, CutoverLive memory l, OwnerBalances memory o) private {
        _requireOwnerNotCredited(step, p, l, o);
        _afterCutoverStep(step, p, l);
    }

    function _ownerBalances(CutoverParams memory p, CutoverLive memory l)
        internal
        view
        returns (OwnerBalances memory o)
    {
        o.bpt = ICutoverERC20(l.bPool).balanceOf(p.owner);
        o.sUSDS = ICutoverERC20(l.sUSDS).balanceOf(p.owner);
        o.phUSD = ICutoverERC20(l.phUSD).balanceOf(p.owner);
        o.usds = ICutoverERC20(l.usds).balanceOf(p.owner);
    }

    /// @notice yield-claim-nft:052 invariant: no protocol funds transit the owner EOA. Its BPT,
    ///         sUSDS, phUSD and USDS balances never rise above their step-0 values. A decrease is
    ///         not a breach (the core never spends owner funds either, so none is expected).
    function _requireOwnerNotCredited(
        uint256 step,
        CutoverParams memory p,
        CutoverLive memory l,
        OwnerBalances memory o
    ) internal view {
        OwnerBalances memory n = _ownerBalances(p, l);
        if (n.bpt > o.bpt || n.sUSDS > o.sUSDS || n.phUSD > o.phUSD || n.usds > o.usds) {
            revert(
                string.concat("UniPoolerCutoverCore: owner EOA credited with protocol funds at step ", _stepName(step))
            );
        }
    }

    function _stepName(uint256 step) internal pure returns (string memory) {
        if (step == CUTOVER_STEP_DEPLOY_ESCROW) return "3b";
        bytes memory b = new bytes(step >= 10 ? 2 : 1);
        if (step >= 10) {
            b[0] = bytes1(uint8(48 + step / 10));
            b[1] = bytes1(uint8(48 + (step % 10)));
        } else {
            b[0] = bytes1(uint8(48 + step));
        }
        return string(b);
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
        require(p.balancerRouter != address(0), "UniPoolerCutoverCore: zero balancer router");

        require(p.exitToleranceBps <= CUTOVER_MAX_TOLERANCE_BPS, "UniPoolerCutoverCore: tolerance too wide");

        // The seed deadline is strictly in the future (never the raw simulation timestamp, which
        // expires as soon as the broadcast seed lands in a later block) and not unboundedly so.
        require(p.seedDeadline > block.timestamp, "UniPoolerCutoverCore: seed deadline not in future");
        require(
            p.seedDeadline <= block.timestamp + CUTOVER_MAX_SEED_DEADLINE_WINDOW,
            "UniPoolerCutoverCore: seed deadline too far"
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

    /// @notice Step 2. Require reserves (0,0) and record the pair's token balances. No skim: the
    ///         escrow skims an unsynced donation to `UniPoolerV2` inside `exitAndSeed`.
    function _step2EnsurePairEmpty(CutoverLive memory l) internal view returns (uint256 donS, uint256 donP) {
        (uint112 r0, uint112 r1,) = ICutoverUniV2Pair(l.pair).getReserves();
        require(r0 == 0 && r1 == 0, "UniPoolerCutoverCore: pair reserves not empty");
        donS = ICutoverERC20(l.sUSDS).balanceOf(l.pair);
        donP = ICutoverERC20(l.phUSD).balanceOf(l.pair);
    }

    /// @notice Step 3. Deploy UniPoolerV2 against the (now existing, reserve-less) canonical pair.
    function _step3DeployPooler(CutoverParams memory p, CutoverLive memory l) internal returns (address) {
        UniPoolerV2 np = new UniPoolerV2(l.sUSDS, l.phUSD, p.uniV2Router, l.pair, p.owner);
        require(np.pair() == l.pair && np.owner() == p.owner, "UniPoolerCutoverCore: deploy mismatch");
        return address(np);
    }

    /// @notice Step 3b. Deploy the escrow (operator = OWNER) and check every immutable it read.
    function _step3bDeployEscrow(CutoverParams memory p, CutoverLive memory l) internal returns (address e) {
        e = address(new UniPoolerCutoverEscrow(p.owner, l.newPooler, p.oldPooler, p.balancerRouter));
        ICutoverEscrow x = ICutoverEscrow(e);
        require(
            x.operator() == p.owner && x.newPooler() == l.newPooler && x.oldPooler() == p.oldPooler
                && x.v3Router() == p.balancerRouter,
            "UniPoolerCutoverCore: escrow wiring mismatch"
        );
        require(
            x.bpt() == l.bPool && x.usds() == l.usds && x.sUSDS() == l.sUSDS && x.phUSD() == l.phUSD
                && x.pair() == l.pair && x.uniRouter() == p.uniV2Router,
            "UniPoolerCutoverCore: escrow token mismatch"
        );
    }

    /// @notice Step 4. The old pooler's whole BPT balance to the escrow, behind the L-27 guard.
    function _step4FundEscrow(CutoverParams memory p, CutoverLive memory l) internal returns (uint256 bal) {
        bal = _fundEscrow(p.oldPooler, l.escrow);
        require(bal > 0, "UniPoolerCutoverCore: old pooler holds no BPT");
    }

    /// @notice The ONLY `withdrawBPT` call site. Reads `old.pool()` live (never cached across steps)
    ///         and requires it to equal the escrow's snapshotted `bpt()` BEFORE moving anything, so a
    ///         `setPool` repoint can never send a token the escrow cannot return. Use it for a resume
    ///         into an existing escrow too (after `escrow.abort()`, or from broadcast receipts).
    /// @return bal The BPT moved (the old pooler's whole balance; 0 if it held none).
    function _fundEscrow(address oldPooler, address escrow) internal returns (uint256 bal) {
        address livePool = ICutoverBalancerPooler(oldPooler).pool();
        require(livePool == ICutoverEscrow(escrow).bpt(), CUTOVER_BPT_GUARD_MESSAGE);
        bal = ICutoverERC20(livePool).balanceOf(oldPooler);
        if (bal > 0) {
            uint256 escrowBefore = ICutoverERC20(livePool).balanceOf(escrow);
            ICutoverBalancerPooler(oldPooler).withdrawBPT(escrow, bal);
            require(
                ICutoverERC20(livePool).balanceOf(escrow) - escrowBefore == bal,
                "UniPoolerCutoverCore: escrow did not receive the BPT"
            );
        }
        require(ICutoverERC20(livePool).balanceOf(oldPooler) == 0, "UniPoolerCutoverCore: BPT left on old pooler");
    }

    /// @notice Step 5. Check the floors against the live proportional share of the BPT step 4 moved
    ///         (the old pooler's BPT only), then `escrow.exitAndSeed`, which exits the escrow's whole
    ///         BPT balance. Returns the BPT exited, the seeded reserves and the LP minted.
    /// @dev    DONATION-PROOF (story 103 revision 2). The escrow is a CREATE from OWNER's public nonce,
    ///         so its address is predictable and anyone can pre-fund it. The floors are therefore sized
    ///         on `bptWithdrawn`, never on `balanceOf(escrow)`: a BPT donation only adds to what is
    ///         exited (share(bptIn) >= share(bptWithdrawn) >= floors), so it can neither push the
    ///         floors out of tolerance nor revert the run. sUSDS/phUSD donations are swept into the
    ///         seed by `exitAndSeed` itself (it seeds with its whole balances).
    function _step5ExitAndSeed(CutoverParams memory p, CutoverLive memory l, uint256 bptWithdrawn)
        internal
        returns (uint256 bptIn, uint256 sSeeded, uint256 pSeeded, uint256 liquidity)
    {
        bptIn = ICutoverERC20(l.bPool).balanceOf(l.escrow);
        require(bptWithdrawn > 0 && bptIn >= bptWithdrawn, "UniPoolerCutoverCore: escrow holds no BPT");
        _checkMinAmountsOut(p, l, bptWithdrawn);

        uint256 lpBefore = ICutoverUniV2Pair(l.pair).balanceOf(l.newPooler);
        liquidity = ICutoverEscrow(l.escrow).exitAndSeed(uint8(p.exitMode), p.minAmountsOut, p.seedDeadline);
        require(liquidity > 0, "UniPoolerCutoverCore: no LP minted");
        require(
            ICutoverUniV2Pair(l.pair).balanceOf(l.newPooler) - lpBefore == liquidity,
            "UniPoolerCutoverCore: LP not on pooler"
        );

        (uint112 r0, uint112 r1,) = ICutoverUniV2Pair(l.pair).getReserves();
        bool s0 = ICutoverUniV2Pair(l.pair).token0() == l.sUSDS;
        sSeeded = s0 ? r0 : r1;
        pSeeded = s0 ? r1 : r0;
        require(sSeeded > 0 && pSeeded > 0, "UniPoolerCutoverCore: empty seed");
        // The exit honoured the floors: everything the escrow received went into the pair.
        (uint256 minS, uint256 minP) = _minsByToken(p, l);
        require(sSeeded >= minS && pSeeded >= minP, "UniPoolerCutoverCore: seed below exit floors");
        // No escrow-balance re-check here: `exitAndSeed` itself reverts unless it ends holding 0 BPT,
        // 0 sUSDS and 0 phUSD (`_requireNoBalance`), and the delta checks above prove where it went.
    }

    /// @dev `minAmountsOut` re-keyed by token: (sUSDS floor, phUSD floor).
    function _minsByToken(CutoverParams memory p, CutoverLive memory l) internal view returns (uint256, uint256) {
        (address[] memory tokens,,,) = IBalancerV3VaultViews(l.bVault).getPoolTokenInfo(l.bPool);
        return
            tokens[0] == l.sUSDS ? (p.minAmountsOut[0], p.minAmountsOut[1]) : (p.minAmountsOut[1], p.minAmountsOut[0]);
    }

    /// @dev Every `minAmountsOut[i]` must sit in [share_i * (1 - tol), share_i], where
    ///      share_i = balancesRaw_i * bptIn / totalSupply is the live proportional share of the BPT
    ///      step 4 moved into the escrow (the old pooler's BPT only; owner BPT and any third-party
    ///      donation to the escrow are out of scope).
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
    ///         sUSDS goes straight to the new pooler; USDS goes to the escrow, which wraps it into
    ///         sUSDS credited to the new pooler. Contract-to-contract only; the old pooler is
    ///         verified empty.
    /// @dev    DONATION-PROOF (story 103 revision 2): every escrow check is a before/after DELTA, never
    ///         an absolute balance, because the escrow's address is predictable and anyone can pre-fund
    ///         it with USDS. `wrapUsds` wraps the escrow's whole USDS balance, so pre-donated dust is
    ///         simply wrapped along with the rescue and credited to the new pooler. If nothing is
    ///         rescued, no wrap runs and any donated USDS stays on the escrow, reported by verify.
    function _step11MoveBalances(CutoverParams memory p, CutoverLive memory l)
        internal
        returns (uint256 sUSDSRescued, uint256 usdsRescued, uint256 wrappedShares)
    {
        ICutoverBalancerPooler old = ICutoverBalancerPooler(p.oldPooler);

        sUSDSRescued = ICutoverERC20(l.sUSDS).balanceOf(p.oldPooler);
        if (sUSDSRescued > 0) {
            uint256 npBefore = ICutoverERC20(l.sUSDS).balanceOf(l.newPooler);
            old.rescueERC20(l.sUSDS, l.newPooler, sUSDSRescued);
            require(
                ICutoverERC20(l.sUSDS).balanceOf(l.newPooler) - npBefore == sUSDSRescued,
                "UniPoolerCutoverCore: sUSDS rescue short"
            );
        }

        usdsRescued = ICutoverERC20(l.usds).balanceOf(p.oldPooler);
        if (usdsRescued > 0) {
            uint256 escrowUsdsBefore = ICutoverERC20(l.usds).balanceOf(l.escrow);
            old.rescueERC20(l.usds, l.escrow, usdsRescued);
            uint256 escrowUsdsAfterRescue = ICutoverERC20(l.usds).balanceOf(l.escrow);
            require(escrowUsdsAfterRescue - escrowUsdsBefore == usdsRescued, "UniPoolerCutoverCore: USDS rescue short");
            uint256 npBefore = ICutoverERC20(l.sUSDS).balanceOf(l.newPooler);
            wrappedShares = ICutoverEscrow(l.escrow).wrapUsds();
            require(
                wrappedShares > 0 && ICutoverERC20(l.sUSDS).balanceOf(l.newPooler) - npBefore == wrappedShares,
                "UniPoolerCutoverCore: wrapped sUSDS not on new pooler"
            );
            // wrapUsds consumes the escrow's whole USDS balance (it reverts otherwise), so the delta
            // this step moved out is at least the rescue: the parked USDS really was wrapped.
            require(
                escrowUsdsAfterRescue - ICutoverERC20(l.usds).balanceOf(l.escrow) >= usdsRescued,
                "UniPoolerCutoverCore: rescued USDS not wrapped"
            );
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
    ///         Owner BPT is deliberately NOT checked (out of scope; a donation must not brick this).
    ///         Nor is the escrow's balance (story 103 revision 2): its address is predictable, so a
    ///         third party can always leave dust on it. What step 4/5/11 moved through it is proven by
    ///         delta checks; the old pooler being empty is the hard requirement.
    function _assertRetired(CutoverParams memory p, CutoverLive memory l) internal view {
        (address d,,,) = ICutoverNFTMinter(p.nftMinter).configs(p.dispatcherIndex);
        require(d == l.newPooler, "UniPoolerCutoverCore: index not on new pooler");
        require(ICutoverMintDebtHook(p.mintDebtHook).dispatcher() == l.newPooler, "UniPoolerCutoverCore: hook");
        require(ICutoverERC20(l.bPool).balanceOf(p.oldPooler) == 0, "UniPoolerCutoverCore: BPT remains");
        require(
            ICutoverERC20(l.sUSDS).balanceOf(p.oldPooler) == 0 && ICutoverERC20(l.usds).balanceOf(p.oldPooler) == 0,
            "UniPoolerCutoverCore: old pooler holds funds"
        );
        require(ICutoverBalancerPooler(p.oldPooler).paused(), "UniPoolerCutoverCore: old pooler live");
    }
}
