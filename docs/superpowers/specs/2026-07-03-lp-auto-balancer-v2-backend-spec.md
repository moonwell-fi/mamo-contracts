# LPAutoBalancerV2 — Offchain Backend Specification (`lp_balancer_sweep`)

> 📖 New here? Start with the [system overview](../../LP_AUTO_BALANCER_V2.md) — architecture, state machines, and how this spec fits in.

**Status:** Spec, pre-implementation (contracts implemented and tested on `feat/lp-auto-balancer-v2`)
**Date:** 2026-07-03 · **Revised:** 2026-08-10 for the Sherlock audit remediation (`fix/sherlock-lp-autobalancer`)

> **⚠ ABI BREAK vs. the 2026-07-03 revision — re-read §2 before writing any calldata.**
> The audit fixes changed the surface this spec is the contract for. A backend built to the original
> text produces calldata that does not decode and reads getters that no longer exist.
>
> | Change | Then | Now |
> | --- | --- | --- |
> | `RebuildParams` | 6 fields | **8** — `expectedTickLower`/`expectedTickUpper` appended. Different selector (§2.2). |
> | `RebalanceParams` | 10 fields | **12** — same two tick-commitment fields appended. Different selector (§2.2). |
> | Value-floor snapshot | `rebalanceValueBeforePos()` / `rebalanceLooseBefore()` / `rebalanceValueBefore()`, USD 1e8 | **removed.** One `rebalanceAmountsBefore()` returning four raw TOKEN amounts (§2.1, §8.2). |
> | Oracle staleness | one `maxOracleDelay()` | **`maxOracleDelay0()` / `maxOracleDelay1()`**, one bound per feed. |
> | Oracle staleness DEFAULT | 26 hours | **1 hour** (`DEFAULT_MAX_ORACLE_DELAY`), cap **1 day** (`MAX_ORACLE_DELAY`); proposal 011 arms 3600s on both (§7). |
> | `setMaxOracleDelay(uint256)` | writes both bounds | **removed.** Use `setMaxOracleDelays(uint256,uint256)` — both values must be named. |
> | `unwindForSwap` | read no oracle | **probes both feeds + the sequencer guard** before teardown; can now revert `StaleOracle`/`SequencerDown`/`SequencerGracePeriod` (§2.2). |
> | Sequencer uptime | backend-only compensating control | **enforced on-chain** — `sequencerUptimeFeed()` / `sequencerGracePeriod()` (§7). |
> | Legal `width` | any multiple of `tickSpacing` | multiple of **`2 × tickSpacing`** (§5). |
> | `claimEmissions()` | permissionless | **`REBALANCER_ROLE`** (§1, §9.1). |
> | `isValidSignature` | always live while in flight | **`whenNotPaused`** — pausing kills order placement AND settlement (§6.1). |
**Extends:** `2026-06-17-lp-auto-balancer-v2-dual-position-design.md` (base), `2026-07-02-lp-auto-balancer-v2-swap-rebalance-design.md` (two-phase swap mode), `docs/LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md` Phase C (handover)
**Target:** the `centaur-moonwell` `lp_balancer_sweep` workflow — Python workflow + httpx JSON-RPC helpers (`workflows/_evm.py` conventions), a sandboxed signer EOA acting via `cast send`, and a completion gate that re-reads chain state independently of the agent. All money-moving decisions in this spec are **deterministic formulas**; the LLM layer orchestrates, retries, and reports, but never freestyles amounts, prices, or direction.

---

## 1. Actors, keys, and trust envelope

| Actor | Key/where | Can | Cannot |
| --- | --- | --- | --- |
| **Backend rebalancer** | `BACKEND_REBALANCER_EOA`, hot key inside the sandbox, holds `REBALANCER_ROLE` | `stake`, `unstake`, `rebalanceUsingAlt`, `unwindForSwap`, `rebuildAfterSwap`, `compound`, **`claimEmissions`** | Move value anywhere except the balancer itself, `feeCollector` (DROP_AUTOMATION), or the compound module. Cannot change config, oracles, gauge, pool, or tolerances. |
| **F-MAMO Safe** | `0xfE2ff8927EF602DDac27E314A199D16BE6177860`, `DEFAULT_ADMIN_ROLE` on balancer + module | `exit(to)` (unpausable, works mid-flight), `setSwapLossAllowanceBps`, `setRebalanceSlippageBps`, `setCompoundAppData`, `approveCowSwap`, role grants/revokes, recover | — |
| **Guardian** | F-MAMO (phase-1) | `pause()` / `unpause()` — blocks both swap phases and all rebalancer actions; `exit` stays available | — |
| **Checker owner** | MAMO_MULTISIG `0x26c158A4CD56d148c554190A95A921d90F00C160` (NOT F-MAMO) | `addTokenConfiguration`, `setMaxTimePriceValid` on `CHAINLINK_SWAP_CHECKER_PROXY` `0x5A8F10be44E25Bb21492C5f46DA94cDb1f0b2fF6` | — |
| **Anyone** | — | `collectFees()` (permissionless skim to feeCollector, idle + unstaked only); place CoW orders against the balancer while `rebalanceInFlight` and NOT paused (see §6.6) | Extract funds. Orders are price-floored by `rebalanceSlippageBps` and must pay to the balancer. **`claimEmissions()` is no longer here** — see the note below. |

> `claimEmissions()` was moved from permissionless to `REBALANCER_ROLE`. It routes 100% of claimed
> AERO to the feeCollector, so leaving it open let anyone keep the gauge's pending balance at ~0,
> which starves `compound(compoundBps)` of anything to split and silently disables the reinvest leg.
> Nothing about the claim is time-critical (emissions keep accruing in the gauge), so the backend now
> owns the call. Any external tooling that relied on calling it will revert
> `AccessControlUnauthorizedAccount`.

Worst-case with a fully compromised rebalancer key: principal converted between WETH↔cbBTC at no worse than `rebalanceSlippageBps` (50 bps) below Chainlink per swap, round-trip bounded by the rebuild value floor (`maxRebalanceLossBps + swapLossAllowanceBps` = 400 bps), at most once per `minRebalanceInterval` (6h). Response: Safe `revokeRole(REBALANCER_ROLE, eoa)`, then `exit(SAFE)` if needed.

## 2. Contract surface consumed

Balancer: `MAMO_LP_AUTO_BALANCER_V2` (addresses/8453.json after the 011 proposal). Module: `MAMO_LP_COMPOUND_MODULE`.

### 2.1 Reads

`getDecisionSnapshot()` (selector `0xb2c646c8`) → `DecisionSnapshotV2`, single atomic read, **reverts `NotActive` if no position registered**:

```solidity
struct DecisionSnapshotV2 {
    int24  spotTick;            // pool slot0 tick
    int24  twapTick;            // TWAP over position.twapWindow (1800s)
    int24  mainTickLower;       // ┐
    int24  mainTickUpper;       // │
    bool   mainInRange;         // │ ZERO/FALSE while rebalanceInFlight —
    int24  altTickLower;        // │ the NFTs are burned mid-flight and the
    int24  altTickUpper;        // │ view skips them. Key ALL interpretation
    bool   hasAlt;              // │ of these fields off rebalanceInFlight
    uint128 mainLiquidity;      // │ first.
    uint128 altLiquidity;       // │
    bool   mainStaked;          // │
    bool   hasGauge;            // │
    uint256 earnedAero;         // ┘ (try/catch on gauge.earned)
    uint256 cooldownRemaining;  // seconds until unwindForSwap/rebalanceUsingAlt allowed
    bool   deviationGateOpen;   // |spot − twap| ≤ maxTickDeviation (100 ticks)
    bool   rebalanceInFlight;   // two-phase swap window open
    uint256 rebalanceStartedAt; // unwindForSwap timestamp (0 when idle)
}
```

Supplementary reads the decision engine needs beyond the snapshot:
- `position()` — 21-field tuple; notably `token0`, `token1`, `tickSpacing`, `gauge`, `lastRebalance`, `minRebalanceInterval`, `minWidth`, `maxWidth`, `maxRebalanceLossBps`.
- **Value-floor baseline — `rebalanceAmountsBefore()` (`0x9ab6c2c5`), the ONLY floor read.**

  ```solidity
  function rebalanceAmountsBefore() external view
      returns (uint256 amount0Pos, uint256 amount1Pos, uint256 loose0, uint256 loose1);
  ```

  Four RAW TOKEN AMOUNTS in each token's own decimals (WETH 18, cbBTC 8) — **not USD 1e8**.
  `amount0Pos`/`amount1Pos` are the main+alt principal at unwind; `loose0`/`loose1` are the loose
  balance that was already sitting on the balancer at unwind. Price them yourself with the same
  ETH/USD and BTC/USD feeds the contract uses (§8.2).

  **The old `rebalanceValueBeforePos()`, `rebalanceLooseBefore()` and `rebalanceValueBefore()` USD
  getters are GONE — calling them reverts (no such selector).** They froze a USD figure at unwind,
  which is exactly what the floor stopped using: an ordinary market move during CoW settlement read
  as a rebalance loss and reverted honest rebuilds. The floor now snapshots amounts at unwind and
  prices them at rebuild with the same feed reads that produce `valueAfter`, so the market move
  cancels on both sides.
- `sellTokenInFlight()` (`0x518dbe76`), `rebalanceWasStaked()` (`0x168b41ca`), `rebalanceInFlight()`
  (`0xc6d59f3a`), `rebalanceStartedAt()` (`0x54ea6848`), `swapLossAllowanceBps()` (`0xfaf35448`).
- **Per-feed oracle staleness: `maxOracleDelay0()` (`0x69915df2`) and `maxOracleDelay1()`
  (`0x312bb0be`).** The single `maxOracleDelay()` getter is GONE. `maxOracleDelay0` bounds
  `position.oracle0` (ETH/USD) only and `maxOracleDelay1` bounds `position.oracle1` (BTC/USD) only —
  a shared bound sized for the slower feed accepted the faster feed's answers far past their own
  validity, and both `_mainRange` and `_mintAlt` pick a SIDE from a value0-vs-value1 comparison, so
  one stale leg puts the position on the wrong side of the market. `setMaxOracleDelays(uint256,uint256)`
  (`0x3c528ef6`) is now the ONLY writer — the single-argument `setMaxOracleDelay(uint256)` was REMOVED
  along with its `MaxOracleDelayUpdated` event, because a setter that writes one value to both feeds
  silently flattens the per-feed tuning this split exists to provide. Both bounds must be named at
  every write. Two new constants bound them: `DEFAULT_MAX_ORACLE_DELAY()` (`0x4b77e25e`) = **1 hour**,
  the value the constructor seeds, and `MAX_ORACLE_DELAY()` (`0xc6d3107f`) = **1 day**, the hard
  ceiling either bound may take (the old ceiling was 7 days — ~500x the feeds' ~20-minute heartbeat,
  loose enough that a fat-fingered value validated). Proposal 011 arms **3600s on both**.
- **Sequencer guard: `sequencerUptimeFeed()` (`0xa7264705`) and `sequencerGracePeriod()`
  (`0x26a97b94`).** Non-zero after the 011 proposal (`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`,
  grace 3600s). See §7 — this is now an on-chain guard, not a backend-only precondition.
- `POSITION_MANAGER.positions(tokenId)` for exact liquidity/ticks (idle only).
- `IERC20(token0|token1).balanceOf(balancer)` — loose balances (the principal itself, mid-flight).
- `IERC20(sellTokenInFlight).allowance(balancer, VAULT_RELAYER)` — remaining approval mid-flight.
- Gauge: `rewardRate()`, `totalSupply()`/staked-liquidity accessors for the AERO math (§4).
- Checker: `getExpectedOut(amountIn, from, to)`, `maxTimePriceValid(token)`; module: `rebalanceSlippageBps()`, `compoundAppData()`.
- Chainlink `latestRoundData()` on `CHAINLINK_ETH_USD` `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` and `CHAINLINK_BTC_USD` `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` (freshness precondition, §7).

### 2.2 Writes (all `REBALANCER_ROLE`, `nonReentrant`, `whenNotPaused`)

```solidity
struct UnwindParams {            // unwindForSwap — phase 1
    address sellToken;           // token0 or token1: the EXCESS leg
    uint256 sellAmount;          // exact approval pinned to VAULT_RELAYER
    uint256 amount0MinWithdraw;  // sandwich floors, main teardown
    uint256 amount1MinWithdraw;
    uint256 amount0MinWithdrawAlt; // alt teardown (0s if hasAlt == false)
    uint256 amount1MinWithdrawAlt;
    uint256 deadline;
}

struct RebalanceParams {         // rebalanceUsingAlt ONLY (has withdraw-min fields; it tears down)
    uint24  width;               // ∈ [minWidth, maxWidth], multiple of tickSpacing
    uint256 amount0MinMain;      // mint floors, main
    uint256 amount1MinMain;
    uint256 amount0MinAlt;       // mint floors, alt (contract zeroes the unfunded leg)
    uint256 amount1MinAlt;
    uint256 amount0MinWithdraw;  // teardown sandwich floors, main
    uint256 amount1MinWithdraw;
    uint256 amount0MinWithdrawAlt;
    uint256 amount1MinWithdrawAlt;
    uint256 deadline;
    int24   expectedTickLower;   // ── TICK COMMITMENT (fields 11 and 12, appended in this order)
    int24   expectedTickUpper;   //    reverts TickMismatch() unless the on-chain main range matches
}

struct RebuildParams {           // rebuildAfterSwap ONLY — NO withdraw-min fields (teardown
    uint24  width;               // already happened in unwindForSwap; this call only mints)
    uint256 amount0MinMain;      // mint floors, main
    uint256 amount1MinMain;
    uint256 amount0MinAlt;       // mint floors, alt (contract zeroes the unfunded leg)
    uint256 amount1MinAlt;
    uint256 deadline;
    int24   expectedTickLower;   // ── TICK COMMITMENT (fields 7 and 8, appended in this order)
    int24   expectedTickUpper;   //    reverts TickMismatch() unless the on-chain main range matches
}
```

**`RebuildParams` is 8 fields, in exactly that order.** The canonical signature is

```
rebuildAfterSwap((uint24,uint256,uint256,uint256,uint256,uint256,int24,int24))   selector 0x44254680
```

(for reference: `unwindForSwap((address,uint256,uint256,uint256,uint256,uint256,uint256))` = `0x6792a3dc`,
`rebalanceUsingAlt((uint24,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int24,int24))` = `0x924a74b4` —
the pre-audit 10-field encoding `0xb1d2c9ac` no longer decodes.)
The pre-audit 6-field encoding hits a **different selector and will not decode** — it lands in the
fallback and reverts. Both new fields are `int24`, ABI-encoded as sign-extended 32-byte words.

**Computing the commitment — required on BOTH rebalance paths.** `expectedTickLower`/`expectedTickUpper`
are the main range you decided on off-chain; the contract recomputes the range from LIVE spot and
reverts `TickMismatch()` on any difference. `rebalanceUsingAlt` now enforces the identical check:
being a single transaction is not a substitute, because the calm gate bounds spot against the TWAP
but still hands LIVE spot to `_mainRange`, so a sandwich that moves spot by up to `maxTickDeviation`
(one full spacing at the phase-1 config) shifts the whole range, and neither the mint minima nor the
value floor can detect it (the floor measures at the manipulated price, where the fresh position
holds exactly the tokens just deposited).

Reproduce `_mainRange` exactly, using `spotTick` from `slot0()` in the same block you build the call,
and the SAME per-leg USD values the contract computes (Chainlink `oracle0`/`oracle1`):

- **`rebuildAfterSwap`** — the principal is already loose on the balancer, so `balanceOf(token0|1)`
  is the input directly.
- **`rebalanceUsingAlt`** — the principal is still IN the positions at call time. Use the amounts the
  teardown will return: `LPValuationLib.principalAmounts(positionManager, mainTokenId, sqrtP)`
  `+ principalAmounts(positionManager, altTokenId, sqrtP)` (it derives them from `positions()`
  liquidity + ticks at the current `sqrtPriceX96`, and returns `(0, 0)` for tokenId 0, so an absent
  alt needs no special case) **plus** any loose `balanceOf` already on the balancer. Simplest path
  in practice: read `getDecisionSnapshot()`, which returns the ticks + liquidity for both legs.
  That sum is what `_mainRange` sees post-`_exitAll`, modulo the pool's own round-down on the
  decrease — within a wei of `MIN_MAIN_LEG_USD` the branch can therefore flip and produce an honest
  `TickMismatch()`; treat it as the retry it is.

```
floor = floorAlign(spotTick, tickSpacing)          // largest aligned tick <= spot, floors toward -inf
v0    = usd(balanceOf(token0)), v1 = usd(balanceOf(token1))     // 1e8 scale, per-leg feeds

if min(v0, v1) >= MIN_MAIN_LEG_USD (1e6, i.e. $0.01):           // BALANCED straddle
    tickLower = floorAlign(spotTick - width/2, tickSpacing)
    tickUpper = tickLower + width
else if v0 >= v1:                                               // token0-majority, SINGLE-SIDED above spot
    tickLower = floor + tickSpacing
    tickUpper = tickLower + width
else:                                                           // token1-majority, SINGLE-SIDED at/below spot
    tickUpper = floor
    tickLower = floor - width
```

Because `width` must be a multiple of `2 × tickSpacing` (§5), `width/2` is a whole number of
spacings and the balanced branch simplifies to `[floor - width/2, floor + width/2]`.

**The commitment pins the tick PAIR, not the branch that produced it.** Two known residuals follow,
both Low and both closable off-chain:

1. *Branch collision at `width == 2 × tickSpacing`.* The balanced pair `[F − w/2, F + w/2]` and the
   token1-single-sided pair `[F' − w, F']` are the SAME pair whenever `F' = F + w/2` — i.e. one full
   spacing of push, which the calm gate accepts (`dev == maxTickDeviation` passes). At the phase-1
   config (`tickSpacing` 100, `width` 200, `maxTickDeviation` 100) that collision is reachable: push
   spot to the old main's `tickUpper`, teardown returns 100% token1, `value0` falls under
   `MIN_MAIN_LEG_USD`, and the single-sided branch mints the pair you committed to. The geometry is
   correct so there is no mis-ranging loss, but the single-sided branch **zeroes the caller's token0
   mint minimum**, an intended two-sided deployment becomes a single-sided deposit priced at
   manipulated spot, and the cooldown is consumed. Config closes it with zero bytecode: ship
   `minWidth > 2 × maxTickDeviation` (i.e. `MIN_WIDTH` 400 at the phase-1 deviation bound), which
   makes the collision arithmetically unreachable. Otherwise the backend must not treat a committed
   pair as proof of a balanced mint — check the realized `amount0Min`/`amount1Min` forwarding.
2. *Residual MAGNITUDE inside one committed bucket.* For `spot ∈ [floor, floor + tickSpacing − 1]`
   the main range is the same pair throughout, so `TickMismatch()` stays silent while the in-range
   value split swings from 50/50 at `spot == floor` to ≈0.6/99.4 at `floor + 99`. Sandwiching a
   rebuild with a +99-tick push against a 50/50 balance sheet leaves ~half the principal as surplus,
   minted into a one-spacing out-of-range alt that earns nothing until the cooldown expires. The
   value floor is blind to it (it prices the alt at the manipulated `sqrtP`). **The mint minima ARE
   the control here** — the balanced branch keeps BOTH caller minima (it only zeroes one on the
   single-sided branches), so sized minima revert this scenario. See the sizing rule in §5.

**Failure mode is a revert, never a bad mint.** Spot moving one tickSpacing between your read and
inclusion reverts `TickMismatch()` — recompute at fresh spot and resubmit. Treat it as a retry, not
an error (§8). Do NOT widen the commitment to "whatever the contract computes": it exists precisely
because the amount minima cannot detect a shifted range (a single-sided mint consumes the whole
funded balance at the honest and the manipulated price alike, so `amount0MinMain` passes either way).

- `unwindForSwap(UnwindParams)` — guards in order: active → not-in-flight → cooldown → module set → sellToken/amount valid → calm gate. Snapshots the value floor as FOUR raw TOKEN AMOUNTS, readable via `rebalanceAmountsBefore()`: `(amount0Pos, amount1Pos)` = main + alt PRINCIPAL, `(loose0, loose1)` = loose token0/token1 already on the contract. **The snapshot itself is oracle-free** (pricing happens at rebuild, so a market move between the two
transactions cancels on both sides of the floor) — but the call now PROBES both feeds and the sequencer
guard before the teardown, purely to fail fast. It can therefore revert `StaleOracle`, `SequencerDown` or
`SequencerGracePeriod`. This closes a teardown that provably could not be rebuilt: previously a feed
stale at unwind burned both NFTs and only surfaced when `rebuildAfterSwap` reverted, leaving principal
loose and unstaked with `exit()` (DEFAULT_ADMIN_ROLE, the timelocked Safe) as the only escape. Note the
residual: the probe bounds the state at unwind, not at rebuild — a feed that goes stale BETWEEN the two
calls, a sequencer restart between them (`checkSequencer` then rejects reads for the whole grace period),
or a Safe `setOracles`/`setMaxOracleDelays` mid-flight all still strand the rebuild until they clear. That
residual got MORE reachable with MOO-740: at the 3600s bound three consecutive missed rounds strand a
rebuild, where the old 26h bound took ~76. Mitigations are operational — short `validTo`, and prefer the
no-swap `rebalanceUsingAlt` while either feed is degraded (§8.2). Tears down both legs (AERO skimmed to feeCollector), pins `forceApprove(VAULT_RELAYER, sellAmount)`, sets `rebalanceInFlight` and `sellTokenInFlight = sellToken`. **Does NOT stamp `lastRebalance`.** Emits `RebalanceUnwound(address sellToken, uint256 sellAmount)`.
- `rebuildAfterSwap(RebuildParams)` — **takes `RebuildParams`, NOT `RebalanceParams`** (8 fields: no withdraw-mins, plus the two tick-commitment fields — a `RebalanceParams`-encoded call, or a pre-audit 6-field `RebuildParams`, hits a different selector and reverts). Requires in-flight; **no cooldown**; revokes approval; re-runs calm gate; checks `width` bounds and the `2 × tickSpacing` alignment; derives the main range and reverts `TickMismatch()` unless it equals `(expectedTickLower, expectedTickUpper)`; mints main (+alt from surplus); enforces

  ```
  valueAfter ≥ usd(amount0Pos, amount1Pos) × (10000 − maxRebalanceLossBps − swapLossAllowanceBps)/10000
             + usd(loose0, loose1)
  ```

  where BOTH `usd(...)` terms are computed inside the rebuild call at the same feed reads that
  produce `valueAfter` (position term haircut, loose term added back UN-haircut — same H-1 treatment
  as `rebalanceUsingAlt`). Then clears in-flight state; forwards dust; restakes iff staked at unwind;
  **stamps `lastRebalance`**. Emits `RebalanceRebuilt(uint256 mainTokenId, uint256 altTokenId)`.
- `rebalanceUsingAlt(RebalanceParams)` — the atomic no-swap path (same-transaction floor: `valueAfter ≥ valueBeforePos × (10000 − maxRebalanceLossBps)/10000 + looseBefore`). **Takes 12 fields now**, and derives the main range then reverts `TickMismatch()` unless it equals `(expectedTickLower, expectedTickUpper)` — same rule as `rebuildAfterSwap`; see §2.2 for how to compute the commitment on this path (the principal is still in the positions, so you must predict the teardown output). Emits `RebalancedUsingAlt(uint256 mainTokenId, uint256 altTokenId, int24 tickLower, int24 tickUpper)`.
- `compound(uint16 compoundBps)` — harvests AERO from staked legs; `compoundBps`/10000 → module, remainder → feeCollector. Emits `CompoundInitiated(uint256 compoundAmount, uint256 droppedAmount, uint16 compoundBps)`.
- `stake()` / `unstake()` — gauge deposit/withdraw for both legs.

### 2.3 Events to index

`RebalanceUnwound`, `RebalanceRebuilt`, `RebalancedUsingAlt`, `CompoundInitiated`, `EmissionsClaimed(uint256)`, `Staked(uint256 indexed,address)`, `Unstaked(uint256 indexed,address)`, `SwapLossAllowanceUpdated(uint256,uint256)`, module `RebalanceSlippageUpdated(uint256,uint256)`, and GPv2 `Trade` (settlement `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`, filter `owner == balancer`) as the authoritative fill signal alongside orderbook polling.

### 2.4 Error selector table (decode revert data before retrying)

| Selector | Error | Meaning for the backend |
| --- | --- | --- |
| `0x80cb55e2` | `NotActive()` | No registered position (or `exit` ran). Halt; page ops. |
| `0x9db4b036` | `AlreadyInFlight()` | Unwind attempted while a cycle is open. Resume §3 recovery. |
| `0x8ca96565` | `NotInFlight()` | Rebuild attempted while idle — the cycle already closed. Re-derive state. |
| `0xb0782df7` | `Cooldown()` | Wait `cooldownRemaining` from the snapshot. |
| `0x64a78d82` | `TwapDeviation()` | Calm gate closed. Backoff-retry (§8). |
| `0x63ffd39c` | `ValueFloor()` | Rebuild floor breached — wedge playbook (§8.2). |
| `0x88cce429` | `StaleOracle()` | The offending feed is stale against ITS OWN bound (`maxOracleDelay0` for oracle0, `maxOracleDelay1` for oracle1), or its answer is non-positive, or `updatedAt` is in the future. Alert; do NOT unwind. |
| `0x032b3d00` | `SequencerDown()` | Base sequencer uptime feed reports down (or a zero/future `startedAt`). Every valuation path fails closed. Stop all writes; wait for recovery (§7). |
| `0xb5d44b5c` | `SequencerGracePeriod()` | Sequencer is back up but inside `sequencerGracePeriod()` (3600s). Not an error — wait it out, then resume. |
| `0xe6434dc8` | `TickMismatch()` | Spot moved (or was moved) between your range decision and inclusion, so the derived main range ≠ `expectedTickLower`/`expectedTickUpper`. **Expected under normal drift.** Re-read `slot0()`, recompute the commitment (§2.2), resubmit. Repeated mismatches in the same block range ⇒ someone is pushing spot; back off and re-quote. |
| `0xa23c9545` | `InvalidWidth()` | `width` is not a multiple of `2 × tickSpacing` (§5), or a config write used bounds that are not. Backend bug — fix params, don't retry. |
| `0x1f9f54af` | `WidthOutOfBounds()` | `width` outside `[minWidth, maxWidth]` — backend width bug, don't retry blindly. |
| `0x69a0cf86` | `CenterDeviation()` | Range placement drifted from spot mid-mint; recompute + retry. |
| `0x5110df24` | `InvalidSellToken()` | sellToken ∉ {token0,token1} or sellAmount 0 — backend bug. |
| `0x03bca7b7` | `ModuleNotSet()` | Wiring incomplete — pre-launch gap. |
| `0x039f2e18` | `NotStaked()` | claimEmissions/unstake with nothing staked. |
| `0x0ae3514d` | `AlreadyStaked()` | `stake()` on an already-staked main, or `collectFees()` while staked (use `claimEmissions()`). |
| `0x61f826f4` | `NothingToCompound()` | `compound()` with zero AERO on hand — typically called mid-flight (both legs unstaked, nothing harvests). |
| `0xd93c0665` | `EnforcedPause()` | Guardian paused. Stop, alert, wait (§8). Note this now also blocks `isValidSignature`, so open CoW orders stop settling too (§6.1). |

## 3. Cycle state machine and stateless recovery

```
IDLE ──observe──▶ DECIDE ──┬─▶ NOOP (sleep)
                           ├─▶ ALT:  rebalanceUsingAlt ──▶ IDLE
                           └─▶ SWAP: unwindForSwap ──▶ IN_FLIGHT
IN_FLIGHT ──quote+place──▶ ORDER_OPEN ──┬─ filled (Trade event / API "fulfilled")
                                        ├─ expired (validTo passed, or validTo−5min policy cutoff)
                                        └─ wedged (rebuild reverting)
        all three ────────▶ rebuildAfterSwap ──▶ IDLE
        emergency ────────▶ Safe exit(SAFE) (manual escalation only)
```

**Stateless recovery rule (mandatory).** The workflow persists nothing it cannot rebuild. On every wake, derive the phase from chain truth:

1. `getDecisionSnapshot()` → if `rebalanceInFlight == false` → IDLE (any locally remembered order uid is dead: rebuild revoked the approval and closed the 1271 window, so a stale order cannot settle).
2. If `rebalanceInFlight == true` → IN_FLIGHT. Read `sellTokenInFlight`, remaining `allowance(balancer, VAULT_RELAYER)`, loose `balanceOf` both tokens, and query the orderbook `GET /api/v1/account/{balancer}/orders` for open orders. Allowance consumed (or buy-token balance jumped) ⇒ filled ⇒ REBUILD. Open order within its window ⇒ keep polling. No live order and no desire to re-post ⇒ REBUILD (no-swap outcome).
3. Never trust local memory over the chain: a crash between `unwindForSwap` confirmation and order placement, or between fill and rebuild, must resolve correctly from reads alone.

Concurrency: exactly one sweep instance (workflow-level lock). The 6h `minRebalanceInterval` is the outer cadence; the cron may run more often (for compound/monitoring) but the rebalance branch is gated by `cooldownRemaining == 0`.

## 4. Decision math (deterministic)

All USD values 8-decimal, matching the contract's `valueInUsd`.

**Holdings.** Idle: token amounts from `positions(mainTokenId)` + `positions(altTokenId)` converted at `spotTick` (LiquidityAmounts math), plus loose balances. `V0 = usd(token0 total)`, `V1 = usd(token1 total)`, `TVL = V0 + V1`.

**Imbalance.** `imbalance = |V0 − V1| / TVL` ∈ [0, 1). A perfectly balanced dual-leg position has 0; a fully one-sided position ½ of TVL out of ratio has 0.5.

**Excess leg / sell size.** Sell the richer leg down to 50/50:
`sellValueUsd = (max(V0,V1) − min(V0,V1)) / 2`; `sellToken` = richer leg; `sellAmountApprove = tokens(sellValueUsd) × (1 + APPROVE_BUFFER_BPS/10000)` (default buffer 200 bps — covers fee accrual and drift between quote and teardown; the approval is a ceiling, not the order size, and any residue is revoked at rebuild).

**AERO rates.** Gauge emissions accrue only to *staked, in-range* liquidity:
- `aeroPerSecPool = gauge.rewardRate()`; our in-range share `σ = ourStakedInRangeLiquidity / gaugeInRangeLiquidity`.
- `R_full` = AERO/hour if the whole TVL sits in a staked, in-range main (post-swap state).
- `R_now` = AERO/hour of the current shape (alt liquidity out of range earns 0; an out-of-range main earns 0).
- `marginal = R_full − R_now` (AERO/h), `marginalUsd = marginal × aeroUsd` (AERO/USD from CHAINLINK_AERO_USD `0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0`).

**Swap cost.**
`swapCostUsd = quoteFeeUsd + expectedSlippageUsd + gasUsd(unwind + rebuild + order overhead) + downtimeUsd + cooldownDragUsd`
- `quoteFeeUsd` + `expectedSlippageUsd`: from the CoW quote vs Chainlink mid (§6.2) — the *expected* execution shortfall, not the worst-case floor.
- `downtimeUsd = T_inflight_hours × R_now_usd` — while in flight NOTHING is staked, so the running rate is lost in full. Use `T_inflight = ORDER_WINDOW + margin` (pessimistic).
- `cooldownDragUsd`: an unfilled cycle still burns a 6h cooldown (rebuild stamps `lastRebalance`); charge `P(no-fill) × 6h × marginalUsd`. With sane pricing P(no-fill) is small; default charge 10%.

**Decision rule (per idle cycle):**
```
if !deviationGateOpen or cooldownRemaining > 0 or feeds stale:      NOOP
elif imbalance < IMBALANCE_MIN (default 0.10):                      NOOP or ALT (recenter only)
elif paybackHours = swapCostUsd / marginalUsd ≤ PAYBACK_MAX_HOURS   SWAP
     (default 24h) and marginalUsd > MARGINAL_MIN_USD_PER_H:
elif main out of range or |center drift| > hysteresis:              ALT
else:                                                               NOOP
```
The emissions-regime guard is the `marginalUsd > MARGINAL_MIN_USD_PER_H` term: when AERO price or `rewardRate` collapses, `paybackHours` blows up and the engine naturally falls back to ALT/no-op — the per-cycle mode choice the design intends.

## 5. Parameter computation

- **Withdraw mins (unwind + alt path).** For each leg: `amounts = getAmountsForLiquidity(sqrtP, tickLower, tickUpper, liquidity)`, then `min = amount × (1 − WITHDRAW_TOLERANCE_BPS/10000)` (default 50). **Never send 0 mins** — the calm gate (~1%) would be the only sandwich backstop. If `hasAlt == false`, alt mins are 0 (nothing to tear down).
- **Mint mins (rebuild + alt path).** Predict the in-ratio consumption from planned post-swap balances at `spotTick` for the chosen range, haircut by `MINT_TOLERANCE_BPS` (default 50). Alt mint mins: apply the haircut to the predicted surplus leg (the contract zeroes the unfunded side itself).
  **Send them, and size them — they are the only control for the in-bucket residual (§2.2).** On the balanced branch the contract forwards BOTH `amount0MinMain` and `amount1MinMain` to the position manager unchanged, so a min set at `predicted × (1 − MINT_TOLERANCE_BPS/10000)` reverts a sandwich that skews the in-range split inside a single committed tick bucket (where `TickMismatch()` is silent by construction). Zeros disable that protection entirely: `TickMismatch` pins WHERE liquidity lands, the minima pin HOW MUCH of each leg actually lands there, and neither substitutes for the other. The Tenderly reference harness passes zeros for rig convenience — do not copy it into a production caller.
- **Width.** Default `WIDTH_TICKS` env (phase-1 default 200 = 2 × tickSpacing, the tightest allowed — the CL10 backtest's edge is tight ranges). Must satisfy `minWidth ≤ width ≤ maxWidth` **and `width % (2 × tickSpacing) == 0`** — at the phase-1 tickSpacing of 100 that is `width % 200 == 0`, so 200/400/600… are legal and 300/500/700… now revert `InvalidWidth()` even though they are multiples of 100. The even-multiple rule is load-bearing, not stylistic: it makes `width/2` a whole number of spacings, which is what lets the `RebuildParams` tick commitment pin the ALT placement as well as the main (§2.2). The same rule is validated on `minWidth`/`maxWidth` at config time, so a Safe config write with an odd-multiple bound reverts `InvalidWidth()` too. The phase-1 config (`minWidth` 200, `maxWidth` 20 000) and the default width all satisfy it unchanged. Any adaptive widening (realized-vol responsive) stays within the on-chain band AND on the even-multiple grid.
- **Deadline.** `now + 300` seconds on every write.
- **Order size ≠ approval.** After the unwind tx confirms, read actual loose balances and size the order: `sellAmountOrder = min(recomputed excess from actual balances, approval, balanceOf(sellToken))`. An order larger than the balance can never settle (fill-or-kill), it just wastes the cycle.

## 6. CoW order lifecycle (Base)

Orderbook base URL: `https://api.cow.fi/base/api/v1` (chain live, checked 2026-07-03). Settlement `0x9008D19f58AAbD9eD0D60971565AA8510560ab41`; vault relayer `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110`; domain separator `0xd72ffa789b6fae41254d0b5a13e6e1e92ed947ec6a251edf1cf0b6c02c257b4b` (verified against the live settlement contract 2026-07-03; equals the module's hardcoded constant).

### 6.1 Ordering constraint
Place the order **only after the `unwindForSwap` tx is confirmed**: the orderbook simulates `isValidSignature` at placement, which requires `rebalanceInFlight == true`, a live price-checker path, and (for balance checks) the sell tokens loose on the balancer.

`isValidSignature` is now `whenNotPaused`. Pausing therefore does two things the original spec did
not account for: placement fails (`EnforcedPause()` surfaces as a signature-verification failure from
the orderbook), and — more importantly — **an already-placed order stops being settleable**, because
the solver's settlement re-evaluates the 1271 signature. That closes the gap where `pause()` could
not stop an in-flight swap (it does not revoke the standing `VAULT_RELAYER` allowance). Operational
consequence: after an unpause, re-check whether the order is still inside its `validTo` before
assuming it is dead, and never treat "paused" as "the swap is guaranteed unfilled" for an order whose
window survives the pause.

### 6.2 Quote and limit price
1. `POST /quote` with `{sellToken, buyToken, receiver: balancer, from: balancer, kind: "sell", sellAmountBeforeFee: sellAmountOrder, signingScheme: "eip1271"}` → `quote.buyAmount`.
2. Oracle floor: `oracleFloor = checker.getExpectedOut(sellAmountOrder, sellToken, buyToken) × (10000 − rebalanceSlippageBps)/10000`. The on-chain check is a **strict** `buyAmount > oracleFloor`.
3. Limit: `buyAmountLimit = max(quote.buyAmount × (10000 − LIMIT_HAIRCUT_BPS)/10000, oracleFloor + 1)` with `LIMIT_HAIRCUT_BPS` default 20.
4. Sanity: if `quote.buyAmount ≤ oracleFloor` the market is dislocated ≥ `rebalanceSlippageBps` from Chainlink — do not post; retry next poll; if persistent, rebuild unswapped.

### 6.3 Order payload
```jsonc
{
  "sellToken": "<excess leg>", "buyToken": "<other leg>",
  "receiver": "<balancer>",                       // module enforces receiver == balancer
  "sellAmount": "<sellAmountOrder>", "buyAmount": "<buyAmountLimit>",
  "validTo": now + ORDER_WINDOW,                   // §7 window invariants
  "appData": "<FULL appData JSON string>",         // must keccak to module.compoundAppData()
  "appDataHash": "<module.compoundAppData()>",     // defensive: API verifies match
  "feeAmount": "0",                                // module enforces feeAmount == 0
  "kind": "sell", "partiallyFillable": false,      // fill-or-kill, enforced on-chain
  "sellTokenBalance": "erc20", "buyTokenBalance": "erc20",
  "signingScheme": "eip1271",
  "signature": "<0x… abi.encode(GPv2Order.Data)>", // the module abi.decodes exactly this
  "from": "<balancer>"                             // order owner = the balancer contract
}
```
The `signature` bytes are the ABI encoding of the full `GPv2Order.Data` struct (the tuple the module decodes: `(address,address,address,uint256,uint256,uint32,bytes32,uint256,bytes32,bool,bytes32,bytes32)` with the `kind`/balance enums as their keccak constants). No key signs anything — validity is the module's live 1271 evaluation.

### 6.4 Polling and terminal states
Poll `GET /orders/{uid}` (and watch GPv2 `Trade` logs) every `POLL_SECONDS` (default 30).
- **Fulfilled** → REBUILD immediately (every in-flight minute is unstaked downtime).
- **Policy-expired**: treat the order as dead at `validTo − 5 min` — the module's settlement-time lower bound (`validTo ≥ now + 5 min`) makes later settlement impossible. Then either re-post (§6.5) or REBUILD unswapped.
- **API rejection at placement**: re-check `rebalanceInFlight == true`, `order.sellToken == sellTokenInFlight()` (the module hard-requires the order's sell leg to match the leg `unwindForSwap` approved — "sellToken must match in-flight approval"; a reverse-direction order is rejected even though the other token is a valid underlying), appData preimage/hash match, `balanceOf(sellToken) ≥ sellAmount`, allowance ≥ sellAmount, and that the checker path is configured (a `checkPrice` revert inside simulation reads as signature-verification failure).

### 6.5 Re-posting
EIP-1271 orders have no off-chain hard-cancel: orderbook cancellation only delists; a solver holding the order can still settle it until `validTo` while the window is open and allowance remains. Therefore: **at most one live order at a time**, and when re-posting after a policy-expiry, size so that `Σ sellAmounts of all orders whose validTo has not passed ≤ approval` — the allowance is the real serialization primitive. Total in-flight time across re-posts is bounded by the payback budget: stop re-posting once `elapsed × R_now_usd` approaches `swapCostUsd` headroom and rebuild unswapped.

### 6.6 Third-party orders (accepted residual risk)
While in flight, anyone can post a validating order against the approved principal; economics are floored at `rebalanceSlippageBps` (50 bps) below Chainlink. Direction is pinned by the module's explicit `sellToken == sellTokenInFlight()` require (defense-in-depth beyond allowance scoping); size is pinned by the exact-amount allowance. This is why the knob is tight and windows are short. Detection: a `Trade` with owner == balancer and uid ≠ ours. Response: none needed on-chain (the trade IS a fair-priced version of the intended swap) — recompute the remaining excess from balances and proceed to REBUILD.

## 7. Config invariants (assert at startup and before each SWAP cycle)

| Invariant | Why |
| --- | --- |
| `checker.maxTimePriceValid(WETH) and (cbBTC) < position.minRebalanceInterval` (6h) | Kills cross-cycle order replay: a cycle-N order must expire before cycle N+1's window can open. Suggested value 3600s. |
| `ORDER_WINDOW + 5 min ≤ maxTimePriceValid(sellToken)` | Module upper bound `validTo ≤ now + maxTimePriceValid` must admit the policy window (checked at placement AND settlement). |
| `module.rebalanceSlippageBps() ∈ (0, REBALANCE_SLIPPAGE_MAX]` (expect 50) | 0 = swap mode dark (safe but silent); shared-knob regression would reopen the 200 bps leak. |
| `balancer.swapLossAllowanceBps() == 300`, `maxRebalanceLossBps == 100` | Floor arithmetic the wedge playbook assumes. |
| `allowance(balancer → VAULT_RELAYER, both tokens) == 0` while idle | Approval-leak tripwire — nonzero when `rebalanceInFlight == false` means a closed window left residue (should be impossible; page ops). |
| `module.compoundAppData()` has a registered preimage: `GET /app_data/{hash}` == 200 | Placement uses the full JSON document (§6.3). Placeholder `keccak256("mamo-lpv2-compound")` = `0x4e685fb45a0eeffd9bed35e33c88cfcfa7fd6712902fed22a9b934df9a748efa` has NO valid preimage — launch blocker until replaced (§10). |
| `width % (2 × position.tickSpacing) == 0` for every planned width, and for `minWidth`/`maxWidth` | On-chain rule (§5). A width that is a plain `tickSpacing` multiple but an odd one reverts `InvalidWidth()` after the teardown on `rebuildAfterSwap`, wasting the cycle. Assert at startup against the live `position()` bounds, not against a hardcoded 100. |
| ETH/USD and BTC/USD `updatedAt` fresh within their OWN heartbeats | The balancer now bounds each feed separately — `maxOracleDelay0()` for ETH/USD, `maxOracleDelay1()` for BTC/USD (both seeded to `DEFAULT_MAX_ORACLE_DELAY` = 1 hour, capped at `MAX_ORACLE_DELAY` = 1 day, and armed at 3600s by proposal 011; retune via `setMaxOracleDelays`). Assert each read against its own getter, never one shared value. Still refuse to `unwindForSwap` on feeds older than `FEED_FRESHNESS_MAX` (default 2× heartbeat); a frozen feed makes the value floor a no-op. |
| `sequencerUptimeFeed() != address(0)` and `sequencerGracePeriod() != 0` | **The guard now lives on-chain** (`checkSequencer` runs ahead of every Chainlink read) — but it is DISABLED by default and armed only by the 011 setup proposal. A zero feed is a silently-off guard indistinguishable from "never wired": treat it as a launch blocker, and alert if it ever reads zero afterwards. Expect `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` / `3600`. |
| Base sequencer healthy for ≥ `sequencerGracePeriod()` | The contract fails closed with `SequencerDown()` / `SequencerGracePeriod()`, so the backend is no longer the only control — but it should still gate proactively rather than burn gas on a guaranteed revert. Keep `MOONWELL_LP_SEQUENCER_GRACE_S` ≥ the on-chain value. |
| No admin config changes mid-cycle | `setOracles`/`setMaxOracleDelays`/`setSequencerUptimeFeed`/`setPositionConfig`/`setGauge` mid-flight rebase the two-transaction floor. Watch the config events (`OraclesUpdated`, `MaxOracleDelaysUpdated`, `SequencerUptimeFeedUpdated`, `PositionConfigUpdated`, `GaugeUpdated`); if one fires while in flight, alert and prefer rebuild-unswapped. |

## 8. Monitoring, alerting, failure playbook

Watchdogs (every poll): in-flight age (`now − rebalanceStartedAt`; WARN > `ORDER_WINDOW + 15 min`, PAGE > 2h), idle-approval tripwire (§7), unstaked-while-idle (`mainStaked == false` for > 1h with `hasGauge` — emissions bleeding), unswept AERO (`earnedAero > MOONWELL_LP_MAX_UNSWEPT_AERO`), paused flag, config-event stream.

| Condition | Automated response | Escalation |
| --- | --- | --- |
| `TwapDeviation` on unwind (idle) | Skip cycle; retry next sweep. | — |
| `TwapDeviation` on rebuild (in flight) | Backoff retry 5→15→30 min. Volatility gates the mint on purpose. | WARN at 1h in flight; PAGE at 2h. |
| **`ValueFloor` on rebuild (§8.2)** | Predict it from `rebalanceAmountsBefore()` priced at CURRENT feeds, keeping the position/loose split (formula in §8.2). Retry every 15 min while the margin trends up. | If it trips from a market drop: alert with the three Safe options — wait it out (funds are loose tokens, no IL, only AERO downtime), raise `swapLossAllowanceBps` (≤500) / `maxRebalanceLossBps` (≤500, MANAGER), or `exit(SAFE)`. Never spam retries during a crash — each costs gas and mints/burns nothing. |
| `TickMismatch` on rebuild | Re-read `slot0()`, recompute `expectedTickLower`/`expectedTickUpper` (§2.2), resubmit immediately. Expected under ordinary drift; budget one or two retries per cycle. | Persistent mismatch across several blocks ⇒ spot is being pushed. Back off, re-check `deviationGateOpen`, and do not loosen the commitment. |
| `SequencerDown` / `SequencerGracePeriod` | Freeze all writes. Poll the uptime feed; resume only once it reads up AND `block.timestamp − startedAt ≥ sequencerGracePeriod()`. | PAGE on `SequencerDown`. Mid-flight this is survivable — the window stays open and rebuild is retriable — but `exit(SAFE)` also reads no oracles if teardown becomes urgent. |
| Mint slippage revert (NFPM `Price slippage check`) | Distinct from ValueFloor — recompute mint mins at fresh spot and retry once. | Recurring ⇒ tolerance too tight; bump `MINT_TOLERANCE_BPS`. |
| `StaleOracle` anywhere | Do nothing on-chain. | PAGE — feed outage. `exit` reads no oracles (0-min emergency path) so it still works if teardown becomes urgent, but a feed outage alone rarely warrants it. |
| `EnforcedPause` | Freeze all writes, keep read-only monitoring. | Notify; guardian decides. If paused mid-flight: funds sit loose on the balancer; `exit` (Safe) is the only mover. |
| Backend key dark mid-flight | (Nothing runs.) | Runbook: Safe `exit(SAFE)` — the ONLY mid-flight escape. `withdrawPosition`/`deregisterPosition` revert mid-flight and do not clear the window — do not reach for them. |
| Order placement 4xx repeatedly | §6.4 checklist; verify checker config + appData registration. | Ops if config regressed. |
| Unknown revert selector | Stop the branch, dump revert data + tx, no blind retries. | PAGE. |

**§8.2 ValueFloor wedge, spelled out.**

Predicting the floor from the CURRENT ABI (this replaces the removed-getter recipe):

```python
a0Pos, a1Pos, l0, l1 = balancer.rebalanceAmountsBefore()   # RAW token amounts, token decimals
p0, p1               = chainlink(ETH_USD), chainlink(BTC_USD)   # read NOW, not at unwind

usd = lambda a0, a1: a0 * p0 // 10**dec0 + a1 * p1 // 10**dec1   # 1e8 scale, both feeds fresh

lossBps   = maxRebalanceLossBps + swapLossAllowanceBps            # 100 + 300 = 400
floorUsd  = usd(a0Pos, a1Pos) * (10_000 - lossBps) // 10_000 + usd(l0, l1)
valueNow  = usd(balanceOf(token0), balanceOf(token1))             # mid-flight: principal is loose
rebuild_will_revert = valueNow < floorUsd
```

Two things this gets right that the old USD-getter recipe could not. **(1)** Both sides are priced at
the SAME feed reads, so a market move between unwind and rebuild cancels instead of reading as a
rebalance loss — that is exactly why the snapshot became amounts. Do not cache prices from unwind
time. **(2)** The haircut applies to the POSITION term only; `usd(l0, l1)` is added back whole. Using
a single combined "value before" over-predicts a revert whenever loose value was present at unwind.

The wedge itself is unchanged in character: with the position term haircut 4%, a basket drop beyond
that mid-flight makes rebuild revert *even with zero execution loss*; the position is then loose
WETH+cbBTC on the balancer (no LP, no IL, earning nothing). The floor is soft — rebuild is retriable
forever and has no cooldown — so the default play is patience plus alerting; the Safe levers are for
extended drawdowns. Symmetrically, a pump masks up to `floor` of real loss: the backend must
therefore compute and log **realized execution shortfall** (`fill buyAmount` vs Chainlink mid at fill
time) per cycle so leakage is measured off-chain rather than inferred from the floor.

Residual the contract documents and the backend must respect: both snapshot terms are taken in the
PRIOR transaction, so a token donated to the balancer between `unwindForSwap` and `rebuildAfterSwap`
inflates `valueNow` without inflating either term, widening apparent headroom by the donated amount.
Not an extraction vector, but it means the floor is a weaker guarantee here than on the atomic
`rebalanceUsingAlt` path — the realized-shortfall log is the real measurement.

## 9. Compound and staking policy

- `compound(COMPOUND_BPS)` on the sweep cadence when `earnedAero × aeroUsd > COMPOUND_MIN_USD` and idle. The module sells AERO → underlying via its own (always-open, `allowedSlippageInBps` = 200 bps) 1271 path with proceeds to the balancer; they fold into the next rebuild/rebalance mint. Don't call mid-flight (both legs unstaked ⇒ nothing harvests ⇒ `NothingToCompound` unless loose AERO happens to sit on the balancer); don't leave AERO pooling on the module (its relayer approval is standing `type(uint256).max` — forward-and-swap promptly).

### 9.1 Weekly MAMO drop share

`compound(uint16 compoundBps)` (in `LPAutoBalancerV2.sol`) is the drop-share knob: each harvest sends `(10000 − compoundBps)/10000` of the claimed AERO to the `feeCollector` (DROP_AUTOMATION → the weekly MAMO drop) and forwards the rest to the compound module for reinvestment. Principal is never touched — rewards and LP liquidity are fully segregated, and no privileged withdrawal is involved.

- **Default flow favors the drop.** Every AERO path that is NOT `compound()` already routes 100% to DROP_AUTOMATION: `claimEmissions()` (now `REBALANCER_ROLE`-gated — see §1), and the auto-skims inside `unstake`, both rebalance flavors, and `unwindForSwap`'s teardown. `compound()` exists to carve out the *reinvest* share, not to enable the drop share. Because the claim is no longer permissionless, the backend is the only thing that calls it: put it on the sweep cadence rather than assuming an external bot keeps the gauge drained.
- **Policy knob.** `MOONWELL_LP_COMPOUND_BPS` (default `7000` → 30% of each harvest to the weekly drop). Per-call, full 0–10000 range; changing weekly policy is an env change, no transaction.
- **Drop-day scheduling.** Guarantee at least one harvest inside the 24h before the weekly drop snapshot so the week's accrued AERO is included: call `compound(COMPOUND_BPS)` (or, if the reinvest leg is inert — checker/appData prerequisites pending — plain `claimEmissions()`). If a swap-rebalance is in flight at the cutoff, skip: the unwind's teardown already skimmed all pending AERO to the drop, and a mid-flight `compound()` reverts `NothingToCompound`.
- **Measurement (policy is not protocol).** The split is chosen per call by the REBALANCER hot key — the contract does not store or enforce it (an on-chain `minDropShareBps` clamp was considered and declined for phase-1). Monitor realized share from events over each drop week:
  `realizedDropShare = (Σ EmissionsClaimed.amount + Σ CompoundInitiated.droppedAmount) / (Σ EmissionsClaimed.amount + Σ CompoundInitiated.droppedAmount + Σ CompoundInitiated.compoundAmount)`
  (`EmissionsClaimed(uint256)` covers claims and auto-skims; `CompoundInitiated(uint256 compoundAmount, uint256 droppedAmount, uint16 compoundBps)` covers explicit splits — note `compound()` also emits `EmissionsClaimed` for its drop leg, so dedupe by tx hash: within a `CompoundInitiated` tx, count the drop leg once). Alert when it deviates from `1 − COMPOUND_BPS/10000` by more than `MOONWELL_LP_DROP_SHARE_TOL_BPS`. Both destinations are value-preserving, so a key compromise can skew the split but not extract — the monitor is the detection layer.
- Compound proceeds or donations landing mid-flight inflate `valueAfter` and loosen the floor by that amount (documented contract limitation) — harmless, but the §8.2 realized-shortfall log keeps measurement honest.
- `stake()` immediately after any rebuild/rebalance leaves `mainStaked == false` unexpectedly (restake is automatic iff staked at teardown; the phase-1 handover starts unstaked until the APR gather is wired). Hysteresis on stake/unstake flips: `MOONWELL_LP_HYSTERESIS_BPS`.

## 10. Pre-launch checklist (blocking, in order)

```bash
RPC=$BASE_RPC_URL; SETTLE=0x9008D19f58AAbD9eD0D60971565AA8510560ab41
CHECKER=0x5A8F10be44E25Bb21492C5f46DA94cDb1f0b2fF6

# 1. Domain separator matches the module constant (verified 2026-07-03: 0xd72ffa78…57b4b)
cast call $SETTLE "domainSeparator()(bytes32)" --rpc-url $RPC

# 2. Checker owner (MAMO_MULTISIG) deferred tx has landed — WETH<->cbBTC both directions + AERO pairs
cast call $CHECKER "getExpectedOut(uint256,address,address)(uint256)" 1000000000000000000 $WETH $CBBTC --rpc-url $RPC   # reverts "Token pair not configured" until done
cast call $CHECKER "maxTimePriceValid(address)(uint256)" $WETH  --rpc-url $RPC   # expect 0 < v < 21600, e.g. 3600
cast call $CHECKER "maxTimePriceValid(address)(uint256)" $CBBTC --rpc-url $RPC

# 3. appData: generate a PLAIN {appCode:"Mamo"} doc via @cowprotocol/app-data (MetadataApi.generateAppDataDoc
#    + appDataKeccak256 — see test/utils/generate-appdata.ts for the library usage, but WITHOUT its
#    transferFrom pre-hook: lpv2 takes fees via the on-chain compound split, and feeAmount==0 is enforced),
#    register it, and point the module at it
curl -X PUT https://api.cow.fi/base/api/v1/app_data/$HASH -d "$FULL_APP_DATA_JSON"   # 200/201
# F-MAMO: module.setCompoundAppData($HASH)  — replaces the 011 placeholder
#         0x4e685fb45a0eeffd9bed35e33c88cfcfa7fd6712902fed22a9b934df9a748efa

# 4. Module knobs + relayer approval
cast call $MODULE "rebalanceSlippageBps()(uint256)" --rpc-url $RPC     # 50
cast call $MODULE "allowedSlippageInBps()(uint256)" --rpc-url $RPC     # 200
cast call $BALANCER "swapLossAllowanceBps()(uint16)" --rpc-url $RPC    # 300
# F-MAMO: module.approveCowSwap()  (after step 2's AERO config; reverts "Token not allowed" before)

# 5. Roles + read path
cast call $BALANCER "hasRole(bytes32,address)(bool)" $(cast keccak "REBALANCER_ROLE") $BACKEND_EOA --rpc-url $RPC
cast call $BALANCER "getDecisionSnapshot()" --rpc-url $RPC             # decodes, deviationGateOpen true

# 6. Post-audit ABI + guards (BLOCKING — a backend built to the pre-audit spec fails all of these)
cast call $BALANCER "rebalanceAmountsBefore()(uint256,uint256,uint256,uint256)" --rpc-url $RPC  # exists; 0,0,0,0 while idle
cast call $BALANCER "rebalanceValueBefore()(uint256)" --rpc-url $RPC   # MUST revert — getter removed
cast call $BALANCER "maxOracleDelay0()(uint256)" --rpc-url $RPC        # per-feed bounds exist
cast call $BALANCER "maxOracleDelay1()(uint256)" --rpc-url $RPC
cast call $BALANCER "sequencerUptimeFeed()(address)" --rpc-url $RPC    # 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433, NOT 0x0
cast call $BALANCER "sequencerGracePeriod()(uint256)" --rpc-url $RPC   # 3600, NOT 0
# rebuildAfterSwap must be the 8-field encoding:
cast sig "rebuildAfterSwap((uint24,uint256,uint256,uint256,uint256,uint256,int24,int24))"   # 0x44254680
```

6. **Fork dry-run** of one full SWAP cycle: `make lp-auto-balancer-v2` covers the contract legs; the backend end-to-end (quote → place → poll → rebuild) runs against a fork with the orderbook mocked, asserting the §3 recovery from a killed process at each step.
7. First live cycle at small TVL with `ORDER_WINDOW = 15 min` and a human watching the §8 dashboards.

## 11. Environment (extends runbook §C2)

| Env | Default | Meaning |
| --- | --- | --- |
| `MOONWELL_LP_AUTO_BALANCER` | — | Balancer address |
| `MOONWELL_LP_RPC_URL` | — | Base RPC (gate + agent) |
| `MOONWELL_LP_COW_API` | `https://api.cow.fi/base/api/v1` | Orderbook |
| `MOONWELL_LP_ORDER_WINDOW_S` | `1800` | CoW order validTo horizon (§7 invariants) |
| `MOONWELL_LP_POLL_S` | `30` | Order/status poll cadence |
| `MOONWELL_LP_IMBALANCE_MIN` | `0.10` | Below this, never swap |
| `MOONWELL_LP_PAYBACK_MAX_H` | `24` | Max AERO-payback horizon to justify a swap |
| `MOONWELL_LP_LIMIT_HAIRCUT_BPS` | `20` | Limit price haircut off the CoW quote |
| `MOONWELL_LP_APPROVE_BUFFER_BPS` | `200` | Approval headroom over computed excess |
| `MOONWELL_LP_WITHDRAW_TOL_BPS` / `_MINT_TOL_BPS` | `50` / `50` | Sandwich floors |
| `MOONWELL_LP_WIDTH_TICKS` | `200` | Main range width |
| `MOONWELL_LP_FEED_FRESHNESS_MAX_S` | 2× feed heartbeat | Unwind precondition |
| `MOONWELL_LP_SEQUENCER_GRACE_S` | `3600` | No swaps after sequencer recovery |
| `MOONWELL_LP_COMPOUND_BPS` | `7000` | Reinvest share per harvest; drop share = `10000 −` this (§9.1) |
| `MOONWELL_LP_DROP_SHARE_TOL_BPS` | `500` | Alert threshold on realized vs policy drop share (§9.1) |
| `MOONWELL_LP_HYSTERESIS_BPS` | `200` | Stake/unstake anti-flap (existing) |
| `MOONWELL_LP_MAX_UNSWEPT_AERO` | — | Compound trigger (existing) |
| `MOONWELL_LP_MAX_TURNS` | `3` | Agent turn budget (existing) |

Signer: `BACKEND_REBALANCER_EOA` private key provisioned inside the sandbox only; the workflow layer never holds it. The completion gate re-reads `getDecisionSnapshot()` + idle-invariants (§7) after every sweep and fails the run on divergence from the agent's report.

## 12. Out of scope

Cross-pool migration (phase-2), DropAutomation internals.

The contract-hardening backlog that the swap-rebalance design doc §8 tracked has largely LANDED in
the Sherlock remediation and is no longer out of scope — it is spec'd above: on-chain sequencer-uptime
feed (§7), per-feed oracle staleness bounds (§2.1), explicit `AlreadyInFlight` guards (§2.4). Still
open and still out of scope: heartbeat-scaled floor staleness, and raising the alt dust threshold
(`MIN_ALT_VALUE_USD` is $0.01).

Also accepted, not fixed: the residual documented at the end of §8.2 (mid-flight donations widening
the floor's apparent headroom), and the `_exitAll` commingling note — `unwindForSwap` tears down into
the same balance the pre-existing loose tokens sit in, so an oversized `sellAmount` can dip into them.
Size `sellAmount` from the position snapshot (`amount0Pos`/`amount1Pos`), never from the balancer's
whole balance.
