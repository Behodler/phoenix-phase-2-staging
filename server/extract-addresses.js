const fs = require('fs');
const path = require('path');

/**
 * Chain ID to output file mapping
 */
const CHAIN_OUTPUT_MAP = {
    31337: 'local.json',      // Anvil/Local
    1: 'mainnet.json'         // Mainnet
};

/**
 * Chain ID to network name mapping
 */
const CHAIN_NAME_MAP = {
    31337: 'anvil',
    1: 'mainnet'
};

/**
 * Zero address constant for filtering checkpoint entries
 */
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

/**
 * NFT contract base names (V2 only). Contracts with a "V2" suffix matching these names
 * are written to flat `contracts` under the stripped base name. Bare-name (V1) contracts
 * and NFTMigrator are dropped entirely.
 */
const NFT_BASE_NAMES = ["NFTMinter", "BurnerEYE", "BurnerSCX", "BurnerFlax", "BalancerPooler", "GatherWBTC"];

/**
 * Contracts to drop from extraction entirely (V1 NFTs are handled via NFT_BASE_NAMES;
 * NFTMigrator is explicitly dropped here as a belt-and-suspenders guard).
 *
 * BuggedPoolerV2Index6 is a deploy-only placeholder: a disabled BalancerPoolerV2
 * registered at dispatcher index 6 purely to mirror mainnet's index layout (so the
 * local NudgeRatchet lands at index 7). It is never enabled and never minted, so it
 * must not be surfaced as a consumable address in the ContractAddresses interface.
 */
const DROPPED_CONTRACT_NAMES = ["NFTMigrator", "BuggedPoolerV2Index6"];

/**
 * Raw Uniswap V2 stack that backs the Uniboost dispatchers (WETH9, the canonical
 * factory/router, the Uniboost target pools, and the routing pools). These are deployed
 * locally only so Uniboost has an AMM to swap against; the UI never interacts with UniV2
 * directly (all routing is wired on-chain inside the Uniboost dispatchers/hooks). They are
 * therefore not part of the UI-facing ContractAddresses surface and are dropped from
 * extraction so they stop appearing in the generated interface (and in the hand-maintained
 * mainnet file, whose key-set must mirror that interface). On mainnet Uniboost would reuse
 * the live UniV2 deployment, so there is nothing UI-consumable to surface there either.
 */
const UNISWAP_V2_BACKING_NAMES = [
    "WETH9",
    "UniswapV2Factory",
    "UniswapV2Router02",
    "UniPoolEYE",
    "UniPoolSCX",
    "UniPoolFLX",
    "UniRoutePoolWETH",
    "UniRoutePoolUSDS",
    "UniRoutePoolDOLA",
];

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
        contracts: {}
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

        // Drop explicitly excluded contracts (NFTMigrator and bare V1 NFT names)
        if (DROPPED_CONTRACT_NAMES.includes(displayName)) {
            console.log(`  Dropping excluded contract: ${displayName}`);
            continue;
        }

        // Drop the raw UniV2 stack that backs Uniboost — not UI-consumable (see constant above)
        if (UNISWAP_V2_BACKING_NAMES.includes(displayName)) {
            console.log(`  Dropping UniV2 backing contract: ${displayName}`);
            continue;
        }

        // Drop bare-name V1 NFT contracts (e.g. "NFTMinter" without V2 suffix)
        if (NFT_BASE_NAMES.includes(displayName)) {
            console.log(`  Dropping V1 NFT contract: ${displayName}`);
            continue;
        }

        const contractData = {
            address: data.address,
            deployed: data.deployed,
            configured: data.configured,
            deployGas: data.deployGas,
            configGas: data.configGas
        };

        // Check if this is a V2 NFT contract (e.g., "NFTMinterV2" -> base "NFTMinter")
        // Route to flat contracts under the stripped base name.
        const v2Match = displayName.endsWith('V2') ? displayName.slice(0, -2) : null;
        if (v2Match && NFT_BASE_NAMES.includes(v2Match)) {
            extracted.contracts[v2Match] = contractData;
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
    console.log(`\nExtracted ${flatCount} flat contracts:`);

    console.log('\n  Flat contracts:');
    for (const [displayName, data] of Object.entries(extracted.contracts)) {
        const status = data.configured ? '✓ configured' : '⚠ not configured';
        console.log(`  - ${displayName.padEnd(25)} ${data.address} (${status})`);
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
