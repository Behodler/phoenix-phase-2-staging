#!/usr/bin/env node
/**
 * check-dry-run-autousdc.js
 *
 * This script validates the progress.autoUSDC.1.json file from a dry run to ensure
 * it completed successfully before allowing a fresh mainnet deployment.
 *
 * Exit codes:
 *   0 - Dry run was successful, safe to proceed with fresh deployment
 *   1 - Error: No progress file found (must run deploy:autousdc-mainnet-preview first)
 *   2 - Error: Progress file indicates deployment failed or is incomplete
 *   3 - Error: Could not parse progress file
 */

const fs = require('fs');
const path = require('path');

const PROGRESS_FILE = path.join(__dirname, '..', 'server', 'deployments', 'progress.autoUSDC.1.json');

function checkDryRun() {
    console.log('==========================================');
    console.log('  Validating AutoUSDC Dry Run Results');
    console.log('==========================================');
    console.log('');

    // Check if progress file exists
    if (!fs.existsSync(PROGRESS_FILE)) {
        console.error('ERROR: progress.autoUSDC.1.json not found!');
        console.error('');
        console.error('You must run a dry run first:');
        console.error('  npm run deploy:autousdc-mainnet-preview');
        console.error('');
        console.error('The dry run will generate progress.autoUSDC.1.json which is used to:');
        console.error('  1. Verify all deployment steps would succeed');
        console.error('  2. Validate contract addresses and configurations');
        console.error('');
        process.exit(1);
    }

    console.log('Found progress file:', PROGRESS_FILE);

    // Read and parse progress file
    let progress;
    try {
        const content = fs.readFileSync(PROGRESS_FILE, 'utf8');
        progress = JSON.parse(content);
    } catch (err) {
        console.error('ERROR: Could not parse progress.autoUSDC.1.json');
        console.error('Parse error:', err.message);
        console.error('');
        console.error('The progress file may be corrupted. Please run the dry run again:');
        console.error('  npm run deploy:autousdc-mainnet-preview');
        console.error('');
        process.exit(3);
    }

    // Validate chain ID
    if (progress.chainId !== 1) {
        console.error('ERROR: Progress file is for wrong chain!');
        console.error(`  Expected chainId: 1 (mainnet)`);
        console.error(`  Found chainId: ${progress.chainId}`);
        console.error('');
        console.error('Please run the dry run on mainnet:');
        console.error('  npm run deploy:autousdc-mainnet-preview');
        console.error('');
        process.exit(2);
    }

    console.log('Chain ID:', progress.chainId, '(mainnet)');
    console.log('Network:', progress.networkName);
    console.log('Status:', progress.deploymentStatus);
    console.log('');

    // Check deployment status
    if (progress.deploymentStatus !== 'completed') {
        console.error('ERROR: Dry run did not complete successfully!');
        console.error(`  Status: ${progress.deploymentStatus}`);
        console.error('');
        console.error('The dry run must show "completed" status before proceeding.');
        console.error('Please review the dry run logs and fix any issues, then run:');
        console.error('  npm run deploy:autousdc-mainnet-preview');
        console.error('');

        // Show which contracts failed
        if (progress.contracts) {
            console.log('Contract Status:');
            for (const [name, contract] of Object.entries(progress.contracts)) {
                const deployStatus = contract.deployed ? 'DEPLOYED' : 'NOT DEPLOYED';
                const configStatus = contract.configured ? 'CONFIGURED' : 'NOT CONFIGURED';
                const icon = (contract.deployed && contract.configured) ? '  OK' : '  FAIL';
                console.log(`${icon} ${name}: ${deployStatus}, ${configStatus}`);
            }
            console.log('');
        }

        process.exit(2);
    }

    // Validate all contracts are deployed and configured
    let allSuccess = true;
    const failures = [];

    console.log('Contract Deployment Results:');
    console.log('----------------------------');

    if (progress.contracts) {
        for (const [name, contract] of Object.entries(progress.contracts)) {
            const deployStatus = contract.deployed ? 'OK' : 'FAIL';
            const configStatus = contract.configured ? 'OK' : 'FAIL';

            const success = contract.deployed && contract.configured;
            const icon = success ? '  OK' : '  FAIL';

            console.log(`${icon} ${name}`);
            console.log(`      Address: ${contract.address || 'N/A'}`);
            console.log(`      Deployed: ${deployStatus}, Configured: ${configStatus}`);

            if (!success) {
                allSuccess = false;
                failures.push({
                    name,
                    deployed: contract.deployed,
                    configured: contract.configured
                });
            }
        }
    }

    console.log('');

    if (!allSuccess) {
        console.error('ERROR: Some contracts failed deployment or configuration!');
        console.error('');
        console.error('Failed contracts:');
        for (const failure of failures) {
            console.error(`  - ${failure.name}: deployed=${failure.deployed}, configured=${failure.configured}`);
        }
        console.error('');
        console.error('Please review the dry run logs and fix any issues, then run:');
        console.error('  npm run deploy:autousdc-mainnet-preview');
        console.error('');
        process.exit(2);
    }

    // All checks passed
    console.log('==========================================');
    console.log('  DRY RUN VALIDATION PASSED');
    console.log('==========================================');
    console.log('');
    console.log('All AutoUSDC deployment steps completed successfully in dry run.');
    console.log('');
    console.log('IMPORTANT REMINDERS:');
    console.log('  1. Verify all mainnet addresses are correct');
    console.log('  2. Ensure Ledger is connected and unlocked');
    console.log('  3. Verify account index 46 is correct');
    console.log('  4. Have sufficient ETH for gas fees');
    console.log('');
    console.log('The fresh deployment will now:');
    console.log('  1. Delete progress.autoUSDC.1.json');
    console.log('  2. Run the deployment script with --broadcast');
    console.log('  3. Generate a new progress.autoUSDC.1.json as it deploys');
    console.log('');
    console.log('Proceeding with AutoUSDC deployment...');
    console.log('');

    process.exit(0);
}

checkDryRun();
