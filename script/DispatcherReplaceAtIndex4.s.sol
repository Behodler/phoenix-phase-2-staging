// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {Pauser} from "@pauser/Pauser.sol";
import {NFTMinterV2} from "@yield-claim-nft/V2/NFTMinterV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/V2/dispatchers/BalancerPoolerV2.sol";
import {BalancerPoolerMintDebtHook} from "@yield-claim-nft/V2/hooks/BalancerPoolerMintDebtHook.sol";
import {IBalancerPoolerMintDebtHook} from "@yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/V2/interfaces/IDispatchHook.sol";
import {NFTStaker} from "nft-staking/NFTStaker.sol";

/// @title DispatcherReplaceAtIndex4
/// @notice Single owner-signed Foundry broadcast performing the full cutover
///         that installs a bug-fixed BalancerPoolerV2 at NFTMinterV2 dispatcher
///         INDEX 4 (replacing the original index-4 pooler), disables and
///         drains the bugged INDEX 6 pooler, burns the founder's id-6 balance
///         and decommissions the old hook. After this broadcast, the existing
///         NFTStaker (stakedId=4, dispatcherIndex=4) keeps working unchanged
///         -- only the dispatcher pointer in `configs[4]` flips.
///
///         Full rationale in:
///           /home/justin/code/product-owner/scratchpad/planning-docs/phoenix/
///             phase2/nft-staking/v2/dispatcher-replacement-at-index-4-plan.md
///         Executable spec / checklist in story 048.
///
///         Modes:
///           PREVIEW_MODE=true  -> startPrank(OWNER_ADDRESS), no broadcast
///           PREVIEW_MODE=false -> startBroadcast() (ledger-signed)
///
///         Dry run:
///           PREVIEW_MODE=true forge script script/DispatcherReplaceAtIndex4.s.sol \
///             --rpc-url $RPC_MAINNET --slow -vvv
///
///         Broadcast (ledger, index 46):
///           forge script script/DispatcherReplaceAtIndex4.s.sol \
///             --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
///             --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
contract DispatcherReplaceAtIndex4 is Script {
    // ==========================================
    //         LIVE MAINNET ADDRESSES
    // ==========================================

    address public constant PHUSD             = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;
    address public constant PAUSER            = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant NFT_MINTER_V2     = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant NFT_STAKER        = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b;
    address public constant BUGGED_POOLER_V2  = 0x4da153dc02bB084528D10335759f2C4447e6f73d; // index 6
    address public constant FOUNDER           = 0x64d3CbAB6100782a7839fC1af791027a2f1908D2;

    // Owner / ledger signer (HD path m/44'/60'/46'/0/0 -- same convention as
    // sibling deploy scripts; see DeployMainnetNudgePoolerV2.s.sol:155 and
    // package.json:65-66).
    address public constant OWNER_ADDRESS     = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;

    // Restore target for MintPageView. This was the V2-wired view that
    // hardcoded dispatcher index 4. The currently-deployed view targets
    // index 6 (deployed by story-047). After this cutover, index 4 is the
    // active dispatcher again, so the patcher should restore this address
    // -- but ONLY if its on-chain `dispatcherIndex` reading confirms it
    // reads `configs(4)`. The script logs the pre-revert assertion result
    // so the patcher / human can gate the revert.
    address public constant PRIOR_MINT_PAGE_VIEW = 0x64FE63ca7BA456a9Bb190140e35DF2e437AbD119;

    // ==========================================
    //  CODIFIED AUTHORISED-POOLER SET TO MIRROR
    // ==========================================

    /// @notice Authorised-pooler set to replay onto the NEW pooler.
    ///         Source: on-chain history search across mainnet broadcasts
    ///         (DeployMainnetNFTStaking step 10 -- line 390 -- and
    ///         AuthorizeOwnerAsPoolerV2.s.sol). Both set the deployer ledger
    ///         as the only authorised pooler. The user-direction note in
    ///         story 048 (Concerns) also REQUIRES the deployer ledger be in
    ///         the final set on the new pooler, independent of historical
    ///         replay -- that single entry covers both requirements.
    function _authorisedPoolerSet() internal pure returns (address[] memory set) {
        set = new address[](1);
        set[0] = OWNER_ADDRESS;
    }

    // ==========================================
    //         RUNTIME-CAPTURED STATE
    // ==========================================

    /// @dev Captured pre-broadcast from on-chain reads. Snapshotted in step 1.
    address public oldPooler;        // configs(4).dispatcher BEFORE the cutover
    address public oldHook;          // NFTStaker.dispatcherHook() BEFORE the cutover
    uint256 public totalSupplyId6;   // NFTMinterV2.totalSupply(6)
    uint256 public preBptOld;        // BPT held by oldPooler
    uint256 public preBptBugged;     // BPT held by buggedPooler
    uint256 public preOldHookMintDebt;
    uint256 public prePhUSDStakerBalance;

    /// @dev Deployed during step 4 / 5.
    address public newPooler;
    address public newHook;

    /// @dev BPT (LP token) address, read from oldPooler.pool() in step 4.
    address public bpt;

    /// @dev sUSDS / vault / router / sUSDSIsFirst all read from oldPooler.
    address public sUSDS_;
    address public lpPool_;
    address public balancerVault_;
    address public balancerRouter_;
    bool    public sUSDSIsFirst_;

    /// @dev MintPageView verification result.
    bool    public priorMintPageViewReadsIndex4;

    bool internal isPreview;

    // ==========================================
    //         MINIMAL EXTERNAL INTERFACES
    // ==========================================

    function setUp() public {
        require(block.chainid == 1, "Wrong chain id - expected Mainnet (1)");
    }

    function run() external {
        console.log("===============================================");
        console.log(" DispatcherReplaceAtIndex4 -- single cutover");
        console.log("===============================================");
        console.log("Chain id:                 ", block.chainid);
        console.log("NFTMinterV2:              ", NFT_MINTER_V2);
        console.log("NFTStaker:                ", NFT_STAKER);
        console.log("phUSD:                    ", PHUSD);
        console.log("Pauser:                   ", PAUSER);
        console.log("Bugged pooler (index 6):  ", BUGGED_POOLER_V2);
        console.log("Founder (id-6 sole hold): ", FOUNDER);
        console.log("Owner (ledger signer):    ", OWNER_ADDRESS);
        console.log("Prior MintPageView (idx4):", PRIOR_MINT_PAGE_VIEW);

        isPreview = vm.envOr("PREVIEW_MODE", false);
        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE -- impersonating owner via prank ***");
            console.log("");
        }

        // ====== Pre-flight (no broadcast) ======
        // Step 1 reads are pure on-chain inspection; doing them outside the
        // broadcast keeps them out of the broadcast.json transaction list.
        _step1_snapshotPreState();
        _step2_verifyId6SoleHolderGate();
        _verifyStakerOwner();
        _verifyMinterAuthorisation();
        _verifyPriorMintPageView();

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
        _step8_ejectAndTransferBPT();
        _step9_swapStakerHook();
        _step10_replaceDispatcher4();
        // Step 11 omitted intentionally -- see story 048 Concerns. The dispatch
        //   path itself does not require NFTMinterV2 authorisation; the new
        //   pooler is wired in via replaceDispatcher in step 10.
        _step12_decommissionOldHook();
        _step13_burnFounderId6();
        _step14_disableIndex6();
        _step15_pauserRegister();
        _step16_postStateLog();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        console.log("");
        console.log("===============================================");
        console.log(" Cutover complete (in-memory only if preview)");
        console.log("===============================================");
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
        oldPooler = d4;

        (address d6,,,) = minter.configs(6);
        require(d6 == BUGGED_POOLER_V2, "index 6 dispatcher != BUGGED_POOLER_V2 constant");

        // Read current hook from staker (public dispatcherHook storage var).
        oldHook = address(NFTStaker(NFT_STAKER).dispatcherHook());
        require(oldHook != address(0), "NFTStaker.dispatcherHook == address(0)");

        preOldHookMintDebt = BalancerPoolerMintDebtHook(oldHook).mintDebt();

        // Read BPT address from oldPooler.pool().
        bpt = BalancerPoolerV2(oldPooler).pool();
        require(bpt != address(0), "oldPooler.pool() == 0");
        preBptOld    = IERC20Minimal(bpt).balanceOf(oldPooler);
        preBptBugged = IERC20Minimal(bpt).balanceOf(BUGGED_POOLER_V2);

        prePhUSDStakerBalance = IERC20Minimal(PHUSD).balanceOf(NFT_STAKER);
        totalSupplyId6 = NFTMinterV2(NFT_MINTER_V2).totalSupply(6);

        // Capture pooler constructor args / config we'll mirror.
        sUSDS_         = BalancerPoolerV2(oldPooler).sUSDS();
        lpPool_        = bpt; // pool() returns the LP/BPT address
        balancerVault_ = BalancerPoolerV2(oldPooler).vault();
        // router is private/immutable on the pooler; we read it from the
        // bugged index-6 pooler instead -- both poolers were deployed with
        // the same router constant by the same script family.
        // BalancerPoolerV2 doesn't expose a public router() getter, so
        // we re-derive it from MigrateBalancerPoolerV2Pool / DeployMainnet
        // constants embedded in this script.
        balancerRouter_ = BALANCER_ROUTER;
        // sUSDSIsFirst not exposed via a getter; mirror the documented
        // constant used in the prior deploys (SUSDS_IS_FIRST=true in
        // DeployMainnetNudgePoolerV2). The deploy script will revert if
        // this ever drifts from the live pool's ordering on a fresh
        // deployment, so we treat it as a script constant.
        sUSDSIsFirst_ = SUSDS_IS_FIRST;

        console.log("oldPooler (configs(4).dispatcher):", oldPooler);
        console.log("buggedPooler (configs(6).dispatcher):", BUGGED_POOLER_V2);
        console.log("oldHook (NFTStaker.dispatcherHook):", oldHook);
        console.log("oldHook.mintDebt():                ", preOldHookMintDebt);
        console.log("phUSD.balanceOf(NFTStaker):        ", prePhUSDStakerBalance);
        console.log("BPT token (oldPooler.pool()):      ", bpt);
        console.log("BPT.balanceOf(oldPooler):          ", preBptOld);
        console.log("BPT.balanceOf(buggedPooler):       ", preBptBugged);
        console.log("NFTMinterV2.totalSupply(6):        ", totalSupplyId6);
        console.log("sUSDS (from oldPooler):            ", sUSDS_);
        console.log("BalancerVault (from oldPooler):    ", balancerVault_);
        console.log("BalancerRouter (script constant):  ", balancerRouter_);
        console.log("sUSDSIsFirst (script constant):    ", sUSDSIsFirst_);
    }

    // ==========================================
    // Step 2: id-6 sole-holder gate
    // ==========================================

    function _step2_verifyId6SoleHolderGate() internal view {
        console.log("");
        console.log("=== Step 2: verify founder is sole holder of id 6 ===");
        uint256 founderBal6 = NFTMinterV2(NFT_MINTER_V2).balanceOf(FOUNDER, 6);
        console.log("balanceOf(FOUNDER, 6): ", founderBal6);
        console.log("totalSupply(6):        ", totalSupplyId6);
        require(
            founderBal6 == totalSupplyId6,
            "id-6 sole-holder gate FAILED: founder does not hold the entire id-6 supply"
        );
        console.log("OK -- founder holds the entire id-6 supply");
    }

    function _verifyStakerOwner() internal view {
        address stakerOwner = NFTStaker(NFT_STAKER).owner();
        console.log("NFTStaker.owner(): ", stakerOwner);
        require(stakerOwner == OWNER_ADDRESS, "Staker owner mismatch -- pullAndRefresh would revert");
    }

    function _verifyMinterAuthorisation() internal view {
        // We don't directly assert phUSD.minter() because the IFlax interface
        // exposes authorizedMinters(address) returns (MinterInfo) -- checking
        // version equality is overkill for a script log. We simply log that
        // the cutover script EXPECTS old hook to be a minter pre-broadcast
        // and the new hook to be a non-minter pre-broadcast; the actual
        // setMinter calls in steps 6 and 12 enforce the post-state.
        console.log("(verification of phUSD minter status deferred to setMinter txs in steps 6/12)");
    }

    function _verifyPriorMintPageView() internal {
        // eth_call the prior view's `dispatcherIndex()` getter (if exposed)
        // or fall back to a successful `getData(OWNER_ADDRESS)` call which
        // exercises the read path. We can't import MintPageView here (cross-
        // submodule), so we use a low-level static call to the conventional
        // accessor name. A revert/zero is logged but does NOT block the
        // broadcast -- the patcher reads this flag from logs and either
        // restores the prior view address or warns.
        (bool ok, bytes memory data) = PRIOR_MINT_PAGE_VIEW.staticcall(
            abi.encodeWithSignature("dispatcherIndex()")
        );
        if (ok && data.length >= 32) {
            uint256 idx = abi.decode(data, (uint256));
            priorMintPageViewReadsIndex4 = (idx == 4);
            console.log("Prior MintPageView.dispatcherIndex():", idx);
        } else {
            // Fall back to a smoke test: does code exist at the address?
            uint256 size; address a = PRIOR_MINT_PAGE_VIEW; assembly { size := extcodesize(a) }
            priorMintPageViewReadsIndex4 = false;
            console.log("Prior MintPageView: dispatcherIndex() not exposed; extcodesize =", size);
            console.log("WARNING: cannot prove prior view targets index 4; patcher must NOT revert MintPageView field unless human confirms via another method.");
        }
        console.log("priorMintPageViewReadsIndex4:", priorMintPageViewReadsIndex4);
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
    // Step 4: deploy new BalancerPoolerV2
    // ==========================================

    function _step4_deployNewPooler() internal {
        console.log("");
        console.log("=== Step 4: deploy new BalancerPoolerV2 ===");
        BalancerPoolerV2 p = new BalancerPoolerV2(
            sUSDS_,
            lpPool_,
            balancerVault_,
            balancerRouter_,
            sUSDSIsFirst_,
            OWNER_ADDRESS
        );
        newPooler = address(p);
        console.log("newPooler:", newPooler);
        console.log("  sUSDS:        ", sUSDS_);
        console.log("  pool:         ", lpPool_);
        console.log("  vault:        ", balancerVault_);
        console.log("  router:       ", balancerRouter_);
        console.log("  sUSDSIsFirst: ", sUSDSIsFirst_);
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

        BalancerPoolerMintDebtHook(newHook).setRecipient(NFT_STAKER);
        console.log("newHook.setRecipient(NFTStaker):", NFT_STAKER);

        // phUSD is an IFlax -- setMinter(address,bool) -- see
        // lib/.../mutable/flax-token/src/interfaces/IFlax.sol:93.
        IFlaxMinimal(PHUSD).setMinter(newHook, true);
        console.log("phUSD.setMinter(newHook, true)");
    }

    // ==========================================
    // Step 7: mirror pooler config
    // ==========================================

    function _step7_mirrorPoolerConfig() internal {
        console.log("");
        console.log("=== Step 7: mirror pooler config ===");

        // IMPORTANT: source the donation-phase config from the BUGGED index-6
        // pooler, not the OLD index-4 pooler. The old index-4 pooler is an
        // early-version BalancerPoolerV2 that pre-dates the donation-phase
        // feature (story 031); its `batchDonationSize`/`batchMinter`/swap-
        // config slots simply don't exist as public state vars on that
        // older artifact, so reads revert. The bugged index-6 deploy is the
        // same artifact as our new pooler (minus the bug fix) and has the
        // fully-populated config we want to inherit.
        BalancerPoolerV2 srcP = BalancerPoolerV2(BUGGED_POOLER_V2);
        BalancerPoolerV2 newP = BalancerPoolerV2(newPooler);

        uint256 batchSize = srcP.batchDonationSize();
        address batchM    = srcP.batchMinter();
        address swapPool_ = srcP.swapPool();
        address waUsdc_   = srcP.waUsdc();
        address usdc_     = srcP.usdc();

        console.log("Mirroring from buggedPooler (index 6, same artifact family):");
        console.log("  batchDonationSize:", batchSize);
        console.log("  batchMinter:      ", batchM);
        console.log("  swapPool:         ", swapPool_);
        console.log("  waUsdc:           ", waUsdc_);
        console.log("  usdc:             ", usdc_);

        newP.setBatchDonationSize(batchSize);
        if (batchM != address(0)) {
            newP.setBatchMinter(batchM);
        } else {
            console.log("  (skipping setBatchMinter -- old value is address(0))");
        }
        if (swapPool_ != address(0) && waUsdc_ != address(0) && usdc_ != address(0)) {
            newP.setSwapConfig(swapPool_, waUsdc_, usdc_);
        } else {
            console.log("  (skipping setSwapConfig -- at least one of swapPool/waUsdc/usdc is address(0))");
        }

        // Authorise the codified set on the new pooler.
        address[] memory authSet = _authorisedPoolerSet();
        for (uint256 i = 0; i < authSet.length; i++) {
            newP.setAuthorizedPooler(authSet[i], true);
            console.log("newPooler.setAuthorizedPooler(authorised=true):", authSet[i]);
        }

        // Independent of the codified set -- per user direction in story 048
        // Concerns -- explicitly call setAuthorizedPooler(deployer, true) and
        // assert. Idempotent: re-authorising an already-authorised address
        // just stamps the same auth version.
        newP.setAuthorizedPooler(OWNER_ADDRESS, true);
        require(
            newP.poolerAuthVersion(OWNER_ADDRESS) == newP.authVersion(),
            "deployer not authorised on new pooler after explicit setAuthorizedPooler"
        );
        console.log("Explicit deployer-ledger auth assertion: OK");
    }

    // ==========================================
    // Step 8: eject BPT from both poolers and hand off
    // ==========================================

    function _step8_ejectAndTransferBPT() internal {
        console.log("");
        console.log("=== Step 8: eject BPT and transfer to new pooler ===");

        IERC20Minimal bptToken = IERC20Minimal(bpt);
        uint256 deployerBefore = bptToken.balanceOf(OWNER_ADDRESS);
        uint256 newPoolerBefore = bptToken.balanceOf(newPooler);

        // 8a -- old (index 4) pooler
        uint256 oldBal = bptToken.balanceOf(oldPooler);
        console.log("BPT.balanceOf(oldPooler):", oldBal);
        if (oldBal > 0) {
            BalancerPoolerV2(oldPooler).withdrawBPT(OWNER_ADDRESS, oldBal);
            console.log("oldPooler.withdrawBPT(deployer, oldBal)");
        } else {
            console.log("  (oldPooler holds zero BPT -- skipping withdrawBPT)");
        }

        // 8b -- bugged (index 6) pooler
        uint256 buggedBal = bptToken.balanceOf(BUGGED_POOLER_V2);
        console.log("BPT.balanceOf(buggedPooler):", buggedBal);
        if (buggedBal > 0) {
            BalancerPoolerV2(BUGGED_POOLER_V2).withdrawBPT(OWNER_ADDRESS, buggedBal);
            console.log("buggedPooler.withdrawBPT(deployer, buggedBal)");
        } else {
            console.log("  (buggedPooler holds zero BPT -- skipping withdrawBPT)");
        }

        // 8c -- transfer all newly-received BPT to the new pooler
        uint256 deployerAfter = bptToken.balanceOf(OWNER_ADDRESS);
        uint256 ejected = deployerAfter - deployerBefore;
        require(ejected == oldBal + buggedBal, "Ejected BPT != oldBal + buggedBal");
        if (ejected > 0) {
            require(bptToken.transfer(newPooler, ejected), "BPT transfer to newPooler failed");
            console.log("BPT.transfer(newPooler, ejected):", ejected);
        }

        // 8d -- atomicity asserts
        require(bptToken.balanceOf(oldPooler) == 0, "oldPooler still holds BPT");
        require(bptToken.balanceOf(BUGGED_POOLER_V2) == 0, "buggedPooler still holds BPT");
        require(
            bptToken.balanceOf(newPooler) == newPoolerBefore + ejected,
            "newPooler did not receive the expected BPT"
        );
        require(
            bptToken.balanceOf(OWNER_ADDRESS) == deployerBefore,
            "Deployer BPT balance changed unexpectedly"
        );
        console.log("BPT handoff complete. newPooler balance:", bptToken.balanceOf(newPooler));
    }

    // ==========================================
    // Step 9: swap the staker's hook reference
    // ==========================================

    function _step9_swapStakerHook() internal {
        console.log("");
        console.log("=== Step 9: NFTStaker.setDispatcherHook(newHook) ===");
        NFTStaker(NFT_STAKER).setDispatcherHook(IBalancerPoolerMintDebtHook(newHook));
        require(
            address(NFTStaker(NFT_STAKER).dispatcherHook()) == newHook,
            "Staker dispatcherHook != newHook"
        );
        console.log("NFTStaker.dispatcherHook() == newHook: OK");
    }

    // ==========================================
    // Step 10: replace dispatcher at index 4
    // ==========================================

    function _step10_replaceDispatcher4() internal {
        console.log("");
        console.log("=== Step 10: NFTMinterV2.replaceDispatcher(4, newPooler) ===");
        NFTMinterV2(NFT_MINTER_V2).replaceDispatcher(4, newPooler);
        (address d4,,,) = NFTMinterV2(NFT_MINTER_V2).configs(4);
        require(d4 == newPooler, "configs(4).dispatcher != newPooler after replaceDispatcher");
        console.log("configs(4).dispatcher == newPooler: OK");
    }

    // ==========================================
    // Step 12: decommission old hook
    // ==========================================

    function _step12_decommissionOldHook() internal {
        console.log("");
        console.log("=== Step 12: phUSD.setMinter(oldHook, false) ===");
        IFlaxMinimal(PHUSD).setMinter(oldHook, false);
    }

    // ==========================================
    // Step 13: burn founder's id-6 balance
    // ==========================================

    function _step13_burnFounderId6() internal {
        console.log("");
        console.log("=== Step 13: burn founder's id-6 balance ===");
        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        minter.setAuthorizedBurner(OWNER_ADDRESS, true);
        console.log("setAuthorizedBurner(deployer, true)");

        uint256 bal6 = minter.balanceOf(FOUNDER, 6);
        console.log("balanceOf(FOUNDER, 6) pre-burn:", bal6);
        if (bal6 > 0) {
            minter.burn(FOUNDER, 6, bal6);
            console.log("burn(FOUNDER, 6, bal6)");
        } else {
            console.log("  (founder already holds zero id-6 -- skipping burn)");
        }

        minter.setAuthorizedBurner(OWNER_ADDRESS, false);
        console.log("setAuthorizedBurner(deployer, false)");

        require(
            minter.balanceOf(FOUNDER, 6) == 0,
            "balanceOf(FOUNDER, 6) != 0 after burn"
        );
        console.log("balanceOf(FOUNDER, 6) post-burn: OK (== 0)");
    }

    // ==========================================
    // Step 14: disable index 6
    // ==========================================

    function _step14_disableIndex6() internal {
        console.log("");
        console.log("=== Step 14: NFTMinterV2.setDispatcherDisabled(6, true) ===");
        NFTMinterV2(NFT_MINTER_V2).setDispatcherDisabled(6, true);
        (,,,bool disabled6) = NFTMinterV2(NFT_MINTER_V2).configs(6);
        require(disabled6, "configs(6).disabled != true after setDispatcherDisabled");
        console.log("configs(6).disabled == true: OK");
    }

    // ==========================================
    // Step 15: Pauser.register(newPooler) -- SKIPPED
    // ==========================================

    function _step15_pauserRegister() internal pure {
        // NOTE: Skipped intentionally, matching DeployMainnetNudgePoolerV2's
        // decision at lines 898-906. BalancerPoolerV2 inherits OZ Pausable
        // but does NOT implement IPausable.pauser() -- Pauser.register(...)
        // reverts on the pauser() callback check. Pause coverage for the
        // new pooler is provided indirectly via NFTMinterV2 (which IS
        // registered on the global Pauser) -- calling pause() on the
        // dispatcher is owner/minter-gated and surfaces via NFTMinterV2's
        // own pause mechanism.
        console.log("");
        console.log("=== Step 15 SKIPPED: Pauser.register(newPooler) -- see DeployMainnetNudgePoolerV2:898-906 ===");
    }

    // ==========================================
    // Step 16: post-state log
    // ==========================================

    function _step16_postStateLog() internal view {
        console.log("");
        console.log("=== Step 16: post-state log + invariant asserts ===");

        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);
        (address d4,,,)          = minter.configs(4);
        (address d6,,,bool dis6) = minter.configs(6);

        IERC20Minimal bptToken = IERC20Minimal(bpt);
        uint256 newBptBalance = bptToken.balanceOf(newPooler);

        console.log("configs(4).dispatcher:", d4);
        console.log("configs(6).dispatcher:", d6);
        console.log("configs(6).disabled:  ", dis6);
        console.log("BPT.balanceOf(newPooler):  ", newBptBalance);
        console.log("BPT.balanceOf(oldPooler):  ", bptToken.balanceOf(oldPooler));
        console.log("BPT.balanceOf(buggedPooler):", bptToken.balanceOf(BUGGED_POOLER_V2));
        console.log("NFTStaker.dispatcherHook():", address(NFTStaker(NFT_STAKER).dispatcherHook()));
        console.log("balanceOf(FOUNDER, 6):    ", minter.balanceOf(FOUNDER, 6));
        console.log("phUSD.balanceOf(NFTStaker):", IERC20Minimal(PHUSD).balanceOf(NFT_STAKER));

        require(d4 == newPooler, "INVARIANT: configs(4).dispatcher != newPooler");
        require(dis6, "INVARIANT: configs(6).disabled != true");
        require(newBptBalance == preBptOld + preBptBugged, "INVARIANT: newPooler BPT != preOld+preBugged");
        require(
            address(NFTStaker(NFT_STAKER).dispatcherHook()) == newHook,
            "INVARIANT: NFTStaker.dispatcherHook != newHook"
        );
        require(minter.balanceOf(FOUNDER, 6) == 0, "INVARIANT: founder still holds id-6");

        console.log("All post-state invariants hold.");

        console.log("");
        console.log("--- For patcher / human reference ---");
        console.log("newPooler:                ", newPooler);
        console.log("newHook:                  ", newHook);
        console.log("oldPooler (pre-cutover):  ", oldPooler);
        console.log("oldHook (pre-cutover):    ", oldHook);
        console.log("priorMintPageViewReadsIndex4 (gate for MintPageView revert):", priorMintPageViewReadsIndex4);
    }

    // ==========================================
    //         SCRIPT CONSTANTS
    // ==========================================

    // BalancerRouter address used by the existing pooler deployments. This is
    // an immutable system-level address; see DeployMainnetNudgePoolerV2.s.sol:138
    // (BALANCER_ROUTER = 0x5C6f…9FDd). BalancerPoolerV2 does NOT expose a
    // router() getter (the field is `address private immutable _router`), so
    // we mirror this from the deploy-time constant rather than reading on-chain.
    address public constant BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;

    // sUSDSIsFirst constant -- mirrored from MigrateBalancerPoolerV2Pool /
    // DeployMainnetNudgePoolerV2 (SUSDS_IS_FIRST=true).
    bool public constant SUSDS_IS_FIRST = true;
}

// ==========================================
//   MINIMAL EXTERNAL TYPE INTERFACES
// ==========================================

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev IFlax surface used by this script. The phUSD token implements IFlax
///      (see lib/.../mutable/flax-token/src/interfaces/IFlax.sol:93).
interface IFlaxMinimal {
    function setMinter(address minter, bool canMint) external;
}
