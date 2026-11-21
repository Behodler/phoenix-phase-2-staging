// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

/**
 * @title UniboostMultiPool
 * @notice One owner transaction: `MultiPooler.pool(PoolCall[])` on the live MultiPooler, which forwards one
 *         `Uniboost.pool(amountIn, minPairOut, minTargetOut, minLP)` per protocol-token NFT dispatcher
 *         (UniboostEYE / UniboostSCX / UniboostFLX = NFTMinter indices 1 / 2 / 3). Each Uniboost zaps its retained
 *         USDC: USDC -> WETH (its primeToPairPath), half the WETH -> target token, then addLiquidity on the
 *         target/WETH UniV2 pair. The LP stays on the Uniboost dispatcher (protocol-owned liquidity). Nothing moves
 *         through OWNER: the tax-ledger row is gas only.
 *
 *         WHY THE SCRIPT QUOTES ITSELF (unlike unipooler:pool, which takes floors from scripts/quote-unipooler-pool.js).
 *         Uniboost has no on-chain quotePool, and its LP depends on the post-swap reserves, the UniV2 protocol fee
 *         mint and any transfer fee on the target token, none of which `cast call` can reproduce. All three rows also
 *         sell USDC into the SAME USDC/WETH pair in sequence, so a row's WETH quote depends on the rows before it.
 *         The script therefore runs the whole batch once on the fork (snapshot, prank MultiPooler, row by row, each
 *         row's swap floors quoted with router.getAmountsOut at that row's simulated state), records each row's
 *         quotes and LP, reverts the snapshot, and sets every floor to quote * (10000 - TOLERANCE_BPS) / 10000.
 *         The floors are computed from fork state seconds before the single tx is signed. The swap floors are exactly
 *         what the router checks (amounts[last] of getAmountsOut).
 *
 *         INPUTS (CLAUDE.md "Configuration Safety"):
 *           UNIBOOST_POOL_TOLERANCE_BPS  integer 1..100, default 50. Above 100 (1%) is refused.
 *           UNIBOOST_POOL_EYE_USDC / _SCX_USDC / _FLX_USDC
 *                                        USDC (6dp) to pool per dispatcher, default the whole balance; 0 skips
 *                                        the row. More than the balance is refused.
 *         A row whose any floor rounds to 0 (dust) is SKIPPED, never sent with a zero floor. If every row is
 *         skipped the script reverts: nothing to pool.
 *
 *         CALLER. MultiPooler.pool is onlyPooler; the script require()s MultiPooler.pooler() == OWNER, and per row
 *         that the Uniboost is NFTMinter.configs(i).dispatcher, is owned by OWNER, is not paused, has prime USDC,
 *         and authorizes the MultiPooler (poolerAuthVersion(MultiPooler) == authVersion).
 *         Kill switches: MultiPooler.setPooler(address(0)), or each Uniboost's incrementAuthVersion().
 *
 * Preview:   npm run uniboost:multipool:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed)
 * Broadcast: npm run uniboost:multipool:broadcast   (Ledger m/44'/60'/46'/0/0, then the tax-ledger recorder)
 */

interface IUMPMultiPooler {
    struct PoolCall {
        address uniboost;
        uint256 amountIn;
        uint256 minPairOut;
        uint256 minTargetOut;
        uint256 minLP;
    }

    function owner() external view returns (address);
    function pooler() external view returns (address);
    function pool(PoolCall[] calldata calls) external;
}

interface IUMPUniboost {
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function primeToken() external view returns (address);
    function pairToken() external view returns (address);
    function targetToken() external view returns (address);
    function targetPool() external view returns (address);
    function router() external view returns (address);
    function primeToPairPath() external view returns (address[] memory);
    function authVersion() external view returns (uint256);
    function poolerAuthVersion(address pooler) external view returns (uint256);
    function pool(uint256 amountIn, uint256 minPairOut, uint256 minTargetOut, uint256 minLP) external;
}

interface IUMPRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

interface IUMPNFTMinter {
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

interface IUMPERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract UniboostMultiPool is Script {
    uint256 public constant CHAIN_ID = 1;
    string public constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";

    /// @dev Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0); MultiPooler owner and pooler.
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F; // NFTMinter (V2)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    uint256 public constant DEFAULT_TOLERANCE_BPS = 50;
    /// @dev Loosest floor accepted: 1% below the simulated quote (same cap as unipooler:pool / buy-and-burn).
    uint256 public constant MAX_TOLERANCE_BPS = 100;

    /// @dev Sentinel for "the dispatcher's whole USDC balance" (the env default).
    uint256 internal constant ALL = type(uint256).max;

    struct Row {
        string name;
        IUMPUniboost uniboost;
        address lp; // target/WETH UniV2 pair
        uint256 balance; // USDC on the dispatcher
        uint256 amountIn;
        uint256 pairQuote;
        uint256 targetQuote;
        uint256 lpQuote;
        bool included;
    }

    function run() external {
        console.log("=================================================");
        console.log("  MultiPooler.pool() - MAINNET Uniboost EYE/SCX/FLX");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        bool isPreview = _previewModeFromEnv();
        console.log(isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed)" : "Mode: BROADCAST (Ledger)");

        uint256 tol = _toleranceFromEnv();
        require(tol >= 1 && tol <= MAX_TOLERANCE_BPS, "input: UNIBOOST_POOL_TOLERANCE_BPS must be 1..100");

        string memory book = _addressBook();
        IUMPMultiPooler mp = IUMPMultiPooler(_bookAddress(book, "MultiPooler"));
        require(address(mp) != address(0) && address(mp).code.length > 0, "preflight: MultiPooler missing or no code");
        require(mp.owner() == OWNER, "preflight: MultiPooler owner is not OWNER");
        require(mp.pooler() == OWNER, "preflight: MultiPooler.pooler() is not OWNER");

        (uint256 aEye, uint256 aScx, uint256 aFlx) = _amountsFromEnv();
        Row[] memory rows = new Row[](3);
        rows[0] = _row(book, "EYE", 1, address(mp), aEye);
        rows[1] = _row(book, "SCX", 2, address(mp), aScx);
        rows[2] = _row(book, "FLX", 3, address(mp), aFlx);

        _simulate(rows, address(mp));

        uint256 n;
        for (uint256 i; i < rows.length; i++) {
            Row memory r = rows[i];
            uint256 minPair = _floor(r.pairQuote, tol);
            uint256 minTarget = _floor(r.targetQuote, tol);
            uint256 minLP = _floor(r.lpQuote, tol);
            if (r.amountIn == 0) {
                console.log(string.concat("  ", r.name, ": SKIPPED (amount 0)"));
            } else if (minPair == 0 || minTarget == 0 || minLP == 0) {
                console.log(string.concat("  ", r.name, ": SKIPPED (dust - a floor rounds to 0)"), r.amountIn);
            } else {
                r.included = true;
                n++;
            }
        }
        require(n > 0, "preflight: no Uniboost has poolable USDC - nothing to pool");

        IUMPMultiPooler.PoolCall[] memory calls = new IUMPMultiPooler.PoolCall[](n);
        uint256[] memory lpBefore = new uint256[](n);
        uint256[] memory usdcBefore = new uint256[](n);
        uint256 k;
        for (uint256 i; i < rows.length; i++) {
            Row memory r = rows[i];
            if (!r.included) continue;
            calls[k] = IUMPMultiPooler.PoolCall({
                uniboost: address(r.uniboost),
                amountIn: r.amountIn,
                minPairOut: _floor(r.pairQuote, tol),
                minTargetOut: _floor(r.targetQuote, tol),
                minLP: _floor(r.lpQuote, tol)
            });
            lpBefore[k] = IUMPERC20(r.lp).balanceOf(address(r.uniboost));
            usdcBefore[k] = r.balance;
            console.log(string.concat("  --- ", r.name, " ---"));
            console.log("  Uniboost           :", address(r.uniboost));
            console.log("  target pair (LP)   :", r.lp);
            console.log("  USDC balance       :", r.balance);
            console.log("  amountIn (USDC)    :", r.amountIn);
            console.log("  quote WETH out     :", r.pairQuote);
            console.log("  quote target out   :", r.targetQuote);
            console.log("  sim LP minted      :", r.lpQuote);
            console.log("  minPairOut         :", calls[k].minPairOut);
            console.log("  minTargetOut       :", calls[k].minTargetOut);
            console.log("  minLP              :", calls[k].minLP);
            k++;
        }
        console.log("  tolerance (bps)    :", tol);

        if (isPreview) {
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }
        mp.pool(calls);
        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        for (uint256 j; j < n; j++) {
            IUMPUniboost u = IUMPUniboost(calls[j].uniboost);
            address lp = u.targetPool();
            uint256 lpAfter = IUMPERC20(lp).balanceOf(address(u));
            uint256 usdcAfter = IUMPERC20(USDC).balanceOf(address(u));
            require(lpAfter >= lpBefore[j] + calls[j].minLP, "post: a Uniboost's LP rose by less than its minLP");
            // `>=` not `==`: an NFT mint dispatching USDC into the Uniboost mid-run would raise the balance.
            require(usdcAfter >= usdcBefore[j] - calls[j].amountIn, "post: a Uniboost spent more than amountIn USDC");
            console.log("  LP minted          :", address(u), lpAfter - lpBefore[j]);
        }
        console.log("OK: pooled", n, "Uniboost dispatcher(s) in one MultiPooler tx; LP stays on each dispatcher");
        if (isPreview) {
            console.log("PREVIEW: nothing broadcast. Run uniboost:multipool:broadcast with the Ledger.");
        }
    }

    // ---------------------------------------------------------------------------------------------- building

    function _row(string memory book, string memory name, uint256 index, address mp, uint256 requested)
        internal
        view
        returns (Row memory r)
    {
        string memory key = string.concat("Uniboost", name);
        IUMPUniboost u = IUMPUniboost(_bookAddress(book, key));
        require(address(u) != address(0), string.concat("preflight: mainnet-addresses.ts ", key, " missing or zero"));
        (address d,,,) = IUMPNFTMinter(NFT_MINTER).configs(index);
        require(d == address(u), string.concat("preflight: ", key, " is not the live NFTMinter dispatcher"));
        require(u.owner() == OWNER, string.concat("preflight: ", key, " owner is not OWNER"));
        require(!u.paused(), string.concat("preflight: ", key, " is paused"));
        require(u.primeToken() == USDC, string.concat("preflight: ", key, " prime is not USDC"));
        require(u.pairToken() == WETH, string.concat("preflight: ", key, " pair token is not WETH"));
        require(u.router() == UNIV2_ROUTER, string.concat("preflight: ", key, " router is not UniV2 Router02"));
        require(
            u.poolerAuthVersion(mp) == u.authVersion(),
            string.concat("preflight: ", key, " does not authorize MultiPooler")
        );

        r.name = name;
        r.uniboost = u;
        r.lp = u.targetPool();
        r.balance = IUMPERC20(USDC).balanceOf(address(u));
        if (requested == ALL) {
            r.amountIn = r.balance;
        } else {
            require(requested <= r.balance, string.concat("input: UNIBOOST_POOL_", name, "_USDC exceeds the balance"));
            r.amountIn = requested;
        }
    }

    /// @dev Runs the batch row by row on the fork exactly as MultiPooler would (pranking it as the caller), quoting
    ///      each row's swap legs at that row's simulated state with the router's own math and measuring its LP, then
    ///      reverts every state change. The swap floors passed here are the exact quotes, so the simulation also
    ///      proves they are reachable.
    function _simulate(Row[] memory rows, address mp) internal {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < rows.length; i++) {
            Row memory r = rows[i];
            if (r.amountIn == 0) continue;
            IUMPUniboost u = r.uniboost;
            address[] memory p1 = u.primeToPairPath();
            uint256[] memory o1 = IUMPRouter(UNIV2_ROUTER).getAmountsOut(r.amountIn, p1);
            r.pairQuote = o1[o1.length - 1];
            uint256 half = (IUMPERC20(WETH).balanceOf(address(u)) + r.pairQuote) / 2;
            if (half > 0) {
                address[] memory p2 = new address[](2);
                p2[0] = WETH;
                p2[1] = u.targetToken();
                uint256[] memory o2 = IUMPRouter(UNIV2_ROUTER).getAmountsOut(half, p2);
                r.targetQuote = o2[1];
            }
            if (r.pairQuote == 0 || r.targetQuote == 0) continue; // dust: skipped by the caller
            uint256 lpBefore = IUMPERC20(r.lp).balanceOf(address(u));
            vm.prank(mp);
            u.pool(r.amountIn, r.pairQuote, r.targetQuote, 0);
            r.lpQuote = IUMPERC20(r.lp).balanceOf(address(u)) - lpBefore;
        }
        require(vm.revertToState(snap), "simulate: snapshot revert failed");
    }

    function _floor(uint256 quote, uint256 tol) internal pure returns (uint256) {
        return (quote * (10000 - tol)) / 10000;
    }

    /// @dev The address literal of `key` in mainnet-addresses.ts, or address(0) when absent. Same reader as
    ///      UniPoolerPool.s.sol (uncommented top-level `\n  <key>: "0x..."` entries only).
    function _bookAddress(string memory book, string memory key) internal pure returns (address) {
        string memory needle = string.concat("\n  ", key, ": \"");
        uint256 at = vm.indexOf(book, needle);
        if (at == type(uint256).max) return address(0);
        bytes memory src = bytes(book);
        uint256 start = at + bytes(needle).length;
        require(src.length >= start + 42, string.concat("address book: truncated entry for ", key));
        bytes memory lit = new bytes(42);
        for (uint256 i; i < 42; i++) {
            lit[i] = src[start + i];
        }
        return vm.parseAddress(string(lit));
    }

    // ------------------------------------------------------------------------------------- I/O seams (virtual)

    function _addressBook() internal view virtual returns (string memory) {
        return vm.readFile(ADDRESS_BOOK);
    }

    function _toleranceFromEnv() internal view virtual returns (uint256) {
        return vm.envOr("UNIBOOST_POOL_TOLERANCE_BPS", DEFAULT_TOLERANCE_BPS);
    }

    function _amountsFromEnv() internal view virtual returns (uint256 eye, uint256 scx, uint256 flx) {
        eye = vm.envOr("UNIBOOST_POOL_EYE_USDC", ALL);
        scx = vm.envOr("UNIBOOST_POOL_SCX_USDC", ALL);
        flx = vm.envOr("UNIBOOST_POOL_FLX_USDC", ALL);
    }

    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
