#!/usr/bin/env node
/**
 * patch-mainnet-addresses-ys-swap.js  (story 060)
 *
 * After broadcasting ResetAndRewire.s.sol (story 060 step 3), this script patches
 * mainnet-addresses.ts with the real deployed V2 strategy addresses read from
 * script/migration-inputs/ys-swap-deployments.json.
 *
 * What it patches (2 fields, OVERWRITE — not zero-only):
 *   - YieldStrategyDola  <- ysDolaV2 address (new ERC4626YieldStrategy for DOLA)
 *   - YieldStrategyUSDC  <- ysUsdcV2 address (new ERC4626YieldStrategy for USDC)
 *
 * What it does NOT patch:
 *   - StableStaker        (unchanged — same original staker address, story 060 rewires it in-place)
 *   - YieldStrategyUSDe   (USDe strategy is unchanged by story 060)
 *   - tempStaker          (ephemeral, not in mainnet-addresses.ts)
 *   - migrators           (ephemeral, not in mainnet-addresses.ts)
 *
 * Rules:
 *   1. Both YieldStrategy* fields are EXPECTED to be non-zero (old addresses) and are
 *      overwritten unconditionally with the new V2 addresses.
 *   2. Fails loudly if any expected field is missing from the addresses file.
 *   3. Fails loudly if deployments JSON is missing or unparseable.
 *
 * Exit codes:
 *   0 - Success
 *   1 - deployments JSON missing / unparseable, or mainnet-addresses.ts missing
 *   3 - Expected address not found in deployments JSON
 *   4 - A field not found in mainnet-addresses.ts
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const DEPLOYMENTS_FILE = path.join(ROOT, 'script', 'migration-inputs', 'ys-swap-deployments.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function loadDeployments() {
    if (!fs.existsSync(DEPLOYMENTS_FILE)) {
        fail(1, `Deployments JSON not found: ${DEPLOYMENTS_FILE}\nRun DeployTempStableStakerAndMigrators + ResetAndRewire first.`);
    }
    try {
        return JSON.parse(fs.readFileSync(DEPLOYMENTS_FILE, 'utf8'));
    } catch (err) {
        fail(1, `Deployments JSON unparseable: ${err.message}`);
    }
}

function resolveAddresses(deployments) {
    const ysDolaV2 = deployments.ysDolaV2;
    const ysUsdcV2 = deployments.ysUsdcV2;

    if (!ysDolaV2 || !/^0x[0-9a-fA-F]{40}$/.test(ysDolaV2)) {
        fail(3, `deployments.ysDolaV2 missing or invalid in ${DEPLOYMENTS_FILE}`);
    }
    if (!ysUsdcV2 || !/^0x[0-9a-fA-F]{40}$/.test(ysUsdcV2)) {
        fail(3, `deployments.ysUsdcV2 missing or invalid in ${DEPLOYMENTS_FILE}`);
    }

    return { YieldStrategyDola: ysDolaV2, YieldStrategyUSDC: ysUsdcV2 };
}

/**
 * Replace a flat top-level field. Overwrites unconditionally (both fields are migrations —
 * the old address is the previous strategy, the new address is the V2 replacement).
 * Returns { newSource, replaced, currentAddress, notFound }.
 */
function patchFlatField(source, field, newAddress) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) {
        return { newSource: source, replaced: false, currentAddress: null, notFound: true };
    }
    const currentAddress = match[2];
    const trailingContent = match[3];
    // Strip any placeholder comments.
    const cleanTrailing = trailingContent
        .replace(/\s*\/\/\s*not yet deployed.*/i, ',')
        .replace(/\s*\/\/\s*placeholder.*/i, ',')
        .replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');

    const newSource = source.replace(re, `$1"${newAddress}"${cleanTrailing}`);
    return { newSource, replaced: true, currentAddress };
}

function run() {
    const deployments = loadDeployments();
    const addrs = resolveAddresses(deployments);

    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

    const plan = [
        { field: 'YieldStrategyDola', newAddress: addrs.YieldStrategyDola },
        { field: 'YieldStrategyUSDC', newAddress: addrs.YieldStrategyUSDC },
    ];

    const summary = [];
    let hadError = false;

    for (const p of plan) {
        const result = patchFlatField(source, p.field, p.newAddress);
        if (result.replaced) {
            source = result.newSource;
            summary.push(`  PATCH   ${p.field.padEnd(20)} <- ${p.newAddress}  (was ${result.currentAddress})`);
        } else if (result.notFound) {
            summary.push(`  MISS    ${p.field.padEnd(20)} field not found in mainnet-addresses.ts`);
            hadError = true;
        }
    }

    // Header comment refresh.
    const today = new Date().toISOString().split('T')[0];
    if (!/ys-swap migration .*patched/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: YS-swap migration (story 060) — new YieldStrategyDola + YieldStrategyUSDC patched\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-ys-swap summary');
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
