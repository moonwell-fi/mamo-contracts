#!/usr/bin/env bash
# Price spike: once the 180s average has absorbed a 3x move the account is far overweight, the
# de-risking sell is accepted and settles, buying more is refused, and the unwind restores both.
set -euo pipefail

SCEN=03-spike
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_helper

CASH_LEG=1000000000
STOCK_LEG=1000000000
SETTLE_VALUE=25000000
BUY_BACK=100000000
ONE_NVDA=100000000
TARGET_MULTIPLE=3

# Start from a settled average: the scenario before this one leaves the window still absorbing a move.
fund "$DEPLOYER" 100000000000000
increase_time 200
swap "$DEPLOYER" "$USDC" "$NVDA" 10 1000000 0

USER_E=$(actor E)
fund "$USER_E" $((CASH_LEG + STOCK_LEG))
ACCT=$(create_account "$USER_E" "[($NVDA,5000)]" 5000)
buy_and_deposit "$USER_E" "$ACCT" "$NVDA" 10 "$STOCK_LEG" >/dev/null
deposit_usdc "$USER_E" "$ACCT" "$CASH_LEG"
send "$USER_E" "$ACCT" 'approveCowRelayer(address)' "$NVDA" >/dev/null
send "$USER_E" "$ACCT" 'approveCowRelayer(address)' "$USDC" >/dev/null

PRE_SQRT=$(sqrt_price "$NVDA_POOL")
PRE_REF=$(expected_out "$ONE_NVDA" "$NVDA" "$USDC")

# Walk the pool up until the average, not just the spot, is past the target multiple.
push() { # push <multiple-of-current-spot>
  set_usdc "$DEPLOYER" 100000000000000
  swap "$DEPLOYER" "$USDC" "$NVDA" 10 50000000000000 "$(bn "$(sqrt_price "$NVDA_POOL") / $1 ** 0.5")"
  increase_time 200
  swap "$DEPLOYER" "$USDC" "$NVDA" 10 1000000 0
}

push 4.5
for _ in 1 2 3; do
  REF=$(expected_out "$ONE_NVDA" "$NVDA" "$USDC")
  [ "$(bb "$REF >= $TARGET_MULTIPLE * $PRE_REF")" = 1 ] && break
  push 2.2
done

REF=$(expected_out "$ONE_NVDA" "$NVDA" "$USDC")
assert_gte "reference price is at least 3x the pre-spike average" \
  "$(bn "$REF * 100 // $PRE_REF")" $((TARGET_MULTIPLE * 100))

WEIGHTS=$(callline 2 "$ACCT" 'getWeights()(address[],uint256[],uint256[])')
TARGETS=$(callline 3 "$ACCT" 'getWeights()(address[],uint256[],uint256[])')
NVDA_I=$(weights_index "$ACCT" "$NVDA")
NVDA_W=$(list_at "$WEIGHTS" "$NVDA_I")
assert_gt "NVDAc far above its band after the spike" "$NVDA_W" \
  "$(bn "$(list_at "$TARGETS" "$NVDA_I") + $MAX_DEVIATION")"

# Selling into the spike is exactly what the band wants, so the account signs it.
SELL_NVDA=$(bn "$SETTLE_VALUE * $ONE_NVDA // $REF")
SELL_USDC=$(bn "$(expected_out "$SELL_NVDA" "$NVDA" "$USDC") * 995 // 1000")
VALID_TO=$(bn "$(now_ts) + 900")
SELL_ORDER=$(mk_order "$NVDA" "$USDC" "$ACCT" "$SELL_NVDA" "$SELL_USDC" "$VALID_TO")

assert_eq "de-risking sell accepted at the spiked reference" \
  "$(check_signature "$ACCT" "$SELL_ORDER")" "$MAGIC_VALUE"
record "$SCEN" "spiked reference, USDC per NVDAc" 1 "$REF"

# Buying more is refused. Both range rules are violated, and for a two-asset account they are the
# same condition seen from either leg, so the sell-side rule is the one that fires first.
BUY_NVDA=$(bn "$(expected_out "$SETTLE_VALUE" "$USDC" "$NVDA") * 995 // 1000")
BUY_ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT" "$SETTLE_VALUE" "$BUY_NVDA" "$VALID_TO")
BUY_DIGEST=$(order_digest "$BUY_ORDER")
expect_call_revert "buying more NVDAc refused while overweight" "$(selector 'SellLeavesTokenBelowRange(address)')" \
  "$DEPLOYER" "$ACCT" 'isValidSignature(bytes32,bytes)(bytes4)' \
  "$BUY_DIGEST" "$(order_encoded "$BUY_ORDER" "$(sign_digest "$BUY_DIGEST")")"

USDC_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT")
RECEIPT=$(settle_sell "$ACCT" "$SELL_ORDER" "$SELL_NVDA" "$SELL_USDC")
FEE_USDC=$(fees_paid "$RECEIPT" "$ACCT" "$USDC")
assert_eq "de-risking sell settled" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT") - $USDC_BEFORE + $FEE_USDC")" \
  "$SELL_USDC"

# Unwind the spike and let the average come back down with it.
swap "$DEPLOYER" "$NVDA" "$USDC" 10 "$(call "$NVDA" 'balanceOf(address)(uint256)' "$DEPLOYER")" "$PRE_SQRT"
increase_time 200
swap "$DEPLOYER" "$USDC" "$NVDA" 10 1000000 0

assert_approx "reference back at the pre-spike level" "$(expected_out "$ONE_NVDA" "$NVDA" "$USDC")" "$PRE_REF" 200

VALID_TO=$(bn "$(now_ts) + 900")
BACK_NVDA=$(bn "$(expected_out "$BUY_BACK" "$USDC" "$NVDA") * 995 // 1000")
BACK_ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT" "$BUY_BACK" "$BACK_NVDA" "$VALID_TO")
assert_eq "buy-back accepted once the spike is gone" "$(check_signature "$ACCT" "$BACK_ORDER")" "$MAGIC_VALUE"

setup_note accountE "$ACCT"
finish
