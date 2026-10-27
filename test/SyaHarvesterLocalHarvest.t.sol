// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {IStableYieldAccumulator} from "@stable-yield-accumulator/interfaces/IStableYieldAccumulator.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import {SYAHarvester} from "sya-harvester/SYAHarvester.sol";
import {SyaHarvesterLocalStack} from "../script/helpers/SyaHarvesterLocalStack.sol";
import {SyaHarvesterLocalConfig} from "../script/helpers/SyaHarvesterLocalConfig.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockDola} from "../src/mocks/MockDola.sol";
import {MockUSDe} from "../src/mocks/MockUSDe.sol";
import {MockSUSDe} from "../src/mocks/MockSUSDe.sol";
import {MockSDOLA} from "../src/mocks/MockSDOLA.sol";
import {MockAutoDOLA} from "../src/mocks/MockAutoDOLA.sol";
import {MockMarketAMMAdapter} from "../src/mocks/MockMarketAMMAdapter.sol";
import {MockCurveDolaMetaPool} from "../src/mocks/MockCurveDolaMetaPool.sol";

/// @notice Stands in for PhlimboV3 on SYA's reward path: pulls the reward the SYA approved it for.
contract RewardSinkPhlimbo {
    address public immutable usdc;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function collectReward(uint256 amount) external {
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
    }
}

/// @title  SyaHarvesterLocalHarvestTest
/// @notice Story 116. Reproduces the anvil harvest stack and harvests through it end to end:
///         - story 115's infrastructure via `SyaHarvesterLocalStack.deploy` (Router NG mock, crvUSD pools,
///           V4 PoolManager + ETH/USDC pool), and the story-110 DOLA metapool;
///         - the REAL StableYieldAccumulator and NFTMinterV2, with the three strategy types DeployMocks
///           registers: ERC4626YieldStrategy over MockSDOLA (DOLA) and over MockAutoDOLA(USDC), and
///           ERC4626MarketYieldStrategy over MockSUSDe through MockMarketAMMAdapter (USDe), with the
///           DeployMocks 30 / 10 bps tolerance / AMM slippage, token configs (decimals, 1e18) and the
///           DeployMocks 2000 bps discount;
///         - SYAHarvester deployed and configured by `SyaHarvesterLocalConfig.deploy`, and the harvest run by
///           `SyaHarvesterLocalConfig.smokeHarvest`: the SAME library calls DeployMocks Phase 11.12 makes.
///         The nudge split is left at 0 (no NudgeStreamer here); the nudge path is not the harvester's concern.
contract SyaHarvesterLocalHarvestTest is Test {
    uint256 internal constant NFT_INDEX = 1;
    uint256 internal constant PRINCIPAL_18 = 10_000e18;
    uint256 internal constant PRINCIPAL_USDC = 10_000e6;
    uint256 internal constant YIELD_18 = 1_000e18;
    uint256 internal constant YIELD_USDC = 1_000e6;

    MockRewardToken internal usdc;
    MockDola internal dola;
    MockUSDe internal usde;
    MockCurveDolaMetaPool internal curveDola;
    SyaHarvesterLocalStack.Infra internal s;

    MockSDOLA internal sdola;
    MockAutoDOLA internal autoUsdc;
    MockSUSDe internal susde;
    ERC4626YieldStrategy internal ysDola;
    ERC4626YieldStrategy internal ysUsdc;
    ERC4626MarketYieldStrategy internal ysUsde;

    StableYieldAccumulator internal sya;
    NFTMinterV2 internal nft;
    RewardSinkPhlimbo internal phlimbo;
    SYAHarvester internal harvester;

    address internal keeper = makeAddr("keeper");

    receive() external payable {}

    function setUp() public {
        usdc = new MockRewardToken();
        dola = new MockDola();
        usde = new MockUSDe();
        curveDola = new MockCurveDolaMetaPool(address(dola), address(usdc));
        dola.mint(address(curveDola), 1_000_000e18);
        usdc.mint(address(curveDola), 1_000_000e6);

        vm.deal(address(this), 1_000 ether);
        s = SyaHarvesterLocalStack.deploy(
            SyaHarvesterLocalStack.Inputs({
                usdc: address(usdc),
                dola: address(dola),
                usde: address(usde),
                curveDola: address(curveDola),
                poolManagerOwner: address(this),
                payer: address(this)
            })
        );

        _deployStrategies();
        _deploySya();

        harvester = SyaHarvesterLocalConfig.deploy(s, _configInputs());

        // Keeper: one claim NFT, approved to the harvester.
        nft.setAuthorizedMinter(address(this), true);
        nft.mintFor(NFT_INDEX, keeper);
        vm.prank(keeper);
        nft.setApprovalForAll(address(harvester), true);
    }

    function _deployStrategies() internal {
        sdola = new MockSDOLA(address(dola));
        autoUsdc = new MockAutoDOLA(address(usdc));
        susde = new MockSUSDe(address(usde));
        ysDola = new ERC4626YieldStrategy(address(this), address(dola), address(sdola));
        ysUsdc = new ERC4626YieldStrategy(address(this), address(usdc), address(autoUsdc));
        MockMarketAMMAdapter adapter = new MockMarketAMMAdapter(address(usde), address(susde), 10);
        ysUsde = new ERC4626MarketYieldStrategy(address(this), address(usde), address(susde), address(adapter));
        ysUsde.setSlippageTolerance(30);

        // This contract is the strategies' client (StableStakerV2 / the minter on anvil).
        ysDola.setClient(address(this), true);
        ysUsdc.setClient(address(this), true);
        ysUsde.setClient(address(this), true);
        dola.mint(address(this), PRINCIPAL_18);
        usdc.mint(address(this), PRINCIPAL_USDC);
        usde.mint(address(this), PRINCIPAL_18);
        dola.approve(address(ysDola), PRINCIPAL_18);
        usdc.approve(address(ysUsdc), PRINCIPAL_USDC);
        usde.approve(address(ysUsde), PRINCIPAL_18);
        ysDola.deposit(address(dola), PRINCIPAL_18, address(this));
        ysUsdc.deposit(address(usdc), PRINCIPAL_USDC, address(this));
        ysUsde.deposit(address(usde), PRINCIPAL_18, address(this));
    }

    function _deploySya() internal {
        nft = new NFTMinterV2(address(this));
        nft.registerDispatcher(makeAddr("dispatcher"), 1e18, 0); // index 1

        phlimbo = new RewardSinkPhlimbo(address(usdc));
        sya = new StableYieldAccumulator();
        sya.setRewardToken(address(usdc));
        sya.setPhlimbo(address(phlimbo));
        sya.setTokenConfig(address(usdc), 6, 1e18);
        sya.setTokenConfig(address(dola), 18, 1e18);
        sya.setTokenConfig(address(usde), 18, 1e18);
        sya.addYieldStrategy(address(ysUsdc), address(usdc));
        sya.addYieldStrategy(address(ysUsde), address(usde));
        sya.addYieldStrategy(address(ysDola), address(dola));
        sya.setDiscountRate(2000);
        sya.approvePhlimbo(type(uint256).max);
        sya.setNFTMinter(address(nft));
        nft.setAuthorizedBurner(address(sya), true);
        ysDola.setWithdrawer(address(sya), true);
        ysUsdc.setWithdrawer(address(sya), true);
        ysUsde.setWithdrawer(address(sya), true);
    }

    function _configInputs() internal view returns (SyaHarvesterLocalConfig.Inputs memory) {
        return SyaHarvesterLocalConfig.Inputs({
            owner: address(this),
            sya: address(sya),
            usdc: address(usdc),
            dola: address(dola),
            usde: address(usde),
            curveDola: address(curveDola)
        });
    }

    function _seedYield() internal {
        sdola.addYield(YIELD_18);
        susde.addYield(YIELD_18);
        usdc.mint(address(autoUsdc), YIELD_USDC);
    }

    function _smokeInputs() internal view returns (SyaHarvesterLocalConfig.SmokeInputs memory) {
        return SyaHarvesterLocalConfig.SmokeInputs({
            sya: address(sya),
            usdc: address(usdc),
            dola: address(dola),
            usde: address(usde),
            crvUSD: address(s.crvUSD),
            dolaPool: address(curveDola),
            usdePool: address(s.curveUsdeCrvusd),
            dolaStrategy: address(ysDola),
            usdeStrategy: address(ysUsde),
            usdcStrategy: address(ysUsdc),
            caller: keeper,
            nftIndex: NFT_INDEX
        });
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_configuration_routesAreRouterNgContiguous() public view {
        SyaHarvesterLocalConfig.assertConfigured(harvester, s, _configInputs());
        assertEq(harvester.getRoute(address(dola)).path[2], address(usdc), "DOLA: one hop to USDC");
        assertEq(harvester.getRoute(address(usde)).path[2], address(s.crvUSD), "USDe: via crvUSD");
        assertEq(harvester.getRoute(address(usde)).path[4], address(usdc), "USDe: then USDC");
        assertFalse(harvester.getRoute(address(usdc)).configured, "USDC (reward token) carries no route");
    }

    /// @notice The M-01 shape `[USDe, pool, crvUSD, 0, ..., USDC]`: Router NG would stop after hop 0 and
    ///         deliver crvUSD. `setRoute` rejects it at the first non-zero entry after the gap.
    function test_setRoute_rejectsGappedRoute_InvalidRouteGap() public {
        SyaHarvesterLocalStack.Route memory u = SyaHarvesterLocalStack.usdeRoute(s, address(usde), address(usdc));
        address[11] memory gapped;
        gapped[0] = address(usde);
        gapped[1] = address(s.curveUsdeCrvusd);
        gapped[2] = address(s.crvUSD);
        gapped[10] = address(usdc); // trailing USDC after the empty pool slot path[3]
        uint256[5][5] memory params;
        params[0] = u.swapParams[0];

        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteGap.selector, uint256(10)));
        harvester.setRoute(address(usde), gapped, params, u.pools);
    }

    /// @notice The same gap with nothing trailing: the route is contiguous but delivers crvUSD, so it is
    ///         rejected by the delivered-token check instead.
    function test_setRoute_rejectsTruncatedRoute_InvalidRouteEnd() public {
        SyaHarvesterLocalStack.Route memory u = SyaHarvesterLocalStack.usdeRoute(s, address(usde), address(usdc));
        u.path[3] = address(0);
        u.path[4] = address(0);
        u.swapParams[1] = [uint256(0), 0, 0, 0, 0];

        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.InvalidRouteEnd.selector, address(usdc), address(s.crvUSD)));
        harvester.setRoute(address(usde), u.path, u.swapParams, u.pools);
    }

    /// @notice A rejected update leaves the stored, valid route untouched.
    function test_rejectedRoute_leavesStoredRouteIntact() public {
        SyaHarvesterLocalStack.Route memory u = SyaHarvesterLocalStack.usdeRoute(s, address(usde), address(usdc));
        u.path[3] = address(0);
        u.swapParams[1] = [uint256(0), 0, 0, 0, 0];
        vm.expectRevert();
        harvester.setRoute(address(usde), u.path, u.swapParams, u.pools);
        SyaHarvesterLocalConfig.assertRouteContiguous(harvester, address(usde), address(usdc), 2);
    }

    // ------------------------------------------------------------------
    // Harvest
    // ------------------------------------------------------------------

    function test_yieldSeeded_everyStrategyClaimable() public {
        _seedYield();
        IStableYieldAccumulator i = IStableYieldAccumulator(address(sya));
        assertGt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysDola)), 0, "DOLA");
        assertGt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysUsde)), 0, "USDe");
        assertGt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysUsdc)), 0, "USDC");
    }

    /// @notice The smoke harvest DeployMocks runs, at a 50 gwei gas price so the harvester's own
    ///         `Unprofitable` gas check genuinely bites: sells DOLA and USDe, pays ETH to the keeper, burns
    ///         one claim NFT, pays SYA's reward sink, and leaves the harvester empty.
    function test_smokeHarvest_sellsDolaAndUsde_paysEth_passesGasCheck() public {
        _seedYield();
        uint256 keeperEthBefore = keeper.balance;
        uint256 phlimboBefore = usdc.balanceOf(address(phlimbo));

        vm.txGasPrice(50 gwei);
        vm.startPrank(keeper, keeper);
        SyaHarvesterLocalConfig.SmokeResult memory r = SyaHarvesterLocalConfig.smokeHarvest(harvester, _smokeInputs());
        vm.stopPrank();

        assertGt(r.ethOut, 0);
        assertEq(keeper.balance - keeperEthBefore, r.ethOut, "keeper received the ETH");
        assertGe(r.ethOut, (r.gasUsed + SyaHarvesterLocalConfig.GAS_OVERHEAD) * 50 gwei, "gas check");
        assertGt(r.dolaSold, 0);
        assertGt(r.usdeSold, 0);
        assertGt(usdc.balanceOf(address(phlimbo)), phlimboBefore, "SYA paid its reward sink");
        assertEq(nft.balanceOf(keeper, NFT_INDEX), 0, "claim NFT burned");
        // Harvested: nothing material left to claim on any strategy.
        IStableYieldAccumulator i = IStableYieldAccumulator(address(sya));
        assertLt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysDola)), 1e6, "DOLA yield harvested");
        assertLt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysUsde)), 1e6, "USDe yield harvested");
        assertLt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysUsdc)), 1e6, "USDC yield harvested");
    }

    /// @notice Without a USDe route, a harvest that receives USDe reverts loudly instead of stranding it.
    function test_harvest_withoutUsdeRoute_revertsRouteNotConfigured() public {
        _seedYield();
        harvester.clearRoute(address(usde));
        vm.prank(keeper, keeper);
        vm.expectRevert(abi.encodeWithSelector(SYAHarvester.RouteNotConfigured.selector, address(usde)));
        harvester.harvest(new address[](0), NFT_INDEX, 1);
    }
}
