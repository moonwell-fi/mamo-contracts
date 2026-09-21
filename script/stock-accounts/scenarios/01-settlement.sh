#!/usr/bin/env bash
# CoW settlement: a priced buy-in is accepted and settles with the appData post-hook paying the
# management fee in the token the order buys, an order carrying the document of the wrong token is
# refused, an out-of-range mirror of the trade is refused, and two accounts on opposite sides of the
# pair net against each other, each paying its fee in the token it bought.
set -euo pipefail

SCEN=01-settlement
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_helper

DEPOSIT=2000000000
BUY_IN=1000000000
OUT_OF_RANGE=500000000
NET=150000000
DAY=86400
# The fee is valued on the account after the trade legs, and the buy-in trades half the account half a
# point inside the reference, so it lands a little under the feeDueIn read before the settle.
FEE_TOL_BPS=100

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

COLLECTOR=$(fee_collector "$ACCT_A")

# A day of fee is due by the time the first order settles.
increase_time "$DAY"

VALID_TO=$(bn "$(now_ts) + 900")
BUY_AMT=$(bn "$(expected_out "$BUY_IN" "$USDC" "$NVDA") * 995 // 1000")
ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT_A" "$BUY_IN" "$BUY_AMT" "$VALID_TO")

assert_eq "in-range buy order accepted by EIP-1271" "$(check_signature "$ACCT_A" "$ORDER")" "$MAGIC_VALUE"

# Same order carrying the document for the sell token: its hook would take the fee in USDC, which is
# not what this order buys, so the account refuses it.
WRONG_ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT_A" "$BUY_IN" "$BUY_AMT" "$VALID_TO" "$(app_data_hash "$ACCT_A" "$USDC")")
WRONG_DIGEST=$(order_digest "$WRONG_ORDER")

expect_call_revert "order carrying the sell token appData refused" "$(selector 'InvalidAppData()')" \
  "$DEPLOYER" "$ACCT_A" 'isValidSignature(bytes32,bytes)(bytes4)' \
  "$WRONG_DIGEST" "$(order_encoded "$WRONG_ORDER" "$(sign_digest "$WRONG_DIGEST")")"

FEE_DUE_NVDA=$(fee_due_in "$ACCT_A" "$NVDA")
COLLECTOR_USDC=$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")
COLLECTOR_NVDA=$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR")

RECEIPT=$(settle_sell "$ACCT_A" "$ORDER" "$BUY_IN" "$BUY_AMT")

CREDITED=$(fees_paid_credited "$RECEIPT" "$ACCT_A")
FEE_NVDA=$(fees_paid "$RECEIPT" "$ACCT_A" "$NVDA")

assert_eq "the buy-in paid its fee in the token it bought" "$(fees_paid_token "$RECEIPT" "$ACCT_A")" "$NVDA"
assert_gt "that fee is non-zero" "$FEE_NVDA" 0
assert_eq "collector NVDAc grew by exactly the fee paid" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_NVDA")" "$FEE_NVDA"
assert_eq "collector USDC untouched by the hook" \
  "$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")" "$COLLECTOR_USDC"
assert_approx "the fee paid is feeDueIn(NVDAc) read before the settle" \
  "$FEE_NVDA" "$FEE_DUE_NVDA" "$FEE_TOL_BPS"
record "$SCEN" "fee credited, seconds" 1 "$CREDITED"
record "$SCEN" "buy-in fee: paid vs feeDueIn(NVDAc)" 1 "$FEE_NVDA vs $FEE_DUE_NVDA"

NVDA_HELD=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_A")
assert_gt "account holds NVDAc after settlement" "$NVDA_HELD" 0
assert_eq "account kept the buy amount less its fee" "$(bn "$NVDA_HELD + $FEE_NVDA")" "$BUY_AMT"
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

BAD_DIGEST=$(order_digest "$BAD_ORDER")
BAD_SIG=$(sign_digest "$BAD_DIGEST")

expect_call_revert "out-of-range order refused by EIP-1271" "$(selector 'SellLeavesTokenBelowRange(address)')" \
  "$DEPLOYER" "$ACCT_A" 'isValidSignature(bytes32,bytes)(bytes4)' \
  "$BAD_DIGEST" "$(order_encoded "$BAD_ORDER" "$BAD_SIG")"

expect_revert "out-of-range order refused at settlement" "$(selector 'SellLeavesTokenBelowRange(address)')" \
  "$DEPLOYER" "$HELPER" "settleSell(address,$ORDER_T,bytes,uint256,uint256)" \
  "$ACCT_A" "$BAD_ORDER" "$BAD_SIG" "$BAD_BUY" "$OUT_OF_RANGE"

# The solver cannot author an order on its own: without the backend signature the account refuses it.
VALID_TO=$(bn "$(now_ts) + 900")
UNSIGNED_IN=100000000
UNSIGNED_BUY=$(bn "$(expected_out "$UNSIGNED_IN" "$USDC" "$NVDA") * 995 // 1000")
UNSIGNED_ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT_A" "$UNSIGNED_IN" "$UNSIGNED_BUY" "$VALID_TO")

expect_call_revert "unsigned order refused by EIP-1271" "$(selector 'InvalidBackendSignature()')" \
  "$DEPLOYER" "$ACCT_A" 'isValidSignature(bytes32,bytes)(bytes4)' \
  "$(order_digest "$UNSIGNED_ORDER")" "$(order_encoded "$UNSIGNED_ORDER" 0x)"

expect_revert "unsigned order refused at settlement" "$(selector 'InvalidBackendSignature()')" \
  "$DEPLOYER" "$HELPER" "settleSell(address,$ORDER_T,bytes,uint256,uint256)" \
  "$ACCT_A" "$UNSIGNED_ORDER" 0x "$UNSIGNED_BUY" "$UNSIGNED_IN"

assert_eq "the same order signed by the backend is accepted" "$(check_signature "$ACCT_A" "$UNSIGNED_ORDER")" "$MAGIC_VALUE"

# B holds NVDAc and wants cash, A wants the reverse: one settle, no pool, no liquidity cost.
USER_B=$(actor B)
ACCT_B=$(open_account "$USER_B" 2100000000 5000)
buy_and_deposit "$USER_B" "$ACCT_B" "$NVDA" 10 1000000000 >/dev/null
deposit_usdc "$USER_B" "$ACCT_B" 1000000000
send "$USER_B" "$ACCT_B" 'approveCowRelayer(address)' "$NVDA" >/dev/null
send "$USER_B" "$ACCT_B" 'approveCowRelayer(address)' "$USDC" >/dev/null

# Another day, so the netted settle carries a material fee hook for each side.
increase_time "$DAY"

VALID_TO=$(bn "$(now_ts) + 900")
NET_NVDA=$(bn "$(expected_out "$NET" "$USDC" "$NVDA") * 995 // 1000")
ORDER_A=$(mk_order "$USDC" "$NVDA" "$ACCT_A" "$NET" "$NET_NVDA" "$VALID_TO")
ORDER_B=$(mk_order "$NVDA" "$USDC" "$ACCT_B" "$NET_NVDA" "$NET" "$VALID_TO")

assert_eq "netting buy leg accepted" "$(check_signature "$ACCT_A" "$ORDER_A")" "$MAGIC_VALUE"
assert_eq "netting sell leg accepted" "$(check_signature "$ACCT_B" "$ORDER_B")" "$MAGIC_VALUE"

A_NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_A")
B_NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_B")
B_USDC_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT_B")
A_FEE_DUE_NVDA=$(fee_due_in "$ACCT_A" "$NVDA")
B_FEE_DUE_USDC=$(fee_due "$ACCT_B")
COLLECTOR_USDC=$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")
COLLECTOR_NVDA=$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR")

RECEIPT=$(send "$DEPLOYER" "$HELPER" "settleBatch(address,$ORDER_T,bytes,address,$ORDER_T,bytes)" \
  "$ACCT_A" "$ORDER_A" "$(sign_digest "$(order_digest "$ORDER_A")")" \
  "$ACCT_B" "$ORDER_B" "$(sign_digest "$(order_digest "$ORDER_B")")")

A_FEE_NVDA=$(fees_paid "$RECEIPT" "$ACCT_A" "$NVDA")
B_FEE_USDC=$(fees_paid "$RECEIPT" "$ACCT_B" "$USDC")

# Each side pays in what it bought, so one settle pays the collector in both tokens at once.
assert_eq "netted: A, buying NVDAc, paid in NVDAc" "$(fees_paid_token "$RECEIPT" "$ACCT_A")" "$NVDA"
assert_eq "netted: B, selling NVDAc for cash, paid in USDC" "$(fees_paid_token "$RECEIPT" "$ACCT_B")" "$USDC"
assert_eq "netted: A received the NVDAc B sold" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_A") - $A_NVDA_BEFORE + $A_FEE_NVDA")" "$NET_NVDA"
assert_eq "netted: B delivered exactly that NVDAc" \
  "$(bn "$B_NVDA_BEFORE - $(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT_B")")" "$NET_NVDA"
assert_eq "netted: B received the cash A sold" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT_B") - $B_USDC_BEFORE + $B_FEE_USDC")" "$NET"

assert_eq "collector NVDAc grew by A's fee alone" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_NVDA")" "$A_FEE_NVDA"
assert_eq "collector USDC grew by B's fee alone" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_USDC")" "$B_FEE_USDC"
assert_approx "A's fee is feeDueIn(NVDAc) read before the settle" "$A_FEE_NVDA" "$A_FEE_DUE_NVDA" "$FEE_TOL_BPS"
assert_approx "B's fee is feeDue read before the settle" "$B_FEE_USDC" "$B_FEE_DUE_USDC" "$FEE_TOL_BPS"
assert_gt "the netted settle paid a fee on both sides" "$(bn "min($A_FEE_NVDA, $B_FEE_USDC)")" 0
record "$SCEN" "netted fees: A NVDAc / B USDC" 1 \
  "$A_FEE_NVDA vs $A_FEE_DUE_NVDA | $B_FEE_USDC vs $B_FEE_DUE_USDC"

setup_note accountA "$ACCT_A"
setup_note accountB "$ACCT_B"
finish
