# Mamo Contracts

Smart contracts for Mamo yield strategies on Base. This glossary fixes the canonical vocabulary; terms cluster by subsystem as they are resolved.

## Language

### LP Auto-Balancer V2

**Main**:
The balanced, spot-straddling CL position holding the bulk of principal (single-sided only in the degenerate fully-out-of-range rebuild).
_Avoid_: primary position, base position

**Alt**:
The transient single-sided CL position that parks the surplus leg left over after the main mint.
_Avoid_: side position, buffer position

**Rebalance (no-swap)**:
The atomic re-range via `rebalanceUsingAlt`: withdraw both positions, rebuild main + alt from current balances, no token ever sold.
_Avoid_: reset (pre-rename name; grep-dead), bare "rebalance" where ambiguous

**Swap-rebalance**:
The two-phase cycle `unwindForSwap` → off-chain CowSwap order → `rebuildAfterSwap`, which may sell principal token0↔token1 under oracle bounds.
_Avoid_: swap rebalance without hyphen, principal swap

**Sweep**:
One iteration of the offchain backend's decision loop (`lp_balancer_sweep`): read snapshot → decide → execute → verify.
_Avoid_: cycle (reserved for the on-chain swap-rebalance window), tick

**In-flight**:
The window between `unwindForSwap` and its closer (`rebuildAfterSwap` or `exit`): both NFTs burned, order validation open, `rebalanceInFlight == true`.
_Avoid_: mid-swap, pending rebalance

**Loose balance**:
token0/token1 sitting on the balancer contract outside any position (settled compound proceeds, donations), awaiting fold.
_Avoid_: idle balance, stray funds

**Fold**:
The absorption of loose balance into the freshly minted main + alt at the next rebuild.
_Avoid_: sweep-in, reinvest (reserved for compound)

**Dust**:
The sub-threshold remainder forwarded to the feeCollector only AFTER the value floor passes.
_Avoid_: leftovers, residue

**Calm gate**:
The spot-vs-TWAP deviation check that blocks rebalances during unstable price.
_Avoid_: TWAP check, deviation gate

**Value floor**:
The invariant that post-operation value (positions + loose) must be at least the haircut applied to pre-operation position value, with loose added back un-haircut.
_Avoid_: slippage check (that is the CowSwap order's price check), loss cap

**Haircut**:
The tolerated-loss multiplier applied to pre-operation POSITION value when computing the value floor: `maxRebalanceLossBps` (+ `swapLossAllowanceBps` on the swap path). Never applies to loose balance.
_Avoid_: discount, tolerance band

**Skim / Drop**:
Forwarding of LP fees and the non-compounded AERO share to the feeCollector (DropAutomation) for the weekly drop.
_Avoid_: harvest (ambiguous — gauge claim vs forward)

**Compound share**:
The `compoundBps` fraction of harvested AERO forwarded to the LPCompoundModule to be sold (reward-only) back into the underlying pair.
_Avoid_: reinvestment rate

**Escape hatch**:
An admin-gated recovery path that works regardless of operational state: the balancer's `exit()` (always available, including mid-flight and paused) and both `recoverERC20` functions (balancer and module).
_Avoid_: emergency exit (only `exit()` is the mid-flight escape; recoverERC20 is narrower), rescue function

### Leveraged Aero Vault

**Vanilla vault**:
`LeveragedAeroVault` — the in-repo share ledger + owner-driven lifecycle driver the vendored leveraged-aero strategy binds to, replacing Sherwood's `SyndicateVault`. Not ERC-4626, not upgradeable, holds no position and computes no price.
_Avoid_: SyndicateVault (the replaced upstream contract), 4626 vault, minimal vault

**Leg A / Leg B**:
The two borrowed tokens of the CL pair, carried in `Layout` under the historical names `weth`/`mWeth`/`wethFeed` (leg A) and `cbBTC`/`mCbBTC`/`cbBTCFeed` (leg B). Slot names only — the actual tokens are init parameters, validated against the pool.
_Avoid_: WETH leg / cbBTC leg as if fixed, token0/token1 (that is pool ordering, derived separately via `wethIsToken0`)

**Deposits open**:
The vault's `depositsOpen` flag. Gates `strategyMint` only — new share issuance including fee-share crystallise. Never gates `strategyBurn`: exits keep working while issuance is frozen.
_Avoid_: paused, pause (there is no pause), deposits enabled

**Activate / Settle**:
The owner-only lifecycle drivers `activateStrategy(seed)` (pull seed to the strategy → `execute()`) and `settleStrategy()` (`settle()` → unwind → assets pushed to the vault). One-way, no proposal or vote behind them.
_Avoid_: execute/settle unqualified (those are the strategy-side calls), propose, proposal lifecycle

**Redeem-settled**:
The vault's permissionless post-settle exit `redeemSettled(shares)`: pro-rata against the vault's settled asset balance, priced on pre-burn supply. The only exit once the strategy is Settled — the strategy's own redeem paths require `Executed`.
_Avoid_: withdraw, redeem (reserved for the strategy's in-position `redeem`)

**Fee-config hops**:
The two-call protocol-fee lookup the strategy inherits (`vault.factory()` → `.protocolConfig()`). The vault plays both roles and returns `address(0)` on the first hop while `feeConfig` is unset — the launch default, meaning the protocol-fee leg is off.
_Avoid_: factory (nothing is deployed by it), ProtocolConfig as a contract we ship

**Width band**:
The init-time `[minWidth, maxWidth]` bounds, on the `tickSpacing` grid, that every rerange width must satisfy — the genesis width included. Enforced by `_checkWidth`, rejected with `WidthOutOfBounds()`.
_Avoid_: range (that is the resulting tickLower/tickUpper), tick spacing (the grid the band sits on)
