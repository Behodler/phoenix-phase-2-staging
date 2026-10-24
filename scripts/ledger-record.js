#!/usr/bin/env node
/**
 * ledger-record.js — tax ledger recorder (ZAR).
 *
 * Appends every broadcast transaction to ledger/transactions.csv with its
 * timestamp, gas fee, native ETH value and wallet token flows, each priced in
 * South African Rand at the transaction's block time. fee_zar is a cost
 * (always positive); token_net_zar is signed (+ into the sender, - out of it) (CoinGecko 5-minute
 * market_chart/range, closest point). Rows are de-duplicated on
 * (chain_id, tx_hash), so re-running after a `--resume` or re-recording the
 * same run-latest.json is safe.
 *
 * Usage (run as the final step of a broadcasting npm key):
 *   node scripts/ledger-record.js <Script.s.sol> [chainId]      # reads broadcast/<Script.s.sol>/<chainId>/run-latest.json
 *   node scripts/ledger-record.js --tx <hash> [--tx <hash> ...] # cast send / UI / manual transactions
 *   options: --note "text"   (or env LEDGER_NOTE)  optional clarifying note
 *            --chain <id>    chain for --tx mode (default 1)
 *
 * Only mainnet (chainId 1) is recorded; other chains are a no-op so the same
 * step can sit in Sepolia/anvil keys without polluting the tax ledger.
 * The npm key that ran the step is captured from npm_lifecycle_event.
 *
 * The ledger is append-only: rows are never edited, reordered or deleted.
 * Never fails the calling npm chain after a successful broadcast: if pricing
 * fails, the row is still written with price_status=missing and the ZAR
 * columns blank; `npm run ledger:reprice` appends a superseding
 * price_status=repriced row rather than editing the original.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const LEDGER_DIR = process.env.LEDGER_DIR || path.join(ROOT, 'ledger'); // override only for testing
const LEDGER_FILE = path.join(LEDGER_DIR, 'transactions.csv');
const RECORDED_CHAINS = new Set([1]);
const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const CG = 'https://api.coingecko.com/api/v3';

const COLUMNS = [
  'date_utc', 'sa_tax_year', 'chain_id', 'tx_hash', 'block', 'status', 'from', 'to',
  'function', 'contract_name', 'gas_used', 'gas_price_gwei', 'fee_eth', 'value_eth',
  'eth_zar', 'fee_zar', 'value_zar', 'token_flows', 'token_net_zar',
  'price_status', 'npm_key', 'script', 'note', 'recorded_at',
];

// ---------- csv ----------

function csvEscape(v) {
  const s = v === undefined || v === null ? '' : String(v);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function parseCsv(text) {
  const rows = [];
  let row = [], field = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') q = false;
      else field += c;
    } else if (c === '"') q = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c !== '\r') field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows;
}

function readLedger() {
  if (!fs.existsSync(LEDGER_FILE)) return [];
  const [header, ...rows] = parseCsv(fs.readFileSync(LEDGER_FILE, 'utf8'));
  if (!header || header.join(',') !== COLUMNS.join(',')) {
    throw new Error(`${LEDGER_FILE} header does not match the expected columns; refusing to write`);
  }
  return rows.filter((r) => r.length > 1).map((r) => Object.fromEntries(COLUMNS.map((c, i) => [c, r[i] ?? ''])));
}

// Append-only: existing rows are never rewritten, reordered or deleted.
function appendLedger(rows) {
  if (!rows.length) return;
  fs.mkdirSync(LEDGER_DIR, { recursive: true });
  if (!fs.existsSync(LEDGER_FILE)) fs.writeFileSync(LEDGER_FILE, COLUMNS.join(',') + '\n');
  fs.appendFileSync(LEDGER_FILE, rows.map((e) => COLUMNS.map((c) => csvEscape(e[c])).join(',')).join('\n') + '\n');
}

// ---------- rpc ----------

function rpcUrl(chainId) {
  const url = chainId === 1 ? process.env.RPC_MAINNET : process.env.RPC_SEPOLIA;
  if (!url) throw new Error(`RPC URL for chain ${chainId} not set (RPC_MAINNET / RPC_SEPOLIA)`);
  return url;
}

async function rpc(chainId, method, params) {
  const res = await fetch(rpcUrl(chainId), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

const blockTimeCache = new Map();
async function blockTimestamp(chainId, blockHex) {
  if (!blockTimeCache.has(blockHex)) {
    const b = await rpc(chainId, 'eth_getBlockByNumber', [blockHex, false]);
    blockTimeCache.set(blockHex, Number(BigInt(b.timestamp)));
  }
  return blockTimeCache.get(blockHex);
}

function decodeString(hex) {
  if (!hex || hex === '0x') return '';
  const data = hex.slice(2);
  if (data.length === 64) return Buffer.from(data, 'hex').toString('utf8').replace(/\0+$/, ''); // bytes32 symbol
  const len = Number(BigInt('0x' + data.slice(64, 128)));
  return Buffer.from(data.slice(128, 128 + len * 2), 'hex').toString('utf8');
}

const tokenMetaCache = new Map();
async function tokenMeta(chainId, token) {
  if (!tokenMetaCache.has(token)) {
    let symbol = token, decimals = 18;
    try { symbol = decodeString(await rpc(chainId, 'eth_call', [{ to: token, data: '0x95d89b41' }, 'latest'])) || token; } catch {}
    try { decimals = Number(BigInt(await rpc(chainId, 'eth_call', [{ to: token, data: '0x313ce567' }, 'latest']))); } catch {}
    tokenMetaCache.set(token, { symbol, decimals });
  }
  return tokenMetaCache.get(token);
}

// ---------- pricing (ZAR) ----------

async function cgClosestPrice(pathPart, ts) {
  const url = `${CG}/${pathPart}/market_chart/range?vs_currency=zar&from=${ts - 3600}&to=${ts + 3600}`;
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch(url, { headers: process.env.COINGECKO_API_KEY ? { 'x-cg-demo-api-key': process.env.COINGECKO_API_KEY } : {} });
    if (res.status === 429) { await new Promise((r) => setTimeout(r, 15000 * (attempt + 1))); continue; }
    if (!res.ok) return null;
    const { prices } = await res.json();
    if (!prices || !prices.length) return null;
    let best = prices[0];
    for (const p of prices) if (Math.abs(p[0] / 1000 - ts) < Math.abs(best[0] / 1000 - ts)) best = p;
    return best[1];
  }
  return null;
}

// phUSD has no CoinGecko price. It is inferred from the phUSD/sUSDS Uniswap V2
// pair: (sUSDS reserve / phUSD reserve) x sUSDS/ZAR. The ratio is read ONCE per
// recording run, at the block before the run's first transaction, so the
// run's own swaps/pools do not move the price it is valued at. Addresses come
// from the live server/deployments/mainnet-addresses.ts (PhUSD, SUSDS,
// PhusdSusdsPair), so a pair replacement is picked up automatically.
const ADDRESSES_TS = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
let phusdPoolBlock = 'latest'; // set by main()/reprice() before rows are built

function mainnetAddress(name) {
  const m = fs.readFileSync(ADDRESSES_TS, 'utf8').match(new RegExp(`^\\s*${name}:\\s*"(0x[0-9a-fA-F]{40})"`, 'm'));
  return m ? m[1].toLowerCase() : null;
}
const PHUSD = mainnetAddress('PhUSD');
const SUSDS = mainnetAddress('SUSDS');
const PHUSD_PAIR = mainnetAddress('PhusdSusdsPair');

const ratioCache = new Map();
async function phusdPerSusdsRatio(block) {
  if (!ratioCache.has(block)) {
    let ratio = null;
    try {
      const t0 = await rpc(1, 'eth_call', [{ to: PHUSD_PAIR, data: '0x0dfe1681' }, block]);
      if (!t0 || t0 === '0x') throw new Error('pair did not exist yet at this block');
      const token0 = '0x' + t0.slice(26);
      const r = (await rpc(1, 'eth_call', [{ to: PHUSD_PAIR, data: '0x0902f1ac' }, block])).slice(2);
      const r0 = BigInt('0x' + r.slice(0, 64));
      const r1 = BigInt('0x' + r.slice(64, 128));
      const [susdsRes, phusdRes] = token0.toLowerCase() === SUSDS ? [r0, r1] : [r1, r0];
      // Both tokens are 18 decimals; scale to keep precision through Number().
      if (phusdRes > 0n) ratio = Number((susdsRes * 10n ** 18n) / phusdRes) / 1e18;
      console.log(`ledger: phUSD priced from pair ${PHUSD_PAIR} at block ${block === 'latest' ? 'latest' : Number(BigInt(block))}: 1 phUSD = ${ratio} sUSDS`);
    } catch (err) {
      console.warn(`ledger: phUSD pool price unavailable at ${block} (${err.message})`);
    }
    ratioCache.set(block, ratio);
  }
  return ratioCache.get(block);
}

async function inferPhusdZar(ts) {
  if (!PHUSD_PAIR || !SUSDS) return null;
  const ratio = await phusdPerSusdsRatio(phusdPoolBlock);
  const susdsZar = ratio === null ? null : await priceZar(SUSDS, ts);
  return susdsZar === null ? null : ratio * susdsZar;
}

const priceCache = new Map();
async function priceZar(asset, ts) {
  // Bucket to 5 minutes, matching CoinGecko's granularity, to avoid re-fetching per tx.
  const key = `${asset}:${Math.round(ts / 300)}${asset === PHUSD ? `:${phusdPoolBlock}` : ''}`;
  if (!priceCache.has(key)) {
    const p = asset === 'ETH'
      ? (process.env.LEDGER_ETH_ZAR ? Number(process.env.LEDGER_ETH_ZAR) : await cgClosestPrice('coins/ethereum', ts))
      : asset === PHUSD
        ? await inferPhusdZar(ts)
        : await cgClosestPrice(`coins/ethereum/contract/${asset}`, ts);
    priceCache.set(key, p);
  }
  return priceCache.get(key);
}

// ---------- row building ----------

function fmtUnits(raw, decimals) {
  const neg = raw < 0n;
  const abs = neg ? -raw : raw;
  const base = 10n ** BigInt(decimals);
  const frac = (abs % base).toString().padStart(decimals, '0').replace(/0+$/, '');
  return `${neg ? '-' : ''}${abs / base}${frac ? '.' + frac : ''}`;
}

const zar = (x) => (x === null || x === undefined || Number.isNaN(x) ? '' : x.toFixed(2));

// SA tax year runs 1 March – end February and is named by the year it ends in.
function saTaxYear(d) {
  return d.getUTCMonth() >= 2 ? d.getUTCFullYear() + 1 : d.getUTCFullYear();
}

async function buildRow({ chainId, hash, receipt, tx, fn, contractName, script, note }) {
  const ts = await blockTimestamp(chainId, receipt.blockNumber);
  const date = new Date(ts * 1000);
  const sender = receipt.from.toLowerCase();
  const gasUsed = BigInt(receipt.gasUsed);
  const gasPrice = BigInt(receipt.effectiveGasPrice || tx.gasPrice || 0);
  const feeWei = gasUsed * gasPrice + BigInt(receipt.l1Fee || 0);
  const valueWei = BigInt(tx.value || 0);
  const feeEth = Number(fmtUnits(feeWei, 18));
  const valueEth = Number(fmtUnits(valueWei, 18));

  // Net ERC-20 movement into/out of the sending wallet.
  const net = new Map();
  for (const log of receipt.logs || []) {
    if (log.topics[0] !== TRANSFER_TOPIC || log.topics.length !== 3) continue;
    const from = '0x' + log.topics[1].slice(26);
    const to = '0x' + log.topics[2].slice(26);
    if (from !== sender && to !== sender) continue;
    const amt = BigInt(log.data === '0x' ? 0 : log.data.slice(0, 66));
    const token = log.address.toLowerCase();
    const d = (to === sender ? amt : 0n) - (from === sender ? amt : 0n);
    net.set(token, (net.get(token) || 0n) + d);
  }

  let missing = false;
  const ethZar = await priceZar('ETH', ts);
  if (ethZar === null) missing = true;

  const flows = [];
  let flowsZar = 0;
  for (const [token, amt] of net) {
    if (amt === 0n) continue;
    const { symbol, decimals } = await tokenMeta(chainId, token);
    const qty = fmtUnits(amt, decimals);
    const p = await priceZar(token, ts);
    if (p === null) { missing = true; flows.push(`${amt > 0n ? '+' : ''}${qty} ${symbol} (${token}, unpriced)`); continue; }
    flowsZar += Number(qty) * p;
    flows.push(`${amt > 0n ? '+' : ''}${qty} ${symbol} @R${p.toFixed(4)}`);
  }

  const feeZar = ethZar === null ? null : feeEth * ethZar;
  const valueZar = ethZar === null ? null : valueEth * ethZar;
  return {
    date_utc: date.toISOString(),
    sa_tax_year: saTaxYear(date),
    chain_id: chainId,
    tx_hash: hash.toLowerCase(),
    block: Number(BigInt(receipt.blockNumber)),
    status: BigInt(receipt.status) === 1n ? 'success' : 'reverted',
    from: sender,
    to: (receipt.to || receipt.contractAddress || '').toLowerCase(),
    function: fn || (receipt.contractAddress ? 'CREATE' : ''),
    contract_name: contractName || '',
    gas_used: gasUsed.toString(),
    gas_price_gwei: fmtUnits(gasPrice, 9),
    fee_eth: fmtUnits(feeWei, 18),
    value_eth: fmtUnits(valueWei, 18),
    eth_zar: zar(ethZar),
    fee_zar: zar(feeZar),
    value_zar: zar(valueZar),
    token_flows: flows.join('; '),
    token_net_zar: flows.length ? zar(flowsZar) : '',
    price_status: missing ? 'missing' : 'ok',
    npm_key: process.env.npm_lifecycle_event || '',
    script: script || '',
    note: note || '',
    recorded_at: new Date().toISOString(),
  };
}

// ---------- inputs ----------

function parseArgs(argv) {
  const out = { txs: [], positional: [], note: process.env.LEDGER_NOTE || '', chain: 1, reprice: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--tx') out.txs.push(argv[++i]);
    else if (a === '--note') out.note = argv[++i];
    else if (a === '--chain') out.chain = Number(argv[++i]);
    else if (a === '--reprice') out.reprice = true;
    else out.positional.push(a);
  }
  return out;
}

async function fromBroadcast(scriptFile, chainId, note) {
  const file = path.join(ROOT, 'broadcast', scriptFile, String(chainId), 'run-latest.json');
  if (!fs.existsSync(file)) throw new Error(`no broadcast record at ${path.relative(ROOT, file)}`);
  const run = JSON.parse(fs.readFileSync(file, 'utf8'));
  const byHash = new Map(run.transactions.map((t) => [t.hash && t.hash.toLowerCase(), t]));
  const jobs = [];
  for (const receipt of run.receipts) {
    const t = byHash.get(receipt.transactionHash.toLowerCase()) || { transaction: {} };
    jobs.push({
      chainId, hash: receipt.transactionHash, receipt, tx: t.transaction || {},
      fn: t.function || (t.transactionType === 'CREATE' ? 'CREATE' : ''), contractName: t.contractName,
      script: scriptFile, note,
    });
  }
  if (run.transactions.length > run.receipts.length) {
    console.warn(`ledger: ${run.transactions.length - run.receipts.length} broadcast tx(s) have no receipt yet; re-run after they confirm (or --resume)`);
  }
  return jobs;
}

async function fromHashes(hashes, chainId, note) {
  const jobs = [];
  for (const hash of hashes) {
    const [receipt, tx] = await Promise.all([
      rpc(chainId, 'eth_getTransactionReceipt', [hash]),
      rpc(chainId, 'eth_getTransactionByHash', [hash]),
    ]);
    if (!receipt) throw new Error(`no receipt for ${hash} on chain ${chainId}`);
    jobs.push({ chainId, hash, receipt, tx, fn: tx.input && tx.input.length >= 10 ? tx.input.slice(0, 10) : '', note });
  }
  return jobs;
}

// Appends a superseding row (price_status=repriced) for every tx whose only
// rows are price_status=missing. The original row stays in place.
async function reprice(entries) {
  const priced = new Set(entries.filter((e) => e.price_status !== 'missing').map((e) => `${e.chain_id}:${e.tx_hash}`));
  const todo = new Map();
  for (const e of entries) {
    const k = `${e.chain_id}:${e.tx_hash}`;
    if (e.price_status === 'missing' && !priced.has(k)) todo.set(k, e);
  }
  const rows = [];
  for (const e of todo.values()) {
    const [job] = await fromHashes([e.tx_hash], Number(e.chain_id), e.note);
    phusdPoolBlock = '0x' + (BigInt(job.receipt.blockNumber) - 1n).toString(16);
    const row = await buildRow({ ...job, fn: e.function, contractName: e.contract_name, script: e.script });
    if (row.price_status !== 'ok') continue;
    rows.push({ ...row, price_status: 'repriced', npm_key: e.npm_key });
  }
  appendLedger(rows);
  console.log(`ledger: appended ${rows.length} repriced row(s); ${todo.size - rows.length} still unpriced`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const entries = readLedger();

  if (args.reprice) {
    await reprice(entries);
    return;
  }

  let jobs;
  if (args.txs.length) {
    if (!RECORDED_CHAINS.has(args.chain)) return console.log(`ledger: chain ${args.chain} not recorded (mainnet only)`);
    jobs = await fromHashes(args.txs, args.chain, args.note);
  } else {
    const [scriptFile, chainArg] = args.positional;
    if (!scriptFile) throw new Error('usage: ledger-record.js <Script.s.sol> [chainId] | --tx <hash> [--note text]');
    const chainId = Number(chainArg || 1);
    if (!RECORDED_CHAINS.has(chainId)) return console.log(`ledger: chain ${chainId} not recorded (mainnet only)`);
    jobs = await fromBroadcast(scriptFile, chainId, args.note);
  }

  const seen = new Set(entries.map((e) => `${e.chain_id}:${e.tx_hash}`));
  if (jobs.length) {
    const first = jobs.reduce((m, j) => (BigInt(j.receipt.blockNumber) < m ? BigInt(j.receipt.blockNumber) : m), BigInt(jobs[0].receipt.blockNumber));
    phusdPoolBlock = '0x' + (first - 1n).toString(16);
  }
  const added = [];
  for (const job of jobs) {
    if (seen.has(`${job.chainId}:${job.hash.toLowerCase()}`)) continue;
    const row = await buildRow(job);
    added.push(row);
    seen.add(`${row.chain_id}:${row.tx_hash}`);
    console.log(`ledger: ${row.date_utc} ${row.tx_hash} ${row.function || '-'} fee R${row.fee_zar || '?'}${row.token_flows ? ` tokens ${row.token_flows} (net R${row.token_net_zar || '?'})` : ''}${row.price_status === 'missing' ? ' [PRICE MISSING]' : ''}`);
  }
  appendLedger(added);
  console.log(`ledger: ${added.length} new row(s), ${jobs.length - added.length} already recorded -> ${path.relative(ROOT, LEDGER_FILE)}`);
  if (added.some((e) => e.price_status === 'missing')) {
    console.warn('ledger: some rows have price_status=missing; run `npm run ledger:reprice` to fill them');
  }
}

main().catch((err) => {
  // Deliberately exit 0: the on-chain broadcast already happened, and a ledger
  // failure must not mask that or abort the remaining post-broadcast steps.
  console.error(`ledger: FAILED TO RECORD — ${err.message}`);
  console.error('ledger: re-run `node scripts/ledger-record.js ...` manually once fixed');
});
