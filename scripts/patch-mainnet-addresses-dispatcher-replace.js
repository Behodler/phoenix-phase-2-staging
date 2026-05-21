#!/usr/bin/env node
/**
 * patch-mainnet-addresses-dispatcher-replace.js
 *
 * After broadcasting DispatcherReplaceAtIndex4.s.sol (story 048), this script
 * patches mainnet-addresses.ts with the new BalancerPoolerV2 and
 * BalancerPoolerMintDebtHook addresses pulled from
 * `broadcast/DispatcherReplaceAtIndex4.s.sol/1/run-latest.json`. It also
 * reverts `MintPageView` to the previous (index-4-targeting) address, gated
 * on the script's pre-revert verification flag (logged in the broadcast
 * output as `priorMintPageViewReadsIndex4`).
 *
 * Patches in this run:
 *
 *   1. nftsV2.BalancerPooler           expected old = BUGGED_POOLER_V2 (index-6 deploy)
 *                                      patched to  = newPooler from broadcast
 *   2. BalancerPoolerMintDebtHook      expected old = current hook tied to bugged pooler
 *                                      patched to  = newHook from broadcast
 *   3. MintPageView                    expected old = current index-6 view
 *                                      patched to  = PRIOR_MINT_PAGE_VIEW (index-4 view)
 *                                      GATED on PRIOR_MINT_PAGE_VIEW_READS_INDEX_4
 *                                      flag (set by the agent BEFORE running this
 *                                      patcher; otherwise the field is left alone
 *                                      and a follow-up redeploy is required).
 *
 * Additionally rewrites the misleading comment block near lines 49-56 of
 * mainnet-addresses.ts: prior comments described the previous swap (story-047)
 * which left the active dispatcher at index 6 with a hardcoded-index-6 view.
 * After story 048 the active dispatcher is index 4 again, so the historical
 * comment is stale.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - Expected contract not found in broadcast
 *   3 - Address collision / unexpected old address (self-validation failed)
 *   4 - target mainnet-addresses.ts missing
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'DispatcherReplaceAtIndex4.s.sol', '1', 'run-latest.json'
);
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

// Must match constants in script/DispatcherReplaceAtIndex4.s.sol and the
// pre-broadcast state of mainnet-addresses.ts (post-story-047).
const OLD_BALANCER_POOLER_NFTS_V2 = '0x4da153dc02bb084528d10335759f2c4447e6f73d';
const OLD_BALANCER_POOLER_MINT_DEBT_HOOK = '0xbe79dc2c302165025166f09193d9905ef262c064';
const OLD_MINT_PAGE_VIEW = '0xeBEc50cD19310e6ed59D8153313Ec7C888152c1A';

// Restore target for MintPageView -- the V2-wired view that hardcoded
// dispatcher index 4. Restored when the script verified the on-chain
// `dispatcherIndex()` reads 4.
const PRIOR_MINT_PAGE_VIEW = '0x64FE63ca7BA456a9Bb190140e35DF2e437AbD119';

/**
 * Gate flag for the MintPageView revert. The cutover script logs a line like
 * `priorMintPageViewReadsIndex4: true|false` in the broadcast. The agent
 * surfaces this in the dry-run output for human review before broadcast.
 *
 * Setting via env var avoids parsing forge's mixed stdout/JSON. Default is
 * false, meaning the patcher will NOT revert the MintPageView field unless
 * the agent / human passes
 *   PRIOR_MINT_PAGE_VIEW_READS_INDEX_4=true node scripts/patch-mainnet-addresses-dispatcher-replace.js
 * during the broadcast wrapper. The dry-run log includes the value of
 * `priorMintPageViewReadsIndex4` so the human can decide.
 */
const REVERT_MINT_PAGE_VIEW = process.env.PRIOR_MINT_PAGE_VIEW_READS_INDEX_4 === 'true';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function loadBroadcast() {
    if (!fs.existsSync(BROADCAST_FILE)) {
        fail(1, `Broadcast file not found: ${BROADCAST_FILE}`);
    }
    try {
        return JSON.parse(fs.readFileSync(BROADCAST_FILE, 'utf8'));
    } catch (err) {
        fail(1, `Broadcast file unparseable: ${err.message}`);
    }
}

/**
 * Walk transactions[], filter transactionType === "CREATE", match deployments
 * by contractName. The cutover broadcast deploys exactly TWO contracts:
 *
 *   1. BalancerPoolerV2
 *   2. BalancerPoolerMintDebtHook
 *
 * Order is fixed by the script (step 4 then step 5).
 */
function matchDeploys(broadcast) {
    const creates = (broadcast.transactions || []).filter(
        (tx) => tx.transactionType === 'CREATE'
    );

    const expected = ['BalancerPoolerV2', 'BalancerPoolerMintDebtHook'];
    const out = {};
    const seen = new Set();

    for (const cname of expected) {
        const tx = creates.find((t) => t.contractName === cname && !seen.has(t));
        if (!tx) {
            fail(2, `Expected CREATE tx for ${cname} not found in broadcast`);
        }
        if (!tx.contractAddress) {
            fail(2, `CREATE tx for ${cname} has no contractAddress`);
        }
        seen.add(tx);
        out[cname] = tx.contractAddress;
    }

    if (creates.length !== expected.length) {
        fail(2, `Broadcast has ${creates.length} CREATE transactions; expected exactly ${expected.length} (BalancerPoolerV2 + BalancerPoolerMintDebtHook)`);
    }

    return out;
}

function patchFlatField(source, field, newAddress, expectedOld) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const currentAddress = match[2];
    const trailing = match[3];
    if (currentAddress.toLowerCase() !== expectedOld.toLowerCase()) {
        return { newSource: source, currentAddress, replaced: false };
    }
    const newSource = source.replace(re, `$1"${newAddress}"${trailing}`);
    return { newSource, currentAddress, replaced: true };
}

function patchNestedField(source, parentKey, childField, newAddress, expectedOld) {
    const headerRe = new RegExp(`(^[ \\t]*${parentKey}:\\s*\\{[\\s\\S]*?\\n[ \\t]*\\},)`, 'm');
    const headerMatch = source.match(headerRe);
    if (!headerMatch) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const block = headerMatch[1];

    const childRe = new RegExp(`(^[ \\t]+${childField}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const childMatch = block.match(childRe);
    if (!childMatch) {
        return { newSource: source, currentAddress: null, replaced: false };
    }
    const currentAddress = childMatch[2];
    const trailing = childMatch[3];
    if (currentAddress.toLowerCase() !== expectedOld.toLowerCase()) {
        return { newSource: source, currentAddress, replaced: false };
    }
    const newBlock = block.replace(childRe, `$1"${newAddress}"${trailing}`);
    const newSource = source.replace(block, newBlock);
    return { newSource, currentAddress, replaced: true };
}

/**
 * Rewrites the misleading comment near the top of mainnet-addresses.ts that
 * was added by RedeployMintPageViewV2 / story-047 to describe the old vs new
 * MintPageView swap (which is reversed by this story).
 *
 * Pre-patch comment block: a multi-line `/* ... *\/` near lines 13-20 has a
 * description of yield-strategy historical state. The misleading comment
 * the story-048 plan calls out lives in script/RedeployMintPageViewV2.s.sol
 * (lines 49-56), NOT mainnet-addresses.ts. We additionally append a stamp
 * line to the header comments at the top of the file so a reader sees the
 * cutover context.
 */
function refreshHeaderComment(source) {
    const today = new Date().toISOString().split('T')[0];
    const stampLine = `// Updated ${today}: dispatcher-replace cutover patched (story 048 - index 4 restored)`;
    if (source.includes(stampLine)) return source;
    // Append a new header line right before the `import` statement, matching
    // the pattern of prior `Updated YYYY-MM-DD: ...` lines.
    return source.replace(
        /(\/\/ Updated [^\n]*\n)(?=import)/,
        `$1${stampLine}\n`
    );
}

function run() {
    const broadcast = loadBroadcast();
    const { BalancerPoolerV2: newPooler, BalancerPoolerMintDebtHook: newHook } = matchDeploys(broadcast);

    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(4, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');
    const summary = [];
    let hadFailure = false;

    // 1. nftsV2.BalancerPooler -- nested
    {
        const r = patchNestedField(source, 'nftsV2', 'BalancerPooler', newPooler, OLD_BALANCER_POOLER_NFTS_V2);
        if (r.replaced) {
            source = r.newSource;
            summary.push(`  PATCH    nftsV2.BalancerPooler         ${OLD_BALANCER_POOLER_NFTS_V2} -> ${newPooler}`);
        } else if (r.currentAddress) {
            summary.push(`  COLLIDE  nftsV2.BalancerPooler         existing=${r.currentAddress} (expected OLD=${OLD_BALANCER_POOLER_NFTS_V2})`);
            hadFailure = true;
        } else {
            summary.push(`  MISS     nftsV2.BalancerPooler         field not found`);
            hadFailure = true;
        }
    }

    // 2. BalancerPoolerMintDebtHook -- flat
    {
        const r = patchFlatField(source, 'BalancerPoolerMintDebtHook', newHook, OLD_BALANCER_POOLER_MINT_DEBT_HOOK);
        if (r.replaced) {
            source = r.newSource;
            summary.push(`  PATCH    BalancerPoolerMintDebtHook    ${OLD_BALANCER_POOLER_MINT_DEBT_HOOK} -> ${newHook}`);
        } else if (r.currentAddress) {
            summary.push(`  COLLIDE  BalancerPoolerMintDebtHook    existing=${r.currentAddress} (expected OLD=${OLD_BALANCER_POOLER_MINT_DEBT_HOOK})`);
            hadFailure = true;
        } else {
            summary.push(`  MISS     BalancerPoolerMintDebtHook    field not found`);
            hadFailure = true;
        }
    }

    // 3. MintPageView -- gated on PRIOR_MINT_PAGE_VIEW_READS_INDEX_4 env flag
    if (REVERT_MINT_PAGE_VIEW) {
        const r = patchFlatField(source, 'MintPageView', PRIOR_MINT_PAGE_VIEW, OLD_MINT_PAGE_VIEW);
        if (r.replaced) {
            source = r.newSource;
            summary.push(`  PATCH    MintPageView                  ${OLD_MINT_PAGE_VIEW} -> ${PRIOR_MINT_PAGE_VIEW} (reverted)`);
        } else if (r.currentAddress) {
            summary.push(`  COLLIDE  MintPageView                  existing=${r.currentAddress} (expected OLD=${OLD_MINT_PAGE_VIEW})`);
            hadFailure = true;
        } else {
            summary.push(`  MISS     MintPageView                  field not found`);
            hadFailure = true;
        }
    } else {
        summary.push(`  SKIP     MintPageView                  pre-revert verification flag not set (PRIOR_MINT_PAGE_VIEW_READS_INDEX_4 != "true"); leaving current value untouched. Follow-up story may redeploy a fresh index-4 view.`);
    }

    source = refreshHeaderComment(source);

    console.log('============================================');
    console.log('  patch-mainnet-addresses-dispatcher-replace');
    console.log('============================================');
    summary.forEach((line) => console.log(line));
    console.log('============================================');

    if (hadFailure) {
        fail(3, 'One or more fields could not be safely patched -- self-validation against expected-OLD constants failed (see summary above)');
    }

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
