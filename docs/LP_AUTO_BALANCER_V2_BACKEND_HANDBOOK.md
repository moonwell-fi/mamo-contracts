# LPAutoBalancerV2 — Backend Handbook (WETH/cbBTC)

**Audience:** the team building and running the offchain rebalancer service.
**Status:** phase-1 deployment, proposal `011_LPAutoBalancerV2Setup`.
**Addresses and feed cadences verified on Base 2026-08-24.** Re-measurement methods are inline. Yield, cost and payback figures are deliberately absent — the backend computes those from live state (§6.3, §6.5).

## Related documents

| Document | Role |
| --- | --- |
| [`LP_AUTO_BALANCER_V2.md`](LP_AUTO_BALANCER_V2.md) | System overview. Read first; this assumes its vocabulary. |
| [backend spec](superpowers/specs/2026-07-03-lp-auto-balancer-v2-backend-spec.md) | The operational contract: ABI, selectors, decision math, CoW lifecycle, error table. **Wins on every conflict** — this handbook is the venue layer on top. |
| [setup runbook](LP_AUTO_BALANCER_V2_WETH_CBBTC_SETUP.md) | How the Safe stands the position up (Phases A–C, deferred checker steps, handover). That is the deployment side; this is the operating side. |
| `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol` | The Safe proposal. Arms the §4 config; `validate()` asserts it. |
| `test/LPAutoBalancerV2Setup.integration.t.sol` | Fork proof — `make lp-v2-setup` |

`moonwell-fi/mamo-rebalancer` is the reference for *process shape* (§5), not for domain: it drives a leveraged strategy, so its `ADJUST_LEVERAGE` / `FULFILL_REDEEM` / health-and-LTV surface has no counterpart here.

---

## 1. The venue

Aerodrome Slipstream CL, Base. Verified onchain 2026-08-24.

| Thing | Address / value |
| --- | --- |
| WETH/cbBTC CL pool | `0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1` |
| **tickSpacing** | **`100`** |
| Swap fee (`fee()`, pips) | `2505` → ~0.25% (dynamic, from the factory's swap-fee module) |
| `unstakedFee` | `50000` → 5% cut on unstaked-position fees |
| CL gauge (`rewardToken` = AERO, alive) | `0x41b2126661C673C2beDd208cC72E85DC51a5320a` |
| Gauge `nft()` | `0x827922686190790b37229fd06084350E74485b72` — the Slipstream NFPM the balancer uses |
| WETH — **token0**, **18 dp** | `0x4200000000000000000000000000000000000006` |
| cbBTC — **token1**, **8 dp** | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| Chainlink ETH/USD — **oracle0**, 8 dp | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink BTC/USD — **oracle1**, 8 dp | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` |
| Chainlink AERO/USD | `0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0` |
| Chainlink L2 sequencer uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |
| feeCollector | `DROP_AUTOMATION` in `addresses/8453.json` |
| Balancer | `MAMO_LP_AUTO_BALANCER_V2` |
| Rebalancer EOA (backend hot key) | `MAMO_LP_REBALANCER` — `0xd4669fCee3BE73b51438ad1f1debEB3505Eab308` |
| Compound module | `MAMO_LP_COMPOUND_MODULE` |

Two things that bite if assumed rather than read:

- **Token order is by address: WETH (`0x4200…`) < cbBTC (`0xcbB7…`), so WETH is token0.** Every `token0`/`token1`, `oracle0`/`oracle1`, `amount0`/`amount1`, `maxOracleDelay0`/`maxOracleDelay1` follows.
- **The legs have different decimals — WETH 18, cbBTC 8.** Any USD conversion, min-amount computation or allocation check must carry both. A helper that assumes symmetric decimals is off by 1e10 on one leg and will still look plausible.

The position manager the **gauge accepts** is `0x827922…`, registered as `UNISWAP_V3_POSITION_MANAGER_AERODROME` — **not** `AERODROME_POSITION_MANAGER` (`0xc741be…`, a different contract).

### 1.1 Oracle heartbeats — measured, not assumed

`maxOracleDelay0/1 = 3600` is only safe if both feeds actually publish faster than that, and the balancer's `MAX_ORACLE_DELAY` ceiling is 1 day — a slow feed under a 3600 s bound would brick every priced path.

Measured on Base 2026-08-24, 501 consecutive rounds each, zero missing samples:

| Feed | Max consecutive gap | Span | Missed rounds tolerated at 3600 s |
| --- | --- | --- | --- |
| ETH/USD (`oracle0`) | 1234 s | 30.6 h | ~2.9 → ≥ 2 |
| BTC/USD (`oracle1`) | 1232 s | 52.0 h | ~2.9 → ≥ 2 |

Both behave like ~1200 s heartbeat feeds. Re-measure before any re-pin:

```bash
FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70          # or the BTC/USD proxy
AGG=$(cast call $FEED "aggregator()(address)" --rpc-url base)
LR=$(cast call $AGG "latestRound()(uint256)" --rpc-url base | awk '{print $1}')
seq $((LR-500)) $LR | xargs -P 6 -I{} sh -c \
  "echo {} \$(cast call $AGG 'getTimestamp(uint256)(uint256)' {} --rpc-url base | awk '{print \$1}')" \
  | sort -n | awk 'NF==2{if(p>0 && $1==pr+1){g=$2-p; if(g>m)m=g} p=$2; pr=$1} END{print "max gap:", m, "s"}'
```

Two traps in that measurement, both of which produce a **false** over-limit reading:

- `latestRound()` on the **proxy** returns a phase-encoded id that overflows shell arithmetic — walk the aggregator.
- At high `xargs -P` some calls return empty and the gap is then computed across non-adjacent rounds. Keep concurrency low, retry empties, and only compare **consecutive** round ids (`$1 == pr+1` above). A first pass at `-P 20` reported a 3662 s ETH/USD gap that did not exist.

---

## 2. Total allocation

`totalAllocationUsd` is a parameter of proposal 011 (8-decimal USD, matching `valueInUsd`), default $50,000:

```solidity
proposal.setTotalAllocation(50_000e8, 500);   // target, tolerance bps
```

`validate()` asserts the registered principal — priced with the balancer's own feeds, staleness bounds and sequencer guard at the pool's live `sqrtPriceX96` — lands inside `totalAllocationUsd ± allocationToleranceBps`. A position minted at half the intended size fails the proposal.

**Why it validates rather than mints.** FPS records `build()`'s actions as calldata and replays them at execution time. A `mint` inside `build()` returns a tokenId seen during *simulation*, but the NFPM tokenId is a global counter anyone's mint advances in between — the encoded `registerPosition(tokenId)` would name someone else's NFT.

### 2.1 Sizing the mint

**Do not split the target 50/50 by value.** That is only correct when spot sits exactly at the range's centre, and at `tickSpacing 100` the aligned centre can be up to 99 ticks from spot. At that offset the legs bind roughly 25/75, the NFPM refunds about a third of the intended size, and the mint lands well outside a 500 bps band.

Size from the range geometry instead — price one reference unit of liquidity across the actual `[tickLower, tickUpper]` at the live `sqrtPriceX96`, then scale:

```text
(r0, r1) = amountsForLiquidityAtTicks(sqrtP, tickLower, tickUpper, 1e18)
refUsd   = r0 * ethUsd / 1e18  +  r1 * btcUsd / 1e8        // note the asymmetric decimals
amount0  = r0 * targetUsd / refUsd
amount1  = r1 * targetUsd / refUsd
```

Both legs then bind together by construction. Add ~50 bps of headroom on the desired amounts so the NFPM's own rounding cannot leave the mint a wei short of the band. `test_proposal_lifecycle` mints exactly this way and passes `validate()`; `test_validate_rejectsWrongAllocation` is its non-vacuity control (same position, 2× target, must fail).

---

## 3. Venue mechanics

How income works on this pool. **The numbers are the backend's job** — it reads them at runtime and computes yield, cost and payback per cycle from live state (§6.3, §6.5). This section is the mechanics those computations sit on, not a projection.

**Slipstream is fees XOR emissions.** A staked position earns AERO and its swap fees divert to the gauge (`pool.gaugeFees()`); an unstaked one earns fees less the 5% `unstakedFee`. So `stake()`/`unstake()` is a real economic choice, not a formality, and it is `REBALANCER_ROLE` — the backend owns it and re-evaluates it per sweep. The winner moves with pool volume and the AERO price and does genuinely flip; §6.5 has the comparison and the hysteresis that keeps it from thrashing.

011 registers the position **unstaked** — `_store` forces `mainStaked = false` at registration. Whether to stake is the backend's first decision, not a proposal setting.

**Income accrues per unit of liquidity, not per unit of capital.** For fixed capital `L` scales as `1 / width`, so a wider range earns proportionally less than the same money in a narrow one. Read `pool.liquidity()` against the pool's token balances to see how tightly incumbents are concentrated before choosing an operating width — that ratio, not the pool's headline TVL, is what determines our share.

**The two legs are independent assets.** Unlike an LST pair, WETH and cbBTC diverge on ordinary market action, so: ranges exit for normal reasons rather than only in a depeg, the USD value floor is genuinely noisy across a two-transaction swap cycle, and the swap-rebalance path earns its keep here — a no-swap rebuild cannot fix a ratio that has actually moved. That is the opposite posture from a correlated pair, where ALT-only is sufficient indefinitely.

---

## 4. The config 011 arms

| Field | Value | Why |
| --- | --- | --- |
| `tickSpacing` | `100` | The pool's. Legal widths are multiples of `2 × tickSpacing` = **200**. |
| `minWidth` | `200` | The floor the contract allows (`2 × tickSpacing`). **Note this does NOT close the R7 branch-collision residual** — see §4.1. |
| `maxWidth` | `20000` | Operator headroom. |
| `maxTickDeviation` | `100` | Calm gate, one full spacing (~1%). |
| `maxCenterDeviation` | `200` | Backstop on minted-range centre vs spot. |
| `twapWindow` | `1800` | Pool observation cardinality is 11,000 — window comfortably covered. |
| `maxRebalanceLossBps` | `100` | 1%. Sanity guard on the atomic no-swap path. |
| `minRebalanceInterval` | `21600` (6 h) | Sweep cadence; stops a buggy agent looping rebalances. |
| `maxOracleDelay0 / 1` | `3600 / 3600` | Two missed rounds on ~1200 s heartbeats (§1.1). Armed explicitly — the constructor default is byte-identical, so `validate()` alone cannot tell armed from inherited; the fork test arms non-default values to make the action observable. |
| `sequencerUptimeFeed` / grace | `0xBCF85224…` / `3600` | Ships **disabled** (`address(0)` makes `checkSequencer` a no-op). Armed before `registerPosition`, which probes both feeds. |
| `swapLossAllowanceBps` | `300` | Extra floor tolerance for the CoW round-trip, on top of `maxRebalanceLossBps`. |
| module `rebalanceSlippageBps` | `50` | The binding price floor on approved principal while `rebalanceInFlight`, since EIP-1271 placement is permissionless. |
| module `allowedSlippageInBps` | `200` | AERO → underlying compound orders (reward-only). |

### 4.1 R7 is live at `minWidth` — submit width ≥ 400

`minWidth` is exactly `2 × tickSpacing`, and at `width == 2 × tickSpacing` the balanced tick pair and the token1-single-sided tick pair **collide**: they are the same `(tickLower, tickUpper)` at different anchors. A spot push *inside* the calm gate can therefore turn a committed two-sided mint into a single-sided one with a zeroed mint minimum, and the tick commitment cannot detect it — it pins the pair, not the branch that produced it.

011 deliberately did not close this at config level (raising `minWidth` to 400 would double the minimum position width against a backtest whose edge is tight ranges). **So the mitigation is the backend's, per cycle: submit `width ≥ 4 × tickSpacing = 400`.** At `maxTickDeviation` 100 that is immune, because the collision would require the anchor to move `width/2 ≥ 2` spacings — a ≥ 101-tick push the calm gate rejects.

**Operating width: `400`** (`MOONWELL_LP_WIDTH_TICKS=400`). Legal — a multiple of 200, inside `[200, 20000]`. Never submit 200 in production. Until this is in force, do not treat a committed pair as proof of a balanced mint; check the realized `amount0Min`/`amount1Min` forwarding.

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
    prices.ts         ETH/USD + BTC/USD + AERO/USD, freshness assertions
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
| 2 | RESUME (in-flight) | `rebalanceInFlight == true`. Enter the swap-cycle recovery machine (spec §3). |
| 3 | REBALANCE | Main out of range, gate (§6.3) says `RECENTER`, `deviationGateOpen`, `cooldownRemaining == 0`. Choose ALT vs SWAP per spec §4 — on this pair both are live once §7.1 lands. |
| 4 | COMPOUND / CLAIM | Idle, staked, `earnedAero × aeroUsd > COMPOUND_MIN_USD`. `claimEmissions()` is role-gated, so the backend is the only thing draining the gauge — put it on the sweep cadence. |
| 5 | STAKE / UNSTAKE | The §6.5 comparison flips by more than `MOONWELL_LP_HYSTERESIS_BPS`. |
| 6 | NOOP | Otherwise. |

### 6.2 Tick commitment (every rebalance)

`rebalanceUsingAlt` (12 fields) and `rebuildAfterSwap` (8) both end in `expectedTickLower` / `expectedTickUpper` and revert `TickMismatch()` unless the range the contract derives from live spot matches. Reproduce `_mainRange` exactly (spec §2.2 is normative):

```text
floor = floorAlign(spotTick, 100)                 // largest aligned tick <= spot, floors toward -inf
v0 = usd(WETH balance), v1 = usd(cbBTC balance)   // 1e8, per-leg feeds, 18dp and 8dp

if min(v0, v1) >= MIN_MAIN_LEG_USD ($0.01):       // balanced straddle
    tickLower = floorAlign(spotTick - width/2, 100) ;  tickUpper = tickLower + width
elif v0 >= v1:                                    // WETH-majority, single-sided ABOVE spot
    tickLower = floor + 100 ;                          tickUpper = tickLower + width
else:                                             // cbBTC-majority, single-sided AT/BELOW spot
    tickUpper = floor ;                                tickLower = tickUpper - width
```

Because `width` is a multiple of `2 × tickSpacing`, `width/2` is a whole number of spacings and the balanced branch simplifies to `[floor - width/2, floor + width/2]`.

On `rebalanceUsingAlt` the principal is still in the positions, so those balances are what the teardown returns: `principalAmounts(mainTokenId) + principalAmounts(altTokenId)` at current `sqrtPriceX96`, plus loose balance. `getDecisionSnapshot()` gives ticks and liquidity for both legs.

`TickMismatch()` under ordinary drift is a retry: re-read `slot0()`, recompute, resubmit. Budget two or three per cycle; persistent mismatch across blocks means spot is being pushed, so back off and re-check `deviationGateOpen`. Never widen the commitment to whatever the contract computes — it exists because the amount minima cannot detect a shifted range.

### 6.3 Economic recenter gate

Port `mamo-rebalancer`'s `evaluateRecenterGate` unchanged in structure. Verdicts: `IN_RANGE`, `CLOCK_STARTING`, `TOO_THIN`, `PATIENT`, `RECENTER`.

- Drive off **gross** income, not net-of-IL carry. Out of range you earn $0 while still holding 100% of one leg, so the divergence you would re-incur in range is being incurred anyway; netting IL double-counts it and makes the keeper far too patient.
- `recenterCostUsd` on the ALT path is gas only — `rebalanceUsingAlt` performs no swap. On the SWAP path add the quote's expected shortfall, the in-flight downtime (nothing is staked while the window is open) and the cooldown drag of an unfilled cycle; spec §4 has the full cost model.
- `grossIncomeUsdDay < recenterCostUsd` ⇒ `TOO_THIN`: hold and flag rather than chase pennies.
- `CLOCK_STARTING` on the first out-of-range observation — hold a tick rather than react to a wick.

### 6.4 Parameters

- **Width** — `MOONWELL_LP_WIDTH_TICKS` (400, §4.1). `minWidth ≤ width ≤ maxWidth` and `width % 200 == 0`, asserted against live `position()` bounds, never a hardcoded constant. An odd multiple of `tickSpacing` (300, 500, …) reverts `InvalidWidth()` — after the teardown, on the swap path, wasting the cycle.
- **Withdraw mins** — per leg, `getAmountsForLiquidity(sqrtP, tickLower, tickUpper, liquidity) × (1 − 50 bps)`. Never 0, or the calm gate is the only sandwich backstop. Alt mins are 0 only when `hasAlt == false`.
- **Mint mins** — predicted in-ratio consumption at `spotTick`, haircut 50 bps. Size them: on the balanced branch the contract forwards both minima unchanged, and they are the only control for the in-bucket residual. `TickMismatch` pins *where* liquidity lands; the minima pin *how much of each leg*. Neither substitutes for the other. The contract force-zeroes the unfunded leg's minimum on a single-sided mint. (The Tenderly harness passes zeros for rig convenience — do not copy that.)
- **Deadline** — `now + 300` on every write.
- **Sell size (SWAP path)** — from the position snapshot (`rebalanceAmountsBefore()`), never from `balanceOf(balancer)`. Pre-existing loose balance is commingled at unwind, and slippage on it inflates loss against a floor sized to position value only.

### 6.5 Stake vs unstake

Both sides scale with the same liquidity share, so the comparison is pool-level:

```text
stakedUsdDay   = gauge.rewardRate() * 86400 * aeroUsd            * σ
unstakedUsdDay = feeRate_usd_day * (1 - unstakedFee/1e6)         * σ
```

`σ` is your in-range liquidity share. Flip only when the winner leads by more than `MOONWELL_LP_HYSTERESIS_BPS` (200), never mid-cycle. `unstake()` claims and skims AERO to the feeCollector; restake after a rebalance is automatic if the position was staked at teardown.

The gap between the two sides is driven by pool volume and the AERO price, both of which move fast enough to invert the ranking within a day. Expect real flips; the hysteresis is what stops them thrashing.

---

## 7. Preflight — the boot gate

Assert against the live chain, not env — a wrong address must fail at boot, not quietly operate someone else's position. Hard failures aggregate and throw together; soft mismatches warn.

```bash
RPC=$BASE_RPC_URL
LAB=$MOONWELL_LP_AUTO_BALANCER          # MAMO_LP_AUTO_BALANCER_V2

# 1. identity
cast call $LAB "position()" --rpc-url $RPC              # pool/tokens/tickSpacing/gauge/oracles
cast call $LAB "getDecisionSnapshot()" --rpc-url $RPC   # decodes; reverts NotActive if unregistered

# 2. guards ARMED (zero on a fresh deployment == guard OFF)
cast call $LAB "sequencerUptimeFeed()(address)" --rpc-url $RPC   # 0xBCF85224…, NOT 0x0
cast call $LAB "sequencerGracePeriod()(uint256)" --rpc-url $RPC  # 3600, NOT 0
cast call $LAB "maxOracleDelay0()(uint256)" --rpc-url $RPC       # 3600
cast call $LAB "maxOracleDelay1()(uint256)" --rpc-url $RPC       # 3600
cast call $LAB "swapLossAllowanceBps()(uint16)" --rpc-url $RPC   # 300

# 3. our role
cast call $LAB "hasRole(bytes32,address)(bool)" $(cast keccak "REBALANCER_ROLE") $BACKEND_EOA --rpc-url $RPC
# BACKEND_EOA must equal MAMO_LP_REBALANCER (0xd4669fCe…) — the key 011 grants

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
- **every planned width is `≥ 4 × position.tickSpacing`** (§4.1 — config does not enforce this, the backend must);
- both feeds fresh against their own getter, never one shared value;
- sequencer up for at least `sequencerGracePeriod()`.

### 7.1 Deferred prerequisites

`CHAINLINK_SWAP_CHECKER_PROXY`'s owner is the MAMO multisig (`0x26c158A4…`), not F-MAMO, so three steps are a separate owner transaction:

1. **AERO reward config:** `addTokenConfiguration(AERO → WETH)` and `(AERO → cbBTC)` using `CHAINLINK_AERO_USD` forward + ETH/USD resp. BTC/USD reverse, plus `setMaxTimePriceValid(AERO, …)`. Until this lands AERO is not a reward token.
2. **Swap-rebalance pair:** `addTokenConfiguration(WETH → cbBTC)` and `(cbBTC → WETH)`, plus `setMaxTimePriceValid` for **both** tokens. Keep both < `minRebalanceInterval` (6 h) so a cycle-N order cannot settle in cycle N+1; 3600 s suggested.
3. **F-MAMO:** `module.approveCowSwap()` — reverts `"Token not allowed"` until (1) lands.

`maxTimePriceValid == 0` for a token collapses the module's `validTo ≤ now + maxTimePriceValid` bound against its own `validTo ≥ now + 5 min` floor: **every** order reverts, even after the pair configs exist. Missing it bricks the swap path silently — `unwindForSwap` tears the position down, no order can settle, and admin `exit()` is the only way back.

Plus **appData**: 011 ships the placeholder `keccak256("mamo-lpv2-compound")`, which has no valid appData-JSON preimage while the orderbook demands the full document at placement. Before the first order of either kind, generate a plain `{appCode:"Mamo"}` document (no pre-hook — this system takes its cut via the onchain compound split and the module enforces `feeAmount == 0`), `PUT` it to `/app_data/{hash}`, and have F-MAMO call `setCompoundAppData(realHash)`.

**Until step 2 lands, run ALT-only.** `validateRebalanceOrder` calls `checkPrice` on the WETH↔cbBTC pair, and an unconfigured pair reverts — so a swap cycle would tear down, place nothing, rebuild unswapped, and burn a full 6 h cooldown. Make `SWAP` unreachable in the decision engine until the checker tx is confirmed. Unlike a correlated pair, that is a real capability loss here (§3), so treat step 2 as a launch item rather than a nice-to-have.

---

## 8. Monitoring and failure playbook

| Watch | Threshold |
| --- | --- |
| In-flight age | `now − rebalanceStartedAt` > `ORDER_WINDOW + 15 min` ⇒ WARN; > 2 h ⇒ PAGE |
| Idle relayer allowance | non-zero on either token while `!rebalanceInFlight` ⇒ PAGE (approval leak) |
| Unstaked-while-idle | `mainStaked == false` > 1 h while the stake decision says stake ⇒ WARN |
| Unswept AERO | `earnedAero > MOONWELL_LP_MAX_UNSWEPT_AERO` ⇒ compound/claim |
| Submitted width | any planned `width < 4 × tickSpacing` ⇒ PAGE (§4.1) |
| Guard regression | `sequencerUptimeFeed() == 0`, `sequencerGracePeriod() == 0`, or an oracle bound outside `(0, MAX_ORACLE_DELAY]` ⇒ PAGE |
| Config events mid-cycle | `OraclesUpdated`, `MaxOracleDelaysUpdated`, `SequencerUptimeFeedUpdated`, `PositionConfigUpdated`, `GaugeUpdated` ⇒ alert; never rebalance while one is in flight |
| Paused | `EnforcedPause()` ⇒ freeze writes, keep read-only monitoring |

Decode revert data before retrying (full table: spec §2.4). The ones you will see here:

| Error | Response |
| --- | --- |
| `TickMismatch()` | Expected. Re-read `slot0()`, recompute, resubmit. |
| `TwapDeviation()` | Calm gate closed. Skip the cycle; backoff-retry 5→15→30 min if in flight. |
| `Cooldown()` | Wait `cooldownRemaining`. |
| `ValueFloor()` | Rebuild floor breached. Predict it from `rebalanceAmountsBefore()` priced at CURRENT feeds (spec §8.2) and retry every 15 min while the margin trends up. Do not spam retries during a drawdown. |
| `StaleOracle()` | Do nothing onchain. PAGE — feed outage. The offending feed is stale against its own bound. |
| `SequencerDown()` / `SequencerGracePeriod()` | Freeze writes. Resume once the feed reads up **and** `now − startedAt ≥ sequencerGracePeriod()`. |
| `InvalidWidth()` / `WidthOutOfBounds()` | Backend bug — fix params, do not retry. |
| Unknown selector | Stop the branch, dump revert data + tx, PAGE. |

**Emergency levers, escalating:** `pause()` (guardian; blocks everything operational — including `isValidSignature`, so open CoW orders stop settling — while leaving `exit` available) → `revokeRole(REBALANCER_ROLE, backendEOA)` → `exit(SAFE)` (admin, not pausable, works mid-flight; unstakes, withdraws, burns, returns all WETH + cbBTC to the Safe).

If the backend key goes dark mid-flight, `exit(SAFE)` is the **only** escape. `withdrawPosition`/`deregisterPosition` revert mid-flight and do not clear the window — do not reach for them.

---

## 9. Environment

Names are the backend spec §11 names verbatim, so there is one vocabulary across both documents.

| Env | Value | Note |
| --- | --- | --- |
| `MOONWELL_LP_AUTO_BALANCER` | `MAMO_LP_AUTO_BALANCER_V2` | from `addresses/8453.json` after 011 |
| `MOONWELL_LP_COMPOUND_MODULE` | `MAMO_LP_COMPOUND_MODULE` | |
| `MOONWELL_LP_RPC_URL` | Base RPC | |
| `MOONWELL_LP_WIDTH_TICKS` | `400` | multiple of 200, **≥ 400** (§4.1) |
| `MOONWELL_LP_WITHDRAW_TOL_BPS` / `_MINT_TOL_BPS` | `50` / `50` | sandwich floors — never 0 |
| `MOONWELL_LP_HYSTERESIS_BPS` | `200` | stake/unstake anti-flap (§6.5) |
| `MOONWELL_LP_MAX_UNSWEPT_AERO` | operator choice | compound trigger |
| `MOONWELL_LP_COMPOUND_BPS` | `7000` | reinvest share; drop share = `10000 −` this |
| `MOONWELL_LP_DROP_SHARE_TOL_BPS` | `500` | alert on realized vs policy drop share |
| `MOONWELL_LP_FEED_FRESHNESS_MAX_S` | `2400` | 2× the measured ~1200 s heartbeat (§1.1) |
| `MOONWELL_LP_SEQUENCER_GRACE_S` | `3600` | ≥ the onchain value |
| `MOONWELL_LP_SWEEP_INTERVAL_S` | `300` | monitoring cadence; the rebalance branch is gated by `cooldownRemaining`, not this |
| `DRY_RUN` | `true` until go-live | |
| `HEALTH_PORT` | `8080` | |

Swap-mode variables (`MOONWELL_LP_COW_API`, `_ORDER_WINDOW_S`, `_IMBALANCE_MIN`, `_PAYBACK_MAX_H`, `_LIMIT_HAIRCUT_BPS`, `_APPROVE_BUFFER_BPS`) come into play once §7.1 step 2 lands; see spec §11.

`BACKEND_REBALANCER_EOA` is provisioned inside the sandbox only; the workflow layer never holds it.

---

## 10. Go-live checklist

1. `make lp-v2-setup` green on a pinned fork.
2. Re-run the §1.1 heartbeat measurement for **both** feeds; confirm each tolerates ≥ 2 missed rounds.
3. Have the backend report live fee/emission rates and the stake-vs-unstake verdict; agree `totalAllocationUsd` against them.
4. Safe mints the WETH/cbBTC NFT offchain at the agreed size (§2.1 — geometry-sized, not 50/50); record `INIT_TOKEN_ID`.
5. Run 011 with `setTokenId`, `setRebalancerEOA`, `setTotalAllocation` — `validate()` must pass, allocation band included.
6. Preflight (§7) green, including every guard-armed read and the `width ≥ 400` assert.
7. Checker-owner transaction (§7.1). Steps 1+3 gate AERO compounding; step 2 gates the swap path — ALT-only until it lands.
8. Dry-run soak: one full sweep cadence, completion gate agreeing with the agent's report on every tick.
9. Flip `DRY_RUN=false` with a human watching. First live action is the stake decision (§3), then claim/compound — not a rebalance.
10. Confirm AERO routing lands in `DROP_AUTOMATION` and the realized drop share matches `1 − COMPOUND_BPS/10000` within tolerance.
