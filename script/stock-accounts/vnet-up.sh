#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

CALLER_VNET_RPC_URL=${TENDERLY_VNET_RPC_URL:-}

# shellcheck disable=SC1091
set -a && source .env && set +a

TENDERLY_VNET_RPC_URL=${CALLER_VNET_RPC_URL:-${TENDERLY_VNET_RPC_URL:-}}

DEPLOYER=0xDca82E03057329f53Ed4173429D46B0511E46Fb8
MULTISIG=0x26c158A4CD56d148c554190A95A921d90F00C160
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
TEST_USER=${TEST_USER:-$DEPLOYER}
VNET_REUSE=${VNET_REUSE:-0}
ADDRESSES_DIR=script/stock-accounts/addresses-vnet

if [ "$VNET_REUSE" = "1" ] && [ -n "${TENDERLY_VNET_RPC_URL:-}" ]; then
  RPC="$TENDERLY_VNET_RPC_URL"
  SLUG="(reused)"
else
  SLUG="stock-accounts-$(date +%s)"
  RESPONSE=$(curl -sS -X POST \
    "https://api.tenderly.co/api/v1/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets" \
    -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H 'Content-Type: application/json' \
    -d "{
      \"slug\": \"$SLUG\",
      \"display_name\": \"$SLUG\",
      \"fork_config\": {\"network_id\": 8453},
      \"virtual_network_config\": {\"chain_config\": {\"chain_id\": 8453}},
      \"sync_state_config\": {\"enabled\": false}
    }")
  RPC=$(echo "$RESPONSE" | jq -r '.rpcs[] | select(.name == "Admin RPC") | .url')
  [ -n "$RPC" ] && [ "$RPC" != "null" ] || { echo "$RESPONSE" >&2; exit 1; }
fi

export TENDERLY_VNET_RPC_URL="$RPC"

rpc() {
  curl -sS -X POST "$RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" > /dev/null
}

rpc tenderly_setBalance "[[\"$DEPLOYER\", \"$MULTISIG\", \"$TEST_USER\"], \"0x56BC75E2D63100000\"]"
rpc tenderly_setErc20Balance "[\"$USDC\", \"$TEST_USER\", \"0x2540BE400\"]"

if [ "$VNET_REUSE" != "1" ] || [ ! -d "$ADDRESSES_DIR" ]; then
  rm -rf "$ADDRESSES_DIR"
  mkdir -p "$ADDRESSES_DIR"
  cp addresses/*.json "$ADDRESSES_DIR/"
fi

export ADDRESSES_PATH="./$ADDRESSES_DIR"
export DEPLOY_ENV=8453_TESTING
export ADMIN_MODE=impersonate
export TEST_USER
export FOUNDRY_OUT=${FOUNDRY_OUT:-out}
export FOUNDRY_CACHE_PATH=${FOUNDRY_CACHE_PATH:-cache}

forge script script/StockAccountsPoolReadiness.s.sol:StockAccountsPoolReadiness \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --slow -vv

forge script script/DeployStockAccounts.s.sol:DeployStockAccounts \
  --rpc-url "$RPC" --broadcast --unlocked --sender "$DEPLOYER" --slow -vv

# The B20 stock tokens are node precompiles, which revm refuses to execute, so the deploy prints those
# listings instead of sending them and they go straight to the node here. They go last: an account's
# getNAV scans every listed token, so no forge script can touch an account once they are listed.
REGISTRY=$(jq -r '.[] | select(.name == "STOCK_ACCOUNT_REGISTRY") | .addr' "$ADDRESSES_DIR/8453.json")
ZERO=0x0000000000000000000000000000000000000000
TOKEN_LIST=$(jq -r '.tokens[] | select(.source == "PoolTwap") | "\(.token) \(.pool)"' config/stock-accounts/8453.json)

[ -n "$REGISTRY" ] && [ "$REGISTRY" != "null" ] ||
  { echo "no STOCK_ACCOUNT_REGISTRY in $ADDRESSES_DIR/8453.json; the deploy did not record one" >&2; exit 1; }
[ -n "$TOKEN_LIST" ] ||
  { echo "no PoolTwap entries in config/stock-accounts/8453.json; nothing to list" >&2; exit 1; }

# Whether the registry already holds the token. A call that fails is fatal rather than "listed": an
# empty status compares unequal to zero, which would skip the smoke run and every listing below.
listed() { # listed <token>
  local out status
  out=$(cast call "$REGISTRY" 'tokenConfig(address)(uint8,uint8,address,address)' "$1" --rpc-url "$RPC") ||
    { echo "tokenConfig($1) failed on $REGISTRY; cannot tell whether it is listed" >&2; exit 1; }
  status=$(printf '%s' "$out" | sed -n 1p | awk '{print $1}')
  [ -n "$status" ] || { echo "tokenConfig($1) returned nothing" >&2; exit 1; }
  [ "$status" != "0" ]
}

# `cast send` exits 0 on a mined-but-reverted transaction, so the receipt status is what decides, the
# same way the harness's `send` in scenarios/lib.sh does it.
send() { # send <to> <sig> [args...]
  local to=$1 out status
  shift
  out=$(cast send --rpc-url "$RPC" --unlocked --from "$DEPLOYER" --gas-limit 12000000 --json "$to" "$@") ||
    { echo "send failed: to=$to sig=$1" >&2; exit 1; }
  status=$(printf '%s' "$out" | jq -r '.status')
  [ "$status" = "0x1" ] || {
    echo "tx status $status: to=$to sig=$1 hash=$(printf '%s' "$out" | jq -r '.transactionHash')" >&2
    exit 1
  }
}

FIRST_TOKEN=$(printf '%s\n' "$TOKEN_LIST" | head -1 | awk '{print $1}')

if listed "$FIRST_TOKEN"; then
  echo "smoke skipped: the stock tokens are already listed, so getNAV cannot run under revm"
else
  forge script script/StockAccountsSmoke.s.sol:StockAccountsSmoke \
    --rpc-url "$RPC" --broadcast --unlocked --sender "$TEST_USER" --slow -vv
fi

while read -r TOKEN POOL; do
  if listed "$TOKEN"; then continue; fi
  [ -n "$POOL" ] && [ "$POOL" != "$ZERO" ] || { echo "no pool for $TOKEN in the token list" >&2; exit 1; }
  send "$REGISTRY" 'listToken(address,(uint8,uint8,address,address))' "$TOKEN" "(1,0,$POOL,$ZERO)" >/dev/null
  listed "$TOKEN" || { echo "listToken($TOKEN) was mined but the registry still reports it unlisted" >&2; exit 1; }
  echo "listed $TOKEN"
done <<<"$TOKEN_LIST"

echo "vnet slug: $SLUG"
echo "manifest: script/stock-accounts/vnet-manifest.json"
