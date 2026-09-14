# Fund Capacity Cap for the Leveraged Aero Fund

## Why

There is no limit on how large the leveraged Aerodrome position can grow. Mamo wants a capacity
ceiling — a maximum size for the fund as a whole — because the strategy's edge is bounded by how much
the underlying Aerodrome pool and Moonwell markets can absorb, and past that point new capital dilutes
returns for everyone already in. Today the only related control is the vault's binary `depositsOpen`
freeze, which is all-or-nothing and has to be toggled by hand.

A second, related gap: `MamoLeveragedAeroStrategy.depositIdle` deposits the account's **entire** idle
USDC balance. The backend has no way to deploy part of it, which is exactly what a ceiling requires (an
account holding more idle USDC than the fund's remaining capacity could otherwise never deposit at all).

## What Changes

- Add a **fund capacity cap** to `LeveragedAeroVault`: one `maxTotalAssets` value (USDC, 6dp) settable
  only by the vault owner (MAMO multisig via `Ownable2Step`). `0` means **unlimited**, so a fresh
  deployment is never bricked.
- Enforce it inside `LeveragedAerodromeCLStrategy.deposit` — the single path every share-minting
  deposit takes, per-user accounts and direct depositors alike — so the ceiling binds the FUND rather
  than one wrapper layer. A deposit that would cross the ceiling **reverts** `FundAtCapacity`;
  measured on the post-deposit book against the post-crystallise net NAV.
- Deliberately NOT enforced in `LeveragedAeroVault.strategyMint`: that also serves fee-share
  crystallisations, which the strategy performs best-effort inside a try/catch, so a capacity-blocked
  fee mint would silently defer fees forever. Fees are an accounting event, not new capital.
- Add `remainingCapacity()` so depositors and keepers can size a deposit to the room that is left
  (`type(uint256).max` when the cap is disabled, disambiguating "unlimited" from "full").
- **BREAKING**: `depositIdle(uint256 minShares)` becomes `depositIdle(uint256 assets, uint256 minShares)`
  — the backend chooses how much of the account's idle USDC to deploy instead of always deploying all
  of it. Reverts if `assets` exceeds the idle balance.
- `deposit` remains **permissionless** (unchanged), so any keeper can still fund an account.

## Capabilities

### New Capabilities

- `fund-capacity-cap`: A multisig-set ceiling on the fund's total NAV, enforced at the single deposit
  path every depositor takes, plus the partial-deposit control that makes the ceiling usable.

### Modified Capabilities

<!-- none — no existing specs in openspec/specs/ -->

## Impact

- **Contracts changed**: `src/LeveragedAeroVault.sol` (new storage field, setter, event, two views),
  `src/leveraged-aero/LeveragedAerodromeCLStrategy.sol` (the capacity check in `deposit` and a local
  interface for the vault getter — no diamond-storage `Layout` change, so the three byte-identical
  copies stay as they are), `src/MamoLeveragedAeroStrategy.sol` (`depositIdle` signature only).
- **Contracts NOT changed**: `MamoLeveragedAeroStrategyFactory`, the strategy's libraries.
- **Not a security boundary in the pooled sense**: the ceiling is a size control, not an access
  control. It binds every deposit path that mints shares, but it does not (and is not meant to)
  prevent value entering the venue by other means.
