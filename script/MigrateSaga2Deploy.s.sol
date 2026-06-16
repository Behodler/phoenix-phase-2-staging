// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {InPlaceMigrator} from "stable-staker/InPlaceMigrator.sol";
import {IStableStaker} from "stable-staker/interfaces/IStableStaker.sol";
import {
    ERC4626YieldStrategy
} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";

/*//////////////////////////////////////////////////////////////////////////////
                          MIGRATE SAGA 2 — STEP 2.1 (DEPLOY & FREEZE)
//////////////////////////////////////////////////////////////////////////////

Saga 2 replaces the abandoned temp-staker "ys-swap" saga with the simpler InPlaceMigrator
route. See docs/stable-staker-migrations/combined-inplace-and-minter-v2-migration-plan.md.

This is the deploy/freeze leg (Script 2.1). It deploys everything, wires it, freezes minter V1,
and records the V1 positions — but it DRAINS NOTHING. It can be run any time before the migrate
leg (2.2). Steps performed (all as the owner EOA):

  1. Deploy InPlaceMigrator(staker, 2 weeks, owner).
  2. Fund the migrator's in-place allotment by transferring hardcoded DOLA/USDC from the deployer
     (see ALLOTMENT TRIPWIRE below — reverts loudly until the amounts are set > 0).
  3. Deploy new fixed ERC4626YieldStrategy for DOLA (autoDOLA) and USDC (autoUSDC).
  4. Deploy phUSD minter V2.
  5. Wire the new strategies: setClient(staker), setClient(minterV2), setWithdrawer(accumulator).
  6. Wire V2 for USDe (dormant-client carry-over): setClient(minterV2) on the USDe market YS,
     register USDe on V2. Leave minter V1 authorized on the USDe market YS (dormant).
  7. Register DOLA/USDC on V2 against the NEW strategies, replicating V1's exchange-rate/decimals,
     with maxMintPerDay = 4000 phUSD each (USDe too).
  8. phUSD: revoke minter V1, grant minter V2.
  9. staker.setMigrator(inPlaceMigrator).
 10. Record V1 DOLA/USDC positions and persist deploy addresses to migration-inputs JSON.

NOTE on set-aside buffer: TWO cushions are in play. (1) The skimmed surplus is transferred to the
staker in 2.2 (raw idle balance == buffer). (2) The strategy-level set-aside withholding is set
at 10% for the staker client here (step 5a), with the buffer recipient = the stable-staker (the old
strategies are NOT touched — their bytecode predates the global-recipient feature).
*/

contract MigrateSaga2Deploy is Script {
    using SafeERC20 for IERC20;

    // ───────────────────────────── ALLOTMENT TRIPWIRE ─────────────────────────────
    // In-place allotment: the owner pre-funds the migrator with DOLA/USDC so that if migrateOut
    // realizes any slippage/haircut, the migrator can top the parked users up to par (forthcoming
    // InPlaceMigrator feature). HARDCODED TO ZERO ON PURPOSE — set both > 0 before running, or the
    // require at the top of run() reverts loudly to remind you. Amounts are in token-native decimals
    // (DOLA = 18, USDC = 6).
    uint256 public constant DOLA_ALLOTMENT = 27000000000000000000; // <-- SET ME (18 decimals) before running
    uint256 public constant USDC_ALLOTMENT = 27000000; // <-- SET ME (6 decimals) before running

    // ───────────────────────────── CONFIG ─────────────────────────────
    uint256 public constant CHAIN_ID = 1;
    uint256 public constant MIGRATION_TIMEOUT = 14 days; // operator-confirmed; bounds [1d, 30d]
    uint256 public constant MAX_MINT_PER_DAY = 4000e18; // operator-confirmed cap, phUSD (18 dec), each token
    uint256 public constant SETASIDE_BUFFER_PCT = 10; // operator-confirmed: carry forward the existing 10%

    // Live mainnet addresses (verify against server/deployments/mainnet-addresses.ts).
    address public constant OWNER_ADDRESS =
        0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant MINTER_V1 =
        0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant ACCUMULATOR =
        0x3C690EC3B2524104dE269bf0F9baa7f045eF8270;
    address public constant USDE_MARKET_YS =
        0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3; // global Pauser

    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant AUTO_DOLA =
        0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant AUTO_USDC =
        0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    string public constant DEPLOYMENTS_JSON =
        "script/migration-inputs/saga2-deployments.json";

    bool public isPreview;

    // deployed
    InPlaceMigrator public migrator;
    ERC4626YieldStrategy public ysDolaV2;
    ERC4626YieldStrategy public ysUsdcV2;
    PhusdStableMinter public minterV2;

    function setUp() public view {
        require(
            block.chainid == CHAIN_ID,
            "saga2.1: wrong chain - expected mainnet (1)"
        );
    }

    function run() external {
        // ── ALLOTMENT TRIPWIRE: refuse to run until the allotment amounts are deliberately set. ──
        require(
            DOLA_ALLOTMENT > 0 && USDC_ALLOTMENT > 0,
            "saga2.1: set DOLA_ALLOTMENT and USDC_ALLOTMENT (> 0) before running"
        );

        isPreview = vm.envOr("PREVIEW_MODE", false);
        _preflight();

        if (isPreview) {
            console.log(
                "*** PREVIEW MODE - impersonating owner, NO broadcast ***"
            );
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE ***");
            vm.startBroadcast();
        }

        // 1. Deploy migrator (owner = the operator EOA).
        migrator = new InPlaceMigrator(
            IStableStaker(STAKER),
            MIGRATION_TIMEOUT,
            OWNER_ADDRESS
        );
        console.log("InPlaceMigrator:", address(migrator));

        // 2. Fund the in-place allotment from the deployer.
        IERC20(DOLA).safeTransfer(address(migrator), DOLA_ALLOTMENT);
        IERC20(USDC).safeTransfer(address(migrator), USDC_ALLOTMENT);
        console.log(
            "Allotment funded - DOLA:",
            DOLA_ALLOTMENT,
            "USDC:",
            USDC_ALLOTMENT
        );

        // 3. Deploy new fixed strategies (owner = operator EOA).
        ysDolaV2 = new ERC4626YieldStrategy(OWNER_ADDRESS, DOLA, AUTO_DOLA);
        ysUsdcV2 = new ERC4626YieldStrategy(OWNER_ADDRESS, USDC, AUTO_USDC);
        console.log("ysDolaV2:", address(ysDolaV2));
        console.log("ysUsdcV2:", address(ysUsdcV2));

        // 4. Deploy minter V2.
        minterV2 = new PhusdStableMinter(PHUSD);
        console.log("minterV2:", address(minterV2));

        // 5. Wire the new strategies: staker (for migrateIn re-deposit), minterV2 (for noMintDeposit
        //    and live mints), accumulator (authorized withdrawer for future skimSurplus).
        ysDolaV2.setClient(STAKER, true);
        ysDolaV2.setClient(address(minterV2), true);
        ysDolaV2.setWithdrawer(ACCUMULATOR, true);
        ysUsdcV2.setClient(STAKER, true);
        ysUsdcV2.setClient(address(minterV2), true);
        ysUsdcV2.setWithdrawer(ACCUMULATOR, true);

        // 5a. Set the staker's set-aside buffer (operator-confirmed 10%): on each skim this % of the
        //     staker's surplus is withheld to the buffer recipient as a below-par reserve. The recipient
        //     is ALWAYS the stable-staker (withheld buffer flows back to it as idle balance == buffer).
        //     Do NOT read the old strategies — their deployed bytecode predates the global-recipient
        //     feature (it returns the buffer to the skimmed client) and lacks setAsideBufferRecipient().
        _setBuffer(ysDolaV2);
        _setBuffer(ysUsdcV2);

        // 5b. Wire the global Pauser (protocol compliance): authorize it to pause the new strategies
        //     and register them in the Pauser's contract set, mirroring the canonical ReplaceSYAMainnet
        //     wiring. A fresh strategy deploys with an unset pauser (address(0)) and would otherwise be
        //     uncontrollable by the protocol pause path.
        ysDolaV2.setPauser(PAUSER);
        ysUsdcV2.setPauser(PAUSER);
        IPauserAdmin(PAUSER).register(address(ysDolaV2));
        IPauserAdmin(PAUSER).register(address(ysUsdcV2));

        // 6. USDe: add minterV2 as a third client on the existing market strategy (minter V1 stays
        //    authorized as a dormant yield client). Register USDe on V2 against the SAME market YS.
        IYS(USDE_MARKET_YS).setClient(address(minterV2), true);
        _registerOnV2(USDE, USDE_MARKET_YS);

        // 7. Register DOLA/USDC on V2 against the new strategies.
        _registerOnV2(DOLA, address(ysDolaV2));
        _registerOnV2(USDC, address(ysUsdcV2));

        // 7a. Wire V2's global Pauser BEFORE granting it mint authority (step 8). minterV2 is IPausable
        //     and is the one contract that can mint phUSD against user deposits — a fresh deploy leaves
        //     pauser == address(0), i.e. no emergency stop. Mirror the strategy wiring: setPauser +
        //     register in the Pauser's contract set.
        minterV2.setPauser(PAUSER);
        IPauserAdmin(PAUSER).register(address(minterV2));
        require(
            minterV2.pauser() != address(0),
            "saga2.1: minterV2 pauser unset"
        );

        // 8. phUSD mint authority: revoke V1 (freeze its liability), grant V2.
        IFlax(PHUSD).setMinter(MINTER_V1, false);
        IFlax(PHUSD).setMinter(address(minterV2), true);
        console.log("phUSD minter: V1 revoked, V2 granted");

        // 9. Point the staker at the in-place migrator (stays set across 2.2's out+in legs).
        IStaker(STAKER).setMigrator(address(migrator));

        // 10. Record V1 positions (for the post-mortem ledger; 2.2 does NOT require recovered == this).
        uint256 v1DolaPrincipal = IYS(_v1Strategy(DOLA)).principalOf(
            DOLA,
            MINTER_V1
        );
        uint256 v1UsdcPrincipal = IYS(_v1Strategy(USDC)).principalOf(
            USDC,
            MINTER_V1
        );
        console.log("V1 DOLA principal:", v1DolaPrincipal);
        console.log("V1 USDC principal:", v1UsdcPrincipal);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
            _writeDeployments(v1DolaPrincipal, v1UsdcPrincipal);
        }

        _postAssert();
        _printSummary();
    }

    // Reads-only verification that every set/wire actually took effect (no more txs). Mirrors the
    // post-assert blocks in 2.2/2.3 — logging alone is not proof.
    function _postAssert() internal view {
        // New strategies: clients, withdrawer, pauser+registry, set-aside buffer.
        _assertStrategyWired(ysDolaV2);
        _assertStrategyWired(ysUsdcV2);

        // USDe market YS: minterV2 added as a client (V1 stays a dormant client; not asserted here).
        require(
            IYS(USDE_MARKET_YS).authorizedClients(address(minterV2)),
            "post: minterV2 not USDe client"
        );

        // minterV2 registrations (strategy mapping, cap, rate == V1) + its own pauser wiring.
        _assertMinterRegistered(DOLA, address(ysDolaV2));
        _assertMinterRegistered(USDC, address(ysUsdcV2));
        _assertMinterRegistered(USDE, USDE_MARKET_YS);
        require(minterV2.pauser() == PAUSER, "post: minterV2 pauser != PAUSER");
        require(
            IPauserAdmin(PAUSER).isRegistered(address(minterV2)),
            "post: minterV2 not in Pauser registry"
        );

        // phUSD mint authority: V2 is a CURRENT-version minter, V1 revoked.
        (bool v2CanMint, uint256 v2Ver) = IFlax(PHUSD).authorizedMinters(
            address(minterV2)
        );
        require(
            v2CanMint && v2Ver == IFlax(PHUSD).mintVersion(),
            "post: minterV2 not a current minter"
        );
        (bool v1CanMint, ) = IFlax(PHUSD).authorizedMinters(MINTER_V1);
        require(!v1CanMint, "post: minterV1 mint not revoked");

        // Migrator wired on the staker; allotment actually funded into the migrator.
        require(
            IStaker(STAKER).migrator() == address(migrator),
            "post: migrator not set on staker"
        );
        require(
            IERC20(DOLA).balanceOf(address(migrator)) >= DOLA_ALLOTMENT,
            "post: DOLA allotment not funded"
        );
        require(
            IERC20(USDC).balanceOf(address(migrator)) >= USDC_ALLOTMENT,
            "post: USDC allotment not funded"
        );

        console.log("saga 2.1 post-asserts passed");
    }

    function _assertStrategyWired(ERC4626YieldStrategy ys) internal view {
        require(
            ys.authorizedClients(STAKER),
            "post: staker not strategy client"
        );
        require(
            ys.authorizedClients(address(minterV2)),
            "post: minterV2 not strategy client"
        );
        require(
            ys.authorizedWithdrawers(ACCUMULATOR),
            "post: accumulator not withdrawer"
        );
        require(ys.pauser() == PAUSER, "post: strategy pauser != PAUSER");
        require(
            IPauserAdmin(PAUSER).isRegistered(address(ys)),
            "post: strategy not in Pauser registry"
        );
        require(
            ys.setAsideBufferSize(STAKER) == SETASIDE_BUFFER_PCT,
            "post: strategy buffer != 10"
        );
        require(
            ys.setAsideBufferRecipient() == STAKER,
            "post: strategy buffer recipient != staker"
        );
    }

    function _assertMinterRegistered(
        address token,
        address expectedYS
    ) internal view {
        PhusdStableMinter.StablecoinConfig memory c = minterV2
            .getStablecoinConfig(token);
        require(
            c.yieldStrategy == expectedYS,
            "post: minter strategy mismatch"
        );
        require(
            c.maxMintPerDay == MAX_MINT_PER_DAY,
            "post: minter cap mismatch"
        );
        (, uint256 v1Rate, , ) = IMinterV1(MINTER_V1).stablecoinConfigs(token);
        require(
            c.exchangeRate == v1Rate && c.exchangeRate > 0,
            "post: minter rate != V1"
        );
    }

    // Register `token` on V2 against `strategy`, replicating V1's exchange rate + decimals, and apply
    // the 4000/day cap. Approve the strategy so V2 can deposit.
    function _registerOnV2(address token, address strategy) internal {
        (, uint256 rate, uint8 dec, ) = IMinterV1(MINTER_V1).stablecoinConfigs(
            token
        );
        require(
            rate > 0,
            "saga2.1: V1 exchangeRate is zero - cannot replicate config"
        );
        minterV2.registerStablecoin(token, strategy, rate, dec);
        minterV2.approveYS(token, strategy);
        minterV2.setMaxMintPerDay(token, MAX_MINT_PER_DAY);
        console.log("V2 registered token (rate, dec):", token);
        console.log("   rate:", rate, "dec:", dec);
    }

    // Set the set-aside buffer on `newYS`: recipient AND buffered client are both the stable-staker.
    function _setBuffer(ERC4626YieldStrategy newYS) internal {
        newYS.setSetAsideBufferRecipient(STAKER);
        newYS.setSetAsideBuffer(STAKER, SETASIDE_BUFFER_PCT);
    }

    function _v1Strategy(address token) internal view returns (address ys) {
        (ys, , , ) = IMinterV1(MINTER_V1).stablecoinConfigs(token);
        require(ys != address(0), "saga2.1: V1 strategy unset for token");
    }

    function _preflight() internal view {
        // Owner must hold enough DOLA/USDC for the allotment funding.
        require(
            IERC20(DOLA).balanceOf(OWNER_ADDRESS) >= DOLA_ALLOTMENT,
            "saga2.1 preflight: owner DOLA balance < DOLA_ALLOTMENT"
        );
        require(
            IERC20(USDC).balanceOf(OWNER_ADDRESS) >= USDC_ALLOTMENT,
            "saga2.1 preflight: owner USDC balance < USDC_ALLOTMENT"
        );
        // Owner must control the contracts whose owner-only setters we call.
        require(
            IStaker(STAKER).owner() == OWNER_ADDRESS,
            "saga2.1 preflight: not staker owner"
        );
        // Pauser.register is onlyOwner on the Pauser — the deployer must own it.
        require(
            IPauserAdmin(PAUSER).owner() == OWNER_ADDRESS,
            "saga2.1 preflight: not Pauser owner"
        );
    }

    function _writeDeployments(
        uint256 v1DolaPrincipal,
        uint256 v1UsdcPrincipal
    ) internal {
        string memory json = string.concat(
            "{\n",
            '  "migrator": "',
            vm.toString(address(migrator)),
            '",\n',
            '  "ysDolaV2": "',
            vm.toString(address(ysDolaV2)),
            '",\n',
            '  "ysUsdcV2": "',
            vm.toString(address(ysUsdcV2)),
            '",\n',
            '  "minterV2": "',
            vm.toString(address(minterV2)),
            '",\n',
            '  "v1DolaPrincipal": "',
            vm.toString(v1DolaPrincipal),
            '",\n',
            '  "v1UsdcPrincipal": "',
            vm.toString(v1UsdcPrincipal),
            '",\n',
            '  "timestamp": ',
            vm.toString(block.timestamp),
            "\n",
            "}\n"
        );
        vm.writeFile(DEPLOYMENTS_JSON, json);
        console.log("Wrote", DEPLOYMENTS_JSON);
    }

    function _printSummary() internal view {
        console.log("==========================================");
        console.log("  SAGA 2.1 (deploy & freeze) complete");
        console.log("==========================================");
        if (isPreview) {
            console.log(
                "PREVIEW - no on-chain state changed, no JSON written."
            );
        } else {
            console.log(
                "BROADCAST done. Patcher updates mainnet-addresses.ts. Proceed to saga 2.2."
            );
        }
    }
}

// ───────────────────────────── minimal interfaces ─────────────────────────────

interface IStaker {
    function owner() external view returns (address);
    function setMigrator(address) external;
    function migrator() external view returns (address);
}

interface IYS {
    function principalOf(
        address token,
        address account
    ) external view returns (uint256);
    function setClient(address client, bool auth) external;
    function authorizedClients(address client) external view returns (bool);
}

interface IFlax {
    function setMinter(address account, bool isMinter) external;
    function authorizedMinters(
        address minter
    ) external view returns (bool canMint, uint256 mintVersion);
    function mintVersion() external view returns (uint256);
}

interface IPauserAdmin {
    function owner() external view returns (address);
    function register(address pausableContract) external;
    function isRegistered(
        address pausableContract
    ) external view returns (bool);
}

interface IMinterV1 {
    // NOTE: the LIVE minter V1 (0x435B...) predates the rolling-cap feature — its stablecoinConfigs
    // getter returns only 4 fields. Do NOT use the current 7-field source ABI here; decoding 7 from a
    // 4-field return reverts.
    function stablecoinConfigs(
        address token
    )
        external
        view
        returns (
            address yieldStrategy,
            uint256 exchangeRate,
            uint8 decimals,
            bool enabled
        );
}
