# Mamo on Robinhood Chain — v2 Product Specification

*Status: product spec for the full two-product launch. This document **extends** `docs/MAMO_BASKETS_SPEC.md` (v1), which stays authoritative for everything about baskets — lineup, weights, caps, capacity math, basket risks. v2 adds the second door (a MAMO/USDG pool with an immutable trade-tax hook), the staking hub that fuses the two, and the two new mechanisms that make the fusion mechanical rather than rhetorical: **epoch-voted stock rewards** and **claim-to-basket compounding**.*

*Grounded in: `ROBINHOOD_CHAIN_SPEC.md` §1 (verified chain facts, [V] tags), `BOOSTED_USDG_SIZING.md` (why yield products stay dark), `ROBINHOOD_TENDERLY_AUTOMATIONS.md` (keeper patterns; the tax-conversion keeper becomes **A11** there), and the on-chain teardown of **"The Index"** — a live trade-tax token on 4663, measured 2026-08-05, which is the only working precedent for this mechanism on this chain and supplies both the design we copy and the failures we fix.*

---

## 1. Summary

**The opportunity.** Tokenized real-world assets are the strongest narrative in crypto, and equities are its center of gravity. Robinhood — a top consumer brokerage — has made its chain the flagship venue for on-chain stocks: ~95 tickers live, ~$70M of stock-token AUM within weeks of launch and growing, and institutional rails (Morpho, Chainlink, Uniswap) deployed from genesis. What the chain does not yet have is a credible manager for those assets — the competitive field is measured-empty ($41 of competitor TVL at last teardown), and the seat for *the money manager of on-chain stocks* is open. Mamo is built for exactly that seat: audited history, per-user custody, hard on-chain mandates. This spec is the plan to take it.

**One launch, two doors, one flywheel.**

**Mamo arrives on Robinhood Chain. Same companion, new ground.** Until now Mamo helped your money earn. Now it can help your money own. **Door 1 — Mamo Baskets:** you deposit USDG, Mamo builds your basket of tokenized stocks, keeps it on target, and keeps the cash half earning. Calm, capped, per-user, exactly as specced in v1. **Door 2 — the Stock Drop:** MAMO arrives on the chain with its own market, and that market's trading fees do one thing — they buy real tokenized stocks for MAMO stakers. Every trade buys a piece of the market for the people who hold the token. *(Voice rule §11: user-facing copy says "trading fees" or "pool fee", never "tax".)*

The two doors are not two products with a shared logo. They are wired:

> **The flywheel, in one line:** trading MAMO buys stocks → stocks are paid to stakers → stakers reinvest them in-kind into their baskets → baskets are capped, so basket capacity is what stakers get first → basket fees come back to stakers as the Drop.

**What is new versus v1:**

| | v1 (baskets spec) | v2 (this document) |
|---|---|---|
| Products | Baskets only | Baskets + the MAMO pool (the Stock Drop) |
| MAMO on 4663 | "bridge pre-launch, nice to have" | **launch-critical** — the second door is denominated in it |
| Staking utility | capacity carve-out, backend-attested against Base balances | **three streams**, all native on-chain: stock rewards, capacity priority, the Drop |
| Reward assets | USDG (+MAMO later) | + **one tokenized stock per epoch, chosen by stakers** |
| Reward destination | wallet | wallet **or** in-kind into your basket (`claimAndDeposit`) |
| New contracts | — | trade-tax hook, tax vault, epoch controller, reward router, in-kind basket deposit |

**What does not change.** Baskets remain the headline product and the thing we ask people to trust. Boosted USDG stays dark (`BOOSTED_USDG_SIZING.md` §6 — the carry does not exist at scale, and it has *worsened*: syrupUSDG's organic spread flipped **−51 bps** on the 2026-08-05 re-measure). No leverage ships. The launch is still bought for stance and the option, not for revenue.

**The honest frame for Door 2.** The pool fee is **not yield and must never be quoted as an APY** — The Index's own volume is down ~97% from its peak window (§3); trade-fee revenue is reflexive and varies with the trading it rides on. **By default the Stock Drop runs indefinitely.** The hook carries exactly one lever: a **one-way, irrevocable `disable()`** held by the admin multisig that can set the fee to zero forever — it can never raise the fee, never redirect it, never re-enable it. A **hardcoded sunset** (a fixed end date in bytecode) is retained as a consideration, not the default (§3e, decision 3).

---

## 2. What carries over from v1

Read `MAMO_BASKETS_SPEC.md` for the full argument. Carried here only for reference:

**Launch lineup** (§3b, §3d there):

| Basket | Composition | Stock/sleeve | Supply cap | Single-clip build limit |
|---|---|---|---|---|
| Mamo AI & Mega-cap Tech | NVDA 30% / AAPL 15% / GOOGL 8% / TSLA 7% | 60 / 40 | $750k | $200k |
| Mamo Blue-chip Index + Yield | SPY 30% | 30 / 70 | $350k | $100k |

$1.1M of combined capacity. Small on purpose: capacity is the binding constraint, and **scarce capacity is the MAMO utility** — v2 makes that gating native (§6).

**Headline verified numbers.** Live round trip (deposit 2,000 USDG → rebalance to a 45% NVDA/AAPL/TSLA basket → `withdrawAll`) cost **26 bps of NAV** against real feeds, real 0.30% pools and the real Steakhouse vault; rebalance leg drifted 17 bps against a 17.9 bps prediction. Sleeve is Spark **spUSDG at 3.500% contractual**; Earn's on-chain all-in rate is only ~2.1–2.4% (the ~7% headline is app-side). Fee model: `compoundFee` ≤10% of sleeve yield + **50 bps/yr on the equity share only**. Revenue at full launch caps: **≈$3.7k/yr** — stated plainly in v1 and unchanged by v2.

**Eligible universe** (§3a there) — the gate set that v2's ballot inherits verbatim:

| Ticker | Feed | v3 USDG depth | Largest trade < 100 bps | v1 verdict |
|---|---|---|---|---|
| NVDA | yes | $779k | ~$170k | Core |
| AAPL | yes | $69k | ~$60k | Core |
| SPY | yes (ETF) | $144k | ~$34k | Core |
| GOOGL | yes | $56k | ~$20k | Core |
| SPCX | yes | $382k | ~$20k | Deep, blocked — underlying unidentified |
| TSLA | yes | $63k | ~$16k | Core |
| COST | yes | $70k | not measured | Reserve |
| QQQ | yes (ETF) | $73k | ~$4k | Reserve |
| GME / SLV | yes | $218k / $185k | **$0** | Rejected — 1%-tier-only liquidity |

**Launch-now critical path** (v1 §7, ordered): venue-registry reconciliation → market-hours guard + production price checker → wire caps and fees into `StockBasketStrategy` → factories and deploy tooling → venue set → COST/SPCX resolution → Tenderly automations → legal review + geo-gated front end → audit. Per-stock fee tiers and v4 routing are deferred to the first cap raise. v2's additions attach to this path in §9; **none of them reorder it.**

---

## 3. Door 2 — the MAMO pool and the Stock Drop

### 3a. What it is

A **MAMO/USDG Uniswap v4 pool on chain 4663** with one hook attached. The hook takes an immutable percentage of the USDG leg of every swap and sends it to an immutable destination. A keeper converts that USDG into **one tokenized stock per epoch — the stock MAMO stakers voted for** — and streams it to stakers through `MultiRewards`. The program is **the Stock Drop** — the on-chain extension of The Mamo Drop, the reward ritual Mamo already ships. By default it runs indefinitely; its only lever is a one-way retire (§3c, §3e).

MAMO reaches 4663 via **Wormhole** (per v1 §2 — `Mamo.sol`'s Superchain leg does not port to Orbit; the Wormhole path is already operational for MAMO). Bridge execution moves from "nice to have" to launch-critical, because Door 2 is denominated in it.

### 3b. The precedent, measured

"The Index" is a trade-tax token live on 4663 since block ~1.67M. Everything below was read on-chain on 2026-08-05; addresses are given so the claims are checkable.

| Measured | Value |
|---|---|
| Hook | `0x2cd91bd228ff4c537031d6b8204782090c84c0cc` — 5 pools, flags `beforeSwap+afterSwap+beforeSwapReturnDelta+afterSwapReturnDelta` (address low bits `0x0cc`) |
| Tax destination | `0x1604ff11dfeaac437077aeda2fa492ac9ec804df` (treasury EOA-controlled), **verified 1:1 pass-through** |
| Push distributor | `0x39adb8acd07427d338b5f1afab436a04abfdb7c4`, **18 stock tokens** configured |
| Lifetime flow | **62,565 swaps**, **21,085 ETH** two-sided throughput ≈ **$39.5M** at ETH $1,873 (chain feed); implied 3% tax ≈ **633 ETH ≈ $1.19M** |
| Volume decay | peak 5.8-day window **8,930 ETH** → most recent equivalent window **265 ETH** = **−97%** |
| Holders | 11,030 non-zero, 8,718 above 1 token, 984 above 100k |
| Distribution cost | ~**925M gas** per hourly round; **$74** effective eligibility floor; **$1.64** median distribution; holder list assembled **off-chain** |
| Governance | distribution destination **silently redirected 3×** by a bare EOA |

Two conclusions, both load-bearing:

1. **The tax leg works and is credible precisely because it is dumb.** Stateless, ownerless, hardcoded bps, immutable destination. There is no lever to pull, so nobody has to trust anyone. That is why a 3% tax survived $39.5M of volume without a governance fight.
2. **Everything downstream of the tax is the anti-pattern.** A push distributor with an off-chain holder list is permissioned-by-omission — if you are not on the list you are not paid, and at $74 of implied gas cost per recipient the list is *necessarily* truncated. A median distribution of $1.64 is not a reward; it is dust that rots in a wallet. And a redirect lever exercised three times by an EOA is the whole trust model, undone.

### 3c. Hook design — copy the good leg, fix the failures

| Design point | The Index (measured) | Mamo Stock Drop hook | Why |
|---|---|---|---|
| State / ownership | stateless, ownerless, hardcoded bps | **same** | The only reason a tax is credible. No admin, no setter, no upgrade path. |
| Fee denomination | ETH side of an ETH-paired pool | **USDG side of a MAMO/USDG pool** | The accrual is bankable in the numeraire we buy stocks with. No second swap to price the tax; no ETH-price reflexivity in the reward stream. |
| Rate | 300 bps | **200 bps (recommended, §10)** | Total per-side cost = 200 tax + 30 LP = 230 bps. 300 bps taxes the volume the mechanism exists to monetize. |
| Destination | treasury EOA | **`StockDropVault`** — immutable, ownerless | Removes the redirect lever entirely. |
| Distribution | push, hourly, off-chain list, ~925M gas/round | **pull-based `MultiRewards`** | Pull scales to any holder count at zero marginal gas to us, has no list, and cannot omit anyone. |
| Eligibility floor | ~$74 of implied gas | **none** | Accrual is per-second and continuous; the user chooses when claiming is worth the gas. |
| Duration | indefinite, no off-switch | **indefinite by default, with a one-way irrevocable `disable()`** (fee→0 only; nothing else settable) | Reflexive revenue (−97% on the precedent) should be retirable deliberately, not promised forever; a hardcoded sunset stays on the table as a consideration (§3e, decision 3). |
| Reward asset | 18 stocks, pro-rata dust | **one voted stock per epoch** | Concentration makes the accumulation visible and keeps every buy inside measured depth. |

**Mechanics.** `beforeSwap` (buy: USDG in) takes `taxBps` of `amountSpecified` and `afterSwap` (sell: USDG out) takes `taxBps` of the realized USDG output, both via return-delta accounting, transferring to the vault in the same call. `taxBps`, the USDG address and the vault address are **`immutable` constructor arguments**. The hook's single storage slot is a one-way `disabled` flag: the admin multisig may call `disable()` once, after which both callbacks return a zero delta and the pool behaves as an ordinary v4 pool forever. There is no `setFee`, no re-enable, no proxy — the only reachable state change is the fee ending.

**The vault is where the mandate lives.** `StockDropVault` holds USDG and has exactly one outbound path:

```
swapAndNotify(address winner, uint256 amountIn, uint256 backendMinOut)
  require(winner == epochController.settledWinner())          // stakers chose it
  require(amountIn <= perClipCap(winner))                      // measured 100bps cap / 2
  minOut = max(backendMinOut, slippagePriceChecker.getExpectedOut(...) * (1 - slippage))
  router.exactInputSingle(USDG -> winner, minOut)
  MULTI_REWARDS.notifyRewardAmount(winner, received)           // immutable address
```

`MULTI_REWARDS`, the router, the price checker and the epoch controller are immutable. The caller is `BACKEND_ROLE` for the first 7 days after epoch close and **permissionless thereafter**, so a keeper outage delays the conversion but cannot strand the funds. Even with the backend key fully compromised, the only reachable outcome is *stakers receive the stock they voted for, at an oracle-bounded price*. This is the same shape as the basket mandate in v1 §4: the agent chooses *when*, never *what* or *at what price*.

**Hook engineering is routine on this chain, verified.** 4663 carries **101,336 hooked v4 pools across 3,830 distinct hooks**, of which **363 carry the exact four-flag trade-tax combination** we need. CREATE2 address mining (required, since v4 encodes hook permissions in the address low bits) is standard practice here — both CreateX and the Arachnid deterministic deployer are live (`ROBINHOOD_CHAIN_SPEC.md` §1). Budget 1–2 weeks including the mine and the audit delta, not a research project.

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

$300–400k is also the working scale the precedent operated at, which is the only empirical anchor available. Policy, stated in public and not enforced in code: **the POL is committed for a published minimum term of 12 months.** We do not want a credible-neutrality claim that depends on a multisig's restraint, so we say what we will do and let the on-chain record be the proof — the same posture v1 takes on the drift band being off-chain policy.

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
| `t0 → t0+13d` | Tax accrues in USDG in the vault. Stakers vote (changeable until the freeze). |
| `t0+13d` | **Voting freezes** — 24h so the keeper can plan clips against a settled answer. |
| `t0+14d` | Epoch *N+1* opens. Winner is final. Keeper converts epoch *N*'s USDG into the winner in oracle-bounded clips, market-hours-gated by automation A1. |
| `+0–3d` | `notifyRewardAmount(winner, amount)` — streams to stakers over `rewardsDuration = 14 days`. |

### 4b. The ballot is the cleared menu, not the open universe

**Only names that pass v1's three eligibility gates can appear on the ballot**: a genuine Chainlink feed (never a `dividends.finance` decoy), real per-name USDG depth, and a **measured** 100 bps trade capacity — the ~8-name set of §2. NVDA / AAPL / SPY / GOOGL / TSLA / SPCX, with COST and QQQ as reserves pending their own measurements, and SPCX blocked until its underlying is identified (v1 §3b — a deep pool against a misunderstood underlying is worse than a thin pool against a known one).

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

**One deviation from v1, stated plainly.** v1 says `FeeSplitter` and `MultiRewards` "redeploy verbatim". Stake-weighted snapshot voting needs a staked-balance history that the Synthetix-fork `MultiRewards` does not keep. The 4663 deployment therefore adds an OZ `Checkpoints`-backed staked-balance trace (~25 lines, one extra SSTORE on `stake`/`withdraw`) and is **not byte-identical to Base**. That is an audit delta, small but real, and it is the honest cost of native on-chain voting. `addReward` for each menu token is a one-time multisig action at genesis; the tax vault is set as each token's `rewardsDistributor`.

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

1. **A basket accepts in-kind rewards only for stocks already in its fixed set.** The stock set is immutable at initialization (v1 §4) and this does not change that. NVDA reward → AI basket, yes. NVDA reward → SPY basket, no.
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

**Prerequisite:** `StockBasketStrategy.depositStock(address token, uint256 amount)` — permissionless like `deposit`, requires `token ∈ stockTokens`, pulls the token, prices it through the oracle for cap accounting, buys nothing. ~40 lines. It is also a **standalone capacity unlock**: it is the only way to enter a basket without touching a DEX pool at all, which means a user holding NVDA-token already can join without paying the 26–52 bps of pool-vs-oracle cost measured in v1, and without consuming any of the measured 100 bps trade budget. That is worth building even if the reward mechanism never shipped.

### 5d. Why it matters

Stated plainly, because this is the mechanism that makes "flywheel" a claim rather than a diagram:

- It **converts the speculative door's output into the passive door's AUM**, mechanically, in one click. Tax revenue does not become a token holder's wallet dust; it becomes basket AUM, which is fee-bearing, capped, and staker-gated.
- It **fixes the measured dust-rewards failure.** The Index's median distribution is $1.64. Ours defaults to compounding into a portfolio instead of landing in a wallet.
- It **closes the loop**: trading → rewards → AUM → fees → Drop → stakers → more staking → more capacity priority.

User-facing framing (in voice), mirroring the existing "Reinvest (Grow your Bitcoin stack)" option in Mamo's docs — this is a named pattern users already know: **"Reinvest — grow your basket. Send your stock rewards straight into the basket you already hold. No claiming, no swapping, nothing left behind. Set it once and Mamo handles the rest."**

---

## 6. The staking hub

`MultiRewards` on 4663 (checkpointed variant, §4e) is the single place all three streams land. Staking is native and local — no cross-chain attestation anywhere in the design.

| Stream | Source | Cadence | Durable? |
|---|---|---|---|
| **Stock rewards** | trade tax → epoch winner | streamed over each 14d epoch | Runs while the pool trades; retirable via the one-way `disable()` |
| **Capacity priority** | basket supply caps | continuous | Yes |
| **The Drop** | `compoundFee` + management fee → `FeeSplitter` | quarterly, then weekly (below) | Yes |

**Native capacity gating replaces backend attestation.** v1 had to enforce the staker carve-out against *backend-attested Base staking balances* because MAMO was not on 4663. With MAMO native and staking local, `MamoVaultConfig.recordDeposit` reads the staked balance directly:

```
reserved      = remainingCapacity * reservedBps          // recommend reservedBps = 5000
openToAll     = remainingCapacity - reserved
if (deposit consumes into `reserved`)  require(multiRewards.balanceOf(user) >= minStake)
```

Roughly ten lines in `recordDeposit`, no oracle, no off-chain input, no trusted attester — a strict security improvement over v1's design, not just a convenience. Capacity utilization is already published by automation **A8**; the front end reads the same feed and shows two numbers: open capacity and staker-reserved capacity. **Both baskets need the `MamoVaultConfig` wiring that v1 §7 item 3 already schedules** — baskets are not metered today at all, so this rides an existing critical-path item rather than adding one.

**Drop cadence.** v1's judgment stands: at $1.1M of caps a weekly Drop is ~$70 and reads as parody. **Accrue and distribute quarterly until the run-rate clears $2,500/week (~$130k/yr of fee base), then switch to weekly.** The trigger is published in advance so the switch is a milestone rather than an announcement. Note that while the Stock Drop runs, the *stock* stream will dominate the Drop by an order of magnitude — say so rather than letting the comparison be discovered.

---

## 7. Revenue and honesty

**Neither door is a revenue product on day one, and the spec says so first.**

- **Door 1**: ≈**$3.7k/yr** at full launch caps (v1 §2). Unchanged.
- **Door 2**: **$0 to Mamo.** The tax goes **100% to stakers**, with no treasury cut, for the program's life. There is no revenue line to defend, which is exactly why the sunset is credible.

**Sizing Door 2's output, from the precedent.** The Index at its *decayed* floor still moves ~45.7 ETH/day ≈ $85.6k/day of taxable throughput. A new MAMO/USDG pool with $300k of POL should be sized against a fraction of that:

| Scenario | Volume/epoch | Tax @ 200 bps | Fits in one clip? |
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
| the fee stream that outlives the sunset | attention and distribution during a launch window when baskets have no track record |

**KPIs — four numbers, published:**

1. **Staked %** of MAMO circulating on 4663. The token-side health metric.
2. **Epoch turnout** — % of checkpointed stake that voted. Below quorum twice in a row means the vote is theatre and should be simplified or retired.
3. **`claimAndDeposit` conversion rate** — % of distributed reward value routed in-kind rather than claimed to wallet. **This is the flywheel's actual efficiency**; if it is near zero, v2 is two products sharing a logo.
4. **Basket fill rate** — % of each cap filled, and what share of filled capacity came from stakers. Tells us whether the carve-out is a real utility or a decorative one.

---

## 8. Risk register — delta versus v1

v1 §5 stands in full (issuer blocklist, regulatory, stale feeds, decoy feeds, impostor tokens, `uiMultiplier`, capacity, weekend gap, unaudited). New rows only:

| Risk | L / I | Mitigation |
|---|---|---|
| **Legal scope growth** — (a) paying **securities tokens** as staking rewards to token holders, (b) stakers **collectively directing purchases of named securities**, (c) if the §4f agent-pick fallback ships, **Mamo selecting named securities on analysis-based criteria**. All three are new activities, not extensions of "managed basket". | **High / Severe** | The dominant new risk. All three go on the Jersey/regulatory review list **by name**, not as a footnote to the basket review. Door 2 does not ship without specific sign-off; Door 1 ships regardless. The one-way `disable()` can end the program on demand if counsel requires. |
| **Pooled stock custody in `MultiRewards`** — the reward buffer holds stock tokens for all stakers, which is precisely the pooling baskets avoid. The issuer can blocklist that one address. | Medium / High | Bounded by size: only *undistributed* rewards sit there — one epoch's proceeds, $5–25k central case. `claimAndDeposit` shortens residence time structurally. Buffer balance is a monitored quantity (extend A9's blocklist watch to the `MultiRewards` address). Disclose it: this is the one place Mamo pools stock tokens. |
| **Reflexivity** — trade-fee revenue is measurably self-consuming (−97% peak-to-now on the precedent) | **High / Medium** | Never quoted as APY; never in a yield table; the front end shows realized purchases, not projected rates. The one-way `disable()` retires the program deliberately if it decays to noise; a hardcoded sunset remains a consideration (decision 3). |
| **MAMO becomes a speculation object** — a tax hook and a stock-buying flywheel invite trading behaviour Mamo has not previously courted | Medium / Medium | **A token-governance decision, not an engineering one — flag it for the owners of the token.** Containment: baskets stay the headline, the tax sunsets, and no MAMO emissions are introduced anywhere in v2. |
| **Comms sequencing** — the pool is the loud thing; the baskets are the trustworthy thing. Lead with the pool and Mamo becomes a memecoin with a portfolio feature. | Medium / High | Hard sequencing rule: **baskets launch first and stay the headline**; the Stock Drop is framed as *how MAMO arrives on the chain*, always downstream of the product. Every Door 2 asset must name Door 1 first. |
| **Hook immutability cuts both ways** — no fix path, no pause, no upgrade. A bug is permanent. | Low / Severe | Audit it like it is forever, because it is. Keep the hook under ~150 lines with a single one-way storage flag; differential-test against the precedent's live behaviour; deploy the mined address only after audit sign-off. Blast radius is bounded to the tax leg — a broken hook cannot touch baskets, the vault's mandate, or user funds. |
| **POL exposure** — $300k of treasury capital in a two-sided position, impermanent-loss-exposed and unhedged | Medium / Medium | Sized as a launch cost, not an investment. Half full-range so it cannot go out of range. A published minimum commitment term (12 months) makes the exposure a stated commitment rather than a surprise. |
| **Keeper liveness on conversions** | Low / Low | `swapAndNotify` goes permissionless 7 days after epoch close; bounds are immutable, so an anonymous caller gets the same outcome the backend would. |

---

## 9. Build delta and critical path v2

Added to v1 §7's ordered path. **Nothing here reorders it**; the audit gate is shared and the legal gate remains org-level.

| # | Item | Owner | Size | Notes |
|---|---|---|---|---|
| V1 | **Bridge MAMO to 4663 via Wormhole** | infra | days | Was "pre-launch, nice to have"; now gates Door 2 entirely. Do it first. |
| V2 | **`MultiRewards` (checkpointed) + `FeeSplitter` deploy on 4663** | contracts | ~1 wk | +25 lines of checkpoints; `addReward` for the menu at genesis; audit delta. |
| V3 | **`StockBasketStrategy.depositStock`** | contracts | ~40 lines | Prerequisite for §5 **and** a standalone capacity unlock. Ships with v1 item 3 (cap + fee wiring). |
| V4 | **Native staker capacity gating in `MamoVaultConfig`** | contracts | ~10 lines | Replaces backend attestation. Rides v1 item 3. |
| V5 | **`StockDropEpochController`** | contracts | ~150 lines | Clock, menu, checkpointed tally, `settledWinner()`. |
| V6 | **Trade-tax hook + `StockDropVault`** | contracts | **1–2 wks** | Includes the CREATE2 flag mine. Zero storage in the hook. |
| V7 | **`MamoRewardRouter`** | contracts | ~100 lines | Stateless, permissionless, registry-authenticated. |
| V8 | **Automation A11 — tax-conversion keeper** | backend | small | Spec it into `ROBINHOOD_TENDERLY_AUTOMATIONS.md` §4: cron 1h, gated by A1 market-hours, reads `settledWinner()`, clips at ≤50% of the winner's measured 100 bps cap ≥15 min apart via A3's executor, calls `swapAndNotify`, alerts if unconverted at epoch close +5d. |
| V9 | **POL seeding runbook** | ops | days | Pool init, mined hook address, range placement, public no-withdraw statement. |
| V10 | **Audit — v2 scope** | external | shared gate | Hook immutability and return-delta accounting; vault mandate; checkpoint correctness under stake/withdraw; router authentication; in-kind deposit cap accounting. |
| V11 | **Mamo concierge (MCP)** — *consideration, not launch-blocking* | backend | ~2–4 wks | Read API + calldata builder + MCP server (§12). Ships within the launch window if greenlit; no contract changes. |

**Explicitly NOT in scope for v2:**

- **Boosted USDG stays dark.** Triggers unchanged and currently further away (`BOOSTED_USDG_SIZING.md` §6).
- **No leverage products of any kind.**
- **No push distribution, ever.** Pull-based `MultiRewards` only.
- **No open-universe ballot.** The cleared menu is the ballot, permanently.
- **No vote-incentive ("bribe") markets.** Named here as a *future option* — third parties paying stakers to vote for a name is a coherent v2.1 extension and an obvious one. It is not designed, not built, and not committed; it also has its own legal surface and should not be casually inherited.
- **No MAMO emissions.** Every reward in v2 is bought with realized revenue.
- **No treasury cut of the tax** during the program.

---

## 10. Open decisions for review

Recommendations given; each is a real decision, not a formality.

| # | Decision | Recommendation | Why / what moves it |
|---|---|---|---|
| 1 | **Tax rate** | **200 bps** | 300 bps is the proven-credible precedent, but with a 30 bps LP fee the round trip is ~4.6% at 200 and ~6.6% at 300. We are taxing the volume the mechanism monetizes. Go 300 only if the pool is explicitly a distribution event and low volume is acceptable. **Immutable — decide before the mine.** |
| 2 | **Epoch length** | **14 days** | Long enough that proceeds are a legible number and a vote is worth casting; 7d halves per-epoch size and doubles keeper load; 30d makes turnout decay. |
| 3 | **Program end** | **Indefinite + one-way `disable()` (default); hardcoded sunset as a consideration** | The default keeps a working program alive and avoids countdown theater; the retire switch is the deliberate end path. If a sunset is chosen instead, 182d (13 × 14d) aligns epochs exactly, and longer starts to look like a permanent revenue claim. Either choice is immutable — decide before the mine. |
| 4 | **Reward set** | **Single name, voted** | Concentration is the narrative and costs nothing in execution at realistic size. The alternative — pro-rata across the menu — is exactly The Index's $1.64 dust failure. |
| 5 | **POL size** | **$300k** (50% full-range / 50% ±40%) | ~100 bps at a ~$4k ticket. $400k buys a ~$5.5k ticket and is defensible; below $200k the pool is too thin to attract the volume the tax needs. |
| 6 | **Staker reservation** | **50% of remaining capacity**, `minStake` TBD | v1 already proposed ~50%. `minStake` should be set from the actual staker distribution after the bridge, not guessed now. |
| 7 | **Quorum** | **10% of checkpointed stake**, fallback = prior winner, genesis = SPY | Deliberately low: the fallback is benign, so a high quorum only manufactures failed epochs. |
| 8 | **Drop switch** | quarterly → weekly at **$2,500/week** | Publish the trigger in advance. |
| 9 | **`MultiRewards` byte-identity** | accept the **+25-line checkpoint delta** | The alternative is off-chain vote-weight computation, which reintroduces exactly the trusted-attester problem native staking was supposed to remove. |
| 10 | **Comms order** | **baskets first, always** | Sequencing is the main containment for the "Mamo becomes a memecoin" risk (§8). |
| 11 | **Who picks the epoch stock** | **Staker vote with agent-pick fallback** (§4f) | Pure vote maximizes the utility story but hands users homework; pure agent-pick is on-brand ("no thinking") but weakens governance utility. The hybrid keeps both: vote if you care, Mamo decides when you do not — with its reasoning published. ~5-line controller change; decide before audit; carries legal flag (c). |

Launch line (in voice): **"Mamo is not bringing another savings account to Robinhood Chain. It is bringing the part that was missing: a portfolio that manages itself, in plain language, under your control."** Door 1 is the product; Door 2 is how MAMO gets there. Nothing in the copy implies the fee stream is a yield, and nothing promises it lasts.

---

## 11. Voice and naming

Sourced verbatim from Mamo's published docs (`docs.mamo.bot`, via the public `moonwell-fi/mamodocs` GitBook source). The rules that bind every user-facing surface of v2:

- **Identity:** "a finance companion, not a finance tool." Second person always ("your basket", "your money"); Mamo is "it", never "he/she". Persona signals: calm protector ("Mamo 守"), 🌱 motif — one emoji per heading at most, none mid-sentence, no exclamation marks. No capybara — it does not exist in the brand.
- **Vocabulary:** *Account*, not vault; *put your money to work*, not deploy; *reallocate*, not rebalance; *earnings / what you earn*, not yield or APY in any headline ("good available returns" is the strongest permitted claim; precise APY figures live only where precision protects the user). *No degen register of any kind.*
- **Never say "tax."** The brand's published don'ts exclude tax/reflection-token mechanics. User-facing copy says **"pool fee" or "trading fees"**; the immutable hook is the proof behind "trust comes from proof, not promises" (their line). Engineering docs keep the precise word.
- **Extend named things, never invent parallel ones.** The epoch purchase is an extension of **The Mamo Drop**; claim-to-basket is **Reinvest**, the option name Mamo already ships for Bitcoin. Naming continuity is free brand equity.
- **Honesty is house style.** Mamo volunteers downside unprompted ("Honest about risk" is a standing docs section). The four hard truths — markets close ~50h on weekends, baskets are capped on purpose, no single blended number will ever be quoted, tokenized stocks are not available everywhere — are written in-voice, on the first screen, not the last.
- **No urgency theater.** The caps are genuinely scarce — state it calmly and let the fact do the work; the same rule argues against a hardcoded sunset (decision 3). Countdown-style FOMO inverts the brand.

---

## 12. Consideration — the Mamo concierge (MCP)

Today Mamo's interface is a chat with basic tools. This launch is an opening to ship something better *alongside* it without rebuilding it: **an MCP server that turns the user's agent harness of choice into a Mamo concierge.** Any agent that speaks MCP — Claude, or whatever the user already runs — gets:

- **Read tools**: basket state and NAV, sleeve rate, epoch status and current ballot, accrued rewards, capacity remaining (open vs staker-reserved), the published agent-pick reasoning (§4f).
- **Action tools**: calldata generation for every user action — deposit, withdraw, Reinvest, stake, vote — returned for the **user's own wallet to sign**. The concierge composes transactions; it never holds keys and never signs.

**The safety story is the architecture we already shipped, extended for free.** Every hard bound in the system — the basket mandate, the oracle-floored swaps, the owner-only fund paths, the cleared ballot menu — binds *any* caller, including an agent we did not write. A misbehaving third-party harness can only ever produce transactions the contracts permit. "An agent you do not have to trust" was built for our backend; it turns out to be exactly the property that makes opening the surface to other agents safe. No other product on this chain can make that claim.

**Build shape** (backend-owned, no contract changes): a read API over state we already index for the Tenderly automations, a calldata/tx-builder service, and the MCP server wrapping both. Geo-gating enforced at the API layer, same policy as the front end. **Not launch-blocking** — the chat UI remains the default door — but shipping it inside the launch window turns the launch's attention into distribution in the interfaces users already live in, and is an honest answer to the fact that our current agent UI is the weakest part of the product. Costed in §9 as V11; greenlight is a product decision, not an engineering one.
