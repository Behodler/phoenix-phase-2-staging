# Runbook: NFTBonfire mainnet cutover (story 129)

The human runs this. Every broadcast is signed by the owner EOA
`0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6` on the Ledger (hd path `m/44'/60'/46'/0/0`).

Run everything from the phStaging2 root with `source .envrc` loaded (it provides `RPC_MAINNET`
and `ETHERSCAN_API_KEY`).

> **Never burn or claim from the Ledger account.** No funds may ever enter OWNER: it only pays
> gas. The deploy script enforces this. It snapshots OWNER's balances before its first call and
> reverts `OwnerBalanceIncreased(token, id, before, after)` after its last call if any of them
> rose. The balances covered are ETH (must not increase), Antimatter, phUSD,
> USDC/DOLA/USDe/sUSDe/USDS/sUSDS, EYE and every NFTMinterV2 ERC1155 id. The script never calls
> `antimatter.mint`, and no call names OWNER as a recipient.

## What it does

`NFTBonfire` (lib/yield-claim-nft, pin `c5ad56d`) lets a holder burn one claim NFT for the
antimatter pot. The pot accrues at `ratePerDay`, is capped at `maxPayout`, and resets to zero on
each burn.

| Parameter | Value | Provenance |
|---|---|---|
| `ratePerDay` | `10e18` (10 AM/day) | Human decision 2026-11-05 |
| `maxPayout` | `100e18` (100 AM, 10 days of accrual) | Human decision 2026-11-05. Audit L-29 suggested 10-20 AM; kept at 100 AM because the top NFT is ~$70. Lower it later (see *Operating rules*) if burn-profit premiums are excessive |
| owner | OWNER EOA | Owns NFTMinterV2, Antimatter and PauserV2. No ownership handoff |

One npm key runs everything, in the order audit run 23 (L-29 / Q-27) mandates:

| Step | What |
|---|---|
| 1 | Deploy `NFTBonfire(OWNER, NFTMinterV2, Antimatter)`. It deploys inert: rate 0, cap 0, pauser 0 |
| 2 | `NFTMinterV2.setAuthorizedBurner(bonfire, true)` |
| 3 | `Antimatter.setApprovedMinter(bonfire, true)`, read back (the setter is a silent no-op on an unchanged value) |
| 4 | `bonfire.setPauser(PauserV2)`, then `PauserV2.register(bonfire)` |
| 5 | `setMaxPayout(100e18)`. The cap goes on **before** any non-zero rate |
| 6 | `setRatePerDay(10e18)` **last**. This is the call that enables burning |
| 7 | Confirm the progress file (`pending` -> `completed`) |
| 8 | Fill the `NFTBonfire` ZERO placeholder in `server/deployments/mainnet-addresses.ts`, and append the bonfire to `postMigrationAdditions()` in `script/helpers/PauserV2Registry.sol` |
| 9 | `npm run pauser-v2-verify`, then `npm run nft-bonfire-verify` |
| 10 | Record the transactions in the tax ledger |

Steps 1-6 are up to 7 OWNER transactions. Steps 7-10 are chained in the broadcast key.

## 1. Preview

```bash
npm run nft-bonfire:preview
```

It runs on a mainnet fork as an OWNER prank. Nothing is signed and nothing is written. The
preview also runs a snapshot-reverted smoke test:

- it probes the live NFTMinterV2 `authorizedBurners` and Antimatter `isApprovedMinter` getters;
- a real third-party NFT holder (pranked, never OWNER) burns after 1 day and gets exactly 10 AM;
- after 30 more days the burn is capped at 100 AM;
- a global `PauserV2.pause()` pauses every registrant, including the bonfire. A burn reverts
  while paused, and `PauserV2.unpause()` restores everything and burning works again;
- the OWNER balance invariant is checked over the whole preview.

Expect `Transactions sent (or simulated): 7` and every step logged. Re-run the preview right before
broadcasting.

## 2. Broadcast

```bash
NFT_BONFIRE_GAS_PRICE_WEI=<wei> npm run nft-bonfire:broadcast
```

- `NFT_BONFIRE_GAS_PRICE_WEI` defaults to 300000000 (0.3 gwei). The txs are legacy and pay the
  full price. The script refuses to broadcast unless the price is at least 2x the current
  `block.basefee`.
- `LEDGER_NOTE` is optional. The default note is "admin txs, gas only".
- The deploy writes `server/deployments/progress.nft-bonfire.1.json` as `pending`, with the CREATE
  nonce, in forge's local pass. `scripts/confirm-nft-bonfire-progress.js` flips it to `completed`
  once it has a success receipt and live code.
- The patcher refuses unless the progress is `completed` and the bonfire is fully wired on-chain
  (rate 10e18, registered with PauserV2). It fills only the ZERO placeholder: the same address is a
  no-op and any other address refuses. It also refuses if the receipts and the progress file
  disagree.
- The ledger recorder runs even if the tail fails, and the key exits with the tail's status.

## 3. Verify

Both verifiers run at the end of the broadcast key. Re-run them any time:

```bash
npm run pauser-v2-verify     # the bonfire must be in PauserV2Registry.postMigrationAdditions()
npm run nft-bonfire-verify   # owner, immutables, rate, cap, pauser, registration, grants, book
```

Optionally run `npm run nft-bonfire:etherscan` for Etherscan source verification. It is not
chained, and a failure blocks nothing.

## 4. Commit

Commit these in phase-2-staging:

- `server/deployments/mainnet-addresses.ts` (patched) and its backup
- `script/helpers/PauserV2Registry.sol` (patched)
- `server/deployments/progress.nft-bonfire.1.json`
- `broadcast/DeployNFTBonfireMainnet.s.sol/1/`
- `ledger/transactions.csv`

## Recovery

### Interrupted run (RPC drop, Ledger timeout)

Re-run `npm run nft-bonfire:broadcast`. Every step is state-gated. A re-run adopts the bonfire
from the progress file and sends only the missing steps, and a finished run sends nothing. The
confirm step accepts a resume run with no CREATE in its `run-latest.json`. In that case it
confirms from live code at the recorded address.

### Gas stall

A legacy tx cannot be included while the base fee is above its price, and re-running at the same
price cannot replace it.

1. Compare `cast nonce 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 --block pending --rpc-url $RPC_MAINNET`
   with `--block latest`. A difference means a tx is stuck.
2. Ctrl+C the forge run.
3. Replace the stuck nonce with a zero-value self-send at a higher price (Ledger), or wait for it
   to mine.
4. Re-run the broadcast with a higher `NFT_BONFIRE_GAS_PRICE_WEI`. It resumes from chain state.

If the CREATE itself is stuck, the progress file names a bonfire with no code. The script then
refuses to redeploy while OWNER has not consumed the recorded create nonce: it is pending, so wait
or replace it. If the nonce was consumed by something else (for example a cancel), the deploy
never landed. The script then tells you to delete the progress file and re-run the preview.

### Refusal: rate non-zero with the cap unset

The script will not set a cap while burns are live with an unlimited cap. Stop burns first with
`setRatePerDay(0)` as OWNER, then re-run.

## Operating rules

- **Never change `maxPayout` while burns are live.** First stop burns, either with
  `setRatePerDay(0)` (one owner tx, keeps the pot, no pauser needed) or a PauserV2 pause. Then call
  `setMaxPayout`, then restore the rate or unpause.
- **Set a cap before any planned pause.**
- **Pausing NFTMinterV2 does NOT stop bonfire burns** (story 125 Concern 5).
  `setRatePerDay(0)` is the one-tx stop.
- **The bonfire must not be left paused**, or the `health()` check in `pauser-v2-verify` fails.
- **Any future PauserV2 register/unregister must update `script/helpers/PauserV2Registry.sol`**
  (append only), or `pauser-v2-verify` fails and names the address.
- **Never burn or claim from the Ledger account.** No funds may ever enter OWNER; it only pays gas.
- **Analytics.** Median burn profit is the `Burned(burner, tokenId, payout)` payout times the AM
  price, compared against the NFT price at the burn block. Key the comparison by `tokenId` (the
  ERC1155 id is the NFT type). The NFT price comes from the minter's price history off-chain.

## Overlap with phStaging2:119

119 touches the same files: `mainnet-addresses.ts`, `package.json` and `PauserV2Registry.sol`.
Whichever lands second rebases and keeps both registry entries; the patcher appends and never
drops an existing entry. Broadcast the two in separate windows, and re-run the second one's
preview and verifier.
