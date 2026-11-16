# Chainlink equity feeds on Base: what they are and what to do with them

Every stock in the launch set is priced today from its Aerodrome Slipstream pool's time-weighted
average, because a reference that holds Friday's close through the weekend cannot support a product
whose edge is trading weekend dislocations. The cost of that choice is measured in
[STOCK_ACCOUNT_PRICE_CHECKER.md](./STOCK_ACCOUNT_PRICE_CHECKER.md): the reference is only as honest as
the pool, and opening the whole 100 bps backend slippage budget costs an attacker 285.70 USDC at the
NVDAc pool's current depth.

Morpho lists the same tokens as collateral on Base, so oracle infrastructure for them exists. This
document establishes what that infrastructure is, how it behaves when the US equity market is shut,
how far it sits from our own reference, and whether we should use any of it.

`StockAccountRegistry` already supports either source per token — `PriceSource.PoolTwap` reads the
pool, `PriceSource.Chainlink` delegates to the audited `SlippagePriceChecker` — so switching a token is
a listing decision, not a code change. Nothing here proposes a code change and nothing in this branch
changes any token's source.

All onchain numbers are read from Base mainnet. The reference block is **51,617,291**
(`timestamp` 1,790,023,929 — Mon 2026-09-21 20:52:09 UTC). Historical readings name their own block.

## What actually exists

Every one of our four launch stocks has a Chainlink feed on Base, and so does SPCXc. They are the
"Coinbase" tokenized equity feeds, published in Chainlink's Base feed directory under asset class
`Equity` with `marketHours: us_equities_24/5`. Each proxy is a standard `AggregatorV3Interface` and its
current aggregator reports `typeAndVersion` `AccessControlledOCR2Aggregator 1.0.0`.

| token | in launch set | feed proxy | current aggregator | dec | answer at the reference block | last update |
| ----- | ------------- | ---------- | ------------------ | --- | ----------------------------- | ----------- |
| AAPLc  | yes | `0x787f13dEa48Db0897CbCDD985de77809D837F988` | `0xc37B6F754e90D4Cca1f533F5a08f7d532b3d0d9D` | 8 | 339.33555 | 1.39 h earlier |
| GOOGLc | yes | `0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2` | `0x6bF33b7855eB8047dDe206D9F6321D7d02CfB308` | 8 | 355.10386581 | 2.33 h earlier |
| METAc  | yes | `0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D` | `0xA7155928bEE40052EFb3094a046c5498202FD3EE` | 8 | 740.27020 | 0.82 h earlier |
| NVDAc  | yes | `0x04689a41629776563E6822F76f2e57D148d28513` | `0xF72B1eB5932800F3d2a5EeC5f99e6cD586479675` | 8 | 227.55500 | 3.03 h earlier |
| SPCXc  | no  | `0x6A634B235903C4ad6376892180d6fF8612e3Fa68` | `0xa994B7fC3123AE0EF4EE53ab5e3545f2639187a7` | 8 | 151.77035 | 1.18 h earlier |

All five proxies are owned by `0xf0Db7318A51a21C413CaDd4AbDC1E8a500fE5B1b`, report `version` 6, and sit
at `phaseId` 2; each has a retired phase-1 aggregator that stopped updating on 2026-08-14. The Base
directory carries the same shape for TSLA, AMZN, MSFT, INTC, COIN, CRCL, MSTR and SNDK, so a later
listing is unlikely to find itself without a feed.

Chainlink's published Base feed list declares **heartbeat 86,400 s and deviation threshold 0.5 %** for
all of them. The heartbeat is the number that does not survive contact with the data; see the next
section.

**These are the feeds Morpho uses.** Ten Morpho Blue markets on Base take these tokens as collateral
against USDC; each market's oracle was read from `Morpho.idToMarketParams` on
`0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` and then followed to its inputs.

| collateral | LLTV | market id (prefix) | oracle | oracle kind | underlying feed |
| ---------- | ---- | ------------------ | ------ | ----------- | --------------- |
| AAPLc  | 62.5 % | `0xae1a3048…` | `0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e` | MorphoChainlinkOracleV2 | Coinbase AAPL |
| GOOGLc | 77 %   | `0xa3913d89…` | `0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99` | MorphoChainlinkOracleV2 | Coinbase GOOGL |
| GOOGLc | 62.5 % | `0x0cc78b1f…` | `0x24DC11055aa5b2C5692E4B77d7285c4f0fd9Cf99` | MorphoChainlinkOracleV2 | Coinbase GOOGL |
| METAc  | 62.5 % | `0x44b343b5…` | `0x4752B27dFc1931eb9a5DFEFC7FBC9d0af9020dC7` | MorphoChainlinkOracleV2 | Coinbase META |
| METAc  | 86 %   | `0xa8835b56…` | `0x4490497FB4f49061FB99F3E4De0bC4D182377cAA` | unverified, 1,575 B | not exposed |
| NVDAc  | 62.5 % | `0xb4b42dd6…` | `0x4F698C04d01d9CebCDd9494c189aBdD6C5453f84` | MorphoChainlinkOracleV2 | Coinbase NVDA |
| NVDAc  | 77 %   | `0xfef5641f…` | `0x1E2b20B4703F97710c2600eA73179c6CD1E00b02` | unverified, 16,481 B, exposes `feed()` | Coinbase NVDA |
| NVDAc  | 77 %   | `0x91360eea…` | `0xE0AE3137a30393410B595E1C1d572a1449A969ea` | unverified, 4,187 B | not exposed |
| NVDAc  | 77 %   | `0x5c800e86…` | `0x39712F36c013C09Cf4D62D0F695DD74eBe67FD19` | unverified, 4,187 B | not exposed |
| SPCXc  | 62.5 % | `0xce983b9e…` | `0x9079857a2b5FFfC3d87052b11b866a185B4A6483` | MorphoChainlinkOracleV2 | Coinbase SPCX |

The five `MorphoChainlinkOracleV2` instances are configured identically and minimally: `BASE_FEED_1`
is the Coinbase equity feed, `BASE_FEED_2`, `QUOTE_FEED_1`, `QUOTE_FEED_2`, `BASE_VAULT` and
`QUOTE_VAULT` are all zero, and `SCALE_FACTOR` is 1e26. Each oracle's `price()` divided by 1e34 equals
its feed's `latestRoundData` answer exactly — AAPLc's oracle reports 339.33555 and the AAPL feed
reports 339.33555 — so Morpho consumes the feed directly, prices USDC at a flat 1.0 with no USDC/USD
hop, and applies nothing of its own.

Two details worth carrying forward. The four unverified oracles are third-party wrappers whose
behaviour cannot be read from chain; one of them, `0x39712F36…` on a live 77 % NVDAc market, **reverts**
on `price()` at the reference block (custom error selector `0x2def1a76`). And there is real money behind
these oracles: at the reference block Morpho Blue holds 149.11637508 AAPLc, 109.54346520 GOOGLc,
75.33237195 NVDAc and 22.72720009 METAc as collateral — about 50,600, 38,900, 17,100 and 16,800 USD at
the same block's feed prices — most of it in the 62.5 % markets that sit on the plain V2 oracles.

## The answer already includes the B20 multiplier

Each B20 token carries a `multiplier()` that grows with dividends and corporate actions, so one token
is worth `multiplier / 1e18` underlying shares. At the reference block AAPLc, METAc, NVDAc and SPCXc
are all at exactly 1e18; **GOOGLc is at 1.000377118676784179e18**, having stepped up at block
51,310,619 (Mon 2026-09-14 18:29:45 UTC). It is a value multiplier, not a rebase: a passive holder's
balance and the token's `totalSupply` are byte-identical either side of that block.

That matters because a feed quoting the raw share price would drift from the token's worth every time
the multiplier moves, and a split would put it out by whole multiples. It does not: **the feed quotes
the token, multiplier included.**

The step is only 3.77 bps, far below the noise in any price comparison, so it was established from the
shape of the answers rather than their level. A price quoted in cents or in thousandths of a dollar
lands on a short decimal; multiply it by 1.000377118676784179 and it lands on a long one. Counting how
many of each feed's phase-2 answers carry six or more significant decimal places, split at the block
where GOOGLc's multiplier moved:

| feed | multiplier | long answers before | long answers after |
| ---- | ---------- | ------------------- | ------------------ |
| GOOGL | stepped to 1.000377118676784179 | 8 / 173 | **55 / 55** |
| AAPL  | still 1 | 16 / 202  | 3 / 26  |
| META  | still 1 | 16 / 420  | 7 / 99  |
| NVDA  | still 1 | 16 / 358  | 5 / 35  |
| SPCX  | still 1 | 71 / 1107 | 6 / 126 |

GOOGL goes from 5 % long answers to 100 % of them at exactly that block. The four feeds whose
multiplier is still 1 show no such break: 4–8 % before, 5–14 % after, on much smaller post-split
samples. Dividing the post-step answers back out gives the
short form again: 348.88762243, 347.11360367 and 345.08048723 become 348.7561, 346.98275 and 344.9504.
Chainlink's own documentation states the same rule,
`Token Price = Underlying Equity Market Price x Multiplier`.

So a `PriceSource.Chainlink` listing would need no multiplier handling of its own, and Morpho's direct
use of the feed is correct rather than a latent bug.

## How they behave when the market is shut

This is the question that decides the ticket. Every round of the current phase of all five feeds was
walked by `getRoundData` on the aggregator, 2,601 rounds spanning 2026-08-05 to 2026-09-21, and the
gaps between consecutive `updatedAt` values measured. (The retired phase-1 aggregators were walked too,
another 1,188 rounds, and are excluded from the timing tables because they stopped a month ago.)

| feed | rounds | median gap | p90 | p99 | worst gap |
| ---- | ------ | ---------- | --- | --- | --------- |
| AAPL  | 228   | 3,302 s | 51,688 s | 207,540 s | 273,734 s (**76.04 h**) |
| GOOGL | 228   | 3,722 s | 52,440 s | 205,452 s | 293,756 s (**81.60 h**) |
| META  | 519   | 1,170 s | 16,630 s | 186,778 s | 276,646 s (**76.85 h**) |
| NVDA  | 393   | 2,222 s | 22,670 s | 191,436 s | 280,578 s (**77.94 h**) |
| SPCX  | 1,233 | 570 s   | 5,402 s  | 44,726 s  | 274,022 s (**76.12 h**) |

The declared 86,400 s heartbeat is not what the feed does. Across the whole sample exactly **one** gap
lands near it (GOOGL, 86,418 s); every feed has seven or eight gaps that *exceed* it. What actually
triggers a round is the 0.5 % deviation threshold: the median move between consecutive answers is
52.8, 52.1, 53.8, 52.6 and 55.2 bps for AAPL, GOOGL, META, NVDA and SPCX. Rounds with a move well
under 50 bps are almost all the first round after a weekend. Chainlink's documentation says as much
outright: "these feeds do not have heartbeats during off-hours", and "when markets close, the feed
holds the last close even though the contract remains callable via `latestRoundData()`".

**Overnight, on a weekday**, the gap is bounded but long. Medians of 15.99 h (AAPL), 15.74 h (GOOGL),
12.46 h (META), 10.58 h (NVDA) and 6.65 h (SPCX), worst cases 21.47 h, 24.00 h, 18.39 h, 17.65 h and
17.06 h. Even *inside* regular trading hours the feed can sit still for hours: the longest gap with
both ends between 09:30 and 16:00 ET on the same day is 6.10 h for AAPL, 5.63 h for GOOGL, 5.33 h for
META, 6.21 h for NVDA and 4.97 h for SPCX.

**Over a weekend**, the feed freezes from some point on Friday until Sunday 20:00 ET, when the 24/5
session reopens. Seven weekends are in the sample. The Friday stop is not the close — it is simply the
last time the price moved 50 bps, which on 2026-08-07 was 10:21 ET for AAPL, five and a half hours
before the bell.

| weekend (2026) | AAPL | GOOGL | META | NVDA | SPCX |
| -------------- | ---- | ----- | ---- | ---- | ---- |
| Aug 07 → Aug 09 | 57.65 h | 55.53 h | 55.53 h | 52.09 h | 48.49 h |
| Aug 14 → Aug 16 | 57.65 h | 57.49 h | 52.05 h | 53.53 h | 50.15 h |
| Aug 21 → Aug 23 | 54.13 h | 57.07 h | 48.54 h | 55.17 h | 52.20 h |
| Aug 28 → Aug 30 | 54.98 h | 56.02 h | 52.84 h | 53.18 h | 51.44 h |
| **Sep 04 → Sep 07 (Labor Day)** | **76.04 h** | **81.60 h** | **76.85 h** | **77.94 h** | **76.12 h** |
| Sep 11 → Sep 13 | 56.06 h | 53.26 h | 55.39 h | 52.45 h | 48.36 h |
| Sep 18 → Sep 20 | 56.62 h | 50.32 h | 51.88 h | 52.08 h | 48.97 h |

**Over a market holiday** the freeze simply extends. Labor Day fell on Monday 2026-09-07; the feeds
went quiet on Friday and did not print again until Monday 20:00 ET. The worst single observation in the
sample is GOOGL holding 338.71195 from Fri 2026-09-04 10:24:41 ET to Mon 2026-09-07 20:00:37 ET —
**81.60 hours** — before reopening at 339.3162875, 17.8 bps away.

To put a number on what the freeze costs in information: the move from the last Friday print to the
first Sunday print, over the seven weekends, is between 1 and 118 bps in absolute terms across
all 35 weekend-feed pairs, the extremes being AAPL's +1 bps on 2026-09-18 and NVDA's -118 bps on
2026-09-11. So the answer a consumer reads on Saturday is within about a percent of where the feed will
restart — but it is a number from Friday morning, and nothing in the feed says how far it has
drifted.

The plain statement the ticket asked for: **yes, these feeds hold the last print for the whole weekend,
and for 81.60 hours over a long weekend, with no heartbeat to break the silence.**

## Zero and negative answers

None. Across all 3,789 rounds read — both phases of all five feeds, from 2026-08-03 to 2026-09-21 —
every `answer` is strictly positive, the smallest being 105.55725 (SPCX, phase 2, round 50). Every
`startedAt` and every `updatedAt` is non-zero, and every `answeredInRound` equals its `roundId`. The reported
behaviour of Coinbase equity feeds emitting zero during extended sessions **does not appear anywhere in
the history of these five feeds**. What they do instead is go stale, which is the failure mode this
document is about.

That said, the sample is seven weeks long and contains no earnings halt, no circuit breaker and no
single-stock trading halt. A zero has not been ruled out; it has only failed to appear.

## How far the feed sits from the pool

Each measurement takes the same block, reads the Aerodrome pool TWAP over the registry's 180-second
window through the exact `StockAccountPriceChecker` path, reads the feed's `latestRoundData`, and
reports `(pool - feed) / feed` in basis points. The arithmetic was validated against the deployed
contract code: a fork of blocks 51,612,127 and 51,565,327 running the real `StockAccountPriceChecker`
returns 338.427276, 356.276338, 742.906293, 227.381475 and 333.956216, 349.991038, 670.802678,
220.882428 USDC per whole token, matching the standalone computation to the last unit.

Market hours: 60 samples per token, hourly from 10:00 to 15:00 ET on the ten trading days from
2026-09-08 to 2026-09-21. Off hours: 106 samples per token, covering the 2026-09-18 → 09-21 weekend
hourly and the 2026-09-04 → 09-07 Labor Day weekend two-hourly, with Monday 2026-09-07 counted as
closed.

| token | RTH median | RTH p90 | RTH max | off-hours median | off-hours p90 | off-hours max |
| ----- | ---------- | ------- | ------- | ---------------- | ------------- | ------------- |
| AAPLc  | 18.2 bps | 33.0 bps | 43.9 bps | 19.2 bps | 53.6 bps | 74.8 bps |
| GOOGLc | 15.6 bps | 33.4 bps | 40.2 bps | 14.7 bps | 34.6 bps | 64.1 bps |
| METAc  | 14.6 bps | 25.7 bps | 41.5 bps | 15.5 bps | 32.1 bps | 57.0 bps |
| NVDAc  | 10.7 bps | 27.6 bps | 39.7 bps | 31.3 bps | 84.7 bps | **109.9 bps** |

All figures are absolute spreads. The staleness behind them, in the same samples: during market hours
the feed is a median 0.44–1.27 h old and at worst 5.40 h old; off hours it is a median 25–28 h old and
at worst 81.6 h old.

The worst six off-hours cells are all NVDAc over the Labor Day weekend, peaking at **109.9 bps at
block 50,992,927** (Mon 2026-09-07 06:00 ET) with the feed 64 hours stale. The pool had carried NVDAc
more than a percent above a Friday-afternoon print; when the feed finally restarted fourteen hours
later it had moved only 35 bps of that, so the pool was not merely tracking a move the feed had missed
— it had overshot it by a factor of three. Neither reference was right, and only one of them was
moving.

Two readings of this table matter for the decision.

First, **the honest divergence is already large enough to make a tight cross-check useless.** A rule
that fires when the pool and the feed disagree by more than some threshold has to sit above 44 bps to
survive normal market hours and above 110 bps to survive a long weekend, and those are maxima from
seven weeks of quiet tape. A 100 bps backend slippage budget compounds with drift rather than capping
it, so a cross-check that only bites past 110 bps of divergence catches nothing that the deposit cap
and the deviation band do not already bound — while a cross-check tight enough to matter would have
fired on honest data repeatedly over this sample.

Second, **during market hours the two references agree well enough that neither is obviously better.**
Median absolute spreads of 10.7–18.2 bps against a pool whose own 180-second TWAP is quantised to a
whole tick is close agreement. The feed adds nothing during the session; it only subtracts outside it.

## What would happen if we listed a stock as `PriceSource.Chainlink`

Worth being concrete, because the failure is not "a slightly worse price".

A Chainlink listing goes onto the existing audited `SlippagePriceChecker` as a two-hop configuration,
the stock feed then USDC/USD reversed, exactly as cbBTC is configured in
`config/stock-accounts/8453.json`. That checker enforces
`require(block.timestamp <= updatedAt + heartbeat, "Price feed update time exceeds heartbeat")` per
hop. It reverts; it does not return a stale price.

So the heartbeat chosen at listing decides the failure mode, and neither option is acceptable:

- A heartbeat near the declared 86,400 s makes the token unpriceable for 24 to 34 hours of every
  weekend in this sample, and 52 to 58 hours of the long one.
  `StockAccountPriceChecker.getExpectedOut` bubbles the revert, so every quote touching that token
  fails — not just its own leg, since quotes compose through USDC. Deposits, orders and the range
  check all stop.
- A heartbeat wide enough never to revert over the observed sample would have to exceed **293,756 s
  (81.60 h)**, and even that is only the worst *observed* case. Thanksgiving and the Christmas–New Year
  closures are longer than Labor Day. At that setting the "staleness" check no longer checks anything:
  a feed that stopped on Friday morning would still be accepted as fresh on Monday afternoon.

There is no third setting. A feed with no off-hours heartbeat cannot be consumed by a checker whose
only notion of validity is a heartbeat.

## Recommendation

**Keep the pool TWAP as the onchain reference for all four launch stocks. Do not route any stock
through `PriceSource.Chainlink`. Use the feed off-chain only, as one input among several to the
backend's price sanity rule, and as a manual signal — not an automatic switch — when a pool looks
broken.**

The reasoning, shortest first.

Routing stocks through Chainlink is not available in practice. The product needs a reference at
02:00 ET on a Sunday, and the feed does not have one — it has Friday's 10:21 print. Configuring it
anyway forces a choice between a checker that reverts for two and a half days a week and a staleness
bound so wide it is decorative. That is settled by the 81.60 h measurement, not by preference.

Using the feed as a fallback when a pool breaks is worse than it sounds, because the two fail at the
same time. The pool's weak state is a thin or young pool, most dangerous outside market hours when no
arbitrageur will unwind a manipulation — and that is precisely when the feed is frozen and 110 bps
away. A fallback that is only trustworthy while the primary is healthy is not a fallback.

Using the feed as an off-chain sanity input is worth doing and costs nothing. The backend already has
to decide whether a quote looks sane before it signs. Adding "and the pool TWAP is within X of the
Chainlink feed, where the feed updated within Y" is a cheap extra veto that catches a genuinely broken
pool during market hours, when the feed is a median 0.44–1.27 h old and the spread is a median 10.7–18.2
bps. The numbers in the spread table are the ones to set X from: 100 bps during market hours, with the feed
required to have updated inside 6 h, is 2.3x the worst honest spread and just above the worst honest
staleness in this sample, so it would not have fired once on it. Outside market hours the rule should
be disabled rather than loosened, because a threshold set above 110 bps so it never fires is a rule
that lies about being a control.

Ignoring the feeds entirely is the wrong call for one reason: the audit. "We looked, here is the
oracle, here is the 81.60-hour freeze, here is why it cannot be the reference" is a materially stronger
position than silence, and the same reading tells us Morpho's markets on our collateral inherit that
freeze — which is useful to know if we ever lend against these tokens or are lent against.

### What would change the answer

- **A heartbeat that survives off-hours.** If Chainlink or Coinbase publish these feeds with a real
  off-hours heartbeat — even 4 h — the stale-price failure disappears and the feed becomes a usable
  fallback. Re-run the gap table; the deciding number is the worst gap over a long weekend.
- **A separate 24/7 reference.** A feed priced from the tokenized market rather than the underlying
  equity would track the weekend the way the pool does. None exists on Base today.
- **Pool depth growing by an order of magnitude.** The recommendation leans on the pool being the only
  weekend reference, not on it being a good one. If the pools stay thin while balances grow, the
  answer is still not Chainlink — it is smaller caps, a longer window, or not trading those hours.
- **A zero or a negative answer appearing.** None was found in 3,789 rounds, but the sample contains no
  halt. One confirmed zero would rule the feeds out even as an off-chain input unless the sanity rule
  explicitly rejects non-positive answers, which it should do from the start regardless.
- **A stock listing whose multiplier moves materially** — a split rather than a dividend. The evidence
  that the feed embeds the multiplier rests on a 3.77 bps step in GOOGL and on Chainlink's
  documentation. A split would make that verifiable at a glance and is worth re-checking when one
  happens.

## What is not measured here

- **Arbitrageur behaviour off-hours.** As in the price-checker document, nothing here measures whether
  anyone will unwind a manipulated pool when the underlying market is shut. The 110 bps figure is
  observed drift on a quiet tape, not a bound.
- **The four unverified Morpho oracles.** Their bytecode is not verified and their inputs are not
  exposed, so what `0x1E2b20B4…`, `0x4490497F…`, `0xE0AE3137…` and `0x39712F36…` do beyond returning a
  number is unknown. `0x39712F36…` currently reverts, which is stated as an observation, not diagnosed.
- **Behaviour across a market halt, a circuit breaker or an earnings gap.** The seven-week sample
  contains none.
- **Longer closures than Labor Day.** Thanksgiving and the year-end holidays are assumed to produce
  gaps longer than 81.60 h. That is an assumption from the market calendar, not a measurement.
- **Whether the backend's sanity rule exists in the shape described.** The recommendation describes
  what the rule should consume; wiring it is not part of this ticket.

## Regenerating the numbers

Everything above comes from `eth_call` against Base; no state is written and no script is committed.

```bash
source .env   # BASE_RPC_URL

# the feed table
cast call 0x787f13dEa48Db0897CbCDD985de77809D837F988 'description()(string)'      --rpc-url "$BASE_RPC_URL"
cast call 0x787f13dEa48Db0897CbCDD985de77809D837F988 'decimals()(uint8)'          --rpc-url "$BASE_RPC_URL"
cast call 0x787f13dEa48Db0897CbCDD985de77809D837F988 'aggregator()(address)'      --rpc-url "$BASE_RPC_URL"
cast call 0x787f13dEa48Db0897CbCDD985de77809D837F988 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' \
  --block 51617291 --rpc-url "$BASE_RPC_URL"

# the Morpho market behind a token, and the feed behind that market
cast call 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
  'idToMarketParams(bytes32)(address,address,address,address,uint256)' \
  0xae1a30486234bf7e7ac166c7c03d9bc5f2cd8a39be2c48e73c665ac7148c3c28 --rpc-url "$BASE_RPC_URL"
cast call 0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e 'BASE_FEED_1()(address)'     --rpc-url "$BASE_RPC_URL"
cast call 0xEcC5c9bf18CB2CfC94C2f7EFf8BDd5837A60AB0e 'price()(uint256)'           --rpc-url "$BASE_RPC_URL"

# the B20 multiplier, and that it is a value multiplier rather than a rebase
cast call 0xb2000000000000000000002D0BA3164cc74f58B7 'multiplier()(uint256)'      --rpc-url "$BASE_RPC_URL"
cast call 0xb2000000000000000000002D0BA3164cc74f58B7 'totalSupply()(uint256)' --block 51310618 --rpc-url "$BASE_RPC_URL"
cast call 0xb2000000000000000000002D0BA3164cc74f58B7 'totalSupply()(uint256)' --block 51310619 --rpc-url "$BASE_RPC_URL"

# one historical round, addressed through the proxy: phase 2 composes as (2 << 64) + aggregatorRound
cast call 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2 \
  'getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)' 36893488147419103351 --rpc-url "$BASE_RPC_URL"
cast call 0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2 \
  'getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)' 36893488147419103352 --rpc-url "$BASE_RPC_URL"
# -> 338.71195 at 1788531881 and 339.3162875 at 1788825637: the 81.60 h Labor Day freeze

# the pool leg of a spread measurement
cast call 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9 'observe(uint32[])(int56[],uint160[])' '[180,0]' \
  --block 50992927 --rpc-url "$BASE_RPC_URL"
```

The gap and spread tables are aggregates over thousands of such calls: every round of each phase-2
aggregator by `getRoundData(uint80)` from 1 to `latestRound()`, and, for the spreads, one pool
`observe` plus one `latestRoundData` per token per sampled block. Base blocks are exactly two seconds
apart across this range, so a block for a timestamp is `51617291 - (1790023929 - t) / 2`, verified
against `cast block` at four points.

One caveat for anyone reproducing the spread numbers in Foundry: the B20 tokens' onchain code is the
single byte `0xef`, which revm rejects with `OpcodeNotFound`, so `IERC20Metadata(token).decimals()`
inside `StockAccountPriceChecker` reverts on a bare fork. The existing suite works around this by
etching a `MockERC20Decimals` stand-in at the token address, exactly as
`test/StockAccountPriceChecker.integration.t.sol` does in `setUp`; the token's real state lives in
node-native storage that the etch replaces, which is fine here because only `decimals()` is on the
path.
