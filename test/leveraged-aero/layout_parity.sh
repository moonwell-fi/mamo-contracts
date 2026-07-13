#!/usr/bin/env bash
#
# Extracts the CORRUPTION-CRITICAL diamond-storage triplet from the two vendored
# files that MUST share it byte-for-byte, and prints a unified diff (empty ==
# parity). Consumed by LayoutParity.t.sol via forge FFI.
#
#   kind = redeemrequest | layout | storageslot
#
# Normalization strips line comments (`// ...`) and trailing whitespace before
# comparing, so the meaningful invariant — the Solidity storage declarations
# (field types + order + names) and the STORAGE_SLOT literal — is what is
# checked. This intentionally tolerates the one benign self-referential comment
# inside `Layout` that reads "keep byte-identical in the manager" on the
# strategy side and "...in the strategy" on the manager side; it catches every
# storage-relevant drift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STRAT="$ROOT/src/leveraged-aero/LeveragedAerodromeCLStrategy.sol"
MGR="$ROOT/src/leveraged-aero/LeveragedAeroManager.sol"

norm() { sed 's#//.*##; s/[[:space:]]*$//' | grep -v '^[[:space:]]*$' || true; }

extract() {
  local file="$1" kind="$2"
  case "$kind" in
    redeemrequest) awk '/^    struct RedeemRequest \{/,/^    \}$/' "$file" ;;
    layout)        awk '/^    struct Layout \{/,/^    \}$/' "$file" ;;
    storageslot)   grep -E 'bytes32 private constant STORAGE_SLOT' "$file" ;;
    *) echo "unknown kind: $kind" >&2; exit 2 ;;
  esac
}

kind="${1:?usage: layout_parity.sh <redeemrequest|layout|storageslot>}"

diff <(extract "$STRAT" "$kind" | norm) <(extract "$MGR" "$kind" | norm) || true
