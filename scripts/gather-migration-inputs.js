#!/usr/bin/env node
/**
 * gather-migration-inputs.js  (story 060)
 *
 * Off-chain snapshot of all StableStaker stakers for a given token set (DOLA + USDC),
 * chunked into arrays suitable for direct vm.parseJsonAddressArray consumption in
 * SkimAndLeg1Migration.s.sol and Leg2Migration.s.sol.
 *
 * For leg 1: reads from ORIGINAL_STABLE_STAKER (hardcoded constant).
 * For leg 2: reads tempStaker address from script/migration-inputs/ys-swap-deployments.json.
 *
 * CLI:
 *   RPC_MAINNET=https://... node scripts/gather-migration-inputs.js --leg <1|2> [--chunk-size 50]
 *
 * Output:
 *   script/migration-inputs/leg<N>-stakers.json
 *
 * Output shape:
 *   {
 *     "stakerSource": "<address>",
 *     "leg": 1,
 *     "blockNumber": N,
 *     "timestamp": "ISO",
 *     "chunkSize": 50,
 *     "tokens": {
 *       "DOLA": { "count": n, "totalStaked": "...", "chunkCount": m, "chunks": [[addr,...], ...] },
 *       "USDC": { "count": n, "totalStaked": "...", "chunkCount": m, "chunks": [[addr,...], ...] }
 *     }
 *   }
 *
 * Exit codes:
 *   0 - Success
 *   1 - Missing RPC_MAINNET env var
 *   2 - Could not resolve staker address
 *   3 - RPC / network error
 *   4 - Deployments JSON missing or unparseable (leg 2 only)
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const DEPLOYMENTS_FILE = path.join(ROOT, 'script', 'migration-inputs', 'ys-swap-deployments.json');
const OUTPUT_DIR = path.join(ROOT, 'script', 'migration-inputs');

// ==========================================
//   CONSTANTS
// ==========================================

const ORIGINAL_STABLE_STAKER = '0xbce8ABC09BaEDCabE93419bF875f6186e182079A';

const DOLA = '0x865377367054516e17014CcdED1e7d814EDC9ce4';
const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';

const TOKENS = [
    { symbol: 'DOLA', address: DOLA },
    { symbol: 'USDC', address: USDC },
];

const STABLE_STAKER_ABI = [
    {
        type: 'function',
        name: 'stakerCount',
        inputs: [{ name: 'token', type: 'address' }],
        outputs: [{ type: 'uint256' }],
        stateMutability: 'view',
    },
    {
        type: 'function',
        name: 'getStakersRange',
        inputs: [
            { name: 'token', type: 'address' },
            { name: 'start', type: 'uint256' },
            { name: 'end', type: 'uint256' },
        ],
        outputs: [{ type: 'address[]' }],
        stateMutability: 'view',
    },
    {
        type: 'function',
        name: 'poolInfo',
        inputs: [{ name: 'token', type: 'address' }],
        outputs: [
            { name: 'phusdPerSecond', type: 'uint256' },
            { name: 'accPhusdPerShare', type: 'uint256' },
            { name: 'lastRewardTime', type: 'uint256' },
            { name: 'totalStaked', type: 'uint256' },
        ],
        stateMutability: 'view',
    },
];

// ==========================================
//   HELPERS
// ==========================================

function die(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function parseArgs() {
    const args = process.argv.slice(2);
    let leg = null;
    let chunkSize = 50;

    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--leg' && args[i + 1]) {
            leg = parseInt(args[i + 1], 10);
            i++;
        } else if (args[i] === '--chunk-size' && args[i + 1]) {
            chunkSize = parseInt(args[i + 1], 10);
            i++;
        }
    }

    if (leg !== 1 && leg !== 2) {
        console.error('Usage: node scripts/gather-migration-inputs.js --leg <1|2> [--chunk-size 50]');
        process.exit(1);
    }
    if (chunkSize < 1 || chunkSize > 500) {
        die(1, `--chunk-size must be between 1 and 500; got ${chunkSize}`);
    }

    return { leg, chunkSize };
}

function loadViem() {
    try {
        return require('viem');
    } catch (err) {
        die(3, 'viem not installed. Run `npm install` in the project root first.');
    }
}

// Multicall3 canonical address.
const MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11';

function chainConfig(viem, chainId) {
    let base;
    try {
        const chains = require('viem/chains');
        if (chainId === 1) base = chains.mainnet;
    } catch (_) {
        // viem/chains not loadable; use stub.
    }
    if (!base) {
        base = {
            id: chainId,
            name: chainId === 1 ? 'mainnet' : `chain-${chainId}`,
            nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
            rpcUrls: {},
        };
    }
    if (!base.contracts || !base.contracts.multicall3) {
        base = {
            ...base,
            contracts: {
                ...(base.contracts || {}),
                multicall3: { address: MULTICALL3_ADDRESS },
            },
        };
    }
    return base;
}

function resolveStakerAddress(leg) {
    if (leg === 1) {
        console.log(`Leg 1 — reading from ORIGINAL_STABLE_STAKER: ${ORIGINAL_STABLE_STAKER}`);
        return ORIGINAL_STABLE_STAKER;
    }

    // Leg 2: read tempStaker from deployments JSON.
    if (!fs.existsSync(DEPLOYMENTS_FILE)) {
        die(4, `Deployments JSON not found: ${DEPLOYMENTS_FILE}\nRun DeployTempStableStakerAndMigrators first.`);
    }
    let deployments;
    try {
        deployments = JSON.parse(fs.readFileSync(DEPLOYMENTS_FILE, 'utf8'));
    } catch (err) {
        die(4, `Deployments JSON unparseable: ${err.message}`);
    }
    const tempStaker = deployments.tempStaker;
    if (!tempStaker || !/^0x[0-9a-fA-F]{40}$/.test(tempStaker)) {
        die(4, `deployments.tempStaker missing or invalid in ${DEPLOYMENTS_FILE}`);
    }
    console.log(`Leg 2 — reading from tempStaker: ${tempStaker}`);
    return tempStaker;
}

async function multicallBatched(publicClient, calls, batchSize = 200) {
    const out = [];
    for (let i = 0; i < calls.length; i += batchSize) {
        const slice = calls.slice(i, i + batchSize);
        process.stdout.write(`  multicall batch ${i}..${i + slice.length - 1} ... `);
        const res = await publicClient.multicall({ contracts: slice, allowFailure: false });
        console.log('OK');
        out.push(...res);
    }
    return out;
}

function chunkArray(arr, size) {
    const out = [];
    for (let i = 0; i < arr.length; i += size) {
        out.push(arr.slice(i, i + size));
    }
    return out;
}

// ==========================================
//   MAIN
// ==========================================

async function main() {
    const { leg, chunkSize } = parseArgs();

    const RPC = process.env.RPC_MAINNET;
    if (!RPC) die(1, 'RPC_MAINNET env var is required');

    const viem = loadViem();
    const stakerAddress = resolveStakerAddress(leg);

    const transport = viem.http(RPC, { batch: true, retryCount: 3, retryDelay: 500 });
    const probeClient = viem.createPublicClient({ transport });
    const chainId = await probeClient.getChainId();
    console.log(`Chain ID: ${chainId}`);

    const publicClient = viem.createPublicClient({
        chain: chainConfig(viem, chainId),
        transport,
    });

    const blockNumber = Number(await publicClient.getBlockNumber());
    console.log(`Block number: ${blockNumber}`);
    console.log(`Chunk size:   ${chunkSize}`);
    console.log('');

    const tokenResults = {};

    for (const token of TOKENS) {
        console.log(`=== Processing ${token.symbol} (${token.address}) ===`);

        // Read stakerCount.
        const count = await publicClient.readContract({
            address: stakerAddress,
            abi: STABLE_STAKER_ABI,
            functionName: 'stakerCount',
            args: [token.address],
        });
        const countNum = Number(count);
        console.log(`  stakerCount: ${countNum}`);

        // Read poolInfo for totalStaked.
        const poolInfo = await publicClient.readContract({
            address: stakerAddress,
            abi: STABLE_STAKER_ABI,
            functionName: 'poolInfo',
            args: [token.address],
        });
        const totalStaked = (Array.isArray(poolInfo) ? poolInfo[3] : poolInfo.totalStaked).toString();
        console.log(`  totalStaked: ${totalStaked}`);

        // Page through getStakersRange in blocks of 200.
        const PAGE_SIZE = 200;
        const allStakers = [];
        let start = 0;

        // YS-04 fix (story-065): getStakersRange(start, end) is HALF-OPEN — it returns indices
        // [start, end) (StableStaker.sol:666 `for (i = start; i < end; i++)`, length `end - start`).
        // The previous `end = min(start+PAGE, count) - 1` + `start = end + 1` treated it as inclusive
        // and dropped the last staker of the final page (e.g. count=50 fetched only indices 0..48).
        // Correct half-open paging: end = min(start+PAGE, count) (exclusive), advance start = end.
        while (start < countNum) {
            const end = Math.min(start + PAGE_SIZE, countNum);
            process.stdout.write(`  getStakersRange(${start}, ${end}) [half-open) ... `);
            const page = await publicClient.readContract({
                address: stakerAddress,
                abi: STABLE_STAKER_ABI,
                functionName: 'getStakersRange',
                args: [token.address, BigInt(start), BigInt(end)],
            });
            const addrs = Array.isArray(page) ? page : [page];
            console.log(`${addrs.length} addresses`);
            allStakers.push(...addrs);
            start = end;
        }

        if (allStakers.length !== countNum) {
            console.log(
                `WARNING: fetched ${allStakers.length} stakers but stakerCount returned ${countNum}. ` +
                `This can happen if stakers joined between reads. Re-run to get a fresh snapshot.`
            );
        }

        // Chunk the staker list.
        const chunks = chunkArray(allStakers, chunkSize);
        console.log(`  Chunked into ${chunks.length} chunk(s) of up to ${chunkSize}`);
        console.log('');

        tokenResults[token.symbol] = {
            count: allStakers.length,
            totalStaked,
            chunkCount: chunks.length,
            chunks,
        };
    }

    // Write output.
    if (!fs.existsSync(OUTPUT_DIR)) {
        fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    }

    const output = {
        stakerSource: stakerAddress,
        leg,
        blockNumber,
        timestamp: new Date().toISOString(),
        chunkSize,
        tokens: tokenResults,
    };

    const outFile = path.join(OUTPUT_DIR, `leg${leg}-stakers.json`);
    fs.writeFileSync(outFile, JSON.stringify(output, null, 2) + '\n', 'utf8');

    console.log('=== Summary ===');
    for (const token of TOKENS) {
        const t = tokenResults[token.symbol];
        console.log(`  ${token.symbol}: ${t.count} stakers, ${t.chunkCount} chunk(s), totalStaked=${t.totalStaked}`);
    }
    console.log(`  blockNumber: ${blockNumber}`);
    console.log(`  wrote: ${outFile}`);
}

main().catch((err) => {
    console.error('UNCAUGHT:', err?.stack || err);
    process.exit(3);
});
