# LeveragedAerodromeCLStrategy — audit package

This document is the entry point for auditing `src/leveraged-aero/`, the strategy contract of the
joint Sherwood × Mamo **leveraged Aerodrome LP fund**: a net-short, leveraged Aerodrome Slipstream
CL position (supply USDC to Moonwell → borrow cbBTC + WETH → concentrated LP → farm & compound AERO)
run by the Mamo backend as operator, on Sherwood's pooled-vault rails.

## Provenance

The code in `src/leveraged-aero/` is **vendored identical modulo import-path rewrites and `forge fmt`**
from the public Sherwood protocol repo — i.e. it compares equal to upstream after the import-path
rewrites and this repo's `forge fmt` whitespace normalization:

| | |
|---|---|
| Repo | https://github.com/sherwoodagent/sherwood-protocol |
| Pinned commit | [`bb10bebff3cbf554e7538e42f1e876a47b09a6ac`](https://github.com/sherwoodagent/sherwood-protocol/tree/bb10bebff3cbf554e7538e42f1e876a47b09a6ac) (2026-07-10) |
| Verified | 2026-07-13 — every vendored strategy file compared equal to the mirror at the pinned commit after import-path rewrites and `forge fmt` normalization |

Where this package and the upstream repo disagree, upstream at the pinned commit is authoritative.

## Scope

**Audit subject — the four contracts in `src/leveraged-aero/`:**

| Contract | Role |
|---|---|
| `LeveragedAerodromeCLStrategy.sol` | Thin entrypoints + `nav()` + init + ERC-7201 `Layout`; owns everything touching the vault / shares / fees. ERC-1167 clone. |
| `LeveragedAeroManager.sol` | All venue logic (supply/borrow/mint/stake/unwind/repay/swap), **delegatecalled** by the strategy. |
| `LeveragedAeroValuation.sol` | Oracle net-equity NAV; fail-closed. |
| `LeveragedAeroFees.sol` | Streaming management + high-water-mark performance fee math (`pure`). |

**Supporting context — `src/leveraged-aero/sherwood/`:** the Sherwood framework pieces the strategy
compiles against (`BaseStrategy`, interfaces, `ChainlinkReader` / `TickMath` / `LiquidityAmounts`,
`FeeConstants`, `BatchExecutorLib`). Vendored so the package is self-contained and compiling; these are
part of the already-reviewed Sherwood protocol and are context, not the primary subject.

**Not vendored, but load-bearing** — read these in the upstream repo:

- [`src/SyndicateVault.sol`](https://github.com/sherwoodagent/sherwood-protocol/blob/main/src/SyndicateVault.sol)
  — the pooled ERC-4626 vault. The strategy mints/burns vault shares through two hooks:
  `strategyMint(to, shares)` (`onlyActiveStrategy` + `whenNotPaused` + depositor whitelist) and
  `strategyBurn(shares)` (`onlyActiveStrategy`, deliberately **not** pause-gated so user exits work
  during an incident). The only thing standing between these hooks and arbitrary supply inflation is
  the `onlyActiveStrategy` gate (the active proposal's strategy, resolved through the per-vault governor).
- [`src/StrategyFactory.sol`](https://github.com/sherwoodagent/sherwood-protocol/blob/main/src/StrategyFactory.sol)
  — `cloneAndInit` (template allowlist, `proposer == msg.sender`, one-shot init).
- The per-vault governor lifecycle (propose → vote → guardian review → execute → settle) under which the
  strategy lives as one **indefinite** proposal.

## The corruption-critical invariant

`LeveragedAeroManager`'s public functions are **delegatecalled** from the strategy clone, so both files
declare the same diamond-storage triplet, which must stay **byte-identical** across the two files:

- `Layout` struct (and `RedeemRequest`)
- `STORAGE_SLOT` (`0x405ae0b1…844900`, ERC-7201 derived from `"leveraged.aero.cl.storage"`)
- the `_layout()` assembly accessor

Any field reorder/insert in one file without the other silently reads/writes wrong slots. There is no
compile-time cross-file check; this repo adds `test/leveraged-aero/LayoutParity.t.sol` as a CI tripwire
that textually compares the triplet between the two vendored files. (The comparison strips line comments:
the upstream `Layout` blocks carry one intentionally asymmetric self-referential comment — "keep
byte-identical in the manager" vs "…in the strategy" — while every storage-relevant token, the
`RedeemRequest` struct, and the `STORAGE_SLOT` literal are compared verbatim.)

**Bytecode margin note:** under this repo's optimizer profile (via_ir, runs=200), `LeveragedAeroManager`
compiles to 23,996 runtime bytes — only **580 bytes under** the EIP-170 cap (`LeveragedAerodromeCLStrategy`
is 19,514). Both Sherwood's CI and this repo's CI gate this — the build step runs `forge build --sizes`
(`.github/workflows/test.yml`), which fails on an EIP-170 violation, so an optimizer-setting change that
pushed the manager over the cap would break the build rather than slip through. Still re-check
`forge build --sizes` locally after any toolchain change.

## Custody model in one paragraph

Users deposit and withdraw **at the strategy contract** (not the vault) while holding standard vault
ERC-20 shares — "strategy-serviced custody". Deposits are priced at oracle net-equity NAV (`nav()`,
fail-closed: a stale feed or shoved pool denies the deposit, never mints cheap shares). Exits have three
entrypoints: fast oracle-priced `redeem` (LTV-gated, collateral-funded), async oracle-free
`requestRedeem → fulfillRedeem` (proposer, exact proportional unwind), and a trustless
`emergencyRedeem` deadman after 2 days. The operator (Mamo backend, the "proposer") manages the
position through a bounded interface (`deployIdle` / `compound` / `rerange` / `adjustLeverage`) with
hard LTV/health caps asserted after every action, plus a **permissionless** `deleverage` anyone can
trigger when health slips. The agent can never withdraw user funds to itself.

## Audit focus areas

Condensed from the upstream spec (§ *Audit focus areas & known risks*) — the full treatment with code
line references lives there:

1. **Delegatecall layout drift** — the top structural risk (see above).
2. **Oracle manipulation surface** — `nav()` prices deposits and the fast redeem. Focus on
   `oracleSqrtPriceX96` bounds, the calm-gate TWAP rounding, and `_usdcValue` decimal scaling in
   `LeveragedAeroValuation.sol`. CL legs split at an oracle-implied `sqrtP`, not pool `slot0`, so the
   mint mark cannot be tick-shoved.
3. **Deposit-side oracle-lag MEV (accepted, beta)** — a depositor front-running a pending Chainlink
   update can skim up to the feed deviation threshold; bounded by `maxDelay` + calm-gate.
4. **LTV-gate bypass attempts** — fast `redeem` predicts post-withdraw LTV on pre-withdraw prices;
   `_assertHealthy` as belt; permissionless `deleverage` repays only to `minHealthBps × 1.05`.
5. **Donation / inflation on strategy-side mint** — `nav()` excludes vault float but counts
   strategy-held idle USDC and out-of-position legs; `NavUnpriceable` guards only the `navNet == 0` case.
6. **IL-shortfall handling on full redeem** — the lone oracle dependency on the otherwise oracle-free
   proportional path; partial redeems cap IL cover at the redeemer's own budget.
7. **Fee paths** — fees crystallize on pre-action NAV (phantom-fee guard); protocol fee accrues as the
   `protocolFeeOwed` USDC liability netted out of `nav()`; crystallize is best-effort on user-exit paths
   (`FeeCrystallizeDeferred`) and hard-reverting on `compound`/`settle` — the asymmetry is intentional.
8. **`compound` reward swap** — routes through a hardcoded Aerodrome v2 router; the hardened AERO/USD
   oracle floor (`BelowOracleFloor`) is the honesty-independent guard.
9. **Accepted residuals** (documented upstream): `deleverage` oracle-staleness window vs Moonwell's own
   oracle; `selfManagesFees()` trust stopped by guardian review + owner veto; pending unclaimed AERO not
   in NAV; governance blast radius of the 3650-day duration ceiling; vault-side rescue dormancy under
   the indefinite proposal.
10. **Hardcoded swap-route `tickSpacing`** — the auxiliary USDC↔leg swap helpers in
    `LeveragedAeroManager.sol` (`_swapUsdcExactIn`, `_sweepLegToUsdc`, `_redeemCoverShortfall`) pin
    `tickSpacing: int24(100)` for the USDC/cbBTC and USDC/WETH Slipstream routes, whereas the main LP
    pool's spacing is config-driven (`$.tickSpacing`, used for range math and mint). This is a
    single-venue assumption with no fallback: if the 100-spacing pool for a leg is the wrong or an
    illiquid venue, the swap routes through it regardless. The slippage protection is uneven across
    call sites: `_settleShortfall`'s `_swapUsdcExactIn` calls pass an oracle-derived
    `minAmtOut = debtRem × (10000 − maxSlippageBps)/10000`; `_redeemCoverShortfall` is exact-output and
    bounded by `amountInMax` (a `type(uint256).max`/idle-USDC cap on full redeem, the redeemer's own
    budget on partial redeem, an oracle+slippage ceiling on the permissionless deleverage path); but the
    two redeem-path residual-leg sweeps (`redeemUnwindImpl` → `_sweepLegToUsdc($.cbBTC/$.weth, …, 0)`)
    pass `minOut = 0` and rely solely on the redeem's aggregate `minAssetsOut` floor rather than a
    per-swap bound. Focus: whether the fixed spacing plus the `minOut = 0` residual sweeps are
    exploitable under a manipulated/illiquid 100-spacing leg pool, and whether the aggregate floor is a
    sufficient guard.

## Accepted patterns / known non-issues

Pre-declared so auditors don't re-report them; each is a deliberate, reviewed choice in the vendored code.

- **No-op swap/mint deadlines.** Every Slipstream/Aerodrome swap and mint passes
  `deadline: block.timestamp + 600`. Because the deadline is computed relative to the execution block,
  it can never expire and provides no MEV/staleness protection. This is intentional: the real guards are
  the per-swap min-outs / oracle floors (item 8, item 10) and the redeem/deploy aggregate min-out floors,
  not the deadline. Accepted.
- **CEI ordering in `fulfillRedeem` / `emergencyRedeem`.** Both settle via `_proportionalRedeem`, which
  makes external calls — `IERC20(usdc).safeTransfer(recipient, assetsOut)` then
  `ISyndicateVault(vault()).strategyBurn(shares)` — *before* the caller writes `r.settled = true`, so the
  double-spend flag is set after the effects rather than before (a CEI-ordering deviation). Safe in
  practice: both functions are `nonReentrant` under `ReentrancyGuardTransient`, USDC has no transfer
  hooks, and the vault is a trusted in-scope contract, so no reentrant path can observe `settled == false`
  and re-enter. Accepted.

## Specification & documentation

- **Full spec + integration guide** (architecture, storage, authorization matrix, valuation & fees,
  invariants, integrator flows, events, errors):
  [`docs/LeveragedAerodromeCLStrategy.md`](https://github.com/sherwoodagent/sherwood-protocol/blob/main/docs/LeveragedAerodromeCLStrategy.md)
  in the upstream repo. The spec was re-verified claim-by-claim against source on 2026-07-13; two known
  minor errata at the pinned commit (a fix is upstream in review): the `ABSOLUTE_MAX_STRATEGY_DURATION`
  reference should read `GovernorParameters.sol:50` (not `:39`), and `MIN_VOTING_PERIOD` is now a
  constructor-set immutable (24h on mainnet, per-deployment) rather than a fixed 24h constant.
- Product-level overview of the fund (roles, trust boundary, what Sherwood vs Mamo contributes) is
  summarized in the PR description introducing this package.

## Test evidence & how to reproduce

**In this repo:**

- `forge build` — the vendored package compiles against OZ 5.2.0, via_ir, cancun.
- `forge test --match-path 'test/leveraged-aero/*' --ffi -vv` — the `Layout`/`RedeemRequest`/`STORAGE_SLOT`
  parity tripwire.

**Upstream (the full behavioral suite)** — the strategy's fork harness deploys the entire Sherwood
protocol (governor + factory → vault → clone + init → propose/vote/execute → deposit / deployIdle /
compound / rerange / deleverage / redeem → settle) against a Tenderly Base-fork vnet:

```bash
# in sherwoodagent/sherwood-protocol, with TENDERLY_FORK_RPC_URL in .env
./script/tenderly/run-leveraged-aero.sh
```

Last verified run — **2026-07-13, 62/62 tests green, 0 failed, 0 skipped** across 9 suites:
`LeveragedAeroCL.{deploy,deposit,leverage,redeem,rerange,compound,rescue,e2e}.fork.t.sol` +
`LeveragedAeroValuation.fork.t.sol`. Coverage highlights: full e2e lifecycle; LTV/health bounds and
permissionless deleverage recovery after an adverse Chainlink move; oracle-NAV invariance under a pool
tick-shove (vs a drifting naive slot0 NAV); fail-closed valuation on sequencer-down/stale feeds with
redeems still working; IL-shortfall cover at settle; performance fee on compounded yield.

**Invariant suite** (upstream): `test/invariants/LeveragedAeroCL.invariant.t.sol` — stayer per-share NAV
non-decreasing, health/LTV bounds after every op, `totalSupply` conservation across the mint/burn hooks,
no-exfil (the strategy only ever pays the vault or a redeeming user), `protocolFeeOwed` monotonicity.
