# Runbook: migrate mainnet from the V1 Pauser to PauserV2 (story 128)

The human runs this. Every broadcast is signed by the owner EOA
`0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6` on the Ledger (hd path `m/44'/60'/46'/0/0`).

Run everything from the phStaging2 root with `source .envrc` loaded (it provides `RPC_MAINNET`
and `ETHERSCAN_API_KEY`).

## What it does

1. Deploys `PauserV2` (lib/pauser, pauser-RM:003). Its EYE token and 1000-EYE burn amount match V1.
2. Rotates each of the 18 LIVE V1 registrants onto PauserV2 and registers it there:
   `setPauser(V2)`, then `V2.register`.
3. Leaves the 9 RETIRED registrants on V1 with no transaction.
4. Repoints the `Pauser` key of `server/deployments/mainnet-addresses.ts` to PauserV2.

The LIVE / RETIRED classification is in `docs/pauser-v2-registrants.md`.

## The window

**The first `setPauser(V2)` bricks the V1 Pauser**: V1's `pause()` reverts as soon as any
registrant stops pointing at it. From that transaction until a contract's own turn comes, the
contracts not yet rotated have **no working emergency stop**. The owner is an EOA, so the
rotation cannot be batched.

The migration therefore runs in value-at-risk order: StableStakerV2, Antimatter, PhlimboV3, the
yield strategies, the minters, the stakers, then the rest. It sends up to 36 transactions in one
`--slow` run.

- Run step 3 in **one continuous session**. Start it when you can watch it to the end.
- If it is interrupted (RPC failure, Ledger timeout, gas), **re-run the same command
  immediately**. Every step is state-gated: a re-run picks up where the chain stands, and a
  completed run sends nothing.

## Steps, in order

### 1. Audit (recommended, the human)

In `~/code/audits`:

- `/update-lib pauser`, then `/full-audit pauser`
- `/audit-script phoenix-phase-2-staging pauser-v2-migrate:broadcast`

This is recommended, not a hard gate in the scripts.

### 2. Deploy PauserV2

```bash
npm run pauser-v2-deploy:preview      # fork; OWNER prank; nothing signed or written
npm run pauser-v2-deploy:broadcast    # Ledger. ONE tx. Optional gas: PAUSER_V2_GAS_PRICE_WEI (default 0.3 gwei)
```

The broadcast:

- backs up the address book;
- deploys PauserV2 and asserts `owner == OWNER`, `eyeToken == EYE` and `eyeBurnAmount == 1000e18`;
- writes `server/deployments/progress.pauser-v2.1.json`;
- records the transaction in the tax ledger.

Re-running it is a no-op. It does **not** touch the address book.

Next, verify the contract on Etherscan:

```bash
forge verify-contract \
  $(node -p "require('./server/deployments/progress.pauser-v2.1.json').contracts.PauserV2.address") \
  lib/pauser/src/PauserV2.sol:PauserV2 --chain 1 --watch \
  --constructor-args $(cast abi-encode 'constructor(address)' 0x155ff1A85F440EE0A382eA949f24CE4E0b751c65)
```

Commit `server/deployments/progress.pauser-v2.1.json`, the broadcast artifacts and
`ledger/transactions.csv`.

### 3. Migrate: one continuous session

```bash
npm run pauser-v2-migrate:preview     # against the deployed PauserV2 (from the progress file)
npm run pauser-v2-migrate:broadcast   # Ledger. Up to 36 txs. Do not walk away.
```

The script reads the PauserV2 address from the env variable `PAUSER_V2` if it is set, and from
the progress file otherwise. Before the deploy has landed, `:preview` rehearses against a
PauserV2 it deploys inside the fork.

The preflight refuses before sending any transaction if:

- V1's registrant set is not the classified 27. This happens, for example, if phStaging2:119
  registered a new minter with V1 first. **Do not work around it.** Re-run
  `npm run pauser-v2-classify`, then update `docs/pauser-v2-registrants.md` and the live and
  retired sets in `script/helpers/PauserV2MainnetBase.sol`.
- StableStakerV2 is not registered with V1.
- Any live registrant's `owner()` is not OWNER, or its `pauser()` is neither V1 nor PauserV2.
- PauserV2 already holds an address outside the live set.

After the run, the script checks these postconditions:

- `V2.health()` reports no `notPauser`, `alreadyPaused` or `unreachable` entries;
- V2's registrants equal the live set;
- no live registrant points at V1;
- no retired registrant is on V2.

`:preview` additionally runs a snapshot-reverted global `pause()` / `unpause()` round trip.

Commit the broadcast artifacts and `ledger/transactions.csv`.

### 4. Patch the address book

```bash
node scripts/patch-mainnet-addresses-pauser-v2.js
```

The script:

- reads PauserV2 from `broadcast/DeployPauserV2Mainnet.s.sol/1/run-latest.json` and requires a
  successful receipt;
- cross-checks it against the progress file;
- backs up the book;
- repoints the `Pauser` key from V1, refusing any other current value;
- leaves a comment recording the retired V1 address.

It adds no keys, and it is idempotent. Commit `server/deployments/mainnet-addresses.ts`.

### 5. Verify

```bash
npm run pauser-v2-verify
```

This is read-only. It requires:

- the book's `Pauser` to equal PauserV2;
- PauserV2's config to match (`owner`, `eyeToken`, `eyeBurnAmount`);
- the same postconditions as step 3.

It names any live registrant that has been re-pointed at V1. Re-run it whenever you want a health
check.

### 6. Then phlimbo-ui:094

That story points the UI's mainnet Pauser address at V2.

## Warnings

- **Never run an old V1 recovery script after the migration.** For example,
  `npm run ssv2-unfreeze-after-cutover-abort:*` (`script/UnfreezeStableStakerV2AfterCutoverAbort.s.sol`)
  does `setPauser(V1 Pauser)` and then `V1.register`. Afterwards that contract would point at the
  dead V1, and **no** emergency stop would cover it. The same goes for any script that hard-codes
  `0x7c5A8EeF1d836450C019FB036453ac6eC97885a3`. `npm run pauser-v2-verify` detects the re-point.
  To repair it: `setPauser(PauserV2)`, then `PauserV2.register` (re-run the migrate key).
- **The future NFTBonfire mainnet cutover must register the bonfire with PauserV2, never V1.** The
  same applies to phStaging2:119's new batch minter: `setPauser(V2)` then `V2.register`, and
  retire the old minter with `V2.unregister`, which is unconditional on V2.
- **Do not register anything with V1 again**, and do not unregister the retired set from V1.
  Unregistering costs transactions and changes nothing, because V1 is dead.
- **Owner actions are now safe for the global pause**: `setPauser(x)` on one registrant, the owner
  pausing PhlimboV3 directly, or the owner unpausing one contract early after a global pause.
  PauserV2 skips those registrants and stops or restarts everything else. The fork test
  `test/MigratePauserV2Mainnet.fork.t.sol` proves each case. Keep the registry to live contracts
  anyway: when a contract is retired, call `PauserV2.unregister`.
