#!/bin/bash
# dev-local.sh - honest orchestration for the local dev stack (`npm run dev`).
#
# Story 081, script-audit run-28 M-01. The old `dev` key was two CONCURRENT shell
# pipelines rather than one sequence: `&` binds looser than `&&`, so
# `npm run clean:local && npm run start:anvil` was backgrounded AS A UNIT and its exit
# status discarded, while the foreground chain starting at `sleep 3` ran regardless of
# whether anvil ever bound the port. Nothing probed 8545, and nothing checked WHICH node
# was answering. A leftover anvil - the state a Ctrl-C out of `npm run serve` reliably
# leaves behind - therefore absorbed the entire mainnet-cutover rehearsal silently, and
# the resulting progress.31337.json was indistinguishable from a good run.
#
# This script is the shell-side half of the fix; the Solidity-side half is the deployer
# nonce require in script/DeployMocks.s.sol:run(). They are independent: this one refuses
# to START next to a foreign node, that one refuses to DEPLOY onto a dirty chain.
#
# Usage: ./dev-local.sh   (or `npm run dev`)
#
# Mirrors verify-stable-staker.sh's orchestration precedent: cd to the repo root, own the
# anvil we start, poll it for readiness, tear it down on the way out.

# `set -e` alone is what the two existing root scripts use, but the whole defect being
# fixed here IS a discarded exit status, so failure propagation is load-bearing:
# -E propagates the ERR trap, -u catches an unset variable, -o pipefail keeps a failure
# in the middle of a pipeline from being masked by a successful tail.
set -Eeuo pipefail

cd "$(dirname "$0")"

RPC_URL="http://localhost:8545"
export PATH="$HOME/.foundry/bin:$PATH"

ANVIL_PID=""

cleanup() {
    if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        echo ""
        echo "Tearing down Anvil (pid $ANVIL_PID)..."
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
}
# EXIT alone is not enough: the failure mode this script exists to prevent is created by
# Ctrl-C out of `npm run serve`, which is a SIGINT, and the stale node it leaves behind is
# what poisons the NEXT run.
trap cleanup EXIT INT TERM

echo "=== Pre-flight: checking nothing already owns $RPC_URL ==="
if cast block-number --rpc-url "$RPC_URL" > /dev/null 2>&1; then
    echo "Error: something is already answering on $RPC_URL." >&2
    echo "       A leftover node would silently absorb this deployment and every" >&2
    echo "       post-condition would still pass. Kill it (pkill anvil) and re-run." >&2
    exit 1
fi
echo "Port is free."

echo ""
echo "=== Cleaning previous local deployment artifacts ==="
# Run ONCE, here, before anvil starts. deploy:local:forge deliberately does not clean:
# cleaning after anvil is up deletes the broadcast/*/31337 directory that the very next
# forge script writes into.
npm run clean:local

echo ""
echo "=== Starting Anvil ==="
# Started DIRECTLY, not via `npm run start:anvil`, so that $! is anvil's own pid: the npm
# wrapper's pid would make the listener comparison below meaningless and would survive the
# trap. Flags are byte-identical to the start:anvil key, which stays as-is for standalone use.
anvil --host 0.0.0.0 --port 8545 --chain-id 31337 --block-time 2 &
ANVIL_PID=$!
echo "Anvil pid: $ANVIL_PID"

echo "Waiting for Anvil to answer on $RPC_URL ..."
ANVIL_UP=false
for i in $(seq 1 30); do
    if ! kill -0 "$ANVIL_PID" 2>/dev/null; then
        echo "Error: Anvil (pid $ANVIL_PID) died during startup. See the output above." >&2
        exit 1
    fi
    if cast block-number --rpc-url "$RPC_URL" > /dev/null 2>&1; then
        ANVIL_UP=true
        echo "Anvil is up."
        break
    fi
    sleep 1
done

if [ "$ANVIL_UP" != "true" ]; then
    echo "Error: Anvil never answered on $RPC_URL after 30s." >&2
    exit 1
fi

echo ""
echo "=== Confirming the node on 8545 is the Anvil we started ==="
# Belt and braces on top of the pre-flight: if some other process grabbed the port in the
# race window, we must not deploy onto it. A machine with neither ss nor lsof cannot answer
# the question at all - warn rather than fail, since the Solidity nonce require is the
# authoritative gate and still runs.
LISTENER_PID=""
if command -v ss > /dev/null 2>&1; then
    LISTENER_PID="$(ss -lptnH 'sport = :8545' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)"
elif command -v lsof > /dev/null 2>&1; then
    LISTENER_PID="$(lsof -t -iTCP:8545 -sTCP:LISTEN 2>/dev/null | head -1 || true)"
fi

if [ -z "$LISTENER_PID" ]; then
    echo "Warning: neither ss nor lsof could name the process listening on 8545; skipping" >&2
    echo "         the ownership check. The deployer-nonce require in DeployMocks still guards" >&2
    echo "         against deploying onto a dirty chain." >&2
elif [ "$LISTENER_PID" != "$ANVIL_PID" ]; then
    echo "Error: port 8545 is owned by pid $LISTENER_PID, not the Anvil we started ($ANVIL_PID)." >&2
    echo "       Refusing to deploy onto a node this script does not control." >&2
    exit 1
else
    echo "Confirmed: pid $ANVIL_PID owns 8545."
fi

# Block-height sanity check. The audit drafted `> 5`, which false-positives: anvil runs at
# --block-time 2 and the readiness loop above allows up to 30s, so a slow start can legitimately
# mine well past block 5. The threshold here sits clear of that whole window and only fires on a
# chain that has genuinely been running for a while.
BLOCK_NUMBER="$(cast block-number --rpc-url "$RPC_URL")"
echo "Block number at hand-off: $BLOCK_NUMBER"
if [ "$BLOCK_NUMBER" -gt 100 ]; then
    echo "Error: the node on $RPC_URL is at block $BLOCK_NUMBER - that is not a chain we just" >&2
    echo "       started. Kill it (pkill anvil) and re-run." >&2
    exit 1
fi

echo ""
echo "=== Deploying mocks ==="
LOCAL_PROMO_KENDU=true npm run deploy:local:forge

echo ""
echo "=== Simulating yield ==="
./simulate-yield.sh

echo ""
echo "=== Extracting addresses ==="
npm run extract:addresses

echo ""
echo "=== Generating TypeScript addresses ==="
npm run generate:ts-anvil

echo ""
echo "=== Starting API server (Ctrl-C to stop; Anvil is torn down with it) ==="
npm run serve
