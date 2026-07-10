#!/usr/bin/env bash
# ==============================================================================
# market.sh — price / market simulation primitives (SOURCED, after common.sh)
# ==============================================================================
# Composable cheat-RPC building blocks for driving market conditions on a vnet.
# The pool-move + reset choreography itself lives in the per-contract matrix runner
# (it just calls run_forge_phase for the pushTick/justReset/… entrypoints); this
# file holds the genuinely reusable state-control cheats.
#
# NOTE — coherent oracle+pool moves (`market_move`, mock-aggregator repoint,
# `set_feed_price`) are intentionally NOT here yet: LPV2's price simulation is the
# pool tick alone (the tick IS the WETH/cbBTC price; the Chainlink feed only backs
# the value floor, which is self-consistent before/after). Coherent oracle control
# is a hard requirement for the sherwood port (Moonwell health factor must move with
# price) and is built there, on top of these same snapshot/time primitives.
# ==============================================================================
[ -n "${_TENDERLY_MARKET_SH:-}" ] && return 0
_TENDERLY_MARKET_SH=1

# evm_snapshot → prints the snapshot id. Each snapshot can be reverted ONCE, so the
# matrix takes a fresh snapshot immediately before every scenario. Keep the number of
# blocks mined between snapshot and revert small (Tenderly caps evm_revert at ~2000).
snapshot()  { crpc evm_snapshot | tr -d '"'; }
revert_to() { crpc evm_revert "$1" >/dev/null; }

# accrue gauge emissions / let time pass, then mine (alias of advance_time for readability).
accrue_emissions() { advance_time "$1"; }
