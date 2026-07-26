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

## MamoLeveragedAeroStrategy account harness

`run-leveraged-aero-account.sh` (dispatch: `./run-harness.sh leveraged-aero-account`, or
`make tenderly-leveraged-aero-account`) drives the **Mamo side** of the leveraged-Aero account
deployment against a LIVE, **persistent** Base-fork vnet on which the **Sherwood** stack
(`SyndicateVault` + `LeveragedAerodromeCLStrategy`) is already deployed, then smoke-tests the
account wrapper end-to-end. It replays multisig proposal `012_DeployLeveragedAeroAccountSystem`
plus the full user lifecycle as real broadcast txs, driven by Tenderly **unlocked impersonation**
(no private keys) for `MAMO_MULTISIG` / `DEPLOYER_EOA` / the strategy proposer / a fresh throwaway user.

| Phase | What it does |
|---|---|
| **2 — deploy** | `LeveragedAeroAccountHarness.deploy()` runs the real `LeveragedAeroAccountDeployer` (the same code proposal 012 calls) to deploy the impl + factory as `DEPLOYER_EOA`. |
| **3 — multisig** | As `MAMO_MULTISIG`: `whitelistImplementation(impl,5)`, `grantRole(BACKEND_ROLE, factory)`, `vault.setOpenDeposits(true)`; then reproduces every `validate()` assert via `cast` reads. |
| **4 — e2e** | Fresh throwaway user: `createStrategyForUser` → `deposit` → fast `withdraw(half)` → `requestWithdraw` → proposer `fulfillRedeem` → `claimWithdrawnUsdc` → `depositIdle` gate (third-party reverts, registry backend succeeds) → `withdrawAll` cleanup → clean-state asserts + net-delta report. |

**Why `--reuse` is forced.** The Sherwood strategy/vault exist only on the shared persistent vnet, so
this harness ALWAYS reuses `TENDERLY_VNET_RPC_URL` (point it at the vnet's **Admin RPC** — it accepts
`eth_sendTransaction` from any unlocked sender AND serves reads); it never creates or deletes a vnet.

**Address resolution.** The `SHERWOOD_LEVERAGED_AERO_STRATEGY` / `SHERWOOD_SYNDICATE_VAULT` keys are
deliberately NOT in `addresses/8453.json`: FPS `Addresses` validates `isContract` **eagerly** in its
constructor (gated on `chainId == block.chainid`), so committing them with `isContract:true` would
revert the `Addresses` constructor on every real-Base-mainnet CI run (no code lives there). They are
supplied via env vars (documented defaults = current vnet values) and injected at runtime inside
`LeveragedAeroAccountHarness.s.sol` with `addresses.addAddress(...)`.

**NEVER time-warp this vnet.** `evm_increaseTime` / `evm_setNextBlockTimestamp` age the frozen
Chainlink feeds and brick NAV for everyone (`StaleOracle`). This harness does no time travel; the
2-day `emergencyWithdraw` path is covered by unit tests only, not the live smoke.

**Config for consumers.** Every successful run regenerates
[`leveraged-aero-vnet.json`](./leveraged-aero-vnet.json) — the machine-consumable source of the
current vnet's addresses + public RPC for the frontend env, indexer, keeper, and rebalancer. Only
read-safe values go in it; the **admin RPC lives in 1Password**, never in git. Set
`TENDERLY_VNET_PUBLIC_RPC_URL` when running so the public RPC lands in the file.

### Future reference — redeploying / vnet ops crib

Vnets rotate **by design** (the frozen Chainlink feeds go stale in ~1 day of wall-clock drift, which
bricks `nav()`-priced paths). When the shared vnet is refreshed:

0. **Create the replacement vnet with STATE SYNC ENABLED** (creation-time only; cannot be changed
   afterward — API-verified). A synced instance keeps the Chainlink feeds fresh from Base mainnet,
   removing the ~1-day staleness brick entirely. Current shared instance (created 2026-07-21) has
   sync disabled — it stays on the rotation treadmill until replaced.
1. **Sherwood side first** — the vault + `LeveragedAerodromeCLStrategy` clone are deployed from the
   `sherwood-protocol` repo (not here). Full two-repo sequence:
   [`docs/LEVERAGED_AERO_VNET_RUNBOOK.md`](../../docs/LEVERAGED_AERO_VNET_RUNBOOK.md), Phases A–B.
2. **Mamo side** (this harness) — with the new vnet's admin RPC and the fresh Sherwood addresses:

   ```bash
   TENDERLY_VNET_RPC_URL=<admin-rpc> \
   TENDERLY_VNET_PUBLIC_RPC_URL=<public-rpc> \
   SHERWOOD_LEVERAGED_AERO_STRATEGY=<clone> SHERWOOD_SYNDICATE_VAULT=<vault> \
   make tenderly-leveraged-aero-account
   ```

   Deploys + wires + smokes everything and re-emits `leveraged-aero-vnet.json` — commit that diff so
   consumers pick up the new instance.

One-off ops against the vnet (all via the **admin** RPC, no keys — unlocked impersonation):

```bash
# fund ETH / USDC to any address
cast rpc tenderly_setBalance        '["<addr>","0x56BC75E2D63100000"]'                    --rpc-url "$ADMIN"   # 100 ETH
cast rpc tenderly_setErc20Balance   '["<usdc>","<addr>","0x2540BE400"]'                   --rpc-url "$ADMIN"   # 10,000 USDC

# act as any actor — e.g. fulfill an async withdrawal as the backend/proposer
cast send <strategyClone> 'fulfillRedeem(uint256)' <id> --from <MAMO_BACKEND> --unlocked --rpc-url "$ADMIN"

# read anything via the public RPC (share this one freely)
cast call <account> 'sharesBalance()(uint256)' --rpc-url <public-rpc>
```

```bash
# current vnet values are the built-in defaults; override to point elsewhere
TENDERLY_VNET_RPC_URL=<admin-rpc> make tenderly-leveraged-aero-account
```

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
  injects the vnet-only `SHERWOOD_*` keys at runtime.
- `TenderlySwapHelper.sol` — a tiny deployed swap-callback holder for the price-sim matrix; a
  forge Script can't be its own `uniswapV3SwapCallback`, so `pushTick` routes swaps through this.

**Orchestrators / shell:**

- `run-harness.sh` — dispatcher: routes to `run-lpv2.sh` (default), `run-lpv2-matrix.sh`, or
  `run-price-checker.sh` (see Usage).
- `run-lpv2.sh` — LPAutoBalancerV2 lifecycle orchestrator (balanced + single-sided scenarios).
- `run-lpv2-matrix.sh` — LPAutoBalancerV2 price-simulation scenario matrix (calm reset → in range,
  large move → single-sided, calm-gate → `TwapDeviation`, stale-oracle → `StaleOracle`), each off a
  fresh `evm_snapshot`.
- `run-price-checker.sh` — SlippagePriceChecker gate against the live checker + real Chainlink config.
- `run-leveraged-aero-account.sh` — MamoLeveragedAeroStrategy account deploy-drive + e2e smoke against
  the persistent Sherwood vnet (unlocked impersonation; always `--reuse`). See section above.
- `setup-staging.sh` — stands up a **persistent** frontend staging vnet (not torn down after the run).
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
