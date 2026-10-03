// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "@forge-std/Test.sol";
import {Vm, VmSafe} from "@forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockBalancerPool} from "../src/mocks/MockBalancerPool.sol";
import {MockBalancerVault} from "../src/mocks/MockBalancerVault.sol";
import {MockBalancerRouter} from "../src/mocks/MockBalancerRouter.sol";
import {MockUSDS} from "../src/mocks/MockUSDS.sol";
import {MockSUSDS} from "../src/mocks/MockSUSDS.sol";
import {MockPhUSD} from "../src/mocks/MockPhUSD.sol";
import {AddLiquidityParams, AddLiquidityKind} from "@yield-claim-nft/interfaces/balancer/BalancerTypes.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/dispatchers/BalancerPoolerV2.sol";
import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
import {ATokenDispatcherV2} from "@yield-claim-nft/dispatchers/ATokenDispatcherV2.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {BalancerPoolerMintDebtHook} from "@yield-claim-nft/hooks/BalancerPoolerMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";
import {Pauser} from "@pauser/Pauser.sol";
import {UniswapV2Deployer, IUniswapV2FactoryLike, IUniswapV2RouterLike} from "../script/helpers/UniswapV2Deployer.sol";
import {UniPoolerCutoverCore} from "../script/helpers/UniPoolerCutoverCore.sol";

interface IPairView {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function sync() external;
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title UniPoolerCutoverCoreTest  (story 100)
 * @notice Drives the SAME `UniPoolerCutoverCore` that the anvil rehearsal (101), the mainnet
 *         script and the fork test (103) inherit, against a local stack: the Balancer mocks with
 *         their new exits, a real `BalancerPoolerV2` at NFT index 4 holding BPT and interim sUSDS,
 *         the real `BalancerPoolerMintDebtHook` and `NFTMinterV2`, and the canonical Uniswap V2
 *         stack from `UniswapV2Deployer`. No fork.
 *
 *         The test contract is the OWNER of everything, so the core's internal calls run from the
 *         owner exactly as they do from a broadcasting script (execution context is the caller's).
 */
contract UniPoolerCutoverCoreTest is Test, UniPoolerCutoverCore {
    // Tokens
    MockUSDS usds;
    MockSUSDS susds;
    MockPhUSD phusd;

    // Balancer mocks
    MockBalancerPool bpt;
    MockBalancerVault bVault;
    MockBalancerRouter bRouter;

    // Live stack
    BalancerPoolerV2 old;
    NFTMinterV2 minter;
    BalancerPoolerMintDebtHook hook;
    Pauser pauser;

    // Uniswap V2
    IUniswapV2FactoryLike factory;
    IUniswapV2RouterLike uniRouter;

    address user = makeAddr("user");
    address thirdPartyLp = makeAddr("thirdPartyLp");
    address staker = makeAddr("nftStaker");
    address multiPooler = makeAddr("multiPooler");
    address pooler7702 = makeAddr("pooler7702");
    address poolerEoa = makeAddr("poolerEoa");
    address batchMinter = makeAddr("batchMinter");
    address nudgeStreamer = makeAddr("nudgeStreamer");
    address fakePsm = makeAddr("psm"); // no code: a live donation reverts and parks USDS

    uint256 constant INDEX = 4;
    uint256 constant PRICE = 100e18;
    uint256 constant GROWTH = 50; // 0.5% per mint
    uint256 constant TOL_BPS = 10; // 0.1%
    uint256 constant SEED_DEADLINE_OFFSET = 1 hours; // what the broadcast callers (101/103) pass

    function setUp() public {
        usds = new MockUSDS();
        susds = new MockSUSDS(address(usds));
        phusd = new MockPhUSD();
        phusd.setMinter(address(this), true);

        // Balancer mocks, tokens in Balancer (address-sorted) order.
        bpt = new MockBalancerPool();
        bVault = new MockBalancerVault(address(bpt));
        bpt.setVault(address(bVault));
        bRouter = new MockBalancerRouter();
        bool sFirst = address(susds) < address(phusd);
        address[] memory toks = new address[](2);
        toks[0] = sFirst ? address(susds) : address(phusd);
        toks[1] = sFirst ? address(phusd) : address(susds);
        bVault.setPoolTokens(toks);

        // Today's index-4 pooler, wired as on mainnet.
        old = new BalancerPoolerV2(
            address(susds), address(bpt), address(bVault), address(bRouter), sFirst, address(this)
        );
        minter = new NFTMinterV2(address(this));
        minter.registerDispatcher(address(0x1001), 1e18, 0);
        minter.registerDispatcher(address(0x1002), 1e18, 0);
        minter.registerDispatcher(address(0x1003), 1e18, 0);
        minter.registerDispatcher(address(old), PRICE, GROWTH);
        assertEq(minter.dispatcherToIndex(address(old)), INDEX);
        old.setMinter(address(minter));

        hook = new BalancerPoolerMintDebtHook(address(this), address(old), address(phusd));
        hook.setRecipient(staker);
        phusd.setMinter(address(hook), true);
        old.setHook(IDispatchHook(address(hook)));

        old.setPSM(fakePsm);
        old.setMaxTout(0.02e18);
        old.setBatchMinter(batchMinter);
        old.setNudgeStreamer(nudgeStreamer);
        // batchDonationSize stays 0, as on mainnet at block 26,093,540.

        address[] memory ps = _poolers();
        for (uint256 i = 0; i < ps.length; i++) {
            old.setAuthorizedPooler(ps[i], true);
        }

        pauser = new Pauser(address(usds));

        (, factory, uniRouter) = UniswapV2Deployer.deploy(address(this));

        // The pool's phUSD side and a third-party LP position (not ours: never exited).
        usds.approve(address(susds), type(uint256).max);
        susds.deposit(4_000e18, address(bVault));
        phusd.mint(address(bVault), 9_000e18);
        _addLiquidityTo(thirdPartyLp, 13_000e18);
        // BPT the owner already holds (mainnet: 202.30 BPT from an earlier withdrawBPT).
        phusd.mint(address(bVault), 300e18);
        _addLiquidityTo(address(this), 300e18);

        // Mints at index 4 accrue sUSDS on the pooler, which pools it into BPT it keeps.
        usds.transfer(user, 100_000e18);
        vm.prank(user);
        usds.approve(address(minter), type(uint256).max);
        _mintN(10);
        old.pool(1);
        assertGt(bpt.balanceOf(address(old)), 0, "pooler holds BPT");

        // Interim mints after the holding pattern began: sUSDS accrues, mint debt accrues.
        _mintN(3);
        assertGt(susds.balanceOf(address(old)), 0, "pooler holds interim sUSDS");
        assertGt(hook.mintDebt(), 0, "interim mint debt");

        // Holding pattern (story 099): revoke every authorized pooler at once.
        old.incrementAuthVersion();
    }

    // ------------------------------------------------------------------ helpers

    function _poolers() internal view returns (address[] memory ps) {
        ps = new address[](4);
        ps[0] = address(this);
        ps[1] = multiPooler;
        ps[2] = pooler7702;
        ps[3] = poolerEoa;
    }

    function _addLiquidityTo(address to, uint256 bptAmount) internal {
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = bptAmount;
        bVault.addLiquidity(
            AddLiquidityParams({
                pool: address(bpt),
                to: to,
                maxAmountsIn: maxIn,
                minBptAmountOut: 0,
                kind: AddLiquidityKind.UNBALANCED,
                userData: ""
            })
        );
    }

    function _mintN(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.prank(user);
            minter.mint(INDEX, user);
        }
    }

    /// @dev Off-chain computation the mainnet script (103) performs: the live proportional share
    ///      of the owner's whole BPT balance after `withdrawBPT`, minus TOL_BPS, in pool order.
    function _expectedMins() internal view returns (uint256[] memory mins) {
        uint256 bptIn = bpt.balanceOf(address(this)) + bpt.balanceOf(address(old));
        (,, uint256[] memory raw,) = bVault.getPoolTokenInfo(address(bpt));
        mins = new uint256[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            uint256 share = (raw[i] * bptIn) / bpt.totalSupply();
            mins[i] = (share * (10_000 - TOL_BPS)) / 10_000;
        }
    }

    function _params(ExitMode mode) internal view returns (CutoverParams memory p) {
        p.owner = address(this);
        p.oldPooler = address(old);
        p.mintDebtHook = address(hook);
        p.nftMinter = address(minter);
        p.dispatcherIndex = INDEX;
        p.uniV2Router = address(uniRouter);
        p.balancerRouter = address(bRouter);
        p.poolers = _poolers();
        p.exitMode = mode;
        p.minAmountsOut = _expectedMins();
        p.exitToleranceBps = TOL_BPS;
        p.seedToleranceBps = TOL_BPS;
        p.seedDeadline = block.timestamp + SEED_DEADLINE_OFFSET;
    }

    function runExt(CutoverParams memory p) external returns (CutoverResult memory) {
        return _runCutover(p);
    }

    struct Pre {
        uint256 price;
        uint256 growth;
        uint256 oldSUSDS;
        uint256 oldUSDS;
        uint256 bptIn;
        uint256 ownerSUSDS;
        uint256 ownerPhUSD;
        uint256 stakerPhUSD;
        uint256 debt;
    }

    function _pre() internal view returns (Pre memory s) {
        (, s.price, s.growth,) = minter.configs(INDEX);
        s.oldSUSDS = susds.balanceOf(address(old));
        s.oldUSDS = usds.balanceOf(address(old));
        s.bptIn = bpt.balanceOf(address(this)) + bpt.balanceOf(address(old));
        s.ownerSUSDS = susds.balanceOf(address(this));
        s.ownerPhUSD = phusd.balanceOf(address(this));
        s.stakerPhUSD = phusd.balanceOf(staker);
        s.debt = hook.mintDebt();
    }

    function _assertPost(CutoverResult memory r, Pre memory s) internal {
        UniPoolerV2 np = UniPoolerV2(r.newPooler);

        // Dispatcher swapped, price/growth preserved.
        (address d, uint256 price, uint256 growth, bool disabled) = minter.configs(INDEX);
        assertEq(d, r.newPooler, "configs(4).dispatcher");
        assertEq(price, s.price, "price preserved");
        assertEq(growth, s.growth, "growth preserved");
        assertFalse(disabled, "index 4 enabled");
        assertEq(minter.dispatcherToIndex(r.newPooler), INDEX);
        assertEq(minter.dispatcherToIndex(address(old)), 0);

        // Hook repointed, ledger clean, interim debt paid to the recipient.
        assertEq(hook.dispatcher(), r.newPooler, "hook.dispatcher");
        assertEq(address(np.hook()), address(hook), "new pooler hook");
        assertEq(hook.mintDebt(), 0, "mintDebt == 0");
        assertEq(phusd.balanceOf(staker), s.stakerPhUSD + s.debt, "debt pulled to recipient");

        // Pair seeded with exactly the recovered amounts; the new pooler holds the LP.
        assertEq(r.pair, factory.getPair(address(susds), address(phusd)), "canonical pair");
        assertEq(np.pair(), r.pair);
        (uint112 r0, uint112 r1,) = IPairView(r.pair).getReserves();
        bool s0 = IPairView(r.pair).token0() == address(susds);
        assertEq(s0 ? r0 : r1, r.sUSDSRecovered, "sUSDS reserve == seeded");
        assertEq(s0 ? r1 : r0, r.phUSDRecovered, "phUSD reserve == seeded");
        assertGt(r.liquidity, 0);
        assertEq(IPairView(r.pair).balanceOf(r.newPooler), r.liquidity, "new pooler holds the LP");
        assertEq(r.bptExited, s.bptIn, "owner's whole BPT exited");

        // Only Balancer-recovered tokens seeded the pair: the owner's own balances are unchanged.
        assertEq(susds.balanceOf(address(this)), s.ownerSUSDS, "owner sUSDS unchanged");
        assertEq(phusd.balanceOf(address(this)), s.ownerPhUSD, "owner phUSD unchanged");

        // Old pooler drained, retired and paused.
        assertEq(susds.balanceOf(address(old)), 0, "old sUSDS == 0");
        assertEq(usds.balanceOf(address(old)), 0, "old USDS == 0");
        assertEq(bpt.balanceOf(address(old)), 0, "old BPT == 0");
        assertEq(bpt.balanceOf(address(this)), 0, "owner BPT == 0");
        assertTrue(old.paused(), "old paused");
        assertEq(r.sUSDSRescued, s.oldSUSDS);
        assertEq(r.usdsRescued, s.oldUSDS);

        // New pooler config equals the old one's, read live; all four poolers authorized.
        assertEq(np.psm(), old.psm(), "psm");
        assertEq(np.maxTout(), old.maxTout(), "maxTout");
        assertEq(np.batchMinter(), old.batchMinter(), "batchMinter");
        assertEq(np.nudgeStreamer(), old.nudgeStreamer(), "nudgeStreamer");
        assertEq(np.batchDonationSize(), old.batchDonationSize(), "batchDonationSize");
        address[] memory ps = _poolers();
        for (uint256 i = 0; i < ps.length; i++) {
            assertEq(np.poolerAuthVersion(ps[i]), np.authVersion(), "pooler authorized on new");
        }
        assertEq(np.owner(), address(this));

        // A post-cutover mint dispatches through the new pooler, wraps and accrues debt.
        uint256 npSUSDS = susds.balanceOf(r.newPooler);
        _mintN(1);
        assertGt(susds.balanceOf(r.newPooler), npSUSDS, "mint wrapped on new pooler");
        assertGt(hook.mintDebt(), 0, "mint accrued debt");
        (, uint256 priceAfterMint,,) = minter.configs(INDEX);
        assertEq(priceAfterMint, s.price + (s.price * s.growth) / 10_000, "price curve continues");
    }

    // ------------------------------------------------------------- happy paths

    function test_cutover_proportional() public {
        Pre memory s = _pre();
        CutoverResult memory r = _runCutover(_params(ExitMode.PROPORTIONAL));
        _assertPost(r, s);
    }

    function test_cutover_recovery() public {
        bVault.setPoolPaused(true); // after 30 Oct: proportional reverts, recovery works
        Pre memory s = _pre();
        CutoverResult memory r = _runCutover(_params(ExitMode.RECOVERY));
        _assertPost(r, s);
    }

    function test_cutover_newPoolerSUSDSEqualsRescued_beforeAnyMint() public {
        CutoverResult memory r = _runCutover(_params(ExitMode.PROPORTIONAL));
        assertEq(susds.balanceOf(r.newPooler), r.sUSDSRescued, "new pooler sUSDS == rescued");
    }

    /// @dev Parked USDS with the donation disabled on the new pooler: the USDS goes to OWNER, is
    ///      wrapped, and the sUSDS is deposited for the new pooler (plan Stage 2, interim mints).
    function test_parkedUSDS_donationDisabled_wrappedIntoNewPooler() public {
        usds.transfer(address(old), 55e18); // as if parked by DonationSkipped
        uint256 ownerUSDS = usds.balanceOf(address(this));
        CutoverResult memory r = _runCutover(_params(ExitMode.PROPORTIONAL));
        assertEq(r.usdsRescued, 55e18);
        assertTrue(r.usdsWrapped, "wrapped");
        assertEq(usds.balanceOf(address(old)), 0);
        assertEq(usds.balanceOf(r.newPooler), 0, "no raw USDS on new pooler");
        assertEq(usds.balanceOf(address(this)), ownerUSDS, "owner USDS unchanged");
        assertEq(susds.balanceOf(r.newPooler), r.sUSDSRescued + r.usdsWrappedShares, "rescued + wrapped");
        assertGt(r.usdsWrappedShares, 0);
    }

    /// @dev Parked USDS with the donation live: the USDS goes straight to the new pooler, whose
    ///      next dispatch sweeps and retries it.
    function test_parkedUSDS_donationLive_sentToNewPooler() public {
        old.setBatchDonationSize(10);
        _mintN(2); // fake PSM has no code -> donation reverts -> USDS parks on the old pooler
        uint256 parked = usds.balanceOf(address(old));
        assertGt(parked, 0, "USDS parked");
        Pre memory s = _pre();
        CutoverResult memory r = _runCutover(_params(ExitMode.PROPORTIONAL));
        assertEq(r.usdsRescued, parked);
        assertFalse(r.usdsWrapped);
        assertEq(usds.balanceOf(r.newPooler), parked, "parked USDS on new pooler");
        assertEq(UniPoolerV2(r.newPooler).batchDonationSize(), 10);
        _assertPost(r, s);
    }

    /// @dev An unsynced pre-donation to the pair is skimmed back to OWNER before the empty check.
    function test_unsyncedDonation_skimmedThenCutoverProceeds() public {
        address pair = factory.createPair(address(susds), address(phusd));
        susds.deposit(5e18, pair);
        phusd.mint(pair, 7e18);
        uint256 ownerS = susds.balanceOf(address(this));
        uint256 ownerP = phusd.balanceOf(address(this));
        CutoverResult memory r = _runCutover(_params(ExitMode.PROPORTIONAL));
        assertEq(r.pair, pair, "existing pair reused");
        assertEq(susds.balanceOf(address(this)), ownerS + 5e18, "sUSDS donation skimmed to owner");
        assertEq(phusd.balanceOf(address(this)), ownerP + 7e18, "phUSD donation skimmed to owner");
        (uint112 r0, uint112 r1,) = IPairView(pair).getReserves();
        bool s0 = IPairView(pair).token0() == address(susds);
        assertEq(s0 ? r0 : r1, r.sUSDSRecovered);
        assertEq(s0 ? r1 : r0, r.phUSDRecovered);
    }

    /// @dev A front-run createPair with no reserves is harmless: the core reuses the pair.
    function test_existingEmptyPair_reused() public {
        address pair = factory.createPair(address(phusd), address(susds));
        CutoverResult memory r = _runCutover(_params(ExitMode.PROPORTIONAL));
        assertEq(r.pair, pair);
    }

    // --------------------------------------------------------- order invariants

    function _firstCall(Vm.AccountAccess[] memory acc, address target, bytes4 sel) internal pure returns (uint256) {
        for (uint256 i = 0; i < acc.length; i++) {
            if (
                acc[i].kind == VmSafe.AccountAccessKind.Call && acc[i].account == target && acc[i].data.length >= 4
                    && bytes4(acc[i].data) == sel
            ) return i;
        }
        revert("call not found");
    }

    function _countSelector(Vm.AccountAccess[] memory acc, bytes4 sel) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < acc.length; i++) {
            if (acc[i].kind == VmSafe.AccountAccessKind.Call && acc[i].data.length >= 4 && bytes4(acc[i].data) == sel) {
                n++;
            }
        }
    }

    function test_orderInvariants_andNoPauserCalls() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.startStateDiffRecording();
        CutoverResult memory r = _runCutover(p);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        address np = r.newPooler;

        uint256 iCreate = _firstCall(acc, address(factory), IUniswapV2FactoryLike.createPair.selector);
        uint256 iWithdraw = _firstCall(acc, address(old), BalancerPoolerV2.withdrawBPT.selector);
        uint256 iExit = _firstCall(acc, address(bRouter), MockBalancerRouter.removeLiquidityProportional.selector);
        uint256 iSeed = _firstCall(acc, address(uniRouter), IUniswapV2RouterLike.addLiquidity.selector);
        uint256 iPull = _firstCall(acc, address(hook), BalancerPoolerMintDebtHook.pull.selector);
        uint256 iSetDisp = _firstCall(acc, address(hook), BalancerPoolerMintDebtHook.setDispatcher.selector);
        uint256 iSetHook = _firstCall(acc, np, ATokenDispatcherV2.setHook.selector);
        uint256 iNewMinter = _firstCall(acc, np, ATokenDispatcherV2.setMinter.selector);
        uint256 iReplace = _firstCall(acc, address(minter), NFTMinterV2.replaceDispatcher.selector);
        uint256 iRescue = _firstCall(acc, address(old), BalancerPoolerV2.rescueERC20.selector);
        uint256 iOldMinter = _firstCall(acc, address(old), ATokenDispatcherV2.setMinter.selector);
        uint256 iPause = _firstCall(acc, address(old), ATokenDispatcherV2.pause.selector);

        // Pair exists before the pooler is deployed (051's canonical-pair constructor check).
        bool deployedAfterCreate;
        for (uint256 i = iCreate; i < acc.length; i++) {
            if (acc[i].kind == VmSafe.AccountAccessKind.Create && acc[i].account == np) deployedAfterCreate = true;
        }
        assertTrue(deployedAfterCreate, "createPair before UniPoolerV2 deploy");

        assertLt(iWithdraw, iExit, "withdrawBPT before exit");
        assertLt(iExit, iSeed, "exit before seed");
        assertLt(iSeed, iPull, "seed before pull");
        assertLt(iPull, iSetDisp, "pull() before hook.setDispatcher");
        assertLt(iSetDisp, iSetHook, "hook.setDispatcher before new.setHook");
        assertLt(iSetHook, iReplace, "setHook before replaceDispatcher");
        assertLt(iNewMinter, iReplace, "new.setMinter before replaceDispatcher");
        assertLt(iReplace, iRescue, "replaceDispatcher before rescue");
        assertLt(iReplace, iOldMinter, "replaceDispatcher before old.setMinter(OWNER)");
        assertLt(iOldMinter, iPause, "old.setMinter(OWNER) before old.pause");

        assertEq(_countSelector(acc, Pauser.register.selector), 0, "no Pauser.register");
        assertEq(_countSelector(acc, Pauser.unregister.selector), 0, "no Pauser.unregister");
    }

    function test_noPauserCalls_expectCall() public {
        vm.expectCall(address(pauser), abi.encodeWithSelector(Pauser.register.selector), 0);
        vm.expectCall(address(pauser), abi.encodeWithSelector(Pauser.unregister.selector), 0);
        _runCutover(_params(ExitMode.PROPORTIONAL));
    }

    // ------------------------------------------------------------ seed deadline

    /// @notice The deadline handed to Router02 is the caller's forward-dated value, never the raw
    ///         execution timestamp (which a broadcast fixes at simulation time).
    function test_seedDeadline_forwardedToRouter() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.startStateDiffRecording();
        _runCutover(p);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        bytes memory data = acc[_firstCall(acc, address(uniRouter), IUniswapV2RouterLike.addLiquidity.selector)].data;
        uint256 deadline;
        assembly {
            deadline := mload(add(data, mload(data))) // last ABI word: the deadline argument
        }
        assertEq(deadline, p.seedDeadline, "router deadline == caller's seedDeadline");
        assertGt(deadline, block.timestamp, "router deadline strictly in the future");
    }

    /// @notice Broadcast semantics: the params (and so the deadline) are built at simulation time,
    ///         and the seed lands in a later block. With a forward-dated deadline it still succeeds.
    ///         Times are literals: via_ir may re-read `block.timestamp` after a `vm.warp`.
    function test_seedDeadline_survivesLaterBlock() public {
        uint256 simTime = 2_000_000_000;
        vm.warp(simTime);
        Pre memory s = _pre();
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.seedDeadline = simTime + SEED_DEADLINE_OFFSET;
        vm.warp(simTime + 30 minutes);
        vm.roll(block.number + 150);
        CutoverResult memory r = this.runExt(p);
        _assertPost(r, s);
    }

    /// @notice The regression the parameter exists to prevent: a deadline equal to the simulation
    ///         timestamp is rejected by Router02 once the seed is mined one block later.
    function test_simulationTimestampDeadline_expiresInLaterBlock() public {
        uint256 simTime = 2_000_000_000;
        vm.warp(simTime);
        susds.deposit(10e18, address(this));
        phusd.mint(address(this), 10e18);
        susds.approve(address(uniRouter), 10e18);
        phusd.approve(address(uniRouter), 10e18);
        vm.warp(simTime + 12); // the next block
        vm.expectRevert(bytes("UniswapV2Router: EXPIRED"));
        uniRouter.addLiquidity(address(susds), address(phusd), 10e18, 10e18, 0, 0, address(0xBEEF), simTime);
    }

    function test_revert_seedDeadlineNotInFuture() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.seedDeadline = block.timestamp;
        vm.expectRevert(bytes("UniPoolerCutoverCore: seed deadline not in future"));
        this.runExt(p);
        p.seedDeadline = 0;
        vm.expectRevert(bytes("UniPoolerCutoverCore: seed deadline not in future"));
        this.runExt(p);
    }

    function test_revert_seedDeadlineTooFar() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.seedDeadline = block.timestamp + CUTOVER_MAX_SEED_DEADLINE_WINDOW + 1;
        vm.expectRevert(bytes("UniPoolerCutoverCore: seed deadline too far"));
        this.runExt(p);
        p.seedDeadline = type(uint256).max;
        vm.expectRevert(bytes("UniPoolerCutoverCore: seed deadline too far"));
        this.runExt(p);
    }

    // ------------------------------------------------------- precondition reverts

    function test_revert_poolersNotRevoked() public {
        // Re-authorize one pooler at the current authVersion: the set is no longer revoked.
        old.setAuthorizedPooler(multiPooler, true);
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.expectRevert(bytes("UniPoolerCutoverCore: pooler still authorized"));
        this.runExt(p);
    }

    function test_revert_poolersNeverRevoked() public {
        // Fresh state where incrementAuthVersion was never called: undo by re-authorizing all four.
        address[] memory ps = _poolers();
        for (uint256 i = 0; i < ps.length; i++) {
            old.setAuthorizedPooler(ps[i], true);
        }
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.expectRevert(bytes("UniPoolerCutoverCore: pooler still authorized"));
        this.runExt(p);
    }

    function test_revert_pairReservesNonZero() public {
        susds.deposit(10e18, address(this));
        phusd.mint(address(this), 10e18);
        susds.approve(address(uniRouter), 10e18);
        phusd.approve(address(uniRouter), 10e18);
        uniRouter.addLiquidity(address(susds), address(phusd), 10e18, 10e18, 0, 0, address(0xBEEF), block.timestamp);
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.expectRevert(bytes("UniPoolerCutoverCore: pair reserves not empty"));
        this.runExt(p);
    }

    function test_revert_pairSyncedDonation() public {
        address pair = factory.createPair(address(susds), address(phusd));
        susds.deposit(1e18, pair);
        phusd.mint(pair, 1e18);
        IPairView(pair).sync();
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.expectRevert(bytes("UniPoolerCutoverCore: pair reserves not empty"));
        this.runExt(p);
    }

    function test_revert_zeroMinAmountOut() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.minAmountsOut[0] = 0;
        vm.expectRevert(bytes("UniPoolerCutoverCore: zero minAmountOut"));
        this.runExt(p);

        p = _params(ExitMode.PROPORTIONAL);
        p.minAmountsOut[1] = 0;
        vm.expectRevert(bytes("UniPoolerCutoverCore: zero minAmountOut"));
        this.runExt(p);
    }

    function test_revert_minAmountsOutLength() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.minAmountsOut = new uint256[](1);
        p.minAmountsOut[0] = 1;
        vm.expectRevert(bytes("UniPoolerCutoverCore: minAmountsOut length"));
        this.runExt(p);
    }

    function test_revert_minAmountsOutTooLoose() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.minAmountsOut[0] = p.minAmountsOut[0] / 2; // far below share - tolerance
        vm.expectRevert(bytes("UniPoolerCutoverCore: minAmountOut below tolerance"));
        this.runExt(p);
    }

    function test_revert_minAmountsOutAboveShare() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.minAmountsOut[1] = p.minAmountsOut[1] * 2;
        vm.expectRevert(bytes("UniPoolerCutoverCore: minAmountOut above share"));
        this.runExt(p);
    }

    function test_revert_toleranceTooWide() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.exitToleranceBps = 101;
        vm.expectRevert(bytes("UniPoolerCutoverCore: tolerance too wide"));
        this.runExt(p);
        p = _params(ExitMode.PROPORTIONAL);
        p.seedToleranceBps = 101;
        vm.expectRevert(bytes("UniPoolerCutoverCore: tolerance too wide"));
        this.runExt(p);
    }

    function test_revert_proportionalWhenPoolPaused() public {
        bVault.setPoolPaused(true);
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.expectRevert(bytes("MockBalancerVault: pool paused"));
        this.runExt(p);
    }

    function test_revert_recoveryWhenPoolLive() public {
        CutoverParams memory p = _params(ExitMode.RECOVERY);
        vm.expectRevert(bytes("MockBalancerVault: pool not in recovery mode"));
        this.runExt(p);
    }

    function test_revert_wrongPoolerCount() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.poolers = new address[](0);
        vm.expectRevert(bytes("UniPoolerCutoverCore: no poolers"));
        this.runExt(p);
    }

    function test_revert_indexNotOldPooler() public {
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        p.dispatcherIndex = 3;
        vm.expectRevert(bytes("UniPoolerCutoverCore: index not on old pooler"));
        this.runExt(p);
    }

    function test_revert_hookNotOnOldPooler() public {
        hook.setDispatcher(address(0xD00D));
        CutoverParams memory p = _params(ExitMode.PROPORTIONAL);
        vm.expectRevert(bytes("UniPoolerCutoverCore: hook not on old pooler"));
        this.runExt(p);
    }
}
