#!/bin/bash
# simulate-yield.sh - Simulate yield for MockAutoDOLA vault by minting DOLA directly to it
#
# Usage: ./simulate-yield.sh [amount]
#   amount: DOLA amount to mint as yield (default: 2300)
#
# This increases the vault's totalAssets without minting new shares,
# effectively simulating yield for testing purposes.

set -e

# Configuration - addresses from local Anvil deployment
MOCK_DOLA="0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"
MOCK_AUTODOLA="0x610178dA211FEF7D417bC0e6FeD39F05609AD788"
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
