# SYA / Antimatter mainnet catch-up (stories 122, 123, 124)

Three human-broadcast mainnet scripts bring mainnet level with `script/DeployMocks.s.sol` Phases 11.7-11.14.
The executing agent wrote, fork-tested and previewed them; **only the human broadcasts**, from the Ledger
(OWNER `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`, HD path `m/44'/60'/46'/0/0`).

| Script | What it does | npm keys | Progress file | Address-book keys |
|---|---|---|---|---|
| **A** `DeploySyaHarvesterMainnet` | Deploy `SYAHarvester`, set the USDe + DOLA Curve Router NG routes and the ETH/USDC V4 pool, then `StableStakerV2.setClaimEnabled(true)` | `sya-harvester:preview / :broadcast / :verify / :etherscan` | `progress.sya-harvester.1.json` | FILL `SYAHarvester` |
| **Freeze** `FreezeStableStakerV2ForCutover` (story 124) | Freeze StableStakerV2 for B's window: `setPauser(OWNER)` -> `Pauser.unregister(SSV2)` -> `pause()` | `ssv2-freeze-for-cutover:preview / :broadcast` (chained by `antimatter-pool:broadcast`) | none (reads B's) | none |
| **B** `CutoverAntimatterPoolMainnet` | Deploy `AntimatterPoolSeeder`, move **10%** of UniPoolerV2's phUSD/sUSDS LP into a new AM/sUSDS UniV2 pair, then restore StableStakerV2 | `antimatter-pool:preview / :broadcast / :verify / :etherscan` | `progress.antimatter-pool.1.json` | FILL `AntimatterPoolSeeder`, `AntimatterSusdsPair` |
| **Unfreeze** `UnfreezeStableStakerV2AfterCutoverAbort` (story 124, recovery only) | Restore StableStakerV2 after an abandoned window: `unpause()` -> `setPauser(Pauser)` -> `Pauser.register(SSV2)` | `ssv2-unfreeze-after-cutover-abort:preview / :broadcast` (never chained) | none (reads B's) | none |
| **C** `DeployUniswapHelperMainnet` | Redeploy `UniswapHelper` (story-120 15-arg build with Antimatter routes) | `uniswap-helper:preview / :broadcast / :verify / :etherscan` | `progress.uniswap-helper-am.1.json` (new) | REPOINT `UniswapHelper` from `0x564810D5d9D31754C8dbdb8F62Bb429D50Dfa5b3` |

## Order: freeze + B, then A, then C - one command

```bash
npm run sya-antimatter-cutover:preview     # B (pranks the freeze itself) then A (C excluded, see below)
npm run sya-antimatter-cutover:broadcast   # freeze && B && A && C
```

1. **B runs inside a StableStakerV2 freeze (story 124, audit run-44 M-02 / run-45 pps44m2).** B-before-A ordering
   alone does **not** keep Antimatter out of third-party hands: any StableStakerV2 staker can `withdraw` their full
   principal (which banks the pending reward without a `claimEnabled` check) and then `autoAnnihilate`, whose excess
   branch mints the whole reward as raw AM. Run 45 reproduced 26.44 AM with claims closed. With AM in hand an
   outsider can (a) create the AM/sUSDS pair AM-cheap while B's tx1-tx4 (seeder CREATE, LP rescue, approve,
   `setApprovedMinter`) are mined publicly before tx5 `seed()` (M-01), or (b) mint a dust AM/sUSDS LP to OWNER and
   spoof a re-run of B into "resuming" onto the attacker's pair (M-02). So `antimatter-pool:broadcast` first runs
   the freeze step as a separate, mined forge invocation: StableStakerV2 - the only approved AM minter - is paused
   with its pauser temporarily OWNER and is unregistered from the global Pauser. B's local pass then requires that
   frozen state and, while the AM/sUSDS pair does not exist, `Antimatter.totalSupply() == 0`. With no AM outside
   the cutover and no way to mint any until B's seed lands, neither attack has the AM it needs, whatever the script
   order. B's final transactions restore StableStakerV2 (`unpause` -> `setPauser(Pauser)` -> `Pauser.register`).
   The seeder's on-chain `minSUSDSPaired` floor (story 123) stays the M-01 backstop. B still runs before A, but the
   ordering is no longer the stated M-02 fix.
2. **Then A.** A reads nothing B writes; under `&&` and `--slow`, A simulates against B's landed state. This is the
   order DeployMocks has always rehearsed (11.10 cutover, 11.12 harvester, 11.13 claim enable).
3. **Then C, strictly after B has landed and B's patcher has filled `AntimatterSusdsPair`.** The combined key
   guarantees this: B's patcher runs inside `antimatter-pool:broadcast`, so the working-tree book is patched before
   C starts, and C reads it at run time. C also enforces it in code: it refuses with `run the Antimatter cutover
   (Script B) first` unless the book's `AntimatterSusdsPair` is non-zero, equals `factory.getPair(AM, sUSDS)` and
   has code.

Because of `&&`, B never runs if the freeze fails, A never runs if B or its verifier fails, and C never runs if A or
its verifier fails.

### The freeze window (story 124)

From the freeze step's first transaction until B's restore lands, StableStakerV2 is out of normal service:

- **UI in maintenance mode** for the window (operational, the human's job). `stake`, `withdraw`, `claim` and
  `autoAnnihilate` revert `EnforcedPause`. `emergencyWithdraw` stays open and mints nothing, so principal is never
  trapped. Rewards keep accruing.
- **Do not initiate a StableStakerV2 migration** during the window: `batchMigrate` / `userMigrate` mint AM without
  the pause gate once a migration is initiated.
- **Do not run `phStaging2:119` or `npm run stable-staker-v2-cutover:verify`** while frozen: both expect a
  registered, unpaused StableStakerV2 and fail against the frozen one. Run them only after B's restore.
- **Global Pauser.** The freeze unregisters StableStakerV2 BEFORE pausing it, and the restore unpauses it BEFORE
  re-registering it, so `Pauser.pause()` (which loops every registrant with no try/catch) is never bricked by a
  paused registrant (rule of `CutoverStableStakerV2Mainnet` L44-58). Two transient one-transaction windows are
  inherent and accepted: between `setPauser(OWNER)` and `Pauser.unregister` the global pause reverts; between
  `setPauser(Pauser)` and `Pauser.register` it succeeds but misses StableStakerV2. B's preview proves the breaker
  works before the freeze, while frozen and after the restore. Never use `Pauser.pause()` for the freeze itself: it
  burns EYE and pauses all 27 registrants, Antimatter included.
- **Accepted residual.** OWNER can mint AM itself (Antimatter's `onlyApprovedMinters` admits `owner()`); OWNER is
  trusted.
- **Re-runs.** The freeze step is idempotent (each transaction is skipped when already done) and is a full no-op
  once B has completed on chain (the progress pair exists, OWNER holds at least the recorded LP, the seeder is no
  longer a minter and StableStakerV2 is restored). So the "A failed -> re-run the combined key" recovery below never
  re-freezes StableStakerV2. Do not re-run the cutover keys after OWNER has moved AM/sUSDS LP out: that anchor would
  then read as "B not complete".

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

**What protects the seed.** The StableStakerV2 freeze plus B's supply gate (above): B's step -1 requires the frozen
state and step 0 requires `Antimatter.totalSupply() == 0` while the pair does not exist, so nobody outside the
cutover holds AM during the window. Both checks run in forge's local simulation, which is why the freeze must
already be mined when B starts (the npm key chains it with `&&`, over the same RPC). On chain, tx1-tx4 are still
mined publicly before tx5 `seed()`, so a pair can still appear in between; the seeder's on-chain `minSUSDSPaired`
floor is the backstop: Script B passes the pro-rata sUSDS quote less 0.1%, so a pair pre-priced AM-cheap makes tx5
revert `InsufficientSUSDSPaired` instead of leaking the AM. A one-sided griefed pair (dust + `sync`, no LP) still
seeds, because the direct mint pairs all the sUSDS.

**Resume gate (story 124).** If the AM/sUSDS pair already exists, B resumes only when it is the pair B's progress
file recorded, the seed is recorded, and OWNER holds **at least** the recorded `liquidity` of its LP (run-45
recommendation; was "any LP"). Anything else aborts with the R1 message. A dust LP sent to OWNER no longer passes,
and under the freeze nobody can mint one anyway. The recorded figures come from forge's local pass, so they are only
ever compared with chain state. If a legitimate seed landed with slightly less LP than the local pass predicted (the
phUSD/sUSDS pair moved between the local pass and tx5), the resume aborts loudly: investigate the receipts, do not
edit the gate.

**Private RPC: optional, not a safety control.** A private RPC hides only pending transactions. Under `--slow`
tx1-tx4 are mined publicly before the seed, so it does not cover the window. If you still want one, scope it to B's
forge call only - A, the verifiers and the tax ledger keep using `RPC_MAINNET`:

```bash
ANTIMATTER_POOL_RPC_URL=<private RPC URL> npm run sya-antimatter-cutover:broadcast
```

Do **not** override `RPC_MAINNET` itself for this. Note that C's pair precondition reads `getPair` over
`$RPC_MAINNET`; if that node lags B's private-RPC landing, C refuses to run. That is safe: re-run
`npm run uniswap-helper:broadcast`.

1. `npm run antimatter-pool:preview`. B's preview pranks the freeze itself first. Check:
   `GLOBAL_PAUSE|before-freeze|SUCCEEDED`, the three freeze lines (`setPauser(OWNER)`, `unregister`, `pause`),
   `GLOBAL_PAUSE|frozen|SUCCEEDED|registered=26`, `factory.getPair(AM, sUSDS) == 0: OK`,
   `Antimatter.totalSupply() == 0: OK`, the LP slice (10% of UniPoolerV2's LP), the three floors (`minPhUSD`,
   `minSUSDS`, `minSUSDSPaired`), `AM minted == phUSD burned`, `seeder empty, not a minter`, the three restore lines,
   `registrant sweep OK`, `GLOBAL_PAUSE|after-restore|SUCCEEDED|registered=27`, `Transactions this run: 9` (the
   freeze's 3 are the freeze step's, not counted). The preview's seeder address differs from the broadcast's: pranked
   freeze calls do not bump OWNER's nonce, the broadcast freeze does. Optionally also
   `npm run ssv2-freeze-for-cutover:preview` (3 transactions, both probes).
2. Broadcast via the combined key (first step), or `npm run antimatter-pool:broadcast` alone: backup, then the
   freeze step (3 transactions: `setPauser(OWNER)`, `Pauser.unregister`, `pause`; its own tax-ledger record), then
   B (9 transactions: CREATE, `rescueERC20`, `approve`, `setApprovedMinter(true)`, `seed`,
   `setApprovedMinter(false)`, `unpause`, `setPauser(Pauser)`, `Pauser.register`). Then the patcher fills both keys,
   `:verify` runs (it now also requires StableStakerV2 unpaused, `pauser == Pauser`, registered, and every Pauser
   registrant pausable) and the tax ledger records (suggested
   `ANTIMATTER_POOL_LEDGER_NOTE="protocol-owned LP conversion phUSD/sUSDS -> AM/sUSDS"`). Gas price for the freeze
   step: `SSV2_FREEZE_GAS_PRICE_WEI`, default `ANTIMATTER_POOL_GAS_PRICE_WEI`.
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
  `claimEnabled == true`; only after B's restore - it fails while StableStakerV2 is frozen). Note that the freeze
  and restore change the order of `Pauser.getPausableContracts()` (`unregister` swap-and-pops, `register` pushes);
  nothing asserts on that order.
- **phlimbo-ui follow-up (separate story):** `src/lib/contracts.ts` hardcodes `UniswapHelper` and the three zero
  keys (`SYAHarvester`, `AntimatterPoolSeeder`, `AntimatterSusdsPair`). Update it after the broadcasts.
- **Story 119 interaction:** SYA's nudge sink is the old `BatchNFTMinter` `0x0683...15c7`. Every harvest (a SYA
  `claim`) streams its nudge share to that minter through NudgeStreamer. That is harmless before 119; 119 repoints
  SYA's nudge and migrates the old minter's stream buffer. After 119 repoints the sink, the new sink must have a
  registered USDC stream, otherwise every SYA claim - and so every harvest - reverts `NudgeStreamer__NotRegistered`.
- Whichever of 119 and this story broadcasts second re-runs its preview and verifier (both touch UniPoolerV2/SYA).
  Never preview or broadcast 119 while StableStakerV2 is frozen by the freeze step (story 124): run the two
  broadcasts in separate windows.

## If something goes wrong

- **Recovering the combined key.**
  - **The freeze step fails**: B, A and C never ran. If its first transaction landed but not the second, the global
    Pauser is dead until `Pauser.unregister(SSV2)` lands: re-run the combined key promptly (each freeze transaction
    is skipped when done), or the unfreeze key to abandon.
  - **B fails mid-run** (an on-chain revert, gas, a crash): A and C never ran, and B's restore was never sent, so
    StableStakerV2 **stays frozen** - paused, pauser OWNER, unregistered. That is the safe state: the AM source is shut
    and the global Pauser still works for the other registrants. Investigate first (receipts in
    `broadcast/CutoverAntimatterPoolMainnet.s.sol/1/run-latest.json`), fix the cause, then re-run
    `npm run sya-antimatter-cutover:broadcast`: the freeze step is a no-op, B resumes from chain state and ends with
    the restore (`test_fork_BFailsAtTx5_ssv2StaysFrozen_rerunResumesAndRestores` in
    `test/FreezeStableStakerV2ForCutover.fork.t.sol`). Do **not** run the unfreeze key to "finish" a half-done B.
  - **B aborts with `Step 0 (M-02): Antimatter.totalSupply() != 0`**: B sent nothing (txCount 0), StableStakerV2
    stays frozen. Someone obtained AM before the freeze landed (e.g. a staker's `withdraw` + `autoAnnihilate`), so the
    zero-supply precondition cannot be met; it may never be met again. **The human decides** what happens next. To
    end the window, `npm run ssv2-unfreeze-after-cutover-abort:preview` then `:broadcast` (`unpause` ->
    `setPauser(Pauser)` -> `Pauser.register`; it refuses while B's recorded seeder is still an approved AM minter).
    Relaxing the gate or re-planning is a separate decision, not a runbook step.
  - **B aborts with `Step 0: the AM/sUSDS pair ALREADY EXISTS`**: a pair B did not create, or OWNER holds less of
    it than B recorded (a possible resume spoof). Do not re-run; treat the pair as hostile and investigate. If B's
    seeder was granted the minter role, revoke it by hand (`Antimatter.setApprovedMinter(seeder, false)`) and
    `approve(seeder, 0)` the phUSD/sUSDS LP before deciding on the unfreeze key.
  - **tx5 `seed()` reverted `InsufficientSUSDSPaired`** (pps45l2): the pair was pre-priced. The local pass already
    wrote a `completed` progress file that is false. Do not re-run; revoke the seeder's minter role and its LP
    allowance by hand, return the LP slice to UniPoolerV2 if wanted, delete the false progress file, treat the pair
    as hostile and escalate. Under the freeze this needs AM nobody outside the cutover can hold.
  - **A fails**: C did not run. Re-run `npm run sya-antimatter-cutover:broadcast`. B has completed on chain, so the
    freeze step short-circuits (StableStakerV2 is **not** re-frozen) and B sends 0 transactions
    (`test_fork_broadcastMode_progress_rerunIsNoop_verifyPasses` in `test/CutoverAntimatterPoolMainnet.fork.t.sol`)
    and A resumes.
  - **C fails after A has landed**: prefer `npm run uniswap-helper:broadcast` alone. Re-running the combined key
    is also safe - A's re-run after it has fully landed is a no-op too
    (`test_fork_broadcastMode_writesProgress_rerunIsNoop_verifyPasses` in
    `test/DeploySyaHarvesterMainnet.fork.t.sol`: 0 transactions, the recorded harvester is adopted; its patcher
    reports `SAME`; `ledger-record.js` de-duplicates on tx hash) - but it repeats B's and A's simulations for no gain.
  - **C refuses because `$RPC_MAINNET` lags B's private-RPC landing**: wait a block and re-run
    `npm run uniswap-helper:broadcast`.
- **Every script is resumable.** Re-run `:broadcast`; each step is gated on chain state and only the missing ones
  are sent. B's LP slice is fixed at first sizing and read from its progress file, so a resume never re-sizes.
  B's minter revoke and its StableStakerV2 restore run on every run that gets past steps -1 and 0. A run that aborts
  at step -1 or step 0 sends nothing at all, so the revoke does **not** run then (pps45l2): revoke by hand as
  described above.
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
- **Story 124 re-run** (2026-10-31, mainnet block ~26,309,7xx): `ssv2-freeze-for-cutover:preview` exit 0, 3
  transactions, `GLOBAL_PAUSE` before-freeze (27 registrants) and frozen (26) SUCCEEDED. `antimatter-pool:preview`
  exit 0: freeze pranked, `Antimatter.totalSupply() == 0: OK`, same slice and floors as above, AM minted 2,457.70,
  restore + sweep OK, `GLOBAL_PAUSE|after-restore|SUCCEEDED|registered=27`, 9 transactions.
  `ssv2-unfreeze-after-cutover-abort:preview` exit 0 against the live (unfrozen) state: 0 transactions.
- **C** (`uniswap-helper:preview`, exit 1, expected): `precondition: AntimatterSusdsPair is zero in
  mainnet-addresses.ts - run the Antimatter cutover (Script B) first`. The guard is working; C's fork test proves
  B-then-C end to end.
