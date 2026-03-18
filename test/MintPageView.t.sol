// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Test.sol";
import "../src/views/MintPageView.sol";
import "../src/views/IPageView.sol";
import "@yield-claim-nft/interfaces/INFTMinter.sol";
import "@yield-claim-nft/BurnRecorder.sol";
import "@yield-claim-nft/NFTMinter.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC20 mock for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal mock dispatcher that satisfies ITokenDispatcher.primeToken().
contract MockDispatcher {
    address public primeToken;
    bool public paused;

    constructor(address _primeToken) {
        primeToken = _primeToken;
    }

    function name() external pure returns (string memory) {
        return "MockDispatcher";
    }

    function image() external pure returns (string memory) {
        return "";
    }

    function description() external pure returns (string memory) {
        return "";
    }

    function pause() external {
        paused = true;
    }

    function unpause() external {
        paused = false;
    }
}

contract MintPageViewTest is Test {
    MintPageView public view_;
    NFTMinter public nftMinter;
    BurnRecorder public burnRecorder;

    MockERC20 public eye;
    MockERC20 public scx;
    MockERC20 public flax;
    MockERC20 public susds;
    MockERC20 public wbtc;

    MockDispatcher public dispatcherEYE;
    MockDispatcher public dispatcherSCX;
    MockDispatcher public dispatcherFlax;
    MockDispatcher public dispatcherSUSDS;
    MockDispatcher public dispatcherWBTC;

    address public user = makeAddr("user");
    address public owner;

    function setUp() public {
        owner = address(this);

        // Deploy mock tokens
        eye = new MockERC20("EYE", "EYE");
        scx = new MockERC20("SCX", "SCX");
        flax = new MockERC20("Flax", "FLAX");
        susds = new MockERC20("sUSDS", "sUSDS");
        wbtc = new MockERC20("WBTC", "WBTC");

        // Deploy NFTMinter
        nftMinter = new NFTMinter(owner);

        // Deploy BurnRecorder
        burnRecorder = new BurnRecorder(owner);

        // Deploy mock dispatchers
        dispatcherEYE = new MockDispatcher(address(eye));
        dispatcherSCX = new MockDispatcher(address(scx));
        dispatcherFlax = new MockDispatcher(address(flax));
        dispatcherSUSDS = new MockDispatcher(address(susds));
        dispatcherWBTC = new MockDispatcher(address(wbtc));

        // Register dispatchers in order: index 1=EYE, 2=SCX, 3=Flax, 4=sUSDS, 5=WBTC
        nftMinter.registerDispatcher(address(dispatcherEYE), 1 ether, 100); // 1%
        nftMinter.registerDispatcher(address(dispatcherSCX), 2 ether, 200); // 2%
        nftMinter.registerDispatcher(address(dispatcherFlax), 0.5 ether, 50); // 0.5%
        nftMinter.registerDispatcher(address(dispatcherSUSDS), 10 ether, 300); // 3%
        nftMinter.registerDispatcher(address(dispatcherWBTC), 0.001 ether, 500); // 5%

        // Deploy MintPageView
        view_ = new MintPageView(
            INFTMinter(address(nftMinter)),
            burnRecorder,
            address(eye),
            address(scx),
            address(flax),
            address(susds),
            address(wbtc)
        );
    }

    function testGetNamesReturnsCorrectCount() public view {
        string[] memory names = view_.getNames();
        assertEq(names.length, 33, "Should return 33 field names");
    }

    function testGetNamesReturnsCorrectFieldNames() public view {
        string[] memory names = view_.getNames();

        // EYE fields
        assertEq(names[0], "EYE-allowance");
        assertEq(names[1], "EYE-price");
        assertEq(names[2], "EYE-growthBasisPoints");
        assertEq(names[3], "EYE-balance");
        assertEq(names[4], "EYE-nftBalance");
        assertEq(names[5], "EYE-dispatcherIndex");

        // SCX fields
        assertEq(names[6], "SCX-allowance");
        assertEq(names[7], "SCX-price");
        assertEq(names[8], "SCX-growthBasisPoints");
        assertEq(names[9], "SCX-balance");
        assertEq(names[10], "SCX-nftBalance");
        assertEq(names[11], "SCX-dispatcherIndex");

        // Flax fields
        assertEq(names[12], "Flax-allowance");
        assertEq(names[13], "Flax-price");
        assertEq(names[14], "Flax-growthBasisPoints");
        assertEq(names[15], "Flax-balance");
        assertEq(names[16], "Flax-nftBalance");
        assertEq(names[17], "Flax-dispatcherIndex");

        // sUSDS fields
        assertEq(names[18], "sUSDS-allowance");
        assertEq(names[19], "sUSDS-price");
        assertEq(names[20], "sUSDS-growthBasisPoints");
        assertEq(names[21], "sUSDS-balance");
        assertEq(names[22], "sUSDS-nftBalance");
        assertEq(names[23], "sUSDS-dispatcherIndex");

        // WBTC fields
        assertEq(names[24], "WBTC-allowance");
        assertEq(names[25], "WBTC-price");
        assertEq(names[26], "WBTC-growthBasisPoints");
        assertEq(names[27], "WBTC-balance");
        assertEq(names[28], "WBTC-nftBalance");
        assertEq(names[29], "WBTC-dispatcherIndex");

        // Burn totals
        assertEq(names[30], "EYE-totalBurnt");
        assertEq(names[31], "SCX-totalBurnt");
        assertEq(names[32], "Flax-totalBurnt");
    }

    function testGetDataReturnsCorrectCount() public view {
        uint256[] memory data = view_.getData(user);
        assertEq(data.length, 33, "Should return 33 data values");
    }

    function testGetDataWithZeroBalancesAndAllowances() public view {
        uint256[] memory data = view_.getData(user);

        // All allowances should be 0
        assertEq(data[0], 0, "EYE allowance should be 0");
        assertEq(data[6], 0, "SCX allowance should be 0");
        assertEq(data[12], 0, "Flax allowance should be 0");
        assertEq(data[18], 0, "sUSDS allowance should be 0");
        assertEq(data[24], 0, "WBTC allowance should be 0");

        // Prices should match registered values
        assertEq(data[1], 1 ether, "EYE price");
        assertEq(data[7], 2 ether, "SCX price");
        assertEq(data[13], 0.5 ether, "Flax price");
        assertEq(data[19], 10 ether, "sUSDS price");
        assertEq(data[25], 0.001 ether, "WBTC price");

        // Growth basis points should match registered values
        assertEq(data[2], 100, "EYE growthBasisPoints");
        assertEq(data[8], 200, "SCX growthBasisPoints");
        assertEq(data[14], 50, "Flax growthBasisPoints");
        assertEq(data[20], 300, "sUSDS growthBasisPoints");
        assertEq(data[26], 500, "WBTC growthBasisPoints");

        // All balances should be 0
        assertEq(data[3], 0, "EYE balance should be 0");
        assertEq(data[9], 0, "SCX balance should be 0");
        assertEq(data[15], 0, "Flax balance should be 0");
        assertEq(data[21], 0, "sUSDS balance should be 0");
        assertEq(data[27], 0, "WBTC balance should be 0");

        // All NFT balances should be 0
        assertEq(data[4], 0, "EYE nftBalance should be 0");
        assertEq(data[10], 0, "SCX nftBalance should be 0");
        assertEq(data[16], 0, "Flax nftBalance should be 0");
        assertEq(data[22], 0, "sUSDS nftBalance should be 0");
        assertEq(data[28], 0, "WBTC nftBalance should be 0");

        // Dispatcher indices
        assertEq(data[5], 1, "EYE dispatcherIndex should be 1");
        assertEq(data[11], 2, "SCX dispatcherIndex should be 2");
        assertEq(data[17], 3, "Flax dispatcherIndex should be 3");
        assertEq(data[23], 4, "sUSDS dispatcherIndex should be 4");
        assertEq(data[29], 5, "WBTC dispatcherIndex should be 5");

        // All burn totals should be 0
        assertEq(data[30], 0, "EYE totalBurnt should be 0");
        assertEq(data[31], 0, "SCX totalBurnt should be 0");
        assertEq(data[32], 0, "Flax totalBurnt should be 0");
    }

    function testGetDataReturnsCorrectValuesForMockScenario() public {
        // Give user some token balances
        eye.mint(user, 100 ether);
        scx.mint(user, 50 ether);
        flax.mint(user, 200 ether);
        susds.mint(user, 1000 ether);
        wbtc.mint(user, 5 ether);

        // Set allowances
        vm.startPrank(user);
        eye.approve(address(nftMinter), 10 ether);
        scx.approve(address(nftMinter), 20 ether);
        flax.approve(address(nftMinter), 30 ether);
        susds.approve(address(nftMinter), 40 ether);
        wbtc.approve(address(nftMinter), 0.5 ether);
        vm.stopPrank();

        uint256[] memory data = view_.getData(user);

        // Allowances
        assertEq(data[0], 10 ether, "EYE allowance");
        assertEq(data[6], 20 ether, "SCX allowance");
        assertEq(data[12], 30 ether, "Flax allowance");
        assertEq(data[18], 40 ether, "sUSDS allowance");
        assertEq(data[24], 0.5 ether, "WBTC allowance");

        // Balances
        assertEq(data[3], 100 ether, "EYE balance");
        assertEq(data[9], 50 ether, "SCX balance");
        assertEq(data[15], 200 ether, "Flax balance");
        assertEq(data[21], 1000 ether, "sUSDS balance");
        assertEq(data[27], 5 ether, "WBTC balance");

        // Dispatcher indices
        assertEq(data[5], 1, "EYE dispatcherIndex");
        assertEq(data[11], 2, "SCX dispatcherIndex");
        assertEq(data[17], 3, "Flax dispatcherIndex");
        assertEq(data[23], 4, "sUSDS dispatcherIndex");
        assertEq(data[29], 5, "WBTC dispatcherIndex");
    }

    function testGetNamesAndGetDataLengthsMatch() public view {
        string[] memory names = view_.getNames();
        uint256[] memory data = view_.getData(user);
        assertEq(names.length, data.length, "getNames and getData should return same length arrays");
    }
}
