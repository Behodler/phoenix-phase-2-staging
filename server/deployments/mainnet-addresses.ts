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
  // V2 of PhlimboEA -- deployed by story 049 MigratePhlimboV1ToV2.s.sol
  PhlimboEA: "0x6084a02c2ac0127ddf1e617de257c61480a2aee0",
  StableYieldAccumulator: "0x3bbe928340c61a65cb6c4a87b3fb59b6f3f7606a",
  DepositView: "0x0725722b50287f2285b873f534d5848e76c15251",
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
  BalancerPool: "0x642BB6860b4776CC10b26B8f361Fd139E7f0db04",
  BalancerVault: "0xbA1333333333a1BA1108E8412f11850A5C319bA9",
  BalancerRouter: "0x5C6fb490BDFD3246EB0bB062c168DeCAF4bD9FDd",

  // NFT infrastructure — common
  BurnRecorder: "0x2A2c4186C906d3b347c86882ad4Bd1f2bE05579F",

  // NFT V2 contracts (flattened)
  NFTMinter: "0x39af088408e815844c567037c157b31d48d2e10f",
  BurnerEYE: "0x13fb51bcb3c5ae9e7115730bc1a58ec676ceeef2",
  BurnerSCX: "0xa833603fd82674aec51f8a57c6a27b91bc1725b2",
  BurnerFlax: "0xb63b57025e9bee5bbb66e4a5297ed0ca044d5ff7",
  BalancerPooler: "0x26f89f4b46eb164303985795ee20b15bb1edb38a",
  GatherWBTC: "0xfd3775f2ccfb94b532b34b2b683e210ba4449880",

  // View contracts
  ViewRouter: "0xC17Ce1cE5ebB43fc0cfda9Fe8BbC849c0894631a",
  DepositPageView: "0x50D4443782bB9A6e8D65dAcd593684EDd3FF03b8",
  // Story 048: reverted from 0xeBEc50cD19310e6ed59D8153313Ec7C888152c1A (index-6 view)
  // to the prior index-4 view ahead of the dispatcher cutover. Verified on-chain:
  // getData(0)[23] == 4 for the address below.
  MintPageView: "0x64FE63ca7BA456a9Bb190140e35DF2e437AbD119",
  // NFT staking
  BalancerPoolerMintDebtHook: "0x14277a0bc38a6bb7eb732c3a49190030632f727e",
  NFTStaker: "0xc8514f821a3d801fa8a8c435840a992a4365a13b",
  WaUSDC: "0xd4fa2d31b7968e448877f69a96de69f5de8cd23e",
  BatchNFTMinter: "0x6e9886AfDF07DD67dc70b8335E4e9DF14B445071",
  // Stable Staking (story 051) — not yet deployed to mainnet; placeholder.
  StableStaker: "0x0000000000000000000000000000000000000000",

};

export type MainnetContractName = keyof ContractAddresses;
