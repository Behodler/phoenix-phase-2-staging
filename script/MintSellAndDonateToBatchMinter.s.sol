// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFlax} from "@flax-token/IFlax.sol";
import {ISkyPSM} from "@yield-claim-nft/V2/interfaces/ISkyPSM.sol";

/// @notice Minimal Balancer V3 Router surface: the EXACT_IN swap plus its
///         off-chain quote twin. `querySwapSingleTokenExactIn` is non-view but
///         is designed to be eth_call'd; we invoke it pre-broadcast to size the
///         `minAmountOut` slippage floor from live pool state.
interface IBalancerRouter {
    function swapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bool wethIsEth,
        bytes calldata userData
    ) external payable returns (uint256 amountCalculated);

    function querySwapSingleTokenExactIn(
        address pool,
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 exactAmountIn,
        address sender,
        bytes calldata userData
    ) external returns (uint256 amountCalculated);
}

/// @notice Uniswap Permit2 allowance approval (Balancer V3 pulls via Permit2).
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Subset of the live BalancerPoolerV2 config we cross-check against.
interface IPoolerCfg {
    function batchMinter() external view returns (address);
    function psm() external view returns (address);
}

/**
 * @title MintSellDonateHelper
 * @notice Single-transaction, on-chain executor for the
 *         mint→sell→redeem→(owner gas-comp)→donate flow. Every intermediate
 *         amount (the sUSDS the swap delivers, the USDS
 *         the redeem returns, the USDC the PSM mints) is read LIVE on-chain
 *         inside `execute()` rather than carried across separate broadcast
 *         transactions. This is the hardening fix for the prior multi-tx script,
 *         where Foundry baked the *simulated* swap output into the *next* tx's
 *         `redeem(shares)` calldata; when the live swap returned slightly less
 *         sUSDS than simulated, the redeem reverted `SUsds/insufficient-balance`
 *         (see run-1780570366967, block 25243549).
 *
 * @dev Trust model: the helper is a throwaway contract deployed per run. It holds
 *      funds only transiently within `execute()` and is never granted any
 *      protocol role. `execute()` is `onlyOwner`, so even though the owner
 *      pre-funds it with phUSD and approves it to sweep sUSDS, nobody but the
 *      owner (the broadcasting Ledger) can trigger the flow — no MEV grief window
 *      between the funding txns and `execute()`.
 *
 *      All safety-critical invariants are asserted on-chain, atomically:
 *        - swap output >= `minAmountOut` (the querySwap-sized slippage floor);
 *        - PSM `tout` <= `MAX_TOUT` and `to18ConversionFactor` > 0;
 *        - the owner gas-comp slice is carved only from swap proceeds, paid as
 *          USDS (sweep-proof), and is strictly less than the redeemed total;
 *        - USDS pulled by the PSM <= the donation USDS remaining after comp;
 *        - USDC actually delivered to the batchMinter == the computed `gemAmt`.
 */
contract MintSellDonateHelper {
    using SafeERC20 for IERC20;

    uint256 constant WAD = 1e18;
    // Ceiling on the PSM buy fee, mirroring DispatcherReplaceSkyPoolerAtIndex4's
    // MAX_TOUT (the LitePSM maxTout default, WAD-scaled). tout is currently 0.
    uint256 constant MAX_TOUT = 1e16; // 1%

    address public immutable owner;
    address public immutable phusd;
    address public immutable susds;
    address public immutable usds;
    address public immutable usdc;
    address public immutable pool;
    address public immutable router;
    address public immutable permit2;
    address public immutable skyPsm;
    address public immutable batchMinter;

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(
        address _owner,
        address _phusd,
        address _susds,
        address _usds,
        address _usdc,
        address _pool,
        address _router,
        address _permit2,
        address _skyPsm,
        address _batchMinter
    ) {
        owner = _owner;
        phusd = _phusd;
        susds = _susds;
        usds = _usds;
        usdc = _usdc;
        pool = _pool;
        router = _router;
        permit2 = _permit2;
        skyPsm = _skyPsm;
        batchMinter = _batchMinter;
    }

    /**
     * @notice Atomically: (optionally) sell the phUSD this contract was pre-funded
     *         with for sUSDS, sweep any sUSDS in the owner's wallet, redeem the
     *         combined sUSDS to USDS, hand the owner an `ownerCompPhusd`-proportional
     *         slice of the SWAP proceeds as USDS (gas compensation), and convert the
     *         remaining USDS to USDC delivered straight to the batchMinter via PSM.
     * @dev   The owner slice is paid as USDS, NOT sUSDS, deliberately: a later run's
     *        opening sUSDS sweep (above) would otherwise pull the compensation back
     *        into the helper. The slice is carved only from the freshly-swapped
     *        sUSDS — any swept sUSDS is reserved entirely for the donation.
     * @param phusdToSwap     total phUSD held by this contract to sell (0 = pure sweep).
     * @param minSusdsOut     slippage floor for the swap leg; ignored if phusdToSwap==0.
     * @param ownerCompPhusd  phUSD-equivalent of the swap proceeds to route to the
     *                        owner as USDS (must be < phusdToSwap; 0 = none).
     * @return gemAmt         USDC (6dp) donated to the batchMinter.
     * @return ownerUsdsPaid  USDS handed to the owner as gas compensation.
     */
    function execute(uint256 phusdToSwap, uint256 minSusdsOut, uint256 ownerCompPhusd)
        external
        onlyOwner
        returns (uint256 gemAmt, uint256 ownerUsdsPaid)
    {
        require(ownerCompPhusd == 0 || ownerCompPhusd < phusdToSwap, "owner comp must be < swap amount");

        // ---- Sweep the owner's pre-existing sUSDS into this contract ----
        // Recovers e.g. sUSDS stranded by a previously-failed multi-tx run.
        uint256 ownerSusds = IERC20(susds).balanceOf(owner);
        if (ownerSusds > 0) {
            IERC20(susds).safeTransferFrom(owner, address(this), ownerSusds);
        }

        // ---- Sell phUSD -> sUSDS on the Balancer pool (output lands here) ----
        uint256 swapOut = 0;
        if (phusdToSwap > 0) {
            require(minSusdsOut > 0, "swap floor unset"); // never an unprotected swap
            IERC20(phusd).forceApprove(permit2, type(uint256).max);
            IPermit2(permit2).approve(phusd, router, type(uint160).max, type(uint48).max);
            swapOut = IBalancerRouter(router)
                .swapSingleTokenExactIn(
                    pool, IERC20(phusd), IERC20(susds), phusdToSwap, minSusdsOut, block.timestamp + 300, false, ""
                );
            require(swapOut >= minSusdsOut, "swap below minAmountOut");
        }

        // ---- Redeem ALL sUSDS this contract now holds -> USDS (live amount) ----
        uint256 totalSusds = IERC20(susds).balanceOf(address(this));
        require(totalSusds > 0, "no sUSDS to process");
        uint256 redeemed = IERC4626(susds).redeem(totalSusds, address(this), address(this));
        require(redeemed > 0, "redeem returned 0 USDS");

        // ---- Carve the owner's gas-comp slice out of the SWAP proceeds only ----
        // ownerComp is proportional to the freshly-swapped sUSDS (swept sUSDS is
        // reserved for donation), valued at the live redeem rate. Paid as USDS so a
        // subsequent run's sUSDS sweep cannot pull it back into the helper.
        uint256 donationUsds = redeemed;
        if (ownerCompPhusd > 0) {
            uint256 ownerSusdsShare = (swapOut * ownerCompPhusd) / phusdToSwap;
            ownerUsdsPaid = (redeemed * ownerSusdsShare) / totalSusds;
            require(ownerUsdsPaid > 0, "owner comp rounds to dust");
            require(ownerUsdsPaid < redeemed, "owner comp consumes whole redeem");
            donationUsds = redeemed - ownerUsdsPaid;
            IERC20(usds).safeTransfer(owner, ownerUsdsPaid);
        }

        // ---- Remaining USDS -> USDC via Sky PSM, delivered to the batchMinter ----
        uint256 tout = ISkyPSM(skyPsm).tout();
        require(tout <= MAX_TOUT, "live PSM tout > MAX_TOUT");
        uint256 conv = ISkyPSM(skyPsm).to18ConversionFactor();
        require(conv > 0, "to18ConversionFactor == 0");
        // Floor the USDC out (dust accrues to owner; never over-credits).
        gemAmt = (donationUsds * WAD) / (conv * (WAD + tout));
        require(gemAmt > 0, "donation rounds to dust");
        uint256 usdsSpent = (gemAmt * conv * (WAD + tout)) / WAD;
        require(usdsSpent <= donationUsds, "PSM would pull more USDS than donation");

        uint256 minterBefore = IERC20(usdc).balanceOf(batchMinter);
        IERC20(usds).forceApprove(skyPsm, usdsSpent);
        ISkyPSM(skyPsm).buyGem(batchMinter, gemAmt);
        IERC20(usds).forceApprove(skyPsm, 0);
        require(IERC20(usdc).balanceOf(batchMinter) - minterBefore == gemAmt, "USDC delta != gemAmt");

        // ---- Return residual USDS dust (from flooring) to the owner ----
        uint256 dust = IERC20(usds).balanceOf(address(this));
        if (dust > 0) IERC20(usds).safeTransfer(owner, dust);
    }
}

/**
 * @title MintSellAndDonateToBatchMinter
 * @notice One-shot mainnet operational flow that tops up the BatchNFTMinter
 *         USDC pot by minting fresh phUSD and routing it to USDC the same way
 *         the live Sky-PSM BalancerPoolerV2 donates (see story 056 /
 *         `DispatcherReplaceSkyPoolerAtIndex4.s.sol`):
 *
 *           1. Mint (`BATCH_DONATION_PHUSD_WEI` + `OWNER_COMP_PHUSD_WEI`) phUSD
 *              (default 130e18 + 0 = 130e18; owner gas-comp off by default) into a
 *              throwaway MintSellDonateHelper via the signer's authorized-minter role.
 *           2–5. In a SINGLE atomic `helper.execute()` call: sweep any sUSDS in
 *              the signer's wallet, sell the phUSD for sUSDS on the canonical
 *              Balancer V3 50/50 phUSD/sUSDS pool, redeem the combined sUSDS to
 *              USDS (ERC4626), pay the signer/owner the `OWNER_COMP_PHUSD_WEI`-
 *              worth slice of the swap proceeds as USDS (gas compensation that
 *              survives future sweeps because it is USDS, not sUSDS), and convert
 *              the remaining USDS -> USDC through the Sky PSM (`buyGem`) delivered
 *              directly to the BatchNFTMinter.
 *
 * @dev Hardening (vs the prior multi-tx version that reverted at redeem):
 *        - The amount-dependent chain (swap -> redeem -> buyGem) runs entirely
 *          inside one on-chain tx, so no simulated return value is ever baked
 *          into a later tx's calldata. The redeem operates on the helper's LIVE
 *          sUSDS balance, not a stale simulated figure.
 *        - The helper additionally sweeps the signer's existing sUSDS, recovering
 *          anything stranded by a previous partial run.
 *
 *      Safety (see CLAUDE.md "Configuration Safety"):
 *        - chainid pinned to mainnet (1).
 *        - Swap `minAmountOut` is NEVER 0 when swapping: sized from a live
 *          `querySwap` quote minus `SLIPPAGE_BPS` (default 100 = 1%), or an
 *          explicit `MIN_SUSDS_OUT_WEI` override. The helper reverts rather than
 *          broadcast an unprotected swap.
 *        - PSM `tout`/`to18ConversionFactor`, over-pull and USDC-delta invariants
 *          are all asserted on-chain inside `execute()`.
 *        - The donation target (`BATCH_MINTER`) and PSM (`SKY_PSM`) are asserted
 *          against the live pooler's own config so this script and the protocol
 *          always agree on where funds land.
 *
 *      Env:
 *        - PREVIEW_MODE=true        impersonate OWNER instead of broadcasting.
 *        - BATCH_DONATION_PHUSD_WEI phUSD-worth donated to the BatchNFTMinter
 *                                   (wei). Default 130e18. Set this AND
 *                                   OWNER_COMP_PHUSD_WEI to 0 for a PURE SWEEP
 *                                   (donate only wallet sUSDS; no new minting).
 *        - OWNER_COMP_PHUSD_WEI     phUSD-worth of swap proceeds paid to the owner
 *                                   as USDS gas compensation. Default 0 (off). When
 *                                   set, must be < the total minted (donation + comp).
 *        - SLIPPAGE_BPS             swap slippage in bps. Default 100 (1%).
 *        - MIN_SUSDS_OUT_WEI        hard override for the swap floor (skips quote).
 */
contract MintSellAndDonateToBatchMinter is Script {
    // ---- Protocol / token addresses (mainnet, verified live 2026-06-04) ----
    address constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // sUSDS.asset()
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Canonical Balancer V3 50/50 weighted phUSD/sUSDS pool + its router/permit2.
    address constant POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04;
    address constant ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Sky USDS<->USDC PSM (UsdsPsmWrapper "LitePSMWrapper-USDS-USDC").
    address constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    // Donation target: the live BatchNFTMinter (also the Sky pooler's batchMinter()).
    address constant BATCH_MINTER = 0x6e9886AfDF07DD67dc70b8335E4e9DF14B445071;

    // The live Sky-PSM BalancerPoolerV2 (index-4) — used only to cross-check that
    // our PSM + batchMinter constants match the protocol's own config.
    address constant LIVE_POOLER = 0x7f74388bc970dE5e2822036A1aD06fCCd156786b;

    // Owner / signer — Ledger index 46 (m/44'/60'/46'/0/0), authorized phUSD minter.
    address constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    function run() external {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");

        uint256 donationPhusd = vm.envOr("BATCH_DONATION_PHUSD_WEI", uint256(130e18));
        uint256 ownerCompPhusd = vm.envOr("OWNER_COMP_PHUSD_WEI", uint256(0));
        uint256 phusdAmount = donationPhusd + ownerCompPhusd; // total to mint + sell
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(100)); // 1%
        require(slippageBps < 10_000, "SLIPPAGE_BPS >= 100%");
        // A pure sweep zeroes BOTH portions; otherwise the donation must be > 0 so
        // the owner-comp carve (which must be < total) can never starve the donation.
        require(phusdAmount == 0 || donationPhusd > 0, "donation portion must be > 0");
        require(ownerCompPhusd == 0 || ownerCompPhusd < phusdAmount, "owner comp must be < total minted");

        console.log("===== MintSellAndDonateToBatchMinter (atomic) =====");
        console.log("phUSD to mint+sell (wei):  ", phusdAmount);
        console.log("  - batch donation portion:", donationPhusd);
        console.log("  - owner gas-comp portion:", ownerCompPhusd);
        console.log("Slippage (bps):            ", slippageBps);

        // ---- Cross-check our constants against the live pooler's config ----
        require(IPoolerCfg(LIVE_POOLER).batchMinter() == BATCH_MINTER, "batchMinter != live pooler");
        require(IPoolerCfg(LIVE_POOLER).psm() == SKY_PSM, "PSM != live pooler");
        require(IERC4626(SUSDS).asset() == USDS, "sUSDS.asset() != USDS");
        require(ISkyPSM(SKY_PSM).gem() == USDC, "PSM gem != USDC");
        require(ISkyPSM(SKY_PSM).usds() == USDS, "PSM usds != USDS");

        // ---- Size the swap slippage floor (NEVER 0 when we swap) ----
        uint256 minSusdsOut = 0;
        if (phusdAmount > 0) {
            minSusdsOut = vm.envOr("MIN_SUSDS_OUT_WEI", uint256(0));
            if (minSusdsOut == 0) {
                // Live quote of selling `phusdAmount` phUSD for sUSDS, then haircut.
                //
                // Two forge-vs-eth_call quirks have to be handled:
                //   1. Balancer V3's `quote` only runs in "query mode", which it detects
                //      via `tx.origin == address(0)` (true under an off-chain eth_call,
                //      false in a forge script) — so we spoof tx.origin to 0.
                //   2. Query mode relies on eth_call discarding state; called as a normal
                //      forge `.call` it actually MUTATES the pool balances (it "sells" the
                //      phUSD into the pool), which would mis-price the real swap below.
                //      So we snapshot before and revert after to discard the side effects.
                uint256 snap = vm.snapshotState();
                vm.prank(address(0), address(0));
                (bool ok, bytes memory ret) = ROUTER.call(
                    abi.encodeWithSelector(
                        IBalancerRouter.querySwapSingleTokenExactIn.selector,
                        POOL,
                        IERC20(PHUSD),
                        IERC20(SUSDS),
                        phusdAmount,
                        OWNER,
                        bytes("")
                    )
                );
                vm.revertToState(snap);
                require(ok, "querySwap failed - pass MIN_SUSDS_OUT_WEI");
                uint256 quoted = abi.decode(ret, (uint256));
                require(quoted > 0, "querySwap returned 0 - pass MIN_SUSDS_OUT_WEI");
                minSusdsOut = (quoted * (10_000 - slippageBps)) / 10_000;
                console.log("querySwap sUSDS out:      ", quoted);
            }
            require(minSusdsOut > 0, "minSusdsOut resolved to 0 - refusing unprotected swap");
            console.log("Swap minAmountOut (sUSDS):", minSusdsOut);
        } else {
            console.log("*** PURE SWEEP MODE - no minting, donating only wallet sUSDS ***");
        }

        uint256 ownerSusds = IERC20(SUSDS).balanceOf(OWNER);
        console.log("OWNER sUSDS to be swept:  ", ownerSusds);
        require(phusdAmount > 0 || ownerSusds > 0, "nothing to do: no mint amount and no sUSDS to sweep");

        bool isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("*** PREVIEW MODE - impersonating OWNER ***");
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }

        // ---- Deploy the per-run atomic executor ----
        MintSellDonateHelper helper =
            new MintSellDonateHelper(OWNER, PHUSD, SUSDS, USDS, USDC, POOL, ROUTER, PERMIT2, SKY_PSM, BATCH_MINTER);
        console.log("Helper deployed at:       ", address(helper));

        // ---- Mint fresh phUSD straight into the helper (signer's minter role) ----
        if (phusdAmount > 0) {
            IFlax phUSD = IFlax(PHUSD);
            if (!phUSD.authorizedMinters(OWNER).canMint) {
                console.log("OWNER not authorized minter - calling setMinter(OWNER, true)");
                phUSD.setMinter(OWNER, true);
            }
            phUSD.mint(address(helper), phusdAmount);
            console.log("Minted phUSD into helper: ", phusdAmount);
        }

        // ---- Approve the helper to sweep the owner's existing sUSDS ----
        if (ownerSusds > 0) {
            IERC20(SUSDS).approve(address(helper), ownerSusds);
        }

        uint256 minterUsdcBefore = IERC20(USDC).balanceOf(BATCH_MINTER);
        uint256 ownerUsdsBefore = IERC20(USDS).balanceOf(OWNER);

        // ---- The atomic swap -> sweep -> redeem -> owner gas-comp -> donate ----
        (uint256 donated, uint256 ownerPaid) = helper.execute(phusdAmount, minSusdsOut, ownerCompPhusd);

        // ---- Revoke the sweep approval (helper is throwaway, but be tidy) ----
        if (ownerSusds > 0) {
            IERC20(SUSDS).approve(address(helper), 0);
        }

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        uint256 usdcDelta = IERC20(USDC).balanceOf(BATCH_MINTER) - minterUsdcBefore;
        require(usdcDelta == donated, "USDC delta != donated");
        // Owner USDS delta = the gas-comp slice + any flooring dust returned.
        uint256 ownerUsdsDelta = IERC20(USDS).balanceOf(OWNER) - ownerUsdsBefore;
        require(ownerUsdsDelta >= ownerPaid, "owner USDS delta < comp paid");
        console.log("USDC donated to BatchNFTMinter:  ", donated);
        console.log("USDS paid to owner (gas comp):   ", ownerPaid);
        console.log("Owner USDS delta (incl dust):    ", ownerUsdsDelta);
        console.log("BatchNFTMinter USDC balance now: ", IERC20(USDC).balanceOf(BATCH_MINTER));
        console.log("===== Done =====");
    }
}
