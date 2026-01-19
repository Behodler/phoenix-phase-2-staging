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

    // Build TypeScript object literal
    const lines = [];
    lines.push(`// Generated from ${inputFile} on ${new Date().toISOString()}`);
    lines.push(`// Chain ID: ${chainId} (${networkName})`);
    lines.push('');
    lines.push(`export const ${networkName}Addresses = {`);

    const contracts = Object.entries(data.contracts || {});
    contracts.forEach(([name, contract], index) => {
        const comma = index < contracts.length - 1 ? ',' : '';
        lines.push(`  ${name}: "${contract.address}" ${comma}`);
    });

    lines.push('};');
    lines.push('');
    lines.push(`export type ${networkName.charAt(0).toUpperCase() + networkName.slice(1)}ContractName = keyof typeof ${networkName}Addresses;`);

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
