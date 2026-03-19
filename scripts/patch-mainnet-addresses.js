#!/usr/bin/env node
/**
 * patch-mainnet-addresses.js
 *
 * After broadcasting DeployMainnetNFT.s.sol, this script patches
 * mainnet-addresses.ts with the real deployed addresses from progress.1.json.
 *
 * Rules:
 *   1. Only replace entries that are currently the zero address (0x000...000)
 *   2. Replace StableYieldAccumulator with the new accumulator address
 *   3. Leave all other existing addresses untouched
 *
 * Exit codes:
 *   0 - Success
 *   1 - progress.1.json not found
 *   2 - progress.1.json not completed
 *   3 - Parse error
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const PROGRESS_FILE = path.join(__dirname, '..', 'server', 'deployments', 'progress.1.json');
const ADDRESSES_FILE = path.join(__dirname, '..', 'server', 'deployments', 'mainnet-addresses.ts');

// Maps progress.1.json keys to mainnet-addresses.ts keys.
// Only entries listed here will be patched.
const PROGRESS_TO_TS_KEY = {
    NFTMinter: 'NFTMinter',
    BurnRecorder: 'BurnRecorder',
    BurnerEYE: 'BurnerEYE',
    BurnerSCX: 'BurnerSCX',
    BurnerFlax: 'BurnerFlax',
    BalancerPooler: 'BalancerPooler',
    GatherWBTC: 'GatherWBTC',
    NewStableYieldAccumulator: 'StableYieldAccumulator',
    ViewRouter: 'ViewRouter',
    DepositPageView: 'DepositPageView',
    MintPageView: 'MintPageView',
};

function run() {
    // 1. Load progress file
    if (!fs.existsSync(PROGRESS_FILE)) {
        console.error('ERROR: progress.1.json not found. Run the broadcast first.');
        process.exit(1);
    }

    let progress;
    try {
        progress = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
    } catch (err) {
        console.error('ERROR: Could not parse progress.1.json:', err.message);
        process.exit(3);
    }

    if (progress.deploymentStatus !== 'completed') {
        console.error(`ERROR: Deployment status is "${progress.deploymentStatus}", expected "completed".`);
        process.exit(2);
    }

    // 2. Build replacement map from progress contracts
    const replacements = {};
    for (const [progressKey, tsKey] of Object.entries(PROGRESS_TO_TS_KEY)) {
        const entry = (progress.contracts || {})[progressKey];
        if (entry && entry.address && entry.address !== ZERO_ADDRESS) {
            replacements[tsKey] = entry.address;
        }
    }

    if (Object.keys(replacements).length === 0) {
        console.error('ERROR: No deployable contract addresses found in progress.1.json.');
        process.exit(2);
    }

    // 3. Read the current mainnet-addresses.ts
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

    // 4. Apply patches
    let patchedCount = 0;
    let skippedCount = 0;

    for (const [tsKey, newAddress] of Object.entries(replacements)) {
        // Match the line:  KeyName: "0x...",  or  KeyName: "0x...", // comment
        const regex = new RegExp(
            `(${tsKey}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)`
        );

        const match = source.match(regex);
        if (!match) {
            console.warn(`  SKIP: "${tsKey}" not found in mainnet-addresses.ts`);
            skippedCount++;
            continue;
        }

        const currentAddress = match[2];

        // Only patch zero addresses, except StableYieldAccumulator which always gets replaced
        if (currentAddress !== ZERO_ADDRESS && tsKey !== 'StableYieldAccumulator') {
            console.log(`  KEEP: ${tsKey} already has ${currentAddress}`);
            skippedCount++;
            continue;
        }

        // Strip placeholder comments when replacing
        const trailingContent = match[3];
        const cleanTrailing = trailingContent.replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');

        source = source.replace(regex, `$1"${newAddress}"${cleanTrailing}`);
        console.log(`  PATCH: ${tsKey} ${currentAddress} -> ${newAddress}`);
        patchedCount++;
    }

    // 5. Update the header comment
    const today = new Date().toISOString().split('T')[0];
    source = source.replace(
        /\/\/ NOTE: NFT contract addresses are placeholders.*\n\/\/\s+Replace with actual addresses.*/,
        `// Updated ${today}: NFT addresses patched from progress.1.json after broadcast`
    );

    // 6. Write back
    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');

    console.log('');
    console.log('==========================================');
    console.log('  Mainnet Addresses Patched');
    console.log('==========================================');
    console.log(`  Patched:  ${patchedCount}`);
    console.log(`  Skipped:  ${skippedCount}`);
    console.log(`  File:     ${ADDRESSES_FILE}`);
    console.log('==========================================');
}

run();
