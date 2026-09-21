#!/usr/bin/env bash
# Idempotent setup shared by every scenario: token listing, funded deployer, solver-enabled helper.
set -euo pipefail

SCEN=prepare
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

init_results

echo "prepare: vnet $VNET (run $RUN_ID)"

fund "$DEPLOYER" 100000000000000

ensure_listed "$NVDA" "$NVDA_POOL"
assert_eq "NVDAc listed as Active" "$(token_status "$NVDA")" 1

# Orders carry a signature by the registry order signer; on the vnet that is a public test key.
assert_eq "order signer is a plain EOA on this fork" "$(cast code "$ORDER_SIGNER" --rpc-url "$VNET" 2>>"$LOG")" 0x

CURRENT_SIGNER=$(call "$STOCK_REGISTRY" 'orderSigner()(address)')
if [ "$(echo "$CURRENT_SIGNER" | tr 'A-Z' 'a-z')" != "$(echo "$ORDER_SIGNER" | tr 'A-Z' 'a-z')" ]; then
  send "$DEPLOYER" "$STOCK_REGISTRY" 'setOrderSigner(address)' "$ORDER_SIGNER" >/dev/null
fi
assert_eq "registry order signer is the harness key" "$(call "$STOCK_REGISTRY" 'orderSigner()(address)')" "$ORDER_SIGNER"

deploy_helper() {
  forge create --rpc-url "$VNET" --unlocked --from "$DEPLOYER" --broadcast --json \
    "$SCEN_DIR/SettlementHelper.sol:SettlementHelper" \
    --constructor-args "$SETTLEMENT" "$ROUTER" "$STOCK_REGISTRY" "$USDC" 2>>"$LOG" | jq -r '.deployedTo'
}

HELPER=$(cat "$STATE_DIR/helper" 2>/dev/null || true)
if [ -z "$HELPER" ] || [ "$(cast code "$HELPER" --rpc-url "$VNET" 2>>"$LOG")" = "0x" ]; then
  HELPER=$(deploy_helper)
  echo "$HELPER" >"$STATE_DIR/helper"
  echo "prepare: deployed SettlementHelper at $HELPER"
fi
assert_eq "settlement helper has code" "$([ "$(cast code "$HELPER" --rpc-url "$VNET" 2>>"$LOG")" = 0x ] && echo no || echo yes)" yes

# The settlement only accepts `settle` from an allow-listed solver; the manager is impersonated here.
if [ "$(call "$COW_AUTHENTICATOR" 'isSolver(address)(bool)' "$HELPER")" != "true" ]; then
  set_eth "$COW_AUTH_MANAGER"
  send "$COW_AUTH_MANAGER" "$COW_AUTHENTICATOR" 'addSolver(address)' "$HELPER" >/dev/null
fi
assert_eq "helper registered as CoW solver" "$(call "$COW_AUTHENTICATOR" 'isSolver(address)(bool)' "$HELPER")" true

setup_note runId "$RUN_ID"
setup_note rpc "$VNET"
setup_note settlementHelper "$HELPER"
setup_note stockRegistry "$STOCK_REGISTRY"
setup_note priceChecker "$CHECKER"
setup_note strategyFactory "$FACTORY"

finish
