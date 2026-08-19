#!/usr/bin/env bash
# ==============================================================================
# run-lpv2-matrix.sh — LPAutoBalancerV2 PRICE-SIMULATION scenario matrix
# ==============================================================================
# Builds ONE funded, registered baseline, then runs each price-sim scenario off a
# fresh evm_snapshot (revert back to baseline between scenarios). For this WETH/cbBTC
# pool the tick IS the price, so a real broadcast swap through the pool = a price move.
#
#   0. calm reset (no move)        → reset re-centers a spot-straddling main IN range
#   1. large move down (out of range) → reset rebuilds a single-sided main above spot
#                                        (the V2 _mainRange fix), no swap, principal kept
#   2. calm gate fires             → tighten maxTickDeviation, push spot, reset reverts
#                                     TwapDeviation (spot deviates from the lagging TWAP)
#   3. stale oracle fires          → advance clock past maxOracleDelay, reset reverts
#                                     StaleOracle
#
# Usage:
#   ./script/tenderly/run-lpv2-matrix.sh            # fresh vnet by default
#   ./script/tenderly/run-lpv2-matrix.sh --reuse    # reuse TENDERLY_VNET_RPC_URL
#   (dispatcher: ./run-harness.sh lpv2-matrix [flags])
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$ROOT/script/tenderly/harness-results.log}"
: > "$RESULTS"

HARNESS_SLUG="lpv2-matrix"
HARNESS_DISPLAY="LPAutoBalancerV2 price-sim matrix"
PHASE_MARKERS='HARNESS_(LAB|SWAPPER)=|pushTick\.|justReset\.|assert|calmGate\.|StaleOracle|tightenCalmGate\.|\[OK\]'
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/market.sh
source "$SCRIPT_DIR/lib/market.sh"

FQ="script/tenderly/LPV2TenderlyHarness.s.sol:LPV2TenderlyHarness"

ETH_FUND_HEX=0x56BC75E2D63100000        # 100 ETH
WETH_FUND_HEX=0x3635C9ADC5DEA00000      # 1000 WETH (sender, for the initial mint)
CBBTC_FUND_HEX=0x12A05F200               # 50e8 cbBTC (sender)

# ── cli args ───────────────────────────────────────────────────────────────────
REUSE_VNET=0
KEEP_VNET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --reuse) REUSE_VNET=1; shift ;;
    --create) REUSE_VNET=0; shift ;;
    --keep)  KEEP_VNET=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

load_env
trap teardown EXIT

WETH="$(addr WETH)"
CBBTC="$(addr cbBTC)"
GAUGE="$(addr WETH_CBBTC_CL_GAUGE)"
NFPM="$(addr UNISWAP_V3_POSITION_MANAGER_AERODROME)"
AERO="$(addr AERO)"
ETH_USD="$(addr CHAINLINK_ETH_USD)"
BTC_USD="$(addr CHAINLINK_BTC_USD)"

resolve_vnet
section "Verify fork is Base + protocol wiring intact"
chain_sanity
[ "$(ccall "$GAUGE" 'nft()(address)')" = "$NFPM" ] || die "gauge.nft() != expected NFPM"
ok "gauge.nft()==NFPM"

# derive_sender reads the key from the env (not argv) via the harness sender() entrypoint — see common.sh
derive_sender "$FQ"
export HARNESS_SENDER="$SENDER"
export HARNESS_SCENARIO="balanced"   # baseline mints a spot-straddling main
info "sender: $SENDER"

ensure_feeds_fresh "$ETH_USD" "$BTC_USD"
section "Repair NFPM _nextId"; repair_nfpm_counter "$NFPM"

# ── baseline: fund → deploy swapper → deploy+mint balanced → register+stake ─────
section "Baseline: fund → swapper → deploy/mint → register/stake"
fund_eth "$SENDER" "$ETH_FUND_HEX"
fund_erc20 "$WETH" "$SENDER" "$WETH_FUND_HEX"
fund_erc20 "$CBBTC" "$SENDER" "$CBBTC_FUND_HEX"
ok "funded sender"

info "→ deploySwapper()"
run_forge_phase "$FQ" "deploySwapper()" 1 200 || die "deploySwapper failed"
capture_created_address "broadcast/LPV2TenderlyHarness.s.sol/8453/deploySwapper-latest.json"
export HARNESS_SWAPPER="$CREATED_ADDR"
info "swapper → $HARNESS_SWAPPER"
# fund the swapper generously so multi-tick pushes never run dry
fund_erc20 "$WETH"  "$HARNESS_SWAPPER" "$(cast to-hex 6000000000000000000000)"   # 6000 WETH
fund_erc20 "$CBBTC" "$HARNESS_SWAPPER" "$(cast to-hex 15000000000)"              # 150 cbBTC
ok "funded swapper (6000 WETH / 150 cbBTC)"

info "→ deployAndMint() (balanced straddle)"
run_forge_phase "$FQ" "deployAndMint()" 1 200 || die "deployAndMint failed"
capture_created_address "broadcast/LPV2TenderlyHarness.s.sol/8453/deployAndMint-latest.json"
export HARNESS_LAB="$CREATED_ADDR"
info "lab → $HARNESS_LAB"
HARNESS_TOKEN_ID="$(ccall "$NFPM" 'tokenOfOwnerByIndex(address,uint256)(uint256)' "$HARNESS_LAB" 0 | field)"
export HARNESS_TOKEN_ID
info "tokenId → $HARNESS_TOKEN_ID"

info "→ registerStake() (staked)"
run_forge_phase "$FQ" "registerStake()" 1 || die "registerStake failed"

# ── scenario runner: snapshot → body → revert ──────────────────────────────────
PASS=0; TOTAL=0
scenario() { # <name> <function...>
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  section "Scenario: $name"
  local snap; snap="$(snapshot)"
  info "snapshot=$snap"
  if "$@"; then ok "scenario '$name' passed"; PASS=$((PASS + 1)); else warn "scenario '$name' FAILED"; fi
  revert_to "$snap"
  info "reverted to baseline"
}

sc_calm_reset() {
  run_forge_phase "$FQ" "justReset()" 1 || return 1
  run_forge_phase "$FQ" "assertInRange()" 0
}
sc_move_down_single_sided() {
  # push spot decisively DOWN (sell WETH) → old range exited → one-sided withdrawal
  run_forge_phase "$FQ" "pushTick(bool,uint256)" 1 200 "true 2000000000000000000000" || return 1
  run_forge_phase "$FQ" "justReset()" 1 || return 1
  run_forge_phase "$FQ" "assertSingleSided()" 0
}
sc_calm_gate() {
  run_forge_phase "$FQ" "tightenCalmGate()" 1 || return 1
  # push spot so it deviates from the lagging TWAP by > tight maxTickDeviation; reset must revert
  run_forge_phase "$FQ" "pushTick(bool,uint256)" 1 200 "true 500000000000000000000" || return 1
  run_forge_phase "$FQ" "checkCalmGate()" 0
}
sc_stale_oracle() {
  advance_time 97200   # 27h > maxOracleDelay (24h — deployAndMint arms MAX_ORACLE_DELAY)
  run_forge_phase "$FQ" "checkStaleOracle()" 0
}

scenario "0 calm-reset → in range"          sc_calm_reset
scenario "1 large-move-down → single-sided" sc_move_down_single_sided
scenario "2 calm-gate fires → TwapDeviation" sc_calm_gate
scenario "3 stale-oracle → StaleOracle"     sc_stale_oracle

section "Summary"
info "price-sim scenarios passed: $PASS / $TOTAL"
[ "$PASS" = "$TOTAL" ] && ok "ALL price-sim scenarios passed" || die "$((TOTAL - PASS)) scenario(s) failed — see $RESULTS"
[ "$CREATED_VNET" = "1" ] && [ "$KEEP_VNET" = "1" ] && info "vnet kept: $RPC"
echo
