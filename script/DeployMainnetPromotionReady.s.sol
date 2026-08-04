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
import {PhlimboV3} from "@phlimbo-ea/PhlimboV3.sol";
import {MigratorV2V3} from "@phlimbo-ea/MigratorV2V3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
// Story 078, Phase 4f. `ViewRouter` itself is deliberately NOT imported — the router is live and
// untouched, so a local `IViewRouterLike` (see the bottom of this file) is enough, matching
// `DeployMainnetMintPageView.s.sol:112-116`.
import {DepositPageViewV3} from "../src/views/DepositPageViewV3.sol";
import {IPageView} from "../src/views/IPageView.sol";
import {IPhlimboV3} from "@phlimbo-ea/interfaces/IPhlimboV3.sol";

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
 *         STORY 076 ADDS A SIXTH: the PhlimboV3 cutover (Phase 4e). Story 072 was planned
 *         before the PhlimboV3 promo work landed and never contemplated it, so Phase 5 wired
 *         the fresh accumulator straight back at PhlimboV2 — leaving the whole
 *         "promotion-ready" stack pointed at a Phlimbo with no promotional-reward machinery
 *         at all. Phase 4e deploys `PhlimboV3`, grants it phUSD mint authority, deploys and
 *         wires `MigratorV2V3`, migrates the V2 user base in chunks, winds V2 down and
 *         revokes its mint authority; Phase 5 then points the new accumulator at V3.
 *
 * ======================== PHLIMBO V2 IS WOUND DOWN, NEVER PAUSED ========================
 *
 *  This is the exact INVERSE of Phase 6, where pausing V1 before `initiateMigration` is
 *  MANDATORY. Do not copy Phase 6's pause discipline into Phase 4e.
 *
 *  `MigratorV2V3` reads each position LIVE off V2 and calls `phlimboV2.withdraw`, which is
 *  `whenNotPaused` (`PhlimboV2.sol:363`) — so pausing V2 blocks the migrator itself
 *  (`MigratorV2V3.sol:22-24`). Worse, it does not fail loudly: the per-user body runs inside
 *  a try/catch, so a `"Pausable: paused"` revert is absorbed as a `UserMigrationSkipped`
 *  event and the pass COMPLETES with every user skipped, looking identical to a good one
 *  (`MigratorV2V3.sol:65-73`). Phase 4e therefore decodes and logs every skip event, and
 *  gates on `phlimboV2.totalStaked() == 0`.
 *
 *  The wind-down is operational, per `MigratorV2V3.sol:40-44`: `setDesiredAPY(0)`, stop
 *  feeding `collectReward` (which is what Phase 5's accumulator repoint actually
 *  accomplishes), and `setMigrator(address(0))` once the pass is done.
 *
 * ============================== NO PROMOTION IS ARMED HERE ==============================
 *
 *  `PhlimboV3` ships at `promoPhase == None` with `promoToken == address(0)`, which is a
 *  first-class designed-for state at every one of its nine consumption sites (`:106-107`,
 *  `:875`, `:946`, `:370`, `:1047`; `MigratorV2V3.sol:240-246`, `:262-271`, `:323-327`).
 *  `startPromotion` is a separate, later, deliberate owner action with its own funding step
 *  and its own depletion clock, and this script NEVER calls it. Phase 7 asserts the negative.
 *
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
 *    * The HOOK REPOINT itself makes zero `phUSD.setMinter` calls — mint authority is not
 *      touched by any part of the hook/dispatcher swap.
 *
 *      AMENDED BY STORY 076. The old, stronger claim here was "ZERO `phUSD.setMinter` calls
 *      in this ENTIRE script ... byte-identical before and after BY CONSTRUCTION". That is
 *      now FALSE, and deliberately so. Phase 4e makes exactly two:
 *
 *          phUSD.setMinter(phlimboV3, true)    // PhlimboV3 mints the phUSD reward leg
 *          phUSD.setMinter(PHLIMBO_V2, false)  // gated on phlimboV2.totalStaked() == 0
 *
 *      So the correct post-cutover claim is not invariance but an EXPECTED, ASSERTED,
 *      TWO-SIDED DELTA: the candidate-set mask must have lost exactly the PhlimboV2 bit and
 *      nothing else, and PhlimboV3 must positively hold mint authority. Both directions are
 *      asserted — a one-sided "gained V3" check would not notice an unintended revoke
 *      elsewhere. See `_phusdMinterCandidates`, `_phase7_wiringAssertions` and
 *      `VerifyPromotionReady._verifyMintAuthorityInvariance`.
 *
 *      The V2 revoke is ORDERED, not incidental: it comes after `setDesiredAPY(0)` and after
 *      the `totalStaked() == 0` gate, never before either. `PhlimboV2._claimRewards` mints
 *      with a BARE, REVERTING `phUSD.mint` (`PhlimboV2.sol:495`) — V3's non-reverting bank
 *      (`PhlimboV3.sol:913`) was added to V3 only — so revoking while any position still
 *      carried pending phUSD would make that user's `withdraw` revert and freeze their
 *      principal. With `totalStaked == 0` no position exists to reach the mint, and with
 *      `desiredAPYBps == 0` a user who stakes into V2 AFTER the cutover accrues zero pending
 *      phUSD and can still exit cleanly. The revoke does not trap late arrivals.
 *
 *      The three OTHER `setMinter` occurrences in this file (`dispatcher.setMinter(...)`)
 *      remain what they always were: an unrelated function on `ATokenDispatcherV2`, nothing
 *      to do with phUSD.
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
 *   4e  (story 076) New `PhlimboV3` + phUSD mint grant, new `MigratorV2V3`, migrate the V2
 *       user base in chunks, wind V2 down (APY->0, revoke migrator), gate on
 *       `totalStaked()==0`, revoke V2's phUSD mint authority. RUNS IMMEDIATELY BEFORE
 *       PHASE 5 so Phase 5 can point the fresh accumulator at V3 in one place, rather than
 *       mirroring V2 and correcting afterwards.
 *   4f  (story 078) THE READ SIDE OF 4e. New `DepositPageViewV3` bound to the Phase 4e
 *       `PhlimboV3`, then `ViewRouter.setPage(keccak256("deposit"), ...)` as the phase's LAST
 *       step. RUNS AFTER 4e (the view's `phlimbo` is immutable, so the V3 must already exist)
 *       and BEFORE PHASE 5 (registering a page has no bearing on the accumulator rewiring, and
 *       keeping the cutover's write and read legs adjacent is what makes Phase 7 read in order).
 *       Repointing EARLIER than 4e's migration would show not-yet-migrated users a
 *       zero-balance V3 page. FIXES A LIVE BUG: `pages("deposit")` has never once been
 *       repointed and still names a `DepositPageView` baked to PhlimboEA (V1).
 *       NO ADDRESS-BOOK KEY is minted for the new view — `ViewRouter` is the sole view key
 *       after this story; see `_phase4f_depositViewCutover`.
 *   5   New `StableYieldAccumulator` (pointed at the Phase 4e `PhlimboV3`), rewire
 *       strategies / burner / Pauser, deactivate old.
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
 *   PREREQUISITE for both, TWO snapshots — `npm run promotion-ready:snapshot` runs both:
 *     * `node scripts/snapshot-depletion-stakers.js` -> `scripts/snapshots/depletion-stakers-latest.json`
 *       Phase 6 reads its user lists from there; `migrate` takes an explicit array and the
 *       stakers keep no on-chain enumeration.
 *     * `node scripts/snapshot-phlimbo-v2-stakers.js` -> `scripts/snapshots/phlimbo-v2-snapshot-latest.json`
 *       (story 076) Phase 4e seeds `MigratorV2V3` from there. PhlimboV2 exposes no staker
 *       enumeration either, and unlike the V1->V2 migration this list is ADDRESSES ONLY —
 *       `MigratorV2V3` reads every position live. Phase 0 validates the file's `phlimboV2`
 *       field, its `blockNumber` and its age.
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

    /// @dev Story 078. The live `ViewRouter` — the ONLY view-related address a consumer needs,
    ///      and after this story the only view key left in the address books. Every page is a
    ///      `pages(bytes32)` call away. NOT redeployed here: `setPage` is `onlyOwner` and the
    ///      Ledger key already owns it.
    address public constant VIEW_ROUTER = 0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a;

    /// @dev Story 078. `keccak256("deposit")` — the router slot Phase 4f repoints. Its incumbent
    ///      is `DepositPageView` 0x50D4...03b8, still baked to PhlimboEA (V1); see Phase 4f.
    bytes32 public constant DEPOSIT_KEY = keccak256("deposit");

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

    /// @notice Story 076. Users migrated per `MigratorV2V3.migrate` call.
    ///
    ///         `migrate` walks `[cursor, min(cursor + maxIterations, len))` and each user
    ///         costs a V2 `withdraw` (with reward settlement and a phUSD mint) plus a V3
    ///         `stake`, plus up to three reward forwards. The try/catch inside `migrate`
    ///         absorbs REVERTS but NOT gas exhaustion: under the 63/64 rule a starving
    ///         `migrateOne` can eat the remainder of the pass and every subsequent user in
    ///         that call is skipped (`MigratorV2V3.sol:74-88`). A small chunk is the
    ///         mitigation the migrator's own docs prescribe, and `skipCurrent()` is the
    ///         owner backstop if one index stalls outright.
    ///
    ///         25 keeps a single `migrate` transaction comfortably inside a block gas limit
    ///         with headroom for the worst-case per-user path, at the cost of more (cheap)
    ///         transactions during the Ledger session. Erring small is deliberate: an
    ///         over-large chunk fails SILENTLY as a wall of skips, whereas an over-small one
    ///         merely costs another signature.
    uint256 public constant MIGRATE_CHUNK = 25;

    /// @notice Story 076. Upper bound on `migrate` CALLS in one Phase 4e run, across all
    ///         passes. Purely a runaway-loop guard for a script that must terminate: at
    ///         `MIGRATE_CHUNK == 25` this covers 5,000 user-slots, orders of magnitude above
    ///         the live V2 user base. Exceeding it aborts loudly rather than spinning.
    uint256 public constant MAX_MIGRATE_CALLS = 200;

    /// @notice Story 076. How many times Phase 4e may reseed and re-run the whole pass
    ///         before giving up on the `totalStaked() == 0` completeness gate.
    ///
    ///         Why more than one pass is needed at all: V2's `stake` is ungated and V2 is
    ///         deliberately NOT paused, so a user can stake into V2 at an index the cursor
    ///         has already passed. `seedUsers` is reseedable once `migrateIterator == -1`
    ///         (`MigratorV2V3.sol:145`), so the same list can simply be re-walked — a user
    ///         who has since exited reads `amount == 0` and is skipped for free.
    ///
    ///         3 is enough because the incentive to stake into V2 is gone by then: the
    ///         wind-down sets `desiredAPYBps = 0` BEFORE the gate. It is bounded rather
    ///         than open-ended because an unbounded retry against a genuinely stuck position
    ///         (dust below `MINIMUM_STAKE`, or one that reverts every time) would spin
    ///         forever instead of surfacing the finding.
    uint256 public constant MAX_MIGRATION_PASSES = 3;

    /// @notice Story 076. Maximum age of `phlimbo-v2-snapshot-latest.json`, checked in
    ///         Phase 0 against `block.timestamp`.
    ///
    ///         Phase 4e absorbs a user who stakes DURING the pass (it reseeds and re-runs).
    ///         What it cannot absorb is a user whose FIRST EVER `Staked` event postdates the
    ///         snapshot's event scan: they are absent from the seed list entirely, `migrate`
    ///         never visits them, and their position holds `totalStaked()` above 0 — failing
    ///         the completeness gate. Only a fresh scan closes that window. Mirrors the
    ///         24-hour discipline `scripts/check-phlimbo-snapshot-age.js` applies off-chain.
    uint256 public constant MAX_V2_SNAPSHOT_AGE = 24 hours;

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
    /// @dev Story 076, Phase 4e. `PhlimboV3` is PERMANENT and gets a `mainnet-addresses.ts`
    ///      key; `MigratorV2V3` is a TRANSIENT orchestrator and deliberately gets none,
    ///      following story 072's precedent for the three `NFTStakerMigrator` instances. It
    ///      still gets a progress-file record so a resume leg can find it.
    address public newPhlimboV3;
    address public migratorV2V3;

    /// @dev Story 078, Phase 4f. PERMANENT, but deliberately gets NO `mainnet-addresses.ts` key —
    ///      unlike `PhlimboV3` above. Consumers resolve it through
    ///      `ViewRouter.pages(keccak256("deposit"))`; a second, hand-maintained resolution path is
    ///      precisely the failure mode this story removes. It still gets a progress-file record so
    ///      a resume leg can find it.
    address public newDepositPageViewV3;

    // Phase 0 readings retained for Phase 7's conservation assertions.
    uint256 public bptAtPhase0;
    bool public kenduWhitelisted;

    /// @dev PHLIMBO V2 MIGRATION BASELINE (story 076), persisted under `baselines` exactly as
    ///      story 074 does for `bptAtCutover`, and for the identical reason (audit run-22
    ///      L-02). Phase 7 asserts `phlimboV3.totalStaked()` conserves what V2 held before
    ///      the migration. Re-deriving that from a live read of V2 on a resume leg is
    ///      worthless: by then V2 is empty by construction (the completeness gate demands
    ///      it), so the assertion would collapse to `>= 0` and pass no matter where the
    ///      position went. Write-once and monotonic, mirroring `bptAtPhase0`.
    uint256 public phlimboV2StakedAtCutover;
    bool public phlimboBaselineFromProgressFile;

    /// @dev The BPT cutover baseline as recovered from the progress file's top-level
    ///      `baselines` block, and whether it was actually present there. Kept separate from
    ///      `bptAtPhase0` so Phase 0 can tell "resumed with a baseline" from "resumed without
    ///      one" and fail loudly in the second case (audit run-22, L-02).
    uint256 public bptAtCutoverPersisted;
    bool public bptBaselineFromProgressFile;

    /// @dev phUSD MINT-AUTHORITY BASELINE (story 075, audit run-22 M-01 stage 3).
    ///
    ///      Phase 7 asserts nothing about phUSD's minter set, and the `5ae94bd` correction
    ///      reassigned that obligation to story-072 checklist line 1195, which is unticked —
    ///      so mint-authority invariance is verified NOWHERE today. The cutover makes zero
    ///      `phUSD.setMinter` calls (all three `setMinter` sites are
    ///      `dispatcher.setMinter(NFTMinterV2)` on `ATokenDispatcherV2`, a different function
    ///      on a different contract), so the correct claim is INVARIANCE: the membership of a
    ///      fixed candidate set, and phUSD's global `mintVersion`, must be byte-identical
    ///      before and after.
    ///
    ///      Snapshotted here as a bitmask over `_phusdMinterCandidates()` — index i of that
    ///      array maps to bit i — and persisted beside `bptAtCutover`. This side only ever
    ///      RECORDS; `VerifyPromotionReady` is what asserts. Deliberately so: a new abort in
    ///      Phase 0 could brick a live resume leg, and the invariant is a post-broadcast
    ///      claim anyway.
    uint256 public phusdMinterMaskAtPhase0;
    uint256 public phusdMintVersionAtPhase0;
    bool public phusdMinterBaselineRecorded;
    bool public phusdMinterBaselineFromProgressFile;

    string constant PROGRESS_FILE = "server/deployments/progress.promotion-ready.1.json";
    string constant SNAPSHOT_FILE = "scripts/snapshots/depletion-stakers-latest.json";
    /// @dev Story 076. Written by `scripts/snapshot-phlimbo-v2-stakers.js`. ADDRESS LIST
    ///      ONLY — `MigratorV2V3` reads every position live, so no amount is seeded.
    string constant SNAPSHOT_V2_FILE = "scripts/snapshots/phlimbo-v2-snapshot-latest.json";
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

    /// @dev `virtual` so `script/VerifyPromotionReady.s.sol` can override it with a read-only
    ///      post-broadcast entry point (audit run-22, M-01). Both npm keys name their contract
    ///      explicitly (`:DeployMainnetPromotionReady`), so nothing about the cutover path
    ///      changes. NOTHING ELSE in this function is touched by story 075.
    function run() external virtual {
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
        // Story 076, Phase 4e. Zero is not a neutral placeholder for any of these:
        // MIGRATE_CHUNK==0 is rejected by `migrate` itself ("maxIterations==0") and would
        // abort the cutover mid-session; MAX_MIGRATE_CALLS or MAX_MIGRATION_PASSES at 0
        // would silently skip the migration entirely and then fail the completeness gate
        // with a misleading message.
        require(MIGRATE_CHUNK > 0 && MIGRATE_CHUNK <= 100, "MIGRATE_CHUNK out of range (1..100)");
        require(MAX_MIGRATE_CALLS > 0, "MAX_MIGRATE_CALLS must be > 0");
        require(MAX_MIGRATION_PASSES > 0 && MAX_MIGRATION_PASSES <= 10, "MAX_MIGRATION_PASSES out of range (1..10)");
        require(MAX_V2_SNAPSHOT_AGE > 0, "MAX_V2_SNAPSHOT_AGE must be > 0");

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
        // Story 076. Sequenced IMMEDIATELY BEFORE Phase 5 on purpose: with PhlimboV3 already
        // deployed, Phase 5's `sya.setPhlimbo(...)` can name it directly. Running this AFTER
        // Phase 5 would leave a window in which a freshly deployed accumulator is wired to a
        // Phlimbo that is about to be retired, then corrected — strictly worse.
        _phase4e_phlimboV3Cutover();
        // Story 078. The read-side half of the same cutover. AFTER 4e because the view's
        // `phlimbo` is immutable and must name the V3 that 4e deploys; BEFORE Phase 5 because
        // registering a page has no bearing on the accumulator rewiring and keeping the write
        // and read legs adjacent is what makes Phase 7 readable. See the function's NatSpec.
        _phase4f_depositViewCutover();
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

        // ---- phUSD mint-authority baseline (story 075). Record only; never abort. ----
        _snapshotPhusdMinterSet();

        // ---- PhlimboV3 cutover preconditions (story 076, Phase 4e). ----
        _phase0_phlimboV3Preconditions();

        // ---- Deposit-page cutover preconditions (story 078, Phase 4f). ----
        _phase0_depositViewPreconditions();

        // ---- The three V1 depletion stakers. ----
        _logV1Staker("V1 StakerEYE", V1_STAKER_EYE, IDX_EYE);
        _logV1Staker("V1 StakerSCX", V1_STAKER_SCX, IDX_SCX);
        _logV1Staker("V1 StakerFLX", V1_STAKER_FLX, IDX_FLX);

        console.log("Phase 0 preconditions: PASS");
    }

    // =====================================================================
    //  PHASE 0 — deposit-page cutover preconditions (story 078)
    // =====================================================================

    /// @dev Everything Phase 4f depends on, read before any mutation.
    ///
    ///      DELIBERATELY NOT REQUIRED: any particular incumbent at `pages(DEPOSIT_KEY)`. The whole
    ///      premise of Phase 4f is that the incumbent is WRONG — a `DepositPageView` still baked to
    ///      PhlimboEA (V1) — so pinning it would abort the very run that fixes it, and pinning it
    ///      to the *new* view would abort every fresh run. It is logged, not asserted.
    function _phase0_depositViewPreconditions() internal view {
        console.log("--- deposit-page cutover preconditions (story 078) ---");

        require(VIEW_ROUTER.code.length > 0, "ViewRouter has no code at the pinned address");
        require(
            IViewRouterLike(VIEW_ROUTER).owner() == OWNER, "ViewRouter.owner != OWNER - Phase 4f cannot setPage"
        );

        address incumbent = IViewRouterLike(VIEW_ROUTER).pages(DEPOSIT_KEY);
        console.log("  ViewRouter:             ", VIEW_ROUTER);
        console.log("  pages('deposit') now:   ", incumbent);
        if (incumbent == address(0)) {
            console.log("  (unregistered - Phase 4f will register the deposit page for the first time)");
        } else {
            console.log("  (WILL BE DISPLACED by Phase 4f's DepositPageViewV3)");
        }
    }

    // =====================================================================
    //  PHASE 0 — PhlimboV3 cutover preconditions (story 076)
    // =====================================================================

    /// @dev Everything Phase 4e depends on, read and asserted before any mutation.
    ///
    ///      Deliberately NOT asserted here: that PhlimboV2 is unpaused. It is asserted at the
    ///      top of Phase 4e instead, where the failure message can name the migration it
    ///      breaks — and where a resume leg that has already completed the migration skips it
    ///      rather than aborting on a V2 that was legitimately paused afterwards.
    function _phase0_phlimboV3Preconditions() internal {
        console.log("--- PhlimboV3 cutover preconditions (story 076) ---");

        // phUSD's OWNER is the one who may call `setMinter`. Story 072 never needed this
        // because it made no such call; Phase 4e makes two, so it is now load-bearing.
        require(IOwnable(PHUSD).owner() == OWNER, "phUSD.owner != OWNER - Phase 4e cannot setMinter");
        require(IOwnable(PHLIMBO_V2).owner() == OWNER, "PhlimboV2.owner != OWNER");

        IPhlimboV2Like v2 = IPhlimboV2Like(PHLIMBO_V2);
        uint256 liveStaked = v2.totalStaked();
        address v2Reward = address(v2.rewardToken());
        require(v2Reward != address(0), "PhlimboV2.rewardToken is zero");
        require(v2.depletionDuration() > 0, "PhlimboV2.depletionDuration is zero - PhlimboV3 ctor would revert");
        require(address(v2.phUSD()) == PHUSD, "PhlimboV2.phUSD != the phUSD constant");

        console.log("  V2 desiredAPYBps:     ", v2.desiredAPYBps());
        console.log("  V2 depletionDuration: ", v2.depletionDuration());
        console.log("  V2 rewardToken:       ", v2Reward);
        console.log("  V2 totalStaked (live):", liveStaked);
        console.log("  V2 pauser:            ", v2.pauser());
        console.log("  V2 migrator:          ", v2.migrator());
        console.log("  V2 paused:            ", v2.paused());
        // Recorded explicitly rather than left to the mask: bit 19 of the candidate set is
        // PHLIMBO_V2, and whether it is SET at Phase 0 decides whether step 14's revoke is a
        // real revoke or a no-op. As of 2026-08-04 it reads FALSE on mainnet (baseline mask
        // 270080 = the five mint-debt hooks plus OWNER), which is consistent: V2's
        // desiredAPYBps is already 0, so accPhUSDPerShare never advances, no position carries
        // pending phUSD, and V2's bare reverting `phUSD.mint` is unreachable. The revoke is
        // kept regardless — it is idempotent, and it must not silently become a no-op if V2
        // is ever re-granted before the Ledger session.
        {
            (bool okMint, bool v2CanMint, uint256 v2Ver) = _readPhusdMinter(PHLIMBO_V2);
            console.log("  V2 holds phUSD mint:  ", okMint && v2CanMint && v2Ver == phusdMintVersionAtPhase0);
        }

        // WRITE-ONCE MIGRATION BASELINE, same discipline as story 074's `bptAtCutover`.
        // Monotonic: take the LARGER of the persisted and live readings so a resume leg run
        // against an already-emptied V2 can never downgrade a real baseline to 0.
        phlimboV2StakedAtCutover = phlimboV2StakedAtCutover > liveStaked ? phlimboV2StakedAtCutover : liveStaked;
        console.log("  V2 migration baseline:", phlimboV2StakedAtCutover);

        // A resume that has already run the migration MUST arrive carrying the baseline.
        // Falling back to the emptied live reading is exactly the vacuity audit run-22's L-02
        // is about, so refuse rather than proceed with an assertion that cannot fail.
        require(
            !_isConfigured("p4e_migrate") || phlimboBaselineFromProgressFile,
            "RESUME ABORT: p4e_migrate is already configured but the progress file carries no baselines.phlimboV2StakedAtCutover - restore that block verbatim (hand-trimming must NEVER remove it); re-deriving from the emptied PhlimboV2 makes the Phase 7 stake-conservation assertion vacuous"
        );

        // On a FRESH leg, PhlimboV3 must not yet exist and must not already hold mint
        // authority. `newPhlimboV3` is only non-zero when a progress file named it.
        if (newPhlimboV3 == address(0)) {
            require(phlimboV2StakedAtCutover > 0, "PhlimboV2 holds no stake - nothing to migrate; investigate before running Phase 4e");
        } else {
            (bool okV3, bool v3CanMint, uint256 v3Version) = _readPhusdMinter(newPhlimboV3);
            console.log("  resumed PhlimboV3:    ", newPhlimboV3);
            console.log("  resumed V3 canMint:   ", okV3 && v3CanMint && v3Version == phusdMintVersionAtPhase0);
        }

        // The V2 staker snapshot Phase 4e seeds from.
        _validateV2Snapshot();
    }

    /// @dev Validates `phlimbo-v2-snapshot-latest.json` BEFORE anything is mutated, so a
    ///      stale or wrong-target file aborts the session at Phase 0 rather than halfway
    ///      through a Ledger signing run. `vm.readFile` itself reverts when the file is
    ///      absent, which is the intended fail-loud behaviour — the file is a documented
    ///      prerequisite of both npm keys.
    function _validateV2Snapshot() internal view {
        string memory json = vm.readFile(SNAPSHOT_V2_FILE);

        address snapTarget = vm.parseJsonAddress(json, ".phlimboV2");
        require(
            snapTarget == PHLIMBO_V2,
            "V2 staker snapshot names a different phlimbo than PHLIMBO_V2 - seeding it would migrate the wrong user base"
        );

        uint256 snapBlock = vm.parseJsonUint(json, ".blockNumber");
        require(snapBlock > 0, "V2 staker snapshot has blockNumber 0");

        // Age gate. See MAX_V2_SNAPSHOT_AGE for why a stale scan is not recoverable by the
        // reseed loop. `unixTimestamp` is numeric precisely so this comparison is possible;
        // the sibling ISO `timestamp` field cannot be parsed in Solidity.
        uint256 snapTime = vm.parseJsonUint(json, ".unixTimestamp");
        require(snapTime > 0, "V2 staker snapshot has no unixTimestamp");
        require(
            block.timestamp >= snapTime,
            "V2 staker snapshot is timestamped in the future - the clock or the file is wrong"
        );
        require(
            block.timestamp - snapTime <= MAX_V2_SNAPSHOT_AGE,
            "V2 staker snapshot is STALE - re-run `npm run promotion-ready:snapshot`. A user whose first Staked event postdates the scan is absent from the seed list, is never migrated, and will fail Phase 4e's totalStaked()==0 gate"
        );

        address[] memory users = vm.parseJsonAddressArray(json, ".users");
        require(users.length > 0, "V2 staker snapshot carries an empty users[] - seedUsers would revert 'Empty users'");
        console.log("  V2 snapshot users:    ", users.length);
        console.log("  V2 snapshot block:    ", snapBlock);
        console.log("  V2 snapshot age (s):  ", block.timestamp - snapTime);
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

    // =====================================================================
    //  phUSD mint-authority baseline (story 075 / audit run-22 M-01 stage 3)
    // =====================================================================

    /// @notice The FIXED candidate set whose phUSD mint authority must not change across the
    ///         cutover. Order is part of the persisted encoding — index i is bit i of the
    ///         mask — so entries may only ever be APPENDED, never reordered or removed, or an
    ///         old progress file would decode against a different meaning.
    ///
    ///         Every entry is a compile-time `constant`. Runtime-deployed addresses are
    ///         deliberately absent: on a fresh leg they are still `address(0)` when this
    ///         snapshot is taken, so they cannot carry a meaningful "before" reading. The
    ///         verifier covers them with a stronger ABSOLUTE assertion instead — none of the
    ///         newly deployed contracts may hold phUSD mint authority, with the ONE declared
    ///         exception `PhlimboV3` (story 076), which is asserted POSITIVELY instead.
    ///
    ///         STORY 076 APPENDED `PHLIMBO_V2` AT INDEX 19. Phase 4e revokes its phUSD mint
    ///         authority, and an address absent from this set cannot have its removal
    ///         expressed in the mask at all — the revoke would then be verified nowhere.
    ///         Appending is safe by the append-only rule above: bits 0..18 keep their exact
    ///         prior meaning, so a progress file written before story 076 still decodes
    ///         correctly (its bit 19 simply reads 0, which the delta check tolerates because
    ///         it asserts the baseline's OWN bit 19 was cleared, not that it was ever set).
    ///
    ///         PhlimboV3 is deliberately NOT appended here, and this is the one place the
    ///         story-076 plan had to bend to the code: this function is `pure` over
    ///         compile-time constants, and PhlimboV3's address is a runtime CREATE. It is
    ///         covered instead by the positive assertion in `_phase7_wiringAssertions` and by
    ///         its explicit exclusion from the verifier's `_requireNotPhusdMinter` sweep —
    ///         which together give exactly the two-sided delta the plan asked for.
    function _phusdMinterCandidates() internal pure returns (address[] memory set) {
        set = new address[](20);
        uint256 i;
        set[i++] = NFT_MINTER_V2;
        set[i++] = OLD_BATCH_MINTER;
        set[i++] = OLD_POOLER;
        set[i++] = OLD_SYA;
        set[i++] = OLD_UNIBOOST_EYE;
        set[i++] = OLD_UNIBOOST_SCX;
        set[i++] = OLD_UNIBOOST_FLX;
        set[i++] = OLD_DELAY_RELEASE;
        set[i++] = HOOK_EYE;
        set[i++] = HOOK_SCX;
        set[i++] = HOOK_FLX;
        set[i++] = HOOK_POOLER;
        set[i++] = HOOK_RATCHET;
        set[i++] = NFT_STAKER;
        set[i++] = RATCHET_NFT_STAKER;
        set[i++] = V1_STAKER_EYE;
        set[i++] = V1_STAKER_SCX;
        set[i++] = V1_STAKER_FLX;
        set[i++] = OWNER;
        // --- Appended by story 076. Bit 19. See the NatSpec above before touching. ---
        set[i++] = PHLIMBO_V2;
        require(i == 20, "phUSD minter candidate count drifted");
    }

    /// @notice Bit index of `PHLIMBO_V2` inside `_phusdMinterCandidates()`. The one bit the
    ///         cutover is EXPECTED to clear, and the only one it may.
    /// @dev    Kept as a named constant so the delta assertion in `_phase7_wiringAssertions`
    ///         and in `VerifyPromotionReady` cannot drift apart from the array above.
    uint256 public constant PHUSD_MINTER_BIT_PHLIMBO_V2 = 19;

    /// @dev Guards the constant above against a silent reorder of the candidate array. A
    ///      wrong bit index would make the two-sided delta assert the wrong thing while still
    ///      passing, which is the worst possible failure mode for a control of this kind.
    function _requirePhlimboV2BitIndex() internal pure {
        address[] memory set = _phusdMinterCandidates();
        require(
            set[PHUSD_MINTER_BIT_PHLIMBO_V2] == PHLIMBO_V2,
            "PHUSD_MINTER_BIT_PHLIMBO_V2 no longer indexes PHLIMBO_V2 - the candidate set was reordered, which also invalidates every persisted mask"
        );
    }

    /// @dev Reads phUSD's authorization for one address via staticcall rather than a typed
    ///      call, so an unexpected live interface degrades to "unreadable" instead of
    ///      reverting a mainnet leg. `IFlax.authorizedMinters(address)` returns a
    ///      `MinterInfo{bool canMint; uint256 mintVersion;}`, ABI-encoded as two words.
    function _readPhusdMinter(address who) internal view returns (bool ok, bool canMint, uint256 version) {
        (bool success, bytes memory ret) = PHUSD.staticcall(abi.encodeWithSignature("authorizedMinters(address)", who));
        if (!success || ret.length < 64) return (false, false, 0);
        (canMint, version) = abi.decode(ret, (bool, uint256));
        ok = true;
    }

    /// @dev Reads the live membership bitmask plus phUSD's global `mintVersion`. `ok` is false
    ///      if phUSD exposes no usable read path, in which case NOTHING is persisted and the
    ///      verifier fails loudly on the absent baseline rather than silently passing.
    function _livePhusdMinterMask() internal view returns (bool ok, uint256 mask, uint256 globalVersion) {
        (bool vOk, bytes memory vRet) = PHUSD.staticcall(abi.encodeWithSignature("mintVersion()"));
        if (!vOk || vRet.length < 32) return (false, 0, 0);
        globalVersion = abi.decode(vRet, (uint256));

        address[] memory set = _phusdMinterCandidates();
        for (uint256 i = 0; i < set.length; i++) {
            (bool rOk, bool canMint, uint256 grantedAt) = _readPhusdMinter(set[i]);
            if (!rOk) return (false, 0, 0);
            // A grant issued against a superseded `mintVersion` is inert — `mint()` requires
            // `minterInfo.mintVersion == mintVersion` — so it must NOT read as membership.
            if (canMint && grantedAt == globalVersion) mask |= (1 << i);
        }
        ok = true;
    }

    /// @dev Write-once: a persisted baseline always wins, so a resume leg can never overwrite
    ///      the true pre-cutover reading with a post-cutover one. Records only — the assertion
    ///      lives in `VerifyPromotionReady`.
    function _snapshotPhusdMinterSet() internal {
        if (phusdMinterBaselineFromProgressFile) {
            console.log("--- phUSD mint-authority baseline (from progress file) ---");
            console.log("  membership mask:", phusdMinterMaskAtPhase0);
            console.log("  mintVersion:    ", phusdMintVersionAtPhase0);
            return;
        }

        (bool ok, uint256 mask, uint256 globalVersion) = _livePhusdMinterMask();
        if (!ok) {
            // Not fatal here on purpose: bricking a live cutover over a verification nicety
            // would be a worse outcome than the gap it closes. The verifier treats an absent
            // baseline as a loud failure, so the gap cannot pass silently either.
            console.log("WARNING: phUSD exposes no readable minter set - mint-authority baseline NOT recorded.");
            console.log("         VerifyPromotionReady will FAIL on the missing baseline; verify line 1195 by hand.");
            return;
        }
        phusdMinterMaskAtPhase0 = mask;
        phusdMintVersionAtPhase0 = globalVersion;
        phusdMinterBaselineRecorded = true;
        console.log("--- phUSD mint-authority baseline (live) ---");
        console.log("  membership mask:", mask);
        console.log("  mintVersion:    ", globalVersion);
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
    //  PHASE 4e — PhlimboV3 cutover and V2 user-base migration (story 076)
    // =====================================================================

    /// @dev THE STEP STORY 072 NEVER CONTEMPLATED. Its Phase 5 pointed the fresh accumulator
    ///      straight back at PhlimboV2, leaving a "promotion-ready" stack wired to a Phlimbo
    ///      with no promotional-reward machinery at all.
    ///
    ///      ORDER IS LOAD-BEARING. Read this before reordering anything:
    ///
    ///        1..5  Deploy and arm V3 (APY, pauser, phUSD mint grant) BEFORE the migrator
    ///              exists, so a half-armed V3 can never receive a position.
    ///        6..7  Deploy MigratorV2V3 and set it on BOTH sides. A HALF-MET PAIR SILENTLY
    ///              SKIPS EVERY USER (`MigratorV2V3.sol:46-53`) — the pass completes, the
    ///              events all read `Error("Not authorized")`, and nothing reverts.
    ///        8..9  Seed and walk the pass in chunks, reseeding for stragglers.
    ///        10    Conservation, against the WRITE-ONCE Phase 0 baseline.
    ///        11    Wind V2 down: `setDesiredAPY(0)` x2. MUST precede step 14.
    ///        12    Revoke V2's migrator role.
    ///        13    THE COMPLETENESS GATE: `totalStaked() == 0`. MUST precede step 14.
    ///        14    Revoke V2's phUSD mint authority. Safe ONLY after 11 and 13 — see the
    ///              file header's amended `setMinter` section for the freeze-the-principal
    ///              failure this ordering avoids.
    ///
    ///      NOT DONE ANYWHERE IN HERE, both deliberate and both asserted in Phase 7:
    ///        * NO `phlimboV2.pause()`. Pausing breaks the migration while APPEARING to
    ///          succeed. This is the inverse of Phase 6. See the file header.
    ///        * NO `phlimboV3.startPromotion(...)`. `promoToken == address(0)` is a designed
    ///          state; arming a promotion mid-Ledger-session would commit live funds to a
    ///          running depletion clock for no benefit.
    ///
    ///      Every step is `_isConfigured`-gated on its own key, so a resumed leg is
    ///      idempotent and never re-runs a landed transaction.
    function _phase4e_phlimboV3Cutover() internal {
        console.log("\n=== Phase 4e: PhlimboV3 cutover + V2 migration (story 076) ===");
        _requirePhlimboV2BitIndex();

        IPhlimboV2Like v2 = IPhlimboV2Like(PHLIMBO_V2);

        // ---- 1. Deploy PhlimboV3, mirroring V2's live config. ----
        // `depletionDuration` and `rewardToken` are read LIVE off V2 rather than hardcoded,
        // matching `_mirrorTokenConfig`/`_mirrorStrategy`'s house style: a retune on V2
        // between planning and broadcast must carry over, not be silently reverted.
        if (_isDeployed("PhlimboV3")) {
            newPhlimboV3 = deployments["PhlimboV3"].addr;
            console.log("  PhlimboV3 already deployed at:", newPhlimboV3);
        } else {
            address v2Reward = address(v2.rewardToken());
            uint256 v2Duration = v2.depletionDuration();
            // Constructor-set, so no separate `setDepletionDuration` call is needed (and a
            // second call would only re-emit and recompute an identical rate).
            require(v2Duration > 0, "PhlimboV3 ctor requires depletionDuration > 0");
            uint256 g = gasleft();
            PhlimboV3 v3 = new PhlimboV3(PHUSD, v2Reward, v2Duration);
            newPhlimboV3 = address(v3);
            _trackDeployment("PhlimboV3", newPhlimboV3, g - gasleft());
            console.log("  PhlimboV3 deployed at:", newPhlimboV3);
            console.log("    phUSD / rewardToken / depletionDuration:", PHUSD, v2Reward, v2Duration);
        }
        require(IOwnable(newPhlimboV3).owner() == OWNER, "PhlimboV3 owner != OWNER (msg.sender was not the Ledger key)");
        // A fresh V3 must arrive with no promotion armed and no roles set. Asserting it here
        // rather than only in Phase 7 catches a wrong-address resume immediately.
        require(PhlimboV3(newPhlimboV3).promoToken() == IERC20(address(0)), "PhlimboV3 arrived with a promo token set");

        // ---- 2/3. Mirror V2's APY. TWO-STEP preview -> commit. ----
        if (!_isConfigured("p4e_v3_apy")) {
            uint256 targetBps = v2.desiredAPYBps();
            _setDesiredAPYTwoStep(newPhlimboV3, targetBps, "PhlimboV3");
            _trackConfig("p4e_v3_apy");
        }

        // ---- 4. Pauser wiring, both directions. ----
        if (!_isConfigured("p4e_v3_pauser")) {
            PhlimboV3(newPhlimboV3).setPauser(PAUSER);
            Pauser(PAUSER).register(newPhlimboV3);
            _trackConfig("p4e_v3_pauser");
            console.log("  PhlimboV3 pauser set + registered with the global Pauser");
        }

        // ---- 5. THE INVARIANT-BREAKING CALL. ----
        // Story 072's header claimed "ZERO phUSD.setMinter calls in this entire script" and
        // that mint authority was byte-identical BY CONSTRUCTION. Story 076 makes that false
        // on purpose: PhlimboV3 mints the phUSD reward leg (`PhlimboV3.sol:913`), so it MUST
        // hold mint authority. The claim is now an asserted two-sided DELTA, not invariance —
        // see the amended header section and Phase 7.
        //
        // THE FAILURE THIS PREVENTS IS SILENT. V3 pays that leg with
        // `try phUSD.mint(beneficiary, amount) {} catch { ...bank... }` (audit-09 M-01). If
        // the grant were forgotten NOTHING would revert: every staker would silently accrue
        // an unpayable phUSD entitlement while the stable leg kept paying, surfacing only as
        // user complaints. Hence the POSITIVE Phase 7 assertion.
        if (!_isConfigured("p4e_v3_mintGrant")) {
            IFlaxAdmin(PHUSD).setMinter(newPhlimboV3, true);
            _trackConfig("p4e_v3_mintGrant");
            console.log("  phUSD.setMinter(PhlimboV3, true) - mint authority GRANTED");
        }

        // ---- 6. Deploy MigratorV2V3. ----
        // NO phUSD mint role goes to the migrator, unlike its V1->V2 predecessor: V2 itself
        // mints the pending phUSD rewards during `withdraw` (`MigratorV2V3.sol:54-56`).
        if (_isDeployed("MigratorV2V3")) {
            migratorV2V3 = deployments["MigratorV2V3"].addr;
            console.log("  MigratorV2V3 already deployed at:", migratorV2V3);
        } else {
            uint256 g = gasleft();
            MigratorV2V3 m = new MigratorV2V3(PHLIMBO_V2, newPhlimboV3, PHUSD, address(v2.rewardToken()));
            migratorV2V3 = address(m);
            _trackDeployment("MigratorV2V3", migratorV2V3, g - gasleft());
            console.log("  MigratorV2V3 deployed at:", migratorV2V3);
        }
        require(IOwnable(migratorV2V3).owner() == OWNER, "MigratorV2V3 owner != OWNER");

        // ---- 7. BOTH sides of the migrator pair. A half-met pair skips every user. ----
        if (!_isConfigured("p4e_setMigrator")) {
            v2.setMigrator(migratorV2V3);
            PhlimboV3(newPhlimboV3).setMigrator(migratorV2V3);
            // Read both back immediately: this is the single wiring mistake that produces a
            // pass which completes successfully with nothing migrated.
            require(v2.migrator() == migratorV2V3, "PhlimboV2.setMigrator did not land");
            require(PhlimboV3(newPhlimboV3).migrator() == migratorV2V3, "PhlimboV3.setMigrator did not land");
            _trackConfig("p4e_setMigrator");
            console.log("  migrator role set on BOTH V2 and V3, both read back");
        }

        // ---- 8/9/10. Seed, migrate, conserve. ----
        if (!_isConfigured("p4e_migrate")) {
            // The migration cannot run against a paused V2, and would not fail loudly if it
            // did. Checked here (rather than Phase 0) so a resume leg that has already
            // completed the migration is not blocked by a V2 paused afterwards.
            require(
                !v2.paused(),
                "PhlimboV2 is PAUSED - its withdraw is whenNotPaused, so the migrator cannot act and every user would be SKIPPED by a pass that still reports success. Unpause V2; do NOT pause it for this migration (MigratorV2V3.sol:22-24)"
            );
            _runV2ToV3Migration();
            _trackConfig("p4e_migrate");
        }

        // ---- 11. Wind V2 down. NOT a pause. TWO-STEP, like every APY set. ----
        if (!_isConfigured("p4e_v2_apyZero")) {
            _setDesiredAPYTwoStep(PHLIMBO_V2, 0, "PhlimboV2");
            _trackConfig("p4e_v2_apyZero");
        }

        // ---- 12. Revoke the migrator role now the pass is done. ----
        if (!_isConfigured("p4e_v2_revokeMigrator")) {
            v2.setMigrator(address(0));
            require(v2.migrator() == address(0), "PhlimboV2 migrator revoke did not land");
            _trackConfig("p4e_v2_revokeMigrator");
            console.log("  PhlimboV2.setMigrator(0) - migrator role revoked");
        }

        // ---- 13. THE COMPLETENESS GATE. ----
        // Owner decision (2026-08-03): a complete migration of the user base is the mark of a
        // successful cutover; there should be no stragglers. An incomplete migration FAILS
        // the cutover here, loudly — it is never downgraded to a skip-the-revoke branch.
        //
        // The tension is real and deliberate: `migrate` skips sub-MINIMUM_STAKE dust and any
        // reverting position, so a residual non-zero totalStaked is a POSSIBLE outcome. That
        // is a genuine finding about the live user base and is the owner's call, not the
        // executor's. `_runV2ToV3Migration` has already printed the decoded skip reasons.
        require(
            v2.totalStaked() == 0,
            "PHASE 4e INCOMPLETE: PhlimboV2 still holds stake after the migration passes. The decoded UserMigrationSkipped reasons are printed above - an empty reason is sub-MINIMUM_STAKE dust, a non-empty one is revert data. STOP and report; do NOT relax this gate"
        );
        console.log("  completeness gate: PhlimboV2.totalStaked() == 0");

        // ---- 14. Revoke V2's phUSD mint authority. AFTER 11 and AFTER 13, never before. ----
        // Safe only because of those two: with totalStaked == 0 there is no position whose
        // `_claimRewards` could reach the bare, REVERTING `phUSD.mint` at PhlimboV2.sol:495
        // (it early-returns on `amount == 0`), and with desiredAPYBps == 0 the emission rate
        // is 0 so a user who stakes into V2 after the cutover accrues zero pending phUSD and
        // can still exit cleanly. The revoke does not trap late arrivals.
        if (!_isConfigured("p4e_v2_mintRevoke")) {
            IFlaxAdmin(PHUSD).setMinter(PHLIMBO_V2, false);
            _trackConfig("p4e_v2_mintRevoke");
            console.log("  phUSD.setMinter(PhlimboV2, false) - mint authority REVOKED");
        }

        console.log("  Phase 4e complete. V2 wound down and mint-revoked; NOT paused. No promotion armed.");
    }

    /// @dev `setDesiredAPY` is a two-step preview->commit on BOTH V2 and V3
    ///      (`PhlimboV3.sol:261-280`, `PhlimboV2.sol:171-189`): the first call only emits
    ///      `IntendedSetAPY` and records `pendingAPYBps`/`pendingAPYBlockNumber`; the value
    ///      commits only on a SECOND call with the IDENTICAL bps within 100 blocks. A script
    ///      that calls it once has silently done nothing.
    ///
    ///      The read-back is the point. Under a `--slow` Ledger broadcast the two calls are
    ///      separate transactions in separate blocks; 100 blocks is generous but not
    ///      infinite, and a missed commit must fail the cutover rather than leave a Phlimbo
    ///      emitting at the wrong rate.
    ///
    ///      THE VALUE READ-BACK ALONE IS NOT ENOUGH, and this bit is easy to get wrong. When
    ///      `bps == 0` — which is BOTH real cases here, since PhlimboV2's live `desiredAPYBps`
    ///      currently reads 0 and the V2 wind-down targets 0 — `desiredAPYBps() == 0` is
    ///      trivially true on a fresh V3 and on a V2 that never moved, so it would pass even
    ///      if the commit never ran and the contract were left latched mid-preview. The
    ///      `apySetInProgress` check is what makes this non-vacuous: the preview SETS that
    ///      latch and only the commit branch clears it (`PhlimboV3.sol:261-280`).
    function _setDesiredAPYTwoStep(address phlimbo, uint256 bps, string memory label) internal {
        IPhlimboAPYLike p = IPhlimboAPYLike(phlimbo);
        p.setDesiredAPY(bps); // preview  -> apySetInProgress = true
        p.setDesiredAPY(bps); // commit   -> apySetInProgress = false
        require(
            p.desiredAPYBps() == bps,
            string.concat(label, ": setDesiredAPY did not COMMIT - the two-step preview/commit window was missed")
        );
        require(
            !p.apySetInProgress(),
            string.concat(
                label,
                ": setDesiredAPY is still latched mid-preview - the second (commit) call did not take the commit branch. This is the failure a zero-valued read-back cannot see"
            )
        );
        console.log(string.concat("  ", label, " desiredAPYBps committed:"), bps);
    }

    /// @dev Seeds and walks the migration, reseeding for stragglers until the completeness
    ///      gate can be satisfied or the pass budget is exhausted.
    ///
    ///      WHY EVENTS ARE READ AND NOT JUST THE CURSOR. `migrate` completes even when wholly
    ///      misconfigured: an unwired `setMigrator` or a paused Phlimbo yields a pass full of
    ///      skips whose reasons decode to `Error(string)`, with `migrateIterator == -1` and no
    ///      revert anywhere (`MigratorV2V3.sol:68-73`). The migrator's own docs are explicit
    ///      that "the owner MUST read the UserMigrationSkipped events after every pass before
    ///      trusting it". The cursor alone proves nothing.
    function _runV2ToV3Migration() internal {
        IPhlimboV2Like v2 = IPhlimboV2Like(PHLIMBO_V2);
        MigratorV2V3 migrator = MigratorV2V3(migratorV2V3);
        address[] memory users = _loadV2SnapshotUsers();

        uint256 migrateCalls;
        uint256 totalSkips;

        for (uint256 pass = 0; pass < MAX_MIGRATION_PASSES; pass++) {
            if (v2.totalStaked() == 0) break;

            // Reseedable ONLY between passes: `!seeded || migrateIterator == -1`
            // (`MigratorV2V3.sol:145`). Reseeding replaces the list wholesale and resets the
            // cursor, so a user who exited in the meantime simply reads `amount == 0` and is
            // skipped for free on the re-walk.
            migrator.seedUsers(users);
            require(migrator.userCount() == users.length, "seedUsers landed a different user count than the snapshot");
            console.log("  pass seeded with users:", users.length);

            vm.recordLogs();
            while (migrator.migrateIterator() >= 0) {
                require(migrateCalls < MAX_MIGRATE_CALLS, "MAX_MIGRATE_CALLS exhausted - the migration is not converging; investigate before re-running");
                migrator.migrate(MIGRATE_CHUNK);
                migrateCalls++;
            }
            totalSkips += _reportMigrationSkips();

            console.log("  pass complete. V2 totalStaked now:", v2.totalStaked());
            console.log("             V3 totalStaked now:    ", PhlimboV3(newPhlimboV3).totalStaked());
        }

        console.log("  migrate() calls:", migrateCalls);
        console.log("  total UserMigrationSkipped events:", totalSkips);

        // ---- Conservation, against the WRITE-ONCE Phase 0 baseline. ----
        // Never against a live re-read of a V2 the gate has by then emptied — that is the
        // identical defect class story 074 remediated for the BPT position (audit L-02).
        //
        // `>=` rather than `==` because V3 legitimately accumulates more than the baseline:
        // a user may stake into V3 directly between the baseline read and this assertion,
        // and a straggler who staked into V2 mid-pass is migrated on top. It can never
        // legitimately hold LESS, which is the direction that would mean value went missing.
        uint256 v3Staked = PhlimboV3(newPhlimboV3).totalStaked();
        require(
            v3Staked >= phlimboV2StakedAtCutover,
            "CONSERVATION FAILED: PhlimboV3.totalStaked is below the pre-migration PhlimboV2 baseline - stake went somewhere other than V3"
        );
        console.log("  conservation OK. baseline / V3 totalStaked:", phlimboV2StakedAtCutover, v3Staked);
    }

    /// @dev Decodes and logs every `UserMigrationSkipped` emitted by the migrator during the
    ///      pass just walked, distinguishing the two very different meanings of `reason`:
    ///        * EMPTY   -> nothing was attempted; the live position was below V3's
    ///                     MINIMUM_STAKE and `stake` would have rejected it (audit-08 M-02
    ///                     vector 1a). The position stays in V2 and stays the user's.
    ///        * NON-EMPTY -> the whole iteration reverted atomically; `reason` is the raw
    ///                     ABI-encoded revert data. `Error(string)` here almost always means
    ///                     MISCONFIGURATION ("Not authorized" = a missing setMigrator,
    ///                     "Pausable: paused" = someone paused V2), not a bad position.
    /// @return skipCount how many skip events this pass produced.
    function _reportMigrationSkips() internal returns (uint256 skipCount) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("UserMigrationSkipped(address,uint256,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != migratorV2V3) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic) continue;
            skipCount++;
            address user = address(uint160(uint256(logs[i].topics[1])));
            (uint256 amount, bytes memory reason) = abi.decode(logs[i].data, (uint256, bytes));
            if (reason.length == 0) {
                console.log("  SKIP (dust, nothing attempted):", user, amount);
            } else {
                console.log("  SKIP (REVERTED, decode the reason):", user, amount);
                console.logBytes(reason);
            }
        }
        if (skipCount > 0) {
            console.log("  *** THIS PASS SKIPPED", skipCount, "USER(S). A non-zero skip count is never routine. ***");
            console.log("  *** Non-empty reasons are usually MISCONFIGURATION, not bad positions. ***");
        } else {
            console.log("  no UserMigrationSkipped events this pass");
        }
    }

    /// @dev Address list only — `MigratorV2V3` reads every position live, so there is nothing
    ///      else worth seeding. Phase 0 has already validated the file's target, block and age.
    function _loadV2SnapshotUsers() internal view returns (address[] memory users) {
        string memory json = vm.readFile(SNAPSHOT_V2_FILE);
        users = vm.parseJsonAddressArray(json, ".users");
    }

    // =====================================================================
    //  PHASE 4f — deposit-page cutover onto DepositPageViewV3 (story 078)
    // =====================================================================

    /// @dev THE READ SIDE OF PHASE 4e. Phase 4e moved every position and the yield funnel onto
    ///      PhlimboV3 but left the UI resolving the deposit page through a view that has never
    ///      once been repointed:
    ///
    ///        ViewRouter                            0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a
    ///        ViewRouter.pages(keccak256("deposit")) -> DepositPageView 0x50D4...03b8, still
    ///                                                 baked to PhlimboEA (V1)
    ///        DepositView 0x0725...5251              -> PhlimboV2, but NOT the routed one
    ///
    ///      `RewireSYAToPhlimboV2.s.sol:45-50` records the V1->V2 decision that produced that
    ///      inversion: `DepositPageView` was judged deprecated and deliberately not redeployed,
    ///      while the one actually MARKED deprecated, `DepositView`, was. The only
    ///      `setPage("deposit")` anywhere in
    ///      this repo is the local `DeployMocks.s.sol:1278`. THIS PHASE IS THE FIRST TIME THE
    ///      MAINNET DEPOSIT PAGE IS REPOINTED.
    ///
    ///      ORDER IS LOAD-BEARING, in two directions:
    ///
    ///        * AFTER Phase 4e. `DepositPageViewV3.phlimbo` is IMMUTABLE, so the view cannot be
    ///          constructed before the PhlimboV3 it must name exists.
    ///        * `setPage` LAST, after 4e's migration completed and V2 was wound down. Repointing
    ///          earlier would show every not-yet-migrated user a zero-balance V3 page — a
    ///          "your deposit vanished" screen, mid-Ledger-session, with no way to hurry it.
    ///        * BEFORE Phase 5. Registering a page is a pure read-side change with no bearing on
    ///          the accumulator rewiring, so keeping it adjacent to 4e keeps the cutover's write
    ///          and read legs together and lets Phase 7 read in narrative order.
    ///
    ///      Deliberately NOT done: no address-book key is minted for the new view. Its address is
    ///      published on-chain by `ViewRouter.pages(DEPOSIT_KEY)` and recorded in the progress
    ///      file by `_trackDeployment`. A hand-maintained key would recreate exactly the
    ///      dual-resolution ambiguity that let the V1/V2 inversion above go unnoticed for months.
    ///
    ///      Both mutating steps are `_isConfigured`/`_isDeployed`-gated, so a resumed leg neither
    ///      redeploys the view nor re-sends a `setPage` that already landed.
    function _phase4f_depositViewCutover() internal {
        console.log("\n=== Phase 4f: deposit-page cutover -> DepositPageViewV3 (story 078) ===");

        require(newPhlimboV3 != address(0), "Phase 4f reached with no PhlimboV3 - Phase 4e must run first");

        // ---- 1. Owner precheck. Without it the broadcast reverts deep inside the phase with an
        //         opaque `OwnableUnauthorizedAccount`. Mirrors DeployMainnetMintPageView.s.sol:66.
        require(
            IViewRouterLike(VIEW_ROUTER).owner() == OWNER, "ViewRouter.owner != OWNER (setPage would revert)"
        );

        // ---- 2. Record what is about to be displaced, so the broadcast log carries it. ----
        address incumbent = IViewRouterLike(VIEW_ROUTER).pages(DEPOSIT_KEY);
        console.log("  ViewRouter 'deposit' page currently:", incumbent);

        // ---- 3. Deploy the V3-native view. ----
        if (_isDeployed("DepositPageViewV3")) {
            newDepositPageViewV3 = deployments["DepositPageViewV3"].addr;
            console.log("  DepositPageViewV3 already deployed at:", newDepositPageViewV3);
        } else {
            uint256 g = gasleft();
            DepositPageViewV3 view_ = new DepositPageViewV3(IPhlimboV3(newPhlimboV3), IERC20(PHUSD));
            newDepositPageViewV3 = address(view_);
            _trackDeployment("DepositPageViewV3", newDepositPageViewV3, g - gasleft());
            console.log("  DepositPageViewV3 deployed at:", newDepositPageViewV3);
        }

        // Constructor-arg read-back. Both members are immutable, so a mismatch here is
        // unrecoverable-in-place and must abort before the router is repointed at it.
        require(
            address(DepositPageViewV3(newDepositPageViewV3).phlimbo()) == newPhlimboV3,
            "DepositPageViewV3.phlimbo != new PhlimboV3"
        );
        require(
            address(DepositPageViewV3(newDepositPageViewV3).phUSD()) == PHUSD, "DepositPageViewV3.phUSD != phUSD"
        );

        // ---- 4. LAST STEP OF THE PHASE: repoint the router. ----
        if (_isConfigured("viewRouter_setPage_deposit")) {
            console.log("  viewRouter_setPage_deposit already applied (resumed leg)");
        } else {
            IViewRouterLike(VIEW_ROUTER).setPage(DEPOSIT_KEY, IPageView(newDepositPageViewV3));
            _trackConfig("viewRouter_setPage_deposit");
            console.log("  ViewRouter.setPage('deposit') -> DepositPageViewV3");
        }

        require(
            IViewRouterLike(VIEW_ROUTER).pages(DEPOSIT_KEY) == newDepositPageViewV3,
            "ViewRouter 'deposit' page did not repoint"
        );
        console.log("  displaced:", incumbent, "->", newDepositPageViewV3);
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
            // STORY 076 — THE CORE OF THE FIX. This used to read `old.phlimbo()`, which
            // resolves to PHLIMBO_V2: story 072 deployed a brand-new accumulator and pointed
            // it straight back at the Phlimbo with no promotional-reward machinery, which is
            // the blindspot story 076 exists to close. Phase 4e has already deployed and
            // fully migrated PhlimboV3 by the time we get here, so it can be named directly
            // rather than mirroring V2 and correcting afterwards. This one line is what
            // actually stops the yield funnel feeding V2.
            require(newPhlimboV3 != address(0), "Phase 5 reached with no PhlimboV3 - Phase 4e must run first");
            sya.setPhlimbo(newPhlimboV3);
            // MUST STAY AFTER `setPhlimbo`: `approvePhlimbo` approves whichever phlimbo is
            // CURRENTLY set (`RewireSYAToPhlimboV2.s.sol:27`). Reversing these two would
            // approve the old target and leave the new one unable to pull.
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

        _phase7_phlimboV3Assertions();
        _phase7_depositViewAssertions();

        console.log("Phase 7: ALL WIRING ASSERTIONS PASS");
    }

    /// @dev Story 078's half of Phase 7. `view` for the same reason as the block above:
    ///      `VerifyPromotionReady` re-runs the entire phase against LIVE post-broadcast state by
    ///      inheritance alone, so nothing here may mutate or reach for a cheatcode.
    ///
    ///      The second assertion is THE ONE THAT MATTERS. `pages("deposit") == theNewView` alone
    ///      would have passed happily throughout the V1->V2 era — the router pointed at a view,
    ///      just not at one wired to the live Phlimbo. Asserting the view's immutable `phlimbo`
    ///      equals the PhlimboV3 Phase 4e deployed is what actually closes that hole.
    ///
    ///      The round-trips go THROUGH the router, not directly at the view, because the router is
    ///      the only sanctioned resolution path after this story — testing the direct call would
    ///      verify a path no consumer is supposed to take.
    function _phase7_depositViewAssertions() internal view {
        require(newDepositPageViewV3 != address(0), "Phase 7: no DepositPageViewV3 address resolved");
        require(newPhlimboV3 != address(0), "Phase 7: no PhlimboV3 address resolved");

        require(
            IViewRouterLike(VIEW_ROUTER).pages(DEPOSIT_KEY) == newDepositPageViewV3,
            "ViewRouter 'deposit' page != DepositPageViewV3 - the deposit page still resolves to the old view"
        );

        DepositPageViewV3 v = DepositPageViewV3(newDepositPageViewV3);
        require(
            address(v.phlimbo()) == newPhlimboV3,
            "DepositPageViewV3.phlimbo != PhlimboV3 - the deposit page reads a Phlimbo the protocol no longer uses"
        );
        require(address(v.phUSD()) == PHUSD, "DepositPageViewV3.phUSD != phUSD");

        // Exactly 23, not `>= 23`. Story 077 declares the array append-only, so a changed count is
        // drift worth failing on; bumping one integer is a trivial cost when the layout is
        // intentionally extended.
        require(
            IViewRouterLike(VIEW_ROUTER).getNames(DEPOSIT_KEY).length == 23,
            "router getNames('deposit').length != 23"
        );
        require(
            IViewRouterLike(VIEW_ROUTER).getData(DEPOSIT_KEY, OWNER).length == 23,
            "router getData('deposit').length != 23"
        );

        console.log("  deposit page: router repointed to DepositPageViewV3, bound to PhlimboV3, 23 fields round-trip");
    }

    /// @dev Story 076's half of Phase 7. Every assertion here is `view`, which is what lets
    ///      `VerifyPromotionReady` re-run the whole set against LIVE post-broadcast state by
    ///      inheritance alone — see that file's header. Nothing in here may mutate or need a
    ///      cheatcode.
    function _phase7_phlimboV3Assertions() internal view {
        require(newPhlimboV3 != address(0), "Phase 7: no PhlimboV3 address resolved");
        require(migratorV2V3 != address(0), "Phase 7: no MigratorV2V3 address resolved");

        PhlimboV3 v3 = PhlimboV3(newPhlimboV3);
        IPhlimboV2Like v2 = IPhlimboV2Like(PHLIMBO_V2);
        MigratorV2V3 migrator = MigratorV2V3(migratorV2V3);

        // ---- V3 identity and roles. ----
        require(IOwnable(newPhlimboV3).owner() == OWNER, "PhlimboV3.owner != OWNER");
        require(v3.pauser() == PAUSER, "PhlimboV3.pauser != the global Pauser");
        require(Pauser(PAUSER).isRegistered(newPhlimboV3), "PhlimboV3 not registered with Pauser");
        require(address(v3.phUSD()) == PHUSD, "PhlimboV3.phUSD != phUSD");
        require(address(v3.rewardToken()) == address(v2.rewardToken()), "PhlimboV3.rewardToken != V2's");
        require(v3.depletionDuration() > 0, "PhlimboV3.depletionDuration is 0");

        // ---- THE SILENT-FAILURE GUARD, asserted POSITIVELY. ----
        // `PhlimboV3._claimRewards` banks a failed phUSD mint instead of reverting
        // (`:913`, audit-09 M-01), so a forgotten grant produces no error anywhere — every
        // staker just silently accrues an unpayable entitlement. Nothing else in this script
        // would catch it.
        (bool okV3, bool v3CanMint, uint256 v3Version) = _readPhusdMinter(newPhlimboV3);
        require(okV3, "phUSD minter read failed for PhlimboV3");
        require(
            v3CanMint && v3Version == IFlaxAdmin(PHUSD).mintVersion(),
            "PhlimboV3 does NOT hold phUSD mint authority - its reward mints will silently bank as unpayable instead of reverting"
        );

        // ---- The no-promotion negative. ----
        // A promotion is a separate, later, deliberate owner action with its own funding and
        // its own depletion clock. This script must never have armed one.
        require(v3.promoToken() == IERC20(address(0)), "PhlimboV3 has a promo token set - this cutover arms NO promotion");
        require(uint256(v3.promoPhase()) == 0, "PhlimboV3.promoPhase != None - this cutover arms NO promotion");

        // ---- Migrator, both sides, at their post-pass values. ----
        require(v3.migrator() == migratorV2V3, "PhlimboV3.migrator != MigratorV2V3");
        require(v2.migrator() == address(0), "PhlimboV2.migrator was not revoked after the pass");
        require(migrator.seeded(), "MigratorV2V3 was never seeded");
        require(migrator.migrateIterator() == -1, "MigratorV2V3 pass did not complete (migrateIterator != -1)");
        require(address(migrator.phlimboV2()) == PHLIMBO_V2, "MigratorV2V3.phlimboV2 wrong");
        require(address(migrator.phlimboV3()) == newPhlimboV3, "MigratorV2V3.phlimboV3 wrong");

        // ---- V2 wound down, NOT paused. ----
        require(v2.desiredAPYBps() == 0, "PhlimboV2.desiredAPYBps != 0 - the wind-down did not commit");
        require(v2.totalStaked() == 0, "PhlimboV2 still holds stake - the migration was incomplete");
        (bool okV2, bool v2CanMint, uint256 v2Version) = _readPhusdMinter(PHLIMBO_V2);
        require(okV2, "phUSD minter read failed for PhlimboV2");
        require(
            !v2CanMint || v2Version != IFlaxAdmin(PHUSD).mintVersion(),
            "PhlimboV2 still holds phUSD mint authority - the revoke did not land"
        );

        // ---- Conservation, against the write-once baseline (never a live re-read). ----
        require(
            v3.totalStaked() >= phlimboV2StakedAtCutover,
            "PhlimboV3.totalStaked is below the pre-migration PhlimboV2 baseline"
        );

        // ---- The accumulator actually points at V3. This is the whole point of story 076. ----
        require(ISYALike(newSYA).phlimbo() == newPhlimboV3, "new SYA.phlimbo != PhlimboV3 - the yield funnel still feeds V2");
        // The allowance is on the SYA's REWARD TOKEN (USDC), not on phUSD:
        // `approvePhlimbo` approves `rewardToken` (`StableYieldAccumulator.sol:473`) and
        // `Phlimbo.collectReward` pulls exactly that with `rewardToken.safeTransferFrom`.
        // Reading it off the SYA rather than off a constant keeps this honest if the
        // accumulator's reward token is ever retuned.
        address syaReward = ISYALike(newSYA).rewardToken();
        require(
            IERC20(syaReward).allowance(newSYA, newPhlimboV3) > 0,
            "new SYA has no rewardToken allowance for PhlimboV3 - collectReward pulls via transferFrom and would revert"
        );
        // And the two sides must agree on WHICH token, or `collectReward` would approve one
        // token and pull another.
        require(
            syaReward == address(PhlimboV3(newPhlimboV3).rewardToken()),
            "new SYA.rewardToken != PhlimboV3.rewardToken - collectReward would approve one token and pull another"
        );

        console.log("  PhlimboV3: owned/paused-registered, MINTS phUSD, no promo armed, SYA repointed");
        console.log("  PhlimboV2: APY 0, totalStaked 0, migrator revoked, mint authority revoked, NOT paused");
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
        _probeDepositPageView();
        _probeDonorPaths();
        _probeBatchMint();
        _probeArrayLengthMismatch();
        _probeBptRecovery();
        _probePhlimboV3StakeClaim();
        _probePhlimboV3Solvency();
    }

    /// @dev STORY 076'S HEADLINE PROBE: a stake -> warp -> claim round trip on PhlimboV3
    ///      proving the phUSD reward leg ACTUALLY PAYS.
    ///
    ///      This exists because that leg cannot fail loudly. `_claimRewards` mints with
    ///      `try phUSD.mint(beneficiary, amount) {} catch { ...bank into unclaimablePhUSDOf... }`
    ///      (`PhlimboV3.sol:913`, audit-09 M-01). Without mint authority the claim STILL
    ///      SUCCEEDS: the user's pending simply lands in the bank instead of their wallet,
    ///      nothing reverts, and the fault surfaces weeks later as user complaints. Phase 7
    ///      asserts the grant exists; this asserts it WORKS end to end.
    ///
    ///      The assertion is therefore two-sided and specific: the wallet balance must rise,
    ///      AND `unclaimablePhUSDOf` must stay at zero. Checking only the first would pass on
    ///      a claim that paid nothing but banked everything.
    ///
    ///      A PROBE APY MAY BE ARMED HERE, AND ONLY HERE. PhlimboV2's live `desiredAPYBps`
    ///      reads 0 today, so Phase 4e faithfully mirrors 0 onto V3 and NOTHING accrues — the
    ///      probe would have nothing to claim and would prove nothing about the mint grant.
    ///      Since Phase 8 is PREVIEW-ONLY fork state (it already deals a million KENDU, warps
    ///      a day and mints NFTs), the probe arms a temporary non-zero APY under the owner
    ///      prank purely to make the reward leg observable. This CANNOT leak into a
    ///      broadcast: `_phase8_previewSmokeTests` is only reachable from the `isPreview`
    ///      branch of `run()`, and it runs strictly AFTER Phase 7's assertions.
    function _probePhlimboV3StakeClaim() internal {
        console.log("--- PhlimboV3 stake -> claim round trip (phUSD mint leg) ---");
        PhlimboV3 v3 = PhlimboV3(newPhlimboV3);
        address staker = address(0xC0FFEE);
        uint256 amount = v3.MINIMUM_STAKE() * 1000;

        // Preview-only: give the pool something to emit, if the mirrored APY is 0.
        if (v3.desiredAPYBps() == 0) {
            console.log("  (preview only) mirrored APY is 0 - arming a probe APY so the reward leg is observable");
            vm.startPrank(OWNER);
            _setDesiredAPYTwoStep(newPhlimboV3, 1000, "PhlimboV3 (PROBE APY, preview only)");
            vm.stopPrank();
        }

        deal(PHUSD, staker, amount);
        vm.startPrank(staker);
        IERC20(PHUSD).approve(newPhlimboV3, amount);
        v3.stake(amount, staker);
        vm.stopPrank();

        // Accrual is `totalStaked * desiredAPYBps / 10000 / SECONDS_PER_YEAR` per second, so
        // a meaningful window is needed before pending is non-dust.
        vm.warp(block.timestamp + 30 days);
        uint256 pending = v3.pendingPhUSD(staker);
        console.log("  pendingPhUSD after 30d:", pending);
        require(pending > 0, "PhlimboV3 accrued NO pending phUSD in 30 days - desiredAPYBps did not commit, or totalStaked is 0");

        uint256 before = IERC20(PHUSD).balanceOf(staker);
        vm.prank(staker);
        v3.claim(staker);
        uint256 paid = IERC20(PHUSD).balanceOf(staker) - before;
        uint256 banked = v3.unclaimablePhUSDOf(staker);
        console.log("  phUSD actually delivered:", paid);
        console.log("  phUSD banked as unclaimable:", banked);
        require(
            banked == 0,
            "PhlimboV3 BANKED the phUSD reward instead of paying it - the mint reverted and was swallowed by the try/catch at PhlimboV3.sol:913. The mint grant is missing or inert"
        );
        require(paid > 0, "PhlimboV3 claim delivered no phUSD despite non-zero pending");
        console.log("  VERDICT: the phUSD mint leg pays - the grant is live, not merely recorded");
    }

    /// @dev `lib/phlimbo-ea/SolvencyDetermination.md` section 1: staked principal is held 1:1
    ///      and is never used to pay any reward stream (phUSD rewards are freshly minted,
    ///      section 2; the stable stream is separately pre-funded, section 3). So the
    ///      post-migration state satisfies solvency iff:
    ///
    ///          phUSD.balanceOf(phlimboV3) >= phlimboV3.totalStaked()
    ///
    ///      That probe is cheap — two live reads — so per the story's Implementation Notes it
    ///      is included here rather than left as prose. The `>=` (not `==`) is deliberate:
    ///      section 3's floor-division dust and forfeited rewards accumulate as a surplus
    ///      favouring the protocol.
    ///
    ///      Section 2's condition — that the contract holds an ACTIVE mint privilege at the
    ///      current `mintVersion` — is asserted in Phase 7 and exercised end to end by
    ///      `_probePhlimboV3StakeClaim`. Section 4 is vacuous here: no promotion is armed.
    function _probePhlimboV3Solvency() internal view {
        console.log("--- PhlimboV3 solvency (SolvencyDetermination.md) ---");
        PhlimboV3 v3 = PhlimboV3(newPhlimboV3);
        uint256 held = IERC20(PHUSD).balanceOf(newPhlimboV3);
        uint256 staked = v3.totalStaked();
        console.log("  phUSD held / totalStaked:", held, staked);
        require(held >= staked, "SOLVENCY (section 1): PhlimboV3 holds less phUSD than totalStaked");
        require(v3.promoToken() == IERC20(address(0)), "SOLVENCY (section 4): a promo stream exists but none was armed");
        console.log("  section 1 principal invariant holds; section 4 vacuous (no promotion armed)");
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

    /// @dev Story 078. The deposit-page sibling of `_probeMintPageView`, and the only place the
    ///      new page's VALUES (rather than just its wiring) are printed for a human to eyeball.
    ///
    ///      Reads THROUGH the router — the sanctioned path, and the one Phase 4f actually
    ///      changed. WARNS RATHER THAN REVERTS, exactly like its sibling: Phase 8 is a preview
    ///      diagnostic, and blowing up the whole preview over an unregistered page would destroy
    ///      the run that was about to explain why. The hard failure lives in Phase 7, which is
    ///      `require`-gated and re-run post-broadcast by `VerifyPromotionReady`.
    function _probeDepositPageView() internal view {
        console.log("--- ViewRouter.getData('deposit') (story 078) ---");

        address page = IViewRouterLike(VIEW_ROUTER).pages(DEPOSIT_KEY);
        if (page == address(0)) {
            console.log("  !! 'deposit' page is UNREGISTERED on the router.");
            console.log("  !! Phase 4f's setPage did not land - the UI would resolve nothing.");
            return;
        }
        console.log("  resolves to:", page);
        if (page != newDepositPageViewV3) {
            console.log("  !! but Phase 4f deployed:", newDepositPageViewV3);
            console.log("  !! the router points at a DIFFERENT view than this run built.");
        }

        (bool okNames, bytes memory retNames) =
            VIEW_ROUTER.staticcall(abi.encodeWithSignature("getNames(bytes32)", DEPOSIT_KEY));
        (bool okData, bytes memory retData) =
            VIEW_ROUTER.staticcall(abi.encodeWithSignature("getData(bytes32,address)", DEPOSIT_KEY, OWNER));

        if (!okNames || !okData) {
            console.log("  !! getNames/getData REVERTED through the router.");
            console.log("  !! DepositPageViewV3 is documented as never-reverting; investigate before broadcasting.");
            return;
        }

        string[] memory names = abi.decode(retNames, (string[]));
        uint256[] memory data = abi.decode(retData, (uint256[]));
        if (names.length != data.length) {
            console.log("  !! names/data length mismatch:", names.length, data.length);
            return;
        }
        if (names.length != 23) {
            console.log("  !! expected 23 fields, got:", names.length);
        }
        for (uint256 i = 0; i < names.length; i++) {
            console.log("  ", names[i], data[i]);
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
        newPhlimboV3 = deployments["PhlimboV3"].addr;
        migratorV2V3 = deployments["MigratorV2V3"].addr;
        // Story 078. Without this line the read-only VerifyPromotionReady — which never runs
        // Phase 4f, the only other place this member is assigned — sees address(0) and aborts
        // in `_requireResolved(newDepositPageViewV3, "DepositPageViewV3")`, taking the whole
        // trailing verify leg of `promotion-ready:broadcast` with it.
        newDepositPageViewV3 = deployments["DepositPageViewV3"].addr;
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
        // Story 075: a SIBLING key inside the same `baselines` object. Independently guarded,
        // so a file carrying only `bptAtCutover` (written before story 075) still parses.
        if (
            vm.keyExistsJson(json, ".baselines.phusdMinterMask")
                && vm.keyExistsJson(json, ".baselines.phusdMintVersion")
        ) {
            phusdMinterMaskAtPhase0 = vm.parseUint(vm.parseJsonString(json, ".baselines.phusdMinterMask"));
            phusdMintVersionAtPhase0 = vm.parseUint(vm.parseJsonString(json, ".baselines.phusdMintVersion"));
            phusdMinterBaselineFromProgressFile = true;
            phusdMinterBaselineRecorded = true;
            console.log("Loaded persisted phUSD minter mask:", phusdMinterMaskAtPhase0);
        }
        // Story 076: a third SIBLING key inside the same `baselines` object, independently
        // guarded so a file written before story 076 still parses. Same trust argument as
        // `bptAtCutover`: it is a READ of pre-existing chain state taken at Phase 0 before
        // this session dispatched anything, so no crash can falsify it.
        if (vm.keyExistsJson(json, ".baselines.phlimboV2StakedAtCutover")) {
            // Decimal STRING for the same reason as bptAtCutover: the Node patcher reads and
            // rewrites this file through JS `JSON.parse`, which cannot round-trip a
            // large-integer literal losslessly.
            phlimboV2StakedAtCutover = vm.parseUint(vm.parseJsonString(json, ".baselines.phlimboV2StakedAtCutover"));
            phlimboBaselineFromProgressFile = true;
            console.log("Loaded persisted PhlimboV2 migration baseline:", phlimboV2StakedAtCutover);
        }
    }

    /// @dev Every key the progress file can carry — deployments first, then the config-step
    ///      flags. Used for both parsing and (implicitly) the write path's ordering.
    function _allProgressKeys() internal pure returns (string[] memory names) {
        // Sized with headroom above the `require(i == 62)` below (story 076 raised the count
        // from 50 to 60, which exactly filled the previous allocation; story 078 added the
        // `DepositPageViewV3` deployment and the `viewRouter_setPage_deposit` flag, 60 -> 62).
        // 70 still leaves 8 free slots. Only `i` entries are ever read — `all` is built from
        // `i + j`, not from this length.
        names = new string[](70);
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
        // Story 076, Phase 4e. `PhlimboV3` is permanent and gets a `mainnet-addresses.ts`
        // key; `MigratorV2V3` is a transient orchestrator and gets none, following story
        // 072's precedent for the three NFTStakerMigrator instances. Both are recorded here
        // regardless, so a resume leg can find them.
        names[i++] = "PhlimboV3";
        names[i++] = "MigratorV2V3";
        // Story 078, Phase 4f. Permanent, but deliberately gets NO `mainnet-addresses.ts` key:
        // `ViewRouter.pages(keccak256("deposit"))` publishes its address on-chain, and this
        // record is how a resume leg finds it. A hand-maintained key would recreate the
        // dual-resolution ambiguity the story exists to remove.
        names[i++] = "DepositPageViewV3";
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
        // Story 076, Phase 4e config-step flags. Order matches the phase body.
        names[i++] = "p4e_v3_apy";
        names[i++] = "p4e_v3_pauser";
        names[i++] = "p4e_v3_mintGrant";
        names[i++] = "p4e_setMigrator";
        names[i++] = "p4e_migrate";
        names[i++] = "p4e_v2_apyZero";
        names[i++] = "p4e_v2_revokeMigrator";
        names[i++] = "p4e_v2_mintRevoke";
        // Story 078, Phase 4f. Its only config step; the deployment record is up with the
        // address-bearing keys above.
        names[i++] = "viewRouter_setPage_deposit";
        // Bumped by story 076: +2 deployment records (PhlimboV3, MigratorV2V3) and +8 Phase
        // 4e config flags. 50 -> 60.
        // Bumped by story 078: +1 deployment record (DepositPageViewV3) and +1 Phase 4f config
        // flag (viewRouter_setPage_deposit). 60 -> 62.
        require(i == 62, "progress key count drifted");
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
        json = string.concat(json, '"baselines": {"bptAtCutover": "', vm.toString(bptAtPhase0), '"');
        // Story 075: appended as a SIBLING key. `bptAtCutover` above is untouched — story 074
        // owns it. Omitted entirely when phUSD's minter set was unreadable, so the verifier
        // fails loudly on the absent baseline instead of asserting against a fabricated 0.
        if (phusdMinterBaselineRecorded) {
            json = string.concat(json, ', "phusdMinterMask": "', vm.toString(phusdMinterMaskAtPhase0), '"');
            json = string.concat(json, ', "phusdMintVersion": "', vm.toString(phusdMintVersionAtPhase0), '"');
        }
        // Story 076: another SIBLING key. `bptAtCutover` and the story-075 pair above are
        // untouched. `phlimboV2StakedAtCutover` is already the monotonic maximum of the
        // persisted and live readings (see `_phase0_phlimboV3Preconditions`), so re-emitting
        // it here can never shrink the recorded baseline. Written whenever it is non-zero:
        // a zero baseline carries no information and Phase 0 rejects it on a fresh leg.
        if (phlimboV2StakedAtCutover > 0) {
            json = string.concat(
                json, ', "phlimboV2StakedAtCutover": "', vm.toString(phlimboV2StakedAtCutover), '"'
            );
        }
        json = string.concat(json, "},");
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
        console.log("PhlimboV3 (story 076):    ", newPhlimboV3);
        console.log("MigratorV2V3 (transient): ", migratorV2V3);
        console.log("-------------------------------------------------");
        console.log("Hooks REPOINTED, not redeployed - addresses unchanged.");
        console.log("phUSD minter-set DELTA (story 076): +PhlimboV3, -PhlimboV2. Nothing else moved.");
        console.log("PhlimboV2 is wound down (APY 0) and mint-revoked, but deliberately NOT PAUSED.");
        console.log("A late V2 staker still exits cleanly: APY 0 means zero pending phUSD accrues.");
        console.log("NO promotion is armed on PhlimboV3 - startPromotion is a separate owner action.");
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

/// @dev Story 076. phUSD's owner-only mint-authority admin surface plus the global version
///      counter. `setMinter` does NOT bump `mintVersion` (`FlaxToken.sol:44-51`) — only
///      `revokeAllMintPrivileges` does (`:88-90`) — which is why the cutover expects the
///      version to be unchanged while the membership mask loses exactly one bit.
interface IFlaxAdmin {
    function setMinter(address minter, bool canMint) external;
    function mintVersion() external view returns (uint256);
}

/// @dev Story 076. PhlimboV2's read/admin surface. Declared locally rather than importing
///      the submodule's own `interfaces/IPhlimboV2.sol` because that interface omits the three
///      Ownable/Pausable members Phase 0 and Phase 7 need (`owner`, `pauser`, `paused`) and
///      declaring the union here keeps every selector this script relies on in one place,
///      matching the house style of the interfaces above.
interface IPhlimboV2Like {
    function phUSD() external view returns (address);
    function rewardToken() external view returns (address);
    function desiredAPYBps() external view returns (uint256);
    function depletionDuration() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function migrator() external view returns (address);
    function pauser() external view returns (address);
    function paused() external view returns (bool);
    function userInfo(address user) external view returns (uint256 amount, uint256 phUSDDebt, uint256 stableDebt);
    function setMigrator(address newMigrator) external;
}

/// @dev Story 078. The live `ViewRouter`'s read/admin surface, declared locally rather than
///      importing `src/views/ViewRouter.sol`, matching `DeployMainnetMintPageView.s.sol:112-116`.
///      The router is deployed, owned by the Ledger key and never redeployed by this script, so
///      pulling its implementation into the script's bytecode would buy nothing.
interface IViewRouterLike {
    function owner() external view returns (address);
    function pages(bytes32 key) external view returns (address);
    function setPage(bytes32 key, IPageView page) external;
    function getNames(bytes32 page) external view returns (string[] memory);
    function getData(bytes32 page, address user) external view returns (uint256[] memory);
}

/// @dev Story 076. The two-step APY setter, identical on V2 and V3, so one helper drives
///      both. See `_setDesiredAPYTwoStep`.
interface IPhlimboAPYLike {
    function setDesiredAPY(uint256 bps) external;
    function desiredAPYBps() external view returns (uint256);
    /// @dev The preview/commit latch. True after a preview, cleared by the commit — which is
    ///      what makes it a non-vacuous proof that the commit branch actually ran, even when
    ///      the target value is 0 and the value read-back proves nothing.
    function apySetInProgress() external view returns (bool);
}
