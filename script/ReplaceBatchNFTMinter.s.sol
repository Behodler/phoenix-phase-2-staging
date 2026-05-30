// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// [story-050] Redeploy the fixed BatchNFTMinter on mainnet, repoint SYA + BalancerPoolerV2
// to it, seed the new USDC nudge pot from the Balancer BPT (proportional exit -> sUSDS->USDC
// seed + phUSD burn), and retire the old exploited contract. Single owner-signed broadcast,
// PREVIEW_MODE-aware fork dry-run. Mechanics copied from DeployMainnetNudgePoolerV2.s.sol
// (deploy/config/repoint) and RescuePoolAndDonateUSDC.s.sol (BPT->swap->seed->burn).

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {ITokenMinterV2} from "@yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";

/**
 * @title ReplaceBatchNFTMinter
 * @notice One-shot mainnet cutover (story 050 / incident §6): redeploys the fixed,
 *         minter-pinned BatchNFTMinter, repoints its two real funders (SYA's nudge
 *         address + BalancerPoolerV2's batchMinter), seeds its USDC nudge pot from the
 *         Balancer BPT, and neutralizes the old exploited contract.
 *
 * Flow (single owner-signed broadcast):
 *   1. Pre-flight snapshot (old USDC balance, pooler BPT, current pointers).
 *   2. Deploy new BatchNFTMinter(OWNER).
 *   3. Configure: setTokenMinter -> setDispatcherIndex(4) -> setNudgePaymentToken(USDC)
 *                 -> setNudgeSize(40) -> (optional) setPauser.
 *   4. Guards (config invariants) before any funds move.
 *   5. Repoint: SYA.setNudgeAddress(new) + BalancerPoolerV2.setBatchMinter(new).
 *   6. Seed from BPT: withdraw the slice that releases ~SEED_USDS_TARGET of sUSDS value
 *      (leave the rest on the pooler), proportional exit -> sUSDS + phUSD, swap sUSDS ->
 *      waUSDC -> USDC, transfer USDC to the new nudge pot, burn the phUSD leg.
 *   7. Retire old contract: assert USDC balance == 0, zero its nudge config (idempotent —
 *      DisableNudgeAndDivertDonations already zeroed it).
 *   8. Persist progress JSON.
 *
 * Dry run:
 *   PREVIEW_MODE=true forge script script/ReplaceBatchNFTMinter.s.sol:ReplaceBatchNFTMinter \
 *     --rpc-url $RPC_MAINNET --sender 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --slow -vvv
 *
 * Broadcast:
 *   forge script script/ReplaceBatchNFTMinter.s.sol:ReplaceBatchNFTMinter \
 *     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
 *     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
 */

interface ISYANudge {
    function setNudgeAddress(address) external;
    // NOTE: the getter is the public state var `nudge` (source: StableYieldAccumulator.sol
    // `address public nudge;`), NOT `nudgeAddress`. The setter is `setNudgeAddress`.
    function nudge() external view returns (address);
    // nudgeSplit is the percentage [0,100] of each claim() payment routed to `nudge`
    // (StableYieldAccumulator.sol: `nudgeAmount = actualPayment * nudgeSplit / 100`). The
    // incident mitigation dropped it to 0 to cut funding; the cutover restores it to 30%.
    function setNudgeSplit(uint256) external;
    function nudgeSplit() external view returns (uint256);
}

interface IBalancerPoolerV2Min {
    function setBatchMinter(address) external;
    function batchMinter() external view returns (address);
    function withdrawBPT(address recipient, uint256 amount) external;
    function pool() external view returns (address);
}

interface IOldBatchMinter {
    function setNudgePaymentToken(address) external;
    function setNudgeSize(uint256) external;
}

interface INFTMinterV2Configs {
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}

interface ITokenDispatcherV2Prime {
    function primeToken() external view returns (address);
}

interface IBalancerRouterV3 {
    function removeLiquidityProportional(
        address pool,
        uint256 exactBptAmountIn,
        uint256[] memory minAmountsOut,
        bool wethIsEth,
        bytes memory userData
    ) external returns (uint256[] memory amountsOut);
}

// Balancer V3 VaultTypes.TokenInfo (src/balancer-v3/interfaces/.../VaultTypes.sol). Mirrored
// here only so getPoolTokenInfo's return tuple decodes correctly; we use balancesRaw.
enum TokenType {
    STANDARD,
    WITH_RATE
}

struct TokenInfo {
    TokenType tokenType;
    address rateProvider;
    bool paysYieldFees;
}

interface IBalancerVaultV3 {
    function getPoolTokens(address pool) external view returns (address[] memory);
    // Balancer V3 keeps token reserves in the Vault, not the pool contract — so the
    // pool's sUSDS reserve must be read from the Vault, not via IERC20.balanceOf(pool).
    function getCurrentLiveBalances(address pool) external view returns (uint256[] memory);
    // RAW (un-rate-scaled) per-token reserves, aligned with `tokens`. Used to compute exact
    // proportional-exit floors: amountOut[i] = balancesRaw[i] * bptIn / bptTotalSupply
    // (Balancer V3 BasePoolMath.computeProportionalAmountsOut — no swap fee, exact).
    function getPoolTokenInfo(address pool)
        external
        view
        returns (
            address[] memory tokens,
            TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        );
}

interface IERC4626Min {
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function totalSupply() external view returns (uint256);
}

interface IFlaxBurn {
    // phUSD (FlaxToken) has NO self-burn `burn(uint256)`. Its `burn(holder, amount)` works
    // like `transferFrom`: it spends msg.sender's allowance against `holder`, then `_burn`s.
    // It is permissionless (no minter role needed). Source: flax-token-v2/src/FlaxToken.sol.
    function burn(address holder, uint256 amount) external;
}

interface IBalancerSwapVaultV3 {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(VaultSwapParams memory params) external returns (uint256, uint256, uint256);
    function settle(address token, uint256 amountHint) external returns (uint256);
    function sendTo(address token, address to, uint256 amount) external;
}

enum SwapKind {
    EXACT_IN,
    EXACT_OUT
}

struct VaultSwapParams {
    SwapKind kind;
    address pool;
    address tokenIn;
    address tokenOut;
    uint256 amountGivenRaw;
    uint256 limitRaw;
    bytes userData;
}

/// @notice Short-lived helper that performs the Balancer-V3 sUSDS -> waUSDC -> USDC swap
///         and forwards the USDC to the new nudge pot. A Balancer V3 `unlock` callback is
///         dispatched to `msg.sender`, so the caller MUST be a contract — an owner-signed
///         EOA broadcast cannot drive `unlock` directly (the earlier `this.swapCallback`
///         approach reverted with `AddressEmptyCode` on the EOA). Mirrors
///         RescuePoolAndDonateUSDC's `DonationRescueHelper`: owner pre-funds it with sUSDS,
///         calls `execute`, the Vault calls back `unlockCallback` (guarded `msg.sender==vault`),
///         which swaps/settles/redeems and forwards USDC. Deployed fresh per run.
contract SeedSwapHelper {
    address public immutable owner;
    address public immutable vault;
    address public immutable swapPool;
    address public immutable sUSDS;
    address public immutable waUsdc;
    address public immutable usdc;
    address public immutable recipient; // the new BatchNFTMinter nudge pot

    error NotOwner();
    error NotVault();
    error UsdcSlippage(uint256 received, uint256 minOut);

    constructor(
        address _vault,
        address _swapPool,
        address _sUSDS,
        address _waUsdc,
        address _usdc,
        address _recipient
    ) {
        owner = msg.sender;
        vault = _vault;
        swapPool = _swapPool;
        sUSDS = _sUSDS;
        waUsdc = _waUsdc;
        usdc = _usdc;
        recipient = _recipient;
    }

    /// @notice Owner pre-funds this helper with `sUSDSAmount` sUSDS, then calls `execute`
    ///         to swap it to USDC and forward to `recipient`. Returns the USDC forwarded.
    function execute(uint256 sUSDSAmount, uint256 minUsdcOut) external returns (uint256 usdcSent) {
        if (msg.sender != owner) revert NotOwner();
        bytes memory inner = abi.encode(sUSDSAmount, minUsdcOut);
        bytes memory ret =
            IBalancerSwapVaultV3(vault).unlock(abi.encodeWithSelector(this.unlockCallback.selector, inner));
        usdcSent = abi.decode(ret, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != vault) revert NotVault();
        (uint256 sUSDSAmount, uint256 minUsdcOut) = abi.decode(data, (uint256, uint256));

        // 1. Pay the sUSDS swap input into the Vault.
        IERC20(sUSDS).transfer(vault, sUSDSAmount);
        // 2. Swap sUSDS -> waUSDC (Vault credits this contract internally).
        VaultSwapParams memory params = VaultSwapParams({
            kind: SwapKind.EXACT_IN,
            pool: swapPool,
            tokenIn: sUSDS,
            tokenOut: waUsdc,
            amountGivenRaw: sUSDSAmount,
            limitRaw: 0,
            userData: bytes("")
        });
        (,, uint256 waUsdcReceived) = IBalancerSwapVaultV3(vault).swap(params);
        // 3. Settle the sUSDS we paid in.
        IBalancerSwapVaultV3(vault).settle(sUSDS, sUSDSAmount);
        // 4. Materialize the waUSDC credit into a real balance here.
        IBalancerSwapVaultV3(vault).sendTo(waUsdc, address(this), waUsdcReceived);
        // 5. Unwrap waUSDC -> USDC.
        uint256 usdcReceived = IERC4626Min(waUsdc).redeem(waUsdcReceived, address(this), address(this));
        if (usdcReceived < minUsdcOut) revert UsdcSlippage(usdcReceived, minUsdcOut);
        // 6. Forward USDC to the new nudge pot.
        IERC20(usdc).transfer(recipient, usdcReceived);
        return abi.encode(usdcReceived);
    }
}

contract ReplaceBatchNFTMinter is Script {
    // ============ Mainnet addresses (hardcoded constants, per repo convention) ============
    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant OLD_BATCH_MINTER = 0x4ef0fDe49360ed31c68ED442Ff263CC6291041f3;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant POOLER = 0x26F89f4B46eB164303985795ee20b15BB1Edb38A; // BalancerPoolerV2 (index 4)
    address public constant SYA = 0x3bBE928340c61a65Cb6C4a87B3fb59B6f3F7606a;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WAUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address public constant LP_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04; // 50/50 phUSD/sUSDS BPT
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address public constant BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;

    uint256 public constant DISPATCHER_INDEX = 4;
    uint256 public constant NUDGE_SIZE = 40;
    // SYA nudgeSplit (percent, [0,100]) to restore after the migration. The incident
    // mitigation set this to 0 to cut nudge funding; the canonical operating value is 30%.
    uint256 public constant SYA_NUDGE_SPLIT = 30;

    // ============ Tunable slippage / sizing knobs (env-overridable) ============
    // SEED_USDS_TARGET is the USDS-equivalent (18-dp) notional of the pool slice to remove. It is
    // sized against the Vault's rate-scaled sUSDS live balance, and the proportional exit also
    // releases the phUSD leg (burned), so the eventual USDC seed is a fraction of this notional.
    // CALIBRATED ON FORK (2026-05-30, block ~0x180a223, RPC_MAINNET; pooler held ~2214 BPT):
    //   - SEED_USDS_TARGET = 46e18  -> BPT slice ~49.88e18 -> sUSDS leg 46.0 / phUSD leg 54.1
    //                                 -> 50.417869 USDC seeded into the new nudge pot. (target ~50 USDC)
    //   - (For reference, 190e18 -> 208.03 USDC, so the prior 190e18 default was ~4x too high.)
    // Re-tune on a fresh fork before broadcast if pool state has moved materially.
    uint256 public constant DEFAULT_SEED_USDS_TARGET = 46e18; // fork-calibrated -> ~50.4 USDC seed
    // Non-zero safety floors (repo Configuration Safety gate: never leave slippage bounds at 0).
    // MIN_BPT_WEI: reject a degenerate dust slice (calibrated slice ~49.88e18; floor well below it).
    uint256 public constant DEFAULT_MIN_BPT_WEI = 40e18;
    // MIN_USDC_OUT: final slippage floor on USDC into the pot (observed 50.42; ~6.8% haircut allowed).
    uint256 public constant DEFAULT_MIN_USDC_OUT = 47_000_000;
    address public constant DEFAULT_SWAP_POOL = 0x0B65A4505E8C323AE4fEDcc48515FD713dC9d8C0; // sUSDS/waUSDC
    // EXIT_SLIPPAGE_BPS: per-leg slippage tolerance for the proportional BPT exit's minAmountsOut.
    // The proportional exit is deterministic (amountOut[i] = balancesRaw[i] * bptIn / supply, no
    // swap fee), so the only real drift is other LPs joining/exiting in the same block before our
    // tx lands. 50 bps (0.5%) is a safe non-zero floor; NEVER leave minAmountsOut at 0 on mainnet
    // (repo Configuration Safety gate — an unbounded exit invites sandwiching/MEV).
    uint256 public constant DEFAULT_EXIT_SLIPPAGE_BPS = 50;

    uint256 public seedUsdsTarget;
    uint256 public minBptWei;
    uint256 public minUsdcOut;
    uint256 public exitSlippageBps;
    address public swapPool;

    address public newMinter;

    string public constant PROGRESS_PATH = "server/deployments/progress.batch-minter-replace.1.json";

    function run() external {
        bool preview = vm.envOr("PREVIEW_MODE", false);

        seedUsdsTarget = vm.envOr("SEED_USDS_TARGET", DEFAULT_SEED_USDS_TARGET);
        minBptWei = vm.envOr("MIN_BPT_WEI", DEFAULT_MIN_BPT_WEI);
        minUsdcOut = vm.envOr("MIN_USDC_OUT", DEFAULT_MIN_USDC_OUT);
        exitSlippageBps = vm.envOr("EXIT_SLIPPAGE_BPS", DEFAULT_EXIT_SLIPPAGE_BPS);
        swapPool = vm.envOr("SWAP_POOL", DEFAULT_SWAP_POOL);
        // Configuration Safety gate: the exit floor must be a real, bounded haircut — never 0%
        // (=> minAmountsOut all 0, unbounded) and never >=100% (=> floor of 0).
        require(exitSlippageBps > 0 && exitSlippageBps < 10_000, "EXIT_SLIPPAGE_BPS out of range");

        if (preview) {
            console.log("=== PREVIEW MODE (fork dry-run) ===");
            vm.startPrank(OWNER);
        } else {
            console.log("=== BROADCAST MODE ===");
            vm.startBroadcast();
        }

        _preflight();
        _deployAndConfigure();
        _guards();
        _repoint();
        uint256 usdcSeeded = _seedFromBpt();
        _retireOld();
        _postflight(usdcSeeded);

        if (preview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
            _persist(usdcSeeded);
        }
    }

    // ============ 1. Pre-flight snapshot ============
    function _preflight() internal view {
        console.log("==== PRE-FLIGHT ====");
        console.log("old batchMinter:    ", OLD_BATCH_MINTER);
        console.log("old USDC balance:   ", IERC20(USDC).balanceOf(OLD_BATCH_MINTER));
        console.log("pooler BPT balance: ", IERC20(LP_POOL).balanceOf(POOLER));
        console.log("SYA nudge:          ", ISYANudge(SYA).nudge());
        console.log("SYA nudgeSplit:     ", ISYANudge(SYA).nudgeSplit());
        console.log("pooler batchMinter: ", IBalancerPoolerV2Min(POOLER).batchMinter());
        console.log("seed USDS target:   ", seedUsdsTarget);
    }

    // ============ 2-3. Deploy + configure ============
    function _deployAndConfigure() internal {
        BatchNFTMinter m = new BatchNFTMinter(OWNER);
        newMinter = address(m);
        console.log("Deployed new BatchNFTMinter:", newMinter);

        // order matters — minter first, then index, payment token, size
        m.setTokenMinter(ITokenMinterV2(NFT_MINTER_V2));
        m.setDispatcherIndex(DISPATCHER_INDEX);
        m.setNudgePaymentToken(USDC);
        m.setNudgeSize(NUDGE_SIZE);
        console.log("Configured: tokenMinter, dispatcherIndex=4, nudgeToken=USDC, nudgeSize=40");
    }

    // ============ 4. Config-invariant guards (before any funds move) ============
    function _guards() internal view {
        BatchNFTMinter m = BatchNFTMinter(newMinter);
        require(address(m.tokenMinter()) != address(0), "tokenMinter not set");
        require(m.dispatcherIndex() == DISPATCHER_INDEX, "dispatcherIndex != 4");
        require(m.nudgePaymentToken() == USDC, "nudge token != USDC");

        // resolve the pinned index-4 dispatcher via the live NFTMinterV2 and check its prime token
        (address dispatcher,,,) = INFTMinterV2Configs(NFT_MINTER_V2).configs(DISPATCHER_INDEX);
        require(dispatcher != address(0), "index-4 dispatcher missing");
        address primeToken = ITokenDispatcherV2Prime(dispatcher).primeToken();
        console.log("index-4 dispatcher: ", dispatcher);
        console.log("index-4 primeToken: ", primeToken);
        // index-4 is the USDS / BalancerPoolerV2 path (confirmed on-chain 2026-05-30:
        // configs(4).primeToken == USDS 0xdC03...384F).
        require(primeToken == USDS, "index-4 primeToken != USDS");
        // The security-critical exploit guard: nudge payout token MUST differ from the
        // dispatcher's prime (mint payment) token, else batchMint would revert up-front.
        require(m.nudgePaymentToken() != primeToken, "nudge token == prime token");
        console.log("Guards passed.");
    }

    // ============ 5. Repoint dependencies ============
    function _repoint() internal {
        // Set the nudge address BEFORE restoring the split: SYA's claim() reverts
        // (NudgeNotConfigured) whenever nudgeSplit > 0 while nudge == address(0), so the
        // pointer must be live before the split is re-enabled.
        ISYANudge(SYA).setNudgeAddress(newMinter);
        // Restore the nudge funding cut during the incident mitigation (split was zeroed).
        ISYANudge(SYA).setNudgeSplit(SYA_NUDGE_SPLIT);
        IBalancerPoolerV2Min(POOLER).setBatchMinter(newMinter);
        require(ISYANudge(SYA).nudge() == newMinter, "SYA repoint failed");
        require(ISYANudge(SYA).nudgeSplit() == SYA_NUDGE_SPLIT, "SYA nudgeSplit restore failed");
        require(IBalancerPoolerV2Min(POOLER).batchMinter() == newMinter, "pooler repoint failed");
        console.log("Repointed SYA + BalancerPoolerV2 to new minter");
        console.log("SYA nudgeSplit restored to:", ISYANudge(SYA).nudgeSplit());
    }

    // ============ 6. Seed nudge pot from BPT ============
    function _seedFromBpt() internal returns (uint256 usdcOut) {
        // Size the BPT slice so the released sUSDS leg is worth ~= seedUsdsTarget of USDS.
        // Balancer V3 reserves live in the Vault, NOT the pool contract, and the V3 "live
        // balance" for sUSDS is already rate-scaled into USDS-equivalent 18-dp units. So work
        // entirely in USDS-equivalent units: target (seedUsdsTarget) and the pool's sUSDS live
        // balance share the same unit, giving a clean proportional slice. (Reading the raw sUSDS
        // share count via IERC20.balanceOf(LP_POOL) returns 0 for a V3 pool, hence the Vault read.)
        uint256 poolSusdsValue = _poolSusdsReserve();
        uint256 bptTotalSupply = IERC4626Min(LP_POOL).totalSupply();
        uint256 poolerBpt = IERC20(LP_POOL).balanceOf(POOLER);
        require(poolSusdsValue > 0, "pool holds no sUSDS");
        require(poolerBpt > 0, "pooler holds no BPT");

        // bptSlice ~= (seedUsdsTarget / poolSusdsValue) * bptTotalSupply (proportional pool share)
        uint256 bptSlice = (seedUsdsTarget * bptTotalSupply) / poolSusdsValue;
        if (bptSlice > poolerBpt) bptSlice = poolerBpt;
        require(bptSlice >= minBptWei, "BPT slice below floor");
        require(bptSlice > 0, "BPT slice is zero");
        console.log("BPT slice to withdraw:", bptSlice);
        console.log("BPT left on pooler:   ", poolerBpt - bptSlice);

        // pull only the slice from the pooler to the OWNER EOA (leave the rest on the pooler)
        IBalancerPoolerV2Min(POOLER).withdrawBPT(OWNER, bptSlice);

        // proportional exit: BPT -> sUSDS + phUSD
        IERC20(LP_POOL).approve(BALANCER_ROUTER, bptSlice);
        // Per-token slippage floors (NEVER 0 on mainnet). A proportional exit is exact:
        // amountOut[i] = balancesRaw[i] * bptSlice / bptTotalSupply (no swap fee). We read the
        // RAW reserves from the Vault (view, so it never broadcasts — a Balancer V3 query* call
        // is non-view and would emit a junk broadcast tx), compute the deterministic expected
        // out, then haircut by exitSlippageBps to absorb same-block LP drift.
        (address[] memory rawToks,, uint256[] memory rawBals,) =
            IBalancerVaultV3(BALANCER_VAULT).getPoolTokenInfo(LP_POOL);
        require(rawToks.length == 2, "unexpected pool token count");
        uint256[] memory minAmountsOut = new uint256[](rawToks.length);
        for (uint256 i; i < rawToks.length; ++i) {
            uint256 expectedOut = (rawBals[i] * bptSlice) / bptTotalSupply;
            minAmountsOut[i] = (expectedOut * (10_000 - exitSlippageBps)) / 10_000;
            require(minAmountsOut[i] > 0, "exit floor is zero");
            console.log("exit minAmountOut leg:", rawToks[i], minAmountsOut[i]);
        }
        uint256[] memory amountsOut =
            IBalancerRouterV3(BALANCER_ROUTER).removeLiquidityProportional(LP_POOL, bptSlice, minAmountsOut, false, bytes(""));

        // rawToks (from getPoolTokenInfo) is in the same order as amountsOut.
        uint256 susdsLeg;
        uint256 phusdLeg;
        for (uint256 i; i < rawToks.length; ++i) {
            if (rawToks[i] == SUSDS) susdsLeg = amountsOut[i];
            else if (rawToks[i] == PHUSD) phusdLeg = amountsOut[i];
        }
        console.log("sUSDS leg released:", susdsLeg);
        console.log("phUSD leg released:", phusdLeg);

        // sUSDS leg -> waUSDC -> USDC, forwarded straight to the new nudge pot. The Balancer
        // V3 `unlock` callback is dispatched to its caller, so this must run inside a contract
        // (SeedSwapHelper), NOT from the owner EOA. Owner pre-funds the helper with the sUSDS
        // leg, then `execute` swaps it and forwards the USDC to newMinter (slippage floor
        // enforced inside the helper).
        uint256 potBefore = IERC20(USDC).balanceOf(newMinter);
        SeedSwapHelper helper = new SeedSwapHelper(BALANCER_VAULT, swapPool, SUSDS, WAUSDC, USDC, newMinter);
        IERC20(SUSDS).transfer(address(helper), susdsLeg);
        helper.execute(susdsLeg, minUsdcOut);
        // Measure the actual delta into the pot (robust against the Vault.unlock bytes-wrapper
        // return shape); the helper already enforced the minUsdcOut slippage floor.
        usdcOut = IERC20(USDC).balanceOf(newMinter) - potBefore;
        console.log("Seeded new BatchNFTMinter USDC:", usdcOut);

        // Burn the proportionally-released phUSD leg. phUSD (FlaxToken) has no self-burn; its
        // burn(holder, amount) spends the caller's allowance against holder (like burnFrom), so
        // the owner approves itself, then burns from its own balance.
        if (phusdLeg > 0) {
            IERC20(PHUSD).approve(OWNER, phusdLeg);
            IFlaxBurn(PHUSD).burn(OWNER, phusdLeg);
            console.log("Burned phUSD leg:", phusdLeg);
        }
    }

    /// @dev The pool's sUSDS reserve, read from the Balancer V3 Vault (reserves live in the
    ///      Vault, not the pool contract). Matches the sUSDS index in `getPoolTokens`.
    function _poolSusdsReserve() internal view returns (uint256) {
        address[] memory toks = IBalancerVaultV3(BALANCER_VAULT).getPoolTokens(LP_POOL);
        uint256[] memory bals = IBalancerVaultV3(BALANCER_VAULT).getCurrentLiveBalances(LP_POOL);
        for (uint256 i; i < toks.length; ++i) {
            if (toks[i] == SUSDS) return bals[i];
        }
        revert("sUSDS not in pool tokens");
    }

    // ============ 7. Retire old contract (defense-in-depth) ============
    function _retireOld() internal {
        uint256 oldUsdc = IERC20(USDC).balanceOf(OLD_BATCH_MINTER);
        console.log("Old contract USDC balance:", oldUsdc);
        require(oldUsdc == 0, "old contract still holds USDC");

        // idempotent — DisableNudgeAndDivertDonations already zeroed these on-chain.
        IOldBatchMinter(OLD_BATCH_MINTER).setNudgePaymentToken(address(0));
        IOldBatchMinter(OLD_BATCH_MINTER).setNudgeSize(0);
        console.log("Old contract neutralized (nudge token=0, size=0)");
    }

    // ============ 8. Post-flight + persist ============
    function _postflight(uint256 usdcSeeded) internal view {
        console.log("==== POST-FLIGHT ====");
        console.log("new batchMinter:     ", newMinter);
        console.log("new USDC (nudge pot):", IERC20(USDC).balanceOf(newMinter));
        console.log("usdc seeded:         ", usdcSeeded);
        console.log("SYA nudge:           ", ISYANudge(SYA).nudge());
        console.log("SYA nudgeSplit:      ", ISYANudge(SYA).nudgeSplit());
        console.log("pooler batchMinter:  ", IBalancerPoolerV2Min(POOLER).batchMinter());
        console.log("pooler BPT remaining:", IERC20(LP_POOL).balanceOf(POOLER));
    }

    function _persist(uint256 usdcSeeded) internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": 1,');
        json = string.concat(json, '"networkName": "mainnet",');
        json = string.concat(json, '"batchMinter": "', vm.toString(newMinter), '",');
        json = string.concat(json, '"oldBatchMinter": "', vm.toString(OLD_BATCH_MINTER), '",');
        json = string.concat(json, '"usdcSeeded": ', vm.toString(usdcSeeded), ",");
        json = string.concat(json, '"timestamp": ', vm.toString(block.timestamp));
        json = string.concat(json, "}");
        vm.writeFile(PROGRESS_PATH, json);
        console.log("Progress file written:", PROGRESS_PATH);
    }
}
