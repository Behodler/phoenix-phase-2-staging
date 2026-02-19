#!/bin/bash
read -p "How many ETH units of phUSD to mint? " AMOUNT

if [ -z "$AMOUNT" ]; then
    echo "Error: No amount provided"
    exit 1
fi

echo "Minting $AMOUNT phUSD (${AMOUNT}e18 wei) on mainnet..."
echo ""

rm -rf broadcast/MintPhUSDMainnet.s.sol

forge script script/interactions/MintPhUSDMainnet.s.sol:MintPhUSDMainnet \
    --sig "run(uint256)" "$AMOUNT" \
    --rpc-url "$RPC_MAINNET" \
    --broadcast --skip-simulation --slow \
    --ledger --hd-paths "m/44'/60'/46'/0/0" \
    -vvv
