# BatchNFTMinter — Self-Refund Bug: Fix & Migration Plan

**Status:** Draft for review — no code written, nothing broadcast.
**Author:** investigation 2026-06-04.
**Scope:** Fix the nudge self-refund bug in `BatchNFTMinter`, deploy a patched
instance, and migrate the two live funding paths over to it.

---

## 1. TL;DR

The live `BatchNFTMinter` (`0x6e9886Af…445071`, deployed today under story 056)
pays the nudge reward by reading its **full** `nudgePaymentToken` (USDC) balance
*after* the mint loop. Because the index-4 `BalancerPoolerV2` donates USDC into
that same contract **during** each mint, a 40-batcher's own donation is included
in their own payout and refunded to them.

**Scope of the bug (confirmed with owner):** the defect is *only* the per-mint
donation round-tripping back to the minter — **minting NFTs never tops up the pot
for the next person.** The separate behaviour where a 40-batcher scoops the
*pre-existing* pot (funded by SYA's 30% claim `nudgeSplit` + prior accumulation)
is the **intended** nudge incentive and is fine — it is NOT part of this bug. The
fix preserves that incentive; it only stops the self-refund.

- **Fix:** snapshot the pot **before** the mint loop (one-block move in
  `BatchNFTMinter.batchMint`). One-line logical change, localized to the
  `nft-staking` submodule. No pooler or minter change required.
- **Migration is SAFE and low-risk.** `BatchNFTMinter` is a peripheral helper:
  no user funds, no NFT ownership, no staking positions, no mint-debt accounting,
  no minter role. Its only persistent value is the rescuable USDC pot. Only two
  owner-settable pointers reference it. **No show-stoppers found.**
- **Two funding paths must be repointed** (both owner-gated, owner = the single
  ledger signer `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`):
  1. `BalancerPoolerV2.setBatchMinter(new)` on `0x7f74388b…786b`
  2. `StableYieldAccumulator.setNudgeAddress(new)` on `0x3bBE92…7606a`

---

## 2. The bug

### 2.1 Root cause (code)

`lib/nft-staking/src/BatchNFTMinter.sol`, `batchMint()`:

```solidity
for (uint256 i; i < count; ++i) {
    nftMinter.mint(_dispatcherIndex, recipient);   // L257-259: each mint → pooler._dispatch → PSM donates USDC INTO this contract
}
paymentToken.forceApprove(address(nftMinter), 0);
...
if (_nudgeSize != 0 && count >= _nudgeSize && _nudgeTokenEntry != address(0)) {
    nudgeAmount = IERC20(_nudgeTokenEntry).balanceOf(address(this));  // L271: reads balance AFTER the loop
}
...
IERC20(_nudgeTokenEntry).safeTransfer(recipient, nudgeAmount);        // L283: pays whole balance to the batcher
```

The index-4 `BalancerPoolerV2._dispatch` (`lib/yield-claim-nft/src/V2/dispatchers/BalancerPoolerV2.sol`)
performs a `batchDonationSize` (10%) USDS→USDC PSM `buyGem` **synchronously on
every mint**, delivering USDC straight to its configured `batchMinter`. So by the
time `batchMint` reads `balanceOf` at L271, the pot already contains the current
batch's donations — which are then handed back to the batcher.

### 2.2 On-chain evidence

Tx `0x6d71d6fd…f14996` (block 25242986), caller `0x0f92282a…24aa9`, 40 mints:

| | USDC |
|---|---|
| Pot before the batch (prior minters' donations + SYA `nudgeSplit` + migration seed) | 88.066035 |
| This batch's 40 donations (40 × `BatchDonatedViaPSM`, **zero** `DonationSkipped`) | +51.765728 |
| Pot when nudge reads `balanceOf` | 139.831763 |
| Paid to batcher `0x0f92…24aa9` | −139.831763 |
| **Net to batcher** | **+88.07 (prior pot); their own 51.77 round-tripped back** |
| Pot left for the *next* minter | **0** |

The 0.00000039 USDS still parked on the pooler is expected PSM floor-rounding
dust, **not** a silent donation failure. `batchDonationSize` is `10`, not `0`.

This is **not** the historical fake-mint drain — these were 40 real, paid mints
through the real dispatcher. It is a new bug created by today's wiring, in which
the donation now flows *into the same contract that pays the nudge*, in one tx.

---

## 3. The fix

Snapshot the deliverable nudge amount **before** the mint loop, so the current
batch's donations stay in the contract for the next claimant.

```solidity
// --- BEFORE the loop ---
uint256 _nudgeSize = nudgeSize;
uint256 nudgeAmount;
if (_nudgeSize != 0 && count >= _nudgeSize && _nudgeTokenEntry != address(0)) {
    nudgeAmount = IERC20(_nudgeTokenEntry).balanceOf(address(this));   // pot from PRIOR minters only
}

paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
paymentToken.forceApprove(address(nftMinter), type(uint256).max);
for (uint256 i; i < count; ++i) {
    nftMinter.mint(_dispatcherIndex, recipient);                       // this batch's donations accumulate for the NEXT minter
}
paymentToken.forceApprove(address(nftMinter), 0);

// --- minReward floor + payout use the pre-loop snapshot (unchanged below) ---
if (nudgeAmount < minReward) revert BatchMint__RewardBelowMinimum(minReward, nudgeAmount);
if (nudgeAmount != 0) { IERC20(_nudgeTokenEntry).safeTransfer(recipient, nudgeAmount); emit NudgePaid(...); }
```

### Why this is correct and safe

- **Nudge token (USDC) ≠ payment token (USDS)**, so reading the USDC balance
  before the USDS `safeTransferFrom` pull is stable — the snapshot is unaffected
  by the payment pull.
- `minReward` now compares against the amount the caller will *actually* receive
  (the prior pot), which is strictly more correct than the post-loop reading.
- The dust-refund sweep at the end is in **USDS** (payment token) and never
  touched USDC, so it is unaffected.
- Net economic change: a 40-batcher receives only **prior** accumulated
  donations; their own 40 donations seed the next batcher. Exactly the intended
  "donate forward" mechanic.

### Intended behaviour preserved (not a blocker)

The nudge remains "first to reach `nudgeSize` takes the whole prior pot," which
the owner has confirmed is the desired incentive. After the fix a batcher can no
longer recover their *own* donation within one tx, so their mint genuinely tops up
the pot for the next person. A batcher scooping the pre-existing pot is expected
and acceptable — no epoch / own-contribution accounting is wanted.

### Implementation (TDD, when approved — currently deferred per owner)

1. New regression test in `lib/nft-staking/test/BatchNFTMinterNudge.t.sol`:
   simulate a donation landing *during* the mint loop (mock minter that transfers
   nudge-token into the BatchNFTMinter on each `mint`) and assert the batcher is
   paid only the **pre-loop** balance, with the loop's donation remaining in the
   contract. Red against current code.
2. Move the snapshot before the loop. Green.
3. `forge test` in `lib/nft-staking`; regenerate `remappings.txt` if touched.

---

## 4. Migration surface — what references the batchMinter

| Reference | Location | Type | Action |
|---|---|---|---|
| `BalancerPoolerV2.batchMinter` | pooler `0x7f74388b…786b` storage | **Funding path 1** (10% USDS→USDC PSM donation per mint) | `setBatchMinter(new)` — owner `0xCad1` |
| `StableYieldAccumulator.nudge` | SYA `0x3bBE92…7606a` storage (`nudgeSplit=30`) | **Funding path 2** (30% of each `claim()` payment in USDC) | `setNudgeAddress(new)` — owner `0xCad1` |
| `BatchNFTMinter` address | `server/deployments/mainnet-addresses.ts:96` | UI/hooks source of truth | edit → regenerate + republish wagmi hooks |
| `NFTMinterV2.mint(index,recipient)` | called by BatchNFTMinter L258 | **permissionless** (only `mintFor` gates on `authorizedMinters`) | **none** — new minter needs no authorization ✅ |

Nothing else in the protocol points at the BatchNFTMinter. It is a *caller* of the
minter, not a *callee* — no dispatcher, hook, staker, or phUSD-minter wiring
depends on its address.

### Current live config to mirror on the new instance

- `tokenMinter`        = `0x39Af088408e815844c567037C157B31d48d2E10F` (NFTMinterV2)
- `dispatcherIndex`    = `4`
- `nudgeSize`          = `40`
- `nudgePaymentToken`  = `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC)
- `pauser`             = `0x0` (no pauser set on the current instance)
- `owner`              = `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`

**Decision point:** wire the global Pauser on the new instance (recommended) vs.
leave `pauser = 0` to match current. Setting a pauser also makes the *old*
instance pausable, which helps close the drain window in §6.

---

## 5. Is the upgrade safe? Show-stopper analysis

**Verdict: SAFE. No show-stoppers.** Reasons:

1. **No state to migrate** beyond the USDC pot. No user balances, no ERC1155
   ownership, no staking principal, no accrual/`rewardDebt`. The pot is fully
   recoverable via `rescueERC20` (owner).
2. **Permissionless mint.** The new instance calls the public `mint`, so it needs
   no allowlisting on `NFTMinterV2`. (Verified: only `mintFor`/burn paths gate on
   `authorizedMinters`/`authorizedBurners`.)
3. **Both funding pointers are owner-settable**, controlled by the same single
   ledger key that owns the pooler, SYA, and BatchNFTMinter (`0xCad1`).
4. **Config invariant preserved:** `nudgePaymentToken` (USDC) ≠ derived
   `paymentToken` (USDS), so the `BatchMint__NudgeTokenMatchesPaymentToken` guard
   never trips.
5. **Fully reversible.** Every step is an owner call; pointers can be set back.

Residual risks (manageable, see §6):
- **Drain window:** while the *old* instance still holds USDC and is callable,
  a 40-batch can claim its residual. Mitigated by repointing funding first and/or
  pausing the old instance before rescuing.
- **UI cutover:** the UI/hooks must be updated to the new address or batches will
  keep hitting the old (now-defunded) instance. Harmless to funds, but mints would
  route to an instance that no longer receives donations.

---

## 6. Migration runbook (order matters)

Do the on-chain steps in a single owner-signed Foundry broadcast (mirror the
story-056 ledger pattern: `PREVIEW_MODE=true` dry run, then `--ledger --hd-paths`
broadcast). Suggested script: `script/MigrateBatchNFTMinter.s.sol`.

**Pre-req:** patched `BatchNFTMinter` built & tested in `nft-staking` (§3).

1. **Deploy** new `BatchNFTMinter(0xCad1)`.
2. **Configure** new instance:
   `setTokenMinter(NFTMinterV2)`, `setDispatcherIndex(4)`, `setNudgeSize(40)`,
   `setNudgePaymentToken(USDC)`, (optional) `setPauser(globalPauser)`.
3. **Cut funding over to the new instance** (stops feeding the old one):
   - `BalancerPoolerV2(0x7f74388b…).setBatchMinter(new)`
   - `StableYieldAccumulator(0x3bBE92…).setNudgeAddress(new)`
4. **Drain the old instance's residual USDC** → new instance (or treasury):
   `BatchNFTMinter(0x6e9886Af…).rescueERC20(USDC, new, balanceOf(old))`.
   - To eliminate the drain window between steps 3 and 4, either (a) bundle 3+4
     in one broadcast (residual is sub-batch and unlikely to be sniped in the gap),
     or (b) first `setPauser`+`pause()` the old instance so `batchMint` is blocked,
     then rescue. Pausing is the belt-and-suspenders option.
5. **Update address book:** `server/deployments/mainnet-addresses.ts` →
   `BatchNFTMinter: new`. Add a dated `// Updated …` comment per repo convention.
6. **Regenerate + republish wagmi hooks** (`npm run generate:hooks`, version bump,
   `npm publish`), then bump the UI dependency so batch mints target the new
   instance.
7. **Verify** (§7).
8. **⚠️ RESTORE the donation to 15%** if it was zeroed as an interim bleed-stop
   (see below; owner raised the operating value from the original 10% to 15% on
   2026-06-10). The Sky-route donation does NOT fund the pot while
   `batchDonationSize == 0`, so the nudge pot stays empty until this is set back.
   `script/MigrateBatchNFTMinter.s.sol` does this in-broadcast; the standalone
   fallback is:
   ```
   DONATION_SIZE=15 forge script script/SetBatchDonationSizeZeroIndex4.s.sol \
     --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
     --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
   ```
   Verify `cast call pooler "batchDonationSize()(uint256)"` == 15 afterward.

### Interim bleed-stop (before migration, reversible, no redeploy)

While the patched instance is being built, halt the self-refund by zeroing the
donation on the current index-4 pooler:

```
# STOP (set to 0):
forge script script/SetBatchDonationSizeZeroIndex4.s.sol \
  --rpc-url $RPC_MAINNET --broadcast --skip-simulation --slow \
  --ledger --hd-paths "m/44'/60'/46'/0/0" -vvv
```

`script/SetBatchDonationSizeZeroIndex4.s.sol` targets the live Sky-route pooler
`0x7f74388b…786b`, defaults to size 0, and the SAME script restores 10% via
`DONATION_SIZE=10` (step 8). Zeroing the per-mint donation is the **complete** stop
for this bug — it removes the only thing that self-refunds. **Leave SYA untouched:**
its 30% `nudgeSplit` drip and a 40-batcher scooping the resulting pot are the
intended incentive, not part of this bug. The only effect of the interim stop is
that minting won't top up the pot until the donation is restored at step 8.

> **Do NOT** leave `batchDonationSize` at 0 once the fix is live — it's an *interim*
> stop, not the fix. The actual fix is the snapshot-before-loop change (§3) +
> redeploy; restore 15% at step 8 so minting tops up the pot again.

---

## 7. Verification checklist

- `cast call new "tokenMinter()(address)"` == NFTMinterV2; `dispatcherIndex()`==4;
  `nudgeSize()`==40; `nudgePaymentToken()`==USDC; `owner()`==`0xCad1`.
- `cast call pooler "batchMinter()(address)"` == new.
- `cast call SYA "nudge()(address)"` == new; `nudgeSplit()` == 30 (unchanged).
- Old instance USDC balance == 0 after rescue.
- A test 40-batch (or fork sim): batcher receives only the **prior** pot; the
  batch's own ~10% donation **remains** in the new instance afterward (the bug is
  gone). One `BatchDonatedViaPSM` per mint, no `DonationSkipped`.
- `cast code new` non-empty; Etherscan-verified.
- UI/hooks point to `new`.

---

## 8. Open questions for the owner

1. **Pauser on the new instance** — wire the global Pauser (recommended), or
   match current (`pauser=0`)?
2. **Rescue destination** for the old instance's residual USDC — straight into the
   new instance (keeps it as nudge fuel) or to treasury/multisig?
3. **Drain-window handling** — bundle steps 3+4 in one broadcast (simplest), or
   pause-old-first (safest)?
4. ~~Stricter nudge semantics?~~ **Resolved (owner):** "first-to-N scoops the
   pre-existing pot" is the intended incentive. No epoch / own-contribution
   accounting. The fix only stops the per-mint self-refund.

---

## Appendix — key addresses

| Name | Address |
|---|---|
| BatchNFTMinter (current, buggy) | `0x6e9886AfDF07DD67dc70b8335E4e9DF14B445071` |
| BatchNFTMinter (old, retired drain) | `0x4ef0fDe49360ed31c68ED442Ff263CC6291041f3` |
| BalancerPoolerV2 (index-4, Sky route) | `0x7f74388bc970dE5e2822036A1aD06fCCd156786b` |
| StableYieldAccumulator (live) | `0x3bBE928340c61a65cB6C4a87b3FB59b6F3F7606a` |
| NFTMinterV2 | `0x39Af088408e815844c567037C157B31d48d2E10F` |
| USDC (nudge token) | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| USDS (payment / prime token) | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` |
| Sky PSM (UsdsPsmWrapper) | `0xA188EEC8F81263234dA3622A406892F3D630f98c` |
| Owner / ledger signer (HD m/44'/60'/46'/0/0) | `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6` |
</content>
</invoke>
