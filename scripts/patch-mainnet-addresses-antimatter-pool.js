#!/usr/bin/env node
/**
 * patch-mainnet-addresses-antimatter-pool.js  (story 122, Script B, sprint sya-antimatter-cutover)
 *
 * FILLS the `AntimatterPoolSeeder` and `AntimatterSusdsPair` keys of `server/deployments/mainnet-addresses.ts` from
 * `server/deployments/progress.antimatter-pool.1.json` (written by script/CutoverAntimatterPoolMainnet.s.sol).
 *
 * Modelled on patch-mainnet-addresses-uniswap-helper.js. MANDATORY TAIL of `antimatter-pool:broadcast`, joined with
 * `&&` so it runs only on a zero exit from forge script. The progress file is written during forge's LOCAL execution
 * pass, so after a crashed broadcast it can name a contract that never landed; check the receipts
 * (broadcast/CutoverAntimatterPoolMainnet.s.sol/1/run-latest.json) before trusting it.
 *
 * WHAT IT TOUCHES
 *   FILL `AntimatterPoolSeeder` and `AntimatterSusdsPair` (overwrite ONLY the zero-address placeholders story 114 left;
 *   the SAME address already present is success, so a re-run is idempotent; any OTHER non-zero value is a COLLIDE and
 *   NOTHING is written - both keys or neither). Requires `deploymentStatus == "completed"` and `cutover.seeded == true`.
 *   Story 114's "ZERO until the mainnet cutover" comment becomes false once filled and is replaced.
 *
 * WHAT IT NEVER DOES
 *   Add or remove a key. The key-set must exactly equal the ContractAddresses interface in addresses.ts (exit 3).
 *
 * OPTIONS (for proving the patcher on scratch copies; production runs with none)
 *   --progress <path>    progress file   (default server/deployments/progress.antimatter-pool.1.json)
 *   --addresses <path>   address book    (default server/deployments/mainnet-addresses.ts)
 *
 * Exit codes:
 *   0 - Success
 *   1 - mainnet-addresses.ts missing
 *   2 - progress file missing / unparseable / wrong chain / not completed / not seeded
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - a source address is missing/zero/malformed, a target key is absent, or a collision
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const DEFAULT_PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.antimatter-pool.1.json');
const DEFAULT_ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const TS_FIELDS = ['AntimatterPoolSeeder', 'AntimatterSusdsPair'];
const HEADER_MARKER = 'Antimatter/sUSDS cutover (story 122)';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function parseArgs(argv) {
    const opts = { progress: DEFAULT_PROGRESS_FILE, addresses: DEFAULT_ADDRESSES_FILE };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if ((a === '--progress' || a === '--addresses') && argv[i + 1]) {
            opts[a.slice(2)] = path.resolve(argv[++i]);
        } else {
            fail(4, `Unknown or incomplete argument: ${a} (expected --progress <path> / --addresses <path>)`);
        }
    }
    return opts;
}

function loadProgress(file) {
    if (!fs.existsSync(file)) fail(2, `Progress file not found: ${file}`);
    let p;
    try {
        p = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
        fail(2, `Progress unparseable: ${e.message}`);
    }
    if (p.chainId !== 1) fail(2, `Progress chainId is ${p.chainId}, expected 1 (mainnet)`);
    if (p.deploymentStatus !== 'completed') {
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (broadcast not finished - resume it)`);
    }
    if (!p.cutover || p.cutover.seeded !== true) fail(2, 'cutover.seeded is not true in the progress file (the seed did not complete)');
    if (!p.contracts || typeof p.contracts !== 'object') fail(2, 'Progress file has no "contracts" object');
    return p;
}

function validAddress(a) {
    return typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a) && a.toLowerCase() !== ZERO_ADDRESS;
}

/** FILL-once replace of `field`'s address literal. */
function fillFlatField(source, field, newAddress) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) return { newSource: source, currentAddress: null, replaced: false };
    const currentAddress = match[2];
    const cur = currentAddress.toLowerCase();
    if (cur !== ZERO_ADDRESS && cur !== newAddress.toLowerCase()) {
        return { newSource: source, currentAddress, replaced: false };
    }
    return { newSource: source.replace(re, `$1"${newAddress}"$3`), currentAddress, replaced: true };
}

function interfaceKeys() {
    if (!fs.existsSync(INTERFACE_FILE)) fail(3, `Interface file not found: ${INTERFACE_FILE}`);
    const src = fs.readFileSync(INTERFACE_FILE, 'utf8');
    const body = src.slice(src.indexOf('{'), src.lastIndexOf('}'));
    return [...body.matchAll(/^\s*([A-Za-z0-9_]+)\s*:\s*string\s*;/gm)].map((m) => m[1]);
}

/** Keys assigned in mainnet-addresses.ts, ignoring commented-out entries. */
function dataKeys(source) {
    const body = source.slice(source.indexOf('mainnetAddresses: ContractAddresses = {'));
    const withoutBlockComments = body.replace(/\/\*[\s\S]*?\*\//g, '');
    const withoutLineComments = withoutBlockComments.replace(/^\s*\/\/.*$/gm, '');
    return [...withoutLineComments.matchAll(/^\s*([A-Za-z0-9_]+)\s*:\s*"0x[0-9a-fA-F]{40}"/gm)].map((m) => m[1]);
}

function run() {
    const opts = parseArgs(process.argv.slice(2));
    const progress = loadProgress(opts.progress);
    if (!fs.existsSync(opts.addresses)) fail(1, `Target file not found: ${opts.addresses}`);
    let source = fs.readFileSync(opts.addresses, 'utf8');

    const lines = [];
    let ok = true;
    let filled = false;
    for (const field of TS_FIELDS) {
        const entry = progress.contracts[field];
        const addr = entry && entry.address;
        if (!validAddress(addr)) fail(4, `progress key "${field}" missing, malformed or zero`);
        const result = fillFlatField(source, field, addr);
        if (result.replaced) {
            source = result.newSource;
            const same = result.currentAddress.toLowerCase() === addr.toLowerCase();
            filled = filled || !same;
            lines.push(`  ${same ? 'SAME' : 'FILL'}     ${field} <- ${addr}`);
        } else if (result.currentAddress) {
            ok = false;
            lines.push(`  COLLIDE  ${field} already=${result.currentAddress}, wanted=${addr}`);
        } else {
            ok = false;
            lines.push(`  MISS-DST ${field} key not found in ${path.basename(opts.addresses)}`);
        }
    }

    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-antimatter-pool (story 122)');
    console.log('==========================================================');
    lines.forEach((l) => console.log(l));
    console.log('==========================================================');
    if (!ok) fail(4, 'AntimatterPoolSeeder / AntimatterSusdsPair could not be safely patched (see summary above); nothing written');

    source = source.replace(
        /^([ \t]*)\/\/ Story 114: the Antimatter\/sUSDS cutover\.[^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*AntimatterPoolSeeder:)/m,
        (m, indent) =>
            `${indent}// Story 114/122: the Antimatter/sUSDS cutover. \`AntimatterPoolSeeder\` converted 10% of the\n` +
            `${indent}// protocol-owned phUSD/sUSDS LP into Antimatter/sUSDS LP, and \`AntimatterSusdsPair\` is the UniV2 pair\n` +
            `${indent}// its seed created. Patched from progress.antimatter-pool.1.json (CutoverAntimatterPoolMainnet).\n`
    );

    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} — AntimatterPoolSeeder + AntimatterSusdsPair FILLED from progress.antimatter-pool.1.json.\n`
        );
    }

    const iface = interfaceKeys();
    const data = dataKeys(source);
    const missingInData = iface.filter((k) => !data.includes(k));
    const extraInData = data.filter((k) => !iface.includes(k));
    console.log(`  key-set: interface=${iface.length}  data=${data.length}`);
    if (missingInData.length || extraInData.length) {
        if (missingInData.length) console.error(`  missing from mainnet-addresses.ts: ${missingInData.join(', ')}`);
        if (extraInData.length) console.error(`  not in ContractAddresses:           ${extraInData.join(', ')}`);
        fail(3, 'key-set drift — mainnet-addresses.ts no longer matches the ContractAddresses interface');
    }

    fs.writeFileSync(opts.addresses, source, 'utf8');
    console.log(`  File written: ${opts.addresses}${filled ? '' : ' (no change: already filled)'}`);
}

run();
