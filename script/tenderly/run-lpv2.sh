#!/usr/bin/env bash
# ==============================================================================
# run-lpv2.sh — LPAutoBalancerV2 Tenderly Virtual TestNet harness orchestrator
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
# Reusable vnet plumbing lives in lib/common.sh; this file keeps only the
# LP-specific choreography. Addresses are resolved from addresses/8453.json.
#
# Usage:
#   ./script/tenderly/run-lpv2.sh                  # both scenarios (fresh vnet by default)
#   ./script/tenderly/run-lpv2.sh --scenario balanced
#   ./script/tenderly/run-lpv2.sh --reuse          # reuse TENDERLY_VNET_RPC_URL instead of creating
#   ./script/tenderly/run-lpv2.sh --keep           # keep a freshly-created vnet after the run
# (also reachable via the dispatcher: ./run-harness.sh [lpv2] [flags])
#
# Requires: forge, cast, jq, python3, curl. Reads .env.
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$ROOT/script/tenderly/harness-results.log}"
: > "$RESULTS"

# vnet naming + which forge log lines to surface into the results log
HARNESS_SLUG="lpv2-harness"
HARNESS_DISPLAY="LPAutoBalancerV2 harness"
PHASE_MARKERS='HARNESS_LAB=|setup\.|reset\.|exit\.|roleGating\.|calmGate\.|\[OK\]'
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FQ="script/tenderly/LPV2TenderlyHarness.s.sol:LPV2TenderlyHarness"

# funding amounts (hex wei / base units)
ETH_FUND_HEX=0x56BC75E2D63100000          # 100 ETH
WETH_FUND_HEX=0x3635C9ADC5DEA00000        # 1000 WETH (18-dec)
CBBTC_FUND_HEX=0x12A05F200                 # 50e8 = 5_000_000_000 cbBTC (8-dec)

# ── cli args ──────────────────────────────────────────────────────────────────
SCENARIOS=("balanced" "singlesided")
REUSE_VNET=0
KEEP_VNET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIOS=("$2"); shift 2 ;;
    --reuse)    REUSE_VNET=1; shift ;;   # reuse TENDERLY_VNET_RPC_URL instead of creating a fresh vnet
    --create)   REUSE_VNET=0; shift ;;   # explicit fresh vnet (now the default; kept for back-compat)
    --keep)     KEEP_VNET=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

load_env
trap teardown EXIT

# ── real Base addresses (single source of truth = addresses/8453.json) ────────
WETH="$(addr WETH)"
CBBTC="$(addr cbBTC)"
GAUGE="$(addr WETH_CBBTC_CL_GAUGE)"
NFPM="$(addr UNISWAP_V3_POSITION_MANAGER_AERODROME)"
AERO="$(addr AERO)"
ETH_USD="$(addr CHAINLINK_ETH_USD)"
BTC_USD="$(addr CHAINLINK_BTC_USD)"

# ── 1. resolve the vnet RPC ────────────────────────────────────────────────────
resolve_vnet

# ── 2. sanity-check the fork + protocol wiring ─────────────────────────────────
section "Verify fork is Base + protocol wiring intact"
chain_sanity
[ "$(ccall "$GAUGE" 'nft()(address)')" = "$NFPM" ] || die "gauge.nft() != expected NFPM"
[ "$(ccall "$GAUGE" 'rewardToken()(address)')" = "$AERO" ] || die "gauge.rewardToken() != AERO"
ok "gauge.nft()==NFPM and gauge.rewardToken()==AERO"

# ── 3. sender ─────────────────────────────────────────────────────────────────
# derive_sender reads the key from the env (not argv) via the harness sender() entrypoint — see common.sh
derive_sender "$FQ"
export HARNESS_SENDER="$SENDER"
info "sender (all-roles deployer): $SENDER"

# ── 4. oracle freshness ────────────────────────────────────────────────────────
ensure_feeds_fresh "$ETH_USD" "$BTC_USD"

# ── 5. repair NFPM _nextId so fresh mints land on a free id ────────────────────
section "Repair NFPM _nextId (lazy-hydration quirk)"
repair_nfpm_counter "$NFPM"

# ── LP-specific phase helpers ──────────────────────────────────────────────────
fund_sender() {
  fund_eth   "$SENDER" "$ETH_FUND_HEX"
  fund_erc20 "$WETH"  "$SENDER" "$WETH_FUND_HEX"
  fund_erc20 "$CBBTC" "$SENDER" "$CBBTC_FUND_HEX"
}

capture_lab() {
  # forge names the broadcast artifact after the --sig entrypoint; the deploy happens in deployAndMint().
  capture_created_address "broadcast/LPV2TenderlyHarness.s.sol/8453/deployAndMint-latest.json"
  HARNESS_LAB="$CREATED_ADDR"; export HARNESS_LAB
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

# ── 6. run scenarios ───────────────────────────────────────────────────────────
for scen in "${SCENARIOS[@]}"; do
  export HARNESS_SCENARIO="$scen"
  section "Scenario: $scen — fund → deploy/register → role gate → reset → exit"
  fund_sender; ok "funded sender (100 ETH / 1000 WETH / 50 cbBTC)"

  info "→ deployAndMint() [deploy balancer + mint a real WETH/cbBTC position into it]"
  # 200% (not the 300% default): the ~24KB CREATE estimates ~5.77M gas; 3x would exceed Base's
  # 16,777,216 per-tx gas cap. Deploy gas is deterministic, so 2x headroom is ample.
  run_forge_phase "$FQ" "deployAndMint()" 1 200 || die "deployAndMint() failed for $scen"
  capture_lab
  capture_token_id

  info "→ registerStake() [register the held NFT$([ "$scen" = balanced ] && echo ' + stake')]"
  run_forge_phase "$FQ" "registerStake()" 1 || die "registerStake() failed for $scen"

  info "→ checkRoleGating() [unprivileged caller must revert]"
  run_forge_phase "$FQ" "checkRoleGating()" 0 || die "checkRoleGating() failed for $scen"

  if [ "$scen" = "balanced" ]; then
    info "→ advance vnet clock +2h so the staked main accrues AERO"
    advance_time 7200; ok "clock advanced +7200s"
  fi

  info "→ doReset() [no-swap rebuild + conservation/value-floor/cooldown measurements]"
  run_forge_phase "$FQ" "doReset()" 1 || die "doReset() failed for $scen"

  info "→ doExit() [Safe-gated full teardown returns all principal]"
  run_forge_phase "$FQ" "doExit()" 1 || die "doExit() failed for $scen"

  ok "scenario '$scen' completed"
done

# ── 7. summary ─────────────────────────────────────────────────────────────────
section "Summary"
oks=$(grep -c '\[OK\]' "$RESULTS" || true)
info "entrypoint [OK] markers: $oks"
ok "Harness run complete. Full log + measurements: $RESULTS"
[ "$CREATED_VNET" = "1" ] && [ "$KEEP_VNET" = "1" ] && info "vnet kept: $RPC"
echo
