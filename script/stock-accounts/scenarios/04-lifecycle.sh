#!/usr/bin/env bash
# Account lifecycle: deterministic address, buy-in, basket change, cash withdrawal, a halted token
# leaving the account valuation but not the account, and a month of management fee.
set -euo pipefail

SCEN=04-lifecycle
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_helper

DEPOSIT=500000000
BUY_IN=250000000
CASH_WITHDRAW=100000000
MONTH=2592000
YEAR=31536000
HALTED=3
ACTIVE=1

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

deposit_usdc "$USER_C" "$ACCT" "$DEPOSIT"
send "$USER_C" "$ACCT" 'approveCowRelayer(address)' "$USDC" >/dev/null
send "$USER_C" "$ACCT" 'approveCowRelayer(address)' "$NVDA" >/dev/null

VALID_TO=$(bn "$(now_ts) + 900")
BUY_AMT=$(bn "$(expected_out "$BUY_IN" "$USDC" "$NVDA") * 995 // 1000")
ORDER=$(mk_order "$USDC" "$NVDA" "$ACCT" "$BUY_IN" "$BUY_AMT" "$VALID_TO")
settle_sell "$ACCT" "$ORDER" "$BUY_IN" "$BUY_AMT"
assert_eq "buy-in settled into the account" "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")" "$BUY_AMT"

send "$USER_C" "$ACCT" 'setBasket((address,uint16)[],uint16)' "[($NVDA,7000)]" 3000 >/dev/null
assert_eq "new NVDAc target read back" "$(list_at "$(callline 3 "$ACCT" 'getWeights()(address[],uint256[],uint256[])')" 0)" 7000
assert_eq "new cash target read back" "$(call "$ACCT" 'cashTargetBps()(uint16)')" 3000

NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")
send "$USER_C" "$ACCT" 'withdraw(uint256,uint16)' "$CASH_WITHDRAW" 100 >/dev/null
assert_eq "cash withdrawal left the position alone" "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")" "$NVDA_BEFORE"

# A halted token stops being valued but stays withdrawable in kind.
send "$DEPLOYER" "$STOCK_REGISTRY" 'setTokenStatus(address,uint8)' "$NVDA" "$HALTED" >/dev/null
CASH_ONLY=$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT") - $(call "$ACCT" 'feeOwed(address)(uint256)' "$USDC")")
assert_eq "halted token drops out of the NAV" "$(nav "$ACCT")" "$CASH_ONLY"
assert_eq "halted token is still held" "$(list_at "$(callline 1 "$ACCT" 'heldTokens()(address[])')" 0)" "$NVDA"

IN_KIND=$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT") - $(call "$ACCT" 'feeOwed(address)(uint256)' "$NVDA")")
OWNER_NVDA=$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C")
send "$USER_C" "$ACCT" 'withdrawToken(address,uint256)' "$NVDA" "$IN_KIND" >/dev/null
assert_eq "halted token withdrawn in kind" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$USER_C") - $OWNER_NVDA")" "$IN_KIND"

send "$DEPLOYER" "$STOCK_REGISTRY" 'setTokenStatus(address,uint8)' "$NVDA" "$ACTIVE" >/dev/null
assert_eq "admin restores the token to Active" "$(token_status "$NVDA")" "$ACTIVE"

# A month of management fee at the configured 100 bps a year.
FEE_BPS=$(call "$ACCT" 'managementFeeBps()(uint16)')
LAST_ACCRUAL=$(call "$ACCT" 'lastFeeAccrual()(uint256)')
FEE_BEFORE=$(call "$ACCT" 'feeOwed(address)(uint256)' "$USDC")
BALANCE=$(call "$USDC" 'balanceOf(address)(uint256)' "$ACCT")

increase_time "$MONTH"
send "$DEPLOYER" "$ACCT" 'accrueManagementFee()' >/dev/null

ELAPSED=$(bn "$(now_ts) - $LAST_ACCRUAL")
EXPECTED_FEE=$(bn "$FEE_BEFORE + ($BALANCE - $FEE_BEFORE) * $FEE_BPS * $ELAPSED // (10000 * $YEAR)")
assert_approx "a month of fee accrued on the cash balance" \
  "$(call "$ACCT" 'feeOwed(address)(uint256)' "$USDC")" "$EXPECTED_FEE" 100

RECIPIENT=$(call "$ACCT" 'feeRecipient()(address)')
RECIPIENT_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$RECIPIENT")
RECEIPT=$(send "$DEPLOYER" "$ACCT" 'collectFees(address)' "$USDC")
COLLECTED=$(event_word "$RECEIPT" 'FeesCollected(address,uint256)' 0)

assert_approx "collected fee matches the accrual" "$COLLECTED" "$EXPECTED_FEE" 100
assert_eq "fee recipient received it" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$RECIPIENT") - $RECIPIENT_BEFORE")" "$COLLECTED"
assert_eq "nothing left owed" "$(call "$ACCT" 'feeOwed(address)(uint256)' "$USDC")" 0

setup_note accountC "$ACCT"
finish
