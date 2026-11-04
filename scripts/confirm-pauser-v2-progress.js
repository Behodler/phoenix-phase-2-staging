#!/usr/bin/env node
/**
 * confirm-pauser-v2-progress.js  (audit run 49 L-06)
 *
 * Flips server/deployments/progress.pauser-v2.1.json from `pending` to `completed`, and only on evidence the
 * script itself cannot see. DeployPauserV2Mainnet writes `pending` in forge's LOCAL pass, before the CREATE is
 * signed. This runs after forge exits, chained in `pauser-v2-deploy:broadcast`, and requires:
 *   1. a successful receipt for exactly one PauserV2 CREATE in
 *      broadcast/DeployPauserV2Mainnet.s.sol/1/run-latest.json (the patcher's parser);
 *   2. that address == the progress file's PauserV2 address;
 *   3. live code at that address (`cast code` against $RPC_MAINNET).
 * Re-running on a `completed` file whose address still has code is a no-op success.
 *
 * Exit codes:
 *   0 - completed (or already completed)
 *   2 - receipts missing / unsuccessful (from the patcher's parser)
 *   4 - progress missing, unparseable, or disagrees with the receipts
 *   5 - no code at the address yet (still pending?) or RPC_MAINNET unset
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { pauserV2FromRunLatest } = require('./patch-mainnet-addresses-pauser-v2.js');

const ROOT = path.join(__dirname, '..');
const RUN_LATEST = path.join(ROOT, 'broadcast', 'DeployPauserV2Mainnet.s.sol', '1', 'run-latest.json');
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.pauser-v2.1.json');

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function main() {
    if (!fs.existsSync(PROGRESS_FILE)) fail(4, `no progress file at ${PROGRESS_FILE}`);
    let p;
    try {
        p = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
    } catch (e) {
        fail(4, `progress unparseable: ${e.message}`);
    }
    const entry = p.contracts && p.contracts.PauserV2;
    if (!entry || !entry.address) fail(4, 'progress has no contracts.PauserV2.address');

    const addr = pauserV2FromRunLatest(RUN_LATEST);
    if (addr.toLowerCase() !== entry.address.toLowerCase()) {
        fail(4, `progress PauserV2 (${entry.address}) != run-latest PauserV2 (${addr}) - investigate`);
    }

    const rpc = process.env.RPC_MAINNET;
    if (!rpc) fail(5, 'RPC_MAINNET unset - cannot confirm live code');
    const code = execFileSync('cast', ['code', addr, '--rpc-url', rpc], { encoding: 'utf8' }).trim();
    if (!code || code === '0x') fail(5, `no code at ${addr} yet - the CREATE may still be pending; re-run this script later`);

    if (p.deploymentStatus === 'completed' && entry.deployed === true) {
        console.log(`PauserV2 ${addr} already confirmed - nothing to do.`);
        return;
    }
    entry.deployed = true;
    p.deploymentStatus = 'completed';
    fs.writeFileSync(PROGRESS_FILE, JSON.stringify(p, null, 2) + '\n', 'utf8');
    console.log(`PauserV2 ${addr}: success receipt + live code confirmed. Progress marked completed.`);
}

main();
