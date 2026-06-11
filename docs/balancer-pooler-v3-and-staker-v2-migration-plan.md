# BalancerPoolerV3 + NFTStakerV2 Migration Plan

## Purpose

Fix the latest BalancerPoolerV2 bug by deploying a replacement dispatcher under
**the same NFTMinterV2 index (6)** via `replaceDispatcher`, so existing id-6
holders are unaffected. At the same time, retire the old id-4 NFTStaker by
providing a one-shot burn-and-migrate path for id-4 holders into a new id-6
NFTStakerV2 — and add two small features to the new staker
(`stakeFor`, `withdrawRewardToken`) so future incidents are easier to migrate
without stranding phUSD.

The trigger for the staker side of this work was a separate finding: NFT id 4
(old BalancerPoolerV2 at dispatcher index 4) and NFT id 6 (current
BalancerPoolerV2 at index 6) are distinct ERC1155 token ids — the existing
NFTStaker is wired to id 4 and rejects id 6 transfers. The id-4 staker holds
139 NFTs and ~910 phUSD of remaining runway as of writing.

## Scope by Project

| Project | Responsibility |
|---|---|
| `yield-claim-nft` (submodule) | New `BalancerPoolerV3` dispatcher with `migrateMint` side-function. Inherits the existing pooler interface for new id-6 mints (USDS pay path unchanged). |
| `nft-staking` (submodule) | New `NFTStakerV2`: identical to current `NFTStaker` plus `stakeFor(beneficiary, amount)` and `withdrawRewardToken(to, amount)`. No loosening of the `totalStaked == 0` guards. |
| `phase-2-staging` (this repo) | Hosts `MigrationHelper.sol` (orchestrates burn-and-stake in one user tx). Hosts the broadcast script that wires everything together. Funds new staker's runway. |
| Phoenix UI / `@behodler/phase2-wagmi-hooks` consumer | Two-step migration modal (unstake → migrate-and-stake). New users and pure id-6 holders see the unchanged staking page. |
| phUSD minter ops | Owner mints phUSD to the new staker sized to give it the same forward runway the old staker has today. This is the deliberate inflation hit — see "On the inflation hit" below. |

## High-Level Flow

1. **Leave the old staker alone.** No `setTargetAPY(0)`, no `pause()`. The
   ~910 phUSD of remaining runway continues to drain to id-4 stakers at the
   live 30% APY for as long as they stay. The cost of this choice is the
   double-reward window (see "On the inflation hit" below); the benefit is
   that no honest staker accrues nothing during the migration period.
2. **Deploy `BalancerPoolerV3`** with the bug fix, identical USDS pay-path
   interface plus a new `migrateMint(uint256 amount)` entry point (see
   "BalancerPoolerV3.migrateMint" below).
3. **`NFTMinterV2.replaceDispatcher(6, newPoolerV3)`** — token id 6 stays,
   price/growth curve continuous, dispatcher swapped underneath.
4. **Authorise the new pooler** on NFTMinterV2 as both
   `setAuthorizedBurner(newPoolerV3, true)` and
   `setAuthorizedMinter(newPoolerV3, true)`. Required by the burn-and-mint
   migration path; not required for the standard USDS mint path (which
   continues to flow through `_executeMint`).
5. **Eject BPT** from old pooler at index 6: `oldPooler.withdrawBPT(deployer, bal)`
   then `LP.transfer(newPooler, bal)` in the same broadcast. Same template as
   `script/DeployMainnetNudgePoolerV2.s.sol:72–75`.
6. **Mirror pooler config**: `newPooler.setBatchDonationSize`,
   `setBatchMinter`, `setSwapConfig`, `setHook`, etc. — values read off the
   old index-6 pooler so the new one is a drop-in replacement for everything
   except the bug-fix delta.
7. **Deploy `NFTStakerV2`** with `stakedId = 6`, `dispatcherIndex = 6`, the
   new hook (see step 8), and `targetAPY = 0` (turn on only after step 11).
8. **Deploy `BalancerPoolerMintDebtHook`** for the new pooler (the hook's
   `dispatcher` field is constructor-immutable, so the swap requires a fresh
   hook deployment). Wire:
   - `newPooler.setHook(newHook)`
   - `newStakerV2.setDispatcherHook(newHook)`
   - `newHook.setRecipient(newStakerV2)`
   - `phUSD.setMinter(newHook, true)`; `phUSD.setMinter(oldHook, false)`
9. **Deploy `MigrationHelper`** (this repo's `src/`): a tiny one-shot contract
   wired to the new pooler and new staker, with a single user entry point
   `migrateAndStake(uint256 amount)`. Approve it once at deploy time on the
   new staker (`helper` sets `setApprovalForAll(newStakerV2, true)` on
   NFTMinterV2 so `stakeFor` can pull id-6 from the helper).
10. **Register with Pauser**: `Pauser.register(newPoolerV3)`,
    `Pauser.register(newStakerV2)`.
11. **Mint phUSD to `newStakerV2`** sized to give it the same forward runway
    the old staker has today (see "On the inflation hit"). Then
    `newStakerV2.setTargetAPY(0.3e18)` to start the schedule.
12. **Publish UI changes**: migration modal active for id-4 NFT holders
    (whether currently staked or in-wallet); plain stake/unstake flow for
    id-6 holders.
13. **Sunset old staker** once both (a) `oldStaker.totalStaked() == 0` and
    (b) the residual `rewardBudget` has been emitted or is acceptably small:
    `oldStaker.setTargetAPY(0)` and `oldStaker.pause()` as a final hard stop.
    Any phUSD remaining in the old staker at sunset is left stranded — the
    inflation cost is already paid up front in step 11.

## On the inflation hit

Two reward streams run in parallel during the migration window:

- **Old staker (id 4)** keeps emitting from its existing ~910 phUSD budget at
  the live 30% APY against the remaining id-4 stakers. No top-up — this is
  pre-funded runway draining naturally.
- **New staker (id 6)** is freshly funded in step 11 so id-6 stakers
  immediately see a productive APY. The mint amount is sized to give the new
  staker the same forward runway in seconds that the old staker has at the
  moment of migration (i.e., `oldStaker.runwaySeconds()` carried over to the
  new staker against its own expected `S = totalStaked * latestPrice`).

Total fresh phUSD inflation = the new staker's mint, not the new + the old
residual. The old residual is already in circulation as committed runway and
will be paid to id-4 stakers who stay (and to none other).

**The deliberate cost: a user who delays migration earns on both contracts.**
They keep collecting on their id-4 stake until they unstake, and the moment
they migrate they start collecting on their id-6 stake. We accept this rather
than the alternative (zero accrual for the migration period) because:

1. Honest users don't pay for the migration with lost yield.
2. The double-reward is rate-limited by the old staker's pre-funded runway,
   which only emits to stakers who actually held through — it does not scale
   with the number of new entrants.
3. The team can choose to keep the migration window short to limit total
   double-reward exposure, but is not forced to.

The doc author's recommendation: do not cut the old APY early. Accept the
inflation, ship the migration cleanly, and pause + zero-APY the old staker
only once `totalStaked == 0`.

## BalancerPoolerV3.migrateMint

```solidity
/// @notice Burn a quantity of id-4 NFTs from `msg.sender` and mint the same
///         quantity of id-6 NFTs to `mintRecipient`. Does not touch
///         configs[6].price — only USDS payers move the price curve. Reverts
///         if msg.sender does not hold `amount` of id 4.
function migrateMint(uint256 amount, address mintRecipient) external {
    require(amount > 0, "BalancerPoolerV3: zero migrate");
    INFTMinterV2(NFT_MINTER_V2).burn(msg.sender, OLD_NFT_ID, amount);
    for (uint256 i = 0; i < amount; ++i) {
        INFTMinterV2(NFT_MINTER_V2).mintFor(NEW_NFT_INDEX, mintRecipient);
    }
}
```

- `NFTMinterV2.burn(holder, ...)` is callable by any authorised burner with no
  holder approval required (`NFTMinterV2.sol:341`). So a user holding id-4
  NFTs needs zero ERC1155 approvals on the migration path.
- `mintFor` mints one NFT per call (line 211). For 41 NFTs that's a loop of 41
  calls. Gas overhead is real but tolerable for a one-shot migration; if it
  becomes a concern, add a batched `mintForBatch(index, recipient, quantity)`
  to NFTMinterV2 as a separate change.
- The price curve `configs[6].price` is deliberately **not** advanced by
  migrations — migrations aren't price discovery, only USDS payers move the
  curve. Worth documenting on the migrateMint NatSpec.

## NFTStakerV2 deltas

Two surgical additions to the current `NFTStaker.sol`:

### `stakeFor(address beneficiary, uint256 amount)`

```solidity
function stakeFor(address beneficiary, uint256 amount) external nonReentrant whenNotPaused {
    require(beneficiary != address(0), "NFTStakerV2: zero beneficiary");
    require(amount > 0, "NFTStakerV2: zero stake");
    _syncBudget();
    UserInfo storage user = users[beneficiary];
    if (user.amount > 0) {
        uint256 pending = (user.amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        if (pending > 0) {
            pending = _safePay(pending);  // pays beneficiary; see note
            if (pending > 0) emit Claimed(beneficiary, pending);
        }
    }
    stakedToken.safeTransferFrom(msg.sender, address(this), stakedId, amount, "");
    user.amount += amount;
    totalStaked += amount;
    user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;
    emit Staked(beneficiary, amount);
    _recomputeSchedule();
}
```

Note: `_safePay` in the current contract sends to `msg.sender`. For `stakeFor`,
that's the helper, not the beneficiary — the helper would receive pending phUSD
on behalf of a brand-new beneficiary (a no-op since their `user.amount == 0`).
If `stakeFor` is ever called for an existing beneficiary, the helper would
receive their pending — undesirable. Either:
  - Restrict `stakeFor` to brand-new beneficiaries (`require(user.amount == 0)`),
    which fits the migration use case exactly, OR
  - Refactor `_safePay` to take an explicit recipient param.

The first is simpler and matches the only realistic caller (a stateless helper
migrating a fresh user into the new staker).

**No authorisation gate** — anyone can call `stakeFor` provided they own the
NFTs to deposit. The deposit requirement (`safeTransferFrom` from `msg.sender`)
prevents griefing.

### `withdrawRewardToken(address to, uint256 amount)`

```solidity
function withdrawRewardToken(address to, uint256 amount) external onlyOwner {
    require(totalStaked == 0, "NFTStakerV2: stake outstanding");
    require(paused(), "NFTStakerV2: not paused");
    require(to != address(0), "NFTStakerV2: zero recipient");
    require(amount > 0, "NFTStakerV2: zero withdraw");
    rewardToken.safeTransfer(to, amount);
    // Re-derive invariant state from balance: when totalStaked == 0 there are
    // no live claimants and `committedDebt` should already be 0 (no pending
    // accrual). Recompute as defence-in-depth.
    rewardBudget = rewardToken.balanceOf(address(this));
    committedDebt = 0;
    emit RewardTokenWithdrawn(to, amount);
}
```

Guards: `totalStaked == 0 && paused`. This is the decommissioning sweep that
would have prevented the ~910 phUSD orphaning in the current incident. Not used
in this migration (the old staker is the V1 without this method), but in place
for the next one.

## MigrationHelper.sol (phase-2-staging/src/)

Single-purpose, no admin, no upgrade path. Holds no funds between txs.

```solidity
contract MigrationHelper {
    IBalancerPoolerV3 public immutable pooler;
    INFTStakerV2 public immutable staker;
    IERC1155 public immutable nftMinter;
    uint256 public constant NEW_ID = 6;

    constructor(IBalancerPoolerV3 _pooler, INFTStakerV2 _staker, IERC1155 _nftMinter) {
        pooler = _pooler;
        staker = _staker;
        nftMinter = _nftMinter;
        // One-time approval so `stakeFor` can pull from the helper.
        _nftMinter.setApprovalForAll(address(_staker), true);
    }

    function migrateAndStake(uint256 amount) external {
        pooler.migrateMint(amount, address(this));
        staker.stakeFor(msg.sender, amount);
    }
}
```

User flow (two on-chain signatures, no approvals required):

1. **Tx 1**: `oldStaker.unstake(amount)` — returns id-4 NFTs to the user's
   wallet, pays out any pending phUSD at the OLD staker.
2. **Tx 2**: `migrationHelper.migrateAndStake(amount)` — burns id-4 from the
   user (NFTMinterV2 authorised-burner path bypasses ERC1155 approval),
   `mintFor`s id-6 to the helper, helper calls `staker.stakeFor(user, amount)`.

If the user already holds id-4 NFTs in their wallet (never staked), they skip
Tx 1.

## Deployment Script

Single Foundry broadcast in `phase-2-staging/script/`, modeled on
`DeployMainnetNudgePoolerV2.s.sol`. Inherit its progress-file pattern
(`server/deployments/progress.pooler-v3.1.json`) and Ledger signer
(`0xCad1...D0B6`, HD path `m/44'/60'/46'/0/0`).

The script does **not** mint the runway phUSD — that's a separate
owner-signed call against the phUSD contract once the new staker is live, so
that the broadcast does not require the phUSD-minter role and can be reviewed
independently.

## UI Changes (Phoenix UI consumer)

- **Modal: "Migrate your old NFTs"** — shown to wallets whose id-4 balance > 0
  OR whose old-staker `users[wallet].amount > 0`. Two steps:
  1. (if staked) "Unstake N id-4 NFTs from the previous pool" — calls
     `oldStaker.unstake(N)`.
  2. "Migrate to the new pool and stake" — calls
     `migrationHelper.migrateAndStake(N)`.
- **Plain stake page** for id-6 holders and new users — unchanged surface, just
  points at the new staker address.
- **Address book**: add `BalancerPoolerV3`, `NFTStakerV2`, the new
  `BalancerPoolerMintDebtHook`, and `MigrationHelper` to
  `server/deployments/mainnet-addresses.ts`. Old addresses retained as
  `*_legacy` for reference until the migration window closes.

Hook regeneration (`npm run generate:hooks`) and a `@behodler/phase2-wagmi-hooks`
version bump go in the same UI-side PR.

## Open Questions

1. **Burn loop gas on `migrateMint`** — for the user holding 41 NFTs the loop
   is 41 × `mintFor` invocations. Worth measuring. If close to a block limit
   ceiling for larger holders, add `NFTMinterV2.mintForBatch` upstream.
2. **`stakeFor` recipient restriction** — fix as `require(user.amount == 0)`
   in the new staker, or generalise `_safePay`? First is smaller surface area.
3. **Pauser registration of `MigrationHelper`** — probably no, it holds no
   user funds and any compromise just bricks itself. Confirm.
4. **Migration deadline** — the old staker stays live indefinitely with
   `targetAPY == 0` after this rolls out. Worth defining an end-of-window
   policy: once `totalStaked == 0`, call `pause()` and treat the contract as
   archive-only.
