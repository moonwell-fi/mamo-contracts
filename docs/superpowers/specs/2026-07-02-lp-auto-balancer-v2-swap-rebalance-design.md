# LPAutoBalancerV2 — Swap-Rebalance Mode (CowSwap Two-Phase) Design

**Status:** Implemented (2026-07-03) — commits `4c2ff30`…`03904b3` plus the `rebalanceSlippageBps` hardening; see §8 post-implementation review notes
**Date:** 2026-07-02
**Extends:** `2026-06-17-lp-auto-balancer-v2-dual-position-design.md` (dual-position no-swap base + LPCompoundModule §4b)
**Motivation:** CL10 WETH/cbBTC backtest (Aditya, ~70 days incl. a ~30% drawdown): swap fees are thin (~1.55 bps pool); returns are carried by AERO emissions, and only tight/active concentrated positions capture them (+48% vs hold). The no-swap alt leg sits outside the gauge and earns zero AERO — dead weight in farming mode. Decision (Luke): optimize for AERO farming. But the swap edge exists only while emissions are high; if AERO emissions/price drop, the no-swap alt design wins again. Therefore the contract supports **both**, selected per cycle by the backend.

## 1. Decision summary

| Question | Decision |
| --- | --- |
| Swap venue | **Async CowSwap** (MEV-protected, best-price), NOT an atomic in-pool swap. Accepts a two-phase rebalance state machine and AERO downtime between phases. |
| Mode selection | **Per-cycle by REBALANCER** — no Safe master switch. The backend runs the slippage-payback math (Luke: hours of extra AERO to earn back the swap cost) and picks `rebalanceUsingAlt()` (the renamed `reset()`, no-swap) or `unwindForSwap()`/`rebuildAfterSwap()` (swap) each cycle. |
| Swap ratio | **Continuous** — the backend chooses the sell amount off-chain; selling the full excess ≈ full 50/50 (no alt), selling nothing = today's no-swap path. No on-chain `swapBps`; the amount is embedded in the CowSwap order. |
| Stuck orders | **`rebuildAfterSwap()` is never gated on order state** — it mints from whatever the contract holds. Filled → balanced main; expired unfilled → identical outcome to today's no-swap reset (single-sided main + alt). No cancel path, no on-chain order tracking. (It IS still gated on the calm gate and pause — minting at a deviated price is worse than waiting; `exit()` is the always-available escape.) |
| EIP-1271 hosting | **Module validates, balancer delegates.** Order owner = balancer (tokens are pulled from and delivered to the balancer). The balancer's `isValidSignature` is a ~3-line passthrough to `LPCompoundModule.validateRebalanceOrder`. All validation logic lives on the module (balancer has ~590 B of EIP-170 headroom). |

## 2. Balancer changes (`LPAutoBalancerV2`)

### 2.1 New state

```solidity
bool    public rebalanceInFlight;      // gates the module's principal-swap window
uint256 public rebalanceValueBefore;   // USD (1e8) snapshot at begin, for the finish floor
uint256 public rebalanceStartedAt;     // diagnostics + snapshot field
uint16  public swapLossAllowanceBps;   // admin-set extra floor tolerance for the CowSwap round trip
uint16  public constant MAX_SWAP_LOSS_ALLOWANCE_BPS = 500; // cap on the above
```

### 2.2 `unwindForSwap(UnwindParams)` — `onlyRole(REBALANCER_ROLE)`, `nonReentrant`, `whenNotPaused`

```solidity
struct UnwindParams {
    address sellToken;          // token0 or token1 — the excess leg (backend-computed)
    uint256 sellAmount;         // approve exactly this to VAULT_RELAYER
    uint256 amount0MinWithdraw; // sandwich floors for the teardown (main)
    uint256 amount1MinWithdraw;
    uint256 amount0MinWithdrawAlt; // (alt)
    uint256 amount1MinWithdrawAlt;
    uint256 deadline;
}
```

1. Guards: `active`, NOT already in flight, cooldown (`lastRebalance + minRebalanceInterval`), calm gate (TWAP deviation) — same as `rebalanceUsingAlt()`.
2. Snapshot `rebalanceValueBefore` = main + alt principal at oracle prices **plus** loose balances (`_principalValue` + `_altValue` + `_contractPairValue`), and `rebalanceStartedAt = block.timestamp`.
3. Teardown via the existing `_exitAll`: unstake (skims AERO → feeCollector), skim LP fees, `decreaseLiquidity(all)`, burn both NFTs. Principal now sits loose on the balancer.
4. Validate `sellToken ∈ {token0, token1}` and `sellAmount > 0`; `forceApprove(VAULT_RELAYER, sellAmount)` on `sellToken`.
5. Set `rebalanceInFlight = true`. **No mint.** Emit `RebalanceUnwound(sellToken, sellAmount)`.

The contract does NOT compute the excess on-chain. The backend passes direction + amount; safety does not depend on it being "correct": every order is fair-price-bounded by the module's price check with `receiver == balancer`, so an oversized or wrong-direction sell only converts tokens at market — the finish floor catches any residual loss.

### 2.3 `rebuildAfterSwap(RebalanceParams)` — `onlyRole(REBALANCER_ROLE)`, `nonReentrant`, `whenNotPaused`

1. Requires `rebalanceInFlight` (reverts `NotInFlight` otherwise). **No cooldown check** — finish must always be callable; NOT gated on order settlement.
2. Revoke the sell-token relayer approval (`forceApprove(VAULT_RELAYER, 0)`).
3. Re-run the calm gate (fresh spot/TWAP), then mint from current balances via the **existing** reset mint path: `_mainRange` → `_mintBalanced` → `_mintAlt`. Post-swap ≈50/50 balances → balanced main with tiny/no alt; unfilled order → single-sided main + alt, exactly today's no-swap outcome.
4. Value floor: `valueAfter ≥ rebalanceValueBefore × (BPS − maxRebalanceLossBps − swapLossAllowanceBps) / BPS`, where `valueAfter` = new main + alt + loose at current oracle prices. `swapLossAllowanceBps` covers the CowSwap slippage bound + fees; the per-order price check independently bounds the swap itself. No-swap `rebalanceUsingAlt()` keeps its existing tighter floor (no allowance term).
5. Clear `rebalanceInFlight` (closes the module's signing window — CowSwap re-checks EIP-1271 at settlement, so a stale signed order can no longer settle), zero `rebalanceValueBefore`, restake if the position was staked at begin, stamp `lastRebalance`, forward dust, emit `RebalanceRebuilt(mainTokenId, altTokenId)`.

### 2.4 `isValidSignature` passthrough (balancer)

```solidity
function isValidSignature(bytes32 digest, bytes calldata order) external view returns (bytes4) {
    return LPCompoundModule(compoundModule).validateRebalanceOrder(digest, order);
}
```

Order owner = balancer: GPv2 pulls the sell token from the balancer (approved in begin) and delivers the buy token to the balancer (`receiver == balancer`). Custody never leaves the balancer.

### 2.5 Other

- **Rename `reset()` → `rebalanceUsingAlt()`** — behavior unchanged (the atomic no-swap path); the new name states what it does (rebuilds by parking surplus as the alt, no swap). Mechanical rename across `src/`, the three test files, `011_LPAutoBalancerV2Setup.sol`, and the runbook. `ResetParams` → `RebalanceParams` and the `Reset` event → `RebalancedUsingAlt` to match; `rebuildAfterSwap` reuses `RebalanceParams`.
- `exit(to)` additionally clears `rebalanceInFlight` and revokes any relayer approval — the Safe can always tear down mid-flight.
- `setSwapLossAllowanceBps(uint16)` — `DEFAULT_ADMIN_ROLE`, `≤ MAX_SWAP_LOSS_ALLOWANCE_BPS`.
- `getDecisionSnapshot()` gains `rebalanceInFlight` and `rebalanceStartedAt` so the agent's discovery stage sees pending state.
- New errors: `NotInFlight`, `AlreadyInFlight`, `InvalidSellToken`, `SwapLossAllowanceTooHigh`.
- Cooldown semantics: `unwindForSwap` consumes the cooldown slot (it is the teardown); `rebuildAfterSwap` stamps `lastRebalance` so the next unwind/rebalance honors the interval from finish time.

## 3. Module changes (`LPCompoundModule`)

`isValidSignature` (module-owned orders, i.e. AERO compound) is unchanged. New entry point:

### 3.1 `validateRebalanceOrder(bytes32 digest, bytes calldata encodedOrder) → bytes4`

Called by the balancer's passthrough. Validates a **principal rebalance** order:

- `o.hash(DOMAIN_SEPARATOR) == digest`; `kind == SELL`; fill-or-kill; ERC20 balances; `feeAmount == 0`; `appData == compoundAppData` (same appData policy as compound; a distinct `rebalanceAppData` is NOT needed — the token/direction checks fully classify the order).
- **`ILPAutoBalancerV2(balancer).rebalanceInFlight()` must be true** — the window. Outside it, revert `"no rebalance in flight"`.
- `sellToken` and `buyToken` both ∈ {`balancer.token0()`, `balancer.token1()`} (read live) and `sellToken != buyToken`. AERO is NOT valid here (compound orders go through the module-owned path).
- **`sellToken == ILPAutoBalancerV2(balancer).sellTokenInFlight()`** — the sell leg must match the leg `unwindForSwap` approved this cycle (added in the base-branch hardening pass). Pins swap direction on-chain rather than relying on allowance scoping alone; a reverse-direction order is rejected even though the other token is a valid underlying. Revert `"sellToken must match in-flight approval"`.
- `receiver == balancer`.
- `validTo ∈ [now + 5 min, now + slippagePriceChecker.maxTimePriceValid(sellToken)]`.
- `slippagePriceChecker.checkPrice(sellAmount, sellToken, buyToken, buyAmount, rebalanceSlippageBps)` — a **dedicated, tighter knob** (011 wires 50 bps) rather than the compound path's `allowedSlippageInBps` (200 bps, sized for thin AERO feeds). EIP-1271 placement is permissionless while in flight, so this knob — not the backend's own limit price — is the binding price floor on the approved principal (review note R1, §8). Admin setter `setRebalanceSlippageBps(uint256)` (≤ `MAX_SLIPPAGE_IN_BPS`); default 0 is maximally strict — the checker's condition is `buyAmount > expectedOut·(10000−bps)/10000`, so at 0 bps only an order priced strictly ABOVE the Chainlink rate clears (any below-oracle pricing is rejected). It is NOT a hard "cannot settle" gate: a favorably-priced order can still fill pre-config. The real pre-config block is the deferred checker token-pair configuration (an unconfigured pair reverts `checkPrice`); once that lands, set this knob before enabling the swap path.
- Returns `MAGIC_VALUE` (0x1626ba7e).

`ILPAutoBalancerV2` interface gains `rebalanceInFlight()`.

### 3.2 Checker configuration (owner tx, extends the existing deferred list)

The `CHAINLINK_SWAP_CHECKER_PROXY` owner (`0x26c158A4…`, not F-MAMO) must add, in the same deferred tx as the AERO pairs:

- `WETH → cbBTC`: ETH/USD (forward), BTC/USD (reverse)
- `cbBTC → WETH`: BTC/USD (forward), ETH/USD (reverse)
- `setMaxTimePriceValid` for WETH and cbBTC.

Until configured, `checkPrice` reverts → rebalance orders cannot settle → `rebuildAfterSwap` degenerates safely to the no-swap outcome.

## 4. Off-chain flow (backend, per cycle)

1. Read `getDecisionSnapshot()`; compute imbalance, current AERO emission rate, and the slippage-payback time (hours of extra AERO from a balanced+concentrated position needed to repay the swap cost).
2. **Swap wins** → `unwindForSwap(sellToken, sellAmount, …)` → post CowSwap order (owner = balancer, receiver = balancer, appData = compound appData) → poll settlement → `rebuildAfterSwap(params)`. AERO downtime between begin and finish is a real cost the payback math must include.
3. **Alt wins** (weak emissions / small imbalance) → plain `reset(params)`.
4. Order expired unfilled → call `rebuildAfterSwap` anyway (no-swap outcome) or leave in-flight and re-post within `maxTimePriceValid` bounds; never leave the position unstaked longer than the payback math justifies.

## 5. Security properties

- **Hot key cannot extract value.** Rebalance orders are price-checker-bounded (Chainlink), `receiver == balancer`, fill-or-kill; a malicious/buggy `sellAmount` converts tokens at fair market price at worst. The finish floor (`maxRebalanceLossBps + swapLossAllowanceBps`) bounds the total round-trip loss.
- **Window discipline.** Principal orders validate ONLY while `rebalanceInFlight` — set and cleared solely by role-gated begin/finish/exit. Settlement-time 1271 re-check makes stale signatures dead after finish.
- **Approval hygiene.** Exact-amount approval at begin; revoked at finish and at exit.
- **Pause / exit.** Guardian `pause()` blocks begin and finish (in-flight funds remain recoverable via `exit`, which is admin-gated and unpausable by design). `exit` mid-flight sweeps everything and clears the flag.
- **Size budget.** Balancer adds: 3 state vars + begin/finish (mostly reusing `_exitAll` / mint internals) + a 3-line passthrough + one setter. Must stay < 24,576 bytes. Currently 23,845 (731 B headroom) after the 2026-07-14 SwapWindowLib extraction (prior: 23,962 at this PR's base) moved `validateGauge` and `validatePoolAndNft` into the linked libraries — the escape valve this bullet predicted (2026-07-14: the spillover `LPBalancerLib` was split by domain into `LPGeometryLib` / `LPValuationLib` / `LPPositionLib`, bytecode-neutral). Re-run `forge build --sizes` before trusting this figure; it drifts with every edit.

## 6. Testing

**Balancer unit (mocks):** begin sets flag/snapshot/approval + tears down; begin reverts when in-flight / on cooldown / paused / bad sellToken; finish reverts when not in flight; finish-after-simulated-settlement mints balanced main + floor passes; finish-without-fill reproduces the no-swap outcome; finish floor honors `swapLossAllowanceBps` (reverts when breached); finish revokes approval + clears flag + restakes; exit mid-flight sweeps + clears; snapshot exposes in-flight fields; passthrough delegates to the module.

**Module unit:** rebalance order valid only in-flight (both directions); reverts on same-token, AERO as sell/buy, wrong receiver, failed price check, expired window after finish; compound-order path unaffected.

**Fork (Base, pinned block):** full two-phase cycle on the real CL10 pool — begin (real teardown), simulate settlement (`deal` proceeds + remove sell balance), finish rebuilds a balanced staked main; unfilled path — begin then finish immediately, outcome equals plain reset; 011 proposal wires `setSwapLossAllowanceBps` and the runbook documents the extended checker-owner deferred tx.

**Size:** `forge build --sizes` gate in the plan.

## 7. Out of scope

- On-chain excess/ratio computation (backend's job).
- Automatic re-posting of expired orders (backend's job).
- Cross-pool migration (Phase-2, unchanged).
- Changes to the AERO compound flow (§4a/4b of the base spec) beyond sharing the checker/appData plumbing.

## 8. Post-implementation review notes (2026-07-03)

Independent review of the implemented branch (adversarial pass over `LPAutoBalancerV2`, `LPCompoundModule`, `LPBalancerLib`, `SlippagePriceChecker`, and the 011 proposal, plus live-chain checks). Verified live: GPv2 `domainSeparator()` on Base equals the module's hardcoded constant (`0xd72ffa78…57b4b`; fork tests only simulate settlement net-effect, so this was previously unverified) and `VAULT_RELAYER` is canonical. Custody-safe design confirmed: no path moves value outside {balancer, feeCollector, module}; settlement-vs-rebuild races are safe in both orderings; `exit()` handles mid-flight state correctly. The operational counterpart to these notes is `2026-07-03-lp-auto-balancer-v2-backend-spec.md`.

**R1 — fixed in this branch (was Medium, economic).** EIP-1271 order placement is permissionless while `rebalanceInFlight`: anyone could post an order priced at the shared `allowedSlippageInBps` floor (200 bps, sized for AERO feeds) and hand a solver ~2% of the approved principal, regardless of how tightly the backend priced its own order. Fixed with the dedicated `rebalanceSlippageBps` (§3.1; 011 wires 50 bps). Residual: the permissionless leak bound is now 50 bps of the approved amount per cycle — keep in-flight windows short.

**R2 — accepted (Med-low, liveness).** The rebuild floor compares absolute USD across two transactions: a basket drop > `maxRebalanceLossBps + swapLossAllowanceBps` (400 bps at 011 defaults) mid-flight makes `rebuildAfterSwap` revert `ValueFloor` with zero execution loss; a pump (or a mid-flight donation / compound proceeds — documented at the function) masks real loss up to the same bound. The floor is *soft*: rebuild has no cooldown, so waiting out a drawdown and retrying works; the escapes are wait / raise tolerances (`swapLossAllowanceBps` ≤ 500, `maxRebalanceLossBps` ≤ 500) / `exit()`. Mid-flight funds are loose tokens (no LP exposure, no IL) — the wedge costs AERO downtime, not principal. Backend spec §8.2 is the playbook; the backend logs realized execution shortfall (fill vs Chainlink mid) per cycle so leakage is measured rather than inferred from the floor.

**R3 — CLOSED on-chain (was Med-low; MOO-740 + MOO-741).** Both halves shipped. Sequencer: `LPValuationLib.checkSequencer` now runs inside every `readFeed`, and 011 arms `setSequencerUptimeFeed(CHAINLINK_L2_SEQUENCER_UPTIME_FEED, 3600)` — a guard whose setter is never called is not a guard, so the proposal arms it before anything reads a feed and `LPAutoBalancerV2SetupTest` pins that the armed guard is LIVE, not merely stored. Staleness: the single 26h `maxOracleDelay` is replaced by per-feed `maxOracleDelay0`/`maxOracleDelay1`, ceiling `MAX_ORACLE_DELAY` = 1 day, constructor default `DEFAULT_MAX_ORACLE_DELAY` = 1 hour, and 011 arms 3600/3600 explicitly. Measured basis: 60 rounds of each configured Base feed give a max inter-round gap of 1232 s, so 3600 s ≈ three heartbeats. New residual, accepted and documented at `unwindForSwap`: a ~26× more reachable "feed goes stale between unwind and rebuild" window (three missed rounds, vs ~76 before). Funds are never locked — `exit()` is oracle-free — and the backend controls are a short `validTo` plus preferring the no-swap path while a feed is degraded (backend spec §7/§8.2).

**R4 — launch blocker (ops; already flagged in the 011 comment).** `COMPOUND_APP_DATA = keccak256("mamo-lpv2-compound")` (`0x4e685fb45a0eeffd9bed35e33c88cfcfa7fd6712902fed22a9b934df9a748efa`) has no valid appData-document preimage; the orderbook expects the full JSON document at placement. Before the first order (compound or rebalance): generate a plain `{appCode:"Mamo"}` document (no transferFrom pre-hook — lpv2 fees flow through the on-chain compound split and `feeAmount == 0` is enforced), register it via `PUT /app_data/{hash}`, and `setCompoundAppData(hash)`. Same prerequisite family as the deferred checker config (§3.2) — where `setMaxTimePriceValid` for WETH/cbBTC must be **< `minRebalanceInterval`** (kills cross-cycle order replay; there is no per-cycle nonce) and **> order window + 5 min**.

**R5 — partially closed (2026-07-10).** `collectFees` now has an explicit `AlreadyInFlight` guard — it was the highest-exposure member of this family (permissionless, and `mainStaked` is already false mid-flight so nothing else blocked it). Still no explicit guard on `rebalanceUsingAlt` / `stake` / `withdrawPosition` / `deregisterPosition`: called mid-flight they revert deep on burned-NFT reads — confusing errors but no state corruption and no double-mint (the valuation read reverts before any teardown or mint). All four are role-gated, so the operator sees the confusing revert, not the public. Note `withdrawPosition`/`deregisterPosition` are NOT mid-flight escapes and do not clear the window or revoke the approval; only `exit()` special-cases the in-flight state. Remaining guards queued for the next rev (balancer headroom: 621 B at 23,955 bytes as of 2026-07-10 — re-measure before relying on it).

**R6 — accepted (Low, misc).** The module's compound path keeps a standing `type(uint256).max` AERO relayer approval and validates orders anytime (reward-only exposure, floored at 200 bps — operationally: don't let AERO pool on the module). Admin config setters (`setOracles`/`setMaxOracleDelays`/`setPositionConfig`/`setGauge` — note the singular `setMaxOracleDelay` was removed by MOO-740) are callable mid-flight and silently rebase the two-transaction floor's basis (operator rule: freeze config during a cycle; `setPool` is correctly blocked). An unfilled cycle still consumes a full cooldown (`rebuildAfterSwap` stamps `lastRebalance`). Orders cannot settle in their final 5 minutes (the module's `validTo ≥ now + 5 min` lower bound is re-evaluated at settlement). `MIN_ALT_VALUE_USD` = $0.01 is a dust-tight alt-mint threshold (raise next rev).

**R7 — open, deferred to product (Low, economic; no on-chain action taken).** The `RebuildParams` tick commitment pins the tick PAIR, not the BRANCH that produced it. At `width == 2 × tickSpacing` exactly, the balanced pair `[F − w/2, F + w/2]` and the token1-single-sided pair `[F' − w, F']` with `F' = F + w/2` are the same pair, so a committed pair is not proof of a balanced mint: an attacker who advances the floor-aligned anchor by one spacing (as little as a 1-tick push when honest spot sits at `F + 99`, always ≤ `maxTickDeviation`, so the calm gate accepts it) can convert an intended two-sided deployment into a single-sided deposit priced at manipulated spot — the single-sided branch zeroes the caller's token0 mint minimum — and consume the cooldown. The phase-1 config (`tickSpacing` 100, `MIN_WIDTH`/`WIDTH_TICKS` 200, `maxTickDeviation` 100) is exactly the vulnerable point; 200 is the ONLY vulnerable width at that deviation bound. Two zero-bytecode closures exist and the choice between them is a yield call, not a security one: (a) the backend submits any `width ≥ 4 × tickSpacing` per cycle — no Safe write, no standing commitment to wider ranges; (b) ship `MIN_WIDTH` 400 (`minWidth > 2 × maxTickDeviation`), which closes it for every caller but **doubles every phase-1 position's width**, against a backtest whose +48%-vs-hold edge is tight ranges (backend spec §5). Deliberately NOT changed in the MOO-740/741 remediation: the on-chain surface is unaffected either way. Interim control, in force today: the balanced branch forwards BOTH caller mint minima untouched, so sized `amount0Min`/`amount1Min` revert the skewed mint — see the sizing rule in backend spec §5 and residual 1 in §2.2.
