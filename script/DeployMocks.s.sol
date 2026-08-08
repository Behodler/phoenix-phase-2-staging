// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@forge-std/Script.sol";
import "@forge-std/console.sol";
import "../src/mocks/MockPhUSD.sol";
import "../src/mocks/MockRewardToken.sol";
import "../src/mocks/MockUSDS.sol";
import "../src/mocks/MockUSDe.sol";
import "../src/mocks/MockSUSDe.sol";
import "../src/mocks/MockDola.sol";
import "../src/mocks/MockAutoDOLA.sol";
import "../src/mocks/MockSUSDS.sol";
import "../src/mocks/MockEYE.sol";
import "../src/mocks/MockSCX.sol";
import "../src/mocks/MockKendu.sol";
import "../src/mocks/MockFlax.sol";
import "../src/mocks/MockWBTC.sol";
import "../src/mocks/MockBalancerPool.sol";
import "../src/mocks/MockBalancerVault.sol";
import "../src/mocks/MockERC4626Wrapper.sol";
import "../src/mocks/MockSkyPSM.sol";
import "../src/mocks/MockMarketAMMAdapter.sol";
import "@phlimbo-ea/Phlimbo.sol";
import "@phlimbo-ea/interfaces/IPhlimbo.sol";
// Story 079: the local chain now mirrors mainnet's promotion-ready cutover, so it carries the
// SAME three phlimbo-side contracts that Phase 4e touches. `PhlimboEA` (V1) is no longer
// deployed locally at all — mainnet's incumbent is V2, and a rehearsal that starts from the
// wrong generation rehearses nothing.
import {PhlimboV2} from "@phlimbo-ea/PhlimboV2.sol";
import {PhlimboV3} from "@phlimbo-ea/PhlimboV3.sol";
import {MigratorV2V3} from "@phlimbo-ea/MigratorV2V3.sol";
import {IPhlimboV3} from "@phlimbo-ea/interfaces/IPhlimboV3.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@pauser/Pauser.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "../src/views/DepositView.sol";
import "../src/views/ViewRouter.sol";
import "../src/views/DepositPageView.sol";
import {DepositPageViewV3} from "../src/views/DepositPageViewV3.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
// V1 INFTMinter removed (yield-claim-nft story-039). MintPageView's constructor takes the V2
// interface; alias it the same way the rest of the file expects (INFTMinterView).
import {INFTMinterV2 as INFTMinterView} from "@yield-claim-nft/interfaces/INFTMinterV2.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import "../src/mocks/MockBalancerRouter.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {ITokenMinterV2} from "@yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {BalancerPoolerV2} from "@yield-claim-nft/dispatchers/BalancerPoolerV2.sol";
import {GatherV2} from "@yield-claim-nft/dispatchers/GatherV2.sol";
// Story 070 put NudgeRatchetDelayRelease at index 7 as a stopgap; story 073 retires it and puts
// the streamer-aware NudgeRatchet back in the same slot (same ctor, same index, same hook).
import {NudgeRatchet} from "@yield-claim-nft/dispatchers/NudgeRatchet.sol";
import {NudgeRatchetMintDebtHook} from "@yield-claim-nft/hooks/NudgeRatchetMintDebtHook.sol";
import {BalancerPoolerMintDebtHook} from "@yield-claim-nft/hooks/BalancerPoolerMintDebtHook.sol";
import {IDispatchHook} from "@yield-claim-nft/interfaces/IDispatchHook.sol";
import {IBalancerPoolerMintDebtHook} from "@yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
// Story 070: Uniboost dispatchers (replace the 3 burners at indices 1/2/3) + their hook + staker.
import {Uniboost} from "@yield-claim-nft/dispatchers/Uniboost.sol";
import {UniboostMintDebtHook} from "@yield-claim-nft/hooks/UniboostMintDebtHook.sol";
import {IUniboostMintDebtHook} from "@yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {MultiPooler} from "@yield-claim-nft/MultiPooler.sol";
import {NFTStaker} from "nft-staking/NFTStaker.sol";
import {NFTStakerPriceScaled} from "nft-staking/NFTStakerPriceScaled.sol";
import {NFTStakerDepletion} from "nft-staking/NFTStakerDepletion.sol";
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {INFTSupply} from "nft-staking/INFTSupply.sol";
// Story 073: the streamer-era contract set (mirrors the mainnet cutover planned in story 072).
import {NudgeStreamer} from "nft-staking/NudgeStreamer.sol";
import {BatchNFTMinterMultiToken} from "nft-staking/BatchNFTMinterMultiToken.sol";
import {NFTStakerDepletionV2} from "nft-staking/NFTStakerDepletionV2.sol";
import {NFTStakerMigrator} from "nft-staking/NFTStakerMigrator.sol";
import {INFTStakerMigratable} from "nft-staking/INFTStakerMigratable.sol";
// Story 070: canonical Uniswap V2 (WETH9 + Factory + Router02) deployer + interfaces.
import {
    UniswapV2Deployer,
    IUniswapV2FactoryLike,
    IUniswapV2RouterLike,
    IWETH9Like
} from "./helpers/UniswapV2Deployer.sol";
import {StableStaker} from "stable-staker/StableStaker.sol";
// StableStaker's constructor takes the flax-token-v2 IFlax; alias to avoid an
// identifier clash with phlimbo-ea's IFlax which is already in scope transitively.
import {IFlax as IFlaxStaker} from "flax-token/IFlax.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Story 079. The shared admin surface of `PhlimboV2` and `PhlimboV3`, which are
 *         unrelated Solidity types. Byte-identical to the shim in
 *         `DeployMainnetPromotionReady.s.sol` so the local `_setDesiredAPYTwoStep` and the
 *         mainnet one are the same code operating through the same interface.
 */
interface IPhlimboAPYLike {
    function setDesiredAPY(uint256 bps) external;
    function desiredAPYBps() external view returns (uint256);
    /// @dev The preview/commit latch. True after a preview, cleared by the commit — which is
    ///      what makes it a non-vacuous proof that the commit branch actually ran, even when
    ///      the target value is 0 and the value read-back proves nothing.
    function apySetInProgress() external view returns (bool);
}

/**
 * @title DeployMocks
 * @notice Deployment script for Phase 2 contracts on local Anvil
 * @dev Full architecture matching DeployMainnet pattern:
 *
 * Architecture Overview:
 * - Multiple YieldStrategies (vaults) accumulate yield from different stablecoins
 * - PhusdStableMinter manages stablecoin deposits and phUSD minting
 * - StableYieldAccumulator gathers yield from all strategies and offers to users for discounted USDC
 * - USDC is then injected into Phlimbo for distribution via collectReward()
 * - Phlimbo handles staking and reward distribution
 *
 * Key Integration Points:
 * - StableYieldAccumulator deployment and configuration
 * - Multiple YieldStrategy deployment and registration
 * - USDC holding account setup for the collectReward swap mechanism
 * - Phlimbo contract integration for yield distribution
 */
contract DeployMocks is Script {
    // Mock-vs-mainnet parity constants for nudge feature (story 045.5)
    // - MOCK_NUDGE_SPLIT matches mainnet (story 046)
    // - MOCK_NUDGE_SIZE is lowered from mainnet's 40 for dev ergonomics
    uint256 constant MOCK_NUDGE_SPLIT = 30;
    uint256 constant MOCK_NUDGE_SIZE = 25;
    // Story 045.5 Phase 7 — BalancerPoolerV2 batch-donation phase
    // Percent of sUSDS share balance diverted to the donation phase on each pool() call.
    // Mirrors MOCK_NUDGE_SPLIT for mental-model parity; LP path still receives 70%.
    uint256 constant MOCK_BATCH_DONATION_SIZE = 30;

    // ---- Story 073: NudgeStreamer-era constants ----
    // Local stream window. DELIBERATELY 6 hours, NOT mainnet's 7 days (story 073 user decision):
    // a developer can watch a stream accrue and flush inside one session without vm.warp, while
    // still leaving a seeded buffer non-empty across a working session rather than fully depleting
    // an hour in. Do NOT "fix" this to match mainnet.
    uint256 constant LOCAL_STREAM_DURATION = 6 hours;
    // Seed donations pushed through `collectNudge` at deploy time so the phUSD and Kendu reward
    // slots read non-zero on a fresh local chain. Mainnet has no donor for either token, so both
    // slots are permanently zero there — this is part of the deliberate local divergence, not a
    // prediction of mainnet behaviour. Sized so a 6-hour stream emits a visible amount per block
    // without dwarfing the USDC slot the real donors fund.
    uint256 constant LOCAL_PHUSD_NUDGE_SEED = 5_000 * 10 ** 18; // 5,000 phUSD (18dp)
    uint256 constant LOCAL_KENDU_NUDGE_SEED = 50_000 * 10 ** 18; // 50,000 Kendu (18dp)
    // phUSD budget seeded onto each rehearsal V1 depletion staker before the migration dry-run.
    // Deliberate, non-default: large enough that per-second emission is non-zero over a 12-month
    // window (budget / (12 * 30 days) > 0) so the migration exercises a real, non-trivial accrual.
    uint256 constant REHEARSAL_STAKER_BUDGET = 1_000 * 10 ** 18; // 1,000 phUSD
    // Distinct mock actors whose positions the V1 -> V2 depletion-staker migration rehearsal
    // moves. These are anvil's default accounts #1/#2/#3 — real, distinct addresses so
    // `migrator.migrate(users)` operates on a genuine multi-user list rather than a single
    // self-staked position.
    address constant REHEARSAL_ACTOR_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant REHEARSAL_ACTOR_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant REHEARSAL_ACTOR_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    // ---- Story 079: PhlimboV2 -> PhlimboV3 cutover rehearsal (mirrors mainnet Phase 4e) ----
    //
    // Per-actor stake seeded onto PhlimboV2 before the migration. Deliberate, non-default, and
    // COMFORTABLY ABOVE `PhlimboV3.MINIMUM_STAKE` (1e15): `MigratorV2V3.migrate` skips any live
    // position below that threshold up-front with an EMPTY-reason `UserMigrationSkipped`
    // (MigratorV2V3.sol:194-200). A dust-sized seed would therefore produce a pass that
    // "succeeds" having migrated nobody — precisely the silent failure this rehearsal exists to
    // catch — and would then trip the completeness gate for the wrong reason.
    uint256 constant PHLIMBO_REHEARSAL_STAKE = 100 * 10 ** 18; // 100 phUSD per actor
    // Chunk size for the `migrate` loop. Mainnet chunks because each user costs a V2 withdraw
    // (with reward settlement and a phUSD mint) plus a V3 stake; locally the point is to
    // exercise the CHUNKED path — a cursor that has to advance across more than one call — not
    // to fit a gas ceiling. 2 with 3 actors guarantees at least two passes and a partial chunk.
    uint256 constant PHLIMBO_MIGRATE_CHUNK = 2;
    // Distinct mock actors for the phlimbo migration, deliberately NOT the three
    // `REHEARSAL_ACTOR_*` above: those hold NFT-staker positions from the story-073 rehearsal,
    // and reusing them would let an NFT-side reward transfer be mistaken for a phlimbo-side one
    // when reading the migration's forwarded-reward deltas. Anvil default accounts #4/#5/#6.
    address constant PHLIMBO_ACTOR_1 = 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65;
    address constant PHLIMBO_ACTOR_2 = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc;
    address constant PHLIMBO_ACTOR_3 = 0x976EA74026E726554dB657fA54763abd0C3a0aa9;

    // ---- Story 079: LOCAL-ONLY Kendu promotion armed on PhlimboV3 ----
    //
    // A DELIBERATE DIVERGENCE FROM MAINNET, not a prediction of it. Mainnet's Phase 4e ships the
    // cutover with `promoToken == address(0)` and explicitly does NOT call `startPromotion` —
    // the dormant slot is the designed launch state and arming one is a separate, later,
    // owner-signed decision. The local chain arms one anyway because the promo slot is the
    // single largest piece of NEW UI surface in V3 (fields 13/16/17/18/19 and the three
    // unclaimable banks on `DepositPageViewV3`), and with no promotion running every one of
    // those reads is zero — indistinguishable from a broken binding.
    //
    // Sized to be VISIBLE, not realistic: 10,000 Kendu over 1 day gives a per-second rate large
    // enough that `pendingPromo` moves between UI polls at anvil's 2s block time, and depletes
    // within a working day so the `Active`-with-zero-balance dormant state is also reachable
    // locally without waiting a week.
    uint256 constant LOCAL_PROMO_KENDU_AMOUNT = 10_000 * 10 ** 18; // 10,000 Kendu (18dp)
    uint256 constant LOCAL_PROMO_DURATION = 1 days;

    // ---- Script-audit run-26, L-03 (`pps26l3`): the arming above is now TOGGLEABLE ----
    //
    // The arming block immediately above is admissible and stays exactly as it was — deliberate,
    // argued, and sequenced dead last for a load-bearing reason. The run-26 finding is the
    // INVERSE: because it was unconditional, the DORMANT promo state — the one mainnet actually
    // ships on day one — was the single state this script could never produce, so no local run
    // could ever rehearse it.
    /// @dev LOCAL-ONLY toggle for the Kendu promotion (script-audit run-26, L-03). Default TRUE:
    ///      an unqualified `npm run dev` arms the promotion, because the armed state is the one a
    ///      UI developer needs most of the time (every V3 promo field reads zero when dormant, which
    ///      is indistinguishable from a broken binding). Set LOCAL_PROMO_KENDU=false to boot the
    ///      DORMANT chain instead — the state mainnet actually ships on day one, and the one state
    ///      this script could previously never produce.
    bool internal armKenduPromo;

    // ---- Script-audit run-26, L-01 (`pps26l1`): the index the Phase 7.6 swap rehearsal moves ----
    //
    // Index 1 (`uniboostEYE`). The Uniboost swap is the shape mainnet repeats three times
    // (indices 1/2/3), it is the lowest-blast-radius index on the local chain, and its hook's
    // `scale` is IMMUTABLE, which is what makes the prime-token assertion meaningful. Index 7
    // (`NudgeRatchet`) would additionally exercise the `hookTypeId()` guard and the non-default
    // `DEFAULT_RATIO == 100`, but swapping it means re-wiring `RatchetNFTStaker`,
    // `RatchetBatchNFTMinter`, the nudge streamer and the target APY on the exact chain the UI is
    // about to be tested against. Those two index-7 claims are instead pinned by cheap STATIC
    // assertions at the end of the phase, which regression-gates them without a swap.
    uint256 constant REHEARSAL_SWAP_INDEX = 1;

    // Deployment addresses
    MockPhUSD public phUSD;
    MockRewardToken public rewardToken; // USDC - the consolidated reward token
    MockUSDS public usds; // Underlying USDS stablecoin (plain ERC20)
    MockSUSDS public susds; // ERC4626 savings vault wrapping USDS
    MockUSDe public usde; // Underlying USDe stablecoin (plain ERC20)
    MockSUSDe public susde; // ERC4626 savings vault wrapping USDe
    MockDola public dola;
    MockAutoDOLA public mockAutoDola;
    MockAutoDOLA public mockAutoUSDC; // Reusing MockAutoDOLA pattern for USDC
    ERC4626YieldStrategy public yieldStrategyDola;
    ERC4626YieldStrategy public yieldStrategyUSDC;
    // USDe uses the AMM-market strategy (not the plain 1:1 ERC4626YieldStrategy) to mirror
    // mainnet, where sUSDe is reached via a Curve AMM that imposes slippage on every leg.
    ERC4626MarketYieldStrategy public yieldStrategyUSDe;
    MockMarketAMMAdapter public usdeAmmAdapter;
    PhusdStableMinter public minter;
    // Story 079: the INCUMBENT, tracked under the existing `PhlimboEA` progress key. The key name
    // is mainnet's, not the contract's: on mainnet `PhlimboEA` names the PhlimboV2 address and
    // keeps naming it after the cutover, because V2 survives the cutover wound down (APY 0,
    // mint-revoked) but explicitly NOT paused, so a late staker can still exit. Renaming the key
    // here would desync the local `ContractAddresses` interface from the mainnet one.
    PhlimboV2 public phlimbo;
    // Story 079: the post-cutover farm. This is what the UI stakes into and what SYA feeds.
    PhlimboV3 public phlimboV3;
    MockEYE public eyeToken;
    Pauser public pauser;
    StableYieldAccumulator public stableYieldAccumulator;
    DepositView public depositView;
    ViewRouter public viewRouter;
    DepositPageView public depositPageView;
    // Story 079: the V3-native deposit page. Deliberately KEYLESS — never `_trackDeployment`d —
    // mirroring mainnet, where every page behind `ViewRouter` was stripped of its address key so
    // `pages(keccak256("deposit"))` is the single resolution path (see extract-addresses.js's
    // DROPPED_CONTRACT_NAMES note).
    DepositPageViewV3 public depositPageViewV3;
    MintPageView public mintPageView;

    // NFTMinter infrastructure (V2 only — V1 removed in story 059)
    MockSCX public mockSCX;
    // Story 073: third nudge-reward asset alongside USDC and phUSD on the multi-token batch minter.
    MockKendu public mockKendu;
    MockFlax public mockFlax;
    MockWBTC public mockWBTC;
    MockBalancerPool public mockBalancerPool;
    MockBalancerVault public mockBalancerVault;
    BurnRecorder public burnRecorder;

    // V2 NFTMinter infrastructure
    MockBalancerRouter public mockBalancerRouter;
    NFTMinterV2 public nftMinterV2;
    // Story 070: the three BurnerV2 dispatchers (indices 1/2/3) were replaced with Uniboost
    // dispatchers, each backed by a real UniV2 pool + a UniboostMintDebtHook + an
    // NFTStakerDepletion staker. Indices 1/2/3 are preserved (same registration order).
    Uniboost public uniboostEYE;
    Uniboost public uniboostSCX;
    Uniboost public uniboostFLX;
    UniboostMintDebtHook public uniboostHookEYE;
    UniboostMintDebtHook public uniboostHookSCX;
    UniboostMintDebtHook public uniboostHookFLX;
    // Story 073: the chain now ENDS on NFTStakerDepletionV2. Each of these is the V2 instance the
    // migration rehearsal migrated into; the transient V1 stakers and migrators are deliberately
    // not retained as fields (they are rehearsal artifacts, never tracked, never read by the UI).
    NFTStakerDepletionV2 public uniboostStakerEYE;
    NFTStakerDepletionV2 public uniboostStakerSCX;
    NFTStakerDepletionV2 public uniboostStakerFLX;
    // Story 070: batch forwarder authorized to pool() across all three Uniboost dispatchers. It is
    // the ONLY authorized pooler on each Uniboost (the deployer is deliberately NOT whitelisted).
    MultiPooler public multiPooler;

    // Story 070: canonical Uniswap V2 infrastructure (deployed on anvil 31337) backing the
    // Uniboost target + routing pools. weth9 is the EYE-pool pairing token (no MockWETH exists).
    address public weth9;
    IUniswapV2FactoryLike public uniFactory;
    IUniswapV2RouterLike public uniRouter;
    // Target pools (the pool each Uniboost boosts).
    address public poolEYE; // EYE / WETH9
    address public poolSCX; // SCX / USDS
    address public poolFLX; // FLX / DOLA
    // Routing pools (USDC -> pairToken) so Uniboost.pool()'s prime->pair swap can execute.
    address public routePoolWETH; // USDC / WETH9
    address public routePoolUSDS; // USDC / USDS
    address public routePoolDOLA; // USDC / DOLA

    BalancerPoolerV2 public balancerPoolerV2;
    GatherV2 public gatherWBTCV2;
    // Disabled placeholder occupying dispatcher index 6 to mirror mainnet, where the
    // "bugged" BalancerPoolerV2 (story-047) was appended at index 6 and then permanently
    // disabled by the story-048 cutover. Registering this here pushes NudgeRatchet to
    // index 7, matching the index it will receive on mainnet. Never enabled / never minted.
    BalancerPoolerV2 public buggedPoolerV2Index6;

    // Story 068 — NudgeRatchet dispatcher (6-decimal USDC) + its mint-debt hook.
    // Story 070 — swapped the dispatcher to NudgeRatchetDelayRelease (HOLDS USDC on dispatch,
    // releaser-gated release to batchMinter). Same index 7, same hook, same price/growth.
    // Story 073 — retires the DelayRelease stopgap and restores the streamer-aware NudgeRatchet
    // in the SAME slot (index 7). The variable name is intentionally type-agnostic so the
    // `_trackDeployment("NudgeRatchet", ...)` key stays correct.
    NudgeRatchet public nudgeRatchet;
    NudgeRatchetMintDebtHook public nudgeRatchetHook;
    // Dedicated NFTStakerPriceScaled for the NudgeRatchet NFT (dispatcher index 7). Uses the
    // price-scaled variant because the ratchet's prime token is 6-decimal USDC while the reward
    // token is 18-decimal phUSD; priceScale = 1e12 normalizes the mint price so targetAPY works.
    NFTStakerPriceScaled public ratchetNFTStaker;
    // Dedicated BatchNFTMinter for the NudgeRatchet NFT (dispatcher index 7), so the UI
    // can batch-mint ratchet NFTs in a single tx. Separate instance from `batchNFTMinter`
    // (which is pinned to the BalancerPoolerV2 index-4 NFT): a BatchNFTMinter pins a single
    // dispatcher index. Payment token derives from the dispatcher's prime token (USDC);
    // its nudge REWARD token is USDS so it never collides with the USDC input.
    BatchNFTMinter public ratchetBatchNFTMinter;
    // Dedicated BatchNFTMinter per Uniboost NFT (EYE=index 1, SCX=index 2, FLX=index 3) so the
    // UI can batch-mint each in a single tx. One BatchNFTMinter pins exactly one dispatcher index,
    // so each Uniboost NFT needs its own instance. The nudge feature is deliberately left DISABLED
    // on all three (nudgeSize=0, nudgePaymentToken=address(0) — the defaults): these are pure batch
    // loopers, so they hold no funds and carry none of the nudge-pot drain surface.
    BatchNFTMinter public eyeBatchNFTMinter;
    BatchNFTMinter public scxBatchNFTMinter;
    BatchNFTMinter public flxBatchNFTMinter;

    // NFT Staking infrastructure
    BalancerPoolerMintDebtHook public balancerPoolerHook;
    NFTStaker public nftStaker;
    // Story 073: the shared donor sink is now a BatchNFTMinterMultiToken (USDC / phUSD / Kendu),
    // fed through the NudgeStreamer rather than by direct transfers. Keeps the "BatchNFTMinter"
    // tracked key so the address pipeline and the UI keep resolving it.
    BatchNFTMinterMultiToken public batchNFTMinter;

    // Story 073: buffers bursty donations per (batchMinter, token) and streams them linearly.
    // Six donors route through it: Uniboost x3, BalancerPoolerV2, the index-7 NudgeRatchet and
    // StableYieldAccumulator.
    NudgeStreamer public nudgeStreamer;

    // Stable Staking infrastructure (story 051)
    StableStaker public stableStaker;

    // Story 045.5 Phase 7 — BalancerPoolerV2 donation-phase mocks
    // waUSDC mock = ERC4626 wrapper over the existing USDC `rewardToken`.
    // (Retained for the V1-era BalancerPooler donation path; the V2 Sky-route
    //  donation no longer uses it — see MockSkyPSM below.)
    MockERC4626Wrapper public mockWaUsdc;

    // Story 056 — BalancerPoolerV2 Sky-PSM donation route mock.
    // Mock UsdsPsmWrapper: pulls USDS, delivers USDC from its reserve.
    MockSkyPSM public mockSkyPSM;

    // Progress tracking structure
    struct ContractDeployment {
        string name;
        address addr;
        bool deployed;
        bool configured;
        uint256 deployGas;
        uint256 configGas;
    }

    // Track all deployments
    mapping(string => ContractDeployment) public deployments;
    string[] public contractNames;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("ANVIL_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Phase 2 contracts to Anvil...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // Script-audit run-26, L-03. Resolved ONCE, here, and logged loudly next to the deployer
        // and chain-id lines so a developer reading the transcript knows which leg they got
        // without scrolling to Phase 7.4. Assigning a CONTRACT FIELD rather than a `run()` local
        // is deliberate: `run()` is at its stack-depth ceiling.
        armKenduPromo = vm.envOr("LOCAL_PROMO_KENDU", true);
        console.log("LOCAL_PROMO_KENDU (Kendu promo armed on PhlimboV3):", armKenduPromo);
        if (!armKenduPromo) {
            console.log("  -> DORMANT leg selected: PhlimboV3 will ship with promoToken == address(0),");
            console.log("     which is the day-one mainnet shape. Unset the var for the armed leg.");
        }

        vm.startBroadcast(deployerPrivateKey);

        // ====== PHASE 1: Token Deployment ======
        console.log("\n=== Phase 1: Deploying Tokens ===");

        uint256 gasBefore = gasleft();
        phUSD = new MockPhUSD();
        _trackDeployment("MockPhUSD", address(phUSD), gasBefore - gasleft());
        console.log("MockPhUSD deployed at:", address(phUSD));

        gasBefore = gasleft();
        rewardToken = new MockRewardToken(); // USDC - reward token for Phlimbo
        _trackDeployment("MockUSDC", address(rewardToken), gasBefore - gasleft());
        console.log("MockUSDC (RewardToken) deployed at:", address(rewardToken));

        gasBefore = gasleft();
        usds = new MockUSDS();
        _trackDeployment("MockUSDS", address(usds), gasBefore - gasleft());
        console.log("MockUSDS deployed at:", address(usds));

        // Deploy MockSUSDS (ERC4626 savings vault wrapping USDS)
        gasBefore = gasleft();
        susds = new MockSUSDS(address(usds));
        _trackDeployment("MockSUSDS", address(susds), gasBefore - gasleft());
        console.log("MockSUSDS deployed at:", address(susds));

        // Deposit initial USDS into MockSUSDS to establish baseline shares
        uint256 initialSusdsDeposit = 10_000 * 10 ** 18; // 10,000 USDS
        usds.approve(address(susds), initialSusdsDeposit);
        susds.deposit(initialSusdsDeposit, deployer);
        console.log("Deposited 10,000 USDS into MockSUSDS (baseline shares established)");

        // Deploy MockUSDe (ERC20, 18 decimals) — mirrors mainnet Ethena USDe
        gasBefore = gasleft();
        usde = new MockUSDe();
        _trackDeployment("USDe", address(usde), gasBefore - gasleft());
        console.log("MockUSDe deployed at:", address(usde));

        // Deploy MockSUSDe (ERC4626 savings vault wrapping USDe)
        gasBefore = gasleft();
        susde = new MockSUSDe(address(usde));
        _trackDeployment("SUSDe", address(susde), gasBefore - gasleft());
        console.log("MockSUSDe deployed at:", address(susde));

        // Deposit initial USDe into MockSUSDe to establish baseline shares
        uint256 initialSusdeDeposit = 10_000 * 10 ** 18; // 10,000 USDe
        usde.approve(address(susde), initialSusdeDeposit);
        susde.deposit(initialSusdeDeposit, deployer);
        console.log("Deposited 10,000 USDe into MockSUSDe (baseline shares established)");

        gasBefore = gasleft();
        dola = new MockDola();
        _trackDeployment("MockDola", address(dola), gasBefore - gasleft());
        console.log("MockDola deployed at:", address(dola));

        // ====== PHASE 1.5: EYE Token and Pauser Deployment ======
        console.log("\n=== Phase 1.5: Deploying EYE Token and Pauser ===");

        gasBefore = gasleft();
        eyeToken = new MockEYE();
        _trackDeployment("MockEYE", address(eyeToken), gasBefore - gasleft());
        console.log("MockEYE deployed at:", address(eyeToken));

        gasBefore = gasleft();
        mockSCX = new MockSCX();
        _trackDeployment("MockSCX", address(mockSCX), gasBefore - gasleft());
        console.log("MockSCX deployed at:", address(mockSCX));

        // Story 073: third nudge-reward asset on the multi-token batch minter. 18 decimals,
        // no burn surface, no transfer fee (the streamer assumes transfer(x) delivers exactly x).
        gasBefore = gasleft();
        mockKendu = new MockKendu();
        _trackDeployment("MockKendu", address(mockKendu), gasBefore - gasleft());
        console.log("MockKendu deployed at:", address(mockKendu));

        gasBefore = gasleft();
        mockFlax = new MockFlax();
        _trackDeployment("MockFlax", address(mockFlax), gasBefore - gasleft());
        console.log("MockFlax deployed at:", address(mockFlax));

        gasBefore = gasleft();
        mockWBTC = new MockWBTC();
        _trackDeployment("MockWBTC", address(mockWBTC), gasBefore - gasleft());
        console.log("MockWBTC deployed at:", address(mockWBTC));

        gasBefore = gasleft();
        pauser = new Pauser(address(eyeToken));
        _trackDeployment("Pauser", address(pauser), gasBefore - gasleft());
        console.log("Pauser deployed at:", address(pauser));

        // ====== PHASE 2: Yield Strategy Deployment ======
        console.log("\n=== Phase 2: Deploying Yield Strategies ===");

        // ====== PHASE 2.5: AutoDOLA ERC4626 Infrastructure for DOLA YieldStrategy ======
        console.log("\n=== Phase 2.5: Deploying AutoDOLA ERC4626 Infrastructure ===");

        // Deploy MockAutoDOLA (ERC4626 vault wrapper)
        gasBefore = gasleft();
        mockAutoDola = new MockAutoDOLA(address(dola));
        _trackDeployment("MockAutoDOLA", address(mockAutoDola), gasBefore - gasleft());
        console.log("MockAutoDOLA deployed at:", address(mockAutoDola));

        // Deploy ERC4626YieldStrategy wrapping the DOLA vault
        gasBefore = gasleft();
        yieldStrategyDola = new ERC4626YieldStrategy(
            deployer, // owner
            address(dola), // underlyingToken (DOLA)
            address(mockAutoDola) // erc4626Vault
        );
        _trackDeployment("YieldStrategyDola", address(yieldStrategyDola), gasBefore - gasleft());
        console.log("YieldStrategyDola (ERC4626YieldStrategy) deployed at:", address(yieldStrategyDola));

        // ====== PHASE 2.6: AutoUSDC ERC4626 Infrastructure for USDC YieldStrategy ======
        console.log("\n=== Phase 2.6: Deploying AutoUSDC ERC4626 Infrastructure ===");

        // Deploy MockAutoUSDC (ERC4626 vault wrapper for USDC) - reusing MockAutoDOLA pattern
        gasBefore = gasleft();
        mockAutoUSDC = new MockAutoDOLA(address(rewardToken)); // rewardToken is USDC (6 decimals)
        _trackDeployment("MockAutoUSDC", address(mockAutoUSDC), gasBefore - gasleft());
        console.log("MockAutoUSDC deployed at:", address(mockAutoUSDC));

        // Deploy ERC4626YieldStrategy wrapping the USDC vault
        gasBefore = gasleft();
        yieldStrategyUSDC = new ERC4626YieldStrategy(
            deployer, // owner
            address(rewardToken), // underlyingToken (USDC)
            address(mockAutoUSDC) // erc4626Vault
        );
        _trackDeployment("YieldStrategyUSDC", address(yieldStrategyUSDC), gasBefore - gasleft());
        console.log("YieldStrategyUSDC (ERC4626YieldStrategy) deployed at:", address(yieldStrategyUSDC));

        // ====== PHASE 2.7: USDe AMM-Market Infrastructure for USDe YieldStrategy ======
        console.log("\n=== Phase 2.7: Deploying USDe AMM-Market Infrastructure ===");

        // Configuration Safety (CLAUDE.md): both values are deliberately chosen, not defaults.
        //   - usdeSlippageToleranceBps = 30: target go-live tolerance chosen 2026-06-10 from
        //     live Curve route measurement (USDe->crvUSD->sUSDe at ~6k USDe magnitude):
        //     exit-leg loss observed 5-32 bps over 8 months of block samples, typically
        //     ~10 bps. Supersedes the old 120 bps mainnet-parity value (story 043); the
        //     owner can retune the live strategy any time via setSlippageTolerance.
        //   - usdeAmmSlippageBps is the simulated per-leg AMM loss. It MUST stay <= the
        //     tolerance or deposits revert on the strategy's minOut check (and the strategy
        //     would otherwise be left underwater). 10 bps mirrors the typical observed
        //     exit slippage on the live route.
        uint256 usdeSlippageToleranceBps = 30; // 0.3% principal haircut (target go-live value)
        uint256 usdeAmmSlippageBps = 10; // 0.1% simulated AMM slippage per swap leg
        require(
            usdeAmmSlippageBps <= usdeSlippageToleranceBps, "AMM slippage exceeds tolerance (would brick USDe deposits)"
        );

        // Deploy the mock Curve-style AMM adapter (USDe<->sUSDe). Routes through MockSUSDe so
        // share pricing tracks the vault, while skimming a slippage haircut on every leg.
        gasBefore = gasleft();
        usdeAmmAdapter = new MockMarketAMMAdapter(address(usde), address(susde), usdeAmmSlippageBps);
        _trackDeployment("USDeAMMAdapter", address(usdeAmmAdapter), gasBefore - gasleft());
        console.log("MockMarketAMMAdapter (USDe<->sUSDe) deployed at:", address(usdeAmmAdapter));
        console.log("  Simulated AMM slippage (bps):", usdeAmmSlippageBps);

        // Deploy ERC4626MarketYieldStrategy wrapping the USDe vault via the AMM adapter.
        // Unlike ERC4626YieldStrategy (1:1, no haircut), this credits principal at a haircut so
        // AMM slippage cannot leave the strategy underwater; the surplus surfaces as yield, and
        // the UI sees that deposits are NOT perfectly preserved.
        gasBefore = gasleft();
        yieldStrategyUSDe = new ERC4626MarketYieldStrategy(
            deployer, // owner
            address(usde), // underlyingToken (USDe)
            address(susde), // erc4626Vault (MockSUSDe)
            address(usdeAmmAdapter) // ammAdapter
        );
        _trackDeployment("YieldStrategyUSDe", address(yieldStrategyUSDe), gasBefore - gasleft());
        console.log("YieldStrategyUSDe (ERC4626MarketYieldStrategy) deployed at:", address(yieldStrategyUSDe));

        // Set the principal haircut. Left unset it defaults to 0 bps => principal == amount,
        // which is exactly the "perfectly preserved / immediately underwater" bug being fixed.
        yieldStrategyUSDe.setSlippageTolerance(usdeSlippageToleranceBps);
        require(yieldStrategyUSDe.slippageToleranceBps() == usdeSlippageToleranceBps, "USDe slippage tolerance unset");
        console.log("YieldStrategyUSDe slippage tolerance set (bps):", usdeSlippageToleranceBps);

        // ====== PHASE 3: Core Contract Deployment ======
        console.log("\n=== Phase 3: Deploying Core Contracts ===");

        // 1. Deploy PhusdStableMinter
        gasBefore = gasleft();
        minter = new PhusdStableMinter(address(phUSD));
        _trackDeployment("PhusdStableMinter", address(minter), gasBefore - gasleft());
        console.log("PhusdStableMinter deployed at:", address(minter));

        // 2. Deploy the INCUMBENT phlimbo — PhlimboV2 as of story 079, was PhlimboEA (V1).
        //
        // WHY V2 AND NOT V1: mainnet's incumbent is PhlimboV2, and the cutover under rehearsal
        // (Phase 4e / `MigratorV2V3`) only exists between V2 and V3. Deploying V1 here would
        // leave the local chain a generation behind and make the rehearsal impossible — there is
        // no V1->V3 migrator. Same constructor arity and same depletion model, so nothing else
        // in this phase changes.
        //
        // Using Linear Depletion model: depletion window = 1 week (604800 seconds)
        uint256 oneWeekInSeconds = 604800;
        gasBefore = gasleft();
        phlimbo = new PhlimboV2(
            address(phUSD), // _phUSD
            address(rewardToken), // _rewardToken (USDC)
            oneWeekInSeconds // _depletionDuration (1 week for linear depletion)
        );
        _trackDeployment("PhlimboEA", address(phlimbo), gasBefore - gasleft());
        console.log("PhlimboV2 (incumbent, key 'PhlimboEA') deployed at:", address(phlimbo));
        console.log("  - Depletion window:", oneWeekInSeconds, "seconds (1 week)");

        // 3. Deploy StableYieldAccumulator
        gasBefore = gasleft();
        stableYieldAccumulator = new StableYieldAccumulator();
        _trackDeployment("StableYieldAccumulator", address(stableYieldAccumulator), gasBefore - gasleft());
        console.log("StableYieldAccumulator deployed at:", address(stableYieldAccumulator));

        // ====== PHASE 3.6: V2 NFTMinter Infrastructure ======
        // (Phase 3.5 V1 NFTMinter infra removed in story 059 — V1 is decommissioned)
        console.log("\n=== Phase 3.6: Deploying V2 NFTMinter Infrastructure ===");

        // Deploy MockBalancerPool (ERC20 BPT)
        gasBefore = gasleft();
        mockBalancerPool = new MockBalancerPool();
        _trackDeployment("MockBalancerPool", address(mockBalancerPool), gasBefore - gasleft());
        console.log("MockBalancerPool deployed at:", address(mockBalancerPool));

        // Deploy MockBalancerVault
        gasBefore = gasleft();
        mockBalancerVault = new MockBalancerVault(address(mockBalancerPool));
        _trackDeployment("MockBalancerVault", address(mockBalancerVault), gasBefore - gasleft());
        console.log("MockBalancerVault deployed at:", address(mockBalancerVault));

        // Wire MockBalancerPool to recognize the vault
        mockBalancerPool.setVault(address(mockBalancerVault));
        console.log("Wired MockBalancerPool to recognize MockBalancerVault");

        // Deploy BurnRecorder
        gasBefore = gasleft();
        burnRecorder = new BurnRecorder(deployer);
        _trackDeployment("BurnRecorder", address(burnRecorder), gasBefore - gasleft());
        console.log("BurnRecorder deployed at:", address(burnRecorder));

        // 1. Deploy MockBalancerRouter
        gasBefore = gasleft();
        mockBalancerRouter = new MockBalancerRouter();
        _trackDeployment("MockBalancerRouter", address(mockBalancerRouter), gasBefore - gasleft());
        console.log("MockBalancerRouter deployed at:", address(mockBalancerRouter));

        // 2. Deploy NFTMinterV2
        gasBefore = gasleft();
        nftMinterV2 = new NFTMinterV2(deployer);
        _trackDeployment("NFTMinterV2", address(nftMinterV2), gasBefore - gasleft());
        console.log("NFTMinterV2 deployed at:", address(nftMinterV2));

        // ---- Story 070: real Uniswap V2 + target/routing pools (anvil 31337) ----
        // Replace the three burners (indices 1/2/3) with Uniboost dispatchers, each backed by a
        // REAL UniV2 pool. We deploy the canonical Uniswap V2 stack and seed pools here, BEFORE
        // constructing the dispatchers, because Uniboost's constructor reads pool.token0()/token1().
        _deployUniswapAndPools(deployer);

        // 3. Deploy V2 Dispatchers
        // ---- Story 070: Uniboost #1/#2/#3 replace BurnerEYE/SCX/Flax at indices 1/2/3 ----
        // primeToken = rewardToken (USDC, 6dp); router = canonical Router02; targetPool/targetToken
        // per the seeded pools above. Hook + staker + donation split are wired in later phases.
        gasBefore = gasleft();
        uniboostEYE = new Uniboost(address(rewardToken), address(uniRouter), poolEYE, address(eyeToken), deployer);
        _trackDeployment("UniboostEYE", address(uniboostEYE), gasBefore - gasleft());
        console.log("UniboostEYE deployed at:", address(uniboostEYE));

        gasBefore = gasleft();
        uniboostSCX = new Uniboost(address(rewardToken), address(uniRouter), poolSCX, address(mockSCX), deployer);
        _trackDeployment("UniboostSCX", address(uniboostSCX), gasBefore - gasleft());
        console.log("UniboostSCX deployed at:", address(uniboostSCX));

        gasBefore = gasleft();
        uniboostFLX = new Uniboost(address(rewardToken), address(uniRouter), poolFLX, address(mockFlax), deployer);
        _trackDeployment("UniboostFLX", address(uniboostFLX), gasBefore - gasleft());
        console.log("UniboostFLX deployed at:", address(uniboostFLX));

        // BalancerPoolerV2: prime token is USDS (derived from sUSDS via IERC4626.asset())
        gasBefore = gasleft();
        balancerPoolerV2 = new BalancerPoolerV2(
            address(susds), // sUSDS_ (ERC4626 vault)
            address(mockBalancerPool), // pool_ (BPT token)
            address(mockBalancerVault), // vault_
            address(mockBalancerRouter), // router_
            true, // sUSDSIsFirst_
            deployer // initialOwner
        );
        _trackDeployment("BalancerPoolerV2", address(balancerPoolerV2), gasBefore - gasleft());
        console.log("BalancerPoolerV2 deployed at:", address(balancerPoolerV2));

        // GatherV2: accumulates WBTC, sends to deployer
        gasBefore = gasleft();
        gatherWBTCV2 = new GatherV2(
            address(mockWBTC), // token_ (WBTC)
            deployer, // recipient_ (deployer)
            deployer // initialOwner
        );
        _trackDeployment("GatherWBTCV2", address(gatherWBTCV2), gasBefore - gasleft());
        console.log("GatherWBTCV2 deployed at:", address(gatherWBTCV2));

        // 4. Register V2 dispatchers with NFTMinterV2
        uint256 v2InitialPrice = 10 * 10 ** 18;
        uint256 v2WBTCInitialPrice = 100 * 10 ** 8; // WBTC has 8 decimals
        uint256 v2RatchetInitialPrice = 10 * 10 ** 6; // NudgeRatchet's prime token is 6-decimal USDC
        // Story 070: uniboost NFT mint price = 10 USDC (6dp), growth 0.1% (10 bps). This is the
        // NFT MINT price (unrelated to the seeded Uniswap pool price). Replaces the burners'
        // 100e18 / 2% registration AT THE SAME SLOT so indices 1/2/3 are preserved.
        uint256 uniboostInitialPrice = 10 * 10 ** 6; // 10 USDC
        uint256 uniboostGrowthBps = 10; // 0.1%

        nftMinterV2.registerDispatcher(address(uniboostEYE), uniboostInitialPrice, uniboostGrowthBps);
        console.log("Registered UniboostEYE dispatcher with NFTMinterV2 (index 1, 10 USDC, 0.1% growth)");

        nftMinterV2.registerDispatcher(address(uniboostSCX), uniboostInitialPrice, uniboostGrowthBps);
        console.log("Registered UniboostSCX dispatcher with NFTMinterV2 (index 2, 10 USDC, 0.1% growth)");

        nftMinterV2.registerDispatcher(address(uniboostFLX), uniboostInitialPrice, uniboostGrowthBps);
        console.log("Registered UniboostFLX dispatcher with NFTMinterV2 (index 3, 10 USDC, 0.1% growth)");

        nftMinterV2.registerDispatcher(address(balancerPoolerV2), v2InitialPrice, 10); // 0.1% growth
        console.log("Registered BalancerPoolerV2 dispatcher with NFTMinterV2 (index 4, 0.1% growth)");

        nftMinterV2.registerDispatcher(address(gatherWBTCV2), v2WBTCInitialPrice, 1000); // 10% growth
        console.log("Registered GatherWBTCV2 dispatcher with NFTMinterV2 (index 5, 10% growth)");

        // ---- Index-6 mirror: disabled "bugged pooler" placeholder ----
        // On mainnet, dispatcher index 6 is permanently occupied by the disabled bugged
        // BalancerPoolerV2 (registered by story-047, disabled by the story-048 cutover).
        // registerDispatcher is append-only by index, so index 6 can never be reclaimed —
        // meaning NudgeRatchet will land at index 7 on mainnet. We mirror that here by
        // registering a second BalancerPoolerV2 at index 6 and immediately disabling it,
        // so the local NudgeRatchet also receives index 7 and the dispatcher layout (and
        // therefore MintPageView's hardcoded index 7) is identical across all networks.
        // This dispatcher is disabled and never minted; it exists only to consume index 6.
        gasBefore = gasleft();
        buggedPoolerV2Index6 = new BalancerPoolerV2(
            address(susds), // sUSDS_ (ERC4626 vault) — same args as the real pooler
            address(mockBalancerPool), // pool_ (BPT token)
            address(mockBalancerVault), // vault_
            address(mockBalancerRouter), // router_
            true, // sUSDSIsFirst_
            deployer // initialOwner
        );
        _trackDeployment("BuggedPoolerV2Index6", address(buggedPoolerV2Index6), gasBefore - gasleft());
        console.log("BuggedPoolerV2Index6 (disabled placeholder) deployed at:", address(buggedPoolerV2Index6));

        nftMinterV2.registerDispatcher(address(buggedPoolerV2Index6), v2InitialPrice, 10); // index 6
        nftMinterV2.setDispatcherDisabled(6, true); // mirror mainnet: index 6 is disabled
        console.log("Registered + disabled BuggedPoolerV2Index6 (index 6) to mirror mainnet");

        // 5. Set minter on each V2 dispatcher.
        // ---- Story 070: Uniboost minter + hook + pooler-auth wiring (indices 1/2/3) ----
        // Construction/registration must stay in this early block to preserve indices 1/2/3.
        // The DONATION split (setRecipient/setDonationSplit) is DEFERRED to Phase 3.7 below
        // because its recipient (batchNFTMinter) is not deployed until then. The staker +
        // Pauser registration are likewise deferred to keep this block focused.

        // Deploy the MultiPooler batch forwarder FIRST so _wireUniboost can authorize it as the sole
        // pooler on each dispatcher. The deployer is the keeper/operator that drives the batch from
        // the UI on anvil, so it is the MultiPooler's single batch-caller (`pooler`). Note this is
        // distinct from a Uniboost authorized-pooler: the deployer can call MultiPooler.pool(), but
        // is NOT whitelisted on any Uniboost — only the MultiPooler address is.
        gasBefore = gasleft();
        multiPooler = new MultiPooler(deployer);
        _trackDeployment("MultiPooler", address(multiPooler), gasBefore - gasleft());
        console.log("MultiPooler deployed at:", address(multiPooler));
        multiPooler.setPooler(deployer);
        console.log("MultiPooler.setPooler -> deployer (anvil keeper/operator)");

        _wireUniboost(uniboostEYE, "UniboostEYE");
        uniboostHookEYE = _deployUniboostHook(uniboostEYE, deployer);
        _trackDeployment("UniboostHookEYE", address(uniboostHookEYE), 0);

        _wireUniboost(uniboostSCX, "UniboostSCX");
        uniboostHookSCX = _deployUniboostHook(uniboostSCX, deployer);
        _trackDeployment("UniboostHookSCX", address(uniboostHookSCX), 0);

        _wireUniboost(uniboostFLX, "UniboostFLX");
        uniboostHookFLX = _deployUniboostHook(uniboostFLX, deployer);
        _trackDeployment("UniboostHookFLX", address(uniboostHookFLX), 0);

        balancerPoolerV2.setMinter(address(nftMinterV2));
        console.log("BalancerPoolerV2.setMinter -> NFTMinterV2");

        balancerPoolerV2.setAuthorizedPooler(deployer, true);
        console.log("BalancerPoolerV2.setAuthorizedPooler(deployer, true)");

        // ---- Story 045.5 Phase 7: BalancerPoolerV2 swap-config + waUSDC ----
        // (setBatchMinter and setBatchDonationSize land in Phase 3.7 below, after
        // BatchNFTMinter is deployed.)
        // Deploy waUSDC mock (ERC4626 wrapper over the existing USDC reward token).
        // 6 decimals to match real USDC; default rate 10000 bps (1:1 redeem).
        gasBefore = gasleft();
        mockWaUsdc = new MockERC4626Wrapper("Mock Wrapped Aave USDC", "mwaUSDC", address(rewardToken), 6, 10000);
        _trackDeployment("MockWaUSDC", address(mockWaUsdc), gasBefore - gasleft());
        console.log("MockWaUSDC deployed at:", address(mockWaUsdc));

        // Pre-fund the waUSDC wrapper with underlying USDC so `redeem` payouts
        // succeed during BalancerPoolerV2 donation-phase unwraps. The mock
        // wrapper mints shares without taking deposits, so it has no USDC
        // backing unless we seed it here. See src/mocks/MockERC4626Wrapper.sol
        // ("Tests/dev scripts pre-fund the wrapper directly").
        rewardToken.mint(address(mockWaUsdc), 1_000_000 * 10 ** 6);
        console.log("Pre-funded MockWaUSDC with 1,000,000 USDC for redeem backing");

        // ---- Story 056: BalancerPoolerV2 Sky-PSM donation route ----
        // The V2 batch donation no longer swaps sUSDS->waUSDC on Balancer (that route
        // was structurally dead). It now routes raw USDS -> USDC via the Sky PSM
        // (`buyGem`). The contract's `_dispatch` carves a `batchDonationSize`% slice of
        // the dispatched USDS and sends the resulting USDC to `batchMinter`.
        //
        // Deploy a MockSkyPSM (USDS in -> USDC out, fixed-rate, reserve-backed) and
        // pre-fund its USDC reserve so `buyGem` payouts succeed during dispatch.
        gasBefore = gasleft();
        mockSkyPSM = new MockSkyPSM(
            address(rewardToken), // gem  = USDC (6dp)
            address(usds) // usds = USDS (18dp)
        );
        _trackDeployment("MockSkyPSM", address(mockSkyPSM), gasBefore - gasleft());
        console.log("MockSkyPSM deployed at:", address(mockSkyPSM));

        // Pre-fund the PSM's USDC reserve so it can deliver USDC on `buyGem`.
        rewardToken.mint(address(mockSkyPSM), 1_000_000 * 10 ** 6);
        console.log("Pre-funded MockSkyPSM with 1,000,000 USDC reserve");

        // Wire the Sky-route config on BalancerPoolerV2 (recipient comes later in
        // Phase 3.7). `setPSM` enables the route; `setMaxTout(0.01e18)` mirrors the
        // contract's default 1% buy-fee ceiling so a fee spike parks USDS rather than
        // shipping a worse rate. The mock PSM's tout defaults to 0 (well under the cap).
        balancerPoolerV2.setPSM(address(mockSkyPSM));
        console.log("BalancerPoolerV2.setPSM -> MockSkyPSM");

        balancerPoolerV2.setMaxTout(0.01e18);
        console.log("BalancerPoolerV2.setMaxTout -> 0.01e18 (1%)");

        gatherWBTCV2.setMinter(address(nftMinterV2));
        console.log("GatherWBTCV2.setMinter -> NFTMinterV2");

        // Story 070: the burner-specific BurnRecorder.setBurner(burner*, true) lines were removed
        // — Uniboost does not burn. BurnRecorder itself is retained (MintPageView still reads its
        // getTotalBurnt totals, which now stay at zero on the EYE/SCX/Flax slots).

        // ====== PHASE 3.7: NFT Staking Stack ======
        console.log("\n=== Phase 3.7: NFT Staking Stack ===");

        // 1. Deploy BalancerPoolerMintDebtHook (replaces the default no-op DispatchHook)
        gasBefore = gasleft();
        balancerPoolerHook = new BalancerPoolerMintDebtHook(deployer, address(balancerPoolerV2), address(phUSD));
        _trackDeployment("BalancerPoolerMintDebtHook", address(balancerPoolerHook), gasBefore - gasleft());
        console.log("BalancerPoolerMintDebtHook deployed at:", address(balancerPoolerHook));

        // 2. Install the hook on BalancerPoolerV2 (swaps out the constructor-installed DefaultDispatchHook)
        balancerPoolerV2.setHook(IDispatchHook(address(balancerPoolerHook)));
        console.log("BalancerPoolerV2.setHook -> BalancerPoolerMintDebtHook");

        // 3. Deploy NFTStaker (BalancerPoolerV2 NFT id = 4, phUSD as reward, dispatcher index 4)
        gasBefore = gasleft();
        nftStaker = new NFTStaker(
            IERC1155(address(nftMinterV2)), 4, IERC20(address(phUSD)), deployer, INFTSupply(address(nftMinterV2)), 4
        );
        _trackDeployment("NFTStaker", address(nftStaker), gasBefore - gasleft());
        console.log("NFTStaker deployed at:", address(nftStaker));

        // 4. Wire NFTStaker -> hook
        nftStaker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(balancerPoolerHook)));
        console.log("NFTStaker.setDispatcherHook -> BalancerPoolerMintDebtHook");

        // 5. Wire hook recipient -> NFTStaker
        balancerPoolerHook.setRecipient(address(nftStaker));
        console.log("BalancerPoolerMintDebtHook.setRecipient -> NFTStaker");

        // 6. Authorize the hook to mint phUSD (so pull() can realise mint debt)
        phUSD.setMinter(address(balancerPoolerHook), true);
        console.log("Authorized BalancerPoolerMintDebtHook as phUSD minter");

        // 7. Set the target APY (30% — bounded by MAX_TARGET_APY = 50%)
        nftStaker.setTargetAPY(0.3e18);
        console.log("NFTStaker.setTargetAPY -> 0.3e18 (30%)");

        // 8/9. Story 073 — deploy the NudgeStreamer and the multi-token batch minter, whitelist
        //      the three nudge-reward tokens, and register their streams. Extracted into a helper
        //      because run() is at its stack-depth ceiling (see the gas-tracking note further
        //      down); the mandated call ordering lives inside the helper.
        _deployStreamerAndBatchMinter(deployer);

        // ---- Story 045.5 Phase 7: Finalise BalancerPoolerV2 batch-donation wiring ----
        // BatchNFTMinter is now deployed — point the donation recipient at it and
        // turn the donation phase on. Order: setBatchMinter (recipient) BEFORE
        // setBatchDonationSize (the activator). Swap config was already wired in
        // Phase 3.6 above.
        balancerPoolerV2.setBatchMinter(address(batchNFTMinter));
        console.log("BalancerPoolerV2.setBatchMinter -> BatchNFTMinter");

        balancerPoolerV2.setBatchDonationSize(MOCK_BATCH_DONATION_SIZE);
        console.log("BalancerPoolerV2.setBatchDonationSize ->", MOCK_BATCH_DONATION_SIZE);

        // Story 073: the index-4 donation branch is streamer-gated. Without this the donation
        // reverts inside `_psmDonate` and `_dispatch`'s try/catch swallows it — the mint succeeds
        // but zero USDC ever reaches the batch minter (the exact silent breakage this story fixes).
        // MUST come after registerStream(batchNFTMinter, USDC) inside the helper above.
        balancerPoolerV2.setNudgeStreamer(address(nudgeStreamer));
        console.log("BalancerPoolerV2.setNudgeStreamer -> NudgeStreamer");

        // ---- Story 070: deferred Uniboost wiring (donation split + staker + Pauser) ----
        // batchNFTMinter now exists, so this is the phase where the uniboost dispatchers learn
        // their donation recipient. Recipient is `batchNFTMinter` (the BalancerPoolerV2 index-4
        // LSP batch minter) — NOT ratchetBatchNFTMinter — so 50% of each mint's USDC nudges
        // protocol-pooler (LSP) minting; the remaining 50% is retained for pool().
        //
        // Story 073: `_finalizeUniboost` additionally calls setNudgeStreamer, and the staker step
        // is now the full V1 -> migrator -> V2 depletion-staker migration REHEARSAL. The chain ends
        // on NFTStakerDepletionV2 under the existing UniboostStaker* keys; the V1 stakers and the
        // migrators are transient rehearsal artifacts and are deliberately NOT tracked.
        _finalizeUniboost(uniboostEYE, uniboostHookEYE, address(batchNFTMinter), deployer);
        uniboostStakerEYE = _rehearseStakerMigration(uniboostEYE, uniboostHookEYE, deployer, "EYE");
        _trackDeployment("UniboostStakerEYE", address(uniboostStakerEYE), 0);

        _finalizeUniboost(uniboostSCX, uniboostHookSCX, address(batchNFTMinter), deployer);
        uniboostStakerSCX = _rehearseStakerMigration(uniboostSCX, uniboostHookSCX, deployer, "SCX");
        _trackDeployment("UniboostStakerSCX", address(uniboostStakerSCX), 0);

        _finalizeUniboost(uniboostFLX, uniboostHookFLX, address(batchNFTMinter), deployer);
        uniboostStakerFLX = _rehearseStakerMigration(uniboostFLX, uniboostHookFLX, deployer, "FLX");
        _trackDeployment("UniboostStakerFLX", address(uniboostStakerFLX), 0);

        // ---- Batch minters for the three Uniboost NFTs (EYE/SCX/FLX) ----
        // A BatchNFTMinter pins exactly one dispatcher index, so each Uniboost NFT (indices 1/2/3)
        // needs its own instance to be batch-mintable from the UI. Nudge is left disabled on all
        // three (see the field declarations). Indices are derived from the registered dispatcher
        // rather than hard-coded so a registration-order change can't silently mis-wire them.
        eyeBatchNFTMinter = _deployNudgelessBatchMinter(address(uniboostEYE), "EyeBatchNFTMinter", deployer);
        scxBatchNFTMinter = _deployNudgelessBatchMinter(address(uniboostSCX), "ScxBatchNFTMinter", deployer);
        flxBatchNFTMinter = _deployNudgelessBatchMinter(address(uniboostFLX), "FlxBatchNFTMinter", deployer);

        // ---- Story 068/070/073: NudgeRatchet dispatcher + mint-debt hook ----
        // Story 070 swapped the index-7 dispatcher from NudgeRatchet to NudgeRatchetDelayRelease
        // (HOLDS USDC on dispatch; a whitelisted releaser later released it). Story 073 retires
        // that stopgap: the streamer-aware NudgeRatchet forwards on dispatch again, but through
        // the NudgeStreamer, which supplies the same anti-burst smoothing the DelayRelease hack
        // approximated manually. Same constructor signature (token_, batchMinter_, initialOwner),
        // same 6-decimal USDC guard, same non-zero batchMinter sink, same index-7 registration
        // slot/price/growth. There is no releaser concept on NudgeRatchet, so setReleaser is gone.
        gasBefore = gasleft();
        nudgeRatchet = new NudgeRatchet(
            address(rewardToken), // token_ — existing 6-decimal MockRewardToken (USDC)
            address(batchNFTMinter), // batchMinter_ — the multi-token nudge-reward sink
            deployer // initialOwner
        );
        _trackDeployment("NudgeRatchet", address(nudgeRatchet), gasBefore - gasleft());
        console.log("NudgeRatchet deployed at:", address(nudgeRatchet));

        // 1. Point the dispatcher's minter at NFTMinterV2.
        nudgeRatchet.setMinter(address(nftMinterV2));
        console.log("NudgeRatchet.setMinter -> NFTMinterV2");

        // 1b. Story 073: route the USDC sweep through the NudgeStreamer. `_dispatch` sweeps the
        //     full USDC balance and `collectNudge` reverts unless the streamer is set, so without
        //     this EVERY index-7 dispatch reverts "NudgeRatchet: nudgeStreamer unset". Ordering is
        //     mandated (NudgeRatchet.sol:39-43): whitelist -> registerStream -> setNudgeStreamer;
        //     the first two already ran in _deployStreamerAndBatchMinter above.
        nudgeRatchet.setNudgeStreamer(address(nudgeStreamer));
        console.log("NudgeRatchet.setNudgeStreamer -> NudgeStreamer");

        // 2. Deploy the matching mint-debt hook. NudgeRatchet._dispatch reverts unless the
        //    installed hook is a NudgeRatchetMintDebtHook (hookTypeId() guard), so this hook
        //    MUST replace the constructor-installed DefaultDispatchHook or the dispatcher is
        //    bricked on first dispatch.
        gasBefore = gasleft();
        nudgeRatchetHook = new NudgeRatchetMintDebtHook(
            deployer, // initialOwner
            address(nudgeRatchet), // dispatcher_
            address(phUSD) // phUSD_
        );
        _trackDeployment("NudgeRatchetMintDebtHook", address(nudgeRatchetHook), gasBefore - gasleft());
        console.log("NudgeRatchetMintDebtHook deployed at:", address(nudgeRatchetHook));

        // 3. Install the hook on NudgeRatchet (swaps out the DefaultDispatchHook).
        nudgeRatchet.setHook(IDispatchHook(address(nudgeRatchetHook)));
        console.log("NudgeRatchet.setHook -> NudgeRatchetMintDebtHook");

        // 4. Authorize the hook to mint phUSD (so it can realise mint debt on dispatch).
        phUSD.setMinter(address(nudgeRatchetHook), true);
        console.log("Authorized NudgeRatchetMintDebtHook as phUSD minter");

        // 5. Register the dispatcher on NFTMinterV2 (index auto-assigns to 7, after the
        //    disabled bugged-pooler placeholder at index 6 — see the index-6 mirror above).
        //    Index 7 matches the index NudgeRatchet receives on mainnet, where the disabled
        //    bugged pooler permanently holds index 6. Mirror the BalancerPoolerV2 price + 0.1% growth.
        nftMinterV2.registerDispatcher(address(nudgeRatchet), v2RatchetInitialPrice, 10); // 0.1% growth (6-decimal USDC price)
        console.log("Registered NudgeRatchet dispatcher with NFTMinterV2 (index 7, 0.1% growth)");

        // 6. Deploy + wire a dedicated NFTStaker for the NudgeRatchet NFT. The
        //    NudgeRatchetMintDebtHook accrues phUSD mint debt on every ratchet
        //    dispatch and exposes the same consumer surface as the Balancer
        //    pooler hook (`mintDebt()` + `pull()`), so the staker drives it the
        //    same way — only the recipient/index differ. The minted tokenId
        //    equals the dispatcher index (NFTMinterV2._executeMint:
        //    resolvedTokenId = index), so stakedId == dispatcherIndex == 7.
        //    Derive the index rather than hard-coding so a registration-order
        //    change can't silently mis-wire the staker.
        uint256 ratchetIndex = nftMinterV2.dispatcherToIndex(address(nudgeRatchet));
        require(ratchetIndex != 0, "NudgeRatchet not registered with NFTMinterV2");
        // Story 073: MintPageView hard-codes index 7 for the ratchet row. The index-6 disabled
        // placeholder above exists solely so this lands on 7 — assert it, loudly, rather than
        // letting a registration-order change silently shift the UI's pinned slot.
        require(ratchetIndex == 7, "NudgeRatchet must occupy dispatcher index 7");
        // priceScale = 1e12: NudgeRatchet's prime token is 6-decimal USDC; phUSD is 18-decimal.
        // Without scaling, latestPrice floor-divides the emission rate to zero.
        uint256 ratchetPriceScale = 1e12;
        gasBefore = gasleft();
        ratchetNFTStaker = new NFTStakerPriceScaled(
            IERC1155(address(nftMinterV2)),
            ratchetIndex,
            IERC20(address(phUSD)),
            deployer,
            INFTSupply(address(nftMinterV2)),
            ratchetIndex,
            ratchetPriceScale
        );
        _trackDeployment("RatchetNFTStaker", address(ratchetNFTStaker), gasBefore - gasleft());
        console.log("RatchetNFTStaker deployed at:", address(ratchetNFTStaker));

        // Wire staker -> hook (cast to the IBalancerPoolerMintDebtHook surface).
        ratchetNFTStaker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(nudgeRatchetHook)));
        console.log("RatchetNFTStaker.setDispatcherHook -> NudgeRatchetMintDebtHook");

        // Wire hook recipient -> staker so pull() mints accrued phUSD to the pool.
        // (The hook was already authorised as a phUSD minter above.)
        nudgeRatchetHook.setRecipient(address(ratchetNFTStaker));
        console.log("NudgeRatchetMintDebtHook.setRecipient -> RatchetNFTStaker");

        // Target APY 45% (bounded by MAX_TARGET_APY = 50%).
        ratchetNFTStaker.setTargetAPY(0.45e18);
        console.log("RatchetNFTStaker.setTargetAPY -> 0.45e18 (45%)");

        // 7. Deploy + wire a dedicated BatchNFTMinter for the NudgeRatchet NFT so the UI
        //    can batch-mint ratchet NFTs in a single tx. This is a separate instance from
        //    the BalancerPoolerV2 batch minter (`batchNFTMinter`, index 4): a BatchNFTMinter
        //    pins exactly one dispatcher index, so the ratchet NFT (index 7) needs its own.
        gasBefore = gasleft();
        ratchetBatchNFTMinter = new BatchNFTMinter(deployer);
        _trackDeployment("RatchetBatchNFTMinter", address(ratchetBatchNFTMinter), gasBefore - gasleft());
        console.log("RatchetBatchNFTMinter deployed at:", address(ratchetBatchNFTMinter));

        // Pin the trusted minter + the ratchet dispatcher index. batchMint reverts
        // BatchMint__MinterNotConfigured / BatchMint__DispatcherNotConfigured before pulling
        // any funds unless both are set. The payment token is DERIVED from the pinned
        // dispatcher's primeToken() — here the NudgeRatchet's 6-decimal USDC — so the caller
        // pays in USDC and cannot supply a wrong/zero payment asset. Reuse the derived
        // `ratchetIndex` (== 7) rather than hard-coding so a registration-order change can't
        // silently mis-wire it.
        ratchetBatchNFTMinter.setTokenMinter(ITokenMinterV2(address(nftMinterV2)));
        console.log("RatchetBatchNFTMinter.setTokenMinter -> NFTMinterV2");
        ratchetBatchNFTMinter.setDispatcherIndex(ratchetIndex);
        console.log("RatchetBatchNFTMinter.setDispatcherIndex ->", ratchetIndex);

        // Nudge REWARD token = USDS (18-decimal), deliberately DISTINCT from the USDC payment
        // token. BatchNFTMinter requires nudgePaymentToken != the dispatcher's prime token,
        // else batchMint reverts BatchMint__NudgeTokenMatchesPaymentToken up-front (before any
        // funds move). USDC in, USDS out — no overlap. Set the token before the size to mirror
        // the index-4 batch minter's setter ordering above.
        ratchetBatchNFTMinter.setNudgePaymentToken(address(usds)); // USDS reward (!= USDC input)
        console.log("RatchetBatchNFTMinter.setNudgePaymentToken -> USDS");
        ratchetBatchNFTMinter.setNudgeSize(MOCK_NUDGE_SIZE);
        console.log("RatchetBatchNFTMinter.setNudgeSize ->", MOCK_NUDGE_SIZE);

        // Seed the USDS nudge pot so the reward is visibly payable in local dev. The index-4
        // batch minter's USDC nudge is refilled by the SYA/pooler USDC funnel; the ratchet
        // batch minter's USDS reward has no such on-chain funnel (the ratchet funnel forwards
        // USDC), so pre-fund it directly here. MockUSDS exposes an unrestricted mint (dev only).
        uint256 ratchetNudgeSeed = 10_000 * 10 ** 18; // 10,000 USDS
        usds.mint(address(ratchetBatchNFTMinter), ratchetNudgeSeed);
        console.log("Seeded RatchetBatchNFTMinter with 10,000 USDS nudge pot");

        // ====== PHASE 3.7: StableStaker Deployment + Wiring (story 051) ======
        console.log("\n=== Phase 3.7: Deploying + Wiring StableStaker ===");

        // 1. Deploy the MasterChef-style stable farm. phUSD (MockPhUSD) satisfies IFlax
        //    (exposes mint/setMinter); deployer is the initial owner.
        gasBefore = gasleft();
        stableStaker = new StableStaker(IFlaxStaker(address(phUSD)), deployer);
        _trackDeployment("StableStaker", address(stableStaker), gasBefore - gasleft());
        console.log("StableStaker deployed at:", address(stableStaker));

        // 2. Authorize StableStaker as a phUSD minter — it mints rewards on claim/withdraw.
        phUSD.setMinter(address(stableStaker), true);
        console.log("Authorized StableStaker as phUSD minter");

        // 3. Per token: register the pool, authorize the staker as a client ON the strategy
        //    (mandatory two-sided wiring — without it stake/withdraw revert), wire the
        //    strategy on the staker, then set the daily phUSD emission budget.
        //    Emission units are phUSD wei/day (18 decimals) regardless of the staked
        //    token's decimals: 10e18 = 10 phUSD/day, 5e18 = 5 phUSD/day.
        //    DOLA and USDe pools get 10/day; the USDC (rewardToken) pool gets 5/day so
        //    the reduced rate is visible in the UI (story 051 Concerns).
        address[3] memory ssTokens = [address(dola), address(rewardToken), address(usde)];
        // Heterogeneous strategies (DOLA/USDC are ERC4626YieldStrategy; USDe is the
        // ERC4626MarketYieldStrategy) — upcast to the shared base so the loop's setClient /
        // setSetAsideBuffer calls (both defined on AYieldStrategy) apply uniformly.
        AYieldStrategy[3] memory ssStrats =
            [AYieldStrategy(yieldStrategyDola), AYieldStrategy(yieldStrategyUSDC), AYieldStrategy(yieldStrategyUSDe)];
        for (uint256 i = 0; i < 3; i++) {
            stableStaker.addToken(ssTokens[i]);
            ssStrats[i].setClient(address(stableStaker), true); // client added ON the yield strategy
            stableStaker.setYieldStrategy(ssTokens[i], IYieldStrategy(address(ssStrats[i])));
            // Reserve a 10% liquid buffer of realized surplus back to StableStaker (the client)
            // on each skimSurplus, so 90% flows downstream. Integer percent (require <= 100); the
            // setter lives on the strategy, not the staker (story 053).
            ssStrats[i].setSetAsideBuffer(address(stableStaker), 10);
            uint256 dailyRate = ssTokens[i] == address(rewardToken) ? 5e18 : 10e18;
            stableStaker.phUSDPerDay(ssTokens[i], dailyRate);
            console.log("StableStaker pool wired (token / phUSD-per-day):", ssTokens[i], dailyRate);
            console.log("StableStaker set-aside buffer set to 10% on strategy:", address(ssStrats[i]));
        }
        console.log("StableStaker: 3 pools registered, strategies wired (both sides), rates set, 10% set-aside buffer");

        // ====== PHASE 4: Token Authorization ======
        console.log("\n=== Phase 4: Token Authorization ===");

        // Authorize the PhlimboV2 incumbent as phUSD minter. Story 079: this grant is REVOKED
        // again in the Phase 7.4 cutover, after V2 has been emptied and wound down — mirroring
        // mainnet Phase 4e step 14. It is granted here because V2 must be able to mint the
        // pending phUSD reward leg during the migration's `withdraw` calls.
        phUSD.setMinter(address(phlimbo), true);
        console.log("Authorized PhlimboV2 as phUSD minter (revoked again after the cutover)");

        // Authorize PhusdStableMinter as phUSD minter
        phUSD.setMinter(address(minter), true);
        console.log("Authorized PhusdStableMinter as phUSD minter");

        // ====== PHASE 5: YieldStrategy Configuration ======
        console.log("\n=== Phase 5: YieldStrategy Configuration ===");

        // Authorize minter as client on all yield strategies
        yieldStrategyDola.setClient(address(minter), true);
        yieldStrategyUSDC.setClient(address(minter), true);
        console.log("Authorized minter as yield strategy client (all strategies)");

        // ====== PHASE 6: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 6: PhusdStableMinter Configuration ===");

        // Approve yield strategies for their respective tokens
        minter.approveYS(address(dola), address(yieldStrategyDola));
        minter.approveYS(address(rewardToken), address(yieldStrategyUSDC)); // USDC
        console.log("Approved yield strategies for their tokens");

        // Register DOLA as stablecoin (18 decimals)
        minter.registerStablecoin(
            address(dola), // stablecoin
            address(yieldStrategyDola), // yieldStrategy
            1e18, // exchangeRate (1:1)
            18 // decimals
        );
        console.log("Registered DOLA as stablecoin");

        // Register USDC as stablecoin (6 decimals)
        minter.registerStablecoin(
            address(rewardToken), // stablecoin (USDC)
            address(yieldStrategyUSDC), // yieldStrategy
            1e18, // exchangeRate (1:1)
            6 // decimals
        );
        console.log("Registered USDC as stablecoin");

        // ====== PHASE 7: Phlimbo Configuration ======
        console.log("\n=== Phase 7: Phlimbo Configuration ===");

        // Desired APY = 0: no phUSD minted by phlimbo, yield comes only from the yield funnel
        phlimbo.setDesiredAPY(0);
        console.log("Set desired APY (preview): 0 bps");

        // Wait for next block (simulate block advancement)
        vm.roll(block.number + 1);

        // Commit APY change
        phlimbo.setDesiredAPY(0);
        console.log("Set desired APY (commit): 0 bps");

        // ====== PHASE 7.4: PhlimboV2 -> PhlimboV3 cutover rehearsal (story 079) ======
        // Sequenced HERE, immediately before Phase 7.5, for the same reason mainnet sequences
        // Phase 4e immediately before Phase 5: with V3 already live, the accumulator can be
        // pointed at its final target in ONE place below rather than wired to V2 and repointed.
        phlimboV3 = _rehearsePhlimboV3Cutover(deployer);

        // ====== PHASE 7.5: StableYieldAccumulator Configuration ======
        console.log("\n=== Phase 7.5: StableYieldAccumulator Configuration ===");

        // Set reward token to USDC (rewardToken is MockRewardToken which is USDC).
        //
        // STORY 073 — ORDERING IS LOAD-BEARING. yield-accumulator:027 added a conditional guard to
        // setRewardToken: once the nudge path is live (nudgeSplit != 0 && nudgeStreamer != 0 &&
        // nudge != 0) it requires the streamer to already hold a registered stream for the NEW
        // reward token. Calling setRewardToken FIRST — before setNudgeAddress / setNudgeSplit /
        // setNudgeStreamer below — keeps the guard dormant at deploy time. Do not reorder.
        stableYieldAccumulator.setRewardToken(address(rewardToken));
        console.log("Set reward token to USDC:", address(rewardToken));

        // Set Phlimbo as the reward recipient.
        //
        // STORY 079: this is PhlimboV3, not the `phlimbo` (V2) field, mirroring mainnet Phase 5.
        // The stable yield funnel must terminate at the farm users are actually staked in — V2
        // was emptied and wound down in Phase 7.4 above, so feeding it would strand every
        // collected reward in a contract with zero stakers.
        stableYieldAccumulator.setPhlimbo(address(phlimboV3));
        console.log("Set PhlimboV3 as reward recipient:", address(phlimboV3));

        // NOTE: SYA.setMinter() was removed in the stable-yield-accumulator bump
        // (the accumulator no longer tracks the phUSD stable minter directly;
        // yield strategies are registered via addYieldStrategy instead). Call dropped.
        // stableYieldAccumulator.setMinter(address(minter));

        // Configure USDC token (6 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(rewardToken), 6, 1e18);
        console.log("Configured USDC token config (6 decimals, 1:1 rate)");

        // Configure DOLA token (18 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(dola), 18, 1e18);
        console.log("Configured DOLA token config (18 decimals, 1:1 rate)");

        // Add YieldStrategyDola to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyDola), address(dola));
        console.log("Added YieldStrategyDola to yield strategy registry");

        // Add YieldStrategyUSDC to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyUSDC), address(rewardToken));
        console.log("Added YieldStrategyUSDC to yield strategy registry");

        // Set discount rate (20% = 2000 basis points)
        stableYieldAccumulator.setDiscountRate(2000);
        console.log("Set discount rate to 2000 basis points (20%)");

        // Approve Phlimbo to spend reward tokens with max approval
        stableYieldAccumulator.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo to spend reward tokens from StableYieldAccumulator");

        // CRITICAL: Authorize StableYieldAccumulator as withdrawer on all yield strategies
        // This allows StableYieldAccumulator to withdraw yield from the strategies
        yieldStrategyDola.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyDola");

        yieldStrategyUSDC.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyUSDC");

        // Wire nudge config on StableYieldAccumulator (story 045.5)
        //   nudge address first, then split (mirrors mainnet sequence in story 046).
        //   When claim() runs, nudgeSplit% of the discounted USDC payment is forwarded
        //   to the BatchNFTMinter; the remainder goes to Phlimbo as before.
        stableYieldAccumulator.setNudgeAddress(address(batchNFTMinter));
        console.log("SYA.setNudgeAddress ->", address(batchNFTMinter));

        stableYieldAccumulator.setNudgeSplit(MOCK_NUDGE_SPLIT);
        console.log("SYA.setNudgeSplit ->", MOCK_NUDGE_SPLIT);

        // Story 073: sixth and last donor onto the streamer. claim() now PULLS the nudge slice via
        // collectNudge(nudge, rewardToken, nudgeAmount) instead of pushing it straight at the batch
        // minter. Must run after registerStream(batchNFTMinter, USDC) (done in Phase 3.7) and after
        // setRewardToken above, or the first claim() reverts.
        stableYieldAccumulator.setNudgeStreamer(address(nudgeStreamer));
        console.log("SYA.setNudgeStreamer ->", address(nudgeStreamer));
        require(stableYieldAccumulator.nudgeStreamer() == address(nudgeStreamer), "SYA nudgeStreamer not wired");

        // ====== PHASE 7.6: dispatcher-swap cutover rehearsal (script-audit run-26, L-01) ======
        // The local chain rehearsed the cutover's END STATE but never its MECHANICS: before this
        // phase, `hook.pull()`, `hook.setDispatcher()` and `replaceDispatcher()` executed ZERO
        // times locally, so the one cutover ordering whose wrong direction is SILENT rather than
        // loud was also the only one the local mirror never executed. A separate internal helper,
        // not inline: `run()` is at its stack-depth ceiling.
        _rehearseDispatcherSwap(deployer);

        // ====== PHASE 8: Pauser Registration ======
        console.log("\n=== Phase 8: Pauser Registration ===");
        console.log("CRITICAL: setPauser() must be called BEFORE register()");

        // Register PhusdStableMinter with Pauser
        // Step 1: Set pauser address on contract FIRST
        minter.setPauser(address(pauser));
        console.log("PhusdStableMinter.setPauser() called");
        // Step 2: Register with pauser (validates that pauser() == address(this))
        pauser.register(address(minter));
        console.log("Pauser.register(PhusdStableMinter) completed");

        // Register the PhlimboV2 incumbent with Pauser (PhlimboV3 is registered in Phase 7.4)
        // Step 1: Set pauser address on contract FIRST
        phlimbo.setPauser(address(pauser));
        console.log("PhlimboV2.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(phlimbo));
        console.log("Pauser.register(PhlimboV2) completed");

        // Register StableYieldAccumulator with Pauser
        // Step 1: Set pauser address on contract FIRST
        stableYieldAccumulator.setPauser(address(pauser));
        console.log("StableYieldAccumulator.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(stableYieldAccumulator));
        console.log("Pauser.register(StableYieldAccumulator) completed");

        // Register NFTMinterV2 with Pauser
        nftMinterV2.setPauser(address(pauser));
        console.log("NFTMinterV2.setPauser() called");
        pauser.register(address(nftMinterV2));
        console.log("Pauser.register(NFTMinterV2) completed");

        // Register NFTStaker with Pauser
        nftStaker.setPauser(address(pauser));
        console.log("NFTStaker.setPauser() called");
        pauser.register(address(nftStaker));
        console.log("Pauser.register(NFTStaker) completed");

        // Register StableStaker with Pauser (story 052 — fixes story 051's missing pauser wiring)
        // Step 1: Set pauser address on contract FIRST (register() validates pauser() == address(this))
        stableStaker.setPauser(address(pauser));
        console.log("StableStaker.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(stableStaker));
        console.log("Pauser.register(StableStaker) completed");

        console.log("All protocol contracts registered with Pauser");

        // ====== PHASE 8.7: SYA Integration — V2 NFTMinter ======
        console.log("\n=== Phase 8.7: SYA Integration - V2 NFTMinter ===");

        // Set V2 NFTMinter on StableYieldAccumulator
        stableYieldAccumulator.setNFTMinter(address(nftMinterV2));
        console.log("StableYieldAccumulator.setNFTMinter -> NFTMinterV2");

        // Set StableYieldAccumulator as authorized burner on V2 NFTMinter
        nftMinterV2.setAuthorizedBurner(address(stableYieldAccumulator), true);
        console.log("NFTMinterV2.setAuthorizedBurner(StableYieldAccumulator, true)");

        // ====== PHASE 9: Seed YieldStrategyDola with PhUSD Minting ======
        console.log("\n=== Phase 9: Seed YieldStrategyDola with PhUSD Minting ===");

        uint256 dolaAmount = 5000 * 10 ** 18; // 5000 DOLA

        // Deployer already has DOLA from MockDola constructor mint
        // Approve minter to spend deployer's DOLA
        dola.approve(address(minter), dolaAmount);
        console.log("Approved minter to spend 5000 DOLA");

        // Mint PhUSD by depositing DOLA through the minter
        // This will: 1) Transfer DOLA to minter, 2) Deposit DOLA into YieldStrategyDola, 3) Mint PhUSD to deployer
        minter.mint(address(dola), dolaAmount);
        console.log("Minted PhUSD with 5000 DOLA");
        console.log("  - DOLA deposited to YieldStrategyDola");
        console.log("  - PhUSD minted to deployer:", deployer);

        // ====== PHASE 9.5: Add DOLA Yield to MockAutoDOLA Vault ======
        console.log("\n=== Phase 9.5: Add DOLA Yield to MockAutoDOLA Vault ===");

        uint256 yieldAmount = 1000 * 10 ** 18; // 1000 DOLA

        // To create yield, we must transfer DOLA directly to the vault WITHOUT minting shares.
        // This increases totalAssets without increasing totalSupply, raising share price.
        // Using deposit() would mint new shares, keeping share price at 1:1 (no yield).

        // Mint 1000 DOLA directly to the vault address (not to deployer)
        dola.mint(address(mockAutoDola), yieldAmount);
        console.log("Minted 1000 DOLA directly to MockAutoDOLA vault as yield");
        console.log("  - totalAssets increased without minting new shares");
        console.log("  - Share price now > 1, creating claimable yield");
        console.log("  - YieldStrategyDola can claim this yield via ERC4626YieldStrategy");

        // ====== PHASE 9.55: Seed YieldStrategyUSDC with PhUSD Minting ======
        console.log("\n=== Phase 9.55: Seed YieldStrategyUSDC with PhUSD Minting ===");

        uint256 usdcAmount = 5000 * 10 ** 6; // 5000 USDC (6 decimals)

        // Deployer already has USDC from MockRewardToken constructor mint
        // Approve minter to spend deployer's USDC
        rewardToken.approve(address(minter), usdcAmount);
        console.log("Approved minter to spend 5000 USDC");

        // Mint PhUSD by depositing USDC through the minter
        // This will: 1) Transfer USDC to minter, 2) Deposit USDC into YieldStrategyUSDC, 3) Mint PhUSD to deployer
        minter.mint(address(rewardToken), usdcAmount);
        console.log("Minted PhUSD with 5000 USDC");
        console.log("  - USDC deposited to YieldStrategyUSDC");
        console.log("  - PhUSD minted to deployer:", deployer);

        _trackDeployment("UsdcSeeding", address(0), 0);
        _markConfigured("UsdcSeeding", 0);

        // ====== PHASE 9.6: Add USDC Yield to MockAutoUSDC Vault ======
        console.log("\n=== Phase 9.6: Add USDC Yield to MockAutoUSDC Vault ===");

        uint256 usdcYieldAmount = 1000 * 10 ** 6; // 1000 USDC (6 decimals)

        // Mint 1000 USDC directly to the vault address (not to deployer)
        rewardToken.mint(address(mockAutoUSDC), usdcYieldAmount);
        console.log("Minted 1000 USDC directly to MockAutoUSDC vault as yield");
        console.log("  - totalAssets increased without minting new shares");
        console.log("  - Share price now > 1, creating claimable yield");
        console.log("  - YieldStrategyUSDC can claim this yield via ERC4626YieldStrategy");

        // ====== PHASE 10: Deploy DepositView for UI Polling ======
        console.log("\n=== Phase 10: Deploy DepositView for UI Polling ===");

        depositView = new DepositView(IPhlimbo(address(phlimbo)), IERC20(address(phUSD)));
        _trackDeployment("DepositView", address(depositView), 0);
        console.log("DepositView deployed at:", address(depositView));

        // ====== PHASE 11: Deploy ViewRouter + DepositPageView ======
        console.log("\n=== Phase 11: Deploy ViewRouter + DepositPageView ===");

        gasBefore = gasleft();
        viewRouter = new ViewRouter();
        _trackDeployment("ViewRouter", address(viewRouter), gasBefore - gasleft());
        console.log("ViewRouter deployed at:", address(viewRouter));

        gasBefore = gasleft();
        depositPageView = new DepositPageView(IPhlimbo(address(phlimbo)), IERC20(address(phUSD)));
        _trackDeployment("DepositPageView", address(depositPageView), gasBefore - gasleft());
        console.log("DepositPageView deployed at:", address(depositPageView));

        // Register DepositPageView with ViewRouter.
        //
        // STORY 079: registered and then DISPLACED a few lines below by DepositPageViewV3, which
        // is not redundant work — it reproduces mainnet's exact Phase 4f transition (the live
        // router held a V1-baked page and Phase 4f overwrites the key). Keeping the displaced
        // registration here means a regression that drops the V3 setPage shows up locally as the
        // router serving 7-field V1 data, which is what the bug looked like on mainnet, rather
        // than as an unset key that reverts and would be caught by accident.
        viewRouter.setPage(keccak256("deposit"), IPageView(address(depositPageView)));
        console.log("Registered DepositPageView with ViewRouter (WILL BE DISPLACED by V3 below)");

        gasBefore = gasleft();
        mintPageView = new MintPageView(
            INFTMinterView(address(nftMinterV2)),
            burnRecorder,
            address(eyeToken),
            address(mockSCX),
            address(mockFlax),
            address(usds),
            address(mockWBTC),
            address(rewardToken) // usdc — NudgeRatchet's 6-decimal USDC (dispatcher index 7)
        );
        _trackDeployment("MintPageView", address(mintPageView), gasBefore - gasleft());
        console.log("MintPageView deployed at:", address(mintPageView));

        // Register MintPageView with ViewRouter
        viewRouter.setPage(keccak256("mint"), IPageView(address(mintPageView)));
        console.log("Registered MintPageView with ViewRouter under key: keccak256('mint')");

        // ====== PHASE 11.5: DepositPageViewV3 — the read side of the cutover (story 079) ======
        // Local mirror of mainnet Phase 4f. Runs AFTER the Phase 7.4 cutover because the view's
        // `phlimbo` is IMMUTABLE: it must be constructed against the V3 that already exists.
        //
        // NOT A RE-CAST OF THE OLD PAGE. `PhlimboV3.userInfo` returns a 4-tuple where V1/V2
        // returned 3, and Solidity's decoder tolerates the extra trailing returndata — so the old
        // V1-typed page pointed at V3 does not revert, it silently returns undefined-by-accident
        // data with none of the promo fields. That is exactly the failure mode this phase exists
        // to remove, and it is why a separate contract typed against `IPhlimboV3` is required.
        console.log("\n=== Phase 11.5: Deploy DepositPageViewV3 + repoint the deposit page ===");

        gasBefore = gasleft();
        depositPageViewV3 = new DepositPageViewV3(IPhlimboV3(address(phlimboV3)), IERC20(address(phUSD)));
        console.log("DepositPageViewV3 deployed at:", address(depositPageViewV3));
        console.log("  gas:", gasBefore - gasleft());
        // NO `_trackDeployment`. Keyless by design, exactly as on mainnet: `ViewRouter` publishes
        // the page address on-chain, and a second hand-maintained address key is a COMPETING
        // resolution path — the precise duplication that let mainnet's deposit page sit on a
        // stale view unnoticed for months. See extract-addresses.js DROPPED_CONTRACT_NAMES.

        // THE LAST STEP OF THE PHASE, deliberately: until this lands, the router still serves the
        // displaced V1-shaped page registered above.
        viewRouter.setPage(keccak256("deposit"), IPageView(address(depositPageViewV3)));
        require(
            address(viewRouter.pages(keccak256("deposit"))) == address(depositPageViewV3),
            "ViewRouter deposit page did not repoint to DepositPageViewV3"
        );
        console.log("ViewRouter deposit page -> DepositPageViewV3 (displaced the V1-shaped page)");

        // Mark configurations as complete (gas tracking simplified to avoid stack depth issues)
        _markConfigured("MockPhUSD", 0);
        _markConfigured("MockUSDC", 0);
        _markConfigured("MockUSDS", 0);
        _markConfigured("MockSUSDS", 0);
        _markConfigured("USDe", 0);
        _markConfigured("SUSDe", 0);
        _markConfigured("MockDola", 0);
        _markConfigured("MockEYE", 0);
        _markConfigured("MockSCX", 0);
        _markConfigured("MockKendu", 0);
        _markConfigured("MockFlax", 0);
        _markConfigured("MockWBTC", 0);
        _markConfigured("MockAutoDOLA", 0);
        _markConfigured("MockAutoUSDC", 0);
        _markConfigured("YieldStrategyDola", 0);
        _markConfigured("YieldStrategyUSDC", 0);
        _markConfigured("YieldStrategyUSDe", 0);
        _markConfigured("USDeAMMAdapter", 0);
        _markConfigured("PhusdStableMinter", 0);
        _markConfigured("PhlimboEA", 0);
        // Story 079. Configured inside the Phase 7.4 cutover (APY, pauser, phUSD mint grant,
        // migrated user base) rather than in the phases above, but it is a first-class tracked
        // deployment and must appear here or extract-addresses drops it from the interface.
        _markConfigured("PhlimboV3", 0);
        _markConfigured("StableYieldAccumulator", 0);
        _markConfigured("Pauser", 0);
        _markConfigured("MockBalancerPool", 0);
        _markConfigured("MockBalancerVault", 0);
        _markConfigured("BurnRecorder", 0);
        _markConfigured("MockBalancerRouter", 0);
        _markConfigured("NFTMinterV2", 0);
        // Story 070: Uniboost stack (replaced the three burners at indices 1/2/3) + UniV2 infra.
        _markConfigured("UniswapV2Factory", 0);
        _markConfigured("UniswapV2Router02", 0);
        _markConfigured("WETH9", 0);
        _markConfigured("UniboostEYE", 0);
        _markConfigured("UniboostSCX", 0);
        _markConfigured("UniboostFLX", 0);
        _markConfigured("UniboostHookEYE", 0);
        _markConfigured("UniboostHookSCX", 0);
        _markConfigured("UniboostHookFLX", 0);
        _markConfigured("MultiPooler", 0);
        _markConfigured("UniboostStakerEYE", 0);
        _markConfigured("UniboostStakerSCX", 0);
        _markConfigured("UniboostStakerFLX", 0);
        _markConfigured("BalancerPoolerV2", 0);
        _markConfigured("MockWaUSDC", 0);
        _markConfigured("MockSkyPSM", 0);
        _markConfigured("GatherWBTCV2", 0);
        _markConfigured("NudgeRatchet", 0);
        _markConfigured("NudgeRatchetMintDebtHook", 0);
        _markConfigured("BalancerPoolerMintDebtHook", 0);
        _markConfigured("NFTStaker", 0);
        _markConfigured("RatchetNFTStaker", 0);
        _markConfigured("BatchNFTMinter", 0);
        _markConfigured("NudgeStreamer", 0);
        _markConfigured("RatchetBatchNFTMinter", 0);
        _markConfigured("StableStaker", 0);
        _markConfigured("DepositView", 0);
        _markConfigured("ViewRouter", 0);
        _markConfigured("DepositPageView", 0);
        _markConfigured("MintPageView", 0);

        // Track seeding completion
        _trackDeployment("Seeding", address(0), 0);
        _markConfigured("Seeding", 0);
        _trackDeployment("DolaYield", address(0), 0);
        _markConfigured("DolaYield", 0);
        _trackDeployment("UsdcYield", address(0), 0);
        _markConfigured("UsdcYield", 0);

        // ====== TERMINAL: residual-privilege sweep (script-audit run-26, L-04) ======
        // THE LAST STATEMENT BEFORE `stopBroadcast`, deliberately. The script grants the deployer
        // phUSD mint authority three times (`_seedNudgeStream`, `_seedPhlimboV2Position`,
        // `_seedV1Position`) and, before this, never revoked it — while correctly revoking
        // PhlimboV2's grant in the same run. No malicious-owner vector is asserted: this is a mock
        // token on chain 31337 whose deployer key is published in Foundry's own documentation. The
        // cost is purely rehearsal fidelity — "revoke the operational key's temporary grant" is
        // exactly the kind of step that is easy to forget on a Ledger broadcast, and it was the one
        // step the local mirror never exercised.
        _sweepResidualPrivileges(deployer);

        vm.stopBroadcast();

        // ====== Write Progress File ======
        console.log("\n=== Writing Deployment Progress ===");
        _writeProgressFile();

        console.log("\n=== Deployment Complete ===");
        console.log("All contracts deployed and configured successfully!");
        console.log("");
        console.log("Architecture Summary:");
        console.log("  - DOLA -> YieldStrategyDola (ERC4626YieldStrategy) -> PhusdStableMinter");
        console.log("    \\-> ERC4626YieldStrategy wraps MockAutoDOLA (ERC4626 vault)");
        console.log("  - USDC -> YieldStrategyUSDC (ERC4626YieldStrategy) -> PhusdStableMinter");
        console.log("    \\-> ERC4626YieldStrategy wraps MockAutoUSDC (ERC4626 vault)");
        console.log("");
        console.log("StableYieldAccumulator Configuration:");
        console.log("  - Reward token: USDC (MockRewardToken)");
        console.log("  - Discount rate: 20% (2000 basis points)");
        console.log("  - Yield strategies registered: YieldStrategyDola, YieldStrategyUSDC");
        console.log("  - Phlimbo set as reward recipient");
        console.log("  - Minter set for yield queries");
        console.log("  - Authorized as withdrawer on all yield strategies");
        console.log("");
        console.log("Reward Flow:");
        console.log("  - Yield accrues in yield strategies");
        console.log("  - StableYieldAccumulator gathers yield and offers to users for discounted USDC");
        console.log("  - USDC is then injected into Phlimbo via collectReward()");
        console.log("  - Phlimbo distributes rewards to stakers");
        console.log("");
        console.log("Global Pauser System:");
        console.log("  - Pauser contract deployed with MockEYE token");
        console.log("  - PhusdStableMinter registered with Pauser");
        console.log("  - PhlimboV2 and PhlimboV3 registered with Pauser");
        console.log("  - StableYieldAccumulator registered with Pauser");
        console.log("  - StableStaker registered with Pauser");
        console.log("StableStaker: 10% set-aside buffer on all 3 pools (DOLA, USDC, USDe)");
        console.log("  - Burn 1000 EYE to trigger global pause");
        console.log("");
        console.log("Initial Seeding:");
        console.log("  - 5000 DOLA deposited to YieldStrategyDola via minter.mint()");
        console.log("  - Deployer received 5000 PhUSD");
        console.log("  - YieldStrategyDola now has positive balance");
        console.log("");
        console.log("DOLA Yield Seeding:");
        console.log("  - 1000 DOLA deposited directly to MockAutoDOLA vault");
        console.log("  - This increases share value for YieldStrategyDola");
        console.log("  - ERC4626YieldStrategy can claim this yield via StableYieldAccumulator");
        console.log("");
        console.log("USDC Seeding:");
        console.log("  - 5000 USDC deposited to YieldStrategyUSDC via minter.mint()");
        console.log("  - Deployer received 5000 PhUSD");
        console.log("  - YieldStrategyUSDC now has positive balance");
        console.log("");
        console.log("USDC Yield Seeding:");
        console.log("  - 1000 USDC deposited directly to MockAutoUSDC vault");
        console.log("  - This increases share value for YieldStrategyUSDC");
        console.log("  - ERC4626YieldStrategy can claim this yield via StableYieldAccumulator");
        console.log("");
        console.log("NFTMinter Infrastructure:");
        console.log("  - NFTMinter (ERC1155) deployed for claim gating");
        console.log("  - BurnRecorder retained (burn totals now zero on EYE/SCX/Flax)");
        console.log("  - UniboostEYE dispatcher (index 1: boosts EYE/WETH9 UniV2 pool)");
        console.log("  - UniboostSCX dispatcher (index 2: boosts SCX/USDS UniV2 pool)");
        console.log("  - UniboostFLX dispatcher (index 3: boosts FLX/DOLA UniV2 pool)");
        console.log("  - BalancerPooler dispatcher (index 4: sUSDS single-sided add to phUSD/sUSDS pool)");
        console.log("  - GatherWBTC dispatcher (index 5: accumulates WBTC to deployer)");
        console.log("  - StableYieldAccumulator authorized as NFT burner");
        console.log("  - NFTMinter registered with Global Pauser");
        console.log("");
        console.log("Local rehearsal toggles + sweeps (script-audit run-26):");
        console.log("  - LOCAL_PROMO_KENDU (Kendu promo armed on PhlimboV3):", armKenduPromo);
        if (armKenduPromo) {
            console.log("    ARMED leg: promoToken == MockKendu, promoPhase == Active");
            console.log("    Set LOCAL_PROMO_KENDU=false to boot the DORMANT (day-one mainnet) chain");
        } else {
            console.log("    DORMANT leg: promoToken == address(0) - the day-one mainnet shape");
            console.log("    Unset LOCAL_PROMO_KENDU (or set it true) to boot the ARMED chain");
        }
        console.log("  - Phase 7.6: index-1 dispatcher swap rehearsed (pull -> setDispatcher -> setHook -> replaceDispatcher)");
        console.log("  - Terminal sweep: deployer phUSD mint authority REVOKED, end-state ACL asserted");
    }

    // =====================================================================
    // Story 070: Uniboost + Uniswap V2 helpers
    // =====================================================================

    /// @dev Deploys the canonical Uniswap V2 stack (WETH9 + Factory + Router02) and creates +
    ///      seeds the three TARGET pools (EYE/WETH9, SCX/USDS, FLX/DOLA) and three ROUTING pools
    ///      (USDC/WETH9, USDC/USDS, USDC/DOLA). Pairs are created BEFORE the Uniboost dispatchers
    ///      are constructed (their constructor reads pool.token0()/token1()). Routing pools let
    ///      Uniboost.pool() execute its prime(USDC)->pair swap. Seed ratios set the AMM price and
    ///      are INDEPENDENT of the 10-USDC NFT mint price. Chosen seed amounts (documented):
    ///        Target:  EYE/WETH9 100k EYE : 100 WETH9 | SCX/USDS 100k:100k | FLX/DOLA 100k:100k
    ///        Routing: USDC/WETH9 200k USDC : 100 WETH9 | USDC/USDS 200k:200k | USDC/DOLA 200k:200k
    ///      (USDC is 6dp; EYE/SCX/FLX/USDS/DOLA/WETH9 are 18dp.)
    function _deployUniswapAndPools(address deployer) internal {
        uint256 gasBefore = gasleft();
        (weth9, uniFactory, uniRouter) = UniswapV2Deployer.deploy(deployer);
        _trackDeployment("WETH9", weth9, gasBefore - gasleft());
        _trackDeployment("UniswapV2Factory", address(uniFactory), 0);
        _trackDeployment("UniswapV2Router02", address(uniRouter), 0);
        console.log("Uniswap V2 deployed: WETH9", weth9);
        console.log("  Factory", address(uniFactory), "Router02", address(uniRouter));

        // Wrap some native ETH into WETH9 for the two WETH9 pools (100 + 100 = 200 WETH9).
        IWETH9Like(weth9).deposit{value: 300 ether}();

        // Mint mock balances for seeding (generous; dev only).
        eyeToken.mint(deployer, 200_000 ether);
        mockSCX.mint(deployer, 200_000 ether);
        mockFlax.mint(deployer, 200_000 ether);
        usds.mint(deployer, 400_000 ether);
        dola.mint(deployer, 400_000 ether);
        rewardToken.mint(deployer, 600_000 * 10 ** 6); // USDC, 6dp

        // ---- Target pools ----
        poolEYE = _createAndSeed(deployer, address(eyeToken), weth9, 100_000 ether, 100 ether);
        poolSCX = _createAndSeed(deployer, address(mockSCX), address(usds), 100_000 ether, 100_000 ether);
        poolFLX = _createAndSeed(deployer, address(mockFlax), address(dola), 100_000 ether, 100_000 ether);
        _trackDeployment("UniPoolEYE", poolEYE, 0);
        _trackDeployment("UniPoolSCX", poolSCX, 0);
        _trackDeployment("UniPoolFLX", poolFLX, 0);

        // ---- Routing pools (prime USDC -> pair token) ----
        routePoolWETH = _createAndSeed(deployer, address(rewardToken), weth9, 200_000 * 10 ** 6, 100 ether);
        routePoolUSDS = _createAndSeed(deployer, address(rewardToken), address(usds), 200_000 * 10 ** 6, 200_000 ether);
        routePoolDOLA = _createAndSeed(deployer, address(rewardToken), address(dola), 200_000 * 10 ** 6, 200_000 ether);
        _trackDeployment("UniRoutePoolWETH", routePoolWETH, 0);
        _trackDeployment("UniRoutePoolUSDS", routePoolUSDS, 0);
        _trackDeployment("UniRoutePoolDOLA", routePoolDOLA, 0);
        console.log("Seeded 3 target + 3 routing UniV2 pools");
    }

    /// @dev createPair + addLiquidity for one pool, returning the pair address.
    /// @dev Deadline is block.timestamp + 1 hours, NOT a bare block.timestamp: under `--slow`
    ///      broadcast the tx mines a few seconds after the script captures the timestamp, so a bare
    ///      block.timestamp deadline is already in the past at mine time and Router02's
    ///      `ensure(deadline)` reverts ("UniswapV2Router: EXPIRED").
    function _createAndSeed(address deployer, address tokenA, address tokenB, uint256 amtA, uint256 amtB)
        internal
        returns (address pair)
    {
        pair = uniFactory.createPair(tokenA, tokenB);
        IERC20(tokenA).approve(address(uniRouter), amtA);
        IERC20(tokenB).approve(address(uniRouter), amtB);
        uniRouter.addLiquidity(tokenA, tokenB, amtA, amtB, 0, 0, deployer, block.timestamp + 1 hours);
    }

    /// @dev setMinter + authorized-pooler for a uniboost dispatcher (early index-1/2/3 block).
    ///      The ONLY authorized pooler is the MultiPooler batch forwarder; the deployer is
    ///      deliberately NOT whitelisted, so all pooling must go through MultiPooler.pool().
    ///      Requires `multiPooler` to be deployed before this is called.
    function _wireUniboost(Uniboost dispatcher, string memory label) internal {
        dispatcher.setMinter(address(nftMinterV2));
        dispatcher.setAuthorizedPooler(address(multiPooler), true);
        console.log(string.concat(label, ".setMinter + setAuthorizedPooler(multiPooler)"));
    }

    /// @dev Deploys + installs a UniboostMintDebtHook for a dispatcher and authorizes it to mint
    ///      phUSD. primeToken = rewardToken (USDC, 6dp) => hook scale = 1e12. recipient(staker) is
    ///      set later in _deployUniboostStaker. Unlike NudgeRatchet, Uniboost has no hookTypeId
    ///      guard, so the hook installs cleanly.
    function _deployUniboostHook(Uniboost dispatcher, address deployer) internal returns (UniboostMintDebtHook hook) {
        hook = new UniboostMintDebtHook(deployer, address(dispatcher), address(phUSD), address(rewardToken));
        dispatcher.setHook(IDispatchHook(address(hook)));
        phUSD.setMinter(address(hook), true);
    }

    /// @dev Deferred (Phase 3.7) per-dispatcher donation wiring: 50% of mint USDC -> batchNFTMinter
    ///      (the BalancerPoolerV2 index-4 LSP batch minter), remaining 50% retained for pool().
    /// @dev Story 073: the donation branch is now streamer-gated. `Uniboost._dispatch` reverts
    ///      `"Uniboost: nudgeStreamer unset"` whenever `donationAmount > 0` and no streamer is
    ///      wired — i.e. every mint on indices 1/2/3. `setNudgeStreamer` therefore is NOT optional
    ///      polish; it is what keeps these three dispatchers mintable at all. Mandated ordering
    ///      (Uniboost.sol:38-41) is whitelist -> registerStream -> setNudgeStreamer, and the first
    ///      two already ran in `_deployStreamerAndBatchMinter`.
    function _finalizeUniboost(Uniboost dispatcher, UniboostMintDebtHook, address batchMinter, address) internal {
        dispatcher.setRecipient(batchMinter);
        dispatcher.setDonationSplit(50);
        dispatcher.setNudgeStreamer(address(nudgeStreamer));
    }

    // =====================================================================
    // Script-audit run-26, L-01: dispatcher-swap cutover rehearsal (Phase 7.6)
    // =====================================================================

    /// @dev Performs ONE genuine dispatcher swap on index 1 (`uniboostEYE`) in the exact
    ///      fail-closed order the mainnet cutover mandates, with the same assertions.
    ///
    ///      THE ORDERING CONTRACT (`DeployMainnetPromotionReady.s.sol:146-158`), per index:
    ///
    ///          hook.pull() -> hook.setDispatcher(new) -> new.setHook(hook) -> replaceDispatcher(idx, new)
    ///
    ///      During the window between `setDispatcher` and `replaceDispatcher` the OLD dispatcher is
    ///      still on the index but the hook now rejects it (`onDispatch` is gated
    ///      `if (msg.sender != dispatcher) revert OnlyDispatcher()`), so mints on that index REVERT.
    ///      That is the correct failure direction. The reverse order would put the new dispatcher
    ///      live on the index while it still carried the fresh `DefaultDispatchHook` its constructor
    ///      gave it, so mints would SUCCEED while accruing no mint debt — a silent value leak.
    ///      Never do that.
    ///
    ///      THIS PHASE MAKES NO CLAIM THAT THE MAINNET ORDERING IS WRONG. The run-26 finding is
    ///      that `dev` could not tell you either way, because `setDispatcher`, `replaceDispatcher`
    ///      and `hook.pull()` executed ZERO times on the local chain.
    ///
    ///      The hook is REUSED, not redeployed, and no new `phUSD.setMinter` grant is issued —
    ///      hook reuse is the whole point of the exercise, and it is what makes the immutable-scale
    ///      prime-token assertion load-bearing rather than decorative.
    function _rehearseDispatcherSwap(address deployer) internal {
        console.log("\n=== Phase 7.6: Dispatcher-swap cutover rehearsal (script-audit run-26, L-01) ===");

        UniboostMintDebtHook hook = uniboostHookEYE;
        address oldUb = address(uniboostEYE);
        uint256 idx = nftMinterV2.dispatcherToIndex(oldUb);
        require(idx == REHEARSAL_SWAP_INDEX, "rehearsal: UniboostEYE is not on the expected dispatcher index");

        // ---- 0. NON-VACUITY FIRST. ----
        // `pull()` is a NO-OP at zero debt, so a conservation assertion taken across a pull on an
        // empty ledger is trivially true and proves nothing. Drive a real mint through index 1 so
        // the ledger is non-zero at pull time, then gate on it below.
        _accrueIndex1MintDebt(deployer, idx);

        // ---- 1. Snapshot everything the swap must preserve. ----
        uint256 mintDebtBefore = hook.mintDebt();
        require(
            mintDebtBefore > 0,
            "VACUOUS REHEARSAL: uniboost hook mintDebt is zero at pull time, so the conservation assertion below would prove NOTHING - do NOT relax this gate, fix the accrual"
        );
        address recipientBefore = hook.recipient();
        uint8 ratioBefore = hook.ratio();
        uint256 recipientPhusdBefore = phUSD.balanceOf(recipientBefore);
        (, uint256 priceBefore, uint256 growthBefore, bool disabledBefore) = nftMinterV2.configs(idx);

        // ---- 2. pull(), then MINT-DEBT CONSERVATION. ----
        // Non-vacuous by construction: `mintDebtBefore` was just gated above as strictly positive,
        // so the recipient's phUSD balance MUST move by exactly that amount.
        hook.pull();
        require(hook.mintDebt() == 0, "uniboost hook mintDebt != 0 after pull");
        require(
            phUSD.balanceOf(recipientBefore) - recipientPhusdBefore == mintDebtBefore,
            "CONSERVATION FAILED: the phUSD realised by hook.pull() does not equal the mint debt it retired - do NOT relax this gate"
        );
        console.log("  hook.pull() realised NON-ZERO mint debt (phUSD wei):", mintDebtBefore);

        // ---- 3. The replacement, built with the SAME constructor arguments as the incumbent. ----
        Uniboost newUb = new Uniboost(address(rewardToken), address(uniRouter), poolEYE, address(eyeToken), deployer);
        console.log("  replacement UniboostEYE deployed at:", address(newUb));
        _wireUniboost(newUb, "UniboostEYE(replacement)");

        // The hook's `scale` is IMMUTABLE (`10 ** (18 - primeDecimals)`), so a replacement under a
        // reused hook MUST carry the same 6-decimal prime or every future mint inflates the debt by
        // 1e12. Assert BEFORE repointing, mirroring DeployMainnetPromotionReady.s.sol:1475-1479.
        require(
            newUb.primeToken() == address(rewardToken),
            "replacement Uniboost is not USDC-primed (the reused hook's scale is IMMUTABLE)"
        );
        require(rewardToken.decimals() == 6, "USDC (MockRewardToken) decimals != 6");

        // ---- 4. Repoint, in the fail-closed order and no other. ----
        hook.setDispatcher(address(newUb));
        newUb.setHook(IDispatchHook(address(hook)));

        // ---- 5. THE INTERMEDIATE-WINDOW ASSERTION. ----
        // Asserted STRUCTURALLY rather than by a live probe: a reverting call issued while
        // `vm.startBroadcast` is active is recorded into the broadcast bundle and would fail
        // `deploy:local`. This mismatch IS the property that makes a mint on the index revert
        // `OnlyDispatcher()`, and asserting it is deterministic.
        require(hook.dispatcher() == address(newUb), "intermediate window: hook did not repoint to the new dispatcher");
        (address midDispatcher,,,) = nftMinterV2.configs(idx);
        require(
            midDispatcher == oldUb,
            "intermediate window: the index already moved - the fail-closed window was never entered"
        );
        console.log("  intermediate window OK: hook -> NEW dispatcher while the index still carries the OLD one");
        console.log("    a mint on this index right now would revert OnlyDispatcher(). That is the correct direction.");

        // ---- 7. Replace, then read the whole config back. ----
        // `replaceDispatcher` touches NEITHER price NOR growthBasisPoints NOR disabled — which is
        // exactly the claim these assertions pin.
        nftMinterV2.replaceDispatcher(idx, address(newUb));
        (address d, uint256 price, uint256 growth, bool disabled) = nftMinterV2.configs(idx);
        require(d == address(newUb), "configs(idx).dispatcher != the replacement Uniboost");
        require(price == priceBefore && growth == growthBefore, "configs(idx) price/growth not preserved");
        require(disabled == disabledBefore, "configs(idx) disabled flag not preserved");
        require(price < 1e12, "index price is not 6-decimal-shaped");
        console.log("  replaceDispatcher OK; price/growth preserved:", price, growth);

        // ---- 8. Post-swap invariants. ----
        require(address(newUb.hook()) == address(hook), "replacement dispatcher is not carrying the REUSED hook");
        require(hook.recipient() == recipientBefore, "hook recipient changed across the swap");
        require(hook.ratio() == ratioBefore, "hook ratio changed across the swap");
        require(nftMinterV2.dispatcherToIndex(address(newUb)) == idx, "dispatcherToIndex did not move to the replacement");
        require(nftMinterV2.dispatcherToIndex(oldUb) == 0, "dispatcherToIndex still resolves the RETIRED dispatcher");

        // ---- 9. Finalise, so the local chain ends FULLY WORKING (the UI is tested against it). ----
        // The full `_finalizeUniboost` recipe, not a subset: the dispatcher's own `recipient` (the
        // DONATION recipient) is a different field from the hook's `recipient`, and a fresh
        // Uniboost arrives with it unset, which would silently disable the donation branch.
        _finalizeUniboost(newUb, hook, address(batchNFTMinter), deployer);

        // ---- 10. The address book must name the dispatcher that is actually LIVE on the index. ----
        // `deployments[...]` is edited in place rather than re-`_trackDeployment`ed: the latter also
        // pushes onto `contractNames`, which would emit a DUPLICATE key into the progress-file JSON.
        // The key is reused, so no new `_markConfigured` entry is required.
        uniboostEYE = newUb;
        deployments["UniboostEYE"].addr = address(newUb);
        require(deployments["UniboostEYE"].addr == address(newUb), "UniboostEYE address key did not repoint");
        console.log("  UniboostEYE address key repointed to the live index-1 dispatcher:", address(newUb));

        _pinNudgeRatchetStaticClaims();

        console.log("  Phase 7.6 complete: setDispatcher / setHook / replaceDispatcher / pull all EXECUTED locally.");
    }

    /// @dev Makes `uniboostHookEYE.mintDebt()` strictly positive by driving one real mint through
    ///      the index, so the conservation assertion in `_rehearseDispatcherSwap` is non-vacuous.
    ///      The mint routes prime USDC through the Uniboost donation branch, so it doubles as a
    ///      live smoke test that the incumbent dispatcher is still fully wired at this point.
    function _accrueIndex1MintDebt(address deployer, uint256 idx) internal {
        // 2x the current price: `getPrice` grows 0.1% per mint, and the surplus costs nothing on a
        // mock token. `approve` overwrites rather than adds, so no stale allowance accumulates.
        uint256 budget = nftMinterV2.getPrice(idx) * 2;
        rewardToken.mint(deployer, budget);
        rewardToken.approve(address(nftMinterV2), budget);
        require(nftMinterV2.mint(idx, deployer), "rehearsal: index-1 mint returned false");
        console.log("  accrued mint debt via one real index-1 mint; hook.mintDebt() now:", uniboostHookEYE.mintDebt());
    }

    /// @dev The two claims an index-7 swap would have exercised, pinned STATICALLY instead.
    ///      Swapping index 7 would mean re-wiring `RatchetNFTStaker`, `RatchetBatchNFTMinter`, the
    ///      nudge streamer and the target APY on the exact chain the UI is about to be tested
    ///      against; blast radius won. These two assertions regression-gate the claims without a
    ///      swap, so a hook or ratio drift on index 7 still fails the run loudly.
    function _pinNudgeRatchetStaticClaims() internal view {
        require(
            nudgeRatchetHook.hookTypeId() == keccak256("NudgeRatchetMintDebtHook.v1"),
            "index-7 hook typeId drifted: NudgeRatchet._dispatch would revert on every mint"
        );
        require(nudgeRatchetHook.ratio() == 100, "index-7 hook ratio is not the non-default DEFAULT_RATIO of 100");
    }

    // =====================================================================
    // Script-audit run-26, L-04: terminal residual-privilege sweep
    // =====================================================================

    /// @dev Revokes the deployer's phUSD mint authority and then asserts the WHOLE expected
    ///      end-state ACL declaratively, so a future grant that forgets to clean up fails the run
    ///      rather than silently surviving into `local-addresses.ts`.
    ///
    ///      SAFE ONLY AS THE LAST STATEMENT BEFORE `stopBroadcast`. The last deployer-as-minter
    ///      phUSD mint in the whole run is `_seedPhlimboV2Position`, at the START of Phase 7.4;
    ///      everything after that mints through `PhusdStableMinter` (its own grant) or through
    ///      contracts holding their own. `_armLocalKenduPromotion` mints MockKendu, whose `mint` is
    ///      permissionless. A revoke placed before `_seedPhlimboV2Position` would break it.
    function _sweepResidualPrivileges(address deployer) internal {
        console.log("\n=== Terminal: residual-privilege sweep (script-audit run-26, L-04) ===");

        phUSD.setMinter(deployer, false);
        console.log("  phUSD.setMinter(deployer, false) - mint authority REVOKED");

        // The expected end-state ACL, as a table. Any drift names its own offender.
        _requireLiveMinter(deployer, false, "deployer");
        _requireLiveMinter(address(phlimbo), false, "PhlimboV2");
        _requireLiveMinter(address(phlimboV3), true, "PhlimboV3");
        _requireLiveMinter(address(minter), true, "PhusdStableMinter");
        _requireLiveMinter(address(stableStaker), true, "StableStaker");
        _requireLiveMinter(address(balancerPoolerHook), true, "BalancerPoolerMintDebtHook");
        _requireLiveMinter(address(nudgeRatchetHook), true, "NudgeRatchetMintDebtHook");
        _requireLiveMinter(address(uniboostHookEYE), true, "UniboostHookEYE");
        _requireLiveMinter(address(uniboostHookSCX), true, "UniboostHookSCX");
        _requireLiveMinter(address(uniboostHookFLX), true, "UniboostHookFLX");

        console.log("  end-state phUSD ACL asserted: deployer + PhlimboV2 OUT, V3 + minter + staker + 5 hooks IN");
    }

    /// @dev Asserts one row of the end-state phUSD ACL, using the TWO-FIELD idiom. Checking
    ///      `canMint` alone is wrong: `revokeAllMintPrivileges` bumps `mintVersion`, and a minter
    ///      carrying a stale version is refused at mint time despite `canMint == true`
    ///      (MockPhUSD.sol:47-58).
    function _requireLiveMinter(address who, bool expected, string memory label) internal view {
        MockPhUSD.MinterInfo memory info = phUSD.authorizedMinters(who);
        bool isLiveMinter = info.canMint && info.mintVersion == phUSD.mintVersion();
        require(
            isLiveMinter == expected,
            string.concat(
                "RESIDUAL PRIVILEGE SWEEP FAILED: ",
                label,
                " has the wrong phUSD minter status - do NOT relax this gate, fix the grant"
            )
        );
    }

    // =====================================================================
    // Story 073: NudgeStreamer + multi-token batch minter
    // =====================================================================

    /// @dev Deploys the `NudgeStreamer` and replaces the shared `BatchNFTMinter` donor sink with a
    ///      `BatchNFTMinterMultiToken` carrying three nudge-reward tokens (USDC / phUSD / Kendu).
    ///      Extracted from `run()` because `run()` sits at its stack-depth ceiling.
    ///
    ///      THE CALL ORDER BELOW IS MANDATORY, not stylistic:
    ///        1. `setTokenMinter` + `setDispatcherIndex` — `setNudgeTokenWhitelist` runs
    ///           `_resolvePaymentPath()` on every add and reverts
    ///           `BatchMint__MinterNotConfigured` / `BatchMint__DispatcherNotConfigured`
    ///           without them.
    ///        2. whitelist the reward tokens — `NudgeStreamer.registerStream` calls
    ///           `isNudgeToken(token)` and reverts `NudgeStreamer__NotWhitelisted` otherwise.
    ///           (That same call is the structural guard that only a MultiToken batch minter can
    ///           ever be registered with the streamer — a legacy `BatchNFTMinter` has no such view.)
    ///        3. `registerStream` per token.
    ///        4. `setNudgeStreamer` on the batch minter and, later, on all six donors.
    ///
    ///      Local divergence from mainnet, deliberate (story 073 user decision): mainnet registers
    ///      a stream for USDC ONLY, leaving phUSD and Kendu whitelisted-but-unregistered with
    ///      permanently zero rewards. All three are registered here so the UI can render three
    ///      non-zero reward slots. Do not read local behaviour as a prediction of mainnet's.
    function _deployStreamerAndBatchMinter(address deployer) internal {
        uint256 gasBefore = gasleft();
        nudgeStreamer = new NudgeStreamer(deployer);
        _trackDeployment("NudgeStreamer", address(nudgeStreamer), gasBefore - gasleft());
        console.log("NudgeStreamer deployed at:", address(nudgeStreamer));

        gasBefore = gasleft();
        batchNFTMinter = new BatchNFTMinterMultiToken(deployer);
        // Reuse the EXISTING "BatchNFTMinter" tracked key: the address pipeline, mainnet-addresses
        // and the UI all resolve the shared donor sink under that name, and it is still the shared
        // donor sink — only its type changed.
        _trackDeployment("BatchNFTMinter", address(batchNFTMinter), gasBefore - gasleft());
        console.log("BatchNFTMinterMultiToken deployed at:", address(batchNFTMinter));

        // Derive the pinned dispatcher index rather than hard-coding it, so a registration-order
        // change can't silently mis-wire the batch minter.
        uint256 batchDispatcherIndex = nftMinterV2.dispatcherToIndex(address(balancerPoolerV2));
        require(batchDispatcherIndex != 0, "BalancerPoolerV2 not registered with NFTMinterV2");

        // THE SINGLE HIGHEST-RISK LINE IN THIS STORY. `setNudgeTokenWhitelist(token, true)` reverts
        // `BatchMint__RewardTokenIsPaymentToken(token)` when the added token equals the pinned
        // dispatcher's `primeToken()`. Mainnet index 4 is USDS-primed, so USDC is addable there.
        // Locally the pooler derives its prime token from `IERC4626(sUSDS).asset()`, which is USDS
        // — assert it explicitly so a mock rewire fails loudly HERE rather than as a confusing
        // revert three calls later.
        require(
            balancerPoolerV2.primeToken() == address(usds),
            "index-4 prime token must be USDS (else USDC is unwhitelistable)"
        );

        batchNFTMinter.setTokenMinter(ITokenMinterV2(address(nftMinterV2)));
        console.log("BatchNFTMinter.setTokenMinter -> NFTMinterV2");
        batchNFTMinter.setDispatcherIndex(batchDispatcherIndex);
        console.log("BatchNFTMinter.setDispatcherIndex ->", batchDispatcherIndex);

        // `setNudgePaymentToken` does not exist on the multi-token contract — the single-token
        // nudge field is replaced by this ordered whitelist. The ORDER here is the order
        // `batchMint`'s `minRewards` array must use (see `getNudgeTokens()`); unwhitelisting uses
        // swap-and-pop, so callers must re-fetch rather than cache it.
        batchNFTMinter.setNudgeTokenWhitelist(address(rewardToken), true); // USDC (6dp)
        batchNFTMinter.setNudgeTokenWhitelist(address(phUSD), true); // phUSD (18dp)
        batchNFTMinter.setNudgeTokenWhitelist(address(mockKendu), true); // Kendu (18dp)
        require(batchNFTMinter.getNudgeTokens().length == 3, "expected 3 whitelisted nudge tokens");
        console.log("BatchNFTMinter nudge tokens whitelisted: USDC, phUSD, Kendu");

        batchNFTMinter.setNudgeSize(MOCK_NUDGE_SIZE);
        console.log("BatchNFTMinter.setNudgeSize ->", MOCK_NUDGE_SIZE);

        // Story 072 flags the mainnet batch minter as un-pausable (a gap it inherits); close it
        // here. setPauser BEFORE register — register() validates pauser() == address(this).
        batchNFTMinter.setPauser(address(pauser));
        pauser.register(address(batchNFTMinter));
        console.log("BatchNFTMinter registered with Pauser");

        // Streams must exist before any donor is pointed at the streamer, or the first donation
        // reverts. `LOCAL_STREAM_DURATION` is 6 hours by deliberate local divergence.
        nudgeStreamer.registerStream(address(batchNFTMinter), address(rewardToken), LOCAL_STREAM_DURATION);
        nudgeStreamer.registerStream(address(batchNFTMinter), address(phUSD), LOCAL_STREAM_DURATION);
        nudgeStreamer.registerStream(address(batchNFTMinter), address(mockKendu), LOCAL_STREAM_DURATION);
        console.log("NudgeStreamer streams registered for USDC / phUSD / Kendu, duration:", LOCAL_STREAM_DURATION);

        // Seed the two donorless streams. USDC is funded by real donors (Uniboost, the ratchet, the
        // pooler, SYA); phUSD and Kendu have none, so without this the UI renders two permanently
        // empty reward slots and the three-stream divergence buys nothing. `collectNudge` requires
        // a registered stream, hence its position after the registerStream block.
        _seedNudgeStream(deployer, address(phUSD), LOCAL_PHUSD_NUDGE_SEED);
        _seedNudgeStream(deployer, address(mockKendu), LOCAL_KENDU_NUDGE_SEED);

        // Last: the batch minter learns to flush its own accrued stream inside batchMint.
        batchNFTMinter.setNudgeStreamer(address(nudgeStreamer));
        console.log("BatchNFTMinter.setNudgeStreamer -> NudgeStreamer");
    }

    /// @dev Acts as a DONOR of `token` to `batchNFTMinter`'s stream: mints `amount` to the
    ///      deployer, approves the streamer and calls `collectNudge`. This is the local stand-in
    ///      for the organic donors USDC has and phUSD/Kendu do not.
    ///
    ///      Doubles as the fee-on-transfer probe. `collectNudge` does
    ///      `safeTransferFrom(donor, streamer, amount)` and then credits `buffer += amount`
    ///      UNCONDITIONALLY — it never measures what actually landed. A taxed token would
    ///      therefore over-credit the buffer and the stream would run dry mid-window, so the
    ///      balance-delta assertion below is load-bearing, not decorative. The delta is exact
    ///      rather than approximate because the stream was registered moments ago with an empty
    ///      buffer, so `collectNudge`'s pre-settle transfers nothing out.
    function _seedNudgeStream(address deployer, address token, uint256 amount) internal {
        if (token == address(phUSD)) {
            // Local dev only: the deployer needs mint rights to act as a donor of its own.
            phUSD.setMinter(deployer, true);
            phUSD.mint(deployer, amount);
        } else {
            MockKendu(token).mint(deployer, amount);
        }

        uint256 streamerBefore = IERC20(token).balanceOf(address(nudgeStreamer));
        (, uint256 bufferBefore,,) = nudgeStreamer.streams(address(batchNFTMinter), token);

        IERC20(token).approve(address(nudgeStreamer), amount);
        nudgeStreamer.collectNudge(address(batchNFTMinter), token, amount);

        uint256 received = IERC20(token).balanceOf(address(nudgeStreamer)) - streamerBefore;
        require(received == amount, "nudge seed token is fee-on-transfer: streamer received < sent");

        (, uint256 bufferAfter,,) = nudgeStreamer.streams(address(batchNFTMinter), token);
        require(bufferAfter - bufferBefore == amount, "nudge seed did not credit the stream buffer");

        console.log("Seeded nudge stream:", token, amount);
    }

    // =====================================================================
    // Story 079: PhlimboV2 -> MigratorV2V3 -> PhlimboV3 cutover rehearsal
    // =====================================================================

    /// @dev Local mirror of `DeployMainnetPromotionReady._phase4e_phlimboV3Cutover` (story 076),
    ///      step for step, plus the seeding of a user base that mainnet gets for free from live
    ///      stakers. This is the ONLY place the highest-risk phase of the promotion-ready cutover
    ///      can be dry-run for free, and it is the reason the local chain deploys V2 rather than
    ///      V3 directly: an end-state-only deploy would leave the migration itself untested.
    ///
    ///      Deliberately NOT mirrored from mainnet, and each omission is a real difference rather
    ///      than an oversight:
    ///
    ///        * NO `_isDeployed`/`_isConfigured` resume guards. Mainnet's Phase 4e is resumable
    ///          because a Ledger broadcast can die mid-phase and must not re-deploy V3 or re-run
    ///          a completed migration. `deploy:local` is preceded by `clean:local`, which deletes
    ///          the progress file outright — every local run is a FRESH leg by construction, so a
    ///          resume branch here would be dead code that silently rots.
    ///        * NO owner assertions (`owner() == OWNER`). There is one key on anvil.
    ///        * NO snapshot file. Mainnet seeds the migrator from
    ///          `phlimbo-v2-snapshot-latest.json` because PhlimboV2 exposes no staker
    ///          enumeration; here the script created the positions and knows the list.
    ///
    ///      What IS mirrored exactly, because these are the steps that can fail silently:
    ///      the two-step APY commit, the BOTH-SIDES `setMigrator` with read-back, the chunked
    ///      migrate loop, the stake-conservation assertion, and the ordering of the wind-down
    ///      (APY 0 -> revoke migrator -> completeness gate -> revoke mint authority).
    /// @return v3 The `PhlimboV3` the user base was migrated into.
    function _rehearsePhlimboV3Cutover(address deployer) internal returns (PhlimboV3 v3) {
        console.log("\n=== Phase 7.4: PhlimboV2 -> PhlimboV3 cutover rehearsal (story 079) ===");

        // ---- 0. A real multi-user V2 position. Mainnet's Phase 0 asserts this is non-zero. ----
        uint256 preMigrationTotal = _seedPhlimboV2Position(deployer);
        console.log("  V2 migration baseline (totalStaked):", preMigrationTotal);

        // ---- 1. Deploy PhlimboV3, mirroring V2's LIVE config. ----
        // `rewardToken` and `depletionDuration` are read off V2 rather than re-derived from the
        // locals above, exactly as mainnet reads them off the live V2: the rehearsal must
        // exercise the read path, not a parallel source of truth that cannot drift.
        address v2Reward = address(phlimbo.rewardToken());
        uint256 v2Duration = phlimbo.depletionDuration();
        require(v2Duration > 0, "PhlimboV3 ctor requires depletionDuration > 0");
        uint256 gasBefore = gasleft();
        v3 = new PhlimboV3(address(phUSD), v2Reward, v2Duration);
        _trackDeployment("PhlimboV3", address(v3), gasBefore - gasleft());
        console.log("  PhlimboV3 deployed at:", address(v3));
        // A fresh V3 arrives with no promotion armed. `promoToken == address(0)` is the designed
        // dormant state, NOT a misconfiguration — the local chain, like mainnet, ships the
        // cutover with no promotion running.
        require(v3.promoToken() == IERC20(address(0)), "PhlimboV3 arrived with a promo token set");

        // ---- 2/3. Mirror V2's APY. TWO-STEP preview -> commit. ----
        _setDesiredAPYTwoStep(IPhlimboAPYLike(address(v3)), phlimbo.desiredAPYBps(), "PhlimboV3");

        // ---- 4. Pauser wiring, both directions (setPauser BEFORE register, as everywhere). ----
        v3.setPauser(address(pauser));
        pauser.register(address(v3));
        console.log("  PhlimboV3 pauser set + registered with the local Pauser");

        // ---- 5. phUSD mint authority to V3. THE SILENT-FAILURE STEP. ----
        // V3 pays its phUSD reward leg with a try/catch'd mint that BANKS on failure rather than
        // reverting (PhlimboV3.sol:913). Forget this grant and nothing reverts: every staker
        // accrues an unpayable phUSD entitlement while the stable leg keeps paying. Hence the
        // positive read-back rather than a fire-and-forget call.
        phUSD.setMinter(address(v3), true);
        // Read back BOTH fields: `canMint` alone is not proof. `revokeAllMintPrivileges` bumps
        // `mintVersion`, and a minter carrying a stale version is refused at mint time despite
        // `canMint == true` (MockPhUSD.sol:47-58), mirroring the live phUSD.
        MockPhUSD.MinterInfo memory v3Minter = phUSD.authorizedMinters(address(v3));
        require(
            v3Minter.canMint && v3Minter.mintVersion == phUSD.mintVersion(),
            "phUSD.setMinter(PhlimboV3) did not land at the current mintVersion"
        );
        console.log("  phUSD.setMinter(PhlimboV3, true) - mint authority GRANTED");

        // ---- 6..14. The migration and the wind-down. ----
        _runPhlimboV2ToV3Migration(v3, v2Reward, preMigrationTotal);

        // ---- 15. LOCAL ONLY: arm a Kendu promotion. NOT part of the mainnet cutover. ----
        // Sequenced dead last, AFTER the migration, and that ordering is load-bearing rather
        // than cosmetic. `MigratorV2V3.migrateOne` brackets the live `promoToken` balance around
        // each user's withdraw+stake and forwards the delta (MigratorV2V3.sol:241-272); arming
        // the promo first would drag that path into a migration mainnet runs with the slot
        // dormant, so the rehearsal would stop rehearsing the thing it exists to rehearse. It
        // also keeps the `promoToken == address(0)` assertion on the fresh V3 above meaningful.
        //
        // SCRIPT-AUDIT RUN-26, L-03: the CALL SITE is gated, the helper is not. The arming itself
        // is admissible and its four post-condition `require`s stay exactly as they were; the
        // finding was that the DORMANT leg — mainnet's day-one shape — was unreachable. Both legs
        // now assert, so neither is a silent no-op.
        if (armKenduPromo) {
            _armLocalKenduPromotion(deployer, v3);
        } else {
            // Dormant leg: assert the negative, mirroring what story 076 asserts for mainnet.
            require(v3.promoToken() == IERC20(address(0)), "dormant leg: promoToken is not the zero address");
            require(v3.promoRewardBalance() == 0, "dormant leg: promoRewardBalance is not zero");
            console.log("  LOCAL-ONLY: Kendu promotion NOT armed (LOCAL_PROMO_KENDU=false) - DORMANT leg");
            console.log("    this is the day-one mainnet shape: promoToken == address(0)");
        }
    }

    /// @dev LOCAL-ONLY. Arms the Kendu promotion described at `LOCAL_PROMO_KENDU_AMOUNT`. There
    ///      is deliberately no mainnet counterpart to mirror — `DeployMainnetPromotionReady`
    ///      calls `startPromotion` nowhere, and if this helper ever grows one, that is a new
    ///      owner decision and a new story, not a port of this code.
    ///
    ///      Runs while V3 already holds the migrated stake, so `accPromoPerShare` accrues against
    ///      real positions from the first block. The migrated users' `promoDebt` was set against
    ///      `accPromoPerShare == 0` at stake time, so they accrue from zero with no retroactive
    ///      credit — the same shape a post-cutover promotion would have on mainnet.
    function _armLocalKenduPromotion(address deployer, PhlimboV3 v3) internal {
        // `startPromotion` pulls via transferFrom, so the owner must hold and approve first.
        // MockKendu's `mint` is permissionless (local mock), so no minter grant is needed.
        mockKendu.mint(deployer, LOCAL_PROMO_KENDU_AMOUNT);
        IERC20(address(mockKendu)).approve(address(v3), LOCAL_PROMO_KENDU_AMOUNT);

        v3.startPromotion(address(mockKendu), LOCAL_PROMO_KENDU_AMOUNT, LOCAL_PROMO_DURATION);

        // Read the slot back. A promotion that failed to arm leaves every promo field at zero,
        // which is exactly what an unarmed slot looks like — silent, and indistinguishable from
        // the dormant state this call exists to escape.
        require(v3.promoToken() == IERC20(address(mockKendu)), "promo token did not land");
        require(v3.promoPhase() == IPhlimboV3.PromoPhase.Active, "promo phase is not Active");
        require(v3.promoRewardBalance() == LOCAL_PROMO_KENDU_AMOUNT, "promo balance did not land");
        require(v3.promoRewardPerSecond() > 0, "promo rate rounded to zero");

        console.log("  LOCAL-ONLY: Kendu promotion armed on PhlimboV3");
        console.log("    token / amount / duration(s):", address(mockKendu), LOCAL_PROMO_KENDU_AMOUNT, LOCAL_PROMO_DURATION);
        console.log("    promoRewardPerSecond (PRECISION-scaled):", v3.promoRewardPerSecond());
    }

    /// @dev Steps 6-14 of the cutover. Split out of `_rehearsePhlimboV3Cutover` purely to stay
    ///      under the stack-depth ceiling, matching how story 073 split its staker rehearsal.
    function _runPhlimboV2ToV3Migration(PhlimboV3 v3, address v2Reward, uint256 preMigrationTotal)
        internal
    {
        // ---- 6. Deploy MigratorV2V3. Transient: deliberately NEVER `_trackDeployment`d. ----
        // It gets no address key for the same reason mainnet gives it none and story 073 gave
        // the three `NFTStakerMigrator`s none — a one-shot orchestrator is not UI surface.
        //
        // NO phUSD mint role goes to the migrator, unlike its V1->V2 predecessor: V2 itself mints
        // the pending phUSD rewards during `withdraw` (MigratorV2V3.sol:54-56).
        MigratorV2V3 migrator =
            new MigratorV2V3(address(phlimbo), address(v3), address(phUSD), v2Reward);
        console.log("  MigratorV2V3 (transient, untracked) deployed at:", address(migrator));

        // ---- 7. BOTH sides of the migrator pair, then read BOTH back. ----
        // A HALF-MET PAIR IS THE WHOLE POINT OF THIS REHEARSAL. With only one side wired, every
        // per-user body reverts "Not authorized" inside the try/catch, `migrate` emits
        // UserMigrationSkipped for all of them, the pass COMPLETES, and nothing reverts —
        // the cutover reports success having moved nobody (MigratorV2V3.sol:66-71).
        phlimbo.setMigrator(address(migrator));
        v3.setMigrator(address(migrator));
        require(phlimbo.migrator() == address(migrator), "PhlimboV2.setMigrator did not land");
        require(v3.migrator() == address(migrator), "PhlimboV3.setMigrator did not land");
        console.log("  migrator role set on BOTH V2 and V3, both read back");

        // ---- 8. Seed. ----
        // The migration cannot run against a paused V2 and would not fail loudly if it did:
        // `withdraw` is `whenNotPaused`, so a paused V2 surfaces as a pass full of
        // "Pausable: paused" skips that still reports success.
        require(!phlimbo.paused(), "PhlimboV2 is PAUSED - every user would be silently SKIPPED");
        address[] memory users = new address[](3);
        users[0] = PHLIMBO_ACTOR_1;
        users[1] = PHLIMBO_ACTOR_2;
        users[2] = PHLIMBO_ACTOR_3;
        migrator.seedUsers(users);

        // ---- 9. Migrate in chunks until the cursor terminates at -1. ----
        // Bounded loop: `migrate` always advances the cursor by at least one per iteration (a
        // reverting or dust position is skipped, not retried), so `users.length` passes is a
        // hard upper bound and this cannot spin.
        for (uint256 i = 0; i < users.length && migrator.migrateIterator() >= 0; i++) {
            migrator.migrate(PHLIMBO_MIGRATE_CHUNK);
            console.log("  migrate pass done; V3 totalStaked now:", v3.totalStaked());
        }
        require(migrator.migrateIterator() == -1, "migration pass did not complete");

        // ---- 10. Stake conservation. `>=`, not `==`. ----
        // V3 may legitimately hold MORE than the baseline (a direct stake between the baseline
        // read and here); it may never hold less, which is the failure that matters.
        require(
            v3.totalStaked() >= preMigrationTotal,
            "CONSERVATION FAILED: PhlimboV3.totalStaked is below the pre-migration PhlimboV2 baseline"
        );
        console.log("  stake conserved into V3:", v3.totalStaked());

        // ---- 11. Wind V2 down. An APY of 0, NOT a pause. TWO-STEP, like every APY set. ----
        // Pausing V2 would trap the late stakers this wind-down is designed to let out.
        _setDesiredAPYTwoStep(IPhlimboAPYLike(address(phlimbo)), 0, "PhlimboV2");

        // ---- 12. Revoke the migrator role now the pass is done. ----
        phlimbo.setMigrator(address(0));
        require(phlimbo.migrator() == address(0), "PhlimboV2 migrator revoke did not land");
        console.log("  PhlimboV2.setMigrator(0) - migrator role revoked");

        // ---- 13. THE COMPLETENESS GATE. ----
        // Mainnet fails the entire cutover here rather than downgrading to a skip-the-revoke
        // branch, and so does the rehearsal: locally every seeded position is well above
        // MINIMUM_STAKE and freshly created, so a non-zero residue can only mean the wiring or
        // the migrator itself is broken — exactly what this run exists to detect BEFORE mainnet.
        require(
            phlimbo.totalStaked() == 0,
            "REHEARSAL INCOMPLETE: PhlimboV2 still holds stake after the migration passes - read the UserMigrationSkipped reasons; do NOT relax this gate"
        );
        console.log("  completeness gate: PhlimboV2.totalStaked() == 0");

        // ---- 14. Revoke V2's phUSD mint authority. AFTER 11 and AFTER 13, never before. ----
        // Safe only because of those two: with totalStaked == 0 no position's `_claimRewards` can
        // reach V2's BARE, REVERTING `phUSD.mint` (PhlimboV2.sol:495), and with desiredAPYBps == 0
        // a post-cutover staker accrues zero pending phUSD and can still exit cleanly.
        phUSD.setMinter(address(phlimbo), false);
        console.log("  phUSD.setMinter(PhlimboV2, false) - mint authority REVOKED");

        console.log("  Cutover rehearsal complete. V2 wound down and mint-revoked; NOT paused.");
    }

    /// @dev Creates the multi-user PhlimboV2 position the migration moves. This is the local
    ///      stand-in for mainnet's live user base, which a single-key broadcast script cannot
    ///      otherwise produce.
    ///
    ///      `stake(amount, user)` is `msg.sender == user || msg.sender == migrator`, so the
    ///      deployer is TEMPORARILY installed as V2's migrator to stake on the actors' behalf and
    ///      is replaced by the real `MigratorV2V3` in `_runPhlimboV2ToV3Migration` — the same
    ///      idiom story 073 used to seed its V1 depletion staker. The resulting on-chain state
    ///      (three non-zero `userInfo` entries) is identical to three separately-signed stakes.
    /// @return preMigrationTotal `phlimbo.totalStaked()` immediately after seeding.
    function _seedPhlimboV2Position(address deployer) internal returns (uint256 preMigrationTotal) {
        address[3] memory actors = [PHLIMBO_ACTOR_1, PHLIMBO_ACTOR_2, PHLIMBO_ACTOR_3];
        uint256 total = PHLIMBO_REHEARSAL_STAKE * actors.length;

        // The deployer is authorised as a phUSD minter for local dev so the rehearsal mints its
        // own stake budget rather than competing with the seeded protocol balances.
        phUSD.setMinter(deployer, true);
        phUSD.mint(deployer, total);
        phUSD.approve(address(phlimbo), total);

        phlimbo.setMigrator(deployer);
        for (uint256 i = 0; i < actors.length; i++) {
            phlimbo.stake(PHLIMBO_REHEARSAL_STAKE, actors[i]);
        }

        preMigrationTotal = phlimbo.totalStaked();
        require(preMigrationTotal == total, "rehearsal: V2 seeding did not land the full stake");
    }

    /// @dev `setDesiredAPY` is a two-step preview -> commit on BOTH V2 and V3
    ///      (PhlimboV3.sol:261-280, PhlimboV2.sol:172-190): the first call only records
    ///      `pendingAPYBps`; the value commits on a SECOND call with the IDENTICAL bps within 100
    ///      blocks. A script that calls it once has silently done nothing.
    ///
    ///      Both a value read-back AND an `apySetInProgress` read-back, because the value alone
    ///      is not enough: setting an APY to the value it already holds (the local case — V2 sits
    ///      at 0 and V3 mirrors it) leaves `desiredAPYBps` correct after the PREVIEW call alone,
    ///      so a value-only assertion would pass on a half-done set. Only the commit branch
    ///      clears the latch.
    ///
    ///      Takes `IPhlimboAPYLike` rather than a concrete type because V2 and V3 are unrelated
    ///      Solidity types with identical admin surfaces — the same shim mainnet's Phase 4e uses.
    function _setDesiredAPYTwoStep(IPhlimboAPYLike p, uint256 bps, string memory label) internal {
        p.setDesiredAPY(bps); // preview
        vm.roll(block.number + 1);
        p.setDesiredAPY(bps); // commit
        require(p.desiredAPYBps() == bps, "APY commit did not land");
        require(!p.apySetInProgress(), "APY still in preview - the commit call was treated as a new preview");
        console.log(string.concat("  ", label, " desired APY committed (bps):"), bps);
    }

    // =====================================================================
    // Story 073: V1 -> migrator -> V2 depletion-staker migration rehearsal
    // =====================================================================

    /// @dev Deploys the V1 Uniboost staker exactly as before, seeds it with a real multi-user
    ///      staked position, then runs the COMPLETE `NFTStakerMigrator` sequence so the local chain
    ///      ends on `NFTStakerDepletionV2` with migrated balances. This exists because story 072's
    ///      mainnet Phase 6 is its riskiest, least-exercised phase and this is the only place it
    ///      can be dry-run for free.
    /// @return v2 The `NFTStakerDepletionV2` the position was migrated into. This is what gets
    ///         tracked under the existing `UniboostStaker*` key; the V1 staker and the migrator are
    ///         transient rehearsal artifacts and are never tracked (mirroring story 072's
    ///         "no interface keys for migrators" rule).
    function _rehearseStakerMigration(
        Uniboost dispatcher,
        UniboostMintDebtHook hook,
        address deployer,
        string memory label
    ) internal returns (NFTStakerDepletionV2 v2) {
        uint256 idx = nftMinterV2.dispatcherToIndex(address(dispatcher));
        require(idx != 0, "Uniboost dispatcher not registered");

        // ---- 1. V1, exactly as deployed today ----
        NFTStakerDepletion v1 = _deployUniboostStaker(dispatcher, hook, deployer);

        // ---- 2. Real reward budget + a real multi-user staked position ----
        uint256 preMigrationTotal = _seedV1Position(v1, idx, deployer);
        console.log(string.concat("[", label, "] V1 rehearsal staked total:"), preMigrationTotal);

        // ---- 3. V2, IDENTICAL constructor args ----
        v2 = new NFTStakerDepletionV2(
            IERC1155(address(nftMinterV2)), idx, IERC20(address(phUSD)), deployer, INFTSupply(address(nftMinterV2)), idx
        );
        v2.setDepletionWindow(12);
        v2.setPauser(address(pauser));
        pauser.register(address(v2));

        // ---- 4-9. The migration itself ----
        _runStakerMigration(v1, v2, hook, idx, deployer);

        // ---- 10. Post-conditions ----
        require(v1.totalStaked() == 0, "rehearsal: V1 still holds stake");
        require(v2.totalStaked() == preMigrationTotal, "rehearsal: V2 total != pre-migration total");
        require(phUSD.balanceOf(address(v2)) > 0, "rehearsal: V2 has no reward budget");
        console.log(string.concat("[", label, "] migration rehearsal OK -> V2 at"), address(v2));
    }

    /// @dev Mints three NFTs of `idx` to the deployer and credits them to three DISTINCT mock
    ///      actors, so `migrator.migrate(users)` operates on a genuine multi-user list.
    ///
    ///      `depositFor` is `onlyMigrator`, so the deployer is TEMPORARILY installed as the
    ///      migrator for the seeding and replaced by the real `NFTStakerMigrator` in
    ///      `_runStakerMigration`. This is the local stand-in for three separately-signed user
    ///      `stake()` calls, which a single-key broadcast script cannot produce; the resulting
    ///      on-chain state (three non-zero `userInfo` entries) is identical.
    /// @return preMigrationTotal `v1.totalStaked()` immediately after seeding.
    function _seedV1Position(NFTStakerDepletion v1, uint256 idx, address deployer)
        internal
        returns (uint256 preMigrationTotal)
    {
        // Reward budget. The deployer is authorised as a phUSD minter for local dev so the
        // rehearsal does not have to compete with the seeded protocol balances.
        phUSD.setMinter(deployer, true);
        phUSD.mint(deployer, REHEARSAL_STAKER_BUDGET);
        phUSD.approve(address(v1), REHEARSAL_STAKER_BUDGET);
        v1.topUp(REHEARSAL_STAKER_BUDGET);

        // Mint three NFTs of this dispatcher's id. Each mint routes prime USDC through the
        // Uniboost donation branch, so this doubles as a live smoke test that setNudgeStreamer
        // landed (an unwired streamer reverts the mint outright).
        uint256 budget = nftMinterV2.getPrice(idx) * 6; // generous: price grows 0.1% per mint
        rewardToken.mint(deployer, budget);
        rewardToken.approve(address(nftMinterV2), budget);
        nftMinterV2.mint(idx, deployer);
        nftMinterV2.mint(idx, deployer);
        nftMinterV2.mint(idx, deployer);

        address[3] memory actors = [REHEARSAL_ACTOR_1, REHEARSAL_ACTOR_2, REHEARSAL_ACTOR_3];
        nftMinterV2.setApprovalForAll(address(v1), true);
        v1.setMigrator(deployer);
        for (uint256 i = 0; i < 3; i++) {
            v1.depositFor(actors[i], 1);
        }
        nftMinterV2.setApprovalForAll(address(v1), false);

        preMigrationTotal = v1.totalStaked();
        require(preMigrationTotal == 3, "rehearsal: expected 3 staked units on V1");
    }

    /// @dev Steps 4-9 of the rehearsal. Split out of `_rehearseStakerMigration` purely to stay
    ///      under the stack-depth ceiling.
    ///
    ///      TWO DEVIATIONS FROM THE STORY'S LITERAL STEP ORDER, both forced by the contracts and
    ///      both recorded in the story's Autonomous Decisions section:
    ///
    ///      (a) `v1.pause()` is `onlyPauser`, and V1's pauser is the GLOBAL `Pauser`, whose
    ///          `pause()` burns EYE and pauses every registered contract. A global pause is not an
    ///          acceptable end state for a dev chain, so V1's pauser is repointed to the deployer
    ///          and V1 is unregistered from the global Pauser first. The unregister is mandatory,
    ///          not tidiness: leaving a contract registered whose `pauser` is no longer the Pauser
    ///          would make a later global `Pauser.unpause()` revert for everyone.
    ///
    ///      (b) The budget move happens AFTER `initiateMigration`, and moves strictly less than the
    ///          full balance. `rescueERC20` requires the post-transfer balance still covers
    ///          `committedDebt`, and `_exitPosition` -> `_safePayTo` requires the balance to cover
    ///          each user's frozen pending. Rescuing the FULL balance (the story's literal step 7)
    ///          therefore reverts as soon as any accrual exists — which it always does, since
    ///          `--slow` puts seconds between the seeding and the migration.
    ///
    ///          ORDERING IS THE FINDING THE REHEARSAL EXISTS TO PRODUCE: settle and freeze
    ///          (`initiateMigration`) BEFORE moving the budget, so `committedDebt` is final rather
    ///          than still growing under the transfer. Story 072's mainnet Phase 6 must apply that
    ///          correction.
    ///
    ///          SIZING IS NOT THE FINDING, AND IS NOT SOLVED HERE. This rehearsal moves a flat 90%
    ///          of the seeded budget — a script-local expedient forced by forge's simulate-then-
    ///          replay model, explained at the `movable` line below. It is NOT `balance -
    ///          committedDebt`, it is not exact, and it leaves an arbitrary 10% stranded in V1.
    ///          Story 072 inherits the question of how much a mainnet migration should move as
    ///          OPEN. Do not read this 90% as a validated answer; the rehearsal proves nothing
    ///          about sizing.
    function _runStakerMigration(
        NFTStakerDepletion v1,
        NFTStakerDepletionV2 v2,
        UniboostMintDebtHook hook,
        uint256 idx,
        address deployer
    ) internal {
        NFTStakerMigrator migrator = new NFTStakerMigrator(
            INFTStakerMigratable(address(v1)),
            INFTStakerMigratable(address(v2)),
            IERC1155(address(nftMinterV2)),
            idx,
            IERC20(address(phUSD)),
            deployer
        );

        // BOTH sides, or the pair is half-met: V1 needs it for initiateMigration/batchMigrate,
        // V2 needs it for depositFor.
        v1.setMigrator(address(migrator));
        v2.setMigrator(address(migrator));

        // MANDATORY. V1's `stake` is ungated during `Migrating` (audit-20 M-05), so a
        // permissionless stake mid-migration wedges `finalizeAndReset`'s
        // `require(totalStaked == 0)`. V2 fixed this; V1 relies on the pause-before-migrate
        // operational remedy. See deviation (a) above for why the pauser is repointed first.
        v1.setPauser(deployer);
        pauser.unregister(address(v1));
        v1.pause();

        // Settle + freeze BEFORE moving the budget — see deviation (b) above.
        migrator.initiateMigration();

        // The moved amount is a CONSTANT FRACTION of the seeded budget, deliberately NOT
        // `balanceOf(v1) - committedDebt()`. A forge script builds its calldata during the
        // simulation pass, where every rehearsal tx shares one block timestamp and
        // `committedDebt` is therefore 0; the broadcast then replays that baked-in number
        // against a `--slow` chain where seconds have elapsed and `committedDebt > 0`, and
        // `rescueERC20` reverts "NFTStaker: rescue breaches committedDebt". Any on-chain-state-
        // dependent amount has the same defect. 90% is safe by a wide margin: over a 12-month
        // depletion window a few seconds of accrual is ~1e-7 of the budget, so the 10% left
        // behind covers every departing user's frozen pending many times over.
        uint256 movable = (REHEARSAL_STAKER_BUDGET * 90) / 100;
        v1.rescueERC20(IERC20(address(phUSD)), deployer, movable);
        phUSD.approve(address(v2), movable);
        v2.topUp(movable);

        address[] memory users = new address[](3);
        users[0] = REHEARSAL_ACTOR_1;
        users[1] = REHEARSAL_ACTOR_2;
        users[2] = REHEARSAL_ACTOR_3;
        migrator.migrate(users);

        // Repoint the mint-debt hook at V2 and complete the two-sided wiring, or every subsequent
        // dispatch would keep funding the abandoned V1.
        hook.setRecipient(address(v2));
        v2.setDispatcherHook(IUniboostMintDebtHook(address(hook)));
    }

    /// @dev Deploys the uniboost staker (NFTStakerDepletion), wires it to the dispatcher hook, sets
    ///      the hook recipient to the staker, configures the depletion window, and registers with
    ///      the local Pauser. NFTStakerDepletion has NO setTargetAPY (depletion-budget model);
    ///      the window is owner-set and the per-second rate is budget/windowSeconds. stakedId ==
    ///      dispatcherIndex (NFTMinterV2 mints tokenId == index); resolve the index dynamically.
    function _deployUniboostStaker(Uniboost dispatcher, UniboostMintDebtHook hook, address deployer)
        internal
        returns (NFTStakerDepletion staker)
    {
        uint256 idx = nftMinterV2.dispatcherToIndex(address(dispatcher));
        require(idx != 0, "Uniboost dispatcher not registered");
        staker = new NFTStakerDepletion(
            IERC1155(address(nftMinterV2)), idx, IERC20(address(phUSD)), deployer, INFTSupply(address(nftMinterV2)), idx
        );
        staker.setDispatcherHook(IUniboostMintDebtHook(address(hook)));
        // pull() is onlyOwnerOrRecipient; the staker must be the hook's recipient to sweep mint debt.
        hook.setRecipient(address(staker));
        // Depletion window = 12 months (one APY-year analogue). Bounded 1..120. Budget is refilled
        // by the hook's pull() on dispatch; rate = budget/windowSeconds. Deliberate, non-default.
        staker.setDepletionWindow(12);
        // Register with the local Pauser like the index-4 NFTStaker (setPauser BEFORE register).
        staker.setPauser(address(pauser));
        pauser.register(address(staker));
    }

    /**
     * @dev Deploy a BatchNFTMinter pinned to a single dispatcher, with the nudge feature left
     *      DISABLED (nudgeSize=0, nudgePaymentToken=address(0) — the constructor defaults, never
     *      touched). Pure batch looper: it holds no funds, so no nudge/reward wiring is needed and
     *      none of the nudge-pot drain surface applies. The dispatcher index is derived from the
     *      registered dispatcher (reverts if unregistered), and the payment token is derived at
     *      batchMint time from the dispatcher's primeToken() — never a caller-supplied parameter.
     */
    function _deployNudgelessBatchMinter(address dispatcher, string memory trackName, address deployer)
        internal
        returns (BatchNFTMinter batchMinter)
    {
        uint256 idx = nftMinterV2.dispatcherToIndex(dispatcher);
        require(idx != 0, "batch minter: dispatcher not registered");
        uint256 gasBefore = gasleft();
        batchMinter = new BatchNFTMinter(deployer);
        _trackDeployment(trackName, address(batchMinter), gasBefore - gasleft());
        // Pin the trusted minter + dispatcher index so batchMint is enabled. Without these,
        // batchMint reverts BatchMint__MinterNotConfigured / BatchMint__DispatcherNotConfigured.
        batchMinter.setTokenMinter(ITokenMinterV2(address(nftMinterV2)));
        batchMinter.setDispatcherIndex(idx);
        console.log(string.concat(trackName, " deployed + wired (index ", vm.toString(idx), "):"), address(batchMinter));
    }

    /**
     * @dev Track contract deployment
     */
    function _trackDeployment(string memory name, address addr, uint256 gas) internal {
        deployments[name] = ContractDeployment({
            name: name, addr: addr, deployed: true, configured: false, deployGas: gas, configGas: 0
        });
        contractNames.push(name);
    }

    /**
     * @dev Mark contract as configured
     */
    function _markConfigured(string memory name, uint256 gas) internal {
        deployments[name].configured = true;
        deployments[name].configGas = gas;
    }

    /**
     * @dev Write progress file in JSON format
     */
    function _writeProgressFile() internal {
        string memory json = "{";
        json = string.concat(json, '"chainId": 31337,');
        json = string.concat(json, '"networkName": "anvil",');
        json = string.concat(json, '"deploymentStatus": "completed",');
        json = string.concat(json, '"contracts": {');

        for (uint256 i = 0; i < contractNames.length; i++) {
            string memory name = contractNames[i];
            ContractDeployment memory deployment = deployments[name];

            if (i > 0) json = string.concat(json, ",");

            json = string.concat(json, '"', name, '": {');
            json = string.concat(json, '"address": "', vm.toString(deployment.addr), '",');
            json = string.concat(json, '"deployed": ', deployment.deployed ? "true" : "false", ",");
            json = string.concat(json, '"configured": ', deployment.configured ? "true" : "false", ",");
            json = string.concat(json, '"deployGas": ', vm.toString(deployment.deployGas), ",");
            json = string.concat(json, '"configGas": ', vm.toString(deployment.configGas));
            json = string.concat(json, "}");
        }

        json = string.concat(json, "}}");

        // Write to server/deployments/progress.31337.json
        vm.writeFile("server/deployments/progress.31337.json", json);
        console.log("Progress file written to: server/deployments/progress.31337.json");
    }
}
