#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────────────────────────
# compound-cycle.sh — drive a REAL AERO harvest cycle on the leveraged-aero Tenderly vnet.
#
# The pooled strategy's `compound()` is the one lifecycle path a fresh vnet cannot exercise: at the
# fork block the staked CL position has just been minted, so `gauge.earned() == 0` and no amount of
# calling `compound` proves anything. Getting real accrued AERO needs TWO things, in this order:
#
#   1. ARMED EMISSIONS. A Base fork inherits `pool.rewardReserve()`/`periodFinish` frozen at the fork
#      block, and NOBODY on a vnet ever runs Aerodrome's weekly epoch flip. Once the vnet clock is
#      past `periodFinish`, gauge accrual is permanently 0 — warping alone yields nothing. Re-arm it
#      the PRODUCTION way: `voter.distribute([gauge])`, which is permissionless and internally calls
#      `minter.updatePeriod()` (mint the week) → `gauge.notifyRewardAmount(claimable)` (sets
#      `rewardReserve` + `periodFinish = epochNext(now)`). No impersonation, no fake AERO.
#   2. TIME. Warp with `evm_increaseTime` up to the new `periodFinish` to drain the whole period.
#
# Warping is SAFE on this instance ONLY because the 5 venue Chainlink feeds are `FreshFeed` mocks
# (`updatedAt` tracks `block.timestamp`) — see `feeds` in `leveraged-aero-vnet.json` and the runbook
# section "Rebalance-cycle testing on the vnet". `check-feeds` below is the gate; run it after every
# warp. On an instance WITHOUT FreshFeed, warping bricks every priced path with `StaleOracle`.
#
# Usage (each subcommand is independent and idempotent-ish):
#   ./compound-cycle.sh snap [label]        # full before/after state dump
#   ./compound-cycle.sh check-feeds         # assert all 5 feeds fresh vs head (the warp gate)
#   ./compound-cycle.sh gauge              # emission-arming diagnostics
#   ./compound-cycle.sh arm                # voter.distribute([gauge]) — permissionless re-arm
#   ./compound-cycle.sh warp <seconds>     # evm_increaseTime + assert the head actually moved
#   ./compound-cycle.sh warp-to-finish     # warp to gauge.periodFinish + 60
#   ./compound-cycle.sh quote              # derive minUsdcOut: oracle fair, oracle floor, router quote
#   ./compound-cycle.sh compound <minUsdcOut> [minLiquidity]
#   ./compound-cycle.sh compound-expect-revert <minUsdcOut> [minLiquidity]
#   ./compound-cycle.sh floor-probe            # prove BelowOracleFloor with a zero-side-effect eth_call
#
# RPC: LEVERAGED_AERO_ADMIN_RPC_URL (admin, write-capable), falling back to TENDERLY_VNET_RPC_URL.
# Set the former explicitly — TENDERLY_VNET_RPC_URL is shared with the LPV2 harness and routinely
# points at a different vnet. Never commit either.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CFG="$HERE/leveraged-aero-vnet.json"

[[ -f "$ROOT/.env" ]] && set -a && . "$ROOT/.env" && set +a
# LEVERAGED_AERO_ADMIN_RPC_URL wins over TENDERLY_VNET_RPC_URL: the latter is shared with the LPV2
# harness and routinely points at a DIFFERENT vnet. Pointing this script at the wrong instance is
# caught by `check-feeds` (a non-FreshFeed instance fails the gate) — but set it explicitly.
RPC="${LEVERAGED_AERO_ADMIN_RPC_URL:-${TENDERLY_VNET_RPC_URL:?set LEVERAGED_AERO_ADMIN_RPC_URL (admin RPC) or TENDERLY_VNET_RPC_URL}}"

# ── resolved from leveraged-aero-vnet.json (never hardcode; the instance rotates) ──
eval "$(python3 - "$CFG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
out = {
    "STRAT": d["pooled"]["strategyClone"], "VAULT": d["pooled"]["vault"],
    "POOL": d["pooled"]["lpPool"], "PROPOSER": d["pooled"]["proposer"], "USDC": d["usdc"],
    "LEGA_FEED": d["feeds"]["legAUsd"], "LEGB_FEED": d["feeds"]["legBUsd"],
    "USDC_FEED": d["feeds"]["usdcUsd"], "AERO_FEED": d["feeds"]["aeroUsd"],
    "SEQ_FEED": d["feeds"]["sequencerUptime"],
}
for k, v in out.items():
    print(f'{k}="{v}"')
PY
)"

# fork-native Base addresses
AERO=0x940181a94A35A4569E4529A3CDfB74e38FD98631
AERO_V2_ROUTER=0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43
AERO_V2_FACTORY=0x420DD381b31aEf6683db6B902084cB0FFECe40Da
NPM=0x827922686190790b37229fd06084350E74485b72

# NB: keep in lockstep with LeveragedAerodromeCLStrategy.LayoutView. b9ea6ac appended
# `uint128 hedgedDebtA` + `uint128 hedgedDebtB` (fields 47/48) for the borrow-interest hedge; a
# short signature here makes `cast call` fail to decode and every `lay N` read comes back empty.
LAYOUT_SIG='layout()((address,address,address,address,address,address,address,address,address,address,address,uint256,uint256,uint16,uint32,address,address,address,address,int24,uint16,uint16,uint16,uint16,uint16,uint256,int24,int24,uint16,uint16,address,uint256,uint256,uint256,address,uint256,uint8,uint8,bool,bool,int24,int24,uint24,uint24,uint24,bool,uint128,uint128))'

c() { cast call --rpc-url "$RPC" "$@" 2>/dev/null; }
num() { echo "${1%% *}"; }
# `cast send --json` prints a foundry config warning on stdout in some versions; keep only the JSON.
receipt() { python3 -c '
import json,sys
raw=sys.stdin.read()
i=raw.find("{")
d=json.loads(raw[i:]) if i>=0 else {}
print("  tx",d["transactionHash"],"status",d["status"],"gas",int(d["gasUsed"],16),"block",int(d["blockNumber"],16))
'; }
rpc() { # rpc <method> <params-json>
  curl -s -X POST "$RPC" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}
head_ts() { cast block latest --rpc-url "$RPC" --field timestamp 2>/dev/null; }

lay() { c "$STRAT" "$LAYOUT_SIG" | tr ',' '\n' | sed -n "${1}p" | tr -d ' ()' | sed 's/\[.*//'; }
GAUGE_CACHE=""
gauge() { [[ -n "$GAUGE_CACHE" ]] || GAUGE_CACHE="$(lay 18)"; echo "$GAUGE_CACHE"; }
tokenid() { lay 26; }

# ─────────────────────────────────────────────────────────────────────────────── check-feeds
cmd_check_feeds() {
  local ts maxdelay bad=0
  ts="$(head_ts)"; maxdelay="$(num "$(lay 12)")"
  echo "head timestamp $ts   maxDelay ${maxdelay}s"
  for pair in "legA/USD:$LEGA_FEED" "legB/USD:$LEGB_FEED" "USDC/USD:$USDC_FEED" \
              "AERO/USD:$AERO_FEED" "seqUptime:$SEQ_FEED"; do
    local n="${pair%%:*}" a="${pair##*:}" raw ua ans lag
    raw="$(c "$a" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)')"
    ans="$(num "$(echo "$raw" | sed -n 2p)")"; ua="$(num "$(echo "$raw" | sed -n 4p)")"
    lag=$((ts - ua))
    if (( lag < 0 || lag > maxdelay )); then bad=1; printf '  ✗ '; else printf '  ✓ '; fi
    printf '%-10s %s answer=%-16s updatedAt=%-12s lag=%ss\n' "$n" "$a" "$ans" "$ua" "$lag"
  done
  if (( bad )); then
    echo "FEEDS STALE — this instance is NOT FreshFeed-backed (or the mock broke). Do NOT warp."; return 1
  fi
  echo "all 5 feeds fresh → warping is safe on this instance"
}

# ─────────────────────────────────────────────────────────────────────────────── gauge
cmd_gauge() {
  local g ts tid pf
  g="$(gauge)"; ts="$(head_ts)"; tid="$(num "$(tokenid)")"
  pf="$(num "$(c "$POOL" 'periodFinish()(uint256)')")"
  echo "gauge            $g   tokenId $tid"
  echo "head timestamp   $ts"
  echo "pool.periodFinish   $pf  ($((pf - ts)) s from head)"
  echo "pool.rewardReserve  $(num "$(c "$POOL" 'rewardReserve()(uint256)')")"
  echo "pool.rewardRate     $(num "$(c "$POOL" 'rewardRate()(uint256)')")  (AERO/s, 18dp)"
  echo "pool.stakedLiquidity $(num "$(c "$POOL" 'stakedLiquidity()(uint128)')")"
  echo "gauge.earned        $(num "$(c "$g" 'earned(address,uint256)(uint256)' "$STRAT" "$tid")")"
  echo "gauge.stakedContains $(c "$g" 'stakedContains(address,uint256)(bool)' "$STRAT" "$tid")"
  if (( pf <= ts )); then
    echo ">> EMISSIONS NOT ARMED (periodFinish in the past). Warping accrues NOTHING. Run 'arm'."
  else
    echo ">> emissions armed; accrual runs until periodFinish"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────── arm
cmd_arm() {
  local g out; g="$(gauge)"
  local voter; voter="$(c "$g" 'voter()(address)')"
  echo "voter.distribute([$g]) from $PROPOSER (permissionless; internally runs minter.updatePeriod)"
  out="$(cast send "$voter" 'distribute(address[])' "[$g]" \
        --from "$PROPOSER" --unlocked --gas-limit 12000000 --rpc-url "$RPC" --json 2>&1)"
  echo "$out" | receipt || { echo "$out" | tail -3; return 1; }
  cmd_gauge
}

# ─────────────────────────────────────────────────────────────────────────────── warp
cmd_warp() {
  local secs="$1" before after
  before="$(head_ts)"
  rpc evm_increaseTime "[\"$(printf '0x%x' "$secs")\"]" >/dev/null
  rpc evm_mine '[]' >/dev/null
  after="$(head_ts)"
  echo "warp requested ${secs}s — head $before → $after (moved $((after - before))s)"
  (( after - before >= secs )) || { echo "WARP DID NOT TAKE"; return 1; }
  cmd_check_feeds
}

cmd_warp_to_finish() {
  local pf ts
  pf="$(num "$(c "$POOL" 'periodFinish()(uint256)')")"; ts="$(head_ts)"
  (( pf > ts )) || { echo "periodFinish $pf already past head $ts — run 'arm' first"; return 1; }
  cmd_warp $((pf - ts + 60))
}

# ─────────────────────────────────────────────────────────────────────────────── quote
# Derives the three numbers that matter for `compound(minUsdcOut, minLiquidity)`:
#   fair6  = aeroBal × AERO/USD(8dp) / 1e20                       (oracle fair value, USDC 6dp)
#   floor  = fair6 × (1 − maxSlippageBps/1e4)                     (the ON-CHAIN BelowOracleFloor bound)
#   quote  = router.getAmountsOut(aeroBal, AERO→USDC volatile)    (what the venue will actually fill)
# Pass minUsdcOut = max(floor, quote × (1 − slack)). It MUST be nonzero: `minUsdcOut == 0` reverts
# ZeroMinOut() (0x2870c094) BEFORE the zero-AERO early return, so even a no-op harvest needs a floor.
cmd_quote() {
  local g tid earned bal price slip q claimable
  g="$(gauge)"; tid="$(num "$(tokenid)")"
  # NB: 18dp AERO amounts exceed bash's signed-64-bit arithmetic — do ALL the math in python.
  earned="$(num "$(c "$g" 'earned(address,uint256)(uint256)' "$STRAT" "$tid")")"
  bal="$(num "$(c "$AERO" 'balanceOf(address)(uint256)' "$STRAT")")"
  price="$(num "$(c "$AERO_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p)")"
  slip="$(num "$(lay 24)")"
  claimable="$(python3 -c "print($earned+$bal)")"
  q="$(c "$AERO_V2_ROUTER" 'getAmountsOut(uint256,(address,address,bool,address)[])(uint256[])' \
        "$claimable" "[($AERO,$USDC,false,$AERO_V2_FACTORY)]" 2>/dev/null \
        | tr -d '[]' | tr ',' '\n' | sed -n 2p | awk '{print $1}')"
  python3 - "$earned" "$bal" "$price" "$slip" "${q:-0}" <<'PY'
import sys
earned, bal, price, slip, q = (int(x) for x in sys.argv[1:6])
claimable = earned + bal
fair  = claimable * price // 10**20                  # manager step 2: mulDiv(aeroBal, price8, 1e20)
floor = fair * (10000 - slip) // 10000               # BelowOracleFloor bound
print(f"AERO earned (gauge)     {earned}   ({earned/1e18:,.6f} AERO)")
print(f"AERO idle (strategy)    {bal}")
print(f"AERO claimable total    {claimable}   ({claimable/1e18:,.6f} AERO)")
print(f"AERO/USD (8dp)          {price}   (${price/1e8:.8f})")
print(f"maxSlippageBps          {slip}")
print(f"oracle fair (USDC 6dp)  {fair}   (${fair/1e6:,.6f})")
print(f"BelowOracleFloor bound  {floor}   (${floor/1e6:,.6f})")
print(f"router quote (USDC 6dp) {q}   (${q/1e6:,.6f})")
if fair:
    print(f"quote / oracle fair     {q/fair*100:.4f}%   (venue basis + v2 fee)")
    print(f"quote / floor           {q/floor*100:.4f}%   ({'PASSES' if q>=floor else 'WOULD REVERT BelowOracleFloor'})")
sug = max(floor, q * 995 // 1000)
print(f"SUGGESTED minUsdcOut    {sug}   (max(floor, quote−0.5%))")
PY
}

# ─────────────────────────────────────────────────────────────────────────────── compound
cmd_compound() {
  local minOut="$1" minLiq="${2:-0}" out
  echo "compound($minOut, $minLiq) as proposer $PROPOSER"
  out="$(cast send "$STRAT" 'compound(uint256,uint256)' "$minOut" "$minLiq" \
        --from "$PROPOSER" --unlocked --gas-limit 14000000 --rpc-url "$RPC" --json 2>&1)"
  echo "$out" | receipt || { echo "  REVERT — raw:"; echo "$out" | tail -5; return 1; }
}

# Proves `BelowOracleFloor()` (0xc872b206) WITHOUT touching state: an `eth_call` that swaps the
# AERO/USD feed's code for the leg-A/USD FreshFeed's (a far higher answer), so the derived oracle
# floor is unreachable by any venue fill. NB an absurdly high `minUsdcOut` does NOT test this — the
# Aerodrome router's own `InsufficientOutputAmount()` (0x42301c23) fires first.
cmd_floor_probe() {
  local code out
  code="$(cast code "$LEGA_FEED" --rpc-url "$RPC" 2>/dev/null)"
  echo "override $AERO_FEED code <- $LEGA_FEED (leg-A/USD FreshFeed), then eth_call compound(1,0)"
  out="$(cast call --from "$PROPOSER" --override-code "$AERO_FEED:$code" \
         "$STRAT" 'compound(uint256,uint256)' 1 0 --rpc-url "$RPC" 2>&1)"
  echo "$out" | sed 's/^/  /'
  if echo "$out" | grep -q 0xc872b206; then echo "  ✓ BelowOracleFloor() — the oracle band is enforced"
  else echo "  ✗ expected 0xc872b206 (needs nonzero claimable AERO — harvest first, probe before compounding)"; return 1; fi
}

cmd_compound_expect_revert() {
  local minOut="$1" minLiq="${2:-0}" out
  echo "compound($minOut, $minLiq) — expecting a typed revert"
  out="$(cast call "$STRAT" 'compound(uint256,uint256)' "$minOut" "$minLiq" \
        --from "$PROPOSER" --rpc-url "$RPC" 2>&1)"
  echo "$out" | sed 's/^/  /'
  local sel; sel="$(echo "$out" | grep -oE '0x[0-9a-f]{8}' | head -1)"
  [[ -n "$sel" ]] && echo "  selector $sel"
}

# ─────────────────────────────────────────────────────────────────────────────── snap
cmd_snap() {
  local label="${1:-snapshot}" ts bn g tid
  bn="$(cast block-number --rpc-url "$RPC" 2>/dev/null)"; ts="$(head_ts)"
  g="$(gauge)"; tid="$(num "$(tokenid)")"
  echo "############ $label ############"
  echo "block $bn   head ts $ts   ($(python3 -c "import datetime;print(datetime.datetime.fromtimestamp($ts,datetime.timezone.utc).isoformat())"))"
  echo "-- strategy --"
  echo "state                 $(c "$STRAT" 'state()(uint8)')"
  echo "nav (USDC 6dp)        $(num "$(c "$STRAT" 'nav()(uint256)')")"
  echo "idle USDC             $(num "$(c "$USDC" 'balanceOf(address)(uint256)' "$STRAT")")"
  echo "idle AERO             $(num "$(c "$AERO" 'balanceOf(address)(uint256)' "$STRAT")")"
  echo "protocolFeeOwed       $(num "$(lay 34)")"
  echo "hwmPerShare           $(num "$(lay 32)")"
  echo "lastFeeAccrual        $(num "$(lay 33)")"
  echo "targetLtvBps          $(num "$(lay 21)")"
  echo "-- vault shares (12dp) --"
  echo "totalSupply           $(num "$(c "$VAULT" 'totalSupply()(uint256)')")"
  echo "feeRecipient shares   $(num "$(c "$VAULT" 'balanceOf(address)(uint256)' "$(lay 31)")")"
  echo "-- venue --"
  echo "collateral/debt USDC  $(c --from "$STRAT" "$STRAT" 'previewCollateralDebt()(uint256,uint256)' | tr '\n' ' ')"
  local dbtA hedA hedB
  dbtA="$(num "$(c "$(lay 4)" 'borrowBalanceStored(address)(uint256)' "$STRAT")")"
  # THE HEDGE MEASURE (b9ea6ac): drift = borrowBalanceStored - hedgedDebtA is the UNHEDGED accrued
  # borrow interest. Price-independent by construction, so it isolates interest from the LP's
  # price-driven leg drift. `compound` should collapse it to ~0; on the pre-fix code it grew every
  # harvest. hedgedDebt() is the additive keeper getter (selector 0xead99a57).
  hedA="$(num "$(c "$STRAT" 'hedgedDebt()(uint128,uint128)' | sed -n 1p)")"
  hedB="$(num "$(c "$STRAT" 'hedgedDebt()(uint128,uint128)' | sed -n 2p)")"
  echo "legA debt (borrowStored) $dbtA"
  echo "hedgedDebtA / B       $hedA / $hedB"
  echo "DRIFT (debt-hedgedA)  $(python3 -c "print($dbtA - $hedA)")"
  echo "gauge.earned AERO     $(num "$(c "$g" 'earned(address,uint256)(uint256)' "$STRAT" "$tid")")"
  echo "gauge staked?         $(c "$g" 'stakedContains(address,uint256)(bool)' "$STRAT" "$tid")"
  echo "tokenId               $tid"
  echo "npm liquidity         $(c "$NPM" 'positions(uint256)(uint96,address,address,address,int24,int24,int24,uint128,uint256,uint256,uint128,uint128)' "$tid" | sed -n 8p)"
  echo "pool tick             $(c "$POOL" 'slot0()(uint160,int24,uint16,uint16,uint16,bool)' | sed -n 2p)"
}

case "${1:-}" in
  snap)                     shift; cmd_snap "$@" ;;
  check-feeds)              cmd_check_feeds ;;
  gauge)                    cmd_gauge ;;
  arm)                      cmd_arm ;;
  warp)                     cmd_warp "$2" ;;
  warp-to-finish)           cmd_warp_to_finish ;;
  quote)                    cmd_quote ;;
  compound)                 shift; cmd_compound "$@" ;;
  compound-expect-revert)   shift; cmd_compound_expect_revert "$@" ;;
  floor-probe)              cmd_floor_probe ;;
  *) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
