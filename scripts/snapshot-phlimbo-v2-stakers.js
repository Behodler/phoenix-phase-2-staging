#!/usr/bin/env node
/**
 * snapshot-phlimbo-v2-stakers.js  (story 076)
 *
 * Off-chain snapshot of the PhlimboV2 (`PhlimboEA` key) user base, for the
 * PhlimboV3 cutover's Phase 4e. Output is a JSON file consumed by
 * `script/DeployMainnetPromotionReady.s.sol` via `vm.readFile` + `vm.parseJson`,
 * which feeds it straight into `MigratorV2V3.seedUsers(address[])`.
 *
 * ==================== WHY THIS IS AN ADDRESS LIST AND NOTHING MORE ====================
 *
 * Its V1 predecessor (`snapshot-phlimbo-v1-stakers.js`, story 049) also snapshotted
 * per-user deposits and pending rewards, because `MigratorV1V2` seeded BALANCES and
 * strictly `==`-validated them on-chain. `MigratorV2V3` deliberately does not:
 *
 *   "LIVE position reads from V2 instead of seeded balance snapshots. This makes the
 *    migration robust to users interacting with V2 mid-migration"
 *      -- MigratorV2V3.sol:20-24
 *
 * `migrate` reads `(amount,,) = phlimboV2.userInfo(user)` at execution time
 * (`MigratorV2V3.sol:191`), so an amount captured here would be decoration at best and
 * a false precision at worst. This script therefore supplies the ADDRESS LIST ONLY.
 * The amounts below are recorded in `source` for the operator's eyes and are never read
 * by the Foundry script.
 *
 * ==================== TIMING ====================
 *
 * Unlike the V1 snapshot, this one MUST NOT be taken after a pause: PhlimboV2 must NOT
 * be paused for this migration. `PhlimboV2.withdraw` is `whenNotPaused` and the migrator
 * calls exactly that, so a paused V2 yields a pass that COMPLETES with every user
 * skipped (`MigratorV2V3.sol:22-24`, `:65-73`). The wind-down is operational
 * (`setDesiredAPY(0)` + redirecting the accumulator), not a pause. See story 076
 * Concerns section 2.
 *
 * A user may therefore stake into V2 between this snapshot and the broadcast. That is
 * expected and handled: Phase 4e reseeds and re-runs the pass within the session, and
 * gates the cutover on `phlimboV2.totalStaked() == 0`. Freshness still matters, because
 * a user whose FIRST EVER `Staked` event postdates this scan is not in the list at all
 * and no reseed can invent them — hence the staleness gate
 * (`scripts/check-phlimbo-snapshot-age.js --variant v2`) and Phase 0's own age check.
 *
 * Strategy:
 *   1. Resolve the V2 address from `server/deployments/mainnet-addresses.ts` (`PhlimboEA`).
 *   2. queryFilter `Staked(address indexed user, uint256 amount)` from FROM_BLOCK to
 *      `latest`, chunked to stay under provider `eth_getLogs` limits.
 *   3. Dedupe `user` (first-appearance order preserved -- it is also the migrator's
 *      cursor order).
 *   4. Multicall `userInfo(addr)` -> keep where `amount > 0`.
 *   5. Write the JSON shape Phase 0 validates and Phase 4e seeds from.
 *
 * Output shape (the four fields the Foundry script reads are marked *):
 *   {
 *     chainId, networkName,
 *     phlimboV2,        * asserted == the script's PHLIMBO_V2 constant
 *     blockNumber,      * asserted > 0
 *     unixTimestamp,    * asserted within MAX_V2_SNAPSHOT_AGE of block.timestamp
 *     timestamp,          ISO string, for the JS staleness gate
 *     users[],          * seedUsers input
 *     userCount,
 *     source: { owner, pauser, paused, migrator, desiredAPYBps, depletionDuration,
 *               rewardToken, totalStaked, sumDeposits, deposits[], minimumStake,
 *               dustUserCount, fromBlock, toBlock, chunkSize }
 *   }
 *
 * Output location:
 *   scripts/snapshots/phlimbo-v2-snapshot-<block>.json
 *   scripts/snapshots/phlimbo-v2-snapshot-latest.json   (stable alias)
 *
 * Usage:
 *   RPC_MAINNET=https://... node scripts/snapshot-phlimbo-v2-stakers.js
 *
 * Optional env:
 *   PHLIMBO_V2_ADDRESS  Override the V2 address (default: PhlimboEA from
 *                       mainnet-addresses.ts)
 *   FROM_BLOCK          Lower bound for the Staked scan (default 0)
 *   TO_BLOCK            Upper bound (default latest)
 *   CHUNK_SIZE          eth_getLogs chunk size in blocks (default 50_000)
 *   OUTPUT_DIR          Output dir (default scripts/snapshots)
 *
 * Exit codes (mirrors the V1 script):
 *   0 - Success
 *   1 - Missing RPC_MAINNET
 *   2 - Could not resolve the V2 address
 *   3 - RPC / network error
 *   4 - Empty staker set (nothing to migrate)
 *   5 - Output write failure
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

function resolveV2Address() {
    if (process.env.PHLIMBO_V2_ADDRESS) return process.env.PHLIMBO_V2_ADDRESS;
    if (!fs.existsSync(ADDRESSES_FILE)) die(2, `mainnet-addresses.ts not found at ${ADDRESSES_FILE}`);
    const src = fs.readFileSync(ADDRESSES_FILE, 'utf8');
    // `PhlimboEA` is the V2 address and STAYS the V2 address after this cutover -- the new
    // `PhlimboV3` key is added alongside it, never in place of it (story 076 Concerns 4).
    const m = src.match(/PhlimboEA:\s*"(0x[0-9a-fA-F]{40})"/);
    if (!m) die(2, 'PhlimboEA address not found in mainnet-addresses.ts');
    return m[1];
}

function loadViem() {
    try {
        return require('viem');
    } catch (err) {
        die(3, 'viem not installed. Run `npm install` in the project root first.');
    }
}

const PHLIMBO_V2_ABI = [
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
    { type: 'function', name: 'owner', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'pauser', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'paused', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
    { type: 'function', name: 'migrator', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'rewardToken', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
    { type: 'function', name: 'desiredAPYBps', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    {
        type: 'function',
        name: 'depletionDuration',
        stateMutability: 'view',
        inputs: [],
        outputs: [{ type: 'uint256' }],
    },
    { type: 'function', name: 'totalStaked', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
    { type: 'function', name: 'MINIMUM_STAKE', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
];

async function chunkedQueryFilter(publicClient, address, eventAbi, fromBlock, toBlock, chunkSize) {
    let from = fromBlock;
    const out = [];
    while (from <= toBlock) {
        const to = from + BigInt(chunkSize) - 1n > toBlock ? toBlock : from + BigInt(chunkSize) - 1n;
        process.stdout.write(`  scanning logs [${from} .. ${to}] ... `);
        try {
            const logs = await publicClient.getLogs({ address, event: eventAbi, fromBlock: from, toBlock: to });
            console.log(`${logs.length} log(s)`);
            out.push(...logs);
        } catch (err) {
            console.log('FAILED');
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
            contracts: { ...(base.contracts || {}), multicall3: { address: MULTICALL3_ADDRESS } },
        };
    }
    return base;
}

async function main() {
    const RPC = process.env.RPC_MAINNET;
    if (!RPC) die(1, 'RPC_MAINNET env var is required');

    const viem = loadViem();
    const v2 = resolveV2Address();
    console.log(`PhlimboV2 address: ${v2}`);

    const transport = viem.http(RPC, { batch: true, retryCount: 3, retryDelay: 500 });
    const probeClient = viem.createPublicClient({ transport });
    const chainId = await probeClient.getChainId();
    console.log(`Chain ID: ${chainId}`);

    const publicClient = viem.createPublicClient({ chain: chainConfig(viem, chainId), transport });

    // ===== Pre-flight reads =====
    console.log('Pre-flight reads:');
    const read = (functionName) => publicClient.readContract({ address: v2, abi: PHLIMBO_V2_ABI, functionName });
    const [ownerAddr, pauserAddr, paused, migratorAddr, rewardToken, desiredAPYBps, depletionDuration, totalStaked, minimumStake] =
        await Promise.all([
            read('owner'),
            read('pauser'),
            read('paused'),
            read('migrator'),
            read('rewardToken'),
            read('desiredAPYBps'),
            read('depletionDuration'),
            read('totalStaked'),
            read('MINIMUM_STAKE'),
        ]);
    console.log(`  owner:             ${ownerAddr}`);
    console.log(`  pauser:            ${pauserAddr}`);
    console.log(`  paused:            ${paused}`);
    console.log(`  migrator:          ${migratorAddr}`);
    console.log(`  rewardToken:       ${rewardToken}`);
    console.log(`  desiredAPYBps:     ${desiredAPYBps}`);
    console.log(`  depletionDuration: ${depletionDuration} (${Number(depletionDuration) / 86400} days)`);
    console.log(`  totalStaked:       ${totalStaked}`);
    console.log(`  MINIMUM_STAKE:     ${minimumStake}`);

    if (paused) {
        // Not fatal here (this script only reads), but it is fatal for the migration.
        console.log('');
        console.log('*** WARNING: PhlimboV2 is PAUSED. ***');
        console.log('    MigratorV2V3 calls PhlimboV2.withdraw, which is whenNotPaused, and the');
        console.log('    per-user body runs inside a try/catch -- so a paass against a paused V2');
        console.log('    COMPLETES with every user skipped and looks identical to a good pass.');
        console.log('    Unpause V2 before broadcasting Phase 4e. See MigratorV2V3.sol:22-24.');
        console.log('');
    }

    // ===== Event scan =====
    const tip = await publicClient.getBlockNumber();
    const fromEnv = process.env.FROM_BLOCK ? BigInt(process.env.FROM_BLOCK) : 0n;
    const toEnv = process.env.TO_BLOCK ? BigInt(process.env.TO_BLOCK) : tip;
    const chunkSize = process.env.CHUNK_SIZE ? Number(process.env.CHUNK_SIZE) : 50_000;

    console.log(`Scanning Staked events from block ${fromEnv} to ${toEnv} (chunk=${chunkSize})`);
    const stakedEvent = PHLIMBO_V2_ABI.find((x) => x.type === 'event' && x.name === 'Staked');
    const logs = await chunkedQueryFilter(publicClient, v2, stakedEvent, fromEnv, toEnv, chunkSize);
    console.log(`Found ${logs.length} Staked event(s)`);

    // ===== Dedupe users (preserve first-seen order = the migrator's cursor order) =====
    const seen = new Set();
    const candidates = [];
    for (const log of logs) {
        const user = (log.args?.user || '').toLowerCase();
        if (!user || seen.has(user)) continue;
        seen.add(user);
        candidates.push(user);
    }
    console.log(`Unique candidate stakers: ${candidates.length}`);
    if (candidates.length === 0) die(4, 'No Staked events found -- nothing to snapshot.');

    // ===== Filter by userInfo.amount > 0 =====
    console.log('Reading userInfo for each candidate ...');
    const userInfos = await multicallBatched(
        publicClient,
        candidates.map((u) => ({ address: v2, abi: PHLIMBO_V2_ABI, functionName: 'userInfo', args: [u] })),
        200
    );

    const survivors = [];
    for (let i = 0; i < candidates.length; i++) {
        const info = userInfos[i];
        const amount = Array.isArray(info) ? info[0] : info.amount;
        if (amount && amount > 0n) survivors.push({ user: candidates[i], deposit: amount });
    }
    console.log(`Survivors with non-zero current stake: ${survivors.length}`);
    if (survivors.length === 0) die(4, 'No stakers with non-zero current stake -- nothing to migrate.');

    const sumDeposits = survivors.reduce((acc, x) => acc + x.deposit, 0n);
    console.log(`Sum of survivor deposits: ${sumDeposits}`);
    console.log(`On-chain totalStaked:     ${totalStaked}`);
    if (sumDeposits !== totalStaked) {
        console.log('WARNING: sum(deposits) != totalStaked. Either FROM_BLOCK is too high and');
        console.log('  Staked events were missed, or state moved between the two reads. A missed');
        console.log('  event is the dangerous case: Phase 4e gates on totalStaked()==0, so a user');
        console.log('  absent from this list will FAIL the cutover. Cross-check before broadcasting.');
    }

    // Dust users are informational only: `migrate` skips a live position below V3's
    // MINIMUM_STAKE up-front with an empty-reason UserMigrationSkipped
    // (MigratorV2V3.sol:194-200). They still count toward totalStaked, so they are exactly
    // the population that can block Phase 4e's completeness gate. Surfacing the count here
    // gives the operator the warning BEFORE the Ledger session rather than during it.
    const dustUsers = survivors.filter((s) => s.deposit < minimumStake);
    if (dustUsers.length > 0) {
        console.log('');
        console.log(`*** ${dustUsers.length} survivor(s) hold a position BELOW V3's MINIMUM_STAKE (${minimumStake}). ***`);
        console.log('    `migrate` skips these; they will remain in V2 and hold totalStaked above 0,');
        console.log('    which FAILS Phase 4e\'s completeness gate by design (story 076 Concerns 6).');
        console.log('    That is a finding about the live user base and is the owner\'s call to');
        console.log('    resolve -- do NOT relax the gate.');
        for (const d of dustUsers) console.log(`      ${viem.getAddress(d.user)}  ${d.deposit}`);
        console.log('');
    }

    // ===== Output JSON =====
    const outputDir = process.env.OUTPUT_DIR || DEFAULT_OUTPUT_DIR;
    if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

    const now = new Date();
    const out = {
        chainId,
        networkName: chainId === 1 ? 'mainnet' : `chain-${chainId}`,
        phlimboV2: viem.getAddress(v2),
        blockNumber: Number(toEnv),
        // Numeric seconds so the Foundry script can compare it against block.timestamp;
        // `vm.parseJson` has no ISO-8601 parser.
        unixTimestamp: Math.floor(now.getTime() / 1000),
        timestamp: now.toISOString(),
        users: survivors.map((s) => viem.getAddress(s.user)),
        userCount: survivors.length,
        source: {
            owner: ownerAddr,
            pauser: pauserAddr,
            paused,
            migrator: migratorAddr,
            rewardToken,
            desiredAPYBps: desiredAPYBps.toString(),
            depletionDuration: depletionDuration.toString(),
            totalStaked: totalStaked.toString(),
            sumDeposits: sumDeposits.toString(),
            // Informational only -- Phase 4e reads every position LIVE.
            deposits: survivors.map((s) => s.deposit.toString()),
            minimumStake: minimumStake.toString(),
            dustUserCount: dustUsers.length,
            fromBlock: Number(fromEnv),
            toBlock: Number(toEnv),
            chunkSize,
        },
    };

    const outFile = path.join(outputDir, `phlimbo-v2-snapshot-${out.blockNumber}.json`);
    const latestLink = path.join(outputDir, `phlimbo-v2-snapshot-latest.json`);
    try {
        fs.writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n', 'utf8');
        fs.writeFileSync(latestLink, JSON.stringify(out, null, 2) + '\n', 'utf8');
    } catch (err) {
        die(5, `Failed to write snapshot: ${err.message}`);
    }

    console.log('');
    console.log('=== PhlimboV2 snapshot summary ===');
    console.log(`  userCount:      ${out.userCount}`);
    console.log(`  totalStaked:    ${out.source.totalStaked}`);
    console.log(`  sumDeposits:    ${out.source.sumDeposits}`);
    console.log(`  dust users:     ${out.source.dustUserCount}`);
    console.log(`  blockNumber:    ${out.blockNumber}`);
    console.log(`  wrote:          ${outFile}`);
    console.log(`  wrote (alias):  ${latestLink}`);
}

main().catch((err) => {
    console.error('UNCAUGHT:', err?.stack || err);
    process.exit(3);
});
