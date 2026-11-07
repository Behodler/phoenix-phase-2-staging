#!/usr/bin/env node
/**
 * patch-mainnet-addresses-sya-gate-off.js  (story 131, sprint nft-bonfire)
 *
 * Post-broadcast patcher for the gate-free SYA replacement + SYAHarvester redeploy
 * (script/ReplaceSYAGateOffMainnet.s.sol). CHAINED in `sya-gate-off:broadcast` after the forge run and
 * scripts/confirm-sya-gate-off-progress.js, before `npm run sya-gate-off-verify` and `npm run pauser-v2-verify`.
 * Can be re-run by hand with the same gates. Models: patch-mainnet-addresses-nft-bonfire.js (registry append,
 * key-set check), patch-mainnet-addresses-replace-sya.js (exact-old repoint).
 *
 * SOURCE OF THE ADDRESSES
 *   server/deployments/progress.sya-gate-off.1.json, which must be `completed` (the confirm step), cross-checked
 *   against the CREATE receipts in broadcast/ReplaceSYAGateOffMainnet.s.sol/1/run-latest.json for every CREATE that
 *   file holds (same address = fine; any other = refuse). A resume-only run-latest (no CREATE) is accepted: the
 *   progress file was confirmed from the first run's receipts.
 *
 * WHAT IT TOUCHES
 *   (a) REPOINT `StableYieldAccumulator` and `SYAHarvester` in server/deployments/mainnet-addresses.ts. Each key is
 *       overwritten ONLY when its current value is exactly the old address (0x0cD3...21B6 / 0xeE42...703B); the new
 *       address already present is a no-op; ANY other value is a COLLIDE and nothing is written. Backs the book up
 *       first (scripts/backup-mainnet-addresses.js) and re-checks the key-set against the ContractAddresses interface.
 *       A dated header comment is added once. The book is hand-maintained: never regenerated.
 *   (b) APPEND the new SYA to `postMigrationAdditions()` and the old SYA to `postMigrationRemovals()` in
 *       script/helpers/PauserV2Registry.sol (append only, idempotent; entries from other stories, e.g. 129's
 *       NFTBonfire or 119's minter, are kept). The harvester is NOT a PauserV2 registrant (it has no pauser()).
 *
 * ON-CHAIN GATE (skippable with --skip-chain-check on scratch copies only)
 *   The cutover must have finished before the UI-facing book names the new contracts: new SYA registered with
 *   PauserV2, old SYA unregistered with an empty strategy list, harvester.sya() == new SYA.
 *
 * OPTIONS (scratch copies only; production runs with none)
 *   --run-latest <path> --progress <path> --addresses <path> --registry <path> --no-backup --skip-chain-check
 *
 * Exit codes:
 *   0 - Success (including the idempotent no-op)
 *   1 - mainnet-addresses.ts or PauserV2Registry.sol missing
 *   2 - progress missing / unparseable / wrong chain / not completed; run-latest unparseable / failed CREATE
 *   3 - post-patch key-set no longer equals the ContractAddresses interface
 *   4 - address missing/zero/malformed, receipts disagree with progress, key absent, collision, registry unparseable
 *   5 - the cutover is not finished on-chain, or RPC_MAINNET unset
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const ROOT = path.join(__dirname, '..');
const DEFAULT_RUN_LATEST = path.join(ROOT, 'broadcast', 'ReplaceSYAGateOffMainnet.s.sol', '1', 'run-latest.json');
const DEFAULT_PROGRESS_FILE = path.join(ROOT, 'server', 'deployments', 'progress.sya-gate-off.1.json');
const DEFAULT_ADDRESSES_FILE = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const DEFAULT_REGISTRY_FILE = path.join(ROOT, 'script', 'helpers', 'PauserV2Registry.sol');
const INTERFACE_FILE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');

const OLD_SYA = '0x0cD353bfda674D04823B2826ffafB83B560D21B6';
const OLD_HARVESTER = '0xeE426A950Cb17D559F6391ef0D140715CD46703B';
const PAUSER_V2 = '0x669Ebfa5309db66683c199Cfe22516DECBe1a154';
const HEADER_MARKER = 'gate-free SYA + SYAHarvester (story 131)';

/** progress key / forge contractName -> book key and the exact old value it may overwrite. */
const TARGETS = [
    { key: 'StableYieldAccumulator', contractName: 'StableYieldAccumulator', old: OLD_SYA },
    { key: 'SYAHarvester', contractName: 'SYAHarvester', old: OLD_HARVESTER },
];

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
 * The CREATE addresses in the broadcast receipts, by contractName. `optional`: an absent file yields {}. A CREATE
 * that is present but failed always refuses, as does more than one CREATE of the same contract.
 */
function createsFromRunLatest(file, optional = true) {
    if (!fs.existsSync(file)) {
        if (optional) return {};
        fail(2, `Deploy receipts not found: ${file} (run npm run sya-gate-off:broadcast first)`);
    }
    let run;
    try {
        run = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
        fail(2, `run-latest.json unparseable: ${e.message}`);
    }
    if (run.chain !== undefined && Number(run.chain) !== 1) fail(2, `run-latest.json chain is ${run.chain}, expected 1`);
    const out = {};
    for (const t of TARGETS) {
        const creates = (run.transactions || []).filter(
            (tx) => tx.transactionType === 'CREATE' && tx.contractName === t.contractName && tx.contractAddress
        );
        if (creates.length === 0) continue;
        if (creates.length > 1) fail(2, `more than one ${t.contractName} CREATE in run-latest.json`);
        const tx = creates[0];
        const receipt = (run.receipts || []).find((r) => r.transactionHash === tx.hash);
        if (!receipt) fail(2, `no receipt for the ${t.contractName} CREATE ${tx.hash} - the broadcast did not land`);
        if (!(receipt.status === '0x1' || receipt.status === 1 || receipt.status === '1')) {
            fail(2, `${t.contractName} CREATE ${tx.hash} receipt status is ${receipt.status}, not success`);
        }
        if (!validAddress(tx.contractAddress)) fail(2, `malformed ${t.contractName} address ${tx.contractAddress}`);
        out[t.key] = tx.contractAddress;
    }
    return out;
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
        fail(2, `deploymentStatus is "${p.deploymentStatus}", expected "completed" (run scripts/confirm-sya-gate-off-progress.js)`);
    }
    const out = {};
    for (const t of TARGETS) {
        const addr = p.contracts && p.contracts[t.key] && p.contracts[t.key].address;
        if (!validAddress(addr)) fail(4, `progress contracts.${t.key}.address missing, malformed or zero`);
        if (addr.toLowerCase() === t.old.toLowerCase()) fail(4, `progress ${t.key} is the OLD address ${t.old}`);
        out[t.key] = addr;
    }
    return out;
}

function requireFinishedOnChain(addrs) {
    const rpc = process.env.RPC_MAINNET;
    if (!rpc) fail(5, 'RPC_MAINNET unset - cannot confirm the cutover (use --skip-chain-check only on scratch copies)');
    const call = (to, sig, ...args) => {
        try {
            return execFileSync('cast', ['call', to, sig, ...args, '--rpc-url', rpc], {
                encoding: 'utf8',
                stdio: ['ignore', 'pipe', 'pipe'],
            }).trim();
        } catch (e) {
            // Never echo the command line: it carries the RPC URL.
            return fail(5, `cast call ${sig} on ${to} failed (no code yet, or RPC error)`);
        }
    };
    const sya = addrs.StableYieldAccumulator;
    if (call(PAUSER_V2, 'isRegistered(address)(bool)', sya) !== 'true') fail(5, `new SYA ${sya} is not registered with PauserV2 - the cutover has not finished`);
    if (call(PAUSER_V2, 'isRegistered(address)(bool)', OLD_SYA) !== 'false') fail(5, 'old SYA is still registered with PauserV2 - the retirement has not finished');
    if (call(OLD_SYA, 'getYieldStrategies()(address[])') !== '[]') fail(5, 'old SYA still lists strategies - the retirement has not finished');
    const hSya = call(addrs.SYAHarvester, 'sya()(address)');
    if (hSya.toLowerCase() !== sya.toLowerCase()) fail(5, `new harvester sya() is ${hSya}, not the new SYA`);
    console.log('  on-chain: new SYA registered, old SYA unregistered and stripped, harvester points at the new SYA');
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

/** Decide every key BEFORE writing anything: a collision on either key leaves the book untouched. */
function patchBook(opts, addrs) {
    if (!fs.existsSync(opts.addresses)) fail(1, `Target file not found: ${opts.addresses}`);
    let source = fs.readFileSync(opts.addresses, 'utf8');
    const keysBefore = dataKeys(source);
    const plan = [];
    for (const t of TARGETS) {
        // Whole-key match at line start: `StableYieldAccumulator:` never matches a longer key.
        const re = new RegExp(`^(\\s*${t.key}:\\s*)"(0x[0-9a-fA-F]{40})"(.*)$`, 'm');
        const m = source.match(re);
        if (!m) fail(4, `MISS-DST ${t.key} key not found in ${path.basename(opts.addresses)}`);
        const cur = m[2].toLowerCase();
        const want = addrs[t.key];
        if (cur === want.toLowerCase()) {
            console.log(`  SAME     ${t.key} <- ${want} (already repointed; no change)`);
            continue;
        }
        if (cur !== t.old.toLowerCase()) fail(4, `COLLIDE ${t.key} is ${m[2]}, expected the old ${t.old} or the new ${want} - refusing`);
        plan.push({ re, key: t.key, want, old: m[2] });
    }
    if (plan.length === 0) return;
    if (opts.backup) execFileSync('node', [path.join(__dirname, 'backup-mainnet-addresses.js')], { stdio: 'inherit' });
    for (const p of plan) source = source.replace(p.re, `$1"${p.want}"$3`);
    const today = new Date().toISOString().split('T')[0];
    if (!source.includes(HEADER_MARKER)) {
        source = source.replace(
            /(?=^import \{ ContractAddresses \})/m,
            `// Updated ${today}: ${HEADER_MARKER} — StableYieldAccumulator REPOINTED from ${OLD_SYA} and SYAHarvester\n` +
                `// REPOINTED from ${OLD_HARVESTER}, both from progress.sya-gate-off.1.json (NFT claim gate off, 1% discount).\n`
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
    for (const p of plan) console.log(`  REPOINT  ${p.key}: ${p.old} -> ${p.want}  (written: ${opts.addresses})`);
}

// ---------------- (b) PauserV2Registry ----------------

function registryRe(fn) {
    return new RegExp(
        `(function ${fn}\\(\\) public view virtual returns \\(address\\[\\] memory a\\) \\{\\n)([\\s\\S]*?)(\\n[ \\t]*\\})`
    );
}

/** Append `addr` to `fn()` in the registry source; returns the new source (unchanged when already listed). */
function appendToRegistryFn(source, fn, addr, label) {
    const re = registryRe(fn);
    const m = source.match(re);
    if (!m) fail(4, `could not find ${fn}() in PauserV2Registry.sol`);
    const body = m[2];
    const sizeMatch = body.match(/a = new address\[\]\((\d+)\);/);
    if (!sizeMatch) fail(4, `${fn}(): no \`a = new address[](N);\` line`);
    const entryLines = body.split('\n').filter((l) => /^\s*a\[\d+\] = 0x[0-9a-fA-F]{40};/.test(l));
    const entries = entryLines.map((l) => l.match(/a\[(\d+)\] = (0x[0-9a-fA-F]{40});/));
    if (Number(sizeMatch[1]) !== entries.length) {
        fail(4, `${fn}(): declared size ${sizeMatch[1]} != ${entries.length} entries - fix by hand`);
    }
    entries.forEach((e, i) => {
        if (Number(e[1]) !== i) fail(4, `${fn}(): entry indices are not 0..${entries.length - 1}`);
    });
    if (entries.some((e) => e[2].toLowerCase() === addr.toLowerCase())) {
        console.log(`  SAME     PauserV2Registry.${fn}() already lists ${addr} (no change)`);
        return source;
    }
    const indent = (body.match(/^([ \t]*)a = new address/m) || [null, '        '])[1];
    const n = entries.length;
    const newBody = [
        `${indent}a = new address[](${n + 1});`,
        ...entryLines,
        `${indent}a[${n}] = ${checksum(addr)}; // ${label}`,
    ].join('\n');
    console.log(`  APPEND   PauserV2Registry.${fn}()[${n}] <- ${addr}`);
    return source.replace(re, `$1${newBody}$3`);
}

function patchRegistry(opts, addrs) {
    if (!fs.existsSync(opts.registry)) fail(1, `Registry not found: ${opts.registry}`);
    const before = fs.readFileSync(opts.registry, 'utf8');
    let out = appendToRegistryFn(
        before,
        'postMigrationAdditions',
        addrs.StableYieldAccumulator,
        'StableYieldAccumulator, gate-free (story 131)'
    );
    out = appendToRegistryFn(out, 'postMigrationRemovals', OLD_SYA, 'StableYieldAccumulator, retired (story 131)');
    if (out !== before) {
        fs.writeFileSync(opts.registry, out, 'utf8');
        console.log(`  (written: ${opts.registry})`);
    }
}

function run() {
    const opts = parseArgs(process.argv.slice(2));
    console.log('==========================================================');
    console.log('  patch-mainnet-addresses-sya-gate-off (story 131)');
    console.log('==========================================================');
    const fromProgress = loadProgress(opts.progress);
    const addrs = {};
    for (const t of TARGETS) addrs[t.key] = checksum(fromProgress[t.key]);
    const fromReceipts = createsFromRunLatest(opts['run-latest'], true);
    for (const t of TARGETS) {
        const r = fromReceipts[t.key];
        if (r && r.toLowerCase() !== addrs[t.key].toLowerCase()) {
            fail(4, `progress ${t.key} (${addrs[t.key]}) != run-latest CREATE (${r}) - investigate before patching`);
        }
        if (!r) console.log(`  (run-latest holds no ${t.contractName} CREATE - resume run; the confirmed progress file is the source)`);
    }
    if (opts.chainCheck) requireFinishedOnChain(addrs);
    patchBook(opts, addrs);
    patchRegistry(opts, addrs);
    console.log('==========================================================');
}

if (require.main === module) run();

module.exports = { createsFromRunLatest, TARGETS };
