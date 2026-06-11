## Background
phUSD is live on mainnet. It can be minted with Dola or USDC at 1:1. The minter deposits either token into corresponding yield strategies (AutoPoolYieldStrategy) which wraps Tokemak (now AutoFinance) vaults of each respective token.

Dola lost its peg briefly, falling to 1c. This essentially allowed people to briefly mint phUSD for free.

On Balancer, we have an E-CLP pool of sUSDS/phUSD. At attacker minted 6984 phUSD using 6984 Dola and immediately sold for sUSDS on the pool, sending the pool out of range.

The credit to this debit is that our TVL increased by 6984 Dola in the yield strategy. The good news is that Dola peg restored.

So the net effect is that our spread of external capital has skewd from zero in LP to 100% in yield strategy. The net result is that user can't sell their phUSd.

As a result, I triggered the Pauser by burning 1000 EYE to pause the entire set of contracts.


## Suggested fix (high level)
I (the owner account) would like to remove 6984 Dola from the Dola AutoPoolYieldStrategy. Then I want to sell the Dola removed for sUSDS and use that to purchase phUSD on Balancer. The e-CLP pool isn't symmetric so the net price effect won't be zero but it's good enough. Then I want to burn the purchased phUSD, effectively undoing the exploit. When I withdraw the Dola, I don't want to corrupt the internal accounting of the Autopool. The safest way to do that is to withdraw the entire amount through the stable-minter contract. Then send away the 6984 and then perform a noMintDeposit of the remainder to ensure no new phUSD is minted.

I have 2 accounts, owner at address 0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6 which is indexed on my ledger as 46. You can see this being used throughout many scripts in package.json.

The other account is the Balancer LP end user account, 0x64d3CbAB6100782a7839fC1af791027a2f1908D2. This is the account to which I'd like to send the 6984.

## Bugs and blockers discovered

### minter.withdraw has a bug
`PhusdStableMinter.withdraw(yieldStrategy, recipient)` passes `recipient` directly to `yieldStrategy.withdraw(token, amount, recipient)`. But the YS uses `recipient` both as the `clientBalances` lookup key AND the token destination. Since principal is tracked under the minter's address (`clientBalances[DOLA][minter]`), passing any external address as recipient finds 0 balance and withdraws nothing. This makes `minter.withdraw` unusable for extracting funds to an external address.

**Workaround**: Use `yieldStrategy.emergencyWithdraw(amount)` (owner-only) which bypasses clientBalances entirely and sends DOLA directly to `owner()`.

### AutoDOLA vault was paused (resolved)
The external AutoDOLA vault (0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d) was paused by Tokemak/AutoFinance, blocking all share transfers. This has since been resolved.

### convertToShares truncation
The AutoDOLA vault's `convertToShares` truncates, causing minor discrepancies (~0.075 DOLA) between deposited amount and reported TVL immediately after deposit. This is cosmetic and does not affect actual value held.

### Solution: Deploy fresh AutoPoolYieldStrategy
Instead of redepositing into the old YS (which would carry over stale clientBalances), deploy a brand new AutoPoolYieldStrategy with clean accounting. The old YS remains paused and is abandoned.

## Implemented approach

Script: `script/interactions/governance/RebalanceTVL.s.sol`

The script is a multi-tx Foundry script (not atomic — each call is a separate ledger signature). Forge simulates before broadcasting, so it fails without spending gas if any step reverts.

### Pre-conditions
- AutoDOLA vault must be unpaused by Tokemak/AutoFinance (confirmed)
- Owner account has gas for ~20 transactions

### Steps

**Phase 1: Emergency withdraw from old YS**
1. Old YS: setPauser to owner (to unpause without EYE burn)
2. Unpause old YS
3. oldYS.emergencyWithdraw(tvlBefore) — sends all DOLA to owner, bypasses clientBalances
4. Pause old YS (discarded, leave pauser as owner)
5. Send 6984 DOLA to Balancer LP account (0x64d3CbAB6100782a7839fC1af791027a2f1908D2)

**Phase 2: Deploy and configure new YS**
6. Minter: setPauser to owner, unpause (needed for noMintDeposit)
7. Deploy new AutoPoolYieldStrategy (same constructor params: owner, DOLA, TOKE, AutoDOLA vault, MainRewarder)
8. New YS: setClient(minter, true)
9. Minter: registerStablecoin(DOLA, newYS, 1e18, 18) — overwrites old mapping
10. Minter: approveYS(DOLA, newYS)
11. Minter: noMintDeposit(newYS, DOLA, remainder) — deposit all remaining DOLA

**Phase 3: Accumulator swap**
12. Accumulator: removeYieldStrategy(oldYS)
13. Accumulator: addYieldStrategy(newYS, DOLA)
14. New YS: setWithdrawer(accumulator, true)

**Phase 4: Pause and restore pauser state**
15. New YS: setPauser to owner (constructor leaves _pauser as address(0))
16. Pause new YS
17. New YS: setPauser to global pauser
18. Pause minter
19. Minter: setPauser to original global pauser

**Phase 5: Global pauser registration**
20. GlobalPauser: register(newYS) (requires newYS.pauser() == globalPauser)
21. GlobalPauser: unregister(oldYS) (requires oldYS.pauser() != globalPauser)

**Phase 6: Update external references (manual)**
22. Update mainnet-addresses.ts with new YS address
23. Update Phoenix UI with new address

### Post-flight verification (automated in script)
- New YS principal ~= remainder (clean accounting, within 1 DOLA of TVL)
- New YS TVL ~= old TVL - 6984 DOLA (within 50 DOLA tolerance for truncation)
- Balancer LP account received exactly 6984 DOLA
- All contracts re-paused
- Pausers restored to global pauser

### npm scripts
- `npm run mainnet:rebalance-tvl-dry` — dry run against mainnet (no broadcast, no Ledger)
- `npm run mainnet:rebalance-tvl` — live broadcast via Ledger index 46