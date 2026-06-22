# LPAutoBalancerV2 — Dual-Position (No-Swap) Design

**Date:** 2026-06-17
**Status:** Design
**Author:** Ana Julia + Claude
**Off-chain companion:** `centaur-moonwell` `docs/superpowers/specs/2026-06-17-lp-balancer-agent-design.md`

## 1. The IL problem

V1 re-ranges by swapping to the new range's ratio (decrease → swap surplus leg → mint). Every swap **crystallizes** impermanent loss that was, until then, only on paper — plus swap fees. On a volatile/stable pair like MAMO/USDC, divergence is large and frequent, so a swap-based auto-rebalancer can bleed more in realized IL + swap fees than it earns in trading fees + AERO. (Phase-1 deliberately starts on a correlated pair — WETH/cbBTC, §6 — where IL is small, to prove the mechanism before touching high-IL pairs.) This is the failure mode Beefy's CLM docs call out for "rebalancing-heavy" ALMs (Gamma/vfat style), where "aggregate IL ... far exceeds earnings."

**V2 adopts Beefy CLM's structural fix: never sell.** Excess tokens are redeployed into a single-sided "alt" position instead of swapped. IL is realized only on a true range exit (same as holding), not on every reset.

## 2. The dual-position model (Beefy CLM, adapted)

Each managed slot holds **two** Aerodrome CL position NFTs:

- **`main`** — a balanced (~50/50) position centered on the reference tick at an agent-chosen `width`. Earns trading fees (unstaked) or AERO (staked). This is the workhorse.
- **`alt`** — a single-sided position holding the **excess** token after the main is funded 50/50. Its range sits between the main's overweight boundary and the nearest valid tick on the excess side, so it holds only the surplus token and waits to be earned back into balance as price oscillates — **without any swap**.

When price drifts, the main goes out of balance; on reset we rebuild a fresh 50/50 main and park the (now larger or smaller) excess in a fresh alt. No token is ever sold to do this.

**Why only one alt side.** After a maxed 50/50 main mint, exactly **one** token is left over — never both: "balanced" means depositing the most that fits the range's ratio, which fully consumes one leg and leaves a remainder of the other. A single-sided CL range holds exactly one token (a range entirely above spot is 100% token0; entirely below is 100% token1), so one alt on the surplus side absorbs all of it. A second alt would have nothing to hold. The surplus *side* flips reset-to-reset with price; at any single reset there is only one.

**Width tradeoff (Beefy's caveat):** a too-narrow main is "quickly imbalanced by Range IL, leading to a very large alt position." So `width` is a real decision — wider main ⇒ smaller alt ⇒ more capital earning balanced fees, fewer resets. The off-chain agent picks `width` (§7); the contract bounds it (`minWidth`/`maxWidth`).

## 3. Contract: `LPAutoBalancerV2`

The contract implements standard security protocols including `AccessControlEnumerable`, `ReentrancyGuard`, `Pausable`, and `IERC721Receiver` (Solidity 0.8.28, BUSL-1.1). It uses a role-based access model: `DEFAULT_ADMIN_ROLE` (assigned to the Safe), `MANAGER_ROLE`, `REBALANCER_ROLE`, and `GUARDIAN_ROLE`.

The architecture is built on the following core components:

- **Registry & position management:** tracks positions via a `slotId` registry, using the `POSITION_MANAGER`, `QUOTER`, and `AERO` interfaces. **No swap router** — V2 never swaps, on any path.
- **Oracles & pricing:** the `_consultTwapTick` helper and Chainlink oracles enforce the value-floor checks.
- **Core administrative functions:** `collectFees`, `claimEmissions`, `recover*` utilities, and pause.
- **Operational mechanisms:**
  - **`reset()`** — the primary operational function that rebuilds the dual position **without performing any token swap**, minimizing impermanent-loss impact.
  - **`exit()`** — a protected, Safe-gated function that withdraws all liquidity from both the main and alt positions, burns the NFTs, and returns all underlying tokens to the Safe. This replaces V1's `migrate()`: V2 has no swap router, so cross-pool moves are done as exit-to-Safe + redeploy, never an in-contract swap.

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
    address oracle0;            // Chainlink feeds for the value floor (per-leg)
    address oracle1;
    uint24  minWidth;           // bounds on main width (tick units)
    uint24  maxWidth;
    uint24  maxCenterDeviation; // main center must be within N ticks of reference
    uint32  twapWindow;         // calm-gate + value-floor TWAP fallback
    int24   maxTickDeviation;   // calm gate: |spot - twap| <= this
    uint16  maxRebalanceLossBps;// value floor (sanity guard under no-swap)
    uint256 minRebalanceInterval;
    uint256 lastRebalance;
    bool    active;
}

mapping(uint256 slotId => ManagedPositionV2) public positions;
```

**No `swapPolicy`/`protectedToken`/`maxSlippageBps`.** Swap-related policy and the slippage cap are omitted because no swap ever occurs — not in `reset`, not in `exit`.

### 3.2 `reset(uint256 slotId, ResetParams params)` — `onlyRole(REBALANCER_ROLE)`, `nonReentrant`, `whenNotPaused`

```solidity
struct ResetParams {
    uint24  width;              // chosen main width; centers + aligns + bounds-checks
    uint256 amount0MinMain;     // sandwich protection for balanced mint
    uint256 amount1MinMain;
    uint256 amount0MinAlt;      // sandwich protection for single-sided alt
    uint256 amount1MinAlt;
    uint256 amount0MinWithdraw; // sandwich protection for principal withdrawal
    uint256 amount1MinWithdraw;
    uint256 deadline;
}
```

### 3.3 Core operational flow (the reset loop)

1. **Cooldown validation:** ensures `block.timestamp` has surpassed `lastRebalance + minRebalanceInterval`.
2. **Calm gate:** compares the `slot0` spot tick against `_consultTwapTick`; if the delta exceeds `maxTickDeviation`, reverts with `TwapDeviation`. The TWAP serves as the **reference tick**.
3. **Oracle pricing:** captures the market rate (preferring Chainlink per-leg feeds over pool TWAP) to be used consistently across both valuation checkpoints.
4. **Pre-reset snapshot:** calculates `valueBefore` by pricing the principal in the main and alt positions at the captured oracle rate.
5. **Unstake & harvest:** removes NFTs from the gauge; `gauge.withdraw` triggers an AERO claim which is skimmed to `feeCollector`, firing `EmissionsClaimed`.
6. **Fee collection:** `collect(max,max)` on both positions, skimming trading fees to `feeCollector` and emitting `FeesSkimmed`. Fees are excluded from the value-floor check.
7. **Liquidity withdrawal:** `decreaseLiquidity(all)` then burns both existing NFTs. Underlying `token0`/`token1` are now held by the contract.
8. **Range calculation:** `_alignedRange` from the reference tick + provided `width`; strictly enforces `minWidth`/`maxWidth` and `maxCenterDeviation`.
9. **Main mint:** `LiquidityAmounts` mints a balanced 50/50 position within `[tickLower, tickUpper]` at the oracle price with the slippage mins. A new `mainTokenId` is assigned.
10. **Alt mint:** deploys the surplus leg into a single-sided range from the main's overweight boundary to the nearest aligned tick. If the remainder is dust, it is forwarded to `feeCollector` and `altTokenId` stays 0. **No swap occurs.**
11. **Restaking:** the main is redeposited into the gauge if the agent's decision requires it; the alt inherits that state. Emits `Staked`.
12. **Sanity value floor:** verifies `valueAfter` (total principal) ≥ `valueBefore * (BPS - maxRebalanceLossBps)/BPS`. Final defense against mint rounding or reference-tick manipulation.
13. `lastRebalance = block.timestamp`; emits `Reset(slotId, mainTokenId, altTokenId, tickLower, tickUpper)`.

### 3.4 Stake / unstake (per-pair)

`stake(slotId)` / `unstake(slotId)` operate on the **main**, and the **alt follows**: when `altTokenId != 0` and `gauge != 0`, the alt is staked/unstaked alongside. The agent decides the main's stake state (AERO-vs-fees, §7); the alt is a transient buffer that inherits it. (A single-sided alt may sit outside the gauge's active range and earn little AERO — acceptable; it is short-lived between resets and the bookkeeping stays simple.)

### 3.5 `getDecisionSnapshot(uint256 slotId)` — view (extended for V2)

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

A consolidated, atomic on-chain view for the agent's discovery and completion stages, augmented with alt-position data. `mainInRange == false` is the primary reset signal; a large `altLiquidity` relative to `mainLiquidity` is a diagnostic for persistent divergence or an overly restrictive width.

### 3.6 `exit(uint256 slotId, address to)` — `onlyRole(DEFAULT_ADMIN_ROLE)`, `nonReentrant`

Safe-gated emergency / migration primitive. Unstakes both NFTs if staked (skimming AERO to `feeCollector`), collects fees, `decreaseLiquidity(all)`, burns both NFTs, and transfers **all** underlying `token0`/`token1` to `to` (the Safe). Marks the slot inactive. No swap — the Safe decides what to do with the returned tokens (e.g. redeploy into a new pool). This is the seam that Phase-2 (§6) automates behind safety rails.

## 4. Fees / AERO / drop economics

Fees (unstaked) and AERO (staked) are skimmed to `feeCollector` (`DropAutomation`) on every `reset` / `collectFees` / `claimEmissions`. **No compounding** — fees + AERO feed the weekly drop.

## 5. Value floor under no-swap

In V1, the value floor was the fundamental constraint on realized market loss during rebalancing (the swap). Since V2 eliminates the swap entirely, the primary cause of crystallized IL is removed. The floor is preserved as a **sanity guard**: it intercepts mint-ratio rounding, reference-tick manipulation that might skew the main, or structural flaws in `LiquidityAmounts`. During standard operation it resolves with significant margin; any failure indicates a structural anomaly where an immediate revert is the intended behavior.

## 6. Scope & phasing

Two phases of improved yield generation:

### Phase-1 (immediate) — validate the no-swap model on WETH/cbBTC

- **Initial pair: WETH/cbBTC** — a highly correlated pair (minimal IL) with a live Aerodrome CL **gauge** for AERO emissions. The strategic starting point because: (a) correlation ⇒ a compact alt and negligible IL, so mechanical failures in the reset logic surface without being masked by price divergence; (b) it validates the AERO-staking integration; (c) the small initial allocation limits TVL-at-risk during proof-of-concept.
- **Displaces MAMO/USDC** as the primary testbed. MAMO-incentivized pools in `TransferAndEarn` remain unaltered this phase.
- **Funding via Safe (external to the agent, § trust model):** governance liquidates lagging `TransferAndEarn` holdings into **WETH + cbBTC**, mints the initial WETH/cbBTC NFT manually (off-contract), transfers the NFT to `LPAutoBalancerV2`, and calls `registerPosition` with active gauging and Chainlink price feeds (WETH/USD + cbBTC/USD). `REBALANCER_ROLE` is restricted to `reset`/`stake`/`unstake`/`claimEmissions` — it has **no sell capability**; the trust model centralizes all value-shifting in the Safe.
- **Goal:** verify the no-swap reset preserves principal through real market shifts and the automated stake/unstake logic is sound, before broader deployment.

### Phase-2 (long term) — automated cross-pool migration into the best pair

- **Automated inter-pool migration:** systematically liquidate positions in underperforming pairs and redeploy into higher-yield opportunities (e.g. MAMO/VVV). This transitions **`exit()`** from a manual, Safe-gated operation to an agent-driven workflow. Previously restricted due to open-destination swap / TWAP-manipulation risk; V2 introduces the infrastructure to bridge the gap.
- **Migration safety rails (deployment prerequisites):** a governance-sanctioned **allowlist** of destination pools, mandatory **Chainlink-based value floors for both assets** (never a potentially-compromised pool TWAP), and **min-TVL / liquidity-depth** gates. Each move inherits the cooldown + value-floor protections from `reset`. Automated migration stays blocked until a robust price feed or allowlist entry is secured (MAMO/VVV included).
- The off-chain companion gains a **migration-decision capability** using LpSugar + DefiLlama for pool scoring, ranking destinations and executing within the approved allowlist — extending the core discovery funnel.

### Out of scope (both phases)

veAERO; compounding (fees + AERO feed the drop); the locked `BurnAndEarn` MAMO/VIRTUALS LP; **autonomous migration without the Phase-2 safety rails above**.

## 7. Off-chain agent

The off-chain companion is a goal-gated agent governing the liquidity lifecycle. It uses a continuous discovery funnel to keep positions aligned with market shifts **without ever triggering a swap**.

**Discovery funnel.** The agent runs a persistent loop, inspecting position health via the `DecisionSnapshotV2` view. Execution follows a strict heuristic:

- **Reset candidacy:** a `reset()` is offered only when health criteria align — the main is out of range (`mainInRange == false`), the calm gate confirms price stability (`deviationGateOpen == true`), and `cooldownRemaining == 0`.
- **Parameter choice:** the agent's primary mandate is picking `width` — balancing capital efficiency (narrower concentrates liquidity) against the resulting alt size. It also selects the staking strategy: unstaked (fees) vs staked (AERO emissions).

**Completion gate & diagnostics.** After `reset()`, the agent enters a completion gate to verify mechanical success against an **independent** chain re-read:

- **State alignment:** confirms the main is in range and the staking state matches the decision intent.
- **Asset reconciliation:** verifies trading fees and AERO were skimmed to `feeCollector`.
- **Diagnostic analysis:** monitors `altLiquidity`. Since V2 never sells on reset, a bloated alt is a diagnostic for persistent divergence — if alt liquidity grows too large relative to the main, the agent flags `GOAL NOT MET`, indicating the width is too restrictive.

This feedback loop lets the agent autonomously adapt to volatility while safeguarding principal across the position lifecycle. (Full agent design — goal-gated turn loop, sandbox-`cast` execution, `eth_call` gate, circuit-breaker — in the companion spec.)

## 8. Testing

- **Reset (unit, mocks):** out-of-range → `reset(width)` rebuilds a 50/50 main + single-sided alt with **no swap call** (assert no router exists / is never invoked); fees/AERO skimmed; both old NFTs burned; new `mainTokenId`/`altTokenId` set; value floor passes; dust forwarded; alt skipped when leftover is dust.
- **Calm gate / cooldown / width bounds / value-floor / stale-oracle** — ported from V1.
- **Stake/unstake (per-pair):** main staked → alt follows; unstake roundtrip; `claimEmissions` sums both NFTs.
- **`exit` (Safe-gated):** non-admin reverts; admin withdraws both NFTs, burns them, returns all `token0`/`token1` to `to`, marks slot inactive, skims fees/AERO; no swap.
- **getDecisionSnapshot V2:** main+alt ranges, `mainInRange`, `hasAlt`, `altLiquidity`, `cooldownRemaining`, `deviationGateOpen`, staked-path `earnedAero` (try/catch).
- **Adversarial:** manipulated spot (calm gate reverts), lopsided forced mint (value floor reverts), pre-cooldown, mint sandwich bounded by min-amounts. **Assert no swap path exists** anywhere in the contract (the IL-defining property).
- **Integration (Base fork):** bootstrap the real WETH/cbBTC position (mint from held WETH+cbBTC, transfer NFT in, register gauged with WETH/USD + cbBTC/USD oracles), push the tick out of range, `reset(width)` → assert dual-position rebuilt **without selling** (token0/token1 balances conserved within mint rounding, zero router calls), fees/AERO to `DropAutomation`, `mainInRange == true` after, old NFTs burned, `Reset` emitted.
- **FPS proposal test:** deploy `LPAutoBalancerV2`, run the Safe setup (sell → mint → transfer → register), validate.
