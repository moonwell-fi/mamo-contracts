# Leveraged Aero — Rebalancer (fund-ops) integration guide

## The product — Leveraged Aerodrome LP Fund

Leveraged Aerodrome LP fund. Users deposit USDC; the Mamo agent runs a leveraged AERO-farming
position that earns through emissions. Custody and execution are deliberately separate: the fund's share
ledger is a minimal in-repo vault (`LeveragedAeroVault` — shares plus an owner-driven execute/settle
lifecycle, no pricing of its own), execution lives in one strategy contract (supply USDC on Moonwell →
borrow the two CL legs → Aerodrome concentrated LP → farm & compound AERO, with onchain leverage caps and
a permissionless deleverage), and Mamo's **rebalancer** service is the agent — the same trusted-operator
model as Mamo today: it manages the position but can never withdraw user funds. Users redeem anytime at
NAV.

| At a glance | |
|---|---|
| Chain | Base |
| Deposit asset | USDC (ETH & cbBTC added later) |
| Structure | Pooled fund — many depositors, one shared position |
| Strategy | Supply USDC on Moonwell → borrow the CL leg(s) → Aerodrome CL LP → farm & compound AERO |
| Pool shape | **Two** per-clone shapes, derived at init and read from `layout().legBIsAsset` — *two borrowed legs* (e.g. cbBTC + ETH) or *asset-as-leg-B* (borrow one volatile leg, pair it with USDC). Several ops behave differently between them — see §G. |
| Posture | Leveraged Aerodrome CL LP + AERO emissions carry |
| Custody | Agent manages the position, can never withdraw user funds; users redeem anytime |
| Lifetime | Runs indefinitely — no fixed term; the terminal `Settled` state is driven by the vault owner (MAMO multisig) |

**Where this guide sits.** This is the fund-ops surface — the Mamo agent driving the **one shared**
strategy position directly, as its **proposer**: position management (deploy / compound /
re-range / leverage), and the withdraw-queue drain. It is the third guide in the family; the per-user,
user-facing account integration is the sibling docs
([`LEVERAGED_AERO_BACKEND.md`](./LEVERAGED_AERO_BACKEND.md),
[`LEVERAGED_AERO_FRONTEND.md`](./LEVERAGED_AERO_FRONTEND.md)), which cover the
`MamoLeveragedAeroStrategy` account (USDC-in / USDC-out wrapper) — the many accounts all deposit into
this single position. This doc completes the backend picture: everything the account docs called
"a separate fund-ops runbook" lives here.

> The strategy delegates its venue ops to `LeveragedAeroManager.sol` (impl-call/delegatecall pattern).
> This guide documents the **strategy-facing** behavior the agent observes; manager internals are cited
> only where they explain a guard or a failure mode. **This repo is the authority.** The
> `src/leveraged-aero/` package is an in-repo fork: upstream Sherwood at the vendoring pin is a historical
> baseline useful only for diffing, and where the two disagree the code here wins (see
> [`docs/LEVERAGED_AERO_CL_AUDIT.md`](../LEVERAGED_AERO_CL_AUDIT.md)). There is no upstream doc set to
> defer to for fund-ops procedure any more — rebalance policy, monitoring cadence and incident playbooks
> are Mamo's to define.

---

This is the contract-integration guide for the **keeper / agent** that operates the in-repo strategy,
`LeveragedAerodromeCLStrategy` (deployed as an ERC-1167 clone bound to one `LeveragedAeroVault`). The
single integration surface here is that clone; the agent calls it as **proposer**. Units: USDC is 6dp;
vault shares are 12dp; LTV / health / fees are all in **bps** (1% = 100). Every operator op requires the
strategy to be in state `Executed`.

---

## A. Role & authorization

The strategy inherits `BaseStrategy`, which stores a per-clone `_proposer` set at
`initialize(vault_, proposer_, data)`. The gate is a single modifier:

```solidity
// BaseStrategy
function proposer() public view returns (address);          // read the operator address
modifier onlyProposer() { if (msg.sender != _proposer) revert NotProposer(); _; }
function setProposer(address newProposer) external onlyVault;  // rotation — see below
```

> ### The operator key is **rotatable**
>
> `BaseStrategy.setProposer` is `onlyVault`, reached by the vault owner (the MAMO multisig) through
> `LeveragedAeroVault.setProposer(newProposer)` — `onlyOwner`, not set-once, not state-gated, zero
> rejected, and it emits `ProposerUpdated(old, new)`. Read the live value off `proposer()`; do not
> cache it across an incident.
>
> Rotation is **not** a fund-moving power: the incoming key inherits exactly the `onlyProposer`
> surface, which can neither raise leverage (that is `setTargetLtv`, admin-only) nor move tokens. It
> exists so a compromised keeper key does not force `settleStrategy` — a terminal unwind of the whole
> fund — as the only response. Note it does **not** move `layout().feeRecipient`, which is an
> init-only field: check that separately before treating rotation as a complete response.

> ### ⚠️ The `proposer` is `MAMO_REBALANCER` — **not** `MAMO_BACKEND`
>
> Earlier revisions of this guide claimed `proposer() == MAMO_BACKEND`. **That was wrong.** Verified live:
> the proposer is a **dedicated rebalancer address**, `MAMO_REBALANCER` —
> `0x73f6B456d063F78129113D42DBC315b9eEee8FAf` on the staging instance (`pooled.proposer` in
> `script/tenderly/leveraged-aero-vnet.json`; mainnet gets the real rebalancer ops key). The two roles are
> separate **on purpose**, so account-layer keys never reach the levered-book surface.
>
> **`fulfillRedeem` is `onlyProposer`, so the REBALANCER fulfils user withdrawal requests — not the
> backend.** The backend drives the account layer (`createStrategyForUser`, `depositIdle`); the rebalancer
> drives the strategy (`compound`, `rerange`, `adjustLeverage`, `fulfillRedeem`).

The proposer key is also **not** the registry `getBackendAddress()` member-0 key used for the account-level
`depositIdle` nudge (see the backend doc's "two BACKEND_ROLE domains") — three distinct addresses in total.
Read `strategy.proposer()` off the clone you actually target before wiring a keeper. The role is a
per-clone immutable, granted at `initialize`, and is unaffected by the removal of the Sherwood stack.
Unless `FEE_RECIPIENT` overrides it at init, the proposer is also the strategy's fee recipient.

> ### The **operations / policy split**: `proposer` ≠ `admin`
>
> **The `proposer` role IS the rebalancer.** We deliberately did **not** rename it — `proposer()` is the
> keeper address and every operational entrypoint is `onlyProposer`.
>
> **`admin` is a second, derived role: `Ownable(vault()).owner()` — the MAMO multisig.** It is *not* a
> stored field on the strategy and there is no setter; it simply follows whoever owns the vault, so a
> vault-owner handover carries the strategy's admin rights with it. The gate is
> `if (msg.sender != Ownable(vault()).owner()) revert NotAdmin();`.
>
> The split exists because **the backend/keeper must not be capable of rugging you: raising fund risk is
> multisig-only.** The rebalancer moves the book toward the fund's standing policy and may **de-risk** it;
> it cannot increase leverage and it cannot move tokens out of the strategy.
>
> ### 🧭 The direction rule — memorize this one line
>
> **The admin owns the standing target; the proposer moves the book underneath it.**
>
> | Move | Who | Entrypoint |
> |---|---|---|
> | Change the standing target, either direction | **admin only** | `setTargetLtv(uint16)` |
> | Move the BOOK to any LTV at or below that target | proposer | `adjustLeverage(uint16 targetBps, ...)` |
>
> `adjustLeverage`'s `targetBps` is **a parameter, not policy**: it is bounded by the stored
> `targetLtvBps()` (`TargetLtvExceedsPolicy(requested, policy)` above it) and is **never persisted**. So a
> compromised keeper key can move the book anywhere in `(0, targetLtvBps()]` but can never raise fund risk
> past the policy the admin set, never reach a zero target (a zero is a full unwind and fails closed in
> `_leverDown` with `FullUnwindNotSupported`; `flatten` is the real full unwind), and never move tokens.
>
> **The de-lever is TRANSIENT by construction.** Nothing stores it, so the next `deployIdle` / `compound`
> sizes its new tranche at the *stored* target and blended LTV creeps back up. A **durable** de-risk is the
> admin's `setTargetLtv`; the permissionless `deleverage` covers the health emergency.
>
> Three concrete consequences for keeper operators:
> - **`adjustLeverage` takes a target again**, but a bounded one — `adjustLeverage(targetBps, minLiq,
>   minOut)`. Pass `targetLtvBps()` to hold the book at policy.
> - **The keeper can de-risk without a multisig.** One `adjustLeverage` at a lower target does it, and
>   restoring the book is the same call with the (untouched) stored target — which is what keeps the 2-day
>   `FULFILL_WINDOW` off the multisig's critical path in **both** directions (§C).
> - **`rescueToVault` is admin-only.** The proposer used to be able to call it. It can't any more.

Four authorization tiers appear on the strategy:

| Tier | Functions | Gate |
|---|---|---|
| Proposer-only (operations) | **`supplyIdle`**, **`withdrawIdle`**, `deployIdle`, `compound`, `rerange`, **`adjustLeverage`** (per-call target, capped at policy), `fulfillRedeem`, `updateParams` | `onlyProposer` (== `MAMO_REBALANCER`) |
| **Admin-only (policy / custody)** | **`setTargetLtv`** (the only way to **raise** the target), `rescueToVault` | `onlyAdmin` — `Ownable(vault()).owner()`, the MAMO multisig → `NotAdmin()` |
| Permissionless | `deleverage` | anyone (by design — safety backstop) |
| Vault-only (lifecycle) | `execute`, `settle` | `onlyVault` — the vault **owner** drives these, not the agent |

- **State gate.** Every proposer op (and `deleverage`) opens with `if (_state != State.Executed) revert
  NotExecuted();`. The agent operates the position only while `state() == Executed` (enum
  `State { Pending=0, Executed=1, Settled=2 }`). `execute()`/`settle()` are `onlyVault` and are reachable
  only through the vault owner's `LeveragedAeroVault.activateStrategy(seedAmount)` (pulls the seed from the
  owner to the strategy, then `execute()`) and `settleStrategy()` (`settle()` → full unwind → realized USDC
  pushed to the vault). One-way, owner-only, no proposal or vote behind them — out of the agent's hands
  either way.
- **`deleverage` is permissionless by design.** It is deliberately **not** `onlyProposer`: a public
  deleverage is the user-safety backstop for an open-ended position (no fixed term, no scheduled unwind).
  It reverts `HealthyNoDeleverage` unless the position is genuinely unhealthy (conditions in §B). The
  agent should run it proactively, but anyone (a watcher bot, a user) can trigger it when health slips.
- **`rescueToVault` is ADMIN-ONLY and always pays the vault.** *(Behaviour change — the proposer could
  previously call it; it now reverts `NotAdmin()` for the keeper.)* Moving tokens out of the strategy is
  a custody action, not an operation. The recovery target is still hardcoded to `vault()`, never
  caller-supplied, so even the admin cannot exfiltrate; it only sweeps stray (non-position) tokens.
- **`updateParams(bytes)` is a no-op** here (`_updateParams` has an empty body — there are no tunable
  params). Listed for completeness; the agent never needs it.

---

## B. The operator surface — every proposer-callable function

All signatures below are exact. All revert `NotExecuted()` outside `Executed`, are `nonReentrant`, and
are `onlyProposer` except where noted. Risk caps live in the ERC-7201 `Layout` (read via `layout()`,
§E): `targetLtvBps`, `maxLtvBps`, `minHealthBps`, `maxSlippageBps`, `usdcCollateralFactorBps`. Two
compile-time constants bound the recovery valve: `DELEVERAGE_BUFFER_BPS = 500` (+5%) and, in the
strategy, `FULFILL_WINDOW = 2 days`.

Three further proposer ops — `flatten`, `migrateVenue`, `redeploy` — belong to the venue-migration
sequence and are specified in **§G2**, not here. `flatten` and `redeploy` are also the recovery pair for a
range the price has left; §D's idle loop says when that reaches you.

### `supplyIdle` — park idle USDC in Moonwell so it earns (no borrow, no LP)

```solidity
function supplyIdle(uint256 amount) external onlyProposer nonReentrant;   // 0xe349a513
```

| | |
|---|---|
| `amount` | USDC (6dp) to supply as Moonwell collateral. Bounded by the strategy's **raw** USDC balance and nothing else — `InsufficientIdle()` above it. |
| Position effect | `usdc.forceApprove(mUsdc, amount)` → `mUsdc.mint(amount)`. That is the whole op. **No borrow, no LP touch, no health assert** — it only moves USDC from a raw balance into interest-bearing collateral. Same in both pool shapes; no asset-mode branch. |
| Effect on NAV | **Zero.** `nav()` counts raw USDC at face and collateral at `exchangeRateStored`, and the mint hands back `amount / exchangeRateStored` cTokens worth `amount` again. Expect movement of at most 1–2 units (6dp) from the mint's floor division. If you see more, something is wrong — stop. |
| Effect on LTV | LTV **falls**: collateral grows, debt does not. The book is then under-levered relative to `targetLtvBps` until you retarget. |
| Works on a flat book | Yes, and this is the main use. After `flatten` the entire fund sits as raw USDC earning nothing; `supplyIdle` puts it to work while the book is out of the pool. `nav()`'s flat branch prices the collateral, so deposits and redeems keep working normally throughout. |
| Errors | `InsufficientIdle` (asked for more than the raw balance), `MoonwellMintFailed(errCode)` (market paused or at its **supply cap** — a retry, not a fault), `NotProposer`, `NotExecuted`. |
| When to call | Whenever meaningful idle USDC has accumulated (deposits, a `flatten`, a rerange remainder) and you are not about to lever it immediately. |

**How much float to leave un-supplied is your call, and it is a real trade-off.** `supplyIdle` takes an
amount rather than sweeping, on purpose:

- **Supplying earns.** Un-supplied USDC earns nothing at all.
- **Raw USDC is the only ORACLE-FREE redeem cover.** When a full async redeem's proportional repay comes
  up short on a leg (IL), the cover runs in two phases: **Phase 1** buys the deficit with the *raw* USDC
  balance and reads **no** Chainlink feed; **Phase 2** falls back to redeeming collateral and pricing the
  deficit off the oracle. So the raw float is exactly how much of a shortfall can be covered with the
  feeds down — which matters most for the trustless 2-day `emergencyRedeem` deadman (§C), the one exit
  that must keep working when nothing else does.

This is why supplying is a keeper op and **not** something `deposit` does on arrival. Supplying every
deposit as it landed would (a) put Moonwell's supply cap on the fund's money-in path — a capped market
could refuse deposits outright — and (b) drive the Phase-1 budget structurally to zero, making every
shortfall-carrying full redeem oracle-dependent. As an operator dial, both stay under your control.

Rule of thumb: park the working capital, hold back a float sized against the redemptions you would want
to be able to cover with the oracle down. And the dial turns **both ways**: `withdrawIdle` (next entry)
un-parks collateral back into a raw float, so an over-parked book is one keeper call away from
recovering its oracle-free cover — no levering, no `flatten`. On a **live** book, `supplyIdle` then
`adjustLeverage` is a two-step spelling of `deployIdle` — see below for when to use which. On a **flat**
book neither `adjustLeverage` nor `deployIdle` can run (there is no position to add into); `redeploy` is
the op that re-enters a flat book, parked or raw.

### `withdrawIdle` — un-park collateral back to a raw USDC float (the inverse of `supplyIdle`)

```solidity
function withdrawIdle(uint256 amount) external onlyProposer nonReentrant;
```

| | |
|---|---|
| `amount` | USDC (6dp) to redeem out of mUSDC back to the raw balance. Bounded by the **un-levered** collateral — `C − ceil(D·1e4 / targetLtvBps)`, i.e. collateral not already backing debt at the standing target — `InsufficientIdle()` above it. On a flat book (no debt) the whole parked pot is withdrawable, oracle-free. |
| Position effect | `mUsdc.redeemUnderlying(amount)`. No borrow, no repay, no LP touch. |
| Effect on NAV | **Zero** (collateral at `exchangeRateStored` becomes raw USDC at face; the same 1–2 unit rounding budget as `supplyIdle`). |
| Effect on LTV | LTV **rises** (collateral shrinks, debt does not) — which is exactly why the bound stops at the un-levered slice: post-op LTV can never exceed `targetLtvBps`. Withdrawing levered collateral is not a float adjustment, it is a de-risk — use `adjustLeverage` down or `flatten`. |
| **Feed outage** | The op **does not jam** — this is the deliberate exception to §F's fail-closed rule, because restoring the oracle-free Phase-1 float is most needed *during* an outage. When the hardened reader refuses, the **same** un-levered bound is re-derived from Moonwell's own account snapshot (`getAccountLiquidity` + live CF, the venue's un-gated oracle) and the call emits **`WithdrawIdleBoundDegraded`**. The line is held at the venue's (possibly stale) prices, never dropped; expect `InsufficientIdle` at the same place. If even the comptroller cannot answer: `ComptrollerCallFailed`, fail-closed. |
| Errors | `InsufficientIdle` (asked past the un-levered slice — under EITHER oracle basis), `MoonwellRedeemFailed(errCode)` (market short of cash — a retry), `ComptrollerCallFailed` (degraded path and even the venue can't answer), `NotProposer`, `NotExecuted`. |
| When to call | Whenever the raw float has drifted below the redemption cover you want to hold oracle-free — after over-parking, after Phase-1 covers spent the float, or on a flat book you parked and now expect exits from. |

### `deployIdle` — put idle USDC to work

```solidity
function deployIdle(uint256 amount, uint256 minLiquidity) external onlyProposer nonReentrant;
```

> **`deployIdle` vs `supplyIdle` + `adjustLeverage`.** `deployIdle` supplies *and* borrows *and* adds to
> the LP in one call. `supplyIdle` only supplies; the collateral it creates is **leverageable like any
> other** (there is no buffer/book distinction in `Layout`), so a following `adjustLeverage` levers the
> whole book — the new collateral included — to the stored `targetLtvBps` and lands the same position.
> Use `deployIdle` when you want one call with a `minLiquidity` floor; use `supplyIdle` when you want the
> USDC earning *now* and will lever on a separate cadence, or when the book is flat and there is nothing
> to add to.
>
> `amount` may now exceed the raw balance: the bound is raw **plus un-levered** mUSDC collateral
> (`C − ceil(D·1e4 / targetLtvBps)`), and the op redeems the shortfall on demand. So USDC you parked
> with `supplyIdle` is still deployable without un-parking it first — but collateral **already backing
> debt at target is not "idle" and is refused** (`InsufficientIdle`). That refusal is load-bearing:
> funded from levered collateral, the op would be redeem → supply-straight-back → borrow — a pure debt
> increase that re-levers the same USDC twice and walks LTV from `targetLtvBps` toward `maxLtvBps`,
> which is precisely the risk-increase capability the proposer key must not have. A redeem Moonwell
> itself refuses (market short of cash) still surfaces as `MoonwellRedeemFailed(errCode)` — a retry.

| | |
|---|---|
| `amount` | USDC (6dp) to deploy. Bounded by raw USDC **plus un-levered collateral** (`InsufficientIdle()` above it) — no other size ceiling to compute, and inside that bound none is needed: the op supplies not-yet-levered value and borrows against it at exactly the stored `targetLtvBps`, so the incremental tranche's LTV **is** the target and a bigger deploy pulls blended LTV *toward* target. (The un-levered cap is what keeps that reasoning true — collateral already backing debt would make the "tranche" pure debt.) Partial deploys are expected and legal. |
| `minLiquidity` | Minimum CL liquidity the add must produce (slippage floor). |
| Position effect (two borrowed legs) | supply **all** of `amount` USDC → mUSDC → borrow both legs at **`targetLtvBps`** (50/50 by USD value) → wrap native ETH **iff** `wethDeliversNative` (§G) → `increaseLiquidity` into the existing CL NFT → restake in the gauge. |
| Position effect (asset-mode) | `LeveragedAeroValuation.assetModeSplit` solves the split closed-form against the **STORED** range: only `C < amount` is supplied as collateral, a **single** leg-A borrow is taken against `C` at `targetLtvBps`, and `U = amount − C` is held back as the LP's USDC side so the add lands at exactly the ratio the stored range needs. Net leg-A exposure stays 0 (LP leg == debt leg). |
| Guards | Two-borrowed-legs: borrow sized at `amount × targetLtvBps / 1e4`. Asset-mode: borrow sized at `C × targetLtvBps / 1e4` with `C` from the split — so the **effective** collateral is less than `amount` and a naive `amount × targetLtvBps` model will over-predict the borrow. Both: two-sided `maxSlippageBps` mins on the add plus the caller's `minLiquidity`; closes with `_assertHealthy()` (post-op LTV ≤ `maxLtvBps` **and** no Moonwell shortfall) — that assert runs **after** the deploy, so the caps constrain the *result*, not the input. |
| Errors | `InsufficientIdle`, `InsufficientLiquidity`, `MoonwellMintFailed`/`MoonwellBorrowFailed(errCode)`, `UnhealthyPosition(ltvBps, limitBps)`; **asset-mode also** `DegenerateRange()` — the split is sized against the STORED range (`posTickLower`/`posTickUpper`), so a range the price has already left is one-sided and fails closed. A `rerange` unblocks it **only while spot is still inside the stored band** (there it recentres); once spot has *left* the band the rerange reopens **wholly on the populated side**, which is still one-sided against spot, so this path stays closed until price enters the new band. The unconditional cure is `flatten` + `redeploy`. The one genuine **external** ceiling on `amount` is Moonwell's borrow cap on the leg market(s), which surfaces as `MoonwellBorrowFailed(errCode)` — size down and retry. Naming trap: `InsufficientIdleForLeverUp` is **not** a `deployIdle` error despite reading like one; it belongs to asset-mode `adjustLeverage` (below). |
| When to call | Deposits land as idle USDC (see §D) and earn nothing until deployed. Run periodically to sweep accumulated idle into the position. Since `amount` is free up to idle, the decision is not "how much fits under the caps" but **how much idle to hold back**: the reserve is the instant-redeem cover (§D) and, in asset-mode, the funding for a lever-**up** (§G). Choose it deliberately rather than deploying to zero. |

### `compound` — harvest AERO, reinvest, crystallize fees

```solidity
function compound(uint256 minUsdcOut, uint256 minLiquidity) external onlyProposer nonReentrant;
```

| | |
|---|---|
| `minUsdcOut` | Minimum USDC out of the AERO→USDC swap. **Must be non-zero** — `ZeroMinOut()` otherwise. |
| `minLiquidity` | Minimum CL liquidity on the redeploy of the net yield. |
| Position effect | claim AERO from the gauge → swap **all** AERO → USDC via the Aerodrome v2 volatile pool → skim the protocol-fee slice → **re-hedge accrued borrow interest out of what's left** (below) → redeploy the remainder at `targetLtvBps` (same path as `deployIdle`, so asset-mode redeploys through `assetModeSplit`). No-op if flat book (`tokenId == 0`) or no AERO accrued/held. |
| **Redeploy size — read this before predicting it** | The redeploy is **not** `usdcOut − protocolFeeSkim`. In order: `pay = min(skimCap, usdcOut)`; `redeploy = usdcOut − pay`; then `redeploy -= _hedgeInterestDrift(redeploy)`. The hedge step spends part of the harvest **buying back and repaying accrued borrow interest** before anything is redeployed, so the CL add is smaller than the gross yield by that amount. |
| Interest re-hedge (what it spends) | Per borrowed leg, drift = `borrowBalanceCurrent(market) − hedgedDebt*` — the market is **accrued first** (`borrowBalanceCurrent`, not `…Stored`), so it sees interest that has not yet been capitalised. That drift is priced to USDC on the hardened leg + USDC feeds, bought on the Slipstream leg↔USDC pool with an oracle-floored min-out, and repaid to Moonwell. |
| Interest re-hedge (how the budget is split) | **Measure both legs, then allocate pro-rata by USD cost**: each leg gets `budget × costᵢ / (costA + costB)`, with leg B taking the exact complement of leg A's allocation so division strands no dust. A budget that covers everything neutralises both legs fully (each leg's spend is capped at its own cost). Asset-mode has one drifting leg — leg B is the unit of account and never borrows, so its drift is structurally 0 and leg A takes the whole budget, unchanged. **What to expect when the harvest is thin:** both legs' drifts shrink by the *same fraction*, so a partial hedge keeps the residual short spread across the book instead of concentrating it on one leg. (Previously leg A was served the whole budget first and leg B got the leftover — so whenever leg A's drift alone exceeded the harvest, leg B was hedged by exactly 0 harvest after harvest.) |
| Interest re-hedge (bounds) | Hard-bounded by the harvest's own proceeds: it **never** touches stayers' idle USDC or the collateral. A budget too small for the whole drift hedges what it can — **on both legs** — and carries the remainder to the next harvest; it does **not** revert for insufficiency. Drift priced below 1 USDC unit is left to accumulate. Effect on the book: financing cost lands as **NAV drag** (less yield reinvested) instead of accumulating as unintended short leg exposure, and leverage dips slightly (the safe direction). |
| Fee interaction | Crystallizes management + HWM **performance** fees on the **pre-compound** NAV first (fail-closed on the price — a stale oracle reverts, so the harvest defers rather than mis-prices), so realized yield can't escape the performance fee. Then discharges `protocolFeeOwed` out of the swapped USDC before the hedge and the redeploy. |
| Guards | Effective swap floor = `max(minUsdcOut, oracleFloor)` where `oracleFloor = aeroBal × AERO/USD(8dp) / 1e20 × (1 − maxSlippageBps)`, post-checked on the measured fill → `BelowOracleFloor()`. The hedge's USDC→leg buy is separately floored at the oracle-implied leg amount haircut by `maxSlippageBps`. Redeploy runs `_assertHealthy()`. |
| Errors | `ZeroMinOut`, `BelowOracleFloor`, `UnhealthyPosition`; **`MoonwellRepayFailed(errCode)` from the interest re-hedge**; `MoonwellMintFailed`/`MoonwellBorrowFailed(errCode)`, `InsufficientLiquidity` and (asset-mode) `DegenerateRange()` from the redeploy. A stale/mismatched feed fail-closes the whole call — the AERO feed at the swap floor, and the leg + USDC feeds at the hedge (`compound` already fail-closes on those via the pre-compound `nav()`, so the hedge widens no oracle exposure). |
| **The redeploy is ATOMIC with the harvest** | Any of the redeploy errors above unwinds the **whole** call — the `getReward` claim, the AERO sale and the interest hedge included. Nothing is half-done and there is no partial-harvest state to reconcile. It is also **free to wait**: an unclaimed tranche keeps accruing in the gauge rather than decaying, an out-of-range position accrues no new emissions anyway, and the hedge measure is cumulative, so the drift carries to the next harvest. Do not read a reverted `compound` as lost yield. |
| Recovery when the redeploy is what blocks | `DegenerateRange()` means spot has left the stored range. Either `rerange` (see its row for what that does and does not fix once spot is fully outside the band) or `flatten` + `redeploy`, which claims and sells the tranche and repays the legs on its way through. `InsufficientLiquidity` / calm-gate reverts are ordinary retries. |
| When to call | On a yield/gas cadence. NAV no longer *steps* at `compound` (§E — `nav()` prices the held tranche **and** `gauge.earned()`), so harvesting is a conversion, not a re-pricing event, and there is no front-run window to close by harvesting promptly. A stale AERO feed intentionally blocks it — defer and retry; that same stale feed also fail-closes `nav()` whenever the gauge has reward value, which with live emissions is essentially always. Use `hedgedDebt()` vs. the markets' `borrowBalanceStored` (§E) to see how much drift a harvest will have to buy back, and to verify it went to ~0 afterwards. |

### `rerange` — reposition the CL range: re-width, re-skew, re-anchor (no swap)

```solidity
function rerange(uint24 width_, uint16 skewBps_, uint256 minLiq0, uint256 minLiq1)
    external onlyProposer nonReentrant;
```

The 4-arg form (per-cycle width **and** skew) is the in-repo signature — `src/leveraged-aero/LeveragedAerodromeCLStrategy.sol`
is the authority for it. It replaces the previous 3-arg `rerange(uint24,uint256,uint256)`; **the selector
changed**, so anything holding a hardcoded one must be re-derived (`cast sig 'rerange(uint24,uint16,uint256,uint256)'`).

| | |
|---|---|
| `width_` | New position width in **raw ticks** (must be a multiple of `tickSpacing`), validated strategy-side against the init-immutable `[minWidth, maxWidth]` band **before** the venue delegatecall → `OutOfBounds()`. The width is **persisted** — subsequent range math (and the genesis mint path) reads the stored value; only `rerange` moves it, the band never moves after init. `layout()` exposes `width` / `minWidth` / `maxWidth` for the rebalancer to read on-chain — always read them off the clone you actually point at (the current staging clone was init'd width **4000**, band **[200, 20000]**). |
| `skewBps_` | The fraction of `width_` placed **BELOW** the current tick, in bps (`10000` = 1.00). `5000` = centered — the old, and still the genesis/ops default. `3500` puts 35 % of the range below spot and 65 % above, i.e. more room for the price to rise. Concretely `lowerSpan = width_ × skewBps_ / 10000`, `upperSpan = width_ − lowerSpan`; both bounds are then aligned **DOWN** to `tickSpacing`, which preserves the realised **width** exactly but moves part of the requested upper span into the lower one — see *Realised split precision* below, and do not read the request as the realised split. Validated with the width, **before** the venue delegatecall → `OutOfBounds()`: `skewBps_` must be in `(0, 10000)` **exclusive**, must lie inside the clone's init-immutable `[minSkewBps, maxSkewBps]` band, and **both** spans must be ≥ one `tickSpacing` — the last check is what protects the strict-bracketing invariant at small widths, where a legal-looking skew would otherwise collapse a side to zero. Like `width`, `skewBps` is **persisted** and exposed on `layout()`; the next `execute`/genesis mint re-mints at the stored width **and** the stored skew. |
| `minSkewBps` / `maxSkewBps` | **Not arguments — the governance band on `skewBps_`.** Two init-time fields (`InitParams` / `Layout` / `layout()`, immediately after `skewBps`), fixed for the life of the clone exactly like `[minWidth, maxWidth]`. They are validated at **init** *and* re-checked on **every** `rerange`, and a violation raises the same `OutOfBounds()` — there is no separate selector. The band is what stops an operator key from parking the fund at a near-degenerate skew even though the raw `(0, 10000)` bound and the one-spacing floor would allow it; the harness default is `[1000, 9000]` (`MIN_SKEW_BPS` / `MAX_SKEW_BPS`). Read them off the clone before the rebalancer proposes a skew — a policy that can emit values outside the band is a policy that will revert. |
| `minLiq0` / `minLiq1` | Minimum **token0** / **token1** the re-add must consume → `InsufficientLiquidity()`. `token0`/`token1` are **pool ordering**, derived at init from `pool.token0()` and exposed as `layout().wethIsToken0` — do not assume which leg is which (see §G). **One-sided reopens:** when spot has left the old band the position holds one leg only and the new range is placed wholly on that side, so the re-add consumes **nothing** of the other token. Floor the populated side and pass **0** for the other, or the call reverts `InsufficientLiquidity()` on a leg it structurally cannot fill. `positions()` before the call tells you which side is populated. |
| Position effect | **Calm-gate runs FIRST** (`LeveragedAeroValuation._calmGate`) so a reposition can never execute at a manipulated tick → remove 100% liquidity + collect → mint a **new** CL NFT → restake. The **old NFT is left empty** (Slipstream ticks are immutable; the stale NFT is harmless dust). **Where the new range lands depends on what the unwind collected.** Both legs (spot still *inside* the old band) → the band **brackets** the current tick, `width_ × skewBps_ / 10000` raw ticks below it and the remainder above (equal halves at the default `skewBps_ = 5000`): a true recentre. **One leg only** (spot has *left* the old band) → the band is placed **wholly on the populated side**, abutting spot, `width_` ticks wide, and `skewBps_` is **not consulted** (there is no "either side" to apportion). That reopen starts **out of range** and becomes two-sided only if price comes back into it — it is not a recentre, and a true recentre of a departed book needs a swap, i.e. `flatten` + `redeploy`. Before this, that case reverted inside the pool and `rerange` was unusable in exactly the state it exists for. |
| What happens to principal | **No swap → principal conserved** (IL is realized only on a true exit). The collected ratio can't match the new range, so a remainder of **one** leg is left idle in the strategy — `nav()` prices it, so the reposition is NAV-neutral and the remainder stays redeployable. Debt + collateral untouched (health preserved). |
| Asset-mode difference | **`rerange` can no longer draw on idle USDC.** In asset-mode the leg-B slot **is** USDC (`layout().cbBTC == layout().usdc`), so a naive "offer the whole balance as `amountDesired`" re-add would have swept stayers' idle USDC — and the redeemers' cover reserve with it — into the LP. The impl now **snapshots the leg-B (USDC) balance before the unwind** and offers the mint only the delta the unwind itself collected; everything that was idle before the call is still idle after it. Operator consequence: a rerange no longer shrinks the redeem-cover budget, and it is **not** an idle-consuming op the way an asset-mode lever-up is. What is unchanged: the leftover remainder left idle is plain USDC rather than a borrowed leg. |
| Fee interaction | **No crystallization** — supply and NAV are unchanged; the streaming fee simply defers to the next crystallize point and the HWM is unaffected. |
| Guards | Calm-gate; width **and** skew validation (both bands + the one-spacing-per-side floor) now live in `LeveragedAeroValuation.checkRange`, called from the strategy before the venue delegatecall — the behaviour is identical to the previous strategy-local checks, plus the new `[minSkewBps, maxSkewBps]` band; two-sided `maxSlippageBps` mins + caller `minLiq0/minLiq1`; closing `_assertHealthy()`. |
| Errors | `OutOfBounds` — **one error covers every range knob**: an out-of-band or misaligned `width_`, a `skewBps_` outside `(0, 10000)`, a `skewBps_` outside the init band `[minSkewBps, maxSkewBps]`, and one whose spans do not both reach a `tickSpacing`. Plus calm-gate reverts (`TwapDeviation`/`StaleOracle` family), `InsufficientLiquidity` (see the `minLiq0`/`minLiq1` row on one-sided reopens), `NothingToRerange()` (the unwind collected neither leg — an empty position), `UnhealthyPosition`. **`OutOfBounds()` is the rename of the old `WidthOutOfBounds()` and therefore has a NEW selector** — see the note below. |
| Errors — asset-mode reachability | An **extreme** skew makes the range very lopsided, and a very lopsided range is exactly the shape `LeveragedAeroValuation.assetModeSplit` fails closed on: the next `deployIdle` / lever-up can then revert `DegenerateRange()`. This is **not a new failure mode** — it is the existing one-sided-range guard — but skew is a new way to reach it. Prefer moderate skews. And note what a `rerange` can and cannot fix here: while spot is still inside the band it recentres and the deploy paths resume, but once spot has left the band the rerange reopens **one-sided** and they stay closed — `flatten` + `redeploy` is the unconditional cure. |
| When to call | When spot has drifted out of the active range, or when the rebalance model chooses a new width **or a new skew** for the cycle. Width and skew selection policy is the rebalancer's (`RebalanceParams.width` in the backend spec); the chain only enforces the two init bands (`[minWidth, maxWidth]`, `[minSkewBps, maxSkewBps]`), the `(0, 10000)` bound and the one-spacing-per-side floor. |

> **Selector change — the backend error table must be updated.** `WidthOutOfBounds()` (`0x1f9f54af`)
> is gone; it is renamed `OutOfBounds()`, selector **`0xb4120f14`** (`cast sig 'OutOfBounds()'`). The old
> selector was deliberately paired with the Mamo backend's rebalance-param error code — that pairing now
> points at a selector the strategy no longer emits, so the backend's decode table has to be re-pointed at
> `0xb4120f14` or every out-of-band width/skew will surface as an unknown revert. The error's *meaning*
> widened too: it is no longer width-only.
>
> **Do not "fix" `docs/superpowers/specs/2026-07-03-lp-auto-balancer-v2-backend-spec.md`.** That table
> also lists `0x1f9f54af → WidthOutOfBounds()`, and it is still **correct** — it describes
> `LPAutoBalancerV2`, a different contract that keeps its own `WidthOutOfBounds()`. The two contracts'
> errors have now **diverged**: `0x1f9f54af` means an LPV2 width bug, `0xb4120f14` means a leveraged-Aero
> width **or skew** bug. A backend decoding both products needs both entries, keyed by which contract
> reverted.

#### Realised split precision — the request is not what you get

The alignment is **down-only on both bounds**, and that is not symmetric. `tickLower = alignDown(tick −
lowerSpan)` and `tickUpper = alignDown(tick + upperSpan)`, so:

- **The realised WIDTH is exact.** Both bounds move down by the same residue, so `tickUpper − tickLower`
  reproduces the request on the nose (`width_` is already a multiple of `tickSpacing`). The old claim that
  the realised width is only "within one spacing of the request" was about the wrong quantity — width is
  the part that *is* preserved.
- **The realised SPLIT always loses ticks from the UPPER side to the lower one — never the reverse.** Both
  bounds shift down by the same residue `r = (tick − lowerSpan) mod tickSpacing`, so `lowerSpan` **gains**
  `r` and `upperSpan` **loses** it — up to `tickSpacing − 1` ticks. The realised skew is therefore
  systematically **more below-weighted** than requested, by an amount the market's tick at execution
  decides, not the proposer.
- **At the guard's floor this is not a rounding detail.** The on-chain floor is `upperSpan ≥ one
  tickSpacing`; combined with a residue of up to `tickSpacing − 1`, the realised upper side can come out
  as a **single tick**. The guard guarantees strict bracketing of spot and nothing more — it is not a
  promise of a meaningful upper side.

**Ops rule: keep `upperSpan ≥ 2 × tickSpacing`** — i.e. pick `(width_, skewBps_)` such that
`(10000 − skewBps_) × width_ / 10000 ≥ 2 × tickSpacing`. That is what buys the upper side a real span
after the residue is taken out of it. The consequence of ignoring it is unchanged and already documented:
a one-tick side is a lopsided range, and in asset-mode the next `deployIdle` / lever-up sized against the
**stored** range can fail closed on the pre-existing `DegenerateRange()` guard until the range is fixed — and
note that a `rerange` fixes it only while spot is still *inside* the band; past it the rerange reopens
one-sided and `flatten` + `redeploy` is the cure.

> **Skew quantization cliff at `width_ == 2 × tickSpacing`.** At the smallest legal width the geometry has
> exactly one legal shape: one spacing below, one above — **centered**. Every `skewBps_` the guard admits
> at that width (at spacing 100 and `width_ = 200`: exactly `[5000, 5049]`) aliases onto the same range, so skew is a knob
> with no effect there. **Meaningful skew needs `width_ ≥ 3 × tickSpacing`**, and a *usable* upper side
> needs the `2 × tickSpacing` rule above on top of that. A rebalance model that sweeps skew at minimum
> width will read as "the parameter does nothing" — it is the width that is binding, not the skew.

> **Two-borrowed-legs shape: skew ratchets a debt-funded idle slice, once per borrow (deliberate).** The
> genesis / `deployIdle` / `compound` borrow is **range-blind** — `_borrowHalfEach` splits each borrow
> 50/50 by USD value regardless of where the range sits. A skewed range does not want 50/50 by value, so
> the mint consumes an unequal amount of the two legs and leaves the surplus one idle. Read the shape of
> this carefully, because it is worse than a standing balance:
> - **It is a per-borrow ratchet, not a one-off.** Each borrow site offers the mint only the amounts
>   **freshly borrowed in that cycle**; pre-existing idle leg balances are never swept back into the LP.
>   So every `deployIdle` and every `compound` strands a fresh slice of its own borrow on top of what is
>   already stranded, and the idle fraction **grows with each compound** until an op that resizes the
>   book folds it back in. `rerange` is that op here: in this shape it re-adds the **full** balance of
>   both legs, so a reposition sweeps the accumulated remainder back into the LP. (The pre-unwind
>   snapshot that stops a rerange reaching idle is **asset-mode only**, where the leg-B slot is the
>   fund's USDC; it does not apply to two borrowed legs, whose idle balances are genuine remainders that
>   redeploying is *supposed* to absorb.) Treat a periodic `rerange` as the de-ratchet.
> - **It is direction-independent at the borrow sites.** The drag is a function of how far the range is
>   from 50/50, not which way it leans: skew `2000` and skew `8000` both strand ≈ **33.5 %** of each
>   borrow, and the documented `3500` strands ≈ **19 %**. There is no "safe side" to skew toward.
> - **The stranded slice is debt-funded.** It was borrowed, so it pays Moonwell borrow interest while
>   earning no LP fees — that is the actual cost, and it compounds with the ratchet.
> - **Not a hedge break, not an LTV or health change.** The idle borrowed token hedges its own debt 1:1
>   exactly as it would inside the LP, `nav()` prices it, and net per-leg delta stays **zero**. Collateral
>   and debt are untouched; `_assertHealthy()` sees the same numbers. The cost is carry and lost fees, not
>   exposure.
>
> Recommended ops default is unchanged — **initialize with `skewBps = 5000` (centered) and apply skew
> per-cycle via `rerange`** — but be clear about what it buys: it **defers** the drag rather than avoiding
> it. The borrow never consults the range, so the very next `deployIdle` borrows 50/50 into the *stored*
> skewed range and starts the ratchet anyway. Size the skew against the drag you are willing to carry, and
> prefer fewer, larger deploys over many small ones. Asset-mode is unaffected in kind (its leg-B slot is
> USDC, so the surplus is plain idle USDC — and since the rerange fix it is no longer even consumed by the
> re-add). Making the borrow **range-aware** is the planned follow-up that removes the drag at source; it
> is **out of scope** here.

### `setTargetLtv` — **ADMIN-ONLY**: set the fund's standing target LTV (either direction)

```solidity
function setTargetLtv(uint16 targetLtvBps_) external onlyAdmin;   // selector 0x45325ee3
```

**Not a rebalancer call.** Listed here because the rebalancer must *read* what it writes, and because it
is **the only way to move the stored target at all**, in either direction — the keeper's
`adjustLeverage` (below) moves the book *under* it without writing it. Only `Ownable(vault()).owner()`
(the MAMO multisig) may call it; anyone else reverts
`NotAdmin()` (`0x7bfa4b9f`) — including the proposer.

| | |
|---|---|
| `targetLtvBps_` | The new **standing** target in bps. Must be **non-zero** → `TargetLtvZero()` (`0xcc7b6172`), and `≤ maxLtvBps` → `TargetLtvExceedsMax()`. A rejected value stores nothing and emits nothing. |
| Why zero is refused | A zero standing target is not a brick — it borrows nothing, so `debtUsdc == 0`, `adjustLeverage`'s two branches both skip, and `_leverDown` guards the full-unwind case anyway (`FullUnwindNotSupported`). What it *is* is a fund that can silently never lever. Refused on **all three** write paths: the two setters, and `migrateVenue` (the guard sits in `LeveragedAeroVenue.applyVenue`, the route `_initialize` and `migrateVenue` share). |
| Position effect | **None.** This is policy only; it moves nothing on chain. The value takes effect on the next `adjustLeverage` (retargets the live position to it) or the next `deployIdle` / `compound` / `execute` (sizes its collateral/borrow split at it). |
| State gate | **None** — legal in `Pending` as well as `Executed`, so the multisig can correct an init-time target before the genesis `execute` without redeploying the clone. |
| Events | `TargetLtvUpdated(uint16 previousBps, uint16 newBps)` — topic0 `0x74a1eafe22c602fe09147945eeb780f3482d293fefdceaa3ff058fd31134093e`. The only leverage-policy event on the contract; monitor it as a multisig-signed risk change. **Two emitters, one topic**: this setter and `migrateVenue` — a migration's staged params carry their own `targetLtvBps`, and `applyVenue` announces it when it differs from the stored one (it stays quiet when it does not, and it also fires once at init, `previousBps == 0`). So the log stream is the complete history of the stored target, with no per-path special case. |
| Read-back | `targetLtvBps()` or `layout().targetLtvBps` (§E) — the same storage read. |

### `adjustLeverage` — move the BOOK to any LTV at or below the stored target

```solidity
function adjustLeverage(uint16 targetBps, uint256 minLiq, uint256 minOut)
    external onlyProposer nonReentrant;                           // selector 0x9792419f
```

> **⚠️ SIGNATURE CHANGED — the backend must remap.** Was `adjustLeverage(uint256,uint256)` →
> `0x4be1cadd`. Now `adjustLeverage(uint16,uint256,uint256)` → `0x9792419f`, which is the **original**
> pre-`lowerTargetLtv` selector — an integration that never migrated off it is correct again. The target
> is a per-call argument once more, but a **bounded** one: `targetBps` may not exceed the stored
> `targetLtvBps()`, and it is **never persisted**. Pass `targetLtvBps()` to hold the book at policy.
>
> **`lowerTargetLtv` is GONE.** Its job — de-lever without a multisig inside `FULFILL_WINDOW` — is now
> one `adjustLeverage` call at a lower target, and it no longer costs a policy write to get back.

| | |
|---|---|
| `targetBps` | Target LTV for **this call only**, in bps. Must be `≤ targetLtvBps()` → `TargetLtvExceedsPolicy(uint16 requested, uint16 policy)` (`0x614db9b8`) above it. **Never stored**, so it changes no future sizing. No `maxLtvBps` check here — policy already cleared that bound, and this is at or under policy. A zero (or near-zero) target is a full unwind and fails closed in `_leverDown` with `FullUnwindNotSupported` — `flatten()` is the real full unwind. |
| `minLiq` | Minimum CL liquidity on a lever-**UP** add. |
| `minOut` | Minimum USDC out of a lever-**DOWN** residual rebalancing swap. |
| Position effect (both shapes) | Collateral untouched; LTV moves on the **debt** side. `targetDebt = targetBps × collateralUsdc / 1e4`. Lever **down**: unwind the matching CL fraction and repay, per-leg residual rebalanced through USDC (`minOut`) — unchanged in asset-mode, where the leg-B residual **is** USDC and flows straight into the leg-A cover. Closes with `_assertHealthy()`. |
| Lever **down** — the cover sell is now **need-sized** | When one leg comes back short and the other long, `_rebalanceCover` sells the surplus leg to cover the shortfall. It now sells **only as much as covering the shortfall requires** and keeps the rest, instead of dumping the whole surplus balance. Two consequences for the operator: a lever-down (and the permissionless `deleverage`, same helper) realizes **less** unnecessary swap slippage and fees, and it **leaves the unsold surplus as an idle leg balance** — priced by `nav()`, still hedging its own debt, and redeployable on the next add. Do not model the residual sweep as "the surplus leg ends at zero" any more. |
| Lever **up** — two borrowed legs | Borrow the delta 50/50 by USD across both legs and LP them against each other. **Self-funding**: the pair *is* the two borrows, so no idle USDC is consumed. |
| Lever **up** — asset-mode | Borrows **only leg A** and pairs it with USDC **drawn from the book's own USDC — raw balance first, then a `redeemUnderlying` off the mUSDC collateral** (where the USDC lives once you have run `supplyIdle`), sized closed-form (`assetModeLeverUpPair`) so the LP's leg-A amount equals the added leg-A debt — that is what preserves the delta-hedge (swapping part of the borrow to USDC would leave the book net short). The sizing solves a fixed point that accounts for the collateral it consumes, so the book lands **AT** target, not past it; with raw ≥ the draw it clamps to the exact pre-change behaviour. **Operator consequences: (1) an asset-mode lever-up CONSUMES raw float and/or collateral into the LP** — value-conserving, but it shrinks the oracle-free redeem cover until you restore it (`withdrawIdle` or the next deposit). **(2) Near a range edge, do not retarget — `rerange` first.** The USDC the pairing demands per unit of new debt is the live range ratio; near the leg-A-poor edge it diverges, and the op — still landing exactly at target — can draw essentially the whole excess collateral into a nearly one-sided LP for vanishing new debt. The LTV gates cannot see that composition shift, and the op takes no amount parameter, so your control is sequencing. An under-funded op fails closed with everything rolled back — realistically `MoonwellRedeemFailed(errCode)` from the mid-op collateral redeem (market short of cash, or the draw crossing Moonwell's free-collateral line). |
| It writes **nothing** | The op persists no target: `targetBps` is consumed and discarded, and only `setTargetLtv` writes policy. **So the de-lever is TRANSIENT** — the next `deployIdle` / `compound` sizes its new tranche at the *stored* target and blended LTV creeps back toward it. A durable de-risk is `setTargetLtv`. When neither branch runs (`targetDebt == debtUsdc`) the call is a genuine no-op. The per-cycle range knobs are unaffected: `rerange` still persists `width` and `skewBps`. |
| Fee interaction | **No crystallization** (like `rerange`): no supply change, no PnL realized; streaming fee defers, HWM unaffected. |
| Errors | `InsufficientLiquidity`, `MoonwellRepayFailed`/`MoonwellBorrowFailed`, `UnhealthyPosition`; **asset-mode lever-up also** `MoonwellRedeemFailed(errCode)` (the realistic funding failure — the mid-op collateral redeem refused) and `DegenerateRange()` (the pairing is sized against the STORED range — a one-sided one fails closed; a `rerange` unblocks it only while spot is still inside that range, otherwise it reopens one-sided too and you need `flatten` + `redeploy`). `InsufficientIdleForLeverUp(uint256 needed, uint256 available)` is retained as defence in depth but is **provably unreachable through this entrypoint** (the corrected draw is always inside raw + collateral) — do not build runbook logic around receiving it. It stays re-declared on the strategy ABI for direct-library integrations. `TargetLtvExceedsMax` is **no longer reachable here** — it moved to `setTargetLtv` with the parameter. |
| When to call | To hold the fund near the standing `targetLtvBps()` (pass it). **To lever DOWN before `fulfillRedeem`** — so the oracle-free proportional unwind self-funds its IL/debt shortfall (see §C) — pass a lower `targetBps`: **one call, no multisig step**, so the fulfil runbook is a single-actor sequence. **Restoring the book afterwards is the same call with `targetLtvBps()`** — also proposer-only, so neither direction touches the multisig. (The permissionless `deleverage` remains available for the genuinely-unhealthy case.) In asset-mode note the two directions are asymmetric on idle: lever **down** frees USDC, lever **up** spends it. |

### `fulfillRedeem` — drain the withdraw queue

```solidity
function fulfillRedeem(uint256 id, uint256 minAssetsOut) external onlyProposer nonReentrant;
```

Runs the **oracle-free proportional unwind** for request `id`, paying `request.recipient` (for a Mamo
account, the end user's own wallet — so the fulfil COMPLETES the withdrawal with no follow-up claim,
rather than parking USDC on the account) net of its pro-rata protocol-fee skim, enforcing
**`max(stored, fresh)`** on the net payout, then burning the escrowed shares. See §C for the full loop.

**The `minAssetsOut` argument is YOUR floor, layered on top of the requester's — never instead of it.**
The stored floor was fixed at `requestRedeem` and can be up to the 2-day `FULFILL_WINDOW` stale by the
time you fulfil, which is a long time for a levered book to move; nothing else on the path covers that
gap (the per-swap sweep floors below bound individual **swaps**, not the payout). **Quote it by
SIMULATING the fulfil and decoding `RedeemFulfilled.assetsOut` — see §C "Sizing the fulfil". Do NOT quote
off `previewRedeem`**, which is the fast-path quote and over-quotes the async payout. Passing `0` defers entirely to the stored floor —
the previous behaviour, byte for byte. You cannot go the other way: a value **below** the stored floor
is ignored, so the requester's guarantee is not lowerable by whoever fulfils.

| | |
|---|---|
| Preconditions | `state() == Executed`; request not `settled` (else `RequestSettled()`). |
| Guards | Enforces `max(stored, fresh) minAssetsOut` → `InsufficientAssetsOut()`; rejects a burn-for-zero → `ZeroAssetsOut()`. The two residual leg→USDC sweeps that END the unwind now carry a **Chainlink min-out floor** — `oracleValue(amount actually sold) × (1 − maxSlippageBps)` per leg — so a hostile router / sandwiched fill reverts the fulfill instead of silently short-paying the redeemer. Preview it with `redeemSweepFloors(cbAmt, wethAmt)` (§E). The reward tranche the unwind auto-claims is sold on the same L9 oracle floor (best-effort — see §C) and split `f / (1−f)`. |
| Oracle posture | Still **oracle-free in the sense that matters**: the floor is derived behind a catchable call and falls back to **0** when the feeds are unreadable, so a down oracle/sequencer never blocks a fulfill or the `emergencyRedeem` deadman — it only removes the floor. A sandwicher cannot *make* a feed stale, so the floor binds whenever it can bind. Consequence for the agent: a fulfill that reverts on the sweep's min-out is a **venue-liquidity/pricing** signal (thin leg↔USDC pool, or someone shoving it), not an oracle problem — retry, or lever down first to shrink the residual being sold. |
| Fee interaction | Best-effort crystallize (never blocks the exit): on an oracle outage `navPre = 0`, so the price-free **management** fee still accrues while the **performance** fee defers; a fee-mint revert emits `FeeCrystallizeDeferred(2, navPre)` and proceeds. |
| Events | `RedeemFulfilled(id, owner, recipient, assetsOut)` — `owner` is the account that escrowed, `recipient` is the address PAID. |
| When to call | On every `RedeemRequested`, after ensuring the unwind self-funds (deleverage first if needed). |

### `deleverage` — permissionless safety valve

```solidity
function deleverage(uint256 minOut) external nonReentrant;   // NOT onlyProposer
```

| | |
|---|---|
| `minOut` | Minimum USDC out of any residual rebalancing swap. |
| Trigger conditions | Health basis `health = collateralUsdc × 1e4 / debtUsdc` (same hardened-Chainlink reads as `_assertHealthy`). Reverts `HealthyNoDeleverage()` when `debtUsdc == 0` **or** `health >= minHealthBps`. Only fires when the position has slipped below the `minHealthBps` buffer. |
| Bounds | A **recovery op, not** the full LTV-≤-max gate: repays debt down to `minHealthBps × (1 + DELEVERAGE_BUFFER_BPS/1e4)` = `minHealthBps × 1.05`. Post-checks: health strictly improved **and** the Moonwell shortfall cleared or reduced, else `UnhealthyPosition(healthAfter, minHealth)`. |
| Oracle | A stale strategy-side feed fail-closes (reverts) — deleveraging at a stale/manipulated price is worse than waiting. Moonwell liquidation uses Moonwell's own oracle; the window where ours is stale but theirs is fresh is an accepted residual (audit §9). |
| Config invariant | The deleverage trigger LTV `= 1e8 / minHealthBps` is guaranteed strictly above `maxLtvBps` at init (`minHealthBps × maxLtvBps < 1e8`), so there is no in-band range anyone can grief-deleverage. |
| When to call | Proactively when health approaches `minHealthBps`; but note anyone can and will call it — treat it as an always-available backstop, not an exclusive agent action. |

### `rescueToVault` — sweep stray tokens to the vault

```solidity
function rescueToVault(address token) external nonReentrant;  // proposer OR vault owner
```

Pushes the full balance of a **stray** ERC-20 (airdrop / accidental send) to `vault()`. Reverts
`NotProposerOrOwner()` if the caller is neither the proposer nor the vault owner (`Ownable(vault()).owner()`
— on `LeveragedAeroVault` that is the accepted `Ownable2Step` owner, MAMO_MULTISIG). Reverts
`CannotRescuePositionToken()` for any position/accounting token: the vault's own share token, `usdc`,
leg B, leg A, `mUsdc`, `mCbBTC`, `mWeth`, and — **while `Executed`** — the gauge reward token (read live
from the gauge so a sweep can't bypass `compound()`). That last block is state-scoped on purpose: once
`Settled`, `compound` is unreachable, so post-settle AERO **is** a stray and sweeping it is the only
recovery. `_settle` does sell the tranche its unwind auto-claims, so this covers the **residual** case
only: a best-effort sale that skipped (`SettleRewardSaleDeferred` — stale reward feed, broken reward
route, or a fill under the oracle floor), a sub-micro-USD dust balance, or a post-settle donation.
Harvest before settling (see the runbook) so there is nothing to recover. The
position NFT is never swept (no ERC-721 path), and **native ETH is not sweepable at all** (§G).

This is a two-hop recovery: the strategy can only push to the vault, and the vault owner then moves it out
with the vault's own `rescueERC20(token, to, amount)` — which can take any non-asset token at any time, but
refuses the **asset** (USDC) while any **external** share is outstanding
(`"LAV: asset reserved for redemptions"`), so a settled redemption pot can never be pulled out from under
holders. The test is `totalSupply() == balanceOf(vault)`, not `totalSupply() == 0`: shares donated to the
vault itself are permanent dead weight (nothing burns or moves them, and `rescueERC20` refuses the share
token), so counting them would let one wei disable the asset rescue forever. A donation cannot open the
gate early either — it raises the vault's own balance and leaves `totalSupply()` alone, so external supply
is unchanged. Shares escrowed on the STRATEGY are external and still hold the gate shut.

### Fee surface (proposer-relevant summary)

The strategy is self-fee'd (`selfManagesFees() == true`) — the vault performs no fee distribution of its
own at settle; this strategy collects fees itself:

- **Launch state: the protocol-fee leg is OFF.** The strategy resolves it live through
  `vault.factory()` → `.protocolConfig()`, and `LeveragedAeroVault` returns `address(0)` on the first hop
  while its `feeConfig` is unset — the deploy default. So `protocolFeeOwed` stays 0 and the protocol skim
  never fires until the vault owner calls `setFeeConfig(...)` (no strategy change needed). The
  **management** and **performance** fees are separate: they are the clone's own init params
  (`managementFeeBps` / `performanceFeeBps` / `feeRecipient` in `layout()`) and are live iff they were
  init'd non-zero. Read the three values rather than assuming a schedule.
- **Fee-share mints are gated on the vault's `depositsOpen`.** Crystallized management/performance fees are
  minted via `strategyMint`, which reverts `"LAV: deposits closed"` while issuance is frozen. On the
  best-effort paths that surfaces as `FeeCrystallizeDeferred`; on `compound` / `deposit` it hard-reverts.
  Closing deposits therefore also stalls `compound` until fees can mint again.
- **Crystallization triggers.** `deposit` (hard, fail-closed pre-deposit NAV), `compound` (hard,
  pre-compound NAV), fast `redeem` and the async `fulfillRedeem`/`emergencyRedeem` (best-effort, may
  emit `FeeCrystallizeDeferred`). `rerange`, `adjustLeverage`, `deleverage` **do not** crystallize.
- **`protocolFeeOwed`** is a USDC (6dp) liability accrued at crystallization, **netted out of `nav()`**
  (floored at 0), and discharged during `compound` (skim from swapped yield), `redeem`/fulfill (pro-rata
  skim), and `_settle`. It persists across ops until a protocol-fee recipient exists.
- Fee ceilings at init: `performanceFeeBps ≤ 1500` (15%, `FeeConstants.MAX_PERFORMANCE_FEE_BPS`),
  `managementFeeBps ≤ 500` (5%/yr). Performance fee is HWM-gated (only charged on gains above the
  high-water mark per share).

---

## C. The withdraw queue — the rebalancer's SLA loop

Async withdrawals are the agent's core recurring duty. A Mamo account (as `msg.sender`) escrows shares
into a `RedeemRequest`; the agent fulfills it; USDC is paid back to that account.

```solidity
struct RedeemRequest {
    address owner;        // request creator (the Mamo account) — only it can cancel / emergency-redeem
    uint256 shares;       // vault shares escrowed at request time (12dp)
    uint256 minAssetsOut; // slippage floor enforced at fulfill (the REQUESTER's floor)
    uint40  requestedAt;  // FULFILL_WINDOW deadman clock anchor
    bool    settled;      // set on fulfill / cancel / emergency (double-spend guard)
}

function redeemRequest(uint256 id) external view returns (RedeemRequest memory);
// layout().nextRedeemRequestId — monotonic id cursor (next id to be assigned)
```

Queue events (on the strategy; `owner` is the **Mamo account** that escrowed, not the end user):

| Event | Meaning |
|---|---|
| `RedeemRequested(uint256 indexed id, address indexed owner, address indexed recipient, uint256 shares)` | request escrowed — **the keeper trigger** |
| `RedeemFulfilled(uint256 indexed id, address indexed owner, address indexed recipient, uint256 assetsOut)` | agent fulfilled; USDC paid to `recipient` (for a Mamo account, its owner — the end user) |
| `RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares)` | request owner cancelled (any state); escrow returned |
| `RedeemEmergency(uint256 indexed id, address indexed owner, uint256 assetsOut)` | deadman self-fulfill after the window — **a missed SLA** |

### The 2-day deadman — `FULFILL_WINDOW`

`FULFILL_WINDOW = 2 days`. If the agent does not `fulfillRedeem` within that window, the request owner
can trustlessly self-service via `emergencyRedeem(id, minAssetsOut)` (owner-gated; reverts
`FulfillWindowOpen()` before the window elapses). At the account layer that surfaces as
`WithdrawEmergency`/`RedeemEmergency`. **Every emergency exit is a missed SLA** and strips the agent
from the loop. Treat 2 days as the hard fulfillment SLA; alert well before it.

**Reachable is not the same as successful.** `emergencyRedeem` runs the *same* proportional unwind as
`fulfillRedeem`, so it inherits its failure modes: on a **partial** redeem the IL cover is capped at the
redeemer's own budget (`balance − stayersIdle`) and fails closed rather than dipping into stayers' funds,
so a deeply out-of-range book can bounce the deadman itself. It is an unconditional right to *try*, not a
guaranteed payout — one more reason not to let a request reach the window. The user is never trapped by
that: `cancelRedeem` has **no state gate and no NAV gate** (owner-only, un-settled-only), so the escrowed
shares can always be retrieved and exited later.

**Drain the queue before settlement.** `fulfillRedeem` and `emergencyRedeem` both require `Executed`, so any
request still outstanding when the vault owner calls `settleStrategy()` becomes unfulfillable — its owner
must `cancelRedeem(id)` (callable in **any** state) to get the shares back and then exit via the vault's
`redeemSettled`. If a settlement is planned, clear the queue first and flag any request you can't fulfill.

**And `compound()` last, immediately before the owner settles — defense-in-depth, not a requirement.**
`settle`'s unwind auto-claims the final AERO tranche through `gauge.withdraw`, and `_settle` now **sells**
it into the USDC pot `redeemSettled` pays holders from. That sale is **best-effort by design**: `settle()`
is terminal, owner-driven and argument-less, so it is wrapped in a self-`try/catch` and skips (emitting
`SettleRewardSaleDeferred`) on a stale AERO/USD feed, a broken AERO→USDC route, or a fill under the L9
oracle floor — the swap rolls back whole, so it is never sold blind, but the tranche then stays on the
strategy. Harvesting in the block before settlement means the exit never depends on that path and bounds
any residue to a single block of emissions. Recovery of a residue is owner-only and manual
(`rescueToVault(aero)` → `vault.rescueERC20`), so keep "compound, then hand off to the owner" as the
settlement procedure and check the strategy's AERO balance afterwards.

### Why deleverage before fulfill — the self-funding unwind

`fulfillRedeem` runs `_proportionalRedeem` → `redeemUnwindImpl(shares, supply)`: it removes
`f = shares/supply` of **every** leg (oracle-free, pool-based mins), repays `f` of each Moonwell debt
from the collected tokens, and pays out the net USDC. The subtlety is IL: when the collected legs don't
fully cover `f` of the debt, the unwind must cover the shortfall.

- **Full redeem (`shares == supply`).** Three phases: (1) cover any IL shortfall from idle USDC via
  exact-output swaps; (2) if debt remains, self-fund by redeeming mUSDC collateral → swap to the
  deficit token → repay; (3) with all debt cleared, redeem 100% of the remaining collateral. The
  oracle is read only when `borrowBalance > 0`, so it's oracle-free once debt is cleared.
- **Partial redeem.** Redeem `f × collateral` first, then cover each leg's shortfall capped at the
  **redeemer's own** budget (`balance − stayersIdle`), recomputed before each cover buy. A shortfall
  needing more than the redeemer's slice reverts the whole redeem (fail-safe — never touches stayers'
  reserved `(1-f)` share of idle USDC/legs).
- **The closing leg sweeps are oracle-floored.** Whatever leg balance survives the repays (minus the
  stayers' reserved `(1-f)`) is sold to USDC at `oracleValue(amount sold) × (1 − maxSlippageBps)`. The
  loss on a bad fill there was always the **redeemer's** (stayers are insulated by the pre-unwind
  snapshot), and it is now bounded. **The floor never blocks the deadman**: it is derived behind a
  catchable call, so an unreadable feed drops it to 0 and `emergencyRedeem` still completes — the whole
  point being that the deadman exists for the oracle-down-and-backend-dead state. Not *silently*, though:
  the fallback emits **`RedeemSweepFloorsDegraded`** (§E), because the `catch` cannot tell a stale feed
  from an out-of-gas and those swaps then run unbounded.
- **The redeem sells the reward tranche its own unwind claims, and splits it `f / (1−f)`.** The unwind's
  `gauge.withdraw` auto-claims the whole accrued AERO tranche — on *every* async redeem, because the
  redeem's own unwind is what creates the balance. The leg sweeps above only touch the two leg tokens, so
  before this the redeemer was paid `f × (assets − reward)` while 100% of the tranche stayed with the
  stayers; with `nav()` pricing that reward, that was a payout that did not match the NAV the shares were
  measured against. The redeem now runs the **same best-effort, oracle-floored sale** the terminal
  `settle` uses, right after the unwind, and reserves `(1−f)` of the proceeds for the stayers — so the
  redeemer receives their pro-rata slice and no more. **Best-effort, for the same deadman reason as the
  sweep floors:** a stale AERO/USD feed or a broken AERO→USDC route makes the sale fail *closed inside its
  own frame* (the swap rolls back whole — never sold blind), the redeem swallows it and completes, and the
  tranche simply stays with the stayers. That residual is the only case in which the old behaviour still
  applies, and it emits **`RedeemRewardSaleDeferred`** (§E) so it is never silent. Stayers are never worse
  off than before; the redeemer is, at worst, no better off.

Because a levered position tends to run a debt/IL shortfall against the collected legs, levering
**down** first shrinks the debt the unwind must repay, so the proportional unwind self-funds cleanly
instead of eating deep into collateral. It is a **single-actor** step: one
`adjustLeverage(lowerTarget, minLiq, minOut)`. **It is NOT a routine pre-step and it is not sized off the
request** — most fulfils need no de-lever at all, and whether this one does is decided by simulation,
not by how large the request is (§C "Sizing the fulfil"). **No
multisig signature is on the fulfil path**, which is what keeps the 2-day SLA achievable — and none is on
the way back either, since restoring the book is the same call with the untouched `targetLtvBps()`.

### If `fulfillRedeem` reverts `InsufficientAssetsOut`

`fulfillRedeem` enforces the **requester's** stored `minAssetsOut` against the net payout. If the
position can't currently produce that floor (adverse IL / price move, or too much of the payout eaten
by shortfall cover), the fulfill reverts `InsufficientAssetsOut()`. Reason from the code: the escrowed
shares **carry no frozen price** — they keep bearing PnL until fulfilled — so the agent's options are
(1) re-run `adjustLeverage` at a still-lower `targetBps` to reduce the unwind's
shortfall and raise the achievable net, then retry, or (2) **wait** for the position to recover and retry. Do **not** try to lower the floor — it is
the requester's, not the agent's. A stuck request self-resolves at the 2-day deadman (the account owner
can also `cancelRedeem` to reclaim the shares).

```mermaid
sequenceDiagram
    participant A as Mamo account
    participant K as Agent keeper (proposer)
    participant M as MAMO multisig (admin == vault owner)
    participant S as Strategy (LeveragedAerodromeCL)

    A->>S: requestRedeem(shares, minAssetsOut, recipient = the account's owner)
    S-->>K: RedeemRequested(id, account, recipient, shares)
    Note over K: read redeemRequest(id); assess if unwind self-funds
    opt shortfall likely (non-trivial size)
        K->>S: adjustLeverage(lowerTarget, minLiq, minOut)   (PROPOSER, ≤ policy — no multisig)
    end
    K->>S: fulfillRedeem(id, minAssetsOut)
    alt payout ≥ requester minAssetsOut
        S-->>A: pays USDC to the request's RECIPIENT (the end user) + RedeemFulfilled(id, account, recipient, assetsOut)
    else InsufficientAssetsOut
        Note over K: deleverage/adjust more, or wait, then retry (never lower the floor)
    end
    Note over K: escalation — if unfulfilled at requestedAt + 2 days, the account can emergencyRedeem (missed SLA)
    K->>S: adjustLeverage(targetLtvBps(), minLiq, minOut)    (restore — PROPOSER, no multisig)
    Note over M: the multisig is OFF this path entirely; policy only moves if it CHOOSES to setTargetLtv
```


### Sizing the fulfil — the de-lever decision and the `minAssetsOut` quote

Two questions arrive together on every request: *do I need to lever down first, and what floor do I
pass?* Both are answered by **simulation, not by a formula** — and the answer to the first is usually
"no". A book whose LP is in range self-funds its own unwind.

#### Simulate STATEFULLY — and pick the method by environment

The ladder below is "de-lever **then** fulfil" evaluated in one context. A stateless call cannot express
that, so without a stateful simulator you would have to *actually transact* each rung and eat every
intermediate unwind's cost.

| Environment | Method | Notes |
|---|---|---|
| **Base mainnet (prod)** | **`eth_simulateV1`** | The portable one, verified live against Base. Executes `calls[]` sequentially with state carried, and returns `logs` **and** `returnData` per call. **Standardise on this.** |
| Staging vnet (`73578453`) | `eth_simulateV1` **or** `tenderly_simulateBundle` | Both work here. **`tenderly_simulateBundle` is vnet-only — it returns HTTP 400 on Base**, so never let it reach a production code path. |
| Anywhere | plain `eth_call` | **Pass/fail only** — no logs, no state carried between calls. Fine as the first probe; useless for the ladder or the quote. |
| Fallback | local fork (`anvil --fork-url`) | When a provider exposes neither simulator. |

**Simulators disagree at the dust level.** The same de-lever returned `34,130,340` through
`tenderly_simulateBundle` and `34,130,346` through `eth_simulateV1` — block-timestamp accrual, ~6 units
on 3.4e7. Keep a tolerance; never treat a simulated payout as exact.

#### The loop

1. **Probe** — simulate `fulfillRedeem(id, 0)` from `proposer()` against the live book.
2. **It passes** → decode the payout from the simulated `RedeemFulfilled` log, apply your tolerance,
   send. **Most fulfils end here.**
3. **It reverts** → **classify before reacting** (table at the end of this section). Only a cover-budget
   failure belongs on the ladder.
4. **Ladder** — simulate `[adjustLeverage(candidate, minLiq, minOut), fulfillRedeem(id, 0)]` as one
   stateful bundle. The first candidate that passes is what you then send as two real transactions.
5. **Restore once, after the queue drains** — not per request.

#### The ladder, specified

```
currentLtv = debtUsdc × 1e4 / collateralUsdc      // read from the venue, NOT assumed to be policy
anchor     = min(currentLtv, targetLtvBps())      // NEVER anchor on policy alone — see below
candidates = anchor − 250, anchor − 500, anchor − 750, …   // integer bps, round DOWN
floor      = operator policy (e.g. 2500 bps)      // stop here
```

- **Every candidate must be strictly below `currentLtv`.** `adjustLeverageImpl` takes the **lever-UP**
  branch whenever `targetDebt > debtUsdc`, so a candidate above current LTV *increases* risk while the
  operator believes they are de-risking. Anchoring on `targetLtvBps()` alone is wrong whenever the book
  has drifted **below** policy — which is an ordinary state, not an edge case.
- **If no candidate passes by the floor, stop and escalate.** Do not keep dropping; past some point the
  request is not fulfillable at any leverage and the answer is to wait, or let the requester cancel.
- **Restore is one call after the queue drains**: `adjustLeverage(targetLtvBps(), minLiq, minOut)`.
  Restoring between requests just pays the round trip repeatedly.

#### Quoting `minAssetsOut`

| | |
|---|---|
| The **stored** floor | `redeemRequest(id).minAssetsOut` — the **third** field of `(owner, shares, minAssetsOut, requestedAt, settled, recipient)`. **The strategy's `RedeemRequested(id, owner, recipient, shares)` does NOT carry it** — only the account's `WithdrawRequested(id, shares, minAssetsOut)` does. Read the struct; do not reconstruct it from strategy logs. |
| What the chain enforces | `max(stored, fresh)`. Your fresh floor can only **tighten** the requester's, never loosen it — `0` is the identity. |
| Getting the **fresh** number | `fulfillRedeem` has **no return value**, so a plain `eth_call` yields `0x`. The realised payout lives solely in **`RedeemFulfilled(uint256 indexed id, address indexed owner, address indexed recipient, uint256 assetsOut)`** — `assetsOut` is still the only non-indexed field, so it is the whole `data` word, but the **`topic0` changed** with the added `recipient` topic. Simulate, decode that log, send with `minAssetsOut = assetsOut × (1 − tolerance)`. |
| **Do NOT quote with `previewRedeem`** | It is the **fast-path** quote — `shares × navNet / supplyPost`, oracle-priced — and does not model the async unwind's swap costs, so it **over-quotes**. Used raw as a floor it reverts `InsufficientAssetsOut` against itself. |

Measured on the live staging clone — 10% of supply, calm book, LP in range:

```
previewRedeem(shares)            10,001,212,660   (fastOk = false — routed to async)
RedeemFulfilled.assetsOut        10,001,153,342   (simulated fulfil — 0.6 bps lower)
```

0.6 bps of drift on a calm in-range book, **wider whenever there is an IL gap to cover**, since the
cover buy and the leg sweeps both cross a pool. An order-of-magnitude sanity check, never the floor.

#### Why levering down fixes a failing fulfil

An asymmetry in **who pays for the IL cover** — not "leverage is too high" in the abstract:

- A **partial** redeem caps its cover at the **redeemer's own pro-rata budget** (`balance − stayersIdle`)
  and is **not** best-effort: a deficit buy that will not fit inside that budget reverts the whole fulfil
  rather than spending the stayers' `(1−f)` share.
- `adjustLeverage`'s lever-down has **no such cap** — bounded only by your `minOut` and the oracle floor,
  so the fund pays out of the **whole book**.

It also shrinks the gap. Collateral is untouched while debt *and* the matching CL fraction both scale by:

```
f = targetBps / currentLtv          ← NOT targetBps / targetLtvBps()
```

because `targetDebt = targetBps × collateral / 1e4` is compared against **current** debt, and
`_unwindLiquidity` removes `(debt − targetDebt) / debt`. The two coincide **only** when the book sits
exactly at policy. Measured on the live clone, at `currentLtv = 6157` against a policy of `5000`:

| `targetBps` | debt before | debt after | realised `f` | `targetBps/currentLtv` | `targetBps/policy` (wrong) |
|---|---|---|---|---|---|
| 4800 | 50,036,587 | 39,006,102 | 0.77955 | 0.77960 | 0.96000 |
| 4200 | 50,036,587 | 34,130,340 | 0.68211 | 0.68215 | 0.84000 |
| 3600 | 50,036,587 | 29,254,577 | 0.58466 | 0.58470 | 0.72000 |
| 3000 | 50,036,587 | 24,378,814 | 0.48722 | 0.48725 | 0.60000 |

#### How much does the withdrawal size matter?

**To first order, not at all** — which is why the de-lever target tracks the book's IL state rather than
the amount. Every term in the cover constraint is the redeemer's pro-rata slice: the shortfall is
`f × (debt − LP amount)` per leg; the budget is `f × collateral` (the redeem burns `f` of the cToken
balance) plus `f × idle` (`stayersIdle` reserves the rest) plus the `f`-scaled surplus-leg sweep. The
`f` cancels.

**It is an approximation, not an invariant.** Simulate every request regardless. Five things break exact
proportionality:

- **AMM price impact is nonlinear** — a bigger cover buy moves the pool further per unit.
- **A FULL redeem (`shares == supply`) is a different code path**, not a scaled partial: three phases,
  a `type(uint256).max` cover budget, and a best-effort Phase 1.
- **Stored floors are absolute per request** — one request can fail `InsufficientAssetsOut` where
  another of a different size passes.
- **Rounding** — `mulDiv` floors, and small requests can reach `ZeroAssetsOut`.
- **Each fulfil mutates the book and the pool**, so a later request's simulation must be re-run against
  post-fulfil state.

So: **one de-lever can serve the whole queue** (the target does not need recomputing per request), but
**each request still needs its own simulation, in queue order, after the previous receipt.**

**Ordering — two different claims, both true.** The *protocol* imposes none: `fulfillRedeem` indexes a
mapping, there is no FIFO and no head pointer, so any order or one multicall is legal and a stuck request
blocks only itself. The *outcomes* are path-dependent: each fulfil moves the book and the pool, so a
different order gives different payouts and a different simulation result. Do not read "no ordering
constraint" as "order does not matter".

#### Classify the revert before reacting

> **Ranked by what actually fires.** The three rows marked **LADDER** below are the observed failures on a
> real out-of-range matrix (vnet, 2026-08-21, five price scenarios); `ZeroAssetsOut` was the dominant one
> and `MoonwellRedeemFailed` was the blocker in the only scenario that needed a de-lever at all.

| Revert | Meaning | Action |
|---|---|---|
| **`ZeroAssetsOut`** | The unwind paid the redeemer **exactly nothing**: `redeemUnwindImpl` returns `usdcFinal − stayersIdle` floored at 0, and the cover consumed the redeemer's whole slice. The **most common** ladder signal out of range — every greyed rung of the observed matrix ended here. Fail-closed by design: the escrowed shares are **not** burned and stay cancellable | **LADDER.** A deeper de-lever repays more debt out of the *whole book*, leaving the redeemer's slice intact |
| **`MoonwellRedeemFailed(errCode)`** on the FULFIL path | The partial branch calls `_redeemCollateral` **first**, and Moonwell refuses a collateral redeem that would leave the account under-collateralised. Observed at **70.53% LTV** — above `maxLtvBps`, which is reachable by price drift because the cap binds *operations*, not drift | **LADDER.** This is a leverage problem, not a venue outage. (A paused market or a cash-short market is the *other* cause of the same error — distinguish by `errCode` and by whether LTV is elevated) |
| **router revert** (untyped) from the cover's `exactOutputSingle` | the IL deficit buy did not fit the redeemer's pro-rata budget **and** could not partially fill | **LADDER** |
| `InsufficientAssetsOut` | payout under `max(stored, fresh)` | **conditional.** If cover swaps are eating the payout, a lower target raises the achievable net — retry lower. If the floor is unreachable at the current price, levering down cannot help and its own swap costs come out of NAV: wait, or the owner cancels. Never try to lower the floor |
| `RequestSettled` | already fulfilled or cancelled | drop it from the queue — **never** a de-lever |
| `NotProposer` / `NotExecuted` | wrong key, or the strategy is not `Executed` | fix the caller / check lifecycle — **never** a de-lever |
| `MoonwellRepayFailed` | the venue refused a **repay** (market paused) | retry later — **never** a de-lever |
| oracle / sequencer failures, `RedeemSweepFloorsDegraded` | feed or L2 uptime problem | do not fulfil into a degraded oracle unless the deadman forces it — **never** a de-lever |
| broken AERO→USDC route, `RedeemRewardSaleDeferred` | the reward leg could not sell | non-fatal to the redeem; investigate the route separately |

**Retry the SAME request id — do not cancel and re-request.** A reverted `fulfillRedeem` leaves the
request untouched and retryable: nothing is settled, nothing is burned, the escrow stands. Cancelling and
re-requesting works, but `requestRedeem` stamps a **fresh `requestedAt`**, which **restarts the 2-day
`FULFILL_WINDOW`** and pushes back the requester's trustless `emergencyRedeem` escape hatch. That is a
silent downgrade of a user guarantee, taken by the operator, in a state where the operator has already
demonstrated it cannot pay. Retry in place.

> **KNOWN GAP — classification is brittle today.** The cover-budget failure is the *router's* untyped
> revert: `swapExactOut` with `bestEffort == false` calls `exactOutputSingle` **directly**, so there is no
> strategy-specific selector to branch on. Keyers must match on the router's revert data, which is
> fragile across router versions. A typed error on that path is a worthwhile contract follow-up — it is
> the single signal the whole loop keys off.


---

## D. Deposit handling

Deposits from the Mamo accounts' `deposit`/`depositIdle` calls arrive as **idle USDC on the strategy**
and earn nothing until deployed. Key facts for the agent:

- `deposit(assets, minShares)` on the strategy mints shares priced against `nav()` but leaves the USDC
  idle — the comment is explicit: "Deposited USDC sits idle until a proposer calls `deployIdle()`."
  **Deposit touches no venue at all**, deliberately: a paused or supply-capped Moonwell market can never
  refuse the fund's money-in path.
- **Idle USDC does not have to be dead while it waits.** `supplyIdle(amount)` (§B) parks any part of the
  raw balance in Moonwell to earn supply interest, without borrowing or touching the LP, and works on a
  flat book too. It is NAV-neutral. How much you leave raw is a real dial — the raw float is the only
  ORACLE-FREE cover for an IL shortfall on a full async redeem (§B, `supplyIdle`).
- **`nav()` counts strategy-held raw USDC AND its Moonwell collateral, but NOT vault float.** Both
  branches count both terms: the active branch through `netEquityUsdc`, and the flat branch through
  `LeveragedAeroValuation.usdcAvailable(usdc, mUsdc, strategy)` — raw balance plus
  `mUsdc.balanceOf × exchangeRateStored / 1e18`, no feed read, so a flat book stays priceable through an
  oracle outage. Vault float is excluded to preserve deposit/redeem symmetry. So idle-but-undeployed
  deposits are in NAV and correctly priced whether or not you have parked them.
- The agent's job is to **periodically `deployIdle`** accumulated idle USDC (or `supplyIdle` it and lever
  on a separate cadence). `amount` is bounded by raw USDC **plus** redeemable mUSDC collateral — the
  leverage caps bind the *result* (the closing `_assertHealthy()`), not the input, because the tranche is
  borrowed at exactly `targetLtvBps` (§B). The real decision is the size of the reserve you leave
  behind — and note that parking a reserve with `supplyIdle` does **not** remove it from `deployIdle`'s
  reach, but it does remove it from the oracle-free redeem cover.
- **Why the reserve matters: the fast `redeem` path draws idle FIRST, then Moonwell collateral** — via
  `_redeemUnderlying($.mUsdc, …)` — and **never** touches the LP position or the debt (the fast path has
  zero LP call sites; unwinding the LP happens only on the async `fulfillRedeem` path). The LTV gate
  applies to the collateral-funded remainder only, since pulling collateral against unchanged debt raises
  LTV: a breach of `maxLtvBps` reverts `FastRedeemExceedsLtv` and forces the redeemer onto the request
  queue. **When idle fully covers the redeem the gate is skipped entirely** (`if (fromCollateral == 0)
  return;`), so a healthy idle balance is what keeps ordinary exits off your SLA loop. Note a redeemer can
  only draw their own pro-rata `f × idle` (`f = shares/supply`); the stayers' `(1−f)` share is reserved.
- **Do not confuse this with the account-level `depositIdle` nudge.** That is a *separate* surface on the
  per-user `MamoLeveragedAeroStrategy` account (sibling backend doc), gated to the owner or registry
  backend member-0, and it moves a user's plain-transferred USDC into the fund. This section is about
  **strategy-level** idle USDC — the pooled deposits sitting on the strategy clone — deployed with the
  **proposer** key via `deployIdle`.

### The idle loop — how `deployIdle`, `supplyIdle`, `withdrawIdle` and `flatten` compose

The withdraw side has a clock (§C); the deposit side does not. Idle USDC is in `nav()` and correctly
priced whether or not it is deployed, so nothing here is an SLA — the cadence is a yield decision.
**Two of these are the routine loop; the rest are exception paths.**

| Op | Cadence | Trigger |
|---|---|---|
| `deployIdle(amount, minLiquidity)` | **routine** | Idle USDC has accumulated on a **live** book. Unchanged by the ops below — a keeper that only ever calls this is correct, just not maximally yielding. |
| `supplyIdle(amount)` | **routine, optional** | That idle will sit a while before it is levered, or the book is **flat**. Parks it in Moonwell at supply interest, NAV-neutral. Gas-bounded: pick a floor (≈$100) and let smaller residues wait for the next sweep. |
| `withdrawIdle(amount)` | exception | The **raw** float has drifted below the redeem cover you want to hold oracle-free. Not part of the deposit flow — it is the same dial turning back. |
| `flatten(minRewardUsdcOut, minIdleUsdcOut)` | exception | Venue migration (§G2), or a range the price has left that `rerange` cannot reopen two-sided. **Never terminal — always followed by `redeploy`.** |
| `redeploy(minLiquidity)` | exception | Re-enter from a **flat** book (§G2). The pair to `flatten`. |

**The composition fact that makes the ordering free:** parking with `supplyIdle` does **not** put USDC
out of `deployIdle`'s reach. `deployIdle` is bounded by raw **plus un-levered collateral**
(`C − ceil(D·1e4 / targetLtvBps)`) and redeems the shortfall on demand, so `supplyIdle` now →
`deployIdle` later needs no `withdrawIdle` in between. Same for `redeploy`, which funds off
`_usdcAvailable()` (raw **plus** collateral) precisely so it can re-enter a book the keeper swept into
mUSDC. On a live book, `supplyIdle` + `adjustLeverage` and `deployIdle` land the same position; the
difference is that `deployIdle` is one call with a `minLiquidity` floor.

The loop, in the order a keeper run should evaluate it:

```
idle = usdc.balanceOf(strategy)        # RAW only; parked collateral is not in this number
if state != Executed:      nothing to do (§F)
if idle < gasThreshold:    nothing to do

if layout().tokenId == 0:              # FLAT book
    supplyIdle(idle)                   # optional: earn while flat, does not strand it
    redeploy(minLiquidity)             # deployIdle CANNOT re-enter a flat book
else:                                  # LIVE book
    deployIdle(idle - reserve, minLiquidity)   # the normal path
    # or, if levering on a separate cadence:
    supplyIdle(idle - float)                   # NAV-neutral; levered by the next deployIdle/adjustLeverage
```

**`deployIdle` cannot re-open a flat book.** It `increaseLiquidity`s the stored `tokenId`, which is `0`
when flat; `redeploy` is the genesis-sequence re-entry and conversely reverts `PositionAlreadyOpen` on a
live book. So `flatten` is never complete on its own: the sequence is `flatten` → (`migrateVenue`, if
migrating) → `redeploy`. Note `redeploy` deploys the **whole** pot at the stored target LTV, which leaves
the book with no un-levered slice — a `withdrawIdle` immediately after it will hit `InsufficientIdle`, and
the raw float rebuilds from subsequent deposits.

**Do not sweep to zero — two different reserves come out of the same idle balance.**

- The **raw** float is the ORACLE-FREE IL cover: Phase 1 of a full async redeem's shortfall buy reads no
  Chainlink feed. `supplyIdle` spends this budget, `withdrawIdle` restores it.
- **Total** idle (raw + parked) is what keeps ordinary exits off your SLA loop: the fast `redeem` path
  draws idle first, never touches the LP, and skips the LTV gate entirely when idle covers the redeem.

Both are policy dials, deliberately — §B (`supplyIdle`) has the trade-off in full.

---

## E. Monitoring & reads for the keeper

```solidity
function nav() public view returns (uint256);                                   // USDC 6dp, net of protocolFeeOwed
function previewRedeem(uint256 shares) external view returns (uint256 assetsOut, bool fastOk);
function state() external view returns (State);                                 // Pending/Executed/Settled
function layout() external view returns (LayoutView memory);                    // full config/risk/fee/position state
function redeemRequest(uint256 id) external view returns (RedeemRequest memory);
function positions() external view returns (Position[] memory);                 // PriceRouter reporting
function proposer() external view returns (address);
function vault() external view returns (address);

// Two dedicated keeper getters — the same storage `layout()` returns, given their own selectors
// so a rebalancer can read them without decoding the whole LayoutView.
function targetLtvBps() external view returns (uint16);                         // the STANDING target
function hedgedDebt() external view returns (uint128 legA, uint128 legB);       // hedged borrow PRINCIPAL

// The Chainlink min-out floors the proportional unwind's two residual leg sweeps must clear, for the
// given leg-B / leg-A amounts being sold. Reverts (fail-closed) when a feed is stale — inside the
// unwind that revert is CAUGHT and the floors fall back to 0, which is what keeps `emergencyRedeem`
// alive with the oracle down. Pass 0 for leg B in asset-mode (that sweep is the identity).
function redeemSweepFloors(uint256 cbAmt, uint256 wethAmt) external view returns (uint256, uint256);
```

- **`targetLtvBps()`** is the fund's **standing** target — set at init, re-set in either direction by the
  admin's `setTargetLtv`, and writable by nobody else — and it is what `execute` / `deployIdle` /
  `compound` size their borrow at, and the CEILING on `adjustLeverage`'s per-call target.
  Read it **before** rebalancing; do not infer it from the position's current LTV, which drifts with price.
  If policy should be **higher** than it is, that is a multisig action, not a keeper one.
- **`hedgedDebt()`** returns the borrowed **principal** each leg's LP side currently hedges. The unhedged
  accrued borrow interest is `borrowBalanceStored(market) − hedgedDebt*` per leg, and that difference is
  exactly what `compound` buys back and repays out of harvest proceeds (§B). Use it two ways: to decide
  whether a harvest is worth calling, and to confirm afterwards that drift returned to ~0. `legB` is
  structurally **0** in asset-mode (leg B is the unit of account there and is never borrowed). Note the
  contract itself measures with `borrowBalanceCurrent` (accrue-then-measure), so an off-chain
  `borrowBalanceStored` read **understates** the drift by whatever has not yet been capitalised on that
  market — treat it as a lower bound. The same two values are also on `layout()` as
  `hedgedDebtA`/`hedgedDebtB`.

- **`nav()` fail-closed semantics.** With an active position (`tokenId != 0`), `nav()` prices the levered
  book at an oracle-implied `sqrtP` and **reverts** on any oracle/calm-gate failure or ≤0 equity (a stale
  feed, a sequencer-down, a shoved pool, or a worthless book). Operationally: a `nav()` revert is **not**
  a panic signal — it means the fast/priced paths (deposit, fast `redeem`, `previewRedeem`) degrade to the
  async queue. The agent can **still fulfill** requests: `fulfillRedeem`'s proportional unwind is
  oracle-free (best-effort crystallize with `navPre = 0`). Don't gate the fulfill loop on `nav()`.
- **`nav()` prices the WHOLE gauge-reward claim — held balance *and* `gauge.earned()`.** Two places reward
  value can sit, and both are in NAV:
  1. the **claimed-but-unsold balance**. Every unwind (`rerange`, `adjustLeverage`, a proportional
     `fulfillRedeem`, `flatten`, `settle`) goes through `gauge.withdraw`, which **auto-claims** the accrued
     AERO tranche into the strategy whether or not anyone asked for it; and
  2. the **still-unclaimed `gauge.earned(strategy, tokenId)`** on the staked NFT — where a harvest spends
     most of its life, and therefore the larger of the two.

  Both are marked on the same `aeroUsdFeed` (8dp) the sale floor uses. `earned()` is read through a
  `try/catch`: the gauge reverts `"NA"` for a tokenId it does not have staked, and that state is exactly
  the state where the tranche has just been auto-claimed into (1) — so the catch-to-0 is correct, not an
  understatement, and the sum is continuous across the unstake. A flat book (`tokenId == 0`) skips the call.
  Three operator consequences:
  - **NAV no longer steps at `compound`.** Reward value is priced where it sits, so a `compound` is a
    conversion (AERO → USDC at the same mark), not a jump. There is no longer a window in which a deposit
    buys in below the true book and collects a slice of someone else's harvest — that was worth ~4.5% of a
    100k deposit, post-fee, in a single block before this change.
  - **The reward feed is now a standing `nav()` dependency whenever the gauge is live.** The feed read is
    gated on `heldBalance + earned() > 0`, and with live emissions that sum is essentially always positive —
    so a stale `aeroUsdFeed` **fail-closes `nav()`**: deposits and the priced fast redeem are denied until
    the feed recovers. (Before this change the dependency only existed inside a post-unwind window.) This is
    intentional — a NAV that cannot be computed honestly must not price a deposit — and the async queue is
    unaffected: `fulfillRedeem` never reads `nav()`, so the exit stays open throughout. `compound` clears
    the held half; the `earned()` half returns as soon as the feed does.
  - **Fee crystallisation reads NAV, so the performance fee now accrues against UNREALISED, UNCLAIMED
    rewards, continuously.** This is the deliberate trade-off of pricing `earned()`: a fee can be
    crystallised on reward value the fund has not yet realised, and a later adverse event (a gauge killed by
    governance, a broken reward route, a sale under the mark) means some of it never is. Accepted as the
    correct side to err on — the alternative mis-prices every deposit, every block, in an attacker's favour.
    Accounting should expect fee accrual to track emissions rather than harvest events.
  - **Second-order, accepted:** Slipstream accrues emissions on `rewardGrowthInside`, so the marked
    `earned()` is mildly **tick-influenced**. It is bounded by the calm gate — `nav()` runs the
    spot-vs-TWAP check before pricing anything, so a shove beyond `calmDeviationTicks` fail-closes the whole
    NAV first.
- **`previewRedeem(shares)`** returns `(assetsOut, fastOk)`; `assetsOut` is the advisory oracle-priced
  fast-path payout and `fastOk` whether the fast path would currently price **and** clear the LTV gate.
  Both are advisory — the manager's on-chain gate is authoritative. Returns `(0, false)` on an oracle
  outage. Useful for dashboards and for routing a user between the fast and async paths. **NOT for the
  async fulfil**: it neither quotes the async payout nor predicts whether a fulfil needs a de-lever —
  simulate for both (§C "Sizing the fulfil").
- **`layout()`** (memory-returnable `LayoutView`, minus the `redeemRequests` mapping) is the single read
  for **risk caps** (`targetLtvBps`, `maxLtvBps`, `minHealthBps`, `maxSlippageBps`,
  `usdcCollateralFactorBps`), **fees** (`managementFeeBps`, `performanceFeeBps`, `feeRecipient`,
  `hwmPerShare`, `lastFeeAccrualTimestamp`, `protocolFeeOwed`), **venue/feed addresses** (pool, npm,
  gauge, swapRouter, comptroller, the Moonwell markets, the Chainlink feeds incl. `aeroUsdFeed`,
  `sequencerFeed`), **oracle config** (`maxDelay`, `gracePeriod`, `calmDeviationTicks`, `twapWindow`,
  `tickSpacing`), **position state** (`tokenId`, `posTickLower`, `posTickUpper`, `nextRedeemRequestId`),
  the **range knobs and their two init bands** (`width`, `minWidth`, `maxWidth`, `skewBps`, `minSkewBps`,
  `maxSkewBps`), the **hedged-debt basis** (`hedgedDebtA`,
  `hedgedDebtB`), and the **venue-shape fields the keeper must not assume** (`legBIsAsset`,
  `cbBTCDecimals`, `wethDecimals`, `wethIsToken0`, `wethDeliversNative`, `cbBTCSwapTickSpacing`,
  `wethSwapTickSpacing` — see §G).
- **Current LTV / health.** There is no public LTV getter, but the health basis is
  `collateralUsdc × 1e4 / debtUsdc` on the same hardened-Chainlink reads `_assertHealthy` uses. To compute
  it off-chain the keeper reads collateral/debt from Moonwell directly — `mUsdc.balanceOf × exchangeRateStored / 1e18`
  for collateral, `mCbBTC/mWeth.borrowBalanceStored` for the raw debt, priced with the same feeds — or
  cross-checks Moonwell's own `Comptroller.getAccountLiquidity(strategy)` (a non-zero `shortfall` is the
  authoritative "unhealthy" signal `_assertHealthy` and `deleverage` both consult). `previewRedeem` also
  indirectly reflects the gate (`fastOk`).

**Events for ops dashboards.** The event coverage is asymmetric, and the asymmetry matters:

- **The user-flow events the rebalancer depends on already exist.** Most importantly
  `RedeemRequested(id, owner, recipient, shares)` — the withdraw-request trigger that drives the whole SLA loop —
  plus the rest of the queue set (`RedeemFulfilled`/`RedeemCancelled`/`RedeemEmergency`) and
  `FeeCrystallizeDeferred`. Nothing needs to be added for the keeper's core watch-and-fulfill duty.
- **Position-management ops emit nothing** — `deployIdle`, `compound`, `rerange`, `adjustLeverage`, and
  `deleverage` are event-silent from both the strategy and the manager (the manager emits no events at
  all). What *does* emit is every write to the standing target — the admin's `setTargetLtv` and a
  `migrateVenue` whose staged params change it — both as
  `TargetLtvUpdated(previousBps, newBps)`; watch it as a risk change. Until that changes, dashboards key off
  venue-level events (Moonwell mint/borrow/repay/redeem, Slipstream NPM increase/decrease, gauge
  stake/getReward) and transaction receipts.
- **Adding events is an open option, not a blocker.** If the rebalancer or an indexer ends up needing
  first-class `Compounded`/`Reranged`/`LeverageAdjusted`-style events, they can be added **directly in this
  repo** — the package is an in-repo fork now, so there is no upstream round-trip or re-vendor wait. Raise
  it when a concrete consumer needs it; don't build ops tooling on the assumption they'll never exist.

Strategy events that exist today:

| Strategy event | Use |
|---|---|
| `RedeemRequested / RedeemFulfilled / RedeemCancelled / RedeemEmergency` | withdraw-queue tracking (§C) |
| `FeeCrystallizeDeferred(uint8 op, uint256 navPre)` | a best-effort crystallize deferred (`op`: 0=deposit, 1=fast redeem, 2=proportional redeem). The fee-share mint failed — on the vanilla vault the realistic cause is `depositsOpen == false` (`"LAV: deposits closed"`); investigate. |
| `SettleRewardSaleDeferred()` | the **terminal settle**'s best-effort reward-tranche sale was skipped (stale/paused AERO feed, broken AERO→USDC route, or a fill under the L9 floor). The settle completed; the tranche is left on the now-`Settled` strategy and needs the owner's `rescueToVault(rewardToken)` → `vault.rescueERC20`. **Check the strategy's AERO balance after any settle.** |
| `RedeemRewardSaleDeferred()` | an **async redeem**'s sale of the tranche its own unwind auto-claimed was skipped, same causes. The redeem completed and paid, but that redeemer got `f × (assets − reward)` and the tranche stayed with the stayers — the one residual of the pre-fix behaviour (§C). Clear it with `compound` once the feed/route recovers; a *recurring* one means every redeemer is being short-paid, so treat it as a feed/route incident, not noise. |
| `RedeemSweepFloorsDegraded()` | an **async redeem**'s closing leg→USDC sweeps ran with their Chainlink min-out floors at **zero** — the derivation reverted (stale feed / down sequencer, or an out-of-gas: the `catch` cannot tell them apart). Deliberately fail-open so the `emergencyRedeem` deadman still completes, but those swaps were **unbounded** for that call. Expect it only alongside a real oracle outage; seeing it while feeds are healthy is a gas/venue problem worth investigating before the next fulfill. |
| `WithdrawIdleBoundDegraded()` | a `withdrawIdle` could not price its un-levered bound at the hardened reader and **re-derived the same line from Moonwell's own account snapshot** for that call (see the `withdrawIdle` entry's Feed-outage row). The withdraw happened, **inside the bound** — what degraded is the price basis, not the line. Reconcile LTV against the hardened feeds once they recover; seeing it while feeds are healthy is a gas problem worth investigating. |
| `HedgeLegMeasureDegraded(address market)` | a `compound` could not accrue-and-read one leg's live Moonwell debt, so that leg's interest-drift hedge was skipped for the harvest (the other leg proceeds). The drift stays open and compounds until a later harvest reads it; a *recurring* one on the same market is a venue incident. |

> **The naming rule for the fail-opens above.** `…Deferred` = an optional **action** was skipped;
> `…Degraded` = a **guard or measure** fell back and the op ran with less protection. All are emitted from
> the strategy address (the library-declared ones reach the strategy's ABI through delegatecall). None of
> them reverts anything — they exist because the `catch` blocks they mark cannot distinguish their
> expected cause from any other revert, and a silent fail-open leaves no on-chain trace at all.

---

## F. Hard operational constraints

- **Oracle staleness / sequencer.** All priced paths (`nav`, fast `redeem`, `compound`, `_assertHealthy`,
  `deleverage`) read hardened Chainlink with `maxDelay` staleness, `gracePeriod` sequencer-restart grace,
  and a calm-gate. A stale feed or a down sequencer **fail-closes** — the op reverts. This is intended
  posture: defer the harvest / re-range / deleverage and rely on the oracle-free async queue for exits.
  **One deliberate exception:** `withdrawIdle` does not jam — its bound is re-derived at Moonwell's own
  oracle and the call is marked `WithdrawIdleBoundDegraded` (see its entry) — because restoring the
  oracle-free redemption float is most needed during exactly this state.
- **Calm gate.** Every mint/add path runs the calm-gate (`|spotTick − twapTick| ≤ calmDeviationTicks` over
  `twapWindow`) before the pool is touched, as does NAV pricing — so the agent can never reposition, add or
  price at a manipulated tick. A shoved pool blocks `rerange`, `deployIdle`, `compound`'s redeploy and a
  lever-**up**; retry once calm. **Where in the op the gate fires is not uniform**, and an operator reading
  a reverted trace should expect it: `rerange` gates first, before any venue call; `execute` gates after
  `enterMarkets` but before the supply/borrow/mint; `deployIdle` and lever-**up** reach the gate inside the
  CL add, i.e. *after* the Moonwell supply/borrow already executed in that transaction. In all cases the
  breach reverts the **whole** transaction atomically — there is no state to unwind by hand and no partial
  deploy to reconcile — but a shoved-tick `deployIdle` trace will show a Moonwell borrow before the
  `CalmGateBreached` revert. That is expected, not a partial failure.
  **Coverage map — correction: the gate is on ADD paths only.** `deleverage`, `settle` and the redeem
  unwinds (`fulfillRedeem` / `emergencyRedeem`) are deliberately **un-gated**. They burn liquidity rather
  than mint it, so a shoved tick cannot be used to mint the fund a bad position through them — and gating
  them would let anyone block a user's exit or the safety valve by shoving the pool. Do not read an
  un-gated unwind as a missing check.
- **Per-op slippage bounds.** Every value-moving op takes a caller `min*` floor **and** is additionally
  bounded by the always-on `maxSlippageBps` (∈ (0, 1000] = ≤10%, set at init). `compound` is further
  floored by the AERO/USD oracle (`BelowOracleFloor`). Pass **tight, freshly-quoted** floors; `0` is not
  legal for `compound.minUsdcOut` (`ZeroMinOut`).
- **Swap-route `tickSpacing` is now configured, not hardcoded (was audit item 10).** The three
  `int24(100)` literals are gone: the auxiliary USDC↔leg swap helpers
  (`_sweepLegToUsdc`, `_redeemCoverShortfall`) resolve the route spacing per leg from the init params
  `cbBTCSwapTickSpacing` / `wethSwapTickSpacing` (non-zero enforced at init; readable via `layout()`),
  independently of the LP pool's `tickSpacing`. The single-venue-at-spacing-100 assumption is **gone** —
  but the route is still **one pool per leg**, fixed at init and not switchable at runtime, so keep an eye
  on the depth of whichever two swap pools the clone was wired to.
  What has **not** changed: the redeem path's two residual-leg sweeps still pass `minOut = 0`
  (`_sweepLegToUsdc($.cbBTC, stayersCb, 0)` / `(…$.weth, stayersWeth, 0)`) and lean entirely on the
  redeem's **aggregate** `minAssetsOut` floor, and a full redeem's phase-1 shortfall cover runs with
  `amountInMax = type(uint256).max`. Prefer sizing exits so the fast/priced path or a pre-deleverage
  carries them, rather than leaning on those sweeps under stressed leg-pool conditions. (The
  *deleverage/adjustLeverage* residual swap is separately oracle-floored — `_rebalanceCover` raises any
  caller `minOut` to `oracleValue × (1 − maxSlippageBps)` — so the permissionless `deleverage(0)` is not
  sandwichable. It is now also **need-sized**: it sells only the surplus required to cover the shortfall
  and keeps the remainder as an idle leg balance, which shrinks the swapped notional and therefore the
  slippage surface on every lever-down. That raised floor is handed to the router, so a breach surfaces as the **router's own
  `amountOutMinimum` revert**, not as `BelowOracleFloor`, which has exactly one raise site: `compound`'s
  AERO→USDC sell. Alert on both.)
- **Fee-path asymmetry (audit item 7).** Crystallize is **best-effort** on user-exit paths (defers +
  emits `FeeCrystallizeDeferred`) but **hard-reverts** on `compound`/`settle`/the redeem skim. A persistent
  `FeeCrystallizeDeferred` on deposits/redeems while `compound` reverts points at a **frozen vault**
  (`depositsOpen == false` → the fee-share mint reverts `"LAV: deposits closed"`) — an ops issue to clear.
  Note the vanilla vault has **no pause and no depositor whitelist**; that one flag is the whole gate.
- **`deleverage` accepted residual (audit item 9).** Our-feed staleness can block `deleverage` in a window
  where Moonwell's own oracle is fresh enough to liquidate; documented and accepted. Monitor Moonwell
  account liquidity independently.
- **The flat book is a TERMINAL state — the fund cannot re-enter the LP.** After a **full** redeem (the
  last holder exits via `fulfillRedeem` or `emergencyRedeem`) the position NFT is gone: `tokenId == 0`
  while `state()` is still `Executed`. Everything then degrades quietly rather than reverting, which is
  exactly why it needs saying out loud:
  - `rerange` **persists but mints nothing** — the width/skew writes land in storage, the venue call has
    no position to re-add, and you get a success receipt for a no-op.
  - `deployIdle` **fails closed** — there is no NFT to `increaseLiquidity` into.
  - `compound` **no-ops** (its explicit `tokenId == 0` early return), so it cannot rebuild the book either.
  - `execute` is **one-shot** (`Pending → Executed`) and cannot be replayed to re-mint a genesis position.

  Deposits still work and land as idle USDC, `nav()` still prices them, and they remain withdrawable at
  face — nobody is trapped and nothing is lost. But the capital **cannot be put back to work**: the only
  path forward is `settleStrategy()` and a **new vault**, because the vault's strategy binding is
  **set-once** (`_bind`, no rotation). Treat "supply went to zero" as an incident that ends the fund's
  life, not as an idle state to redeploy from — and keep a non-zero stake in the book if you want the
  option to continue.

See [`docs/LEVERAGED_AERO_CL_AUDIT.md`](../LEVERAGED_AERO_CL_AUDIT.md) for the full audit focus-area list.

---

## G. Per-clone venue shape — read it, don't assume it

The strategy now initializes against **any** Slipstream pool whose two tokens have Moonwell borrow markets
and Chainlink feeds. Nothing about the pair is hardcoded any more, so the keeper must read the shape off
the clone rather than assuming the launch pair:

- **There are TWO pool shapes, and the clone tells you which (`legBIsAsset`).** This is the single most
  consequential shape field — it changes what several ops do, not just what they're denominated in. It is
  **derived at init**, not configured: `legBIsAsset == (cbBTC slot address == usdc)`. Branch on
  `layout().legBIsAsset`, never on the token addresses by hand.

  | | `legBIsAsset == false` — two borrowed legs | `legBIsAsset == true` — asset-as-leg-B |
  |---|---|---|
  | Pool | both legs are volatile (e.g. cbBTC/WETH) | leg B **is USDC**, the unit of account (e.g. WETH/USDC) |
  | Collateral on `deployIdle` | the **whole** `amount` | only `C < amount` from `assetModeSplit`; `U = amount − C` becomes the LP's USDC side |
  | Borrows | **both** legs, 50/50 by USD | **leg A only** |
  | `hedgedDebt()` | both `legA` and `legB` move | `legB` is structurally **0** |
  | `compound` interest hedge | hedges **both** legs from one shared budget | hedges **leg A only** (leg B can't drift) |
  | Lever **up** | self-funding (the pair is the two borrows) | **consumes idle USDC**; reverts `InsufficientIdleForLeverUp(needed, available)` if short |
  | `rerange` | remainder left idle is a borrowed leg | **never draws idle USDC** (the re-add is capped at what the unwind collected, snapshot pre-unwind); the remainder left idle is USDC |
  | Range-sensitivity | none on the deploy path | `deployIdle` / lever-up size against the **STORED** range → `DegenerateRange()` when it is one-sided; `rerange` first — but that only re-opens a two-sided range while spot is still *inside* the old band; past it, `flatten` + `redeploy` |

  The operator rule of thumb for asset-mode: **idle USDC is both the redeem buffer and an input to
  `deployIdle` and `adjustLeverage` (up)** — but **not** to `rerange`, which since the pre-unwind leg-B
  snapshot re-adds only what it collected and can no longer reach idle or the redeem cover. Track idle as
  a budget for the two ops that do spend it, and prefer a `rerange` back onto spot before any op that
  sizes against the stored range.
- **`weth*` / `cbBTC*` are leg SLOTS, not tokens.** `weth`/`mWeth`/`wethFeed`/`wethDecimals` are **leg A**
  (the slot that may be delivered natively on borrow); `cbBTC`/`mCbBTC`/`cbBTCFeed`/`cbBTCDecimals` are
  **leg B**. The names are historical — read the actual token addresses from `layout()`. Every error
  message and field name in this guide that says "cbBTC" or "WETH" means the corresponding slot.
- **Decimals are read, not assumed.** `cbBTCDecimals` / `wethDecimals` come from `IERC20Metadata.decimals()`
  at init and are bounded to `[2, 18]` (`LegDecimalsOutOfRange()` otherwise). They drive every leg↔USDC
  conversion, so an off-chain model that hardcodes 8/18 will disagree with the chain on a different pair.
- **Pool ordering is derived.** `wethIsToken0` comes from `pool.token0()` at init. It is what maps
  (leg B, leg A) onto (amount0, amount1) — including for `rerange`'s `minLiq0`/`minLiq1`. Read it; never
  infer ordering from the slot names.
- **Native wrap is conditional (`wethDeliversNative`).** With `true` (Base mWETH's behavior) the strategy
  wraps borrowed native ETH into the leg-A token. With `false` the wrap helper is a **no-op**, so any ETH
  that reaches the strategy's `receive()` is **stranded** — `rescueToVault` is ERC-20-only and there is no
  ETH sweep. Do not send ETH to the clone.
- **Init venue guards** (all `VenueMismatch()` unless noted): pool `tickSpacing` must equal the declared
  one; the pool's token set must be exactly the two declared legs; each Moonwell market's `underlying()`
  must be its declared leg; both leg-swap spacings must be non-zero. Plus `UnsupportedLeg()` if a leg is
  USDC (the unit of account) or the gauge's reward token (which `compound()` sells wholesale).

### Known gaps the operator must know (disclosed in PR #66)

- **No behavioural fork suite in CI.** The lifecycle *has* now been driven on a Base-fork vnet by hand —
  `deployIdle` (real mint), `compound` (real accrued AERO), `rerange`, `adjustLeverage`, `fulfillRedeem`
  and the full account lifecycle all executed as broadcast txs — but those are **manual harness drives,
  not automated coverage**. A Slipstream+Moonwell fork suite remains the named top follow-up before
  mainnet. Treat any pair *other than* the driven cbBTC/USDC asset-mode shape as unvalidated.
- **`underlying()` confirmed present** on the live Moonwell markets — initialization succeeds against
  mcbBTC / mUSDC on the fork, so the init guard does not brick. (Previously listed here as unverified.)
- **`_readCollateralDebt` reads un-accrued Moonwell state**, so the permissionless `deleverage` valve
  trips marginally late. Analysed and deliberately scoped out of PR #66 — tracked as **MOO-684**.

---

## G2. Venue migration — owner-staged pool/pair change

The fund can move to a **different Slipstream pool — including a different token pair — in place**:
same vault, same share token, same user accounts, no user action. Three new strategy entry points
(impls in `LeveragedAeroVenue.sol`, the third delegatecall library):

| Call | Who | What |
|---|---|---|
| `stageVenue(bytes32)` | **vault owner (multisig)** | Commit `keccak256(abi.encode(LeveragedAeroVenue.VenueParams))` for the destination venue; `0` clears. Inert until executed. |
| `flatten(minRewardUsdcOut, minIdleUsdcOut)` | proposer | `settleImpl`'s exact unwind (exit gauge+CL, repay both legs, redeem all collateral, sweep legs → USDC) but **no settle**: state stays `Executed`, USDC stays in the strategy, deposits/redeems keep working (flat NAV = idle USDC, oracle-free). **Calm-gated** before the burn, and it **sells the reward tranche** the unwind auto-claims (L9 oracle floor + your `minRewardUsdcOut`) so the flat NAV is the whole book. `minIdleUsdcOut` is your aggregate floor on the realised unwind. Idempotent. |
| `migrateVenue(VenueParams)` | proposer | Executes the staged rewrite. Requires byte-exact hash match AND a flat book (`tokenId == 0`, hedged bases 0, zero debt on both current leg markets). Re-runs full init-grade validation (incl. the **two-way** gauge↔pool binding `gauge.pool() == pool` *and* `pool.gauge() == gauge`, and a probe that the reward token has an Aerodrome v2 volatile USDC route) and rewrites the venue subset of storage. Moves **no funds**. **The skew triple is NOT in `VenueParams`** — `skewBps`/`minSkewBps`/`maxSkewBps` are venue-independent governance config and a migration never rewrites them; but the destination's `width` + `tickSpacing` ARE rewritten, and `checkRange`'s one-spacing-per-side floor couples the two, so `migrateVenue` re-validates the **live** skew against the destination and reverts `OutOfBounds` if that venue would starve either side. Pick a destination width/spacing the standing `skewBps` still fits, or the migration is rejected (nothing changes). |
| `redeploy(minLiquidity)` | proposer | Re-opens a **fresh** position from the flat book — `executeImpl`'s genesis sequence, entire idle balance, stored width/target-LTV, floored by your `minLiquidity`. **Clears any staged venue hash.** `deployIdle` can NOT do this (it `increaseLiquidity`s the stored tokenId, 0 when flat); conversely `redeploy` reverts `PositionAlreadyOpen` on a live book. |

**Runbook (per migration):**

1. Owner multisig: `stageVenue(keccak256(abi.encode(params)))` — encode the exact `VenueParams`
   struct (legs, markets, leg feeds, **the reward feed `aeroUsdFeed`**, pool, gauge, spacings, width
   band, LTV params; the non-migratable core — usdc/mUsdc/comptroller/npm/router/usdcFeed/
   sequencerFeed/oracle-calm params/fees — is read from live storage and is NOT in the struct).
   The reward feed travels WITH the gauge on purpose: the gauge determines `rewardToken()`, so
   pinning its feed separately would let a migration price a new reward token at AERO's price and
   mis-scale the L9 harvest floor.
2. Rebalancer: `flatten(minRewardUsdcOut, minIdleUsdcOut)` (oracle must be live — the leg sweeps and
   the reward sale are Chainlink-floored via `maxSlippageBps`, and the pool is calm-gated, so a
   shoved tick reverts rather than unwinding at a manipulated price). Size `minIdleUsdcOut` off the
   expected realised unwind; pass a nonzero `minRewardUsdcOut` whenever a tranche is pending.
3. Rebalancer: `migrateVenue(params)` — pure config rewrite; NAV is provably unchanged (flat NAV is
   the idle-USDC balance, which no venue field touches).
4. Rebalancer: `redeploy(minLiquidity)`; afterwards sweep old-leg unwind dust with
   `rescueToVault(oldLeg)` (former legs leave the deny-list at the rewrite; the NEW legs enter it).

**Trust split:** the owner alone picks the venue (hash-committed, byte-exact); the proposer alone
sequences execution and can neither deviate from the committed config nor move funds out of the
contract at any step.

**Residual owner trust (state it plainly).** The bound above is on the *proposer*, not on the owner.
A compromised owner multisig can stage a venue whose contracts it controls, and `redeploy` then mints
the position NFT into that venue's gauge. Validation narrows this but does not erase it: the gauge
must be attested by the pool (`pool.gauge()`) as well as attesting the pool itself, so a hostile gauge
alone no longer suffices — the attacker must control the *pool*, which in turn must satisfy the leg /
market / spacing / feed-decimal / width / LTV checks and expose a working reward route. It is still a
smaller step than `stageVenue`'s existing authority implies, and it is the same trust root that
already governs `rescueToVault`'s owner leg and the vault's fee configuration. Treat owner-key
compromise as fund-loss, not merely config-loss.

**Rollback:** before step 3, `redeploy(minLiquidity)` re-enters the *old* venue (nothing changed) and
**clears the staged hash as a side effect** — re-stage if the migration is still intended. A failed
step 3 reverts atomically; after step 3, stage the old venue's params and repeat.

**Pair constraints:** both legs need live borrowable Moonwell markets and Chainlink USD feeds on
Base; asset-mode (leg-B slot == USDC) is selected emergently by the config exactly as at init.
Pending withdraw-queue requests survive the whole sequence (share-denominated, fulfillable against
post-migration NAV).

## H. Testing rebalance operations on the vnet

Rebalance operations **are** testable on the Tenderly vnet — the fork is not frozen in the way it first
appears. But there is one misconception worth killing up front, because it wastes a day:

> **Moving the mock Chainlink feed does NOT move the position.** The feed and the pool are two
> independent price sources, and they drive different things. A feed-only move produces a fund whose
> *accounting* thinks the price moved while its *LP position* has not moved at all — and whose swaps then
> revert, because the oracle and the pool disagree.

### Which price drives what

| Driven by the **Chainlink feed** (the FreshFeed mock) | Driven by the **pool tick** (a real swap) |
| --- | --- |
| `nav()` and all USD valuation (`readUsd8`) | LP leg composition (how much cbBTC vs USDC the position holds) |
| Slippage floors / `minOut` sizing, `compound`'s `BelowOracleFloor` | Whether the position is in or out of range |
| The interest hedge's oracle-priced buy sizing | Where `rerange` anchors the new range (it brackets the pool tick, split by `skewBps`) |
| The staleness gate (`maxDelay`, currently 172800 s) | `calmGate` — **both** sides of it |
| Health / LTV ratios and the `deleverage` trigger | Realized swap price, and therefore actual slippage |

**`calmGate` never reads a Chainlink feed.** It is a pool-internal manipulation check comparing the pool's
spot tick against the pool's own TWAP:

```solidity
// LeveragedAeroValuation.calmGate
(, int24 spotTick,,,,) = ICLPool(pool).slot0();
// twapTick = mean tick over `twapWindow`, from pool.observe([twapWindow, 0])
if (|spotTick - twapTick| > calmDeviationTicks) revert CalmGateBreached();
```

So a large instantaneous swap breaches the gate *by design* until the TWAP catches up. That is the
mechanism protecting the fund from being rebalanced at a manipulated price — and on a vnet it means
**you must warp after moving the pool**, not just swap and immediately call.

### Live parameters (read them, don't copy them — they are per-clone)

| Field | `layout()` idx | Current staging value | Meaning |
| --- | --- | --- | --- |
| `calmDeviationTicks` | 14 | **500** | max \|spot − TWAP\|; 500 ticks ≈ **5.1 %** |
| `twapWindow` | 15 | **1800 s** | TWAP averaging window (30 min) |
| `tickSpacing` | 20 | 100 | LP pool spacing |
| `maxSlippageBps` | 24 | 100 | 1 % — also the oracle-floor tolerance on swaps |
| `posTickLower` / `posTickUpper` | 27 / 28 | −66300 / −63300 | current range (width 3000 ≈ 35 % span, centered — `skewBps` 5000) |
| width band | 44 / 45 | [200, 20000] | `rerange` width bounds (`OutOfBounds` outside) |
| `legBIsAsset` | 46 | `true` | asset mode: leg B **is** USDC |
| `skewBps` | 47 | **5000** | fraction of `width` placed BELOW spot; 5000 = centered (`OutOfBounds` outside `(0, 10000)`, outside the skew band below, or if either span < `tickSpacing`). **Appended after `legBIsAsset`, not next to the width band** — decode by name, not by eyeballing the group |
| skew band (`minSkewBps` / `maxSkewBps`) | 48 / 49 | [1000, 9000] (harness default) | init-immutable governance band on `skewBps`, checked at init **and** every `rerange` → the same `OutOfBounds` |
| `hedgedDebtA` / `hedgedDebtB` | 50 / 51 | — | hedged borrow principal per leg; **these moved from 48/49** when the skew band was inserted |
| `stagedVenueHash` | 52 | `0x00…0` | `keccak256(abi.encode(VenueParams))` the vault owner has staged as the migration destination; `0` == nothing staged. Appended **last**, so it shifts nothing |

> **The two skew-band fields were INSERTED after `skewBps`, not appended**, so every field below them
> shifted by two — `hedgedDebtA`/`hedgedDebtB` were 48/49 and are now 50/51. Anything decoding `layout()`
> positionally (a raw `abi.decode`, a hand-written tuple, a cached ABI) will read the wrong values against
> a clone built from this PR. Decode by **name** off a freshly generated ABI. A clone deployed *before*
> this PR — the current staging one included — has neither field at all; re-deploy the pooled layer to
> read them.

At the time of writing spot tick is **−64796** and the TWAP tick is **−64796** (identical — no recent
swaps), so the gate has full headroom. Note the range edges are ~1500 ticks away, i.e. it takes roughly a
**16 % price move to push the position out of range** — which is 3× `calmDeviationTicks`, so such a move
*cannot* be done in one swap and then immediately rebalanced. Warp first.

### The procedure for a price-move rebalance test

You need the **admin RPC** throughout (`tenderly_setCode`, `evm_increaseTime`, unlocked impersonation).
The public RPC cannot do any of this.

1. **Move the pool** — execute a real swap in the LP pool to push the tick where you want it. This is what
   changes the position's composition. Use `script/tenderly/TenderlySwapHelper.sol`: the pool calls back
   into the swapper, so it must be a funded persistent contract, which a `forge script` is not.
2. **Warp ≥ `twapWindow` (1800 s)** so the whole averaging window sits at the new tick and the TWAP
   converges on spot. Skip this and every priced path reverts `CalmGateBreached`.
3. **Move the feed to match** — deploy a new `FreshFeed` carrying the new answer and `tenderly_setCode` it
   over the **same** feed address. The answer is an `immutable`, so **there is no setter**; "moving" the
   price means replacing the code. If you skip this, the oracle still reports the old price, the router
   quote diverges from oracle fair by more than `maxSlippageBps`, and the oracle-floored swaps fail closed
   — but **with two different selectors**: `compound`'s AERO→USDC sell reverts `BelowOracleFloor` (its one
   and only raise site), while the `deleverage` / `adjustLeverage` lever-down residual swap has its min-out
   *raised* to the oracle floor and handed to the router, so it reverts inside **Slipstream's own
   `amountOutMinimum`** check. Same economic protection, different revert to alert on.
4. **Re-assert freshness** — `./script/tenderly/compound-cycle.sh check-feeds` after *every* warp. This is
   the gate that catches a non-FreshFeed instance before you waste a run.
5. **Now rebalance** — `rerange`, `adjustLeverage`, or `compound` as the scenario requires.

**All five steps are tooled**, and steps 1–4 collapse into a single command — see *Tooling: moving the
price* immediately below. You only have to think about the four steps when you deliberately want the pool
and the oracle to *disagree* (e.g. to prove a gate fires).

### Tooling: moving the price

`script/tenderly/compound-cycle.sh` wraps the whole procedure. Every subcommand reads its addresses and
its parameters (`twapWindow`, `calmDeviationTicks`, feed decimals, pool token ordering) **live** — nothing
is hardcoded, so they keep working when the instance rotates or the clone is re-deployed.

| Command | Writes? | What it does |
| --- | --- | --- |
| `calm` | no | Prints spot tick, TWAP tick, \|spot − TWAP\|, `calmDeviationTicks`, **PASS/FAIL**, and whether spot is inside the position range. The check to run constantly. |
| `move-pool <target-tick>` | 1 tx | Real swap through the LP pool to land on `<target-tick>`. |
| `move-feed <asset> <answer>` | 1 tx + `tenderly_setCode` | Replaces one FreshFeed with a new answer. `<asset>` ∈ `legA` \| `legB` \| `usdc` \| `aero`; `<answer>` is at **that feed's own `decimals()`**, read live (8 on every current feed). Runs `check-feeds` afterwards. |
| `move-price <target-tick>` | 2 tx + warp | **The one-shot.** `move-pool` → warp `twapWindow + 60` → `move-feed legA <price the new tick implies>` → `check-feeds` → `calm`. Leaves pool, TWAP and oracle in agreement. |

Notes that will save you a confused hour:

- **`move-pool` does not binary-search an input amount.** It sets `sqrtPriceLimitX96` to the sqrt price at
  the target tick and passes an unbounded exact input, so the pool walks its ticks and halts exactly at the
  limit. One tx, exact landing. Landing **±1 tick** off the target is normal (the limit is computed with
  real `sqrt()`, the pool reads it back through TickMath's fixed-point `getTickAtSqrtRatio`); a miss of
  *more* than a tick means the funding bound before the limit did, and the command says so explicitly.
- **Direction is not intuitive on this pool.** `pool.token0()` is **USDC** and `token1` is **cbBTC**, so the
  tick prices *USDC in cbBTC*: a **lower** tick means a **higher** cbBTC/USD price. The tool derives all of
  this from `pool.token0()` at runtime — but read its output rather than reasoning about the sign yourself.
- **`move-feed legB` also moves `usdc`** on an asset-mode clone: `legBIsAsset == true` means both slots point
  at the *same* USDC/USD aggregator. The command prints a `NOTE:` when the address it is about to overwrite
  is shared, so watch for it.
- The harness uses two fixed vnet-only addresses: `0x5ca1…0001` (the `TenderlySwapHelper`, installed by
  `tenderly_setCode`, storage-free so a code-only placement is sound) and `0x5ca1…0002` (a throwaway
  broadcaster, deliberately **not** the proposer, so pool swaps never look like rebalancer activity in the
  vnet tx history). Both are created on first use and reused afterwards.
- The swaps are real, so they pay real pool fees (`pool.fee()` is **246**, i.e. 0.0246 %). A move-and-return
  round trip does **not** land back on the exact starting tick; expect ~1 tick of residual and say so if you
  are handing the instance back to someone.

#### Tick ↔ percentage intuition

A tick is a fixed **1.0001×** step, so ticks compose multiplicatively — 500 ticks is 5.13 %, not 5.00 %.

| Ticks | Price move | What it means here |
| --- | --- | --- |
| 1 | 0.01 % | the landing tolerance of `move-pool` — noise |
| 100 | 1.005 % | one `tickSpacing` on this pool |
| **500** | **5.13 %** | `calmDeviationTicks` — the largest instantaneous move that still passes `calmGate` |
| 1000 | 10.5 % | needs a warp before anything priced will run |
| ~1500 | ~16.2 % | distance from spot to either range edge (−66300 / −63300 vs spot −64796) |
| 3000 | 35.0 % | the full width of the current position |

Because the range edges are ~3× `calmDeviationTicks` away, **an out-of-range scenario can never be swapped
and rebalanced in the same breath** — the warp in step 2 is mandatory, which is exactly what `move-price`
does for you.

#### Worked example — drive the position out of range and `rerange` it

```bash
cd script/tenderly
# LEVERAGED_AERO_ADMIN_RPC_URL must be set (admin RPC — NOT TENDERLY_VNET_RPC_URL)

./compound-cycle.sh calm                       # baseline: spot ≈ TWAP, "spot is in range"
./compound-cycle.sh snap before-rerange        # full state dump to diff against

# 1600 ticks BELOW spot = past the −66300 lower edge = cbBTC ~17 % MORE expensive.
# One command: swap the pool → warp 1860 s → re-price leg-A/USD → re-gate the feeds → calm.
./compound-cycle.sh move-price -66400
#   ... expect: ">> target REACHED", then "PASS" with 0 ticks of deviation (the TWAP has
#   ... converged), then "spot is OUT OF RANGE (single-sided; rerange to reposition (width + skew))"

# The rebalance under test. rerange brackets the NEW pool tick, split by skewBps; width must be a
# multiple of tickSpacing (100) and inside the clone's [minWidth, maxWidth] band, and skewBps must be
# inside [minSkewBps, maxSkewBps] — read all four from layout(). skewBps = 3500 => 35 % of the width
# below spot, 65 % above (the cbBTC/WETH backtest's skew): a deliberate lean that leaves more room for
# the price to recover upward.
cast send "$STRAT" 'rerange(uint24,uint16,uint256,uint256)' 3000 3500 0 0 \
  --from "$PROPOSER" --unlocked --gas-limit 14000000 --rpc-url "$LEVERAGED_AERO_ADMIN_RPC_URL"
# lowerSpan = 3000 × 3500/10000 = 1050, upperSpan = 1950, both bounds aligned DOWN to spacing 100:
#   tickLower = alignDown(-66400 - 1050) = -67500,  tickUpper = alignDown(-66400 + 1950) = -64500
# => realised WIDTH 3000, exactly as requested (both bounds moved down by the same residue), but a
# realised 1100/1900 split: the 50-tick residue came OUT of the upper span and went INTO the lower
# one. That direction is systematic — down-alignment can only ever move ticks upper -> lower, up to
# tickSpacing - 1 of them, and the market's tick at execution decides how many. Budget for it
# (upperSpan >= 2 x tickSpacing) rather than expecting the requested split.
# Pass 5000 instead of 3500 for the old centered behaviour.

./compound-cycle.sh calm                       # expect "spot is in range" again — new range, same spot
./compound-cycle.sh snap after-rerange         # principal conserved; one leg left idle (see §B)

./compound-cycle.sh move-price -64796          # put the instance back for the next person
```

Pass real `minLiq0`/`minLiq1` rather than `0 0` when you are testing the slippage guards; `0 0` is only
acceptable on a vnet where you are the only source of flow.

### The AERO harvest cycle (fully tooled today)

Independent of price, and the more common test. `gauge.earned()` is 0 on a fresh fork and **warping alone
accrues nothing**: a Base fork inherits `periodFinish` in the past with `rewardReserve == 0`, and no vnet
runs Aerodrome's weekly epoch flip. Re-arm it the production way:

```bash
./script/tenderly/compound-cycle.sh check-feeds       # gate — all 5 feeds fresh
./script/tenderly/compound-cycle.sh arm               # voter.distribute([gauge]) — PERMISSIONLESS
./script/tenderly/compound-cycle.sh warp-to-finish    # drain the epoch
./script/tenderly/compound-cycle.sh check-feeds       # re-gate after the warp
./script/tenderly/compound-cycle.sh quote             # oracle fair / floor / router quote → minUsdcOut
./script/tenderly/compound-cycle.sh compound <minUsdcOut> 0
```

**Emissions must be re-armed every cycle** — `earned` returns to 0 after each harvest.

### Failure modes and what they mean

| Revert | Cause | Fix |
| --- | --- | --- |
| `CalmGateBreached` | pool moved > `calmDeviationTicks` from its TWAP | warp ≥ `twapWindow`, then retry |
| `BelowOracleFloor` | **`compound` only** — its AERO→USDC sell is the single raise site; the realized fill came in under the AERO/USD oracle floor because pool and feed disagree by > `maxSlippageBps` | move the feed to match the pool (step 3) |
| Slipstream `amountOutMinimum` revert (no named selector) | the same pool/feed disagreement hitting a **lever-down residual swap** (`deleverage` / `adjustLeverage`): its min-out is raised to the oracle floor and enforced by the router, **not** by `BelowOracleFloor` | same fix — re-align the feed with the pool |
| `StaleOracle` | warped on a **non**-FreshFeed instance | wrong instance — check `check-feeds` |
| `OLD` from `pool.observe` | state sync is ON — observation ring re-hydrated from mainnet while `observationIndex` froze | not repairable; recreate the vnet with sync OFF |
| `ZeroMinOut` | `minUsdcOut == 0` | derive one from `quote` |
| `OutOfBounds` | width outside [200, 20000] or off the spacing grid; **or** `skewBps` outside `(0, 10000)`, outside the init-immutable `[minSkewBps, maxSkewBps]` band, or with a span shorter than one `tickSpacing` | pick a valid width / skew — read all four bounds off `layout()` (selector `0xb4120f14` — this is the renamed `WidthOutOfBounds`; the skew band raises the **same** error, there is no new selector) |
| `DegenerateRange` | asset-mode deploy/lever-up sized against a range the price has left — reachable by an extreme skew as well as by drift | `rerange` with a moderate skew **while spot is still inside the band**; once spot has left it, the rerange reopens one-sided and only `flatten` + `redeploy` restores a two-sided range |
| `NothingToRerange` | `rerange` on a position that collected **neither** leg — nothing to place a band around | Nothing to re-range; the book is empty. Check `layout().tokenId` and whether a redeem drained it |
| `TargetLtvExceedsMax` | target above `maxLtvBps` | lower the target |
| `InsufficientIdleForLeverUp` | lever-up needs idle USDC it doesn't have | deposit more, then retry — this is correct fail-closed behaviour |
| `NotProposer` | signed with the wrong key | sign as the **rebalancer**, not `MAMO_BACKEND` |

### Hard rules on the vnet

- **State sync must be OFF.** Creation-time-only, so it cannot be fixed after the fact. Green FreshFeed
  checks are **not** evidence sync is off — `tenderly_setCode` writes are vnet-local, so feed asserts pass
  on a broken instance. The reliable check is functional: `pool.observe([twapWindow, 0])` must not revert.
- **Never write to the feed addresses** except via the FreshFeed replacement recipe.
- **Never publish the admin RPC** — it is write-capable. 1Password only, never a committed file.
- **Don't `settleStrategy()` a shared instance.** Settling is a one-way door and will strand everyone
  else's deposit testing.

### Tooling coverage

`compound-cycle.sh` now covers the whole loop: emission arming, warping, quoting, compounding, the feed
gate (`check-feeds`), the calm-gate read (`calm`), the pool swap to a target tick (`move-pool`), the
FreshFeed redeploy at a new answer (`move-feed`), and the four-step composition (`move-price`). Nothing in
a price-move scenario needs to be driven by hand against the admin RPC any more.

What is still **not** wrapped, and is deliberate:

- **The strategy writes themselves** — `rerange`, `adjustLeverage`, `deployIdle`, `fulfillRedeem`. These are
  the thing under test and their arguments are a policy decision (width, target LTV, `minLiq`/`minOut`), so
  they stay explicit `cast send` calls signed as the proposer. `compound` is the one exception, because
  deriving a safe `minUsdcOut` needs the oracle-floor arithmetic that `quote` already does.
- **Time-dependent venue state.** Moonwell's price oracle is *not* a gap: it resolves the same aggregator
  addresses the FreshFeeds are code-replaced over, so `move-feed legA` moves the lending market's collateral
  valuation in lockstep — verified on staging by nudging leg A/USD by one unit at the 8th decimal and
  watching `ChainlinkOracle.getUnderlyingPrice(mcbBTC)` track it. Health and LTV therefore stay coherent
  with the fund's own math. What `move-price` does not simulate is anything that only *time* produces:
  Moonwell borrow-interest accrual, gauge emissions (use `arm` + `warp-to-finish`), or the third-party flow
  that would surround a real price move.

---

## Fund capacity cap (multisig procedure)

`LeveragedAeroVault.maxTotalAssets` caps the whole fund's NAV, in USDC (6dp). `0` == unlimited.
Owner-only, one transaction:

```
vault.setMaxTotalAssets(5_000_000e6)   // $5M capacity
vault.setMaxTotalAssets(0)             // rollback: unlimited
```

Denominated in the unit of account, so **set the dollar figure you mean** — no share conversion, and
none of the 12dp/6dp hazard the old per-account share cap carried. Read the live headroom with
`vault.remainingCapacity()` (USDC; `type(uint256).max` when the cap is disabled).

Three things to keep straight:

- **It is a real TVL ceiling.** Once the fund's NAV reaches it, EVERY deposit is refused — every
  account, and direct depositors too, because the check lives in the strategy's `deposit`, which is
  the one path all of them take. That is the difference from the per-account cap it replaced.
- **NAV moves on its own, so the ceiling is not a static gate.** The fund can drift *above* it on
  gains alone (closing deposits with nobody having deposited) and back below on a drawdown. Expect
  deposits to reopen and close without any owner action; that is inherent to a value-denominated
  capacity limit.
- **It gates deposits only.** Lowering it below the live book traps nobody — no withdrawal path
  consults it, so holders can always exit, and each exit frees that much capacity for others.

## Staging

> **The live staging instance runs the AUDITED build** (vault generation 3), redeployed 2026-08-18 from
> the audit-remediation branch: a `LeveragedAerodromeCLStrategy` clone bound to `LeveragedAeroVault`,
> deployed by `make tenderly-leveraged-aero-stack`, with the full lifecycle / rescue / fee-config surface
> documented above (`activateStrategy`, `settleStrategy`, `redeemSettled`, `setFeeConfig`), the fund
> capacity cap (`maxTotalAssets` / `remainingCapacity`), the per-cycle rerange skew and the any-pool init
> + per-leg swap spacings. Everything on this page — the `fulfillRedeem(uint256,uint256)` signature, the
> `OutOfBounds` / `NothingToRerange` selectors, `setProposer` rotation — matches the code that is live
> here. Sherwood is gone: no `SyndicateVault`, no governor, no proposal lifecycle.
>
> ⚠️ **`script/tenderly/leveraged-aero-vnet.json` is the source of truth**, not this table — a harness
> redeploy changes these addresses. Re-read it and
> [`docs/LEVERAGED_AERO_VNET_RUNBOOK.md`](../LEVERAGED_AERO_VNET_RUNBOOK.md) before wiring an environment,
> and read every risk/venue value off `layout()` on the clone you actually target.

| Field | Value | Config key |
|---|---|---|
| Network | Base fork (Tenderly Virtual TestNet), **custom** chainId `73578453` (parent Base `8453`) | `chainId` |
| RPC (public, read-only) | `https://virtual.base.eu.rpc.tenderly.co/b5ec5ea9-e5ea-4e06-a9a6-21310065d282` | `publicRpc` |
| Admin RPC (writes) | **1Password** (write-capable — never committed to this repo) | `adminRpc` |
| Strategy clone (the operator target) | `0x01BF606144a56AB2e992bd96E5E4BaFdf09287F1` — width 4000 / band [200, 20000], skew 5000 / band [1000, 9000] | `pooled.strategyClone` |
| Vault (`LeveragedAeroVault`, shares 12dp) | `0x8D2F111794992AEF0bD4733E2af3c0F800A11E59` | `pooled.vault` |
| Strategy template (clone source) | `0x92b37B73d51Ff44b5562Dd3e7563B5b45d1c2FB9` | `pooled.template` |
| **Proposer / agent** (`MAMO_REBALANCER`, **not** `MAMO_BACKEND`) | `0x73f6B456d063F78129113D42DBC315b9eEee8FAf` | `pooled.proposer` |
| LP pool (Slipstream, tickSpacing 100) | `0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1` — **twoleg WETH/cbBTC**, migrated 2026-08-21 from the asset-mode cbBTC/USDC pool. A `migrateVenue` does **not** update the manifest: read `layout()`. | `pooled.lpPool` |
| Seed (USDC, 6dp) | `100000000000` = 100,000 USDC | `pooled.seed` |
| Venue feeds | FreshFeed-mocked via `tenderly_setCode` — never stale, warping safe | `feeds.*` |

**Deliberate history — do not target these.** `0x168ac730AB0DA6FCDE8aA26e33eac4aE6c8CfB4B` is a retired
Sherwood-era clone, now `Settled`; it is kept on record only as a historical `Settled`-state reference and
its ABI/lifecycle is the *old* one.

Production addresses are published separately at deploy.

---

## Rebalancer checklist

- [ ] Sign every operator op with the strategy **proposer** key (`MAMO_REBALANCER`, `0x73f6…8FAf` on staging) — **never** the backend key (`MAMO_BACKEND`); confirm `strategy.proposer()` matches before wiring.
- [ ] Gate the whole operator loop on `state() == Executed`; `execute`/`settle` are `onlyVault` and belong to the vault owner's `activateStrategy` / `settleStrategy`, not to you.
- [ ] Periodically `deployIdle(amount, minLiquidity)` accumulated strategy-idle USDC; pass a real `minLiquidity`. `amount` is capped by idle alone — no leverage-derived ceiling to compute (§B) — so decide the **reserve you hold back**: it is the instant-redeem cover that keeps exits off the queue (§D), and in asset-mode the lever-up funding (§G).
- [ ] **Read `layout().legBIsAsset` first and branch on it** — asset-mode changes `deployIdle` sizing, makes lever-**up** consume idle USDC, and adds `InsufficientIdleForLeverUp` / `DegenerateRange` to the error set (§G). `rerange` is **not** on that list any more: it re-adds only what its own unwind collected and never reaches idle.
- [ ] `compound(minUsdcOut, minLiquidity)` on cadence with a **non-zero** `minUsdcOut`; expect it to defer (revert) on a stale AERO feed. **Do not predict the redeploy as `usdcOut − fee`** — `compound` first repays accrued borrow interest out of the harvest (§B), so the CL add is smaller by that amount; `MoonwellRepayFailed` is on that path.
- [ ] Track drift with `hedgedDebt()` vs. each market's `borrowBalanceStored` (§E) to size the harvest cadence, and confirm it returns to ~0 after a compound; remember the on-chain measure accrues first, so the off-chain `…Stored` read is a lower bound.
- [ ] Read the standing target with `targetLtvBps()`, not from the position's current LTV — the admin's `setTargetLtv` **persists** it, and `adjustLeverage` / the next `deployIdle`/`compound` all size at it.
- [ ] `rerange(width, skewBps, minLiq0, minLiq1)` when spot drifts out of range or the model picks a new width **or skew** — if spot has already **left** the band the reopen is **one-sided**: floor only the populated leg and pass `0` for the other, and expect the asset-mode deploy paths to stay `DegenerateRange`-closed until price enters the new band — `width` in raw ticks, tickSpacing-aligned, inside `[minWidth, maxWidth]`; `skewBps` in `(0, 10000)` (5000 = centered), inside the init-immutable `[minSkewBps, maxSkewBps]` band, with **both** spans ≥ one `tickSpacing` (else `OutOfBounds`, selector `0xb4120f14` — **re-point the backend error table off the retired `WidthOutOfBounds` `0x1f9f54af`**); expect calm-gate reverts on a shoved pool (retry when calm).
- [ ] Size `(width, skewBps)` for the **realised** geometry, not the requested one: down-alignment preserves width exactly but always moves up to `tickSpacing − 1` ticks from the upper span into the lower one, so keep `upperSpan ≥ 2 × tickSpacing`; and remember skew is inert at `width == 2 × tickSpacing` (needs `≥ 3 × tickSpacing` to do anything) (§B).
- [ ] In the two-borrowed-legs shape, budget for the **per-borrow ratchet** a skewed range creates against the range-blind 50/50 borrow: each `deployIdle`/`compound` strands a fresh, debt-funded slice of its own borrow (≈19 % at `skewBps` 3500, ≈33.5 % at 2000 *or* 8000) and the idle fraction grows with every compound until an op that resizes the book folds it back in (§B). Utilisation drag and borrow carry — not a hedge or health change.
- [ ] `adjustLeverage(targetBps, minLiq, minOut)` — **selector `0x9792419f`** — pass `targetLtvBps()` to hold the book at policy. To lever **down before `fulfillRedeem`** so the oracle-free unwind self-funds, pass a lower `targetBps` (capped at policy → `TargetLtvExceedsPolicy`, never stored) — no multisig step, in either direction. `lowerTargetLtv` no longer exists.
- [ ] Watch `RedeemRequested` → **simulate** `fulfillRedeem(id, 0)` statefully (`eth_simulateV1`; `tenderly_simulateBundle` is **vnet-only**) → passes: decode `RedeemFulfilled.assetsOut`, send with a tolerance → reverts: **classify first**, and only a cover-budget failure goes on the ladder (`min(currentLtv, targetLtvBps())` anchored, candidates strictly **below current LTV**, integer steps down to a floor, then escalate). Restore with `adjustLeverage(targetLtvBps(), …)` **once, after the queue drains**. Never quote from `previewRedeem` and never lower the requester's floor — §C "Sizing the fulfil".
- [ ] Treat `FULFILL_WINDOW = 2 days` as the hard SLA; alert before it; every `RedeemEmergency` is a missed SLA.
- [ ] Alert on **supply reaching zero**: a full redeem burns the position NFT (`tokenId == 0` while still `Executed`) and the book cannot be rebuilt — `rerange` silently mints nothing, `deployIdle` fails closed, `compound` no-ops, and the only way forward is `settleStrategy()` plus a **new vault** (§F).
- [ ] Run `deleverage(minOut)` proactively as health nears `minHealthBps`; remember it is permissionless (others will trigger it too).
- [ ] Monitor `nav()` reverts as a "priced paths degraded to async" signal — **not** a fulfill blocker (the queue is oracle-free); monitor `FeeCrystallizeDeferred`, whose realistic cause is a frozen vault (`depositsOpen == false`).
- [ ] Read the venue shape off `layout()` before wiring anything numeric — leg tokens, `cbBTCDecimals`/`wethDecimals`, `wethIsToken0`, the two leg-swap spacings, the width band and the stored `skewBps` (§G). Never hardcode the launch pair.
- [ ] Know the open gaps: the any-pool rewrites have **no behavioral fork coverage** yet, and the Moonwell `underlying()` init guard is unverified on the live markets (§G).
- [ ] Use `rescueToVault(token)` only for genuine stray tokens; it reverts on any position/accounting token and always pays the vault.
