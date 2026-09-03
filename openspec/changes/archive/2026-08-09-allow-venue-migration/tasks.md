# Tasks: allow-venue-migration

> Branch note: implemented on `feat/venue-migration` (branched from `feat/leveraged-aero-vanilla-vault`).
> Test-style note: tasks 4.4/5.x were written as "fork tests"; this branch's leveraged-aero suites are
> deliberately fork-free (custodial mocks with real Slipstream geometry — see `LeveragedAeroVenuesHarness.sol`),
> so they were implemented in that style. The Tenderly vnet harness remains the fork-ish layer.

## 1. Shared venue validation

- [x] 1.1 Extract the venue-validation block from `LeveragedAerodromeCLStrategy._initialize` into a library function (landed as the new deployed library `LeveragedAeroVenue.applyVenue` — the Manager was itself at the EIP-170 cap) taking a `VenueParams`-shaped struct; derived values (`wethIsToken0`, leg decimals, shape flag, collateral factor) are validated AND stored there
- [x] 1.2 Add the `gauge.pool() == pool` binding check to the shared validation (new check — init previously trusted the deployer on gauge binding; `ICLGauge.pool()` added to the vendored interface, `MockCLGauge` already had it)
- [x] 1.3 Rewire `_initialize` to call the shared validation with preserved check order/errors (init suite: 80/80 pass unchanged); `forge build --sizes`: strategy 24,228 → 22,435 B (2,141 margin), Manager untouched at 24,237, Venue lib 7,530

## 2. Flatten

- [x] 2.1 `flattenImpl` in the Venue library: reuses `LeveragedAeroManager.settleImpl` verbatim (it never pushed to the vault or changed state — those live in `_settle`), then zeroes `hedgedDebtA/B` (same pathological-case belt as `_settle`); slippage is settle's own Chainlink-floored `maxSlippageBps` guard, so no caller min-outs
- [x] 2.2 Strategy entry `flatten()` (`onlyProposer nonReentrant`, `State.Executed`); `Flattened(idleUsdc)` event
- [x] 2.3 Tests: flatten ends flat (tokenId 0, zero bases, zero debt, zero collateral, NAV == idle, still `Executed`); non-proposer reverts; idempotent; deposit AND redeem work on the flat book

## 3. Staging (owner)

- [x] 3.1 `stagedVenueHash` (bytes32) appended to all THREE byte-identical `Layout` copies (strategy/Manager/Venue; `layout_parity.sh` extended to 3-way diff); `stageVenue(bytes32)` gated to `Ownable(vault()).owner()` (`NotVaultOwner`), 0 clears; `VenueStaged` event
- [x] 3.2 Tests: owner stages/clears; proposer and third parties revert; staging changes no live venue state

## 4. Migration (proposer)

- [x] 4.1 `LeveragedAeroVenue.VenueParams` struct (legs, markets, feeds, pool, gauge, spacings, width band, LTV/health params; non-migratable core read from live storage)
- [x] 4.2 `migrateVenue(VenueParams calldata)` (`onlyProposer nonReentrant`, `State.Executed`): staged-hash byte-match (`VenueNotStaged`), flat-book gate (`BookNotFlat`: tokenId/hedged bases/borrowBalanceStored on both current markets), shared validation, venue-subset rewrite, hash consumed, `VenueMigrated(oldPool, newPool)`
- [x] 4.3 Tests: unstaged + tampered-params revert; live-position and residual-debt revert; non-proposer (incl. owner) reverts; invalid configs revert venue-untouched (wrong token set, gauge unbound, missing swap pool, off-grid width, targetLtv > maxLtv)
- [x] 4.4 Tests: cross-pair migration (full venue-subset rewrite asserted field-by-field) and two-leg → asset-mode shape flip (`legBIsAsset` re-derived, mUsdc/usdcFeed/spacing-0 pins)

## 4b. Redeploy (discovered during implementation)

- [x] 4b.1 `redeploy()` (`onlyProposer`) → `LeveragedAeroVenue.redeployImpl` → `Manager.executeImpl` genesis sequence; `PositionAlreadyOpen` guard. Needed because `deployIdle` only `increaseLiquidity`s an existing NFT and `rerange` no-ops on flat — no path re-opened a position from a flat `Executed` book. Design/proposal artifacts updated (D6 revised).

## 5. End-to-end continuity

- [x] 5.1 Full sequence test: deployed book → flatten → migrate → redeploy into venue B; NAV identical across the rewrite, share balances + HWM untouched, entire idle redeployed as collateral at the NEW venue's target LTV, old markets debt-free, new gauge staked
- [x] 5.2 Pending async redeem request created pre-flatten fulfills post-redeploy for the same shares
- [x] 5.3 After cross-pair migration `rescueToVault(oldLeg)` sweeps former-leg dust; NEW leg refused (`CannotRescuePositionToken`)
- [x] 5.4 Full unit sweep: 617/617 pass (`test/*.unit.t.sol`, includes all leveraged-aero suites + LayoutParity 3-way); sizes all under EIP-170 (`forge build --sizes`); `forge fmt` run (NOTE: local forge 1.7.1 — verify against CI's pinned nightly before merge)

## 6. Docs & ops

- [x] 6.1 Natspec on all new entry points + Venue library (trust split, flat-book invariant, redeploy-vs-deployIdle routing); `docs/integrations/LEVERAGED_AERO_REBALANCER.md` gained §G2 with the 4-step runbook + rollback path
- [x] 6.2 Multisig staging recipe (`keccak256(abi.encode(VenueParams))`, non-migratable core excluded) documented in §G2
