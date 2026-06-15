#!/usr/bin/env node
/**
 * patch-mainnet-addresses-saga2-deploy.js  (migrate saga 2, step 2.1)
 *
 * After broadcasting MigrateSaga2Deploy.s.sol (saga 2.1), this patches mainnet-addresses.ts with the
 * real deployed addresses read from script/migration-inputs/saga2-deployments.json.
 *
 * What it patches (3 fields, OVERWRITE — not zero-only):
 *   - YieldStrategyDola  <- ysDolaV2 (new fixed ERC4626YieldStrategy for DOLA)
 *   - YieldStrategyUSDC  <- ysUsdcV2 (new fixed ERC4626YieldStrategy for USDC)
 *   - PhusdStableMinter  <- minterV2 (the new phUSD minter)
 *
 * What it does NOT patch:
 *   - StableStaker / StableYieldAccumulator (unchanged — saga 2 rewires them in place)
 *   - YieldStrategyUSDe (USDe market strategy is untouched by saga 2)
 *   - InPlaceMigrator (ephemeral; not tracked in mainnet-addresses.ts)
 *
 * Exit codes: 0 success / 1 file missing-unparseable / 3 bad deployments field / 4 field not found.
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const DEPLOYMENTS_FILE = path.join(ROOT, 'script', 'migration-inputs', 'saga2-deployments.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function loadDeployments() {
    if (!fs.existsSync(DEPLOYMENTS_FILE)) {
        fail(1, `Deployments JSON not found: ${DEPLOYMENTS_FILE}\nRun MigrateSaga2Deploy (saga 2.1) broadcast first.`);
    }
    try {
        return JSON.parse(fs.readFileSync(DEPLOYMENTS_FILE, 'utf8'));
    } catch (err) {
        fail(1, `Deployments JSON unparseable: ${err.message}`);
    }
}

function requireAddr(value, name) {
    if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
        fail(3, `deployments.${name} missing or invalid in ${DEPLOYMENTS_FILE}`);
    }
    return value;
}

function patchFlatField(source, field, newAddress) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) {
        return { newSource: source, replaced: false, currentAddress: null, notFound: true };
    }
    const currentAddress = match[2];
    const newSource = source.replace(re, `$1"${newAddress}"${match[3]}`);
    return { newSource, replaced: true, currentAddress };
}

function run() {
    const d = loadDeployments();
    const plan = [
        { field: 'YieldStrategyDola', newAddress: requireAddr(d.ysDolaV2, 'ysDolaV2') },
        { field: 'YieldStrategyUSDC', newAddress: requireAddr(d.ysUsdcV2, 'ysUsdcV2') },
        { field: 'PhusdStableMinter', newAddress: requireAddr(d.minterV2, 'minterV2') },
    ];

    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

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

    const today = new Date().toISOString().split('T')[0];
    if (!/saga 2 migration .*patched/.test(source)) {
        source = source.replace(
            /(\/\/ Updated [^\n]*\n)(?=import)/,
            `$1// Updated ${today}: saga 2 migration (2.1) — YieldStrategyDola/USDC + PhusdStableMinter (V2) patched\n`
        );
    }

    console.log('==========================================');
    console.log('  patch-mainnet-addresses-saga2-deploy summary');
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
