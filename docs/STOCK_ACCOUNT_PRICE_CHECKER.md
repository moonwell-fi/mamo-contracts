# Stock account price checker: TWAP manipulation economics

`StockAccountPriceChecker` is the reference price every stock account trade is checked against. For a
token listed with `PriceSource.PoolTwap` it reads the mean tick of that token's Aerodrome Slipstream
pool over `StockAccountRegistry.twapWindow()` and converts it to a USDC price; for a token listed with
`PriceSource.Chainlink` it delegates to the audited `SlippagePriceChecker`. Every quote is composed
through USDC, so a token-to-token quote is two of those legs.

The checker is a reference, not a trade route: the backend still has to fill at or above
`expectedOut * (10_000 - maxBackendSlippageBps) / 10_000`. This document answers what it costs someone
to push that reference far enough to be worth attacking, and what they can take once they have. All
numbers are measured on a pinned Base fork (block 51,181,271) by
`test/StockAccountPriceChecker.integration.t.sol`.

## The pool at the pin

The NVDAc/USDC pool (`0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9`, tick spacing 10, fee tier 500)
holds 913,213.16 USDC. One swap that pushes the pool's sqrt price to the -10% limit — NVDAc about
23.5% more expensive — takes 1,338,095.99 USDC in and pays out 5,862.85 NVDAc, moving the tick from
-7880 to -9987 and cutting in-range liquidity from 23,836,154,634,203 to 580,780,186,808.

Registry configuration used throughout: `maxStrategyDeposit` 25,000 USDC, `maxBackendSlippageBps` 100,
`maxDeviationBps` 1,000, `maxPositions` 10.

## Drift versus hold time

A single manipulation does nothing to the reference in the block it lands in. What moves the reference
is holding the manipulated tick. The mean tick is exactly linear in hold time and price is exponential
in tick, so with a window `W`, a hold `h` and a full-hold drift `D` the reference drifts by

```
drift(h) = (1 + D)^(h/W) - 1
```

With a 180-second window, a full-limit pump and no further pool activity:

| hold | drift | closed form | straight line |
| ---- | ----- | ----------- | ------------- |
| 3s   | 35 bps   | 35 bps   | 39 bps   |
| 12s  | 141 bps  | 140 bps  | 156 bps  |
| 30s  | 358 bps  | 357 bps  | 391 bps  |
| 60s  | 729 bps  | 727 bps  | 782 bps  |
| 90s  | 1112 bps | 1111 bps | 1173 bps |
| 150s | 1920 bps | 1919 bps | 1955 bps |
| 180s | 2346 bps | 2346 bps | 2346 bps |

Measurement and closed form agree to within 2 bps, the rounding of the mean tick to a whole tick. The
operative point is unchanged from a linear reading: an attacker buys drift by the second, there is no
threshold to clear. (The earlier claim that drift stays within 10% of a straight line is not true in
general — at the three-second hold above the straight line overstates the real drift by 10.3%, which
a 10% tolerance would reject.)

## Round-trip cost

Pushing the pool and putting it straight back costs only swap fees. Committing 1,338,095.99 USDC to
the pump and selling the whole 5,862.85 NVDAc position back in the same block destroys
**1,313.62 USDC — 9.8 bps of the amount committed**. That is two crossings of the pool's 5 bps fee
tier, slightly under 10 bps because the second crossing is charged on a smaller notional. The
attacker's real cash cost is that fee: the float itself comes back.

The attacker buys exactly the drift they intend to use, so the cost that matters is the cost of a
*usable* manipulation, not of a maximal one. Pumping to a chosen sqrt-price factor, holding the full
window and unwinding:

| sqrtP factor | full-hold drift | USDC committed | round-trip loss |
| ------------ | --------------- | -------------- | --------------- |
| x0.9995 | 11 bps   | 17,874.94    | 17.87    |
| x0.9975 | 51 bps   | 121,313.38   | 121.11   |
| x0.9950 | 101 bps  | 286,562.59   | 285.70   |
| x0.9900 | 204 bps  | 487,662.58   | 485.38   |
| x0.9800 | 413 bps  | 739,769.46   | 733.40   |
| x0.9000 | 2346 bps | 1,338,095.99 | 1,313.62 |

Opening the whole 100 bps budget costs **285.70 USDC**, not 1,313.62: the maximal pump is 23 times
larger than the attack needs.

## Exploit direction

Against `StockAccountStrategy` the profitable direction is a **deflated** reference — dumping NVDAc
into the pool so the TWAP prices it low, which lowers the `minOut` floor the backend's sell order has
to clear and lets a cheap fill pass. The tests measure the pump, which is the mirror image, and the
two are not interchangeable in cost: at the operative size (0.5% of sqrt price) the pump costs 285.70
against the dump's 355.25, so the pump *understates*; at the maximal size (10%) the pump costs
1,313.62 against the dump's 907.14, so it *overstates*.

The deflation direction is not bounded by the pool's USDC float. A dump to sqrtP x1.1 already drains
98.01% of the pool's USDC, but that is not a wall: past the liquidity range the price is nearly free.
A dump to sqrtP x2.0 moves 13,864 ticks instead of 1,906 for only 1.4% more NVDAc. The deflation
direction is effectively unbounded in magnitude at roughly constant cost.

## What one order can take

`StockAccountStrategy._checkRange` values both legs of an order at the reference — the manipulated one
— and bounds the resulting basket weights, so one order can move at most

```
min( sellHeld - (target_sell - maxDeviationBps) x navAfter ,
     (target_buy + maxDeviationBps) x navAfter - buyHeld )
```

The sell floor collapses to `sellValue <= sellHeld` whenever `target_sell <= maxDeviationBps`, because
the weight left behind can never be negative, and the buy leg is then the only binding constraint.
With `maxDeviationBps` at 1,000 that is exactly the case for a ten-position equal-weight basket, whose
buy leg caps one order at (1,000 + 1,000) / 10,000 = 20% of NAV, i.e. **5,000 USDC** at the deposit
cap. A basket with fewer, heavier positions has `target_sell` above the band and the sell floor binds
first, tighter. The worst case is the other end: a single-position basket (target 10,000, cash 0) is
bounded by neither leg, and one order can move the whole NAV — the full **25,000 USDC** deposit cap.

## Break-even

The manipulated reference and the slippage budget compound rather than capping each other.
`isValidSignature` computes `expectedOut` from the already-manipulated reference and then accepts a
fill at `expectedOut x (1 - s)`, so the attacker's edge on one filled order is

```
s    = maxBackendSlippageBps / 10_000
edge = 1 - (1 - drift) x (1 - s)
gain = exposure x edge
```

At 2346 bps of drift and a 100 bps budget the edge is 2423 bps, not 100. Against the cost of buying
exactly that drift:

| sqrtP factor | drift | edge | cost | gain, concentrated | gain, ten-position | orders to break even |
| ------------ | ----- | ---- | ---- | ------------------ | ------------------ | -------------------- |
| x0.9995 | 11 bps   | 111 bps  | 17.87    | 277.50   | 55.50    | 1 / 1 |
| x0.9975 | 51 bps   | 151 bps  | 121.11   | 377.50   | 75.50    | 1 / 2 |
| x0.9950 | 101 bps  | 200 bps  | 285.70   | 500.00   | 100.00   | 1 / 3 |
| x0.9900 | 204 bps  | 302 bps  | 485.38   | 755.00   | 151.00   | 1 / 4 |
| x0.9800 | 413 bps  | 509 bps  | 733.40   | 1,272.50 | 254.50   | 1 / 3 |
| x0.9000 | 2346 bps | 2423 bps | 1,313.62 | 6,057.50 | 1,211.50 | 1 / 2 |

Every figure is USDC; the last column is orders against a concentrated basket and against a
ten-position one. Against a concentrated basket **every row pays for itself on the first filled
order** — the 100 bps budget alone is worth 250 USDC on a 25,000 USDC order, more than the 17.87 USDC
the smallest usable manipulation costs. Against a ten-position basket the attacker needs between one
and four orders inside a single manipulated window, and the worst cell for them is a mid-sized pump:
the smallest and the largest manipulations are both cheaper per basis point of edge than the ones in
between.

So the deposit cap and the deviation band, not the slippage budget, are what bound a single order. And
up to the drift that opens the whole budget — the first three rows, the cheap ones — the slippage
budget is at least half the edge on its own, before any manipulation.

## What the window buys

The window does not change the cash cost of a manipulation, but it changes the manipulation an
attacker needs. If they can only hold the tick for `h` seconds — because other flow or an arbitrageur
will trade it back — then opening a budget `b` needs a full-hold drift of

```
D = (1 + b)^(W/h) - 1
```

which grows exponentially in `W/h`. Measured against the cheapest pump that actually opens a 100 bps
budget within that hold:

| window | hold | drift needed | cheapest pump reaches | its round-trip cost |
| ------ | ---- | ------------ | --------------------- | ------------------- |
| 60s  | 30s | 201 bps  | 204 bps  | 487.23   |
| 180s | 30s | 615 bps  | 618 bps  | 1,142.81 |
| 300s | 30s | 1046 bps | 1051 bps | 1,264.71 |
| 60s  | 12s | 510 bps  | 513 bps  | 1,023.73 |
| 180s | 12s | 1609 bps | 1620 bps | 1,287.37 |
| 300s | 12s | 2824 bps | unreachable at this pool's sqrt-price limit | — |

The exponent law holds to within 1.5% at every reachable cell. Against a 60-second window a
thirty-second attack costs 487.23; against 180 seconds the same attack costs 1,142.81, 2.3x more, and
against 300 seconds 1,264.71. A twelve-second attack — one or two Base blocks — is simply not
available at a 300-second window: it would need 2824 bps of drift and this pool tops out at about
2346 bps. **The window is what prices out the short attacks.** It buys nothing against an attacker who
can hold the tick for the whole window; against one who cannot, it is the only control that makes the
manipulation itself infeasible rather than merely expensive.

Read the other way — `h* = W ln(1 + b) / ln(1 + D)` — a full-limit pump (2344, 2346 and 2348 bps of
full-hold drift respectively) covers the whole 100 bps budget after 3 seconds at a 60-second window,
9 at 180 and 15 at 300.

## Fresh pools

A pool that keeps a single observation cannot be quoted at all: `observe` reverts and the checker
surfaces `InsufficientObservations`. Growing the observation buffer is necessary but **not
sufficient**. Until a second observation lands inside the window, `observe` extrapolates both
endpoints from the same one and the mean tick is the current tick, so the reference is spot with no
manipulation resistance whatsoever.

Measured on the cbBTC/USDC spacing-10 pool, which keeps cardinality 1 at the pin: after growing the
buffer and letting a window pass, the checker quotes 117,643.80 USDC per cbBTC — 5,238 bps away from
the Chainlink reference of 77,201.48, and 0 bps away from the manipulated spot. Only once a further
observation lands inside the window does the quote stop being spot (1,803 bps away from it). The swap
the test uses to move that pool is not small in effect: the pool is thin enough that a 100 USDC swap
runs it to whatever sqrt-price limit the caller sets.

The practical rule: a pool is not usable as a reference the moment its buffer is big enough, only once
it has carried trading for longer than the window.

## Market-closed caveat

**This section is an assumption, not a measurement** — nothing in the suite measures arbitrageur
behaviour. For tokenised equities, when the underlying market is closed an arbitrageur who unwinds the
attacker's pump cannot hedge the stock exposure they just took on, so they should be expected to
demand a much wider spread or not to show up at all. Outside market hours, assume the attacker can
hold the tick for the full window at the round-trip costs above, which removes the protection the
window otherwise provides, and plan the caps accordingly.

## Regenerating the numbers

```bash
source .env   # BASE_RPC_URL
make stock-price-checker
```

Every number above is emitted as a log by one of the `test_fork_*` tests in that file; read them off
the output (the Makefile target passes `-vvv`). Raw USDC and NVDAc amounts in the logs carry 6 and 8
decimals respectively. They are stable until someone moves the pin.
