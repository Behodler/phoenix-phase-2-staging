#!/usr/bin/env node
/**
 * patch-mainnet-addresses-stable-staker.js
 *
 * After broadcasting MigrateStableStakerMainnet.s.sol (story 055), this script patches
 * mainnet-addresses.ts with the real deployed addresses read from
 * broadcast/MigrateStableStakerMainnet.s.sol/1/run-latest.json.
 *
 * What it patches (4 flat top-level fields):
 *   - YieldStrategyDola  <- new DOLA ERC4626YieldStrategy  (OVERWRITE: old non-zero address)
 *   - YieldStrategyUSDC  <- new USDC ERC4626YieldStrategy  (OVERWRITE: old non-zero address)
 *   - YieldStrategyUSDe  <- new USDe ERC4626YieldStrategy  (OVERWRITE: old non-zero address)
 *   - StableStaker       <- deployed StableStaker          (ZERO-ONLY: placeholder)
 *
 * Disambiguation: the three new strategies are all CREATE txs with the SAME
 * contractName "ERC4626YieldStrategy". The migration script deploys them in a FIXED
 * Phase-B order — DOLA, then USDC, then USDe — so they are matched positionally by the
 * Nth ERC4626YieldStrategy CREATE in the broadcast. StableStaker is a unique contractName.
 *
 * Rules:
 *   1. The three YieldStrategy* fields are EXPECTED to be non-zero (old addresses) and are
 *      overwritten unconditionally with the new addresses (this is a strategy MIGRATION).
 *   2. StableStaker must be a zero-address placeholder; aborts if already populated
 *      (collision guard) so a re-run can't silently clobber a real deployment.
 *   3. Strips any trailing `// not yet deployed` / `// placeholder` / `// PLACEHOLDER:` comment
 *      on patched lines.
 *   4. Fails loudly if any expected contract is missing from the broadcast log.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing / unparseable, or target file missing
 *   3 - Expected contract not found in broadcast (too few CREATEs)
 *   4 - StableStaker target already non-zero (collision) or a field not found
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'MigrateStableStakerMainnet.s.sol', '1', 'run-latest.json'
);
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

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
 * Walk transactions[] in order, filter transactionType === "CREATE", and map them to the
 * expected deploy order. The three ERC4626YieldStrategy CREATEs are matched positionally
 * (Phase-B order: DOLA, USDC, USDe); StableStaker by unique name.
 */
function resolveAddresses(broadcast) {
    const creates = (broadcast.transactions || []).filter(
        (tx) => tx.transactionType === 'CREATE'
    );

    const ysCreates = creates.filter((tx) => tx.contractName === 'ERC4626YieldStrategy');
    if (ysCreates.length < 3) {
        fail(3, `Expected >= 3 ERC4626YieldStrategy CREATE txs, found ${ysCreates.length}`);
    }
    const ssCreate = creates.find((tx) => tx.contractName === 'StableStaker');
    if (!ssCreate) {
        fail(3, 'Expected StableStaker CREATE tx not found in broadcast');
    }

    const out = {
        YieldStrategyDola: ysCreates[0].contractAddress,
        YieldStrategyUSDC: ysCreates[1].contractAddress,
        YieldStrategyUSDe: ysCreates[2].contractAddress,
        StableStaker: ssCreate.contractAddress,
    };
    for (const [k, v] of Object.entries(out)) {
        if (!v) fail(3, `CREATE tx for ${k} has no contractAddress`);
    }
    return out;
}

/**
 * Replace a flat top-level field. `zeroOnly` enforces the field is currently the zero
 * address (collision guard); otherwise the field is overwritten unconditionally.
 * Returns { newSource, replaced, currentAddress }.
 */
function patchFlatField(source, field, newAddress, zeroOnly) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) {
        return { newSource: source, replaced: false, currentAddress: null, notFound: true };
    }
    const currentAddress = match[2];
    const trailingContent = match[3];
    const cleanTrailing = trailingContent
        .replace(/\s*\/\/\s*not yet deployed.*/i, ',')
        .replace(/\s*\/\/\s*placeholder.*/i, ',')
        .replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');

    if (zeroOnly && currentAddress.toLowerCase() !== ZERO_ADDRESS) {
        return { newSource: source, replaced: false, currentAddress, collision: true };
    }
    const newSource = source.replace(re, `$1"${newAddress}"${cleanTrailing}`);
    return { newSource, replaced: true, currentAddress };
}

function run() {
    const broadcast = loadBroadcast();
    const addrs = resolveAddresses(broadcast);

    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

    // field -> { newAddress, zeroOnly }
    const plan = [
        { field: 'YieldStrategyDola', newAddress: addrs.YieldStrategyDola, zeroOnly: false },
        { field: 'YieldStrategyUSDC', newAddress: addrs.YieldStrategyUSDC, zeroOnly: false },
        { field: 'YieldStrategyUSDe', newAddress: addrs.YieldStrategyUSDe, zeroOnly: false },
        { field: 'StableStaker', newAddress: addrs.StableStaker, zeroOnly: true },
    ];

    const summary = [];
    let hadError = false;

    for (const p of plan) {
        const result = patchFlatField(source, p.field, p.newAddress, p.zeroOnly);
        if (result.replaced) {
            source = result.newSource;
            const note = p.zeroOnly ? '' : `  (was ${result.currentAddress})`;
            summary.push(`  PATCH   ${p.field.padEnd(20)} <- ${p.newAddress}${note}`);
        } else if (result.notFound) {
            summary.push(`  MISS    ${p.field.padEnd(20)} field not found in mainnet-addresses.ts`);
            hadError = true;
        } else if (result.collision) {
            summary.push(`  COLLIDE ${p.field.padEnd(20)} already=${result.currentAddress}, wanted=${p.newAddress}`);
            hadError = true;
        }
    }

    // Header comment refresh (chronological note).
    const today = new Date().toISOString().split('T')[0];
    if (!/StableStaker migration .*patched/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: StableStaker migration (story 055) — new YS{Dola,USDC,USDe} + StableStaker patched from broadcast\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-stable-staker summary');
    console.log('==========================================');
    summary.forEach((line) => console.log(line));
    console.log('==========================================');

    if (hadError) {
        fail(4, 'One or more fields could not be safely patched (see summary above)');
    }

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
