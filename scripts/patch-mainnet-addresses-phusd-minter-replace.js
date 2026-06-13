#!/usr/bin/env node
/**
 * story-065 (phusd-minter-replace) — patch server/deployments/mainnet-addresses.ts after the
 * DeployNewPhusdMinter + CutoverAndRevokeOldMinter broadcasts: rewrite the PhusdStableMinter entry
 * from the old 4-field minter to the freshly deployed minter (with the daily mint cap).
 *
 * The new minter address is written by script/DeployNewPhusdMinter.s.sol (vm.writeJson) into
 *   script/migration-inputs/ys-swap-deployments.json  -> ".newMinter"
 *
 * Safety:
 *   - Idempotent: exits cleanly if the entry already holds newMinter.
 *   - Aborts if the current value is neither the known OLD minter nor newMinter (unknown state —
 *     never silently overwrite).
 *
 * NOTE (Q-REFS): this patches only the IN-REPO mainnet-addresses.ts. The phoenix-ui repo has its
 * own mainnet-addresses.ts that must be edited + redeployed separately by the operator.
 */
const fs = require("fs");
const path = require("path");

const DEPLOYMENTS = path.join(__dirname, "..", "script/migration-inputs/ys-swap-deployments.json");
const ADDR_FILE = path.join(__dirname, "..", "server/deployments/mainnet-addresses.ts");
const OLD_MINTER = "0x435B0A1884bd0fb5667677C9eb0e59425b1477E5";

function fail(code, msg) {
  console.error(`ERROR (${code}): ${msg}`);
  process.exit(code);
}

function main() {
  if (!fs.existsSync(DEPLOYMENTS)) fail(1, `Deployments file not found: ${DEPLOYMENTS}`);
  const deployments = JSON.parse(fs.readFileSync(DEPLOYMENTS, "utf8"));
  const newMinter = deployments.newMinter;
  if (!newMinter || !/^0x[0-9a-fA-F]{40}$/.test(newMinter)) {
    fail(2, "ys-swap-deployments.json missing/invalid .newMinter; run DeployNewPhusdMinter (Phase 2) broadcast first");
  }

  let src = fs.readFileSync(ADDR_FILE, "utf8");
  const re = /^(\s*PhusdStableMinter:\s*")(0x[0-9a-fA-F]{40})(")/m;
  const match = src.match(re);
  if (!match) fail(3, "PhusdStableMinter key not found in mainnet-addresses.ts");

  const current = match[2];
  if (current.toLowerCase() === newMinter.toLowerCase()) {
    console.log(`PhusdStableMinter already set to ${newMinter}. Nothing to do.`);
    return;
  }
  if (current.toLowerCase() !== OLD_MINTER.toLowerCase()) {
    fail(4, `PhusdStableMinter is "${current}", expected old minter "${OLD_MINTER}". Aborting to avoid overwrite.`);
  }

  src = src.replace(re, `$1${newMinter}$3`);
  fs.writeFileSync(ADDR_FILE, src);
  console.log("Patched mainnet-addresses.ts PhusdStableMinter ->", newMinter);
  console.log("  (old minter, now revoked:", OLD_MINTER + ")");
  console.log("  REMINDER (Q-REFS): also update + redeploy the phoenix-ui mainnet-addresses.ts.");
}

main();
