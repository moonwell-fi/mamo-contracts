# LPAutoBalancerV2 — Tenderly Virtual TestNet harness

A **broadcasting** harness that deploys `LPAutoBalancerV2` to a Tenderly Virtual TestNet
(a Base mainnet fork) and drives its real lifecycle as on-chain transactions, to
**empirically verify the spec's assumptions on infrastructure that mirrors mainnet** and feed
measured numbers into PR review.

This complements — does not replace — the unit/integration suites. Those run inside foundry's
in-process EVM with cheatcodes (`deal`, `prank`, `vm.createSelectFork`). This harness proves the
*deployed artifact* behaves as specified: real signed txs, real gas, the real op-stack EVM, the
real Aerodrome Slipstream pool/gauge/NFPM, and an inspectable trace in the Tenderly dashboard.

## What it verifies (against real Base WETH/cbBTC liquidity)

| Spec assumption | How the harness checks it |
|---|---|
| **No-swap principal conservation** on `reset()` | Measures token0/token1 forwarded to `feeCollector` — must be fees/dust only, never principal. The contract has no router, so a successful `reset()` IS the on-chain value floor passing. |
| **Balanced rebuild** → in range | Mints a spot-straddling main, `reset()`, asserts `mainInRange == true`. |
| **Single-sided rebuild** (the `_mainRange` fix) | Mints a main entirely above spot (100% WETH), `reset()`, asserts the rebuild is a valid single-sided position parked above spot (`mainTickLower > spot`, `!mainInRange`, liquidity > 0) — **no swap, principal fully redeployed**. |
| **Fee + AERO skim** to `feeCollector` | Stakes, advances the vnet clock, `reset()`, asserts AERO arrived at `feeCollector`. |
| **Role gating** | An unprivileged caller's `reset()` / `exit()` / `stake()` must revert with `AccessControlUnauthorizedAccount`. |
| **Cooldown** | An immediate second `reset()` must revert `Cooldown`. |
| **`exit()` returns all principal** | Safe-gated `exit()` returns all token0/token1 to the Safe and marks the slot inactive (`getDecisionSnapshot` reverts `NotActive`). |
| **Deployable size** | The orchestrator reports the deployed runtime bytecode size vs the 24,576-byte EIP-170 limit. |

The calm-gate (spot↔TWAP deviation) firing is covered by the unit suite; the `checkCalmGate()`
entrypoint is provided for driving it live via a `slot0` storage override but is not run by default.

## Usage

```bash
# both scenarios (balanced + single-sided)
./script/tenderly/run-harness.sh
# or via make
make tenderly-harness

# one scenario
./script/tenderly/run-harness.sh --scenario balanced
./script/tenderly/run-harness.sh --scenario singlesided

# force-create a fresh vnet via the Tenderly API and keep it after the run
./script/tenderly/run-harness.sh --create --keep

# the other harnesses (each documented in its own section below)
./script/tenderly/run-harness.sh lpv2-matrix
./script/tenderly/run-harness.sh price-checker
./script/tenderly/run-harness.sh leveraged-aero-stack     # pooled layer — run before the account one
./script/tenderly/run-harness.sh leveraged-aero-account
```

Requires `forge`, `cast`, `jq`, `python3`, `curl`. Reads `.env`.

### Broadcaster key (`MAMO_DEPLOYER_PRIVATE_KEY`)

`MAMO_DEPLOYER_PRIVATE_KEY` in `.env` signs the broadcast txs. **It must be a throwaway, fork-only key
— never a mainnet deployer.** The harness only ever touches an ephemeral Tenderly Base-fork vnet, so
any funded key works; treat it as disposable.

The key is deliberately kept **off the command line**: forge/cast argv is world-readable via `ps aux`
on a shared host. Instead `load_env` exports it into the environment (`set -a`), the `.s.sol` reads it
with `vm.envUint` + `vm.startBroadcast(pk)`, and the orchestrator derives the sender address by reading
it back through the harness `sender()` entrypoint (`vm.addr`) — so the raw key never appears in an argv.
(This differs from `make deploy-broadcast`, which uses a `--account` keystore; an interactive keystore
prompt is a poor fit for this non-interactive automation loop, and foundry does not honor an
`ETH_PRIVATE_KEY` env fallback on the pinned nightly.)

## Leveraged-Aero pooled-layer harness (vault + strategy clone)

`run-leveraged-aero-stack.sh` (dispatch: `./run-harness.sh leveraged-aero-stack`, or
`make tenderly-leveraged-aero-stack`) deploys the **pooled layer** — the `LeveragedAeroVault` plus its
`LeveragedAerodromeCLStrategy` clone — onto a live, **persistent** Base-fork vnet and drives it
`Pending → Executed`. This is runbook
[Phase B](../../docs/LEVERAGED_AERO_VNET_RUNBOOK.md#phase-b--pooled-layer-vault--strategy-clone-this-repo);
**it must run before the account harness** on a fresh vnet.

| Phase | What it does |
|---|---|
| **B.0 — FreshFeed** | For each of the 5 venue feeds: read the live `decimals()`/answer, deploy a [`FreshFeed`](./FreshFeed.sol) carrying them as immutables, then `tenderly_setCode` its **runtime** code onto the canonical mainnet feed address. Asserts `updatedAt` is within seconds of the head timestamp, the sequencer answer is `0` (up), and AERO/USD is 8dp. Skip with `--no-freshfeed`. |
| **B.1 — deploy** | `LeveragedAeroStackHarness.deployTemplate()` as `DEPLOYER_EOA`: the strategy **template** (a `forge script` broadcast, so its three delegatecall libraries are deployed + linked automatically) and `LeveragedAeroVault(USDC, MAMO_MULTISIG, "Mamo Leveraged Aero Vault", "mlaUSDC")`. `owner_` is the multisig in the constructor, so there is no `acceptOwnership()` step. |
| **B.2 — initData** | `buildInitData()` ABI-encodes `InitParams` from the env-driven venue book (no RPC needed — pure `env → abi.encode`). |
| **B.3 — cloneAndBind** | As impersonated `MAMO_MULTISIG`: `vault.cloneAndBind(template, MAMO_REBALANCER, initData)` — atomic clone + `initialize` + bind, so there is no window in which the fresh clone is initializable by a front-runner. A wrong venue value fails here loudly (`VenueMismatch` / `UnsupportedLeg` / `LegDecimalsOutOfRange` / …). |
| **B.4 — activate** | `tenderly_setErc20Balance` USDC to the multisig → `approve(vault, SEED)` (the seed is pulled from the **caller**) → `activateStrategy(SEED)`, which executes the levered book and mints the seeder `SEED × 1e6` genesis shares. |
| **B.5 — asserts** | Every post-condition the account layer depends on (table below). |

```bash
TENDERLY_VNET_RPC_URL=<admin-rpc> TENDERLY_VNET_PUBLIC_RPC_URL=<public-rpc> \
make tenderly-leveraged-aero-stack
```

| Post-condition | Expected |
|---|---|
| `vault.owner()` / `pendingOwner()` | `MAMO_MULTISIG` / `0x0` |
| `vault.strategy()` | the clone (both directions bound) |
| `vault.asset()` / `decimals()` | USDC / `12` (6dp asset + the load-bearing 6-decimal offset) |
| `vault.depositsOpen()` / `settled()` | `false` / `false` — deposits are flipped by proposal 012 in Phase C |
| `vault.balanceOf(MAMO_MULTISIG)` / `totalSupply()` | `SEED × 1e6` (the genesis mint) |
| `strategy.state()` | `1` — Executed |
| `strategy.nav()` | `> 0` |
| `strategy.vault()` / `proposer()` | the vault / `MAMO_REBALANCER` |
| all 5 venue feeds | FreshFeed'd, `updatedAt` within seconds of the head |

**`proposer` = `MAMO_REBALANCER`, deliberately NOT `MAMO_BACKEND`.** The strategy has exactly one
operator role (`onlyProposer`: `rerange` / `compound` / `fulfillRedeem` / deleverage) and the
**rebalancer service** owns it; the Mamo backend drives the *account* layer. The vnet default is a
throwaway keypair (`0x73f6B456d063F78129113D42DBC315b9eEee8FAf`, private key published in the runner
header so anyone can drive the role on the fork). **Mainnet must pass the real rebalancer ops key via
`MAMO_REBALANCER`.** Unless `FEE_RECIPIENT` overrides it, the proposer is also the fee recipient.

**The venue book is env-driven** with Base defaults in both the runner and
`LeveragedAeroStackHarness.s.sol` (keep the two in lockstep). `LP_POOL` is the prominent one — the
final pool choice is a **pending product decision**, so it is a parameter, not a constant (default:
the WETH/cbBTC CL pool at `tickSpacing 100`). Changing it means changing the legs, their Moonwell
markets, their feeds, `TICK_SPACING` and the two swap spacings with it. USDC can never be a leg
(`UnsupportedLeg` — it is the unit of account), nor can the gauge reward token (AERO). The per-leg
**swap** tickSpacings (`LEG_A_SWAP_TICK_SPACING` / `LEG_B_SWAP_TICK_SPACING`, default `100`) are
separate venues from the LP pool and are existence-**probed** at init through the CL factory, so a
wrong value fails `cloneAndBind` rather than bricking a live book's settle/deleverage path.

Results log: `script/tenderly/harness-results-leveraged-aero-stack.log`. On success it merge-writes the
`pooled` + `feeds` objects of [`leveraged-aero-vnet.json`](./leveraged-aero-vnet.json) and **nulls the
account addresses** — a new pooled layer invalidates the account factory, which binds the strategy
clone at construction, so the account harness has to run again.

## MamoLeveragedAeroStrategy account harness

`run-leveraged-aero-account.sh` (dispatch: `./run-harness.sh leveraged-aero-account`, or
`make tenderly-leveraged-aero-account`) drives the **account layer** of the leveraged-Aero deployment
against a LIVE, **persistent** Base-fork vnet on which the **pooled layer** (`LeveragedAeroVault` +
a `LeveragedAerodromeCLStrategy` clone) is already deployed, then smoke-tests the account wrapper
end-to-end. It replays multisig proposal `012_DeployLeveragedAeroAccountSystem`
plus the full user lifecycle as real broadcast txs, driven by Tenderly **unlocked impersonation**
(no private keys) for `MAMO_MULTISIG` / `DEPLOYER_EOA` / the strategy proposer / a fresh throwaway user.

Both layers now live in **this** repo — the Sherwood dependency was removed in PR #66 — and both have
harnesses: the pooled layer is deployed by [`run-leveraged-aero-stack.sh`](#leveraged-aero-pooled-layer-harness-vault--strategy-clone)
(section above), which must run first on a fresh vnet. The two harnesses share
`leveraged-aero-vnet.json`: the stack run records `pooled.{vault, strategyClone}` and this harness
picks them up as its defaults (env vars still win).

| Phase | What it does |
|---|---|
| **2 — deploy** | `LeveragedAeroAccountHarness.deploy()` runs the real `LeveragedAeroAccountDeployer` (the same code proposal 012 calls) to deploy the impl + factory as `DEPLOYER_EOA`. |
| **3 — multisig** | As `MAMO_MULTISIG`: `whitelistImplementation(impl,5)`, `grantRole(BACKEND_ROLE, factory)`, `vault.setOpenDeposits(true)`; then reproduces every `validate()` assert via `cast` reads. |
| **4 — e2e** | Fresh throwaway user: `createStrategyForUser` → `deposit` → fast `withdraw(half)` → `requestWithdraw` → proposer `fulfillRedeem` (pays the USER directly — no claim step) → `syncRedeemRequests` → `depositIdle` gate (third-party reverts, registry backend succeeds) → `withdrawAll` cleanup → clean-state asserts + net-delta report. |

**Why `--reuse` is forced.** The vault + strategy clone exist only on the shared persistent vnet, so
this harness ALWAYS reuses `TENDERLY_VNET_RPC_URL` (point it at the vnet's **Admin RPC** — it accepts
`eth_sendTransaction` from any unlocked sender AND serves reads); it never creates or deletes a vnet.

**Address resolution.** The strategy/vault keys are deliberately NOT in `addresses/8453.json`: FPS
`Addresses` validates `isContract` **eagerly** in its constructor (gated on
`chainId == block.chainid`), so committing them with `isContract:true` would revert the `Addresses`
constructor on every real-Base-mainnet CI run (no code lives there). They are supplied via env vars
(documented defaults = current vnet values) and injected at runtime inside
`LeveragedAeroAccountHarness.s.sol` with `addresses.addAddress(...)`.

The env-var names match the address-book keys proposal 012 resolves exactly: the strategy is
`LEVERAGED_AERO_STRATEGY` (also `factory.leveragedAeroStrategy()`) and the vault is
`LEVERAGED_AERO_VAULT`.

**Feed freshness.** A Base fork's Chainlink answers are frozen, so `updatedAt` recedes as the clock
advances and every priced path bricks with `StaleOracle` in ~1 day. The fix is the **FreshFeed**
pattern: code-replace the 5 venue feeds (leg A/USD, leg B/USD, USDC/USD, AERO/USD, L2 sequencer
uptime) with mocks whose `updatedAt` tracks `block.timestamp` — feeds never stale, prices
frozen-but-movable, warping safe. The shared instance carries those mocks (verified live 2026-07-26:
clock +5 days, feed lag 60 s, e2e green). The in-repo implementation is [`FreshFeed.sol`](./FreshFeed.sol),
applied by `run-leveraged-aero-stack.sh` phase **B.0**. On an instance without the mocks: never
time-warp, expect ~1-day staleness. This harness does no time travel either way; the 2-day
`emergencyWithdraw` path stays unit-test-covered, not part of the live smoke.

**Config for consumers.** Every successful run refreshes
[`leveraged-aero-vnet.json`](./leveraged-aero-vnet.json) — the machine-consumable source of the
current vnet's addresses + public RPC for the frontend env, indexer, keeper, and rebalancer. Only
read-safe values go in it; the **admin RPC is retrieved from the Tenderly dashboard** (org access
required), never committed. Set
`TENDERLY_VNET_PUBLIC_RPC_URL` when running so the public RPC lands in the file.

Both harnesses **merge-write** the file (`jq '$prev * {…}'`) rather than overwriting it, so they can run
in either order: the stack harness owns `pooled` + `feeds`, the account harness owns `mamo`. The pooled
layer is published under `pooled.{vault, strategyClone, template, proposer, seed, lpPool}`.
`vaultGeneration` is a **number** — `2` for the in-repo `LeveragedAeroVault`, `1` for the legacy
Sherwood `SyndicateVault` — probed at run time from whether the vault answers `depositsOpen()`, with
the human-readable form in `vaultGenerationName`.

### Future reference — redeploying / vnet ops crib

Vnet instances rotate occasionally (fork-block hygiene, broken state) — but NOT for feed staleness:
the shared instance carries FreshFeed mocks (see step 0). When a refresh does happen:

0. **Check whether a refresh is even needed.** The current shared instance has the **FreshFeed**
   pattern applied (the 5 venue Chainlink feeds code-replaced with mocks whose `updatedAt` tracks
   `block.timestamp`) — feeds never stale, so there is **no ~1-day rotation treadmill** on it
   (verified live 2026-07-26: clock +5 days, feed lag 60s, e2e green). Rotate only for fork-block
   hygiene or a broken instance. Do **NOT** create replacements with state sync: it is
   creation-time-only, it is unnecessary once FreshFeed is applied, and it would re-hydrate the
   *mainnet feed addresses* the FreshFeed override lives at — silently restoring the real aggregators
   and the staleness treadmill with them. Re-apply FreshFeed instead.
1. **Pooled layer first** — `LeveragedAeroVault` + the `LeveragedAerodromeCLStrategy` clone, via
   `make tenderly-leveraged-aero-stack` (runbook Phases A–B: create the vnet by hand → FreshFeed
   overrides → template + vault owned by `MAMO_MULTISIG` → `cloneAndBind` → `activateStrategy(seed)`):

   ```bash
   TENDERLY_VNET_RPC_URL=<admin-rpc> \
   TENDERLY_VNET_PUBLIC_RPC_URL=<public-rpc> \
   MAMO_REBALANCER=<rebalancer-ops-addr> \
   make tenderly-leveraged-aero-stack
   ```

2. **Account layer** (this harness) — with the same admin RPC. The pooled addresses come from
   `leveraged-aero-vnet.json`, which step 1 just refreshed, so they normally need no env override:

   ```bash
   TENDERLY_VNET_RPC_URL=<admin-rpc> \
   TENDERLY_VNET_PUBLIC_RPC_URL=<public-rpc> \
   make tenderly-leveraged-aero-account
   ```

   Deploys + wires + smokes everything and merge-writes `leveraged-aero-vnet.json` — commit that diff so
   consumers pick up the new instance.

> **The current shared instance is Sherwood-era.** It predates PR #66, so the vault beneath it is
> Sherwood's `SyndicateVault`: no `redeemSettled`, `openDeposits()` instead of `depositsOpen()`,
> governor-driven lifecycle. The account ABI is unchanged (`MamoLeveragedAeroStrategy` is byte-identical
> across PR #66), so it stays valid for account-side FE/BE work — but not for anything vault-shaped.

One-off ops against the vnet (all via the **admin** RPC, no keys — unlocked impersonation):

```bash
# fund ETH / USDC to any address
cast rpc tenderly_setBalance        '["<addr>","0x56BC75E2D63100000"]'                    --rpc-url "$ADMIN"   # 100 ETH
cast rpc tenderly_setErc20Balance   '["<usdc>","<addr>","0x2540BE400"]'                   --rpc-url "$ADMIN"   # 10,000 USDC

# act as any actor — e.g. fulfill an async withdrawal as the backend/proposer
cast send <strategyClone> 'fulfillRedeem(uint256,uint256)' <id> 0 --from <MAMO_BACKEND> --unlocked --rpc-url "$ADMIN"

# read anything via the public RPC (share this one freely)
cast call <account> 'sharesBalance()(uint256)' --rpc-url <public-rpc>
```

```bash
# current vnet values are the built-in defaults; override to point elsewhere
TENDERLY_VNET_RPC_URL=<admin-rpc> make tenderly-leveraged-aero-account
```

## Vnet heartbeat — an idle vnet mines nothing (MOO-768)

A Tenderly vnet produces a block **only when a transaction arrives**. Real Base produces one every
~2s, and wallets assume the latter. Two QA artifacts fall out of that, both seen during FE-05 manual
testing:

1. **Confirmation deadlock** — any `waitForTransactionReceipt` with `confirmations > 1` between
   interactive legs never resolves: the first leg mines into its own block and no further blocks come.
2. **MetaMask "previous transactions are still being signed or submitted"** — MetaMask's activity
   tracker needs block progression to mark a tx confirmed, so mined txs linger locally as
   submitted/pending and the next signature request shows the stale-queue banner. Benign (nonces come
   from the RPC and are correct) but it reads as a failure to testers. Clears via MetaMask → Settings
   → Advanced → *Clear activity tab data*.

`mine-ticker.sh` closes the gap from outside the app — it calls `evm_mine` on a fixed interval so the
chain keeps ticking while nobody is transacting. It holds no state, so starting and stopping it is
always safe, and it needs the **admin** (write-capable) RPC: on the public one `evm_mine` returns
`Access forbidden by access rules`.

```bash
make tenderly-mine                                  # foreground 15s heartbeat, Ctrl-C to stop
make tenderly-mine-start                            # detached — logs to mine-ticker.log
make tenderly-mine-status                           # running? and how far behind wall clock
make tenderly-mine-stop
./script/tenderly/mine-ticker.sh --once             # single block — catch a drifted vnet up
./script/tenderly/mine-ticker.sh --interval 2 --quiet   # exactly Base's cadence
```

**It does not fast-forward the chain.** Tenderly stamps each mined block with the real time elapsed
since the previous one, so the cadence sets the block rate, not the rate of chain time — a 15s ticker
and a 2s ticker both keep the offset flat. What it fixes is *drift*:
an idle vnet falls behind wall clock by exactly as long as it sat idle (measured 2026-08-19: the
shared instance was ~2h behind after a quiet stretch), and the first transaction afterwards closes the
whole gap in a single block's timestamp. A running ticker keeps that offset flat — which is the more
production-faithful thing for anything reading a TWAP or an oracle age.

### Keeping it up all day

QA wants blocks whenever someone is clicking, not only when someone remembers to start a ticker. The
daemon has to live on a host that does not sleep — a closed laptop stops the chain, which is the exact
failure this exists to prevent. On macOS, a LaunchAgent restarts it across crashes and reboots:

```xml
<!-- ~/Library/LaunchAgents/fi.moonwell.vnet-mine.plist -->
<plist version="1.0"><dict>
  <key>Label</key>            <string>fi.moonwell.vnet-mine</string>
  <key>ProgramArguments</key> <array>
    <string>/path/to/mamo-contracts/script/tenderly/mine-ticker.sh</string>
    <string>--interval</string><string>15</string>
    <string>--quiet</string>
  </array>
  <key>EnvironmentVariables</key> <dict>
    <!-- admin RPC from 1Password; the plist is NOT in the repo -->
    <key>TENDERLY_VNET_RPC_URL</key> <string>https://virtual.base.…</string>
  </dict>
  <key>RunAtLoad</key>  <true/>
  <key>KeepAlive</key>  <true/>
  <key>StandardOutPath</key>   <string>/tmp/vnet-mine.log</string>
  <key>StandardErrorPath</key> <string>/tmp/vnet-mine.err</string>
</dict></plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/fi.moonwell.vnet-mine.plist
launchctl print gui/$(id -u)/fi.moonwell.vnet-mine | grep 'pid ='
launchctl bootout   gui/$(id -u) ~/Library/LaunchAgents/fi.moonwell.vnet-mine.plist   # remove
```

Run it under `--quiet` there: the status line is for humans watching a terminal, and unattended it
just grows the log. Note the plist embeds the write-capable RPC, so it stays out of the repo — keep it
in `~/Library/LaunchAgents` and source the URL from 1Password.

The alternative that depends on nobody's machine is a scheduled CI job holding the admin RPC as a
secret and mining for the length of its run — worth it only if the vnet outlives the QA train.

Fixing this at the source instead — interval mining configured on the vnet itself — is a Tenderly
dashboard/admin action rather than anything in this repo, and it is still the right permanent answer.
The ticker is the version that needs no account privileges and no maintainer in the loop.

## vnet resolution

Mirrors the goal's "(a) spin up a vnet **or** (b) use the url in `.env`":

- **(a)** If `TENDERLY_ACCESS_KEY` + `TENDERLY_ACCOUNT_SLUG` + `TENDERLY_PROJECT_SLUG` are set
  (and `--create` or no `TENDERLY_VNET_RPC_URL`), the orchestrator creates a fresh Base-fork vnet
  via the Tenderly API (the same REST flow as `moonwell-tenderly/scripts/setup-forks.ts`) and
  tears it down at the end unless `--keep`.
- **(b)** Otherwise it uses `TENDERLY_VNET_RPC_URL` from `.env` and never deletes it.

## Files

**Foundry harnesses** — each exposes multiple `--sig` entrypoints so the orchestrator can
interleave Tenderly cheat-RPCs (funding, time advance, snapshots) between phases:

- `LPV2TenderlyHarness.s.sol` — the LPAutoBalancerV2 script.
  - lifecycle (`run-lpv2.sh`): `deployAndMint`, `registerStake`, `checkRoleGating`, `doReset`, `doExit`
  - price-sim matrix (`run-lpv2-matrix.sh`): `deploySwapper`, `pushTick(bool,uint256)`, `justReset`,
    `assertInRange`, `assertSingleSided`, `tightenCalmGate`, `checkCalmGate`, `checkStaleOracle`
  - `sender()` — plumbing: prints `vm.addr(pk)` so the orchestrator derives the broadcaster
    address without putting the raw key on an argv (see "Broadcaster key" above).
- `SlippagePriceCheckerTenderlyHarness.s.sol` — the SlippagePriceChecker script
  (`run-price-checker.sh`): `checkPriceGating`, `checkStalePrice`.
- `LeveragedAeroAccountHarness.s.sol` — the MamoLeveragedAeroStrategy account deploy runner
  (`run-leveraged-aero-account.sh`): `deploy()` wraps the real `LeveragedAeroAccountDeployer` and
  injects the vnet-only vault / strategy-clone keys at runtime (`LEVERAGED_AERO_{STRATEGY,VAULT}`).
- `LeveragedAeroStackHarness.s.sol` — the leveraged-Aero **pooled**-layer script
  (`run-leveraged-aero-stack.sh`): `deployTemplate()` (strategy template + vault, libraries linked by
  the broadcast) and `buildInitData()` (env venue book → ABI-encoded `InitParams`). The clone/init/bind
  and activation are `cast send` from bash, because they are `onlyOwner` on an impersonated multisig.
- `FreshFeed.sol` — vnet-only Chainlink aggregator stand-in whose `updatedAt` tracks
  `block.timestamp`; its runtime code is `tenderly_setCode`'d onto the 5 canonical venue feed
  addresses (phase B.0). Serves both the 8dp price feeds and the sequencer-uptime feed (`answer 0`).
  Storage-free (immutables only), which is what makes a code-only override sound.
- `TenderlySwapHelper.sol` — a tiny deployed swap-callback holder for the price-sim matrix; a
  forge Script can't be its own `uniswapV3SwapCallback`, so `pushTick` routes swaps through this.

**Orchestrators / shell:**

- `run-harness.sh` — dispatcher: routes to `run-lpv2.sh` (default), `run-lpv2-matrix.sh`,
  `run-price-checker.sh`, `run-leveraged-aero-stack.sh`, or `run-leveraged-aero-account.sh` (see Usage).
- `run-lpv2.sh` — LPAutoBalancerV2 lifecycle orchestrator (balanced + single-sided scenarios).
- `run-lpv2-matrix.sh` — LPAutoBalancerV2 price-simulation scenario matrix (calm reset → in range,
  large move → single-sided, calm-gate → `TwapDeviation`, stale-oracle → `StaleOracle`), each off a
  fresh `evm_snapshot`.
- `run-price-checker.sh` — SlippagePriceChecker gate against the live checker + real Chainlink config.
- `run-leveraged-aero-stack.sh` — leveraged-Aero **pooled**-layer deploy (FreshFeed → template + vault
  → `cloneAndBind` → seed + activate → post-condition asserts) against the persistent vnet (unlocked
  impersonation; always `--reuse`; never warps). Run before the account harness. See section above.
- `run-leveraged-aero-account.sh` — MamoLeveragedAeroStrategy account deploy-drive + e2e smoke against
  the persistent vnet carrying the pooled layer (unlocked impersonation; always `--reuse`). See section
  above.
- `setup-staging.sh` — stands up a **persistent** frontend staging vnet (not torn down after the run).
- `mine-ticker.sh` — vnet heartbeat: `evm_mine` on an interval so an idle chain keeps producing
  blocks for wallet-driven manual QA. `--daemon/--stop/--status` for an all-day ticker (see
  "Vnet heartbeat" above for the launchd recipe). Standalone; not part of any harness run.
- `lib/common.sh` — shared plumbing (vnet resolution/teardown, cheat-RPC fund/time helpers, the
  forge-phase runner, address-book lookup, vnet gotcha fixes). Sourced, never executed.
- `lib/market.sh` — reusable price/market simulation cheat primitives (`snapshot`/`revert_to`,
  time advance). Sourced after `common.sh`.
- `harness-results.log` — written each run (gitignored).

## Notes / gotchas baked into the harness

Running a deployed contract against a live vnet surfaces things in-process fork tests never hit.
The harness handles each explicitly (see inline comments):

1. **Deadlines.** A broadcast tx lands in a *later* block than simulation, so `deadline = now + 1`
   (fine in-process) expires. The harness uses `now + 1 day`.
2. **No simulated-return chaining across broadcast txs.** On a live fork the simulated NFPM
   `tokenId` can differ from the broadcast one. The harness mints **directly to the balancer** and
   reads the real `tokenId` from chain (`tokenOfOwnerByIndex`) before registering.
3. **`--no-storage-caching`.** This vnet reports chain id `8453` (same as real Base), so forge's
   fork cache would mix real-Base slots with vnet slots. (moonwell-tenderly avoids this by giving
   vnets a unique chain id, `73570 + networkId`.)
4. **NFPM `_nextId` repair.** The vnet's packed `_nextId/_nextPoolId` slot (#14) hydrates *behind*
   real Base's counter while higher `_owners` hydrate lazily → `ERC721: token already minted`. The
   orchestrator copies real Base's authoritative slot 14 onto the vnet (+1000 id margin).
5. **Oracle freshness.** A fresh fork's Chainlink `updatedAt` can sit slightly ahead of the latest
   block, underflowing `block.timestamp - updatedAt`. The orchestrator advances the clock just past
   the freshest feed (and stays far under `maxOracleDelay = 26 h`).
6. **Gas estimate multiplier (3×).** The vnet under-estimates gas for deep nested delegatecalls
   (e.g. `exit()`'s final cbBTC FiatToken transfer OOG'd at the default 1.3×).
