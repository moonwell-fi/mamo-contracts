# Boosted USDG — Measured Sizing Dataset (Robinhood Chain 4663)

*Measured on-chain 2026-08-05, canonical Morpho Blue `0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010`, primary state block 28,035,587. Full provenance in §8. This dataset supersedes the reported "~15–20% looped ROE" figure carried in `ROBINHOOD_CHAIN_SPEC.md` §2 idea #3 and `ROBINHOOD_PLAN.md` §3 — those were [R]-grade; this is measured.*

**Verdict: Boosted USDG is not a revenue product on today's chain.** The three USDG-loan markets that matter sit at the AdaptiveCurveIRM's 90% target utilization with borrow rates arbitraged to within 50–100bps of collateral yield. The binding constraint is **rate impact, not liquidity**: the loop's own borrowing pushes the rate through the collateral yield after ~$0.6M of size. Launch-viable shape is a **$500k, 2x-leverage, syrupUSDG-only plumbing pilot** (~$400/yr of fee revenue at a 15% performance fee). Six-month outlook: $1–2M of viable size, not $20M.

---

## 1. The markets (62 of 68 canonical markets are USDG-loan; three are 99.99% of it)

| Collateral | LLTV | Oracle | Supply | Borrow | Util | Borrow APY | Free liquidity |
|---|---|---|---|---|---|---|---|
| USDe | 91.5% | composite: **hardcoded 1:1** ±0.5% band, then USDE/USD feed (16–24h window) | $227.5M | $205.3M | 90.2% | 3.53% | $22.2M |
| syrupUSDG | 91.5% | Chainlink syrupUSDG/USDG exchange-rate feed | $67.7M | $61.2M | 90.4% | 4.04% | $6.5M |
| spUSDG | 91.5% | ERC-4626 `convertToAssets` | $10.9M | $9.9M | 90.7% | 3.03% | $1.0M |

Remaining 59 markets are dust (≤$25k), incl. 40+ equity-collateral markets with ~zero borrow — the spec's "no live stock-collateral market" claim effectively still holds. Fees are 0% everywhere.

## 2. Collateral reality

| | syrupUSDG | spUSDG | USDe |
|---|---|---|---|
| Intrinsic yield (measured) | **5.01% APY** (62 Chainlink rate-feed rounds, 30d trailing) | **3.50% APY** (exact, from `chi`/`rho`/`drip`) | **0.00%** — no rate mechanism exists; **sUSDe is not on this chain** |
| Provenance | custodial mint/burn bridge token (single MINTER_ROLE) | native ERC-4626 on USDG, 99.96% cash-backed | LayerZero OFT (not the canonical gateway) |
| On-chain exit to USDG | **none** (no redeem, no DEX) | **yes — $12.7M instant `maxWithdraw`** | none locally (bridge out, sell on mainnet) |
| DEX pool on 4663 | none | none | none |
| Held inside Morpho Blue | 96.4% | 98.6% | 98.7% |

**No DEX pool exists for any loop collateral.** A loop engine that enters via on-chain swap cannot acquire syrupUSDG or USDe on this chain at all; only spUSDG has a fully on-chain entry+exit (its own vault). syrupUSDG entry/exit is an off-chain Maple bridge operation; deleveraging it is multi-day and outside our control.

## 3. Loop economics — the breakeven is the headline

Raw spreads: syrupUSDG **+97bps**, spUSDG **+47bps**, USDe **−353bps** (intrinsic). ROE at practical 7.41x leverage (LLTV−5pp): syrupUSDG 11.2%, spUSDG 6.5% — but only for the *first dollars in*. Simulating the live IRM against added borrow:

| Additional borrow until borrow APY ≥ collateral yield | |
|---|---|
| syrupUSDG | **$595k** |
| spUSDG | **$67k** |
| USDe | **$754k** |

Past those, the loop is loss-making at any leverage. Free liquidity is ~10x larger than carry capacity. Self-funding the supply side doesn't help: blended return at 2x computes to 4.75%, *below* just holding syrupUSDG at 5.01%. Sensitivities are violent: +200bps borrow or halved collateral yield puts every market deeply negative at high leverage. Existing loopers already run 88–91.2% LTV (thinnest observed buffer: **0.28pp** from liquidation).

## 4. Organic vs manufactured

- **syrupUSDG / spUSDG spreads are organic and thin** — no Merkl rewards flow to any of their top borrowers.
- **USDe carry is 100% incentive-manufactured**: zero intrinsic yield, −353bps raw spread, propped by a ~$9.0M/yr-pace Merkl campaign (≈3.87% APY on $233M). All 15 top borrowers are Merkl claimers; the top 5 borrowers are the top 5 claimers in exact rank order; top-15 claimers take 95.3% of rewards. This is ~15 professional loopers being paid to hold a non-yielding dollar. End the campaign and $228M unwinds.
- The steakUSDG (Earn) campaign, by contrast, is genuine retail: 7,402 claimant addresses, ≈0.49% APY actual run-rate.

## 5. The circularity

Steakhouse Earn's single adapter supplies **83.4% of all USDG borrow liquidity** ($255.9M of $306.97M): 99.9% of the syrupUSDG market, 100% of spUSDG, 77.9% of USDe. **A Boosted USDG loop borrows from Earn retail depositors and unwinds against their redemption queue.** Earn's own instant redemption capacity is ~$52M against $279M of assets (18.6%); measured gross redemptions already hit $13.3M in one day. If Mamo markets both a chassis (supply side) and a loop (borrow side), both sides of the trade are Mamo users.

## 6. Recommendation

- **Launch cap $500k TVL, 2x leverage, syrupUSDG market only, framed as a plumbing pilot.** $500k of borrow compresses the spread to ~15bps; ROE ≈5.2% vs 5.0% unlevered — the largest size that doesn't destroy its own economics. Exclude spUSDG ($67k headroom) and USDe (negative organic carry, hardcoded-1:1 oracle cliff at 91.5% LLTV, no local exit).
- Entry/exit for syrupUSDG is off-chain (Maple bridge) — the pilot needs an operational runbook, not just contracts.
- **Revisit triggers:** (i) syrupUSDG gains an on-chain redemption path or DEX; (ii) the organic spread widens past ~250bps; (iii) a new yield-bearing collateral with local liquidity lists. 6-month extrapolation of Earn growth (+$3.6M/day net measured, decayed) puts viable size at **$1–2M**, because new supply re-pins the rate — capacity scales with the vault; the spread does not improve.

## 7. Rogue singletons — resolved benign

The two non-canonical CreateMarket emitters (`0xba03eb57…`, `0xc8c01adf…`) are the same 12,283-byte third-party Blue fork deployed twice, memecoin-collateral markets (RUGD/HOODRAT/etc.), **all ten markets at zero supply and zero borrow**. No relevance, nothing to monitor. Also noted: a counterfeit 0-decimal "Global Dollar" exists as a loan token in one empty canonical market.

## 8. Provenance

Measured: market census via full-history `CreateMarket` logs (68/8/2 events); all states/APYs/simulations via `market()`/`borrowRateView` at block 28,035,587; adapter positions at 28,026,752; borrower LTVs at 28,031,997; collateral yields from pruning-immune stored data (Chainlink round history; `chi`/`rho` accumulator); Merkl attribution from on-chain claims (416k USDe claimed by 56 addresses). Chain timing measured: **0.297 s/block** (not the ~100ms carried in earlier docs), chain age 96 days. Assumed: USDe intrinsic yield = 0 (no rate mechanism exists — high confidence); ROE formulas exclude gas, bridge/swap costs and Mamo fees (all negative). Node prunes state ~1k–50k blocks back; historical `eth_call` beyond that fails.
