#!/usr/bin/env node

/**
 * Generate TypeScript-compatible address object from extracted deployment data.
 * Outputs an object literal that can be copied directly into TypeScript code.
 *
 * ANVIL (chainId 31337) and SEPOLIA (chainId 11155111).
 *
 * 31337 is the ONLY chain that (re)generates the `ContractAddresses` interface in
 * `deployments/addresses.ts`. Sepolia (story 098) writes `deployments/sepolia-addresses.ts`
 * (`export const sepoliaAddresses: ContractAddresses`) AGAINST the existing interface and never
 * touches `addresses.ts`: if the Sepolia key set differs from the interface's in any way, the
 * script fails loudly and writes nothing, so drift is fixed deliberately rather than papered over.
 *
 * The mainnet (chainId 1) codegen path was removed deliberately. Mainnet is an
 * ever-evolving target whose addresses are maintained by hand in
 * `deployments/mainnet-addresses.ts` and surgically updated by the
 * `scripts/patch-mainnet-addresses-*.js` patchers run after each mainnet
 * broadcast. The hand-written `: ContractAddresses` annotation on that file is
 * the compile-time guard that keeps it from drifting. A merge-from-extraction
 * codegen could only ever clobber that curated file with a stale
 * `mainnet.json` snapshot, so it is intentionally not supported here.
 *
 * Usage:
 *   node server/generate-ts-addresses.js [chainId]
 *
 * Examples:
 *   node server/generate-ts-addresses.js 31337     # Local/Anvil
 *   node server/generate-ts-addresses.js 11155111  # Sepolia (interface read-only)
 *   node server/generate-ts-addresses.js           # Defaults to 31337
 */

const fs = require('fs');
const path = require('path');

// Chain ID to input file mapping
const CHAIN_FILE_MAP = {
    31337: 'local.json',
    11155111: 'sepolia.json'
};

// Chain ID to output file mapping
const CHAIN_OUTPUT_MAP = {
    31337: 'local-addresses.ts',
    11155111: 'sepolia-addresses.ts'
};

const CHAIN_NAME_MAP = {
    31337: 'anvil',
    11155111: 'sepolia'
};

// The only chain whose extraction defines the ContractAddresses interface.
const INTERFACE_SOURCE_CHAIN_ID = 31337;

/**
 * Reads the key set of `export interface ContractAddresses { ... }` from addresses.ts.
 * Exits non-zero if the file or the interface block cannot be found.
 */
function readInterfaceKeys() {
    const interfacePath = path.join(__dirname, 'deployments', 'addresses.ts');
    if (!fs.existsSync(interfacePath)) {
        console.error(`Error: interface file not found: ${interfacePath}`);
        process.exit(1);
    }
    const source = fs.readFileSync(interfacePath, 'utf-8');
    const block = source.match(/export interface ContractAddresses\s*\{([\s\S]*?)\n\}/);
    if (!block) {
        console.error(`Error: no 'export interface ContractAddresses { ... }' block in ${interfacePath}`);
        process.exit(1);
    }
    const keys = [];
    for (const line of block[1].split('\n')) {
        const m = line.match(/^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*string\s*;/);
        if (m) keys.push(m[1]);
    }
    if (keys.length === 0) {
        console.error(`Error: ContractAddresses in ${interfacePath} has no keys`);
        process.exit(1);
    }
    return keys;
}

/**
 * Fails loudly (exit 2) unless `contractNames` is exactly the interface key set.
 */
function assertKeySetMatchesInterface(chainId, inputFile, contractNames, interfaceKeys) {
    const have = new Set(contractNames);
    const want = new Set(interfaceKeys);
    const missing = interfaceKeys.filter((k) => !have.has(k));
    const extra = contractNames.filter((k) => !want.has(k));
    if (missing.length === 0 && extra.length === 0) {
        console.log(`Key set OK: ${contractNames.length}/${interfaceKeys.length} keys match ContractAddresses`);
        return;
    }
    console.error('\n' + '='.repeat(60));
    console.error(`REFUSING: ${inputFile} (chainId ${chainId}) key set != ContractAddresses interface`);
    console.error('='.repeat(60));
    console.error(`Interface keys: ${interfaceKeys.length}, extracted keys: ${contractNames.length}`);
    if (missing.length) console.error(`Missing from ${inputFile}: ${missing.join(', ')}`);
    if (extra.length) console.error(`Not in the interface: ${extra.join(', ')}`);
    console.error('addresses.ts is generated from chain 31337 only and is NOT rewritten here.');
    console.error('Fix the deploy script (or the interface, via a local deploy) so the sets agree.');
    console.error('Nothing was written.');
    console.error('='.repeat(60) + '\n');
    process.exit(2);
}

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

function generateTsAddresses(chainId) {
    // Mainnet is hand-maintained — never regenerate it from an extraction.
    if (chainId === 1) {
        console.error('\n' + '='.repeat(60));
        console.error('REFUSING: mainnet (chainId 1) address codegen is not supported.');
        console.error('='.repeat(60));
        console.error('server/deployments/mainnet-addresses.ts is hand-maintained and kept');
        console.error('in sync with the ContractAddresses interface (the compile-time guard).');
        console.error('After a mainnet broadcast, update it with the matching');
        console.error('scripts/patch-mainnet-addresses-*.js patcher — never via codegen.');
        console.error('='.repeat(60) + '\n');
        process.exit(1);
    }

    const inputFile = CHAIN_FILE_MAP[chainId];
    const outputFile = CHAIN_OUTPUT_MAP[chainId];
    const networkName = CHAIN_NAME_MAP[chainId] || 'unknown';

    if (!inputFile) {
        console.error(`Error: Unsupported chainId '${chainId}'.`);
        console.error('Supported chain IDs: 31337 (Anvil), 11155111 (Sepolia)');
        process.exit(1);
    }

    const inputPath = path.join(__dirname, 'deployments', inputFile);
    const outputPath = path.join(__dirname, 'deployments', outputFile);

    if (!fs.existsSync(inputPath)) {
        console.error(`Error: Input file not found: ${inputPath}`);
        console.error(chainId === 11155111
            ? "Run 'npm run extract:sepolia' first."
            : "Run 'npm run extract:addresses' first.");
        process.exit(1);
    }

    // Read extracted addresses
    const data = JSON.parse(fs.readFileSync(inputPath, 'utf-8'));

    let contracts = Object.entries(data.contracts || {});

    if (chainId === INTERFACE_SOURCE_CHAIN_ID) {
        // Generate the interface file first
        generateInterfaceFile(chainId, inputFile, contracts);
    } else {
        // Non-anvil chains type against the EXISTING interface and must match it exactly.
        const interfaceKeys = readInterfaceKeys();
        assertKeySetMatchesInterface(chainId, inputFile, contracts.map(([name]) => name), interfaceKeys);
        // Emit in interface order so diffs against local-addresses.ts line up.
        const byName = new Map(contracts);
        contracts = interfaceKeys.map((name) => [name, byName.get(name)]);
    }

    // Build TypeScript object literal
    const lines = [];
    lines.push(`// Generated from ${inputFile} on ${new Date().toISOString()}`);
    lines.push(`// Chain ID: ${chainId} (${networkName})`);
    lines.push('');
    lines.push("import { ContractAddresses } from './addresses';");
    lines.push('');
    lines.push(`export const ${networkName}Addresses: ContractAddresses = {`);

    // Write flat contracts (all contracts including V2 NFTs)
    contracts.forEach(([name, contract]) => {
        lines.push(`  ${name}: "${contract.address}",`);
    });

    lines.push('};');
    lines.push('');
    lines.push(`export type ${networkName.charAt(0).toUpperCase() + networkName.slice(1)}ContractName = keyof ContractAddresses;`);

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

// Parse command line arguments
function parseArgs() {
    const args = process.argv.slice(2);
    let chainId = 31337; // Default

    if (args.length > 0) {
        const parsed = parseInt(args[0], 10);
        if (isNaN(parsed)) {
            console.error(`Error: Invalid chainId '${args[0]}'. Must be a number.`);
            console.error('Usage: node server/generate-ts-addresses.js [chainId]');
            console.error('  chainId: 31337 (Anvil) | 11155111 (Sepolia)');
            process.exit(1);
        }
        chainId = parsed;
    }

    return chainId;
}

const chainId = parseArgs();
generateTsAddresses(chainId);
