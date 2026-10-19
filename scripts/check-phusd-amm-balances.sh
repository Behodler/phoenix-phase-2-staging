#!/usr/bin/env bash
set -euo pipefail

# Check phUSD ERC20 balances on Balancer V3, Uniswap V4 and the phUSD/sUSDS Uniswap V2 pair on mainnet

PHUSD="0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605"
BALANCER_V3_VAULT="0xbA1333333333a1BA1108E8412f11850A5C319bA9"
UNISWAP_V4_POOL_MANAGER="0x000000000004444c5dc75cB358380D2e3dE08A90"
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

# Story 105: the phUSD/sUSDS V2 pair is read from the hand-maintained address book. It stays the zero
# placeholder until the Stage 4 cutover is patched in, and is skipped (not counted) until then.
ADDRESS_BOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/server/deployments/mainnet-addresses.ts"

if [ -z "${RPC_MAINNET:-}" ]; then
  echo "Error: RPC_MAINNET not set. Source your .envrc first."
  exit 1
fi

if [ ! -f "$ADDRESS_BOOK" ]; then
  echo "Error: address book not found at $ADDRESS_BOOK"
  exit 1
fi

phusd_susds_pair=$(grep -oE '^  PhusdSusdsPair: "0x[0-9a-fA-F]{40}"' "$ADDRESS_BOOK" | grep -oE '0x[0-9a-fA-F]{40}' || true)
if [ -z "$phusd_susds_pair" ]; then
  echo "Error: PhusdSusdsPair key not found in $ADDRESS_BOOK"
  exit 1
fi

echo "Querying phUSD balances on mainnet AMMs..."
echo ""

balancer_raw=$(cast call "$PHUSD" "balanceOf(address)(uint256)" "$BALANCER_V3_VAULT" --rpc-url "$RPC_MAINNET" | awk '{print $1}')
uniswap_raw=$(cast call "$PHUSD" "balanceOf(address)(uint256)" "$UNISWAP_V4_POOL_MANAGER" --rpc-url "$RPC_MAINNET" | awk '{print $1}')

balancer_formatted=$(cast from-wei "$balancer_raw")
uniswap_formatted=$(cast from-wei "$uniswap_raw")

echo "Balancer V3 Vault:          $balancer_formatted phUSD"
echo "Uniswap V4 PoolManager:     $uniswap_formatted phUSD"

v2_pair_raw=0
if [ "$(echo "$phusd_susds_pair" | tr '[:upper:]' '[:lower:]')" = "$ZERO_ADDRESS" ]; then
  echo "phUSD/sUSDS V2 pair:        skipped (PhusdSusdsPair is the zero placeholder - Stage 4 cutover not patched yet)"
else
  v2_pair_raw=$(cast call "$PHUSD" "balanceOf(address)(uint256)" "$phusd_susds_pair" --rpc-url "$RPC_MAINNET" | awk '{print $1}')
  v2_pair_formatted=$(cast from-wei "$v2_pair_raw")
  echo "phUSD/sUSDS V2 pair:        $v2_pair_formatted phUSD ($phusd_susds_pair)"
fi

echo ""
echo "---"
total_raw=$(echo "$balancer_raw + $uniswap_raw + $v2_pair_raw" | bc)
total_formatted=$(cast from-wei "$total_raw")
echo "Total phUSD across AMMs:    $total_formatted phUSD"
