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
 *   node server/generate-ts-addresses.js 11155111  # Sepolia
 *   node server/generate-ts-addresses.js           # Defaults to 31337
 */

const fs = require('fs');
const path = require('path');

// Chain ID to input file mapping
const CHAIN_FILE_MAP = {
    31337: 'local.json',
    11155111: 'sepolia.json',
    1: 'mainnet.json'
};

// Chain ID to output file mapping
const CHAIN_OUTPUT_MAP = {
    31337: 'local-addresses.ts',
    11155111: 'sepolia-addresses.ts',
    1: 'mainnet-addresses.ts'
};

const CHAIN_NAME_MAP = {
    31337: 'anvil',
    11155111: 'sepolia',
    1: 'mainnet'
};

function generateInterfaceFile(chainId, inputFile, contracts, nftsV1, nftsV2) {
    const interfacePath = path.join(__dirname, 'deployments', 'addresses.ts');
    const networkName = CHAIN_NAME_MAP[chainId];
    const timestamp = new Date().toISOString();

    const lines = [];
    lines.push(`// Generated interface from ${inputFile} on ${timestamp}`);
    lines.push(`// Chain ID: ${chainId} (${networkName})`);
    lines.push('// This interface can be copied directly into UI projects');
    lines.push('');

    // Generate YieldNFTAddresses sub-interface from nftsV1 keys (or nftsV2 — same shape)
    const nftKeys = Object.keys(nftsV1).length > 0 ? Object.keys(nftsV1) : Object.keys(nftsV2);
    if (nftKeys.length > 0) {
        lines.push('export interface YieldNFTAddresses {');
        nftKeys.forEach((name) => {
            lines.push(`  ${name}: string;`);
        });
        lines.push('}');
        lines.push('');
    }

    lines.push('export interface ContractAddresses {');

    contracts.forEach(([name]) => {
        lines.push(`  ${name}: string;`);
    });

    // Add nested nftsV1/nftsV2 fields
    if (nftKeys.length > 0) {
        lines.push('  nftsV1: YieldNFTAddresses;');
        lines.push('  nftsV2: YieldNFTAddresses;');
    }

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
    const inputFile = CHAIN_FILE_MAP[chainId];
    const outputFile = CHAIN_OUTPUT_MAP[chainId];
    const networkName = CHAIN_NAME_MAP[chainId] || 'unknown';

    if (!inputFile) {
        console.error(`Error: Unsupported chainId '${chainId}'.`);
        console.error('Supported chain IDs: 31337 (Anvil), 11155111 (Sepolia), 1 (Mainnet)');
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

    // For local/anvil, generate the interface file first
    if (chainId === 31337) {
        generateInterfaceFile(chainId, inputFile, contracts, nftsV1, nftsV2);
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

    // Write flat contracts
    contracts.forEach(([name, contract]) => {
        lines.push(`  ${name}: "${contract.address}",`);
    });

    // Write nested nftsV1
    const v1Entries = Object.entries(nftsV1);
    if (v1Entries.length > 0) {
        lines.push('  nftsV1: {');
        v1Entries.forEach(([name, contract]) => {
            lines.push(`    ${name}: "${contract.address}",`);
        });
        lines.push('  },');
    }

    // Write nested nftsV2
    const v2Entries = Object.entries(nftsV2);
    if (v2Entries.length > 0) {
        lines.push('  nftsV2: {');
        v2Entries.forEach(([name, contract]) => {
            lines.push(`    ${name}: "${contract.address}",`);
        });
        lines.push('  },');
    }

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

// Parse command line arguments
function parseArgs() {
    const args = process.argv.slice(2);
    let chainId = 31337; // Default

    if (args.length > 0) {
        const parsed = parseInt(args[0], 10);
        if (isNaN(parsed)) {
            console.error(`Error: Invalid chainId '${args[0]}'. Must be a number.`);
            console.error('Usage: node server/generate-ts-addresses.js [chainId]');
            console.error('  chainId: 31337 (Anvil), 11155111 (Sepolia), 1 (Mainnet)');
            process.exit(1);
        }
        chainId = parsed;
    }

    return chainId;
}

const chainId = parseArgs();
generateTsAddresses(chainId);
