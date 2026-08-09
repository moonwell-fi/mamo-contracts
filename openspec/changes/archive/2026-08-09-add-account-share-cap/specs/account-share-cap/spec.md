# account-share-cap Delta Spec

## Purpose

Caps how much of the leveraged Aerodrome fund any single per-user account may hold, so operators can bound each user's allocation to a leveraged position while leaving the rest of their USDC untouched in their own account.

## ADDED Requirements

### Requirement: The vault carries a single global share cap set only by its owner

`LeveragedAeroVault` SHALL expose a `maxSharesPerAccount` value denominated in vault shares that applies identically to every per-user account. Only the vault owner SHALL be able to change it, and each change SHALL emit an event carrying the new value. A value of `0` SHALL mean **unlimited** (no cap enforced), so a freshly deployed vault never blocks deposits before the owner has acted.

#### Scenario: Owner sets the cap

- **WHEN** the vault owner sets `maxSharesPerAccount` to a non-zero value
- **THEN** the value is stored, an event carrying it is emitted, and every account reads the same value

#### Scenario: Non-owner cannot set the cap

- **WHEN** any address other than the vault owner attempts to set `maxSharesPerAccount`
- **THEN** the call reverts and the stored value is unchanged

#### Scenario: Zero means unlimited

- **WHEN** `maxSharesPerAccount` is `0`
- **THEN** deposits of any size succeed and no cap check rejects them

### Requirement: Account deposits that would breach the cap revert

A per-user account SHALL reject any deposit that would leave it holding more vault shares than `maxSharesPerAccount`. The rejection SHALL be a revert — the account SHALL NOT silently deposit a reduced amount — and it SHALL apply to every path that mints shares into the account, including both the permissionless `deposit` and the owner-or-backend `depositIdle`. A deposit that leaves the account exactly at the cap SHALL succeed.

#### Scenario: Deposit that would exceed the cap is rejected

- **WHEN** an account holding shares at or near the cap receives a deposit whose resulting share balance would exceed `maxSharesPerAccount`
- **THEN** the call reverts, no shares are minted, and no USDC leaves the caller

#### Scenario: Deposit landing exactly at the cap succeeds

- **WHEN** a deposit would leave the account holding exactly `maxSharesPerAccount` shares
- **THEN** the deposit succeeds

#### Scenario: The cap applies to the idle-deposit path

- **WHEN** the backend calls `depositIdle` with an amount whose resulting share balance would exceed the cap
- **THEN** the call reverts and the account's idle USDC is untouched

#### Scenario: Withdrawing frees cap room

- **WHEN** an account at the cap withdraws part of its position and then receives a new deposit within the freed room
- **THEN** the deposit succeeds, because the cap is measured against the share balance actually held

### Requirement: The backend chooses how much idle USDC to deploy

`depositIdle` SHALL accept the amount of idle USDC to deploy rather than always deploying the account's entire idle balance, and SHALL reject an amount greater than the balance held. This is what makes the cap usable: an account holding more idle USDC than its remaining cap room must still be able to deploy the part that fits.

#### Scenario: Partial idle deposit

- **WHEN** the backend calls `depositIdle` for less than the account's idle USDC balance
- **THEN** exactly that amount is deposited and the remainder stays as idle USDC in the account, withdrawable by the owner

#### Scenario: Amount above the idle balance is rejected

- **WHEN** the caller requests more than the account's idle USDC balance
- **THEN** the call reverts

#### Scenario: An over-cap account can still deploy what fits

- **WHEN** an account holds far more idle USDC than its remaining cap room
- **THEN** the backend can deposit an amount within that room successfully, rather than being blocked entirely

### Requirement: Operators can convert a USDC figure into the share cap to set

Because the cap is denominated in vault shares (12dp) while operators reason in USDC (6dp), the system SHALL expose a read-only conversion from a USDC amount to the corresponding share quantity at current pricing, so the value the multisig sets is derived from one canonical calculation rather than an ad-hoc off-chain one.

#### Scenario: Operator converts a target allocation

- **WHEN** an operator queries the conversion for a USDC amount
- **THEN** the returned share quantity is what a deposit of that USDC would mint at current pricing

#### Scenario: Conversion is advisory only

- **WHEN** the fund's share price moves after the cap is set
- **THEN** the stored cap is unchanged, and the USDC value it represents moves with the share price — the conversion is a point-in-time aid, not a peg
