// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {
    UniswapV2Deployer,
    IUniswapV2FactoryLike,
    IUniswapV2RouterLike
} from "../script/helpers/UniswapV2Deployer.sol";
import {MockEYE} from "../src/mocks/MockEYE.sol";
import {MockDola} from "../src/mocks/MockDola.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPairLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

/// @notice Validates the vendored canonical Uniswap V2 creation-bytecode artifacts deploy on a
///         bare chain AND that the Factory init-code hash matches Router02 (a real swap routes
///         through the router-resolved pair). If the hash were wrong, addLiquidity would deploy
///         the pair at one address while the router looked it up at another and the swap reverts.
contract UniswapV2DeployerTest is Test {
    address internal deployer = address(0xBEEF);

    function test_deploy_seed_and_swap() public {
        vm.startPrank(deployer);
        (, IUniswapV2FactoryLike factory, IUniswapV2RouterLike router) = UniswapV2Deployer.deploy(deployer);

        assertEq(router.factory(), address(factory), "router.factory mismatch");

        MockEYE eye = new MockEYE();
        MockDola dola = new MockDola();

        // createPair BEFORE seeding (Uniboost reads token0/token1 in its constructor).
        address pair = factory.createPair(address(eye), address(dola));
        assertEq(factory.getPair(address(eye), address(dola)), pair, "getPair != createPair");

        uint256 amtEye = 1_000_000e18;
        uint256 amtDola = 1_000_000e18;
        eye.mint(deployer, amtEye);
        dola.mint(deployer, amtDola);

        IERC20(address(eye)).approve(address(router), amtEye);
        IERC20(address(dola)).approve(address(router), amtDola);
        (,, uint256 liquidity) =
            router.addLiquidity(address(eye), address(dola), amtEye, amtDola, 0, 0, deployer, block.timestamp);
        assertGt(liquidity, 0, "no LP minted");

        (uint112 r0, uint112 r1,) = IPairLike(pair).getReserves();
        assertGt(r0, 0, "reserve0 empty");
        assertGt(r1, 0, "reserve1 empty");

        // The decisive check: a swap routed through the router-resolved pair. This only works if
        // the Factory's pair init-code hash matches Router02's UniswapV2Library.pairFor hash.
        uint256 swapIn = 1_000e18;
        eye.mint(deployer, swapIn);
        IERC20(address(eye)).approve(address(router), swapIn);
        address[] memory path = new address[](2);
        path[0] = address(eye);
        path[1] = address(dola);
        uint256 before = dola.balanceOf(deployer);
        router.swapExactTokensForTokens(swapIn, 1, path, deployer, block.timestamp);
        assertGt(dola.balanceOf(deployer), before, "swap produced no DOLA (init-code hash mismatch?)");

        vm.stopPrank();
    }
}
