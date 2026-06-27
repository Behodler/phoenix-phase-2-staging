// Generated from mainnet.json on 2026-01-29
// Updated 2026-03-20 for NFT infrastructure redeployment (WBTC address fix)
// Chain ID: 1 (mainnet)
// Updated 2026-03-20: NFT addresses patched from progress.1.json after broadcast
// Updated 2026-04-20: NFT V2 addresses patched from broadcast
// Updated 2026-06-09: Flattened NFT V2 addresses to top-level; removed V1 and NFTMigrator (story 059)
// Updated 2026-05-02: BalancerPool repointed to phUSD/sUSDS 50/50 pool
// Updated 2026-05-01: NFT staking addresses patched from broadcast
// Updated 2026-05-13: nudge-pooler addresses patched from broadcast
// Updated 2026-05-22: dispatcher-replace cutover patched (story 048 - index 4 restored)
// Updated 2026-05-22: PhlimboV2 + MigratorV1V2 deployed (story 049 - V1 stakers migrated)
// Updated 2026-05-22: DepositView redeployed against PhlimboV2 (story 049 follow-up - rewire-sya-to-phlimbo-v2)
// Updated 2026-06-04: index-4 dispatcher cut over to Sky-PSM BalancerPoolerV2 + new MintDebtHook (story 056)
// Updated 2026-06-16: saga 2 migration (2.1) — YieldStrategyDola/USDC + PhusdStableMinter (V2) patched
// Updated 2026-06-20: NudgeRatchet infrastructure deployed to mainnet (story 069); ratchet addresses + MintPageView patched from broadcast
import { ContractAddresses } from './addresses';


/*
  Old YieldStrategyDola: 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4
  New YieldStrategyDola: 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78
  New YieldStrategyUSD: 0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952
  Old YieldStrategyUSD: 0xf5F91E8240a0320CAC40b799B25F944a61090E5B

  note as of 30/03/2026, old is still mapped.
*/
export const mainnetAddresses: ContractAddresses = {
  //Phase 1 protocol contracts
  PhUSD: "0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605",

  // Deployed Phase 2 contracts
  Pauser: "0x7c5A8EeF1d836450C019FB036453ac6eC97885a3",
  PhusdStableMinter: "0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C",
  // V2 of PhlimboEA -- deployed by story 049 MigratePhlimboV1ToV2.s.sol
  PhlimboEA: "0x6084a02c2ac0127ddf1e617de257c61480a2aee0",
  StableYieldAccumulator: "0x3C690EC3B2524104dE269bf0F9baa7f045eF8270",
  DepositView: "0x0725722b50287f2285b873f534d5848e76c15251",
  // Story 055 migration (executed 2026-06-10: MigrateStableStakerMainnet run txs 1-20 +
  // ResumeStableStakerMigration run, all receipts 0x1). DOLA/USDC are plain
  // ERC4626YieldStrategy; USDe is ERC4626MarketYieldStrategy @ 30 bps (sUSDe cooldown
  // blocks plain redeem). Old strategies (0xE7aE…, 0x8b4A…, 0xFc62…) drained + retired.
  YieldStrategyDola: "0x1760E05356Ec1FBBA159C730781dCfB9920524e2",
  YieldStrategyUSDe: "0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95",
  YieldStrategyUSDC: "0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83",
  // USDe<->sUSDe CurveAMMAdapter (Router NG, via crvUSD) backing YieldStrategyUSDe.
  USDeAMMAdapter: "0x2D024e0d03Fb6Ead4F8E7Ba1EBECF6db0E755D6f",

  // External protocol contracts
  // Sky USDS PSM wrapper (USDS<->USDC). Real mainnet address — NOT the local mock (0xc351…1181).
  SkyPSM: "0xA188EEC8F81263234dA3622A406892F3D630f98c",
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  Dola: "0x865377367054516e17014CcdED1e7d814EDC9ce4",
  AutoDOLA: "0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d",
  AutoUSDC: "0xa7569A44f348d3D70d8ad5889e50F78E33d80D35",

  // External tokens
  USDS: "0xdC035D45d973E3EC169d2276DDab16f1e407384F",
  SCX: "0x1B8568FbB47708E9E9D31Ff303254f748805bF21",
  Flax: "0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8",
  WBTC: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",
  EYE: "0x155ff1A85F440EE0A382eA949f24CE4E0b751c65",
  USDe: "0x4c9EDD5852cd905f086C759E8383e09bff1E68B3",
  SUSDe: "0x9D39A5DE30e57443BfF2A8307A4256c8797A3497",
  SUSDS: "0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD",

  // Balancer V3 infrastructure
  BalancerPool: "0x642BB6860b4776CC10b26B8f361Fd139E7f0db04",
  BalancerVault: "0xbA1333333333a1BA1108E8412f11850A5C319bA9",
  BalancerRouter: "0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd",

  // NFT infrastructure — common
  BurnRecorder: "0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F",

  // NFT V2 contracts (flattened)
  NFTMinter: "0x39af088408e815844c567037c157b31d48d2e10f",
  // Story 070 (2026-06-27): the three BurnerEYE/SCX/Flax dispatchers (indices 1/2/3) were
  // replaced by Uniboost dispatchers in the local mock deploy, so the BurnerEYE/SCX/Flax keys
  // were dropped from the ContractAddresses interface. Their place is taken by the Uniboost
  // stack (dispatchers + hooks + stakers) and the backing Uniswap V2 infra/pools below. These
  // are NOT yet deployed on mainnet — zero-address placeholders keep this hand-maintained file's
  // key-set equal to the regenerated interface (tsc drift guard). Patch by hand when they ship.
  UniboostEYE: "0x0000000000000000000000000000000000000000",
  UniboostSCX: "0x0000000000000000000000000000000000000000",
  UniboostFLX: "0x0000000000000000000000000000000000000000",
  UniboostHookEYE: "0x0000000000000000000000000000000000000000",
  UniboostHookSCX: "0x0000000000000000000000000000000000000000",
  UniboostHookFLX: "0x0000000000000000000000000000000000000000",
  UniboostStakerEYE: "0x0000000000000000000000000000000000000000",
  UniboostStakerSCX: "0x0000000000000000000000000000000000000000",
  UniboostStakerFLX: "0x0000000000000000000000000000000000000000",
  // Canonical Uniswap V2 stack + Uniboost target/routing pools (anvil-only; mainnet would reuse
  // the live UniV2 deployment). Placeholders for interface parity.
  WETH9: "0x0000000000000000000000000000000000000000",
  UniswapV2Factory: "0x0000000000000000000000000000000000000000",
  UniswapV2Router02: "0x0000000000000000000000000000000000000000",
  UniPoolEYE: "0x0000000000000000000000000000000000000000",
  UniPoolSCX: "0x0000000000000000000000000000000000000000",
  UniPoolFLX: "0x0000000000000000000000000000000000000000",
  UniRoutePoolWETH: "0x0000000000000000000000000000000000000000",
  UniRoutePoolUSDS: "0x0000000000000000000000000000000000000000",
  UniRoutePoolDOLA: "0x0000000000000000000000000000000000000000",
  // Story 056 (2026-06-04): index-4 dispatcher cut over to the Sky-PSM BalancerPoolerV2.
  // Verified on-chain 2026-06-11: NFTMinter.configs(4).dispatcher == this address; it holds
  // the pending sUSDS leg (418.63 sUSDS). The prior pooler 0x26f8…b38a is retired (0 balance).
  BalancerPooler: "0x7f74388bc970de5e2822036a1ad06fccd156786b",
  GatherWBTC: "0xfd3775f2ccfb94b532b34b2b683e210ba4449880",

  // View contracts
  ViewRouter: "0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a",
  DepositPageView: "0x50D4443782bB9A6e8D65dAcd593684EDd3FF03b8",
  // Story 048: reverted from 0xeBEc50cD19310e6ed59D8153313Ec7C888152c1A (index-6 view)
  // to the prior index-4 view ahead of the dispatcher cutover. Verified on-chain:
  // getData(0)[23] == 4 for the address below.
  MintPageView: "0x7e329338d319882ba1809b648eba584b3a4630cb",
  // NFT staking
  BalancerPoolerMintDebtHook: "0x4a26ad83306a2f17155799fdd9449f77eb3f8bd7",
  NFTStaker: "0xc8514f821a3d801fa8a8c435840a992a4365a13b",
  WaUSDC: "0xd4fa2d31b7968e448877f69a96de69f5de8cd23e",
  BatchNFTMinter: "0x86866e01a115C17892Ed04c548F2e8638851029d",
  // Stable Staking — deployed 2026-06-10 by ResumeStableStakerMigration (story 055).
  // Pools: DOLA 5 / USDC 7 / USDe 10 phUSD per day, 10% set-aside buffer.
  StableStaker: "0xbce8ABC09BaEDCabE93419bF875f6186e182079A",
  // NudgeRatchet dispatcher + its mint-debt hook — not yet deployed on mainnet (story 068).
  // Zero placeholders so this file still satisfies the ContractAddresses interface once the
  // local deploy added these fields. Patch by hand when they ship to mainnet.
  NudgeRatchet: "0x7a4ed11160a06bb1c5b59091575d59707be97a72",
  NudgeRatchetMintDebtHook: "0xdcddb2f6548d5f1bac812110679e4c87e4ba9958",
  // Dedicated NFTStaker for the NudgeRatchet NFT — not yet deployed on mainnet (story 068).
  RatchetNFTStaker: "0x299b0071def42d35eaf5ea24cc0a71cf10655a64",
  // Dedicated BatchNFTMinter for the NudgeRatchet NFT (UI batch-mint entrypoint; pays USDC,
  // rewards USDS) — not yet deployed on mainnet (story 068). Patch by hand when it ships.
  RatchetBatchNFTMinter: "0x81896f48a95abea255cd38a3010e985b6051a1c7",
};

export type MainnetContractName = keyof ContractAddresses;
