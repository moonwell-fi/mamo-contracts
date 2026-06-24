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

## vnet resolution

Mirrors the goal's "(a) spin up a vnet **or** (b) use the url in `.env`":

- **(a)** If `TENDERLY_ACCESS_KEY` + `TENDERLY_ACCOUNT_SLUG` + `TENDERLY_PROJECT_SLUG` are set
  (and `--create` or no `TENDERLY_VNET_RPC_URL`), the orchestrator creates a fresh Base-fork vnet
  via the Tenderly API (the same REST flow as `moonwell-tenderly/scripts/setup-forks.ts`) and
  tears it down at the end unless `--keep`.
- **(b)** Otherwise it uses `TENDERLY_VNET_RPC_URL` from `.env` and never deletes it.

## Files

- `LPV2TenderlyHarness.s.sol` — the Foundry script. Multiple `--sig` entrypoints
  (`deployAndMint`, `registerStake`, `checkRoleGating`, `doReset`, `doExit`, `checkCalmGate`) so
  the orchestrator can interleave Tenderly cheat-RPCs (funding, time advance) between phases.
- `run-harness.sh` — the orchestrator (vnet lifecycle, funding, clock/oracle handling, reporting).
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
