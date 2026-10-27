const fs = require('fs');
const path = require('path');
const { readInterfaceKeysFromFile } = require('./contract-addresses-interface');

/**
 * Chain ID to output file mapping
 */
const CHAIN_OUTPUT_MAP = {
    31337: 'local.json',      // Anvil/Local
    11155111: 'sepolia.json', // Sepolia (story 098: DeployMocksSepolia; same filtering as 31337)
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
 * Story 104 (Balancexit Stage 3): chains whose extraction is COMPLETED against the
 * `ContractAddresses` interface. After the normal filtering, every interface key the chain did not
 * deploy is emitted as a zero-address placeholder (`deployed: false`), the same convention the
 * hand-maintained mainnet-addresses.ts uses for undeployed keys.
 *
 * Why: generate:ts-sepolia refuses any key-set mismatch, and Sepolia does not deploy every
 * interface key (e.g. `UniswapHelper` outside its add-on). Story 104 introduced this for the
 * legacy Balancer keys, which story 107 has since removed from the interface. A zero entry in
 * the progress file cannot carry this: the loop below skips zero addresses, because the deploy scripts use them
 * as checkpoint markers ("Seeding", "UsdcSeeding", ...).
 *
 * The placeholders are added AFTER that skip, from the interface itself, so checkpoint markers
 * still never surface and only real interface keys are filled. The fill never adds a key the
 * interface lacks, so generate:ts' "Not in the interface" check is unaffected.
 *
 * Story 106: 31337 is listed too. Anvil's extraction is what DEFINES the interface (generate:ts-anvil rewrites
 * addresses.ts from local.json), so anvil cannot fill from the interface the way Sepolia does:
 * every key would become sticky and a contract dropped from DeployMocks would silently survive as
 * a zero entry forever. Anvil therefore fills ONLY the explicit ANVIL_ZERO_PLACEHOLDER_KEYS list
 * below, which is what keeps those keys in the interface through the wind-down.
 * Mainnet (1) is never listed: mainnet-addresses.ts is hand-maintained and never generated.
 */
const ZERO_PLACEHOLDER_CHAIN_IDS = [11155111, 31337];

/**
 * The ONLY keys chain 31337 emits as zero-address placeholders. Story 106 listed the legacy
 * Balancer keys here (`BalancerPooler`, `BalancerPool`, `BalancerVault`, `BalancerRouter`) to keep
 * them in `ContractAddresses` through the wind-down; story 107 (wind-down confirmed) emptied the
 * list, so anvil no longer emits them and the next generate:ts-anvil drops them from the interface.
 * `BalancerPoolerMintDebtHook` was never listed: the hook is still deployed on anvil (pointed at
 * UniPoolerV2). Add a key here only to keep a no-longer-deployed key in the interface on purpose.
 */
const ANVIL_CHAIN_ID = 31337;
const ANVIL_ZERO_PLACEHOLDER_KEYS = Object.freeze([]);

/**
 * The keys `chainId` completes its extraction against: anvil's fixed list, otherwise the
 * interface keys the caller supplied (Sepolia).
 */
function placeholderKeysFor(chainId, interfaceKeys) {
    if (chainId === ANVIL_CHAIN_ID) return ANVIL_ZERO_PLACEHOLDER_KEYS;
    if (!Array.isArray(interfaceKeys) || interfaceKeys.length === 0) {
        throw new Error(`chainId ${chainId} emits zero placeholders but no ContractAddresses keys were supplied`);
    }
    return interfaceKeys;
}

/**
 * NFT contract base names (V2 only). Contracts with a "V2" suffix matching these names
 * are written to flat `contracts` under the stripped base name. Bare-name (V1) contracts
 * and NFTMigrator are dropped entirely.
 *
 * Story 102 (Balancexit Stage 1c): "UniPooler" is added so the tracked "UniPoolerV2"
 * (DeployMocks' cutover rehearsal) surfaces as the key `UniPooler`, the live index-4
 * dispatcher. Story 107: "BalancerPooler" removed — the wind-down is confirmed and the key is
 * gone from ContractAddresses; nothing deploys a BalancerPoolerV2 any more.
 */
const NFT_BASE_NAMES = ["NFTMinter", "BurnerEYE", "BurnerSCX", "BurnerFlax", "UniPooler", "GatherWBTC"];

/**
 * Contracts to drop from extraction entirely (V1 NFTs are handled via NFT_BASE_NAMES;
 * NFTMigrator is explicitly dropped here as a belt-and-suspenders guard).
 *
 * BuggedPoolerV2Index6 is a deploy-only placeholder: a disabled pooler (an unwired
 * UniPoolerV2 since story 106; the retired Balancer pooler before it) registered at dispatcher index 6 purely to mirror mainnet's index layout (so the
 * local NudgeRatchet lands at index 7). It is never enabled and never minted, so it
 * must not be surfaced as a consumable address in the ContractAddresses interface.
 */
/*
 * Story 078: the three page views are dropped for a different reason from the two above —
 * not because they are local-only or bugged, but because they are RESOLVED THROUGH
 * `ViewRouter`. `ViewRouter.pages(keccak256("<page>"))` publishes each page's address
 * on-chain, so a second, hand-maintained address key is a competing resolution path. That
 * duplication is exactly how the mainnet deposit page went unnoticed for months resolving to
 * a PhlimboEA (V1) view while the keyed `DepositView` named the V2-correct one. `ViewRouter`
 * stays; every page behind it goes.
 *
 * `MintPageView` is still deployed locally and nothing about the anvil environment changes —
 * dropping it here only stops it being PUBLISHED into the generated `ContractAddresses`
 * interface. Without this entry, the hand-deletions in `addresses.ts` / `local-addresses.ts` are
 * undone by the very next local deploy.
 *
 * `DepositView` and `DepositPageView` are no longer deployed at all: both are typed against the
 * V1/V2-shaped `IPhlimbo` and went with PhlimboV2 when the local chain flattened onto PhlimboV3.
 * Their entries are kept as a guard, so a future contract reviving either name cannot slip back
 * into the interface unnoticed.
 *
 * `DepositPageViewV3`, the replacement page, is deliberately never tracked by
 * `DeployMocks.s.sol` as a UI-consumable address either — it is keyless by design.
 */
const DROPPED_CONTRACT_NAMES = [
    "NFTMigrator",
    "BuggedPoolerV2Index6",
    "DepositView",
    "DepositPageView",
    "MintPageView",
];

/**
 * Raw Uniswap V2 stack that backs the Uniboost dispatchers (WETH9, the canonical
 * factory, the Uniboost target pools, and the routing pools). These are deployed
 * locally only so Uniboost has an AMM to swap against; the UI never interacts with them
 * directly (all routing is wired on-chain inside the Uniboost dispatchers/hooks). They are
 * therefore not part of the UI-facing ContractAddresses surface and are dropped from
 * extraction so they stop appearing in the generated interface (and in the hand-maintained
 * mainnet file, whose key-set must mirror that interface).
 *
 * Story 102 (Balancexit Stage 1c): the router is NO LONGER dropped. The UI's "buy phUSD"
 * and price widgets will read the phUSD/sUSDS V2 pair through Router02 (phlimbo-ui step U1),
 * so it is surfaced as `UniswapV2Router` (see RENAMED_CONTRACT_NAMES). The pair itself is tracked as
 * "PhusdSusdsPair" and surfaces under that name. Matching here is exact, so these names
 * never swallow "UniPoolerV2" or "PhusdSusdsPair".
 */
const UNISWAP_V2_BACKING_NAMES = [
    "WETH9",
    "UniswapV2Factory",
    "UniPoolEYE",
    "UniPoolSCX",
    "UniPoolFLX",
    "UniRoutePoolWETH",
    "UniRoutePoolUSDS",
    "UniRoutePoolDOLA",
];

/**
 * Story 110: the local venue mocks UniswapHelper calls on anvil (Uniswap V3 SwapRouter +
 * QuoterV2, Curve DOLA-3CRV metapool, Curve USDe/USDC stableswap-ng). DeployMocks tracks them
 * (as "Mock..." names, so they appear in progress.31337.json) but the UI never calls them: every
 * swap and liquidity route goes through the `UniswapHelper` key, which takes these addresses as
 * immutables. Surfacing them would also force mainnet/Sepolia placeholders for addresses nothing
 * reads. Matched on the display name, i.e. after the "Mock" prefix is stripped.
 * `UniswapHelper` itself is NOT listed: it surfaces under its own tracked name.
 */
const UNISWAP_HELPER_VENUE_NAMES = [
    "UniswapV3SwapRouter",
    "UniswapV3QuoterV2",
    "CurveDolaMetaPool",
    "CurveStableSwapNG",
];

/**
 * Story 115: the anvil infrastructure SYAHarvester executes against (Curve Router NG mock, the
 * mock crvUSD and the two Curve pools of the USDe -> crvUSD -> USDC route, the Uniswap V4
 * PoolManager and the V4 liquidity router that seeded its ETH/USDC pool). DeployMocks tracks
 * them so they appear in progress.31337.json, but the UI never calls them: harvesting goes
 * through the SYAHarvester contract (story 116), which takes the router and PoolManager as
 * immutables. Surfacing them would also force mainnet/Sepolia placeholders for addresses
 * nothing reads (on mainnet these are Curve's and Uniswap's own contracts). Matched on the
 * display name, i.e. after the "Mock" prefix is stripped.
 */
const SYA_HARVESTER_INFRA_NAMES = [
    "CrvUSD",
    "CurveRouterNG",
    "CurveUsdeCrvusdPool",
    "CurveCrvusdUsdcPool",
    "UniswapV4PoolManager",
    "UniswapV4LiquidityRouter",
];

/**
 * Tracked deployment name -> ContractAddresses key, for names whose key differs from the
 * tracked name. Story 102: DeployMocks tracks the canonical router as "UniswapV2Router02";
 * the address book key is `UniswapV2Router`.
 */
const RENAMED_CONTRACT_NAMES = {
    UniswapV2Router02: "UniswapV2Router",
};

/**
 * Pure extraction: progress data -> the deployment JSON object. No file I/O.
 * @param {object} progressData - parsed progress.<chainId>.json
 * @param {number} chainId
 * @param {object} [opts]
 * @param {string[]} [opts.interfaceKeys] - ContractAddresses keys; required when `chainId` is in
 *        ZERO_PLACEHOLDER_CHAIN_IDS (the extraction is completed against them), except on 31337,
 *        which always uses ANVIL_ZERO_PLACEHOLDER_KEYS
 * @param {boolean} [opts.quiet] - suppress per-entry logging
 * @returns {{extracted: object, filteredCount: number, placeholders: string[]}}
 */
function buildExtraction(progressData, chainId, opts = {}) {
    const log = opts.quiet ? () => {} : console.log;

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
            log(`  Skipping checkpoint entry: ${name} (zero address)`);
            filteredCount++;
            continue;
        }

        // Strip "Mock" prefix for UI compatibility (e.g., MockPhUSD -> PhUSD, MockUSDS -> USDS),
        // then apply any explicit tracked-name -> key rename (e.g. UniswapV2Router02 -> UniswapV2Router)
        const strippedName = name.startsWith('Mock') ? name.slice(4) : name;
        const displayName = RENAMED_CONTRACT_NAMES[strippedName] || strippedName;

        // Drop explicitly excluded contracts (NFTMigrator and bare V1 NFT names)
        if (DROPPED_CONTRACT_NAMES.includes(displayName)) {
            log(`  Dropping excluded contract: ${displayName}`);
            continue;
        }

        // Drop the raw UniV2 stack that backs Uniboost — not UI-consumable (see constant above)
        if (UNISWAP_V2_BACKING_NAMES.includes(displayName)) {
            log(`  Dropping UniV2 backing contract: ${displayName}`);
            continue;
        }

        // Drop UniswapHelper's local venue mocks — reached only through the helper (see constant above)
        if (UNISWAP_HELPER_VENUE_NAMES.includes(displayName)) {
            log(`  Dropping UniswapHelper venue mock: ${displayName}`);
            continue;
        }

        // Drop SYAHarvester's local infrastructure — reached only through the harvester (see constant above)
        if (SYA_HARVESTER_INFRA_NAMES.includes(displayName)) {
            log(`  Dropping SYAHarvester infrastructure: ${displayName}`);
            continue;
        }

        // Drop bare-name V1 NFT contracts (e.g. "NFTMinter" without V2 suffix)
        if (NFT_BASE_NAMES.includes(displayName)) {
            log(`  Dropping V1 NFT contract: ${displayName}`);
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

    // Story 104: complete the extraction against the interface (see ZERO_PLACEHOLDER_CHAIN_IDS).
    const placeholders = [];
    if (ZERO_PLACEHOLDER_CHAIN_IDS.includes(chainId)) {
        for (const key of placeholderKeysFor(chainId, opts.interfaceKeys)) {
            if (Object.prototype.hasOwnProperty.call(extracted.contracts, key)) continue;
            extracted.contracts[key] = {
                address: ZERO_ADDRESS,
                deployed: false,
                configured: false,
                deployGas: 0,
                configGas: 0
            };
            placeholders.push(key);
            log(`  Zero-address placeholder: ${key} (interface key not deployed on chain ${chainId})`);
        }
    }

    return { extracted, filteredCount, placeholders };
}

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

    const interfaceKeys = ZERO_PLACEHOLDER_CHAIN_IDS.includes(chainId) && chainId !== ANVIL_CHAIN_ID
        ? readInterfaceKeysFromFile()
        : undefined;
    const { extracted, filteredCount, placeholders } = buildExtraction(progressData, chainId, { interfaceKeys });

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
    if (placeholders.length > 0) {
        console.log(`Placeholders: ${placeholders.length} zero-address interface keys (${placeholders.join(', ')})`);
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
            console.error('  11155111  - Sepolia');
            console.error('  1         - Mainnet');
            process.exit(1);
        }
        chainId = parsed;
    }

    return chainId;
}

module.exports = {
    ZERO_ADDRESS,
    ZERO_PLACEHOLDER_CHAIN_IDS,
    ANVIL_ZERO_PLACEHOLDER_KEYS,
    NFT_BASE_NAMES,
    RENAMED_CONTRACT_NAMES,
    buildExtraction,
};

// Run extraction (CLI only; requiring this module for its exports runs nothing)
if (require.main === module) {
    try {
        const chainId = parseArgs();
        extractAddresses(chainId);
    } catch (error) {
        console.error('Error extracting addresses:', error.message);
        process.exit(1);
    }
}
