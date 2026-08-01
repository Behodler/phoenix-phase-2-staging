// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import {Vm} from "@forge-std/Vm.sol";
import {StdCheats} from "@forge-std/StdCheats.sol";
import {Pauser} from "@pauser/Pauser.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/dispatchers/BalancerPoolerV2.sol";
import {Uniboost} from "@yield-claim-nft/dispatchers/Uniboost.sol";
import {NudgeRatchet} from "@yield-claim-nft/dispatchers/NudgeRatchet.sol";
import {BalancerPoolerMintDebtHook} from "@yield-claim-nft/hooks/BalancerPoolerMintDebtHook.sol";
import {UniboostMintDebtHook} from "@yield-claim-nft/hooks/UniboostMintDebtHook.sol";
import {NudgeRatchetMintDebtHook} from "@yield-claim-nft/hooks/NudgeRatchetMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";
import {IUniboostMintDebtHook} from "@yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {ITokenMinterV2} from "@yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {NudgeStreamer} from "nft-staking/NudgeStreamer.sol";
import {BatchNFTMinterMultiToken} from "nft-staking/BatchNFTMinterMultiToken.sol";
import {NFTStakerDepletion} from "nft-staking/NFTStakerDepletion.sol";
import {NFTStakerDepletionV2} from "nft-staking/NFTStakerDepletionV2.sol";
import {NFTStakerMigrator} from "nft-staking/NFTStakerMigrator.sol";
import {INFTStakerMigratable} from "nft-staking/INFTStakerMigratable.sol";
import {INFTSupply} from "nft-staking/INFTSupply.sol";
import {StableYieldAccumulator} from "@stable-yield-accumulator/StableYieldAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title  DeployMainnetPromotionReady
 * @notice Story 072. The single largest mainnet runbook this protocol has attempted:
 *         one differential deploy/cutover that promotes the accumulated `nft-staking`,
 *         `yield-claim-nft` and `stable-yield-accumulator` work to mainnet.
 *
 *         Five coupled changes, none of which can land alone:
 *
 *           1. Deploy `NudgeStreamer` and convert every donor from "push USDC straight at
 *              the batch-minter" to "approve + `collectNudge` through the streamer", which
 *              buffers each donation and releases it linearly instead of dumping it in a
 *              burst the next `batchMint` caller captures whole.
 *           2. Redeploy all four donor dispatchers — `BalancerPoolerV2` (index 4),
 *              `Uniboost` x3 (indices 1/2/3) and `NudgeRatchet` (replacing the
 *              `NudgeRatchetDelayRelease` stopgap at index 7) — plus
 *              `StableYieldAccumulator`. Every live instance is a PRE-streamer build:
 *              `nudgeStreamer()` reverts on all four (asserted in Phase 0), so none can be
 *              patched in place.
 *           3. Replace the shared `BatchNFTMinter` with `BatchNFTMinterMultiToken`,
 *              whitelist USDC / phUSD / Kendu, register a stream per token at independent
 *              durations, and route the live USDC balance across THROUGH the streamer.
 *           4. Silently migrate the three `NFTStakerDepletion` instances to
 *              `NFTStakerDepletionV2` via `NFTStakerMigrator` — zero user action.
 *           5. (Off-chain, in the release step) regenerate wagmi hooks and publish the
 *              phase2-wagmi-hooks package at 0.12.0.
 *
 * ============================ HOOKS ARE REPOINTED, NOT REDEPLOYED ============================
 *
 *  The five mint-debt hooks keep their addresses. `dispatcher` is MUTABLE STORAGE on all
 *  three hook types with an owner-only setter — `BalancerPoolerMintDebtHook.dispatcher`
 *  at `:31` / `setDispatcher` at `:98`, `UniboostMintDebtHook` `:38` / `:117`,
 *  `NudgeRatchetMintDebtHook` `:42` / `:111`. The upstream NatSpec endorses exactly this
 *  use: "owner-repointable via `setDispatcher` so a future dispatcher swap does not require
 *  redeploying the hook", and "Operationally, `pull()` the outstanding `mintDebt` before
 *  repointing so the ledger is clean across the swap."
 *
 *  Consequences, all deliberate:
 *    * ZERO `phUSD.setMinter` calls in this entire script. Mint authority is not touched,
 *      so it is byte-identical before and after BY CONSTRUCTION — there is no call that
 *      could change it. Note that this script does NOT assert that on-chain: neither
 *      Phase 0 nor Phase 7 reads phUSD's minter set. The confirmation is the post-broadcast
 *      HUMAN checklist item ("phUSD's minter set is byte-identical to its pre-cutover
 *      state"), verified with `cast` after the Ledger session.
 *    * Each hook keeps its `ratio`, `recipient` and `mintDebt` across the swap, so a tuned
 *      ratio cannot be silently reset to a constructor default. That matters most at index
 *      7, where `NudgeRatchetMintDebtHook`'s DEFAULT_RATIO is 100 while the other two hook
 *      types default to 50.
 *    * `NudgeRatchet._dispatch` (`:137-140`) `require`s
 *      `INudgeRatchetMintDebtHook(hook).hookTypeId() == EXPECTED_HOOK_TYPE_ID`. Reusing the
 *      existing hook satisfies that guard by construction.
 *
 *  ORDER IS FAIL-CLOSED IN ONE DIRECTION ONLY. Per index:
 *
 *      hook.pull()  ->  hook.setDispatcher(new)  ->  new.setHook(hook)  ->  replaceDispatcher(idx, new)
 *
 *  During the window between `setDispatcher` and `replaceDispatcher`, the OLD dispatcher is
 *  still on the index but the hook now rejects it (`onDispatch` is gated
 *  `if (msg.sender != dispatcher) revert OnlyDispatcher()`), so mints on that index REVERT.
 *  That is the correct failure direction. The reverse order would put the new dispatcher
 *  live on the index while it still carried the fresh `DefaultDispatchHook` that
 *  `ATokenDispatcherV2`'s constructor gave it (`:50`), so mints would SUCCEED while accruing
 *  no mint debt — a silent value leak. Never do that.
 *
 *  EXPECT USER-VISIBLE MINT FAILURES on indices 1/2/3/4/7 for the duration of the broadcast.
 *
 * ================================ WHAT THIS SCRIPT ASSUMES ================================
 *
 *  Nothing about balances. Every figure is read at runtime. The script aborts on STRUCTURAL
 *  drift (dispatcher slots, owners, prime tokens, donor sinks) and treats balance movement
 *  as expected — the index-7 pot alone moved 363.51 -> 250.77 -> 123.77 USDC across three
 *  successive planning reads.
 *
 * ==================================== PHASE ORDER =========================================
 *
 *   0   Preconditions. Require-gated, no mutation.
 *   1   `new NudgeStreamer(OWNER)`.
 *   2   `new BatchNFTMinterMultiToken(OWNER)` + config + `registerStream` x3.
 *   3   Rescue the old batch-minter's USDC to OWNER, then `collectNudge` it INTO THE STREAM.
 *   4a  New `BalancerPoolerV2` (index 4) + BPT custody shift + `replaceDispatcher(4)`.
 *   4b  New `Uniboost` x3 (indices 1/2/3) + `replaceDispatcher(1/2/3)`.
 *   4c  Drain index 7 into the stream, settle the ratchet hook's debt, new `NudgeRatchet`,
 *       `replaceDispatcher(7)`.
 *   5   New `StableYieldAccumulator`, rewire strategies / burner / Pauser, deactivate old.
 *   4d  Retire the old batch-minter (`setPauser(OWNER)` + `pause()`). RUNS AFTER PHASE 5 —
 *       see `_phase4d_retireOldBatchMinter` for why.
 *   6   Staker migration x3, in the order story 073 proved on-chain.
 *   7   Bidirectional wiring assertions + progress file.
 *   8   PREVIEW_MODE only: smoke tests, including the BLOCKING Kendu fee-on-transfer probe.
 *
 * ==================================== RUNNING IT ==========================================
 *
 *   Dry run (no broadcast, no progress file, includes Phase 8):
 *     npm run promotion-ready:dry
 *
 *   Broadcast (Ledger, HD m/44'/60'/46'/0/0, owner 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6):
 *     npm run promotion-ready:broadcast
 *
 *   The broadcast npm key MUST end with `&& node scripts/patch-mainnet-addresses-promotion-ready.js`.
 *
 *   PREREQUISITE for both: `node scripts/snapshot-depletion-stakers.js` must have written
 *   `scripts/snapshots/depletion-stakers-latest.json`. Phase 6 reads its user lists from
 *   there; `migrate` takes an explicit array and the stakers keep no on-chain enumeration.
 */
contract DeployMainnetPromotionReady is Script, StdCheats {
    // =====================================================================
    //  LIVE MAINNET ADDRESSES
    //  (server/deployments/mainnet-addresses.ts, each re-read on-chain during
    //   planning; Phase 0 re-asserts every structural one at execution time)
    // =====================================================================

    address public constant OWNER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    address public constant NFT_MINTER_V2 = 0x39Af088408e815844c567037C157B31d48d2E10F;
    address public constant PAUSER = 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3;
    address public constant PHUSD = 0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605;

    // ---- Tokens ----
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6dp
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F; // 18dp
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address public constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant EYE = 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65;
    address public constant SCX = 0x1B8568FbB47708E9E9D31Ff303254f748805bF21;
    address public constant FLX = 0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8;
    /// @notice Kendu Inu, 18dp. `owner()` is `address(0)` — ownership is RENOUNCED, so its
    ///         fee switches can never be moved again. Read live during planning:
    ///         `buyTotalFees() == 0`, `sellTotalFees() == 0`, `limitsInEffect() == false`.
    ///         That is strong evidence it is not fee-on-transfer, but it is NOT the
    ///         preflight — Phase 8 round-trips a real amount through `collectNudge` and
    ///         asserts the credited buffer delta equals the amount sent. That probe is
    ///         BLOCKING for broadcast.
    address public constant KENDU = 0xaa95f26e30001251fb905d264Aa7b00eE9dF6C18;

    // ---- The shared donor sink being replaced ----
    address public constant OLD_BATCH_MINTER = 0x86866e01a115C17892Ed04c548F2e8638851029d;

    // ---- Live dispatchers being replaced ----
    address public constant OLD_UNIBOOST_EYE = 0x63f4aCE0304d795A458fc2567F2c4eFeB60970CA; // idx 1
    address public constant OLD_UNIBOOST_SCX = 0xea6bAa2170E60e9069646d689730533176c59a03; // idx 2
    address public constant OLD_UNIBOOST_FLX = 0xb490c48701eB44D59af4A530d75B4fd3E79B5ddD; // idx 3
    address public constant OLD_POOLER = 0x7f74388bc970dE5e2822036A1aD06fCCd156786b; // idx 4
    address public constant OLD_DELAY_RELEASE = 0xd4ea91f6096A75a1c34A3c25D7725dE1f5c49f68; // idx 7

    // ---- The five REUSED mint-debt hooks (repointed, never redeployed) ----
    address public constant HOOK_EYE = 0x0F05c34d458dd8953864a56857a2bb67ecb22683;
    address public constant HOOK_SCX = 0xfe4Ed16a8450c76768e1EB5FF8292806E2204a2A;
    address public constant HOOK_FLX = 0x8F48E5431814FfaC9c35cf934Aa2556A946Fb33C;
    address public constant HOOK_POOLER = 0x4A26ad83306a2F17155799fDD9449f77eb3F8bD7;
    address public constant HOOK_RATCHET = 0x09AceB96337df1316e0D2d7EEEa44d754D1f8d05;

    // ---- Stakers ----
    // The three depletion stakers migrated to V2 in Phase 6.
    address public constant V1_STAKER_EYE = 0x66989bb99c1569bf2540f3bB16975801df05864B;
    address public constant V1_STAKER_SCX = 0x39e85E62d0Ccb83fb87fb525aA259F8f79A70637;
    address public constant V1_STAKER_FLX = 0x6E8cA0E37AadF35Df19F5064f279d9CC96a3403b;
    // NOT depletion-type (`depletionWindowMonths()` reverts on both) and therefore OUT OF
    // SCOPE for the V2 migration. Both are hook RECIPIENTS, so their hooks are still
    // repointed at the new dispatchers — but `setDispatcherHook` is not touched on either,
    // because the hook INSTANCE they point at does not change.
    address public constant NFT_STAKER = 0xc8514f821A3d801Fa8a8c435840a992A4365a13b; // idx-4 recipient
    address public constant RATCHET_NFT_STAKER = 0x299b0071DEf42D35eaf5ea24CC0a71Cf10655A64; // idx-7 recipient

    // ---- Uniboost swap infrastructure (unchanged; mirrored into the replacements) ----
    address public constant ROUTER02 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address public constant POOL_EYE = 0x54965801946d768b395864019903aEF8B5b63BB3; // EYE/WETH
    address public constant POOL_SCX = 0x319eAd06eb01E808C80c7eb9bd77C5d8d163AddB; // SCX/WETH
    address public constant POOL_FLX = 0x6dF6B57FB7c35D7C71395F77cb08b82A62635e19; // FLX/WETH
    address public constant MULTI_POOLER = 0xd1E5774159381915f5579dFd68507E2614f67b51;

    // ---- BalancerPoolerV2 constructor inputs ----
    // `sUSDS_`, `pool_` and `vault_` are readable off the live instance and Phase 0 asserts
    // the constants below match. `router_` and `sUSDSIsFirst_` are `private immutable` with
    // NO getter (`BalancerPoolerV2.sol:82-83`), so `cast call` reverts on them.
    //
    // They are not inferred. All six were decoded from the live instance's CREATION
    // TRANSACTION calldata, tx 0x98c5ab00bf31232d736177e16c13cfcde8cc0ba09e214eadc4d93c3ec4a421a2,
    // whose trailing ABI-encoded constructor arguments read, in order:
    //   sUSDS_        0xa3931d71877c0e7a3148cb7eb4463524fec27fbd
    //   pool_         0x642bb6860b4776cc10b26b8f361fd139e7f0db04
    //   vault_        0xba1333333333a1ba1108e8412f11850a5c319ba9
    //   router_       0x5c6fb490bdfd3246eb0bb062c168decaf4bd9fdd
    //   sUSDSIsFirst_ 0x...01  (true)
    //   initialOwner  0xcad1a7864a108dbff67f4b8af71fab0c7a86d0b6
    // That matches `script/DeployMainnetNudgePoolerV2.s.sol:138` / `:152` exactly.
    address public constant BALANCER_POOL = 0x642BB6860b4776CC10b26B8f361Fd139E7f0db04; // 50/50 phUSD/sUSDS
    address public constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address public constant BALANCER_ROUTER = 0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd;
    bool public constant SUSDS_IS_FIRST = true;
    address public constant SKY_PSM = 0xA188EEC8F81263234dA3622A406892F3D630f98c;

    // ---- StableYieldAccumulator dependencies ----
    address public constant OLD_SYA = 0x3C690EC3B2524104dE269bf0F9baa7f045eF8270;
    address public constant PHLIMBO_V2 = 0x6084a02C2Ac0127ddF1e617De257c61480A2AeE0;
    address public constant YS_USDC = 0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83;
    address public constant YS_USDE = 0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95;
    address public constant YS_DOLA = 0x1760E05356Ec1FBBA159C730781dCfB9920524e2;

    // ---- View layer (Phase 8 resolves it; a stale build is a story-071 style follow-up) ----
    address public constant MINT_PAGE_VIEW = 0x9b3ec09C14ec49FE2AC0981cDf43f3a2f69f8FB7;

    // =====================================================================
    //  CONFIGURATION CONSTANTS
    //  Configuration Safety (CLAUDE.md): every value is deliberately chosen,
    //  justified, and guarded by a `require` before any broadcast.
    // =====================================================================

    /// @notice Stream windows are PER `(batchMinter, token)`: `duration` is a field of
    ///         `Stream` inside `streams[batchMinter][token]` (`NudgeStreamer.sol:75-83`),
    ///         so these three are genuinely independent and there is no global duration.
    ///         All three are retunable later with a single `registerStream` call and no
    ///         redeploy — it settles at the OLD rate, then respreads the surviving buffer
    ///         over the FULL new window starting now (`:131-142`).
    ///
    ///         USDC is the only endogenously funded stream (Uniboost x3, the pooler, the
    ///         ratchet and the SYA all donate USDC), hence the faster release.
    uint256 public constant DURATION_USDC = 10 days;
    /// @notice phUSD and Kendu have NO donor contract and none is planned — they are topped
    ///         up BY HAND by the owner. The 30-day windows exist precisely because those are
    ///         lumpy one-off deposits rather than a steady feed. Top-up procedure, from OWNER:
    ///           IERC20(token).forceApprove(streamer, amount);
    ///           streamer.collectNudge(newBatchMinter, token, amount);
    ///         `collectNudge` is permissionless, so no owner call on the batch-minter is
    ///         needed — Phase 2's `registerStream` pre-arms both pairs permanently.
    uint256 public constant DURATION_PHUSD = 30 days;
    uint256 public constant DURATION_KENDU = 30 days;

    /// @notice Mirrors the live `BatchNFTMinter.nudgeSize()` (read 40 on-chain). The number
    ///         of mints in one batch that qualifies the caller for the reward pot.
    uint256 public constant NUDGE_SIZE = 40;

    /// @notice Depletion window for the V2 stakers, in months. Identical to the live V1
    ///         value on all three (read 12 on-chain); Phase 6 asserts the V1 reading equals
    ///         this before applying it, so a V1 retune cannot be silently dropped.
    uint256 public constant DEPLETION_WINDOW_MONTHS = 12;

    /// @notice Uniboost donation split, percent of each mint's prime token that nudges the
    ///         batch-minter. Mirrors the live value on all three (read 50 on-chain).
    uint256 public constant DONATION_SPLIT = 50;

    /// @notice Phase 6 step 9 headroom, in basis points of the V1 staker's phUSD balance.
    ///
    ///         THE READ-VS-REPLAY HAZARD. A forge script builds its calldata during a LOCAL
    ///         execution pass; the broadcast then replays those numbers against a chain
    ///         where time has moved. `initiateMigration()` freezes each user's pending at
    ///         the moment IT executes, which on the real chain is later than the moment this
    ///         script computed the sweep amount — so the frozen pendings `batchMigrate` pays
    ///         out are LARGER at broadcast time than they were at exec time, and a sweep
    ///         sized against the exec-time balance would revert
    ///         "NFTStaker: rescue breaches committedDebt" (story 073's finding 1, observed
    ///         on-chain).
    ///
    ///         100 bps of the balance is roughly 3.65 days of accrual against a 12-month
    ///         depletion window — orders of magnitude more than any Ledger session. It is
    ///         PROPORTIONAL rather than absolute on purpose: the emission rate is
    ///         budget/window, so the drift scales with the balance, and a flat margin that
    ///         suits the 721 phUSD SCX staker would swallow the 4.9 phUSD EYE staker whole.
    ///
    ///         The residual left on V1 is logged and is recoverable at any later date with a
    ///         single `oldStaker.rescueERC20(phUSD, OWNER, residual)` — V1 is paused,
    ///         migrated and inert, so nothing accrues against it afterwards.
    ///
    ///         This is NOT story 073's flat 90%. That was an explicitly-labelled
    ///         simulation-pass expedient on a dev chain proving nothing about sizing
    ///         (`DeployMocks.s.sol:1822-1831`); 073's finding was the ORDERING — settle and
    ///         freeze before moving the budget — and its docblock says sizing was left OPEN.
    uint256 public constant SWEEP_HEADROOM_BPS = 100;

    // Dispatcher indices.
    uint256 public constant IDX_EYE = 1;
    uint256 public constant IDX_SCX = 2;
    uint256 public constant IDX_FLX = 3;
    uint256 public constant IDX_POOLER = 4;
    uint256 public constant IDX_RATCHET = 7;

    // =====================================================================
    //  DEPLOYMENT STATE
    // =====================================================================

    address public nudgeStreamer;
    address public newBatchMinter;
    address public newPooler;
    address public newUniboostEYE;
    address public newUniboostSCX;
    address public newUniboostFLX;
    address public newRatchet;
    address public newSYA;
    address public v2StakerEYE;
    address public v2StakerSCX;
    address public v2StakerFLX;
    address public migratorEYE;
    address public migratorSCX;
    address public migratorFLX;

    // Phase 0 readings retained for Phase 7's conservation assertions.
    uint256 public bptAtPhase0;
    bool public kenduWhitelisted;

    /// @dev The BPT cutover baseline as recovered from the progress file's top-level
    ///      `baselines` block, and whether it was actually present there. Kept separate from
    ///      `bptAtPhase0` so Phase 0 can tell "resumed with a baseline" from "resumed without
    ///      one" and fail loudly in the second case (audit run-22, L-02).
    uint256 public bptAtCutoverPersisted;
    bool public bptBaselineFromProgressFile;

    string constant PROGRESS_FILE = "server/deployments/progress.promotion-ready.1.json";
    string constant SNAPSHOT_FILE = "scripts/snapshots/depletion-stakers-latest.json";
    uint256 constant CHAIN_ID = 1;
    string constant NETWORK_NAME = "mainnet";

    struct ContractDeployment {
        string name;
        address addr;
        bool deployed;
        bool configured;
        uint256 deployGas;
        uint256 configGas;
    }

    mapping(string => ContractDeployment) public deployments;
    string[] public contractNames;
    bool progressFileExists;
    bool isPreview;

    function setUp() public view {
        require(block.chainid == CHAIN_ID, "Wrong chain id - expected Mainnet (1)");
    }

    function run() external {
        console.log("=================================================");
        console.log("  MAINNET PROMOTION-READY CUTOVER (story 072)");
        console.log("=================================================");
        console.log("Chain ID:               ", block.chainid);
        require(block.chainid == CHAIN_ID, "Wrong chain ID - expected Mainnet (1)");

        // Configuration Safety gate — refuse to run with an unsafe or accidental value.
        require(DURATION_USDC == 10 days, "DURATION_USDC must be 10 days (user decision)");
        require(DURATION_PHUSD == 30 days, "DURATION_PHUSD must be 30 days (user decision)");
        require(DURATION_KENDU == 30 days, "DURATION_KENDU must be 30 days (user decision)");
        require(NUDGE_SIZE == 40, "NUDGE_SIZE must mirror the live batch minter (40)");
        require(DONATION_SPLIT > 0 && DONATION_SPLIT <= 100, "donation split out of range");
        require(
            DEPLETION_WINDOW_MONTHS >= 1 && DEPLETION_WINDOW_MONTHS <= 120, "depletion window out of range (1..120)"
        );
        require(SWEEP_HEADROOM_BPS > 0 && SWEEP_HEADROOM_BPS < 10000, "sweep headroom out of range");

        isPreview = vm.envOr("PREVIEW_MODE", false);
        _loadProgressFile();

        _phase0_preconditions();

        if (isPreview) {
            console.log("");
            console.log("*** PREVIEW MODE - impersonating OWNER, nothing signed, nothing broadcast ***");
            console.log("*** Progress file will NOT be written (a preview CREATE address is fiction) ***");
            console.log("");
            vm.startPrank(OWNER);
        } else {
            vm.startBroadcast();
        }

        _phase1_deployStreamer();
        _phase2_deployBatchMinter();
        _phase3_rescuePotIntoStream();
        _phase4a_pooler();
        _phase4b_uniboosts();
        _phase4c_ratchet();
        _phase5_stableYieldAccumulator();
        // Sequenced after Phase 5 on purpose — see the function's NatSpec.
        _phase4d_retireOldBatchMinter();
        _phase6_stakerMigration();

        if (isPreview) {
            vm.stopPrank();
        } else {
            vm.stopBroadcast();
        }

        _phase7_wiringAssertions();

        if (!isPreview) {
            _writeProgressFileWithStatus("completed");
        } else {
            console.log("");
            console.log("PREVIEW: no progress file written (by design).");
            _phase8_previewSmokeTests();
        }

        _printSummary();
    }

    // =====================================================================
    //  PHASE 0 — Preconditions (require-gated, no mutation)
    // =====================================================================

    function _phase0_preconditions() internal {
        console.log("\n=== Phase 0: Preconditions (no mutation) ===");

        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        // ---- Owners. Every mutation target must be the Ledger key. ----
        require(minter.owner() == OWNER, "NFTMinterV2.owner != OWNER");
        require(Pauser(PAUSER).owner() == OWNER, "Pauser.owner != OWNER");
        require(IOwnable(OLD_BATCH_MINTER).owner() == OWNER, "old BatchNFTMinter.owner != OWNER");
        require(IOwnable(OLD_POOLER).owner() == OWNER, "old BalancerPoolerV2.owner != OWNER");
        require(IOwnable(OLD_UNIBOOST_EYE).owner() == OWNER, "UniboostEYE.owner != OWNER");
        require(IOwnable(OLD_UNIBOOST_SCX).owner() == OWNER, "UniboostSCX.owner != OWNER");
        require(IOwnable(OLD_UNIBOOST_FLX).owner() == OWNER, "UniboostFLX.owner != OWNER");
        require(IOwnable(OLD_DELAY_RELEASE).owner() == OWNER, "NudgeRatchetDelayRelease.owner != OWNER");
        require(IOwnable(OLD_SYA).owner() == OWNER, "old StableYieldAccumulator.owner != OWNER");
        // Repointing is onlyOwner on all five hooks.
        require(IOwnable(HOOK_EYE).owner() == OWNER, "UniboostHookEYE.owner != OWNER");
        require(IOwnable(HOOK_SCX).owner() == OWNER, "UniboostHookSCX.owner != OWNER");
        require(IOwnable(HOOK_FLX).owner() == OWNER, "UniboostHookFLX.owner != OWNER");
        require(IOwnable(HOOK_POOLER).owner() == OWNER, "BalancerPoolerMintDebtHook.owner != OWNER");
        require(IOwnable(HOOK_RATCHET).owner() == OWNER, "NudgeRatchetMintDebtHook.owner != OWNER");
        require(IOwnable(V1_STAKER_EYE).owner() == OWNER, "V1 StakerEYE.owner != OWNER");
        require(IOwnable(V1_STAKER_SCX).owner() == OWNER, "V1 StakerSCX.owner != OWNER");
        require(IOwnable(V1_STAKER_FLX).owner() == OWNER, "V1 StakerFLX.owner != OWNER");
        console.log("owners: all 17 mutation targets == OWNER");

        // ---- Dispatcher lineup. Resume-aware: each slot holds either its pre-cutover
        //      dispatcher or the replacement loaded from the progress file. ----
        _requireSlot(IDX_EYE, OLD_UNIBOOST_EYE, newUniboostEYE, "configs(1)");
        _requireSlot(IDX_SCX, OLD_UNIBOOST_SCX, newUniboostSCX, "configs(2)");
        _requireSlot(IDX_FLX, OLD_UNIBOOST_FLX, newUniboostFLX, "configs(3)");
        _requireSlot(IDX_POOLER, OLD_POOLER, newPooler, "configs(4)");
        _requireSlot(IDX_RATCHET, OLD_DELAY_RELEASE, newRatchet, "configs(7)");
        console.log("dispatcher slots 1/2/3/4/7: OK (resume-aware)");

        // ---- Prime tokens. ----
        // INDEX 4 MUST STAY USDS-PRIMED, and the reason is PRICING BASIS, not whitelisting.
        // `replaceDispatcher` (NFTMinterV2.sol:227) repoints `configs[index].dispatcher` in
        // place and does NOT reset `price` / `growthBasisPoints`; index 4's price is
        // 18-decimal USDS-denominated. A USDC-primed replacement would reprice mints against
        // a 6-decimal basis. (The original plan attributed this requirement to a whitelist
        // tripwire in `setNudgeTokenWhitelist`; `nft-staking:032` DELETED that tripwire, so
        // the attribution is wrong — the requirement is not.)
        require(IDispatcherLike(OLD_POOLER).primeToken() == USDS, "index 4 primeToken != USDS (pricing basis)");
        require(IDispatcherLike(OLD_UNIBOOST_EYE).primeToken() == USDC, "index 1 primeToken != USDC");
        require(IDispatcherLike(OLD_UNIBOOST_SCX).primeToken() == USDC, "index 2 primeToken != USDC");
        require(IDispatcherLike(OLD_UNIBOOST_FLX).primeToken() == USDC, "index 3 primeToken != USDC");
        require(IDispatcherLike(OLD_DELAY_RELEASE).primeToken() == USDC, "index 7 primeToken != USDC");
        console.log("prime tokens: idx4=USDS (pricing basis), idx1/2/3/7=USDC");

        // ---- Every donor still points at the shared old batch minter. ----
        require(IUniboostLike(OLD_UNIBOOST_EYE).recipient() == OLD_BATCH_MINTER, "UniboostEYE sink drifted");
        require(IUniboostLike(OLD_UNIBOOST_SCX).recipient() == OLD_BATCH_MINTER, "UniboostSCX sink drifted");
        require(IUniboostLike(OLD_UNIBOOST_FLX).recipient() == OLD_BATCH_MINTER, "UniboostFLX sink drifted");
        require(IPoolerLike(OLD_POOLER).batchMinter() == OLD_BATCH_MINTER, "BalancerPoolerV2 sink drifted");
        require(IRatchetLike(OLD_DELAY_RELEASE).batchMinter() == OLD_BATCH_MINTER, "DelayRelease sink drifted");
        require(ISYALike(OLD_SYA).nudge() == OLD_BATCH_MINTER, "SYA nudge sink drifted");
        console.log("all six donors point at the shared old BatchNFTMinter");

        // ---- All four live donor dispatchers are PRE-streamer builds. ----
        // `nudgeStreamer()` does not exist on any of them, so a staticcall reverts. If one
        // of these ever succeeded it would mean the live bytecode had changed under us.
        require(!_hasNudgeStreamer(OLD_UNIBOOST_EYE), "UniboostEYE unexpectedly exposes nudgeStreamer()");
        require(!_hasNudgeStreamer(OLD_UNIBOOST_SCX), "UniboostSCX unexpectedly exposes nudgeStreamer()");
        require(!_hasNudgeStreamer(OLD_UNIBOOST_FLX), "UniboostFLX unexpectedly exposes nudgeStreamer()");
        require(!_hasNudgeStreamer(OLD_POOLER), "BalancerPoolerV2 unexpectedly exposes nudgeStreamer()");
        require(!_hasNudgeStreamer(OLD_DELAY_RELEASE), "DelayRelease unexpectedly exposes nudgeStreamer()");
        console.log("nudgeStreamer() reverts on all live donors: confirmed pre-streamer builds");

        // ---- BalancerPoolerV2 constructor mirror. The two `private immutable` args
        //      (router_, sUSDSIsFirst_) have no getter and cannot be checked here. ----
        require(IPoolerLike(OLD_POOLER).sUSDS() == SUSDS, "live pooler sUSDS != constant");
        require(IPoolerLike(OLD_POOLER).pool() == BALANCER_POOL, "live pooler pool != constant");
        require(IPoolerLike(OLD_POOLER).vault() == BALANCER_VAULT, "live pooler vault != constant");
        require(IPoolerLike(OLD_POOLER).psm() == SKY_PSM, "live pooler psm != constant");
        console.log("pooler ctor mirror OK (router_/sUSDSIsFirst_ are private immutable, sourced from");
        console.log("  DeployMainnetNudgePoolerV2.s.sol:138/:152 and cross-checked in the story)");
        console.log("  live batchDonationSize (percent):", IPoolerLike(OLD_POOLER).batchDonationSize());
        console.log("  live maxTout (WAD):              ", IPoolerLike(OLD_POOLER).maxTout());

        // ---- The five hooks: wiring + outstanding debt. ----
        _logHook("UniboostHookEYE", HOOK_EYE, OLD_UNIBOOST_EYE, V1_STAKER_EYE);
        _logHook("UniboostHookSCX", HOOK_SCX, OLD_UNIBOOST_SCX, V1_STAKER_SCX);
        _logHook("UniboostHookFLX", HOOK_FLX, OLD_UNIBOOST_FLX, V1_STAKER_FLX);
        _logHook("BalancerPoolerHook", HOOK_POOLER, OLD_POOLER, NFT_STAKER);
        _logHook("NudgeRatchetHook", HOOK_RATCHET, OLD_DELAY_RELEASE, RATCHET_NFT_STAKER);

        // ---- Stranded value. Recorded, never hardcoded. ----
        // WRITE-ONCE BPT CUTOVER BASELINE (audit run-22, L-02).
        //
        // This used to be an unconditional live read, which quietly broke resume: once
        // `_moveBPT()` has landed the old pooler is EMPTY, so a re-derived baseline is 0 and
        // Phase 7's conservation assertion collapses to `balanceOf(newPooler) >= 0` — true even
        // if the whole position were sitting on a third address. `//promotion-ready:resume`
        // calls this "THE ONE STEP A BAD RESUME COULD RUIN", so the baseline is persisted in
        // the progress file (`baselines.bptAtCutover`) and adopted here instead.
        //
        // Monotonic by construction: take the LARGER of the persisted and the live reading, so
        // a later leg can never downgrade a non-zero baseline to a smaller value or to zero.
        uint256 liveBpt = IERC20(BALANCER_POOL).balanceOf(OLD_POOLER);
        bptAtPhase0 = bptAtCutoverPersisted > liveBpt ? bptAtCutoverPersisted : liveBpt;
        console.log("--- stranded value (live) ---");
        console.log("  old BatchNFTMinter USDC:", IERC20(USDC).balanceOf(OLD_BATCH_MINTER));
        console.log("  DelayRelease USDC:      ", IERC20(USDC).balanceOf(OLD_DELAY_RELEASE));
        console.log("  old pooler BPT (live):  ", liveBpt);
        console.log("  old pooler USDS dust:   ", IERC20(USDS).balanceOf(OLD_POOLER));
        console.log("  V1 StakerEYE phUSD:     ", IERC20(PHUSD).balanceOf(V1_STAKER_EYE));
        console.log("  V1 StakerSCX phUSD:     ", IERC20(PHUSD).balanceOf(V1_STAKER_SCX));
        console.log("  V1 StakerFLX phUSD:     ", IERC20(PHUSD).balanceOf(V1_STAKER_FLX));
        console.log("  BPT cutover baseline:   ", bptAtPhase0);

        // A resume that has already moved the BPT MUST arrive carrying the baseline. Falling
        // back to the emptied live reading is precisely the bug this section closes, so refuse
        // rather than proceed with an assertion that cannot fail.
        require(
            !_isConfigured("pooler_bpt") || bptBaselineFromProgressFile,
            "RESUME ABORT: pooler_bpt is already configured but the progress file carries no baselines.bptAtCutover - restore that block verbatim (hand-trimming must NEVER remove it); re-deriving from the emptied old pooler makes the Phase 7 BPT conservation assertion vacuous"
        );
        // Tightened from `bptAtPhase0 > 0 || newPooler != address(0)`: the old escape hatch
        // existed only to let the emptied-old-pooler resume case through, and the persisted
        // baseline now handles that case properly. Leaving it would re-admit the vacuous path.
        require(
            bptAtPhase0 > 0,
            "BPT baseline is 0 - on a fresh run the old pooler must hold BPT; on a resume the progress file must carry baselines.bptAtCutover. Investigate before re-running"
        );

        // ---- The three V1 depletion stakers. ----
        _logV1Staker("V1 StakerEYE", V1_STAKER_EYE, IDX_EYE);
        _logV1Staker("V1 StakerSCX", V1_STAKER_SCX, IDX_SCX);
        _logV1Staker("V1 StakerFLX", V1_STAKER_FLX, IDX_FLX);

        console.log("Phase 0 preconditions: PASS");
    }

    function _requireSlot(uint256 idx, address expectedOld, address expectedNew, string memory label) internal view {
        (address d,,,) = NFTMinterV2(NFT_MINTER_V2).configs(idx);
        require(d == expectedOld || (expectedNew != address(0) && d == expectedNew), string.concat(label, " drifted"));
    }

    /// @dev A pre-streamer build has no `nudgeStreamer()` selector at all, so the staticcall
    ///      reverts. Returns true only if the call succeeds AND decodes to an address.
    function _hasNudgeStreamer(address target) internal view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("nudgeStreamer()"));
        return ok && ret.length >= 32;
    }

    function _logHook(string memory label, address hook, address expectedDispatcher, address expectedRecipient)
        internal
        view
    {
        IMintDebtHookLike h = IMintDebtHookLike(hook);
        require(h.dispatcher() == expectedDispatcher, string.concat(label, ": dispatcher drifted"));
        require(h.recipient() == expectedRecipient, string.concat(label, ": recipient drifted"));
        // `pull()` reverts `RecipientUnset` on a zero recipient; the require above already
        // proves it is set, so the settle in Phases 4a/4b/4c cannot fail that way.
        console.log(string.concat("  ", label, " ratio/mintDebt:"), h.ratio(), h.mintDebt());
    }

    function _logV1Staker(string memory label, address staker, uint256 expectedIdx) internal view {
        IDepletionStakerLike s = IDepletionStakerLike(staker);
        require(s.stakedId() == expectedIdx, string.concat(label, ": stakedId drifted"));
        require(s.dispatcherIndex() == expectedIdx, string.concat(label, ": dispatcherIndex drifted"));
        require(s.rewardToken() == PHUSD, "V1 staker rewardToken != phUSD");
        require(s.stakedToken() == NFT_MINTER_V2, "V1 staker stakedToken != NFTMinterV2");
        // 073's finding 2, reproduced on mainnet: the pauser is the GLOBAL Pauser, whose
        // pause() burns EYE and pauses every registrant. Phase 6 step 5's
        // setPauser(OWNER) -> Pauser.unregister -> pause() route is therefore MANDATORY.
        require(s.pauser() == PAUSER, string.concat(label, ": pauser is not the global Pauser"));
        console.log(string.concat("  ", label, " totalStaked/committedDebt:"), s.totalStaked(), s.committedDebt());
    }

    // =====================================================================
    //  PHASE 1 — NudgeStreamer
    // =====================================================================

    function _phase1_deployStreamer() internal {
        console.log("\n=== Phase 1: NudgeStreamer ===");
        if (_isDeployed("NudgeStreamer")) {
            nudgeStreamer = deployments["NudgeStreamer"].addr;
            console.log("NudgeStreamer already deployed at:", nudgeStreamer);
            return;
        }
        uint256 g = gasleft();
        // `constructor(address initialOwner)` — NudgeStreamer.sol:116. Ownable + ReentrancyGuard.
        // No wiring yet: `registerStream` calls `isNudgeToken(token)` on the batch minter, so
        // it cannot run until the multi-token minter exists AND has the token whitelisted.
        NudgeStreamer s = new NudgeStreamer(OWNER);
        nudgeStreamer = address(s);
        _trackDeployment("NudgeStreamer", nudgeStreamer, g - gasleft());
        console.log("NudgeStreamer deployed at:", nudgeStreamer);
    }

    // =====================================================================
    //  PHASE 2 — BatchNFTMinterMultiToken + the three streams
    // =====================================================================

    function _phase2_deployBatchMinter() internal {
        console.log("\n=== Phase 2: BatchNFTMinterMultiToken + streams ===");

        if (_isDeployed("BatchNFTMinter")) {
            newBatchMinter = deployments["BatchNFTMinter"].addr;
            console.log("BatchNFTMinterMultiToken already deployed at:", newBatchMinter);
        } else {
            uint256 g = gasleft();
            // `constructor(address initialOwner)` — BatchNFTMinterMultiToken.sol:162.
            BatchNFTMinterMultiToken bm = new BatchNFTMinterMultiToken(OWNER);
            newBatchMinter = address(bm);
            _trackDeployment("BatchNFTMinter", newBatchMinter, g - gasleft());
            console.log("BatchNFTMinterMultiToken deployed at:", newBatchMinter);
        }

        BatchNFTMinterMultiToken bm_ = BatchNFTMinterMultiToken(newBatchMinter);

        // `setTokenMinter` and `setDispatcherIndex` no longer HAVE to precede the whitelist
        // calls. `nft-staking:032` deleted the `_resolvePaymentPath()` call from
        // `setNudgeTokenWhitelist`'s add branch (`:328`), and with it the incidental
        // requirement that the minter/index be configured first. `_resolvePaymentPath`'s only
        // remaining caller is `batchMint` step 2 (`:479`). Keeping them first is stylistic
        // consistency with story 073's landed local script, not a constraint.
        if (!_isConfigured("bm_setTokenMinter")) {
            bm_.setTokenMinter(ITokenMinterV2(NFT_MINTER_V2));
            _trackConfig("bm_setTokenMinter");
            console.log("  setTokenMinter -> NFTMinterV2");
        }
        if (!_isConfigured("bm_setDispatcherIndex")) {
            // Index 4. `batchMint` DERIVES its payment token from
            // `ITokenDispatcherV2(configs(4).dispatcher).primeToken()` (`:733-748`), so the
            // payment asset is USDS — it is never a caller-supplied parameter.
            bm_.setDispatcherIndex(IDX_POOLER);
            _trackConfig("bm_setDispatcherIndex");
            console.log("  setDispatcherIndex -> 4");
        }

        // The whitelist is a SET: re-adding reverts `BatchMint__NudgeTokenAlreadyWhitelisted`
        // (`:332`), which is what makes duplicate reward entries structurally impossible with
        // no runtime dedupe pass (audit-21 M-02).
        if (!_isConfigured("bm_wl_usdc")) {
            bm_.setNudgeTokenWhitelist(USDC, true);
            _trackConfig("bm_wl_usdc");
            console.log("  whitelist USDC (6dp)");
        }
        if (!_isConfigured("bm_wl_phusd")) {
            bm_.setNudgeTokenWhitelist(PHUSD, true);
            _trackConfig("bm_wl_phusd");
            console.log("  whitelist phUSD (18dp)");
        }
        // Kendu is whitelisted UNCONDITIONALLY here. Its fee-on-transfer preflight is Phase 8,
        // which only runs under PREVIEW_MODE — so the protection is procedural: run
        // `promotion-ready:dry` before broadcasting and let `_probeKenduFeeOnTransfer`'s
        // `require` abort the run. Do not read this call as gated by that probe.
        if (!_isConfigured("bm_wl_kendu")) {
            bm_.setNudgeTokenWhitelist(KENDU, true);
            _trackConfig("bm_wl_kendu");
            console.log("  whitelist Kendu (18dp)");
        }
        kenduWhitelisted = bm_.isNudgeToken(KENDU);
        require(bm_.getNudgeTokens().length == 3, "expected exactly 3 whitelisted nudge tokens");

        if (!_isConfigured("bm_setNudgeSize")) {
            bm_.setNudgeSize(NUDGE_SIZE);
            _trackConfig("bm_setNudgeSize");
            console.log("  setNudgeSize -> 40 (mirrors the retiring minter)");
        }
        if (!_isConfigured("bm_setPauser")) {
            // The old shared minter has `pauser() == 0x0` — it was never registered. Closing
            // that pre-existing gap on the replacement. setPauser BEFORE register: the Pauser
            // validates `pauser() == address(this)` on register (`Pauser.sol:97-101`).
            bm_.setPauser(PAUSER);
            _trackConfig("bm_setPauser");
            console.log("  setPauser -> global Pauser");
        }
        if (!_isConfigured("bm_pauserRegister")) {
            Pauser(PAUSER).register(newBatchMinter);
            _trackConfig("bm_pauserRegister");
            console.log("  Pauser.register(newBatchMinter)");
        }

        // Streams BEFORE `setNudgeStreamer`, and whitelist before streams:
        // `registerStream` (`:125-143`) reverts `NudgeStreamer__NotWhitelisted` unless
        // `IMultiTokenNudgeWhitelist(batchMinter).isNudgeToken(token)`. `nft-staking:032` did
        // NOT touch NudgeStreamer.sol, so that gate stands. It doubles as the structural
        // guarantee that only a BatchNFTMinterMultiToken can ever be registered — a legacy
        // `BatchNFTMinter` has no `isNudgeToken` view at all.
        _registerStream("stream_usdc", USDC, DURATION_USDC, "USDC");
        _registerStream("stream_phusd", PHUSD, DURATION_PHUSD, "phUSD");
        _registerStream("stream_kendu", KENDU, DURATION_KENDU, "Kendu");

        if (!_isConfigured("bm_setNudgeStreamer")) {
            // Last. From here `batchMint` step 3.5 (`:528-536`) flushes every whitelisted
            // token's stream into the pot before `_snapshotRewards` reads balances. There is
            // no try/catch around that loop, so a streamer revert bricks `batchMint` for
            // EVERY reward token — which is why a confiscatory token must never be
            // whitelisted (Phase 8's Kendu probe).
            bm_.setNudgeStreamer(nudgeStreamer);
            _trackConfig("bm_setNudgeStreamer");
            console.log("  setNudgeStreamer -> NudgeStreamer");
        }
    }

    function _registerStream(string memory key, address token, uint256 duration, string memory label) internal {
        if (_isConfigured(key)) return;
        NudgeStreamer(nudgeStreamer).registerStream(newBatchMinter, token, duration);
        _trackConfig(key);
        console.log(string.concat("  registerStream(newBM, ", label, ") duration(s):"), duration);
    }

    // =====================================================================
    //  PHASE 3 — Rescue the pot, and route it THROUGH the streamer
    // =====================================================================

    /// @dev The old plan moved the rescued USDC straight onto the new batch-minter. That
    ///      defeats the entire point of the cutover: a balance sitting directly on the
    ///      batch-minter is standing pot, captured whole by the next caller who clears
    ///      `nudgeSize` — exactly the burst dynamic `NudgeStreamer` exists to kill. It is
    ///      DONATED into the stream instead, so it releases linearly over DURATION_USDC.
    function _phase3_rescuePotIntoStream() internal {
        console.log("\n=== Phase 3: rescue the old pot INTO the stream ===");
        if (_isConfigured("phase3_rescueAndStream")) {
            console.log("already done");
            return;
        }
        uint256 bal = IERC20(USDC).balanceOf(OLD_BATCH_MINTER);
        console.log("  old batch-minter USDC (runtime read):", bal);
        if (bal == 0) {
            console.log("  nothing to rescue");
            _trackConfig("phase3_rescueAndStream");
            return;
        }

        uint256 bmBefore = IERC20(USDC).balanceOf(newBatchMinter);
        // `rescueERC20(IERC20,address,uint256) onlyOwner` on the legacy minter. To OWNER, NOT
        // to newBM — OWNER then acts as the donor. `collectNudge` is permissionless
        // (`msg.sender` is simply the donor), so the only cost is the Ledger holding the USDC
        // transiently between these three adjacent calls.
        IRescuableERC20(OLD_BATCH_MINTER).rescueERC20(IERC20(USDC), OWNER, bal);
        _collectNudgeFromOwner(USDC, bal);

        require(IERC20(USDC).balanceOf(OLD_BATCH_MINTER) == 0, "old batch minter still holds USDC");
        require(
            IERC20(USDC).balanceOf(newBatchMinter) == bmBefore,
            "newBM USDC increased - the pot bypassed the stream (this is the whole point of Phase 3)"
        );
        _trackConfig("phase3_rescueAndStream");
    }

    /// @dev The manual top-up pattern, used by Phase 3, Phase 4c and Phase 4d, and the exact
    ///      procedure the owner uses to fund the phUSD and Kendu streams by hand later.
    ///      Asserts the credited buffer delta equals the amount sent — true for USDC (not
    ///      fee-on-transfer) and the property Phase 8 establishes for Kendu.
    function _collectNudgeFromOwner(address token, uint256 amount) internal {
        (, uint256 bufBefore,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, token);
        // `collectNudge` pulls via `transferFrom`, so the donor approves the exact amount.
        // The allowance is fully consumed inside `collectNudge`, so it always returns to 0 —
        // asserted here so a stale approval can never silently accumulate.
        require(IERC20(token).allowance(OWNER, nudgeStreamer) == 0, "stale streamer allowance");
        IERC20(token).approve(nudgeStreamer, amount);
        NudgeStreamer(nudgeStreamer).collectNudge(newBatchMinter, token, amount);
        (, uint256 bufAfter,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, token);
        // `collectNudge` credits the MEASURED receipt, not the requested amount
        // (`NudgeStreamer.sol:193-211`, added by nft-staking:031): it brackets the transfer
        // with a balance read and caps the credit at `amount`. For a non-taxed token the
        // delta is therefore exactly `amount`.
        require(bufAfter - bufBefore == amount, "stream buffer did not grow by the full amount (taxed token?)");
        require(IERC20(token).allowance(OWNER, nudgeStreamer) == 0, "collectNudge left allowance behind");
        console.log("  collectNudge -> stream buffer now:", bufAfter);
    }

    // =====================================================================
    //  PHASE 4a — index 4, BalancerPoolerV2
    // =====================================================================

    function _phase4a_pooler() internal {
        console.log("\n=== Phase 4a: index 4 BalancerPoolerV2 ===");

        // Settle the existing hook FIRST so no mintDebt is stranded across the swap.
        // `pull()` is `onlyOwnerOrRecipient`, mints phUSD to `recipient`, and is a NO-OP when
        // `mintDebt == 0` (`BalancerPoolerMintDebtHook.sol:120-127`) — safe to call blindly.
        if (!_isConfigured("pooler_pull")) {
            IMintDebtHookLike(HOOK_POOLER).pull();
            require(IMintDebtHookLike(HOOK_POOLER).mintDebt() == 0, "pooler hook mintDebt != 0 after pull");
            _trackConfig("pooler_pull");
            console.log("  BalancerPoolerMintDebtHook.pull(): settled");
        }

        if (_isDeployed("BalancerPooler")) {
            newPooler = deployments["BalancerPooler"].addr;
            console.log("  new BalancerPoolerV2 already deployed at:", newPooler);
        } else {
            uint256 g = gasleft();
            // SIX args. `_primeToken` is DERIVED as `IERC4626(sUSDS_).asset()` at
            // `BalancerPoolerV2.sol:152` — it is NOT a constructor argument, so passing
            // mainnet sUSDS makes the prime token USDS automatically. Asserted below anyway,
            // because a wrong `sUSDS_` would silently reprice index 4 against another asset.
            BalancerPoolerV2 p =
                new BalancerPoolerV2(SUSDS, BALANCER_POOL, BALANCER_VAULT, BALANCER_ROUTER, SUSDS_IS_FIRST, OWNER);
            newPooler = address(p);
            _trackDeployment("BalancerPooler", newPooler, g - gasleft());
            console.log("  new BalancerPoolerV2 deployed at:", newPooler);
        }
        require(IDispatcherLike(newPooler).primeToken() == USDS, "new pooler primeToken != USDS");

        if (!_isConfigured("pooler_config")) {
            BalancerPoolerV2 p = BalancerPoolerV2(newPooler);
            // Mirror the live config, read off the OLD instance at runtime.
            p.setPSM(IPoolerLike(OLD_POOLER).psm());
            p.setMaxTout(IPoolerLike(OLD_POOLER).maxTout()); // WAD-scaled; live value 1e16 (the :106 default)
            p.setBatchDonationSize(IPoolerLike(OLD_POOLER).batchDonationSize()); // a PERCENT 0..100, not a token amount
            p.setBatchMinter(newBatchMinter); // `setBatchMinter` :219
            p.setNudgeStreamer(nudgeStreamer); // :246, rejects address(0)
            p.setMinter(NFT_MINTER_V2);
            p.setAuthorizedPooler(MULTI_POOLER, true); // :190
            _trackConfig("pooler_config");
            console.log("  config mirrored (psm/maxTout/batchDonationSize/batchMinter/streamer/minter/pooler)");
        }

        // Settle-then-repoint. The hook's `recipient` is already `NFT_STAKER` and
        // `NFTStaker.setDispatcherHook` already points at THIS hook instance, so neither
        // needs touching — the hook address does not change. No `phUSD.setMinter` here.
        if (!_isConfigured("pooler_repointHook")) {
            IMintDebtHookLike(HOOK_POOLER).setDispatcher(newPooler);
            BalancerPoolerV2(newPooler).setHook(IDispatchHook(HOOK_POOLER));
            _trackConfig("pooler_repointHook");
            console.log("  hook repointed: setDispatcher(new) then new.setHook(hook) [fail-closed]");
        }

        _moveBPT();

        if (!_isConfigured("pooler_usdsRescue")) {
            // USDS parked by a skipped donation (`_psmDonate` failures are swallowed). Dust
            // today, but it is prime token and belongs on the live dispatcher.
            uint256 usdsBal = IERC20(USDS).balanceOf(OLD_POOLER);
            if (usdsBal > 0) {
                IPoolerLike(OLD_POOLER).rescueERC20(USDS, newPooler, usdsBal);
                console.log("  USDS moved old -> new pooler:", usdsBal);
            }
            _trackConfig("pooler_usdsRescue");
        }

        if (!_isConfigured("pooler_replace4")) {
            NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);
            (, uint256 priceBefore, uint256 growthBefore,) = minter.configs(IDX_POOLER);
            minter.replaceDispatcher(IDX_POOLER, newPooler);
            (address d, uint256 price, uint256 growth,) = minter.configs(IDX_POOLER);
            require(d == newPooler, "configs(4).dispatcher != new pooler");
            // `replaceDispatcher` does NOT reset price/growth. Both instances are USDS-primed
            // at the same 18-decimal basis, so no reset is wanted — but assert preservation
            // rather than assume it, because a mismatched decimal basis prices mints
            // catastrophically wrong (story 071's highest-risk finding).
            require(price == priceBefore && growth == growthBefore, "configs(4) price/growth not preserved");
            _trackConfig("pooler_replace4");
            console.log("  replaceDispatcher(4) OK; price/growth preserved:", price, growth);
        }
    }

    /// @dev The BPT custody shift — the single largest asset in the cutover (16,338.8190 BPT
    ///      at the 2026-08-01 planning read; re-read at runtime here, never hardcoded).
    ///
    ///      It moves as a PLAIN ERC20 TRANSFER via `withdrawBPT` (`BalancerPoolerV2.sol:424`).
    ///      No AMM operation: no `pool()`, no join, no exit, no slippage exposure. `pool()` is
    ///      now single-arg `pool(uint256 minBPT)` (`:356`) — irrelevant here precisely because
    ///      it is never called.
    ///
    ///      Six guard rails, all `require`d:
    ///        1. `newPooler.owner() == OWNER` immediately before the transfer. `withdrawBPT`
    ///           takes an ARBITRARY recipient, so the destination is asserted, not trusted.
    ///        2. Direct old -> new. Never via the Ledger EOA, the batch-minter, or any
    ///           intermediary.
    ///        3. The destination can give it back: `withdrawBPT` (`:424`) and `rescueERC20`
    ///           (`:437`), both `onlyOwner`, are on the static type of `newPooler`, and the
    ///           recovery path is exercised in PREVIEW_MODE (Phase 8).
    ///        4. Sequenced late — after the new pooler is fully deployed, config-mirrored and
    ///           hook-wired, and immediately before `replaceDispatcher(4)`. There is no
    ///           ordering in which the position rests somewhere we do not control.
    ///        5. RESUME GUARD. The progress file is written during forge's LOCAL exec, before
    ///           broadcasting, so after a crash it can name a pooler that was never deployed.
    ///           A blind resume could deploy a SECOND pooler and strand the BPT on the first.
    ///           If the old pooler's BPT is already zero we ABORT rather than re-run: the
    ///           executor must locate the holder and confirm its owner first.
    ///        6. Exact conservation both ways. BPT is not fee-on-transfer, so equality — not
    ///           tolerance — is correct.
    function _moveBPT() internal {
        if (_isConfigured("pooler_bpt")) {
            console.log("  BPT already moved");
            return;
        }
        uint256 oldBpt = IERC20(BALANCER_POOL).balanceOf(OLD_POOLER);
        uint256 newBptBefore = IERC20(BALANCER_POOL).balanceOf(newPooler);
        console.log("  BPT on old pooler (runtime read):", oldBpt);

        // Guard 5.
        require(
            oldBpt > 0, "ABORT: old pooler BPT is already 0 - locate the holder and confirm its owner, do NOT re-run"
        );
        // Guard 1.
        require(IOwnable(newPooler).owner() == OWNER, "new pooler owner != OWNER - refusing to send BPT");
        // Guard 3: prove the recovery surface exists on the destination before committing.
        require(newPooler.code.length > 0, "new pooler has no code");

        // Guard 2: direct old -> new, no intermediary.
        IPoolerLike(OLD_POOLER).withdrawBPT(newPooler, oldBpt);

        // Guard 6.
        require(IERC20(BALANCER_POOL).balanceOf(OLD_POOLER) == 0, "old pooler BPT != 0 after move");
        require(
            IERC20(BALANCER_POOL).balanceOf(newPooler) == newBptBefore + oldBpt, "new pooler BPT delta != moved amount"
        );
        _trackConfig("pooler_bpt");
        console.log("  BPT conservation OK - full position now on the new pooler");
    }

    // =====================================================================
    //  PHASE 4b — indices 1/2/3, Uniboost x3
    // =====================================================================

    function _phase4b_uniboosts() internal {
        console.log("\n=== Phase 4b: indices 1/2/3 Uniboost x3 ===");
        newUniboostEYE = _swapUniboost("EYE", IDX_EYE, OLD_UNIBOOST_EYE, HOOK_EYE, POOL_EYE, EYE);
        newUniboostSCX = _swapUniboost("SCX", IDX_SCX, OLD_UNIBOOST_SCX, HOOK_SCX, POOL_SCX, SCX);
        newUniboostFLX = _swapUniboost("FLX", IDX_FLX, OLD_UNIBOOST_FLX, HOOK_FLX, POOL_FLX, FLX);
    }

    function _swapUniboost(
        string memory label,
        uint256 idx,
        address oldUb,
        address hook,
        address targetPool,
        address targetToken
    ) internal returns (address ub) {
        string memory dKey = string.concat("Uniboost", label);
        console.log(string.concat("--- Uniboost", label, " ---"));

        // Settle the existing hook before the swap. No-op at zero debt.
        if (!_isConfigured(string.concat("ub_", label, "_pull"))) {
            IMintDebtHookLike(hook).pull();
            require(IMintDebtHookLike(hook).mintDebt() == 0, "uniboost hook mintDebt != 0 after pull");
            _trackConfig(string.concat("ub_", label, "_pull"));
            console.log("  hook.pull(): settled");
        }

        if (_isDeployed(dKey)) {
            ub = deployments[dKey].addr;
            console.log("  already deployed at:", ub);
        } else {
            uint256 g = gasleft();
            // `constructor(primeToken_, router_, targetPool_, targetToken_, initialOwner)`
            // — Uniboost.sol:115. The pair token is derived from the pool inside `_setPool`.
            Uniboost u = new Uniboost(USDC, ROUTER02, targetPool, targetToken, OWNER);
            ub = address(u);
            _trackDeployment(dKey, ub, g - gasleft());
            console.log("  deployed at:", ub);
        }

        // `UniboostMintDebtHook.scale` is `10 ** (18 - primeDecimals)` and is genuinely
        // IMMUTABLE (`:47`). The reused hook was built against a 6-decimal prime, so an
        // 18-decimal prime under it would inflate mint debt by 1e12. Assert before repointing.
        require(IDispatcherLike(ub).primeToken() == USDC, "new Uniboost is not USDC-primed (hook scale is immutable)");
        require(IERC20Meta(USDC).decimals() == 6, "USDC decimals != 6");

        if (!_isConfigured(string.concat("ub_", label, "_config"))) {
            Uniboost u = Uniboost(ub);
            u.setMinter(NFT_MINTER_V2);
            u.setRecipient(newBatchMinter); // :183
            u.setDonationSplit(DONATION_SPLIT); // :174
            u.setNudgeStreamer(nudgeStreamer); // :190, rejects address(0)
            u.setAuthorizedPooler(MULTI_POOLER, true); // :315 — MultiPooler stays the sole pooler
            _trackConfig(string.concat("ub_", label, "_config"));
            console.log("  configured (minter/recipient/split/streamer/pooler)");
        }

        // Move the LP position, the pair token and any target/prime residue off the retiring
        // instance. `Uniboost` has NO `withdrawBPT` and no dedicated LP withdrawal — the
        // NatSpec at `:332-334` states `rescueERC20` (`:338`) doubles as the LP-withdrawal
        // mechanism, the LP token simply being the pair ERC20.
        //
        // Destination: the NEW Uniboost, not the EOA. Same reasoning as the BPT — the assets
        // stay inside owner-controlled dispatcher custody, and the new instance is pointed at
        // the SAME `targetPool`/`targetToken`, so the position remains usable by `pool()`.
        if (!_isConfigured(string.concat("ub_", label, "_rescue"))) {
            _rescueTo(oldUb, targetPool, ub, "LP"); // the UniV2 pair token IS the LP token
            _rescueTo(oldUb, targetToken, ub, "target");
            _rescueTo(oldUb, IUniboostLike(oldUb).pairToken(), ub, "pair");
            // Any residual prime USDC belongs in the STREAM, not on a dispatcher: same
            // reasoning as Phase 3. Zero on all three at the planning read; handled anyway.
            uint256 usdcBal = IERC20(USDC).balanceOf(oldUb);
            if (usdcBal > 0) {
                IUniboostLike(oldUb).rescueERC20(USDC, OWNER, usdcBal);
                _collectNudgeFromOwner(USDC, usdcBal);
                console.log("  residual prime USDC routed into the stream:", usdcBal);
            }
            _trackConfig(string.concat("ub_", label, "_rescue"));
        }

        if (!_isConfigured(string.concat("ub_", label, "_repointHook"))) {
            // Fail-closed order. `hook.setRecipient` is deliberately NOT called here — it
            // still points at the V1 staker, and Phase 6 step 10 repoints it to the V2 staker
            // once the migration has completed.
            IMintDebtHookLike(hook).setDispatcher(ub);
            Uniboost(ub).setHook(IDispatchHook(hook));
            _trackConfig(string.concat("ub_", label, "_repointHook"));
            console.log("  hook repointed [fail-closed]; ratio and recipient preserved");
        }

        if (!_isConfigured(string.concat("ub_", label, "_replace"))) {
            NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);
            (, uint256 priceBefore, uint256 growthBefore,) = minter.configs(idx);
            minter.replaceDispatcher(idx, ub);
            (address d, uint256 price, uint256 growth,) = minter.configs(idx);
            require(d == ub, "configs(idx).dispatcher != new Uniboost");
            // Old and new are both USDC-primed at the same price, so unlike story 071 NO
            // setPrice/setGrowthFactor reset is needed. Assert preservation regardless.
            require(price == priceBefore && growth == growthBefore, "configs(idx) price/growth not preserved");
            require(price < 1e12, "index price is not 6-decimal-shaped");
            _trackConfig(string.concat("ub_", label, "_replace"));
            console.log("  replaceDispatcher OK; price/growth preserved:", price, growth);
        }
    }

    function _rescueTo(address from, address token, address to, string memory what) internal {
        if (token == address(0)) return;
        uint256 bal = IERC20(token).balanceOf(from);
        if (bal == 0) return;
        uint256 before = IERC20(token).balanceOf(to);
        IUniboostLike(from).rescueERC20(token, to, bal);
        require(IERC20(token).balanceOf(from) == 0, "rescue left a residue");
        require(IERC20(token).balanceOf(to) == before + bal, "rescue destination delta mismatch");
        console.log(string.concat("  moved ", what, " old -> new:"), bal);
    }

    // =====================================================================
    //  PHASE 4c — index 7, NudgeRatchetDelayRelease -> NudgeRatchet
    // =====================================================================

    function _phase4c_ratchet() internal {
        console.log("\n=== Phase 4c: index 7 NudgeRatchetDelayRelease -> NudgeRatchet ===");

        // Drain the accrued USDC FIRST, and through the STREAM.
        //
        // NOT `release(bal)`: `release` sends to the CURRENT sink, which is the old batch
        // minter that Phase 4d retires — it would push USDC onto a contract about to be
        // paused. NOT a direct transfer to `newBM` either: that recreates the burst pot.
        // `rescueERC20` -> OWNER -> `collectNudge` is more faithful to the original intent
        // than `release()` was, because this balance IS accrued donation backing and
        // streaming it is exactly how donation backing is now supposed to reach callers.
        //
        // `NudgeRatchetDelayRelease` has `rescueERC20` (`:118`); the NEW `NudgeRatchet`
        // deliberately does NOT (NatSpec `:113-119`), so nothing may ever be parked on it.
        if (!_isConfigured("ratchet_drain")) {
            uint256 bal = IERC20(USDC).balanceOf(OLD_DELAY_RELEASE);
            console.log("  DelayRelease USDC (runtime read):", bal);
            if (bal > 0) {
                IRescuableLoose(OLD_DELAY_RELEASE).rescueERC20(USDC, OWNER, bal);
                _collectNudgeFromOwner(USDC, bal);
                require(IERC20(USDC).balanceOf(OLD_DELAY_RELEASE) == 0, "DelayRelease still holds USDC");
            }
            _trackConfig("ratchet_drain");
        }

        // Settle the ratchet hook. This is the ONE hook carrying a non-zero balance (70 phUSD
        // at the planning read), accrued under the OLD dispatcher, owed to RatchetNFTStaker.
        if (!_isConfigured("ratchet_pull")) {
            console.log("  ratchet hook mintDebt before pull:", IMintDebtHookLike(HOOK_RATCHET).mintDebt());
            IMintDebtHookLike(HOOK_RATCHET).pull();
            require(IMintDebtHookLike(HOOK_RATCHET).mintDebt() == 0, "ratchet hook mintDebt != 0 after pull");
            _trackConfig("ratchet_pull");
            console.log("  settled to RatchetNFTStaker");
        }

        if (_isDeployed("NudgeRatchet")) {
            newRatchet = deployments["NudgeRatchet"].addr;
            console.log("  NudgeRatchet already deployed at:", newRatchet);
        } else {
            uint256 g = gasleft();
            // `constructor(address token_, address batchMinter_, address initialOwner)` —
            // NudgeRatchet.sol:79. The constructor requires `decimals() == 6` on `token_`.
            NudgeRatchet r = new NudgeRatchet(USDC, newBatchMinter, OWNER);
            newRatchet = address(r);
            _trackDeployment("NudgeRatchet", newRatchet, g - gasleft());
            console.log("  NudgeRatchet deployed at:", newRatchet);
        }
        require(IDispatcherLike(newRatchet).primeToken() == USDC, "new ratchet primeToken != USDC");

        if (!_isConfigured("ratchet_config")) {
            NudgeRatchet(newRatchet).setMinter(NFT_MINTER_V2);
            // `:105`, rejects address(0). `_dispatch` (`:156-160`) sweeps the FULL balance
            // through `collectNudge` and `require`s the streamer is set, so this is not
            // optional — an unset streamer is a HARD REVERT on every index-7 mint, unlike
            // the pooler's silently-swallowed failure.
            NudgeRatchet(newRatchet).setNudgeStreamer(nudgeStreamer);
            _trackConfig("ratchet_config");
            console.log("  configured (minter/streamer); batchMinter was a ctor arg");
        }
        require(IRatchetLike(newRatchet).batchMinter() == newBatchMinter, "new ratchet batchMinter != newBM");

        if (!_isConfigured("ratchet_repointHook")) {
            // Reusing the existing hook satisfies `NudgeRatchet._dispatch`'s
            // `hookTypeId() == EXPECTED_HOOK_TYPE_ID` guard (`:137-140`) BY CONSTRUCTION —
            // the hook already IS a NudgeRatchetMintDebtHook. It also preserves `ratio = 100`
            // (this type's DEFAULT_RATIO, vs 50 on the other two) and
            // `recipient = RatchetNFTStaker`, so neither `setDispatcherHook` on the staker nor
            // any `phUSD.setMinter` call is needed.
            IMintDebtHookLike(HOOK_RATCHET).setDispatcher(newRatchet);
            NudgeRatchet(newRatchet).setHook(IDispatchHook(HOOK_RATCHET));
            _trackConfig("ratchet_repointHook");
            console.log("  hook repointed [fail-closed]; hookTypeId guard satisfied by construction");
        }

        if (!_isConfigured("ratchet_replace7")) {
            NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);
            (, uint256 priceBefore, uint256 growthBefore,) = minter.configs(IDX_RATCHET);
            minter.replaceDispatcher(IDX_RATCHET, newRatchet);
            (address d, uint256 price, uint256 growth,) = minter.configs(IDX_RATCHET);
            require(d == newRatchet, "configs(7).dispatcher != new ratchet");
            // Index-7 price/growth are deliberately left UNTOUCHED (70e6 / 0).
            require(price == priceBefore && growth == growthBefore, "configs(7) price/growth not preserved");
            _trackConfig("ratchet_replace7");
            console.log("  replaceDispatcher(7) OK; price/growth untouched:", price, growth);
        }
    }

    // =====================================================================
    //  PHASE 4d — retire the old batch minter
    // =====================================================================

    /// @dev SEQUENCED AFTER PHASE 5, not after Phase 4c. The rule is "once every donor has
    ///      been repointed at `newBM`", and the sixth donor is the StableYieldAccumulator,
    ///      whose repoint happens in Phase 5. Running this earlier would retire the sink
    ///      while a live donor still targeted it.
    ///
    ///      Owner-as-pauser, NOT the global Pauser. Registering a retiring contract makes it
    ///      a landmine for `Pauser.unpause()`, which loops every registrant — the same
    ///      failure mode Phase 6 step 5 exists to avoid. Owner-as-pauser keeps the lever
    ///      local and reversible.
    function _phase4d_retireOldBatchMinter() internal {
        console.log("\n=== Phase 4d: retire the old BatchNFTMinter (after every donor is repointed) ===");
        if (_isConfigured("oldbm_retire")) {
            console.log("already retired");
            return;
        }
        ILegacyBatchMinter old = ILegacyBatchMinter(OLD_BATCH_MINTER);
        require(old.pauser() == address(0), "old batch minter already has a pauser - investigate before overwriting");

        old.setPauser(OWNER); // `:156`, onlyOwner
        old.pause(); // `:164`, onlyPauser; batchMint is `whenNotPaused` (`:238`)
        require(old.paused(), "old batch minter did not pause");
        console.log("  paused (batchMint now reverts EnforcedPause)");

        // `rescueERC20` is NOT pause-gated, so anything that lands here later is still
        // recoverable. Prove it now by sweeping whatever arrived since Phase 3 — donors were
        // still pushing at this sink while their replacements were being wired.
        uint256 residue = IERC20(USDC).balanceOf(OLD_BATCH_MINTER);
        if (residue > 0) {
            IRescuableERC20(OLD_BATCH_MINTER).rescueERC20(IERC20(USDC), OWNER, residue);
            _collectNudgeFromOwner(USDC, residue);
            console.log("  post-pause residue routed into the stream:", residue);
        } else {
            console.log("  no residue to sweep (rescueERC20 remains available while paused)");
        }
        require(IERC20(USDC).balanceOf(OLD_BATCH_MINTER) == 0, "old batch minter still holds USDC");
        _trackConfig("oldbm_retire");
    }

    // =====================================================================
    //  PHASE 5 — StableYieldAccumulator
    // =====================================================================

    function _phase5_stableYieldAccumulator() internal {
        console.log("\n=== Phase 5: StableYieldAccumulator ===");

        if (_isDeployed("StableYieldAccumulator")) {
            newSYA = deployments["StableYieldAccumulator"].addr;
            console.log("  already deployed at:", newSYA);
        } else {
            uint256 g = gasleft();
            // `constructor() Ownable(msg.sender)` — StableYieldAccumulator.sol:239. NO
            // ARGUMENTS: the broadcasting Ledger key becomes the owner directly, there is no
            // initialOwner parameter to pass, and `pauser` starts at address(0) and must be
            // set via `setPauser` (`:267`).
            StableYieldAccumulator sya = new StableYieldAccumulator();
            newSYA = address(sya);
            _trackDeployment("StableYieldAccumulator", newSYA, g - gasleft());
            console.log("  deployed at:", newSYA);
        }
        require(IOwnable(newSYA).owner() == OWNER, "new SYA owner != OWNER (msg.sender was not the Ledger key)");

        if (!_isConfigured("sya_config")) {
            StableYieldAccumulator sya = StableYieldAccumulator(newSYA);
            ISYALike old = ISYALike(OLD_SYA);

            // `setRewardToken` FIRST. That ordering is correct and conventional, but note the
            // `yield-accumulator:027` guard at `:455-458` is INERT on a fresh deploy: it only
            // probes the streamer when `nudgeSplit != 0 && nudgeStreamer != 0 && nudge != 0`,
            // and all three are zero here. It will NOT catch a mistake, and it is
            // one-directional — `setNudgeAddress` / `setNudgeSplit` / `setNudgeStreamer` can
            // each re-create an unregistered pair afterwards with no check (NatSpec `:446-449`).
            sya.setRewardToken(old.rewardToken());
            sya.setPhlimbo(old.phlimbo());
            sya.approvePhlimbo(type(uint256).max); // collectReward pulls via transferFrom
            sya.setNFTMinter(old.nftMinter()); // claim()'s burn gate
            sya.setDiscountRate(old.getDiscountRate());

            // Token configs, mirrored off the live instance.
            _mirrorTokenConfig(sya, old, USDC);
            _mirrorTokenConfig(sya, old, DOLA);
            _mirrorTokenConfig(sya, old, USDE);

            // Strategies, with each one's token read from the old instance's public
            // `strategyTokens` mapping (`:201`) rather than assumed from a name.
            _mirrorStrategy(sya, old, YS_USDC);
            _mirrorStrategy(sya, old, YS_USDE);
            _mirrorStrategy(sya, old, YS_DOLA);

            sya.setNudgeSplit(old.nudgeSplit());
            sya.setNudgeAddress(newBatchMinter); // :485
            sya.setNudgeStreamer(nudgeStreamer); // :513, rejects address(0); disarm is setNudgeSplit(0)
            sya.setPauser(PAUSER); // :267

            _trackConfig("sya_config");
            console.log("  configured; nudgeSplit/discount mirrored, nudge -> newBM, streamer set");
        }

        if (!_isConfigured("sya_strategies")) {
            // The per-client `setAsideBuffer` values live on the STRATEGIES, not on the SYA,
            // and are unaffected by an accumulator swap — deliberately not touched.
            IStrategyAdmin(YS_USDC).setWithdrawer(newSYA, true);
            IStrategyAdmin(YS_USDC).setWithdrawer(OLD_SYA, false);
            IStrategyAdmin(YS_USDE).setWithdrawer(newSYA, true);
            IStrategyAdmin(YS_USDE).setWithdrawer(OLD_SYA, false);
            IStrategyAdmin(YS_DOLA).setWithdrawer(newSYA, true);
            IStrategyAdmin(YS_DOLA).setWithdrawer(OLD_SYA, false);
            _trackConfig("sya_strategies");
            console.log("  strategies rewired (withdrawer swap x3)");
        }

        if (!_isConfigured("sya_burner")) {
            INFTMinterAdmin(NFT_MINTER_V2).setAuthorizedBurner(newSYA, true);
            INFTMinterAdmin(NFT_MINTER_V2).setAuthorizedBurner(OLD_SYA, false);
            _trackConfig("sya_burner");
            console.log("  NFTMinterV2 burner auth: new in, old out");
        }

        if (!_isConfigured("sya_pauser")) {
            Pauser(PAUSER).register(newSYA);
            // `Pauser.unregister` refuses while the target still names it as pauser
            // (`Pauser.sol:120-127`), so clear the pointer first.
            ISYALike(OLD_SYA).setPauser(address(0));
            Pauser(PAUSER).unregister(OLD_SYA);
            _trackConfig("sya_pauser");
            console.log("  Pauser registry: new in, old out");
        }

        if (!_isConfigured("sya_deactivate")) {
            // Empty the old registry so any residual `claim()` reverts before touching funds
            // and `getTotalYield()` returns 0. Snapshot first: `removeYieldStrategy` mutates
            // the array by swap-and-pop.
            address[] memory registered = ISYALike(OLD_SYA).getYieldStrategies();
            for (uint256 i = 0; i < registered.length; i++) {
                ISYALike(OLD_SYA).removeYieldStrategy(registered[i]);
            }
            _trackConfig("sya_deactivate");
            console.log("  old SYA strategy registry emptied");
        }
    }

    function _mirrorTokenConfig(StableYieldAccumulator sya, ISYALike old, address token) internal {
        (uint8 dec, uint256 rate,) = old.tokenConfigs(token);
        require(dec > 0, "old SYA has no config for a token this script mirrors");
        sya.setTokenConfig(token, dec, rate);
    }

    function _mirrorStrategy(StableYieldAccumulator sya, ISYALike old, address strategy) internal {
        address token = old.strategyTokens(strategy);
        require(token != address(0), "strategy is not registered on the old SYA");
        sya.addYieldStrategy(strategy, token);
    }

    // =====================================================================
    //  PHASE 6 — silent staker migration x3
    // =====================================================================

    /// @dev Ordering per story 073's ON-CHAIN findings, which contradict the original plan:
    ///
    ///        1. deploy V2 (identical ctor args, read off V1)
    ///        2. window + pauser + Pauser.register
    ///        3. deploy NFTStakerMigrator
    ///        4. setMigrator on BOTH sides (V1 needs it for initiateMigration/batchMigrate,
    ///           V2 needs it for depositFor — a half-met pair breaks the migration)
    ///        5. v1.setPauser(OWNER) -> Pauser.unregister(v1) -> v1.pause()
    ///        6. initiateMigration()   <- BEFORE any budget movement
    ///        7. migrate(users)
    ///        8. assert totalStaked conservation
    ///        9. THEN sweep the residual budget
    ///       10. repoint the hook's recipient to V2
    ///
    ///      Step 5's `unregister` is MANDATORY, not tidiness. `NFTStakerDepletion.pause()` is
    ///      `onlyPauser` and V1's pauser is the GLOBAL `Pauser`, whose `pause()` burns EYE and
    ///      pauses every registrant — unusable here. Repointing the pauser to OWNER without
    ///      unregistering would leave a contract in the registry whose pauser is no longer the
    ///      Pauser, and `Pauser.unpause()` loops every registrant calling `unpause()`, so a
    ///      later global unpause would revert FOR EVERYONE.
    ///
    ///      Pausing V1 at all is mandatory because V1's `stake` is UNGATED during `Migrating`
    ///      (`NFTStakerDepletion.sol:550`; audit-20 M-05, fixed in V2 at `:557`), so a
    ///      permissionless stake mid-migration wedges `finalizeAndReset`'s
    ///      `require(totalStaked == 0)`. V1 relies on the pause-before-migrate operational
    ///      remedy (audit-20 L-03).
    ///
    ///      Step 6 before step 9 is 073's finding 1: `rescueERC20` reverts
    ///      "NFTStaker: rescue breaches committedDebt" the moment any accrual exists, and
    ///      `batchMigrate`'s `_exitPosition` -> `_safePayTo` needs V1's balance to cover each
    ///      user's frozen pending, so the budget must still be on V1 when `migrate` runs.
    ///
    ///      `depositFor`'s settlement bug (audit-21 M-03) is avoided by DIRECTION OF TRAVEL:
    ///      V1's `depositFor` pays `_safePay(pending)` which resolves to
    ///      `_safePayTo(msg.sender, ...)` where msg.sender is always the MIGRATOR
    ///      (`NFTStakerDepletion.sol:778`); V2 uses `_safePayTo(user, pending)` (`:781`). We
    ///      only ever call `depositFor` on V2.
    function _phase6_stakerMigration() internal {
        console.log("\n=== Phase 6: silent V1 -> V2 depletion-staker migration ===");
        v2StakerEYE = _migrateStaker("EYE", V1_STAKER_EYE, HOOK_EYE, IDX_EYE);
        v2StakerSCX = _migrateStaker("SCX", V1_STAKER_SCX, HOOK_SCX, IDX_SCX);
        v2StakerFLX = _migrateStaker("FLX", V1_STAKER_FLX, HOOK_FLX, IDX_FLX);
    }

    function _migrateStaker(string memory label, address v1, address hook, uint256 idx) internal returns (address v2) {
        console.log(string.concat("--- Staker", label, " ---"));
        string memory v2Key = string.concat("UniboostStaker", label);
        string memory migKey = string.concat("NFTStakerMigrator", label);
        IDepletionStakerLike old = IDepletionStakerLike(v1);

        // ---- 1-2. V2 with IDENTICAL constructor args, read off V1. ----
        if (_isDeployed(v2Key)) {
            v2 = deployments[v2Key].addr;
            console.log("  V2 already deployed at:", v2);
        } else {
            require(old.stakedId() == idx && old.dispatcherIndex() == idx, "V1 ids drifted");
            uint256 g = gasleft();
            NFTStakerDepletionV2 s = new NFTStakerDepletionV2(
                IERC1155(NFT_MINTER_V2), idx, IERC20(PHUSD), OWNER, INFTSupply(NFT_MINTER_V2), idx
            );
            v2 = address(s);
            _trackDeployment(v2Key, v2, g - gasleft());
            console.log("  V2 deployed at:", v2);
        }
        if (!_isConfigured(string.concat("st_", label, "_v2cfg"))) {
            require(old.depletionWindowMonths() == DEPLETION_WINDOW_MONTHS, "V1 depletion window drifted from 12mo");
            NFTStakerDepletionV2(v2).setDepletionWindow(DEPLETION_WINDOW_MONTHS);
            NFTStakerDepletionV2(v2).setPauser(PAUSER); // setPauser BEFORE register
            Pauser(PAUSER).register(v2);
            _trackConfig(string.concat("st_", label, "_v2cfg"));
            console.log("  V2 window=12mo, registered with the global Pauser");
        }

        // ---- 3-4. Migrator, then setMigrator on BOTH sides. ----
        address mig;
        if (_isDeployed(migKey)) {
            mig = deployments[migKey].addr;
            console.log("  migrator already deployed at:", mig);
        } else {
            uint256 g = gasleft();
            // `constructor(oldStaker, newStaker, stakedToken, stakedId, rewardToken, initialOwner)`
            // — NFTStakerMigrator.sol:120. The constructor asserts `rewardToken()` matches on
            // BOTH stakers and that old != new. The migrator itself is NOT Pausable; the pause
            // is applied by the operator to the OLD staker.
            NFTStakerMigrator m = new NFTStakerMigrator(
                INFTStakerMigratable(v1), INFTStakerMigratable(v2), IERC1155(NFT_MINTER_V2), idx, IERC20(PHUSD), OWNER
            );
            mig = address(m);
            _trackDeployment(migKey, mig, g - gasleft());
            console.log("  migrator deployed at:", mig);
        }
        _recordMigrator(label, mig);

        if (!_isConfigured(string.concat("st_", label, "_setMigrator"))) {
            old.setMigrator(mig);
            NFTStakerDepletionV2(v2).setMigrator(mig);
            _trackConfig(string.concat("st_", label, "_setMigrator"));
            console.log("  setMigrator on both sides");
        }

        // ---- 5. Pause V1 via the owner route. ----
        if (!_isConfigured(string.concat("st_", label, "_pause"))) {
            old.setPauser(OWNER);
            Pauser(PAUSER).unregister(v1);
            old.pause();
            require(old.paused(), "V1 did not pause");
            _trackConfig(string.concat("st_", label, "_pause"));
            console.log("  V1 paused via setPauser(OWNER) -> Pauser.unregister -> pause()");
        }

        // ---- 6. Freeze. ----
        if (!_isConfigured(string.concat("st_", label, "_initiate"))) {
            NFTStakerMigrator(mig).initiateMigration();
            _trackConfig(string.concat("st_", label, "_initiate"));
            console.log("  initiateMigration(): pendings settled and frozen");
        }

        // ---- 7-8. Migrate, then assert conservation. ----
        uint256 preTotal = old.totalStaked();
        if (!_isConfigured(string.concat("st_", label, "_migrate"))) {
            address[] memory users = _loadSnapshotUsers(v2Key);
            require(users.length > 0 || preTotal == 0, "snapshot user list is empty but V1 still holds stake");
            uint256 v2Before = NFTStakerDepletionV2(v2).totalStaked();
            NFTStakerMigrator(mig).migrate(users);
            require(old.totalStaked() == 0, "V1 still holds stake after migrate - widen the snapshot and re-run");
            require(NFTStakerDepletionV2(v2).totalStaked() == v2Before + preTotal, "V2 total != pre-migration V1 total");
            _trackConfig(string.concat("st_", label, "_migrate"));
            console.log("  migrated; conservation OK, units:", preTotal);
        }

        // ---- 9. Sweep the residual budget. ----
        if (!_isConfigured(string.concat("st_", label, "_budget"))) {
            uint256 bal = IERC20(PHUSD).balanceOf(v1);
            uint256 committed = old.committedDebt();
            uint256 headroom = (bal * SWEEP_HEADROOM_BPS) / 10000;
            console.log("  V1 phUSD balance / committedDebt:", bal, committed);
            require(bal > committed + headroom, "V1 budget too small to sweep safely");
            uint256 movable = bal - committed - headroom;
            old.rescueERC20(IERC20(PHUSD), OWNER, movable);
            IERC20(PHUSD).approve(v2, movable); // topUp is onlyOwner and pulls from the owner
            NFTStakerDepletionV2(v2).topUp(movable);
            _trackConfig(string.concat("st_", label, "_budget"));
            console.log("  swept to V2:", movable);
            console.log("  residual left on V1 (recoverable later via rescueERC20):", IERC20(PHUSD).balanceOf(v1));
        }

        // ---- 10. Repoint the hook's RECIPIENT (its dispatcher was repointed in Phase 4b). ----
        //      After step 9 on purpose: any debt realised by an intervening `pull()` still
        //      lands on V1 while V1 is the one holding the frozen pendings.
        if (!_isConfigured(string.concat("st_", label, "_repointHook"))) {
            IMintDebtHookLike(hook).setRecipient(v2);
            NFTStakerDepletionV2(v2).setDispatcherHook(IUniboostMintDebtHook(hook));
            _trackConfig(string.concat("st_", label, "_repointHook"));
            console.log("  hook.setRecipient(V2) + V2.setDispatcherHook(hook)");
        }
    }

    function _recordMigrator(string memory label, address mig) internal {
        bytes32 h = keccak256(bytes(label));
        if (h == keccak256("EYE")) migratorEYE = mig;
        else if (h == keccak256("SCX")) migratorSCX = mig;
        else migratorFLX = mig;
    }

    /// @dev The user list is snapshotted OFF-CHAIN because `migrate` takes an explicit array
    ///      and the stakers keep no on-chain enumeration (`userInfo` is a mapping). Produced
    ///      by `scripts/snapshot-depletion-stakers.js` from `Staked` / `Unstaked` /
    ///      `DepositedFor` history, filtered to `userInfo(...).amount > 0`. `migrate` is
    ///      re-runnable — an already-migrated user's `_exitPosition` returns 0 and is skipped
    ///      — so a superset is harmless and a subset is what to avoid.
    function _loadSnapshotUsers(string memory stakerKey) internal view returns (address[] memory users) {
        string memory json = vm.readFile(SNAPSHOT_FILE);
        users = vm.parseJsonAddressArray(json, string.concat(".stakers.", stakerKey, ".users"));
    }

    // =====================================================================
    //  PHASE 7 — bidirectional wiring assertions
    // =====================================================================

    /// @dev Every pair in the story's wiring table, read back and `require`d as a round trip.
    ///      No pair may be left half-met.
    function _phase7_wiringAssertions() internal view {
        console.log("\n=== Phase 7: wiring assertions (read-back) ===");
        NFTMinterV2 minter = NFTMinterV2(NFT_MINTER_V2);

        // Dispatcher <-> minter.
        _assertSlot(minter, IDX_EYE, newUniboostEYE);
        _assertSlot(minter, IDX_SCX, newUniboostSCX);
        _assertSlot(minter, IDX_FLX, newUniboostFLX);
        _assertSlot(minter, IDX_POOLER, newPooler);
        _assertSlot(minter, IDX_RATCHET, newRatchet);
        console.log("  dispatcher <-> minter: 5 indices repointed both ways");

        // Dispatcher <-> hook (both directions), and hook -> staker.
        _assertHookPair(HOOK_EYE, newUniboostEYE, v2StakerEYE);
        _assertHookPair(HOOK_SCX, newUniboostSCX, v2StakerSCX);
        _assertHookPair(HOOK_FLX, newUniboostFLX, v2StakerFLX);
        _assertHookPair(HOOK_POOLER, newPooler, NFT_STAKER);
        _assertHookPair(HOOK_RATCHET, newRatchet, RATCHET_NFT_STAKER);
        console.log("  dispatcher <-> hook and hook -> recipient: 5 pairs met");

        // Hook <-> staker, V2 side. NFT_STAKER and RATCHET_NFT_STAKER are not depletion-type
        // and were never repointed — their `dispatcherHook` already names the same instance.
        require(IDepletionStakerLike(v2StakerEYE).dispatcherHook() == HOOK_EYE, "V2 EYE hook wrong");
        require(IDepletionStakerLike(v2StakerSCX).dispatcherHook() == HOOK_SCX, "V2 SCX hook wrong");
        require(IDepletionStakerLike(v2StakerFLX).dispatcherHook() == HOOK_FLX, "V2 FLX hook wrong");
        require(IDepletionStakerLike(NFT_STAKER).dispatcherHook() == HOOK_POOLER, "idx-4 staker hook drifted");
        require(IDepletionStakerLike(RATCHET_NFT_STAKER).dispatcherHook() == HOOK_RATCHET, "idx-7 staker hook drifted");

        // Donor <-> batch minter.
        require(IUniboostLike(newUniboostEYE).recipient() == newBatchMinter, "UniboostEYE recipient");
        require(IUniboostLike(newUniboostSCX).recipient() == newBatchMinter, "UniboostSCX recipient");
        require(IUniboostLike(newUniboostFLX).recipient() == newBatchMinter, "UniboostFLX recipient");
        require(IPoolerLike(newPooler).batchMinter() == newBatchMinter, "pooler batchMinter");
        require(IRatchetLike(newRatchet).batchMinter() == newBatchMinter, "ratchet batchMinter");
        require(ISYALike(newSYA).nudge() == newBatchMinter, "SYA nudge");
        console.log("  donor -> batch minter: all six repointed");

        // Donor <-> streamer.
        require(IUniboostLike(newUniboostEYE).nudgeStreamer() == nudgeStreamer, "UniboostEYE streamer");
        require(IUniboostLike(newUniboostSCX).nudgeStreamer() == nudgeStreamer, "UniboostSCX streamer");
        require(IUniboostLike(newUniboostFLX).nudgeStreamer() == nudgeStreamer, "UniboostFLX streamer");
        require(IPoolerLike(newPooler).nudgeStreamer() == nudgeStreamer, "pooler streamer");
        require(IRatchetLike(newRatchet).nudgeStreamer() == nudgeStreamer, "ratchet streamer");
        require(ISYALike(newSYA).nudgeStreamer() == nudgeStreamer, "SYA streamer");
        console.log("  donor -> streamer: all six set");

        // Batch minter <-> whitelist <-> streamer.
        BatchNFTMinterMultiToken bm = BatchNFTMinterMultiToken(newBatchMinter);
        require(bm.nudgeStreamer() == nudgeStreamer, "batch minter streamer");
        require(address(bm.tokenMinter()) == NFT_MINTER_V2, "batch minter tokenMinter");
        require(bm.dispatcherIndex() == IDX_POOLER, "batch minter dispatcherIndex");
        require(bm.nudgeSize() == NUDGE_SIZE, "batch minter nudgeSize");
        require(bm.getNudgeTokens().length == 3, "batch minter whitelist length != 3");
        _assertStream(USDC, DURATION_USDC, "USDC");
        _assertStream(PHUSD, DURATION_PHUSD, "phUSD");
        _assertStream(KENDU, DURATION_KENDU, "Kendu");
        console.log("  batch minter <-> whitelist <-> streamer: 3 streams armed at 10/30/30 days");

        // Uniboost <-> MultiPooler.
        require(IUniboostLike(newUniboostEYE).authVersion() > 0, "UniboostEYE authVersion");
        require(IMultiPoolerLike(MULTI_POOLER).pooler() == OWNER, "MultiPooler.pooler != OWNER");

        // Pauser registry.
        require(Pauser(PAUSER).isRegistered(newBatchMinter), "new batch minter not registered with Pauser");
        require(Pauser(PAUSER).isRegistered(newSYA), "new SYA not registered with Pauser");
        require(Pauser(PAUSER).isRegistered(v2StakerEYE), "V2 EYE not registered");
        require(Pauser(PAUSER).isRegistered(v2StakerSCX), "V2 SCX not registered");
        require(Pauser(PAUSER).isRegistered(v2StakerFLX), "V2 FLX not registered");
        // The de-registration row: omitting it breaks the global unpause() for EVERYONE.
        require(!Pauser(PAUSER).isRegistered(V1_STAKER_EYE), "V1 EYE still registered with Pauser");
        require(!Pauser(PAUSER).isRegistered(V1_STAKER_SCX), "V1 SCX still registered with Pauser");
        require(!Pauser(PAUSER).isRegistered(V1_STAKER_FLX), "V1 FLX still registered with Pauser");
        require(!Pauser(PAUSER).isRegistered(OLD_SYA), "old SYA still registered with Pauser");
        // The retired batch minter is deliberately NOT registered — a retiring contract in
        // the registry is a landmine for Pauser.unpause().
        require(!Pauser(PAUSER).isRegistered(OLD_BATCH_MINTER), "retired batch minter must NOT be registered");
        console.log("  Pauser registry: 5 in, 4 out, retired minter deliberately absent");

        // Migrator <-> both stakers.
        require(IDepletionStakerLike(V1_STAKER_EYE).migrator() == migratorEYE, "V1 EYE migrator");
        require(IDepletionStakerLike(v2StakerEYE).migrator() == migratorEYE, "V2 EYE migrator");
        require(IDepletionStakerLike(V1_STAKER_SCX).migrator() == migratorSCX, "V1 SCX migrator");
        require(IDepletionStakerLike(v2StakerSCX).migrator() == migratorSCX, "V2 SCX migrator");
        require(IDepletionStakerLike(V1_STAKER_FLX).migrator() == migratorFLX, "V1 FLX migrator");
        require(IDepletionStakerLike(v2StakerFLX).migrator() == migratorFLX, "V2 FLX migrator");

        // Migration outcome.
        require(IDepletionStakerLike(V1_STAKER_EYE).totalStaked() == 0, "V1 EYE still holds stake");
        require(IDepletionStakerLike(V1_STAKER_SCX).totalStaked() == 0, "V1 SCX still holds stake");
        require(IDepletionStakerLike(V1_STAKER_FLX).totalStaked() == 0, "V1 FLX still holds stake");
        require(IERC20(PHUSD).balanceOf(v2StakerEYE) > 0, "V2 EYE has no budget");
        require(IERC20(PHUSD).balanceOf(v2StakerSCX) > 0, "V2 SCX has no budget");
        require(IERC20(PHUSD).balanceOf(v2StakerFLX) > 0, "V2 FLX has no budget");
        console.log("  migration: V1 drained, V2 funded, migrators wired both sides");

        // SYA <-> strategies / burner / old instance.
        require(IStrategyAdmin(YS_USDC).authorizedWithdrawers(newSYA), "new SYA not a USDC withdrawer");
        require(!IStrategyAdmin(YS_USDC).authorizedWithdrawers(OLD_SYA), "old SYA still a USDC withdrawer");
        require(IStrategyAdmin(YS_USDE).authorizedWithdrawers(newSYA), "new SYA not a USDe withdrawer");
        require(!IStrategyAdmin(YS_USDE).authorizedWithdrawers(OLD_SYA), "old SYA still a USDe withdrawer");
        require(IStrategyAdmin(YS_DOLA).authorizedWithdrawers(newSYA), "new SYA not a DOLA withdrawer");
        require(!IStrategyAdmin(YS_DOLA).authorizedWithdrawers(OLD_SYA), "old SYA still a DOLA withdrawer");
        require(INFTMinterAdmin(NFT_MINTER_V2).authorizedBurners(newSYA), "new SYA not a burner");
        require(!INFTMinterAdmin(NFT_MINTER_V2).authorizedBurners(OLD_SYA), "old SYA still a burner");
        require(ISYALike(OLD_SYA).getYieldStrategies().length == 0, "old SYA registry not emptied");
        require(ISYALike(newSYA).getYieldStrategies().length == 3, "new SYA strategy count != 3");
        console.log("  SYA: strategies/burner/registry swapped, old instance inert");

        // Retired contracts.
        require(ILegacyBatchMinter(OLD_BATCH_MINTER).paused(), "old batch minter not paused");
        require(IERC20(USDC).balanceOf(OLD_BATCH_MINTER) == 0, "old batch minter holds USDC");
        require(IERC20(USDC).balanceOf(OLD_DELAY_RELEASE) == 0, "DelayRelease holds USDC");
        require(IERC20(BALANCER_POOL).balanceOf(OLD_POOLER) == 0, "old pooler still holds BPT");
        // `bptAtPhase0` is the WRITE-ONCE baseline, not a fresh read of an already-emptied old
        // pooler, so this stays a real conservation assertion on every resume leg (audit L-02).
        require(IERC20(BALANCER_POOL).balanceOf(newPooler) >= bptAtPhase0, "new pooler BPT below the cutover baseline");
        // Belt and braces (the audit's cheaper stopgap, kept alongside the real fix): once the
        // move is recorded, the new pooler must hold SOMETHING. Guarantees this branch is never
        // fully vacuous even if the baseline were somehow lost.
        require(
            !_isConfigured("pooler_bpt") || IERC20(BALANCER_POOL).balanceOf(newPooler) > 0,
            "pooler_bpt recorded as moved but the new pooler holds 0 BPT"
        );
        console.log("  retiring contracts drained; BPT fully on the new pooler");

        console.log("Phase 7: ALL WIRING ASSERTIONS PASS");
    }

    function _assertSlot(NFTMinterV2 minter, uint256 idx, address expected) internal view {
        (address d,,,) = minter.configs(idx);
        require(d == expected, "configs(idx) does not name the new dispatcher");
        require(minter.dispatcherToIndex(expected) == idx, "dispatcherToIndex not updated");
        require(minter.tokenIdToDispatcher(idx) == expected, "tokenIdToDispatcher not updated");
        // The other half of this pair — `dispatcher.setMinter(NFTMinterV2)` — cannot be read
        // back: `ATokenDispatcherV2._minter` is `internal` (`:25`) with no public accessor,
        // and `ITokenDispatcherV2` declares no getter. It IS verified, functionally and more
        // strongly, by Phase 8's live mints in PREVIEW_MODE: `dispatch` is `onlyMinter`
        // (`:44-47`), so a dispatcher whose minter was not set would revert
        // "ATokenDispatcherV2: caller is not minter" on the first mint through this index.
    }

    function _assertHookPair(address hook, address dispatcher, address recipient) internal view {
        require(IMintDebtHookLike(hook).dispatcher() == dispatcher, "hook.dispatcher != new dispatcher");
        require(address(IDispatcherLike(dispatcher).hook()) == hook, "dispatcher.hook != hook");
        require(IMintDebtHookLike(hook).recipient() == recipient, "hook.recipient wrong");
    }

    function _assertStream(address token, uint256 duration, string memory label) internal view {
        (uint256 d,,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, token);
        require(d == duration, string.concat("stream duration wrong for ", label));
    }

    // =====================================================================
    //  PHASE 8 — PREVIEW_MODE smoke tests
    // =====================================================================

    /// @dev Preview only. Nothing here is broadcast; the fork is disposable, so `deal` and
    ///      `vm.warp` are legitimate and — unlike inside a broadcasting run — time really
    ///      does move, because these calls execute locally rather than being replayed.
    function _phase8_previewSmokeTests() internal {
        console.log("\n=== Phase 8: PREVIEW smoke tests ===");

        _probeKenduFeeOnTransfer();
        _probeMintPageView();
        _probeDonorPaths();
        _probeBatchMint();
        _probeArrayLengthMismatch();
        _probeBptRecovery();
    }

    /// @dev THE BLOCKING PREFLIGHT. `nft-staking:031` made `collectNudge` credit
    ///      `min(received, amount)`, so the STREAMER's custody accounting is safe against a
    ///      taxed token — it can no longer over-credit its own stream or drain a sibling's.
    ///      What 031 does NOT do is establish whether Kendu is taxed, and it does not defend
    ///      the reward DELIVERY side: `_payRewards` still assumes `transfer(x)` delivers `x`,
    ///      and the step-3.5 flush loop has no try/catch, so a pathological token can brick
    ///      `batchMint` for EVERY reward token.
    ///
    ///      If the delta is short, Kendu must NOT be whitelisted and its `mainnet-addresses.ts`
    ///      key must stay a zero placeholder.
    function _probeKenduFeeOnTransfer() internal {
        console.log("--- Kendu fee-on-transfer probe (BLOCKING) ---");
        uint256 amount = 1_000_000e18; // 1e-24 of the 1e30 supply; large enough that any
        // percentage tax is unmistakable in the delta.
        deal(KENDU, OWNER, amount);

        uint256 streamerBefore = IERC20(KENDU).balanceOf(nudgeStreamer);
        (, uint256 bufBefore,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, KENDU);

        vm.startPrank(OWNER);
        IERC20(KENDU).approve(nudgeStreamer, amount);
        NudgeStreamer(nudgeStreamer).collectNudge(newBatchMinter, KENDU, amount);
        vm.stopPrank();

        uint256 received = IERC20(KENDU).balanceOf(nudgeStreamer) - streamerBefore;
        (, uint256 bufAfter,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, KENDU);
        console.log("  sent:     ", amount);
        console.log("  received: ", received);
        console.log("  credited: ", bufAfter - bufBefore);
        require(received == amount, "KENDU IS FEE-ON-TRANSFER: do NOT whitelist it, leave its address key at zero");
        require(bufAfter - bufBefore == amount, "Kendu credited buffer delta != amount sent");
        console.log("  VERDICT: Kendu is NOT fee-on-transfer - whitelisting is safe");
    }

    function _probeMintPageView() internal view {
        console.log("--- MintPageView.getData() ---");
        (bool ok, bytes memory ret) = MINT_PAGE_VIEW.staticcall(abi.encodeWithSignature("getData(address)", OWNER));
        if (ok) {
            uint256[] memory data = abi.decode(ret, (uint256[]));
            console.log("  resolved OK, rows:", data.length);
        } else {
            console.log("  !! getData() REVERTED against the post-cutover lineup.");
            console.log("  !! A MintPageView redeploy + ViewRouter.setPage('mint', ...) leg is required.");
        }
    }

    /// @dev One donation on each dispatcher donor path. `BalancerPoolerV2` needs POSITIVE
    ///      verification: `_psmDonate` is invoked via
    ///      `try this._psmDonate() {} catch { emit DonationSkipped; }` (`:290-292`), so a mint
    ///      can succeed with status 1 while ZERO USDC reaches the sink (073's finding). A
    ///      green transaction proves nothing — the assertion is on the emitted event and on
    ///      the STREAMER's buffer, not the batch-minter's balance, because under the streamer
    ///      model the donation lands in custody at the streamer.
    function _probeDonorPaths() internal {
        console.log("--- donor paths ---");
        address actor = address(0xA11CE);

        // Index 1 (Uniboost, USDC-primed): reverts loudly if the streamer is unset (`:248`).
        _mintOnce(actor, IDX_EYE, USDC, "Uniboost EYE (idx 1)");
        // Index 7 (NudgeRatchet, USDC-primed): also reverts loudly (`:158`).
        _mintOnce(actor, IDX_RATCHET, USDC, "NudgeRatchet (idx 7)");

        // Index 4 (BalancerPoolerV2, USDS-primed): the silent one.
        uint256 price = NFTMinterV2(NFT_MINTER_V2).getPrice(IDX_POOLER);
        deal(USDS, actor, price * 2);
        (, uint256 bufBefore,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, USDC);
        vm.recordLogs();
        vm.startPrank(actor);
        IERC20(USDS).approve(NFT_MINTER_V2, price);
        NFTMinterV2(NFT_MINTER_V2).mint(IDX_POOLER, actor);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 donated = keccak256("BatchDonatedViaPSM(uint256,uint256,address)");
        bytes32 skipped = keccak256("DonationSkipped(uint256)");
        bool sawDonated;
        bool sawSkipped;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != newPooler) continue;
            if (logs[i].topics[0] == donated) sawDonated = true;
            if (logs[i].topics[0] == skipped) sawSkipped = true;
        }
        (, uint256 bufAfter,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, USDC);
        console.log("  pooler: BatchDonatedViaPSM / DonationSkipped:", sawDonated, sawSkipped);
        console.log("  pooler: USDC stream buffer delta:", bufAfter - bufBefore);
        require(!sawSkipped, "BalancerPoolerV2 emitted DonationSkipped - the donation was SILENTLY swallowed");
        require(sawDonated, "BalancerPoolerV2 did NOT emit BatchDonatedViaPSM - a green tx is not evidence");
        require(bufAfter > bufBefore, "pooler donation did not reach the stream buffer");

        // StableYieldAccumulator: its donation path runs inside `claim()`, which burns a gate
        // NFT and requires non-trivial live yield state to reach the nudge branch — not
        // reproducible inside this script without fabricating that state. Its wiring is
        // asserted statically in Phase 7 instead (nudge == newBM, nudgeStreamer == streamer,
        // and the (newBM, USDC) stream registered, which is the exact triple the
        // yield-accumulator:027 guard probes).
        console.log("  SYA: donation path verified structurally (see Phase 7); claim() not simulated");
    }

    function _mintOnce(address actor, uint256 idx, address payToken, string memory label) internal {
        uint256 price = NFTMinterV2(NFT_MINTER_V2).getPrice(idx);
        deal(payToken, actor, price * 2);
        (, uint256 bufBefore,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, USDC);
        vm.startPrank(actor);
        IERC20(payToken).approve(NFT_MINTER_V2, price);
        NFTMinterV2(NFT_MINTER_V2).mint(idx, actor);
        vm.stopPrank();
        (, uint256 bufAfter,,) = NudgeStreamer(nudgeStreamer).streams(newBatchMinter, USDC);
        require(bufAfter > bufBefore, string.concat(label, ": collectNudge did not credit the stream"));
        console.log(string.concat("  ", label, ": stream buffer delta"), bufAfter - bufBefore);
    }

    /// @dev A qualifying `batchMint` after warping forward, so the streamed pot has actually
    ///      accrued and step 3.5's flush has something to move. The payment token is DERIVED
    ///      from `configs(4).dispatcher.primeToken()` (`_resolvePaymentPath`, `:733-748`) —
    ///      USDS, not USDC — and is never a caller parameter.
    function _probeBatchMint() internal {
        console.log("--- batchMint ---");
        BatchNFTMinterMultiToken bm = BatchNFTMinterMultiToken(newBatchMinter);
        address batcher = address(0xB0B);

        // Accrue: `pendingStream` is min(rewardPerSecond * elapsed / PRECISION, buffer).
        vm.warp(block.timestamp + 1 days);
        uint256 pendingUsdc = NudgeStreamer(nudgeStreamer).pendingStream(newBatchMinter, USDC);
        console.log("  pendingStream(USDC) after +1 day:", pendingUsdc);
        require(pendingUsdc > 0, "USDC stream did not accrue over a day");

        // `minRewards` is parallel to the FULL whitelist and its length must equal
        // `getNudgeTokens().length` or `batchMint` reverts `BatchMint__ArrayLengthMismatch`
        // (`:473-475`). The order changes on removal (swap-and-pop), so a caller must re-fetch
        // immediately before calling — which is exactly what breaks the live UI until a
        // phlimbo-ui story ships.
        address[] memory tokens = bm.getNudgeTokens();
        require(tokens.length == 3, "expected 3 nudge tokens");
        uint256[] memory minRewards = new uint256[](3);

        uint256 price = NFTMinterV2(NFT_MINTER_V2).getPrice(IDX_POOLER);
        // Generous budget: price grows `growthBasisPoints` per mint at index 4.
        uint256 budget = price * NUDGE_SIZE * 2;
        deal(USDS, batcher, budget);

        uint256 usdcBefore = IERC20(USDC).balanceOf(batcher);
        vm.startPrank(batcher);
        IERC20(USDS).approve(newBatchMinter, budget);
        bm.batchMint(NUDGE_SIZE, batcher, budget, minRewards);
        vm.stopPrank();
        uint256 usdcGained = IERC20(USDC).balanceOf(batcher) - usdcBefore;
        console.log("  qualifying batch of 40: USDC reward paid to the batcher:", usdcGained);
        require(usdcGained > 0, "qualifying batchMint paid no USDC reward from the streamed pot");
    }

    /// @dev MUST sit outside any broadcast/prank block. A reverting call inside a broadcasting
    ///      block is queued as a real transaction and aborts the whole run (073's finding).
    ///      This phase runs after `vm.stopBroadcast`/`vm.stopPrank`, and the call below is
    ///      wrapped in `expectRevert` rather than executed for effect.
    function _probeArrayLengthMismatch() internal {
        console.log("--- negative test: ArrayLengthMismatch ---");
        uint256[] memory wrongLength = new uint256[](2);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__ArrayLengthMismatch.selector, uint256(3), uint256(2)
            )
        );
        BatchNFTMinterMultiToken(newBatchMinter).batchMint(1, address(0xB0B), 1, wrongLength);
        console.log("  reverted as expected (3 whitelisted vs 2 supplied)");
    }

    /// @dev BPT guard rail 3, exercised rather than asserted by type alone: prove the new
    ///      pooler can give the position back before the cutover is ever unwound.
    function _probeBptRecovery() internal {
        console.log("--- BPT recovery path ---");
        uint256 bal = IERC20(BALANCER_POOL).balanceOf(newPooler);
        require(bal > 0, "new pooler holds no BPT");
        uint256 snap = vm.snapshotState();
        vm.startPrank(OWNER);
        BalancerPoolerV2(newPooler).withdrawBPT(OWNER, bal);
        BalancerPoolerV2(newPooler).rescueERC20(BALANCER_POOL, OWNER, 0);
        vm.stopPrank();
        require(IERC20(BALANCER_POOL).balanceOf(OWNER) >= bal, "withdrawBPT did not deliver");
        vm.revertToState(snap);
        require(IERC20(BALANCER_POOL).balanceOf(newPooler) == bal, "snapshot revert failed");
        console.log("  withdrawBPT + rescueERC20 both callable by OWNER; state restored:", bal);
    }

    // =====================================================================
    //  Progress file
    // =====================================================================

    function _loadProgressFile() internal {
        try vm.readFile(PROGRESS_FILE) returns (string memory json) {
            if (bytes(json).length > 0) {
                progressFileExists = true;
                console.log("Found existing progress file, loading...");
                _parseProgressJson(json);
            }
        } catch {
            progressFileExists = false;
            console.log("No existing progress file found, starting fresh");
        }
    }

    function _parseProgressJson(string memory json) internal {
        _parseBaselines(json);
        string[] memory names = _allProgressKeys();
        for (uint256 i = 0; i < names.length; i++) {
            _parseEntry(json, names[i]);
        }
        nudgeStreamer = deployments["NudgeStreamer"].addr;
        newBatchMinter = deployments["BatchNFTMinter"].addr;
        newPooler = deployments["BalancerPooler"].addr;
        newUniboostEYE = deployments["UniboostEYE"].addr;
        newUniboostSCX = deployments["UniboostSCX"].addr;
        newUniboostFLX = deployments["UniboostFLX"].addr;
        newRatchet = deployments["NudgeRatchet"].addr;
        newSYA = deployments["StableYieldAccumulator"].addr;
        v2StakerEYE = deployments["UniboostStakerEYE"].addr;
        v2StakerSCX = deployments["UniboostStakerSCX"].addr;
        v2StakerFLX = deployments["UniboostStakerFLX"].addr;
        migratorEYE = deployments["NFTStakerMigratorEYE"].addr;
        migratorSCX = deployments["NFTStakerMigratorSCX"].addr;
        migratorFLX = deployments["NFTStakerMigratorFLX"].addr;
    }

    /// @dev Recovers the top-level `baselines` block. Guarded by `keyExistsJson` so a progress
    ///      file written by an older binary — or one a human trimmed — parses instead of
    ///      bricking the leg; Phase 0 is what turns a MISSING baseline into a loud failure.
    ///
    ///      TRUST NOTE — read this before "simplifying" it away. `//promotion-ready:resume`
    ///      warns in capitals that the progress file LIES, and it is right about every
    ///      *write-side* entry: those are recorded during forge's LOCAL execution pass, before
    ///      anything is broadcast, so a crash leaves behind addresses for contracts that were
    ///      never deployed. `bptAtCutover` is categorically different. It is a READ of
    ///      pre-existing on-chain state, taken at Phase 0 before this session dispatches its
    ///      first transaction. No crash can falsify it, which is exactly why it is safe to
    ///      trust across legs when a deployed address is not.
    function _parseBaselines(string memory json) internal {
        if (vm.keyExistsJson(json, ".baselines.bptAtCutover")) {
            // Decimal STRING, not a JSON number: `scripts/patch-mainnet-addresses-*.js` reads
            // and rewrites this file through JS `JSON.parse`, which cannot round-trip a
            // 23-digit integer losslessly.
            bptAtCutoverPersisted = vm.parseUint(vm.parseJsonString(json, ".baselines.bptAtCutover"));
            bptBaselineFromProgressFile = true;
            console.log("Loaded persisted BPT cutover baseline:", bptAtCutoverPersisted);
        }
    }

    /// @dev Every key the progress file can carry — deployments first, then the config-step
    ///      flags. Used for both parsing and (implicitly) the write path's ordering.
    function _allProgressKeys() internal pure returns (string[] memory names) {
        names = new string[](60);
        uint256 i;
        // Deployments (address-bearing).
        names[i++] = "NudgeStreamer";
        names[i++] = "BatchNFTMinter";
        names[i++] = "BalancerPooler";
        names[i++] = "UniboostEYE";
        names[i++] = "UniboostSCX";
        names[i++] = "UniboostFLX";
        names[i++] = "NudgeRatchet";
        names[i++] = "StableYieldAccumulator";
        names[i++] = "UniboostStakerEYE";
        names[i++] = "UniboostStakerSCX";
        names[i++] = "UniboostStakerFLX";
        names[i++] = "NFTStakerMigratorEYE";
        names[i++] = "NFTStakerMigratorSCX";
        names[i++] = "NFTStakerMigratorFLX";
        // The five repointed hooks: recorded at their EXISTING addresses so the patch script
        // can round-trip them by name. Not deployments; nothing is created for these.
        names[i++] = "UniboostHookEYE";
        names[i++] = "UniboostHookSCX";
        names[i++] = "UniboostHookFLX";
        names[i++] = "BalancerPoolerMintDebtHook";
        names[i++] = "NudgeRatchetMintDebtHook";
        // Kendu: recorded whenever `isNudgeToken(KENDU)` reads true after Phase 2 — which in
        // a broadcast run is UNCONDITIONAL, because Phase 2 whitelists it unconditionally
        // (`:633`). The fee-on-transfer probe lives in Phase 8 and Phase 8 runs only under
        // PREVIEW_MODE, so the tax gate is PROCEDURAL, not structural: the operator must run
        // `promotion-ready:dry` first, where the probe's `require` aborts before any
        // broadcast. The `optional: true` branch in the patcher is a defensive fallback for
        // the case where the whitelist call did not land; it is not the normal negative path.
        names[i++] = "Kendu";
        // Config-step flags.
        names[i++] = "bm_setTokenMinter";
        names[i++] = "bm_setDispatcherIndex";
        names[i++] = "bm_wl_usdc";
        names[i++] = "bm_wl_phusd";
        names[i++] = "bm_wl_kendu";
        names[i++] = "bm_setNudgeSize";
        names[i++] = "bm_setPauser";
        names[i++] = "bm_pauserRegister";
        names[i++] = "bm_setNudgeStreamer";
        names[i++] = "stream_usdc";
        names[i++] = "stream_phusd";
        names[i++] = "stream_kendu";
        names[i++] = "phase3_rescueAndStream";
        names[i++] = "pooler_pull";
        names[i++] = "pooler_config";
        names[i++] = "pooler_repointHook";
        names[i++] = "pooler_bpt";
        names[i++] = "pooler_usdsRescue";
        names[i++] = "pooler_replace4";
        names[i++] = "ratchet_drain";
        names[i++] = "ratchet_pull";
        names[i++] = "ratchet_config";
        names[i++] = "ratchet_repointHook";
        names[i++] = "ratchet_replace7";
        names[i++] = "oldbm_retire";
        names[i++] = "sya_config";
        names[i++] = "sya_strategies";
        names[i++] = "sya_burner";
        names[i++] = "sya_pauser";
        names[i++] = "sya_deactivate";
        require(i == 50, "progress key count drifted");
        // Per-token Uniboost + staker flags.
        string[3] memory labels = ["EYE", "SCX", "FLX"];
        string[5] memory ubSteps = ["_pull", "_config", "_rescue", "_repointHook", "_replace"];
        string[7] memory stSteps =
            ["_v2cfg", "_setMigrator", "_pause", "_initiate", "_migrate", "_budget", "_repointHook"];
        string[] memory extra = new string[](36);
        uint256 j;
        for (uint256 a = 0; a < 3; a++) {
            for (uint256 b = 0; b < 5; b++) {
                extra[j++] = string.concat("ub_", labels[a], ubSteps[b]);
            }
            for (uint256 c = 0; c < 7; c++) {
                extra[j++] = string.concat("st_", labels[a], stSteps[c]);
            }
        }
        string[] memory all = new string[](i + j);
        for (uint256 k = 0; k < i; k++) {
            all[k] = names[k];
        }
        for (uint256 k = 0; k < j; k++) {
            all[i + k] = extra[k];
        }
        names = all;
    }

    function _parseEntry(string memory json, string memory name) internal {
        try vm.parseJsonAddress(json, string.concat(".contracts.", name, ".address")) returns (address addr) {
            bool deployed;
            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".deployed")) returns (bool d) {
                deployed = d;
            } catch {}
            bool configured;
            try vm.parseJsonBool(json, string.concat(".contracts.", name, ".configured")) returns (bool c) {
                configured = c;
            } catch {}
            if (deployed || configured) {
                deployments[name] = ContractDeployment({
                    name: name, addr: addr, deployed: deployed, configured: configured, deployGas: 0, configGas: 0
                });
                contractNames.push(name);
                console.log("Loaded from progress:", name);
            }
        } catch {}
    }

    function _isDeployed(string memory name) internal view returns (bool) {
        return deployments[name].deployed && deployments[name].addr != address(0);
    }

    function _isConfigured(string memory name) internal view returns (bool) {
        return deployments[name].configured;
    }

    function _trackDeployment(string memory name, address addr, uint256 gas) internal {
        _pushNameIfNew(name);
        deployments[name] = ContractDeployment({
            name: name, addr: addr, deployed: true, configured: false, deployGas: gas, configGas: 0
        });
        if (!isPreview) _writeProgressFileWithStatus("in_progress");
    }

    function _trackConfig(string memory name) internal {
        _pushNameIfNew(name);
        deployments[name] = ContractDeployment({
            name: name, addr: address(0), deployed: true, configured: true, deployGas: 0, configGas: 0
        });
        if (!isPreview) _writeProgressFileWithStatus("in_progress");
    }

    /// @dev Records an address the cutover did not create — the five repointed hooks, and the
    ///      Kendu token — so `patch-mainnet-addresses-promotion-ready.js` can fill or verify
    ///      the matching `mainnet-addresses.ts` key by name.
    function _recordAddress(string memory name, address addr) internal {
        _pushNameIfNew(name);
        deployments[name] =
            ContractDeployment({name: name, addr: addr, deployed: true, configured: true, deployGas: 0, configGas: 0});
    }

    function _pushNameIfNew(string memory name) internal {
        for (uint256 i = 0; i < contractNames.length; i++) {
            if (keccak256(bytes(contractNames[i])) == keccak256(bytes(name))) return;
        }
        contractNames.push(name);
    }

    function _writeProgressFileWithStatus(string memory status) internal {
        // Record the non-deployed addresses the patcher needs before serialising.
        _recordAddress("UniboostHookEYE", HOOK_EYE);
        _recordAddress("UniboostHookSCX", HOOK_SCX);
        _recordAddress("UniboostHookFLX", HOOK_FLX);
        _recordAddress("BalancerPoolerMintDebtHook", HOOK_POOLER);
        _recordAddress("NudgeRatchetMintDebtHook", HOOK_RATCHET);
        if (kenduWhitelisted) _recordAddress("Kendu", KENDU);

        string memory json = "{";
        json = string.concat(json, '"chainId": ', vm.toString(CHAIN_ID), ",");
        json = string.concat(json, '"networkName": "', NETWORK_NAME, '",');
        json = string.concat(json, '"deploymentStatus": "', status, '",');
        // Top-level sibling of `contracts`, deliberately NOT a ContractDeployment record: the
        // Node patcher walks `.contracts.<Name>` by name (patch-mainnet-addresses-
        // promotion-ready.js:82-105) and a baseline is not a contract. Written as a decimal
        // STRING so JS `JSON.parse` round-trips all 23 digits. `bptAtPhase0` is already the
        // monotonic maximum of the persisted and live readings (see `_phase0_preconditions`),
        // so re-emitting it here can never shrink the recorded baseline.
        json = string.concat(json, '"baselines": {"bptAtCutover": "', vm.toString(bptAtPhase0), '"},');
        json = string.concat(json, '"contracts": {');
        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            ContractDeployment memory d = deployments[name];
            if (i > 0) json = string.concat(json, ",");
            json = string.concat(json, '"', name, '": {');
            json = string.concat(json, '"address": "', vm.toString(d.addr), '",');
            json = string.concat(json, '"deployed": ', d.deployed ? "true" : "false", ",");
            json = string.concat(json, '"configured": ', d.configured ? "true" : "false", ",");
            json = string.concat(json, '"deployGas": ', vm.toString(d.deployGas), ",");
            json = string.concat(json, '"configGas": ', vm.toString(d.configGas));
            json = string.concat(json, "}");
        }
        json = string.concat(json, "}}");
        vm.writeFile(PROGRESS_FILE, json);
        console.log("Progress file updated:", PROGRESS_FILE);
    }

    // =====================================================================
    //  Summary
    // =====================================================================

    function _printSummary() internal view {
        console.log("");
        console.log("=================================================");
        console.log("        PROMOTION-READY CUTOVER SUMMARY");
        console.log("=================================================");
        console.log("NudgeStreamer:            ", nudgeStreamer);
        console.log("BatchNFTMinterMultiToken: ", newBatchMinter);
        console.log("BalancerPoolerV2 (idx 4): ", newPooler);
        console.log("Uniboost EYE (idx 1):     ", newUniboostEYE);
        console.log("Uniboost SCX (idx 2):     ", newUniboostSCX);
        console.log("Uniboost FLX (idx 3):     ", newUniboostFLX);
        console.log("NudgeRatchet (idx 7):     ", newRatchet);
        console.log("StableYieldAccumulator:   ", newSYA);
        console.log("V2 StakerEYE:             ", v2StakerEYE);
        console.log("V2 StakerSCX:             ", v2StakerSCX);
        console.log("V2 StakerFLX:             ", v2StakerFLX);
        console.log("Migrators (transient):    ", migratorEYE, migratorSCX, migratorFLX);
        console.log("-------------------------------------------------");
        console.log("Hooks REPOINTED, not redeployed - addresses unchanged, zero phUSD.setMinter calls.");
        console.log("Streams: USDC 10d, phUSD 30d, Kendu 30d (phUSD/Kendu funded MANUALLY by the owner).");
        console.log("=================================================");
    }
}

// =====================================================================
//  MINIMAL EXTERNAL TYPE INTERFACES
//  Declared locally where the concrete type is not imported, or where only a
//  read-back is needed. Every selector below was checked against the pinned
//  source at lib/nft-staking @ 9611312, lib/yield-claim-nft @ 9c18020 and
//  lib/stable-yield-accumulator @ 6eab35c.
// =====================================================================

interface IOwnable {
    function owner() external view returns (address);
}

/// @dev `ATokenDispatcherV2`'s common surface: `primeToken()` is on `ITokenDispatcherV2`,
///      `minter` and `hook` are public state on the abstract base.
interface IDispatcherLike {
    function primeToken() external view returns (address);
    function hook() external view returns (address);
}

interface IUniboostLike {
    function recipient() external view returns (address);
    function nudgeStreamer() external view returns (address);
    function pairToken() external view returns (address);
    function targetPool() external view returns (address);
    function authVersion() external view returns (uint256);
    function rescueERC20(address token, address to, uint256 amount) external;
}

interface IPoolerLike {
    function batchMinter() external view returns (address);
    function nudgeStreamer() external view returns (address);
    function sUSDS() external view returns (address);
    function pool() external view returns (address);
    function vault() external view returns (address);
    function psm() external view returns (address);
    function maxTout() external view returns (uint256);
    function batchDonationSize() external view returns (uint256);
    function withdrawBPT(address recipient, uint256 amount) external;
    function rescueERC20(address token, address to, uint256 amount) external;
}

interface IRatchetLike {
    function batchMinter() external view returns (address);
    function nudgeStreamer() external view returns (address);
}

/// @dev `NudgeRatchetDelayRelease.rescueERC20(address,address,uint256)` at `:118` — the loose
///      (non-IERC20-typed) signature the yield-claim-nft dispatchers use.
interface IRescuableLoose {
    function rescueERC20(address token, address to, uint256 amount) external;
}

/// @dev The legacy `BatchNFTMinter`'s rescue takes a typed `IERC20`.
interface IRescuableERC20 {
    function rescueERC20(IERC20 token, address to, uint256 amount) external;
}

interface ILegacyBatchMinter {
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function setPauser(address newPauser) external;
    function pause() external;
}

/// @dev Shared across all three mint-debt hook types. `dispatcher` is MUTABLE storage with an
///      owner-only setter on every one of them — this is the whole basis of the repoint.
interface IMintDebtHookLike {
    function dispatcher() external view returns (address);
    function recipient() external view returns (address);
    function ratio() external view returns (uint8);
    function mintDebt() external view returns (uint256);
    function setDispatcher(address newDispatcher) external;
    function setRecipient(address newRecipient) external;
    function pull() external;
}

interface IDepletionStakerLike {
    function stakedId() external view returns (uint256);
    function dispatcherIndex() external view returns (uint256);
    function depletionWindowMonths() external view returns (uint256);
    function rewardToken() external view returns (address);
    function stakedToken() external view returns (address);
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function totalStaked() external view returns (uint256);
    function committedDebt() external view returns (uint256);
    function migrator() external view returns (address);
    function dispatcherHook() external view returns (address);
    function setPauser(address newPauser) external;
    function setMigrator(address newMigrator) external;
    function pause() external;
    function rescueERC20(IERC20 token, address to, uint256 amount) external;
}

interface IMultiPoolerLike {
    function pooler() external view returns (address);
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
}

interface ISYALike {
    function rewardToken() external view returns (address);
    function phlimbo() external view returns (address);
    function nftMinter() external view returns (address);
    function nudge() external view returns (address);
    function nudgeSplit() external view returns (uint256);
    function nudgeStreamer() external view returns (address);
    function getDiscountRate() external view returns (uint256);
    function getYieldStrategies() external view returns (address[] memory);
    function strategyTokens(address strategy) external view returns (address);
    function tokenConfigs(address token)
        external
        view
        returns (uint8 decimals, uint256 normalizedExchangeRate, bool paused);
    function removeYieldStrategy(address strategy) external;
    function setPauser(address newPauser) external;
}

interface IStrategyAdmin {
    function setWithdrawer(address withdrawer, bool auth) external;
    function authorizedWithdrawers(address) external view returns (bool);
}

interface INFTMinterAdmin {
    function setAuthorizedBurner(address burner, bool authorized) external;
    function authorizedBurners(address burner) external view returns (bool);
}
