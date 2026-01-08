const fs = require('fs');
const path = require('path');

/**
 * Extract contract addresses from progress file and generate local.json
 */
function extractAddresses() {
    const progressPath = path.join(__dirname, 'deployments', 'progress.31337.json');
    const outputPath = path.join(__dirname, 'deployments', 'local.json');

    // Check if progress file exists
    if (!fs.existsSync(progressPath)) {
        console.error('Error: progress.31337.json not found');
        console.error('Run deployment first: npm run deploy:local');
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

    // Process each contract
    for (const [name, data] of Object.entries(progressData.contracts || {})) {
        // Strip "Mock" prefix for UI compatibility (e.g., MockPhUSD -> PhUSD, MockUSDS -> USDS)
        const displayName = name.startsWith('Mock') ? name.slice(4) : name;
        extracted.contracts[displayName] = {
            address: data.address,
            deployed: data.deployed,
            configured: data.configured,
            deployGas: data.deployGas,
            configGas: data.configGas
        };
    }

    // Write extracted addresses
    fs.writeFileSync(outputPath, JSON.stringify(extracted, null, 2));

    console.log('\n==============================================');
    console.log('Address Extraction Complete');
    console.log('==============================================');
    console.log(`Input:  ${progressPath}`);
    console.log(`Output: ${outputPath}`);
    console.log(`\nExtracted ${Object.keys(extracted.contracts).length} contracts:`);

    for (const [displayName, data] of Object.entries(extracted.contracts)) {
        const status = data.configured ? '✓ configured' : '⚠ not configured';
        console.log(`  - ${displayName.padEnd(25)} ${data.address} (${status})`);
    }

    console.log('==============================================\n');
}

// Run extraction
try {
    extractAddresses();
} catch (error) {
    console.error('Error extracting addresses:', error.message);
    process.exit(1);
}
