// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";

/// @title  LocalUniswapV4PoolManager
/// @notice Story 115. Uniswap V4's `PoolManager` (v4-core v4.0.0, the sya-harvester pin), unchanged, for
///         the anvil deployment. The subclass adds nothing: it exists so the PoolManager is a first-party
///         `src/` artifact that `vm.deployCode` can resolve by name (forge does not resolve the bare
///         `lib/` contract), and so it compiles in its own 0.8.26 unit.
/// @dev    Why not `new PoolManager(...)` in DeployMocks: PoolManager is `pragma solidity 0.8.26` EXACT,
///         while DeployMocks and everything it imports resolve to the repo's newest solc (0.8.30).
///         Importing it would force the whole script, and every contract it `new`s, onto 0.8.26.
///         `script/helpers/SyaHarvesterLocalStack.sol` instead deploys this artifact with
///         `vm.deployCode("LocalUniswapV4PoolManager.sol:LocalUniswapV4PoolManager", ...)` and talks to it
///         only through `IPoolManager` (`^0.8.0`).
contract LocalUniswapV4PoolManager is PoolManager {
    constructor(address initialOwner) PoolManager(initialOwner) {}
}
