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

The strategy inherits `BaseStrategy`, which stores an immutable-per-clone `_proposer` set at
`initialize(vault_, proposer_, data)` and never changed thereafter. The gate is a single modifier:

```solidity
// BaseStrategy
function proposer() public view returns (address);          // read the operator address
modifier onlyProposer() { if (msg.sender != _proposer) revert NotProposer(); _; }
```

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

Three authorization tiers appear on the strategy:

| Tier | Functions | Gate |
|---|---|---|
| Proposer-only | `deployIdle`, `compound`, `rerange`, `adjustLeverage`, `fulfillRedeem`, `updateParams` | `onlyProposer` (== `MAMO_REBALANCER`) |
| Permissionless | `deleverage` | anyone (by design — safety backstop) |
| Proposer **or** vault owner | `rescueToVault` | `proposer() \|\| Ownable(vault()).owner()` |
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
- **`rescueToVault` always pays the vault.** The recovery target is hardcoded to `vault()`, never
  caller-supplied, so neither the proposer nor the vault owner can exfiltrate; it only sweeps stray
  (non-position) tokens.
- **`updateParams(bytes)` is a no-op** here (`_updateParams` has an empty body — there are no tunable
  params). Listed for completeness; the agent never needs it.

---

## B. The operator surface — every proposer-callable function

All signatures below are exact. All revert `NotExecuted()` outside `Executed`, are `nonReentrant`, and
are `onlyProposer` except where noted. Risk caps live in the ERC-7201 `Layout` (read via `layout()`,
§E): `targetLtvBps`, `maxLtvBps`, `minHealthBps`, `maxSlippageBps`, `usdcCollateralFactorBps`. Two
compile-time constants bound the recovery valve: `DELEVERAGE_BUFFER_BPS = 500` (+5%) and, in the
strategy, `FULFILL_WINDOW = 2 days`.

### `deployIdle` — put idle USDC to work

```solidity
function deployIdle(uint256 amount, uint256 minLiquidity) external onlyProposer nonReentrant;
```

| | |
|---|---|
| `amount` | USDC (6dp) to deploy; must be ≤ the strategy's idle USDC balance, else `InsufficientIdle()`. |
| `minLiquidity` | Minimum CL liquidity the add must produce (slippage floor). |
| Position effect (two borrowed legs) | supply **all** of `amount` USDC → mUSDC → borrow both legs at **`targetLtvBps`** (50/50 by USD value) → wrap native ETH **iff** `wethDeliversNative` (§G) → `increaseLiquidity` into the existing CL NFT → restake in the gauge. |
| Position effect (asset-mode) | `LeveragedAeroValuation.assetModeSplit` solves the split closed-form against the **STORED** range: only `C < amount` is supplied as collateral, a **single** leg-A borrow is taken against `C` at `targetLtvBps`, and `U = amount − C` is held back as the LP's USDC side so the add lands at exactly the ratio the stored range needs. Net leg-A exposure stays 0 (LP leg == debt leg). |
| Guards | Two-borrowed-legs: borrow sized at `amount × targetLtvBps / 1e4`. Asset-mode: borrow sized at `C × targetLtvBps / 1e4` with `C` from the split — so the **effective** collateral is less than `amount` and a naive `amount × targetLtvBps` model will over-predict the borrow. Both: two-sided `maxSlippageBps` mins on the add plus the caller's `minLiquidity`; closes with `_assertHealthy()` (post-op LTV ≤ `maxLtvBps` **and** no Moonwell shortfall). |
| Errors | `InsufficientIdle`, `InsufficientLiquidity`, `MoonwellMintFailed`/`MoonwellBorrowFailed(errCode)`, `UnhealthyPosition(ltvBps, limitBps)`; **asset-mode also** `DegenerateRange()` — the split is sized against the STORED range (`posTickLower`/`posTickUpper`), so a range the price has already left is one-sided and fails closed. `rerange` recenters and unblocks it. |
| When to call | Deposits land as idle USDC (see §D) and earn nothing until deployed. Run periodically to sweep accumulated idle into the position, within leverage caps. |

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
| Interest re-hedge (what it spends) | Per borrowed leg, drift = `borrowBalanceCurrent(market) − hedgedDebt*` — the market is **accrued first** (`borrowBalanceCurrent`, not `…Stored`), so it sees interest that has not yet been capitalised. That drift is priced to USDC on the hardened leg + USDC feeds, bought on the Slipstream leg↔USDC pool with an oracle-floored min-out, and repaid to Moonwell. Leg A is served first; in the two-borrowed-legs shape leg B then gets `budget − spentA` (asset-mode has one drifting leg — leg B is the unit of account and never borrows, so its drift is structurally 0). |
| Interest re-hedge (bounds) | Hard-bounded by the harvest's own proceeds: it **never** touches stayers' idle USDC or the collateral. A budget too small for the whole drift hedges what it can and carries the remainder to the next harvest — it does **not** revert for insufficiency. Drift priced below 1 USDC unit is left to accumulate. Effect on the book: financing cost lands as **NAV drag** (less yield reinvested) instead of accumulating as unintended short leg exposure, and leverage dips slightly (the safe direction). |
| Fee interaction | Crystallizes management + HWM **performance** fees on the **pre-compound** NAV first (fail-closed on the price — a stale oracle reverts, so the harvest defers rather than mis-prices), so realized yield can't escape the performance fee. Then discharges `protocolFeeOwed` out of the swapped USDC before the hedge and the redeploy. |
| Guards | Effective swap floor = `max(minUsdcOut, oracleFloor)` where `oracleFloor = aeroBal × AERO/USD(8dp) / 1e20 × (1 − maxSlippageBps)`, post-checked on the measured fill → `BelowOracleFloor()`. The hedge's USDC→leg buy is separately floored at the oracle-implied leg amount haircut by `maxSlippageBps`. Redeploy runs `_assertHealthy()`. |
| Errors | `ZeroMinOut`, `BelowOracleFloor`, `UnhealthyPosition`; **`MoonwellRepayFailed(errCode)` from the interest re-hedge**; `MoonwellMintFailed`/`MoonwellBorrowFailed(errCode)`, `InsufficientLiquidity` and (asset-mode) `DegenerateRange()` from the redeploy. A stale/mismatched feed fail-closes the whole call — the AERO feed at the swap floor, and the leg + USDC feeds at the hedge (`compound` already fail-closes on those via the pre-compound `nav()`, so the hedge widens no oracle exposure). |
| When to call | On a yield/gas cadence. A stale AERO feed intentionally blocks it — defer and retry. Use `hedgedDebt()` vs. the markets' `borrowBalanceStored` (§E) to see how much drift a harvest will have to buy back, and to verify it went to ~0 afterwards. |

### `rerange` — re-center and re-width the CL range (no swap)

```solidity
function rerange(uint24 width, uint256 minLiq0, uint256 minLiq1) external onlyProposer nonReentrant;
```

The 3-arg form (per-cycle width) is the in-repo signature — `src/leveraged-aero/LeveragedAerodromeCLStrategy.sol`
is the authority for it; there is no older 2-arg variant to reconcile against any more.

| | |
|---|---|
| `width` | New position width in **raw ticks** (must be a multiple of `tickSpacing`), validated strategy-side against the init-immutable `[minWidth, maxWidth]` band **before** the venue delegatecall → `WidthOutOfBounds()` (selector `0x1f9f54af`, deliberately matching the Mamo backend's rebalance-param error). The width is **persisted** — subsequent range math (and the genesis mint path) reads the stored value; only `rerange` moves it, the band never moves after init. `layout()` exposes `width` / `minWidth` / `maxWidth` for the rebalancer to read on-chain — always read them off the clone you actually point at (the current staging clone was init'd width **4000**, band **[200, 20000]**). |
| `minLiq0` / `minLiq1` | Minimum **token0** / **token1** the re-add must consume (two-sided slippage guard) → `InsufficientLiquidity()`. `token0`/`token1` are **pool ordering**, derived at init from `pool.token0()` and exposed as `layout().wethIsToken0` — do not assume which leg is which (see §G). |
| Position effect | **Calm-gate runs FIRST** (`LeveragedAeroValuation._calmGate`) so a recenter can never execute at a manipulated tick → remove 100% liquidity + collect → mint a **new** CL NFT spanning `width/2` raw ticks each side of the current tick → restake. The **old NFT is left empty** (Slipstream ticks are immutable; the stale NFT is harmless dust). |
| What happens to principal | **No swap → principal conserved** (IL is realized only on a true exit). The collected ratio can't match the new range, so a remainder of **one** leg is left idle in the strategy — `nav()` prices it, so the recenter is NAV-neutral and the remainder stays redeployable. Debt + collateral untouched (health preserved). |
| Asset-mode difference | The re-add offers the mint the strategy's **whole balance of each leg slot as `amountDesired`** — and in asset-mode the leg-B slot **is USDC** (`layout().cbBTC == layout().usdc`). So the amount of USDC the mint consumes is whatever the new range needs to pair with the collected leg A, which can be **more than the unwind itself collected**, drawing the difference from idle USDC. That is value-conserving (idle → LP, `nav()` unchanged) but it shrinks the redeem cover budget, the same operator consequence as an asset-mode lever-up. Conversely the leftover remainder is plain USDC rather than a borrowed leg. Size reranges against available idle when the clone is asset-mode. |
| Fee interaction | **No crystallization** — supply and NAV are unchanged; the streaming fee simply defers to the next crystallize point and the HWM is unaffected. |
| Guards | Calm-gate; two-sided `maxSlippageBps` mins + caller `minLiq0/minLiq1`; closing `_assertHealthy()`. |
| Errors | `WidthOutOfBounds` (out-of-band or misaligned `width`), calm-gate reverts (`TwapDeviation`/`StaleOracle` family), `InsufficientLiquidity`, `UnhealthyPosition`. |
| When to call | When spot has drifted out of the active range, or when the rebalance model chooses a new width for the cycle. Width selection policy is the rebalancer's (`RebalanceParams.width` in the backend spec); the chain only enforces the band. |

### `adjustLeverage` — move LTV toward a target

```solidity
function adjustLeverage(uint16 targetLtvBps_, uint256 minLiq, uint256 minOut)
    external onlyProposer nonReentrant;
```

| | |
|---|---|
| `targetLtvBps_` | Desired LTV in bps. **Checked at the entrypoint**: `targetLtvBps_ > maxLtvBps` reverts `TargetLtvExceedsMax()`. |
| `minLiq` | Minimum CL liquidity on a lever-**UP** add. |
| `minOut` | Minimum USDC out of a lever-**DOWN** residual rebalancing swap. |
| Position effect (both shapes) | Collateral untouched; LTV moves on the **debt** side. `targetDebt = targetLtvBps_ × collateralUsdc / 1e4`. Lever **down**: unwind the matching CL fraction and repay, per-leg residual rebalanced through USDC (`minOut`) — unchanged in asset-mode, where the leg-B residual **is** USDC and flows straight into the leg-A cover. Closes with `_assertHealthy()`. |
| Lever **up** — two borrowed legs | Borrow the delta 50/50 by USD across both legs and LP them against each other. **Self-funding**: the pair *is* the two borrows, so no idle USDC is consumed. |
| Lever **up** — asset-mode | Borrows **only leg A** and pairs it with USDC **drawn from the strategy's idle balance**, sized closed-form (`assetModeLeverUpPair`) so the LP's leg-A amount equals the added leg-A debt — that is what preserves the delta-hedge (swapping part of the borrow to USDC would leave the book net short). **Operator consequence: an asset-mode lever-up CONSUMES idle USDC.** Value-conserving (a NAV component moving idle → LP, not a loss) but it shrinks the redeem cover budget until the next deposit. **Size lever-ups against available idle**; an under-funded one reverts `InsufficientIdleForLeverUp(needed, available)` and changes nothing — deliberately not a partial fill and not a silent cap. |
| `targetLtvBps_` is **persisted** | The value is stored as the fund's standing target, so `execute` / `deployIdle` / `compound` size their **next** borrow at it. This holds even when neither branch runs (`targetDebt == debtUsdc`) — the retarget still takes effect, exactly like `rerange`-on-a-flat-book persisting `width`. Read it back with `targetLtvBps()` or `layout().targetLtvBps` (§E). |
| Fee interaction | **No crystallization** (like `rerange`): no supply change, no PnL realized; streaming fee defers, HWM unaffected. |
| Errors | `TargetLtvExceedsMax`, `InsufficientLiquidity`, `MoonwellRepayFailed`/`MoonwellBorrowFailed`, `UnhealthyPosition`; **asset-mode lever-up also** `InsufficientIdleForLeverUp(uint256 needed, uint256 available)` and `DegenerateRange()` (the pairing is sized against the STORED range — a one-sided one fails closed; `rerange` unblocks it). `InsufficientIdleForLeverUp` is raised inside `LeveragedAeroValuation` but **re-declared on the strategy** (`LeveragedAerodromeCLStrategy.sol:93`, same selector) so it is on the clone's own ABI for the rebalancer / frontend — decode it off the strategy ABI, no library ABI needed. |
| When to call | To hold the fund near `targetLtvBps`, and — critically — **before `fulfillRedeem`** to lever **down** so the oracle-free proportional unwind self-funds its IL/debt shortfall (see §C). In asset-mode note the two directions are asymmetric on idle: lever **down** frees USDC, lever **up** spends it. |

### `fulfillRedeem` — drain the withdraw queue

```solidity
function fulfillRedeem(uint256 id) external onlyProposer nonReentrant;
```

Runs the **oracle-free proportional unwind** for request `id`, paying `request.owner` (the Mamo
account that escrowed the shares) net of its pro-rata protocol-fee skim, enforcing the **requester's**
stored `minAssetsOut`, then burning the escrowed shares. See §C for the full loop.

| | |
|---|---|
| Preconditions | `state() == Executed`; request not `settled` (else `RequestSettled()`). |
| Guards | Enforces the requester's `minAssetsOut` → `InsufficientAssetsOut()`; rejects a burn-for-zero → `ZeroAssetsOut()`. |
| Fee interaction | Best-effort crystallize (never blocks the exit): on an oracle outage `navPre = 0`, so the price-free **management** fee still accrues while the **performance** fee defers; a fee-mint revert emits `FeeCrystallizeDeferred(2, navPre)` and proceeds. |
| Events | `RedeemFulfilled(id, owner, assetsOut)`. |
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
`CannotRescuePositionToken()` for any position/accounting token: `usdc`, leg B, leg A, `mUsdc`, `mCbBTC`,
`mWeth`, and the gauge reward token (read live from the gauge so a sweep can't bypass `compound()`). The
position NFT is never swept (no ERC-721 path), and **native ETH is not sweepable at all** (§G).

This is a two-hop recovery: the strategy can only push to the vault, and the vault owner then moves it out
with the vault's own `rescueERC20(token, to, amount)` — which can take any non-asset token at any time, but
refuses the **asset** (USDC) while `totalSupply() > 0` (`"LAV: asset reserved for redemptions"`), so a
settled redemption pot can never be pulled out from under holders.

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
| `RedeemRequested(uint256 indexed id, address indexed owner, uint256 shares)` | request escrowed — **the keeper trigger** |
| `RedeemFulfilled(uint256 indexed id, address indexed owner, uint256 assetsOut)` | agent fulfilled; USDC paid to the account |
| `RedeemCancelled(uint256 indexed id, address indexed owner, uint256 shares)` | request owner cancelled (any state); escrow returned |
| `RedeemEmergency(uint256 indexed id, address indexed owner, uint256 assetsOut)` | deadman self-fulfill after the window — **a missed SLA** |

### The 2-day deadman — `FULFILL_WINDOW`

`FULFILL_WINDOW = 2 days`. If the agent does not `fulfillRedeem` within that window, the request owner
can trustlessly self-service via `emergencyRedeem(id, minAssetsOut)` (owner-gated; reverts
`FulfillWindowOpen()` before the window elapses). At the account layer that surfaces as
`WithdrawEmergency`/`RedeemEmergency`. **Every emergency exit is a missed SLA** and strips the agent
from the loop. Treat 2 days as the hard fulfillment SLA; alert well before it.

**Drain the queue before settlement.** `fulfillRedeem` and `emergencyRedeem` both require `Executed`, so any
request still outstanding when the vault owner calls `settleStrategy()` becomes unfulfillable — its owner
must `cancelRedeem(id)` (callable in **any** state) to get the shares back and then exit via the vault's
`redeemSettled`. If a settlement is planned, clear the queue first and flag any request you can't fulfill.

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

Because a levered position tends to run a debt/IL shortfall against the collected legs, calling
`adjustLeverage` to lever **down** first shrinks the debt the unwind must repay, so the proportional
unwind self-funds cleanly instead of eating deep into collateral. This is the standard pre-fulfill
step for anything but small requests.

### If `fulfillRedeem` reverts `InsufficientAssetsOut`

`fulfillRedeem` enforces the **requester's** stored `minAssetsOut` against the net payout. If the
position can't currently produce that floor (adverse IL / price move, or too much of the payout eaten
by shortfall cover), the fulfill reverts `InsufficientAssetsOut()`. Reason from the code: the escrowed
shares **carry no frozen price** — they keep bearing PnL until fulfilled — so the agent's options are
(1) `adjustLeverage` down further to reduce the unwind's shortfall and raise the achievable net, then
retry, or (2) **wait** for the position to recover and retry. Do **not** try to lower the floor — it is
the requester's, not the agent's. A stuck request self-resolves at the 2-day deadman (the account owner
can also `cancelRedeem` to reclaim the shares).

```mermaid
sequenceDiagram
    participant A as Mamo account
    participant K as Agent keeper (proposer)
    participant S as Strategy (LeveragedAerodromeCL)

    A->>S: requestRedeem(shares, minAssetsOut)
    S-->>K: RedeemRequested(id, account, shares)
    Note over K: read redeemRequest(id); assess if unwind self-funds
    opt shortfall likely (non-trivial size)
        K->>S: adjustLeverage(lowerTarget, minLiq, minOut)   (lever DOWN)
    end
    K->>S: fulfillRedeem(id)
    alt payout ≥ requester minAssetsOut
        S-->>A: pays USDC to the account (idle) + RedeemFulfilled(id, account, assetsOut)
    else InsufficientAssetsOut
        Note over K: deleverage/adjust more, or wait, then retry (never lower the floor)
    end
    Note over K: escalation — if unfulfilled at requestedAt + 2 days, the account can emergencyRedeem (missed SLA)
```

---

## D. Deposit handling

Deposits from the Mamo accounts' `deposit`/`depositIdle` calls arrive as **idle USDC on the strategy**
and earn nothing until deployed. Key facts for the agent:

- `deposit(assets, minShares)` on the strategy mints shares priced against `nav()` but leaves the USDC
  idle — the comment is explicit: "Deposited USDC sits idle until a proposer calls `deployIdle()`."
- **`nav()` counts strategy-held idle USDC but NOT vault float** (verified: the flat-book branch reads
  `IERC20(usdc).balanceOf(address(this))` — the strategy's own balance — and the docstring states vault
  float is excluded to preserve deposit/redeem symmetry). So idle-but-undeployed deposits are in NAV and
  correctly priced.
- The agent's job is to **periodically `deployIdle`** accumulated idle USDC within the leverage caps
  (`targetLtvBps`, bounded by `maxLtvBps` via the closing health assert).
- **Do not confuse this with the account-level `depositIdle` nudge.** That is a *separate* surface on the
  per-user `MamoLeveragedAeroStrategy` account (sibling backend doc), gated to the owner or registry
  backend member-0, and it moves a user's plain-transferred USDC into the fund. This section is about
  **strategy-level** idle USDC — the pooled deposits sitting on the strategy clone — deployed with the
  **proposer** key via `deployIdle`.

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
```

- **`targetLtvBps()`** is the fund's **standing** target — set at init and re-set by every `adjustLeverage`
  — and it is what `execute` / `deployIdle` / `compound` size their borrow at. Read it **before** deciding
  whether to retarget; do not infer it from the position's current LTV, which drifts with price.
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
- **`previewRedeem(shares)`** returns `(assetsOut, fastOk)`; `assetsOut` is the advisory oracle-priced
  fast-path payout and `fastOk` whether the fast path would currently price **and** clear the LTV gate.
  Both are advisory — the manager's on-chain gate is authoritative. Returns `(0, false)` on an oracle
  outage. Useful for dashboards and for deciding whether a given size needs a deleverage before fulfill.
- **`layout()`** (memory-returnable `LayoutView`, minus the `redeemRequests` mapping) is the single read
  for **risk caps** (`targetLtvBps`, `maxLtvBps`, `minHealthBps`, `maxSlippageBps`,
  `usdcCollateralFactorBps`), **fees** (`managementFeeBps`, `performanceFeeBps`, `feeRecipient`,
  `hwmPerShare`, `lastFeeAccrualTimestamp`, `protocolFeeOwed`), **venue/feed addresses** (pool, npm,
  gauge, swapRouter, comptroller, the Moonwell markets, the Chainlink feeds incl. `aeroUsdFeed`,
  `sequencerFeed`), **oracle config** (`maxDelay`, `gracePeriod`, `calmDeviationTicks`, `twapWindow`,
  `tickSpacing`), **position state** (`tokenId`, `posTickLower`, `posTickUpper`, `nextRedeemRequestId`),
  the **width band** (`width`, `minWidth`, `maxWidth`), the **hedged-debt basis** (`hedgedDebtA`,
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
  `RedeemRequested(id, owner, shares)` — the withdraw-request trigger that drives the entire SLA loop —
  plus the rest of the queue set (`RedeemFulfilled`/`RedeemCancelled`/`RedeemEmergency`) and
  `FeeCrystallizeDeferred`. Nothing needs to be added for the keeper's core watch-and-fulfill duty.
- **Position-management ops emit nothing** — `deployIdle`, `compound`, `rerange`, `adjustLeverage`, and
  `deleverage` are event-silent from both the strategy and the manager (verified: the manager emits no
  events at all; the strategy declares only the five below). Until that changes, dashboards key off
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

---

## F. Hard operational constraints

- **Oracle staleness / sequencer.** All priced paths (`nav`, fast `redeem`, `compound`, `_assertHealthy`,
  `deleverage`) read hardened Chainlink with `maxDelay` staleness, `gracePeriod` sequencer-restart grace,
  and a calm-gate. A stale feed or a down sequencer **fail-closes** — the op reverts. This is intended
  posture: defer the harvest / re-range / deleverage and rely on the oracle-free async queue for exits.
- **Calm gate.** Every mint/add path runs the calm-gate (`|spotTick − twapTick| ≤ calmDeviationTicks` over
  `twapWindow`) before the pool is touched, as does NAV pricing — so the agent can never recenter, add or
  price at a manipulated tick. A shoved pool blocks `rerange`, `deployIdle`, `compound`'s redeploy and a
  lever-**up**; retry once calm. **Where in the op the gate fires is not uniform**, and an operator reading
  a reverted trace should expect it: `rerange` gates first, before any venue call; `execute` gates after
  `enterMarkets` but before the supply/borrow/mint; `deployIdle` and lever-**up** reach the gate inside the
  CL add, i.e. *after* the Moonwell supply/borrow already executed in that transaction. In all cases the
  breach reverts the **whole** transaction atomically — there is no state to unwind by hand and no partial
  deploy to reconcile — but a shoved-tick `deployIdle` trace will show a Moonwell borrow before the
  `CalmGateBreached` revert. That is expected, not a partial failure.
- **Per-op slippage bounds.** Every value-moving op takes a caller `min*` floor **and** is additionally
  bounded by the always-on `maxSlippageBps` (∈ (0, 1000] = ≤10%, set at init). `compound` is further
  floored by the AERO/USD oracle (`BelowOracleFloor`). Pass **tight, freshly-quoted** floors; `0` is not
  legal for `compound.minUsdcOut` (`ZeroMinOut`).
- **Swap-route `tickSpacing` is now configured, not hardcoded (was audit item 10).** The three
  `int24(100)` literals are gone: the auxiliary USDC↔leg swap helpers (`_swapUsdcExactIn`,
  `_sweepLegToUsdc`, `_redeemCoverShortfall`) resolve the route spacing per leg from the init params
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
  sandwichable.)
- **Fee-path asymmetry (audit item 7).** Crystallize is **best-effort** on user-exit paths (defers +
  emits `FeeCrystallizeDeferred`) but **hard-reverts** on `compound`/`settle`/the redeem skim. A persistent
  `FeeCrystallizeDeferred` on deposits/redeems while `compound` reverts points at a **frozen vault**
  (`depositsOpen == false` → the fee-share mint reverts `"LAV: deposits closed"`) — an ops issue to clear.
  Note the vanilla vault has **no pause and no depositor whitelist**; that one flag is the whole gate.
- **`deleverage` accepted residual (audit item 9).** Our-feed staleness can block `deleverage` in a window
  where Moonwell's own oracle is fresh enough to liquidate; documented and accepted. Monitor Moonwell
  account liquidity independently.

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
  | `rerange` | remainder left idle is a borrowed leg | may **draw idle USDC** into the add; the remainder left idle is USDC |
  | Range-sensitivity | none on the deploy path | `deployIdle` / lever-up size against the **STORED** range → `DegenerateRange()` when it is one-sided; `rerange` first |

  The operator rule of thumb for asset-mode: **idle USDC is no longer just a redeem buffer, it is an input
  to `deployIdle`, `adjustLeverage` (up) and `rerange`.** Track it as a budget, and prefer a `rerange` to
  recenter before any op that sizes against the stored range.
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
| `flatten()` | proposer | `settleImpl`'s exact unwind (exit gauge+CL, repay both legs, redeem all collateral, sweep legs → USDC) but **no settle**: state stays `Executed`, USDC stays in the strategy, deposits/redeems keep working (flat NAV = idle USDC, oracle-free). Idempotent. |
| `migrateVenue(VenueParams)` | proposer | Executes the staged rewrite. Requires byte-exact hash match AND a flat book (`tokenId == 0`, hedged bases 0, zero debt on both current leg markets). Re-runs full init-grade validation (incl. a `gauge.pool() == pool` binding check) and rewrites the venue subset of storage. Moves **no funds**. |
| `redeploy()` | proposer | Re-opens a **fresh** position from the flat book — `executeImpl`'s genesis sequence, entire idle balance, stored width/target-LTV. `deployIdle` can NOT do this (it `increaseLiquidity`s the stored tokenId, 0 when flat); conversely `redeploy` reverts `PositionAlreadyOpen` on a live book. |

**Runbook (per migration):**

1. Owner multisig: `stageVenue(keccak256(abi.encode(params)))` — encode the exact `VenueParams`
   struct (legs, markets, feeds, pool, gauge, spacings, width band, LTV params; the non-migratable
   core — usdc/mUsdc/comptroller/npm/router/usdcFeed/sequencerFeed/aeroUsdFeed/oracle-calm
   params/fees — is read from live storage and is NOT in the struct).
2. Rebalancer: `flatten()` (oracle must be live — the leg sweeps are Chainlink-floored via
   `maxSlippageBps`).
3. Rebalancer: `migrateVenue(params)` — pure config rewrite; NAV is provably unchanged (flat NAV is
   the idle-USDC balance, which no venue field touches).
4. Rebalancer: `redeploy()`; afterwards sweep old-leg unwind dust with `rescueToVault(oldLeg)`
   (former legs leave the deny-list at the rewrite; the NEW legs enter it).

**Trust split:** the owner alone picks the venue (hash-committed, byte-exact); the proposer alone
sequences execution and can neither deviate from the committed config nor move funds out of the
contract at any step. **Rollback:** before step 3, `redeploy()` re-enters the *old* venue (nothing
changed) and the owner can `stageVenue(0)`; a failed step 3 reverts atomically; after step 3, stage
the old venue's params and repeat.

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
| Slippage floors / `minOut` sizing, `BelowOracleFloor` | Whether the position is in or out of range |
| The interest hedge's oracle-priced buy sizing | Where `rerange` re-centres (it centres on the pool tick) |
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
| `posTickLower` / `posTickUpper` | 27 / 28 | −66300 / −63300 | current range (width 3000 ≈ 35 % span) |
| width band | 44 / 45 | [200, 20000] | `rerange` width bounds (`WidthOutOfBounds` outside) |
| `legBIsAsset` | 46 | `true` | asset mode: leg B **is** USDC |

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
   quote diverges from oracle fair by more than `maxSlippageBps`, and swaps revert `BelowOracleFloor`.
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
#   ... converged), then "spot is OUT OF RANGE (single-sided; rerange to re-centre)"

# The rebalance under test. rerange re-centres on the NEW pool tick; width must be a multiple
# of tickSpacing (100) and inside the clone's [minWidth, maxWidth] band — read them from layout().
cast send "$STRAT" 'rerange(uint24,uint256,uint256)' 3000 0 0 \
  --from "$PROPOSER" --unlocked --gas-limit 14000000 --rpc-url "$LEVERAGED_AERO_ADMIN_RPC_URL"

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
| `BelowOracleFloor` | pool and feed disagree by > `maxSlippageBps` | move the feed to match the pool (step 3) |
| `StaleOracle` | warped on a **non**-FreshFeed instance | wrong instance — check `check-feeds` |
| `OLD` from `pool.observe` | state sync is ON — observation ring re-hydrated from mainnet while `observationIndex` froze | not repairable; recreate the vnet with sync OFF |
| `ZeroMinOut` | `minUsdcOut == 0` | derive one from `quote` |
| `WidthOutOfBounds` | width outside [200, 20000] or off the spacing grid | pick a valid width |
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

## Staging

> **The live staging instance runs the current in-repo stack** (vault generation 2): a
> `LeveragedAerodromeCLStrategy` clone bound to `LeveragedAeroVault`, deployed by
> `make tenderly-leveraged-aero-stack`, with the full lifecycle / rescue / fee-config surface documented
> above (`activateStrategy`, `settleStrategy`, `redeemSettled`, `setFeeConfig`) and the any-pool init +
> per-leg swap spacings. Sherwood is gone — no `SyndicateVault`, no governor, no proposal lifecycle.
>
> ⚠️ **`script/tenderly/leveraged-aero-vnet.json` is the source of truth**, not this table — a harness
> redeploy changes these addresses. Re-read it and
> [`docs/LEVERAGED_AERO_VNET_RUNBOOK.md`](../LEVERAGED_AERO_VNET_RUNBOOK.md) before wiring an environment,
> and read every risk/venue value off `layout()` on the clone you actually target.

| Field | Value | Config key |
|---|---|---|
| Network | Base fork (Tenderly Virtual TestNet), chainId `8453` | `chainId` |
| RPC (public, read-only) | `https://virtual.base.eu.rpc.tenderly.co/70a4990f-6686-4536-8237-ad9103acd11b` | `publicRpc` |
| Admin RPC (writes) | **1Password** (write-capable — never committed to this repo) | `adminRpc` |
| Strategy clone (the operator target) | `0xA26557fA6823881327fca5b8C4eD5857997A49da` — width 4000 / band [200, 20000] | `pooled.strategyClone` |
| Vault (`LeveragedAeroVault`, shares 12dp) | `0x8343b35617326A2B416e17388e1BdF10d5Fd22D7` | `pooled.vault` |
| Strategy template (clone source) | `0xafcA85Df8e058A7a755889884d87026e8e118943` | `pooled.template` |
| **Proposer / agent** (`MAMO_REBALANCER`, **not** `MAMO_BACKEND`) | `0x73f6B456d063F78129113D42DBC315b9eEee8FAf` | `pooled.proposer` |
| LP pool (Slipstream, tickSpacing 100) | `0x4e962BB3889Bf030368F56810A9c96B83CB3E778` | `pooled.lpPool` |
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
- [ ] Periodically `deployIdle(amount, minLiquidity)` accumulated strategy-idle USDC within leverage caps; pass a real `minLiquidity`.
- [ ] **Read `layout().legBIsAsset` first and branch on it** — asset-mode changes `deployIdle` sizing, makes lever-**up** consume idle USDC, lets `rerange` draw on idle, and adds `InsufficientIdleForLeverUp` / `DegenerateRange` to the error set (§G).
- [ ] `compound(minUsdcOut, minLiquidity)` on cadence with a **non-zero** `minUsdcOut`; expect it to defer (revert) on a stale AERO feed. **Do not predict the redeploy as `usdcOut − fee`** — `compound` first repays accrued borrow interest out of the harvest (§B), so the CL add is smaller by that amount; `MoonwellRepayFailed` is on that path.
- [ ] Track drift with `hedgedDebt()` vs. each market's `borrowBalanceStored` (§E) to size the harvest cadence, and confirm it returns to ~0 after a compound; remember the on-chain measure accrues first, so the off-chain `…Stored` read is a lower bound.
- [ ] Read the standing target with `targetLtvBps()`, not from the position's current LTV — `adjustLeverage` **persists** it and the next `deployIdle`/`compound` borrows at it.
- [ ] `rerange(width, minLiq0, minLiq1)` when spot drifts out of range or the model picks a new width — `width` in raw ticks, tickSpacing-aligned, inside `[minWidth, maxWidth]` (else `WidthOutOfBounds`); expect calm-gate reverts on a shoved pool (retry when calm).
- [ ] `adjustLeverage(target, minLiq, minOut)` to hold near `targetLtvBps` — and to lever **down before `fulfillRedeem`** so the oracle-free unwind self-funds.
- [ ] Watch `RedeemRequested` → assess self-funding via `redeemRequest(id)`/`previewRedeem` → (deleverage if needed) → `fulfillRedeem(id)`; on `InsufficientAssetsOut`, deleverage more or wait — never lower the requester's floor.
- [ ] Treat `FULFILL_WINDOW = 2 days` as the hard SLA; alert before it; every `RedeemEmergency` is a missed SLA.
- [ ] Run `deleverage(minOut)` proactively as health nears `minHealthBps`; remember it is permissionless (others will trigger it too).
- [ ] Monitor `nav()` reverts as a "priced paths degraded to async" signal — **not** a fulfill blocker (the queue is oracle-free); monitor `FeeCrystallizeDeferred`, whose realistic cause is a frozen vault (`depositsOpen == false`).
- [ ] Read the venue shape off `layout()` before wiring anything numeric — leg tokens, `cbBTCDecimals`/`wethDecimals`, `wethIsToken0`, the two leg-swap spacings, the width band (§G). Never hardcode the launch pair.
- [ ] Know the open gaps: the any-pool rewrites have **no behavioral fork coverage** yet, and the Moonwell `underlying()` init guard is unverified on the live markets (§G).
- [ ] Use `rescueToVault(token)` only for genuine stray tokens; it reverts on any position/accounting token and always pays the vault.
