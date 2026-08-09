# Per-Account Share Cap for the Leveraged Aero Fund

## Why

There is no limit on how much of a user's money can sit in the leveraged Aerodrome position. Mamo wants an allocation guardrail — a ceiling on how much any single per-user account may hold in the fund — so that idle USDC above that ceiling simply stays in the account instead of being pushed into a leveraged position. Today the only related control is the vault's binary `depositsOpen` freeze, which is all-or-nothing across every user.

A second, related gap: `MamoLeveragedAeroStrategy.depositIdle` deposits the account's **entire** idle USDC balance. The backend has no way to deploy part of it, which is exactly what a cap requires (an account holding more idle USDC than its remaining cap room could otherwise never deposit at all).

## What Changes

- Add a **global share cap** to `LeveragedAeroVault`: one `maxSharesPerAccount` value (vault shares, 12dp) settable only by the vault owner (MAMO multisig via `Ownable2Step`). `0` means **unlimited**, so a fresh deployment is never bricked.
- Enforce the cap inside the **per-user account** (`MamoLeveragedAeroStrategy`): any deposit that would leave the account holding more than `maxSharesPerAccount` vault shares **reverts**. Applies to both `deposit` and `depositIdle`.
- **BREAKING**: `depositIdle(uint256 minShares)` becomes `depositIdle(uint256 assets, uint256 minShares)` — the backend chooses how much of the account's idle USDC to deploy instead of always deploying all of it. Reverts if `assets` exceeds the idle balance.
- Add a read helper so operations can convert a USDC figure into the share number the multisig must actually set (shares are 12dp against 6dp USDC).
- `deposit` remains **permissionless** (unchanged), so any keeper can still fund an account.

## Capabilities

### New Capabilities

- `account-share-cap`: A global, multisig-set ceiling on the vault shares a single per-user account may hold, enforced at every account deposit path, plus the partial-deposit control that makes the ceiling usable.

### Modified Capabilities

<!-- none — no existing specs in openspec/specs/ -->

## Impact

- **Contracts changed**: `src/LeveragedAeroVault.sol` (new storage field, setter, event, view helper), `src/MamoLeveragedAeroStrategy.sol` (cap enforcement, `depositIdle` signature).
- **Contracts NOT changed**: `LeveragedAerodromeCLStrategy` and its libraries (the pooled fund is untouched — no diamond-storage `Layout` change, so the three byte-identical copies stay as they are), `MamoLeveragedAeroStrategyFactory`.
- **Storage**: the account is UUPS-upgradeable with an append-only convention after slot 50, but this change adds **no** account storage — the cap value is read from the vault, which the account already references as `vaultShares`. The vault gains one field; nothing leveraged-aero is deployed on Base yet, so there is no live-storage constraint.
- **Callers**: the backend's `depositIdle` integration must pass an amount. Any off-chain caller of `depositIdle` breaks until updated.
- **Deliberate non-goals**: this does **not** bound total fund size (N accounts × cap each is unbounded — a fund-wide TVL cap would be separate work), and it is **not** a security boundary (the pooled `LeveragedAerodromeCLStrategy.deposit` is permissionless, so a depositor bypassing the account layer is uncapped; all product flows go through accounts).
- **Tests**: new unit coverage for cap enforcement on both deposit paths, the unlimited sentinel, the setter's access control, and partial `depositIdle`.
