// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {ICurveRouterNG} from "sya-harvester/interfaces/ICurveRouterNG.sol";
import {SyaHarvesterLocalStack} from "./SyaHarvesterLocalStack.sol";

/// @title  SyaHarvesterLocalConfig
/// @notice Story 116. Deploys SYAHarvester (lib/sya-harvester, pin 6b862aa) on top of story 115's
///         anvil infrastructure, configures it so every SYA strategy token is harvestable, asserts the
///         stored routes satisfy Curve Router NG v1.1's contiguity rules, and runs a smoke harvest.
///
///         - DOLA: one hop to USDC through the DOLA metapool (`exchange_underlying`).
///         - USDe: two hops, USDe -> crvUSD -> USDC.
///         - USDC: NO route. It is SYA's reward token; `_sellYield` skips it and the USDC yield is
///           kept as the reward/settlement currency directly.
///
///         Shared by `DeployMocks` (Phase 11.12, inside its broadcast) and
///         `test/SyaHarvesterLocalHarvest.t.sol`, so the forge test drives exactly the anvil wiring.
/// @dev    Internal functions, inlined into the caller like `SyaHarvesterLocalStack`: every `new` and
///         every call is made by the calling contract (the broadcasting deployer in the script), so the
///         caller must be `Inputs.owner` for the owner-only setters.
library SyaHarvesterLocalConfig {
    /// @dev The harvester's own gas-check overhead (SYAHarvester.GAS_OVERHEAD).
    uint256 internal constant GAS_OVERHEAD = 60_000;
    /// @dev Gas ceiling the smoke harvest must stay under, and the gas price the payout must cover at
    ///      that ceiling. Deliberately generous for an anvil chain (base fee ~1 gwei), so the smoke test
    ///      proves profitability independently of whatever gas price the broadcast actually pays.
    uint256 internal constant SMOKE_GAS_CEILING = 3_000_000;
    uint256 internal constant SMOKE_GAS_PRICE = 50 gwei;
    /// @dev Router NG v1.1 dispatches on swap_type 1..8; 0 reverts "Bad swap type" and 9 (ERC4626)
    ///      is rejected by this router version (sya-harvester test/fork/MainnetRoutes.sol).
    uint256 internal constant MAX_SWAP_TYPE = 8;

    struct Inputs {
        /// @dev Harvester owner; must be the calling account (it sets the routes and the ETH pool).
        address owner;
        address sya;
        address usdc;
        address dola;
        address usde;
        /// @dev The story-110 MockCurveDolaMetaPool (DOLA = 0, USDC = 2).
        address curveDola;
    }

    // ------------------------------------------------------------------
    // Deployment + configuration
    // ------------------------------------------------------------------

    /// @notice Deploys SYAHarvester against the local infrastructure, sets the ETH pool and both
    ///         routes, then asserts the whole configuration (see `assertConfigured`).
    function deploy(SyaHarvesterLocalStack.Infra memory s, Inputs memory t) internal returns (SYAHarvester h) {
        require(IStableYieldAccumulator(t.sya).rewardToken() == t.usdc, "story-116: SYA reward token is not USDC");
        h = new SYAHarvester(t.owner, s.poolManager, IStableYieldAccumulator(t.sya), ICurveRouterNG(address(s.router)));
        h.setEthPool(s.ethPoolKey);
        _setRoute(h, SyaHarvesterLocalStack.dolaRoute(t.curveDola, t.dola, t.usdc));
        _setRoute(h, SyaHarvesterLocalStack.usdeRoute(s, t.usde, t.usdc));
        // USDC deliberately gets no route: it is the reward token, which `_sellYield` never sells.
        assertConfigured(h, s, t);
    }

    function _setRoute(SYAHarvester h, SyaHarvesterLocalStack.Route memory r) private {
        h.setRoute(r.token, r.path, r.swapParams, r.pools);
    }

    /// @notice Loud read-back of the deployed configuration: immutables, owner, ETH pool key and the
    ///         Router NG contiguity of every stored route.
    function assertConfigured(SYAHarvester h, SyaHarvesterLocalStack.Infra memory s, Inputs memory t) internal view {
        require(h.owner() == t.owner, "story-116: harvester owner mismatch");
        require(address(h.poolManager()) == address(s.poolManager), "story-116: harvester PoolManager mismatch");
        require(address(h.sya()) == t.sya, "story-116: harvester SYA mismatch");
        require(address(h.router()) == address(s.router), "story-116: harvester router mismatch");

        PoolKey memory k = h.getEthPool();
        require(Currency.unwrap(k.currency0) == address(0), "story-116: ETH pool currency0 is not native ETH");
        require(
            Currency.unwrap(k.currency1) == IStableYieldAccumulator(t.sya).rewardToken(),
            "story-116: ETH pool currency1 is not the SYA reward token"
        );
        require(k.fee == SyaHarvesterLocalStack.ETH_POOL_FEE, "story-116: ETH pool fee");
        require(k.tickSpacing == SyaHarvesterLocalStack.ETH_POOL_TICK_SPACING, "story-116: ETH pool tickSpacing");
        require(address(k.hooks) == address(0), "story-116: ETH pool has hooks");

        assertRouteContiguous(h, t.dola, t.usdc, 1);
        assertRouteContiguous(h, t.usde, t.usdc, 2);
        require(!h.getRoute(t.usdc).configured, "story-116: reward token (USDC) must carry no route");
    }

    /// @notice Asserts the stored route for `token` is executed by Curve Router NG v1.1 exactly as
    ///         intended. Router NG runs hop k while `path[2k+1] != 0` and delivers `path[2k]` at the first
    ///         empty pool slot (sya-harvester audit 01, M-01), so:
    ///         - `path[0] == token`, and the executed prefix is exactly `expectedHops` hops;
    ///         - no zero address inside the executed prefix (a zero intermediate reverts with empty data);
    ///         - nothing non-zero after the first empty pool slot;
    ///         - executed swapParams rows carry a swap_type in 1..8; unexecuted rows and their pools are zero;
    ///         - the delivered token `path[2k]` is USDC.
    function assertRouteContiguous(SYAHarvester h, address token, address usdc, uint256 expectedHops) internal view {
        SYAHarvester.CurveRoute memory r = h.getRoute(token);
        require(r.configured, "story-116: route not configured");
        require(r.path[0] == token, "story-116: route does not start at its token");

        uint256 k;
        while (k < 5 && r.path[2 * k + 1] != address(0)) k++;
        require(k == expectedHops, "story-116: route executes the wrong number of hops");
        for (uint256 i = 0; i <= 2 * k; i++) {
            require(r.path[i] != address(0), "story-116: zero address inside the executed route prefix");
        }
        for (uint256 i = 2 * k + 1; i < 11; i++) {
            require(r.path[i] == address(0), "story-116: non-zero route entry after the first empty pool slot");
        }
        require(r.path[2 * k] == usdc, "story-116: route does not deliver USDC");

        for (uint256 hop = 0; hop < 5; hop++) {
            if (hop < k) {
                uint256 swapType = r.swapParams[hop][2];
                require(swapType != 0 && swapType <= MAX_SWAP_TYPE, "story-116: executed hop has an invalid swap_type");
            } else {
                for (uint256 f = 0; f < 5; f++) {
                    require(r.swapParams[hop][f] == 0, "story-116: unexecuted swapParams row is not zero");
                }
                require(r.pools[hop] == address(0), "story-116: unexecuted pools slot is not zero");
            }
        }
    }

    // ------------------------------------------------------------------
    // Yield checks
    // ------------------------------------------------------------------

    /// @notice What a single registered strategy alone would cost a claimer: `calculateClaimAmount`
    ///         with every OTHER registered strategy exempted.
    function claimAmountFor(IStableYieldAccumulator sya, address strategy) internal view returns (uint256) {
        address[] memory all = sya.getYieldStrategies();
        address[] memory exempt = new address[](all.length - 1);
        uint256 j;
        bool found;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] == strategy) {
                found = true;
            } else {
                require(j < exempt.length, "story-116: strategy not registered with SYA");
                exempt[j++] = all[i];
            }
        }
        require(found, "story-116: strategy not registered with SYA");
        return sya.calculateClaimAmount(exempt);
    }

    // ------------------------------------------------------------------
    // Smoke harvest
    // ------------------------------------------------------------------

    struct SmokeInputs {
        address sya;
        address usdc;
        address dola;
        address usde;
        address crvUSD;
        /// @dev First pool of each route; its input-token balance rising proves the token was SOLD.
        address dolaPool;
        address usdePool;
        /// @dev The registered strategies whose tokens are DOLA, USDe and USDC.
        address dolaStrategy;
        address usdeStrategy;
        address usdcStrategy;
        /// @dev Harvest caller: holds one unit of `nftIndex` and has `setApprovalForAll(harvester)`.
        address caller;
        uint256 nftIndex;
    }

    struct SmokeResult {
        uint256 ethOut;
        uint256 gasUsed;
        uint256 dolaSold;
        uint256 usdeSold;
    }

    /// @notice Runs `harvest(no exemptions, nftIndex, minEthOut = 1)` from the caller and asserts it
    ///         claimed all three strategies, sold DOLA and USDe through their routes, paid ETH out, burned
    ///         one claim NFT, left the harvester holding nothing, and paid out enough ETH to cover the gas
    ///         check at `SMOKE_GAS_PRICE` with the measured gas.
    function smokeHarvest(SYAHarvester h, SmokeInputs memory t) internal returns (SmokeResult memory res) {
        IStableYieldAccumulator sya = IStableYieldAccumulator(t.sya);
        require(claimAmountFor(sya, t.dolaStrategy) > 0, "story-116: no DOLA yield to harvest");
        require(claimAmountFor(sya, t.usdeStrategy) > 0, "story-116: no USDe yield to harvest");
        require(claimAmountFor(sya, t.usdcStrategy) > 0, "story-116: no USDC yield to harvest");
        address nft = sya.nftMinter();
        require(IERC1155(nft).balanceOf(t.caller, t.nftIndex) > 0, "story-116: harvest caller holds no claim NFT");
        require(IERC1155(nft).isApprovedForAll(t.caller, address(h)), "story-116: claim NFT not approved to harvester");

        uint256 nftBefore = IERC1155(nft).balanceOf(t.caller, t.nftIndex);
        uint256 dolaPoolBefore = IERC20(t.dola).balanceOf(t.dolaPool);
        uint256 usdePoolBefore = IERC20(t.usde).balanceOf(t.usdePool);

        uint256 g0 = gasleft();
        res.ethOut = h.harvest(new address[](0), t.nftIndex, 1);
        res.gasUsed = g0 - gasleft();

        res.dolaSold = IERC20(t.dola).balanceOf(t.dolaPool) - dolaPoolBefore;
        res.usdeSold = IERC20(t.usde).balanceOf(t.usdePool) - usdePoolBefore;
        require(res.ethOut > 0, "story-116: harvest paid no ETH");
        require(res.dolaSold > 0, "story-116: harvest sold no DOLA");
        require(res.usdeSold > 0, "story-116: harvest sold no USDe");
        require(IERC1155(nft).balanceOf(t.caller, t.nftIndex) == nftBefore - 1, "story-116: claim NFT not burned");
        require(res.gasUsed < SMOKE_GAS_CEILING, "story-116: harvest gas above the smoke ceiling");
        require(
            res.ethOut >= (SMOKE_GAS_CEILING + GAS_OVERHEAD) * SMOKE_GAS_PRICE,
            "story-116: harvest ETH out would fail the gas check at the smoke gas price"
        );

        // The harvester is a pass-through: nothing may stay behind.
        require(IERC20(t.usdc).balanceOf(address(h)) == 0, "story-116: harvester kept USDC");
        require(IERC20(t.dola).balanceOf(address(h)) == 0, "story-116: harvester kept DOLA");
        require(IERC20(t.usde).balanceOf(address(h)) == 0, "story-116: harvester kept USDe");
        require(IERC20(t.crvUSD).balanceOf(address(h)) == 0, "story-116: harvester kept crvUSD");
        require(address(h).balance == 0, "story-116: harvester kept ETH");
        require(IERC1155(nft).balanceOf(address(h), t.nftIndex) == 0, "story-116: harvester kept the claim NFT");
    }
}
