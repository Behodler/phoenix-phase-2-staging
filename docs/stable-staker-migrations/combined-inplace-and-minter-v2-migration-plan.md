# Combined In-Place YS Swap + phUSD Minter V1→V2 Migration — Plan

**Status:** plan / agreed shape, not yet scripted
**Supersedes (operationally):** the two-leg temp-staker saga in
`yield-strategy-swap-June-12-2026.md`. That doc and `StableStakerMigrator` are left intact; this
plan uses the simpler `InPlaceMigrator` route (see `in-place-migrator-plan.md`) and folds the
minter swap into the same runbook.
**Scope:** swap the DOLA and USDC yield strategies on the live StableStaker to fixed
(`convertToAssets`-crediting) `ERC4626YieldStrategy` instances, AND retire phUSD minter V1 in favour
of a V2 that maps the new strategies. **USDe is not touched** — its market strategy is already
correct and its V1 client position stays dormant.

---

## 1. Why this is simpler than the saga

The temp-staker bounce needed a throwaway staker, two migrators, a temp mint grant/revoke, token
re-registration, and two snapshot cycles. `InPlaceMigrator` parks staker principal in its own
custody across the rewire and re-injects it into the *same* staker — one migrator, one staker, no
temp anything. The minter swap rides along because the minter's funds and the staker's funds live in
the **same** old strategies and can be evacuated in the same session.

---

## 2. Live addresses (verify against `server/deployments/mainnet-addresses.ts` before each step)

| Thing | Address |
|---|---|
| phUSD token | `0xf3B5B661b92B75C71fA5Aba8Fd95D7514A9CD605` |
| StableStaker (live) | `0xbce8ABC09BaEDCabE93419bF875f6186e182079A` |
| PhusdStableMinter **V1** | `0x435B0A1884bd0fb5667677C9eb0e59425b1477E5` |
| StableYieldAccumulator | `0x3C690EC3B2524104dE269bf0F9baa7f045eF8270` |
| Old DOLA strategy | `0x90ce274b20A2aF4265152B369d09ce6E6Dc177F9` |
| Old USDC strategy | `0x90af002Ee537Ad5C2c9817Ebd4EF22B2e8952470` |
| USDe market strategy (**not migrated**) | `0xaC2e5936Eca286eC364d4D5Bcca33145fBe57f95` |
| DOLA / autoDOLA vault | `0x865377367054516e17014CcdED1e7d814EDC9ce4` / `0x79eB84B5E30Ef2481c8f00fD0Aa7aAd6Ac0AA54d` |
| USDC / autoUSDC vault | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` / `0xa7569A44f348d3D70d8ad5889e50F78E33d80D35` |

The deployer EOA/multisig owns the StableStaker, both old strategies, phUSD, the minter, and the new
strategies. Every owner action below is that one key.

---

## 3. Mechanics that drive the design (verified against source)

These four facts are *load-bearing*. They are why the runbook is ordered the way it is.

1. **The minter has no withdraw.** `PhusdStableMinter` exposes only `mint` / `noMintDeposit` /
   `approveYS` — there is **no** client-side withdraw. The minter's DOLA/USDC principal can only
   leave the old strategy via an **owner** call on the strategy: `totalWithdrawal(token, client)`
   (two-phase) or `withdrawAsOwner(client, recipient, amount)` (single-phase). The two-phase
   withdrawal has already been initiated (see §5), so this plan uses that path; both redeem to the
   strategy **owner**.

2. **The staker drains at par; the minter's two-phase withdrawal recomputes at execute time.**
   - StableStaker `initiateMigration` calls `strategy.withdraw(token, P)` with the underwater guard
     OFF. `_disposeShares` redeems `convertToShares(P)` shares — i.e. it delivers the **full
     requested principal at par**, capped only at *all* available shares
     (`ERC4626YieldStrategy._disposeShares`). So when a pool is mildly underwater the staker still
     pulls its full principal, eating into the shared share pool.
   - The minter's `totalWithdrawal` *snapshots a balance at phase-1 initiate* (`state.balance`), but
     `_totalWithdraw` **does not use it to size the redemption** — it redeems
     `totalShares × clientBalances[minter] / totalDeposited` from **live** balances at execute time.

   **Consequence — the haircut allocation is decided purely by execution order.** If the staker
   drains first, it zeroes itself out of `totalDeposited`; the minter's later execute then sweeps
   *all remaining shares* and absorbs any shortfall. This is exactly "let the minter bear the brunt
   of haircuts; leave staker positions intact" — and it needs **no** floor-gate machinery, as long
   as the pool can still cover the staker principal. (Currently solvent, so this is moot — but the
   ordering rule below makes it robust if a pool drifts mildly underwater.)

   > **HARD ORDERING RULE:** the staker `migrateOut` MUST execute **before** the minter's
   > `totalWithdrawal` phase-2 on the same token. Reverse it and the loss lands on the staker.

3. **Set-aside buffer == raw token balance on the StableStaker.** The staker's underwater path in
   `_routeExit` satisfies withdrawals from `token.balanceOf(staker)`. So "give the skimmed surplus
   to the staker as a buffer" is simply: **`safeTransfer` the skimmed surplus to the StableStaker
   address.** No `depositFor`, no buffer-percentage configuration, no per-client wiring.

4. **`skimSurplus` must precede `initiateMigration`.** `initiateMigration` decouples and zeroes the
   strategy; after it runs there is no surplus left to skim. Skim all three tokens (DOLA, USDC,
   USDe) while they are still wired.

---

## 4. Timing of the in-flight `totalWithdrawal`

The **deployed** old strategies use a **24h waiting period + 48h execution window** (72h total).
This is the live behaviour, NOT the `6h / 72h` constants now in the `lib/vault` source — the
deployed bytecode predates that change. The `totalWithdrawal` phase-1 has already been initiated, so
phase-2 is executable in:

```
[ initiate + 24h , initiate + 72h ]
```

Use the exact `executableAt` timestamp embedded in the `totalWithdrawal` revert message as the
authoritative start. **Script 2 must run inside this window.** If it expires (status lazily flips to
`Expired` only on the next `totalWithdrawal` call — the lazy-expiry footgun), phase-1 must be
re-initiated and the 24h wait restarts.

> **The 24h wait is the ONLY delay, and it has already elapsed.** Phase-1 was initiated before this
> work began, so all three scripts (2.1 → 2.2 → 2.3) run **back-to-back in a single session** — there
> is no second clock. The sole timing constraint is that 2.2 lands inside the window above.

---

## 5. Runbook — three scripts

### Script 1 — Deploy & Freeze (run now; no draining)

Cheap, reversible, risk-free; front-loaded so Script 2 is the only time-critical broadcast.

1. **Deploy** the new fixed `ERC4626YieldStrategy` for DOLA (autoDOLA) and USDC (autoUSDC), owner =
   deployer. *(Configuration-safety gate: confirm vault addresses, underlying, owner before
   broadcast.)*
2. **Deploy** `InPlaceMigrator(staker, migrationTimeout, owner)` with **`migrationTimeout = 2 weeks`**
   (operator-confirmed; within the [1 day, 30 day] bounds in `in-place-migrator-plan.md` §4.2).
2a. **Fund the in-place allotment:** transfer hardcoded DOLA/USDC from the deployer to the migrator so
   that if `migrateOut` realizes slippage, the migrator can top parked users up to par (forthcoming
   InPlaceMigrator feature). The amounts are **hardcoded to 0 with a `require(> 0)` tripwire at the top
   of the script** — set them before running or it reverts loudly.
3. **Deploy** phUSD minter **V2** (`PhusdStableMinter(phUSD)`).
4. **Wire the new strategies** (before any migrateIn / noMintDeposit):
   - `newDolaYS.setClient(staker, true)`, `newUsdcYS.setClient(staker, true)`
   - `newDolaYS.setClient(minterV2, true)`, `newUsdcYS.setClient(minterV2, true)`
   - The current-skim cushion is NOT configured here — it is handled by direct transfer to the
     staker in Script 2, per §3.3.
5. **Wire V2 for USDe (the dormant-client carry-over):**
   - `usdeMarketYS.setClient(minterV2, true)` → USDe market YS client set becomes
     {stable-staker, minterV1, minterV2}. **Leave minterV1 authorized** (dormant yield client).
   - On V2: `registerStablecoin(USDe, usdeMarketYS, rate, 18)` + `approveYS(USDe, usdeMarketYS)` +
     `setMaxMintPerDay(USDe, 4000e18)`.
6. **Register DOLA/USDC on V2** mapped to the **new** strategies: `registerStablecoin(...)` +
   `approveYS(...)` for each, then `setMaxMintPerDay(token, 4000e18)` for each.
   - **Exchange rates and decimals: replicate V1's current configs** — read
     `minterV1.getStablecoinConfig(token).exchangeRate` / `.decimals` for DOLA, USDC, USDe at
     scripting time and reuse them verbatim (do not hardcode from memory).
   - **`maxMintPerDay = 4000 phUSD (4000e18)` for each of DOLA, USDC, USDe** (operator-confirmed).
     V1 ran with no cap (0); V2 introduces the 4000/day rolling cap on all three.
7. **phUSD mint authority:** `phUSD.setMinter(minterV1, false)` (revoke V1 — freezes its liability so
   recorded positions can't drift) AND `phUSD.setMinter(minterV2, true)` (grant V2 so the new minter
   can mint). V1 stays an authorized *yield client* on the USDe market YS — we revoke minting, not its
   dormant position.
8. **Record minter V1 positions** on each old strategy for the post-mortem ledger:
   `principalOf(token, minterV1)` and `totalBalanceOf(token, minterV1)` for DOLA and USDC. Step 9
   does **not** require the recovered amount to match these.
9. `staker.setMigrator(inPlaceMigrator)`.

### Script 2 — Migrate (must run inside the §4 execution window)

Order is critical. Ideally a single broadcast.

1. **Skim surplus first** (before any drain), to the **operator/owner holding address — NOT the
   staker**: `skimSurplus(DOLA, operator)`, `skimSurplus(USDC, operator)`, `skimSurplus(USDe,
   operator)` on the respective strategies. It is parked on the operator now and transferred to the
   staker only **after** the rewire (step 8) — see the ⚠ below.
   > ⚠ **Do not skim DOLA/USDC directly to the staker.** `setYieldStrategy` (step 5) sweeps any idle
   > staker balance into the new strategy (`StableStaker.sol:262`). Sending the buffer in before the
   > rewire would pull it into the YS — the opposite of holding it as a set-aside buffer. USDe is not
   > rewired so it has no sweep risk, but we route it the same way for uniformity.
2. **Pause** the StableStaker (and/or V1 minter is already mint-revoked).
2b. **Top up Phlimbo (60 USDC from the deployer):** `USDC.forceApprove(PhlimboV2, 60e6)` then
   `PhlimboV2.collectReward(60e6)`. The yield accumulator has been on hold, so Phlimbo's
   linear-depletion window is nearly consumed; refill it here. Preflight requires the deployer hold
   ≥ 60 USDC.
3. **Staker drains FIRST:** `migrator.initiateMigration(DOLA)`, `migrator.initiateMigration(USDC)`,
   then `migrator.migrateOut(DOLA, allDolaStakers)`, `migrator.migrateOut(USDC, allUsdcStakers)`.
   Build user arrays from `staker.getStakers(DOLA|USDC)`. Each `migrateOut` mints pending phUSD to
   users and parks principal in the migrator.
4. **Minter drains SECOND:** execute `oldDolaYS.totalWithdrawal(DOLA, minterV1)` and
   `oldUsdcYS.totalWithdrawal(USDC, minterV1)` (phase-2). Funds land with the strategy **owner**.
   Because the staker already zeroed `totalDeposited`, these sweep all remaining shares — the minter
   absorbs any residual loss (§3.2).
5. **Rewire the staker:** `staker.finalizeAndReset(DOLA)`, `finalizeAndReset(USDC)`, then
   `staker.setYieldStrategy(DOLA, newDolaYS)`, `setYieldStrategy(USDC, newUsdcYS)`. At this point the
   pools are empty so there is no idle balance to sweep — keep it that way until after this step.
6. **Re-inject stakers:** `migrator.migrateIn(DOLA, 0, N)`, `migrator.migrateIn(USDC, 0, N)` →
   `depositFor` routes principal into the new strategies with correct first-deposit accounting.
7. **Seed V2 with the recovered minter funds:** `minterV2.noMintDeposit(newDolaYS, DOLA, recovered)`
   and `noMintDeposit(newUsdcYS, USDC, recovered)` using the amounts the owner actually received in
   step 4 (NOT the §5.8 recorded figures — the minter eats the haircut).
8. **Transfer the skimmed surplus to the staker as a set-aside buffer (AFTER the rewire):**
   `safeTransfer` the DOLA, USDC, and USDe amounts skimmed in step 1 from the operator to the
   StableStaker address. No further `setYieldStrategy` runs after this, so the balance stays idle on
   the staker and behaves as the set-aside buffer (§3.3). Do NOT deposit it into any yield strategy.
9. **Unpause** the staker.

### Script 3 — Accumulator rewire & verification

1. Repoint `StableYieldAccumulator` to the new DOLA/USDC strategies; remove/retire the old
   strategies as accumulator sources. Keep the USDe market YS as-is.
2. Deauthorize the StableStaker / minterV1 as clients on the **old** strategies once confirmed empty
   (optional cleanup; the old strategies are decoupled regardless).
3. Update `server/deployments/mainnet-addresses.ts`: new DOLA/USDC strategies, minter V2,
   (accumulator if changed).
4. **Verification gates (assert all):**
   - `staker.stakerCount(DOLA|USDC)` matches expected; `migrator.totalParked(DOLA|USDC) == 0`.
   - `newDolaYS.principalOf(DOLA, staker) > 0`, `newUsdcYS.principalOf(USDC, staker) > 0`.
   - Staker not underwater on either pool (`withdrawDisabled == false`).
   - `newDolaYS.principalOf(DOLA, minterV2) > 0`, `newUsdcYS.principalOf(USDC, minterV2) > 0`.
   - USDe market YS client set includes minterV2; minterV1 still authorized; USDe pool untouched.
   - `phUSD.setMinter(minterV1) == false`; `phUSD.setMinter(minterV2) == true`.

---

## 6. Fallbacks & residual risk

- **If `migrateIn` never completes** (operator incapacitated), parked stakers recover principal via
  `InPlaceMigrator.claimTimedOut(token)` after `migrationTimeout`. phUSD was already minted at
  `migrateOut`.
- **If the `totalWithdrawal` window lapses** before Script 2, re-initiate phase-1 and wait the 24h
  again (§4). Nothing else is invalidated.
- **Severe insolvency** (a pool worth less than the staker principal) would break the
  "staker made whole" guarantee even with correct ordering. Currently solvent; if that changes,
  pre-fund the staker (transfer tokens to it = buffer) before Script 2.
- **V2 also has no withdraw** — the next strategy swap will again require an owner `withdrawAsOwner`
  / `totalWithdrawal` on the strategies. Acceptable while the operator owns the strategies; noted so
  it isn't a surprise later.

---

## 7. Resolved decisions (operator sign-off, 2026-06-15)

1. **`InPlaceMigrator.migrationTimeout = 2 weeks.**
2. **V2 minter configs:** same exchange rates and decimals as V1's current DOLA/USDC/USDe configs
   (read from V1 on-chain at scripting time), with **`maxMintPerDay = 4000 phUSD (4000e18)` on each**
   of DOLA, USDC, USDe.
3. **Skimmed DOLA/USDC surplus is swept into the StableStaker contract** to act as a set-aside
   buffer — transferred AFTER the rewire so `setYieldStrategy` does not pull it into the YS. It must
   NOT be deposited into any yield strategy or sent anywhere else.
4. **USDe surplus: same as (3)** — transferred to the StableStaker as buffer.

Still to source at scripting time (facts, not decisions): the exact on-chain V1 exchange
rates/decimals (§5.6 — read live in-script), the live `executableAt` window for the in-flight
`totalWithdrawal` (§4), and the full staker address lists (read live via `getStakers` in-script).

---

## 8. Implementation (built 2026-06-15)

| Step | Script | npm (preview / broadcast) | Address patch |
|---|---|---|---|
| 2.1 deploy & freeze | `script/MigrateSaga2Deploy.s.sol` | `migrate:saga2.1-deploy-preview` / `migrate:saga2.1-deploy` | `scripts/patch-mainnet-addresses-saga2-deploy.js` (YieldStrategyDola/USDC, PhusdStableMinter) |
| 2.2 migrate | `script/MigrateSaga2Migrate.s.sol` | `migrate:saga2.2-migrate-preview` / `migrate:saga2.2-migrate` | none (no new deploys) |
| 2.3 accumulator rewire & verify | `script/MigrateSaga2Rewire.s.sol` | `migrate:saga2.3-rewire-preview` / `migrate:saga2.3-rewire` | none (accumulator repointed in place) |

- Cross-script handoff: 2.1 (broadcast only) writes `script/migration-inputs/saga2-deployments.json`
  (migrator, ysDolaV2, ysUsdcV2, minterV2, recorded V1 principals); 2.2 and 2.3 read it.
- Preview = `PREVIEW_MODE=true` + `vm.startPrank(owner)` (no broadcast); broadcast = Ledger at
  `m/44'/60'/46'/0/0`. Each broadcast chains its own preview first as a simulation gate.
- The allotment amounts (`DOLA_ALLOTMENT` / `USDC_ALLOTMENT`) are the knob to set before broadcasting
  2.1 (hardcoded 0 → tripwire reverts until set).
- Set-aside buffer: BOTH cushions are configured — (1) skimmed surplus → staker idle balance (2.2),
  and (2) the strategy-level 10% withholding for the staker on the NEW strategies (2.1 step 5a), with
  the buffer recipient set to the stable-staker. The OLD strategies are not touched (their deployed
  bytecode predates the global-recipient feature and returns the buffer to the skimmed client). 2.3
  asserts the 10% is in place.
- The migrator's top-up feature (stable-staker story-013, now pulled) funds shortfalls during
  `migrateIn` from the migrator's surplus balance — i.e. the allotment transferred in 2.1 — and
  reverts the batch if underfunded.
