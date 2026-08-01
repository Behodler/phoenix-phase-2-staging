#!/usr/bin/env node
/**
 * snapshot-depletion-stakers.js  (story 072)
 *
 * Off-chain snapshot of the staked-user list for the three live V1
 * `NFTStakerDepletion` instances (UniboostStakerEYE / SCX / FLX) that story 072's
 * Phase 6 migrates onto `NFTStakerDepletionV2` via `NFTStakerMigrator`.
 *
 * WHY THIS EXISTS
 *   `NFTStakerMigrator.migrate(address[] users)` takes an explicit user list. The
 *   stakers keep no on-chain enumeration of their depositors — `userInfo` is a
 *   mapping — so the list can only be recovered off-chain from the `Staked` /
 *   `DepositedFor` event history. `migrate` is re-runnable (an already-migrated
 *   user's `_exitPosition` returns 0 and is skipped), so a superset is harmless
 *   and a subset silently strands stake on V1. This script therefore errs toward
 *   a superset: every address that has ever appeared as a depositor is a
 *   candidate, and only the `userInfo(addr).amount > 0` filter removes any.
 *
 * WHICH EVENTS
 *   `Staked(address indexed user, uint256 amount)`        NFTStakerDepletion.sol:232
 *   `Unstaked(address indexed user, uint256 amount)`      NFTStakerDepletion.sol:233
 *   `DepositedFor(address indexed user, uint256 amount)`  NFTStakerDepletion.sol:273
 *
 *   `Unstaked` is scanned even though it can only ever REMOVE stake: an address
 *   that appears solely in `Unstaked` cannot exist (you cannot unstake without
 *   having staked), but scanning it costs one extra topic filter and makes the
 *   candidate set provably closed over every balance-moving user event. The
 *   authoritative filter is the `userInfo` read, not the event set.
 *   `DepositedFor` is included because the migrator itself credits users that
 *   way — relevant only if a PRIOR partial migration ran.
 *
 * TIMING
 *   The list is read live and re-filtered by `userInfo(...).amount > 0`. It does
 *   NOT need to be taken after a pause: the Foundry script pauses each V1 staker
 *   itself (Phase 6 step 5) and `migrate` is re-runnable, so a user who stakes
 *   between snapshot and broadcast is at worst left on V1 and can be swept by a
 *   second `migrate` call. `sumStaked` vs on-chain `totalStaked` is reported so
 *   any such drift is visible rather than silent.
 *
 * OUTPUT
 *   scripts/snapshots/depletion-stakers-<block>.json
 *   scripts/snapshots/depletion-stakers-latest.json   <- consumed by
 *     script/DeployMainnetPromotionReady.s.sol via vm.readFile + vm.parseJson
 *
 *   Shape (the Foundry script reads the three `.stakers.<Key>.users` arrays):
 *     {
 *       chainId, networkName, blockNumber, timestamp,
 *       stakers: {
 *         UniboostStakerEYE: { address, totalStaked, committedDebt, rewardBalance,
 *                              paused, pauser, owner, users: [...], stakes: [...],
 *                              sumStaked, userCount },
 *         UniboostStakerSCX: { ... },
 *         UniboostStakerFLX: { ... }
 *       }
 *     }
 *
 * Usage:
 *   RPC_MAINNET=https://... node scripts/snapshot-depletion-stakers.js
 *
 * Optional env:
 *   RPC_MAINNET   RPC URL (required)
 *   FROM_BLOCK    Lower bound for the log scan (default 0 -> DEFAULT_FROM_BLOCK)
 *   TO_BLOCK      Upper bound (default: chain tip)
 *   CHUNK_SIZE    eth_getLogs chunk size in blocks (default 50_000)
 *   OUTPUT_DIR    Output dir (default scripts/snapshots)
 *
 * Exit codes:
 *   0 - Success
 *   1 - Missing RPC_MAINNET
 *   2 - Could not resolve a staker address from mainnet-addresses.ts
 *   3 - RPC / network error
 *   4 - A staker reports totalStaked > 0 but the scan found no holders (would
 *       silently strand stake on V1 — refuse to emit a snapshot the Foundry
 *       script would then trust)
 *   5 - Output write failure
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const DEFAULT_OUTPUT_DIR = path.join(__dirname, 'snapshots');

// The three Uniboost stakers were deployed by story 071's cutover broadcast
// (2026-07-08). Nothing before that block can carry one of their events, so this
// floor only removes dead scan range. Lowered deliberately below the actual
// deploy block so a mis-remembered date cannot truncate the history.
const DEFAULT_FROM_BLOCK = 25000000n;

const STAKER_KEYS = ['UniboostStakerEYE', 'UniboostStakerSCX', 'UniboostStakerFLX'];

function die(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function resolveAddress(key) {
    const envOverride = process.env[`${key.toUpperCase()}_ADDRESS`];
    if (envOverride) return envOverride;
    if (!fs.existsSync(ADDRESSES_FILE)) die(2, `mainnet-addresses.ts not found at ${ADDRESSES_FILE}`);
    const src = fs.readFileSync(ADDRESSES_FILE, 'utf8');
    const m = src.match(new RegExp(`${key}:\\s*"(0x[0-9a-fA-F]{40})"`));
    if (!m) die(2, `${key} address not found in mainnet-addresses.ts`);
    return m[1];
}

function loadViem() {
    try {
        return require('viem');
    } catch (err) {
        die(3, 'viem not installed. Run `npm install` in the project root first.');
    }
}

const STAKER_ABI = [
    { type: 'event', name: 'Staked', inputs: [{ name: 'user', type: 'address', indexed: true }, { name: 'amount', type: 'uint256' }] },
    { type: 'event', name: 'Unstaked', inputs: [{ name: 'user', type: 'address', indexed: true }, { name: 'amount', type: 'uint256' }] },
    { type: 'event', name: 'DepositedFor', inputs: [{ name: 'user', type: 'address', indexed: true }, { name: 'amount', type: 'uint256' }] },
    {
        type: 'function', name: 'userInfo', stateMutability: 'view',
        inputs: [{ name: 'user', type: 'address' }],
        outputs: [{ name: 'amount', type: 'uint256' }, { name: 'rewardDebt', type: 'uint256' }],
    },
    { type: 'function', name: 'totalStaked', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    { type: 'function', name: 'committedDebt', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    { type: 'function', name: 'depletionWindowMonths', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    { type: 'function', name: 'paused', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
    { type: 'function', name: 'pauser', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'owner', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'rewardToken', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'stakedId', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    { type: 'function', name: 'dispatcherIndex', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    { type: 'function', name: 'migrator', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
];

const ERC20_ABI = [
    { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
];

const MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11';

function chainConfig(chainId) {
    let base;
    try {
        const chains = require('viem/chains');
        if (chainId === 1) base = chains.mainnet;
    } catch (_) {
        /* fall through to the stub */
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
        base = { ...base, contracts: { ...(base.contracts || {}), multicall3: { address: MULTICALL3_ADDRESS } } };
    }
    return base;
}

async function chunkedQueryFilter(client, address, eventAbi, fromBlock, toBlock, chunkSize) {
    let from = fromBlock;
    const out = [];
    while (from <= toBlock) {
        const to = from + BigInt(chunkSize) - 1n > toBlock ? toBlock : from + BigInt(chunkSize) - 1n;
        try {
            const logs = await client.getLogs({ address, event: eventAbi, fromBlock: from, toBlock: to });
            out.push(...logs);
        } catch (err) {
            const halfSize = Math.max(1000, Math.floor(chunkSize / 2));
            if (halfSize === chunkSize) die(3, `eth_getLogs failed irrecoverably at ${from}..${to}: ${err.message}`);
            const retry = await chunkedQueryFilter(client, address, eventAbi, from, to, halfSize);
            out.push(...retry);
        }
        from = to + 1n;
    }
    return out;
}

async function multicallBatched(client, calls, batchSize = 200) {
    const out = [];
    for (let i = 0; i < calls.length; i += batchSize) {
        const res = await client.multicall({ contracts: calls.slice(i, i + batchSize), allowFailure: false });
        out.push(...res);
    }
    return out;
}

async function snapshotOne(client, viem, key, address, fromBlock, toBlock, chunkSize) {
    console.log(`\n--- ${key} @ ${address} ---`);

    const [owner, pauser, paused, totalStaked, committedDebt, windowMonths, rewardToken, stakedId, dispatcherIndex, migrator] =
        await Promise.all(
            ['owner', 'pauser', 'paused', 'totalStaked', 'committedDebt', 'depletionWindowMonths', 'rewardToken', 'stakedId', 'dispatcherIndex', 'migrator'].map((fn) =>
                client.readContract({ address, abi: STAKER_ABI, functionName: fn })
            )
        );

    const rewardBalance = await client.readContract({
        address: rewardToken, abi: ERC20_ABI, functionName: 'balanceOf', args: [address],
    });

    console.log(`  owner=${owner} pauser=${pauser} paused=${paused}`);
    console.log(`  stakedId=${stakedId} dispatcherIndex=${dispatcherIndex} window=${windowMonths}mo migrator=${migrator}`);
    console.log(`  totalStaked=${totalStaked} committedDebt=${committedDebt} rewardBalance=${rewardBalance}`);

    const seen = new Set();
    const candidates = [];
    for (const name of ['Staked', 'Unstaked', 'DepositedFor']) {
        const eventAbi = STAKER_ABI.find((x) => x.type === 'event' && x.name === name);
        const logs = await chunkedQueryFilter(client, address, eventAbi, fromBlock, toBlock, chunkSize);
        console.log(`  ${name}: ${logs.length} log(s)`);
        for (const log of logs) {
            const user = (log.args?.user || '').toLowerCase();
            if (!user || seen.has(user)) continue;
            seen.add(user);
            candidates.push(user);
        }
    }
    console.log(`  unique candidate addresses: ${candidates.length}`);

    let survivors = [];
    if (candidates.length > 0) {
        const infos = await multicallBatched(
            client,
            candidates.map((u) => ({ address, abi: STAKER_ABI, functionName: 'userInfo', args: [u] }))
        );
        for (let i = 0; i < candidates.length; i++) {
            const info = infos[i];
            const amount = Array.isArray(info) ? info[0] : info.amount;
            if (amount && amount > 0n) survivors.push({ user: candidates[i], amount });
        }
    }

    const sumStaked = survivors.reduce((a, s) => a + s.amount, 0n);
    console.log(`  holders with non-zero stake: ${survivors.length} (sum=${sumStaked}, on-chain totalStaked=${totalStaked})`);

    if (totalStaked > 0n && survivors.length === 0) {
        die(4, `${key}: totalStaked=${totalStaked} but the scan found no holders — the migrate() list would be empty and stake would be stranded on V1. Widen FROM_BLOCK and retry.`);
    }
    if (sumStaked !== totalStaked) {
        console.log('  WARNING: sum(userInfo.amount) != totalStaked. `migrate` is re-runnable, so a');
        console.log('           subset is recoverable — but investigate before broadcasting, because');
        console.log('           `finalizeAndReset` requires totalStaked == 0.');
    }

    return {
        address: viem.getAddress(address),
        owner,
        pauser,
        paused,
        stakedId: stakedId.toString(),
        dispatcherIndex: dispatcherIndex.toString(),
        depletionWindowMonths: windowMonths.toString(),
        migrator,
        rewardToken,
        rewardBalance: rewardBalance.toString(),
        totalStaked: totalStaked.toString(),
        committedDebt: committedDebt.toString(),
        users: survivors.map((s) => viem.getAddress(s.user)),
        stakes: survivors.map((s) => s.amount.toString()),
        sumStaked: sumStaked.toString(),
        userCount: survivors.length,
    };
}

async function main() {
    const RPC = process.env.RPC_MAINNET;
    if (!RPC) die(1, 'RPC_MAINNET env var is required');

    const viem = loadViem();
    const transport = viem.http(RPC, { batch: true, retryCount: 3, retryDelay: 500 });
    const probe = viem.createPublicClient({ transport });
    const chainId = await probe.getChainId();
    console.log(`Chain ID: ${chainId}`);
    const client = viem.createPublicClient({ chain: chainConfig(chainId), transport });

    const tip = await client.getBlockNumber();
    const fromBlock = process.env.FROM_BLOCK ? BigInt(process.env.FROM_BLOCK) : DEFAULT_FROM_BLOCK;
    const toBlock = process.env.TO_BLOCK ? BigInt(process.env.TO_BLOCK) : tip;
    const chunkSize = process.env.CHUNK_SIZE ? Number(process.env.CHUNK_SIZE) : 50_000;
    console.log(`Scanning blocks ${fromBlock} .. ${toBlock} (chunk=${chunkSize})`);

    const stakers = {};
    for (const key of STAKER_KEYS) {
        const address = resolveAddress(key);
        stakers[key] = await snapshotOne(client, viem, key, address, fromBlock, toBlock, chunkSize);
    }

    const out = {
        chainId,
        networkName: chainId === 1 ? 'mainnet' : `chain-${chainId}`,
        blockNumber: Number(toBlock),
        timestamp: new Date().toISOString(),
        source: { fromBlock: Number(fromBlock), toBlock: Number(toBlock), chunkSize },
        stakers,
    };

    const outputDir = process.env.OUTPUT_DIR || DEFAULT_OUTPUT_DIR;
    if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });
    const outFile = path.join(outputDir, `depletion-stakers-${out.blockNumber}.json`);
    const latest = path.join(outputDir, 'depletion-stakers-latest.json');
    try {
        fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n', 'utf8');
        fs.writeFileSync(latest, JSON.stringify(out, null, 2) + '\n', 'utf8');
    } catch (err) {
        die(5, `Failed to write snapshot: ${err.message}`);
    }

    console.log('\n=== Snapshot summary ===');
    for (const key of STAKER_KEYS) {
        const s = stakers[key];
        console.log(`  ${key.padEnd(20)} users=${String(s.userCount).padStart(4)}  totalStaked=${s.totalStaked}  budget=${s.rewardBalance}`);
    }
    console.log(`  blockNumber:   ${out.blockNumber}`);
    console.log(`  wrote:         ${outFile}`);
    console.log(`  wrote (alias): ${latest}`);
}

main().catch((err) => {
    console.error('UNCAUGHT:', err?.stack || err);
    process.exit(3);
});
