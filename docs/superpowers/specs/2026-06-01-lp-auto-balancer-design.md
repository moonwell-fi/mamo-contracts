# LP Auto-Balancer — Design

**Date:** 2026-06-01
**Status:** Approved (design)
**Author:** Ana Julia + Claude

## 1. Problem & Goal

Protocol-owned Aerodrome concentrated-liquidity (CL) positions that fund the weekly MAMO drop currently sit **static and full-range** (`tickLower -887200` / `tickUpper 887200`, tickSpacing 200) inside the `TransferAndEarn` contract. The only operation performed on them today is fee collection (`earn()` → fee collector → `DropAutomation` → weekly drop). They are never re-ranged, so they are capital-inefficient: a full-range position earns a small fraction of the fees a tight, centered range would earn for the same capital.

**Goal:** maximize the trading-fee yield these positions generate for the weekly drop by (a) concentrating liquidity into tight ranges around spot and (b) re-centering as price drifts — a general, per-position-configurable rebalancer. Inspired by `aerodrome-auto-balance`, adapted to Mamo's protocol-owned-liquidity + Safe-governed model.

This is delivered as two workstreams:
- **On-chain:** a new `LPAutoBalancer` contract (this spec, Sections 3–6) — primary deliverable.
- **Off-chain:** a rebalancing service with an LLM in the loop (Section 7) — documented here, implemented separately.

## 2. Decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Primary goal | General yield-max: concentration **and** ongoing re-centering, configurable per position |
| Custody/logic location | **New standalone `LPAutoBalancer`** contract holding the NFTs |
| Access control | **`AccessControlEnumerable` role split** (not `Ownable`): admin = F-MAMO Safe (drain-capable powers + caps), `MANAGER_ROLE` = EOA (tune bounds within caps), `rebalancer` = EOA (re-range), guardian = EOA/Safe (pause) |
| Pool selection / migration | LLM **never picks pairs autonomously**. Re-ranging stays within governance-registered pools. Changing pool/pair = `migrate()`, **Safe-admin-gated**, open destination, LLM advisory-only (Section 9) |
| Trigger model | **Backend-decided params + on-chain guards** (mirrors `DropAutomation`) |
| Fee handling on rebalance | **Skim accrued fees to fee collector** (`DropAutomation`); rebalance only re-ranges principal — preserves current drop economics |
| Scope | **Generic multi-position registry**; start with the `TransferAndEarn` positions |
| Safety model | **Approach A + reference guards**: per-swap slippage cap + per-position cooldown + width/center-deviation bounds + decrease/mint min-amounts, **plus** a TWAP-priced value floor (`maxRebalanceLossBps`) and a spot-vs-TWAP deviation gate (`maxTickDeviation`) adopted from `aerodrome-auto-balance` to bound the broad LLM discretion |
| Operator | **No Gelato.** A dedicated `rebalancer` EOA (the backend hot wallet the LLM signs with); owner can rotate/revoke instantly |
| LLM role | **LLM computes params directly** (raw target ticks + swap direction/size) → the on-chain contract is the *entire* trust boundary; value-bearing numbers (`minAmountOut`, min-amounts) are still computed deterministically off-chain, never by the LLM |
| Authorization | **Fully autonomous** — service signs and sends with no human gate, bounded by contract guards + a service-side circuit-breaker |

## 3. On-chain Contract: `LPAutoBalancer`

`AccessControlEnumerable`, `ReentrancyGuard`, `Pausable`, `IERC721Receiver`. Solidity 0.8.28, BUSL-1.1 (matches repo). Uses the same role model as `MamoStrategyRegistry` / `MamoStakingRegistry` rather than `Ownable`, so day-to-day operation runs on an EOA while drain-capable powers stay on the Safe.

### 3.1 Trust boundary

The LLM emits raw ticks + swap params. Therefore the contract treats `rebalance()` params as **arbitrary and potentially adversarial** (compromised key / hallucinating model). Every guard must hold against attacker-chosen inputs, not merely honest-but-imperfect ones.

Because the LLM has full discretion over ticks and swap size (far more than the keeper in the `aerodrome-auto-balance` reference, which computes the range on-chain), the contract carries **two outcome-based guards adopted from that reference**, in addition to the per-step guards:

- **TWAP-priced value floor (`maxRebalanceLossBps`)** — the position's value is snapshotted before and after the rebalance, priced at the pool's own TWAP (not spot, not Chainlink), and the call reverts unless `valueAfter >= valueBefore * (1 - maxRebalanceLossBps)`. This directly bounds per-call value loss regardless of what ticks/swap the LLM chose.
- **Spot-vs-TWAP deviation gate (`maxTickDeviation`)** — the call reverts if the spot tick deviates from the TWAP tick by more than `maxTickDeviation`, refusing to act during a price spike or a manipulation attempt.

Net: worst-case value loss per call is bounded to ≈ `maxRebalanceLossBps` (the tighter of it and `maxSlippageBps` on the swapped portion); the deviation gate blocks acting on a manipulated spot; the cooldown rate-limits cumulative damage; the owner kill-switch (`pause` / revoke `rebalancer`) stops it entirely.

**Caveat — TWAP strength scales with pool depth.** The reference targets the deep WETH/cbBTC pool. Our target pools (MAMO/cbBTC, MAMO/USDC) are thinner, so a sufficiently capitalized attacker could move the TWAP over `twapWindow`. The value floor + deviation gate are still strictly stronger than slippage-cap + cooldown alone, and compose with them; `twapWindow` should be set conservatively (longer) per pool, and `maxRebalanceLossBps`/`maxTickDeviation` tightened for thinner pools.

### 3.2 Roles

Powers are split so an EOA can run operations without any single key being able to move or drain protocol liquidity. The drain-capable functions (`migrate`, `withdrawPosition`, `recoverERC20`/`recoverETH`) and all *cap*-setting stay on the Safe.

- **`DEFAULT_ADMIN_ROLE` = F-MAMO Safe** — `registerPosition`/`deregisterPosition`, `migrate` (Section 9), `withdrawPosition`, `recoverERC20`/`recoverETH`, set the global caps (`MAX_SLIPPAGE_CAP_BPS`, `MAX_LOSS_CAP_BPS`), grant/revoke all roles (including `rebalancer`).
- **`MANAGER_ROLE` = EOA** — fast operational tuning *within* admin-set caps: per-position `minWidth/maxWidth/maxCenterDeviation/maxSlippageBps/maxRebalanceLossBps/maxTickDeviation/twapWindow/minRebalanceInterval`, and `setFeeCollector`. **No** power to move, migrate, or withdraw funds.
- **`rebalancer` = a dedicated EOA (`MAMO_LP_REBALANCER`)** — may **only** call `rebalance()` and `collectFees()`. No custody, no config. (The LLM hot wallet.)
- **`GUARDIAN_ROLE` = EOA or Safe** — `pause()`/`unpause()`.

Rationale: re-ranging is bounded by on-chain guards, so it can run on a hot key; migration has no enforceable on-chain value protection (Section 9), so it must stay behind the multisig — putting it on a single EOA would re-create a treasury-drain path. `MANAGER_ROLE` can only loosen/tighten bounds **between** the admin-set caps, so a compromised manager key cannot exceed limits the Safe set.

### 3.3 State

```solidity
struct ManagedPosition {
    uint256 tokenId;            // current Aerodrome CL NFT; changes every rebalance
    address pool;               // CL pool — source of truth for tickSpacing + current tick (slot0)
    address token0;
    address token1;
    int24   tickSpacing;
    address feeCollector;       // defaults to DROP_AUTOMATION
    uint24  minWidth;           // min allowed (tickUpper - tickLower), tick units
    uint24  maxWidth;           // max allowed (tickUpper - tickLower), tick units
    uint24  maxCenterDeviation; // new range center must be within N ticks of current tick
    uint16  maxSlippageBps;     // hard cap on swap slippage (<= MAX_SLIPPAGE_CAP_BPS)
    uint32  twapWindow;         // seconds for the pool TWAP used by the spike gate + value floor
    int24   maxTickDeviation;   // max allowed |spot tick - TWAP tick| before rebalance is refused
    uint16  maxRebalanceLossBps; // value floor: post-value >= pre-value * (1 - this) (<= MAX_LOSS_CAP_BPS)
    uint256 minRebalanceInterval; // cooldown seconds
    uint256 lastRebalance;      // timestamp of last rebalance
    bool    active;
}

mapping(uint256 slotId => ManagedPosition) public positions;
uint256 public nextSlotId;
address public rebalancer;

// Immutables wired at construction:
INonfungiblePositionManager public immutable POSITION_MANAGER; // Aerodrome
ISwapRouter public immutable AERODROME_ROUTER;
IQuoter     public immutable AERODROME_QUOTER;
```

Global constants: `MAX_SLIPPAGE_CAP_BPS` (e.g. 500 = 5%), `MAX_LOSS_CAP_BPS` (e.g. 500 = 5%), `BPS_DENOMINATOR = 10_000`, `SWAP_DEADLINE_BUFFER`.

### 3.4 `rebalance(uint256 slotId, RebalanceParams params)` — `onlyRebalancer`, `nonReentrant`, `whenNotPaused`

```solidity
struct RebalanceParams {
    int24   tickLower;          // LLM-supplied
    int24   tickUpper;          // LLM-supplied
    address swapTokenIn;        // LLM-supplied (which side to sell)
    uint256 swapAmountIn;       // LLM-supplied
    uint256 swapMinAmountOut;   // service-computed (NOT LLM) — external MEV floor
    uint256 amount0MinDecrease; // service-computed — withdrawal sandwich guard
    uint256 amount1MinDecrease;
    uint256 amount0MinMint;     // service-computed — mint sandwich guard
    uint256 amount1MinMint;
    uint256 deadline;
}
```

Execution order (fee-then-principal separation is the key trick):

1. **Cooldown**: `require(block.timestamp >= pos.lastRebalance + pos.minRebalanceInterval)`.
2. **TWAP deviation gate**: read spot tick (`slot0().tick`) and the TWAP tick over `pos.twapWindow` (e.g. via `OracleLibrary.consult`); `require(|spot - twap| <= pos.maxTickDeviation)` else revert `TwapDeviation`. Refuses to act during a spike/manipulation.
3. **Snapshot pre-value**: value the *current* position's principal at the TWAP price in a single numeraire (token1), via `LiquidityAmounts.getAmountsForLiquidity` at the TWAP `sqrtPriceX96` over the current range → `valueBefore`.
4. **Collect fees only**: `collect(tokenId, max, max)` *before* decreasing liquidity collects only accrued `tokensOwed` (fees). Forward both tokens to `pos.feeCollector` → keeps the drop fed. Emit `FeesSkimmed`. (Fees are excluded from the value-floor comparison — only principal is measured before/after, since fees deliberately leave the contract.)
5. **Decrease all liquidity**: read position `liquidity`; `decreaseLiquidity(tokenId, liquidity, amount0MinDecrease, amount1MinDecrease, deadline)`; then `collect(tokenId, max, max)` to pull principal into the contract.
6. **Validate new range** against live `pool.tickSpacing()` + `slot0().tick`:
   - ticks aligned to `tickSpacing` (`tickLower % spacing == 0`, same for upper);
   - `tickLower < tickUpper`;
   - `pos.minWidth <= (tickUpper - tickLower) <= pos.maxWidth`;
   - range straddles current tick: `tickLower < currentTick < tickUpper`;
   - `|((tickLower+tickUpper)/2) - currentTick| <= pos.maxCenterDeviation`.
7. **Swap** to reach the target ratio via Aerodrome CL router, reusing `DropAutomation._executeSwap`'s dual-layer guard:
   - quoter-based on-chain min = `quotedOut * (BPS - maxSlippageBps) / BPS`;
   - effective `minOut = max(quoterMin, swapMinAmountOut)`;
   - `require(swapTokenIn` is one of `token0/token1)`; tickSpacing from `pos`.
8. **Mint** new position (recipient = `address(this)`) with `amount0MinMint`/`amount1MinMint`; **burn** the old now-empty NFT; set `pos.tokenId = newTokenId`; `pos.lastRebalance = block.timestamp`.
9. **Value floor**: compute `valueAfter` = the minted position's principal (its `liquidity` over the new range, valued at the TWAP `sqrtPriceX96` in token1); `require(valueAfter >= valueBefore * (BPS - pos.maxRebalanceLossBps) / BPS)` else revert `ValueFloor`. This is the outcome guard that bounds total value loss across decrease+swap+mint, independent of the LLM-chosen ticks.
10. **Forward dust**: any residual `token0`/`token1` after mint → `pos.feeCollector` (no value trapped in the contract).
11. Emit `Rebalanced(slotId, oldTokenId, newTokenId, tickLower, tickUpper)`.

### 3.5 `collectFees(uint256 slotId)` — **permissionless**, `whenNotPaused`

Standalone fee skim **between** rebalances so the drop keeps its current cadence without forcing a re-range. Permissionless because funds can only ever move to the owner-configured `pos.feeCollector` — there is no caller-chosen destination, so opening it up is safe and lets a keeper/cron poke it cheaply. `collect(tokenId, max, max)` → forward to `pos.feeCollector`. Emit `FeesSkimmed`.

### 3.6 Admin / manager / emergency functions

Admin = `DEFAULT_ADMIN_ROLE` (Safe), Manager = `MANAGER_ROLE` (EOA), Guardian = `GUARDIAN_ROLE`.

- `registerPosition(ManagedPosition config)` — **admin**; requires the NFT already held by the contract; assigns a `slotId`; validates bounds (`maxSlippageBps <= MAX_SLIPPAGE_CAP_BPS`, `maxRebalanceLossBps <= MAX_LOSS_CAP_BPS`, `minWidth <= maxWidth`, `twapWindow > 0`, `maxTickDeviation > 0`, non-zero pool/tokens). Returns `slotId`.
- `deregisterPosition(slotId, address to)` — **admin**; transfer the current NFT out to `to`, mark inactive.
- `withdrawPosition(slotId, address to)` — **admin**; emergency: transfer the current NFT to `to` (the Safe).
- `migrate(slotId, MigrateParams)` — **admin** (see Section 9).
- `recoverERC20(token, to, amount)`, `recoverETH(to)` — **admin**.
- `setRebalancer(address)`, `setCaps(...)` — **admin**.
- `setPositionConfig(slotId, ...)` (bounds within caps), `setFeeCollector(slotId, address)` — **manager**.
- `pause()` / `unpause()` — **guardian**.
- `onERC721Received` — accept NFTs (restricted to the Aerodrome position manager as `msg.sender`, like `TransferAndEarn`).

### 3.7 Events

`PositionRegistered`, `PositionDeregistered`, `Rebalanced`, `FeesSkimmed`, `RebalancerUpdated`, `FeeCollectorUpdated`, `PositionConfigUpdated`, `PositionWithdrawn`, `TokensRecovered`.

Custom errors: `Cooldown`, `TwapDeviation`, `ValueFloor`, `NotInRange`, `WidthOutOfBounds`, `CenterDeviation`, `TickNotAligned`, `SlippageTooHigh`, `NotRebalancer`, `OnlyPositionManager`.

## 4. Scope & a hard caveat

Only NFTs that can be **extracted from their current holder** can be managed:
- `TransferAndEarn` exposes `transfer()` → the F-MAMO Safe can hand those NFTs to the balancer. ✅ Manageable: **MAMO/cbBTC**, **MAMO/USDC**.
- `BurnAndEarn` (holds the **MAMO/VIRTUALS** LP, `BURN_AND_EARN_VIRTUAL_MAMO_LP`) has **no transfer-out function** — those positions are permanently locked there and **cannot** be auto-balanced without replacing that contract. Out of scope for this design.

Initial managed set: the TransferAndEarn positions (MAMO/cbBTC, MAMO/USDC). New pools added later via `registerPosition` — no redeploy.

## 5. Deployment & migration

- **`script/DeployLPAutoBalancer.s.sol`**: deploy with owner = `F-MAMO`, `rebalancer` = new `MAMO_LP_REBALANCER` EOA, wired to `UNISWAP_V3_POSITION_MANAGER_AERODROME`, `AERODROME_ROUTER`, `AERODROME_QUOTER`, `AERODROME_CL_FACTORY`; default per-position `feeCollector` = `DROP_AUTOMATION`. Register the contract in `addresses/` as `MAMO_LP_AUTO_BALANCER`. Add `MAMO_LP_REBALANCER` EOA address.
- **FPS proposal `multisig/f-mamo/006_LPAutoBalancerSetup.sol`** (F-MAMO owns `TransferAndEarn`):
  1. For each managed position: `transferAndEarn.transfer(tokenId)` → NFT returns to the Safe.
  2. Safe `safeTransferFrom(safe, balancer, tokenId)` → `onERC721Received` accepts.
  3. `balancer.registerPosition(config)` per pool with the policy envelope and `feeCollector = DROP_AUTOMATION`.
  4. `validate()`: NFTs held by balancer, bounds set, `rebalancer` correct, `feeCollector` wired to the drop.

Wiring note: once a position lives in the balancer, fee-skimming for the drop happens via `rebalance()` or the standalone `collectFees(slotId)`; `TransferAndEarn.earn()` no longer applies to the moved NFTs.

## 6. Testing (Base fork tests; `MoonwellMorphoStrategy`/`DropAutomation` style)

- **Guard/unit**: tick alignment, width bounds, center-deviation, cooldown, slippage cap, value-floor (`maxRebalanceLossBps`), TWAP deviation gate (`maxTickDeviation`), access control (`onlyRebalancer` / `onlyOwner`), `pause`, emergency `withdrawPosition`, `onERC721Received` sender restriction.
- **Integration (fork)**: register a real MAMO/cbBTC position → swap in the pool to push the tick out of range → `rebalance()` → assert new range straddles tick, fees skimmed to `DropAutomation`, principal preserved within slippage, old NFT burned, `tokenId` updated, dust forwarded.
- **Adversarial**: attacker `rebalance` params (off-spacing / excess-width / non-straddling ticks, slippage above cap, pre-cooldown) all revert; a value-destroying range/swap reverts on the value floor; a manipulated spot (large in-pool swap pushing spot past `maxTickDeviation` from TWAP) reverts on the deviation gate; withdrawal & mint min-amounts bound a simulated sandwich.
- **FPS proposal test** (like `ERC20StrategyV2Test`): run `006`'s deploy/build/simulate/validate end-to-end.

## 7. Off-chain Rebalancing Service (separate workstream)

Standalone TypeScript/Node service on a scheduler. The contract is the hard boundary; the service fails fast and keeps a full audit trail. This section covers the **re-range** loop, which is **fully autonomous** — no human gate. (Pool *migration* discovery is a separate, advisory, human-gated flow — see §8.3.)

### 7.1 Decision loop (per position, on a cron aligned so a rebalance can land before the weekly drop)

1. **Ingest state (deterministic):** pool `slot0` (`sqrtPriceX96`, current tick), `tickSpacing`, position `tickLower/tickUpper/liquidity`, accrued fees, token0/1 balances; derived signals (in-range, range utilization, realized fee APR over recent windows, price volatility, pool TVL/volume).
2. **Cheap gate (deterministic):** skip the LLM unless cooldown elapsed AND (out-of-range OR utilization/deviation past a configured threshold). Saves tokens, avoids churn.
3. **LLM call:** feed the structured snapshot + the position's policy envelope (the same `minWidth/maxWidth/maxCenterDeviation/maxSlippageBps` the contract enforces) with a strict JSON-schema output:
   ```json
   { "shouldRebalance": true, "reason": "...",
     "tickLower": 0, "tickUpper": 0,
     "swap": { "tokenIn": "0x..", "amountIn": "..", "tickSpacing": 200 } }
   ```
   The LLM decides range + swap direction/size only.
4. **Deterministic post-processing (no LLM):**
   - Re-validate the LLM output against the policy envelope locally (alignment, width, straddle, center-deviation) → reject + alert before spending gas (mirror of on-chain guards; the revert is the backstop).
   - Pre-check the two outcome guards off-chain too, to fail fast before gas: read the pool TWAP, confirm `|spot - twap| <= maxTickDeviation`, and simulate the rebalance to confirm the projected `valueAfter` clears the `maxRebalanceLossBps` floor. The on-chain checks remain the authoritative backstop.
   - Compute `swapMinAmountOut` from the **Aerodrome Quoter** at the service slippage; compute `decreaseLiquidity`/`mint` min-amounts from current reserves. Never from the LLM.
5. **Sign & send:** build `rebalance(slotId, params)`, sign with the dedicated `rebalancer` hot wallet (KMS/secrets-managed, isolated from other Mamo keys), submit via a private/MEV-aware RPC where available, manage nonce, confirm, log.
6. **Observe:** persist every decision (input snapshot, raw LLM output, validation result, tx hash, realized amounts). Metrics + alerts on validation rejections, reverts, slippage near cap, repeated rebalances (possible key compromise).

### 7.2 Trust posture

- Hot wallet holds only the `rebalancer` role — bounded to `rebalance()`/`collectFees()` within contract guards. No custody, no config.
- The LLM is **untrusted for value-bearing numbers** (`minAmountOut`, min-amounts) — those are deterministic.
- **Kill switches:** owner rotates/revokes `rebalancer` and/or `pause()`s the contract; the service has a local circuit-breaker halting on N consecutive reverts or anomaly flags.

## 8. Pool Migration (human-gated) + LLM pair discovery

Re-ranging stays within governance-registered pools. **Migration** — moving a position into a *different* pool/pair (open destination) — is a separate, higher-trust action with a different power model.

### 8.1 Why migration cannot be autonomous or EOA-gated

Every on-chain guard (`maxSlippageBps`, the TWAP value floor) assumes a **known, liquid pool**. With an **open/LLM-discovered destination**, none of them hold: an attacker (or compromised key / hallucinating model) can migrate into a pool they created, seed its TWAP to report MAMO at an arbitrary price, and the value floor will read that fabricated number and approve its own draining; the quoter likewise quotes against the attacker's pool. The contract has nothing trustworthy to value against when the caller chooses the pool.

You can have **open destinations** OR **on-chain-bounded autonomous execution** — not both. So migration's vetting moves to a human/governance step the contract does not pretend to replace. Concretely: `migrate()` is **`DEFAULT_ADMIN_ROLE` (F-MAMO Safe) only**; the `rebalancer`/LLM EOA cannot call it. The only actor that can route protocol liquidity into an arbitrary pool is the multisig — which can already do anything with protocol funds — so `migrate()` adds **no new trust**, it just makes the operation atomic and keeps the registry + fee-skim consistent. (This is exactly why the access-control split in §3.2 keeps `migrate`/`withdraw`/`recover` on the Safe and off any single EOA.)

### 8.2 `migrate(uint256 slotId, MigrateParams params)` — `onlyRole(DEFAULT_ADMIN_ROLE)`, `nonReentrant`, `whenNotPaused`

Params (multisig-reviewed): `destPool, destToken0, destToken1, destTickSpacing, tickLower, tickUpper, swapTokenIn, swapAmountIn, swapMinAmountOut, amount{0,1}MinDecrease, amount{0,1}MinMint, deadline`.

Flow: collect fees → skim to `feeCollector`; `decreaseLiquidity(all)` + collect principal; swap per route with the passed `swapMinAmountOut` (defense-in-depth slippage); `mint` into `destPool` (recipient = contract) with mint mins; burn old NFT; **update the slot in place** (pool/tokens/tickSpacing/tokenId, plus the per-position bounds for the new pool); reset `lastRebalance`; emit `Migrated(slotId, oldPool, destPool, oldTokenId, newTokenId)`.

**Cheap sanity guards** (catch fat-finger, NOT value protection — the human review is the value guard): `destPool.code.length > 0`, `destTickSpacing == IPool(destPool).tickSpacing()`, MAMO is one of `destToken0/1`, ticks aligned + `tickLower < tickUpper`. The TWAP value floor is **deliberately not applied** to migrations because an arbitrary pool's TWAP isn't trustworthy.

### 8.3 LLM pair-discovery pipeline (advisory only)

Because migration is Safe-gated, the LLM's role here is **decision support**: produce a ranked, justified shortlist of candidate MAMO pools for operators to vet. A bad pick is a recommendation a human rejects, not a loss. Pattern (deterministic funnel → LLM reasoning → human execution; mirrors QuickNode's "AI DeFi Yield Optimizer on Base"):

1. **Deterministic data layer (no LLM):** pull the pool universe + metrics.
   - **Aerodrome `LpSugar` (on-chain)** — `all()`/`byIndex()`/`count()` → per-pool reserves, fees, gauge, emissions, CL tick data. **Source of truth** (an attacker can spoof a 3rd-party API but not the on-chain Sugar read).
   - **DefiLlama yields API** (`yields.llama.fi/pools`, free, no auth) — `apyBase` (fee yield = what feeds the drop), `apyReward` (AERO emissions), `tvlUsd`, APY history. Cross-check + trend.
   - Optional analytics API (QuickNode Aerodrome / Bitquery) for 24h volume + fee-APR breakdowns.
2. **Hard pre-filters (deterministic, non-negotiable):** pool must contain **MAMO**; verified canonical Aerodrome CL pool from the factory; **min TVL/depth** (this is the link that makes the destination safe for the re-range TWAP guards — directly addresses the thin-pool caveat in §3.1); min age / cumulative volume; verified counter-token.
3. **Deterministic scoring → candidate set:** rank by fee APR (`apyBase`, the objective), volume/TVL (fees per dollar), TVL (safety weight), counter-token risk (stable vs volatile → IL), optionally `apyReward` if the destination would be gauge-staked.
4. **LLM reasoning:** given the pre-filtered scored candidates + context (current position, realized fees, MAMO volatility regime), emit a **ranked shortlist with written rationale** weighing yield vs depth vs IL vs strategic fit. Outputs recommendations, **not** tx params.
5. **Human/multisig execution:** operators review shortlist + rationale, pick a destination, the **Safe** signs `migrate()`.

Caveats recorded: concentrating into volatile MAMO pairs raises impermanent-loss exposure (LLM weights it, humans own it); trust the on-chain Sugar read over any API; the min-TVL pre-filter is what connects "high-APR pool found" to "the re-range TWAP guards are actually safe there."

### 8.4 Testing additions for migration

- `migrate` access control: `rebalancer`/`manager`/random revert; only admin (Safe) succeeds.
- Sanity guards: non-contract `destPool`, mismatched `destTickSpacing`, MAMO not a leg, misaligned/inverted ticks → revert.
- Fork integration: admin migrates a real MAMO/USDC position into another MAMO pool → assert fees skimmed, principal moved within `swapMinAmountOut`, slot updated (new pool/tokens/tickSpacing/tokenId), old NFT burned, `Migrated` emitted, and the position is subsequently re-rangeable by the `rebalancer` in the new pool.

## 9. Out of scope / non-goals

- Rebalancing the MAMO/VIRTUALS LP (locked in `BurnAndEarn`, no transfer-out).
- Changing the drop staging mechanism (`DropAutomation` / `RewardsDistributorSafeModule`) — fees continue to flow to it unchanged.
- Compounding fees into positions (explicitly rejected; fees feed the drop).
- **Chainlink-valued** retention guards — rejected because MAMO has no reliable Chainlink feed. (Note: this is *not* a reason to skip a value floor entirely. Section 3 adopts a **pool-TWAP-priced** value floor from the `aerodrome-auto-balance` reference, which needs no external oracle. Earlier drafts of this spec incorrectly dropped the value floor on the Chainlink grounds; that reasoning was corrected after reviewing the reference implementation.)
- Human-approval gating **for re-ranges** (rejected — re-ranges run fully autonomously, bounded by on-chain guards). Note: **pool migrations are the opposite** — they are Safe-admin-gated and never autonomous (§8), because open destinations have no enforceable on-chain value protection.
- **Autonomous or single-EOA-gated migration** (rejected — would re-create a treasury-drain path; migration stays on the multisig).
- LLM **autonomously selecting/entering pairs** (rejected — the LLM is advisory-only for pool selection; humans + the Safe execute migrations).
