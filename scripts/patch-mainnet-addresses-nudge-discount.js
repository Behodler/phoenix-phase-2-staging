#!/usr/bin/env node
/**
 * patch-mainnet-addresses-nudge-discount.js  (story 119, sprint nudge-discount)
 *
 * Post-broadcast patcher for the mainnet nudge-discount minter cutover (script/DeployMainnetNudgeDiscount.s.sol).
 * CHAINED in `nudge-discount:broadcast` after the forge run and scripts/confirm-nudge-discount-progress.js, before
 * `npm run pauser-v2-verify` and `npm run nudge-discount:verify`. Can be re-run by hand with the same gates.
 * Modelled on patch-mainnet-addresses-nft-bonfire.js (story 129) and patch-mainnet-addresses-promotion-ready.js.
 *
 * SOURCE OF THE ADDRESS
 *   server/deployments/progress.nudge-discount.1.json, which must be `completed` (the confirm step), cross-checked
 *   against the CREATE receipt in broadcast/DeployMainnetNudgeDiscount.s.sol/1/run-latest.json when that file holds
 *   a BatchNFTMinterNudgeDiscount CREATE (same address = fine; any other = refuse). A resume-only run-latest (no
 *   CREATE) is accepted: the progress file is then the only source, and it was confirmed by the first run.
 *
 * WHAT IT TOUCHES (by NAME, never by line number)
 *   (a) FILL `NudgeDiscountBatchMinter` in server/deployments/mainnet-addresses.ts (update:false): overwrite ONLY the
 *       zero-address placeholder story 118 left; the SAME address already present is success (idempotent); ANY
 *       other non-zero value is a COLLIDE and nothing is written. `BatchNFTMinter` (the old, now paused minter) is
 *       left untouched: the UI keeps reading it until phlimbo-ui:091. Adds a dated header line. Backs the book up
 *       first (scripts/backup-mainnet-addresses.js). Re-checks the key-set against the ContractAddresses interface.
 *   (b) APPEND to script/helpers/PauserV2Registry.sol (append only, idempotent, entries of other stories kept):
 *         - the new minter to `postMigrationAdditions()`  (registered with PauserV2 by the cutover),
 *         - the old minter 0x0683...15c7 to `postMigrationRemovals()` (unregistered by the cutover),
 *       each with a `// ... (story 119)` comment. Without them `npm run pauser-v2-verify` fails.
 *
 * ON-CHAIN GATE (skippable with --skip-chain-check on scratch copies only)
 *   The UI-facing book must not name the minter before the cutover's last Phase 2 step landed:
 *   NFTMinter.authorizedMinters(new) == true and PauserV2.isRegistered(new) == true.
 *
 * OPTIONS (for proving the patcher on scratch copies; production runs with none)
 *   --run-latest <path>  deploy receipts  (default broadcast/DeployMainnetNudgeDiscount.s.sol/1/run-latest.json)
 *   --progress <path>    progress file    (default server/deployments/progress.nudge-discount.1.json)
 *   --addresses <path>   address book     (default server/deployments/mainnet-addresses.ts)
 *   --registry <path>    registry source  (default script/helpers/PauserV2Registry.sol)
 *   --no-backup          skip the book backup (scratch copies only)
 *   --skip-chain-check   skip the on-chain gate (scratch copies only)
 *
 * Exit codes:
 *   0 - Success (including the idempotent no-op)
 *   1 - mainnet-addresses.ts or PauserV2Registry.sol missing
 *   2 - progress missing / unparseable / wrong chain / not completed; run-latest unparseable / failed CREATE
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - address missing/zero/malformed, receipts disagree with progress, target key absent, collision,
 *       or a registry function could not be parsed
 *   5 - the minter is not authorised / not registered on-chain, or RPC_MAINNET unset
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const DEFAULT_RUN_LATEST = path.join(ROOT, 'broadcast', 'DeployMainnetNudgeDiscount.s.sol', '1', 'run-latest.json');
const DEFAULT_PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.nudge-discount.1.json');
const DEFAULT_ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const DEFAULT_REGISTRY_FILE = path.join(ROOT, 'script', 'helpers', 'PauserV2Registry.sol');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const TS_FIELD = 'NudgeDiscountBatchMinter';
const CONTRACT_NAME = 'BatchNFTMinterNudgeDiscount';
const OLD_MINTER = '0x068395556b8c43eDf257DC54D109EA5910aE15c7';
const NFT_MINTER = '0x39Af088408e815844c567037C157B31d48d2E10F';
const PAUSER_V2 = '0x669Ebfa5309db66683c199Cfe22516DECBe1a154';
const HEADER_MARKER = 'nudge-discount minter cutover (story 119)';

function fail(code, msg) {
    console.error(`ERROR (${code}): ${msg}`);
    process.exit(code);
}

function parseArgs(argv) {
    const opts = {
        'run-latest': DEFAULT_RUN_LATEST,
        progress: DEFAULT_PROGRESS_FILE,
        addresses: DEFAULT_ADDRESSES_FILE,
        registry: DEFAULT_REGISTRY_FILE,
        backup: true,
        chainCheck: true,
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--no-backup') opts.backup = false;
        else if (a === '--skip-chain-check') opts.chainCheck = false;
        else if (['--run-latest', '--progress', '--addresses', '--registry'].includes(a) && argv[i + 1]) {
            opts[a.slice(2)] = path.resolve(argv[++i]);
        } else fail(4, `Unknown or incomplete argument: ${a}`);
    }
    return opts;
}

function validAddress(a) {
    return typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a) && a.toLowerCase() !== ZERO_ADDRESS;
}

/**
 * The new minter's address from the cutover broadcast's receipts. `optional`: return null when the file is absent or
 * holds no BatchNFTMinterNudgeDiscount CREATE (a resume-only run). A CREATE that is present but failed always refuses.
 */
function minterFromRunLatest(file, optional = false) {
    if (!fs.existsSync(file)) {
        if (optional) return null;
        fail(2, `Deploy receipts not found: ${file} (run npm run nudge-discount:broadcast first)`);
    }
    let run;
    try {
        run = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
        fail(2, `run-latest.json unparseable: ${e.message}`);
    }
    if (run.chain !== undefined && Number(run.chain) !== 1) fail(2, `run-latest.json chain is ${run.chain}, expected 1`);
    const creates = (run.transactions || []).filter(
        (t) => t.transactionType === 'CREATE' && t.contractName === CONTRACT_NAME && t.contractAddress
    );
    if (creates.length === 0 && optional) return null;
    if (creates.length !== 1) fail(2, `expected exactly one ${CONTRACT_NAME} CREATE in run-latest.json, found ${creates.length}`);
    const tx = creates[0];
    const receipt = (run.receipts || []).find((r) => r.transactionHash === tx.hash);
    if (!receipt) fail(2, `no receipt for the ${CONTRACT_NAME} CREATE ${tx.hash} - the broadcast did not land`);
    if (!(receipt.status === '0x1' || receipt.status === 1 || receipt.status === '1')) {
        fail(2, `${CONTRACT_NAME} CREATE ${tx.hash} receipt status is ${receipt.status}, not success`);
    }
    if (!validAddress(tx.contractAddress)) fail(2, `malformed ${CONTRACT_NAME} address ${tx.contractAddress}`);
    return tx.contractAddress;
}

function loadProgress(file) {
    if (!fs.existsSync(file)) fail(2, `Progress file not found: ${file}`);
    let p;
    try {
        p = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
        fail(2, `Progress unparseable: ${e.message}`);
    }
    if (p.chainId !== 1) fail(2, `Progress chainId is ${p.chainId}, expected 1 (mainnet)`);
    if (p.deploymentStatus !== 'completed') {
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (run scripts/confirm-nudge-discount-progress.js)`);
    }
    const addr = p.contracts && p.contracts[TS_FIELD] && p.contracts[TS_FIELD].address;
    if (!validAddress(addr)) fail(4, `progress contracts.${TS_FIELD}.address missing, malformed or zero`);
    return addr;
}

function requireWiredOnChain(addr) {
    const rpc = process.env.RPC_MAINNET || process.env.MAINNET_RPC_URL;
    if (!rpc) fail(5, 'RPC_MAINNET unset - cannot confirm the wiring (use --skip-chain-check only on scratch copies)');
    const call = (to, sig, ...args) => {
        try {
            return execFileSync('cast', ['call', to, sig, ...args, '--rpc-url', rpc], {
                encoding: 'utf8',
                stdio: ['ignore', 'pipe', 'pipe'],
            })
                .trim()
                .split(/\s/)[0];
        } catch (e) {
            // Never echo the command line: it carries the RPC URL.
            return fail(5, `cast call ${sig} on ${to} failed (no code yet, or RPC error)`);
        }
    };
    if (call(NFT_MINTER, 'authorizedMinters(address)(bool)', addr) !== 'true') {
        fail(5, `${addr} is not an authorised NFTMinterV2 minter - Phase 2 has not finished (re-run the broadcast)`);
    }
    if (call(PAUSER_V2, 'isRegistered(address)(bool)', addr) !== 'true') {
        fail(5, `${addr} is not registered with PauserV2 - Phase 2 has not finished (re-run the broadcast)`);
    }
    console.log('  on-chain: authorised NFTMinterV2 minter, registered with PauserV2');
}

function checksum(addr) {
    return execFileSync('cast', ['to-check-sum-address', addr], { encoding: 'utf8' }).trim();
}

// ---------------- (a) address book ----------------

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

function patchBook(opts, addr) {
    if (!fs.existsSync(opts.addresses)) fail(1, `Target file not found: ${opts.addresses}`);
    let source = fs.readFileSync(opts.addresses, 'utf8');
    const keysBefore = dataKeys(source);

    const re = new RegExp(`^(\\s*${TS_FIELD}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
    const match = source.match(re);
    if (!match) fail(4, `MISS-DST ${TS_FIELD} key not found in ${path.basename(opts.addresses)}`);
    const cur = match[2].toLowerCase();
    if (cur === addr.toLowerCase()) {
        console.log(`  SAME     ${TS_FIELD} <- ${addr} (book already patched; no change)`);
        return;
    }
    if (cur !== ZERO_ADDRESS) fail(4, `COLLIDE ${TS_FIELD} already=${match[2]}, wanted=${addr} (FILL only over the ZERO placeholder)`);

    if (opts.backup) execFileSync('node', [path.join(__dirname, 'backup-mainnet-addresses.js')], { stdio: 'inherit' });

    source = source.replace(re, `$1"${addr}"$3`);
    source = source.replace(
        /^([ \t]*)\/\/ Story 118: BatchNFTMinterNudgeDiscount[^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*NudgeDiscountBatchMinter:)/m,
        (m, indent) =>
            `${indent}// Story 118/119: BatchNFTMinterNudgeDiscount (nft-staking:033-035), the index-4 nudge sink. Deployed\n` +
            `${indent}// by DeployMainnetNudgeDiscount (story 119), registered with PauserV2, patched from progress.nudge-discount.1.json.\n` +
            `${indent}// BatchNFTMinter above is the OLD minter, paused by the same cutover (kept for the UI until phlimbo-ui:091).\n`
    );
    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} — NudgeDiscountBatchMinter FILLED from progress.nudge-discount.1.json; BatchNFTMinter (old, paused) kept.\n`
        );
    }

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
    console.log(`  FILL     ${TS_FIELD} <- ${addr}  (written: ${opts.addresses})`);
}

// ---------------- (b) PauserV2Registry ----------------

function fnRegex(name) {
    return new RegExp(
        `(function ${name}\\(\\) public view virtual returns \\(address\\[\\] memory a\\) \\{\\n)([\\s\\S]*?)(\\n[ \\t]*\\})`
    );
}

/** Append `addr` to the registry function `name` (append-only, idempotent). Returns the new source. */
function appendToRegistryFn(source, name, addr, comment) {
    const re = fnRegex(name);
    const m = source.match(re);
    if (!m) fail(4, `could not find ${name}() in the registry`);
    const body = m[2];
    const sizeMatch = body.match(/a = new address\[\]\((\d+)\);/);
    if (!sizeMatch) fail(4, `${name}(): no \`a = new address[](N);\` line`);
    const entryLines = body.split('\n').filter((l) => /^\s*a\[\d+\] = 0x[0-9a-fA-F]{40};/.test(l));
    const entries = entryLines.map((l) => l.match(/a\[(\d+)\] = (0x[0-9a-fA-F]{40});/));
    if (Number(sizeMatch[1]) !== entries.length) {
        fail(4, `${name}(): declared size ${sizeMatch[1]} != ${entries.length} entries - fix by hand`);
    }
    entries.forEach((e, i) => {
        if (Number(e[1]) !== i) fail(4, `${name}(): entry indices are not 0..${entries.length - 1}`);
    });
    if (entries.some((e) => e[2].toLowerCase() === addr.toLowerCase())) {
        console.log(`  SAME     PauserV2Registry.${name}() already lists ${addr} (no change)`);
        return source;
    }
    const indent = (body.match(/^([ \t]*)a = new address/m) || [null, '        '])[1];
    const n = entries.length;
    const newBody = [
        `${indent}a = new address[](${n + 1});`,
        ...entryLines,
        `${indent}a[${n}] = ${checksum(addr)}; // ${comment}`,
    ].join('\n');
    console.log(`  APPEND   PauserV2Registry.${name}()[${n}] <- ${addr}`);
    return source.replace(re, `$1${newBody}$3`);
}

function patchRegistry(opts, addr) {
    if (!fs.existsSync(opts.registry)) fail(1, `Registry not found: ${opts.registry}`);
    const before = fs.readFileSync(opts.registry, 'utf8');
    let out = appendToRegistryFn(before, 'postMigrationAdditions', addr, 'BatchNFTMinterNudgeDiscount (story 119)');
    out = appendToRegistryFn(out, 'postMigrationRemovals', OLD_MINTER, 'BatchNFTMinterMultiToken, retired (story 119)');
    if (out !== before) {
        fs.writeFileSync(opts.registry, out, 'utf8');
        console.log(`  (written: ${opts.registry})`);
    }
}

function run() {
    const opts = parseArgs(process.argv.slice(2));
    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-nudge-discount (story 119)');
    console.log('==========================================================');
    const addr = checksum(loadProgress(opts.progress));
    const fromReceipts = minterFromRunLatest(opts['run-latest'], true);
    if (fromReceipts && fromReceipts.toLowerCase() !== addr.toLowerCase()) {
        fail(4, `progress ${TS_FIELD} (${addr}) != run-latest CREATE (${fromReceipts}) - investigate before patching`);
    }
    if (!fromReceipts) console.log(`  (run-latest holds no ${CONTRACT_NAME} CREATE - resume-only run; progress file is the source)`);
    if (opts.chainCheck) requireWiredOnChain(addr);
    patchBook(opts, addr);
    patchRegistry(opts, addr);
    console.log('==========================================================');
}

if (require.main === module) run();

module.exports = { minterFromRunLatest };
