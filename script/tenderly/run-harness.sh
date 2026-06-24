#!/usr/bin/env bash
# ==============================================================================
# LPAutoBalancerV2 — Tenderly Virtual TestNet harness orchestrator
# ==============================================================================
# Deploys LPAutoBalancerV2 to a Tenderly vnet (Base fork) and drives its real
# lifecycle as broadcast transactions to empirically verify the spec's claims:
#   • no-swap principal conservation on reset()      (balanced + single-sided)
#   • value floor passes with margin on a calm reset
#   • single-sided rebuild when withdrawal is one-sided (the _mainRange fix)
#   • fee + AERO skim to feeCollector
#   • role gating (REBALANCER for reset/stake, ADMIN for exit)
#   • cooldown gates an immediate re-reset
#   • exit() returns ALL principal to the Safe and marks the slot inactive
#
# vnet resolution (the goal's "a) spin up a vnet OR b) use the url in .env"):
#   (a) if TENDERLY_ACCESS_KEY + TENDERLY_ACCOUNT_SLUG + TENDERLY_PROJECT_SLUG
#       are set → create a fresh Base-fork vnet via the Tenderly API and tear it
#       down at the end (unless --keep). Mirrors moonwell-tenderly/scripts/setup-forks.ts.
#   (b) otherwise → use TENDERLY_VNET_RPC_URL from .env (no teardown).
#
# Usage:
#   ./script/tenderly/run-harness.sh                  # both scenarios
#   ./script/tenderly/run-harness.sh --scenario balanced
#   ./script/tenderly/run-harness.sh --create --keep  # force-create a vnet, keep it
#
# Requires: forge, cast, jq, curl. Reads .env (TENDERLY_VNET_RPC_URL,
# MAMO_DEPLOYER_PRIVATE_KEY, and optionally the TENDERLY_* creds above).
# ==============================================================================
set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# ── paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$ROOT/script/tenderly/harness-results.log}"
: > "$RESULTS"

FQ="script/tenderly/LPV2TenderlyHarness.s.sol:LPV2TenderlyHarness"
BCAST="broadcast/LPV2TenderlyHarness.s.sol/8453/run-latest.json"

# ── real Base mainnet addresses (must match the Solidity harness) ─────────────
WETH=0x4200000000000000000000000000000000000006
CBBTC=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
GAUGE=0x41b2126661C673C2beDd208cC72E85DC51a5320a
NFPM=0x827922686190790b37229fd06084350E74485b72
AERO=0x940181a94A35A4569E4529A3CDfB74e38FD98631
ETH_USD=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
BTC_USD=0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F
POOL=0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1
TENDERLY_API="https://api.tenderly.co/api/v1"

# funding amounts (hex wei / base units)
ETH_FUND_HEX=0x56BC75E2D63100000          # 100 ETH
WETH_FUND_HEX=0x3635C9ADC5DEA00000        # 1000 WETH (18-dec)
CBBTC_FUND_HEX=0x12A05F200                 # 50e8 = 5_000_000_000 cbBTC (8-dec)

# ── cli args ──────────────────────────────────────────────────────────────────
SCENARIOS=("balanced" "singlesided")
FORCE_CREATE=0
KEEP_VNET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIOS=("$2"); shift 2 ;;
    --create)   FORCE_CREATE=1; shift ;;
    --keep)     KEEP_VNET=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

# ── logging helpers ───────────────────────────────────────────────────────────
c_blue='\033[0;34m'; c_grn='\033[0;32m'; c_red='\033[0;31m'; c_yel='\033[0;33m'; c_off='\033[0m'
section() { printf "\n${c_blue}━━━ %s ━━━${c_off}\n" "$1" | tee -a "$RESULTS"; }
info()    { printf "  %s\n" "$1" | tee -a "$RESULTS"; }
ok()      { printf "  ${c_grn}✓ %s${c_off}\n" "$1" | tee -a "$RESULTS"; }
warn()    { printf "  ${c_yel}! %s${c_off}\n" "$1" | tee -a "$RESULTS"; }
die()     { printf "  ${c_red}✗ %s${c_off}\n" "$1" | tee -a "$RESULTS"; teardown; exit 1; }

# cast read with stderr (nightly/lint warnings) suppressed, stdout only
ccall()   { cast call "$@" --rpc-url "$RPC" 2>/dev/null; }
crpc()    { cast rpc "$@" --rpc-url "$RPC" 2>/dev/null; }
field()   { awk '{print $1}'; }   # strip cast's " [1.23e4]" annotation

# ── load env ──────────────────────────────────────────────────────────────────
[ -f .env ] || die ".env not found in $ROOT"
set -a; . ./.env; set +a
[ -n "${MAMO_DEPLOYER_PRIVATE_KEY:-}" ] || die "MAMO_DEPLOYER_PRIVATE_KEY not set in .env"

CREATED_VNET=0
VNET_ID=""

teardown() {
  if [ "$CREATED_VNET" = "1" ] && [ "$KEEP_VNET" = "0" ] && [ -n "$VNET_ID" ]; then
    section "Teardown: deleting created vnet $VNET_ID"
    curl -s -X DELETE "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets/$VNET_ID" \
      -H "X-Access-Key: $TENDERLY_ACCESS_KEY" >/dev/null && ok "vnet deleted" || warn "vnet delete failed (delete manually)"
  elif [ "$CREATED_VNET" = "1" ]; then
    warn "created vnet $VNET_ID kept (--keep or teardown skipped)"
  fi
}
trap teardown EXIT

# ── 1. resolve the vnet RPC ────────────────────────────────────────────────────
section "1. Resolve Tenderly vnet"
have_creds=0
if [ -n "${TENDERLY_ACCESS_KEY:-}" ] && [ -n "${TENDERLY_ACCOUNT_SLUG:-}" ] && [ -n "${TENDERLY_PROJECT_SLUG:-}" ]; then
  have_creds=1
fi

if [ "$have_creds" = "1" ] && { [ "$FORCE_CREATE" = "1" ] || [ -z "${TENDERLY_VNET_RPC_URL:-}" ]; }; then
  info "mode (a): creating a fresh Base-fork vnet via the Tenderly API"
  resp="$(curl -s -X POST "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets" \
    -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "{\"slug\":\"lpv2-harness-$(date +%s)\",\"display_name\":\"LPAutoBalancerV2 harness\",\"fork_config\":{\"network_id\":8453},\"virtual_network_config\":{\"chain_config\":{\"chain_id\":8453}},\"sync_state_config\":{\"enabled\":false},\"explorer_page_config\":{\"enabled\":false,\"verification_visibility\":\"bytecode\"}}")"
  VNET_ID="$(echo "$resp" | jq -r '.id // empty')"
  RPC="$(echo "$resp" | jq -r '.rpcs[]? | select(.name=="Admin RPC") | .url')"
  [ -n "$RPC" ] || die "vnet create failed: $resp"
  CREATED_VNET=1
  ok "created vnet $VNET_ID"
else
  info "mode (b): using TENDERLY_VNET_RPC_URL from .env"
  RPC="${TENDERLY_VNET_RPC_URL:-}"
  [ -n "$RPC" ] && [ "$RPC" != "..." ] || die "TENDERLY_VNET_RPC_URL not usable and no API creds to create one"
fi
info "RPC: ${RPC:0:42}…"

# ── 2. sanity-check the fork ───────────────────────────────────────────────────
section "2. Verify fork is Base + protocol wiring intact"
CHAIN="$(cast chain-id --rpc-url "$RPC" 2>/dev/null)"
[ "$CHAIN" = "8453" ] || die "expected chain 8453 (Base), got '$CHAIN'"
ok "chain id 8453 (Base), block $(cast block-number --rpc-url "$RPC" 2>/dev/null)"
[ "$(ccall "$GAUGE" 'nft()(address)')" = "$NFPM" ] || die "gauge.nft() != expected NFPM"
[ "$(ccall "$GAUGE" 'rewardToken()(address)')" = "$AERO" ] || die "gauge.rewardToken() != AERO"
ok "gauge.nft()==NFPM and gauge.rewardToken()==AERO"

# ── 3. sender ─────────────────────────────────────────────────────────────────
SENDER="$(cast wallet address --private-key "$MAMO_DEPLOYER_PRIVATE_KEY" 2>/dev/null)"
export HARNESS_SENDER="$SENDER"
info "sender (all-roles deployer): $SENDER"

# ── 4. oracle freshness: advance the chain clock past the freshest Chainlink feed ──
# On a fresh fork the feed updatedAt can sit slightly AHEAD of the latest block ts,
# which makes _readFeed's `block.timestamp - updatedAt` underflow-revert. Advance the
# vnet clock just past the freshest feed (and stay far under maxOracleDelay = 26h).
section "3. Ensure Chainlink feeds are fresh (avoid updatedAt underflow)"
upd0="$(ccall "$ETH_USD" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 4p | field)"
upd1="$(ccall "$BTC_USD" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 4p | field)"
blkts="$(cast block latest --rpc-url "$RPC" --field timestamp 2>/dev/null | field)"
maxupd=$(( upd0 > upd1 ? upd0 : upd1 ))
target=$(( maxupd + 120 ))
info "block ts=$blkts  ETH/USD updatedAt=$upd0  BTC/USD updatedAt=$upd1"
if [ "$blkts" -lt "$target" ]; then
  delta=$(( target - blkts ))
  crpc evm_increaseTime "$(cast to-hex $delta)" >/dev/null
  crpc evm_mine >/dev/null
  ok "advanced clock +${delta}s → block ts $(cast block latest --rpc-url "$RPC" --field timestamp 2>/dev/null | field)"
else
  ok "feeds already fresh (block ts ≥ feed updatedAt)"
fi

# ── 3b. repair NFPM _nextId (Tenderly lazy-state hydration quirk) ──────────────
# On this vnet the Slipstream NFPM's packed _nextId/_nextPoolId slot (#14) hydrates to a value
# BEHIND real Base's counter, while _owners for the higher (already-minted) ids hydrate lazily on
# read — so a fresh mint reverts "ERC721: token already minted". Copy real Base's authoritative
# slot 14 onto the vnet (+1000 id margin) so the next mint lands on a genuinely-free id. Confirmed
# empirically: this slot packs (_nextPoolId<<176 | _nextId) on this exact NFPM.
NFPM_NEXTID_SLOT=0x000000000000000000000000000000000000000000000000000000000000000e
repair_nfpm_counter() {
  local real
  if [ -n "${BASE_RPC_URL:-}" ] && [ "$BASE_RPC_URL" != "..." ]; then
    real="$(cast storage "$NFPM" 14 --rpc-url "$BASE_RPC_URL" 2>/dev/null)"
  fi
  local vnet; vnet="$(cast storage "$NFPM" 14 --rpc-url "$RPC" 2>/dev/null)"
  local newslot
  newslot="$(python3 - "${real:-0x0}" "$vnet" <<'PY'
import sys
real = int(sys.argv[1], 16)
vnet = int(sys.argv[2], 16)
poolId = vnet >> 176                      # preserve the vnet's _nextPoolId
real_nextId = real & ((1 << 176) - 1)
vnet_nextId = vnet & ((1 << 176) - 1)
# use the authoritative real counter when available, else bump the vnet's own; +1000 id margin
base = real_nextId if real_nextId > vnet_nextId else vnet_nextId
print("0x%064x" % ((poolId << 176) | (base + 1000)))
PY
)"
  crpc tenderly_setStorageAt "$NFPM" "$NFPM_NEXTID_SLOT" "$newslot" >/dev/null
  ok "repaired NFPM _nextId → slot14=$newslot"
}

# ── cheat-rpc fund helper ──────────────────────────────────────────────────────
fund_sender() {
  crpc tenderly_setBalance "[\"$SENDER\"]" "$ETH_FUND_HEX" >/dev/null
  crpc tenderly_setErc20Balance "$WETH"  "$SENDER" "$WETH_FUND_HEX"  >/dev/null
  crpc tenderly_setErc20Balance "$CBBTC" "$SENDER" "$CBBTC_FUND_HEX" >/dev/null
}
advance_time() { crpc evm_increaseTime "$(cast to-hex "$1")" >/dev/null; crpc evm_mine >/dev/null; }

# ── forge phase runners ────────────────────────────────────────────────────────
# run a --sig entrypoint; $2=broadcast(0/1). Tees output to results; returns forge's status.
run_phase() {
  local sig="$1" broadcast="$2"; shift 2
  local full="$ROOT/script/tenderly/.phase-$(echo "$sig" | tr -cd 'a-zA-Z').log"
  # --no-storage-caching is REQUIRED: this vnet reports chain id 8453 (same as real Base), so
  # forge's fork cache (keyed by chain id) would otherwise serve stale real-Base slots mixed with
  # live vnet slots — e.g. a stale NFPM _nextId against real _owners → "ERC721: token already minted".
  # (moonwell-tenderly avoids this by giving vnets a unique chain id, 73570+networkId.)
  local flags=(--rpc-url "$RPC" --private-key "$MAMO_DEPLOYER_PRIVATE_KEY" --sig "$sig" --no-storage-caching -vvv)
  # --gas-estimate-multiplier 300: the vnet's eth_estimateGas can under-estimate txs with deep
  # nested delegatecalls (e.g. exit()'s final cbBTC FiatToken/USDC-proxy transfer OOG'd at the
  # tight 1.3x default due to the EIP-150 63/64 forwarding rule). 3x headroom is safe on a fork.
  [ "$broadcast" = "1" ] && flags+=(--broadcast --slow --gas-estimate-multiplier 300)
  forge script "$FQ" "${flags[@]}" > "$full" 2>&1
  local rc=$?
  # surface the harness's own log lines + any failure context
  grep -E "HARNESS_LAB=|setup\.|reset\.|exit\.|roleGating\.|calmGate\.|\[OK\]" "$full" | tee -a "$RESULTS"
  if [ "$rc" != "0" ]; then
    warn "forge exited $rc — failure context from $full:"
    grep -iE "error|revert|panic|fail|require|0x[0-9a-f]{8}" "$full" | grep -vE "exclude_lints|nightly|preprocessed" | tail -25 | tee -a "$RESULTS"
  fi
  return "$rc"
}

capture_lab() {
  # forge names the broadcast artifact after the --sig entrypoint; the deploy happens in deployAndMint().
  local art="broadcast/LPV2TenderlyHarness.s.sol/8453/deployAndMint-latest.json"
  HARNESS_LAB="$(jq -r '[.transactions[] | select(.transactionType=="CREATE")][0].contractAddress' "$art" 2>/dev/null)"
  [ -n "$HARNESS_LAB" ] && [ "$HARNESS_LAB" != "null" ] || die "could not read deployed lab address from $art"
  export HARNESS_LAB
  info "deployed LPAutoBalancerV2 → $HARNESS_LAB"
}

# Read the REAL minted tokenId from chain (NFPM is ERC721Enumerable; lab holds exactly one NFT).
# Avoids trusting forge's simulated mint return, which can diverge from the broadcast id on a live fork.
capture_token_id() {
  HARNESS_TOKEN_ID="$(ccall "$NFPM" 'tokenOfOwnerByIndex(address,uint256)(uint256)' "$HARNESS_LAB" 0 | field)"
  [ -n "$HARNESS_TOKEN_ID" ] && [ "$HARNESS_TOKEN_ID" != "0" ] || die "could not read minted tokenId held by lab"
  export HARNESS_TOKEN_ID
  info "minted position tokenId (held by lab) → $HARNESS_TOKEN_ID"
}

# ── 4. repair the NFPM counter so fresh mints land on a free id ────────────────
section "4. Repair NFPM _nextId (lazy-hydration quirk)"
repair_nfpm_counter

# ── 5. run scenarios ───────────────────────────────────────────────────────────
PASS=0; TOTAL=0
for scen in "${SCENARIOS[@]}"; do
  export HARNESS_SCENARIO="$scen"
  section "Scenario: $scen — fund → deploy/register → role gate → reset → exit"
  fund_sender; ok "funded sender (100 ETH / 1000 WETH / 50 cbBTC)"

  info "→ deployAndMint() [deploy balancer + mint a real WETH/cbBTC position into it]"
  run_phase "deployAndMint()" 1 || die "deployAndMint() failed for $scen"
  capture_lab
  capture_token_id

  info "→ registerStake() [register the held NFT$([ "$scen" = balanced ] && echo ' + stake')]"
  run_phase "registerStake()" 1 || die "registerStake() failed for $scen"

  info "→ checkRoleGating() [unprivileged caller must revert]"
  run_phase "checkRoleGating()" 0 || die "checkRoleGating() failed for $scen"

  if [ "$scen" = "balanced" ]; then
    info "→ advance vnet clock +2h so the staked main accrues AERO"
    advance_time 7200; ok "clock advanced +7200s"
  fi

  info "→ doReset() [no-swap rebuild + conservation/value-floor/cooldown measurements]"
  run_phase "doReset()" 1 || die "doReset() failed for $scen"

  info "→ doExit() [Safe-gated full teardown returns all principal]"
  run_phase "doExit()" 1 || die "doExit() failed for $scen"

  ok "scenario '$scen' completed"
done

# ── 6. summary ─────────────────────────────────────────────────────────────────
section "Summary"
oks=$(grep -c '\[OK\]' "$RESULTS" || true)
info "entrypoint [OK] markers: $oks"
ok "Harness run complete. Full log + measurements: $RESULTS"
[ "$CREATED_VNET" = "1" ] && [ "$KEEP_VNET" = "1" ] && info "vnet kept: $RPC"
echo
