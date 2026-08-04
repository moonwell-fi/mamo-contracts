# Mamo on Robinhood Chain — Execution Plan

*Companion to `ROBINHOOD_CHAIN_SPEC.md` (research + ranked ideas). This is the forward plan: current status, deep dives on the lead products, the fork-test runbook for the next session, and the wave 1 / wave 2 build plan.*

---

## 1. Status snapshot (branch `claude/mamo-robinhood-chain-04xxwe`)

| Layer | Artifact | State |
|---|---|---|
| Research | `docs/ROBINHOOD_CHAIN_SPEC.md` | Chain findings, ranked ideas, port plan, risks. RPC-unverified facts flagged in §6. |
| Chassis MVP | `src/robinhood/MorphoVaultsStrategy.sol` + `MamoVaultConfig.sol` | 26 unit tests green. Supply cap + multisig-scoped venue allowlist + Merkl claim + oracle-bounded Uniswap compounding. |
| Baskets MVP | `src/robinhood/StockBasketStrategy.sol` | 14 unit tests green. Drift-band rebalance, equity mandate cap, sleeve-first withdrawals. |
| Real-bytecode validation | `test/MorphoVaultsStrategyVaultV2.integration.t.sol` + `test/vendor/` | 25 tests green against genuine compiled Morpho Vault V2 (`make robinhood-vaults-v2`). No bugs found in `src/robinhood/`. |
| Fork suite (armed) | `test/RobinhoodFork.integration.t.sol` | Env-gated on `ROBINHOOD_RPC_URL`; skips cleanly without it (`make robinhood-fork`). Smoke-tested against a staged chain-4663 anvil. |

Key facts proven against real Vault V2 bytecode (not mocks): the no-`max*` design is correct; withdraw math settles exactly under live vault fees (256-run fuzz); donations are invisible until an allocator sets `maxRate` (yield ≠ vault balance); interest accrues once per transaction (Multicall batching gets one snapshot); 6-dp assets mint 18-dp shares (`virtualShares = 1e12`); a `sendSharesGate` can trap a funded position — gates need ongoing monitoring.

---

## 2. Deep dive: Mamo Baskets (lead product)

**Product.** Per-user strategy holding N tokenized stocks at target weights plus a USDG sleeve in Morpho vaults. USDG in, USDG out; the agent tilts weights inside a hard `maxTotalStockBps` mandate, rebalances on drift bands, keeps idle cash earning. Launch baskets: **Mag7**, **AI**, **Blue-chip + Yield** (30/70 conservative). Each basket is a registry strategy type; each user's basket is their own contract.

**Why it leads.**
1. *Uncontested lane.* Robinhood Earn is a subsidized ~7% savings product, app-gated. A portfolio product competes with "holding stock tokens idle" (~$70M and growing), not with the subsidy. Nobody pays users to hold NVDA-token; Mamo would.
2. *Infra is ready.* Stock tokens are plain ERC-20s (blocklist, not allowlist); per-equity Chainlink 24/5 feeds; ERC-8056 keeps raw balances stable through corporate actions and the feed price already includes the multiplier — oracle-NAV accounting is correct by construction (never multiply by `uiMultiplier()` again).
3. *Per-user contracts are safety architecture here.* The Jersey issuer retains pause/burn/confiscate powers. Pooled vaults concentrate that blast radius; per-user strategies bound it to one user. A true, differentiated safety claim consistent with Mamo's Base story.
4. *Mechanics proven.* 14 tests: buy-to-target, trim-winner after 2x move, NAV preservation at oracle parity, sleeve yield accrual, oracle-deviation revert (the market-closed guard), mandate enforcement, sleeve-first exits.
5. *Graceful market-hours degradation.* Deposits land in the sleeve; withdrawals drain sleeve first. Common paths never need an equity price; only large exits during closed markets hit the oracle guard — and reverting there is correct.

**Economics.** User: equity performance on the stock share + ~2–4.5% organic sleeve yield on the rest (≈1–1.8% yield floor on a 60/40). Mamo: `compoundFee` (≤10% of yield) on the sleeve + a basket management fee (50–95bps precedent) → FeeSplitter → MultiRewards → weekly Drop. Capacity: ~$1–2M/basket on current pool depth; mitigate with small launch caps (which feed the staking-gated-capacity flywheel), RFQ routing (0x RFQ / 1inch Fusion) for size, and wide drift bands. Engineer against Index Coop's failure mode: never bleed NAV as a taker on routine rebalances.

**Risks.** Regulatory (the gate): tokens barred to US/UK/CA/CH/UAE persons; composability is the documented leak vector; geo-gate our front end, legal review of the Jersey prospectus is a launch gate; issuer can blocklist our contracts in one tx. Oracle/market-hours: the guard module (§5 of the spec) is a hard prerequisite. Issuer powers: bounded by per-user architecture, disclosed honestly. Liquidity: caps + RFQ + drift bands.

## 3. Deep dive: Boosted USDG (wave 2 headline)

**Product.** The Robinhood sibling of Boosted USDC with Morpho Blue as the venue: loop yield-bearing collateral (sUSDe ~4.5%, syrupUSDG ~4.6%, spUSDG ~3.2–4.2%) against USDG borrow at a target LTV. Reported looped ROE ~15–20% today; even compressed it clears the subsidized 7% honestly — the answer to "why not just use Robinhood Earn?"

**Why it's cheap for us.** It reuses the audited Boosted USDC stack minus the hard parts: `LeveragedAeroVault` share-ledger lifecycle (Pending/Executed/Settled, atomic `cloneAndBind`, permissionless `redeemSettled`), the `LeveragedAeroFees` HWM/crystallization library (pure, chain-agnostic), and the deposit-cap + admin-scoped-venue governance. No LP legs, no tick management, no hedge drift — the new work is the loop engine (with the `adjustLeverage` target-persistence lesson applied) and the risk framework.

**Why wave 2.** Carry spreads are young and partly incentive-driven; USDe/syrupUSDG depeg risk needs its own framework; liquidation sizing on a centralized-sequencer chain needs care; the audit pipeline is full with Boosted USDC. Pooled shape is correct (a levered book can't be sliced per user) — and makes it the natural first **staking-gated, hard-capped** launch for MAMO utility.

---

## 4. Fork-test runbook (next session, once the RPC is allowlisted)

Prereq: environment network policy allows `rpc.mainnet.chain.robinhood.com` (custom allowed domains + default package managers; changes apply to NEW sessions only).

**Environment bootstrap** (this container ships without foundry; direct installers are proxy-blocked, GitHub releases work):

```bash
mkdir -p ~/.foundry/bin ~/.svm/0.8.28 ~/.svm/0.5.17
curl -sSL -o /tmp/foundry.tar.gz https://github.com/foundry-rs/foundry/releases/download/stable/foundry_stable_linux_amd64.tar.gz
tar -xzf /tmp/foundry.tar.gz -C ~/.foundry/bin && export PATH="$PATH:$HOME/.foundry/bin"
curl -sSL -o ~/.svm/0.8.28/solc-0.8.28 https://github.com/ethereum/solidity/releases/download/v0.8.28/solc-static-linux
curl -sSL -o ~/.svm/0.5.17/solc-0.5.17 https://github.com/ethereum/solidity/releases/download/v0.5.17/solc-static-linux
chmod +x ~/.svm/*/solc-*
git submodule update --init --recursive
```

**Run the fork suite:**

```bash
export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
make robinhood-fork          # or: forge test --ffi --match-path "test/RobinhoodFork.integration.t.sol" -vvv
```

If `deal()` cannot rewrite Paxos' USDG balance storage, set `ROBINHOOD_USDG_WHALE=<holder address>` (find one on robinhoodchain.blockscout.com) and re-run.

**What the results mean:**

| Check | GO | NO-GO / action |
|---|---|---|
| Steakhouse vault gates (all four read, verdict logged) | All `address(0)` → chassis works against the Earn vault as-is | Receive gate set → target Turbo/Ethena/Grove vaults instead, or seek whitelisting; **send gate set → do not allocate there at all** |
| USDG `decimals()==6` at `0x5fc5360D…` | Config matches | Re-derive addresses from Blockscout; update spec §1 |
| Vault `max* == 0`, `virtualShares == 1e12` | V2 semantics confirmed live | If it's NOT V2, re-audit the venue assumption (unlikely) |
| SwapRouter02 code at `0xcaf681a6…` | Compound path viable | Find the live router via Uniswap deploy logs |
| Funded E2E deposit→balance→withdraw→exit | Strategy works against the live adapter-backed vault | An exit failure here = Morpho Blue market illiquidity — size caps accordingly |

**Then, still on the fork:** run the remaining spec §6 checklist — Chainlink feed directory (USDG/USD + per-equity feeds, heartbeats), realistic USDG swap slippage at target trade sizes via the live Quoter, stock/USDG pool depth for basket sizing, Safe deployment (for `RewardsDistributorSafeModule`), Chainlink Automation/Gelato presence, MORPHO token bridged or not. Record verified values in spec §1 and flip its confidence tags to [V].

**Optional next fidelity step:** a fork-based variant of the basket suite against 2–3 real stock tokens (addresses from the on-chain registry) and their live feeds/pools.

---

## 5. Wave 1 build plan (chassis + baskets, after fork verification passes)

1. **Rebase onto the audit branch's multi-market work** (`MarketRegistry`, `MamoMultiMarketStrategy`, `MultiMarketStrategyFactory`); strip MTOKEN arms; fold `MamoVaultConfig`'s supply cap + strategy authentication into `MarketRegistry`'s append-only/soft-deactivate shape (one venue registry, not two).
2. **Market-hours oracle guard module** (spec §5): NYSE-calendar staleness policy, `oraclePaused()`/staged-multiplier checks, sequencer-uptime feed. Required for any stock-token product; reusable moat.
3. **Vault-gate monitor**: off-chain watch on all four gates of every allowlisted vault (the `sendSharesGate` trap found in real-bytecode testing).
4. **Factory + deploy tooling**: basket/chassis factories on the multi-market factory pattern, `addresses/4663.json`, `deploy/4663_*.json`, config schema per spec §4; parameterize the three hardcoded keys in `DeploySystem.s.sol`.
5. **Flywheel wiring**: redeploy `FeeSplitter` + `MultiRewards` (+ `RewardsDistributorSafeModule` iff Safe exists on 4663, else the Ownable-treasury variant); point `feeRecipient` at the splitter; extend the config with staking-gated cap carve-outs.
6. **Legal gate (parallel track)**: Jersey base prospectus review — third-party contracts holding stock tokens for a mixed-jurisdiction user base: technical gap or contractual breach; front-end geo-gating scope.
7. Launch posture: small supply caps, 2–3 curated baskets, geo-gated front end, honest disclosure of chain-level guarantees (ArbOS filtering, issuer powers).

## 6. Wave 2 (Boosted USDG)

Spec + risk framework first (depeg scenarios for USDe/syrupUSDG, Fri→Mon liquidation sizing, sequencer-halt behavior), then the loop engine on the `LeveragedAeroVault` lifecycle + `LeveragedAeroFees`, through the same audit pipeline as Boosted USDC. First staking-gated hard-capped launch. Revisit as promotions fade: organic borrow demand is the number that decides sizing.
