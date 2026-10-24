# Tax ledger (ZAR)

`transactions.csv` is an append-only record of every **mainnet** transaction broadcast from this
repo, priced in South African Rand at block time, for tax purposes. It is written by
`scripts/ledger-record.js` and committed to git. Never edit or delete existing rows by hand.

| Column | Meaning |
|---|---|
| `date_utc` | Block timestamp (ISO 8601, UTC) |
| `sa_tax_year` | SA tax year (1 March – end February), named by the year it ends in |
| `chain_id`, `tx_hash`, `block`, `status` | Transaction identity and outcome (`success` / `reverted`; reverted txs still cost gas) |
| `from`, `to`, `function`, `contract_name` | Sender, target (or created contract), call signature, forge contract name |
| `gas_used`, `gas_price_gwei`, `fee_eth` | Gas paid |
| `value_eth` | Native ETH sent with the call |
| `eth_zar` | ETH/ZAR at block time (CoinGecko 5-minute data, closest point) |
| `fee_zar` | Gas cost in ZAR (always positive) |
| `value_zar` | Native ETH sent, in ZAR |
| `token_flows` | Net ERC-20 movement into (+) or out of (−) the sending wallet, with the ZAR unit price used |
| `token_net_zar` | Signed ZAR sum of `token_flows` |
| `price_status` | `ok`, `missing` (some price unavailable) or `repriced` (a later row superseding a `missing` one) |
| `npm_key` | The npm script that recorded the row |
| `script` | Forge script whose broadcast was recorded |
| `note` | Optional clarifying note |
| `recorded_at` | When the row was written |

## Recording

- Broadcasting npm keys call `node scripts/ledger-record.js <Script.s.sol> 1` as their final step.
  Add a note with `LEDGER_NOTE="why" npm run <key>`.
- Transactions sent outside forge (cast, UI, Etherscan): `npm run ledger:record -- --tx 0x… --note "…"`.
- Rows with `price_status=missing`: `npm run ledger:reprice` appends a superseding `repriced` row.
- Re-running is safe; rows are de-duplicated on `chain_id` + `tx_hash`. Non-mainnet chains are ignored.

Requires `RPC_MAINNET`. `COINGECKO_API_KEY` (demo key) is optional and only helps with rate limits.
phUSD has no CoinGecko price, so it is inferred from the phUSD/sUSDS Uniswap V2 pair
(`PhusdSusdsPair` in `server/deployments/mainnet-addresses.ts`): phUSD/ZAR = (sUSDS reserve /
phUSD reserve) x sUSDS/ZAR. The reserves are read once per recording run, at the block before the
run's first transaction, so the run's own swaps do not move the price it is valued at. Transactions
from before the pair existed (block 26254526, 2026-10-23) cannot be priced this way.

Other tokens CoinGecko does not know are marked `unpriced` and the row is `missing`; add a `note`
with the value you used if you price one yourself.
