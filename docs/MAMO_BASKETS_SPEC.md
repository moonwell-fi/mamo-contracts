# Mamo Baskets — Product Specification

*Status: product spec for the Robinhood Chain lead product. Grounded in the on-chain verification of 2026-08-04 (`docs/ROBINHOOD_CHAIN_SPEC.md` §1, all [V] tags) and the live-market fork suites in this branch. The contract exists and trades on the live chain; it is **not** audited, not fee-wired, not cap-wired, and not deployed. This document gates further engineering: it fixes the launch lineup, the parameters, and the open items.*

*Companions — read rather than duplicated here: `docs/ROBINHOOD_CHAIN_SPEC.md` (chain facts, ranked ideas, port plan, the market-hours guard design in its §5), `docs/ROBINHOOD_PLAN.md` (§2 basket deep dive, §4 executed fork runbook, §5 wave-1 build plan), `docs/ROBINHOOD_TENDERLY_AUTOMATIONS.md` (keeper design, being specced in parallel).*

---

## 1. Summary

**Mamo Baskets** is a per-user, agent-managed portfolio of tokenized equities plus a USDG yield sleeve, on Robinhood Chain (chain 4663). USDG in, USDG out. The user picks a basket; their own contract holds the stock tokens at target weights and parks everything else in a Morpho USDG vault; the Mamo agent builds and rebalances the basket inside a hard, admin-set mandate.

Three things make it worth building rather than porting another yield router:

1. **Subsidy-immune surface.** Robinhood Earn pays a subsidized ~7% on USDG savings, app-gated, for roughly a year. A yield router loses to that in the incumbent's own app. A portfolio product does not compete with it at all — it competes with holding stock tokens idle, which is ~$70M of dead assets today. Nobody pays users to hold NVDA-token; we would.
2. **Per-user custody as a safety claim, not a preference.** The Jersey issuer retains pause, burn and confiscate powers, and its `AccessControlsRegistry` can blocklist a contract address in one transaction. Every pooled competitor concentrates that blast radius across all depositors. One user's basket is one user's contract. This is the only honest differentiated safety claim available on this chain.
3. **Every idle dollar earns.** The cash half sits in the Steakhouse USDG Vault V2 (~$269.6M TVL) from the moment of deposit, not in a hot wallet awaiting a build.

**Headline verified numbers.** A full live round trip — deposit 2,000 USDG → agent rebalance to a 45% NVDA/AAPL/TSLA basket → `withdrawAll` — cost **26 bps of NAV**, executed against real Chainlink feeds, real 0.30% Uniswap pools and the real Steakhouse vault. The rebalance leg alone drifted 17 bps and landed the mix at 4490/5509 bps against a 4500/5500 target. Per-leg pool-vs-oracle cost including the 30 bps pool fee: NVDA 26 bps, AAPL 52 bps, TSLA 49 bps.

**Launch shape.** Two baskets, hard-capped, geo-gated, small:

| Basket | Composition | Stock/sleeve | Supply cap |
|---|---|---|---|
| Mamo AI & Mega-cap Tech | NVDA 30% / AAPL 15% / GOOGL 8% / TSLA 7% | 60 / 40 | $750k |
| Mamo Blue-chip Index + Yield | SPY 30% | 30 / 70 | $350k |

$1.1M of combined capacity at full caps. That is small on purpose: capacity is the binding constraint (§3e), and scarce capacity is the MAMO staking utility (§2).

---

## 2. Product description

### The user journey

**Deposit.** The user approves USDG and calls `deposit(amount)`. The whole amount goes straight into the yield sleeve — no equity is bought. This is deliberate: deposits are cheap, they work at 3am on a Sunday when every equity feed is frozen, and equity trading stays on the agent's schedule rather than the depositor's. USDG has EIP-2612 permit, so a one-transaction permit deposit is available in the front end.

**Build.** On its next scheduled pass, the agent calls `rebalance(minTradeValue)`. The contract sells overweights, buys underweights, and re-parks the remainder in the sleeve. Every swap carries an oracle-derived `amountOutMinimum`, so the agent chooses *when* to trade and never *at what price*.

**Weekly experience.** The basket tracks its targets within the drift band; the sleeve accrues; the user sees one NAV in USDG. Fees flow to the MAMO flywheel and come back to stakers as the weekly Drop. Equity trading pauses roughly 50 hours every weekend and on market holidays (§4) — the position simply sits.

**Withdraw.** `withdraw(amount)` drains idle USDG first, then the sleeve, and only sells stock pro-rata if those two cannot cover it. `withdrawAll()` liquidates everything. In practice the common exit — a partial withdrawal smaller than the sleeve — never touches an equity pool, which is what makes the market-hours halt survivable rather than a product defect.

### Why not just hold the stocks yourself?

The question every reviewer should ask, so it goes in the spec. For a single-stock buy-and-holder we have no pitch, and the copy must never pretend otherwise. The product is for portfolio holders, and the value stack is concrete:

1. **The cash half works.** A self-directed holder's dry powder sits in wallet USDG earning zero (Robinhood Earn is app-gated savings, disconnected from a portfolio). Here every idle dollar is in the sleeve from the moment of deposit.
2. **Execution they can't easily replicate.** One USDG ticket becomes a weighted basket instead of four manual DEX swaps through the same pools at the same-or-worse spreads — and every fill is oracle-bounded, so the user structurally cannot trade against a frozen weekend price or a manipulated pool, which a manual trader can and will. The measured 26 bps round trip at retail size is competitive with careful manual execution and strictly better than careless.
3. **Portfolio hygiene nobody does by hand.** Drift-band rebalancing and winner-trimming, on schedule, inside a mandate the agent cannot exceed.
4. **Custody preserved.** It is the user's own contract, not a pooled fund; sleeve-covered withdrawals work 24/7.

Dividends are a wash against self-custody — the issuer auto-reinvests them into the multiplier for every holder equally. What we charge for the difference is the 50 bps management fee on the equity share.

### Fee model

Two legs, both matching existing repo precedent:

- **`compoundFee` ≤ 10% of sleeve yield** — the chassis constant (`MorphoVaultsStrategy.MAX_COMPOUND_FEE = 1000`).
- **Basket management fee, 50 bps/yr, charged on the equity share of NAV only** — the bottom of the 50–95 bps precedent band, and charged on the equity share rather than on total NAV.

Both route `feeRecipient` → `FeeSplitter` → `MultiRewards` → weekly Drop.

The reason for both choices is arithmetic, and it is the least comfortable number in this document:

| | Basket 1 (60/40) | Basket 2 (30/70) |
|---|---|---|
| Sleeve share of NAV | 40% | 70% |
| Sleeve gross yield @ 1.6–1.9% (Steakhouse today) | 64–76 bps | 112–133 bps |
| less `compoundFee` (10% of sleeve yield) | 6–8 bps | 11–13 bps |
| less management fee @ 50 bps on equity share | 30 bps | 15 bps |
| **Net cash yield to user** | **28–38 bps** | **86–105 bps** |

At the top of the precedent band (95 bps on the equity share) Basket 1's net cash yield is 1–11 bps — the fee consumes the entire sleeve. **A 60/40 basket cannot carry a 95 bps fee at today's Steakhouse yield.** Two things restore headroom, neither available today: routing the sleeve to a 2–4.5% curated vault (Turbo / Ethena / Grove, all unverified — §7), or a higher equity share, which capacity does not permit. Until then, 50 bps.

The honest positioning that follows: **the sleeve is not the return driver — equity performance is.** The sleeve makes the cash half non-dead and pays most of the management fee. We should say exactly that and not imply a yield product.

**What we report as yield: no blended basket APY, ever.** Most of the return is equity performance, which is not an APY; projecting it as one invites both user harm and exactly the regulatory attention a securities-adjacent product cannot afford. The UI shows two separate numbers: the **live sleeve APY** read from the vault (~1.6–1.9% today; net ~1.4–1.7% on sleeve dollars after `compoundFee`) and **basket price performance** as a return, not a rate. Merkl or Drop rewards are quoted as variable, never projected. If the curated 2–4.5% vaults verify (§7 item 6), the cash-yield line improves materially: with a 4.3% sleeve, Basket 1's net cash yield rises from 28–38 bps to ~125 bps of NAV, Basket 2's from 86–105 bps to ~256 bps.

**How the user is paid, mechanically.** Everything accrues in NAV and realizes in USDG on withdrawal — no claim flows. Three streams: equity marked to the Chainlink feeds; sleeve yield via `steakUSDG` share-price appreciation; Merkl rewards, when campaigns pay the strategy, compounded into the sleeve minus the fee. Dividends *do* reach the user economically — the feed price includes the multiplier, so issuer-reinvested dividends surface as NAV appreciation (§2, "What the user actually holds").

**Revenue at the launch caps, honestly.** Basket 1 at a full $750k: 50 bps × 60% equity = $2,250/yr management, plus ~$525/yr from `compoundFee` on the sleeve. Basket 2 at $350k: ~$525 + ~$430. **Total ≈ $3.7k/yr at full launch caps — a rounding error, and the spec should say so before anyone else does.** The launch buys the uncontested seat and proves the flywheel; the revenue line scales with caps (which scale with pool depth), with sleeve yield (curated vaults), and above all with wave-2 Boosted USDG, which is pooled and has no per-name capacity ceiling. After the gas subsidy expires (~2026-09-29), backend-paid rebalance gas nets against this fee base — the re-check is already on the clock (§7).

### The MAMO flywheel hook

Fees are real revenue, not emissions. `FeeSplitter` and `MultiRewards` redeploy verbatim; `RewardsDistributorSafeModule` ports as-is (Safe 1.3.0 + 1.4.1 are fully deployed on 4663 and in production use — Morpho Blue's own owner is a 5-threshold Safe). Separately, the supply cap makes capacity scarce by construction — and the scarcity is measured, not manufactured — so a staking-gated carve-out in `MamoVaultConfig` — X% of remaining capacity reserved for users staking ≥ N MAMO — turns the cap into MAMO utility at essentially zero code cost. Wave-2 Boosted USDG, the product that honestly beats the subsidized 7%, is the natural first fully staking-gated, hard-capped launch. See `ROBINHOOD_CHAIN_SPEC.md` §2 idea 4.

**MAMO reaches 4663 via Wormhole — we bridge it ourselves, and the infra is ready.** (`Mamo.sol`'s Superchain bridge leg does not port to Orbit; Wormhole is our path and is already operational for MAMO.) Sequencing is deliberately decoupled from launch: fees accrue from day one regardless. Until the bridge is live, the weekly Drop pays in USDG and the staking-gated carve-out is enforced against backend-attested Base staking balances; once MAMO is native on 4663, the Drop can pay USDG + MAMO and gating can move fully on-chain. Not launch-blocking, but the bridge should land before the first staking-gated cap raise so the utility story is native when it matters.

### What the user actually holds

A `StockBasketStrategy` behind an ERC1967 proxy, owned by them, registered to them in `MamoStrategyRegistry`. Inside it: ERC-20 tokens issued by **Robinhood Assets (Jersey) Ltd** — tokenized *debt notes* giving economic exposure to the reference share, 1:1 share-backed, with **no shareholder rights and no voting** — plus `steakUSDG` shares of the Steakhouse USDG Vault V2.

There is **no dividend cash flow**. Dividends auto-reinvest into the ERC-8056 `uiMultiplier` rather than paying out. The economics still reach the user: the Chainlink feed price includes the multiplier, so reinvested dividends surface as NAV appreciation. But the issuer does that compounding, not us — "we compound your dividends" is not a feature we have, and the multiplier mechanism is real and live (CRWD carries `uiMultiplier() == 4e18` from an actual 4:1 split).

### What we promise, and what we do not

**We promise:** USDG in, USDG out. The user is the sole owner: only they can withdraw, only they can initiate an upgrade, and only to an implementation the registry has whitelisted for their strategy type. The backend can never exceed `maxTotalStockBps`, never trade outside the oracle bound, and never move funds to an address of its choosing. Deposits and sleeve-covered withdrawals work 24/7.

**We do not promise:** dividend capture or shareholder rights (neither exists); tracking-error bounds against the underlying index; uninterrupted equity trading (feeds and therefore trading halt ~50h per weekend and through holidays — an ~80h freeze was observed over July 4); chain-level censorship resistance (ArbOS transaction filtering can nullify even force-included transactions, so Mamo's usual "you can always withdraw" guarantee is strictly weaker here and must be disclosed); immunity from the issuer's pause/burn/confiscate/blocklist powers; availability to US, UK, Canadian, Swiss or UAE persons; index-fund capacity.

---

## 3. Launch baskets

This is the decision section. The lineup is derived from constraints, not from marketing appeal — and the constraints kill the obvious lineup.

### (a) The eligibility rule

A ticker is eligible only if it clears **all three** gates:

1. **A genuine Chainlink feed exists.** 35 equity-type feeds are live (28 single names + 7 ETF/commodity) against ~95 issued tickers — roughly one third. The feed set, not the token set, defines the universe. There are also 31 decoy "dividends.finance" feeds covering exactly the tickers Chainlink does not, with plausible descriptions, no round history and implausible prices: **never enumerate feeds by description.**
2. **Real pool depth, not listing dust.** Ten tickers hold genuine per-name v3 USDG depth; roughly thirty more hold only ~$1.4k of listing seed.
3. **A non-trivial single trade clears 100 bps** at the sizes rebalancing actually requires, measured on the live QuoterV2 across v3 + v4.

Applied to the measured data:

| Ticker | Feed | v3 USDG depth | Largest trade < 100 bps (v3+v4) | Verdict |
|---|---|---|---|---|
| NVDA | yes | $779k | ~$170k | **Core** — the only name with real two-tier depth |
| AAPL | yes | $69k | ~$60k | **Core** |
| SPY | yes (ETF) | $144k | ~$34k | **Core** |
| GOOGL | yes | $56k | ~$20k | **Core** |
| SPCX | yes | $382k | ~$20k | Deep, but blocked — underlying unidentified (§3b) |
| TSLA | yes | $63k | ~$16k | **Core** |
| COST | yes | $70k | not measured | Reserve — quote it before use |
| QQQ | yes (ETF) | $73k | ~$4k | Reserve — too thin to build against |
| GME | yes | $218k | **$0** | Rejected |
| SLV | yes (commodity) | $185k | **$0** | Rejected |

Eight names pass gates 1 and 2; five have a measured trade cap large enough to build a position against. **Depth and tradeable capacity are not the same quantity** — GME and SLV rank third and fourth on depth and are entirely untradeable, because their liquidity sits only in 1% fee tiers where the fee alone consumes the whole 100 bps budget. Rank on the trade cap, never on TVL.

### (b) The proposed lineup

**Basket 1 — "Mamo AI & Mega-cap Tech".** NVDA / AAPL / GOOGL / TSLA, 60% equity / 40% sleeve, cap $750k.

Weights are tilted toward depth rather than toward market cap. Pure depth-proportional weighting of the four trade caps (170/60/20/16) would put NVDA at 64% of the equity share, which is a single-name position wearing a basket's name. The proposed split — NVDA 50% of equity, AAPL 25%, GOOGL 13%, TSLA 12% — keeps NVDA dominant enough that most rebalance flow lands in the one pool that can absorb it, while remaining recognisable as a four-name basket. Equity share is 60% because it is the highest share the capacity math tolerates at this cap (§3e) and because the sleeve share must still cover most of the fee (§2).

**Basket 2 — "Mamo Blue-chip Index + Yield".** SPY only, 30% equity / 70% sleeve, cap $350k.

Conservative by construction, and the basket where "the idle half earns" is actually true (86–105 bps net cash yield versus 28–38 bps for Basket 1). **We recommend launching SPY-only rather than SPY + QQQ.** QQQ's 100 bps trade cap is ~$4k. Adding it at even a 5% weight would cut the single-clip build limit from $113k to $80k and add a leg that fails to fill on any adverse day. Add QQQ as a second slot only once its measured 100 bps cap exceeds ~$15k.

Cap math, shown in full:

```
SPY 100bps trade cap                      = $34,000
SPY weight of NAV                         = 30%
drift band (relative, per leg)            = 10%
rebalance trade at cap  = 10% x 30% x AUM = 0.03 x AUM
binding condition       0.03 x AUM        <= $34,000
theoretical AUM ceiling                   = $1.13M
safety factor (weekend depth loss, multi-leg simultaneity, one-sample cost data)  = 3.2x
launch cap                                = $350k
single-clip build limit = $34,000 / 0.30  = $113k  ->  round down to $100k
```

**Candidate 3 — "SPCX + Yield".** SPCX has the second-deepest USDG pool on the chain ($382k), a Chainlink feed, and a ~$20k trade cap — mechanically it is a viable single-name basket at a ~$250k cap and $80k clips. **It is blocked, and not on liquidity grounds.** We have not verified what instrument the SPCX token actually references, nor that the Chainlink feed under that ticker references the same instrument. Both must be established from the issuer's documentation and the Chainlink docs directory before it can be listed. A deep pool against a misunderstood underlying is a worse failure than a thin pool against a known one. Do not assert the underlying in any user-facing copy until this is closed.

### (c) Explicitly rejected for now

- **Mag7.** MSFT, AMZN and META hold only ~$1.4k of listing-seed dust each. **A true Mag7 basket is not currently buildable at any size.** This supersedes `ROBINHOOD_PLAN.md` §2 and `ROBINHOOD_CHAIN_SPEC.md` §7, both of which list Mag7 as a launch basket — they predate the liquidity measurement.
- **GME, SLV.** Zero capacity at 100 bps: 1%-fee-tier-only liquidity, where the fee alone exhausts the slippage budget. Deep on paper, untradeable in practice.
- **Roughly two thirds of the ticker universe.** No Chainlink feed, therefore no NAV and no oracle bound, therefore no product.
- **Any name whose only "feed" is a dividends.finance decoy.** These cover precisely the tickers Chainlink does not, which makes them exactly the trap a naive feed-discovery script falls into.
- **COST.** Passes feed and depth ($70k, comparable to AAPL) but has no measured 100 bps quote. Cheap to resolve; do it before considering a five-name Basket 1.

### (d) Per-basket parameters

| Parameter | Basket 1 — AI & Mega-cap Tech | Basket 2 — Blue-chip Index + Yield |
|---|---|---|
| `stockTokens` | NVDA `0xd0601ce1…`, AAPL `0xaf3d76f1…`, GOOGL, TSLA `0x322f0929…` | SPY `0x117cc213…` |
| `stockWeightsBps` | 3000 / 1500 / 800 / 700 | 3000 |
| Equity / sleeve target | 6000 / 4000 | 3000 / 7000 |
| `maxTotalStockBps` (mandate) | 6500 | 3500 |
| `yieldVault` | Steakhouse USDG Vault V2 `0xBeEff033…` | same |
| `poolFee` | 3000 (0.30%) | 3000 (0.30%) |
| `allowedSlippageInBps` | 150 | 150 |
| Supply cap | $750k | $350k |
| Single-clip build limit | $200k | $100k |
| TWAP cadence above the clip | ≤ $200k per clip, ≥ 15 min apart | ≤ $100k per clip, ≥ 15 min apart |
| Drift band (backend policy) | ±10% relative per leg | ±10% relative |
| `minTradeValue` per call | max(0.5% of NAV, 50 USDG) | max(0.5% of NAV, 50 USDG) |

Notes on the judgment calls:

- **Mandate above target.** `maxTotalStockBps` is set 500 bps above the equity target so the agent can tilt without the mandate becoming a straitjacket, while the hard ceiling still binds. The fork suite runs the same shape (4500 target under a 6000 mandate).
- **`poolFee` is one value for the whole basket.** All five core names quote against USDG in the 0.30% tier today, so a single tier works. NVDA's two-tier depth means it could route through the 0.05% tier and save 25 bps on the largest leg in the largest basket — but `poolFee` is a single `uint24` on the contract. **Per-stock fee tiers plus v4 routing are a planned contract change worth roughly 2x capacity** (§7).
- **150 bps slippage.** Three times the worst measured per-leg deviation (AAPL, 52 bps including the pool fee), half the 300 bps the fork suite used, and far inside the contract's `MAX_SLIPPAGE_IN_BPS` of 2500. Tight enough that the bound binds on a bad print; loose enough that ordinary rebalances fill. A failure here is a revert and a retry, not a loss.
- **`setSlippage` is `onlyOwner` — the user, not the backend.** Good governance (the agent can never widen its own bound) with a sharp edge: a user could set 2500 bps and a subsequent backend rebalance would trade up to 25% off oracle. **Recommend lowering `MAX_SLIPPAGE_IN_BPS` to 500 in the basket implementation** (§7).
- **The drift band is off-chain policy, not a contract invariant.** On-chain the agent may call `rebalance` at any time; what the contract enforces is the mandate, the `minTradeValue` dust filter and the oracle bound. Stated plainly because it changes what an auditor should look for.

### (e) Capacity math, honestly

The binding constraint is the **thinnest leg**, not the basket average. For a basket with name *i* at weight *w<sub>i</sub>* of NAV, a relative drift band *d*, and a measured 100 bps trade cap *T<sub>i</sub>*:

```
rebalance trade for leg i  ~=  d x w_i x AUM        must be <=  T_i
AUM_max = min over i of  ( T_i / (d x w_i) )
```

For Basket 1 at d = 10%:

| Leg | *T<sub>i</sub>* | *w<sub>i</sub>* | AUM ceiling |
|---|---|---|---|
| NVDA | $170k | 30% | $5.67M |
| AAPL | $60k | 15% | $4.00M |
| GOOGL | $20k | 8% | $2.50M |
| TSLA | $16k | 7% | **$2.29M ← binding** |

The published capacity envelope from the fork measurement work is **$750k–$1M for a five-name deepest-ticker basket at ≤10% drift** and ~$250–400k for a ten-name. Our $750k cap sits at the bottom of that envelope and about 3x inside the drift-band ceiling. The gap is deliberate and covers three things the formula does not: measured depth is a market-open snapshot and degrades over the weekend gap; several legs can need correcting in the same transaction; and the cost data behind it is a single sample.

**Construction, not drift, is the tighter constraint.** Building a position from zero is a 100%-of-weight buy, so the single-clip limit is:

```
clip_max = min over i of ( T_i / w_i )
Basket 1: min(170/0.30, 60/0.15, 20/0.08, 16/0.07) = $228k  ->  $200k
Basket 2: 34/0.30 = $113k                                    ->  $100k
```

Consistent with the measured "~$100–200k per execution" ceiling. One structural advantage falls out of the architecture: because strategies are **per-user**, aggregate construction is naturally spread across deposits arriving at different times. The clip limit binds only against a single large depositor, and only that user's build is TWAP'd.

**On the 26 bps round trip.** It was measured once, at $2,000 notional, in one live session. At $2,000 the trade is negligible against every pool, so 26 bps is close to a floor: it is essentially the pool fee plus the standing pool-vs-oracle gap. At the $100–200k clip sizes the caps permit, cost rises toward the 100 bps budget by construction. The user-facing number should be "tens of basis points at retail ticket sizes, bounded at 150 bps by the oracle guard" — not "26 bps".

The measured numbers reconcile cleanly, which is the main reason to trust them: weighting the per-leg costs by the traded mix gives (2000×26 + 1500×52 + 1000×49) / 4500 = **39.8 bps on traded notional**, and 45% of NAV traded, giving **17.9 bps of NAV predicted against 17 bps measured**.

Sleeve capacity is a non-issue: $1.1M of combined caps against the Steakhouse vault's ~$269.6M TVL is 0.4%.

---

## 4. How it works

### Architecture

`src/robinhood/StockBasketStrategy.sol` — one instance per user, behind an ERC1967 proxy, `Ownable` to the user, registered in `MamoStrategyRegistry`. State: the base asset (USDG, 6dp), one ERC-4626 `yieldVault`, a fixed `stockTokens[]` array with parallel `stockWeightsBps[]`, the `maxTotalStockBps` mandate, a `SlippagePriceChecker`, a Uniswap router and `poolFee`.

The stock set and the sleeve are **fixed at initialization** and cannot be changed by anyone afterwards, including the backend. Weights are mutable by the backend within the mandate. `MAX_STOCKS = 12` bounds every loop.

**The sleeve follows the chassis rules for Morpho Vault V2:** `maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` are hardcoded to 0 by design, so available sleeve liquidity is always derived as `convertToAssets(balanceOf(this))` and never from a `max*` view. Sizing sleeve pulls off `maxWithdraw` was one of the four live-chain bugs (§6). All four of the vault's gates (`receiveSharesGate`, `sendSharesGate`, and the two asset gates) read `address(0)` today — verdict GO — but they are a *monitored* quantity, not a listing-time check: a `sendSharesGate` set later would trap an already-funded position.

### Deposit path

`deposit(amount)` is permissionless (anyone may fund a user's strategy; only the owner may withdraw). It transfers USDG in, `forceApprove`s the sleeve and deposits the full amount. No equity is priced and no pool is touched, so **the deposit path has no dependency on equity feeds and works every hour of the week.**

### The two-pass rebalance

`rebalance(minTradeValue)`, backend-only:

1. Snapshot `navBefore = getTotalBalance()`. All targets are computed against this one snapshot, so intra-call price moves cannot make the passes disagree.
2. **Pass 1 — sell overweights.** For each leg where `currentValue > targetValue + minTradeValue`, sell the proportional excess into USDG.
3. **Pass 2 — buy underweights.** For each leg where `targetValue > currentValue + minTradeValue`, top up from idle USDG, pulling from the sleeve (via `convertToAssets`) if idle is short, and buy.
4. **Park the remainder** back into the sleeve, so no USDG is left idle and earning nothing.

The mandate is enforced on the *weights*, in `_setStockWeights`: the sum of the new weights must be `<= maxTotalStockBps`, checked at initialization and on every backend update. The backend cannot push equity exposure past the product's mandate in any code path.

### NAV

```
NAV = idle USDG
    + yieldVault.convertToAssets(shares)
    + Σ slippagePriceChecker.getExpectedOut(balance_i, stock_i, USDG)
```

The oracle, not the pool, defines NAV. **The Chainlink feed price already includes the ERC-8056 `uiMultiplier` — never multiply by `uiMultiplier()` in NAV.** This is the single most likely accounting bug in the product, and it is live-relevant, not theoretical: CRWD carries a 4e18 multiplier from a real 4:1 split. Getting this wrong would overstate a CRWD position by 4x.

### Withdrawal waterfall

`withdraw(amount)`: idle → sleeve → pro-rata stock sales, in that order, and only as far as needed. The stock-sale path grosses up the required amount by `allowedSlippageInBps` so slippage cannot leave the withdrawal short. `withdrawAll()` sells every leg, redeems all sleeve shares and transfers the balance.

The consequence that matters: **an ordinary partial withdrawal covered by the sleeve never touches an equity pool**, so it is available 24/7. Only a withdrawal large enough to eat into equity can be blocked by closed markets — and blocking is the correct behaviour there.

### Every swap is oracle-bounded

`_swap` computes `expectedOut` from the price checker, requires it non-zero, derives `minOut = expectedOut × (1 − slippage)`, and passes it as `amountOutMinimum`. If the pool cannot fill inside the bound, the router reverts with `Too little received` and the whole rebalance reverts atomically — no partial fills, no equity acquired at a bad price. The live-market suite proves this **binds against genuine liquidity**, not just against a mock: with the tolerance tightened to 1 bp, the live QuoterV2 quote falls under the oracle minimum and the rebalance reverts with the position untouched.

### Market hours, precisely

| Feed class | Live behaviour | Staleness bound |
|---|---|---|
| Equity (35 feeds, 8dp) | Mon 00:00 UTC → Fri ~21:00–23:35 UTC, ~20–30 min cadence intraweek. **24/5, not NYSE sessions** — they update overnight. ~50h weekend freeze; an ~80h freeze observed over July 4. | 26h (market-closed detector) |
| USDG/USD `0x8beee350…` | Strict 24h heartbeat, zero deviation-triggered updates in 59 days, **updates straight through weekends** | 27h — any bound below ~26h bricks the oracle path entirely |

A guard hard-coded to NYSE sessions (13:30–20:00 UTC) would wrongly halt during live overnight trading. This is verified behaviour, not an assumption.

**What happens on a weekend, today:** deposits work; sleeve-covered withdrawals work; `rebalance` reverts once the 26h bound trips; equity-touching withdrawals revert; and **`getTotalBalance()` also reverts**, because `_stockValue` routes through `getExpectedOut`, which reverts on a stale heartbeat. That last one is a real gap — front-end NAV display would break every weekend — and it needs a staleness-flagged read path separate from the swap-bounding path (§7).

**The 26h bound is deliberately loose and is not the production answer.** It detects "the market is closed", not intraday latency. With equity feeds last updating Friday ~21:00 UTC, a 26h bound still permits a trade against that frozen Friday price until roughly Saturday 23:00 UTC. Production needs two tiers: a **calendar/liveness gate** (are we inside the trading week?) *and* a tight intraweek bound of ~1–2h. Design detail in `ROBINHOOD_CHAIN_SPEC.md` §5.

There is **no sequencer-uptime feed on chain 4663** (full-history scan). Until Chainlink ships one, substitute a cross-feed liveness proxy — ETH/USD updates 24/7 at ~44 min median cadence — plus conservative equity bounds.

### Capacity metering

`MamoVaultConfig` holds the family supply cap and the venue allowlist, owned by the admin multisig, with strategies self-reporting flows and authenticating via `MamoStrategyRegistry.isUserStrategy`. `recordDeposit` enforces the cap; `recordWithdraw` clamps down to tracked principal so yield cannot underflow the global meter; `recordFullExit` releases the whole tracked principal, because ERC-4626 rounds down on both entry and exit and debiting only the realized amount stranded a unit of capacity per round trip forever at the vault's ~1.003 share price.

**`StockBasketStrategy` does not yet call any of this.** The chassis does; the basket does not. Wiring it — one `MamoVaultConfig` instance per basket family, cap set to the §3d figure — is roughly ten lines and is an open item (§7).

### Fee flow

Also unbuilt on the basket: `StockBasketStrategy` has no `compoundFee` and no `feeRecipient`. `MorphoVaultsStrategy` has both, with the fee taken on compounded proceeds and transferred to `feeRecipient`. The basket needs the same plus the management-fee accrual described in §2. Open item.

### Upgrades and governance

`_authorizeUpgrade` requires `msg.sender == mamoStrategyRegistry`; the registry only performs upgrades **initiated by the user**, and only to an implementation whitelisted for that strategy's type ID. The registry itself is not upgradeable. Roles carry over from Base: `DEFAULT_ADMIN_ROLE` (multisig + timelock), `GUARDIAN_ROLE` (pause), `BACKEND_ROLE`.

### The agent's bounds

| The backend **may** choose | The backend **can never** |
|---|---|
| when to rebalance, and at what clip size | exceed `maxTotalStockBps` |
| target weights within the mandate | change the stock set or the sleeve (fixed at init) |
| `minTradeValue` per call | trade outside the oracle bound (`minOut` is derived, not passed in) |
| which Merkl rewards to claim | move funds to any address other than the sleeve, the router, or the owner |
| — | withdraw to itself, or widen `allowedSlippageInBps` (owner-only) |
| — | upgrade the strategy (user-initiated, registry-gated, whitelisted implementations only) |

All keeper work is the Mamo backend: there is **no Chainlink Automation and no Gelato** on 4663 (zero upkeep events across all 27.7M blocks; every canonical Gelato address is empty). See `docs/ROBINHOOD_TENDERLY_AUTOMATIONS.md`.

---

## 5. Risk register

| Risk | L / I | Mitigation |
|---|---|---|
| **Issuer blocklists our contract addresses** — `AccessControlsRegistry` can do it in one transaction | Low / Severe | The core structural mitigation: per-user strategies bound the blast radius to one user, where a pooled vault would freeze everyone. Legal review of the Jersey prospectus is a launch gate; small caps limit exposure; disclose the power explicitly. |
| **Regulatory** — tokens barred to US/UK/CA/CH/UAE persons; composability is the documented leak vector and is already drawing press | Medium / Severe | Geo-gate our own front end; legal review before launch (§7); non-US TAM accepted as the product's premise, not a surprise. |
| **Issuer pause / burn / confiscate on individual balances** | Low / High | Same per-user bound; disclosed in product copy; no pooling of stock tokens anywhere in the design. |
| **Frozen feeds traded against** — the 26h bound permits ~26h of trading at a stale Friday price | **High / High** | The single most likely production incident today. Two-tier guard (calendar/liveness + ~1–2h intraweek bound) is a hard prerequisite (§7). |
| **Feed rotation strands a consumer** — every verified address is a raw aggregator, not a consumer proxy | Medium / High | Bind production to consumer proxies from the Chainlink docs directory, never to aggregators. Requires an external fetch (§7). |
| **Decoy feeds** — 31 dividends.finance feeds cover exactly the tickers Chainlink does not | Medium / High | Never enumerate feeds by description; allowlist feed addresses explicitly per basket; the eligible set in §3a is closed, not discovered at runtime. |
| **Impostor tokens** — spam ERC-20s with copied symbols exist | Medium / High | Identify by the "… • Robinhood Token" name suffix, **never by symbol**; asserted in the fork suite; hardcode addresses in deploy config. |
| **`uiMultiplier` double-counting** — would overstate a split name by its multiplier (CRWD: 4x) | Medium / High | Feed price already includes it; NAV never multiplies by it; asserted live in the fork suite. |
| **Capacity / thin-leg liquidity** — the thinnest leg binds the whole basket | High / Medium | Caps at ~3x inside the drift ceiling; depth-tilted weights; TWAP clips; measured trade caps, not TVL, drive eligibility; per-stock fee tiers + v4 routing roughly double it (§7). |
| **Weekend gap** — Friday-close to Monday-open moves cannot be traded through | High / Medium | Structural to the asset class and disclosed. Sleeve-first exits mean ordinary withdrawals are unaffected; the position simply sits. |
| **Adverse LP selection** — stock/USDG LPs write a free straddle to gap traders, so depth may thin further | Medium / Medium | We are a taker, not an LP. Oracle bound means a thin book produces a revert, not a bad fill. Re-measure trade caps before each cap increase. |
| **Chain: ArbOS transaction filtering can nullify force-included transactions** | Low / High | Disclose honestly — the standard "you can always withdraw" guarantee is weaker here. L2Beat classifies 4663 "Other", not a rollup. |
| **Chain: centralized sequencer, no uptime feed** | Medium / Medium | ETH/USD (24/7, ~44min cadence) as a liveness proxy plus conservative bounds until Chainlink ships an uptime feed. |
| **Smart contract: unaudited** | — / Severe | Non-negotiable launch gate. 14 unit + 26 real-bytecode + 13 fork tests are evidence of correctness, not a substitute for audit. Launch caps are sized so the worst case is bounded. |
| **Sleeve gates set after we are funded** (`sendSharesGate` traps a position) | Low / High | All four read `address(0)` today; ongoing off-chain gate monitoring is a wave-1 deliverable, not a listing-time check. |

**Per-user vs pooled, stated honestly.** Per-user contracts bound issuer and venue blast radius to one user and let the user own upgrades — genuinely better on the risks that dominate this chain. They cost more gas per rebalance, they cannot net one user's buys against another's sells, and the gas subsidy expires around 2026-09-29, after which per-user rebalance economics need re-checking. We think the trade is clearly right here; it is a trade.

---

## 6. What was built and tested

| Suite | Tests | What it establishes |
|---|---|---|
| `test/StockBasketStrategy.unit.t.sol` | 14 | Mechanics against mocks: buy-to-target, trim-the-winner after a price move, NAV under price moves, sleeve yield accrual, mandate enforcement, backend-only access, sleeve-first and stock-selling withdrawals, oracle-deviation revert. |
| `test/MorphoVaultsStrategyVaultV2.integration.t.sol` | 26 | The chassis against **real compiled Morpho Vault V2 bytecode** (`make robinhood-vaults-v2`, no fork). Confirms the no-`max*` design and exact rounding under live vault fees. |
| `test/RobinhoodFork.integration.t.sol` | 7 | Live chassis fork suite. On-chain ground truths + explicit GO/NO-GO gate verdict (**GO**) + a funded deposit→withdraw→exit E2E against the live Steakhouse vault. |
| `test/RobinhoodBasketFork.integration.t.sol` | 6 | **The live-market basket suite.** Real tokens, real Chainlink feeds, real 0.30% pools, real vault: identity/impostor guards, sleeve-only deposit, rebalance through live pools, sleeve-first withdrawal, full exit (**26 bps round trip**), and proof the oracle bound binds against real liquidity. |

The basket fork suite is the one that matters for this product. It carries its own `ChainlinkPairPriceChecker` reading the raw aggregators — deliberately not a mock, because a fork suite whose prices come from a stub proves nothing about the live system. Tests that must trade equities skip themselves with a log when feeds are stale, since reverting there is correct behaviour rather than a failure.

**Four live-chain bugs found and fixed** — none of which the local suites could have caught:

1. **Router ABI.** SwapRouter02 on 4663 dispatches only the no-deadline `IV3SwapRouter` struct (selector `0x04e45aaf`); the original 8-field `ISwapRouter` struct is absent from its bytecode. Every swap reverted. Fixed via `src/robinhood/interfaces/IUniswapV3SwapRouter.sol`.
2. **Sleeve `max*` reliance.** The basket sized sleeve pulls off `maxWithdraw`, which Vault V2 hardcodes to 0. Fixed to `convertToAssets(balanceOf)`.
3. **Supply-cap residue.** At the vault's ~1.003 share price a full round trip realizes 1–2 units under tracked principal, and `MamoVaultConfig` stranded the difference in the global meter permanently. Fixed via `recordFullExit()`, with a regression pinned at non-par share price.
4. **Event proceeds.** Swap events reported intended rather than realized amounts, making off-chain cost accounting silently wrong.

Behind all of it: **four independent chain-verification passes** over feeds, liquidity and infrastructure, which produced the eligible universe in §3a, the trade caps, the feed calendar, and the corrections now carried in `ROBINHOOD_CHAIN_SPEC.md` §1 with [V] tags. Several original assumptions were wrong — USDG depth was understated ~2x, "per-equity feeds" overstated coverage by 3x, USDG permit exists — which is the argument for having done it.

---

## 7. Open items before code-complete

Ordered. Owner shape in brackets.

1. **Venue-registry reconciliation, on our branch.** [contracts] Fold `MamoVaultConfig`'s supply cap and registry-authenticated accounting into the append-only / soft-deactivate semantics of the audit branch's `MarketRegistry` — one venue registry, not two. **Do this as a port into this branch: do not merge the audit branch.** That branch is mid-audit; taking a dependency on it makes our launch date theirs.
2. **Market-hours guard module + production price checker.** [contracts + external] The two-tier guard from §4: calendar/liveness gate plus per-feed-class staleness (~1–2h equity intraweek, ~26–27h USDG), `oraclePaused()` and staged-multiplier reads, ETH/USD as the sequencer-liveness proxy. Also add a staleness-flagged NAV read path so `getTotalBalance()` does not revert on weekends. **Blocked on an external fetch:** consumer proxy addresses and declared heartbeat/deviation parameters from the Chainlink docs directory. Everything we verified on-chain is a raw aggregator; shipping bound to those means a feed rotation strands us.
3. **Wire the cap and the fees into `StockBasketStrategy`.** [contracts] One `MamoVaultConfig` per basket family with the §3d caps; `recordDeposit` / `recordWithdraw` / `recordFullExit`; `compoundFee` + `feeRecipient` matching the chassis; management-fee accrual on the equity share. Also lower `MAX_SLIPPAGE_IN_BPS` from 2500 to 500. Small, but the product has no revenue and no cap until it is done.
4. **Per-stock fee tiers + v4 routing.** [contracts] Replace the single `poolFee` with a per-leg tier and route across v3 + v4. Roughly **2x capacity**, and it is what lets NVDA use the 0.05% tier — 25 bps off the largest leg of the largest basket.
5. **Factories + deploy tooling.** [contracts] Basket factory on the multi-market factory pattern; `addresses/4663.json`; `deploy/4663_*.json` with the §3d parameters; parameterize the hardcoded keys in `DeploySystem.s.sol`; verify Cancun / via-IR support on the Orbit node.
6. **Finish venue verification.** [backend] Turbo, Ethena and Grove USDG vaults: all four gates, TVL, organic yield, share-price behaviour. Their 2–4.5% versus Steakhouse's 1.6–1.9% is the difference between a 28 bps and a 132 bps net cash yield on Basket 1 (§2). Plus the standing gate monitor on every allowlisted vault.
7. **Measure COST's 100 bps trade cap; identify SPCX's underlying.** [backend + external] Both are cheap and both unlock a listing decision. SPCX in particular must not ship on liquidity alone.
8. **Tenderly automations.** [backend] Rebalance scheduling, TWAP clip execution, gate monitoring, Merkl claims — all of it, since neither Chainlink Automation nor Gelato exists on 4663. Being specced in parallel: `docs/ROBINHOOD_TENDERLY_AUTOMATIONS.md`.
9. **Legal review + geo-gated front end.** [external] The Jersey base prospectus: whether third-party contracts holding tokens for a mixed-jurisdiction user base is a technical gap or a contractual breach, and the issuer's policy on contract addresses. **This is the launch gate** — it can change the product's shape, not just its copy, so it should start now and in parallel with everything above.
10. **Audit.** [external] After items 1–5 land. Focus areas: the mandate and oracle-bound invariants, the cap accounting under non-par share prices, and the NAV path's `uiMultiplier` handling.

Not blocking launch, but on the clock: the gas subsidy expires around **2026-09-29**, after which per-user rebalance economics need re-checking against the fee model in §2 — the fee base at launch caps is ~$3.7k/yr, so gas netting is not academic. Also queued: **bridge MAMO to 4663 via Wormhole** [infra — ready]. Enables the MAMO leg of the weekly Drop and fully on-chain staking-gated capacity; until then the Drop pays USDG and gating uses backend-attested Base staking balances. Should land before the first staking-gated cap raise.
