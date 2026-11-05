#!/usr/bin/env node
/**
 * pauser-v2-migrate-resume.js — unstick and resume an interrupted pauser-v2-migrate:broadcast.
 *
 * Automates the runbook's "Gas price" stall recovery (docs/runbooks/pauser-v2-migration.md):
 *
 *   0. Refuses while a MigratePauserV2Mainnet forge process is still running (Ctrl+C it first).
 *   1. Archives broadcast/MigratePauserV2Mainnet.s.sol/1/run-latest.json, because the re-run
 *      overwrites it.
 *   2. Records the interrupted run's confirmed txs in the tax ledger. The interrupted chain never
 *      reached its ledger step, and the re-run's recorder only sees the new run-latest.json.
 *      The recorder de-duplicates on tx hash, so this is safe to repeat.
 *   3. Picks a gas price: max(4 x current base fee, 2 gwei floor, 1.13 x the stuck tx's price),
 *      unless PAUSER_V2_GAS_PRICE_WEI is set. Refuses above 30 gwei.
 *   4. For every nonce the interrupted run sent that is still unmined, sends a zero-value Ledger
 *      self-send at that nonce (the runbook's cancel; a forge re-run is NOT relied on to replace
 *      it), waits for its receipt and records it in the ledger. If the original tx mines first,
 *      the cancel is skipped or its "nonce too low" failure is tolerated.
 *   5. Re-runs `npm run pauser-v2-migrate:broadcast` at that price. Every migrate step is
 *      state-gated, so it resumes from the chain and keeps its own verify + ledger tail.
 */

const fs = require('fs');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const OWNER = '0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6';
const HD_PATH = "m/44'/60'/46'/0/0";
const RUN_DIR = path.join(ROOT, 'broadcast', 'MigratePauserV2Mainnet.s.sol', '1');
const RUN_LATEST = path.join(RUN_DIR, 'run-latest.json');
const GWEI = 1_000_000_000n;
const FLOOR_WEI = 2n * GWEI; // above the 1.33 gwei spike that stalled the first run
const CAP_WEI = 30n * GWEI;
const RPC = process.env.RPC_MAINNET;

function die(msg) {
  console.error(`\nREFUSING: ${msg}`);
  process.exit(1);
}

function cast(args, { allowFail = false } = {}) {
  try {
    return execFileSync('cast', [...args, '--rpc-url', RPC], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch (e) {
    if (allowFail) return null;
    throw new Error(`cast ${args[0]} failed: ${(e.stderr || e.message).toString().trim()}`);
  }
}

const latestNonce = () => BigInt(cast(['nonce', OWNER, '--block', 'latest']));
const baseFee = () => BigInt(cast(['basefee']));
const mined = (hash) => {
  const r = cast(['receipt', hash, '--async', '--json'], { allowFail: true });
  if (!r) return null;
  try { const j = JSON.parse(r); return j && j.blockNumber ? j : null; } catch { return null; }
};

function ledgerRecord(hashes, note) {
  if (!hashes.length) return;
  const args = [path.join(ROOT, 'scripts', 'ledger-record.js')];
  for (const h of hashes) args.push('--tx', h);
  args.push('--note', note);
  spawnSync('node', args, { stdio: 'inherit', cwd: ROOT });
}

function main() {
  if (!RPC) die('RPC_MAINNET is not set (source .envrc).');

  // 0. No live forge run.
  const ps = spawnSync('pgrep', ['-f', 'forge script script/MigratePauserV2Mainnet'], { encoding: 'utf8' });
  if (ps.status === 0 && ps.stdout.trim()) {
    die(`a MigratePauserV2Mainnet forge run is still alive (pid ${ps.stdout.trim().split('\n').join(', ')}). Ctrl+C it, then re-run this key.`);
  }

  // 1. Archive the interrupted run.
  if (!fs.existsSync(RUN_LATEST)) die(`${RUN_LATEST} not found: nothing to resume. Use pauser-v2-migrate:broadcast.`);
  const run = JSON.parse(fs.readFileSync(RUN_LATEST, 'utf8'));
  const archive = path.join(RUN_DIR, `run-interrupted-${Date.now()}.json`);
  fs.copyFileSync(RUN_LATEST, archive);
  console.log(`Archived interrupted run -> ${path.relative(ROOT, archive)}`);

  const sent = run.transactions
    .filter((t) => t.hash && t.transaction && t.transaction.nonce !== undefined)
    .filter((t) => (t.transaction.from || '').toLowerCase() === OWNER.toLowerCase())
    .map((t) => ({
      hash: t.hash,
      nonce: BigInt(t.transaction.nonce),
      price: BigInt(t.transaction.gasPrice || t.transaction.maxFeePerGas || 0),
      fn: t.function,
      to: t.transaction.to,
    }));

  // 2. Ledger the interrupted run's confirmed txs.
  const confirmed = sent.filter((t) => mined(t.hash));
  console.log(`Interrupted run: ${sent.length} sent, ${confirmed.length} mined.`);
  ledgerRecord(confirmed.map((t) => t.hash),
    process.env.LEDGER_NOTE || 'PauserV2 migration (story 128): interrupted run, setPauser + register admin txs, gas only');

  // 3. Gas price.
  const fee = baseFee();
  const n0 = latestNonce();
  const stuck = sent.filter((t) => t.nonce >= n0 && !mined(t.hash)).sort((a, b) => (a.nonce < b.nonce ? -1 : 1));
  const stuckMax = stuck.reduce((m, t) => (t.price > m ? t.price : m), 0n);
  let price;
  if (process.env.PAUSER_V2_GAS_PRICE_WEI) {
    price = BigInt(process.env.PAUSER_V2_GAS_PRICE_WEI);
  } else {
    price = [4n * fee, FLOOR_WEI, (stuckMax * 113n) / 100n + 1n].reduce((m, x) => (x > m ? x : m), 0n);
  }
  if (price > CAP_WEI) die(`gas price ${price} wei exceeds the 30 gwei cap. Set PAUSER_V2_GAS_PRICE_WEI explicitly if you mean it.`);
  if (price < 2n * fee) die(`gas price ${price} wei is below 2 x base fee (${fee}); the migrate script would refuse it.`);
  if (stuckMax && price < (stuckMax * 1125n) / 1000n + 1n) die(`gas price ${price} wei is not 12.5% above the stuck price ${stuckMax}.`);
  console.log(`Base fee ${fee} wei; using gas price ${price} wei (${Number(price) / 1e9} gwei).`);

  // 4. Cancel every still-unmined nonce the interrupted run sent.
  if (stuck.length) {
    const signer = execFileSync('cast', ['wallet', 'address', '--ledger', '--mnemonic-derivation-path', HD_PATH], { encoding: 'utf8' }).trim();
    if (signer.toLowerCase() !== OWNER.toLowerCase()) die(`Ledger path ${HD_PATH} resolves to ${signer}, not OWNER ${OWNER}.`);
  }
  const cancels = [];
  for (const t of stuck) {
    if (latestNonce() > t.nonce || mined(t.hash)) {
      console.log(`Nonce ${t.nonce}: original ${t.fn} mined meanwhile; no cancel needed.`);
      continue;
    }
    console.log(`Nonce ${t.nonce}: cancelling stuck ${t.fn} -> ${t.to} (${t.hash}). Confirm the self-send on the Ledger.`);
    const out = cast(['send', OWNER, '--value', '0', '--nonce', t.nonce.toString(), '--legacy', '--gas-price', price.toString(),
      '--ledger', '--mnemonic-derivation-path', HD_PATH, '--async'], { allowFail: true });
    if (!out) {
      if (latestNonce() > t.nonce) { console.log(`Nonce ${t.nonce}: consumed by the original tx; continuing.`); continue; }
      die(`cancel at nonce ${t.nonce} failed and the nonce is still open. Nothing further was sent.`);
    }
    const hash = (out.match(/0x[0-9a-fA-F]{64}/) || [])[0];
    if (!hash) die(`could not parse the cancel tx hash from: ${out}`);
    console.log(`Nonce ${t.nonce}: cancel sent ${hash}; waiting for receipt...`);
    cast(['receipt', hash, '--confirmations', '1']);
    console.log(`Nonce ${t.nonce}: cancel mined.`);
    cancels.push(hash);
  }
  ledgerRecord(cancels, 'PauserV2 stuck-nonce cancel');

  const maxSent = sent.reduce((m, t) => (t.nonce > m ? t.nonce : m), -1n);
  if (latestNonce() <= maxSent) die(`OWNER nonce ${latestNonce()} has not passed the interrupted run's last nonce ${maxSent}.`);

  // 5. Resume.
  console.log(`\nResuming: PAUSER_V2_GAS_PRICE_WEI=${price} npm run pauser-v2-migrate:broadcast\n`);
  const r = spawnSync('npm', ['run', 'pauser-v2-migrate:broadcast'], {
    stdio: 'inherit', cwd: ROOT, env: { ...process.env, PAUSER_V2_GAS_PRICE_WEI: price.toString() },
  });
  process.exit(r.status === null ? 1 : r.status);
}

main();
