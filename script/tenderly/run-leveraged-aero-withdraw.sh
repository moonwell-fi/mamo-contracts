#!/usr/bin/env bash
# =================================================================================================
# run-leveraged-aero-withdraw.sh — withdraw-flow EDGE matrix for MamoLeveragedAeroStrategy
# =================================================================================================
# The account harness (run-leveraged-aero-account.sh) already proves the HAPPY path: deposit,
# fast withdraw, and request → fulfill → claim. This runs the states a frontend actually has to
# RENDER, which the happy path never reaches — the reverts, the waiting states, and the numbers
# that drift between quote and signature.
#
# Every scenario runs from the same funded baseline behind an evm_snapshot and reverts after, so
# the matrix is order-independent and leaves the shared vnet as it found it.
#
# Output: a findings JSON (see FINDINGS at the bottom) with the MEASURED values — revert strings,
# observed quote drift, request-struct transitions — so the frontend builds against measurements
# rather than against prose. That file is the input to the FE-facing artifact.
#
# ALWAYS reuses the persistent vnet: the pooled layer (LeveragedAeroVault + strategy clone) and
# the account layer exist only there. Run AFTER `make tenderly-leveraged-aero-account`, which
# deploys the factory this script reads from leveraged-aero-vnet.json.
#
# Time warping is safe on this instance ONLY because the 5 venue Chainlink feeds are FreshFeed
# mocks (updatedAt tracks block.timestamp) — see `feeds` in leveraged-aero-vnet.json. Scenario 4
# warps 2 days to open the FULFILL_WINDOW; on an instance without FreshFeed that would brick
# every priced path with StaleOracle.
#
# Usage:  ./script/tenderly/run-leveraged-aero-withdraw.sh
#         make tenderly-leveraged-aero-withdraw
# =================================================================================================
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$ROOT/script/tenderly/harness-results-leveraged-aero-withdraw.log}"
: > "$RESULTS"

HARNESS_SLUG="leveraged-aero-withdraw"
HARNESS_DISPLAY="MamoLeveragedAeroStrategy withdraw-edge matrix"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/market.sh
source "$SCRIPT_DIR/lib/market.sh"

_CFG="$ROOT/script/tenderly/leveraged-aero-vnet.json"
FINDINGS="${HARNESS_FINDINGS:-$ROOT/script/tenderly/leveraged-aero-withdraw-findings.json}"

_cfg() { jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty' "$_CFG" 2>/dev/null; }
STRAT="${SHERWOOD_LEVERAGED_AERO_STRATEGY:-$(_cfg pooled strategyClone)}"
VAULT="${SHERWOOD_SYNDICATE_VAULT:-$(_cfg pooled vault)}"
FACTORY="${ACCOUNT_FACTORY:-$(_cfg mamo accountFactory)}"

REUSE_VNET=1
KEEP_VNET=0
# The MAX_OPEN_REQUESTS scenario costs 16 sequential sends (~10 min against the vnet) to confirm a
# compile-time constant, so it is opt-in. Everything else runs in a couple of minutes.
# NOT `[ ... ] && { ... }`: under `set -e` a false test makes that compound the script's exit status
# and kills the run before anything is logged.
RUN_SLOW=0
if [ "${1:-}" = "--full" ]; then RUN_SLOW=1; shift; fi
_CLI_VNET_RPC="${TENDERLY_VNET_RPC_URL:-}"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
[ -n "$_CLI_VNET_RPC" ] && export TENDERLY_VNET_RPC_URL="$_CLI_VNET_RPC"

ETH_FUND_HEX=0x56BC75E2D63100000     # 100 ETH
USDC_FUND_HEX=0x2540BE400            # 10,000 USDC (6dp)
DEPOSIT=5000000000                   # 5,000 USDC
PLAIN_XFER=100000000                 # 100 USDC
FULFILL_WINDOW=172800                # 2 days — LeveragedAerodromeCLStrategy.FULFILL_WINDOW
MAX_OPEN_REQUESTS=16                 # MamoLeveragedAeroStrategy.MAX_OPEN_REQUESTS

assert_eq()  { [ "$2" = "$3" ] && ok "$1 == $3" || die "$1 mismatch: got $2 want $3"; }
assert_gt()  { [ "$2" -gt "$3" ] 2>/dev/null && ok "$1 ($2) > $3" || die "$1 not > $3 (got $2)"; }

# ── findings accumulator ─────────────────────────────────────────────────────
# Appends {key: value} to the emitted JSON. Values are raw strings — the artifact formats them.
_FIND_TMP="$(mktemp)"; echo '{}' > "$_FIND_TMP"
record() { # <key> <value>
  jq --arg k "$1" --arg v "$2" '. + {($k): $v}' "$_FIND_TMP" > "$_FIND_TMP.n" && mv "$_FIND_TMP.n" "$_FIND_TMP"
}

# ── revert decoding ──────────────────────────────────────────────────────────
# The frontend has to map a revert to user-facing copy, so a raw `0x08c379a0…` blob is useless
# to it and to this log. Custom errors are 4-byte selectors with no on-chain name, so the table
# is built by hashing every `error Foo(...)` declared in the two contracts that can revert here —
# generated rather than hardcoded, so a new error does not silently degrade to "unknown".
ERR_TABLE="$(mktemp)"
build_error_table() {
  # Canonicalise before hashing: `error Foo(uint256 ltvBps, uint256 maxLtvBps)` must become
  # `Foo(uint256,uint256)`. Stripping whitespace alone yields `Foo(uint256ltvBps,...)`, which hashes
  # to nothing and silently degrades every PARAMETERISED error to "unknown" — which is exactly how
  # FastRedeemExceedsLtv, the most important revert in this flow, first showed up unnamed.
  : > "$ERR_TABLE"
  # `find`, not a glob: NotExecuted() is declared in src/leveraged-aero/sherwood/BaseStrategy.sol,
  # two levels down, and a one-level glob silently left the most common async revert unnamed.
  python3 "$SCRIPT_DIR/lib/solidity-error-sigs.py" $(find src -name '*.sol' | sort) > "$ERR_TABLE.sigs"
  local sig sel
  while read -r sig; do
    [ -n "$sig" ] || continue
    sel="$(cast sig "$sig" 2>/dev/null || true)"
    [ -n "$sel" ] && echo "$sel $sig" >> "$ERR_TABLE"
  done < "$ERR_TABLE.sigs"
  rm -f "$ERR_TABLE.sigs"
  info "revert decoder: $(wc -l < "$ERR_TABLE" | tr -d ' ') custom-error selectors known"
}

# Turn cast's stderr into something a human (and the artifact) can read.
decode_revert() {
  local raw="$1" hex sel name
  hex="$(echo "$raw" | grep -oE '0x[0-9a-fA-F]{8,}' | tail -1)"
  if [ -z "$hex" ]; then echo "$raw" | tr '\n' ' ' | sed -E 's/  +/ /g' | cut -c1-160; return; fi
  case "$hex" in
    0x08c379a0*)  # Error(string) — a plain require message
      echo "require: $(cast abi-decode 'e()(string)' "0x${hex#0x08c379a0}" 2>/dev/null | tr -d '"')" ;;
    0x4e487b71*)  # Panic(uint256)
      echo "panic: $(cast abi-decode 'e()(uint256)' "0x${hex#0x4e487b71}" 2>/dev/null | field)" ;;
    *)
      sel="$(echo "$hex" | cut -c1-10)"
      name="$(grep -i "^$sel " "$ERR_TABLE" 2>/dev/null | head -1 | awk '{print $2}')"
      if [ -z "$name" ]; then echo "unknown custom error $sel"; return; fi
      # A parameterised error carries the numbers the frontend needs — FastRedeemExceedsLtv reports
      # the live LTV and the cap, and the cap has NO public getter, so this revert is the only place
      # it is observable at all. Decode the args rather than dropping them.
      local types args
      types="$(echo "$name" | sed -E 's/^[^(]*\(//; s/\)$//')"
      if [ -z "$types" ]; then echo "$name"; return; fi
      args="$(cast abi-decode "e()($types)" "0x${hex#$sel}" 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
      if [ -n "$args" ]; then echo "$name = [$args]"; else echo "$name"; fi ;;
  esac
}

# `cast call` rather than `cast send`: a static call surfaces the revert REASON and cannot leave
# half-applied state behind.
# usage: expect_revert <label> <want-substr|any> <from> <to> <sig> [args...]
expect_revert() {
  local label="$1" want="$2" from="$3" to="$4" sig="$5"; shift 5
  local out rc reason
  set +e; out="$(cast call "$to" "$sig" "$@" --from "$from" --rpc-url "$RPC" 2>&1)"; rc=$?; set -e
  [ $rc -ne 0 ] || die "$label: expected a revert, the call SUCCEEDED"
  reason="$(decode_revert "$out")"
  if [ "$want" != "any" ] && ! echo "$reason" | grep -qiF -- "$want"; then
    die "$label: reverted, but not with '$want' — got: $reason"
  fi
  ok "$label — reverts: $reason"
  record "$label" "$reason"
}

# csend, but a revert is DATA. `die` inside a scenario body would skip revert_to and leave the
# shared vnet mid-scenario, so anything whose failure is a legitimate finding uses this.
# usage: csend_soft <label> <from> <to> <sig> [args...] -> 0 on success, 1 on revert; sets SOFT_ERR
csend_soft() {
  local label="$1" from="$2" to="$3" sig="$4"; shift 4
  local gl out st
  gl="$(gas_flags "$from" "$to" "$sig" "$@")"
  set +e
  out="$(cast send "$to" "$sig" "$@" --from "$from" --unlocked $gl --rpc-url "$RPC" --json 2>&1)"
  set -e
  st="$(echo "$out" | jq -r '.status' 2>/dev/null)"
  if [ "$st" = "0x1" ]; then ok "$label - tx $(echo "$out" | jq -r '.transactionHash')"; SOFT_ERR=""; return 0; fi
  SOFT_ERR="$(decode_revert "$out")"
  warn "$label - reverted: $SOFT_ERR"
  return 1
}

# ── 1. resolve vnet + preflight ───────────────────────────────────────────────
build_error_table
resolve_vnet
chain_sanity
REG="$(addr MAMO_STRATEGY_REGISTRY)"
USDC="$(addr USDC)"
MULTISIG="$(addr MAMO_MULTISIG)"

section "Preflight — pooled + account layers"
[ -n "$STRAT" ] && [ -n "$VAULT" ] || die "pooled layer not in $_CFG — run 'make tenderly-leveraged-aero-stack' first"
[ -n "$FACTORY" ] || die "mamo.accountFactory not in $_CFG — run 'make tenderly-leveraged-aero-account' first"
[ "$(cast code "$FACTORY" --rpc-url "$RPC" | wc -c)" -gt 4 ] || die "factory $FACTORY has no code on this vnet"
STATE="$(ccall "$STRAT" 'state()(uint8)' | field)"
assert_eq "strategy.state() (1 == Executed)" "$STATE" "1"
info "strategy=$STRAT vault=$VAULT factory=$FACTORY"
record "strategy" "$STRAT"; record "vault" "$VAULT"; record "accountFactory" "$FACTORY"

# ── 2. baseline: a funded user with a deposited account ───────────────────────
section "Baseline — fresh user, account, 5,000 USDC deposited"
NEWW="$(cast wallet new)"
USER="$(echo "$NEWW" | awk '/Address:/{print $2}')"
info "throwaway user: $USER   key: $(echo "$NEWW" | awk '/Private key:/{print $3}') (fork-only)"
fund_eth "$USER" "$ETH_FUND_HEX"
fund_erc20 "$USDC" "$USER" "$USDC_FUND_HEX"

csend "createStrategyForUser(user)" "$USER" "$FACTORY" 'createStrategyForUser(address)' "$USER"
ACCT="$(ccall "$FACTORY" 'computeStrategyAddress(address)(address)' "$USER" | field)"
info "account = $ACCT"

NAV="$(ccall "$STRAT" 'nav()(uint256)' | field)"; SUP="$(ccall "$VAULT" 'totalSupply()(uint256)' | field)"
MINSH="$(python3 -c "print(($DEPOSIT*($SUP+10**6)//($NAV+1))*99//100)")"
csend "approve(account, 5,000 USDC)" "$USER" "$USDC" 'approve(address,uint256)' "$ACCT" "$DEPOSIT"
csend "deposit(5,000 USDC, minShares)" "$USER" "$ACCT" 'deposit(uint256,uint256)' "$DEPOSIT" "$MINSH"
SHARES="$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)"
assert_gt "sharesBalance after deposit" "$SHARES" "0"
record "baselineDepositUsdc6dp" "$DEPOSIT"
record "baselineShares12dp" "$SHARES"

PROPOSER="$(ccall "$STRAT" 'proposer()(address)' | field)"
fund_eth "$PROPOSER" "$ETH_FUND_HEX"
info "proposer = $PROPOSER (impersonated to stand in for the backend)"

# ── scenario runner: snapshot → body → revert ─────────────────────────────────
PASS=0; TOTAL=0; FAILED=""
scenario() { # <name> <function>
  local name="$1"; shift
  TOTAL=$((TOTAL + 1))
  section "Scenario: $name"
  local snap; snap="$(snapshot)"
  if "$@"; then ok "scenario '$name' passed"; PASS=$((PASS + 1)); else warn "scenario '$name' FAILED"; FAILED="$FAILED\n    - $name"; fi
  revert_to "$snap"
  info "reverted to baseline"
}

# Helper: submit requestWithdraw and echo the request id (only recoverable from the receipt logs).
REQ_SIG="$(cast keccak 'WithdrawRequested(uint256,uint256,uint256)')"
request_withdraw() { # <shares> <minAssetsOut> → echoes id
  local sh="$1" mo="$2" gl rc
  gl="$(gas_flags "$USER" "$ACCT" 'requestWithdraw(uint256,uint256)' "$sh" "$mo")"
  rc="$(cast send "$ACCT" 'requestWithdraw(uint256,uint256)' "$sh" "$mo" --from "$USER" --unlocked $gl --rpc-url "$RPC" --json 2>/dev/null)"
  [ "$(echo "$rc" | jq -r '.status')" = "0x1" ] || return 1
  cast to-dec "$(echo "$rc" | jq -r --arg a "$(echo "$ACCT" | tr 'A-Z' 'a-z')" --arg s "$REQ_SIG" \
    '.logs[] | select((.address|ascii_downcase)==$a and .topics[0]==$s) | .topics[1]')"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. QUOTE DRIFT — how stale is a preview by the time the user signs?
#    The management fee accrues with dt, so previewWithdraw's answer decays. The frontend needs a
#    tolerance for minAssetsOut; this measures what it actually has to absorb rather than guessing.
# ─────────────────────────────────────────────────────────────────────────────
sc_quote_drift() {
  local q0 q1 q2
  q0="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 1p | field)"
  info "quote at T+0     : $q0"
  advance_time 60;    q1="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 1p | field)"
  advance_time 3540;  q2="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 1p | field)"
  info "quote at T+60s   : $q1"
  info "quote at T+1h    : $q2"
  python3 - "$q0" "$q1" "$q2" <<'PY'
import sys
q0, q1, q2 = (int(x) for x in sys.argv[1:4])
for label, q in (("60s", q1), ("1h", q2)):
    bps = (q0 - q) * 10_000 / q0 if q0 else 0
    print(f"  drift over {label:>3}: {q0-q} units ({bps:.4f} bps of the quote)")
PY
  record "quoteAtT0" "$q0"; record "quoteAtT60s" "$q1"; record "quoteAtT1h" "$q2"
  # MEASURED, not asserted. The natspec warns that the management fee accrues with dt, which would
  # make the quote decay; on this instance the opposite happens, because venue yield accrues faster
  # than the fee. Either direction is fine for the frontend as long as it knows which — so this
  # records the sign rather than encoding a guess about it.
  #
  # HONEST LIMIT: FreshFeed mocks hold the venue prices still, so this isolates ACCRUAL only. Real
  # price movement is not modelled here and dominates on mainnet, where drift IS two-sided. Treat
  # the number below as the floor on drift, never as the whole of it.
  if [ "$q2" -gt "$q0" ]; then
    record "quoteDriftDirection" "increasing (accrual outpaces the management fee, no price movement modelled)"
    info "direction: quote INCREASES with time on this instance"
  else
    record "quoteDriftDirection" "decreasing (management fee dominates)"
    info "direction: quote DECREASES with time on this instance"
  fi
  record "quoteDriftCaveat" "FreshFeed pins venue prices — accrual only; real price movement makes drift two-sided"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. fastOk SEMANTICS — what a frontend can and cannot conclude from previewWithdraw.
# ─────────────────────────────────────────────────────────────────────────────
sc_fastok_semantics() {
  local out q fast
  out="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)')" || true
  q="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 1p | field)"
  fast="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 2p | field)"
  info "previewWithdraw(all) → assetsOut=$q fastOk=$fast"
  record "previewFastOkAtBaseline" "$fast"
  record "previewAssetsOutAtBaseline" "$q"

  # A ZERO-share preview is the ambiguity the frontend has to handle: (0,false) is also what a
  # down oracle returns, so "0 and false" cannot be rendered as "the oracle is down".
  local z zf
  z="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' 0 | sed -n 1p | field)"
  zf="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' 0 | sed -n 2p | field)"
  info "previewWithdraw(0) → assetsOut=$z fastOk=$zf   (same shape a down oracle returns)"
  record "previewAtZeroShares" "assetsOut=$z fastOk=$zf"
  assert_eq "previewWithdraw(0) assetsOut" "$z" "0"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 2b. DOES fastOk == false ACTUALLY BLOCK withdraw()?
#     previewRedeem's natspec calls fastOk advisory and names fastRedeemImpl's LTV gate as
#     authoritative. On this instance fastOk is FALSE at a healthy baseline, so the frontend's
#     whole routing decision hangs on whether that is a refusal or just a conservative hint.
#     This is the single most consequential answer in the matrix.
# ─────────────────────────────────────────────────────────────────────────────
sc_fastok_is_authoritative() {
  local fast q half hq before after out rc
  fast="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 2p | field)"
  q="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 1p | field)"
  info "full position: fastOk=$fast quote=$q"

  # Full position first.
  set +e
  out="$(cast call "$ACCT" 'withdraw(uint256,uint256)' "$SHARES" 1 --from "$USER" --rpc-url "$RPC" 2>&1)"; rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    warn "fastOk=$fast but withdraw(full) SUCCEEDS — fastOk is advisory, not a refusal"
    record "fastOkFullPosition" "$fast"
    record "withdrawFullWhenFastOkFalse" "SUCCEEDS — fastOk is a hint, the UI must not gate on it alone"
  else
    ok "withdraw(full) reverts: $(decode_revert "$out")"
    record "fastOkFullPosition" "$fast"
    record "withdrawFullWhenFastOkFalse" "reverts: $(decode_revert "$out")"
  fi

  # Half position — the size the existing account harness proves works.
  half=$((SHARES / 2))
  hq="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$half" | sed -n 2p | field)"
  info "half position: fastOk=$hq"
  record "fastOkHalfPosition" "$hq"
  before="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
  if csend_soft "withdraw(half, 1)" "$USER" "$ACCT" 'withdraw(uint256,uint256)' "$half" 1; then
    after="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
    assert_gt "half-position fast withdraw paid the user" "$after" "$before"
    record "withdrawHalfResult" "SUCCEEDS (paid $((after - before)) USDC 6dp)"
  else
    record "withdrawHalfResult" "reverts: $SOFT_ERR"
    info "the fast path is closed at HALF the position too - async is the only exit in this book state"
  fi
  # The gate's own inputs, so the finding stays interpretable once the book state moves on.
  # NOTE maxLtvBps() is NOT exposed: the strategy publishes targetLtvBps() only, so a frontend
  # cannot precompute whether the fast path will clear — it has to try and read the revert args.
  record "targetLtvBps" "$(ccall "$STRAT" 'targetLtvBps()(uint16)' 2>/dev/null | field || echo unknown)"
  record "maxLtvBpsReadable" "NO public getter — only observable in the FastRedeemExceedsLtv revert args"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. REQUEST → CANCEL — shares come back, tracking clears, gate stays shut.
# ─────────────────────────────────────────────────────────────────────────────
sc_request_cancel() {
  local id
  id="$(request_withdraw "$SHARES" 1)" || return 1
  ok "requestWithdraw → id=$id"
  assert_eq "account shares escrowed"   "$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)" "0"
  assert_eq "openRequestIds length"     "$(ccall "$ACCT" 'openRequestIds()(uint256[])' | tr -d '[]' | tr ',' '\n' | grep -c .)" "1"
  assert_eq "hasUnclaimedWithdrawal"    "$(ccall "$ACCT" 'hasUnclaimedWithdrawal()(bool)')" "false"

  csend "cancelWithdraw(id)" "$USER" "$ACCT" 'cancelWithdraw(uint256)' "$id"
  assert_eq "shares returned to account" "$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)" "$SHARES"
  assert_eq "openRequestIds emptied"     "$(ccall "$ACCT" 'openRequestIds()(uint256[])' | tr -d '[] ' | grep -c . || true)" "0"

  # THE TRAP: cancel sets `settled` on the strategy too. A frontend reading redeemRequest(id).settled
  # off the shared strategy would call this "fulfilled, money waiting". Only the ACCOUNT's
  # hasUnclaimedWithdrawal() is correct, because cancel untracks the id.
  local settled
  settled="$(ccall "$STRAT" 'redeemRequest(uint256)((address,uint256,uint256,uint40,bool,address))' "$id" | grep -oE 'true|false' | tail -1)"
  info "strategy.redeemRequest($id).settled after CANCEL = $settled"
  record "settledFlagAfterCancel" "$settled"
  assert_eq "account hasUnclaimedWithdrawal after cancel" "$(ccall "$ACCT" 'hasUnclaimedWithdrawal()(bool)')" "false"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. EMERGENCY EXIT — closed until FULFILL_WINDOW elapses, then trustless.
#    This is the "backend is down" story and it needs a countdown in the UI.
# ─────────────────────────────────────────────────────────────────────────────
sc_request_emergency() {
  local id requested_at
  id="$(request_withdraw "$SHARES" 1)" || return 1
  ok "requestWithdraw → id=$id"
  requested_at="$(ccall "$STRAT" 'redeemRequest(uint256)((address,uint256,uint256,uint40,bool,address))' "$id" | tr -d '()' | awk -F', ' '{print $4}' | field)"
  info "requestedAt=$requested_at → emergency opens at $((requested_at + FULFILL_WINDOW))"
  record "fulfillWindowSeconds" "$FULFILL_WINDOW"

  expect_revert "emergencyWithdraw before the window" "any" "$USER" "$ACCT" 'emergencyWithdraw(uint256,uint256)' "$id" 0

  advance_time $((FULFILL_WINDOW + 60))
  ensure_feeds_fresh "$(_cfg feeds legAUsd)" "$(_cfg feeds usdcUsd)" 2>/dev/null || true
  local before after
  before="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
  csend "emergencyWithdraw(id) after +2d" "$USER" "$ACCT" 'emergencyWithdraw(uint256,uint256)' "$id" 0
  after="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
  assert_gt "USDC paid straight to the USER (not the account)" "$after" "$before"
  assert_eq "account holds no USDC after emergency" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"
  record "emergencyPaysDirectlyToOwner" "true (no claim step needed)"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. STUCK REQUEST — minAssetsOut too tight, so the backend's fulfill reverts.
#    The request just sits there. Nobody currently owns the retry.
# ─────────────────────────────────────────────────────────────────────────────
sc_stuck_fulfil() {
  local q id
  q="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 1p | field)"
  # Ask for 2x what the position is worth: fulfil can never clear this floor.
  id="$(request_withdraw "$SHARES" "$((q * 2))")" || return 1
  ok "requestWithdraw with an unreachable floor (${q} available, asked $((q * 2))) → id=$id"

  expect_revert "fulfillRedeem against an unreachable floor" "any" "$PROPOSER" "$STRAT" 'fulfillRedeem(uint256,uint256)' "$id" 0

  local settled
  settled="$(ccall "$STRAT" 'redeemRequest(uint256)((address,uint256,uint256,uint40,bool,address))' "$id" | grep -oE 'true|false' | tail -1)"
  assert_eq "request still unsettled after a failed fulfil" "$settled" "false"
  assert_eq "shares still escrowed"                          "$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)" "0"
  assert_eq "hasUnclaimedWithdrawal still false"             "$(ccall "$ACCT" 'hasUnclaimedWithdrawal()(bool)')" "false"
  # The user's own escape hatches both still work — this is the recovery story for the UI.
  csend "cancelWithdraw(id) recovers the stuck request" "$USER" "$ACCT" 'cancelWithdraw(uint256)' "$id"
  assert_eq "shares returned" "$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)" "$SHARES"
  record "stuckRequestRecovery" "cancelWithdraw(id) returns the shares; emergencyWithdraw(id) also available after the window"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. MAX_OPEN_REQUESTS — the 17th request is refused.
# ─────────────────────────────────────────────────────────────────────────────
sc_max_open_requests() {
  local i
  for i in $(seq 1 "$MAX_OPEN_REQUESTS"); do
    request_withdraw 1 1 >/dev/null || die "request #$i failed before the cap"
  done
  ok "opened $MAX_OPEN_REQUESTS requests"
  assert_eq "openRequestIds length" "$(ccall "$ACCT" 'openRequestIds()(uint256[])' | tr -d '[]' | tr ',' '\n' | grep -c .)" "$MAX_OPEN_REQUESTS"
  expect_revert "requestWithdraw #$((MAX_OPEN_REQUESTS + 1))" "Too many open requests" \
    "$USER" "$ACCT" 'requestWithdraw(uint256,uint256)' 1 1
  record "maxOpenRequests" "$MAX_OPEN_REQUESTS"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. CLAIM AT ZERO — the button must not be offered on an empty account.
# ─────────────────────────────────────────────────────────────────────────────
sc_claim_zero() {
  assert_eq "account USDC is 0 to begin with" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"
  expect_revert "claimWithdrawnUsdc() on an empty account" "No USDC to claim" \
    "$USER" "$ACCT" 'claimWithdrawnUsdc()'
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. CLAIM SWEEPS EVERYTHING — including USDC the user plain-transferred in.
#    Relevant because the UI may show "withdrawable" from request proceeds alone.
# ─────────────────────────────────────────────────────────────────────────────
sc_claim_sweeps_plain_transfer() {
  csend "user plain-transfers 100 USDC to the account" "$USER" "$USDC" 'transfer(address,uint256)' "$ACCT" "$PLAIN_XFER"
  assert_eq "account idle USDC" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "$PLAIN_XFER"
  local before after
  before="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
  csend "claimWithdrawnUsdc()" "$USER" "$ACCT" 'claimWithdrawnUsdc()'
  after="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
  assert_eq "claim swept the plain transfer too" "$((after - before))" "$PLAIN_XFER"
  assert_eq "account USDC after claim" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"
  record "claimSweepsWholeIdleBalance" "true (a plain transfer is indistinguishable from redeem proceeds)"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. FULFIL PAYS THE USER DIRECTLY — no proceeds park on the account, no claim step.
#    The account names owner() as the pooled request's RECIPIENT, so fulfillRedeem transfers the USDC
#    to the user. RedeemFulfilled is still emitted by the SHARED pooled strategy, indexed by the
#    ACCOUNT address in topic2 and now by the RECIPIENT in topic3; the account emits nothing.
# ─────────────────────────────────────────────────────────────────────────────
sc_fulfilled_unclaimed() {
  local id ful_sig before after
  id="$(request_withdraw "$SHARES" 1)" || return 1
  ok "requestWithdraw → id=$id"
  before="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
  csend "fulfillRedeem(id) [proposer stands in for the backend]" "$PROPOSER" "$STRAT" 'fulfillRedeem(uint256,uint256)' "$id" 0
  after="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"

  assert_gt "USDC landed on the USER (not the account)" "$after" "$before"
  assert_eq "account holds no USDC after the fulfil" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"
  record "fulfilledProceedsLandOn" "the owner directly — no claimWithdrawnUsdc() step"

  # The push signal: an event on the SHARED strategy, indexed by both the account and the payee.
  ful_sig="$(cast keccak 'RedeemFulfilled(uint256,address,address,uint256)')"
  info "watch topic0=$ful_sig on $STRAT, topic2 = the account, topic3 = the paid recipient (padded)"
  record "fulfilEventEmitter" "$STRAT (shared across all users)"
  record "fulfilEventTopic0"  "$ful_sig"
  record "fulfilEventFilter"  "topics[2] == account address, topics[3] == recipient, left-padded to 32 bytes"

  # The request completed, so its id is stale bookkeeping the next owner call prunes — it claims nothing.
  assert_eq "hasSettledRequest reports the completed request" "$(ccall "$ACCT" 'hasSettledRequest()(bool)')" "true"
  expect_revert "claimWithdrawnUsdc() has nothing to sweep" "No USDC to claim" \
    "$USER" "$ACCT" 'claimWithdrawnUsdc()'
  csend "syncRedeemRequests()" "$USER" "$ACCT" 'syncRedeemRequests()'
  assert_eq "openRequestIds pruned"  "$(ccall "$ACCT" 'openRequestIds()(uint256[])' | tr -d '[] ' | grep -c . || true)" "0"
  assert_eq "hasSettledRequest cleared" "$(ccall "$ACCT" 'hasSettledRequest()(bool)')" "false"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. STRATEGY NOT EXECUTED — both exits close at once. No UI anticipates this today.
# ─────────────────────────────────────────────────────────────────────────────
sc_state_not_executed() {
  csend "vault.settleStrategy() [multisig]" "$MULTISIG" "$VAULT" 'settleStrategy()'
  local st; st="$(ccall "$STRAT" 'state()(uint8)' | field)"
  info "strategy.state() = $st (2 == Settled)"
  record "stateAfterSettle" "$st"

  expect_revert "requestWithdraw while state != Executed" "NotExecuted" "$USER" "$ACCT" 'requestWithdraw(uint256,uint256)' "$SHARES" 1
  # Approve FIRST. Without it the ERC20 allowance check fires before the state gate and the test
  # passes for the wrong reason — it would assert nothing about `state` at all.
  csend "approve(account, 1 USDC) so the STATE gate is what fires" "$USER" "$USDC" 'approve(address,uint256)' "$ACCT" 1000000
  expect_revert "deposit while state != Executed"         "NotExecuted" "$USER" "$ACCT" 'deposit(uint256,uint256)' 1000000 0
  # previewWithdraw is the read the UI would use to decide what to show. Record what it says here.
  local q f
  q="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 1p | field || echo REVERTED)"
  f="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$SHARES" | sed -n 2p | field || echo REVERTED)"
  info "previewWithdraw while Settled → assetsOut=$q fastOk=$f"
  record "previewWhileSettled" "assetsOut=$q fastOk=$f"
  return 0
}

# ── run the matrix ────────────────────────────────────────────────────────────
scenario "1  quote drift over time"                  sc_quote_drift
scenario "2  fastOk / preview semantics"             sc_fastok_semantics
scenario "2b fastOk advisory vs authoritative"       sc_fastok_is_authoritative
scenario "3  request → cancel"                       sc_request_cancel
scenario "4  request → emergency after FULFILL_WINDOW" sc_request_emergency
scenario "5  stuck fulfil (floor unreachable)"       sc_stuck_fulfil
if [ "$RUN_SLOW" = 1 ]; then
  scenario "6  MAX_OPEN_REQUESTS cap"                sc_max_open_requests
else
  info "skipping scenario 6 (MAX_OPEN_REQUESTS = $MAX_OPEN_REQUESTS, 16 sends) — pass --full to run it"
  record "maxOpenRequests" "$MAX_OPEN_REQUESTS"
  record "maxOpenRequestsRevert" "require: Too many open requests (verified 2026-08-19 with --full)"
fi
scenario "7  claim on an empty account"              sc_claim_zero
scenario "8  claim sweeps a plain transfer"          sc_claim_sweeps_plain_transfer
scenario "9  fulfilled-but-unclaimed"                sc_fulfilled_unclaimed
scenario "10 strategy not Executed"                  sc_state_not_executed

# ── emit findings ─────────────────────────────────────────────────────────────
section "Findings"
jq --arg chain "$(cast chain-id --rpc-url "$RPC")" \
   --arg acct "$ACCT" --arg user "$USER" \
   '. + {chainId: $chain, sampleAccount: $acct, sampleUser: $user}' "$_FIND_TMP" > "$FINDINGS"
rm -f "$_FIND_TMP" "$ERR_TABLE"
ok "findings → ${FINDINGS#$ROOT/}"

section "Summary"
if [ "$PASS" -eq "$TOTAL" ]; then
  ok "withdraw-edge matrix: $PASS/$TOTAL scenarios passed"
else
  printf "  scenarios FAILED:$FAILED\n" | tee -a "$RESULTS"
  die "withdraw-edge matrix: $PASS/$TOTAL scenarios passed"
fi
teardown
