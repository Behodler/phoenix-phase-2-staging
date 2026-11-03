#!/usr/bin/env node
/**
 * pauser-v2-registrant-labels.js  (story 128, sprint global-pauser-v2) - READ-ONLY
 *
 * Off-chain half of the PauserV2 registrant classification. For every address registered with the
 * V1 mainnet Pauser it prints:
 *   - the key(s) it has in the CURRENT hand-maintained book (server/deployments/mainnet-addresses.ts),
 *     plus the comment lines directly above the key (that is where "Old ..." / retired notes live);
 *   - the key(s) it has had in every historical book (mainnet.backup.*.ts, mainnet-addresses-*.ts);
 *   - the key(s) it has in any mainnet progress file (progress*.1.json);
 *   - its Etherscan verified contract name (needs ETHERSCAN_API_KEY; skipped if unset).
 *
 * The on-chain half (code size, owner, pauser, paused, balances) is
 * script/ClassifyPauserV2Registrants.s.sol. The merged verdict table is docs/pauser-v2-registrants.md.
 *
 * Usage: node scripts/pauser-v2-registrant-labels.js [addr ...]
 *        With no args, reads the live registrant list from the V1 Pauser via `cast` and $RPC_MAINNET.
 * Writes nothing.
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const V1_PAUSER = '0x7c5A8EeF1d836450C019FB036453ac6eC97885a3';
const DEPLOY_DIR = path.join(__dirname, '..', 'server', 'deployments');
const CURRENT_BOOK = path.join(DEPLOY_DIR, 'mainnet-addresses.ts');

function registrants() {
  if (process.argv.length > 2) return process.argv.slice(2);
  const rpc = process.env.RPC_MAINNET;
  if (!rpc) throw new Error('RPC_MAINNET unset and no addresses given');
  const out = execFileSync('cast', ['call', V1_PAUSER, 'getPausableContracts()(address[])', '--rpc-url', rpc], {
    encoding: 'utf8',
  });
  return out.replace(/[\[\]\s]/g, '').split(',').filter(Boolean);
}

/** Map lower-case address -> [{key, comment}] for one .ts book. */
function bookLabels(file) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const map = {};
  for (let i = 0; i < lines.length; i++) {
    // Quoted object keys (`Key: "0x..",`) and the unquoted note lines inside the header block comment
    // (`  Old YieldStrategyDola: 0x..`), which is where the book records superseded addresses.
    const m =
      lines[i].match(/^\s*([A-Za-z0-9_]+)\s*:\s*["'](0x[0-9a-fA-F]{40})["']/) ||
      lines[i].match(/^\s*([A-Za-z][A-Za-z0-9_ ]*?)\s*:\s*(0x[0-9a-fA-F]{40})\s*$/);
    if (!m) continue;
    const comments = [];
    for (let j = i - 1; j >= 0 && /^\s*\/\//.test(lines[j]); j--) comments.unshift(lines[j].trim());
    const trailing = (lines[i].split('//')[1] || '').trim();
    (map[m[2].toLowerCase()] ||= []).push({ key: m[1], comment: [...comments, trailing].filter(Boolean).join(' ') });
  }
  return map;
}

/** Map lower-case address -> [key] for one progress JSON (any depth). */
function progressLabels(file) {
  const map = {};
  let json;
  try {
    json = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return map;
  }
  const walk = (node, trail) => {
    if (typeof node === 'string' && /^0x[0-9a-fA-F]{40}$/.test(node)) {
      (map[node.toLowerCase()] ||= []).push(trail.filter((t) => t !== 'address' && t !== 'contracts').join('.'));
    } else if (node && typeof node === 'object') {
      for (const [k, v] of Object.entries(node)) walk(v, [...trail, k]);
    }
  };
  walk(json, []);
  return map;
}

function etherscanName(addr) {
  const key = process.env.ETHERSCAN_API_KEY;
  if (!key) return '(ETHERSCAN_API_KEY unset)';
  const url = `https://api.etherscan.io/v2/api?chainid=1&module=contract&action=getsourcecode&address=${addr}&apikey=${key}`;
  try {
    const body = JSON.parse(execFileSync('curl', ['-s', '--max-time', '20', url], { encoding: 'utf8' }));
    const r = Array.isArray(body.result) ? body.result[0] : null;
    if (!r) return `(etherscan: ${body.message || 'no result'})`;
    return r.ContractName ? r.ContractName : '(unverified)';
  } catch (e) {
    return `(etherscan error: ${e.message.split('\n')[0]})`;
  }
}

function main() {
  const addrs = registrants();
  const current = bookLabels(CURRENT_BOOK);
  const histFiles = fs
    .readdirSync(DEPLOY_DIR)
    .filter((f) => /^mainnet.*\.ts$/.test(f) && f !== 'mainnet-addresses.ts')
    .sort();
  const hist = histFiles.map((f) => [f, bookLabels(path.join(DEPLOY_DIR, f))]);
  const progFiles = fs.readdirSync(DEPLOY_DIR).filter((f) => /^progress.*\.1\.json$/.test(f)).sort();
  const prog = progFiles.map((f) => [f, progressLabels(path.join(DEPLOY_DIR, f))]);

  const rows = addrs.map((a, i) => {
    const lc = a.toLowerCase();
    const historical = new Set();
    for (const [, m] of hist) for (const e of m[lc] || []) historical.add(e.key);
    const progress = new Set();
    for (const [f, m] of prog) for (const k of m[lc] || []) progress.add(`${f}:${k}`);
    return {
      index: i,
      address: a,
      currentBook: current[lc] || [],
      historicalBookKeys: [...historical],
      progressKeys: [...progress],
      etherscanName: etherscanName(a),
    };
  });
  console.log(JSON.stringify(rows, null, 2));
}

main();
