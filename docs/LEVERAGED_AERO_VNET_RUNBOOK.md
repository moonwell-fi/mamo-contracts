# Leveraged-Aero vnet runbook — stand up & e2e-verify the full stack

A repeatable procedure for standing up a **fresh Tenderly Base-fork Virtual TestNet** carrying the
complete leveraged-Aerodrome stack — the **Sherwood** side (pooled `SyndicateVault` +
`LeveragedAerodromeCLStrategy`) and the **Mamo** side (`MamoLeveragedAeroStrategy` account wrapper +
factory) — and end-to-end verifying it. Run this on staging refreshes, feed-staleness resets, and
pre-mainnet rehearsals.

Audience: Mamo engineers with checkouts of **both** repos.

- Mamo repo: `mamo-contracts` (this repo).
- Sherwood repo: `sherwoodagent/sherwood`, `contracts/` package — local checkout at `../sherwood`.

The two sides are deliberately split. Fund/vault creation and the governor lifecycle
(`createSyndicate`, `ISyndicateGovernor.propose` with `BatchExecutorLib` call batches + WOOD
voting-power orchestration) exist **only upstream**; the interfaces vendored into `mamo-contracts`
(`src/leveraged-aero/sherwood/`) do not expose them. Mamo treats upstream as authoritative and never
duplicates fund orchestration. **Phase A → B run in the Sherwood repo; Phase C is the Mamo side and
starts once the Sherwood stack is live.**

---

## Actors & canonical addresses (Base mainnet / fork-native)

These resolve identically on real Base and on any correctly-forked vnet (chainId 8453). Mamo values
come from `addresses/8453.json`.

| Role | Key | Address |
|---|---|---|
| Mamo multisig (admin / vault owner) | `MAMO_MULTISIG` | `0x26c158A4CD56d148c554190A95A921d90F00C160` |
| Mamo backend (operator / proposer / agent) | `MAMO_BACKEND` | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` |
| Deployer EOA | `DEPLOYER_EOA` | `0xDca82E03057329f53Ed4173429D46B0511E46Fb8` |
| Mamo strategy registry | `MAMO_STRATEGY_REGISTRY` | `0x46a5624C2ba92c08aBA4B206297052EDf14baa92` |
| USDC | `USDC` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

> On a vnet, all privileged roles are driven by **unlocked impersonation** through the admin RPC — no
> private keys. Throwaway EOAs are used only for simulated end users.

---

## Hard constraints (read before every run)

> 1. **chainId 8453 only.** Mamo's FPS `Addresses` book keys off `block.chainid`, and a matching chain
>    id keeps real Base addresses (USDC, Moonwell, Aerodrome, Chainlink feeds) fork-native. A different
>    chain id breaks address resolution and the whole harness.
> 2. **NEVER time-warp a shared vnet** (`evm_increaseTime` / `evm_setNextBlockTimestamp`). Advancing
>    the clock ages the frozen Chainlink feeds; once `block.timestamp − updatedAt` exceeds the feed's
>    max delay, `nav()` fails closed (`StaleOracle`) and every deposit/fast-redeem bricks for everyone.
>    This is also **why vnets are recreated periodically**: even without deliberate warping, wall-clock
>    drift stales the feeds in ~1 day — plan refreshes accordingly. The Mamo harness does no time
>    travel; the 2-day `emergencyWithdraw` path is covered by unit tests only.
> 3. **Base per-tx gas cap = 16,777,216 (2^24).** `estimate × gas-multiplier` must stay under it. Large
>    `CREATE`s (impl/factory) use a modest multiplier (`DEPLOY_GAS_MULT=200`); deep nested delegatecalls
>    want more headroom. Watch the multiplier on both bounds.
> 4. **Unlocked impersonation replaces all privileged keys** — `MAMO_MULTISIG`, `MAMO_BACKEND`,
>    `DEPLOYER_EOA`, the strategy proposer. Only end users are throwaway EOAs.

---

## Phase A — create the vnet (Tenderly)

Create a **fresh, persistent** Virtual TestNet forking Base:

- Fork network: **Base (8453)**.
- Virtual network chain id: **8453 — MANDATORY** (see constraint 1).
- State sync: disabled. Explorer: optional.
- Persistence: **no auto-delete** (the Sherwood stack must survive across the multi-step deploy).

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
| **Admin RPC** | Sherwood `RPC_URL`; Mamo `TENDERLY_VNET_RPC_URL` (accepts `eth_sendTransaction` from any unlocked sender **and** serves reads) |
| Public RPC | read-only `cast` verification |
| fork block | reproducibility |

---

## Phase B — Sherwood stack (repo `../sherwood`, `contracts/`)

All commands run from `../sherwood/contracts`. Set `RPC=<admin-rpc>` first:

```bash
cd ../sherwood/contracts
RPC="https://virtual.base.<...>.rpc.tenderly.co/<admin-uuid>"
```

`DEPLOY_AUTH` selects the broadcast identity. On a vnet, use the funded-unlocked form so no key leaves
the box:

```bash
DEPLOY_AUTH="--unlocked --sender 0xDca82E03057329f53Ed4173429D46B0511E46Fb8"   # DEPLOYER_EOA
```

### B.1 — full stack (`deploy-vnet.sh`)

```bash
RPC_URL="$RPC" DEPLOY_AUTH="$DEPLOY_AUTH" ./script/deploy-vnet.sh
```

`deploy-vnet.sh` runs, in order:

| Step | Script | Deploys |
|---|---|---|
| 1 | `DeployWood.s.sol:DeployWood` | fixture WOOD + mint |
| 2 | `Deploy.s.sol:DeploySherwood` | core: factory / governor / registry / sWOOD / vault impl |
| 3 | `DeployPriceRouter.s.sol:DeployPriceRouter` | PriceRouter + Moonwell adapter + `factory.setPriceRouter` |
| 4 | `DeployTemplates.s.sol:DeployTemplates` | strategy templates |
| 5 | `DeployStrategyFactory.s.sol:DeployStrategyFactory` | keyless-clone factory + template approvals |

It exports `SKIP_MULTISIG_HANDOFF=true ALLOW_FIXTURE_WOOD=true` (deployer keeps ownership; fixture WOOD
allowed) — a **fork-only / beta posture, NEVER for mainnet**. It writes the address book to
`contracts/chains/8453.json`; re-runs and out-of-order static keys are preserved.

> **Note (verified against the scripts):** `deploy-vnet.sh` does **not** deploy the leveraged-aero
> template, clone, or proposal. Those are the three separate steps below, invoked after B.1.

### B.2 — leveraged-aero template (`DeployLeveragedAeroTemplate.s.sol`)

Deploys the `LeveragedAerodromeCLStrategy` template singleton (Foundry auto-links its three library
deps) and patches `LEVERAGED_AERO_CL_TEMPLATE` into `chains/8453.json`. **No env vars.**

```bash
forge script script/DeployLeveragedAeroTemplate.s.sol:DeployLeveragedAeroTemplate \
  --rpc-url "$RPC" --broadcast --slow $DEPLOY_AUTH
```

### B.3 — vault creation + clone/init + genesis proposal

This is the upstream-owned part. Three sub-steps; only the last two are fully scripted in the repo.

**Vault creation** (`createSyndicate` + agent/owner wiring) is **not** scripted here — it is driven by
the sherwood-side operator. The output you need is a live `SyndicateVault` address (`VAULT`) with:
- `vault.owner()` → `MAMO_MULTISIG`,
- the agent/proposer registered → `MAMO_BACKEND`,
- `openDeposits()` still `false` (Mamo's Phase C flips it).

**Clone + init** (`CloneAndInitLeveragedAero.s.sol`) — clones the template and initializes it against
the live vault. The Base venue book (USDC/WETH/cbBTC, Moonwell markets, the Slipstream pool/NFPM/gauge,
Chainlink feeds, `tickSpacing=100`) is **hardcoded**; actors + fees come from env. `initialize` has no
`proposer==caller` check, so the governor's `propose()` can store the clone directly.

```bash
VAULT=0x...                       # from vault creation
PROPOSER=0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73   # MAMO_BACKEND (agent registered on the vault)
FEE_RECIPIENT=0x...               # EOA receiving fee-shares
# optional: PERF_FEE_BPS (default 1000), MGMT_FEE_BPS (default 100),
#           LEVERAGED_AERO_CL_TEMPLATE (else read from chains.json)
VAULT="$VAULT" PROPOSER="$PROPOSER" FEE_RECIPIENT="$FEE_RECIPIENT" \
forge script script/CloneAndInitLeveragedAero.s.sol:CloneAndInitLeveragedAero \
  --rpc-url "$RPC" --broadcast --slow $DEPLOY_AUTH
```

**Genesis proposal** (`ProposeLeveragedAero.s.sol`) — proposes the clone through the real
`SyndicateGovernor`. Must be broadcast by the **agent EOA** (`propose` requires
`vault.isAgent(msg.sender)`), i.e. impersonate `MAMO_BACKEND`. The batch is
`exec = [USDC.transfer(strategy, PRINCIPAL), strategy.execute()]`, `settle = [strategy.settle()]`, no
co-proposers.

```bash
VAULT="$VAULT" STRATEGY=0x...     # the clone from B.3
# optional: PRINCIPAL (default 50000e6), STRATEGY_DURATION_DAYS (default 3650),
#           SYNDICATE_GOVERNOR (else read from chains.json)
VAULT="$VAULT" STRATEGY="$STRATEGY" \
forge script script/ProposeLeveragedAero.s.sol:ProposeLeveragedAero \
  --rpc-url "$RPC" --broadcast --slow \
  --unlocked --sender 0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73   # MAMO_BACKEND
```

> **Verified discrepancy — vote/execute is NOT scripted.** `ProposeLeveragedAero` only calls
> `propose()`. The rest of the governor lifecycle (WOOD voting-power delegation → vote → guardian
> review → `execute` → the deposits that fund NAV) is **not** in the repo scripts; it is owned by the
> **sherwood-side driver**. Use that driver's flow and its handoff record as the authoritative account
> of the last run (see next note).

> **Verified discrepancy — handoff doc / branch.** The runbook brief pointed at a sherwood branch
> `vnet/mamo-leveraged-aero` and a doc `docs/vnet-mamo-handoff.md`. **Neither exists on `origin`** as of
> this writing. The closest authoritative driver branch is **`test/e2e-leveraged-aero-vnet`** (the only
> handoff file present anywhere in the leveraged-aero branches is the unrelated
> `docs/validation/2026-06-12-mainnet-readiness/audit-fixes-handoff.md`). Treat
> `test/e2e-leveraged-aero-vnet` as the sherwood-side driver of record; confirm the exact doc name with
> the Sherwood team before citing it.

### B.4 — post-conditions Mamo requires before Phase C

Verify on the **public RPC** (reads only). `$STRAT` = the clone, `$VAULT` = the SyndicateVault,
`$PUB` = public RPC:

```bash
PUB="https://virtual.base.<...>.rpc.tenderly.co/<public-uuid>"
STRAT=0x...; VAULT=0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9

cast call "$STRAT" 'state()(uint8)'   --rpc-url "$PUB"    # 1  (BaseStrategy.State: Pending=0, Executed=1, Settled=2)
cast call "$STRAT" 'nav()(uint256)'   --rpc-url "$PUB"    # > 0  (proposal executed + deposits funded)
cast call "$STRAT" 'vault()(address)' --rpc-url "$PUB"    # == $VAULT
cast call "$VAULT" 'owner()(address)' --rpc-url "$PUB"    # == MAMO_MULTISIG
cast call "$STRAT" 'proposer()(address)' --rpc-url "$PUB" # == MAMO_BACKEND
cast call "$VAULT" 'openDeposits()(bool)' --rpc-url "$PUB" # false  (Mamo's Phase C flips it to true)
```

| Post-condition | Expected |
|---|---|
| `strategy.state()` | `1` (Executed — **BaseStrategy.State enum**, not the governor's `ProposalState` where Executed=6) |
| `strategy.nav()` | `> 0` (executed and deposits funded) |
| `strategy.vault()` | the SyndicateVault |
| `vault.owner()` | `MAMO_MULTISIG` |
| `strategy.proposer()` / agent | `MAMO_BACKEND` |
| `vault.openDeposits()` | `false` (Mamo flips it in Phase C) |

---

## Phase C — Mamo side (this repo)

Once B.4 passes, run the Mamo harness from `mamo-contracts`:

```bash
cd mamo-contracts
TENDERLY_VNET_RPC_URL="<admin-rpc>" \
SHERWOOD_LEVERAGED_AERO_STRATEGY="<clone>" \
SHERWOOD_SYNDICATE_VAULT="<vault>" \
make tenderly-leveraged-aero-account
```

`make tenderly-leveraged-aero-account` → `./script/tenderly/run-harness.sh leveraged-aero-account` →
`./script/tenderly/run-leveraged-aero-account.sh`. The harness **always reuses**
`TENDERLY_VNET_RPC_URL` (the Sherwood stack lives only on the persistent vnet; a freshly API-created
fork would not have it) and **never** creates, tears down, or time-warps the vnet. It needs **no**
broadcaster key — everything is unlocked impersonation.

A CLI-supplied `TENDERLY_VNET_RPC_URL` wins over the `.env` value (the `.env` one may point at an older
vnet without the stack). `SHERWOOD_LEVERAGED_AERO_STRATEGY` / `SHERWOOD_SYNDICATE_VAULT` have documented
defaults matching the current instance; override them to target a different vnet.

### What it does

| Phase | Actions |
|---|---|
| **2 — deploy** | Funds `DEPLOYER_EOA` with ETH, then runs `LeveragedAeroAccountHarness.deploy()` — the real `LeveragedAeroAccountDeployer.deployImplementationAndFactory()` path (the **same** deploy code the 012 multisig proposal calls). Deploys the `MamoLeveragedAeroStrategy` UUPS impl + the `MamoLeveragedAeroStrategyFactory` (wired to registry, admin=`MAMO_MULTISIG`, backend=`MAMO_BACKEND`, impl, `strategyTypeId=5`, sherwoodStrategy, USDC). Parses `HARNESS_IMPL` / `HARNESS_FACTORY` from the log. |
| **3 — multisig `build()`** | As impersonated `MAMO_MULTISIG`: `registry.whitelistImplementation(impl, 5)`, `registry.grantRole(BACKEND_ROLE, factory)`, `vault.setOpenDeposits(true)`. Then `validate()` asserts: `whitelistedImplementations(impl)==true`, `implementationToId(impl)==5`, `latestImplementationById(5)==impl`, factory `hasRole(BACKEND_ROLE)`, `vault.openDeposits()==true`, `factory.strategyTypeId()==5`, `factory.sherwoodStrategy()==$STRAT`, `factory.usdc()==USDC`. |
| **4 — e2e lifecycle** | Fresh throwaway user, funded ETH + 10,000 USDC. `createStrategyForUser` → `computeStrategyAddress` (assert `isUserStrategy` + `account.owner()==user`); `deposit(5,000 USDC, minShares)` (minShares from the vendored `shares=assets*(supply+1e6)/(navNet+1)` formula, 1% tol) → assert shares minted & mirrored on the vault; fast `withdraw(half, minOut)` → assert USDC lands on user, account USDC==0; `requestWithdraw` → `fulfillRedeem` (impersonated `proposer`) → `claimWithdrawnUsdc` → asserts; `depositIdle` gate (a third party reverts "Not owner or backend"; `registry.getBackendAddress()` succeeds); `withdrawAll` cleanup; final clean-state asserts (shares==0, account USDC==0) + net user delta. |

> **Why `SHERWOOD_*` are runtime-injected, never committed to `addresses/8453.json`:** FPS `Addresses`
> validates `isContract` **eagerly** in its constructor (`_checkAddress`, gated on
> `chainId==block.chainid`). Committing the Sherwood keys with `isContract:true` would revert the
> `Addresses` constructor on every real-Base-mainnet CI run, where no code lives at those addresses.
> The harness instead calls `addresses.addAddress(...)` from the env vars at runtime, so the keys exist
> only inside the vnet process (`LeveragedAeroAccountHarness._addFromEnv`, which also requires
> `value.code.length > 0`).

> **Verified note — `depositIdle` backend gate.** The gate checks `registry.getBackendAddress()`
> (BACKEND_ROLE member index 0), **not** the address-book `MAMO_BACKEND`. On the fork these differ; the
> harness reads the live value.

> **Verified note — proposal 012 vs the harness.** The FPS proposal is committed at
> `multisig/mamo-multisig/012_DeployLeveragedAeroAccountSystem.sol` (deploy + `preBuildMock` typeId-5
> guard + `build()` + `validate()`). FPS proposals *simulate* multisig actions rather than broadcast
> them, so the harness replays 012's `build()`/`validate()` **as real broadcast txs inline in bash**
> (the three `csend` actions + the `assert_eq` block) — same actions, same asserts, live on the vnet.
> On mainnet the actual multisig executes the FPS proposal itself.

Results log: `script/tenderly/harness-results-leveraged-aero.log`.

---

## Mainnet delta (short)

On real Base, the phases collapse:

- **Phase A/B** → Sherwood's normal **mainnet deployment** (no vnet, no fixture WOOD, no
  `SKIP_MULTISIG_HANDOFF`). Vault ownership handoff to `MAMO_MULTISIG` is **real** — no impersonation.
- **Phase C** → **Proposal 012 executed by the actual multisig**, not unlocked impersonation. At that
  point the `SHERWOOD_LEVERAGED_AERO_STRATEGY` / `SHERWOOD_SYNDICATE_VAULT` keys **are** committed to
  `addresses/8453.json` — safe then, because the code genuinely exists on mainnet and the eager
  `isContract` check passes.
- The **typeId-5 availability guard** still applies: `preBuildMock` in
  `multisig/mamo-multisig/012_DeployLeveragedAeroAccountSystem.sol` asserts
  `latestImplementationById(5) == address(0)` before whitelisting (the stale-counter-safe check).

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

**Sherwood stack live (Phase B):**

```bash
cast chain-id --rpc-url "$PUB"                                   # 8453
cast call "$STRAT" 'state()(uint8)'      --rpc-url "$PUB"        # 1  (Executed)
cast call "$STRAT" 'nav()(uint256)'      --rpc-url "$PUB"        # > 0
cast call "$STRAT" 'vault()(address)'    --rpc-url "$PUB"        # == $VAULT
cast call "$STRAT" 'proposer()(address)' --rpc-url "$PUB"        # == $BACKEND
cast call "$VAULT" 'owner()(address)'    --rpc-url "$PUB"        # == $MULTISIG
```

**Mamo wiring (after Phase C):**

```bash
cast call "$REG" 'whitelistedImplementations(address)(bool)' "$IMPL"      --rpc-url "$PUB"  # true
cast call "$REG" 'implementationToId(address)(uint256)'      "$IMPL"      --rpc-url "$PUB"  # 5
cast call "$REG" 'latestImplementationById(uint256)(address)' 5          --rpc-url "$PUB"  # == $IMPL
BR=$(cast call "$REG" 'BACKEND_ROLE()(bytes32)' --rpc-url "$PUB")
cast call "$REG" 'hasRole(bytes32,address)(bool)' "$BR" "$FACTORY"        --rpc-url "$PUB"  # true
cast call "$VAULT"   'openDeposits()(bool)'                               --rpc-url "$PUB"  # true
cast call "$FACTORY" 'strategyTypeId()(uint256)'                         --rpc-url "$PUB"  # 5
cast call "$FACTORY" 'sherwoodStrategy()(address)'                        --rpc-url "$PUB"  # == $STRAT
cast call "$FACTORY" 'usdc()(address)'                                    --rpc-url "$PUB"  # == $USDC
```

**End-to-end account (spot-check a created account `$ACCT`):**

```bash
cast call "$REG"  'isUserStrategy(address,address)(bool)' "$USER" "$ACCT" --rpc-url "$PUB"  # true
cast call "$ACCT" 'owner()(address)'                                     --rpc-url "$PUB"  # == $USER
cast call "$ACCT" 'sharesBalance()(uint256)'                            --rpc-url "$PUB"  # 0 after full withdraw
cast call "$USDC" 'balanceOf(address)(uint256)' "$ACCT"                 --rpc-url "$PUB"  # 0 clean state
```

---

## Current live instance — WILL ROTATE

> Snapshot of one instance for convenience. The vnet is **ephemeral by policy** (feeds stale within
> ~1 day of drift — constraint 2), so treat every value below as expiring. Re-run Phases A–C to mint a
> fresh one and update this table.

| Field | Value |
|---|---|
| vnet id | `8975a20b-5cf0-4399-9165-08e2b19229db` |
| chainId | `8453` |
| fork block | `48,901,646` |
| Admin RPC | `https://virtual.base.eu.rpc.tenderly.co/e6961d2a-4711-42eb-b4c1-2a42cbc17d28` |
| Public RPC | `https://virtual.base.eu.rpc.tenderly.co/70a4990f-6686-4536-8237-ad9103acd11b` |
| SyndicateVault | `0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9` |
| Strategy clone | `0x168ac730AB0DA6FCDE8aA26e33eac4aE6c8CfB4B` |
| SyndicateGovernor | `0x430FA5659cCf6E9c1586007a0A2B7760fb75e105` |
| Mamo impl | `0x3F26d1E36310442453d3aefCf75d5817eceBCF29` |
| Mamo factory (typeId 5, latest) | `0x9CDBe7DB9F967E793E7261e0ffd546E5D29b476f` |
</content>
