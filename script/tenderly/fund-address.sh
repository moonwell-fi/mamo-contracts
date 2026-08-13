#!/usr/bin/env bash
# ==============================================================================
# fund-address.sh — fund a wallet on a Tenderly Virtual TestNet via the Admin RPC
# ==============================================================================
# Uses Tenderly's admin-RPC cheat methods (write-capable RPC required):
#   tenderly_setBalance      — set the ETH balance
#   tenderly_setErc20Balance — set any ERC20 balance (no whale needed)
# Both SET the balance to the given value (they do not add to it).
#
# Usage:
#   ./script/tenderly/fund-address.sh <wallet> [--eth <amount>] [--usdc <amount>]
#                                     [--erc20 <token> <amount>] [--rpc-url <admin-rpc>]
#
# Amounts are HUMAN units (10 = 10 ETH, 50000 = 50k USDC); decimals are read
# from the token. With no amount flags, defaults to --eth 10.
# The RPC comes from --rpc-url, else $TENDERLY_VNET_RPC_URL, else .env.
#
# Examples:
#   ./script/tenderly/fund-address.sh 0x0b491d1D47E88D546675a6b836C8738ec007ac29
#   ./script/tenderly/fund-address.sh 0x0b49... --eth 5 --usdc 100000
#   ./script/tenderly/fund-address.sh 0x0b49... --erc20 0x94018130... 250
# ==============================================================================
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" # Base-native USDC

die() { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
ok()  { printf '\033[0;32m✓ %s\033[0m\n' "$1"; }

# ── args ─────────────────────────────────────────────────────────────────────
WALLET="${1:-}"; shift || true
[[ "$WALLET" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "usage: fund-address.sh <wallet> [--eth N] [--usdc N] [--erc20 <token> N] [--rpc-url <url>]"

ETH_AMT=""; RPC="${TENDERLY_VNET_RPC_URL:-}"
declare -a TOKENS=() TOKEN_AMTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --eth)     ETH_AMT="$2"; shift 2 ;;
    --usdc)    TOKENS+=("$USDC"); TOKEN_AMTS+=("$2"); shift 2 ;;
    --erc20)   TOKENS+=("$2");    TOKEN_AMTS+=("$3"); shift 3 ;;
    --rpc-url) RPC="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done
# default when nothing requested: 10 ETH for gas
[ -z "$ETH_AMT" ] && [ "${#TOKENS[@]}" -eq 0 ] && ETH_AMT=10

# ── rpc resolution (never printed in full — the admin URL is write-capable) ──
if [ -z "$RPC" ] && [ -f "$ROOT/.env" ]; then
  RPC="$(grep -E '^TENDERLY_VNET_RPC_URL=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d '"')"
fi
[ -n "$RPC" ] && [ "$RPC" != "..." ] || die "no admin RPC: pass --rpc-url or set TENDERLY_VNET_RPC_URL (in env or .env)"
echo "vnet: ${RPC:0:42}…  chain $(cast chain-id --rpc-url "$RPC" 2>/dev/null || die 'RPC unreachable')"

# ── fund ETH ─────────────────────────────────────────────────────────────────
if [ -n "$ETH_AMT" ]; then
  wei_hex="$(cast to-hex "$(cast to-wei "$ETH_AMT" ether)")"
  cast rpc tenderly_setBalance "[\"$WALLET\"]" "$wei_hex" --rpc-url "$RPC" >/dev/null \
    || die "tenderly_setBalance failed — is this the ADMIN RPC (not the public one)?"
  ok "ETH balance set to $(cast from-wei "$(cast balance "$WALLET" --rpc-url "$RPC")") ETH"
fi

# ── fund ERC20s ──────────────────────────────────────────────────────────────
for i in "${!TOKENS[@]}"; do
  token="${TOKENS[$i]}"; amt="${TOKEN_AMTS[$i]}"
  dec="$(cast call "$token" 'decimals()(uint8)' --rpc-url "$RPC")"
  sym="$(cast call "$token" 'symbol()(string)' --rpc-url "$RPC" | tr -d '"')"
  raw_hex="$(cast to-hex "$(cast from-fixed-point "$dec" "$amt")")"
  cast rpc tenderly_setErc20Balance "$token" "$WALLET" "$raw_hex" --rpc-url "$RPC" >/dev/null \
    || die "tenderly_setErc20Balance failed for $sym ($token)"
  bal="$(cast call "$token" 'balanceOf(address)(uint256)' "$WALLET" --rpc-url "$RPC" | awk '{print $1}')"
  ok "$sym balance set to $(cast to-fixed-point "$dec" "$bal") $sym"
done
