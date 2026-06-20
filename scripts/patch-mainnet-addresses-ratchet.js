#!/usr/bin/env node
/**
 * patch-mainnet-addresses-ratchet.js
 *
 * After broadcasting DeployMainnetNudgeRatchet.s.sol, this script patches
 * mainnet-addresses.ts with the real deployed addresses read from
 * broadcast/DeployMainnetNudgeRatchet.s.sol/1/run-latest.json.
 *
 * Rules:
 *   1. The four ratchet fields (NudgeRatchet, NudgeRatchetMintDebtHook,
 *      RatchetNFTStaker, RatchetBatchNFTMinter) are zero-address placeholders and
 *      are only patched when currently zero; a non-zero value aborts (collision).
 *   2. MintPageView is an UPDATE: the field currently holds the old (live) view.
 *      It is replaced unconditionally with the new deployed address.
 *   3. Strips any trailing `// not yet deployed` / `// placeholder` /
 *      `// PLACEHOLDER:` comment on patched lines.
 *   4. Verifies the broadcast corresponds to the current run by cross-checking
 *      progress.nudge-ratchet.1.json (deploymentStatus === "completed").
 *   5. Fails loudly if any expected contract is missing from the broadcast log.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - progress.nudge-ratchet.1.json missing / not completed
 *   3 - Expected contract not found in broadcast
 *   4 - Address collision: a zero-placeholder field is already set to a non-zero value,
 *       or a field could not be found in mainnet-addresses.ts
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'DeployMainnetNudgeRatchet.s.sol', '1', 'run-latest.json'
);
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.nudge-ratchet.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Contracts expected to appear in the broadcast in deploy order. Each is a distinct
// contractName EXCEPT BatchNFTMinter — the ratchet batch minter is a BatchNFTMinter
// instance, so its broadcast contractName is "BatchNFTMinter". It is the only
// BatchNFTMinter CREATE in this script's broadcast, so a name match is unambiguous.
//
// `update: true`  -> replace whatever is there (MintPageView).
// `update: false` -> only replace a zero-address placeholder (the four ratchet fields).
const DEPLOY_ORDER = [
    { contractName: 'BatchNFTMinter',           tsField: 'RatchetBatchNFTMinter',    update: false },
    { contractName: 'NudgeRatchet',             tsField: 'NudgeRatchet',             update: false },
    { contractName: 'NudgeRatchetMintDebtHook', tsField: 'NudgeRatchetMintDebtHook', update: false },
    { contractName: 'NFTStakerPriceScaled',     tsField: 'RatchetNFTStaker',         update: false },
    { contractName: 'MintPageView',             tsField: 'MintPageView',             update: true },
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
 * Walk transactions[] in order, filter transactionType === "CREATE", and map each
 * expected contract to its CREATE tx by contractName, consuming matches in order so
 * duplicate names (none here, but defensive) resolve positionally.
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
            update: expected.update,
        });
    }

    return assignments;
}

/**
 * Replace a flat field at the top level of mainnetAddresses.
 *   update === false -> only replaces zero-address placeholders (abort on non-zero).
 *   update === true  -> replaces unconditionally (used for MintPageView).
 */
function patchFlatField(source, field, newAddress, update) {
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

    if (!update && currentAddress.toLowerCase() !== ZERO_ADDRESS) {
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
        const result = patchFlatField(source, a.tsField, a.address, a.update);
        const label = a.tsField;

        if (result.replaced) {
            source = result.newSource;
            const verb = a.update ? 'UPDATE' : 'PATCH ';
            summary.push(`  ${verb} ${label.padEnd(28)} <- ${a.address}  (${a.contractName})`);
        } else if (result.currentAddress && result.currentAddress.toLowerCase() !== ZERO_ADDRESS) {
            summary.push(`  COLLIDE ${label.padEnd(27)} already=${result.currentAddress}, wanted=${a.address}`);
            hadCollision = true;
        } else {
            summary.push(`  MISS   ${label.padEnd(28)} field not found in mainnet-addresses.ts`);
            hadCollision = true;
        }
    }

    // Datestamped header comment refresh (append-only, mirrors the nft-staking patcher).
    const today = new Date().toISOString().split('T')[0];
    if (!/Updated .*NudgeRatchet infrastructure deployed/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: NudgeRatchet infrastructure deployed to mainnet (story 069); ratchet addresses + MintPageView patched from broadcast\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-ratchet summary');
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
