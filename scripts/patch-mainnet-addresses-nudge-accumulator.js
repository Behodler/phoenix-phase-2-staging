#!/usr/bin/env node
/**
 * patch-mainnet-addresses-nudge-accumulator.js
 *
 * After broadcasting DeployMainnetNudgeAccumulator.s.sol, this script patches
 * mainnet-addresses.ts with the real deployed addresses read from
 * broadcast/DeployMainnetNudgeAccumulator.s.sol/1/run-latest.json.
 *
 * DIVERGENCE FROM patch-mainnet-addresses-v2.js:
 *   The two prior patchers (v2, nft-staking) refused to overwrite a non-zero
 *   address — they target zero-address placeholders. This patcher must
 *   overwrite the LIVE addresses for `StableYieldAccumulator` and
 *   `BatchNFTMinter`. To stay safe against re-runs and stale broadcasts, the
 *   patcher uses SELF-VALIDATION: it will only overwrite if the existing
 *   address matches the deploy-script's OLD_ACCUMULATOR / OLD_BATCH_MINTER
 *   constant. Any other existing value (already-patched new address, or an
 *   unexpected third-party mutation) triggers exit code 4.
 *
 * Rules:
 *   1. Reads broadcast/DeployMainnetNudgeAccumulator.s.sol/1/run-latest.json.
 *   2. Filters transactionType === "CREATE", maps two CREATE txs by contractName:
 *        - BatchNFTMinter
 *        - StableYieldAccumulator
 *   3. Verifies progress.nudge-accumulator.1.json has deploymentStatus
 *      === "completed" (exit 2 otherwise).
 *   4. Self-validating overwrite for both top-level fields:
 *        - existing field must equal OLD_* constant; otherwise exit 4.
 *   5. Strips any trailing `// not yet deployed` / `// placeholder` /
 *      `// PLACEHOLDER:` comment on patched lines.
 *   6. Adds an `Updated YYYY-MM-DD: nudge accumulator addresses patched`
 *      comment at the top of the file.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - progress.nudge-accumulator.1.json missing / not completed
 *   3 - Expected contract not found in broadcast
 *   4 - Address collision / unexpected old address (self-validation failed)
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'DeployMainnetNudgeAccumulator.s.sol', '1', 'run-latest.json'
);
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.nudge-accumulator.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Must match the constants in script/DeployMainnetNudgeAccumulator.s.sol
const OLD_ACCUMULATOR = '0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E';
const OLD_BATCH_MINTER = '0xD3104A6e6D53b37061856fe1f31296D8962f9e01';

// Contracts expected in the broadcast, in deploy order (BatchNFTMinter first,
// StableYieldAccumulator second; both have unique contractNames so positional
// disambiguation is not strictly required).
const DEPLOY_ORDER = [
    {
        contractName: 'BatchNFTMinter',
        tsField: 'BatchNFTMinter',
        expectedOld: OLD_BATCH_MINTER,
    },
    {
        contractName: 'StableYieldAccumulator',
        tsField: 'StableYieldAccumulator',
        expectedOld: OLD_ACCUMULATOR,
    },
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
 * to our expected deploy order by contractName. Both contracts have unique names,
 * so this is a simple find-by-name match in the order specified by DEPLOY_ORDER.
 */
function matchDeploysToExpected(broadcast) {
    const creates = (broadcast.transactions || []).filter(
        (tx) => tx.transactionType === 'CREATE'
    );

    const assignments = [];
    const seen = new Set();

    for (const expected of DEPLOY_ORDER) {
        const cname = expected.contractName;
        const matchedTx = creates.find((tx) => tx.contractName === cname && !seen.has(tx));
        if (!matchedTx) {
            fail(3, `Expected CREATE tx for ${cname} (target ${expected.tsField}) not found in broadcast`);
        }
        if (!matchedTx.contractAddress) {
            fail(3, `CREATE tx for ${cname} has no contractAddress`);
        }
        seen.add(matchedTx);
        assignments.push({
            tsField: expected.tsField,
            address: matchedTx.contractAddress,
            contractName: cname,
            expectedOld: expected.expectedOld,
        });
    }

    // Defensive: ensure the broadcast has exactly the 2 expected CREATEs.
    if (creates.length !== DEPLOY_ORDER.length) {
        fail(3, `Broadcast has ${creates.length} CREATE transactions; expected exactly ${DEPLOY_ORDER.length} (BatchNFTMinter + StableYieldAccumulator)`);
    }

    return assignments;
}

/**
 * Self-validating flat-field overwrite. Replaces the field's address only when
 * the existing value matches `expectedOld` (the deploy script's OLD_* constant).
 * This protects against:
 *   - Re-running the patcher on a stale broadcast (the existing value would
 *     already be the NEW address, not the OLD one — refused).
 *   - Out-of-band edits (anything other than OLD_* — refused).
 *
 * Returns { newSource, currentAddress, replaced } where:
 *   - replaced === true  means the source was mutated successfully.
 *   - replaced === false && currentAddress is non-null means the field exists
 *     but its value does not match expectedOld; caller should fail with exit 4.
 *   - replaced === false && currentAddress === null means the field wasn't
 *     found at all.
 */
function patchFlatField(source, field, newAddress, expectedOld) {
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

    if (currentAddress.toLowerCase() !== expectedOld.toLowerCase()) {
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
        const result = patchFlatField(source, a.tsField, a.address, a.expectedOld);
        const label = a.tsField;

        if (result.replaced) {
            source = result.newSource;
            summary.push(`  PATCH    ${label.padEnd(28)} ${a.expectedOld} -> ${a.address}  (${a.contractName})`);
        } else if (result.currentAddress) {
            summary.push(
                `  COLLIDE  ${label.padEnd(28)} existing=${result.currentAddress} (expected OLD=${a.expectedOld}); will not overwrite`
            );
            hadCollision = true;
        } else {
            summary.push(`  MISS     ${label.padEnd(28)} field not found in mainnet-addresses.ts`);
            hadCollision = true;
        }
    }

    // Header comment refresh.
    const today = new Date().toISOString().split('T')[0];
    if (!/Updated .*nudge accumulator addresses patched/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: nudge accumulator addresses patched from broadcast\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-nudge-accumulator');
    console.log('==========================================');
    summary.forEach((line) => console.log(line));
    console.log('==========================================');

    if (hadCollision) {
        fail(4, 'One or more fields could not be safely patched — self-validation against OLD_* constants failed (see summary above)');
    }

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
