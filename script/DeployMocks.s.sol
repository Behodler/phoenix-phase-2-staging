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
import {PhusdStableMinter} from "@phUSD-stable-minter/PhusdStableMinter.sol";
import "@pauser/Pauser.sol";
import {ERC4626YieldStrategy} from "@vault/concreteYieldStrategies/ERC4626YieldStrategy.sol";
import {ERC4626MarketYieldStrategy} from "@vault/concreteYieldStrategies/ERC4626MarketYieldStrategy.sol";
import {AYieldStrategy} from "@vault/AYieldStrategy.sol";
import "@stable-yield-accumulator/StableYieldAccumulator.sol";
import "../src/views/DepositView.sol";
import "../src/views/ViewRouter.sol";
import "../src/views/DepositPageView.sol";
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
    PhlimboEA public phlimbo;
    MockEYE public eyeToken;
    Pauser public pauser;
    StableYieldAccumulator public stableYieldAccumulator;
    DepositView public depositView;
    ViewRouter public viewRouter;
    DepositPageView public depositPageView;
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

        // 2. Deploy PhlimboEA
        // Using Linear Depletion model: depletion window = 1 week (604800 seconds)
        uint256 oneWeekInSeconds = 604800;
        gasBefore = gasleft();
        phlimbo = new PhlimboEA(
            address(phUSD), // _phUSD
            address(rewardToken), // _rewardToken (USDC)
            oneWeekInSeconds // _depletionDuration (1 week for linear depletion)
        );
        _trackDeployment("PhlimboEA", address(phlimbo), gasBefore - gasleft());
        console.log("PhlimboEA deployed at:", address(phlimbo));
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

        // Authorize PhlimboEA as phUSD minter
        phUSD.setMinter(address(phlimbo), true);
        console.log("Authorized PhlimboEA as phUSD minter");

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

        // Set Phlimbo as the reward recipient
        stableYieldAccumulator.setPhlimbo(address(phlimbo));
        console.log("Set Phlimbo as reward recipient:", address(phlimbo));

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

        // Register PhlimboEA with Pauser
        // Step 1: Set pauser address on contract FIRST
        phlimbo.setPauser(address(pauser));
        console.log("PhlimboEA.setPauser() called");
        // Step 2: Register with pauser
        pauser.register(address(phlimbo));
        console.log("Pauser.register(PhlimboEA) completed");

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

        // Register DepositPageView with ViewRouter
        viewRouter.setPage(keccak256("deposit"), IPageView(address(depositPageView)));
        console.log("Registered DepositPageView with ViewRouter under key: keccak256('deposit')");

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
        console.log("  - PhlimboEA registered with Pauser");
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
