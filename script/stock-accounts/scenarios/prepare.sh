#!/usr/bin/env bash
# Idempotent setup shared by every scenario: token listing, funded deployer, solver-enabled helper.
set -euo pipefail

SCEN=prepare
# shellcheck source=lib.sh
# shellcheck disable=SC2312 # a cd that failed leaves "/lib.sh", which `source` then fails to read under set -e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

init_results

echo "prepare: vnet $VNET (run $RUN_ID)"

fund "$DEPLOYER" 100000000000000

ensure_listed "$NVDA" "$NVDA_POOL"
# shellcheck disable=SC2312 # a read that failed prints nothing, which is not 1, so the assert records a FAIL
assert_eq "NVDAc listed as Active" "$(token_status "$NVDA")" 1

# Orders carry a signature by the registry order signer; on the vnet that is a public test key.
# shellcheck disable=SC2312 # same: nothing is not "0x", so a failed code read is a failed check
assert_eq "order signer is a plain EOA on this fork" "$(cast code "$ORDER_SIGNER" --rpc-url "$VNET" 2>>"$LOG")" 0x

CURRENT_SIGNER=$(call "$STOCK_REGISTRY" 'orderSigner()(address)')
# shellcheck disable=SC2312 # `lc` cannot fail, and the assert two lines down checks the signer that was actually left in place
if [ "$(lc "$CURRENT_SIGNER")" != "$(lc "$ORDER_SIGNER")" ]; then
  send "$DEPLOYER" "$STOCK_REGISTRY" 'setOrderSigner(address)' "$ORDER_SIGNER" >/dev/null
fi
# shellcheck disable=SC2312 # a failed read prints nothing, which compares unequal to the expected address
assert_eq "registry order signer is the harness key" "$(call "$STOCK_REGISTRY" 'orderSigner()(address)')" "$ORDER_SIGNER"

deploy_helper() {
  forge create --rpc-url "$VNET" --unlocked --from "$DEPLOYER" --broadcast --json \
    "$SCEN_DIR/SettlementHelper.sol:SettlementHelper" \
    --constructor-args "$SETTLEMENT" "$ROUTER" "$STOCK_REGISTRY" "$USDC" 2>>"$LOG" | jq -r '.deployedTo'
}

HELPER=$(cat "$STATE_DIR/helper" 2>/dev/null || true)
# Each code read is captured: an empty answer from a failed call is not "0x", so comparing it inline
# would read as "already deployed" and leave every settle pointing at an address with nothing on it.
HELPER_CODE=""
[ -z "$HELPER" ] || HELPER_CODE=$(cast code "$HELPER" --rpc-url "$VNET" 2>>"$LOG") || true
if [ -z "$HELPER_CODE" ] || [ "$HELPER_CODE" = "0x" ]; then
  HELPER=$(deploy_helper)
  echo "$HELPER" >"$STATE_DIR/helper"
  echo "prepare: deployed SettlementHelper at $HELPER"
  HELPER_CODE=$(cast code "$HELPER" --rpc-url "$VNET" 2>>"$LOG") || true
fi
if [ -n "$HELPER_CODE" ] && [ "$HELPER_CODE" != 0x ]; then
  pass "settlement helper has code" "$HELPER"
else
  fail "settlement helper has code" "cast code returned '$HELPER_CODE'"
fi

# The settlement only accepts `settle` from an allow-listed solver; the manager is impersonated here.
# shellcheck disable=SC2312 # a failed read is not "true", so the solver is registered again and the assert below decides
if [ "$(call "$COW_AUTHENTICATOR" 'isSolver(address)(bool)' "$HELPER")" != "true" ]; then
  set_eth "$COW_AUTH_MANAGER"
  send "$COW_AUTH_MANAGER" "$COW_AUTHENTICATOR" 'addSolver(address)' "$HELPER" >/dev/null
fi
# shellcheck disable=SC2312 # a failed read prints nothing, which is not "true"
assert_eq "helper registered as CoW solver" "$(call "$COW_AUTHENTICATOR" 'isSolver(address)(bool)' "$HELPER")" true

# appData is per (account, fee token): the backend uploads the document the account itself reports.
# Both sides are captured: `mani` exits from inside a substitution, so a manifest miss on both sides
# would otherwise compare empty against empty and pass the check having read nothing.
RECORDED_HASH=$(mani appDataHashUsdc)
DOCUMENT=$(jq -c '.appDataDocumentUsdc' "$MANIFEST")
DOCUMENT_HASH=$(cast keccak "$DOCUMENT")
SMOKE_ACCOUNT=$(mani testUserAccount)
ACCOUNT_HASH=$(app_data_hash "$SMOKE_ACCOUNT" "$USDC")
assert_eq "manifest USDC appData document hashes to the recorded hash" "$DOCUMENT_HASH" "$RECORDED_HASH"
assert_eq "the smoke account reports that same USDC appDataHash" "$ACCOUNT_HASH" "$RECORDED_HASH"

setup_note runId "$RUN_ID"
setup_note rpc "$VNET"
setup_note settlementHelper "$HELPER"
setup_note stockRegistry "$STOCK_REGISTRY"
setup_note priceChecker "$CHECKER"
setup_note strategyFactory "$FACTORY"

finish
