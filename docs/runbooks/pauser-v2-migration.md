# Runbook: migrate mainnet from the V1 Pauser to PauserV2 (story 128)

The human runs this. Every broadcast is signed by the owner EOA
`0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6` on the Ledger (hd path `m/44'/60'/46'/0/0`).

Run everything from the phStaging2 root with `source .envrc` loaded (it provides `RPC_MAINNET`
and `ETHERSCAN_API_KEY`).

## What it does

The order is fixed. Two npm keys carry all six steps.

| Step | What | npm key |
|---|---|---|
| 1 | Deploy `PauserV2` (lib/pauser, pauser-RM:003). Its EYE token matches V1 | `pauser-v2-deploy:broadcast` |
| 2 | `config(1_000_000e18, EYE)`: raise the burn so nobody can grief the rotation window | `pauser-v2-deploy:broadcast` |
| 3 | Rotate each of the 18 LIVE V1 registrants onto PauserV2 (`setPauser(V2)`, then `V2.register`). The 9 RETIRED stay on V1 with no transaction | `pauser-v2-migrate:broadcast` |
| 4 | `config(1000e18, EYE)`: restore the burn, once the postconditions pass | `pauser-v2-migrate:broadcast` |
| 5 | Repoint the `Pauser` key of `server/deployments/mainnet-addresses.ts` to PauserV2 | chained in `pauser-v2-migrate:broadcast` |
| 6 | Verify | chained in `pauser-v2-migrate:broadcast` |

The LIVE / RETIRED classification is in `docs/pauser-v2-registrants.md`.

**Why the burn is raised (audit 49 L-02).** At 1000 EYE (about $12) anyone can call
`V2.pause()` mid-window. The paused registrants then make the scripted resume refuse while the
unrotated ones sit on the bricked V1. At 1,000,000 EYE (about 10% of EYE's 9.73M supply) that
griefing is impractical. Nothing can be paused before step 3 either, because an empty PauserV2's
`pause()` reverts. If the migrate script finds a PauserV2 still at 1000 EYE with rotations
outstanding, its first transaction raises the burn. The verifier fails while the burn is still
1M, so a migration that stopped before step 4 cannot pass as finished.

## The window

**The first `setPauser(V2)` bricks the V1 Pauser**: V1's `pause()` reverts as soon as any
registrant stops pointing at it. From that transaction until a contract's own turn comes, the
contracts not yet rotated have **no working emergency stop**. The owner is an EOA, so the
rotation cannot be batched.

The migration therefore runs in value-at-risk order: StableStakerV2, Antimatter, PhlimboV3, the
yield strategies, the minters, the stakers, then the rest. It sends up to 36 rotation transactions (plus the burn raise and restore) in one
`--slow` run.

- Run step 3 in **one continuous session**. Start it when you can watch it to the end.
- If it is interrupted by an RPC failure or a Ledger timeout, **re-run the same command
  immediately**. Every step is state-gated: a re-run picks up where the chain stands, and a
  completed run sends nothing.
- If a transaction is **stuck pending** (gas), the same command cannot replace it. Follow
  [Gas price](#gas-price) below before re-running.

### Gas price

Both broadcast keys send **legacy** transactions at a fixed `PAUSER_V2_GAS_PRICE_WEI`
(default 300000000 wei, 0.3 gwei). A legacy transaction pays that whole price per gas: the base
fee is burned and the rest goes to the validator as a tip. It cannot be included while the base
fee is above it. Both scripts refuse to broadcast unless the price is at least 2x the current
`block.basefee` (audit 49 L-03), so a stall needs the base fee to more than double mid-session.

If a transaction stalls anyway:

1. Compare `cast nonce 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --block pending --rpc-url $RPC_MAINNET`
   with the same command at `--block latest`. A higher pending nonce means a transaction is stuck.
2. Cancel the stuck nonce `N` (the `latest` value) with a zero-value self-send priced at least
   12.5% above the stuck transaction and at least 2x the base fee (`cast base-fee --rpc-url $RPC_MAINNET`):
   ```bash
   cast send 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --value 0 --nonce N --legacy \
     --gas-price <WEI> --ledger --mnemonic-derivation-path "m/44'/60'/46'/0/0" --rpc-url $RPC_MAINNET
   ```
   Do not rely on a forge re-run to replace it: whether forge reuses the stuck nonce or queues
   behind it has not been tested. Record the cancel in the tax ledger with
   `npm run ledger:record -- --tx 0x... --note "PauserV2 stuck-nonce cancel"`.
3. Once `pending` and `latest` nonces agree, re-run the npm key with the higher price, for example
   `PAUSER_V2_GAS_PRICE_WEI=1000000000 npm run pauser-v2-migrate:broadcast`. Every step is
   state-gated, so it picks up from the chain.

## Steps, in order

### Before you start: audit (recommended, the human)

In `~/code/audits`:

- `/update-lib pauser`, then `/full-audit pauser`
- `/audit-script phoenix-phase-2-staging pauser-v2-migrate:broadcast`

This is recommended, not a hard gate in the scripts.

### Steps 1-2: deploy PauserV2 and raise the burn

```bash
npm run pauser-v2-deploy:preview      # fork; OWNER prank; nothing signed or written
npm run pauser-v2-deploy:broadcast    # Ledger. TWO txs (deploy, raise burn). Optional gas: PAUSER_V2_GAS_PRICE_WEI (default 0.3 gwei; see Gas price)
```

The broadcast:

- backs up the address book;
- deploys PauserV2 and asserts `owner == OWNER`, `eyeToken == EYE` and `eyeBurnAmount == 1000e18`;
- calls `config(1_000_000e18, EYE)` and asserts it took (step 2);
- writes `server/deployments/progress.pauser-v2.1.json` as `pending`, with the CREATE nonce;
- runs `scripts/confirm-pauser-v2-progress.js`, which marks the file `completed` only after
  it finds a success receipt and live code at the address;
- records the transaction in the tax ledger.

Re-running it is a no-op, except that it raises the burn if a previous run died between the two
transactions. It does **not** touch the address book. A dry run without the npm key
(no `PAUSER_V2_BROADCAST=true`) never writes the progress file (audit 49 L-06).

If the confirmation exits 5 (no code yet), the CREATE is still pending. Wait for it to mine, or
replace it as described under [Gas price](#gas-price), then run
`node scripts/confirm-pauser-v2-progress.js` on its own. If a re-run of the deploy reports
**NO CODE**, follow its message. It tells you whether OWNER's create nonce is still unconsumed, in
which case you must **not** delete the progress file, or consumed, in which case the deploy never
landed and you delete the file and start again.

Next, verify the contract on Etherscan:

```bash
forge verify-contract \
  $(node -p "require('./server/deployments/progress.pauser-v2.1.json').contracts.PauserV2.address") \
  lib/pauser/src/PauserV2.sol:PauserV2 --chain 1 --watch \
  --constructor-args $(cast abi-encode 'constructor(address)' 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65)
```

Commit `server/deployments/progress.pauser-v2.1.json`, the broadcast artifacts and
`ledger/transactions.csv`.

### Steps 3-6: migrate, restore the burn, patch, verify (one continuous session)

```bash
npm run pauser-v2-migrate:preview     # against the deployed PauserV2 (from the progress file)
npm run pauser-v2-migrate:broadcast   # Ledger. Up to 38 txs. Do not walk away.
```

The script reads PauserV2 from the progress file, which must be `completed`. If the env variable
`PAUSER_V2` is also set, it must name the same address. A stale value refuses instead of rotating
every registrant onto a PauserV2 the address book will never name (audit 49 L-05). `:preview`
accepts `PAUSER_V2` alone. Before the deploy has landed, it rehearses against a PauserV2 it
deploys and raises inside the fork.

The preflight refuses before sending any transaction if:

- V1's registrant set is not the classified 27. This happens, for example, if phStaging2:119
  registered a new minter with V1 first. **Do not work around it.** Re-run
  `npm run pauser-v2-classify`, then update `docs/pauser-v2-registrants.md` and the live and
  retired sets in `script/helpers/PauserV2MainnetBase.sol`.
- StableStakerV2 is not registered with V1.
- Any live registrant's `owner()` is not OWNER, or its `pauser()` is neither V1 nor PauserV2.
- PauserV2 already holds an address outside the live set.

After the rotations, the script checks these postconditions:

- `V2.health()` reports no `notPauser`, `alreadyPaused` or `unreachable` entries;
- V2's registrants equal the 18-address live set;
- no live registrant points at V1;
- no retired registrant is on V2.

Only then does it send `config(1000e18, EYE)` (step 4). `:preview` additionally runs a
snapshot-reverted global `pause()` / `unpause()` round trip at the restored burn.

When forge succeeds, the key continues with two mandatory steps (audit 49 L-04):

- **Step 5:** `node scripts/patch-mainnet-addresses-pauser-v2.js` reads PauserV2 from the deploy
  receipts and cross-checks the progress file. It refuses unless PauserV2 on-chain has
  registrants and a 1000e18 burn, which only a finished migration leaves behind. It then backs
  up the book and repoints the `Pauser` key from V1, refusing any other current value. It is
  idempotent.
- **Step 6:** `npm run pauser-v2-verify` (below).

The tax ledger recorder runs whatever the outcome of steps 5 and 6. If either fails, fix the
cause and run the failing step by hand. Do not re-run the broadcast just to patch.

Commit `server/deployments/mainnet-addresses.ts`, the broadcast artifacts and
`ledger/transactions.csv`.

#### Verify

```bash
npm run pauser-v2-verify
```

This is read-only. It checks invariants against the live chain, not the 18-address snapshot
(audit 49 L-07):

- PauserV2's `owner`, `eyeToken`, and an `eyeBurnAmount` of exactly 1000e18;
- the book's `Pauser` equals PauserV2;
- **V1 has no new registrant.** Its list may only be a subset of the story-128 snapshot of 27.
  Any other address is named: it sits on the dead V1 with no working stop;
- **the live set is on PauserV2.** The live set is the 18 migrated contracts, minus
  `postMigrationRemovals()`, plus `postMigrationAdditions()` from
  `script/helpers/PauserV2Registry.sol`. Every member must be registered with `pauser() == V2`,
  and any member re-pointed at V1 is named;
- **nothing else is on PauserV2.** Any registrant not in the live set is named;
- no retired registrant is on V2, and `health()` is clean.

Re-run it whenever you want a health check. It stays green after a committed registry change.

### Afterwards: phlimbo-ui:094

That story points the UI's mainnet Pauser address at V2.

## Warnings

- **Never run an old V1 recovery script after the migration.** For example,
  `npm run ssv2-unfreeze-after-cutover-abort:*` (`script/UnfreezeStableStakerV2AfterCutoverAbort.s.sol`)
  does `setPauser(V1 Pauser)` and then `V1.register`. Afterwards that contract would point at the
  dead V1, and **no** emergency stop would cover it. The same goes for any script that hard-codes
  `0x7c5A8EeF1d836450C019FB036453ac6eC97885a3`. `npm run pauser-v2-verify` names such a contract
  in both cases: a live-set member re-pointed at V1, and a new contract registered with V1.
  It cannot see a contract that points at V1 but was never registered anywhere.
  To repair it: `setPauser(PauserV2)`, then `PauserV2.register`, and commit the address to
  `postMigrationAdditions()` if it is not one of the 18.
- **The future NFTBonfire mainnet cutover must register the bonfire with PauserV2, never V1.** The
  same applies to phStaging2:119's new batch minter: `setPauser(V2)` then `V2.register`, and
  retire the old minter with `V2.unregister`, which is unconditional on V2. **Every** such
  register or unregister must append the address to `postMigrationAdditions()` or
  `postMigrationRemovals()` in `script/helpers/PauserV2Registry.sol` in the same change, or the
  verifier fails and names it.
- **Do not register anything with V1 again**, and do not unregister the retired set from V1.
  Unregistering costs transactions and changes nothing, because V1 is dead.
- **Owner actions are now safe for the global pause**: `setPauser(x)` on one registrant, the owner
  pausing PhlimboV3 directly, or the owner unpausing one contract early after a global pause.
  PauserV2 skips those registrants and stops or restarts everything else. The fork test
  `test/MigratePauserV2Mainnet.fork.t.sol` proves each case. Keep the registry to live contracts
  anyway: when a contract is retired, call `PauserV2.unregister`.
