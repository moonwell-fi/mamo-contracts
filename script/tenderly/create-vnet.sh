#!/usr/bin/env bash
# ==============================================================================
# create-vnet.sh — create a PERSISTENT Tenderly Base-fork vnet (runbook Phase A)
# ==============================================================================
# Automates the one step the leveraged-aero harnesses deliberately do not do:
# creating the persistent vnet they deploy onto (run-leveraged-aero-stack.sh is
# reuse-only by design). Defaults follow docs/LEVERAGED_AERO_VNET_RUNBOOK.md:
#
#   - custom chain id 73578453 (7357-prefix convention; addresses/73578453.json
#     and EXPECTED_CHAIN=73578453 already accommodate it)
#   - state-sync DISABLED (constraint 3: a syncing parent re-hydrates the real
#     Chainlink aggregators over the FreshFeed overrides and corrupts the pool
#     TWAP ring buffer)
#   - persistent (never auto-deleted; the delete command is printed at the end)
#
# Usage:
#   ./script/tenderly/create-vnet.sh <slug> [display-name]
#   VNET_CHAIN_ID=73578453 ./script/tenderly/create-vnet.sh mamo-remint-range
#
# Prints the Admin RPC (ops-only — never share), Public RPC, vnet id and fork
# block. Writes nothing: the stack harness owns leveraged-aero-vnet.json.
#
# Requires: curl, jq, cast, and TENDERLY_ACCESS_KEY + account/project slugs in .env.
# ==============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$SCRIPT_DIR/create-vnet.log}"
: > "$RESULTS"
KEEP_VNET=1
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SLUG="${1:?usage: create-vnet.sh <slug> [display-name]}"
DISPLAY="${2:-$SLUG}"
VNET_CHAIN_ID="${VNET_CHAIN_ID:-73578453}"

[ -f .env ] && { set -a; . ./.env; set +a; }
_derive_tenderly_slugs
{ [ -n "${TENDERLY_ACCESS_KEY:-}" ] && [ -n "${TENDERLY_ACCOUNT_SLUG:-}" ] && [ -n "${TENDERLY_PROJECT_SLUG:-}" ]; } \
  || die "need TENDERLY_ACCESS_KEY (+ TENDERLY_ACCOUNT_SLUG/TENDERLY_PROJECT_SLUG) in .env"

section "Create persistent Base-fork vnet '$SLUG' (chainId $VNET_CHAIN_ID, state-sync OFF)"
resp="$(curl -s -X POST "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets" \
  -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d "{\"slug\":\"$SLUG\",\"display_name\":\"$DISPLAY\",\"fork_config\":{\"network_id\":8453},\"virtual_network_config\":{\"chain_config\":{\"chain_id\":$VNET_CHAIN_ID}},\"sync_state_config\":{\"enabled\":false},\"explorer_page_config\":{\"enabled\":true,\"verification_visibility\":\"src\"}}")"
VNET_ID="$(echo "$resp" | jq -r '.id // empty')"
ADMIN_RPC="$(echo "$resp" | jq -r '.rpcs[]? | select(.name=="Admin RPC") | .url')"
PUBLIC_RPC="$(echo "$resp" | jq -r '.rpcs[]? | select(.name=="Public RPC") | .url')"
[ -n "$ADMIN_RPC" ] && [ -n "$VNET_ID" ] || die "vnet create failed: $resp"

CID="$(cast chain-id --rpc-url "$ADMIN_RPC" 2>/dev/null)"
[ "$CID" = "$VNET_CHAIN_ID" ] || die "expected chainId $VNET_CHAIN_ID, got '$CID'"
BLOCK="$(cast block-number --rpc-url "$ADMIN_RPC" 2>/dev/null)"

section "Summary — vnet '$SLUG' is LIVE (persistent)"
info "Vnet id    : $VNET_ID"
info "Chain id   : $CID (fork of Base @ block $BLOCK)"
info "Admin RPC  : $ADMIN_RPC   (ops-only — cheatcodes; never share)"
info "Public RPC : $PUBLIC_RPC"
info "Explorer   : https://dashboard.tenderly.co/$TENDERLY_ACCOUNT_SLUG/$TENDERLY_PROJECT_SLUG/testnet/$VNET_ID"
info "Delete     : curl -X DELETE $TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets/$VNET_ID -H \"X-Access-Key: \$TENDERLY_ACCESS_KEY\""
info "Next       : TENDERLY_VNET_RPC_URL=$ADMIN_RPC EXPECTED_CHAIN=$CID ./script/tenderly/run-leveraged-aero-stack.sh"
