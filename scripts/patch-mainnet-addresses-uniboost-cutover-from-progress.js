#!/usr/bin/env node
/**
 * patch-mainnet-addresses-uniboost-cutover-from-progress.js
 *
 * RESUME variant of scripts/patch-mainnet-addresses-uniboost-cutover.js.
 *
 * The stock patcher reads addresses POSITIONALLY from broadcast/.../run-latest.json
 * (it expects 3x Uniboost + 3x UniboostMintDebtHook + ... in CREATE order). After a
 * *resumed* broadcast (see the uniboost-cutover:resume npm script), run-latest.json only
 * holds the tx-12+ CREATEs — zero Uniboost, only the FLX hook — so the stock patcher
 * mis-assigns / aborts (exit 3).
 *
 * This variant instead reads every address BY NAME from the post-resume progress file
 * (server/deployments/progress.uniboost-cutover.1.json), which the deploy script rewrites
 * with ALL final addresses once the run completes. Same safe fill/update semantics as the
 * stock patcher:
 *   update:false -> only overwrite a zero-address placeholder (abort on non-zero collision)
 *   update:true  -> overwrite whatever is there (the two live ratchet keys)
 *
 * mainnet-addresses.ts is HAND-MAINTAINED — this only fills/updates values by key; it never
 * adds or removes keys. Runs only AFTER the resume broadcast fully succeeds (progress
 * deploymentStatus must be "completed").
 *
 * Exit codes:
 *   0 - Success
 *   1 - mainnet-addresses.ts missing
 *   2 - progress file missing / unparseable / not "completed"
 *   4 - a source address is missing/zero, a target field is absent, or an address collision
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.uniboost-cutover.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// tsField (mainnet-addresses.ts key) -> progress-file contract key.
// update:false = fill a zero placeholder only; update:true = overwrite the live value.
const FIELDS = [
    { tsField: 'UniboostEYE',              progressKey: 'UniboostEYE',              update: false },
    { tsField: 'UniboostSCX',              progressKey: 'UniboostSCX',              update: false },
    { tsField: 'UniboostFLX',              progressKey: 'UniboostFLX',              update: false },
    { tsField: 'UniboostHookEYE',          progressKey: 'UniboostHookEYE',          update: false },
    { tsField: 'UniboostHookSCX',          progressKey: 'UniboostHookSCX',          update: false },
    { tsField: 'UniboostHookFLX',          progressKey: 'UniboostHookFLX',          update: false },
    { tsField: 'MultiPooler',              progressKey: 'MultiPooler',              update: false },
    { tsField: 'UniboostStakerEYE',        progressKey: 'UniboostStakerEYE',        update: false },
    { tsField: 'UniboostStakerSCX',        progressKey: 'UniboostStakerSCX',        update: false },
    { tsField: 'UniboostStakerFLX',        progressKey: 'UniboostStakerFLX',        update: false },
    { tsField: 'NudgeRatchet',             progressKey: 'NudgeRatchet',             update: true  },
    { tsField: 'NudgeRatchetMintDebtHook', progressKey: 'NudgeRatchetMintDebtHook', update: true  },
];

function fail(code, msg) { console.error(`ERROR (${code}): ${msg}`); process.exit(code); }

function loadProgress() {
    if (!fs.existsSync(PROGRESS_FILE)) fail(2, `Progress file not found: ${PROGRESS_FILE}`);
    let p;
    try { p = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8')); }
    catch (e) { fail(2, `Progress unparseable: ${e.message}`); }
    if (p.deploymentStatus !== 'completed')
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (resume not finished?)`);
    return p;
}

function patchFlatField(source, field, newAddress, update) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) return { newSource: source, currentAddress: null, replaced: false };
    const currentAddress = match[2];
    const cleanTrailing = match[3]
        .replace(/\s*\/\/\s*not yet deployed.*/i, ',')
        .replace(/\s*\/\/\s*placeholder.*/i, ',')
        .replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');
    if (!update && currentAddress.toLowerCase() !== ZERO_ADDRESS)
        return { newSource: source, currentAddress, replaced: false };
    return { newSource: source.replace(re, `$1"${newAddress}"${cleanTrailing}`), currentAddress, replaced: true };
}

function run() {
    const progress = loadProgress();
    if (!fs.existsSync(ADDRESSES_FILE)) fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

    const summary = [];
    let bad = false;

    for (const f of FIELDS) {
        const entry = progress.contracts[f.progressKey];
        if (!entry || !entry.address || entry.address.toLowerCase() === ZERO_ADDRESS) {
            summary.push(`  MISS-SRC ${f.tsField.padEnd(23)} progress key "${f.progressKey}" missing/zero`);
            bad = true;
            continue;
        }
        const result = patchFlatField(source, f.tsField, entry.address, f.update);
        if (result.replaced) {
            source = result.newSource;
            summary.push(`  ${f.update ? 'UPDATE' : 'PATCH '} ${f.tsField.padEnd(24)} <- ${entry.address}`);
        } else if (result.currentAddress && result.currentAddress.toLowerCase() !== ZERO_ADDRESS) {
            summary.push(`  COLLIDE ${f.tsField.padEnd(23)} already=${result.currentAddress}, wanted=${entry.address}`);
            bad = true;
        } else {
            summary.push(`  MISS-DST ${f.tsField.padEnd(23)} field not found in mainnet-addresses.ts`);
            bad = true;
        }
    }

    const today = new Date().toISOString().split('T')[0];
    if (!/Uniboost dispatchers cut over/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: Uniboost dispatchers cut over at indices 1/2/3 + index-7 ratchet swapped to NudgeRatchetDelayRelease (story 071, RESUMED); addresses patched from progress file\n`
        );
    }

    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-uniboost-cutover-from-progress');
    console.log('==========================================================');
    summary.forEach((l) => console.log(l));
    console.log('==========================================================');

    if (bad) fail(4, 'One or more fields could not be safely patched (see summary above)');
    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
