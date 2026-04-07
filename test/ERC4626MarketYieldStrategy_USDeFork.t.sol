// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*//////////////////////////////////////////////////////////////////////////
    ERC4626MarketYieldStrategy_USDeFork
    ------------------------------------
    Mainnet-fork integration test for `ERC4626MarketYieldStrategy` configured
    for USDe -> sUSDe via the live `CurveAMMAdapter` + Curve Router NG.

    Configuration choices:
    * Fork block:              24_800_000 (pinned for determinism / CI stability).
                               Verified that pool1 (0xF55B...442) has
                               coin0=USDe, coin1=crvUSD and pool2 (0x5706...E85)
                               has coin0=crvUSD, coin1=sUSDe at this block via
                               `cast call coins(uint256)` — indices match the
                               swapParams [0,1,...] / [1,0,...] pairs copied
                               from lib/vault/AMMRoutes.json.

    * USDe funding approach:   `deal(USDe, client, amount, true)` (with the
                               adjust-totalSupply flag). USDe is a standard
                               ERC20-upgradeable token whose balance mapping
                               is writable by Foundry's deal cheatcode — the
                               test asserts the balance after deal to fail
                               fast if the implementation ever changes. No
                               whale impersonation is needed at this block.

    * Slippage tolerance:      100 bps (1%). This is the same value used by
                               the in-repo mock test and is sufficient for the
                               live USDe/crvUSD/sUSDe route at the chosen fork
                               block. If the block is bumped and the route
                               becomes imbalanced, raise to 200 bps.

    * Yield simulation:        USDe donation to sUSDe contract + `vm.warp`
                               past the vesting window. Ethena's StakedUSDe
                               computes `totalAssets = balanceOf(this) -
                               getUnvestedAmount()`; donated USDe is absorbed
                               into the balance and, after warping past
                               `lastDistributionTimestamp + VESTING_PERIOD`
                               (8 hours), `getUnvestedAmount() == 0`, so
                               `totalAssets` increases by the donated amount.
                               This avoids touching sUSDe internal storage.

    Scope discipline:
    * This test does NOT modify any contracts in `lib/vault/`.
    * It does NOT add mocks or helpers to `src/`.
    * It does NOT wire the strategy into StableYieldAccumulator or any other
      live protocol contract. This is a standalone integration test only.

    Run:
        source .envrc
        forge test --fork-url $RPC_MAINNET \
            --match-contract ERC4626MarketYieldStrategy_USDeFork -vvv
//////////////////////////////////////////////////////////////////////////*/

import "@forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import "@vault/AMMAdapters/CurveAMMAdapter.sol";

/// @notice Minimal view surface on Ethena's sUSDe used only for yield sim introspection.
interface ISUSDeView {
    function getUnvestedAmount() external view returns (uint256);
    function lastDistributionTimestamp() external view returns (uint256);
}

contract ERC4626MarketYieldStrategy_USDeFork is Test {
    // ── Pinned fork block ──
    uint256 constant FORK_BLOCK = 24_800_000;

    // ── Mainnet addresses ──
    address constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant CRV_USD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CURVE_ROUTER_NG = 0x16C6521Dff6baB339122a0FE25a9116693265353;
    address constant POOL_USDE_CRVUSD = 0xF55B0f6F2Da5ffDDb104b58a60F2862745960442; // coin0=USDe, coin1=crvUSD
    address constant POOL_CRVUSD_SUSDE = 0x57064F49Ad7123C92560882a45518374ad982e85; // coin0=crvUSD, coin1=sUSDe

    // ── Test config ──
    uint256 constant SLIPPAGE_BPS = 100; // 1%
    uint256 constant CLIENT_INITIAL_USDE = 1_000_000e18;

    // ── Actors ──
    address owner;
    address client;

    // ── Contracts under test ──
    CurveAMMAdapter adapter;
    ERC4626MarketYieldStrategy strategy;

    function setUp() public {
        // Pin the fork block for determinism.
        vm.createSelectFork(vm.envString("RPC_MAINNET"), FORK_BLOCK);

        owner = makeAddr("owner");
        client = makeAddr("client");

        _deployStrategyStack();
        _configureRoutes(adapter);
        _fundClientAndApprove();

        // Sanity check: pool coin indices match the swapParams direction
        // (coin0 -> coin1 for forward path, coin1 -> coin0 for reverse).
        // If this ever fails the deployment payload in AMMRoutes.json is out of sync.
        assertEq(_coin(POOL_USDE_CRVUSD, 0), USDE, "pool1 coin0 should be USDe");
        assertEq(_coin(POOL_USDE_CRVUSD, 1), CRV_USD, "pool1 coin1 should be crvUSD");
        assertEq(_coin(POOL_CRVUSD_SUSDE, 0), CRV_USD, "pool2 coin0 should be crvUSD");
        assertEq(_coin(POOL_CRVUSD_SUSDE, 1), SUSDE, "pool2 coin1 should be sUSDe");
    }

    // ============================================================
    //                         setUp helpers
    // ============================================================

    function _deployStrategyStack() internal {
        vm.startPrank(owner);
        adapter = new CurveAMMAdapter(owner, CURVE_ROUTER_NG);
        strategy = new ERC4626MarketYieldStrategy(owner, USDE, SUSDE, address(adapter));
        strategy.setClient(client, true);
        strategy.setSlippageTolerance(SLIPPAGE_BPS);
        vm.stopPrank();
    }

    /// @dev Configure adapter with the exact payload from `lib/vault/AMMRoutes.json`
    ///      for USDe <-> sUSDe. Both directions are required for the strategy to
    ///      accept any deposit (bidirectional invariant in CurveAMMAdapter).
    /// @dev keep in sync with AMMRoutes.json
    function _configureRoutes(CurveAMMAdapter _adapter) internal {
        // ── Forward: USDe -> sUSDe ──
        // path[0]  = USDe
        // path[1]  = pool USDe/crvUSD
        // path[2]  = crvUSD
        // path[3]  = pool crvUSD/sUSDe
        // path[4]  = sUSDe
        // swapParams[0] = [0,1,1,10,2] — pool1: coin0(USDe) -> coin1(crvUSD), stableswap-ng exchange
        // swapParams[1] = [0,1,1,10,2] — pool2: coin0(crvUSD) -> coin1(sUSDe), stableswap-ng exchange
        // pools         = [0,0,0,0,0]
        address[11] memory fwdPath;
        fwdPath[0] = USDE;
        fwdPath[1] = POOL_USDE_CRVUSD;
        fwdPath[2] = CRV_USD;
        fwdPath[3] = POOL_CRVUSD_SUSDE;
        fwdPath[4] = SUSDE;

        uint256[5][5] memory fwdParams;
        fwdParams[0] = [uint256(0), 1, 1, 10, 2];
        fwdParams[1] = [uint256(0), 1, 1, 10, 2];

        address[5] memory emptyPools;

        // ── Reverse: sUSDe -> USDe ──
        // path[0]  = sUSDe
        // path[1]  = pool crvUSD/sUSDe
        // path[2]  = crvUSD
        // path[3]  = pool USDe/crvUSD
        // path[4]  = USDe
        // swapParams[0] = [1,0,1,10,2] — pool2: coin1(sUSDe) -> coin0(crvUSD)
        // swapParams[1] = [1,0,1,10,2] — pool1: coin1(crvUSD) -> coin0(USDe)
        // pools         = [0,0,0,0,0]
        address[11] memory revPath;
        revPath[0] = SUSDE;
        revPath[1] = POOL_CRVUSD_SUSDE;
        revPath[2] = CRV_USD;
        revPath[3] = POOL_USDE_CRVUSD;
        revPath[4] = USDE;

        uint256[5][5] memory revParams;
        revParams[0] = [uint256(1), 0, 1, 10, 2];
        revParams[1] = [uint256(1), 0, 1, 10, 2];

        vm.startPrank(owner);
        _adapter.setRoute(USDE, SUSDE, fwdPath, fwdParams, emptyPools);
        _adapter.setRoute(SUSDE, USDE, revPath, revParams, emptyPools);
        vm.stopPrank();
    }

    function _fundClientAndApprove() internal {
        // `deal` with the adjust-totalSupply flag works against standard ERC20
        // storage layouts. USDe's implementation stores balances in a plain
        // mapping; deal overwrites the slot directly. Asserting the balance
        // here fails fast if a future USDe upgrade breaks this assumption.
        deal(USDE, client, CLIENT_INITIAL_USDE, true);
        assertEq(IERC20(USDE).balanceOf(client), CLIENT_INITIAL_USDE, "deal() failed to fund client with USDe");

        vm.prank(client);
        IERC20(USDE).approve(address(strategy), type(uint256).max);
    }

    function _coin(address pool, uint256 i) internal view returns (address c) {
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("coins(uint256)", i));
        require(ok, "coins() call failed");
        c = abi.decode(data, (address));
    }

    // ============================================================
    //                         Test 1: deposit
    // ============================================================

    function testHappyPathDeposit() public {
        uint256 depositAmount = 100_000e18;

        vm.prank(client);
        strategy.deposit(USDE, depositAmount, client);

        assertEq(strategy.principalOf(USDE, client), depositAmount, "principal should equal deposit");
        assertGt(IERC20(SUSDE).balanceOf(address(strategy)), 0, "strategy should hold sUSDe shares");

        // totalBalanceOf reads convertToAssets on sUSDe: starts roughly equal
        // to principal (minus slippage / AMM spread), not below slippage tolerance.
        uint256 totalBal = strategy.totalBalanceOf(USDE, client);
        assertApproxEqAbs(
            totalBal, depositAmount, (depositAmount * SLIPPAGE_BPS) / 10_000, "totalBalanceOf within slippage of deposit"
        );
    }

    // ============================================================
    //                   Test 2: deposit -> withdraw
    // ============================================================

    function testRoundTripWithdraw() public {
        uint256 depositAmount = 100_000e18;

        vm.prank(client);
        strategy.deposit(USDE, depositAmount, client);

        uint256 clientUsdeBefore = IERC20(USDE).balanceOf(client);

        vm.prank(client);
        strategy.withdraw(USDE, depositAmount, client);

        assertEq(strategy.principalOf(USDE, client), 0, "principal should be zero after full withdraw");

        uint256 usdeReceived = IERC20(USDE).balanceOf(client) - clientUsdeBefore;
        // Round-trip across two Curve pools incurs double spread; allow 2 * slippage.
        uint256 tolerance = (depositAmount * SLIPPAGE_BPS * 2) / 10_000;
        assertApproxEqAbs(usdeReceived, depositAmount, tolerance, "should receive approximately deposit back");

        // Strategy should hold only dust sUSDe after a full round-trip.
        // Rounding in convertToShares / convertToAssets can leave up to a few wei.
        assertLt(
            IERC20(SUSDE).balanceOf(address(strategy)), 1e12, "strategy sUSDe balance should be dust after round-trip"
        );
    }

    // ============================================================
    //                Test 3: yield growth + extraction
    // ============================================================

    function testYieldGrowthAndExtraction() public {
        uint256 depositAmount = 100_000e18;

        vm.prank(client);
        strategy.deposit(USDE, depositAmount, client);

        uint256 principalBefore = strategy.principalOf(USDE, client);
        uint256 totalBefore = strategy.totalBalanceOf(USDE, client);

        // ── Simulate sUSDe yield by donating USDe and warping past vesting ──
        //
        // Ethena's StakedUSDe computes:
        //   totalAssets() = underlyingToken.balanceOf(this) - getUnvestedAmount()
        //
        // `getUnvestedAmount` decays linearly to zero at
        // `lastDistributionTimestamp + VESTING_PERIOD` (8 hours). After warping
        // past that point the unvested amount is zero, so any donated USDe is
        // immediately reflected in `totalAssets`, which raises the sUSDe share
        // price seen by `convertToAssets`.
        uint256 donation = 50_000_000e18; // ~1.4% of TVL, large enough to move share price meaningfully

        deal(USDE, address(this), donation, true);
        IERC20(USDE).transfer(SUSDE, donation);

        // Warp past the vesting window so donation is fully reflected in totalAssets.
        ISUSDeView sUSDeView = ISUSDeView(SUSDE);
        uint256 lastDist = sUSDeView.lastDistributionTimestamp();
        vm.warp(lastDist + 8 hours + 1);

        // Sanity: unvested amount should now be zero.
        assertEq(sUSDeView.getUnvestedAmount(), 0, "unvested amount should be zero after warping past vesting window");

        // totalBalanceOf should have grown (share price up).
        uint256 totalAfter = strategy.totalBalanceOf(USDE, client);
        assertGt(totalAfter, totalBefore, "totalBalanceOf should increase after yield donation");
        assertEq(strategy.principalOf(USDE, client), principalBefore, "principal must not change from yield");

        // Withdraw all: client should receive >= deposit (within slippage), and
        // strategy should have extracted at least some of the yield.
        uint256 clientUsdeBeforeWithdraw = IERC20(USDE).balanceOf(client);
        vm.prank(client);
        strategy.withdraw(USDE, depositAmount, client);

        uint256 usdeReceived = IERC20(USDE).balanceOf(client) - clientUsdeBeforeWithdraw;

        // Client should receive approximately totalBalanceOf (principal + proportional yield),
        // minus round-trip AMM slippage. Allow 2 * slippage for the withdraw leg.
        uint256 tolerance = (totalAfter * SLIPPAGE_BPS * 2) / 10_000;
        assertApproxEqAbs(usdeReceived, totalAfter, tolerance, "should receive appreciated amount within slippage");

        assertGe(usdeReceived, depositAmount * 9900 / 10000, "should receive at least ~99% of deposit");
        assertEq(strategy.principalOf(USDE, client), 0, "principal should be zero after withdraw");
    }

    // ============================================================
    //             Test 4: bidirectional swap sanity check
    // ============================================================

    /// @notice Exercises the adapter directly — independent of strategy state —
    ///         to isolate pure adapter behavior. Uses a fresh adapter instance
    ///         so route state and approvals don't collide with the strategy.
    function testBidirectionalSwapsWork() public {
        vm.prank(owner);
        CurveAMMAdapter freshAdapter = new CurveAMMAdapter(owner, CURVE_ROUTER_NG);
        _configureRoutes(freshAdapter);

        // ── Forward leg: USDe -> sUSDe ──
        uint256 usdeIn = 10_000e18;
        deal(USDE, address(this), usdeIn, true);
        IERC20(USDE).approve(address(freshAdapter), usdeIn);

        uint256 sUSDeBefore = IERC20(SUSDE).balanceOf(address(this));
        uint256 sUSDeOut = freshAdapter.swap(USDE, SUSDE, usdeIn, 0);
        uint256 sUSDeAfter = IERC20(SUSDE).balanceOf(address(this));

        assertGt(sUSDeOut, 0, "forward swap returned zero");
        assertEq(sUSDeAfter - sUSDeBefore, sUSDeOut, "sUSDe balance delta should match swap output");

        // ── Reverse leg: sUSDe -> USDe ──
        // Use exactly what we just received so we exercise sUSDe as the input.
        IERC20(SUSDE).approve(address(freshAdapter), sUSDeOut);

        uint256 usdeBefore = IERC20(USDE).balanceOf(address(this));
        uint256 usdeOut = freshAdapter.swap(SUSDE, USDE, sUSDeOut, 0);
        uint256 usdeAfter = IERC20(USDE).balanceOf(address(this));

        assertGt(usdeOut, 0, "reverse swap returned zero");
        assertEq(usdeAfter - usdeBefore, usdeOut, "USDe balance delta should match swap output");

        // Round-trip should return close to the original USDe (two AMM spreads lost).
        // Allow up to 2% loss across the round-trip.
        assertGe(usdeOut, usdeIn * 9800 / 10000, "round-trip via adapter should lose less than 2%");
    }
}
