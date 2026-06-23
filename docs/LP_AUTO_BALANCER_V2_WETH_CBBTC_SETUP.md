# LPAutoBalancerV2 — WETH/cbBTC Phase-1 Setup Runbook

**Status:** Operational runbook (phase-1)
**Audience:** Mamo ops + F-MAMO Safe signers + the backend team running the LLM rebalancer
**Design refs:** `docs/superpowers/specs/2026-06-17-lp-auto-balancer-v2-dual-position-design.md` (contract), `centaur-moonwell` `docs/superpowers/specs/2026-06-17-lp-balancer-agent-design.md` (agent)

This is the step-by-step to stand up the **first** managed position: a **WETH/cbBTC** Aerodrome Slipstream CL position managed by `LPAutoBalancerV2` (no-swap dual-position rebalancer) and driven by the off-chain LLM agent. The three actors and their jobs:

| Actor | Does |
| --- | --- |
| **TransferAndEarn** | Releases underperforming protocol LP back to the Safe (source of capital) |
| **F-MAMO Safe** (`DEFAULT_ADMIN_ROLE`) | Liquidates → WETH+cbBTC, mints the CL position, deposits it into the balancer, registers it, hands the rebalancer key to the backend |
| **Backend / LLM** (`REBALANCER_ROLE`) | After handover: `reset` / `stake` / `unstake` / `claimEmissions` only — never sells, never withdraws to itself |

> **Trust model:** every value-moving action (selling, minting, registering, emergency exit) is the **Safe's**. The backend key can only re-range and stake within on-chain guards and can only route fees/AERO to the configured `feeCollector`. Keep the two strictly separated.

---

## 0. Prerequisites — addresses (Base mainnet, verified on the fork test)

| Thing | Address |
| --- | --- |
| WETH/cbBTC Slipstream CL pool (`tickSpacing = 100`) | `0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1` |
| CL gauge (rewardToken = AERO) | `0x41b2126661C673C2beDd208cC72E85DC51a5320a` |
| **Slipstream NonfungiblePositionManager** (the one the gauge accepts) | `0x827922686190790b37229fd06084350E74485b72` |
| WETH (**token0**) | `0x4200000000000000000000000000000000000006` |
| cbBTC (**token1**) | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| AERO | `0x940181a94A35A4569E4529A3CDfB74e38FD98631` |
| Chainlink ETH/USD (8-dec) | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| Chainlink BTC/USD (8-dec) | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` |
| feeCollector (drop sink) | `DROP_AUTOMATION` (from `addresses/8453.json`) |

> **Two gotchas, both confirmed on-chain:**
> 1. The position manager the **gauge accepts** is `0x827922…`, **not** the `AERODROME_POSITION_MANAGER` in `addresses/8453.json`. Deploy and mint against `0x827922…`.
> 2. Token order is by address: **WETH = token0, cbBTC = token1** (`0x42…` < `0xcb…`). Every `token0`/`token1`/`oracle0`/`oracle1`/`amount0`/`amount1` field follows this order.

---

## Phase 0 — Deploy `LPAutoBalancerV2`

There is no deploy script yet — add `script/DeployLPAutoBalancerV2.s.sol` (mirror an existing deploy script) or deploy via the Safe. Constructor (6 args, **no swap router / no quoter**):

```solidity
new LPAutoBalancerV2(
    admin_           = F_MAMO_SAFE,          // DEFAULT_ADMIN_ROLE
    manager_         = MANAGER_EOA,          // MANAGER_ROLE (bounds tuning within caps); may be address(0)
    rebalancer_      = address(0),           // grant LATER, in Phase C (do NOT wire the backend key at deploy)
    guardian_        = GUARDIAN_EOA_OR_SAFE, // pause()
    positionManager_ = 0x827922686190790b37229fd06084350E74485b72, // Slipstream NFPM
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

All steps are Safe transactions (batch them in one Safe tx / FPS proposal where possible). **Strongly recommended:** encode Phase B as an **FPS proposal script** (`multisig/f-mamo/00X_LPAutoBalancerV2Setup.sol`) with a `validate()` step, and add an FPS test (mirror `ERC20StrategyV2Test`) that runs build → simulate → validate on a fork before signing. Manual sequence below for reference.

### B1. Liquidate the underperforming LP → WETH + cbBTC
Withdraw liquidity from the Phase-A NFTs and swap the proceeds into **WETH + cbBTC** in the ratio you want for the initial position (≈50/50 by value for a centered main). Use the team's preferred venue (Aerodrome router / CoWSwap). This is a deliberate, Safe-reviewed sell — it is the one value-moving swap in the whole flow and is intentionally **off** the rebalancer.

End state: the Safe holds `X` WETH + `Y` cbBTC (small phase-1 size — keep TVL-at-risk low while proving the rebalancer).

### B2. Mint the initial WETH/cbBTC CL position
Mint via the Slipstream NFPM (`0x827922…`), recipient = **Safe**:
- `token0 = WETH`, `token1 = cbBTC`, `tickSpacing = 100`.
- Initial range: centered on current spot, width a multiple of `tickSpacing` and **≥ 2·tickSpacing = 200** (the contract rejects narrower — see B4). A wider initial range (e.g. a few thousand ticks) is fine; the agent re-ranges later.
- `amount0Desired / amount1Desired` = the WETH/cbBTC from B1; set sane `amount{0,1}Min`.

Record the returned `tokenId` → call it `INIT_TOKEN_ID`.

### B3. Deposit the NFT into the balancer
Safe transfers the position NFT into `LPAutoBalancerV2` **via the position manager** (its `onERC721Received` only accepts the NFPM as `msg.sender`):

```
INFPM(0x827922…).safeTransferFrom(SAFE, MAMO_LP_AUTO_BALANCER_V2, INIT_TOKEN_ID)
```

### B4. `registerPosition(config)` — Safe (`DEFAULT_ADMIN_ROLE`)
Call `registerPosition` with the `ManagedPositionV2` config. The contract **validates** the config and reverts if any of these fail — get them right:

- `mainTokenId = INIT_TOKEN_ID` and the NFT is **already held** by the contract (B3 done first).
- `pool = 0x70aCDF…` and **`pool.token0()/token1()/tickSpacing()` must equal** `token0=WETH`, `token1=cbBTC`, `tickSpacing=100` (`PoolMismatch` otherwise).
- `gauge = 0x41b2…` and **`gauge.rewardToken()` must equal `AERO`** (`GaugeRewardMismatch` otherwise).
- `oracle0 = ETH/USD (0x71041d…)`, `oracle1 = BTC/USD (0x64c911…)` — both must return a **fresh, non-zero** answer at call time (within `maxOracleDelay`, default 26h).
- `minWidth ≥ 2·tickSpacing = 200`, `minWidth % 100 == 0`, `maxWidth ≥ minWidth` (`WidthTooNarrow` / `InvalidWidth`).
- `maxRebalanceLossBps ≤ MAX_LOSS_CAP_BPS`, `maxTickDeviation > 0`, `maxCenterDeviation > 0`, `twapWindow > 0`.
- `feeCollector = DROP_AUTOMATION`.

Suggested phase-1 config values (conservative; manager can tune within caps later):

| Field | Value | Note |
| --- | --- | --- |
| `pool` | `0x70aCDF…` | WETH/cbBTC |
| `token0 / token1` | WETH / cbBTC | address order |
| `tickSpacing` | `100` | |
| `gauge` | `0x41b2…` | rewardToken == AERO |
| `feeCollector` | `DROP_AUTOMATION` | drop sink |
| `oracle0 / oracle1` | ETH/USD / BTC/USD | 8-dec feeds |
| `minWidth` | `200` | = 2·tickSpacing (floor) |
| `maxWidth` | e.g. `20000` | operator choice |
| `maxCenterDeviation` | e.g. `200` | backstop on center |
| `twapWindow` | e.g. `1800` (30m) | calm gate + value-floor fallback; confirm pool oracle cardinality covers it |
| `maxTickDeviation` | e.g. `100` | calm gate; correlated pair → tight |
| `maxRebalanceLossBps` | e.g. `100` (1%) | no-swap → sanity guard; small headroom is enough |
| `minRebalanceInterval` | e.g. `21600` (6h) | matches the agent's sweep cadence; **set > 0** so a buggy agent can't loop resets |
| `mainTokenId` | `INIT_TOKEN_ID` | held NFT |
| `altTokenId / mainStaked / altStaked / lastRebalance / active` | `0 / false / false / 0 / false` | **forced** by `_store` — values you pass are ignored |

`registerPosition` returns `slotId` (the first one is `0`). Record it as `MAMO_LP_SLOT_ID`.

### B5. AERO routing in DropAutomation
Confirm **AERO is whitelisted in `DropAutomation`'s swap config** so claimed emissions get swapped into the drop. If not, add it (Safe). Without this, AERO reaches the feeCollector but isn't converted.

> **Do not stake at setup.** Whether to gauge-stake (farm AERO) vs stay unstaked (fees) is the agent's per-pair decision (`stake` is `REBALANCER_ROLE`). Leave it unstaked; the backend stakes if/when its APR comparison says to.

Output of Phase B: a registered, **unstaked** WETH/cbBTC position in the balancer at `slotId`, fees/AERO wired to the drop. No hot key exists yet.

---

## Phase C — Handover to the LLM backend

### C1. Grant the rebalancer key
Safe grants `REBALANCER_ROLE` to the backend's **signer EOA** (the key the sandboxed agent uses for `cast send`):

```
lpAutoBalancerV2.grantRole(REBALANCER_ROLE, BACKEND_REBALANCER_EOA)
```

`REBALANCER_ROLE = keccak256("REBALANCER_ROLE")`. This EOA can call only `reset` / `stake` / `unstake` / `claimEmissions` — no custody, no config, value only to `feeCollector`.

### C2. Configure the backend (`centaur-moonwell` `lp_balancer_sweep` workflow)
Set the env the agent reads (see the agent spec / Plan B):

| Env | Value |
| --- | --- |
| `MOONWELL_LP_AUTO_BALANCER` | deployed `LPAutoBalancerV2` address |
| `MOONWELL_LP_SLOT_ID` | the `slotId` from B4 (e.g. `0`) |
| `MOONWELL_LP_RPC_URL` | Base RPC (the gate's `eth_call` + the agent's `cast` use it) |
| `MOONWELL_LP_HYSTERESIS_BPS` | e.g. `200` (stake/unstake anti-flap) |
| `MOONWELL_LP_MAX_TURNS` | e.g. `3` |
| `MOONWELL_LP_MAX_UNSWEPT_AERO` | dust threshold for the "no unswept AERO" goal clause |

Provision the `BACKEND_REBALANCER_EOA` private key **inside the sandbox** (the workflow layer never holds it). The completion gate reads `getDecisionSnapshot(slotId)` over JSON-RPC; the agent acts via `cast send`.

### C3. Verify before go-live
- **Read path:** call `getDecisionSnapshot(slotId)` — confirm `mainInRange`, `hasGauge == true`, `mainStaked == false`, `cooldownRemaining`, `deviationGateOpen` look right.
- **Dry run:** on a fork (or testnet), have the backend run one sweep turn end-to-end — confirm a `reset` lands, `Reset` event fires, fees/AERO route to `DropAutomation`, and the gate's independent re-read agrees with the agent's report.
- **Guards live:** confirm cooldown blocks a too-soon second reset; confirm the calm gate (`maxTickDeviation`) and value floor are active.
- **Market gather:** note that the stake/unstake decision stays dormant until the LpSugar/DefiLlama APR gather is wired in the workflow (logged follow-up). Until then phase-1 runs **reset-only** safely.

### C4. Go live
Enable the `lp_balancer_sweep` cron (default every 6h, matching `minRebalanceInterval`). Monitor the first few sweeps.

---

## Verification checklist (post-setup)

- [ ] `LPAutoBalancerV2` deployed; admin = Safe, guardian set, rebalancer = backend EOA, manager optional.
- [ ] Position NFT held by the contract; `slotId` registered and `active`.
- [ ] `registerPosition` passed all validations (pool/token/tickSpacing match, gauge reward = AERO, oracles fresh, `minWidth ≥ 200`).
- [ ] `feeCollector == DROP_AUTOMATION`; AERO whitelisted in DropAutomation swaps.
- [ ] `minRebalanceInterval > 0`.
- [ ] Backend can read `getDecisionSnapshot` and execute a guarded `reset`; gate re-reads chain independently.
- [ ] Small phase-1 TVL.

## Emergency / rollback (Safe + guardian)

- **Pause:** guardian calls `pause()` — blocks `reset`/`stake`/`unstake`/`claimEmissions` (not `exit`).
- **Revoke the key:** Safe `revokeRole(REBALANCER_ROLE, BACKEND_REBALANCER_EOA)` — instantly stops the backend.
- **Full teardown:** Safe `exit(slotId, SAFE)` — unstakes both legs (skims AERO), withdraws all liquidity, burns the NFTs, returns all WETH + cbBTC to the Safe, marks the slot inactive. No swap.

## Scope notes

- Phase-1 is **WETH/cbBTC only**, small TVL, correlated pair → minimal IL, proves the no-swap rebalancer + AERO-stake path. MAMO pools stay in `TransferAndEarn`.
- Phase-2 (future, not this runbook): automated cross-pool migration into a higher-performing pair (e.g. MAMO/VVV) via an allowlisted, Chainlink-floored `exit`-and-redeploy path. Requires the §6/§10 safety rails before any automation.
