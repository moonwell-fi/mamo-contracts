#!/usr/bin/env bash
# ==============================================================================
# run-harness.sh — dispatcher for the per-contract Tenderly vnet harnesses
# ==============================================================================
# Routes to a per-contract orchestrator. The reusable vnet plumbing lives in
# lib/common.sh; each contract has a thin run-<name>.sh.
#
#   ./run-harness.sh                    → LPAutoBalancerV2 (default; back-compat)
#   ./run-harness.sh lpv2 [flags]       → LPAutoBalancerV2   (run-lpv2.sh)
#   ./run-harness.sh price-checker [..] → SlippagePriceChecker (run-price-checker.sh)
#   ./run-harness.sh leveraged-aero-account [..] → MamoLeveragedAeroStrategy account
#                                         (run-leveraged-aero-account.sh)
#
# Flags passed with no leading subcommand still route to lpv2, so the historical
# `make tenderly-harness` and `./run-harness.sh --scenario balanced` keep working.
# ==============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -eq 0 ]; then
  exec "$SCRIPT_DIR/run-lpv2.sh"
fi

case "$1" in
  lpv2)          shift; exec "$SCRIPT_DIR/run-lpv2.sh" "$@" ;;
  lpv2-matrix)   shift; exec "$SCRIPT_DIR/run-lpv2-matrix.sh" "$@" ;;
  price-checker) shift; exec "$SCRIPT_DIR/run-price-checker.sh" "$@" ;;
  leveraged-aero-account) shift; exec "$SCRIPT_DIR/run-leveraged-aero-account.sh" "$@" ;;
  --*)           exec "$SCRIPT_DIR/run-lpv2.sh" "$@" ;;   # bare flags → lpv2 (back-compat)
  *) echo "unknown harness '$1' (expected: lpv2 | lpv2-matrix | price-checker | leveraged-aero-account)"; exit 2 ;;
esac
