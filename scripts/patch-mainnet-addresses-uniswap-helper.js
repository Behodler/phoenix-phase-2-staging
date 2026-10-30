#!/usr/bin/env node
/**
 * patch-mainnet-addresses-uniswap-helper.js  (story 111, sprint Balancexit; REPOINT mode story 122)
 *
 * REPOINTS the `UniswapHelper` key of `server/deployments/mainnet-addresses.ts` to the Antimatter-aware helper
 * recorded in `server/deployments/progress.uniswap-helper-am.1.json` (written by script/DeployUniswapHelperMainnet.s.sol
 * since story 122). The story-111 progress file `progress.uniswap-helper.1.json` is history and is never read.
 *
 * MANDATORY TAIL of `uniswap-helper:broadcast`, joined with `&&` so it runs only on a zero exit from forge script.
 * The progress file is written during forge's LOCAL execution pass, so after a crashed broadcast it can name a
 * contract that never landed; check the receipt (broadcast/DeployUniswapHelperMainnet.s.sol/1/run-latest.json) first.
 *
 * WHAT IT TOUCHES
 *   REPOINT `UniswapHelper` (story 092/082 guarded-overwrite pattern): overwrite ONLY when the current value is EXACTLY
 *   the story-111 helper 0x564810D5d9D31754C8dbdb8F62Bb429D50Dfa5b3 (logs `REPOINT ... (was ...)`); the SAME new
 *   address already present is success (idempotent re-run); ANY other value - including zero - is a COLLIDE and
 *   nothing is written. The story-111 comment above the key is replaced.
 *
 * WHAT IT NEVER DOES
 *   Add or remove a key. The data file's key-set must exactly equal the ContractAddresses interface in
 *   addresses.ts (the tsc --strict drift guard); re-checked after patching, before writing.
 *   Touch `AntimatterSusdsPair` / `PhusdSusdsPair`: those belong to the cutover patchers.
 *
 * OPTIONS (for proving the patcher on scratch copies; production runs with none)
 *   --progress <path>    progress file   (default server/deployments/progress.uniswap-helper-am.1.json)
 *   --addresses <path>   address book    (default server/deployments/mainnet-addresses.ts)
 *   The ContractAddresses interface is always read from server/deployments/addresses.ts.
 *
 * Exit codes:
 *   0 - Success
 *   1 - mainnet-addresses.ts missing
 *   2 - progress file missing / unparseable / wrong chain / deploymentStatus != "completed"
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - the source address is missing/zero/malformed, the target key is absent, or a collision
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const DEFAULT_PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.uniswap-helper-am.1.json');
const DEFAULT_ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const TS_FIELD = 'UniswapHelper';
const PROGRESS_KEY = 'UniswapHelper';
const HEADER_MARKER = 'UniswapHelper REPOINTED (story 122)';
// The story-111 helper (pre-story-120, no Antimatter routes). The only value REPOINT may overwrite.
const PREVIOUS_HELPER = '0x564810D5d9D31754C8dbdb8F62Bb429D50Dfa5b3';

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

/** Guarded REPOINT of `field`: from exactly PREVIOUS_HELPER, or already `newAddress` (SAME). */
function repointFlatField(source, field, newAddress) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) return { newSource: source, currentAddress: null, replaced: false };
    const currentAddress = match[2];
    const cur = currentAddress.toLowerCase();
    if (cur !== PREVIOUS_HELPER.toLowerCase() && cur !== newAddress.toLowerCase()) {
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

    const entry = progress.contracts[PROGRESS_KEY];
    const addr = entry && entry.address;
    if (!addr || !/^0x[0-9a-fA-F]{40}$/.test(addr) || addr.toLowerCase() === ZERO_ADDRESS) {
        fail(4, `progress key "${PROGRESS_KEY}" missing, malformed or zero`);
    }
    if (addr.toLowerCase() === PREVIOUS_HELPER.toLowerCase()) {
        fail(4, `progress names the OLD story-111 helper ${PREVIOUS_HELPER}; expected the story-122 redeploy`);
    }

    let line;
    let filled = false;
    const result = repointFlatField(source, TS_FIELD, addr);
    if (result.replaced) {
        source = result.newSource;
        const same = result.currentAddress.toLowerCase() === addr.toLowerCase();
        filled = !same;
        line = same
            ? `  SAME     ${TS_FIELD} <- ${addr}`
            : `  REPOINT  ${TS_FIELD} <- ${addr} (was ${result.currentAddress})`;
    } else if (result.currentAddress) {
        line = `  COLLIDE  ${TS_FIELD} already=${result.currentAddress}, wanted=${addr} (REPOINT only from ${PREVIOUS_HELPER})`;
    } else {
        line = `  MISS-DST ${TS_FIELD} key not found in ${path.basename(opts.addresses)}`;
    }

    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-uniswap-helper (story 122 REPOINT)');
    console.log('==========================================================');
    console.log(line);
    console.log('==========================================================');
    if (!result.replaced) fail(4, 'UniswapHelper could not be safely patched (see summary above)');

    // Story 111's comment above the key describes the old helper; replace it.
    source = source.replace(
        /^([ \t]*)\/\/ Story 111: one-tx phUSD swaps \+ phUSD\/sUSDS liquidity periphery \(UniswapHelper\)[^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*UniswapHelper:)/m,
        (m, indent) =>
            `${indent}// Story 111/120/122: one-tx phUSD + Antimatter swaps and phUSD/sUSDS + AM/sUSDS liquidity periphery\n` +
            `${indent}// (UniswapHelper, 15-arg story-120 build), redeployed after the AM/sUSDS cutover by DeployUniswapHelperMainnet\n` +
            `${indent}// and REPOINTED from ${PREVIOUS_HELPER} via progress.uniswap-helper-am.1.json.\n`
    );

    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} — UniswapHelper REPOINTED from ${PREVIOUS_HELPER} via progress.uniswap-helper-am.1.json.\n`
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
    console.log(`  File written: ${opts.addresses}${filled ? '' : ' (no change: already repointed)'}`);
}

run();
