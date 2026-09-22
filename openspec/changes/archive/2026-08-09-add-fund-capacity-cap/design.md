# Design: Fund Capacity Cap

## Context

See `proposal.md` — Why. Facts that shape the approach:

- **Two layers, one fund.** `MamoLeveragedAeroStrategy` is a per-user account (one clone per user, owner = the user) that custodies vault shares and forwards USDC. `LeveragedAerodromeCLStrategy` + `LeveragedAeroVault` are the single pooled fund. An account can only ever see its own slice — which is precisely why a FUND-level ceiling cannot live in the account.
- **The strategy already reads the vault every deposit.** `deposit` calls `vault()` for `totalSupply` and `strategyMint`, so reading one more value there costs a single extra call and no new plumbing.
- **`deposit` already computes NAV.** `navPre = nav()` runs before the depositor's USDC arrives, so a value-denominated ceiling needs no additional oracle read and measures cleanly against the post-deposit book.
- **The vault owner is the MAMO multisig** (`Ownable2Step`), the same authority behind `stageVenue`, `activateStrategy` and `setOpenDeposits`. The registry's `DEFAULT_ADMIN_ROLE` is a *different*, timelocked authority.
- **Nothing leveraged-aero is deployed on Base** (no entries in `addresses/8453.json`), so the vault can take a new storage field with no migration concern.
- **`strategyMint` serves two callers.** User deposits AND fee-share crystallisations. The strategy performs the latter best-effort inside a try/catch.

## Goals / Non-Goals

**Goals:**

- A single operator-set ceiling on the fund's total size, binding every depositor.
- Let the backend deploy part of an account's idle USDC.
- No new oracle dependency in the capacity path.

**Non-Goals:**

- Per-user allocation limits. Explicitly considered and rejected — see D1.
- Preventing value entering the venue by means other than a share-minting deposit.

## Decisions

### D1: Cap the FUND, not the account

An earlier iteration of this change capped the shares any ONE per-user account could hold. That was
replaced wholesale, because it answered a different question. A per-account ceiling is a
*concentration* control; what the fund needs is a *capacity* control — the strategy's edge is bounded
by what the Aerodrome pool and Moonwell markets can absorb, and that limit is a property of the fund,
not of any holder.

The per-account version was also weak on its own terms: N accounts × cap each is unbounded, so it
never bounded fund size; and because it measured `balanceOf(account)`, it was bypassable from inside a
single account by parking shares in the async-redeem escrow (`deposit → requestWithdraw → deposit →
cancelWithdraw`), which required counting escrowed shares to close. All of that machinery — the
escrow accounting, the open-request bound, the account-side check — is deleted by this design rather
than fixed, because the fund-level ceiling does not care where shares sit.

- *Accepted cost*: no concentration control. One depositor may hold an arbitrary fraction of the fund.
  If that is ever wanted, it is a separate feature and a separate knob.

### D2: Denominated in USDC, not shares

The ceiling is a value question, so it is denominated in the unit of account. Operators set the dollar
figure they mean, with no 12dp-share conversion and none of the off-by-1e6 hazard the share-denominated
version carried.

- *Accepted cost*: NAV moves on its own, so the fund can drift ABOVE the ceiling on gains alone —
  closing deposits with nobody having deposited — and back below on a drawdown, reopening them. This is
  inherent to a value-denominated capacity limit and is the intended reading: if the venue is at
  capacity, it is at capacity regardless of how that came about. Documented for operators so a
  spontaneously-closed fund is not read as a bug.
- *Alternative rejected*: capping `totalSupply` (exact, oracle-free, immune to price moves) — but its
  dollar meaning drifts upward with performance, so a "$5M fund" silently becomes a $6M fund, which is
  the opposite of what a capacity limit is for.

### D3: Enforced in the strategy's `deposit`, NOT in `strategyMint`

`deposit` is the single path every share-minting deposit takes — per-user accounts and direct
depositors alike — so enforcing there makes the ceiling bind the fund rather than one wrapper layer.
Enforcing in the account instead would have left the pooled `deposit` uncapped.

`strategyMint` looks like the tighter chokepoint but is the wrong one: it also serves FEE-SHARE
crystallisations, which the strategy performs best-effort inside a try/catch. A capacity-blocked fee
mint would be swallowed and the fee deferred **forever**, silently — the same hazard `depositsOpen`
already carries, and not one to duplicate. Fees are an accounting event, not new capital.

### D4: Reject a crossing deposit outright, do not trim

A deposit that would cross the ceiling reverts rather than being partially filled. Matches the
revert-don't-trim posture of every other guard on this path (`minShares`, `NavUnpriceable`,
`ZeroShares`), keeps the depositor's slippage expectations intact, and avoids a partial fill the caller
did not ask for. `remainingCapacity()` exists so the caller can size the retry.

### D5: Measured against `navNet`, pre-transfer

The check runs on `navNet + assets` before the depositor's USDC moves, so a rejected deposit transfers
nothing at all. `navNet` (post-crystallise) is the same basis the share price uses, so the ceiling and
the pricing agree about what the fund is worth.

### D6: `deposit` stays permissionless

Unchanged. With a fund-level ceiling the third-party-deposit concern that applied to a per-account cap
mostly evaporates: a griefer can consume the fund's remaining capacity, but they do so by handing the
fund real capital, and the capacity reopens as soon as anyone withdraws.

## Risks / Trade-offs

- [Capacity closes and reopens on its own as NAV moves] → accepted (D2); documented in all three
  integration guides so operators and the frontend treat "full" as a live, reversible state.
- [No concentration control] → accepted (D1); a separate feature if wanted.
- [`depositIdle` signature change breaks the backend integration] → BREAKING and called out in the
  proposal; coordinate the deploy with the backend change.
- [Ceiling bypassable by routes that do not mint shares] → out of scope; this is a size control, not
  an access control.
- [A vault predating `maxTotalAssets` bricks every deposit] → the strategy makes a TYPED call, which
  reverts with empty returndata against an older vault. The vault is not upgradeable, so the vnet
  harness probes the selector and refuses to run against an older generation.
