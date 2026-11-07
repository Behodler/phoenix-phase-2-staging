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
import {SyaGateOffLocal} from "../script/helpers/SyaGateOffLocal.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockDola} from "../src/mocks/MockDola.sol";
import {MockUSDe} from "../src/mocks/MockUSDe.sol";
import {MockSUSDe} from "../src/mocks/MockSUSDe.sol";
import {MockSDOLA} from "../src/mocks/MockSDOLA.sol";
import {MockAutoDOLA} from "../src/mocks/MockAutoDOLA.sol";
import {MockMarketAMMAdapter} from "../src/mocks/MockMarketAMMAdapter.sol";
import {MockCurveDolaMetaPool} from "../src/mocks/MockCurveDolaMetaPool.sol";
import {RewardSinkPhlimbo} from "./SyaHarvesterLocalHarvest.t.sol";

/// @title  SyaGateOffLocalTest
/// @notice Story 130. The anvil SYA stack of `SyaHarvesterLocalHarvestTest` (real StableYieldAccumulator at
///         the yield-accumulator:029 pin, real NFTMinterV2, the three DeployMocks strategy types, SYAHarvester
///         configured by `SyaHarvesterLocalConfig.deploy`), gated exactly as DeployMocks Phase 8.7 gates it,
///         then turned OFF by `SyaGateOffLocal.turnGateOff`: the SAME library call DeployMocks Phase 11.17
///         makes. Proves that after the gate-off a keeper holding NO claim NFT harvests with `nftIndex 0`,
///         and that no NFT moves.
contract SyaGateOffLocalTest is Test {
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

    /// @dev Holds one claim NFT (index 1) and approves the harvester, so a stray NFT move would show.
    address internal holder = makeAddr("holder");
    /// @dev Holds no claim NFT at all.
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

        harvester = SyaHarvesterLocalConfig.deploy(
            s,
            SyaHarvesterLocalConfig.Inputs({
                owner: address(this),
                sya: address(sya),
                usdc: address(usdc),
                dola: address(dola),
                usde: address(usde),
                curveDola: address(curveDola)
            })
        );

        nft.setAuthorizedMinter(address(this), true);
        nft.mintFor(NFT_INDEX, holder);
        vm.prank(holder);
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

    /// @dev DeployMocks order: configure first (yield-accumulator:029), then the reward token, then the
    ///      strategies, then the Phase 8.7 gate.
    function _deploySya() internal {
        nft = new NFTMinterV2(address(this));
        nft.registerDispatcher(makeAddr("dispatcher"), 1e18, 0); // index 1

        phlimbo = new RewardSinkPhlimbo(address(usdc));
        sya = new StableYieldAccumulator();
        sya.setTokenConfig(address(usdc), 6, 1e18);
        sya.setTokenConfig(address(dola), 18, 1e18);
        sya.setTokenConfig(address(usde), 18, 1e18);
        sya.setRewardToken(address(usdc));
        sya.setPhlimbo(address(phlimbo));
        sya.addYieldStrategy(address(ysUsdc), address(usdc));
        sya.addYieldStrategy(address(ysUsde), address(usde));
        sya.addYieldStrategy(address(ysDola), address(dola));
        sya.setDiscountRate(2000);
        sya.approvePhlimbo(type(uint256).max);
        // Phase 8.7: the gate is set first, exactly as on anvil.
        sya.setNFTMinter(address(nft));
        nft.setAuthorizedBurner(address(sya), true);
        ysDola.setWithdrawer(address(sya), true);
        ysUsdc.setWithdrawer(address(sya), true);
        ysUsde.setWithdrawer(address(sya), true);
    }

    function _seedYield() internal {
        sdola.addYield(YIELD_18);
        susde.addYield(YIELD_18);
        usdc.mint(address(autoUsdc), YIELD_USDC);
    }

    function _gateOff() internal {
        SyaGateOffLocal.turnGateOff(IStableYieldAccumulator(address(sya)), nft, keeper);
    }

    // ------------------------------------------------------------------
    // The Phase 11.17 sequence
    // ------------------------------------------------------------------

    function test_gatedBeforePhase_nftLessKeeperCannotClaim() public view {
        assertEq(sya.nftMinter(), address(nft), "Phase 8.7 gate set");
        assertTrue(nft.authorizedBurners(address(sya)), "SYA is a burner while gated");
        assertFalse(sya.canClaim(keeper), "NFT-less keeper cannot claim while gated");
    }

    function test_turnGateOff_clearsGate_revokesBurner_canClaimForAnyone() public {
        _gateOff();
        assertEq(sya.nftMinter(), address(0), "gate cleared");
        assertFalse(nft.authorizedBurners(address(sya)), "burner right revoked");
        assertTrue(sya.canClaim(keeper), "NFT-less keeper can claim");
        assertTrue(sya.canClaim(makeAddr("anyone")), "any EOA can claim");
    }

    function test_turnGateOff_revertsWhenGateNotOnNftMinterV2() public {
        _gateOff();
        // A second run must refuse, rather than silently re-clear: the precondition is the Phase 8.7 state.
        vm.expectRevert(bytes("story-130: SYA gate is not set to NFTMinterV2"));
        this.gateOffExternal();
    }

    function gateOffExternal() external {
        _gateOff();
    }

    // ------------------------------------------------------------------
    // Post-gate-off smoke
    // ------------------------------------------------------------------

    /// @notice The post-gate-off smoke: a keeper holding no claim NFT harvests with `nftIndex 0` at a
    ///         50 gwei gas price. All three strategies are claimed, DOLA and USDe are sold, ETH reaches the
    ///         keeper, SYA's reward sink is paid, and no NFT moves anywhere.
    function test_gateOff_nftLessKeeperHarvestsWithIndexZero_noNftMoves() public {
        _gateOff();
        _seedYield();

        assertEq(nft.balanceOf(keeper, NFT_INDEX), 0, "keeper holds no claim NFT");
        uint256 holderNftBefore = nft.balanceOf(holder, NFT_INDEX);
        uint256 keeperEthBefore = keeper.balance;
        uint256 phlimboBefore = usdc.balanceOf(address(phlimbo));
        uint256 dolaPoolBefore = dola.balanceOf(address(curveDola));
        uint256 usdePoolBefore = usde.balanceOf(address(s.curveUsdeCrvusd));

        vm.txGasPrice(50 gwei);
        vm.prank(keeper, keeper);
        uint256 ethOut = harvester.harvest(new address[](0), 0, 1);

        assertGt(ethOut, 0, "harvest paid ETH");
        assertEq(keeper.balance - keeperEthBefore, ethOut, "keeper received the ETH");
        assertGt(dola.balanceOf(address(curveDola)), dolaPoolBefore, "DOLA sold");
        assertGt(usde.balanceOf(address(s.curveUsdeCrvusd)), usdePoolBefore, "USDe sold");
        assertGt(usdc.balanceOf(address(phlimbo)), phlimboBefore, "SYA paid its reward sink");

        // No NFT moved: the keeper never had one, the holder kept theirs, the harvester holds none.
        assertEq(nft.balanceOf(keeper, NFT_INDEX), 0, "keeper still holds no NFT");
        assertEq(nft.balanceOf(holder, NFT_INDEX), holderNftBefore, "holder's NFT untouched");
        assertEq(nft.balanceOf(address(harvester), NFT_INDEX), 0, "harvester holds no NFT");

        // Pass-through: nothing left behind.
        assertEq(usdc.balanceOf(address(harvester)), 0, "harvester kept USDC");
        assertEq(dola.balanceOf(address(harvester)), 0, "harvester kept DOLA");
        assertEq(usde.balanceOf(address(harvester)), 0, "harvester kept USDe");
        assertEq(IERC20(address(s.crvUSD)).balanceOf(address(harvester)), 0, "harvester kept crvUSD");
        assertEq(address(harvester).balance, 0, "harvester kept ETH");

        IStableYieldAccumulator i = IStableYieldAccumulator(address(sya));
        assertLt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysDola)), 1e6, "DOLA yield harvested");
        assertLt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysUsde)), 1e6, "USDe yield harvested");
        assertLt(SyaHarvesterLocalConfig.claimAmountFor(i, address(ysUsdc)), 1e6, "USDC yield harvested");
    }

    /// @notice With the gate off, an NFT holder who passes a non-zero `nftIndex` keeps their NFT: the
    ///         harvester only moves an NFT when `sya.nftMinter()` is non-zero.
    function test_gateOff_holderWithNonZeroIndex_keepsNft() public {
        _gateOff();
        _seedYield();
        uint256 before = nft.balanceOf(holder, NFT_INDEX);

        vm.prank(holder, holder);
        harvester.harvest(new address[](0), NFT_INDEX, 1);

        assertEq(nft.balanceOf(holder, NFT_INDEX), before, "holder's NFT not burned or moved");
        assertEq(nft.balanceOf(address(harvester), NFT_INDEX), 0, "harvester holds no NFT");
    }
}
