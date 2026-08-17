#!/usr/bin/env bash
# ==============================================================================
# run-leveraged-aero-stack.sh — leveraged-Aero POOLED LAYER Tenderly harness
# ==============================================================================
# Deploys the POOLED LAYER of the leveraged-Aero system to a LIVE, PERSISTENT
# Tenderly Base-fork vnet and drives it Pending -> Executed:
#
#   B.0  FreshFeed — code-replace the 5 venue Chainlink aggregators (leg A/USD,
#        leg B/USD, USDC/USD, AERO/USD, L2 sequencer uptime) with mocks whose
#        updatedAt tracks block.timestamp, via tenderly_setCode
#   B.1  deploy the LeveragedAerodromeCLStrategy TEMPLATE + the LeveragedAeroVault
#        (asset = USDC, owner = MAMO_MULTISIG) as DEPLOYER_EOA
#   B.2  ABI-encode the strategy's InitParams from the venue book (env-driven)
#   B.3  as MAMO_MULTISIG: vault.cloneAndBind(template, MAMO_REBALANCER, initData)
#        — atomic clone + initialize + bind, one owner tx
#   B.4  seed: tenderly_setErc20Balance USDC to the multisig, approve the vault,
#        vault.activateStrategy(SEED)  (pulls the seed from the CALLER, executes
#        the levered book, and mints the seeder the genesis shares)
#   B.5  post-conditions the account layer (Phase C) depends on
#
# Written spec: docs/LEVERAGED_AERO_VNET_RUNBOOK.md Phase B. The account layer is a
# SEPARATE harness (run-leveraged-aero-account.sh) that runs after this one.
#
# ── WHY --reuse IS FORCED ─────────────────────────────────────────────────────
# The pooled layer must live on the SHARED PERSISTENT vnet that all downstream
# FE/BE/keeper work points at, so this harness ALWAYS reuses TENDERLY_VNET_RPC_URL
# (the vnet's ADMIN RPC — it accepts eth_sendTransaction from any unlocked sender AND
# serves reads). It never creates or tears down a vnet: an ephemeral fork would be
# deleted with the stack on it. Create the vnet per runbook Phase A (chainId 8453
# MANDATORY, state sync DISABLED, persistent).
#
# ── NO TIME WARPING ───────────────────────────────────────────────────────────
# This script never calls evm_increaseTime. FreshFeed makes warping SAFE, but the
# pooled deploy has no reason to need it, and a warp is a shared-instance side effect.
#
# ── PRIVILEGED ROLES = UNLOCKED IMPERSONATION ─────────────────────────────────
# MAMO_MULTISIG (vault owner) and DEPLOYER_EOA are impersonated through the admin RPC;
# no private keys, so do NOT require MAMO_DEPLOYER_PRIVATE_KEY.
#
# ── PROPOSER = MAMO_REBALANCER (a NEW dedicated operator address) ──────────────
# The strategy has exactly ONE operator role (`proposer`, gating rerange / compound /
# fulfillRedeem / deleverage), and the REBALANCER SERVICE owns it. It is deliberately
# NOT MAMO_BACKEND: the Mamo backend drives the account layer, the rebalancer drives the
# pooled book, and collapsing them would hand account-layer keys the levered book's
# operator surface. The vnet default below is a throwaway keypair minted with
# `cast wallet new` and recorded here for repeatability (fork-only — the private key is
# 0x3f622d0c053a7667d220093295bb66270bd70e2725cff10e53972c553b4bfd9f, published on
# purpose so anyone can drive the rebalancer role on the vnet).
#   >>> MAINNET MUST PASS THE REAL REBALANCER OPS KEY VIA MAMO_REBALANCER. <<<
#
# Usage:
#   TENDERLY_VNET_RPC_URL=<admin-rpc> ./script/tenderly/run-leveraged-aero-stack.sh
#   make tenderly-leveraged-aero-stack
#
# Flags:
#   --reuse          accepted and implied (this harness always reuses)
#   --no-freshfeed   skip phase B.0 (an instance that already carries the mocks)
#
# Env overrides (all optional; defaults documented in the table below and mirrored in
# LeveragedAeroStackHarness.s.sol):
#   MAMO_REBALANCER  strategy proposer + default fee recipient
#   SEED             seed in USDC 6dp units (default 100000000000 = 100,000 USDC)
#   LP_POOL          Aerodrome Slipstream CL pool for the leg pair  <-- PENDING PRODUCT DECISION
#   LEG_A/LEG_B, M_LEG_A/M_LEG_B, M_USDC, COMPTROLLER, NPM, GAUGE, SWAP_ROUTER
#   LEG_A_FEED/LEG_B_FEED/USDC_FEED/AERO_FEED/SEQ_FEED
#   TICK_SPACING, LEG_A_SWAP_TICK_SPACING, LEG_B_SWAP_TICK_SPACING, WETH_DELIVERS_NATIVE
#   WIDTH/MIN_WIDTH/MAX_WIDTH, SKEW_BPS (5000 = centered — the ops default; skew is meant to be
#     applied per-cycle via `rerange`, not baked into genesis),
#   MIN_SKEW_BPS (1000) / MAX_SKEW_BPS (9000) — the INIT-IMMUTABLE governance band on skewBps, the
#     skew analogue of MIN_WIDTH/MAX_WIDTH. Validated at init AND re-checked on every rerange, and a
#     violation raises the SAME OutOfBounds() as a bad width — there is no new selector, so the
#     expected-error list below needs no new entry. Immutable per clone: widening it means redeploying.
#   TARGET_LTV_BPS/MAX_LTV_BPS/MIN_HEALTH_BPS/MAX_SLIPPAGE_BPS
#   MAX_DELAY/GRACE_PERIOD/TWAP_WINDOW/CALM_DEVIATION_TICKS
#   MGMT_FEE_BPS (100) / PERF_FEE_BPS (1000) / FEE_RECIPIENT (= MAMO_REBALANCER)
#   VAULT_NAME / VAULT_SYMBOL
#   TENDERLY_VNET_PUBLIC_RPC_URL  recorded into leveraged-aero-vnet.json
#
# Requires: forge, cast, jq, python3. Reads .env.
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$ROOT/script/tenderly/harness-results-leveraged-aero-stack.log}"
: > "$RESULTS"

HARNESS_SLUG="leveraged-aero-stack"
HARNESS_DISPLAY="Leveraged-Aero pooled layer harness"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FQ="script/tenderly/LeveragedAeroStackHarness.s.sol:LeveragedAeroStackHarness"
FRESHFEED_ART="$ROOT/out/FreshFeed.sol/FreshFeed.json"
CONFIG_JSON="$ROOT/script/tenderly/leveraged-aero-vnet.json"

# ── args ──────────────────────────────────────────────────────────────────────
# Force reuse: the pooled layer must land on the shared persistent vnet (see header).
REUSE_VNET=1
KEEP_VNET=1
DO_FRESHFEED=1
while [ $# -gt 0 ]; do
  case "$1" in
    --reuse)        REUSE_VNET=1; shift ;;
    --no-freshfeed) DO_FRESHFEED=0; shift ;;
    *) echo "unknown arg: $1 (expected: --reuse | --no-freshfeed)"; exit 2 ;;
  esac
done

# Minimal env load. This harness uses UNLOCKED impersonation, so it needs NO broadcaster
# key (do not call load_env / require MAMO_DEPLOYER_PRIVATE_KEY). A TENDERLY_VNET_RPC_URL
# passed on the COMMAND LINE must win over the .env value (which may point at an older
# vnet), so preserve a caller-set value across the source.
_CLI_VNET_RPC="${TENDERLY_VNET_RPC_URL:-}"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
[ -n "$_CLI_VNET_RPC" ] && export TENDERLY_VNET_RPC_URL="$_CLI_VNET_RPC"

# ── venue book: exported so the forge harness reads the SAME values ───────────
# These are the subset THIS script also needs (the 5 feeds for B.0, the pool for the
# log, USDC for the seed). LeveragedAeroStackHarness.s.sol carries identical defaults for
# them plus the fields only it reads (legs, Moonwell markets, NPM, gauge, router, risk /
# oracle / width+skew / fee params) — keep the two default sets in lockstep. SKEW_BPS defaults
# to 5000 (centered) on both sides, and its governance band defaults to MIN_SKEW_BPS=1000 /
# MAX_SKEW_BPS=9000 (init-immutable; re-checked on every rerange, same OutOfBounds()). Like WIDTH
# and SKEW_BPS these are read straight from the process env by LeveragedAeroStackHarness.buildInitData()
# — this script does not re-export them, so a caller override reaches the harness unchanged.
#
# ── SHAPE: which pool family this fund LPs ────────────────────────────────────
# `asset` (DEFAULT — the launch product): leg B IS the unit of account, i.e. a cbBTC/USDC
#   pool. ONE borrowed leg (cbBTC) LP'd against the fund's own USDC. Delta-neutral on
#   cbBTC by construction (LP long == debt short); the collateral USDC is the unlevered part.
# `twoleg`: two borrowed legs LP'd against each other (WETH/cbBTC) — the original shape.
#
# The strategy DERIVES the shape from config (`legBIsAsset = (legB == usdc)`) — there is no
# mode argument. Everything below is just a coherent venue book for the chosen family; the
# init guard ladder (LeveragedAerodromeCLStrategy._initialize) re-derives and re-validates
# all of it on-chain and reverts VenueMismatch / UnsupportedLeg on any inconsistency.
#
# Asset-mode pins (enforced at init, not optional): M_LEG_B == M_USDC (leg B is never
# borrowed, so its market slot must be the collateral market — this is what makes every
# borrowBalanceStored(mLegB) structurally 0), LEG_B_SWAP_TICK_SPACING == 0 (declared unused:
# there is no USDC/USDC pool and every leg-B swap is an identity early-return), and
# LEG_B_FEED == USDC_FEED (leg B prices at face). Leg A must NEVER be USDC or AERO.
SHAPE="${SHAPE:-asset}"
case "$SHAPE" in
  asset)
    # cbBTC/USDC, tickSpacing 100 — chosen for the highest liquidity AND the highest live
    # AERO emissions of the three cbBTC/USDC CL pools (ts 1 / 100 / 2000; the ts-1 gauge is
    # dead). token0 == USDC, so the strategy derives wethIsToken0 = false.
    # Note the leg-A (cbBTC) ↔ USDC swap route resolves to THIS SAME pool at ts 100, so
    # there is no second venue to trust.
    export LP_POOL="${LP_POOL:-0x4e962BB3889Bf030368F56810A9c96B83CB3E778}"
    export TICK_SPACING="${TICK_SPACING:-100}"
    export GAUGE="${GAUGE:-0x6399ed6725cC163D019aA64FF55b22149D7179A8}"
    export LEG_A="${LEG_A:-0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf}"          # cbBTC — the single borrowed leg
    export LEG_B="${LEG_B:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"          # USDC  — the unit of account == asset
    export M_LEG_A="${M_LEG_A:-0xF877ACaFA28c19b96727966690b2f44d35aD5976}"      # mcbBTC
    export M_LEG_B="${M_LEG_B:-0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22}"      # == M_USDC (pinned)
    export LEG_A_FEED="${LEG_A_FEED:-0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F}" # BTC/USD  8dp
    export LEG_B_FEED="${LEG_B_FEED:-0x7e860098F58bBFC8648a4311b374B1D669a2bc6B}" # == USDC_FEED (pinned)
    export LEG_A_SWAP_TICK_SPACING="${LEG_A_SWAP_TICK_SPACING:-100}"
    export LEG_B_SWAP_TICK_SPACING="${LEG_B_SWAP_TICK_SPACING:-0}"               # declared unused (pinned)
    # cbBTC is a plain ERC-20 — mcbBTC does NOT pay native on borrow, so nothing to wrap.
    export WETH_DELIVERS_NATIVE="${WETH_DELIVERS_NATIVE:-false}"
    ;;
  twoleg)
    # WETH/cbBTC at tickSpacing 100 — the original two-borrowed-legs shape.
    export LP_POOL="${LP_POOL:-0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1}"
    export LEG_A_FEED="${LEG_A_FEED:-0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70}" # ETH/USD  8dp
    export LEG_B_FEED="${LEG_B_FEED:-0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F}" # BTC/USD  8dp
    ;;
  *) echo "unknown SHAPE: $SHAPE (expected 'asset' or 'twoleg')"; exit 2 ;;
esac
export USDC_FEED="${USDC_FEED:-0x7e860098F58bBFC8648a4311b374B1D669a2bc6B}"     # USDC/USD 8dp
export AERO_FEED="${AERO_FEED:-0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0}"     # AERO/USD 8dp (asserted at init)
export SEQ_FEED="${SEQ_FEED:-0xBCF85224fc0756B9Fa45aA7892530B47e10b6433}"       # L2 sequencer uptime (answer 0 = up)
# Strategy proposer (operator) — see the header. NOT MAMO_BACKEND, by design.
export MAMO_REBALANCER="${MAMO_REBALANCER:-0x73f6B456d063F78129113D42DBC315b9eEee8FAf}"
# Optional: the vnet's PUBLIC (read-only) RPC — recorded into the emitted config for consumers.
# NEVER put the admin RPC in the config; it accepts unlocked writes and lives in 1Password only.
TENDERLY_VNET_PUBLIC_RPC_URL="${TENDERLY_VNET_PUBLIC_RPC_URL:-}"

SEED="${SEED:-100000000000}"          # 100,000 USDC (6dp). A seed is MANDATORY: 0 reverts
                                      # ExecuteZeroBalance inside execute(), not in the vault.
ETH_FUND_HEX=0x56BC75E2D63100000      # 100 ETH
# Base per-tx gas cap is 16,777,216 (2^24): estimate x multiplier must stay under it. The
# template CREATE (+ its 4 delegatecall libraries) is the big one — 200% clears it. The two
# heavy sends get EXPLICIT limits instead of trusting the vnet's estimate, which
# under-reports deep nested delegatecalls (the LPV2 harness hit an OOG at forge's 1.3x).
DEPLOY_GAS_MULT=200
GAS_CLONE_AND_BIND=8000000            # clone + initialize (venue/feed/factory probes)
GAS_ACTIVATE=12000000                 # execute(): supply, borrow both legs, swap, mint LP, stake

# ── cast send via unlocked impersonation; asserts status 0x1; echoes tx hash ──
# usage: csend <label> <from> <to> <sig> [args...]
csend() {
  local label="$1" from="$2" to="$3" sig="$4"; shift 4
  local out; out="$(cast send "$to" "$sig" "$@" --from "$from" --unlocked --rpc-url "$RPC" --json 2>/dev/null)"
  local st tx; st="$(echo "$out" | jq -r '.status')"; tx="$(echo "$out" | jq -r '.transactionHash')"
  [ "$st" = "0x1" ] || die "$label failed (status=$st tx=$tx)"
  ok "$label — tx $tx"
  LAST_TX="$tx"
}

# Same, with an explicit --gas-limit (see the gas note above).
# usage: csend_gas <gas> <label> <from> <to> <sig> [args...]
csend_gas() {
  local gas="$1" label="$2" from="$3" to="$4" sig="$5"; shift 5
  local out; out="$(cast send "$to" "$sig" "$@" --from "$from" --unlocked --gas-limit "$gas" \
    --rpc-url "$RPC" --json 2>/dev/null)"
  local st tx; st="$(echo "$out" | jq -r '.status')"; tx="$(echo "$out" | jq -r '.transactionHash')"
  [ "$st" = "0x1" ] || die "$label failed (status=$st tx=$tx gasLimit=$gas)"
  ok "$label — tx $tx"
  LAST_TX="$tx"
}

assert_eq() { [ "$2" = "$3" ] && ok "$1 == $3" || die "$1 mismatch: got $2 want $3"; }
lower()     { echo "$1" | tr 'A-Z' 'a-z'; }

# ── 1. resolve vnet (reuse) + sanity ──────────────────────────────────────────
resolve_vnet
chain_sanity
USDC="$(addr USDC)"
MULTISIG="$(addr MAMO_MULTISIG)"
DEPLOYER="$(addr DEPLOYER_EOA)"
export USDC
info "vault owner / lifecycle driver : MAMO_MULTISIG  $MULTISIG"
info "template + vault deployer      : DEPLOYER_EOA   $DEPLOYER"
info "strategy proposer (rebalancer) : MAMO_REBALANCER $MAMO_REBALANCER"
info "shape                          : $SHAPE $([ "$SHAPE" = asset ] && echo '(leg B == USDC — one borrowed leg)' || echo '(two borrowed legs)')"
info "LP pool                        : $LP_POOL (tickSpacing ${TICK_SPACING:-100})"
info "seed                           : $SEED USDC units (6dp)"
[ "$(lower "$MAMO_REBALANCER")" = "$(lower "$(addr MAMO_BACKEND)")" ] \
  && warn "MAMO_REBALANCER == MAMO_BACKEND — the rebalancer is meant to be a DEDICATED operator key"
fund_eth "$DEPLOYER" "$ETH_FUND_HEX"
fund_eth "$MULTISIG" "$ETH_FUND_HEX"
fund_eth "$MAMO_REBALANCER" "$ETH_FUND_HEX"

# ── Phase B.-1: STATE SYNC must be OFF, and the LP pool's TWAP must be servable ─
# Runbook constraint 3 says state sync MUST be disabled, and it is a CREATION-TIME-ONLY flag —
# so a state-synced instance cannot be repaired, only replaced. It was previously enforced only
# by prose, which cost a full pooled deploy on 2026-07-29: the instance had
# `sync_state_config.enabled = true`, Tenderly kept re-hydrating the LP pool's Slipstream oracle
# ring buffer from the LIVE parent chain while `slot0.observationIndex` stayed frozen at OUR last
# swap, so `oldest = observations[index+1]` became a *recent* live entry and
# `pool.observe([twapWindow, 0])` reverted `'OLD'`. That is the calm gate inside
# `LeveragedAeroValuation.netEquityUsdc`, i.e. EVERY priced path — `nav()`, `deposit`, `redeem`,
# `compound`, `deployIdle`'s health assert — fail-closes, and it does NOT self-heal.
#
# Two checks, cheapest first:
#   (a) the Tenderly API's `sync_state_config.enabled` when creds are present (unambiguous), and
#   (b) an always-on FUNCTIONAL probe: `pool.observe([twapWindow, 0])` must not revert. (b) is the
#       one that matters — it catches a synced instance with no creds, and any other reason the
#       pool's oracle window is too short (a very fresh pool, a wrapped ring buffer).
section "Phase B.-1 — vnet sanity: state sync OFF + LP-pool TWAP servable"
TWAP_WINDOW="${TWAP_WINDOW:-1800}"
if [ -n "${TENDERLY_ACCESS_KEY:-}" ]; then
  # A vnet's UUID-form RPC (`…rpc.tenderly.co/<uuid>`) matches `rpcs[].url` directly. The ALIASED
  # form (`…rpc.tenderly.co/<account>/<project>/<slug>`) does NOT — the API only ever returns the
  # UUID urls — but its path carries the account/project the vnet actually lives in, which may
  # differ from .env's. So try .env's slug pair AND the URL-derived one, matching on either the
  # UUID or the trailing alias slug.
  #
  # ── AND the known home of the SHARED instance, which is why this check was silently inert ──
  # Observed 2026-07-29: `.env` carries TENDERLY_PROJECT_SLUG=moonwell-automations (correct for the
  # LPV2 / price-checker harnesses), but the shared leveraged-Aero vnet lives in `moonwell/project`.
  # The .env pair therefore lists 4 unrelated vnets and never matches, and the URL-derived fallback
  # can't help because a UUID-form RPC has no account/project in its path — so this check, the ONE
  # that would have caught the state-synced instance up front, reported "could not confirm" and fell
  # through to the functional probe every time. Appending the known pair makes it actually fire.
  # It is a CANDIDATE list, not an override: the first pair that resolves the vnet wins, so adding
  # this cannot mis-report a vnet that .env's pair already matches.
  _vnet_key="${RPC##*/}"
  _rpc_path="${RPC#*rpc.tenderly.co/}"
  _synced=""
  for _pair in "${TENDERLY_ACCOUNT_SLUG:-}/${TENDERLY_PROJECT_SLUG:-}" \
               "$(printf '%s' "$_rpc_path" | cut -d/ -f1)/$(printf '%s' "$_rpc_path" | cut -d/ -f2)" \
               "${TENDERLY_ACCOUNT_SLUG:-moonwell}/project"; do
    _acct="${_pair%%/*}"; _proj="${_pair##*/}"
    { [ -n "$_acct" ] && [ -n "$_proj" ] && [ "$_acct" != "$_rpc_path" ]; } || continue
    _synced="$(curl -s "$TENDERLY_API/account/$_acct/project/$_proj/vnets?page=1&perPage=100" \
      -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Accept: application/json" 2>/dev/null \
      | jq -r --arg u "$_vnet_key" '.[]? | select(([.rpcs[]?.url] | join(" ") | contains($u)) or (.slug == $u)) | .sync_state_config.enabled' 2>/dev/null | head -1)"
    [ -n "$_synced" ] && break
  done
  case "$_synced" in
    true)  die "vnet has sync_state_config.enabled = true — runbook constraint 3. It is CREATION-TIME-ONLY: recreate the vnet with sync_state_config.enabled=false (it re-hydrates mainnet accounts, which breaks the pool TWAP and would silently undo the FreshFeed code overrides)" ;;
    false) ok "state sync disabled (Tenderly API)" ;;
    *)     info "state sync: could not confirm via API (vnet not matched) — relying on the functional probe" ;;
  esac
else
  info "state sync: no API creds to check — relying on the functional probe"
fi
if cast call "$LP_POOL" 'observe(uint32[])(int56[],uint160[])' "[$TWAP_WINDOW,0]" --rpc-url "$RPC" >/dev/null 2>&1; then
  ok "LP pool TWAP servable over ${TWAP_WINDOW}s (calm gate can run)"
else
  _obs_err="$(cast call "$LP_POOL" 'observe(uint32[])(int56[],uint160[])' "[$TWAP_WINDOW,0]" --rpc-url "$RPC" 2>&1 | tail -1)"
  die "pool.observe([$TWAP_WINDOW,0]) reverts on $LP_POOL — the calm gate in every priced path will fail-close. Almost always a STATE-SYNCED vnet (recreate it with sync_state_config.enabled=false). Raw: $_obs_err"
fi

# ── Phase B.0: FreshFeed code-replacement ─────────────────────────────────────
# Per feed: read the LIVE decimals + answer, deploy a FreshFeed carrying them as
# immutables, then copy its RUNTIME code onto the canonical mainnet feed address with
# tenderly_setCode. The override lands at the address the strategy is initialized with, so
# feeds are permanently fresh (updatedAt = block.timestamp - 60) and warping is safe.
# Storage-free by construction (immutables only), which is what makes a code-only
# override sound. Idempotent: re-reading an already-overridden feed yields the same answer.
head_ts() { cast block latest --rpc-url "$RPC" --field timestamp 2>/dev/null | field; }

feed_answer()   { ccall "$1" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 2p | field; }
feed_updated()  { ccall "$1" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 4p | field; }

# usage: apply_freshfeed <label> <feedAddr>
apply_freshfeed() {
  local label="$1" feed="$2"
  local dec ans code args deployed runtime
  dec="$(ccall "$feed" 'decimals()(uint8)' | field)"
  ans="$(feed_answer "$feed")"
  [ -n "$dec" ] && [ -n "$ans" ] || die "$label: could not read decimals/answer off $feed"
  code="$(jq -r '.bytecode.object' "$FRESHFEED_ART")"
  [ -n "$code" ] && [ "$code" != "null" ] || die "FreshFeed artifact missing bytecode ($FRESHFEED_ART)"
  args="$(cast abi-encode 'ctor(int256,uint8)' "$ans" "$dec")"
  # NOTE flag ORDER: every option MUST precede `--create`. In cast >= 1.7 `--create` takes the
  # bytecode as a positional and then greedily consumes the rest of argv as [SIG] [ARGS]..., so a
  # trailing `--from` dies with "unexpected argument '--from' found" (and the 2>/dev/null here turns
  # that into a bare "FreshFeed deploy failed"). Keep --create LAST.
  deployed="$(cast send --from "$DEPLOYER" --unlocked --rpc-url "$RPC" --json \
    --create "${code}${args#0x}" 2>/dev/null | jq -r '.contractAddress')"
  [ -n "$deployed" ] && [ "$deployed" != "null" ] || die "$label: FreshFeed deploy failed"
  runtime="$(cast code "$deployed" --rpc-url "$RPC" 2>/dev/null)"
  [ -n "$runtime" ] && [ "$runtime" != "0x" ] || die "$label: FreshFeed has no runtime code"
  crpc tenderly_setCode "$feed" "$runtime" >/dev/null
  ok "$label $feed <- FreshFeed(answer=$ans, decimals=$dec) [mock at $deployed]"
}

# usage: assert_feed_fresh <label> <feedAddr> [expectedAnswer]
assert_feed_fresh() {
  local label="$1" feed="$2" want="${3:-}"
  local upd ts lag ans
  upd="$(feed_updated "$feed")"; ts="$(head_ts)"
  [ -n "$upd" ] && [ -n "$ts" ] || die "$label: could not read updatedAt / head timestamp"
  lag=$(( ts - upd ))
  # FreshFeed reports block.timestamp - 60; allow slack for the eth_call block being a
  # block or two behind the head. Anything larger means the override did not land.
  { [ "$lag" -ge 0 ] && [ "$lag" -le 300 ]; } 2>/dev/null \
    || die "$label: updatedAt is $lag s behind head ($upd vs $ts) — FreshFeed override not in effect"
  ans="$(feed_answer "$feed")"
  if [ -n "$want" ]; then assert_eq "$label answer" "$ans" "$want"; fi
  ok "$label fresh (lag ${lag}s, answer=$ans)"
}

if [ "$DO_FRESHFEED" = "1" ]; then
  section "Phase B.0 — FreshFeed code-replacement (5 venue feeds)"
  [ -f "$FRESHFEED_ART" ] || { info "building FreshFeed artifact"; forge build script/tenderly/FreshFeed.sol >/dev/null 2>&1; }
  [ -f "$FRESHFEED_ART" ] || die "FreshFeed artifact not found — run: forge build script/tenderly/FreshFeed.sol"
  apply_freshfeed "leg A/USD " "$LEG_A_FEED"
  apply_freshfeed "leg B/USD " "$LEG_B_FEED"
  apply_freshfeed "USDC/USD  " "$USDC_FEED"
  apply_freshfeed "AERO/USD  " "$AERO_FEED"
  # The sequencer-uptime feed is the same mock, different shape: answer 0 == UP, and
  # FreshFeed reports startedAt = block.timestamp - 30 days so any gracePeriod (<= 1 day)
  # is cleared. Its live answer on a healthy Base fork is already 0, so the read-then-mock
  # flow reproduces it; the assert below pins it.
  apply_freshfeed "sequencer " "$SEQ_FEED"
  section "Phase B.0 — freshness asserts"
  assert_feed_fresh "leg A/USD " "$LEG_A_FEED"
  assert_feed_fresh "leg B/USD " "$LEG_B_FEED"
  assert_feed_fresh "USDC/USD  " "$USDC_FEED"
  assert_feed_fresh "AERO/USD  " "$AERO_FEED"
  assert_feed_fresh "sequencer " "$SEQ_FEED" "0"
  assert_eq "AERO/USD decimals (init asserts 8)" "$(ccall "$AERO_FEED" 'decimals()(uint8)' | field)" "8"
else
  warn "Phase B.0 SKIPPED (--no-freshfeed) — the instance must already carry the mocks"
fi

# ── Phase B.1: deploy the strategy template + the vault ───────────────────────
section "Phase B.1 — deploy strategy template + LeveragedAeroVault (DEPLOYER_EOA, unlocked)"
DEPLOY_LOG="$ROOT/script/tenderly/.phase-leveraged-aero-stack-deploy.log"
forge script "$FQ" --sig 'deployTemplate()' --rpc-url "$RPC" --broadcast --slow --unlocked \
  --sender "$DEPLOYER" --no-storage-caching --gas-estimate-multiplier "$DEPLOY_GAS_MULT" -vvv \
  > "$DEPLOY_LOG" 2>&1 || { grep -iE "error|revert|fail" "$DEPLOY_LOG" | tail -20 | tee -a "$RESULTS"; die "deployTemplate() failed"; }
TEMPLATE="$(grep -oE 'HARNESS_TEMPLATE=0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | head -1 | cut -d= -f2)"
VAULT="$(grep -oE 'HARNESS_VAULT=0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | head -1 | cut -d= -f2)"
[ -n "$TEMPLATE" ] && [ -n "$VAULT" ] || die "could not parse template/vault from $DEPLOY_LOG"
TPL_SIZE="$(grep -oE 'template runtime size \(limit 24576\): [0-9]+' "$DEPLOY_LOG" | tail -1 | awk '{print $NF}')"
[ -n "$TPL_SIZE" ] && info "template runtime size: $TPL_SIZE / 24576 bytes"
ok "template=$TEMPLATE"
ok "vault=$VAULT"
# owner_ = MAMO_MULTISIG in the CONSTRUCTOR, so Ownable makes it owner immediately and there
# is NO acceptOwnership() step (Ownable2Step only gates later transfers).
assert_eq "vault.owner()"        "$(lower "$(ccall "$VAULT" 'owner()(address)' | field)")" "$(lower "$MULTISIG")"
assert_eq "vault.pendingOwner()" "$(ccall "$VAULT" 'pendingOwner()(address)' | field)" "0x0000000000000000000000000000000000000000"

# ── Phase B.2: build the InitParams calldata ──────────────────────────────────
section "Phase B.2 — ABI-encode InitParams from the venue book"
# No --rpc-url: this entrypoint is a pure env -> abi.encode, so it needs no fork.
INITDATA_LOG="$ROOT/script/tenderly/.phase-leveraged-aero-stack-initdata.log"
forge script "$FQ" --sig 'buildInitData()' -vvv > "$INITDATA_LOG" 2>&1 \
  || { grep -iE "error|revert|fail" "$INITDATA_LOG" | tail -20 | tee -a "$RESULTS"; die "buildInitData() failed"; }
INITDATA="$(grep -oE 'HARNESS_INITDATA=0x[0-9a-fA-F]+' "$INITDATA_LOG" | head -1 | cut -d= -f2)"
[ -n "$INITDATA" ] || die "could not parse HARNESS_INITDATA from $INITDATA_LOG"
# "width band" matches EVERY harness range line: the min/width/max triple AND the min/skew/max skew
# triple. Both keep that prefix deliberately so this one pattern covers the whole range config — if you
# add another range knob, prefix its log line the same way rather than widening this grep.
grep -E "(pool +:|legA/legB:|feeRecip +:|mgmt/perf fee bps|width band)" "$INITDATA_LOG" | tee -a "$RESULTS"
ok "initData = ${#INITDATA} hex chars"

# ── Phase B.3: clone + initialize + bind, atomically, as the owner ────────────
section "Phase B.3 — vault.cloneAndBind(template, MAMO_REBALANCER, initData) [MAMO_MULTISIG]"
# cloneAndBind is onlyOwner and atomic (clone -> initialize -> bind). It replaces the old
# Clones.clone + initialize + setStrategy flow (both halves now gone), which left the fresh clone initializable by
# ANYONE in between (a front-runner could seize the proposer role). _bind re-checks
# clone.vault() == this vault, so a foreign-vault clone can never be bound here either.
# A wrong venue value fails HERE, loudly: VenueMismatch (pool spacing / token set / Moonwell
# underlying / a swap pool that does not exist at the configured spacing), UnsupportedLeg
# (USDC or AERO as a leg), LegDecimalsOutOfRange, AssetMismatch, UnexpectedFeedDecimals,
# OutOfBounds (width band OR skewBps OR the [MIN_SKEW_BPS, MAX_SKEW_BPS] band — one error covers
# every range knob), or one of the risk/oracle/fee bound errors.
csend_gas "$GAS_CLONE_AND_BIND" "cloneAndBind" "$MULTISIG" "$VAULT" \
  'cloneAndBind(address,address,bytes)' "$TEMPLATE" "$MAMO_REBALANCER" "$INITDATA"
CLONE="$(ccall "$VAULT" 'strategy()(address)' | field)"
[ -n "$CLONE" ] && [ "$CLONE" != "0x0000000000000000000000000000000000000000" ] || die "vault.strategy() is still unset"
ok "strategyClone=$CLONE"
assert_eq "clone.vault()"    "$(lower "$(ccall "$CLONE" 'vault()(address)' | field)")" "$(lower "$VAULT")"
assert_eq "clone.proposer()" "$(lower "$(ccall "$CLONE" 'proposer()(address)' | field)")" "$(lower "$MAMO_REBALANCER")"
assert_eq "clone.state() (0=Pending)" "$(ccall "$CLONE" 'state()(uint8)' | field)" "0"

# ── Phase B.4: seed + activate (Pending -> Executed) ──────────────────────────
section "Phase B.4 — seed the multisig, approve, activateStrategy($SEED)"
# activateStrategy pulls the seed from the CALLER via safeTransferFrom(msg.sender, strategy,
# seed) — the vault never custodies it — so the OWNER must approve the VAULT first. It then
# calls strategy.execute() (the vault being the caller is what satisfies onlyVault) and mints
# the seeder seed * 10**(vault.decimals() - asset.decimals()) = seed * 1e6 genesis shares,
# keeping supply and NAV in step for the first real depositor.
fund_erc20 "$USDC" "$MULTISIG" "$(cast to-hex $((SEED * 2)))"
USDC_BAL="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$MULTISIG" | field)"
[ "$USDC_BAL" -ge "$SEED" ] 2>/dev/null || die "multisig USDC balance $USDC_BAL < seed $SEED"
csend "approve(vault, seed)" "$MULTISIG" "$USDC" 'approve(address,uint256)' "$VAULT" "$SEED"
csend_gas "$GAS_ACTIVATE" "activateStrategy($SEED)" "$MULTISIG" "$VAULT" 'activateStrategy(uint256)' "$SEED"

# ── Phase B.5: post-conditions the account layer (Phase C) depends on ─────────
section "Phase B.5 — post-conditions"
assert_eq "vault.owner()"        "$(lower "$(ccall "$VAULT" 'owner()(address)' | field)")" "$(lower "$MULTISIG")"
assert_eq "vault.pendingOwner()" "$(ccall "$VAULT" 'pendingOwner()(address)' | field)" "0x0000000000000000000000000000000000000000"
assert_eq "vault.strategy()"     "$(lower "$(ccall "$VAULT" 'strategy()(address)' | field)")" "$(lower "$CLONE")"
assert_eq "vault.asset()"        "$(lower "$(ccall "$VAULT" 'asset()(address)' | field)")" "$(lower "$USDC")"
assert_eq "vault.decimals()"     "$(ccall "$VAULT" 'decimals()(uint8)' | field)" "12"
# Left CLOSED here on purpose: proposal 012's build() flips it, which is what makes the vnet
# a faithful rehearsal of the mainnet proposal (the account harness replays that).
assert_eq "vault.depositsOpen()" "$(ccall "$VAULT" 'depositsOpen()(bool)')" "false"
assert_eq "vault.feeConfig()"    "$(ccall "$VAULT" 'feeConfig()(address)' | field)" "0x0000000000000000000000000000000000000000"
assert_eq "vault.settled()"      "$(ccall "$VAULT" 'settled()(bool)')" "false"
# Genesis mint: seed x 10^(12-6).
SEED_SHARES="$(python3 -c "print($SEED * 10**6)")"
assert_eq "vault.balanceOf(multisig)" "$(ccall "$VAULT" 'balanceOf(address)(uint256)' "$MULTISIG" | field)" "$SEED_SHARES"
assert_eq "vault.totalSupply()"       "$(ccall "$VAULT" 'totalSupply()(uint256)' | field)" "$SEED_SHARES"
assert_eq "strategy.state() (1=Executed)" "$(ccall "$CLONE" 'state()(uint8)' | field)" "1"
assert_eq "strategy.vault()"    "$(lower "$(ccall "$CLONE" 'vault()(address)' | field)")" "$(lower "$VAULT")"
assert_eq "strategy.proposer()" "$(lower "$(ccall "$CLONE" 'proposer()(address)' | field)")" "$(lower "$MAMO_REBALANCER")"
NAV="$(ccall "$CLONE" 'nav()(uint256)' | field)"
[ "$NAV" -gt 0 ] 2>/dev/null && ok "strategy.nav() == $NAV (> 0)" || die "strategy.nav() is 0 — the book did not execute"
section "Phase B.5 — feeds still fresh"
assert_feed_fresh "leg A/USD " "$LEG_A_FEED"
assert_feed_fresh "leg B/USD " "$LEG_B_FEED"
assert_feed_fresh "USDC/USD  " "$USDC_FEED"
assert_feed_fresh "AERO/USD  " "$AERO_FEED"
assert_feed_fresh "sequencer " "$SEQ_FEED" "0"

section "Summary"
ok "Pooled layer live. vault=$VAULT strategyClone=$CLONE template=$TEMPLATE proposer=$MAMO_REBALANCER"
info "Next: the account layer —"
info "  TENDERLY_VNET_RPC_URL=<admin-rpc> SHERWOOD_LEVERAGED_AERO_STRATEGY=$CLONE \\"
info "  SHERWOOD_SYNDICATE_VAULT=$VAULT make tenderly-leveraged-aero-account"

# ── machine-consumable config for downstream consumers ────────────────────────
# MERGE-WRITE, not clobber: run-leveraged-aero-account.sh owns the `mamo` object and this
# script owns `pooled` + `feeds`. Both merge onto whatever is already in the file so the two
# harnesses can run in either order without erasing each other's fields. A NEW pooled layer
# does invalidate the account layer (the factory binds the strategy clone at construction),
# so the account addresses are reset to null here and the account harness refills them.
PREV='{}'; [ -f "$CONFIG_JSON" ] && PREV="$(cat "$CONFIG_JSON")"
jq -n \
  --argjson prev "$PREV" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg publicRpc "$TENDERLY_VNET_PUBLIC_RPC_URL" \
  --arg vault "$VAULT" --arg clone "$CLONE" --arg template "$TEMPLATE" \
  --arg proposer "$MAMO_REBALANCER" --arg seed "$SEED" \
  --arg usdc "$USDC" --arg registry "$(addr MAMO_STRATEGY_REGISTRY)" \
  --arg pool "$LP_POOL" \
  --arg legAFeed "$LEG_A_FEED" --arg legBFeed "$LEG_B_FEED" --arg usdcFeed "$USDC_FEED" \
  --arg aeroFeed "$AERO_FEED" --arg seqFeed "$SEQ_FEED" \
  '$prev * {
    generatedAt: $ts,
    chainId: 8453,
    publicRpc: (if $publicRpc == "" then ($prev.publicRpc // null) else $publicRpc end),
    adminRpc: "1Password (write-capable — never committed)",
    strategyTypeId: 5,
    mamo: { accountImplementation: null, accountFactory: null, strategyRegistry: $registry },
    pooled: {
      vault: $vault,
      strategyClone: $clone,
      template: $template,
      proposer: $proposer,
      seed: $seed,
      lpPool: $pool
    },
    sherwood: { strategyClone: $clone, syndicateVault: $vault },
    usdc: $usdc,
    feeds: {
      pattern: "FreshFeed (tenderly_setCode; updatedAt tracks block.timestamp)",
      legAUsd: $legAFeed, legBUsd: $legBFeed, usdcUsd: $usdcFeed, aeroUsd: $aeroFeed,
      sequencerUptime: $seqFeed
    },
    vaultGeneration: 3,
    vaultGenerationName: "leveraged-aero-vault (in-repo: + maxTotalAssets(), remainingCapacity())",
    note: "Addresses change when the instance rotates or a harness redeploys — always read this file, never hardcode. pooled = the LeveragedAeroVault + its LeveragedAerodromeCLStrategy clone (both in-repo since PR #66); mamo = the account layer, filled by run-leveraged-aero-account.sh (null right after a pooled redeploy — the factory binds the clone at construction, so the account layer must be redeployed too). sherwood is a deprecated alias of pooled, kept for existing consumers. The 5 feeds are FreshFeed-mocked (never stale). proposer is the rebalancer operator key, deliberately distinct from MAMO_BACKEND."
  }' > "$CONFIG_JSON"
ok "config emitted: $CONFIG_JSON"
info "Full log: $RESULTS"
echo
