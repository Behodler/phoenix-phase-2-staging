#!/usr/bin/env node
/**
 * snapshot-phlimbo-v1-stakers.js  (story 049)
 *
 * Off-chain snapshot of all PhlimboEA (V1) stakers with non-zero current
 * balances, plus their pending USDC + phUSD rewards. Output is a JSON file
 * that the Foundry migration script (`script/MigratePhlimboV1ToV2.s.sol`)
 * consumes via `vm.readFile` + `vm.parseJson`.
 *
 * Strategy (per story 049 § Snapshot script logic):
 *
 *   1. Resolve V1 PhlimboEA address from `server/deployments/mainnet-addresses.ts`.
 *   2. queryFilter `Staked(address indexed user, uint256 amount)` from a known
 *      deployment-floor block to `latest` (chunked to keep eth_getLogs RPC
 *      requests under common provider limits).
 *   3. Dedupe `user` addresses (order preserved -- first appearance order is
 *      also iteration order in the Foundry script's seedObligations() loop).
 *   4. Multicall `userInfo(addr)` -> keep where `amount > 0`.
 *   5. Multicall `pendingPhUSD(addr)` + `pendingStable(addr)` for survivors.
 *   6. Write JSON with the shape MigratePhlimboV1ToV2.s.sol expects:
 *        {
 *          chainId, networkName, phlimboV1, blockNumber, timestamp,
 *          users[],  deposits[],  usdcOwed[],  phUSDOwed[],
 *          totalUSDC, totalPHUSDDeposited, totalPHUSDPending,
 *          userCount, source: { ... }
 *        }
 *
 * IMPORTANT timing rule (story Implementation Notes):
 *   The snapshot MUST be taken AFTER `pause()` + `emergencyTransfer()` have
 *   been mined. Otherwise stake/withdraw/claim activity between snapshot and
 *   migration can drift the pending-rewards numbers (which the migrator
 *   strictly == validates). This script does NOT pause anything itself --
 *   it's a read-only snapshot. The Foundry migration script consumes the
 *   JSON `blockNumber` field and `require`s it is >= the V1 pause block.
 *
 * Output location:
 *   scripts/snapshots/phlimbo-v1-snapshot-<block>.json
 *
 * Usage:
 *   RPC_MAINNET=https://eth-mainnet.g.alchemy.com/v2/KEY \
 *     node scripts/snapshot-phlimbo-v1-stakers.js
 *
 * Optional env:
 *   RPC_MAINNET            RPC URL (required)
 *   PHLIMBO_V1_ADDRESS     Override the V1 address (default: parsed from
 *                          server/deployments/mainnet-addresses.ts)
 *   FROM_BLOCK             Lower bound for Staked event scan (default: 0,
 *                          which uses CHAIN-tuned floor; mainnet floor is the
 *                          deployment block of V1, fallback 'earliest')
 *   TO_BLOCK               Upper bound (default 'latest')
 *   CHUNK_SIZE             eth_getLogs chunk size in blocks (default 50_000)
 *   OUTPUT_DIR             Output dir (default scripts/snapshots)
 *
 * Exit codes:
 *   0  - Success
 *   1  - Missing RPC_MAINNET
 *   2  - Could not resolve V1 address
 *   3  - RPC / network error
 *   4  - Empty staker set (nothing to migrate)
 *   5  - Output write failure
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const DEFAULT_OUTPUT_DIR = path.join(__dirname, 'snapshots');

function die(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function resolveV1Address() {
    if (process.env.PHLIMBO_V1_ADDRESS) return process.env.PHLIMBO_V1_ADDRESS;
    if (!fs.existsSync(ADDRESSES_FILE)) die(2, `mainnet-addresses.ts not found at ${ADDRESSES_FILE}`);
    const src = fs.readFileSync(ADDRESSES_FILE, 'utf8');
    const m = src.match(/PhlimboEA:\s*"(0x[0-9a-fA-F]{40})"/);
    if (!m) die(2, 'PhlimboEA address not found in mainnet-addresses.ts');
    return m[1];
}

// viem is declared as a transitive dep of @wagmi/cli (see package-lock.json).
// We import lazily so the script gives a clearer error if `npm install` was
// skipped.
function loadViem() {
    try {
        return require('viem');
    } catch (err) {
        die(3, 'viem not installed. Run `npm install` in the project root first.');
    }
}

const PHLIMBO_V1_ABI = [
    {
        type: 'event',
        name: 'Staked',
        inputs: [
            { name: 'user', type: 'address', indexed: true },
            { name: 'amount', type: 'uint256', indexed: false },
        ],
    },
    {
        type: 'function',
        name: 'userInfo',
        stateMutability: 'view',
        inputs: [{ name: 'user', type: 'address' }],
        outputs: [
            { name: 'amount', type: 'uint256' },
            { name: 'phUSDDebt', type: 'uint256' },
            { name: 'stableDebt', type: 'uint256' },
        ],
    },
    {
        type: 'function',
        name: 'pendingPhUSD',
        stateMutability: 'view',
        inputs: [{ name: 'user', type: 'address' }],
        outputs: [{ type: 'uint256' }],
    },
    {
        type: 'function',
        name: 'pendingStable',
        stateMutability: 'view',
        inputs: [{ name: 'user', type: 'address' }],
        outputs: [{ type: 'uint256' }],
    },
    {
        type: 'function',
        name: 'depletionDuration',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'uint256' }],
    },
    {
        type: 'function',
        name: 'paused',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'bool' }],
    },
    {
        type: 'function',
        name: 'owner',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'address' }],
    },
    {
        type: 'function',
        name: 'pauser',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'address' }],
    },
    {
        type: 'function',
        name: 'totalStaked',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'uint256' }],
    },
];

async function chunkedQueryFilter(publicClient, address, eventAbi, fromBlock, toBlock, chunkSize) {
    let from = fromBlock;
    const out = [];
    while (from <= toBlock) {
        const to = from + BigInt(chunkSize) - 1n > toBlock ? toBlock : from + BigInt(chunkSize) - 1n;
        process.stdout.write(`  scanning logs [${from} .. ${to}] ... `);
        try {
            const logs = await publicClient.getLogs({
                address,
                event: eventAbi,
                fromBlock: from,
                toBlock: to,
            });
            console.log(`${logs.length} log(s)`);
            out.push(...logs);
        } catch (err) {
            console.log('FAILED');
            // Halve chunk on failure and retry once.
            const halfSize = Math.max(1000, Math.floor(chunkSize / 2));
            if (halfSize === chunkSize) {
                die(3, `eth_getLogs failed irrecoverably at chunk ${from}..${to}: ${err.message}`);
            }
            console.log(`  -> halving chunk to ${halfSize} and retrying ...`);
            const retry = await chunkedQueryFilter(publicClient, address, eventAbi, from, to, halfSize);
            out.push(...retry);
        }
        from = to + 1n;
    }
    return out;
}

async function multicallBatched(publicClient, calls, batchSize = 200) {
    const out = [];
    for (let i = 0; i < calls.length; i += batchSize) {
        const slice = calls.slice(i, i + batchSize);
        process.stdout.write(`  multicall batch ${i}..${i + slice.length} ... `);
        const res = await publicClient.multicall({ contracts: slice, allowFailure: false });
        console.log('OK');
        out.push(...res);
    }
    return out;
}

// Multicall3 canonical address (same on every EVM chain that has it
// deployed: see https://github.com/mds1/multicall). We attach it to the
// chain config so viem's multicall path doesn't error with
// ChainDoesNotSupportContract.
const MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11';

function chainConfig(viem, chainId) {
    // Prefer the official viem chain definition when available -- it carries
    // multicall3 address and block details out of the box. Falls back to a
    // minimal stub on unknown chains.
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
    // Ensure multicall3 is set (some custom chains forget it).
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

async function main() {
    const RPC = process.env.RPC_MAINNET;
    if (!RPC) die(1, 'RPC_MAINNET env var is required');

    const viem = loadViem();
    const v1 = resolveV1Address();
    console.log(`PhlimboEA V1 address: ${v1}`);

    const transport = viem.http(RPC, { batch: true, retryCount: 3, retryDelay: 500 });
    // chainId is fetched dynamically so the script also works on forks (chainId=1 typically).
    const probeClient = viem.createPublicClient({ transport });
    const chainId = await probeClient.getChainId();
    console.log(`Chain ID: ${chainId}`);

    const publicClient = viem.createPublicClient({
        chain: chainConfig(viem, chainId),
        transport,
    });

    // ===== Pre-flight reads =====
    console.log('Pre-flight reads:');
    const [ownerAddr, pauserAddr, paused, depletionDuration, totalStaked] = await Promise.all([
        publicClient.readContract({ address: v1, abi: PHLIMBO_V1_ABI, functionName: 'owner' }),
        publicClient.readContract({ address: v1, abi: PHLIMBO_V1_ABI, functionName: 'pauser' }),
        publicClient.readContract({ address: v1, abi: PHLIMBO_V1_ABI, functionName: 'paused' }),
        publicClient.readContract({ address: v1, abi: PHLIMBO_V1_ABI, functionName: 'depletionDuration' }),
        publicClient.readContract({ address: v1, abi: PHLIMBO_V1_ABI, functionName: 'totalStaked' }),
    ]);
    console.log(`  owner:             ${ownerAddr}`);
    console.log(`  pauser:            ${pauserAddr}`);
    console.log(`  paused:            ${paused}`);
    console.log(`  depletionDuration: ${depletionDuration} (${Number(depletionDuration) / 86400} days)`);
    console.log(`  totalStaked:       ${totalStaked}`);

    if (!paused) {
        console.log('WARNING: V1 is NOT paused. Snapshot taken now may drift if any user');
        console.log('         interacts with V1 before the migration broadcast. Per story 049,');
        console.log('         the snapshot should be taken AFTER pause + emergencyTransfer.');
    }

    // ===== Event scan =====
    const tip = await publicClient.getBlockNumber();
    const fromEnv = process.env.FROM_BLOCK ? BigInt(process.env.FROM_BLOCK) : 0n;
    const toEnv = process.env.TO_BLOCK ? BigInt(process.env.TO_BLOCK) : tip;
    const chunkSize = process.env.CHUNK_SIZE ? Number(process.env.CHUNK_SIZE) : 50_000;

    console.log(`Scanning Staked events from block ${fromEnv} to ${toEnv} (chunk=${chunkSize})`);
    const stakedEvent = PHLIMBO_V1_ABI.find((x) => x.type === 'event' && x.name === 'Staked');
    const logs = await chunkedQueryFilter(publicClient, v1, stakedEvent, fromEnv, toEnv, chunkSize);
    console.log(`Found ${logs.length} Staked event(s)`);

    // ===== Dedup users (preserve first-seen order) =====
    const seen = new Set();
    const candidates = [];
    for (const log of logs) {
        const user = (log.args?.user || '').toLowerCase();
        if (!user || seen.has(user)) continue;
        seen.add(user);
        candidates.push(user);
    }
    console.log(`Unique candidate stakers: ${candidates.length}`);

    if (candidates.length === 0) {
        die(4, 'No Staked events found -- nothing to snapshot.');
    }

    // ===== Filter by userInfo.amount > 0 =====
    console.log('Reading userInfo for each candidate ...');
    const userInfoCalls = candidates.map((u) => ({
        address: v1,
        abi: PHLIMBO_V1_ABI,
        functionName: 'userInfo',
        args: [u],
    }));
    const userInfos = await multicallBatched(publicClient, userInfoCalls, 200);

    const survivors = [];
    for (let i = 0; i < candidates.length; i++) {
        const info = userInfos[i];
        // viem returns tuples as arrays for unnamed outputs but here outputs are named.
        // userInfo returns (amount, phUSDDebt, stableDebt).
        const amount = Array.isArray(info) ? info[0] : info.amount;
        if (amount && amount > 0n) {
            survivors.push({ user: candidates[i], deposit: amount });
        }
    }
    console.log(`Survivors with non-zero current stake: ${survivors.length}`);

    if (survivors.length === 0) {
        die(4, 'No stakers with non-zero current stake -- nothing to migrate.');
    }

    // Sum check vs on-chain totalStaked.
    const sumDeposits = survivors.reduce((acc, x) => acc + x.deposit, 0n);
    console.log(`Sum of survivor deposits: ${sumDeposits}`);
    console.log(`On-chain totalStaked:     ${totalStaked}`);
    if (sumDeposits !== totalStaked) {
        console.log('WARNING: sum(deposits) != totalStaked');
        console.log('  This can happen if events were missed (FROM_BLOCK too high) or if');
        console.log('  pauseWithdraw was called between snapshot reads (no-op when contract');
        console.log('  is drained, but worth flagging). Cross-check before broadcasting.');
    }

    // ===== Pending rewards =====
    console.log('Reading pendingPhUSD + pendingStable for each survivor ...');
    const pendingCalls = [];
    for (const s of survivors) {
        pendingCalls.push({
            address: v1,
            abi: PHLIMBO_V1_ABI,
            functionName: 'pendingStable',
            args: [s.user],
        });
        pendingCalls.push({
            address: v1,
            abi: PHLIMBO_V1_ABI,
            functionName: 'pendingPhUSD',
            args: [s.user],
        });
    }
    const pendings = await multicallBatched(publicClient, pendingCalls, 200);

    let totalUSDC = 0n;
    let totalPhUSDPending = 0n;
    let totalPhUSDDeposited = 0n;
    for (let i = 0; i < survivors.length; i++) {
        const usdc = pendings[i * 2];
        const phusd = pendings[i * 2 + 1];
        survivors[i].usdcOwed = usdc;
        survivors[i].phUSDOwed = phusd;
        totalUSDC += usdc;
        totalPhUSDPending += phusd;
        totalPhUSDDeposited += survivors[i].deposit;
    }

    // ===== Output JSON =====
    const outputDir = process.env.OUTPUT_DIR || DEFAULT_OUTPUT_DIR;
    if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

    const out = {
        chainId,
        networkName: chainId === 1 ? 'mainnet' : `chain-${chainId}`,
        phlimboV1: v1,
        blockNumber: Number(toEnv),
        timestamp: new Date().toISOString(),
        users: survivors.map((s) => viem.getAddress(s.user)),
        deposits: survivors.map((s) => s.deposit.toString()),
        usdcOwed: survivors.map((s) => s.usdcOwed.toString()),
        phUSDOwed: survivors.map((s) => s.phUSDOwed.toString()),
        totalUSDC: totalUSDC.toString(),
        totalPHUSDDeposited: totalPhUSDDeposited.toString(),
        totalPHUSDPending: totalPhUSDPending.toString(),
        userCount: survivors.length,
        source: {
            owner: ownerAddr,
            pauser: pauserAddr,
            paused,
            depletionDuration: depletionDuration.toString(),
            totalStaked: totalStaked.toString(),
            sumDeposits: sumDeposits.toString(),
            fromBlock: Number(fromEnv),
            toBlock: Number(toEnv),
            chunkSize,
        },
    };

    const outFile = path.join(outputDir, `phlimbo-v1-snapshot-${out.blockNumber}.json`);
    const latestLink = path.join(outputDir, `phlimbo-v1-snapshot-latest.json`);
    try {
        fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n', 'utf8');
        // Also write a stable filename for the Foundry script to consume by default.
        fs.writeFileSync(latestLink, JSON.stringify(out, null, 2) + '\n', 'utf8');
    } catch (err) {
        die(5, `Failed to write snapshot: ${err.message}`);
    }

    console.log('');
    console.log('=== Snapshot summary ===');
    console.log(`  userCount:           ${out.userCount}`);
    console.log(`  totalUSDC owed:      ${out.totalUSDC}`);
    console.log(`  totalPHUSD deposit:  ${out.totalPHUSDDeposited}`);
    console.log(`  totalPHUSD pending:  ${out.totalPHUSDPending}`);
    console.log(`  blockNumber:         ${out.blockNumber}`);
    console.log(`  wrote:               ${outFile}`);
    console.log(`  wrote (alias):       ${latestLink}`);
}

main().catch((err) => {
    console.error('UNCAUGHT:', err?.stack || err);
    process.exit(3);
});
