# Leveraged Aero — Rebalancer (fund-ops) integration guide

## The product — Leveraged Aerodrome LP Fund (Sherwood × Mamo)

Leveraged Aerodrome LP fund. Users deposit USDC; the Mamo agent runs a leveraged AERO-farming
position that earns through emissions. Custody and execution are deliberately separate: the fund runs
on Sherwood's pooled-vault rails (share ledger, live NAV, withdrawal queue), execution lives in one
Sherwood strategy contract (supply USDC on Moonwell → borrow cbBTC + ETH → Aerodrome concentrated LP →
farm & compound AERO, with onchain leverage caps and a permissionless deleverage), and Mamo's backend
is the agent — the same trusted-operator model as Mamo today: it manages the position but can never
withdraw user funds. Users redeem anytime at NAV.

| At a glance | |
|---|---|
| Chain | Base |
| Deposit asset | USDC (ETH & cbBTC added later) |
| Structure | Pooled fund — many depositors, one shared position |
| Strategy | Supply USDC → borrow cbBTC + ETH → Aerodrome CL LP → farm & compound AERO |
| Posture | Leveraged Aerodrome CL LP + AERO emissions carry |
| Custody | Agent manages the position, can never withdraw user funds; users redeem anytime |
| Lifetime | Runs indefinitely |

**Where this guide sits.** This is the fund-ops surface — the Mamo agent driving the **one shared**
Sherwood strategy position directly, as its **proposer**: position management (deploy / compound /
re-range / leverage), and the withdraw-queue drain. It is the third guide in the family; the per-user,
user-facing account integration is the sibling docs
([`LEVERAGED_AERO_BACKEND.md`](./LEVERAGED_AERO_BACKEND.md),
[`LEVERAGED_AERO_FRONTEND.md`](./LEVERAGED_AERO_FRONTEND.md)), which cover the
`MamoLeveragedAeroStrategy` account (USDC-in / USDC-out wrapper) — the many accounts all deposit into
this single position. This doc completes the backend picture: everything the account docs called
"a separate fund-ops runbook" lives here.

> The strategy delegates its venue ops to `LeveragedAeroManager.sol` (impl-call/delegatecall pattern).
> This guide documents the **strategy-facing** behavior the agent observes; manager internals are cited
> only where they explain a guard or a failure mode. For fund-ops **procedure** beyond this repo
> (rebalance policy, monitoring cadence, incident playbooks) the upstream Sherwood repo docs are
> authoritative — the same posture the sibling docs take for the account surface.

---

This is the contract-integration guide for the **keeper / agent** that operates the inner Sherwood
strategy, `LeveragedAerodromeCLStrategy` (a live ERC-1167 clone on staging). The single integration
surface here is that clone; the agent calls it as **proposer**. Units: USDC is 6dp; vault shares are
12dp; LTV / health / fees are all in **bps** (1% = 100). Every operator op requires the strategy to be
in state `Executed`.

---

## A. Role & authorization

The strategy inherits `BaseStrategy`, which stores an immutable-per-clone `_proposer` set at
`initialize(vault_, proposer_, data)` and never changed thereafter. The gate is a single modifier:

```solidity
// BaseStrategy
function proposer() public view returns (address);          // read the operator address
modifier onlyProposer() { if (msg.sender != _proposer) revert NotProposer(); _; }
```

On this deployment `proposer() == MAMO_BACKEND == 0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` — the
Mamo agent. This is the **same** key the account docs call the Sherwood proposer for `fulfillRedeem`;
it is **not** the registry `getBackendAddress()` member-0 key used for the account-level `depositIdle`
nudge (see the backend doc's "two BACKEND_ROLE domains"). Keep the keys wired separately.

Three authorization tiers appear on the strategy:

| Tier | Functions | Gate |
|---|---|---|
| Proposer-only | `deployIdle`, `compound`, `rerange`, `adjustLeverage`, `fulfillRedeem`, `updateParams` | `onlyProposer` (== `MAMO_BACKEND`) |
| Permissionless | `deleverage` | anyone (by design — safety backstop) |
| Proposer **or** vault owner | `rescueToVault` | `proposer() \|\| Ownable(vault()).owner()` |
| Vault-only (lifecycle) | `execute`, `settle` | `onlyVault` — the governor drives these, not the agent |

- **State gate.** Every proposer op (and `deleverage`) opens with `if (_state != State.Executed) revert
  NotExecuted();`. The agent operates the position only while `state() == Executed` (enum
  `State { Pending=0, Executed=1, Settled=2 }`). `execute()`/`settle()` are `onlyVault` and belong to
  the Sherwood governor's proposal lifecycle — out of the agent's hands.
- **`deleverage` is permissionless by design.** It is deliberately **not** `onlyProposer`: a public
  deleverage is the user-safety backstop for the indefinite proposal. It reverts `HealthyNoDeleverage`
  unless the position is genuinely unhealthy (conditions in §B). The agent should run it proactively,
  but anyone (a watcher bot, a user) can trigger it when health slips.
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
| Position effect | supply `amount` USDC → mUSDC → borrow cbBTC+WETH at **`targetLtvBps`** (50/50 split) → wrap ETH → `increaseLiquidity` into the existing CL NFT → restake in the gauge. |
| Guards | Borrow sized at `amount × targetLtvBps / 1e4`; two-sided `maxSlippageBps` mins on the add plus the caller's `minLiquidity`; closes with `_assertHealthy()` (post-op LTV ≤ `maxLtvBps` **and** no Moonwell shortfall). |
| Errors | `InsufficientIdle`, `InsufficientLiquidity`, `MoonwellMintFailed`/`MoonwellBorrowFailed(errCode)`, `UnhealthyPosition(ltvBps, limitBps)`. |
| When to call | Deposits land as idle USDC (see §D) and earn nothing until deployed. Run periodically to sweep accumulated idle into the position, within leverage caps. |

### `compound` — harvest AERO, reinvest, crystallize fees

```solidity
function compound(uint256 minUsdcOut, uint256 minLiquidity) external onlyProposer nonReentrant;
```

| | |
|---|---|
| `minUsdcOut` | Minimum USDC out of the AERO→USDC swap. **Must be non-zero** — `ZeroMinOut()` otherwise. |
| `minLiquidity` | Minimum CL liquidity on the redeploy of the net yield. |
| Position effect | claim AERO from the gauge → swap **all** AERO → USDC via the Aerodrome v2 volatile pool → skim the protocol-fee slice → redeploy the remainder at `targetLtvBps` (same path as `deployIdle`). No-op if flat book (`tokenId == 0`) or no AERO accrued. |
| Fee interaction | Crystallizes management + HWM **performance** fees on the **pre-compound** NAV first (fail-closed on the price — a stale oracle reverts, so the harvest defers rather than mis-prices), so realized yield can't escape the performance fee. Then discharges `protocolFeeOwed` out of the swapped USDC before redeploy. |
| Guards | Effective swap floor = `max(minUsdcOut, oracleFloor)` where `oracleFloor = aeroBal × AERO/USD(8dp) / 1e20 × (1 − maxSlippageBps)`, post-checked on the measured fill → `BelowOracleFloor()`. Redeploy runs `_assertHealthy()`. |
| Errors | `ZeroMinOut`, `BelowOracleFloor`, `UnhealthyPosition`, plus Moonwell/NPM errors on the redeploy; a stale AERO feed fail-closes the whole call. |
| When to call | On a yield/gas cadence. A stale AERO feed intentionally blocks it — defer and retry. |

### `rerange` — re-center the CL range (no swap)

```solidity
function rerange(uint256 minLiq0, uint256 minLiq1) external onlyProposer nonReentrant;
```

| | |
|---|---|
| `minLiq0` / `minLiq1` | Minimum token0 (WETH) / token1 (cbBTC) the re-add must consume (two-sided slippage guard) → `InsufficientLiquidity()`. |
| Position effect | **Calm-gate runs FIRST** (`LeveragedAeroValuation._calmGate`) so a recenter can never execute at a manipulated tick → remove 100% liquidity + collect → mint a **new** tickSpacing-aligned CL NFT centered on the current tick → restake. The **old NFT is left empty** (Slipstream ticks are immutable; the stale NFT is harmless dust). |
| What happens to principal | **No swap → principal conserved** (IL is realized only on a true exit). The collected ratio can't match the new range, so a remainder of **one** borrowed leg is left idle in the strategy — `nav()` prices it, so the recenter is NAV-neutral and the remainder stays redeployable. Debt + collateral untouched (health preserved). |
| Fee interaction | **No crystallization** — supply and NAV are unchanged; the streaming fee simply defers to the next crystallize point and the HWM is unaffected. |
| Guards | Calm-gate; two-sided `maxSlippageBps` mins + caller `minLiq0/minLiq1`; closing `_assertHealthy()`. |
| Errors | calm-gate reverts (`TwapDeviation`/`StaleOracle` family), `InsufficientLiquidity`, `UnhealthyPosition`. |
| When to call | When spot has drifted out of the active range and emissions/fees would benefit from re-centering. |

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
| Position effect | Collateral untouched; LTV moves on the **debt** side. `targetDebt = targetLtvBps_ × collateralUsdc / 1e4`. Lever **up**: borrow the cbBTC/WETH delta and add it (`minLiq`). Lever **down**: unwind the matching CL fraction and repay, per-leg residual rebalanced through USDC (`minOut`). Closes with `_assertHealthy()`. |
| Fee interaction | **No crystallization** (like `rerange`): no supply change, no PnL realized; streaming fee defers, HWM unaffected. |
| Errors | `TargetLtvExceedsMax`, `InsufficientLiquidity`, `MoonwellRepayFailed`/`MoonwellBorrowFailed`, `UnhealthyPosition`. |
| When to call | To hold the fund near `targetLtvBps`, and — critically — **before `fulfillRedeem`** to lever **down** so the oracle-free proportional unwind self-funds its IL/debt shortfall (see §C). |

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
`NotProposerOrOwner()` if the caller is neither the proposer nor the vault owner. Reverts
`CannotRescuePositionToken()` for any position/accounting token: `usdc`, `cbBTC`, `weth`, `mUsdc`,
`mCbBTC`, `mWeth`, and **AERO** (read live from the gauge so a sweep can't bypass `compound()`). The
position NFT is never swept (no ERC-721 path). This is the only recovery path while the indefinite
proposal keeps the vault's own `rescueERC20/721/Eth` dormant.

### Fee surface (proposer-relevant summary)

The strategy is self-fee'd (`selfManagesFees() == true`), so the Sherwood governor skips all
settle-fee distribution and this strategy collects fees itself:

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
    participant S as Sherwood strategy

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
  **strategy-level** idle USDC — the pooled deposits sitting on the Sherwood strategy — deployed with the
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
```

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
  `tickSpacing`), and **position state** (`tokenId`, `posTickLower`, `posTickUpper`, `nextRedeemRequestId`).
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
  first-class `Compounded`/`Reranged`/`LeverageAdjusted`-style events, they can be added — the change
  goes to the upstream Sherwood repo (the code here is vendored; upstream at the pinned commit is
  authoritative) and lands here on the next re-vendor. Raise it when a concrete consumer needs it;
  don't build ops tooling on the assumption they'll never exist.

Strategy events that exist today:

| Strategy event | Use |
|---|---|
| `RedeemRequested / RedeemFulfilled / RedeemCancelled / RedeemEmergency` | withdraw-queue tracking (§C) |
| `FeeCrystallizeDeferred(uint8 op, uint256 navPre)` | a best-effort crystallize deferred (`op`: 0=deposit, 1=fast redeem, 2=proportional redeem). A vault-paused / feeRecipient-de-whitelisted fee-mint — investigate. |

---

## F. Hard operational constraints

- **Oracle staleness / sequencer.** All priced paths (`nav`, fast `redeem`, `compound`, `_assertHealthy`,
  `deleverage`) read hardened Chainlink with `maxDelay` staleness, `gracePeriod` sequencer-restart grace,
  and a calm-gate. A stale feed or a down sequencer **fail-closes** — the op reverts. This is intended
  posture: defer the harvest / re-range / deleverage and rely on the oracle-free async queue for exits.
- **Calm gate.** `rerange` (and NAV pricing) run the calm-gate (`|spotTick − twapTick| ≤ calmDeviationTicks`
  over `twapWindow`) **before** touching the pool, so the agent can never recenter or price at a
  manipulated tick. A shoved pool blocks `rerange`; retry once calm.
- **Per-op slippage bounds.** Every value-moving op takes a caller `min*` floor **and** is additionally
  bounded by the always-on `maxSlippageBps` (∈ (0, 1000] = ≤10%, set at init). `compound` is further
  floored by the AERO/USD oracle (`BelowOracleFloor`). Pass **tight, freshly-quoted** floors; `0` is not
  legal for `compound.minUsdcOut` (`ZeroMinOut`).
- **Hardcoded swap-route `tickSpacing` (audit item 10).** The auxiliary USDC↔leg swap helpers
  (`_swapUsdcExactIn`, `_sweepLegToUsdc`, `_redeemCoverShortfall`) pin `tickSpacing = 100` for the
  USDC/cbBTC and USDC/WETH Slipstream routes (the main LP pool's spacing is config-driven). Two redeem-path
  residual-leg sweeps pass `minOut = 0` and rely on the redeem's **aggregate** `minAssetsOut` floor.
  Operationally: this is a single-venue assumption with no fallback — if a 100-spacing leg pool is thin or
  manipulated, lever-down residual rebalances and full-redeem shortfall covers route through it regardless.
  Prefer sizing exits so the fast/priced path or a pre-deleverage carries them, rather than leaning on the
  `minOut = 0` sweeps under stressed leg-pool conditions.
- **Fee-path asymmetry (audit item 7).** Crystallize is **best-effort** on user-exit paths (defers +
  emits `FeeCrystallizeDeferred`) but **hard-reverts** on `compound`/`settle`/the redeem skim. A persistent
  `FeeCrystallizeDeferred` on deposits/redeems while `compound` reverts points at a vault-pause or a
  de-whitelisted `feeRecipient` — an ops issue to clear.
- **`deleverage` accepted residual (audit item 9).** Our-feed staleness can block `deleverage` in a window
  where Moonwell's own oracle is fresh enough to liquidate; documented and accepted. Monitor Moonwell
  account liquidity independently.

See [`docs/LEVERAGED_AERO_CL_AUDIT.md`](../LEVERAGED_AERO_CL_AUDIT.md) for the full audit focus-area list.

---

## Staging

| Field | Value |
|---|---|
| Network | Base fork (Tenderly Virtual TestNet) — **current staging instance, rotates** |
| RPC | `https://virtual.base.eu.rpc.tenderly.co/70a4990f-6686-4536-8237-ad9103acd11b` |
| Sherwood strategy clone (the operator target) | `0x168ac730AB0DA6FCDE8aA26e33eac4aE6c8CfB4B` |
| Sherwood vault (shares, 12dp) | `0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9` |
| Proposer / agent (`MAMO_BACKEND`) | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` |

Staging endpoints and clone addresses rotate — re-read the current instance from
[`docs/LEVERAGED_AERO_VNET_RUNBOOK.md`](../LEVERAGED_AERO_VNET_RUNBOOK.md) before wiring an environment.
Production addresses are published separately at deploy.

---

## Rebalancer checklist

- [ ] Sign every operator op with the Sherwood **proposer** key (`MAMO_BACKEND`, `0x2Ab0…5e73`); confirm `strategy.proposer()` matches before wiring.
- [ ] Gate the whole operator loop on `state() == Executed`; `execute`/`settle` are the governor's (`onlyVault`), not yours.
- [ ] Periodically `deployIdle(amount, minLiquidity)` accumulated strategy-idle USDC within leverage caps; pass a real `minLiquidity`.
- [ ] `compound(minUsdcOut, minLiquidity)` on cadence with a **non-zero** `minUsdcOut`; expect it to defer (revert) on a stale AERO feed.
- [ ] `rerange(minLiq0, minLiq1)` when spot drifts out of range; expect calm-gate reverts on a shoved pool (retry when calm).
- [ ] `adjustLeverage(target, minLiq, minOut)` to hold near `targetLtvBps` — and to lever **down before `fulfillRedeem`** so the oracle-free unwind self-funds.
- [ ] Watch `RedeemRequested` → assess self-funding via `redeemRequest(id)`/`previewRedeem` → (deleverage if needed) → `fulfillRedeem(id)`; on `InsufficientAssetsOut`, deleverage more or wait — never lower the requester's floor.
- [ ] Treat `FULFILL_WINDOW = 2 days` as the hard SLA; alert before it; every `RedeemEmergency` is a missed SLA.
- [ ] Run `deleverage(minOut)` proactively as health nears `minHealthBps`; remember it is permissionless (others will trigger it too).
- [ ] Monitor `nav()` reverts as a "priced paths degraded to async" signal — **not** a fulfill blocker (the queue is oracle-free); monitor `FeeCrystallizeDeferred` for vault-pause / feeRecipient issues.
- [ ] Use `rescueToVault(token)` only for genuine stray tokens; it reverts on any position/accounting token and always pays the vault.
