# PauserV2 migration: V1 registrant classification (story 128)

Every contract registered with the V1 mainnet Pauser `0x7c5A8EeF1d836450C019FB036453ac6eC97885a3`,
classified LIVE or RETIRED for the PauserV2 migration.

- **LIVE** registrants are rotated onto PauserV2 and registered there by
  `script/MigratePauserV2Mainnet.s.sol`.
- **RETIRED** registrants get **no transaction**. They stay on V1, which the migration bricks.
  PauserV2 never covers them.

The sets are hard-coded in `script/helpers/PauserV2MainnetBase.sol` (`liveRegistrants()` /
`retiredRegistrants()`). The migration preflight checks the combined 27-address set against the
live `V1.getPausableContracts()` and refuses on any drift. If you see that refusal, re-run the
classification and update both this table and that file.

## Sources

Swept at mainnet block **26,333,708** (2026-11-03). Every registrant had `owner() == OWNER`
(`0xCad1…D0B6`), `pauser() == V1`, a `paused()` getter, and `paused() == false`.

| Source | What it gives |
|---|---|
| `script/ClassifyPauserV2Registrants.s.sol` (`npm run pauser-v2-classify`) | Code size, owner, pauser, paused, `getTotalShares()`, `totalSupply()`, non-zero ERC-20 balances across the book's tokens, ERC-1155 balances of NFTMinter V2/V1 ids 1..8 |
| `scripts/pauser-v2-registrant-labels.js` | Labels from the current book (including the header block comment), from every historical `mainnet*.ts`, and from the `progress*.1.json` files. Also the Etherscan verified name |
| Manual `cast` / Etherscan reads | Last transactions, creation date, `phUSD.authorizedMinters`, strategy client lists, minter `stablecoinConfigs`, SYA strategy lists, V1 NFTMinter dispatcher `configs` |

## Rule

- **LIVE** if any of these hold: it is labelled non-"Old" in the current book; it holds non-dust
  funds or positions; users can still interact with it with economic effect.
- **AMBIGUOUS → LIVE** (fail-safe). The cost is two extra transactions. The alternative is a live
  contract with no stop.
- **RETIRED** otherwise.

## Table

`#` is the index in `V1.getPausableContracts()` at the sweep block. `Order` is the rotation order
for LIVE registrants: value at risk first.

| # | Address | Identity (book / Etherscan) | Evidence | Verdict | Order |
|---|---|---|---|---|---|
| 26 | `0xA6d3fc83C91B8319D219cEB12B46e3dfF064B58F` | StableStakerV2 (current book) | Holds user principal in the three live strategies. Claims and stakes in late Oct 2026. Re-registered with V1 after the story-124 freeze/unfreeze | **LIVE** | 1 |
| 25 | `0x9CA92B527012DfC6Fdca7B7493C722D5901FF151` | Antimatter (current book) | Reward token, `totalSupply` ≈ 2,457.7 AM. Holders active (approvals on 2026-11-02) | **LIVE** | 2 |
| 2 | `0x8D3A8E3ba43DEb8C7e2110DF437a92243523b6ca` | PhlimboV3 (current book) | Holds 17,122 phUSD + 404.9 USDC. Stakes and claims in Oct 2026 | **LIVE** | 3 |
| 20 | `0xaFDf8DeA96a0F37Aae4869f813901bf73a3eAB83` | YieldStrategyUSDC (current book) | 14,734.8 autoUSD shares. Clients: PhusdStableMinter, StableStakerV2, StableStaker V1 | **LIVE** | 4 |
| 19 | `0x981c7BE1460c7C8Cb40B8EB5908B29510Ae0B7EE` | YieldStrategyDola (current book) | 11,235.8 sDOLA shares. Clients: StableStakerV2, PhusdStableMinter | **LIVE** | 5 |
| 17 | `0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95` | YieldStrategyUSDe (current book) | 5,157.8 sUSDe shares. Clients: old PhusdStableMinter, StableStakerV2, PhusdStableMinter | **LIVE** | 6 |
| 21 | `0x94855ACA13952D81507C92D3CdBb2e25D3bbE60C` | PhusdStableMinter (current book) | Mints phUSD against USDC/DOLA/USDe (last mint 2026-10-09) | **LIVE** | 7 |
| 1 | `0x435B0A1884bd0fb5667677C9eb0e59425b1477E5` | PhusdStableMinter (backups only; Etherscan `PhusdStableMinter`) | Not in the current book and has no phUSD mint right (`authorizedMinters.canMint == false`). But it still has **≈ 3,749.6 USDe principal** (`principalOf`) in the live YieldStrategyUSDe, is still that strategy's authorized client, and holds ≈ $26 of USDC/DOLA/USDe dust | **LIVE** (non-dust position) | 8 |
| 12 | `0x39Af088408e815844c567037C157B31d48d2E10F` | NFTMinter (V2, current book) | `totalSupply` 5,445. Admin activity on 2026-10-31 | **LIVE** | 9 |
| 4 | `0x068395556b8c43eDf257DC54D109EA5910aE15c7` | BatchNFTMinter (current book) | Batch mints through 2026-11-01. 0.36 USDC | **LIVE** | 10 |
| 8 | `0xd936461f1C15eA9f34Ca1F20ecD54A0819068811` | NFTMinter (V1; backups + `progress.1.json`; Etherscan `NFTMinter`) | V1 is decommissioned and its last user mint was 2026-04-17. But dispatcher indices 1, 2, 3, 5 and 6 are still **enabled** (`configs(i).disabled == false`), so `mint` may still take user funds and dispatch them | **LIVE** (ambiguous → LIVE) | 11 |
| 6 | `0x4Bf42BD098774a3b3e844cd42149ebBB1108E541` | Not in any book (Etherscan `NFTMinter`; created 2026-03-19) | Pre-V1 NFTMinter. Dispatchers 1–5 are still **enabled**, so the same reasoning as #8 applies | **LIVE** (ambiguous → LIVE) | 12 |
| 13 | `0xc8514f821A3d801Fa8a8c435840a992A4365a13b` | NFTStaker (current book) | Holds 4,282 NFTs (id 4) + 26,189 phUSD rewards. Stakes and claims in Oct 2026 | **LIVE** | 13 |
| 22 | `0x299b0071DEf42D35eaf5ea24CC0a71Cf10655A64` | RatchetNFTStaker (current book) | Holds 337 NFTs (id 7) + 12,379 phUSD | **LIVE** | 14 |
| 23 | `0xE9067f37f6D0bb116233194690fb600Add8fD052` | UniboostStakerEYE (current book) | Holds 378 NFTs (id 1) + 1,900.6 phUSD. Claim on 2026-11-03 | **LIVE** | 15 |
| 24 | `0x541b912B5451FfE2c04D5Ea8D317081718683242` | UniboostStakerSCX (current book) | Holds 295 NFTs (id 2) + 1,238.3 phUSD | **LIVE** | 16 |
| 18 | `0x17E25Cca844bC71c1E663E089fF11aFD266B5795` | UniboostStakerFLX (current book) | Holds 20 NFTs (id 3) + 44.8 phUSD | **LIVE** | 17 |
| 14 | `0x0cD353bfda674D04823B2826ffafB83B560D21B6` | StableYieldAccumulator (book until story 131) | Claims through 2026-10-25. Strategies are the three live ones. **Retired by story 131** (`ReplaceSYAGateOffMainnet`): unregistered from PauserV2, `pauser()` moved to OWNER, strategies removed, withdrawer and burner rights revoked, Phlimbo allowance 0, not paused. Listed in `PauserV2Registry.postMigrationRemovals()` once the human broadcasts | **LIVE** at the sweep; retired by story 131 | 18 |
| 0 | `0x5cBAd8c3a18F37BC829e319533927a57d2BC99a4` | "Old YieldStrategyDola" (book header comment) | `getTotalShares() == 0`, no balances, last tx 2026-03-31 | **RETIRED** | — |
| 3 | `0xdD9A470dFFa0DF2cE264Ca2ECeA265d30ac1008f` | Not in any book (unverified; selectors `addYieldStrategy` / `removeYieldStrategy`; created 2026-01-24) | A first-generation StableYieldAccumulator. Its strategies (`0x01d3…a20C`, `0x8b4A…3952`) both have 0 shares, it holds nothing, no phUSD mint right, last tx 2026-04-06 | **RETIRED** | — |
| 5 | `0xdd8cE46ea31d51f38279886a81cFc4c1a90d5E19` | Not in any book (Etherscan `StableYieldAccumulator`; created 2026-03-19) | Strategies `0x01d3…a20C` and `0xf5F9…0E5B` both have 0 shares. Holds nothing, no user activity | **RETIRED** | — |
| 7 | `0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E` | StableYieldAccumulator (backups; `progress.1.json` `NewStableYieldAccumulator`) | All five strategies (`0xf5F9`, `0x5cBA`, `0xE7aE`, `0x8b4A`, `0xFc62`) have 0 shares. Holds nothing, last user claim 2026-05-08 | **RETIRED** | — |
| 9 | `0xE7aEC21BF6420FF483107adCB9360C4b31d69D78` | "New YieldStrategyDola" (book header comment; Etherscan `ERC4626YieldStrategy`) | `getTotalShares() == 0`, no balances, last tx 2026-06-10 | **RETIRED** | — |
| 10 | `0x8b4A75290A1C4935eC1dfd990374AC4BD4D33952` | "New YieldStrategyUSD" (book header comment; Etherscan `ERC4626YieldStrategy`) | `getTotalShares() == 0`, no balances | **RETIRED** | — |
| 11 | `0xFc629bC5F6339F77635f4F656FBb114A31F7bCB3` | YieldStrategyUSDe (backups; Etherscan `ERC4626MarketYieldStrategy`) | `getTotalShares() == 0`, no balances | **RETIRED** | — |
| 15 | `0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9` | YieldStrategyDola (backups) | `getTotalShares() == 0`, no balances. Its clients are the old PhusdStableMinter, which cannot mint, and StableStaker V1 | **RETIRED** | — |
| 16 | `0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470` | YieldStrategyUSDC (backups) | `getTotalShares() == 0`, no balances. Same clients as #15 | **RETIRED** | — |

**Post-sweep changes (not part of the 27-address snapshot).** The snapshot above, and
`liveRegistrants()` in `script/helpers/PauserV2MainnetBase.sol`, are frozen. Later changes live in
`script/helpers/PauserV2Registry.sol`:

- **Story 131, gate-free SYA.** The new StableYieldAccumulator (NFT claim gate off, 1% discount,
  address in `server/deployments/progress.sya-gate-off.1.json`) is registered with PauserV2 and
  appended to `postMigrationAdditions()`. The old SYA `0x0cD3…21B6` (#14 above) is unregistered and
  appended to `postMigrationRemovals()`. The patcher `scripts/patch-mainnet-addresses-sya-gate-off.js`
  makes both entries after the human's broadcast.

**Totals:** 18 LIVE (15 from the current book, 1 because of its funds, 2 ambiguous → LIVE) and
9 RETIRED, for 27 in all.

## Notes

- **The design doc's "3 unidentified" addresses are resolved.** `0xdD9A…008f` and `0xdd8c…5E19`
  are early StableYieldAccumulators (RETIRED). `0x4Bf4…E541` is an early NFTMinter (LIVE,
  ambiguous).
- **The old PhusdStableMinter is LIVE only because of its position.** It is not a phUSD minter,
  so `mint` reverts. Its ≈ 3,750 USDe principal still sits in the live YieldStrategyUSDe as a
  client balance, though, and that is a position under the rule. A later cleanup can withdraw it
  and retire the minter. That is not this story's work.
- **The two old NFTMinters are LIVE as a fail-safe.** Their dispatchers were never disabled, so a
  user can probably still pay into `mint`. Disabling the dispatchers (`setDispatcherDisabled`)
  would let a later classification retire them.
- **Retired registrants stay on V1.** Once the migration rotates the first live registrant, V1's
  `pause()` reverts for everyone. That is intended: V1 is dead after the migration, and none of
  the retired contracts holds anything worth stopping.
- **This snapshot assumes phStaging2:119 has not run.** If phStaging2:119 broadcasts first and
  registers its new minter with V1, the migration preflight refuses. In that case add the new
  minter to the live set, re-run the classification, and update this table.
