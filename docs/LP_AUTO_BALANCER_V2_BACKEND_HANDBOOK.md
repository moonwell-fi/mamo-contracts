# LPAutoBalancerV2 — Backend Handbook (cbETH/WETH bootstrap)

**Audience:** the team building and running the off-chain rebalancer service.
**Status:** handbook for the bootstrap deployment (proposal `014_LPAutoBalancerV2CbETHBootstrap`).
**Measurements in this document were taken on Base at block 50,264,168 / 50,200,000 (2026-08-21).** Numbers move; the *methods* for re-measuring them are given inline, and §3 in particular must be re-run before the allocation is fixed.

## How this fits with the other documents

| Document | Role | Relationship to this one |
| --- | --- | --- |
| [`LP_AUTO_BALANCER_V2.md`](LP_AUTO_BALANCER_V2.md) | System overview: architecture, state machines, trust model | Read it first. This handbook assumes its vocabulary. |
| [backend spec](superpowers/specs/2026-07-03-lp-auto-balancer-v2-backend-spec.md) | **The operational contract**: exact ABI, selectors, decision math, CoW lifecycle, error table | **It wins on every conflict.** This handbook is the venue-specific layer on top; where it restates the spec it is a convenience, not a second source of truth. |
| [`LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md`](LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md) | Phase-1 WETH/cbBTC runbook (proposal 011) | A *different* pair on a *different* balancer instance. Do not copy its constants — see §1. |
| `multisig/mamo-multisig/014_LPAutoBalancerV2CbETHBootstrap.sol` | The Safe proposal that stands this deployment up | The config values in §4 are the ones it arms; `validate()` asserts them. |
| `test/LPAutoBalancerV2CbETHBootstrap.integration.t.sol` | Fork proof of the whole proposal + an operable rebalance | `make lp-v2-cbeth-bootstrap` |

`moonwell-fi/mamo-rebalancer` is the reference implementation for *process shape* — boot gate, one-action-per-tick loop, degraded mode, completion gate, stateless recovery. §5 maps its module layout onto this contract. It drives a **leveraged** Aerodrome strategy; this one has no leverage, no borrowing, no Moonwell leg, and no withdrawal queue, so everything in its `ADJUST_LEVERAGE` / `FULFILL_REDEEM` / health-and-LTV surface has no counterpart here.

---

## 1. The venue

Aerodrome Slipstream CL, Base. All addresses verified on-chain 2026-08-21.

| Thing | Address / value |
| --- | --- |
| cbETH/WETH CL pool | `0x47cA96Ea59C13F72745928887f84C9F52C3D7348` |
| **tickSpacing** | **`1`** |
| Swap fee (`fee()`, pips) | `65` → **0.0065%** (from the factory's swap-fee module `0x090b2A6b…`) |
| `unstakedFee` | `100000` → 10% cut on unstaked-position fees |
| CL gauge (`rewardToken` = AERO, alive) | `0xF5550F8F0331B8CAA165046667f4E6628E9E3Aac` |
| Gauge `nft()` | `0x827922686190790b37229fd06084350E74485b72` — the Slipstream NFPM, same one the balancer is deployed against |
| cbETH — **token0**, 18 dp | `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22` |
| WETH — **token1**, 18 dp | `0x4200000000000000000000000000000000000006` |
| Chainlink cbETH/USD — **oracle0**, 8 dp | `0xd7818272B9e248357d13057AAb0B417aF31E817d` |
| Chainlink ETH/USD — **oracle1**, 8 dp | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink AERO/USD (compound sizing) | `0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0` |
| Chainlink L2 sequencer uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
| feeCollector (drop sink) | `DROP_AUTOMATION` in `addresses/8453.json` |
| Balancer instance | `MAMO_LP_AUTO_BALANCER_V2_CBETH` (registered by proposal 014) |
| Compound module | `MAMO_LP_COMPOUND_MODULE_CBETH` |

**Token order is by address: cbETH (`0x2Ae3…`) < WETH (`0x4200…`), so cbETH is token0.** Every `token0`/`token1`, `oracle0`/`oracle1`, `amount0`/`amount1`, `maxOracleDelay0`/`maxOracleDelay1` field follows that. The 011 WETH/cbBTC deployment has WETH as token0; the two are *not* interchangeable and a copied field mapping is silently wrong rather than loudly wrong.

### 1.1 What differs from the WETH/cbBTC phase-1 deployment

Do not port 011's constants. Four structural differences:

1. **`tickSpacing` is 1, not 100.** The entire width grid is 100× finer. Legal widths are even numbers (the contract requires `width % (2 × tickSpacing) == 0`); 011's `minWidth 200 / maxWidth 20000` describe a completely different geometry.
2. **A separate balancer instance.** One `LPAutoBalancerV2` manages exactly one pool — the state is a single `position` struct and `registerPosition` reverts `AlreadyRegistered` once active. cbETH/WETH therefore gets its own balancer *and* its own compound module. Proposal 011 is untouched.
3. **The pair is an LST ratio, not two independent assets.** cbETH accrues staking yield against ETH, so the ratio *drifts monotonically upward* at roughly `ln(1.0275)/ln(1.0001) ≈ 271 ticks/year ≈ 0.74 ticks/day`, with small noise around it. Drift alone will not push a 50-tick band out of range for weeks. Range exits here are depeg/liquidity events, not ordinary price action.
4. **Both feeds are ETH-correlated.** A cbETH/USD move and an ETH/USD move are ~99% common-mode, so the USD value floor is far less noisy than on WETH/cbBTC. That is why 014 ships a tighter `maxRebalanceLossBps` (50 vs 100) and a tighter `swapLossAllowanceBps` (100 vs 300).

### 1.2 Oracle heartbeats — measured, not assumed

`maxOracleDelay0 = 3600` is only safe if cbETH/USD actually publishes faster than that. Some LST feeds run a 24h heartbeat on other chains, and the balancer's `MAX_ORACLE_DELAY` ceiling is 1 day — a 24h-heartbeat feed under a 3600s bound would brick every priced path.

Measured on Base 2026-08-21: **501 consecutive rounds spanning 37.4 hours, maximum inter-round gap 1290 s.** cbETH/USD behaves like a ~1200 s heartbeat feed, the same cadence as ETH/USD. 3600 s therefore tolerates two consecutive missed rounds.

Re-measure before any re-pin, and before extending this deployment to a new pair:

```bash
AGG=$(cast call 0xd7818272B9e248357d13057AAb0B417aF31E817d "aggregator()(address)" --rpc-url base)
LR=$(cast call $AGG "latestRound()(uint256)" --rpc-url base | awk '{print $1}')
seq $((LR-500)) $LR | xargs -P 20 -I{} sh -c \
  "echo {} \$(cast call $AGG 'getTimestamp(uint256)(uint256)' {} --rpc-url base | awk '{print \$1}')" \
  | sort -n | awk 'NF==2{if(p>0&&$2-p>m)m=$2-p; p=$2} END{print "max gap:", m, "s"}'
```

Note `latestRound()` on the **proxy** returns a phase-encoded id that overflows shell arithmetic — walk the **aggregator**, as above.

---

## 2. Total allocation

`totalAllocationUsd` is a parameter of proposal 014 (8-decimal USD, matching the balancer's own `valueInUsd` scale), default **$50,000**, set per run:

```solidity
proposal.setTotalAllocation(50_000e8, 500);   // target, tolerance bps
```

`validate()` asserts the registered position's principal — priced with the same feeds, the same staleness bounds and the same sequencer guard the balancer itself uses, at the pool's live `sqrtPriceX96` — lands inside `totalAllocationUsd ± allocationToleranceBps`. A position minted at half the intended size fails the proposal.

**Why the proposal validates the size rather than minting it.** FPS records `build()`'s actions as calldata and replays them at Safe-execution time. A `mint` inside `build()` returns a tokenId observed during *simulation*, but the Slipstream NFPM's tokenId is a global counter that anyone's mint advances in between — the encoded `registerPosition(tokenId)` would name someone else's NFT. Minting off-chain and asserting the resulting **size** is the only form of this parameter that cannot silently bind the wrong token.

### 2.1 Sizing the mint

For a **tick-symmetric** range around spot (which is log-price-symmetric), the two legs carry very nearly equal value, so:

```text
halfUsd = totalAllocationUsd / 2
amount0 (cbETH, 18dp) = halfUsd * 1e18 / chainlink(cbETH/USD)
amount1 (WETH,  18dp) = halfUsd * 1e18 / chainlink(ETH/USD)
```

At the pinned test block the residual mismatch between the two legs is **0.13%**, so the NFPM consumes essentially all of both and the minted principal lands within a few tenths of a percent of the target. `test_proposal_lifecycle` mints this way and then passes `validate()` at a 500 bps band — that is the proof the recipe works, not an assumption. `test_validate_rejectsWrongAllocation` is its non-vacuity control: the same position against a 2× target must fail.

**Read §3 before choosing the number.**

---

## 3. Economics of this venue — read before sizing the allocation

This section is the reason to think twice about cbETH/WETH, and every figure is reproducible from the reads above.

**Aerodrome Slipstream is fees XOR emissions.** A position staked in the gauge earns AERO and its swap fees are diverted to the gauge (`pool.gaugeFees()` accumulates them); an unstaked position earns swap fees less the 10% `unstakedFee`. `stake()`/`unstake()` is therefore a genuine either/or economic decision, and it is a `REBALANCER_ROLE` call — the backend owns it.

Pool-level, measured 2026-08-21:

| Quantity | Value |
| --- | --- |
| Pool TVL | ~$3.86 M |
| 24 h volume | ~$6.63 M |
| Fee income (0.0065%) | ~$431 / day → ~$388 / day net of `unstakedFee` |
| Gauge emissions (`rewardRate` 8.3996e15 wei/s × AERO $0.478) | ~$347 / day |

So at current prices **unstaked (fees) beats staked (AERO) by ~12%** — a close call that flips with the AERO price. Proposal 014 registers the position **unstaked**, which is the right starting state.

**The problem is concentration, not the pool.** In-range liquidity is `2.264e25`, and 99.99% of it is staked. Working the geometry backwards, one tick of that liquidity holds ~1,207 WETH against a pool balance of ~1,017 WETH: **effectively all incumbent liquidity sits within ~1–2 ticks of spot.** Income accrues per unit of *liquidity*, not per unit of capital, and for fixed capital `L ∝ 1 / width`. Hence:

> **Effective gross APR ≈ 4.7% / `width_ticks`** (staked, at the measured emission rate and AERO price; the unstaked/fee figure is within ~12% of it). This is **independent of the allocation size** while we are small relative to the pool.

| `width` (ticks) | Band | Our share of in-range L @ $50k | Gross income | Gross APR |
| --- | --- | --- | --- | --- |
| 2 | ±0.01% | ~0.92% | ~$3.2 / day | ~2.3% |
| 6 | ±0.03% | ~0.31% | ~$1.1 / day | ~0.78% |
| **50** (shipped `minWidth`) | ±0.25% | ~0.037% | ~$0.13 / day | **~0.093%** |
| 100 | ±0.50% | ~0.018% | ~$0.06 / day | ~0.047% |
| Pool average | — | — | — | ~3.3% |

**Consequences you must design around, not discover in production:**

- At the shipped `minWidth` of 50 the bootstrap earns on the order of **$0.13/day on $50,000**. A `rebalanceUsingAlt` on Base costs roughly $0.05–0.10 in gas, and it unstakes, burns two NFTs, mints two, and restakes. **The economic recenter gate (§6.3) will correctly return `TOO_THIN` most of the time.** That is the gate working, not a bug.
- Competing on yield here means operating at 2–6 ticks. That collides with two safety choices: `minWidth > 2 × maxTickDeviation` (the R7 closure, §4) forces `maxTickDeviation ≤ 2`, which is an unusably tight calm gate, and a 2–6 tick band exits range on ordinary noise against a 6 h `minRebalanceInterval`, so the position would be out of range — earning zero — for much of each cooldown.
- **Recommendation.** Ship the bootstrap as a **mechanism proving-ground**: small allocation ($25–50k), width at `minWidth` = 50, expectations set at ~0.1% APR, and success measured as "the loop ran unattended for N weeks, every guard fired when it should, no principal was lost". Treat any yield as incidental. Revisit the venue (or the width/deviation pair, with a fresh R7 analysis) **before** increasing the allocation — `totalAllocationUsd` is exactly the knob for that conversation, and raising it does not improve the APR.

If the goal is yield rather than mechanism validation, this pool is the wrong venue at any prudent width, and that conclusion should be taken before capital moves rather than after.

---

## 4. The on-chain config proposal 014 arms

| Field | Value | Why this value on this venue |
| --- | --- | --- |
| `tickSpacing` | `1` | The pool's. |
| `minWidth` | `50` | **Config-level closure of the R7 branch-collision residual**: `minWidth > 2 × maxTickDeviation`. At `width == 2 × tickSpacing` the balanced tick pair and the token1-single-sided pair collide, so a spot push *inside* the calm gate turns a committed two-sided mint into a single-sided one with a zeroed mint minimum. Only `width ≥ 4 × tickSpacing` rules it out for every caller. 011 declined this closure because it doubles a 200-tick minimum; here it costs 50 ticks, so it is bought outright. `validatePosition()` asserts the inequality so a later edit cannot quietly reopen it. |
| `maxWidth` | `2000` | ~22% wide — headroom for a manager to widen into a depeg regime. |
| `maxTickDeviation` | `20` | Calm gate, ~0.20%. Tight because both legs are the same underlying asset. |
| `maxCenterDeviation` | `20` | Backstop on the minted range's center vs spot. |
| `twapWindow` | `1800` | The pool's observation cardinality is 1440, so a full ring spans ≥ 1440 blocks (~48 min at 2 s) — the window is covered. |
| `maxRebalanceLossBps` | `50` | Half of 011's. A no-swap rebuild on a correlated pair loses only pool rounding plus forwarded dust. |
| `minRebalanceInterval` | `21600` (6 h) | Sweep cadence; also stops a buggy agent looping rebalances. |
| `maxOracleDelay0 / 1` | `3600 / 3600` | Two missed rounds on ~1200 s heartbeats (§1.2). Armed explicitly and asserted — the constructor default is byte-identical, so an inherited value would be indistinguishable from an armed one in `validate()` alone; the fork test arms non-default values to make the action observable. |
| `sequencerUptimeFeed` / grace | `0xBCF85224…` / `3600` | The guard ships **disabled** (`address(0)` makes `checkSequencer` a no-op). Armed **before** `registerPosition`, which probes both feeds. |
| `swapLossAllowanceBps` | `100` | Not 011's 300 — cbETH↔WETH executes inside a few bps, and a loose allowance is a loss the floor stops detecting, not a loss it prevents. |
| module `rebalanceSlippageBps` | `30` | The binding price floor on the whole approved principal while `rebalanceInFlight`, because EIP-1271 placement is permissionless. Tighter than 011's 50: both legs price off ETH-correlated feeds and the pool fee is 0.0065%. |
| module `allowedSlippageInBps` | `200` | AERO → underlying compound orders (reward-only). |

**Operating width for the backend: `50`** (`MOONWELL_LP_WIDTH_TICKS=50`). Legal — even, and inside `[50, 2000]`.

---

## 5. Process shape

Lift the shape from `mamo-rebalancer`; the domain underneath is different and much smaller.

```text
src/
  index.ts            boot: env → client → preflight → loop
  preflight.ts        the boot gate (§7) — refuses to run against a mis-wired balancer
  loop.ts             one tick: read → decide → actuate → verify → record; never throws
  reads/
    snapshot.ts       getDecisionSnapshot() + position() — ONE pinned block
    pool.ts           slot0, TWAP, liquidity curve
    prices.ts         cbETH/USD + ETH/USD + AERO/USD, freshness assertions
    gauge.ts          rewardRate, earned, staked liquidity
  decision/
    decide.ts         action priority (§6.1)
    range.ts          _mainRange reproduction + the tick commitment (§6.2)
    params.ts         widths, mins, deadlines (§6.4)
  engine/
    gate.ts           the economic recenter gate (§6.3)
  actuation/
    execute.ts        encode + send + receipt, one action per tick
    errors.ts         revert-selector decoding (backend spec §2.4)
  monitoring/
    completion.ts     post-write state diff proving the op did something
    health.ts         HTTP health endpoint
    notify.ts         Slack / Sentry
```

Rules carried over verbatim, because each one exists to prevent a specific failure:

- **All reads pinned to ONE block.** A decision must never mix two blocks' state. `getDecisionSnapshot()` is one atomic view; everything else in the tick reads at the same `blockNumber`.
- **One on-chain action per tick.** Priority resolves conflicts; the loop never batches.
- **Stateless recovery is mandatory.** On every wake, derive the phase from chain truth (`rebalanceInFlight`, relayer allowance, balances, orderbook), never from local memory. Backend spec §3 is normative.
- **The first tick after any boot is preview-only.** A fresh or redeployed process shows a decision before the cadence can move funds. `--once` opts out so a fork drive can act on its single tick.
- **`DRY_RUN=true` is the default.** Soak in dry-run before flipping it.
- **The tick owns its error handling and never throws.** A benign contract decline (calm gate closed, cooldown, a balance race) logs quietly and retries next tick; anything else pages.
- **Degraded mode is a first-class read-only hold.** Stale feed, sequencer down, or TWAP window not yet covered ⇒ hold all writes until priced reads recover.
- **Completion gate.** After every write, re-read chain state independently and prove the op did what the decision intended (new tokenIds, `mainInRange` true, `lastRebalance` stamped). Fail the run on divergence from the agent's own report.
- **No env var gets a silent default.** The process refuses to boot on a missing required one.

Not applicable here (they belong to the leveraged strategy): leverage/LTV/health, Moonwell reads, the withdrawal queue and its consumer, `deployIdle`, hedge drift.

---

## 6. Decision layer

### 6.1 Action priority

One action per tick, first match wins:

| # | Action | Fires when |
| --- | --- | --- |
| 1 | **HOLD (degraded)** | Either feed stale against **its own** bound, sequencer down or inside grace, TWAP window not covered, or paused. No writes at all. |
| 2 | **RESUME (in-flight)** | `rebalanceInFlight == true`. Enter the swap-cycle recovery machine (backend spec §3). At bootstrap this should never happen — the swap path is dark (§8). Treat it as a page. |
| 3 | **REBALANCE** | Main out of range **and** the economic gate (§6.3) says `RECENTER` **and** `deviationGateOpen` **and** `cooldownRemaining == 0`. Always `rebalanceUsingAlt` — never the swap path (§8). |
| 4 | **COMPOUND / CLAIM** | Idle, staked, and `earnedAero × aeroUsd > COMPOUND_MIN_USD`. `claimEmissions()` is `REBALANCER_ROLE`-gated now, so the backend is the only thing that drains the gauge — put it on the sweep cadence. |
| 5 | **STAKE / UNSTAKE** | The fees-vs-emissions comparison (§6.5) flips by more than `MOONWELL_LP_HYSTERESIS_BPS`. |
| 6 | **NOOP** | Otherwise. Sleep. |

### 6.2 The tick commitment (required on every rebalance)

`rebalanceUsingAlt` takes **12** fields and `rebuildAfterSwap` takes **8**; both end in `expectedTickLower` / `expectedTickUpper`, and both revert `TickMismatch()` unless the range the contract derives from **live** spot equals what you committed. Reproduce `_mainRange` exactly — backend spec §2.2 is normative; the venue-specific part is only that `tickSpacing == 1`, so `floorAlign(t) == t` and `width/2` is a whole number of spacings for any even width:

```text
floor = spotTick                                  // tickSpacing == 1
v0 = usd(cbETH balance), v1 = usd(WETH balance)   // 1e8, per-leg feeds

if min(v0, v1) >= MIN_MAIN_LEG_USD ($0.01):       // balanced straddle
    tickLower = spotTick - width/2 ;  tickUpper = tickLower + width
elif v0 >= v1:                                    // cbETH-majority, single-sided ABOVE spot
    tickLower = spotTick + 1 ;        tickUpper = tickLower + width
else:                                             // WETH-majority, single-sided AT/BELOW spot
    tickUpper = spotTick ;            tickLower = tickUpper - width
```

On `rebalanceUsingAlt` the principal is still **in** the positions when you build the call, so the balances above are what the teardown will return: `principalAmounts(mainTokenId) + principalAmounts(altTokenId)` at the current `sqrtPriceX96`, plus any loose balance already on the balancer. `getDecisionSnapshot()` gives you the ticks and liquidity for both legs.

`TickMismatch()` under ordinary drift is a **retry**, not an error: re-read `slot0()`, recompute, resubmit. At `tickSpacing 1` expect it more often than the 011 deployment does — one tick of drift is enough. Budget two or three retries per cycle; persistent mismatch across blocks means spot is being pushed, so back off and re-check `deviationGateOpen`. **Never** widen the commitment to "whatever the contract computes" — it exists precisely because the amount minima cannot detect a shifted range.

### 6.3 The economic recenter gate

Port `mamo-rebalancer`'s `evaluateRecenterGate` unchanged in structure. Verdicts: `IN_RANGE`, `CLOCK_STARTING`, `TOO_THIN`, `PATIENT`, `RECENTER`.

- Drive off **gross** income, not net-of-IL carry. Sitting out of range earns $0 while still holding 100% of one leg, so the divergence you would "re-incur" in range is being incurred out of range anyway; netting IL here double-counts it and makes the keeper far too patient.
- `recenterCostUsd` on this venue is **gas only** — `rebalanceUsingAlt` performs no swap.
- `grossIncomeUsdDay < recenterCostUsd` ⇒ `TOO_THIN`: hold and flag for review rather than chase pennies. **Per §3, this is the expected steady state at the bootstrap allocation and width.** Do not "fix" it by lowering the cost multiplier; it is reporting a true fact about the venue.
- `CLOCK_STARTING` on the first out-of-range observation: hold one tick rather than react to a wick.

### 6.4 Parameters

- **Width** — `MOONWELL_LP_WIDTH_TICKS` (50). Must satisfy `minWidth ≤ width ≤ maxWidth` **and `width % 2 == 0`**. An odd width reverts `InvalidWidth()` *after* the teardown on the swap path — assert it at startup against the live `position()` bounds, never against a hardcoded constant.
- **Withdraw mins** — per leg, `getAmountsForLiquidity(sqrtP, tickLower, tickUpper, liquidity) × (1 − 50 bps)`. **Never send 0**: the calm gate would be the only sandwich backstop. Alt mins are 0 only when `hasAlt == false`.
- **Mint mins** — predicted in-ratio consumption at `spotTick` for the chosen range, haircut 50 bps. **Send them and size them.** On the balanced branch the contract forwards BOTH minima unchanged, and they are the *only* control for the in-bucket residual: `TickMismatch` pins *where* liquidity lands, the minima pin *how much of each leg* lands there, and neither substitutes for the other. The contract force-zeroes the unfunded leg's minimum on a single-sided mint — do not rely on that one. (The Tenderly reference harness passes zeros for rig convenience; do not copy it into a production caller.)
- **Deadline** — `now + 300` on every write.

### 6.5 Stake vs unstake

Because both sides scale with the same liquidity share, the comparison is pool-level and cheap:

```text
stakedUsdDay   = gauge.rewardRate() * 86400 * aeroUsd            * σ
unstakedUsdDay = feeRate_usd_day * (1 - unstakedFee/1e6)         * σ
```

with `σ` your in-range liquidity share. Flip only when the winner leads by more than `MOONWELL_LP_HYSTERESIS_BPS` (200), and never mid-cycle. `unstake()` claims and skims AERO to the feeCollector on the way out; `stake()` is a no-op restake after a rebalance if the position was staked at teardown (the contract handles that itself). Measured 2026-08-21 the two are within 12% of each other, so expect this decision to flip with the AERO price — hysteresis is load-bearing.

---

## 7. Preflight — the boot gate

Assert against the **live chain**, not against env. A wrong address in env must fail loudly at boot rather than quietly operate someone else's position. Hard failures aggregate and throw together; soft mismatches warn and continue.

```bash
RPC=$BASE_RPC_URL
LAB=$MOONWELL_LP_AUTO_BALANCER          # MAMO_LP_AUTO_BALANCER_V2_CBETH
MODULE=$MOONWELL_LP_COMPOUND_MODULE     # MAMO_LP_COMPOUND_MODULE_CBETH

# 1. identity — the balancer really points at the cbETH/WETH venue
cast call $LAB "position()" --rpc-url $RPC          # pool/token0/token1/tickSpacing/gauge/oracles
cast call $LAB "getDecisionSnapshot()" --rpc-url $RPC   # decodes; reverts NotActive if unregistered

# 2. guards ARMED (each of these is zero on a fresh deployment — a zero is an OFF guard)
cast call $LAB "sequencerUptimeFeed()(address)" --rpc-url $RPC   # 0xBCF85224…, NOT 0x0
cast call $LAB "sequencerGracePeriod()(uint256)" --rpc-url $RPC  # 3600, NOT 0
cast call $LAB "maxOracleDelay0()(uint256)" --rpc-url $RPC       # 3600
cast call $LAB "maxOracleDelay1()(uint256)" --rpc-url $RPC       # 3600
cast call $LAB "swapLossAllowanceBps()(uint16)" --rpc-url $RPC   # 100

# 3. our role
cast call $LAB "hasRole(bytes32,address)(bool)" $(cast keccak "REBALANCER_ROLE") $BACKEND_EOA --rpc-url $RPC

# 4. post-audit ABI (a backend built to the pre-audit spec fails all of these)
cast call $LAB "rebalanceAmountsBefore()(uint256,uint256,uint256,uint256)" --rpc-url $RPC  # exists; 0,0,0,0 idle
cast call $LAB "rebalanceValueBefore()(uint256)" --rpc-url $RPC   # MUST revert — getter removed
cast sig "rebuildAfterSwap((uint24,uint256,uint256,uint256,uint256,uint256,int24,int24))"  # 0x44254680

# 5. idle hygiene
cast call $LAB "rebalanceInFlight()(bool)" --rpc-url $RPC         # false
# allowance(balancer -> VAULT_RELAYER) MUST be 0 on both tokens while idle (approval-leak tripwire)
```

Internal-consistency asserts (not constants — read them from `position()` and check they agree with the venue contracts they name):

- `pool.token0()/token1()/tickSpacing()` equal the registered descriptor;
- `gauge.rewardToken() == AERO` and `gauge.pool() == position.pool`;
- `width % (2 × position.tickSpacing) == 0` for every width you plan to submit, and for `minWidth`/`maxWidth`;
- `minWidth > 2 × maxTickDeviation` (the R7 closure — if this stops holding, the collision is live again);
- both feeds fresh against **their own** getter, never one shared value;
- sequencer up for at least `sequencerGracePeriod()`.

### 7.1 Deferred prerequisites — what is NOT wired when 014 lands

The `CHAINLINK_SWAP_CHECKER_PROXY` owner is the MAMO multisig (`0x26c158A4…`), **not** F-MAMO, so three steps are a separate owner transaction:

1. **AERO reward config**: `addTokenConfiguration(AERO → cbETH)` and `(AERO → WETH)` using `CHAINLINK_AERO_USD` forward + cbETH/USD resp. ETH/USD reverse, plus `setMaxTimePriceValid(AERO, …)`. Until this lands AERO is not a reward token.
2. **Swap-rebalance pair**: `addTokenConfiguration(cbETH → WETH)` and `(WETH → cbETH)`, plus `setMaxTimePriceValid(cbETH, …)` **and** `setMaxTimePriceValid(WETH, …)`. Keep both **< `minRebalanceInterval` (6 h)** so a stale order from one cycle can never settle inside the next cycle's window; 3600 s is the suggested value.
3. **F-MAMO**: `module.approveCowSwap()` — reverts `"Token not allowed"` until (1) lands.

Plus: **appData**. The proposal ships the placeholder `keccak256("mamo-lpv2-compound-cbeth")`, which has no valid appData-JSON preimage while the CoW orderbook demands the full document at placement. Before the first order of either kind, generate a plain `{appCode:"Mamo"}` document (no pre-hook — this system takes its cut via the on-chain compound split and the module enforces `feeAmount == 0`), `PUT` it to `/app_data/{hash}`, and have F-MAMO call `setCompoundAppData(realHash)`.

Until (1) and (3) land, `compound(compoundBps)` still harvests AERO, drops the non-compound share to `feeCollector`, and forwards the rest to the module — only the CowSwap sell leg is inert, which is safe.

---

## 8. The swap path is dark at bootstrap

`unwindForSwap` / `rebuildAfterSwap` **must not be called** until §7.1 step 2 lands. `validateRebalanceOrder` calls `checkPrice` on the cbETH↔WETH pair and an **unconfigured pair reverts**, so every cycle would tear the position down, fail to place any order, and rebuild unswapped — **burning a full 6 h cooldown for nothing**. Worse, `maxTimePriceValid == 0` for a token collapses the module's `validTo ≤ now + maxTimePriceValid` bound against its own `validTo ≥ now + 5 min` floor: every order reverts even after the pair configs exist.

This costs nothing at bootstrap. The pair is an LST ratio: a re-range that conserves principal is essentially always sufficient, and there is no imbalance a swap would fix that time does not. **Run ALT-only.** Configure the decision engine so `SWAP` is unreachable, and alert if `rebalanceInFlight` is ever true.

When the swap path is enabled later, the backend spec §4/§6 governs it unchanged. The one venue note: `sellAmount` must be sized from the **position snapshot** (`rebalanceAmountsBefore()`), never from `balanceOf(balancer)` — pre-existing loose balance is commingled at unwind, and slippage on loose inflates loss against a floor sized to position value only.

---

## 9. Monitoring and failure playbook

Watchdogs every poll:

| Watch | Threshold |
| --- | --- |
| `rebalanceInFlight` | **any** true at bootstrap ⇒ PAGE (the swap path is dark, §8) |
| Idle relayer allowance | non-zero on either token while `!rebalanceInFlight` ⇒ PAGE (approval leak) |
| Unstaked-while-idle | `mainStaked == false` for > 1 h *while the stake decision says stake* ⇒ WARN |
| Unswept AERO | `earnedAero > MOONWELL_LP_MAX_UNSWEPT_AERO` ⇒ compound/claim |
| Out-of-range clock | `> MAX_OUT_OF_RANGE_HOURS` with the gate stuck at `TOO_THIN` ⇒ WARN + review (this is the §3 economics surfacing) |
| Guard regression | `sequencerUptimeFeed() == 0`, `sequencerGracePeriod() == 0`, or either oracle bound outside `(0, MAX_ORACLE_DELAY]` ⇒ PAGE |
| Config events mid-cycle | `OraclesUpdated`, `MaxOracleDelaysUpdated`, `SequencerUptimeFeedUpdated`, `PositionConfigUpdated`, `GaugeUpdated` ⇒ alert; never rebalance while one is in flight |
| Paused | `EnforcedPause()` ⇒ freeze writes, keep read-only monitoring |

Decode revert data before retrying — the full selector table is backend spec §2.4. The ones you will actually see here:

| Error | Response |
| --- | --- |
| `TickMismatch()` | Expected. Re-read `slot0()`, recompute the commitment, resubmit. More frequent at `tickSpacing 1`. |
| `TwapDeviation()` | Calm gate closed. Skip the cycle; backoff-retry. |
| `Cooldown()` | Wait `cooldownRemaining`. |
| `StaleOracle()` | Do nothing on-chain. PAGE — feed outage. Note the offending feed is stale against **its own** bound. |
| `SequencerDown()` / `SequencerGracePeriod()` | Freeze all writes. Resume only once the feed reads up **and** `now − startedAt ≥ sequencerGracePeriod()`. |
| `ValueFloor()` | Should be rare on the ALT path (atomic, same-transaction floor). If it fires, something moved principal — investigate, do not retry blindly. |
| `InvalidWidth()` / `WidthOutOfBounds()` | Backend bug — fix the params, do not retry. |
| Unknown selector | Stop the branch, dump revert data + tx, PAGE. No blind retries. |

**Emergency levers (Safe / guardian), in escalating order:** `pause()` (guardian; blocks everything operational, leaves `exit` available) → `revokeRole(REBALANCER_ROLE, backendEOA)` (instantly stops the backend) → `exit(SAFE)` (admin, **not** pausable, works mid-flight; unstakes, withdraws, burns, returns all cbETH + WETH to the Safe).

---

## 10. Environment

Names are the backend spec §11 names, verbatim, so there is one vocabulary across both documents. Bootstrap values:

| Env | Value | Note |
| --- | --- | --- |
| `MOONWELL_LP_AUTO_BALANCER` | `MAMO_LP_AUTO_BALANCER_V2_CBETH` | from `addresses/8453.json` after 014 |
| `MOONWELL_LP_COMPOUND_MODULE` | `MAMO_LP_COMPOUND_MODULE_CBETH` | |
| `MOONWELL_LP_RPC_URL` | Base RPC | |
| `MOONWELL_LP_WIDTH_TICKS` | `50` | must be even and inside `[minWidth, maxWidth]` |
| `MOONWELL_LP_WITHDRAW_TOL_BPS` / `_MINT_TOL_BPS` | `50` / `50` | sandwich floors — never 0 |
| `MOONWELL_LP_HYSTERESIS_BPS` | `200` | stake/unstake anti-flap (§6.5) |
| `MOONWELL_LP_MAX_UNSWEPT_AERO` | operator choice | compound trigger |
| `MOONWELL_LP_COMPOUND_BPS` | `7000` | reinvest share; drop share = `10000 −` this |
| `MOONWELL_LP_DROP_SHARE_TOL_BPS` | `500` | alert on realized vs policy drop share |
| `MOONWELL_LP_FEED_FRESHNESS_MAX_S` | `2400` | 2× the measured ~1200 s heartbeat (§1.2) |
| `MOONWELL_LP_SEQUENCER_GRACE_S` | `3600` | ≥ the on-chain value |
| `MOONWELL_LP_SWEEP_INTERVAL_S` | `300` | monitoring cadence; the rebalance branch is gated by `cooldownRemaining == 0`, not by this |
| `DRY_RUN` | `true` until go-live | |
| `HEALTH_PORT` | `8080` | |

Swap-mode variables (`MOONWELL_LP_COW_API`, `_ORDER_WINDOW_S`, `_IMBALANCE_MIN`, `_PAYBACK_MAX_H`, `_LIMIT_HAIRCUT_BPS`, `_APPROVE_BUFFER_BPS`) are **unset at bootstrap** — see §8.

The signer key (`BACKEND_REBALANCER_EOA`) is provisioned **inside the sandbox only**; the workflow layer never holds it.

---

## 11. Go-live checklist

1. `make lp-v2-cbeth-bootstrap` green on a pinned fork.
2. Re-run the §1.2 heartbeat measurement; confirm `maxOracleDelay0` still tolerates ≥ 2 missed rounds.
3. Re-run the §3 economics reads at current prices; agree the allocation with that table in front of you.
4. Safe mints the cbETH/WETH NFT off-chain at the agreed size (§2.1); record `INIT_TOKEN_ID`.
5. Run 014 with `setTokenId`, `setRebalancerEOA`, `setTotalAllocation` — `validate()` must pass, including the allocation band.
6. Preflight (§7) green against the live deployment, including every "guard armed" read.
7. Checker-owner transaction (§7.1) — required for AERO compounding; **not** required for ALT-only operation.
8. Dry-run soak: `DRY_RUN=true`, one full sweep cadence, confirm the completion gate's independent re-read agrees with the agent's report on every tick.
9. Flip `DRY_RUN=false` with a human watching the first few sweeps. First live action should be a `claimEmissions`/`compound`, not a rebalance.
10. Confirm the AERO drop routing lands in `DROP_AUTOMATION` and the realized drop share matches `1 − COMPOUND_BPS/10000` within tolerance.
