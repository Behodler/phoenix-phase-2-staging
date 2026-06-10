// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";

import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";
import {IFlax as IFlaxStaker} from "flax-token/IFlax.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ResumeStableStakerMigration
 * @notice Story 055 RESUME — finish the MigrateStableStakerMainnet broadcast that halted at tx 21
 *         of 59 (run-latest timestamp 2026-06-10 01:19:13 UTC; txs 1-20 all landed, status 0x1).
 *
 * ROOT CAUSE of the halt: forge executes the script locally to BUILD the tx list, baking the
 * locally-simulated drain balance-deltas into depositAsOwner/approve calldata. The LIVE drains
 * returned slightly less than the simulation predicted (vault-side rounding/yield drift), so the
 * queued DOLA deposit exceeded the owner's real balance and gas estimation reverted with the
 * SafeMath-era "subtraction underflow" from DOLA's transferFrom. Nothing failed on-chain.
 *
 * ALREADY LANDED (do NOT redo):
 *   - Phase A drains: DOLA 13,816.564..., USDC 11,935.645684, USDe 3,760.900... -> owner EOA
 *   - Phase B deploys: new DOLA YS 0x90ce...77F9, new USDC YS 0x90af...2470,
 *     CurveAMMAdapter 0x2d02...5D6F (+ both routes), new USDe market YS 0xaC2e...7f95
 *     (slippage 30 bps), pauser wired + registered on all three.
 *   - Phase C (DOLA only, partial): setClient(minter), registerStablecoin, approveYS, and the
 *     owner's DOLA approve (13,827.86 — MORE than needed, still valid). The deposit itself FAILED.
 *
 * THIS SCRIPT (remainder, with ACTUAL drained amounts hardcoded from the drain receipts'
 * Transfer logs — txs 0x9c7b4a47..., 0xfdde98d4..., 0x96b6daa3...):
 *   C' — per token: (re)wire minter client/config where missing, then depositAsOwner the ACTUAL
 *        received amount. Guarded by principalOf(token, minter) == 0 so a re-run can never
 *        double-deposit.
 *   D  — SYA: add + authorize the 3 new strategies, then remove the 3 old ones (all guarded).
 *   E  — verified no-op (see original script).
 *   F  — deploy + wire StableStaker (pauser, phUSD minter role, 3 pools at DOLA 5 / USDC 7 /
 *        USDe 10 phUSD/day, 10% set-aside buffer). Pass EXISTING_STABLE_STAKER to adopt an
 *        already-deployed instance on a re-run instead of deploying a fresh one.
 *
 * EVERY step is idempotent (state-checked before sending), so this script may be re-run safely
 * if it halts partway again.
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/ResumeStableStakerMigration.s.sol:ResumeStableStakerMigration \
 *     --rpc-url $RPC_MAINNET --slow -vvv
 *
 * Broadcast (ledger):
 *   forge script script/ResumeStableStakerMigration.s.sol:ResumeStableStakerMigration \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 *
 * POST: mainnet-addresses.ts must be patched by hand (patch-mainnet-addresses-stable-staker.js
 * matches 3 positional ERC4626YieldStrategy CREATEs in the ORIGINAL broadcast file — stale on
 * both counts now: USDe is a Market CREATE there, and StableStaker deploys from THIS script).
 */

interface ILiveMinter {
    function owner() external view returns (address);
    function stablecoinConfigs(address stablecoin)
        external
        view
        returns (address yieldStrategy, uint256 exchangeRate, uint8 decimals, bool enabled);
    function registerStablecoin(address stablecoin, address yieldStrategy, uint256 exchangeRate, uint8 decimals)
        external;
    function approveYS(address token, address yieldStrategy) external;
}

interface ILiveSYA {
    function owner() external view returns (address);
    function addYieldStrategy(address strategy, address token) external;
    function removeYieldStrategy(address strategy) external;
    function isRegisteredStrategy(address strategy) external view returns (bool);
}

interface ILivePauser {
    function register(address contractToRegister) external;
    function owner() external view returns (address);
}

interface ILivePhUSD {
    function setMinter(address minter, bool canMint) external;
}

/// @dev principalOf probe on the OLD (live-bytecode) strategies — used to assert the drains landed.
interface ILiveOldYS {
    function principalOf(address token, address account) external view returns (uint256);
}

contract ResumeStableStakerMigration is Script {
    // ============ Live mainnet refs (unchanged from MigrateStableStakerMainnet) ============
    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant PHUSD_STABLE_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;

    address public constant OLD_YS_DOLA = 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78;
    address public constant OLD_YS_USDC = 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952;
    address public constant OLD_YS_USDE = 0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3;

    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    address public constant VAULT_DOLA = 0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d;
    address public constant VAULT_USDC = 0xa7569A44f348d3D70d8ad5889e50F78E33d80D35;
    address public constant VAULT_USDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    // ============ Phase-B deployments that LANDED in the halted run (txs 4-9) ============
    address public constant NEW_YS_DOLA = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant NEW_YS_USDC = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;
    address public constant NEW_YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95; // market, 30 bps
    address public constant USDE_AMM_ADAPTER = 0x2D024e0d03Fb6Ead4F8E7Ba1EBECF6db0E755D6f;

    // ============ ACTUAL drained amounts — Transfer logs of the landed drain txs ============
    // tx 0x9c7b4a47e0d99f2b... (block 25283677): DOLA -> owner
    uint256 public constant RECEIVED_DOLA = 13816564202291221245191;
    // tx 0xfdde98d48c943610... (block 25283681): USDC -> owner
    uint256 public constant RECEIVED_USDC = 11935645684;
    // tx 0x96b6daa30d878f27... (block 25283682): USDe -> owner
    uint256 public constant RECEIVED_USDE = 3760900993410333255682;

    // ============ Safety constants (identical to the original script) ============
    uint256 public constant EXPECTED_RATE = 1e18;
    uint8 public constant DECIMALS_DOLA = 18;
    uint8 public constant DECIMALS_USDC = 6;
    uint8 public constant DECIMALS_USDE = 18;
    uint256 public constant DAILY_USDE = 10e18;
    uint256 public constant DAILY_USDC = 7e18;
    uint256 public constant DAILY_DOLA = 5e18;
    uint256 public constant SETASIDE_BUFFER = 10;
    uint256 public constant USDE_SLIPPAGE_BPS = 30;

    bool public isPreview;
    StableStaker public stableStaker;

    function setUp() public view {
        require(block.chainid == 1, "Wrong chain ID - expected Mainnet (1)");
    }

    function run() external {
        console.log("=========================================");
        console.log("  StableStaker migration RESUME (story 055)");
        console.log("=========================================");

        _preflight();

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, NO broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            console.log("*** BROADCAST MODE - ledger will sign each tx ***");
            vm.startBroadcast();
        }

        _phaseC_resume();
        _phaseD_syaCutover();
        _phaseF_stableStaker();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _printSummary();
    }

    // ============ Pre-flight: assert the world is exactly as the halted run left it ============
    function _preflight() internal view {
        require(ILiveMinter(PHUSD_STABLE_MINTER).owner() == OWNER_ADDRESS, "preflight: minter owner != deployer");
        require(ILiveSYA(SYA).owner() == OWNER_ADDRESS, "preflight: SYA owner != deployer");
        require(ILivePauser(PAUSER).owner() == OWNER_ADDRESS, "preflight: Pauser owner != deployer");

        // The drains really landed: the minter holds zero principal on every OLD strategy.
        require(ILiveOldYS(OLD_YS_DOLA).principalOf(DOLA, PHUSD_STABLE_MINTER) == 0, "preflight: old DOLA not drained");
        require(ILiveOldYS(OLD_YS_USDC).principalOf(USDC, PHUSD_STABLE_MINTER) == 0, "preflight: old USDC not drained");
        require(ILiveOldYS(OLD_YS_USDE).principalOf(USDe, PHUSD_STABLE_MINTER) == 0, "preflight: old USDe not drained");

        // The Phase-B deployments are the expected contracts, correctly configured.
        _checkNewYs(NEW_YS_DOLA, DOLA, VAULT_DOLA);
        _checkNewYs(NEW_YS_USDC, USDC, VAULT_USDC);
        _checkNewYs(NEW_YS_USDE, USDe, VAULT_USDE);
        ERC4626MarketYieldStrategy market = ERC4626MarketYieldStrategy(NEW_YS_USDE);
        require(address(market.ammAdapter()) == USDE_AMM_ADAPTER, "preflight: USDe adapter mismatch");
        require(market.slippageToleranceBps() == USDE_SLIPPAGE_BPS, "preflight: USDe slippage != 30 bps");

        // Daily rates (Configuration Safety: assert the deliberate values, user-confirmed 2026-06-10).
        require(DAILY_USDE == 10e18 && DAILY_USDC == 7e18 && DAILY_DOLA == 5e18, "preflight: daily rate mismatch");

        console.log("Pre-flight OK: drains landed, Phase-B contracts verified.");
    }

    function _checkNewYs(address ys, address token, address vault) internal view {
        AYieldStrategy s = AYieldStrategy(ys);
        require(s.owner() == OWNER_ADDRESS, "preflight: new YS owner != deployer");
        require(address(s.underlyingToken()) == token, "preflight: new YS token mismatch");
        require(s.pauser() == PAUSER, "preflight: new YS pauser not wired");
        // vault() lives on the concrete strategies (both expose it with the same selector).
        require(address(ERC4626MarketYieldStrategy(ys).vault()) == vault, "preflight: new YS vault mismatch");
    }

    // ============ Phase C' — minter cutover + re-deposit (ACTUAL amounts, idempotent) ============
    function _phaseC_resume() internal {
        console.log("=== PHASE C': minter cutover + re-deposit (actual drained amounts) ===");
        _cutoverAndDeposit("DOLA", DOLA, AYieldStrategy(NEW_YS_DOLA), RECEIVED_DOLA, DECIMALS_DOLA);
        _cutoverAndDeposit("USDC", USDC, AYieldStrategy(NEW_YS_USDC), RECEIVED_USDC, DECIMALS_USDC);
        _cutoverAndDeposit("USDe", USDe, AYieldStrategy(NEW_YS_USDE), RECEIVED_USDE, DECIMALS_USDE);
        console.log("");
    }

    function _cutoverAndDeposit(
        string memory label,
        address token,
        AYieldStrategy newYs,
        uint256 received,
        uint8 expectedDecimals
    ) internal {
        ILiveMinter minter = ILiveMinter(PHUSD_STABLE_MINTER);
        console.log("--- resume", label, "---");

        // 1. client authorization on the strategy (skip if the halted run already did it — DOLA).
        if (!newYs.authorizedClients(PHUSD_STABLE_MINTER)) {
            newYs.setClient(PHUSD_STABLE_MINTER, true);
            console.log("  setClient(minter) done");
        } else {
            console.log("  setClient(minter) already set - skipped");
        }

        // 2. minter config: preserve rate/decimals; re-point only if not already on the new YS.
        (address curYs, uint256 rate, uint8 decimals,) = minter.stablecoinConfigs(token);
        require(rate == EXPECTED_RATE, "C': minter exchangeRate != expected (preserve check)");
        require(decimals == expectedDecimals, "C': minter decimals mismatch");
        if (curYs != address(newYs)) {
            minter.registerStablecoin(token, address(newYs), rate, decimals);
            minter.approveYS(token, address(newYs));
            console.log("  registerStablecoin + approveYS done");
        } else {
            console.log("  minter already points at new YS - skipped");
        }

        // 3. deposit the ACTUAL drained amount. principalOf guard makes re-runs unable to
        //    double-deposit; balance check refuses to proceed on any remaining drift.
        uint256 already = newYs.principalOf(token, PHUSD_STABLE_MINTER);
        if (already == 0) {
            require(IERC20(token).balanceOf(OWNER_ADDRESS) >= received, "C': owner balance < drained amount");
            if (IERC20(token).allowance(OWNER_ADDRESS, address(newYs)) < received) {
                IERC20(token).approve(address(newYs), received);
            }
            newYs.depositAsOwner(token, received, PHUSD_STABLE_MINTER);
            console.log("  deposited (actual received):", received);
            console.log("  minter principalOf(new):", newYs.principalOf(token, PHUSD_STABLE_MINTER));
        } else {
            console.log("  principal already deposited - skipped:", already);
        }
    }

    // ============ Phase D — SYA cutover (guarded) ============
    function _phaseD_syaCutover() internal {
        console.log("=== PHASE D: SYA cutover (add new + authorize, then remove old) ===");
        ILiveSYA sya = ILiveSYA(SYA);

        _syaAdd(sya, "DOLA", AYieldStrategy(NEW_YS_DOLA), DOLA);
        _syaAdd(sya, "USDC", AYieldStrategy(NEW_YS_USDC), USDC);
        _syaAdd(sya, "USDe", AYieldStrategy(NEW_YS_USDE), USDe);

        _syaRemove(sya, "DOLA", OLD_YS_DOLA);
        _syaRemove(sya, "USDC", OLD_YS_USDC);
        _syaRemove(sya, "USDe", OLD_YS_USDE);
        console.log("");
    }

    function _syaAdd(ILiveSYA sya, string memory label, AYieldStrategy newYs, address token) internal {
        if (!sya.isRegisteredStrategy(address(newYs))) {
            sya.addYieldStrategy(address(newYs), token);
            console.log("  SYA + new", label, address(newYs));
        } else {
            console.log("  SYA already has new", label, "- skipped");
        }
        newYs.setWithdrawer(SYA, true); // idempotent set
    }

    function _syaRemove(ILiveSYA sya, string memory label, address oldYs) internal {
        if (sya.isRegisteredStrategy(oldYs)) {
            sya.removeYieldStrategy(oldYs);
            console.log("  SYA - old", label, oldYs);
        } else {
            console.log("  SYA old", label, "already removed - skipped");
        }
    }

    // ============ Phase F — StableStaker deploy + wiring (guarded) ============
    function _phaseF_stableStaker() internal {
        console.log("=== PHASE F: deploy + wire StableStaker ===");

        address existing = vm.envOr("EXISTING_STABLE_STAKER", address(0));
        if (existing == address(0)) {
            stableStaker = new StableStaker(IFlaxStaker(PHUSD), OWNER_ADDRESS);
            console.log("  StableStaker deployed:", address(stableStaker));
        } else {
            stableStaker = StableStaker(existing);
            require(stableStaker.owner() == OWNER_ADDRESS, "F: existing staker owner mismatch");
            console.log("  StableStaker adopted (EXISTING_STABLE_STAKER):", existing);
        }

        if (stableStaker.pauser() != PAUSER) {
            stableStaker.setPauser(PAUSER);
            ILivePauser(PAUSER).register(address(stableStaker));
            console.log("  pauser set + registered");
        }

        // idempotent on the live phUSD (setMinter(_, true) twice is a no-op state-wise).
        ILivePhUSD(PHUSD).setMinter(address(stableStaker), true);

        _wirePool("DOLA", DOLA, AYieldStrategy(NEW_YS_DOLA), DAILY_DOLA);
        _wirePool("USDC", USDC, AYieldStrategy(NEW_YS_USDC), DAILY_USDC);
        _wirePool("USDe", USDe, AYieldStrategy(NEW_YS_USDE), DAILY_USDE);
        console.log("");
    }

    function _wirePool(string memory label, address token, AYieldStrategy newYs, uint256 dailyRate) internal {
        if (!_hasToken(token)) {
            stableStaker.addToken(token);
        }
        newYs.setClient(address(stableStaker), true); // idempotent
        if (address(stableStaker.yieldStrategy(token)) != address(newYs)) {
            stableStaker.setYieldStrategy(token, IYieldStrategy(address(newYs)));
        }
        newYs.setSetAsideBuffer(address(stableStaker), SETASIDE_BUFFER); // idempotent
        stableStaker.phUSDPerDay(token, dailyRate); // idempotent (sets the same rate)
        console.log("--- StableStaker pool wired", label, "---");
        console.log("  phUSD/day:", dailyRate);
        console.log("  set-aside buffer (strategy):", newYs.setAsideBufferSize(address(stableStaker)));
    }

    function _hasToken(address token) internal view returns (bool) {
        address[] memory toks = stableStaker.getStakedTokens();
        for (uint256 i = 0; i < toks.length; i++) {
            if (toks[i] == token) return true;
        }
        return false;
    }

    // ============ Summary ============
    function _printSummary() internal view {
        console.log("=========================================");
        console.log("  RESUME SUMMARY (story 055)");
        console.log("=========================================");
        console.log("New YieldStrategy DOLA:", NEW_YS_DOLA);
        console.log("New YieldStrategy USDC:", NEW_YS_USDC);
        console.log("New YieldStrategy USDe:", NEW_YS_USDE, "(market, 30 bps)");
        console.log("StableStaker:          ", address(stableStaker));
        console.log("Deposited DOLA:", RECEIVED_DOLA);
        console.log("Deposited USDC:", RECEIVED_USDC);
        console.log("Deposited USDe:", RECEIVED_USDE);
        if (isPreview) {
            console.log("PREVIEW complete. No state changed on-chain.");
        } else {
            console.log("BROADCAST complete. Patch mainnet-addresses.ts BY HAND (see header).");
        }
        console.log("=========================================");
    }
}
