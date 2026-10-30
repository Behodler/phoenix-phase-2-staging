# SYA / Antimatter mainnet catch-up (stories 122, 123)

Three human-broadcast mainnet scripts bring mainnet level with `script/DeployMocks.s.sol` Phases 11.7-11.14.
The executing agent wrote, fork-tested and previewed them; **only the human broadcasts**, from the Ledger
(OWNER `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`, HD path `m/44'/60'/46'/0/0`).

| Script | What it does | npm keys | Progress file | Address-book keys |
|---|---|---|---|---|
| **A** `DeploySyaHarvesterMainnet` | Deploy `SYAHarvester`, set the USDe + DOLA Curve Router NG routes and the ETH/USDC V4 pool, then `StableStakerV2.setClaimEnabled(true)` | `sya-harvester:preview / :broadcast / :verify / :etherscan` | `progress.sya-harvester.1.json` | FILL `SYAHarvester` |
| **B** `CutoverAntimatterPoolMainnet` | Deploy `AntimatterPoolSeeder`, move **10%** of UniPoolerV2's phUSD/sUSDS LP into a new AM/sUSDS UniV2 pair | `antimatter-pool:preview / :broadcast / :verify / :etherscan` | `progress.antimatter-pool.1.json` | FILL `AntimatterPoolSeeder`, `AntimatterSusdsPair` |
| **C** `DeployUniswapHelperMainnet` | Redeploy `UniswapHelper` (story-120 15-arg build with Antimatter routes) | `uniswap-helper:preview / :broadcast / :verify / :etherscan` | `progress.uniswap-helper-am.1.json` (new) | REPOINT `UniswapHelper` from `0x564810D5d9D31754C8dbdb8F62Bb429D50Dfa5b3` |

## Order: B, then A, then C - one command

```bash
npm run sya-antimatter-cutover:preview     # B then A (C excluded, see below)
npm run sya-antimatter-cutover:broadcast   # B && A && C
```

1. **B before A (audit run-44 M-01).** Before A's last transaction, `StableStakerV2.setClaimEnabled(true)`, no
   third party holds Antimatter. Under `--broadcast --skip-simulation --slow`, B's tx1-tx4 (seeder CREATE, LP
   rescue, approve, `setApprovedMinter`) are mined publicly before tx5 `seed()`. If AM were already in circulation,
   any holder could create the AM/sUSDS pair AM-cheap in that window and buy the ~2,457.70 seeded AM for dust (the
   fork-proven loss was about $2.3k of POL). Running B first removes the precondition; the seeder's on-chain
   `minSUSDSPaired` floor (story 123) is the backstop and makes such a seed revert `InsufficientSUSDSPaired`.
2. **Then A.** A reads nothing B writes; under `&&` and `--slow`, A simulates against B's landed state. This is the
   order DeployMocks has always rehearsed (11.10 cutover, 11.12 harvester, 11.13 claim enable).
3. **Then C, strictly after B has landed and B's patcher has filled `AntimatterSusdsPair`.** The combined key
   guarantees this: B's patcher runs inside `antimatter-pool:broadcast`, so the working-tree book is patched before
   C starts, and C reads it at run time. C also enforces it in code: it refuses with `run the Antimatter cutover
   (Script B) first` unless the book's `AntimatterSusdsPair` is non-zero, equals `factory.getPair(AM, sUSDS)` and
   has code.

Because of `&&`, A never runs if B or its verifier fails, and C never runs if A or its verifier fails.

**The combined preview excludes C.** C's `:preview` fails on its pair precondition until B has landed and been
patched (exit 1, expected - see the preview evidence below), and B's preview writes nothing, so chaining it would
always fail. During the chained broadcast C's in-script preflight (`_requireCode`, `_requireVenues`, the pair
precondition, `_checkImmutables`) still gates its CREATE. If you want to inspect C's preview, run
`npm run uniswap-helper:preview` after B has landed; it is meaningful only then.

The individual `:broadcast` keys remain, for resume and for running C alone. Do not run `sya-harvester:broadcast`
on its own before B has landed.

All commands run from the repo root with `RPC_MAINNET` exported (`.envrc`) and the Ledger connected. B alone may
optionally use a private RPC (`ANTIMATTER_POOL_RPC_URL`, below).

**Tax-ledger notes.** A process-wide `LEDGER_NOTE` is not passed to A or C by the combined key (they run with
`LEDGER_NOTE` cleared), so B's note cannot be stamped on their rows. Give B's note through its own variable:

```bash
ANTIMATTER_POOL_LEDGER_NOTE="protocol-owned LP conversion phUSD/sUSDS -> AM/sUSDS" npm run sya-antimatter-cutover:broadcast
```

When `antimatter-pool:broadcast` runs alone, `ANTIMATTER_POOL_LEDGER_NOTE` wins and `LEDGER_NOTE` is the fallback.

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

**What protects the seed.** B's step 0 (`factory.getPair(AM, sUSDS) == 0`) runs only in forge's local
simulation. On chain, tx1-tx4 are mined publicly before tx5 `seed()`, so a pair can still appear in between. The
real control is the seeder's on-chain `minSUSDSPaired` floor: Script B passes the pro-rata sUSDS quote less 0.1%,
so a pair pre-priced AM-cheap makes tx5 revert `InsufficientSUSDSPaired` instead of leaking the AM. A one-sided
griefed pair (dust + `sync`, no LP) still seeds, because the direct mint pairs all the sUSDS. Running B before A
(above) means nobody outside the protocol holds AM during the window anyway.

**Private RPC: optional, not a safety control.** A private RPC hides only pending transactions. Under `--slow`
tx1-tx4 are mined publicly before the seed, so it does not cover the window. If you still want one, scope it to B's
forge call only - A, the verifiers and the tax ledger keep using `RPC_MAINNET`:

```bash
ANTIMATTER_POOL_RPC_URL=<private RPC URL> npm run sya-antimatter-cutover:broadcast
```

Do **not** override `RPC_MAINNET` itself for this. Note that C's pair precondition reads `getPair` over
`$RPC_MAINNET`; if that node lags B's private-RPC landing, C refuses to run. That is safe: re-run
`npm run uniswap-helper:broadcast`.

1. `npm run antimatter-pool:preview`. Check: `factory.getPair(AM, sUSDS) == 0: OK`, the LP slice (10% of
   UniPoolerV2's LP), the three floors (`minPhUSD`, `minSUSDS`, `minSUSDSPaired`), `AM minted == phUSD burned`,
   `seeder empty, not a minter`,
   `Transactions this run: 6`.
2. Broadcast via the combined key (first step), or `npm run antimatter-pool:broadcast` alone (6 transactions:
   CREATE, `rescueERC20`, `approve`, `setApprovedMinter(true)`, `seed`, `setApprovedMinter(false)`). Then the
   patcher fills both keys, `:verify` runs and the tax ledger records (suggested
   `ANTIMATTER_POOL_LEDGER_NOTE="protocol-owned LP conversion phUSD/sUSDS -> AM/sUSDS"`).
3. Optional: `npm run antimatter-pool:etherscan`.

F3 (story 113): the seeder adds the AM/sUSDS liquidity through the router with `amountBMin = 0`. That is now
bounded by the on-chain `minSUSDSPaired` floor (story 123), not by step 0, which cannot see the publicly mined
tx1-tx4 window.

## Script C - UniswapHelper redeploy

Only after B is live **and** `AntimatterSusdsPair` is filled in `mainnet-addresses.ts`. The combined key runs C last;
C reads the working-tree book B's patcher has just written, so nothing needs committing first (commit everything
after the whole chain, below).

1. No separate preview gate. C's in-script preflight (`_requireCode`, `_requireVenues`, the pair precondition,
   `_checkImmutables`) gates its CREATE during the chained broadcast. If you want to inspect it, run
   `npm run uniswap-helper:preview` after B has landed and check `Precondition OK`, the 15 inputs and
   `OK: every immutable matches`.
2. Broadcast via the combined key (last step), or `npm run uniswap-helper:broadcast` alone. One CREATE; writes `progress.uniswap-helper-am.1.json` (the story-111
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

- **Recovering the combined key.**
  - **B fails** (or its verifier): A and C never ran. Fix the cause and re-run
    `npm run sya-antimatter-cutover:broadcast`; B resumes.
  - **A fails**: C did not run. Re-run `npm run sya-antimatter-cutover:broadcast`. B resumes or no-ops
    (`test_fork_broadcastMode_progress_rerunIsNoop_verifyPasses` in `test/CutoverAntimatterPoolMainnet.fork.t.sol`:
    a re-run after B has landed sends 0 transactions) and A resumes.
  - **C fails after A has landed**: prefer `npm run uniswap-helper:broadcast` alone. Re-running the combined key
    is also safe - A's re-run after it has fully landed is a no-op too
    (`test_fork_broadcastMode_writesProgress_rerunIsNoop_verifyPasses` in
    `test/DeploySyaHarvesterMainnet.fork.t.sol`: 0 transactions, the recorded harvester is adopted; its patcher
    reports `SAME`; `ledger-record.js` de-duplicates on tx hash) - but it repeats B's and A's simulations for no gain.
  - **C refuses because `$RPC_MAINNET` lags B's private-RPC landing**: wait a block and re-run
    `npm run uniswap-helper:broadcast`.
- **Every script is resumable.** Re-run `:broadcast`; each step is gated on chain state and only the missing ones
  are sent. B's LP slice is fixed at first sizing and read from its progress file, so a resume never re-sizes.
  B's minter revoke runs on every run.
- **Progress file names an address with no code**: recorded in forge's local pass, never landed. Check
  `broadcast/<Script>.s.sol/1/run-latest.json`, then delete the progress file and start again from preview.
- **A patcher fails** (exit 2/3/4): the chain is fine, the book is unchanged. Fix the cause, re-run the patcher and
  `:verify`. Never re-broadcast to fix a patcher.

## Preview evidence (story 122 execution)

Previews run against `$RPC_MAINNET` on 2026-10-30 (full logs in the product-owner story file). Re-run
`npm run sya-antimatter-cutover:preview` immediately before the broadcast; the numbers drift.

- **A** (`sya-harvester:preview`, exit 0): both payloads pass the story-052 check. Dry-run balance deltas:
  1000 USDe -> 997.90 USDC; 1000 USDC -> 1001.70 USDe; 1000 DOLA -> 994.16 USDC; 1000 USDC -> 1004.88 DOLA.
  Read-back OK. Harvest smoke: SYA claimable 20.09 USDC, caller ETH delta 0.003643 ETH. 5 transactions.
- **B** (`antimatter-pool:preview`, exit 0): pair absent. UniPoolerV2 LP 22,589.27; slice (10%) 2,258.93 LP.
  Floors: phUSD 2,455.25, sUSDS 2,075.08 (expected 2,457.71 / 2,077.16); `minSUSDSPaired` = the sUSDS floor
  (story 123). AM minted == phUSD burned 2,457.70.
  AM/sUSDS LP to OWNER 2,259.43. UniPoolerV2 LP after 20,330.34. Seeder empty and not a minter. 6 transactions.
- **C** (`uniswap-helper:preview`, exit 1, expected): `precondition: AntimatterSusdsPair is zero in
  mainnet-addresses.ts - run the Antimatter cutover (Script B) first`. The guard is working; C's fork test proves
  B-then-C end to end.
