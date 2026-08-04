#!/usr/bin/env node
/**
 * patch-mainnet-addresses-mintpageview.js
 *
 * After DeployMainnetMintPageView.s.sol broadcasts, replace the MintPageView address in
 * mainnet-addresses.ts with the newly deployed view (the fixed, primeToken-balance version).
 *
 * Source of truth = the broadcast's LANDED MintPageView CREATE (real tx hash + contractAddress).
 * Requires exactly one landed MintPageView CREATE; unconditionally replaces the existing value.
 *
 * Exit: 0 ok | 1 broadcast/addresses missing | 3 != 1 landed MintPageView | 4 field not found
 *
 * ===== DEAD AS OF STORY 078. RETAINED AS HISTORY; NOT WIRED INTO ANY npm KEY. =====
 * Story 078 deleted the MintPageView key from mainnet-addresses.ts (with DepositView and
 * DepositPageView), leaving ViewRouter as the sole view key: views resolve on-chain through
 * ViewRouter.pages(keccak256("<page>")), never through a hand-maintained address book. There is
 * no longer a field for this script to patch, so it can only exit 4. Its call was therefore
 * removed from the `mintpageview:broadcast` npm key, which was a spent one-shot leg anyway.
 * Do not re-wire it; register a redeployed view with ViewRouter.setPage instead.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BROADCAST = path.join(ROOT, 'broadcast', 'DeployMainnetMintPageView.s.sol', '1', 'run-latest.json');
const ADDRESSES = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

function fail(code, msg) { console.error(`ERROR (${code}): ${msg}`); process.exit(code); }

function run() {
    if (!fs.existsSync(BROADCAST)) fail(1, `Broadcast not found: ${BROADCAST}`);
    let bc;
    try { bc = JSON.parse(fs.readFileSync(BROADCAST, 'utf8')); } catch (e) { fail(1, `Broadcast unreadable: ${e.message}`); }

    const creates = (bc.transactions || []).filter(
        (t) => t.transactionType === 'CREATE'
            && t.contractName === 'MintPageView'
            && t.hash && t.hash !== '0x' + '0'.repeat(64)
            && t.contractAddress
    );
    if (creates.length !== 1) fail(3, `Expected 1 landed MintPageView CREATE, found ${creates.length}.`);
    const addr = creates[0].contractAddress;

    if (!fs.existsSync(ADDRESSES)) fail(1, `Addresses file not found: ${ADDRESSES}`);
    let src = fs.readFileSync(ADDRESSES, 'utf8');

    const re = /^(\s*MintPageView:\s*)"(0x[0-9a-fA-F]{40})"(.*)$/m;
    const m = src.match(re);
    if (!m) fail(4, 'MintPageView field not found in mainnet-addresses.ts');
    const old = m[2];
    if (old.toLowerCase() === addr.toLowerCase()) {
        console.log(`MintPageView already = ${addr}, nothing to do.`);
        return;
    }
    src = src.replace(re, `$1"${addr}"$3`);
    fs.writeFileSync(ADDRESSES, src, 'utf8');
    console.log('==================================================');
    console.log('  patch-mainnet-addresses-mintpageview');
    console.log(`  MintPageView  ${old}  ->  ${addr}`);
    console.log('==================================================');
}

run();
