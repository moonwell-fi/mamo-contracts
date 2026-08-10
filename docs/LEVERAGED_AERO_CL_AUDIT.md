# LeveragedAerodromeCLStrategy — audit package

This document is the entry point for auditing `src/leveraged-aero/` plus `src/LeveragedAeroVault.sol`,
the contracts of the Mamo **leveraged Aerodrome LP fund**: a leg-neutral, leveraged Aerodrome Slipstream
CL position (supply USDC to Moonwell → borrow two legs → concentrated LP → farm & compound the gauge
reward) run by the Mamo **rebalancer** as operator (the strategy's `proposer`) against a minimal in-repo
share vault. Leg-neutral by construction: each long LP leg is funded by debt in that same asset, so the
fund is not net-short the legs.

## Provenance

The strategy contracts originate from the public Sherwood protocol repo, but the package has **forked
in-repo** as of the two commits below. Sherwood will not deploy to Base; the strategy no longer runs on
Sherwood's pooled-vault / governor rails, and the venue assumptions have been parameterized.

| | |
|---|---|
| Origin repo | https://github.com/sherwoodagent/sherwood-protocol |
| Baseline commit | [`bb10bebff3cbf554e7538e42f1e876a47b09a6ac`](https://github.com/sherwoodagent/sherwood-protocol/tree/bb10bebff3cbf554e7538e42f1e876a47b09a6ac) (2026-07-10) |
| Vendor verification | 2026-07-13 — at that date every vendored file compared equal to the mirror at the pinned commit after import-path rewrites and `forge fmt` normalization |
| Status | **Forked.** Upstream at the pin is the historical baseline — useful for diffing what this fork changed — and is **no longer authoritative**. Where this package and upstream disagree, THIS repo is the subject under review. |

Delta against the baseline:

| Area | Change | Commit |
|---|---|---|
| Host swap (de-Sherwood) | New `src/LeveragedAeroVault.sol` replaces Sherwood's `SyndicateVault`; `sherwood/` shims shrunk to the surface the strategy actually consumes (`ISyndicateGovernor` + `BatchExecutorLib` deleted; `ISyndicateVault` → 3 functions; `BaseStrategy` rewritten for the vanilla vault-driven lifecycle) | `ea822be` |
| Any-pool init + validation | Leg decimals read from the tokens at init and bounded `[2, 18]` (were `CBBTC_DECIMALS` / `WETH_DECIMALS` constants); pool token ordering derived from `pool.token0()` (`wethIsToken0`, mapped through `_tokens01` / `_amounts01`) instead of the manager's hardwired `token0 == WETH`; per-leg swap-pool `tickSpacing` inputs replace three hardcoded `int24(100)` literals; native-ETH borrow wrap made conditional (`wethDeliversNative`); init venue guards (pool `tickSpacing` + token-set match, Moonwell `underlying()` binding, reject USDC-as-leg and reward-token-as-leg) | `978e5af` |
| Per-cycle rerange width | `rerange(uint24 width, uint256 minLiq0, uint256 minLiq1)` validated against an init-time `[minWidth, maxWidth]` band on the `tickSpacing` grid and persisted; `RANGE_TICK_SPACINGS` deleted; genesis mints at the init width; `WidthOutOfBounds()` = `0x1f9f54af` | `978e5af` |
| Per-cycle rerange **skew** | `rerange` grew a second argument — `rerange(uint24 width_, uint16 skewBps_, uint256 minLiq0, uint256 minLiq1)`. `skewBps` is the fraction of `width` placed **below** the current tick (bps, `10000` = 1.00; `5000` = centered, the previous fixed behaviour and the genesis/ops default). `lowerSpan = width × skewBps / 10000`, `upperSpan = width − lowerSpan`, both bounds still aligned DOWN to `tickSpacing`. Stored in `Layout` and surfaced on `layout()` exactly like `width`, so a flat-book `rerange` persists both and the next genesis mint re-mints at the stored pair. `centeredTickRange` → `skewedTickRange(pool, tickSpacing, width, skewBps)`; `rerangeImpl` narrowed to `(minLiq0, minLiq1)` and reads both knobs from storage (the persists moved to the strategy). **`WidthOutOfBounds()` renamed `OutOfBounds()` = `0xb4120f14`** and reused for both knobs | *this change* |
| Comment hygiene | Three comment-only hunks in the strategy retiring stale Sherwood rationale (`selfManagesFees`, `_protocolConfig`, `rescueToVault`); new docstring on the manager's trimmed `_config()` | `ea822be`, `978e5af` |

> **Selector break in the skew row, called out deliberately.** The width row above records
> `WidthOutOfBounds()`'s selector (`0x1f9f54af`), which was matched to the Mamo backend's rebalance-param
> error code. The rename to `OutOfBounds()` **changes that selector to `0xb4120f14`** — the pairing is
> broken until the backend's error table is re-pointed, and the error's meaning is now wider (width *or*
> skew). `rerange`'s own selector changed with the added argument. Both are intentional, both are
> pre-launch, and neither is upgrade-safe to do later; re-derive rather than copy
> (`cast sig 'OutOfBounds()'`, `cast sig 'rerange(uint24,uint16,uint256,uint256)'`).

> **Known, accepted consequence of skew — two-borrowed-legs shape only.** The genesis / `deployIdle`
> borrow is range-blind (`_borrowHalfEach` splits 50/50 by USD value), so a **skewed** range is not 50/50
> by value and the book carries a persistent idle remainder of one borrowed token. This is **not** a hedge
> break (the idle borrowed token 1:1 hedges its own debt, and `nav()` prices it) and **not** an LTV/health
> change — it is capital-utilisation drag: less of the book earns LP fees. Mitigated operationally
> (init `skewBps = 5000`, apply skew via `rerange`, size the skew against the drag). Making the borrow
> range-aware is a possible follow-up and is **out of scope** here.

Field names in `Layout` still read `cbBTC` / `weth` / `mCbBTC` / `mWeth`. These are **leg slots**, not
token commitments — leg B and leg A respectively. Nothing in the code assumes those particular tokens
after `978e5af`.

## Scope

**Audit subject — the four contracts in `src/leveraged-aero/` plus the vault:**

| Contract | Role |
|---|---|
| `LeveragedAerodromeCLStrategy.sol` | Thin entrypoints + `nav()` + init/validation + ERC-7201 `Layout`; owns everything touching the vault / shares / fees. ERC-1167 clone. |
| `LeveragedAeroManager.sol` | All venue logic (supply/borrow/mint/stake/unwind/repay/swap/rerange), **delegatecalled** by the strategy. |
| `LeveragedAeroValuation.sol` | Oracle net-equity NAV; fail-closed. |
| `LeveragedAeroFees.sol` | Streaming management + high-water-mark performance fee math (`pure`). |
| `LeveragedAeroVault.sol` | **In scope as of `ea822be`.** The share ledger (ERC-20, `asset.decimals() + 6`) + `Ownable2Step` lifecycle driver. Owns the `strategyMint` / `strategyBurn` hooks that are the only thing standing between the strategy and arbitrary share inflation — the backstop named in focus area 5. Non-upgradeable, holds no position, computes no price. |

**Supporting context — `src/leveraged-aero/sherwood/`:** the framework pieces the strategy compiles
against (`BaseStrategy`, interfaces, `ChainlinkReader` / `TickMath` / `LiquidityAmounts`,
`FeeConstants`). The interface names are preserved because the strategy imports those paths/types
verbatim; the bodies have been trimmed to the consumed surface (`ISyndicateVault` is now three
functions, implemented by `LeveragedAeroVault`). `BaseStrategy` was **rewritten** in `ea822be` for the
vanilla lifecycle — it is fork-local code, not vendored context.

**Adjacent, not in this package:** `src/MamoLeveragedAeroStrategy.sol` (per-user account wrapper) and
`ILeveragedAeroCLStrategy`, reviewed with PR #64. Neither has a code change across the two commits —
the wrapper's only diff is a NatSpec hunk repointing its terminal-state escape hatch at the vault's
`redeemSettled`. They are exercised by the same unit gate (see Test evidence).

**Deploy flow** (replaces Sherwood's `StrategyFactory.cloneAndInit`): deploy the vault → `Clones.clone`
the strategy template → `strategy.initialize(vault, proposer = MAMO_BACKEND, initData)` →
`vault.setStrategy(strategy)` (set-once) → `vault.setOpenDeposits(true)` →
`vault.activateStrategy(seedAmount)`, which pulls the seed from the owner straight to the strategy and
calls `execute()`. There is no template allowlist and no atomic clone+init: **the clone is initializable
by anyone between `clone` and `initialize`**, so the two must be broadcast together or the deployment
front-run check must be done by hand. The vault's `setStrategy` is the binding that matters — a clone
someone else initialized against a different vault cannot mint here.

## The corruption-critical invariant

`LeveragedAeroManager`'s public functions are **delegatecalled** from the strategy clone, so both files
declare the same diamond-storage triplet, which must stay **byte-identical** across the two files:

- `Layout` struct (and `RedeemRequest`)
- `STORAGE_SLOT` (`0x405ae0b1…844900`, ERC-7201 derived from `"leveraged.aero.cl.storage"`)
- the `_layout()` assembly accessor

Any field reorder/insert in one file without the other silently reads/writes wrong slots. There is no
compile-time cross-file check; `test/leveraged-aero/LayoutParity.t.sol` is the CI tripwire that
textually compares the triplet between the two files. (The comparison strips line comments: the `Layout`
blocks carry one intentionally asymmetric self-referential comment — "keep byte-identical in the
manager" vs "…in the strategy" — while every storage-relevant token, the `RedeemRequest` struct, and the
`STORAGE_SLOT` literal are compared verbatim.) `978e5af` appended 9 fields into one packed slot and the
tripwire is green on both files.

**Bytecode margin note:** under this repo's optimizer profile (via_ir, `optimizer_runs = 200`, cancun):

| Contract | Runtime bytes | Margin under EIP-170 |
|---|---|---|
| `LeveragedAeroManager` | 24,025 | **551** |
| `LeveragedAerodromeCLStrategy` | 22,447 | 2,129 |
| `LeveragedAeroVault` | 5,206 | 19,370 |

The manager's 551-byte margin is the binding constraint and is what forced the drop-only `_config()`
trim in `978e5af` (see gap 4). CI gates this — the build step runs `forge build --sizes`
(`.github/workflows/test.yml`), which fails on an EIP-170 violation, so an optimizer-setting change that
pushed the manager over would break the build rather than slip through. Still re-check
`forge build --sizes` locally after any toolchain change.

## Custody model in one paragraph

Users deposit and withdraw **at the strategy contract** (not the vault) while holding standard vault
ERC-20 shares — "strategy-serviced custody". Deposits are priced at oracle net-equity NAV (`nav()`,
fail-closed: a stale feed or shoved pool denies the deposit, never mints cheap shares). Exits have three
entrypoints while the strategy is `Executed`: fast oracle-priced `redeem` (LTV-gated,
collateral-funded), async oracle-free `requestRedeem → fulfillRedeem` (proposer, exact proportional
unwind), and a trustless `emergencyRedeem` deadman after 2 days. The operator (Mamo backend, the
"proposer") manages the position through a bounded interface (`deployIdle` / `compound` / `rerange` /
`adjustLeverage`) with hard LTV/health caps asserted after every action, plus a **permissionless**
`deleverage` anyone can trigger when health slips. The agent can never withdraw user funds to itself.

The lifecycle around that is **vault-owner-driven**, not governance-driven: the vault owner
(MAMO_MULTISIG, `Ownable2Step`) calls `activateStrategy(seed)` → strategy `execute()`, and
`settleStrategy()` → strategy `settle()`, which unwinds the whole levered book and pushes the realized
asset balance to the vault. There is no proposal, no vote, no guardian review and no duration ceiling —
the position runs until the owner settles it. After settlement the strategy's own redeem paths are
closed (they require `State.Executed`), so the **only** exit is the vault's permissionless
`redeemSettled(shares)`: pro-rata against the vault's settled asset balance, computed on pre-burn supply
and pre-transfer balance, rounding in the stayers' favour. The owner can also freeze new issuance at any
time via `setOpenDeposits(false)`, which gates `strategyMint` only — `strategyBurn` is deliberately
never gated so exits keep working during an incident.

## Audit focus areas

Items 1–9 are condensed from the upstream spec (§ *Audit focus areas & known risks*), which still holds
for the strategy internals at the baseline commit. Items 10–12 are fork-local.

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
   strategy-held idle USDC and out-of-position legs; `NavUnpriceable` guards only the `navNet == 0`
   case. The backstop is now in scope: `LeveragedAeroVault.strategyMint` performs no pricing of its own
   and takes the strategy's share count on faith, gated solely on `msg.sender == strategy` (set-once)
   and `depositsOpen`.
6. **IL-shortfall handling on full redeem** — the lone oracle dependency on the otherwise oracle-free
   proportional path; partial redeems cap IL cover at the redeemer's own budget.
7. **Fee paths** — fees crystallize on pre-action NAV (phantom-fee guard); protocol fee accrues as the
   `protocolFeeOwed` USDC liability netted out of `nav()`; crystallize is best-effort on the deposit and
   user-exit paths (`FeeCrystallizeDeferred`) and hard-reverting on `compound` — the asymmetry is
   intentional. `_settle` does NOT crystallize: it unwinds, discharges `min(protocolFeeOwed, balance)` to
   the live recipient, and pushes the rest to the vault, so an unpayable fee cannot block settlement.
   The protocol-fee lookup is now a two-hop through the vault (`vault.factory()` → `.protocolConfig()`);
   `LeveragedAeroVault` returns `address(0)` on the first hop until the owner sets `feeConfig`, so the
   **protocol-fee leg is OFF at launch** and the strategy short-circuits before the second hop. The
   management/performance fee legs are strategy-local and unaffected. Note the fork-local interaction
   with item 5: a fee-share crystallize mints through `strategyMint`, so it also reverts while
   `depositsOpen == false`. Tolerated on the best-effort paths; on `compound` it is fatal whenever fee
   shares are actually due (`feeShares > 0` — nonzero fee bps and elapsed time or a fresh HWM), so
   closing deposits can make `compound` un-callable until the owner reopens them. It is masked entirely
   if both fee bps are initialized to 0; the init params for this deployment are not in-repo, so this
   cannot be checked from the source alone. Confirm the coupling is intended.
8. **`compound` reward swap** — routes through a hardcoded Aerodrome v2 router; the hardened reward/USD
   oracle floor (`BelowOracleFloor`) is the honesty-independent guard. Init asserts the reward feed is
   8-decimal and rejects a leg token that equals the gauge reward token.
9. **Accepted residuals** — `deleverage` oracle-staleness window vs Moonwell's own oracle; pending
   unclaimed gauge rewards not in NAV; `selfManagesFees()` self-attestation (there is no guardian review
   or owner veto in this fork — the mitigation is simply that `LeveragedAeroVault` has no fee path at
   all, so there is nothing for a lying strategy to double-charge against); **open-ended position
   duration** (the 3650-day governance ceiling is gone — the position runs until the owner calls
   `settleStrategy`, so the owner key IS the duration bound); **vault rescue policy** (`rescueERC20` is
   owner-only and refuses the vault asset while `totalSupply() > 0`, so the strategy's `rescueToVault`
   sweeps of stray non-position tokens are recoverable at any time, and the asset pot is claimable only
   after every share has exited — this replaces the upstream "rescue dormant under `redemptionsLocked`"
   residual).
10. **Swap-route `tickSpacing`** — the three hardcoded `int24(100)` literals in the auxiliary
    leg↔USDC swap helpers (`_swapUsdcExactIn`, `_sweepLegToUsdc`, `_redeemCoverShortfall`) are gone;
    the spacing is now per-leg config (`$.cbBTCSwapTickSpacing` / `$.wethSwapTickSpacing`, read through
    `_legSwapSpacing`). **The init check is only `!= 0`** — nothing verifies the named swap pool exists,
    is the right pair, or is liquid, so the wrong-or-illiquid-venue concern is narrowed to a
    configuration risk rather than eliminated. Slippage protection remains uneven across call sites:
    `_settleShortfall`'s `_swapUsdcExactIn` calls pass an oracle-derived
    `minAmtOut = debtRem × (10000 − maxSlippageBps)/10000`; `_redeemCoverShortfall` is exact-output and
    bounded by `amountInMax` (`type(uint256).max`/idle-USDC cap on full redeem, the redeemer's own
    budget on partial redeem, an oracle+slippage ceiling on the permissionless deleverage path); but the
    two redeem-path residual-leg sweeps (`redeemUnwindImpl` → `_sweepLegToUsdc($.cbBTC/$.weth, …, 0)`)
    still pass `minOut = 0` and rely solely on the redeem's aggregate `minAssetsOut` floor rather than a
    per-swap bound. Focus: whether the `minOut = 0` residual sweeps are exploitable under a manipulated
    or illiquid leg swap pool, and whether the aggregate floor is a sufficient guard.
11. **Venue parameterization (new in `978e5af`)** — the highest-value fork-local review target, because
    it rewrites the manager's hot paths and has **no behavioral fork coverage** (gap 1). Check:
    (a) `wethIsToken0` ordering is threaded correctly through every `_tokens01` / `_amounts01` /
    `_mintPosition` / `_addLiquidity` site, in BOTH orderings — the manager previously hardwired
    `token0 == WETH` while the valuation was already dynamic, so this is a real prior mismatch being
    corrected, not a refactor; (b) the stored `cbBTCDecimals` / `wethDecimals` replace what were bare
    `1e8` / `1e18` borrow-sizing literals — verify no `10 ** dec` scaling site was missed; (c) the init
    guards actually bind the venue (`pool.tickSpacing()`, `token0`/`token1` set match, Moonwell
    `underlying()`, USDC-as-leg and reward-token-as-leg rejection, decimals in `[2, 18]`); (d)
    `wethDeliversNative == false` leaves `receive()` accepting ETH with no wrap (gap 3).
12. **Rerange width band + skew + the vault's own surface** — `rerange(width, skewBps, …)` accepts a
    per-cycle width **and skew** and `_checkWidth` enforces the grid + `[minWidth, maxWidth]` band on
    both the genesis width and every subsequent one; the band itself is validated once at init
    (`% spacing == 0`, `minWidth >= 2 × spacing`, `min <= max`). `skewBps` is checked alongside it —
    strictly inside `(0, 10000)`, and **both** derived spans (`width × skewBps / 10000` and the
    remainder) at least one `tickSpacing`, which is what keeps the range strictly bracketing spot at
    small widths. Confirm a proposer cannot degenerate the range to an empty or single-tick band **by
    either knob**, that the down-alignment of both bounds cannot invert them or push spot outside the
    minted range, and that the persisted `$.width` / `$.skewBps` cannot desync from the minted position.
    Note also that an extreme (still-valid) skew can leave the range far enough off spot to trip the
    pre-existing `DegenerateRange()` in `assetModeSplit` — a new path to an old guard, not a new failure
    mode. On the vault: `setStrategy` set-once, `redeemSettled` rounding and the pre-burn/pre-transfer
    ordering, the `decimals() = asset.decimals() + 6` coupling to the strategy's `SHARES_VIRTUAL_OFFSET = 1e6` genesis
    pricing, `activateStrategy`'s owner-funded seed path, and the `rescueERC20` asset carve-out.

## Accepted patterns / known non-issues

Pre-declared so auditors don't re-report them; each is a deliberate, reviewed choice.

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
  hooks, and the vault is trusted (now in-repo and in scope — see below), so no reentrant path can
  observe `settled == false` and re-enter. Accepted.
- **`Syndicate`-prefixed interface names.** `ISyndicateVault` / `ISyndicateFactory` retain their upstream
  names and import paths so the strategy source stays diff-able against the baseline commit. They are
  implemented by `LeveragedAeroVault`; there is no Sherwood contract in the deployment.
- **`Layout` leg field names.** `cbBTC` / `weth` / `mCbBTC` / `mWeth` / `wethIsToken0` are leg-slot
  names, kept because renaming them would break the byte-identical `Layout` parity across two files for
  no behavioral gain. Documented as leg B / leg A in the source.

### Trusted-vault note

The strategy trusts its vault: it takes `vault()` as its share ledger, calls `strategyMint` /
`strategyBurn` unconditionally, resolves its rescue authority as `Ownable(vault()).owner()`, and reads
the fee config through `vault.factory()`. That trust now rests on **`src/LeveragedAeroVault.sol`, which
is in this repo and in this review** — not on an upstream contract reviewed elsewhere. Conversely the
vault trusts the strategy completely for share pricing. The pair must be reviewed together; neither
half's guarantees survive on its own.

## Known gaps / follow-ups

Stated plainly; none are closed.

1. **No behavioral fork coverage for the `978e5af` manager rewrites.** The ordering, leg-decimals and
   swap-spacing changes were argued equivalent under the legacy (cbBTC/WETH, 100-spacing) config by
   tracing each call site by hand, and the unit suite proves the init-time validation and both pool
   orderings *at init* — but **the `wethIsToken0 == false` branch has never been driven through a mint,
   deploy, compound, rerange or redeem.** A venue fork suite (Tenderly Base fork, both orderings, a
   non-8/18-decimal leg pair) is the named top follow-up and should gate any deployment on a pool whose
   ordering differs from the legacy config.
2. **Moonwell `underlying()` not verified on the live markets.** The new init guard
   `IMoonwellMarket(mX).underlying() != legX → VenueMismatch` will brick initialization if the live
   mWETH / mcbBTC markets do not expose `underlying()`. Verify on a Base fork before any deploy.
3. **Stray ETH is stranded when `wethDeliversNative == false`.** `receive()` still accepts ETH
   unconditionally (it must, for the native-borrow path), but the wrap is now conditional. On a
   deployment whose leg-A market delivers ERC-20, ETH sent to the strategy sits there with no wrap and no
   sweep — `rescueToVault` is ERC-20-only and there is no ETH rescue path.
4. **The manager's `_config()` is a partial `Config`.** It populates only the three fields `_calmGate`
   reads (`pool`, `twapWindow`, `calmDeviationTicks`) and leaves every other member at its zero default;
   handing it to `netEquityUsdc` would silently value against `address(0)`. The docstring carries that
   warning and all three call sites pass it straight to `_calmGate`, but the type does not enforce it.
   The flagged structural fix is a distinct `CalmConfig` type — deferred because the manager has only
   551 bytes of EIP-170 headroom.

## Specification & documentation

- **Full spec + integration guide** (architecture, storage, authorization matrix, valuation & fees,
  invariants, integrator flows, events, errors):
  [`docs/LeveragedAerodromeCLStrategy.md`](https://github.com/sherwoodagent/sherwood-protocol/blob/main/docs/LeveragedAerodromeCLStrategy.md)
  in the origin repo. It remains the best description of the strategy internals **as of the baseline
  commit**, and its `§`-references are the ones cited in the source NatSpec. It is stale w.r.t. this
  fork in exactly the places the fork changed: the host/vault/governor sections describe Sherwood's
  proposal lifecycle rather than the vanilla activate/settle one, and it predates the any-pool init and
  the rerange width band and skew. The spec was re-verified claim-by-claim against source on 2026-07-13; two
  minor errata at the pinned commit relate to Sherwood governance constants and no longer apply here.
- Product-level overview of the fund (roles, trust boundary, operating model) is summarized in the PR
  description introducing this package.

## Test evidence & how to reproduce

**In this repo** (all fork-free; `make test-unit`):

```bash
make test-unit                       # 459 tests / 0 failed across 13 suites
make leveraged-aero-vault            # LeveragedAeroVault.unit.t.sol
make leveraged-aero-account          # MamoLeveragedAeroStrategy.unit.t.sol
forge test --match-path 'test/leveraged-aero/*' --ffi -vv   # parity tripwire + init/width suite
forge build --sizes                  # EIP-170 margins (table above)
```

Last verified locally 2026-07-27: **459 passed / 0 failed / 0 skipped**. Relevant breakdown:

| Suite | Tests | Covers |
|---|---|---|
| `test/LeveragedAeroVault.unit.t.sol` | 45 | The vault end-to-end against a mock strategy: `strategyMint`/`strategyBurn` gating, set-once `setStrategy`, `depositsOpen`, decimals coupling, `activateStrategy`/`settleStrategy`, `redeemSettled` pro-rata + rounding, `rescueERC20` asset carve-out, fee-config hops |
| `test/leveraged-aero/LeveragedAeroStrategyInit.unit.t.sol` | 31 | Init validation (venue guards, leg decimals band, USDC/reward-token leg rejection, width band, `skewBps` bounds) and `rerange` width/skew/auth — **including both pool orderings at init** |
| `test/MamoLeveragedAeroStrategy.unit.t.sol` | 51 | The per-user account wrapper (adjacent, not in this package's scope) |
| `test/leveraged-aero/LayoutParity.t.sol` | 4 | The `Layout` / `RedeemRequest` / `STORAGE_SLOT` tripwire. **Not part of the 459** — it is not a `*.unit.t.sol` file; it runs under `make test` and under the `test/leveraged-aero/*` match-path above. 4/4 green. |

**Upstream (behavioral, baseline only)** — the strategy's fork harness in the origin repo deploys the
entire Sherwood protocol (governor + factory → vault → clone + init → propose/vote/execute → deposit /
deployIdle / compound / rerange / deleverage / redeem → settle) against a Tenderly Base-fork vnet:

```bash
# in sherwoodagent/sherwood-protocol, with TENDERLY_FORK_RPC_URL in .env
./script/tenderly/run-leveraged-aero.sh
```

Last verified run — **2026-07-13, 62/62 tests green** across 9 suites. Coverage highlights: full e2e
lifecycle; LTV/health bounds and permissionless deleverage recovery after an adverse Chainlink move;
oracle-NAV invariance under a pool tick-shove; fail-closed valuation on sequencer-down/stale feeds with
redeems still working; IL-shortfall cover at settle; performance fee on compounded yield. An invariant
suite (`test/invariants/LeveragedAeroCL.invariant.t.sol`) covers stayer per-share NAV non-decreasing,
health/LTV bounds after every op, `totalSupply` conservation across the mint/burn hooks, no-exfil, and
`protocolFeeOwed` monotonicity.

**Read that evidence narrowly.** It exercises the strategy internals **at the baseline commit**, on the
Sherwood host, with the legacy cbBTC/WETH config. It does NOT cover: the `LeveragedAeroVault` host swap,
the any-pool ordering/decimals/swap-spacing rewrites, or the rerange width band and skew. **There is no
behavioral (fork) suite in this repo for the forked code** — the in-repo gate is unit-level and
mock-based. Closing that is follow-up 1 and it is the single largest evidence gap in this package.
