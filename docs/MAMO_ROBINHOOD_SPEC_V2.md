# Mamo on Robinhood Chain — Launch Specification

*Status: the complete product specification for Mamo's launch on Robinhood Chain (chain 4663) — both products, the mechanisms that wire them together, every parameter, the full risk register, and the build order. This document is self-contained: everything needed to evaluate, approve or build the launch is in it.*

*Grounded in: `ROBINHOOD_CHAIN_SPEC.md` §1 (verified chain facts, [V] tags, on-chain at blocks ~27.70–27.73M), the live-market fork suites in this branch, `BOOSTED_USDG_SIZING.md` (why yield products stay dark), `ROBINHOOD_TENDERLY_AUTOMATIONS.md` (keeper design; the fee-conversion keeper becomes **A11** there), and the on-chain teardown of **"The Index"** — a live trade-fee token on 4663, measured 2026-08-05, which is the only working precedent for that mechanism on this chain and supplies both the design we copy and the failures we fix.*

---

## 1. Summary

**The opportunity.** Tokenized real-world assets are the strongest narrative in crypto, and equities are its center of gravity. Robinhood — a top consumer brokerage — has made its chain the flagship venue for on-chain stocks: ~95 tickers live, ~$70M of stock-token AUM within weeks of launch and growing, and institutional rails (Morpho, Chainlink, Uniswap) deployed from genesis. What the chain does not yet have is a credible manager for those assets — the competitive field is measured-empty ($41 of competitor TVL at last teardown), and the seat for *the money manager of on-chain stocks* is open. Mamo is built for exactly that seat: audited history, per-user custody, hard on-chain mandates. This spec is the plan to take it.

**One launch, two doors, one flywheel.**

**Mamo arrives on Robinhood Chain. Same companion, new ground.** Until now Mamo helped your money earn. Now it can help your money own. **Door 1 — Mamo Baskets:** you deposit USDG, Mamo builds your basket of tokenized stocks, keeps it on target, and keeps the cash half earning. Calm, capped, per-user (§2). **Door 2 — the Stock Drop:** MAMO arrives on the chain with its own market, and that market's trading fees do one thing — they buy real tokenized stocks for MAMO stakers. Every trade buys a piece of the market for the people who hold the token. *(Voice rule §11: user-facing copy says "trading fees" or "pool fee", never "tax".)*

The two doors are not two products with a shared logo. They are wired:

> **The flywheel, in one line:** trading MAMO buys stocks → stocks are paid to stakers → stakers reinvest them in-kind into their baskets → baskets are capped, so basket capacity is what stakers get first → basket fees come back to stakers as the Drop.

**What the launch ships.**

| Piece | Shape |
|---|---|
| **Mamo Baskets** | Two hard-capped, geo-gated, per-user basket strategies. $1.1M of combined capacity. The headline product. |
| **MAMO on 4663** | Bridged via Wormhole. **Launch-critical**, because the second door is denominated in it. |
| **The MAMO/USDG pool + fee hook** | Uniswap v4 pool with an immutable, ownerless hook taking a fixed share of the USDG leg of every swap. |
| **`StockDropVault`** | Ownerless destination for the pool fee, with exactly one outbound path: buy the epoch's stock, notify the staking hub. |
| **Epoch-voted rewards** | Every 14 days, MAMO stakers choose one tokenized stock from a cleared menu. The pool's fees buy it for them. |
| **The reinvest (`claimAndDeposit`)** | Reward stock routes in-kind, at oracle value, straight into the user's basket — no swap, no spread. |
| **The staking hub** | One `MultiRewards` deployment carrying three native streams: stock rewards, basket-capacity priority, the Drop. |

**Headline verified numbers, up front.** A full live round trip — deposit 2,000 USDG → agent rebalance to a 45% NVDA/AAPL/TSLA basket → `withdrawAll` — cost **26 bps of NAV**, executed against real Chainlink feeds, real 0.30% Uniswap pools and the real Steakhouse vault. The rebalance leg alone drifted 17 bps against a 17.9 bps prediction and landed the mix at 4490/5509 bps versus a 4500/5500 target. The chassis fork suite returns an explicit **GO** on the venue gate check. The yield sleeve is Spark **spUSDG at 3.500% contractual**; Robinhood Earn's on-chain all-in rate is only **~2.1–2.4%** (the ~7% headline is app-side credit). Fee model: `compoundFee` ≤10% of sleeve yield plus **50 bps/yr on the equity share only**. Revenue at full launch caps: **≈$3.7k/yr**, stated plainly here and again in §7.

**The honest frame for Door 2.** The pool fee is **not yield and must never be quoted as an APY** — The Index's own volume is down ~97% from its peak window (§3b); trade-fee revenue is reflexive and varies with the trading it rides on. **By default the Stock Drop runs indefinitely.** The hook carries exactly one lever: a **one-way, irrevocable `disable()`** held by the admin multisig that can set the fee to zero forever — it can never raise the fee, never redirect it, never re-enable it. A **hardcoded sunset** (a fixed end date in bytecode) is retained as a consideration, not the default (§3e, decision 3).

**What stays out.** Boosted USDG (levered USDG carry) stays dark: the carry does not exist at scale, and it has *worsened* — syrupUSDG's organic spread flipped **−51 bps** on the 2026-08-05 re-measure (`BOOSTED_USDG_SIZING.md` §6). No leverage ships. No MAMO emissions anywhere. The launch is bought for stance and the option, not for revenue, and no document should call it break-even.

---

## 2. Door 1 — Mamo Baskets

**Mamo Baskets** is a per-user, agent-managed portfolio of tokenized equities plus a USDG yield sleeve. USDG in, USDG out. The user picks a basket; their own contract holds the stock tokens at target weights and parks everything else in a Morpho USDG vault; the Mamo agent builds and rebalances inside a hard, admin-set mandate.

Three things make it worth building rather than porting another yield router:

1. **Subsidy-immune surface.** Robinhood Earn shows a subsidized ~7% on USDG savings, app-gated, for roughly a year. A yield router loses to that inside the incumbent's own app. A portfolio product does not compete with it at all — it competes with holding stock tokens idle, which is ~$70M of dead assets today. Nobody pays users to hold NVDA-token; we would.
2. **Per-user custody as a safety claim, not a preference** (§2b).
3. **Every idle dollar earns, at the best visible on-chain rate.** The cash half sits in the sleeve from the moment of deposit, not in a hot wallet awaiting a build.

### 2a. The user journey

**Deposit.** The user approves USDG and calls `deposit(amount)`. The whole amount goes straight into the yield sleeve — no equity is bought. This is deliberate: deposits are cheap, they work at 3am on a Sunday when every equity feed is frozen, and equity trading stays on the agent's schedule rather than the depositor's. USDG has EIP-2612 permit, so a one-transaction permit deposit is available in the front end. `deposit` is permissionless — anyone may fund a user's strategy; only the owner may ever withdraw.

**Build.** On its next scheduled pass the agent calls `rebalance(minTradeValue)`, backend-only. It snapshots `navBefore = getTotalBalance()` once, sells overweights into USDG, buys underweights (pulling from the sleeve if idle USDG is short), and re-parks the remainder in the sleeve so no dollar sits idle. Every swap carries an oracle-derived `amountOutMinimum`, so **the agent chooses *when* to trade and never *at what price*.**

**Weekly experience.** The basket tracks its targets within the drift band; the sleeve accrues; the user sees one NAV in USDG. Fees flow to the MAMO flywheel and come back to stakers as the Drop. Equity trading pauses roughly 50 hours every weekend and on market holidays (§2i) — the position simply sits.

**Withdraw.** `withdraw(amount)` drains idle USDG first, then the sleeve, and only sells stock pro-rata if those two cannot cover it, grossing the sale up by `allowedSlippageInBps` so slippage cannot leave the withdrawal short. `withdrawAll()` liquidates everything. The consequence that matters: **an ordinary partial withdrawal covered by the sleeve never touches an equity pool, so it is available 24/7.** Only a withdrawal large enough to eat into equity can be blocked by closed markets — and blocking is the correct behaviour there.

**Why not just hold the stocks yourself?** The question every reviewer should ask, so it goes in the spec. For a single-stock buy-and-holder we have no pitch, and the copy must never pretend otherwise. The product is for portfolio holders, and the value stack is concrete: the cash half works (a self-directed holder's dry powder earns zero — Earn is app-gated savings, disconnected from a portfolio); one USDG ticket becomes a weighted basket instead of four manual DEX swaps through the same pools at the same-or-worse spreads, with every fill oracle-bounded so the user structurally cannot trade against a frozen weekend price or a manipulated pool; drift-band rebalancing and winner-trimming happen on schedule inside a mandate the agent cannot exceed; and custody is preserved. Dividends are a wash against self-custody — the issuer auto-reinvests them for every holder equally. What we charge for the difference is the 50 bps management fee on the equity share.

### 2b. Per-user custody is the safety architecture on this chain

The stock tokens are issued by **Robinhood Assets (Jersey) Ltd**. The issuer retains **pause, burn and confiscate** powers over individual balances, and its `AccessControlsRegistry` can **blocklist a contract address in a single transaction**. That is not a tail scenario to be argued away; it is a documented power of the asset we are holding.

Every pooled competitor concentrates that blast radius across all depositors. One blocklist transaction freezes everyone. **One user's basket is one user's contract** — an ERC1967 proxy owned by them, registered to them in `MamoStrategyRegistry` — so the blast radius of any issuer action is exactly one user. This is the only honest differentiated safety claim available on this chain, and it is the reason the architecture is per-user rather than pooled.

**Stated honestly, it is a trade.** Per-user contracts cost more gas per rebalance and cannot net one user's buys against another's sells, and the chain's gas subsidy expires around **2026-09-29**, after which per-user rebalance economics need re-checking against the fee model. We think the trade is clearly right here; it is still a trade. The one place in the whole design where stock tokens are pooled is the undistributed reward buffer in `MultiRewards`, and that is called out by name in the risk register (§8).

### 2c. What the user actually holds

Inside the strategy: ERC-20 tokens issued by Robinhood Assets (Jersey) Ltd — tokenized *debt notes* giving economic exposure to the reference share, 1:1 share-backed, with **no shareholder rights and no voting** — plus ERC-4626 shares of a Morpho USDG vault.

There is **no dividend cash flow**. Dividends auto-reinvest into the ERC-8056 `uiMultiplier` rather than paying out. The economics *should* still reach the user, because the Chainlink feed price already includes the multiplier, so credited dividends surface as NAV appreciation; and the mechanism is demonstrably real — CRWD carries `uiMultiplier() == 4e18` from an actual 4:1 split. **Crediting caveat (2026-08-05): SGOV's Aug-3 distribution dropped its feed price −0.27% and the multiplier has not stepped in the days since.** Plausibly a crediting lag, but until one full cycle is observed landing, dividend capture appears in **no user-facing copy**, and the corporate-action monitor (automation A7) reconciles every ex-dividend date against multiplier steps. Either way the compounding is the issuer's, never claimed as ours.

The single most likely accounting bug in the product follows directly: **the feed price already includes `uiMultiplier`, so NAV must never multiply by `uiMultiplier()` again.** Getting this wrong would overstate a CRWD position by 4x. It is asserted live in the fork suite.

### 2d. The eligibility rule, and the eligible universe

A ticker is eligible only if it clears **all three** gates:

1. **A genuine Chainlink feed exists.** 35 equity-type feeds are live (28 single names + 7 ETF/commodity) against ~95 issued tickers — roughly one third. **The feed set, not the token set, defines the universe.** There are also **31 decoy "dividends.finance" feeds covering exactly the tickers Chainlink does not**, with plausible descriptions, no round history and implausible prices: never enumerate feeds by description.
2. **Real pool depth, not listing dust.** Ten tickers hold genuine per-name v3 USDG depth; roughly thirty more hold only ~$1.4k of listing seed.
3. **A non-trivial single trade clears 100 bps** at the sizes rebalancing actually requires, measured on the live QuoterV2 across v3 + v4.

Applied to the measured data (2026-08-04, US market open):

| Ticker | Feed | v3 USDG depth | Largest trade < 100 bps (v3+v4) | Verdict |
|---|---|---|---|---|
| NVDA | yes | $779k | ~$170k | **Core** — the only name with real two-tier depth |
| AAPL | yes | $69k | ~$60k | **Core** |
| SPY | yes (ETF) | $144k | ~$34k | **Core** |
| GOOGL | yes | $56k | ~$20k | **Core** |
| SPCX | yes | $382k | ~$20k | Deep, but blocked — underlying unidentified (§2e) |
| TSLA | yes | $63k | ~$16k | **Core** |
| COST | yes | $70k | not measured | Reserve — quote it before use |
| QQQ | yes (ETF) | $73k | ~$4k | Reserve — too thin to build against |
| GME | yes | $218k | **$0** | Rejected |
| SLV | yes (commodity) | $185k | **$0** | Rejected |

Eight names pass gates 1 and 2; five have a measured trade cap large enough to build a position against. **Depth and tradeable capacity are not the same quantity.** GME and SLV rank third and fourth on depth and are entirely untradeable, because their liquidity sits only in 1% fee tiers where the fee alone consumes the whole 100 bps budget. **Rank on the measured trade cap, never on TVL.** This closed set is the eligible universe for baskets *and* the ballot menu for epoch-voted rewards (§4b).

### 2e. The launch lineup, and why

| Basket | Composition | Stock/sleeve | Supply cap | Single-clip build limit |
|---|---|---|---|---|
| Mamo AI & Mega-cap Tech | NVDA 30% / AAPL 15% / GOOGL 8% / TSLA 7% | 60 / 40 | $750k | $200k |
| Mamo Blue-chip Index + Yield | SPY 30% | 30 / 70 | $350k | $100k |

$1.1M of combined capacity. **Small on purpose:** capacity is the binding constraint (§2g), and **scarce capacity is the MAMO utility** — the gating for it is native and on-chain (§6).

**Basket 1 weights are tilted toward depth, not toward market cap.** Pure depth-proportional weighting of the four trade caps (170/60/20/16) would put NVDA at 64% of the equity share, which is a single-name position wearing a basket's name. The split — NVDA 50% of equity, AAPL 25%, GOOGL 13%, TSLA 12% — keeps NVDA dominant enough that most rebalance flow lands in the one pool that can absorb it, while remaining recognisable as a four-name basket. Equity share is 60% because it is the highest share the capacity math tolerates at this cap, and because the sleeve share must still cover most of the fee (§2h).

**Basket 2 launches SPY-only, not SPY + QQQ.** QQQ's 100 bps trade cap is ~$4k. Adding it at even a 5% weight would cut the single-clip build limit from $113k to $80k and add a leg that fails to fill on any adverse day. Add QQQ as a second slot only once its measured 100 bps cap exceeds ~$15k. Basket 2 is also the basket where "the idle half earns" is genuinely true (~205 bps of net cash yield against ~96 bps for Basket 1).

**Explicitly rejected for launch:**

- **Mag7.** MSFT, AMZN and META hold only ~$1.4k of listing-seed dust each. **A true Mag7 basket is not currently buildable at any size.** This is a liquidity measurement, not a preference; any earlier plan listing Mag7 as a launch basket predates the measurement.
- **GME, SLV.** Zero capacity at 100 bps. Deep on paper, untradeable in practice.
- **SPCX.** Second-deepest USDG pool on the chain ($382k), a Chainlink feed, a ~$20k trade cap — mechanically a viable single-name basket at a ~$250k cap with $80k clips. **It is blocked, and not on liquidity grounds:** we have not verified what instrument the SPCX token references, nor that the Chainlink feed under that ticker references the same instrument. Both must be established from the issuer's documentation and the Chainlink docs directory first. **A deep pool against a misunderstood underlying is a worse failure than a thin pool against a known one.** Do not assert the underlying in any user-facing copy until this is closed.
- **COST.** Passes feed and depth ($70k, comparable to AAPL) but has no measured 100 bps quote. Cheap to resolve; do it before considering a five-name Basket 1.
- **Roughly two thirds of the ticker universe.** No Chainlink feed, therefore no NAV and no oracle bound, therefore no product. Any name whose only "feed" is a dividends.finance decoy is excluded by construction.

### 2f. Per-basket parameters

| Parameter | Basket 1 — AI & Mega-cap Tech | Basket 2 — Blue-chip Index + Yield |
|---|---|---|
| `stockTokens` | NVDA `0xd0601ce1…`, AAPL `0xaf3d76f1…`, GOOGL, TSLA `0x322f0929…` | SPY `0x117cc213…` |
| `stockWeightsBps` | 3000 / 1500 / 800 / 700 | 3000 |
| Equity / sleeve target | 6000 / 4000 | 3000 / 7000 |
| `maxTotalStockBps` (mandate) | 6500 | 3500 |
| `yieldVault` (sleeve) | Spark spUSDG `0xde770c84…` (3.500% contractual, verified permissionless); Steakhouse `0xBeEff033…` as fallback venue | same |
| `poolFee` | 3000 (0.30%) | 3000 (0.30%) |
| `allowedSlippageInBps` | 150 | 150 |
| Supply cap | $750k | $350k |
| Single-clip build limit | $200k | $100k |
| TWAP cadence above the clip | ≤ $200k per clip, ≥ 15 min apart | ≤ $100k per clip, ≥ 15 min apart |
| Drift band (backend policy) | ±10% relative per leg | ±10% relative |
| `minTradeValue` per call | max(0.5% of NAV, 50 USDG) | max(0.5% of NAV, 50 USDG) |

The judgment calls behind those numbers:

- **Mandate above target.** `maxTotalStockBps` sits 500 bps above the equity target so the agent can tilt without the mandate becoming a straitjacket, while the hard ceiling still binds. The mandate is enforced on the *weights*, in `_setStockWeights`: the sum of new weights must be `<= maxTotalStockBps`, checked at initialization and on every backend update.
- **`poolFee` is one value for the whole basket.** All five core names quote against USDG in the 0.30% tier today, so a single tier works. NVDA's two-tier depth means it could route through the 0.05% tier and save 25 bps on the largest leg in the largest basket — but `poolFee` is a single `uint24` on the contract. **Per-stock fee tiers plus v4 routing are a planned contract change worth roughly 2x capacity**, deferred to the first cap raise (§9).
- **150 bps slippage.** Three times the worst measured per-leg deviation (AAPL, 52 bps including the pool fee), half the 300 bps the fork suite used, and far inside the contract's `MAX_SLIPPAGE_IN_BPS` of 2500. Tight enough that the bound binds on a bad print; loose enough that ordinary rebalances fill. A failure here is a revert and a retry, not a loss.
- **`setSlippage` is `onlyOwner` — the user, not the backend.** Good governance (the agent can never widen its own bound) with a sharp edge: a user could set 2500 bps and a subsequent backend rebalance would trade up to 25% off oracle. **Lower `MAX_SLIPPAGE_IN_BPS` from 2500 to 500 in the basket implementation** (§9).
- **The drift band is off-chain policy, not a contract invariant.** On-chain the agent may call `rebalance` at any time; what the contract enforces is the mandate, the `minTradeValue` dust filter and the oracle bound. Stated plainly because it changes what an auditor should look for.
- **The stock set and the sleeve are fixed at initialization** and cannot be changed by anyone afterwards, including the backend. Weights are mutable by the backend within the mandate. `MAX_STOCKS = 12` bounds every loop.

### 2g. Capacity math, honestly

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

The published capacity envelope from the fork measurement work is **$750k–$1M for a five-name deepest-ticker basket at ≤10% drift** and ~$250–400k for a ten-name. The $750k cap sits at the bottom of that envelope and about **3x inside** the drift-band ceiling. The gap is deliberate and covers three things the formula does not: measured depth is a market-open snapshot and degrades over the weekend gap; several legs can need correcting in the same transaction; and the cost data behind it is a single sample.

Basket 2 in full, since it is the shorter derivation:

```
SPY 100bps trade cap                      = $34,000
SPY weight of NAV                         = 30%
drift band (relative, per leg)            = 10%
rebalance trade at cap  = 10% x 30% x AUM = 0.03 x AUM
binding condition       0.03 x AUM        <= $34,000
theoretical AUM ceiling                   = $1.13M
safety factor (weekend depth loss, multi-leg simultaneity, one-sample cost data)  = 3.2x
launch cap                                = $350k
```

**Construction, not drift, is the tighter constraint.** Building a position from zero is a 100%-of-weight buy, so the single-clip limit is:

```
clip_max = min over i of ( T_i / w_i )
Basket 1: min(170/0.30, 60/0.15, 20/0.08, 16/0.07) = $228k  ->  $200k
Basket 2: 34/0.30 = $113k                                    ->  $100k
```

Consistent with the measured "~$100–200k per execution" ceiling. One structural advantage falls out of the architecture: because strategies are **per-user**, aggregate construction is naturally spread across deposits arriving at different times. The clip limit binds only against a single large depositor, and only that user's build is TWAP'd.

**On the 26 bps round trip.** It was measured once, at $2,000 notional, in one live session. At $2,000 the trade is negligible against every pool, so 26 bps is close to a floor: essentially the pool fee plus the standing pool-vs-oracle gap. Per-leg pool-vs-oracle cost including the 30 bps pool fee was NVDA 26 bps, AAPL 52 bps, TSLA 49 bps. At the $100–200k clip sizes the caps permit, cost rises toward the 100 bps budget by construction. **The user-facing number is "tens of basis points at retail ticket sizes, bounded at 150 bps by the oracle guard" — not "26 bps".** The measured numbers reconcile cleanly, which is the main reason to trust them: weighting the per-leg costs by the traded mix gives (2000×26 + 1500×52 + 1000×49) / 4500 = **39.8 bps on traded notional**, and 45% of NAV traded, giving **17.9 bps of NAV predicted against 17 bps measured**.

Sleeve capacity is a non-issue: $1.1M of combined caps against the Steakhouse vault's ~$269.6M TVL is 0.4%.

### 2h. The fee model, the sleeve, and what we report as yield

Two legs, both matching existing repo precedent:

- **`compoundFee` ≤ 10% of sleeve yield** — the chassis constant (`MorphoVaultsStrategy.MAX_COMPOUND_FEE = 1000`).
- **Basket management fee, 50 bps/yr, charged on the equity share of NAV only** — the bottom of the 50–95 bps precedent band, and charged on the equity share rather than on total NAV.

Both route `feeRecipient` → `FeeSplitter` → `MultiRewards` → the Drop.

The reason for both choices is arithmetic, and it is the least comfortable table in this document:

| | Basket 1 (60/40) | Basket 2 (30/70) |
|---|---|---|
| Sleeve share of NAV | 40% | 70% |
| Sleeve gross yield @ **3.50%** (spUSDG, contractual — verified 2026-08-05) | 140 bps | 245 bps |
| less `compoundFee` (10% of sleeve yield) | 14 bps | 24 bps |
| less management fee @ 50 bps on equity share | 30 bps | 15 bps |
| **Net cash yield to user** | **~96 bps** | **~205 bps** |

The sleeve routes to **Spark's spUSDG `0xde770c84fe66e063336b31737cfe9790f18c4087`** — verified 2026-08-05: permissionless (contracts already deposit; per-address `maxDeposit` identical for any caller), honest full ERC-4626 surface, **exactly 3.500% APY by contract** (`chi`/`rho`), 99.96% cash-backed with instant exit at any size we would deploy, $487M of unused deposit cap. Steakhouse steakUSDG (1.6–1.9% organic) stays in the allowlist as the fallback venue and the backend routes to the best rate — the multi-vault chassis doing its actual job. Residual spUSDG risk is governance-shaped, not access-shaped (UUPS-upgradeable; admin-settable rate under a 6% ceiling) and is a standing monitor item. At a Steakhouse-only sleeve the numbers would be 28–38 / 86–105 bps and a 95 bps fee would consume Basket 1's entire sleeve; at 3.50% the 50 bps fee has real headroom, and **50 bps remains the call.**

The honest positioning that follows: **the sleeve is not the return driver — equity performance is.** The sleeve makes the cash half non-dead and pays most of the management fee. We should say exactly that and not imply a yield product.

**Positioning unlock (measured 2026-08-05): Earn's ~7% headline is app-side, not on-chain.** The Earn vault's visible on-chain economics are 1.6–1.9% organic plus a Merkl campaign whose *funded* size is $1.385M against $279M of TVL — **~48 bps/yr, with the "100M over 365d" nominal ~83× unfunded** — for an all-in on-chain rate of **~2.1–2.4%**. The remaining ~4.5–5% of the headline is invisible on-chain. With spUSDG at 3.50% in the sleeve, **"the best visible on-chain USDG rate on Robinhood Chain" is an honest Mamo claim today**, for exactly the audience (on-chain holders, not app users) this product serves. The subsidy-capture idea is correspondingly dead: mechanically ungated on-chain, but worth ~48 bps at best and gated by off-chain Merkl tree construction we can never verify in advance.

**What we report as yield: no blended basket APY, ever.** Most of the return is equity performance, which is not an APY; projecting it as one invites both user harm and exactly the regulatory attention a securities-adjacent product cannot afford. The UI shows two separate numbers: the **live sleeve APY** read from the venue (3.50% contractual on spUSDG today; net ~3.15% on sleeve dollars after `compoundFee`) and **basket price performance** as a return, not a rate. Merkl or Drop rewards are quoted as variable, never projected.

**How the user is paid, mechanically.** Everything accrues in NAV and realizes in USDG on withdrawal — no claim flows for basket returns. Three streams: equity marked to the Chainlink feeds; sleeve yield via share-price appreciation; Merkl rewards, when campaigns pay the strategy, compounded into the sleeve minus the fee.

```
NAV = idle USDG
    + yieldVault.convertToAssets(shares)
    + Σ slippagePriceChecker.getExpectedOut(balance_i, stock_i, USDG)
```

The oracle, not the pool, defines NAV.

### 2i. Market hours, precisely

| Feed class | Live behaviour | Staleness bound |
|---|---|---|
| Equity (35 feeds, 8dp) | Mon 00:00 UTC → Fri ~21:00–23:35 UTC, ~20–30 min cadence intraweek. **24/5, not NYSE sessions** — they update overnight. ~50h weekend freeze; an ~80h freeze observed over July 4. | 26h (market-closed detector) |
| USDG/USD `0x8beee350…` | Strict 24h heartbeat, zero deviation-triggered updates in 59 days, **updates straight through weekends** | 27h — any bound below ~26h bricks the oracle path entirely |

A guard hard-coded to NYSE sessions (13:30–20:00 UTC) would wrongly halt during live overnight trading. This is verified behaviour, not an assumption.

**What happens on a weekend, today:** deposits work; sleeve-covered withdrawals work; `rebalance` reverts once the 26h bound trips; equity-touching withdrawals revert; and **`getTotalBalance()` also reverts**, because `_stockValue` routes through `getExpectedOut`, which reverts on a stale heartbeat. That last one is a real gap — front-end NAV display would break every weekend — and it needs a staleness-flagged read path separate from the swap-bounding path (§9).

**The 26h bound is deliberately loose and is not the production answer.** It detects "the market is closed", not intraday latency. With equity feeds last updating Friday ~21:00 UTC, a 26h bound still permits a trade against that frozen Friday price until roughly Saturday 23:00 UTC. Production needs two tiers: a **calendar/liveness gate** (are we inside the trading week?) *and* a tight intraweek bound of ~1–2h. Design detail in `ROBINHOOD_CHAIN_SPEC.md` §5.

There is **no sequencer-uptime feed on chain 4663** (full-history scan). Until Chainlink ships one, substitute a cross-feed liveness proxy — ETH/USD updates 24/7 at ~44 min median cadence — plus conservative equity bounds. All keeper work is the Mamo backend: there is **no Chainlink Automation and no Gelato** on 4663 (zero upkeep events across all 27.7M blocks; every canonical Gelato address is empty).

**All sleeve paths run 24/7.** Deposits, sleeve accrual and sleeve-covered withdrawals have no equity-feed dependency whatsoever. That is what makes the market-hours halt survivable rather than a product defect, and it is the first thing to say in user-facing copy about weekends.

### 2j. The agent's bounds

| The backend **may** choose | The backend **can never** |
|---|---|
| when to rebalance, and at what clip size | exceed `maxTotalStockBps` |
| target weights within the mandate | change the stock set or the sleeve (fixed at init) |
| `minTradeValue` per call | trade outside the oracle bound (`minOut` is derived, not passed in) |
| which Merkl rewards to claim | move funds to any address other than the sleeve, the router, or the owner |
| — | withdraw to itself, or widen `allowedSlippageInBps` (owner-only) |
| — | upgrade the strategy (user-initiated, registry-gated, whitelisted implementations only) |

`_authorizeUpgrade` requires `msg.sender == mamoStrategyRegistry`; the registry only performs upgrades **initiated by the user**, and only to an implementation whitelisted for that strategy's type ID. The registry itself is not upgradeable. Roles carry over from Base: `DEFAULT_ADMIN_ROLE` (multisig + timelock), `GUARDIAN_ROLE` (pause), `BACKEND_ROLE`.

**Every swap is oracle-bounded.** `_swap` computes `expectedOut` from the price checker, requires it non-zero, derives `minOut = expectedOut × (1 − slippage)`, and passes it as `amountOutMinimum`. If the pool cannot fill inside the bound the router reverts and the whole rebalance reverts atomically — no partial fills, no equity acquired at a bad price. The live-market suite proves this binds against genuine liquidity: with the tolerance tightened to 1 bp, the live QuoterV2 quote falls under the oracle minimum and the rebalance reverts with the position untouched.

**Capacity metering.** `MamoVaultConfig` holds the family supply cap and the venue allowlist, owned by the admin multisig, with strategies self-reporting flows and authenticating via `MamoStrategyRegistry.isUserStrategy`. `recordDeposit` enforces the cap; `recordWithdraw` clamps down to tracked principal so yield cannot underflow the global meter; `recordFullExit` releases the whole tracked principal, because ERC-4626 rounds down on both entry and exit and debiting only the realized amount stranded a unit of capacity per round trip forever at the vault's ~1.003 share price. **`StockBasketStrategy` does not yet call any of this** — wiring it is an open item (§9), and the staker carve-out (§6) rides on the same wiring.

### 2k. What is built and tested

| Suite | Tests | What it establishes |
|---|---|---|
| `test/StockBasketStrategy.unit.t.sol` | 14 | Mechanics against mocks: buy-to-target, trim-the-winner after a price move, NAV under price moves, sleeve yield accrual, mandate enforcement, backend-only access, sleeve-first and stock-selling withdrawals, oracle-deviation revert. |
| `test/MorphoVaultsStrategyVaultV2.integration.t.sol` | 26 | The chassis against **real compiled Morpho Vault V2 bytecode** (no fork). Confirms the no-`max*` design and exact rounding under live vault fees. |
| `test/RobinhoodFork.integration.t.sol` | 7 | Live chassis fork suite. On-chain ground truths + explicit GO/NO-GO gate verdict (**GO**) + a funded deposit→withdraw→exit E2E against the live Steakhouse vault. |
| `test/RobinhoodBasketFork.integration.t.sol` | 6 | **The live-market basket suite.** Real tokens, real Chainlink feeds, real 0.30% pools, real vault: identity/impostor guards, sleeve-only deposit, rebalance through live pools, sleeve-first withdrawal, full exit (**26 bps round trip**), and proof the oracle bound binds against real liquidity. |

**Four live-chain bugs were found and fixed**, none of which the local suites could have caught: SwapRouter02 on 4663 dispatches only the no-deadline `IV3SwapRouter` struct (selector `0x04e45aaf`), so every swap reverted against the 8-field `ISwapRouter` struct; the basket sized sleeve pulls off `maxWithdraw`, which Morpho Vault V2 hardcodes to 0; the supply-cap meter stranded 1–2 units per round trip at non-par share price (fixed via `recordFullExit()`); and swap events reported intended rather than realized amounts, making off-chain cost accounting silently wrong.

The contract exists and trades on the live chain. It is **not audited, not fee-wired, not cap-wired, and not deployed.**

### 2l. What we promise, and what we do not

**We promise:** USDG in, USDG out. The user is the sole owner: only they can withdraw, only they can initiate an upgrade, and only to an implementation the registry has whitelisted for their strategy type. The backend can never exceed `maxTotalStockBps`, never trade outside the oracle bound, and never move funds to an address of its choosing. Deposits and sleeve-covered withdrawals work 24/7.

**We do not promise:** dividend capture or shareholder rights (neither exists); tracking-error bounds against the underlying index; uninterrupted equity trading (feeds and therefore trading halt ~50h per weekend and through holidays); chain-level censorship resistance (ArbOS transaction filtering can nullify even force-included transactions, so Mamo's usual "you can always withdraw" guarantee is strictly weaker here and must be disclosed); immunity from the issuer's pause/burn/confiscate/blocklist powers; availability to US, UK, Canadian, Swiss or UAE persons; index-fund capacity.

---

## 3. Door 2 — the MAMO pool and the Stock Drop

### 3a. What it is

A **MAMO/USDG Uniswap v4 pool on chain 4663** with one hook attached. The hook takes an immutable percentage of the USDG leg of every swap and sends it to an immutable destination. A keeper converts that USDG into **one tokenized stock per epoch — the stock MAMO stakers voted for** — and streams it to stakers through `MultiRewards`. The program is **the Stock Drop** — the on-chain extension of The Mamo Drop, the reward ritual Mamo already ships. By default it runs indefinitely; its only lever is a one-way retire (§3c, §3e).

MAMO reaches 4663 via **Wormhole**: `Mamo.sol`'s Superchain bridge leg does not port to Arbitrum Orbit, and the Wormhole path is already operational for MAMO. Bridge execution is launch-critical, because Door 2 is denominated in it.

### 3b. The precedent, measured

"The Index" is a trade-fee token live on 4663 since block ~1.67M. Everything below was read on-chain on 2026-08-05; addresses are given so the claims are checkable.

| Measured | Value |
|---|---|
| Hook | `0x2cd91bd228ff4c537031d6b8204782090c84c0cc` — 5 pools, flags `beforeSwap+afterSwap+beforeSwapReturnDelta+afterSwapReturnDelta` (address low bits `0x0cc`) |
| Fee destination | `0x1604ff11dfeaac437077aeda2fa492ac9ec804df` (treasury EOA-controlled), **verified 1:1 pass-through** |
| Push distributor | `0x39adb8acd07427d338b5f1afab436a04abfdb7c4`, **18 stock tokens** configured |
| Lifetime flow | **62,565 swaps**, **21,085 ETH** two-sided throughput ≈ **$39.5M** at ETH $1,873 (chain feed); implied 3% take ≈ **633 ETH ≈ $1.19M** |
| Volume decay | peak 5.8-day window **8,930 ETH** → most recent equivalent window **265 ETH** = **−97%** |
| Holders | 11,030 non-zero, 8,718 above 1 token, 984 above 100k |
| Distribution cost | ~**925M gas** per hourly round; **$74** effective eligibility floor; **$1.64** median distribution; holder list assembled **off-chain** |
| Governance | distribution destination **silently redirected 3×** by a bare EOA |

Two conclusions, both load-bearing:

1. **The fee leg works and is credible precisely because it is dumb.** Stateless, ownerless, hardcoded bps, immutable destination. There is no lever to pull, so nobody has to trust anyone. That is why a 3% take survived $39.5M of volume without a governance fight.
2. **Everything downstream of the fee is the anti-pattern.** A push distributor with an off-chain holder list is permissioned-by-omission — if you are not on the list you are not paid, and at $74 of implied gas cost per recipient the list is *necessarily* truncated. A median distribution of $1.64 is not a reward; it is dust that rots in a wallet. And a redirect lever exercised three times by an EOA is the whole trust model, undone.

### 3c. Hook design — copy the good leg, fix the failures

| Design point | The Index (measured) | Mamo Stock Drop hook | Why |
|---|---|---|---|
| State / ownership | stateless, ownerless, hardcoded bps | **same** | The only reason a fee of this shape is credible. No admin, no setter, no upgrade path. |
| Fee denomination | ETH side of an ETH-paired pool | **USDG side of a MAMO/USDG pool** | The accrual is bankable in the numeraire we buy stocks with. No second swap to price it; no ETH-price reflexivity in the reward stream. |
| Rate | 300 bps | **200 bps (recommended, §10)** | Total per-side cost = 200 fee + 30 LP = 230 bps. 300 bps taxes the volume the mechanism exists to monetize. |
| Destination | treasury EOA | **`StockDropVault`** — immutable, ownerless | Removes the redirect lever entirely. |
| Distribution | push, hourly, off-chain list, ~925M gas/round | **pull-based `MultiRewards`** | Pull scales to any holder count at zero marginal gas to us, has no list, and cannot omit anyone. |
| Eligibility floor | ~$74 of implied gas | **none** | Accrual is per-second and continuous; the user chooses when claiming is worth the gas. |
| Duration | indefinite, no off-switch | **indefinite by default, with a one-way irrevocable `disable()`** (fee→0 only; nothing else settable) | Reflexive revenue (−97% on the precedent) should be retirable deliberately, not promised forever; a hardcoded sunset stays on the table as a consideration (§3e, decision 3). |
| Reward asset | 18 stocks, pro-rata dust | **one voted stock per epoch** | Concentration makes the accumulation visible and keeps every buy inside measured depth. |

**Mechanics.** `beforeSwap` (buy: USDG in) takes `feeBps` of `amountSpecified` and `afterSwap` (sell: USDG out) takes `feeBps` of the realized USDG output, both via return-delta accounting, transferring to the vault in the same call. `feeBps`, the USDG address and the vault address are **`immutable` constructor arguments**. The hook's single storage slot is a one-way `disabled` flag: the admin multisig may call `disable()` once, after which both callbacks return a zero delta and the pool behaves as an ordinary v4 pool forever. There is no `setFee`, no re-enable, no proxy — the only reachable state change is the fee ending.

**The vault is where the mandate lives.** `StockDropVault` holds USDG and has exactly one outbound path:

```
swapAndNotify(address winner, uint256 amountIn, uint256 backendMinOut)
  require(winner == epochController.settledWinner())          // stakers chose it
  require(amountIn <= perClipCap(winner))                      // measured 100bps cap / 2
  minOut = max(backendMinOut, slippagePriceChecker.getExpectedOut(...) * (1 - slippage))
  router.exactInputSingle(USDG -> winner, minOut)
  MULTI_REWARDS.notifyRewardAmount(winner, received)           // immutable address
```

`MULTI_REWARDS`, the router, the price checker and the epoch controller are immutable. The caller is `BACKEND_ROLE` for the first 7 days after epoch close and **permissionless thereafter**, so a keeper outage delays the conversion but cannot strand the funds. Even with the backend key fully compromised, the only reachable outcome is *stakers receive the stock they voted for, at an oracle-bounded price*. This is the same shape as the basket mandate (§2j): the agent chooses *when*, never *what* or *at what price*.

**Hook engineering is routine on this chain, verified.** 4663 carries **101,336 hooked v4 pools across 3,830 distinct hooks**, of which **363 carry the exact four-flag combination** we need. CREATE2 address mining (required, since v4 encodes hook permissions in the address low bits) is standard practice here — both CreateX and the Arachnid deterministic deployer are live (`ROBINHOOD_CHAIN_SPEC.md` §1). Budget 1–2 weeks including the mine and the audit delta, not a research project.

### 3d. Pool seeding (POL)

Treasury-owned liquidity, **$300k notional** (≈$150k USDG + ≈$150k MAMO at seed price), recommended split **50% full-range / 50% concentrated ±40%**. The sizing follows from slippage, not from vibes:

```
full-range CPMM, USDG-side reserve X:  execution slippage ≈ tradeSize / X
  X = $150k  ->  100 bps at a  $1.5k  ticket
concentrated to [0.6p, 1.667p]: virtual-reserve amplification A = 1/(1 - sqrt(0.6)) ≈ 4.4x
  $150k concentrated  ->  ≈$660k effective  ->  100 bps at a  ~$6.6k  ticket
blended $300k as specced  ->  100 bps at roughly a $4k ticket, and the full-range half
never goes out of range no matter what MAMO does
```

$300–400k is also the working scale the precedent operated at, which is the only empirical anchor available. Policy, stated in public and not enforced in code: **the POL is committed for a published minimum term of 12 months.** We do not want a credible-neutrality claim that depends on a multisig's restraint, so we say what we will do and let the on-chain record be the proof — the same posture the basket drift band takes as off-chain policy.

### 3e. Program duration — and the sunset as a consideration

**Default: the Stock Drop runs indefinitely.** The hook carries no end date; its only lever is the one-way `disable()` (§3c) — the program can be retired deliberately, in public, and never resurrected or repriced. Whenever it ends, nothing breaks: the pool keeps trading with an inert hook, `MultiRewards` streams out whatever the last conversion funded, and the staking hub keeps its durable streams (capacity priority, the Drop).

**Consideration — a hardcoded sunset.** An earlier draft defaulted to a fixed end date in bytecode (182 days = 13 exact epochs). For it: it removes all discretion, bounds the legal exposure window mechanically, and turns a decaying mechanism into stated urgency. Against it: it kills a working program on a timer, sits uncomfortably close to the countdown theater the brand rules exclude (§11), and the precedent's −97% decay suggests these programs end themselves without help. It remains a live option — decision 3 — and if chosen, epoch alignment (13 × 14d) should be preserved so no epoch is truncated.

---

## 4. Epoch-voted rewards

### 4a. Mechanics

An epoch is **14 days**. The cycle:

| t | Event |
|---|---|
| `t0` | Epoch *N* opens. Staked-balance checkpoint taken. Ballot menu frozen. Voting opens. |
| `t0 → t0+13d` | Fees accrue in USDG in the vault. Stakers vote (changeable until the freeze). |
| `t0+13d` | **Voting freezes** — 24h so the keeper can plan clips against a settled answer. |
| `t0+14d` | Epoch *N+1* opens. Winner is final. Keeper converts epoch *N*'s USDG into the winner in oracle-bounded clips, market-hours-gated by automation A1. |
| `+0–3d` | `notifyRewardAmount(winner, amount)` — streams to stakers over `rewardsDuration = 14 days`. |

### 4b. The ballot is the cleared menu, not the open universe

**Only names that pass the three eligibility gates of §2d can appear on the ballot**: a genuine Chainlink feed (never a `dividends.finance` decoy), real per-name USDG depth, and a **measured** 100 bps trade capacity. That is the ~8-name set: NVDA / AAPL / SPY / GOOGL / TSLA / SPCX, with COST and QQQ as reserves pending their own measurements, and SPCX blocked until its underlying is identified.

**GME and SLV can never be on the ballot.** They rank 3rd and 4th on raw depth and have **zero** capacity at 100 bps, because their liquidity sits only in 1% fee tiers where the fee alone eats the entire slippage budget. This is exactly the trap a popularity vote over an open universe walks into: the meme names are the ones with no execution. Rank on the measured trade cap, never on TVL.

The menu is re-measured **every epoch** by the existing keeper loop (the same QuoterV2 sweep that already feeds A2/A3), and set on the controller by the admin multisig. Two hard rules: menu changes take effect **only at the next epoch open** (never mid-epoch), and the menu is capped at 12 entries to bound both the tally loop and `MultiRewards.rewardTokens`.

This is the same philosophy as every Mamo mandate: **the bounds are admin-set and measured; the choice inside them is the user's.** Stakers pick the name; they cannot pick a name that cannot be bought.

### 4c. Vote rules

- **Stake-weighted**, one name per voter, weight = staked MAMO **checkpointed at epoch open**. Snapshotting kills flash-stake voting: buying in on the last day buys zero voting power.
- Checkpoints are **timestamp-keyed, not block-keyed** — on Arbitrum Orbit, Solidity's `block.number` returns the *L1* block (`ROBINHOOD_CHAIN_SPEC.md` §1), so any block-numbered snapshot is subtly wrong here.
- **Quorum: 10% of checkpointed staked supply.** Below quorum the epoch's proceeds go to the **prior winner** — no re-vote, no stall, no admin discretion. **Genesis default: SPY**, the deepest ETF on the cleared menu and the least concentrated thing on it.
- Ties break to the deeper measured 100 bps cap. Deterministic, and it errs toward executability.
- Vote changes are free until the freeze; there is no lock on the underlying stake (unstaking after the checkpoint keeps the vote — this is deliberate, since forcing a lock would make voting a liquidity decision).

### 4d. Why one name per epoch

Concentration is a product decision with an execution justification.

- **Narrative visibility.** "This epoch, MAMO stakers bought NVDA" is a legible sentence. Eighteen simultaneous dust distributions is what The Index does, and its measured median distribution is $1.64.
- **Depth.** At the realistic revenue range (§7: **$5–25k per epoch**), one name is trivially inside every core name's measured capacity. Even a **$100k** epoch clears NVDA ($170k), AAPL ($60k) and SPY ($34k) in one clip.
- **Clipping, where it binds.** If projected proceeds exceed **50% of the winner's measured 100 bps cap**, the keeper splits the buy into clips ≥15 min apart across the conversion window — reusing A3's TWAP executor. A $30k epoch on TSLA (cap ~$16k) is four clips, not an exclusion. Names are never dropped for size; buys are.
- **Reward-token bound.** The menu cap (12) bounds what can ever enter `MultiRewards.rewardTokens`, keeping `getReward()`'s loop at ~10 tokens including MAMO and USDG.

### 4e. Build

**One small contract** — `StockDropEpochController` (~150 lines): epoch clock, menu, checkpointed tally, `settledWinner()`. Immutable except the menu setter (multisig) and non-upgradeable. Plus **a one-line keeper change**: A11 reads `settledWinner()` instead of a config constant.

**One deviation from the Base deployment, stated plainly.** `FeeSplitter` and `MultiRewards` were expected to redeploy verbatim. Stake-weighted snapshot voting needs a staked-balance history that the Synthetix-fork `MultiRewards` does not keep. The 4663 deployment therefore adds an OpenZeppelin `Checkpoints`-backed staked-balance trace (~25 lines, one extra SSTORE on `stake`/`withdraw`) and is **not byte-identical to Base**. That is an audit delta, small but real, and it is the honest cost of native on-chain voting. `addReward` for each menu token is a one-time multisig action at genesis; the vault is set as each token's `rewardsDistributor`. `RewardsDistributorSafeModule` ports as-is — Safe 1.3.0 and 1.4.1 are fully deployed on 4663 and in production use.

**Legal-scope flag, explicit:** *MAMO stakers collectively directing the purchase of specific named securities* is a materially different activity from *Mamo managing a basket inside a fixed mandate*. It goes on the Jersey review list by name, alongside "paying securities-token rewards to token stakers" (§8). Engineering can build it; it does not ship until legal signs on it specifically.

User-facing framing (in voice): **"This epoch, you pick the stock. Every two weeks, MAMO stakers choose one company. The pool's trading fees are already real — you decide what they turn into."** Nothing about yield, nothing about APY, and the vote is written as an extension of The Mamo Drop, an existing named ritual, not a new concept.

### 4f. Consideration — who picks the stock: stakers, or Mamo?

Worth stating the tension plainly, because it touches the brand's core promise. **Mamo is a "no thinking required" product** — it handles the heavy lifting; the user is never handed homework. A biweekly vote is the engagement and governance-utility mechanic, but it is also, unavoidably, a decision we ask users to make. The alternative is on-brand and simple: **the Mamo agent picks the epoch's stock** — from the same cleared menu, under the same execution bounds — based on published criteria (price movements, news flow, liquidity re-measures; LLM-assisted analysis is an implementation detail of the backend, not a contract surface).

**Recommended hybrid: staker vote with an agent-pick fallback.** Keep the vote, but replace the below-quorum fallback (currently "prior winner") with **Mamo's published pick**: stakers who want a say have one; everyone else gets Mamo's judgment. Each epoch the agent publishes its pick *with a plain-language why* — the brand's no-black-box rule applied to the choice itself. Contract impact is minimal and should be decided before audit: `settledWinner()` gains a `BACKEND_ROLE`-set fallback bounded to the menu (~5 lines); everything downstream — the vault mandate, the clips, the oracle bounds — is unchanged, because **whoever chooses, the cleared menu and the execution bounds still bind the choice.** KPI tie-in: §7's turnout KPI already says a theatre vote should be simplified or retired; the agent pick is the documented successor, so building it as the fallback now removes a future migration.

**Legal flag, added by name:** *Mamo selecting specific named securities on analysis-based criteria* sits closer to discretionary advice than mandate execution, and is a different activity again from stakers voting. It joins the §8 legal list as item (c).

---

## 5. The reinvest — `claimAndDeposit`

### 5a. What it does

Rewards are claimable normally, to the wallet, always. **Or**, in one atomic transaction, the accrued stock is routed **in-kind** into the user's basket strategy:

- **Valued at the Chainlink oracle** — the same feed the basket's NAV already uses.
- **No swap, no pool, no spread.** The stock token moves from `MultiRewards` to the basket. Nothing is sold and re-bought.
- **Counted toward that stock's weight**, then the basket's normal machinery takes over: the next `rebalance` trims any resulting overweight and the excess lands in the spUSDG sleeve, earning 3.50%.

### 5b. Rules

1. **A basket accepts in-kind rewards only for stocks already in its fixed set.** The stock set is immutable at initialization (§2f) and this does not change that. NVDA reward → AI basket, yes. NVDA reward → SPY basket, no.
2. **Anything the basket cannot accept stays claimable to the wallet** in the same transaction. The user is never blocked, never partially stuck.
3. **Sub-threshold accruals are left unclaimed.** Below `minInKindValue` (recommend **1 USDG** of oracle value) the router skips the token entirely — it keeps accruing in `MultiRewards`, which is strictly better than paying gas to move dust. This is the direct fix for the $1.64-median failure mode.
4. **In-kind deposits are metered against the basket's supply cap** at oracle value, via `recordDeposit` — otherwise the cap leaks and the staker-reserved carve-out stops meaning anything.
5. **The mandate is not violated by a user deposit.** An in-kind deposit can push the equity share above `maxTotalStockBps`; the deposit still succeeds and the next rebalance sells the excess into the sleeve. `maxTotalStockBps` binds the *agent's* weight-setting, not the *owner's* deposits — which is already true today for large USDG deposits pushing the equity share down.
6. **In-kind deposits inherit the equity-feed dependence** that plain USDG deposits do not have (they price through the oracle). They therefore fail during the ~50h weekend feed freeze. Small, real UX regression; the keeper schedules conversions and notifications inside the trading week regardless.

### 5c. Build

`MamoRewardRouter`, permissionless and stateless, holding nothing between transactions and having no admin. Two entry paths:

- **Via the staking strategy** (the ported per-user `MamoStakingStrategy` pattern): owner calls the router, the router calls the strategy's registry-authenticated `claimTo`, then deposits in-kind. Atomic.
- **Direct stakers**: claim to wallet, approve the router, router deposits. Same code path after the claim.

Both require `MamoStrategyRegistry.isUserStrategy(msg.sender, target)` for the destination basket, so the router can only ever move a caller's assets between contracts the caller owns.

**Prerequisite:** `StockBasketStrategy.depositStock(address token, uint256 amount)` — permissionless like `deposit`, requires `token ∈ stockTokens`, pulls the token, prices it through the oracle for cap accounting, buys nothing. ~40 lines. It is also a **standalone capacity unlock**: it is the only way to enter a basket without touching a DEX pool at all, which means a user already holding NVDA-token can join without paying the 26–52 bps of pool-vs-oracle cost measured in §2g, and without consuming any of the measured 100 bps trade budget. That is worth building even if the reward mechanism never shipped.

### 5d. Why it matters

Stated plainly, because this is the mechanism that makes "flywheel" a claim rather than a diagram:

- It **converts the speculative door's output into the passive door's AUM**, mechanically, in one click. Pool-fee revenue does not become a token holder's wallet dust; it becomes basket AUM, which is fee-bearing, capped, and staker-gated.
- It **fixes the measured dust-rewards failure.** The Index's median distribution is $1.64. Ours defaults to compounding into a portfolio instead of landing in a wallet.
- It **closes the loop**: trading → rewards → AUM → fees → Drop → stakers → more staking → more capacity priority.

User-facing framing (in voice), mirroring the existing "Reinvest (Grow your Bitcoin stack)" option in Mamo's docs — this is a named pattern users already know: **"Reinvest — grow your basket. Send your stock rewards straight into the basket you already hold. No claiming, no swapping, nothing left behind. Set it once and Mamo handles the rest."**

---

## 6. The staking hub

`MultiRewards` on 4663 (checkpointed variant, §4e) is the single place all three streams land. Staking is native and local — no cross-chain attestation anywhere in the design.

| Stream | Source | Cadence | Durable? |
|---|---|---|---|
| **Stock rewards** | pool fee → epoch winner | streamed over each 14d epoch | Runs while the pool trades; retirable via the one-way `disable()` |
| **Capacity priority** | basket supply caps | continuous | Yes |
| **The Drop** | `compoundFee` + management fee → `FeeSplitter` | quarterly, then weekly (below) | Yes |

**Native capacity gating.** Because MAMO is native on 4663 and staking is local, the staker carve-out is enforced on-chain with no attester: `MamoVaultConfig.recordDeposit` reads the staked balance directly.

```
reserved      = remainingCapacity * reservedBps          // recommend reservedBps = 5000
openToAll     = remainingCapacity - reserved
if (deposit consumes into `reserved`)  require(multiRewards.balanceOf(user) >= minStake)
```

Roughly ten lines in `recordDeposit`, no oracle, no off-chain input, no trusted attester. The alternative — enforcing the carve-out against backend-attested staking balances held on another chain — would reintroduce exactly the trusted-attester problem the rest of the architecture removes, so bridging MAMO before launch is a security decision as much as a product one. Capacity utilization is already published by automation **A8**; the front end reads the same feed and shows two numbers: open capacity and staker-reserved capacity. **Both baskets need the `MamoVaultConfig` wiring that §9 item 4 already schedules** — baskets are not metered today at all, so this rides an existing critical-path item rather than adding one.

**The scarcity is measured, not manufactured.** Caps are set from measured depth (§2g), and they rise only when re-measured depth supports them — with stakers keeping first access every time they do. That converts the standing monitoring tripwires (equity-DEX depth, feed coverage, subsidy runway) into cap-raise triggers with staker priority.

**Drop cadence.** At $1.1M of caps a weekly Drop is ~$70 and reads as parody. **Accrue and distribute quarterly until the run-rate clears $2,500/week (~$130k/yr of fee base), then switch to weekly.** The trigger is published in advance so the switch is a milestone rather than an announcement. Note that while the Stock Drop runs, the *stock* stream will dominate the Drop by an order of magnitude — say so rather than letting the comparison be discovered.

---

## 7. Revenue and honesty

**Neither door is a revenue product on day one, and the spec says so first.**

- **Door 1**: ≈**$3.7k/yr** at full launch caps. Basket 1 at a full $750k: 50 bps × 60% equity = $2,250/yr of management fee, plus ~$525/yr from `compoundFee` on the sleeve. Basket 2 at $350k: ~$525 + ~$430. **A rounding error, and the spec should say so before anyone else does.** The launch buys the uncontested seat and proves the flywheel. The revenue line scales with caps (which scale with pool depth) and with sleeve yield. After the gas subsidy expires (~2026-09-29), backend-paid rebalance gas nets against this fee base — with a fee base this small, gas netting is not academic.
- **Door 2**: **$0 to Mamo.** The pool fee goes **100% to stakers**, with no treasury cut, for the program's life. There is no revenue line to defend, which is exactly why a deliberate retirement is credible.

**Sizing Door 2's output, from the precedent.** The Index at its *decayed* floor still moves ~45.7 ETH/day ≈ $85.6k/day of taxable throughput. A new MAMO/USDG pool with $300k of POL should be sized against a fraction of that:

| Scenario | Volume/epoch | Fee @ 200 bps | Fits in one clip? |
|---|---|---|---|
| Quiet | $250k | **$5k** | Yes, every core name |
| Central | $750k | **$15k** | Yes, except TSLA (2 clips) |
| Loud | $5M | **$100k** | NVDA/AAPL/SPY yes; others clipped |

Even the loud case is inside measured depth. Capacity is not the constraint on this mechanism at any realistic scale — which is the entire reason the single-name concentration is safe.

**What each door manufactures for the other:**

| Door 1 gives Door 2 | Door 2 gives Door 1 |
|---|---|
| a real product behind the token (the reason a MAMO buyer is not just buying a ticker) | a reason to hold and stake MAMO, which gates basket capacity |
| the destination for reward compounding (AUM that pays fees) | AUM arriving in-kind at zero acquisition cost — no pool, no spread, no capacity consumed |
| the fee stream that outlives the pool program | attention and distribution during a launch window when baskets have no track record |

**KPIs — four numbers, published:**

1. **Staked %** of MAMO circulating on 4663. The token-side health metric.
2. **Epoch turnout** — % of checkpointed stake that voted. Below quorum twice in a row means the vote is theatre and should be simplified or retired.
3. **`claimAndDeposit` conversion rate** — % of distributed reward value routed in-kind rather than claimed to wallet. **This is the flywheel's actual efficiency**; if it is near zero, we have shipped two products sharing a logo.
4. **Basket fill rate** — % of each cap filled, and what share of filled capacity came from stakers. Tells us whether the carve-out is a real utility or a decorative one.

---

## 8. Risk register

One table, both doors, ordered by severity (impact first, then likelihood).

| Risk | L / I | Mitigation |
|---|---|---|
| **Legal scope growth** — (a) paying **securities tokens** as staking rewards to token holders, (b) stakers **collectively directing purchases of named securities**, (c) if the §4f agent-pick fallback ships, **Mamo selecting named securities on analysis-based criteria**. All three are new activities, not extensions of "managed basket". | **High / Severe** | The dominant new risk. All three go on the Jersey/regulatory review list **by name**, not as a footnote to the basket review. Door 2 does not ship without specific sign-off; Door 1 ships regardless. The one-way `disable()` can end the program on demand if counsel requires. |
| **Regulatory** — tokens barred to US/UK/CA/CH/UAE persons; composability is the documented leak vector and is already drawing press | Medium / Severe | Geo-gate our own front end (and the concierge API, §12); legal review before launch (§9); non-US TAM accepted as the product's premise, not a surprise. |
| **Smart contract: unaudited** | — / Severe | Non-negotiable launch gate. 14 unit + 26 real-bytecode + 13 fork tests are evidence of correctness, not a substitute for audit. Launch caps are sized so the worst case is bounded. |
| **Issuer blocklists our contract addresses** — `AccessControlsRegistry` can do it in one transaction | Low / Severe | The core structural mitigation: per-user strategies bound the blast radius to one user, where a pooled vault would freeze everyone. Legal review of the Jersey prospectus is a launch gate; small caps limit exposure; disclose the power explicitly. |
| **Hook immutability cuts both ways** — no fix path, no pause, no upgrade. A bug is permanent. | Low / Severe | Audit it like it is forever, because it is. Keep the hook under ~150 lines with a single one-way storage flag; differential-test against the precedent's live behaviour; deploy the mined address only after audit sign-off. Blast radius is bounded to the fee leg — a broken hook cannot touch baskets, the vault's mandate, or user funds. |
| **Frozen feeds traded against** — the 26h bound permits ~26h of trading at a stale Friday price | **High / High** | The single most likely production incident today. The two-tier guard (calendar/liveness + ~1–2h intraweek bound) is a hard prerequisite (§9 item 3). |
| **Pooled stock custody in `MultiRewards`** — the reward buffer holds stock tokens for all stakers, which is precisely the pooling baskets avoid. The issuer can blocklist that one address. | Medium / High | Bounded by size: only *undistributed* rewards sit there — one epoch's proceeds, $5–25k central case. `claimAndDeposit` shortens residence time structurally. Buffer balance is a monitored quantity (extend A9's blocklist watch to the `MultiRewards` address). Disclose it: this is the one place Mamo pools stock tokens. |
| **Comms sequencing** — the pool is the loud thing; the baskets are the trustworthy thing. Lead with the pool and Mamo becomes a memecoin with a portfolio feature. | Medium / High | Hard sequencing rule: **baskets launch first and stay the headline**; the Stock Drop is framed as *how MAMO arrives on the chain*, always downstream of the product. Every Door 2 asset must name Door 1 first. |
| **Feed rotation strands a consumer** — every verified address is a raw aggregator, not a consumer proxy | Medium / High | Bind production to consumer proxies from the Chainlink docs directory, never to aggregators. Requires an external fetch (§9 item 3). |
| **Decoy feeds** — 31 dividends.finance feeds cover exactly the tickers Chainlink does not | Medium / High | Never enumerate feeds by description; allowlist feed addresses explicitly per basket; the eligible set in §2d is closed, not discovered at runtime. The ballot menu inherits the same closed set. |
| **Impostor tokens** — spam ERC-20s with copied symbols exist (a fake `APPLE` named "Pump Killer") | Medium / High | Identify by the "… • Robinhood Token" name suffix, **never by symbol**; asserted in the fork suite; hardcode addresses in deploy config. |
| **`uiMultiplier` double-counting** — would overstate a split name by its multiplier (CRWD: 4x) | Medium / High | Feed price already includes it; NAV never multiplies by it; asserted live in the fork suite. |
| **Issuer pause / burn / confiscate on individual balances** | Low / High | Same per-user bound; disclosed in product copy; no pooling of stock tokens anywhere in the design except the reward buffer above. |
| **Sleeve gates set after we are funded** (`sendSharesGate` traps a position) | Low / High | All four gates read `address(0)` today; ongoing off-chain gate monitoring (A5) is a launch deliverable, not a listing-time check. |
| **Chain: ArbOS transaction filtering can nullify force-included transactions** | Low / High | Disclose honestly — the standard "you can always withdraw" guarantee is weaker here. L2Beat classifies 4663 "Other", not a rollup. |
| **Capacity / thin-leg liquidity** — the thinnest leg binds the whole basket | High / Medium | Caps at ~3x inside the drift ceiling; depth-tilted weights; TWAP clips; measured trade caps, not TVL, drive eligibility; per-stock fee tiers + v4 routing roughly double it (§9, deferred). |
| **Weekend gap** — Friday-close to Monday-open moves cannot be traded through | High / Medium | Structural to the asset class and disclosed. Sleeve-first exits mean ordinary withdrawals are unaffected; the position simply sits. |
| **Reflexivity** — trade-fee revenue is measurably self-consuming (−97% peak-to-now on the precedent) | **High / Medium** | Never quoted as APY; never in a yield table; the front end shows realized purchases, not projected rates. The one-way `disable()` retires the program deliberately if it decays to noise; a hardcoded sunset remains a consideration (decision 3). |
| **MAMO becomes a speculation object** — a fee hook and a stock-buying flywheel invite trading behaviour Mamo has not previously courted | Medium / Medium | **A token-governance decision, not an engineering one — flag it for the owners of the token.** Containment: baskets stay the headline, the program is retirable, and no MAMO emissions are introduced anywhere in this launch. |
| **POL exposure** — $300k of treasury capital in a two-sided position, impermanent-loss-exposed and unhedged | Medium / Medium | Sized as a launch cost, not an investment. Half full-range so it cannot go out of range. A published minimum commitment term (12 months) makes the exposure a stated commitment rather than a surprise. |
| **Adverse LP selection on stock/USDG pools** — LPs write a free straddle to weekend gap traders, so depth may thin further | Medium / Medium | We are a taker, not an LP. The oracle bound means a thin book produces a revert, not a bad fill. Re-measure trade caps before each cap increase. |
| **Chain: centralized sequencer, no uptime feed** | Medium / Medium | ETH/USD (24/7, ~44 min cadence) as a liveness proxy plus conservative bounds until Chainlink ships an uptime feed. |
| **Keeper liveness on conversions** | Low / Low | `swapAndNotify` goes permissionless 7 days after epoch close; bounds are immutable, so an anonymous caller gets the same outcome the backend would. |

---

## 9. Build plan and critical path

**Posture: launch now.** The market gap (idle stock tokens, no credible manager) is open today, the competitive field is measured-empty, and the seat is worth a deliberate year-one cost center. Target **~2–3 months**: contracts (2–4 weeks of build), the P0 keeper set, and the audit run in parallel. **Legal review runs at the org level and keys the final date — engineering does not pace on it.** Launch posture: genesis-capped, staker-priority.

Ordered. Owner shape in brackets.

| # | Item | Owner | Size | Notes |
|---|---|---|---|---|
| 1 | **Bridge MAMO to 4663 via Wormhole** | infra | days | Gates Door 2 entirely and gates native capacity gating. Do it first; the path is already operational for MAMO. |
| 2 | **Venue-registry reconciliation, on our branch** | contracts | ~1 wk | Fold `MamoVaultConfig`'s supply cap and registry-authenticated accounting into the append-only / soft-deactivate semantics of the audit branch's `MarketRegistry` — one venue registry, not two. **Do this as a port into this branch: do not merge the audit branch.** That branch is mid-audit; taking a dependency on it makes our launch date theirs. |
| 3 | **Market-hours guard module + production price checker** | contracts + external | ~1–2 wks | The two-tier guard of §2i: calendar/liveness gate plus per-feed-class staleness (~1–2h equity intraweek, ~26–27h USDG), `oraclePaused()` and staged-multiplier reads, ETH/USD as the sequencer-liveness proxy. Also a staleness-flagged NAV read path so `getTotalBalance()` does not revert on weekends. **Blocked on an external fetch:** Chainlink **consumer proxy** addresses and declared heartbeat/deviation parameters from the docs directory. Everything verified on-chain is a raw aggregator; shipping bound to those means a feed rotation strands us. |
| 4 | **Wire the caps and the fees into `StockBasketStrategy`** | contracts | small | One `MamoVaultConfig` per basket family with the §2f caps; `recordDeposit` / `recordWithdraw` / `recordFullExit`; `compoundFee` + `feeRecipient` matching the chassis; management-fee accrual on the equity share. Also lower `MAX_SLIPPAGE_IN_BPS` from 2500 to 500. The product has no revenue and no cap until this lands. |
| 5 | **`StockBasketStrategy.depositStock` (in-kind entry)** | contracts | ~40 lines | Prerequisite for §5 **and** a standalone capacity unlock. Ships with item 4. |
| 6 | **Native staker capacity gating in `MamoVaultConfig`** | contracts | ~10 lines | §6. No attester, no oracle, no off-chain input. Rides item 4. |
| 7 | **`MultiRewards` (checkpointed) + `FeeSplitter` deploy on 4663** | contracts | ~1 wk | +25 lines of checkpoints; `addReward` for the menu at genesis; audit delta (§4e). |
| 8 | **`StockDropEpochController`** | contracts | ~150 lines | Clock, menu, timestamp-keyed checkpointed tally, `settledWinner()`. |
| 9 | **Fee hook + `StockDropVault`** | contracts | **1–2 wks** | Includes the CREATE2 flag mine. Zero storage in the hook beyond the one-way flag. |
| 10 | **`MamoRewardRouter`** | contracts | ~100 lines | Stateless, permissionless, registry-authenticated. |
| 11 | **Factories + deploy tooling** | contracts | ~1 wk | Basket factory on the multi-market factory pattern; `addresses/4663.json`; `deploy/4663_*.json` with the §2f parameters; parameterize the hardcoded keys in `DeploySystem.s.sol`; verify Cancun / via-IR support on the Orbit node. |
| 12 | **Venue set** | backend | days | spUSDG verified and added 2026-08-05 — add its UUPS admin and rate-setter to the standing governance monitor. Turbo, Ethena and Grove still pending the same verification (gates, TVL, organic yield, share-price behaviour). Plus the standing gate monitor on every allowlisted vault. |
| 13 | **Measure COST's 100 bps trade cap; identify SPCX's underlying** | backend + external | days | Both are cheap and both unlock a listing decision — for baskets and for the ballot menu. SPCX must not ship on liquidity alone. |
| 14 | **Tenderly automations, including A11** | backend | ~2 wks | Rebalance scheduling, TWAP clip execution, gate monitoring, Merkl claims — all of it, since neither Chainlink Automation nor Gelato exists on 4663. **A11 — fee-conversion keeper**: cron 1h, gated by A1 market-hours, reads `settledWinner()`, clips at ≤50% of the winner's measured 100 bps cap ≥15 min apart via A3's executor, calls `swapAndNotify`, alerts if unconverted at epoch close +5d. Spec it into `ROBINHOOD_TENDERLY_AUTOMATIONS.md` §4. |
| 15 | **POL seeding runbook** | ops | days | Pool init, mined hook address, range placement, public no-withdraw statement (12-month minimum term). |
| 16 | **Legal review + geo-gated front end** | external — org-level | in hand | The Jersey base prospectus question (third-party contracts holding tokens for a mixed-jurisdiction user base; the issuer's policy on contract addresses) plus the three named Door 2 activities (§8). Handled outside engineering. **The launch date keys to its completion; nothing else waits on it.** |
| 17 | **Audit — one shared gate** | external | after 2–11 | Basket mandate and oracle-bound invariants; cap accounting under non-par share prices; the NAV path's `uiMultiplier` handling; hook immutability and return-delta accounting; vault mandate; checkpoint correctness under stake/withdraw; router authentication; in-kind deposit cap accounting. |
| 18 | **Mamo concierge (MCP)** — *consideration, not launch-blocking* | backend | ~2–4 wks | Read API + calldata builder + MCP server (§12). Ships within the launch window if greenlit; no contract changes. |

**Deferred, deliberately:** per-stock fee tiers plus v4 routing — roughly **2x capacity** and the thing that lets NVDA use the 0.05% tier, but capacity is not binding at genesis caps and the 0.30% tiers serve the launch lineup. It belongs to the first cap raise, not to launch.

**On the clock but not blocking:** the gas subsidy expires around **2026-09-29**, after which per-user rebalance economics need re-checking against the §7 fee base.

**Explicitly NOT in scope:**

- **Boosted USDG stays dark.** Launching a ~4–5% product beside a subsidized 7% is worse than not launching it; the measured carry does not exist at scale and has worsened (`BOOSTED_USDG_SIZING.md` §6). It flips on at the subsidy cliff, as the upsell to the basket user base, when its own triggers fire.
- **No leverage products of any kind.**
- **No push distribution, ever.** Pull-based `MultiRewards` only.
- **No open-universe ballot.** The cleared menu is the ballot, permanently.
- **No vote-incentive ("bribe") markets.** Named here as a *future option* — third parties paying stakers to vote for a name is a coherent extension and an obvious one. It is not designed, not built, and not committed; it also has its own legal surface and should not be casually inherited.
- **No MAMO emissions.** Every reward here is bought with realized revenue.
- **No treasury cut of the pool fee** during the program.

---

## 10. Open decisions for review

Recommendations given; each is a real decision, not a formality.

| # | Decision | Recommendation | Why / what moves it |
|---|---|---|---|
| 1 | **Pool fee rate** | **200 bps** | 300 bps is the proven-credible precedent, but with a 30 bps LP fee the round trip is ~4.6% at 200 and ~6.6% at 300. We are taxing the volume the mechanism monetizes. Go 300 only if the pool is explicitly a distribution event and low volume is acceptable. **Immutable — decide before the mine.** |
| 2 | **Epoch length** | **14 days** | Long enough that proceeds are a legible number and a vote is worth casting; 7d halves per-epoch size and doubles keeper load; 30d makes turnout decay. |
| 3 | **Program end** | **Indefinite + one-way `disable()` (default); hardcoded sunset as a consideration** | The default keeps a working program alive and avoids countdown theater; the retire switch is the deliberate end path. If a sunset is chosen instead, 182d (13 × 14d) aligns epochs exactly, and longer starts to look like a permanent revenue claim. Either choice is immutable — decide before the mine. |
| 4 | **Reward set** | **Single name, voted** | Concentration is the narrative and costs nothing in execution at realistic size. The alternative — pro-rata across the menu — is exactly The Index's $1.64 dust failure. |
| 5 | **POL size** | **$300k** (50% full-range / 50% ±40%) | ~100 bps at a ~$4k ticket. $400k buys a ~$5.5k ticket and is defensible; below $200k the pool is too thin to attract the volume the fee needs. |
| 6 | **Staker reservation** | **50% of remaining capacity**, `minStake` TBD | 50% is the working proposal. `minStake` should be set from the actual staker distribution after the bridge, not guessed now. |
| 7 | **Quorum** | **10% of checkpointed stake**, fallback = prior winner, genesis = SPY | Deliberately low: the fallback is benign, so a high quorum only manufactures failed epochs. |
| 8 | **Drop switch** | quarterly → weekly at **$2,500/week** | Publish the trigger in advance. |
| 9 | **`MultiRewards` byte-identity with Base** | accept the **+25-line checkpoint delta** | The alternative is off-chain vote-weight computation, which reintroduces exactly the trusted-attester problem native staking was supposed to remove. |
| 10 | **Comms order** | **baskets first, always** | Sequencing is the main containment for the "Mamo becomes a memecoin" risk (§8). |
| 11 | **Who picks the epoch stock** | **Staker vote with agent-pick fallback** (§4f) | Pure vote maximizes the utility story but hands users homework; pure agent-pick is on-brand ("no thinking") but weakens governance utility. The hybrid keeps both: vote if you care, Mamo decides when you do not — with its reasoning published. ~5-line controller change; decide before audit; carries legal flag (c). |

Launch line (in voice): **"Mamo is not bringing another savings account to Robinhood Chain. It is bringing the part that was missing: a portfolio that manages itself, in plain language, under your control."** Door 1 is the product; Door 2 is how MAMO gets there. Nothing in the copy implies the fee stream is a yield, and nothing promises it lasts.

---

## 11. Voice and naming

Sourced verbatim from Mamo's published docs (`docs.mamo.bot`, via the public `moonwell-fi/mamodocs` GitBook source). The rules that bind every user-facing surface of this launch:

- **Identity:** "a finance companion, not a finance tool." Second person always ("your basket", "your money"); Mamo is "it", never "he/she". Persona signals: calm protector ("Mamo 守"), 🌱 motif — one emoji per heading at most, none mid-sentence, no exclamation marks. No capybara — it does not exist in the brand.
- **Vocabulary:** *Account*, not vault; *put your money to work*, not deploy; *reallocate*, not rebalance; *earnings / what you earn*, not yield or APY in any headline ("good available returns" is the strongest permitted claim; precise APY figures live only where precision protects the user). *No degen register of any kind.*
- **Never say "tax."** The brand's published don'ts exclude tax/reflection-token mechanics. User-facing copy says **"pool fee" or "trading fees"**; the immutable hook is the proof behind "trust comes from proof, not promises" (their line). Engineering docs keep the precise word.
- **Extend named things, never invent parallel ones.** The epoch purchase is an extension of **The Mamo Drop**; claim-to-basket is **Reinvest**, the option name Mamo already ships for Bitcoin. Naming continuity is free brand equity. The program is the **Stock Drop** — never "Initiation".
- **Honesty is house style.** Mamo volunteers downside unprompted ("Honest about risk" is a standing docs section). The four hard truths — markets close ~50h on weekends, baskets are capped on purpose, no single blended number will ever be quoted, tokenized stocks are not available everywhere — are written in-voice, on the first screen, not the last.
- **No urgency theater.** The caps are genuinely scarce — state it calmly and let the fact do the work; the same rule argues against a hardcoded sunset (decision 3). Countdown-style FOMO inverts the brand.

---

## 12. Consideration — the Mamo concierge (MCP)

Today Mamo's interface is a chat with basic tools. This launch is an opening to ship something better *alongside* it without rebuilding it: **an MCP server that turns the user's agent harness of choice into a Mamo concierge.** Any agent that speaks MCP — Claude, or whatever the user already runs — gets:

- **Read tools**: basket state and NAV, sleeve rate, epoch status and current ballot, accrued rewards, capacity remaining (open vs staker-reserved), the published agent-pick reasoning (§4f).
- **Action tools**: calldata generation for every user action — deposit, withdraw, Reinvest, stake, vote — returned for the **user's own wallet to sign**. The concierge composes transactions; it never holds keys and never signs.

**The safety story is the architecture we already shipped, extended for free.** Every hard bound in the system — the basket mandate, the oracle-floored swaps, the owner-only fund paths, the cleared ballot menu — binds *any* caller, including an agent we did not write. A misbehaving third-party harness can only ever produce transactions the contracts permit. "An agent you do not have to trust" was built for our backend; it turns out to be exactly the property that makes opening the surface to other agents safe. No other product on this chain can make that claim.

**Build shape** (backend-owned, no contract changes): a read API over state we already index for the Tenderly automations, a calldata/tx-builder service, and the MCP server wrapping both. Geo-gating enforced at the API layer, same policy as the front end. **Not launch-blocking** — the chat UI remains the default door — but shipping it inside the launch window turns the launch's attention into distribution in the interfaces users already live in, and is an honest answer to the fact that our current agent UI is the weakest part of the product. Costed in §9 as item 18; greenlight is a product decision, not an engineering one.

---

*Companion documents, for evidence rather than prerequisite: `ROBINHOOD_CHAIN_SPEC.md` (the verified chain facts and [V] tags behind every number here), `BOOSTED_USDG_SIZING.md` (the measured case for keeping levered USDG dark), `ROBINHOOD_TENDERLY_AUTOMATIONS.md` (the keeper build, A0–A11), and `MAMO_BASKETS_SPEC.md` (the basket implementation deep-dive). Nothing in this document depends on reading them.*
