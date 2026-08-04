// Generated interface from local.json on 2026-07-31T22:21:43.345Z
// Chain ID: 31337 (anvil)
// This interface can be copied directly into UI projects

export interface ContractAddresses {
  PhUSD: string;
  USDC: string;
  USDS: string;
  SUSDS: string;
  USDe: string;
  SUSDe: string;
  Dola: string;
  EYE: string;
  SCX: string;
  Kendu: string;
  Flax: string;
  WBTC: string;
  Pauser: string;
  AutoDOLA: string;
  YieldStrategyDola: string;
  AutoUSDC: string;
  YieldStrategyUSDC: string;
  USDeAMMAdapter: string;
  YieldStrategyUSDe: string;
  PhusdStableMinter: string;
  PhlimboEA: string;
  /**
   * Story 076. PhlimboV3, deployed by the promotion-ready cutover's Phase 4e. ADDED
   * ALONGSIDE `PhlimboEA`, never in place of it: `PhlimboEA` is the V2 address and V2
   * continues to exist post-cutover (wound down to APY 0 and mint-revoked, but not paused,
   * so any late staker can still exit).
   *
   * `MigratorV2V3` deliberately has NO key here — it is a transient orchestrator, following
   * the same precedent as the three `NFTStakerMigrator` instances.
   */
  PhlimboV3: string;
  StableYieldAccumulator: string;
  BalancerPool: string;
  BalancerVault: string;
  BurnRecorder: string;
  BalancerRouter: string;
  NFTMinter: string;
  UniboostEYE: string;
  UniboostSCX: string;
  UniboostFLX: string;
  BalancerPooler: string;
  GatherWBTC: string;
  MultiPooler: string;
  UniboostHookEYE: string;
  UniboostHookSCX: string;
  UniboostHookFLX: string;
  WaUSDC: string;
  SkyPSM: string;
  BalancerPoolerMintDebtHook: string;
  NFTStaker: string;
  NudgeStreamer: string;
  BatchNFTMinter: string;
  UniboostStakerEYE: string;
  UniboostStakerSCX: string;
  UniboostStakerFLX: string;
  EyeBatchNFTMinter: string;
  ScxBatchNFTMinter: string;
  FlxBatchNFTMinter: string;
  NudgeRatchet: string;
  NudgeRatchetMintDebtHook: string;
  RatchetNFTStaker: string;
  RatchetBatchNFTMinter: string;
  StableStaker: string;
  ViewRouter: string;
}
