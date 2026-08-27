# LPAutoBalancerV2 — WETH/cbBTC Phase-1 Setup Runbook

> 📖 New here? Start with the [system overview](LP_AUTO_BALANCER_V2.md) — architecture, state machines, and how this runbook fits in.

**Status:** Operational runbook (phase-1)
**Audience:** Mamo ops + F-MAMO Safe signers + the backend team running the LLM rebalancer
**Design refs:** `docs/superpowers/specs/2026-06-17-lp-auto-balancer-v2-dual-position-design.md` (contract), `centaur-moonwell` `docs/superpowers/specs/2026-06-17-lp-balancer-agent-design.md` (agent)

This is the step-by-step to stand up the **first** managed position: a **WETH/cbBTC** Aerodrome Slipstream CL position managed by `LPAutoBalancerV2` (no-swap dual-position rebalancer) and driven by the off-chain LLM agent. The three actors and their jobs:

| Actor | Does |
| --- | --- |
| **TransferAndEarn** | Releases underperforming protocol LP back to the Safe (source of capital) |
| **F-MAMO Safe** (`DEFAULT_ADMIN_ROLE`) | Liquidates → WETH+cbBTC, mints the CL position, deposits it into the balancer, registers it, hands the rebalancer key to the backend |
| **Backend / LLM** (`REBALANCER_ROLE`) | After handover: `rebalanceUsingAlt` / `stake` / `unstake` / `claimEmissions` / `compound` only — never sells principal, never withdraws to itself |

> **Trust model:** every value-moving action (selling, minting, registering, emergency exit) is the **Safe's**. The backend key can only re-range and stake within on-chain guards and can only route fees/AERO to the configured `feeCollector`. Keep the two strictly separated.

---

## 0. Prerequisites — addresses (Base mainnet, verified on the fork test)

| Thing | Address |
| --- | --- |
| WETH/cbBTC Slipstream CL pool (`tickSpacing = 10`) | `0x42d4a22CaD0F5a49681a5715cE994Af73A43B76b` |
| CL gauge (rewardToken = AERO) | `0x61E0B10423a0009C3f83ab4313813d29437d0817` |
| **Slipstream NonfungiblePositionManager** (the one the gauge accepts) | `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` |
| WETH (**token0**) | `0x4200000000000000000000000000000000000006` |
| cbBTC (**token1**) | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| AERO | `0x940181a94A35A4569E4529A3CDfB74e38FD98631` |
| Chainlink ETH/USD (8-dec) | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink BTC/USD (8-dec) | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` |
| Chainlink AERO/USD (8-dec, for compound) | `0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0` (`CHAINLINK_AERO_USD`) |
| SlippagePriceChecker proxy (compound min-out) | `CHAINLINK_SWAP_CHECKER_PROXY` — owner `0x26c158A4…` (**not** F-MAMO) |
| feeCollector (drop sink) | `DROP_AUTOMATION` (from `addresses/8453.json`) |

> **Two gotchas, both confirmed on-chain:**
> 1. The position manager the **gauge accepts** is `0xe1f8cd…`, registered in `addresses/8453.json` as **`AERODROME_SLIPSTREAM_NFPM_V2`** — **not** `AERODROME_POSITION_MANAGER` (`0xc741be…`, a different address). Deploy and mint against `0xe1f8cd…` / `AERODROME_SLIPSTREAM_NFPM_V2`.
> 2. Token order is by address: **WETH = token0, cbBTC = token1** (`0x42…` < `0xcb…`). Every `token0`/`token1`/`oracle0`/`oracle1`/`amount0`/`amount1` field follows this order.

---

## Phase 0 — Deploy `LPAutoBalancerV2`

Deploy via `script/DeployLPAutoBalancerV2.s.sol` (`deployLPAutoBalancerV2(Addresses)` / `run()`) — it reads `F-MAMO` (admin+guardian), `AERODROME_SLIPSTREAM_NFPM_V2`, `AERO`, passes `manager_ = rebalancer_ = address(0)`, and records `MAMO_LP_AUTO_BALANCER_V2`. Or deploy via the FPS proposal's `deploy()` (Phase B). Constructor (6 args, **no swap router / no quoter**):

```solidity
new LPAutoBalancerV2(
    admin_           = F_MAMO_SAFE,          // DEFAULT_ADMIN_ROLE
    manager_         = MANAGER_EOA,          // MANAGER_ROLE (bounds tuning within caps); may be address(0)
    rebalancer_      = address(0),           // grant LATER, in Phase C (do NOT wire the backend key at deploy)
    guardian_        = GUARDIAN_EOA_OR_SAFE, // pause()
    positionManager_ = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53, // Slipstream NFPM
    aero_            = 0x940181a94A35A4569E4529A3CDfB74e38FD98631
);
```

Record the deployed address as `MAMO_LP_AUTO_BALANCER_V2` in `addresses/8453.json`.

> Leave `rebalancer_ = address(0)` at deploy. The backend key is granted only in Phase C, after the position is funded and registered, so the hot key never exists against an empty/unguarded contract.

---

## Phase A — TransferAndEarn: release the capital

`TransferAndEarn` holds the protocol's Aerodrome LP NFTs and is owned by the Safe. To fund WETH/cbBTC you liquidate a **portion of the underperforming** positions (the weaker MAMO pairs identified by the team). Leave the better-performing MAMO pools untouched.

1. **(optional) Sweep pending fees first** so they aren't stranded: `transferAndEarn.earn(tokenId)` (or `earnMany([...])`) on the positions you're about to move — forwards accrued fees to the fee collector.
2. **Return the underperforming position NFT(s) to the Safe:** Safe (the owner) calls `transferAndEarn.transfer(tokenId)` (or `transferMany([tokenIds])`). This sends each LP NFT back to the Safe.
3. The Safe now holds the underperforming LP NFTs. **Do not move the MAMO pools you intend to keep.**

Output of Phase A: the Safe holds the LP positions to be liquidated into WETH + cbBTC.

---

## Phase B — Safe: build and register the WETH/cbBTC position

**Phase B is implemented as an FPS proposal: `multisig/mamo-multisig/011_LPAutoBalancerV2Setup.sol`** (`deploy` → `build` → `simulate` → `validate`), with a Base-fork test `test/LPAutoBalancerV2Setup.integration.t.sol` (`make lp-v2-setup`) that mints a real WETH/cbBTC position, runs the full lifecycle, and proves the granted rebalancer can `rebalanceUsingAlt`. **Two values the production run MUST set on the proposal** (it reverts otherwise — fail-safe, no silent zero-address): `setTokenId(INIT_TOKEN_ID)` (the off-chain-minted NFT from B2) and `setRebalancerEOA(backendEOA)` (or add `MAMO_LP_REBALANCER` to `addresses/8453.json`). The proposal's `build()` encodes the on-chain Safe actions (B3 transfer-in + B4 register + C1 grant-rebalancer); the liquidate+mint (B1/B2) stay off-chain. Manual sequence below documents what the proposal does.

### B1. Liquidate the underperforming LP → WETH + cbBTC
Withdraw liquidity from the Phase-A NFTs and swap the proceeds into **WETH + cbBTC** in the ratio you want for the initial position (≈50/50 by value for a centered main). Use the team's preferred venue (Aerodrome router / CoWSwap). This is a deliberate, Safe-reviewed sell — it is the one value-moving swap in the whole flow and is intentionally **off** the rebalancer.

End state: the Safe holds `X` WETH + `Y` cbBTC (small phase-1 size — keep TVL-at-risk low while proving the rebalancer).

### B2. Mint the initial WETH/cbBTC CL position
Mint via the Slipstream NFPM (`0xe1f8cd…`), recipient = **Safe**:
- `token0 = WETH`, `token1 = cbBTC`, `tickSpacing = 10`.
- Initial range: centered on current spot, width a multiple of `tickSpacing` and **≥ 2·tickSpacing = 200** (the contract rejects narrower — see B4). A wider initial range (e.g. a few thousand ticks) is fine; the agent re-ranges later.
- `amount0Desired / amount1Desired` = the WETH/cbBTC from B1; set sane `amount{0,1}Min`.

Record the returned `tokenId` → call it `INIT_TOKEN_ID`.

### B3. Deposit the NFT into the balancer
Safe transfers the position NFT into `LPAutoBalancerV2` **via the position manager** (its `onERC721Received` only accepts the NFPM as `msg.sender`):

```
INFPM(0xe1f8cd…).safeTransferFrom(SAFE, MAMO_LP_AUTO_BALANCER_V2, INIT_TOKEN_ID)
```

### B4. `registerPosition(config)` — Safe (`DEFAULT_ADMIN_ROLE`)
Call `registerPosition` with the `ManagedPositionV2` config. The contract **validates** the config and reverts if any of these fail — get them right:

- `mainTokenId = INIT_TOKEN_ID` and the NFT is **already held** by the contract (B3 done first).
- `pool = 0x42d4a2…` and **`pool.token0()/token1()/tickSpacing()` must equal** `token0=WETH`, `token1=cbBTC`, `tickSpacing=10` (`PoolMismatch` otherwise).
- `gauge = 0x41b2…` and **`gauge.rewardToken()` must equal `AERO`** (`GaugeRewardMismatch` otherwise).
- `oracle0 = ETH/USD (0x71041d…)`, `oracle1 = BTC/USD (0x64c911…)` — both must return a **fresh, non-zero** answer at call time. Each leg is bounded SEPARATELY: `maxOracleDelay0` for `oracle0`, `maxOracleDelay1` for `oracle1` (constructor seeds `DEFAULT_MAX_ORACLE_DELAY` = 1h, hard cap `MAX_ORACLE_DELAY` = 1 day). Proposal 011 arms both at 3600s — 3x the feeds' ~20-minute heartbeat.
- `minWidth ≥ 2·tickSpacing = 20`, `minWidth % 10 == 0`, `maxWidth ≥ minWidth` (`WidthTooNarrow` / `InvalidWidth`).
- `maxRebalanceLossBps ≤ MAX_LOSS_CAP_BPS`, `maxTickDeviation > 0`, `maxCenterDeviation > 0`, `twapWindow > 0`.
- `feeCollector = DROP_AUTOMATION`.

Suggested phase-1 config values (conservative; manager can tune within caps later):

| Field | Value | Note |
| --- | --- | --- |
| `pool` | `0x42d4a2…` | WETH/cbBTC |
| `token0 / token1` | WETH / cbBTC | address order |
| `tickSpacing` | `10` | |
| `gauge` | `0x41b2…` | rewardToken == AERO |
| `feeCollector` | `DROP_AUTOMATION` | drop sink |
| `oracle0 / oracle1` | ETH/USD / BTC/USD | 8-dec feeds |
| `minWidth` | `200` | = 2·tickSpacing (floor) |
| `maxWidth` | e.g. `20000` | operator choice |
| `maxCenterDeviation` | e.g. `200` | backstop on center |
| `twapWindow` | e.g. `1800` (30m) | calm gate + value-floor fallback; confirm pool oracle cardinality covers it |
| `maxTickDeviation` | e.g. `100` | calm gate; correlated pair → tight |
| `maxRebalanceLossBps` | e.g. `100` (1%) | no-swap → sanity guard; small headroom is enough |
| `minRebalanceInterval` | e.g. `21600` (6h) | matches the agent's sweep cadence; **set > 0** so a buggy agent can't loop rebalances |
| `mainTokenId` | `INIT_TOKEN_ID` | held NFT |
| `altTokenId / mainStaked / altStaked / lastRebalance / active` | `0 / false / false / 0 / true` | **forced** by `_store` — values you pass are ignored (`active` is forced **true**: registration activates the position) |

> **Single position per contract (no `slotId`).** One `LPAutoBalancerV2` manages exactly **one** pool: state lives in a single `position` struct, and every external call (`rebalanceUsingAlt`, `stake`, `exit`, `getDecisionSnapshot`, …) takes **no** `slotId`. To repoint the contract at a different pair, empty it first (`exit`) then `setPool(newConfig)` — see "Changing the pool" below. `registerPosition` reverts `AlreadyRegistered` if a position is already active.

### B5. AERO routing in DropAutomation
Confirm **AERO is whitelisted in `DropAutomation`'s swap config** so claimed emissions get swapped into the drop. If not, add it (Safe). Without this, AERO reaches the feeCollector but isn't converted.

> **Do not stake at setup.** Whether to gauge-stake (farm AERO) vs stay unstaked (fees) is the agent's per-pair decision (`stake` is `REBALANCER_ROLE`). Leave it unstaked; the backend stakes if/when its APR comparison says to.

### B6. Compound module (partial AERO reinvest) — `LPCompoundModule`

The `011` proposal also **deploys `LPCompoundModule`** (admin = F-MAMO, immutably linked to this balancer) and wires the F-MAMO-doable part:

- `lab.setCompoundModule(module)` — the balancer forwards the compound share of harvested AERO here.
- `module.setSlippagePriceChecker(CHAINLINK_SWAP_CHECKER_PROXY)`, `module.setSlippage(200)` (2%, compound/AERO orders), `module.setRebalanceSlippageBps(50)` (0.5%, principal WETH↔cbBTC orders — deliberately much tighter: EIP-1271 placement is permissionless while a swap-rebalance is in flight, so this knob is the binding price floor on the approved principal), `module.setCompoundAppData(keccak256("mamo-lpv2-compound"))`.

> **appData is a placeholder.** `keccak256("mamo-lpv2-compound")` has no valid appData-JSON preimage, and the CoW orderbook wants the full document at order placement. Before the first order of either kind: generate a plain `{appCode:"Mamo"}` document (no pre-hook), `PUT` it to `/app_data/{hash}` on the orderbook, and F-MAMO `setCompoundAppData(realHash)`. See the backend spec §10 for the exact commands.

**Three steps are DEFERRED to a separate owner tx** because the `CHAINLINK_SWAP_CHECKER_PROXY` owner is **not** F-MAMO:

1. **Checker owner** (`0x26c158A4…`): `addTokenConfiguration(AERO → WETH)` and `(AERO → cbBTC)` using `CHAINLINK_AERO_USD` (`0x4EC5970f…`, 8-dec, forward) then ETH/USD resp. BTC/USD (reverse), plus `setMaxTimePriceValid(AERO, …)`. Only after this is AERO a reward token.
2. **Checker owner — SWAP-REBALANCE pair (do not skip)**: `addTokenConfiguration(WETH → cbBTC)` and `(cbBTC → WETH)` (ETH/USD forward + BTC/USD reverse and vice-versa), plus `setMaxTimePriceValid(WETH, …)` **and** `setMaxTimePriceValid(cbBTC, …)`. `validateRebalanceOrder` calls `checkPrice` on the WETH↔cbBTC pair and an **unconfigured pair reverts** — without this step no rebalance order ever validates and every `unwindForSwap`/`rebuildAfterSwap` cycle silently degrades to a no-swap rebuild. See "Rebalance mode selection" below for the `maxTimePriceValid == 0` failure mode this also prevents.
3. **F-MAMO**: `module.approveCowSwap()` — reverts `"Token not allowed"` until step 1 lands.

Until steps 1 and 3 run, `compound(compoundBps)` still harvests AERO, drops the `(1 − compoundBps)` share to `feeCollector`, and forwards the `compoundBps` share to the module; only the CowSwap **sell leg** is inert (no relayer allowance / orders fail slippage) — which is safe. The off-chain bot posts two CowSwap sell orders (AERO→WETH, AERO→cbBTC, ~50/50 by value) validated by the module's `isValidSignature`; the solver delivers the underlying **to the balancer**, where it folds into the next `rebalanceUsingAlt()`. Reward-only — principal is never swapped.

Output of Phase B: a registered, **unstaked** WETH/cbBTC position in the balancer, fees/AERO wired to the drop, and a linked compound module (CowSwap approval pending the checker-owner tx). No hot key exists yet.

---

## Rebalance mode selection (swap vs. no-swap)

Every rebalance cycle, the backend (`REBALANCER_ROLE`) picks **one** of two paths. There is **no Safe-level master switch** — the choice is made per cycle by the backend, based on whether re-ranging the position without a swap keeps it reasonably centered or whether a partial swap is needed to rebalance the underlying ratio:

- **No-swap path — `rebalanceUsingAlt(RebalanceParams)`.** The original single-transaction flow: re-range using only what the position already holds. Use this whenever it's sufficient; it's simpler and has no off-chain dependency.
- **Swap path — `unwindForSwap(UnwindParams)` + off-chain CowSwap order + `rebuildAfterSwap(RebuildParams)`.** (`RebuildParams` is the slimmer 6-field struct — `width`, the four mint mins, `deadline`; it has **no** withdraw-min fields, those belong to `UnwindParams`.) An async, two-phase flow for when the backend needs to actually change the WETH/cbBTC ratio:
  1. `unwindForSwap` tears down the position and pins the CowSwap relayer's allowance to an **exact** sell amount.
  2. The backend places a CowSwap order off-chain. **The sell amount is chosen off-chain by the backend and baked directly into the order** — the contract's only job is pinning the relayer approval to that exact amount in step 1; it does not compute or re-derive a sell size on-chain.
  3. Once the order settles (or is abandoned), the backend calls `rebuildAfterSwap` to redeploy into a fresh position.

### Stuck-order handling

`rebuildAfterSwap` is **never gated on CowSwap order state**. If the order expires unfilled, calling `rebuildAfterSwap` anyway simply redeploys the principal as-is — the outcome is identical to what the no-swap path would have produced. What `rebuildAfterSwap` **is** gated on is `pause()` and the TWAP calm gate, same as the no-swap path.

For a true escape hatch mid-flight — for example if the backend key goes dark after `unwindForSwap` but before `rebuildAfterSwap` — `exit()` (`DEFAULT_ADMIN_ROLE`, Safe-only) is **always available**, swap or no swap. It correctly detects an in-flight swap-rebalance and skips the redundant teardown step (the position was already torn down by `unwindForSwap`), going straight to returning principal to the Safe.

### On-chain order validation

CowSwap orders for the swap path are validated on-chain via `LPCompoundModule.validateRebalanceOrder` (EIP-1271, `isValidSignature`). An order only validates if **all** of the following hold:

- Fill-or-kill sell order strictly between the pool's two underlying tokens (WETH/cbBTC).
- `sellToken == sellTokenInFlight()` — the sell leg must be exactly the one `unwindForSwap` approved this cycle. A reverse-direction order is rejected even though the other token is a valid underlying (defense-in-depth beyond the exact-amount relayer allowance).
- `receiver == balancer` (the `LPAutoBalancerV2` contract itself, never the backend EOA).
- Price bounded by the Chainlink-backed `SlippagePriceChecker` using the module's **dedicated `rebalanceSlippageBps`** (011: 50 bps) — NOT the looser compound slippage. This bound matters more than the backend's own limit price: order placement is permissionless while the window is open, so any third-party order is floored here too.
- Expiry window: minimum 5 minutes (re-checked at settlement — an order cannot settle in its final 5 minutes), maximum the checker's `maxTimePriceValid`. The checker owner must keep `maxTimePriceValid(WETH/cbBTC) < minRebalanceInterval` (6h) so a stale order from one cycle can never settle inside the next cycle's window.
- Validates **only** while the balancer reports `rebalanceInFlight() == true` — i.e. only between `unwindForSwap` and `rebuildAfterSwap`. Outside that window, no order can be signed off.

### `setSwapLossAllowanceBps`

`setSwapLossAllowanceBps` (admin-only, capped at `MAX_SWAP_LOSS_ALLOWANCE_BPS = 500` bps) sets the **extra** value-floor tolerance `rebuildAfterSwap` allows for the CowSwap round-trip's real-world slippage, on top of the position's existing `maxRebalanceLossBps`. The `011` proposal sets this to `SWAP_LOSS_ALLOWANCE_BPS = 300` (3%) by default — a conservative allowance on top of the 1% `maxRebalanceLossBps` already configured for phase-1 (see B4).

> **Manual prerequisite, unchanged from B6:** as with AERO compounding, the `CHAINLINK_SWAP_CHECKER_PROXY` owner (**not** F-MAMO) must have the relevant WETH/cbBTC feed configuration in place — here it's the existing `oracle0`/`oracle1` config already required by `registerPosition` (B4), plus `WETH→cbBTC` and `cbBTC→WETH` token-pair configs on the checker itself, before swap-rebalance orders can settle in production. Without this, `validateRebalanceOrder` will reject any order priced against those pairs.
>
> **Also required — `setMaxTimePriceValid(WETH, …)` and `setMaxTimePriceValid(cbBTC, …)`.** `validateRebalanceOrder` enforces `order.validTo <= now + slippagePriceChecker.maxTimePriceValid(sellToken)`, where `sellToken` is WETH or cbBTC. The checker returns `0` for any token that never had `setMaxTimePriceValid` called on it — and B6 only calls it for AERO. With `maxTimePriceValid(WETH) == 0`, that bound collapses to `validTo <= now`, which is mutually exclusive with the `validTo >= now + 5 minutes` floor `validateRebalanceOrder` also enforces — **every** rebalance order reverts, even after the token-pair configs above are added. Missing this bricks the swap path silently: `unwindForSwap` tears down the position, no CowSwap order can ever settle, and the only way back in is an admin `exit()`. The checker owner must set this alongside the AERO step in B6 before the swap path is used in production.

---

## Phase C — Handover to the LLM backend

### C1. Grant the rebalancer key
Safe grants `REBALANCER_ROLE` to the backend's **signer EOA** (the key the sandboxed agent uses for `cast send`):

```
lpAutoBalancerV2.grantRole(REBALANCER_ROLE, BACKEND_REBALANCER_EOA)
```

`REBALANCER_ROLE = keccak256("REBALANCER_ROLE")`. This EOA can call only `rebalanceUsingAlt` / `unwindForSwap` / `rebuildAfterSwap` / `compound` / `stake` / `unstake` — no custody, no config; value can only ever move to the balancer itself, the `feeCollector`, or the compound module. (`claimEmissions` and `collectFees` are permissionless skims to the feeCollector, not role-gated.)

### C2. Configure the backend (`centaur-moonwell` `lp_balancer_sweep` workflow)

The full backend behavior — cycle state machine, swap-vs-alt decision math, CowSwap order lifecycle, config invariants, and the failure playbook — is specified in `docs/superpowers/specs/2026-07-03-lp-auto-balancer-v2-backend-spec.md`. Set the env the agent reads (baseline below; swap-mode vars in the backend spec §11):

| Env | Value |
| --- | --- |
| `MOONWELL_LP_AUTO_BALANCER` | deployed `LPAutoBalancerV2` address |
| `MOONWELL_LP_RPC_URL` | Base RPC (the gate's `eth_call` + the agent's `cast` use it) |
| `MOONWELL_LP_HYSTERESIS_BPS` | e.g. `200` (stake/unstake anti-flap) |
| `MOONWELL_LP_MAX_TURNS` | e.g. `3` |
| `MOONWELL_LP_MAX_UNSWEPT_AERO` | dust threshold for the "no unswept AERO" goal clause |

Provision the `BACKEND_REBALANCER_EOA` private key **inside the sandbox** (the workflow layer never holds it). The completion gate reads `getDecisionSnapshot()` over JSON-RPC; the agent acts via `cast send`.

### C3. Verify before go-live
- **Read path:** call `getDecisionSnapshot()` — confirm `mainInRange`, `hasGauge == true`, `mainStaked == false`, `cooldownRemaining`, `deviationGateOpen` look right.
- **Dry run:** on a fork (or testnet), have the backend run one sweep turn end-to-end — confirm a `rebalanceUsingAlt` lands, `RebalancedUsingAlt` event fires, fees/AERO route to `DropAutomation`, and the gate's independent re-read agrees with the agent's report.
- **Guards live:** confirm cooldown blocks a too-soon second rebalanceUsingAlt; confirm the calm gate (`maxTickDeviation`) and value floor are active.
- **Market gather:** note that the stake/unstake decision stays dormant until the LpSugar/DefiLlama APR gather is wired in the workflow (logged follow-up). Until then phase-1 runs **rebalanceUsingAlt-only** safely.

### C4. Go live
Enable the `lp_balancer_sweep` cron (default every 6h, matching `minRebalanceInterval`). Monitor the first few sweeps.

---

## Verification checklist (post-setup)

- [ ] `LPAutoBalancerV2` deployed; admin = Safe, guardian set, rebalancer = backend EOA, manager optional.
- [ ] Position NFT held by the contract; the single `position` registered and `active`.
- [ ] `registerPosition` passed all validations (pool/token/tickSpacing match, gauge reward = AERO, oracles fresh, `minWidth ≥ 200`).
- [ ] `feeCollector == DROP_AUTOMATION`; AERO whitelisted in DropAutomation swaps.
- [ ] `minRebalanceInterval > 0`.
- [ ] Backend can read `getDecisionSnapshot` and execute a guarded `rebalanceUsingAlt`; gate re-reads chain independently.
- [ ] Small phase-1 TVL.

## Emergency / rollback (Safe + guardian)

- **Pause:** guardian calls `pause()` — blocks `rebalanceUsingAlt`/`stake`/`unstake`/`claimEmissions` (not `exit`).
- **Revoke the key:** Safe `revokeRole(REBALANCER_ROLE, BACKEND_REBALANCER_EOA)` — instantly stops the backend.
- **Full teardown:** Safe `exit(SAFE)` — unstakes both legs (skims AERO), withdraws all liquidity, burns the NFTs, returns all WETH + cbBTC to the Safe, marks the position inactive and zeroes the token ids. No swap.

## Changing the pool (`setPool`)

One contract = one pool, so switching pairs is an explicit, Safe-gated re-registration on an **emptied** contract:

1. Safe `exit(SAFE)` — liquidates and returns principal, and (critically) **zeroes the token ids** so the empty guard passes.
2. Off-chain: acquire the new pair, mint its Slipstream NFT, `safeTransferFrom` it into the balancer.
3. Safe `setPool(newConfig)` — same validation as `registerPosition` (pool/token/tickSpacing cross-checks, oracle probes, gauge reward-token check, NFT ownership). Reverts `NotEmpty` unless `!active && mainTokenId == 0 && altTokenId == 0`. Emits `PoolChanged`.

The compound module reads `token0()/token1()` from the balancer **live**, so a `setPool` re-point automatically re-scopes the compound buy-token check — no module change needed. If the new pair no longer uses AERO/WETH/cbBTC feeds, the checker owner reconfigures the module's price checker accordingly.

## Scope notes

- Phase-1 is **WETH/cbBTC only**, small TVL, correlated pair → minimal IL, proves the no-swap rebalancer + AERO-stake path. MAMO pools stay in `TransferAndEarn`.
- Phase-2 (future, not this runbook): automated cross-pool migration into a higher-performing pair (e.g. MAMO/VVV) via an allowlisted, Chainlink-floored `exit`-and-redeploy path. Requires the §6/§10 safety rails before any automation.
