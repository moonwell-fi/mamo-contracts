# venue-migration Specification

## Purpose
Enables the leveraged Aerodrome CL strategy to be migrated in place to a different Slipstream pool — including a different token pair — without terminating the strategy, redeploying the vault, or requiring any action from users holding vault shares.
## Requirements
### Requirement: Flatten operation unwinds the book to idle USDC without terminating the strategy

The strategy SHALL provide a flatten operation, callable only by the proposer, that fully exits the CL position (unstakes from the gauge, removes all liquidity, collects owed amounts), repays all outstanding leg debt, and withdraws all Moonwell collateral, leaving the entire book as idle USDC held by the strategy. The strategy SHALL remain in the `Executed` state after flattening; funds SHALL NOT be pushed to the vault and share issuance/redemption SHALL remain available.

#### Scenario: Proposer flattens a deployed book

- **WHEN** the proposer calls flatten on a strategy in the `Executed` state with an active CL position and leg debt
- **THEN** the strategy ends with no CL position (`tokenId == 0`), zero hedged-debt bases, zero outstanding debt on both leg markets, zero Moonwell collateral, and its full NAV as idle USDC, still in the `Executed` state

#### Scenario: Non-proposer cannot flatten

- **WHEN** any address other than the proposer calls flatten
- **THEN** the call reverts and the book is unchanged

#### Scenario: Deposits and redemptions work on a flat book

- **WHEN** the book is flat (all NAV in idle USDC) and a user deposits or redeems
- **THEN** shares are priced against the idle-USDC NAV exactly as they would be against a deployed book of equal NAV, and the operation succeeds

### Requirement: Vault owner stages venue configuration

The system SHALL allow only the vault's owner to stage a complete new venue configuration (pool, leg tokens, gauge, tick spacings, Moonwell markets, oracle feeds, width band, and LTV/health parameters). Staging SHALL NOT modify the live venue or the deployed book. Staging a new configuration SHALL replace any previously staged configuration, and the owner SHALL be able to clear a staged configuration without executing it.

#### Scenario: Owner stages a config

- **WHEN** the vault owner stages a venue configuration while the strategy is running against its current venue
- **THEN** the staged configuration is recorded, an event is emitted, and the live venue, positions, and share pricing are unchanged

#### Scenario: Non-owner cannot stage

- **WHEN** any address other than the vault owner (including the proposer) attempts to stage or clear a venue configuration
- **THEN** the call reverts

#### Scenario: Owner clears a staged config

- **WHEN** the vault owner clears the staged configuration before it is executed
- **THEN** no migration can execute until a new configuration is staged

### Requirement: Proposer executes migration only when a config is staged and the book is flat

The strategy SHALL provide a migration operation, callable only by the proposer, that switches the strategy's venue to the staged configuration. The migration SHALL revert unless a configuration is staged AND the book is flat: no CL position, both hedged-debt bases zero, and zero outstanding debt on both current leg markets. Executing the migration SHALL consume the staged configuration.

#### Scenario: Successful migration

- **WHEN** a venue configuration is staged, the book is flat, and the proposer executes the migration
- **THEN** the strategy's venue (pool, legs, gauge, spacings, markets, feeds, width band, LTV parameters) is replaced by the staged configuration, the staged configuration is cleared, and an event records the old and new pool

#### Scenario: Migration with a non-flat book reverts

- **WHEN** the proposer attempts migration while the strategy still holds a CL position or any leg debt
- **THEN** the call reverts and no venue state changes

#### Scenario: Migration with no staged config reverts

- **WHEN** the proposer attempts migration and no configuration is staged (or it was cleared)
- **THEN** the call reverts

#### Scenario: Non-proposer cannot execute migration

- **WHEN** any address other than the proposer attempts to execute a staged migration
- **THEN** the call reverts, even if the caller is the vault owner

### Requirement: Migration re-validates the new venue to the same standard as initialization

The migration SHALL apply every venue validation enforced at strategy initialization to the staged configuration before any state is rewritten, including: pool token set matches the declared legs exactly; pool tick spacing matches the declared spacing; leg-to-USDC swap pools exist at the declared spacings (probed via the pool's factory); the gauge's reward token is not a leg and has 18 decimals; leg decimals are within the supported band; oracle feeds have the expected decimals; the width band is on-grid and within the tick domain; and target-LTV / max-LTV / collateral-factor / min-health invariants hold against the new markets. Additionally, the migration SHALL verify that the staged gauge is the gauge of the staged pool. A configuration that fails any check SHALL revert without modifying any venue state.

#### Scenario: Mismatched pool token set rejected

- **WHEN** a staged configuration's pool does not contain exactly the declared leg tokens
- **THEN** the migration reverts with a venue-mismatch error and the current venue remains active

#### Scenario: Gauge not bound to pool rejected

- **WHEN** a staged configuration's gauge does not report the staged pool as its pool
- **THEN** the migration reverts and the current venue remains active

#### Scenario: Cross-pair migration re-derives the pool shape

- **WHEN** the staged configuration's leg-B slot equals the unit of account (asset-as-a-leg shape) or differs from it (two-leg shape)
- **THEN** the migration derives and applies the correct shape from the staged configuration alone, with the same emergent-shape rule used at initialization

### Requirement: Share-ledger continuity across migration

A venue migration SHALL NOT change the vault, the share token, users' share balances, the high-water mark, or any pending redeem request. Because migration requires a flat book, the strategy's NAV immediately before and immediately after the venue rewrite SHALL be identical (its idle USDC balance), so share pricing is continuous across the migration. Deposits SHALL remain permitted throughout the flatten–migrate–redeploy sequence.

#### Scenario: Pending redeem request survives migration

- **WHEN** a user has a pending async redeem request and the strategy is flattened, migrated, and redeployed into a new venue
- **THEN** the request remains fulfillable for the same share amount, priced against post-migration NAV, without user action

#### Scenario: NAV unchanged by the venue rewrite

- **WHEN** the migration executes on a flat book holding N idle USDC
- **THEN** NAV reads N both immediately before and immediately after the migration

### Requirement: Residual tokens of a former venue become rescuable

After a migration to a venue with different leg tokens, any residual balance of the former legs (unwind dust) SHALL be rescuable to the vault through the existing rescue path, and the former legs SHALL no longer be treated as protected core tokens.

#### Scenario: Old-leg dust rescued after cross-pair migration

- **WHEN** a cross-pair migration completes and the strategy still holds dust of a former leg token
- **THEN** the rescue path transfers that balance to the vault instead of reverting

