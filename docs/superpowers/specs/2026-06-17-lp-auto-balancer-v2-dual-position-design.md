# LPAutoBalancerV2 — Dual-Position (No-Swap) Design

**Date:** 2026-06-17
**Status:** Design
**Author:** Ana Julia + Claude
**Supersedes (for new deployments):** the swap-based `rebalance()` in `docs/superpowers/specs/2026-06-01-lp-auto-balancer-design.md` (V1, PR #54). V1 stays as-is; **V2 is a new contract** (`LPAutoBalancerV2`), not a modification.
**Off-chain companion:** `centaur-moonwell` `docs/superpowers/specs/2026-06-17-lp-balancer-agent-design.md` (the goal-gated agent; its funnel is updated for V2 — see §8).

## 1. Why V2 — the IL problem with V1

V1 re-ranges by **swapping** to the new range's ratio (decrease → swap surplus leg → mint). Every swap **crystallizes** impermanent loss that was, until then, only on paper — plus swap fees. On a **volatile/stable** pair like MAMO/USDC (phase-1), divergence is large and frequent, so a swap-based auto-rebalancer can bleed more in realized IL + swap fees than it earns in trading fees + AERO. This is the failure mode Beefy's CLM docs call out for "rebalancing-heavy" ALMs (Gamma/vfat style), where "aggregate IL ... far exceeds earnings."

**V2 adopts Beefy CLM's structural fix: never sell on reset.** Excess tokens are redeployed into a single-sided "alt" position instead of swapped. IL is realized only on a true range exit (same as holding), not on every reset.

## 2. The dual-position model (Beefy CLM, adapted)

Each managed slot holds **two** Aerodrome CL position NFTs:

- **`main`** — a balanced (~50/50) position centered on the reference tick at an agent-chosen `width`. Earns trading fees (unstaked) or AERO (staked). This is the workhorse.
- **`alt`** — a **single-sided** position holding the **excess** token after the main is funded 50/50. Its range sits between the main's overweight boundary and the **nearest valid tick** on the excess side, so it holds only the surplus token and waits to be earned back into balance as price oscillates — **without any swap**.

When price drifts, the main goes out of balance; on reset we rebuild a fresh 50/50 main and park the (now larger or smaller) excess in a fresh alt. No token is ever sold to do this.

**Width tradeoff (Beefy's caveat):** a too-narrow main is "quickly imbalanced by Range IL, leading to a very large alt position." So `width` is a real decision — wider main ⇒ smaller alt ⇒ more capital earning balanced fees, fewer resets. The off-chain agent picks `width` (§8); the contract bounds it (`minWidth`/`maxWidth`).

## 3. Contract: `LPAutoBalancerV2`

`AccessControlEnumerable`, `ReentrancyGuard`, `Pausable`, `IERC721Receiver`. Solidity 0.8.28, BUSL-1.1. **Reuses V1 verbatim** for everything that isn't the rebalance path: the role model (`DEFAULT_ADMIN_ROLE`=Safe, `MANAGER_ROLE`, `REBALANCER_ROLE`, `GUARDIAN_ROLE`), the `slotId` registry, immutables (`POSITION_MANAGER`, `SWAP_ROUTER` — retained only for `migrate`, `QUOTER`, `AERO`), the TWAP helper `_consultTwapTick`, the Chainlink value-floor oracle plumbing, `collectFees`, `claimEmissions`, `migrate` (still Safe-gated, still allowed to swap — it's a rare human-reviewed action), `recover*`, pause. **The swap-based `rebalance()` is removed** and replaced by `reset()`.

### 3.1 State

```solidity
struct ManagedPositionV2 {
    uint256 mainTokenId;        // balanced 50/50 CL NFT
    uint256 altTokenId;         // single-sided excess CL NFT (0 if none this cycle)
    address pool;
    address token0;
    address token1;
    int24   tickSpacing;
    address gauge;              // address(0) => never staked
    bool    mainStaked;         // main NFT staked in gauge
    bool    altStaked;          // alt NFT staked in gauge
    address feeCollector;       // skim destination (DropAutomation)
    address oracle0;            // Chainlink feeds for the value floor (per-leg, from V1)
    address oracle1;
    uint24  minWidth;           // bounds on main width (tick units)
    uint24  maxWidth;
    uint24  maxCenterDeviation; // main center must be within N ticks of reference
    uint16  maxSlippageBps;     // retained for migrate() only
    uint32  twapWindow;         // calm-gate + value-floor TWAP fallback
    int24   maxTickDeviation;   // calm gate: |spot - twap| <= this
    uint16  maxRebalanceLossBps;// value floor (sanity guard under no-swap)
    uint256 minRebalanceInterval;
    uint256 lastRebalance;
    bool    active;
}

mapping(uint256 slotId => ManagedPositionV2) public positions;
```

> **No `swapPolicy`/`protectedToken`.** V1 needed them to constrain which leg the swap could sell. V2 never swaps on reset, so they are gone. (`migrate` still swaps but is Safe-reviewed.)

### 3.2 `reset(uint256 slotId, ResetParams params)` — `onlyRole(REBALANCER_ROLE)`, `nonReentrant`, `whenNotPaused`

```solidity
struct ResetParams {
    uint24  width;              // desired main width; contract centers + aligns + bounds-checks
    uint256 amount0MinMain;     // mint sandwich guards (main)
    uint256 amount1MinMain;
    uint256 amount0MinAlt;      // mint sandwich guard (alt, single-sided => one is 0)
    uint256 amount1MinAlt;
    uint256 amount0MinWithdraw; // decrease sandwich guards
    uint256 amount1MinWithdraw;
    uint256 deadline;
}
```

Execution (no swap):
1. **Cooldown**: `require(block.timestamp >= lastRebalance + minRebalanceInterval)`.
2. **Calm gate**: read spot tick (`slot0`) + TWAP tick (`_consultTwapTick`); `require(|spot - twap| <= maxTickDeviation)` else revert `TwapDeviation`. TWAP tick is the **reference tick**.
3. **Read pricing oracle** (Chainlink per-leg if set, else pool TWAP) — held once for both value snapshots.
4. **Snapshot pre-value**: value `main`+`alt` principal at the oracle price → `valueBefore`.
5. **Unstake** main (and alt) if staked; `gauge.withdraw` auto-claims AERO → skim to `feeCollector` (emit `EmissionsClaimed`).
6. **Collect fees** from main+alt (`collect(max,max)` before decreasing) → skim to `feeCollector` (emit `FeesSkimmed`). Fees excluded from the value comparison.
7. **Withdraw all**: `decreaseLiquidity(all)` + `collect` principal from both NFTs; **burn** both old NFTs. Contract now holds token0+token1.
8. **Compute main range** from reference tick + `width` (reuse V1's `_alignedRange`): bounds-check `minWidth<=width<=maxWidth`, `|center-reference|<=maxCenterDeviation`.
9. **Mint main 50/50**: compute the balanced amounts that fit `[tickLower,tickUpper]` at the oracle price (`LiquidityAmounts`), mint with `amount{0,1}MinMain`. Record `mainTokenId`.
10. **Mint alt single-sided** with the **leftover** token (whichever leg has surplus after the main): range from the main's overweight boundary to the nearest aligned tick on that side; mint with `amount{0,1}MinAlt` (the zero-leg min is 0). If leftover is dust (below a threshold) skip the alt (`altTokenId = 0`) and forward dust to `feeCollector`. **No swap.**
11. **Restake** per the agent's decision (carried in prior state / params): if main was staked, `gauge.deposit(mainTokenId)`; alt follows main's state (`altStaked = mainStaked` when alt exists and `gauge != 0`). Emit `Staked`.
12. **Value floor (sanity)**: `valueAfter` = main+alt principal at the same oracle observation; `require(valueAfter >= valueBefore * (BPS - maxRebalanceLossBps)/BPS)`. Under no-swap this only catches mint rounding / a manipulated reference tick / a lopsided mint — defense-in-depth.
13. `lastRebalance = block.timestamp`; emit `Reset(slotId, mainTokenId, altTokenId, tickLower, tickUpper)`.

### 3.3 Stake / unstake (per-pair)

`stake(slotId)` / `unstake(slotId)` operate on the **main**, and the **alt follows**: when `altTokenId != 0` and `gauge != 0`, the alt is staked/unstaked alongside. The agent decides the main's stake state (AERO-vs-fees, §8); the alt is a transient buffer that inherits it. (A single-sided alt may sit outside the gauge's active range and earn little AERO — acceptable; it is short-lived between resets and the bookkeeping stays simple.)

### 3.4 `getDecisionSnapshot(uint256 slotId)` — view (extended for V2)

```solidity
struct DecisionSnapshotV2 {
    int24   spotTick;
    int24   twapTick;
    int24   mainTickLower;
    int24   mainTickUpper;
    bool    mainInRange;        // tickLower <= spot < tickUpper for main
    int24   altTickLower;
    int24   altTickUpper;
    bool    hasAlt;             // altTokenId != 0
    uint128 mainLiquidity;
    uint128 altLiquidity;       // large alt => accumulated divergence (reset signal)
    bool    mainStaked;
    bool    hasGauge;
    uint256 earnedAero;         // gauge.earned summed over staked NFTs (try/catch => 0 on revert)
    uint256 cooldownRemaining;
    bool    deviationGateOpen;  // |spot - twap| <= maxTickDeviation (reset won't revert on calm gate)
}

function getDecisionSnapshot(uint256 slotId) external view returns (DecisionSnapshotV2 memory);
```

Built like V1's (a single consistent chain read for the agent's gather + the completion gate), extended with the alt fields. `mainInRange == false` is the primary reset signal; `altLiquidity` large relative to `mainLiquidity` is the divergence/"width too narrow" signal.

## 4. What carries over from V1 unchanged

Roles, registry (`registerPosition`/`deregisterPosition`/`withdrawPosition`), caps, `collectFees`, `claimEmissions`, the Chainlink value-floor plumbing + staleness, `_consultTwapTick`, `_alignedRange`/`_floorAlign`, `migrate` (Safe-gated, may still swap), `recoverERC20`/`recoverETH`, pause/guardian, `onERC721Received` (now accepts the two NFTs per slot). The trust model is identical: `REBALANCER_ROLE` is bounded by calm gate + cooldown + width bounds + value floor; migrations stay Safe-gated.

## 5. Fees / AERO / drop economics — unchanged

Fees (unstaked) and AERO (staked) are skimmed to `feeCollector` (`DropAutomation`) on every reset / `collectFees` / `claimEmissions`. **No compounding** — fees+AERO feed the weekly drop, exactly as V1. The no-swap change is about **principal** redeployment only; it does not touch the drop pipeline.

## 6. Value floor under no-swap

V1's value floor was the primary bound on per-rebalance market loss (the swap). V2 removes the swap, so the dominant IL-crystallization source is gone. The floor is retained as a **sanity guard**: it catches mint-ratio rounding, a manipulated reference tick that would mint a lopsided main, or a buggy `LiquidityAmounts` computation. It should pass with wide headroom on a healthy reset; a failure means something is structurally wrong, and reverting is correct.

## 7. Scope & phasing (unchanged from V1)

- **Phase-1: single position, MAMO/USDC** (tokenId 21585074, custody confirmed). MAMO/USDC is volatile/stable — the highest-IL pair — which is *why* V2's no-swap model matters most here. Run a wide main (small alt), conservative cooldown.
- Phase-2+: cbBTC/MAMO (once custody confirmed), deep correlated non-MAMO pools (cbBTC/WETH — low IL, strong emissions), multi-position sweep.
- **Out of scope:** veAERO; compounding; the locked `BurnAndEarn` MAMO/VIRTUALS LP; autonomous migration.

## 8. Off-chain agent changes (companion spec §3, §4)

The goal-gated agent and its funnel are mostly unchanged; the deltas:
- The **`rebalance` candidate becomes `reset`**. The funnel's IL-crystallization-vs-fee-gain scoring is **dropped** — under no-swap a reset is cheap in IL terms, so the candidate is simply: offer `reset` when `mainInRange == false` AND `deviationGateOpen` AND `cooldownRemaining == 0`.
- The agent's remaining real judgment narrows to **main `width`** (the alt-size tradeoff) and **stake-vs-fees** — the dangerous swap-timing call is gone from its hands.
- The **completion gate** reads `DecisionSnapshotV2` and verifies the mechanical clauses: `mainInRange`, no unswept fees/AERO, `mainStaked` matches the agent's `DECISION:` line. A persistently bloated `altLiquidity` (divergence the resets can't tame) is surfaced as a `GOAL NOT MET: alt position oversized — widen main` hint and/or a circuit-breaker alert.
- The eth_call decoder decodes `DecisionSnapshotV2` (more fields; same all-static-tuple layout).

## 9. Testing

- **Reset (unit, mocks):** out-of-range → `reset(width)` rebuilds a 50/50 main + single-sided alt with **no swap call** (assert the router is never invoked on the reset path); fees/AERO skimmed; both old NFTs burned; new `mainTokenId`/`altTokenId` set; value floor passes; dust forwarded; alt skipped when leftover is dust.
- **Calm gate / cooldown / width bounds / value-floor / stale-oracle** — ported from V1.
- **Stake/unstake (per-pair):** main staked → alt follows; unstake roundtrip; `claimEmissions` sums both.
- **getDecisionSnapshot V2:** main+alt ranges, `mainInRange`, `hasAlt`, `altLiquidity`, `cooldownRemaining`, `deviationGateOpen`, staked path `earnedAero` (try/catch).
- **Adversarial:** manipulated spot (calm gate reverts), lopsided forced mint (value floor reverts), pre-cooldown, mint sandwich bounded by min-amounts. **Assert no swap path exists in `reset`** (the IL-defining property).
- **Integration (Base fork):** register the real MAMO/USDC position, push tick out of range, `reset` → assert dual-position rebuilt without selling, principal preserved within rounding, fees/AERO to `DropAutomation`.
- **FPS proposal test:** deploy `LPAutoBalancerV2`, move the MAMO/USDC NFT in, register, validate.

## 10. Migration note

`migrate` (Safe-gated) is retained from V1 and **may still swap** — it is a rare, human-reviewed action for moving into a different pool, where a one-time swap is acceptable and value protection is the human review. Only the autonomous `reset` path is swap-free.
