#!/usr/bin/env bash
set -euo pipefail

# Check phUSD ERC20 balances on Balancer V3 and Uniswap V4 on mainnet

PHUSD="0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605"
BALANCER_V3_VAULT="0xbA1333333333a1BA1108E8412f11850A5C319bA9"
UNISWAP_V4_POOL_MANAGER="0x000000000004444c5dc75cB358380D2e3dE08A90"

if [ -z "${RPC_MAINNET:-}" ]; then
  echo "Error: RPC_MAINNET not set. Source your .envrc first."
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
echo ""
echo "---"
total_raw=$(echo "$balancer_raw + $uniswap_raw" | bc)
total_formatted=$(cast from-wei "$total_raw")
echo "Total phUSD across AMMs:    $total_formatted phUSD"
