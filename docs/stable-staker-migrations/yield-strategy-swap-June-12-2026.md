# Yield Strategy Swap Migration — June 12 2026

## Background

`ERC4626YieldStrategy._acquireShares` credits the full nominal `amount` as principal regardless
of how many shares the vault actually returned. For vaults whose exchange rate is not exactly 1:1
(ERC4626 rounding, deposit fee, or any premium), `totalDeposited` ends up greater than
`_positionValue()`, causing the strategy to appear underwater immediately after deposits. This
blocks normal `withdraw` calls on StableStaker for affected users.

The fix: credit `vault.convertToAssets(sharesReceived)` — the actual value of the shares
received — instead of the nominal `amount`. This is consistent with how
`ERC4626MarketYieldStrategy` already handles slippage (though the market strategy uses a
conservative pre-computed floor rather than the live post-deposit value).

**As of writing (2026-06-12), the fixed contract code is not yet complete. This plan is written
in anticipation of that work finishing.**

---

## Scope

Only the plain `ERC4626YieldStrategy` instances are affected. The market strategy is correct.

| Token | Current Strategy | Affected? |
|-------|-----------------|-----------|
| DOLA  | `0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9` | Yes |
| USDC  | `0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470` | Yes |
| USDe  | `0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95` | No — `ERC4626MarketYieldStrategy`, already correct |

The USDe pool and its stakers are untouched by this migration.

**Live StableStaker:** `0xbce8ABC09BaEDCabE93419bF875f6186e182079A`

---

## Why Two Migrator Contracts

`StableStakerMigrator` bakes `oldStaker` and `newStaker` in as immutables set at construction time — there is no way to change direction on the same instance. Leg 1 requires `old=original, new=temp`; leg 2 requires `old=temp, new=original`. Because those are opposite directions, two separate contracts are needed.

---

## Why a Full Migration Is Required

`StableStaker.setYieldStrategy` is gated on `totalStaked == 0`. There is no hot-swap path; the
only way to change a yield strategy on a live pool is the terminal migration runbook:

```
initiateMigration → batchMigrate/userMigrate → finalizeAndReset → setYieldStrategy
```

To preserve the original StableStaker address (referenced by the UI and other contracts), we use
a two-leg bounce:

- **Leg 1**: migrate DOLA and USDC stakers out of original StableStaker into a temporary staker
- **Reset**: `finalizeAndReset` both pools on original, wire new yield strategies
- **Leg 2**: migrate DOLA and USDC stakers back into original StableStaker

The USDe pool never moves.

---

## User Impact

- Pending phUSD rewards are minted directly to each user's wallet at the time of each
  `batchMigrate` call — users receive two payouts, one per migration leg.
- Principal is preserved 1:1 (subject to any below-par haircut from the old buggy strategy; the
  migration's `(R, P)` snapshot socializes any realized loss proportionally).
- Users take **zero action**. The migrator deposits on their behalf via `depositFor`.
- There is a brief window between leg 1 and leg 2 where DOLA and USDC principal sits idle in the
  temp staker (no vault yield, but phUSD emissions continue if configured).

---

## Pre-Migration Checklist

### Awaiting
- [ ] Fixed `ERC4626YieldStrategy` contract code reviewed and tested
- [ ] New strategy contracts audited / reviewed

### Deploy (once code is ready)
- [ ] Deploy `YieldStrategyDolaV2` — new `ERC4626YieldStrategy` for DOLA / autoDOLA vault
  - Owner: deployer multisig / EOA
  - underlyingToken: DOLA `0x865377367054516e17014CcdED1e7d814EDC9ce4`
  - vault: autoDOLA `0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d`
- [ ] Deploy `YieldStrategyUSDCV2` — new `ERC4626YieldStrategy` for USDC / autoUSDC vault
  - Owner: deployer multisig / EOA
  - underlyingToken: USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`
  - vault: autoUSDC `0xa7569A44f348d3D70d8ad5889e50F78E33d80D35`
- [ ] Deploy `TempStableStaker`
  - phUSD: `0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605`
  - Owner: deployer EOA
  - No yield strategies wired (principal held idle — transit only)
- [ ] Deploy `Migrator1(oldStaker=original, newStaker=temp)`
- [ ] Deploy `Migrator2(oldStaker=temp, newStaker=original)`

### Wire (before running leg 1)
- [ ] `phUSD.setMinter(tempStableStaker, true)`
- [ ] `tempStableStaker.addToken(DOLA)`
- [ ] `tempStableStaker.addToken(USDC)`
- [ ] `tempStableStaker.setMigrator(migrator1)`
- [ ] `originalStableStaker.setMigrator(migrator1)`
- [ ] `YieldStrategyDolaV2.setClient(originalStableStaker, true)` *(needed for leg 2 re-deposit)*
- [ ] `YieldStrategyUSDCV2.setClient(originalStableStaker, true)` *(needed for leg 2 re-deposit)*
- [ ] Optional: `tempStableStaker.phUSDPerDay(DOLA, X)` and `phUSDPerDay(USDC, X)` if the
  migration window is expected to be longer than a few blocks

---

## Migration Sequence

### Step 1 — Script pre-flight: verify deployer USDC balance

The `SkimAndLeg1Migration` script must revert at the very start if the deployer does not hold
at least 60 USDC, because the Phlimbo reward injection in step 1c requires it:

```solidity
require(
    IERC20(USDC).balanceOf(deployer) >= 60e6,
    "Pre-flight: deployer needs >= 60 USDC for Phlimbo collectReward"
);
```

### Step 1a — Skim surplus from all yield strategies

`skimSurplus` iterates every authorized client registered on a strategy, so a single call per
strategy captures all client yield — not just StableStaker's. This must happen **before**
`initiateMigration` on the DOLA and USDC strategies; once initiateMigration runs it drains and
decouples them, leaving nothing to skim. The USDe strategy is not being migrated but its surplus
should be skimmed here too while all three calls are batched together.

```
YieldStrategyDola(0x90ce274b…).skimSurplus(DOLA, treasuryAddress)
YieldStrategyUSDC(0x90af002E…).skimSurplus(USDC, treasuryAddress)
YieldStrategyUSDe(0xaC2e5936…).skimSurplus(USDe, treasuryAddress)
```

Record each `underlyingReceived` return value. These tokens are protocol-owned. Optionally they
can be re-injected as principal into the new strategies via `depositFor` after leg 2 completes
(see Post-Migration Options below).

### Step 1b — Collect Phlimbo rewards

PhlimboV2 (`0x6084a02c…`) distributes USDC to stakers via a linear depletion model. Rewards are
topped up by calling `collectReward(amount)`, which pulls `amount` of USDC from `msg.sender` via
`safeTransferFrom`. The deployer must have pre-approved PhlimboV2 to spend USDC.

```
USDC.approve(PhlimboV2, 60e6)
PhlimboV2.collectReward(60e6)
```

This is included in the same migration script so the reward injection and skim happen atomically
in the same broadcast. The pre-flight check in step 1 guards against a dry run.

### Step 2 — Leg 1: original → temp (same script as step 1)

```
migrator1.initiateMigration(DOLA)   // snapshots (R, P), drains old DOLA strategy
migrator1.initiateMigration(USDC)   // snapshots (R, P), drains old USDC strategy

migrator1.migrate(DOLA, [all DOLA stakers])   // batchMigrate + depositFor into temp
migrator1.migrate(USDC, [all USDC stakers])   // batchMigrate + depositFor into temp
```

Use `originalStableStaker.getStakers(DOLA)` and `getStakers(USDC)` to build the user arrays
off-chain. Batch into chunks if the staker count is large (gas limit).

Each `batchMigrate` mints pending phUSD directly to each user's wallet.

### Step 3 — Reset original and wire new strategies

Once both pools are fully drained (verify `stakerCount == 0 && totalStaked == 0` on-chain):

```
originalStableStaker.finalizeAndReset(DOLA)
originalStableStaker.finalizeAndReset(USDC)

originalStableStaker.setYieldStrategy(DOLA, YieldStrategyDolaV2)
originalStableStaker.setYieldStrategy(USDC, YieldStrategyUSDCV2)
```

`setYieldStrategy` will sweep any idle DOLA/USDC balance into the new strategies immediately.
Verify: `YieldStrategyDolaV2.principalOf(DOLA, originalStableStaker) == 0` (expected — pool
was empty before wiring).

### Step 4 — Wire migrator2

```
tempStableStaker.setMigrator(migrator2)
originalStableStaker.setMigrator(migrator2)
```

### Step 5 — Leg 2: temp → original

```
migrator2.initiateMigration(DOLA)
migrator2.initiateMigration(USDC)

migrator2.migrate(DOLA, [all DOLA stakers in temp])
migrator2.migrate(USDC, [all USDC stakers in temp])
```

Use `tempStableStaker.getStakers(DOLA)` and `getStakers(USDC)` for the user arrays.

Each `depositFor` routes through `_routeDeposit` → `YieldStrategyDolaV2.deposit` /
`YieldStrategyUSDCV2.deposit` — so principal lands in the new strategies with correct accounting
from the first deposit.

### Step 6 — Post-migration cleanup

- [ ] Verify `tempStableStaker.stakerCount(DOLA) == 0`
- [ ] Verify `tempStableStaker.stakerCount(USDC) == 0`
- [ ] Verify `originalStableStaker.stakerCount(DOLA)` matches expected user count
- [ ] Verify `originalStableStaker.stakerCount(USDC)` matches expected user count
- [ ] Verify `YieldStrategyDolaV2.principalOf(DOLA, originalStableStaker) > 0`
- [ ] Verify `YieldStrategyUSDCV2.principalOf(USDC, originalStableStaker) > 0`
- [ ] Verify neither new strategy reports underwater (`withdrawDisabled` returns false on original)
- [ ] `phUSD.setMinter(tempStableStaker, false)` — revoke temp staker's mint permission
- [ ] Update `mainnet-addresses.ts`: `YieldStrategyDola` and `YieldStrategyUSDC` to new addresses

---

## Post-Migration Options: Surplus Re-injection

The DOLA and USDC surplus skimmed in Step 1 sits at the treasury address as raw tokens. Options:

1. **Leave as treasury revenue** — simplest, no further action.
2. **Re-inject as protocol-owned principal** — call `originalStableStaker.depositFor(token,
   protocolAddress, amount)` with the migrator, which routes through the new yield strategy and
   credits a protocol-controlled address with a staker position.

Option 2 requires the migrator still be set on the original staker. If choosing this option, do
it before revoking migrator permissions.

---

## Scripts Needed

| Script | Purpose |
|--------|---------|
| `DeployTempStableStakerAndMigrators.s.sol` | Deploys temp staker, migrator1, migrator2 |
| `SkimAndLeg1Migration.s.sol` | Pre-flight USDC balance check; skims all three strategies; Phlimbo collectReward(60 USDC); initiateMigration + migrate DOLA and USDC old → temp |
| `ResetAndRewire.s.sol` | finalizeAndReset + setYieldStrategy on original |
| `Leg2Migration.s.sol` | Runs initiateMigration + migrate on temp → original |
| `PostMigrationCleanup.s.sol` | Revokes temp minter permission, verifies state |

These scripts do not need to be written until the fixed yield strategy code is ready.

---

## Set-Aside Buffer

The live original staker has a 10% set-aside buffer configured. After leg 2, verify:

```
YieldStrategyDolaV2.setAsideBufferSize(originalStableStaker) == 10
YieldStrategyUSDCV2.setAsideBufferSize(originalStableStaker) == 10
```

These are set on the new strategy contracts by the strategy owner — they do not carry over
automatically from the old strategies.
