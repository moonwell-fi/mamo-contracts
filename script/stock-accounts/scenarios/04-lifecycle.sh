#!/usr/bin/env bash
# Account lifecycle: deterministic address, buy-in, basket change, and every way the management fee is
# paid outside a settlement -- a cash withdrawal paying in USDC, an in-kind withdrawal paying in the
# token it sends, a poke on an idle account, and a halted token that can no longer settle the fee but
# is still withdrawable, the fee then coming out of the cash instead.
# Reads here are arguments to an assert or to `send`: a failed read prints nothing, the asserts refuse
# an empty operand outright (see lib.sh), so it is recorded as a FAIL and cannot pass, and `send` will
# not build a transaction out of one. Reads that decide control flow are captured into a variable
# first, where the shell's own -e catches them.
# shellcheck disable=SC2312
set -euo pipefail

SCEN=04-lifecycle
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_helper

DEPOSIT=500000000
BUY_IN=250000000
CASH_WITHDRAW=100000000
FEE_WITHDRAW=10000000
MONTH=2592000
DAY=86400
HALTED=3
ACTIVE=1
# All that separates a feeDue read from what the next transaction pays: a few seconds of accrual, and
# any move in the pool average behind the conversion.
FEE_TOL_BPS=10

USER_C=$(actor C)
fund "$USER_C" "$DEPOSIT"

PREDICTED=$(call "$FACTORY" 'computeStrategyAddress(address)(address)' "$USER_C")
# Captured, not compared inline: an empty answer from a failed call is not "0x", so the account would
# never be created and every check below would run against an address with nothing behind it.
PREDICTED_CODE=$(cast code "$PREDICTED" --rpc-url "$VNET" 2>>"$LOG") || true
[ -n "$PREDICTED_CODE" ] || { echo "cannot read the code at $PREDICTED (see $LOG)" >&2; exit 1; }
if [ "$PREDICTED_CODE" = "0x" ]; then
  RECEIPT=$(send "$USER_C" "$FACTORY" 'createStrategyForUser(address,(address,uint16)[],uint16)' \
    "$USER_C" "[($NVDA,5000)]" 5000)
  CREATED=0x$(printf '%s' "$RECEIPT" |
    jq -r --arg t "$(cast keccak 'StrategyCreated(address,address)')" \
      '[.logs[] | select(.topics[0] == $t) | .topics[2]] | first' | cut -c 27-66)
  assert_eq "created account is the predicted address" "$CREATED" "$PREDICTED"
fi
ACCT=$PREDICTED
COLLECTOR=$(fee_collector "$ACCT")

deposit_usdc "$USER_C" "$ACCT" "$DEPOSIT"
send "$USER_C" "$ACCT" 'approveCowRelayer(address)' "$USDC" >/dev/null
send "$USER_C" "$ACCT" 'approveCowRelayer(address)' "$NVDA" >/dev/null

VALID_TO=$(bn "$(now_ts) + 900")
BUY_AMT=$(bn "$(expected_out "$BUY_IN" "$USDC" "$NVDA") * 995 // 1000")
ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT" "$BUY_IN" "$BUY_AMT" "$VALID_TO")
RECEIPT=$(settle_sell "$ACCT" "$ORDER" "$BUY_IN" "$BUY_AMT")
BUY_FEE=$(fees_paid "$RECEIPT" "$ACCT" "$NVDA")
assert_eq "buy-in settled into the account" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT") + $BUY_FEE")" "$BUY_AMT"

send "$USER_C" "$ACCT" 'setBasket((address,uint16)[],uint16)' "[($NVDA,7000)]" 3000 >/dev/null
NVDA_I=$(weights_index "$ACCT" "$NVDA")
assert_eq "new NVDAc target read back" \
  "$(list_at "$(callline 3 "$ACCT" 'getWeights()(address[],uint256[],uint256[])')" "$NVDA_I")" 7000
assert_eq "new cash target read back" "$(call "$ACCT" 'cashTargetBps()(uint16)')" 3000

NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")
send "$USER_C" "$ACCT" 'withdraw(uint256,uint16)' "$CASH_WITHDRAW" 100 >/dev/null
assert_eq "cash withdrawal sold no NVDAc" "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")" "$NVDA_BEFORE"

# A month of fee on an account that never traded: `withdraw` sells nothing and pays it in USDC.
increase_time "$MONTH"

FEE_DUE=$(fee_due "$ACCT")
COLLECTOR_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")
OWNER_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$USER_C")
NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")

RECEIPT=$(send "$USER_C" "$ACCT" 'withdraw(uint256,uint16)' "$FEE_WITHDRAW" 100)
PAID=$(fees_paid "$RECEIPT" "$ACCT" "$USDC")
CREDITED=$(fees_paid_credited "$RECEIPT" "$ACCT")

assert_eq "the withdrawal paid its fee in USDC" "$(fees_paid_token "$RECEIPT" "$ACCT")" "$USDC"
assert_eq "collector USDC grew by exactly that fee" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_BEFORE")" "$PAID"
assert_approx "the fee is feeDue read before the withdrawal" "$PAID" "$FEE_DUE" "$FEE_TOL_BPS"
assert_eq "the withdrawal fee left the position alone" "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")" "$NVDA_BEFORE"
assert_eq "the owner still received what was asked" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$USER_C") - $OWNER_BEFORE")" "$FEE_WITHDRAW"
record "$SCEN" "month of fee: paid vs feeDue" 1 "$PAID vs $FEE_DUE over ${CREDITED}s"

# An in-kind withdrawal pays in the token it sends, not in cash.
increase_time "$DAY"

PART=$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT") // 2")
FEE_DUE_NVDA=$(fee_due_in "$ACCT" "$NVDA")
COLLECTOR_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR")
COLLECTOR_USDC_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")
OWNER_NVDA=$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C")

RECEIPT=$(send "$USER_C" "$ACCT" 'withdrawToken(address,uint256)' "$NVDA" "$PART")
PAID_NVDA=$(fees_paid "$RECEIPT" "$ACCT" "$NVDA")

assert_eq "withdrawToken paid its fee in NVDAc" "$(fees_paid_token "$RECEIPT" "$ACCT")" "$NVDA"
assert_eq "collector NVDAc grew by exactly that fee" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_BEFORE")" "$PAID_NVDA"
assert_eq "collector USDC untouched by an in-kind withdrawal" \
  "$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")" "$COLLECTOR_USDC_BEFORE"
assert_approx "that fee is feeDueIn(NVDAc) read before it" "$PAID_NVDA" "$FEE_DUE_NVDA" "$FEE_TOL_BPS"
assert_eq "the owner received the tokens asked for" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C") - $OWNER_NVDA")" "$PART"
record "$SCEN" "in-kind fee: paid vs feeDueIn(NVDAc)" 1 "$PAID_NVDA vs $FEE_DUE_NVDA"

# An account nobody touches is poked instead, which is how the backend settles an idle one. The poke
# names the token, so the backend can take it out of a position rather than out of the cash.
increase_time "$DAY"

FEE_DUE_NVDA=$(fee_due_in "$ACCT" "$NVDA")
COLLECTOR_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR")

RECEIPT=$(send "$DEPLOYER" "$ACCT" 'payFees(address)' "$NVDA")
PAID_NVDA=$(fees_paid "$RECEIPT" "$ACCT" "$NVDA")

assert_eq "the poke paid the day of fee in NVDAc" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_BEFORE")" "$PAID_NVDA"
assert_approx "the poked fee is feeDueIn(NVDAc) read before it" "$PAID_NVDA" "$FEE_DUE_NVDA" "$FEE_TOL_BPS"
# Both sides captured: two failed reads would otherwise compare empty against empty and pass.
LAST_FEE_PAID=$(call "$ACCT" 'lastFeePaid()(uint64)')
POKE_TS=$(now_ts)
assert_eq "lastFeePaid moved to the poke" "$LAST_FEE_PAID" "$POKE_TS"
assert_eq "nothing is due straight after" "$(fee_due "$ACCT")" 0
record "$SCEN" "poked fee: paid vs feeDueIn(NVDAc)" 1 "$PAID_NVDA vs $FEE_DUE_NVDA"

# A halted token stops being valued and can no longer settle the fee, but stays withdrawable in kind.
send "$DEPLOYER" "$STOCK_REGISTRY" 'setTokenStatus(address,uint8)' "$NVDA" "$HALTED" >/dev/null
increase_time "$DAY"

# Both sides captured, for the same reason: empty NAV against empty balance would read as agreement.
HALTED_NAV=$(nav "$ACCT")
HALTED_CASH=$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT")
assert_eq "halted token drops out of the NAV" "$HALTED_NAV" "$HALTED_CASH"
assert_eq "halted token is still held" "$(list_at "$(callline 1 "$ACCT" 'heldTokens()(address[])')" 0)" "$NVDA"
expect_revert "the fee cannot be taken in a halted token" "$(selector 'FeeTokenNotAllowed(address)')" \
  "$DEPLOYER" "$ACCT" 'payFees(address)' "$NVDA"

IN_KIND=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")
OWNER_NVDA=$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C")
COLLECTOR_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")
FEE_DUE=$(fee_due "$ACCT")

RECEIPT=$(send "$USER_C" "$ACCT" 'withdrawToken(address,uint256)' "$NVDA" "$IN_KIND")
PAID=$(fees_paid "$RECEIPT" "$ACCT" "$USDC")

assert_eq "halted token withdrawn in kind" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C") - $OWNER_NVDA")" "$IN_KIND"
assert_eq "its fee fell back to the cash" "$(fees_paid_token "$RECEIPT" "$ACCT")" "$USDC"
assert_eq "collector USDC grew by exactly that fee" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_BEFORE")" "$PAID"
assert_approx "the fallback fee is feeDue read before it" "$PAID" "$FEE_DUE" "$FEE_TOL_BPS"

send "$DEPLOYER" "$STOCK_REGISTRY" 'setTokenStatus(address,uint8)' "$NVDA" "$ACTIVE" >/dev/null
assert_eq "admin restores the token to Active" "$(token_status "$NVDA")" "$ACTIVE"

setup_note accountC "$ACCT"
finish
