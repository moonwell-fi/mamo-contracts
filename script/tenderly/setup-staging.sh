#!/usr/bin/env bash
# ==============================================================================
# setup-staging.sh — stand up a PERSISTENT Mamo frontend staging vnet
# ==============================================================================
# Creates a long-lived Tenderly Virtual TestNet (a Base fork) for the frontend team to
# integrate against, and hands them a *Public* RPC + block-explorer URL. Unlike the
# harness runners this vnet is NOT torn down — it persists until explicitly deleted.
#
# Config (the decided Phase 6 shape):
#   • custom chain id (default 82023 = 73570 + 8453, the moonwell-tenderly convention) so it
#     never collides with real Base 8453 — wallets/indexers treat it as its own network, and
#     MetaMask can add it (it refuses a second network on an existing chain id).
#   • state sync ON — mirrors live Base so prices/liquidity stay fresh over the vnet's life.
#   • public explorer ON + source verification — the frontend gets decoded traces + a debugger.
#   • fork-native — the full Mamo system is already deployed on the Base fork at its real
#     addresses (addresses/8453.json), so the frontend integrates against the current contracts;
#     we just seed demo balances. (Pass --fresh-core later to deploy unreleased versions.)
#
# Hand the frontend the PUBLIC RPC only. The Admin RPC (cheatcodes) stays in ops.
#
# Usage:
#   ./script/tenderly/setup-staging.sh            # create + seed + write docs/tenderly-staging.md
#   STAGING_CHAIN_ID=8453888 ./script/tenderly/setup-staging.sh
#
# Requires: cast, jq, curl, and TENDERLY_ACCESS_KEY in .env (account/project slugs are derived
# from TENDERLY_VNET_RPC_URL). Prints the delete command at the end.
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
RESULTS="${HARNESS_RESULTS:-$SCRIPT_DIR/staging-setup.log}"
: > "$RESULTS"

STAGING_CHAIN_ID="${STAGING_CHAIN_ID:-82023}"   # != 8453 by design
KEEP_VNET=1                                       # persistent — never auto-deleted (even on die())
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[ -f .env ] && { set -a; . ./.env; set +a; }
_derive_tenderly_slugs
{ [ -n "${TENDERLY_ACCESS_KEY:-}" ] && [ -n "${TENDERLY_ACCOUNT_SLUG:-}" ] && [ -n "${TENDERLY_PROJECT_SLUG:-}" ]; } \
  || die "need TENDERLY_ACCESS_KEY in .env (+ derivable account/project slugs from TENDERLY_VNET_RPC_URL)"

# ── 1. create the persistent vnet ───────────────────────────────────────────
section "1. Create persistent Mamo staging vnet (chainId $STAGING_CHAIN_ID, state-sync on)"
resp="$(curl -s -X POST "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets" \
  -H "X-Access-Key: $TENDERLY_ACCESS_KEY" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d "{\"slug\":\"mamo-staging\",\"display_name\":\"Mamo staging (frontend)\",\"fork_config\":{\"network_id\":8453},\"virtual_network_config\":{\"chain_config\":{\"chain_id\":$STAGING_CHAIN_ID}},\"sync_state_config\":{\"enabled\":true},\"explorer_page_config\":{\"enabled\":true,\"verification_visibility\":\"src\"}}")"
VNET_ID="$(echo "$resp" | jq -r '.id // empty')"
ADMIN_RPC="$(echo "$resp" | jq -r '.rpcs[]? | select(.name=="Admin RPC") | .url')"
PUBLIC_RPC="$(echo "$resp" | jq -r '.rpcs[]? | select(.name=="Public RPC") | .url')"
EXPLORER="$(echo "$resp" | jq -r '.explorer_page_url // .explorer_page // empty')"
[ -n "$ADMIN_RPC" ] && [ -n "$VNET_ID" ] || die "vnet create failed: $resp"
CREATED_VNET=1
[ -n "$EXPLORER" ] || EXPLORER="https://dashboard.tenderly.co/$TENDERLY_ACCOUNT_SLUG/$TENDERLY_PROJECT_SLUG/testnet/$VNET_ID"
ok "created vnet $VNET_ID"
RPC="$ADMIN_RPC"   # crpc/ccall/fund_* use the Admin RPC (cheatcodes) for seeding

# ── 2. sanity: right chain + the Mamo system is present on the fork ──────────
section "2. Verify chain + Mamo system present (fork-native)"
CID="$(cast chain-id --rpc-url "$RPC" 2>/dev/null)"
[ "$CID" = "$STAGING_CHAIN_ID" ] || die "expected chainId $STAGING_CHAIN_ID, got '$CID'"
REG="$(addr MAMO_STRATEGY_REGISTRY)"
REG_CODE="$(cast code "$REG" --rpc-url "$RPC" 2>/dev/null)"
[ -n "$REG_CODE" ] && [ "$REG_CODE" != "0x" ] || die "Mamo registry has no code on the fork"
ok "chainId $CID, block $(cast block-number --rpc-url "$RPC" 2>/dev/null); Mamo registry present"

# ── 3. seed demo balances for the well-known Anvil test accounts ─────────────
# These accounts have publicly-known private keys (test-only) so the frontend QA can import
# them straight into MetaMask against the staging RPC.
section "3. Seed demo wallets (Anvil test accounts — public keys, staging-only)"
WALLETS=(
  0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  0x70997970C51812dc3A010C7d01b50e0d17dc79C8
  0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
)
USDC="$(addr USDC)"; CBBTC="$(addr cbBTC)"; WETH="$(addr WETH)"; MAMO="$(addr MAMO)"
ETH_HEX="$(cast to-hex 10000000000000000000)"       # 10 ETH
USDC_HEX="$(cast to-hex 100000000000)"              # 100,000 USDC (6dp)
CBBTC_HEX="$(cast to-hex 500000000)"                # 5 cbBTC (8dp)
WETH_HEX="$(cast to-hex 50000000000000000000)"      # 50 WETH (18dp)
MAMO_HEX="$(cast to-hex 1000000000000000000000000)" # 1,000,000 MAMO (18dp)
for w in "${WALLETS[@]}"; do
  fund_eth   "$w" "$ETH_HEX"
  fund_erc20 "$USDC"  "$w" "$USDC_HEX"
  fund_erc20 "$CBBTC" "$w" "$CBBTC_HEX"
  fund_erc20 "$WETH"  "$w" "$WETH_HEX"
  fund_erc20 "$MAMO"  "$w" "$MAMO_HEX"
  ok "seeded $w (10 ETH / 100k USDC / 5 cbBTC / 50 WETH / 1M MAMO)"
done

# ── 4. write the frontend hand-off doc ───────────────────────────────────────
section "4. Write hand-off doc"
mkdir -p docs
cat > docs/tenderly-staging.md <<DOC
# Mamo staging vnet (frontend integration)

A persistent Tenderly Virtual TestNet forking Base mainnet, for frontend integration testing.
Generated by \`script/tenderly/setup-staging.sh\`.

## Connection (share the PUBLIC RPC only)

| | |
|---|---|
| **Public RPC** | \`$PUBLIC_RPC\` |
| **Explorer** | $EXPLORER |
| **Chain ID** | \`$STAGING_CHAIN_ID\` |
| **Currency** | ETH (18 decimals) |
| **Forked from** | Base mainnet (8453), state-sync ON |

> The **Admin RPC** (cheatcodes: set balances, override storage, advance time) is ops-only —
> never put it in frontend config, docs, or Slack. Only the Public RPC above is safe to share.

## wagmi / viem

\`\`\`ts
import { defineChain } from "viem";
export const mamoStaging = defineChain({
  id: $STAGING_CHAIN_ID,
  name: "Mamo Staging (Tenderly)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["$PUBLIC_RPC"] } },
  blockExplorers: { default: { name: "Tenderly", url: "$EXPLORER" } },
  testnet: true,
});
\`\`\`

MetaMask: **Add network** with the RPC / chain id / explorer above.

## Contract addresses

The full Mamo system is present at its **real Base addresses** (this is a Base fork) — use
\`addresses/8453.json\`. Key ones:

| Name | Address |
|---|---|
| MAMO_STRATEGY_REGISTRY | \`$(addr MAMO_STRATEGY_REGISTRY)\` |
| WETH_STRATEGY_FACTORY | \`$(addr WETH_STRATEGY_FACTORY)\` |
| MAMO_MULTI_REWARDS | \`$(addr MAMO_MULTI_REWARDS)\` |
| CHAINLINK_SWAP_CHECKER_PROXY | \`$(addr CHAINLINK_SWAP_CHECKER_PROXY)\` |
| USDC / cbBTC / WETH / MAMO | \`$USDC\` / \`$CBBTC\` / \`$WETH\` / \`$MAMO\` |

## Pre-funded test wallets (Anvil defaults — public keys, staging-only)

Importable into MetaMask; each holds 10 ETH / 100k USDC / 5 cbBTC / 50 WETH / 1M MAMO:

$(for w in "${WALLETS[@]}"; do echo "- \`$w\`"; done)

Anvil account 0 private key (test-only, do NOT reuse on any real network):
\`0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80\`.

## Ops runbook

- **Reseed balances / add a wallet** (Admin RPC): \`cast rpc tenderly_setErc20Balance <token> <wallet> <hexAmount> --rpc-url <ADMIN_RPC>\`.
- **Recreate** (new URL): re-run \`./script/tenderly/setup-staging.sh\` (it creates a new vnet; update this doc + notify frontend).
- **Delete** this vnet: \`curl -s -X DELETE "$TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets/$VNET_ID" -H "X-Access-Key: \$TENDERLY_ACCESS_KEY"\`
- State-sync keeps mirroring Base; it consumes Tenderly Units continuously — delete when no longer needed.
DOC
ok "wrote docs/tenderly-staging.md"

# ── 5. summary ────────────────────────────────────────────────────────────────
section "Summary — Mamo staging vnet is LIVE (persistent)"
info "Public RPC : $PUBLIC_RPC"
info "Explorer   : $EXPLORER"
info "Chain ID   : $STAGING_CHAIN_ID"
info "Hand-off   : docs/tenderly-staging.md"
info "Delete     : curl -X DELETE $TENDERLY_API/account/$TENDERLY_ACCOUNT_SLUG/project/$TENDERLY_PROJECT_SLUG/vnets/$VNET_ID -H \"X-Access-Key: \$TENDERLY_ACCESS_KEY\""
warn "state-sync consumes Tenderly Units continuously — delete the vnet when the frontend no longer needs it"
echo
