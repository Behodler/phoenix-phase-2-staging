#!/usr/bin/env node
/**
 * update-mainnet-addresses-phlimbo-v2.js  (story 049)
 *
 * After broadcasting MigratePhlimboV1ToV2.s.sol, this script patches
 * `server/deployments/mainnet-addresses.ts` with the newly-deployed
 * PhlimboV2 and MigratorV1V2 addresses pulled from
 * `broadcast/MigratePhlimboV1ToV2.s.sol/1/run-latest.json`.
 *
 * Patches:
 *
 *   1. PhlimboV2     -- added as a new top-level field (no prior entry)
 *   2. MigratorV1V2  -- added as a new top-level field (no prior entry)
 *   3. PhlimboEA     -- renamed COMMENT to mark as deprecated (the address
 *                       itself is preserved for historical reference; the
 *                       contract is paused + drained so any reads against it
 *                       return zero balances). The TypeScript key is NOT
 *                       renamed because downstream consumers (UI, hooks) may
 *                       still reference it.
 *
 * The two new fields are added immediately AFTER the existing PhlimboEA
 * entry so the diff is small and reviewable.
 *
 * Exit codes:
 *   0 - Success
 *   1 - broadcast run-latest.json missing or unparseable
 *   2 - Expected contract not found in broadcast
 *   3 - Address collision / target file not in expected shape
 *   4 - target mainnet-addresses.ts missing
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const BROADCAST_FILE = path.join(
    ROOT, 'broadcast', 'MigratePhlimboV1ToV2.s.sol', '1', 'run-latest.json'
);
const ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');

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
 * MigratePhlimboV1ToV2 deploys exactly TWO contracts (PhlimboV2 then
 * MigratorV1V2 in script step 2 -> step 3 order). All other operations
 * are CALL transactions, not CREATEs.
 */
function matchDeploys(broadcast) {
    const creates = (broadcast.transactions || []).filter(
        (tx) => tx.transactionType === 'CREATE'
    );

    const expected = ['PhlimboV2', 'MigratorV1V2'];
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
        fail(2, `Broadcast has ${creates.length} CREATE transactions; expected exactly ${expected.length} (PhlimboV2 + MigratorV1V2)`);
    }

    return out;
}

function ensureNotPresent(source, fieldName) {
    const re = new RegExp(`^\\s*${fieldName}:\\s*"0x[0-9a-fA-F]{40}"`, 'm');
    return !re.test(source);
}

/**
 * Insert `newLines` (an array of strings, no trailing newline on each) into
 * `source` immediately AFTER the line matching `anchorRegex`. Returns the
 * mutated source or null if the anchor is not found.
 */
function insertAfterAnchor(source, anchorRegex, newLines) {
    const lines = source.split('\n');
    for (let i = 0; i < lines.length; i++) {
        if (anchorRegex.test(lines[i])) {
            lines.splice(i + 1, 0, ...newLines);
            return lines.join('\n');
        }
    }
    return null;
}

function refreshHeaderComment(source) {
    const today = new Date().toISOString().split('T')[0];
    const stampLine = `// Updated ${today}: PhlimboV2 + MigratorV1V2 deployed (story 049 - V1 stakers migrated)`;
    if (source.includes(stampLine)) return source;
    return source.replace(
        /(\/\/ Updated [^\n]*\n)(?=import)/,
        `$1${stampLine}\n`
    );
}

function run() {
    const broadcast = loadBroadcast();
    const { PhlimboV2: phlimboV2Addr, MigratorV1V2: migratorAddr } = matchDeploys(broadcast);

    if (!fs.existsSync(ADDRESSES_FILE)) {
        fail(4, `Target file not found: ${ADDRESSES_FILE}`);
    }
    let source = fs.readFileSync(ADDRESSES_FILE, 'utf8');
    const summary = [];

    // 1. PhlimboV2 -- must not already exist
    if (!ensureNotPresent(source, 'PhlimboV2')) {
        fail(3, 'PhlimboV2 entry already present in mainnet-addresses.ts -- aborting to avoid overwrite');
    }
    // 2. MigratorV1V2 -- must not already exist
    if (!ensureNotPresent(source, 'MigratorV1V2')) {
        fail(3, 'MigratorV1V2 entry already present in mainnet-addresses.ts -- aborting to avoid overwrite');
    }

    // Insert both new fields immediately AFTER the existing PhlimboEA line.
    // Mirror the indent of the surrounding fields (two spaces, key, colon,
    // value, trailing comma).
    const phlimboAnchor = /^\s*PhlimboEA:\s*"0x[0-9a-fA-F]{40}",/;
    const insertion = [
        `  // V2 of PhlimboEA -- deployed by story 049 MigratePhlimboV1ToV2.s.sol`,
        `  PhlimboV2: "${phlimboV2Addr}",`,
        `  // One-shot V1 -> V2 user migrator. Retired after broadcast; left here for audit.`,
        `  MigratorV1V2: "${migratorAddr}",`,
    ];
    const mutated = insertAfterAnchor(source, phlimboAnchor, insertion);
    if (mutated === null) {
        fail(3, 'PhlimboEA anchor line not found in mainnet-addresses.ts');
    }
    source = mutated;
    summary.push(`  PATCH    PhlimboV2                     <new>      -> ${phlimboV2Addr}`);
    summary.push(`  PATCH    MigratorV1V2                  <new>      -> ${migratorAddr}`);

    // Mark PhlimboEA as deprecated in a comment. We don't rename the key (UI
    // / hooks may still reference it). We just prepend a `// DEPRECATED ...`
    // comment line above it if not already present.
    const deprecatedMarker = '// DEPRECATED post-story-049 -- V1 paused + drained; positions migrated to PhlimboV2';
    if (!source.includes(deprecatedMarker)) {
        source = source.replace(
            /^(\s*)(PhlimboEA:\s*"0x[0-9a-fA-F]{40}",.*)$/m,
            `$1${deprecatedMarker}\n$1$2`
        );
        summary.push(`  COMMENT  PhlimboEA                     marked DEPRECATED`);
    } else {
        summary.push(`  SKIP     PhlimboEA                     deprecated marker already present`);
    }

    source = refreshHeaderComment(source);

    console.log('===========================================');
    console.log('  update-mainnet-addresses-phlimbo-v2');
    console.log('===========================================');
    summary.forEach((line) => console.log(line));
    console.log('===========================================');

    fs.writeFileSync(ADDRESSES_FILE, source, 'utf8');
    console.log(`  File written: ${ADDRESSES_FILE}`);
    console.log('');
    console.log('NEXT STEPS (manual):');
    console.log('  1. Update addresses.ts ContractAddresses interface to include');
    console.log('     PhlimboV2 and MigratorV1V2 fields (and remove old fields if you');
    console.log('     choose to fully retire PhlimboEA from the typed surface).');
    console.log('  2. Regenerate Wagmi hooks: `npm run generate:hooks`.');
    console.log('  3. Publish hooks: `npm run update:hooks`.');
    console.log('  4. Verify each V1 staker\'s V2 userInfo(addr).amount matches their V1 amount');
    console.log('     and that USDC + phUSD reward landings are visible in their wallets.');
}

run();
