#!/usr/bin/env node
/**
 * check-phlimbo-snapshot-age.js  (story 049 — snapshot freshness guard)
 *
 * Used by the `migrate-phlimbo-v1-to-v2:dry` and `:broadcast` npm scripts to
 * gate execution on a fresh staker snapshot.
 *
 *   --max-hours <N>      Snapshot is "stale" if its embedded `timestamp` is
 *                        older than N hours (default 24).
 *   --auto-refresh       If missing or stale, spawn the snapshot script and
 *                        wait for it to finish. Used by `:dry`.
 *   --fail-on-stale      If missing or stale, exit non-zero with a message
 *                        telling the operator to re-run `snapshot:phlimbo-v1`.
 *                        Used by `:broadcast`.
 *
 * Exactly one of --auto-refresh or --fail-on-stale must be supplied.
 *
 * The snapshot file path is fixed at
 *   scripts/snapshots/phlimbo-v1-snapshot-latest.json
 * (matches the alias the snapshot script always writes).
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const SNAPSHOT_PATH = path.join(
    __dirname,
    'snapshots',
    'phlimbo-v1-snapshot-latest.json'
);
const SNAPSHOT_SCRIPT = path.join(__dirname, 'snapshot-phlimbo-v1-stakers.js');

function parseArgs(argv) {
    const args = { maxHours: 24, autoRefresh: false, failOnStale: false };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--max-hours') {
            args.maxHours = Number(argv[++i]);
            if (!Number.isFinite(args.maxHours) || args.maxHours <= 0) {
                fail(`--max-hours must be a positive number (got ${argv[i]})`);
            }
        } else if (a === '--auto-refresh') {
            args.autoRefresh = true;
        } else if (a === '--fail-on-stale') {
            args.failOnStale = true;
        } else {
            fail(`Unknown arg: ${a}`);
        }
    }
    if (args.autoRefresh === args.failOnStale) {
        fail('Exactly one of --auto-refresh or --fail-on-stale is required');
    }
    return args;
}

function fail(msg, code = 2) {
    console.error(`[check-phlimbo-snapshot-age] ${msg}`);
    process.exit(code);
}

function snapshotAgeHours() {
    if (!fs.existsSync(SNAPSHOT_PATH)) return null;
    let raw;
    try {
        raw = fs.readFileSync(SNAPSHOT_PATH, 'utf8');
    } catch (e) {
        fail(`Cannot read ${SNAPSHOT_PATH}: ${e.message}`);
    }
    let json;
    try {
        json = JSON.parse(raw);
    } catch (e) {
        fail(`Snapshot is not valid JSON: ${e.message}`);
    }
    if (!json.timestamp) {
        fail(`Snapshot has no "timestamp" field — refusing to evaluate freshness`);
    }
    const then = Date.parse(json.timestamp);
    if (Number.isNaN(then)) {
        fail(`Snapshot timestamp is unparseable: ${json.timestamp}`);
    }
    return (Date.now() - then) / (1000 * 60 * 60);
}

function refresh() {
    console.error(`[check-phlimbo-snapshot-age] Refreshing snapshot via ${SNAPSHOT_SCRIPT} ...`);
    const result = spawnSync('node', [SNAPSHOT_SCRIPT], {
        stdio: 'inherit',
        env: process.env,
    });
    if (result.status !== 0) {
        fail(`Snapshot script exited with code ${result.status}`, result.status ?? 1);
    }
}

function main() {
    const args = parseArgs(process.argv.slice(2));
    const ageHours = snapshotAgeHours();
    const missing = ageHours === null;
    const stale = !missing && ageHours > args.maxHours;

    if (!missing && !stale) {
        console.error(
            `[check-phlimbo-snapshot-age] OK — snapshot is ${ageHours.toFixed(2)}h old ` +
                `(threshold ${args.maxHours}h).`
        );
        return;
    }

    if (args.failOnStale) {
        if (missing) {
            fail(
                `Snapshot file is missing at ${SNAPSHOT_PATH}. ` +
                    `Run \`npm run snapshot:phlimbo-v1\` before broadcasting.`
            );
        }
        fail(
            `Snapshot is ${ageHours.toFixed(2)}h old (threshold ${args.maxHours}h). ` +
                `Re-run \`npm run snapshot:phlimbo-v1\` before broadcasting.`
        );
    }

    // --auto-refresh
    if (missing) {
        console.error(
            `[check-phlimbo-snapshot-age] Snapshot missing — running snapshot script.`
        );
    } else {
        console.error(
            `[check-phlimbo-snapshot-age] Snapshot is ${ageHours.toFixed(2)}h old ` +
                `(threshold ${args.maxHours}h) — refreshing.`
        );
    }
    refresh();
}

main();
