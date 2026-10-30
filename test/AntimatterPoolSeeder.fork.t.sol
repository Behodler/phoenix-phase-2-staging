// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AntimatterPoolSeeder} from "../src/periphery/AntimatterPoolSeeder.sol";

interface IUniPoolerRescue {
    function rescueERC20(address token, address to, uint256 amount) external;
    function owner() external view returns (address);
}

interface IAntimatterAdmin {
    function setApprovedMinter(address minter, bool approved) external;
    function isApprovedMinter(address minter) external view returns (bool);
    function owner() external view returns (address);
}

interface IFactoryRead {
    function getPair(address, address) external view returns (address);
}

/**
 * @title AntimatterPoolSeederForkTest  (story 113)
 * @notice Mainnet fork (skipped without RPC_MAINNET). Runs the full owner sequence against the LIVE
 *         phUSD (FlaxToken: permissionless, allowance-gated burn), sUSDS, Antimatter, UniPooler and the
 *         canonical Uniswap V2 router/factory, with the Ledger OWNER pranked:
 *         `lpForBps` -> `UniPooler.rescueERC20` -> approve -> `Antimatter.setApprovedMinter` (+ verify)
 *         -> `seed`, twice (pair creation, then an add into the existing pair).
 */
contract AntimatterPoolSeederForkTest is Test {
    /// @dev Post-Balancexit, post-UniPooler-cutover block (story 113 planning read at 26_280_711).
    uint256 constant FORK_BLOCK = 26_280_700;
    uint256 constant BPS = 100; // 1% of the pooler's LP: a small rehearsal slice
    uint256 constant TOL_BPS = 50;

    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant ANTIMATTER = 0x9CA92B527012DfC6Fdca7B7493C722D5901FF151;
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant PAIR = 0x0b96b8ab66d40ba3C7501aa8C28Cdc37688F6F7f;
    address constant UNIPOOLER = 0x56997ea45091CBc01DB8a09E60DEDB8b3706a3D2;

    AntimatterPoolSeeder seeder;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(IUniPoolerRescue(UNIPOOLER).owner(), OWNER, "pooler owner");
        assertEq(IAntimatterAdmin(ANTIMATTER).owner(), OWNER, "antimatter owner");
        seeder = new AntimatterPoolSeeder(OWNER, PHUSD, SUSDS, ANTIMATTER, ROUTER, PAIR, UNIPOOLER);
        assertEq(seeder.factory(), FACTORY, "factory resolved from router");

        vm.prank(OWNER);
        IAntimatterAdmin(ANTIMATTER).setApprovedMinter(address(seeder), true);
        assertTrue(IAntimatterAdmin(ANTIMATTER).isApprovedMinter(address(seeder)), "grant verified");
    }

    /// @dev The owner sequence, with floors TOL_BPS under the pair-math quote.
    function _ownerSeed(uint256 bps) internal returns (uint256 burned, uint256 liquidity, uint256 lpAmount) {
        lpAmount = seeder.lpForBps(bps);
        assertGt(lpAmount, 0, "pooler holds LP");
        uint256 supply = IERC20(PAIR).totalSupply();
        uint256 minP = lpAmount * IERC20(PHUSD).balanceOf(PAIR) / supply * (10_000 - TOL_BPS) / 10_000;
        uint256 minS = lpAmount * IERC20(SUSDS).balanceOf(PAIR) / supply * (10_000 - TOL_BPS) / 10_000;
        assertGt(minP, 0);
        assertGt(minS, 0);

        vm.startPrank(OWNER);
        IUniPoolerRescue(UNIPOOLER).rescueERC20(PAIR, OWNER, lpAmount);
        IERC20(PAIR).approve(address(seeder), lpAmount);
        (burned, liquidity) = seeder.seed(lpAmount, minP, minS, minS, OWNER, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function _assertSeederEmpty() internal view {
        assertEq(IERC20(PHUSD).balanceOf(address(seeder)), 0, "seeder phUSD");
        assertEq(IERC20(ANTIMATTER).balanceOf(address(seeder)), 0, "seeder AM");
        assertEq(IERC20(SUSDS).balanceOf(address(seeder)), 0, "seeder sUSDS");
        assertEq(IERC20(PAIR).balanceOf(address(seeder)), 0, "seeder old LP");
        assertEq(IERC20(seeder.amSusdsPair()).balanceOf(address(seeder)), 0, "seeder new LP");
    }

    function test_fork_seed_mainnetOwnerSequence() public {
        assertEq(IFactoryRead(FACTORY).getPair(ANTIMATTER, SUSDS), address(0), "AM/sUSDS pair absent at fork block");
        uint256 phSupply = IERC20(PHUSD).totalSupply();
        uint256 amSupply = IERC20(ANTIMATTER).totalSupply();
        uint256 ownerSusds = IERC20(SUSDS).balanceOf(OWNER);

        (uint256 burned, uint256 liquidity,) = _ownerSeed(BPS);

        address amPair = IFactoryRead(FACTORY).getPair(ANTIMATTER, SUSDS);
        assertEq(seeder.amSusdsPair(), amPair);
        assertTrue(amPair != address(0), "pair created");
        assertGt(burned, 0);
        assertEq(phSupply - IERC20(PHUSD).totalSupply(), burned, "real FlaxToken burn: supply drops by AM minted");
        assertEq(IERC20(ANTIMATTER).totalSupply() - amSupply, burned, "AM minted 1:1");
        assertEq(IERC20(ANTIMATTER).balanceOf(amPair), burned, "all AM in the new pair");
        assertEq(IERC20(amPair).balanceOf(OWNER), liquidity, "OWNER holds the AM/sUSDS LP");
        assertEq(IERC20(SUSDS).balanceOf(OWNER), ownerSusds, "empty pair takes all sUSDS");
        _assertSeederEmpty();

        // Second slice into the now-existing pair.
        uint256 amInPair = IERC20(ANTIMATTER).balanceOf(amPair);
        (uint256 burned2, uint256 liquidity2,) = _ownerSeed(BPS);
        assertEq(IERC20(ANTIMATTER).balanceOf(amPair) - amInPair, burned2, "AM fully consumed on second seed");
        assertEq(IERC20(amPair).balanceOf(OWNER), liquidity + liquidity2);
        _assertSeederEmpty();
    }
}
