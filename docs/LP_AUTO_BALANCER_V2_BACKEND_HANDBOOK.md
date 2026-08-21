# LPAutoBalancerV2 — Backend Handbook (cbETH/WETH bootstrap)

**Audience:** the team building and running the offchain rebalancer service.
**Status:** bootstrap deployment, proposal `014_LPAutoBalancerV2CbETHBootstrap`.
**Measurements taken on Base, 2026-08-21; §3 re-measured 2026-08-22.** Numbers move — the stake/unstake winner already flipped once between those two dates. Re-measurement methods are inline; re-run §3 before fixing the allocation.

## Related documents

| Document | Role |
| --- | --- |
| [`LP_AUTO_BALANCER_V2.md`](LP_AUTO_BALANCER_V2.md) | System overview. Read first; this assumes its vocabulary. |
| [backend spec](superpowers/specs/2026-07-03-lp-auto-balancer-v2-backend-spec.md) | The operational contract: ABI, selectors, decision math, CoW lifecycle, error table. **Wins on every conflict** — this handbook is the venue layer on top. |
| [`LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md`](LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md) | Phase-1 WETH/cbBTC runbook (proposal 011). Different pair, different instance — do not copy its constants (§1.1). |
| `multisig/mamo-multisig/014_LPAutoBalancerV2CbETHBootstrap.sol` | The Safe proposal. Arms the §4 config; `validate()` asserts it. |
| `test/LPAutoBalancerV2CbETHBootstrap.integration.t.sol` | Fork proof — `make lp-v2-cbeth-bootstrap` |

`moonwell-fi/mamo-rebalancer` is the reference for *process shape* (§5), not for domain: it drives a leveraged strategy, so its `ADJUST_LEVERAGE` / `FULFILL_REDEEM` / health-and-LTV surface has no counterpart here.

---

## 1. The venue

Aerodrome Slipstream CL, Base. Addresses verified onchain 2026-08-21.

| Thing | Address / value |
| --- | --- |
| cbETH/WETH CL pool | `0x47cA96Ea59C13F72745928887f84C9F52C3D7348` |
| **tickSpacing** | **`1`** |
| Swap fee (`fee()`, pips) | `65` → 0.0065% |
| `unstakedFee` | `100000` → 10% cut on unstaked-position fees |
| CL gauge (`rewardToken` = AERO, alive) | `0xF5550F8F0331B8CAA165046667f4E6628E9E3Aac` |
| Gauge `nft()` | `0x827922686190790b37229fd06084350E74485b72` — the Slipstream NFPM the balancer uses |
| cbETH — **token0**, 18 dp | `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22` |
| WETH — **token1**, 18 dp | `0x4200000000000000000000000000000000000006` |
| Chainlink cbETH/USD — **oracle0**, 8 dp | `0xd7818272B9e248357d13057AAb0B417aF31E817d` |
| Chainlink ETH/USD — **oracle1**, 8 dp | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink AERO/USD | `0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0` |
| Chainlink L2 sequencer uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
| feeCollector | `DROP_AUTOMATION` in `addresses/8453.json` |
| Balancer | `MAMO_LP_AUTO_BALANCER_V2_CBETH` |
| Compound module | `MAMO_LP_COMPOUND_MODULE_CBETH` |

Token order is by address: cbETH (`0x2Ae3…`) < WETH (`0x4200…`), so **cbETH is token0**. Every `token0`/`token1`, `oracle0`/`oracle1`, `amount0`/`amount1`, `maxOracleDelay0`/`maxOracleDelay1` follows. The 011 deployment has WETH as token0 — a copied field mapping is silently wrong, not loudly wrong.

### 1.1 What differs from 011

1. **`tickSpacing` is 1, not 100.** The width grid is 100× finer; legal widths are even numbers (`width % (2 × tickSpacing) == 0`). 011's `minWidth 200 / maxWidth 20000` describe different geometry.
2. **Separate balancer instance.** One `LPAutoBalancerV2` manages one pool (`registerPosition` reverts `AlreadyRegistered` once active), so cbETH/WETH gets its own balancer and compound module. 011 is untouched.
3. **LST ratio, not two independent assets.** cbETH accrues staking yield against ETH, so the ratio drifts upward at `ln(1.0275)/ln(1.0001) ≈ 271 ticks/year ≈ 0.74 ticks/day` plus noise. Drift alone will not push a 50-tick band out of range for weeks; range exits here are depeg or liquidity events.
4. **Both feeds are ETH-correlated,** ~99% common-mode, so the USD value floor is far less noisy than on WETH/cbBTC. Hence 014's tighter `maxRebalanceLossBps` (50 vs 100) and `swapLossAllowanceBps` (100 vs 300).

### 1.2 Oracle heartbeats — measured, not assumed

Some LST feeds run a 24h heartbeat on other chains, and `MAX_ORACLE_DELAY` caps at 1 day — a 24h feed under a 3600s bound would brick every priced path.

Measured 2026-08-21: 501 consecutive rounds over 37.4 hours, **max inter-round gap 1290 s**. cbETH/USD behaves like a ~1200 s heartbeat, same as ETH/USD, so 3600 s tolerates two missed rounds.

Re-measure before any re-pin or new pair:

```bash
AGG=$(cast call 0xd7818272B9e248357d13057AAb0B417aF31E817d "aggregator()(address)" --rpc-url base)
LR=$(cast call $AGG "latestRound()(uint256)" --rpc-url base | awk '{print $1}')
seq $((LR-500)) $LR | xargs -P 20 -I{} sh -c \
  "echo {} \$(cast call $AGG 'getTimestamp(uint256)(uint256)' {} --rpc-url base | awk '{print \$1}')" \
  | sort -n | awk 'NF==2{if(p>0&&$2-p>m)m=$2-p; p=$2} END{print "max gap:", m, "s"}'
```

`latestRound()` on the **proxy** returns a phase-encoded id that overflows shell arithmetic — walk the aggregator.

---

## 2. Total allocation

`totalAllocationUsd` is a parameter of proposal 014 (8-decimal USD, matching `valueInUsd`), default $50,000:

```solidity
proposal.setTotalAllocation(50_000e8, 500);   // target, tolerance bps
```

`validate()` asserts the registered principal — priced with the balancer's own feeds, staleness bounds and sequencer guard at the pool's live `sqrtPriceX96` — lands inside `totalAllocationUsd ± allocationToleranceBps`. A position minted at half the intended size fails the proposal.

**Why it validates rather than mints.** FPS records `build()`'s actions as calldata and replays them at execution time. A `mint` inside `build()` returns a tokenId seen during *simulation*, but the NFPM tokenId is a global counter anyone's mint advances in between — the encoded `registerPosition(tokenId)` would name someone else's NFT.

### 2.1 Sizing the mint

For a tick-symmetric (hence log-price-symmetric) range around spot, the legs carry near-equal value:

```text
halfUsd = totalAllocationUsd / 2
amount0 (cbETH, 18dp) = halfUsd * 1e18 / chainlink(cbETH/USD)
amount1 (WETH,  18dp) = halfUsd * 1e18 / chainlink(ETH/USD)
```

At the pinned block the residual mismatch is 0.13%, so the NFPM consumes nearly all of both. `test_proposal_lifecycle` mints this way and passes `validate()` at 500 bps — proof the recipe works; `test_validate_rejectsWrongAllocation` is its non-vacuity control (same position, 2× target, must fail).

Read §3 before choosing the number.

---

## 3. Venue economics — read before sizing

Every figure below is reproducible from onchain reads.

**Slipstream is fees XOR emissions.** A staked position earns AERO and its swap fees divert to the gauge (`pool.gaugeFees()`); an unstaked one earns fees less the 10% `unstakedFee`. `stake()`/`unstake()` is a real economic choice, and it is `REBALANCER_ROLE` — the backend owns it.

Pool-level, measured 2026-08-22 (2026-08-21 in brackets — one day apart, to show how fast this moves):

| Quantity | Value |
| --- | --- |
| Pool TVL | ~$3.98 M *(3.86)* |
| 24 h volume | ~$3.67 M *(6.63)* |
| Fee income (0.0065%) | ~$239 / day → ~$215 net of `unstakedFee` *(431 → 388)* |
| Gauge emissions (`rewardRate` 8.3996e15 wei/s × AERO $0.475) | ~$345 / day *(347)* |

**Staked (AERO) beats unstaked (fees) by ~60%.** Volume roughly halved in a day while emissions held flat, which inverted the ranking — on 2026-08-21 unstaked led by 12%. So the backend's first live action is `stake()`, not a claim. 014 registers the position unstaked because `_store` forces `mainStaked = false` at registration; staking is the backend's call (§6.5), and at these numbers it should make it immediately.

Re-read this before go-live. A 2× volume swing flips the decision, and it took one day.

**The problem is concentration, not the pool.** In-range liquidity is `2.264e25`, 99.99% staked. One tick of it holds ~1,207 WETH against a pool balance of ~1,017 WETH — so effectively all incumbent liquidity sits within ~1–2 ticks of spot. Income accrues per unit of *liquidity*, not capital, and `L ∝ 1 / width`:

> **Gross APR ≈ 4.4% / `width_ticks`**, independent of allocation size while we are small relative to the pool.

| `width` | Band | Share of in-range L @ $50k | Gross | APR |
| --- | --- | --- | --- | --- |
| 2 | ±0.01% | ~0.85% | ~$2.93/day | ~2.14% |
| 6 | ±0.03% | ~0.28% | ~$0.98/day | ~0.71% |
| **50** (shipped `minWidth`) | ±0.25% | ~0.034% | ~$0.12/day | **~0.086%** |
| 100 | ±0.50% | ~0.017% | ~$0.06/day | ~0.043% |
| 200 | ±1.00% | ~0.0085% | ~$0.03/day | ~0.021% |
| Pool average | — | — | — | ~3.16% |

Consequences:

- At `minWidth` 50 the bootstrap earns ~$0.12/day on $50,000, against $0.05–0.10 of gas per `rebalanceUsingAlt`. The recenter gate (§6.3) will return `TOO_THIN` most of the time — that is the gate working.
- Competing on yield means 2–6 ticks, which collides with `minWidth > 2 × maxTickDeviation` (§4 — forces `maxTickDeviation ≤ 2`, an unusably tight calm gate) and with a 6 h cooldown against a band that exits on ordinary noise.
- **Recommendation:** run this as a mechanism proving-ground — $25–50k, width 50, ~0.1% APR expected, success measured as "ran unattended for N weeks, every guard fired when it should, no principal lost". Revisit the venue before raising `totalAllocationUsd`; raising it does not improve APR.

If the goal is yield rather than mechanism validation, this pool is the wrong venue at any prudent width.

---

## 4. The config 014 arms

| Field | Value | Why |
| --- | --- | --- |
| `tickSpacing` | `1` | The pool's. |
| `minWidth` | `50` | Closes the R7 branch-collision residual at config level: `minWidth > 2 × maxTickDeviation`. At `width == 2 × tickSpacing` the balanced and token1-single-sided tick pairs collide, so a spot push inside the calm gate turns a committed two-sided mint into a single-sided one with a zeroed mint minimum; only `width ≥ 4 × tickSpacing` rules that out for every caller. 011 declined it (doubles a 200-tick minimum); here it costs 50 ticks. `validatePosition()` asserts the inequality. |
| `maxWidth` | `2000` | ~22% wide — headroom for a depeg regime. |
| `maxTickDeviation` | `20` | Calm gate ~0.20%. Tight because both legs are the same underlying. |
| `maxCenterDeviation` | `20` | Backstop on minted-range center vs spot. |
| `twapWindow` | `1800` | Pool observation cardinality is 1440 → ≥ 1440 blocks (~48 min); window covered. |
| `maxRebalanceLossBps` | `50` | Half of 011's. A no-swap rebuild on a correlated pair loses only rounding plus forwarded dust. |
| `minRebalanceInterval` | `21600` (6 h) | Sweep cadence; stops a buggy agent looping rebalances. |
| `maxOracleDelay0 / 1` | `3600 / 3600` | Two missed rounds on ~1200 s heartbeats (§1.2). Armed explicitly — the constructor default is byte-identical, so `validate()` alone cannot tell armed from inherited; the fork test arms non-default values to make the action observable. |
| `sequencerUptimeFeed` / grace | `0xBCF85224…` / `3600` | Ships **disabled** (`address(0)` makes `checkSequencer` a no-op). Armed before `registerPosition`, which probes both feeds. |
| `swapLossAllowanceBps` | `100` | Not 011's 300 — cbETH↔WETH executes inside a few bps, and a loose allowance is a loss the floor stops detecting, not one it prevents. |
| module `rebalanceSlippageBps` | `30` | The binding price floor on approved principal while `rebalanceInFlight`, since EIP-1271 placement is permissionless. Tighter than 011's 50: correlated feeds, 0.0065% pool fee. |
| module `allowedSlippageInBps` | `200` | AERO → underlying compound orders (reward-only). |

Operating width: **50** (`MOONWELL_LP_WIDTH_TICKS=50`) — even, inside `[50, 2000]`.

---

## 5. Process shape

Lift the shape from `mamo-rebalancer`; the domain underneath is smaller.

```text
src/
  index.ts            boot: env → client → preflight → loop
  preflight.ts        boot gate (§7) — refuses to run against a mis-wired balancer
  loop.ts             one tick: read → decide → actuate → verify → record; never throws
  reads/
    snapshot.ts       getDecisionSnapshot() + position() — ONE pinned block
    pool.ts           slot0, TWAP, liquidity curve
    prices.ts         cbETH/USD + ETH/USD + AERO/USD, freshness assertions
    gauge.ts          rewardRate, earned, staked liquidity
  decision/
    decide.ts         action priority (§6.1)
    range.ts          _mainRange reproduction + tick commitment (§6.2)
    params.ts         widths, mins, deadlines (§6.4)
  engine/
    gate.ts           economic recenter gate (§6.3)
  actuation/
    execute.ts        encode + send + receipt, one action per tick
    errors.ts         revert-selector decoding (backend spec §2.4)
  monitoring/
    completion.ts     post-write state diff proving the op did something
    health.ts         HTTP health endpoint
    notify.ts         Slack / Sentry
```

Rules carried over, each preventing a specific failure:

- **All reads pinned to ONE block.** `getDecisionSnapshot()` is atomic; everything else in the tick reads at the same `blockNumber`.
- **One onchain action per tick.** Priority resolves conflicts; never batch.
- **Stateless recovery.** Derive the phase from chain truth (`rebalanceInFlight`, relayer allowance, balances, orderbook) on every wake, never local memory. Spec §3 is normative.
- **First tick after boot is preview-only.** `--once` opts out so a fork drive can act on its single tick.
- **`DRY_RUN=true` by default.**
- **The tick never throws.** Benign declines (calm gate, cooldown, balance race) log and retry; anything else pages.
- **Degraded mode is a read-only hold.** Stale feed, sequencer down, or TWAP window uncovered ⇒ no writes until priced reads recover.
- **Completion gate.** After every write, re-read chain state independently and prove the op did what the decision intended (new tokenIds, `mainInRange`, `lastRebalance` stamped). Fail on divergence from the agent's report.
- **No env var gets a silent default.**

Not applicable (leveraged-strategy only): leverage/LTV/health, Moonwell reads, withdrawal queue, `deployIdle`, hedge drift.

---

## 6. Decision layer

### 6.1 Action priority

One action per tick, first match wins:

| # | Action | Fires when |
| --- | --- | --- |
| 1 | HOLD (degraded) | Either feed stale against **its own** bound, sequencer down or in grace, TWAP window uncovered, or paused. No writes. |
| 2 | RESUME (in-flight) | `rebalanceInFlight == true`. Swap-cycle recovery (spec §3). Should never happen at bootstrap — the swap path is dark (§8). Page. |
| 3 | REBALANCE | Main out of range, gate (§6.3) says `RECENTER`, `deviationGateOpen`, `cooldownRemaining == 0`. Always `rebalanceUsingAlt`. |
| 4 | COMPOUND / CLAIM | Idle, staked, `earnedAero × aeroUsd > COMPOUND_MIN_USD`. `claimEmissions()` is role-gated, so the backend is the only thing draining the gauge — put it on the sweep cadence. |
| 5 | STAKE / UNSTAKE | The §6.5 comparison flips by more than `MOONWELL_LP_HYSTERESIS_BPS`. |
| 6 | NOOP | Otherwise. |

### 6.2 Tick commitment (every rebalance)

`rebalanceUsingAlt` (12 fields) and `rebuildAfterSwap` (8) both end in `expectedTickLower` / `expectedTickUpper` and revert `TickMismatch()` unless the range the contract derives from live spot matches. Reproduce `_mainRange` exactly (spec §2.2 is normative). At `tickSpacing == 1`, `floorAlign(t) == t`:

```text
v0 = usd(cbETH balance), v1 = usd(WETH balance)   // 1e8, per-leg feeds

if min(v0, v1) >= MIN_MAIN_LEG_USD ($0.01):       // balanced straddle
    tickLower = spotTick - width/2 ;  tickUpper = tickLower + width
elif v0 >= v1:                                    // cbETH-majority, single-sided ABOVE spot
    tickLower = spotTick + 1 ;        tickUpper = tickLower + width
else:                                             // WETH-majority, single-sided AT/BELOW spot
    tickUpper = spotTick ;            tickLower = tickUpper - width
```

On `rebalanceUsingAlt` the principal is still in the positions, so those balances are what the teardown returns: `principalAmounts(mainTokenId) + principalAmounts(altTokenId)` at current `sqrtPriceX96`, plus loose balance. `getDecisionSnapshot()` gives ticks and liquidity for both legs.

`TickMismatch()` under ordinary drift is a retry: re-read `slot0()`, recompute, resubmit. Expect it more often than on 011 — one tick of drift is enough. Budget two or three per cycle; persistent mismatch across blocks means spot is being pushed, so back off and re-check `deviationGateOpen`. Never widen the commitment to whatever the contract computes — it exists because the amount minima cannot detect a shifted range.

### 6.3 Economic recenter gate

Port `mamo-rebalancer`'s `evaluateRecenterGate` unchanged in structure. Verdicts: `IN_RANGE`, `CLOCK_STARTING`, `TOO_THIN`, `PATIENT`, `RECENTER`.

- Drive off **gross** income, not net-of-IL carry. Out of range you earn $0 while still holding 100% of one leg, so the divergence you would re-incur in range is being incurred anyway; netting IL double-counts it and makes the keeper far too patient.
- `recenterCostUsd` is gas only — `rebalanceUsingAlt` performs no swap.
- `grossIncomeUsdDay < recenterCostUsd` ⇒ `TOO_THIN`: hold and flag. Per §3 that is the expected steady state; do not lower the cost multiplier to escape it.
- `CLOCK_STARTING` on the first out-of-range observation — hold a tick rather than react to a wick.

### 6.4 Parameters

- **Width** — `MOONWELL_LP_WIDTH_TICKS` (50). `minWidth ≤ width ≤ maxWidth` and `width % 2 == 0`, asserted against live `position()` bounds, never a hardcoded constant.
- **Withdraw mins** — per leg, `getAmountsForLiquidity(sqrtP, tickLower, tickUpper, liquidity) × (1 − 50 bps)`. Never 0, or the calm gate is the only sandwich backstop. Alt mins are 0 only when `hasAlt == false`.
- **Mint mins** — predicted in-ratio consumption at `spotTick`, haircut 50 bps. Size them: on the balanced branch the contract forwards both minima unchanged, and they are the only control for the in-bucket residual. `TickMismatch` pins *where* liquidity lands; the minima pin *how much of each leg*. Neither substitutes for the other. The contract force-zeroes the unfunded leg's minimum on a single-sided mint. (The Tenderly harness passes zeros for rig convenience — do not copy that.)
- **Deadline** — `now + 300` on every write.

### 6.5 Stake vs unstake

Both sides scale with the same liquidity share, so the comparison is pool-level:

```text
stakedUsdDay   = gauge.rewardRate() * 86400 * aeroUsd            * σ
unstakedUsdDay = feeRate_usd_day * (1 - unstakedFee/1e6)         * σ
```

`σ` is your in-range liquidity share. Flip only when the winner leads by more than `MOONWELL_LP_HYSTERESIS_BPS` (200), never mid-cycle. `unstake()` claims and skims AERO to the feeCollector; restake after a rebalance is automatic if the position was staked at teardown.

Staked leads by ~60% as of 2026-08-22, but it led the other way by 12% the day before — the gap is driven by pool volume, which halved overnight. Expect real flips, and expect the hysteresis to be what stops them thrashing.

---

## 7. Preflight — the boot gate

Assert against the live chain, not env — a wrong address must fail at boot, not quietly operate someone else's position. Hard failures aggregate and throw together; soft mismatches warn.

```bash
RPC=$BASE_RPC_URL
LAB=$MOONWELL_LP_AUTO_BALANCER          # MAMO_LP_AUTO_BALANCER_V2_CBETH

# 1. identity
cast call $LAB "position()" --rpc-url $RPC              # pool/tokens/tickSpacing/gauge/oracles
cast call $LAB "getDecisionSnapshot()" --rpc-url $RPC   # decodes; reverts NotActive if unregistered

# 2. guards ARMED (zero on a fresh deployment == guard OFF)
cast call $LAB "sequencerUptimeFeed()(address)" --rpc-url $RPC   # 0xBCF85224…, NOT 0x0
cast call $LAB "sequencerGracePeriod()(uint256)" --rpc-url $RPC  # 3600, NOT 0
cast call $LAB "maxOracleDelay0()(uint256)" --rpc-url $RPC       # 3600
cast call $LAB "maxOracleDelay1()(uint256)" --rpc-url $RPC       # 3600
cast call $LAB "swapLossAllowanceBps()(uint16)" --rpc-url $RPC   # 100

# 3. our role
cast call $LAB "hasRole(bytes32,address)(bool)" $(cast keccak "REBALANCER_ROLE") $BACKEND_EOA --rpc-url $RPC

# 4. post-audit ABI (a backend built to the pre-audit spec fails all of these)
cast call $LAB "rebalanceAmountsBefore()(uint256,uint256,uint256,uint256)" --rpc-url $RPC  # exists; zeros when idle
cast call $LAB "rebalanceValueBefore()(uint256)" --rpc-url $RPC   # MUST revert — getter removed
cast sig "rebuildAfterSwap((uint24,uint256,uint256,uint256,uint256,uint256,int24,int24))"  # 0x44254680

# 5. idle hygiene
cast call $LAB "rebalanceInFlight()(bool)" --rpc-url $RPC         # false
# allowance(balancer -> VAULT_RELAYER) MUST be 0 on both tokens while idle
```

Internal-consistency asserts — read from `position()`, never hardcode:

- `pool.token0()/token1()/tickSpacing()` equal the registered descriptor;
- `gauge.rewardToken() == AERO` and `gauge.pool() == position.pool`;
- `width % (2 × position.tickSpacing) == 0` for every planned width, and for `minWidth`/`maxWidth`;
- `minWidth > 2 × maxTickDeviation` (R7 closure — if this stops holding, the collision is live again);
- both feeds fresh against their own getter, never one shared value;
- sequencer up for at least `sequencerGracePeriod()`.

### 7.1 Deferred prerequisites

`CHAINLINK_SWAP_CHECKER_PROXY`'s owner is the MAMO multisig (`0x26c158A4…`), not F-MAMO, so three steps are a separate owner transaction:

1. **AERO reward config:** `addTokenConfiguration(AERO → cbETH)` and `(AERO → WETH)` using `CHAINLINK_AERO_USD` forward + cbETH/USD resp. ETH/USD reverse, plus `setMaxTimePriceValid(AERO, …)`. Until this lands AERO is not a reward token.
2. **Swap-rebalance pair:** `addTokenConfiguration(cbETH → WETH)` and `(WETH → cbETH)`, plus `setMaxTimePriceValid` for **both** tokens. Keep both < `minRebalanceInterval` (6 h) so a cycle-N order cannot settle in cycle N+1; 3600 s suggested.
3. **F-MAMO:** `module.approveCowSwap()` — reverts `"Token not allowed"` until (1) lands.

Plus **appData**: 014 ships the placeholder `keccak256("mamo-lpv2-compound-cbeth")`, which has no valid appData-JSON preimage while the orderbook demands the full document at placement. Before the first order of either kind, generate a plain `{appCode:"Mamo"}` document (no pre-hook — this system takes its cut via the onchain compound split and the module enforces `feeAmount == 0`), `PUT` it to `/app_data/{hash}`, and have F-MAMO call `setCompoundAppData(realHash)`.

Until (1) and (3) land, `compound(compoundBps)` still harvests AERO, drops the non-compound share to `feeCollector`, and forwards the rest to the module — only the CowSwap sell leg is inert, which is safe.

---

## 8. The swap path is dark at bootstrap

Do not call `unwindForSwap` / `rebuildAfterSwap` until §7.1 step 2 lands. `validateRebalanceOrder` calls `checkPrice` on the cbETH↔WETH pair, and an unconfigured pair reverts — so every cycle would tear the position down, place nothing, rebuild unswapped, and burn a full 6 h cooldown. Worse, `maxTimePriceValid == 0` collapses the module's `validTo ≤ now + maxTimePriceValid` bound against its own `validTo ≥ now + 5 min` floor: every order reverts even after the pair configs exist.

This costs nothing here. The pair is an LST ratio, so a principal-conserving re-range is essentially always sufficient. **Run ALT-only:** make `SWAP` unreachable in the decision engine and alert if `rebalanceInFlight` is ever true.

When the swap path is enabled later, spec §4/§6 governs unchanged. One venue note: size `sellAmount` from the position snapshot (`rebalanceAmountsBefore()`), never from `balanceOf(balancer)` — pre-existing loose balance is commingled at unwind, and slippage on it inflates loss against a floor sized to position value only.

---

## 9. Monitoring and failure playbook

| Watch | Threshold |
| --- | --- |
| `rebalanceInFlight` | any true at bootstrap ⇒ PAGE (§8) |
| Idle relayer allowance | non-zero on either token while `!rebalanceInFlight` ⇒ PAGE (approval leak) |
| Unstaked-while-idle | `mainStaked == false` > 1 h while the stake decision says stake ⇒ WARN |
| Unswept AERO | `earnedAero > MOONWELL_LP_MAX_UNSWEPT_AERO` ⇒ compound/claim |
| Out-of-range clock | `> MAX_OUT_OF_RANGE_HOURS` with the gate at `TOO_THIN` ⇒ WARN + review (§3 surfacing) |
| Guard regression | `sequencerUptimeFeed() == 0`, `sequencerGracePeriod() == 0`, or an oracle bound outside `(0, MAX_ORACLE_DELAY]` ⇒ PAGE |
| Config events mid-cycle | `OraclesUpdated`, `MaxOracleDelaysUpdated`, `SequencerUptimeFeedUpdated`, `PositionConfigUpdated`, `GaugeUpdated` ⇒ alert; never rebalance while one is in flight |
| Paused | `EnforcedPause()` ⇒ freeze writes, keep read-only monitoring |

Decode revert data before retrying (full table: spec §2.4). The ones you will see here:

| Error | Response |
| --- | --- |
| `TickMismatch()` | Expected. Re-read `slot0()`, recompute, resubmit. |
| `TwapDeviation()` | Calm gate closed. Skip the cycle; backoff-retry. |
| `Cooldown()` | Wait `cooldownRemaining`. |
| `StaleOracle()` | Do nothing onchain. PAGE — feed outage. The offending feed is stale against its own bound. |
| `SequencerDown()` / `SequencerGracePeriod()` | Freeze writes. Resume once the feed reads up **and** `now − startedAt ≥ sequencerGracePeriod()`. |
| `ValueFloor()` | Rare on the ALT path (atomic floor). If it fires, something moved principal — investigate, do not retry blindly. |
| `InvalidWidth()` / `WidthOutOfBounds()` | Backend bug — fix params, do not retry. |
| Unknown selector | Stop the branch, dump revert data + tx, PAGE. |

**Emergency levers, escalating:** `pause()` (guardian; blocks everything operational, leaves `exit` available) → `revokeRole(REBALANCER_ROLE, backendEOA)` → `exit(SAFE)` (admin, not pausable, works mid-flight; unstakes, withdraws, burns, returns all cbETH + WETH to the Safe).

---

## 10. Environment

Names are the backend spec §11 names verbatim, so there is one vocabulary across both documents.

| Env | Value | Note |
| --- | --- | --- |
| `MOONWELL_LP_AUTO_BALANCER` | `MAMO_LP_AUTO_BALANCER_V2_CBETH` | from `addresses/8453.json` after 014 |
| `MOONWELL_LP_COMPOUND_MODULE` | `MAMO_LP_COMPOUND_MODULE_CBETH` | |
| `MOONWELL_LP_RPC_URL` | Base RPC | |
| `MOONWELL_LP_WIDTH_TICKS` | `50` | even, inside `[minWidth, maxWidth]` |
| `MOONWELL_LP_WITHDRAW_TOL_BPS` / `_MINT_TOL_BPS` | `50` / `50` | sandwich floors — never 0 |
| `MOONWELL_LP_HYSTERESIS_BPS` | `200` | stake/unstake anti-flap (§6.5) |
| `MOONWELL_LP_MAX_UNSWEPT_AERO` | operator choice | compound trigger |
| `MOONWELL_LP_COMPOUND_BPS` | `7000` | reinvest share; drop share = `10000 −` this |
| `MOONWELL_LP_DROP_SHARE_TOL_BPS` | `500` | alert on realized vs policy drop share |
| `MOONWELL_LP_FEED_FRESHNESS_MAX_S` | `2400` | 2× the measured ~1200 s heartbeat (§1.2) |
| `MOONWELL_LP_SEQUENCER_GRACE_S` | `3600` | ≥ the onchain value |
| `MOONWELL_LP_SWEEP_INTERVAL_S` | `300` | monitoring cadence; the rebalance branch is gated by `cooldownRemaining`, not this |
| `DRY_RUN` | `true` until go-live | |
| `HEALTH_PORT` | `8080` | |

Swap-mode variables (`MOONWELL_LP_COW_API`, `_ORDER_WINDOW_S`, `_IMBALANCE_MIN`, `_PAYBACK_MAX_H`, `_LIMIT_HAIRCUT_BPS`, `_APPROVE_BUFFER_BPS`) stay unset at bootstrap (§8).

`BACKEND_REBALANCER_EOA` is provisioned inside the sandbox only; the workflow layer never holds it.

---

## 11. Go-live checklist

1. `make lp-v2-cbeth-bootstrap` green on a pinned fork.
2. Re-run the §1.2 heartbeat measurement; confirm `maxOracleDelay0` still tolerates ≥ 2 missed rounds.
3. Re-run the §3 economics reads; agree the allocation with that table in front of you.
4. Safe mints the cbETH/WETH NFT offchain at the agreed size (§2.1); record `INIT_TOKEN_ID`.
5. Run 014 with `setTokenId`, `setRebalancerEOA`, `setTotalAllocation` — `validate()` must pass, allocation band included.
6. Preflight (§7) green, including every guard-armed read.
7. Checker-owner transaction (§7.1) — needed for AERO compounding, not for ALT-only operation.
8. Dry-run soak: one full sweep cadence, completion gate agreeing with the agent's report on every tick.
9. Flip `DRY_RUN=false` with a human watching. First live action should be `stake()` (§3), then `claimEmissions`/`compound` — not a rebalance.
10. Confirm AERO routing lands in `DROP_AUTOMATION` and the realized drop share matches `1 − COMPOUND_BPS/10000` within tolerance.
