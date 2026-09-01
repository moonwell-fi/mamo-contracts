#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# remint-range-cycle.sh — drive `remintRange` (explicit-tick remint + optional leg swap) on the
# leveraged-aero Tenderly vnet, as the proposer.
#
# `remintRange` is the placement primitive the rebalancer's d4/2 strategy uses: explicit ticks
# (width-band-bounded, the SKEW band deliberately does not apply) plus an optional swap of part of
# the inventory the unwind collects, so the mint can be two-sided at a band spot has left. The swap
# is bounded by max(minSwapOut, Chainlink cross-rate − maxSlippageBps) — `scenarios` proves both
# halves: the happy paths AND that `minSwapOut = 0` still reverts on a pool price away from oracle.
#
# Usage:
#   ./remint-range-cycle.sh book                                    # position + inventory snapshot
#   ./remint-range-cycle.sh remint <tickLo> <tickHi> <zeroForOne> <swapBps> [minSwapOut] [minLiq]
#   ./remint-range-cycle.sh remint-expect-revert <same args>        # zero-side-effect eth_call probe
#   ./remint-range-cycle.sh scenarios                               # canned suite (see below)
#
# `scenarios` mutates the book (real remints) and the pool (a move-pool round-trip for the floor
# leg, via compound-cycle.sh) — run it on an instance where that is acceptable. It ends by
# re-minting a centred band at the restored spot, so the book is left ordinary.
#
# RPC: LEVERAGED_AERO_ADMIN_RPC_URL, falling back to TENDERLY_VNET_RPC_URL (same rule and same
# caveat as compound-cycle.sh: set it explicitly, the .env values may point at a different vnet).
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CFG="$HERE/leveraged-aero-vnet.json"
CYCLE="$HERE/compound-cycle.sh"

[[ -f "$ROOT/.env" ]] && set -a && . "$ROOT/.env" && set +a
RPC="${LEVERAGED_AERO_ADMIN_RPC_URL:-${TENDERLY_VNET_RPC_URL:?set LEVERAGED_AERO_ADMIN_RPC_URL (admin RPC) or TENDERLY_VNET_RPC_URL}}"

eval "$(python3 - "$CFG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(f'STRAT="{d["pooled"]["strategyClone"]}"')
print(f'POOL="{d["pooled"]["lpPool"]}"')
print(f'PROPOSER="{d["pooled"]["proposer"]}"')
print(f'USDC="{d["usdc"]}"')
PY
)"

# NB: identical to compound-cycle.sh — 51 fields, 1-based `lay N`; that header's warning applies.
LAYOUT_SIG='layout()((address,address,address,address,address,address,address,address,address,address,address,uint256,uint256,uint16,uint32,address,address,address,address,int24,uint16,uint16,uint16,uint16,uint16,uint256,int24,int24,uint16,uint16,address,uint256,uint256,address,uint256,uint8,uint8,bool,bool,int24,int24,uint24,uint24,uint24,bool,uint16,uint16,uint16,uint128,uint128,bytes32))'

c() { cast call --rpc-url "$RPC" "$@" 2>/dev/null; }
num() { echo "${1%% *}"; }
lay() { c "$STRAT" "$LAYOUT_SIG" | tr ',' '\n' | sed -n "${1}p" | tr -d ' ()' | sed 's/\[.*//'; }
spot_tick() { num "$(c "$POOL" 'slot0()(uint160,int24,uint16,uint16,uint16,bool)' | sed -n 2p)"; }
align() { python3 -c "t=$1; s=$2; r=t % s; r += s if r < 0 else 0; print(t - r)"; }

PASS=0; FAIL=0
check() { # check <label> <cond-as-python-bool-expr>
  if python3 -c "import sys; sys.exit(0 if ($2) else 1)"; then
    echo "  ✓ $1"; PASS=$((PASS+1))
  else
    echo "  ✗ $1  [$2]"; FAIL=$((FAIL+1))
  fi
}

cmd_book() {
  local t0 t1 s0 s1
  t0="$(c "$POOL" 'token0()(address)')"; t1="$(c "$POOL" 'token1()(address)')"
  s0="$(c "$t0" 'symbol()(string)' | tr -d '"')"; s1="$(c "$t1" 'symbol()(string)' | tr -d '"')"
  echo "strategy   $STRAT   proposer $PROPOSER"
  echo "pool       $POOL   token0 $s0  token1 $s1"
  echo "spot tick  $(spot_tick)   tickSpacing $(lay 20)"
  echo "position   tokenId $(lay 26)   ticks [$(lay 27), $(lay 28)]   width $(lay 42) (band [$(lay 43), $(lay 44)])   skewBps $(lay 46)"
  echo "nav        $(num "$(c "$STRAT" 'nav()(uint256)')")"
  echo "idle       $s0 $(num "$(c "$t0" 'balanceOf(address)(uint256)' "$STRAT")")   $s1 $(num "$(c "$t1" 'balanceOf(address)(uint256)' "$STRAT")")"
}

cmd_remint() {
  local lo="$1" hi="$2" z0="$3" bps="$4" minOut="${5:-0}" minLiq="${6:-1}" out
  echo "remintRange($lo, $hi, $z0, $bps, $minOut, $minLiq) as proposer $PROPOSER"
  out="$(cast send "$STRAT" 'remintRange(int24,int24,bool,uint16,uint256,uint256)' \
        "$lo" "$hi" "$z0" "$bps" "$minOut" "$minLiq" \
        --from "$PROPOSER" --unlocked --gas-limit 14000000 --rpc-url "$RPC" --json 2>&1)"
  echo "$out" | python3 -c '
import json,sys
raw=sys.stdin.read(); i=raw.find("{")
d=json.loads(raw[i:]) if i>=0 else {}
ok = d.get("status")=="0x1"
print("  tx",d.get("transactionHash"),"status",d.get("status"),"gas",int(d.get("gasUsed","0x0"),16))
sys.exit(0 if ok else 1)
' || { echo "  REVERT — raw:"; echo "$out" | tail -5; return 1; }
}

cmd_remint_expect_revert() {
  local lo="$1" hi="$2" z0="$3" bps="$4" minOut="${5:-0}" minLiq="${6:-1}" out sel
  echo "remintRange($lo, $hi, $z0, $bps, $minOut, $minLiq) — expecting a revert (eth_call, no state)"
  out="$(cast call "$STRAT" 'remintRange(int24,int24,bool,uint16,uint256,uint256)' \
        "$lo" "$hi" "$z0" "$bps" "$minOut" "$minLiq" --from "$PROPOSER" --rpc-url "$RPC" 2>&1)"
  if [[ "$out" != *"error"* && "$out" != *"revert"* && "$out" != *"Revert"* ]]; then
    echo "  DID NOT REVERT: $out"; return 1
  fi
  echo "$out" | tail -2 | sed 's/^/  /'
  sel="$(echo "$out" | grep -oE '0x[0-9a-f]{8}' | head -1)"; [[ -n "$sel" ]] && echo "  selector $sel"
  return 0
}

# ── the canned suite ─────────────────────────────────────────────────────────────────────────────
cmd_scenarios() {
  local spacing width spot lo hi tid0 tid1 nav0 nav1 t0 t1 idle0 oob
  spacing="$(lay 20)"; width="$(lay 42)"
  t0="$(c "$POOL" 'token0()(address)')"; t1="$(c "$POOL" 'token1()(address)')"
  oob="$(cast sig 'OutOfBounds()')"

  echo "══ S0 — book before"; cmd_book; echo

  echo "══ S1 — parity: centred explicit band, swapBps=0 (rerange-equivalent placement)"
  spot="$(spot_tick)"; lo="$(align $((spot - width / 2)) "$spacing")"; hi=$((lo + width))
  tid0="$(lay 26)"; nav0="$(num "$(c "$STRAT" 'nav()(uint256)')")"
  cmd_remint "$lo" "$hi" false 0 0 1 || { FAIL=$((FAIL+1)); echo "S1 send failed"; }
  tid1="$(lay 26)"; nav1="$(num "$(c "$STRAT" 'nav()(uint256)')")"
  check "S1 new tokenId minted"            "$tid1 != $tid0 and $tid1 > 0"
  check "S1 ticks persisted as requested"  "$(lay 27) == $lo and $(lay 28) == $hi"
  check "S1 width persisted"               "$(lay 42) == $hi - $lo"
  check "S1 nav conserved within 1%"       "abs($nav1 - $nav0) <= $nav0 // 100"
  echo

  echo "══ S2 — partial swap 25% token0→token1, centred band"
  spot="$(spot_tick)"; lo="$(align $((spot - width / 2)) "$spacing")"; hi=$((lo + width))
  tid0="$tid1"; nav0="$nav1"
  cmd_remint "$lo" "$hi" true 2500 0 1 || { FAIL=$((FAIL+1)); echo "S2 send failed"; }
  tid1="$(lay 26)"; nav1="$(num "$(c "$STRAT" 'nav()(uint256)')")"
  check "S2 new tokenId minted"      "$tid1 != $tid0 and $tid1 > 0"
  check "S2 nav conserved within 1%" "abs($nav1 - $nav0) <= $nav0 // 100"
  echo

  echo "══ S3 — partial swap 25% token1→token0, centred band"
  spot="$(spot_tick)"; lo="$(align $((spot - width / 2)) "$spacing")"; hi=$((lo + width))
  tid0="$tid1"; nav0="$nav1"
  cmd_remint "$lo" "$hi" false 2500 0 1 || { FAIL=$((FAIL+1)); echo "S3 send failed"; }
  tid1="$(lay 26)"; nav1="$(num "$(c "$STRAT" 'nav()(uint256)')")"
  check "S3 new tokenId minted"      "$tid1 != $tid0 and $tid1 > 0"
  check "S3 nav conserved within 1%" "abs($nav1 - $nav0) <= $nav0 // 100"
  echo

  echo "══ S4 — full-notional (10000) token0→token1, band wholly BELOW spot (one-sided, skew-band-free)"
  # All collected token0 is sold, so the mint is token1-only — legal only at/below spot. The
  # F05 guard: pre-existing idle token0 must NOT be drawn into the sale (balance can only grow).
  spot="$(spot_tick)"; hi="$(align "$spot" "$spacing")"; lo=$((hi - width))
  tid0="$tid1"; nav0="$nav1"; idle0="$(num "$(c "$t0" 'balanceOf(address)(uint256)' "$STRAT")")"
  cmd_remint "$lo" "$hi" true 10000 0 1 || { FAIL=$((FAIL+1)); echo "S4 send failed"; }
  tid1="$(lay 26)"; nav1="$(num "$(c "$STRAT" 'nav()(uint256)')")"
  check "S4 new tokenId minted"          "$tid1 != $tid0 and $tid1 > 0"
  check "S4 one-sided ticks persisted"   "$(lay 27) == $lo and $(lay 28) == $hi"
  check "S4 idle token0 not drawn (F05)" "$(num "$(c "$t0" 'balanceOf(address)(uint256)' "$STRAT")") >= $idle0"
  check "S4 nav conserved within 1%"     "abs($nav1 - $nav0) <= $nav0 // 100"
  echo

  echo "══ S5 — recentre two-sided with a 50% token1→token0 swap (the d4/2 shape)"
  spot="$(spot_tick)"; lo="$(align $((spot - width / 2)) "$spacing")"; hi=$((lo + width))
  tid0="$tid1"; nav0="$nav1"
  cmd_remint "$lo" "$hi" false 5000 0 1 || { FAIL=$((FAIL+1)); echo "S5 send failed"; }
  tid1="$(lay 26)"; nav1="$(num "$(c "$STRAT" 'nav()(uint256)')")"
  check "S5 new tokenId minted"          "$tid1 != $tid0 and $tid1 > 0"
  check "S5 spot inside the new band"    "$(lay 27) <= $(spot_tick) < $(lay 28)"
  check "S5 nav conserved within 1%"     "abs($nav1 - $nav0) <= $nav0 // 100"
  echo

  echo "══ S6 — validation probes (zero-side-effect eth_calls; all must revert)"
  spot="$(spot_tick)"; lo="$(align $((spot - width / 2)) "$spacing")"; hi=$((lo + width))
  local minw maxw
  minw="$(lay 43)"; maxw="$(lay 44)"
  cmd_remint_expect_revert $((lo + 1)) "$hi" false 0 0 1        && check "S6 misaligned tickLower reverts" "True" || check "S6 misaligned tickLower reverts" "False"
  cmd_remint_expect_revert "$hi" "$lo" false 0 0 1              && check "S6 inverted ticks revert" "True" || check "S6 inverted ticks revert" "False"
  cmd_remint_expect_revert "$lo" $((lo + minw - spacing)) false 0 0 1 && check "S6 width below band reverts" "True" || check "S6 width below band reverts" "False"
  cmd_remint_expect_revert "$lo" $((lo + maxw + spacing)) false 0 0 1 && check "S6 width above band reverts" "True" || check "S6 width above band reverts" "False"
  cmd_remint_expect_revert "$lo" "$hi" false 10001 0 1          && check "S6 swapBps > 10000 reverts" "True" || check "S6 swapBps > 10000 reverts" "False"
  local nonprop_out
  nonprop_out="$(cast call "$STRAT" 'remintRange(int24,int24,bool,uint16,uint256,uint256)' "$lo" "$hi" false 0 0 1 \
                 --from 0x000000000000000000000000000000000000dEaD --rpc-url "$RPC" 2>&1)"
  [[ "$nonprop_out" == *"error"* || "$nonprop_out" == *"evert"* ]] \
    && check "S6 non-proposer caller reverts" "True" || check "S6 non-proposer caller reverts" "False"
  echo "  (expected selector for the band/bps probes: OutOfBounds() = $oob)"
  echo

  echo "══ S7 — oracle floor: pool moved −500 ticks off the (unchanged) feeds, minSwapOut=0 must still revert"
  local twap t_orig
  twap="$(num "$(lay 15)")"; t_orig="$(spot_tick)"
  "$CYCLE" move-pool $((t_orig - 500)) || { FAIL=$((FAIL+1)); echo "move-pool failed"; }
  "$CYCLE" warp $((twap + 60)) >/dev/null || { FAIL=$((FAIL+1)); echo "warp failed"; }
  "$CYCLE" calm | tail -2
  spot="$(spot_tick)"; lo="$(align $((spot - width / 2)) "$spacing")"; hi=$((lo + width))
  # tick DOWN = token1 RICHER on the pool than at the (unchanged) Chainlink cross rate. Selling
  # token0 INTO the overpriced leg under-fills the always-on floor → must revert at minSwapOut=0;
  # selling token1 WITH the divergence over-fills it → must pass. The floor is directional.
  cmd_remint_expect_revert "$lo" "$hi" true 5000 0 1 \
    && check "S7 floor blocks minSwapOut=0 selling INTO the divergence" "True" \
    || check "S7 floor blocks minSwapOut=0 selling INTO the divergence" "False"
  local with_out
  with_out="$(cast call "$STRAT" 'remintRange(int24,int24,bool,uint16,uint256,uint256)' "$lo" "$hi" false 5000 0 1 \
              --from "$PROPOSER" --rpc-url "$RPC" 2>&1)"
  [[ "$with_out" != *"error"* && "$with_out" != *"evert"* ]] \
    && check "S7 selling WITH the divergence still passes (floor is directional)" "True" \
    || check "S7 selling WITH the divergence still passes (floor is directional)" "False"
  echo "  restoring pool to tick $t_orig"
  "$CYCLE" move-pool "$t_orig" >/dev/null || { FAIL=$((FAIL+1)); echo "restore move-pool failed"; }
  "$CYCLE" warp $((twap + 60)) >/dev/null || { FAIL=$((FAIL+1)); echo "restore warp failed"; }
  "$CYCLE" calm | tail -2
  echo

  echo "══ S8 — leave the book ordinary: centred remint at the restored spot, swapBps=0"
  spot="$(spot_tick)"; lo="$(align $((spot - width / 2)) "$spacing")"; hi=$((lo + width))
  nav0="$nav1"
  cmd_remint "$lo" "$hi" false 0 0 1 || { FAIL=$((FAIL+1)); echo "S8 send failed"; }
  nav1="$(num "$(c "$STRAT" 'nav()(uint256)')")"
  check "S8 spot inside the final band" "$(lay 27) <= $(spot_tick) < $(lay 28)"
  check "S8 nav conserved within 1%"    "abs($nav1 - $nav0) <= $nav0 // 100"
  echo; echo "══ book after"; cmd_book

  echo; echo "════ scenarios: $PASS passed, $FAIL failed ════"
  [[ "$FAIL" == 0 ]]
}

case "${1:-}" in
  book)                 cmd_book ;;
  remint)               shift; cmd_remint "$@" ;;
  remint-expect-revert) shift; cmd_remint_expect_revert "$@" ;;
  scenarios)            cmd_scenarios ;;
  *) sed -n '3,22p' "$0"; exit 2 ;;
esac
