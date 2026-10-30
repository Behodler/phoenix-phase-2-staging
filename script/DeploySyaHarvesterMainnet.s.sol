// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Script.sol";
import "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {ICurveRouterNG} from "sya-harvester/interfaces/ICurveRouterNG.sol";

/// @notice The StableStakerV2 surface Script A touches (lib/stable-staker/src/StableStakerV2.sol:266, onlyOwner).
interface IStableStakerV2ClaimGate {
    function claimEnabled() external view returns (bool);
    function setClaimEnabled(bool enabled) external;
    function owner() external view returns (address);
}

/// @notice Curve pool coin views used by the route preflight.
interface ISyaHarvesterCurvePool {
    function coins(uint256 i) external view returns (address);
}

/// @notice NFTMinterV2 views/calls the harvest smoke needs.
interface ISyaHarvesterNftMinter {
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
    function mint(uint256 index, address recipient) external returns (bool);
}

interface ISyaHarvesterDispatcher {
    function primeToken() external view returns (address);
}

/**
 * @title DeploySyaHarvesterMainnet  (story 122, Script A, sprint sya-antimatter-cutover)
 * @notice Brings mainnet level with DeployMocks Phases 11.12 + 11.13:
 *           1. deploy `SYAHarvester(OWNER, PoolManager, SYA, Curve Router NG)` (lib/sya-harvester pin 6b862aa);
 *           2. `setRoute(USDe)`  USDe -> crvUSD -> USDC (2 hops);
 *           3. `setRoute(DOLA)`  DOLA -> USDC through the DOLA/FRAXBP metapool (exchange_underlying, 1 hop);
 *           4. `setEthPool`      native ETH / USDC, fee 3000, tickSpacing 60, no hooks;
 *           5. read-back of every stored route and the pool key;
 *           6. `StableStakerV2.setClaimEnabled(true)`, asserted.
 *         USDC gets NO route: it is SYA's reward token, which the harvester never sells.
 *
 *         ROUTE SAFETY (the human's standing warning; repo CLAUDE.md "OPEN BUG - audit ryv18m5"; story-052 rules).
 *         Before ANY `vm.startBroadcast()` - in preview and broadcast alike, so a broadcast cannot skip them - the
 *         script:
 *           a. checks each exact broadcast payload off-chain with `checkRoutePayload` (pure; reverts on any
 *              story-052 violation, plus swap_type 9 which Router NG v1.1 rejects);
 *           b. dry-runs each route on the fork in BOTH directions through Router NG `exchange`, inside a
 *              `vm.snapshotState()` / `vm.revertToState()` bracket, asserting on BALANCE DELTAS (USDC in on the
 *              way out, tokenIn back on the reverse route) and that no intermediate token is left on the
 *              receiver - never on the router's return value.
 *         After the harvester is configured, a harvest smoke (buy one claim NFT, `harvest`, assert ETH in, NFT
 *         burned, harvester empty) runs in its own snapshot bracket before the claim-enable step. Everything a
 *         snapshot bracket does (deal, prank, swaps) is reverted and never recorded as a transaction.
 *
 *         RESUMABLE. Each step has a `done` gate read from chain state: a recorded harvester with code is adopted
 *         (immutables re-checked), a stored route equal to the payload is not re-sent, a matching pool key is not
 *         re-sent, `claimEnabled == true` is not re-sent. A progress address with NO code aborts.
 *
 * Preview:   npm run sya-harvester:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written)
 * Broadcast: npm run sya-harvester:broadcast   (backup -> Ledger m/44'/60'/46'/0/0 -> patcher -> :verify -> ledger)
 * Verify:    npm run sya-harvester:verify      (read-only, script/VerifySyaHarvester.s.sol)
 * Runbook:   docs/SyaAntimatterMainnetCutover.md
 */
abstract contract SyaHarvesterMainnetBase is Script, StdCheats {
    uint256 public constant CHAIN_ID = 1;
    string public constant NETWORK_NAME = "mainnet";

    /// @dev Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0): the harvester owner and the StableStakerV2 owner.
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    string public constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";
    string public constant PROGRESS_FILE = "server/deployments/progress.sya-harvester.1.json";

    // ---- Constants with no address-book key. Copied (not imported: they live under test/, which the
    //      remapping does not reach) from lib/sya-harvester/test/fork/MainnetAddresses.sol + MainnetRoutes.sol,
    //      where they were discovered and fork-verified (pinned block 26_261_000). Re-checked by `_preflight`. ----
    address public constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    /// @dev coin0 = USDe, coin1 = crvUSD (stableswap-ng)
    address public constant POOL_USDE_CRVUSD = 0xF55B0f6F2Da5ffDDb104b58a60F2862745960442;
    /// @dev coin0 = USDC, coin1 = crvUSD (factory plain pool)
    address public constant POOL_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;
    /// @dev coin0 = DOLA, coin1 = FRAXBP LP; underlying 0 = DOLA, 1 = FRAX, 2 = USDC
    address public constant POOL_DOLA_FRAXBP = 0xE57180685E3348589E9521aa53Af0BCD497E884d;
    /// @dev FRAXBP base pool: coin0 = FRAX, coin1 = USDC (so metapool underlying index 2 = USDC)
    address public constant POOL_FRAXBP = 0xDcEF968d416a41Cdac0ED8702fAC8128A64241A2;

    uint24 public constant ETH_POOL_FEE = 3000;
    int24 public constant ETH_POOL_TICK_SPACING = 60;

    /// @dev Router NG v1.1 dispatches swap_type 1..8; 0 reverts "Bad swap type" and 9 (ERC4626) is rejected.
    uint256 public constant MAX_SWAP_TYPE = 8;
    uint256 public constant SWAP_TYPE_ERC4626 = 9;

    /// @dev Dry-run size per direction (whole tokens) and the floor on what must come out, in bps of par.
    ///      All three tokens are dollar stables; 97% of par is far below the ~99.6% the routes quote and far
    ///      above anything a wrong-token delivery (e.g. a gapped route stopping at crvUSD) could produce in USDC.
    uint256 public constant DRY_RUN_UNITS = 1_000;
    uint256 public constant DRY_RUN_MIN_BPS = 9_700;

    /// @dev Claim NFT index the harvest smoke buys (UniPoolerV2, as in DeployMocks 11.12). Verified on chain:
    ///      registered and not disabled (`_harvestSmoke` requires both).
    uint256 public constant SMOKE_NFT_INDEX = 4;

    struct Config {
        address sya;
        address usdc;
        address dola;
        address usde;
        address stableStakerV2;
        address nftMinter;
    }

    /// @notice One Curve Router NG payload, exactly as it is passed to `setRoute` and to the dry run.
    struct Route {
        address token;
        address[11] path;
        uint256[5][5] swapParams;
        address[5] pools;
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function expectedConfig() public view returns (Config memory c) {
        string memory book = vm.readFile(ADDRESS_BOOK);
        c.sya = _requireBook(book, "StableYieldAccumulator");
        c.usdc = _requireBook(book, "USDC");
        c.dola = _requireBook(book, "Dola");
        c.usde = _requireBook(book, "USDe");
        c.stableStakerV2 = _requireBook(book, "StableStakerV2");
        c.nftMinter = _requireBook(book, "NFTMinter");
    }

    /// @notice USDe -> crvUSD -> USDC. swapParams [i, j, swap_type, pool_type, n_coins].
    function usdeRoute(Config memory c) public pure returns (Route memory r) {
        r.token = c.usde;
        r.path[0] = c.usde;
        r.path[1] = POOL_USDE_CRVUSD;
        r.path[2] = CRVUSD;
        r.path[3] = POOL_CRVUSD_USDC;
        r.path[4] = c.usdc;
        r.swapParams[0] = [uint256(0), 1, 1, 10, 2]; // USDe(0) -> crvUSD(1), exchange, stableswap-ng
        r.swapParams[1] = [uint256(1), 0, 1, 1, 2]; // crvUSD(1) -> USDC(0), exchange, plain stable
    }

    /// @notice DOLA -> USDC through the DOLA/FRAXBP metapool, exchange_underlying 0 -> 2.
    function dolaRoute(Config memory c) public pure returns (Route memory r) {
        r.token = c.dola;
        r.path[0] = c.dola;
        r.path[1] = POOL_DOLA_FRAXBP;
        r.path[2] = c.usdc;
        r.swapParams[0] = [uint256(0), 2, 2, 1, 3];
    }

    function ethPoolKey(Config memory c) public pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(c.usdc),
            fee: ETH_POOL_FEE,
            tickSpacing: ETH_POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    // ------------------------------------------------------------------
    // Off-chain payload check (story-052 rules, audit ryv18m5)
    // ------------------------------------------------------------------

    /// @notice Pure check of one exact broadcast payload against the story-052 contiguity rules. Reverts with a
    ///         descriptive message on the first violation; returns the executed hop count k.
    ///         - path[0] == tokenIn
    ///         - k = number of leading hops with path[2i+1] != 0, and k >= 1
    ///         - no non-zero path entry after index 2k
    ///         - no zero token path[2i] for i <= k
    ///         - path[2k] == tokenOut (the reward token, USDC)
    ///         - executed swapParams rows: swap_type in 1..8 (never 0, never 9)
    ///         - unexecuted swapParams rows and EVERY pools entry are zero (no route here uses a zap)
    function checkRoutePayload(Route memory r, address tokenIn, address tokenOut) public pure returns (uint256 k) {
        require(tokenIn != address(0) && tokenOut != address(0), "route check: zero tokenIn/tokenOut");
        require(r.token == tokenIn, "route check: route registered for a different token");
        require(r.path[0] == tokenIn, "route check: path[0] != tokenIn");
        while (k < 5 && r.path[2 * k + 1] != address(0)) k++;
        require(k >= 1, "route check: no executed hop (path[1] is zero)");
        for (uint256 i = 2 * k + 1; i < 11; i++) {
            require(
                r.path[i] == address(0),
                "route check: GAPPED route - non-zero path entry after the first empty pool slot (Router NG would stop early and deliver an intermediate token)"
            );
        }
        for (uint256 i = 0; i <= k; i++) {
            require(r.path[2 * i] != address(0), "route check: zero token inside the executed prefix");
        }
        require(r.path[2 * k] == tokenOut, "route check: path[2k] (the delivered token) != tokenOut");
        for (uint256 h = 0; h < 5; h++) {
            if (h < k) {
                uint256 st = r.swapParams[h][2];
                require(st != 0, "route check: executed hop has swap_type 0");
                require(
                    st != SWAP_TYPE_ERC4626, "route check: executed hop has swap_type 9 (rejected by Router NG v1.1)"
                );
                require(st <= MAX_SWAP_TYPE, "route check: executed hop has swap_type > 8");
            } else {
                for (uint256 f = 0; f < 5; f++) {
                    require(r.swapParams[h][f] == 0, "route check: unexecuted swapParams row is not zero");
                }
            }
            require(r.pools[h] == address(0), "route check: pools entry is not zero (no route here uses a zap)");
        }
    }

    /// @notice The reverse of `r` (tokenOut -> tokenIn): path reversed, hops reversed, i/j swapped per hop,
    ///         swap_type / pool_type / n_coins kept.
    function reverseRoute(Route memory r, address tokenOut) public pure returns (Route memory rev) {
        uint256 k;
        while (k < 5 && r.path[2 * k + 1] != address(0)) k++;
        rev.token = tokenOut;
        for (uint256 i = 0; i <= 2 * k; i++) {
            rev.path[i] = r.path[2 * k - i];
        }
        for (uint256 h = 0; h < k; h++) {
            uint256[5] memory p = r.swapParams[k - 1 - h];
            rev.swapParams[h] = [p[1], p[0], p[2], p[3], p[4]];
        }
    }

    // ------------------------------------------------------------------
    // Preflight + read-back
    // ------------------------------------------------------------------

    function _preflight(Config memory c) internal view {
        _code(c.sya, "SYA");
        _code(c.usdc, "USDC");
        _code(c.dola, "DOLA");
        _code(c.usde, "USDe");
        _code(c.stableStakerV2, "StableStakerV2");
        _code(c.nftMinter, "NFTMinter");
        _code(CURVE_ROUTER_NG, "Curve Router NG");
        _code(POOL_MANAGER, "Uniswap V4 PoolManager");
        _code(CRVUSD, "crvUSD");
        require(IStableYieldAccumulator(c.sya).rewardToken() == c.usdc, "preflight: SYA rewardToken != USDC");
        require(IStableYieldAccumulator(c.sya).nftMinter() == c.nftMinter, "preflight: SYA nftMinter != book NFTMinter");
        require(IStableStakerV2ClaimGate(c.stableStakerV2).owner() == OWNER, "preflight: StableStakerV2 owner != OWNER");
        // Coin indices the swapParams rows rely on.
        require(ISyaHarvesterCurvePool(POOL_USDE_CRVUSD).coins(0) == c.usde, "preflight: USDe/crvUSD coins(0) != USDe");
        require(
            ISyaHarvesterCurvePool(POOL_USDE_CRVUSD).coins(1) == CRVUSD, "preflight: USDe/crvUSD coins(1) != crvUSD"
        );
        require(ISyaHarvesterCurvePool(POOL_CRVUSD_USDC).coins(0) == c.usdc, "preflight: crvUSD/USDC coins(0) != USDC");
        require(
            ISyaHarvesterCurvePool(POOL_CRVUSD_USDC).coins(1) == CRVUSD, "preflight: crvUSD/USDC coins(1) != crvUSD"
        );
        require(ISyaHarvesterCurvePool(POOL_DOLA_FRAXBP).coins(0) == c.dola, "preflight: DOLA/FRAXBP coins(0) != DOLA");
        require(ISyaHarvesterCurvePool(POOL_FRAXBP).coins(1) == c.usdc, "preflight: FRAXBP coins(1) != USDC");
        // Route coverage: every non-reward SYA strategy token must be DOLA or USDe (both routed here).
        IStableYieldAccumulator sya = IStableYieldAccumulator(c.sya);
        address[] memory strategies = sya.getYieldStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            address t = sya.strategyTokens(strategies[i]);
            require(
                t == c.usdc || t == c.dola || t == c.usde,
                "preflight: SYA has a strategy token this script does not route - the harvester would revert RouteNotConfigured"
            );
        }
    }

    function _code(address a, string memory name) internal view {
        require(a.code.length > 0, string.concat("preflight: no code at ", name));
    }

    /// @dev Immutables + owner of a deployed (or adopted) harvester.
    function _checkImmutables(SYAHarvester h, Config memory c) internal view {
        require(address(h).code.length > 0, "verify: SYAHarvester has no code");
        require(h.owner() == OWNER, "verify: SYAHarvester owner != OWNER");
        require(address(h.poolManager()) == POOL_MANAGER, "verify: SYAHarvester poolManager mismatch");
        require(address(h.sya()) == c.sya, "verify: SYAHarvester sya mismatch");
        require(address(h.router()) == CURVE_ROUTER_NG, "verify: SYAHarvester router mismatch");
    }

    function _routeStored(SYAHarvester h, Route memory r) internal view returns (bool) {
        SYAHarvester.CurveRoute memory s = h.getRoute(r.token);
        if (!s.configured) return false;
        return
            keccak256(abi.encode(s.path, s.swapParams, s.pools)) == keccak256(abi.encode(r.path, r.swapParams, r.pools));
    }

    function _ethPoolStored(SYAHarvester h, Config memory c) internal view returns (bool) {
        return keccak256(abi.encode(h.getEthPool())) == keccak256(abi.encode(ethPoolKey(c)));
    }

    /// @notice Full read-back: immutables, both stored routes byte-equal to the payloads AND passing the
    ///         story-052 check as stored, USDC unrouted, ETH pool key exact.
    function _checkConfigured(SYAHarvester h, Config memory c) internal view {
        _checkImmutables(h, c);
        Route memory u = usdeRoute(c);
        Route memory d = dolaRoute(c);
        require(_routeStored(h, u), "verify: stored USDe route != expected payload");
        require(_routeStored(h, d), "verify: stored DOLA route != expected payload");
        require(checkRoutePayload(_stored(h, c.usde), c.usde, c.usdc) == 2, "verify: stored USDe route is not 2 hops");
        require(checkRoutePayload(_stored(h, c.dola), c.dola, c.usdc) == 1, "verify: stored DOLA route is not 1 hop");
        require(!h.getRoute(c.usdc).configured, "verify: USDC (the reward token) must carry no route");
        require(_ethPoolStored(h, c), "verify: ETH pool key mismatch");
    }

    function _stored(SYAHarvester h, address token) internal view returns (Route memory r) {
        SYAHarvester.CurveRoute memory s = h.getRoute(token);
        r.token = token;
        r.path = s.path;
        r.swapParams = s.swapParams;
        r.pools = s.pools;
    }

    // ------------------------------------------------------------------
    // Address book + progress file
    // ------------------------------------------------------------------

    /// @dev The address literal of `key` in mainnet-addresses.ts, or address(0) when absent (uncommented
    ///      top-level entries only, so `USDC` never matches `AutoUSDC`).
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

    function _requireBook(string memory book, string memory key) internal pure returns (address a) {
        a = _bookAddress(book, key);
        require(a != address(0), string.concat("address book: key missing or zero in mainnet-addresses.ts: ", key));
    }

    /// @dev `virtual` only so fork tests can point at a scratch file.
    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    function _progressHarvester() internal view returns (address) {
        string memory json;
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            return address(0);
        }
        if (bytes(json).length == 0 || !vm.keyExistsJson(json, ".contracts.SYAHarvester.address")) return address(0);
        return vm.parseJsonAddress(json, ".contracts.SYAHarvester.address");
    }
}

contract DeploySyaHarvesterMainnet is SyaHarvesterMainnetBase {
    SYAHarvester public harvester;
    bool public deployedThisRun;
    /// @dev Transactions this run sent (or, in preview, would send). Read by the fork tests.
    uint256 public txCount;

    // Logged dry-run results (also read by the fork tests).
    uint256 public dryUsdeToUsdc;
    uint256 public dryUsdcToUsde;
    uint256 public dryDolaToUsdc;
    uint256 public dryUsdcToDola;
    uint256 public smokeEthOut;

    bool internal isPreview;

    function run() external {
        console.log("=================================================");
        console.log("  DEPLOY SYAHarvester + claim enable - MAINNET (story 122, Script A)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );

        Config memory c = expectedConfig();
        _preflight(c);
        console.log("Preflight OK: SYA / USDC / DOLA / USDe / StableStakerV2 / NFTMinter / Router NG / PoolManager");

        // ---- Route safety: BEFORE any broadcast, in both modes ----
        Route memory u = usdeRoute(c);
        Route memory d = dolaRoute(c);
        console.log("\n=== Route safety 1/2: off-chain story-052 payload check ===");
        require(checkRoutePayload(u, c.usde, c.usdc) == 2, "route check: USDe route must execute 2 hops");
        require(checkRoutePayload(d, c.dola, c.usdc) == 1, "route check: DOLA route must execute 1 hop");
        // The reverse payloads the dry run uses pass the same rules (towards tokenIn).
        checkRoutePayload(reverseRoute(u, c.usdc), c.usdc, c.usde);
        checkRoutePayload(reverseRoute(d, c.usdc), c.usdc, c.dola);
        console.log("  USDe route: 2 hops, contiguous, delivers USDC   OK");
        console.log("  DOLA route: 1 hop,  contiguous, delivers USDC   OK");
        console.log("\n=== Route safety 2/2: bidirectional fork dry run (balance deltas, snapshot-reverted) ===");
        (dryUsdeToUsdc, dryUsdcToUsde) = _dryRunBothWays(u, c, CRVUSD);
        (dryDolaToUsdc, dryUsdcToDola) = _dryRunBothWays(d, c, address(0));

        // ---- Step 1: harvester ----
        console.log("\n=== Step 1: SYAHarvester ===");
        address recorded = _progressHarvester();
        if (recorded != address(0)) {
            require(
                recorded.code.length > 0,
                "Progress file names an SYAHarvester with NO CODE - recorded in forge's local pass but never landed. Delete server/deployments/progress.sya-harvester.1.json and re-run preview."
            );
            harvester = SYAHarvester(payable(recorded));
            _checkImmutables(harvester, c);
            console.log("  adopted from progress file:", recorded);
        } else {
            _begin();
            harvester = new SYAHarvester(
                OWNER, IPoolManager(POOL_MANAGER), IStableYieldAccumulator(c.sya), ICurveRouterNG(CURVE_ROUTER_NG)
            );
            _end();
            deployedThisRun = true;
            _checkImmutables(harvester, c);
            console.log("  deployed:", address(harvester));
            // Record the address immediately (broadcast only) so a run that dies before step 6 resumes.
            if (!isPreview) _writeProgress(false);
        }

        // ---- Steps 2-4: routes + ETH pool, each gated on chain state ----
        console.log("\n=== Steps 2-4: routes + ETH pool ===");
        _setRouteIfNeeded(u, "USDe");
        _setRouteIfNeeded(d, "DOLA");
        if (_ethPoolStored(harvester, c)) {
            console.log("  ETH pool already set - skipped");
        } else {
            _begin();
            harvester.setEthPool(ethPoolKey(c));
            _end();
            console.log("  setEthPool(ETH/USDC, fee 3000, tickSpacing 60, no hooks)");
        }

        // ---- Step 5: read-back ----
        _checkConfigured(harvester, c);
        console.log(
            "  read-back OK: both routes stored byte-equal to the checked payloads, USDC unrouted, ETH pool exact"
        );

        // ---- Harvest smoke (snapshot-reverted) ----
        console.log("\n=== Harvest smoke (snapshot-reverted) ===");
        smokeEthOut = _harvestSmoke(c);

        // ---- Step 6: claim enable ----
        console.log("\n=== Step 6: StableStakerV2.setClaimEnabled(true) ===");
        IStableStakerV2ClaimGate v2 = IStableStakerV2ClaimGate(c.stableStakerV2);
        if (v2.claimEnabled()) {
            console.log("  claimEnabled already true - skipped");
        } else {
            _begin();
            v2.setClaimEnabled(true);
            _end();
            console.log("  setClaimEnabled(true) sent");
        }
        require(v2.claimEnabled(), "Step 6: StableStakerV2.claimEnabled() must be true");

        console.log("\nSYAHarvester:", address(harvester));
        console.log("Transactions this run:", txCount);
        if (isPreview) {
            console.log("PREVIEW: nothing broadcast, progress file NOT written.");
            return;
        }
        _writeProgress(true);
    }

    function _setRouteIfNeeded(Route memory r, string memory name) internal {
        if (_routeStored(harvester, r)) {
            console.log(string.concat("  ", name, " route already stored - skipped"));
            return;
        }
        _begin();
        harvester.setRoute(r.token, r.path, r.swapParams, r.pools);
        _end();
        console.log(string.concat("  setRoute(", name, ")"));
    }

    function _begin() internal {
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast(OWNER); // the Ledger signer must BE the OWNER (`--sender` + hd path)
        txCount++;
    }

    function _end() internal {
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
    }

    // ------------------------------------------------------------------
    // Dry run
    // ------------------------------------------------------------------

    /// @dev tokenIn -> USDC on `r`, then USDC -> tokenIn on its reverse, each with a fresh receiver and
    ///      DRY_RUN_UNITS of input, inside one snapshot bracket. `intermediate` (crvUSD for USDe) must end at
    ///      zero on the receiver: a delivered intermediate is exactly the ryv18m5 failure.
    function _dryRunBothWays(Route memory r, Config memory c, address intermediate)
        internal
        returns (uint256 usdcOut, uint256 tokenBack)
    {
        uint256 snap = vm.snapshotState();
        address tokenIn = r.token;

        // Forward: tokenIn -> USDC
        address fwd = address(uint160(uint256(keccak256(abi.encode("story122.dryrun.fwd", tokenIn)))));
        uint256 amountIn = DRY_RUN_UNITS * 1e18;
        usdcOut = _exchange(r, tokenIn, c.usdc, amountIn, fwd, intermediate);
        uint256 minUsdc = DRY_RUN_UNITS * 1e6 * DRY_RUN_MIN_BPS / 10_000;
        console.log(string.concat("  1000 ", _sym(tokenIn, c), " -> USDC: USDC balance delta"), usdcOut);
        require(
            usdcOut >= minUsdc,
            "dry run: forward USDC balance delta below the floor - route delivers the wrong token or misprices"
        );

        // Reverse: USDC -> tokenIn
        Route memory rev = reverseRoute(r, c.usdc);
        address bwd = address(uint160(uint256(keccak256(abi.encode("story122.dryrun.bwd", tokenIn)))));
        tokenBack = _exchange(rev, c.usdc, tokenIn, DRY_RUN_UNITS * 1e6, bwd, intermediate);
        console.log(string.concat("  1000 USDC -> ", _sym(tokenIn, c), ": tokenIn balance delta"), tokenBack);
        require(
            tokenBack >= DRY_RUN_UNITS * 1e18 * DRY_RUN_MIN_BPS / 10_000,
            "dry run: reverse tokenIn balance delta below the floor - pool indices wrong in the reverse direction"
        );

        vm.revertToState(snap);
    }

    /// @dev One Router NG exchange from a fresh `who`, measured purely by balances.
    function _exchange(
        Route memory r,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address who,
        address intermediate
    ) internal returns (uint256 delta) {
        deal(tokenIn, who, amountIn);
        uint256 outBefore = IERC20(tokenOut).balanceOf(who);
        uint256 midBefore = intermediate == address(0) ? 0 : IERC20(intermediate).balanceOf(who);
        vm.startPrank(who);
        IERC20(tokenIn).approve(CURVE_ROUTER_NG, amountIn);
        // _expected = 1: the router's own check is NOT the assertion; the balance delta below is.
        ICurveRouterNG(CURVE_ROUTER_NG).exchange(r.path, r.swapParams, amountIn, 1, r.pools, who);
        vm.stopPrank();
        require(IERC20(tokenIn).balanceOf(who) == 0, "dry run: router did not pull exactly amountIn");
        if (intermediate != address(0)) {
            require(
                IERC20(intermediate).balanceOf(who) == midBefore,
                "dry run: receiver got the INTERMEDIATE token - gapped-route failure (audit ryv18m5)"
            );
        }
        delta = IERC20(tokenOut).balanceOf(who) - outBefore;
    }

    function _sym(address t, Config memory c) internal pure returns (string memory) {
        if (t == c.usde) return "USDe";
        if (t == c.dola) return "DOLA";
        return "USDC";
    }

    // ------------------------------------------------------------------
    // Harvest smoke
    // ------------------------------------------------------------------

    /// @dev Mirrors DeployMocks 11.12 on the live stack, inside a snapshot: buy one claim NFT at
    ///      SMOKE_NFT_INDEX through the normal paid mint, approve the harvester, `harvest(no exemptions, index, 1)`
    ///      at gas price 0 (so the profitability gate does not depend on the simulation's gas price), revoke.
    ///      Asserts on deltas: caller ETH up, one NFT unit burned, SYA yield consumed, harvester empty.
    function _harvestSmoke(Config memory c) internal returns (uint256 ethOut) {
        uint256 snap = vm.snapshotState();
        IStableYieldAccumulator sya = IStableYieldAccumulator(c.sya);
        uint256 claimBefore = sya.calculateClaimAmount(new address[](0));
        console.log("  SYA calculateClaimAmount (USDC, no exemptions):", claimBefore);
        require(claimBefore > 0, "harvest smoke: SYA has no claimable yield");

        (address dispatcher, uint256 price,, bool disabled) =
            ISyaHarvesterNftMinter(c.nftMinter).configs(SMOKE_NFT_INDEX);
        require(dispatcher != address(0) && !disabled, "harvest smoke: claim NFT index not registered or disabled");
        address payToken = ISyaHarvesterDispatcher(dispatcher).primeToken();
        address caller = address(uint160(uint256(keccak256("story122.harvest.smoke.caller"))));
        deal(payToken, caller, price);

        vm.startPrank(caller, caller);
        IERC20(payToken).approve(c.nftMinter, price);
        ISyaHarvesterNftMinter(c.nftMinter).mint(SMOKE_NFT_INDEX, caller);
        IERC1155(c.nftMinter).setApprovalForAll(address(harvester), true);
        uint256 nftBefore = IERC1155(c.nftMinter).balanceOf(caller, SMOKE_NFT_INDEX);
        uint256 ethBefore = caller.balance;
        uint256 gasPriceBefore = tx.gasprice;
        vm.txGasPrice(0);
        harvester.harvest(new address[](0), SMOKE_NFT_INDEX, 1);
        vm.txGasPrice(gasPriceBefore);
        IERC1155(c.nftMinter).setApprovalForAll(address(harvester), false);
        vm.stopPrank();

        ethOut = caller.balance - ethBefore;
        console.log("  harvest ETH balance delta (wei):", ethOut);
        require(ethOut > 0, "harvest smoke: caller ETH balance did not rise");
        require(
            IERC1155(c.nftMinter).balanceOf(caller, SMOKE_NFT_INDEX) == nftBefore - 1,
            "harvest smoke: exactly one claim NFT unit must be burned"
        );
        require(
            sya.calculateClaimAmount(new address[](0)) < claimBefore, "harvest smoke: SYA claimable yield not consumed"
        );
        require(address(harvester).balance == 0, "harvest smoke: harvester kept ETH");
        require(IERC20(c.usdc).balanceOf(address(harvester)) == 0, "harvest smoke: harvester kept USDC");
        require(IERC20(c.dola).balanceOf(address(harvester)) == 0, "harvest smoke: harvester kept DOLA");
        require(IERC20(c.usde).balanceOf(address(harvester)) == 0, "harvest smoke: harvester kept USDe");
        require(IERC20(CRVUSD).balanceOf(address(harvester)) == 0, "harvest smoke: harvester kept crvUSD");
        require(
            IERC1155(c.nftMinter).balanceOf(address(harvester), SMOKE_NFT_INDEX) == 0,
            "harvest smoke: harvester kept the claim NFT"
        );
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------
    // Progress
    // ------------------------------------------------------------------

    function _writeProgress(bool claimEnabledDone) internal {
        vm.serializeAddress("s122a.harvester", "address", address(harvester));
        string memory entry = vm.serializeBool("s122a.harvester", "deployed", true);
        string memory contracts = vm.serializeString("s122a.contracts", "SYAHarvester", entry);
        vm.serializeUint("s122a.root", "chainId", CHAIN_ID);
        vm.serializeString("s122a.root", "networkName", NETWORK_NAME);
        vm.serializeBool("s122a.root", "claimEnabled", claimEnabledDone);
        vm.serializeString("s122a.root", "deploymentStatus", claimEnabledDone ? "completed" : "in_progress");
        string memory json = vm.serializeString("s122a.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written:", _progressFile());
    }

    /// @dev The ONE reader of PREVIEW_MODE; `virtual` only so fork-test harnesses can pin it.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
