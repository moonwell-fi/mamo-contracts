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
| Custody/logic location | **New standalone `LPAutoBalancer`** contract holding the NFTs; owner = F-MAMO Safe |
| Trigger model | **Backend-decided params + on-chain guards** (mirrors `DropAutomation`) |
| Fee handling on rebalance | **Skim accrued fees to fee collector** (`DropAutomation`); rebalance only re-ranges principal — preserves current drop economics |
| Scope | **Generic multi-position registry**; start with the `TransferAndEarn` positions |
| Safety model | **Approach A**: per-swap slippage cap + per-position cooldown + width/deviation bounds + decrease/mint min-amounts |
| Operator | **No Gelato.** A dedicated `rebalancer` EOA (the backend hot wallet the LLM signs with); owner can rotate/revoke instantly |
| LLM role | **LLM computes params directly** (raw target ticks + swap direction/size) → the on-chain contract is the *entire* trust boundary; value-bearing numbers (`minAmountOut`, min-amounts) are still computed deterministically off-chain, never by the LLM |
| Authorization | **Fully autonomous** — service signs and sends with no human gate, bounded by contract guards + a service-side circuit-breaker |

## 3. On-chain Contract: `LPAutoBalancer`

`Ownable`, `ReentrancyGuard`, `Pausable`, `IERC721Receiver`. Solidity 0.8.28, BUSL-1.1 (matches repo).

### 3.1 Trust boundary

The LLM emits raw ticks + swap params. Therefore the contract treats `rebalance()` params as **arbitrary and potentially adversarial** (compromised key / hallucinating model). Every guard must hold against attacker-chosen inputs, not merely honest-but-imperfect ones. Worst-case value loss per call is bounded to ≈ `maxSlippageBps` on the swapped portion; the cooldown rate-limits cumulative damage; the owner kill-switch (`pause` / revoke `rebalancer`) stops it entirely.

### 3.2 Roles

- `owner` = **F-MAMO Safe**: register/deregister positions, set all policy bounds, emergency-withdraw NFTs, `recoverERC20`/`recoverETH`, `pause`/`unpause`, rotate `rebalancer`.
- `rebalancer` = a single dedicated EOA (`MAMO_LP_REBALANCER`): may **only** call `rebalance()` and `collectFees()`. Holds no token custody and no config powers.

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

Global constants: `MAX_SLIPPAGE_CAP_BPS` (e.g. 500 = 5%), `BPS_DENOMINATOR = 10_000`, `SWAP_DEADLINE_BUFFER`.

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
2. **Collect fees only**: `collect(tokenId, max, max)` *before* decreasing liquidity collects only accrued `tokensOwed` (fees). Forward both tokens to `pos.feeCollector` → keeps the drop fed. Emit `FeesSkimmed`.
3. **Decrease all liquidity**: read position `liquidity`; `decreaseLiquidity(tokenId, liquidity, amount0MinDecrease, amount1MinDecrease, deadline)`; then `collect(tokenId, max, max)` to pull principal into the contract.
4. **Validate new range** against live `pool.tickSpacing()` + `slot0().tick`:
   - ticks aligned to `tickSpacing` (`tickLower % spacing == 0`, same for upper);
   - `tickLower < tickUpper`;
   - `pos.minWidth <= (tickUpper - tickLower) <= pos.maxWidth`;
   - range straddles current tick: `tickLower < currentTick < tickUpper`;
   - `|((tickLower+tickUpper)/2) - currentTick| <= pos.maxCenterDeviation`.
5. **Swap** to reach the target ratio via Aerodrome CL router, reusing `DropAutomation._executeSwap`'s dual-layer guard:
   - quoter-based on-chain min = `quotedOut * (BPS - maxSlippageBps) / BPS`;
   - effective `minOut = max(quoterMin, swapMinAmountOut)`;
   - `require(swapTokenIn` is one of `token0/token1)`; tickSpacing from `pos`.
6. **Mint** new position (recipient = `address(this)`) with `amount0MinMint`/`amount1MinMint`; **burn** the old now-empty NFT; set `pos.tokenId = newTokenId`; `pos.lastRebalance = block.timestamp`.
7. **Forward dust**: any residual `token0`/`token1` after mint → `pos.feeCollector` (no value trapped in the contract).
8. Emit `Rebalanced(slotId, oldTokenId, newTokenId, tickLower, tickUpper)`.

### 3.5 `collectFees(uint256 slotId)` — **permissionless**, `whenNotPaused`

Standalone fee skim **between** rebalances so the drop keeps its current cadence without forcing a re-range. Permissionless because funds can only ever move to the owner-configured `pos.feeCollector` — there is no caller-chosen destination, so opening it up is safe and lets a keeper/cron poke it cheaply. `collect(tokenId, max, max)` → forward to `pos.feeCollector`. Emit `FeesSkimmed`.

### 3.6 Owner / emergency functions

- `registerPosition(ManagedPosition config)` — requires the NFT already held by the contract; assigns a `slotId`; validates bounds (`maxSlippageBps <= MAX_SLIPPAGE_CAP_BPS`, `minWidth <= maxWidth`, non-zero pool/tokens). Returns `slotId`.
- `deregisterPosition(slotId, address to)` — transfer the current NFT out to `to`, mark inactive.
- `withdrawPosition(slotId, address to)` — emergency: transfer the current NFT to `to` (the Safe).
- `setRebalancer(address)`, `setPositionConfig(slotId, ...)`, `setFeeCollector(slotId, address)`.
- `recoverERC20(token, to, amount)`, `recoverETH(to)`.
- `pause()` / `unpause()`.
- `onERC721Received` — accept NFTs (restricted to the Aerodrome position manager as `msg.sender`, like `TransferAndEarn`).

### 3.7 Events

`PositionRegistered`, `PositionDeregistered`, `Rebalanced`, `FeesSkimmed`, `RebalancerUpdated`, `FeeCollectorUpdated`, `PositionConfigUpdated`, `PositionWithdrawn`, `TokensRecovered`.

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

- **Guard/unit**: tick alignment, width bounds, center-deviation, cooldown, slippage cap, access control (`onlyRebalancer` / `onlyOwner`), `pause`, emergency `withdrawPosition`, `onERC721Received` sender restriction.
- **Integration (fork)**: register a real MAMO/cbBTC position → swap in the pool to push the tick out of range → `rebalance()` → assert new range straddles tick, fees skimmed to `DropAutomation`, principal preserved within slippage, old NFT burned, `tokenId` updated, dust forwarded.
- **Adversarial**: attacker `rebalance` params (off-spacing / excess-width / non-straddling ticks, slippage above cap, pre-cooldown) all revert; withdrawal & mint min-amounts bound a simulated sandwich.
- **FPS proposal test** (like `ERC20StrategyV2Test`): run `006`'s deploy/build/simulate/validate end-to-end.

## 7. Off-chain Rebalancing Service (separate workstream)

Standalone TypeScript/Node service on a scheduler. The contract is the hard boundary; the service fails fast and keeps a full audit trail. **Fully autonomous** — no human gate.

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
   - Re-validate the LLM output against the policy envelope locally (alignment, width, straddle, deviation) → reject + alert before spending gas (mirror of on-chain guards; the revert is the backstop).
   - Compute `swapMinAmountOut` from the **Aerodrome Quoter** at the service slippage; compute `decreaseLiquidity`/`mint` min-amounts from current reserves. Never from the LLM.
5. **Sign & send:** build `rebalance(slotId, params)`, sign with the dedicated `rebalancer` hot wallet (KMS/secrets-managed, isolated from other Mamo keys), submit via a private/MEV-aware RPC where available, manage nonce, confirm, log.
6. **Observe:** persist every decision (input snapshot, raw LLM output, validation result, tx hash, realized amounts). Metrics + alerts on validation rejections, reverts, slippage near cap, repeated rebalances (possible key compromise).

### 7.2 Trust posture

- Hot wallet holds only the `rebalancer` role — bounded to `rebalance()`/`collectFees()` within contract guards. No custody, no config.
- The LLM is **untrusted for value-bearing numbers** (`minAmountOut`, min-amounts) — those are deterministic.
- **Kill switches:** owner rotates/revokes `rebalancer` and/or `pause()`s the contract; the service has a local circuit-breaker halting on N consecutive reverts or anomaly flags.

## 8. Out of scope / non-goals

- Rebalancing the MAMO/VIRTUALS LP (locked in `BurnAndEarn`, no transfer-out).
- Changing the drop staging mechanism (`DropAutomation` / `RewardsDistributorSafeModule`) — fees continue to flow to it unchanged.
- Compounding fees into positions (explicitly rejected; fees feed the drop).
- Oracle-valued retention guards (no reliable MAMO Chainlink feed; the slippage-cap + cooldown model is the chosen protection).
- Human-approval gating (rejected in favor of fully autonomous operation bounded by guards).
