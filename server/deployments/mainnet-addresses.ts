// Generated from mainnet.json on 2026-01-29
// Chain ID: 1 (mainnet)

export interface ContractAddresses {
  PhUSD: string,
  USDC: string,
  USDT: string,
  Dola: string,
  USDS: string,
  Toke: string,
  EYE: string,
  Pauser: string,
  YieldStrategyUSDT: string,
  YieldStrategyDola: string,
  YieldStrategyUSDS: string,
  YieldStrategyUSDC: string,
  PhusdStableMinter: string,
  StableYieldAccumulator: string,
  PhlimboEA: string,
  AutoDOLA: string,
  AutoUSDC: string,
  MainRewarder: string,
  MainRewarderUSDC: string,
  DepositView: string,
}

export const mainnetAddresses: ContractAddresses = {
  // Deployed Phase 2 contracts
  Pauser: "0x7c5A8EeF1d836450C019FB036453ac6eC97885a3",
  YieldStrategyDola: "0x01d34d7EF3988C5b981ee06bF0Ba4485Bd8eA20C",
  PhusdStableMinter: "0x435B0A1884bd0fb5667677C9eb0e59425b1477E5",
  PhlimboEA: "0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4",
  StableYieldAccumulator: "0xFc88cE7Ca2f4D2A78b2f96F6d1c34691960A9027",
  DepositView: "0x2Fdf77d4Ea75eFd48922B8E521612197FFbB564c",
  // External protocol contracts
  PhUSD: "0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605",
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  Dola: "0x865377367054516e17014CcdED1e7d814EDC9ce4",
  AutoDOLA: "0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d",
  EYE: "0x155ff1A85F440EE0A382eA949f24CE4E0b751c65",

  // Not yet used on mainnet
  USDT: "0x0000000000000000000000000000000000000000",
  USDS: "0x0000000000000000000000000000000000000000",
  Toke: "0x0000000000000000000000000000000000000000",
  YieldStrategyUSDT: "0x0000000000000000000000000000000000000000",
  YieldStrategyUSDS: "0x0000000000000000000000000000000000000000",
  YieldStrategyUSDC: "0xf5F91E8240a0320CAC40b799B25F944a61090E5B",
  AutoUSDC: "0xa7569A44f348d3D70d8ad5889e50F78E33d80D35",
  MainRewarder: "0x0000000000000000000000000000000000000000",
  MainRewarderUSDC: "0x726104cfbd7ece2d1f5b3654a19109a9e2b6c27b",
};

export type MainnetContractName = keyof ContractAddresses;
