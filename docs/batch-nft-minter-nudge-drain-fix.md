# BatchNFTMinter Nudge Drain — Incident & Fix Plan

## Status

- **Severity:** Critical (live fund loss on mainnet)
- **Affected contract:** `BatchNFTMinter` @ `0x4ef0fDe49360ed31c68ED442Ff263CC6291041f3` (mainnet)
- **Source:** `lib/nft-staking/src/BatchNFTMinter.sol`
- **First confirmed loss:** 61.297674 USDC, 2026-05-28
- **Owner / operator EOA:** `0xCad1a7864a108DBFF67F4b8af71fAB0C7A86D0B6`

## 1. Summary

The `BalancerPoolerV2` donation phase pools pending sUSDS and pushes the resulting USDC
into the `BatchNFTMinter` as a "nudge" pot (intended to subsidize a genuine large
batch mint). The pooling transaction
[`0xe65ca6…82cc`](https://etherscan.io/tx/0xe65ca67b2f56f5af3e8ea5f4b16047ce2f6f6ba7f9fb2f82ee2ca316c7de82cc)
correctly delivered **61.297674 USDC** into the BatchNFTMinter.

Fourteen blocks later, an EIP-7702-delegated MEV bot (`0x0E730000…0691`) drained the
entire balance in
[`0x7535ec…f384c`](https://etherscan.io/tx/0x7535ec2684aa775136befe949b4beb012f77083bfcfa98978febebf8005f384c).
The funds are gone (forwarded to `0x9300d700…`) and are not recoverable.

**Any USDC funded into this contract going forward will be stolen the same way, within a
block or two — searchers are actively watching the balance.**

## 2. Root cause

`batchMint` takes the NFT minter and the payment token as **unvalidated, caller-supplied
parameters**:

```solidity
function batchMint(
    ITokenMinterV2 nftMinter,   // <-- caller-controlled
    IERC20 paymentToken,        // <-- caller-controlled
    uint256 dispatcherIndex,
    uint256 count,
    address recipient,
    uint256 paymentAmount
) external returns (uint256 totalPaid)
```

The nudge payout fires on a purely numeric gate and sends the contract's **entire**
`nudgePaymentToken` balance to a caller-chosen `recipient`:

```solidity
if (_nudgeSize != 0 && count >= _nudgeSize) {
    if (_nudgeTokenEntry != address(0)) {
        uint256 nudgeAmount = IERC20(_nudgeTokenEntry).balanceOf(address(this));
        if (nudgeAmount != 0) {
            IERC20(_nudgeTokenEntry).safeTransfer(recipient, nudgeAmount);
            ...
```

Because nothing forces `nftMinter` to be the real protocol minter, the "work" that the
nudge rewards can be **completely faked**. The mints are fake; the payout is real.

### Why were `nftMinter` / `paymentToken` ever parameters?

This is the important part — it was a reasonable decision that a later feature
silently invalidated:

- **story-009** introduced `BatchNFTMinter` as a deliberately **stateless** generic
  utility: "loops `ITokenMinter.mint(...)` `count` times… no reentrancy guard,
  ownership, or pausing (out of scope for a stateless utility)." For a stateless
  looper this is safe — the caller can only ever spend *their own* tokens (pulled
  via `safeTransferFrom(msg.sender, …)`) and receives the NFTs. A caller-supplied
  minter/token is harmless when the contract holds no funds of its own.
- **story-010** migrated to `ITokenMinterV2` (whose own H-01 anti-spoofing fix removed
  the `token` argument from `mint`, since trusting a caller-supplied token address was
  itself unsafe). The wrapper kept `nftMinter`/`paymentToken` as parameters.
- **story-011** bolted the **nudge** (Ownable + contract-held balance + balance-based
  payout) onto the stateless design — *without revisiting the now-dangerous assumption
  that the caller-supplied minter is trustworthy.* The moment the contract began holding
  a balance that pays out on faked work, the stateless-era parameter became a drain.

In short: parameters were correct for a stateless utility; they became a critical flaw
when stateful, contract-held funds were added on top without re-validating the trust
model. The very fix V2 applied to `mint()` (don't trust caller-supplied addresses) is
the fix the wrapper still needs.

## 3. The exploit (confirmed from on-chain trace)

The bot called (decoded via `cast run`):

```
batchMint(
  nftMinter     = 0x0E730000…0691,   // the bot's own delegated contract
  paymentToken  = 0x0E730000…0691,   // the bot's own contract
  dispatcherIndex = 1,
  count         = 54,                 // >= nudgeSize (40)
  recipient     = 0x0E730000…0691,    // the bot
  paymentAmount = 1
)
```

Mechanism:

1. `paymentToken.safeTransferFrom(...)` → bot's contract returns `true`, pulls 1 wei of a fake token.
2. `paymentToken.forceApprove(...)` → returns `true`.
3. 54× `nftMinter.mint(...)` → bot's contract returns `1` (no-op stub), ~700 gas each. **Zero real NFTs minted.**
4. `count (54) ≥ nudgeSize (40)` and `nudgePaymentToken (USDC) ≠ paymentToken` → contract transfers its **full 61.297674 USDC** to `recipient` (the bot).
5. Dust sweep of the fake `paymentToken` → nothing meaningful.

Whole drain cost 146k gas and emitted only 3 logs (2 USDC `Transfer`, 1 `NudgePaid`) —
the absence of any mint events is the proof no genuine minting occurred.

Current config that makes this farmable: `nudgeSize = 40`, `nudgePaymentToken = USDC`.

## 4. Immediate mitigation (no redeploy)

`BatchNFTMinter` is a plain non-upgradeable `Ownable` contract, so the deployed code
cannot be patched and it has **no owner-withdraw** function.

### Disabling the nudge is NOT sufficient on its own

Clearing `nudgePaymentToken` removes the `paymentToken == nudgeToken` guard, so a caller
can pass `paymentToken = USDC` and the end-of-batch dust sweep
(`paymentToken.safeTransfer(msg.sender, remaining)`) hands the whole USDC balance to any
caller — the same drain via a different line. Therefore the only robust stop-gap is to
**stop funds reaching the contract**.

### Two funding paths feed the BatchNFTMinter — both must be cut

1. **PRIMARY — StableYieldAccumulator (`0x3bBE92…7606a`).** Its permissionless `claim()`
   routes `nudgeSplit` (currently **30%**) of each claim's USDC reward straight to
   `nudge`, which is set to the BatchNFTMinter. This drips funds in on every claim,
   independent of `pool()`. **This is the path that matters.**
2. **BalancerPoolerV2 (`0x26f89f…db38a`).** Its `pool()` donation phase
   (`batchDonationSize = 10%`) swaps sUSDS→USDC and sends it to `batchMinter`
   (the BatchNFTMinter). Only fires when an authorized pooler calls `pool()`.

### Mitigation calls (all from the shared owner EOA)

- `SYA.setNudgeSplit(0)` — stop the claim drip entirely; the full claim payment flows to
  Phlimbo as normal rewards and nothing reaches the BatchNFTMinter. `claim()` stays
  functional (the `nudgeSplit > 0 && nudge == address(0)` guard only bites while the
  split is `> 0`). The `nudge` address is left untouched — it is inert at split 0.
  (Note: do **not** instead try to zero the `nudge` *address* while the split is still
  30 — that trips the `NudgeNotConfigured` guard and reverts **every** `claim()`.)
- `BalancerPoolerV2.setBatchMinter(OWNER)` — redirect pool donations to the owner so they
  are set aside (belt-and-suspenders; `pool()` is not intended to be called).
- `setNudgePaymentToken(0)` + `setNudgeSize(0)` on the BatchNFTMinter — defense in depth
  only (see caveat above; this is not the protection).

Implemented in `script/DisableNudgeAndDivertDonations.s.sol`, wired into `package.json`:

```bash
npm run DisableNudgeAndDivertDonations:preview   # fork dry-run (impersonates owner)
npm run DisableNudgeAndDivertDonations           # broadcast (Ledger, owner key)
```

Verified against a live mainnet fork.

> These are **mainnet broadcasts** — confirm with the operator before sending.

## 5. The fix: pin the minter to an owner-configured canonical address

Make the NFT minter **trusted contract state**, not a call parameter. A genuine batch
then forces real, priced mints through the real dispatcher, so qualifying for the nudge
costs more than the nudge is worth — the free-drain disappears.

### Contract changes (`BatchNFTMinter.sol`)

1. Add owner-set state:
   ```solidity
   /// @notice The only NFT minter batchMint is permitted to call. Owner-set.
   ITokenMinterV2 public tokenMinter;
   event TokenMinterSet(address indexed newMinter);
   error BatchMint__MinterNotConfigured();

   function setTokenMinter(ITokenMinterV2 newMinter) external onlyOwner {
       tokenMinter = newMinter;            // address(0) disables batchMint
       emit TokenMinterSet(address(newMinter));
   }
   ```
2. **Remove `nftMinter` from the `batchMint` signature** and use the pinned
   `tokenMinter` internally; revert if unset:
   ```solidity
   ITokenMinterV2 nftMinter = tokenMinter;
   if (address(nftMinter) == address(0)) revert BatchMint__MinterNotConfigured();
   ```
3. Keep `paymentToken` as a parameter (it legitimately varies by dispatcher prime
   token — e.g. USDS for the Balancer pooler dispatcher). This is now safe: with a
   pinned real minter, a mismatched `paymentToken` causes the real `mint()` to fail its
   internal prime-token pull and the whole batch reverts atomically. The existing
   `nudgePaymentToken != paymentToken` guard still stands.
4. Optionally also pin `dispatcherIndex` allow-listing, but not required for the fix.

### Why pinning the minter is sufficient

- The bot's drain depended entirely on substituting a no-op minter. With the minter
  pinned to the real `NFTMinterV2` (`0x39Af0884…E10F`), `count ≥ nudgeSize` requires
  genuinely paying for ≥40 real mints at the dispatcher's ramping price — far more than
  the ~61 USDC nudge, so farming it is unprofitable.
- A fake/mismatched `paymentToken` no longer helps: the real minter pulls the real
  prime token, the approval was on the wrong token, the mint reverts, the batch rolls
  back. No funds move.
- The nudge then behaves as designed: whoever performs the first genuine large batch
  receives the accumulated bonus.

## 6. Deployment & cutover plan

Because the contract is non-upgradeable, the fix ships as a **new deployment**:

1. **TDD the fix** in `lib/nft-staking` (see §7), submodule PR, bump the submodule
   pointer here.
2. **Deploy** the new `BatchNFTMinter` (owner = the operations multisig/EOA).
3. **Configure** the new contract under the [Configuration Safety](../CLAUDE.md#configuration-safety-non-negotiable) gate:
   - `setTokenMinter(0x39Af088408e815844c567037C157B31d48d2E10F)` — canonical V2 NFTMinter.
   - `setNudgePaymentToken(USDC)` and `setNudgeSize(40)` — only after the minter is pinned.
   - Add in-script `require`s that reject `tokenMinter == address(0)` and a nudge token
     equal to the payment token before broadcast on real networks.
4. **Repoint the funder:** `BalancerPoolerV2.setBatchMinter(newBatchNFTMinter)`.
5. **Update addresses:** `server/deployments/mainnet-addresses.ts` (`BatchNFTMinter`),
   `progress.1.json`, then regenerate Wagmi hooks (`npm run generate:hooks`) — the
   `batchMint` ABI changed (one fewer parameter), so downstream UI calls must update.
6. **Retire the old contract:** confirm its USDC balance is 0 and disable its nudge
   (`setNudgePaymentToken(0)`), so nothing accidentally funds it again.

## 7. Tests (TDD — write first, must fail on current code)

In `lib/nft-staking/test/BatchNFTMinterNudge.t.sol`:

1. **Regression / drain reproduction:** fund the contract with USDC, configure
   `nudgeSize`/`nudgePaymentToken`, then attempt `batchMint` with an attacker-controlled
   no-op minter + fake payment token + `count ≥ nudgeSize`. **Assert it reverts** (on the
   fixed contract) — and confirm this same test drains the balance on the pre-fix code.
2. **Happy path:** with `tokenMinter` pinned to a real mock V2 minter that charges a
   real price, a `count ≥ nudgeSize` batch succeeds, mints `count` NFTs, and pays the
   nudge to `recipient`.
3. **Unconfigured minter:** `batchMint` reverts with `BatchMint__MinterNotConfigured`
   when `tokenMinter == address(0)`.
4. **Mismatched payment token:** real pinned minter + wrong `paymentToken` reverts and
   moves no funds.
5. **Access control:** `setTokenMinter` is `onlyOwner`.

## 8. Checklist

- [ ] Immediate: disable nudge on live contract (`setNudgePaymentToken(0)`) and pooler donation (`setBatchMinter(0)` / `setBatchDonationSize(0)`)
- [ ] TDD fix in `lib/nft-staking`, regression test reproduces the drain on old code
- [ ] Pin minter as owner-set state; drop `nftMinter` param from `batchMint`
- [ ] Deploy new contract; configure minter → then nudge knobs; in-script `require` guards
- [ ] `BalancerPoolerV2.setBatchMinter(newContract)`
- [ ] Update `mainnet-addresses.ts`, `progress.1.json`, regenerate hooks, bump UI
- [ ] Verify old contract drained + nudge disabled
```
