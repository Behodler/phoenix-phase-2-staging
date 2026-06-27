// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "@forge-std/Vm.sol";

/// @notice Minimal Uniswap V2 Factory interface (creation/lookup of pairs).
interface IUniswapV2FactoryLike {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function feeToSetter() external view returns (address);
}

/// @notice Minimal Uniswap V2 Router02 interface used by the local deploy (seed + swap + topology).
interface IUniswapV2RouterLike {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Minimal WETH9 deposit interface (wrap native ETH into WETH for seeding).
interface IWETH9Like {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title UniswapV2Deployer
/// @notice Deploys the CANONICAL Uniswap V2 stack (WETH9 + Factory + Router02) from vendored
///         creation-bytecode artifacts onto a local chain (anvil 31337). Using the canonical
///         artifacts is essential: the Factory's pair init-code hash must match the hash
///         baked into Router02's `UniswapV2Library.pairFor`, otherwise router-resolved pair
///         addresses are wrong and every swap/addLiquidity breaks. Story 070.
/// @dev Library so `DeployMocks` can call it inside its broadcast without growing its own stack.
///      `vm.deployCode` reads the JSONs from `script/uniswap-artifacts/` (whitelisted in
///      foundry.toml `fs_permissions`).
library UniswapV2Deployer {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Deploys WETH9, the Factory (feeToSetter = `feeToSetter`), and Router02 (factory, weth9).
    function deploy(address feeToSetter)
        internal
        returns (address weth9, IUniswapV2FactoryLike factory, IUniswapV2RouterLike router)
    {
        weth9 = vm.deployCode("script/uniswap-artifacts/WETH9.json");
        address factoryAddr = vm.deployCode("script/uniswap-artifacts/UniswapV2Factory.json", abi.encode(feeToSetter));
        address routerAddr =
            vm.deployCode("script/uniswap-artifacts/UniswapV2Router02.json", abi.encode(factoryAddr, weth9));
        factory = IUniswapV2FactoryLike(factoryAddr);
        router = IUniswapV2RouterLike(routerAddr);
    }
}
