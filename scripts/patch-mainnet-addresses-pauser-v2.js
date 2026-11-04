#!/usr/bin/env node
/**
 * patch-mainnet-addresses-pauser-v2.js  (story 128, sprint global-pauser-v2)
 *
 * REPOINTS the `Pauser` key of `server/deployments/mainnet-addresses.ts` from the retired V1 Pauser
 * 0x7c5A8EeF1d836450C019FB036453ac6eC97885a3 to the PauserV2 deployed by script/DeployPauserV2Mainnet.s.sol.
 *
 * CHAINED at the end of `pauser-v2-migrate:broadcast`, after the forge run and before `npm run pauser-v2-verify`
 * (audit 49 L-04: every other mainnet broadcast patches its own book). The book must keep naming V1 until every
 * live registrant has been rotated, so it refuses (exit 5) unless PauserV2 on-chain shows the finished state:
 * at least one registrant and the burn restored to 1000e18, which the migration does last. It can also be run by
 * hand, with the same gate (runbook docs/runbooks/pauser-v2-migration.md).
 *
 * SOURCE OF THE ADDRESS
 *   The deploy broadcast's receipts: broadcast/DeployPauserV2Mainnet.s.sol/1/run-latest.json - the CREATE of
 *   contractName "PauserV2", with a successful receipt. Cross-checked against
 *   server/deployments/progress.pauser-v2.1.json (written by the same run's local pass) when that file exists;
 *   any disagreement refuses.
 *
 * WHAT IT TOUCHES
 *   1. Backs up mainnet-addresses.ts first (scripts/backup-mainnet-addresses.js).
 *   2. Guarded REPOINT of `Pauser`: overwrite ONLY when the current value is EXACTLY the V1 Pauser; the SAME new
 *      address already present is success (idempotent re-run); ANY other value is a COLLIDE and nothing is written.
 *   3. Leaves a comment above the key recording the retired V1 address, and a dated header line.
 *
 * WHAT IT NEVER DOES
 *   Add or remove a key. The data file's key-set must exactly equal the ContractAddresses interface in
 *   addresses.ts (the tsc --strict drift guard); re-checked after patching, before writing.
 *
 * OPTIONS (for proving the patcher on scratch copies; production runs with none)
 *   --run-latest <path>  deploy receipts   (default broadcast/DeployPauserV2Mainnet.s.sol/1/run-latest.json)
 *   --progress <path>    progress file     (default server/deployments/progress.pauser-v2.1.json; optional)
 *   --addresses <path>   address book      (default server/deployments/mainnet-addresses.ts)
 *   --no-backup          skip the backup (scratch copies only)
 *   --skip-chain-check   skip the on-chain "migration finished" gate (scratch copies only)
 *
 * Exit codes:
 *   0 - Success
 *   1 - mainnet-addresses.ts missing
 *   2 - run-latest.json missing / unparseable / no successful PauserV2 CREATE / wrong chain
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - progress disagrees with the receipts, the target key is absent, or a collision
 *   5 - the migration has not finished on-chain (no registrants, or burn not 1000e18), or RPC_MAINNET unset
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const DEFAULT_RUN_LATEST = path.join(ROOT, 'broadcast', 'DeployPauserV2Mainnet.s.sol', '1', 'run-latest.json');
const DEFAULT_PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.pauser-v2.1.json');
const DEFAULT_ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const TS_FIELD = 'Pauser';
const V1_PAUSER = '0x7c5A8EeF1d836450C019FB036453ac6eC97885a3';
const HEADER_MARKER = 'Pauser REPOINTED to PauserV2 (story 128)';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function parseArgs(argv) {
    const opts = {
        'run-latest': DEFAULT_RUN_LATEST,
        progress: DEFAULT_PROGRESS_FILE,
        addresses: DEFAULT_ADDRESSES_FILE,
        backup: true,
        chainCheck: true,
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--no-backup') {
            opts.backup = false;
        } else if (a === '--skip-chain-check') {
            opts.chainCheck = false;
        } else if ((a === '--run-latest' || a === '--progress' || a === '--addresses') && argv[i + 1]) {
            opts[a.slice(2)] = path.resolve(argv[++i]);
        } else {
            fail(4, `Unknown or incomplete argument: ${a}`);
        }
    }
    return opts;
}

/** The PauserV2 address from the deploy broadcast's receipts. */
function pauserV2FromRunLatest(file) {
    if (!fs.existsSync(file)) fail(2, `Deploy receipts not found: ${file} (run npm run pauser-v2-deploy:broadcast first)`);
    let run;
    try {
        run = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
        fail(2, `run-latest.json unparseable: ${e.message}`);
    }
    if (run.chain !== undefined && Number(run.chain) !== 1) fail(2, `run-latest.json chain is ${run.chain}, expected 1`);
    const creates = (run.transactions || []).filter(
        (t) => t.transactionType === 'CREATE' && t.contractName === 'PauserV2' && t.contractAddress
    );
    if (creates.length !== 1) fail(2, `expected exactly one PauserV2 CREATE in run-latest.json, found ${creates.length}`);
    const tx = creates[0];
    const receipt = (run.receipts || []).find((r) => r.transactionHash === tx.hash);
    if (!receipt) fail(2, `no receipt for the PauserV2 CREATE ${tx.hash} - the broadcast did not land`);
    if (!(receipt.status === '0x1' || receipt.status === 1 || receipt.status === '1')) {
        fail(2, `PauserV2 CREATE ${tx.hash} receipt status is ${receipt.status}, not success`);
    }
    const addr = tx.contractAddress;
    if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) fail(2, `malformed PauserV2 address ${addr}`);
    return addr;
}

function checkProgress(file, addr) {
    if (!fs.existsSync(file)) {
        console.log(`  (no progress file at ${path.basename(file)} - receipts only)`);
        return;
    }
    let p;
    try {
        p = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
        fail(4, `progress unparseable: ${e.message}`);
    }
    const rec = p.contracts && p.contracts.PauserV2 && p.contracts.PauserV2.address;
    if (!rec || rec.toLowerCase() !== addr.toLowerCase()) {
        fail(4, `progress PauserV2 (${rec}) != run-latest PauserV2 (${addr}) - investigate before patching`);
    }
}

function interfaceKeys() {
    if (!fs.existsSync(INTERFACE_FILE)) fail(3, `Interface file not found: ${INTERFACE_FILE}`);
    const src = fs.readFileSync(INTERFACE_FILE, 'utf8');
    const body = src.slice(src.indexOf('{'), src.lastIndexOf('}'));
    return [...body.matchAll(/^\s*([A-Za-z0-9_]+)\s*:\s*string\s*;/gm)].map((m) => m[1]);
}

/** Keys assigned in mainnet-addresses.ts, ignoring commented-out entries. */
function dataKeys(source) {
    const body = source.slice(source.indexOf('mainnetAddresses: ContractAddresses = {'));
    const withoutBlockComments = body.replace(/\/\*[\s\S]*?\*\//g, '');
    const withoutLineComments = withoutBlockComments.replace(/^\s*\/\/.*$/gm, '');
    return [...withoutLineComments.matchAll(/^\s*([A-Za-z0-9_]+)\s*:\s*"0x[0-9a-fA-F]{40}"/gm)].map((m) => m[1]);
}

const FINAL_BURN = 1000n * 10n ** 18n;

/**
 * Audit 49 L-04: refuse to name PauserV2 in the book before the migration has finished. MigratePauserV2Mainnet
 * restores the 1000-EYE burn as its LAST transaction, only after every live registrant is on V2 and health() is
 * clean, so "burn == 1000e18 and at least one registrant" is on-chain proof that the migration completed.
 * `npm run pauser-v2-verify`, chained after this, checks the full invariant.
 */
function requireMigrationComplete(addr) {
    const rpc = process.env.RPC_MAINNET;
    if (!rpc) fail(5, 'RPC_MAINNET unset - cannot confirm the migration finished (use --skip-chain-check only on scratch copies)');
    const call = (sig) => execFileSync('cast', ['call', addr, sig, '--rpc-url', rpc], { encoding: 'utf8' }).trim();
    const burn = BigInt(call('eyeBurnAmount()(uint256)').split(/\s/)[0]);
    const regs = call('getPausableContracts()(address[])').replace(/[\[\]\s]/g, '');
    const count = regs === '' ? 0 : regs.split(',').length;
    if (count === 0) fail(5, `PauserV2 ${addr} has no registrants - run npm run pauser-v2-migrate:broadcast first`);
    if (burn !== FINAL_BURN) {
        fail(5, `PauserV2 ${addr} eyeBurnAmount is ${burn}, not 1000e18 - the migration has not finished (it lowers the burn last)`);
    }
    console.log(`  PauserV2 ${addr}: ${count} registrants, burn 1000e18 - migration finished`);
}

function run() {
    const opts = parseArgs(process.argv.slice(2));
    const addr = pauserV2FromRunLatest(opts['run-latest']);
    if (addr.toLowerCase() === V1_PAUSER.toLowerCase()) fail(2, 'run-latest names the V1 Pauser');
    checkProgress(opts.progress, addr);
    if (opts.chainCheck) requireMigrationComplete(addr);
    if (!fs.existsSync(opts.addresses)) fail(1, `Target file not found: ${opts.addresses}`);

    let source = fs.readFileSync(opts.addresses, 'utf8');
    const keysBefore = dataKeys(source);

    const re = new RegExp(`^(\\s*${TS_FIELD}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) fail(4, `${TS_FIELD} key not found in ${path.basename(opts.addresses)}`);
    const cur = match[2].toLowerCase();

    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-pauser-v2 (story 128 REPOINT)');
    console.log('==========================================================');
    if (cur === addr.toLowerCase()) {
        console.log(`  SAME     ${TS_FIELD} <- ${addr} (already patched; no change)`);
        return;
    }
    if (cur !== V1_PAUSER.toLowerCase()) {
        fail(4, `COLLIDE ${TS_FIELD} already=${match[2]}, wanted=${addr} (REPOINT only from V1 ${V1_PAUSER})`);
    }

    if (opts.backup) {
        execFileSync('node', [path.join(__dirname, 'backup-mainnet-addresses.js')], { stdio: 'inherit' });
    }

    const indent = match[1].match(/^\s*/)[0];
    source = source.replace(
        re,
        `${indent}// Story 128: PauserV2 (tolerant global pause). The V1 Pauser ${V1_PAUSER} is RETIRED and\n` +
            `${indent}// bricked by the migration; only the 9 retired registrants remain on it. Never re-register anything with V1.\n` +
            `$1"${addr}"$3`
    );
    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} — was the V1 Pauser ${V1_PAUSER}.\n`
        );
    }
    console.log(`  REPOINT  ${TS_FIELD} <- ${addr} (was ${match[2]})`);

    const iface = interfaceKeys();
    const data = dataKeys(source);
    if (data.length !== keysBefore.length) fail(3, `key count changed ${keysBefore.length} -> ${data.length}`);
    const missingInData = iface.filter((k) => !data.includes(k));
    const extraInData = data.filter((k) => !iface.includes(k));
    console.log(`  key-set: interface=${iface.length}  data=${data.length}`);
    if (missingInData.length || extraInData.length) {
        if (missingInData.length) console.error(`  missing from mainnet-addresses.ts: ${missingInData.join(', ')}`);
        if (extraInData.length) console.error(`  not in ContractAddresses:           ${extraInData.join(', ')}`);
        fail(3, 'key-set drift — mainnet-addresses.ts no longer matches the ContractAddresses interface');
    }

    fs.writeFileSync(opts.addresses, source, 'utf8');
    console.log(`  File written: ${opts.addresses}`);
}

if (require.main === module) run();

module.exports = { pauserV2FromRunLatest };
