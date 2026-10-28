// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV2Deployer, IUniswapV2FactoryLike, IUniswapV2RouterLike} from "../script/helpers/UniswapV2Deployer.sol";
import {DeployUniswapHelperSepolia} from "../script/DeployUniswapHelperSepolia.s.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";
import {MockRewardToken} from "../src/mocks/MockRewardToken.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSUSDS} from "../src/mocks/MockSUSDS.sol";
import {MockDola} from "../src/mocks/MockDola.sol";
import {MockUSDe} from "../src/mocks/MockUSDe.sol";
import {MockSkyPSM} from "../src/mocks/MockSkyPSM.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
import {UniswapHelper} from "../src/periphery/UniswapHelper.sol";

/// @dev Pins the progress path (never the real progress.11155111.json), the deployer key and the WETH
///      reserve (never the process-wide SEPOLIA_WETH_SEED env, which races parallel suites).
contract DeployUniswapHelperSepoliaHarness is DeployUniswapHelperSepolia {
    string internal progressPath;
    uint256 internal immutable key;
    uint256 internal immutable wethReserve;
    bool internal preview;

    constructor(string memory progressPath_, uint256 key_, uint256 wethReserve_) {
        progressPath = progressPath_;
        key = key_;
        wethReserve = wethReserve_;
    }

    function _progressFile() internal view override returns (string memory) {
        return progressPath;
    }

    function _deployerKey() internal view override returns (uint256) {
        return key;
    }

    function _wethReserve() internal view override returns (uint256) {
        return wethReserve;
    }

    function _previewMode() internal view override returns (bool) {
        return preview;
    }

    function setPreview(bool p) external {
        preview = p;
    }
}

/// @title  DeployUniswapHelperSepoliaTest
/// @notice The Sepolia add-on deploys UniswapHelper + its venue mocks against the addresses a
///         DeployMocksSepolia progress file names, appends them to that file, and is a no-op on re-run.
contract DeployUniswapHelperSepoliaTest is Test {
    /// @dev Per-test path: forge runs a contract's tests in parallel, so a shared file would race.
    string internal PROGRESS;
    uint256 internal constant RESERVE = 0.4 ether;

    uint256 internal deployerKey = 0xA11CE;
    address internal deployer;

    MockPhUSD internal phUSD;
    MockRewardToken internal usdc;
    MockUSDS internal usds;
    MockSUSDS internal susds;
    MockDola internal dola;
    MockUSDe internal usde;
    MockSkyPSM internal psm;
    address internal weth;
    IUniswapV2RouterLike internal router;
    address internal pair;
    Antimatter internal am;

    function setUp() public {
        vm.chainId(11155111);
        deployer = vm.addr(deployerKey);
        vm.deal(deployer, 10 ether);

        IUniswapV2FactoryLike factory;
        (weth, factory, router) = UniswapV2Deployer.deploy(address(this));
        phUSD = new MockPhUSD();
        phUSD.setMinter(address(this), true);
        usdc = new MockRewardToken();
        usds = new MockUSDS();
        susds = new MockSUSDS(address(usds));
        dola = new MockDola();
        usde = new MockUSDe();
        psm = new MockSkyPSM(address(usdc), address(usds));
        usdc.mint(address(psm), 1_000_000e6);
        am = new Antimatter(address(this)); // story 120: read from the progress file's "Antimatter" key

        usds.mint(address(this), 2_000e18);
        usds.approve(address(susds), type(uint256).max);
        uint256 shares = susds.deposit(2_000e18, address(this));
        phUSD.mint(address(this), 2_000e18);
        pair = factory.createPair(address(susds), address(phUSD));
        IERC20(address(susds)).approve(address(router), type(uint256).max);
        phUSD.approve(address(router), type(uint256).max);
        router.addLiquidity(address(susds), address(phUSD), shares, 2_000e18, 0, 0, address(this), block.timestamp);
    }

    /// @dev Points this test at its own progress file and writes the baseline into it.
    function _begin(string memory tag) internal {
        PROGRESS = string.concat("server/deployments/test-progress.uniswap-helper-sepolia.", tag, ".json");
        vm.writeFile(PROGRESS, _progressJson(""));
    }

    function _cleanup() internal {
        if (vm.exists(PROGRESS)) vm.removeFile(PROGRESS);
    }

    /// @dev The DeployMocksSepolia progress-file shape, with only the entries the add-on reads plus one it
    ///      must leave alone (MockEYE), and an optional extra tail of entries.
    function _progressJson(string memory extra) internal view returns (string memory) {
        return string.concat(
            '{"chainId": 11155111,"networkName": "sepolia","deploymentStatus": "completed","contracts": {',
            _entry("MockPhUSD", address(phUSD)),
            ",",
            _entry("MockUSDC", address(usdc)),
            ",",
            _entry("MockUSDS", address(usds)),
            ",",
            _entry("MockSUSDS", address(susds)),
            ",",
            _entry("USDe", address(usde)),
            ",",
            _entry("MockDola", address(dola)),
            ",",
            _entry("MockEYE", address(0xE1E)),
            ",",
            _entry("WETH9", weth),
            ",",
            _entry("UniswapV2Router02", address(router)),
            ",",
            _entry("PhusdSusdsPair", pair),
            ",",
            _entry("MockSkyPSM", address(psm)),
            ",",
            _entry("Antimatter", address(am)),
            extra,
            "}}"
        );
    }

    function _entry(string memory name, address a) internal pure returns (string memory) {
        return string.concat(
            '"',
            name,
            '": {"address": "',
            vm.toString(a),
            '","deployed": true,"configured": true,"deployGas": 0,"configGas": 0}'
        );
    }

    function _run() internal returns (DeployUniswapHelperSepoliaHarness s) {
        s = new DeployUniswapHelperSepoliaHarness(PROGRESS, deployerKey, RESERVE);
        s.run();
    }

    function _recorded(string memory name) internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(PROGRESS), string.concat(".contracts.", name, ".address"));
    }

    function test_deploysHelperWiredToProgressAddresses() public {
        _begin("test_deploysHelperWiredToProgressAddresses");
        _run();
        UniswapHelper h = UniswapHelper(payable(_recorded("UniswapHelper")));
        assertGt(address(h).code.length, 0, "helper code");
        assertEq(h.pair(), pair, "pair");
        assertEq(h.skyPSM(), address(psm), "psm");
        assertEq(h.phUSD(), address(phUSD), "phUSD");
        assertEq(h.v2Router(), address(router), "v2 router");
        assertEq(h.antimatter(), address(am), "antimatter");
        assertEq(h.amPair(), address(0), "no AM pair on Sepolia");
        _cleanup();
    }

    function test_recordsVenueMocksAndKeepsExistingEntries() public {
        _begin("test_recordsVenueMocksAndKeepsExistingEntries");
        _run();
        assertEq(_recorded("MockEYE"), address(0xE1E), "existing entry kept");
        assertEq(_recorded("MockPhUSD"), address(phUSD), "existing entry kept");
        assertGt(_recorded("MockUniswapV3SwapRouter").code.length, 0, "v3 router");
        assertGt(_recorded("MockUniswapV3QuoterV2").code.length, 0, "v3 quoter");
        assertGt(_recorded("MockCurveDolaMetaPool").code.length, 0, "curve dola");
        assertGt(_recorded("MockCurveStableSwapNG").code.length, 0, "curve usde");
        _cleanup();
    }

    function test_v3RouterReserveIsTheSuppliedWethSeed() public {
        _begin("test_v3RouterReserveIsTheSuppliedWethSeed");
        _run();
        address v3 = _recorded("MockUniswapV3SwapRouter");
        assertEq(IERC20(weth).balanceOf(v3), RESERVE, "WETH reserve");
        assertEq(usdc.balanceOf(v3), 800e6, "USDC side at 2000 USDC/ETH");
        _cleanup();
    }

    function test_topsUpDeployerDemoBalances() public {
        _begin("test_topsUpDeployerDemoBalances");
        _run();
        assertGe(dola.balanceOf(deployer), 10_000e18, "DOLA");
        assertGe(usdc.balanceOf(deployer), 10_000e6, "USDC");
        assertGe(IERC20(address(susds)).balanceOf(deployer), 10_000e18, "sUSDS");
        _cleanup();
    }

    function test_rerunIsNoop() public {
        _begin("test_rerunIsNoop");
        _run();
        address first = _recorded("UniswapHelper");
        string memory before = vm.readFile(PROGRESS);
        _run();
        assertEq(_recorded("UniswapHelper"), first, "helper unchanged");
        assertEq(keccak256(bytes(vm.readFile(PROGRESS))), keccak256(bytes(before)), "progress unchanged");
        _cleanup();
    }

    function test_previewModeLeavesProgressUntouched() public {
        _begin("test_previewModeLeavesProgressUntouched");
        string memory before = vm.readFile(PROGRESS);
        DeployUniswapHelperSepoliaHarness s = new DeployUniswapHelperSepoliaHarness(PROGRESS, deployerKey, RESERVE);
        s.setPreview(true);
        s.run();
        assertEq(keccak256(bytes(vm.readFile(PROGRESS))), keccak256(bytes(before)), "progress unchanged");
        _cleanup();
    }

    function test_revertsWhenRecordedHelperHasNoCode() public {
        _begin("test_revertsWhenRecordedHelperHasNoCode");
        vm.writeFile(PROGRESS, _progressJson(string.concat(",", _entry("UniswapHelper", address(0xBEEF)))));
        DeployUniswapHelperSepoliaHarness s = new DeployUniswapHelperSepoliaHarness(PROGRESS, deployerKey, RESERVE);
        vm.expectRevert(bytes("DeployUniswapHelperSepolia: recorded UniswapHelper has no code"));
        s.run();
        _cleanup();
    }

    function test_revertsOffSepolia() public {
        _begin("test_revertsOffSepolia");
        vm.chainId(1);
        DeployUniswapHelperSepoliaHarness s = new DeployUniswapHelperSepoliaHarness(PROGRESS, deployerKey, RESERVE);
        vm.expectRevert(bytes("DeployUniswapHelperSepolia: sepolia only"));
        s.run();
        _cleanup();
    }

    function test_revertsWhenDependencyHasNoCode() public {
        _begin("test_revertsWhenDependencyHasNoCode");
        vm.etch(address(psm), "");
        DeployUniswapHelperSepoliaHarness s = new DeployUniswapHelperSepoliaHarness(PROGRESS, deployerKey, RESERVE);
        vm.expectRevert(bytes("DeployUniswapHelperSepolia: MockSkyPSM has no code"));
        s.run();
        _cleanup();
    }

    function test_revertsWhenDeployerCannotFundReserve() public {
        _begin("test_revertsWhenDeployerCannotFundReserve");
        vm.deal(deployer, 0.1 ether);
        DeployUniswapHelperSepoliaHarness s = new DeployUniswapHelperSepoliaHarness(PROGRESS, deployerKey, RESERVE);
        vm.expectRevert(bytes("DeployUniswapHelperSepolia: deployer ETH below SEPOLIA_WETH_SEED"));
        s.run();
        _cleanup();
    }
}
