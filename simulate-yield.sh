#!/bin/bash
# simulate-yield.sh - Simulate yield for MockAutoDOLA vault by minting DOLA directly to it
#
# Usage: ./simulate-yield.sh [amount]
#   amount: DOLA amount to mint as yield (default: 2300)
#
# This increases the vault's totalAssets without minting new shares,
# effectively simulating yield for testing purposes.

set -e

# Configuration - addresses read from deployment progress file
PROGRESS_JSON="$(dirname "$0")/server/deployments/progress.31337.json"
if [ ! -f "$PROGRESS_JSON" ]; then
    echo "Error: $PROGRESS_JSON not found. Run deploy:local first." >&2
    exit 1
fi
MOCK_DOLA=$(jq -r '.contracts.MockDola.address' "$PROGRESS_JSON")
MOCK_AUTODOLA=$(jq -r '.contracts.MockAutoDOLA.address' "$PROGRESS_JSON")
if [ -z "$MOCK_DOLA" ] || [ "$MOCK_DOLA" = "null" ] || [ -z "$MOCK_AUTODOLA" ] || [ "$MOCK_AUTODOLA" = "null" ]; then
    echo "Error: Could not read MockDola/MockAutoDOLA addresses from $PROGRESS_JSON" >&2
    exit 1
fi
RPC_URL="http://localhost:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

# Default amount: 2300 DOLA
AMOUNT=${1:-2300}

# Convert to wei (18 decimals)
AMOUNT_WEI="${AMOUNT}000000000000000000"

echo "Simulating yield for MockAutoDOLA vault..."
echo "  Amount: $AMOUNT DOLA"
echo "  Vault:  $MOCK_AUTODOLA"

# Get total assets before
BEFORE=$(cast call "$MOCK_AUTODOLA" "totalAssets()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}')
BEFORE_FORMATTED=$(echo "scale=2; $BEFORE / 1000000000000000000" | bc)

echo "  Total assets before: $BEFORE_FORMATTED DOLA"

# Mint DOLA directly to the vault
cast send "$MOCK_DOLA" "mint(address,uint256)" "$MOCK_AUTODOLA" "$AMOUNT_WEI" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --quiet

# Get total assets after
AFTER=$(cast call "$MOCK_AUTODOLA" "totalAssets()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}')
AFTER_FORMATTED=$(echo "scale=2; $AFTER / 1000000000000000000" | bc)

echo "  Total assets after:  $AFTER_FORMATTED DOLA"
echo "Done! Yield of $AMOUNT DOLA has been simulated."
