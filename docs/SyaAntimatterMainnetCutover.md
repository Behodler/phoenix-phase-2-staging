# SYA / Antimatter mainnet catch-up (story 122)

Three human-broadcast mainnet scripts bring mainnet level with `script/DeployMocks.s.sol` Phases 11.7-11.14.
The executing agent wrote, fork-tested and previewed them; **only the human broadcasts**, from the Ledger
(OWNER `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`, HD path `m/44'/60'/46'/0/0`).

| Script | What it does | npm keys | Progress file | Address-book keys |
|---|---|---|---|---|
| **A** `DeploySyaHarvesterMainnet` | Deploy `SYAHarvester`, set the USDe + DOLA Curve Router NG routes and the ETH/USDC V4 pool, then `StableStakerV2.setClaimEnabled(true)` | `sya-harvester:preview / :broadcast / :verify / :etherscan` | `progress.sya-harvester.1.json` | FILL `SYAHarvester` |
| **B** `CutoverAntimatterPoolMainnet` | Deploy `AntimatterPoolSeeder`, move **10%** of UniPoolerV2's phUSD/sUSDS LP into a new AM/sUSDS UniV2 pair | `antimatter-pool:preview / :broadcast / :verify / :etherscan` | `progress.antimatter-pool.1.json` | FILL `AntimatterPoolSeeder`, `AntimatterSusdsPair` |
| **C** `DeployUniswapHelperMainnet` | Redeploy `UniswapHelper` (story-120 15-arg build with Antimatter routes) | `uniswap-helper:preview / :broadcast / :verify / :etherscan` | `progress.uniswap-helper-am.1.json` (new) | REPOINT `UniswapHelper` from `0x564810D5d9D31754C8dbdb8F62Bb429D50Dfa5b3` |

## Order

1. **A and B, in either order.** They touch disjoint state (A: a new harvester + one StableStakerV2 flag; B:
   UniPoolerV2's LP, Antimatter's minter list, a new pair).
2. **Then C, strictly after B has landed and B's patcher has filled `AntimatterSusdsPair`.** C enforces this in
   code: it refuses with `run the Antimatter cutover (Script B) first` unless the book's `AntimatterSusdsPair` is
   non-zero, equals `factory.getPair(AM, sUSDS)` and has code. Its `:preview` therefore **fails on that
   precondition until B is live - that is the guard working**, not a bug.

All commands run from the repo root with `RPC_MAINNET` exported (`.envrc`) and the Ledger connected.

## Script A - SYAHarvester + claim enable

1. `npm run sya-harvester:preview`. Check in the log:
   - `Route safety 1/2`: both payloads pass the story-052 check (USDe 2 hops, DOLA 1 hop, both deliver USDC).
   - `Route safety 2/2`: four balance deltas, each at least 970 (USDC or token) for 1,000 in.
   - `read-back OK`, a positive `harvest ETH balance delta`, `setClaimEnabled(true) sent`, `Transactions this run: 5`.
2. `npm run sya-harvester:broadcast`. Backs up `mainnet-addresses.ts`, sends 5 transactions (CREATE, 2x `setRoute`,
   `setEthPool`, `setClaimEnabled`), writes the progress file, fills `SYAHarvester`, runs `:verify`, records the tax
   ledger. Gas price `SYA_HARVESTER_GAS_PRICE_WEI` (default 0.3 gwei).
3. Optional: `npm run sya-harvester:etherscan` (unchained; a failure here changes nothing on chain or in the book).

**The route safety is not skippable.** The off-chain check and the two-way dry run sit in the script body
before the first `vm.startBroadcast`, and `forge script` simulates the whole run before it sends anything, so a
failure anywhere aborts the broadcast. This is the human's standing warning (repo `CLAUDE.md`, audit ryv18m5)
made mechanical.

**Knock-on for the StableStaker V2 cutover scripts.** `CutoverStableStakerV2Mainnet` (Phases 7 and 8) and
`VerifyStableStakerV2Cutover` asserted `claimEnabled == false`. They now accept `true` once the unblock is on
record: A's progress file says `claimEnabled: true`, or the book's `SYAHarvester` key is filled
(`script/helpers/ClaimUnblockState.sol`). Before that, `false` is still required.

## Script B - Antimatter/sUSDS cutover

**Broadcast it through a private RPC.** Anyone can create the AM/sUSDS pair first and leave it one-sided
(griefing risk R1, story 113). B refuses to seed into a pair it did not create, but a front-run would still waste
the session. Override the RPC for the broadcast only, e.g.

```bash
RPC_MAINNET=https://rpc.flashbots.net npm run antimatter-pool:broadcast
```

1. `npm run antimatter-pool:preview`. Check: `factory.getPair(AM, sUSDS) == 0: OK`, the LP slice (10% of
   UniPoolerV2's LP), the two floors, `AM minted == phUSD burned`, `seeder empty, not a minter`,
   `Transactions this run: 6`.
2. `npm run antimatter-pool:broadcast` (6 transactions: CREATE, `rescueERC20`, `approve`,
   `setApprovedMinter(true)`, `seed`, `setApprovedMinter(false)`). Then the patcher fills both keys, `:verify`
   runs and the tax ledger records (suggested `LEDGER_NOTE="protocol-owned LP conversion phUSD/sUSDS -> AM/sUSDS"`).
3. Optional: `npm run antimatter-pool:etherscan`.

F3 (story 113): the seeder adds the AM/sUSDS liquidity with `amountBMin = 0`. That is safe only because the pair
is created inside the same transaction; step 0 guarantees it.

## Script C - UniswapHelper redeploy

Only after B is live **and** `AntimatterSusdsPair` is filled in `mainnet-addresses.ts` (commit B's patch first).

1. `npm run uniswap-helper:preview`. Check `Precondition OK`, the 15 inputs, `OK: every immutable matches`.
2. `npm run uniswap-helper:broadcast`. One CREATE; writes `progress.uniswap-helper-am.1.json` (the story-111
   `progress.uniswap-helper.1.json` is history and is never read again); the patcher REPOINTs `UniswapHelper`
   only from `0x564810D5...a5b3` (anything else is a COLLIDE); `:verify` now also checks `antimatter()`,
   `amPair() == factory.getPair == book AntimatterSusdsPair` and AM quotes; the tax ledger records.
3. Optional: `npm run uniswap-helper:etherscan`.

## After all three

- Commit the progress files, the patched `mainnet-addresses.ts` and `ledger/transactions.csv`.
- Re-run all three `:verify` keys plus `npm run stable-staker-v2-cutover:verify` (must still pass with
  `claimEnabled == true`).
- **phlimbo-ui follow-up (separate story):** `src/lib/contracts.ts` hardcodes `UniswapHelper` and the three zero
  keys (`SYAHarvester`, `AntimatterPoolSeeder`, `AntimatterSusdsPair`). Update it after the broadcasts.
- **Story 119 interaction:** SYA's nudge sink is the old `BatchNFTMinter` `0x0683...15c7`. Every harvest (a SYA
  `claim`) streams its nudge share to that minter through NudgeStreamer. That is harmless before 119; 119 repoints
  SYA's nudge and migrates the old minter's stream buffer. After 119 repoints the sink, the new sink must have a
  registered USDC stream, otherwise every SYA claim - and so every harvest - reverts `NudgeStreamer__NotRegistered`.
- Whichever of 119 and this story broadcasts second re-runs its preview and verifier (both touch UniPoolerV2/SYA).

## If something goes wrong

- **Every script is resumable.** Re-run `:broadcast`; each step is gated on chain state and only the missing ones
  are sent. B's LP slice is fixed at first sizing and read from its progress file, so a resume never re-sizes.
  B's minter revoke runs on every run.
- **Progress file names an address with no code**: recorded in forge's local pass, never landed. Check
  `broadcast/<Script>.s.sol/1/run-latest.json`, then delete the progress file and start again from preview.
- **A patcher fails** (exit 2/3/4): the chain is fine, the book is unchanged. Fix the cause, re-run the patcher and
  `:verify`. Never re-broadcast to fix a patcher.

## Preview evidence (story 122 execution)

Previews run against `$RPC_MAINNET` on 2026-10-30 (full logs in the product-owner story file). Re-run every preview
immediately before its broadcast; the numbers drift.

- **A** (`sya-harvester:preview`, exit 0): both payloads pass the story-052 check. Dry-run balance deltas:
  1000 USDe -> 997.90 USDC; 1000 USDC -> 1001.70 USDe; 1000 DOLA -> 994.16 USDC; 1000 USDC -> 1004.88 DOLA.
  Read-back OK. Harvest smoke: SYA claimable 20.09 USDC, caller ETH delta 0.003643 ETH. 5 transactions.
- **B** (`antimatter-pool:preview`, exit 0): pair absent. UniPoolerV2 LP 22,589.27; slice (10%) 2,258.93 LP.
  Floors: phUSD 2,455.25, sUSDS 2,075.08 (expected 2,457.71 / 2,077.16). AM minted == phUSD burned 2,457.70.
  AM/sUSDS LP to OWNER 2,259.43. UniPoolerV2 LP after 20,330.34. Seeder empty and not a minter. 6 transactions.
- **C** (`uniswap-helper:preview`, exit 1, expected): `precondition: AntimatterSusdsPair is zero in
  mainnet-addresses.ts - run the Antimatter cutover (Script B) first`. The guard is working; C's fork test proves
  B-then-C end to end.
