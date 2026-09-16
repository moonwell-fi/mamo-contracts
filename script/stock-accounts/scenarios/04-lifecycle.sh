#!/usr/bin/env bash
# Account lifecycle: deterministic address, buy-in, basket change, cash withdrawal, a halted token
# leaving the account valuation but not the account, and the two ways the management fee gets paid
# outside a settlement -- the withdrawal backstop and a plain poke on an idle account.
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
YEAR=31536000
HALTED=3
ACTIVE=1

FEE_BPS=$(mgmt_fee_bps)
expected_fee() { bn "$1 * $FEE_BPS * $2 // (10000 * $YEAR)"; }

USER_C=$(actor C)
fund "$USER_C" "$DEPOSIT"

PREDICTED=$(call "$FACTORY" 'computeStrategyAddress(address)(address)' "$USER_C")
if [ "$(cast code "$PREDICTED" --rpc-url "$VNET" 2>>"$LOG")" = "0x" ]; then
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
assert_eq "buy-in settled into the account" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT") + $(fees_paid "$RECEIPT" "$ACCT" "$NVDA")")" "$BUY_AMT"

send "$USER_C" "$ACCT" 'setBasket((address,uint16)[],uint16)' "[($NVDA,7000)]" 3000 >/dev/null
assert_eq "new NVDAc target read back" "$(list_at "$(callline 3 "$ACCT" 'getWeights()(address[],uint256[],uint256[])')" 0)" 7000
assert_eq "new cash target read back" "$(call "$ACCT" 'cashTargetBps()(uint16)')" 3000

NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")
RECEIPT=$(send "$USER_C" "$ACCT" 'withdraw(uint256,uint16)' "$CASH_WITHDRAW" 100)
assert_eq "cash withdrawal sold no NVDAc" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT") + $(fees_paid "$RECEIPT" "$ACCT" "$NVDA")")" "$NVDA_BEFORE"

# A halted token stops being valued and stops accruing a fee, but stays withdrawable in kind.
send "$DEPLOYER" "$STOCK_REGISTRY" 'setTokenStatus(address,uint8)' "$NVDA" "$HALTED" >/dev/null
assert_eq "halted token drops out of the NAV" "$(nav "$ACCT")" "$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT")"
assert_eq "no fee is due on a halted token" "$(fee_due "$ACCT" "$NVDA")" 0
assert_eq "halted token is still held" "$(list_at "$(callline 1 "$ACCT" 'heldTokens()(address[])')" 0)" "$NVDA"

IN_KIND=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")
OWNER_NVDA=$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C")
send "$USER_C" "$ACCT" 'withdrawToken(address,uint256)' "$NVDA" "$IN_KIND" >/dev/null
assert_eq "halted token withdrawn in kind" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C") - $OWNER_NVDA")" "$IN_KIND"

send "$DEPLOYER" "$STOCK_REGISTRY" 'setTokenStatus(address,uint8)' "$NVDA" "$ACTIVE" >/dev/null
assert_eq "admin restores the token to Active" "$(token_status "$NVDA")" "$ACTIVE"

# A month of fee on an account that never traded: the next withdrawal pays it before paying the owner.
increase_time "$MONTH"

BALANCE=$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT")
FEE_DUE=$(fee_due "$ACCT" "$USDC")
COLLECTOR_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")
OWNER_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$USER_C")

RECEIPT=$(send "$USER_C" "$ACCT" 'withdraw(uint256,uint16)' "$FEE_WITHDRAW" 100)
PAID=$(fees_paid "$RECEIPT" "$ACCT" "$USDC")
ELAPSED=$(fees_paid_elapsed "$RECEIPT" "$ACCT")

assert_eq "the withdrawal paid the month of fee in the same tx" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_BEFORE")" "$PAID"
# Fees come out before the owner is paid, so the month is charged on the pre-withdrawal balance.
assert_eq "the fee is the balance x rate x elapsed" "$PAID" "$(expected_fee "$BALANCE" "$ELAPSED")"
assert_approx "the fee matches feeDue read before the withdrawal" "$PAID" "$FEE_DUE" 10
assert_eq "the owner still received what was asked" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$USER_C") - $OWNER_BEFORE")" "$FEE_WITHDRAW"
record "$SCEN" "month of fee: paid vs feeDue" 1 "$PAID vs $FEE_DUE over ${ELAPSED}s"

# An account nobody touches is poked instead, which is how the backend settles an idle one.
increase_time "$DAY"

BALANCE=$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT")
FEE_DUE=$(fee_due "$ACCT" "$USDC")
COLLECTOR_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR")

RECEIPT=$(send "$DEPLOYER" "$ACCT" 'payFees()')
PAID=$(fees_paid "$RECEIPT" "$ACCT" "$USDC")
ELAPSED=$(fees_paid_elapsed "$RECEIPT" "$ACCT")

assert_eq "the poke paid the day of fee" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$COLLECTOR") - $COLLECTOR_BEFORE")" "$PAID"
assert_eq "the poked fee is the balance x rate x elapsed" "$PAID" "$(expected_fee "$BALANCE" "$ELAPSED")"
assert_approx "the poked fee matches feeDue read before it" "$PAID" "$FEE_DUE" 10
assert_eq "lastFeePaid moved to the poke" "$(call "$ACCT" 'lastFeePaid()(uint64)')" "$(now_ts)"
assert_eq "nothing is due straight after" "$(fee_due "$ACCT" "$USDC")" 0

setup_note accountC "$ACCT"
finish
