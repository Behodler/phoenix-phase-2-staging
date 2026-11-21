#!/usr/bin/env node
/**
 * patch-mainnet-addresses-antimatter-booster.js  (story 139, sprint antimatter-boost)
 *
 * Post-broadcast patcher for the mainnet AntimatterBooster cutover (script/DeployAntimatterBoosterMainnet.s.sol).
 * CHAINED in `antimatter-booster:broadcast` after the forge run and scripts/confirm-antimatter-booster-progress.js,
 * before `npm run pauser-v2-verify` and `npm run antimatter-booster-verify`. Can be re-run by hand with the same
 * gates. Modelled on patch-mainnet-addresses-nft-bonfire.js (story 129).
 *
 * SOURCE OF THE ADDRESS
 *   server/deployments/progress.antimatter-booster.1.json, which must be `completed` (the confirm step),
 *   cross-checked against the CREATE receipt in broadcast/DeployAntimatterBoosterMainnet.s.sol/1/run-latest.json
 *   when that file holds an AntimatterBooster CREATE (same address = fine; any other = refuse). A resume-only
 *   run-latest (wiring txs, no CREATE) is accepted: the progress file is then the only source.
 *
 * WHAT IT TOUCHES
 *   (a) FILL `AntimatterBooster` in server/deployments/mainnet-addresses.ts: overwrite ONLY the zero-address
 *       placeholder story 138 left; the SAME address already present is success (idempotent); ANY other non-zero
 *       value is a COLLIDE and nothing is written. Story 138's "Story 138: AntimatterBooster (antimatter:005) - ..."
 *       placeholder comment is replaced and a dated header line is added. Backs the book up first
 *       (scripts/backup-mainnet-addresses.js). The key-set is re-checked against the ContractAddresses interface.
 *   (b) APPEND the booster to `postMigrationAdditions()` in script/helpers/PauserV2Registry.sol (append only,
 *       idempotent; entries added by other stories are kept). Without it `npm run pauser-v2-verify` fails.
 *
 * ON-CHAIN GATE (skippable with --skip-chain-check on scratch copies only)
 *   The booster must be fully wired before the UI-facing book names it: boostBps() == 1500 (set FIFTH, after the
 *   mint grant, the stables and the pauser) and PauserV2.isRegistered(booster).
 *
 * WHAT IT NEVER DOES
 *   Add or remove a book key; predict a CREATE address; make the registry read the progress file at runtime.
 *
 * OPTIONS (for proving the patcher on scratch copies; production runs with none)
 *   --run-latest <path>  deploy receipts  (default broadcast/DeployAntimatterBoosterMainnet.s.sol/1/run-latest.json)
 *   --progress <path>    progress file    (default server/deployments/progress.antimatter-booster.1.json)
 *   --addresses <path>   address book     (default server/deployments/mainnet-addresses.ts)
 *   --registry <path>    registry source  (default script/helpers/PauserV2Registry.sol)
 *   --interface <path>   ContractAddresses interface (default server/deployments/addresses.ts)
 *   --no-backup          skip the book backup (scratch copies only)
 *   --skip-chain-check   skip the on-chain wiring gate (scratch copies only)
 *
 * Exit codes:
 *   0 - Success (including the idempotent no-op)
 *   1 - mainnet-addresses.ts or PauserV2Registry.sol missing
 *   2 - progress missing / unparseable / wrong chain / not completed; run-latest unparseable / failed CREATE
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - address missing/zero/malformed, receipts disagree with progress, target key absent, collision,
 *       or the registry function could not be parsed
 *   5 - the booster is not fully wired on-chain, or RPC_MAINNET unset
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const DEFAULT_RUN_LATEST = path.join(ROOT, 'broadcast', 'DeployAntimatterBoosterMainnet.s.sol', '1', 'run-latest.json');
const DEFAULT_PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.antimatter-booster.1.json');
const DEFAULT_ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const DEFAULT_REGISTRY_FILE = path.join(ROOT, 'script', 'helpers', 'PauserV2Registry.sol');
const DEFAULT_INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const TS_FIELD = 'AntimatterBooster';
const CONTRACT_NAME = 'AntimatterBooster';
const PAUSER_V2 = '0x669Ebfa5309db66683c199Cfe22516DECBe1a154';
const BOOST_BPS = 1500n;
const HEADER_MARKER = 'AntimatterBooster deployed (story 139)';

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
        interface: DEFAULT_INTERFACE_FILE,
        backup: true,
        chainCheck: true,
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--no-backup') opts.backup = false;
        else if (a === '--skip-chain-check') opts.chainCheck = false;
        else if (['--run-latest', '--progress', '--addresses', '--registry', '--interface'].includes(a) && argv[i + 1]) {
            opts[a.slice(2)] = path.resolve(argv[++i]);
        } else fail(4, `Unknown or incomplete argument: ${a}`);
    }
    return opts;
}

function validAddress(a) {
    return typeof a === 'string' && /^0x[0-9a-fA-F]{40}$/.test(a) && a.toLowerCase() !== ZERO_ADDRESS;
}

/**
 * The AntimatterBooster address from the deploy broadcast's receipts. `optional`: return null when the file is
 * absent or holds no AntimatterBooster CREATE (a resume-only run). A CREATE that is present but failed always refuses.
 */
function boosterFromRunLatest(file, optional = false) {
    if (!fs.existsSync(file)) {
        if (optional) return null;
        fail(2, `Deploy receipts not found: ${file} (run npm run antimatter-booster:broadcast first)`);
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
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (run scripts/confirm-antimatter-booster-progress.js)`);
    }
    const addr = p.contracts && p.contracts[TS_FIELD] && p.contracts[TS_FIELD].address;
    if (!validAddress(addr)) fail(4, `progress contracts.${TS_FIELD}.address missing, malformed or zero`);
    return addr;
}

function requireWiredOnChain(addr) {
    const rpc = process.env.RPC_MAINNET;
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
            return fail(5, `cast call ${sig} on ${to} failed (no code at the booster yet, or RPC error)`);
        }
    };
    const bps = BigInt(call(addr, 'boostBps()(uint256)'));
    const registered = call(PAUSER_V2, 'isRegistered(address)(bool)', addr);
    if (bps !== BOOST_BPS) fail(5, `AntimatterBooster ${addr} boostBps is ${bps}, not 1500 - the wiring has not finished (re-run the broadcast)`);
    if (registered !== 'true') fail(5, `AntimatterBooster ${addr} is not registered with PauserV2 - the wiring has not finished`);
    console.log('  on-chain: boostBps 1500, registered with PauserV2 - wiring finished');
}

function checksum(addr) {
    return execFileSync('cast', ['to-check-sum-address', addr], { encoding: 'utf8' }).trim();
}

// ---------------- (a) address book ----------------

function interfaceKeys(file) {
    if (!fs.existsSync(file)) fail(3, `Interface file not found: ${file}`);
    const src = fs.readFileSync(file, 'utf8');
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
        /^([ \t]*)\/\/ Story 138: AntimatterBooster \(antimatter:005\) - [^\n]*\n(?:[ \t]*\/\/[^\n]*\n)*?(?=[ \t]*AntimatterBooster:)/m,
        (m, indent) =>
            `${indent}// Story 138/139: AntimatterBooster (antimatter:005) - phUSD bonus (15%) on annihilations of\n` +
            `${indent}// under-represented stables. Deployed + wired by DeployAntimatterBoosterMainnet (story 139),\n` +
            `${indent}// registered with PauserV2, and patched from progress.antimatter-booster.1.json.\n`
    );
    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} — AntimatterBooster FILLED from progress.antimatter-booster.1.json; OWNER phUSD mint revoked.\n`
        );
    }

    const iface = interfaceKeys(opts.interface);
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

// ---------------- (b) PauserV2Registry.postMigrationAdditions() ----------------

const ADDITIONS_RE =
    /(function postMigrationAdditions\(\) public view virtual returns \(address\[\] memory a\) \{\n)([\s\S]*?)(\n[ \t]*\})/;

function patchRegistry(opts, addr) {
    if (!fs.existsSync(opts.registry)) fail(1, `Registry not found: ${opts.registry}`);
    const source = fs.readFileSync(opts.registry, 'utf8');
    const m = source.match(ADDITIONS_RE);
    if (!m) fail(4, `could not find postMigrationAdditions() in ${path.basename(opts.registry)}`);
    const body = m[2];

    const sizeMatch = body.match(/a = new address\[\]\((\d+)\);/);
    if (!sizeMatch) fail(4, 'postMigrationAdditions(): no `a = new address[](N);` line');
    const entryLines = body.split('\n').filter((l) => /^\s*a\[\d+\] = 0x[0-9a-fA-F]{40};/.test(l));
    const entries = entryLines.map((l) => l.match(/a\[(\d+)\] = (0x[0-9a-fA-F]{40});/));
    if (Number(sizeMatch[1]) !== entries.length) {
        fail(4, `postMigrationAdditions(): declared size ${sizeMatch[1]} != ${entries.length} entries - fix by hand`);
    }
    entries.forEach((e, i) => {
        if (Number(e[1]) !== i) fail(4, `postMigrationAdditions(): entry indices are not 0..${entries.length - 1}`);
    });
    if (entries.some((e) => e[2].toLowerCase() === addr.toLowerCase())) {
        console.log(`  SAME     PauserV2Registry.postMigrationAdditions() already lists ${addr} (no change)`);
        return;
    }

    const indent = (body.match(/^([ \t]*)a = new address/m) || [null, '        '])[1];
    const n = entries.length;
    const newBody = [
        `${indent}a = new address[](${n + 1});`,
        ...entryLines,
        `${indent}a[${n}] = ${checksum(addr)}; // AntimatterBooster (story 139)`,
    ].join('\n');
    const out = source.replace(ADDITIONS_RE, `$1${newBody}$3`);
    fs.writeFileSync(opts.registry, out, 'utf8');
    console.log(`  APPEND   PauserV2Registry.postMigrationAdditions()[${n}] <- ${addr}  (written: ${opts.registry})`);
}

function run() {
    const opts = parseArgs(process.argv.slice(2));
    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-antimatter-booster (story 139)');
    console.log('==========================================================');
    const addr = checksum(loadProgress(opts.progress));
    const fromReceipts = boosterFromRunLatest(opts['run-latest'], true);
    if (fromReceipts && fromReceipts.toLowerCase() !== addr.toLowerCase()) {
        fail(4, `progress AntimatterBooster (${addr}) != run-latest CREATE (${fromReceipts}) - investigate before patching`);
    }
    if (!fromReceipts) console.log('  (run-latest holds no AntimatterBooster CREATE - resume-only run; progress file is the source)');
    if (opts.chainCheck) requireWiredOnChain(addr);
    patchBook(opts, addr);
    patchRegistry(opts, addr);
    console.log('==========================================================');
}

if (require.main === module) run();

module.exports = { boosterFromRunLatest };
