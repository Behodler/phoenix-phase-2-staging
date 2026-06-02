#!/bin/bash
# verify-stable-staker.sh - Story 051 end-to-end config verification for StableStaker.
#
# A configuration/smoke check (NOT a unit test): it deploys the full mock stack to a
# fresh local Anvil, stakes into the StableStaker DOLA pool (10 phUSD/day), advances
# the live chain clock by one day with `cast rpc evm_increaseTime` + `evm_mine`
# (vm.warp inside --broadcast does NOT move the live clock), then claims + withdraws
# and asserts the reward (~10 phUSD), full principal return, and totalStaked baseline
# restoration. A clean run (no reverts) IS the verification.
#
# Usage: ./verify-stable-staker.sh
#
# Mirrors the orchestration precedent of the `test:nudge-payout` npm script +
# simulate-yield.sh: spin anvil up in the background, run the flow, tear it down.

set -e

cd "$(dirname "$0")"

RPC_URL="http://localhost:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
export PATH="$HOME/.foundry/bin:$PATH"

cleanup() {
    if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        echo ""
        echo "Tearing down Anvil (pid $ANVIL_PID)..."
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=== Cleaning previous local deployment artifacts ==="
npm run clean:local

echo "=== Starting Anvil ==="
anvil --host 0.0.0.0 --port 8545 --chain-id 31337 > /tmp/anvil-stable-staker.log 2>&1 &
ANVIL_PID=$!
echo "Anvil pid: $ANVIL_PID"

# Wait for Anvil to be ready
for i in $(seq 1 30); do
    if cast block-number --rpc-url "$RPC_URL" > /dev/null 2>&1; then
        echo "Anvil is up."
        break
    fi
    sleep 1
done

echo "=== Deploying mocks (deploy:local) ==="
npm run deploy:local

echo ""
echo "=== STEP 1: Stake into StableStaker DOLA pool ==="
forge script script/interactions/StakeStableStaker.s.sol:StakeStableStaker \
    --rpc-url "$RPC_URL" --broadcast -vv

echo ""
echo "=== STEP 2: Advance chain clock by 1 day (evm_increaseTime + evm_mine) ==="
cast rpc evm_increaseTime 86400 --rpc-url "$RPC_URL"
cast rpc evm_mine --rpc-url "$RPC_URL"
echo "Advanced time by 86400s and mined a block."

echo ""
echo "=== STEP 3: Claim + Withdraw and assert results ==="
forge script script/interactions/ClaimWithdrawStableStaker.s.sol:ClaimWithdrawStableStaker \
    --rpc-url "$RPC_URL" --broadcast -vv

echo ""
echo "=== verify-stable-staker.sh: ALL ASSERTIONS PASSED ==="
