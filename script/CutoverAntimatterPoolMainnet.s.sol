// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/StdCheats.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";
import {IPausableLike, IPauserRegistry} from "./CutoverStableStakerV2Mainnet.s.sol";

interface IAmCutoverPooler {
    function rescueERC20(address token, address to, uint256 amount) external;
    function owner() external view returns (address);
}

interface IAmCutoverAntimatter {
    function setApprovedMinter(address minter, bool approved) external;
    function isApprovedMinter(address minter) external view returns (bool);
    function owner() external view returns (address);
}

interface IAmCutoverOwned {
    function owner() external view returns (address);
}

interface IAmCutoverRouter {
    function factory() external view returns (address);
}

interface IAmCutoverFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IAmCutoverPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
}

/**
 * @title CutoverAntimatterPoolMainnet  (story 122, Script B, sprint sya-antimatter-cutover; M-02 freeze story 124)
 * @notice The mainnet Antimatter/sUSDS cutover, mirroring DeployMocks Phase 11.10 `_rehearseAntimatterPoolCutover`
 *         (story 114) with `CUTOVER_BPS = 1_000` (10%) instead of the anvil 50%. It runs INSIDE a StableStakerV2
 *         (SSV2) freeze (story 124, audit run-44 M-02 / run-45 pps44m2):
 *          -1. freeze gate: SSV2 must be frozen by the separate, already-mined freeze step
 *              (`script/FreezeStableStakerV2ForCutover.s.sol`: `setPauser(OWNER)` -> `Pauser.unregister(SSV2)` ->
 *              `pause()`), i.e. `paused && pauser == OWNER && !Pauser.isRegistered(SSV2)` - unless B has already
 *              completed on chain (`_bCompletedOnChain`), in which case the whole run is the re-run no-op path;
 *           0. AM/sUSDS pair gate, keyed on CHAIN state (never on progress-file numbers alone):
 *              - pair absent -> `Antimatter.totalSupply() == 0` (M-02: nobody outside the cutover holds AM, so nobody
 *                can build a dust AM/sUSDS LP; a non-zero supply ABORTS before any transaction);
 *              - pair present -> resume only if it is the progress file's pair, the seed is recorded and OWNER holds
 *                at least the recorded `liquidity` of its LP (run-45 recommendation; was `> 0`). Anything else ABORTS.
 *              Both are SIMULATION-TIME checks. Under `--broadcast --skip-simulation --slow` steps 1, 4, 5 and 6 are
 *              mined publicly before step 7, so a pair can still appear in between; the on-chain `minSUSDSPaired`
 *              floor (step 7) is the control for that window (audit run-44 M-01);
 *           1. deploy `AntimatterPoolSeeder(OWNER, phUSD, sUSDS, Antimatter, Router02, PhusdSusdsPair, UniPoolerV2)`;
 *           2. `lp = seeder.lpForBps(1_000)`;
 *           3. floors: pro-rata unwrap amounts minus 0.1% (`_floors`), plus `minSPaired`, the floor on the sUSDS
 *              actually paired with the Antimatter (the same pro-rata sUSDS quote: on a fresh pair every unit of the
 *              unwrapped sUSDS is paired);
 *           4. `UniPoolerV2.rescueERC20(PhusdSusdsPair, OWNER, lp)`;
 *           5. `PhusdSusdsPair.approve(seeder, lp)`;
 *           6. `Antimatter.setApprovedMinter(seeder, true)` + require (the setter is a silent no-op on no change);
 *           7. `seeder.seed(lp, minPhUSD, minSUSDS, minSUSDSPaired, OWNER, now + 1h)`;
 *           8. `Antimatter.setApprovedMinter(seeder, false)` + require - runs on every run that gets past steps -1/0;
 *           9. `amSusdsPair = seeder.amSusdsPair()` == `factory.getPair(AM, sUSDS)`; both written to the progress file;
 *          10. restore SSV2, B's FINAL transactions: `SSV2.unpause()` -> `SSV2.setPauser(Pauser)` ->
 *              `Pauser.register(SSV2)` (unpause BEFORE register, so the global Pauser never holds a paused
 *              registrant), each skipped when already done; then the registrant sweep (every registrant unpaused,
 *              `pauser == Pauser`). If any earlier transaction reverts on chain, `--slow` stops sending and SSV2 stays
 *              frozen AND unregistered: the AM source stays shut while the global Pauser still works for the other
 *              registrants. That is the safe failure mode.
 *
 *         WHY THE FREEZE (M-02). B-before-A ordering does NOT keep AM out of third-party hands: any SSV2 staker can
 *         `withdraw` their full principal (banks the pending reward without a `claimEnabled` check) and then
 *         `autoAnnihilate`, whose excess branch mints the whole reward as raw AM (run-45: 26.44 AM with
 *         `claimEnabled == false`). With AM in hand an outsider can mint a dust AM/sUSDS LP to OWNER and spoof a
 *         re-run of B into "resuming" onto the attacker's pair. SSV2 is the only approved AM minter and `stake`,
 *         `withdraw`, `claim` and `autoAnnihilate` are `whenNotPaused`, so once the freeze is MINED (a separate
 *         invocation chained with `&&`, because a forge-script `require` runs only in the local pass) the supply
 *         check in B's local pass stays true until B's own seed mints AM. The protection is the freeze plus the
 *         supply check, not script order; the npm key still runs B before A (the M-01 floor argument is unchanged).
 *         Residual, accepted: OWNER itself can mint AM (`onlyApprovedMinters` admits `owner()`), and
 *         `batchMigrate`/`userMigrate` mint ungated but need a migration to have been initiated - never start an
 *         SSV2 migration during the window.
 *
 *         F3 (story 113): the seeder's AM/sUSDS router add passes `amountBMin = 0`. That is bounded by the seeder's
 *         on-chain `minSUSDSPaired` floor, NOT by step 0: a pair created and priced AM-cheap between the publicly
 *         mined setup txs and the seed makes the seed revert `InsufficientSUSDSPaired` instead of pouring the
 *         protocol-minted AM into a pool the attacker can drain (audit run-44 M-01). Under the freeze nobody but
 *         OWNER can hold AM in that window, so the floor is now a backstop. A one-sided griefed pair (dust + sync,
 *         no LP) still seeds: the direct mint pairs all the sUSDS, so it clears the floor.
 *         R1 / private RPC: a private RPC hides only PENDING transactions. Under `--slow` steps 1-6 are mined
 *         publicly before step 7, so it does not cover the window; it remains optional (`ANTIMATTER_POOL_RPC_URL`,
 *         scoped to the freeze step's and this script's forge calls, so the freeze is read back from the same node)
 *         and carries no part of the safety argument.
 *
 *         RESUMABLE (progress file `server/deployments/progress.antimatter-pool.1.json`). The LP slice `lp` is
 *         fixed at first sizing and persisted, because `lpForBps` reads the pooler's LIVE balance, which the rescue
 *         itself shrinks. Gates read chain state: rescue done when OWNER holds `ownerLpBefore + lp`; approval done
 *         when the allowance covers `lp`; grant done when `isApprovedMinter`; seed done when the progress pair exists
 *         on chain AND OWNER holds at least the recorded liquidity of it. If a run dies after step 4 the LP sits
 *         safely on OWNER, SSV2 stays frozen, and the resume (freeze step no-op, then B) continues at 5.
 *
 *         END STATE (asserted in-run, in the same simulated block as the seed, and recorded for the verifier):
 *         phUSD supply fell by exactly the AM minted; AM supply rose by the same; the pair's AM reserve equals it;
 *         UniPoolerV2 holds its prior LP minus `lp`; the seeder holds nothing; the seeder is not an AM minter;
 *         OWNER holds the AM/sUSDS LP; SSV2 is unpaused, `pauser == Pauser` and registered.
 *
 * Preview:   npm run antimatter-pool:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written;
 *            B's preview pranks the freeze itself first, then probes the global Pauser before the freeze, while
 *            frozen and after the restore)
 * Broadcast: npm run sya-antimatter-cutover:broadcast (preferred: freeze + B, then Script A, then Script C), or
 *            npm run antimatter-pool:broadcast alone (backup -> freeze -> B on the Ledger -> patcher -> :verify ->
 *            ledger). Optional private RPC for the freeze and B only: ANTIMATTER_POOL_RPC_URL=<url>.
 * Verify:    npm run antimatter-pool:verify      (read-only, script/VerifyAntimatterPoolCutover.s.sol)
 * Abort:     npm run ssv2-unfreeze-after-cutover-abort:broadcast - the human's call only, never chained (runbook).
 */
abstract contract AntimatterPoolMainnetBase is Script {
    uint256 public constant CHAIN_ID = 1;
    string public constant NETWORK_NAME = "mainnet";
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    string public constant ADDRESS_BOOK = "server/deployments/mainnet-addresses.ts";
    string public constant PROGRESS_FILE = "server/deployments/progress.antimatter-pool.1.json";

    /// @dev 10% of UniPoolerV2's phUSD/sUSDS LP (story 122; the human's choice; anvil rehearses 5_000).
    uint256 public constant CUTOVER_BPS = 1_000;
    uint256 public constant BPS = 10_000;
    /// @dev Unwrap-floor tolerance under the pro-rata quote: 0.1% (DeployMocks `UNI_POOL_TOLERANCE_BPS`).
    uint256 public constant FLOOR_TOLERANCE_BPS = 10;
    uint256 public constant SEED_DEADLINE = 1 hours;

    struct Config {
        address phUSD;
        address sUSDS;
        address antimatter;
        address router;
        address factory;
        address phusdSusdsPair;
        address uniPooler;
        // story 124 (M-02 freeze)
        address stableStakerV2;
        address pauser;
    }

    /// @notice Everything the progress file records; zero fields mean "not reached yet".
    struct Progress {
        address seeder;
        address amPair;
        uint256 lpAmount;
        uint256 poolerLpBefore;
        uint256 ownerLpBefore;
        // seed record (only once seeded)
        bool seeded;
        uint256 amMinted;
        uint256 liquidity;
        uint256 phusdSupplyBefore;
        uint256 phusdSupplyAfter;
        uint256 amSupplyBefore;
        uint256 amSupplyAfter;
        uint256 amReserve;
        uint256 poolerLpAfter;
    }

    function expectedConfig() public view returns (Config memory c) {
        string memory book = vm.readFile(ADDRESS_BOOK);
        c.phUSD = _requireBook(book, "PhUSD");
        c.sUSDS = _requireBook(book, "SUSDS");
        c.antimatter = _requireBook(book, "Antimatter");
        c.router = _requireBook(book, "UniswapV2Router");
        c.phusdSusdsPair = _requireBook(book, "PhusdSusdsPair");
        c.uniPooler = _requireBook(book, "UniPooler");
        c.stableStakerV2 = _requireBook(book, "StableStakerV2");
        c.pauser = _requireBook(book, "Pauser");
        c.factory = IAmCutoverRouter(c.router).factory();
    }

    function _preflight(Config memory c) internal view {
        _code(c.phUSD, "phUSD");
        _code(c.sUSDS, "sUSDS");
        _code(c.antimatter, "Antimatter");
        _code(c.router, "UniswapV2Router");
        _code(c.factory, "UniswapV2Factory");
        _code(c.phusdSusdsPair, "PhusdSusdsPair");
        _code(c.uniPooler, "UniPooler");
        _code(c.stableStakerV2, "StableStakerV2");
        _code(c.pauser, "Pauser");
        require(
            IAmCutoverFactory(c.factory).getPair(c.phUSD, c.sUSDS) == c.phusdSusdsPair,
            "preflight: PhusdSusdsPair is not the factory's canonical phUSD/sUSDS pair"
        );
        require(IAmCutoverPooler(c.uniPooler).owner() == OWNER, "preflight: UniPoolerV2 owner != OWNER");
        require(IAmCutoverAntimatter(c.antimatter).owner() == OWNER, "preflight: Antimatter owner != OWNER");
        // Story 124: OWNER sends every freeze/restore tx (SSV2.setPauser/pause/unpause, Pauser.register/unregister).
        require(IAmCutoverOwned(c.stableStakerV2).owner() == OWNER, "preflight: StableStakerV2 owner != OWNER");
        require(IAmCutoverOwned(c.pauser).owner() == OWNER, "preflight: Pauser owner != OWNER");
    }

    // ---- story 124: SSV2 freeze state + the completed-B on-chain anchor ----

    /// @dev The freeze step's end state: SSV2 paused, its pauser is OWNER, and it is NOT a Pauser registrant (so the
    ///      global `Pauser.pause()`, which loops every registrant with no try/catch, is not bricked by it).
    function _ssv2Frozen(Config memory c) internal view returns (bool) {
        IPausableLike s = IPausableLike(c.stableStakerV2);
        return s.paused() && s.pauser() == OWNER && !IPauserRegistry(c.pauser).isRegistered(c.stableStakerV2);
    }

    /// @dev B's restore end state (and SSV2's normal state): unpaused, `pauser == Pauser`, registered.
    function _ssv2Restored(Config memory c) internal view returns (bool) {
        IPausableLike s = IPausableLike(c.stableStakerV2);
        return !s.paused() && s.pauser() == c.pauser && IPauserRegistry(c.pauser).isRegistered(c.stableStakerV2);
    }

    /// @dev The seed recorded in the progress file is on chain: the AM/sUSDS pair exists, it is the recorded pair, the
    ///      recorded seeder has code, and OWNER holds AT LEAST the recorded liquidity of its LP. Recorded numbers come
    ///      from forge's local pass, so they are only ever compared against chain state, never trusted alone. A pair
    ///      someone else created (dust LP to OWNER) fails the LP floor: under the freeze nobody can hold AM, so nobody
    ///      can mint that much LP (M-02).
    function _seedRecordedOnChain(Config memory c, Progress memory p) internal view returns (bool) {
        address existing = IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS);
        return existing != address(0) && p.seeded && p.amPair == existing && p.seeder != address(0)
            && p.seeder.code.length > 0 && p.liquidity > 0 && IERC20(existing).balanceOf(OWNER) >= p.liquidity;
    }

    /// @dev B has COMPLETED on chain: the seed is recorded on chain, the seeder is no longer an AM minter, and SSV2 is
    ///      restored. Lets the runbook's "A failed -> re-run the combined key" recovery pass through the freeze step
    ///      and B as no-ops instead of re-freezing SSV2 (after which B's supply gate would abort on legitimate AM).
    ///      Note: if OWNER later moves AM/sUSDS LP out, this anchor goes false; never re-run the cutover keys then.
    function _bCompletedOnChain(Config memory c, Progress memory p) internal view returns (bool) {
        return _seedRecordedOnChain(c, p) && !IAmCutoverAntimatter(c.antimatter).isApprovedMinter(p.seeder)
            && _ssv2Restored(c);
    }

    /// @dev Story 084's static registrant sweep: `Pauser.pause()` calls `pause()` on every registrant with no
    ///      try/catch, so ONE registrant that is already paused or whose pauser is not the Pauser bricks the breaker.
    function _requireRegistrantsPausable(Config memory c, string memory prefix) internal view {
        address[] memory registrants = IPauserRegistry(c.pauser).getPausableContracts();
        require(registrants.length > 0, string.concat(prefix, "Pauser has no registrants"));
        for (uint256 i = 0; i < registrants.length; i++) {
            address r = registrants[i];
            require(
                IPausableLike(r).pauser() == c.pauser,
                string.concat(prefix, "Pauser registrant pauser != Pauser (bricks global pause): ", vm.toString(r))
            );
            require(
                !IPausableLike(r).paused(),
                string.concat(prefix, "Pauser registrant already paused (bricks global pause): ", vm.toString(r))
            );
        }
    }

    function _code(address a, string memory name) internal view {
        require(a.code.length > 0, string.concat("preflight: no code at ", name));
    }

    function _checkSeeder(AntimatterPoolSeeder s, Config memory c) internal view {
        require(address(s).code.length > 0, "verify: AntimatterPoolSeeder has no code");
        require(s.owner() == OWNER, "verify: seeder owner != OWNER");
        require(s.phUSD() == c.phUSD, "verify: seeder phUSD mismatch");
        require(s.sUSDS() == c.sUSDS, "verify: seeder sUSDS mismatch");
        require(s.antimatter() == c.antimatter, "verify: seeder antimatter mismatch");
        require(s.router() == c.router, "verify: seeder router mismatch");
        require(s.factory() == c.factory, "verify: seeder factory mismatch");
        require(s.phusdSusdsPair() == c.phusdSusdsPair, "verify: seeder phusdSusdsPair mismatch");
        require(s.lpSource() == c.uniPooler, "verify: seeder lpSource != UniPoolerV2");
    }

    /// @dev The seeder must hold none of the five tokens `seed` touches.
    function _requireSeederEmpty(AntimatterPoolSeeder s, Config memory c, address amPair) internal view {
        address a = address(s);
        require(IERC20(c.phUSD).balanceOf(a) == 0, "end state: seeder holds phUSD");
        require(IERC20(c.antimatter).balanceOf(a) == 0, "end state: seeder holds Antimatter");
        require(IERC20(c.sUSDS).balanceOf(a) == 0, "end state: seeder holds sUSDS");
        require(IERC20(c.phusdSusdsPair).balanceOf(a) == 0, "end state: seeder holds phUSD/sUSDS LP");
        if (amPair != address(0)) require(IERC20(amPair).balanceOf(a) == 0, "end state: seeder holds AM/sUSDS LP");
    }

    function _amReserve(address amPair, address antimatter) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IAmCutoverPair(amPair).getReserves();
        return IAmCutoverPair(amPair).token0() == antimatter ? uint256(r0) : uint256(r1);
    }

    // ---- address book ----

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

    // ---- progress ----

    function _progressFile() internal view virtual returns (string memory) {
        return PROGRESS_FILE;
    }

    function _readProgress() internal view returns (Progress memory p) {
        string memory json;
        try vm.readFile(_progressFile()) returns (string memory j) {
            json = j;
        } catch {
            return p;
        }
        if (bytes(json).length == 0) return p;
        if (vm.keyExistsJson(json, ".contracts.AntimatterPoolSeeder.address")) {
            p.seeder = vm.parseJsonAddress(json, ".contracts.AntimatterPoolSeeder.address");
        }
        if (vm.keyExistsJson(json, ".contracts.AntimatterSusdsPair.address")) {
            p.amPair = vm.parseJsonAddress(json, ".contracts.AntimatterSusdsPair.address");
        }
        if (vm.keyExistsJson(json, ".cutover.lpAmount")) {
            p.lpAmount = vm.parseJsonUint(json, ".cutover.lpAmount");
            p.poolerLpBefore = vm.parseJsonUint(json, ".cutover.poolerLpBefore");
            p.ownerLpBefore = vm.parseJsonUint(json, ".cutover.ownerLpBefore");
        }
        if (vm.keyExistsJson(json, ".cutover.seeded")) p.seeded = vm.parseJsonBool(json, ".cutover.seeded");
        if (p.seeded) {
            p.amMinted = vm.parseJsonUint(json, ".cutover.amMinted");
            p.liquidity = vm.parseJsonUint(json, ".cutover.liquidity");
            p.phusdSupplyBefore = vm.parseJsonUint(json, ".cutover.phusdSupplyBefore");
            p.phusdSupplyAfter = vm.parseJsonUint(json, ".cutover.phusdSupplyAfter");
            p.amSupplyBefore = vm.parseJsonUint(json, ".cutover.amSupplyBefore");
            p.amSupplyAfter = vm.parseJsonUint(json, ".cutover.amSupplyAfter");
            p.amReserve = vm.parseJsonUint(json, ".cutover.amReserve");
            p.poolerLpAfter = vm.parseJsonUint(json, ".cutover.poolerLpAfter");
        }
    }
}

/**
 * @title AntimatterPoolMainnetOps  (story 124)
 * @notice The transaction-sending half shared by Script B, the freeze step and the unfreeze recovery key: the
 *         prank-vs-broadcast switch, the SSV2 freeze and restore triples, and the PREVIEW-ONLY global-pause probe.
 *
 *         THE RULE (CutoverStableStakerV2Mainnet L44-58): never leave a registrant paused or un-pausable by the
 *         Pauser - unregister BEFORE pause, unpause BEFORE register. Two transient one-tx windows are inherent and
 *         accepted (same shape as the SSV2 cutover): between `setPauser(OWNER)` and `Pauser.unregister(SSV2)` the
 *         global `Pauser.pause()` reverts (a registrant whose pauser is OWNER rejects the Pauser); between
 *         `setPauser(Pauser)` and `Pauser.register(SSV2)` a global pause succeeds but misses SSV2.
 */
abstract contract AntimatterPoolMainnetOps is AntimatterPoolMainnetBase, StdCheats {
    uint256 public txCount;
    bool internal isPreview;

    /// @dev Stages at which the simulated EYE-funded `Pauser.pause()` succeeded (preview only; read by tests).
    string[] public globalPauseStagesPassed;

    function globalPauseStageCount() external view returns (uint256) {
        return globalPauseStagesPassed.length;
    }

    /// @dev Freeze SSV2: `setPauser(OWNER)` -> `Pauser.unregister(SSV2)` -> `pause()`, each skipped when done.
    function _freezeSsv2(Config memory c) internal {
        IPausableLike s = IPausableLike(c.stableStakerV2);
        IPauserRegistry reg = IPauserRegistry(c.pauser);
        if (s.pauser() != OWNER) {
            _begin();
            s.setPauser(OWNER);
            _end();
            console.log("  SSV2.setPauser(OWNER) sent");
        } else {
            console.log("  SSV2 pauser already OWNER - skipped");
        }
        if (reg.isRegistered(c.stableStakerV2)) {
            _begin();
            reg.unregister(c.stableStakerV2);
            _end();
            console.log("  Pauser.unregister(SSV2) sent");
        } else {
            console.log("  SSV2 already unregistered from Pauser - skipped");
        }
        if (!s.paused()) {
            _begin();
            s.pause();
            _end();
            console.log("  SSV2.pause() sent");
        } else {
            console.log("  SSV2 already paused - skipped");
        }
        require(_ssv2Frozen(c), "freeze: SSV2 is not paused + pauser OWNER + unregistered after the freeze triple");
    }

    /// @dev Restore SSV2: `unpause()` -> `setPauser(Pauser)` -> `Pauser.register(SSV2)`, each skipped when done.
    function _restoreSsv2(Config memory c) internal {
        IPausableLike s = IPausableLike(c.stableStakerV2);
        IPauserRegistry reg = IPauserRegistry(c.pauser);
        if (s.paused()) {
            _begin();
            s.unpause();
            _end();
            console.log("  SSV2.unpause() sent");
        } else {
            console.log("  SSV2 already unpaused - skipped");
        }
        if (s.pauser() != c.pauser) {
            _begin();
            s.setPauser(c.pauser);
            _end();
            console.log("  SSV2.setPauser(Pauser) sent");
        } else {
            console.log("  SSV2 pauser already Pauser - skipped");
        }
        if (!reg.isRegistered(c.stableStakerV2)) {
            _begin();
            reg.register(c.stableStakerV2);
            _end();
            console.log("  Pauser.register(SSV2) sent");
        } else {
            console.log("  SSV2 already registered with Pauser - skipped");
        }
        require(_ssv2Restored(c), "restore: SSV2 is not unpaused + pauser Pauser + registered after the restore triple");
        _requireRegistrantsPausable(c, "restore: ");
    }

    /// @dev PREVIEW ONLY (deal/prank/snapshot are never used in a broadcast session). Inside a state snapshot, funds a
    ///      throwaway actor with the Pauser's EYE burn amount, calls the permissionless `Pauser.pause()` and requires
    ///      every registrant to report paused, then reverts the snapshot. Pattern of
    ///      `CutoverStableStakerV2Mainnet._assertGlobalPauseWorks`. The caller must not have an active prank.
    function _assertGlobalPauseWorks(Config memory c, string memory stage) internal {
        require(isPreview, "simulated global pause is preview-only");
        IPauserRegistry reg = IPauserRegistry(c.pauser);
        address eye = reg.eyeToken();
        uint256 burn = reg.eyeBurnAmount();
        address[] memory registrants = reg.getPausableContracts();

        uint256 snap = vm.snapshotState();
        address actor = makeAddr("story124-global-pause-actor");
        deal(eye, actor, burn, false);
        bool funded = IERC20(eye).balanceOf(actor) >= burn;
        bool ok;
        bool allPaused;
        if (funded) {
            vm.prank(actor);
            IERC20(eye).approve(c.pauser, burn);
            vm.prank(actor);
            (ok,) = c.pauser.call(abi.encodeWithSignature("pause()"));
            allPaused = ok;
            for (uint256 i = 0; ok && i < registrants.length; i++) {
                if (!IPausableLike(registrants[i]).paused()) {
                    allPaused = false;
                    break;
                }
            }
        }
        vm.revertToState(snap);
        require(funded, "globalPause: could not fund actor with EYE (deal failed)");
        require(
            ok && allPaused, string.concat("globalPause(", stage, "): Pauser.pause() does not pause every registrant")
        );
        globalPauseStagesPassed.push(stage);
        console.log(string.concat("GLOBAL_PAUSE|", stage, "|SUCCEEDED|registered=", vm.toString(registrants.length)));
    }

    function _begin() internal {
        if (isPreview) vm.startPrank(OWNER);
        else vm.startBroadcast(OWNER);
        txCount++;
    }

    function _end() internal {
        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();
    }

    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}

contract CutoverAntimatterPoolMainnet is AntimatterPoolMainnetOps {
    AntimatterPoolSeeder public seeder;
    address public amSusdsPair;
    bool public deployedThisRun;
    bool public seededThisRun;
    bool public rescuedThisRun;
    /// @dev Preview only: freeze txs B's preview pranked itself (they are the freeze step's, not B's, so they are
    ///      NOT in `txCount`).
    uint256 public freezeTxCount;
    /// @dev True when the run found B already completed on chain (`_bCompletedOnChain`).
    bool public completedBeforeRun;
    Progress public progress;

    function run() external {
        console.log("=================================================");
        console.log("  CUTOVER Antimatter/sUSDS pool - MAINNET (story 122, Script B; story 124 freeze)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );

        Config memory c = expectedConfig();
        _preflight(c);
        console.log(
            "Preflight OK: canonical phUSD/sUSDS pair; OWNER owns UniPoolerV2, Antimatter, StableStakerV2, Pauser"
        );

        Progress memory p = _readProgress();
        IAmCutoverAntimatter am = IAmCutoverAntimatter(c.antimatter);

        // ---- Step -1: SSV2 freeze gate (story 124, M-02) ----
        _freezeGate(c, p);

        // ---- Step 0: pair gate, keyed on chain state ----
        console.log("\n=== Step 0: AM/sUSDS pair + AM supply precondition ===");
        address existing = IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS);
        bool seedDone;
        if (existing != address(0)) {
            require(
                _seedRecordedOnChain(c, p),
                "Step 0: the AM/sUSDS pair ALREADY EXISTS and this cutover did not create it - ABORT (griefing risk R1, story 113). Do not seed into a pair someone else created; investigate first."
            );
            seedDone = true;
            console.log(
                "  progress pair exists and OWNER holds >= the recorded LP: seed already done (resume)", existing
            );
        } else {
            console.log("  factory.getPair(AM, sUSDS) == 0: OK");
            uint256 amSupply = IERC20(c.antimatter).totalSupply();
            require(
                amSupply == 0,
                "Step 0 (M-02): Antimatter.totalSupply() != 0 while the AM/sUSDS pair does not exist - AM is in hands outside this cutover, so a dust-LP resume spoof is possible. ABORT before any transaction. SSV2 stays FROZEN: investigate, then the human decides (npm run ssv2-unfreeze-after-cutover-abort:broadcast restores SSV2; see docs/SyaAntimatterMainnetCutover.md)."
            );
            console.log("  Antimatter.totalSupply() == 0: OK (nobody outside the cutover holds AM)");
        }

        // ---- Step 1: seeder ----
        console.log("\n=== Step 1: AntimatterPoolSeeder ===");
        if (p.seeder != address(0)) {
            require(
                p.seeder.code.length > 0,
                "Progress file names an AntimatterPoolSeeder with NO CODE - recorded in forge's local pass but never landed. Delete server/deployments/progress.antimatter-pool.1.json and re-run preview."
            );
            seeder = AntimatterPoolSeeder(p.seeder);
            console.log("  adopted from progress file:", p.seeder);
        } else {
            require(!seedDone, "Step 1: pair seeded but no seeder recorded - STOP");
            _begin();
            seeder = new AntimatterPoolSeeder(
                OWNER, c.phUSD, c.sUSDS, c.antimatter, c.router, c.phusdSusdsPair, c.uniPooler
            );
            _end();
            deployedThisRun = true;
            p.seeder = address(seeder);
            console.log("  deployed:", address(seeder));
        }
        _checkSeeder(seeder, c);

        // ---- Step 2: size the slice (fixed at first sizing, persisted) ----
        console.log("\n=== Step 2: LP slice ===");
        IERC20 lpToken = IERC20(c.phusdSusdsPair);
        if (p.lpAmount == 0) {
            p.poolerLpBefore = lpToken.balanceOf(c.uniPooler);
            p.ownerLpBefore = lpToken.balanceOf(OWNER);
            p.lpAmount = seeder.lpForBps(CUTOVER_BPS);
            require(p.lpAmount > 0, "Step 2: lpForBps(1_000) is zero - UniPoolerV2 holds no LP");
            require(p.lpAmount == p.poolerLpBefore * CUTOVER_BPS / BPS, "Step 2: lpForBps sizing mismatch");
        } else {
            console.log("  slice adopted from progress file");
        }
        console.log("  UniPoolerV2 phUSD/sUSDS LP before:", p.poolerLpBefore);
        console.log("  LP slice (10%):                   ", p.lpAmount);
        console.log("  phUSD/sUSDS LP total supply:      ", IAmCutoverPair(c.phusdSusdsPair).totalSupply());
        _writeProgress(p, "in_progress");

        if (!seedDone) {
            // ---- Step 4: rescue ----
            console.log("\n=== Step 4: UniPoolerV2.rescueERC20(PhusdSusdsPair, OWNER, lp) ===");
            if (lpToken.balanceOf(OWNER) >= p.ownerLpBefore + p.lpAmount) {
                console.log("  OWNER already holds the slice - skipped (resume)");
            } else {
                uint256 poolerAtRescue = lpToken.balanceOf(c.uniPooler);
                require(poolerAtRescue >= p.lpAmount, "Step 4: UniPoolerV2 holds less LP than the slice");
                _begin();
                IAmCutoverPooler(c.uniPooler).rescueERC20(c.phusdSusdsPair, OWNER, p.lpAmount);
                _end();
                require(
                    lpToken.balanceOf(c.uniPooler) == poolerAtRescue - p.lpAmount,
                    "Step 4: UniPoolerV2 LP did not fall by exactly the slice"
                );
                p.poolerLpAfter = lpToken.balanceOf(c.uniPooler);
                rescuedThisRun = true;
            }
            require(lpToken.balanceOf(OWNER) >= p.ownerLpBefore + p.lpAmount, "Step 4: OWNER does not hold the slice");

            // ---- Step 5: approve ----
            console.log("\n=== Step 5: approve seeder ===");
            if (lpToken.allowance(OWNER, address(seeder)) >= p.lpAmount) {
                console.log("  allowance already covers the slice - skipped");
            } else {
                _begin();
                lpToken.approve(address(seeder), p.lpAmount);
                _end();
            }

            // ---- Step 6: grant the AM minter role ----
            console.log("\n=== Step 6: Antimatter.setApprovedMinter(seeder, true) ===");
            if (am.isApprovedMinter(address(seeder))) {
                console.log("  already an approved minter - skipped");
            } else {
                _begin();
                am.setApprovedMinter(address(seeder), true);
                _end();
            }
            require(am.isApprovedMinter(address(seeder)), "Step 6: seeder is not an approved AM minter (silent no-op?)");

            // ---- Steps 3 + 7: floors computed against the pair as it stands right before the seed ----
            console.log("\n=== Steps 3 + 7: floors + seed ===");
            (uint256 minP, uint256 minS, uint256 minSPaired) = _floors(c, p.lpAmount);
            p.phusdSupplyBefore = IERC20(c.phUSD).totalSupply();
            p.amSupplyBefore = IERC20(c.antimatter).totalSupply();
            // A resumed run (rescue landed earlier) records the pooler's LP as it stands now; UniPoolerV2 can
            // gain LP between runs (`pool()`), so the exact "prior minus slice" equality is only asserted when
            // the rescue happened in this run.
            if (!rescuedThisRun) p.poolerLpAfter = lpToken.balanceOf(c.uniPooler);
            // OWNER holds no AM/sUSDS LP before the seed: step 0 saw no pair, and a pair a third party creates in
            // the tx1-tx5 window mints its LP to that third party, not to OWNER (and an AM-cheap one reverts at the
            // minSUSDSPaired floor). Under the SSV2 freeze no third party holds AM to build one with (story 124).
            uint256 ownerAmLpBefore = 0;
            _begin();
            (p.amMinted, p.liquidity) =
                seeder.seed(p.lpAmount, minP, minS, minSPaired, OWNER, block.timestamp + SEED_DEADLINE);
            _end();
            seededThisRun = true;
            p.seeded = true;
            p.phusdSupplyAfter = IERC20(c.phUSD).totalSupply();
            p.amSupplyAfter = IERC20(c.antimatter).totalSupply();
            address pairNow = seeder.amSusdsPair();
            p.amReserve = _amReserve(pairNow, c.antimatter);

            // In-run end state (same simulated block as the seed: exact equalities).
            require(p.amMinted > 0, "end state: seed minted no Antimatter");
            require(
                p.phusdSupplyBefore - p.phusdSupplyAfter == p.amMinted,
                "end state: phUSD supply did not fall by exactly the AM minted"
            );
            require(
                p.amSupplyAfter - p.amSupplyBefore == p.amMinted,
                "end state: AM supply did not rise by exactly the AM minted"
            );
            require(p.amReserve == p.amMinted, "end state: pair AM reserve != AM minted (not fully consumed)");
            if (rescuedThisRun) {
                require(
                    p.poolerLpAfter == p.poolerLpBefore - p.lpAmount,
                    "end state: UniPoolerV2 LP != prior minus the slice"
                );
            }
            require(
                IERC20(pairNow).balanceOf(OWNER) == ownerAmLpBefore + p.liquidity && p.liquidity > 0,
                "end state: OWNER does not hold the AM/sUSDS LP"
            );
            console.log("  floors: minPhUSD", minP);
            console.log("          minSUSDS", minS);
            console.log("          minSUSDSPaired", minSPaired);
            console.log("  AM minted == phUSD burned:", p.amMinted);
            console.log("  AM/sUSDS LP to OWNER:     ", p.liquidity);
            console.log("  UniPoolerV2 LP after:     ", p.poolerLpAfter);
            // Persist the seed record now (broadcast only), so a run that dies before the revoke keeps it.
            p.amPair = pairNow;
            _writeProgress(p, "in_progress");
        }

        // ---- Step 8: revoke (every run that passes steps -1/0) ----
        console.log("\n=== Step 8: Antimatter.setApprovedMinter(seeder, false) (always) ===");
        if (am.isApprovedMinter(address(seeder))) {
            _begin();
            am.setApprovedMinter(address(seeder), false);
            _end();
        } else {
            console.log("  seeder already not a minter");
        }
        require(!am.isApprovedMinter(address(seeder)), "Step 8: seeder AM minter role NOT revoked");

        // ---- Step 9: pair read-back ----
        console.log("\n=== Step 9: pair read-back ===");
        amSusdsPair = seeder.amSusdsPair();
        require(amSusdsPair != address(0), "Step 9: AM/sUSDS pair not created");
        require(
            amSusdsPair == IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS),
            "Step 9: seeder.amSusdsPair() != factory.getPair(AM, sUSDS)"
        );
        require(IERC20(amSusdsPair).balanceOf(OWNER) > 0, "Step 9: OWNER holds no AM/sUSDS LP");
        (uint112 r0, uint112 r1,) = IAmCutoverPair(amSusdsPair).getReserves();
        require(r0 > 0 && r1 > 0, "Step 9: AM/sUSDS reserves are zero");
        _requireSeederEmpty(seeder, c, amSusdsPair);
        p.amPair = amSusdsPair;
        console.log("  AntimatterSusdsPair:", amSusdsPair);
        console.log("  AntimatterPoolSeeder:", address(seeder));
        console.log("  seeder empty, not a minter; OWNER holds the AM/sUSDS LP");

        // ---- Step 10: restore SSV2 (story 124) - B's FINAL transactions ----
        console.log("\n=== Step 10: restore SSV2: unpause -> setPauser(Pauser) -> Pauser.register (always) ===");
        _restoreSsv2(c);
        console.log("  SSV2 unpaused, pauser == Pauser, registered; registrant sweep OK");
        if (isPreview) _assertGlobalPauseWorks(c, "after-restore");
        console.log("Transactions this run:", txCount);

        progress = p;
        _writeProgress(p, "completed");
    }

    /// @dev Step -1. Unless B has already completed on chain, SSV2 must be frozen BEFORE B's local pass reads the AM
    ///      supply. In broadcast the freeze is the separate, already-mined `FreezeStableStakerV2ForCutover` step; the
    ///      preview pranks that same triple itself first (counted in `freezeTxCount`, not `txCount`) and probes the
    ///      global Pauser before the freeze and while frozen.
    function _freezeGate(Config memory c, Progress memory p) internal {
        console.log("\n=== Step -1: StableStakerV2 freeze gate (M-02) ===");
        if (_bCompletedOnChain(c, p)) {
            completedBeforeRun = true;
            console.log(
                "  B already COMPLETED on chain (pair, OWNER LP, minter revoked, SSV2 restored): freeze not required"
            );
            return;
        }
        if (isPreview && !_ssv2Frozen(c)) {
            if (_ssv2Restored(c)) _assertGlobalPauseWorks(c, "before-freeze");
            console.log("  PREVIEW: pranking the freeze step (FreezeStableStakerV2ForCutover) first");
            uint256 before = txCount;
            _freezeSsv2(c);
            freezeTxCount = txCount - before;
            txCount = before;
        }
        require(
            _ssv2Frozen(c),
            "Step -1 (M-02): StableStakerV2 is NOT frozen (need paused + pauser == OWNER + unregistered from Pauser). Run npm run ssv2-freeze-for-cutover:broadcast first - npm run antimatter-pool:broadcast chains it."
        );
        if (isPreview) _assertGlobalPauseWorks(c, "frozen");
        console.log("  SSV2 frozen: paused, pauser == OWNER, not a Pauser registrant");
    }

    /// @dev Pro-rata share of the pair's balances (what `burn` pays) less FLOOR_TOLERANCE_BPS.
    ///      `minSPaired` is the M-01 floor on the sUSDS the seeder pairs with the Antimatter. It equals `minS`
    ///      today (a fresh pair pairs every unit of the unwrapped sUSDS) and is returned separately so the intent
    ///      at the call site is explicit.
    function _floors(Config memory c, uint256 lp)
        internal
        view
        returns (uint256 minP, uint256 minS, uint256 minSPaired)
    {
        uint256 supply = IAmCutoverPair(c.phusdSusdsPair).totalSupply();
        uint256 expP = IERC20(c.phUSD).balanceOf(c.phusdSusdsPair) * lp / supply;
        uint256 expS = IERC20(c.sUSDS).balanceOf(c.phusdSusdsPair) * lp / supply;
        minP = expP * (BPS - FLOOR_TOLERANCE_BPS) / BPS;
        minS = expS * (BPS - FLOOR_TOLERANCE_BPS) / BPS;
        require(minP > 0 && minS > 0, "Step 3: zero unwrap floor");
        minSPaired = minS;
        console.log("  expected phUSD out:", expP);
        console.log("  expected sUSDS out:", expS);
    }

    function _writeProgress(Progress memory p, string memory status) internal {
        if (isPreview) return;
        vm.serializeAddress("s122b.seeder", "address", p.seeder);
        string memory seederEntry = vm.serializeBool("s122b.seeder", "deployed", true);
        vm.serializeString("s122b.contracts", "AntimatterPoolSeeder", seederEntry);
        string memory contracts;
        if (p.amPair != address(0)) {
            vm.serializeAddress("s122b.pair", "address", p.amPair);
            string memory pairEntry = vm.serializeBool("s122b.pair", "deployed", true);
            contracts = vm.serializeString("s122b.contracts", "AntimatterSusdsPair", pairEntry);
        } else {
            contracts = vm.serializeString("s122b.contracts", "AntimatterPoolSeeder", seederEntry);
        }

        vm.serializeUint("s122b.cutover", "bps", CUTOVER_BPS);
        vm.serializeUint("s122b.cutover", "lpAmount", p.lpAmount);
        vm.serializeUint("s122b.cutover", "poolerLpBefore", p.poolerLpBefore);
        vm.serializeUint("s122b.cutover", "ownerLpBefore", p.ownerLpBefore);
        string memory cutover = vm.serializeBool("s122b.cutover", "seeded", p.seeded);
        if (p.seeded) {
            vm.serializeUint("s122b.cutover", "amMinted", p.amMinted);
            vm.serializeUint("s122b.cutover", "liquidity", p.liquidity);
            vm.serializeUint("s122b.cutover", "phusdSupplyBefore", p.phusdSupplyBefore);
            vm.serializeUint("s122b.cutover", "phusdSupplyAfter", p.phusdSupplyAfter);
            vm.serializeUint("s122b.cutover", "amSupplyBefore", p.amSupplyBefore);
            vm.serializeUint("s122b.cutover", "amSupplyAfter", p.amSupplyAfter);
            vm.serializeUint("s122b.cutover", "amReserve", p.amReserve);
            cutover = vm.serializeUint("s122b.cutover", "poolerLpAfter", p.poolerLpAfter);
        }

        vm.serializeUint("s122b.root", "chainId", CHAIN_ID);
        vm.serializeString("s122b.root", "networkName", NETWORK_NAME);
        vm.serializeString("s122b.root", "deploymentStatus", status);
        vm.serializeString("s122b.root", "cutover", cutover);
        string memory json = vm.serializeString("s122b.root", "contracts", contracts);
        vm.writeFile(_progressFile(), json);
        console.log("Progress file written:", _progressFile(), status);
    }
}
