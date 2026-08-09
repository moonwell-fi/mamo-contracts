# Design: Per-Account Share Cap

## Context

See `proposal.md` — Why. Facts that shape the approach:

- **Two layers, one fund.** `MamoLeveragedAeroStrategy` is a per-user account (one clone per user, owner = the user) that custodies vault shares and forwards USDC. `LeveragedAerodromeCLStrategy` + `LeveragedAeroVault` are the single pooled fund. An account can only ever see its own slice.
- **The account already references the vault.** `vaultShares` is initialized as `IERC20(sherwoodStrategy.vault())`, so `address(vaultShares)` *is* the vault — no new pointer is needed to read a value stored there. This matters because accounts are initialized without a factory reference, and already-deployed accounts cannot gain one without a re-initializer.
- **The vault owner is the MAMO multisig** (`Ownable2Step`), the same authority behind `stageVenue`, `activateStrategy` and `setOpenDeposits`. The registry's `DEFAULT_ADMIN_ROLE` is a *different*, timelocked authority.
- **Nothing leveraged-aero is deployed on Base** (no entries in `addresses/8453.json`), so the vault can take a new storage field with no migration concern.
- **Fee-shares mint to `feeRecipient`, not to accounts**, so an account's share balance moves only on its own deposits and withdrawals. This is what makes a share-denominated cap stable without an oracle.
- The pooled strategy has no `previewDeposit`; only `previewRedeem` exists.

## Goals / Non-Goals

**Goals:**

- A single operator-set ceiling on any one account's holding in the fund.
- Let the backend deploy part of an account's idle USDC.
- No new oracle dependency in the cap path.

**Non-Goals:**

- Bounding total fund size (N accounts × cap each is unbounded).
- Acting as a security boundary — the pooled `deposit` stays permissionless, so bypassing the account layer bypasses the cap.
- Per-account cap values or exemptions.
- Forcing existing over-cap positions to unwind. The cap gates *new* deposits only.

## Decisions

### D1: Cap denominated in vault shares, not USDC

Shares are exact, need no oracle, and an account's balance cannot drift on its own (fee-shares go to `feeRecipient`). Withdrawals free room automatically with no bookkeeping.

- *Accepted cost*: the cap's **dollar meaning drifts upward** with fund performance. `shares = assets × (supply + offset) / navNet`, so as NAV grows each dollar buys fewer shares and a fixed share cap admits more dollars. A cap set as "≈$30k" becomes ≈$36k of room after a +20% run. This loosens rather than tightens, so the drift is in the safe direction for a user-facing allocation limit.
- *Alternatives rejected*: tracked USDC principal (needs pro-rata decrement across four exit paths, and diverges from real value anyway); current position value (accurate, and adds no new failure mode since deposits are already NAV-priced and fail-closed — but it makes gains consume cap room, which reads as punishing good performance).

### D2: Cap value on the vault, enforcement in the account

`LeveragedAeroVault.maxSharesPerAccount`, set by `onlyOwner`; each account reads it through the `vaultShares` pointer it already holds.

- *Why the vault*: zero new pointers (works for already-deployed accounts), the owner is already the multisig, and "how many shares may one holder have" is naturally a property of the share ledger. One transaction covers the whole user base.
- *Why not `strategyMint`*: enforcing there would also catch **fee-share crystallisations**, which the strategy performs best-effort inside `try/catch` — a cap-blocked fee mint would silently defer fees forever rather than reverting. It also cannot see per-account balances.
- *Why not the registry*: `MamoStrategyRegistry` is explicitly not upgradeable, so it cannot take a new field; its admin role is also timelocked, making per-user tuning slow.
- *Why not the factory*: accounts hold no factory reference.

### D3: Post-hoc share check

Share count is only known after `sherwoodStrategy.deposit` returns, and there is no `previewDeposit`. The account therefore deposits first and checks the resulting balance, reverting if it exceeds the cap — the whole transaction unwinds, so no state persists.

- *Alternative rejected*: duplicating the strategy's share-pricing formula in the account to pre-check. That formula (`mulDiv(assets, supply + SHARES_VIRTUAL_OFFSET, navNet + 1)`, plus the fee crystallisation that runs first) would have to stay in lock-step with the strategy forever; a silent drift there is worse than gas wasted on a reverting path.

### D4: Revert, never clamp

An over-cap deposit reverts rather than depositing a reduced amount. Silent partial fills surprise integrators, and the caller can always retry with a smaller figure. `depositIdle`'s new `assets` parameter is what makes this workable — the backend picks the amount that fits rather than relying on the contract to trim it.

### D5: `0` means unlimited

A freshly deployed vault has `maxSharesPerAccount == 0`; treating that as "no deposits" would brick the fund until the multisig acted. The freeze case is already served by `depositsOpen`, so `0` is the natural "no cap" sentinel.

### D6: `deposit` stays permissionless

Unchanged from today. *Known consequence*: with a cap in place, a third party can consume a user's allocation room by depositing their own USDC into that user's account, blocking the user from depositing their own. The attacker pays real money and the shares land under the victim's ownership, so it is self-harming — accepted deliberately rather than overlooked. Revisit if it is ever observed.

## Risks / Trade-offs

- [Cap set in 12dp share units, operator thinks in dollars] → a view helper converts a USDC figure to shares at current pricing; the runbook must use it rather than hand-computing. An off-by-1e6 error here sets a cap a million times too large or small.
- [Cap's dollar meaning drifts up with performance] → accepted (D1); document that it is an allocation guardrail, not a hard dollar limit, and re-set it periodically if a tighter dollar bound is wanted.
- [`depositIdle` signature change breaks the backend integration] → BREAKING and called out in the proposal; coordinate the deploy with the backend change.
- [Cap bypassable by depositing into the pooled strategy directly] → stated non-goal; all product flows go through accounts, and the pooled `deposit` was already permissionless before this change.
- [Existing positions above a newly-lowered cap] → the cap gates new deposits only; nothing forces an unwind and no user is trapped (all withdrawal paths are unaffected).

## Migration Plan

1. Deploy the updated vault and account implementation (nothing is live on Base, so this is a first deploy rather than a migration).
2. Multisig: read the conversion helper for the target USDC allocation, then `setMaxSharesPerAccount(<shares>)`.
3. Backend: update the `depositIdle` integration to pass an amount.
4. Rollback: `setMaxSharesPerAccount(0)` restores unlimited behaviour in one transaction.

## Open Questions

- Whether operations wants a periodic re-set cadence to counteract the upward dollar drift (D1). Does not affect the contract surface — purely a runbook decision.
