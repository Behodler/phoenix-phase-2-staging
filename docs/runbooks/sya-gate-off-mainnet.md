# Runbook: gate-free SYA replacement + SYAHarvester redeploy (story 131)

The human runs this. Every broadcast is signed by the owner EOA
`0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6` on the Ledger (hd path `m/44'/60'/46'/0/0`).

Run everything from the phStaging2 root with `source .envrc` loaded (it provides `RPC_MAINNET`
and `ETHERSCAN_API_KEY`).

> **Never claim or harvest from the Ledger account.** No funds may ever enter OWNER: it only pays
> gas. The script enforces this. It snapshots OWNER's balances before its first call and reverts
> `OwnerBalanceIncreased(token, id, before, after)` after its last call if any rose: ETH (must not
> increase), Antimatter, phUSD, USDC/DOLA/USDe/sUSDe/USDS/sUSDS, EYE and every NFTMinterV2 id. No
> call names OWNER as a claimer, harvest caller or recipient. OWNER's USDC (0.410905 at the time of
> writing) must stay exactly that.

## What it does

The live StableYieldAccumulator `0x0cD353bfda674D04823B2826ffafB83B560D21B6` is not upgradeable
and its NFT claim gate is hard-coded. This replaces it with a new SYA built from the
`lib/stable-yield-accumulator` pin `105f22b` (yield-accumulator:029, which includes 028), then
redeploys SYAHarvester, whose `sya` is immutable (old harvester
`0xeE426A950Cb17D559F6391ef0D140715CD46703B`).

| Parameter | Value | Provenance |
|---|---|---|
| `nftMinter` | ZERO (claim gate OFF) | The point of the story (yield-accumulator:028) |
| discount | 100 bps (1%) | Human decision 2026-11-06 (the old SYA runs 3000) |
| token configs | USDC 6, DOLA 18, USDe 18, each rate `1e18` | **Hard-coded** (human decision 2026-11-07). Each is checked against the token's on-chain `decimals()` |
| rewardToken, phlimbo, nudge, nudgeSplit, nudgeStreamer, strategy list | Mirrored **live** from the old SYA | So a phStaging2:119 nudge repoint is honoured **only if 119 broadcasts before this script**. If this script goes first, 119 must repoint the NEW SYA (see *Overlap with phStaging2:119 and 129*) |
| pauser | PauserV2 `0x669E…a154` | Live since 2026-11-05. The V1 Pauser `0x7c5A…85a3` is never called |
| owner | OWNER | `Ownable(msg.sender)`; the Ledger sender is OWNER |

One npm key runs everything. Each step is state-gated against the values this script wants (the
old SYA's wiring, discount 100) and read back with a `require`:

| Step | What |
|---|---|
| 1 | Preflight: old SYA `owner() == OWNER`; wiring and strategy list read live; on-chain decimals check; token set check (exactly 3 strategies, mapping to USDC, DOLA and USDe one each, each equal to its book key); Curve route payload check and bidirectional dry run. Nothing is sent before all of this passes |
| 2 | Deploy the new SYA (or adopt it from the progress file) |
| 3 | `setTokenConfig` x3 **first** (029 makes `setRewardToken` / `addYieldStrategy` revert `TokenNotConfigured` otherwise) → `setRewardToken(USDC)` (before the nudge setters) → `setPhlimbo` + `approvePhlimbo(max)` → `setNudgeAddress` / `setNudgeSplit` / `setNudgeStreamer` → `addYieldStrategy` x3 → `setDiscountRate(100)` → `nftMinter` asserted zero → `setPauser(PauserV2)` → `PauserV2.register` |
| 4 | `setWithdrawer(newSYA, true)` on the three strategies (`setAsideBuffer` untouched) |
| 5 | Retire the old SYA: `PauserV2.unregister` **first**, `setPauser(OWNER)`, `setWithdrawer(old, false)` x3, `removeYieldStrategy` x3, `NFTMinterV2.setAuthorizedBurner(old, false)`, `approvePhlimbo(0)`. **Not paused** |
| 6 | `SYAHarvester(OWNER, PoolManager, newSYA, Router NG)`, story 122's USDe and DOLA routes, ETH/USDC pool (fee 3000, tickSpacing 60, no hooks) |
| 7 | Postconditions, then (chained) confirm progress, patch book + `PauserV2Registry`, `sya-gate-off-verify`, `pauser-v2-verify`, ledger |

A first run is 33 OWNER transactions. A re-run of an interrupted run sends only what is missing.
That holds only while nothing has touched the new SYA since this script deployed it. The wiring
targets are the old SYA's frozen values and the discount target is 100, so after any retune of the
new SYA a re-run sends setters that roll the retune back.

> **After completion: never re-run the broadcast.** Once `progress.sya-gate-off.1.json` reads
> `completed`, never run `sya-gate-off:broadcast` again. If the new SYA has since been retuned (a
> phStaging2:119 nudge repoint, a discount change), a re-run rolls the nudge (20% of each claim
> payment) back to the retired sink `0x068395556b8c43eDf257DC54D109EA5910aE15c7` and resets the
> discount to 100 bps. Its output still says `Postconditions OK`. To see what a re-run would send,
> run `npm run sya-gate-off:preview` and read the planned tx list. After completion, any planned
> step-3 setter (`setNudgeAddress`, `setNudgeSplit`, `setNudgeStreamer`, `setPhlimbo`,
> `setDiscountRate`) is a rollback, not a repair.

## 1. Preview

```bash
npm run sya-gate-off:preview
```

It runs on a mainnet fork as an OWNER prank. Nothing is signed and nothing is written. The
preview also runs these snapshot-reverted smokes:

- a non-NFT-holding EOA calls `claim(0, 0, [])` on the new SYA. It must pay exactly
  yield × 99% (the 1% discount), with Phlimbo receiving the payment minus the 20% nudge share;
- a non-OWNER caller runs `harvest([], 0, 1)` through the new harvester. It must be paid ETH, and no
  NFT moves;
- a residual claim on the old SYA reverts (see *Old SYA after the cutover*);
- a global `PauserV2.pause()` pauses every registrant, including the new SYA (a claim reverts),
  and `unpause()` restores everything;
- the OWNER balance invariant is checked throughout.

The smokes warp only one hour. YieldStrategyUSDC values autoUSD through a Chainlink-backed oracle
with a staleness check, so a multi-day warp would revert every claim on a stale feed (custom error
`0x8d54ba1f`). That would be a fork artefact, not a cutover fault.

Expect `Transactions sent (or simulated): 33` and `Postconditions OK`. Re-run the preview right
before broadcasting.

## 2. Broadcast

```bash
SYA_GATE_OFF_GAS_PRICE_WEI=<wei> npm run sya-gate-off:broadcast
```

- `SYA_GATE_OFF_GAS_PRICE_WEI` defaults to 300000000 (0.3 gwei). The txs are legacy and pay the
  full price. The script refuses before its first tx unless the price is at least 2x the current
  `block.basefee`.
- `LEDGER_NOTE` is optional. The default note is "admin txs, gas only".
- In forge's local pass the script writes `server/deployments/progress.sya-gate-off.1.json` as
  `pending`, with each CREATE nonce. `scripts/confirm-sya-gate-off-progress.js` flips it to
  `completed` once it has success receipts and live code for both the new SYA and the harvester.
- `scripts/patch-mainnet-addresses-sya-gate-off.js` refuses unless the progress is `completed` and
  the cutover has finished on-chain: new SYA registered, old SYA unregistered and stripped, and
  `harvester.sya() == newSYA`. It repoints `StableYieldAccumulator` and `SYAHarvester` only when
  the current value is exactly the old address. If the new address is already there it does
  nothing; any other value refuses. It appends the new SYA to `postMigrationAdditions()` and the old
  SYA to `postMigrationRemovals()` in `script/helpers/PauserV2Registry.sol`, keeping every
  existing entry, including 129's NFTBonfire. The harvester is not a PauserV2 registrant.
- The ledger recorder runs even if the tail fails, and the key exits with the tail's status. It
  does **not** run if forge itself exits non-zero (Ctrl+C, RPC drop, Ledger timeout, revert). The
  `&&` chain stops there, so any transactions that did mine are not in the tax ledger. Record them
  by hand before any re-run: see *Recording a partial run in the ledger* under Recovery.

## 3. Verify

Both verifiers run at the end of the broadcast key. They can be re-run later, with one limit:

```bash
npm run sya-gate-off-verify   # new SYA wiring, token configs, gate off, 1%, PauserV2; old SYA retired; harvester; book
npm run pauser-v2-verify      # registry invariant: new SYA added, old SYA removed, health() clean
```

`sya-gate-off-verify` asserts the new SYA's nudge, nudgeSplit, nudgeStreamer and phlimbo equal the
old SYA's frozen values, and that the discount is 100. It is a valid health check only until the
first post-cutover retune of the new SYA (a phStaging2:119 nudge repoint, a discount change).
After that it fails permanently by design: do not "fix" that failure by re-running the broadcast
(see *After completion: never re-run the broadcast*). Once 119 has broadcast, use 119's own
`nudge-discount:verify` as the health check instead. `pauser-v2-verify` is unaffected by a retune
and stays valid.

Optionally run `npm run sya-gate-off:etherscan-sya` and `npm run sya-gate-off:etherscan-harvester`
for Etherscan source verification. They are not chained, and a failure blocks nothing.

## 4. Commit

Commit these in phase-2-staging:

- `server/deployments/mainnet-addresses.ts` (patched) and its backup
- `script/helpers/PauserV2Registry.sol` (patched)
- `server/deployments/progress.sya-gate-off.1.json`
- `broadcast/ReplaceSYAGateOffMainnet.s.sol/1/`
- `ledger/transactions.csv`

## Consequences

- **Claims become a permissionless race for the 1% spread.** Anyone can claim, with no NFT. The
  claimer pays 99% of the skimmed yield in USDC, and the protocol keeps 1% less than it did at 30%.
- **Harvesters only need to cover gas, swap costs and the borrow buffer.** At 1% the margin on a
  small pot is thin. The preview harvest of about $4 of yield paid about 0.000016 ETH at zero gas
  price, so a real harvest is only profitable once yield has accumulated.
- **Claim NFTs lose their SYA utility.** The new SYA never reads or burns them. NFTBonfire
  (story 129) is their remaining burn sink.
- **Yield never sits in the SYA.** `claim()` skims straight from the strategies to the claimer.
  Pending yield follows the withdrawer rights, so nothing is stranded.

## Old SYA after the cutover

The old SYA is left unpaused, with no strategies, no withdrawer rights, no NFT burner right, a
zero Phlimbo allowance and `pauser() == OWNER`. It is unregistered from PauserV2 (CLAUDE.md
*Deregister Retired Contracts*). It stays in the frozen V1 snapshot (`liveRegistrants()[17]` in
`PauserV2MainnetBase.sol`) and is listed in `postMigrationRemovals()`.

A residual claim reverts. Because the old SYA still gates on the NFT before its strategy loop, a
holder's claim reverts in the burn (`NFTMinterV2: caller is not authorized burner`), and a
non-holder's reverts `Invalid index` (index 0) or `NoValidNFT`. It never reaches `ZeroAmount`, and no NFT is consumed.

## Historical scripts that now report failures by design

- `npm run sya-harvester:verify` (`VerifySyaHarvester`, story 122) reads
  `progress.sya-harvester.1.json` (the old harvester) and the book (now the new one), so it fails
  on "progress file and mainnet-addresses.ts name different harvesters". Use
  `sya-gate-off-verify` instead.
- `VerifyStableStakerV2Cutover` (L250, L387-389) and `CutoverStableStakerV2Mainnet` (L258) hard-code
  the old SYA. Their old-SYA checks report as failed after this cutover. That is by design: they
  are records of a finished cutover and are not rewritten.

## Recovery

### Recording a partial run in the ledger

When forge exits non-zero the broadcast key never reaches its ledger step. Do this **before** any
re-run, because the re-run overwrites `broadcast/ReplaceSYAGateOffMainnet.s.sol/1/run-latest.json`:

1. Record what the interrupted run mined from its receipts:
   ```bash
   npm run ledger:record -- ReplaceSYAGateOffMainnet.s.sol 1 --note "sya-gate-off partial run"
   ```
2. Record anything that step missed (for example, receipts not flushed on Ctrl+C) and any
   transaction sent outside forge, one `--tx` per hash:
   ```bash
   npm run ledger:record -- --tx 0x<hash> --note "sya-gate-off partial run"
   ```
   Hashes are in the timestamped `broadcast/ReplaceSYAGateOffMainnet.s.sol/1/run-<ts>.json` files,
   which a re-run does not overwrite, or on Etherscan in OWNER
   `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`'s nonce range for the run.

Re-recording is safe: rows are de-duplicated on (chain id, tx hash).

### Interrupted run (RPC drop, Ledger timeout)

1. Record what mined: *Recording a partial run in the ledger*, above.
2. Make sure nothing has retuned the new SYA since the interruption. In particular, do not
   broadcast phStaging2:119 or change the discount between the interruption and the resume. The
   resume would roll that change back (see *After completion: never re-run the broadcast*).
3. Run `npm run sya-gate-off:preview` and check that its planned txs are only the missing steps.
4. Re-run `npm run sya-gate-off:broadcast`.

Every step is state-gated. A re-run adopts the new SYA and harvester from the progress file and
is designed to send only what is missing, but a resume is not guaranteed to succeed from every
interruption point. If the preview refuses, stop and investigate before sending anything. Once the old SYA's strategy
list has been stripped, the re-run takes the strategy list from the adopted new SYA. It requires
that SYA to hold all three strategies, and every strategy still on the old SYA to be among them.
The confirm step accepts a resume run with no CREATE in its `run-latest.json`. In that case it
confirms from live code at the recorded addresses.

### Gas stall

1. Compare `cast nonce 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --block pending --rpc-url $RPC_MAINNET`
   with `--block latest`. A difference means a tx is stuck.
2. Ctrl+C the forge run.
3. Record what mined: *Recording a partial run in the ledger*, above.
4. Replace the stuck nonce with a zero-value self-send at a higher price (Ledger), or wait for it
   to mine. Record a cancel self-send in the ledger:
   `npm run ledger:record -- --tx 0x<hash> --note "sya-gate-off stuck-nonce cancel"`.
5. Re-run the broadcast with a higher `SYA_GATE_OFF_GAS_PRICE_WEI`. It resumes from chain state,
   under the same conditions as *Interrupted run* (no retune in between; preview first).

If a CREATE is stuck, the progress file names a contract with no code. The script refuses to
redeploy while OWNER has not consumed the recorded create nonce: the CREATE is pending, so wait or
replace it. If something else consumed the nonce (a cancel, for example), the deploy never landed.
The script then tells you to remove that entry from the progress file and re-run the preview.

### Brief dual-SYA window

Between step 4 (new withdrawer granted) and step 5 (old withdrawer revoked), both SYAs could
claim. That is harmless: each pays Phlimbo at its own discount, and neither holds funds.

## Follow-ups (not this story)

- **phlimbo-ui**: swap the mainnet SYA and SYAHarvester addresses (`src/lib/contracts.ts` L28,
  L118). This depends on the broadcast.
- **sya-harvester**: NatSpec refresh and a fork assertion against the gate-free SYA.

## Overlap with phStaging2:119 and 129

119 and 129 touch the same files: `mainnet-addresses.ts`, `package.json` and
`PauserV2Registry.sol`. Whichever lands second rebases and keeps every registry entry; the
patchers append and never drop an existing entry. Broadcast each in its own window.

- **Preferred order: 129 and 119 first, then this script.** This script reads the old SYA's
  wiring live, so it mirrors the nudge that 119 set on the old SYA.
- **If this script broadcasts first**, 119 must target the NEW SYA. It resolves the SYA from the
  address book, which this script's patcher has already repointed. Once 119 has broadcast, this
  script's broadcast and `sya-gate-off-verify` are retired. The verifier fails permanently by
  design, because the new SYA's nudge no longer equals the old SYA's. Use 119's own verifier
  (`nudge-discount:verify`) as the health check from then on, and never re-run
  `sya-gate-off:broadcast` (see *After completion: never re-run the broadcast*).
- Whichever goes second, run **that script's own** preview before and verifier after its
  broadcast. Never re-run the earlier script's preview, broadcast or verifier to "check" the
  later one.
