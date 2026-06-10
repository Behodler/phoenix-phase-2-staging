#!/usr/bin/env node
/**
 * NO_STORY (replace-sya) — patch server/deployments/mainnet-addresses.ts after the
 * ReplaceSYAMainnet broadcast: rewrite the StableYieldAccumulator entry to the freshly
 * deployed skimSurplus-compatible accumulator.
 *
 * The progress file is written by script/ReplaceSYAMainnet.s.sol (vm.writeFile) with shape:
 *   { chainId, networkName, newSYA, oldSYA, nudgeSplit, setAsideBufferPercent,
 *     discountRateBps, timestamp }
 *
 * Safety:
 *   - Idempotent: exits cleanly if the entry already holds newSYA.
 *   - Aborts if the current value is neither oldSYA nor newSYA (unknown state — never
 *     silently overwrite).
 */
const fs = require("fs");
const path = require("path");

const PROGRESS = path.join(__dirname, "..", "server/deployments/progress.replace-sya.1.json");
const ADDR_FILE = path.join(__dirname, "..", "server/deployments/mainnet-addresses.ts");

function fail(code, msg) {
  console.error(`ERROR (${code}): ${msg}`);
  process.exit(code);
}

function main() {
  if (!fs.existsSync(PROGRESS)) fail(1, `Progress file not found: ${PROGRESS}`);
  const progress = JSON.parse(fs.readFileSync(PROGRESS, "utf8"));
  const { newSYA, oldSYA } = progress;
  if (!newSYA || !oldSYA) fail(2, "Progress file missing newSYA/oldSYA; refusing to patch");

  let src = fs.readFileSync(ADDR_FILE, "utf8");
  const re = /^(\s*StableYieldAccumulator:\s*")(0x[0-9a-fA-F]{40})(")/m;
  const match = src.match(re);
  if (!match) fail(3, "StableYieldAccumulator key not found in mainnet-addresses.ts");

  const current = match[2];
  if (current.toLowerCase() === newSYA.toLowerCase()) {
    console.log(`StableYieldAccumulator already set to ${newSYA}. Nothing to do.`);
    return;
  }
  if (current.toLowerCase() !== oldSYA.toLowerCase()) {
    fail(4, `StableYieldAccumulator is "${current}", expected old SYA "${oldSYA}". Aborting to avoid overwrite.`);
  }

  src = src.replace(re, `$1${newSYA}$3`);
  fs.writeFileSync(ADDR_FILE, src);
  console.log("Patched mainnet-addresses.ts StableYieldAccumulator ->", newSYA);
  console.log("  (old SYA, now deactivated:", oldSYA + ")");
}

main();
