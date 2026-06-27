#!/usr/bin/env bash
# restore-yieldclaimnft-compat-shim.sh (phStaging2 story 070)
#
# yield-claim-nft story-039 removed the V1 `INFTMinter` interface, but the pinned
# `stable-yield-accumulator` submodule still imports `yield-claim-nft/interfaces/INFTMinter.sol`
# (using only burn()/nextIndex(), both on INFTMinterV2). This script (re)places a compat shim at
# lib/yield-claim-nft/src/interfaces/INFTMinter.sol that re-exports INFTMinterV2 as INFTMinter, so
# `forge build` succeeds. The shim lives in a submodule (untracked by the parent), so it must be
# restored after a fresh checkout or `git submodule update`.
#
# Idempotent: safe to run repeatedly. Run from the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Stored with a .txt suffix so `forge build` does not try to compile the template in place
# (its relative import only resolves once copied INTO the submodule's interfaces/ dir).
SRC="$ROOT/script/compat/INFTMinter.shim.sol.txt"
DST="$ROOT/lib/yield-claim-nft/src/interfaces/INFTMinter.sol"

if [ ! -f "$SRC" ]; then
  echo "ERROR: canonical shim not found at $SRC" >&2
  exit 1
fi

if [ ! -d "$(dirname "$DST")" ]; then
  echo "ERROR: yield-claim-nft submodule not initialized ($(dirname "$DST") missing)." >&2
  echo "Run: git submodule update --init --recursive" >&2
  exit 1
fi

cp "$SRC" "$DST"
echo "Restored INFTMinter compat shim -> $DST"
