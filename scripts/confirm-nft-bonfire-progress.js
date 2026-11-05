#!/usr/bin/env node
/**
 * confirm-nft-bonfire-progress.js  (story 129, sprint nft-bonfire; modelled on confirm-pauser-v2-progress.js)
 *
 * Flips server/deployments/progress.nft-bonfire.1.json from `pending` to `completed`, and only on evidence the
 * script itself cannot see. DeployNFTBonfireMainnet writes `pending` in forge's LOCAL pass, before the CREATE is
 * signed. This runs after forge exits, chained in `nft-bonfire:broadcast`, and requires:
 *   1. a successful receipt for exactly one NFTBonfire CREATE in
 *      broadcast/DeployNFTBonfireMainnet.s.sol/1/run-latest.json (the patcher's parser);
 *   2. that address == the progress file's NFTBonfire address;
 *   3. live code at that address (`cast code` against $RPC_MAINNET).
 * Re-running on a `completed` file whose address still has code is a no-op success.
 *
 * A re-run of the broadcast that only RESUMED wiring has no CREATE in its run-latest.json: an already `completed`
 * file is left as it is, and a still-`pending` one is confirmed from live code at the recorded address alone.
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
const { bonfireFromRunLatest } = require('./patch-mainnet-addresses-nft-bonfire.js');

const ROOT = path.join(__dirname, '..');
const RUN_LATEST = path.join(ROOT, 'broadcast', 'DeployNFTBonfireMainnet.s.sol', '1', 'run-latest.json');
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.nft-bonfire.1.json');

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
    const entry = p.contracts && p.contracts.NFTBonfire;
    if (!entry || !entry.address) fail(4, 'progress has no contracts.NFTBonfire.address');

    if (p.deploymentStatus === 'completed' && entry.deployed === true) {
        if (!liveCode(entry.address)) fail(5, `progress is completed but ${entry.address} has no code - investigate`);
        console.log(`NFTBonfire ${entry.address} already confirmed - nothing to do.`);
        return;
    }

    // A resume run (the CREATE landed in an earlier run, wiring was re-run) has no CREATE in its run-latest.json:
    // the progress address with live code is then the evidence (it is OWNER's recorded CREATE address).
    const fromReceipts = bonfireFromRunLatest(RUN_LATEST, true);
    if (fromReceipts && fromReceipts.toLowerCase() !== entry.address.toLowerCase()) {
        fail(4, `progress NFTBonfire (${entry.address}) != run-latest NFTBonfire (${fromReceipts}) - investigate`);
    }
    if (!fromReceipts) console.log('run-latest holds no NFTBonfire CREATE (resume run): confirming from live code alone.');
    const addr = entry.address;
    if (!liveCode(addr)) fail(5, `no code at ${addr} yet - the CREATE may still be pending; re-run this script later`);

    entry.deployed = true;
    p.deploymentStatus = 'completed';
    fs.writeFileSync(PROGRESS_FILE, JSON.stringify(p, null, 2) + '\n', 'utf8');
    console.log(`NFTBonfire ${addr}: success receipt + live code confirmed. Progress marked completed.`);
}

main();
