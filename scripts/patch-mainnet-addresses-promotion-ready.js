#!/usr/bin/env node
/**
 * patch-mainnet-addresses-promotion-ready.js  (story 072)
 *
 * Rewrites `server/deployments/mainnet-addresses.ts` from the promotion-ready
 * cutover's progress file, BY NAME (never positionally off broadcast CREATEs).
 *
 * MANDATORY TAIL. This script is the final element of the `promotion-ready:broadcast`
 * npm chain and of every `:resume` leg, joined with `&&` — never `;`. The broadcast is
 * not complete until `mainnet-addresses.ts` reflects the new lineup, and patching from a
 * failed or partial broadcast would write addresses for contracts that may not exist.
 * `&&` guarantees it runs only on a zero exit from `forge script`. It is preceded in the
 * chain by `node scripts/backup-mainnet-addresses.js` so the pre-cutover file is
 * recoverable if this patch is wrong.
 *
 * WHY BY NAME. Story 071's hard lesson: the Foundry progress file is written during
 * forge's LOCAL execution pass, BEFORE broadcasting, so after a crash it can name a
 * contract that was never deployed. The `deploymentStatus == "completed"` gate below is
 * therefore necessary but not sufficient — on a resumed run the executor must first trim
 * the progress file to the on-chain-confirmed steps (source of truth: the broadcast
 * `run-latest.json` receipts + `cast nonce`). This script only ever consumes that
 * trimmed, completed file.
 *
 * WHAT IT TOUCHES
 *   FILL (update:false — overwrite ONLY a zero-address placeholder, abort on any other
 *   value): `NudgeStreamer` and `Kendu`. Both were added as zero placeholders by story
 *   073 so the hand-maintained key-set matched the regenerated `ContractAddresses`
 *   interface; this story is the one that fills them.
 *
 *   REPOINT (update:true — overwrite whatever is there): every key whose live contract is
 *   replaced or re-verified by the cutover.
 *
 *   The five mint-debt hooks are in the REPOINT list even though this cutover REPOINTS
 *   rather than redeploys them (`hook.setDispatcher(new)`), so their addresses are
 *   unchanged. Writing them back from the progress file makes the round trip explicit:
 *   if the Foundry script recorded a different hook address than the file already holds,
 *   something is wrong and the diff will show it, instead of the key being silently
 *   skipped.
 *
 * WHAT IT NEVER DOES
 *   Add or remove a key. `mainnet-addresses.ts` is hand-maintained and never regenerated;
 *   its key-set must exactly equal the `ContractAddresses` interface in `addresses.ts`
 *   (currently 57 == 57), which is the `tsc --strict` drift guard. That equality is
 *   re-checked below AFTER patching, and a mismatch is a non-zero exit.
 *
 *   The three `NFTStakerMigrator` instances are transient orchestrators and deliberately
 *   have no interface key, so they are absent from FIELDS by design.
 *
 * KENDU IS TOLERATED-MISSING, NOT CONDITIONAL IN PRACTICE. The Foundry script records a
 * `Kendu` progress entry whenever `isNudgeToken(KENDU)` reads true after Phase 2, and
 * Phase 2 whitelists Kendu UNCONDITIONALLY. The fee-on-transfer preflight lives in Phase 8,
 * which runs only under PREVIEW_MODE, so in a broadcast run it never executes: the tax gate
 * is PROCEDURAL — the operator runs `promotion-ready:dry` first and the probe's `require`
 * aborts there — not structural. `optional: true` below is therefore a defensive fallback
 * for the case where the whitelist call did not land (which would also fail Phase 2's
 * `getNudgeTokens().length == 3` require), not the expected negative outcome. If it ever
 * does fire, the correct state is the same: Kendu unwhitelisted, no stream registered, key
 * left as a zero placeholder. Every other key is mandatory.
 *
 * Exit codes:
 *   0 - Success
 *   1 - mainnet-addresses.ts missing
 *   2 - progress file missing / unparseable / deploymentStatus != "completed"
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - a source address is missing/zero, a target field is absent, or a collision
 *       (non-zero existing value under update:false)
 */

const fs = require('fs');
const path = require('path');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.promotion-ready.1.json');
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

// tsField (mainnet-addresses.ts key) -> progress-file contract key.
//   update:false -> fill a zero placeholder only; a non-zero existing value is a collision.
//   update:true  -> overwrite the live value.
//   optional:true -> a missing progress entry is tolerated (Kendu only; defensive, see header).
const FIELDS = [
    // ---- FILL: zero placeholders added by story 073 ----
    { tsField: 'NudgeStreamer', progressKey: 'NudgeStreamer', update: false },
    { tsField: 'Kendu', progressKey: 'Kendu', update: false, optional: true },

    // ---- REPOINT: contracts redeployed by this cutover ----
    { tsField: 'BatchNFTMinter', progressKey: 'BatchNFTMinter', update: true }, // now a BatchNFTMinterMultiToken
    { tsField: 'BalancerPooler', progressKey: 'BalancerPooler', update: true },
    { tsField: 'UniboostEYE', progressKey: 'UniboostEYE', update: true },
    { tsField: 'UniboostSCX', progressKey: 'UniboostSCX', update: true },
    { tsField: 'UniboostFLX', progressKey: 'UniboostFLX', update: true },
    { tsField: 'NudgeRatchet', progressKey: 'NudgeRatchet', update: true }, // was the DelayRelease stopgap
    { tsField: 'StableYieldAccumulator', progressKey: 'StableYieldAccumulator', update: true },
    { tsField: 'UniboostStakerEYE', progressKey: 'UniboostStakerEYE', update: true }, // now NFTStakerDepletionV2
    { tsField: 'UniboostStakerSCX', progressKey: 'UniboostStakerSCX', update: true },
    { tsField: 'UniboostStakerFLX', progressKey: 'UniboostStakerFLX', update: true },

    // ---- REPOINT (address UNCHANGED): the five repointed mint-debt hooks ----
    { tsField: 'UniboostHookEYE', progressKey: 'UniboostHookEYE', update: true },
    { tsField: 'UniboostHookSCX', progressKey: 'UniboostHookSCX', update: true },
    { tsField: 'UniboostHookFLX', progressKey: 'UniboostHookFLX', update: true },
    { tsField: 'BalancerPoolerMintDebtHook', progressKey: 'BalancerPoolerMintDebtHook', update: true },
    { tsField: 'NudgeRatchetMintDebtHook', progressKey: 'NudgeRatchetMintDebtHook', update: true },
];

const HEADER_MARKER = 'promotion-ready cutover';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function loadProgress() {
    if (!fs.existsSync(PROGRESS_FILE)) fail(2, `Progress file not found: ${PROGRESS_FILE}`);
    let p;
    try {
        p = JSON.parse(fs.readFileSync(PROGRESS_FILE, 'utf8'));
    } catch (e) {
        fail(2, `Progress unparseable: ${e.message}`);
    }
    if (p.deploymentStatus !== 'completed') {
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (broadcast not finished, or a resume leg is still outstanding)`);
    }
    if (!p.contracts || typeof p.contracts !== 'object') fail(2, 'Progress file has no "contracts" object');
    return p;
}

/**
 * Replace the address literal for `field`. Returns {newSource, currentAddress, replaced}.
 * `replaced:false` with a non-zero `currentAddress` under update:false is a collision;
 * `replaced:false` with a null `currentAddress` means the key is absent from the file.
 */
function patchFlatField(source, field, newAddress, update) {
    const re = new RegExp(`^(\\s*${field}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) return { newSource: source, currentAddress: null, replaced: false };
    const currentAddress = match[2];
    // Strip the stale "PLACEHOLDER" / "not yet deployed" trailing comments left by the
    // story-073 placeholders, so the file does not keep claiming a filled key is empty.
    const cleanTrailing = match[3]
        .replace(/\s*\/\/\s*not yet deployed.*/i, ',')
        .replace(/\s*\/\/\s*placeholder.*/i, ',')
        .replace(/\s*\/\/\s*PLACEHOLDER:.*/, ',');
    // update:false is FILL-ONCE. A non-zero existing value is a collision — UNLESS it is
    // already exactly the address we were going to write, which is what a `:resume` leg
    // re-running this patch looks like. Treating that as success is what makes the patch
    // idempotent across resume legs without weakening the fill-once guarantee.
    if (!update && currentAddress.toLowerCase() !== ZERO_ADDRESS && currentAddress.toLowerCase() !== newAddress.toLowerCase()) {
        return { newSource: source, currentAddress, replaced: false };
    }
    return {
        newSource: source.replace(re, `$1"${newAddress}"${cleanTrailing}`),
        currentAddress,
        replaced: true,
    };
}

/** Keys declared in the ContractAddresses interface (addresses.ts). */
function interfaceKeys() {
    if (!fs.existsSync(INTERFACE_FILE)) fail(3, `Interface file not found: ${INTERFACE_FILE}`);
    const src = fs.readFileSync(INTERFACE_FILE, 'utf8');
    const body = src.slice(src.indexOf('{'), src.lastIndexOf('}'));
    return [...body.matchAll(/^\s*([A-Za-z0-9_]+)\s*:\s*string\s*;/gm)].map((m) => m[1]);
}

/**
 * Keys assigned in mainnet-addresses.ts. Block comments are stripped first: the three
 * BurnerEYE / BurnerSCX / BurnerFlax entries live inside a commented-out block and must
 * NOT be counted (story 070 dropped them from the interface).
 */
function dataKeys(source) {
    const body = source.slice(source.indexOf('mainnetAddresses: ContractAddresses = {'));
    const withoutBlockComments = body.replace(/\/\*[\s\S]*?\*\//g, '');
    const withoutLineComments = withoutBlockComments.replace(/^\s*\/\/.*$/gm, '');
    return [...withoutLineComments.matchAll(/^\s*([A-Za-z0-9_]+)\s*:\s*"0x[0-9a-fA-F]{40}"/gm)].map((m) => m[1]);
}

function run() {
    const progress = loadProgress();
    if (!fs.existsSync(ADDRESSES_FILE)) fail(1, `Target file not found: ${ADDRESSES_FILE}`);
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');

    const summary = [];
    let bad = false;

    for (const f of FIELDS) {
        const entry = progress.contracts[f.progressKey];
        const missing = !entry || !entry.address || entry.address.toLowerCase() === ZERO_ADDRESS;

        if (missing && f.optional) {
            summary.push(`  SKIP-OPT ${f.tsField.padEnd(26)} no progress entry — left as-is (token not whitelisted; unexpected in a normal run, see header)`);
            continue;
        }
        if (missing) {
            summary.push(`  MISS-SRC ${f.tsField.padEnd(26)} progress key "${f.progressKey}" missing or zero`);
            bad = true;
            continue;
        }

        const result = patchFlatField(source, f.tsField, entry.address, f.update);
        if (result.replaced) {
            source = result.newSource;
            const unchanged = result.currentAddress.toLowerCase() === entry.address.toLowerCase();
            const verb = f.update ? (unchanged ? 'SAME  ' : 'UPDATE') : 'FILL  ';
            summary.push(`  ${verb} ${f.tsField.padEnd(26)} <- ${entry.address}`);
        } else if (result.currentAddress && result.currentAddress.toLowerCase() !== ZERO_ADDRESS) {
            summary.push(`  COLLIDE  ${f.tsField.padEnd(26)} already=${result.currentAddress}, wanted=${entry.address}`);
            bad = true;
        } else {
            summary.push(`  MISS-DST ${f.tsField.padEnd(26)} key not found in mainnet-addresses.ts`);
            bad = true;
        }
    }

    // Strip the story-073 PLACEHOLDER comment blocks now that the two keys are filled — a
    // stale "not yet deployed" note on a live address is exactly the prose drift this story
    // exists to stop. Only comment lines that mention PLACEHOLDER are removed, and only the
    // contiguous block immediately preceding a key this run filled.
    for (const key of ['NudgeStreamer', 'Kendu']) {
        const re = new RegExp(`((?:^[ \\t]*//[^\\n]*\\n)+)(?=[ \\t]*${key}:)`, 'm');
        const m = source.match(re);
        if (m && /placeholder/i.test(m[1])) {
            source = source.replace(re, '');
        }
    }

    // Datestamped provenance header (idempotent — added once). Anchored on the import line
    // rather than on a trailing "// Updated" line: the existing header block wraps across
    // several continuation lines, so only the import is a reliable anchor.
    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} (story 072) — NudgeStreamer deployed; shared BatchNFTMinter\n` +
                `// replaced by BatchNFTMinterMultiToken (USDC/phUSD/Kendu); all four donors redeployed\n` +
                `// (BalancerPoolerV2 idx 4, Uniboost x3 idx 1/2/3, NudgeRatchet idx 7); StableYieldAccumulator\n` +
                `// replaced; the three depletion stakers migrated to NFTStakerDepletionV2. The five mint-debt\n` +
                `// hooks were REPOINTED, not redeployed — their addresses are unchanged. Patched from\n` +
                `// progress.promotion-ready.1.json by name.\n`
        );
    }

    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-promotion-ready (story 072)');
    console.log('==========================================================');
    summary.forEach((l) => console.log(l));
    console.log('==========================================================');

    if (bad) fail(4, 'One or more fields could not be safely patched (see summary above)');

    // Key-set drift guard: the hand-maintained data file must still declare exactly the
    // interface's keys — no more, no fewer. This is the same invariant `tsc --strict`
    // enforces; checking it here means a bad patch fails the broadcast chain immediately
    // rather than at the next type-check.
    const iface = interfaceKeys();
    const data = dataKeys(source);
    const missingInData = iface.filter((k) => !data.includes(k));
    const extraInData = data.filter((k) => !iface.includes(k));
    console.log(`  key-set: interface=${iface.length}  data=${data.length}`);
    if (missingInData.length || extraInData.length) {
        if (missingInData.length) console.error(`  missing from mainnet-addresses.ts: ${missingInData.join(', ')}`);
        if (extraInData.length) console.error(`  not in ContractAddresses:           ${extraInData.join(', ')}`);
        fail(3, 'key-set drift — mainnet-addresses.ts no longer matches the ContractAddresses interface');
    }

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
}

run();
