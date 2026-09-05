// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";

/**
 * @title ReplaceSYAMainnet
 * @notice Replaces the live StableYieldAccumulator with a build compatible with the
 *         story-055 yield strategies, rewiring every dependency, and deactivates the old one.
 *
 * WHY (diagnosed 2026-06-10): the live SYA (0x3bbe…7606a) is a pre-story-025 build.
 *   - Its claim() withdraws via IYieldStrategy.withdrawFrom(token, minterAddress, yield, claimer),
 *     a function the story-055 strategies no longer have (replaced by skimSurplus) — so every
 *     claim() reverts on the first strategy with yield, regardless of USDC supplied.
 *   - Its getYield() reads only the phUSD minter's surplus, silently omitting StableStaker yield.
 * The current lib/stable-yield-accumulator (story-025, commit a9b21fd) claims via
 * skimSurplus(token, claimer), which batch-sweeps the surplus of ALL authorized clients
 * (minter + StableStaker) and aggregates getYield() across all clients.
 *
 * FULL WIRING (everything the old SYA touches, verified on-chain 2026-06-10):
 *   New SYA config (values replicated from the live old SYA unless noted):
 *     1.  deploy StableYieldAccumulator              (owner = broadcast signer)
 *     2.  setRewardToken(USDC)
 *     3.  setPhlimbo(PhlimboV2 0x6084…AeE0)
 *     4.  approvePhlimbo(max)                        (collectReward pulls USDC via transferFrom)
 *     5.  setNFTMinter(NFTMinterV2 0x39Af…E10F)      (claim() burn gate)
 *     6.  setNudgeAddress(BatchNFTMinter 0x8686…029d)
 *     7.  setNudgeSplit(20)                          (USER-SPECIFIED 2026-06-10: 20% of claim
 *                                                     payment to nudge pot, rest to Phlimbo;
 *                                                     old SYA had 30)
 *     8.  setPauser(Pauser 0x7c5A…85a3)
 *     9.  setTokenConfig: DOLA 18/1e18, USDe 18/1e18, USDC 6/1e18
 *     10. addYieldStrategy ×3 (DOLA / USDe / USDC story-055 strategies)
 *     11. setDiscountRate(3000)                      (replicated from live old SYA — claimer
 *                                                     pays 70% of skimmed yield value)
 *   Strategy-side (×3, owner-gated on each strategy):
 *     12. setWithdrawer(newSYA, true)                (lets new SYA call skimSurplus)
 *     13. setWithdrawer(oldSYA, false)               (deactivation)
 *     14. setSetAsideBuffer(StableStaker, 25)        (USER-SPECIFIED 2026-06-10: 25% of the
 *                                                     staker's skimmed surplus returns to the
 *                                                     staker, topping up its withdrawal buffer)
 *     15. setSetAsideBuffer(phUSD minter, 0)         (DELIBERATELY ZERO: the buffer is sent to
 *                                                     the client contract itself, and the minter
 *                                                     has no code path to use or recover loose
 *                                                     tokens — a nonzero value strands funds.
 *                                                     0 matches the live story-055 config.)
 *   NFTMinter:
 *     16. setAuthorizedBurner(newSYA, true)          (claim() must burn the gate NFT)
 *     17. setAuthorizedBurner(oldSYA, false)         (deactivation)
 *   Pauser:
 *     18. register(newSYA)
 *     19. oldSYA.setPauser(0), then unregister(oldSYA) (deactivation; Pauser refuses to
 *                                                     unregister while still set as the
 *                                                     target's pauser)
 *   Old SYA:
 *     20. removeYieldStrategy ×3                     (deactivation: empties its registry so any
 *                                                     residual claim() reverts ZeroAmount before
 *                                                     touching funds; getTotalYield() returns 0)
 *
 * NOT REWIRED (verified no SYA-side state held elsewhere):
 *   - PhlimboV2.collectReward is open to any caller (pull-based) — no Phlimbo-side pointer.
 *   - MintPageView / DepositView do not reference the SYA address.
 *
 * Post-run: the broadcast pipeline auto-patches mainnet-addresses.ts (StableYieldAccumulator)
 * via progress.replace-sya.1.json. Manual: verify the new contract on Etherscan, repoint UI.
 *
 * LEDGER SIGNER: index 46, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6
 */
interface IStrategyAdmin {
    function owner() external view returns (address);
    function setWithdrawer(address withdrawer, bool _auth) external;
    function authorizedWithdrawers(address) external view returns (bool);
    function setSetAsideBuffer(address client, uint256 bufferPercent) external;
    function setAsideBufferSize(address client) external view returns (uint256);
    function authorizedClients(address client) external view returns (bool);
}

interface INFTMinterAdmin {
    function owner() external view returns (address);
    function setAuthorizedBurner(address burner, bool authorized) external;
    function authorizedBurners(address burner) external view returns (bool);
}

interface IPauserAdmin {
    function owner() external view returns (address);
    function register(address pausableContract) external;
    function unregister(address pausableContract) external;
    function getPausableContracts() external view returns (address[] memory);
}

interface IOldSYA {
    function owner() external view returns (address);
    function getYieldStrategies() external view returns (address[] memory);
    function removeYieldStrategy(address strategy) external;
    function rewardToken() external view returns (address);
    function phlimbo() external view returns (address);
    function nftMinter() external view returns (address);
    function nudge() external view returns (address);
    function pauser() external view returns (address);
    function setPauser(address _pauser) external;
}

contract ReplaceSYAMainnet is Script {
    // ===== External tokens =====
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // ===== Live Phoenix contracts (server/deployments/mainnet-addresses.ts, verified on-chain) =====
    address public constant OLD_SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address public constant PHLIMBO_V2 = 0x6084a02C2Ac0127ddF1e617De257c61480A2AeE0;
    address public constant NFT_MINTER = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant NUDGE = 0x86866e01a115C17892Ed04c548F2e8638851029d; // BatchNFTMinter (story 057)

    // Story-055 yield strategies (deployed 2026-06-10)
    address public constant YS_DOLA = 0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9;
    address public constant YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;
    address public constant YS_USDC = 0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470;

    // Strategy clients whose surplus the SYA sweeps
    address public constant PHUSD_MINTER = 0x435B0A1884bd0fb5667677C9eb0e59425b1477E5;
    address public constant STABLE_STAKER = 0xbce8ABC09BaEDCabE93419bF875f6186e182079A;

    address public constant OWNER_ADDRESS = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // ===== Safety-relevant parameters (every value sourced; see header) =====
    uint256 public constant DISCOUNT_RATE_BPS = 3000; // replicated from live old SYA getDiscountRate()
    uint256 public constant NUDGE_SPLIT_PERCENT = 20; // user-specified 2026-06-10 (was 30 live)
    // Staker only: the buffer slice is transferred to the client contract itself. StableStaker
    // serves withdrawals from idle balance (useful); the minter cannot use or recover loose
    // tokens (stranded). User-specified 25% 2026-06-10 (live: staker 10 on USDC strategy, else 0).
    uint256 public constant STAKER_BUFFER_PERCENT = 25;
    uint256 public constant MINTER_BUFFER_PERCENT = 0;

    address public newSYA;

    function run() external {
        require(block.chainid == 1, "Wrong chain - expected Mainnet (1)");

        _preflight();

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner, no broadcast ***");
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        _deployAndConfigureNewSYA();
        _rewireStrategies();
        _rewireNFTMinter();
        _rewirePauser();
        _deactivateOldSYA();

        if (isPreview) vm.stopPrank();
        else vm.stopBroadcast();

        _postVerify();
        // Broadcast only: a preview's CREATE address is fork-local fiction — writing it
        // would let the patcher poison mainnet-addresses.ts with a nonexistent contract.
        if (!isPreview) _writeProgress();
        else console.log("(preview: progress file NOT written)");
        _printSummary();
    }

    // Consumed by scripts/patch-mainnet-addresses-replace-sya.js (broadcast pipeline)
    // to rewrite the StableYieldAccumulator entry in mainnet-addresses.ts.
    function _writeProgress() internal {
        string memory json = string.concat(
            '{\n',
            '  "chainId": 1,\n',
            '  "networkName": "mainnet",\n',
            '  "newSYA": "', vm.toString(newSYA), '",\n',
            '  "oldSYA": "', vm.toString(OLD_SYA), '",\n',
            '  "nudgeSplit": ', vm.toString(NUDGE_SPLIT_PERCENT), ',\n',
            '  "setAsideBufferPercent": ', vm.toString(STAKER_BUFFER_PERCENT), ',\n',
            '  "discountRateBps": ', vm.toString(DISCOUNT_RATE_BPS), ',\n',
            '  "timestamp": ', vm.toString(block.timestamp), '\n',
            '}\n'
        );
        vm.writeFile("server/deployments/progress.replace-sya.1.json", json);
        console.log("Progress written: server/deployments/progress.replace-sya.1.json");
    }

    // Abort before broadcasting anything if the live state diverges from what this
    // script was written against (Configuration Safety gate).
    function _preflight() internal view {
        console.log("=== Preflight: verifying live state matches script assumptions ===");

        IOldSYA old = IOldSYA(OLD_SYA);
        require(old.owner() == OWNER_ADDRESS, "old SYA owner mismatch");
        require(old.rewardToken() == USDC, "old SYA rewardToken mismatch");
        require(old.phlimbo() == PHLIMBO_V2, "old SYA phlimbo mismatch");
        require(old.nftMinter() == NFT_MINTER, "old SYA nftMinter mismatch");
        require(old.nudge() == NUDGE, "old SYA nudge mismatch");
        require(old.pauser() == PAUSER, "old SYA pauser mismatch");
        require(old.getYieldStrategies().length == 3, "old SYA strategy count changed");

        address[3] memory strategies = [YS_DOLA, YS_USDE, YS_USDC];
        for (uint256 i = 0; i < 3; i++) {
            IStrategyAdmin ys = IStrategyAdmin(strategies[i]);
            require(ys.owner() == OWNER_ADDRESS, "strategy owner mismatch");
            require(ys.authorizedWithdrawers(OLD_SYA), "old SYA not withdrawer (already rewired?)");
            require(ys.authorizedClients(PHUSD_MINTER), "minter not a client");
            require(ys.authorizedClients(STABLE_STAKER), "staker not a client");
        }

        require(INFTMinterAdmin(NFT_MINTER).owner() == OWNER_ADDRESS, "NFTMinter owner mismatch");
        require(INFTMinterAdmin(NFT_MINTER).authorizedBurners(OLD_SYA), "old SYA not a burner");
        require(IPauserAdmin(PAUSER).owner() == OWNER_ADDRESS, "Pauser owner mismatch");

        console.log("Preflight OK");
    }

    function _deployAndConfigureNewSYA() internal {
        StableYieldAccumulator sya = new StableYieldAccumulator();
        newSYA = address(sya);
        console.log("New StableYieldAccumulator:", newSYA);

        sya.setRewardToken(USDC);
        sya.setPhlimbo(PHLIMBO_V2);
        sya.approvePhlimbo(type(uint256).max);
        sya.setNFTMinter(NFT_MINTER);
        sya.setNudgeAddress(NUDGE);
        sya.setNudgeSplit(NUDGE_SPLIT_PERCENT);
        sya.setPauser(PAUSER);

        sya.setTokenConfig(DOLA, 18, 1e18);
        sya.setTokenConfig(USDE, 18, 1e18);
        sya.setTokenConfig(USDC, 6, 1e18);

        sya.addYieldStrategy(YS_DOLA, DOLA);
        sya.addYieldStrategy(YS_USDE, USDE);
        sya.addYieldStrategy(YS_USDC, USDC);

        sya.setDiscountRate(DISCOUNT_RATE_BPS);
        console.log("New SYA configured (nudgeSplit=20, discount=3000bps)");
    }

    function _rewireStrategies() internal {
        address[3] memory strategies = [YS_DOLA, YS_USDE, YS_USDC];
        for (uint256 i = 0; i < 3; i++) {
            IStrategyAdmin ys = IStrategyAdmin(strategies[i]);
            ys.setWithdrawer(newSYA, true);
            ys.setWithdrawer(OLD_SYA, false);
            ys.setSetAsideBuffer(STABLE_STAKER, STAKER_BUFFER_PERCENT);
            ys.setSetAsideBuffer(PHUSD_MINTER, MINTER_BUFFER_PERCENT);
            console.log("Strategy rewired (withdrawer swap, staker buffer 25%):", strategies[i]);
        }
    }

    function _rewireNFTMinter() internal {
        INFTMinterAdmin(NFT_MINTER).setAuthorizedBurner(newSYA, true);
        INFTMinterAdmin(NFT_MINTER).setAuthorizedBurner(OLD_SYA, false);
        console.log("NFTMinter burner auth: new SYA in, old SYA out");
    }

    function _rewirePauser() internal {
        IPauserAdmin(PAUSER).register(newSYA);
        // Pauser.unregister refuses while the target still names it as pauser —
        // clear the old SYA's pauser pointer first (also disables pausing on it).
        IOldSYA(OLD_SYA).setPauser(address(0));
        IPauserAdmin(PAUSER).unregister(OLD_SYA);
        console.log("Pauser registry: new SYA in, old SYA out");
    }

    function _deactivateOldSYA() internal {
        IOldSYA old = IOldSYA(OLD_SYA);
        // Snapshot first: removeYieldStrategy mutates the array (swap-and-pop).
        address[] memory registered = old.getYieldStrategies();
        for (uint256 i = 0; i < registered.length; i++) {
            old.removeYieldStrategy(registered[i]);
        }
        console.log("Old SYA strategy registry emptied (claim now reverts ZeroAmount)");
    }

    function _postVerify() internal view {
        console.log("=== Post-wire verification ===");
        StableYieldAccumulator sya = StableYieldAccumulator(newSYA);

        require(sya.owner() == OWNER_ADDRESS, "new SYA owner wrong");
        require(sya.rewardToken() == USDC, "rewardToken not set");
        require(sya.phlimbo() == PHLIMBO_V2, "phlimbo not set");
        require(sya.nftMinter() == NFT_MINTER, "nftMinter not set");
        require(sya.nudge() == NUDGE, "nudge not set");
        require(sya.nudgeSplit() == NUDGE_SPLIT_PERCENT, "nudgeSplit wrong");
        require(sya.getDiscountRate() == DISCOUNT_RATE_BPS, "discountRate wrong");
        require(sya.getYieldStrategies().length == 3, "strategy count wrong");

        address[3] memory strategies = [YS_DOLA, YS_USDE, YS_USDC];
        for (uint256 i = 0; i < 3; i++) {
            IStrategyAdmin ys = IStrategyAdmin(strategies[i]);
            require(ys.authorizedWithdrawers(newSYA), "new SYA not withdrawer");
            require(!ys.authorizedWithdrawers(OLD_SYA), "old SYA still withdrawer");
            require(ys.setAsideBufferSize(STABLE_STAKER) == STAKER_BUFFER_PERCENT, "staker buffer wrong");
            require(ys.setAsideBufferSize(PHUSD_MINTER) == MINTER_BUFFER_PERCENT, "minter buffer wrong");
        }

        require(INFTMinterAdmin(NFT_MINTER).authorizedBurners(newSYA), "new SYA not burner");
        require(!INFTMinterAdmin(NFT_MINTER).authorizedBurners(OLD_SYA), "old SYA still burner");
        require(IOldSYA(OLD_SYA).getYieldStrategies().length == 0, "old SYA not emptied");

        bool newRegistered;
        bool oldRegistered;
        address[] memory pausables = IPauserAdmin(PAUSER).getPausableContracts();
        for (uint256 i = 0; i < pausables.length; i++) {
            if (pausables[i] == newSYA) newRegistered = true;
            if (pausables[i] == OLD_SYA) oldRegistered = true;
        }
        require(newRegistered && !oldRegistered, "Pauser registry wrong");

        // Live smoke check: the new getYield must now see BOTH clients' USDe surplus
        // (~14 USDe pending at time of writing, vs ~11 minter-only on the old SYA).
        uint256 totalYield = sya.getTotalYield();
        console.log("New SYA getTotalYield (18dp):", totalYield);
        require(totalYield > 0, "expected nonzero pending yield");

        console.log("Post-wire verification OK");
    }

    function _printSummary() internal view {
        console.log("");
        console.log("=========================================");
        console.log("  SYA REPLACEMENT SUMMARY");
        console.log("=========================================");
        console.log("NEW StableYieldAccumulator:", newSYA);
        console.log("OLD (deactivated):         ", OLD_SYA);
        console.log("nudgeSplit: 20% | set-aside buffers: 25% | discount: 3000 bps");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. mainnet-addresses.ts auto-patched by broadcast pipeline (verify the diff)");
        console.log("2. Verify new SYA on Etherscan");
        console.log("3. Point UI / wagmi hooks at the new address");
        console.log("4. Re-test claim: SYA_ADDRESS=<new> npm run preview-sya-claim-scx");
        console.log("=========================================");
    }
}
