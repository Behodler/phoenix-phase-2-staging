#!/usr/bin/env node
/**
 * patch-balancer-pool-mainnet.js
 *
 * After migrating BalancerPoolerV2 to the new phUSD/sUSDS 50/50 pool, update
 * `BalancerPool` in server/deployments/mainnet-addresses.ts.
 *
 * Safety:
 *   - Only replaces the value if it currently matches OLD_POOL (idempotent).
 *   - Aborts on any other current value to avoid silently overwriting unknown state.
 */

const fs = require('fs');
const path = require('path');

const OLD_POOL = '0x5B26d938F0bE6357C39e936Cc9c2277b9334eA58';
const NEW_POOL = '0x642BB6860b4776CC10b26B8f361Fd139E7f0db04';

const ROOT = path.join(__dirname, '..');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function run() {
    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

    const re = /^(\s*BalancerPool:\s*)"(0x[0-9a-fA-F]{40})"(.*)$/m;
    const match = source.match(re);
    if (!match) {
        fail(2, 'BalancerPool field not found in mainnet-addresses.ts');
    }
    const currentAddress = match[2];

    if (currentAddress.toLowerCase() === NEW_POOL.toLowerCase()) {
        console.log(`BalancerPool already set to NEW_POOL (${NEW_POOL}). Nothing to do.`);
        return;
    }
    if (currentAddress.toLowerCase() !== OLD_POOL.toLowerCase()) {
        fail(
            3,
            `BalancerPool currently "${currentAddress}", expected OLD_POOL "${OLD_POOL}". Aborting to avoid overwrite.`
        );
    }

    const newSource = source.replace(re, `$1"${NEW_POOL}"$3`);

    const today = new Date().toISOString().split('T')[0];
    const stampedSource = /Updated .*BalancerPool repointed/.test(newSource)
        ? newSource
        : newSource.replace(
              /(\/\/ Updated [^\n]*\n)(?=import)/,
              `$1// Updated ${today}: BalancerPool repointed to phUSD/sUSDS 50/50 pool\n`
          );

    fs.writeFileSync(ADDRESSES_FILE, stampedSource, 'utf8');

    console.log('==========================================');
    console.log('  patch-balancer-pool-mainnet summary');
    console.log('==========================================');
    console.log(`  PATCH  BalancerPool  ${currentAddress}  ->  ${NEW_POOL}`);
    console.log('==========================================');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
