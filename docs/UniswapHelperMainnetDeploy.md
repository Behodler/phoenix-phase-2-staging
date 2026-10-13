# UniswapHelper mainnet deploy (story 111)

`src/periphery/UniswapHelper.sol` (story 109) is stateless and ownerless. Deploying it is one owner
CREATE from the Ledger. Nothing is configured afterwards, and the deployer key has no further role.

## Precondition: the pair (read this first)

The helper does **not** take the phUSD/sUSDS pair as an input. It resolves the pair at call time with
`factory.getPair(sUSDS, phUSD)`. That pair does not exist on mainnet until story 103's cutover is
broadcast at **Stage 4**. Until then:

- you can deploy and verify the helper; nothing gates the broadcast on Stage 4;
- **every swap and liquidity call through it reverts** (`PairNotFound`, or the Router02 path revert);
- the quote functions revert or return nothing useful, so the UI must not offer the mainnet Market (uni)
  tab yet.

After Stage 4, re-run `npm run uniswap-helper:verify`. It then runs the quote smoke test on every route.

## Steps

All commands run from the repo root, with `RPC_MAINNET` exported (`.envrc`) and the Ledger connected on
`m/44'/60'/46'/0/0` (OWNER `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`).

1. **Preview.** `npm run uniswap-helper:preview`
   This is a fork simulation as OWNER: nothing is signed and no progress file is written. Check that the 14
   constructor inputs it logs match the story 111 table, that it prints `Preflight OK`, and that it prints
   `OK: every immutable matches`. Before Stage 4 it also logs `pair not yet created (Stage 4 pending)`.
2. **Broadcast.** `npm run uniswap-helper:broadcast`
   It does the following, in order:
   - backs up `mainnet-addresses.ts`;
   - sends the one CREATE (legacy gas price `UNISWAP_HELPER_GAS_PRICE_WEI`, default 0.3 gwei; measured
     ~3.35M gas, so about 0.001 ETH at the default price);
   - writes `server/deployments/progress.uniswap-helper.1.json`;
   - fills the `UniswapHelper` zero placeholder in `mainnet-addresses.ts`. The patcher refuses any other
     non-zero value and re-checks the `ContractAddresses` key set;
   - runs `:verify`.
3. **Check the receipt.** `broadcast/DeployUniswapHelperMainnet.s.sol/1/run-latest.json` should show status
   `0x1` at the address the progress file names.
4. **Commit** the progress file and the patched `mainnet-addresses.ts`. Do not regenerate `mainnet-addresses.ts`:
   it is hand-maintained and the patcher has already written it. Then publish the wagmi hooks the UI
   consumes, as for any other address-book change.
5. **After Stage 4.** Run `npm run uniswap-helper:verify` again and confirm `OK: quote smoke test passed on
   every route`.

## If something goes wrong

- **Re-running is safe.** If the progress file names a helper that has code, the script re-checks that
  helper's immutables and sends nothing. Re-running the patcher with the same address prints `SAME`.
- **Progress file names an address with no code.** The address was recorded in forge's local pass but the
  transaction never landed. The script aborts. Delete the progress file and start again from step 1.
- **The patcher fails** (exit 2/3/4). The helper is deployed, but the address book is unchanged. Fix the
  reported cause, then run `node scripts/patch-mainnet-addresses-uniswap-helper.js && npm run
  uniswap-helper:verify`. Do not re-broadcast.
