// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {StdCheats} from "@forge-std/StdCheats.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/dispatchers/BalancerPoolerV2.sol";
import {BalancerPoolerMintDebtHook} from "@yield-claim-nft/hooks/BalancerPoolerMintDebtHook.sol";
import {IBalancerPoolerMintDebtHook} from "@yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";
import {ISkyPSM} from "@yield-claim-nft/interfaces/ISkyPSM.sol";
import {NFTStaker} from "nft-staking/NFTStaker.sol";

/// @title DispatcherReplaceSkyPoolerAtIndex4
/// @notice Single owner-signed Foundry broadcast cutting NFTMinterV2 dispatcher
///         INDEX 4 over from the current live (nudge) BalancerPoolerV2 to a freshly
///         deployed Sky-route BalancerPoolerV2 + new BalancerPoolerMintDebtHook.
///
///         Story 056. The live index-4 pooler's owner-triggered `pool()` reverts on
///         mainnet because its batch donation swaps sUSDS->waUSDC on a structurally
///         unseeded Balancer V3 pool (`MaxImbalanceRatioExceeded()`), aborting the
///         atomic `pool()`. The fixed artifact (yield-claim-nft story 34) reroutes the
///         donation through the Sky PSM (USDS->USDC via `buyGem`) inside `_dispatch`,
///         isolated in try/catch, and makes `pool(uint256 minBPT)` a pure single-arg
///         LP add. This script installs that fixed pooler at index 4 while keeping the
///         NFT id == 4 and the NFTStaker (stakedId=4 / dispatcherIndex=4) unchanged --
///         only the `configs[4]` dispatcher pointer flips via `replaceDispatcher(4,..)`.
///
///         Differences vs. DispatcherReplaceAtIndex4.s.sol (story 048):
///           - the CURRENT index-4 dispatcher is the live nudge pooler; it is read from
///             chain (`configs(4).dispatcher`) and asserted == the known live address;
///           - the story-048 index-6 cleanup (bugged-pooler drain, founder id-6 burn,
///             setDispatcherDisabled(6)) is OMITTED;
///           - ADDED: an sUSDS sweep from the old pooler, a one-time manual Sky-route
///             validation donation (10% of swept sUSDS), seeding of the new pooler with
///             the remaining 90% sUSDS + the migrated BPT, and a final `pool(minBPT)`
///             with a derived (router-queried) `minBPT > 0`.
///
///         Full rationale:
///           scratchpad/planning-docs/phoenix/phase2/vault/
///             balancer-poolerv2-sky-psm-donation-route-plan-June-03-2026.md
///         Executable spec / checklist in story 056.
///
///         Modes:
///           PREVIEW_MODE=true  -> startPrank(OWNER_ADDRESS), no broadcast
///           PREVIEW_MODE=false -> startBroadcast() (ledger-signed)
///
///         Dry run:
///           PREVIEW_MODE=true forge script \
///             script/DispatcherReplaceSkyPoolerAtIndex4.s.sol \
///             --rpc-url $RPC_MAINNET --slow -vvv
///
///         Broadcast (ledger, index 46):
///           forge script script/DispatcherReplaceSkyPoolerAtIndex4.s.sol \
///             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
///             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
contract DispatcherReplaceSkyPoolerAtIndex4 is Script, StdCheats {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    address public constant PHUSD            = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant NFT_MINTER_V2    = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant NFT_STAKER       = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b;

    // Current live index-4 pooler (nudge pooler). Read from chain and asserted ==
    // this constant (`nftsV2.BalancerPooler` in mainnet-addresses.ts).
    address public constant LIVE_INDEX4_POOLER = 0x26F89f4B46eB164303985795ee20b15BB1Edb38A;

    // Owner / ledger signer (HD path m/44'/60'/46'/0/0).
    address public constant OWNER_ADDRESS    = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Sky USDS<->USDC PSM (UsdsPsmWrapper "LitePSMWrapper-USDS-USDC"), verified live.
    address public constant SKY_PSM          = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    // USDS (18dp) is the sUSDS underlying / PSM stablecoin; USDC (6dp) is the gem.
    address public constant USDC             = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ==========================================
    //         SCRIPT CONSTANTS
    // ==========================================

    // BalancerRouter address used by the existing pooler deployments. BalancerPoolerV2
    // does NOT expose a router() getter (the field is `address private immutable
    // _router`), so we mirror the deploy-time constant (DeployMainnetNudgePoolerV2 /
    // DispatcherReplaceAtIndex4: 0x5C6f...9FDd).
    address public constant BALANCER_ROUTER  = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;

    // sUSDSIsFirst constant -- mirrored from the prior deploys (SUSDS_IS_FIRST=true).
    bool public constant SUSDS_IS_FIRST      = true;

    // WAD-scaled ceiling on the PSM buy fee, mirroring the contract's maxTout default.
    uint256 public constant MAX_TOUT         = 0.01e18;
    uint256 internal constant WAD            = 1e18;

    // Percent of the swept sUSDS routed through the manual Sky-route validation.
    uint256 public constant VALIDATION_PCT   = 10;

    // Slippage tolerance (bps) subtracted from the router's ideal-BPT quote to derive
    // the `minBPT` floor for the final pool(). 100 bps = 1%.
    uint256 public constant MIN_BPT_TOLERANCE_BPS = 100;

    // Default `minBPT` floor (overridable via MIN_BPT_WEI env). Derived offline from a
    // live router `queryAddLiquidityUnbalanced` for the ~90% seed (~527.71 sUSDS) on
    // 2026-06-04 (~287.85 BPT), minus the 1% tolerance, floored conservatively. See the
    // full derivation comment in _step15_pool(). Re-query before broadcast if state
    // moved. NOTE: this is the slippage FLOOR; the pool() will mint more than this.
    uint256 public constant DEFAULT_MIN_BPT = 284e18;

    // ==========================================
    //         RUNTIME-CAPTURED STATE
    // ==========================================

    address public oldPooler;        // configs(4).dispatcher BEFORE the cutover
    address public oldHook;          // NFTStaker.dispatcherHook() BEFORE the cutover

    address public newPooler;        // deployed in step 4
    address public newHook;          // deployed in step 5

    address public bpt;              // BPT (LP token) address = oldPooler.pool()
    address public sUSDS_;           // sUSDS (ERC4626) address from oldPooler
    address public balancerVault_;   // Balancer vault from oldPooler

    uint256 public preBptOld;        // BPT held by oldPooler at snapshot
    uint256 public preSusdsOld;      // sUSDS held by oldPooler at snapshot
    uint256 public preOldHookMintDebt;

    uint256 public batchDonationSize_;
    address public batchMinter_;

    uint256 public sweptSUSDS;       // sUSDS pulled from oldPooler to the owner
    uint256 public seededSUSDS;      // 90% remaining seeded into the new pooler
    uint256 public derivedMinBPT;
    bool public poolExecuted;        // true iff the final pool() LP add succeeded

    bool internal isPreview;

    function setUp() public {
        require(block.chainid == 1 || block.chainid == 31337, "Wrong chain id - expected Mainnet (1) or Anvil fork (31337)");
    }

    function run() external {
        console.log("===================================================");
        console.log(" DispatcherReplaceSkyPoolerAtIndex4 -- single cutover");
        console.log("===================================================");
        console.log("Chain id:                 ", block.chainid);
        console.log("NFTMinterV2:              ", NFT_MINTER_V2);
        console.log("NFTStaker:                ", NFT_STAKER);
        console.log("phUSD:                    ", PHUSD);
        console.log("Live index-4 pooler:      ", LIVE_INDEX4_POOLER);
        console.log("Sky PSM:                  ", SKY_PSM);
        console.log("Owner (ledger signer):    ", OWNER_ADDRESS);

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE -- impersonating owner via prank ***");
            console.log("");
        }

        // ====== Pre-flight (no broadcast) ======
        _step1_snapshotPreState();
        _verifyStakerOwner();

        if (isPreview) {
            vm.startPrank(OWNER_ADDRESS);
        } else {
            vm.startBroadcast();
        }

        _step3_drainOldHookDebt();
        _step4_deployNewPooler();
        _step5_deployNewHook();
        _step6_wireNewHook();
        _step7_mirrorPoolerConfig();
        _step8_withdrawBPT();
        _step9_sweepSUSDS();
        _step10_manualSkyRouteValidation();
        _step11_seedNewPooler();
        _step12_swapStakerHook();
        _step13_replaceDispatcher4();
        _step14_decommissionOldHook();
        // Cutover invariants are confirmed BEFORE the LP add so the dispatcher swap is
        // verified independent of pool()'s outcome.
        _step15_postStateLog();

        if (isPreview) {
            // PREVIEW ONLY: prove the cutover left index 4 fully mintable end-to-end.
            // Uses the `deal` cheatcode (fork-only); runs before stopPrank and never on a
            // real broadcast. Done before the LP add so dispatch is validated regardless of
            // whether pool() succeeds.
            _step16_previewE2EMint();
        }

        // FINAL, ISOLATED action -- intentionally the LAST state-changing call. A pool()
        // failure (minBPT estimate too high, or live pool drift between the offline quote
        // and broadcast) is caught inside the step so it can NEVER roll back or block the
        // already-committed cutover above. See _step17_finalPool for the recovery path.
        _step17_finalPool();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("");
        console.log("===================================================");
        console.log(" Cutover complete (in-memory only if preview)");
        console.log("===================================================");
    }

    // ==========================================
    // Step 1: Snapshot pre-state
    // ==========================================

    function _step1_snapshotPreState() internal {
        console.log("");
        console.log("=== Step 1: Snapshot pre-state ===");

        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        (address d4,,,) = minter.configs(4);
        require(d4 != address(0), "index 4 not registered");
        require(
            d4 == LIVE_INDEX4_POOLER,
            "configs(4).dispatcher != known live index-4 pooler constant"
        );
        oldPooler = d4;

        // Read current hook from staker (public dispatcherHook storage var).
        oldHook = address(NFTStaker(NFT_STAKER).dispatcherHook());
        require(oldHook != address(0), "NFTStaker.dispatcherHook == address(0)");
        preOldHookMintDebt = BalancerPoolerMintDebtHook(oldHook).mintDebt();

        // Read BPT / sUSDS / vault constructor args we will mirror onto the new pooler.
        bpt = BalancerPoolerV2(oldPooler).pool();
        require(bpt != address(0), "oldPooler.pool() == 0");
        sUSDS_ = BalancerPoolerV2(oldPooler).sUSDS();
        require(sUSDS_ != address(0), "oldPooler.sUSDS() == 0");
        balancerVault_ = BalancerPoolerV2(oldPooler).vault();
        require(balancerVault_ != address(0), "oldPooler.vault() == 0");

        preBptOld   = IERC20Minimal(bpt).balanceOf(oldPooler);
        preSusdsOld = IERC20Minimal(sUSDS_).balanceOf(oldPooler);

        // Donation-phase config to mirror onto the new pooler.
        batchDonationSize_ = BalancerPoolerV2(oldPooler).batchDonationSize();
        batchMinter_       = BalancerPoolerV2(oldPooler).batchMinter();

        console.log("oldPooler (configs(4).dispatcher):", oldPooler);
        console.log("oldHook (NFTStaker.dispatcherHook):", oldHook);
        console.log("oldHook.mintDebt():                ", preOldHookMintDebt);
        console.log("BPT token (oldPooler.pool()):      ", bpt);
        console.log("BPT.balanceOf(oldPooler):          ", preBptOld);
        console.log("sUSDS (from oldPooler):            ", sUSDS_);
        console.log("sUSDS.balanceOf(oldPooler):        ", preSusdsOld);
        console.log("BalancerVault (from oldPooler):    ", balancerVault_);
        console.log("BalancerRouter (script constant):  ", BALANCER_ROUTER);
        console.log("sUSDSIsFirst (script constant):    ", SUSDS_IS_FIRST);
        console.log("batchDonationSize (from oldPooler):", batchDonationSize_);
        console.log("batchMinter (from oldPooler):      ", batchMinter_);

        require(batchMinter_ != address(0), "oldPooler.batchMinter == 0 (manual Sky route needs it)");
        require(preSusdsOld > 0, "oldPooler holds no sUSDS to migrate");
    }

    function _verifyStakerOwner() internal view {
        address stakerOwner = NFTStaker(NFT_STAKER).owner();
        console.log("NFTStaker.owner(): ", stakerOwner);
        require(stakerOwner == OWNER_ADDRESS, "Staker owner mismatch -- pullAndRefresh would revert");

        address minterOwner = NFTMinterV2(NFT_MINTER_V2).owner();
        console.log("NFTMinterV2.owner():", minterOwner);
        require(minterOwner == OWNER_ADDRESS, "Minter owner mismatch -- replaceDispatcher would revert");
    }

    // ==========================================
    // Step 3: drain old-hook debt
    // ==========================================

    function _step3_drainOldHookDebt() internal {
        console.log("");
        console.log("=== Step 3: NFTStaker.pullAndRefresh() ===");
        NFTStaker(NFT_STAKER).pullAndRefresh();
        uint256 postDebt = BalancerPoolerMintDebtHook(oldHook).mintDebt();
        console.log("oldHook.mintDebt() after pullAndRefresh:", postDebt);
        require(postDebt == 0, "oldHook.mintDebt != 0 after pullAndRefresh");
    }

    // ==========================================
    // Step 4: deploy new BalancerPoolerV2 (Sky-route artifact)
    // ==========================================

    function _step4_deployNewPooler() internal {
        console.log("");
        console.log("=== Step 4: deploy new BalancerPoolerV2 (Sky-route) ===");
        BalancerPoolerV2 p = new BalancerPoolerV2(
            sUSDS_,
            bpt,            // pool() / BPT token
            balancerVault_,
            BALANCER_ROUTER,
            SUSDS_IS_FIRST,
            OWNER_ADDRESS
        );
        newPooler = address(p);
        console.log("newPooler:", newPooler);
        console.log("  sUSDS:        ", sUSDS_);
        console.log("  pool:         ", bpt);
        console.log("  vault:        ", balancerVault_);
        console.log("  router:       ", BALANCER_ROUTER);
        console.log("  sUSDSIsFirst: ", SUSDS_IS_FIRST);
        console.log("  owner:        ", OWNER_ADDRESS);
    }

    // ==========================================
    // Step 5: deploy new BalancerPoolerMintDebtHook
    // ==========================================

    function _step5_deployNewHook() internal {
        console.log("");
        console.log("=== Step 5: deploy new BalancerPoolerMintDebtHook ===");
        BalancerPoolerMintDebtHook h = new BalancerPoolerMintDebtHook(
            OWNER_ADDRESS,
            newPooler,
            PHUSD
        );
        newHook = address(h);
        console.log("newHook:", newHook);
        console.log("  initialOwner:", OWNER_ADDRESS);
        console.log("  dispatcher:  ", newPooler);
        console.log("  phUSD:       ", PHUSD);
    }

    // ==========================================
    // Step 6: wire new hook
    // ==========================================

    function _step6_wireNewHook() internal {
        console.log("");
        console.log("=== Step 6: wire new hook ===");

        BalancerPoolerV2(newPooler).setHook(IDispatchHook(newHook));
        console.log("newPooler.setHook(newHook)");

        // CRITICAL: authorize NFTMinterV2 as the dispatch caller on the new pooler.
        // ATokenDispatcherV2.dispatch() is gated by `onlyMinter` (msg.sender == _minter).
        // The pooler constructor does NOT set _minter (it inits hook + owner only), and
        // NFTMinterV2.replaceDispatcher does NOT set it either -- verified on-chain: the
        // story-048 replaceDispatcher install tx (0xa72ff101...) is a pure storage write
        // with no internal call into the pooler, and the live pooler's _minter was wired
        // by a SEPARATE FixBalancerPoolerV2SetMinter / SetMinterOnIndex4Pooler tx. Without
        // this call the very first index-4 mint after the cutover reverts
        // "ATokenDispatcherV2: caller is not minter" and index-4 minting is bricked.
        BalancerPoolerV2(newPooler).setMinter(NFT_MINTER_V2);
        console.log("newPooler.setMinter(NFTMinterV2):", NFT_MINTER_V2);

        // _minter has no public getter; assert via raw storage slot so the script refuses
        // to proceed with an unwired dispatcher. Storage layout verified against the live
        // pooler 0x26F8...b38a: slot0 = Ownable._owner (packed with Pausable._paused),
        // slot1 = ATokenDispatcherV2._minter. Same contract code => same layout here.
        address wiredMinter = address(uint160(uint256(vm.load(newPooler, bytes32(uint256(1))))));
        require(wiredMinter == NFT_MINTER_V2, "newPooler._minter (slot1) != NFTMinterV2 after setMinter");
        console.log("newPooler._minter (slot1) verified == NFTMinterV2");

        BalancerPoolerMintDebtHook(newHook).setRecipient(NFT_STAKER);
        console.log("newHook.setRecipient(NFTStaker):", NFT_STAKER);

        IFlaxMinimal(PHUSD).setMinter(newHook, true);
        console.log("phUSD.setMinter(newHook, true)");
    }

    // ==========================================
    // Step 7: mirror pooler config (incl. Sky-route PSM config)
    // ==========================================

    function _step7_mirrorPoolerConfig() internal {
        console.log("");
        console.log("=== Step 7: mirror pooler config + Sky-route PSM config ===");

        BalancerPoolerV2 newP = BalancerPoolerV2(newPooler);

        newP.setBatchDonationSize(batchDonationSize_);
        console.log("newPooler.setBatchDonationSize:", batchDonationSize_);

        newP.setBatchMinter(batchMinter_);
        console.log("newPooler.setBatchMinter:", batchMinter_);

        newP.setPSM(SKY_PSM);
        console.log("newPooler.setPSM:", SKY_PSM);

        newP.setMaxTout(MAX_TOUT);
        console.log("newPooler.setMaxTout:", MAX_TOUT);

        // Authorise the owner ledger as a pooler so it can call pool(minBPT).
        newP.setAuthorizedPooler(OWNER_ADDRESS, true);
        require(
            newP.poolerAuthVersion(OWNER_ADDRESS) == newP.authVersion(),
            "deployer not authorised on new pooler after setAuthorizedPooler"
        );
        console.log("newPooler.setAuthorizedPooler(OWNER, true): OK");
    }

    // ==========================================
    // Step 8: withdraw BPT from old pooler to the owner
    // ==========================================

    function _step8_withdrawBPT() internal {
        console.log("");
        console.log("=== Step 8: oldPooler.withdrawBPT(OWNER, bptBal) ===");
        uint256 oldBal = IERC20Minimal(bpt).balanceOf(oldPooler);
        console.log("BPT.balanceOf(oldPooler):", oldBal);
        if (oldBal > 0) {
            uint256 ownerBefore = IERC20Minimal(bpt).balanceOf(OWNER_ADDRESS);
            BalancerPoolerV2(oldPooler).withdrawBPT(OWNER_ADDRESS, oldBal);
            uint256 ownerAfter = IERC20Minimal(bpt).balanceOf(OWNER_ADDRESS);
            require(ownerAfter - ownerBefore == oldBal, "BPT withdraw delta mismatch");
            require(IERC20Minimal(bpt).balanceOf(oldPooler) == 0, "oldPooler still holds BPT");
            console.log("Withdrew BPT to owner:", oldBal);
        } else {
            console.log("  (oldPooler holds zero BPT -- skipping withdrawBPT)");
        }
    }

    // ==========================================
    // Step 9: sweep sUSDS from old pooler to the owner
    // ==========================================

    function _step9_sweepSUSDS() internal {
        console.log("");
        console.log("=== Step 9: oldPooler.rescueERC20(sUSDS, OWNER, susdsBal) ===");
        uint256 oldSusds = IERC20Minimal(sUSDS_).balanceOf(oldPooler);
        require(oldSusds > 0, "oldPooler holds no sUSDS to sweep");

        uint256 ownerBefore = IERC20Minimal(sUSDS_).balanceOf(OWNER_ADDRESS);
        BalancerPoolerV2(oldPooler).rescueERC20(sUSDS_, OWNER_ADDRESS, oldSusds);
        uint256 ownerAfter = IERC20Minimal(sUSDS_).balanceOf(OWNER_ADDRESS);
        sweptSUSDS = ownerAfter - ownerBefore;
        require(sweptSUSDS == oldSusds, "sUSDS sweep delta mismatch");
        require(IERC20Minimal(sUSDS_).balanceOf(oldPooler) == 0, "oldPooler still holds sUSDS");
        console.log("Swept sUSDS to owner:", sweptSUSDS);
    }

    // ==========================================
    // Step 10: one-time MANUAL Sky-route validation donation (10% of swept sUSDS)
    // ==========================================
    //
    // Distinct from the contract's automatic per-dispatch donation. Its sole purpose is
    // to fail-fast in PREVIEW if any of {sUSDS, USDS, PSM, USDC, batchMinter} is
    // misconfigured: it routes 10% of the swept sUSDS through the EXACT redeem->PSM
    // path the new pooler is configured to use, delivering the USDC to batchMinter.
    function _step10_manualSkyRouteValidation() internal {
        console.log("");
        console.log("=== Step 10: manual Sky-route validation (10% of swept sUSDS) ===");

        uint256 tenPctShares = (sweptSUSDS * VALIDATION_PCT) / 100;
        require(tenPctShares > 0, "10% validation share rounds to zero");
        console.log("10% sUSDS shares for validation:", tenPctShares);

        // Redeem sUSDS shares -> USDS (owner holds the shares post-sweep).
        uint256 usds = IERC4626Minimal(sUSDS_).redeem(tenPctShares, OWNER_ADDRESS, OWNER_ADDRESS);
        require(usds > 0, "redeem returned 0 USDS");
        address usdsToken = IERC4626Minimal(sUSDS_).asset();
        console.log("USDS token (sUSDS.asset()):", usdsToken);
        console.log("USDS redeemed:             ", usds);

        // Read/assert tout, then size the USDC out with the SAME floored math the
        // contract uses (dust accrues to the protocol; never over-credits).
        uint256 tout = ISkyPSM(SKY_PSM).tout();
        require(tout <= MAX_TOUT, "live PSM tout > MAX_TOUT");
        uint256 conv = ISkyPSM(SKY_PSM).to18ConversionFactor();
        require(conv > 0, "to18ConversionFactor == 0");
        uint256 gemAmt = (usds * WAD) / (conv * (WAD + tout));
        require(gemAmt > 0, "validation donation rounds to dust");
        uint256 usdsSpent = gemAmt * conv * (WAD + tout) / WAD;
        require(usdsSpent <= usds, "PSM would pull more USDS than redeemed");
        console.log("tout:                      ", tout);
        console.log("to18ConversionFactor:      ", conv);
        console.log("gemAmt (USDC out, floored):", gemAmt);
        console.log("usdsSpent (<= redeemed):   ", usdsSpent);

        uint256 minterUsdcBefore = IERC20Minimal(USDC).balanceOf(batchMinter_);

        // forceApprove pattern: approve exact spend, buy, reset to 0.
        IERC20Minimal(usdsToken).approve(SKY_PSM, 0);
        IERC20Minimal(usdsToken).approve(SKY_PSM, usdsSpent);
        ISkyPSM(SKY_PSM).buyGem(batchMinter_, gemAmt);
        IERC20Minimal(usdsToken).approve(SKY_PSM, 0);

        uint256 minterUsdcAfter = IERC20Minimal(USDC).balanceOf(batchMinter_);
        uint256 usdcDelta = minterUsdcAfter - minterUsdcBefore;
        console.log("batchMinter USDC before:   ", minterUsdcBefore);
        console.log("batchMinter USDC after:    ", minterUsdcAfter);
        console.log("batchMinter USDC delta:    ", usdcDelta);
        require(usdcDelta == gemAmt, "manual Sky-route donation: USDC delta != gemAmt");
        console.log("Manual Sky-route validation: OK");
    }

    // ==========================================
    // Step 11: seed new pooler with remaining 90% sUSDS + migrated BPT
    // ==========================================

    function _step11_seedNewPooler() internal {
        console.log("");
        console.log("=== Step 11: seed new pooler (remaining sUSDS + BPT) ===");

        // Remaining sUSDS the owner still holds after the 10% validation redeem. Using
        // the live owner balance (not 90% arithmetic) guarantees we seed exactly what is
        // available -- the redeem consumed only the 10% slice.
        uint256 remainingSUSDS = IERC20Minimal(sUSDS_).balanceOf(OWNER_ADDRESS);
        require(remainingSUSDS > 0, "no remaining sUSDS to seed");
        require(IERC20Minimal(sUSDS_).transfer(newPooler, remainingSUSDS), "sUSDS seed transfer failed");
        seededSUSDS = remainingSUSDS;
        console.log("Seeded sUSDS into new pooler:", seededSUSDS);
        require(
            IERC20Minimal(sUSDS_).balanceOf(newPooler) == remainingSUSDS,
            "new pooler did not receive seeded sUSDS"
        );

        // Transfer the migrated BPT (the owner received it in step 8).
        uint256 ownerBpt = IERC20Minimal(bpt).balanceOf(OWNER_ADDRESS);
        if (ownerBpt > 0) {
            uint256 newPoolerBptBefore = IERC20Minimal(bpt).balanceOf(newPooler);
            require(IERC20Minimal(bpt).transfer(newPooler, ownerBpt), "BPT seed transfer failed");
            require(
                IERC20Minimal(bpt).balanceOf(newPooler) == newPoolerBptBefore + ownerBpt,
                "new pooler did not receive seeded BPT"
            );
            console.log("Seeded BPT into new pooler:", ownerBpt);
        } else {
            console.log("  (owner holds zero BPT -- nothing to seed)");
        }
    }

    // ==========================================
    // Step 12: swap the staker's hook reference
    // ==========================================

    function _step12_swapStakerHook() internal {
        console.log("");
        console.log("=== Step 12: NFTStaker.setDispatcherHook(newHook) ===");
        NFTStaker(NFT_STAKER).setDispatcherHook(IBalancerPoolerMintDebtHook(newHook));
        require(
            address(NFTStaker(NFT_STAKER).dispatcherHook()) == newHook,
            "Staker dispatcherHook != newHook"
        );
        console.log("NFTStaker.dispatcherHook() == newHook: OK");
    }

    // ==========================================
    // Step 13: replace dispatcher at index 4 (NFT id stays 4)
    // ==========================================

    function _step13_replaceDispatcher4() internal {
        console.log("");
        console.log("=== Step 13: NFTMinterV2.replaceDispatcher(4, newPooler) ===");
        NFTMinterV2(NFT_MINTER_V2).replaceDispatcher(4, newPooler);
        (address d4,,,) = NFTMinterV2(NFT_MINTER_V2).configs(4);
        require(d4 == newPooler, "configs(4).dispatcher != newPooler after replaceDispatcher");
        console.log("configs(4).dispatcher == newPooler: OK (NFT id stays 4)");
    }

    // ==========================================
    // Step 14: decommission old hook
    // ==========================================

    function _step14_decommissionOldHook() internal {
        console.log("");
        console.log("=== Step 14: phUSD.setMinter(oldHook, false) ===");
        IFlaxMinimal(PHUSD).setMinter(oldHook, false);
        console.log("Old hook decommissioned as phUSD minter");
    }

    // ==========================================
    // Step 15: post-state log + cutover invariants (pre-pool)
    // ==========================================
    //
    // Runs BEFORE the final LP add so the dispatcher swap is asserted independently of
    // pool()'s outcome. At this point the new pooler holds exactly the migrated (seeded)
    // BPT, so `newBptBalance == preBptOld`; the step-17 LP add only increases it further.
    function _step15_postStateLog() internal view {
        console.log("");
        console.log("=== Step 15: post-state log + cutover invariants (pre-pool) ===");

        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);
        (address d4,,,) = minter.configs(4);

        uint256 newBptBalance = IERC20Minimal(bpt).balanceOf(newPooler);
        uint256 oldBptBalance = IERC20Minimal(bpt).balanceOf(oldPooler);
        uint256 oldSusdsBalance = IERC20Minimal(sUSDS_).balanceOf(oldPooler);

        console.log("configs(4).dispatcher:      ", d4);
        console.log("BPT.balanceOf(newPooler):   ", newBptBalance);
        console.log("BPT.balanceOf(oldPooler):   ", oldBptBalance);
        console.log("sUSDS.balanceOf(oldPooler): ", oldSusdsBalance);
        console.log("NFTStaker.dispatcherHook(): ", address(NFTStaker(NFT_STAKER).dispatcherHook()));

        require(d4 == newPooler, "INVARIANT: configs(4).dispatcher != newPooler");
        require(newBptBalance >= preBptOld, "INVARIANT: newPooler BPT < migrated BPT");
        require(
            address(NFTStaker(NFT_STAKER).dispatcherHook()) == newHook,
            "INVARIANT: NFTStaker.dispatcherHook != newHook"
        );
        require(oldBptBalance == 0, "INVARIANT: oldPooler still holds BPT");
        require(oldSusdsBalance == 0, "INVARIANT: oldPooler still holds sUSDS");

        console.log("All cutover invariants hold (LP add still pending in step 17).");
        console.log("");
        console.log("--- For patcher / human reference ---");
        console.log("newPooler:               ", newPooler);
        console.log("newHook:                 ", newHook);
        console.log("oldPooler (pre-cutover): ", oldPooler);
        console.log("oldHook (pre-cutover):   ", oldHook);
    }

    // ==========================================
    // Step 16 (PREVIEW ONLY): end-to-end index-4 mint
    // ==========================================
    //
    // Proves the cutover left index 4 fully mintable -- in particular that the new pooler's
    // _minter wiring from step 6 lets NFTMinterV2.dispatch() through the `onlyMinter` gate
    // (the exact failure this whole change guards against). Spoofs the dispatcher's prime
    // token (USDS) to the owner via forge-std's `deal` cheatcode -- a FORK-ONLY operation
    // that has no effect on a live broadcast, which is precisely why this step is gated
    // behind `isPreview`. It then approves NFTMinterV2 and mints one id-4 NFT to the owner,
    // exercising the full path: onlyMinter gate -> USDS->sUSDS wrap -> Sky-PSM donation
    // (try/catch) -> hook.onDispatch debt accrual -> ERC1155 _mint.
    //
    // Runs inside the owner prank (set in run()) and BEFORE the step-17 LP add, so dispatch
    // is validated regardless of pool()'s outcome. Never reached on a real broadcast.
    function _step16_previewE2EMint() internal {
        console.log("");
        console.log("=== Step 16 (PREVIEW ONLY): end-to-end index-4 mint ===");

        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        // Sanity: index 4 now points at the new pooler and is enabled.
        (address d4, uint256 price4,, bool disabled4) = minter.configs(4);
        require(d4 == newPooler, "e2e: configs(4).dispatcher != newPooler");
        require(!disabled4, "e2e: index 4 is disabled");
        require(price4 > 0, "e2e: index-4 price is zero");

        // The dispatcher's authoritative prime token (NFTMinterV2 reads this, not the caller).
        address usds = IERC4626Minimal(sUSDS_).asset();
        console.log("USDS (prime token):", usds);
        console.log("index-4 price:     ", price4);

        // Spoof exactly the mint price of USDS onto the owner (fork cheatcode; no-op live).
        deal(usds, OWNER_ADDRESS, price4);
        require(IERC20Minimal(usds).balanceOf(OWNER_ADDRESS) >= price4, "e2e: deal USDS failed");

        uint256 nftBefore       = minter.balanceOf(OWNER_ADDRESS, 4);
        uint256 poolerSusdsBefore = IERC20Minimal(sUSDS_).balanceOf(newPooler);
        uint256 hookDebtBefore  = BalancerPoolerMintDebtHook(newHook).mintDebt();

        // Approve + mint one id-4 NFT to the owner (owner is the active prank sender).
        IERC20Minimal(usds).approve(NFT_MINTER_V2, price4);
        bool ok = minter.mint(4, OWNER_ADDRESS);
        require(ok, "e2e: mint returned false");

        uint256 nftAfter        = minter.balanceOf(OWNER_ADDRESS, 4);
        uint256 poolerSusdsAfter = IERC20Minimal(sUSDS_).balanceOf(newPooler);
        uint256 hookDebtAfter   = BalancerPoolerMintDebtHook(newHook).mintDebt();

        console.log("owner id-4 NFT balance:  ", nftBefore, "->", nftAfter);
        console.log("newPooler sUSDS balance: ", poolerSusdsBefore, "->", poolerSusdsAfter);
        console.log("newHook mintDebt:        ", hookDebtBefore, "->", hookDebtAfter);

        require(nftAfter == nftBefore + 1, "e2e: NFT id-4 balance did not increase by 1");
        require(hookDebtAfter > hookDebtBefore, "e2e: hook mintDebt did not accrue on dispatch");
        console.log("PREVIEW e2e mint OK: index-4 dispatch path works post-cutover.");
    }

    // ==========================================
    // Step 17: FINAL isolated LP add -- derive minBPT and pool()
    // ==========================================
    //
    // Intentionally the LAST state-changing action in run(). Everything above is the
    // dispatcher cutover, which is fully committed (and, on a real broadcast, already
    // mined) by the time this executes. The pool() call is wrapped in try/catch so an
    // overstated minBPT -- or live Balancer-pool drift between the offline router quote
    // and execution -- can NEVER roll back or block that cutover. On failure the new
    // pooler simply keeps its seeded sUSDS un-LP'd; no funds are at risk and the owner
    // (already an authorized pooler) calls pool(freshMinBPT) later to finish the LP add.
    //
    // Note on Foundry semantics: forge executes run() locally to collect the broadcast
    // transactions BEFORE sending any of them, and that local pass aborts on the first
    // uncaught revert. Without this catch, a too-high minBPT would abort the local pass
    // and NOTHING -- including the cutover -- would broadcast. The catch lets the cutover
    // txs broadcast and isolates the LP add as the only step that can fail.
    function _step17_finalPool() internal {
        console.log("");
        console.log("=== Step 17: FINAL isolated LP add -- derive minBPT (>0) and pool() ===");

        // --- minBPT derivation ---
        // The `minBPT` floor is DERIVED from the Balancer Router ideal-BPT quote
        // (`getIdealBPT` -> `queryAddLiquidityUnbalanced`) for the seeded (~90%) sUSDS,
        // minus MIN_BPT_TOLERANCE_BPS. That router query path is gated by Balancer V3's
        // query mechanism: it can ONLY run from a true `eth_call` (STATICCALL) frame and
        // genuinely mutates+reverts state internally, so it cannot be evaluated from
        // inside this script's broadcast/prank transaction frame (it reverts
        // `NotStaticCall()` directly and `StateChangeDuringStaticCall` via staticcall).
        // The codebase handles this the same way RescuePoolAndDonateUSDC does: the quote
        // is performed OFFLINE and supplied as a slippage floor, guarded by require>0.
        //
        // DEFAULT_MIN_BPT below was derived from a live offline router query
        // (2026-06-04): for the 90% seed (~527.71 sUSDS) the router quoted ~287.85 BPT:
        //   cast call <ROUTER> \
        //     "queryAddLiquidityUnbalanced(address,uint256[],address,bytes)(uint256)" \
        //     0x642BB6860b4776CC10b26B8f361Fd139E7f0db04 "[527707128367552116559,0]" \
        //     0x0 0x --rpc-url $RPC_MAINNET   -> 287850681894744402748 (~287.85 BPT)
        // 287.85 BPT minus the 1% (MIN_BPT_TOLERANCE_BPS) tolerance ~= 284.97 BPT; we
        // floor conservatively to 284e18. Re-query and override via MIN_BPT_WEI if the
        // pool state moves materially before broadcast.
        uint256 minBPT = vm.envOr("MIN_BPT_WEI", DEFAULT_MIN_BPT);
        console.log("MIN_BPT_WEI (env or default):", minBPT);

        if (block.chainid == 31337) {
            // Anvil-only relaxation: a forked router quote / local state may not match
            // the mainnet-derived default. Mainnet/Sepolia MUST enforce minBPT > 0.
            if (minBPT == 0) {
                console.log("  (Anvil) minBPT == 0 -- relaxing to 1 for local run");
                minBPT = 1;
            }
        } else {
            require(minBPT > 0, "minBPT resolved to 0 on a real network -- refusing unprotected pool()");
        }
        derivedMinBPT = minBPT;
        console.log("derivedMinBPT (slippage floor):", derivedMinBPT);

        uint256 newPoolerBptBefore = IERC20Minimal(bpt).balanceOf(newPooler);

        // pool(minBPT) enforces the slippage floor on-chain (it reverts if it would mint
        // fewer than minBPT). We catch that revert so it stays an isolated failure.
        try BalancerPoolerV2(newPooler).pool(derivedMinBPT) {
            uint256 newPoolerBptAfter = IERC20Minimal(bpt).balanceOf(newPooler);
            console.log("BPT.balanceOf(newPooler) before pool:", newPoolerBptBefore);
            console.log("BPT.balanceOf(newPooler) after pool: ", newPoolerBptAfter);
            // On a successful pool() these always hold (pool() enforces minBPT internally
            // and consumes the full sUSDS balance); kept as belt-and-suspenders.
            require(newPoolerBptAfter > newPoolerBptBefore, "pool() did not increase new pooler BPT");
            require(
                newPoolerBptAfter - newPoolerBptBefore >= derivedMinBPT,
                "pool() minted fewer BPT than minBPT floor"
            );
            require(
                IERC20Minimal(sUSDS_).balanceOf(newPooler) == 0,
                "new pooler still holds sUSDS after pool()"
            );
            poolExecuted = true;
            console.log("pool() succeeded; sUSDS consumed; BPT increased.");
        } catch (bytes memory reason) {
            // ISOLATED FAILURE -- the cutover above is committed and unaffected.
            poolExecuted = false;
            console.log("");
            console.log("*** WARNING: pool() FAILED -- cutover is COMMITTED, LP add DEFERRED ***");
            console.log("Likely cause: minBPT estimate too high, or the Balancer pool drifted");
            console.log("between the offline router quote and execution. Revert reason (bytes):");
            console.logBytes(reason);
            console.log("");
            console.log("The dispatcher swap is fully in effect; the new pooler just holds its");
            console.log("seeded sUSDS un-LP'd. No funds are at risk -- the sUSDS stays parked");
            console.log("until pooled:");
            console.log("  newPooler:           ", newPooler);
            console.log("  sUSDS held (un-LP'd):", IERC20Minimal(sUSDS_).balanceOf(newPooler));
            console.log("ACTION REQUIRED: re-query the router for a fresh minBPT, then call as owner:");
            console.log("  BalancerPoolerV2(newPooler).pool(freshMinBPT)");
        }
    }
}

// ==========================================
//   MINIMAL EXTERNAL TYPE INTERFACES
// ==========================================

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC4626Minimal {
    function asset() external view returns (address);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

/// @dev IFlax surface used by this script. phUSD implements IFlax.setMinter(address,bool).
interface IFlaxMinimal {
    function setMinter(address minter, bool canMint) external;
}
