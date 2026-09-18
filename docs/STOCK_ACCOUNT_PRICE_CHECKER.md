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

The NVDAc/USDC pool (`0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9`, tick spacing 10) holds about
913,213 USDC. One swap that pushes the pool's sqrt price to the -10% limit — NVDAc about 23.5% more
expensive — takes 1,338,095.99 USDC in and pays out 5,862.85 NVDAc, moving the tick from -7880 to
-9987 and cutting in-range liquidity from 23,836,154,634,203 to 580,780,186,808.

Registry configuration used throughout: `maxStrategyDeposit` 25,000 USDC, `maxBackendSlippageBps` 100.

## Drift versus hold time

A single manipulation does nothing to the reference in the block it lands in. What moves the reference
is holding the manipulated tick, and the TWAP converges on it linearly in hold time — an attacker buys
drift by the second, there is no threshold to clear. With a 180-second window and no further pool
activity after the pump:

| hold | drift | linear prediction (`full × hold / 180`) |
| ---- | ----- | --------------------------------------- |
| 12s  | 141 bps  | 156 bps  |
| 30s  | 358 bps  | 391 bps  |
| 60s  | 729 bps  | 782 bps  |
| 90s  | 1112 bps | 1173 bps |
| 150s | 1920 bps | 1955 bps |
| 180s | 2346 bps | 2346 bps |

Measured drift sits within 10% of the linear prediction at every hold. It runs slightly under, because
the mean *tick* is what moves linearly and price is exponential in tick.

## Round-trip cost

Pushing the pool and putting it straight back costs only swap fees. Committing 1,338,095.99 USDC to
the pump and selling the whole 5,862.85 NVDAc position back in the same block destroys
**1,313.62 USDC — 9 bps of the amount committed**. That is the attacker's real cash cost: the float
itself comes back.

## Exploit direction

Against `StockAccountStrategy` the profitable direction is a **deflated** reference — dumping NVDAc
into the pool so the TWAP prices it low, which lowers the `minOut` floor the backend's sell order has
to clear and lets a cheap fill pass. A pump is the mirror image and is what the tests measure, because
the pump direction is not bounded by the pool's USDC float: the dump helper alone takes about 98% of
the pool's USDC at the pin, so the dump side cannot be pushed much further than the tests push it.

## Time to open the budget

The interesting quantity per window is how long the attacker must hold the tick before the drift
covers the whole 100 bps backend budget. Bisected to the second:

| window | full-hold drift | budget opens at |
| ------ | --------------- | --------------- |
| 60s  | 2344 bps | 3s  |
| 180s | 2346 bps | 9s  |
| 300s | 2348 bps | 15s |

Roughly window/20. The cash cost is identical in all three rows — 1,313.62 USDC — because it is a pure
pool operation and the window does not enter it. Lengthening the window buys time, not money.

## Break-even

Gain per filled order is bounded by the deposit cap and by the mispricing the checker will actually
accept:

```
gain = maxStrategyDeposit × min(drift_bps, maxBackendSlippageBps) / 10_000
```

At 25,000 USDC and 100 bps that is **250 USDC per order**, against a **1,313.62 USDC** round-trip cost:
**6 orders** must be filled inside one manipulated window to break even.

| window | hold | drift | usable | gain/order | orders to break even |
| ------ | ---- | ----- | ------ | ---------- | -------------------- |
| 60s  | 30s  | 1110 bps | 100 bps | 250 USDC | 6 |
| 60s  | 90s  | 2344 bps | 100 bps | 250 USDC | 6 |
| 60s  | 180s | 2344 bps | 100 bps | 250 USDC | 6 |
| 180s | 30s  | 358 bps  | 100 bps | 250 USDC | 6 |
| 180s | 90s  | 1112 bps | 100 bps | 250 USDC | 6 |
| 180s | 180s | 2346 bps | 100 bps | 250 USDC | 6 |
| 300s | 30s  | 214 bps  | 100 bps | 250 USDC | 6 |
| 300s | 90s  | 655 bps  | 100 bps | 250 USDC | 6 |
| 300s | 180s | 1351 bps | 100 bps | 250 USDC | 6 |

The slippage cap binds in every cell: at this pool's depth even a 30-second hold on a 5-minute window
already saturates a 100 bps budget. So the window is not what limits the damage — the deposit cap and
the slippage budget are. The window only decides how long the attacker has to keep the tick parked,
and therefore how long arbitrageurs have to take it off them.

## Market-closed caveat

That last point is weaker than it looks for tokenised equities. When the underlying market is closed,
an arbitrageur who unwinds the attacker's pump cannot hedge the stock exposure they just took on, so
they demand a much wider spread or do not show up at all. Outside market hours, assume the attacker can
hold the tick for the full window at roughly the round-trip cost above and plan the caps accordingly.

## Regenerating the numbers

```bash
source .env   # BASE_RPC_URL
make stock-price-checker
```

The drift table, the round-trip cost, the per-window "budget opens at" and the break-even grid are all
emitted as logs by `test_fork_twapDriftIsLinearInHoldTime`,
`test_fork_manipulationRoundTripCostsOnlyFees`, `test_fork_twapWindowSensitivity` and
`test_fork_manipulationBreakEvenGrid`; read them off the output (the Makefile target passes `-vvv`).
They are stable until someone moves the pin.
