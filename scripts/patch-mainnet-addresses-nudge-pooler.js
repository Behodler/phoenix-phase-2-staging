#!/usr/bin/env node
/**
 * patch-mainnet-addresses-nudge-pooler.js
 *
 * After broadcasting DeployMainnetNudgePoolerV2.s.sol, this script patches
 * mainnet-addresses.ts with the real deployed addresses read from
 * broadcast/DeployMainnetNudgePoolerV2.s.sol/1/run-latest.json.
 *
 * Patches three fields (all self-validating — refuses to overwrite anything
 * other than the deploy script's OLD_* constants):
 *
 *   1. StableYieldAccumulator (top-level, line 28)      expected old = OLD_ACCUMULATOR
 *   2. nftsV2.BalancerPooler  (nested, line 75)         expected old = OLD_BALANCER_POOLER_V2
 *   3. BatchNFTMinter         (top-level, line 87)      expected old = OLD_BATCH_MINTER
 *
 * The WaUSDC field (line 86) is INTENTIONALLY NOT touched — that is set
 * manually by the agent before broadcast.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - progress.nudge-pooler.1.json missing or deploymentStatus != "completed"
 *   3 - Expected contract not found in broadcast
 *   4 - Address collision / unexpected old address (self-validation failed)
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'DeployMainnetNudgePoolerV2.s.sol', '1', 'run-latest.json'
);
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.nudge-pooler.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Must match the constants in script/DeployMainnetNudgePoolerV2.s.sol
const OLD_ACCUMULATOR = '0xb9639e6Be92033F55E6D9E375Fd1C28ceEdbA50E';
const OLD_BATCH_MINTER = '0xD3104A6e6D53b37061856fe1f31296D8962f9e01';
const OLD_BALANCER_POOLER_V2 = '0x6e957842AFBCD01cE9DB296D173F39134b362771';

// Deploy order in the broadcast matches the script's run() ordering:
//   1. BatchNFTMinter        -> top-level BatchNFTMinter
//   2. StableYieldAccumulator -> top-level StableYieldAccumulator
//   3. BalancerPoolerV2       -> nested nftsV2.BalancerPooler
const DEPLOY_ORDER = [
    {
        contractName: 'BatchNFTMinter',
        kind: 'flat',
        tsField: 'BatchNFTMinter',
        expectedOld: OLD_BATCH_MINTER,
    },
    {
        contractName: 'StableYieldAccumulator',
        kind: 'flat',
        tsField: 'StableYieldAccumulator',
        expectedOld: OLD_ACCUMULATOR,
    },
    {
        contractName: 'BalancerPoolerV2',
        kind: 'nested',
        parentKey: 'nftsV2',
        childField: 'BalancerPooler',
        expectedOld: OLD_BALANCER_POOLER_V2,
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
 * Walk transactions[], filter transactionType === "CREATE", and map them
 * to expected deploys by contractName. Each expected contract has a unique
 * contractName so find-by-name suffices.
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
            const labelTarget = expected.kind === 'nested'
                ? `${expected.parentKey}.${expected.childField}`
                : expected.tsField;
            fail(3, `Expected CREATE tx for ${cname} (target ${labelTarget}) not found in broadcast`);
        }
        if (!matchedTx.contractAddress) {
            fail(3, `CREATE tx for ${cname} has no contractAddress`);
        }
        seen.add(matchedTx);
        assignments.push({
            ...expected,
            address: matchedTx.contractAddress,
        });
    }

    // Defensive: broadcast should contain exactly the expected count of CREATEs.
    if (creates.length !== DEPLOY_ORDER.length) {
        fail(3, `Broadcast has ${creates.length} CREATE transactions; expected exactly ${DEPLOY_ORDER.length} (BatchNFTMinter + StableYieldAccumulator + BalancerPoolerV2)`);
    }

    return assignments;
}

/**
 * Self-validating flat-field overwrite. Replaces a top-level field's address
 * only when the existing value matches `expectedOld`.
 *
 * Returns { newSource, currentAddress, replaced }.
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

/**
 * Self-validating nested-field overwrite. Locates the named parent object
 * (`parentKey: { ... }`) and replaces the `childField` line within it.
 *
 * The regex scans from the parent block's opening `{` to its matching closing
 * `}` and only mutates a `childField: "0x…"` line within that span. To keep
 * the regex tractable we use a multiline match anchored to a `\s*<parentKey>:\s*{`
 * header, then a non-greedy span up to the next top-level `},` or `}` followed
 * by a newline + outdented context.
 *
 * Returns { newSource, currentAddress, replaced } with the same semantics as
 * patchFlatField.
 */
function patchNestedField(source, parentKey, childField, newAddress, expectedOld) {
    // Locate the parent block. Capture indent depth so we can constrain the span.
    const headerRe = new RegExp(`(^[ \\t]*${parentKey}:\\s*\\{[\\s\\S]*?\\n[ \\t]*\\},)`, 'm');
    const headerMatch = source.match(headerRe);
    if (!headerMatch) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const block = headerMatch[1];

    // Within the captured block, find the childField line.
    const childRe = new RegExp(`(^[ \\t]+${childField}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const childMatch = block.match(childRe);
    if (!childMatch) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const currentAddress = childMatch[2];
    const trailingContent = childMatch[3];
    const cleanTrailing = trailingContent
        .replace(/\s*\/\/\s*not yet deployed.*/i, ',')
        .replace(/\s*\/\/\s*placeholder.*/i, ',')
        .replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');

    if (currentAddress.toLowerCase() !== expectedOld.toLowerCase()) {
        return { newSource: source, currentAddress, replaced: false };
    }

    const newBlock = block.replace(childRe, `$1"${newAddress}"${cleanTrailing}`);
    const newSource = source.replace(block, newBlock);
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
        let result;
        let label;
        if (a.kind === 'flat') {
            result = patchFlatField(source, a.tsField, a.address, a.expectedOld);
            label = a.tsField;
        } else {
            result = patchNestedField(source, a.parentKey, a.childField, a.address, a.expectedOld);
            label = `${a.parentKey}.${a.childField}`;
        }

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
    if (!/Updated .*nudge-pooler addresses patched/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: nudge-pooler addresses patched from broadcast\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-nudge-pooler');
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
