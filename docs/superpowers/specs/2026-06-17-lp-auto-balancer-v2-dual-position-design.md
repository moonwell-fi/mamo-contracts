# LPAutoBalancerV2 — Dual-Position (No-Swap Principal) Design

**Date:** 2026-06-17 (revised 2026-06-30)
**Status:** Design
**Author:** Ana Julia + Claude
**Off-chain companion:** `centaur-moonwell` `docs/superpowers/specs/2026-06-17-lp-balancer-agent-design.md`

> **2026-06-30 revision.** Three changes, driven by production needs:
> 1. **One contract per pool.** The multi-slot `positions[slotId]` registry collapses to a **single managed position** per deployment, with a `setPool` setter to re-point an emptied contract at a new pair.
> 2. **Partial AERO compounding.** A new `compound()` reinvests a backend-chosen percentage of harvested AERO back into the underlying pair — **both `token0` and `token1`** — while the rest still feeds the weekly drop, so the position grows over time and offsets divergence drag. The conversion is two **async CowSwap** sells (AERO→token0 and AERO→token1) gated by `SlippagePriceChecker` + EIP-1271 — mirroring `ERC20MoonwellMorphoStrategy`.
> 3. **No-swap thesis narrowed to principal.** V2 still never swaps *principal* (the IL-defining property). It now has exactly one swap path, and it is **reward-only**: AERO→underlying, oracle-bounded, never `token0↔token1`.

## 1. The IL problem

V1 re-ranges by swapping to the new range's ratio (decrease → swap surplus leg → mint). Every swap **crystallizes** impermanent loss that was, until then, only on paper — plus swap fees. On a volatile/stable pair like MAMO/USDC, divergence is large and frequent, so a swap-based auto-rebalancer can bleed more in realized IL + swap fees than it earns in trading fees + AERO. (Phase-1 deliberately starts on a correlated pair — WETH/cbBTC, §6 — where IL is small, to prove the mechanism before touching high-IL pairs.) This is the failure mode Beefy's CLM docs call out for "rebalancing-heavy" ALMs (Gamma/vfat style), where "aggregate IL ... far exceeds earnings."

**V2 adopts Beefy CLM's structural fix: never sell principal.** Excess *principal* tokens are redeployed into a single-sided "alt" position instead of swapped. IL is realized only on a true range exit (same as holding), not on every reset. Reward AERO is a separate, non-principal asset and may be partially swapped to compound (§4a) — that introduces no IL on the position.

## 2. The dual-position model (Beefy CLM, adapted)

Each managed position holds **two** Aerodrome CL position NFTs:

- **`main`** — a balanced (~50/50) position centered on the reference tick at an agent-chosen `width`. Earns trading fees (unstaked) or AERO (staked). This is the workhorse.
- **`alt`** — a single-sided position holding the **excess** token after the main is funded 50/50. Its range sits between the main's overweight boundary and the nearest valid tick on the excess side, so it holds only the surplus token and waits to be earned back into balance as price oscillates — **without any swap**.

When price drifts, the main goes out of balance; on reset we rebuild a fresh 50/50 main and park the (now larger or smaller) excess in a fresh alt. No token is ever sold to do this.

**Why only one alt side.** After a maxed 50/50 main mint, exactly **one** token is left over — never both: "balanced" means depositing the most that fits the range's ratio, which fully consumes one leg and leaves a remainder of the other. A single-sided CL range holds exactly one token (a range entirely above spot is 100% token0; entirely below is 100% token1), so one alt on the surplus side absorbs all of it. A second alt would have nothing to hold. The surplus *side* flips reset-to-reset with price; at any single reset there is only one.

**Width tradeoff (Beefy's caveat):** a too-narrow main is "quickly imbalanced by Range IL, leading to a very large alt position." So `width` is a real decision — wider main ⇒ smaller alt ⇒ more capital earning balanced fees, fewer resets. The off-chain agent picks `width` (§7); the contract bounds it (`minWidth`/`maxWidth`).

## 3. Contract: `LPAutoBalancerV2` (single-position)

The contract implements standard security protocols including `AccessControlEnumerable`, `ReentrancyGuard`, `Pausable`, `IERC721Receiver`, and **EIP-1271 `isValidSignature`** (Solidity 0.8.28, BUSL-1.1). It uses a role-based access model: `DEFAULT_ADMIN_ROLE` (assigned to the Safe), `MANAGER_ROLE`, `REBALANCER_ROLE`, and `GUARDIAN_ROLE`.

**One contract manages exactly one pool.** The previous multi-slot `positions[slotId]` registry is replaced by a single storage struct `position`. Every external function drops its `slotId` argument. This matches the deployment reality (each pool gets its own deployed contract) and removes the registry's slot-iteration surface.

The architecture is built on the following core components:

- **Position management:** tracks one position via the `position` struct, using the `POSITION_MANAGER` and `AERO` interfaces. **No principal swap** — `reset`/`exit` never sell `token0↔token1`, on any path.
- **Oracles & pricing:** the `_consultTwapTick` helper and Chainlink oracles enforce the value-floor checks. A separate `SlippagePriceChecker` bounds the reward-only AERO→underlying compound swap (§4a).
- **Core administrative functions:** `collectFees`, `claimEmissions`, `recover*` utilities, pause, and **`setPool`** (re-point an emptied contract).
- **Operational mechanisms:**
  - **`reset()`** — the primary operational function that rebuilds the dual position **without performing any principal swap**, minimizing impermanent-loss impact. It also absorbs any loose underlying produced by a settled compound (§4a) into the freshly minted main+alt.
  - **`compound(compoundBps)`** — harvests AERO, drops `(1 − compoundBps)` to `feeCollector`, and queues `compoundBps` for an async CowSwap sell into the underlying (§4a).
  - **`exit()`** — a protected, Safe-gated function that withdraws all liquidity from both the main and alt positions, burns the NFTs, and returns all underlying tokens to the Safe. This replaces V1's `migrate()`: V2 never swaps principal, so cross-pool moves are done as exit-to-Safe + redeploy, never an in-contract principal swap.

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
    uint16  maxRebalanceLossBps;// value floor (sanity guard under no principal swap)
    uint256 minRebalanceInterval;
    uint256 lastRebalance;
    bool    active;
}

// Single managed position — NOT a mapping. One contract = one pool.
ManagedPositionV2 public position;

// Compound (reward-only swap) config — contract-level, since there is one position:
ISlippagePriceChecker public slippagePriceChecker; // bounds AERO→underlying min-out
uint256 public allowedSlippageInBps;               // <= MAX_SLIPPAGE_IN_BPS
```

**Constants.** `MAX_COMPOUND_BPS` caps the per-call compound percentage (e.g. `10_000` = up to 100%, or a tighter governance bound). `MAX_SLIPPAGE_IN_BPS` caps `allowedSlippageInBps`. `VAULT_RELAYER`, `DOMAIN_SEPARATOR`, and the EIP-1271 `MAGIC_VALUE` are added for CowSwap (mirroring `ERC20MoonwellMorphoStrategy`).

**No `swapPolicy`/`protectedToken`/principal `maxSlippageBps`.** Principal swap policy is omitted because no *principal* swap ever occurs — not in `reset`, not in `exit`. The only slippage cap (`allowedSlippageInBps`) governs the reward-only AERO→underlying compound swap.

### 3.2 `reset(ResetParams params)` — `onlyRole(REBALANCER_ROLE)`, `nonReentrant`, `whenNotPaused`

```solidity
struct ResetParams {
    uint24  width;              // chosen main width; centers + aligns + bounds-checks
    uint256 amount0MinMain;     // sandwich protection for balanced mint
    uint256 amount1MinMain;
    uint256 amount0MinAlt;      // sandwich protection for single-sided alt
    uint256 amount1MinAlt;
    uint256 amount0MinWithdraw; // sandwich protection for principal withdrawal (main)
    uint256 amount1MinWithdraw;
    uint256 amount0MinWithdrawAlt; // sandwich protection for principal withdrawal (alt)
    uint256 amount1MinWithdrawAlt;
    uint256 deadline;
}
```

### 3.3 Core operational flow (the reset loop)

1. **Cooldown validation:** ensures `block.timestamp` has surpassed `lastRebalance + minRebalanceInterval`.
2. **Calm gate:** compares the `slot0` spot tick against `_consultTwapTick`; if the delta exceeds `maxTickDeviation`, reverts with `TwapDeviation`. The TWAP serves as the **reference tick**.
3. **Oracle pricing:** captures the market rate (preferring Chainlink per-leg feeds over pool TWAP) to be used consistently across both valuation checkpoints.
4. **Pre-reset snapshot:** calculates `valueBefore` by pricing the principal in the main and alt positions at the captured oracle rate, **plus any loose `token0`/`token1` already held** (donated, or compounded underlying awaiting fold). `looseBefore` is netted against `looseAfter` so a stray/compounded balance cannot inflate or mask the floor.
5. **Unstake & harvest:** removes NFTs from the gauge; `gauge.withdraw` triggers an AERO claim which is skimmed to `feeCollector`, firing `EmissionsClaimed`. (Compounding does **not** happen on reset — it is a separate `compound()` call; on reset all pending AERO is dropped.)
6. **Fee collection:** `collect(max,max)` on both positions, skimming trading fees to `feeCollector` and emitting `FeesSkimmed`. Fees are excluded from the value-floor check.
7. **Liquidity withdrawal:** `decreaseLiquidity(all)` then burns both existing NFTs. Underlying `token0`/`token1` (including any compounded underlying that settled since the last reset) are now held by the contract.
8. **Range calculation:** `_mainRange` from the reference tick + provided `width`; strictly enforces `minWidth`/`maxWidth` and `maxCenterDeviation`. A fully out-of-range (100%-single-sided) reset places the main single-sided on the funded side (no swap).
9. **Main mint:** `LiquidityAmounts` mints a balanced 50/50 position within `[tickLower, tickUpper]` at the oracle price with the slippage mins. A new `mainTokenId` is assigned.
10. **Alt mint:** deploys the surplus leg into a single-sided range from the main's overweight boundary to the nearest aligned tick. If the remainder is dust, it is forwarded to `feeCollector` and `altTokenId` stays 0. **No swap occurs.**
11. **Restaking:** the main is redeposited into the gauge if the agent's decision requires it; the alt inherits that state. Emits `Staked`.
12. **Sanity value floor:** verifies `valueAfter` (total principal + loose) ≥ `valueBefore * (BPS − maxRebalanceLossBps)/BPS + looseBefore`. Final defense against mint rounding or reference-tick manipulation.
13. `lastRebalance = block.timestamp`; emits `Reset(mainTokenId, altTokenId, tickLower, tickUpper)`.

### 3.4 Stake / unstake

`stake()` / `unstake()` operate on the **main**, and the **alt follows**: when `altTokenId != 0` and `gauge != 0`, the alt is staked/unstaked alongside. The agent decides the main's stake state (AERO-vs-fees, §7); the alt is a transient buffer that inherits it. (A single-sided alt may sit outside the gauge's active range and earn little AERO — acceptable; it is short-lived between resets and the bookkeeping stays simple.)

### 3.5 `getDecisionSnapshot()` — view (extended for V2)

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

function getDecisionSnapshot() external view returns (DecisionSnapshotV2 memory);
```

A consolidated, atomic on-chain view for the agent's discovery and completion stages, augmented with alt-position data. `mainInRange == false` is the primary reset signal; a large `altLiquidity` relative to `mainLiquidity` is a diagnostic for persistent divergence or an overly restrictive width.

### 3.6 `exit(address to)` — `onlyRole(DEFAULT_ADMIN_ROLE)`, `nonReentrant`

Safe-gated emergency / migration primitive. Unstakes both NFTs if staked (skimming AERO to `feeCollector`), collects fees, `decreaseLiquidity(all)`, burns both NFTs, and transfers **all** underlying `token0`/`token1` to `to` (the Safe). Marks the position inactive and zeroes the NFT ids. No principal swap — the Safe decides what to do with the returned tokens (e.g. redeploy into a new pool via `setPool`). This is the seam that Phase-2 (§6) automates behind safety rails.

### 3.7 `setPool` — re-point an emptied contract — `onlyRole(DEFAULT_ADMIN_ROLE)`

Because one contract manages one pool, changing the pool is an explicit, Safe-gated re-registration:

- `registerPosition(config)` is the **first** registration. It reverts (`AlreadyRegistered`) if a position is already `active`.
- **`setPool(config)`** re-points the contract at a new pair. It requires the contract to be **empty** — `!active`, `mainTokenId == 0`, `altTokenId == 0` — i.e. a prior `exit()` (or `deregisterPosition`) has run. It performs the same validation as `registerPosition` (pool/token/tickSpacing cross-checks, oracle probes, gauge reward-token check, NFT ownership + pool binding) on the new pool, then stores the fresh config and emits `PoolChanged`. `registerPosition` and `setPool` share one internal validate-and-store path; `setPool` is the named entry for the "change the pool" operation.

**Flow to change pool:** Safe calls `exit(safe)` → liquidates/acquires the new pair off-contract → mints the new pool's NFT off-contract → `safeTransferFrom`s it in → `setPool(newConfig)`. Identical to the phase-1 funding path (§6), just reusing an already-deployed contract. The contract never holds two pools' positions at once.

## 4. Fees / AERO / drop economics

LP trading fees (unstaked) and the **non-compounded** share of AERO (staked) are skimmed to `feeCollector` (`DropAutomation`) on every `reset` / `collectFees` / `claimEmissions` / `compound`. **LP fees are always 100% dropped** — only AERO is ever partially compounded.

### 4a. AERO compounding (CowSwap, async, reward-only)

**Goal.** Reinvest a backend-chosen percentage of harvested AERO back into the underlying pair so the position grows over time and offsets divergence drag, while the remainder continues to feed the weekly drop.

**Why a swap is needed (and why it is safe).** AERO is neither `token0` nor `token1` (for WETH/cbBTC it is a third token), so compounding it into the position requires converting AERO→underlying. The contract compounds into **both** legs — two CowSwap sells, AERO→token0 and AERO→token1, split ~50/50 by value so the proceeds fold into a balanced main (the reset rebuilds a 50/50 main centered on spot, so a 50/50-by-value buy maximizes how much lands in the main and minimizes alt spillover). These are the **only** swap paths in V2, and they are **reward-only**: they never touch principal `token0↔token1`, so they crystallize no impermanent loss. Each is bounded by a Chainlink-backed `SlippagePriceChecker` and gated by EIP-1271, exactly as `ERC20MoonwellMorphoStrategy` swaps its Merkl rewards.

**`compound(uint16 compoundBps)` — `onlyRole(REBALANCER_ROLE)`, `nonReentrant`, `whenNotPaused`:**

1. Require `compoundBps <= MAX_COMPOUND_BPS`.
2. Harvest AERO from the gauge via `gauge.getReward(mainTokenId)` (and the alt if `altStaked`) — claims AERO to the contract **without unstaking**. Combined with any AERO already held.
3. Compute `dropAmount = aero * (BPS − compoundBps) / BPS` and `safeTransfer` it to `feeCollector` **immediately** — the drop. Emit `EmissionsClaimed` for the dropped amount.
4. The remaining `compoundBps` share stays on the contract; `forceApprove(VAULT_RELAYER, ...)` so the CowSwap solver can pull it. Emit `CompoundInitiated(compoundAmount)`.
5. **Off-chain (bot):** posts **two** CowSwap **sell** orders — AERO→token0 and AERO→token1 — splitting `compoundAmount` ~50/50 by value. CowSwap validates each via this contract's `isValidSignature` (which permits `buyToken ∈ {token0, token1}`). Their combined sell is bounded by the contract's remaining AERO balance, so they cannot eat into the already-transferred drop.
6. **Settlement (async):** the solver delivers **both** `token0` and `token1` to the contract. They sit as **loose balances** and are absorbed into a balanced main (with minimal alt spillover) at the **next `reset()`** (the existing mint reads `balanceOf(this)` and redeploys with no swap; the value floor counts them). The position grows step-wise per reset.

**`isValidSignature(orderDigest, encodedOrder)` — EIP-1271 view.** Mirrors `ERC20MoonwellMorphoStrategy.isValidSignature`, adapted:

- `_order.hash(DOMAIN_SEPARATOR) == orderDigest`; `kind == SELL`; fill-or-kill (`!partiallyFillable`); ERC20 sell/buy balances; `validTo` within `[now + 5 min, now + maxTimePriceValid(sellToken)]`.
- `sellToken == AERO`.
- **`buyToken == token0 || buyToken == token1`** (the position's underlying — never an arbitrary token). The two compound orders are validated independently: one buys `token0`, the other `token1`.
- `receiver == address(this)`; `feeAmount == 0`.
- `slippagePriceChecker.checkPrice(sellAmount, sellToken, buyToken, buyAmount, allowedSlippageInBps)` must pass.
- The drop is taken on-chain in step 3, so **no fee pre-hook / appData fee-transfer is required** — simpler than the strategy's order (the exact `appData` policy is pinned in the implementation plan). Settlement is bounded by the contract's AERO balance regardless of the order's stated `sellAmount`.

**Setters.** `setSlippage(uint256)` (`onlyRole(DEFAULT_ADMIN_ROLE)`, `<= MAX_SLIPPAGE_IN_BPS`) and `setSlippagePriceChecker(address)` / `approveCowSwap(...)` mirror the strategy. AERO must be a configured reward token in the `SlippagePriceChecker` for the pair before compounding.

## 5. Value floor under no principal swap

In V1, the value floor was the fundamental constraint on realized market loss during rebalancing (the swap). Since V2 eliminates the *principal* swap entirely, the primary cause of crystallized IL is removed. The floor is preserved as a **sanity guard**: it intercepts mint-ratio rounding, reference-tick manipulation that might skew the main, or structural flaws in `LiquidityAmounts`. Loose balances (donations or settled-but-unfolded compound proceeds) are netted via `looseBefore`/`_contractPairValue` so they neither inflate headroom nor mask a real loss. During standard operation it resolves with significant margin; any failure indicates a structural anomaly where an immediate revert is the intended behavior.

## 6. Scope & phasing

Two phases of improved yield generation:

### Phase-1 (immediate) — validate the no-principal-swap model on WETH/cbBTC

- **Initial pair: WETH/cbBTC** — a highly correlated pair (minimal IL) with a live Aerodrome CL **gauge** for AERO emissions. The strategic starting point because: (a) correlation ⇒ a compact alt and negligible IL, so mechanical failures in the reset logic surface without being masked by price divergence; (b) it validates the AERO-staking + compounding integration; (c) the small initial allocation limits TVL-at-risk during proof-of-concept.
- **Displaces MAMO/USDC** as the primary testbed. MAMO-incentivized pools in `TransferAndEarn` remain unaltered this phase.
- **Funding via Safe (external to the agent, § trust model):** governance liquidates lagging `TransferAndEarn` holdings into **WETH + cbBTC**, mints the initial WETH/cbBTC NFT manually (off-contract), transfers the NFT to `LPAutoBalancerV2`, and calls `registerPosition` with active gauging, Chainlink price feeds (WETH/USD + cbBTC/USD), and a `SlippagePriceChecker` configured for AERO→WETH / AERO→cbBTC. `REBALANCER_ROLE` is restricted to `reset`/`stake`/`unstake`/`claimEmissions`/`compound` — it has **no principal-sell capability** (compound only sells reward AERO, oracle-bounded); the trust model centralizes all principal value-shifting in the Safe.
- **Goal:** verify the no-principal-swap reset preserves principal through real market shifts, the automated stake/unstake logic is sound, and partial AERO compounding grows the position — before broader deployment.

### Phase-2 (long term) — automated cross-pool migration into the best pair

- **Automated inter-pool migration:** systematically liquidate positions in underperforming pairs and redeploy into higher-yield opportunities (e.g. MAMO/VVV). With one-contract-per-pool, this is `exit()` → `setPool(newPair)` automated behind safety rails (previously a manual, Safe-gated operation). Previously restricted due to open-destination swap / TWAP-manipulation risk; V2 introduces the infrastructure to bridge the gap.
- **Migration safety rails (deployment prerequisites):** a governance-sanctioned **allowlist** of destination pools, mandatory **Chainlink-based value floors for both assets** (never a potentially-compromised pool TWAP), and **min-TVL / liquidity-depth** gates. Each move inherits the cooldown + value-floor protections from `reset`. Automated migration stays blocked until a robust price feed or allowlist entry is secured (MAMO/VVV included).
- The off-chain companion gains a **migration-decision capability** using LpSugar + DefiLlama for pool scoring, ranking destinations and executing within the approved allowlist — extending the core discovery funnel.

### Out of scope (both phases)

veAERO; the locked `BurnAndEarn` MAMO/VIRTUALS LP; **autonomous migration without the Phase-2 safety rails above**; compounding of **LP fees** (only AERO is compounded; fees always feed the drop); any swap of **principal** `token0↔token1`.

## 7. Off-chain agent

The off-chain companion is a goal-gated agent governing the liquidity lifecycle. It uses a continuous discovery funnel to keep positions aligned with market shifts **without ever triggering a principal swap**.

**Discovery funnel.** The agent runs a persistent loop, inspecting position health via the `DecisionSnapshotV2` view. Execution follows a strict heuristic:

- **Reset candidacy:** a `reset()` is offered only when health criteria align — the main is out of range (`mainInRange == false`), the calm gate confirms price stability (`deviationGateOpen == true`), and `cooldownRemaining == 0`.
- **Parameter choice:** the agent's primary mandate is picking `width` — balancing capital efficiency (narrower concentrates liquidity) against the resulting alt size. It also selects the staking strategy: unstaked (fees) vs staked (AERO emissions).
- **Compound decision:** between resets the agent may call `compound(compoundBps)`, choosing how much of harvested AERO to reinvest vs drop (bounded by `MAX_COMPOUND_BPS`), then posts the bounded CowSwap order. Higher `compoundBps` grows the position faster (offsets divergence drag); lower favors the weekly drop.

**Completion gate & diagnostics.** After `reset()`, the agent enters a completion gate to verify mechanical success against an **independent** chain re-read:

- **State alignment:** confirms the main is in range and the staking state matches the decision intent.
- **Asset reconciliation:** verifies trading fees and the dropped AERO share were skimmed to `feeCollector`, and any settled compound proceeds were folded into the rebuilt position.
- **Diagnostic analysis:** monitors `altLiquidity`. Since V2 never sells principal on reset, a bloated alt is a diagnostic for persistent divergence — if alt liquidity grows too large relative to the main, the agent flags `GOAL NOT MET`, indicating the width is too restrictive.

This feedback loop lets the agent autonomously adapt to volatility while safeguarding principal across the position lifecycle. (Full agent design — goal-gated turn loop, sandbox-`cast` execution, `eth_call` gate, circuit-breaker — in the companion spec.)

## 8. Testing

- **Reset (unit, mocks):** out-of-range → `reset(width)` rebuilds a 50/50 main + single-sided alt with **no principal-swap call**; fees/AERO skimmed; both old NFTs burned; new `mainTokenId`/`altTokenId` set; value floor passes; dust forwarded; alt skipped when leftover is dust. **Loose underlying (simulating settled compound proceeds) present at reset is folded into the rebuilt main+alt and counted by the value floor.**
- **Calm gate / cooldown / width bounds / value-floor / stale-oracle** — ported from V1.
- **Stake/unstake:** main staked → alt follows; unstake roundtrip; `claimEmissions` sums both NFTs.
- **`exit` (Safe-gated):** non-admin reverts; admin withdraws both NFTs, burns them, returns all `token0`/`token1` to `to`, marks inactive, zeroes NFT ids, skims fees/AERO; no principal swap.
- **Single-position / `setPool`:** `registerPosition` reverts (`AlreadyRegistered`) when a position is already active; after `exit`, `setPool(newConfig)` re-validates and re-points to a new pair and emits `PoolChanged`; `setPool` reverts if not empty (active or NFT ids non-zero); all external fns take no `slotId`.
- **Compound (unit, mocks):** `compound(compoundBps)` claims AERO, transfers `(BPS−compoundBps)` to `feeCollector`, leaves `compoundBps` approved to `VAULT_RELAYER`; reverts when `compoundBps > MAX_COMPOUND_BPS`. `isValidSignature` returns `MAGIC_VALUE` for **both** a valid AERO→token0 sell and a valid AERO→token1 sell (the two-order, both-legs split), and reverts on: wrong `sellToken` (not AERO), `buyToken` not in {token0,token1}, `receiver != this`, partial fill, expired/too-far `validTo`, and failing `checkPrice`. `setSlippage` bounds at `MAX_SLIPPAGE_IN_BPS`.
- **getDecisionSnapshot V2:** main+alt ranges, `mainInRange`, `hasAlt`, `altLiquidity`, `cooldownRemaining`, `deviationGateOpen`, staked-path `earnedAero` (try/catch).
- **Adversarial:** manipulated spot (calm gate reverts), lopsided forced mint (value floor reverts), pre-cooldown, mint sandwich bounded by min-amounts. **Assert no PRINCIPAL swap path exists** — `reset`/`exit` never call the vault relayer and never sell `token0↔token1`; the only sell path is AERO→underlying in the compound flow (the IL-defining property).
- **Integration (Base fork):** bootstrap the real WETH/cbBTC position (mint from held WETH+cbBTC, transfer NFT in, register gauged with WETH/USD + cbBTC/USD oracles + AERO `SlippagePriceChecker`), push the tick out of range, `reset(width)` → assert dual-position rebuilt **without selling principal** (token0/token1 balances conserved within mint rounding, zero principal-router calls), fees/dropped-AERO to `DropAutomation`, `mainInRange == true` after, old NFTs burned, `Reset` emitted. Simulate a settled compound (drop loose **token0 AND token1** on the contract) and assert both fold into a balanced main at the next reset. Exercise `exit` → `setPool` re-point to a second pair.
- **FPS proposal test:** deploy `LPAutoBalancerV2` (per-pool), run the Safe setup (acquire → mint → transfer → register + configure SlippagePriceChecker), validate.
