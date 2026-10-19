#!/usr/bin/env node
/**
 * Story 104 (Balancexit Stage 3): proves that a Sepolia extraction WITHOUT Balancer deployments
 * emits zero-address placeholders for the legacy Balancer keys and passes the
 * generate:ts-sepolia key-set check, and that anvil (31337) extraction is unchanged.
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
    NFT_BASE_NAMES,
    RENAMED_CONTRACT_NAMES,
    buildExtraction,
} = require('../server/extract-addresses');
const { readInterfaceKeysFromFile, diffKeySet } = require('../server/contract-addresses-interface');

const SEPOLIA = 11155111;
const ANVIL = 31337;
const LEGACY_BALANCER_KEYS = ['BalancerPooler', 'BalancerPool', 'BalancerVault', 'BalancerRouter'];
// Index-4 keys DeployMocksSepolia must now deploy for real (never placeholders).
const UNIPOOLER_KEYS = ['UniPooler', 'PhusdSusdsPair', 'UniswapV2Router'];

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
    const notDeployed = new Set([...LEGACY_BALANCER_KEYS, 'UniswapHelper']);
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
        const c = extracted.contracts[key];
        check(c && c.address === ZERO_ADDRESS && c.deployed === false, `${key} is a zero-address placeholder`);
    }
    const { missing, extra } = diffKeySet(names, interfaceKeys);
    check(missing.length === 0, `no interface key missing (generate:ts-sepolia key-set check)${missing.length ? ': ' + missing.join(', ') : ''}`);
    check(extra.length === 0, `no key outside the interface${extra.length ? ': ' + extra.join(', ') : ''}`);
    check(!names.some((n) => ['Seeding', 'DolaYield', 'UsdcYield', 'UsdcSeeding'].includes(n)), 'checkpoint markers still filtered');
    check(!names.includes('BuggedPoolerV2Index6'), 'BuggedPoolerV2Index6 still dropped');
    check(placeholders.every((k) => interfaceKeys.includes(k)), 'placeholders are interface keys only');
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

// ---- 2. Anvil is unchanged: no placeholder fill, missing keys stay missing ----
console.log(`\n[synthetic] Anvil (${ANVIL}) extraction is unchanged`);
check(!ZERO_PLACEHOLDER_CHAIN_IDS.includes(ANVIL), '31337 is not a zero-placeholder chain');
check(!ZERO_PLACEHOLDER_CHAIN_IDS.includes(1), 'mainnet (1) is not a zero-placeholder chain');
{
    const anvilProgress = { ...syntheticSepoliaProgress(), chainId: ANVIL, networkName: 'anvil' };
    const { extracted, placeholders } = buildExtraction(anvilProgress, ANVIL, { quiet: true });
    check(placeholders.length === 0, 'no placeholders on anvil');
    check(LEGACY_BALANCER_KEYS.every((k) => !(k in extracted.contracts)), 'undeployed keys are absent on anvil, as before');
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
