# fund-capacity-cap

## Purpose

A multisig-set ceiling on the total size of the leveraged Aero fund, so the position cannot grow past
the capacity its underlying venues can absorb. Distinct from the vault's binary `depositsOpen` freeze:
this is a size limit that binds automatically, not a switch someone must remember to flip.

## Requirements

### Requirement: The vault carries a fund capacity ceiling

`LeveragedAeroVault` SHALL expose a `maxTotalAssets` value denominated in the unit of account (USDC,
6dp), settable ONLY by the vault owner. `0` SHALL mean unlimited, so a fresh deployment is never
bricked before the owner acts. Setting it SHALL emit an event.

#### Scenario: The ceiling defaults to unlimited

- **WHEN** a vault is freshly deployed
- **THEN** `maxTotalAssets` is `0`, and deposits are unconstrained by it

#### Scenario: Only the owner may set the ceiling

- **WHEN** any address other than the owner calls the setter
- **THEN** the call reverts and the stored value is unchanged

### Requirement: Deposits that would cross the ceiling revert

A deposit that would leave the fund's NAV above `maxTotalAssets` SHALL revert. The rejection SHALL be
a revert — the deposit SHALL NOT be silently trimmed to the room that remains — and it SHALL apply to
EVERY path that mints new shares, so that no depositor and no wrapper layer can exceed it. A deposit
that leaves the fund exactly at the ceiling SHALL succeed.

#### Scenario: A deposit that would cross the ceiling is rejected

- **WHEN** the fund is below the ceiling and receives a deposit large enough to cross it
- **THEN** the call reverts, no shares are minted, and no USDC leaves the depositor

#### Scenario: A deposit landing exactly at the ceiling succeeds

- **WHEN** a deposit would leave the fund's NAV exactly at `maxTotalAssets`
- **THEN** the deposit succeeds

#### Scenario: A full fund refuses everyone

- **WHEN** the fund is at or above the ceiling and ANY account deposits — including one holding no
  shares at all
- **THEN** the call reverts, because the ceiling is a limit on the fund and not on any one holder

### Requirement: Capacity gates deposits only

No withdrawal path SHALL consult the capacity ceiling. Lowering the ceiling below the fund's current
NAV SHALL NOT unwind, trap, or penalise any existing holder; it SHALL only close new deposits until
the fund is back under the ceiling.

#### Scenario: Lowering the ceiling under a live book does not trap holders

- **WHEN** the owner lowers `maxTotalAssets` below the fund's current NAV
- **THEN** deposits are refused, and every holder can still withdraw in full by every exit path

#### Scenario: Withdrawing frees capacity for other depositors

- **WHEN** a holder exits and the fund's NAV falls back below the ceiling
- **THEN** the freed capacity is immediately available to any depositor, because the ceiling is
  measured against live NAV rather than a high-water mark

### Requirement: Fee-share issuance is never gated on capacity

Share issuance for protocol / performance / management fees SHALL NOT be subject to the capacity
ceiling. Fees are an accounting event rather than new capital, and the strategy mints them
best-effort, so a capacity-blocked fee mint would defer fees indefinitely instead of reverting.

#### Scenario: A fee crystallisation succeeds against a full fund

- **WHEN** the fund is at or above its capacity ceiling and a fee crystallisation mints fee-shares
- **THEN** the mint succeeds

### Requirement: The remaining capacity is readable

The vault SHALL expose the USDC still depositable before the ceiling is reached, so depositors and
keepers can size a deposit rather than discovering the limit by reverting. An unlimited fund SHALL be
distinguishable from a full one.

#### Scenario: Remaining capacity distinguishes unlimited from full

- **WHEN** the ceiling is disabled (`0`)
- **THEN** the read reports the maximum representable value, not `0`

#### Scenario: Remaining capacity floors at zero

- **WHEN** the fund's NAV has drifted at or above the ceiling
- **THEN** the read reports `0` rather than underflowing

### Requirement: The caller chooses how much idle USDC to deploy

`depositIdle` SHALL accept the amount of idle USDC to deploy rather than always deploying the
account's entire idle balance, and SHALL reject an amount greater than the balance held. This is what
keeps accounts usable against the ceiling: an account holding more idle USDC than the fund's remaining
capacity must still be able to deploy the part that fits.

#### Scenario: The backend deploys the slice that fits

- **WHEN** an account holds more idle USDC than the fund's remaining capacity, and the caller deposits
  an amount within that capacity
- **THEN** the deposit succeeds and the remainder stays idle on the account, withdrawable by the owner
