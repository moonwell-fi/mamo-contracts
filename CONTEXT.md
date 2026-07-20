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
