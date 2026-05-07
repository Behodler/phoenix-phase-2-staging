#!/usr/bin/env node
/**
 * patch-mainnet-addresses-nft-staking.js
 *
 * After broadcasting DeployMainnetNFTStaking.s.sol, this script patches
 * mainnet-addresses.ts with the real deployed addresses read from
 * broadcast/DeployMainnetNFTStaking.s.sol/1/run-latest.json.
 *
 * Rules:
 *   1. Only replaces zero-address placeholders. If a target field is already
 *      populated (non-zero), the script aborts rather than silently overwrite.
 *   2. Patches three flat top-level fields: BalancerPoolerMintDebtHook,
 *      NFTStaker, BatchNFTMinter.
 *   3. Strips any trailing `// not yet deployed` / `// placeholder` /
 *      `// PLACEHOLDER:` comment on patched lines.
 *   4. Verifies the broadcast corresponds to the current run by cross-checking
 *      progress.nft-staking.1.json (deploymentStatus === "completed").
 *   5. Fails loudly if any expected contract is missing from the broadcast log.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - progress.nft-staking.1.json missing / not completed
 *   3 - Expected contract not found in broadcast
 *   4 - Address collision: a target field is already set to a non-zero value
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'DeployMainnetNFTStaking.s.sol', '1', 'run-latest.json'
);
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.nft-staking.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Contracts expected to appear in the broadcast in deploy order. Each is a
// distinct contractName, so positional disambiguation is unnecessary.
const DEPLOY_ORDER = [
    { contractName: 'BalancerPoolerMintDebtHook', tsTarget: { parent: null, field: 'BalancerPoolerMintDebtHook' } },
    { contractName: 'NFTStaker',                  tsTarget: { parent: null, field: 'NFTStaker' } },
    { contractName: 'BatchNFTMinter',             tsTarget: { parent: null, field: 'BatchNFTMinter' } },
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
 * Walk transactions[] in order, filter transactionType === "CREATE", and map
 * them to our expected deploy order. All three contracts have unique names,
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
        const result = patchFlatField(source, a.tsTarget.field, a.address);
        const label = a.tsTarget.field;

        if (result.replaced) {
            source = result.newSource;
            summary.push(`  PATCH  ${label.padEnd(30)} <- ${a.address}  (${a.contractName})`);
        } else if (result.currentAddress && result.currentAddress.toLowerCase() !== ZERO_ADDRESS) {
            summary.push(`  COLLIDE ${label.padEnd(29)} already=${result.currentAddress}, wanted=${a.address}`);
            hadCollision = true;
        } else {
            summary.push(`  MISS   ${label.padEnd(30)} field not found in mainnet-addresses.ts`);
            hadCollision = true;
        }
    }

    // Strip the section header comment for NFT staking now that addresses are filled in.
    source = source.replace(
        /^\s*\/\/\s*NFT staking — not yet deployed.*\r?\n/m,
        '  // NFT staking\n'
    );

    // Header comment refresh.
    const today = new Date().toISOString().split('T')[0];
    if (!/Updated .*NFT staking addresses patched/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: NFT staking addresses patched from broadcast\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-nft-staking summary');
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
