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

        // Deploy BurnRecorder with nftMinter as the authorized minter
        burnRecorder = new BurnRecorder(owner, address(nftMinter));

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
        assertEq(names.length, 28, "Should return 28 field names");
    }

    function testGetNamesReturnsCorrectFieldNames() public view {
        string[] memory names = view_.getNames();

        // EYE fields
        assertEq(names[0], "EYE-allowance");
        assertEq(names[1], "EYE-price");
        assertEq(names[2], "EYE-growthBasisPoints");
        assertEq(names[3], "EYE-balance");
        assertEq(names[4], "EYE-nftBalance");

        // SCX fields
        assertEq(names[5], "SCX-allowance");
        assertEq(names[6], "SCX-price");
        assertEq(names[7], "SCX-growthBasisPoints");
        assertEq(names[8], "SCX-balance");
        assertEq(names[9], "SCX-nftBalance");

        // Flax fields
        assertEq(names[10], "Flax-allowance");
        assertEq(names[11], "Flax-price");
        assertEq(names[12], "Flax-growthBasisPoints");
        assertEq(names[13], "Flax-balance");
        assertEq(names[14], "Flax-nftBalance");

        // sUSDS fields
        assertEq(names[15], "sUSDS-allowance");
        assertEq(names[16], "sUSDS-price");
        assertEq(names[17], "sUSDS-growthBasisPoints");
        assertEq(names[18], "sUSDS-balance");
        assertEq(names[19], "sUSDS-nftBalance");

        // WBTC fields
        assertEq(names[20], "WBTC-allowance");
        assertEq(names[21], "WBTC-price");
        assertEq(names[22], "WBTC-growthBasisPoints");
        assertEq(names[23], "WBTC-balance");
        assertEq(names[24], "WBTC-nftBalance");

        // Burn totals
        assertEq(names[25], "EYE-totalBurnt");
        assertEq(names[26], "SCX-totalBurnt");
        assertEq(names[27], "Flax-totalBurnt");
    }

    function testGetDataReturnsCorrectCount() public view {
        uint256[] memory data = view_.getData(user);
        assertEq(data.length, 28, "Should return 28 data values");
    }

    function testGetDataWithZeroBalancesAndAllowances() public view {
        uint256[] memory data = view_.getData(user);

        // All allowances should be 0
        assertEq(data[0], 0, "EYE allowance should be 0");
        assertEq(data[5], 0, "SCX allowance should be 0");
        assertEq(data[10], 0, "Flax allowance should be 0");
        assertEq(data[15], 0, "sUSDS allowance should be 0");
        assertEq(data[20], 0, "WBTC allowance should be 0");

        // Prices should match registered values
        assertEq(data[1], 1 ether, "EYE price");
        assertEq(data[6], 2 ether, "SCX price");
        assertEq(data[11], 0.5 ether, "Flax price");
        assertEq(data[16], 10 ether, "sUSDS price");
        assertEq(data[21], 0.001 ether, "WBTC price");

        // Growth basis points should match registered values
        assertEq(data[2], 100, "EYE growthBasisPoints");
        assertEq(data[7], 200, "SCX growthBasisPoints");
        assertEq(data[12], 50, "Flax growthBasisPoints");
        assertEq(data[17], 300, "sUSDS growthBasisPoints");
        assertEq(data[22], 500, "WBTC growthBasisPoints");

        // All balances should be 0
        assertEq(data[3], 0, "EYE balance should be 0");
        assertEq(data[8], 0, "SCX balance should be 0");
        assertEq(data[13], 0, "Flax balance should be 0");
        assertEq(data[18], 0, "sUSDS balance should be 0");
        assertEq(data[23], 0, "WBTC balance should be 0");

        // All NFT balances should be 0
        assertEq(data[4], 0, "EYE nftBalance should be 0");
        assertEq(data[9], 0, "SCX nftBalance should be 0");
        assertEq(data[14], 0, "Flax nftBalance should be 0");
        assertEq(data[19], 0, "sUSDS nftBalance should be 0");
        assertEq(data[24], 0, "WBTC nftBalance should be 0");

        // All burn totals should be 0
        assertEq(data[25], 0, "EYE totalBurnt should be 0");
        assertEq(data[26], 0, "SCX totalBurnt should be 0");
        assertEq(data[27], 0, "Flax totalBurnt should be 0");
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
        assertEq(data[5], 20 ether, "SCX allowance");
        assertEq(data[10], 30 ether, "Flax allowance");
        assertEq(data[15], 40 ether, "sUSDS allowance");
        assertEq(data[20], 0.5 ether, "WBTC allowance");

        // Balances
        assertEq(data[3], 100 ether, "EYE balance");
        assertEq(data[8], 50 ether, "SCX balance");
        assertEq(data[13], 200 ether, "Flax balance");
        assertEq(data[18], 1000 ether, "sUSDS balance");
        assertEq(data[23], 5 ether, "WBTC balance");
    }

    function testGetDataWithDispatcherTokenIdOverride() public {
        // Set a custom token ID for the EYE dispatcher (index 1)
        uint256 customTokenId = 42;
        nftMinter.setDispatcherTokenId(address(dispatcherEYE), customTokenId);

        // The view should still work correctly even with an override
        uint256[] memory data = view_.getData(user);

        // NFT balance should be 0 (queried with overridden token ID)
        assertEq(data[4], 0, "EYE nftBalance with override should be 0");
    }

    function testGetNamesAndGetDataLengthsMatch() public view {
        string[] memory names = view_.getNames();
        uint256[] memory data = view_.getData(user);
        assertEq(names.length, data.length, "getNames and getData should return same length arrays");
    }
}
