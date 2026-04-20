// Generated from mainnet.json on 2026-01-29
// Updated 2026-03-20 for NFT infrastructure redeployment (WBTC address fix)
// Chain ID: 1 (mainnet)
// Updated 2026-03-20: NFT addresses patched from progress.1.json after broadcast
// Updated 2026-04-16: Restructured for NFT V2 (nftsV1/nftsV2 sub-objects)
// Updated 2026-04-20: NFT V2 addresses patched from broadcast
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
  PhusdStableMinter: "0x435B0A1884bd0fb5667677C9eb0e59425b1477E5",
  PhlimboEA: "0x3984eBC84d45a889dDAc595d13dc0aC2E54819F4",
  StableYieldAccumulator: "0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E",
  DepositView: "0x2Fdf77d4Ea75eFd48922B8E521612197FFbB564c",
  YieldStrategyDola: "0xE7aEC21BF6420FF483107adCB9360C4b31d69D78",
  YieldStrategyUSDe: "0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3",
  YieldStrategyUSDC: "0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952",

  // External protocol contracts
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
  BalancerPool: "0x5b26d938f0be6357c39e936cc9c2277b9334ea58",
  BalancerVault: "0xbA1333333333a1BA1108E8412f11850A5C319bA9",
  BalancerRouter: "0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd",

  // NFT infrastructure — common
  BurnRecorder: "0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F",
  NFTMigrator: "0x22c0fc1aae66873abd029448eaf15a2fd7eed140",

  // NFT V1
  nftsV1: {
    NFTMinter: "0xd936461f1C15eA9f34Ca1F20ecD54A0819068811",
    BurnerEYE: "0xA592e074f990c87E10b3Bba1DACFB9187899575b",
    BurnerSCX: "0xbe2fbBb49b26C20E3aEE3b0608cB5116aeD5d297",
    BurnerFlax: "0xD3B630cBA76AEA5Aadb4cB71732227E073C8338C",
    BalancerPooler: "0xC2d1a82C66Fd535ae218b59F77a1B716919a46C3",
    GatherWBTC: "0xb304e2E63820D4f7B41219D2C39123E20444D0C9",
  },

  // NFT V2 — not yet deployed
  nftsV2: {
    NFTMinter: "0x39af088408e815844c567037c157b31d48d2e10f",
    BurnerEYE: "0x13fb51bcb3c5ae9e7115730bc1a58ec676ceeef2",
    BurnerSCX: "0xa833603fd82674aec51f8a57c6a27b91bc1725b2",
    BurnerFlax: "0xb63b57025e9bee5bbb66e4a5297ed0ca044d5ff7",
    BalancerPooler: "0x6e957842afbcd01ce9db296d173f39134b362771",
    GatherWBTC: "0xfd3775f2ccfb94b532b34b2b683e210ba4449880",
  },

  // View contracts
  ViewRouter: "0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a",
  DepositPageView: "0x50D4443782bB9A6e8D65dAcd593684EDd3FF03b8",
  MintPageView: "0x64FE63ca7BA456a9Bb190140e35DF2e437AbD119",


};

export type MainnetContractName = keyof ContractAddresses;
