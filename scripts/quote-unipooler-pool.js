#!/usr/bin/env node
/**
 * quote-unipooler-pool.js  (story 105, sprint Balancexit)
 *
 * Computes the slippage floors for `UniPoolerV2.pool(sUSDSIn, minPhusdOut, minLP)` on the live index-4 UniPooler
 * (script/UniPoolerPool.s.sol, npm `unipooler:pool:*`) and prints them as env-var assignments:
 *
 *     eval "$(node scripts/quote-unipooler-pool.js all 50)"
 *     # -> export SUSDS_IN_WEI=...   export MIN_PHUSD_OUT_WEI=...   export MIN_LP_WEI=...
 *
 * Replaces scripts/compute-min-bpt-poolerv2.js (the dead Balancer `pool(minBPT)` quote).
 *
 * WHAT IT QUOTES. `quotePool(sUSDSIn) returns (swapIn, phusdOut, expectedLP)` via `cast call` (an `eth_call`), sized
 * from the pair's live balances exactly as `pool()` sizes after its `sync()`. Then:
 *
 *     MIN_PHUSD_OUT_WEI = phusdOut   * (10000 - TOLERANCE_BPS) / 10000     (BigInt floor division)
 *     MIN_LP_WEI        = expectedLP * (10000 - TOLERANCE_BPS) / 10000
 *
 * Re-quote immediately before :preview and :broadcast, in the SAME shell, so both use identical floors. A trade on
 * the pair between quoting and broadcasting can push the live quote below a floor; the simulation then reverts and
 * you re-quote.
 *
 * WHICH POOLER. `UniPooler` is read from server/deployments/mainnet-addresses.ts (hand-maintained; patched by the
 * Stage 4 cutover). While it is still the zero placeholder the helper refuses before touching the RPC.
 *
 * USAGE
 *   node scripts/quote-unipooler-pool.js <SUSDS_IN_WEI|all> [TOLERANCE_BPS]
 *     SUSDS_IN_WEI   sUSDS to pool, in wei, or `all` for the pooler's whole sUSDS balance. Must not exceed it.
 *     TOLERANCE_BPS  integer 1..100 (default 50). Capped at 100 = UniPoolerPool.s.sol's MAX_TOLERANCE_BPS, because
 *                    a looser floor is rejected by the script.
 *   Env: RPC_MAINNET (or MAINNET_RPC_URL) required.
 *
 * STDOUT carries ONLY the three `export` lines. Diagnostics go to STDERR. On any failure (zero UniPooler, RPC, cast
 * missing, a zero quote) it prints NOTHING to STDOUT and exits non-zero; the Solidity script's non-zero-floor and
 * live-quote checks, and `pool()`'s own `UniPoolerV2__ZeroMinimum`, are the backstops.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ADDRESS_BOOK = path.join(__dirname, '..', 'server', 'deployments', 'mainnet-addresses.ts');
const ZERO = '0x0000000000000000000000000000000000000000';

const DEFAULT_TOLERANCE_BPS = 50n;
const MAX_TOLERANCE_BPS = 100n; // UniPoolerPool.s.sol MAX_TOLERANCE_BPS

const TAG = '[quote-unipooler-pool]';

function fail(msg, code = 1) {
    console.error(`${TAG} ERROR: ${msg}`);
    process.exit(code);
}

function log(msg) {
    console.error(`${TAG} ${msg}`);
}

/** The address literal of an uncommented top-level `  <key>: "0x..."` entry (same reader as the Solidity scripts). */
function bookAddress(key) {
    let src;
    try {
        src = fs.readFileSync(ADDRESS_BOOK, 'utf8');
    } catch (e) {
        fail(`cannot read ${ADDRESS_BOOK}: ${e.message}`);
    }
    const m = src.match(new RegExp(`\\n  ${key}: "(0x[0-9a-fA-F]{40})"`));
    if (!m) fail(`key ${key} not found in mainnet-addresses.ts`);
    return m[1];
}

function cast(rpc, args) {
    const res = spawnSync('cast', [...args, '--rpc-url', rpc], { encoding: 'utf8', env: process.env });
    if (res.error) fail(`failed to spawn 'cast' (is Foundry installed?): ${res.error.message}`);
    if (res.status !== 0) fail(`cast ${args.slice(0, 3).join(' ')} failed:\n${(res.stderr || res.stdout || '').trim()}`);
    return (res.stdout || '').trim();
}

function uintCall(rpc, target, sig, ...a) {
    // cast may append a human-readable suffix, e.g. "2040... [2.04e22]"; take the raw integer.
    return BigInt(cast(rpc, ['call', target, sig, ...a]).split(/\s+/)[0]);
}

function parseArgs(argv) {
    if (argv.length < 1 || argv.length > 2) fail('usage: quote-unipooler-pool.js <SUSDS_IN_WEI|all> [TOLERANCE_BPS]');
    const amount = argv[0];
    if (amount !== 'all' && !/^[0-9]+$/.test(amount)) fail(`SUSDS_IN_WEI must be an integer (wei) or "all", got "${amount}"`);
    if (amount !== 'all' && BigInt(amount) === 0n) fail('SUSDS_IN_WEI must be non-zero');
    let tol = DEFAULT_TOLERANCE_BPS;
    if (argv.length === 2) {
        if (!/^[0-9]+$/.test(argv[1])) fail(`TOLERANCE_BPS must be an integer, got "${argv[1]}"`);
        tol = BigInt(argv[1]);
        if (tol < 1n || tol > MAX_TOLERANCE_BPS) fail(`TOLERANCE_BPS out of range (1..${MAX_TOLERANCE_BPS}): ${tol}`);
    }
    return { amount, tol };
}

function main() {
    const { amount, tol } = parseArgs(process.argv.slice(2));

    const pooler = bookAddress('UniPooler');
    if (pooler.toLowerCase() === ZERO) {
        fail(
            'UniPooler in server/deployments/mainnet-addresses.ts is the zero placeholder - the Stage 4 cutover ' +
                '(npm run unipooler-cutover:broadcast) has not been run/patched yet. Nothing to quote.'
        );
    }

    const rpc = process.env.RPC_MAINNET || process.env.MAINNET_RPC_URL;
    if (!rpc) fail('RPC_MAINNET (or MAINNET_RPC_URL) is not set');
    const chainId = cast(rpc, ['chain-id']);
    if (chainId !== '1') fail(`RPC chain id is ${chainId}, expected 1 (mainnet)`);

    const sUSDS = cast(rpc, ['call', pooler, 'sUSDS()(address)']).split(/\s+/)[0];
    const balance = uintCall(rpc, sUSDS, 'balanceOf(address)(uint256)', pooler);
    const sUSDSIn = amount === 'all' ? balance : BigInt(amount);
    if (sUSDSIn === 0n) fail('the pooler holds 0 sUSDS - nothing to pool');
    if (sUSDSIn > balance) fail(`SUSDS_IN_WEI ${sUSDSIn} exceeds the pooler's sUSDS balance ${balance}`);

    const block = cast(rpc, ['block-number']);
    const out = cast(rpc, ['call', pooler, 'quotePool(uint256)(uint256,uint256,uint256)', sUSDSIn.toString()])
        .split('\n')
        .map((l) => BigInt(l.trim().split(/\s+/)[0]));
    if (out.length !== 3) fail(`quotePool returned ${out.length} values, expected 3`);
    const [swapIn, phusdOut, expectedLP] = out;

    const floor = (q) => (q * (10000n - tol)) / 10000n;
    const minPhusdOut = floor(phusdOut);
    const minLP = floor(expectedLP);
    if (minPhusdOut === 0n || minLP === 0n) fail('a floor rounded to 0 - refusing to emit an unprotected floor');

    log(`block               : ${block}`);
    log(`UniPooler           : ${pooler}`);
    log(`pooler sUSDS        : ${balance} (~${Number(balance) / 1e18} sUSDS)`);
    log(`SUSDS_IN_WEI        : ${sUSDSIn} (~${Number(sUSDSIn) / 1e18} sUSDS)`);
    log(`quote swapIn        : ${swapIn}`);
    log(`quote phusdOut      : ${phusdOut}`);
    log(`quote expectedLP    : ${expectedLP}`);
    log(`tolerance (bps)     : ${tol}`);
    log(`MIN_PHUSD_OUT_WEI   : ${minPhusdOut} (~${Number(minPhusdOut) / 1e18} phUSD)`);
    log(`MIN_LP_WEI          : ${minLP}`);

    process.stdout.write(
        `export SUSDS_IN_WEI=${sUSDSIn}\nexport MIN_PHUSD_OUT_WEI=${minPhusdOut}\nexport MIN_LP_WEI=${minLP}\n`
    );
}

main();
