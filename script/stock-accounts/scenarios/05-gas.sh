#!/usr/bin/env bash
# Cost as a basket grows: the same sell order priced against accounts holding 2, 4 and 10 listed stock
# tokens, with every extra position adding one more pool TWAP read, and the fee post-hook measured on
# the widest of them against the gas limit the appData document declares.
# Reads here are arguments to an assert or to `send`: a failed read prints nothing, an assert compares
# that unequal and records a FAIL, and `send` will not build a transaction out of it. The reads that
# decide control flow are captured into a variable first, where the shell's own -e catches them.
# shellcheck disable=SC2312
set -euo pipefail

SCEN=05-gas
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_helper

WANTED=10
MIN_POOL_USDC=10000000000
CASH_LEG=500000000
STOCK_LEG=500000000
ORDER_SIZE=25000000
SIZES="2 4 10"
DAY=86400
# StockAccountStrategy.HOOK_GAS_LIMIT, the gas every appData document gives its post-hook.
HOOK_GAS_LIMIT=1000000

USDC_TOPIC=0x000000000000000000000000$(lc "${USDC#0x}")

pools_from_logs() {
  rpc eth_getLogs "[{\"address\":\"$CL_FACTORY\",\"topics\":[\"$POOL_CREATED_TOPIC\",\"$USDC_TOPIC\"],\"fromBlock\":\"0x0\",\"toBlock\":\"latest\"}]" |
    python3 -c '
import json, sys
for log in json.load(sys.stdin):
    token = "0x" + log["topics"][2][26:]
    if not token.startswith("0xb2"):
        continue
    spacing = int(log["topics"][3], 16)
    print(token, spacing - (1 << 256) if spacing >= (1 << 255) else spacing, "0x" + log["data"][26:])
'
}

# Deepest USDC pool per token, ranked by that depth.
deep_pools() {
  local pools=$STATE_DIR/pools.tsv balances=$STATE_DIR/pool-usdc.txt
  pools_from_logs >"$pools"
  awk -v usdc="$USDC" '{print usdc, "0x70a08231000000000000000000000000" substr($3, 3)}' "$pools" | batch_call >"$balances"
  paste "$pools" "$balances" | python3 -c '
import sys
best = {}
for line in sys.stdin:
    token, spacing, pool, balance = line.split()
    if int(balance, 16) < '"$MIN_POOL_USDC"':
        continue
    if token not in best or int(balance, 16) > best[token][2]:
        best[token] = (spacing, pool, int(balance, 16))
for token, (spacing, pool, balance) in sorted(best.items(), key=lambda kv: -kv[1][2]):
    print(token, spacing, pool, balance)
'
}

# Appends ok or old to every pool line: old means `observe` cannot reach back over the registry window.
annotate() { # annotate <pools-file>
  local data
  data=$(cast calldata 'observe(uint32[])' "[$TWAP_WINDOW,0]")
  awk -v data="$data" '{print $3, data}' "$1" |
    batch_call >"$STATE_DIR/pool-obs.txt"
  paste "$1" "$STATE_DIR/pool-obs.txt" | awk '{print $1, $2, $3, $4, ($5 == "0x" ? "old" : "ok")}'
}

# A pool whose history is shorter than the window becomes usable once the ring is grown and an
# observation is written; the wait that makes it count happens after every such pool is poked.
widen_window() { # widen_window <pool> <tick-spacing> <token>
  send "$DEPLOYER" "$1" 'increaseObservationCardinalityNext(uint16)' "$RING" >/dev/null
  swap "$DEPLOYER" "$USDC" "$3" "$2" 1000000 0
}

CANDIDATES=$STATE_DIR/candidates.tsv
DEEP=$STATE_DIR/deep.tsv
ANNOTATED=$STATE_DIR/annotated.tsv
TWAP_WINDOW=$(call "$STOCK_REGISTRY" 'twapWindow()(uint32)')
# The ring these pools are grown to, derived the way StockAccountsPoolReadiness derives it rather than
# pinned at a number that happens to cover today's window: one observation per Base block, times the
# headroom factor.
BLOCK_SECONDS=2
RING_HEADROOM=2
RING=$(((TWAP_WINDOW / BLOCK_SECONDS) * RING_HEADROOM))

deep_pools >"$DEEP"
annotate "$DEEP" >"$ANNOTATED"
if grep -q ' old$' "$ANNOTATED"; then
  while read -r token spacing pool _ state; do
    if [ "$state" = old ]; then widen_window "$pool" "$spacing" "$token"; fi
  done <"$ANNOTATED"
  increase_time $((TWAP_WINDOW + 20))
  annotate "$DEEP" >"$ANNOTATED"
fi
awk '$5 == "ok" {print $1, $2, $3, $4}' "$ANNOTATED" >"$CANDIDATES"

# NVDAc is the token the deploy config already listed, so it leads the basket.
{
  grep -i "^$NVDA " "$CANDIDATES" || true
  grep -iv "^$NVDA " "$CANDIDATES"
} | head -n "$WANTED" >"$CANDIDATES.picked"

TOKENS=()
SPACINGS=()
while read -r token spacing pool _; do
  ensure_listed "$token" "$pool"
  TOKENS+=("$token")
  SPACINGS+=("$spacing")
done <"$CANDIDATES.picked"

FOUND=${#TOKENS[@]}
POOLED=$(wc -l <"$CANDIDATES" | tr -d ' ')
if [ "$FOUND" -ge "$WANTED" ]; then
  pass "stock tokens listed with a usable USDC pool" "$FOUND of $WANTED wanted, $POOLED discovered"
else
  fail "stock tokens listed with a usable USDC pool" \
    "$FOUND of $WANTED; only $POOLED B20/USDC pools hold $MIN_POOL_USDC USDC and serve a 180s window"
fi
[ "$FOUND" -ge 2 ] || { echo "not enough usable pools to measure" >&2; finish; }

build_account() { # build_account <positions> -> account address
  local count=$1 bps=$((5000 / $1)) leg=$((STOCK_LEG / $1)) entries="[" index user account
  for index in $(seq 0 $((count - 1))); do
    entries="$entries(${TOKENS[$index]},$bps),"
  done
  entries="${entries%,}]"

  user=$(actor "G$count")
  fund "$user" $((CASH_LEG + STOCK_LEG))
  account=$(create_account "$user" "$entries" 5000)
  deposit_usdc "$user" "$account" "$CASH_LEG"
  for index in $(seq 0 $((count - 1))); do
    buy_and_deposit "$user" "$account" "${TOKENS[$index]}" "${SPACINGS[$index]}" "$leg" >/dev/null
  done
  send "$user" "$account" 'approveCowRelayer(address)' "$USDC" >/dev/null
  echo "$account"
}

for SIZE in $SIZES; do
  [ "$SIZE" -le "$FOUND" ] || continue
  ACCT=$(build_account "$SIZE")
  VALID_TO=$(bn "$(now_ts) + 900")
  BUY_AMT=$(bn "$(expected_out "$ORDER_SIZE" "$USDC" "${TOKENS[0]}") * 995 // 1000")
  ORDER=$(mk_order "$USDC" "${TOKENS[0]}" "$ACCT" "$ORDER_SIZE" "$BUY_AMT" "$VALID_TO")

  assert_eq "order valid against a $SIZE-position account" "$(check_signature "$ACCT" "$ORDER")" "$MAGIC_VALUE"
  DIGEST=$(order_digest "$ORDER")
  GAS=$(estimate_gas "$DEPLOYER" "$ACCT" 'isValidSignature(bytes32,bytes)' \
    "$DIGEST" "$(order_encoded "$ORDER" "$(sign_digest "$DIGEST")")")
  if [ -n "$GAS" ]; then
    pass "isValidSignature gas with $SIZE positions" "$GAS"
  else
    fail "isValidSignature gas with $SIZE positions" "estimate failed"
  fi
  setup_note "gasAccount$SIZE" "$ACCT"
  WIDEST=$ACCT
  WIDEST_SIZE=$SIZE
done

# The fee is a post-hook inside the settlement, so paying it has to fit in HOOK_GAS_LIMIT on the widest
# basket, where every position is one more TWAP read in the NAV the fee is valued on.
increase_time "$DAY"
GAS=$(estimate_gas "$DEPLOYER" "$WIDEST" 'payFees(address)' "${TOKENS[0]}")
if [ -n "$GAS" ]; then
  assert_gt "payFees with $WIDEST_SIZE positions fits the hook gas limit" "$HOOK_GAS_LIMIT" "$GAS"
  record "$SCEN" "payFees gas with $WIDEST_SIZE positions" 1 "$GAS"
else
  fail "payFees gas with $WIDEST_SIZE positions" "estimate failed"
fi

finish
