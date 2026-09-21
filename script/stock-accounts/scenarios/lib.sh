#!/usr/bin/env bash
# Shared plumbing for the stock account vnet scenarios. Sourced, never executed.

SCEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCEN_DIR/../../.." && pwd)"
STATE_DIR="$SCEN_DIR/.state"
RESULTS="$SCEN_DIR/results.json"
LOG="$STATE_DIR/harness.log"
MANIFEST="$REPO_ROOT/script/stock-accounts/vnet-manifest.json"
ADDRESS_BOOK="$REPO_ROOT/addresses/8453.json"

mkdir -p "$STATE_DIR"
cd "$REPO_ROOT"

set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
set +a

export FOUNDRY_OUT=${FOUNDRY_OUT:-out}
export FOUNDRY_CACHE_PATH=${FOUNDRY_CACHE_PATH:-cache}

[ -f "$MANIFEST" ] || { echo "missing $MANIFEST; run 'make tenderly-stock-accounts' first" >&2; exit 1; }

# Both lookups are fatal on a miss: jq prints "" or "null" and exits 0, which would otherwise travel
# on as an RPC url or a call target.
book() { # book <name> -> its address in addresses/8453.json
  local addr
  addr=$(jq -r --arg n "$1" '.[] | select(.name == $n) | .addr' "$ADDRESS_BOOK")
  [ -n "$addr" ] && [ "$addr" != "null" ] || { echo "no $1 in $ADDRESS_BOOK" >&2; exit 1; }
  printf '%s\n' "$addr"
}

mani() { # mani <key> -> its value in the vnet manifest
  local value
  value=$(jq -r --arg n "$1" '.[$n]' "$MANIFEST")
  [ -n "$value" ] && [ "$value" != "null" ] || { echo "no $1 in $MANIFEST" >&2; exit 1; }
  printf '%s\n' "$value"
}

VNET=$(mani rpc)
DEPLOYER=$(mani testUser)
STOCK_REGISTRY=$(mani STOCK_ACCOUNT_REGISTRY)
CHECKER=$(mani STOCK_ACCOUNT_PRICE_CHECKER)
FACTORY=$(mani STOCK_ACCOUNT_STRATEGY_FACTORY)
CL_FACTORY=$(mani AERODROME_STOCKS_CL_FACTORY)
ROUTER=$(mani AERODROME_STOCKS_SWAP_ROUTER)
QUOTER=$(mani AERODROME_STOCKS_QUOTER)
USDC=$(book USDC)
SETTLEMENT=$(book COWSWAP_SETTLEMENT)
RELAYER=$(book COWSWAP_VAULT_RELAYER)

# CoW allow-list authenticator and its manager, impersonated on the vnet to register our solver.
COW_AUTHENTICATOR=0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE
COW_AUTH_MANAGER=0xA03be496e67Ec29bC62F01a428683D7F9c204930

# The stock token the scenarios trade, one of the four the deploy lists; its Slipstream pool against
# USDC, tick spacing 10.
NVDA=0xb20000000000000000000078ee7ce2fE4908108C
NVDA_POOL=0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9

# The order signer prepare.sh points the registry at, from the public test key
# `cast keccak "mamo stock accounts order signer"`. The anvil accounts cannot be used: all of them
# carry an EIP-7702 delegation on Base, which makes them ERC-1271 signers rather than plain EOAs.
ORDER_SIGNER=0xc419099bfA195fe92e57d137dFe3b2116E9203fe
ORDER_SIGNER_KEY=0x7b6a9fd55d3ea602d74d514fc4d8366d864d3d565ba36ba636701eed6c19b047

KIND_SELL=0xf3b277728b3fee749481eb3e0b3b48980dbbab78658fc419025cb16eee346775
BALANCE_ERC20=0x5a28e9363bb942b639270062aa6bb295f434bcdfc42c97267bf003f272060dc9
MAGIC_VALUE=0x1626ba7e
ORDER_T='(address,address,address,uint256,uint256,uint32,bytes32,uint256,bytes32,bool,bytes32,bytes32)'
POOL_CREATED_TOPIC=0xab0d57f0df537bb25e80245ef7748fa62353808c54d6e528a9dd20887aed9ac2
MAX_UINT=115792089237316195423570985008687907853269984665640564039457584007913129639935
SEND_GAS_LIMIT=12000000

FAILURES=0
SCEN=${SCEN:-lib}

# ---------------------------------------------------------------- arithmetic

# Big integers past 2^63 (sqrt prices, wei) are beyond bash arithmetic.
bn() { python3 -c "print(int($1))"; }
bb() { python3 -c "print(1 if ($1) else 0)"; }
lc() { printf '%s\n' "$1" | tr 'A-Z' 'a-z'; }

# ---------------------------------------------------------------- rpc

rpc() { # rpc <method> <params-json>
  local out
  out=$(curl -sS -m 120 -X POST "$VNET" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}")
  if [ "$(printf '%s' "$out" | jq -r 'has("error")')" = "true" ]; then
    echo "rpc $1 failed: $out" >&2
    return 1
  fi
  printf '%s' "$out" | jq -r '.result'
}

read -r -d '' BATCH_CALL_PY <<'PYSRC' || true
import json, sys, urllib.request
rpc = sys.argv[1]
calls = [l.split() for l in sys.stdin.read().splitlines() if l.strip()]
body = [{'jsonrpc': '2.0', 'id': i, 'method': 'eth_call', 'params': [{'to': to, 'data': data}, 'latest']}
        for i, (to, data) in enumerate(calls)]
if body:
    request = urllib.request.Request(rpc, json.dumps(body).encode(), {'content-type': 'application/json'})
    for reply in sorted(json.load(urllib.request.urlopen(request, timeout=120)), key=lambda r: r['id']):
        print(reply.get('result', '0x'))
PYSRC

# One http round trip for many eth_calls. Reads "to data" pairs on stdin, prints one result per line.
batch_call() { python3 -c "$BATCH_CALL_PY" "$VNET"; }

callraw() { cast call --rpc-url "$VNET" "$@" 2>>"$LOG"; }

# Nth returned value, stripped of cast's "[1e9]" annotation.
calln() { local n=$1; shift; callraw "$@" | sed -n "${n}p" | awk '{print $1}'; }
call() { calln 1 "$@"; }

# Nth returned value kept whole, for the "[a, b, c]" array returns.
callline() { local n=$1; shift; callraw "$@" | sed -n "${n}p"; }
# A row of a "[a, b, c]" return, by index. A non-numeric index is a failed lookup, never row 0:
# bash reads "" as the unary plus of nothing and would hand sed a 1.
list_at() { # list_at <bracketed-list> <index>
  case "${2-}" in '' | *[!0-9]*)
    echo "list_at: '${2-}' is not a row index" >&2
    return 1
    ;;
  esac
  printf '%s' "$1" | tr -d '[]' | tr ',' '\n' | sed -n "$(($2 + 1))p" | awk '{print $1}'
}

send() { # send <from> <to> <sig> [args...]
  local from=$1 to=$2 out status
  shift 2
  # An explicit limit: estimation against the B20 precompiles occasionally comes back short.
  if ! out=$(cast send --rpc-url "$VNET" --unlocked --from "$from" --gas-limit "$SEND_GAS_LIMIT" --json "$to" "$@" 2>>"$LOG"); then
    echo "send reverted: from=$from to=$to sig=$1 (see $LOG)" >&2
    return 1
  fi
  status=$(printf '%s' "$out" | jq -r '.status')
  if [ "$status" != "0x1" ]; then
    echo "tx status $status: from=$from to=$to sig=$1 hash=$(printf '%s' "$out" | jq -r '.transactionHash') gasUsed=$(printf '%s' "$out" | jq -r '.gasUsed')" >&2
    return 1
  fi
  printf '%s' "$out"
}

estimate_gas() { # estimate_gas <from> <to> <sig> [args...]
  local from=$1 to=$2
  shift 2
  cast estimate --rpc-url "$VNET" --from "$from" "$to" "$@" 2>>"$LOG"
}

set_eth() { rpc tenderly_setBalance "[[\"$1\"],\"0x56BC75E2D63100000\"]" >/dev/null; }
set_usdc() { rpc tenderly_setErc20Balance "[\"$USDC\",\"$1\",\"$(cast to-hex "$2")\"]" >/dev/null; }
# Tenderly mines a block on evm_increaseTime, so reads and order deadlines see the new time at once.
increase_time() { rpc evm_increaseTime "[\"$(cast to-hex "$1")\"]" >/dev/null; }
now_ts() { cast block latest --field timestamp --rpc-url "$VNET" 2>>"$LOG"; }

# ---------------------------------------------------------------- results

init_results() { [ -f "$RESULTS" ] || echo '{"setup":{},"checks":[]}' >"$RESULTS"; }

record() { # record <scenario> <check> <0|1> <value>
  local flag=false
  [ "$3" = 1 ] && flag=true
  init_results
  jq --arg s "$1" --arg c "$2" --argjson p "$flag" --arg v "$4" \
    '.checks += [{scenario: $s, check: $c, pass: $p, value: $v}]' "$RESULTS" >"$RESULTS.tmp"
  mv "$RESULTS.tmp" "$RESULTS"
}

setup_note() { # setup_note <key> <value>
  init_results
  jq --arg k "$1" --arg v "$2" '.setup[$k] = $v' "$RESULTS" >"$RESULTS.tmp"
  mv "$RESULTS.tmp" "$RESULTS"
}

pass() { record "$SCEN" "$1" 1 "${2-}"; printf '  ok   %-44s %s\n' "$1" "${2-}"; }
fail() { record "$SCEN" "$1" 0 "${2-}"; printf '  FAIL %-44s %s\n' "$1" "${2-}" >&2; FAILURES=$((FAILURES + 1)); }

assert_eq() { # assert_eq <check> <actual> <expected>
  if [ "$(echo "$2" | tr 'A-Z' 'a-z')" = "$(echo "$3" | tr 'A-Z' 'a-z')" ]; then
    pass "$1" "$2"
  else
    fail "$1" "actual=$2 expected=$3"
  fi
}

assert_gt() { # assert_gt <check> <a> <b>
  if [ "$(bb "$2 > $3")" = 1 ]; then pass "$1" "$2 > $3"; else fail "$1" "$2 !> $3"; fi
}

assert_gte() { # assert_gte <check> <a> <b>
  if [ "$(bb "$2 >= $3")" = 1 ]; then pass "$1" "$2 >= $3"; else fail "$1" "$2 !>= $3"; fi
}

assert_approx() { # assert_approx <check> <actual> <expected> <tolerance-bps>
  if [ "$(bb "abs($2 - $3) * 10000 <= $4 * $3")" = 1 ]; then
    pass "$1" "$2 ~ $3"
  else
    fail "$1" "actual=$2 expected=$3 tol=${4}bps"
  fi
}

# ---------------------------------------------------------------- reverts

_expect_revert() { # _expect_revert <send|call> <check> <want> <from> <to> <sig> [args...]
  local mode=$1 check=$2 want=$3 from=$4 to=$5 out rc=0
  shift 5
  if [ "$mode" = send ]; then
    out=$(cast send --rpc-url "$VNET" --unlocked --from "$from" "$to" "$@" 2>&1) || rc=$?
  else
    out=$(cast call --rpc-url "$VNET" --from "$from" "$to" "$@" 2>&1) || rc=$?
  fi
  if [ $rc -eq 0 ]; then
    fail "$check" "succeeded, expected revert ${want:-any}"
    return 0
  fi
  out=$(printf '%s' "$out" | tr '\n' ' ')
  if [ -z "$want" ] || printf '%s' "$out" | grep -qiF -- "${want#0x}"; then
    pass "$check" "${want:-reverted}"
  else
    fail "$check" "wanted ${want}, got: $(printf '%s' "$out" | cut -c1-240)"
  fi
}

# expect_revert <check> <selector-or-substring> <from> <to> <sig> [args...]
expect_revert() { _expect_revert send "$@"; }
expect_call_revert() { _expect_revert call "$@"; }

selector() { cast sig "$1"; }

# ---------------------------------------------------------------- vnet actors

# Addresses are derived per run so a rerun never collides with an account created by an earlier one.
if [ -n "${CT11_RUN_ID:-}" ]; then
  RUN_ID=$CT11_RUN_ID
elif [ -f "$STATE_DIR/run-id" ]; then
  RUN_ID=$(cat "$STATE_DIR/run-id")
else
  RUN_ID=$(date +%s)
  echo "$RUN_ID" >"$STATE_DIR/run-id"
fi

actor() { printf '0x%s\n' "$(cast keccak "ct11:$RUN_ID:$1" | cut -c 27-66)"; }

fund() { # fund <address> [usdc-amount]
  set_eth "$1"
  [ $# -gt 1 ] && set_usdc "$1" "$2"
  return 0
}

ensure_approve() { # ensure_approve <owner> <token> <spender>
  local cur
  cur=$(call "$2" 'allowance(address,address)(uint256)' "$1" "$3")
  [ "$cur" = "$MAX_UINT" ] && return 0
  send "$1" "$2" 'approve(address,uint256)' "$3" "$MAX_UINT" >/dev/null
}

# ---------------------------------------------------------------- stock accounts

token_status() { call "$STOCK_REGISTRY" 'tokenConfig(address)(uint8,uint8,address,address)' "$1"; }

ensure_listed() { # ensure_listed <token> <pool>
  [ "$(token_status "$1")" != "0" ] && return 0
  send "$DEPLOYER" "$STOCK_REGISTRY" 'listToken(address,(uint8,uint8,address,address))' \
    "$1" "(1,0,$2,0x0000000000000000000000000000000000000000)" >/dev/null
}

create_account() { # create_account <user> <entries-tuple-array> <cash-bps>
  local acct
  acct=$(call "$FACTORY" 'computeStrategyAddress(address)(address)' "$1")
  if [ "$(cast code "$acct" --rpc-url "$VNET" 2>>"$LOG")" = "0x" ]; then
    send "$1" "$FACTORY" 'createStrategyForUser(address,(address,uint16)[],uint16)' "$1" "$2" "$3" >/dev/null
  fi
  echo "$acct"
}

deposit_usdc() { # deposit_usdc <user> <account> <amount>
  ensure_approve "$1" "$USDC" "$2"
  send "$1" "$2" 'deposit(uint256)' "$3" >/dev/null
}

# Stock tokens cannot be minted, so an actor buys them on the stocks router and deposits them in kind.
buy_and_deposit() { # buy_and_deposit <user> <account> <token> <tick-spacing> <usdc-in>
  local before got
  before=$(call "$3" 'balanceOf(address)(uint256)' "$1")
  swap "$1" "$USDC" "$3" "$4" "$5" 0
  got=$(bn "$(call "$3" 'balanceOf(address)(uint256)' "$1") - $before")
  ensure_approve "$1" "$3" "$2"
  send "$1" "$2" 'depositToken(address,uint256)' "$3" "$got" >/dev/null
  echo "$got"
}

swap() { # swap <from> <tokenIn> <tokenOut> <tick-spacing> <amount-in> <sqrt-limit>
  ensure_approve "$1" "$2" "$ROUTER"
  send "$1" "$ROUTER" \
    'exactInputSingle((address,address,int24,address,uint256,uint256,uint256,uint160))(uint256)' \
    "($2,$3,$4,$1,$(bn "$(now_ts) + 3600"),$5,0,$6)" >/dev/null
}

# Non-indexed data of the first matching log, narrowed to one emitter when given.
event_data() { # event_data <receipt-json> <event-signature> [emitter]
  printf '%s' "$1" | jq -r --arg t "$(cast keccak "$2")" --arg a "$(echo "${3-}" | tr 'A-Z' 'a-z')" \
    '[.logs[] | select(.topics[0] == $t) | select($a == "" or (.address | ascii_downcase) == $a) | .data] | first // empty'
}

event_word() { # event_word <receipt-json> <event-signature> <word-index>
  local data
  data=$(event_data "$1" "$2")
  [ -n "$data" ] || { echo "event $2 not in receipt" >&2; return 1; }
  bn "0x${data:$((2 + $3 * 64)):64}"
}

# FeesPaid(credited, token, amount): the token is indexed, so the data is two flat words and the
# credited seconds are the slice of the period the payment covered, not the whole elapsed time.
FEES_PAID_SIG='FeesPaid(uint256,address,uint256)'

# An account's FeesPaid log, refused when its shape is not the two topics and two data words of the
# current event: a deployment still carrying the flat three-word event would otherwise decode silently.
fees_paid_log() { # fees_paid_log <receipt-json> <account>
  local log topics data
  log=$(printf '%s' "$1" | jq -c --arg t "$(cast keccak "$FEES_PAID_SIG")" --arg a "$(lc "$2")" \
    '[.logs[] | select(.topics[0] == $t) | select((.address | ascii_downcase) == $a)] | first // empty')
  [ -n "$log" ] || return 0

  topics=$(printf '%s' "$log" | jq -r '.topics | length')
  data=$(printf '%s' "$log" | jq -r '.data')

  if [ "$topics" != 2 ] || [ ${#data} != 130 ]; then
    echo "FeesPaid carries $topics topics and ${#data} chars of data, not the 2 and 130 this decoder reads" >&2
    return 1
  fi

  printf '%s\n' "$log"
}

# The token an account's fee payment was taken in, empty when it paid nothing in this transaction.
fees_paid_token() { # fees_paid_token <receipt-json> <account>
  local log
  log=$(fees_paid_log "$1" "$2") || return 1
  [ -n "$log" ] || return 0
  printf '0x%s\n' "$(printf '%s' "$log" | jq -r '.topics[1]' | cut -c27-66)"
}

# What an account's fee payment moved in one token; zero when it paid in another token or not at all.
fees_paid() { # fees_paid <receipt-json> <account> <token>
  local log data
  log=$(fees_paid_log "$1" "$2") || return 1
  [ -n "$log" ] || { echo 0; return 0; }
  [ "$(lc "$(fees_paid_token "$1" "$2")")" = "$(lc "$3")" ] || { echo 0; return 0; }
  data=$(printf '%s' "$log" | jq -r '.data')
  bn "0x${data:66:64}"
}

fees_paid_credited() { # fees_paid_credited <receipt-json> <account>
  local log data
  log=$(fees_paid_log "$1" "$2") || return 1
  [ -n "$log" ] || { echo 0; return 0; }
  data=$(printf '%s' "$log" | jq -r '.data')
  bn "0x${data:2:64}"
}

quote_out() { # quote_out <tokenIn> <tokenOut> <tick-spacing> <amount-in>
  call "$QUOTER" 'quoteExactInputSingle((address,address,uint256,int24,uint160))(uint256,uint160,uint32,uint256)' \
    "($1,$2,$4,$3,0)"
}

# getWeights covers every registry-listed token, in registry order, so a token's own row has to be
# looked up by address rather than assumed to be the first one. A token with no row is a fatal lookup
# failure: the empty index used to reach list_at and read row 0 there.
weights_index() { # weights_index <account> <token>
  local index
  index=$(callline 1 "$1" 'getWeights()(address[],uint256[],uint256[])' |
    tr -d '[]' | tr ',' '\n' | awk '{print tolower($1)}' |
    grep -n -x -- "$(lc "$2")" | cut -d: -f1 | awk '{print $1 - 1}') || true
  [ -n "$index" ] || { echo "weights_index: $2 has no row in getWeights() of account $1" >&2; return 1; }
  printf '%s\n' "$index"
}

expected_out() { call "$CHECKER" 'getExpectedOut(uint256,address,address)(uint256)' "$1" "$2" "$3"; }
# The fee is valued on the whole account in USDC, then converted to whichever token settles it.
fee_due() { call "$1" 'feeDue()(uint256)'; }
fee_due_in() { call "$1" 'feeDueIn(address)(uint256)' "$2"; }
fee_collector() { call "$1" 'feeRecipient()(address)'; }
# One document, and one hash, per (account, fee token); the fee token is the token an order buys.
app_data_hash() { call "$1" 'appDataHash(address)(bytes32)' "$2"; }
nav() { call "$1" 'getNAV()(uint256)'; }
sqrt_price() { calln 1 "$1" 'slot0()(uint160,int24,uint16,uint16,uint16,bool)'; }

# ---------------------------------------------------------------- cow orders

# The appData an order must carry is the account's document for the token it buys, since that is the
# token the post-hook takes the fee in.
mk_order() { # mk_order <sellToken> <buyToken> <account> <sellAmount> <buyAmount> <validTo> [appData]
  printf '(%s,%s,%s,%s,%s,%s,%s,0,%s,false,%s,%s)' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:-$(app_data_hash "$3" "$2")}" "$KIND_SELL" "$BALANCE_ERC20" "$BALANCE_ERC20"
}

order_digest() { call "$HELPER" "digest($ORDER_T,bytes32)(bytes32)" "$1" "$DOMAIN_SEPARATOR"; }

sign_digest() { cast wallet sign --no-hash --private-key "$ORDER_SIGNER_KEY" "$1" 2>>"$LOG"; }

# The bytes the account decodes in isValidSignature: the order and the backend signature over its digest.
order_encoded() { # order_encoded <order> <signature>
  call "$HELPER" "encodeOrder($ORDER_T,bytes)(bytes)" "$1" "$2"
}

check_signature() { # check_signature <account> <order>
  local digest
  digest=$(order_digest "$2")
  call "$1" 'isValidSignature(bytes32,bytes)(bytes4)' "$digest" "$(order_encoded "$2" "$(sign_digest "$digest")")"
}

settle_sell() { # settle_sell <account> <order> <sellAmount> <buyAmount>
  send "$DEPLOYER" "$HELPER" "settleSell(address,$ORDER_T,bytes,uint256,uint256)" \
    "$1" "$2" "$(sign_digest "$(order_digest "$2")")" "$4" "$3"
}

# ---------------------------------------------------------------- scenario frame

finish() {
  echo "$SCEN: $FAILURES failed check(s)"
  [ "$FAILURES" -eq 0 ] || exit 1
  exit 0
}

load_helper() {
  HELPER=$(jq -r '.setup.settlementHelper // empty' "$RESULTS" 2>/dev/null || true)
  [ -n "$HELPER" ] || HELPER=$(cat "$STATE_DIR/helper" 2>/dev/null || true)
  if [ -z "$HELPER" ] || [ "$(cast code "$HELPER" --rpc-url "$VNET" 2>>"$LOG")" = "0x" ]; then
    echo "settlement helper not deployed; run prepare.sh" >&2
    exit 1
  fi
  DOMAIN_SEPARATOR=$(call "$SETTLEMENT" 'domainSeparator()(bytes32)')
  MAX_DEVIATION=$(call "$STOCK_REGISTRY" 'maxDeviationBps()(uint16)')
}
