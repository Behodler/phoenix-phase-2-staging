// Story 139 - off-chain helpers of the AntimatterBooster mainnet cutover, tested on SCRATCH COPIES only.
// Run: node --test test/js/antimatter-booster-offchain.test.js   (npm run test:antimatter-booster-offchain)
//
// Never touches server/deployments/mainnet-addresses.ts, script/helpers/PauserV2Registry.sol or the real progress
// file: every case copies them (or the fixtures in test/fixtures/antimatter-booster/) into a fresh temp dir. `cast code`
// is stubbed (--code-stub) and the patcher's on-chain gate is skipped (--skip-chain-check), so no RPC is needed.
// `cast` itself must be on PATH (checksumming).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..', '..');
const FIX = path.join(ROOT, 'test', 'fixtures', 'antimatter-booster');
const PATCHER = path.join(ROOT, 'scripts', 'patch-mainnet-addresses-antimatter-booster.js');
const CONFIRM = path.join(ROOT, 'scripts', 'confirm-antimatter-booster-progress.js');
const BOOK = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const IFACE = path.join(ROOT, 'server', 'deployments', 'addresses.ts');
const REGISTRY = path.join(ROOT, 'script', 'helpers', 'PauserV2Registry.sol');

const NEW = '0x1111111111111111111111111111111111111139';

function scratch() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'story139-'));
    const copy = (src, name) => {
        const dst = path.join(dir, name || path.basename(src));
        fs.copyFileSync(src, dst);
        return dst;
    };
    return { dir, copy };
}

function node(script, args) {
    const e = { ...process.env };
    delete e.RPC_MAINNET;
    delete e.MAINNET_RPC_URL;
    return spawnSync('node', [script, ...args], { encoding: 'utf8', env: e });
}

function patch(s, { progress = 'progress-completed.json', runLatest = 'run-latest.json', book, registry, iface } = {}) {
    const p = s.copy(path.join(FIX, progress), 'progress.json');
    const r = s.copy(path.join(FIX, runLatest), 'run-latest.json');
    const args = ['--progress', p, '--run-latest', r, '--addresses', book, '--registry', registry, '--no-backup', '--skip-chain-check'];
    if (iface) args.push('--interface', iface);
    return node(PATCHER, args);
}

function fnBody(src, name) {
    const m = src.match(new RegExp(`function ${name}\\(\\)[^{]*\\{([\\s\\S]*?)\\n\\s*\\}`));
    return m[1];
}

// ------------------------------------------------------------------ patcher

test('patcher: FILL over the zero placeholder, replaces the story-138 comment, appends the registry; re-run is SAME', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    const registry = s.copy(REGISTRY);
    const bookBefore = fs.readFileSync(book, 'utf8');
    const regBefore = fs.readFileSync(registry, 'utf8');
    assert.match(bookBefore, /\n {2}AntimatterBooster: "0x0{40}"/, 'fixture precondition: zero placeholder');
    assert.match(bookBefore, /\/\/ Story 138: AntimatterBooster \(antimatter:005\) - /, 'precondition: story-138 comment');

    const r = patch(s, { book, registry });
    assert.equal(r.status, 0, r.stderr + r.stdout);
    assert.match(r.stdout, /FILL {5}AntimatterBooster <- /);
    const after = fs.readFileSync(book, 'utf8');
    assert.match(after, new RegExp(`\\n  AntimatterBooster: "${NEW}"`, 'i'));
    assert.doesNotMatch(after, /\/\/ Story 138: AntimatterBooster \(antimatter:005\) - /, 'placeholder comment replaced');
    assert.match(after, /\/\/ Story 138\/139: AntimatterBooster/);
    assert.match(after, /^\/\/ Updated \d{4}-\d{2}-\d{2}: AntimatterBooster deployed \(story 139\)/m, 'dated header');
    // Only the target line, the 2->3 line comment and one header line changed.
    assert.equal(after.split('\n').length - bookBefore.split('\n').length, 2, 'header line + one extra comment line only');
    for (const key of ['PhUSD', 'Antimatter', 'PhusdStableMinter', 'Pauser']) {
        const re = new RegExp(`\\n  ${key}: "(0x[0-9a-fA-F]{40})"`);
        assert.equal(after.match(re)[1], bookBefore.match(re)[1], `${key} untouched`);
    }

    const reg = fs.readFileSync(registry, 'utf8');
    const adds = fnBody(reg, 'postMigrationAdditions');
    const n = Number(fnBody(regBefore, 'postMigrationAdditions').match(/new address\[\]\((\d+)\)/)[1]);
    assert.match(adds, new RegExp(`a = new address\\[\\]\\(${n + 1}\\);`));
    assert.match(adds, new RegExp(`a\\[${n}\\] = ${NEW}; // AntimatterBooster \\(story 139\\)`, 'i'));
    assert.match(adds, /0xE5983721f009AB57d464e611C9A06B148cEC3Acc; \/\/ NFTBonfire \(story 129\)/, '129 entry kept');
    assert.equal(fnBody(reg, 'postMigrationRemovals'), fnBody(regBefore, 'postMigrationRemovals'), 'removals untouched');

    const again = patch(s, { book, registry });
    assert.equal(again.status, 0, again.stderr);
    assert.equal(fs.readFileSync(book, 'utf8'), after, 'book unchanged on re-run');
    assert.equal(fs.readFileSync(registry, 'utf8'), reg, 'registry unchanged on re-run');
    assert.match(again.stdout, /SAME/);
});

test('patcher: COLLIDE on a non-zero existing value writes nothing', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    const registry = s.copy(REGISTRY);
    const other = fs
        .readFileSync(book, 'utf8')
        .replace(/(\n {2}AntimatterBooster: )"0x0{40}"/, '$1"0x3333333333333333333333333333333333333333"');
    fs.writeFileSync(book, other);
    const regBefore = fs.readFileSync(registry, 'utf8');
    const r = patch(s, { book, registry });
    assert.equal(r.status, 4);
    assert.match(r.stderr, /COLLIDE/);
    assert.equal(fs.readFileSync(book, 'utf8'), other);
    assert.equal(fs.readFileSync(registry, 'utf8'), regBefore);
});

test('patcher: key-set guard exits 3 when the interface and the book disagree, and writes nothing', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    const registry = s.copy(REGISTRY);
    const iface = s.copy(IFACE);
    const src = fs.readFileSync(iface, 'utf8');
    fs.writeFileSync(iface, src.replace(/(\n\s*AntimatterBooster\s*:\s*string\s*;)/, '$1\n  SomeNewKey: string;'));
    const before = fs.readFileSync(book, 'utf8');
    const r = patch(s, { book, registry, iface });
    assert.equal(r.status, 3, r.stderr + r.stdout);
    assert.match(r.stderr, /key-set drift/);
    assert.equal(fs.readFileSync(book, 'utf8'), before, 'book not written');
});

test('patcher: refuses deploymentStatus != completed', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    const r = patch(s, { progress: 'progress-pending.json', book, registry: s.copy(REGISTRY) });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /expected "completed"/);
    assert.equal(fs.readFileSync(book, 'utf8'), fs.readFileSync(BOOK, 'utf8'));
});

test('patcher: refuses receipts that disagree with progress, and a failed CREATE', () => {
    let s = scratch();
    let r = patch(s, { runLatest: 'run-latest-other.json', book: s.copy(BOOK), registry: s.copy(REGISTRY) });
    assert.equal(r.status, 4);
    assert.match(r.stderr, /!= run-latest CREATE/);
    s = scratch();
    r = patch(s, { runLatest: 'run-latest-failed.json', book: s.copy(BOOK), registry: s.copy(REGISTRY) });
    assert.equal(r.status, 2);
    assert.match(r.stderr, /not success/);
});

test('patcher: a resume-only run-latest (no CREATE) patches from the completed progress', () => {
    const s = scratch();
    const r = patch(s, { runLatest: 'run-latest-resume.json', book: s.copy(BOOK), registry: s.copy(REGISTRY) });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /resume-only run/);
});

test('patcher: the on-chain gate refuses without RPC_MAINNET (exit 5)', () => {
    const s = scratch();
    const p = s.copy(path.join(FIX, 'progress-completed.json'), 'progress.json');
    const r = node(PATCHER, [
        '--progress', p, '--run-latest', s.copy(path.join(FIX, 'run-latest.json')),
        '--addresses', s.copy(BOOK), '--registry', s.copy(REGISTRY), '--no-backup',
    ]);
    assert.equal(r.status, 5);
    assert.match(r.stderr, /RPC_MAINNET unset/);
});

// ------------------------------------------------------------------ confirm

function confirm(s, progress, runLatest, codeStub) {
    const p = s.copy(path.join(FIX, progress), 'progress.json');
    const args = ['--progress', p, '--code-stub', codeStub];
    if (runLatest) args.push('--run-latest', s.copy(path.join(FIX, runLatest), 'run-latest.json'));
    else args.push('--run-latest', path.join(s.dir, 'absent.json'));
    return { r: node(CONFIRM, args), p };
}

test('confirm: pending + matching success receipt + live code -> completed; re-run is a no-op', () => {
    const s = scratch();
    const { r, p } = confirm(s, 'progress-pending.json', 'run-latest.json', '1');
    assert.equal(r.status, 0, r.stderr);
    const j = JSON.parse(fs.readFileSync(p, 'utf8'));
    assert.equal(j.deploymentStatus, 'completed');
    assert.equal(j.contracts.AntimatterBooster.deployed, true);
    const again = node(CONFIRM, ['--progress', p, '--run-latest', path.join(s.dir, 'run-latest.json'), '--code-stub', '1']);
    assert.equal(again.status, 0);
    assert.match(again.stdout, /already confirmed/);
});

test('confirm: exit 5 when there is no code yet; file stays pending', () => {
    const s = scratch();
    const { r, p } = confirm(s, 'progress-pending.json', 'run-latest.json', '0');
    assert.equal(r.status, 5);
    assert.equal(JSON.parse(fs.readFileSync(p, 'utf8')).deploymentStatus, 'pending');
});

test('confirm: exit 4 on a receipts/progress mismatch or a missing progress; exit 2 on a failed receipt', () => {
    let s = scratch();
    assert.equal(confirm(s, 'progress-pending.json', 'run-latest-other.json', '1').r.status, 4);
    s = scratch();
    assert.equal(confirm(s, 'progress-pending.json', 'run-latest-failed.json', '1').r.status, 2);
    s = scratch();
    assert.equal(node(CONFIRM, ['--progress', path.join(s.dir, 'none.json'), '--code-stub', '1']).status, 4);
});

test('confirm: resume run (no CREATE in run-latest, or no run-latest) confirms from live code alone', () => {
    let s = scratch();
    let { r, p } = confirm(s, 'progress-pending.json', 'run-latest-resume.json', '1');
    assert.equal(r.status, 0, r.stderr);
    assert.equal(JSON.parse(fs.readFileSync(p, 'utf8')).deploymentStatus, 'completed');
    s = scratch();
    ({ r } = confirm(s, 'progress-pending.json', null, '1'));
    assert.equal(r.status, 0, r.stderr);
});
