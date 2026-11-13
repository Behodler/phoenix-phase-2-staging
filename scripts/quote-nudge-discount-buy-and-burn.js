#!/usr/bin/env node
/**
 * quote-nudge-discount-buy-and-burn.js  (story 119, sprint nudge-discount; modelled on quote-unipooler-pool.js)
 *
 * Computes the slippage floor for `BatchNFTMinterNudgeDiscount.buyAndBurn(usdcIn, minPhusdOut, deadline)` on the live
 * nudge-discount minter (script/NudgeDiscountBuyAndBurn.s.sol, npm `nudge-discount:buy-and-burn:*`) and prints it as
 * env-var assignments:
 *
 *     eval "$(node scripts/quote-nudge-discount-buy-and-burn.js all 50)"
 *     # -> export USDC_IN_WEI=...   export MIN_PHUSD_OUT_WEI=...
 *
 * Re-quote IMMEDIATELY before :preview and :broadcast, in the SAME shell, so both use identical floors. A trade on the
 * pair between quoting and broadcasting can push the live quote below the floor; the simulation then reverts and you
 * re-quote.
 *
 * WHAT IT QUOTES. The pinned contract (nft-staking d7eb782) has no quote view, so this is the route quote, via
 * `cast call` (eth_call), read from the minter's own configured route:
 *     usds   = usdcIn * psm.to18ConversionFactor() - (usdcIn * conv) * psm.tin() / 1e18   (PSM sellGem)
 *     shares = sUSDS.previewDeposit(usds)
 *     out    = router.getAmountsOut(shares, [sUSDS, phUSD])[1]
 *     MIN_PHUSD_OUT_WEI = out * (10000 - TOLERANCE_BPS) / 10000                             (BigInt floor)
 * The same maths runs on-chain in NudgeDiscountMainnetBase._quoteRoute, and the forge script requires the floor to lie
 * in [quote * 0.99, quote].
 *
 * WHICH MINTER. `NudgeDiscountBatchMinter` from server/deployments/mainnet-addresses.ts (patched by the cutover). While
 * it is still the zero placeholder the helper refuses BEFORE touching the RPC (the expected result before the human's
 * cutover broadcast).
 *
 * USAGE
 *   node scripts/quote-nudge-discount-buy-and-burn.js <USDC_IN_WEI|all> [TOLERANCE_BPS] [--address-book <path>]
 *     USDC_IN_WEI    USDC (6dp) to spend, or `all` for the minter's whole pendingBuyUSDC. Must not exceed it.
 *     TOLERANCE_BPS  integer 1..100 (default 50). Capped at 100 = NudgeDiscountBuyAndBurn.s.sol's MAX_TOLERANCE_BPS.
 *     --address-book REHEARSAL ONLY: read the minter from another copy of the book (a fork rehearsal against a
 *                    fork-deployed minter). Production runs never pass it.
 *   Env: RPC_MAINNET (or MAINNET_RPC_URL) required.
 *
 * STDOUT carries ONLY the two `export` lines. Diagnostics go to STDERR. On any failure (zero book entry, RPC, cast
 * missing, a zero quote) it prints NOTHING to STDOUT and exits non-zero.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const DEFAULT_BOOK = path.join(__dirname, '..', 'server', 'deployments', 'mainnet-addresses.ts');
const ZERO = '0x0000000000000000000000000000000000000000';
const WAD = 10n ** 18n;
const DEFAULT_TOLERANCE_BPS = 50n;
const MAX_TOLERANCE_BPS = 100n; // NudgeDiscountBuyAndBurn.s.sol MAX_TOLERANCE_BPS

const TAG = '[quote-nudge-discount-buy-and-burn]';

function fail(msg, code = 1) {
    console.error(`${TAG} ERROR: ${msg}`);
    process.exit(code);
}

function log(msg) {
    console.error(`${TAG} ${msg}`);
}

function bookAddress(bookPath, key) {
    let src;
    try {
        src = fs.readFileSync(bookPath, 'utf8');
    } catch (e) {
        fail(`cannot read ${bookPath}: ${e.message}`);
    }
    const m = src.match(new RegExp(`\\n  ${key}: "(0x[0-9a-fA-F]{40})"`));
    if (!m) fail(`key ${key} not found in ${path.basename(bookPath)}`);
    return m[1];
}

function cast(rpc, args) {
    const res = spawnSync('cast', [...args, '--rpc-url', rpc], { encoding: 'utf8', env: process.env });
    if (res.error) fail(`failed to spawn 'cast' (is Foundry installed?): ${res.error.message}`);
    // Never echo the RPC URL: report only the call.
    if (res.status !== 0) fail(`cast ${args.slice(0, 3).join(' ')} failed:\n${(res.stderr || res.stdout || '').trim()}`);
    return (res.stdout || '').trim();
}

function first(s) {
    return s.split(/\s+/)[0];
}

function uintCall(rpc, target, sig, ...a) {
    return BigInt(first(cast(rpc, ['call', target, sig, ...a])));
}

function addrCall(rpc, target, sig) {
    return first(cast(rpc, ['call', target, sig]));
}

function parseArgs(argv) {
    const pos = [];
    let book = DEFAULT_BOOK;
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === '--address-book') {
            if (!argv[i + 1]) fail('--address-book needs a path');
            book = path.resolve(argv[++i]);
        } else pos.push(argv[i]);
    }
    if (pos.length < 1 || pos.length > 2) {
        fail('usage: quote-nudge-discount-buy-and-burn.js <USDC_IN_WEI|all> [TOLERANCE_BPS] [--address-book <path>]');
    }
    const amount = pos[0];
    if (amount !== 'all' && !/^[0-9]+$/.test(amount)) fail(`USDC_IN_WEI must be an integer (6dp) or "all", got "${amount}"`);
    if (amount !== 'all' && BigInt(amount) === 0n) fail('USDC_IN_WEI must be non-zero');
    let tol = DEFAULT_TOLERANCE_BPS;
    if (pos.length === 2) {
        if (!/^[0-9]+$/.test(pos[1])) fail(`TOLERANCE_BPS must be an integer, got "${pos[1]}"`);
        tol = BigInt(pos[1]);
        if (tol < 1n || tol > MAX_TOLERANCE_BPS) fail(`TOLERANCE_BPS out of range (1..${MAX_TOLERANCE_BPS}): ${tol}`);
    }
    return { amount, tol, book };
}

function main() {
    const { amount, tol, book } = parseArgs(process.argv.slice(2));

    const minter = bookAddress(book, 'NudgeDiscountBatchMinter');
    if (minter.toLowerCase() === ZERO) {
        fail(
            'NudgeDiscountBatchMinter in mainnet-addresses.ts is the zero placeholder - the cutover ' +
                '(npm run nudge-discount:broadcast) has not been run/patched yet. Nothing to quote.'
        );
    }

    const rpc = process.env.RPC_MAINNET || process.env.MAINNET_RPC_URL;
    if (!rpc) fail('RPC_MAINNET (or MAINNET_RPC_URL) is not set');
    const chainId = cast(rpc, ['chain-id']);
    if (chainId !== '1') fail(`RPC chain id is ${chainId}, expected 1 (mainnet)`);

    const reserve = uintCall(rpc, minter, 'pendingBuyUSDC()(uint256)');
    const usdcIn = amount === 'all' ? reserve : BigInt(amount);
    if (usdcIn === 0n) fail('pendingBuyUSDC is 0 - nothing reserved to buy with');
    if (usdcIn > reserve) fail(`USDC_IN_WEI ${usdcIn} exceeds pendingBuyUSDC ${reserve}`);

    const psm = addrCall(rpc, minter, 'psm()(address)');
    const sUSDS = addrCall(rpc, minter, 'sUSDS()(address)');
    const router = addrCall(rpc, minter, 'router()(address)');
    const phUSD = addrCall(rpc, minter, 'phUSD()(address)');
    const block = cast(rpc, ['block-number']);

    const conv = uintCall(rpc, psm, 'to18ConversionFactor()(uint256)');
    const tin = uintCall(rpc, psm, 'tin()(uint256)');
    const gross = usdcIn * conv;
    const usds = gross - (gross * tin) / WAD;
    const shares = uintCall(rpc, sUSDS, 'previewDeposit(uint256)(uint256)', usds.toString());
    const amountsRaw = cast(rpc, [
        'call',
        router,
        'getAmountsOut(uint256,address[])(uint256[])',
        shares.toString(),
        `[${sUSDS},${phUSD}]`,
    ]);
    const amounts = (amountsRaw.match(/\d+(?:\s*\[[^\]]*\])?/g) || []).map((x) => BigInt(x.split(/\s/)[0]));
    if (amounts.length !== 2) fail(`getAmountsOut returned ${amounts.length} values, expected 2: ${amountsRaw}`);
    const phusdOut = amounts[1];
    if (phusdOut === 0n) fail('route quote is zero');

    const minOut = (phusdOut * (10000n - tol)) / 10000n;
    if (minOut === 0n) fail('the floor rounded to 0 - refusing to emit an unprotected floor');

    log(`block               : ${block}`);
    log(`minter              : ${minter}`);
    log(`pendingBuyUSDC      : ${reserve} (~${Number(reserve) / 1e6} USDC)`);
    log(`pendingStakerPhUSD  : ${uintCall(rpc, minter, 'pendingStakerPhUSD()(uint256)')}`);
    log(`USDC_IN_WEI         : ${usdcIn} (~${Number(usdcIn) / 1e6} USDC)`);
    log(`PSM tin / conv      : ${tin} / ${conv}`);
    log(`USDS from PSM       : ${usds}`);
    log(`sUSDS shares        : ${shares}`);
    log(`quote phusdOut      : ${phusdOut} (~${Number(phusdOut) / 1e18} phUSD)`);
    log(`tolerance (bps)     : ${tol}`);
    log(`MIN_PHUSD_OUT_WEI   : ${minOut}`);

    process.stdout.write(`export USDC_IN_WEI=${usdcIn}\nexport MIN_PHUSD_OUT_WEI=${minOut}\n`);
}

main();
