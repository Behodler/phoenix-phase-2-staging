// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";

interface IAmCutoverPooler {
    function rescueERC20(address token, address to, uint256 amount) external;
    function owner() external view returns (address);
}

interface IAmCutoverAntimatter {
    function setApprovedMinter(address minter, bool approved) external;
    function isApprovedMinter(address minter) external view returns (bool);
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
 * @title CutoverAntimatterPoolMainnet  (story 122, Script B, sprint sya-antimatter-cutover)
 * @notice The mainnet Antimatter/sUSDS cutover, mirroring DeployMocks Phase 11.10 `_rehearseAntimatterPoolCutover`
 *         (story 114) with `CUTOVER_BPS = 1_000` (10%) instead of the anvil 50%:
 *           0. precondition: `factory.getPair(AM, sUSDS) == 0` - an existing pair ABORTS (griefing risk R1, story 113);
 *           1. deploy `AntimatterPoolSeeder(OWNER, phUSD, sUSDS, Antimatter, Router02, PhusdSusdsPair, UniPoolerV2)`;
 *           2. `lp = seeder.lpForBps(1_000)`;
 *           3. floors: pro-rata unwrap amounts minus 0.1% (`_amCutoverMins`);
 *           4. `UniPoolerV2.rescueERC20(PhusdSusdsPair, OWNER, lp)`;
 *           5. `PhusdSusdsPair.approve(seeder, lp)`;
 *           6. `Antimatter.setApprovedMinter(seeder, true)` + require (the setter is a silent no-op on no change);
 *           7. `seeder.seed(lp, minPhUSD, minSUSDS, OWNER, now + 1h)`;
 *           8. `Antimatter.setApprovedMinter(seeder, false)` + require - ALWAYS runs, including on resume;
 *           9. `amSusdsPair = seeder.amSusdsPair()` == `factory.getPair(AM, sUSDS)`; both written to the progress file.
 *
 *         F3 (story 113): the seeder's AM/sUSDS add passes `amountBMin = 0`. Acceptable ONLY because step 0
 *         guarantees the pair is created fresh inside the seed transaction, so there is no price to manipulate.
 *         R1: someone could create the pair first. Step 0 refuses to seed into it; the runbook recommends a
 *         private RPC (Flashbots Protect) for the broadcast.
 *
 *         RESUMABLE (progress file `server/deployments/progress.antimatter-pool.1.json`). The LP slice `lp` is
 *         fixed at first sizing and persisted, because `lpForBps` reads the pooler's LIVE balance, which the rescue
 *         itself shrinks. Gates read chain state: rescue done when OWNER holds `ownerLpBefore + lp`; approval done
 *         when the allowance covers `lp`; grant done when `isApprovedMinter`; seed done when the pair exists AND
 *         OWNER holds its LP. If a run dies after step 4 the LP sits safely on OWNER and the resume continues at 5.
 *
 *         END STATE (asserted in-run, in the same simulated block as the seed, and recorded for the verifier):
 *         phUSD supply fell by exactly the AM minted; AM supply rose by the same; the pair's AM reserve equals it;
 *         UniPoolerV2 holds its prior LP minus `lp`; the seeder holds nothing; the seeder is not an AM minter;
 *         OWNER holds the AM/sUSDS LP.
 *
 * Preview:   npm run antimatter-pool:preview     (PREVIEW_MODE=true, OWNER prank on a fork, nothing signed or written)
 * Broadcast: npm run antimatter-pool:broadcast   (backup -> Ledger -> patcher -> :verify -> ledger). Prefer a private RPC.
 * Verify:    npm run antimatter-pool:verify      (read-only, script/VerifyAntimatterPoolCutover.s.sol)
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
        require(
            IAmCutoverFactory(c.factory).getPair(c.phUSD, c.sUSDS) == c.phusdSusdsPair,
            "preflight: PhusdSusdsPair is not the factory's canonical phUSD/sUSDS pair"
        );
        require(IAmCutoverPooler(c.uniPooler).owner() == OWNER, "preflight: UniPoolerV2 owner != OWNER");
        require(IAmCutoverAntimatter(c.antimatter).owner() == OWNER, "preflight: Antimatter owner != OWNER");
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

contract CutoverAntimatterPoolMainnet is AntimatterPoolMainnetBase {
    AntimatterPoolSeeder public seeder;
    address public amSusdsPair;
    bool public deployedThisRun;
    bool public seededThisRun;
    bool public rescuedThisRun;
    uint256 public txCount;
    Progress public progress;

    bool internal isPreview;

    function run() external {
        console.log("=================================================");
        console.log("  CUTOVER Antimatter/sUSDS pool - MAINNET (story 122, Script B)");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");
        isPreview = _previewModeFromEnv();
        console.log(
            isPreview ? "Mode: PREVIEW (OWNER prank, nothing signed, no progress written)" : "Mode: BROADCAST (Ledger)"
        );

        Config memory c = expectedConfig();
        _preflight(c);
        console.log("Preflight OK: canonical phUSD/sUSDS pair; OWNER owns UniPoolerV2 and Antimatter");

        Progress memory p = _readProgress();
        IAmCutoverAntimatter am = IAmCutoverAntimatter(c.antimatter);

        // ---- Step 0: the AM/sUSDS pair must not exist, unless THIS cutover created it ----
        console.log("\n=== Step 0: AM/sUSDS pair precondition ===");
        address existing = IAmCutoverFactory(c.factory).getPair(c.antimatter, c.sUSDS);
        bool seedDone;
        if (existing != address(0)) {
            require(
                p.seeder != address(0) && p.seeder.code.length > 0 && IERC20(existing).balanceOf(OWNER) > 0,
                "Step 0: the AM/sUSDS pair ALREADY EXISTS and this cutover did not create it - ABORT (griefing risk R1, story 113). Do not seed into a pair someone else created; investigate first."
            );
            seedDone = true;
            console.log("  pair exists and OWNER holds its LP: seed already done (resume)", existing);
        } else {
            console.log("  factory.getPair(AM, sUSDS) == 0: OK");
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
            (uint256 minP, uint256 minS) = _floors(c, p.lpAmount);
            p.phusdSupplyBefore = IERC20(c.phUSD).totalSupply();
            p.amSupplyBefore = IERC20(c.antimatter).totalSupply();
            // A resumed run (rescue landed earlier) records the pooler's LP as it stands now; UniPoolerV2 can
            // gain LP between runs (`pool()`), so the exact "prior minus slice" equality is only asserted when
            // the rescue happened in this run.
            if (!rescuedThisRun) p.poolerLpAfter = lpToken.balanceOf(c.uniPooler);
            uint256 ownerAmLpBefore = 0; // the pair does not exist yet (step 0)
            _begin();
            (p.amMinted, p.liquidity) = seeder.seed(p.lpAmount, minP, minS, OWNER, block.timestamp + SEED_DEADLINE);
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
            console.log("  AM minted == phUSD burned:", p.amMinted);
            console.log("  AM/sUSDS LP to OWNER:     ", p.liquidity);
            console.log("  UniPoolerV2 LP after:     ", p.poolerLpAfter);
            // Persist the seed record now (broadcast only), so a run that dies before the revoke keeps it.
            p.amPair = pairNow;
            _writeProgress(p, "in_progress");
        }

        // ---- Step 8: revoke (ALWAYS) ----
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
        console.log("Transactions this run:", txCount);

        progress = p;
        _writeProgress(p, "completed");
    }

    /// @dev Pro-rata share of the pair's balances (what `burn` pays) less FLOOR_TOLERANCE_BPS.
    function _floors(Config memory c, uint256 lp) internal view returns (uint256 minP, uint256 minS) {
        uint256 supply = IAmCutoverPair(c.phusdSusdsPair).totalSupply();
        uint256 expP = IERC20(c.phUSD).balanceOf(c.phusdSusdsPair) * lp / supply;
        uint256 expS = IERC20(c.sUSDS).balanceOf(c.phusdSusdsPair) * lp / supply;
        minP = expP * (BPS - FLOOR_TOLERANCE_BPS) / BPS;
        minS = expS * (BPS - FLOOR_TOLERANCE_BPS) / BPS;
        require(minP > 0 && minS > 0, "Step 3: zero unwrap floor");
        console.log("  expected phUSD out:", expP);
        console.log("  expected sUSDS out:", expS);
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

    function _previewModeFromEnv() internal view virtual returns (bool) {
        return vm.envOr("PREVIEW_MODE", false);
    }
}
