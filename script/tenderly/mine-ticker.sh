#!/usr/bin/env bash
# ==============================================================================
# mine-ticker.sh — give a Tenderly Virtual TestNet a heartbeat (MOO-768)
# ==============================================================================
# A Tenderly vnet mines a block ONLY when a transaction arrives; an idle chain
# mints nothing. Real Base mints one every ~2s. Wallets assume the latter, which
# is where the two QA artifacts on MOO-768 come from:
#
#   1. any waitForTransactionReceipt with confirmations > 1 between interactive
#      legs never resolves — the first leg mines its own block and no more come;
#   2. MetaMask's activity tracker needs block progression to mark a tx
#      confirmed, so mined txs linger as "submitted/pending" locally and the
#      next signature request shows the stale-queue warning banner.
#
# This script closes that gap from the outside: it calls evm_mine on a fixed
# interval so the chain keeps ticking while nobody is transacting. Run it
# alongside a manual QA session; stop it with Ctrl-C when you are done. It holds
# no state — starting and stopping it is always safe.
#
# It does NOT fast-forward the chain. Tenderly stamps each mined block with the
# real time elapsed since the previous one, so the cadence sets the block rate but
# not the rate of chain time. What it does fix is drift: an idle vnet falls behind
# by exactly as long as it sat idle (measured 2026-08-19: ~2h of lag after an
# idle weekend), and the first transaction after that idles jumps the timestamp
# by the whole gap in one block. A running ticker keeps the offset flat.
#
# Usage:
#   ./script/tenderly/mine-ticker.sh [--interval <seconds>] [--rpc-url <url>]
#                                    [--once | --daemon | --stop | --status] [--quiet]
#
#   --interval N   seconds between blocks (default 15). Base is 2s, but the heartbeat
#                  only has to cover the IDLE gaps: a tester's own transaction still
#                  mines its own block instantly. 15s keeps the wallet tracker moving
#                  at ~1/7th the RPC traffic. Drop to 2 to mirror Base exactly; raise
#                  to 30 if the vnet is rate-limiting.
#   --rpc-url URL  admin (write-capable) RPC; else $TENDERLY_VNET_RPC_URL, else .env
#   --once         mine a single block and exit — use to catch a vnet up before a run
#   --daemon       detach and keep mining across terminals; logs to mine-ticker.log
#   --stop         stop the detached ticker
#   --status       is it running, and how far behind wall clock is the chain
#   --quiet        suppress the periodic status line (errors still print)
#
# Examples:
#   ./script/tenderly/mine-ticker.sh                     # 15s heartbeat, Ctrl-C to stop
#   ./script/tenderly/mine-ticker.sh --interval 2        # exactly Base's cadence
#   ./script/tenderly/mine-ticker.sh --once
#   make tenderly-mine / tenderly-mine-start / tenderly-mine-stop / tenderly-mine-status
#
# For an all-day heartbeat the team can rely on, run the daemon on an always-on box
# (see "Vnet heartbeat" in script/tenderly/README.md for the launchd recipe). A laptop
# that sleeps stops the chain; that is the same failure the ticker exists to prevent.
# ==============================================================================
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATUS_EVERY=${STATUS_EVERY:-30} # seconds between status lines

die()  { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
ok()   { printf '\033[0;32m✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[0;33m! %s\033[0m\n' "$1" >&2; }

# ── args ─────────────────────────────────────────────────────────────────────
INTERVAL=15; ONCE=0; QUIET=0; MODE=run; RPC="${TENDERLY_VNET_RPC_URL:-}"
PIDFILE="$ROOT/script/tenderly/.mine-ticker.pid"
LOGFILE="$ROOT/script/tenderly/mine-ticker.log"
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --rpc-url)  RPC="$2";      shift 2 ;;
    --once)     ONCE=1;        shift ;;
    --daemon)   MODE=daemon;   shift ;;
    --stop)     MODE=stop;     shift ;;
    --status)   MODE=status;   shift ;;
    --quiet)    QUIET=1;       shift ;;
    # the header block IS the help text; stop at its closing banner rather than a
    # hardcoded line number, which drifts every time the header is edited
    -h|--help)  awk 'NR>=2{print; if (/^# ={20,}$/ && ++c==3) exit}' "$0"; exit 0 ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
done
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -ge 1 ] || die "--interval must be a whole number of seconds >= 1"

# ── rpc resolution (never printed in full — the admin URL is write-capable) ──
if [ -z "$RPC" ] && [ -f "$ROOT/.env" ]; then
  RPC="$(grep -E '^TENDERLY_VNET_RPC_URL=' "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d '"')"
fi
[ -n "$RPC" ] && [ "$RPC" != "..." ] || die "no admin RPC: pass --rpc-url or set TENDERLY_VNET_RPC_URL (in env or .env)"

rpc() { # $1 = method, $2 = params json (default []) — always emits valid JSON
  local out
  out="$(curl -sS --max-time 15 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" \
    "$RPC" 2>/dev/null || true)"
  # A blip can return nothing, or an HTML error page. Normalising to {} here keeps
  # every caller's `jq` from failing the script under `set -e` mid-retry.
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then printf '%s' "$out"; else printf '{}'; fi
}
hex2dec() { [ -n "${1:-}" ] && [ "$1" != "null" ] && printf '%d' "$1" 2>/dev/null || echo ""; }

block_number() { hex2dec "$(rpc eth_blockNumber | jq -r '.result // empty')"; }
block_ts()     { hex2dec "$(rpc eth_getBlockByNumber '["latest",false]' | jq -r '.result.timestamp // empty')"; }
# How far the chain's clock trails real time. Prints "?" rather than doing
# arithmetic on an empty read — Ctrl-C can interrupt the RPC mid-substitution.
lag() { local t; t="$(block_ts)"; [ -n "$t" ] && echo "$(( $(date +%s) - t ))" || echo '?'; }
bn()  { local b; b="$(block_number)"; echo "${b:-?}"; }

# ── detached-mode plumbing ───────────────────────────────────────────────────
# A pidfile can outlive its process (crash, reboot, kill -9), so every read of it
# is confirmed against the process table before it is believed.
running_pid() {
  local pid
  [ -f "$PIDFILE" ] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { rm -f "$PIDFILE"; return 1; }
  echo "$pid"
}

# Refuse a second ticker before the preflight probe mines anything.
if [ "$MODE" = daemon ] && pid="$(running_pid)"; then
  die "ticker already running (pid $pid) — --stop it first"
fi

case "$MODE" in
  stop)
    pid="$(running_pid)" || die "no ticker running (no live pid in ${PIDFILE##*/})"
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && die "pid $pid did not exit — kill -9 $pid"
    rm -f "$PIDFILE"
    ok "stopped ticker (pid $pid); chain now at block $(bn)"
    exit 0 ;;
  status)
    if pid="$(running_pid)"; then
      ok "ticker running (pid $pid) — block $(bn), $(lag)s behind wall clock"
      echo "  log: ${LOGFILE#$ROOT/}"
    else
      warn "no ticker running — block $(bn), $(lag)s behind wall clock"
    fi
    exit 0 ;;
esac

# ── preflight: reachable, write-capable, and report the starting drift ───────
CHAIN="$(hex2dec "$(rpc eth_chainId | jq -r '.result // empty')")"
[ -n "$CHAIN" ] || die "RPC unreachable: ${RPC:0:42}…"
START_BLOCK="$(block_number)"
echo "vnet: ${RPC:0:42}…  chain $CHAIN  block $START_BLOCK  $(lag)s behind wall clock"

MINE_ERR="$(rpc evm_mine | jq -r '.error.message // empty')"
[ -z "$MINE_ERR" ] || die "evm_mine rejected ($MINE_ERR) — is this the ADMIN RPC (not the public one)?"

if [ "$ONCE" -eq 1 ]; then
  ok "mined 1 block → $(bn) ($(lag)s behind wall clock)"
  exit 0
fi

if [ "$MODE" = daemon ]; then
  # Preflight already proved the RPC reachable and write-capable, so a failure to
  # start is visible here rather than buried in the log.
  # via the environment, not argv: `ps` would otherwise publish the admin URL.
  TENDERLY_VNET_RPC_URL="$RPC" nohup "$0" --interval "$INTERVAL" >>"$LOGFILE" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 1
  running_pid >/dev/null || { rm -f "$PIDFILE"; die "daemon exited immediately — see ${LOGFILE#$ROOT/}"; }
  ok "ticker detached (pid $(cat "$PIDFILE"), every ${INTERVAL}s) → ${LOGFILE#$ROOT/}"
  echo "  stop with: ./script/tenderly/mine-ticker.sh --stop"
  exit 0
fi

# ── heartbeat ────────────────────────────────────────────────────────────────
MINED=0; FAILS=0; LAST_STATUS=$(date +%s)
finish() {
  trap - INT TERM # a second Ctrl-C should kill it, not re-enter this
  echo
  ok "stopped after $MINED block(s) at $(bn)"
  exit 0
}
trap finish INT TERM

# Whoever the parent registered under this pidfile is responsible for clearing it,
# however it exits — otherwise --status reports a ghost after a crash.
release_pidfile() { [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$$" ] && rm -f "$PIDFILE"; return 0; }
trap release_pidfile EXIT

ok "mining every ${INTERVAL}s — Ctrl-C to stop"
while :; do
  sleep "$INTERVAL"
  err="$(rpc evm_mine | jq -r '.error.message // empty')"
  if [ -n "$err" ]; then
    FAILS=$((FAILS + 1))
    # A vnet can blip (redeploy, rate limit). Ride out a few, but do not spin
    # silently forever against a vnet that has gone away.
    [ "$FAILS" -ge 10 ] && die "evm_mine failed 10 times in a row — last error: $err"
    warn "evm_mine failed ($err) — retry $FAILS/10"
    continue
  fi
  FAILS=0; MINED=$((MINED + 1))

  now=$(date +%s)
  if [ "$QUIET" -eq 0 ] && [ $((now - LAST_STATUS)) -ge "$STATUS_EVERY" ]; then
    printf '  block %s  ·  %s mined  ·  %ss behind wall clock\n' \
      "$(bn)" "$MINED" "$(lag)"
    LAST_STATUS=$now
  fi
done
