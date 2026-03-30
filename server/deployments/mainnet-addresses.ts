// Generated from mainnet.json on 2026-01-29
// Updated 2026-03-20 for NFT infrastructure redeployment (WBTC address fix)
// Chain ID: 1 (mainnet)
// Updated 2026-03-20: NFT addresses patched from progress.1.json after broadcast
import { ContractAddresses } from './addresses';


/*
  Old YieldStrategyDola: 0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4
  New YieldStrategyDola: 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78
*/
export const mainnetAddresses: ContractAddresses = {
  // Deployed Phase 2 contracts
  Pauser: "0x7c5A8EeF1d836450C019FB036453ac6eC97885a3",
  YieldStrategyDola: "0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4",// new ERC4626YieldStrategy 0xE7aEC21BF6420FF483107adCB9360C4b31d69D78
  PhusdStableMinter: "0x435B0A1884bd0fb5667677C9eb0e59425b1477E5",
  PhlimboEA: "0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4",
  StableYieldAccumulator: "0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E",
  DepositView: "0x2Fdf77d4Ea75eFd48922B8E521612197FFbB564c",
  // External protocol contracts
  PhUSD: "0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605",
  USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  Dola: "0x865377367054516e17014CcdED1e7d814EDC9ce4",
  AutoDOLA: "0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d",
  EYE: "0x155ff1A85F440EE0A382eA949f24CE4E0b751c65",

  YieldStrategyUSDC: "0xf5F91E8240a0320CAC40b799B25F944a61090E5B",
  AutoUSDC: "0xa7569A44f348d3D70d8ad5889e50F78E33d80D35",
  MainRewarder: "0x0000000000000000000000000000000000000000",
  MainRewarderUSDC: "0x726104cfbd7ece2d1f5b3654a19109a9e2b6c27b",

  // External tokens
  USDS: "0x0000000000000000000000000000000000000000",
  Toke: "0x0000000000000000000000000000000000000000",
  SCX: "0x1B8568FbB47708E9E9D31Ff303254f748805bF21",
  Flax: "0x0cf758D4303295C43CD95e1232f0101ADb3DA9E8",
  WBTC: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",

  // Balancer V3 infrastructure
  BalancerPool: "0x5b26d938f0be6357c39e936cc9c2277b9334ea58",
  BalancerVault: "0xbA1333333333a1BA1108E8412f11850A5C319bA9",

  // NFT infrastructure (PLACEHOLDER: replace after broadcast)
  NFTMinter: "0xd936461f1C15eA9f34Ca1F20ecD54A0819068811",
  BurnRecorder: "0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F",
  BurnerEYE: "0xA592e074f990c87E10b3Bba1DACFB9187899575b",
  BurnerSCX: "0xbe2fbBb49b26C20E3aEE3b0608cB5116aeD5d297",
  BurnerFlax: "0xD3B630cBA76AEA5Aadb4cB71732227E073C8338C",
  BalancerPooler: "0xC2d1a82C66Fd535ae218b59F77a1B716919a46C3",
  GatherWBTC: "0xb304e2E63820D4f7B41219D2C39123E20444D0C9",

  // View contracts (PLACEHOLDER: replace after broadcast)
  ViewRouter: "0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a",
  DepositPageView: "0x50D4443782bB9A6e8D65dAcd593684EDd3FF03b8",
  MintPageView: "0x5122cb32aE42AcC2aD5C2071e977C95c08F70141",

  SUSDS: "0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD",

  // ERC4626 YieldStrategy for DOLA (wraps autoDOLA vault directly, no MainRewarder)
  // PLACEHOLDER: replace after running `mainnet:partial-migrate-execute`.
  // The deployed address is logged to console as: "New ERC4626 YS deployed at: <address>"
  // Also available in the broadcast JSON at: broadcast/PartialMigrationExecute.s.sol/1/run-latest.json
  YieldStrategyDolaERC4626: "0x0000000000000000000000000000000000000000"
};

export type MainnetContractName = keyof ContractAddresses;
