#!/usr/bin/env node
/**
 * patch-mainnet-addresses-v2.js
 *
 * After broadcasting DeployMainnetNFTV2.s.sol, this script patches
 * mainnet-addresses.ts with the real deployed addresses read from
 * broadcast/DeployMainnetNFTV2.s.sol/1/run-latest.json.
 *
 * Rules:
 *   1. Only replaces zero-address placeholders. If a target field is already
 *      populated (non-zero), the script aborts rather than silently overwrite.
 *   2. Handles nested `nftsV2.*` fields and flat `NFTMigrator` field.
 *   3. Strips any trailing `// placeholder` / `// not yet deployed` / `// PLACEHOLDER:`
 *      comment on patched lines.
 *   4. Verifies the broadcast corresponds to the current run by cross-checking
 *      progress.nftv2.1.json (deploymentStatus === "completed").
 *   5. Fails loudly if any expected V2 contract (or the migrator) is missing
 *      from the broadcast log.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - progress.nftv2.1.json missing / not completed
 *   3 - Expected contract not found in broadcast
 *   4 - Address collision: a target field is already set to a non-zero value
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'DeployMainnetNFTV2.s.sol', '1', 'run-latest.json'
);
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.nftv2.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Contracts expected to appear in the broadcast (in deploy order for disambiguation
// of the multiple BurnerV2 CREATE transactions).
const DEPLOY_ORDER = [
    { contractName: 'NFTMinterV2',       tsTarget: { parent: 'nftsV2', field: 'NFTMinter' } },
    { contractName: 'BurnerV2',          tsTarget: { parent: 'nftsV2', field: 'BurnerEYE' } },
    { contractName: 'BurnerV2',          tsTarget: { parent: 'nftsV2', field: 'BurnerSCX' } },
    { contractName: 'BurnerV2',          tsTarget: { parent: 'nftsV2', field: 'BurnerFlax' } },
    { contractName: 'BalancerPoolerV2',  tsTarget: { parent: 'nftsV2', field: 'BalancerPooler' } },
    { contractName: 'GatherV2',          tsTarget: { parent: 'nftsV2', field: 'GatherWBTC' } },
    { contractName: 'NFTMigrator',       tsTarget: { parent: null,     field: 'NFTMigrator' } },
];

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function loadProgress() {
    if (!fs.existsSync(PROGRESS_FILE)) {
        fail(2, `Progress file not found: ${PROGRESS_FILE}`);
    }
    let progress;
    try {
        progress = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
    } catch (err) {
        fail(2, `Progress file unparseable: ${err.message}`);
    }
    if (progress.deploymentStatus !== 'completed') {
        fail(2, `Progress deploymentStatus is "${progress.deploymentStatus}", expected "completed"`);
    }
    return progress;
}

function loadBroadcast() {
    if (!fs.existsSync(BROADCAST_FILE)) {
        fail(1, `Broadcast file not found: ${BROADCAST_FILE}`);
    }
    try {
        return JSON.parse(fs.readFileSync(BROADCAST_FILE, 'utf8'));
    } catch (err) {
        fail(1, `Broadcast file unparseable: ${err.message}`);
    }
}

/**
 * Walk transactions[] in order, filter transactionType === "CREATE", and map them
 * to our expected deploy order. BurnerV2 appears three times — we disambiguate by
 * position, matching the order the deploy script emits them (EYE, SCX, Flax).
 */
function matchDeploysToExpected(broadcast) {
    const creates = (broadcast.transactions || []).filter(
        (tx) => tx.transactionType === 'CREATE'
    );

    const assignments = []; // { tsTarget, address }
    const cursor = { BurnerV2: 0 }; // tracks how many BurnerV2s we've matched so far
    const seen = new Set();

    for (const expected of DEPLOY_ORDER) {
        const cname = expected.contractName;
        let matchedTx = null;

        if (cname === 'BurnerV2') {
            const needed = cursor.BurnerV2;
            let seenOfThisName = 0;
            for (const tx of creates) {
                if (tx.contractName === 'BurnerV2') {
                    if (seenOfThisName === needed) {
                        matchedTx = tx;
                        break;
                    }
                    seenOfThisName += 1;
                }
            }
            cursor.BurnerV2 += 1;
        } else {
            matchedTx = creates.find((tx) => tx.contractName === cname && !seen.has(tx));
        }

        if (!matchedTx) {
            fail(3, `Expected CREATE tx for ${cname} (target ${expected.tsTarget.field}) not found in broadcast`);
        }
        if (!matchedTx.contractAddress) {
            fail(3, `CREATE tx for ${cname} has no contractAddress`);
        }
        seen.add(matchedTx);
        assignments.push({
            tsTarget: expected.tsTarget,
            address: matchedTx.contractAddress,
            contractName: cname,
        });
    }

    return assignments;
}

/**
 * Replace an address inside a nested `parent: { ... field: "0x...", ... }` block,
 * scoped to the first occurrence of `parent:` in the source. This avoids
 * touching the V1 object when patching V2.
 *
 * Returns { newSource, currentAddress, replaced } where:
 *   - replaced === true  means the source was mutated successfully.
 *   - replaced === false && currentAddress is non-null means the field exists
 *     but is already populated with a non-zero address; caller should fail.
 *   - replaced === false && currentAddress === null means the field wasn't found.
 */
function patchNestedField(source, parentKey, field, newAddress) {
    const parentOpenRe = new RegExp(`(${parentKey}:\\s*\\{)`);
    const parentMatch = parentOpenRe.exec(source);
    if (!parentMatch) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const parentStart = parentMatch.index + parentMatch[0].length;

    // Find matching closing brace for the nested object (naive brace matching; our
    // target file has no nested strings with braces inside this object).
    let depth = 1;
    let cursor = parentStart;
    while (cursor < source.length && depth > 0) {
        const ch = source[cursor];
        if (ch === '{') depth += 1;
        else if (ch === '}') depth -= 1;
        if (depth === 0) break;
        cursor += 1;
    }
    if (depth !== 0) {
        return { newSource: source, currentAddress: null, replaced: false };
    }

    const parentBody = source.substring(parentStart, cursor);
    const fieldRe = new RegExp(`(${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)`);
    const fieldMatch = parentBody.match(fieldRe);
    if (!fieldMatch) {
        return { newSource: source, currentAddress: null, replaced: false };
    }

    const currentAddress = fieldMatch[2];
    const trailingContent = fieldMatch[3];
    const cleanTrailing = trailingContent
        .replace(/\s*\/\/\s*not yet deployed.*/i, ',')
        .replace(/\s*\/\/\s*placeholder.*/i, ',')
        .replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');

    if (currentAddress.toLowerCase() !== ZERO_ADDRESS) {
        return { newSource: source, currentAddress, replaced: false };
    }

    const newParentBody = parentBody.replace(
        fieldRe,
        `$1"${newAddress}"${cleanTrailing}`
    );
    const newSource = source.substring(0, parentStart) + newParentBody + source.substring(cursor);
    return { newSource, currentAddress, replaced: true };
}

/**
 * Replace a flat field at the top level of mainnetAddresses. Only replaces
 * zero-address placeholders.
 */
function patchFlatField(source, field, newAddress) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const currentAddress = match[2];
    const trailingContent = match[3];
    const cleanTrailing = trailingContent
        .replace(/\s*\/\/\s*not yet deployed.*/i, ',')
        .replace(/\s*\/\/\s*placeholder.*/i, ',')
        .replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');

    if (currentAddress.toLowerCase() !== ZERO_ADDRESS) {
        return { newSource: source, currentAddress, replaced: false };
    }
    const newSource = source.replace(re, `$1"${newAddress}"${cleanTrailing}`);
    return { newSource, currentAddress, replaced: true };
}

function run() {
    loadProgress();
    const broadcast = loadBroadcast();
    const assignments = matchDeploysToExpected(broadcast);

    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');
    const summary = [];
    let hadCollision = false;

    for (const a of assignments) {
        const result = a.tsTarget.parent
            ? patchNestedField(source, a.tsTarget.parent, a.tsTarget.field, a.address)
            : patchFlatField(source, a.tsTarget.field, a.address);

        if (result.replaced) {
            source = result.newSource;
            const label = a.tsTarget.parent
                ? `${a.tsTarget.parent}.${a.tsTarget.field}`
                : a.tsTarget.field;
            summary.push(`  PATCH  ${label.padEnd(24)} <- ${a.address}  (${a.contractName})`);
        } else if (result.currentAddress && result.currentAddress.toLowerCase() !== ZERO_ADDRESS) {
            const label = a.tsTarget.parent
                ? `${a.tsTarget.parent}.${a.tsTarget.field}`
                : a.tsTarget.field;
            summary.push(`  COLLIDE ${label.padEnd(23)} already=${result.currentAddress}, wanted=${a.address}`);
            hadCollision = true;
        } else {
            const label = a.tsTarget.parent
                ? `${a.tsTarget.parent}.${a.tsTarget.field}`
                : a.tsTarget.field;
            summary.push(`  MISS   ${label.padEnd(24)} field not found in mainnet-addresses.ts`);
            hadCollision = true;
        }
    }

    // Header comment refresh.
    const today = new Date().toISOString().split('T')[0];
    if (!/Updated .*NFT V2 addresses patched/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: NFT V2 addresses patched from broadcast\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-v2 summary');
    console.log('==========================================');
    summary.forEach((line) => console.log(line));
    console.log('==========================================');

    if (hadCollision) {
        fail(4, 'One or more fields could not be safely patched (see summary above)');
    }

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
