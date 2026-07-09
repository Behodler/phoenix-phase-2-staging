#!/usr/bin/env node
/**
 * patch-mainnet-addresses-uniboost-batchminters.js
 *
 * Fills the three empty per-token UI batch-minter fields in mainnet-addresses.ts
 * (EyeBatchNFTMinter / ScxBatchNFTMinter / FlxBatchNFTMinter) after
 * DeployMainnetUniboostBatchMinters.s.sol broadcasts.
 *
 * Source of truth = the BROADCAST artifact's LANDED txes (real tx hash + contractAddress),
 * NOT the progress file — the progress file is written to "completed" during the script's
 * execution phase, before broadcasting, so it can claim addresses that never landed. We read
 * the three CREATE txes with contractName "BatchNFTMinter" that carry a hash, in deploy order
 * (EYE -> SCX -> FLX), and REQUIRE exactly three. If fewer landed (partial broadcast), we abort
 * so a half-done deploy can never mis-fill the file.
 *
 * Exit codes: 0 ok | 1 broadcast missing/unreadable | 3 != 3 landed batch minters | 4 patch collision/miss
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BROADCAST = path.join(ROOT, 'broadcast', 'DeployMainnetUniboostBatchMinters.s.sol', '1', 'run-latest.json');
const ADDRESSES = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const ORDER = ['EyeBatchNFTMinter', 'ScxBatchNFTMinter', 'FlxBatchNFTMinter']; // EYE=idx1, SCX=idx2, FLX=idx3

function fail(code, msg) { console.error(`ERROR (${code}): ${msg}`); process.exit(code); }

function landedBatchMinters(bc) {
    // A tx that actually broadcast has a non-zero hash; CREATEs carry contractAddress.
    return (bc.transactions || []).filter(
        (t) => t.transactionType === 'CREATE'
            && t.contractName === 'BatchNFTMinter'
            && t.hash && t.hash !== '0x' + '0'.repeat(64)
            && t.contractAddress
    );
}

function patchEmptyField(src, field, addr) {
    // Matches `field: ""` (fill) or `field: "0x…40"` (idempotent re-run / collision check).
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40}|)"(.*)$`, 'm');
    const m = src.match(re);
    if (!m) return { src, replaced: false, missing: true };
    const current = m[2];
    if (current && current.toLowerCase() !== addr.toLowerCase()) {
        return { src, replaced: false, collision: current }; // already holds a DIFFERENT address
    }
    if (current) return { src, replaced: false, already: true }; // same address, nothing to do
    return { src: src.replace(re, `$1"${addr}"$3`), replaced: true };
}

function run() {
    if (!fs.existsSync(BROADCAST)) fail(1, `Broadcast not found: ${BROADCAST}`);
    let bc;
    try { bc = JSON.parse(fs.readFileSync(BROADCAST, 'utf8')); } catch (e) { fail(1, `Broadcast unreadable: ${e.message}`); }

    const creates = landedBatchMinters(bc);
    if (creates.length !== 3) {
        fail(3, `Expected 3 landed BatchNFTMinter CREATEs, found ${creates.length}. Partial broadcast — reconcile before patching.`);
    }
    if (!fs.existsSync(ADDRESSES)) fail(1, `Addresses file not found: ${ADDRESSES}`);
    let src = fs.readFileSync(ADDRESSES, 'utf8');

    const summary = [];
    let bad = false;
    ORDER.forEach((field, i) => {
        const addr = creates[i].contractAddress;
        const r = patchEmptyField(src, field, addr);
        if (r.replaced) { src = r.src; summary.push(`  FILL  ${field.padEnd(20)} <- ${addr}`); }
        else if (r.already) summary.push(`  SKIP  ${field.padEnd(20)} already = ${addr}`);
        else if (r.collision) { summary.push(`  COLLIDE ${field.padEnd(18)} has ${r.collision}, wanted ${addr}`); bad = true; }
        else { summary.push(`  MISS  ${field.padEnd(20)} field not found in mainnet-addresses.ts`); bad = true; }
    });

    console.log('==================================================');
    console.log('  patch-mainnet-addresses-uniboost-batchminters');
    console.log('==================================================');
    summary.forEach((l) => console.log(l));
    console.log('==================================================');
    if (bad) fail(4, 'One or more fields could not be safely patched (see above)');
    fs.writeFileSync(ADDRESSES, src, 'utf8');
    console.log(`  File written: ${ADDRESSES}`);
}

run();
