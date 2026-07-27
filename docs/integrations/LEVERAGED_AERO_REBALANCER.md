# Leveraged Aero — Rebalancer (fund-ops) integration guide

## The product — Leveraged Aerodrome LP Fund

Leveraged Aerodrome LP fund. Users deposit USDC; the Mamo agent runs a leveraged AERO-farming
position that earns through emissions. Custody and execution are deliberately separate: the fund's share
ledger is a minimal in-repo vault (`LeveragedAeroVault` — shares plus an owner-driven execute/settle
lifecycle, no pricing of its own), execution lives in one strategy contract (supply USDC on Moonwell →
borrow the two CL legs → Aerodrome concentrated LP → farm & compound AERO, with onchain leverage caps and
a permissionless deleverage), and Mamo's backend is the agent — the same trusted-operator model as Mamo
today: it manages the position but can never withdraw user funds. Users redeem anytime at NAV.

| At a glance | |
|---|---|
| Chain | Base |
| Deposit asset | USDC (ETH & cbBTC added later) |
| Structure | Pooled fund — many depositors, one shared position |
| Strategy | Supply USDC → borrow cbBTC + ETH → Aerodrome CL LP → farm & compound AERO |
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

On this deployment `proposer() == MAMO_BACKEND == 0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` — the
Mamo agent. This is the **same** key the account docs call the strategy proposer for `fulfillRedeem`;
it is **not** the registry `getBackendAddress()` member-0 key used for the account-level `depositIdle`
nudge (see the backend doc's "two BACKEND_ROLE domains"). Keep the keys wired separately. The role is a
per-clone immutable, granted at `initialize`, and is unaffected by the removal of the Sherwood stack.

Three authorization tiers appear on the strategy:

| Tier | Functions | Gate |
|---|---|---|
| Proposer-only | `deployIdle`, `compound`, `rerange`, `adjustLeverage`, `fulfillRedeem`, `updateParams` | `onlyProposer` (== `MAMO_BACKEND`) |
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
| Position effect | supply `amount` USDC → mUSDC → borrow both legs at **`targetLtvBps`** (50/50 by USD value) → wrap native ETH **iff** `wethDeliversNative` (§G) → `increaseLiquidity` into the existing CL NFT → restake in the gauge. |
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

### `rerange` — re-center and re-width the CL range (no swap)

```solidity
function rerange(uint24 width, uint256 minLiq0, uint256 minLiq1) external onlyProposer nonReentrant;
```

The 3-arg form (per-cycle width) is the in-repo signature — `src/leveraged-aero/LeveragedAerodromeCLStrategy.sol`
is the authority for it; there is no older 2-arg variant to reconcile against any more.

| | |
|---|---|
| `width` | New position width in **raw ticks** (must be a multiple of `tickSpacing`), validated strategy-side against the init-immutable `[minWidth, maxWidth]` band **before** the venue delegatecall → `WidthOutOfBounds()` (selector `0x1f9f54af`, deliberately matching the Mamo backend's rebalance-param error). The width is **persisted** — subsequent range math (and the genesis mint path) reads the stored value; only `rerange` moves it, the band never moves after init. `layout()` exposes `width` / `minWidth` / `maxWidth` for the rebalancer to read on-chain — always read them off the clone you actually point at (the stale staging clone was init'd width **4000**, band **[200, 20000]**). |
| `minLiq0` / `minLiq1` | Minimum **token0** / **token1** the re-add must consume (two-sided slippage guard) → `InsufficientLiquidity()`. `token0`/`token1` are **pool ordering**, derived at init from `pool.token0()` and exposed as `layout().wethIsToken0` — do not assume which leg is which (see §G). |
| Position effect | **Calm-gate runs FIRST** (`LeveragedAeroValuation._calmGate`) so a recenter can never execute at a manipulated tick → remove 100% liquidity + collect → mint a **new** CL NFT spanning `width/2` raw ticks each side of the current tick → restake. The **old NFT is left empty** (Slipstream ticks are immutable; the stale NFT is harmless dust). |
| What happens to principal | **No swap → principal conserved** (IL is realized only on a true exit). The collected ratio can't match the new range, so a remainder of **one** borrowed leg is left idle in the strategy — `nav()` prices it, so the recenter is NAV-neutral and the remainder stays redeployable. Debt + collateral untouched (health preserved). |
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
  `tickSpacing`), **position state** (`tokenId`, `posTickLower`, `posTickUpper`, `nextRedeemRequestId`),
  the **width band** (`width`, `minWidth`, `maxWidth`), and the **venue-shape fields the keeper must not
  assume** (`cbBTCDecimals`, `wethDecimals`, `wethIsToken0`, `wethDeliversNative`, `cbBTCSwapTickSpacing`,
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
- **Calm gate.** `rerange` (and NAV pricing) run the calm-gate (`|spotTick − twapTick| ≤ calmDeviationTicks`
  over `twapWindow`) **before** touching the pool, so the agent can never recenter or price at a
  manipulated tick. A shoved pool blocks `rerange`; retry once calm.
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

- **No behavioral fork coverage for these rewrites yet.** The ordering / leg-decimals / swap-spacing
  changes are argued equivalent under the legacy (cbBTC+WETH, spacing-100) config and are proven **at init
  only** — never through a mint, compound, rerange or redeem on a fork. A Slipstream+Moonwell fork suite is
  the named **top follow-up before mainnet**; treat any non-legacy pair as unvalidated until it lands.
- **`underlying()` unverified on the live Moonwell markets.** The new init guard will **brick
  initialization** if the live mWETH / mcbBTC markets don't expose `underlying()`. Confirm on a Base fork
  before any deploy.

---

## Staging

> ⚠️ **The live staging instance is STALE.** The clone below is a Sherwood-era build sitting under
> Sherwood's `SyndicateVault`, so its lifecycle, rescue and fee-config surfaces are the *old* ones — none of
> `activateStrategy` / `settleStrategy` / `redeemSettled` / `setFeeConfig` exist there, and the clone
> predates the any-pool init and per-leg swap spacings documented above. A redeploy onto the
> `LeveragedAeroVault` architecture is **pending** (deploy tooling not written yet). Re-read
> `script/tenderly/leveraged-aero-vnet.json` and
> [`docs/LEVERAGED_AERO_VNET_RUNBOOK.md`](../LEVERAGED_AERO_VNET_RUNBOOK.md) before wiring an environment,
> and read every risk/venue value off `layout()` on the clone you actually target.

| Field | Value |
|---|---|
| Network | Base fork (Tenderly Virtual TestNet) — **stale instance, pending redeploy** |
| RPC | `https://virtual.base.eu.rpc.tenderly.co/70a4990f-6686-4536-8237-ad9103acd11b` |
| Strategy clone (the operator target) | `0x5E22913E4C96f816133fbc8E894F652a4f87C760` — Sherwood-era build, width 4000 / band [200, 20000] |
| Previous clone | `0x168ac730AB0DA6FCDE8aA26e33eac4aE6c8CfB4B` — now `Settled` (useful as a real Settled-state test target) |
| Leveraged-aero template | `0x8eE3AD5B3b574b4253985a7F32aB1231474CA381` |
| Vault (shares, 12dp) | Sherwood-era `SyndicateVault` on the current instance — **not** `LeveragedAeroVault` |
| Proposer / agent (`MAMO_BACKEND`) | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` |

Production addresses are published separately at deploy.

---

## Rebalancer checklist

- [ ] Sign every operator op with the strategy **proposer** key (`MAMO_BACKEND`, `0x2Ab0…5e73`); confirm `strategy.proposer()` matches before wiring.
- [ ] Gate the whole operator loop on `state() == Executed`; `execute`/`settle` are `onlyVault` and belong to the vault owner's `activateStrategy` / `settleStrategy`, not to you.
- [ ] Periodically `deployIdle(amount, minLiquidity)` accumulated strategy-idle USDC within leverage caps; pass a real `minLiquidity`.
- [ ] `compound(minUsdcOut, minLiquidity)` on cadence with a **non-zero** `minUsdcOut`; expect it to defer (revert) on a stale AERO feed.
- [ ] `rerange(width, minLiq0, minLiq1)` when spot drifts out of range or the model picks a new width — `width` in raw ticks, tickSpacing-aligned, inside `[minWidth, maxWidth]` (else `WidthOutOfBounds`); expect calm-gate reverts on a shoved pool (retry when calm).
- [ ] `adjustLeverage(target, minLiq, minOut)` to hold near `targetLtvBps` — and to lever **down before `fulfillRedeem`** so the oracle-free unwind self-funds.
- [ ] Watch `RedeemRequested` → assess self-funding via `redeemRequest(id)`/`previewRedeem` → (deleverage if needed) → `fulfillRedeem(id)`; on `InsufficientAssetsOut`, deleverage more or wait — never lower the requester's floor.
- [ ] Treat `FULFILL_WINDOW = 2 days` as the hard SLA; alert before it; every `RedeemEmergency` is a missed SLA.
- [ ] Run `deleverage(minOut)` proactively as health nears `minHealthBps`; remember it is permissionless (others will trigger it too).
- [ ] Monitor `nav()` reverts as a "priced paths degraded to async" signal — **not** a fulfill blocker (the queue is oracle-free); monitor `FeeCrystallizeDeferred`, whose realistic cause is a frozen vault (`depositsOpen == false`).
- [ ] Read the venue shape off `layout()` before wiring anything numeric — leg tokens, `cbBTCDecimals`/`wethDecimals`, `wethIsToken0`, the two leg-swap spacings, the width band (§G). Never hardcode the launch pair.
- [ ] Know the open gaps: the any-pool rewrites have **no behavioral fork coverage** yet, and the Moonwell `underlying()` init guard is unverified on the live markets (§G).
- [ ] Use `rescueToVault(token)` only for genuine stray tokens; it reverts on any position/accounting token and always pays the vault.
