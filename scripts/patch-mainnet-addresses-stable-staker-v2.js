#!/usr/bin/env node
/**
 * patch-mainnet-addresses-stable-staker-v2.js  (story 082)
 *
 * FILLS the `StableStakerV2` and `Antimatter` keys of `server/deployments/mainnet-addresses.ts`
 * from the StableStaker V1 -> V2 cutover's progress file, BY NAME.
 *
 * Modelled on patch-mainnet-addresses-promotion-ready.js. Do NOT use the stale
 * patch-mainnet-addresses-stable-staker.js: it writes a `StableStaker` key that no longer exists
 * in the ContractAddresses interface (story 080 retired it).
 *
 * MANDATORY TAIL of `stable-staker-v2-cutover:broadcast`, joined with `&&` so it runs only on a
 * zero exit from forge script. The progress file is written during forge's LOCAL execution pass,
 * so after a crashed broadcast it can name a contract that never landed; this script therefore
 * refuses anything but `deploymentStatus == "completed"`, and on a resumed run the operator must
 * first trim the file to on-chain-confirmed deployments (run-latest.json receipts + `cast nonce`).
 *
 * WHAT IT TOUCHES
 *   FILL (overwrite ONLY a zero-address placeholder; the SAME address already present is success,
 *   which keeps a resume leg idempotent; any OTHER non-zero value is a collision):
 *     StableStakerV2, Antimatter
 *     YieldStrategyDolaLegacy <- 0x1760E05356Ec1FBBA159C730781dCfB9920524e2 (story 092: the retired autoDOLA strategy)
 *   OVERWRITE (story 092, saga2-deploy pattern, logs `PATCH field <- new (was old)`), guarded: only when the current
 *   value is EXACTLY the retired autoDOLA strategy; already the new address is SAME; anything else is a COLLISION:
 *     YieldStrategyDola <- contracts.ERC4626YieldStrategySDOLA (the sDOLA strategy the cutover deployed and moved the
 *     V2 DOLA pool, the PhusdStableMinter's DOLA collateral and SYA onto). Consumers of the key switch to sDOLA - the
 *     meaning story 089 gave the key.
 *   CONFIRM (never written): SDOLA must already equal 0xb45ad160634c528Cc3D2926d9807104FA3157305, else COLLISION.
 *   The transient `CrossVersionMigrator` has a progress-file record but deliberately NO key.
 *
 * WHAT IT NEVER DOES
 *   Add or remove a key. The data file's key-set must exactly equal the ContractAddresses
 *   interface in addresses.ts (the tsc --strict drift guard); re-checked after patching.
 *
 * Exit codes:
 *   0 - Success
 *   1 - mainnet-addresses.ts missing
 *   2 - progress file missing / unparseable / deploymentStatus != "completed"
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - a source address is missing/zero, a target field is absent, or a collision
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.stable-staker-v2-cutover.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const FIELDS = [
    { tsField: 'StableStakerV2', progressKey: 'StableStakerV2' },
    { tsField: 'Antimatter', progressKey: 'Antimatter' },
];

// Story 092. Constants mirror script/CutoverStableStakerV2Mainnet.s.sol (YS_DOLA, SDOLA).
const AUTODOLA_STRATEGY = '0x1760E05356Ec1FBBA159C730781dCfB9920524e2';
const SDOLA_VAULT = '0xb45ad160634c528Cc3D2926d9807104FA3157305';
const SDOLA_STRATEGY_PROGRESS_KEY = 'ERC4626YieldStrategySDOLA';

const HEADER_MARKER = 'StableStaker V1 -> V2 cutover';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function loadProgress() {
    if (!fs.existsSync(PROGRESS_FILE)) fail(2, `Progress file not found: ${PROGRESS_FILE}`);
    let p;
    try {
        p = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
    } catch (e) {
        fail(2, `Progress unparseable: ${e.message}`);
    }
    if (p.chainId !== 1) fail(2, `Progress chainId is ${p.chainId}, expected 1 (mainnet)`);
    if (p.deploymentStatus !== 'completed') {
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (broadcast not finished, or a resume leg is outstanding)`);
    }
    if (!p.contracts || typeof p.contracts !== 'object') fail(2, 'Progress file has no "contracts" object');
    return p;
}

/** Current address literal of `field`, or null when the key is absent. */
function readFlatField(source, field) {
    const m = source.match(new RegExp(`^\\s*${field}:\\s*"(0x[0-9a-fA-F]{40})"`, 'm'));
    return m ? m[1] : null;
}

/** Unconditional replace of `field`'s address literal (callers guard the current value first). */
function overwriteFlatField(source, field, newAddress) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    return source.replace(re, `$1"${newAddress}"$3`);
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
    const progress = loadProgress();
    if (!fs.existsSync(ADDRESSES_FILE)) fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

    const summary = [];
    let bad = false;
    let filledAny = false;

    for (const f of FIELDS) {
        const entry = progress.contracts[f.progressKey];
        if (!entry || !entry.address || entry.address.toLowerCase() === ZERO_ADDRESS) {
            summary.push(`  MISS-SRC ${f.tsField.padEnd(16)} progress key "${f.progressKey}" missing or zero`);
            bad = true;
            continue;
        }
        const result = fillFlatField(source, f.tsField, entry.address);
        if (result.replaced) {
            source = result.newSource;
            const same = result.currentAddress.toLowerCase() === entry.address.toLowerCase();
            if (!same) filledAny = true;
            summary.push(`  ${same ? 'SAME' : 'FILL'}     ${f.tsField.padEnd(16)} <- ${entry.address}`);
        } else if (result.currentAddress) {
            summary.push(`  COLLIDE  ${f.tsField.padEnd(16)} already=${result.currentAddress}, wanted=${entry.address}`);
            bad = true;
        } else {
            summary.push(`  MISS-DST ${f.tsField.padEnd(16)} key not found in mainnet-addresses.ts`);
            bad = true;
        }
    }

    // ---- Story 092: DOLA strategy keys ----
    const sdolaEntry = progress.contracts[SDOLA_STRATEGY_PROGRESS_KEY];
    const newYs = sdolaEntry && sdolaEntry.address;
    const sameAddr = (a, b) => a && b && a.toLowerCase() === b.toLowerCase();
    if (!newYs || newYs.toLowerCase() === ZERO_ADDRESS || !/^0x[0-9a-fA-F]{40}$/.test(newYs)) {
        summary.push(`  MISS-SRC YieldStrategyDola progress key "${SDOLA_STRATEGY_PROGRESS_KEY}" missing or zero`);
        bad = true;
    } else if (sameAddr(newYs, AUTODOLA_STRATEGY)) {
        summary.push(`  COLLIDE  YieldStrategyDola progress names the retired autoDOLA strategy ${newYs} as the sDOLA strategy`);
        bad = true;
    } else {
        const cur = readFlatField(source, 'YieldStrategyDola');
        if (cur === null) {
            summary.push('  MISS-DST YieldStrategyDola key not found in mainnet-addresses.ts');
            bad = true;
        } else if (sameAddr(cur, newYs)) {
            summary.push(`  SAME     YieldStrategyDola <- ${newYs}`);
        } else if (sameAddr(cur, AUTODOLA_STRATEGY)) {
            source = overwriteFlatField(source, 'YieldStrategyDola', newYs);
            filledAny = true;
            summary.push(`  PATCH    YieldStrategyDola <- ${newYs} (was ${cur})`);
        } else {
            summary.push(`  COLLIDE  YieldStrategyDola already=${cur}, expected ${AUTODOLA_STRATEGY} (to overwrite) or ${newYs}`);
            bad = true;
        }
    }
    {
        const result = fillFlatField(source, 'YieldStrategyDolaLegacy', AUTODOLA_STRATEGY);
        if (result.replaced) {
            source = result.newSource;
            const same = sameAddr(result.currentAddress, AUTODOLA_STRATEGY);
            if (!same) filledAny = true;
            summary.push(`  ${same ? 'SAME' : 'FILL'}     YieldStrategyDolaLegacy <- ${AUTODOLA_STRATEGY}`);
        } else if (result.currentAddress) {
            summary.push(`  COLLIDE  YieldStrategyDolaLegacy already=${result.currentAddress}, wanted=${AUTODOLA_STRATEGY}`);
            bad = true;
        } else {
            summary.push('  MISS-DST YieldStrategyDolaLegacy key not found in mainnet-addresses.ts');
            bad = true;
        }
    }
    {
        const cur = readFlatField(source, 'SDOLA');
        if (sameAddr(cur, SDOLA_VAULT)) {
            summary.push(`  SAME     SDOLA             == ${SDOLA_VAULT} (confirmed, not written)`);
        } else {
            summary.push(`  COLLIDE  SDOLA             already=${cur}, expected ${SDOLA_VAULT}`);
            bad = true;
        }
    }
    // Story 089's "PENDING CHANGE IN MEANING" and zero-placeholder comments are false once patched; replace them.
    source = source.replace(
        /^([ \t]*)\/\/ Story 089 — PENDING CHANGE IN MEANING\.[^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*YieldStrategyDola:)/m,
        (m, indent) =>
            `${indent}// Story 092: YieldStrategyDola is the sDOLA ERC4626YieldStrategy deployed by the StableStaker V2 cutover\n` +
            `${indent}// (Phase 3b) - V2's DOLA pool, the PhusdStableMinter's DOLA collateral and SYA all use it.\n`
    );
    source = source.replace(
        /^([ \t]*)\/\/ Story 089: zero placeholder keeping the key-set equal to ContractAddresses;[^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*YieldStrategyDolaLegacy:)/m,
        (m, indent) =>
            `${indent}// Story 092: the autoDOLA strategy, RETIRED by the cutover (no clients, SYA removed, pauser OWNER,\n` +
            `${indent}// unregistered from the Pauser, paused). Kept for history; nothing should route through it.\n`
    );

    // The two keys were introduced as zero placeholders by story 080 with a comment block saying
    // they are not deployed yet. Once filled that comment is false; replace it.
    source = source.replace(
        /^([ \t]*)\/\/ Neither StableStakerV2 nor Antimatter is deployed on mainnet yet;[^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*StableStakerV2:)/m,
        (m, indent) =>
            `${indent}// Story 082: StableStakerV2 and Antimatter deployed by the V1 -> V2 cutover and patched\n` +
            `${indent}// from progress.stable-staker-v2-cutover.1.json. V1 is drained (every pool Migrating,\n` +
            `${indent}// phUSD mint revoked) and retired: paused, and unregistered from the Pauser (story 083);\n` +
            `${indent}// the transient CrossVersionMigrator deliberately has no key.\n`
    );

    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} (story 082) — StableStakerV2 + Antimatter FILLED from\n` +
                `// progress.stable-staker-v2-cutover.1.json; V1 users migrated via a transient CrossVersionMigrator.\n` +
                `// Story 092: YieldStrategyDola -> the sDOLA strategy; YieldStrategyDolaLegacy -> retired 0x1760 autoDOLA strategy.\n`
        );
    }

    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-stable-staker-v2 (stories 082 + 092)');
    console.log('==========================================================');
    summary.forEach((l) => console.log(l));
    console.log('==========================================================');

    if (bad) fail(4, 'One or more fields could not be safely patched (see summary above)');

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

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}${filledAny ? '' : ' (no change: already filled)'}`);
}

run();
