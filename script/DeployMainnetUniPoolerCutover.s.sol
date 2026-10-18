// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
import {
    UniPoolerCutoverCore,
    ICutoverBalancerPooler,
    ICutoverMintDebtHook,
    ICutoverNFTMinter,
    ICutoverUniV2Router,
    ICutoverUniV2Factory,
    ICutoverUniV2Pair,
    ICutoverERC20,
    IBalancerV3VaultViews
} from "./helpers/UniPoolerCutoverCore.sol";

/**
 * @title DeployMainnetUniPoolerCutover  (story 103, sprint Balancexit, docs/BalancerWinddownPlan.md §4 Stage 2)
 * @notice The MAINNET index-4 cutover BalancerPoolerV2 (0x7f6874332c4629429d70D15f685A8230323F11F1) -> a new
 *         UniPoolerV2 on the phUSD/sUSDS Uniswap V2 pair, in ONE owner broadcast session. Every step is
 *         `UniPoolerCutoverCore._runCutover` (story 100, rewired to yield-claim-nft:052's escrow by this story), the
 *         same code the anvil rehearsal (DeployMocks Phase 11.7) and test/UniPoolerCutoverCore.t.sol run.
 *
 *         NO PROTOCOL FUNDS THROUGH ANY EOA (yield-claim-nft:052). BPT, sUSDS, phUSD and USDS move contract-to-
 *         contract only, through `UniPoolerCutoverEscrow` (operator = OWNER): old pooler -> escrow -> pair LP on
 *         UniPoolerV2, old pooler sUSDS -> UniPoolerV2, parked USDS -> escrow -> wrapped sUSDS on UniPoolerV2. The core
 *         require()s after EVERY step that OWNER's BPT/sUSDS/phUSD/USDS did not rise. Owner BPT (expected 0: its
 *         202.30 tranche was burned at block 25,985,119, F-02-052) is never moved and never makes this revert; the
 *         verify script reports it.
 *
 *         SEQUENCE (see the core's NatSpec for each require): 0 preconditions (all four poolers REVOKED on the old
 *         pooler - story 099's `incrementAuthVersion`, broadcast 2026-10-01 - and the pair absent or reserve-less);
 *         1 createPair; 2 reserves (0,0), unsynced balances recorded; 3 deploy UniPoolerV2; 3b deploy the escrow; 4
 *         BPT-address guard + withdrawBPT(escrow); 5 minAmountsOut vs the escrow's live share + escrow.exitAndSeed; 7
 *         hook.pull + mintDebt == 0; 8 hook -> UniPoolerV2 -> hook; 9 minter + live config copy + the four poolers
 *         re-authorized on UniPoolerV2; 10 replaceDispatcher(4); 11 sUSDS rescue + USDS via escrow.wrapUsds; 12
 *         old.setMinter(OWNER) + old.pause(). No Pauser register/unregister (dispatchers have no `pauser()`).
 *
 *         KILL SWITCH. `UniPoolerV2.incrementAuthVersion()` (owner) revokes every authorized pooler at once, i.e. it
 *         stops `pool()` without touching mints - the same one-tx holding pattern story 099 used on the old pooler.
 *
 * ============================== OPERATOR WARNINGS ==============================================================
 *   A CRASH MID-BROADCAST POISONS THE PROGRESS FILE: resume from broadcast receipts, not the progress file, and
 *   rename the poisoned file to `progress.unipooler-cutover.1.POISONED.<ts>.bak`. forge writes
 *   `server/deployments/progress.unipooler-cutover.1.json` during its LOCAL execution pass, before any transaction
 *   is sent, so after a crashed broadcast it names contracts that never landed. This script therefore refuses to
 *   run on ANY existing progress file except a `completed` one whose UniPooler is live on chain at index 4 (then
 *   it is a no-op). Resume by hand from `broadcast/DeployMainnetUniPoolerCutover.s.sol/1/run-latest.json` receipts:
 *   if the escrow holds BPT but `exitAndSeed` never landed, the operator either calls `exitAndSeed` with fresh
 *   floors or `escrow.abort()` (everything back to the old pooler) and re-runs from a clean state. Any re-funding
 *   of an existing escrow goes through the core's guarded `_fundEscrow`.
 *
 *   NEVER CALL `BalancerPoolerV2.setPool` ON THE OLD POOLER (0x7f6874332c4629429d70D15f685A8230323F11F1) WHILE A
 *   `UniPoolerCutoverEscrow` POINTING AT IT IS LIVE (yield-claim-nft run 22, L-27). The escrow snapshots the BPT
 *   address at deploy and `abort()` only returns the snapshot tokens; a repointed `withdrawBPT` would strand the
 *   other token in the escrow permanently. Step 4 refuses it (`old.pool() == escrow.bpt()`, read live).
 *
 * ============================== INPUTS (env) ==================================================================
 *   RECOVERY_EXIT       bool, default false. false = `removeLiquidityProportional` (pool live, before 30 Oct);
 *                       true = `removeLiquidityRecovery` (pool paused AND in Recovery Mode). Never chosen by clock.
 *   MIN_SUSDS_OUT_WEI   uint, REQUIRED, > 0. Exit floor for sUSDS on the old pooler's whole BPT balance.
 *   MIN_PHUSD_OUT_WEI   uint, REQUIRED, > 0. Exit floor for phUSD.
 *                       Both from `scripts/quote-balancer-exit-min-amounts.js` (live `cast call` share minus a
 *                       tolerance): `eval "$(node scripts/quote-balancer-exit-min-amounts.js 10)"`. The core re-checks
 *                       each floor against the live proportional share of the ESCROW's BPT in [share*(1-0.5%),share]
 *                       in every mode, so a stale or mis-sized floor reverts the simulation before anything is sent.
 *   CUTOVER_GAS_PRICE_WEI  set by `:broadcast` (default 0.3 gwei), passed to `--with-gas-price`.
 *
 * Preview:   npm run unipooler-cutover:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written;
 *                                                  then a preview-only test mint + quotePool-floored pool())
 * Broadcast: npm run unipooler-cutover:broadcast   (backup -> Ledger m/44'/60'/46'/0/0 -> patcher -> :verify -> :preview)
 * Verify:    npm run unipooler-cutover:verify      (read-only, script/VerifyUniPoolerCutover.s.sol)
 */

/// @notice Shared constants, the address-book cross-check, the progress reader and the post-cutover checks for the
///         cutover and verify scripts.
abstract contract UniPoolerCutoverMainnetBase is Script, StdCheats, UniPoolerCutoverCore {
    uint256 public constant CHAIN_ID = 1;
    string public constant NETWORK_NAME = "mainnet";

    string public constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";
    string public constant PROGRESS_FILE = "server/deployments/progress.unipooler-cutover.1.json";

    /// @dev Mainnet OWNER EOA (Ledger m/44'/60'/46'/0/0): owner of the old pooler, the hook and NFTMinterV2; the
    ///      escrow's operator; authorized pooler #1.
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ---- mainnet-addresses.ts keys (cross-checked against the book in `_requireBook`) ----
    address public constant OLD_POOLER = 0x7f6874332c4629429d70D15f685A8230323F11F1; // BalancerPooler (V2, index 4)
    address public constant MINT_DEBT_HOOK = 0x4A26ad83306a2F17155799fDD9449f77eb3F8bD7; // BalancerPoolerMintDebtHook
    address public constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F; // NFTMinter (V2)
    address public constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D; // UniswapV2Router (Router02)
    address public constant BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd; // BalancerRouter (V3)
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9; // BalancerVault (V3)
    address public constant BPT = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04; // BalancerPool (phUSD/sUSDS)
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant MULTI_POOLER = 0xd1E5774159381915f5579dFd68507E2614f67b51; // authorized pooler #2

    // ---- no address-book key ----
    address public constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // Router02.factory()
    address public constant POOLER_7702_EOA = 0x186c77B80Bbfd21b01C7D7FA44bA27031322a77F; // authorized pooler #3
    address public constant POOLER_EOA = 0x630966B668b321Cc6441754f96519a55F72Cd476; // authorized pooler #4

    uint256 public constant DISPATCHER_INDEX = 4;
    /// @dev Exit-floor tolerance the core enforces: each floor within 0.5% below the live share. The quote helper's
    ///      default (10 bps) sits well inside it, leaving room for pool drift between quoting and broadcasting.
    uint256 public constant EXIT_TOLERANCE_BPS = 50;
    /// @dev Router02 seed deadline offset from the simulation timestamp (the escrow and core cap it at 1 day).
    uint256 public constant SEED_DEADLINE_OFFSET = 1 hours;
    /// @dev Floors for the preview / verify `quotePool`-floored `pool()`: quote minus 0.5%.
    uint256 public constant POOL_PREVIEW_TOLERANCE_BPS = 50;

    /// @notice The four poolers story 099 revoked on the old pooler and the cutover re-authorizes on UniPoolerV2
    ///         (mainnet-addresses / docs/BalancerWinddownPlan.md §4).
    function poolers() public pure returns (address[] memory ps) {
        ps = new address[](4);
        ps[0] = OWNER;
        ps[1] = MULTI_POOLER;
        ps[2] = POOLER_7702_EOA;
        ps[3] = POOLER_EOA;
    }

    // ------------------------------------------------------------------------------------------- address book

    /// @dev The address literal of `key` in mainnet-addresses.ts, or address(0) when the key is absent. Matches only
    ///      an uncommented top-level entry (`\n  <key>: "0x..."`) - same reader as story 111's.
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

    function _requireBook(string memory book, string memory key, address expected) internal pure {
        require(
            _bookAddress(book, key) == expected,
            string.concat("address book: mainnet-addresses.ts ", key, " != the cutover script's constant")
        );
    }

    /// @notice Configuration safety: every constant with a book key equals the book, and every live address the
    ///         core reads off the old pooler / hook / router equals the constants, so a wrong-but-live address fails
    ///         here rather than mid-run.
    function _preflightAddresses() internal view {
        string memory book = vm.readFile(ADDRESS_BOOK);
        _requireBook(book, "BalancerPooler", OLD_POOLER);
        _requireBook(book, "BalancerPoolerMintDebtHook", MINT_DEBT_HOOK);
        _requireBook(book, "NFTMinter", NFT_MINTER);
        _requireBook(book, "UniswapV2Router", UNIV2_ROUTER);
        _requireBook(book, "BalancerRouter", BALANCER_ROUTER);
        _requireBook(book, "BalancerVault", BALANCER_VAULT);
        _requireBook(book, "BalancerPool", BPT);
        _requireBook(book, "SUSDS", SUSDS);
        _requireBook(book, "USDS", USDS);
        _requireBook(book, "PhUSD", PHUSD);
        _requireBook(book, "MultiPooler", MULTI_POOLER);

        ICutoverBalancerPooler old = ICutoverBalancerPooler(OLD_POOLER);
        require(old.pool() == BPT, "preflight: old pooler pool() != BalancerPool");
        require(old.vault() == BALANCER_VAULT, "preflight: old pooler vault() != BalancerVault");
        require(old.sUSDS() == SUSDS, "preflight: old pooler sUSDS() != SUSDS");
        require(old.primeToken() == USDS, "preflight: old pooler primeToken() != USDS");
        require(ICutoverMintDebtHook(MINT_DEBT_HOOK).phUSD() == PHUSD, "preflight: hook phUSD() != PhUSD");
        require(ICutoverUniV2Router(UNIV2_ROUTER).factory() == UNIV2_FACTORY, "preflight: Router02.factory()");
        require(BALANCER_ROUTER.code.length > 0, "preflight: no code at BalancerRouter");
    }

    // --------------------------------------------------------------------------------------------- progress

    /// @dev The progress file path. `virtual` only so fork tests can point at a scratch file.
    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    function _readProgress() internal view returns (bool exists, string memory json) {
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            return (false, "");
        }
        exists = bytes(json).length > 0;
    }

    function _progressAddress(string memory json, string memory name) internal view returns (address) {
        string memory key = string.concat(".contracts.", name, ".address");
        if (!vm.keyExistsJson(json, key)) return address(0);
        return vm.parseJsonAddress(json, key);
    }

    function _progressUint(string memory json, string memory key) internal view returns (uint256) {
        string memory k = string.concat(".cutover.", key);
        require(vm.keyExistsJson(json, k), string.concat("progress file: missing cutover.", key));
        return vm.parseUint(vm.parseJsonString(json, k));
    }

    // ------------------------------------------------------------------------------- post-cutover checks

    /// @dev The post-cutover wiring, read live. Shared by the cutover's own closing check and the verifier.
    function _checkWiring(address newPooler, address pair) internal view {
        require(newPooler.code.length > 0, "verify: UniPooler has no code");
        (address d,,, bool disabled) = ICutoverNFTMinter(NFT_MINTER).configs(DISPATCHER_INDEX);
        require(d == newPooler, "verify: configs(4).dispatcher != UniPooler");
        require(!disabled, "verify: index 4 disabled");
        require(
            ICutoverMintDebtHook(MINT_DEBT_HOOK).dispatcher() == newPooler, "verify: hook.dispatcher() != UniPooler"
        );
        UniPoolerV2 np = UniPoolerV2(newPooler);
        require(address(np.hook()) == MINT_DEBT_HOOK, "verify: UniPooler.hook() != BalancerPoolerMintDebtHook");
        require(np.owner() == OWNER, "verify: UniPooler owner != OWNER");
        require(_minterOf(newPooler) == NFT_MINTER, "verify: UniPooler minter != NFTMinter");
        require(np.pair() == pair, "verify: UniPooler.pair() != PhusdSusdsPair");
        require(
            pair == ICutoverUniV2Factory(UNIV2_FACTORY).getPair(SUSDS, PHUSD), "verify: pair is not the canonical pair"
        );
        require(np.sUSDS() == SUSDS && np.phUSD() == PHUSD, "verify: UniPooler tokens");
        require(np.router() == UNIV2_ROUTER, "verify: UniPooler router");

        ICutoverBalancerPooler old = ICutoverBalancerPooler(OLD_POOLER);
        require(np.psm() == old.psm(), "verify: psm not copied");
        require(np.maxTout() == old.maxTout(), "verify: maxTout not copied");
        require(np.batchMinter() == old.batchMinter(), "verify: batchMinter not copied");
        require(np.batchDonationSize() == old.batchDonationSize(), "verify: batchDonationSize not copied");
        require(np.nudgeStreamer() == old.nudgeStreamer(), "verify: nudgeStreamer not copied");
        address[] memory ps = poolers();
        for (uint256 i = 0; i < ps.length; i++) {
            require(np.poolerAuthVersion(ps[i]) == np.authVersion(), "verify: pooler not authorized on UniPooler");
        }
        require(old.paused(), "verify: old pooler not paused");
        require(_minterOf(OLD_POOLER) == OWNER, "verify: old pooler minter != OWNER");
    }

    /// @dev Old pooler and escrow hold nothing of the four moved tokens.
    function _checkDrained(address escrow) internal view {
        require(ICutoverERC20(BPT).balanceOf(OLD_POOLER) == 0, "verify: old pooler holds BPT");
        require(ICutoverERC20(SUSDS).balanceOf(OLD_POOLER) == 0, "verify: old pooler holds sUSDS");
        require(ICutoverERC20(USDS).balanceOf(OLD_POOLER) == 0, "verify: old pooler holds USDS (parked USDS not moved)");
        if (escrow != address(0)) {
            require(ICutoverERC20(BPT).balanceOf(escrow) == 0, "verify: escrow holds BPT");
            require(ICutoverERC20(SUSDS).balanceOf(escrow) == 0, "verify: escrow holds sUSDS");
            require(ICutoverERC20(PHUSD).balanceOf(escrow) == 0, "verify: escrow holds phUSD");
            require(ICutoverERC20(USDS).balanceOf(escrow) == 0, "verify: escrow holds USDS");
        }
    }

    /// @dev `ATokenDispatcherV2._minter` has no getter. It is storage slot 1 (after Pausable._paused and
    ///      Ownable._owner packed in slot 0) in BOTH UniPoolerV2 and BalancerPoolerV2 (`forge inspect ...
    ///      storageLayout`); the fork test pins it against the live old pooler's known minter (NFTMinterV2).
    uint256 internal constant DISPATCHER_MINTER_SLOT = 1;

    function _minterOf(address dispatcher) internal view returns (address) {
        return address(uint160(uint256(vm.load(dispatcher, bytes32(DISPATCHER_MINTER_SLOT)))));
    }

    /// @dev Owner BPT is REPORTED, never required (F-02-052: anyone can donate BPT to the owner).
    function _reportOwnerBpt() internal view returns (uint256 b) {
        b = ICutoverERC20(BPT).balanceOf(OWNER);
        console.log("  owner BPT (out of scope, reported only):", b);
        if (b > 0) {
            console.log(
                "  WARNING: OWNER holds BPT. It is NOT part of the cutover (F-02-052); exit it separately if wanted."
            );
        }
    }

    /// @dev pair reserves in (sUSDS, phUSD) order.
    function _reservesSP(address pair) internal view returns (uint256 rS, uint256 rP) {
        (uint112 r0, uint112 r1,) = ICutoverUniV2Pair(pair).getReserves();
        bool s0 = ICutoverUniV2Pair(pair).token0() == SUSDS;
        (rS, rP) = s0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @notice `quotePool`-floored `pool()` as OWNER (an authorized pooler), inside a state snapshot that is
    ///         reverted afterwards, so it never changes what later checks or a broadcast see. If the pooler holds no
    ///         sUSDS (nothing minted since the cutover), 100 sUSDS is dealt to it inside the snapshot.
    function _simulateQuotedPool(address newPooler) internal returns (uint256 lpGained) {
        uint256 snap = vm.snapshotState();
        UniPoolerV2 np = UniPoolerV2(newPooler);
        uint256 sIn = ICutoverERC20(SUSDS).balanceOf(newPooler);
        if (sIn == 0) {
            deal(SUSDS, newPooler, 100e18);
            sIn = 100e18;
        }
        (, uint256 phusdOut, uint256 expectedLP) = np.quotePool(sIn);
        uint256 minPhusdOut = (phusdOut * (CUTOVER_MAX_BPS - POOL_PREVIEW_TOLERANCE_BPS)) / CUTOVER_MAX_BPS;
        uint256 minLP = (expectedLP * (CUTOVER_MAX_BPS - POOL_PREVIEW_TOLERANCE_BPS)) / CUTOVER_MAX_BPS;
        require(minPhusdOut > 0 && minLP > 0, "verify: quotePool floors are zero");
        address pair = np.pair();
        uint256 lpBefore = ICutoverUniV2Pair(pair).balanceOf(newPooler);
        vm.prank(OWNER);
        np.pool(sIn, minPhusdOut, minLP);
        lpGained = ICutoverUniV2Pair(pair).balanceOf(newPooler) - lpBefore;
        require(lpGained >= minLP, "verify: pool() minted less LP than its quotePool floor");
        console.log("  quotePool-floored pool() simulated OK; sUSDS in:", sIn);
        console.log("  LP gained (simulated, reverted):", lpGained);
        vm.revertToState(snap);
    }

    /// @dev The ONE reader of PREVIEW_MODE. `virtual` only so fork-test harnesses can pin the mode (`vm.setEnv` is
    ///      process-wide and forge runs suites in parallel). Production always reads the env.
    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}

contract DeployMainnetUniPoolerCutover is UniPoolerCutoverMainnetBase {
    bool public isPreview;
    bool public cutoverRanThisRun;
    ExitMode public exitModeUsed;
    CutoverResult internal _result;

    function result() external view returns (CutoverResult memory) {
        return _result;
    }

    function run() external {
        console.log("=================================================");
        console.log("  MAINNET INDEX-4 CUTOVER BalancerPoolerV2 -> UniPoolerV2 (story 103)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        cutoverRanThisRun = false;
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, progress NOT written)" : "Mode: BROADCAST (Ledger)"
        );

        if (_alreadyCompleted()) return;

        _preflightAddresses();
        console.log("Preflight OK: constants == mainnet-addresses.ts and == the old pooler's live wiring.");
        _reportOwnerBpt();

        CutoverParams memory p = _buildParams();
        exitModeUsed = p.exitMode;
        _logParams(p);

        _beginOwnerSession(isPreview);
        _result = _runCutover(p);
        _endOwnerSession(isPreview);
        cutoverRanThisRun = true;

        _logResult(_result);
        _checkWiring(_result.newPooler, _result.pair);
        _checkDrained(_result.escrow);
        console.log("OK: post-cutover wiring and drained balances asserted.");

        if (isPreview) {
            _previewEndToEnd(_result);
            console.log(
                "PREVIEW: nothing broadcast, progress file NOT written (preview CREATE addresses are fork-local)."
            );
            return;
        }
        _writeProgress(_result);
    }

    // ------------------------------------------------------------------------------------------------ inputs

    /// @notice RECOVERY_EXIT (default false). `virtual` only for fork-test harnesses.
    function _exitModeFromEnv() internal view virtual returns (ExitMode) {
        return vm.envOr("RECOVERY_EXIT", false) ? ExitMode.RECOVERY : ExitMode.PROPORTIONAL;
    }

    /// @notice MIN_SUSDS_OUT_WEI / MIN_PHUSD_OUT_WEI, both REQUIRED and > 0. `virtual` only for fork-test harnesses.
    function _minAmountsFromEnv() internal view virtual returns (uint256 minSUSDS, uint256 minPhUSD) {
        minSUSDS = vm.envOr("MIN_SUSDS_OUT_WEI", uint256(0));
        minPhUSD = vm.envOr("MIN_PHUSD_OUT_WEI", uint256(0));
    }

    function _buildParams() internal view returns (CutoverParams memory p) {
        (uint256 minS, uint256 minP) = _minAmountsFromEnv();
        require(
            minS > 0 && minP > 0,
            "MIN_SUSDS_OUT_WEI and MIN_PHUSD_OUT_WEI must both be set and non-zero: eval \"$(node scripts/quote-balancer-exit-min-amounts.js 10)\""
        );
        p.owner = OWNER;
        p.oldPooler = OLD_POOLER;
        p.mintDebtHook = MINT_DEBT_HOOK;
        p.nftMinter = NFT_MINTER;
        p.dispatcherIndex = DISPATCHER_INDEX;
        p.uniV2Router = UNIV2_ROUTER;
        p.balancerRouter = BALANCER_ROUTER;
        p.poolers = poolers();
        p.exitMode = _exitModeFromEnv();
        // Balancer pool-token order, read live.
        (address[] memory tokens,,,) = IBalancerV3VaultViews(BALANCER_VAULT).getPoolTokenInfo(BPT);
        require(tokens.length == 2, "pool not two-token");
        p.minAmountsOut = new uint256[](2);
        if (tokens[0] == SUSDS) {
            require(tokens[1] == PHUSD, "pool tokens mismatch");
            (p.minAmountsOut[0], p.minAmountsOut[1]) = (minS, minP);
        } else {
            require(tokens[0] == PHUSD && tokens[1] == SUSDS, "pool tokens mismatch");
            (p.minAmountsOut[0], p.minAmountsOut[1]) = (minP, minS);
        }
        p.exitToleranceBps = EXIT_TOLERANCE_BPS;
        p.seedDeadline = block.timestamp + SEED_DEADLINE_OFFSET;
    }

    // ---------------------------------------------------------------------------------------------- session

    /// @dev `virtual` only so a fork-test harness can drive the broadcast-mode path (progress writing) under an
    ///      OWNER prank. Production: preview pranks, broadcast uses the Ledger `--sender`.
    function _beginOwnerSession(bool preview) internal virtual {
        if (preview) vm.startPrank(OWNER);
        else vm.startBroadcast();
    }

    function _endOwnerSession(bool preview) internal virtual {
        if (preview) vm.stopPrank();
        else vm.stopBroadcast();
    }

    // ---------------------------------------------------------------------------------------------- progress

    /// @dev True (and nothing to do) only for a `completed` progress file whose UniPooler is live at index 4. Any
    ///      other existing progress file is treated as POISONED and refuses to run.
    function _alreadyCompleted() internal view returns (bool) {
        (bool exists, string memory json) = _readProgress();
        if (!exists) {
            console.log("No progress file - fresh cutover.");
            return false;
        }
        bool completed = vm.keyExistsJson(json, ".deploymentStatus")
            && keccak256(bytes(vm.parseJsonString(json, ".deploymentStatus"))) == keccak256("completed");
        address np = completed ? _progressAddress(json, "UniPooler") : address(0);
        (address d,,,) = ICutoverNFTMinter(NFT_MINTER).configs(DISPATCHER_INDEX);
        if (completed && np != address(0) && np.code.length > 0 && d == np) {
            console.log("Progress file is completed and its UniPooler is live at index 4:", np);
            console.log("Nothing to do - no transaction sent. Run `npm run unipooler-cutover:verify`.");
            return true;
        }
        revert(
            "Progress file server/deployments/progress.unipooler-cutover.1.json exists but the cutover is not live on chain - it is POISONED (forge writes it in its local pass). Resume from broadcast receipts, not the progress file, and rename it to progress.unipooler-cutover.1.POISONED.<ts>.bak"
        );
    }

    function _writeProgress(CutoverResult memory r) internal {
        string memory c;
        c = _serializeEntry("UniPooler", r.newPooler);
        c = _serializeEntry("PhusdSusdsPair", r.pair);
        c = _serializeEntry("UniPoolerCutoverEscrow", r.escrow);

        vm.serializeString("s103.cutover", "exitMode", exitModeUsed == ExitMode.RECOVERY ? "RECOVERY" : "PROPORTIONAL");
        vm.serializeString("s103.cutover", "cutoverBlock", vm.toString(block.number));
        vm.serializeString("s103.cutover", "ownerBptAtStart", vm.toString(r.ownerBptAtStart));
        vm.serializeString("s103.cutover", "pairDonationSUSDS", vm.toString(r.pairDonationSUSDS));
        vm.serializeString("s103.cutover", "pairDonationPhUSD", vm.toString(r.pairDonationPhUSD));
        vm.serializeString("s103.cutover", "bptWithdrawn", vm.toString(r.bptWithdrawn));
        vm.serializeString("s103.cutover", "bptExited", vm.toString(r.bptExited));
        vm.serializeString("s103.cutover", "sUSDSSeeded", vm.toString(r.sUSDSSeeded));
        vm.serializeString("s103.cutover", "phUSDSeeded", vm.toString(r.phUSDSeeded));
        vm.serializeString("s103.cutover", "liquidity", vm.toString(r.liquidity));
        vm.serializeString("s103.cutover", "sUSDSRescued", vm.toString(r.sUSDSRescued));
        vm.serializeString("s103.cutover", "usdsRescued", vm.toString(r.usdsRescued));
        string memory cut = vm.serializeString("s103.cutover", "usdsWrappedShares", vm.toString(r.usdsWrappedShares));

        vm.serializeUint("s103.root", "chainId", CHAIN_ID);
        vm.serializeString("s103.root", "networkName", NETWORK_NAME);
        vm.serializeString("s103.root", "deploymentStatus", "completed");
        vm.serializeString("s103.root", "cutover", cut);
        string memory json = vm.serializeString("s103.root", "contracts", c);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written:", _progressFile());
    }

    function _serializeEntry(string memory name, address addr) internal returns (string memory contractsJson) {
        string memory k = string.concat("s103.e.", name);
        vm.serializeAddress(k, "address", addr);
        string memory entry = vm.serializeBool(k, "deployed", addr != address(0));
        contractsJson = vm.serializeString("s103.contracts", name, entry);
    }

    // ------------------------------------------------------------------------------------- preview-only E2E

    /// @notice PREVIEW ONLY (never in a broadcast session: `deal` and prank are fork-local). A test mint at index 4
    ///         dispatches through UniPoolerV2, wraps USDS into sUSDS on it and accrues mint debt on the hook; then a
    ///         `quotePool`-floored `pool()` succeeds.
    function _previewEndToEnd(CutoverResult memory r) internal {
        require(isPreview, "preview-only E2E outside preview");
        console.log("");
        console.log("--- PREVIEW E2E: test mint at index 4 + quotePool-floored pool() ---");
        address user = address(uint160(uint256(keccak256("story103.preview.minter"))));
        (, uint256 price,,) = ICutoverNFTMinter(NFT_MINTER).configs(DISPATCHER_INDEX);
        address prime = UniPoolerV2(r.newPooler).primeToken();
        uint256 sBefore = ICutoverERC20(SUSDS).balanceOf(r.newPooler);
        uint256 debtBefore = ICutoverMintDebtHook(MINT_DEBT_HOOK).mintDebt();
        deal(prime, user, price);
        vm.startPrank(user);
        ICutoverERC20(prime).approve(NFT_MINTER, price);
        IPreviewMinter(NFT_MINTER).mint(DISPATCHER_INDEX, user);
        vm.stopPrank();
        require(ICutoverERC20(SUSDS).balanceOf(r.newPooler) > sBefore, "preview: test mint did not wrap on UniPoolerV2");
        require(ICutoverMintDebtHook(MINT_DEBT_HOOK).mintDebt() > debtBefore, "preview: test mint accrued no debt");
        console.log("  test mint dispatched via UniPoolerV2; price paid:", price);
        console.log("  UniPoolerV2 sUSDS after mint:", ICutoverERC20(SUSDS).balanceOf(r.newPooler));
        console.log("  hook mint debt after mint:", ICutoverMintDebtHook(MINT_DEBT_HOOK).mintDebt());
        _simulateQuotedPool(r.newPooler);
    }

    // ------------------------------------------------------------------------------------------------ logging

    function _logParams(CutoverParams memory p) internal pure {
        console.log("Inputs:");
        console.log(
            "  exit mode:", p.exitMode == ExitMode.RECOVERY ? "RECOVERY (removeLiquidityRecovery)" : "PROPORTIONAL"
        );
        console.log("  minAmountsOut[0] (pool order):", p.minAmountsOut[0]);
        console.log("  minAmountsOut[1] (pool order):", p.minAmountsOut[1]);
        console.log("  exit tolerance (bps):", p.exitToleranceBps);
        console.log("  seed deadline:", p.seedDeadline);
    }

    function _logResult(CutoverResult memory r) internal pure {
        console.log("");
        console.log("=================================================");
        console.log("        UNIPOOLER CUTOVER RESULT");
        console.log("=================================================");
        console.log("  UniPooler (UniPoolerV2):", r.newPooler);
        console.log("  PhusdSusdsPair:", r.pair);
        console.log("  UniPoolerCutoverEscrow:", r.escrow);
        console.log("  unsynced pair donation at step 2 - sUSDS:", r.pairDonationSUSDS);
        console.log("  unsynced pair donation at step 2 - phUSD:", r.pairDonationPhUSD);
        console.log("  BPT old pooler -> escrow:", r.bptWithdrawn);
        console.log("  BPT exited by the escrow:", r.bptExited);
        console.log("  pair seeded - sUSDS:", r.sUSDSSeeded);
        console.log("  pair seeded - phUSD:", r.phUSDSeeded);
        console.log("  LP minted to UniPoolerV2:", r.liquidity);
        console.log("  sUSDS rescued old -> UniPoolerV2:", r.sUSDSRescued);
        console.log("  USDS parked old -> escrow -> wrapped:", r.usdsRescued);
        console.log("  wrapped sUSDS shares on UniPoolerV2:", r.usdsWrappedShares);
        console.log("  owner BPT at start (not moved):", r.ownerBptAtStart);
    }
}

interface IPreviewMinter {
    function mint(uint256 index, address recipient) external returns (bool);
}
