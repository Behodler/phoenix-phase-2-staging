const express = require('express');
const cors = require('cors');
const fs = require('fs');
const path = require('path');

const app = express();
const PORT = process.env.API_PORT || 3001;
const HOST = process.env.API_HOST || 'localhost';

// Enable CORS for local development
app.use(cors());
app.use(express.json());

/**
 * Load deployment data from progress file
 */
function loadDeployments() {
    try {
        const progressPath = path.join(__dirname, 'deployments', 'progress.31337.json');
        if (!fs.existsSync(progressPath)) {
            return null;
        }
        const data = fs.readFileSync(progressPath, 'utf-8');
        return JSON.parse(data);
    } catch (error) {
        console.error('Error loading deployments:', error.message);
        return null;
    }
}

/**
 * Load extracted addresses from local.json
 */
function loadExtractedAddresses() {
    try {
        const localPath = path.join(__dirname, 'deployments', 'local.json');
        if (!fs.existsSync(localPath)) {
            return null;
        }
        const data = fs.readFileSync(localPath, 'utf-8');
        return JSON.parse(data);
    } catch (error) {
        console.error('Error loading extracted addresses:', error.message);
        return null;
    }
}

/**
 * GET / - API documentation
 */
app.get('/', (req, res) => {
    res.json({
        name: 'Phoenix Phase 2 Local Deployment API',
        version: '1.0.0',
        endpoints: {
            '/': 'API documentation (this page)',
            '/health': 'Health check',
            '/contracts': 'Get all deployed contract addresses',
            '/contracts/:contractName': 'Get specific contract address',
            '/progress': 'Get deployment progress status'
        },
        availableContracts: [
            'PhUSD',
            'USDC',
            'USDT',
            'USDS',
            'Dola',
            'Toke',
            'EYE',
            'Pauser',
            'YieldStrategyUSDT',
            'YieldStrategyUSDS',
            'AutoDOLA',
            'MainRewarder',
            'YieldStrategyDola',
            'PhusdStableMinter',
            'StableYieldAccumulator',
            'PhlimboEA'
        ]
    });
});

/**
 * GET /health - Health check
 */
app.get('/health', (req, res) => {
    const deployments = loadDeployments();
    const extracted = loadExtractedAddresses();

    res.json({
        status: 'ok',
        timestamp: new Date().toISOString(),
        deploymentsLoaded: deployments !== null,
        extractedAddressesLoaded: extracted !== null,
        chainId: 31337,
        network: 'anvil'
    });
});

/**
 * GET /contracts - Get all deployed contract addresses as flat object
 */
app.get('/contracts', (req, res) => {
    const extracted = loadExtractedAddresses();

    if (!extracted) {
        return res.status(404).json({
            error: 'No deployment data found',
            message: 'Run deployment first: npm run deploy:local'
        });
    }

    // Return flat object: { "ContractName": "0xaddress", ... }
    const flatAddresses = {};
    if (extracted.contracts) {
        for (const [name, data] of Object.entries(extracted.contracts)) {
            flatAddresses[name] = data.address;
        }
    }

    res.json(flatAddresses);
});

/**
 * GET /contracts/:contractName - Get specific contract address
 */
app.get('/contracts/:contractName', (req, res) => {
    const extracted = loadExtractedAddresses();
    const contractName = req.params.contractName;

    if (!extracted) {
        return res.status(404).json({
            error: 'No deployment data found',
            message: 'Run deployment first: npm run deploy:local'
        });
    }

    if (!extracted.contracts || !extracted.contracts[contractName]) {
        return res.status(404).json({
            error: 'Contract not found',
            message: `Contract "${contractName}" does not exist`,
            availableContracts: Object.keys(extracted.contracts || {})
        });
    }

    res.json({
        name: contractName,
        address: extracted.contracts[contractName].address,
        deployed: extracted.contracts[contractName].deployed,
        configured: extracted.contracts[contractName].configured
    });
});

/**
 * GET /progress - Get deployment progress
 */
app.get('/progress', (req, res) => {
    const deployments = loadDeployments();

    if (!deployments) {
        return res.status(404).json({
            error: 'No deployment progress found',
            message: 'Run deployment first: npm run deploy:local'
        });
    }

    res.json(deployments);
});

// Start server
app.listen(PORT, HOST, () => {
    console.log(`\n==============================================`);
    console.log(`Phoenix Phase 2 Local Deployment API`);
    console.log(`==============================================`);
    console.log(`Server running at: http://${HOST}:${PORT}`);
    console.log(`Chain ID: 31337 (Anvil)`);
    console.log(`\nAvailable endpoints:`);
    console.log(`  GET  /              - API documentation`);
    console.log(`  GET  /health        - Health check`);
    console.log(`  GET  /contracts     - All deployed contracts`);
    console.log(`  GET  /contracts/:name - Specific contract`);
    console.log(`  GET  /progress      - Deployment progress`);
    console.log(`\nExample requests:`);
    console.log(`  curl http://${HOST}:${PORT}/health`);
    console.log(`  curl http://${HOST}:${PORT}/contracts`);
    console.log(`  curl http://${HOST}:${PORT}/contracts/PhlimboEA`);
    console.log(`==============================================\n`);

    // Log deployment status
    const deployments = loadDeployments();
    if (deployments) {
        console.log(`Deployment Status: ${deployments.deploymentStatus}`);
        console.log(`Contracts Deployed: ${Object.keys(deployments.contracts || {}).length}`);
    } else {
        console.log(`No deployments found. Run: npm run deploy:local`);
    }
    console.log('');
});
