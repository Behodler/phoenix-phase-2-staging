#!/usr/bin/env node
/**
 * uniboost-multipool-ledger-note.js
 *
 * Prints the tax-ledger note for a `uniboost:multipool:broadcast` run (script/UniboostMultiPool.s.sol). It reads the
 * CONFIRMED receipts in broadcast/UniboostMultiPool.s.sol/1/run-latest.json, decodes each Uniboost
 * `Pooled(address indexed pooler, uint256 primeSpent, uint256 liquidity, uint256 minLP)` event, and states what was
 * pooled and that the LP is not the wallet's:
 *
 *   node scripts/ledger-record.js UniboostMultiPool.s.sol 1 --note "$(node scripts/uniboost-multipool-ledger-note.js)"
 *
 * ACCOUNTING POSITION. The USDC spent belongs to the Uniboost dispatcher contracts (NFT mint proceeds retained by
 * the protocol), not to the sending wallet, and the LP is minted to and stays on those dispatchers as
 * protocol-owned liquidity. The wallet neither disposes of nor acquires any token, so the only personal cost is gas
 * (fee_zar). The note records the amounts so the row is self-explaining without the chain.
 *
 * A caller-supplied LEDGER_NOTE is prepended. This helper NEVER exits non-zero and always prints a note (falling
 * back to the static wording) so it can never stop the recorder from running after a confirmed broadcast.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const RUN = path.join(ROOT, 'broadcast', 'UniboostMultiPool.s.sol', '1', 'run-latest.json');
const BOOK = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const POOLED_TOPIC = '0xaf6cb2e6187986f98607346b0da39860f8bcc4e2e024c1926efa779809b07adb';
const NAMES = ['EYE', 'SCX', 'FLX'];

const BASE =
    'protocol-owned LP, gas only: MultiPooler batch-pooled USDC held by the Uniboost NFT dispatchers into the ' +
    'target/WETH UniV2 pairs; the USDC was protocol funds (not the wallet) and the LP is minted to and held by the ' +
    'dispatcher contracts (not the wallet), so no token was acquired or disposed of by the wallet';

function fmtUnits(v, decimals, dp) {
    const s = v.toString().padStart(decimals + 1, '0');
    const whole = s.slice(0, s.length - decimals);
    const frac = s.slice(s.length - decimals).slice(0, dp);
    return `${whole}.${frac}`;
}

function names() {
    const out = {};
    try {
        const src = fs.readFileSync(BOOK, 'utf8');
        for (const n of NAMES) {
            const m = src.match(new RegExp(`\\n  Uniboost${n}: "(0x[0-9a-fA-F]{40})"`));
            if (m) out[m[1].toLowerCase()] = n;
        }
    } catch (_) {
        /* fall through: unnamed addresses */
    }
    return out;
}

function detail() {
    const run = JSON.parse(fs.readFileSync(RUN, 'utf8'));
    const byAddr = names();
    const parts = [];
    let total = 0n;
    for (const r of run.receipts || []) {
        for (const log of r.logs || []) {
            if ((log.topics || [])[0] !== POOLED_TOPIC) continue;
            const addr = log.address.toLowerCase();
            const data = log.data.replace(/^0x/, '');
            const primeSpent = BigInt('0x' + data.slice(0, 64));
            const liquidity = BigInt('0x' + data.slice(64, 128));
            total += primeSpent;
            const name = byAddr[addr] || addr;
            parts.push(`${name} ${fmtUnits(primeSpent, 6, 2)} USDC -> ${fmtUnits(liquidity, 18, 6)} LP`);
        }
    }
    if (parts.length === 0) return '';
    return `; pooled ${parts.join(', ')} (total ${fmtUnits(total, 6, 2)} USDC)`;
}

let note = BASE;
try {
    note += detail();
} catch (e) {
    console.error(`[uniboost-multipool-ledger-note] could not decode ${RUN}: ${e.message}; using the static note`);
}
const user = (process.env.LEDGER_NOTE || '').trim();
process.stdout.write(user ? `${user}; ${note}` : note);
