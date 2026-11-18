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
import "../src/mocks/MockSDOLA.sol"; // story 089: destination DOLA vault (sDOLA stand-in)
import "../src/mocks/MockSUSDS.sol";
import "../src/mocks/MockEYE.sol";
import "../src/mocks/MockSCX.sol";
import "../src/mocks/MockKendu.sol";
import "../src/mocks/MockFlax.sol";
import "../src/mocks/MockWBTC.sol";
import "../src/mocks/MockERC4626Wrapper.sol";
import "../src/mocks/MockSkyPSM.sol";
import "../src/mocks/MockMarketAMMAdapter.sol";
// PhlimboV3 is the ONLY phlimbo generation the local chain carries. V1 (`PhlimboEA`) and V2
// were both retired here once their mainnet cutovers had executed: a local chain that deploys a
// superseded generation just to migrate off it again is rehearsing a migration that can no
// longer happen. The V2 -> V3 cutover ran on mainnet via `MigratorV2V3`; nothing local mirrors
// it any more.
import {PhlimboV3} from "@phlimbo-ea/PhlimboV3.sol";
import {IPhlimboV3} from "@phlimbo-ea/interfaces/IPhlimboV3.sol";
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
// Story 136: PauserV2 is the ONLY pauser on this chain (DeployMocks Phase 11.16 end state, constructed
// directly). Pauser V1 is never deployed here, so its import is gone.
import {PauserV2} from "@pauser/PauserV2.sol";
import {PauserV2LocalMigration} from "./helpers/PauserV2LocalMigration.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "../src/views/ViewRouter.sol";
import {DepositPageViewV3} from "../src/views/DepositPageViewV3.sol";
import {MintPageView} from "../src/views/MintPageView.sol";
// V1 INFTMinter removed (yield-claim-nft story-039). MintPageView's constructor takes the V2
// interface; alias it the same way the rest of the file expects (INFTMinterView).
import {INFTMinterV2 as INFTMinterView} from "@yield-claim-nft/interfaces/INFTMinterV2.sol";
import {BurnRecorder} from "@yield-claim-nft/BurnRecorder.sol";
import {NFTMinterV2} from "@yield-claim-nft/NFTMinterV2.sol";
import {ITokenMinterV2} from "@yield-claim-nft/interfaces/ITokenMinterV2.sol";
// Story 104 (Balancexit Stage 3): index 4 is UniPoolerV2, deployed DIRECTLY against a fresh
// mock-token phUSD/sUSDS Uniswap V2 pair. No Balancer mock, no Balancer pooler, no cutover.
import {UniPoolerV2} from "@yield-claim-nft/dispatchers/UniPoolerV2.sol";
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
import {BatchNFTMinter} from "nft-staking/BatchNFTMinter.sol";
import {INFTSupply} from "nft-staking/INFTSupply.sol";
// Story 073: the streamer-era contract set (mirrors the mainnet cutover planned in story 072).
import {NudgeStreamer} from "nft-staking/NudgeStreamer.sol";
// Story 137: the multi-token minter (`BatchNFTMinterMultiToken`) is no longer deployed on this chain.
// `BatchNFTMinterNudgeDiscount` is the ONLY donor sink, wired as the mainnet cutover wires it.
import {BatchNFTMinterNudgeDiscount} from "nft-staking/BatchNFTMinterNudgeDiscount.sol";
import {ISkyPSM as INudgeDiscountPSM} from "nft-staking/interfaces/ISkyPSM.sol";
import {IMintDebtRatio} from "nft-staking/interfaces/IMintDebtRatio.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {NFTStakerDepletionV2} from "nft-staking/NFTStakerDepletionV2.sol";
// Story 070: canonical Uniswap V2 (WETH9 + Factory + Router02) deployer + interfaces.
import {
    UniswapV2Deployer,
    IUniswapV2FactoryLike,
    IUniswapV2RouterLike,
    IWETH9Like
} from "./helpers/UniswapV2Deployer.sol";
// Story 098: StableStakerV2 is deployed DIRECTLY. There is no StableStakerV1 on this chain and
// therefore no CrossVersionMigrator: the V1 -> V2 cutover rehearsal DeployMocks carries is a
// local-only dress rehearsal of a mainnet cutover that has already executed. `IAntimatter` is
// StableStakerV2's own local view of the token, which is what its constructor takes; the concrete
// `Antimatter` comes from the antimatter submodule.
import {StableStakerV2} from "stable-staker/StableStakerV2.sol";
import {IAntimatter} from "stable-staker/interfaces/IAntimatter.sol";
import {Antimatter} from "antimatter/Antimatter.sol";
// StableStaker's constructor takes the flax-token-v2 IFlax; alias to avoid an
// identifier clash with phlimbo-ea's IFlax which is already in scope transitively.
import {IFlax as IFlaxStaker} from "flax-token/IFlax.sol";
import {IYieldStrategy} from "reflax-yield-vault/interfaces/IYieldStrategy.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Story 136: NFTBonfire (DeployMocks Phase 11.15), deployed and wired through the SAME library
// DeployMocks and test/NFTBonfireLocalWiring.t.sol use.
import {NFTBonfire} from "@yield-claim-nft/NFTBonfire.sol";
import {NFTBonfireLocalWiring} from "./helpers/NFTBonfireLocalWiring.sol";

/**
 * @notice Phlimbo's two-step APY admin surface. Byte-identical to the shim in
 *         `DeployMainnetPromotionReady.s.sol` so the local `_setDesiredAPYTwoStep` and the
 *         mainnet one are the same code operating through the same interface. Introduced when
 *         one call site had to drive both PhlimboV2 and PhlimboV3, which are unrelated Solidity
 *         types; retained after V2's retirement because it keeps the two commit read-backs with
 *         the setter.
 */
/// @notice The three pair reads the story-104 index-4 read-backs need. Declared locally so this
///         script does not import the cutover core (and, through it, the escrow) just for a view.
interface ISepoliaUniV2PairLike {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Story 136: the one getter every Phoenix pausable exposes, for the PauserV2 end-state sweep.
interface IPausableSepoliaLike {
    function pauser() external view returns (address);
}

interface IPhlimboAPYLike {
    function setDesiredAPY(uint256 bps) external;
    function desiredAPYBps() external view returns (uint256);
    /// @dev The preview/commit latch. True after a preview, cleared by the commit — which is
    ///      what makes it a non-vacuous proof that the commit branch actually ran, even when
    ///      the target value is 0 and the value read-back proves nothing.
    function apySetInProgress() external view returns (bool);
}

/**
 * @title DeployMocksSepolia
 * @notice Fresh, full-surface deployment of the current Phase 2 contract set onto Sepolia
 *         (chainId 11155111), all backed by MOCK tokens. Story 098.
 *
 * @dev ORIGIN. A standalone copy derived from `script/DeployMocks.s.sol` (the local anvil
 *      script) as of phStaging2 `24408e9`. It is NOT a shared base: DeployMocks is untouched and
 *      the local flow (`npm run dev`, `deploy:local`) behaves exactly as before. The cost is drift —
 *      when DeployMocks changes, this file must be re-derived by hand.
 *
 *      WHAT WAS DROPPED vs DeployMocks, and why:
 *        - anvil-only gates: `ANVIL_PRIVATE_KEY`, `require(chainid == 31337)` and the fresh-anvil
 *          `vm.getNonce(deployer) == 0` gate. The Sepolia deployer key has history, so the nonce
 *          gate would always fail; it is replaced by a Sepolia chain-id gate.
 *        - `vm.roll` in `_setDesiredAPYTwoStep`. PhlimboV3 commits on a second IDENTICAL call
 *          within 100 blocks (`PhlimboV3.setDesiredAPY`), so two `--slow` txs in consecutive
 *          blocks commit without the roll. Both post-commit read-backs are kept.
 *        - the 300-ETH WETH wrap: WETH-side UniV2 seeds are faucet-sized and env-configurable
 *          (`SEPOLIA_WETH_SEED`, default 0.1 ether total), token sides scaled to keep DeployMocks'
 *          prices. `addLiquidity` uses a `type(uint256).max` deadline because on a slow public
 *          broadcast the simulation timestamp can be stale by the time the tx is included.
 *        - StableStakerV1 -> V2 CUTOVER REHEARSAL (story 080): no V1 deploy/wiring, no V1 Pauser
 *          registration, no CrossVersionMigrator, no keccak mock stakers. Antimatter +
 *          StableStakerV2 are deployed and wired directly into the end state DeployMocks reaches
 *          after its cutover (client + 10% set-aside buffer + buffer recipient on all three
 *          strategies, Pauser-registered, phUSD shortfall-cover grant, antimatterPerDay rates).
 *        - Phase 9.7 DOLA REPOINT REHEARSAL (story 089): DOLA is registered on the minter and on
 *          SYA directly against `YieldStrategyDola` (the sDOLA strategy) from the start, with the
 *          same end-state parameters. `AutoDOLA` and `YieldStrategyDolaLegacy` are still deployed
 *          and tracked (they are `ContractAddresses` keys) but left IDLE: no client, no withdrawer,
 *          no SYA registration, no yield seed.
 *        - PhlimboV3 seed stakers: DeployMocks stakes for anvil default accounts #4/#5/#6, whose
 *          private keys are public. On a public network anyone could unstake them, so the farm
 *          ships EMPTY here. No replacement stake is placed.
 *        - the Kendu promotion (1-day, would simply expire unobserved on Sepolia): PhlimboV3 ships
 *          DORMANT, `promoToken == address(0)`. (Story 137 replaced the old batch minter's nudge
 *          streams; see the STORY 137 note below for the nudge-discount minter's streams.)
 *        - Balancer pooler -> UniPoolerV2 CUTOVER REHEARSAL (story 101, Phase 11.7 in
 *          DeployMocks) — story 104, Balancexit Stage 3. No `UniPoolerCutoverCore`, no
 *          `UniPoolerCutoverEscrow`, no holding-pattern revoke, no BPT exit. Index 4 is
 *          `UniPoolerV2` from the start, against a fresh mock-token phUSD/sUSDS Uniswap V2 pair
 *          (the factory's canonical pair, created before the pooler, seeded from minter-minted
 *          phUSD in Phase 9.8), wired into the end state the rehearsal leaves behind: minter,
 *          `BalancerPoolerMintDebtHook` in both directions (set BEFORE `registerDispatcher`, see
 *          yield-claim-nft:051), PSM / maxTout / batchMinter / batchDonationSize / nudgeStreamer,
 *          deployer as the sole authorized pooler. Tracked as "UniPoolerV2" and "PhusdSusdsPair".
 *        - the Balancer mocks (pool, vault and router mocks) and
 *          the Balancer pooler itself — story 104. Nothing on this chain is Balancer-backed. The
 *          `ContractAddresses` interface still carries `BalancerPooler`, `BalancerPool`,
 *          `BalancerVault` and `BalancerRouter` through the wind-down, so `extract:sepolia` emits
 *          them as ZERO-ADDRESS PLACEHOLDERS (extract-addresses.js ZERO_PLACEHOLDER_CHAIN_IDS), the
 *          convention mainnet-addresses.ts uses for undeployed keys. `BalancerPoolerMintDebtHook`
 *          is KEPT: the hook contract is live and unchanged on mainnet; only its dispatcher moved.
 *
 *        - SYA / StableStaker re-sync with DeployMocks stories 115, 116 and the claim unblock:
 *          * USDe is registered with SYA in Phase 7.5 (DeployMocks appends it in Phase 11.12), and
 *            YieldStrategyUSDe gets a deployer StableStakerV2 stake plus sUSDe yield in Phase 9.57,
 *            because this chain has no migrated stakers to supply the principal.
 *          * StableStakerV2 opens claims directly in Phase 6.5 (DeployMocks asserts them closed,
 *            then opens them in Phase 11.13).
 *          * SYAHarvester and its infrastructure (Phases 11.11/11.12) live in the add-on
 *            `script/DeploySyaHarvesterSepolia.s.sol`, because its DOLA route runs through the
 *            MockCurveDolaMetaPool that `DeployUniswapHelperSepolia` deploys after this script. The
 *            add-on seeds the V4 ETH/USDC pool faucet-sized and skips the smoke harvest (see its header).
 *        - The story-112 seed deepening, the story-114 Antimatter/sUSDS cutover (Phases 11.9/11.10)
 *          and the story-120 demo Antimatter (Phase 11.14) live in the add-on
 *          `script/DeployAntimatterPoolSepolia.s.sol`, chained after the harvester add-on, so this
 *          script's addresses are unchanged. It creates `AntimatterPoolSeeder` and
 *          `AntimatterSusdsPair` and mints the deployer 10k demo Antimatter.
 *
 *        - STORY 136 (sepolia-catch-up): re-derived against DeployMocks at phStaging2 master
 *          `14bdf56` for Phases 11.15, 11.16 and 11.17. This chain now INCLUDES all three, each
 *          constructed as the END STATE DeployMocks reaches rather than replayed as a migration:
 *          * 11.15 NFTBonfire (story 125): deployed and wired through `NFTBonfireLocalWiring` (its
 *            PauserV2 overload) in the appended Phase 11.15, mainnet params (10 AM/day, 100 AM cap).
 *            The 1% SYA discount is set directly in Phase 7.5; DeployMocks only passes through 20%
 *            for its Phase 11.12 smoke harvest, which this chain does not run.
 *          * 11.16 PauserV2 (story 127): no V1 -> V2 rotation. PauserV2 is deployed in Phase 1.5 in
 *            V1's place under the `Pauser` key, so every registrant lands on V2 from the start and
 *            no Pauser V1 exists. The exact registrant set and `health()` are asserted at the end.
 *          * 11.17 SYA gate OFF (story 130): Phase 8.7 no longer gates the SYA (no setNFTMinter, no
 *            SYA burner grant), so the gate is never on; read-backs assert nftMinter == 0, no burner
 *            right and canClaim for an NFT-less probe, in Phase 8.7 and again in the terminal sweep.
 *          The add-on scripts deploy nothing pausable, so none of them registers on a pauser.
 *
 *        - STORY 137 (sepolia-catch-up 2/2): DeployMocks Phases 11.18 (nudge-discount minter, story
 *          118) and 11.19 (ratchet shutdown, story 135), in the shape the mainnet cutover
 *          (`DeployMainnetNudgeDiscount.s.sol`, params from `NudgeDiscountMainnetBase.sol`) leaves
 *          mainnet in, constructed directly rather than as a cutover:
 *          * OLD BATCH MINTING IS NOT DEPLOYED AT ALL (the human's call, further than both DeployMocks
 *            and mainnet, which keep the multi-token minter deployed but donor-less / frozen):
 *            no `BatchNFTMinterMultiToken` (`BatchNFTMinter` key) and no `RatchetBatchNFTMinter`. Both
 *            keys stay in `ContractAddresses` and `extract:sepolia` emits them as zero-address
 *            placeholders. Nothing to freeze or migrate on a fresh chain, so mainnet's Phase 1 freeze
 *            and Phase 4 pot migration have no equivalent here. The three nudgeless Uniboost batch
 *            loopers (`EyeBatchNFTMinter` / `ScxBatchNFTMinter` / `FlxBatchNFTMinter`) are KEPT: they
 *            hold no pot and are not part of the nudge mechanism the overhaul replaced.
 *          * `BatchNFTMinterNudgeDiscount` (`NudgeDiscountBatchMinter` key) is deployed and FULLY
 *            configured in Phase 3.7, in the old minter's slot and in mainnet Phase 2 order, so every
 *            donor (UniPoolerV2, Uniboost x3, NudgeRatchet, SYA) targets it from construction/wiring
 *            and nothing is ever repointed. Every parameter is set explicitly and read back.
 *          * Streams: all three tokens (USDC, phUSD, Kendu), mirroring mainnet's token set, but at
 *            `SEPOLIA_NUDGE_DISCOUNT_STREAM_DURATION` (1 day) instead of mainnet's 30 days, so the pot
 *            fills while the human tests. Retunable post-deploy by re-`registerStream` (no redeploy).
 *          * The pot is SEEDED in Phase 11.18 through `NudgeStreamer.collectNudge` only (never a
 *            direct transfer): USDC, plus phUSD under a temporary deployer grant revoked in the same
 *            phase, plus Kendu. Sepolia-only testability convenience.
 *          * Phase 11.19 mints `SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS` id-7 NFTs to the deployer and,
 *            NEW vs DeployMocks (which only mints), STAKES them in RatchetNFTStaker, standing in for
 *            mainnet's user-staked ratchets; then disables index 7. The NudgeRatchet hook keeps its
 *            phUSD minter role so its debt can still be pulled, as on mainnet.
 *          * MockSkyPSM's USDS reserve (needed by `buyAndBurn` only, not by user discount mints) is
 *            seeded by the `uniswap-helper:sepolia` add-on, which runs after this script, so the
 *            `NUDGE_DISCOUNT_MIN_PSM_USDS` assertion lives THERE, after its seeding.
 *        - The deployer must never be the mainnet owner Ledger (asserted beside the chain gate).
 *
 *      SEPOLIA-ONLY ADDITION — MockSUSDS is priced at 1.1 USDS (Phase 1, `SEPOLIA_SUSDS_PREMIUM_BPS`)
 *      so code that assumes 1 sUSDS == 1 USDS misbehaves visibly here, and the phUSD/sUSDS pair is
 *      seeded at phUSD par to match. DeployMocks keeps sUSDS at 1:1.
 *
 *      WHAT WAS DELIBERATELY KEPT — the index-6 "bugged pooler" placeholder. On mainnet dispatcher
 *      index 6 is permanently held by the disabled story-047 Balancer pooler. Story 104: with the
 *      Balancer mocks gone the placeholder is a second, never-wired `UniPoolerV2` on the same pair
 *      (its hook is never set, so `_dispatch` reverts `UniPoolerV2__HookNotSet` even if it were
 *      ever re-enabled); its type is irrelevant, only the index it consumes matters.
 *      `NFTMinterV2.registerDispatcher` is append-only and tokenId == dispatcher index, so without
 *      the placeholder NudgeRatchet would land at 6, `require(ratchetIndex == 7)` would revert,
 *      MintPageView (hard-codes 7) would break and RatchetNFTStaker would pin the wrong id. It is a rehearsal only in name: it is what makes dispatcher indices and
 *      ERC-1155 ids mirror mainnet (Uniboost EYE/SCX/FLX 1/2/3, UniPooler 4, GatherWBTC 5,
 *      placeholder 6 disabled, NudgeRatchet 7).
 *
 *      OWNERSHIP EXCEPTION. Every contract is owned by the single deployer EOA. The repo
 *      CLAUDE.md "Required Behavior" rules 4-5 gate such relaxations on chainId 31337; this mock
 *      Sepolia stack is an explicit product-owner exception (story 098): every token is a mock
 *      with an unrestricted mint and nothing of value is at stake. Every other in-script
 *      assertion (terminal phUSD minter-ACL sweep, index-7 assertion, V2 wiring read-backs) is
 *      kept.
 *
 *      HOW TO RUN (env from .envrc: RPC_SEPOLIA, DEPLOYER_SEPOLIA_pk; optional SEPOLIA_WETH_SEED):
 *        npm run deploy:sepolia-preview   # simulation only, no broadcast
 *        npm run deploy:sepolia           # broadcast --slow, then extract + generate
 *                                         #   server/deployments/sepolia-addresses.ts
 *        npm run deploy:sepolia:resume    # forge --resume after a partial broadcast
 *      Recovery is forge's own `--resume`; there is no custom checkpoint logic. Expect ~an hour
 *      of wall time under `--slow`.
 */
contract DeployMocksSepolia is Script {
    // Mock-vs-mainnet parity constants for nudge feature (story 045.5)
    // - MOCK_NUDGE_SPLIT matches mainnet (story 046)
    // (Story 137: MOCK_NUDGE_SIZE is gone with the old batch minters; the discount minter has no nudgeSize.)
    uint256 constant MOCK_NUDGE_SPLIT = 30;
    // Story 045.5 Phase 7 — index-4 batch-donation phase (UniPoolerV2 since story 104)
    // Percent of each dispatched USDS amount diverted to the PSM donation.
    // Mirrors MOCK_NUDGE_SPLIT for mental-model parity; LP path still receives 70%.
    uint256 constant MOCK_BATCH_DONATION_SIZE = 30;

    // ---- Story 137: BatchNFTMinterNudgeDiscount, mainnet parameters ----
    // Source of truth: script/helpers/NudgeDiscountMainnetBase.sol (DISCOUNT_PERCENT, BURN_PERCENT,
    // HOOK_RATIO, MAX_FREE_PER_BATCH, OVERFLOW_NFTS_PER_BOOST_POINT, DAY1_MAX_BOOST, DISPATCHER_INDEX).
    // Pinned equal to it by test/DeployMocksSepoliaNudgeDiscountParams.t.sol, so a mainnet change that
    // is not carried here fails the suite.
    uint8 public constant NUDGE_DISCOUNT_PERCENT = 50;
    uint8 public constant NUDGE_DISCOUNT_BURN_PERCENT = 100;
    uint8 public constant NUDGE_DISCOUNT_HOOK_RATIO = 50;
    uint256 public constant NUDGE_DISCOUNT_MAX_FREE_PER_BATCH = 50;
    uint256 public constant NUDGE_DISCOUNT_OVERFLOW_NFTS_PER_BOOST_POINT = 3;
    uint8 public constant NUDGE_DISCOUNT_DAY1_MAX_BOOST = 0;
    // SEPOLIA DIVERGENCE: mainnet streams all three tokens over 30 days. On Sepolia a 1-day window
    // makes the seeded pot (Phase 11.18) enable a discount batch within the first hour of the deploy
    // so the human can test the UI; retunable post-deploy by re-`registerStream`, no redeploy.
    uint256 public constant SEPOLIA_NUDGE_DISCOUNT_STREAM_DURATION = 1 days;
    // Phase 11.18 pot seeds, routed through NudgeStreamer.collectNudge only. USDC: 1,000 USDC streams
    // ~41.7 USDC/hour, so with P0 = 10 USDS at index 4 `free = floor(potUSD / P0)` is >= 4 an hour
    // after the seed and reaches the 50-NFT cap after ~12 hours. phUSD / Kendu: DeployMocks'
    // LOCAL_PHUSD_NUDGE_SEED / LOCAL_KENDU_NUDGE_SEED magnitudes.
    uint256 public constant SEPOLIA_POT_USDC_SEED = 1_000e6;
    uint256 public constant SEPOLIA_POT_PHUSD_SEED = 5_000e18;
    uint256 public constant SEPOLIA_POT_KENDU_SEED = 50_000e18;
    // Story 137 / 135: NudgeRatchet's NFTMinterV2 index, and how many id-7 NFTs the deployer mints and
    // STAKES before index 7 is disabled (DeployMocks' RATCHET_PRE_SHUTDOWN_MINTS).
    uint256 public constant RATCHET_INDEX = 7;
    uint256 public constant SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS = 5;

    // ---- Story 098: Sepolia-specific constants ----
    // Default TOTAL native ETH wrapped into WETH9 and split evenly across the two WETH-paired UniV2
    // pools (EYE/WETH9 target, USDC/WETH9 routing). Faucet-sized; override with SEPOLIA_WETH_SEED
    // (wei). DeployMocks wraps 300 ETH and seeds 100 WETH per pool.
    uint256 constant SEPOLIA_DEFAULT_WETH_SEED = 0.1 ether;
    // sUSDS share-price premium over USDS, in bps (Phase 1): 1 sUSDS = 1.1 USDS.
    uint256 constant SEPOLIA_SUSDS_PREMIUM_BPS = 1_000;
    // Story 104: the phUSD/sUSDS UniV2 pair seed (Phase 9.8), sized well inside the ~10k phUSD
    // Phases 9/9.55 mint to the deployer and the 10k sUSDS Phase 1 deposits for it. The phUSD
    // side carries the sUSDS premium, so the pair opens with phUSD at par with USDS
    // (2,000 sUSDS = 2,200 USDS against 2,200 phUSD).
    uint256 constant SEPOLIA_PAIR_SUSDS_SEED = 2_000e18;
    uint256 constant SEPOLIA_PAIR_PHUSD_SEED = SEPOLIA_PAIR_SUSDS_SEED * (10_000 + SEPOLIA_SUSDS_PREMIUM_BPS) / 10_000;
    // UniPoolerV2 lives at NFTMinterV2 index 4, the slot the Balancer pooler held on mainnet.
    uint256 constant UNI_POOLER_INDEX = 4;

    // ---- Story 136: DeployMocks Phases 11.15-11.17 end state ----
    // The mainnet owner Ledger. Never the Sepolia deployer (checked beside the chain gate).
    address constant SEPOLIA_FORBIDDEN_DEPLOYER = 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6;
    // The SYA discount the chain ENDS on: 1% (100 bps), DeployMocks' SYA_FINAL_DISCOUNT_BPS and the
    // live mainnet SYA (story 131). Set directly in Phase 7.5: DeployMocks only passes through 2000
    // bps because its Phase 11.12 smoke harvest needs 20%, and this chain runs no smoke harvest.
    uint256 constant SYA_FINAL_DISCOUNT_BPS = 100;
    // Any EOA that holds no claim NFT; `canClaim` must be true for it with the SYA gate off.
    // Same derivation as DeployMocks' SYA_GATE_OFF_PROBE.
    address constant SYA_GATE_OFF_PROBE = address(uint160(uint256(keccak256("story-130 SYA gate-off probe"))));
    // Every pausable contract this script registers on PauserV2 (asserted exactly at the end).
    uint256 constant EXPECTED_PAUSER_REGISTRANTS = 12;

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
    // Story 089: the autoDOLA -> sDOLA split. Key semantics (decided at planning):
    //   `YieldStrategyDolaLegacy` = the autoDOLA strategy V1 sits on (mainnet 0x1760... once 092 patches it)
    //   `YieldStrategyDola`       = the sDOLA strategy, the one that SURVIVES the cutover (V2, minter, SYA)
    //   `SDOLA`                   = the external sDOLA vault (tracked as MockSDOLA; extractor strips `Mock`)
    MockSDOLA public mockSDola;
    ERC4626YieldStrategy public yieldStrategyDolaLegacy; // over MockAutoDOLA
    ERC4626YieldStrategy public yieldStrategyDola; // over MockSDOLA
    ERC4626YieldStrategy public yieldStrategyUSDC;
    // USDe uses the AMM-market strategy (not the plain 1:1 ERC4626YieldStrategy) to mirror
    // mainnet, where sUSDe is reached via a Curve AMM that imposes slippage on every leg.
    ERC4626MarketYieldStrategy public yieldStrategyUSDe;
    MockMarketAMMAdapter public usdeAmmAdapter;
    PhusdStableMinter public minter;
    // The ONLY phlimbo on the local chain. This is what the UI stakes into and what SYA feeds.
    // Tracked under its own `PhlimboV3` key; the legacy `PhlimboEA` key retired with V2.
    PhlimboV3 public phlimboV3;
    MockEYE public eyeToken;
    // Story 136: PauserV2, tracked under the `Pauser` address key exactly as DeployMocks re-tracks it
    // after Phase 11.16. Every pausable contract on this chain registers here from the start.
    PauserV2 public pauser;
    StableYieldAccumulator public stableYieldAccumulator;
    ViewRouter public viewRouter;
    // The V3-native deposit page, and the only one the router ever holds. Deliberately KEYLESS —
    // never `_trackDeployment`d — mirroring mainnet, where every page behind `ViewRouter` was
    // stripped of its address key so `pages(keccak256("deposit"))` is the single resolution path
    // (see extract-addresses.js's DROPPED_CONTRACT_NAMES note).
    DepositPageViewV3 public depositPageViewV3;
    MintPageView public mintPageView;

    // NFTMinter infrastructure (V2 only — V1 removed in story 059)
    MockSCX public mockSCX;
    // Story 073: third nudge-reward asset alongside USDC and phUSD on the multi-token batch minter.
    MockKendu public mockKendu;
    MockFlax public mockFlax;
    MockWBTC public mockWBTC;
    BurnRecorder public burnRecorder;

    // V2 NFTMinter infrastructure
    NFTMinterV2 public nftMinterV2;
    // Story 070: the three BurnerV2 dispatchers (indices 1/2/3) were replaced with Uniboost
    // dispatchers, each backed by a real UniV2 pool + a UniboostMintDebtHook + an
    // NFTStakerDepletionV2 staker. Indices 1/2/3 are preserved (same registration order).
    Uniboost public uniboostEYE;
    Uniboost public uniboostSCX;
    Uniboost public uniboostFLX;
    UniboostMintDebtHook public uniboostHookEYE;
    UniboostMintDebtHook public uniboostHookSCX;
    UniboostMintDebtHook public uniboostHookFLX;
    // The chain runs `NFTStakerDepletionV2` on all three Uniboost indices. Story 073 reached that
    // end state by deploying V1 and draining it through an `NFTStakerMigrator`; since that
    // migration executed on mainnet, V2 is deployed directly under these same keys.
    NFTStakerDepletionV2 public uniboostStakerEYE;
    NFTStakerDepletionV2 public uniboostStakerSCX;
    NFTStakerDepletionV2 public uniboostStakerFLX;
    // Story 070: batch forwarder authorized to pool() across all three Uniboost dispatchers. It is
    // the ONLY authorized pooler on each Uniboost (the deployer is deliberately NOT whitelisted).
    MultiPooler public multiPooler;

    // Story 070: canonical Uniswap V2 infrastructure (deployed fresh by this script) backing the
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

    // Story 104 (Balancexit Stage 3): the index-4 dispatcher, deployed directly (no cutover
    // rehearsal) against the canonical mock-token phUSD/sUSDS UniV2 pair. Tracked as
    // "UniPoolerV2" (-> key `UniPooler`) and "PhusdSusdsPair", the names DeployMocks uses.
    UniPoolerV2 public uniPoolerV2;
    address public phusdSusdsPair;
    GatherV2 public gatherWBTCV2;
    // Disabled placeholder occupying dispatcher index 6 to mirror mainnet, where the
    // "bugged" Balancer pooler (story-047) was appended at index 6 and then permanently
    // disabled by the story-048 cutover. Registering this here pushes NudgeRatchet to
    // index 7, matching the index it will receive on mainnet. Never enabled / never minted.
    // Story 104: a never-wired UniPoolerV2 (no Balancer mocks remain to build the old type);
    // its hook is never set, so it could not dispatch even if re-enabled.
    UniPoolerV2 public buggedPoolerV2Index6;

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
    // (Story 137: no RatchetBatchNFTMinter. Ratchet minting is disabled at the end of the run, and the
    // human asked for every old batch minter to be removed from this chain.)
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
    // Story 137: the shared donor sink is the BatchNFTMinterNudgeDiscount (pot token USDC, bonus
    // tokens phUSD + Kendu), fed through the NudgeStreamer. Tracked under its own
    // `NudgeDiscountBatchMinter` key; the old `BatchNFTMinter` key is a zero placeholder on Sepolia.
    BatchNFTMinterNudgeDiscount public nudgeDiscountMinter;

    // Story 073: buffers bursty donations per (batchMinter, token) and streams them linearly.
    // Six donors route through it: Uniboost x3, UniPoolerV2 (index 4), the index-7 NudgeRatchet and
    // StableYieldAccumulator.
    NudgeStreamer public nudgeStreamer;

    // Story 080: the evergreen staker the local chain ends on, and the Antimatter reward token it
    // pays. Antimatter REPLACES phUSD as the reward token (it is not paid alongside it); V2 still
    // holds a phUSD mint right, but only so `autoAnnihilate` can cover an annihilation shortfall.
    Antimatter public antimatter;
    StableStakerV2 public stableStakerV2;

    // Story 045.5 Phase 7 — index-4 donation-phase mocks
    // waUSDC mock = ERC4626 wrapper over the existing USDC `rewardToken`.
    // (Retained for the V1-era BalancerPooler donation path; the V2 Sky-route
    //  donation no longer uses it — see MockSkyPSM below.)
    MockERC4626Wrapper public mockWaUsdc;

    // Story 056 — index-4 Sky-PSM donation route mock (UniPoolerV2 since story 104).
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
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_SEPOLIA_pk");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Phase 2 MOCK contracts to Sepolia...");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // Story 098: Sepolia only. DeployMocks' fresh-anvil nonce gate is dropped on purpose — the
        // Sepolia deployer key has history, and forge's `--resume` is the recovery path.
        require(block.chainid == 11155111, "DeployMocksSepolia: sepolia only");
        // Story 136: the deployer owns every contract on this chain and must never be the mainnet
        // owner Ledger, which receives nothing, not even mock tokens on a testnet.
        require(
            deployer != SEPOLIA_FORBIDDEN_DEPLOYER, "DeployMocksSepolia: deployer must not be the mainnet Ledger owner"
        );

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

        // Sepolia-only: price sUSDS at a 10% premium over USDS, like mainnet's accrued sUSDS rate,
        // so UI and periphery code that silently assumes 1 sUSDS == 1 USDS shows up on testnet.
        // Donating 10% of the baseline as yield moves the share price from 1 to 1.1 before anyone
        // else holds shares. DeployMocks keeps sUSDS at 1:1.
        _priceSusdsAtPremium(initialSusdsDeposit);

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

        // Story 136: DeployMocks Phase 11.16 (story 127) deploys V1 here and later rotates every V1
        // registrant except the retired StableStaker V1 onto a PauserV2 it re-tracks under the
        // `Pauser` key. A fresh Sepolia deploy constructs that END STATE directly: PauserV2 in V1's
        // slot, so every `setPauser` / `register` below lands on V2 and no V1 ever exists. Same EYE
        // token; the 1000-EYE burn is V2's constructor default, which equals V1's (DeployMocks
        // asserts V2 burn == V1 burn).
        gasBefore = gasleft();
        pauser = new PauserV2(address(eyeToken));
        _trackDeployment("Pauser", address(pauser), gasBefore - gasleft());
        require(pauser.eyeToken() == address(eyeToken), "story-136: PauserV2 EYE token mismatch");
        require(pauser.eyeBurnAmount() == 1000e18, "story-136: PauserV2 burn amount is not the 1000 EYE default");
        console.log("PauserV2 deployed at (tracked as `Pauser`):", address(pauser));

        // ====== PHASE 2: Yield Strategy Deployment ======
        console.log("\n=== Phase 2: Deploying Yield Strategies ===");

        // ====== PHASE 2.5: AutoDOLA ERC4626 Infrastructure for DOLA YieldStrategy ======
        console.log("\n=== Phase 2.5: Deploying AutoDOLA ERC4626 Infrastructure ===");

        // Deploy MockAutoDOLA (ERC4626 vault wrapper)
        gasBefore = gasleft();
        mockAutoDola = new MockAutoDOLA(address(dola));
        _trackDeployment("MockAutoDOLA", address(mockAutoDola), gasBefore - gasleft());
        console.log("MockAutoDOLA deployed at:", address(mockAutoDola));

        // Deploy ERC4626YieldStrategy wrapping the autoDOLA vault. Story 089: this is the LEGACY
        // strategy (V1's, and the minter's until the Phase 9.7 repoint), tracked as
        // `YieldStrategyDolaLegacy`.
        gasBefore = gasleft();
        yieldStrategyDolaLegacy = new ERC4626YieldStrategy(
            deployer, // owner
            address(dola), // underlyingToken (DOLA)
            address(mockAutoDola) // erc4626Vault
        );
        _trackDeployment("YieldStrategyDolaLegacy", address(yieldStrategyDolaLegacy), gasBefore - gasleft());
        console.log(
            "YieldStrategyDolaLegacy (ERC4626YieldStrategy over MockAutoDOLA) deployed at:",
            address(yieldStrategyDolaLegacy)
        );

        // Story 089: the DESTINATION DOLA vault + strategy. Mainnet target is Inverse's sDOLA
        // 0xb45ad160634c528Cc3D2926d9807104FA3157305 (asset() == DOLA verified on mainnet). V2's DOLA
        // pool starts on this strategy (Phase 6.5a); the minter and SYA move onto it in Phase 9.7.
        gasBefore = gasleft();
        mockSDola = new MockSDOLA(address(dola));
        _trackDeployment("MockSDOLA", address(mockSDola), gasBefore - gasleft());
        console.log("MockSDOLA deployed at:", address(mockSDola));

        gasBefore = gasleft();
        yieldStrategyDola = new ERC4626YieldStrategy(
            deployer, // owner
            address(dola), // underlyingToken (DOLA)
            address(mockSDola) // erc4626Vault
        );
        _trackDeployment("YieldStrategyDola", address(yieldStrategyDola), gasBefore - gasleft());
        console.log("YieldStrategyDola (ERC4626YieldStrategy over MockSDOLA) deployed at:", address(yieldStrategyDola));

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

        // 2. Deploy phlimbo. PhlimboV3 is the only generation the local chain carries: V1
        //    (`PhlimboEA`) and V2 both retired here once their mainnet cutovers had executed.
        //    A separate helper, not inline: `run()` is at its stack-depth ceiling.
        phlimboV3 = _deployPhlimboV3(deployer);

        // 3. Deploy StableYieldAccumulator
        gasBefore = gasleft();
        stableYieldAccumulator = new StableYieldAccumulator();
        _trackDeployment("StableYieldAccumulator", address(stableYieldAccumulator), gasBefore - gasleft());
        console.log("StableYieldAccumulator deployed at:", address(stableYieldAccumulator));

        // ====== PHASE 3.6: V2 NFTMinter Infrastructure ======
        // (Phase 3.5 V1 NFTMinter infra removed in story 059 — V1 is decommissioned)
        console.log("\n=== Phase 3.6: Deploying V2 NFTMinter Infrastructure ===");

        // Story 104: no Balancer mocks (pool/vault/router) — index 4 is UniPoolerV2, below.

        // Deploy BurnRecorder
        gasBefore = gasleft();
        burnRecorder = new BurnRecorder(deployer);
        _trackDeployment("BurnRecorder", address(burnRecorder), gasBefore - gasleft());
        console.log("BurnRecorder deployed at:", address(burnRecorder));

        // Deploy NFTMinterV2
        gasBefore = gasleft();
        nftMinterV2 = new NFTMinterV2(deployer);
        _trackDeployment("NFTMinterV2", address(nftMinterV2), gasBefore - gasleft());
        console.log("NFTMinterV2 deployed at:", address(nftMinterV2));

        // ---- Story 070: real Uniswap V2 + target/routing pools (own deployment; story 098) ----
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

        // Story 104 (Balancexit Stage 3): the index-4 venue, deployed DIRECTLY — no cutover
        // rehearsal. Same order as the audited Stage 2 script (story 103 / UniPoolerCutoverCore
        // steps 1, 3, 8): create the canonical pair, deploy UniPoolerV2 against it (its
        // constructor requires `router.factory().getPair(sUSDS, phUSD) == pair`; zero reserves
        // are allowed), then install the mint-debt hook. The pair is seeded in Phase 9.8, once
        // the stable minter has minted the deployer its phUSD side.
        _deployUniPoolerV2(deployer);

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

        // Story 104: UniPoolerV2 takes index 4 in the SAME registration slot the Balancer pooler
        // held. Its hook is already installed (see `_deployUniPoolerV2`), so no index-4 dispatch
        // can ever hit `UniPoolerV2__HookNotSet` (yield-claim-nft:051).
        nftMinterV2.registerDispatcher(address(uniPoolerV2), v2InitialPrice, 10); // 0.1% growth
        require(
            nftMinterV2.dispatcherToIndex(address(uniPoolerV2)) == UNI_POOLER_INDEX,
            "story-104: UniPoolerV2 must occupy dispatcher index 4"
        );
        console.log("Registered UniPoolerV2 dispatcher with NFTMinterV2 (index 4, 0.1% growth)");

        nftMinterV2.registerDispatcher(address(gatherWBTCV2), v2WBTCInitialPrice, 1000); // 10% growth
        console.log("Registered GatherWBTCV2 dispatcher with NFTMinterV2 (index 5, 10% growth)");

        // ---- Index-6 mirror: disabled "bugged pooler" placeholder ----
        // On mainnet, dispatcher index 6 is permanently occupied by the disabled bugged
        // Balancer pooler (registered by story-047, disabled by the story-048 cutover).
        // registerDispatcher is append-only by index, so index 6 can never be reclaimed —
        // meaning NudgeRatchet will land at index 7 on mainnet. We mirror that here by
        // registering a placeholder dispatcher at index 6 and immediately disabling it,
        // so the local NudgeRatchet also receives index 7 and the dispatcher layout (and
        // therefore MintPageView's hardcoded index 7) is identical across all networks.
        // This dispatcher is disabled and never minted; it exists only to consume index 6.
        // Story 104: a second UniPoolerV2 on the same pair (the Balancer mocks the old
        // placeholder type needed are gone). Never wired: no minter, no hook, no pooler — with
        // the default hook in place its `_dispatch` reverts, so it is inert twice over.
        gasBefore = gasleft();
        buggedPoolerV2Index6 =
            new UniPoolerV2(address(susds), address(phUSD), address(uniRouter), phusdSusdsPair, deployer);
        _trackDeployment("BuggedPoolerV2Index6", address(buggedPoolerV2Index6), gasBefore - gasleft());
        console.log("BuggedPoolerV2Index6 (disabled placeholder) deployed at:", address(buggedPoolerV2Index6));

        nftMinterV2.registerDispatcher(address(buggedPoolerV2Index6), v2InitialPrice, 10); // index 6
        nftMinterV2.setDispatcherDisabled(6, true); // mirror mainnet: index 6 is disabled
        console.log("Registered + disabled BuggedPoolerV2Index6 (index 6) to mirror mainnet");

        // 5. Set minter on each V2 dispatcher.
        // ---- Story 070: Uniboost minter + hook + pooler-auth wiring (indices 1/2/3) ----
        // Construction/registration must stay in this early block to preserve indices 1/2/3.
        // The DONATION split (setRecipient/setDonationSplit) is DEFERRED to Phase 3.7 below
        // because its recipient (nudgeDiscountMinter) is not deployed until then. The staker +
        // Pauser registration are likewise deferred to keep this block focused.

        // Deploy the MultiPooler batch forwarder FIRST so _wireUniboost can authorize it as the sole
        // pooler on each dispatcher. The deployer is the keeper/operator that drives the batch from
        // the UI, so it is the MultiPooler's single batch-caller (`pooler`). Note this is
        // distinct from a Uniboost authorized-pooler: the deployer can call MultiPooler.pool(), but
        // is NOT whitelisted on any Uniboost — only the MultiPooler address is.
        gasBefore = gasleft();
        multiPooler = new MultiPooler(deployer);
        _trackDeployment("MultiPooler", address(multiPooler), gasBefore - gasleft());
        console.log("MultiPooler deployed at:", address(multiPooler));
        multiPooler.setPooler(deployer);
        console.log("MultiPooler.setPooler -> deployer (keeper/operator)");

        _wireUniboost(uniboostEYE, "UniboostEYE");
        uniboostHookEYE = _deployUniboostHook(uniboostEYE, deployer);
        _trackDeployment("UniboostHookEYE", address(uniboostHookEYE), 0);

        _wireUniboost(uniboostSCX, "UniboostSCX");
        uniboostHookSCX = _deployUniboostHook(uniboostSCX, deployer);
        _trackDeployment("UniboostHookSCX", address(uniboostHookSCX), 0);

        _wireUniboost(uniboostFLX, "UniboostFLX");
        uniboostHookFLX = _deployUniboostHook(uniboostFLX, deployer);
        _trackDeployment("UniboostHookFLX", address(uniboostHookFLX), 0);

        uniPoolerV2.setMinter(address(nftMinterV2));
        console.log("UniPoolerV2.setMinter -> NFTMinterV2");

        // The deployer is the sole authorized pooler, as it was on the Balancer pooler here.
        uniPoolerV2.setAuthorizedPooler(deployer, true);
        console.log("UniPoolerV2.setAuthorizedPooler(deployer, true)");

        // ---- Story 045.5 Phase 7: index-4 donation config + waUSDC ----
        // (setBatchMinter and setBatchDonationSize land in Phase 3.7 below, after
        // BatchNFTMinter is deployed.)
        // Deploy waUSDC mock (ERC4626 wrapper over the existing USDC reward token).
        // 6 decimals to match real USDC; default rate 10000 bps (1:1 redeem).
        gasBefore = gasleft();
        mockWaUsdc = new MockERC4626Wrapper("Mock Wrapped Aave USDC", "mwaUSDC", address(rewardToken), 6, 10000);
        _trackDeployment("MockWaUSDC", address(mockWaUsdc), gasBefore - gasleft());
        console.log("MockWaUSDC deployed at:", address(mockWaUsdc));

        // Pre-fund the waUSDC wrapper with underlying USDC so `redeem` payouts
        // succeed during V1-era index-4 donation-phase unwraps. The mock
        // wrapper mints shares without taking deposits, so it has no USDC
        // backing unless we seed it here. See src/mocks/MockERC4626Wrapper.sol
        // ("Tests/dev scripts pre-fund the wrapper directly").
        rewardToken.mint(address(mockWaUsdc), 1_000_000 * 10 ** 6);
        console.log("Pre-funded MockWaUSDC with 1,000,000 USDC for redeem backing");

        // ---- Story 056: index-4 Sky-PSM donation route (UniPoolerV2 since story 104) ----
        // The batch donation routes raw USDS -> USDC via the Sky PSM
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

        // Wire the Sky-route config on UniPoolerV2 (recipient comes later in
        // Phase 3.7). `setPSM` enables the route; `setMaxTout(0.01e18)` mirrors the
        // contract's default 1% buy-fee ceiling so a fee spike parks USDS rather than
        // shipping a worse rate. The mock PSM's tout defaults to 0 (well under the cap).
        uniPoolerV2.setPSM(address(mockSkyPSM));
        console.log("UniPoolerV2.setPSM -> MockSkyPSM");

        uniPoolerV2.setMaxTout(0.01e18);
        console.log("UniPoolerV2.setMaxTout -> 0.01e18 (1%)");

        gatherWBTCV2.setMinter(address(nftMinterV2));
        console.log("GatherWBTCV2.setMinter -> NFTMinterV2");

        // Story 070: the burner-specific BurnRecorder.setBurner(burner*, true) lines were removed
        // — Uniboost does not burn. BurnRecorder itself is retained (MintPageView still reads its
        // getTotalBurnt totals, which now stay at zero on the EYE/SCX/Flax slots).

        // ====== PHASE 3.7: NFT Staking Stack ======
        console.log("\n=== Phase 3.7: NFT Staking Stack ===");

        // 1-2. Story 104: BalancerPoolerMintDebtHook was deployed pointed at UniPoolerV2 and
        //      installed on it in Phase 3.6 (`_deployUniPoolerV2`), ahead of the index-4
        //      registration, so UniPoolerV2 never sits registered with its default hook.

        // 3. Deploy NFTStaker (index-4 NFT id = 4, phUSD as reward, dispatcher index 4)
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

        // 8/9. Story 137 — deploy the NudgeStreamer and the BatchNFTMinterNudgeDiscount, and wire the
        //      minter COMPLETELY, in mainnet cutover Phase 2 order (mintFor authority last), BEFORE
        //      any donor below is pointed at it. Every dependency it needs (NFTMinterV2 index 4,
        //      NFTStaker + the index-4 hook, MockSkyPSM, sUSDS, the phUSD/sUSDS pair, PauserV2)
        //      exists by now. Extracted into a helper because run() is at its stack-depth ceiling.
        _deployStreamerAndNudgeDiscountMinter(deployer);

        // ---- Story 045.5 Phase 7: Finalise the UniPoolerV2 batch-donation wiring ----
        // The donor sink is now deployed — point the donation recipient at it and
        // turn the donation phase on. Order: setBatchMinter (recipient) BEFORE
        // setBatchDonationSize (the activator). Swap config was already wired in
        // Phase 3.6 above.
        uniPoolerV2.setBatchMinter(address(nudgeDiscountMinter));
        console.log("UniPoolerV2.setBatchMinter -> NudgeDiscountBatchMinter");

        uniPoolerV2.setBatchDonationSize(MOCK_BATCH_DONATION_SIZE);
        console.log("UniPoolerV2.setBatchDonationSize ->", MOCK_BATCH_DONATION_SIZE);

        // Story 073: the index-4 donation branch is streamer-gated. Without this the donation
        // reverts inside `_psmDonate` and `_dispatch`'s try/catch swallows it — the mint succeeds
        // but zero USDC ever reaches the batch minter (the exact silent breakage this story fixes).
        // MUST come after registerStream(nudgeDiscountMinter, USDC) inside the helper above.
        uniPoolerV2.setNudgeStreamer(address(nudgeStreamer));
        console.log("UniPoolerV2.setNudgeStreamer -> NudgeStreamer");

        // ---- Story 070: deferred Uniboost wiring (donation split + staker + Pauser) ----
        // nudgeDiscountMinter now exists, so this is the phase where the uniboost dispatchers learn
        // their donation recipient. Recipient is the nudge-discount minter (pinned to the
        // UniPoolerV2 index-4 NFT), so 50% of each mint's USDC feeds its discount pot; the
        // remaining 50% is retained for pool().
        //
        // Story 073: `_finalizeUniboost` additionally calls setNudgeStreamer. The staker step
        // deploys `NFTStakerDepletionV2` directly under the `UniboostStaker*` keys — the V1 ->
        // migrator -> V2 rehearsal that used to sit here was retired once its mainnet cutover had
        // executed.
        _finalizeUniboost(uniboostEYE, uniboostHookEYE, address(nudgeDiscountMinter), deployer);
        uniboostStakerEYE = _deployUniboostStaker(uniboostEYE, uniboostHookEYE, deployer);
        _trackDeployment("UniboostStakerEYE", address(uniboostStakerEYE), 0);

        _finalizeUniboost(uniboostSCX, uniboostHookSCX, address(nudgeDiscountMinter), deployer);
        uniboostStakerSCX = _deployUniboostStaker(uniboostSCX, uniboostHookSCX, deployer);
        _trackDeployment("UniboostStakerSCX", address(uniboostStakerSCX), 0);

        _finalizeUniboost(uniboostFLX, uniboostHookFLX, address(nudgeDiscountMinter), deployer);
        uniboostStakerFLX = _deployUniboostStaker(uniboostFLX, uniboostHookFLX, deployer);
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
            address(nudgeDiscountMinter), // batchMinter_ — the nudge-discount pot (story 137)
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
        //     the first two already ran in _deployStreamerAndNudgeDiscountMinter above.
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
        //    bugged pooler permanently holds index 6. Mirror the index-4 price + 0.1% growth.
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

        // 7. (Story 137) No RatchetBatchNFTMinter: removed with the rest of the old batch minting.
        //    Ratchet minting itself is disabled in Phase 11.19, after the deployer's staked mints.

        // ====== PHASE 4: Token Authorization ======
        console.log("\n=== Phase 4: Token Authorization ===");

        // Authorize PhusdStableMinter as phUSD minter
        phUSD.setMinter(address(minter), true);
        console.log("Authorized PhusdStableMinter as phUSD minter");

        // ====== PHASE 5: YieldStrategy Configuration ======
        console.log("\n=== Phase 5: YieldStrategy Configuration ===");

        // Authorize minter as client on all yield strategies.
        // Story 098: DOLA goes straight onto the sDOLA strategy (`YieldStrategyDola`) — the end state
        // DeployMocks only reaches after its Phase 9.7 repoint rehearsal. The legacy autoDOLA
        // strategy is deployed but left idle (no clients).
        yieldStrategyDola.setClient(address(minter), true);
        yieldStrategyUSDC.setClient(address(minter), true);
        console.log("Authorized minter as yield strategy client (DOLA on sDOLA, USDC)");

        // ====== PHASE 6: PhusdStableMinter Configuration ======
        console.log("\n=== Phase 6: PhusdStableMinter Configuration ===");

        // Approve yield strategies for their respective tokens.
        //
        // STORY 080 — USDe IS NOW REGISTERED TOO, and that is a real behavioural addition, not
        // tidying. `StableStakerV2.autoAnnihilate` prices the stablecoin half through
        // `Antimatter.toStableAmount`, which reverts `StablecoinNotRegistered` for any pool token
        // the stable minter does not know; `autoAnnihilateAvailable(token)` is the staticcall
        // probe of exactly that. USDe is one of the three StableStaker pools, so without this
        // pair of calls the USDe pool's whole reward path is dead on arrival and the assertion in
        // Phase 6.5 fails closed. DOLA and USDC were already registered below for the phUSD mint
        // path; USDe never was because nothing before StableStakerV2 needed it.
        minter.approveYS(address(dola), address(yieldStrategyDola));
        minter.approveYS(address(rewardToken), address(yieldStrategyUSDC)); // USDC
        minter.approveYS(address(usde), address(yieldStrategyUSDe));
        console.log("Approved yield strategies for their tokens (DOLA on sDOLA, USDC, USDe)");

        // Register DOLA as stablecoin (18 decimals). Story 098: directly on the sDOLA strategy.
        // `registerStablecoin` leaves maxMintPerDay at 0 (uncapped) — the same value DeployMocks
        // restores after its repoint, so no setMaxMintPerDay call is needed to match its end state.
        minter.registerStablecoin(
            address(dola), // stablecoin
            address(yieldStrategyDola), // yieldStrategy (sDOLA)
            1e18, // exchangeRate (1:1)
            18 // decimals
        );
        console.log("Registered DOLA as stablecoin (on YieldStrategyDola / sDOLA)");

        // Register USDC as stablecoin (6 decimals)
        minter.registerStablecoin(
            address(rewardToken), // stablecoin (USDC)
            address(yieldStrategyUSDC), // yieldStrategy
            1e18, // exchangeRate (1:1)
            6 // decimals
        );
        console.log("Registered USDC as stablecoin");

        // Register USDe as stablecoin (18 decimals). Story 080 — see the approveYS note above.
        // The declared decimals must match what the token actually reports: `toStableAmount`
        // cross-checks them and reverts `DecimalsMismatch` otherwise. MockUSDe is 18-decimal.
        minter.registerStablecoin(
            address(usde), // stablecoin
            address(yieldStrategyUSDe), // yieldStrategy
            1e18, // exchangeRate (1:1)
            18 // decimals
        );
        console.log("Registered USDe as stablecoin (story 080: unlocks autoAnnihilate on the USDe pool)");

        // ====== PHASE 6.5: Antimatter + StableStakerV2 (story 080; direct deploy, story 098) ======
        // AFTER Phase 6, because `Antimatter.setPhUSDMinter` needs the stable minter to exist and
        // `autoAnnihilateAvailable` needs all three pool tokens registered on it. BEFORE Phase 8's
        // pauser block, which registers V2 and Antimatter. No V1, no cutover (story 098).
        _deployAntimatterAndStableStakerV2(deployer);

        // ====== PHASE 7.5: StableYieldAccumulator Configuration ======
        console.log("\n=== Phase 7.5: StableYieldAccumulator Configuration ===");

        // STORY 130 — CONFIGURE FIRST. yield-accumulator:029 (audit-15 M-01) makes the SYA fail
        // closed on unconfigured tokens: setRewardToken and addYieldStrategy revert
        // TokenNotConfigured(token) unless setTokenConfig(token, ...) has already run.
        //
        // Configure USDC token (6 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(rewardToken), 6, 1e18);
        console.log("Configured USDC token config (6 decimals, 1:1 rate)");

        // Configure DOLA token (18 decimals, 1:1 exchange rate)
        stableYieldAccumulator.setTokenConfig(address(dola), 18, 1e18);
        console.log("Configured DOLA token config (18 decimals, 1:1 rate)");

        // Set reward token to USDC (rewardToken is MockRewardToken which is USDC).
        //
        // ORDERING IS LOAD-BEARING, in two directions:
        //   1. AFTER setTokenConfig(rewardToken) above (story 130 / yield-accumulator:029:
        //      setRewardToken reverts TokenNotConfigured on an unconfigured token).
        //   2. BEFORE setNudgeAddress / setNudgeSplit / setNudgeStreamer below (STORY 073 /
        //      yield-accumulator:027: once the nudge path is live (nudgeSplit != 0 &&
        //      nudgeStreamer != 0 && nudge != 0) setRewardToken requires the streamer to already
        //      hold a registered stream for the NEW reward token; calling it before the nudge
        //      setters keeps that guard dormant at deploy time).
        // Do not reorder.
        stableYieldAccumulator.setRewardToken(address(rewardToken));
        console.log("Set reward token to USDC:", address(rewardToken));

        // Set Phlimbo as the reward recipient. The stable yield funnel must terminate at the farm
        // users are actually staked in, which on both mainnet and this chain is PhlimboV3.
        stableYieldAccumulator.setPhlimbo(address(phlimboV3));
        console.log("Set PhlimboV3 as reward recipient:", address(phlimboV3));

        // NOTE: SYA.setMinter() was removed in the stable-yield-accumulator bump
        // (the accumulator no longer tracks the phUSD stable minter directly;
        // yield strategies are registered via addYieldStrategy instead). Call dropped.
        // stableYieldAccumulator.setMinter(address(minter));

        // Story 098: the sDOLA strategy is registered directly (DeployMocks' post-repoint shape).
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyDola), address(dola));
        console.log("Added YieldStrategyDola (sDOLA) to yield strategy registry");

        // Add YieldStrategyUSDC to the yield strategy registry
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyUSDC), address(rewardToken));
        console.log("Added YieldStrategyUSDC to yield strategy registry");

        // USDe as the third SYA strategy, mirroring mainnet SYA 0x0cD353bf...21B6 (USDC, USDe on
        // YieldStrategyUSDe, DOLA on sDOLA). DeployMocks appends this in Phase 11.12 (story 116,
        // `_registerUsdeWithSya`) so no earlier anvil address moves; this chain registers it here.
        stableYieldAccumulator.setTokenConfig(address(usde), 18, 1e18);
        stableYieldAccumulator.addYieldStrategy(address(yieldStrategyUSDe), address(usde));
        console.log("Configured USDe token config (18 decimals, 1:1) and added YieldStrategyUSDe (story 116)");

        // Story 136: the FINAL discount, 1% (100 bps), set directly (see SYA_FINAL_DISCOUNT_BPS).
        stableYieldAccumulator.setDiscountRate(SYA_FINAL_DISCOUNT_BPS);
        require(stableYieldAccumulator.getDiscountRate() == SYA_FINAL_DISCOUNT_BPS, "story-136: SYA discount is not 1%");
        console.log("Set discount rate to 100 basis points (1%) - DeployMocks Phase 11.15 end state");

        // Approve Phlimbo to spend reward tokens with max approval
        stableYieldAccumulator.approvePhlimbo(type(uint256).max);
        console.log("Approved Phlimbo to spend reward tokens from StableYieldAccumulator");

        // CRITICAL: Authorize StableYieldAccumulator as withdrawer on all yield strategies
        // This allows StableYieldAccumulator to withdraw yield from the strategies
        yieldStrategyDola.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyDola (sDOLA)");

        yieldStrategyUSDC.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyUSDC");

        yieldStrategyUSDe.setWithdrawer(address(stableYieldAccumulator), true);
        console.log("Authorized StableYieldAccumulator as withdrawer on YieldStrategyUSDe");
        require(
            stableYieldAccumulator.strategyTokens(address(yieldStrategyUSDe)) == address(usde),
            "story-116: YieldStrategyUSDe not registered with SYA"
        );
        require(stableYieldAccumulator.getYieldStrategies().length == 3, "story-116: SYA should carry 3 strategies");

        // Wire nudge config on StableYieldAccumulator (story 045.5)
        //   nudge address first, then split (mirrors mainnet sequence in story 046).
        //   When claim() runs, nudgeSplit% of the discounted USDC payment is forwarded
        //   to the nudge-discount minter's pot (story 137); the remainder goes to Phlimbo as before.
        stableYieldAccumulator.setNudgeAddress(address(nudgeDiscountMinter));
        console.log("SYA.setNudgeAddress ->", address(nudgeDiscountMinter));

        stableYieldAccumulator.setNudgeSplit(MOCK_NUDGE_SPLIT);
        console.log("SYA.setNudgeSplit ->", MOCK_NUDGE_SPLIT);

        // Story 073: sixth and last donor onto the streamer. claim() now PULLS the nudge slice via
        // collectNudge(nudge, rewardToken, nudgeAmount) instead of pushing it straight at the batch
        // minter. Must run after registerStream(nudgeDiscountMinter, USDC) (done in Phase 3.7) and after
        // setRewardToken above, or the first claim() reverts.
        stableYieldAccumulator.setNudgeStreamer(address(nudgeStreamer));
        console.log("SYA.setNudgeStreamer ->", address(nudgeStreamer));
        require(stableYieldAccumulator.nudgeStreamer() == address(nudgeStreamer), "SYA nudgeStreamer not wired");

        // ====== PHASE 7.6: static index-7 dispatcher claims ======
        // Two cheap read-only gates on the index-7 hook, kept after the index-1 dispatcher-swap
        // rehearsal was retired (its mainnet cutover has executed, so a local chain that deploys a
        // second UniboostEYE purely to replace the first was rehearsing nothing).
        _pinNudgeRatchetStaticClaims();

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

        // PhlimboV3 sets its pauser and registers inside `_deployPhlimboV3` (Phase 3), beside its
        // constructor, so it is never live for a phase without a pauser wired.

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

        // Story 080: the evergreen staker. Registered on the same two-step pattern as everything
        // else — `setPauser` first, because `register()` validates `pauser() == address(this)`.
        stableStakerV2.setPauser(address(pauser));
        pauser.register(address(stableStakerV2));
        console.log("Pauser.register(StableStakerV2) completed");

        // Story 080: Antimatter carries its OWN Phoenix IPausable pauser, distinct from the
        // staker's — `annihilate` is its only whenNotPaused function. Registering it is not
        // required for the cutover to work, but leaving a Phoenix pausable unregistered on the
        // local chain diverges from every other contract here, and the divergence would be
        // invisible until someone burned EYE and found one contract still live.
        antimatter.setPauser(address(pauser));
        pauser.register(address(antimatter));
        console.log("Pauser.register(Antimatter) completed");

        console.log("All protocol contracts registered with Pauser");

        // ====== PHASE 8.7: SYA NFT claim gate — OFF (story 136) ======
        // DeployMocks gates the SYA here (setNFTMinter(NFTMinterV2) + SYA as an NFTMinterV2 burner)
        // and clears both in Phase 11.17 (story 130), mirroring the gate-free SYA phStaging2:131
        // deployed on mainnet. This fresh chain constructs that end state directly: the gate is
        // never set, so neither transaction is sent. Read-backs prove the end state.
        console.log("\n=== Phase 8.7: SYA NFT claim gate OFF (never set; DeployMocks 11.17 end state) ===");
        _requireSyaGateOff();
        console.log("  SYA.nftMinter() == 0, SYA not an NFTMinterV2 burner, canClaim(NFT-less probe) == true");

        // ====== PHASE 9: Seed YieldStrategyDola (sDOLA) with PhUSD Minting ======
        console.log("\n=== Phase 9: Seed YieldStrategyDola (sDOLA) with PhUSD Minting ===");

        uint256 dolaAmount = 5000 * 10 ** 18; // 5000 DOLA

        // Deployer already has DOLA from MockDola constructor mint
        dola.approve(address(minter), dolaAmount);
        console.log("Approved minter to spend 5000 DOLA");

        // 1) Transfer DOLA to minter, 2) Deposit DOLA into YieldStrategyDola, 3) Mint PhUSD to deployer
        minter.mint(address(dola), dolaAmount);
        console.log("Minted PhUSD with 5000 DOLA");
        console.log("  - DOLA deposited to YieldStrategyDola (sDOLA)");
        console.log("  - PhUSD minted to deployer:", deployer);

        // ====== PHASE 9.5: Add DOLA Yield to the MockSDOLA vault ======
        // Story 098: DeployMocks seeds 1000 DOLA onto MockAutoDOLA (legacy) AND 1000 onto MockSDOLA
        // (inside its repoint). Only the sDOLA seed is kept: it is the vault the minter, V2 and SYA
        // actually sit on. The legacy vault has no depositor on this chain, so a seed there would be
        // unclaimable by anything.
        console.log("\n=== Phase 9.5: Add DOLA Yield to MockSDOLA Vault ===");
        mockSDola.addYield(1000 * 10 ** 18); // 1000 DOLA, same magnitude as DeployMocks
        console.log("Minted 1000 DOLA directly to MockSDOLA vault as yield");

        _assertDolaOnSDola();
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

        // ====== PHASE 9.57: Seed YieldStrategyUSDe + add USDe yield (story 116 parity) ======
        // DeployMocks' USDe strategy holds principal from its migrated anvil stakers, and Phase
        // 11.12 seeds sUSDe yield so SYA (and SYAHarvester) has USDe to sell. This chain has no
        // migrated stakers, so the deployer stakes the principal into StableStakerV2.
        _seedUsdeStrategyAndYield();

        // ====== PHASE 9.8: Seed the phUSD/sUSDS UniV2 pair + assert the index-4 end state ======
        // Story 104. Runs after Phases 9/9.55 because the deployer has no phUSD mint right on this
        // chain (story 098): its phUSD comes from the stable minter. Seeded before anything can
        // call `UniPoolerV2.pool()`, which reverts `UniPoolerV2__EmptyPair` on zero reserves.
        _seedPhusdSusdsPairAndAssertIndex4(deployer);

        // ====== PHASE 11: Deploy ViewRouter + the page views ======
        // `DepositView` and `DepositPageView` are both gone with PhlimboV2: they are typed against
        // the V1/V2-shaped `IPhlimbo`, whose 3-tuple `userInfo` silently mis-decodes V3's 4-tuple
        // rather than reverting. `DepositPageViewV3` below is the only deposit page.
        console.log("\n=== Phase 11: Deploy ViewRouter + page views ===");

        gasBefore = gasleft();
        viewRouter = new ViewRouter();
        _trackDeployment("ViewRouter", address(viewRouter), gasBefore - gasleft());
        console.log("ViewRouter deployed at:", address(viewRouter));

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

        // ====== PHASE 11.5: DepositPageViewV3, the deposit page ======
        // The view's `phlimbo` is IMMUTABLE, so it is constructed against the V3 deployed back in
        // Phase 3. Typed against `IPhlimboV3` rather than `IPhlimbo` because `PhlimboV3.userInfo`
        // returns a 4-tuple where V1/V2 returned 3: Solidity's decoder tolerates the extra
        // trailing returndata, so a V1-shaped page pointed at V3 does not revert, it silently
        // returns undefined-by-accident data with none of the promo fields.
        console.log("\n=== Phase 11.5: Deploy DepositPageViewV3 + register the deposit page ===");

        gasBefore = gasleft();
        depositPageViewV3 = new DepositPageViewV3(IPhlimboV3(address(phlimboV3)), IERC20(address(phUSD)));
        console.log("DepositPageViewV3 deployed at:", address(depositPageViewV3));
        console.log("  gas:", gasBefore - gasleft());
        // NO `_trackDeployment`. Keyless by design, exactly as on mainnet: `ViewRouter` publishes
        // the page address on-chain, and a second hand-maintained address key is a COMPETING
        // resolution path — the precise duplication that let mainnet's deposit page sit on a
        // stale view unnoticed for months. See extract-addresses.js DROPPED_CONTRACT_NAMES.

        // THE LAST STEP OF THE PHASE, deliberately: until this lands the "deposit" key is unset
        // and every read through the router reverts, which is a loud failure rather than a quiet
        // one.
        viewRouter.setPage(keccak256("deposit"), IPageView(address(depositPageViewV3)));
        require(
            address(viewRouter.pages(keccak256("deposit"))) == address(depositPageViewV3),
            "ViewRouter deposit page did not point at DepositPageViewV3"
        );
        console.log("ViewRouter deposit page -> DepositPageViewV3");

        // ====== PHASE 11.15: NFTBonfire (story 136, ports DeployMocks Phase 11.15 / story 125) ======
        // After every phase DeployMocks' 11.15 depends on (NFTMinterV2, Antimatter, PauserV2 all
        // deployed and owned by the deployer). The SYA discount half of 11.15 is already in Phase 7.5.
        _deployNFTBonfire(deployer);

        // ====== PHASE 11.18: seed the nudge-discount pot (story 137, Sepolia-only convenience) ======
        // The minter was deployed and fully wired in Phase 3.7 (DeployMocks deploys it here, in 11.18,
        // only because it must append without moving anvil addresses). What is left is the seed: USDC,
        // phUSD and Kendu, each ONLY through NudgeStreamer.collectNudge, so a discount batch is enabled
        // within the first hour of the 1-day stream. phUSD comes from a temporary deployer grant that
        // is revoked (and read back) inside the same helper.
        _seedNudgeDiscountPot(deployer);

        // ====== PHASE 11.19: ratchet minting shut down, with STAKED pre-shutdown ratchets (story 137) ======
        // DeployMocks Phase 11.19 (story 135) plus a stake: the deployer mints
        // SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS id-7 NFTs (their USDC streams into the discount pot through
        // NudgeRatchet), stakes all of them in RatchetNFTStaker, then index 7 is disabled.
        _mintStakeAndShutdownRatchet(deployer);

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
        _markConfigured("MockSDOLA", 0);
        _markConfigured("MockAutoUSDC", 0);
        _markConfigured("YieldStrategyDolaLegacy", 0);
        _markConfigured("YieldStrategyDola", 0);
        _markConfigured("YieldStrategyUSDC", 0);
        _markConfigured("YieldStrategyUSDe", 0);
        _markConfigured("USDeAMMAdapter", 0);
        _markConfigured("PhusdStableMinter", 0);
        // Configured inside `_deployPhlimboV3` (APY, pauser, phUSD mint grant, seed stakers)
        // rather than in the phases above, but it is a first-class tracked deployment and must
        // appear here or extract-addresses drops it from the interface.
        _markConfigured("PhlimboV3", 0);
        _markConfigured("StableYieldAccumulator", 0);
        _markConfigured("Pauser", 0);
        _markConfigured("BurnRecorder", 0);
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
        _markConfigured("UniPoolerV2", 0);
        _markConfigured("PhusdSusdsPair", 0);
        _markConfigured("MockWaUSDC", 0);
        _markConfigured("MockSkyPSM", 0);
        _markConfigured("GatherWBTCV2", 0);
        _markConfigured("NudgeRatchet", 0);
        _markConfigured("NudgeRatchetMintDebtHook", 0);
        _markConfigured("BalancerPoolerMintDebtHook", 0);
        _markConfigured("NFTStaker", 0);
        _markConfigured("RatchetNFTStaker", 0);
        _markConfigured("NudgeDiscountBatchMinter", 0);
        _markConfigured("NudgeStreamer", 0);
        _markConfigured("Antimatter", 0);
        _markConfigured("StableStakerV2", 0);
        _markConfigured("ViewRouter", 0);
        _markConfigured("MintPageView", 0);
        // Story 136: NFTBonfire (deployed and wired inside _deployNFTBonfire).
        _markConfigured("NFTBonfire", 0);

        // Track seeding completion
        _trackDeployment("Seeding", address(0), 0);
        _markConfigured("Seeding", 0);
        _trackDeployment("DolaYield", address(0), 0);
        _markConfigured("DolaYield", 0);
        _trackDeployment("UsdcYield", address(0), 0);
        _markConfigured("UsdcYield", 0);

        // ====== TERMINAL: residual-privilege sweep (script-audit run-26, L-04) ======
        // THE LAST STATEMENT BEFORE `stopBroadcast`, deliberately: revoke any deployer phUSD mint
        // grant and assert the whole end-state minter ACL. On this chain the deployer is never
        // granted (story 098 dropped both DeployMocks grants), so the revoke is a no-op kept for
        // parity; the ACL assertion is the part that matters on a public network.
        _sweepResidualPrivileges(deployer);

        vm.stopBroadcast();

        // ====== Write Progress File ======
        console.log("\n=== Writing Deployment Progress ===");
        _writeProgressFile();

        console.log("\n=== Deployment Complete (Sepolia, story 098) ===");
        console.log("All contracts deployed and configured successfully!");
        console.log("");
        console.log("Divergences from DeployMocks (see the contract header):");
        console.log("  - No StableStakerV1 / cutover rehearsal: StableStakerV2 + Antimatter wired directly");
        console.log("  - No DOLA repoint rehearsal: minter + SYA + V2 on YieldStrategyDola (sDOLA) from the start");
        console.log("  - AutoDOLA + YieldStrategyDolaLegacy deployed and tracked but IDLE");
        console.log("  - PhlimboV3 ships EMPTY (no anvil seed stakers) and DORMANT (no Kendu promo)");
        console.log("  - Story 137: NO BatchNFTMinterMultiToken / RatchetBatchNFTMinter (keys are 0x0 placeholders)");
        console.log("  - Story 137: NudgeDiscountBatchMinter wired in Phase 3.7 (no donor repoint); 1-day streams");
        console.log("  - Story 137: pot seeded via collectNudge; 5 deployer ratchets STAKED, then index 7 disabled");
        console.log("  - WETH-side UniV2 seeds faucet-sized (SEPOLIA_WETH_SEED)");
        console.log(
            "  - No UniPoolerV2 cutover rehearsal / no Balancer mocks: UniPoolerV2 at index 4 directly (story 104)"
        );
        console.log("  - Legacy Balancer keys emitted as zero-address placeholders by extract:sepolia");
        console.log("  - KEPT: index-6 disabled placeholder, so NudgeRatchet occupies index 7 as on mainnet");
        console.log("  - Story 136: PauserV2 / SYA gate-off / 1% discount constructed directly, not migrated");
        console.log("");
        console.log("Architecture Summary:");
        console.log("  - DOLA -> YieldStrategyDola (ERC4626YieldStrategy over MockSDOLA) -> PhusdStableMinter");
        console.log("  - USDC -> YieldStrategyUSDC (ERC4626YieldStrategy over MockAutoUSDC) -> PhusdStableMinter");
        console.log("  - USDe -> YieldStrategyUSDe (ERC4626MarketYieldStrategy) -> StableStakerV2");
        console.log(
            "  - SYA: reward USDC, 1% discount, NFT claim gate OFF, strategies YieldStrategyDola + YieldStrategyUSDC + YieldStrategyUSDe"
        );
        console.log("  - SYAHarvester: deployed by the sya-harvester:sepolia add-on (needs the UniswapHelper venues)");
        console.log("  - MockSUSDS share price 1.1 USDS; phUSD/sUSDS pair seeded at phUSD par");
        console.log("  - StableStakerV2 claimEnabled TRUE (DeployMocks Phase 11.13 end state)");
        console.log(
            "  - Global PauserV2 (`Pauser` key; no V1): minter, PhlimboV3, SYA, NFTMinterV2, NFTStaker, stakers, V2, Antimatter, NFTBonfire"
        );
        console.log("  - NFTBonfire: 10 AM/day, 100 AM cap (DeployMocks Phase 11.15)");
        console.log("  - Terminal sweep: deployer phUSD mint authority REVOKED, end-state ACL asserted");
        console.log("  - Owner of every contract: the deployer EOA (mock-stack exception, story 098)");
    }

    // =====================================================================
    // Story 070: Uniboost + Uniswap V2 helpers
    // =====================================================================

    /// @dev Deploys the canonical Uniswap V2 stack (WETH9 + Factory + Router02) and creates +
    ///      seeds the three TARGET pools (EYE/WETH9, SCX/USDS, FLX/DOLA) and three ROUTING pools
    ///      (USDC/WETH9, USDC/USDS, USDC/DOLA). Pairs are created BEFORE the Uniboost dispatchers
    ///      are constructed (their constructor reads pool.token0()/token1()).
    ///
    ///      Story 098: the WETH sides are FAUCET-SIZED. `SEPOLIA_WETH_SEED` (wei, default 0.1
    ///      ether) is the TOTAL native ETH wrapped, split evenly across the two WETH pools. The
    ///      token sides are scaled so the prices equal DeployMocks' (1,000 EYE per WETH9 and
    ///      2,000 USDC per WETH9). The non-WETH pools are pure mocks and keep DeployMocks' sizes:
    ///        SCX/USDS 100k:100k | FLX/DOLA 100k:100k | USDC/USDS 200k:200k | USDC/DOLA 200k:200k
    function _deployUniswapAndPools(address deployer) internal {
        uint256 gasBefore = gasleft();
        (weth9, uniFactory, uniRouter) = UniswapV2Deployer.deploy(deployer);
        _trackDeployment("WETH9", weth9, gasBefore - gasleft());
        _trackDeployment("UniswapV2Factory", address(uniFactory), 0);
        _trackDeployment("UniswapV2Router02", address(uniRouter), 0);
        console.log("Uniswap V2 deployed: WETH9", weth9);
        console.log("  Factory", address(uniFactory), "Router02", address(uniRouter));

        uint256 wethSeedTotal = vm.envOr("SEPOLIA_WETH_SEED", SEPOLIA_DEFAULT_WETH_SEED);
        uint256 wethPerPool = wethSeedTotal / 2;
        // Price-preserving token sides (DeployMocks: 100k EYE : 100 WETH, 200k USDC : 100 WETH).
        uint256 eyeForWeth = wethPerPool * 1_000; // 18dp EYE per 18dp WETH
        uint256 usdcForWeth = (wethPerPool * 2_000) / 10 ** 12; // 6dp USDC per 18dp WETH
        require(usdcForWeth > 0 && eyeForWeth > 0, "SEPOLIA_WETH_SEED too small to seed the WETH pools");
        console.log("WETH9 seed per WETH pool (wei):", wethPerPool);
        IWETH9Like(weth9).deposit{value: wethPerPool * 2}();

        // Mint mock balances for seeding. Mock mints are free; only the WETH side costs real ETH.
        eyeToken.mint(deployer, eyeForWeth);
        mockSCX.mint(deployer, 100_000 ether);
        mockFlax.mint(deployer, 100_000 ether);
        usds.mint(deployer, 300_000 ether);
        dola.mint(deployer, 300_000 ether);
        rewardToken.mint(deployer, 400_000 * 10 ** 6 + usdcForWeth); // USDC, 6dp

        // ---- Target pools ----
        poolEYE = _createAndSeed(deployer, address(eyeToken), weth9, eyeForWeth, wethPerPool);
        poolSCX = _createAndSeed(deployer, address(mockSCX), address(usds), 100_000 ether, 100_000 ether);
        poolFLX = _createAndSeed(deployer, address(mockFlax), address(dola), 100_000 ether, 100_000 ether);
        _trackDeployment("UniPoolEYE", poolEYE, 0);
        _trackDeployment("UniPoolSCX", poolSCX, 0);
        _trackDeployment("UniPoolFLX", poolFLX, 0);

        // ---- Routing pools (prime USDC -> pair token) ----
        routePoolWETH = _createAndSeed(deployer, address(rewardToken), weth9, usdcForWeth, wethPerPool);
        routePoolUSDS = _createAndSeed(deployer, address(rewardToken), address(usds), 200_000 * 10 ** 6, 200_000 ether);
        routePoolDOLA = _createAndSeed(deployer, address(rewardToken), address(dola), 200_000 * 10 ** 6, 200_000 ether);
        _trackDeployment("UniRoutePoolWETH", routePoolWETH, 0);
        _trackDeployment("UniRoutePoolUSDS", routePoolUSDS, 0);
        _trackDeployment("UniRoutePoolDOLA", routePoolDOLA, 0);
        console.log("Seeded 3 target + 3 routing UniV2 pools");
    }

    /// @dev createPair + addLiquidity for one pool, returning the pair address.
    /// @dev Story 098: deadline is `type(uint256).max`. On a slow public broadcast the timestamp
    ///      the script simulated against can be minutes stale by inclusion time, and Router02's
    ///      `ensure(deadline)` would revert "UniswapV2Router: EXPIRED". These are deployer-seeded
    ///      mock pools, so there is no MEV exposure a tight deadline would protect.
    function _createAndSeed(address deployer, address tokenA, address tokenB, uint256 amtA, uint256 amtB)
        internal
        returns (address pair)
    {
        pair = uniFactory.createPair(tokenA, tokenB);
        IERC20(tokenA).approve(address(uniRouter), amtA);
        IERC20(tokenB).approve(address(uniRouter), amtB);
        uniRouter.addLiquidity(tokenA, tokenB, amtA, amtB, 0, 0, deployer, type(uint256).max);
    }

    // =====================================================================
    // Story 104 (Balancexit Stage 3): UniPoolerV2 at index 4, deployed directly
    // =====================================================================

    /// @dev Creates the canonical mock-token phUSD/sUSDS UniV2 pair, deploys UniPoolerV2 against
    ///      it, then deploys `BalancerPoolerMintDebtHook` pointed at UniPoolerV2 and installs it
    ///      (hook -> pooler via the constructor, pooler -> hook via `setHook`). Called from Phase
    ///      3.6 BEFORE `registerDispatcher`, so index 4 is never registered with the default hook.
    ///      The pair is left reserve-less here and seeded in Phase 9.8.
    function _deployUniPoolerV2(address deployer) internal {
        require(
            uniFactory.getPair(address(susds), address(phUSD)) == address(0),
            "story-104: phUSD/sUSDS pair already exists on a fresh factory"
        );
        phusdSusdsPair = uniFactory.createPair(address(susds), address(phUSD));
        require(
            uniFactory.getPair(address(susds), address(phUSD)) == phusdSusdsPair,
            "story-104: phUSD/sUSDS pair is not the factory's canonical pair"
        );
        _trackDeployment("PhusdSusdsPair", phusdSusdsPair, 0);
        console.log("phUSD/sUSDS UniV2 pair created at:", phusdSusdsPair);

        uint256 gasBefore = gasleft();
        uniPoolerV2 = new UniPoolerV2(address(susds), address(phUSD), address(uniRouter), phusdSusdsPair, deployer);
        _trackDeployment("UniPoolerV2", address(uniPoolerV2), gasBefore - gasleft());
        console.log("UniPoolerV2 deployed at:", address(uniPoolerV2));
        require(uniPoolerV2.pair() == phusdSusdsPair, "story-104: UniPoolerV2 pair");
        // BatchNFTMinter's USDC whitelist depends on the index-4 prime token being USDS.
        require(uniPoolerV2.primeToken() == address(usds), "story-104: UniPoolerV2 prime token != USDS");

        gasBefore = gasleft();
        balancerPoolerHook = new BalancerPoolerMintDebtHook(deployer, address(uniPoolerV2), address(phUSD));
        _trackDeployment("BalancerPoolerMintDebtHook", address(balancerPoolerHook), gasBefore - gasleft());
        console.log("BalancerPoolerMintDebtHook deployed at:", address(balancerPoolerHook));
        uniPoolerV2.setHook(IDispatchHook(address(balancerPoolerHook)));
        require(
            balancerPoolerHook.dispatcher() == address(uniPoolerV2)
                && address(uniPoolerV2.hook()) == address(balancerPoolerHook),
            "story-104: hook not wired both ways"
        );
        console.log("UniPoolerV2.setHook -> BalancerPoolerMintDebtHook (hook.dispatcher == UniPoolerV2)");
    }

    /// @dev Phase 9.8: seeds the pair at phUSD-par (1 sUSDS : 1.1 phUSD, the Phase 1 sUSDS premium)
    ///      from the deployer's own sUSDS and minter-minted phUSD,
    ///      LP to the deployer (a mock-stack seed, like every other pool here), then asserts the
    ///      whole index-4 end state the story-101 rehearsal leaves DeployMocks in.
    function _seedPhusdSusdsPairAndAssertIndex4(address deployer) internal {
        console.log("\n=== Phase 9.8: Seed phUSD/sUSDS UniV2 pair (story 104) ===");
        require(susds.balanceOf(deployer) >= SEPOLIA_PAIR_SUSDS_SEED, "story-104: deployer lacks the sUSDS seed");
        require(phUSD.balanceOf(deployer) >= SEPOLIA_PAIR_PHUSD_SEED, "story-104: deployer lacks the phUSD seed");
        IERC20(address(susds)).approve(address(uniRouter), SEPOLIA_PAIR_SUSDS_SEED);
        IERC20(address(phUSD)).approve(address(uniRouter), SEPOLIA_PAIR_PHUSD_SEED);
        // Fresh pair (asserted reserve-less at creation), so the router adds exactly the desired
        // amounts. Deadline as in `_createAndSeed` (slow public broadcast).
        uniRouter.addLiquidity(
            address(susds),
            address(phUSD),
            SEPOLIA_PAIR_SUSDS_SEED,
            SEPOLIA_PAIR_PHUSD_SEED,
            SEPOLIA_PAIR_SUSDS_SEED,
            SEPOLIA_PAIR_PHUSD_SEED,
            deployer,
            type(uint256).max
        );
        (uint112 r0, uint112 r1,) = ISepoliaUniV2PairLike(phusdSusdsPair).getReserves();
        bool s0 = ISepoliaUniV2PairLike(phusdSusdsPair).token0() == address(susds);
        require(
            (s0 ? r0 : r1) == SEPOLIA_PAIR_SUSDS_SEED && (s0 ? r1 : r0) == SEPOLIA_PAIR_PHUSD_SEED,
            "story-104: pair reserves != seed"
        );
        console.log("Seeded phUSD/sUSDS pair - sUSDS:", SEPOLIA_PAIR_SUSDS_SEED);
        console.log("Seeded phUSD/sUSDS pair - phUSD:", SEPOLIA_PAIR_PHUSD_SEED);

        // The index-4 end state (cf. DeployMocks `_assertUniPoolerCutover`, minus the cutover).
        (address d,, uint256 growth, bool disabled) = nftMinterV2.configs(UNI_POOLER_INDEX);
        require(d == address(uniPoolerV2) && growth == 10 && !disabled, "story-104: configs(4) != UniPoolerV2");
        require(uniPoolerV2.sUSDSIsToken0() == s0, "story-104: UniPoolerV2 token order");
        require(
            balancerPoolerHook.dispatcher() == address(uniPoolerV2)
                && address(uniPoolerV2.hook()) == address(balancerPoolerHook),
            "story-104: index-4 hook not wired both ways"
        );
        require(balancerPoolerHook.recipient() == address(nftStaker), "story-104: hook recipient != NFTStaker");
        require(
            uniPoolerV2.psm() == address(mockSkyPSM) && uniPoolerV2.maxTout() == 0.01e18
                && uniPoolerV2.batchMinter() == address(nudgeDiscountMinter)
                && uniPoolerV2.batchDonationSize() == MOCK_BATCH_DONATION_SIZE
                && uniPoolerV2.nudgeStreamer() == address(nudgeStreamer),
            "story-104: UniPoolerV2 donation config"
        );
        require(
            uniPoolerV2.poolerAuthVersion(deployer) == uniPoolerV2.authVersion(),
            "story-104: deployer not an authorized pooler on UniPoolerV2"
        );
        require(uniPoolerV2.owner() == deployer, "story-104: UniPoolerV2 owner");
        require(!uniPoolerV2.paused(), "story-104: UniPoolerV2 paused");
        (address d6,,, bool disabled6) = nftMinterV2.configs(6);
        require(d6 == address(buggedPoolerV2Index6) && disabled6, "story-104: index-6 placeholder not disabled");
        console.log("Index-4 end state asserted: UniPoolerV2, hook both ways, donation config, pooler auth");
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

    /// @dev Deferred (Phase 3.7) per-dispatcher donation wiring: 50% of mint USDC -> nudgeDiscountMinter
    ///      (the UniPoolerV2 index-4 LSP batch minter), remaining 50% retained for pool().
    /// @dev Story 073: the donation branch is now streamer-gated. `Uniboost._dispatch` reverts
    ///      `"Uniboost: nudgeStreamer unset"` whenever `donationAmount > 0` and no streamer is
    ///      wired — i.e. every mint on indices 1/2/3. `setNudgeStreamer` therefore is NOT optional
    ///      polish; it is what keeps these three dispatchers mintable at all. Mandated ordering
    ///      (Uniboost.sol:38-41) is whitelist -> registerStream -> setNudgeStreamer, and the first
    ///      two already ran in `_deployStreamerAndNudgeDiscountMinter`.
    function _finalizeUniboost(Uniboost dispatcher, UniboostMintDebtHook, address batchMinter, address) internal {
        dispatcher.setRecipient(batchMinter);
        dispatcher.setDonationSplit(50);
        dispatcher.setNudgeStreamer(address(nudgeStreamer));
    }

    /// @dev Two static claims about the index-7 hook, asserted rather than exercised by a swap.
    ///      Actually swapping index 7 would mean re-wiring `RatchetNFTStaker`,
    ///      the nudge streamer and the target APY on the exact chain the
    ///      UI is about to be tested against; blast radius won. These two read-only assertions
    ///      regression-gate the claims for free, so a hook or ratio drift still fails the run
    ///      loudly.
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

    // =====================================================================
    // Story 136: DeployMocks Phases 11.15-11.17 on Sepolia (end state, constructed directly)
    // =====================================================================

    /// @dev Set by `_deployNFTBonfire`. Tracked as "NFTBonfire" (ContractAddresses key `NFTBonfire`).
    NFTBonfire public nftBonfire;

    /// @dev Phase 11.15 (DeployMocks story 125). Deploys NFTBonfire and wires it through
    ///      `NFTBonfireLocalWiring` (burner -> AM minter -> pauser + register -> cap -> rate LAST, each
    ///      read back), using the library's PauserV2 overload because this chain has no V1. Mainnet
    ///      params, which are DeployMocks' params: ratePerDay 10 AM, maxPayout 100 AM (library
    ///      constants). The deployer owns NFTMinterV2, Antimatter and PauserV2 and stays bonfire owner.
    function _deployNFTBonfire(address deployer) internal {
        console.log("\n=== Phase 11.15: NFTBonfire (story 136, DeployMocks story 125) ===");

        uint256 gasBefore = gasleft();
        nftBonfire = NFTBonfireLocalWiring.deploy(deployer, nftMinterV2, antimatter);
        _trackDeployment("NFTBonfire", address(nftBonfire), gasBefore - gasleft());
        require(nftBonfire.owner() == deployer, "story-136: bonfire owner is not the deployer");

        NFTBonfireLocalWiring.wire(nftBonfire, nftMinterV2, antimatter, pauser);
        require(nftBonfire.pendingPayout() == 0, "story-136: bonfire pot must start empty");

        console.log("  NFTBonfire:", address(nftBonfire));
        console.log("  ratePerDay:", nftBonfire.ratePerDay());
        console.log("  maxPayout:", nftBonfire.maxPayout());
        console.log("  pauser (PauserV2):", nftBonfire.pauser());
    }

    /// @dev The SYA NFT claim gate is OFF: no NFT minter, no SYA burner right on NFTMinterV2, and an
    ///      NFT-less address can claim. The same three read-backs `SyaGateOffLocal.turnGateOff` ends on.
    function _requireSyaGateOff() internal view {
        require(stableYieldAccumulator.nftMinter() == address(0), "story-136: SYA NFT claim gate is not off");
        require(
            !nftMinterV2.authorizedBurners(address(stableYieldAccumulator)),
            "story-136: SYA must not be an NFTMinterV2 burner with the gate off"
        );
        require(
            stableYieldAccumulator.canClaim(SYA_GATE_OFF_PROBE),
            "story-136: canClaim(probe) must be true with the gate off"
        );
    }

    /// @dev Terminal end-state assertions for the story-136 ports, called from the sweep:
    ///        - PauserV2 holds EXACTLY the expected registrant set, each with pauser() == PauserV2,
    ///          and `health()` reports nothing that would make pause() miss or revert;
    ///        - the SYA gate is still off and the discount is still 1%;
    ///        - the bonfire is still wired (burner, AM minter, pauser, cap, rate) and owned by the deployer.
    function _requireStory136EndState() internal view {
        address[] memory expected = new address[](EXPECTED_PAUSER_REGISTRANTS);
        expected[0] = address(phlimboV3);
        expected[1] = address(uniboostStakerEYE);
        expected[2] = address(uniboostStakerSCX);
        expected[3] = address(uniboostStakerFLX);
        expected[4] = address(nudgeDiscountMinter);
        expected[5] = address(minter);
        expected[6] = address(stableYieldAccumulator);
        expected[7] = address(nftMinterV2);
        expected[8] = address(nftStaker);
        expected[9] = address(stableStakerV2);
        expected[10] = address(antimatter);
        expected[11] = address(nftBonfire);

        address[] memory registered = pauser.getPausableContracts();
        require(registered.length == EXPECTED_PAUSER_REGISTRANTS, "story-136: PauserV2 registrant count mismatch");
        for (uint256 i = 0; i < expected.length; i++) {
            require(expected[i] != address(0), "story-136: expected PauserV2 registrant not deployed");
            require(pauser.isRegistered(expected[i]), "story-136: contract not registered on PauserV2");
            require(
                IPausableSepoliaLike(expected[i]).pauser() == address(pauser),
                "story-136: registrant pauser() is not PauserV2"
            );
        }
        PauserV2LocalMigration.requireHealthy(pauser);

        _requireSyaGateOff();
        require(stableYieldAccumulator.getDiscountRate() == SYA_FINAL_DISCOUNT_BPS, "story-136: SYA discount is not 1%");

        require(nftMinterV2.authorizedBurners(address(nftBonfire)), "story-136: bonfire is not an NFTMinterV2 burner");
        require(antimatter.isApprovedMinter(address(nftBonfire)), "story-136: bonfire is not an AM minter");
        require(nftBonfire.pauser() == address(pauser), "story-136: bonfire pauser is not PauserV2");
        require(nftBonfire.maxPayout() == NFTBonfireLocalWiring.MAX_PAYOUT, "story-136: bonfire maxPayout");
        require(nftBonfire.ratePerDay() == NFTBonfireLocalWiring.RATE_PER_DAY, "story-136: bonfire ratePerDay");

        console.log("  story-136 end state asserted: PauserV2 registrants (exact set):", registered.length);
        console.log("  SYA gate off + 1% discount; NFTBonfire wired (burner, AM minter, PauserV2, cap, rate)");
    }

    /// @dev Revokes the deployer's phUSD mint authority and then asserts the WHOLE expected
    ///      end-state ACL declaratively, so a future grant that forgets to clean up fails the run.
    ///
    ///      Story 098: on this chain the deployer is never granted phUSD mint authority at all —
    ///      the two DeployMocks grants (PhlimboV3 seed stakers, donorless nudge-stream seeding) are
    ///      both dropped. The revoke is kept anyway: it is idempotent and keeps the sweep a literal
    ///      mirror of the local one, so a future re-derivation that re-adds a grant is still caught.
    function _sweepResidualPrivileges(address deployer) internal {
        console.log("\n=== Terminal: residual-privilege sweep (script-audit run-26, L-04) ===");

        phUSD.setMinter(deployer, false);
        console.log("  phUSD.setMinter(deployer, false) - mint authority REVOKED");

        // The expected end-state ACL, as a table. Any drift names its own offender.
        _requireLiveMinter(deployer, false, "deployer");
        _requireLiveMinter(address(phlimboV3), true, "PhlimboV3");
        _requireLiveMinter(address(minter), true, "PhusdStableMinter");
        // StableStakerV2 holds the live grant — not as a reward right (its reward token is
        // Antimatter) but as `autoAnnihilate`'s shortfall cover, without which that reward path
        // reverts. There is no StableStakerV1 on this chain (story 098).
        _requireLiveMinter(address(stableStakerV2), true, "StableStakerV2");
        _requireLiveMinter(address(antimatter), true, "Antimatter");
        _requireLiveMinter(address(balancerPoolerHook), true, "BalancerPoolerMintDebtHook");
        _requireLiveMinter(address(nudgeRatchetHook), true, "NudgeRatchetMintDebtHook");
        _requireLiveMinter(address(uniboostHookEYE), true, "UniboostHookEYE");
        _requireLiveMinter(address(uniboostHookSCX), true, "UniboostHookSCX");
        _requireLiveMinter(address(uniboostHookFLX), true, "UniboostHookFLX");

        // Story 136: Antimatter mint rights - the deployer never holds one on this chain.
        require(
            !antimatter.isApprovedMinter(deployer), "RESIDUAL PRIVILEGE SWEEP FAILED: deployer is an Antimatter minter"
        );
        _requireStory136EndState();
        _requireStory137EndState(deployer);

        console.log(
            "  end-state phUSD ACL asserted: deployer OUT, PhlimboV3 + minter + StableStakerV2 + Antimatter + 5 hooks IN"
        );
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
    // Story 080: Antimatter + StableStakerV2 (deployed directly, story 098)
    // =====================================================================

    /// @dev Deploys the Antimatter reward token and StableStakerV2, wires both, and registers the
    ///      three pools (DOLA on the sDOLA strategy, USDC, USDe) at DeployMocks' rates.
    ///
    ///      ORDER IS LOAD-BEARING at three points and each one fails differently:
    ///        - `setPhUSD` BEFORE `setPhUSDMinter`: the second reverts `PhUSDNotSet` otherwise,
    ///          and once both are set each refuses a value the other disagrees with.
    ///        - `setApprovedMinter` is a SILENT NO-OP with no event when the status already
    ///          matches, so the grant is verified by READING `isApprovedMinter`. An event check
    ///          would prove nothing.
    ///        - per pool: `addToken` -> `strategy.setClient` -> `setYieldStrategy` ->
    ///          `setSetAsideBuffer` -> rate setter. The two-sided strategy wiring is mandatory;
    ///          without `setClient` both stake and withdraw revert.
    ///
    ///      BOTH mint rights are granted and they are NOT interchangeable. Antimatter is the
    ///      reward token V2 pays (`setApprovedMinter`). phUSD is NOT a second reward: V2 mints it
    ///      only to cover an annihilation shortfall inside `autoAnnihilate` (`phUSD.setMinter`).
    ///      Antimatter itself also receives a phUSD mint right, because `annihilate` mints the
    ///      antimatter half of the payout directly.
    function _deployAntimatterAndStableStakerV2(address deployer) internal {
        console.log("\n=== Phase 6.5a: Deploying Antimatter + StableStakerV2 (story 080) ===");

        // ---- 1. Antimatter. Constructor takes ONLY the owner; phUSD and the stable minter are
        //         attached afterwards by two owner calls that cross-check each other. ----
        uint256 gasBefore = gasleft();
        antimatter = new Antimatter(deployer);
        _trackDeployment("Antimatter", address(antimatter), gasBefore - gasleft());
        console.log("  Antimatter deployed at:", address(antimatter));

        // ---- 2/3. phUSD first, THEN the stable minter. ----
        antimatter.setPhUSD(IFlaxStaker(address(phUSD)));
        antimatter.setPhUSDMinter(minter);
        require(address(antimatter.phUSD()) == address(phUSD), "story-080: Antimatter.phUSD did not land");
        require(address(antimatter.phUSDMinter()) == address(minter), "story-080: Antimatter.phUSDMinter did not land");
        console.log("  Antimatter wired to phUSD + PhusdStableMinter");

        // ---- 4. StableStakerV2. Its constructor takes the ANTIMATTER token, not phUSD, and
        //         reverts "StableStaker: zero antimatter" on a zero address. ----
        gasBefore = gasleft();
        stableStakerV2 = new StableStakerV2(IAntimatter(address(antimatter)), deployer);
        _trackDeployment("StableStakerV2", address(stableStakerV2), gasBefore - gasleft());
        console.log("  StableStakerV2 deployed at:", address(stableStakerV2));
        require(stableStakerV2.STAKER_VERSION() == 2, "story-080: deployed staker is not version 2");

        // ---- 5. The REWARD-token grant. Read back, never trust the (absent) event. ----
        antimatter.setApprovedMinter(address(stableStakerV2), true);
        require(
            antimatter.isApprovedMinter(address(stableStakerV2)),
            "story-080: StableStakerV2 is not an approved Antimatter minter"
        );
        console.log("  Antimatter.setApprovedMinter(StableStakerV2) - VERIFIED by read-back");

        // ---- 6. The SHORTFALL-COVER grant. Must come after step 2: `phUSDMintAvailable` resolves
        //         the token live off `Antimatter.phUSD`, so an unwired Antimatter reads false no
        //         matter what phUSD's own ACL says. ----
        phUSD.setMinter(address(stableStakerV2), true);
        require(
            stableStakerV2.phUSDMintAvailable(),
            "story-080: StableStakerV2 cannot mint phUSD (autoAnnihilate shortfall cover is dead)"
        );
        console.log("  phUSD.setMinter(StableStakerV2) - VERIFIED via phUSDMintAvailable()");

        // ---- 7. The ANNIHILATION grant. `Antimatter.annihilate` pays its antimatter half with
        //         `_phUSD.mint(recipient, amount)`, so without this grant every annihilation (and
        //         therefore V2's `autoAnnihilate` reward path) reverts. Mirrors Phase 5 of
        //         CutoverStableStakerV2Mainnet.s.sol. Verified at the CURRENT mintVersion. ----
        phUSD.setMinter(address(antimatter), true);
        _requireLiveMinter(address(antimatter), true, "Antimatter (post-grant)");
        console.log("  phUSD.setMinter(Antimatter) - VERIFIED at current mintVersion");

        // ---- 8/9. The three pools. ----
        address[3] memory ssTokens = [address(dola), address(rewardToken), address(usde)];
        AYieldStrategy[3] memory ssStrats =
            [AYieldStrategy(yieldStrategyDola), AYieldStrategy(yieldStrategyUSDC), AYieldStrategy(yieldStrategyUSDe)];
        for (uint256 i = 0; i < 3; i++) {
            stableStakerV2.addToken(ssTokens[i]);
            ssStrats[i].setClient(address(stableStakerV2), true); // mandatory two-sided wiring
            stableStakerV2.setYieldStrategy(ssTokens[i], IYieldStrategy(address(ssStrats[i])));
            ssStrats[i].setSetAsideBuffer(address(stableStakerV2), 10);
            // The recipient is GLOBAL per strategy, not per client, and V2 is the only staker here.
            ssStrats[i].setSetAsideBufferRecipient(address(stableStakerV2));
            require(
                ssStrats[i].setAsideBufferRecipient() == address(stableStakerV2),
                "story-080: setAsideBufferRecipient not repointed to StableStakerV2"
            );
            // Same rates DeployMocks uses (USDC 5/day, DOLA + USDe 10/day).
            // Units are 18-decimal REWARD-token wei per day regardless of the staked token's
            // decimals, and the setter floors (perSecond = perDay / 86400).
            uint256 dailyRate = ssTokens[i] == address(rewardToken) ? 5e18 : 10e18;
            stableStakerV2.antimatterPerDay(ssTokens[i], dailyRate);
            // The stablecoin half of `autoAnnihilate` is priced through the stable minter, so a
            // pool token that is not a registered stablecoin has a dead reward path. Phase 6
            // registers all three; this is the fail-closed probe of that.
            require(
                stableStakerV2.autoAnnihilateAvailable(ssTokens[i]),
                "story-080: pool token is not registered on PhusdStableMinter - autoAnnihilate is dead"
            );
            console.log("  StableStakerV2 pool wired (token / antimatter-per-day):", ssTokens[i], dailyRate);
        }

        // ---- 10. Claims OPEN. DeployMocks keeps story 080's closed-claim assertion and then
        //          opens claims in Phase 11.13, a trial run of the imminent mainnet unblock that lets
        //          the UI annihilate HELD Antimatter (only `claim` leaves Antimatter in a staker's
        //          wallet; `autoAnnihilate` burns it against principal). This chain has no history
        //          to replay, so it lands directly in that end state. ----
        stableStakerV2.setClaimEnabled(true);
        require(stableStakerV2.claimEnabled(), "claim unblock: claimEnabled must be true");
        console.log("  StableStakerV2: 3 pools wired, claimEnabled set TRUE (DeployMocks Phase 11.13 end state)");
    }

    /// @dev Phase 1 (Sepolia only): donates `SEPOLIA_SUSDS_PREMIUM_BPS` of the baseline deposit as
    ///      yield, so 1 sUSDS = 1.1 USDS while the deployer is still the only shareholder.
    function _priceSusdsAtPremium(uint256 baselineDeposit) internal {
        susds.addYield(baselineDeposit * SEPOLIA_SUSDS_PREMIUM_BPS / 10_000);
        uint256 sharePrice = susds.convertToAssets(1e18);
        require(sharePrice > 1.0999e18 && sharePrice <= 1.1e18, "sepolia: sUSDS share price != 1.1 USDS");
        console.log("MockSUSDS share price (USDS per sUSDS, 18dp):", sharePrice);
    }

    /// @dev Phase 9.57. Stakes 5,000 USDe into StableStakerV2 from the deployer (the strategy's only
    ///      client here, as on anvil, where the principal arrives with the migrated V1 stakers; the
    ///      stable minter is deliberately NOT a USDe-strategy client). The principal lands in
    ///      MockSUSDe through the AMM adapter. Then 1,000 USDe of yield is donated to MockSUSDe. The
    ///      strategy holds about a third of the sUSDe shares (the deployer holds the Phase 1
    ///      baseline), so SYA sees roughly 330 USDe of claimable yield.
    function _seedUsdeStrategyAndYield() internal {
        console.log("\n=== Phase 9.57: Seed YieldStrategyUSDe via a StableStakerV2 stake + USDe yield ===");
        uint256 usdeAmount = 5000 * 10 ** 18;
        usde.approve(address(stableStakerV2), usdeAmount);
        stableStakerV2.stake(address(usde), usdeAmount);
        usde.approve(address(stableStakerV2), 0);
        require(susde.balanceOf(address(yieldStrategyUSDe)) > 0, "sepolia: USDe stake left YieldStrategyUSDe empty");
        console.log("Deployer staked 5000 USDe into StableStakerV2 (deposited to YieldStrategyUSDe)");

        susde.addYield(1000 * 10 ** 18);
        require(
            stableYieldAccumulator.calculateClaimAmount(_allSyaStrategiesExcept(address(yieldStrategyUSDe))) > 0,
            "sepolia: SYA sees no claimable USDe yield"
        );
        console.log("Minted 1000 USDe directly to MockSUSDe as yield; SYA USDe claim amount > 0");
    }

    /// @dev Every registered SYA strategy except `keep`: the exemption list that makes
    ///      `calculateClaimAmount` price `keep` alone.
    function _allSyaStrategiesExcept(address keep) internal view returns (address[] memory exempt) {
        address[] memory all = stableYieldAccumulator.getYieldStrategies();
        exempt = new address[](all.length - 1);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i] != keep) exempt[j++] = all[i];
        }
    }

    /// @dev Story 098 — the DOLA end state DeployMocks reaches only after its Phase 9.7 repoint
    ///      rehearsal, asserted here where it is reached directly: the minter, SYA and
    ///      StableStakerV2 all sit on the sDOLA strategy, and the legacy autoDOLA strategy is idle.
    function _assertDolaOnSDola() internal view {
        (address ys, uint256 rate, uint8 dec, bool enabled, uint256 maxMintPerDay,,) =
            minter.stablecoinConfigs(address(dola));
        require(ys == address(yieldStrategyDola), "story-098: minter DOLA registration is not the sDOLA strategy");
        require(rate == 1e18 && dec == 18, "story-098: minter DOLA rate/decimals wrong");
        require(enabled, "story-098: minter DOLA registration is disabled");
        require(maxMintPerDay == 0, "story-098: minter DOLA maxMintPerDay is not the uncapped end state");
        require(
            yieldStrategyDola.principalOf(address(dola), address(minter)) > 0,
            "story-098: minter holds no DOLA principal on the sDOLA strategy"
        );
        require(
            yieldStrategyDolaLegacy.principalOf(address(dola), address(minter)) == 0,
            "story-098: minter DOLA principal landed on the legacy strategy"
        );
        require(
            stableYieldAccumulator.isRegisteredStrategy(address(yieldStrategyDola)),
            "story-098: SYA does not list the sDOLA strategy"
        );
        require(
            !stableYieldAccumulator.isRegisteredStrategy(address(yieldStrategyDolaLegacy)),
            "story-098: SYA lists the idle legacy strategy"
        );
        require(
            yieldStrategyDola.authorizedWithdrawers(address(stableYieldAccumulator)),
            "story-098: SYA is not a withdrawer on the sDOLA strategy"
        );
        require(
            !yieldStrategyDolaLegacy.authorizedWithdrawers(address(stableYieldAccumulator)),
            "story-098: SYA is a withdrawer on the idle legacy strategy"
        );
        require(
            yieldStrategyDola.setAsideBufferRecipient() == address(stableStakerV2),
            "story-098: sDOLA strategy set-aside recipient is not StableStakerV2"
        );
        console.log("  DOLA end state asserted: minter + SYA + StableStakerV2 on sDOLA, legacy strategy idle");
    }

    // =====================================================================
    // Story 137: NudgeStreamer + BatchNFTMinterNudgeDiscount (the only donor sink)
    // =====================================================================

    /// @dev Phase 3.7. Deploys the `NudgeStreamer` and `BatchNFTMinterNudgeDiscount` and wires the
    ///      minter in the order the mainnet cutover's Phase 2 uses (`DeployMainnetNudgeDiscount.s.sol`
    ///      `_phase2_deployAndConfigure`), every value set explicitly (even where it equals the
    ///      constructor default) and read back:
    ///        1. deploy + track (`NudgeDiscountBatchMinter`);
    ///        2. tokenMinter + dispatcher index 4 (asserted to be UniPoolerV2, prime token USDS);
    ///        3. whitelist USDC, phUSD, Kendu (BEFORE setDiscountToken, which needs a whitelisted token);
    ///        4. discount token USDC, discount 50, burn 100, NFTStaker, mint-debt hook (ratio 50 and
    ///           recipient NFTStaker asserted first), PSM, sUSDS, swap route (after sUSDS: it validates
    ///           the pair against it), the deployer as authorised buyer (mainnet: OWNER; the Sepolia
    ///           deployer IS the owner of everything here);
    ///        5. cap 50, 3 overflow NFTs per boost point, maxBoost 0 (DAY1), then
    ///           `require(boostDonationSafe())`;
    ///        6. setPauser(PauserV2) THEN PauserV2.register (register validates pauser() == itself);
    ///        7. registerStream for USDC, phUSD and Kendu (whitelisted first, as the streamer requires);
    ///        8. setNudgeStreamer;
    ///        9. LAST: NFTMinterV2.setAuthorizedMinter(minter, true) - the free-mint grant goes in only
    ///           once the pause wiring (the only kill switch for free mints) is live.
    ///      Unlike mainnet there is no donor to repoint afterwards: every donor is wired to this minter
    ///      later in `run()`, from construction.
    function _deployStreamerAndNudgeDiscountMinter(address deployer) internal {
        uint256 gasBefore = gasleft();
        nudgeStreamer = new NudgeStreamer(deployer);
        _trackDeployment("NudgeStreamer", address(nudgeStreamer), gasBefore - gasleft());
        console.log("NudgeStreamer deployed at:", address(nudgeStreamer));

        // 1. Deploy + track.
        gasBefore = gasleft();
        nudgeDiscountMinter = new BatchNFTMinterNudgeDiscount(deployer);
        _trackDeployment("NudgeDiscountBatchMinter", address(nudgeDiscountMinter), gasBefore - gasleft());
        BatchNFTMinterNudgeDiscount m = nudgeDiscountMinter;
        require(m.owner() == deployer, "story-137: nudge-discount minter owner is not the deployer");
        console.log("BatchNFTMinterNudgeDiscount deployed at:", address(m));

        // 2. Pinned NFT minter + dispatcher index 4 (UniPoolerV2, USDS-primed, so USDC is whitelistable).
        require(
            nftMinterV2.dispatcherToIndex(address(uniPoolerV2)) == UNI_POOLER_INDEX,
            "story-137: UniPoolerV2 is not NFTMinterV2 index 4"
        );
        require(uniPoolerV2.primeToken() == address(usds), "story-137: index-4 prime token must be USDS");
        m.setTokenMinter(ITokenMinterV2(address(nftMinterV2)));
        m.setDispatcherIndex(UNI_POOLER_INDEX);
        require(address(m.tokenMinter()) == address(nftMinterV2), "story-137: tokenMinter");
        require(m.dispatcherIndex() == UNI_POOLER_INDEX, "story-137: dispatcherIndex");

        // 3. Whitelist in mainnet's `_nudgeTokens()` order: USDC (discount token), phUSD, Kendu (bonus).
        m.setNudgeTokenWhitelist(address(rewardToken), true);
        m.setNudgeTokenWhitelist(address(phUSD), true);
        m.setNudgeTokenWhitelist(address(mockKendu), true);
        require(m.getNudgeTokens().length == 3, "story-137: expected 3 whitelisted nudge tokens");

        // 4. Discount + buy configuration.
        _configureNudgeDiscount(m, deployer);

        // 5. Cap / boost terms (the audit-27 cutover gate values), then the Safeguard-4 constraint.
        m.setMaxFreePerBatch(NUDGE_DISCOUNT_MAX_FREE_PER_BATCH);
        m.setOverflowNFTsPerBoostPoint(NUDGE_DISCOUNT_OVERFLOW_NFTS_PER_BOOST_POINT);
        m.setMaxBoost(NUDGE_DISCOUNT_DAY1_MAX_BOOST);
        require(m.maxFreePerBatch() == NUDGE_DISCOUNT_MAX_FREE_PER_BATCH, "story-137: maxFreePerBatch");
        require(
            m.overflowNFTsPerBoostPoint() == NUDGE_DISCOUNT_OVERFLOW_NFTS_PER_BOOST_POINT,
            "story-137: overflowNFTsPerBoostPoint"
        );
        require(m.maxBoost() == NUDGE_DISCOUNT_DAY1_MAX_BOOST, "story-137: maxBoost != DAY1 (0)");
        require(m.boostDonationSafe(), "story-137: boostDonationSafe() is false after configuration - refusing");

        // 6. Pause wiring on PauserV2 (the `Pauser` key; this chain has no V1).
        m.setPauser(address(pauser));
        pauser.register(address(m));
        require(m.pauser() == address(pauser) && pauser.isRegistered(address(m)), "story-137: PauserV2 wiring");

        // 7. Streams for all three tokens (mainnet's token set) at the short Sepolia window. They must
        //    exist before any donor is pointed at the streamer, or the first donation reverts.
        address[3] memory toks = [address(rewardToken), address(phUSD), address(mockKendu)];
        for (uint256 i = 0; i < 3; i++) {
            nudgeStreamer.registerStream(address(m), toks[i], SEPOLIA_NUDGE_DISCOUNT_STREAM_DURATION);
            (uint256 dur,,,) = nudgeStreamer.streams(address(m), toks[i]);
            require(dur == SEPOLIA_NUDGE_DISCOUNT_STREAM_DURATION, "story-137: stream duration did not land");
        }
        console.log(
            "NudgeStreamer streams registered (USDC, phUSD, Kendu), duration:", SEPOLIA_NUDGE_DISCOUNT_STREAM_DURATION
        );

        // 8. batchMint learns to flush its accrued streams.
        m.setNudgeStreamer(address(nudgeStreamer));
        require(m.nudgeStreamer() == address(nudgeStreamer), "story-137: nudgeStreamer");

        // 9. LAST: the free-mint grant on NFTMinterV2 (the deployer owns it).
        nftMinterV2.setAuthorizedMinter(address(m), true);
        require(nftMinterV2.authorizedMinters(address(m)), "story-137: mintFor authority not granted");
        console.log("NudgeDiscountBatchMinter configured, PauserV2-registered, NFTMinterV2 mintFor authority granted");
    }

    /// @dev Step 4 of `_deployStreamerAndNudgeDiscountMinter`, split out for the stack. Every setter is
    ///      read back.
    function _configureNudgeDiscount(BatchNFTMinterNudgeDiscount m, address deployer) internal {
        m.setDiscountToken(address(rewardToken));
        m.setDiscountPercent(NUDGE_DISCOUNT_PERCENT);
        m.setBurnPercent(NUDGE_DISCOUNT_BURN_PERCENT);
        m.setNFTStaker(address(nftStaker));

        require(
            balancerPoolerHook.ratio() == NUDGE_DISCOUNT_HOOK_RATIO,
            "story-137: BalancerPoolerMintDebtHook ratio is not 50"
        );
        require(balancerPoolerHook.recipient() == address(nftStaker), "story-137: hook recipient is not NFTStaker");
        m.setMintDebtHook(IMintDebtRatio(address(balancerPoolerHook)));

        require(mockSkyPSM.gem() == address(rewardToken), "story-137: MockSkyPSM gem is not USDC");
        m.setPSM(INudgeDiscountPSM(address(mockSkyPSM)));
        require(susds.asset() == mockSkyPSM.usds(), "story-137: sUSDS asset is not the PSM's USDS");
        m.setSUSDS(IERC4626(address(susds)));
        require(
            uniFactory.getPair(address(susds), address(phUSD)) == phusdSusdsPair,
            "story-137: factory does not resolve the phUSD/sUSDS pair"
        );
        m.setSwapRoute(address(uniRouter), phusdSusdsPair, address(phUSD)); // after setSUSDS
        m.setAuthorizedBuyer(deployer, true);

        require(address(m.discountToken()) == address(rewardToken), "story-137: discountToken");
        require(
            m.discountPercent() == NUDGE_DISCOUNT_PERCENT && m.burnPercent() == NUDGE_DISCOUNT_BURN_PERCENT,
            "story-137: discount/burn percent"
        );
        require(m.nftStaker() == address(nftStaker), "story-137: nftStaker");
        require(address(m.mintDebtHook()) == address(balancerPoolerHook), "story-137: mintDebtHook");
        require(address(m.psm()) == address(mockSkyPSM) && address(m.sUSDS()) == address(susds), "story-137: psm/sUSDS");
        require(
            m.router() == address(uniRouter) && m.pair() == phusdSusdsPair && m.phUSD() == address(phUSD),
            "story-137: swap route"
        );
        require(m.buyerAuthVersion(deployer) == m.authVersion(), "story-137: deployer is not an authorised buyer");
        address[] memory bonus = m.getBonusTokens();
        require(
            bonus.length == 2 && bonus[0] == address(phUSD) && bonus[1] == address(mockKendu),
            "story-137: bonus tokens must be [phUSD, Kendu]"
        );
    }

    /// @dev Phase 11.18. Seeds the discount pot through the streamer: USDC, phUSD, Kendu. phUSD needs a
    ///      deployer mint right this chain otherwise never grants, so it is granted, used and revoked
    ///      here, with a two-field read-back of the revoke (the terminal sweep asserts it again).
    function _seedNudgeDiscountPot(address deployer) internal {
        console.log("\n=== Phase 11.18: seed the nudge-discount pot via NudgeStreamer.collectNudge (story 137) ===");
        rewardToken.mint(deployer, SEPOLIA_POT_USDC_SEED);
        _donateToNudgeStream(deployer, address(rewardToken), SEPOLIA_POT_USDC_SEED);

        phUSD.setMinter(deployer, true);
        phUSD.mint(deployer, SEPOLIA_POT_PHUSD_SEED);
        phUSD.setMinter(deployer, false);
        _requireLiveMinter(deployer, false, "deployer (after the phUSD pot seed)");
        _donateToNudgeStream(deployer, address(phUSD), SEPOLIA_POT_PHUSD_SEED);

        mockKendu.mint(deployer, SEPOLIA_POT_KENDU_SEED);
        _donateToNudgeStream(deployer, address(mockKendu), SEPOLIA_POT_KENDU_SEED);
    }

    /// @dev The deployer acts as a DONOR of `token` to the discount minter's stream: approve the
    ///      streamer exactly, `collectNudge`, reset the approval. Never a direct transfer to the minter.
    ///      The streamer + minter balance sum must rise by exactly `amount` (`collectNudge` may settle
    ///      already-accrued stream to the minter first, so the sum, not the streamer alone, is the
    ///      invariant), which also proves the token is not fee-on-transfer.
    function _donateToNudgeStream(address deployer, address token, uint256 amount) internal {
        address m = address(nudgeDiscountMinter);
        uint256 before = IERC20(token).balanceOf(address(nudgeStreamer)) + IERC20(token).balanceOf(m);
        uint256 donorBefore = IERC20(token).balanceOf(deployer);
        IERC20(token).approve(address(nudgeStreamer), amount);
        nudgeStreamer.collectNudge(m, token, amount);
        IERC20(token).approve(address(nudgeStreamer), 0);
        require(
            IERC20(token).balanceOf(address(nudgeStreamer)) + IERC20(token).balanceOf(m) == before + amount,
            "story-137: pot seed did not land exactly in the streamer/minter"
        );
        require(donorBefore - IERC20(token).balanceOf(deployer) == amount, "story-137: pot seed debit mismatch");
        console.log("  pot seeded via collectNudge (token, amount):", token, amount);
    }

    /// @dev Phase 11.19. DeployMocks `_shutdownRatchetMinting` (story 135) with a stake in the middle:
    ///      mint `SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS` id-7 NFTs to the deployer (exact per-mint USDC
    ///      approval, reset to 0), stake them all in RatchetNFTStaker (approval granted only around the
    ///      stake), then `setDispatcherDisabled(7, true)` and read it back.
    function _mintStakeAndShutdownRatchet(address deployer) internal {
        console.log("\n=== Phase 11.19: ratchet mints STAKED, then ratchet minting shut down (story 137) ===");
        (address d7,,, bool disabledBefore) = nftMinterV2.configs(RATCHET_INDEX);
        require(d7 == address(nudgeRatchet), "story-137: NFTMinterV2 index 7 is not the NudgeRatchet");
        require(!disabledBefore, "story-137: index 7 already disabled before the pre-shutdown mints");
        require(nudgeRatchet.batchMinter() == address(nudgeDiscountMinter), "story-137: ratchet USDC sink");

        uint256 balBefore = nftMinterV2.balanceOf(deployer, RATCHET_INDEX);
        (uint256 stakedBefore,) = ratchetNFTStaker.users(deployer);
        for (uint256 i = 0; i < SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS; ++i) {
            (, uint256 price,,) = nftMinterV2.configs(RATCHET_INDEX);
            rewardToken.approve(address(nftMinterV2), price);
            nftMinterV2.mint(RATCHET_INDEX, deployer);
            rewardToken.approve(address(nftMinterV2), 0);
        }
        require(
            nftMinterV2.balanceOf(deployer, RATCHET_INDEX) == balBefore + SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS,
            "story-137: deployer did not receive the pre-shutdown id-7 NFTs"
        );

        nftMinterV2.setApprovalForAll(address(ratchetNFTStaker), true);
        ratchetNFTStaker.stake(SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS);
        nftMinterV2.setApprovalForAll(address(ratchetNFTStaker), false);
        require(
            !nftMinterV2.isApprovedForAll(deployer, address(ratchetNFTStaker)), "story-137: staker approval not revoked"
        );
        require(nftMinterV2.balanceOf(deployer, RATCHET_INDEX) == balBefore, "story-137: ratchets not all staked");
        (uint256 stakedAfter,) = ratchetNFTStaker.users(deployer);
        require(
            stakedAfter == stakedBefore + SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS,
            "story-137: deployer staked count mismatch"
        );
        console.log("  minted + staked id-7 NFTs (deployer):", SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS);

        nftMinterV2.setDispatcherDisabled(RATCHET_INDEX, true);
        (,,, bool disabled) = nftMinterV2.configs(RATCHET_INDEX);
        require(disabled, "story-137: NFTMinterV2 configs(7).disabled did not read back true");
        console.log("  NFTMinterV2.setDispatcherDisabled(7, true) - ratchet minting OFF");
    }

    /// @dev Terminal story-137 end state, called from the sweep:
    ///        - the nudge-discount minter holds NFTMinterV2 mintFor authority and the deployer does not;
    ///        - no old batch minter was tracked (so `progress.11155111.json` names none);
    ///        - every parameter still reads its mainnet value, `boostDonationSafe()`, PauserV2-registered;
    ///        - every donor targets the new minter;
    ///        - index 7 is disabled and RatchetNFTStaker holds the deployer's pre-shutdown ratchets.
    function _requireStory137EndState(address deployer) internal view {
        BatchNFTMinterNudgeDiscount m = nudgeDiscountMinter;
        require(
            nftMinterV2.authorizedMinters(address(m)),
            "RESIDUAL PRIVILEGE SWEEP FAILED: NudgeDiscountBatchMinter lacks NFTMinterV2 mintFor authority"
        );
        require(
            !nftMinterV2.authorizedMinters(deployer),
            "RESIDUAL PRIVILEGE SWEEP FAILED: deployer must not hold NFTMinterV2 mintFor authority"
        );
        require(
            !deployments["BatchNFTMinter"].deployed && !deployments["RatchetBatchNFTMinter"].deployed,
            "story-137: an old batch minter was deployed on Sepolia"
        );
        require(deployments["NudgeDiscountBatchMinter"].addr == address(m), "story-137: minter not tracked");

        require(
            m.discountPercent() == NUDGE_DISCOUNT_PERCENT && m.burnPercent() == NUDGE_DISCOUNT_BURN_PERCENT
                && m.maxFreePerBatch() == NUDGE_DISCOUNT_MAX_FREE_PER_BATCH
                && m.overflowNFTsPerBoostPoint() == NUDGE_DISCOUNT_OVERFLOW_NFTS_PER_BOOST_POINT,
            "story-137: nudge-discount parameters drifted"
        );
        require(m.maxBoost() == NUDGE_DISCOUNT_DAY1_MAX_BOOST, "story-137: maxBoost must be 0 at the end of the run");
        require(m.boostDonationSafe(), "story-137: boostDonationSafe() false at the end of the run");
        require(pauser.isRegistered(address(m)) && m.pauser() == address(pauser), "story-137: minter not on PauserV2");
        require(m.nudgeStreamer() == address(nudgeStreamer), "story-137: minter streamer");

        require(uniPoolerV2.batchMinter() == address(m), "story-137: UniPoolerV2 does not donate to the new minter");
        require(uniboostEYE.recipient() == address(m), "story-137: UniboostEYE does not donate to the new minter");
        require(uniboostSCX.recipient() == address(m), "story-137: UniboostSCX does not donate to the new minter");
        require(uniboostFLX.recipient() == address(m), "story-137: UniboostFLX does not donate to the new minter");
        require(nudgeRatchet.batchMinter() == address(m), "story-137: NudgeRatchet does not donate to the new minter");
        require(stableYieldAccumulator.nudge() == address(m), "story-137: SYA nudge is not the new minter");

        (,,, bool ratchetDisabled) = nftMinterV2.configs(RATCHET_INDEX);
        require(
            ratchetDisabled, "RESIDUAL PRIVILEGE SWEEP FAILED: ratchet minting (NFTMinterV2 index 7) must be disabled"
        );
        (uint256 staked,) = ratchetNFTStaker.users(deployer);
        require(
            staked == SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS, "story-137: RatchetNFTStaker does not hold the 5 ratchets"
        );
        require(
            nftMinterV2.balanceOf(address(ratchetNFTStaker), RATCHET_INDEX) >= SEPOLIA_RATCHET_PRE_SHUTDOWN_MINTS,
            "story-137: RatchetNFTStaker id-7 balance short"
        );
        console.log("  story-137 end state asserted: discount minter (mintFor IN, deployer OUT), no old minters,");
        console.log("  mainnet params + boostDonationSafe, all donors -> new minter, index 7 off, 5 ratchets staked");
    }

    // =====================================================================
    // PhlimboV3 deployment (Phase 3)
    // =====================================================================

    /// @dev Deploys and fully wires the local chain's only phlimbo.
    ///
    ///      There is no incumbent to migrate off. Both prior generations were retired here once
    ///      their mainnet cutovers had executed: V1 -> V2 (story 049) and V2 -> V3 (story 076,
    ///      via `MigratorV2V3`). Deploying a superseded generation locally just to drain it again
    ///      rehearses a migration that can no longer happen, and leaves an empty husk on the chain
    ///      the UI is tested against.
    ///
    ///      A helper rather than inline code because `run()` is at its stack-depth ceiling.
    ///
    ///      The constructor arguments are the ones V2 carried and V3 inherited at the mainnet
    ///      cutover: the USDC reward token and a 1-week linear depletion window. They are literals
    ///      here because there is no longer a live predecessor to read them off.
    /// @return v3 The deployed, wired (empty, dormant) `PhlimboV3`.
    function _deployPhlimboV3(address) internal returns (PhlimboV3 v3) {
        console.log("\n=== Deploy PhlimboV3 ===");

        // ---- 1. Deploy. Linear depletion model, window = 1 week. ----
        uint256 oneWeekInSeconds = 604800;
        uint256 gasBefore = gasleft();
        v3 = new PhlimboV3(address(phUSD), address(rewardToken), oneWeekInSeconds);
        _trackDeployment("PhlimboV3", address(v3), gasBefore - gasleft());
        console.log("  PhlimboV3 deployed at:", address(v3));
        console.log("  - Depletion window:", oneWeekInSeconds, "seconds (1 week)");
        // A fresh V3 arrives with no promotion armed. `promoToken == address(0)` is the designed
        // dormant state, NOT a misconfiguration — this chain, like mainnet, ships with no
        // promotion running (story 098 drops DeployMocks' local-only Kendu arming).
        require(v3.promoToken() == IERC20(address(0)), "PhlimboV3 arrived with a promo token set");

        // ---- 2. Desired APY = 0: no phUSD minted by phlimbo, yield comes only from the funnel. ----
        _setDesiredAPYTwoStep(IPhlimboAPYLike(address(v3)), 0, "PhlimboV3");

        // ---- 3. Pauser wiring, both directions (setPauser BEFORE register, as everywhere). ----
        v3.setPauser(address(pauser));
        pauser.register(address(v3));
        console.log("  PhlimboV3 pauser set + registered with the local Pauser");

        // ---- 4. phUSD mint authority. THE SILENT-FAILURE STEP. ----
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

        // ---- 5. Story 098: NO seed stakers and NO promotion. ----
        // DeployMocks stakes for anvil default accounts #4/#5/#6 (public private keys — anyone could
        // unstake them on a public network) and arms a 1-day Kendu promotion. Both are dropped: the
        // farm ships empty and DORMANT, the day-one mainnet shape. Assert the negative so neither is
        // a silent assumption.
        require(v3.promoToken() == IERC20(address(0)), "sepolia: promoToken is not the zero address");
        require(v3.promoRewardBalance() == 0, "sepolia: promoRewardBalance is not zero");
        require(v3.migrator() == address(0), "sepolia: PhlimboV3 has a migrator set");
        console.log("  PhlimboV3 ships empty and DORMANT (promoToken == address(0))");
    }

    /// @dev `setDesiredAPY` is a two-step preview -> commit (PhlimboV3.sol:261-280): the first
    ///      call only records `pendingAPYBps`; the value commits on a SECOND call with the
    ///      IDENTICAL bps within 100 blocks. A script that calls it once has silently done nothing.
    ///
    ///      Both a value read-back AND an `apySetInProgress` read-back, because the value alone is
    ///      not enough: setting an APY to the value it already holds (the local case — V3 is
    ///      constructed at 0 and set to 0) leaves `desiredAPYBps` correct after the PREVIEW call
    ///      alone, so a value-only assertion would pass on a half-done set. Only the commit branch
    ///      clears the latch.
    ///
    ///      Takes `IPhlimboAPYLike` rather than the concrete type: the shim outlived the V2/V3
    ///      cutover that needed one call site to drive both generations, and is kept because the
    ///      two read-backs belong with the setter rather than at the call site.
    function _setDesiredAPYTwoStep(IPhlimboAPYLike p, uint256 bps, string memory label) internal {
        p.setDesiredAPY(bps); // preview
        // Story 098: no `vm.roll`. A second IDENTICAL call within 100 blocks takes the commit branch
        // (PhlimboV3.setDesiredAPY), including when mined in the very next block under --slow.
        p.setDesiredAPY(bps); // commit
        require(p.desiredAPYBps() == bps, "APY commit did not land");
        require(!p.apySetInProgress(), "APY still in preview - the commit call was treated as a new preview");
        console.log(string.concat("  ", label, " desired APY committed (bps):"), bps);
    }

    /// @dev Deploys the uniboost staker (`NFTStakerDepletionV2`), wires it to the dispatcher hook,
    ///      sets the hook recipient to the staker, configures the depletion window, and registers
    ///      with the local Pauser.
    ///
    ///      V2 DIRECTLY, no V1 first. Story 073 used to deploy `NFTStakerDepletion` (V1) here, seed
    ///      it with three positions and drain it through an `NFTStakerMigrator`, so that mainnet's
    ///      riskiest phase could be dry-run before it shipped. That migration has since executed on
    ///      mainnet, so the rehearsal was deploying a superseded staker purely to migrate off it
    ///      again. Constructor arity and admin surface are identical between the two generations,
    ///      so nothing else about this helper changed.
    ///
    ///      There is NO setTargetAPY (depletion-budget model); the window is owner-set and the
    ///      per-second rate is budget/windowSeconds. stakedId == dispatcherIndex (NFTMinterV2 mints
    ///      tokenId == index); resolve the index dynamically.
    function _deployUniboostStaker(Uniboost dispatcher, UniboostMintDebtHook hook, address deployer)
        internal
        returns (NFTStakerDepletionV2 staker)
    {
        uint256 idx = nftMinterV2.dispatcherToIndex(address(dispatcher));
        require(idx != 0, "Uniboost dispatcher not registered");
        staker = new NFTStakerDepletionV2(
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
        json = string.concat(json, '"chainId": 11155111,');
        json = string.concat(json, '"networkName": "sepolia",');
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

        // Write to server/deployments/progress.11155111.json
        vm.writeFile("server/deployments/progress.11155111.json", json);
        console.log("Progress file written to: server/deployments/progress.11155111.json");
    }
}
