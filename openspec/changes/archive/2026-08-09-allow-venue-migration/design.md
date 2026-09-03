# Design: Venue Migration for LeveragedAerodromeCLStrategy

## Context

See `proposal.md` — Why. Facts that shape the approach:

- **Venue state lives only in the strategy.** `LeveragedAeroVault` holds no pool state and its `strategy` pointer is set-once by documented invariant; per-user `MamoLeveragedAeroStrategy` accounts pin the strategy address and expose user-only exit hatches. Any backend-drivable migration must therefore happen inside the strategy.
- **The strategy clone is immutable** (no upgrade path — the vault's docs treat clone immutability as a trust property). This feature must land in the strategy template *before* production deployment; already-deployed clones cannot gain it.
- **EIP-170**: the strategy body is at the size cap; heavy logic already lives in the `LeveragedAeroManager` delegatecall library (with `LeveragedAeroValuation` split out for the same reason). All new migration logic must go into the Manager (or a new library), not the strategy body.
- **State machine** (`sherwood/BaseStrategy`): `Pending → Executed → Settled`, one-way. `settleImpl` already unwinds the whole book to USDC, but `_settle` is terminal and pushes funds to the vault — migration needs the unwind without the terminal transition.
- **Unit-of-account continuity**: shares live in the vault and are priced off strategy NAV in USDC. A flat book's NAV is exactly its idle USDC, which is what makes in-place migration share-price-continuous.
- **Existing precedents**: `rerange` (proposer) already exits and re-mints the CL position; `rescueToVault` already recognizes `Ownable(vault()).owner()` as an authority; the `Layout` struct follows an append-only, byte-identical convention.

## Goals / Non-Goals

**Goals:**

- Backend-drivable venue change (pool, pair, gauge, spacings, markets, feeds, width band, LTV params) with zero user action and zero vault/account changes.
- Owner-in-the-loop authorization: the hot proposer key can never choose the destination venue.
- Init-grade (or stronger) validation of the destination venue.

**Non-Goals:**

- Migrating already-deployed strategy clones (impossible — immutable).
- Rotating the vault's `strategy` pointer (explicitly forbidden by the vault's trust model).
- Atomic flatten+migrate+redeploy in one transaction (sequenced proposer calls are acceptable; the book is safe in USDC between steps).
- Changing the unit of account (USDC stays the asset; `usdc`, `mUsdc`, `usdcFeed`, `sequencerFeed`, `npm`, `swapRouter`, `comptroller` are not part of the staged venue).

## Decisions

### D1: Hash-commit staging, full params at execute

The owner stages `keccak256(abi.encode(VenueParams))` (one `bytes32` slot, appended to `Layout`); the proposer executes `migrateVenue(VenueParams calldata p)` and the strategy checks the hash before validating and applying. Staging an empty hash clears.

- *Why*: avoids persisting a full ~20-field struct in storage (Layout bloat + append-only churn); the owner authorizes an exact config byte-for-byte; calldata is validated live at execute time.
- *Alternative rejected*: storing the full staged struct — more storage writes, more Layout surface, no additional safety (validation runs at execute either way).

### D2: Access split — owner stages, proposer executes

Stage/clear: `msg.sender == Ownable(vault()).owner()` (the multisig; same authority pattern `rescueToVault` already uses). Flatten and `migrateVenue`: `onlyProposer` (MAMO_REBALANCER), reusing the role that already commands `rerange`/`adjustLeverage`/`deployIdle`.

- *Why*: the migration's power (redefining the fund's risk) sits with the owner; the hot key only sequences execution of an owner-approved config. No timelock (explicit product decision — see proposal).
- *Alternative rejected*: proposer-only — a compromised hot key could rotate the fund into an attacker-shaped venue.

### D3: `flattenImpl` as a non-terminal sibling of `settleImpl`

New Manager function sharing the unwind path with `settleImpl` (unstake, decrease, collect, repay both legs, withdraw all collateral, zero `hedgedDebtA/B`, clear `tokenId`/ticks) but *not* discharging protocol fees to the recipient, *not* pushing USDC to the vault, and *not* changing `_state`. Strategy-side entry `flatten(uint256 minOut...)` is `onlyProposer nonReentrant`, gated on `State.Executed`, with slippage guards mirroring the unwind legs' existing min-out conventions.

- *Why*: `settleImpl` is proven; reusing its internals minimizes new unwind code. Keeping fees accrued (not discharged) preserves normal fee lifecycle — flatten is an operational move, not a fund event.
- *Alternative rejected*: sequencing existing calls (`adjustLeverage(0)` + `rerange`-style exit) — no combination today reaches "no position, no debt, no collateral" while staying `Executed`.

### D4: Shared venue-validation library function

Extract the venue-validation block from `_initialize` into a library function (Manager or a small new `LeveragedAeroVenue` lib): zero-address checks, pool token-set/tickSpacing match, `wethIsToken0` + leg-decimal derivation, swap-pool factory probes, reward-token exclusions + 18dp check, feed-decimal checks for the staged leg feeds, width-band checks, CF/LTV/health invariants against the *staged* markets. Both `_initialize` and `migrateVenue` call it.

- *Why*: guarantees migration validation can never drift below init validation, and moves bytes out of the at-cap strategy body.
- **Add `gauge.pool() == pool`** to the shared function. Init currently trusts the deployer on gauge binding; with a runtime migration this check is load-bearing (wrong gauge = staked NFT stranded). Adding it to the shared path hardens init too.

### D5: Migration rewrites the venue subset of `Layout` in place

Applied fields: `cbBTC`, `weth`, `mCbBTC`, `mWeth`, `pool`, `gauge`, `tickSpacing`, `cbBTCSwapTickSpacing`, `wethSwapTickSpacing`, `cbBTCFeed`, `wethFeed`, `wethIsToken0`, leg decimals, shape flag (emergent from config, same rule as init: leg-B slot == usdc ⇒ asset mode), `width`/`minWidth`/`maxWidth`, `targetLtvBps`/`maxLtvBps`/`minHealthBps`. Flat-book gate checked immediately before rewrite: `tokenId == 0 && hedgedDebtA == 0 && hedgedDebtB == 0 && borrowBalance(mCbBTC) == 0 && borrowBalance(mWeth) == 0` (current markets). No `Layout` layout change for live fields; only the staged-hash slot is appended.

- *Why*: rewriting values in existing slots is layout-safe under the append-only convention; the flat-book gate plus USDC-only NAV makes the rewrite value-neutral by construction.

### D6: Redeploy via a new `redeploy()` genesis entry; deposits stay open; no auto-pause

*(Revised during implementation.)* `deployIdle` cannot re-enter from a flat book: it `increaseLiquidity`s the stored `tokenId`, which is 0 after a flatten (a real gauge/NPM reverts on it), and `rerange` is an explicit no-op on flat. The only fresh-mint sequence is `executeImpl` (vault-only, one-shot at activation). Fix: a new proposer entry `redeploy()` that requires `tokenId == 0` and delegates to the already-deployed `LeveragedAeroManager.executeImpl` (genesis sequence: enterMarkets, calm-gate, centred range at stored width, supply+borrow at stored target LTV, mint+stake, health assert) — zero new bytes in the at-cap Manager. It deploys the entire idle balance with the same slippage posture as activation (calm-gate + §8 two-sided floor). Subsequent top-ups use `deployIdle` as before.

Flat-book deposits price correctly (NAV = idle USDC), so no pause mechanism is added; the vault's deposit switch remains available as a manual override.

## Risks / Trade-offs

- [Flatten realizes slippage/MEV on full unwind] → per-leg min-out parameters on `flatten` (same guard style as `settleImpl`/`deleverage`); backend sizes them off-chain; calm-gate/TWAP checks still apply on swaps.
- [Owner stages a malicious/wrong config; no timelock means LPs get no exit window] → accepted product decision; mitigants: owner is the existing multisig trust root (already rescue authority + fee-config authority), config is hash-committed byte-exact, and validation rejects structurally invalid venues. Revisit timelock if LP base broadens.
- [New pair lacks borrowable Moonwell market or Chainlink feed] → validation reverts at execute (CF read, feed-decimals checks); operational constraint documented — pair universe is Moonwell-listed assets.
- [Old-leg dust stranded after cross-pair migration] → `rescueToVault`'s denylist reads live `Layout`, so former legs become rescuable automatically; runbook includes a dust-rescue step.
- [Pending redeem requests during migration] → requests are share-denominated and fulfil against NAV; flat-book NAV continuity keeps them fulfillable. Add explicit fork test.
- [`aeroUsdFeed` assumed to keep matching the new gauge's reward token] → shared validation re-checks `rewardToken` is 18dp and not a leg; Aerodrome gauges pay AERO universally, and the feed is not part of the staged venue. If a gauge ever pays a non-AERO reward, validation's decimals/exclusion checks are the backstop and the venue is rejected by ops policy.
- [Library bytecode growth] → Manager is itself near EIP-170; if `flattenImpl` + validation overflow it, split the venue-validation into a separate library (linked like `LeveragedAeroValuation`). Size-check both artifacts in CI.

## Migration Plan (ops runbook, per venue change)

1. Owner (multisig): `stageVenue(keccak256(abi.encode(params)))`.
2. Backend: `flatten(minOuts...)` — book → idle USDC (may be batched close to step 3 to minimize idle time).
3. Backend: `migrateVenue(params)` — validates, rewrites venue, clears stage.
4. Backend: `deployIdle(amount, minLiquidity)` — enter new venue; then `rescueToVault(oldLeg)` for any dust.
5. Rollback: before step 3, `deployIdle` re-enters the *old* venue (nothing changed); a failed step 3 reverts atomically; after step 3, rollback = stage the old venue config and repeat.

## Open Questions

- Exact min-out parameterization of `flatten` (single aggregate USDC floor vs per-leg floors) — decide during implementation against `settleImpl`'s existing guard shape; does not affect specs.
- Whether the shared validation lands in `LeveragedAeroManager` or a new library — pure size question, measured at build time.
