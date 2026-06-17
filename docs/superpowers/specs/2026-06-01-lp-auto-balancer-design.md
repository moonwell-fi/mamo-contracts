# LP Auto-Balancer — Design

**Date:** 2026-06-01
**Status:** Implemented — see docs/superpowers/plans/2026-06-04-lp-auto-balancer-implementation.md (contract + tests on branch feat/lp-auto-balancer). Previously: Revised after review (design) — incorporates F-MAMO review feedback (PR #54)
**Author:** Ana Julia + Claude

> **Revision note (post-review).** This draft was revised to address review comments from Luke:
> (1) **AERO emissions are a first-class goal** — the contract stakes CL position NFTs in their Aerodrome gauges to farm AERO, not just trading fees, achieving capability parity with the `aerodrome-auto-balance` module (Section 5).
> (2) **Scope expands beyond MAMO pairs** — deep, high-volume correlated pools (e.g. cbBTC/WETH) are explicitly in scope because AERO farming performs best there; rollout is phased: start with a small amount of TVL and expand as the strategy proves out (Section 7).
> (3) **Tick & swap-size discretion moves on-chain** — the contract now computes target ticks (from the live tick + a bounded `width`) and the swap amount itself; the off-chain caller no longer supplies raw ticks or swap size (Sections 3.1, 4.4). This is the central change from the previous draft.
> (4) **On-chain min-amount enforcement is explicit** — value-bearing minimums are recomputed on-chain from the Aerodrome Quoter and cannot be weakened by the caller (Section 3.1).
> (5) **One contract manages many positions** — a `slotId` registry, stated up front (Section 1).
> (6) **The value floor is a single-transaction measurement** — there is no separate `snapshot()` call and no multi-block timing (Section 4.4).
> (7) **Per-position swap-leg policy** — a position can be configured to *never sell MAMO* and only sell the counter-asset, which is the default for initial testing (Section 3.3).
> (8) **LLM pool-discovery is demoted to a nice-to-have** — migration destinations are chosen by periodic human analysis; the discovery pipeline is future/optional (Section 8.3).
> (9) **MAMO has a live Chainlink feed** — `MAMO / USD` at `0xeF7541b388a77C1709a3d44BfBfC5c1ED3F0Ac94` on Base (8 decimals). The previous "no Chainlink feed" claim was an error. The value floor now prices against this feed when configured, which also resolves the thin-pool TWAP caveat (Sections 3.1, 9).

> **Revision 2 (2026-06-17) — LLM decisioning is promoted from nice-to-have to the brain.** The off-chain role is no longer a dumb "trigger + bounded width" service. It is a **goal-gated LLM agent** that decides, per run: (a) whether/how to re-range (width), and (b) **whether to gauge-stake the position to farm AERO emissions or stay unstaked to earn trading fees** ("stack AERO vs earn LP rewards"). The agent reuses the goal-gated multi-turn loop pattern from `centaur-moonwell` PR #36 (`feat(agent-loops): goal-gated turns`): an explicit GOAL in the prompt + a workflow completion gate that re-reads chain state after every turn and feeds back `GOAL NOT MET: <reason>`. The decision architecture is **deterministic funnel + LLM judgment on the margin** (gather/compute/pre-filter in code → LLM picks a vetted candidate → code executes → gate re-checks). The agent is specified in §11 here and in full in `centaur-moonwell` at `docs/superpowers/specs/2026-06-17-lp-balancer-agent-design.md`. **Trust model is unchanged:** the agent is just another `REBALANCER_ROLE` caller, bounded by every on-chain guard; a hallucinating LLM gets a revert, not a loss. **Phase-1 scope is reduced to a single position — MAMO/USDC (tokenId 21585074)** — see §7. The AERO-stack half auto-gates on `pos.gauge != 0`: when no gauge is configured, the funnel never emits a stake candidate and the agent runs rebalance-only, with no separate code path.

## 1. Problem & Goal

Protocol-owned Aerodrome concentrated-liquidity (CL) positions that fund the weekly MAMO drop currently sit **static and full-range** (`tickLower -887200` / `tickUpper 887200`, tickSpacing 200) inside the `TransferAndEarn` contract. The only operation performed on them today is fee collection (`earn()` → fee collector → `DropAutomation` → weekly drop). They are never re-ranged and never staked, so they are doubly capital-inefficient: a full-range position earns a small fraction of the fees a tight, centered range would earn for the same capital, **and** it forgoes the AERO emissions a staked position would earn.

**Goal:** maximize the yield these positions generate for the weekly drop through **two complementary yield sources**:
- **(A) Trading-fee yield** — concentrate liquidity into tight ranges around spot and re-center as price drifts (a general, per-position-configurable rebalancer).
- **(B) AERO emissions** — stake the CL position NFTs in their Aerodrome gauges to farm AERO, then route the AERO back into the drop. Emissions farming is strongest in deep, high-volume, correlated-asset pools (e.g. cbBTC/WETH), so the design is **not limited to MAMO pairs**.

Inspired by `aerodrome-auto-balance`, adapted to Mamo's protocol-owned-liquidity + Safe-governed model, with the goal of **capability parity** with that module (re-ranging **and** gauge staking).

**One contract, many positions.** A single `LPAutoBalancer` holds and manages an arbitrary set of positions through a `slotId` registry (Section 3.3). It is *not* one contract per position. New pools are added later via `registerPosition` — no redeploy.

This is delivered as two workstreams:
- **On-chain:** a new `LPAutoBalancer` contract (this spec, Sections 3–6) — primary deliverable.
- **Off-chain:** a rebalancing service (Section 7) — documented here, implemented separately. With tick/swap computation now on-chain (decision below), the off-chain role shrinks to *triggering* and choosing a *bounded width*.

## 2. Decisions (from brainstorming + review)

| Decision | Choice |
| --- | --- |
| Primary goal | General yield-max from **two sources**: fee concentration/re-centering **and** AERO emissions via gauge staking, configurable per position |
| Custody/logic location | **New standalone `LPAutoBalancer`** contract holding the NFTs; **multi-position** registry (`slotId`) |
| Yield source per position | **Either** unstaked (earns trading fees) **or** gauge-staked (earns AERO emissions instead of fees) — chosen per position by whichever yields more; switchable |
| Scope | **Generic multi-position registry; not limited to MAMO pairs.** Deep correlated pools (cbBTC/WETH) explicitly in scope for emissions farming. **Phased rollout**: start with a small amount of TVL, expand as proven |
| Access control | **`AccessControlEnumerable` role split** (not `Ownable`): admin = F-MAMO Safe (drain-capable powers + caps), `MANAGER_ROLE` = EOA (tune bounds within caps), `rebalancer` = EOA (re-range/stake/claim), guardian = EOA/Safe (pause) |
| **Tick & swap discretion** | **On-chain.** The contract computes target ticks from the live tick + a **bounded `width`**, and computes the swap amount on-chain to reach the new range's ratio. The caller supplies only `width` (bounded) + min-amount floors + deadline — **never raw ticks or swap size.** (Addresses review: offchain tick/swap discretion was undesirable.) |
| Value-bearing minimums | **Recomputed on-chain** from the Aerodrome Quoter at the per-position slippage cap; an off-chain floor can only make them *tighter* (`max(quoterMin, callerMin)`), never looser |
| Pool selection / migration | Re-ranging stays within governance-registered pools. Changing pool/pair = `migrate()`, **Safe-admin-gated**, open destination. LLM pool-discovery is **a nice-to-have**, not required — periodic human analysis decides migrations (Section 8) |
| Trigger model | **Backend-decided trigger + bounded width + on-chain guards** (mirrors `DropAutomation`) |
| Fee/emission handling | Re-range only re-ranges principal. **Trading fees** (unstaked positions) and **claimed AERO** (staked positions) are skimmed to the fee collector (`DropAutomation`), preserving the drop economics |
| Swap-leg policy | **Per-position.** A position can be set to *never sell MAMO* (sell only the counter-asset). **Default for initial testing: counter-asset only.** |
| Safety model | per-swap slippage cap + per-position cooldown + width bounds + decrease/mint min-amounts, **plus** a **value floor** (`maxRebalanceLossBps`) priced against the **Chainlink MAMO/USD feed when configured** (pool TWAP fallback) and a **spot-vs-TWAP deviation gate** (`maxTickDeviation`) |
| Operator | **No Gelato.** A dedicated `rebalancer` EOA; owner can rotate/revoke instantly |
| Authorization | **Re-ranges fully autonomous** (bounded by on-chain guards + a service-side circuit-breaker). **Migrations Safe-gated** |

## 3. On-chain Contract: `LPAutoBalancer`

`AccessControlEnumerable`, `ReentrancyGuard`, `Pausable`, `IERC721Receiver`. Solidity 0.8.28, BUSL-1.1 (matches repo). Uses the same role model as `MamoStrategyRegistry` / `MamoStakingRegistry` rather than `Ownable`, so day-to-day operation runs on an EOA while drain-capable powers stay on the Safe.

### 3.1 Trust boundary

The off-chain service supplies only a **bounded `width`** and value-bearing **min-amount floors**; the contract derives everything value-relevant itself. The contract still treats `rebalance()` params as **potentially adversarial** (compromised key) and every guard holds against attacker-chosen inputs — but the attack surface is far smaller than the previous draft because:

- **Ticks are computed on-chain**, not supplied. The caller picks `width ∈ [minWidth, maxWidth]`; the contract centers the range on the live tick (clamped to the spot-vs-TWAP deviation gate), aligns to `tickSpacing`, and rejects anything outside bounds. A compromised key can choose *how wide*, within admin bounds, but not *where*.
- **The swap amount is computed on-chain** from current holdings and the target ratio for the new range (`LiquidityAmounts`). The caller cannot direct an oversized or wrong-direction swap.
- **Min-amounts are recomputed on-chain.** `swapMinAmountOut` is derived on-chain from the Aerodrome **Quoter** at `pos.maxSlippageBps`: `quoterMin = quotedOut * (BPS - maxSlippageBps) / BPS`. The caller-supplied `swapMinAmountOut` is used only as `effectiveMin = max(quoterMin, callerMin)` — it can tighten the floor but never loosen it. So even a zero or garbage caller value cannot weaken slippage protection. (Answers the review question "how can we trust off-chain min-amounts?" — we don't; the on-chain quoter floor is authoritative.)

On top of the per-step guards, two **outcome-based guards** bound the net result of the whole decrease+swap+mint:

- **Value floor (`maxRebalanceLossBps`)** — the position's principal is valued **before and after, inside the same transaction**, and the call reverts unless `valueAfter >= valueBefore * (1 - maxRebalanceLossBps)`. Pricing source per position:
  - **Chainlink `MAMO/USD` (`0xeF7541b388a77C1709a3d44BfBfC5c1ED3F0Ac94`, 8 decimals)** when `pos.valueOracle` is set — an external, manipulation-resistant oracle. This is the preferred source for MAMO-leg pools and **resolves the thin-pool caveat** (a thin pool's own TWAP can be pushed; a Chainlink feed cannot).
  - **Pool TWAP** fallback when no feed is configured (e.g. a non-MAMO correlated pool whose legs both have feeds can use those, or fall back to the pool TWAP) — needs no external oracle but is only as strong as pool depth.
  This directly bounds per-call value loss regardless of the chosen width/swap.
- **Spot-vs-TWAP deviation gate (`maxTickDeviation`)** — the call reverts if the spot tick deviates from the pool TWAP tick by more than `maxTickDeviation`, refusing to act during a price spike or a manipulation attempt, and the range is centered on a tick that has passed this gate.

**Single-transaction snapshot — no separate `snapshot()` call.** `valueBefore` and `valueAfter` are both computed *within* the one `rebalance()` transaction: `valueBefore` from the current position's principal before liquidity is decreased, `valueAfter` from the freshly minted position's principal after the swap+mint **plus the post-mint leftover pair-token balances** (which step 12 forwards to the feeCollector — an internal transfer to a trusted sink, not a market loss). Contract-held pair balances measured at the start of the call are netted out on the other side, so a pre-existing stray balance cannot mask a genuine loss. The floor therefore bounds exactly *market* loss (swap fees, slippage, rounding). This matters under a protective `swapPolicy`: when holdings drift heavy on the protected side, the re-ratio swap is forbidden and the excess structurally exits as feeCollector dust — counting that as "loss" would brick rebalancing precisely when the market moves. Both measurements are priced at the *same* oracle observation read at the start of the call, so there is no time gap to exploit and no operator step to remember. (Answers the review question about snapshot timing/duration — it is atomic, not a two-call dance.)

Net: worst-case value loss per call is bounded to ≈ `maxRebalanceLossBps` (the tighter of it and `maxSlippageBps` on the swapped portion); the deviation gate blocks acting on a manipulated spot; the cooldown rate-limits cumulative damage; the owner kill-switch (`pause` / revoke `rebalancer`) stops it entirely.

### 3.2 Roles

Powers are split so an EOA can run operations without any single key being able to move or drain protocol liquidity. The drain-capable functions (`migrate`, `withdrawPosition`, `recoverERC20`/`recoverETH`) and all *cap*-setting stay on the Safe.

- **`DEFAULT_ADMIN_ROLE` = F-MAMO Safe** — `registerPosition`/`deregisterPosition`, `migrate` (Section 8), `withdrawPosition`, `recoverERC20`/`recoverETH`, set the global caps (`MAX_SLIPPAGE_CAP_BPS`, `MAX_LOSS_CAP_BPS`), set per-position `valueOracle` and `swapPolicy`, grant/revoke all roles (including `rebalancer`).
- **`MANAGER_ROLE` = EOA** — fast operational tuning *within* admin-set caps: per-position `minWidth/maxWidth/maxCenterDeviation/maxSlippageBps/maxRebalanceLossBps/maxTickDeviation/twapWindow/minRebalanceInterval`. **No** power to move, migrate, withdraw, or redirect funds. (`setFeeCollector` was moved to admin after the security review — it routes all fee/AERO/dust flows, so it is a drain-direction power kept off the hot EOA.)
- **`rebalancer` = a dedicated EOA (`MAMO_LP_REBALANCER`)** — may **only** call `rebalance()`, `collectFees()`, `stake()`/`unstake()`, and `claimEmissions()`. No custody, no config.
- **`GUARDIAN_ROLE` = EOA or Safe** — `pause()`/`unpause()`.

Rationale: re-ranging and gauge actions are bounded by on-chain guards and can only ever route value to the configured `feeCollector`, so they run on a hot key; migration has no enforceable on-chain value protection (Section 8), so it stays behind the multisig. `MANAGER_ROLE` can only loosen/tighten bounds **between** the admin-set caps, so a compromised manager key cannot exceed limits the Safe set.

### 3.3 State

```solidity
struct ManagedPosition {
    uint256 tokenId;            // current Aerodrome CL NFT; changes every rebalance/migrate
    address pool;               // CL pool — source of truth for tickSpacing + current tick (slot0)
    address token0;
    address token1;
    int24   tickSpacing;
    address gauge;              // Aerodrome CL gauge for this pool (address(0) => no gauge / never staked)
    bool    staked;             // true if tokenId is currently staked in `gauge` earning AERO
    address feeCollector;       // skim destination for fees + claimed AERO; defaults to DROP_AUTOMATION
    address valueOracle;        // Chainlink feed used to price the value floor (address(0) => pool-TWAP fallback)
    uint8   swapPolicy;         // 0 = either leg; 1 = sell counter-asset only (never sell `protectedToken`); 2 = sell protectedToken only
    address protectedToken;     // token the swapPolicy protects (e.g. MAMO)
    uint24  minWidth;           // min allowed (tickUpper - tickLower), tick units
    uint24  maxWidth;           // max allowed (tickUpper - tickLower), tick units
    uint24  maxCenterDeviation; // computed range center must be within N ticks of the (gated) reference tick
    uint16  maxSlippageBps;     // hard cap on swap slippage (<= MAX_SLIPPAGE_CAP_BPS)
    uint32  twapWindow;         // seconds for the pool TWAP used by the deviation gate (+ value floor when no feed)
    int24   maxTickDeviation;   // max allowed |spot tick - TWAP tick| before rebalance is refused
    uint16  maxRebalanceLossBps; // value floor: post-value >= pre-value * (1 - this) (<= MAX_LOSS_CAP_BPS)
    uint256 minRebalanceInterval; // cooldown seconds
    uint256 lastRebalance;      // timestamp of last rebalance
    bool    active;
}

mapping(uint256 slotId => ManagedPosition) public positions;  // one contract, many positions
uint256 public nextSlotId;
address public rebalancer;

// Immutables wired at construction:
INonfungiblePositionManager public immutable POSITION_MANAGER; // Aerodrome (Slipstream)
ISwapRouter public immutable AERODROME_ROUTER;
IQuoter     public immutable AERODROME_QUOTER;
address     public immutable AERO;                            // AERO token, forwarded on claim
```

Global constants: `MAX_SLIPPAGE_CAP_BPS` (e.g. 500 = 5%), `MAX_LOSS_CAP_BPS` (e.g. 500 = 5%), `BPS_DENOMINATOR = 10_000`, `SWAP_DEADLINE_BUFFER`, `CHAINLINK_STALENESS` (max age for `valueOracle` answers, e.g. 24h + buffer — reverts on a stale/zero answer).

**Swap-leg policy (`swapPolicy`/`protectedToken`).** When the on-chain swap computation determines which leg is in surplus, `swapPolicy` constrains it:
- `1` (counter-asset only) — if reaching the target ratio would require selling `protectedToken` (MAMO), the contract **skips the swap** and mints with whatever ratio is achievable by selling only the counter-asset (or reverts if that is impossible within bounds). This is the **default for the initial test positions** so the strategy never sells MAMO while being proven out.
- `0` (either) — sell whichever leg is in surplus (full re-balancing).
- `2` (protected only) — the inverse, rarely used.

### 3.4 CL-gauge interface (new)

The repo's `IAerodromeGauge` is the **v2 (ERC20-LP) gauge** interface and does **not** apply to CL positions. CL/Slipstream gauges stake the **position NFT by `tokenId`** and pay **AERO in lieu of trading fees**. A new interface is required:

```solidity
interface ICLGauge {
    function deposit(uint256 tokenId) external;                 // stake NFT
    function withdraw(uint256 tokenId) external;                // unstake NFT (auto-claims AERO)
    function getReward(uint256 tokenId) external;               // claim AERO for a staked NFT
    function earned(address account, uint256 tokenId) external view returns (uint256);
    function rewardToken() external view returns (address);     // AERO
    function stakedContains(address depositor, uint256 tokenId) external view returns (bool);
}
```

**Fees-vs-emissions tradeoff.** When a CL position is staked in its gauge, swap fees accrue to the gauge (the protocol/voters), and the LP earns **AERO emissions instead**. So staking is a *yield-source switch*, chosen per position based on which is higher at the time. Unstaked → trading fees feed the drop; staked → claimed AERO feeds the drop. The `rebalancer` may flip a position between the two via `stake()`/`unstake()`.

## 4. Core operations

### 4.1 `stake(uint256 slotId)` / `unstake(uint256 slotId)` — `onlyRebalancer`, `nonReentrant`, `whenNotPaused`

- `stake`: requires `pos.gauge != address(0)` and `!pos.staked`; `POSITION_MANAGER.approve(gauge, tokenId)`; `gauge.deposit(tokenId)`; `pos.staked = true`; emit `Staked`.
- `unstake`: requires `pos.staked`; `gauge.withdraw(tokenId)` (returns the NFT and auto-claims AERO to the contract); forward any AERO to `pos.feeCollector`; `pos.staked = false`; emit `Unstaked` + `EmissionsClaimed`.

### 4.2 `claimEmissions(uint256 slotId)` — **permissionless**, `whenNotPaused`

For a staked position, `gauge.getReward(tokenId)` then forward the claimed AERO to `pos.feeCollector` (DropAutomation, which already swaps reward tokens into MAMO for the drop — AERO must be whitelisted there). Permissionless because funds can only ever move to the owner-configured `feeCollector`. Emit `EmissionsClaimed`.

### 4.3 `collectFees(uint256 slotId)` — **permissionless**, `whenNotPaused`

For an **unstaked** position, standalone fee skim between rebalances so the drop keeps its cadence without forcing a re-range. `collect(tokenId, max, max)` → forward both tokens to `pos.feeCollector`. Permissionless (caller cannot choose the destination). Emit `FeesSkimmed`. (No-op/skip for staked positions — they have no claimable fees, only AERO via `claimEmissions`.)

### 4.4 `rebalance(uint256 slotId, RebalanceParams params)` — `onlyRebalancer`, `nonReentrant`, `whenNotPaused`

```solidity
struct RebalanceParams {
    uint24  width;              // desired (tickUpper - tickLower); contract centers + aligns + bounds-checks
    uint256 swapMinAmountOut;   // optional EXTRA floor only; effective = max(quoterMin, this)
    uint256 amount0MinDecrease; // withdrawal sandwich guard
    uint256 amount1MinDecrease;
    uint256 amount0MinMint;     // mint sandwich guard
    uint256 amount1MinMint;
    uint256 deadline;
}
```

The caller no longer supplies ticks, swap direction, or swap size — those are derived on-chain.

Execution order (fee/emission-then-principal separation is the key trick):

1. **Cooldown**: `require(block.timestamp >= pos.lastRebalance + pos.minRebalanceInterval)`.
2. **TWAP deviation gate**: read spot tick (`slot0().tick`) and the TWAP tick over `pos.twapWindow` (`OracleLibrary.consult`); `require(|spot - twap| <= pos.maxTickDeviation)` else revert `TwapDeviation`. The TWAP tick is the **reference tick** the new range is centered on.
3. **Read pricing oracle**: if `pos.valueOracle != 0`, read Chainlink `MAMO/USD` (revert on stale/zero answer beyond `CHAINLINK_STALENESS`); else use the pool TWAP `sqrtPriceX96`. Hold this single observation for both value snapshots.
4. **Snapshot pre-value**: value the *current* position's principal in a single numeraire at the oracle price → `valueBefore`.
5. **Unstake if staked**: if `pos.staked`, `gauge.withdraw(tokenId)` (auto-claims AERO); forward AERO to `pos.feeCollector` (emit `EmissionsClaimed`). The NFT is now held by the contract.
6. **Collect fees only**: `collect(tokenId, max, max)` *before* decreasing liquidity collects only accrued `tokensOwed` (fees, for a previously-unstaked position). Forward to `pos.feeCollector` → keeps the drop fed. Emit `FeesSkimmed`. (Fees/AERO are excluded from the value-floor comparison — only principal is measured before/after, since fees deliberately leave the contract.)
7. **Decrease all liquidity**: `decreaseLiquidity(tokenId, liquidity, amount0MinDecrease, amount1MinDecrease, deadline)`; then `collect(tokenId, max, max)` to pull principal into the contract.
8. **Compute the new range on-chain** from the reference tick + `params.width`:
   - `require(pos.minWidth <= width <= pos.maxWidth)` else `WidthOutOfBounds`;
   - center on the reference tick, align both bounds to `tickSpacing`, set `tickLower/tickUpper` so the range straddles the current tick;
   - sanity-check `|center - referenceTick| <= pos.maxCenterDeviation` (near-zero by construction; guards rounding).
9. **Compute the swap on-chain**: from current `token0/token1` holdings and the target ratio for `[tickLower, tickUpper]` at the oracle price (`LiquidityAmounts`), determine the surplus leg and amount. Apply `swapPolicy` (skip/forbid selling `protectedToken` when policy = counter-asset-only). Quote via the Aerodrome Quoter; `quoterMin = quotedOut * (BPS - pos.maxSlippageBps)/BPS`; `effectiveMin = max(quoterMin, params.swapMinAmountOut)`; execute the swap (router) with `effectiveMin`.
10. **Mint** new position (recipient = `address(this)`) with `amount0MinMint`/`amount1MinMint`; **burn** the old now-empty NFT; set `pos.tokenId = newTokenId`; `pos.lastRebalance = block.timestamp`.
11. **Restake if applicable**: if the position was staked (or policy says to stake), `gauge.deposit(newTokenId)`; `pos.staked = true`; emit `Staked`.
12. **Value floor**: compute `valueAfter` = the minted position's principal valued at the same oracle observation; `require(valueAfter >= valueBefore * (BPS - pos.maxRebalanceLossBps)/BPS)` else revert `ValueFloor`. Bounds total value loss across decrease+swap+mint independent of the chosen width.
13. **Forward dust**: any residual `token0`/`token1` after mint → `pos.feeCollector`.
14. Emit `Rebalanced(slotId, oldTokenId, newTokenId, tickLower, tickUpper)`.

### 4.5 Admin / manager / emergency functions

Admin = `DEFAULT_ADMIN_ROLE` (Safe), Manager = `MANAGER_ROLE` (EOA), Guardian = `GUARDIAN_ROLE`.

- `registerPosition(ManagedPosition config)` — **admin**; requires the NFT already held by the contract; assigns a `slotId`; validates bounds (`maxSlippageBps <= MAX_SLIPPAGE_CAP_BPS`, `maxRebalanceLossBps <= MAX_LOSS_CAP_BPS`, `minWidth <= maxWidth`, `twapWindow > 0`, `maxTickDeviation > 0`, non-zero pool/tokens; if `gauge != 0`, gauge/pool consistency; if `valueOracle != 0`, a non-stale answer reads). Returns `slotId`.
- `deregisterPosition(slotId, address to)` — **admin**; unstake if needed; transfer the current NFT out to `to`; mark inactive.
- `withdrawPosition(slotId, address to)` — **admin**; emergency: unstake if needed; transfer the current NFT to `to` (the Safe).
- `migrate(slotId, MigrateParams)` — **admin** (Section 8).
- `recoverERC20(token, to, amount)`, `recoverETH(to)` — **admin**.
- `setRebalancer(address)`, `setCaps(...)`, `setValueOracle(slotId, feed)`, `setSwapPolicy(slotId, policy, protectedToken)`, `setGauge(slotId, gauge)` — **admin**.
- `setPositionConfig(slotId, ...)` (bounds within caps) — **manager**.
- `setFeeCollector(slotId, address)` — **admin** (drain-direction power; moved off the manager EOA after the security review).
- `pause()` / `unpause()` — **guardian**.
- `onERC721Received` — accept NFTs (restricted to the Aerodrome position manager as `msg.sender`, like `TransferAndEarn`).

### 4.6 Events & errors

Events: `PositionRegistered`, `PositionDeregistered`, `Rebalanced`, `FeesSkimmed`, `EmissionsClaimed`, `Staked`, `Unstaked`, `RebalancerUpdated`, `FeeCollectorUpdated`, `PositionConfigUpdated`, `ValueOracleUpdated`, `SwapPolicyUpdated`, `GaugeUpdated`, `PositionWithdrawn`, `TokensRecovered`, `Migrated`.

Custom errors: `Cooldown`, `TwapDeviation`, `ValueFloor`, `StaleOracle`, `NotInRange`, `WidthOutOfBounds`, `CenterDeviation`, `TickNotAligned`, `SlippageTooHigh`, `SwapPolicyViolation`, `NotStaked`, `AlreadyStaked`, `NoGauge`, `NotRebalancer`, `OnlyPositionManager`.

### 4.7 `getDecisionSnapshot(uint256 slotId)` — view (added for the agent, §11)

A single read that batches everything the off-chain agent's *gather* step and its *completion gate* need, so both derive "is the goal met" from one consistent chain observation (replay-safety: no straddling a block boundary across several racy calls). No new powers, no state change.

```solidity
struct DecisionSnapshot {
    int24   spotTick;            // pool slot0 tick
    int24   twapTick;            // pool TWAP tick over pos.twapWindow
    int24   tickLower;           // current position range
    int24   tickUpper;
    bool    inRange;             // tickLower <= spotTick < tickUpper
    bool    staked;              // currently gauge-staked
    bool    hasGauge;            // pos.gauge != address(0)  → AERO-stack decision is live iff true
    uint128 liquidity;           // current position liquidity
    uint256 earnedAero;          // gauge.earned(this, tokenId) if staked, else 0
    uint256 cooldownRemaining;   // seconds until rebalance() is allowed again
    bool    deviationGateOpen;   // |spotTick - twapTick| <= pos.maxTickDeviation  → rebalance won't revert on the gate now
}

function getDecisionSnapshot(uint256 slotId) external view returns (DecisionSnapshot memory);
```

`hasGauge == false` is exactly the signal that makes the agent run rebalance-only for a gaugeless pool (e.g. phase-1 MAMO/USDC if it has no CL gauge).

> **No on-chain emission rate.** `ICLGauge` exposes only `earned(account, tokenId)` — there is **no `rewardRate`/emission-rate getter**. The snapshot therefore does **not** carry an emission rate; the agent sources **emission APR off-chain** from Aerodrome LpSugar (which exposes gauge reward rate) and DefiLlama `apyReward` (§11.2). The snapshot's job is the **gate-relevant chain facts** (tick, range, in-range, staked, cooldown, deviation-gate-open) — the authoritative inputs the completion gate re-reads to verify the *mechanical* GOAL clauses.

## 5. AERO emissions workstream (capability parity with `aerodrome-auto-balance`)

The `aerodrome-auto-balance` module both re-ranges **and** stakes for emissions. This design matches that:

- **Stake** newly-registered or re-ranged positions in their CL gauge (`stake`, and step 11 of `rebalance`).
- **Claim** AERO on a cron via the permissionless `claimEmissions(slotId)`, forwarding to `DropAutomation` (which swaps reward tokens → MAMO for the weekly drop; **AERO must be added to its swap config**).
- **Switch** a position between fee-earning (unstaked) and emission-earning (staked) when the relative yields change.
- **Rebalance while staked**: `rebalance()` transparently unstakes → re-ranges → restakes, claiming AERO in the process.

Emissions farming is most productive in **deep, high-volume correlated pools** (cbBTC/WETH and similar), which is why Section 7's rollout deliberately includes non-MAMO pools.

## 6. Scope & a hard caveat

- **Manageable today** (NFT extractable from its holder): the `TransferAndEarn` positions — **MAMO/cbBTC**, **MAMO/USDC** — via `transfer()` to the Safe, then into the balancer.
- **Expandable** (review): the registry is **not limited to MAMO pairs**. Deep correlated pools such as **cbBTC/WETH** can be funded and registered to farm AERO. The MAMO-leg requirement is **not** a contract invariant for re-ranging — it only appears as a *sanity guard option* on `migrate` and can be disabled per pool by the admin.
- **Out of scope**: `BurnAndEarn` (holds the **MAMO/VIRTUALS** LP, `BURN_AND_EARN_VIRTUAL_MAMO_LP`) has **no transfer-out function** — those positions are permanently locked there and cannot be auto-balanced without replacing that contract.

Initial managed set: the TransferAndEarn positions. New pools (including non-MAMO) added later via `registerPosition` — no redeploy.

## 7. Deployment, migration & phased rollout

- **`script/DeployLPAutoBalancer.s.sol`**: deploy with admin = `F-MAMO`, `rebalancer` = new `MAMO_LP_REBALANCER` EOA, wired to `UNISWAP_V3_POSITION_MANAGER_AERODROME`, `AERODROME_ROUTER`, `AERODROME_QUOTER`, `AERODROME_CL_FACTORY`, `AERO`; default per-position `feeCollector` = `DROP_AUTOMATION`, `valueOracle` = `MAMO/USD` (`0xeF7541b388a77C1709a3d44BfBfC5c1ED3F0Ac94`) for MAMO pools, `swapPolicy = 1` (counter-asset only) for the test phase. Register in `addresses/` as `MAMO_LP_AUTO_BALANCER`; add `MAMO_LP_REBALANCER`.
- **FPS proposal `multisig/f-mamo/006_LPAutoBalancerSetup.sol`** (F-MAMO owns `TransferAndEarn`):
  1. For each managed position: `transferAndEarn.transfer(tokenId)` → NFT returns to the Safe.
  2. Safe `safeTransferFrom(safe, balancer, tokenId)` → `onERC721Received` accepts.
  3. `balancer.registerPosition(config)` per pool with the policy envelope, `feeCollector = DROP_AUTOMATION`, gauge + oracle + swap policy.
  4. `validate()`: NFTs held by balancer, bounds set, `rebalancer` correct, `feeCollector` wired to the drop, AERO whitelisted in `DropAutomation`.

**Phased rollout (review).** Do **not** move all liquidity at once. Begin with a **small amount of TVL** (one position, conservative bounds, `swapPolicy = counter-asset only`), prove fee + emission yield and guard behavior on mainnet, then **expand TVL and add pools** (including deep correlated non-MAMO pools) as the strategy demonstrates success.

**Phase-1 (Revision 2) — single position, MAMO/USDC only.** The first deployment manages exactly **one** position: **MAMO/USDC (tokenId 21585074)**, the position already held by `TransferAndEarn` (custody confirmed). This deliberately sidesteps the MAMO/cbBTC custody question (implementation note #1: the cbBTC/MAMO NFT is *not* held by `TransferAndEarn`) — cbBTC/MAMO, deep correlated non-MAMO pools (cbBTC/WETH), and the multi-position **sweep** are all **phase-2+**. The off-chain agent (§11) therefore runs a **single-position loop**, not a sweep-over-set, in phase-1. If MAMO/USDC has no CL gauge, phase-1 is **rebalance-only** (`hasGauge == false` from §4.7); the AERO-stack decision activates automatically once a gauged pool is registered — no contract or agent code change.

Wiring note: once a position lives in the balancer, fee/emission skimming for the drop happens via `rebalance()`, `collectFees(slotId)`, or `claimEmissions(slotId)`; `TransferAndEarn.earn()` no longer applies to the moved NFTs.

## 8. Pool Migration (human-gated)

Re-ranging stays within governance-registered pools. **Migration** — moving a position into a *different* pool/pair (open destination) — is a separate, higher-trust action with a different power model.

### 8.1 Why migration cannot be autonomous or EOA-gated

Every on-chain guard (`maxSlippageBps`, the pool-TWAP fallback value floor) assumes a **known, liquid pool**. With an **open destination**, a TWAP-priced floor can be defeated: an attacker (or compromised key) could migrate into a pool they created, seed its TWAP, and have the floor read a fabricated price. (A Chainlink-priced floor is safe, but most destination pairs won't have one.) So migration's vetting moves to a human/governance step: `migrate()` is **`DEFAULT_ADMIN_ROLE` (F-MAMO Safe) only**. The only actor that can route protocol liquidity into an arbitrary pool is the multisig — which can already do anything with protocol funds — so `migrate()` adds **no new trust**, it just makes the operation atomic and keeps the registry consistent.

### 8.2 `migrate(uint256 slotId, MigrateParams params)` — `onlyRole(DEFAULT_ADMIN_ROLE)`, `nonReentrant`, `whenNotPaused`

Params (multisig-reviewed): `destPool, destToken0, destToken1, destTickSpacing, destGauge, tickLower, tickUpper, swapTokenIn, swapAmountIn, swapMinAmountOut, amount{0,1}MinDecrease, amount{0,1}MinMint, deadline`.

Flow: unstake if staked (claim AERO → `feeCollector`); collect fees → skim; `decreaseLiquidity(all)` + collect principal; swap per route with `swapMinAmountOut` (defense-in-depth slippage); `mint` into `destPool` (recipient = contract) with mint mins; optionally `deposit` into `destGauge`; burn old NFT; **update the slot in place** (pool/tokens/tickSpacing/gauge/tokenId, plus per-position bounds for the new pool); reset `lastRebalance`; emit `Migrated(slotId, oldPool, destPool, oldTokenId, newTokenId)`.

**Cheap sanity guards** (catch fat-finger, NOT value protection — the human review is the value guard): `destPool.code.length > 0`, `destTickSpacing == IPool(destPool).tickSpacing()`, ticks aligned + `tickLower < tickUpper`. An **optional** MAMO-leg check is available per call but is **not** required, since non-MAMO correlated pools are in scope. The TWAP value floor is **deliberately not applied** to migrations because an arbitrary pool's TWAP isn't trustworthy.

### 8.3 LLM pair-discovery pipeline — **nice-to-have, not required** (future / optional)

> **Scope note (Revision 2).** This section is *only* about **migration destination discovery** (which *new* pool to move into) — which remains human/Safe-gated and optional, for the trust reasons in §8.1. It is **distinct** from the §11 agent, which makes the **re-range and AERO-stake-vs-fees decisions** inside the *already-registered* pool. Those decisions are now the agent's live job (autonomous within on-chain guards); migration is not.

Per review, migration destinations are decided by **periodic human analysis**, not an autonomous pipeline. Migration is rare and Safe-gated, so an operator can review pools by hand when considering a move. The discovery automation below is documented as an **optional future enhancement** — decision-support only, never execution — and is **not part of the initial deliverable**:

> *(Future, optional)* A deterministic funnel (Aerodrome `LpSugar` on-chain reads as source of truth + DefiLlama yields for `apyBase`/`apyReward`/`tvlUsd`) → hard pre-filters (canonical pool, min TVL/depth, verified counter-token) → deterministic scoring → an LLM that emits a **ranked shortlist with rationale** for operators to vet → **human/multisig executes** `migrate()`. The min-TVL pre-filter is what would connect "high-APR pool found" to "the destination is safe to operate in."

### 8.4 Testing additions for migration

- `migrate` access control: `rebalancer`/`manager`/random revert; only admin (Safe) succeeds.
- Sanity guards: non-contract `destPool`, mismatched `destTickSpacing`, misaligned/inverted ticks → revert.
- Fork integration: admin migrates a real position into another pool → assert fees/AERO skimmed, principal moved within `swapMinAmountOut`, slot updated (new pool/tokens/tickSpacing/gauge/tokenId), optional restake, old NFT burned, `Migrated` emitted, and the position is subsequently re-rangeable by the `rebalancer` in the new pool.

## 9. Testing (Base fork tests; `MoonwellMorphoStrategy`/`DropAutomation` style)

- **Guard/unit**: width bounds, on-chain tick centering/alignment, center-deviation, cooldown, slippage cap (quoter floor authoritative), value-floor (`maxRebalanceLossBps`) priced via **Chainlink** and via **TWAP fallback**, stale-oracle revert, TWAP deviation gate (`maxTickDeviation`), swap-policy (counter-asset-only blocks selling MAMO), access control, `pause`, emergency `withdrawPosition`, `onERC721Received` sender restriction.
- **Gauge/emissions**: `stake`/`unstake` roundtrip, `claimEmissions` forwards AERO to `feeCollector`, `rebalance` unstakes→re-ranges→restakes and claims AERO, fees-vs-emissions switch.
- **Integration (fork)**: register a real MAMO/cbBTC position → push the tick out of range → `rebalance(width)` → assert new range straddles tick, fees/AERO skimmed to `DropAutomation`, principal preserved within slippage, old NFT burned, `tokenId` updated, dust forwarded. Also a **non-MAMO correlated pool** (e.g. cbBTC/WETH) staked-for-emissions path.
- **Adversarial**: out-of-bounds `width`, slippage above cap, pre-cooldown, garbage caller `swapMinAmountOut` (on-chain quoter floor still holds), a value-destroying outcome (reverts on the value floor), a manipulated spot (reverts on the deviation gate), counter-asset-only policy violation; withdrawal & mint min-amounts bound a simulated sandwich.
- **FPS proposal test** (like `ERC20StrategyV2Test`): run `006`'s deploy/build/simulate/validate end-to-end.

## 10. Out of scope / non-goals

- Rebalancing the MAMO/VIRTUALS LP (locked in `BurnAndEarn`, no transfer-out).
- Changing the drop staging mechanism (`DropAutomation` / `RewardsDistributorSafeModule`) — fees + AERO continue to flow to it (AERO added to its swap config).
- Compounding fees/emissions into positions (rejected; they feed the drop).
- **Off-chain tick/swap-size discretion** (rejected per review — ticks and swap size are computed on-chain; the caller supplies only a bounded `width`).
- **Untrusted off-chain minimums weakening protection** (rejected — min-amounts are recomputed on-chain from the Quoter; a caller floor can only tighten them).
- Human-approval gating **for re-ranges** (rejected — re-ranges run autonomously within on-chain guards). **Migrations are the opposite** — Safe-admin-gated, never autonomous (§8).
- **Autonomous or single-EOA-gated migration** (rejected — would re-create a treasury-drain path).
- **Required LLM pool-discovery for *migration*** (rejected — it is an optional nice-to-have; humans + the Safe decide and execute migrations, §8.3). **Note (Revision 2):** LLM *decisioning* for the re-range/stake-vs-fees calls inside a registered pool is **now in scope** and is the primary off-chain deliverable (§11) — this non-goal is scoped to *migration destination* discovery only.
- **veAERO locking / vote-bribe direction** (out of scope — the AERO decision is the binary gauge-stake-vs-unstaked yield-source switch only; claimed AERO continues to route to the drop, §5).
- **LLM hallucinating value-relevant numbers** (mitigated, not trusted — the funnel feeds the LLM only *computed* facts and *pre-vetted* candidate actions; the LLM picks among them, and every executed action is still bounded by the on-chain guards, §11).

> **Correction (was a non-goal in error).** A previous draft listed "Chainlink-valued retention guards — rejected because MAMO has no reliable Chainlink feed." **MAMO does have a live Chainlink feed** — `MAMO / USD` at `0xeF7541b388a77C1709a3d44BfBfC5c1ED3F0Ac94` on Base (8 decimals, ~$0.0089 at writing). The value floor now prices against it when configured (Section 3.1), which is stronger than a thin-pool TWAP and resolves the earlier thin-pool caveat.

## 11. Off-chain decisioning agent (goal-gated LLM)

The off-chain side is a **goal-gated LLM agent**, reusing the multi-turn loop pattern shipped in `centaur-moonwell` PR #36 (`feat(agent-loops): goal-gated turns`). It lives in `centaur-moonwell` (full spec: `docs/superpowers/specs/2026-06-17-lp-balancer-agent-design.md`); summarized here because it is what drives this contract's `REBALANCER_ROLE` levers. **Phase-1 runs against the single MAMO/USDC position (§7).**

### 11.1 What it decides

Per run, two decisions:
1. **Re-range?** — and at what `width`, or no-op.
2. **Stack AERO vs earn LP rewards** — gauge-stake to farm AERO emissions, or stay unstaked to earn trading fees, choosing whichever yields more (only when `hasGauge` — §4.7).

It drives the *existing* levers (`rebalance`, `stake`, `unstake`, `claimEmissions`, `collectFees`); it gains **no new on-chain power** and is bounded by every guard in §3.1. Migrations are *not* the agent's job (§8).

### 11.2 Decision architecture — deterministic funnel + LLM judgment

The LLM never sees raw RPC or invents numbers. Code does GATHER → COMPUTE → PRE-FILTER, then the LLM picks among **vetted** candidates:

| Stage | Produces |
| --- | --- |
| Gather | `getDecisionSnapshot` (§4.7, authoritative chain reads) + Aerodrome LpSugar + DefiLlama `apyBase`/`apyReward` (cross-check) + Chainlink price (USD numeraire) + a tick-volatility window |
| Compute | `feeAPR` vs `emissionAPR`, both USD-normalized; candidate widths `{tight, mid, wide}` with a projected in-range probability from volatility; projected value-floor headroom per candidate |
| Pre-filter (hard) | drop candidates that *would revert* (`cooldownRemaining > 0`, `!deviationGateOpen`, width outside `[minWidth, maxWidth]`, below min-TVL); apply a **hysteresis band** around the APR crossover so noise can't cause stake/unstake flapping |
| Brief | structured JSON to the LLM: current state + *only vetted* candidates + the APR comparison + a **do-nothing option that is always present** |

The LLM exercises the judgment the funnel can't encode (is a flip worth the gas + IL when the APR gap is small and volatility is rising? is a tighter range worth it this week?), picks **one** vetted candidate, and writes a rationale. If DefiLlama and on-chain APR diverge beyond tolerance, the brief flags it and the LLM defaults to the conservative on-chain number or a no-op.

### 11.3 Goal-gated loop (PR #36 shape)

A cron-fired workflow (`workflows/lp_balancer_sweep.py`) runs a bounded turn loop with this GOAL injected per position:

```
GOAL: position {slotId} ({pair}) is optimally configured right now —
  (1) in-range: spot tick within [tickLower, tickUpper] at a width justified by recent volatility
  (2) higher-yield source selected: staked iff emissionAPR > feeAPR + HYSTERESIS_BPS  (only when hasGauge)
  (3) no claimable AERO/fees left unswept past threshold
```

Each turn: workflow builds the brief → the **sandboxed agent decides and executes the lever itself via `cast`/foundry** (the centaur workflow layer has no web3/signer — on-platform, agents act through CLI in the sandbox, like the coding agent runs `git`/`gh`), holding the `REBALANCER_ROLE` key in the sandbox; the agent reports protocol lines (`LP_ACTION: rebalance tx=0x…`, `SNAPSHOT_AFTER: inRange=… staked=…`). The **completion gate runs in the workflow and independently re-reads `getDecisionSnapshot` via a single JSON-RPC `eth_call` over `httpx`** — it does *not* trust the agent's reported snapshot (same stance as PR #36 re-checking GitHub, not the agent's word). It verifies the **mechanical** clauses (in-range, no unswept fees/AERO, staked-state matches the agent's stated decision) and **trusts the agent's APR-based judgment** for stake *direction* (bounded, reversible, flap-detector-guarded). Met → end run. Unmet → next turn gets `GOAL NOT MET: <reason>` (e.g. `you decided to stake but position still unstaked`, `drifted out of range`, or a reverted-tx reason like `tx reverted: ValueFloor`). Budget spent unmet → escalate to a human, never loop forever.

### 11.4 Safety (three layers, weakest→strongest)

1. **On-chain (authoritative):** value floor, deviation gate, width bounds, cooldown, quoter slippage floor. A bad LLM action reverts and is fed back as the unmet reason — this is the real backstop.
2. **Service-side circuit-breaker:** halt + alert on N consecutive reverts, a flap detector (stake-state flips > K in a window — belt-and-suspenders over hysteresis), DefiLlama-vs-on-chain APR divergence, or oracle staleness. Halting = stop signing; the Safe can also revoke the EOA instantly (existing kill-switch).
3. **Replay-safety:** durable workflow state (PR #36 model); a sandbox dying mid-turn resumes, and the gate re-reads chain so a tx that landed pre-crash is seen as done, not double-sent. An idempotency key per `(slotId, cron-tick)` prevents a duplicate action in one tick (cooldown already guards `rebalance`, but `stake`/`claim` are not cooldown-gated).

## Implementation notes

Key deltas discovered during implementation, important for reviewers:

1. **Day-one managed position is MAMO/USDC (tokenId 21585074 from TransferAndEarn)**, not cbBTC/MAMO — the cbBTC/MAMO NFT is not held by TransferAndEarn. cbBTC/MAMO can be added later once its custody is confirmed.

2. **The Position Manager is Aerodrome Slipstream**: `mint` uses `int24 tickSpacing` (not `uint24 fee`) plus a trailing `uint160 sqrtPriceX96` parameter — a dedicated `ICLPositionManager` interface was added. The repo's existing `INonfungiblePositionManager` was Uniswap-v3-shaped and was never exercised for `mint`.

3. **The value floor refines the spec's single `valueOracle` into per-leg Chainlink feeds** (`oracle0`/`oracle1`), pricing realized token balances rather than in-range liquidity. This gives a more accurate and manipulation-resistant pre/post measurement.

4. **Roles use OZ `AccessControlEnumerable` with a `REBALANCER_ROLE`** (not a standalone `rebalancer` address field). The spec's `address public rebalancer` state variable was replaced by the role — callers with `REBALANCER_ROLE` may call `rebalance()`, `collectFees()`, `stake()`/`unstake()`, and `claimEmissions()`.

5. **Operational note — concentrating a full-range position into a tight range in a single swap can incur >1% value loss** from swap fees alone. `maxRebalanceLossBps` must be set with that headroom, or rebalances done incrementally. Observed on the fork test: 1% was marginally tight for a full-range → 4000-tick move; 3% was realistic.

6. **Operational note — `maxOracleDelay` bounds Chainlink staleness**; keep it consistent with each feed's real heartbeat to avoid spurious stale-oracle reverts.
