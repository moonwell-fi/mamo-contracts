#!/usr/bin/env bash
# Withdrawals: idle cash is paid without touching a pool, a shortfall sells exactly what the preview
# said, and the TWAP floor blocks a sale into a spot price the average has not absorbed.
set -euo pipefail

SCEN=02-withdrawals
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_helper

SLIPPAGE=100
IDLE=1000000000
STOCK_LEG=1060000000
SMALL_WITHDRAW=300000000
BIG_WITHDRAW=1500000000
GAP_BPS=500

USER_D=$(actor D)
fund "$USER_D" $((IDLE + STOCK_LEG))
ACCT=$(create_account "$USER_D" "[($NVDA,5000)]" 5000)
buy_and_deposit "$USER_D" "$ACCT" "$NVDA" 10 "$STOCK_LEG" >/dev/null
deposit_usdc "$USER_D" "$ACCT" "$IDLE"

# Idle cash covers it, so no position is touched beyond the fee every withdrawal pays first.
NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")
RECEIPT=$(send "$USER_D" "$ACCT" 'withdraw(uint256,uint16)' "$SMALL_WITHDRAW" "$SLIPPAGE")

assert_eq "cash-only withdrawal sells no NVDAc" \
  "$(bn "$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT") + $(fees_paid "$RECEIPT" "$ACCT" "$NVDA")")" "$NVDA_BEFORE"
assert_eq "Withdraw event reports the cash paid" "$(event_word "$RECEIPT" 'Withdraw(uint256,uint256)' 0)" "$SMALL_WITHDRAW"
assert_eq "Withdraw event reports zero sold" "$(event_word "$RECEIPT" 'Withdraw(uint256,uint256)' 1)" 0

# Shortfall: the preview is the plan the withdrawal then executes.
PREVIEW=$(callraw "$ACCT" 'previewWithdraw(uint256,uint16)(address[],uint256[],uint256,uint256)' "$BIG_WITHDRAW" "$SLIPPAGE")
PREVIEW_TOKEN=$(list_at "$(printf '%s' "$PREVIEW" | sed -n 1p)" 0)
PREVIEW_AMOUNT=$(list_at "$(printf '%s' "$PREVIEW" | sed -n 2p)" 0)
PREVIEW_MIN=$(printf '%s' "$PREVIEW" | sed -n 4p | awk '{print $1}')

assert_eq "preview plans a NVDAc sale" "$PREVIEW_TOKEN" "$NVDA"
assert_gt "preview floors the proceeds" "$PREVIEW_MIN" 0

NVDA_BEFORE=$(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT")
OWNER_BEFORE=$(call "$USDC" 'balanceOf(address)(uint256)' "$USER_D")
RECEIPT=$(send "$USER_D" "$ACCT" 'withdraw(uint256,uint16)' "$BIG_WITHDRAW" "$SLIPPAGE")

assert_approx "sold amount matches the preview" \
  "$(bn "$NVDA_BEFORE - $(call "$NVDA" 'balanceOf(address)(uint256)' "$ACCT") - $(fees_paid "$RECEIPT" "$ACCT" "$NVDA")")" \
  "$PREVIEW_AMOUNT" 10
assert_eq "owner received exactly what was asked" \
  "$(bn "$(call "$USDC" 'balanceOf(address)(uint256)' "$USER_D") - $OWNER_BEFORE")" "$BIG_WITHDRAW"

# Open a gap between the reference and spot: spike the pool, let the 180s average absorb the spike,
# then put the spot price back. The average is now ~5% above what the pool would actually pay.
fund "$DEPLOYER" 100000000000000
PRE_SQRT=$(sqrt_price "$NVDA_POOL")
SPIKE_LIMIT=$(bn "$PRE_SQRT / (1 + $GAP_BPS / 10000) ** 0.5")
swap "$DEPLOYER" "$USDC" "$NVDA" 10 50000000000000 "$SPIKE_LIMIT"
increase_time 200
swap "$DEPLOYER" "$NVDA" "$USDC" 10 "$(call "$NVDA" 'balanceOf(address)(uint256)' "$DEPLOYER")" "$PRE_SQRT"

REFERENCE=$(expected_out 100000000 "$NVDA" "$USDC")
SPOT=$(quote_out "$NVDA" "$USDC" 10 100000000)
assert_gt "reference sits above spot by more than the slippage cap" \
  "$(bn "($REFERENCE - $SPOT) * 10000 // $SPOT")" "$SLIPPAGE"

expect_revert "withdrawal refuses to sell below the TWAP floor" 'Too little received' \
  "$USER_D" "$ACCT" 'withdraw(uint256,uint16)' 100000000 "$SLIPPAGE"

setup_note accountD "$ACCT"
finish
