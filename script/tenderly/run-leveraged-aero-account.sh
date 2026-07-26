#!/usr/bin/env bash
# ==============================================================================
# run-leveraged-aero-account.sh — MamoLeveragedAeroStrategy account Tenderly harness
# ==============================================================================
# Executes the Mamo side of the leveraged-Aero account deployment against a LIVE,
# PERSISTENT Tenderly Base-fork vnet on which the Sherwood stack (SyndicateVault +
# LeveragedAerodromeCLStrategy) is ALREADY deployed, then runs an end-to-end smoke
# of the account wrapper. Replays proposal 012's build()+validate() plus the full
# user lifecycle as real broadcast txs, using Tenderly UNLOCKED impersonation (no
# private keys) for MAMO_MULTISIG / DEPLOYER_EOA / the strategy proposer / a fresh
# throwaway user.
#
#   Phase 2  deploy impl + factory (real LeveragedAeroAccountDeployer path)
#   Phase 3  the 3 multisig actions (whitelist / grantRole / setOpenDeposits) + validate
#   Phase 4  e2e: create → deposit → fast withdraw → requestWithdraw → fulfill →
#            claim → depositIdle gate → withdrawAll → clean-state asserts
#
# ── WHY --reuse IS FORCED ─────────────────────────────────────────────────────
# The Sherwood strategy/vault live ONLY on the shared persistent vnet; a freshly
# API-created Base fork would not have them. So this harness ALWAYS reuses
# TENDERLY_VNET_RPC_URL (the vnet's ADMIN RPC — it accepts eth_sendTransaction from
# any unlocked sender AND serves reads). It never creates or tears down a vnet.
#
# ── HARD CONSTRAINT ───────────────────────────────────────────────────────────
# NEVER time-warp this vnet (evm_increaseTime / evm_setNextBlockTimestamp): it ages
# the frozen Chainlink feeds and bricks NAV for everyone (StaleOracle). This harness
# does no time travel; the 2-day emergencyWithdraw path is covered by unit tests only.
#
# ── ADDRESS RESOLUTION ────────────────────────────────────────────────────────
# The two SHERWOOD_* keys are NOT committed to addresses/8453.json: FPS Addresses
# validates isContract EAGERLY in its constructor (gated on chainId==block.chainid),
# so committing them with isContract:true would revert the Addresses constructor on
# every real-Base-mainnet CI run. They are supplied here via env vars (documented
# defaults = current vnet values) and injected at runtime inside the deploy .s.sol.
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
# Sherwood stack on the current persistent vnet (block ~48.9M Base fork). These are
# env-var DEFAULTS, not hardcoded logic: pass your own to point at a different vnet.
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
# Force reuse: the Sherwood stack exists only on the persistent vnet (see header).
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
# a different vnet without the Sherwood stack), so preserve a caller-set value across the source.
_CLI_VNET_RPC="${TENDERLY_VNET_RPC_URL:-}"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }
[ -n "$_CLI_VNET_RPC" ] && export TENDERLY_VNET_RPC_URL="$_CLI_VNET_RPC"

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
  || die "sherwoodStrategy.vault() != SHERWOOD_SYNDICATE_VAULT"
ok "Sherwood wired: strategy=$STRAT vault=$VAULT state=$(ccall "$STRAT" 'state()(uint8)' | field)"

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
assert_eq "vault.openDeposits()"             "$(ccall "$VAULT" 'openDeposits()(bool)')" "true"
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
RC="$(cast send "$ACCT" 'requestWithdraw(uint256,uint256)' "$REM" 1 --from "$USER" --unlocked --rpc-url "$RPC" --json 2>/dev/null)"
[ "$(echo "$RC" | jq -r '.status')" = "0x1" ] || die "requestWithdraw failed"
ID="$(cast to-dec "$(echo "$RC" | jq -r --arg a "$(echo "$ACCT" | tr A-Z a-z)" --arg s "$REQSIG" '.logs[] | select((.address|ascii_downcase)==$a and .topics[0]==$s) | .topics[1]')")"
ok "requestWithdraw — id=$ID tx=$(echo "$RC" | jq -r '.transactionHash')"
assert_eq "account sharesBalance escrowed" "$(ccall "$ACCT" 'sharesBalance()(uint256)' | field)" "0"

PROPOSER="$(ccall "$STRAT" 'proposer()(address)' | field)"
fund_eth "$PROPOSER" "$ETH_FUND_HEX"
csend "fulfillRedeem(id) [proposer]" "$PROPOSER" "$STRAT" 'fulfillRedeem(uint256)' "$ID"
FA="$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)"
[ "$FA" -gt 0 ] 2>/dev/null && ok "fulfill landed USDC on ACCOUNT (+$FA)" || die "fulfill did not land USDC on account"
csend "claimWithdrawnUsdc() [user]" "$USER" "$ACCT" 'claimWithdrawnUsdc()'
assert_eq "account USDC after claim" "$(ccall "$USDC" 'balanceOf(address)(uint256)' "$ACCT" | field)" "0"

# depositIdle gate: third address reverts; registry backend succeeds
section "Phase 4 — depositIdle gate"
csend "user transfers 100 USDC to account" "$USER" "$USDC" 'transfer(address,uint256)' "$ACCT" "$IDLE_XFER"
THIRD=0x00000000000000000000000000000000DeaDBeef
fund_eth "$THIRD" "$ETH_FUND_HEX"
if cast send "$ACCT" 'depositIdle(uint256)' 0 --from "$THIRD" --unlocked --rpc-url "$RPC" >/dev/null 2>&1; then
  die "depositIdle from a third party should have reverted"
else
  ok "depositIdle reverts for a non-owner/non-backend third party (Not owner or backend)"
fi
# The gate checks registry.getBackendAddress() (BACKEND_ROLE member index 0) — NOT the
# address-book MAMO_BACKEND. On this fork those differ; use the live value.
REGBACKEND="$(ccall "$REG" 'getBackendAddress()(address)' | field)"
info "registry.getBackendAddress() = $REGBACKEND"
fund_eth "$REGBACKEND" "$ETH_FUND_HEX"
csend "depositIdle(0) [registry backend]" "$REGBACKEND" "$ACCT" 'depositIdle(uint256)' 0
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
CONFIG_JSON="$ROOT/script/tenderly/leveraged-aero-vnet.json"
jq -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg publicRpc "$TENDERLY_VNET_PUBLIC_RPC_URL" \
  --arg impl "$IMPL" --arg factory "$FACTORY" \
  --arg strategy "$STRAT" --arg vault "$VAULT" \
  --arg registry "$REG" --arg usdc "$USDC" \
  '{
    generatedAt: $ts,
    chainId: 8453,
    publicRpc: (if $publicRpc == "" then null else $publicRpc end),
    adminRpc: "1Password (write-capable — never committed)",
    strategyTypeId: 5,
    mamo: { accountImplementation: $impl, accountFactory: $factory, strategyRegistry: $registry },
    sherwood: { strategyClone: $strategy, syndicateVault: $vault },
    usdc: $usdc,
    note: "Vnet values rotate by design (frozen Chainlink feeds stale in ~1 day of drift). Re-run make tenderly-leveraged-aero-account after a vnet refresh to regenerate."
  }' > "$CONFIG_JSON"
ok "config emitted: $CONFIG_JSON"
info "Full log: $RESULTS"
echo
