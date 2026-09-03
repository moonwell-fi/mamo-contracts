# Leveraged-Aero vnet runbook — stand up & e2e-verify the full stack

A repeatable procedure for standing up a **fresh Tenderly Base-fork Virtual TestNet** carrying the
complete leveraged-Aerodrome stack and end-to-end verifying it. Run this on staging refreshes and
pre-mainnet rehearsals.

The stack is **two layers, both in this repo**:

| Layer | Contracts | Who drives it |
|---|---|---|
| **Pooled** | `LeveragedAeroVault` (share ERC-20 + lifecycle driver) + one `LeveragedAerodromeCLStrategy` ERC-1167 clone | vault owner = `MAMO_MULTISIG`; position operator = the strategy's `proposer` (`MAMO_REBALANCER`) |
| **Account** | `MamoLeveragedAeroStrategy` (per-user UUPS wrapper) + `MamoLeveragedAeroStrategyFactory` | multisig proposal `012` + `MAMO_BACKEND` |

Audience: Mamo engineers with a checkout of **this repo only**.

> **De-Sherwood delta (PR #66) — if you ran the old version of this runbook, read this.**
> The Sherwood dependency is **gone**. `LeveragedAeroVault` is a minimal in-repo vanilla vault that
> replaces Sherwood's `SyndicateVault`, so:
> - There is **no second repo**. The old Phase B (`../sherwood/contracts`: `deploy-vnet.sh`, fixture
>   WOOD, core factory/governor/registry, PriceRouter, templates, `StrategyFactory`, `createSyndicate`)
>   is **deleted, not moved**.
> - There is **no governance lifecycle**: no `createSyndicate`, no `SyndicateGovernor`, no
>   propose → vote → execute, no WOOD/sWOOD voting power, no guardian review window, no ~73 h vote
>   warp, no strategy duration ceiling. `ISyndicateGovernor` and `BatchExecutorLib` are deleted;
>   `ILeveragedAeroVault` is down to three functions.
> - The strategy lifecycle is **owner-driven**: `Pending → Executed → Settled` via
>   `vault.activateStrategy(seed)` and `vault.settleStrategy()`. The `proposer` role **survives** for
>   the tunable-params / operator surface (`onlyProposer`, `state()` unchanged).
> - The vendored framework shims (`BaseStrategy`, `interfaces/`, `libraries/`) sit at the
>   `src/leveraged-aero/` root; the old `sherwood/` subdirectory is gone. Nothing calls Sherwood.
> - The post-settlement exit is the vault's **permissionless** `redeemSettled(shares)`.
> - The strategy now initializes against **any** Aerodrome Slipstream pool, and `rerange` is in-repo —
>   in its 4-arg `rerange(uint24 width_, uint16 skewBps_, uint256 minLiq0, uint256 minLiq1)` form, which
>   carries a per-cycle **skew** alongside the width (see B.3).

---

## Actors & canonical addresses (Base mainnet / fork-native)

These resolve identically on real Base and on any correctly-forked vnet — fork-nativeness comes from
the forked **state** (`fork_config.network_id=8453`), not from the reported chain id. Mamo values come
from `addresses/<block.chainid>.json`: `addresses/8453.json` on an 8453-chain-id vnet, or a verbatim
copy named for the custom id (e.g. `addresses/73578453.json`) when the vnet reports one (constraint 1).

| Role | Key | Address |
|---|---|---|
| Mamo multisig (registry admin / **vault owner**) | `MAMO_MULTISIG` | `0x26c158A4CD56d148c554190A95A921d90F00C160` |
| Mamo backend (account-layer operator) | `MAMO_BACKEND` | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` |
| Rebalancer ops (strategy `proposer`) — **vnet throwaway** | `MAMO_REBALANCER` | `0x73f6B456d063F78129113D42DBC315b9eEee8FAf` |
| Deployer EOA | `DEPLOYER_EOA` | `0xDca82E03057329f53Ed4173429D46B0511E46Fb8` |
| Mamo strategy registry | `MAMO_STRATEGY_REGISTRY` | `0x46a5624C2ba92c08aBA4B206297052EDf14baa92` |
| USDC | `USDC` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Two keys are **created by this runbook** and are deliberately **not** committed to
`addresses/8453.json` (see the address-resolution note in Phase C):

| Key | What it points at |
|---|---|
| `LEVERAGED_AERO_VAULT` | the `LeveragedAeroVault` from Phase B |
| `LEVERAGED_AERO_STRATEGY` | the `LeveragedAerodromeCLStrategy` clone from Phase B |

> **Naming.** `config/strategies/LeveragedAeroAccountConfig.json` calls the strategy key
> `leveragedAeroStrategy` / `LEVERAGED_AERO_STRATEGY`, and the factory getter is
> `factory.leveragedAeroStrategy()`. The former `SHERWOOD_*` / `sherwoodStrategy` spellings were
> retired pre-mainnet — use the names above verbatim or lookups fail.

> On a vnet, all privileged roles are driven by **unlocked impersonation** through the admin RPC — no
> private keys. Throwaway EOAs are used only for simulated end users.

---

## Hard constraints (read before every run)

> 1. **The chain id needs a matching address book + `EXPECTED_CHAIN` — custom ids are supported and
>    now preferred.** Venue addresses (USDC, Moonwell, Aerodrome, Chainlink feeds) resolve from forked
>    **state**, so any reported chain id keeps them fork-native. Exactly two things key off the id:
>    Mamo's FPS `Addresses` book reads `addresses/<block.chainid>.json` (make a verbatim copy of
>    `addresses/8453.json` named for the custom id), and `chain_sanity` asserts
>    `EXPECTED_CHAIN` (export it before every harness run). A custom id (Tenderly's `7357`-prefix
>    convention, e.g. `73578453` — proven live 2026-08-13, both harnesses green) buys replay-attack
>    protection, wallet disambiguation from real Base, and a forge fork cache that can't mix vnet and
>    real-Base slots. Keep `--no-storage-caching` regardless: `tenderly_setCode` mutates state without
>    mining a block, so a same-height cache entry can serve pre-override code either way.
> 2. **Feed freshness is solved by the FreshFeed pattern.** On a raw Base fork the forked Chainlink
>    answers are frozen, so `updatedAt` recedes as the clock advances and every priced path bricks with
>    `StaleOracle` in ~1 day (`maxDelay` is an init param, bounded to `(0, 7 days]`). The fix is
>    to **code-replace the 5 venue feeds** (leg A/USD, leg B/USD, USDC/USD, AERO/USD, L2
>    sequencer-uptime) with `FreshFeed` mocks whose `updatedAt` tracks `block.timestamp`, via
>    `tenderly_setCode`. Feeds are then permanently fresh, prices frozen-but-movable, and time-warping
>    is safe. Verified live 2026-07-26 on the Sherwood-era instance (clock +5 days, feed lag 60 s, full
>    e2e green). The in-repo implementation is `script/tenderly/FreshFeed.sol`, applied by
>    `run-leveraged-aero-stack.sh` phase B.0. **It is not optional: without it the instance is dead in
>    about a day.**
> 3. **State sync stays OFF.** It is a creation-time-only flag (API-verified 2026-07-26), so this is
>    locked when you create the vnet — get it right. Two reasons, and note that the *old* reason has
>    changed: with the governance warp gone the vnet clock no longer runs days ahead of real time, so
>    "state-synced mainnet timestamps would read as days-stale" is **no longer** the argument. What
>    holds now: (a) it is **unnecessary** — FreshFeed already makes freshness clock-independent; and
>    (b) it is **actively hostile to FreshFeed** — the fix is a code override on *mainnet* feed
>    addresses, exactly the accounts a state-syncing vnet re-hydrates from the parent network, which
>    would silently restore the real aggregators and bring the staleness treadmill back. Deployed
>    stack addresses are vnet-only and unaffected; the overridden feeds are the exposure.
>
>    **Reason (c), observed live 2026-07-29 — it also breaks the LP pool's TWAP, which is the
>    expensive failure.** A state-synced instance keeps re-hydrating the Slipstream pool's oracle
>    ring buffer from the parent chain while `slot0.observationIndex` stays frozen at the vnet's own
>    last swap. `oldest = observations[index + 1]` then resolves to a *recent* live entry, so
>    `pool.observe([twapWindow, 0])` reverts `'OLD'` — that is the calm gate inside
>    `LeveragedAeroValuation.netEquityUsdc`, i.e. **every** priced path (`nav()`, `deposit`,
>    `redeem`, `compound`, `deployIdle`'s health assert) fail-closes. It does **not** self-heal, and
>    since the flag is creation-time-only the instance cannot be repaired — only replaced. Note the
>    FreshFeed asserts still pass on such an instance (`tenderly_setCode` writes are vnet-local), so
>    green feeds are **not** evidence that state sync is off.
>
>    `run-leveraged-aero-stack.sh` now enforces this in **phase B.-1**, before it deploys anything:
>    it checks `sync_state_config.enabled` through the Tenderly API when creds resolve the instance,
>    and — always — functionally probes `pool.observe([twapWindow, 0])` and dies if it reverts. The
>    functional probe is the load-bearing one: an aliased RPC URL
>    (`…rpc.tenderly.co/<account>/<project>/<slug>`) cannot be mapped back to an API record, because
>    the API only returns UUID-form rpc urls and the alias slug is unrelated to the vnet slug.
> 4. **Base per-tx gas cap = 16,777,216 (2^24).** `estimate × gas-multiplier` must stay under it. Large
>    `CREATE`s (impl/factory, the strategy template + its three libraries) use a modest multiplier
>    (`DEPLOY_GAS_MULT=200`); deep nested delegatecalls want more headroom. Watch the multiplier on
>    both bounds.
> 5. **Unlocked impersonation replaces all privileged keys** — `MAMO_MULTISIG`, `MAMO_BACKEND`,
>    `DEPLOYER_EOA`, the strategy proposer. Only end users are throwaway EOAs.

---

## Phase A — create the vnet (Tenderly)

Create a **fresh, persistent** Virtual TestNet forking Base:

- Fork network: **Base (8453)**.
- Virtual network chain id: **custom, `7357`-prefix convention preferred** (e.g. `73578453` — the
  current instance). Constraint 1 lists the two accommodations a custom id needs
  (`addresses/<id>.json` copy + `EXPECTED_CHAIN=<id>`); `8453` also still works.
- **State sync: DISABLED** (constraint 3 — creation-time-only, unnecessary, and it would undo the
  FreshFeed overrides). This is a deliberate choice, **not** an API limitation: Tenderly supports
  sync with custom chain ids; it is the FreshFeed overrides and the pool TWAP ring buffer that
  cannot survive a syncing parent.
- Explorer: optional.
- Persistence: **no auto-delete** (the pooled layer must survive across the multi-step deploy and all
  downstream FE/BE work).

Two ways to create it:

**(a) Tenderly dashboard** — New Virtual TestNet → fork Base → set the virtual chain id (custom
preferred, e.g. `73578453`) → persistent. Copy the **Admin RPC**, **Public RPC**, vnet id, and fork
block.

**(b) Reuse the harness creation mechanism.** `script/tenderly/lib/common.sh` `resolve_vnet()` already
codifies the exact API call this repo uses (`POST …/vnets` with
`fork_config.network_id=8453` + `virtual_network_config.chain_config.chain_id=${VNET_CHAIN_ID:-8453}`,
`sync_state_config.enabled=false`). Export `VNET_CHAIN_ID` for a custom id. It reads creds from `.env`:

```
TENDERLY_ACCESS_KEY=...
TENDERLY_ACCOUNT_SLUG=...     # or ACCOUNT_SLUG
TENDERLY_PROJECT_SLUG=...     # or PROJECT_SLUG
```

The per-contract harnesses that call `resolve_vnet` create an **ephemeral** vnet (torn down on exit
unless `KEEP_VNET=1`). For this runbook you want a **persistent** vnet, so prefer the dashboard, or
POST once by hand and record the id. Do not rely on a harness to keep it alive.

**Record** (you will paste these into later phases):

| Field | Where it's used |
|---|---|
| vnet id | teardown / bookkeeping |
| **Admin RPC** | every write in Phases B and C; `TENDERLY_VNET_RPC_URL` (accepts `eth_sendTransaction` from any unlocked sender **and** serves reads). **Store it in 1Password, never in a committed file** — `.env` and `adminRpc` in the config stay pointers, not URLs |
| Public RPC | read-only `cast` verification; the only RPC published in `script/tenderly/leveraged-aero-vnet.json` (`publicRpc`) and in docs |
| fork block | reproducibility |

---

## Phase B — pooled layer: vault + strategy clone (this repo)

**One command runs this whole phase:**

```bash
TENDERLY_VNET_RPC_URL=<admin-rpc> \
TENDERLY_VNET_PUBLIC_RPC_URL=<public-rpc> \
MAMO_REBALANCER=<rebalancer-ops-addr> \
SEED=100000000000 \
make tenderly-leveraged-aero-stack
```

`make tenderly-leveraged-aero-stack` → `./script/tenderly/run-harness.sh leveraged-aero-stack` →
`./script/tenderly/run-leveraged-aero-stack.sh`, whose phases are exactly B.0–B.5 below and which
**asserts every B.6 post-condition** before it exits. Like the account harness it **always reuses**
`TENDERLY_VNET_RPC_URL` (the pooled layer must land on the shared persistent vnet — an ephemeral fork
would be deleted with the stack on it), needs **no broadcaster key** (unlocked impersonation for
`MAMO_MULTISIG` / `DEPLOYER_EOA`), and **never time-warps**. A CLI-supplied `TENDERLY_VNET_RPC_URL`
wins over the `.env` value.

The tooling:

| File | Role |
|---|---|
| `script/tenderly/run-leveraged-aero-stack.sh` | orchestrator (B.0 cheat-RPCs, the impersonated multisig sends, all asserts, config emit) |
| `script/tenderly/LeveragedAeroStackHarness.s.sol` | `deployTemplate()` (B.1) and `buildInitData()` (B.2) |
| `script/tenderly/FreshFeed.sol` | the B.0 aggregator stand-in |

Reference implementation for this phase: `multisig/mamo-multisig/015_DeployLeveragedAeroPooledSystem.sol`
(the mainnet proposal — same deploy/bind/activate sequence, minus the vnet cheat-RPCs).

Everything is env-driven; the venue book's Base defaults live in the two script files (kept in
lockstep) and are documented in `script/tenderly/README.md`. The snippets in B.0–B.5 are the
**equivalent raw `cast`** for a by-hand run or a debug session:

```bash
ADMIN="https://virtual.base.<...>.rpc.tenderly.co/<admin-uuid>"    # writes (unlocked impersonation)
PUB="https://virtual.base.<...>.rpc.tenderly.co/<public-uuid>"     # reads
MULTISIG=0x26c158A4CD56d148c554190A95A921d90F00C160                # MAMO_MULTISIG (vault owner)
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
REBALANCER=0x...   # MAMO_REBALANCER — the strategy proposer (NOT MAMO_BACKEND, see below)
TEMPLATE=0x...     # from B.1
VAULT=0x...        # from B.1
STRAT=0x...        # the clone from B.3
```

> **The `proposer` role is `MAMO_REBALANCER`, a NEW dedicated operator address — deliberately NOT
> `MAMO_BACKEND`.** The strategy has exactly one operator role (`onlyProposer`: `rerange`, `compound`,
> `fulfillRedeem`, deleverage) and the **rebalancer service** owns it; the Mamo backend drives the
> *account* layer. Collapsing them would hand account-layer keys the levered book's operator surface.
> The vnet default is a throwaway keypair (`0x73f6B456d063F78129113D42DBC315b9eEee8FAf`; its private
> key is published in the runner header so anyone can drive the role on the fork).
> **Mainnet must pass the real rebalancer ops key via `MAMO_REBALANCER`.** Unless `FEE_RECIPIENT`
> overrides it, the proposer is also the strategy's `feeRecipient` — the address that receives the
> in-kind AERO skim taken at every `compound` (`COMPOUND_FEE_BPS`, default `500` = 5 % of the tranche).

### B.0 — FreshFeed code-replacement (do this first, per constraint 2)

Replace the 5 venue Chainlink aggregators with `script/tenderly/FreshFeed.sol` mocks that return the
forked answer but report a permanently fresh `updatedAt`. Per feed address the script:

1. Reads the live aggregator's `decimals()` and `latestRoundData()` answer off the fork.
2. Deploys a `FreshFeed` carrying that answer + decimals as **immutables** (`cast send --create`, so
   no broadcaster key is needed). `updatedAt` is reported as `block.timestamp - 60` and `startedAt` as
   `block.timestamp - 30 days`. `decimals()` is preserved verbatim — AERO/USD **must** stay 8dp (the
   strategy asserts `UnexpectedFeedDecimals` at init) and `_readUsd8` re-checks the others per read.
3. `cast rpc tenderly_setCode '["<feedAddr>","0x<freshFeedRuntime>"]'` on the **admin** RPC, so the
   override lands at the *mainnet feed address* the strategy is initialized with. `FreshFeed` is
   storage-free by construction (immutables only), which is what makes a code-only override sound.
4. The **sequencer-uptime** feed gets the same treatment, different shape: `answer == 0` (up), and the
   30-day-old `startedAt` clears any `gracePeriod` (bounded to `<= 1 day` at init).
5. Asserts `updatedAt` is within seconds of the head timestamp — a large lag means the override did
   not land. Re-asserted at the end of the run (B.5).

Feeds covered: leg A/USD, leg B/USD, USDC/USD, AERO/USD, L2 sequencer uptime — i.e. exactly the five
`*Feed` members of `LeveragedAerodromeCLStrategy.InitParams`, addresses env-driven
(`LEG_A_FEED` / `LEG_B_FEED` / `USDC_FEED` / `AERO_FEED` / `SEQ_FEED`).

Prices are frozen but **movable**: deploy another `FreshFeed` with a different answer and
`tenderly_setCode` it over the same address again. `--no-freshfeed` skips the whole phase on an
instance that already carries the mocks (re-running it is harmless — it is idempotent, since reading
an already-overridden feed yields the same answer).

### B.1 — deploy the strategy template + `LeveragedAeroVault`

`LeveragedAeroStackHarness.deployTemplate()`, broadcast as `DEPLOYER_EOA`
(`--unlocked --sender DEPLOYER_EOA --gas-estimate-multiplier 200`).

**The template.** `LeveragedAerodromeCLStrategy`'s three libraries (`LeveragedAeroManager`,
`LeveragedAeroValuation`, `LeveragedAeroVenue`) have external functions and are `delegatecall`ed — a
`forge script` broadcast deploys and links them automatically; a raw `cast` deploy does not, which is
why B.1 is a forge script at all. Each library is its own tx, so the Base per-tx gas cap
(16,777,216) applies per `CREATE` and the 200% multiplier clears all of them. The template's
constructor sets `_initialized = true`, permanently locking `initialize` on the template itself
(ERC-1167 clones skip constructors, so clones stay initializable).

> **Never pass `--libraries` for this stack.** The three delegatecall libraries must be deployed and
> linked by the **same compilation** that produces the template. Pointing the link at libraries from an
> earlier run reverts inside the delegatecall dispatcher rather than failing at link time, and it is not
> a theoretical risk here: this PR changed the libraries' public selectors (`centeredTickRange` →
> `skewedTickRange`, the new `checkRange`). Let the broadcast deploy and link them; if you have stale
> library addresses in an env or a config, delete them.

**The vault.** `src/LeveragedAeroVault.sol`, constructor
`(address asset_, address owner_, string name_, string symbol_)`:

| Arg | Value |
|---|---|
| `asset_` | `USDC` (`0x8335…2913`) — must equal the strategy's unit of account or init reverts `AssetMismatch` |
| `owner_` | `MAMO_MULTISIG` |
| `name_` / `symbol_` | share-token metadata — `"Mamo Leveraged Aero Vault"` / `"mlaUSDC"` (`VAULT_NAME` / `VAULT_SYMBOL`) |

> **`decimals()` is derived, not stored: `asset.decimals() + 6` = 12dp for USDC.** Load-bearing — the
> strategy's genesis pricing uses a hardcoded `SHARES_VIRTUAL_OFFSET = 1e6`
> (`shares = assets × (supply + 1e6) / (nav + 1)`), which is exactly a 6-decimal step up from a 6dp
> asset. Any other offset makes the advertised denomination disagree with what the strategy mints.

State after deploy: `strategy == address(0)`, `depositsOpen == false`. Non-upgradeable by design.

### B.2 — vault ownership: nothing to accept

The vault is `Ownable2Step`, but `Ownable(owner_)` in the constructor makes `MAMO_MULTISIG` owner
**immediately** — Ownable2Step's acceptance only gates *later* transfers. B.1 passes
`owner_ = MAMO_MULTISIG`, so there is no `acceptOwnership()` step and the script asserts
`owner() == MAMO_MULTISIG` / `pendingOwner() == 0x0` right after the deploy.

**If you instead deploy as `DEPLOYER_EOA` and hand off**, `transferOwnership(MAMO_MULTISIG)` only
*nominates* — the multisig must call `acceptOwnership()` or every `onlyOwner` path (`cloneAndBind`,
`activateStrategy`, proposal 012's `setOpenDeposits(true)`) reverts:

```bash
# only needed on the deploy-then-hand-off path
cast send "$VAULT" 'acceptOwnership()' --from "$MULTISIG" --unlocked --rpc-url "$ADMIN"
```

Prefer `owner_ = MAMO_MULTISIG` in the constructor and skip the two-step entirely.

### B.3 — clone + `initialize` + bind, atomically: `cloneAndBind`

`buildInitData()` ABI-encodes `InitParams` from the venue book (env vars, Base defaults in the script;
no RPC needed — it is a pure `env → abi.encode`), and the owner calls **one** vault function:

```bash
cast send "$VAULT" 'cloneAndBind(address,address,bytes)' "$TEMPLATE" "$REBALANCER" "$INITDATA" \
  --from "$MULTISIG" --unlocked --gas-limit 8000000 --rpc-url "$ADMIN"
cast call "$VAULT" 'strategy()(address)' --rpc-url "$PUB"     # the clone
```

`cloneAndBind(template, proposer_, initData)` is `onlyOwner` and does `Clones.clone` →
`clone.initialize(address(this), proposer_, initData)` → `_bind(clone)` in a single transaction.

> **This closes a real window.** A bare `Clones.clone` leaves the fresh clone initializable by
> **anyone** (the template's constructor only locks the *template*), so between a two-step
> clone-then-initialize a front-runner could seize the `proposer` role. `cloneAndBind` removes the gap
> entirely, and `_bind` still re-checks `clone.vault() == address(this)` — a clone initialized against
> a different vault can never be bound here. It is also the ONLY wiring path: `BaseStrategy.initialize`
> requires `msg.sender == vault_`, so nothing outside the vault can initialize a clone naming it, and the
> old manual `setStrategy(address)` was removed.

The proposer passed here is **`MAMO_REBALANCER`**, not `MAMO_BACKEND` (see the note at the top of this
phase).

**A wrong venue value fails HERE, loudly** — which is the point of doing it in one owner tx:
`VenueMismatch` (pool spacing or token set, a Moonwell `underlying()` that does not match its leg, or a
leg↔USDC swap pool that does not exist at the configured spacing — both swap spacings are
existence-probed through the CL factory), `UnsupportedLeg`, `LegDecimalsOutOfRange`, `AssetMismatch`,
`UnexpectedFeedDecimals`, `OutOfBounds` (the width band **or** `skewBps` — one error covers both), or one
of the risk / oracle / fee bound errors.

`InitParams` is **leg slots, not token identities** (`weth*` = leg A, the natively-wrappable slot;
`cbBTC*` = leg B — the names are historical). Any Slipstream pool whose two tokens have Moonwell borrow
markets and Chainlink feeds can fill them. Fields the any-pool change made *inputs* rather than
constants:

| Field | Note |
|---|---|
| `tickSpacing` | LP pool spacing; asserted `== pool.tickSpacing()` → `VenueMismatch` |
| `cbBTCSwapTickSpacing`, `wethSwapTickSpacing` | spacings of the leg↔USDC **swap** pools — separate venues from the LP pool, nonzero required. These replaced three hardcoded `int24(100)` literals |
| `wethDeliversNative` | leg A's Moonwell market pays native ETH on borrow → the strategy wraps it. `false` on an ERC-20-delivering market (and then stray ETH is stranded — there is no ETH rescue path) |
| `width`, `minWidth`, `maxWidth` | rerange width band, validated once at init: both bounds on the spacing grid, `minWidth ≥ 2 × spacing`, `minWidth ≤ maxWidth`, and `width` inside the band. Genesis mints at `width` |
| `skewBps` | fraction of `width` placed **below** the current tick, bps (`10000` = 1.00). `5000` = centered — the genesis/ops default, and what `SKEW_BPS` defaults to in the runner. Must be in `(0, 10000)` exclusive, inside `[minSkewBps, maxSkewBps]`, **and** leave both spans ≥ one `tickSpacing` → `OutOfBounds()`. Persisted like `width`: genesis mints at it, `rerange` moves it |
| `minSkewBps`, `maxSkewBps` | the **skew governance band**, the skew analogue of `[minWidth, maxWidth]`. Two new fields sitting immediately after `skewBps` in `InitParams` / `Layout` / `layout()`. The band itself is validated once at init — `0 < minSkewBps ≤ maxSkewBps < 10000`, so it can only ever **tighten** the open `(0, 10000)` interval, never widen it — and the genesis `skewBps` is then checked against it by the same `checkRange` that runs on **every** `rerange`. All of it raises the same `OutOfBounds()`; no new selector. Runner env: `MIN_SKEW_BPS` (default `1000`) / `MAX_SKEW_BPS` (default `9000`). Immutable after init: widening the band means a new clone |

Derived at init, never passed: **leg token ordering** (`wethIsToken0` from `pool.token0()`) and **leg
decimals** (`IERC20Metadata.decimals()`, bounded `[2, 18]` → `LegDecimalsOutOfRange`).

Init guards that will bite during a first deploy against a new pool:

- `pool.tickSpacing()` and the `{token0, token1}` set must match the declared legs → `VenueMismatch`.
- `IMoonwellMarket(mLegX).underlying() == legX` for **both** borrow markets → `VenueMismatch`.
- A leg equal to `USDC`, or equal to the gauge's `rewardToken()`, is rejected → `UnsupportedLeg`.
- `usdc == IERC4626(vault).asset()` and `USDC.decimals() == 6` → `AssetMismatch` /
  `UnexpectedAssetDecimals`.
- `aeroUsdFeed.decimals() == 8` → `UnexpectedFeedDecimals`.
- Risk/oracle bands: `targetLtvBps ≤ maxLtvBps < usdcCollateralFactorBps`, `minHealthBps ≥ 10500`,
  `minHealthBps × maxLtvBps < 1e8`, **`minHealthBps × cfBps > 1e8`** (`DeleverageTriggerAboveCF` — the
  deleverage trigger LTV `1e8/minHealthBps` must sit strictly below the CF, so the real `minHealthBps`
  floor is `1e8/cfBps`: **11364** at the live CF of 8800, not 10500 — and it binds at init and at every
  `migrateVenue` **only**, so a Moonwell CF cut afterwards reopens the liquidatable-but-locked window
  until the next migration), `maxDelay ∈ (0, 7 days]`, `gracePeriod ≤ 1 day`,
  `twapWindow ∈ (0, 1 day]`, `calmDeviationTicks ∈ (0, 5000]`, `maxSlippageBps ∈ (0, 1000]`.
- The fee bound: `compoundFeeBps ≤ 1000` (`MAX_COMPOUND_FEE_BPS`, 10 %) → `CompoundFeeTooHigh`, and a
  nonzero `feeRecipient` whenever `compoundFeeBps != 0` → `FeeRecipientRequired`. Both init-only and
  immutable per clone — changing either means a new clone.

`rerange(uint24 width_, uint16 skewBps_, uint256 minLiq0, uint256 minLiq1)` is **in-repo**
(`onlyProposer`, persisted per-cycle width **and** skew, re-checked against the init width band, the
init skew band and the one-spacing-per-side floor → `OutOfBounds()`, selector `0xb4120f14`). That whole
check now lives in `LeveragedAeroValuation.checkRange`, called from the strategy before the venue
delegatecall — same behaviour as the previous strategy-local checks, plus the skew band. The old "the
vendored copy is behind upstream, re-vendor pending" caveat is **obsolete** — delete it on sight.

> **Two signature/selector changes landed together here.** `rerange` grew a `uint16 skewBps_` second
> argument (was `rerange(uint24,uint256,uint256)`), and `WidthOutOfBounds()` (`0x1f9f54af`) was renamed
> `OutOfBounds()` (`0xb4120f14`) and now covers skew failures as well as width ones. Anything holding
> either value hardcoded — the Mamo backend's rebalance-param error table above all — must be
> re-pointed. Re-derive rather than copy: `cast sig 'OutOfBounds()'`,
> `cast sig 'rerange(uint24,uint16,uint256,uint256)'`.
>
> **Three more breaks moved `layout()` positions.** The skew band (`minSkewBps` / `maxSkewBps`) was
> INSERTED after `skewBps`, not appended; the protocol-fee removal then DELETED `protocolFeeOwed` at
> position 34; the fee-model swap then dropped four more (`managementFeeBps`, `performanceFeeBps`,
> `hwmPerShare`, `lastFeeAccrualTimestamp`) and inserted `compoundFeeBps` at 29, ahead of
> `feeRecipient` at 30. `layout()` is **48 fields** now: fields 1–28 unchanged, `skewBps` at 43, the
> skew band at 44/45, `hedgedDebtA`/`hedgedDebtB` at 46/47, `stagedVenueHash` last at 48. Any hand-rolled
> `abi.encode` of `InitParams`, and any positional decode of `layout()`, must be
> regenerated against the current ABI — `buildInitData()` is generated from the struct and needs no
> change, but a copied calldata blob from an earlier run will initialize the wrong fields.

### B.4 — the bind (already done by B.3)

`cloneAndBind` bound the clone in the same transaction it created it, so there is no separate step —
the script just asserts both directions (`vault.strategy() == clone`, `clone.vault() == vault`) plus
`clone.proposer() == MAMO_REBALANCER` and `clone.state() == 0` (Pending).

The bind is **set-once** (`onlyOwner`, reverts `LAV: strategy already set`). `msg.sender == strategy` is
the sole protection against arbitrary share inflation, so the STRATEGY pointer has no rotation path: a
wrong clone means a new vault.

> **The OPERATOR does rotate.** `vault.setProposer(newProposer)` (`onlyOwner`) drives the strategy's
> `onlyVault` `setProposer` — not set-once, not state-gated, zero rejected, emits
> `ProposerUpdated(old, new)`. That is the incident response for a compromised `MAMO_REBALANCER` key;
> without it the only answer was `settleStrategy()`, a terminal unwind of the whole fund.
>
> ```bash
> cast send "$VAULT" 'setProposer(address)' "$NEW_REBALANCER" --from "$MAMO_MULTISIG" --unlocked
> cast call "$STRAT" 'proposer()(address)'   # assert it moved
> ```
>
> It does **not** move `layout().feeRecipient` (init-only) and it is not a fund-moving power — the
> incoming key inherits exactly the `onlyProposer` surface.

### B.5 — activate: `Pending → Executed`

`activateStrategy` pulls the seed **from the caller** (the owner) straight to the strategy, calls
`strategy.execute()`, then mints the seeder the genesis shares. The vault being the caller is what
satisfies the strategy's `onlyVault` (a raw `msg.sender == vault` compare) — that is the whole reason
activation goes through the vault.

```bash
SEED=100000000000                                   # 100,000 USDC (6dp) — the harness default
cast rpc tenderly_setErc20Balance "[\"$USDC\",\"$MULTISIG\",\"0x2E90EDD000\"]" --rpc-url "$ADMIN"
cast send "$USDC"  'approve(address,uint256)' "$VAULT" "$SEED" --from "$MULTISIG" --unlocked --rpc-url "$ADMIN"
cast send "$VAULT" 'activateStrategy(uint256)' "$SEED" --from "$MULTISIG" --unlocked \
  --gas-limit 12000000 --rpc-url "$ADMIN"
```

> - The owner must **approve the vault** for the seed — the transfer is
>   `safeTransferFrom(msg.sender, strategy, seedAmount)` and the vault never custodies it.
> - `seedAmount == 0` does **not** fail in the vault: it fails inside `execute()` with
>   `ExecuteZeroBalance` (`_supplyCollateral` reads the strategy's own balance). A seed is mandatory.
> - **The seed DOES mint shares** — `seedAmount × 10^(vault.decimals() − asset.decimals())` =
>   `seed × 1e6`, minted to the caller after `execute()` (added in the PR #66 review remediation,
>   commit `db57584`; the earlier "the seed mints no shares / it is a gift to the first depositor"
>   note is **obsolete**). That is the same `assets × 1e6` the strategy's own
>   `shares = assets × (supply + 1e6) / (nav + 1)` produces on an empty book, so supply and NAV stay in
>   step and the first real depositor mints a fair claim. The mint is a direct `_mint`, deliberately
>   **not** `strategyMint`, so it is not subject to the `depositsOpen` gate.
> - `--gas-limit` is set explicitly: `execute()` supplies collateral, borrows both legs, swaps, mints
>   the CL position and stakes it, and the vnet under-estimates deep nested delegatecalls. Stay under
>   the Base per-tx cap of 16,777,216.
> - Leave `depositsOpen == false` here. Phase C (proposal 012's `build()`) flips it — keeping the flip
>   in 012 is what makes the vnet run a faithful rehearsal of the mainnet proposal.

`settleStrategy()` is the mirror image (`onlyOwner`, `Executed → Settled`, one-way): the strategy
unwinds the whole levered book and pushes realized USDC to the vault, after which the **only** exit is
the vault's permissionless `redeemSettled(shares)` — pro-rata on pre-burn supply and pre-transfer
balance. Do **not** settle a staging instance you still want to use: the strategy's own redeem paths
require `State.Executed` and there is no path back.

> **Operational rule (defense-in-depth) — `compound()` immediately before `settle()`.** No longer
> mandatory: `_settle` now **sells** the final AERO tranche its unwind auto-claims (`gauge.withdraw`
> auto-claims whatever accrued since the last harvest), so the proceeds land in the USDC pushed to the
> vault for `redeemSettled` to pay out. Compounding first is still the recommended procedure, because
> that sale is **best-effort**: `settle()` is terminal, owner-driven and argument-less, so a hard revert
> there would block the fund's only exit — the sale is therefore wrapped in a self-`try/catch` and a
> stale AERO/USD feed, a broken AERO→USDC route, or a fill under the L9 oracle floor makes it **skip**
> (the swap is rolled back whole — it never sells blind) and emit `SettleRewardSaleDeferred`. Harvesting
> in the block before settling means you are not relying on that path at all, and bounds the residue to a
> single block of emissions either way.
>
> **Check `SettleRewardSaleDeferred` / the strategy's AERO balance after settling.** If the sale did
> skip, the AERO is not lost but recovery is not automatic: it is claimable **only** through
> `rescueToVault(aero)` → the vault's `rescueERC20(aero, to, amount)`.
> That path does work post-settle — `rescueToVault`'s reward-token block is scoped to `State.Executed`
> precisely so a `Settled` strategy can sweep a stranded tranche — but it is two privileged
> transactions after the fact, and the AERO reaches the vault as a **stray token the owner disposes of**,
> not as part of the settled USDC pot `redeemSettled` pays holders out of.

### B.6 — post-conditions Phase C requires

**The harness asserts all of these itself** and fails the run on any mismatch (phase `B.5 —
post-conditions` in `script/tenderly/harness-results-leveraged-aero-stack.log`). The equivalent reads,
on the **public RPC**:

```bash
PUB="https://virtual.base.<...>.rpc.tenderly.co/<public-uuid>"
STRAT=0x...; VAULT=0x...

cast call "$STRAT" 'state()(uint8)'       --rpc-url "$PUB"   # 1  (BaseStrategy.State: Pending=0, Executed=1, Settled=2)
cast call "$STRAT" 'nav()(uint256)'       --rpc-url "$PUB"   # > 0
cast call "$STRAT" 'vault()(address)'     --rpc-url "$PUB"   # == $VAULT
cast call "$STRAT" 'proposer()(address)'  --rpc-url "$PUB"   # == MAMO_REBALANCER
cast call "$VAULT" 'strategy()(address)'  --rpc-url "$PUB"   # == $STRAT
cast call "$VAULT" 'owner()(address)'     --rpc-url "$PUB"   # == MAMO_MULTISIG
cast call "$VAULT" 'pendingOwner()(address)' --rpc-url "$PUB"   # 0x0
cast call "$VAULT" 'asset()(address)'     --rpc-url "$PUB"   # == USDC
cast call "$VAULT" 'depositsOpen()(bool)' --rpc-url "$PUB"   # false  (Phase C flips it to true)
cast call "$VAULT" 'settled()(bool)'      --rpc-url "$PUB"   # false
cast call "$VAULT" 'decimals()(uint8)'    --rpc-url "$PUB"   # 12     (USDC 6dp + 6)
cast call "$VAULT" 'totalSupply()(uint256)' --rpc-url "$PUB" # == SEED * 1e6 (the genesis mint)
cast call "$VAULT" 'balanceOf(address)(uint256)' "$MULTISIG" --rpc-url "$PUB"   # == SEED * 1e6
```

| Post-condition | Expected |
|---|---|
| `strategy.state()` | `1` — Executed |
| `strategy.nav()` | `> 0` (seeded and executed) |
| `strategy.vault()` | the `LeveragedAeroVault` |
| `strategy.proposer()` | `MAMO_REBALANCER` (the rebalancer ops address — **not** `MAMO_BACKEND`) |
| `vault.strategy()` | the clone (both directions bound) |
| `vault.owner()` | `MAMO_MULTISIG`, with `pendingOwner() == 0x0` |
| `vault.asset()` | `USDC` |
| `vault.depositsOpen()` | `false` (Phase C flips it) |
| `vault.settled()` | `false` |
| `vault.decimals()` | `12` |
| `vault.totalSupply()` = `balanceOf(MAMO_MULTISIG)` | `SEED × 1e6` — the genesis mint |
| all 5 venue feeds | FreshFeed'd (`updatedAt` within seconds of `block.timestamp`) |

On success the harness merge-writes `script/tenderly/leveraged-aero-vnet.json` — the machine-consumable
address book downstream consumers read. It owns the `pooled` (`vault`, `strategyClone`, `template`,
`proposer`, `seed`, `lpPool`) and `feeds` objects plus `vaultGeneration: 3`, and **nulls the account
addresses**: a new pooled layer invalidates the account factory (it binds the strategy clone at
construction), so Phase C must run again. The account harness merge-writes the `mamo` object back in,
so the two never clobber each other.

The merge also `del(.STALE)`s: a hand-added "this recorded layer is out of date, redeploy before use"
marker describes the layer being *replaced*, and a plain `$prev * {…}` would carry it forward onto the
fresh one. A successful run of Phase B is precisely the event that retires such a marker.

> ### ⚠ The recorded layer is PRE-CHANGE — redeploy before using the tooling against it
>
> **`script/tenderly/leveraged-aero-vnet.json` still points at the clone deployed before the
> fee-model swap**, whose `layout()` is the old **51-field** tuple. `compound-cycle.sh` pins the
> **48-field** signature and reads `compoundFeeBps` / `feeRecipient` at 29/30, so it **cannot decode
> that clone**: `cast call` fails silently and every `lay N` read — gauge, tokenId, `maxDelay`,
> `twapWindow`, the tick range — comes back **blank**, which surfaces as empty `snap` / `calm` /
> `check-feeds` output rather than an error.
>
> **Re-run Phase B and then Phase C from this branch before using the helper.** Until that lands,
> treat the recorded `pooled` addresses as `.STALE` (the marker above is exactly for this).

---

## Phase C — account layer (this repo, scripted)

Unchanged by the de-Sherwood work. Once B.6 passes:

```bash
TENDERLY_VNET_RPC_URL="<admin-rpc>" \
TENDERLY_VNET_PUBLIC_RPC_URL="<public-rpc>" \
make tenderly-leveraged-aero-account
```

`make tenderly-leveraged-aero-account` → `./script/tenderly/run-harness.sh leveraged-aero-account` →
`./script/tenderly/run-leveraged-aero-account.sh`. The harness **always reuses**
`TENDERLY_VNET_RPC_URL` (the pooled layer lives only on the persistent vnet; a freshly API-created fork
would not have it) and **never** creates, tears down, or time-warps the vnet. It needs **no**
broadcaster key — everything is unlocked impersonation.

A CLI-supplied `TENDERLY_VNET_RPC_URL` wins over the `.env` value (the `.env` one may point at an older
vnet without the stack). The two pooled-address env vars
(`LEVERAGED_AERO_STRATEGY` / `LEVERAGED_AERO_VAULT`) resolve **env → the `pooled` object
Phase B just wrote into `script/tenderly/leveraged-aero-vnet.json` → a hardcoded fallback**, so after a
Phase B run they normally need no override; pass them to target a different vnet.

> **Env-var names now match the address-book keys.** `LeveragedAeroAccountHarness.s.sol` injects
> `LEVERAGED_AERO_STRATEGY` and `LEVERAGED_AERO_VAULT` — the exact keys proposal 012 resolves, so
> running 012 itself against a vnet resolves both. (Before the rename the harness injected
> `SHERWOOD_SYNDICATE_VAULT` under the old key name, which 012's `vaultKey` lookup would have missed.)

### What it does

| Phase | Actions |
|---|---|
| **2 — deploy** | Funds `DEPLOYER_EOA` with ETH, then runs `LeveragedAeroAccountHarness.deploy()` — the real `LeveragedAeroAccountDeployer.deployImplementationAndFactory()` path (the **same** deploy code the 012 multisig proposal calls). Deploys the `MamoLeveragedAeroStrategy` UUPS impl + the `MamoLeveragedAeroStrategyFactory` (wired to registry, admin=`MAMO_MULTISIG`, backend=`MAMO_BACKEND`, impl, `strategyTypeId=5`, strategy clone, USDC). Parses `HARNESS_IMPL` / `HARNESS_FACTORY` from the log. |
| **3 — multisig `build()`** | As impersonated `MAMO_MULTISIG`: `registry.whitelistImplementation(impl, 5)`, `registry.grantRole(BACKEND_ROLE, factory)`, `vault.setOpenDeposits(true)`. Then `validate()` asserts: `whitelistedImplementations(impl)==true`, `implementationToId(impl)==5`, `latestImplementationById(5)==impl`, factory `hasRole(BACKEND_ROLE)`, `vault.depositsOpen()==true`, `factory.strategyTypeId()==5`, `factory.leveragedAeroStrategy()==$STRAT`, `factory.usdc()==USDC`. |
| **4 — e2e lifecycle** | Fresh throwaway user, funded ETH + 10,000 USDC. `createStrategyForUser` → `computeStrategyAddress` (assert `isUserStrategy` + `account.owner()==user`); `deposit(5,000 USDC, minShares)` (minShares from the strategy's `shares=assets*(supply+1e6)/(nav+1)` formula, 1% tol) → assert shares minted & mirrored on the vault; fast `withdraw(half, minOut)` → assert USDC lands on user, account USDC==0; `requestWithdraw` → `fulfillRedeem` (impersonated `proposer`) → assert the USDC landed on the USER directly (account USDC==0, no claim tx) → `syncRedeemRequests` prunes; `depositIdle` gate (a third party reverts "Not owner or backend"; `registry.getBackendAddress()` succeeds); `withdrawAll` cleanup; final clean-state asserts (shares==0, account USDC==0) + net user delta. |

> **Why the vault/strategy keys are runtime-injected, never committed to `addresses/8453.json`:** FPS
> `Addresses` validates `isContract` **eagerly** in its constructor (`_checkAddress`, gated on
> `chainId==block.chainid`). Committing them with `isContract:true` would revert the `Addresses`
> constructor on every real-Base-mainnet CI run, where no code lives at those addresses. The harness
> instead calls `addresses.addAddress(...)` from the env vars at runtime, so the keys exist only inside
> the vnet process (`LeveragedAeroAccountHarness._addFromEnv`, which also requires
> `value.code.length > 0`).

> **Verified note — `depositIdle` backend gate.** The gate checks `registry.getBackendAddress()`
> (BACKEND_ROLE member index 0), **not** the address-book `MAMO_BACKEND`. On the fork these differ; the
> harness reads the live value.

> **Redeploy hygiene — the registry never revokes a superseded pair (observed live 2026-08-13).**
> `whitelistImplementation(newImpl, 5)` only *adds*: the previous impl stays
> `whitelistedImplementations == true`, and the previous factory keeps `BACKEND_ROLE` (nothing pairs
> `grantRole` with a revoke). `latestImplementationById(5)` does move to the new impl, so nothing
> *routes* to the stale pair — but the old factory can still call `addStrategy`. On a vnet this is
> cosmetic; **a mainnet redeploy must pair the proposal with
> `registry.revokeRole(BACKEND_ROLE, oldFactory)`** (and treat the stale whitelist entry as an
> accepted, documented risk).

> **Verified note — proposal 012 vs the harness.** The FPS proposal is committed at
> `multisig/mamo-multisig/012_DeployLeveragedAeroAccountSystem.sol` (deploy + `preBuildMock` typeId-5
> guard + `build()` + `validate()`), and now types the vault as `LeveragedAeroVault` under the
> `LEVERAGED_AERO_VAULT` key. FPS proposals *simulate* multisig actions rather than broadcast them, so
> the harness replays 012's `build()`/`validate()` **as real broadcast txs inline in bash** (the three
> `csend` actions + the `assert_eq` block) — same actions, same asserts, live on the vnet. On mainnet
> the actual multisig executes the FPS proposal itself.

Results logs: `script/tenderly/harness-results-leveraged-aero-stack.log` (Phase B) and
`script/tenderly/harness-results-leveraged-aero.log` (Phase C).
Machine-consumable output (merge-written by both harnesses on every successful run, committed):
`script/tenderly/leveraged-aero-vnet.json`.

---

## Mainnet delta

The de-Sherwood change **removes the external blocker**: there is no Sherwood mainnet deployment to
wait on, no upstream governance to schedule around, and no third-party contract in the trust path. The
whole sequence is Mamo's to execute:

1. **Deploy the pooled layer** (Phase B, minus the vnet-only parts): the strategy template +
   `LeveragedAeroVault` with `owner_ = MAMO_MULTISIG`, then `cloneAndBind(template, MAMO_REBALANCER,
   initData)` from the multisig. **No FreshFeed** — real Chainlink feeds are genuinely fresh on mainnet,
   and `tenderly_*` cheat-RPCs do not exist. No impersonation: real signers throughout. **`proposer`
   must be the real rebalancer ops key** (`MAMO_REBALANCER`), never the vnet throwaway and never
   `MAMO_BACKEND`. Decide `LP_POOL` (pending product decision) before this step.
2. **Confirm vault ownership is live**, not pending — `owner() == MAMO_MULTISIG` and
   `pendingOwner() == 0x0`. `Ownable2Step` means a nomination is not enough, and 012's
   `setOpenDeposits(true)` reverts if the multisig has not accepted.
3. `vault.activateStrategy(seed)` from the multisig (with the USDC approval to the vault first — the
   seed is pulled from the caller). The seed **does** mint the multisig `seed × 1e6` shares, so it is a
   real position, not a gift; size it as capital, and keep it large enough to clear
   `ExecuteZeroBalance` and to make the first deposits price sanely.
4. **Proposal 012 executed by the actual multisig**, not unlocked impersonation. The **typeId-5
   availability guard** still applies: `preBuildMock` asserts
   `latestImplementationById(5) == address(0)` and `nextStrategyTypeId() <= 5` before whitelisting (the
   stale-counter-safe check).
5. **Commit the address keys.** At that point `LEVERAGED_AERO_VAULT` and
   `LEVERAGED_AERO_STRATEGY` **are** added to `addresses/8453.json` — safe then, because the
   code genuinely exists on mainnet and the eager `isContract` check passes.

The two once-open mainnet gates are closed by `test/LeveragedAeroSystemSetup.integration.t.sol`
(`make leveraged-aero-setup`): the chosen pool has USDC as token0, so the rehearsal drives the
`wethIsToken0 == false` ordering through a full lifecycle, and running 015 against the real
markets exercises the `IMoonwellMarket.underlying()` init guard.

---

## Verification checklist (copy-paste `cast` one-liners)

Set once (public RPC + resolved addresses from the run):

```bash
PUB="https://virtual.base.<...>.rpc.tenderly.co/<public-uuid>"
REG=0x46a5624C2ba92c08aBA4B206297052EDf14baa92     # MAMO_STRATEGY_REGISTRY
VAULT=0x...        STRAT=0x...
IMPL=0x...         FACTORY=0x...
MULTISIG=0x26c158A4CD56d148c554190A95A921d90F00C160
BACKEND=0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73        # MAMO_BACKEND — factory BACKEND_ROLE only
REBALANCER=0x73f6B456d063F78129113D42DBC315b9eEee8FAf   # MAMO_REBALANCER (vnet default) — the strategy proposer
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

**Pooled layer live (Phase B):**

```bash
cast chain-id --rpc-url "$PUB"     # == chainId in leveraged-aero-vnet.json (73578453 on the current instance)
cast call "$STRAT" 'state()(uint8)'      --rpc-url "$PUB"        # 1  (Executed)
cast call "$STRAT" 'nav()(uint256)'      --rpc-url "$PUB"        # > 0
cast call "$STRAT" 'vault()(address)'    --rpc-url "$PUB"        # == $VAULT
cast call "$STRAT" 'proposer()(address)' --rpc-url "$PUB"        # == $REBALANCER
cast call "$VAULT" 'strategy()(address)' --rpc-url "$PUB"        # == $STRAT
cast call "$VAULT" 'owner()(address)'    --rpc-url "$PUB"        # == $MULTISIG
cast call "$VAULT" 'asset()(address)'    --rpc-url "$PUB"        # == $USDC
cast call "$VAULT" 'decimals()(uint8)'   --rpc-url "$PUB"        # 12
cast call "$VAULT" 'totalSupply()(uint256)' --rpc-url "$PUB"     # == SEED * 1e6 (genesis mint)
```

**Account layer (after Phase C):**

```bash
cast call "$REG" 'whitelistedImplementations(address)(bool)' "$IMPL"      --rpc-url "$PUB"  # true
cast call "$REG" 'implementationToId(address)(uint256)'      "$IMPL"      --rpc-url "$PUB"  # 5
cast call "$REG" 'latestImplementationById(uint256)(address)' 5           --rpc-url "$PUB"  # == $IMPL
BR=$(cast call "$REG" 'BACKEND_ROLE()(bytes32)' --rpc-url "$PUB")
cast call "$REG" 'hasRole(bytes32,address)(bool)' "$BR" "$FACTORY"        --rpc-url "$PUB"  # true
cast call "$VAULT"   'depositsOpen()(bool)'                               --rpc-url "$PUB"  # true
cast call "$FACTORY" 'strategyTypeId()(uint256)'                          --rpc-url "$PUB"  # 5
cast call "$FACTORY" 'leveragedAeroStrategy()(address)'                   --rpc-url "$PUB"  # == $STRAT
cast call "$FACTORY" 'usdc()(address)'                                    --rpc-url "$PUB"  # == $USDC
```

**End-to-end account (spot-check a created account `$ACCT`):**

```bash
cast call "$REG"  'isUserStrategy(address,address)(bool)' "$USER" "$ACCT" --rpc-url "$PUB"  # true
cast call "$ACCT" 'owner()(address)'                                     --rpc-url "$PUB"  # == $USER
cast call "$ACCT" 'sharesBalance()(uint256)'                             --rpc-url "$PUB"  # 0 after full withdraw
cast call "$USDC" 'balanceOf(address)(uint256)' "$ACCT"                  --rpc-url "$PUB"  # 0 clean state
```

---

## Rebalance-cycle testing on the vnet (time-warp procedure)

Phase B stands the book up; it cannot prove the **harvest** path. At the fork block the CL position has
just been minted, so `gauge.earned() == 0` and `compound()` is a no-op no matter what you pass it.
Getting real accrued AERO needs a time warp — and on a Base fork that is only safe because of the
FreshFeed pattern (constraint 2). Everything below is driven by one in-repo helper, which resolves
every address from `script/tenderly/leveraged-aero-vnet.json` and pins the **48-field** `layout()`
signature — if `snap` / `calm` print blanks, the recorded clone predates the fee-model swap (see the
⚠ note at the end of B.6):

```bash
# admin (write-capable) RPC for THE leveraged-aero instance — NOT the shared TENDERLY_VNET_RPC_URL,
# which points at the LPV2 vnet. Get it from 1Password; it is deliberately never committed to this repo
# (the config file records only the public RPC). The helper prefers this var and resolves every address
# from script/tenderly/leveraged-aero-vnet.json.
export LEVERAGED_AERO_ADMIN_RPC_URL="https://virtual.base.<...>.rpc.tenderly.co/<admin-uuid>"   # 1Password

./script/tenderly/compound-cycle.sh check-feeds   # ← the gate. Run it BEFORE and AFTER every warp.
./script/tenderly/compound-cycle.sh snap T0
./script/tenderly/compound-cycle.sh gauge         # are emissions armed at all?
./script/tenderly/compound-cycle.sh arm           # voter.distribute([gauge]) — permissionless
./script/tenderly/compound-cycle.sh warp-to-finish
./script/tenderly/compound-cycle.sh quote         # derives minUsdcOut
./script/tenderly/compound-cycle.sh compound <minUsdcOut> <minLiquidity>
./script/tenderly/compound-cycle.sh snap T3
```

> **Warping is safe HERE, and only here, because of FreshFeed.** The 5 venue feeds (leg A/USD, leg
> B/USD, USDC/USD, AERO/USD, L2 sequencer uptime) are `FreshFeed` mocks whose `updatedAt` is
> `block.timestamp - 60`, so freshness is clock-independent. `check-feeds` is the executable form of
> that claim: it reads all 5 `latestRoundData()` and asserts `head - updatedAt <= maxDelay`
> (`172800` s on the live clone). **On an instance WITHOUT the FreshFeed code-replacement, warping
> bricks the fund** — the frozen forked answers go stale and every priced path
> (`nav()`, `deposit`, `redeem`, `compound`, `deployIdle`'s health assert) fail-closes with
> `StaleOracle`. There is no repair short of re-running phase B.0. Treat a red `check-feeds` as
> "do not warp", not as "warp and see".
>
> `check-feeds` also catches the commonest operator error: pointing the helper at the wrong vnet. A
> non-FreshFeed instance fails the gate instantly (observed 2026-07-29 — the stale
> `TENDERLY_VNET_RPC_URL` in `.env` resolved to the LPV2 vnet and every feed came back empty).

> **Warping a SHARED instance is a side effect everyone else sees.** The clock only moves forward,
> Moonwell interest is realized against it, and any FE/BE session on the same vnet will see the jump.
> It is **currently sanctioned** because no integration work is live on this instance yet. Once FE/BE
> are wired up, warping needs an owner's sign-off or its own throwaway instance. Record the total
> warp in the run log; the live clone was already ~5 d ahead of real time before this procedure and
> ~14 d after it.

### The blocker nobody expects: gauge emissions are not armed

A Base fork inherits the Slipstream pool's reward accounting frozen at the fork block, and **nothing
on a vnet ever runs Aerodrome's weekly epoch flip**. Once the clock passes the inherited
`periodFinish`, gauge accrual is permanently zero and *more* warping accrues *nothing*:

```bash
cast call "$POOL" 'periodFinish()(uint256)'   --rpc-url "$RPC"   # < head  → dead
cast call "$POOL" 'rewardReserve()(uint256)'  --rpc-url "$RPC"   # 0       → dead
```

Re-arm it the **production** way rather than faking a balance — `Voter.distribute(address[])` is
permissionless and internally does `minter.updatePeriod()` (mints the week) →
`gauge.notifyRewardAmount(claimable)` (sets `rewardReserve`, `rewardRate`, and
`periodFinish = epochNext(now)`). No impersonation, no minted AERO, real weights, real amounts:

```bash
./script/tenderly/compound-cycle.sh arm
```

> **Order matters.** `notifyRewardAmount` spreads the whole week's allocation over
> `epochNext(now) - now`, so arming mid-epoch compresses a week of emissions into the remaining
> hours and makes any APR you compute from the warp duration nonsense. Warp **past the next Thursday
> 00:00 UTC epoch boundary first**, then `arm`, then `warp-to-finish`. That gives a clean
> "≈7 days of warp == exactly one epoch of emissions" window. `arm` is idempotent per epoch — a
> second call in the same epoch distributes nothing.

### Deriving `minUsdcOut` (and the `ZeroMinOut` trap)

> **`compound(0, …)` always reverts `ZeroMinOut()` — `0x2870c094`.** The check sits *before* the
> zero-AERO early return (`LeveragedAeroManager.sol` step 1 vs the `aeroBal == 0` return), so even a
> deliberate no-op harvest must pass a nonzero floor. Use `1` when you only want to poke the path.

`compound` enforces `max(minUsdcOut, oracleFloor)` on the realized fill — **both priced on the
POST-SKIM sell amount**, because the `compoundFeeBps` tranche leaves as AERO before the swap:

```
sellAmt     = aeroBal − aeroBal × compoundFeeBps / 10000             # AERO 18dp, skim rounds DOWN
fair6       = sellAmt × AERO/USD(8dp) / USDC/USD(8dp) / 1e12         # USDC 6dp — the peg leg is real
oracleFloor = fair6 × (10000 − maxSlippageBps) / 10000               # BelowOracleFloor bound
```

`compound-cycle.sh quote` prints `fair6`, `oracleFloor`, and the venue's actual
`router.getAmountsOut` for the same amount, then suggests `max(oracleFloor, quote × 0.995)` — i.e.
tighten the proposer bound onto the live quote rather than relying on the 1 % oracle band. All three
are already **net of the skim** — the script reads `compoundFeeBps` (`lay 29`) and quotes `sellAmt`,
so `SUGGESTED minUsdcOut` is usable as printed. Its `fair6` still omits the peg leg, so it
approximates `oracleFloor` rather than reproducing it; the printed floor is the one to trust near the
band edge.

> Two revert paths that are easy to confuse:
> - An **absurdly high `minUsdcOut` does NOT test `BelowOracleFloor`.** `minUsdcOut` is forwarded to
>   the Aerodrome v2 router, whose own guard fires first: `InsufficientOutputAmount()` —
>   `0x42301c23`.
> - `BelowOracleFloor()` — `0xc872b206` — needs the *venue* to fill below the *oracle* band, which
>   you cannot induce with call arguments. Probe it with a **zero-side-effect `eth_call`** that
>   overrides the AERO/USD feed's code with another FreshFeed carrying a much higher answer:
>   ```bash
>   CODE=$(cast code "$LEGA_FEED" --rpc-url "$RPC")           # cbBTC/USD FreshFeed: answer 6514631800000
>   cast call --from "$PROPOSER" --override-code "$AERO_FEED:$CODE" \
>     "$STRAT" 'compound(uint256,uint256)' 1 0 --rpc-url "$RPC"   # → 0xc872b206
>   ```

### What to assert after a `compound`

| # | Assertion | How |
|---|---|---|
| 1 | all 5 feeds still fresh | `check-feeds` (green before *and* after the warp) |
| 2 | AERO was claimed | `gauge.earned` → `0`; a gauge→strategy AERO `Transfer` in the receipt |
| 3 | AERO was swapped, not stranded | strategy AERO balance `0`; pool→strategy USDC `Transfer` = `usdcOut` |
| 4 | fill beat both bounds | `usdcOut ≥ minUsdcOut` **and** `≥ oracleFloor` (no `0xc872b206`) |
| 5 | realized vs oracle price | `usdcOut / (aeroClaimed − skim)` vs the feed answer — expect ≈ venue fee ± pool basis. Divide by the **post-skim** amount; using `aeroClaimed` reads as `compoundFeeBps` of extra slippage |
| 6 | yield was redeployed | `supply` + `borrow` + pool `Mint` legs in the receipt; NPM `liquidity` up |
| 7 | NFT still staked, same `tokenId` | `gauge.stakedContains` `true`; `tokenId` unchanged (this is `increaseLiquidity`, not a re-mint — only `rerange` mints a new id) |
| 8 | `nav()` does **not** step across the compound | the pending claim was already marked (net of the skim) in `nav()`'s reward term, so the harvest only *realizes* it. The delta is the realized Moonwell carry plus the small venue-fill-vs-oracle-mark basis — **not** `usdcOut` (see the decomposition note below) |
| 9 | the skim was paid, in kind | `feeRecipient` AERO balance up by exactly `aeroClaimed × compoundFeeBps / 10000` (floor), and exactly one `RewardFeePaid(recipient, aeroAmount)` log from the **strategy** address (the manager is delegatecalled). `vault.totalSupply()` **unchanged** — nothing mints |
| 10 | delta-neutrality | LP leg-A amount vs leg-A debt (expect a small short by the *accrued borrow interest* — see below) |
| 11 | LTV | moves **toward the stored `targetLtvBps`**, not toward the book's current LTV |

> **`vault.totalSupply()` moves on deposit and redeem — and on nothing else.** There are no fee-share
> mints any longer (the fund's only fee is the in-kind AERO skim), so a supply delta with no
> corresponding deposit or redeem in the same window is a **red flag**, not fee accrual. Reconcile it
> against the vault's `Transfer` logs before assuming anything.

> **`nav()` lags Moonwell interest until something touches the market.** `nav()` reads
> `borrowBalanceStored` / the stored exchange rate, so a 9-day warp shows **zero** NAV change from the
> carry until a tx accrues. `compound`'s supply+borrow does accrue, so the NAV jump you measure is the
> whole warp's carry at once — the **harvest is not in that jump**, because `nav()`'s reward term had
> already been marking the pending claim (net of the skim) as it accrued. To see the carry alone before
> compounding, read the accruing getters by `eth_call` — `mUSDC.balanceOfUnderlying(strategy)` and
> `mLegA.borrowBalanceCurrent(strategy)` are non-view and therefore simulate accrual.

### Live results — 2026-07-29 on clone `0x7A5A…01Fd` / vault `0x8BcA…B0F5` (since superseded)

> **Historical record, kept for the measurements.** That clone/vault pair has been replaced twice since;
> the current pair is `0x3393…9c3c` / `0x0B0E…d6f1` (see *Current live instance* below, and
> `script/tenderly/leveraged-aero-vnet.json`, which is authoritative). The harvest/swap/redeploy
> mechanics below still hold — only the addresses moved.
>
> **2026-08-31 — every fee reading in this section records the RETIRED management/performance fee
> model.** That layer (`LeveragedAeroFees`, the high-water mark, the crystallise machinery and its
> fee-share mints) is **deleted**. The fund's only fee is now a single in-kind skim: `compoundFeeBps`
> (500 = 5 %, cap 1000) of each AERO tranche the fund realizes — `compound`, `flatten` and the
> async-redeem fulfilment, everything but the terminal `settle` — transferred to `feeRecipient`
> **pre-swap** and logged as `RewardFeePaid`. Read the numbers below as history; read *What to assert after a
> `compound`* above for current behaviour.

Asset-mode cbBTC/USDC clone, `state() == 1`, proposer `0x73f6…8FAf`, tokenId `73341624`,
`targetLtvBps 5000`, `maxSlippageBps 100`, and the retired fee config `managementFeeBps 100` /
`performanceFeeBps 1000` (both fields gone — see the note above).

> **Retired-model rows (2026-08-31).** The last three rows — `feeRecipient` shares, `hwmPerShare`,
> `lastFeeAccrualTimestamp` — measured the old crystallise layer. `hwmPerShare` and
> `lastFeeAccrualTimestamp` are **gone from `Layout`**; do not go looking for them on a current clone
> (`layout()` is 48 fields, `compoundFeeBps` at 29 / `feeRecipient` at 30). `feeRecipient` survives,
> but what accrues to it is now **AERO**, not shares — the `totalSupply` row would be flat today.

| Metric (6dp USDC / 12dp shares unless noted) | T0 pre-warp | T2 post-warp, pre-compound | T3 post-`compound` | T4 post 2nd `compound` |
|---|---|---|---|---|
| head timestamp | `1785787243` | `1786579343` | `1786579597` | `1786579818` |
| feed lag (all 5) | `60 s` | `60 s` | `60 s` | `60 s` |
| `nav()` | `162000007892` | `162000007892` | `162385919143` | `162385919143` |
| `gauge.earned` (AERO wei) | `0` | `703124673914631803080` | `0` | `0` |
| strategy AERO | `0` | `0` | `0` | `0` |
| idle USDC | `2122005703` | `2122005703` | `2122005813` | `2122005813` |
| collateral / debt (USD) | `100134099996` / `60082539479` | idem | `100435461575` / `60198901805` | idem |
| leg-A debt (cbBTC sats) | `92208022` | `92208022` | `92386602` | `92386602` |
| LP liquidity | `32484548216` | `32484548216` | `32539014655` | `32539014655` |
| LP leg-A (cbBTC sats) | `92207993` | `92207993` | `92362597` | `92362597` |
| LTV (bps) | `6000.21` | `6000.21` | `5993.79` | `5993.79` |
| `vault.totalSupply()` | `162000068997039915` | idem | `162040953045528785` | `162075394597995434` |
| `feeRecipient` shares | `61241094234` | idem | `40945289583104` | `75386842049753` |
| `hwmPerShare` | `1000000027415` | idem | `1000000027415` | `1002128882180` |
| `lastFeeAccrualTimestamp` | `1785783922` | idem | `1786579597` | `1786579818` |

Mechanics and transactions:

| Step | Detail |
|---|---|
| warp 1 | `evm_increaseTime` `+187321 s` (2.17 d) — cross the epoch boundary `1785974400` |
| `arm` | `0xbf47ac31a2f362e40f21ea22e7a4230526ab16edc65c4a2aca9eef06b277bac9` · gas `582672` · notified **59 233.496977 AERO**, `periodFinish 1786579200`, `rewardRate 98025695641991250` |
| warp 2 | `evm_increaseTime` `+604408 s` (6.995 d) — to `periodFinish`; total warp `791729 s` ≈ 9.16 d |
| `compound` | `0x08395cad259a238b83afdc56c1a4c129cd9fd591314466768d67d7f4a6169615` · gas `1620482` · args `(300101811, 0)` |
| 2nd `compound` | `0x71461db86d30b14cdbcf6692d38a628f823957b9c84ba13e68e0350b1e5d6c10` · gas `393372` · args `(1, 0)` |

Swap, bound, and price (the whole point of the exercise):

| Quantity | Value |
|---|---|
| AERO claimed | `703124673914631803080` = **703.124674 AERO** (1.187039 % of the gauge's epoch) |
| USDC realized | `301609861` = **301.609861 USDC** — matched `getAmountsOut` to the unit |
| effective price | **$0.42895645** / AERO |
| oracle price (frozen FreshFeed) | **$0.42977212** / AERO |
| realized slippage vs oracle | **18.98 bps** = 30 bps Aerodrome v2 volatile fee − 11 bps pool-above-oracle basis |
| on-chain `fair6` | `302183381` |
| `oracleFloor` (1 % band) | `299161547` — realized fill cleared it by **0.8184 %**, no `BelowOracleFloor` |
| proposer `minUsdcOut` | `300101811` = `quote × 0.995`, i.e. **tighter than** the contract's own floor |
| redeploy split | supplied `201437848` USDC → borrowed `154604` sats → LP add `100171903` USDC + `154604` sats; `110` left idle |

Fee crystallisation reconciles to the wei:

> **RETIRED MODEL — measured record only (annotated 2026-08-31).** This table verifies the deleted
> management/performance fee layer. Nothing in it describes a current clone: there is no
> crystallisation, no HWM, no fee-share mint and no `A·supply/(nav−A)` identity to check. The
> replacement is the in-kind `compoundFeeBps` AERO skim; assert it per row 9 of *What to assert after
> a `compound`* above.

| | `compound` #1 | `compound` #2 |
|---|---|---|
| management fee | `$40.873718` = 1 %/yr × 9.20920 d × pre-NAV `162000.007892` | `$0.011380` (221 s) |
| performance fee | **`$0` — deferred.** `navPerShare` pre-compound `999999622809` < `hwmPerShare` `1000000027415` | `$34.496166` = 10 % × `$344.961655` above HWM |
| shares minted | `40884048488870` | `34441552466649` |
| minted == `feeRecipient` delta | yes (all fee shares, nothing to holders) | yes |
| `A·supply/(nav − A)` check | exact match at `A = 40873718` | `$34.507545` predicted vs `$34.507540` minted-share value (5e-6 rounding) |

Yield decomposition over the cycle:

| Component | USDC | Annualised |
|---|---|---|
| AERO harvest redeployed | `+301.609861` | **9.7165 %** over the 6.99381 d armed emission window |
| net Moonwell carry realized by the accrual | `+84.301390` | 2.0625 % over the 9.20920 d warp |
| **`nav()` delta** | **`+385.911251`** | 9.4416 % |
| per-share, net of the 1 % management fee | `999999622809 → 1002128882181` (+0.212926 %) | 8.4392 % |

Behaviours worth knowing (observed, **not** defects to fix from this runbook):

1. **`compound` does not re-hedge accrued borrow interest.** It hedges only the *new* borrow, so the
   realized leg-A interest lands in the debt unhedged. Here the LP went from `−29` sats vs debt to
   `−24005` sats (`−$15.64`) — exactly the `23976` sats of cbBTC interest the tx accrued. The drift is
   proportional to `debt × borrowAPY × time` and **accumulates across harvests**; nothing in
   `compound` / `rerange` removes it (only a `deposit`/`adjustLeverage` resize does).
2. **The redeploy sizes at the *stored* `targetLtvBps`, not the book's current LTV.** With the book at
   6000 bps and `targetLtvBps == 5000`, the `201.44` USDC increment was levered at exactly 50.00 %,
   nudging LTV `6000.21 → 5993.79` bps. Expect harvests to walk LTV toward `targetLtvBps` forever.
3. **A no-AERO `compound` is a clean no-op** (current behaviour — run #2 above measured the retired
   model, where it still crystallised). `compoundImpl` returns at `aeroBal == 0`, and the sub-micro-USD
   dust case returns at `floor == 0` — *ahead* of the skim, deliberately, so a dust balance donated to
   a dead gauge cannot be drained a cent at a time. Nothing is paid, nothing is minted, nothing moves.
4. **A `compound` WITH AERO pays exactly one fee, in kind, up front.** `compoundFeeBps` of the tranche
   (rounding down) is transferred to `feeRecipient` as **AERO** before the swap, logged
   `RewardFeePaid(recipient, aeroAmount)` from the strategy address; both `minUsdcOut` and the oracle
   floor then price only the remainder. **Nothing is ever deferred** — there is no HWM to wait for and
   no next accrual point. And `nav()` does **not step** across the harvest: the reward term already
   marks the pending `gauge.earned()` net of the skim, which is what closes the exit-timing arb (a
   redeemer leaving just before a harvest pays their pro-rata share of the pending fee instead of
   dodging it). `flatten` and the async-redeem fulfilment skim on the SAME basis, through
   `LeveragedAeroVenue._sellRewardBalance`: their own `gauge.withdraw` is all-or-nothing per NFT, so each
   realizes 100 % of the book's accrual and leaves no later harvest to charge it. Assert row 9 on those
   two as well. The one accepted asymmetry runs in holders' favour: the **terminal** `settle` sells the
   tranche gross, so the fund's last exit realizes slightly more than the mark.

Could not be verified on this instance: nothing in the harvest path. `BelowOracleFloor` was proven
only by `eth_call` state override (a genuine venue dislocation > `maxSlippageBps` cannot be induced
without moving the AERO/USDC pool, which is a large, shared side effect).

---

## Current live instance — vault generation 3 (audited build)

> **This instance carries the AUDITED build**, redeployed **2026-08-25** by Phase B + Phase C above from
> branch `aero-audit-2` (head `6d25f5f`, PRs #84/#85/#86/#87): the audit remediations plus the post-audit target-LTV refactor —
> `lowerTargetLtv` removed, `adjustLeverage(uint16 targetBps, uint256, uint256)` (`0x9792419f`) bounded by
> the stored `targetLtvBps` and never persisted. The strategy template, `LeveragedAeroVault` and the
> `LeveragedAerodromeCLStrategy` clone all carry it, and the account layer was redeployed on top of them.
> Verified on the 2026-08-18 clone (not re-measured on the 2026-08-25 clone): `adjustLeverage(5001,…)` reverts
> `TargetLtvExceedsPolicy(5001, 5000)`, and a 5000 → 4000 → 5000 round trip moved leg debt
> 51,959,105 → 40,028,007 → 50,036,587 with `targetLtvBps()` unchanged at 5000 throughout. Both harnesses finished green end
> to end. No `SyndicateVault`, no governor, no proposal lifecycle — the getter is `depositsOpen()` and
> the post-settlement exit is the permissionless `redeemSettled(shares)`.
>
> **Generation 3 is what "audited" means here, mechanically.** The vault now exposes
> `maxTotalAssets()` / `remainingCapacity()`, and the strategy makes a **typed** call to
> `maxTotalAssets()` inside its fund-capacity check on every deposit. The vault is not upgradeable, so a
> current strategy bound to a generation-2 vault would revert on every deposit with empty returndata —
> which is why the account harness probes that selector and refuses to run below generation 3, and why a
> pooled redeploy always forces an account redeploy.
>
> **`script/tenderly/leveraged-aero-vnet.json` is authoritative**; this table is the human copy and can
> lag it. Re-run both harnesses after any refresh and re-read the config before wiring anything.
>
> **Never commit the admin RPC.** It is write-capable (unlocked impersonation of every privileged role,
> `tenderly_setCode`, `tenderly_setErc20Balance`, time warps). It lives in **1Password** only — the config
> file records the string `"1Password (write-capable — never committed)"` in `adminRpc` for exactly this
> reason. Only the **public** RPC may appear in docs.

| Field | Value | Config key |
|---|---|---|
| vnet id | `769bfec9-e868-4f87-b6f7-ad3584e86eb3` (slug `mamo-leveraged-aero-pr66-1786640530`) | `vnetSlug` |
| chainId | `73578453` — **custom** (`7357` prefix + parent 8453); harness runs need `EXPECTED_CHAIN=73578453`, forge needs `addresses/73578453.json` | `chainId` |
| parent network | Base (`8453`) — fork state is Base; all venue addresses resolve unchanged | `parentNetworkId` |
| fork block | `49,925,592` (instance created 2026-08-13; stack redeployed 2026-08-25 from `aero-audit-2` head `6d25f5f`) | — |
| **Admin RPC** (writes) | **1Password** — write-capable, never committed | `adminRpc` |
| Public RPC (reads) | `https://virtual.base.eu.rpc.tenderly.co/b5ec5ea9-e5ea-4e06-a9a6-21310065d282` | `publicRpc` |
| State sync | `false` — deliberate (constraint 3), not an API limit | `stateSync` |
| Vault generation | `3` — `leveraged-aero-vault` (`depositsOpen()`, `cloneAndBind`, `redeemSettled`, **`maxTotalAssets()` / `remainingCapacity()`**) | `vaultGeneration` |
| Vault (`LeveragedAeroVault`) | `0x461BdB37099A30dD5242F7216B440Fcc1C38b9cC` | `pooled.vault` |
| Strategy clone (operator target) | `0xf72Dd040A1af43e25C3f1B330F5fbc7b909e8008` — width `4000` raw ticks, band `[200, 20000]`; skew `5000` (centered), band `[1000, 9000]` | `pooled.strategyClone` |
| Strategy template (clone source) | `0xE559268df385ca2bb1A2649C109df0a8186CF56d` | `pooled.template` |
| Strategy `proposer` (`MAMO_REBALANCER`, **not** `MAMO_BACKEND`) | `0x73f6B456d063F78129113D42DBC315b9eEee8FAf` | `pooled.proposer` |
| LP pool (Slipstream, tickSpacing 100; **asset-mode cbBTC/USDC**) | `0x4e962BB3889Bf030368F56810A9c96B83CB3E778` | `pooled.lpPool` |
| LP gauge | `0x6399ed6725cC163D019aA64FF55b22149D7179A8` | `pooled.lpGauge` |
| ⚠️ venue shape | **Asset mode** as deployed 2026-08-25 (`legBIsAsset=true`, cbBTC/USDC): one borrowed leg LP'd against the fund's own USDC. Deploy-time manifest fields do **not** follow a `migrateVenue` — read `layout()` on the clone. | `pooled.venueShape` |
| Seed | `100000000000` = 100,000 USDC (6dp) | `pooled.seed` |
| Mamo account impl | `0x0EE12E97Fe2b176dB30A00bcE0cDe2699b7F4b8f` | `mamo.accountImplementation` |
| Mamo account factory (typeId 5, latest) | `0x70707eb4337FAB8043ea737Fa16a14A90Ad1C440` | `mamo.accountFactory` |
| Mamo strategy registry | `0x46a5624C2ba92c08aBA4B206297052EDf14baa92` | `mamo.strategyRegistry` |
| Strategy type id | `5` | `strategyTypeId` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `usdc` |

FreshFeed-overridden venue feeds (mainnet addresses, code-replaced per B.0 — `updatedAt` tracks
`block.timestamp`, so they are never stale and warping is safe):

| Feed | Address | Config key |
|---|---|---|
| leg A / USD (cbBTC) | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` | `feeds.legAUsd` |
| leg B / USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | `feeds.legBUsd` |
| USDC / USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | `feeds.usdcUsd` |
| AERO / USD | `0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0` | `feeds.aeroUsd` |
| L2 sequencer uptime | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` | `feeds.sequencerUptime` |

### Funding test wallets (FE/BE/QA)

`script/tenderly/fund-address.sh` sets balances via the **Admin RPC** cheat methods
(`tenderly_setBalance` / `tenderly_setErc20Balance` — they SET, not add; no whale needed; any ERC20
works). One wallet per invocation; amounts are human units and decimals are read from the token:

```bash
# one wallet: gas + spending USDC
./script/tenderly/fund-address.sh 0xWALLET --eth 10 --usdc 25000 --rpc-url "$ADMIN_RPC"

# a batch
for w in 0xWALLET1 0xWALLET2 0xWALLET3; do
  ./script/tenderly/fund-address.sh "$w" --eth 10 --usdc 25000 --rpc-url "$ADMIN_RPC"
done

# any other token (e.g. cbBTC)
./script/tenderly/fund-address.sh 0xWALLET --erc20 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf 0.5 --rpc-url "$ADMIN_RPC"
```

Two rules: **check what `TENDERLY_VNET_RPC_URL` resolves to before relying on the fallback**, and get the
Admin RPC from 1Password — the public RPC cannot fund (cheat methods are admin-only). The script verifies
by reading the balance back after each set.

On the RPC: the script uses `--rpc-url`, else `$TENDERLY_VNET_RPC_URL`, else `.env`. That variable has
historically pointed at an *unrelated* vnet, so passing `--rpc-url` explicitly is the safe habit. Since
2026-08-18 it points at THIS instance's Admin RPC, which is why the batch below runs without the flag.
**One-line check before any batch — it must print `73578453`:**

```bash
cast chain-id --rpc-url "$TENDERLY_VNET_RPC_URL"   # 73578453 = this instance; 8453 = the wrong one
```

### Deliberate history — retired, do not target

Kept only so old logs and links resolve. **None of these is part of the current stack** — the live one is
the generation-3 table above. The last three rows are Sherwood-era (vault generation 1: `openDeposits()`,
no `redeemSettled`, governor-driven lifecycle).

| Retired | Address | Note |
|---|---|---|
| Generation-3 stack on the CURRENT instance (2026-08-18) | vault `0x8D2F1117…1E59`, clone `0x01BF6061…87F1`, template `0x92b37B73…2FB9`, impl `0xC68F1419…8bf9`, factory `0x3E130404…F20b` | the `dd9dfdd` deploy, later `migrateVenue`'d to twoleg WETH/cbBTC; superseded 2026-08-25 by the `6d25f5f` asset-mode stack. Still live on the instance — do not target it |
| Generation-3 stack on the CURRENT instance (2026-08-17) | vault `0x0B0ECF22…d6f1`, clone `0x339373E8…9c3c`, template `0x5B33a965…cdA0`, impl `0x9703a770…0E24`, factory `0x46108914…003E` | the first audited-build deploy; superseded 2026-08-18 by the `adjustLeverage` policy-bound refactor. Still live on the instance — do not target it |
| Generation-2 stack on the CURRENT instance | vault `0xC0e7a3fF…727e`, clone `0x0039e435…41E2`, template `0xEA05B89C…5425`, impl `0xd9Fc69ff…CaD1`, factory `0x00247273…4523` | the 2026-08-13 deploy from PR #66 head `d347b68`, superseded 2026-08-17 by the audited generation-3 stack. Its vault predates `maxTotalAssets()`, so a current strategy bound to it reverts on every deposit with empty returndata — the account harness's generation probe exists to catch exactly this. Per the redeploy-hygiene note in Phase C the retired impl is **still whitelisted** and the retired factory **still holds `BACKEND_ROLE`**; `latestImplementationById(5)` routes to the new pair, so this is cosmetic on a vnet |
| Previous vnet instance (chainId `8453`) | vnet `8975a20b-5cf0-4399-9165-08e2b19229db`, public RPC `…/70a4990f-6686-4536-8237-ad9103acd11b` | superseded 2026-08-13 by the `73578453` custom-chain-id instance; still running, not deleted. Its stack: vault `0x8343b356…22D7`, clone `0xA26557fA…49da`, template `0xafcA85Df…8943`, impl `0xC68F1419…8bf9`, factory `0x3E130404…F20b` |
| Attempt-1 pair on the CURRENT instance | impl `0x30fA6E5648bDa78c905dad6f0F5394148aD171DA`, factory `0xbad3b205893F8D729C54A79EB0421232950D27a0` | a failed first account-harness attempt left the impl **still whitelisted** (type 5) and the factory **still holding `BACKEND_ROLE`** — `latestImplementationById(5)` routes correctly, so harmless here, but do not target them |
| Sherwood `SyndicateVault` | `0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9` | replaced by `LeveragedAeroVault` |
| `SyndicateGovernor` | `0x430FA5659cCf6E9c1586007a0A2B7760fb75e105` | no longer part of the stack (PR #66) |
| Sherwood-era clone | `0x168ac730AB0DA6FCDE8aA26e33eac4aE6c8CfB4B` | `Settled` — historical `Settled`-state reference only |
