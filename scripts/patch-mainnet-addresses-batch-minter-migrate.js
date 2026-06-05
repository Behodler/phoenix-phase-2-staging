#!/usr/bin/env node
/**
 * Story 057 — patch server/deployments/mainnet-addresses.ts after the batch-minter-migrate
 * broadcast. Reads the broadcast progress file and rewrites the BatchNFTMinter address entry
 * (and the NudgeBatchNFTMinter alias, if present — they are the same contract) to the freshly
 * deployed self-refund-fixed instance.
 *
 * The progress file is written by script/MigrateBatchNFTMinter.s.sol (vm.writeFile) with a flat
 * shape: { chainId, networkName, batchMinter, oldBatchMinter, usdcSeeded, donationSize, timestamp }.
 *
 * NOTE: the regex for `BatchNFTMinter` is anchored with a leading boundary (`(^|[^A-Za-z])`) so it
 * does NOT also match the `NudgeBatchNFTMinter` key (of which `BatchNFTMinter` is a substring).
 */
const fs = require("fs");
const path = require("path");

const PROGRESS = path.join(__dirname, "..", "server/deployments/progress.batch-minter-migrate.1.json");
const ADDR_FILE = path.join(__dirname, "..", "server/deployments/mainnet-addresses.ts");

function patchKey(src, key, addr) {
  // Match the key only when it is NOT preceded by a word char (so BatchNFTMinter != NudgeBatchNFTMinter).
  const re = new RegExp(`(^|[^A-Za-z])(${key}:\\s*")[^"]*(")`, "m");
  if (re.test(src)) {
    return { src: src.replace(re, `$1$2${addr}$3`), found: true };
  }
  return { src, found: false };
}

function main() {
  const progress = JSON.parse(fs.readFileSync(PROGRESS, "utf8"));
  const batchMinter = progress.batchMinter;
  if (!batchMinter) {
    throw new Error("progress file has no batchMinter address; refusing to patch");
  }

  let src = fs.readFileSync(ADDR_FILE, "utf8");

  // NudgeBatchNFTMinter first (the longer key) if present, then BatchNFTMinter (required).
  let r = patchKey(src, "NudgeBatchNFTMinter", batchMinter);
  src = r.src;
  const nudgeFound = r.found;

  r = patchKey(src, "BatchNFTMinter", batchMinter);
  src = r.src;
  const batchFound = r.found;

  if (!batchFound) {
    throw new Error("BatchNFTMinter key not found in mainnet-addresses.ts; refusing to write a malformed registry");
  }

  fs.writeFileSync(ADDR_FILE, src);
  console.log("Patched mainnet-addresses.ts BatchNFTMinter ->", batchMinter);
  console.log("  NudgeBatchNFTMinter updated:", nudgeFound);
}

main();
