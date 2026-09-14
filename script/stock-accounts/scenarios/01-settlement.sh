#!/usr/bin/env bash
# CoW settlement: a priced buy-in is accepted and settled, an out-of-range mirror of it is refused,
# and two accounts on opposite sides of the pair net against each other with no venue involved.
set -euo pipefail

SCEN=01-settlement
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_helper

DEPOSIT=2000000000
BUY_IN=1000000000
OUT_OF_RANGE=500000000
NET=150000000

open_account() { # open_account <user> <usdc-to-mint> <cash-bps>
  fund "$1" "$2"
  create_account "$1" "[($NVDA,$((10000 - $3)))]" "$3"
}

# A buys NVDAc with cash; the order is priced half a point inside the 1% account slippage cap.
USER_A=$(actor A)
ACCT_A=$(open_account "$USER_A" "$DEPOSIT" 5000)
deposit_usdc "$USER_A" "$ACCT_A" "$DEPOSIT"
send "$USER_A" "$ACCT_A" 'approveCowRelayer(address)' "$USDC" >/dev/null
send "$USER_A" "$ACCT_A" 'approveCowRelayer(address)' "$NVDA" >/dev/null
assert_eq "vault relayer allowance opened" "$(call "$USDC" 'allowance(address,address)(uint256)' "$ACCT_A" "$RELAYER")" "$MAX_UINT"

VALID_TO=$(bn "$(now_ts) + 900")
BUY_AMT=$(bn "$(expected_out "$BUY_IN" "$USDC" "$NVDA") * 995 // 1000")
ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT_A" "$BUY_IN" "$BUY_AMT" "$VALID_TO")

assert_eq "in-range buy order accepted by EIP-1271" "$(check_signature "$ACCT_A" "$ORDER")" "$MAGIC_VALUE"

settle_sell "$ACCT_A" "$ORDER" "$BUY_IN" "$BUY_AMT"

NVDA_HELD=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_A")
assert_gt "account holds NVDAc after settlement" "$NVDA_HELD" 0
assert_eq "account received exactly the buy amount" "$NVDA_HELD" "$BUY_AMT"
assert_approx "NAV preserved by the settlement" "$(nav "$ACCT_A")" "$DEPOSIT" 100

WEIGHTS=$(callline 2 "$ACCT_A" 'getWeights()(address[],uint256[],uint256[])')
TARGETS=$(callline 3 "$ACCT_A" 'getWeights()(address[],uint256[],uint256[])')
NVDA_W=$(list_at "$WEIGHTS" 0)
NVDA_T=$(list_at "$TARGETS" 0)
assert_gte "NVDAc weight within maxDeviationBps of target" \
  "$(bn "$MAX_DEVIATION - abs($NVDA_W - $NVDA_T)")" 0

# The mirror of the same trade overshoots: it would leave cash more than 10 points under its target.
VALID_TO=$(bn "$(now_ts) + 900")
BAD_BUY=$(bn "$(expected_out "$OUT_OF_RANGE" "$USDC" "$NVDA") * 995 // 1000")
BAD_ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT_A" "$OUT_OF_RANGE" "$BAD_BUY" "$VALID_TO")

expect_call_revert "out-of-range order refused by EIP-1271" "$(selector 'SellLeavesTokenBelowRange(address)')" \
  "$DEPLOYER" "$ACCT_A" 'isValidSignature(bytes32,bytes)(bytes4)' \
  "$(order_digest "$BAD_ORDER")" "$(order_encoded "$BAD_ORDER")"

expect_revert "out-of-range order refused at settlement" "$(selector 'SellLeavesTokenBelowRange(address)')" \
  "$DEPLOYER" "$HELPER" "settleSell(address,$ORDER_T,uint256,uint256)" \
  "$ACCT_A" "$BAD_ORDER" "$BAD_BUY" "$OUT_OF_RANGE"

# B holds NVDAc and wants cash, A wants the reverse: one settle, no pool, no liquidity cost.
USER_B=$(actor B)
ACCT_B=$(open_account "$USER_B" 2100000000 5000)
buy_and_deposit "$USER_B" "$ACCT_B" "$NVDA" 10 1000000000 >/dev/null
deposit_usdc "$USER_B" "$ACCT_B" 1000000000
send "$USER_B" "$ACCT_B" 'approveCowRelayer(address)' "$NVDA" >/dev/null
send "$USER_B" "$ACCT_B" 'approveCowRelayer(address)' "$USDC" >/dev/null

VALID_TO=$(bn "$(now_ts) + 900")
NET_NVDA=$(bn "$(expected_out "$NET" "$USDC" "$NVDA") * 995 // 1000")
ORDER_A=$(mk_order "$USDC" "$NVDA" "$ACCT_A" "$NET" "$NET_NVDA" "$VALID_TO")
ORDER_B=$(mk_order "$NVDA" "$USDC" "$ACCT_B" "$NET_NVDA" "$NET" "$VALID_TO")

assert_eq "netting buy leg accepted" "$(check_signature "$ACCT_A" "$ORDER_A")" "$MAGIC_VALUE"
assert_eq "netting sell leg accepted" "$(check_signature "$ACCT_B" "$ORDER_B")" "$MAGIC_VALUE"

A_NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_A")
B_NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_B")
B_USDC_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT_B")

send "$DEPLOYER" "$HELPER" "settleBatch(address,$ORDER_T,address,$ORDER_T)" \
  "$ACCT_A" "$ORDER_A" "$ACCT_B" "$ORDER_B" >/dev/null

assert_eq "netted: A received the NVDAc B sold" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_A") - $A_NVDA_BEFORE")" "$NET_NVDA"
assert_eq "netted: B delivered exactly that NVDAc" \
  "$(bn "$B_NVDA_BEFORE - $(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_B")")" "$NET_NVDA"
assert_eq "netted: B received the cash A sold" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT_B") - $B_USDC_BEFORE")" "$NET"

setup_note accountA "$ACCT_A"
setup_note accountB "$ACCT_B"
finish
