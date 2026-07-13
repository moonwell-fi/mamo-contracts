#!/usr/bin/env bash
# ==============================================================================
# common.sh — shared Tenderly Virtual TestNet harness primitives (SOURCED)
# ==============================================================================
# Reusable plumbing extracted from the original LPAutoBalancerV2 orchestrator so
# every per-contract harness (run-lpv2.sh, run-price-checker.sh, …) shares ONE
# copy of: vnet resolution + teardown, the cheat-RPC fund/time helpers, the
# forge-phase runner, the on-chain address book lookup, and the hard-won vnet
# gotcha fixes (oracle-freshness clock bump, NFPM _nextId repair).
#
# This file is sourced, never executed. Callers set the following BEFORE use:
#   ROOT        repo root (absolute)                     [required]
#   RESULTS     results log path                          [required]
#   MAMO_DEPLOYER_PRIVATE_KEY  broadcaster key            [via load_env]
#   RPC         the resolved vnet RPC                     [set by resolve_vnet]
# Optional knobs (with defaults):
#   HARNESS_SLUG / HARNESS_DISPLAY   vnet naming          [resolve_vnet]
#   EXPECTED_CHAIN=8453              chain assertion       [chain_sanity]
#   ADDR_CHAIN=8453                 addresses/<id>.json    [addr]
#   PHASE_MARKERS                   log lines surfaced     [run_forge_phase]
#   FORCE_CREATE / KEEP_VNET        vnet lifecycle
# ==============================================================================
[ -n "${_TENDERLY_COMMON_SH:-}" ] && return 0
_TENDERLY_COMMON_SH=1

set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

TENDERLY_API="${TENDERLY_API:-https://api.tenderly.co/api/v1}"

# ── logging helpers ─────────────────────────────────────────────────────────
c_blue='\033[0;34m'; c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_off='\033[0m'
section() { printf "\n${c_blue}━━━ %s ━━━${c_off}\n" "$1" | tee -a "$RESULTS"; }
info()    { printf "  %s\n" "$1" | tee -a "$RESULTS"; }
ok()      { printf "  ${c_grn}✓ %s${c_off}\n" "$1" | tee -a "$RESULTS"; }
warn()    { printf "  ${c_yel}! %s${c_off}\n" "$1" | tee -a "$RESULTS"; }
die()     { printf "  ${c_red}✗ %s${c_off}\n" "$1" | tee -a "$RESULTS"; teardown; exit 1; }

# ── cast wrappers (need $RPC) ───────────────────────────────────────────────
# stderr (nightly/lint warnings) suppressed; stdout only.
ccall()   { cast call "$@" --rpc-url "$RPC" 2>/dev/null; }
crpc()    { cast rpc "$@" --rpc-url "$RPC" 2>/dev/null; }
field()   { awk '{print $1}'; }   # strip cast's " [1.23e4]" annotation

# ── on-chain address book: single source of truth = addresses/<chain>.json ──
# Mirrors the Solidity FPS `Addresses` lookup so bash + Solidity resolve the
# same names instead of hardcoding hex. Dies on an unknown name.
addr() {
  local v; v="$(jq -r --arg n "$1" '.[] | select(.name==$n) | .addr' "$ROOT/addresses/${ADDR_CHAIN:-8453}.json" 2>/dev/null)"
  [ -n "$v" ] && [ "$v" != "null" ] || die "address '$1' not found in addresses/${ADDR_CHAIN:-8453}.json"
  echo "$v"
}

# ── env ─────────────────────────────────────────────────────────────────────
load_env() {
  [ -f "$ROOT/.env" ] || die ".env not found in $ROOT"
  # `set -a` exports everything sourced from .env, so MAMO_DEPLOYER_PRIVATE_KEY reaches forge/the .s.sol
  # via the ENVIRONMENT (vm.envUint) rather than forge's argv (--private-key), keeping the key out of
  # `ps aux` on a shared host. MUST be a throwaway, fork-only key — never a mainnet deployer.
  set -a; . "$ROOT/.env"; set +a
  [ -n "${MAMO_DEPLOYER_PRIVATE_KEY:-}" ] || die "MAMO_DEPLOYER_PRIVATE_KEY not set in .env"
}

# Derive the broadcaster address from MAMO_DEPLOYER_PRIVATE_KEY WITHOUT putting the raw key on argv.
# `cast wallet address --private-key <key>` (and any argv form) is visible in `ps aux`; foundry offers
# no argv-free raw-key→address path (ETH_PRIVATE_KEY is not honored; --interactive needs a TTY). So we
# read it back through the harness's sender() entrypoint, which logs vm.addr(vm.envUint(...)). No
# --rpc-url / --broadcast → no fork spin-up, just local key derivation. Sets + exports $SENDER.
# usage: derive_sender <forge-script-fq>
derive_sender() {
  local fq="$1" out
  out="$(forge script "$fq" --sig 'sender()' 2>&1)" || true
  SENDER="$(printf '%s\n' "$out" | grep -oE 'HARNESS_SENDER_DERIVED=0x[0-9a-fA-F]{40}' | head -1 | cut -d= -f2)"
  [ -n "$SENDER" ] || die "could not derive sender from MAMO_DEPLOYER_PRIVATE_KEY via ${fq} sender()"
  export SENDER
}

# ── vnet lifecycle ──────────────────────────────────────────────────────────
CREATED_VNET=0
VNET_ID=""

teardown() {
  # One-shot guard: die() calls teardown explicitly then exit 1, which re-fires the
  # `trap teardown EXIT` in each runner → a second teardown. Run at most once.
  [ "${_TENDERLY_TEARDOWN_DONE:-0}" = "1" ] && return 0
  _TENDERLY_TEARDOWN_DONE=1
  if [ "${CREATED_VNET:-0}" = "1" ] && [ "${KEEP_VNET:-0}" = "0" ] && [ -n "${VNET_ID:-}" ]; then
    section "Teardown: deleting created vnet $VNET_ID"
    curl -s -X DELETE "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets/$VNET_ID" \
      -H "X-Access-Key: $TENDERLY_ACCESS_KEY" >/dev/null && ok "vnet deleted" || warn "vnet delete failed (delete manually)"
  elif [ "${CREATED_VNET:-0}" = "1" ]; then
    warn "created vnet $VNET_ID kept (--keep or teardown skipped)"
  fi
}

# If account/project slugs aren't set explicitly, derive them from the vnet RPC URL path
# (https://virtual.<net>.rpc.tenderly.co/<account>/<project>/<uuid>). These are org/project names,
# not secrets — lets create-mode work with just TENDERLY_ACCESS_KEY + a reuse URL in .env.
_derive_tenderly_slugs() {
  { [ -n "${TENDERLY_ACCOUNT_SLUG:-}" ] && [ -n "${TENDERLY_PROJECT_SLUG:-}" ]; } && return 0
  [ -n "${TENDERLY_VNET_RPC_URL:-}" ] || return 0
  local p="${TENDERLY_VNET_RPC_URL#*rpc.tenderly.co/}"
  [ "$(printf '%s' "$p" | awk -F/ '{print NF}')" -ge 3 ] || return 0
  TENDERLY_ACCOUNT_SLUG="${TENDERLY_ACCOUNT_SLUG:-$(printf '%s' "$p" | cut -d/ -f1)}"
  TENDERLY_PROJECT_SLUG="${TENDERLY_PROJECT_SLUG:-$(printf '%s' "$p" | cut -d/ -f2)}"
}

# Resolve $RPC. DEFAULT = a FRESH Base-fork vnet (deterministic: fresh Chainlink feeds, live gauge
# emissions, no clock drift) when creds are present; `--reuse` (REUSE_VNET=1) or missing creds falls
# back to TENDERLY_VNET_RPC_URL. A freshly-created vnet is torn down on exit unless KEEP_VNET=1.
resolve_vnet() {
  local slug="${HARNESS_SLUG:-harness}"
  local display="${HARNESS_DISPLAY:-Mamo vnet harness}"
  section "Resolve Tenderly vnet"
  _derive_tenderly_slugs
  local have_creds=0
  if [ -n "${TENDERLY_ACCESS_KEY:-}" ] && [ -n "${TENDERLY_ACCOUNT_SLUG:-}" ] && [ -n "${TENDERLY_PROJECT_SLUG:-}" ]; then
    have_creds=1
  fi
  if [ "$have_creds" = "1" ] && [ "${REUSE_VNET:-0}" = "0" ]; then
    info "mode (a): creating a fresh Base-fork vnet (acct=$TENDERLY_ACCOUNT_SLUG proj=$TENDERLY_PROJECT_SLUG)"
    local resp
    resp="$(curl -s -X POST "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets" \
      -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" -H "Accept: application/json" \
      -d "{\"slug\":\"${slug}-$(date +%s)\",\"display_name\":\"${display}\",\"fork_config\":{\"network_id\":8453},\"virtual_network_config\":{\"chain_config\":{\"chain_id\":8453}},\"sync_state_config\":{\"enabled\":false},\"explorer_page_config\":{\"enabled\":false,\"verification_visibility\":\"bytecode\"}}")"
    VNET_ID="$(echo "$resp" | jq -r '.id // empty')"
    RPC="$(echo "$resp" | jq -r '.rpcs[]? | select(.name=="Admin RPC") | .url')"
    [ -n "$RPC" ] || die "vnet create failed: $resp"
    CREATED_VNET=1
    ok "created vnet $VNET_ID"
  else
    info "mode (b): reusing TENDERLY_VNET_RPC_URL ($([ "$have_creds" = "1" ] && echo '--reuse' || echo 'no create creds'))"
    RPC="${TENDERLY_VNET_RPC_URL:-}"
    [ -n "$RPC" ] && [ "$RPC" != "..." ] || die "TENDERLY_VNET_RPC_URL not usable and no API creds to create one"
  fi
  info "RPC: ${RPC:0:42}…"
}

# Assert the fork is the expected chain (default Base 8453).
chain_sanity() {
  local expected="${EXPECTED_CHAIN:-8453}"
  local chain; chain="$(cast chain-id --rpc-url "$RPC" 2>/dev/null)"
  [ "$chain" = "$expected" ] || die "expected chain $expected, got '$chain'"
  ok "chain id $chain, block $(cast block-number --rpc-url "$RPC" 2>/dev/null)"
}

# ── cheat-RPC fund + time helpers ───────────────────────────────────────────
fund_eth()     { crpc tenderly_setBalance "[\"$1\"]" "$2" >/dev/null; }
fund_erc20()   { crpc tenderly_setErc20Balance "$1" "$2" "$3" >/dev/null; }
advance_time() { crpc evm_increaseTime "$(cast to-hex "$1")" >/dev/null; crpc evm_mine >/dev/null; }

# Advance the vnet clock just past the freshest of the given Chainlink feeds so
# `block.timestamp - updatedAt` in _readFeed can't underflow on a fresh fork.
# Stays far under maxOracleDelay. usage: ensure_feeds_fresh <feed> [<feed>...]
ensure_feeds_fresh() {
  section "Ensure Chainlink feeds are fresh (avoid updatedAt underflow)"
  local maxupd=0 upd
  for feed in "$@"; do
    upd="$(ccall "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 4p | field)"
    [ -n "$upd" ] && [ "$upd" -gt "$maxupd" ] 2>/dev/null && maxupd="$upd"
  done
  local blkts; blkts="$(cast block latest --rpc-url "$RPC" --field timestamp 2>/dev/null | field)"
  local target=$(( maxupd + 120 ))
  info "block ts=$blkts  freshest feed updatedAt=$maxupd"
  if [ "$blkts" -lt "$target" ]; then
    local delta=$(( target - blkts ))
    advance_time "$delta"
    ok "advanced clock +${delta}s → block ts $(cast block latest --rpc-url "$RPC" --field timestamp 2>/dev/null | field)"
  else
    ok "feeds already fresh (block ts ≥ feed updatedAt)"
  fi
}

# Repair the Slipstream NFPM's packed _nextId/_nextPoolId slot (#14). On a Base
# vnet reporting chainId 8453 this slot hydrates BEHIND real Base's counter while
# _owners for higher ids hydrate lazily → a fresh mint reverts "token already
# minted". Copy real Base's authoritative slot 14 onto the vnet (+1000 id margin).
# usage: repair_nfpm_counter <nfpm-address>
repair_nfpm_counter() {
  local nfpm="$1"
  local slot=0x000000000000000000000000000000000000000000000000000000000000000e
  local real
  if [ -n "${BASE_RPC_URL:-}" ] && [ "$BASE_RPC_URL" != "..." ]; then
    real="$(cast storage "$nfpm" 14 --rpc-url "$BASE_RPC_URL" 2>/dev/null)"
  fi
  local vnet; vnet="$(cast storage "$nfpm" 14 --rpc-url "$RPC" 2>/dev/null)"
  local newslot
  newslot="$(python3 - "${real:-0x0}" "$vnet" <<'PY'
import sys
real = int(sys.argv[1], 16)
vnet = int(sys.argv[2], 16)
poolId = vnet >> 176                       # preserve the vnet's _nextPoolId
real_nextId = real & ((1 << 176) - 1)
vnet_nextId = vnet & ((1 << 176) - 1)
# authoritative real counter when available, else bump the vnet's own; +1000 margin
base = real_nextId if real_nextId > vnet_nextId else vnet_nextId
print("0x%064x" % ((poolId << 176) | (base + 1000)))
PY
)"
  crpc tenderly_setStorageAt "$nfpm" "$slot" "$newslot" >/dev/null
  ok "repaired NFPM _nextId → slot14=$newslot"
}

# ── forge phase runner ──────────────────────────────────────────────────────
# Run a --sig entrypoint of a forge script.
# usage: run_forge_phase <fq> <sig> <broadcast 0|1> [gas-estimate-multiplier %]
# The multiplier is PER-PHASE (default 300) because it must satisfy two opposing bounds:
#   • lower bound — the vnet under-estimates gas for deep nested delegatecalls (e.g. exit()'s final
#     cbBTC FiatToken transfer OOG'd at forge's default 1.3x), so heavy calls want ~3x headroom;
#   • upper bound — Base enforces a per-tx gas cap of 16,777,216 (2^24), so estimate*mult must stay
#     under it. The LPAutoBalancerV2 CREATE alone estimates ~5.77M gas → 3x = 17.3M > cap and reverts
#     TxGasLimitGreaterThanCap. Big deterministic txs (deploy) therefore pass a smaller multiplier.
run_forge_phase() {
  local fq="$1" sig="$2" broadcast="$3" mult="${4:-300}" sigargs="${5:-}"
  local full="$ROOT/script/tenderly/.phase-$(echo "$sig" | tr -cd 'a-zA-Z').log"
  # --no-storage-caching is REQUIRED: this vnet reports chain id 8453 (same as real Base), so
  # forge's fork cache (keyed by chain id) would otherwise mix stale real-Base slots with live
  # vnet slots. (moonwell-tenderly avoids this by giving vnets a unique chain id, 73570+networkId.)
  # NOTE: the broadcaster key is deliberately NOT passed here as --private-key. forge's argv is
  # world-readable (`ps aux`) on a shared host; instead load_env exports MAMO_DEPLOYER_PRIVATE_KEY
  # into the environment and the .s.sol reads it via vm.envUint + vm.startBroadcast(pk). Non-broadcast
  # (simulate-only) phases need no key at all. See the finding in script/tenderly/README.md.
  local flags=(--rpc-url "$RPC" --sig "$sig" --no-storage-caching -vvv)
  [ "$broadcast" = "1" ] && flags+=(--broadcast --slow --gas-estimate-multiplier "$mult")
  # $sigargs (unquoted) are the --sig function arguments, e.g. "true 2000000000000000000000".
  forge script "$fq" "${flags[@]}" $sigargs > "$full" 2>&1
  local rc=$?
  local markers="${PHASE_MARKERS:-HARNESS_[A-Z_]+=|\[OK\]|===|measurements|reverted|blocked}"
  grep -E "$markers" "$full" | tee -a "$RESULTS"
  if [ "$rc" != "0" ]; then
    warn "forge exited $rc — failure context from $full:"
    grep -iE "error|revert|panic|fail|require|0x[0-9a-f]{8}" "$full" | grep -vE "exclude_lints|nightly|preprocessed" | tail -25 | tee -a "$RESULTS"
  fi
  return "$rc"
}

# Read the first CREATE'd contract address from a forge broadcast artifact into
# $CREATED_ADDR. usage: capture_created_address <broadcast/.../sig-latest.json>
capture_created_address() {
  local art="$1"
  CREATED_ADDR="$(jq -r '[.transactions[] | select(.transactionType=="CREATE")][0].contractAddress' "$art" 2>/dev/null)"
  [ -n "$CREATED_ADDR" ] && [ "$CREATED_ADDR" != "null" ] || die "could not read CREATE address from $art"
}
