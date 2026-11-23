#!/usr/bin/env python3
"""Pre-listing checks for a stock token on the StockAccountRegistry, ending in the listing calldata.

Read-only. Every guard prints PASS, FAIL, WARN or NOT RUN; a blocking FAIL makes the exit code 1, and the
calldata is printed either way so the verdict and the package never drift apart. Needs `cast` (Foundry) on
the PATH and BASE_RPC_URL in the environment or in ./.env. Stdlib only.

    python3 script/stock-accounts/list-token-check.py <token> [--pool <pool>] [--hours 24] [--out <dir>]
                                                      [--to-block <n>] [--recheck] [--addresses addresses/8453.json]

--recheck runs the pool-health guards on a token that is already listed (skips the listing-only guards).
--to-block pins every read to a past block so a run can be replayed (the ANTc day-one pool is the fixture,
see docs/STOCK_ACCOUNT_LISTING.md).
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request

MIN_TICK, MAX_TICK = -887272, 887272
TOPIC_SWAP = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
TOPIC_MINT = "0x7a53080ba414158be7ec69b987b5fb7d07dee101fe85488f0853ae16239d0bde"
TOPIC_BURN = "0x0c396cd989a39f4459b5fa1aed6a9a8dcdbc45908acfd67e028cd568da98982c"
TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ZERO = "0x0000000000000000000000000000000000000000"
ZERO_WORD = "0x" + "0" * 64
SAFE_TX_BUILDER_VERSION = "1.18.0"
MULTISIG_BOOK_NAME = "MAMO_MULTISIG"


# ----------------------------------------------------------------------------- plumbing
class Rpc:
    def __init__(self, url):
        self.url = url
        self.calls = 0

    def __call__(self, method, params, tries=5):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        last = None
        for attempt in range(tries):
            try:
                req = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=120) as resp:
                    out = json.load(resp)
                self.calls += 1
                if "error" in out:
                    raise RpcError(out["error"])
                return out["result"]
            except RpcError as e:
                # A revert is an answer, not a transport failure: hand it back at once.
                if isinstance(e.args[0], dict) and e.args[0].get("code") == 3:
                    raise
                last = e
            except Exception as e:  # noqa: BLE001 - transport errors are retried, nothing else is swallowed
                last = e
            time.sleep(1.5 * (attempt + 1))
        raise RpcError("rpc %s failed after %d tries: %s" % (method, tries, type(last).__name__))


class RpcError(Exception):
    pass


_sel_cache = {}


def cast(*args):
    env = dict(os.environ, FOUNDRY_DISABLE_NIGHTLY_WARNING="1")
    out = subprocess.run(["cast", *args], capture_output=True, text=True, env=env)
    if out.returncode != 0:
        raise RuntimeError("cast %s failed: %s" % (args[0], out.stderr.strip().splitlines()[-1:]))
    return out.stdout.strip()


def calldata(sig, *args):
    key = (sig, tuple(str(a) for a in args))
    if key not in _sel_cache:
        _sel_cache[key] = cast("calldata", sig, *[str(a) for a in args])
    return _sel_cache[key]


def keccak(hexdata):
    return cast("keccak", hexdata)


def words(data):
    d = data[2:] if data.startswith("0x") else data
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def signed(x):
    return x - (1 << 256) if x >= (1 << 255) else x


def addr_word(w):
    return "0x" + ("%064x" % w)[24:]


def topic_addr(t):
    return "0x" + t[26:]


def topic_int(t):
    return signed(int(t, 16))


def tick_price(tick, token_is_0, token_dec, quote_dec):
    """Quote-asset units per whole token at `tick` (raw price = token1/token0 in raw units)."""
    raw = 1.0001 ** tick
    if token_is_0:
        return raw * 10 ** token_dec / 10 ** quote_dec
    return (1 / raw) * 10 ** token_dec / 10 ** quote_dec


class Chain:
    def __init__(self, rpc, block_tag):
        self.rpc = rpc
        self.tag = block_tag

    def call(self, to, sig, *args, frm=None, block=None):
        tx = {"to": to, "data": calldata(sig, *args)}
        if frm:
            tx["from"] = frm
        return self.rpc("eth_call", [tx, block or self.tag])

    def u(self, to, sig, *args, block=None):
        return words(self.call(to, sig, *args, block=block))[0]

    def addr(self, to, sig, *args):
        return addr_word(self.u(to, sig, *args))

    def string(self, to, sig):
        d = self.call(to, sig)
        w = words(d)
        length = w[1]
        return bytes.fromhex(d[2 + 128:2 + 128 + length * 2]).decode(errors="replace")

    def code(self, a, block=None):
        return self.rpc("eth_getCode", [a, block or self.tag])

    def block(self, n_or_tag):
        return self.rpc("eth_getBlockByNumber", [n_or_tag if isinstance(n_or_tag, str) else hex(n_or_tag), False])

    def ts(self, n):
        return int(self.block(n)["timestamp"], 16)

    def logs(self, address, frm, to, topics=None, chunk=50000):
        """Chunked eth_getLogs with a shrinking chunk on failure. Never silently drops a range."""
        out = []
        b = frm
        while b <= to:
            e = min(to, b + chunk - 1)
            f = {"address": address, "fromBlock": hex(b), "toBlock": hex(e)}
            if topics:
                f["topics"] = topics
            try:
                out += self.rpc("eth_getLogs", [f], tries=2)
                b = e + 1
                chunk = min(50000, chunk * 2)
            except RpcError:
                if chunk <= 500:
                    raise
                chunk //= 4
        out.sort(key=lambda l: (int(l["blockNumber"], 16), int(l["logIndex"], 16)))
        return out

    def block_at_or_after(self, target_ts, lo, hi):
        """First block whose timestamp >= target_ts, by bisection on block timestamps (no block-time guess)."""
        while lo < hi:
            mid = (lo + hi) // 2
            if self.ts(mid) < target_ts:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def creation_block(self, a, hi):
        lo = 0
        while lo < hi:
            mid = (lo + hi) // 2
            if len(self.code(a, hex(mid))) > 2:
                hi = mid
            else:
                lo = mid + 1
        return lo


# ----------------------------------------------------------------------------- report
class Report:
    BLOCKING = "blocking"
    INFO = "info"

    def __init__(self):
        self.rows = []

    def add(self, status, kind, name, detail=""):
        self.rows.append((status, kind, name, detail))
        print("  [%-7s] %-44s %s" % (status, name, detail))

    def ok(self, name, detail="", kind=BLOCKING):
        self.add("PASS", kind, name, detail)

    def fail(self, name, detail="", kind=BLOCKING):
        self.add("FAIL", kind, name, detail)

    def warn(self, name, detail=""):
        self.add("WARN", self.INFO, name, detail)

    def info(self, name, detail=""):
        self.add("INFO", self.INFO, name, detail)

    def skip(self, name, detail=""):
        self.add("NOT RUN", self.BLOCKING, name, detail)

    def check(self, cond, name, detail="", kind=BLOCKING):
        (self.ok if cond else self.fail)(name, detail, kind)
        return cond

    @property
    def blocked(self):
        return any(s in ("FAIL", "NOT RUN") and k == self.BLOCKING for s, k, _, _ in self.rows)


def section(title):
    print("\n== %s" % title)


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("token")
    ap.add_argument("--pool", help="pool to use; default: the token/asset pool on the router's factory")
    ap.add_argument("--hours", type=float, default=24, help="history window for the pool guards (default 24)")
    ap.add_argument("--to-block", type=int, help="pin every read to this block (replay)")
    ap.add_argument("--out", help="directory for safe-tx-builder.json (default ./stock-listing-<SYMBOL>)")
    ap.add_argument("--recheck", action="store_true", help="token is already listed: pool-health guards only")
    ap.add_argument("--addresses", default="addresses/8453.json")
    ap.add_argument("--clips", default="1000,10000,25000,50000,100000", help="USDC clip sizes for the impact table")
    args = ap.parse_args()

    url = os.environ.get("BASE_RPC_URL")
    if not url and os.path.exists(".env"):
        for line in open(".env"):
            if line.startswith("BASE_RPC_URL="):
                url = line.split("=", 1)[1].strip().strip('"').strip("'")
    if not url:
        sys.exit("BASE_RPC_URL is not set (environment or ./.env)")
    rpc = Rpc(url)

    head = args.to_block or int(rpc("eth_blockNumber", []), 16)
    ch = Chain(rpc, hex(head))
    rep = Report()
    book = {e["name"]: e["addr"] for e in json.load(open(args.addresses))}
    for name in ("STOCK_ACCOUNT_REGISTRY", MULTISIG_BOOK_NAME, "AERODROME_SLIPSTREAM_V3_METAQUOTER"):
        if name not in book:
            sys.exit("%s missing from %s" % (name, args.addresses))
    registry = book["STOCK_ACCOUNT_REGISTRY"]
    safe = book[MULTISIG_BOOK_NAME]
    quoter = book["AERODROME_SLIPSTREAM_V3_METAQUOTER"]
    token = cast("to-check-sum-address", args.token)

    head_ts = ch.ts(head)
    print("list-token-check  token %s  block %d (%s UTC)%s" % (
        token, head, time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(head_ts)), "  [replay]" if args.to_block else ""))

    # ---------------------------------------------------------------- registry
    section("Registry")
    asset = ch.addr(registry, "asset()")
    checker = ch.addr(registry, "priceChecker()")
    router = ch.addr(registry, "aerodromeRouter()")
    factory = ch.addr(router, "factory()")
    twap_window = ch.u(registry, "twapWindow()")
    slip_bps = ch.u(registry, "maxBackendSlippageBps()")
    max_order = ch.u(registry, "maxOrderValue()")
    cap = ch.u(registry, "MAX_LISTED_TOKENS()")
    raw = ch.call(registry, "allTokens()")
    listed = [addr_word(w) for w in words(raw)[2:]]
    cfg = words(ch.call(registry, "tokenConfig(address)", token))
    status_now = cfg[0]
    paused = ch.u(registry, "paused()") == 1
    rep.check(not paused, "registry not paused")
    rep.info("registry", "%s  checker %s  router %s  factory %s" % (registry, checker, router, factory))
    rep.info("params", "twapWindow %ds  maxBackendSlippage %d bps  maxOrderValue %s USDC  listed %d/%d" % (
        twap_window, slip_bps, f"{max_order / 1e6:,.0f}", len(listed), cap))
    rep.check(token.lower() != asset.lower(), "token is not the asset")
    if args.recheck:
        rep.check(status_now != 0, "token is listed (recheck mode)", "status %d" % status_now)
    else:
        rep.check(status_now == 0, "token not listed yet", "tokenConfig.status = %d" % status_now)
        rep.check(len(listed) < cap, "listing cap", "%d of %d" % (len(listed), cap))

    # ---------------------------------------------------------------- token
    section("Token")
    token_code = ch.code(token)
    if not rep.check(len(token_code) > 2, "token has code"):
        print_calldata_and_exit(rep, None, None, None, None, args, head)
    sym = ch.string(token, "symbol()")
    name = ch.string(token, "name()")
    dec = ch.u(token, "decimals()")
    quote_dec = ch.u(asset, "decimals()")
    supply = ch.u(token, "totalSupply()")
    rep.info("token", '%s "%s"  %d decimals  supply %s' % (sym, name, dec, f"{supply / 10 ** dec:,.2f}"))
    ref = None
    refs = [t for t in listed if t.lower() != token.lower()]
    code_hash = keccak(token_code)
    same_code = [t for t in refs if keccak(ch.code(t)) == code_hash]
    if refs:
        rep.check(bool(same_code), "runtime bytecode matches a listed token",
                  "%d of %d listed tokens share it" % (len(same_code), len(refs)) if same_code else "no listed token has this code")
        ref = same_code[0] if same_code else refs[0]
    else:
        rep.warn("runtime bytecode", "nothing listed yet to compare with")
    # Who mints it: the issuer's minter key and mint contract must be the ones that mint the listed tokens.
    if ref:
        try:
            mints = ch.logs(token, ch.creation_block(token, head), head, [TOPIC_TRANSFER, ZERO_WORD])
            ref_mints = ch.logs(ref, max(0, head - 2_000_000), head, [TOPIC_TRANSFER, ZERO_WORD])
            if not ref_mints:
                ref_mints = ch.logs(ref, 0, head, [TOPIC_TRANSFER, ZERO_WORD])
            senders = set()
            targets = set()
            for lg in mints[-25:]:
                tx = rpc("eth_getTransactionByHash", [lg["transactionHash"]])
                senders.add(tx["from"].lower())
                targets.add((tx["to"] or "").lower())
            ref_senders = set()
            ref_targets = set()
            for lg in ref_mints[-10:]:
                tx = rpc("eth_getTransactionByHash", [lg["transactionHash"]])
                ref_senders.add(tx["from"].lower())
                ref_targets.add((tx["to"] or "").lower())
            same = bool(mints) and senders <= ref_senders and targets <= ref_targets
            rep.check(same, "mints come from the listed tokens' minter",
                      "%d mints (last %d checked), sender(s) %s via %s%s" % (
                          len(mints), min(25, len(mints)), ", ".join(s[:10] for s in senders) or "-", ", ".join(t[:10] for t in targets) or "-",
                          "" if same else "; reference %s uses %s via %s" % (
                              ref[:10], ", ".join(s[:10] for s in ref_senders), ", ".join(t[:10] for t in ref_targets))))
        except RpcError as e:
            rep.fail("mints come from the listed tokens' minter", "log scan failed: %s" % e)

    # ---------------------------------------------------------------- pool
    section("Pool")
    pool = args.pool
    found = []
    cfg_pool = addr_word(cfg[2]) if status_now != 0 else None
    if args.recheck and cfg_pool and cfg_pool != ZERO:
        # The checker prices from tokenConfig.pool; a recheck has to look at that pool, not the factory's first.
        if pool and pool.lower() != cfg_pool.lower():
            rep.warn("--pool differs from the registry's pool", "%s configured, checking %s as asked" % (cfg_pool, pool))
        else:
            pool = cfg_pool
            rep.info("pool from registry", pool)
    if not pool:
        for ts_ in (1, 10, 50, 100, 200, 2000):
            p = ch.addr(factory, "getPool(address,address,int24)", token, asset, ts_)
            if p != ZERO:
                found.append((ts_, p))
        if not found:
            rep.fail("pool on the router's factory", "no %s/asset pool for any tick spacing" % sym)
            print_calldata_and_exit(rep, token, None, sym, None, args, head)
        if len(found) > 1:
            rep.warn("several pools on the factory", ", ".join("ts %d %s" % f for f in found) + "; using the first, pass --pool to choose")
        pool = found[0][1]
    pool = cast("to-check-sum-address", pool)
    pool_factory = ch.addr(pool, "factory()")
    rep.check(pool_factory.lower() == factory.lower(), "pool is on the router's factory", "%s factory %s" % (pool, pool_factory))
    t0 = ch.addr(pool, "token0()")
    t1 = ch.addr(pool, "token1()")
    token_is_0 = t0.lower() == token.lower()
    rep.check({t0.lower(), t1.lower()} == {token.lower(), asset.lower()}, "pool pairs the token with the asset",
              "token0 %s token1 %s" % (t0, t1))
    tick_spacing = signed(ch.u(pool, "tickSpacing()"))
    fee = ch.u(pool, "fee()")
    gauge = ch.addr(pool, "gauge()")
    rep.info("pool", "tick spacing %d  fee %d  gauge %s" % (tick_spacing, fee, gauge if gauge != ZERO else "none"))
    s0 = words(ch.call(pool, "slot0()"))
    sqrt_p, tick_now, obs_idx, card, card_next = s0[0], signed(s0[1]), s0[2], s0[3], s0[4]
    liq_now = ch.u(pool, "liquidity()")
    spot = tick_price(tick_now, token_is_0, dec, quote_dec)
    rep.info("spot", "tick %d  %s %s per %s  in-range liquidity %d  observations %d (next %d)" % (
        tick_now, f"{spot:,.4f}", "USDC", sym, liq_now, card, card_next))
    bal_tok = ch.u(token, "balanceOf(address)", pool) / 10 ** dec
    bal_usd = ch.u(asset, "balanceOf(address)", pool) / 10 ** quote_dec
    rep.info("pool balances", "%s %s + %s USDC  (TVL ~%s USDC at spot)" % (
        f"{bal_tok:,.2f}", sym, f"{bal_usd:,.0f}", f"{bal_tok * spot + bal_usd:,.0f}"))

    # ---------------------------------------------------------------- TWAP
    section("TWAP")

    def twap_tick(window, block=None):
        d = ch.call(pool, "observe(uint32[])", "[%d,0]" % window, block=block)
        w = words(d)
        c0, c1 = signed(w[3]), signed(w[4])
        delta = c1 - c0
        t = delta // window if delta >= 0 else -((-delta) // window) - (1 if (-delta) % window else 0)
        return t  # floored like the checker's _twapTick

    try:
        tw = twap_tick(twap_window)
        twap_px = tick_price(tw, token_is_0, dec, quote_dec)
        dev = (twap_px / spot - 1) * 1e4
        rep.ok("observe(twapWindow) answers", "tick %d  %s USDC  %+.0f bps vs spot" % (tw, f"{twap_px:,.4f}", dev))
        rep.check(abs(dev) <= slip_bps, "TWAP within the slippage cap of spot", "%+.0f bps, cap %d" % (dev, slip_bps))
        for wnd in (1800, 3600):
            try:
                t_ = twap_tick(wnd)
                px = tick_price(t_, token_is_0, dec, quote_dec)
                d_ = (px / spot - 1) * 1e4
                (rep.warn if abs(d_) > 200 else rep.info)("%d s TWAP" % wnd, "%s USDC  %+.0f bps vs spot" % (f"{px:,.4f}", d_))
            except RpcError:
                rep.warn("%d s TWAP" % wnd, "observe reverts: the ring does not reach back that far yet")
    except RpcError as e:
        rep.fail("observe(twapWindow) answers", "reverts (%s): ring too short for %d s" % (short_err(e), twap_window))

    # ---------------------------------------------------------------- history
    section("History (%.0f h)" % args.hours)
    created = ch.creation_block(pool, head)
    created_ts = ch.ts(created)
    age_h = (head_ts - created_ts) / 3600
    rep.check(age_h >= args.hours, "pool age covers the window", "created block %d (%s UTC), %.1f h old" % (
        created, time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(created_ts)), age_h))
    start = ch.block_at_or_after(head_ts - int(args.hours * 3600), max(created, 0), head)
    start = max(start, created)
    try:
        logs = ch.logs(pool, start, head)
    except RpcError as e:
        rep.fail("pool log scan", "failed: %s" % e)
        logs = None
    if logs is not None:
        # Seed the in-range liquidity from the state BEFORE block start (the log replay from start is inclusive,
        # so seeding at start would count that block's Mint/Burn twice). A pool created in block start had none.
        if start > created:
            seed = words(ch.call(pool, "slot0()", block=hex(start - 1)))
            tick = signed(seed[1])
            liq = ch.u(pool, "liquidity()", block=hex(start - 1))
        else:
            tick = signed(words(ch.call(pool, "slot0()", block=hex(start)))[1])
            liq = 0
        seed_liq = liq
        swaps = 0
        first_swap = None
        vol = 0.0
        zero_after = 0
        sweeps = []
        gaps = []
        gap_open = None
        owners = {}
        for lg in logs:
            t = lg["topics"][0]
            bn = int(lg["blockNumber"], 16)
            if t == TOPIC_SWAP:
                d = [signed(x) for x in words(lg["data"])]
                a0, a1, _, liq, tick = d[0], d[1], d[2], d[3], d[4]
                swaps += 1
                first_swap = first_swap or bn
                vol += abs(a0 if not token_is_0 else a1) / 10 ** quote_dec
                if liq == 0:
                    zero_after += 1
                # A downward sweep ends at MIN_TICK; an upward one at MAX_TICK - 1 (the router's limit is MAX_SQRT_RATIO - 1).
                if tick <= MIN_TICK or tick >= MAX_TICK - 1:
                    sweeps.append((bn, tick, lg["transactionHash"]))
                if gap_open is not None:
                    gaps.append((gap_open, bn - gap_open))
                    gap_open = None
            elif t in (TOPIC_MINT, TOPIC_BURN):
                lo, hi = topic_int(lg["topics"][2]), topic_int(lg["topics"][3])
                d = words(lg["data"])
                amt = d[-3] if t == TOPIC_MINT else d[0]
                if t == TOPIC_MINT:
                    owners[topic_addr(lg["topics"][1])] = owners.get(topic_addr(lg["topics"][1]), 0) + 1
                if lo <= tick < hi:
                    liq += amt if t == TOPIC_MINT else -amt
                    if liq <= 0 and gap_open is None:
                        gap_open = bn
                    if liq > 0 and gap_open is not None:
                        if bn > gap_open:
                            gaps.append((gap_open, bn - gap_open))
                        gap_open = None
        if gap_open is not None:
            gaps.append((gap_open, head - gap_open))
        start_ts = ch.ts(start)
        secs = max(1, head_ts - start_ts)
        # A pool that existed but did not trade for the whole window has no history to judge; the liquidity
        # at the start block and a swap within the first hour prove the window is real trading, not an empty pool.
        first_swap_lag = (ch.ts(first_swap) - start_ts) if first_swap else None
        rep.check(seed_liq > 0 and first_swap_lag is not None and first_swap_lag <= 3600, "trading history covers the window",
                  "liquidity at start %d, first swap %s after the window start" % (
                      seed_liq, ("%.0f min" % (first_swap_lag / 60)) if first_swap_lag is not None else "never"))
        rep.info("activity", "%d swaps, %s USDC volume in %.1f h (%s USDC/day pace), %d mint events by %d owner(s): %s" % (
            swaps, f"{vol:,.0f}", secs / 3600, f"{vol * 86400 / secs:,.0f}", sum(owners.values()), len(owners),
            ", ".join("%s x%d" % (o[:10], n) for o, n in sorted(owners.items(), key=lambda x: -x[1])[:3]) or "-"))
        rep.check(not gaps, "in-range liquidity never reached zero",
                  "%d window(s), longest %d blocks" % (len(gaps), max(g[1] for g in gaps)) if gaps else "seeded at block %d" % start)
        rep.check(zero_after == 0, "no swap ended with zero liquidity", "%d swap(s)" % zero_after)
        rep.check(not sweeps, "no sweep to MIN_TICK or MAX_TICK",
                  "; ".join("block %d tick %d tx %s" % (b, t_, h[:12]) for b, t_, h in sweeps[:4]) if sweeps else "")
        # What the checker would have read through any sweep: the worst twapWindow sample after each one.
        if sweeps:
            worst = 0.0
            for b, _, _ in sweeps:
                for off in (0, 300, 600, 900):
                    try:
                        t_ = twap_tick(twap_window, block=hex(min(head, b + off)))
                        px = tick_price(t_, token_is_0, dec, quote_dec)
                        worst = max(worst, abs(px / spot - 1))
                    except RpcError:
                        pass
            rep.info("worst twapWindow read after a sweep", "%s times spot" % (f"{worst + 1:,.1f}" if worst < 1e4 else "%.1e" % (worst + 1)))

    # ---------------------------------------------------------------- depth (report only)
    section("Depth (report only)")
    clips = [int(c) for c in args.clips.split(",") if c]

    def quote(token_in, amount_in):
        d = ch.call(quoter, "quoteExactInputSingleV3(address,address,uint256,uint160)", pool, token_in, amount_in, 0)
        return words(d)[0]

    def impact(usd, buy):
        if buy:
            out = quote(asset, int(usd * 10 ** quote_dec))
            px = usd / (out / 10 ** dec) if out else float("inf")
        else:
            amt = int(usd / spot * 10 ** dec)
            out = quote(token, amt)
            px = (out / 10 ** quote_dec) / (amt / 10 ** dec) if amt else 0
        return (px / spot - 1) * 1e4

    try:
        rows = []
        for usd in clips:
            rows.append("$%s %+.0f/%+.0f" % (f"{usd:,}", impact(usd, True), impact(usd, False)))
        rep.info("impact vs spot (buy/sell bps)", "  ".join(rows))

        def max_clip(buy):
            lo, hi = 0, max(clips)
            for _ in range(20):
                mid = (lo + hi) / 2
                if abs(impact(mid, buy)) <= slip_bps:
                    lo = mid
                else:
                    hi = mid
            return lo

        mb, ms = max_clip(True), max_clip(False)
        rep.info("largest clip inside %d bps" % slip_bps, "buy ~$%s  sell ~$%s  (maxOrderValue %s)" % (
            f"{mb:,.0f}", f"{ms:,.0f}", f"{max_order / 1e6:,.0f}"))
        if min(mb, ms) < 10_000:
            rep.warn("thin pool", "the backend must size %s clips under ~$%s" % (sym, f"{min(mb, ms):,.0f}"))
    except (RpcError, RuntimeError) as e:
        rep.warn("depth", "quoter failed: %s" % short_err(e))

    # ---------------------------------------------------------------- listing simulation
    section("Listing simulation from the Safe")
    data = calldata("listToken(address,(uint8,uint8,address,address))", token, "(1,0,%s,%s)" % (pool, ZERO))
    if args.recheck:
        rep.info("skipped", "recheck mode: the token is already listed")
    else:
        try:
            calls = [
                {"from": safe, "to": registry, "data": data},
                {"to": registry, "data": calldata("tokenConfig(address)", token)},
                {"to": checker, "data": calldata("getExpectedOut(uint256,address,address)", 10 ** dec, token, asset)},
                {"to": checker, "data": calldata("getExpectedOut(uint256,address,address)", 10 ** quote_dec, asset, token)},
                {"from": "0x0000000000000000000000000000000000000001", "to": registry, "data": data},
                {"to": registry, "data": calldata("allTokens()")},
            ]
            res = rpc("eth_simulateV1", [{"blockStateCalls": [{"calls": calls}], "validation": False}, hex(head)])
            c = res[0]["calls"]
            ok = c[0]["status"] == "0x1"
            rep.check(ok, "listToken succeeds from the Safe",
                      "%s gas, %d event(s)" % (f"{int(c[0]['gasUsed'], 16):,}", len(c[0].get("logs", []))) if ok
                      else "revert %s" % short_err(c[0].get("error")))
            if ok:
                after = words(c[1]["returnData"])
                rep.check(after[0] == 1 and after[1] == 0 and addr_word(after[2]).lower() == pool.lower() and after[3] == 0,
                          "tokenConfig reads back", "(Active, PoolTwap, %s, no feed)" % pool)
                q1 = words(c[2]["returnData"])[0] / 10 ** quote_dec if c[2]["status"] == "0x1" else None
                q2 = words(c[3]["returnData"])[0] / 10 ** dec if c[3]["status"] == "0x1" else None
                rep.check(q1 is not None and q2 is not None and q1 > 0 and q2 > 0, "checker quotes both ways",
                          "1 %s -> %s USDC, 1 USDC -> %s %s" % (sym, f"{q1:,.4f}" if q1 else "revert", f"{q2:,.6f}" if q2 else "revert", sym))
                rep.check(c[4]["status"] != "0x1", "non-admin caller is refused")
                rep.check((len(c[5]["returnData"]) - 2 - 128) // 64 == len(listed) + 1, "token count after", "%d" % (len(listed) + 1))
        except RpcError as e:
            rep.fail("listToken succeeds from the Safe", "eth_simulateV1 unavailable or failed: %s" % short_err(e))

    print_calldata_and_exit(rep, token, pool, sym, data, args, head, rpc=rpc, safe=safe, registry=registry, checker=checker, asset=asset)


def short_err(e):
    s = str(e.args[0] if isinstance(e, Exception) and e.args else e)
    return s[:120]


def print_calldata_and_exit(rep, token, pool, sym, data, args, head, rpc=None, safe=None, registry=None, checker=None, asset=None):
    section("Verdict")
    blocking = [r for r in rep.rows if r[1] == Report.BLOCKING and r[0] in ("FAIL", "NOT RUN")]
    if blocking:
        print("  BLOCKED by %d guard(s): %s" % (len(blocking), "; ".join(r[2] for r in blocking)))
    else:
        print("  all blocking guards pass" + ("; see WARN lines" if any(r[0] == "WARN" for r in rep.rows) else ""))
    if data and not args.recheck:
        section("Listing calldata (printed whatever the verdict)")
        print("  to:    %s  (StockAccountRegistry)" % registry)
        print("  value: 0   operation: CALL")
        print("  listToken(%s, (1 Active, 0 PoolTwap, %s, %s))" % (token, pool, ZERO))
        print("  data:  %s" % data)
        try:
            live = Chain(rpc, "latest")
            nonce = live.u(safe, "nonce()")
            h = live.call(safe, "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)",
                          registry, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce)
            print("  safeTxHash at nonce %d (gas fields 0): %s" % (nonce, h))
        except Exception as e:  # noqa: BLE001 - the hash is a convenience, the calldata above is the deliverable
            print("  safeTxHash: not computed (%s)" % short_err(e))
        out_dir = args.out or ("stock-listing-%s" % sym)
        os.makedirs(out_dir, exist_ok=True)
        doc = {
            "version": "1.0", "chainId": "8453", "createdAt": int(time.time() * 1000),
            "meta": {"name": "Stock accounts: list %s" % sym,
                     "description": "StockAccountRegistry listToken(%s, {Active, PoolTwap, pool %s, no Chainlink feed})." % (sym, pool),
                     "txBuilderVersion": SAFE_TX_BUILDER_VERSION, "createdFromSafeAddress": safe, "createdFromOwnerAddress": ""},
            "transactions": [{
                "to": registry, "value": "0", "data": data,
                "contractMethod": {"inputs": [
                    {"internalType": "address", "name": "token", "type": "address"},
                    {"components": [
                        {"internalType": "uint8", "name": "status", "type": "uint8"},
                        {"internalType": "uint8", "name": "source", "type": "uint8"},
                        {"internalType": "address", "name": "pool", "type": "address"},
                        {"internalType": "address", "name": "chainlinkFeed", "type": "address"}],
                     "internalType": "struct IStockAccountRegistry.TokenConfig", "name": "cfg", "type": "tuple"}],
                    "name": "listToken", "payable": False},
                "contractInputsValues": {"token": token, "cfg": '[1,0,"%s","%s"]' % (pool, ZERO)}}]}
        path = os.path.join(out_dir, "safe-tx-builder.json")
        json.dump(doc, open(path, "w"), indent=2)
        print("  Safe Transaction Builder file: %s" % path)
        print("  after execution:")
        print("    cast call %s \"tokenConfig(address)((uint8,uint8,address,address))\" %s --rpc-url base" % (registry, token))
        print("    cast call %s \"getExpectedOut(uint256,address,address)(uint256)\" %d %s %s --rpc-url base" % (
            checker, 10 ** 8, token, asset))
    sys.exit(1 if blocking else 0)


if __name__ == "__main__":
    main()
