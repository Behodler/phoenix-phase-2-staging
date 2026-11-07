#!/usr/bin/env node
/**
 * confirm-sya-gate-off-progress.js  (story 131, sprint nft-bonfire; modelled on confirm-nft-bonfire-progress.js)
 *
 * Flips server/deployments/progress.sya-gate-off.1.json from `pending` to `completed`, only on evidence the forge
 * script cannot see itself. ReplaceSYAGateOffMainnet writes `pending` (with each CREATE nonce) in forge's LOCAL
 * pass, before anything is signed. This runs after forge exits, chained in `sya-gate-off:broadcast`, and requires
 * for BOTH the new StableYieldAccumulator and the new SYAHarvester:
 *   1. when broadcast/ReplaceSYAGateOffMainnet.s.sol/1/run-latest.json holds that contract's CREATE: a successful
 *      receipt whose address == the progress file's address (the patcher's parser);
 *   2. live code at the progress address (`cast code` against $RPC_MAINNET).
 * A resume run (the CREATEs landed earlier) has no CREATE in run-latest: live code at the recorded address is then
 * the evidence. Re-running on a `completed` file whose addresses still have code is a no-op success.
 *
 * Exit codes:
 *   0 - completed (or already completed)
 *   2 - receipts unparseable / unsuccessful (from the patcher's parser)
 *   4 - progress missing, unparseable, incomplete, or disagrees with the receipts
 *   5 - no code at an address yet (still pending?) or RPC_MAINNET unset
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { createsFromRunLatest, TARGETS } = require('./patch-mainnet-addresses-sya-gate-off.js');

const ROOT = path.join(__dirname, '..');
const RUN_LATEST = path.join(ROOT, 'broadcast', 'ReplaceSYAGateOffMainnet.s.sol', '1', 'run-latest.json');
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.sya-gate-off.1.json');

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function liveCode(addr) {
    const rpc = process.env.RPC_MAINNET;
    if (!rpc) fail(5, 'RPC_MAINNET unset - cannot confirm live code');
    let code;
    try {
        code = execFileSync('cast', ['code', addr, '--rpc-url', rpc], {
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'pipe'],
        }).trim();
    } catch (e) {
        // Never echo the command line: it carries the RPC URL.
        fail(5, `cast code ${addr} failed (RPC error) - re-run this script`);
    }
    return code && code !== '0x';
}

function main() {
    if (!fs.existsSync(PROGRESS_FILE)) fail(4, `no progress file at ${PROGRESS_FILE}`);
    let p;
    try {
        p = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
    } catch (e) {
        fail(4, `progress unparseable: ${e.message}`);
    }
    if (p.chainId !== 1) fail(4, `progress chainId is ${p.chainId}, expected 1`);
    const entries = {};
    for (const t of TARGETS) {
        const e = p.contracts && p.contracts[t.key];
        if (!e || !e.address) {
            fail(4, `progress has no contracts.${t.key}.address - the run stopped before that CREATE; re-run the broadcast`);
        }
        entries[t.key] = e;
    }

    if (p.deploymentStatus === 'completed' && TARGETS.every((t) => entries[t.key].deployed === true)) {
        for (const t of TARGETS) {
            if (!liveCode(entries[t.key].address)) fail(5, `progress is completed but ${t.key} ${entries[t.key].address} has no code - investigate`);
        }
        console.log('new SYA + SYAHarvester already confirmed - nothing to do.');
        return;
    }

    const fromReceipts = createsFromRunLatest(RUN_LATEST, true);
    for (const t of TARGETS) {
        const addr = entries[t.key].address;
        const r = fromReceipts[t.key];
        if (r && r.toLowerCase() !== addr.toLowerCase()) {
            fail(4, `progress ${t.key} (${addr}) != run-latest ${t.contractName} CREATE (${r}) - investigate`);
        }
        if (!r) console.log(`run-latest holds no ${t.contractName} CREATE (resume run): confirming from live code alone.`);
        if (!liveCode(addr)) fail(5, `no code at ${t.key} ${addr} yet - the CREATE may still be pending; re-run later`);
    }

    for (const t of TARGETS) entries[t.key].deployed = true;
    p.deploymentStatus = 'completed';
    fs.writeFileSync(PROGRESS_FILE, JSON.stringify(p, null, 2) + '\n', 'utf8');
    console.log('new SYA + SYAHarvester: success receipts + live code confirmed. Progress marked completed.');
}

main();
