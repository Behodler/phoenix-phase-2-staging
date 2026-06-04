#!/usr/bin/env node
/**
 * compute-min-bpt-poolerv2.js
 *
 * Computes a CORRECT, slippage-protected `minBPT` floor for invoking
 * `pool(uint256 minBPT)` on the live Sky-PSM BalancerPoolerV2, then prints that
 * floor (a single base-1e18 integer) to STDOUT so a package.json entry can
 * capture it into the MIN_BPT_WEI env var:
 *
 *     MIN_BPT_WEI=$(node scripts/compute-min-bpt-poolerv2.js) forge script ...
 *
 * WHY this is a separate off-chain step (not done inside the forge script):
 * The ideal-BPT quote comes from BalancerPoolerV2.getIdealBPT(), which calls the
 * Balancer V3 Router's `queryAddLiquidityUnbalanced`. That query path is gated by
 * Balancer V3 to run ONLY inside a true `eth_call` (STATICCALL) frame — it
 * mutates+reverts state internally — so it reverts `NotStaticCall()` if invoked
 * from a broadcast/prank transaction frame. `cast call` performs an `eth_call`,
 * which is exactly the frame the query requires. (Same constraint and resolution
 * as DispatcherReplaceSkyPoolerAtIndex4.s.sol step 17 and RescuePoolAndDonateUSDC.)
 *
 * minBPT = idealBPT * (10000 - SLIPPAGE_BPS) / 10000   (BigInt floor division)
 *
 * Diagnostics go to STDERR so STDOUT carries ONLY the integer. On any failure
 * (RPC error, cast missing, zero balance) it prints NOTHING to STDOUT and exits
 * non-zero — the Solidity script's `require(minBPT > 0)` is the final backstop.
 *
 * Env (all optional except RPC):
 *   RPC_MAINNET / MAINNET_RPC_URL  - mainnet RPC URL (required)
 *   POOLER_ADDRESS                 - override the pooler (default: live Sky-PSM PoolerV2)
 *   SLIPPAGE_BPS                   - slippage floor in bps (default: 100 = 1%)
 */

const { spawnSync } = require('child_process');

// Live Sky-PSM BalancerPoolerV2 (index-4 dispatcher, story 056, 2026-06-04).
// Source of truth: server/deployments/mainnet-addresses.ts -> nftsV2.BalancerPooler,
// cross-checked against broadcast/DispatcherReplaceSkyPoolerAtIndex4.s.sol/1/run-latest.json.
const DEFAULT_POOLER = '0x7f74388bc970de5e2822036a1ad06fccd156786b';
const DEFAULT_SLIPPAGE_BPS = 100n; // 1%

function fail(msg, code = 1) {
    console.error(`[compute-min-bpt-poolerv2] ERROR: ${msg}`);
    process.exit(code);
}

function castCall(rpc, target, sig, ...args) {
    const argv = ['call', target, sig, ...args, '--rpc-url', rpc];
    const res = spawnSync('cast', argv, { encoding: 'utf8', env: process.env });
    if (res.error) fail(`failed to spawn 'cast' (is Foundry installed?): ${res.error.message}`);
    if (res.status !== 0) {
        fail(`cast call ${sig} reverted/failed:\n${(res.stderr || res.stdout || '').trim()}`);
    }
    // cast may append a human-readable suffix e.g. "287850... [2.878e20]"; take the raw int.
    return (res.stdout || '').trim().split(/\s+/)[0];
}

function main() {
    const rpc = process.env.RPC_MAINNET || process.env.MAINNET_RPC_URL;
    if (!rpc) fail('RPC_MAINNET (or MAINNET_RPC_URL) is not set');

    const pooler = (process.env.POOLER_ADDRESS || DEFAULT_POOLER).trim();
    const slippageBps = process.env.SLIPPAGE_BPS ? BigInt(process.env.SLIPPAGE_BPS) : DEFAULT_SLIPPAGE_BPS;
    if (slippageBps < 0n || slippageBps >= 10000n) {
        fail(`SLIPPAGE_BPS out of range (0..9999): ${slippageBps}`);
    }

    console.error(`[compute-min-bpt-poolerv2] pooler        : ${pooler}`);
    console.error(`[compute-min-bpt-poolerv2] slippage (bps): ${slippageBps}`);

    // sUSDS balance currently sitting on the pooler (this is what pool() will consume).
    const sUSDS = castCall(rpc, pooler, 'sUSDS()(address)');
    const sUSDSBal = BigInt(castCall(rpc, sUSDS, 'balanceOf(address)(uint256)', pooler));
    console.error(`[compute-min-bpt-poolerv2] sUSDS         : ${sUSDS}`);
    console.error(`[compute-min-bpt-poolerv2] sUSDS balance : ${sUSDSBal} (${Number(sUSDSBal) / 1e18} sUSDS)`);

    if (sUSDSBal === 0n) {
        fail('pooler holds 0 sUSDS — nothing to pool. Run this after mints accumulate sUSDS.');
    }

    // Router ideal-BPT quote for the current sUSDS balance (eth_call ONLY — see header).
    const idealRaw = castCall(rpc, pooler, 'getIdealBPT()(uint256)');
    const idealBPT = BigInt(idealRaw);
    console.error(`[compute-min-bpt-poolerv2] idealBPT      : ${idealBPT} (${Number(idealBPT) / 1e18} BPT)`);
    if (idealBPT === 0n) {
        fail('getIdealBPT() returned 0 despite non-zero sUSDS — refusing to emit an unprotected (0) floor.');
    }

    // Floor: drop the bottom SLIPPAGE_BPS of the quote. Conservative (rounds down).
    const minBPT = (idealBPT * (10000n - slippageBps)) / 10000n;
    if (minBPT === 0n) fail('computed minBPT floored to 0 — refusing to emit an unprotected floor.');

    console.error(`[compute-min-bpt-poolerv2] minBPT floor  : ${minBPT} (${Number(minBPT) / 1e18} BPT)`);

    // STDOUT: the integer ONLY, so $(...) capture is clean.
    process.stdout.write(minBPT.toString());
}

main();
