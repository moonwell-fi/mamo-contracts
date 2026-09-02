#!/usr/bin/env bash
# ==============================================================================
# run-price-checker.sh — SlippagePriceChecker Tenderly vnet harness
# ==============================================================================
# Simulation-only (checkPrice is `view`): exercises the LIVE deployed checker
# (CHAINLINK_SWAP_CHECKER_PROXY) against its real Chainlink config on a Base-fork vnet.
#   1. checkPriceGating() — fair minOut passes, under-priced minOut fails
#   2. advance the clock past the feed heartbeat
#   3. checkStalePrice()  — a stale feed makes getExpectedOut/checkPrice revert
#
# Usage:
#   ./script/tenderly/run-price-checker.sh          # fresh vnet by default
#   ./script/tenderly/run-price-checker.sh --reuse  # reuse TENDERLY_VNET_RPC_URL
#   (dispatcher: ./run-harness.sh price-checker [flags])
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$ROOT/script/tenderly/harness-results.log}"
: > "$RESULTS"

HARNESS_SLUG="price-checker"
HARNESS_DISPLAY="SlippagePriceChecker harness"
PHASE_MARKERS='priceGating\.|stalePrice\.|\[OK\]'
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/market.sh
source "$SCRIPT_DIR/lib/market.sh"

FQ="script/tenderly/SlippagePriceCheckerTenderlyHarness.s.sol:SlippagePriceCheckerTenderlyHarness"

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

resolve_vnet
section "Verify fork is Base"
chain_sanity
ensure_address_book

section "SlippagePriceChecker gate (live checker, real Chainlink config)"
info "→ checkPriceGating() [fair minOut passes, under-priced minOut fails]"
run_forge_phase "$FQ" "checkPriceGating()" 0 || die "checkPriceGating() failed"

info "→ advance clock +30d so the configured feeds exceed their heartbeat"
advance_time 2592000

info "→ checkStalePrice() [stale feed → checkPrice reverts]"
run_forge_phase "$FQ" "checkStalePrice()" 0 || die "checkStalePrice() failed"

section "Summary"
ok "SlippagePriceChecker harness passed (fair pass / under-priced reject / stale revert)"
[ "$CREATED_VNET" = "1" ] && [ "$KEEP_VNET" = "1" ] && info "vnet kept: $RPC"
echo
