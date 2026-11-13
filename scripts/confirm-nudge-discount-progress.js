#!/usr/bin/env node
/**
 * confirm-nudge-discount-progress.js  (story 119, sprint nudge-discount; modelled on confirm-nft-bonfire-progress.js)
 *
 * Flips server/deployments/progress.nudge-discount.1.json from `pending` to `completed`, and only on evidence the
 * forge script itself cannot see. DeployMainnetNudgeDiscount writes `pending` in forge's LOCAL pass, before the
 * CREATE is signed, so it can never honestly write `completed`. This runs after forge exits, chained in
 * `nudge-discount:broadcast`, and requires:
 *   1. a successful receipt for exactly one BatchNFTMinterNudgeDiscount CREATE in
 *      broadcast/DeployMainnetNudgeDiscount.s.sol/1/run-latest.json (the patcher's parser);
 *   2. that address == the progress file's NudgeDiscountBatchMinter address;
 *   3. live code at that address (`cast code` against $RPC_MAINNET; the URL is never echoed).
 * Re-running on a `completed` file whose address still has code is a no-op success.
 *
 * Why this is not redundant with the patcher's "refuse incomplete" check: that check only READS deploymentStatus.
 * Nothing else sets it, so without this step the patcher would refuse every real broadcast (or the forge script would
 * have to claim `completed` before the tx was signed, which would make the gate meaningless).
 *
 * A re-run of the broadcast that only RESUMED steps has no CREATE in its run-latest.json: an already `completed`
 * file is left as it is, and a still-`pending` one is confirmed from live code at the recorded address alone.
 * If this exits 5 because the CREATE has not mined yet, re-run it standalone once it has, then the patcher and the
 * verifier.
 *
 * OPTIONS (for tests on scratch copies; production runs with none)
 *   --run-latest <path>   --progress <path>
 *   --code-stub <0|1>     do not call `cast code`; treat the address as having (1) or lacking (0) code
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
const { minterFromRunLatest } = require('./patch-mainnet-addresses-nudge-discount.js');

const ROOT = path.join(__dirname, '..');
const KEY = 'NudgeDiscountBatchMinter';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function parseArgs(argv) {
    const opts = {
        runLatest: path.join(ROOT, 'broadcast', 'DeployMainnetNudgeDiscount.s.sol', '1', 'run-latest.json'),
        progress: path.join(ROOT, 'server', 'deployments', 'progress.nudge-discount.1.json'),
        codeStub: null,
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--run-latest' && argv[i + 1]) opts.runLatest = path.resolve(argv[++i]);
        else if (a === '--progress' && argv[i + 1]) opts.progress = path.resolve(argv[++i]);
        else if (a === '--code-stub' && (argv[i + 1] === '0' || argv[i + 1] === '1')) opts.codeStub = argv[++i] === '1';
        else fail(4, `Unknown or incomplete argument: ${a}`);
    }
    return opts;
}

function liveCode(addr, opts) {
    if (opts.codeStub !== null) return opts.codeStub;
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
    const opts = parseArgs(process.argv.slice(2));
    if (!fs.existsSync(opts.progress)) fail(4, `no progress file at ${opts.progress}`);
    let p;
    try {
        p = JSON.parse(fs.readFileSync(opts.progress, 'utf8'));
    } catch (e) {
        fail(4, `progress unparseable: ${e.message}`);
    }
    const entry = p.contracts && p.contracts[KEY];
    if (!entry || !entry.address) fail(4, `progress has no contracts.${KEY}.address`);

    if (p.deploymentStatus === 'completed' && entry.deployed === true) {
        if (!liveCode(entry.address, opts)) fail(5, `progress is completed but ${entry.address} has no code - investigate`);
        console.log(`${KEY} ${entry.address} already confirmed - nothing to do.`);
        return;
    }

    const fromReceipts = minterFromRunLatest(opts.runLatest, true);
    if (fromReceipts && fromReceipts.toLowerCase() !== entry.address.toLowerCase()) {
        fail(4, `progress ${KEY} (${entry.address}) != run-latest CREATE (${fromReceipts}) - investigate`);
    }
    if (!fromReceipts) console.log('run-latest holds no BatchNFTMinterNudgeDiscount CREATE (resume run): confirming from live code alone.');
    if (!liveCode(entry.address, opts)) {
        fail(5, `no code at ${entry.address} yet - the CREATE may still be pending; re-run this script later`);
    }

    entry.deployed = true;
    p.deploymentStatus = 'completed';
    fs.writeFileSync(opts.progress, JSON.stringify(p, null, 2) + '\n', 'utf8');
    console.log(`${KEY} ${entry.address}: success receipt + live code confirmed. Progress marked completed.`);
}

main();
