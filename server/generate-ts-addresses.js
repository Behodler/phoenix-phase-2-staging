#!/usr/bin/env node

/**
 * Generate TypeScript-compatible address object from extracted deployment data.
 * Outputs an object literal that can be copied directly into TypeScript code.
 *
 * Usage:
 *   node server/generate-ts-addresses.js [chainId]
 *
 * Examples:
 *   node server/generate-ts-addresses.js 31337     # Local/Anvil
 *   node server/generate-ts-addresses.js           # Defaults to 31337
 */

const fs = require('fs');
const path = require('path');

// Chain ID to input file mapping
const CHAIN_FILE_MAP = {
    31337: 'local.json',
    1: 'mainnet.json'
};

// Chain ID to output file mapping
const CHAIN_OUTPUT_MAP = {
    31337: 'local-addresses.ts',
    1: 'mainnet-addresses.ts'
};

const CHAIN_NAME_MAP = {
    31337: 'anvil',
    1: 'mainnet'
};

function generateInterfaceFile(chainId, inputFile, contracts) {
    const interfacePath = path.join(__dirname, 'deployments', 'addresses.ts');
    const networkName = CHAIN_NAME_MAP[chainId];
    const timestamp = new Date().toISOString();

    const lines = [];
    lines.push(`// Generated interface from ${inputFile} on ${timestamp}`);
    lines.push(`// Chain ID: ${chainId} (${networkName})`);
    lines.push('// This interface can be copied directly into UI projects');
    lines.push('');

    lines.push('export interface ContractAddresses {');

    contracts.forEach(([name]) => {
        lines.push(`  ${name}: string;`);
    });

    lines.push('}');

    const output = lines.join('\n') + '\n';
    fs.writeFileSync(interfacePath, output);

    console.log('\n' + '='.repeat(60));
    console.log(`TypeScript Interface Generated - ${networkName} (${chainId})`);
    console.log('='.repeat(60));
    console.log(`Output file: ${interfacePath}`);
    console.log('='.repeat(60) + '\n');
    console.log(output);
    console.log('\n' + '='.repeat(60));
}

/**
 * Parse an existing generated `*-addresses.ts` file into a plain object.
 *
 * The generated file is a deterministic object literal with flat
 * `Key: "0x...",` entries and (optionally) nested `nftsV1: { ... }` /
 * `nftsV2: { ... }` blocks. We parse it line-by-line rather than eval'ing
 * the TS so we never execute arbitrary code and never depend on a TS runtime.
 *
 * Returns `{ flat: { Key: "0x..." }, nftsV1: {...}, nftsV2: {...} }`.
 * Returns null shape (empty objects) if the file does not exist.
 */
function parseExistingAddressesTs(filePath) {
    const result = { flat: {}, nftsV1: {}, nftsV2: {} };
    if (!fs.existsSync(filePath)) {
        return result;
    }

    const src = fs.readFileSync(filePath, 'utf-8');
    const entryRe = /^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*"([^"]*)"\s*,?\s*$/;

    let current = 'flat'; // which bucket subsequent flat entries land in
    const lines = src.split('\n');
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];

        // Detect entry into a nested nftsV1/nftsV2 block.
        const nestedOpen = line.match(/^\s*(nftsV1|nftsV2)\s*:\s*\{\s*$/);
        if (nestedOpen) {
            current = nestedOpen[1];
            continue;
        }

        // Detect close of a nested block (`},`) — back to flat.
        if (current !== 'flat' && /^\s*\}\s*,?\s*$/.test(line)) {
            current = 'flat';
            continue;
        }

        const m = line.match(entryRe);
        if (!m) continue;
        const [, key, value] = m;

        if (current === 'flat') {
            result.flat[key] = value;
        } else {
            result[current][key] = value;
        }
    }

    return result;
}

/**
 * Count the total keys in a parsed mainnet address shape (flat + nested),
 * matching how the merged object's keys are counted. Used by the shrink-guard.
 */
function countAddressKeys(shape) {
    return (
        Object.keys(shape.flat || {}).length +
        Object.keys(shape.nftsV1 || {}).length +
        Object.keys(shape.nftsV2 || {}).length
    );
}

function generateTsAddresses(chainId) {
    const inputFile = CHAIN_FILE_MAP[chainId];
    const outputFile = CHAIN_OUTPUT_MAP[chainId];
    const networkName = CHAIN_NAME_MAP[chainId] || 'unknown';

    if (!inputFile) {
        console.error(`Error: Unsupported chainId '${chainId}'.`);
        console.error('Supported chain IDs: 31337 (Anvil), 1 (Mainnet)');
        process.exit(1);
    }

    const inputPath = path.join(__dirname, 'deployments', inputFile);
    const outputPath = path.join(__dirname, 'deployments', outputFile);

    if (!fs.existsSync(inputPath)) {
        console.error(`Error: Input file not found: ${inputPath}`);
        console.error(`Run 'npm run extract:${networkName === 'anvil' ? 'addresses' : networkName}' first.`);
        process.exit(1);
    }

    // Read extracted addresses
    const data = JSON.parse(fs.readFileSync(inputPath, 'utf-8'));

    const contracts = Object.entries(data.contracts || {});
    const nftsV1 = data.nftsV1 || {};
    const nftsV2 = data.nftsV2 || {};

    // ────────────────────────────────────────────────────────────────────
    // chainId 1 (mainnet): NON-DESTRUCTIVE merge path.
    //
    // The mainnet input (mainnet.json) is frequently stale and only ever
    // contains a tiny subset of deployed contracts. External/immutable
    // addresses (Sky PSM, USDC, USDS, Balancer infra, etc.) are never
    // produced by any deploy broadcast. A wholesale overwrite would silently
    // drop them. So for mainnet we MERGE instead of overwrite, and refuse to
    // write a file that would shrink. The 31337/anvil path is left untouched
    // (local-addresses.ts is meant to be regenerated wholesale per deploy).
    // ────────────────────────────────────────────────────────────────────
    if (chainId === 1) {
        return generateMainnetAddresses({
            inputFile,
            outputPath,
            networkName,
            contracts,
            nftsV1,
            nftsV2,
        });
    }

    // For local/anvil, generate the interface file first
    if (chainId === 31337) {
        generateInterfaceFile(chainId, inputFile, contracts);
    }

    // Build TypeScript object literal
    const lines = [];
    lines.push(`// Generated from ${inputFile} on ${new Date().toISOString()}`);
    lines.push(`// Chain ID: ${chainId} (${networkName})`);
    lines.push('');

    if (chainId === 31337) {
        // For local: import and use the ContractAddresses interface
        lines.push("import { ContractAddresses } from './addresses';");
        lines.push('');
        lines.push(`export const ${networkName}Addresses: ContractAddresses = {`);
    } else {
        lines.push(`export const ${networkName}Addresses = {`);
    }

    // Write flat contracts (all contracts including V2 NFTs)
    contracts.forEach(([name, contract]) => {
        lines.push(`  ${name}: "${contract.address}",`);
    });

    lines.push('};');
    lines.push('');

    if (chainId === 31337) {
        lines.push(`export type ${networkName.charAt(0).toUpperCase() + networkName.slice(1)}ContractName = keyof ContractAddresses;`);
    } else {
        lines.push(`export type ${networkName.charAt(0).toUpperCase() + networkName.slice(1)}ContractName = keyof typeof ${networkName}Addresses;`);
    }

    const output = lines.join('\n');

    // Write to file
    fs.writeFileSync(outputPath, output);

    // Also print to console for easy copying
    console.log('\n' + '='.repeat(60));
    console.log(`TypeScript Addresses Generated - ${networkName} (${chainId})`);
    console.log('='.repeat(60));
    console.log(`Output file: ${outputPath}`);
    console.log('='.repeat(60) + '\n');
    console.log(output);
    console.log('\n' + '='.repeat(60));
}

/**
 * Non-destructive mainnet (chainId 1) generation.
 *
 * Merge priority (lowest → highest):
 *   1. Existing on-disk mainnet-addresses.ts values  (preserve everything currently there)
 *   2. mainnet-essential-addresses.json              (durable external/immutable floor)
 *   3. Freshly-extracted mainnet.json contracts/nftsV1/nftsV2 (newly-deployed wins)
 *
 * After building the merged object, a SHRINK-GUARD aborts (non-zero exit) if
 * the result would have fewer keys than the file it is about to overwrite —
 * this is what catches a stale/empty mainnet.json wipe.
 */
function generateMainnetAddresses({ inputFile, outputPath, networkName, contracts, nftsV1, nftsV2 }) {
    const essentialPath = path.join(__dirname, 'deployments', 'mainnet-essential-addresses.json');

    // 1. Existing on-disk values (lowest priority) — preserve the whole current file.
    const existing = parseExistingAddressesTs(outputPath);

    // 2. Essential external/immutable addresses (the durable floor).
    let essential = {};
    if (fs.existsSync(essentialPath)) {
        const raw = JSON.parse(fs.readFileSync(essentialPath, 'utf-8'));
        // Drop the `_comment` documentation key; keep only address entries.
        for (const [k, v] of Object.entries(raw)) {
            if (k === '_comment') continue;
            essential[k] = v;
        }
    } else {
        console.warn(`Warning: essential addresses file not found: ${essentialPath}`);
        console.warn('Proceeding with existing + extracted only (no essential floor).');
    }

    // 3. Freshly-extracted addresses (highest priority — newly-deployed wins).
    const extractedFlat = {};
    contracts.forEach(([name, contract]) => {
        extractedFlat[name] = contract.address;
    });
    const extractedV1 = {};
    Object.entries(nftsV1).forEach(([name, contract]) => {
        extractedV1[name] = contract.address;
    });
    const extractedV2 = {};
    Object.entries(nftsV2).forEach(([name, contract]) => {
        extractedV2[name] = contract.address;
    });

    // Merge flat keys in priority order. Essential externals merge into the
    // flat namespace; nftsV1/nftsV2 are kept as nested objects.
    const mergedFlat = Object.assign({}, existing.flat, essential, extractedFlat);
    const mergedV1 = Object.assign({}, existing.nftsV1, extractedV1);
    const mergedV2 = Object.assign({}, existing.nftsV2, extractedV2);

    const mergedShape = { flat: mergedFlat, nftsV1: mergedV1, nftsV2: mergedV2 };

    // ── SHRINK-GUARD ──────────────────────────────────────────────────────
    // Never write a mainnet file with FEWER keys than the one being overwritten.
    const existingKeyCount = countAddressKeys(existing);
    const mergedKeyCount = countAddressKeys(mergedShape);
    if (mergedKeyCount < existingKeyCount) {
        const existingKeys = new Set([
            ...Object.keys(existing.flat),
            ...Object.keys(existing.nftsV1),
            ...Object.keys(existing.nftsV2),
        ]);
        const mergedKeys = new Set([
            ...Object.keys(mergedFlat),
            ...Object.keys(mergedV1),
            ...Object.keys(mergedV2),
        ]);
        const dropped = [...existingKeys].filter((k) => !mergedKeys.has(k));
        console.error('\n' + '='.repeat(60));
        console.error('ABORT: mainnet address codegen would SHRINK the file.');
        console.error('='.repeat(60));
        console.error(`Existing ${path.basename(outputPath)} has ${existingKeyCount} keys; ` +
            `regenerated object would have only ${mergedKeyCount}.`);
        if (dropped.length > 0) {
            console.error(`Keys that would be dropped: ${dropped.join(', ')}`);
        }
        console.error(`Likely cause: '${inputFile}' is stale/empty. Refusing to overwrite ` +
            `${path.basename(outputPath)}. Re-extract mainnet addresses (npm run extract:mainnet) ` +
            'or update mainnet-essential-addresses.json, then retry.');
        console.error('='.repeat(60) + '\n');
        process.exit(1);
    }

    // ── Build the merged TypeScript object literal ────────────────────────
    // Preserve the typed `: ContractAddresses` annotation and the comment
    // header so mainnet-addresses.ts keeps satisfying the interface.
    const lines = [];
    lines.push(`// Generated from ${inputFile} on ${new Date().toISOString()}`);
    lines.push(`// Chain ID: 1 (${networkName})`);
    lines.push('// Non-destructive merge: existing values + mainnet-essential-addresses.json + freshly-extracted contracts.');
    lines.push('// External/immutable addresses are preserved from mainnet-essential-addresses.json; newly-deployed contracts win on conflict.');
    lines.push("import { ContractAddresses } from './addresses';");
    lines.push('');
    lines.push(`export const ${networkName}Addresses: ContractAddresses = {`);

    // Flat entries (preserve insertion order: existing keys first, then any
    // newly-introduced essential/extracted keys).
    Object.entries(mergedFlat).forEach(([name, address]) => {
        lines.push(`  ${name}: "${address}",`);
    });

    // Nested nftsV1
    const v1Entries = Object.entries(mergedV1);
    if (v1Entries.length > 0) {
        lines.push('  nftsV1: {');
        v1Entries.forEach(([name, address]) => {
            lines.push(`    ${name}: "${address}",`);
        });
        lines.push('  },');
    }

    // Nested nftsV2
    const v2Entries = Object.entries(mergedV2);
    if (v2Entries.length > 0) {
        lines.push('  nftsV2: {');
        v2Entries.forEach(([name, address]) => {
            lines.push(`    ${name}: "${address}",`);
        });
        lines.push('  },');
    }

    lines.push('};');
    lines.push('');
    lines.push(`export type ${networkName.charAt(0).toUpperCase() + networkName.slice(1)}ContractName = keyof ContractAddresses;`);

    const output = lines.join('\n') + '\n';

    fs.writeFileSync(outputPath, output);

    console.log('\n' + '='.repeat(60));
    console.log(`TypeScript Addresses Generated - ${networkName} (1) [non-destructive merge]`);
    console.log('='.repeat(60));
    console.log(`Output file: ${outputPath}`);
    console.log(`Keys: ${existingKeyCount} existing -> ${mergedKeyCount} merged ` +
        `(essential floor: ${Object.keys(essential).length}, extracted: ` +
        `${Object.keys(extractedFlat).length + v1Entries.length + v2Entries.length})`);
    console.log('='.repeat(60) + '\n');
    console.log(output);
    console.log('\n' + '='.repeat(60));
}

// Parse command line arguments
function parseArgs() {
    const args = process.argv.slice(2);
    let chainId = 31337; // Default

    if (args.length > 0) {
        const parsed = parseInt(args[0], 10);
        if (isNaN(parsed)) {
            console.error(`Error: Invalid chainId '${args[0]}'. Must be a number.`);
            console.error('Usage: node server/generate-ts-addresses.js [chainId]');
            console.error('  chainId: 31337 (Anvil), 1 (Mainnet)');
            process.exit(1);
        }
        chainId = parsed;
    }

    return chainId;
}

const chainId = parseArgs();
generateTsAddresses(chainId);
