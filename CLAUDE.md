# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

The phStaging2 project provides **Phase 2 deployment staging infrastructure** for the Phoenix ecosystem. This is a sibling project to deployment-staging-RM (Phase 1) and serves as the orchestration layer for deploying Phase 2 contracts (stable yield accumulator, phlimbo, phUSD minter) to multiple networks.

**Key Role**: This project:
- Deploys Phase 2 contracts to Anvil (local), Sepolia (testnet), and Mainnet
- Tracks deployment progress per network using `progress.<chainId>.json` files
- Generates contract addresses and ABIs for consumption by Phoenix UI and other applications
- Serves deployment data via REST API on port 3001
- Generates type-safe Wagmi hooks for React/TypeScript frontends
- Provides resilient deployment workflows that can resume from checkpoint on failure

**Sibling Relationship**:
- **deployment-staging-RM**: Phase 1 contracts (vault-RM, reflax-mint bonding, etc.)
- **phStaging2**: Phase 2 contracts (stable-yield-accumulator, phlimbo, phUSD-stable-minter)
- Both projects share similar architecture patterns but manage different contract sets

## Architecture Overview

This project acts as a **deployment orchestration layer** that:
- Imports Phase 2 contract code via git submodules
- Deploys contracts to multiple networks with resilient checkpoint-based workflow
- Tracks deployment state per network in `progress.<chainId>.json` files
- Generates structured JSON containing contract addresses and ABIs
- Serves deployment data via local HTTP endpoint for UI integration
- Generates type-safe Wagmi hooks for React/TypeScript frontends
- Supports resuming failed deployments from last successful checkpoint

### Multi-Network Support

This project supports three deployment targets:

| Network | Chain ID | Use Case | RPC URL |
|---------|----------|----------|---------|
| Anvil | 31337 | Local development | http://localhost:8545 |
| Sepolia | 11155111 | Testnet deployment | https://sepolia.infura.io/v3/... |
| Mainnet | 1 | Production deployment | https://mainnet.infura.io/v3/... |

Each network maintains its own deployment state file: `progress.31337.json`, `progress.11155111.json`, `progress.1.json`

## Phase 2 Contracts

The following contracts are deployed as part of Phase 2:

### Stable Yield Accumulator
**Location**: `lib/stable-yield-accumulator/`
**Purpose**: Accumulates yield from stablecoins and distributes to stakeholders
**Git Submodule**: https://github.com/Behodler/stable-yield-accumulator

### Phlimbo
**Location**: `lib/phlimbo/`
**Purpose**: Yield farm for staking phUSD and earning mixed yield in phUSD and a stablecoin such as USDC
**Git Submodule**: https://github.com/Behodler/phlimbo

### phUSD Stable Minter
**Location**: `lib/phUSD-stable-minter/`
**Purpose**: Minting mechanisms for phUSD stablecoin
**Git Submodule**: https://github.com/Behodler/phUSD-stable-minter

**CRITICAL TERMINOLOGY**: The token is **phUSD** (Phoenix USD), NOT pxUSD. pxUSD is a completely different token from another company that exists on mainnet. Always use phUSD in all code, documentation, and user-facing text.

## Project Structure

```
phStaging2/
├── lib/                          # Git submodules
│   ├── forge-std/               # Foundry standard library
│   ├── stable-yield-accumulator/ # Phase 2: Yield accumulation
│   ├── phlimbo/                 # Phase 2: Yield farm for phUSD staking
│   ├── phUSD-stable-minter/     # Phase 2: phUSD minting
│   ├── mutable/                 # Mutable dependencies (interfaces only)
│   └── immutable/               # Immutable dependencies (full source)
├── script/
│   ├── DeployAnvil.s.sol        # Anvil deployment script
│   ├── DeploySepolia.s.sol      # Sepolia deployment script
│   ├── DeployMainnet.s.sol      # Mainnet deployment script
│   └── helpers/                 # Deployment helper contracts
├── src/
│   ├── mocks/                   # Mock contracts for testing
│   └── interfaces/              # Contract interfaces
├── test/                        # Test files (TDD required)
├── out/                         # Foundry build artifacts
├── server/                      # Node.js API server
│   ├── index.js                # Serves deployment data via GET endpoint
│   ├── deployments/            # Generated deployment JSON files
│   └── extract-addresses.js    # Extracts addresses from Foundry artifacts
├── hooks/                       # Generated Wagmi hooks
├── progress.31337.json          # Anvil deployment state
├── progress.11155111.json       # Sepolia deployment state
├── progress.1.json              # Mainnet deployment state
├── foundry.toml                # Foundry configuration with remappings
├── package.json                # Scripts for deployment workflow
├── wagmi.config.ts             # Wagmi hook generation config
├── .env                        # Environment variables (gitignored)
└── .env.example                # Example environment variables
```

## Git Submodules

### Initial Setup
```bash
# Initialize all submodules
git submodule update --init --recursive

# Update submodules to latest commits
git submodule update --remote
```

### Submodule Management
- **Never commit changes inside lib/ directories** - those are managed by their respective repos
- Update submodule references when new contract versions are needed
- Pin specific commits for reproducible deployments
- Exclude forge-std and openzeppelin from deployment (testing/dependency only)

### Current Submodules
```
lib/forge-std              - Foundry testing framework (excluded from deployment)
lib/stable-yield-accumulator - Phase 2: Yield accumulation contracts
lib/phlimbo               - Phase 2: Yield farm for phUSD staking
lib/phUSD-stable-minter   - Phase 2: phUSD minting contracts
```

### Foundry Remappings
The `foundry.toml` should include remappings for clean imports:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]

remappings = [
    "@stable-yield-accumulator/=lib/stable-yield-accumulator/src/",
    "@phlimbo/=lib/phlimbo/src/",
    "@phUSD-stable-minter/=lib/phUSD-stable-minter/src/",
    "@openzeppelin/=lib/openzeppelin-contracts/contracts/",
    "@forge-std/=lib/forge-std/src/"
]
```

## Deployment Progress Tracking

### Progress File Format

Each network maintains a `progress.<chainId>.json` file that tracks deployment state:

```json
{
  "chainId": 31337,
  "networkName": "anvil",
  "lastUpdated": "2025-12-14T10:30:00Z",
  "deploymentStatus": "in_progress",
  "completedSteps": [
    {
      "step": "deploy_stable_yield_accumulator",
      "contract": "StableYieldAccumulator",
      "address": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
      "timestamp": "2025-12-14T10:15:00Z",
      "txHash": "0x..."
    },
    {
      "step": "deploy_phlimbo",
      "contract": "Phlimbo",
      "address": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
      "timestamp": "2025-12-14T10:20:00Z",
      "txHash": "0x..."
    }
  ],
  "pendingSteps": [
    "deploy_phUSD_minter",
    "initialize_contracts",
    "verify_deployment"
  ],
  "failedSteps": [],
  "metadata": {
    "deployer": "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "gasUsed": "1234567",
    "estimatedCost": "0.123 ETH"
  }
}
```

### Resilient Deployment Pattern

Deployments can fail partway through due to:
- Network issues
- Gas price spikes
- Contract initialization errors
- Manual cancellation

The progress file enables **checkpoint-based recovery**:

1. **Before each step**: Check progress file for completion
2. **Skip completed steps**: Don't re-deploy already deployed contracts
3. **Resume from checkpoint**: Continue from the first pending step
4. **Update on success**: Mark step complete and update progress file
5. **Record failures**: Log failed steps with error details for debugging

### Progress File States

| Status | Description | Action |
|--------|-------------|--------|
| `not_started` | No deployment attempted | Begin from first step |
| `in_progress` | Deployment underway | Resume from first pending step |
| `completed` | All steps successful | Skip deployment, serve data |
| `failed` | Unrecoverable error | Review failed steps, manual intervention |

### Multi-Network Progress Isolation

Each network's progress is **completely independent**:
- Anvil deployment failure doesn't affect Sepolia
- Can deploy to multiple networks in parallel
- Each network has its own contract addresses
- Progress files prevent re-deployment to already-deployed networks

## Deployment Workflow

### Automated Development Flow

The `package.json` should provide scripts for each network:

#### Anvil (Local Development)
```json
{
  "scripts": {
    "start:anvil": "anvil --host 0.0.0.0 --port 8545 --chain-id 31337",
    "deploy:anvil": "forge script script/DeployAnvil.s.sol:DeployAnvil --rpc-url http://localhost:8545 --broadcast",
    "extract:anvil": "node server/extract-addresses.js 31337",
    "generate:hooks": "wagmi generate",
    "serve": "node server/index.js",
    "dev:anvil": "npm run start:anvil & sleep 2 && npm run deploy:anvil && npm run extract:anvil && npm run generate:hooks && npm run serve"
  }
}
```

#### Sepolia (Testnet)
```json
{
  "scripts": {
    "deploy:sepolia": "forge script script/DeploySepolia.s.sol:DeploySepolia --rpc-url $SEPOLIA_RPC_URL --broadcast --verify",
    "extract:sepolia": "node server/extract-addresses.js 11155111",
    "dev:sepolia": "npm run deploy:sepolia && npm run extract:sepolia && npm run generate:hooks && npm run serve"
  }
}
```

#### Mainnet (Production)
```json
{
  "scripts": {
    "deploy:mainnet": "forge script script/DeployMainnet.s.sol:DeployMainnet --rpc-url $MAINNET_RPC_URL --broadcast --verify --slow",
    "extract:mainnet": "node server/extract-addresses.js 1",
    "dev:mainnet": "npm run deploy:mainnet && npm run extract:mainnet && npm run generate:hooks && npm run serve"
  }
}
```

### Deployment Script Structure

Each deployment script (DeployAnvil.s.sol, DeploySepolia.s.sol, DeployMainnet.s.sol) should:

1. **Load progress file**: Read `progress.<chainId>.json`
2. **Skip completed steps**: Check which contracts are already deployed
3. **Deploy missing contracts**: Only deploy what's needed
4. **Initialize contracts**: Configure deployed contracts
5. **Update progress**: Mark completed steps
6. **Log addresses**: Output for extraction
7. **Handle failures**: Record errors in progress file

### Progress File Integration Example

```solidity
// DeployAnvil.s.sol
contract DeployAnvil is Script {
    string constant PROGRESS_FILE = "progress.31337.json";

    function run() external {
        // Load progress
        string memory progress = vm.readFile(PROGRESS_FILE);

        // Check if StableYieldAccumulator already deployed
        if (!isStepComplete(progress, "deploy_stable_yield_accumulator")) {
            // Deploy contract
            StableYieldAccumulator accumulator = new StableYieldAccumulator();

            // Update progress
            updateProgress("deploy_stable_yield_accumulator", address(accumulator));
        }

        // Continue with other steps...
    }
}
```

## Contract Deployment Order

Critical deployment sequence (dependencies must be deployed first):

### Phase 2 Deployment Order
1. **Mock/Test Contracts** (Anvil only)
   - Mock DOLA stablecoin
   - Mock ERC4626 vaults
   - Test tokens

2. **Core Phase 2 Contracts**
   - StableYieldAccumulator (yield aggregation)
   - Phlimbo (yield farm for phUSD staking)
   - phUSDStableMinter (minting logic)

3. **Initialization**
   - Grant roles and permissions
   - Configure parameters
   - Set up cross-contract references

**Note**: Exact deployment order depends on contract dependencies defined in each submodule. Review contract constructors and initialization requirements.

## API Endpoint Structure

The local server should expose deployment data at `http://localhost:3001/contracts`:

### Multi-Network Response Format
```json
{
  "networks": {
    "31337": {
      "networkId": 31337,
      "networkName": "anvil",
      "deployedAt": "2025-12-14T10:30:00Z",
      "contracts": {
        "stableYieldAccumulator": {
          "address": "0x5FbDB2315678afecb367f032d93F642f64180aa3",
          "abi": [...],
          "name": "Stable Yield Accumulator"
        },
        "phlimbo": {
          "address": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
          "abi": [...],
          "name": "Phlimbo"
        },
        "phUSDStableMinter": {
          "address": "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
          "abi": [...],
          "name": "phUSD Stable Minter"
        }
      }
    },
    "11155111": {
      "networkId": 11155111,
      "networkName": "sepolia",
      "deployedAt": "2025-12-14T11:00:00Z",
      "contracts": {
        // Sepolia contract addresses...
      }
    },
    "1": {
      "networkId": 1,
      "networkName": "mainnet",
      "deployedAt": "2025-12-14T12:00:00Z",
      "contracts": {
        // Mainnet contract addresses...
      }
    }
  },
  "activeNetwork": 31337,
  "availableNetworks": [31337, 11155111, 1]
}
```

### Query Parameters
```
GET /contracts                    # All networks
GET /contracts?network=31337      # Specific network
GET /contracts?network=sepolia    # By network name
GET /contracts/anvil              # Network-specific endpoint
```

## Wagmi Hook Generation

Use Wagmi CLI with configuration in `wagmi.config.ts`:

```typescript
import { defineConfig } from '@wagmi/cli'
import { foundry } from '@wagmi/cli/plugins'
import { readFileSync } from 'fs'

// Load deployment data for active network
const deployments = JSON.parse(
  readFileSync('./server/deployments/anvil.json', 'utf-8')
)

export default defineConfig({
  out: 'hooks/generated.ts',
  plugins: [
    foundry({
      project: '.',
      deployments: {
        StableYieldAccumulator: deployments.contracts.stableYieldAccumulator.address,
        Phlimbo: deployments.contracts.phlimbo.address,
        PhUSDStableMinter: deployments.contracts.phUSDStableMinter.address
      }
    })
  ]
})
```

### Publishing Wagmi Hooks

Generated hooks are published as `@behodler/wagmi-hooks` package:

1. **Generate hooks**: `npm run generate:hooks`
2. **Verify output**: Check `hooks/generated.ts`
3. **Update package.json**: Version bump
4. **Publish**: `npm publish --access public`
5. **Consume in UI**: `npm install @behodler/wagmi-hooks@latest`

## Environment Configuration

### CRITICAL: Files That Must NEVER Be Committed

**The following files contain sensitive credentials and must NEVER be added to source control:**

- **`.envrc`** - Contains environment variables including private keys and API tokens
- **`.npmrc`** - Contains authentication tokens for package registries

These files are listed in `.gitignore` and must remain there. If you ever see these files tracked in git, immediately run:
```bash
git rm --cached .envrc .npmrc
```

**Use example files instead**: Create `.envrc.example` and `.npmrc.example` with placeholder values for documentation purposes.

### Required Variables in `.env`

```bash
# Network Configuration
ANVIL_PORT=8545
ANVIL_CHAIN_ID=31337

# Sepolia Configuration
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY
SEPOLIA_CHAIN_ID=11155111

# Mainnet Configuration (PRODUCTION - USE WITH EXTREME CAUTION)
MAINNET_RPC_URL=https://mainnet.infura.io/v3/YOUR_INFURA_KEY
MAINNET_CHAIN_ID=1

# API Server
API_PORT=3001
API_HOST=localhost

# Deployment Keys (NEVER COMMIT REAL KEYS)
ANVIL_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
SEPOLIA_PRIVATE_KEY=  # Load from secure vault
MAINNET_PRIVATE_KEY=  # Load from hardware wallet or secure vault

# Etherscan API Keys (for verification)
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY
```

### .envrc for direnv (optional)
```bash
# Load environment variables
dotenv

# Export for Foundry
export FOUNDRY_OPTIMIZER=true
export FOUNDRY_OPTIMIZER_RUNS=200
```

### .npmrc Requirements (DO NOT COMMIT - use .npmrc.example)
```
@behodler:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=${GITHUB_TOKEN}
```

## Development Guidelines

### Test-Driven Development (TDD)

**ALL** features, bug fixes, and modifications MUST follow TDD principles:

1. **Red Phase**: Write failing tests that define expected behavior
2. **Green Phase**: Write minimal code to make tests pass
3. **Refactor Phase**: Improve code while keeping tests green

### Testing Commands

```bash
# Run all tests
forge test

# Run tests with verbose output
forge test -vvv

# Run specific contract tests
forge test --match-contract StableYieldAccumulatorTest

# Run specific test
forge test --match-test testDepositYield

# Check test coverage
forge coverage

# Generate coverage report
forge coverage --report lcov
```

### Pre-deployment Tests
Run Foundry tests before deploying to ANY network:
```bash
forge test
```

All tests must pass before deployment to Sepolia or Mainnet.

### Post-deployment Verification
Verify contracts deployed correctly:

```bash
# Check contract exists at address
cast code <address> --rpc-url $RPC_URL

# Verify contract state
cast call <address> "totalYield()" --rpc-url $RPC_URL

# Check deployment progress
cat progress.<chainId>.json
```

## Phoenix Terminology

### CRITICAL: phUSD vs pxUSD

**The token is called phUSD, NOT pxUSD**

- **phUSD** (Phoenix USD) - The correct token name for this project
- **pxUSD** - A completely different token that exists on mainnet, owned by another company
- **NEVER** use pxUSD in any Phoenix-related code, documentation, or UI
- If you encounter pxUSD in Phoenix code, it's a bug and must be replaced with phUSD

### Historical Context
- Original planning may reference "FlaxToken" - this is now phUSD
- Token symbol: "phUSD"
- Token name: "Phoenix USD"
- Contract may still use legacy names internally, but public-facing must be phUSD

## Vault-RM Naming Conventions (for dependencies)

### YieldStrategy vs Vault Distinction

When integrating with vault-RM or related contracts:

**YieldStrategy** (Our Adapter Pattern):
- Interface: `IYieldStrategy`
- Abstract base: `AYieldStrategy`
- Concrete implementation: `AutoDolaYieldStrategy`
- Purpose: OUR adapter pattern for integrating external yield sources

**Vault** (External ERC4626 Vaults):
- Variable names: `autoDolaVault`, `vault`
- Purpose: External ERC4626 contracts we integrate with
- Example: Inverse Finance's autoDola vault

**Usage Rule**:
- Referring to our adapter → use YieldStrategy
- Referring to external ERC4626 → use Vault

```solidity
// Correct usage
IYieldStrategy public yieldStrategy;
address public autoDolaVault = 0x...;
AutoDolaYieldStrategy strategy = new AutoDolaYieldStrategy(autoDolaVault);
```

## Integration with Phoenix UI

The Phoenix UI should:
1. Fetch contract data from `http://localhost:3001/contracts?network=31337`
2. Import generated Wagmi hooks: `import { useStableYieldAccumulator } from '@behodler/wagmi-hooks'`
3. Use Rainbow wallet (wagmi/viem) to interact with contracts
4. Support network switching (Anvil, Sepolia, Mainnet)

### Phoenix UI Integration Example
```typescript
// In Phoenix UI
const response = await fetch('http://localhost:3001/contracts?network=31337')
const { networks } = await response.json()
const anvilContracts = networks[31337].contracts

// Use generated hooks
import { useStableYieldAccumulatorDeposit } from '@behodler/wagmi-hooks'

const { write: deposit } = useStableYieldAccumulatorDeposit()
```

## Server Infrastructure

### Express API on Port 3001

The server should:
- Serve on `http://localhost:3001`
- Support CORS for local development
- Expose `/contracts` endpoint
- Support network-specific queries
- Serve contract ABIs and addresses
- Include deployment metadata (timestamp, deployer, etc.)

### Server Implementation Pattern
```javascript
// server/index.js
const express = require('express')
const cors = require('cors')
const fs = require('fs')

const app = express()
app.use(cors())

app.get('/contracts', (req, res) => {
  const network = req.query.network || '31337'
  const deployments = loadDeployments(network)
  res.json(deployments)
})

app.listen(3001, () => {
  console.log('Deployment server running on http://localhost:3001')
})
```

## Multi-Network Deployment Resilience

### Handling Partial Failures

Deployments can fail partway through. The progress file system enables recovery:

**Scenario 1: Network Interruption**
```bash
# Deployment fails after deploying 2 of 5 contracts
npm run deploy:sepolia
# Error: Network timeout

# Resume deployment (skips already-deployed contracts)
npm run deploy:sepolia
# Continues from contract 3
```

**Scenario 2: Gas Price Spike**
```bash
# Deployment fails due to insufficient funds
npm run deploy:mainnet
# Error: insufficient funds for gas

# Add funds, then resume
npm run deploy:mainnet
# Skips completed steps, continues deployment
```

**Scenario 3: Manual Inspection**
```bash
# Deploy first few contracts, then stop to verify
npm run deploy:sepolia
# Ctrl+C after 2 contracts

# Verify contracts on Etherscan
# Continue when satisfied
npm run deploy:sepolia
```

### Progress File Best Practices

1. **Version control**: Commit progress files to track deployment history
2. **Backup**: Keep backups before mainnet deployments
3. **Reset**: Delete progress file to force fresh deployment
4. **Audit**: Review progress file before continuing failed deployment
5. **Network isolation**: Never copy progress files between networks

## File Organization

- **script/**: Foundry deployment scripts (Solidity) - one per network
- **src/mocks/**: Mock contracts for Anvil testing
- **src/interfaces/**: Contract interfaces
- **server/**: Node.js API server and extraction utilities
- **hooks/**: Generated Wagmi hooks (auto-generated, don't edit manually)
- **lib/**: Git submodules (never commit changes here)
- **test/**: Test files (TDD required)
- **progress.*.json**: Deployment state files (version controlled)

## Common Commands

```bash
# Initialize project
forge install
git submodule update --init --recursive
npm install

# Run Anvil development workflow
npm run dev:anvil

# Deploy to Sepolia
npm run deploy:sepolia

# Deploy to Mainnet (PRODUCTION - USE WITH CAUTION)
npm run deploy:mainnet

# Rebuild contracts only
forge build

# Format Solidity code
forge fmt

# Generate gas snapshots
forge snapshot

# Extract addresses for specific network
npm run extract:anvil
npm run extract:sepolia
npm run extract:mainnet

# Restart API server
npm run serve

# Generate Wagmi hooks
npm run generate:hooks

# Run tests
forge test
forge test -vvv
```

## Development Workflow

### Anvil (Local Development)
1. **Setup**: Clone repo, initialize submodules, install dependencies
2. **Development**: Make changes to deployment scripts or contracts
3. **Testing**: Run `forge test` to verify deployment logic
4. **Deploy**: Run `npm run dev:anvil` to start Anvil and deploy
5. **Verify**: Check `http://localhost:3001/contracts?network=31337`
6. **Integrate**: Phoenix UI fetches contracts and uses generated hooks

### Sepolia (Testnet)
1. **Configure**: Set `SEPOLIA_RPC_URL` and `SEPOLIA_PRIVATE_KEY` in .env
2. **Test**: Ensure all Foundry tests pass
3. **Deploy**: Run `npm run deploy:sepolia`
4. **Verify**: Check Sepolia Etherscan for deployed contracts
5. **Extract**: Run `npm run extract:sepolia` to generate deployment JSON
6. **Test Integration**: Point Phoenix UI to Sepolia network

### Mainnet (Production)
1. **Audit**: Ensure contracts are audited and reviewed
2. **Test**: Deploy to Sepolia first, verify functionality
3. **Backup**: Backup all progress files and configurations
4. **Secure Keys**: Use hardware wallet or secure vault for private keys
5. **Deploy**: Run `npm run deploy:mainnet` (with --slow flag for safety)
6. **Verify**: Verify contracts on Etherscan
7. **Monitor**: Watch deployment progress, be ready to pause if issues
8. **Finalize**: Update progress file, commit, and announce deployment

## Troubleshooting

### Submodules Not Initializing
```bash
git submodule update --init --recursive --remote
```

### Anvil Port Already in Use
```bash
pkill anvil
lsof -i :8545
npm run start:anvil
```

### Deployment Fails Partway
```bash
# Check progress file
cat progress.<chainId>.json

# Review failed steps
# Fix issue (add gas, fix network, etc.)

# Resume deployment
npm run deploy:<network>
```

### Progress File Corruption
```bash
# Backup corrupted file
cp progress.31337.json progress.31337.json.bak

# Manually edit or delete to reset
rm progress.31337.json

# Redeploy from scratch
npm run deploy:anvil
```

### Contract Verification Fails
```bash
# Verify manually with source code
forge verify-contract <address> <contract-name> --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY

# Or use Etherscan UI verification
```

### API Server Not Responding
```bash
# Verify deployment completed
ls server/deployments/

# Check server logs
npm run serve

# Verify port not in use
lsof -i :3001

# Kill existing server
pkill -f "node server/index.js"
```

### Forge Build Errors
```bash
# Clean build cache
forge clean

# Rebuild
forge build

# Check remappings
forge remappings
```

## Security Notes

### Private Key Management

**CRITICAL SECURITY RULES**:
- **Anvil keys**: Default Anvil private key is publicly known - NEVER use on real networks
- **Sepolia keys**: Use dedicated testnet wallet, minimal ETH
- **Mainnet keys**: Use hardware wallet (Ledger, Trezor) or secure vault (AWS KMS, etc.)
- **Never commit**: Private keys must NEVER be committed to git
- **.env file**: Must be in .gitignore
- **CI/CD**: Use secret management (GitHub Secrets, etc.)

### Deployment Security Checklist

Before deploying to Mainnet:
- [ ] Contracts audited by professional security firm
- [ ] All tests passing with 100% coverage on critical paths
- [ ] Deployed to Sepolia and tested thoroughly
- [ ] Multi-sig or governance controls in place
- [ ] Emergency pause mechanisms verified
- [ ] Upgrade paths considered (proxy patterns if needed)
- [ ] Deployment script reviewed by multiple team members
- [ ] Private keys secured with hardware wallet or vault
- [ ] Gas price and limits configured appropriately
- [ ] Backup plan in place if deployment fails

### Local Development Only

This infrastructure includes features designed for **local testing only**:
- Mock contracts with unlimited minting
- Default Anvil private keys
- Unrestricted permissions
- Simplified initialization

**NEVER** deploy these configurations to Sepolia or Mainnet.

## Reference Projects

### Canonical Sibling Project
**deployment-staging-RM**: Located at `/home/justin/code/reflax-mint/deployment-staging/`

This sibling project demonstrates the same architecture patterns for Phase 1 contracts:
- Git submodule management
- Deployment orchestration
- Wagmi hook generation
- API server structure
- TDD testing approach

**Key Differences from Sibling**:
- phStaging2 deploys Phase 2 contracts (stable-yield-accumulator, phlimbo, phUSD-stable-minter)
- deployment-staging-RM deploys Phase 1 contracts (vault-RM, behodler3-tokenlaunch, flax-token)
- phStaging2 uses `progress.<chainId>.json` for multi-network resilience
- Both share similar npm scripts and server infrastructure patterns

## Important Constraints

- This repo contains **no production contract code** - only deployment orchestration
- All contract logic lives in submodule repos (stable-yield-accumulator, phlimbo, phUSD-stable-minter)
- Changes to contract code must be made in respective repos and pulled via submodule updates
- This is a **multi-network deployment tool** - supports Anvil, Sepolia, and Mainnet
- Follow Solidity best practices and naming conventions
- Use Foundry testing tools exclusively (no Hardhat or Truffle)
- Always use phUSD (NOT pxUSD) for Phoenix token references

## Repository Management

When working with this repo:
- Keep deployment scripts simple and focused
- Document any contract initialization requirements
- Update this CLAUDE.md when adding new contracts or changing architecture
- Test full deployment workflow after changes
- Maintain progress files in version control for deployment history
- Use network-specific scripts for different deployment targets
- Verify contracts on Etherscan after Sepolia/Mainnet deployments
- Follow TDD principles for all changes
