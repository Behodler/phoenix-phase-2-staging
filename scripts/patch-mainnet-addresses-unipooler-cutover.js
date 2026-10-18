#!/usr/bin/env node
/**
 * patch-mainnet-addresses-unipooler-cutover.js  (story 103, sprint Balancexit)
 *
 * FILLS the `UniPooler` and `PhusdSusdsPair` keys of `server/deployments/mainnet-addresses.ts` from
 * `server/deployments/progress.unipooler-cutover.1.json` (written by script/DeployMainnetUniPoolerCutover.s.sol).
 *
 * Modelled on patch-mainnet-addresses-stable-staker-v2.js / -uniswap-helper.js. MANDATORY TAIL of
 * `unipooler-cutover:broadcast`, joined with `&&` so it runs only on a zero exit from forge script. The progress
 * file is written during forge's LOCAL execution pass, so after a crashed broadcast it can name contracts that
 * never landed (a crashed forge exits non-zero, so this tail does not run); check the receipts
 * (broadcast/DeployMainnetUniPoolerCutover.s.sol/1/run-latest.json) before ever running it by hand.
 *
 * WHAT IT TOUCHES
 *   FILL `UniPooler`      <- contracts.UniPooler.address       (the new index-4 UniPoolerV2)
 *   FILL `PhusdSusdsPair` <- contracts.PhusdSusdsPair.address  (the phUSD/sUSDS Uniswap V2 pair)
 *   Each overwrites ONLY the zero-address placeholder story 102 left. The SAME address already present is success
 *   (SAME), so a re-run is idempotent; any OTHER non-zero value is a COLLIDE and NOTHING is written (all or none).
 *   Story 102's "zero placeholders until ... story 103 fills them" comment becomes false once filled and is replaced.
 *
 * WHAT IT NEVER DOES
 *   Overwrite `BalancerPooler` (it keeps naming the retired pooler through the wind-down; re-checked byte-for-byte
 *   after patching) or any other key. Add or remove a key: the data file's key-set must exactly equal the
 *   ContractAddresses interface in addresses.ts (the tsc --strict drift guard), re-checked before writing.
 *   Record the escrow (`UniPoolerCutoverEscrow` is not a ContractAddresses key; it stays in the progress file).
 *
 * OPTIONS (for proving the patcher on scratch copies; production runs with none)
 *   --progress <path>    progress file   (default server/deployments/progress.unipooler-cutover.1.json)
 *   --addresses <path>   address book    (default server/deployments/mainnet-addresses.ts)
 *   The ContractAddresses interface is always read from server/deployments/addresses.ts.
 *
 * Exit codes:
 *   0 - Success (file written once)
 *   1 - mainnet-addresses.ts missing
 *   2 - progress file missing / unparseable / wrong chain / deploymentStatus != "completed"
 *   3 - post-patch key-set no longer equals the ContractAddresses interface, or BalancerPooler changed
 *   4 - a source address is missing/zero/malformed, a target key is absent, a collision, or a bad argument
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const DEFAULT_PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.unipooler-cutover.1.json');
const DEFAULT_ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const FIELDS = [
    { tsField: 'UniPooler', progressKey: 'UniPooler' },
    { tsField: 'PhusdSusdsPair', progressKey: 'PhusdSusdsPair' },
];
const PROTECTED_FIELD = 'BalancerPooler';
const HEADER_MARKER = 'UniPoolerV2 index-4 cutover (story 103)';

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
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (broadcast not finished)`);
    }
    if (!p.contracts || typeof p.contracts !== 'object') fail(2, 'Progress file has no "contracts" object');
    return p;
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

function fieldLine(source, field) {
    const m = source.match(new RegExp(`^\\s*${field}:\\s*"0x[0-9a-fA-F]{40}".*$`, 'm'));
    return m ? m[0] : null;
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
    const original = fs.readFileSync(opts.addresses, 'utf8');
    let source = original;
    const protectedBefore = fieldLine(original, PROTECTED_FIELD);

    const lines = [];
    let ok = true;
    let filledAny = false;
    for (const { tsField, progressKey } of FIELDS) {
        const entry = progress.contracts[progressKey];
        const addr = entry && entry.address;
        if (!addr || !/^0x[0-9a-fA-F]{40}$/.test(addr) || addr.toLowerCase() === ZERO_ADDRESS) {
            lines.push(`  MISS-SRC ${tsField} <- progress key "${progressKey}" missing, malformed or zero`);
            ok = false;
            continue;
        }
        const result = fillFlatField(source, tsField, addr);
        if (result.replaced) {
            source = result.newSource;
            const same = result.currentAddress.toLowerCase() === addr.toLowerCase();
            if (!same) filledAny = true;
            lines.push(`  ${same ? 'SAME' : 'FILL'}     ${tsField} <- ${addr}`);
        } else if (result.currentAddress) {
            lines.push(`  COLLIDE  ${tsField} already=${result.currentAddress}, wanted=${addr}`);
            ok = false;
        } else {
            lines.push(`  MISS-DST ${tsField} key not found in ${path.basename(opts.addresses)}`);
            ok = false;
        }
    }

    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-unipooler-cutover (story 103)');
    console.log('==========================================================');
    lines.forEach((l) => console.log(l));
    console.log('==========================================================');
    if (!ok) fail(4, 'UniPooler / PhusdSusdsPair could not be safely patched (see summary above); nothing written');

    // Story 102's placeholder comment is false once filled; replace it.
    source = source.replace(
        /^([ \t]*)\/\/ Story 102 \(Balancexit Stage 1c\): the UniPoolerV2 cutover\.[^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*UniPooler:)/m,
        (m, indent) =>
            `${indent}// Story 103 (Balancexit Stage 2): the UniPoolerV2 index-4 cutover. \`UniPooler\` is the live\n` +
            `${indent}// index-4 dispatcher and \`PhusdSusdsPair\` the phUSD/sUSDS UniV2 pair it zaps into, both\n` +
            `${indent}// patched from progress.unipooler-cutover.1.json by patch-mainnet-addresses-unipooler-cutover.js.\n` +
            `${indent}// \`BalancerPooler\` above keeps naming the retired pooler through the wind-down.\n` +
            `${indent}// \`UniswapV2Router\` is the canonical live UniswapV2 Router02.\n`
    );

    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} — UniPooler + PhusdSusdsPair FILLED from progress.unipooler-cutover.1.json.\n`
        );
    }

    if (fieldLine(source, PROTECTED_FIELD) !== protectedBefore) {
        fail(3, `${PROTECTED_FIELD} would change - refusing (this patcher never touches it)`);
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
    console.log(`  File written: ${opts.addresses}${filledAny ? '' : ' (no address change: already filled)'}`);
}

run();
