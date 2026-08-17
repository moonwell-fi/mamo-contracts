#!/usr/bin/env bash
# ==============================================================================
# run-leveraged-aero-account.sh — MamoLeveragedAeroStrategy account Tenderly harness
# ==============================================================================
# Executes the ACCOUNT LAYER of the leveraged-Aero deployment against a LIVE,
# PERSISTENT Tenderly Base-fork vnet on which the POOLED LAYER (LeveragedAeroVault +
# a LeveragedAerodromeCLStrategy clone) is ALREADY deployed, then runs an end-to-end
# smoke of the account wrapper. Replays proposal 012's build()+validate() plus the full
# user lifecycle as real broadcast txs, using Tenderly UNLOCKED impersonation (no
# private keys) for MAMO_MULTISIG / DEPLOYER_EOA / the strategy proposer / a fresh
# throwaway user.
#
#   Phase 2  deploy impl + factory (real LeveragedAeroAccountDeployer path)
#   Phase 3  the 3 multisig actions (whitelist / grantRole / setOpenDeposits) + validate
#   Phase 4  e2e: create → deposit → fast withdraw → requestWithdraw → fulfill →
#            claim → depositIdle gate → withdrawAll → clean-state asserts
#
# Both layers live in THIS repo as of PR #66 (the Sherwood dependency is gone). The pooled
# layer is deployed by its own harness — `run-leveraged-aero-stack.sh` (`make
# tenderly-leveraged-aero-stack`), runbook Phase B — which must run FIRST on a fresh vnet.
#
# ── WHY --reuse IS FORCED ─────────────────────────────────────────────────────
# The vault + strategy clone live ONLY on the shared persistent vnet; a freshly
# API-created Base fork would not have them. So this harness ALWAYS reuses
# TENDERLY_VNET_RPC_URL (the vnet's ADMIN RPC — it accepts eth_sendTransaction from
# any unlocked sender AND serves reads). It never creates or tears down a vnet.
#
# ── FEED FRESHNESS ────────────────────────────────────────────────────────────
# A Base fork's Chainlink answers are frozen, so updatedAt recedes as the clock advances
# and every priced path bricks with StaleOracle in ~1 day. Fix = the FreshFeed pattern:
# code-replace the 5 venue feeds (leg A/USD, leg B/USD, USDC/USD, AERO/USD, L2 sequencer
# uptime) with mocks whose updatedAt tracks block.timestamp, so warping never stales them.
# The shared instance carries those mocks. The in-repo implementation is
# script/tenderly/FreshFeed.sol, applied by run-leveraged-aero-stack.sh phase B.0. On an
# instance WITHOUT the mocks the old rule applies: never warp, feeds stale in ~1 day. This
# harness does no time travel either way; the 2-day emergencyWithdraw path stays
# unit-test-covered.
#
# ── ADDRESS RESOLUTION ────────────────────────────────────────────────────────
# The two address keys are NOT committed to addresses/8453.json: FPS Addresses
# validates isContract EAGERLY in its constructor (gated on chainId==block.chainid),
# so committing them with isContract:true would revert the Addresses constructor on
# every real-Base-mainnet CI run. They are supplied here via env vars (documented
# defaults = current vnet values) and injected at runtime inside the deploy .s.sol.
# The env-var names are STALE BUT REAL: SHERWOOD_LEVERAGED_AERO_STRATEGY (also
# factory.sherwoodStrategy()) and SHERWOOD_SYNDICATE_VAULT, even though proposal 012 now
# resolves the vault under the LEVERAGED_AERO_VAULT key. Dropping the SHERWOOD_ prefix is
# a pending cleanup; it implies no remaining Sherwood dependency.
#
# Usage:
#   TENDERLY_VNET_RPC_URL=<admin-rpc> ./script/tenderly/run-leveraged-aero-account.sh
#   make tenderly-leveraged-aero-account
# Optional env overrides (defaults = current vnet):
#   SHERWOOD_LEVERAGED_AERO_STRATEGY, SHERWOOD_SYNDICATE_VAULT
#   HARNESS_USER (skip fresh-user generation and reuse a given EOA)
#
# Requires: forge, cast, jq, python3. Reads .env.
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$ROOT/script/tenderly/harness-results-leveraged-aero.log}"
: > "$RESULTS"

HARNESS_SLUG="leveraged-aero-account"
HARNESS_DISPLAY="MamoLeveragedAeroStrategy account harness"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FQ="script/tenderly/LeveragedAeroAccountHarness.s.sol:LeveragedAeroAccountHarness"

# ── documented vnet defaults (overridable via env) ────────────────────────────
# Pooled layer on the current persistent vnet. The hardcoded fallbacks at the bottom of this
# block are Sherwood-era leftovers and are the LAST resort only — the live instance runs the
# in-repo LeveragedAeroVault (generation 3: depositsOpen(), redeemSettled, maxTotalAssets()),
# and the generation probe further down refuses anything below 3. See the runbook's
# "Current live instance".
# These are env-var DEFAULTS, not hardcoded logic: pass your own to point elsewhere.
#
# Resolution order: env var → the pooled addresses recorded in leveraged-aero-vnet.json by
# run-leveraged-aero-stack.sh (the pooled-layer harness, which emits into the SAME file) →
# the hardcoded fallback. That way a fresh pooled deploy is picked up automatically.
_CFG="$ROOT/script/tenderly/leveraged-aero-vnet.json"
_cfg_pooled() { jq -r --arg k "$1" '.pooled[$k] // empty' "$_CFG" 2>/dev/null; }
export SHERWOOD_LEVERAGED_AERO_STRATEGY="${SHERWOOD_LEVERAGED_AERO_STRATEGY:-$(_cfg_pooled strategyClone)}"
export SHERWOOD_SYNDICATE_VAULT="${SHERWOOD_SYNDICATE_VAULT:-$(_cfg_pooled vault)}"
export SHERWOOD_LEVERAGED_AERO_STRATEGY="${SHERWOOD_LEVERAGED_AERO_STRATEGY:-0x5E22913E4C96f816133fbc8E894F652a4f87C760}"
export SHERWOOD_SYNDICATE_VAULT="${SHERWOOD_SYNDICATE_VAULT:-0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9}"
# Optional: the vnet's PUBLIC (read-only) RPC — recorded into the emitted config for consumers.
# NEVER put the admin RPC in the config; it accepts unlocked writes and lives in 1Password only.
TENDERLY_VNET_PUBLIC_RPC_URL="${TENDERLY_VNET_PUBLIC_RPC_URL:-}"

# Base per-tx gas cap is 16,777,216; the impl+factory CREATEs are well under it at 2x.
DEPLOY_GAS_MULT=200
ETH_FUND_HEX=0x56BC75E2D63100000     # 100 ETH
USDC_FUND_HEX=0x2540BE400            # 10,000 USDC (6dp)
DEPOSIT=5000000000                   # 5,000 USDC
IDLE_XFER=100000000                  # 100 USDC

# ── args ──────────────────────────────────────────────────────────────────────
# Force reuse: the pooled layer exists only on the persistent vnet (see header).
REUSE_VNET=1
KEEP_VNET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --reuse) REUSE_VNET=1; shift ;;
    *) echo "unknown arg: $1 (this harness always reuses the persistent vnet)"; exit 2 ;;
  esac
done

# Minimal env load (this harness uses UNLOCKED impersonation, so — unlike the LPV2
# harness — it needs NO broadcaster private key; do not require MAMO_DEPLOYER_PRIVATE_KEY).
# A TENDERLY_VNET_RPC_URL passed on the command line MUST win over .env (the .env value may point at
# a different vnet without the pooled layer), so preserve a caller-set value across the source.
_CLI_VNET_RPC="${TENDERLY_VNET_RPC_URL:-}"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
[ -n "$_CLI_VNET_RPC" ] && export TENDERLY_VNET_RPC_URL="$_CLI_VNET_RPC"

# ── gas headroom for the vnet's UNDER-estimating eth_estimateGas ──────────────
# Same class of bug that run_forge_phase's --gas-estimate-multiplier exists for, but on the plain
# `cast send` path: Tenderly's estimator under-shoots deep nested calls. Observed exactly once here —
# `fulfillRedeem(id)` (nav() → crystallise → redeemUnwindImpl → Slipstream burn/collect → skim
# transfers) estimated 1,644,942, was sent with that as the limit, and consumed all of it: status 0x0,
# EMPTY revert data, gasUsed == gasLimit, while a `cast call` of the same call at the same state
# returned successfully. `cast send` ships the bare estimate with no multiplier, so every send below
# now carries an explicit 2x limit instead. Floored at 1M (cheap calls) and capped at 16,000,000 —
# just under Base's per-tx gas cap of 16,777,216 (2^24), which a blind multiply would otherwise blow
# past into TxGasLimitGreaterThanCap. If the estimate itself fails (a genuinely reverting call, e.g.
# the intentional depositIdle negative test) this emits nothing and the send falls back to cast's own
# estimate, preserving the original failure diagnostics.
GAS_CAP=16000000
gas_flags() {   # usage: gas_flags <from> <to> <sig> [args...] → echoes "--gas-limit N", or nothing
  local from="$1" to="$2"; shift 2
  local est; est="$(cast estimate "$to" "$@" --from "$from" --rpc-url "$RPC" 2>/dev/null | field)"
  case "$est" in '' | *[!0-9]*) return 0 ;; esac
  local lim=$(( est * 2 ))
  [ "$lim" -lt 1000000 ] && lim=1000000
  [ "$lim" -gt "$GAS_CAP" ] && lim="$GAS_CAP"
  echo "--gas-limit $lim"
}

# ── cast send via unlocked impersonation; asserts status 0x1; echoes tx hash ──
# usage: csend <label> <from> <to> <sig> [args...]
csend() {
  local label="$1" from="$2" to="$3" sig="$4"; shift 4
  # unquoted on purpose: word-splits into `--gas-limit N`, or vanishes when the estimate failed.
  local gl; gl="$(gas_flags "$from" "$to" "$sig" "$@")"
  local out; out="$(cast send "$to" "$sig" "$@" --from "$from" --unlocked $gl --rpc-url "$RPC" --json 2>/dev/null)"
  local st tx; st="$(echo "$out" | jq -r '.status')"; tx="$(echo "$out" | jq -r '.transactionHash')"
  [ "$st" = "0x1" ] || die "$label failed (status=$st tx=$tx)"
  ok "$label — tx $tx"
  LAST_TX="$tx"
}

# ── 1. resolve vnet (reuse) + sanity ──────────────────────────────────────────
resolve_vnet
chain_sanity
REG="$(addr MAMO_STRATEGY_REGISTRY)"
USDC="$(addr USDC)"
MULTISIG="$(addr MAMO_MULTISIG)"
DEPLOYER="$(addr DEPLOYER_EOA)"
STRAT="$SHERWOOD_LEVERAGED_AERO_STRATEGY"
VAULT="$SHERWOOD_SYNDICATE_VAULT"
[ "$(ccall "$STRAT" 'vault()(address)' | field | tr 'A-Z' 'a-z')" = "$(echo "$VAULT" | tr 'A-Z' 'a-z')" ] \
  || die "strategy.vault() != SHERWOOD_SYNDICATE_VAULT (env var name is stale; it holds the LeveragedAeroVault)"
ok "pooled layer wired: strategy=$STRAT vault=$VAULT state=$(ccall "$STRAT" 'state()(uint8)' | field)"
# Which vault generation is under us? The in-repo LeveragedAeroVault exposes depositsOpen()
# (+ redeemSettled); the pre-PR-#66 Sherwood SyndicateVault exposed openDeposits(). The account
# ABI is identical either way, so the smoke below is valid on both — but the getter name and the
# emitted config must follow the live contract.
#
# GEN 3 MUST BE PROBED FIRST AND SEPARATELY. The STRATEGY now makes a TYPED `maxTotalAssets()` call
# on the vault inside its fund-capacity check, and the vault is NOT upgradeable — so a current
# strategy bound to a gen-2 vault reverts on EVERY deposit with empty returndata (Solidity's
# codesize+returndata guard, no decodable reason). `depositsOpen()` cannot distinguish the two
# generations because gen 2 answers it too, which is exactly how that hazard would reach a live vnet
# undetected. Probing the capacity selector is the only reliable discriminator.
if [ -n "$(ccall "$VAULT" 'maxTotalAssets()(uint256)')" ]; then
  VAULT_GEN=3
  VAULT_GEN_NAME="leveraged-aero-vault (in-repo: + maxTotalAssets(), remainingCapacity())"
  DEPOSITS_OPEN_SIG='depositsOpen()(bool)'
elif [ -n "$(ccall "$VAULT" 'depositsOpen()(bool)')" ]; then
  VAULT_GEN=2
  VAULT_GEN_NAME="leveraged-aero-vault (in-repo: depositsOpen(), cloneAndBind, redeemSettled)"
  DEPOSITS_OPEN_SIG='depositsOpen()(bool)'
else
  VAULT_GEN=1
  VAULT_GEN_NAME="sherwood-syndicate-vault (legacy: openDeposits(), no redeemSettled)"
  DEPOSITS_OPEN_SIG='openDeposits()(bool)'
fi
info "vault generation: $VAULT_GEN — $VAULT_GEN_NAME"
# Fail EARLY and loudly rather than at the first deposit with empty returndata.
if [ "$VAULT_GEN" -lt 3 ]; then
  die "vault at $VAULT predates maxTotalAssets() (generation $VAULT_GEN). The strategy's fund-capacity
  check calls it on every deposit and the vault is not upgradeable, so every deposit here would revert
  with empty returndata. Redeploy the pooled layer first: make tenderly-leveraged-aero-stack"
fi

# ── Phase 2: deploy impl + factory ────────────────────────────────────────────
section "Phase 2 — deploy implementation + factory (DEPLOYER_EOA, unlocked)"
fund_eth "$DEPLOYER" "$ETH_FUND_HEX"
DEPLOY_LOG="$ROOT/script/tenderly/.phase-leveraged-aero-deploy.log"
forge script "$FQ" --sig 'deploy()' --rpc-url "$RPC" --broadcast --slow --unlocked \
  --sender "$DEPLOYER" --no-storage-caching --gas-estimate-multiplier "$DEPLOY_GAS_MULT" -vvv \
  > "$DEPLOY_LOG" 2>&1 || { grep -iE "error|revert|fail" "$DEPLOY_LOG" | tail -20 | tee -a "$RESULTS"; die "deploy() failed"; }
IMPL="$(grep -oE 'HARNESS_IMPL=0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | head -1 | cut -d= -f2)"
FACTORY="$(grep -oE 'HARNESS_FACTORY=0x[0-9a-fA-F]{40}' "$DEPLOY_LOG" | head -1 | cut -d= -f2)"
[ -n "$IMPL" ] && [ -n "$FACTORY" ] || die "could not parse impl/factory from deploy log"
ok "impl=$IMPL"
ok "factory=$FACTORY"

# ── Phase 3: the 3 multisig actions + validate ────────────────────────────────
section "Phase 3 — multisig build() (whitelist / grantRole / setOpenDeposits)"
fund_eth "$MULTISIG" "$ETH_FUND_HEX"
BR="$(ccall "$REG" 'BACKEND_ROLE()(bytes32)')"
[ "$(ccall "$REG" 'latestImplementationById(uint256)(address)' 5 | field)" = "$IMPL" ] \
  && warn "type 5 already points at this impl (re-run)" || true
csend "whitelistImplementation(impl,5)" "$MULTISIG" "$REG" 'whitelistImplementation(address,uint256)' "$IMPL" 5
csend "grantRole(BACKEND_ROLE,factory)" "$MULTISIG" "$REG" 'grantRole(bytes32,address)' "$BR" "$FACTORY"
csend "vault.setOpenDeposits(true)"     "$MULTISIG" "$VAULT" 'setOpenDeposits(bool)' true

section "Phase 3 — validate() asserts"
assert_eq() { [ "$2" = "$3" ] && ok "$1 == $3" || die "$1 mismatch: got $2 want $3"; }
assert_eq "whitelistedImplementations(impl)" "$(ccall "$REG" 'whitelistedImplementations(address)(bool)' "$IMPL")" "true"
assert_eq "implementationToId(impl)"         "$(ccall "$REG" 'implementationToId(address)(uint256)' "$IMPL" | field)" "5"
assert_eq "latestImplementationById(5)"      "$(ccall "$REG" 'latestImplementationById(uint256)(address)' 5 | field)" "$IMPL"
assert_eq "factory hasRole(BACKEND_ROLE)"    "$(ccall "$REG" 'hasRole(bytes32,address)(bool)' "$BR" "$FACTORY")" "true"
# $DEPOSITS_OPEN_SIG was resolved above from the live vault generation (depositsOpen vs openDeposits).
assert_eq "vault deposits open"              "$(ccall "$VAULT" "$DEPOSITS_OPEN_SIG")" "true"
assert_eq "factory.strategyTypeId()"         "$(ccall "$FACTORY" 'strategyTypeId()(uint256)' | field)" "5"
assert_eq "factory.sherwoodStrategy()"       "$(ccall "$FACTORY" 'sherwoodStrategy()(address)' | field | tr A-Z a-z)" "$(echo "$STRAT" | tr A-Z a-z)"
assert_eq "factory.usdc()"                   "$(ccall "$FACTORY" 'usdc()(address)' | field | tr A-Z a-z)" "$(echo "$USDC" | tr A-Z a-z)"

# ── Phase 4: e2e smoke with a fresh throwaway user ────────────────────────────
section "Phase 4 — end-to-end account smoke"
if [ -n "${HARNESS_USER:-}" ]; then
  USER="$HARNESS_USER"; info "reusing HARNESS_USER=$USER"
else
  NEWW="$(cast wallet new)"
  USER="$(echo "$NEWW" | awk '/Address:/{print $2}')"
  UKEY="$(echo "$NEWW" | awk '/Private key:/{print $3}')"
  info "fresh throwaway user: $USER"
  info "fresh throwaway key : $UKEY   (fork-only; recorded for repeatability)"
fi
fund_eth "$USER" "$ETH_FUND_HEX"
fund_erc20 "$USDC" "$USER" "$USDC_FUND_HEX"

# create
csend "createStrategyForUser(user)" "$USER" "$FACTORY" 'createStrategyForUser(address)' "$USER"
ACCT="$(ccall "$FACTORY" 'computeStrategyAddress(address)(address)' "$USER" | field)"
assert_eq "isUserStrategy(user,acct)" "$(ccall "$REG" 'isUserStrategy(address,address)(bool)' "$USER" "$ACCT")" "true"
assert_eq "account.owner()"           "$(ccall "$ACCT" 'owner()(address)' | field | tr A-Z a-z)" "$(echo "$USER" | tr A-Z a-z)"
info "account = $ACCT"

# deposit 5,000 USDC (minShares from the vendored formula shares=assets*(supply+1e6)/(navNet+1), 1% tol)
NAV="$(ccall "$STRAT" 'nav()(uint256)' | field)"; SUP="$(ccall "$VAULT" 'totalSupply()(uint256)' | field)"
MINSH="$(python3 -c "print(($DEPOSIT*($SUP+10**6)//($NAV+1))*99//100)")"
csend "approve(account,5000 USDC)" "$USER" "$USDC" 'approve(address,uint256)' "$ACCT" "$DEPOSIT"
csend "deposit(5000 USDC, minShares)" "$USER" "$ACCT" 'deposit(uint256,uint256)' "$DEPOSIT" "$MINSH"
SH="$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)"
[ "$SH" -gt 0 ] 2>/dev/null && ok "sharesBalance=$SH (>0)" || die "no shares minted"
assert_eq "vault.balanceOf(account)" "$(ccall "$VAULT" 'balanceOf(address)(uint256)' "$ACCT" | field)" "$SH"

# fast withdraw half
HALF=$((SH/2))
EXP="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$HALF" | sed -n 1p | field)"
MINOUT="$(python3 -c "print($EXP*99//100)")"
UBEF="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
csend "withdraw(half, minOut)" "$USER" "$ACCT" 'withdraw(uint256,uint256)' "$HALF" "$MINOUT"
UAFT="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
[ "$UAFT" -gt "$UBEF" ] 2>/dev/null && ok "USDC landed on USER (+$((UAFT-UBEF)))" || die "fast withdraw did not pay the user"
assert_eq "account USDC after fast withdraw" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"

# async request → fulfill (proposer) → claim
REM="$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)"
REQSIG="$(cast keccak 'WithdrawRequested(uint256,uint256,uint256)')"
# Raw send rather than csend: the request id is only recoverable from the receipt logs. Same
# explicit gas limit as csend (see gas_flags) — unquoted on purpose.
RQGL="$(gas_flags "$USER" "$ACCT" 'requestWithdraw(uint256,uint256)' "$REM" 1)"
RC="$(cast send "$ACCT" 'requestWithdraw(uint256,uint256)' "$REM" 1 --from "$USER" --unlocked $RQGL --rpc-url "$RPC" --json 2>/dev/null)"
[ "$(echo "$RC" | jq -r '.status')" = "0x1" ] || die "requestWithdraw failed"
ID="$(cast to-dec "$(echo "$RC" | jq -r --arg a "$(echo "$ACCT" | tr A-Z a-z)" --arg s "$REQSIG" '.logs[] | select((.address|ascii_downcase)==$a and .topics[0]==$s) | .topics[1]')")"
ok "requestWithdraw — id=$ID tx=$(echo "$RC" | jq -r '.transactionHash')"
assert_eq "account sharesBalance escrowed" "$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)" "0"

PROPOSER="$(ccall "$STRAT" 'proposer()(address)' | field)"
fund_eth "$PROPOSER" "$ETH_FUND_HEX"
csend "fulfillRedeem(id) [proposer]" "$PROPOSER" "$STRAT" 'fulfillRedeem(uint256,uint256)' "$ID" 0
FA="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)"
[ "$FA" -gt 0 ] 2>/dev/null && ok "fulfill landed USDC on ACCOUNT (+$FA)" || die "fulfill did not land USDC on account"
csend "claimWithdrawnUsdc() [user]" "$USER" "$ACCT" 'claimWithdrawnUsdc()'
assert_eq "account USDC after claim" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"

# depositIdle gate: third address reverts; registry backend succeeds
section "Phase 4 — depositIdle gate"
csend "user transfers 100 USDC to account" "$USER" "$USDC" 'transfer(address,uint256)' "$ACCT" "$IDLE_XFER"
THIRD=0x00000000000000000000000000000000DeaDBeef
fund_eth "$THIRD" "$ETH_FUND_HEX"
# REAL 2-arg signature and the REAL transferred amount. Against the old 1-arg form this "reverted"
# on an unknown selector, i.e. it passed for the wrong reason and asserted no access control at all.
# Passing a valid amount (not 0) also keeps `require(assets > 0)` from being the thing that fires, so
# the ONLY remaining reason to revert is the caller identity.
if cast send "$ACCT" 'depositIdle(uint256,uint256)' "$IDLE_XFER" 0 --from "$THIRD" --unlocked --rpc-url "$RPC" >/dev/null 2>&1; then
  die "depositIdle from a third party should have reverted"
else
  ok "depositIdle reverts for a non-owner/non-backend third party (Not owner or backend)"
fi
# The gate checks registry.getBackendAddress() (BACKEND_ROLE member index 0) — NOT the
# address-book MAMO_BACKEND. On this fork those differ; use the live value.
REGBACKEND="$(ccall "$REG" 'getBackendAddress()(address)' | field)"
info "registry.getBackendAddress() = $REGBACKEND"
fund_eth "$REGBACKEND" "$ETH_FUND_HEX"
# Must pass the ACTUAL transferred idle amount: the caller now picks the amount (that is what makes
# the fund capacity ceiling usable — it rejects rather than trims, so a partial deposit has to be
# expressible), and `require(assets > 0)` rejects the old `0` sentinel outright.
csend "depositIdle(IDLE_XFER, 0) [registry backend]" "$REGBACKEND" "$ACCT" 'depositIdle(uint256,uint256)' "$IDLE_XFER" 0
IDLESH="$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)"
[ "$IDLESH" -gt 0 ] 2>/dev/null && ok "depositIdle minted shares=$IDLESH" || die "depositIdle minted no shares"

# clean up: withdraw the idle-deposited shares back to the user
EXP2="$(ccall "$ACCT" 'previewWithdraw(uint256)(uint256,bool)' "$IDLESH" | sed -n 1p | field)"
csend "withdrawAll(minOut) [cleanup]" "$USER" "$ACCT" 'withdrawAll(uint256)' "$(python3 -c "print($EXP2*99//100)")"

# ── final clean-state asserts + net delta ─────────────────────────────────────
section "Phase 4 — final state"
assert_eq "account sharesBalance()" "$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)" "0"
assert_eq "account USDC balance"    "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"
UEND="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$USER" | field)"
info "user USDC final = $UEND  (net vs 10,000 start = $(python3 -c "print(($UEND-10000000000)/1e6)") USDC — fees+rounding)"

section "Summary"
ok "Leveraged-Aero account harness complete. impl=$IMPL factory=$FACTORY account=$ACCT"

# ── machine-consumable config for downstream consumers (frontend env / indexer / keeper) ──────
# Committed alongside the harness and refreshed by every successful run. Contains ONLY read-safe
# values; the admin RPC is intentionally excluded (1Password only).
#
# MERGE-WRITE, not clobber: run-leveraged-aero-stack.sh (the pooled-layer harness) emits into the
# SAME file and owns `pooled` + `feeds`, while this harness owns `mamo`. Both merge onto whatever
# is already there (`$prev * {…}`) so the two can run in either order without erasing each other's
# fields. Only the pooled keys this harness actually knows (vault + clone) are (re)written here.
CONFIG_JSON="$ROOT/script/tenderly/leveraged-aero-vnet.json"
PREV='{}'; [ -f "$CONFIG_JSON" ] && PREV="$(cat "$CONFIG_JSON")"
jq -n \
  --argjson prev "$PREV" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg chainId "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || echo 8453)" \
  --arg publicRpc "$TENDERLY_VNET_PUBLIC_RPC_URL" \
  --arg impl "$IMPL" --arg factory "$FACTORY" \
  --arg strategy "$STRAT" --arg vault "$VAULT" \
  --arg registry "$REG" --arg usdc "$USDC" \
  --argjson vaultGen "$VAULT_GEN" \
  --arg vaultGenName "$VAULT_GEN_NAME" \
  '$prev * {
    generatedAt: $ts,
    # chainId is READ FROM THE RPC, never hardcoded: a vnet may report a custom chain id
    # (e.g. 73578453) and downstream consumers wire wallets/networks from this field.
    chainId: ($chainId | tonumber),
    publicRpc: (if $publicRpc == "" then ($prev.publicRpc // null) else $publicRpc end),
    adminRpc: "1Password (write-capable — never committed)",
    strategyTypeId: 5,
    mamo: { accountImplementation: $impl, accountFactory: $factory, strategyRegistry: $registry },
    pooled: { strategyClone: $strategy, vault: $vault },
    sherwood: { strategyClone: $strategy, syndicateVault: $vault },
    usdc: $usdc,
    note: "Addresses change when the instance rotates or a harness redeploys — always read this file, never hardcode. pooled = the LeveragedAeroVault + its LeveragedAerodromeCLStrategy clone (both in-repo since PR #66 removed the Sherwood dependency), written by run-leveraged-aero-stack.sh; mamo = the account layer, written by run-leveraged-aero-account.sh; sherwood is a deprecated alias of pooled, kept for existing consumers and due for removal. Feeds on the shared instance are FreshFeed-mocked (never stale). Re-run the two harnesses after any refresh to regenerate.",
    vaultGeneration: $vaultGen,
    vaultGenerationName: $vaultGenName
  }' > "$CONFIG_JSON"
ok "config emitted: $CONFIG_JSON"
info "Full log: $RESULTS"
echo
