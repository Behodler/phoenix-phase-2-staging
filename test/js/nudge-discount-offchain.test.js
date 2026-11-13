// Story 119 - off-chain helpers of the nudge-discount cutover, tested on SCRATCH COPIES only.
// Run: node --test test/js/nudge-discount-offchain.test.js   (npm run test:nudge-discount-offchain)
//
// Never touches server/deployments/mainnet-addresses.ts, script/helpers/PauserV2Registry.sol or the real progress
// file: every case copies them (or the fixtures in test/fixtures/nudge-discount/) into a fresh temp dir. `cast code`
// is stubbed (--code-stub) and the patcher's on-chain gate is skipped (--skip-chain-check), so no RPC is needed.
// `cast` itself must be on PATH (checksumming).

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.join(__dirname, '..', '..');
const FIX = path.join(ROOT, 'test', 'fixtures', 'nudge-discount');
const PATCHER = path.join(ROOT, 'scripts', 'patch-mainnet-addresses-nudge-discount.js');
const CONFIRM = path.join(ROOT, 'scripts', 'confirm-nudge-discount-progress.js');
const QUOTE = path.join(ROOT, 'scripts', 'quote-nudge-discount-buy-and-burn.js');
const BOOK = path.join(ROOT, 'server', 'deployments', 'mainnet-addresses.ts');
const REGISTRY = path.join(ROOT, 'script', 'helpers', 'PauserV2Registry.sol');

const NEW = '0x1111111111111111111111111111111111111119';
const OLD = '0x068395556b8c43eDf257DC54D109EA5910aE15c7';

function scratch() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'story119-'));
    const copy = (src, name) => {
        const dst = path.join(dir, name || path.basename(src));
        fs.copyFileSync(src, dst);
        return dst;
    };
    return { dir, copy };
}

function node(script, args, env = {}) {
    const e = { ...process.env, ...env };
    delete e.RPC_MAINNET;
    delete e.MAINNET_RPC_URL;
    Object.assign(e, env);
    return spawnSync('node', [script, ...args], { encoding: 'utf8', env: e });
}

function patch(s, { progress = 'progress-completed.json', runLatest = 'run-latest.json', book, registry } = {}) {
    const p = s.copy(path.join(FIX, progress), 'progress.json');
    const r = s.copy(path.join(FIX, runLatest), 'run-latest.json');
    return node(PATCHER, [
        '--progress', p, '--run-latest', r, '--addresses', book, '--registry', registry, '--no-backup', '--skip-chain-check',
    ]);
}

function fnBody(src, name) {
    const m = src.match(new RegExp(`function ${name}\\(\\)[^{]*\\{([\\s\\S]*?)\\n\\s*\\}`));
    return m[1];
}

// ------------------------------------------------------------------ patcher

test('patcher: fills the zero placeholder, keeps BatchNFTMinter, appends registry entries, re-run is a no-op', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    const registry = s.copy(REGISTRY);
    const bookBefore = fs.readFileSync(book, 'utf8');
    const regBefore = fs.readFileSync(registry, 'utf8');
    assert.match(bookBefore, /\n {2}NudgeDiscountBatchMinter: "0x0{40}"/, 'fixture precondition: zero placeholder');

    const r = patch(s, { book, registry });
    assert.equal(r.status, 0, r.stderr + r.stdout);
    const after = fs.readFileSync(book, 'utf8');
    assert.match(after, new RegExp(`\\n  NudgeDiscountBatchMinter: "${NEW}"`, 'i'));
    assert.match(after, new RegExp(`\\n  BatchNFTMinter: "${OLD}"`), 'old BatchNFTMinter untouched');
    assert.match(after, /^\/\/ Updated \d{4}-\d{2}-\d{2}: nudge-discount minter cutover \(story 119\)/m, 'dated header');
    assert.equal(after.split('\n').length - bookBefore.split('\n').length, 2, 'header line + one extra comment line only');

    const reg = fs.readFileSync(registry, 'utf8');
    const adds = fnBody(reg, 'postMigrationAdditions');
    const rems = fnBody(reg, 'postMigrationRemovals');
    assert.match(adds, /0xE5983721f009AB57d464e611C9A06B148cEC3Acc; \/\/ NFTBonfire \(story 129\)/, '129 entry kept');
    assert.match(adds, /0x9d69c68F354575B95c1ebf7E87DB85BF3BFF2cE8;/, '131 entry kept');
    assert.match(adds, new RegExp(`a\\[2\\] = ${NEW}; // BatchNFTMinterNudgeDiscount \\(story 119\\)`, 'i'));
    assert.match(adds, /a = new address\[\]\(3\);/);
    assert.match(rems, /0x0cD353bfda674D04823B2826ffafB83B560D21B6;/, '131 removal kept');
    assert.match(rems, new RegExp(`a\\[1\\] = ${OLD}; // BatchNFTMinterMultiToken, retired \\(story 119\\)`));
    assert.match(rems, /a = new address\[\]\(2\);/);
    assert.notEqual(reg, regBefore);

    const again = patch(s, { book, registry });
    assert.equal(again.status, 0, again.stderr);
    assert.equal(fs.readFileSync(book, 'utf8'), after, 'book unchanged on re-run');
    assert.equal(fs.readFileSync(registry, 'utf8'), reg, 'registry unchanged on re-run');
    assert.match(again.stdout, /SAME/);
});

test('patcher: refuses a non-zero existing value (COLLIDE) and writes nothing', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    const registry = s.copy(REGISTRY);
    const other = fs
        .readFileSync(book, 'utf8')
        .replace(/(\n {2}NudgeDiscountBatchMinter: )"0x0{40}"/, '$1"0x3333333333333333333333333333333333333333"');
    fs.writeFileSync(book, other);
    const regBefore = fs.readFileSync(registry, 'utf8');
    const r = patch(s, { book, registry });
    assert.equal(r.status, 4);
    assert.match(r.stderr, /COLLIDE/);
    assert.equal(fs.readFileSync(book, 'utf8'), other);
    assert.equal(fs.readFileSync(registry, 'utf8'), regBefore);
});

test('patcher: refuses deploymentStatus != completed', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    const registry = s.copy(REGISTRY);
    const r = patch(s, { progress: 'progress-pending.json', book, registry });
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
    const book = s.copy(BOOK);
    const r = patch(s, { runLatest: 'run-latest-resume.json', book, registry: s.copy(REGISTRY) });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /resume-only run/);
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
    assert.equal(j.contracts.NudgeDiscountBatchMinter.deployed, true);
    assert.deepEqual(j.baseline.buffer, [1075752886, 0, 0], 'baseline preserved');
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
    const r = node(CONFIRM, ['--progress', path.join(s.dir, 'none.json'), '--code-stub', '1']);
    assert.equal(r.status, 4);
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

test('confirm: exit 5 when RPC_MAINNET is unset and no stub is given', () => {
    const s = scratch();
    const p = s.copy(path.join(FIX, 'progress-pending.json'), 'progress.json');
    const r = node(CONFIRM, ['--progress', p, '--run-latest', s.copy(path.join(FIX, 'run-latest.json'))]);
    assert.equal(r.status, 5);
    assert.match(r.stderr, /RPC_MAINNET unset/);
});

// ------------------------------------------------------------------ quote helper (no RPC paths)

test('quote: refuses the zero book entry before touching the RPC, printing nothing on STDOUT', () => {
    const r = node(QUOTE, ['all', '50']); // real book: still the zero placeholder; RPC env removed
    assert.notEqual(r.status, 0);
    assert.equal(r.stdout, '');
    assert.match(r.stderr, /zero placeholder/);
});

test('quote: tolerance must be an integer 1..100; amount must be an integer or "all"', () => {
    for (const args of [['all', '0'], ['all', '101'], ['all', '1.5'], ['abc'], ['0'], []]) {
        const r = node(QUOTE, args);
        assert.notEqual(r.status, 0, `args ${JSON.stringify(args)}`);
        assert.equal(r.stdout, '');
    }
});

test('quote: a non-zero book entry with no RPC configured fails closed', () => {
    const s = scratch();
    const book = s.copy(BOOK);
    fs.writeFileSync(
        book,
        fs.readFileSync(book, 'utf8').replace(/(\n {2}NudgeDiscountBatchMinter: )"0x0{40}"/, `$1"${NEW}"`)
    );
    const r = node(QUOTE, ['all', '50', '--address-book', book]);
    assert.notEqual(r.status, 0);
    assert.equal(r.stdout, '');
    assert.match(r.stderr, /RPC_MAINNET/);
});
