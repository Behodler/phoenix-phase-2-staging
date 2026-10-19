#!/usr/bin/env node
/**
 * quote-balancer-exit-min-amounts.js  (story 103, sprint Balancexit)
 *
 * Computes the Balancer V3 exit floors (`minAmountsOut`) for the index-4 UniPoolerV2 cutover
 * (script/DeployMainnetUniPoolerCutover.s.sol) and prints them as env-var assignments:
 *
 *     eval "$(node scripts/quote-balancer-exit-min-amounts.js 10)"
 *     # -> export MIN_SUSDS_OUT_WEI=...   export MIN_PHUSD_OUT_WEI=...
 *
 * WHAT IT QUOTES. The escrow exits the OLD POOLER's whole BPT balance (after `withdrawBPT(escrow, bal)`), never
 * the owner's (F-02-052: owner BPT is out of scope; it is reported here on STDERR only). For each pool token:
 *
 *     share_i = balancesRaw_i * BPT.balanceOf(oldPooler) / BPT.totalSupply()     (live, via `cast call`)
 *     floor_i = share_i * (10000 - TOLERANCE_BPS) / 10000                          (BigInt floor division)
 *
 * which is exactly the share the cutover core re-checks on chain (`_checkMinAmountsOut`, each floor in
 * [share * (1 - 0.5%), share]). The quote is read with `cast call` (an `eth_call`), the same off-chain-quote →
 * env-var pattern as scripts/quote-unipooler-pool.js. It is valid for the proportional exit and for the
 * recovery exit (both pay the proportional share of raw balances). Re-quote immediately before broadcasting: a
 * swap on the live pool moves the share, and a floor above the moved share reverts the simulation.
 *
 * USAGE
 *   node scripts/quote-balancer-exit-min-amounts.js [TOLERANCE_BPS]
 *     TOLERANCE_BPS  integer 1..50 (default 10). Capped at 50 = the script's EXIT_TOLERANCE_BPS, because a floor
 *                    looser than that is rejected on chain ("minAmountOut below tolerance").
 *   Env: RPC_MAINNET (or MAINNET_RPC_URL) required.
 *
 * STDOUT carries ONLY the two `export` lines. Diagnostics go to STDERR. On any failure (RPC, cast missing, a zero
 * share) it prints NOTHING to STDOUT and exits non-zero; the Solidity script's `require(min > 0)` and its live
 * share check are the backstops.
 */

const { spawnSync } = require('child_process');

const OLD_POOLER = '0x7f6874332c4629429d70D15f685A8230323F11F1'; // mainnet-addresses.ts BalancerPooler
const BPT = '0x642BB6860b4776CC10b26B8f361Fd139E7f0db04'; // BalancerPool
const VAULT = '0xbA1333333333a1BA1108E8412f11850A5C319bA9'; // BalancerVault (V3)
const SUSDS = '0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD';
const PHUSD = '0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605';
const OWNER = '0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6';

const DEFAULT_TOLERANCE_BPS = 10n;
const MAX_TOLERANCE_BPS = 50n; // DeployMainnetUniPoolerCutover.EXIT_TOLERANCE_BPS

function fail(msg, code = 1) {
    console.error(`[quote-balancer-exit-min-amounts] ERROR: ${msg}`);
    process.exit(code);
}

function log(msg) {
    console.error(`[quote-balancer-exit-min-amounts] ${msg}`);
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

function parseTolerance(argv) {
    if (argv.length > 1) fail('usage: quote-balancer-exit-min-amounts.js [TOLERANCE_BPS]');
    if (argv.length === 0) return DEFAULT_TOLERANCE_BPS;
    if (!/^[0-9]+$/.test(argv[0])) fail(`TOLERANCE_BPS must be an integer, got "${argv[0]}"`);
    const t = BigInt(argv[0]);
    if (t < 1n || t > MAX_TOLERANCE_BPS) fail(`TOLERANCE_BPS out of range (1..${MAX_TOLERANCE_BPS}): ${t}`);
    return t;
}

function main() {
    const tol = parseTolerance(process.argv.slice(2));
    const rpc = process.env.RPC_MAINNET || process.env.MAINNET_RPC_URL;
    if (!rpc) fail('RPC_MAINNET (or MAINNET_RPC_URL) is not set');

    const chainId = cast(rpc, ['chain-id']);
    if (chainId !== '1') fail(`RPC chain id is ${chainId}, expected 1 (mainnet)`);

    const block = cast(rpc, ['block-number']);
    const info = JSON.parse(
        cast(rpc, [
            'call',
            VAULT,
            'getPoolTokenInfo(address)(address[],(uint8,address,bool)[],uint256[],uint256[])',
            BPT,
            '--json',
        ])
    );
    const tokens = info[0].map((t) => t.toLowerCase());
    const raw = info[2].map((b) => BigInt(b));
    if (tokens.length !== 2) fail(`pool has ${tokens.length} tokens, expected 2`);
    const iS = tokens.indexOf(SUSDS.toLowerCase());
    const iP = tokens.indexOf(PHUSD.toLowerCase());
    if (iS < 0 || iP < 0) fail(`pool tokens are ${tokens.join(', ')}, expected sUSDS and phUSD`);

    const bal = uintCall(rpc, BPT, 'balanceOf(address)(uint256)', OLD_POOLER);
    const supply = uintCall(rpc, BPT, 'totalSupply()(uint256)');
    const ownerBpt = uintCall(rpc, BPT, 'balanceOf(address)(uint256)', OWNER);
    if (bal === 0n) fail('the old pooler holds 0 BPT - nothing to exit (already cut over?)');
    if (supply === 0n) fail('BPT totalSupply is 0');

    const floor = (r) => ((r * bal) / supply) * (10000n - tol) / 10000n;
    const minS = floor(raw[iS]);
    const minP = floor(raw[iP]);
    if (minS === 0n || minP === 0n) fail('a floor rounded to 0 - refusing to emit an unprotected floor');

    log(`block                 : ${block}`);
    log(`old pooler BPT (exit) : ${bal}`);
    log(`BPT totalSupply       : ${supply}`);
    log(`pool sUSDS / phUSD raw: ${raw[iS]} / ${raw[iP]}`);
    log(`tolerance (bps)       : ${tol}`);
    log(`MIN_SUSDS_OUT_WEI     : ${minS} (~${Number(minS) / 1e18} sUSDS)`);
    log(`MIN_PHUSD_OUT_WEI     : ${minP} (~${Number(minP) / 1e18} phUSD)`);
    log(`owner BPT             : ${ownerBpt} (out of scope, NOT exited; F-02-052)`);

    process.stdout.write(`export MIN_SUSDS_OUT_WEI=${minS}\nexport MIN_PHUSD_OUT_WEI=${minP}\n`);
}

main();
