#!/usr/bin/env node
/**
 * patch-mainnet-addresses-uniboost-cutover.js
 *
 * Story 071. After broadcasting DeployMainnetUniboostCutover.s.sol, this script patches
 * server/deployments/mainnet-addresses.ts with the real deployed addresses read from
 * broadcast/DeployMainnetUniboostCutover.s.sol/1/run-latest.json.
 *
 * It fills the ten zero-address Uniboost placeholders and updates the two ratchet keys:
 *
 *   Fill (update:false, only replaces a zero-address placeholder; abort on non-zero collision):
 *     UniboostEYE, UniboostSCX, UniboostFLX,
 *     UniboostHookEYE, UniboostHookSCX, UniboostHookFLX,
 *     UniboostStakerEYE, UniboostStakerSCX, UniboostStakerFLX,
 *     MultiPooler
 *
 *   Update (update:true, replaces the live old value unconditionally):
 *     NudgeRatchet             (0x7a4ed1.. -> new NudgeRatchetDelayRelease)
 *     NudgeRatchetMintDebtHook (0xdcddb2.. -> new hook)
 *
 * mainnet-addresses.ts is HAND-MAINTAINED — this script only fills/updates values; it
 * never adds or removes keys (the key-set must stay == the ContractAddresses interface,
 * 55 keys). It cannot be run until AFTER a real broadcast produces the run-latest.json.
 *
 * Positional matching: several contracts share a broadcast `contractName` (three Uniboost,
 * three UniboostMintDebtHook, three NFTStakerDepletion). The DEPLOY_ORDER below lists each
 * repeated name once per instance in the EXACT order the script deploys them (EYE, SCX,
 * FLX), and CREATE txs are consumed positionally so duplicate names resolve deterministically.
 *
 * Verifies the broadcast corresponds to this run by cross-checking
 * progress.uniboost-cutover.1.json (deploymentStatus === "completed").
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing/unparseable, or target addresses file missing
 *   2 - progress.uniboost-cutover.1.json missing / not "completed"
 *   3 - Expected contract not found in broadcast
 *   4 - Address collision (a zero-placeholder field already holds a non-zero value) or a
 *       field could not be found in mainnet-addresses.ts
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'DeployMainnetUniboostCutover.s.sol', '1', 'run-latest.json'
);
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.uniboost-cutover.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Deploy order MUST match the CREATE order in the broadcast (see the script's phases).
// Repeated contractNames are consumed positionally in EYE -> SCX -> FLX order.
//   update: false -> only replace a zero-address placeholder (abort on non-zero).
//   update: true  -> replace whatever is there (the two live ratchet keys).
const DEPLOY_ORDER = [
    { contractName: 'Uniboost',                 tsField: 'UniboostEYE',              update: false },
    { contractName: 'Uniboost',                 tsField: 'UniboostSCX',              update: false },
    { contractName: 'Uniboost',                 tsField: 'UniboostFLX',              update: false },
    { contractName: 'UniboostMintDebtHook',     tsField: 'UniboostHookEYE',          update: false },
    { contractName: 'UniboostMintDebtHook',     tsField: 'UniboostHookSCX',          update: false },
    { contractName: 'UniboostMintDebtHook',     tsField: 'UniboostHookFLX',          update: false },
    { contractName: 'MultiPooler',              tsField: 'MultiPooler',              update: false },
    { contractName: 'NFTStakerDepletion',       tsField: 'UniboostStakerEYE',        update: false },
    { contractName: 'NFTStakerDepletion',       tsField: 'UniboostStakerSCX',        update: false },
    { contractName: 'NFTStakerDepletion',       tsField: 'UniboostStakerFLX',        update: false },
    { contractName: 'NudgeRatchetDelayRelease', tsField: 'NudgeRatchet',             update: true  },
    { contractName: 'NudgeRatchetMintDebtHook', tsField: 'NudgeRatchetMintDebtHook', update: true  },
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
 * Walk transactions[] in order, filter transactionType === "CREATE", and map each expected
 * contract to its CREATE tx by contractName, consuming matches in order so duplicate names
 * (Uniboost x3, UniboostMintDebtHook x3, NFTStakerDepletion x3) resolve positionally.
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
 *   update === true  -> replaces unconditionally (the two ratchet keys).
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
            summary.push(`  ${verb} ${label.padEnd(24)} <- ${a.address}  (${a.contractName})`);
        } else if (result.currentAddress && result.currentAddress.toLowerCase() !== ZERO_ADDRESS) {
            summary.push(`  COLLIDE ${label.padEnd(23)} already=${result.currentAddress}, wanted=${a.address}`);
            hadCollision = true;
        } else {
            summary.push(`  MISS   ${label.padEnd(24)} field not found in mainnet-addresses.ts`);
            hadCollision = true;
        }
    }

    // Datestamped header comment refresh (append-only; distinct marker from the ratchet patcher).
    const today = new Date().toISOString().split('T')[0];
    if (!/Uniboost dispatchers cut over/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: Uniboost dispatchers cut over at indices 1/2/3 + index-7 ratchet swapped to NudgeRatchetDelayRelease (story 071); addresses patched from broadcast\n`
        );
    }

    console.log('==================================================');
    console.log('  patch-mainnet-addresses-uniboost-cutover summary');
    console.log('==================================================');
    summary.forEach((line) => console.log(line));
    console.log('==================================================');

    if (hadCollision) {
        fail(4, 'One or more fields could not be safely patched (see summary above)');
    }

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
