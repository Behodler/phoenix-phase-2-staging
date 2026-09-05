// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IBalancerVault} from "@yield-claim-nft/interfaces/balancer/IBalancerVault.sol";
import {IUnlockCallback} from "@yield-claim-nft/interfaces/balancer/IUnlockCallback.sol";
import {VaultSwapParams, SwapKind} from "@yield-claim-nft/interfaces/balancer/BalancerTypes.sol";

interface IPoolerV2Admin {
    function owner() external view returns (address);
    function authVersion() external view returns (uint256);
    function poolerAuthVersion(address) external view returns (uint256);
    function batchDonationSize() external view returns (uint256);
    function batchMinter() external view returns (address);
    function swapPool() external view returns (address);
    function waUsdc() external view returns (address);
    function usdc() external view returns (address);
    function rescueERC20(address token, address to, uint256 amount) external;
    function setBatchDonationSize(uint256 newSize) external;
    function pool(uint256 minBPT, uint256 minUSDC) external;
}

/// @notice One-shot helper that does the sUSDS -> waUSDC -> USDC -> BatchNFTMinter
///         dance that the broken `BalancerPoolerV2.unlockCallback` was supposed to
///         do (see `docs/balancer-poolerv2-donation-bug.md`). Includes the missing
///         `vault.sendTo` call between `swap` and `redeem`.
///
///         Deployed fresh per script run, called once, then left on-chain (no
///         self-destruct). Holds no state between calls. The `unlockCallback`
///         entry is guarded by `msg.sender == vault`; `execute` is owner-gated.
contract DonationRescueHelper is IUnlockCallback {
    using SafeERC20 for IERC20;

    address public immutable owner;
    address public immutable vault;
    address public immutable swapPool;
    address public immutable sUSDS;
    address public immutable waUsdc;
    address public immutable usdc;
    address public immutable batchMinter;

    error NotOwner();
    error NotVault();
    error UsdcSlippage(uint256 received, uint256 minOut);

    event Donated(uint256 sUSDSIn, uint256 waUsdcMid, uint256 usdcOut);

    constructor(
        address _vault,
        address _swapPool,
        address _sUSDS,
        address _waUsdc,
        address _usdc,
        address _batchMinter
    ) {
        owner = msg.sender;
        vault = _vault;
        swapPool = _swapPool;
        sUSDS = _sUSDS;
        waUsdc = _waUsdc;
        usdc = _usdc;
        batchMinter = _batchMinter;
    }

    /// @notice Owner pre-funds this contract with `sUSDSAmount` of sUSDS, then
    ///         calls `execute` to swap it for USDC and forward to BatchNFTMinter.
    /// @param sUSDSAmount Exact amount of sUSDS to swap. Must already be held here.
    /// @param minUsdcOut  Slippage floor on the final USDC sent to BatchNFTMinter.
    function execute(uint256 sUSDSAmount, uint256 minUsdcOut) external returns (uint256 usdcSent) {
        if (msg.sender != owner) revert NotOwner();
        bytes memory innerData = abi.encode(sUSDSAmount, minUsdcOut);
        bytes memory data = abi.encodeWithSelector(IUnlockCallback.unlockCallback.selector, innerData);
        bytes memory ret = IBalancerVault(vault).unlock(data);
        usdcSent = abi.decode(ret, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != vault) revert NotVault();
        (uint256 sUSDSAmount, uint256 minUsdcOut) = abi.decode(data, (uint256, uint256));

        // 1. Send sUSDS to the vault as the swap input.
        IERC20(sUSDS).safeTransfer(vault, sUSDSAmount);

        // 2. Swap sUSDS -> waUSDC (vault credits us internally).
        VaultSwapParams memory params = VaultSwapParams({
            kind: SwapKind.EXACT_IN,
            pool: swapPool,
            tokenIn: IERC20(sUSDS),
            tokenOut: IERC20(waUsdc),
            amountGivenRaw: sUSDSAmount,
            limitRaw: 0,
            userData: ""
        });
        (, , uint256 waUsdcReceived) = IBalancerVault(vault).swap(params);

        // 3. Settle the sUSDS input we already paid in.
        IBalancerVault(vault).settle(IERC20(sUSDS), sUSDSAmount);

        // 4. Materialize the waUSDC credit into this contract's actual balance.
        //    (This is the line BalancerPoolerV2.unlockCallback is missing.)
        IBalancerVault(vault).sendTo(IERC20(waUsdc), address(this), waUsdcReceived);

        // 5. Unwrap waUSDC -> USDC via ERC4626 redeem.
        uint256 usdcReceived = IERC4626(waUsdc).redeem(
            waUsdcReceived,
            address(this),
            address(this)
        );
        if (usdcReceived < minUsdcOut) revert UsdcSlippage(usdcReceived, minUsdcOut);

        // 6. Forward USDC to BatchNFTMinter.
        IERC20(usdc).safeTransfer(batchMinter, usdcReceived);

        emit Donated(sUSDSAmount, waUsdcReceived, usdcReceived);
        return abi.encode(usdcReceived);
    }
}

/// @notice One-shot maintenance script that:
///
///   1. Rescues the donation-portion (`batchDonationSize%`) of the pooler's
///      sUSDS to the owner — keeps it out of the LP add so it can be donated
///      separately.
///   2. Sets `batchDonationSize = 0` on the pooler so the broken donation
///      branch is skipped on subsequent `pool()` calls (see
///      `docs/balancer-poolerv2-donation-bug.md`).
///   3. Calls `pool(minBPT, 0)` to convert the remaining sUSDS into BPT via
///      the LP-add phase (which is unaffected by the bug).
///   4. Deploys `DonationRescueHelper`, forwards the rescued sUSDS to it, and
///      calls `execute` to swap sUSDS -> waUSDC -> USDC and forward to the
///      BatchNFTMinter — i.e. completes the donation manually.
///
/// Slippage floors are hardcoded based on on-chain quotes captured at
/// script-write time (see `HARDCODED_MIN_*` below). Override with env if
/// conditions move:
///   - `MIN_BPT_WEI`   — slippage floor for `pool()` BPT output.
///   - `MIN_USDC_OUT`  — slippage floor (USDC 6-dec) for the manual donation
///                        swap.
///   - `PREVIEW_MODE=true` impersonates the owner instead of broadcasting.
contract RescuePoolAndDonateUSDC is Script {
    using SafeERC20 for IERC20;

    // Pooler + assets (mainnet)
    address constant POOLER       = 0x4da153dc02bB084528D10335759f2C4447e6f73d;
    address constant OWNER_TARGET = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address constant SUSDS        = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant VAULT        = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address constant BATCH_MINTER = 0x4ef0fDe49360ed31c68ED442Ff263CC6291041f3;

    // Hardcoded slippage floors. Captured from live mainnet reads on
    // 2026-05-20, with the pooler holding 449.497 sUSDS and
    // batchDonationSize = 10%, so lpAmount ≈ 404.55 sUSDS and donationAmount
    // ≈ 44.95 sUSDS. Underlying quotes:
    //   * router.queryAddLiquidityUnbalanced(LP_POOL, [404.55e18, 0], pooler, "")
    //       -> 219.89 BPT.  HARDCODED_MIN_BPT floors at 215 BPT (~2.2% haircut).
    //   * sUSDS.convertToAssets(44.95e18) -> ~49.31 USDS.
    //     USDS:USDC is dollar-pegged ~1:1, so expected USDC ≈ 49.31.
    //       -> HARDCODED_MIN_USDC floors at 46.5 USDC (~5.7% haircut, absorbs
    //          Balancer swap fee + waUSDC unwrap drag + USDS/USDC peg drift).
    // Override via MIN_BPT_WEI / MIN_USDC_OUT env if state moves materially.
    uint256 constant HARDCODED_MIN_BPT  = 215e18;
    uint256 constant HARDCODED_MIN_USDC = 46_500_000;

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");

        IPoolerV2Admin pooler = IPoolerV2Admin(POOLER);

        // Pre-flight introspection
        address poolerOwner = pooler.owner();
        uint256 donationSize = pooler.batchDonationSize();
        address batchMinterCfg = pooler.batchMinter();
        address swapPoolCfg = pooler.swapPool();
        address waUsdcCfg = pooler.waUsdc();
        address usdcCfg = pooler.usdc();
        uint256 sUSDSBalance = IERC20(SUSDS).balanceOf(POOLER);
        uint256 donationAmount = (sUSDSBalance * donationSize) / 100;

        console.log("===== RescuePoolAndDonateUSDC =====");
        console.log("Pooler:                 ", POOLER);
        console.log("Pooler owner:           ", poolerOwner);
        console.log("Expected owner (signer):", OWNER_TARGET);
        console.log("Pooler sUSDS balance:   ", sUSDSBalance);
        console.log("batchDonationSize (%):  ", donationSize);
        console.log("Donation portion sUSDS: ", donationAmount);
        console.log("batchMinter (pooler):   ", batchMinterCfg);
        console.log("swapPool (pooler):      ", swapPoolCfg);
        console.log("waUsdc   (pooler):      ", waUsdcCfg);
        console.log("usdc     (pooler):      ", usdcCfg);
        console.log("BatchNFTMinter target:  ", BATCH_MINTER);

        require(poolerOwner == OWNER_TARGET, "Pooler owner != target");
        require(donationSize > 0, "batchDonationSize already 0 - nothing to rescue");
        require(donationAmount > 0, "Computed donation portion is 0");
        require(batchMinterCfg == BATCH_MINTER, "Pooler batchMinter mismatch");
        require(swapPoolCfg != address(0), "Pooler swapPool unset");
        require(waUsdcCfg != address(0), "Pooler waUsdc unset");
        require(usdcCfg != address(0), "Pooler usdc unset");
        require(
            pooler.poolerAuthVersion(OWNER_TARGET) == pooler.authVersion(),
            "Owner not authorized as pooler - run AuthorizeOwnerAsPoolerV2 first"
        );

        // ---- Slippage floors (hardcoded; see HARDCODED_MIN_* docs) ----
        uint256 minBPT     = vm.envOr("MIN_BPT_WEI",  HARDCODED_MIN_BPT);
        uint256 minUsdcOut = vm.envOr("MIN_USDC_OUT", HARDCODED_MIN_USDC);
        console.log("--- Slippage floors ---");
        console.log("MIN_BPT_WEI:           ", minBPT);
        console.log("MIN_USDC_OUT (6 dec):  ", minUsdcOut);
        require(minBPT > 0,     "minBPT resolved to 0 - refusing to broadcast unprotected");
        require(minUsdcOut > 0, "minUsdcOut resolved to 0 - refusing to broadcast unprotected");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating owner ***");
            vm.startPrank(OWNER_TARGET);
        } else {
            vm.startBroadcast();
        }

        // ---- Step 1: rescueERC20(sUSDS, owner, donationAmount) ----
        pooler.rescueERC20(SUSDS, OWNER_TARGET, donationAmount);
        console.log("Step 1: rescued sUSDS to owner:", donationAmount);

        // ---- Step 2: disable donation phase ----
        pooler.setBatchDonationSize(0);
        console.log("Step 2: setBatchDonationSize(0)");

        // ---- Step 3: pool() the remaining sUSDS into BPT ----
        // After rescue + with donation disabled, pool() only runs the LP-add
        // phase, which is unaffected by the missing-sendTo bug.
        pooler.pool(minBPT, 0);
        console.log("Step 3: pool(minBPT, 0) called");

        // ---- Step 4: deploy one-shot helper ----
        DonationRescueHelper helper = new DonationRescueHelper(
            VAULT,
            swapPoolCfg,
            SUSDS,
            waUsdcCfg,
            usdcCfg,
            BATCH_MINTER
        );
        console.log("Step 4a: helper deployed at:", address(helper));

        // ---- Step 5: forward the rescued sUSDS to the helper and execute ----
        IERC20(SUSDS).safeTransfer(address(helper), donationAmount);
        console.log("Step 4b: forwarded sUSDS to helper:", donationAmount);

        uint256 usdcSent = helper.execute(donationAmount, minUsdcOut);
        console.log("Step 5: helper.execute() complete; USDC sent to BatchNFTMinter:", usdcSent);

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("===== Done =====");
        console.log("BatchNFTMinter USDC balance now:", IERC20(usdcCfg).balanceOf(BATCH_MINTER));
        console.log("Pooler sUSDS balance now:       ", IERC20(SUSDS).balanceOf(POOLER));
    }
}
