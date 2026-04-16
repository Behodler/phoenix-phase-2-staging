// Generated interface — union of all deployment targets (anvil, sepolia, mainnet)
// Chain ID: 31337 (anvil)
// This interface can be copied directly into UI projects
// NOTE: Some fields may have zero-address placeholders on certain networks

export interface YieldNFTAddresses {
  NFTMinter: string;
  BurnerEYE: string;
  BurnerSCX: string;
  BurnerFlax: string;
  BalancerPooler: string;
  GatherWBTC: string;
}

export interface ContractAddresses {
  PhUSD: string;
  USDC: string;
  USDS: string;
  SUSDS: string;
  USDe: string;
  SUSDe: string;
  YieldStrategyUSDe: string;
  Dola: string;
  Toke: string;
  EYE: string;
  SCX: string;
  Flax: string;
  WBTC: string;
  Pauser: string;
  AutoDOLA: string;
  MainRewarder: string;
  YieldStrategyDola: string;
  AutoUSDC: string;
  MainRewarderUSDC: string;
  YieldStrategyUSDC: string;
  PhusdStableMinter: string;
  PhlimboEA: string;
  StableYieldAccumulator: string;
  BalancerPool: string;
  BalancerVault: string;
  BurnRecorder: string;
  BalancerRouter: string;
  NFTMigrator: string;
  nftsV1: YieldNFTAddresses;
  nftsV2: YieldNFTAddresses;
  DepositView: string;
  ViewRouter: string;
  DepositPageView: string;
  MintPageView: string;
}
