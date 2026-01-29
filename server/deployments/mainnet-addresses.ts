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
  // Phoenix Token
  PhUSD: "0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605",

  // Stablecoins
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  USDT: "", // Not yet deployed
  Dola: "0x865377367054516e17014CcdED1e7d814EDC9ce4",
  USDS: "", // Not yet deployed

  // Protocol tokens
  Toke: "0x2e9d63788249371f1DFC918a52f8d799F4a38C94",
  EYE: "0x155ff1A85F440EE0a382eA949f24CE4E0b751c65",

  // Deployed Phase 2 contracts
  Pauser: "0x7c5A8EeF1d836450C019FB036453ac6eC97885a3",
  PhusdStableMinter: "0x435B0A1884bd0fb5667677C9eb0e59425b1477E5",
  StableYieldAccumulator: "0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f",
  PhlimboEA: "0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4",
  DepositView: "0x2Fdf77d4Ea75eFd48922B8E521612197FFbB564c",

  // YieldStrategies
  YieldStrategyDola: "0x01d34d7EF3988C5b981ee06bF0Ba4485Bd8eA20C",
  YieldStrategyUSDC: "", // To be deployed by DeployAutoUSDCMainnet.s.sol
  YieldStrategyUSDT: "", // Not yet deployed
  YieldStrategyUSDS: "", // Not yet deployed

  // External Tokemak Vaults
  AutoDOLA: "0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d",
  AutoUSDC: "0xa7569A44f348d3D70d8ad5889e50F78E33d80D35", // autoUSD vault

  // Tokemak MainRewarders
  MainRewarder: "0xDC39C67b38ecdA8a1974336c89B00F68667c91B7", // For autoDOLA
  MainRewarderUSDC: "0x726104CfBd7ece2d1f5b3654a19109A9e2b6c27B", // For autoUSD
};

export type MainnetContractName = keyof ContractAddresses;
