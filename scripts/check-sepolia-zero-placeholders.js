#!/usr/bin/env node
/**
 * Story 104 (Balancexit Stage 3): proves that a Sepolia extraction WITHOUT Balancer deployments
 * emits zero-address placeholders for the legacy Balancer keys and passes the
 * generate:ts-sepolia key-set check. Story 106: also proves that anvil (31337), which no longer
 * deploys the Balancer mocks either, emits zero placeholders for exactly ANVIL_ZERO_PLACEHOLDER_KEYS
 * and nothing else. Story 107 (wind-down confirmed): the legacy Balancer keys are gone from the
 * interface, so neither chain emits them, anvil emits no placeholders at all, and
 * BalancerPoolerMintDebtHook stays a real interface key. Story 121: `BalancerLPMigrator` is mainnet-only, so
 * anvil emits exactly that one placeholder (ANVIL_ZERO_PLACEHOLDER_KEYS) and Sepolia emits it from the interface.
 *
 * Pure: reads the ContractAddresses interface and (optionally) a progress file; writes NOTHING.
 *
 * Usage:
 *   node scripts/check-sepolia-zero-placeholders.js                 # synthetic progress fixture
 *   node scripts/check-sepolia-zero-placeholders.js <progress.json> # also check a real progress file
 *                                                                   #   (e.g. a deploy:sepolia-preview
 *                                                                   #   run's progress.11155111.json)
 * Exit 0 on success, 1 on any failed assertion.
 */

const fs = require('fs');
const path = require('path');
const {
    ZERO_ADDRESS,
    ZERO_PLACEHOLDER_CHAIN_IDS,
    ANVIL_ZERO_PLACEHOLDER_KEYS,
    NFT_BASE_NAMES,
    RENAMED_CONTRACT_NAMES,
    buildExtraction,
} = require('../server/extract-addresses');
const { readInterfaceKeysFromFile, diffKeySet } = require('../server/contract-addresses-interface');

const SEPOLIA = 11155111;
const ANVIL = 31337;
// Removed from ContractAddresses by story 107; must never be emitted again.
const LEGACY_BALANCER_KEYS = ['BalancerPooler', 'BalancerPool', 'BalancerVault', 'BalancerRouter'];
// Index-4 keys DeployMocksSepolia must now deploy for real (never placeholders).
const UNIPOOLER_KEYS = ['UniPooler', 'PhusdSusdsPair', 'UniswapV2Router'];
// Story 121: mainnet-only (no Balancer V3 on anvil or Sepolia); never deployed by either mock stack.
const MAINNET_ONLY_KEYS = ['BalancerLPMigrator'];

let failures = 0;
function check(cond, msg) {
    if (cond) {
        console.log(`  ok   - ${msg}`);
    } else {
        console.log(`  FAIL - ${msg}`);
        failures++;
    }
}

const interfaceKeys = readInterfaceKeysFromFile();

/** The tracked deployment name that extracts to interface key `key`. */
function trackedNameFor(key) {
    const renamedFrom = Object.keys(RENAMED_CONTRACT_NAMES).find((k) => RENAMED_CONTRACT_NAMES[k] === key);
    if (renamedFrom) return renamedFrom;
    if (NFT_BASE_NAMES.includes(key)) return `${key}V2`;
    return key;
}

function fakeAddress(i) {
    return '0x' + (i + 1).toString(16).padStart(40, '0');
}

/**
 * A progress file shaped like the story-104 DeployMocksSepolia output: every interface key
 * deployed EXCEPT the legacy Balancer keys and UniswapHelper (never deployed on Sepolia), plus
 * the zero-address checkpoint markers and a dropped deploy-only name.
 */
function syntheticSepoliaProgress() {
    const notDeployed = new Set([...LEGACY_BALANCER_KEYS, 'UniswapHelper', ...MAINNET_ONLY_KEYS]);
    const contracts = {};
    interfaceKeys.forEach((key, i) => {
        if (notDeployed.has(key)) return;
        contracts[trackedNameFor(key)] = {
            address: fakeAddress(i),
            deployed: true,
            configured: true,
            deployGas: 1,
            configGas: 0,
        };
    });
    for (const marker of ['Seeding', 'DolaYield', 'UsdcYield', 'UsdcSeeding']) {
        contracts[marker] = { address: ZERO_ADDRESS, deployed: true, configured: true, deployGas: 0, configGas: 0 };
    }
    contracts.BuggedPoolerV2Index6 = { address: fakeAddress(9999), deployed: true, configured: false, deployGas: 1, configGas: 0 };
    return { chainId: SEPOLIA, networkName: 'sepolia', deploymentStatus: 'completed', contracts };
}

function checkSepolia(label, progress, { expectUniPoolerDeployed }) {
    console.log(`\n[${label}] Sepolia (${SEPOLIA}) extraction`);
    const { extracted, placeholders } = buildExtraction(progress, SEPOLIA, { interfaceKeys, quiet: true });
    const names = Object.keys(extracted.contracts);

    for (const key of LEGACY_BALANCER_KEYS) {
        check(!(key in extracted.contracts), `${key} is not emitted (removed by story 107)`);
    }
    const { missing, extra } = diffKeySet(names, interfaceKeys);
    check(missing.length === 0, `no interface key missing (generate:ts-sepolia key-set check)${missing.length ? ': ' + missing.join(', ') : ''}`);
    check(extra.length === 0, `no key outside the interface${extra.length ? ': ' + extra.join(', ') : ''}`);
    check(!names.some((n) => ['Seeding', 'DolaYield', 'UsdcYield', 'UsdcSeeding'].includes(n)), 'checkpoint markers still filtered');
    check(!names.includes('BuggedPoolerV2Index6'), 'BuggedPoolerV2Index6 still dropped');
    check(placeholders.every((k) => interfaceKeys.includes(k)), 'placeholders are interface keys only');
    for (const key of MAINNET_ONLY_KEYS) {
        const c = extracted.contracts[key];
        check(c && c.address === ZERO_ADDRESS && c.deployed === false, `${key} is a zero placeholder (story 121)`);
    }
    if (expectUniPoolerDeployed) {
        for (const key of UNIPOOLER_KEYS) {
            const c = extracted.contracts[key];
            check(c && c.address !== ZERO_ADDRESS && c.deployed === true, `${key} is a real deployment, not a placeholder`);
        }
    }
    console.log(`  placeholders emitted: ${placeholders.join(', ') || '(none)'}`);
}

// ---- 1. Synthetic Sepolia fixture ----
checkSepolia('synthetic', syntheticSepoliaProgress(), { expectUniPoolerDeployed: true });

// ---- 1b. The interface (story 107): legacy Balancer keys gone, the mint-debt hook kept ----
console.log('\n[interface] ContractAddresses');
for (const key of LEGACY_BALANCER_KEYS) {
    check(!interfaceKeys.includes(key), `${key} is not an interface key (removed by story 107)`);
}
check(interfaceKeys.includes('BalancerPoolerMintDebtHook'), 'BalancerPoolerMintDebtHook is still an interface key');
check(!NFT_BASE_NAMES.includes('BalancerPooler'), 'BalancerPooler is not an NFT base name (story 107)');

// ---- 2. Anvil (story 106/107/121): only the mainnet-only placeholders now that the Balancer keys are gone ----
console.log(`\n[synthetic] Anvil (${ANVIL}) extraction`);
check(ZERO_PLACEHOLDER_CHAIN_IDS.includes(ANVIL), '31337 is a zero-placeholder chain (story 106)');
check(!ZERO_PLACEHOLDER_CHAIN_IDS.includes(1), 'mainnet (1) is not a zero-placeholder chain');
check(
    JSON.stringify([...ANVIL_ZERO_PLACEHOLDER_KEYS]) === JSON.stringify(MAINNET_ONLY_KEYS),
    'anvil placeholder list is exactly the mainnet-only keys (story 107 emptied it; story 121 added BalancerLPMigrator)'
);
{
    const anvilProgress = { ...syntheticSepoliaProgress(), chainId: ANVIL, networkName: 'anvil' };
    // Drop two non-Balancer keys too: anvil must NOT resurrect them (anvil defines the interface).
    delete anvilProgress.contracts.UniswapHelper;
    const droppedKey = 'WaUSDC';
    delete anvilProgress.contracts[trackedNameFor(droppedKey)];
    const { extracted, placeholders } = buildExtraction(anvilProgress, ANVIL, { quiet: true });
    check(
        JSON.stringify(placeholders) === JSON.stringify(MAINNET_ONLY_KEYS),
        `anvil emits only the mainnet-only placeholders (got: ${placeholders.join(', ') || 'none'})`
    );
    for (const key of LEGACY_BALANCER_KEYS) {
        check(!(key in extracted.contracts), `anvil ${key} is not emitted`);
    }
    check(
        extracted.contracts.BalancerPoolerMintDebtHook && extracted.contracts.BalancerPoolerMintDebtHook.address !== ZERO_ADDRESS,
        'anvil BalancerPoolerMintDebtHook is a real deployment'
    );
    check(!(droppedKey in extracted.contracts), `an undeployed non-Balancer key (${droppedKey}) is NOT filled on anvil`);
    check(!('UniswapHelper' in extracted.contracts), 'an undeployed UniswapHelper is NOT filled on anvil');
}

// ---- 3. Optional: a real progress file ----
const progressArg = process.argv[2];
if (progressArg) {
    const p = path.resolve(progressArg);
    const progress = JSON.parse(fs.readFileSync(p, 'utf-8'));
    check(progress.chainId === SEPOLIA, `${path.basename(p)} is a Sepolia progress file`);
    checkSepolia(path.basename(p), progress, { expectUniPoolerDeployed: true });
    const tracked = Object.keys(progress.contracts || {});
    check(
        !tracked.some((n) => /^Mock?Balancer(Pool|Vault|Router)$|^BalancerPoolerV2$/.test(n)),
        'progress file tracks no Balancer mock / BalancerPoolerV2'
    );
}

console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
