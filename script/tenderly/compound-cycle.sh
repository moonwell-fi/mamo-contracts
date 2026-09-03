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
# Price movement (see "Which price drives what" in docs/integrations/LEVERAGED_AERO_REBALANCER.md §H):
#   ./compound-cycle.sh calm                   # spot tick vs pool TWAP vs calmDeviationTicks — PASS/FAIL
#   ./compound-cycle.sh move-pool <tick>       # real swap through the LP pool to land on <tick>
#   ./compound-cycle.sh move-feed <asset> <ans>  # asset = legA|legB|usdc|aero; ans at the feed's decimals
#   ./compound-cycle.sh move-price <tick>      # THE ONE-SHOT: move-pool → warp twapWindow → move-feed → calm
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
# LEVERAGED_AERO_ADMIN_RPC_URL wins over TENDERLY_VNET_RPC_URL. Historically the latter named a
# DIFFERENT vnet (the LPV2 one), so the two had to be kept apart; since 2026-08-19 both names
# resolve to the shared leveraged-aero instance (chainId 73578453) and .env says to keep them in
# sync. The preference order is retained so an explicit override still wins. Pointing this script
# at the wrong instance is caught by `check-feeds` (a non-FreshFeed instance fails the gate).
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

# NB: keep in lockstep with LeveragedAerodromeCLStrategy.LayoutView — BOTH arity and field ORDER.
# 48 fields. `uint16 skewBps` sits AFTER `legBIsAsset` — field 43, NOT next to the width band
# (`width`/`minWidth`/`maxWidth`, 39/40/41) where you would expect it — and the skew GOVERNANCE BAND
# (`uint16 minSkewBps`, `uint16 maxSkewBps`) follows it at 44/45, ahead of the two hedgedDebt fields
# at 46/47 and `bytes32 stagedVenueHash` LAST at 48. A short or mis-ordered signature here makes
# `cast call` fail to decode and every `lay N` read comes back empty — if `lay` starts returning
# nothing, check this line FIRST; `forge inspect LeveragedAerodromeCLStrategy abi` is the authority.
# (`lay N` is 1-BASED over the comma-split tuple, so field N == LayoutView member N-1. Appends land
# at the END, but a REMOVAL shifts every later index down — the fee-layer swap dropped four fields
# (`managementFeeBps`, `performanceFeeBps`, `hwmPerShare`, `lastFeeAccrualTimestamp`) and added one
# (`compoundFeeBps` at 29, ahead of `feeRecipient` at 30), which is why the tail numbers above are
# three lower than they used to be — 51 → 48.)
LAYOUT_SIG='layout()((address,address,address,address,address,address,address,address,address,address,address,uint256,uint256,uint16,uint32,address,address,address,address,int24,uint16,uint16,uint16,uint16,uint16,uint256,int24,int24,uint16,address,address,uint256,uint8,uint8,bool,bool,int24,int24,uint24,uint24,uint24,bool,uint16,uint16,uint16,uint128,uint128,bytes32))'

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

# ═══════════════════════════════════════════════════════════════ pool / tick primitives
# Used by calm, move-pool, move-feed and move-price. Everything is read off the live pool — the
# instance rotates and the LP pool is per-clone (`lpPool` in leveraged-aero-vnet.json), so nothing
# about the venue's token ordering or decimals may be assumed.

slot0() { c "$POOL" 'slot0()(uint160,int24,uint16,uint16,uint16,bool)'; }
spot_tick() { num "$(slot0 | sed -n 2p)"; }
spot_sqrt() { num "$(slot0 | sed -n 1p)"; }

POOL_T0="" POOL_T1="" POOL_D0="" POOL_D1="" POOL_S0="" POOL_S1=""
pool_tokens() {
  [[ -n "$POOL_T0" ]] && return 0
  POOL_T0="$(c "$POOL" 'token0()(address)')"; POOL_T1="$(c "$POOL" 'token1()(address)')"
  POOL_D0="$(num "$(c "$POOL_T0" 'decimals()(uint8)')")"; POOL_D1="$(num "$(c "$POOL_T1" 'decimals()(uint8)')")"
  POOL_S0="$(c "$POOL_T0" 'symbol()(string)' | tr -d '"')"; POOL_S1="$(c "$POOL_T1" 'symbol()(string)' | tr -d '"')"
  [[ -n "$POOL_D0" && -n "$POOL_D1" ]] || { echo "could not read pool token decimals off $POOL"; return 1; }
}

# Mean tick over `<window>` seconds, computed EXACTLY as LeveragedAeroValuation.calmGate does:
# (cum[now] − cum[window ago]) / window, rounded toward negative infinity when it does not divide
# evenly (the Uniswap convention). Python's `//` already floors, so it matches the Solidity
# `if (delta < 0 && delta % w != 0) twapTick--` correction with no extra branch. Off-by-one here
# would silently mis-report the calm-gate margin, which is the number people act on.
twap_tick() {
  local w="$1" line c0 c1
  line="$(c "$POOL" 'observe(uint32[])(int56[],uint160[])' "[$w,0]" | sed -n 1p | tr -d '[]')"
  [[ -n "$line" ]] || { echo "pool.observe([$w,0]) reverted on $POOL — state-synced vnet? see runbook" >&2; return 1; }
  c0="$(num "$(echo "$line" | tr ',' '\n' | sed -n 1p | sed 's/^ *//')")"
  c1="$(num "$(echo "$line" | tr ',' '\n' | sed -n 2p | sed 's/^ *//')")"
  python3 -c "print((($c1) - ($c0)) // $w)"
}

# tick → sqrtPriceX96 = floor(sqrt(1.0001^tick) · 2^96).
#
# Decimal at 80 digits, NOT floats: sqrtPriceX96 here is ~3.1e27, which a double's 53-bit mantissa
# cannot represent to better than ~1e11 — hundreds of ticks of error at these magnitudes.
#
# LIVE CROSS-CHECK (the reason to trust it): at spot tick −64796 this returns
#   3104006828174357832433965996   vs the pool's live slot0().sqrtPriceX96
#   3104046187183545523226514787   → +0.00127 %, i.e. an eighth of one 0.01 %-wide tick. That gap is
# expected and correct: sqrtRatioAtTick(t) is the price at the tick's LOWER edge, and the live price
# sits partway between tick −64796 and −64795. A wrong implementation is off by whole percent.
sqrt_at_tick() {
  python3 -c "
from decimal import Decimal, getcontext
getcontext().prec = 80
print(int((Decimal('1.0001') ** ($1)).sqrt() * (Decimal(2) ** 96)))
"
}

# Uniswap-v3 tick / sqrt-price domain (TickMath). A target outside this is rejected by the pool.
MIN_TICK=-887272
MAX_TICK=887272

# tick → the leg-A/USD answer the pool implies, at <feedDecimals> fixed point.
#
# DERIVATION. In the Uniswap/Slipstream convention `1.0001^tick` is RAW token1 per RAW token0 — i.e.
# the price OF token0 QUOTED IN token1. Converting to whole units rescales by the decimal difference:
#
#     price(token0 in token1, whole units) = 1.0001^tick · 10^(d0 − d1)
#
# Which of the two legs is token0 therefore decides whether that is already what we want or its
# reciprocal, so `pool.token0()` is load-bearing and is read live:
#
#   • token0 == USDC  → 1.0001^tick prices USDC in leg A, so leg A/USD is the RECIPROCAL:
#         legA_usd = 1.0001^(−tick) · 10^(d1 − d0)
#   • token0 == leg A → 1.0001^tick already prices leg A in USDC:
#         legA_usd = 1.0001^(tick)  · 10^(d0 − d1)
#
# Then scale by 10^feedDecimals. USDC is taken as exactly $1: the USDC/USD feed reads 0.99979, a 2 bp
# gap that is an order of magnitude inside maxSlippageBps (100 bp) and not worth propagating.
#
# LIVE CROSS-CHECK. This pool is token0 = USDC (6dp) / token1 = cbBTC (8dp), so the first branch
# applies and reduces to 100 · 1.0001^(−tick). At the live spot tick −64796 that is $65,149.91 →
# 6514991172390 at 8dp, against the live leg-A/USD FreshFeed answer 6514631800000 ($65,146.32):
# +0.0055 %, about half a tick of pool-mid-vs-Chainlink basis. If an edit here makes the live tick
# disagree with the live feed by more than ~0.1 %, the conversion is wrong — do not ship it.
usd_at_tick() { # usd_at_tick <tick> <feedDecimals>
  pool_tokens || return 1
  python3 - "$1" "$2" "$POOL_T0" "$USDC" "$POOL_D0" "$POOL_D1" <<'PY'
import sys
from decimal import Decimal, getcontext
getcontext().prec = 60
tick, fdec = int(sys.argv[1]), int(sys.argv[2])
t0, usdc = sys.argv[3].lower(), sys.argv[4].lower()
d0, d1 = int(sys.argv[5]), int(sys.argv[6])
r = Decimal('1.0001') ** tick
p = (1 / r) * (Decimal(10) ** (d1 - d0)) if t0 == usdc else r * (Decimal(10) ** (d0 - d1))
print(int(p * (Decimal(10) ** fdec)))
PY
}

# ── vnet-only harness identities ────────────────────────────────────────────────────────────
# The swap helper lives at a CONSTANT address, placed by `tenderly_setCode` rather than remembered
# from a deploy. TenderlySwapHelper is storage-free — it holds only token balances and reads
# `msg.sender` in the pool callback — so code-only placement is sound, the same argument that makes
# the FreshFeed override sound. That keeps `move-pool` idempotent and stateless: no address cache
# file to go stale when the instance rotates, and no deploy tx after the first run.
# HARNESS_EOA is a throwaway broadcaster for the harness's own txs, kept SEPARATE from $PROPOSER so
# pool swaps can never be confused with rebalancer activity in the vnet tx history.
HARNESS_SWAPPER=0x5ca1ab1e00000000000000000000000000000001
HARNESS_EOA=0x5ca1ab1e00000000000000000000000000000002
SWAPPER_ART="$ROOT/out/TenderlySwapHelper.sol/TenderlySwapHelper.json"
FRESHFEED_ART="$ROOT/out/FreshFeed.sol/FreshFeed.json"

# 100 ETH by default. Hex via python, not printf: 1e20 wei overflows bash's signed-64-bit arithmetic.
fund_eth() { rpc tenderly_setBalance "[[\"$1\"],\"$(python3 -c "print(hex(${2:-100 * 10**18}))")\"]" >/dev/null; }
fund_erc20() { rpc tenderly_setErc20Balance "[\"$1\",\"$2\",\"$3\"]" >/dev/null; }

# Ensure the swap-callback holder exists at HARNESS_SWAPPER. Uses the artifact's `deployedBytecode`
# directly (valid ONLY because the helper declares no immutables — a placeholder-bearing artifact
# would need the deploy-then-copy dance `move-feed` does for FreshFeed).
ensure_swapper() {
  local code
  code="$(cast code "$HARNESS_SWAPPER" --rpc-url "$RPC" 2>/dev/null)"
  if [[ -n "$code" && "$code" != "0x" ]]; then echo "swap helper already at $HARNESS_SWAPPER"; return 0; fi
  [[ -f "$SWAPPER_ART" ]] || (cd "$ROOT" && forge build script/tenderly/TenderlySwapHelper.sol >/dev/null 2>&1)
  [[ -f "$SWAPPER_ART" ]] || { echo "missing $SWAPPER_ART — run: forge build script/tenderly/TenderlySwapHelper.sol"; return 1; }
  local runtime; runtime="$(jq -r '.deployedBytecode.object' "$SWAPPER_ART")"
  [[ -n "$runtime" && "$runtime" != "null" ]] || { echo "artifact has no deployedBytecode"; return 1; }
  rpc tenderly_setCode "[\"$HARNESS_SWAPPER\",\"$runtime\"]" >/dev/null
  code="$(cast code "$HARNESS_SWAPPER" --rpc-url "$RPC" 2>/dev/null)"
  [[ -n "$code" && "$code" != "0x" ]] || { echo "tenderly_setCode did not land on $HARNESS_SWAPPER"; return 1; }
  echo "swap helper installed at $HARNESS_SWAPPER (tenderly_setCode, $((${#runtime} / 2)) bytes)"
}

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
#
# NET OF THE SKIM throughout. `compoundImpl` transfers `compoundFeeBps` (field 29) of the tranche to
# `feeRecipient` PRE-SWAP and prices BOTH bounds on the remainder, so every number below is derived
# from `sellAmt = claimable × (1e4 − compoundFeeBps)/1e4` — the amount the router actually receives.
# Quoting the gross tranche instead overstates by that fraction and the router fires
# InsufficientOutputAmount() (0x42301c23). The on-chain floor also divides by the USDC/USD peg leg
# rather than assuming 1.00, so `floor` here approximates the bound rather than reproducing it.
cmd_quote() {
  local g tid earned bal price slip fee q claimable sell
  g="$(gauge)"; tid="$(num "$(tokenid)")"
  # NB: 18dp AERO amounts exceed bash's signed-64-bit arithmetic — do ALL the math in python.
  earned="$(num "$(c "$g" 'earned(address,uint256)(uint256)' "$STRAT" "$tid")")"
  bal="$(num "$(c "$AERO" 'balanceOf(address)(uint256)' "$STRAT")")"
  price="$(num "$(c "$AERO_FEED" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p)")"
  slip="$(num "$(lay 24)")"
  fee="$(num "$(lay 29)")"
  claimable="$(python3 -c "print($earned+$bal)")"
  sell="$(python3 -c "print(($claimable*(10000-$fee))//10000)")"
  q="$(c "$AERO_V2_ROUTER" 'getAmountsOut(uint256,(address,address,bool,address)[])(uint256[])' \
        "$sell" "[($AERO,$USDC,false,$AERO_V2_FACTORY)]" 2>/dev/null \
        | tr -d '[]' | tr ',' '\n' | sed -n 2p | awk '{print $1}')"
  python3 - "$earned" "$bal" "$price" "$slip" "${q:-0}" "$fee" <<'PY'
import sys
earned, bal, price, slip, q, fee = (int(x) for x in sys.argv[1:7])
claimable = earned + bal
sell  = claimable * (10000 - fee) // 10000           # manager step 2: the post-skim sell amount
fair  = sell * price // 10**20                       # ~manager step 3 (peg-less approximation)
floor = fair * (10000 - slip) // 10000               # BelowOracleFloor bound
print(f"AERO earned (gauge)     {earned}   ({earned/1e18:,.6f} AERO)")
print(f"AERO idle (strategy)    {bal}")
print(f"AERO claimable total    {claimable}   ({claimable/1e18:,.6f} AERO)")
print(f"compoundFeeBps          {fee}   (skim {claimable-sell} == {(claimable-sell)/1e18:,.6f} AERO)")
print(f"AERO sold (post-skim)   {sell}   ({sell/1e18:,.6f} AERO)")
print(f"AERO/USD (8dp)          {price}   (${price/1e8:.8f})")
print(f"maxSlippageBps          {slip}")
print(f"oracle fair (USDC 6dp)  {fair}   (${fair/1e6:,.6f})")
print(f"BelowOracleFloor bound  {floor}   (${floor/1e6:,.6f})")
print(f"router quote (USDC 6dp) {q}   (${q/1e6:,.6f})")
if fair:
    print(f"quote / oracle fair     {q/fair*100:.4f}%   (venue basis + v2 fee)")
    print(f"quote / floor           {q/floor*100:.4f}%   ({'PASSES' if q>=floor else 'WOULD REVERT BelowOracleFloor'})")
sug = max(floor, q * 995 // 1000)
print(f"SUGGESTED minUsdcOut    {sug}   (max(floor, quote−0.5%), post-skim — use as-is)")
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

# ═══════════════════════════════════════════════════════════ price movement (calm / move-*)
# WHY THIS EXISTS. A rebalance test on the vnet needs FOUR coordinated steps (see
# docs/integrations/LEVERAGED_AERO_REBALANCER.md §H). The Chainlink mock and the pool tick are
# INDEPENDENT price sources driving different things:
#   • the FEED drives nav()/valuation, slippage floors and `BelowOracleFloor`, hedge sizing, the
#     staleness gate, health/LTV;
#   • the POOL TICK drives LP leg composition, in/out-of-range, where `rerange` anchors the new range
#     (it brackets the pool tick, split by `skewBps` — 5000 = centered), and the realized swap price;
#   • `calmGate` reads NO feed at all — it compares pool spot against the pool's OWN TWAP.
# So moving exactly one of them fails closed, in two different ways: pool-only reverts
# `CalmGateBreached` until the TWAP catches up and then `BelowOracleFloor` because the oracle is
# still on the old price; feed-only moves the fund's accounting while the position has not moved at
# all, and its swaps then revert `BelowOracleFloor` too. `move-price` is the composition that keeps
# all three in agreement — it is what you want 95 % of the time. `move-pool` and `move-feed` are the
# halves, exposed for scenarios that deliberately want them OUT of agreement (e.g. proving the gate).

# ─────────────────────────────────────────────────────────────────────────────── calm
# The read people run constantly: does a priced path pass `calmGate` right now? Read-only, no txs.
cmd_calm() {
  local w cd spot twap diff lo hi
  w="$(num "$(lay 15)")"; cd="$(num "$(lay 14)")"
  lo="$(num "$(lay 27)")"; hi="$(num "$(lay 28)")"
  spot="$(spot_tick)"; twap="$(twap_tick "$w")" || return 1
  diff=$(( spot > twap ? spot - twap : twap - spot ))
  echo "pool                $POOL"
  echo "spot tick           $spot"
  echo "TWAP tick (${w}s)   $twap"
  # 1 tick = 1.0001x = 0.01 %; the compounding matters by 500 ticks (5.13 %, not 5.00 %).
  echo "|spot - twap|       $diff ticks  ($(python3 -c "print(f'{(1.0001**$diff - 1) * 100:.3f}')") %)"
  echo "calmDeviationTicks  $cd"
  # `calmGate` reverts on `>` (strictly greater), so diff == calmDeviationTicks still passes.
  if (( diff > cd )); then
    echo ">> FAIL — every priced path reverts CalmGateBreached. Warp >= ${w}s and re-check."
  else
    echo ">> PASS — calmGate is satisfied ($((cd - diff)) ticks of headroom); a rebalance can run."
  fi
  if (( spot < lo || spot > hi )); then
    echo "position range      $lo / $hi  ->  spot is OUT OF RANGE (single-sided; rerange to reposition (width + skew))"
  else
    echo "position range      $lo / $hi  ->  spot is in range"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────── move-pool
# Swap the LP pool onto a target tick.
#
# THE TRICK — no binary search on the input amount. `sqrtPriceLimitX96` is a hard stop the pool
# honours mid-swap, so setting the limit to sqrtRatioAtTick(target) and passing an effectively
# unbounded exact input makes the pool walk its ticks and halt EXACTLY at the target. One tx, exact
# landing, no iteration. The input amount only has to be large enough not to bind before the limit
# does — hence the deliberately over-generous funding below (unspent balance is harmless).
#
# DIRECTION is token-ordering INDEPENDENT: in the v3 convention price = token1/token0, so selling
# token0 always lowers sqrtPrice and therefore the tick. `zeroForOne = target < current`, always.
# What token ordering DOES change is the economic meaning (which asset got cheaper), so token0/token1
# are read live and printed by symbol, and the limit is asserted to be on the correct side of the
# live sqrtPrice — the pool would otherwise revert `SPL` and burn a tx to tell us the same thing.
cmd_move_pool() {
  local target="$1"
  echo "$target" | grep -qE '^-?[0-9]+$' || { echo "move-pool <target-tick>: '$target' is not an integer"; return 1; }
  (( target > MIN_TICK && target < MAX_TICK )) || { echo "target tick $target outside TickMath domain"; return 1; }
  pool_tokens || return 1
  local cur curSqrt lim z0 inTok inSym inDec amtIn spent out after
  cur="$(spot_tick)"; curSqrt="$(spot_sqrt)"
  [[ -n "$cur" && -n "$curSqrt" ]] || { echo "could not read slot0 off $POOL"; return 1; }
  if (( target == cur )); then echo "pool already at tick $cur — nothing to do"; return 0; fi

  lim="$(sqrt_at_tick "$target")"
  if (( target < cur )); then z0=true; inTok="$POOL_T0"; inSym="$POOL_S0"; inDec="$POOL_D0"
  else                        z0=false; inTok="$POOL_T1"; inSym="$POOL_S1"; inDec="$POOL_D1"; fi
  # A previous move-pool halts EXACTLY at its limit price, so re-running the same target is a genuine
  # no-op — the spot tick may read one below the target (boundary rounding) while the price is already
  # there. Return success, don't fail: `move-price` must be re-runnable without aborting steps 2–4.
  if [[ "$lim" == "$curSqrt" ]]; then
    echo "pool already sits exactly at the sqrt price for tick $target (spot tick $cur) — no swap needed"
    echo
    cmd_calm
    return 0
  fi
  # Guard the pool's own SPL precondition before spending a tx on it.
  python3 -c "
import sys
cur, lim, z0 = $curSqrt, $lim, '$z0' == 'true'
sys.exit(0 if ((lim < cur) if z0 else (lim > cur)) else 1)
" || { echo "sqrt limit $lim is on the wrong side of live sqrtPrice $curSqrt — pool would revert SPL"; return 1; }

  echo "pool  $POOL   token0 $POOL_S0 (${POOL_D0}dp)  token1 $POOL_S1 (${POOL_D1}dp)"
  echo "tick  $cur -> target $target   (delta $((target - cur)) ticks)"
  echo "swap  zeroForOne=$z0  selling $inSym  sqrtPriceLimitX96=$lim  (live sqrt $curSqrt)"

  ensure_swapper || return 1
  fund_eth "$HARNESS_EOA"
  # Fund BOTH legs: the helper pays whichever side the callback asks for, and a later move in the
  # opposite direction reuses the same balances. 1e8 whole units each — it only has to dominate the
  # pool's depth over the requested tick span, and leftover vnet balance costs nothing.
  fund_erc20 "$POOL_T0" "$HARNESS_SWAPPER" "$(python3 -c "print(hex(10 ** ($POOL_D0 + 8)))")"
  fund_erc20 "$POOL_T1" "$HARNESS_SWAPPER" "$(python3 -c "print(hex(10 ** ($POOL_D1 + 8)))")"
  amtIn="$(num "$(c "$inTok" 'balanceOf(address)(uint256)' "$HARNESS_SWAPPER")")"
  echo "helper $HARNESS_SWAPPER funded; amountIn = full $inSym balance ($amtIn) — the limit binds, not this"

  out="$(cast send "$HARNESS_SWAPPER" 'doSwap(address,bool,uint256,uint160)' "$POOL" "$z0" "$amtIn" "$lim" \
        --from "$HARNESS_EOA" --unlocked --gas-limit 12000000 --rpc-url "$RPC" --json 2>&1)"
  echo "$out" | receipt || { echo "  REVERT — raw:"; echo "$out" | tail -5; return 1; }

  after="$(spot_tick)"
  spent="$(python3 -c "print($amtIn - $(num "$(c "$inTok" 'balanceOf(address)(uint256)' "$HARNESS_SWAPPER")"))")"
  echo "tick  $cur -> $after   (realized delta $((after - cur)) ticks; target was $target, residual $((after - target)))"
  echo "spent $spent $inSym raw ($(python3 -c "print(f'{$spent / 10**$inDec:,.6f}')") whole) — the rest of the funding was never touched"
  # Success is "within one tick", not exact equality. The pool halts at exactly our limit price, but
  # our limit is computed from real sqrt() while the pool reads it back through TickMath's fixed-point
  # `getTickAtSqrtRatio`; a few wei of disagreement at the tick boundary lands us one tick either
  # side. Observed: target −64600 → landed −64601. One tick is 0.01 %, so this is noise. A miss of
  # MORE than a tick is the real failure, and means the input amount bound before the limit did.
  local miss=$(( after - target ))
  if (( miss < 0 )); then miss=$(( -miss )); fi
  if (( miss <= 1 )); then
    echo ">> target REACHED (the sqrt-price limit bound the swap; +/-1 tick is TickMath boundary rounding)"
  else
    echo ">> target NOT reached — off by $miss ticks, i.e. the input amount bound before the price"
    echo "   limit did. Raise the funding exponent in cmd_move_pool, or move in smaller hops."
  fi
  echo
  cmd_calm
}

# ─────────────────────────────────────────────────────────────────────────────── move-feed
# Replace a FreshFeed with a new answer. The answer is an `immutable` — THERE IS NO SETTER — so
# "moving" a feed means deploying a fresh FreshFeed and `tenderly_setCode`-ing its runtime over the
# same address. Sound only because FreshFeed is storage-free (immutables only), so the answer travels
# inline in the code and nothing has to be migrated. See FreshFeed.sol's contract docs.
#
# `decimals()` is read off the REPLACED feed rather than assumed 8: `_initialize` asserts
# `aeroUsdFeed.decimals() == 8` (`UnexpectedFeedDecimals`) and `_readUsd8` re-checks the others at
# read time, so a mismatched replacement bricks every priced path.
cmd_move_feed() {
  local asset="$1" answer="$2" feed label
  case "$(echo "$asset" | tr 'A-Z' 'a-z')" in
    lega|legausd|lega/usd) feed="$LEGA_FEED"; label="legA/USD" ;;
    legb|legbusd|legb/usd) feed="$LEGB_FEED"; label="legB/USD" ;;
    usdc|usdcusd|usdc/usd) feed="$USDC_FEED"; label="USDC/USD" ;;
    aero|aerousd|aero/usd) feed="$AERO_FEED"; label="AERO/USD" ;;
    *) echo "move-feed <legA|legB|usdc|aero> <answer-at-feed-decimals>"; return 1 ;;
  esac
  echo "$answer" | grep -qE '^-?[0-9]+$' || { echo "move-feed: answer '$answer' is not an integer"; return 1; }

  local dec old code args deployed runtime got
  dec="$(num "$(c "$feed" 'decimals()(uint8)')")"
  old="$(num "$(c "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p)")"
  [[ -n "$dec" ]] || { echo "cannot read decimals() off $feed — is it FreshFeed-overridden?"; return 1; }

  echo "$label feed $feed   decimals $dec (read live, not assumed)"
  echo "answer $old -> $answer   $(python3 -c "print(f'(\${$old / 10**$dec:,.8f} -> \${$answer / 10**$dec:,.8f})')")"
  # On an asset-mode clone (legBIsAsset) legB/USD and USDC/USD are the SAME aggregator, so a legB
  # move silently moves USDC/USD too. Say so rather than let it surprise someone.
  for other in "legA/USD:$LEGA_FEED" "legB/USD:$LEGB_FEED" "USDC/USD:$USDC_FEED" "AERO/USD:$AERO_FEED"; do
    local on="${other%%:*}" oa="${other##*:}"
    [[ "$oa" == "$feed" && "$on" != "$label" ]] && echo "NOTE: $oa is ALSO the $on feed — that slot moves too"
  done

  [[ -f "$FRESHFEED_ART" ]] || (cd "$ROOT" && forge build script/tenderly/FreshFeed.sol >/dev/null 2>&1)
  [[ -f "$FRESHFEED_ART" ]] || { echo "missing $FRESHFEED_ART — run: forge build script/tenderly/FreshFeed.sol"; return 1; }
  code="$(jq -r '.bytecode.object' "$FRESHFEED_ART")"
  [[ -n "$code" && "$code" != "null" ]] || { echo "FreshFeed artifact has no bytecode"; return 1; }
  args="$(cast abi-encode 'ctor(int256,uint8)' "$answer" "$dec")"
  fund_eth "$HARNESS_EOA"
  # Unlike the swap helper this CANNOT use the artifact's deployedBytecode: the answer is an
  # immutable, so the runtime code only carries it after a real construction. Deploy, then copy.
  # NOTE flag ORDER — every option must precede `--create`, which greedily eats the rest of argv.
  deployed="$(cast send --from "$HARNESS_EOA" --unlocked --rpc-url "$RPC" --json \
    --create "${code}${args#0x}" 2>/dev/null | python3 -c 'import json,sys
raw = sys.stdin.read(); i = raw.find("{")
print(json.loads(raw[i:])["contractAddress"] if i >= 0 else "")')"
  [[ -n "$deployed" && "$deployed" != "null" ]] || { echo "FreshFeed deploy failed"; return 1; }
  runtime="$(cast code "$deployed" --rpc-url "$RPC" 2>/dev/null)"
  [[ -n "$runtime" && "$runtime" != "0x" ]] || { echo "deployed FreshFeed has no runtime code"; return 1; }
  rpc tenderly_setCode "[\"$feed\",\"$runtime\"]" >/dev/null
  got="$(num "$(c "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p)")"
  [[ "$got" == "$answer" ]] || { echo "override did NOT land: $feed still reports $got"; return 1; }
  echo "$label <- FreshFeed(answer=$answer, decimals=$dec)  [mock deployed at $deployed]"
  echo
  cmd_check_feeds
}

# ─────────────────────────────────────────────────────────────────────────────── move-price
# The one-shot: the whole four-step §H procedure, with pool, TWAP and oracle left in agreement.
# Move the pool, warp past twapWindow so the averaging window sits entirely at the new spot, move
# leg-A/USD to the price the new tick implies, then re-gate the feeds and report the calm margin.
cmd_move_price() {
  local target="$1" w dec want
  echo "════ step 1/4: move the pool tick (real swap) ════"
  cmd_move_pool "$target" || return 1
  # twapWindow from layout()[15] — per-clone, never hardcoded (1800 s on the current staging clone).
  w="$(num "$(lay 15)")"
  [[ -n "$w" ]] && (( w > 0 )) || { echo "could not read twapWindow (layout()[15])"; return 1; }
  echo
  echo "════ step 2/4: warp past twapWindow (${w}s) so the TWAP converges on the new spot ════"
  cmd_warp $(( w + 60 )) || return 1
  dec="$(num "$(c "$LEGA_FEED" 'decimals()(uint8)')")"
  want="$(usd_at_tick "$target" "$dec")"
  echo
  echo "════ step 3/4: move leg-A/USD to the price tick $target implies ════"
  cmd_move_feed legA "$want" || return 1
  echo
  echo "════ step 4/4: calm-gate margin ════"
  cmd_calm
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
  echo "compoundFeeBps        $(num "$(lay 29)")"
  echo "targetLtvBps          $(num "$(lay 21)")"
  echo "-- vault shares (12dp) --"
  echo "totalSupply           $(num "$(c "$VAULT" 'totalSupply()(uint256)')")"
  echo "feeRecipient AERO     $(num "$(c "$AERO" 'balanceOf(address)(uint256)' "$(lay 30)")")"
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
  calm)                     cmd_calm ;;
  move-pool)                cmd_move_pool "${2:?move-pool <target-tick>}" ;;
  move-feed)                cmd_move_feed "${2:?move-feed <legA|legB|usdc|aero> <answer>}" "${3:?move-feed <asset> <answer>}" ;;
  move-price)               cmd_move_price "${2:?move-price <target-tick>}" ;;
  # Usage = the header comment block, scraped rather than a hardcoded line range, so adding a
  # subcommand can never leave the printed usage silently truncated.
  *) awk 'NR > 1 && /^#/ { print } /^set -uo pipefail/ { exit }' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
