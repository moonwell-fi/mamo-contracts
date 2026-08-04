# Mamo on Robinhood Chain — Product Spec & Ranked Strategy Ideas

*Status: research + MVP prototypes. Nothing here is deployment-ready; the two prototype contracts under `src/robinhood/` are proofs of mechanics with passing unit suites, not audited code.*

---

## TL;DR

Robinhood Chain (Arbitrum Orbit L2, chain ID 4663, launched 2026-07-01) has the primitives for a Mamo port — Morpho is the dominant credit layer (~$308M of ~$733M chain TVL), Chainlink is the exclusive oracle, Uniswap v3/v4 is live, and Merkl (which Mamo already uses on Base) is the rewards layer. But three findings reshape the plan versus a naive "fork it":

1. **A pure USDG yield router is commercially dead on arrival.** Robinhood Earn shows a subsidized ~7% (organic ~1.6–4.3% + Merkl top-up **paid only to app depositors**, in vault shares, for ~a year). A third-party router showing 2–4.5% against that, in the incumbent's own app, loses.
2. **Stock tokens are technically wide open and legally fenced.** They are plain ERC-20s (blocklist, not allowlist — any contract can hold and trade them), with per-equity Chainlink 24/5 feeds and an official Arbitrum tutorial that is literally an index-basket dApp. But they exclude US/UK/CA/CH/UAE persons, and the issuer retains pause/burn/confiscate powers. This is a **non-US product surface with a real regulatory tail** — and also the only surface Robinhood's subsidy doesn't crush.
3. **Most of the port is already written.** The audit branch (PR #66 line) contains `MamoMultiMarketStrategy` + `MarketRegistry` + `MultiMarketStrategyFactory` — an N-venue allocation engine that reduces to Morpho-only by dropping the MTOKEN arm — and the oracle-anchored router-swap pattern that replaces CowSwap (which does not exist on Robinhood Chain) is already used by `MamoStakingStrategy.compound()` on that branch.

**Recommendation:** lead with **Mamo Baskets** (curated stock baskets + USDG yield sleeve — the differentiator nobody's subsidy can replicate), on top of the **multi-vault USDG chassis** (the port of least resistance, with supply caps and multisig-scoped venues carried over from the Boosted USDC design), with **Boosted USDG (levered carry)** as the 2nd-wave product that can honestly beat the 7% headline, and the **MAMO flywheel** wired to all three from day one. Both lead ideas are prototyped in this branch with green unit suites (40 tests).

---

## 1. What we verified about the chain

Dense summary of the three research passes (full reports available on request). Confidence: **[V]** = verified in canonical repos (Uniswap/Morpho/Chainlink/L2Beat GitHub registries), **[C]** = corroborated across independent sources, **[R]** = single reported source. On-chain RPC verification was not possible from this environment — §7 lists the reads to run first.

### Rails
- **Chain**: Arbitrum Orbit L2 on Ethereum, chain ID **4663**, ETH gas, ~100ms blocks, permissionless deployment, **MaxCodeSize 96KB** (4× EIP-170 — the size pressure that shaped `LeveragedAeroManager` doesn't exist here) [V].
- **Governance caveat**: L2Beat classifies it "Other," not a rollup: whitelisted validators, and ArbOS 61 **transaction filtering that can nullify even force-included transactions** [V]. Mamo's "users can always withdraw" guarantee is strictly weaker here and must be disclosed honestly.
- **Morpho**: deployed as **Blue + Vaults V2** — *not* MetaMorpho V1 (no metaMorphoFactory on 4663) [V]. Vault V2 is ERC-4626 + ERC-2612, but **`maxDeposit/maxMint/maxWithdraw/maxRedeem` always return 0 by design**, and vaults can set share/asset **gates** (`canReceiveShares` etc.). Key vaults: Steakhouse USDG `0xBeEff033F34C046626B8D0A041844C5d1A5409dd` (the Earn vault, ~1.6–1.9% organic), Steakhouse Turbo USDG (~4.3%), Ethena×Steakhouse, Grove. Collateral markets: spUSDG, USDe, syrupUSDG [C/R].
- **No CoW Protocol** (confirmed by absence in cowprotocol repos for 4663) [V]. Uniswap v2/v3/v4 live with verified addresses (SwapRouter02 `0xcaf6...5cb2`), 1inch, LI.FI; UniswapX planned but unconfirmed [V/R]. **USDG depth on Uniswap ~$8.5M** — fine for reward swaps, thin for large rebalances [R].
- **Chainlink exclusive**: Data Feeds + Data Streams + CCIP from block zero; per-equity **24/5 SVR feeds** (frozen on weekends, `oraclePaused()` advisory only); **Automation NOT in the launch list — do not design keepers around it until verified** [V/C].
- **Merkl is the rewards layer** (Morpho URD deprecated chain-wide since MIP 111). The Earn subsidy is **paid in vault shares** — for the primary yield source there is *nothing to swap*; Merkl's `toggleOperator` lets each strategy authorize the Mamo backend to claim on its behalf [C/R].
- **USDG**: `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, **6 decimals, no EIP-2612 permit**, Paxos-issued, ~64–68% of the chain's stablecoin float. **Bridged USDC is effectively empty (<500 USDC) — the base asset must be USDG** [V, 6-way corroborated].

### Stock tokens
- Issuer: **Robinhood Assets (Jersey) Ltd** — tokenized *debt* notes (economic exposure, no shareholder rights), 1:1 share-backed, ~95 tickers, plain ERC-20 18dp, **blocklist not allowlist** — arbitrary contracts can hold/trade them [C].
- **ERC-8056 uiMultiplier**: corporate actions (dividends auto-reinvest, splits) adjust a display multiplier, never raw balances — vault reserve math survives corporate actions by design. **The Chainlink feed price already includes the multiplier**: use the feed for NAV and never multiply by `uiMultiplier()` again (the #1 accounting bug to avoid) [C].
- **No dividend cash flow exists on-chain** (auto-reinvested into the multiplier) — "we compound your dividends" is not a sellable feature; no options venue; no securities-lending borrow rate (shorting goes through Lighter/Arcus perps). The yield on a basket comes from the **USDG sleeve**, not the stocks [C].
- Jurisdictions: eligible in 120+ countries, **excluded: US, UK, Canada, Switzerland, UAE** + sanctioned. Front-end-enforced only; the "contracts route around geo-blocks" gap is already generating headlines (Coinfello warning, Aug 2026) and the issuer's `AccessControlsRegistry` can block a vault address in one transaction [C].
- Stock-token AUM ~$70M and growing fast, but DEX flow is >80% memecoin-driven; stock/USDG LP is adversely selected (weekend = writing a free straddle to gap traders). **No confirmed live Morpho market with stock-token collateral yet** [R].

### Competition
- **Yieldfy** (pooled ERC-4626 USDG router + off-chain optimizer, targets tokenized equities, claims Chainlink Automation) is the closest analogue — early, TVL unpublished. Quiver, HoodVault, others: weeks-old, anonymous, unaudited. **No major Base yield agent has announced Robinhood Chain plans.** The seat is contested but not taken [R].
- **Virtuals is live day one** with a ~$200M agent economy — the "AI agent" positioning fits the chain's narrative and has infrastructure to plug into [R].

---

## 2. Ranked ideas (strongest → weakest)

### #1 — Mamo Baskets: curated stock baskets + USDG yield sleeve ⭐ *prototyped, 14/14 tests green*

**One-liner:** "Own a slice of the market — and the cash half earns." Per-user strategy holding N tokenized stocks at target weights plus a Morpho USDG sleeve; the agent tilts weights, rebalances on drift bands, and keeps every idle dollar earning.

**Why it's #1:**
- It is the **only strategy surface Robinhood's 7% subsidy doesn't compete with** — Robinhood Earn is a savings product, not a portfolio product.
- **Buildable today**: unrestricted ERC-20s, per-equity Chainlink feeds, Uniswap pools, and an official Arbitrum tutorial that is literally a stock-basket dApp. The infra is unusually friendly (ERC-8056 exists precisely so vaults survive corporate actions).
- **Per-user strategies are a structural safety differentiator here, not just a preference.** The issuer can freeze/confiscate balances; every pooled competitor concentrates that blast radius across all depositors. Mamo's architecture bounds it to one user. This is a defensible, honest safety claim nobody else on the chain can make.
- Differentiated vs. every "Base clone" yield router, including Yieldfy's pooled vault.

**What the prototype proves** (`src/robinhood/StockBasketStrategy.sol`, `test/StockBasketStrategy.unit.t.sol`): deposit-to-sleeve-first (cheap deposits, agent-scheduled equity trading), two-pass drift-band rebalance (sell overweights → buy underweights → re-park remainder in sleeve), NAV preserved through oracle-parity trades, winners trimmed after price moves, withdrawals that drain sleeve first and only touch stocks when necessary, oracle-bounded router swaps that hard-revert when the pool deviates beyond slippage (the market-closed protection), and a `maxTotalStockBps` mandate the backend cannot exceed — the same "scope the agent with admin-set bounds" philosophy as the Boosted USDC pool-switching work.

**Honest caveats:** non-US TAM (also excludes UK/CA/CH/UAE); rebalance capacity caps near **$1–2M AUM per basket** on current pool depth (route via RFQ/1inch Fusion above that); needs the **market-hours oracle guard** (§5) before production; regulatory tail risk — Robinhood's composability tolerance survives until the first enforcement inquiry, and their registry can block our addresses. Ship with caps small, jurisdiction-gate our own front end, and treat legal review as a launch gate.

### #2 — The USDG multi-vault chassis: Morpho-only strategy + supply caps + scoped venues ⭐ *prototyped, 26/26 tests green*

**One-liner:** the Base architecture, generalized: per-user strategy allocating across N allowlisted ERC-4626 vaults (Steakhouse USDG, Turbo, Ethena, Grove, future curators), backend rebalances within a **multisig-scoped allowlist**, global **supply cap** meters total deposits, Merkl claims + oracle-bounded Uniswap compounding replace the CoW loop.

**Why it's #2 and not #1:** as a standalone headline it loses to the subsidized 7%. But it is (a) the **chassis every other idea runs on** — the basket's sleeve, Boosted USDG's unlevered layer, and the fee stream all live here; (b) the **cheapest port** — the audit branch's `MamoMultiMarketStrategy`/`MarketRegistry` already did the N-venue surgery, and dropping Moonwell *simplifies* it (single venue type, `getTotalBalance` becomes `view`); (c) honest positioning exists: "the agent that already runs $X on Base, now on Robinhood Chain, with more venues than Earn's single vault" — plus Merkl campaigns are open to any protocol if we ever choose to co-subsidize.

**What the prototype proves** (`src/robinhood/MorphoVaultsStrategy.sol` + `MamoVaultConfig.sol`): weight-split deposits across N vaults; supply-cap enforcement with per-strategy tracked principal (withdrawals free capacity; clamp-down accounting so yield can't underflow the global meter — the same clamp rule as the audited `hedgedDebt` maintenance); registry-authenticated strategy self-reporting (spoof-resistant via `isUserStrategy`); backend rebalancing hard-scoped to the multisig allowlist; vault removal blocks new allocations without stranding funds; two-sided compound floor `max(backendMinOut, oracleFloor)` (the audited LeveragedAero pattern); compounded yield exempt from the cap. Written against Vault V2's quirks: no `max*` reliance anywhere.

**Port notes:** reconcile `MamoVaultConfig` with the audit branch's `MarketRegistry` before shipping (one venue-registry contract, not two — adopt its append-only/soft-deactivate semantics, keep the cap accounting from this prototype). Full port sequencing in §4.

### #3 — Boosted USDG: levered carry on Morpho Blue *(2nd wave, ~6 months)*

**One-liner:** the Robinhood Chain sibling of Boosted USDC — but the venue is Morpho Blue instead of Aerodrome. Loop yield-bearing collateral (sUSDe ~4.5%, syrupUSDG ~4.6%, spUSDG ~3.2–4.2%) against USDG borrow to lever the carry spread; reported looped ROE on the chain is ~15–20% today.

**Why it matters:** it's the product that can **honestly beat the subsidized 7%** — the answer to "why not just use Robinhood Earn?" It reuses the highest-value parts of the PR #66 work: the `LeveragedAeroVault` share-ledger lifecycle (Pending/Executed/Settled, `cloneAndBind`, permissionless `redeemSettled`), the `LeveragedAeroFees` HWM/crystallization library (pure, chain-agnostic), and the deposit-cap + admin-scoped-venue governance being added for Boosted USDC. The strategy layer is *simpler* than the Aerodrome CL book — no LP legs, no tick management; the loop is deposit-collateral/borrow/re-enter with an LTV target, and `adjustLeverage`-style persistence rules carry over.

**Why not now:** carry spreads are young and partly incentive-driven; USDe/syrupUSDG depeg risk needs its own framework; liquidation sizing on a chain with sequencer/filtering centralization needs care; and the audit pipeline is already full with Boosted USDC. Spec after the chassis ships; the pooled-fund pattern is justified here (a levered book can't be sliced per user).

### #4 — MAMO flywheel: fees → stakers, and staking-gated capacity *(wire from day one)*

**One-liner:** every strategy already skims `compoundFee` (≤10%) on yield to `feeRecipient`. Point that at a `FeeSplitter` → treasury + `MultiRewards` staking, and make **supply-cap capacity itself the staking utility**.

**Design:**
- **Revenue share (reuse, near-zero new code):** `FeeSplitter` and `MultiRewards` (Synthetix fork, already handles mixed decimals) redeploy verbatim; `RewardsDistributorSafeModule` ports iff Safe is deployed on 4663 (verify; else a ~60-line Ownable-treasury variant of the same state machine). Flow: reward/basket-fee USDG → FeeSplitter → weekly "Mamo Drop" in USDG (+MAMO) to stakers. Real revenue, not emissions — the Aerodrome-fee model carried over, sourced from performance fees instead of LP fees.
- **Staking-gated capacity (new, small):** the supply cap makes capacity scarce by construction. Extend `MamoVaultConfig` with tiered carve-outs: e.g. X% of remaining capacity reserved for users staking ≥N MAMO (config already tracks per-strategy principal; the gate is a few lines in `recordDeposit`). Scarce capacity in the highest-yield products (Boosted USDG at launch, new baskets) becomes the rational reason to hold/stake MAMO. This is the cleanest "utility that creates demand" available: it costs nothing, needs no emissions, and scales with product success.
- **Not portable:** `Mamo.sol`'s Superchain bridge leg (OP-Stack predeploy) — an Orbit MAMO needs an Arbitrum-native bridge adapter or plain ERC20Votes; `BurnAndEarn`/`TransferAndEarn`/`DropAutomation` are Aerodrome-shaped end-to-end and stay behind. MAMO/USDG Uniswap pool fee capture can come later — chain DEX flow is real but memecoin-heavy today.

### #5 — Everything we evaluated and ranked out

| Idea | Verdict | Reason |
|---|---|---|
| Pure USDG router as the headline product | **Rejected as lead** | Loses to app-gated, subsidized 7% for ~a year; survives only as the chassis (#2) |
| Stock/USDG LP strategies | **6+ months out** | Adversely selected flow (memecoin pairs, weekend gap traders); needs a v4 trading-hours hook and organic two-way retail flow |
| Dividend auto-compounding | **Does not exist** | Dividends auto-reinvest inside the token's multiplier; no cash flow to capture |
| Covered calls / options overlays | **Blocked** | No on-chain equity options venue anywhere with depth |
| Securities-lending / short-interest yield | **Blocked** | Shorting routes through perps; no token borrow rate to harvest |
| Stock-token-collateral lending markets | **Watch** | Possible and intended per docs; zero confirmed live markets; weekend-gap liquidations need Fri→Mon LLTV sizing |
| Cross-issuer baskets (xStocks/Ondo/Dinari) | **Blocked for now** | None deployed or bridged to 4663 |
| NAV mint/redeem arbitrage | **Structurally blocked** | Primary market is AP-only, KYB-gated |

---

## 3. What was built in this branch (MVP evidence)

All under `src/robinhood/` + `test/`, unit-tested with mocks (no fork needed — one of the port's fringe benefits is losing the `--ffi`/fork-heavy CI path for core logic). **40 new tests, all green; full unit suite 91/91.**

| File | What it is |
|---|---|
| `src/robinhood/MamoVaultConfig.sol` | Multisig-owned venue allowlist + family-wide supply cap with registry-authenticated, clamp-down principal accounting. The Boosted USDC governance asks (admin-scoped venue switching, deposit cap) applied to the per-user model. |
| `src/robinhood/MorphoVaultsStrategy.sol` | The Base strategy generalized: N ERC-4626 vaults × bps weights, backend rebalance scoped to the allowlist, Merkl claim (configurable distributor), oracle-bounded Uniswap compound with two-sided floor, compound fee → `feeRecipient` (flywheel hook). Vault V2-aware (no `max*` reliance). |
| `src/robinhood/StockBasketStrategy.sol` | Basket + sleeve: deposit-to-sleeve, two-pass drift rebalance, `maxTotalStockBps` mandate, oracle NAV, sleeve-first withdrawals with pro-rata stock sales, every swap oracle-bounded. |
| `src/robinhood/interfaces/IUniswapV3SwapRouter.sol` | Fee-tier router interface (repo's existing `ISwapRouter` is the Aerodrome tickSpacing variant). |
| `test/MorphoVaultsStrategy.unit.t.sol` | 26 tests: split/cap/rebalance/access/compound/slippage/governance, incl. cap-capacity lifecycle and removed-vault exit safety. |
| `test/StockBasketStrategy.unit.t.sol` | 14 tests: buy-to-target, trim-winner, NAV under price moves, sleeve yield accrual, market-deviation revert, mandate enforcement. |
| `test/mocks/RobinhoodMocks.sol` | MockERC4626 (the #1 test-infra gap flagged by the portability audit), registry/oracle/router/Merkl mocks. |

Deliberate simplifications (prototype, not production): 18-dp mocks (USDG is 6 — the accounting is decimals-agnostic but tests should add a 6-dp matrix); no sequencer-uptime/market-hours staleness module yet (§5); `MamoVaultConfig` not yet reconciled with the audit branch's `MarketRegistry`; no factory/deploy scripts.

---

## 4. Port plan (from the codebase audit)

The audit branch does most of the work. Execution order:

1. **Rebase onto the multi-market work** from `feat/leveraged-aero-vanilla-vault`: `MarketRegistry`, `MamoMultiMarketStrategy`, `MultiMarketStrategyFactory`, `docs/MULTI_MARKET_DESIGN.md`.
2. **Strip to ERC-4626-only**: delete the MTOKEN arms + `IMToken` + the WETH `receive()` wrap (OP-Stack predeploy `0x4200…0006` doesn't exist on Orbit); `_getTotalBalance` becomes `view`.
3. **Delete the CoW leg entirely** (~150 lines: `isValidSignature`, appData JSON reconstruction, `DOMAIN_SEPARATOR`, `VAULT_RELAYER`, the standing max approval) and adopt the router compound with `max(backendMinOut, oracleFloor)` — the pattern already on the audit branch in `MamoStakingStrategy.compound()`. Fee becomes a plain transfer instead of a CoW pre-hook. CI loses `--ffi` and the CoW SDK dependency.
4. **Oracle layer**: `SlippagePriceChecker` ports nearly as-is (`AggregatorV3Interface` is live), but add (a) a sequencer-uptime feed check, (b) the market-hours-aware staleness policy for equity feeds (§5). Chain-specific constants (`MERKLE_PROTOCOL_DISTRIBUTOR`, currently a hardcoded `constant`) become init/config parameters.
5. **Merge the cap/allowlist**: one venue-registry contract — `MarketRegistry`'s append-only/soft-deactivate semantics + `MamoVaultConfig`'s supply cap and strategy authentication.
6. **Config/deploy**: new `addresses/4663.json`, adopt the audit branch's `markets[]` config schema (drop `moonwellMarket`/`metamorphoVault` scalars), parameterize the three hardcoded keys in `DeploySystem.s.sol`; copy the `011_DeployMultiMarketSystem` proposal pattern. Verify Cancun/via-IR support on the Orbit node (audit-branch code uses transient-storage `ReentrancyGuardTransient`).
7. **Flywheel** (§2 idea 4) once fees flow.

**Registry, `BaseStrategy`, `MamoStrategyRegistry`, `Multicall`, `FeeSplitter`, `MultiRewards`, staking factory: port verbatim.** `StrategyFactory` is superseded by the multi-market factory. `BurnAndEarn`/`TransferAndEarn`/`DropAutomation`/`Mamo.sol`'s Superchain leg stay behind.

---

## 5. The market-hours oracle guard (required infra, unbuilt)

Every stock-token-touching product needs one shared module; nobody on the chain appears to have built it well, which makes it quiet moat:

- **NYSE-calendar-aware staleness**: equity feeds freeze on weekends/holidays with no heartbeat; a naive "revert if stale" bricks every weekend, no check at all means trading at Friday's price on Sunday. Policy: market-open → tight staleness bound; market-closed → NAV *views* may serve the last price flagged stale, but **state-changing paths that price equities (rebalance, stock sales) hard-halt**; sleeve-only operations (deposit, sleeve-covered withdrawals) continue 24/7. The basket prototype's deposit-to-sleeve and sleeve-first-withdrawal design was chosen precisely so the *common* paths never need an equity price.
- **`oraclePaused()` + staged `newUIMultiplier`/`effectiveAt`** checks around corporate actions (advisory per Robinhood docs — the independent `updatedAt` check remains primary).
- **Sequencer-uptime feed** check on every oracle read (standard Arbitrum-family practice; mandatory given the chain's centralization profile).

---

## 6. Verification checklist before any further commitment

Single reads/calls, blocked from this environment (RPC egress denied), cheap from anywhere else:

1. **Vault V2 gates on the Steakhouse vaults**: `receiveSharesGate()`/`sendSharesGate()` on `0xBeEff033…`. If a gate blocks third-party contracts, the chassis needs different target vaults — this one read could reshape idea #2.
2. `eth_getCode` the Morpho/Uniswap addresses above (SDK-sourced, not chain-verified).
3. **USDG depth + realistic slippage** at our trade sizes on Uniswap v3/v4; stock/USDG pool depth for the basket's rebalance cap.
4. Chainlink feed directory for 4663 (`feeds-robinhood-mainnet.json`): confirm USDG/USD exists + per-equity feed coverage, heartbeats, decimals.
5. Chainlink Automation / Gelato presence (keeper design), Safe deployment (RewardsDistributorSafeModule), MORPHO token bridged or not.
6. Whether any live Morpho market takes stock-token collateral (idea-#3 adjacency).
7. **Legal**: the Jersey base prospectus — whether third-party contracts holding tokens for mixed-jurisdiction users is a technical gap or a contractual breach; policy on vault addresses. This gates Mamo Baskets' launch scope.
8. Gas-subsidy expiry (~Sept 29, 2026) → post-subsidy rebalance economics for per-user strategies.

## 7. Suggested sequencing

1. **Now**: run §6 checklist; legal review of the stock-token envelope; reconcile venue-registry design.
2. **Wave 1 (chassis + baskets)**: port per §4; ship USDG chassis with conservative caps + 2–3 curated baskets (e.g. MAG7, AI, Blue-chip) jurisdiction-gated on our front end; flywheel wired (fees → stakers), staking-gated capacity from the first capped product. Positioning: "the yield agent with a portfolio brain — and per-user vaults that don't pool your risk."
3. **Wave 2**: Boosted USDG levered carry (the honest 7%-beater) through the same audit pipeline as Boosted USDC; deepen basket liquidity routing (RFQ/Fusion); revisit stock-collateral markets and LP strategies as depth matures.

The window is real but not indefinite — competitors are weeks old and unaudited, no Base incumbent has moved, and Mamo's audit history + per-user custody story is exactly the trust wedge this chain's early honeypot-ridden ecosystem lacks.
