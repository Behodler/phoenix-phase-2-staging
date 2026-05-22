#!/usr/bin/env node
/**
 * patch-mainnet-addresses-deposit-view.js
 *
 * After broadcasting RewireSYAToPhlimboV2.s.sol (story 049 follow-up), this
 * script patches mainnet-addresses.ts with the new DepositView address pulled
 * from `broadcast/RewireSYAToPhlimboV2.s.sol/1/run-latest.json`.
 *
 * Patch in this run:
 *
 *   1. DepositView    expected old = current mainnet DepositView (V1-baked)
 *                     patched to  = newDepositView from broadcast (V2-baked)
 *
 * DepositPageView is deprecated and intentionally NOT touched.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - Expected contract not found in broadcast
 *   3 - Address collision / unexpected old address (self-validation failed)
 *   4 - target mainnet-addresses.ts missing
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'RewireSYAToPhlimboV2.s.sol', '1', 'run-latest.json'
);
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Must match OLD_DEPOSIT_VIEW constant in script/RewireSYAToPhlimboV2.s.sol
// and the pre-broadcast state of mainnet-addresses.ts.
const OLD_DEPOSIT_VIEW = '0x2Fdf77d4Ea75eFd48922B8E521612197FFbB564c';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
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
 * RewireSYAToPhlimboV2 broadcasts exactly ONE CREATE (DepositView).
 * The other two transactions are CALLs (setPhlimbo + approvePhlimbo).
 */
function matchDeposit(broadcast) {
    const creates = (broadcast.transactions || []).filter(
        (tx) => tx.transactionType === 'CREATE'
    );

    if (creates.length !== 1) {
        fail(2, `Broadcast has ${creates.length} CREATE transactions; expected exactly 1 (DepositView)`);
    }
    const tx = creates[0];
    if (tx.contractName !== 'DepositView') {
        fail(2, `Single CREATE has contractName=${tx.contractName}; expected DepositView`);
    }
    if (!tx.contractAddress) {
        fail(2, 'CREATE tx for DepositView has no contractAddress');
    }
    return tx.contractAddress;
}

function patchFlatField(source, field, newAddress, expectedOld) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const currentAddress = match[2];
    const trailing = match[3];
    if (currentAddress.toLowerCase() !== expectedOld.toLowerCase()) {
        return { newSource: source, currentAddress, replaced: false };
    }
    const newSource = source.replace(re, `$1"${newAddress}"${trailing}`);
    return { newSource, currentAddress, replaced: true };
}

function refreshHeaderComment(source) {
    const today = new Date().toISOString().split('T')[0];
    const stampLine = `// Updated ${today}: DepositView redeployed against PhlimboV2 (story 049 follow-up - rewire-sya-to-phlimbo-v2)`;
    if (source.includes(stampLine)) return source;
    return source.replace(
        /(\/\/ Updated [^\n]*\n)(?=import)/,
        `$1${stampLine}\n`
    );
}

function run() {
    const broadcast = loadBroadcast();
    const newDepositView = matchDeposit(broadcast);

    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(4, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');
    const summary = [];
    let hadFailure = false;

    {
        const r = patchFlatField(source, 'DepositView', newDepositView, OLD_DEPOSIT_VIEW);
        if (r.replaced) {
            source = r.newSource;
            summary.push(`  PATCH    DepositView                   ${OLD_DEPOSIT_VIEW} -> ${newDepositView}`);
        } else if (r.currentAddress) {
            summary.push(`  COLLIDE  DepositView                   existing=${r.currentAddress} (expected OLD=${OLD_DEPOSIT_VIEW})`);
            hadFailure = true;
        } else {
            summary.push(`  MISS     DepositView                   field not found`);
            hadFailure = true;
        }
    }

    source = refreshHeaderComment(source);

    console.log('============================================');
    console.log('  patch-mainnet-addresses-deposit-view');
    console.log('============================================');
    summary.forEach((line) => console.log(line));
    console.log('============================================');

    if (hadFailure) {
        fail(3, 'DepositView field could not be safely patched -- self-validation against expected-OLD constant failed (see summary above)');
    }

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
