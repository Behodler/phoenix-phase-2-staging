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
 *                        telling the operator to re-run the snapshot script.
 *                        Used by `:broadcast`.
 *   --variant v1|v2      Which snapshot to gate on (default `v1`). Story 076
 *                        added `v2`, for the PhlimboV3 cutover's Phase 4e.
 *
 * Exactly one of --auto-refresh or --fail-on-stale must be supplied.
 *
 * The snapshot file path is fixed per variant to the stable `-latest.json` alias
 * the matching snapshot script always writes:
 *   v1 -> scripts/snapshots/phlimbo-v1-snapshot-latest.json
 *   v2 -> scripts/snapshots/phlimbo-v2-snapshot-latest.json
 *
 * WHY THE V2 GATE IS NOT COSMETIC (story 076). PhlimboV2 must NOT be paused for the
 * V2->V3 migration, so users can keep staking right up to the broadcast. Phase 4e
 * absorbs a user who stakes DURING the pass (it reseeds and re-runs), but it cannot
 * absorb a user whose first ever `Staked` event postdates the event scan: they are
 * simply absent from the seed list, `migrate` never visits them, and their position
 * holds `totalStaked()` above 0 -- which fails the cutover's completeness gate. A
 * fresh scan is the only thing that closes that window.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const VARIANTS = {
    v1: {
        snapshot: path.join(__dirname, 'snapshots', 'phlimbo-v1-snapshot-latest.json'),
        script: path.join(__dirname, 'snapshot-phlimbo-v1-stakers.js'),
        npmKey: 'snapshot:phlimbo-v1',
    },
    v2: {
        snapshot: path.join(__dirname, 'snapshots', 'phlimbo-v2-snapshot-latest.json'),
        script: path.join(__dirname, 'snapshot-phlimbo-v2-stakers.js'),
        npmKey: 'promotion-ready:snapshot',
    },
};

function parseArgs(argv) {
    const args = { maxHours: 24, autoRefresh: false, failOnStale: false, variant: 'v1' };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--max-hours') {
            args.maxHours = Number(argv[++i]);
            if (!Number.isFinite(args.maxHours) || args.maxHours <= 0) {
                fail(`--max-hours must be a positive number (got ${argv[i]})`);
            }
        } else if (a === '--variant') {
            args.variant = argv[++i];
            if (!VARIANTS[args.variant]) {
                fail(`--variant must be one of ${Object.keys(VARIANTS).join('|')} (got ${args.variant})`);
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

function snapshotAgeHours(snapshotPath) {
    if (!fs.existsSync(snapshotPath)) return null;
    let raw;
    try {
        raw = fs.readFileSync(snapshotPath, 'utf8');
    } catch (e) {
        fail(`Cannot read ${snapshotPath}: ${e.message}`);
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

function refresh(scriptPath) {
    console.error(`[check-phlimbo-snapshot-age] Refreshing snapshot via ${scriptPath} ...`);
    const result = spawnSync('node', [scriptPath], {
        stdio: 'inherit',
        env: process.env,
    });
    if (result.status !== 0) {
        fail(`Snapshot script exited with code ${result.status}`, result.status ?? 1);
    }
}

function main() {
    const args = parseArgs(process.argv.slice(2));
    const variant = VARIANTS[args.variant];
    const ageHours = snapshotAgeHours(variant.snapshot);
    const missing = ageHours === null;
    const stale = !missing && ageHours > args.maxHours;

    if (!missing && !stale) {
        console.error(
            `[check-phlimbo-snapshot-age] OK — ${args.variant} snapshot is ${ageHours.toFixed(2)}h old ` +
                `(threshold ${args.maxHours}h).`
        );
        return;
    }

    if (args.failOnStale) {
        if (missing) {
            fail(
                `Snapshot file is missing at ${variant.snapshot}. ` +
                    `Run \`npm run ${variant.npmKey}\` before broadcasting.`
            );
        }
        fail(
            `Snapshot is ${ageHours.toFixed(2)}h old (threshold ${args.maxHours}h). ` +
                `Re-run \`npm run ${variant.npmKey}\` before broadcasting.`
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
    refresh(variant.script);
}

main();
