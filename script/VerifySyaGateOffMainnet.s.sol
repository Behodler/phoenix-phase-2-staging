// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {
    SyaGateOffMainnetBase,
    IOldSYA,
    ISyaStrategyAdmin,
    INFTMinterV2SyaGateOff,
    IPauserV2SyaGateOff
} from "./helpers/SyaGateOffMainnetBase.sol";

/// @dev The 029 SYA getters the verifier reads that the interface does not declare.
interface INewSYAView {
    function owner() external view returns (address);
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function isRegisteredStrategy(address strategy) external view returns (bool);
}

/**
 * @title VerifySyaGateOffMainnet  (story 131, sprint nft-bonfire) - READ-ONLY POST-BROADCAST VERIFIER
 * @notice No --broadcast, no --sender, no prank / deal / snapshot: reads LIVE mainnet and fails `verify: ...` on the
 *         first violated invariant. Chained in `sya-gate-off:broadcast` after the confirm step and the patcher, then
 *         followed by `pauser-v2-verify`. Valid as a health check only until the first post-cutover retune of the
 *         new SYA (a phStaging2:119 nudge repoint, a discount change); after that it fails permanently by design and
 *         119's `nudge-discount:verify` is the health check. Never re-run the broadcast to make it pass (runbook).
 *
 *         The new SYA and the new harvester come from the COMPLETED progress.sya-gate-off.1.json. The NEW SYA is
 *         read through the bumped 029 `IStableYieldAccumulator` (4-field TokenConfig); the OLD SYA through the
 *         local `IOldSYA`, which has no `tokenConfigs` - the old SYA's token configs are never read. Asserts:
 *           - new SYA: owner OWNER; wiring == the old SYA's (rewardToken USDC, phlimbo, nudge, nudgeSplit,
 *             nudgeStreamer); USDC / USDe / DOLA each `configured`, decimals == the hard-coded 6 / 18 / 18, rate 1e18;
 *             each token's on-chain decimals() == its constant; strategies map to exactly USDC, DOLA, USDe;
 *             nftMinter == 0; discount == 100; pauser == PauserV2 and registered; not paused;
 *             Phlimbo allowance ~max;
 *           - strategies: withdrawer(new) == true, withdrawer(old) == false;
 *           - old SYA: strategy list empty, unregistered from PauserV2, pauser() != PauserV2, NFTMinterV2 burner
 *             revoked, Phlimbo allowance 0;
 *           - new harvester: owner / immutables (sya == new SYA), routes exact, USDC unrouted, ETH pool exact;
 *           - book `StableYieldAccumulator` == new SYA and `SYAHarvester` == new harvester.
 *
 * Run: npm run sya-gate-off-verify
 */
contract VerifySyaGateOffMainnet is SyaGateOffMainnetBase {
    function run() external view {
        console.log("=================================================");
        console.log("  VERIFY gate-free SYA + SYAHarvester - MAINNET (story 131) - READ-ONLY");
        console.log("=================================================");
        require(block.chainid == CHAIN_ID, "verify: wrong chain ID - expected Mainnet (1)");
        _requireBookMatchesConstants();
        _requireOnChainDecimals();

        address sya = _progressSya();
        address h = _progressHarvester();
        require(
            sya != address(0) && h != address(0), "verify: progress.sya-gate-off.1.json lacks the new SYA / harvester"
        );
        require(_progressCompleted(), "verify: progress.sya-gate-off.1.json is not completed - run the confirm step");
        require(sya != OLD_SYA && h != OLD_HARVESTER, "verify: progress names the OLD SYA / harvester");
        require(sya.code.length > 0 && h.code.length > 0, "verify: new SYA / harvester has no code");
        console.log("new SYA:      ", sya);
        console.log("new harvester:", h);

        IStableYieldAccumulator s = IStableYieldAccumulator(sya);
        IOldSYA old = IOldSYA(OLD_SYA);

        // ---- new SYA ----
        require(INewSYAView(sya).owner() == OWNER, "verify: new SYA owner() != OWNER");
        require(s.rewardToken() == USDC && old.rewardToken() == USDC, "verify: rewardToken != USDC");
        require(s.phlimbo() == old.phlimbo(), "verify: new SYA phlimbo != old SYA phlimbo");
        require(s.nudge() == old.nudge(), "verify: new SYA nudge != old SYA nudge");
        require(s.nudgeSplit() == old.nudgeSplit(), "verify: new SYA nudgeSplit != old SYA nudgeSplit");
        require(s.nudgeStreamer() == old.nudgeStreamer(), "verify: new SYA nudgeStreamer != old SYA nudgeStreamer");
        address[3] memory t = _targetTokens();
        for (uint256 i = 0; i < 3; i++) {
            IStableYieldAccumulator.TokenConfig memory cfg = s.getTokenConfig(t[i]);
            require(cfg.configured, string.concat("verify: token not configured: ", _tokenName(t[i])));
            require(
                cfg.decimals == _expectedDecimals(t[i]),
                string.concat("verify: token decimals != hard-coded constant: ", _tokenName(t[i]))
            );
            require(
                cfg.normalizedExchangeRate == RATE_1_TO_1, string.concat("verify: rate != 1e18: ", _tokenName(t[i]))
            );
        }
        address[] memory list = s.getYieldStrategies();
        address[] memory toks = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            toks[i] = s.strategyTokens(list[i]);
            require(
                ISyaStrategyAdmin(list[i]).authorizedWithdrawers(sya), "verify: new SYA is not a strategy withdrawer"
            );
            require(!ISyaStrategyAdmin(list[i]).authorizedWithdrawers(OLD_SYA), "verify: old SYA is still a withdrawer");
        }
        _requireStrategyTokenSet(list, toks);
        require(s.nftMinter() == address(0), "verify: new SYA nftMinter != 0 (claim gate must be OFF)");
        require(s.getDiscountRate() == NEW_DISCOUNT_BPS, "verify: new SYA discount != 100 bps");
        require(INewSYAView(sya).pauser() == PAUSER_V2, "verify: new SYA pauser() != PauserV2");
        require(IPauserV2SyaGateOff(PAUSER_V2).isRegistered(sya), "verify: new SYA not registered with PauserV2");
        require(!INewSYAView(sya).paused(), "verify: new SYA is paused");
        require(
            IERC20(USDC).allowance(sya, s.phlimbo()) >= type(uint128).max, "verify: new SYA phlimbo allowance not ~max"
        );
        console.log("OK: new SYA wiring mirrors the old, tokens configured 6/18/18 @1e18, gate off, 1%, PauserV2");

        // ---- old SYA ----
        require(old.getYieldStrategies().length == 0, "verify: old SYA strategy list is not empty");
        require(!IPauserV2SyaGateOff(PAUSER_V2).isRegistered(OLD_SYA), "verify: old SYA still registered with PauserV2");
        require(old.pauser() != PAUSER_V2, "verify: old SYA pauser() is still PauserV2");
        require(
            !INFTMinterV2SyaGateOff(NFT_MINTER).authorizedBurners(OLD_SYA), "verify: old SYA is still an NFT burner"
        );
        require(IERC20(USDC).allowance(OLD_SYA, old.phlimbo()) == 0, "verify: old SYA phlimbo allowance != 0");
        console.log("OK: old SYA retired (no strategies, unregistered, burner revoked, allowance 0)");

        // ---- new harvester ----
        Config memory c = _harvesterConfig(sya);
        _checkConfigured(SYAHarvester(payable(h)), c);
        console.log("OK: new SYAHarvester immutables, USDe + DOLA routes, ETH pool");

        // ---- book ----
        require(
            _bookSya() == sya,
            "verify: address book StableYieldAccumulator != new SYA - run node scripts/patch-mainnet-addresses-sya-gate-off.js"
        );
        require(
            _bookHarvester() == h,
            "verify: address book SYAHarvester != new harvester - run node scripts/patch-mainnet-addresses-sya-gate-off.js"
        );
        console.log("VERIFY OK");
    }
}
