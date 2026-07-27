# Leveraged-Aero vnet runbook — stand up & e2e-verify the full stack

A repeatable procedure for standing up a **fresh Tenderly Base-fork Virtual TestNet** carrying the
complete leveraged-Aerodrome stack and end-to-end verifying it. Run this on staging refreshes and
pre-mainnet rehearsals.

The stack is **two layers, both in this repo**:

| Layer | Contracts | Who drives it |
|---|---|---|
| **Pooled** | `LeveragedAeroVault` (share ERC-20 + lifecycle driver) + one `LeveragedAerodromeCLStrategy` ERC-1167 clone | vault owner = `MAMO_MULTISIG`; position operator = the strategy's `proposer` (`MAMO_BACKEND`) |
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
>   `ISyndicateVault` is down to three functions.
> - The strategy lifecycle is **owner-driven**: `Pending → Executed → Settled` via
>   `vault.activateStrategy(seed)` and `vault.settleStrategy()`. The `proposer` role **survives** for
>   the tunable-params / operator surface (`onlyProposer`, `state()` unchanged).
> - Paths and type names under `src/leveraged-aero/sherwood/` are preserved **only** so the vendored
>   strategy's imports still compile. They are shims. Nothing calls Sherwood.
> - The post-settlement exit is the vault's **permissionless** `redeemSettled(shares)`.
> - The strategy now initializes against **any** Aerodrome Slipstream pool, and `rerange` is in-repo.

---

## Actors & canonical addresses (Base mainnet / fork-native)

These resolve identically on real Base and on any correctly-forked vnet (chainId 8453). Mamo values
come from `addresses/8453.json`.

| Role | Key | Address |
|---|---|---|
| Mamo multisig (registry admin / **vault owner**) | `MAMO_MULTISIG` | `0x26c158A4CD56d148c554190A95A921d90F00C160` |
| Mamo backend (operator / strategy `proposer`) | `MAMO_BACKEND` | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` |
| Deployer EOA | `DEPLOYER_EOA` | `0xDca82E03057329f53Ed4173429D46B0511E46Fb8` |
| Mamo strategy registry | `MAMO_STRATEGY_REGISTRY` | `0x46a5624C2ba92c08aBA4B206297052EDf14baa92` |
| USDC | `USDC` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Two keys are **created by this runbook** and are deliberately **not** committed to
`addresses/8453.json` (see the address-resolution note in Phase C):

| Key | What it points at |
|---|---|
| `LEVERAGED_AERO_VAULT` | the `LeveragedAeroVault` from Phase B |
| `SHERWOOD_LEVERAGED_AERO_STRATEGY` | the `LeveragedAerodromeCLStrategy` clone from Phase B |

> **Stale-but-real naming.** `config/strategies/LeveragedAeroAccountConfig.json` still calls the
> strategy key `sherwoodStrategy` / `SHERWOOD_LEVERAGED_AERO_STRATEGY`, and the factory getter is
> `factory.sherwoodStrategy()`. That is the live, current naming — use it verbatim or lookups fail.
> Renaming it to `LEVERAGED_AERO_STRATEGY` is a **pending cleanup**; the `SHERWOOD_` prefix does not
> imply any remaining Sherwood dependency.

> On a vnet, all privileged roles are driven by **unlocked impersonation** through the admin RPC — no
> private keys. Throwaway EOAs are used only for simulated end users.

---

## Hard constraints (read before every run)

> 1. **chainId 8453 only.** Mamo's FPS `Addresses` book keys off `block.chainid`, and a matching chain
>    id keeps real Base addresses (USDC, Moonwell, Aerodrome, Chainlink feeds) fork-native. A different
>    chain id breaks address resolution and the whole harness.
> 2. **Feed freshness is solved by the FreshFeed pattern.** On a raw Base fork the forked Chainlink
>    answers are frozen, so `updatedAt` recedes as the clock advances and every priced path bricks with
>    `StaleOracle` in ~1 day (`maxDelay` is an init param, bounded to `(0, 7 days]`). The fix is
>    to **code-replace the 5 venue feeds** (leg A/USD, leg B/USD, USDC/USD, AERO/USD, L2
>    sequencer-uptime) with `FreshFeed` mocks whose `updatedAt` tracks `block.timestamp`, via
>    `tenderly_setCode`. Feeds are then permanently fresh, prices frozen-but-movable, and time-warping
>    is safe. Verified live 2026-07-26 on the Sherwood-era instance (clock +5 days, feed lag 60 s, full
>    e2e green). **This recipe used to ship with the Sherwood deploy script and now has no in-repo
>    implementation — see the tooling gap in Phase B.0. It is not optional: without it the instance is
>    dead in about a day.**
> 3. **State sync stays OFF.** It is a creation-time-only flag (API-verified 2026-07-26), so this is
>    locked when you create the vnet — get it right. Two reasons, and note that the *old* reason has
>    changed: with the governance warp gone the vnet clock no longer runs days ahead of real time, so
>    "state-synced mainnet timestamps would read as days-stale" is **no longer** the argument. What
>    holds now: (a) it is **unnecessary** — FreshFeed already makes freshness clock-independent; and
>    (b) it is **actively hostile to FreshFeed** — the fix is a code override on *mainnet* feed
>    addresses, exactly the accounts a state-syncing vnet re-hydrates from the parent network, which
>    would silently restore the real aggregators and bring the staleness treadmill back. Deployed
>    stack addresses are vnet-only and unaffected; the overridden feeds are the exposure.
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
- Virtual network chain id: **8453 — MANDATORY** (constraint 1).
- **State sync: DISABLED** (constraint 3 — creation-time-only, unnecessary, and it would undo the
  FreshFeed overrides).
- Explorer: optional.
- Persistence: **no auto-delete** (the pooled layer must survive across the multi-step deploy and all
  downstream FE/BE work).

Two ways to create it:

**(a) Tenderly dashboard** — New Virtual TestNet → fork Base → set the virtual chain id to `8453` →
persistent. Copy the **Admin RPC**, **Public RPC**, vnet id, and fork block.

**(b) Reuse the harness creation mechanism.** `script/tenderly/lib/common.sh` `resolve_vnet()` already
codifies the exact API call this repo uses (`POST …/vnets` with
`fork_config.network_id=8453` + `virtual_network_config.chain_config.chain_id=8453`,
`sync_state_config.enabled=false`). It reads creds from `.env`:

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
| **Admin RPC** | every write in Phases B and C; `TENDERLY_VNET_RPC_URL` (accepts `eth_sendTransaction` from any unlocked sender **and** serves reads) |
| Public RPC | read-only `cast` verification; the value published in `script/tenderly/leveraged-aero-vnet.json` |
| fork block | reproducibility |

---

## Phase B — pooled layer: vault + strategy clone (this repo)

> **TOOLING NOT YET WRITTEN — tracked gap.** `script/` contains only the **account-side**
> `LeveragedAeroAccountDeployer.s.sol` + `DeployLeveragedAeroAccountConfig.sol`. There is **no**
> in-repo script for the vault, the strategy template, the clone/init, the activation, or the
> FreshFeed overrides — that tooling died with the Sherwood repo dependency and has not been
> re-written here. Everything in this phase is therefore a **specification for the script that has to
> be built**, not a command you can run today. Do not invent filenames: nothing below exists yet.
> Steps B.0–B.5 are the required order; B.6 is the acceptance gate Phase C depends on.

Reference implementation contract for this phase: `docs/LEVERAGED_AERO_CL_AUDIT.md`, *Deploy flow*.

Shell variables used by the snippets below:

```bash
ADMIN="https://virtual.base.<...>.rpc.tenderly.co/<admin-uuid>"    # writes (unlocked impersonation)
PUB="https://virtual.base.<...>.rpc.tenderly.co/<public-uuid>"     # reads
MULTISIG=0x26c158A4CD56d148c554190A95A921d90F00C160                # MAMO_MULTISIG (vault owner)
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
VAULT=0x...        # from B.1
STRAT=0x...        # the clone from B.3
```

### B.0 — FreshFeed code-replacement (do this first, per constraint 2)

Replace the 5 venue Chainlink aggregators with `FreshFeed` mocks that return the forked answer but
report `updatedAt == block.timestamp`. What the script must do, per feed address:

1. Read the live aggregator's `decimals()`, `latestRoundData()` answer and `description()` off the
   fork.
2. Deploy (or precompute the runtime bytecode of) a `FreshFeed` that returns that frozen answer with
   `updatedAt = block.timestamp`, keeps `decimals()` identical (AERO/USD **must** stay 8dp — the
   strategy asserts `UnexpectedFeedDecimals` at init), and exposes a setter so the price can be moved
   for scenario tests.
3. `cast rpc tenderly_setCode '["<feedAddr>","0x<freshFeedRuntime>"]'` on the **admin** RPC, so the
   override lands at the *mainnet feed address* the strategy will be initialized with.
4. The **sequencer-uptime** feed is the same treatment but a different shape: `answer == 0` (up) and a
   `startedAt` far enough in the past to clear `gracePeriod`.

Feeds to cover: leg A/USD, leg B/USD, USDC/USD, AERO/USD, L2 sequencer uptime — i.e. exactly the five
`*Feed` members of `LeveragedAerodromeCLStrategy.InitParams`.

There is no `FreshFeed` contract in this repo yet either; it has to be written alongside the script.

### B.1 — deploy `LeveragedAeroVault`

`src/LeveragedAeroVault.sol`, constructor
`(address asset_, address owner_, string name_, string symbol_)`:

| Arg | Value |
|---|---|
| `asset_` | `USDC` (`0x8335…2913`) — must equal the strategy's unit of account or init reverts `AssetMismatch` |
| `owner_` | `MAMO_MULTISIG` |
| `name_` / `symbol_` | share-token metadata |

> **`decimals()` is derived, not stored: `asset.decimals() + 6` = 12dp for USDC.** Load-bearing — the
> strategy's genesis pricing uses a hardcoded `SHARES_VIRTUAL_OFFSET = 1e6`
> (`shares = assets × (supply + 1e6) / (nav + 1)`), which is exactly a 6-decimal step up from a 6dp
> asset. Any other offset makes the advertised denomination disagree with what the strategy mints.

State after deploy: `strategy == address(0)`, `depositsOpen == false`, `feeConfig == address(0)`
(**fees OFF at launch** — `factory()` returns `address(0)` and the strategy's fee lookup
short-circuits). Non-upgradeable by design.

### B.2 — multisig **accepts** vault ownership

The vault is `Ownable2Step`. `Ownable(owner_)` in the constructor makes `MAMO_MULTISIG` owner
immediately, so if you deploy with `owner_ = MAMO_MULTISIG` there is nothing to accept. **If you
instead deploy as `DEPLOYER_EOA` and hand off**, `transferOwnership(MAMO_MULTISIG)` only *nominates* —
the multisig must call `acceptOwnership()` or every `onlyOwner` path (including proposal 012's
`setOpenDeposits(true)`) reverts.

```bash
# only needed on the deploy-then-hand-off path
cast send "$VAULT" 'acceptOwnership()' --from "$MULTISIG" --unlocked --rpc-url "$ADMIN"
cast call "$VAULT" 'owner()(address)' --rpc-url "$PUB"          # == MAMO_MULTISIG
cast call "$VAULT" 'pendingOwner()(address)' --rpc-url "$PUB"   # == 0x0
```

Prefer `owner_ = MAMO_MULTISIG` in the constructor and skip the two-step entirely.

### B.3 — deploy the strategy template, clone it, and `initialize` **in one broadcast**

1. Deploy `LeveragedAerodromeCLStrategy` as a template. Its three libraries
   (`LeveragedAeroManager`, `LeveragedAeroValuation`, `LeveragedAeroFees`) have external functions and
   are `delegatecall`ed — a `forge script` broadcast deploys and links them automatically; a raw
   `cast` deploy does not. The template's constructor sets `_initialized = true`, permanently locking
   `initialize` on the template itself (ERC-1167 clones skip constructors, so clones stay
   initializable).
2. `Clones.clone(template)` → the clone address.
3. `clone.initialize(vault, proposer, abi.encode(InitParams))` with `proposer = MAMO_BACKEND`.

> **The clone is initializable by ANYONE between `clone` and `initialize`.** There is no template
> allowlist and no atomic `cloneAndInit` helper in this repo. The two calls **must** be in the same
> broadcast (one script tx / one contract), or the deploy must be re-checked by hand before use. The
> binding that actually protects holders is `vault.setStrategy` in B.4 — a clone someone else
> initialized against a different vault can never mint here.

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
  `minHealthBps × maxLtvBps < 1e8`, `maxDelay ∈ (0, 7 days]`, `gracePeriod ≤ 1 day`,
  `twapWindow ∈ (0, 1 day]`, `calmDeviationTicks ∈ (0, 5000]`, `maxSlippageBps ∈ (0, 1000]`.
- Fee ceilings, and a nonzero `feeRecipient` whenever either fee bps is nonzero.

`rerange(uint24 width, uint256 minLiq0, uint256 minLiq1)` is **in-repo** (`onlyProposer`, persisted
per-cycle width, re-checked against the init band → `WidthOutOfBounds()`, selector `0x1f9f54af`). The
old "the vendored copy is behind upstream, re-vendor pending" caveat is **obsolete** — delete it on
sight.

### B.4 — bind the strategy to the vault

```bash
cast send "$VAULT" 'setStrategy(address)' "$STRAT" --from "$MULTISIG" --unlocked --rpc-url "$ADMIN"
```

**Set-once** (`onlyOwner`, reverts `LAV: strategy already set`). `msg.sender == strategy` is the sole
protection against arbitrary share inflation, so there is no rotation path. Get the clone right before
you call this — a wrong clone means a new vault.

### B.5 — activate: `Pending → Executed`

`activateStrategy` pulls the seed **from the caller** (the owner) straight to the strategy, then calls
`strategy.execute()`. The vault being the caller is what satisfies the strategy's `onlyVault` (a raw
`msg.sender == vault` compare) — that is the whole reason activation goes through the vault.

```bash
SEED=50000000000                                    # 50,000 USDC (6dp)
cast rpc tenderly_setErc20Balance "[\"$USDC\",\"$MULTISIG\",\"0xBA43B7400\"]" --rpc-url "$ADMIN"
cast send "$USDC"  'approve(address,uint256)' "$VAULT" "$SEED" --from "$MULTISIG" --unlocked --rpc-url "$ADMIN"
cast send "$VAULT" 'activateStrategy(uint256)' "$SEED"         --from "$MULTISIG" --unlocked --rpc-url "$ADMIN"
```

> - The owner must **approve the vault** for the seed — the transfer is
>   `safeTransferFrom(msg.sender, strategy, seedAmount)` and the vault never custodies it.
> - `seedAmount == 0` does **not** fail in the vault: it fails inside `execute()` with
>   `ExecuteZeroBalance` (`_supplyCollateral` reads the strategy's own balance). A seed is mandatory.
> - **The seed mints no shares.** `_execute` issues nothing, so the seed is unowned NAV that accrues to
>   the first depositor via `shares = assets × (supply + 1e6) / (nav + 1)`. Size it deliberately: it is
>   a gift, not a position. On mainnet, decide whether the multisig seeds and then deposits, or seeds
>   the minimum that clears `ExecuteZeroBalance`.
> - Leave `depositsOpen == false` here. Phase C (proposal 012's `build()`) flips it — keeping the flip
>   in 012 is what makes the vnet run a faithful rehearsal of the mainnet proposal.

`settleStrategy()` is the mirror image (`onlyOwner`, `Executed → Settled`, one-way): the strategy
unwinds the whole levered book and pushes realized USDC to the vault, after which the **only** exit is
the vault's permissionless `redeemSettled(shares)` — pro-rata on pre-burn supply and pre-transfer
balance. Do **not** settle a staging instance you still want to use: the strategy's own redeem paths
require `State.Executed` and there is no path back.

### B.6 — post-conditions Phase C requires

Verify on the **public RPC** (reads only).

```bash
PUB="https://virtual.base.<...>.rpc.tenderly.co/<public-uuid>"
STRAT=0x...; VAULT=0x...

cast call "$STRAT" 'state()(uint8)'       --rpc-url "$PUB"   # 1  (BaseStrategy.State: Pending=0, Executed=1, Settled=2)
cast call "$STRAT" 'nav()(uint256)'       --rpc-url "$PUB"   # > 0
cast call "$STRAT" 'vault()(address)'     --rpc-url "$PUB"   # == $VAULT
cast call "$STRAT" 'proposer()(address)'  --rpc-url "$PUB"   # == MAMO_BACKEND
cast call "$VAULT" 'strategy()(address)'  --rpc-url "$PUB"   # == $STRAT
cast call "$VAULT" 'owner()(address)'     --rpc-url "$PUB"   # == MAMO_MULTISIG
cast call "$VAULT" 'depositsOpen()(bool)' --rpc-url "$PUB"   # false  (Phase C flips it to true)
cast call "$VAULT" 'feeConfig()(address)' --rpc-url "$PUB"   # 0x0    (protocol fees off at launch)
cast call "$VAULT" 'decimals()(uint8)'    --rpc-url "$PUB"   # 12     (USDC 6dp + 6)
```

| Post-condition | Expected |
|---|---|
| `strategy.state()` | `1` — Executed |
| `strategy.nav()` | `> 0` (seeded and executed) |
| `strategy.vault()` | the `LeveragedAeroVault` |
| `strategy.proposer()` | `MAMO_BACKEND` |
| `vault.strategy()` | the clone (both directions bound) |
| `vault.owner()` | `MAMO_MULTISIG`, with `pendingOwner() == 0x0` |
| `vault.depositsOpen()` | `false` (Phase C flips it) |
| `vault.decimals()` | `12` |
| all 5 venue feeds | FreshFeed'd (`updatedAt` within seconds of `block.timestamp`) |

---

## Phase C — account layer (this repo, scripted)

Unchanged by the de-Sherwood work. Once B.6 passes:

```bash
TENDERLY_VNET_RPC_URL="<admin-rpc>" \
TENDERLY_VNET_PUBLIC_RPC_URL="<public-rpc>" \
SHERWOOD_LEVERAGED_AERO_STRATEGY="<clone>" \
SHERWOOD_SYNDICATE_VAULT="<vault>" \
make tenderly-leveraged-aero-account
```

`make tenderly-leveraged-aero-account` → `./script/tenderly/run-harness.sh leveraged-aero-account` →
`./script/tenderly/run-leveraged-aero-account.sh`. The harness **always reuses**
`TENDERLY_VNET_RPC_URL` (the pooled layer lives only on the persistent vnet; a freshly API-created fork
would not have it) and **never** creates, tears down, or time-warps the vnet. It needs **no**
broadcaster key — everything is unlocked impersonation.

A CLI-supplied `TENDERLY_VNET_RPC_URL` wins over the `.env` value (the `.env` one may point at an older
vnet without the stack). The two address env vars have documented defaults matching the current
instance; override them to target a different vnet.

> **Env-var name vs address-book key — known skew.** Proposal 012 resolves the vault under the
> `LEVERAGED_AERO_VAULT` key, but `LeveragedAeroAccountHarness.s.sol` still injects the env var
> `SHERWOOD_SYNDICATE_VAULT` under the *old* key name. This is currently harmless: the shared deploy
> path (`LeveragedAeroAccountDeployer`) resolves only `config.sherwoodStrategy` + `config.token` and
> never touches `config.vault`, and the bash phase-3 replay sends to the raw `$VAULT` address rather
> than via the address book. It will bite the first time 012 itself is run against a vnet — the harness
> must then inject `LEVERAGED_AERO_VAULT`. Until then, pass `SHERWOOD_SYNDICATE_VAULT`.

### What it does

| Phase | Actions |
|---|---|
| **2 — deploy** | Funds `DEPLOYER_EOA` with ETH, then runs `LeveragedAeroAccountHarness.deploy()` — the real `LeveragedAeroAccountDeployer.deployImplementationAndFactory()` path (the **same** deploy code the 012 multisig proposal calls). Deploys the `MamoLeveragedAeroStrategy` UUPS impl + the `MamoLeveragedAeroStrategyFactory` (wired to registry, admin=`MAMO_MULTISIG`, backend=`MAMO_BACKEND`, impl, `strategyTypeId=5`, strategy clone, USDC). Parses `HARNESS_IMPL` / `HARNESS_FACTORY` from the log. |
| **3 — multisig `build()`** | As impersonated `MAMO_MULTISIG`: `registry.whitelistImplementation(impl, 5)`, `registry.grantRole(BACKEND_ROLE, factory)`, `vault.setOpenDeposits(true)`. Then `validate()` asserts: `whitelistedImplementations(impl)==true`, `implementationToId(impl)==5`, `latestImplementationById(5)==impl`, factory `hasRole(BACKEND_ROLE)`, `vault.depositsOpen()==true`, `factory.strategyTypeId()==5`, `factory.sherwoodStrategy()==$STRAT`, `factory.usdc()==USDC`. |
| **4 — e2e lifecycle** | Fresh throwaway user, funded ETH + 10,000 USDC. `createStrategyForUser` → `computeStrategyAddress` (assert `isUserStrategy` + `account.owner()==user`); `deposit(5,000 USDC, minShares)` (minShares from the strategy's `shares=assets*(supply+1e6)/(navNet+1)` formula, 1% tol) → assert shares minted & mirrored on the vault; fast `withdraw(half, minOut)` → assert USDC lands on user, account USDC==0; `requestWithdraw` → `fulfillRedeem` (impersonated `proposer`) → `claimWithdrawnUsdc` → asserts; `depositIdle` gate (a third party reverts "Not owner or backend"; `registry.getBackendAddress()` succeeds); `withdrawAll` cleanup; final clean-state asserts (shares==0, account USDC==0) + net user delta. |

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

> **Verified note — proposal 012 vs the harness.** The FPS proposal is committed at
> `multisig/mamo-multisig/012_DeployLeveragedAeroAccountSystem.sol` (deploy + `preBuildMock` typeId-5
> guard + `build()` + `validate()`), and now types the vault as `LeveragedAeroVault` under the
> `LEVERAGED_AERO_VAULT` key. FPS proposals *simulate* multisig actions rather than broadcast them, so
> the harness replays 012's `build()`/`validate()` **as real broadcast txs inline in bash** (the three
> `csend` actions + the `assert_eq` block) — same actions, same asserts, live on the vnet. On mainnet
> the actual multisig executes the FPS proposal itself.

Results log: `script/tenderly/harness-results-leveraged-aero.log`.
Machine-consumable output (regenerated every successful run, committed):
`script/tenderly/leveraged-aero-vnet.json`.

---

## Mainnet delta

The de-Sherwood change **removes the external blocker**: there is no Sherwood mainnet deployment to
wait on, no upstream governance to schedule around, and no third-party contract in the trust path. The
whole sequence is Mamo's to execute:

1. **Deploy the pooled layer** (Phase B, minus the vnet-only parts): `LeveragedAeroVault` with
   `owner_ = MAMO_MULTISIG`, then template → clone → `initialize` in one tx. **No FreshFeed** — real
   Chainlink feeds are genuinely fresh on mainnet, and `tenderly_*` cheat-RPCs do not exist. No
   impersonation: real signers throughout.
2. **Confirm vault ownership is live**, not pending — `owner() == MAMO_MULTISIG` and
   `pendingOwner() == 0x0`. `Ownable2Step` means a nomination is not enough, and 012's
   `setOpenDeposits(true)` reverts if the multisig has not accepted.
3. `vault.setStrategy(clone)` then `vault.activateStrategy(seed)` from the multisig (with the USDC
   approval to the vault first). Decide the seed size knowing it mints no shares.
4. **Proposal 012 executed by the actual multisig**, not unlocked impersonation. The **typeId-5
   availability guard** still applies: `preBuildMock` asserts
   `latestImplementationById(5) == address(0)` and `nextStrategyTypeId() <= 5` before whitelisting (the
   stale-counter-safe check).
5. **Commit the address keys.** At that point `LEVERAGED_AERO_VAULT` and
   `SHERWOOD_LEVERAGED_AERO_STRATEGY` **are** added to `addresses/8453.json` — safe then, because the
   code genuinely exists on mainnet and the eager `isContract` check passes.

Open gates before a mainnet deploy, from `docs/LEVERAGED_AERO_CL_AUDIT.md`: the
`wethIsToken0 == false` ordering has never been driven through a full lifecycle, and
`IMoonwellMarket.underlying()` must be confirmed on the live markets (the new init guard bricks
initialization if it is absent). Both are Base-fork-verifiable — this runbook is the vehicle.

---

## Verification checklist (copy-paste `cast` one-liners)

Set once (public RPC + resolved addresses from the run):

```bash
PUB="https://virtual.base.<...>.rpc.tenderly.co/<public-uuid>"
REG=0x46a5624C2ba92c08aBA4B206297052EDf14baa92     # MAMO_STRATEGY_REGISTRY
VAULT=0x...        STRAT=0x...
IMPL=0x...         FACTORY=0x...
MULTISIG=0x26c158A4CD56d148c554190A95A921d90F00C160
BACKEND=0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

**Pooled layer live (Phase B):**

```bash
cast chain-id --rpc-url "$PUB"                                   # 8453
cast call "$STRAT" 'state()(uint8)'      --rpc-url "$PUB"        # 1  (Executed)
cast call "$STRAT" 'nav()(uint256)'      --rpc-url "$PUB"        # > 0
cast call "$STRAT" 'vault()(address)'    --rpc-url "$PUB"        # == $VAULT
cast call "$STRAT" 'proposer()(address)' --rpc-url "$PUB"        # == $BACKEND
cast call "$VAULT" 'strategy()(address)' --rpc-url "$PUB"        # == $STRAT
cast call "$VAULT" 'owner()(address)'    --rpc-url "$PUB"        # == $MULTISIG
cast call "$VAULT" 'asset()(address)'    --rpc-url "$PUB"        # == $USDC
cast call "$VAULT" 'decimals()(uint8)'   --rpc-url "$PUB"        # 12
cast call "$VAULT" 'factory()(address)'  --rpc-url "$PUB"        # 0x0 while feeConfig == 0 (fees off)
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
cast call "$FACTORY" 'sherwoodStrategy()(address)'                        --rpc-url "$PUB"  # == $STRAT
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

## Current live instance — STALE (Sherwood-era stack)

> **This instance predates the de-Sherwood change (PR #66).** The vault beneath it is Sherwood's
> `SyndicateVault`, deployed from the old two-repo Phase B — **not** `LeveragedAeroVault`. Concretely:
> `redeemSettled` does **not** exist there, the getter is `openDeposits()` rather than
> `depositsOpen()`, and the lifecycle is still governor-driven (live proposal id `3`), so nothing in
> Phase B above describes it.
>
> **It is still usable for account-side FE/BE work**: `MamoLeveragedAeroStrategy` and
> `ILeveragedAeroCLStrategy` are code-untouched by PR #66 (runtime byte-identical; only a NatSpec hunk
> changed), so the account ABI, the factory, and the whole user lifecycle behave exactly as they will
> on the new stack. Do not use it to validate anything vault-shaped.
>
> A fresh instance built with Phase B above supersedes this table — replace it then. The authoritative
> machine-readable values are in `script/tenderly/leveraged-aero-vnet.json`; this table is the human
> copy and can lag it.

| Field | Value |
|---|---|
| vnet id | `8975a20b-5cf0-4399-9165-08e2b19229db` |
| chainId | `8453` |
| fork block | `48,901,646` |
| Admin RPC | `https://virtual.base.eu.rpc.tenderly.co/e6961d2a-4711-42eb-b4c1-2a42cbc17d28` |
| Public RPC | `https://virtual.base.eu.rpc.tenderly.co/70a4990f-6686-4536-8237-ad9103acd11b` |
| Vault (**Sherwood `SyndicateVault`**) | `0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9` |
| Strategy clone | `0x5E22913E4C96f816133fbc8E894F652a4f87C760` (PR #14 build; previous clone `0x168a…FB4B` is Settled) |
| Live proposal id (Sherwood governor) | `3` (1 = rejected artifact, 2 = settled) — clone init: width `4000` raw ticks, band `[200, 20000]` |
| Leveraged-aero template (Sherwood-deployed) | `0x8eE3AD5B3b574b4253985a7F32aB1231474CA381` |
| SyndicateGovernor (**no longer part of the stack**) | `0x430FA5659cCf6E9c1586007a0A2B7760fb75e105` |
| Mamo account impl | `0x699318E0641518eF39418a8D86F93BF8b0715c88` |
| Mamo account factory (typeId 5, latest) | `0x9f548228A41d18e2DC736ceF048cfBeC8fFC55E6` |
