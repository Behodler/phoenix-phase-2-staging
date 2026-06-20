#!/usr/bin/env node

/**
 * Generate TypeScript-compatible address object from extracted deployment data.
 * Outputs an object literal that can be copied directly into TypeScript code.
 *
 * ANVIL (chainId 31337) ONLY.
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
 *   node server/generate-ts-addresses.js           # Defaults to 31337
 */

const fs = require('fs');
const path = require('path');

// Chain ID to input file mapping (anvil only)
const CHAIN_FILE_MAP = {
    31337: 'local.json'
};

// Chain ID to output file mapping (anvil only)
const CHAIN_OUTPUT_MAP = {
    31337: 'local-addresses.ts'
};

const CHAIN_NAME_MAP = {
    31337: 'anvil'
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
        console.error('Supported chain IDs: 31337 (Anvil)');
        process.exit(1);
    }

    const inputPath = path.join(__dirname, 'deployments', inputFile);
    const outputPath = path.join(__dirname, 'deployments', outputFile);

    if (!fs.existsSync(inputPath)) {
        console.error(`Error: Input file not found: ${inputPath}`);
        console.error("Run 'npm run extract:addresses' first.");
        process.exit(1);
    }

    // Read extracted addresses
    const data = JSON.parse(fs.readFileSync(inputPath, 'utf-8'));

    const contracts = Object.entries(data.contracts || {});

    // Generate the interface file first
    generateInterfaceFile(chainId, inputFile, contracts);

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
            console.error('  chainId: 31337 (Anvil)');
            process.exit(1);
        }
        chainId = parsed;
    }

    return chainId;
}

const chainId = parseArgs();
generateTsAddresses(chainId);
