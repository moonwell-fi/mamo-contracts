# Listing a stock token: checks before the Safe transaction

A token joins the stock universe through one admin call on the `StockAccountRegistry`,
`listToken(token, {Active, PoolTwap, pool, no feed})`, signed by the Mamo multisig. The contract
checks what it can (the pool is on the router's factory and pairs the asset, the checker can quote
the token both ways at that moment). It cannot check history, and history is what decides whether
the pool is safe to price from. `script/stock-accounts/list-token-check.py` runs that history, the
identity checks and a Safe simulation, then prints the calldata and writes the Safe Transaction
Builder file, whatever the verdict.

## Rule

List a token only after its pool has traded normally for at least a full day. The script's
24 h window is the default gate; a FAIL on any blocking guard means wait and run it again.
Liquidity size is not the gate: a pool can hold half a million dollars and still have moments with
nothing in range.

## Run it

```bash
# needs cast (Foundry) and BASE_RPC_URL (environment or ./.env); read-only
make stock-list-check TOKEN=0xb20000000000000000000016e38FD364d271Ba28
python3 script/stock-accounts/list-token-check.py <token> [--pool <pool>] [--hours 24] [--out <dir>]
python3 script/stock-accounts/list-token-check.py <token> --recheck      # a token that is already listed (uses the registry's pool)
python3 script/stock-accounts/list-token-check.py <token> --to-block <n> # replay a past state
```

Exit code 1 when a blocking guard fails. The calldata, the expected `safeTxHash` at the Safe's live
nonce and `<out>/safe-tx-builder.json` are printed at the end either way, so a run that is still
blocked today needs no re-encoding tomorrow: only the `safeTxHash` moves with the nonce. A run takes
several minutes; most of it is the log scan.

## What each guard catches

| Guard | Blocking | Why |
|---|---|---|
| registry not paused, token not listed, cap not reached, token is not the asset | yes | the call would revert |
| runtime bytecode matches a listed token | yes | a look-alike token with the same symbol is not the issuer's |
| mints come from the listed tokens' minter (same sender key and mint contract) | yes | same reason; bytecode alone does not identify the issuer |
| pool is on the router's factory and pairs the asset | yes | `listToken` reverts otherwise; checked early so the rest runs on the right pool |
| `observe(twapWindow)` answers | yes | the checker reverts `InsufficientObservations` on a ring shorter than the window |
| TWAP within `maxBackendSlippageBps` of spot | yes | a window that already disagrees with spot is being moved |
| pool age and trading history cover the window | yes | a pool deployed earlier but empty until today has no history to judge |
| in-range liquidity never reached zero | yes | see below |
| no swap ended with zero liquidity, no sweep to `MIN_TICK`/`MAX_TICK` | yes | the visible consequence of a zero-liquidity moment |
| `listToken` succeeds from the Safe, config reads back, checker quotes both ways, non-admin refused | yes | `eth_simulateV1` on the live state; an RPC without it is a FAIL, not a pass |
| TVL, volume, impact per clip, largest clip inside the slippage cap, LP concentration | no | sizing information for the backend; the bar is a judgement call |

### The zero-liquidity guard

Every stock pool is made by one automated LP that re-ranges by burning its positions and minting
new ones, sometimes in different blocks. Between the burn and the mint nothing is in range. A swap
that lands in that moment walks the price to the end of the tick range (tick −887,272 or 887,272),
and that tick stays in the pool's observation ring until the next swap, mint or burn, so the
`twapWindow` mean tick the price checker reads is wrong for up to the window plus the gap. A pool
whose LP leaves such moments is not ready to be priced from, which is why a day of history is
required rather than a snapshot. The checker-side handling of such a window is MOO-1164.

The scan follows every `Mint`, `Burn` and `Swap` of the pool over the window. It seeds the
in-range liquidity from `slot0` and `liquidity()` at the block before the window opens, adjusts it for every
position that covers the live tick, and resyncs it at every swap (the `Swap` event carries the
pool's liquidity). A window where it reaches zero is a FAIL even if no swap landed in it.

## Fixture: ANTc on its first trading day

Anthropic listed on Nasdaq on 2026-11-19. The ANTc pool `0x599C…ED15` had existed since 11-16 but
started trading at 14:34 UTC that day, and its LP bot left fifteen zero-liquidity windows during the
afternoon (longest 23 s). Two buys landed inside them, at 17:17:08 and 17:19:54 UTC, and swept the
pool to tick −887,272; the second time the pool sat there for 97 s. The 180 s TWAP read 287 USDC
per share for about two minutes and then up to 6e22 for four more. The thirteen tokens listed at
the time showed no such window over the same 24 h.

```bash
python3 script/stock-accounts/list-token-check.py 0xb20000000000000000000016e38FD364d271Ba28 --to-block 59613837
```

must report 15 windows, 7 swaps that ended with zero liquidity, 2 sweeps, and exit 1 with the
listing calldata still printed. `--recheck` on any of the thirteen tokens listed before ANTc, over
the same day, must pass.

## After the Safe executes

```bash
cast call <registry> "tokenConfig(address)((uint8,uint8,address,address))" <token> --rpc-url base
cast call <checker>  "getExpectedOut(uint256,address,address)(uint256)" 100000000 <token> <USDC> --rpc-url base
```

Then, outside the contracts: the backend treats a feedless token as frozen while the market is
shut, sizes its clips from the "largest clip inside the slippage cap" line, and adds the token to
the spec's table; accounts that add it need `approveCowRelayer(token)` before their first order;
the app and docs lists gain the token.
