const fs = require('fs');
const path = require('path');

/**
 * Chain ID to output file mapping
 */
const CHAIN_OUTPUT_MAP = {
    31337: 'local.json',      // Anvil/Local
    11155111: 'sepolia.json', // Sepolia
    1: 'mainnet.json'         // Mainnet
};

/**
 * Chain ID to network name mapping
 */
const CHAIN_NAME_MAP = {
    31337: 'anvil',
    11155111: 'sepolia',
    1: 'mainnet'
};

/**
 * Zero address constant for filtering checkpoint entries
 */
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * NFT contract base names that should be nested under nftsV1/nftsV2.
 * Names without "V2" suffix go to nftsV1; names with "V2" suffix get stripped and go to nftsV2.
 * BurnRecorder, NFTMigrator, and BalancerRouter stay flat.
 */
const NFT_BASE_NAMES = ["NFTMinter", "BurnerEYE", "BurnerSCX", "BurnerFlax", "BalancerPooler", "GatherWBTC"];

/**
 * Extract contract addresses from progress file and generate deployment JSON
 * @param {number} chainId - The chain ID to extract addresses for (default: 31337)
 */
function extractAddresses(chainId = 31337) {
    const progressPath = path.join(__dirname, 'deployments', `progress.${chainId}.json`);
    const outputFileName = CHAIN_OUTPUT_MAP[chainId] || `chain-${chainId}.json`;
    const outputPath = path.join(__dirname, 'deployments', outputFileName);

    // Check if progress file exists
    if (!fs.existsSync(progressPath)) {
        console.error(`Error: progress.${chainId}.json not found`);
        const networkName = CHAIN_NAME_MAP[chainId] || `chain ${chainId}`;
        console.error(`Run deployment first for ${networkName}`);
        process.exit(1);
    }

    // Read progress file
    const progressData = JSON.parse(fs.readFileSync(progressPath, 'utf-8'));

    // Extract contract addresses into clean format
    const extracted = {
        chainId: progressData.chainId,
        networkName: progressData.networkName,
        deploymentStatus: progressData.deploymentStatus,
        extractedAt: new Date().toISOString(),
        contracts: {},
        nftsV1: {},
        nftsV2: {}
    };

    // Track filtered entries for logging
    let filteredCount = 0;

    // Process each contract
    for (const [name, data] of Object.entries(progressData.contracts || {})) {
        // Skip entries with zero address (checkpoint markers like "Seeding")
        if (data.address === ZERO_ADDRESS) {
            console.log(`  Skipping checkpoint entry: ${name} (zero address)`);
            filteredCount++;
            continue;
        }

        // Strip "Mock" prefix for UI compatibility (e.g., MockPhUSD -> PhUSD, MockUSDS -> USDS)
        const displayName = name.startsWith('Mock') ? name.slice(4) : name;

        const contractData = {
            address: data.address,
            deployed: data.deployed,
            configured: data.configured,
            deployGas: data.deployGas,
            configGas: data.configGas
        };

        // Check if this is a V2 NFT contract (e.g., "NFTMinterV2" -> base "NFTMinter")
        const v2Match = displayName.endsWith('V2') ? displayName.slice(0, -2) : null;
        if (v2Match && NFT_BASE_NAMES.includes(v2Match)) {
            extracted.nftsV2[v2Match] = contractData;
            continue;
        }

        // Check if this is a V1 NFT contract (e.g., "NFTMinter" without V2 suffix)
        if (NFT_BASE_NAMES.includes(displayName)) {
            extracted.nftsV1[displayName] = contractData;
            continue;
        }

        // Everything else stays flat
        extracted.contracts[displayName] = contractData;
    }

    // Write extracted addresses
    fs.writeFileSync(outputPath, JSON.stringify(extracted, null, 2));

    console.log('\n==============================================');
    console.log('Address Extraction Complete');
    console.log('==============================================');
    console.log(`Chain ID:     ${chainId}`);
    console.log(`Network:      ${CHAIN_NAME_MAP[chainId] || 'unknown'}`);
    console.log(`Input:        ${progressPath}`);
    console.log(`Output:       ${outputPath}`);
    if (filteredCount > 0) {
        console.log(`Filtered:     ${filteredCount} checkpoint entries (zero address)`);
    }

    const flatCount = Object.keys(extracted.contracts).length;
    const v1Count = Object.keys(extracted.nftsV1).length;
    const v2Count = Object.keys(extracted.nftsV2).length;
    console.log(`\nExtracted ${flatCount} flat contracts, ${v1Count} nftsV1, ${v2Count} nftsV2:`);

    console.log('\n  Flat contracts:');
    for (const [displayName, data] of Object.entries(extracted.contracts)) {
        const status = data.configured ? '✓ configured' : '⚠ not configured';
        console.log(`  - ${displayName.padEnd(25)} ${data.address} (${status})`);
    }

    if (v1Count > 0) {
        console.log('\n  nftsV1:');
        for (const [displayName, data] of Object.entries(extracted.nftsV1)) {
            const status = data.configured ? '✓ configured' : '⚠ not configured';
            console.log(`  - ${displayName.padEnd(25)} ${data.address} (${status})`);
        }
    }

    if (v2Count > 0) {
        console.log('\n  nftsV2:');
        for (const [displayName, data] of Object.entries(extracted.nftsV2)) {
            const status = data.configured ? '✓ configured' : '⚠ not configured';
            console.log(`  - ${displayName.padEnd(25)} ${data.address} (${status})`);
        }
    }

    console.log('==============================================\n');
}

// Parse command line arguments
function parseArgs() {
    const args = process.argv.slice(2);

    // Default to 31337 (Anvil) for backwards compatibility
    let chainId = 31337;

    if (args.length > 0) {
        const parsed = parseInt(args[0], 10);
        if (isNaN(parsed)) {
            console.error(`Error: Invalid chainId '${args[0]}'. Must be a number.`);
            console.error('Usage: node extract-addresses.js [chainId]');
            console.error('Supported chain IDs:');
            console.error('  31337     - Anvil/Local (default)');
            console.error('  11155111  - Sepolia testnet');
            console.error('  1         - Mainnet');
            process.exit(1);
        }
        chainId = parsed;
    }

    return chainId;
}

// Run extraction
try {
    const chainId = parseArgs();
    extractAddresses(chainId);
} catch (error) {
    console.error('Error extracting addresses:', error.message);
    process.exit(1);
}
