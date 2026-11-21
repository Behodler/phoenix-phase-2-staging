# Runbook: AntimatterBooster mainnet cutover, 15% boost (story 139)

Script: `script/DeployAntimatterBoosterMainnet.s.sol` (base `script/helpers/AntimatterBoosterMainnetBase.sol`).
Verifier: `script/VerifyAntimatterBoosterMainnet.s.sol`. Patcher: `scripts/patch-mainnet-addresses-antimatter-booster.js`.
Progress: `server/deployments/progress.antimatter-booster.1.json`.

The story that wrote this never broadcasts. The broadcast is the human's, by hand, from the Ledger.

## Prerequisites

- `lib/antimatter` pinned at `70ea8f3` (antimatter:005, pushed). Build with phStaging2's settings (solc 0.8.30,
  via_ir, optimizer 10000 runs, prague). Runtime is ~8.3 KB, well under EIP-170.
- `RPC_MAINNET` set (`.envrc`). Ledger connected, Ethereum app open, account `m/44'/60'/46'/0/0` =
  OWNER `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`, with ETH for up to 9 admin transactions.
- `server/deployments/mainnet-addresses.ts` still has `AntimatterBooster: "0x000…000"` (the story-138 placeholder) and
  there is no `progress.antimatter-booster.1.json`. (After a partial broadcast both are expected; see *Recovery*.)
- OWNER owns phUSD, Antimatter, the active PhusdStableMinter V2 and PauserV2. Preflight checks all of this and refuses
  otherwise.

## What it does

All from OWNER, each step skipped when the chain already shows it done, each followed by a `require` read-back:

| # | Call | Why it is here |
|---|---|---|
| 0 | `new AntimatterBooster(OWNER, Antimatter, phUSD)` | Inert at deploy: boostBps 0, pauser 0, no stables |
| 1 | `phUSD.setMinter(booster, true)` | The booster mints the bonus. Read back as a live minter at mintVersion 0 |
| 2 | `addTrackedStable` DOLA, USDC, USDe | All three, so the 1/6 POC denominator is right (3 txs) |
| 3 | `booster.setPauser(PauserV2)` | `PauserV2.register` requires `pauser() == PauserV2` |
| 4 | `PauserV2.register(booster)` | Global circuit breaker covers the booster |
| 5 | `booster.setBoostBps(1_500)` | **Fifth**: boosting goes live only once 1-4 exist. Until then `boostedAnnihilate` reverts `BoostDisabled` |
| 6 | `phUSD.setMinter(OWNER, false)` | **Last**: revokes OWNER's phUSD mint right (human request, safety) |

Step 6 is a single-address revoke. The script never calls `phUSD.revokeAllMintPrivileges()`, which would bump the
global mintVersion and invalidate every live minter (the V2 minter, Antimatter, PhlimboV3, StableStakerV2, the
Uniboost / NudgeRatchet / BalancerPooler hooks). Revoking OWNER's *minter* right does not touch OWNER's `onlyOwner`
powers over phUSD, so OWNER can still `setMinter` anything afterwards.

Safety properties enforced in-script:

- **No funds to the Ledger.** OWNER's ETH and the book's Antimatter, PhUSD, USDC, Dola, USDe, SUSDe, USDS, SUSDS and EYE
  balances are snapshotted before the first call. `OwnerBalanceIncreased(token, before, after)` reverts after
  **every** transaction if any rose (ETH must be non-increasing). Nothing mints, rescues or routes anything to OWNER.
- **Minter-set integrity.** `phUSD.authorizedMinters` is snapshotted for every address ever named in a phUSD
  `MinterSet` event (19 addresses, live and revoked), plus `mintVersion`. After wiring exactly two entries may differ:
  the booster (now a live minter) and OWNER (revoked). Anything else reverts `MinterSetChanged` / `MintVersionChanged`.
- **Active minter only.** POC is read from `Antimatter.phUSDMinter()`, which preflight requires to equal the book's
  `PhusdStableMinter` (V2 `0x9485…E60C`). See *V1 minter* below.

## 1. Preview

```bash
npm run antimatter-booster:preview
```

Fork simulation as OWNER: nothing is signed and nothing is written. Check the log for:

- `Preflight OK`, then steps 0-6 in order, each followed by `OWNER balance invariant OK`;
- `Wiring OK: live minter, DOLA/USDC/USDe tracked, PauserV2 registered, 15%, OWNER revoked.`;
- `phUSD minter-set delta OK: booster added, OWNER revoked, all else unchanged, mintVersion 0`;
- `previewBoost USDe ELIGIBLE (1 AM -> base, bonus): 2e18, 3e17`, and DOLA / USDC `AboveThreshold`;
- smoke: `boostedAnnihilate(USDe, 10 AM): base / bonus / received: 20e18 3e18 23e18` (base + 15%);
- the PauserV2 pause round-trip passes (the booster pauses, a boost reverts while paused, recovers after unpause);
- `Transactions sent (or simulated): 9`.

If USDe has drifted out of the 1/6 band the script prints a **WARNING** and skips the smoke instead of reverting.
Eligibility is market state, not a deploy error. The deploy is still correct; boosts become available once USDe
re-enters the band.

## 2. Broadcast

```bash
LEDGER_NOTE="optional note" npm run antimatter-booster:broadcast
```

Chain: back up the book → forge broadcast (legacy txs at `ANTIMATTER_BOOSTER_GAS_PRICE_WEI`, default 0.3 gwei,
refused unless ≥ 2 × basefee; progress written `pending` with the CREATE nonce) → `confirm-antimatter-booster-progress.js`
(`pending` → `completed` from the CREATE receipt + live code) → `patch-mainnet-addresses-antimatter-booster.js`
(FILLs the `AntimatterBooster` zero placeholder, replaces the story-138 comment, appends the booster to
`PauserV2Registry.postMigrationAdditions()`) → `npm run pauser-v2-verify` → `npm run antimatter-booster-verify`. The
tax-ledger recorder runs whatever the tail's outcome, and the tail's exit status is preserved.

**Known pre-existing `pauser-v2-verify` failure (not this story's).** At planning/execution time (block ~26,466,600)
`BatchNFTMinterMultiToken 0x0683…15c7` was still registered on PauserV2 although story 119 committed it to
`postMigrationRemovals()`. While that holds, `pauser-v2-verify` fails naming `0x0683…15c7`, and the `&&` chain stops
before `antimatter-booster-verify`. If you see that (and only that address), the booster cutover itself is fine: run
`npm run antimatter-booster-verify` by hand, and finish the 0x0683 unregister separately.

## 3. Verify

```bash
npm run antimatter-booster-verify
```

Read-only. Asserts code, owner, immutables, live phUSD minter, the three tracked stables, PauserV2 pauser and
registration, not paused, boostBps 1500, **OWNER is not a phUSD minter**, and book == booster; prints `previewBoost`
for each stable. Re-run it any time as a health check.

On Etherscan, check the deploy tx and the 8 wiring txs from OWNER, in order: `setMinter(booster,true)`,
`addTrackedStable` ×3, `setPauser`, `register`, `setBoostBps(1500)`, `setMinter(OWNER,false)`. The last one emits
`MinterSet(OWNER, false, 0)` on phUSD. No token transfer to OWNER appears in any of them.

`npm run stable-staker-v2-cutover:verify` tolerates the OWNER revoke: story 139 amended
`_assertPhusdMinterDelta` in `script/CutoverStableStakerV2Mainnet.s.sol` to accept OWNER's bit (bit 1) being cleared
against the persisted baseline 511 (live mask 510 or 508). Any other change still fails. (That verifier has an
unrelated pre-existing Phase 3b failure on live mainnet since the PauserV2 migration.)

## 4. Commit

Commit the patched `server/deployments/mainnet-addresses.ts`, `script/helpers/PauserV2Registry.sol`,
`server/deployments/progress.antimatter-booster.1.json`, `broadcast/DeployAntimatterBoosterMainnet.s.sol/1/` and
`ledger/transactions.csv`.

**UI address swap is manual.** After the broadcast, swap the mainnet `AntimatterBooster` address into phlimbo-ui
by hand (phlimbo-ui:103 wired the row; mainnet shows a zero address until then).

## Recovery

### Interrupted run (RPC drop, Ledger timeout)

Re-run `npm run antimatter-booster:broadcast`. The booster is adopted from the progress file and only the missing
steps are sent. An interruption at the revoke (steps 1-5 done, OWNER still a minter) resumes with the single
`setMinter(OWNER, false)`. A finished run sends nothing.

### Progress file names a booster with no code

- OWNER's nonce has not passed the recorded `createNonce`: the CREATE may be pending. Wait, or replace that nonce at a
  higher `ANTIMATTER_BOOSTER_GAS_PRICE_WEI`. Do **not** delete the progress file.
- OWNER's nonce has passed it: the CREATE never landed. Delete the progress file and preview again.

### Gas stall

Raise `ANTIMATTER_BOOSTER_GAS_PRICE_WEI` (must be ≥ 2 × basefee) and re-run.

## Rollback

| To undo | Call (OWNER) |
|---|---|
| Stop boosting, keep everything else | `booster.setBoostBps(0)` |
| Emergency stop | `PauserV2.pause()` (burns EYE, pauses every registrant), or the booster alone via its pauser |
| Remove the booster's mint right | `phUSD.setMinter(booster, false)` |
| Re-grant OWNER's phUSD mint right, if a future script ever needs it | `phUSD.setMinter(OWNER, true)` |

`docs/uncommitted/RepoolUniV4.s.sol:291-295` is a fork simulation that already self-grants when it needs to mint, so
the OWNER revoke does not affect it.

## Notes

- **V1 minter.** The legacy PhusdStableMinter V1 `0x435B0A1884bd0fb5667677C9eb0e59425b1477E5` is not in the book. It
  holds ~3,749.62 USDe principal in the shared USDe strategy `0xaC2e…7f95`. The booster reads only the active minter,
  so that USDe is excluded from POC by design (AntimatterBooster NatSpec L28-30). At block ~26,466,600: active-only
  total 29,333.18, threshold 4,888.86, USDe 70.67 (0.24%), so USDe headroom is ≈5,782 USDe through V2. Counting V1,
  headroom would be only ≈2,032. The eligible set is the same either way. The human accepted active-only.
- **USDC is 6dp.** `boostedAnnihilate` needs `amount` to be a multiple of 1e12 for USDC (`AmountNotRepresentable`
  otherwise). USDC is not boost-eligible today anyway.
- **Daily cap.** The active minter caps each stable at 4,000e18 phUSD per day. `previewBoost` reports
  `DailyCapExceeded`. `previewBoost` does not check the booster's phUSD mint right; the verifier's live-minter check
  covers that.
- **Out of scope.** The unidentified paused live minter `0xA06ae98c…2573` and the legacy PhlimboEA `0x3984…19F4` still
  hold phUSD mint rights. This cutover does not touch them, and its integrity check fails if anything else does.
- **Sepolia:** not planned (story 138 left a zero placeholder there).
