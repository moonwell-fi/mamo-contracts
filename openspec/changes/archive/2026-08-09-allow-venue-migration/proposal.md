# Allow Venue Migration for LeveragedAerodromeCLStrategy

## Why

The leveraged Aerodrome CL strategy pins its venue — the Slipstream pool, its token pair (legs), gauge, tick spacings, Moonwell markets, and oracle feeds — at `initialize` and can never change it. When liquidity or incentives move to a different pool (including a different token pair), the only exit today is `settle`, which is terminal: it drains all USDC to the vault, and every user must individually redeem and re-deposit into a brand-new vault/strategy/account stack (all user exit hatches are `onlyOwner` on per-user accounts, so the backend cannot drive that migration). The business needs the backend to be able to move the fund to a new pool — including a new pair — without user action.

## What Changes

- Add a **flatten** operation to the strategy: fully exit the CL position (unstake from gauge, decrease liquidity, collect), repay all leg debt, withdraw all Moonwell collateral — ending with the entire book as idle USDC while remaining in the `Executed` state (unlike `settle`, which is terminal and pushes funds to the vault).
- Add **staged venue configuration**: the vault owner (multisig) stages a complete new venue config (pool, legs, gauge, tick spacings, Moonwell markets, oracle feeds, width band, LTV params). Staging does not touch the live book.
- Add **`migrateVenue`**: executable by the proposer (MAMO_REBALANCER backend) only when a config is staged AND the book is flat (`tokenId == 0`, both hedged-debt bases zero, no outstanding market debt). Rewrites the venue subset of the strategy's storage layout, re-running the full init-grade validation suite (venue identity, swap-pool probes, feed/leg decimals, width band, LTV/CF/health invariants, shape re-derivation), plus a new `gauge.pool() == pool` binding check.
- Redeployment into the new venue uses a new proposer-only `redeploy()` entry (fresh genesis mint from a flat book, reusing the Manager's existing `executeImpl` sequence); subsequent top-ups reuse `deployIdle`. *(Revised during implementation: `deployIdle` only increases an existing position and cannot mint from flat.)*
- Share-ledger continuity: the vault, share token, per-user accounts, HWM, and pending redeem requests are untouched. With a flat book, NAV equals idle USDC, so share pricing is continuous across the migration. Deposits remain open throughout (flat-book deposits price correctly against idle-USDC NAV).
- No timelock on staged configs (explicit product decision): a staged config is executable immediately once the book is flat.

## Capabilities

### New Capabilities

- `venue-migration`: In-place migration of the leveraged Aerodrome CL strategy to a different Slipstream pool (same or different token pair): flatten-to-USDC operation, owner-staged venue configuration, proposer-executed migration with init-grade re-validation, and continuity guarantees for the vault share ledger.

### Modified Capabilities

<!-- none — no existing specs in openspec/specs/ -->

## Impact

- **Contracts changed**: `src/leveraged-aero/LeveragedAerodromeCLStrategy.sol` (new entry points, staged-config storage, validation refactor), `src/leveraged-aero/LeveragedAeroManager.sol` (flatten + migration implementation — the strategy body is at the EIP-170 cap, so new logic must live in the delegatecall library), possibly `src/leveraged-aero/LeveragedAeroValuation.sol` (venue-derived config reads).
- **Contracts NOT changed**: `LeveragedAeroVault` (holds no venue state; `strategy` pointer remains set-once), `MamoLeveragedAeroStrategy` per-user accounts, `MamoLeveragedAeroStrategyFactory`.
- **Storage**: venue fields in the strategy's `Layout` are rewritten in place (no layout change); staged-config fields are appended (byte-identical append-only convention).
- **Security surface**: new privileged flow — vault owner picks the venue, backend hot key only executes an owner-approved config. Migration re-runs every init validation; the currently-missing `gauge.pool() == pool` check becomes load-bearing and is added.
- **Operational constraint**: new pairs are limited to assets with live, borrowable Moonwell markets and Chainlink feeds on Base.
- **Tests**: new fork tests for flatten, staging, migration (same-pair and cross-pair, including asset-mode flips), plus regression on deposit/redeem continuity across a migration.
