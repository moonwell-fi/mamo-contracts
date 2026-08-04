# Mamo on Robinhood Chain — Keeper & Automation Specification

*Target repo: `moonwell-tenderly` (Tenderly Web3 Actions). Companion to `docs/ROBINHOOD_CHAIN_SPEC.md` (chain facts, oracle-guard design) and `docs/ROBINHOOD_PLAN.md` (build plan). Written for a backend engineer who has not worked on the Robinhood Chain port. Contract behaviour cited here was read from `src/robinhood/` at branch `claude/mamo-robinhood-chain-04xxwe`; chain facts were verified on-chain 2026-08-04.*

---

## 0. Why this document exists

Robinhood Chain (id **4663**) has **no keeper infrastructure at all**. Full-history event scans over all ~27.7M blocks on 2026-08-04 found:

- **Chainlink Automation: absent.** Zero `UpkeepRegistered` / `UpkeepPerformed` / OCR2 registry events, ever.
- **Gelato: absent.** Every canonical Gelato address is empty code.
- **No sequencer-uptime feed.** The standard L2 liveness primitive does not exist on this chain.

Every recurring duty in the Mamo Robinhood product — rebalancing baskets, building positions, compounding rewards, watching venues, watching oracles, watching the issuer — is therefore **Mamo backend infrastructure**. There is no third party to delegate it to and no "someone else's keeper will do it" fallback. If a duty in this document is not built, it does not happen.

A second, sharper reason: **the on-chain oracle guard is deliberately coarse, so the keeper is the primary market-hours control.** The equity staleness bound that lets the sleeve keep working through weekends (26h, mirroring `test/RobinhoodBasketFork.integration.t.sol`) also means that from Friday ~21:00 UTC until Saturday ~23:00 UTC the contract will happily execute an equity trade against **Friday's closing price**. The contract cannot tell the difference. The keeper can, and must. See §4 / A1.

**Scope.** Off-chain automation only. No contract changes are specified here; §11 lists what the contracts team owes this work and what we would like changed.

---

## 1. Chain facts the automation is built on

Verified on-chain 2026-08-04 unless noted. These are load-bearing — most of them break a naive implementation.

| Fact | Consequence for the keeper |
|---|---|
| RPC `https://rpc.mainnet.chain.robinhood.com`, chain id **4663**, ~**100ms blocks** (~864,000 blocks/day) | Never scan logs by "last N blocks" intuitions from Ethereum. Chunk `eth_getLogs`, always filter by address + topic0, checkpoint by block. |
| Solidity `block.number` returns the **L1 (Ethereum)** block number. `ArbSys` (`0x…0064`) `arbBlockNumber()` returns L2 height. JSON-RPC block numbers (`eth_blockNumber`, `eth_getLogs`) are **L2**. | Never compare a block number read from a contract/emitted in an event with a JSON-RPC block number. Do all time math on **timestamps**, taken from the chain head, not the worker's wall clock. |
| RPC **rate-limits with HTTP 429** | Every RPC client needs exponential backoff + jitter + a per-action request budget. Batch reads through **Multicall3** (deployed) — one `eth_call` instead of forty. |
| Node **prunes deep historical state (~100k blocks ≈ 2.8 hours)** | Historical `eth_call` (including QuoterV2 re-quotes) fails beyond the window. **Execution-quality data must be captured pre-trade by the executor, not reconstructed later** (§4 / A10). Persist all events into your own store; do not treat the node as an archive. |
| ETH gas; chain gas subsidy expires ~**2026-09-29** | Keeper EOA holds ETH on 4663. Monitor its balance. Re-derive per-rebalance economics after the subsidy ends. |
| **Merkl** is the rewards layer: Distributor `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`, merkle root updates ~daily with a **dispute window** | Claim automation must respect the dispute window and cross-check the API-served root against the on-chain root. |
| Uniswap **SwapRouter02** `0xCaf681a66D020601342297493863E78C959E5cb2`, **QuoterV2** `0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7` | QuoterV2 is **state-mutating by design** (it reverts and decodes revert data) — call it with `eth_call`, not as a `view`, and never in a signed tx. Size every trade with it before sending. |
| Steakhouse USDG Vault V2 `0xBeEff033F34C046626B8D0A041844C5d1A5409dd`; all four gates currently `address(0)`; **`maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem` always return 0 by design** | Never read positions or capacity from `max*`. Position = `convertToAssets(balanceOf(strategy))`. Interest accrues at most **once per transaction**; vault balance ≠ yield (donations are invisible until an allocator sets `maxRate`). |
| USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, **6 decimals**, Paxos proxy, has EIP-2612 permit | All USDG amounts in this document are 6dp. Stock tokens are **18dp**. Feeds are **8dp**. Get the scaling right once, in one library. |
| Stock tokens are 18dp ERC-20s with `uiMultiplier()` (ERC-8056). **The Chainlink feed price already includes the multiplier.** CRWD `0xea72…` shows a live `4e18` (4:1 split). | **Never multiply a NAV by `uiMultiplier()`.** This is the single most expensive accounting bug available on this chain. |
| Issuer **AccessControlsRegistry** (address TBD) can blocklist contract addresses in one transaction | A9 exists. Obtain the address; until then, probe by simulation. |
| **31 decoy "dividends.finance" aggregators** exist with plausible descriptions and no round history | **Never auto-discover feeds by description or symbol.** The feed map is reviewed config. Same rule for tokens: identify genuine issues by the `… • Robinhood Token` name suffix, never by symbol. |
| Every documented feed address is a **raw aggregator, not a consumer proxy** | Once proxies are obtained from the Chainlink docs directory, read through proxies and **alert if the aggregator behind a proxy changes** (feed-rotation detection, A6). |

### 1.1 Feed calendar (the thing everything else keys off)

| Class | Address(es) | Cadence observed | Implication |
|---|---|---|---|
| **USDG/USD** | `0x8beee3503f6860d5dac4ce26b5eee92982951c2e` | **Strict 24h heartbeat**, zero deviation-triggered updates in 59 days, **updates through weekends** | A missed beat at ~25h is an incident. Staleness bound 26–27h. A generic 1h bound bricks the whole chassis. |
| **Equities** (35 feeds: 28 single names + 7 ETF/commodity) | AAPL `0xbb11a212…`, NVDA `0xc9d16e4f…`, TSLA `0x7a6b81ba…`, … | **Mon 00:00 UTC → Fri ~21:00–23:35 UTC**, ~20–30 min median intraweek (incl. overnight). **~50h weekend freeze; holidays freeze too (July 4 ≈ 80h).** | 24/5 **crypto-style** calendar, **not NYSE sessions**. A guard hardcoded to 13:30–20:00 UTC would halt during live overnight trading. |
| **ETH/USD** | `0x6091e64eb7138eef066a80fd3a0d7427b91f2721` | 24/7, ~44 min median | The **liveness proxy** standing in for the missing sequencer-uptime feed. |

`AnswerUpdated` topic0 = `0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f`.

**Market-open detection MUST be derived from feed `updatedAt` freshness. Never from a hardcoded exchange calendar.** The calendar is used only to *classify anomalies* (§4 / A1), never to gate trading.

### 1.2 Liquidity constraints (live QuoterV2, 2026-08-04)

Largest single trade under **100 bps** total slippage, v3+v4 combined:

| Name | Cap (100bps) | Name | Cap (100bps) |
|---|---|---|---|
| NVDA | ~$170k | SPCX | ~$20k |
| AAPL | ~$60k | GOOGL | ~$20k |
| SPY | ~$34k | TSLA | ~$16k |
| | | QQQ | ~$4k |
| **GME, SLV** | **$0** — 1%-fee-tier-only liquidity; the fee alone eats the 100bps budget | | |

Measured round-trip cost **26 bps at $2k scale** (three-leg basket, 45% equity). Basket construction absorbs only **~$100–200k per execution** — larger builds must be TWAP'd. **Composition is a capacity decision.**

---

## 2. Contract surfaces the keeper drives

Read these before writing code: `src/robinhood/StockBasketStrategy.sol`, `src/robinhood/MorphoVaultsStrategy.sol`, `src/robinhood/MamoVaultConfig.sol`.

### 2.1 Access control — one address, one nonce lane

`onlyBackend` on both strategies is:

```solidity
require(msg.sender == mamoStrategyRegistry.getBackendAddress(), "Not backend");
```

and `MamoStrategyRegistry.getBackendAddress()` returns **`getRoleMember(BACKEND_ROLE, 0)`** — the *first* member of the role. Consequences the dev must design around:

1. **Exactly one address can drive strategies at any time.** Granting `BACKEND_ROLE` to a second address does *not* give it strategy rights; it only gains registry functions gated by `onlyRole(BACKEND_ROLE)`. Role-member **ordering** matters; key rotation must be sequenced by the admin multisig and verified by reading `getBackendAddress()` afterwards.
2. **All strategy writes share one nonce lane.** The executor must serialize sends (a global advisory lock keyed on the backend address) or manage nonces explicitly with a single writer. Two actions sending concurrently will collide.
3. **Batching requires the batcher to *be* the backend.** The repo's `src/Multicall.sol` (Ownable, `multicall(Call[])`) is exactly that pattern on Base: the Multicall contract is `BACKEND_ROLE` member 0 and the keeper EOA owns it. **Routing `onlyBackend` calls through the canonical Multicall3 breaks them** (`msg.sender` becomes Multicall3). Multicall3 is for **reads only**.

Throughput planning: with one nonce lane at ~100ms blocks, per-tx latency is not the constraint — serialization is. Batch aggressively through the Mamo Multicall once it is deployed on 4663.

### 2.2 `StockBasketStrategy` (baskets)

| Function | Caller | Notes |
|---|---|---|
| `deposit(uint256)` | permissionless | Lands **entirely in the ERC-4626 sleeve**. Never buys stock. Emits `Deposit(address,uint256)`. |
| `withdraw(uint256)` / `withdrawAll()` | owner | Drains idle → sleeve → sells stock pro-rata. Sales are oracle-bounded, so they revert when equity feeds are stale. |
| `rebalance(uint256 minTradeValue)` | **backend** | Two passes over **all** legs in one tx. Emits `Rebalanced(navBefore,navAfter)`, `StockSold`, `StockBought`. |
| `setStockWeights(uint256[])` | **backend** | Must satisfy `sum(weights) <= maxTotalStockBps`. **Does not need to sum to 10000.** Emits `WeightsUpdated`. |
| `setSlippage(uint256)` | owner | ≤ `MAX_SLIPPAGE_IN_BPS` (2500). Not a keeper lever. |
| Views | — | `getBasket() → (address[],uint256[])`, `getTotalBalance()`, `stockWeightsBps(i)`, `maxTotalStockBps()`, `poolFee()`, `allowedSlippageInBps()` |

**Three structural facts that shape A2/A3:**

- **`minTradeValue` is a floor, not a cap.** `rebalance` sizes each leg to close the *entire* gap between current and target value. There is no way to ask the contract for a partial move. **The only way to bound trade size is to move the target: set intermediate weights with `setStockWeights`, rebalance, then ratchet.** This is the "weight ladder" in A2/A3.
- **One `poolFee` for the whole basket**, fixed at initialization. Every constituent must have real liquidity in that tier. GME/SLV-class names (1%-tier-only) cannot be in a 0.30% basket at all.
- **`getTotalBalance()` reverts when any constituent's feed is stale** (it prices through `SlippagePriceChecker.getExpectedOut`). An `eth_call` revert on `getTotalBalance()` is therefore a *signal*, not an error — treat it as "equity pricing unavailable" and fall back to component-wise NAV from raw feeds for reporting.

### 2.3 `MorphoVaultsStrategy` (USDG chassis)

| Function | Caller | Notes |
|---|---|---|
| `deposit(uint256)` | permissionless | Calls `vaultConfig.recordDeposit` → **metered against the family supply cap**; reverts `"Supply cap exceeded"` at the cap. |
| `depositIdleTokens()` | permissionless | Sweeps idle (compounded) balance into vaults, **not** metered. Safe for anyone, including the keeper, to call. |
| `withdraw` / `withdrawAll` | owner | Full exit calls `recordFullExit()` (frees the whole tracked principal — by design, see §2.4). |
| `updatePosition(address[],uint256[])` | **backend** | **Redeems from every current vault, then re-deposits per new weights.** New weights must sum to exactly `SPLIT_TOTAL` (10000) and every vault must be allowlisted. Emits `PositionUpdated`. |
| `claimRewards(address[],uint256[],bytes32[][])` | **backend** | Calls the distributor with `accounts[i] = address(this)` — the strategy is both `msg.sender` and the claim account, so **no Merkl `toggleOperator` grant is needed for this path** (verify against the live distributor ABI before launch; an operator grant is only required if the backend ever claims *directly*). |
| `compoundRewards(address rewardToken, uint24 poolFee, uint256 backendMinOut)` | **backend** | Two-sided floor: effective `amountOutMinimum = max(backendMinOut, oracleFloor)`. Reverts if `!slippagePriceChecker.isRewardToken(rewardToken)`. Skims `compoundFee` to `feeRecipient`, redeposits the rest. Emits `RewardsCompounded`. |
| `setFeeRecipient(address)` | **backend** | Ops action, not automated. |

**`updatePosition` traps:**

- It is a **full round trip through every vault**. ERC-4626 rounds down twice, and Vault V2 accrues interest **once per transaction** — so each call costs a few units of rounding. Do not call it more often than the position change justifies.
- If **any** current vault has a `sendSharesGate` / `sendAssetsGate` set, `_redeemAllFromVaults()` reverts and **`updatePosition` reverts entirely — including for the ungated vaults.** There is no on-chain escape once a gate is live on a funded venue. A5 is therefore a **preventive** monitor, not a remediation one.
- Removing a vault from the allowlist blocks *new* allocations; existing funds stay redeemable, and `updatePosition` to a set that excludes it still redeems from it (the loop iterates the *current* set). That is the rotation path.

### 2.4 `MamoVaultConfig` (allowlist + supply cap)

Events: `VaultAdded(address)`, `VaultRemoved(address)`, `SupplyCapUpdated(uint256 old,uint256 new)`, `DepositRecorded(address strategy,uint256 amount,uint256 totalDeposited)`, `WithdrawRecorded(address strategy,uint256 amount,uint256 totalDeposited)`.
Views: `supplyCap()`, `totalDeposited()`, `remainingCapacity()`, `trackedDeposits(address)`, `isAllowedVault(address)`, `getVaults()`.

- `recordWithdraw` **clamps down** to the strategy's tracked principal, so yield withdrawals cannot free more capacity than the strategy consumed.
- `recordFullExit()` frees the **whole** tracked principal even though realized assets round slightly below it. **This is intentional** (without it, residue accumulates in `totalDeposited` forever). Reconciliation (A10) must not flag it as a bug — see §4 / A10 for the exact invariant.
- **`StockBasketStrategy` is NOT wired to `MamoVaultConfig`.** Baskets have no supply-cap metering; their only on-chain bound is `maxTotalStockBps`. Basket capacity control is currently a factory/front-end concern — see §11.

### 2.5 Event catalogue for indexing

Compute topic0 with `cast sig-event '<signature>'`; do not hand-copy hashes.

| Contract | Event | Use |
|---|---|---|
| `StockBasketStrategy` | `Deposit(address,uint256)` | A3 trigger |
| | `Withdraw(address,uint256)` | A10 |
| | `Rebalanced(uint256,uint256)` | A2 cost accounting |
| | `StockSold(address indexed,uint256,uint256)` / `StockBought(address indexed,uint256,uint256)` | A10 execution quality |
| | `WeightsUpdated(uint256[])` | ladder state reconciliation |
| `MorphoVaultsStrategy` | `Deposit(address,uint256)` / `DepositIdle` / `Withdraw` | A10 |
| | `PositionUpdated(address[],uint256[])` | A5 / A10 |
| | `RewardsClaimed(address[],uint256[])` / `RewardsCompounded(address indexed,uint256,uint256,uint256)` | A4 |
| `MamoVaultConfig` | `DepositRecorded` / `WithdrawRecorded` | A8 trigger |
| | `VaultAdded` / `VaultRemoved` / `SupplyCapUpdated` | A5 / A8 config drift |
| `MamoStrategyRegistry` | `StrategyAdded(address indexed user,address strategy,address implementation)` | A0 discovery |

⚠️ **`Deposit(address,uint256)` has an identical signature on both strategy types.** Disambiguate by **contract address** against the strategy inventory, never by topic0 alone.

---

## 3. Architecture

### 3.1 Topology

```
                    ┌──────────────────────────────────────────────┐
   cron ~60s ──────▶│ A1  Market-State Service                     │──┐
                    └──────────────────────────────────────────────┘  │ publishes
                    ┌──────────────────────────────────────────────┐  │ market_state
   cron ~5m  ──────▶│ A6  Feed Health Monitor  (shares A1's reads) │──┘ (KV, TTL 90s)
                    └──────────────────────────────────────────────┘
                                          │ consumed by
        ┌─────────────────────────────────┴───────────────────────────────┐
        ▼                                                                 ▼
┌───────────────────────────────┐                          ┌──────────────────────────┐
│ ALLOCATION ENGINE  (single    │  ← A3 deposit jobs        │ A4 Compound Keeper       │
│ writer, one nonce lane)       │  ← A2 drift jobs          │ A7 Corporate Actions     │
│  · ladder state machine       │  ← A7 blackouts           │ A5 Vault/Venue Monitor   │
│  · QuoterV2 pre-flight        │                           │ A8 Capacity Monitor      │
│  · simulate → sign → send     │                           │ A9 Blocklist Watch       │
└───────────────┬───────────────┘                           └────────────┬─────────────┘
                │                                                        │
                ▼                                                        ▼
        ┌───────────────────────────────────────────────────────────────────┐
        │ SHARED: RPC client (backoff/batch) · signer (KMS) · indexer/store  │
        │ · alerting (severity → channel) · A0 strategy inventory            │
        └───────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                             A10  Reconciliation & Reporting (daily)
```

**Single-writer rule.** A2, A3 and A4 all send `onlyBackend` transactions from the same address. They must be behind **one executor** with one lock and one nonce source. Treat them as job *producers* feeding a shared *sender*, not as three independent senders.

### 3.2 Shared services (build these first)

| Service | Requirements |
|---|---|
| **RPC client** | Exponential backoff with jitter on 429/5xx; per-invocation request budget; batch all reads through **Multicall3 `aggregate3`**; a `headBlock()` helper returning `{l2Number (eth_blockNumber), timestamp}`; refuse historical `eth_call` older than the pruning window with a clear error. |
| **Signer** | One dedicated backend EOA. Key in KMS/HSM (AWS KMS secp256k1, Turnkey, or Fireblocks) — never raw hex in an action's environment if avoidable. Global nonce lock. Pre-send **simulation is mandatory** (`eth_call` with `from` = backend, or Tenderly Simulation API if 4663 is supported). Per-tx gas ceiling; per-day tx budget; kill switch. |
| **Store / indexer** | Persist every event in §2.5 with `{l2BlockNumber, txHash, logIndex, blockTimestamp}` and a monotonic checkpoint. **Do not rely on the node for history** (pruning). Also stores ladder state, pre-trade quotes, market-state history, alert dedupe keys. |
| **Alerting** | Severity taxonomy in §6, routed by channel. Dedupe by `(action, subject, severity)` with a cooldown; escalate on repeat. Every alert carries a runbook link. |
| **Config loader** | Loads the addresses file, feed map, per-basket params, thresholds (§10). **All addresses are reviewed config; nothing is auto-discovered.** Fails closed on a missing key. |
| **A0 strategy inventory** | See below. |

### 3.3 A0 — Strategy discovery & inventory sync — **PRIORITY: P0**

Factories are not built yet. Spec the discovery mechanism now so nothing else hardcodes a list.

- **Primary (once factories land):** subscribe to the factory's strategy-creation event and to `MamoStrategyRegistry.StrategyAdded(address indexed user, address strategy, address implementation)`. Cron every 5 min: scan from the last checkpoint, upsert into the inventory.
- **Interim (pre-factory):** the inventory is a **config file** (`strategies.json`) of `{address, type, owner, strategyTypeId, basketId|configAddress, enabled}` plus a cron reconciliation against `registry.getUserStrategies(user)` for known users.
- **Per record, cached and refreshed hourly:** type (basket vs chassis), `getBasket()` / `getAllocations()`, `poolFee()`, `allowedSlippageInBps()`, `maxTotalStockBps()`, `vaultConfig()`, owner, and an `automation_enabled` flag (the per-strategy kill switch).
- **Guards:** an address in the inventory whose `strategyTypeId` or implementation does not match the approved set is **disabled and alerted**, never driven. A strategy discovered on-chain that is not in config is alerted (**WARN**) and left disabled until reviewed — discovery informs ops, it does not auto-enrol funds into automation.
- **Failure:** discovery outage ⇒ operate on the last known inventory; alert if the checkpoint is older than 1h.

---

## 4. The automations

Every spec below uses the same schema: **Priority · Trigger · Reads · Decision logic · Emits · Guards · Failure handling · Parameters**.

Inventory at a glance:

| ID | Automation | Priority | Trigger | Writes tx? |
|---|---|---|---|---|
| A0 | Strategy discovery & inventory sync | **P0** | cron 5m + events | no |
| A1 | Market-hours oracle service | **P0** | cron 60s | no |
| A2 | Rebalance scheduler | **P0** | cron 5m (open only) | **yes** |
| A3 | Basket construction TWAP executor | **P0** | `Deposit` event + cron 5m | **yes** |
| A4 | Compound keeper (Merkl claim + compound) | P1 | cron daily + 6h check | **yes** |
| A5 | Vault gate & venue monitor | **P0** | cron 5m + vault events | no (alert + suggested tx) |
| A6 | Feed health monitor | **P0** | cron 5m | no |
| A7 | Corporate-action monitor | P1 | cron 1h | no (publishes blackouts) |
| A8 | Supply-cap capacity monitor | P1 | events + cron 15m | no |
| A9 | Issuer blocklist watch | **P0** | cron 15m (events when registry known) | no |
| A10 | Reconciliation & reporting | P1 | cron daily 02:00 UTC | no |

---

### A1 — Market-hours oracle service — **PRIORITY: P0**

The single source of truth for "may we touch equities right now". Everything else consumes it; nothing else re-derives it.

**Trigger.** Cron, every **60s**.

**Reads** (one Multicall3 `aggregate3`, plus one `eth_getBlockByNumber('latest')`):
- `latestRoundData()` on every configured **equity** aggregator in the active universe (union of constituents across enabled baskets — typically 3–12, capped at the 35 that exist).
- `latestRoundData()` on **USDG/USD** and **ETH/USD**.
- Chain head `{number, timestamp}`.

**Decision logic.**

```
now        := headBlock.timestamp            # NEVER the worker's wall clock
age(f)     := max(0, now - f.updatedAt)
maxAge     := max over equity feeds of age(f)
minAge     := min over equity feeds of age(f)

phase :=
  OPEN      if maxAge <= EQUITY_FRESH_MAX          (default 90 min)
  UNCERTAIN if EQUITY_FRESH_MAX < maxAge <= EQUITY_STALE_MAX   (default 26h)
  CLOSED    if maxAge > EQUITY_STALE_MAX

split := (maxAge - minAge) > FEED_SPLIT_DELTA      (default 4h)   # one name's feed died alone
tradeWindowOpen := (phase == OPEN) and not split and not chainLivenessSuspect
```

- **`UNCERTAIN` is the weekend trap.** Between the Friday freeze and +26h the contract's guard still passes, so `tradeWindowOpen` MUST be false here. This is the whole reason A1 is P0.
- **`split`**: if some equity feeds are fresh and one is far behind, mark that *constituent* untradeable (`perFeed[i].tradeable = false`) and set `tradeWindowOpen = false` for any basket containing it, while leaving other baskets open.
- **Chain liveness (sequencer-uptime substitute):** `chainLivenessSuspect` if `age(ETH/USD) > ETH_LIVENESS_MAX` (default 3h; median cadence is ~44 min) **or** `now` lags the worker clock by more than `HEAD_LAG_MAX` (default 120s).
- **Anomaly classification** uses an *advisory* calendar (Mon 00:00 UTC → Fri 21:00 UTC, plus a holiday list) purely to decide whether a phase is surprising:

| Observation | Advisory calendar says | Alert |
|---|---|---|
| `phase == OPEN` | closed (weekend/holiday) | **WARN** — "equity feeds fresh outside the expected window"; do **not** block trading on this alone (the calendar is not authoritative), but require human ack before the first trade in that window. |
| `phase == UNCERTAIN/CLOSED` | open (mid-week) | **CRIT** — feed freeze during trading hours. Trading already halted by the freshness rule; this is an incident. |
| `split == true` | any | **WARN** (single-name feed outage), **CRIT** if it persists > 2h during the open window. |
| `chainLivenessSuspect` | any | **CRIT** — halt everything (see Guards). |

**Emits.** No transactions. Publishes `market_state` to the shared KV with a **90s TTL**:

```json
{ "ts": 1785000000, "headL2": 27712345, "headTs": 1785000000,
  "phase": "OPEN", "tradeWindowOpen": true, "split": false,
  "chainLivenessSuspect": false, "staleState": false,
  "perFeed": [{ "token":"0xd060…", "feed":"0xc9d1…", "answer":"12345678900",
                "updatedAt":1784999100, "ageSec":900, "tradeable":true }],
  "usdg": {"answer":"100010000","ageSec":3400}, "eth": {"ageSec":1900},
  "anomalies": [] }
```

**Guards.**
- Ages are computed from the **chain head timestamp**, never `Date.now()`.
- If any equity feed returns `answer <= 0` or `updatedAt == 0` → that feed is untradeable, **CRIT**.
- Never use the calendar as a trading gate.

**Failure handling.** On RPC failure, retain the previous record and set `staleState: true`. **Consumers fail closed:** any consumer that reads a record with `staleState == true` or `age > MARKET_STATE_MAX_AGE` (default 5 min) must treat the market as **closed** and take no trading action. Three consecutive failed cycles → **CRIT** (RPC outage).

**Parameters.** `EQUITY_FRESH_MAX`, `EQUITY_STALE_MAX`, `FEED_SPLIT_DELTA`, `ETH_LIVENESS_MAX`, `HEAD_LAG_MAX`, `MARKET_STATE_MAX_AGE` — §10.

---

### A2 — Rebalance scheduler — **PRIORITY: P0**

**Trigger.** Cron every **5 min**, executing only when `market_state.tradeWindowOpen == true`.

**Reads** (batched via Multicall3, per enabled basket strategy):
- `getBasket()` → `(stockTokens[], stockWeightsBps[])`; `maxTotalStockBps()`, `poolFee()`, `allowedSlippageInBps()`.
- `balanceOf(strategy)` for each constituent; sleeve `convertToAssets(balanceOf(strategy))`; idle `USDG.balanceOf(strategy)`.
- Oracle prices from `market_state` (do **not** re-read feeds).
- Local state: last rebalance timestamp, ladder state, rolling cost budget, per-strategy kill switch.

**Decision logic — mirror the contract exactly.**

```
NAV      = idle + sleeveAssets + Σ_i value_i        # value_i = oracle value of leg i, 6dp USDG
target_i = NAV * W_i / 10000                        # W_i = FINAL target weights
gap_i    = target_i - value_i                       # >0 underweight (buy), <0 overweight (sell)
```

Fire only when **all** of:
1. `NAV >= MIN_NAV` (default 250e6 = $250) — dust baskets are not worth gas or spread.
2. `max_i |gap_i| / NAV >= DRIFT_BAND_BPS` (default **500**), **or** `now - lastRebalance > MAX_REBALANCE_INTERVAL` (default 7d) **and** `max_i |gap_i| / NAV >= DRIFT_FLOOR_BPS` (default 200).
3. `now - lastRebalance >= REBALANCE_COOLDOWN` (default 30 min) and today's tx count for this strategy `< DAILY_REBALANCE_BUDGET` (default 6).
4. No constituent is under a corporate-action blackout (A7) or marked untradeable by A1.

**Capacity sizing and the weight ladder.** For each leg, the notional it will trade is `|gap_i|`. Cap it:

```
clip_i = min( CAP_i * CAP_SAFETY_FACTOR , GLOBAL_CLIP )     # CAP_i from §1.2, factor default 0.5
s      = min(1, min over legs with gap_i != 0 of clip_i / |gap_i|)
```

If `s == 1`, call `rebalance(minTradeValue)` directly. If `s < 1`, **you cannot ask the contract for a partial move** — `minTradeValue` is a floor, not a cap. Instead ladder the target:

```
w_current_i = value_i * 10000 / NAV
W_int_i     = round( w_current_i + s * (W_i - w_current_i) )
assert Σ W_int_i <= maxTotalStockBps            # contract requirement; weights need NOT sum to 10000
tx1: setStockWeights(W_int)
tx2: rebalance(minTradeValue)
# next tick: recompute s against the FINAL weights and repeat until W_int == W
```

Ladder state `{strategy, finalWeights, step, startedAt, expiresAt}` is persisted so a crash cannot strand a basket at intermediate weights. **Alert WARN if a basket sits mid-ladder longer than `LADDER_MAX_AGE` (default 24 trading hours)**, and always restore the final weights when the ladder completes.

**QuoterV2 pre-flight (mandatory).** For every leg that will trade, at the strategy's configured `poolFee`:

```
quoted   = QuoterV2.quoteExactInputSingle(tokenIn, tokenOut, amountIn, poolFee, 0)   # eth_call
expected = oracle expected out for amountIn
minOut   = expected * (10000 - allowedSlippageInBps) / 10000        # what the contract will enforce
require quoted >= minOut * (10000 + PREFLIGHT_MARGIN_BPS) / 10000   # default margin 20 bps
```

If any leg fails, **do not send** — the tx would revert with `"Too little received"` and burn a nonce. Reduce `s` (halve the clip) and retry next tick; after `PREFLIGHT_FAIL_STREAK` (default 6) consecutive failures on the same leg, **WARN**: pool is persistently off-oracle.

**Store the pre-flight quote** (`{txHash-to-be, strategy, leg, amountIn, quoted, expected, poolFee, headL2, headTs}`) — A10 cannot reconstruct it later because of state pruning.

`minTradeValue` = `max(MIN_TRADE_VALUE_ABS (default 10e6 = $10), NAV * MIN_TRADE_VALUE_BPS / 10000 (default 25 bps))`. It exists only to suppress dust legs.

**Emits.**
- `setStockWeights(uint256[])` (ladder steps only) then `rebalance(uint256)` from the backend address, serialized through the shared sender, simulated first.
- Post-confirmation: parse `Rebalanced(navBefore, navAfter)`; `costBps = (navBefore - navAfter) * 10000 / navBefore`.

| `costBps` | Action |
|---|---|
| ≤ `REBALANCE_COST_WARN_BPS` (default 100) | record only |
| > 100 | **WARN** + record |
| > `REBALANCE_COST_HALT_BPS` (default 300) | **CRIT** + **auto-disable this strategy's automation** (circuit breaker), requires human re-enable |

Rolling 30-day realized cost per basket > `MONTHLY_COST_BUDGET_BPS` (default 150) → **WARN** to product (drift band is too tight or capacity is too small).

**Guards.** `tradeWindowOpen`; market_state fresh; strategy enabled; no in-flight tx for this strategy; keeper ETH balance ≥ `MIN_KEEPER_ETH`; cooldown and daily budget; equity share after the move must satisfy `Σ W_int <= maxTotalStockBps` (the contract enforces it — a revert here means a ladder bug, treat as CRIT).

**Failure handling — classify the revert reason, never blind-retry:**

| Revert | Meaning | Action |
|---|---|---|
| `"Too little received"` | pool below the oracle-derived `minOut` | expected; halve clip, retry next tick; streak → WARN |
| `"Oracle price is stale"` (or `getTotalBalance()` reverting) | equity feeds frozen | mark CLOSED locally, defer, reconcile with A1 (**A1 disagreeing with the contract is itself a CRIT** — the bounds are out of sync) |
| `"Stock allocation exceeds mandate"` | ladder computed weights above `maxTotalStockBps` | **CRIT**, disable strategy, bug |
| `"Nothing to rebalance"` | NAV == 0 | disable strategy in the scheduler, INFO |
| `"Not backend"` | backend address rotated or role-member 0 changed | **CRIT**, halt **all** write automations |
| tx timeout / dropped | nonce lane stuck | escalate to the sender's stuck-tx path (§5) |

---

### A3 — Basket construction TWAP executor — **PRIORITY: P0**

New deposits land 100% in the sleeve. Without this, a funded basket never buys anything. A3 and A2 are two **job sources for the same allocation engine** — one ladder state machine per strategy, one writer.

**Trigger.**
- **Event:** `Deposit(address,uint256)` emitted by an address in the basket inventory (disambiguate by address — the chassis emits the same signature).
- **Cron every 5 min:** sweep for (a) events missed by the hook, (b) queued jobs waiting for an open window, (c) drift between actual sleeve share and target sleeve share.

**Reads.** Same as A2, plus the construction job queue.

**Decision logic.**
1. On deposit: `unbuilt = Σ_i max(0, target_i - value_i)`. If `unbuilt < MIN_CONSTRUCTION_NOTIONAL` (default 500e6 = $500), **do not create a job** — let A2's ordinary drift band pick it up.
2. Otherwise enqueue/merge `{strategy, finalWeights, unbuilt, createdAt, clipsDone}` (one job per strategy; a second deposit merges into the open job).
3. Drain during open windows only, at most one clip per `TWAP_CLIP_INTERVAL` (default 10 min), each clip sized by the same `s`/ladder mechanism as A2 with `GLOBAL_CLIP` default **$100k** and per-name `clip_i = CAP_i * CAP_SAFETY_FACTOR`.
4. Job completes when `max_i |gap_i| / NAV < DRIFT_FLOOR_BPS`; restore final weights; clear ladder state.

**Emits.** `setStockWeights` + `rebalance` (identical mechanics to A2, same pre-flight, same cost accounting).

**Guards.**
- Never run when `tradeWindowOpen == false`. A half-built basket over a weekend is a **correct** outcome: the unbuilt remainder sits in the sleeve earning yield.
- Do not start a *new* clip within `PRE_CLOSE_QUIET` (default 60 min) of the observed Friday freeze if the ladder would be left mid-step — finish the step or defer the whole clip.
- One writer per strategy: A3 must take the same lock A2 uses.
- Deposits into a basket whose constituents include an untradeable feed → hold the job, INFO.

**Failure handling.** Same revert taxonomy as A2. Additionally: job age > `CONSTRUCTION_MAX_AGE` (default 48 *trading* hours, i.e. excluding frozen windows) → **WARN** ("deposit not deployed"), which is a user-visible SLA. Job age > 2× → **CRIT**.

**Note for the dev.** Deposits are permissionless — anyone can deposit into any strategy. A3 must not assume the depositor is the owner, and must not treat an unexpected deposit as an anomaly.

---

### A4 — Compound keeper (Merkl claim + compound) — **PRIORITY: P1**

**Trigger.** Cron **daily** at a fixed UTC hour chosen to sit after the Merkl root update *and* its dispute window; plus a cron every **6h** that only checks whether anything is claimable.

**Reads.**
- Merkl API for each chassis strategy address: claimable `{token, cumulativeAmount, proof}`.
- On-chain Distributor `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`: current merkle root, `endOfDisputePeriod`, `disputer` (confirm exact getter names against the live ABI).
- Reward token `balanceOf(strategy)`; `slippagePriceChecker.isRewardToken(token)`.
- QuoterV2 quotes for `rewardToken → USDG` across candidate fee tiers **100 / 500 / 3000 / 10000**.
- Oracle expected out for the same amount (to predict `oracleFloor`).

**Decision logic.**
1. **Dispute window open** (`disputer != 0` or `endOfDisputePeriod > now`) → skip, INFO. Never claim against a disputed root.
2. **API root ≠ on-chain root** → skip, **WARN** (the proofs will not verify).
3. Claim when `Σ claimableValueUSD >= CLAIM_MIN_USD` (default $25): `claimRewards(tokens, amounts, proofs)`. Amounts are Merkl **cumulative** amounts — pass exactly what the API returns.
4. For each reward token with a non-zero balance:
   - `isRewardToken == false` → **WARN**, skip (needs an admin `SlippagePriceChecker` config change; the call would revert `"Token not configured as reward"`).
   - Quote all tiers, take the best → `bestQuote`, `bestFee`.
   - `oracleFloor = expectedOut * (10000 - allowedSlippageInBps) / 10000`.
   - **If `bestQuote < oracleFloor` → do not send. WARN**: "reward swap cannot clear the oracle floor" (thin pool, depeg, or a mispriced reward token). This is the two-sided floor working as designed — the contract would revert.
   - `backendMinOut = bestQuote * (10000 - BACKEND_SLIPPAGE_TOLERANCE_BPS) / 10000` (default 50 bps). The contract enforces `max(backendMinOut, oracleFloor)`.
   - Skip if `bestQuote < COMPOUND_MIN_USD` (default $50) or if `bestQuote - gasCostUSD - spreadUSD <= 0`.
5. Send `compoundRewards(rewardToken, bestFee, backendMinOut)`.
6. Optionally call `depositIdleTokens()` (permissionless) if idle balance is non-zero after a partial failure.

**Emits.** `claimRewards(...)`, `compoundRewards(...)` — one tx per strategy per token, serialized. Batch through the Mamo Multicall **only if** that contract is `BACKEND_ROLE` member 0 (§2.1).

**Guards.**
- Compounding does **not** require an open equity window — it is a USDG/reward-token path. It **does** require a healthy USDG/USD feed (A6) because the oracle floor is priced through it.
- `compoundFee` skim is automatic; verify `feeRecipient` matches the ops-approved address each run (drift → **WARN**).
- Never compound the strategy token itself (the contract rejects it).

**Failure handling.** Merkl API 5xx/timeouts → retry with backoff, then defer to the next cycle (rewards are cumulative; a missed day is not a loss). Proof rejection on-chain → **WARN** + re-fetch (root may have rotated mid-run). Repeated failure over 3 days → **CRIT**.

**Context the dev should not be surprised by.** The Robinhood Earn subsidy is paid **in vault shares**, so for the chassis there may be **nothing to claim at all** — that is expected, not a bug. `MORPHO` is **not bridged** to 4663, so MORPHO-denominated rewards are impossible today. A4 exists for Merkl campaigns run by Mamo or by curators.

---

### A5 — Vault gate & venue monitor — **PRIORITY: P0**

**This monitor is preventive, not remedial.** Once a `sendSharesGate` / `sendAssetsGate` is live on a funded vault, `updatePosition` reverts *entirely* (§2.3) and there is **no on-chain escape**. The only defence is to see the gate coming — via the curator timelock submission — and rotate out before it takes effect.

**Trigger.** Cron every **5 min**, plus event hooks on each allowlisted vault (gate setters and timelock submit/accept events — confirm exact names against `morpho-org/vault-v2 @ b1e9005`, vendored under `test/vendor/`) and on `MamoVaultConfig` (`VaultAdded`/`VaultRemoved`/`SupplyCapUpdated`).

**Reads,** per vault in `MamoVaultConfig.getVaults()`:
- All four gates: `receiveSharesGate()`, `sendSharesGate()`, `receiveAssetsGate()`, `sendAssetsGate()`.
- `owner()`, `curator()`, and any pending-timelock views the ABI exposes.
- `keccak256(eth_getCode(vault))` vs the pinned fingerprint (Steakhouse USDG: `0x34920980…c1f6e`; the vault is **not** a proxy, so a codehash change means the address or the allowlist entry changed).
- `totalAssets()`, `convertToAssets(1e18)` (share price), `asset()`.
- Per chassis strategy: `convertToAssets(balanceOf(strategy))` for exposure attribution.
- **Exit probe:** `eth_call` a `withdraw(X, strategy, strategy)` with `from = strategy` (no state override needed) at `X = min(position, EXIT_PROBE_SIZE)` — a revert means the exit path is broken *today*.

**Decision logic.**

| Condition | Severity | Action |
|---|---|---|
| `sendSharesGate != 0` or `sendAssetsGate != 0` on a **funded** vault | **CRIT / P0 incident** | Funds are stranded; `updatePosition` and `withdrawAll` will revert. Runbook: freeze new deposits (front end + multisig cap → 0), contact the curator, prepare user comms. **Do not** attempt `updatePosition` — it reverts and burns nonces. |
| Same gate set on an **unfunded** allowlisted vault | **WARN** | Remove from the allowlist (multisig) before anything is allocated. |
| `receiveSharesGate != 0` or `receiveAssetsGate != 0` | **WARN → CRIT if funded** | New deposits into that vault will fail. Suggested tx: `updatePosition(vaults \ {gated}, renormalized weights)` — redeeming still works, so rotation is possible. Emit the exact calldata in the alert for a human to approve. |
| **Timelock submission observed** that would set any gate | **CRIT** | The only actionable window. Pre-emptively rotate out **before** the timelock elapses. Alert includes the effective time and the suggested `updatePosition` calldata. |
| Exit probe reverts | **CRIT** | Venue illiquidity or a gate; investigate before any user hits it. |
| Share price drop > `VAULT_SHARE_PRICE_DROP_BPS` (default 50 bps in 24h) | **CRIT** | Loss event at the venue. |
| `totalAssets` drop > `VAULT_TVL_DROP_PCT` (default 30% in 1h) | **WARN** | Mass exit; exit liquidity risk. |
| Codehash / `asset()` / `owner()` / `curator()` drift | **CRIT** | Integrity failure or a wrong allowlist entry. |
| `VaultAdded`/`VaultRemoved`/`SupplyCapUpdated` not matching the ops-approved config | **WARN** | Governance drift; reconcile. |

**Emits.** No transactions. Alerts carry **ready-to-sign suggested calldata** for the rotation; execution is a human decision (the backend key *can* send `updatePosition`, but auto-rotating on a monitor signal risks a full round-trip through every vault on a false positive).

**Guards.** All reads batched via Multicall3. Gate reads must tolerate an ABI mismatch (a non-V2 vault in the allowlist) — a revert on a gate read is itself a **WARN**.

**Failure handling.** RPC failure → retain last state, retry; two consecutive full failures → **WARN**; five → **CRIT** (this monitor going blind is itself an incident).

---

### A6 — Feed health monitor — **PRIORITY: P0**

Shares A1's reads where possible (one Multicall3 batch covering both) but runs its own escalation ladder.

**Trigger.** Cron every **5 min**.

**Reads.** `latestRoundData()`, `decimals()` for every configured feed (equities, USDG/USD, ETH/USD); previous round's stored answer from the local store; once proxies are wired, `proxy.aggregator()` for each proxy.

**Checks and escalation.**

| Check | Threshold | Severity |
|---|---|---|
| USDG/USD staleness | > 25h | **WARN** ("heartbeat missed") |
| | > 26h | **CRIT** ("chassis oracle path about to brick") |
| | > 26.5h | **CRIT + page** — the on-chain bound (26–27h) is about to trip; every oracle-bounded path fails |
| USDG/USD peg band | outside **[0.98, 1.02] × 1e8** | **CRIT** — halt compounding and equity trading (all NAV crosses through this feed) |
| Equity staleness | per A1 phases | as A1 |
| ETH/USD staleness (liveness proxy) | > `ETH_LIVENESS_MAX` (default 3h) | **CRIT** — chain/oracle liveness suspect; halt all write automations |
| `decimals() != 8` | any | **CRIT** — config error; the cross-rate math assumes a shared 8dp scale |
| `answer <= 0` | any | **CRIT** |
| `roundId` regression, or `updatedAt` advancing with an unchanged `roundId` | any | **WARN** |
| Single-round jump | equities > `FEED_JUMP_EQUITY_BPS` (default 2000 = 20%), USDG > `FEED_JUMP_USDG_BPS` (default 200 = 2%) | **WARN** + mark that name untradeable for `JUMP_COOLDOWN` (default 15 min) pending a confirming round |
| **Feed rotation**: `proxy.aggregator() != pinned` | any | **CRIT** — halt all trading on that name until the pin is reviewed and updated by PR |
| No `AnswerUpdated` in 7 days on a configured feed | any | **WARN** — possible dead/decoy aggregator |

**Emits.** Alerts + a `feed_health` record consumed by A1 and the allocation engine.

**Guards / policy.**
- **Feed discovery is forbidden.** 31 decoy "dividends.finance" aggregators cover exactly the tickers Chainlink does not, with plausible descriptions, no round history and implausible prices. The feed map is reviewed config; adding a feed is a pull request, never a runtime lookup by description or symbol.
- Optional startup assertion: each configured feed must have ≥ 1 `AnswerUpdated` in the last 7 days and a price within `SANITY_BAND_PCT` of an independent reference (a CEX price API) — advisory only, never a trading gate.

**Failure handling.** Same fail-closed contract as A1: no health data ⇒ no trading.

---

### A7 — Corporate-action monitor — **PRIORITY: P1**

**Trigger.** Cron **hourly** (multiplier changes are rare), plus a daily deep read over the whole eligible universe (not just current constituents — a staged action on a candidate matters for basket design).

**Reads,** per token (all via `staticcall`, tolerating reverts):
- `uiMultiplier()`.
- Staged fields: `newUIMultiplier()` and `effectiveAt()` (**ERC-8056 staged-action surface — confirm the exact selectors against the live issuer token before implementing**; treat "function missing" as "no staged action", not as an error).
- `name()`, `symbol()`, `decimals()`, `totalSupply()`.
- Optional: `paused()` / `oraclePaused()` if exposed.

**Decision logic.**

| Observation | Severity | Action |
|---|---|---|
| `uiMultiplier` changed vs stored | **WARN** (informational) | **NAV is unaffected** — raw balances do not change and the feed price already includes the multiplier. Any off-chain display that stores share counts must be re-derived. Record the new value. |
| Staged `newUIMultiplier` with `effectiveAt` in the future | **WARN** | Publish a **trading blackout** for that constituent over `[effectiveAt - PRE_ACTION_BLACKOUT (default 30 min), effectiveAt + POST_ACTION_BLACKOUT (default 60 min)]`. The allocation engine must skip any basket containing it during the window (feed and pool can disagree transiently across the action). |
| `name()` no longer contains `"Robinhood Token"`, or `decimals() != 18` | **CRIT** | Wrong address or token swap. Disable every basket holding it. |
| `paused()` true | **CRIT** | Equity leg frozen; escalate to the A9 runbook. |

**Emits.** No transactions. Publishes `blackouts[{token, from, to, reason}]` consumed by A2/A3.

**Guards.** Never adjust NAV by the multiplier. Never infer a corporate action from a balance change (balances do not change).

**Failure handling.** A missing staged-field ABI is expected — degrade to detecting multiplier changes after the fact (still useful; the blackout is the only thing lost). Alert **WARN** once if the staged surface cannot be read, so the contracts/ops team can chase the correct ABI.

---

### A8 — Supply-cap capacity monitor — **PRIORITY: P1**

**Trigger.** Event hooks on `MamoVaultConfig.DepositRecorded` / `WithdrawRecorded`, plus cron every **15 min** (hooks can drop; the cron is authoritative).

**Reads.** `supplyCap()`, `totalDeposited()`, `remainingCapacity()`, and `trackedDeposits(strategy)` for every chassis strategy in the inventory.

**Decision logic.**

```
utilization = totalDeposited / supplyCap        # supplyCap == 0 means uncapped
```

| Utilization | Severity | Action |
|---|---|---|
| ≥ 75% | **INFO** | Publish to the capacity feed (front end + staking-gated-capacity service). |
| ≥ 90% | **WARN** | Ops decision: raise the cap (multisig) or start gating the front end. |
| ≥ 98% | **CRIT** | The front end must stop advertising capacity. |
| = 100% | **CRIT** | `deposit()` reverts `"Supply cap exceeded"` — a **user-visible failure**. |

**Reconciliation invariant:** `Σ trackedDeposits(known strategies) == totalDeposited`. A mismatch means an unknown strategy is reporting → **WARN** + trigger an A0 inventory resync.

**Emits.** No transactions. Publishes `capacity{cap, used, remaining, utilization, perStrategy[]}` — this is the feed the **staking-gated capacity** flywheel consumes (reserved carve-outs for stakers, `docs/ROBINHOOD_CHAIN_SPEC.md` §2 idea 4).

**Guards.**
- `supplyCap() == 0` means **uncapped**, not "zero capacity". Do not divide by zero.
- Cap changes should be attributable to a known multisig transaction; an unexplained `SupplyCapUpdated` is a **CRIT** governance alert.
- **Baskets are not metered here** (`StockBasketStrategy` has no `MamoVaultConfig` wiring). Do not present basket AUM in this meter; see §11 for the gap.

**Failure handling.** Standard retry/backoff. If the cron has not succeeded in 1h → **WARN** (capacity display goes stale).

---

### A9 — Issuer blocklist watch — **PRIORITY: P0**

The Jersey issuer's `AccessControlsRegistry` can blocklist a contract address in one transaction. Paxos can freeze USDG addresses. Either event is a **P0 incident** and we need to learn about it from a monitor, not from a user.

**Trigger.**
- **Once the registry address is known** (config item, currently **TBD — obtain from the contracts/legal track**): event hook on its blocklist/unblocklist events, filtered to Mamo strategy addresses.
- **Until then (and as a permanent backstop):** cron every **15 min**, probing by simulation.

**Reads / probes.** All `eth_call`, zero gas, no signatures:

| Probe | Call | Reads |
|---|---|---|
| **Send-side block** | `token.transfer(BURN_PROBE_ADDR, amt)` with `from = strategy`, `amt = min(1, balance)`; if `balance == 0`, `amt = 0` | revert ⇒ blocked (or non-standard zero-transfer semantics — see guard) |
| **Receive-side block** | `token.transfer(strategy, 1)` with `from = <a known holder, e.g. the Uniswap pool>` | revert ⇒ the strategy cannot receive |
| **USDG** | Same two probes against USDG `0x5fc5360D…` | Paxos freeze detection |

Probe set = every constituent held by every enabled basket, plus USDG for every strategy. Batch through Multicall3 where the `from` can be uniform; otherwise, chunk and rate-limit (this is the most `eth_call`-hungry monitor — budget it).

**Decision logic.** Any probe revert that is **not** an insufficient-balance/allowance revert → treat as blocked.

| Scope | Severity | Runbook |
|---|---|---|
| One strategy, one token | **CRIT / P0** | Disable that basket's automation. Determine whether the sleeve is still accessible (it is, unless USDG itself is frozen) — users can still withdraw the USDG side. Notify the user; escalate to legal/BD. |
| Many strategies (Mamo-wide) | **CRIT / P0 page** | Halt **all** write automations. Freeze deposits at the front end. Executive + legal escalation. Public comms per the incident policy. |
| USDG frozen for a strategy | **CRIT / P0 page** | Total loss of access for that strategy; nothing on-chain helps. Immediate escalation. |

**Explicit policy:** the runbook **does not** include evasive redeployment, address rotation to dodge a block, or any attempt to route around an issuer action. That is a policy limit, not a capability limit. Escalate to legal.

**Guards.**
- Some blocklist implementations do not check zero-amount transfers → a zero-amount probe can produce a false negative. Prefer `amt = 1` on any token with a non-zero balance, and treat zero-balance names as "unprobed" rather than "clear".
- Distinguish revert *reasons* — `"transfer amount exceeds balance"` is not a block. Maintain an allowlist of benign revert strings and alert on anything unrecognised (**WARN**) rather than crying wolf.
- Probe results are cached; alert only on a state *transition*, with a two-consecutive-cycle confirmation before firing CRIT.

**Failure handling.** RPC failure ⇒ unknown, not clear. If the monitor has not completed a full sweep in 1h → **WARN**.

---

### A10 — Reconciliation & reporting — **PRIORITY: P1**

**Trigger.** Cron daily, **02:00 UTC** (chosen to sit inside the weekly frozen window on weekends — the report must therefore work with equity feeds stale; see guard).

**Reads.**
- Per strategy: `getTotalBalance()` — **which reverts when any constituent's feed is stale**. Fall back to component-wise NAV from raw feed reads, and label the report `pricedAtLastClose = true`.
- Per strategy: constituent balances, sleeve shares → `convertToAssets`, idle balance.
- Local indexer: all events from §2.5 over the reporting window.
- Stored pre-trade quotes from A2/A3.
- `MamoVaultConfig`: `totalDeposited`, `trackedDeposits`, cap.
- Merkl: claimed-to-date vs claimable.

**Outputs.**

1. **NAV series & attribution** per strategy: equity P&L / sleeve yield / trading cost / fees. Sleeve yield must be computed from `convertToAssets`, **never** from vault token balances (donations are invisible on Vault V2 until an allocator sets `maxRate`).
2. **Execution-quality report.** For each `StockSold` / `StockBought`, compare realized `amountOut` against (a) the oracle expectation at execution and (b) the **pre-trade QuoterV2 quote stored by the executor**.
   ⚠️ **You cannot re-quote historically.** State pruning (~100k blocks ≈ 2.8h) makes historical `eth_call` fail. If the pre-trade quote is missing for a fill, the report records `quoteUnavailable` — it does not attempt a retroactive quote outside the window. Report realized slippage in bps vs oracle, per name, per size bucket; this is the feed that tunes the §1.2 capacity table over time.
3. **Rebalance cost ledger.** From `Rebalanced(navBefore, navAfter)`: per-event cost bps, rolling 7/30-day totals per basket vs `MONTHLY_COST_BUDGET_BPS`.
4. **Cap meter reconciliation.** `MamoVaultConfig.totalDeposited` must equal `Σ DepositRecorded − Σ WithdrawRecorded` from the indexer. Any mismatch = missed events or an unknown strategy → **WARN**.
   **Do not** reconcile `totalDeposited` against realized user principal: `recordFullExit()` frees the *tracked* amount, which is deliberately a hair above the realized amount at a non-par share price. Expect `totalDeposited ≤ Σ(principal actually in the system)` and treat drift in the other direction as the bug.
5. **Inventory reconciliation.** Registry `StrategyAdded` events vs the local inventory vs config → surfaces strategies automation is not driving.
6. **Merkl reconciliation.** Claimed vs claimable per strategy; unclaimed value > `UNCLAIMED_ALERT_USD` (default $250) for > 7 days → **WARN**.
7. **Daily digest** to the ops channel: NAV totals, capacity, incidents, cost budget, unresolved alerts.

**Guards.** Read-only. Must run to completion even when equity feeds are frozen (label, don't fail). Must not consume the trading RPC budget — run it against a secondary RPC endpoint or a lower-priority key if one exists.

**Failure handling.** Report generation failure → retry once, then **WARN**. Two consecutive missed days → **CRIT** (reporting blindness).

---

## 5. Transaction & signing policy

Applies to every action that writes (A2, A3, A4).

1. **One writer.** All `onlyBackend` transactions originate from a single sender component holding a global lock on the backend address. No action signs on its own.
2. **Simulate, then send.** Every transaction is `eth_call`-simulated with `from = backend` at the current head. A simulation revert is a *decision*, not an error: classify it (§4 tables) and act. Never send a transaction whose simulation reverted.
3. **Nonce discipline.** Explicit nonce from `eth_getTransactionCount(backend, 'pending')` under the lock. On timeout (`TX_TIMEOUT`, default 120s), re-broadcast with the same nonce and a bumped fee; after `TX_MAX_BUMPS` (default 3), send a self-transfer to clear the nonce and **CRIT**.
4. **Idempotency.** Every job carries a key `(action, strategy, intentHash)`. Before sending, re-read the on-chain state that the job was computed from and re-verify the trigger condition — a queued job must never fire on stale inputs. Jobs older than `JOB_MAX_AGE` (default 10 min) are recomputed, not sent.
5. **Budgets.** Per-tx gas ceiling; per-strategy daily tx budget; global daily tx budget; keeper ETH balance floor (`MIN_KEEPER_ETH`, alert at 2×). Exceeding a budget halts sending and alerts — it does not silently drop jobs.
6. **Kill switches.** Global (`AUTOMATION_ENABLED=false`), per-action, and per-strategy. Any **CRIT** in A1/A5/A6/A9 flips the relevant switch automatically; re-enabling is a human action.
7. **Block-number hygiene.** Anything the sender records is the **L2** number from `eth_blockNumber`. Never mix with a Solidity `block.number` value read from a contract (that is an L1 number).

---

## 6. Alerting, severity and runbooks

| Severity | Meaning | Channel | Response |
|---|---|---|---|
| **INFO** | State change worth recording | ops log / daily digest | none |
| **WARN** | Degraded; automation continues in a reduced mode | ops Slack channel | next business day |
| **CRIT** | Funds, access or correctness at risk; automation halted in the affected scope | Slack + PagerDuty | immediate |
| **P0 PAGE** | Chain-wide or issuer-level: A5 gate on a funded vault, A9 Mamo-wide block, USDG depeg/freeze | PagerDuty + exec/legal escalation | immediate, follow the incident runbook |

Every alert carries: action id, subject (strategy/vault/feed/token), observed vs threshold, the head block + timestamp it was observed at, the automatic action taken (e.g. "basket automation disabled"), and a runbook link. Dedupe by `(action, subject, severity)` with a cooldown (default 30 min), escalating one level if the condition persists past `ESCALATE_AFTER` (default 2h).

**Runbooks to write before launch** (one page each): vault gate set on a funded venue · issuer blocklist hit · USDG depeg or missed heartbeat · equity feed frozen mid-week · feed rotation detected · basket stuck mid-ladder · backend key compromise / rotation · supply cap exhausted.

---

## 7. Caveat: is Tenderly even available on chain 4663?

**Unknown. Confirm before committing to the platform.** Robinhood Chain launched 2026-07-01 and is not a mainstream network; there is no evidence in this repo either way.

**Confirmation steps (do this first):**
1. Check Tenderly's supported-networks list for chain id 4663.
2. Attempt to add it as a custom network in the dashboard and observe whether **indexing** (not just RPC proxying) is available.
3. Test each trigger type you intend to use: `periodic` (cron), `block`, `transaction`, `alert`/`event`.
4. Test the **Simulation API** against a 4663 transaction.

**What breaks if 4663 is unsupported — and what does not:**

| Capability | If 4663 unsupported |
|---|---|
| **Cron (`periodic`) actions** | **Still work.** A cron action is just a scheduled function that can `fetch()` any HTTPS endpoint, including the 4663 RPC. Network support is irrelevant to it. |
| **Event / alert / transaction triggers** (A3's `Deposit` hook, A5's vault hooks, A8's cap hooks, A9's registry hook) | **Do not work.** Replace each with a **log poller inside a cron action**: `eth_getLogs` from the stored checkpoint, filtered by address + topic0. Every event-triggered automation in §4 already has a cron fallback specified for exactly this reason. |
| **Simulation API** | Falls back to `eth_call` / `eth_estimateGas` against the node — which is what §5 mandates anyway. |
| **Storage / secrets / KV** | Platform features, network-independent. |

**Design rule:** write every action as **RPC + key operations with no Tenderly-specific primitives in the business logic**. Isolate anything platform-shaped (trigger registration, secret access, KV) behind a thin adapter. The entire specification then runs unchanged on a plain scheduled worker (cron + a small service, or a queue worker) if Tenderly cannot index 4663. Tenderly is the *target*, not a dependency.

**Worst realistic case:** event hooks become 5-minute log polls. At ~864,000 blocks/day, polling `eth_getLogs` with an address+topic filter every 5 minutes over ~3,000 blocks is cheap and entirely sufficient for every duty here. Nothing in this spec needs sub-minute event latency.

---

## 8. Configuration & secrets inventory

### 8.1 Secrets

| Secret | Purpose | Custody policy |
|---|---|---|
| `ROBINHOOD_RPC_URL` (+ `ROBINHOOD_RPC_URL_FALLBACK`) | All chain reads/writes | Not sensitive if public, but rate-limits are per-key on a paid endpoint — treat a paid key as a secret. |
| **Backend signing key** | The `onlyBackend` EOA | **Dedicated EOA, used for nothing else.** Custody in KMS/HSM (AWS KMS secp256k1, Turnkey, Fireblocks) with the worker holding *signing permission*, not the key material. Raw hex in an action's environment only if no KMS path exists, and then with a documented rotation plan. Holds only enough ETH for gas (`MIN_KEEPER_ETH` × 10). **Never holds user funds, never has owner/admin rights on any contract, never holds `DEFAULT_ADMIN_ROLE`.** Separate key per environment (staging/prod). Rotation is an admin-multisig operation on `BACKEND_ROLE` **member 0** (§2.1) — verify with `getBackendAddress()` after every rotation. |
| `MERKL_API_KEY` (if required) | A4 claim proofs | standard secret |
| Alerting webhooks (Slack, PagerDuty) | §6 | standard secret |
| Reference price API key (optional, A6 sanity band) | advisory only | standard secret |

**Blast-radius statement for the security review:** compromise of the backend key allows an attacker to rebalance baskets and rotate chassis positions **within the mandates the contracts enforce** — oracle-bounded swaps, allowlisted venues, `maxTotalStockBps`, the two-sided compound floor. It does **not** allow withdrawals (owner-only), venue changes (multisig-only), cap changes (multisig-only), or upgrades (user-initiated, whitelisted implementations only). That containment is the design; see §12.

### 8.2 Configuration files (reviewed, version-controlled, no runtime discovery)

| File | Contents |
|---|---|
| `addresses/4663.json` | USDG, Steakhouse vault, SwapRouter02, QuoterV2, Multicall3, Merkl Distributor + DistributionCreator, `MamoStrategyRegistry`, `MamoVaultConfig`, factories, Mamo `Multicall`, `SlippagePriceChecker`, backend EOA, issuer `AccessControlsRegistry` (**TBD**). Mirrors the `addresses/8453.json` schema (`[{addr, name, isContract}]`). |
| `feeds.4663.json` | Per feed: `{token, aggregator, proxy (TBD), decimals: 8, class: equity\|stable\|liveness, staleness: {fresh, stale}, pegBand?}`. **Pinned aggregator address per proxy** for rotation detection. |
| `strategies.json` | Interim inventory (§3.3) until factories emit discovery events. |
| `baskets.json` | Per basket: `{basketId, name, constituents[], finalWeightsBps[], maxTotalStockBps, poolFee, driftBandBps, clipOverrides{}, dailyRebalanceBudget, enabled}`. |
| `capacity.json` | Per-name 100bps trade caps (§1.2) + `CAP_SAFETY_FACTOR` + `GLOBAL_CLIP`; **re-measured periodically against live QuoterV2** and reviewed by PR. |
| `thresholds.json` | Everything in §10, so product can tune without reading code. |
| `calendar.json` | Advisory equity calendar + holidays. **Anomaly classification only — never a trading gate.** |

---

## 9. What the backend dev needs from the contracts team

| Item | Why | Status |
|---|---|---|
| **ABIs** for `StockBasketStrategy`, `MorphoVaultsStrategy`, `MamoVaultConfig`, `MamoStrategyRegistry`, `SlippagePriceChecker`, `Multicall`, plus the Vault V2 ABI (gates + timelock events) | Everything | Available from `forge build` output on this branch; publish a versioned artifact package. |
| **`addresses/4663.json`** | Config loader | **Blocked** — not yet created; deployment has not happened. |
| **Factory addresses + strategy-creation event signatures** | A0 discovery | **Blocked** — factories not built (`docs/ROBINHOOD_PLAN.md` §5 item 4). Until then A0 runs off config; agree the event shape early so A0 does not need rewriting. |
| **Issuer `AccessControlsRegistry` address + blocklist event signatures** | A9 primary trigger | **Blocked / TBD** — obtain from the issuer docs or on-chain. A9 runs on simulation probes until then. |
| **Chainlink consumer proxy addresses + declared heartbeat/deviation** | A6 rotation detection; correct staleness bounds | **Blocked** — the docs directory was unreachable during verification (`ROBINHOOD_CHAIN_SPEC.md` §6 item 4). We currently bind raw aggregators, which a rotation would strand. |
| **Exact ERC-8056 staged-action selectors** (`newUIMultiplier`, `effectiveAt` or equivalents) | A7 blackouts | **TBD** — confirm against a live issuer token. |
| **Merkl Distributor ABI as deployed** (`disputer`, `endOfDisputePeriod`, root getter names; whether `toggleOperator` is required for the strategy self-claim path) | A4 | Verify on-chain. |
| **Which address is `BACKEND_ROLE` member 0** — the EOA or the Mamo `Multicall` | §2.1; determines whether A4/A2 can batch | Decision needed before launch. Recommendation: **deploy `Multicall` as member 0 with the keeper EOA as its owner** (the Base pattern) to get batching. |
| **Production `SlippagePriceChecker` staleness configuration per feed class** | A2's revert taxonomy must match the contract exactly | Recommendation: USDG 26–27h, equities **~2h intraweek** (see below). |

### Requested contract changes (not blocking, but they make the keeper materially safer)

1. **Add a trade-size cap to `rebalance`** — e.g. `rebalance(uint256 minTradeValue, uint256 maxTradeValue)` or per-leg rebalancing. Today the only way to bound a trade is the `setStockWeights` ladder (A2), which costs a second transaction per clip, temporarily misreports the basket's target weights to any UI reading `getBasket()`, and leaves a basket in a recoverable-but-odd state if the keeper dies mid-ladder. A `maxTradeValue` would delete an entire class of keeper complexity.
2. **Tighten the equity staleness bound in the production price checker to ~2h.** With the 26h bound, the contract will execute equity trades at Friday's close all through Saturday — the guard is a *closed-market detector with a 26h lag*, and the only thing preventing a weekend trade is keeper discipline (A1). A ~2h bound makes the contract enforce what the keeper intends. **Trade-off to decide with product:** a tight bound also makes `withdrawAll` and stock-selling `withdraw` revert on weekends. Sleeve-first withdrawal already covers the common exit path, so the cost is narrow, but it is user-visible and must be a deliberate decision, not a default.
3. **Per-pair pool fee on baskets.** One `poolFee` for the whole basket excludes any name whose liquidity lives in a different tier and prevents routing a leg through a better tier as depth shifts.
4. **Supply-cap metering for baskets.** `StockBasketStrategy` has no `MamoVaultConfig` wiring, so basket AUM is uncapped on-chain and A8 cannot meter it. Given measured basket capacity of ~$250k–$1M, a cap matters more here than on the chassis.
5. **A keeper-readable "last rebalance" timestamp** on the basket would let A2 recover cooldown state from chain rather than local storage.

---

## 10. Parameters appendix

Every tunable in one place. Product can change these without reading code. Defaults are the recommended launch values; all of them are `thresholds.json` entries.

### 10.1 Oracle / market state

| Parameter | Default | Used by | Meaning |
|---|---|---|---|
| `EQUITY_FRESH_MAX` | **90 min** | A1, A2, A3 | Max equity feed age for `phase = OPEN`. Above intraweek cadence (~20–30 min median) with headroom. |
| `EQUITY_STALE_MAX` | **26 h** | A1, A6 | Mirrors the contract bound (`RobinhoodBasketFork` uses 26h). Above this = definitively closed. |
| `USDG_STALE_WARN` | **25 h** | A6 | Heartbeat missed. |
| `USDG_STALE_CRIT` | **26 h** | A6 | Oracle path about to brick (contract bound 26–27h). |
| `USDG_PEG_BAND` | **[0.98, 1.02] × 1e8** | A6 | Depeg halt. |
| `ETH_LIVENESS_MAX` | **3 h** | A1, A6 | Sequencer-uptime substitute (median cadence ~44 min). |
| `FEED_SPLIT_DELTA` | **4 h** | A1 | Spread between freshest and stalest equity feed that indicates a single-name outage. |
| `HEAD_LAG_MAX` | **120 s** | A1 | Chain head timestamp vs worker clock. |
| `MARKET_STATE_MAX_AGE` | **5 min** | all consumers | Older ⇒ fail closed (no trading). |
| `FEED_JUMP_EQUITY_BPS` | **2000** (20%) | A6 | Single-round jump ⇒ WARN + cooldown. |
| `FEED_JUMP_USDG_BPS` | **200** (2%) | A6 | Same, for USDG. |
| `JUMP_COOLDOWN` | **15 min** | A6 | Untradeable window after a suspicious print. |

### 10.2 Rebalancing / construction

| Parameter | Default | Used by | Meaning |
|---|---|---|---|
| `DRIFT_BAND_BPS` | **500** (5% of NAV) | A2 | Fire threshold on the worst leg. Per-basket overridable. |
| `DRIFT_FLOOR_BPS` | **200** | A2, A3 | Time-based fire threshold / ladder completion threshold. |
| `MAX_REBALANCE_INTERVAL` | **7 d** | A2 | Force a rebalance if drift ≥ floor. |
| `REBALANCE_COOLDOWN` | **30 min** | A2 | Min gap between rebalances per strategy. |
| `DAILY_REBALANCE_BUDGET` | **6 tx/strategy/day** | A2, A3 | Hard cap. |
| `MIN_NAV` | **250e6** ($250) | A2 | Skip dust baskets. |
| `MIN_TRADE_VALUE_ABS` | **10e6** ($10) | A2, A3 | `minTradeValue` floor (matches the fork suite). |
| `MIN_TRADE_VALUE_BPS` | **25** | A2, A3 | `minTradeValue = max(abs, NAV × bps)`. |
| `CAP_SAFETY_FACTOR` | **0.5** | A2, A3 | Fraction of the §1.2 100bps cap actually used. |
| `GLOBAL_CLIP` | **100_000e6** ($100k) | A3 | Max notional per construction execution. |
| Per-name caps | NVDA 170k · AAPL 60k · SPY 34k · SPCX 20k · GOOGL 20k · TSLA 16k · QQQ 4k · GME/SLV **0** | A2, A3 | `capacity.json`; re-measure periodically. |
| `TWAP_CLIP_INTERVAL` | **10 min** | A3 | Min gap between construction clips. |
| `PREFLIGHT_MARGIN_BPS` | **20** | A2, A3 | Quote must beat the contract's `minOut` by this much. |
| `PREFLIGHT_FAIL_STREAK` | **6** | A2 | Consecutive pre-flight failures before WARN. |
| `LADDER_MAX_AGE` | **24 trading hours** | A2, A3 | Basket stuck at intermediate weights ⇒ WARN. |
| `MIN_CONSTRUCTION_NOTIONAL` | **500e6** ($500) | A3 | Below this, no construction job; A2's drift band handles it. |
| `CONSTRUCTION_MAX_AGE` | **48 trading hours** | A3 | Deposit-to-deployed SLA ⇒ WARN (2× ⇒ CRIT). |
| `PRE_CLOSE_QUIET` | **60 min** | A3 | No new clips this close to the observed weekly freeze. |
| `REBALANCE_COST_WARN_BPS` | **100** | A2 | Per-rebalance NAV cost warning. |
| `REBALANCE_COST_HALT_BPS` | **300** | A2 | Auto-disable the strategy. |
| `MONTHLY_COST_BUDGET_BPS` | **150** | A2, A10 | Rolling 30-day realized cost per basket. |

### 10.3 Compounding

| Parameter | Default | Used by |
|---|---|---|
| `CLAIM_MIN_USD` | **$25** | A4 |
| `COMPOUND_MIN_USD` | **$50** | A4 |
| `BACKEND_SLIPPAGE_TOLERANCE_BPS` | **50** | A4 (`backendMinOut = bestQuote × (1 − 50bps)`) |
| Candidate fee tiers | **100 / 500 / 3000 / 10000** | A4 |
| `UNCLAIMED_ALERT_USD` | **$250 for > 7 days** | A10 |

### 10.4 Venue / capacity / corporate actions

| Parameter | Default | Used by |
|---|---|---|
| `VAULT_SHARE_PRICE_DROP_BPS` | **50 bps / 24h** | A5 |
| `VAULT_TVL_DROP_PCT` | **30% / 1h** | A5 |
| `EXIT_PROBE_SIZE` | **min(position, $10k)** | A5 |
| Capacity thresholds | **75 / 90 / 98 / 100 %** | A8 |
| `PRE_ACTION_BLACKOUT` | **30 min** | A7 |
| `POST_ACTION_BLACKOUT` | **60 min** | A7 |

### 10.5 Execution / infrastructure

| Parameter | Default | Used by |
|---|---|---|
| `TX_TIMEOUT` | **120 s** | sender |
| `TX_MAX_BUMPS` | **3** | sender |
| `JOB_MAX_AGE` | **10 min** | sender (recompute rather than send stale) |
| `MIN_KEEPER_ETH` | **0.02 ETH** (alert at 2×) | sender |
| `PER_TX_GAS_CEILING` | per-action, set after gas profiling on 4663 | sender |
| `GLOBAL_DAILY_TX_BUDGET` | **200** | sender |
| `RPC_MAX_RETRIES` / `RPC_BACKOFF_BASE` | **5** / **250 ms** with jitter | RPC client |
| `LOG_SCAN_CHUNK` | **2_000 blocks** (~200 s of chain) | indexer |
| `ALERT_DEDUPE_COOLDOWN` | **30 min** | alerting |
| `ESCALATE_AFTER` | **2 h** | alerting |
| Cron cadences | A1 60s · A2/A3/A5/A6 5m · A8 15m · A9 15m · A7 1h · A4 daily + 6h · A10 daily 02:00 UTC | — |

---

## 11. Open items to close before launch

| # | Item | Owner | Blocks |
|---|---|---|---|
| 1 | Confirm Tenderly supports chain 4663 (§7); if not, choose the scheduled-worker host | backend | platform choice only — the spec is unaffected |
| 2 | `addresses/4663.json` + factory deployment + strategy-discovery events | contracts | A0 |
| 3 | Chainlink **consumer proxy** addresses + declared heartbeats | contracts/research | A6 rotation detection |
| 4 | Issuer `AccessControlsRegistry` address + event signatures | contracts/legal | A9 primary trigger |
| 5 | ERC-8056 staged-action selectors on the issuer tokens | contracts | A7 blackouts |
| 6 | Decide `BACKEND_ROLE` member 0: EOA vs Mamo `Multicall` | contracts/ops | batching in A2/A4 |
| 7 | Production `SlippagePriceChecker` staleness config per feed class; decide the equity bound (26h vs ~2h) | contracts/product | A2 revert taxonomy |
| 8 | Re-measure the §1.2 capacity table on the day of launch and monthly thereafter | backend | A2/A3 clip sizes |
| 9 | Write the eight runbooks in §6 | ops | CRIT/P0 response |
| 10 | Gas-subsidy expiry (~2026-09-29): re-derive per-rebalance economics and revisit `DRIFT_BAND_BPS` | product | cost budget |

---

## 12. Non-goals (explicit)

These are **out of scope by design**, not "not yet".

1. **No discretionary trading.** The keeper decides *when* to trade and, within the capacity clips, *how much* — it never decides *what a fair price is*. Every swap's `amountOutMinimum` is derived on-chain from the oracle (`getExpectedOut × (1 − allowedSlippageInBps)`), and for compounding the floor is `max(backendMinOut, oracleFloor)`. A backend that supplies a terrible `backendMinOut` cannot trade below the oracle floor; a backend that supplies a great one cannot make a thin pool fill. **The containment is the product.**
2. **No mandate expansion.** `maxTotalStockBps` is set at initialization and `setStockWeights` reverts above it. The keeper cannot increase equity exposure beyond the product's mandate, and no automation here should ever be written as if it could.
3. **No venue expansion.** `MorphoVaultsStrategy.updatePosition` only accepts vaults allowlisted in the multisig-owned `MamoVaultConfig`. The keeper rebalances *within* the allowlist; adding a venue is a multisig operation and is never automated.
4. **No user funds movement.** `withdraw` / `withdrawAll` are `onlyOwner`. The keeper cannot withdraw to itself or to anyone else, in any scenario, including an incident.
5. **No cap changes, no upgrades, no admin actions.** `setSupplyCap`, `addVault`/`removeVault` are owner-only; upgrades are user-initiated and constrained to registry-whitelisted implementations. The keeper key holds none of these rights and no automation should ever request them.
6. **No evasion of issuer or regulator action.** If the issuer blocklists a Mamo address, the response is escalation and disclosure (A9) — never address rotation, contract redeployment, or routing around the block.
7. **No alpha generation.** Rebalancing to target weights is mechanical portfolio maintenance. Nothing here forecasts prices, times the market, or trades on signals; the only timing input is "are the feeds fresh and does the trade fit the capacity".
8. **No market making, no LP.** Stock/USDG LP is explicitly ranked out for 6+ months (`ROBINHOOD_CHAIN_SPEC.md` §2 idea 5); no automation here should provide liquidity.
9. **Not a substitute for the on-chain guards.** If any automation in this document is off, the contracts still refuse bad prices, unlisted venues, and mandate breaches. The keeper's absence degrades the product (drift, unbuilt baskets, uncompounded rewards); it does not endanger funds. Build accordingly — fail closed, always.
