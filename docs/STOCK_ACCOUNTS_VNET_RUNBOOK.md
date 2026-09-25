# Stock accounts: deploy and vnet runbook

How to stand up the stock accounts system on a fresh Tenderly virtual testnet, and how the Base
mainnet deployment is executed.

The two paths are deliberately separate. `script/DeployStockAccounts.s.sol` is the **vnet** path,
driven by `script/stock-accounts/vnet-up.sh`; it impersonates unlocked admins, which no Safe can do.
`multisig/mamo-multisig/016_DeployStockAccountSystem.sol` is the **mainnet** path: one deploy and one
signable Safe batch. See [Mainnet: proposal 016](#mainnet-proposal-016).

## Prerequisites

`.env` at the repo root with:

- `BASE_RPC_URL` — Base mainnet RPC, used by the `base` alias in `foundry.toml`
- `TENDERLY_ACCESS_KEY`, `TENDERLY_ACCOUNT_SLUG`, `TENDERLY_PROJECT_SLUG` — used to create the vnet
- `TENDERLY_VNET_RPC_URL` — only for reuse mode, see below

`jq`, `curl`, `forge` and `cast` on the path.

## One command

```bash
make tenderly-stock-accounts
```

It creates a fresh Base fork vnet (chain id 8453, state sync off, slug `stock-accounts-<timestamp>`),
funds the deployer, the Mamo multisig and the test user with ETH and the test user with 10,000 USDC,
copies `addresses/` to the gitignored `script/stock-accounts/addresses-vnet/` so the repo address book
is never touched by a vnet run, then runs, against the vnet admin RPC with `--broadcast --unlocked`:
the pool readiness script, the deploy, the smoke script, and finally the four B20 listings the deploy
can only print (see step 8). The listings go last on purpose — see below.

Reuse an existing vnet instead of creating one:

```bash
VNET_REUSE=1 TENDERLY_VNET_RPC_URL=<admin rpc> make tenderly-stock-accounts
```

In reuse mode the address book copy is kept, so every deploy step that already ran is skipped, and the
smoke script is skipped too: the stock tokens are listed by then, and no forge script can read an
account's NAV after that (see below). The whole rerun is a no-op.

## What it deploys, in order

1. `StockAccountRegistry(Config)` — the per-chain rulebook, recorded as `STOCK_ACCOUNT_REGISTRY`,
   deployed with the placeholder price checker (see Configuration)
2. `StockAccountPriceChecker(registry, USDC, existingPriceChecker)` — recorded as
   `STOCK_ACCOUNT_PRICE_CHECKER`; the third argument is the audited `SlippagePriceChecker` that
   every `PriceSource.Chainlink` token is priced against (see Configuration)
3. admin: `StockAccountRegistry.setPriceChecker(checker)` — replaces the placeholder
4. `StockAccountStrategy` implementation — recorded as `STOCK_ACCOUNT_STRATEGY_IMPL`
5. admin: `MamoStrategyRegistry.whitelistImplementation(impl, strategyTypeId)` — the id comes from the
   deploy config (ids 1-4 are all taken on Base; the stock account implementation takes **5**)
6. `StockAccountStrategyFactory(...)` — recorded as `STOCK_ACCOUNT_STRATEGY_FACTORY`
7. admin: `MamoStrategyRegistry.grantRole(BACKEND_ROLE, factory)` so the factory can call `addStrategy`
8. every entry of `config/stock-accounts/8453.json`, in two parts:
   - **8a**, only for a `Chainlink` entry: admin calls on `existingPriceChecker` —
     `addTokenConfiguration(token, USDC, [feed, USDC/USD reversed])` and
     `setMaxTimePriceValid(token, heartbeat)`. That checker has its **own owner**, the Mamo multisig,
     which is not the stock registry admin, so on mainnet these two go to the Safe even when the
     registry admin is an EOA. Both are skipped when the pair is already configured.
   - **8b**: admin `StockAccountRegistry.listToken(...)`, one per entry. Each listing is probed
     against the registry's current price checker and refused with `TokenNotPriceable` unless one
     whole token quotes into `asset`, so step 3 has to land first — and, for a `Chainlink` token, so
     does 8a: the probe routes straight through `existingPriceChecker`, which quotes nothing for an
     unconfigured pair.

If a Chainlink pair is ever removed from `existingPriceChecker` after its token is listed, a re-run of
the deploy does **not** restore it: step 8b sees the token already listed and skips the entry before
step 8a runs. The repair is manual — call `addTokenConfiguration(token, USDC, [feed, USDC/USD
reversed])` and `setMaxTimePriceValid(token, heartbeat)` on the checker as its own owner, with the
values from the token list and `USDC_USD_HEARTBEAT` for the second hop.

Every step checks the address book (steps 1, 2, 4, 6) or the onchain state (steps 3, 5, 7, 8) first,
so a rerun against the same address book is a no-op. Deploying a name that is already recorded is
refused by the address book rather than silently overwritten.

### Listing a B20 token is node-only

This is a standing property of the system, not a workaround. `listToken` probes the token through
`_requirePriceable`, which calls `decimals()` on it. A B20 stock token's code is the single reserved
byte `0xEF`: the real node serves it, revm refuses to execute it (see "Why the smoke test only deposits
USDC"). `forge script` always simulates locally before broadcasting, so a B20 listing can never run
through a forge script — pointing it at the vnet does not help.

So, for a B20 token, step 8b runs:

- **on mainnet**, from the Safe, inside proposal 016's batch;
- **on the vnet**, from `cast send` — `vnet-up.sh` sends the four listings itself after the deploy
  script, the same way `prepare.sh` lists NVDAc.

`impersonate` mode recognises the `0xEF` byte, prints that listing's calldata and moves on rather than
reverting. A fork rehearsal of `listToken` for a B20 token needs a stand-in token; there is no way to
run the real one under revm. That is what proposal 016's `preBuildMock` does — it etches a minimal
8-decimal ERC20 over each token whose code is exactly that byte — and it is why the listings reach the
batch instead of reverting the build. The calldata the Safe receives still targets the real token
addresses. cbBTC is an ordinary contract and lists normally in every mode.

The same byte has a second, wider consequence: `getNAV` values an account by scanning
`registry.allTokens()` and reading each token's balance, so **once a B20 token is listed, no forge
script can touch an account at all** — not `getNAV`, not `deposit`, which checks the account value.
That is why `vnet-up.sh` runs the smoke script *before* it sends the four listings, and why a reuse run
skips the smoke and says so. Everything after that point is the `cast`-driven scenario harness.

The one exception is a process that has already etched the stand-ins, which is why
`test/StockAccountSystemSetup.integration.t.sol` can run a whole account lifecycle after all five
listings: the four stand-ins answer `balanceOf` with zero, so they drop out of valuation and the real
cbBTC leg is what gets priced.

### Ordering, and what it means for the Safe batch

Two hard constraints, both from the probe at the end of `listToken`:

- `setPriceChecker` (step 3) must land before any `listToken`, or the probe goes to the placeholder;
- for a `Chainlink` token, step 8a must land before its `listToken`, or the probe delegates into the
  legacy `SlippagePriceChecker` and reverts with `Token pair not configured`.

In `calldata` mode the probe never runs locally — the script only prints — so nothing catches a wrong
order until the Safe executes. Keep every `listToken` after `setPriceChecker` in the same batch, and
each Chainlink pair configuration before its own `listToken`. One failing probe reverts the whole
batch. The order the script prints is already correct; do not reorder it.

## Admin steps: the two modes

`ADMIN_MODE=impersonate` (default) sends the admin calls from the role holder — the Mamo multisig for
the `MamoStrategyRegistry` calls, the configured `admin` for the stock registry. This only works where
accounts are unlocked, i.e. a Tenderly vnet or anvil.

`ADMIN_MODE=calldata` prints `from`, `to` and the calldata of each admin call and executes none of
them. It is a **dry-run aid**, not the mainnet path — the mainnet path is proposal 016, below, which
assembles the same calls into one batch and then proves the end state. The strategy type id is
**chosen, in the deploy config, never auto-assigned**. The registry's
`nextStrategyTypeId()` counter only moves when an implementation is whitelisted with a zero id, and
every whitelist since the USDC strategy has passed an explicit one, so the counter is a stale lower
bound rather than the next free slot: it reads 4 while slot 4 already holds the Moonwell Morpho V2
implementation. Auto-assigning would overwrite that entry, which would stop new accounts of that type
being created and would repoint its upgrades at the wrong implementation.

The script therefore refuses to proceed unless the configured id is free and sits above the counter,
and the factory can still be deployed before the Safe executes the whitelist, because the id no longer
depends on when that happens.

Dry run (no broadcast, writes to a throwaway copy of the address book):

```bash
make deploy-stock-accounts                     # DEPLOY_ENV defaults to 8453_TESTING
DEPLOY_ENV=8453_PROD make deploy-stock-accounts
```

Both environments now run all the way through: `STOCK_ORDER_SIGNER` and `F-MAMO` — the PROD
`orderSigner` and `feeRecipient` — are both in `addresses/8453.json`.

## Mainnet: proposal 016

`multisig/mamo-multisig/016_DeployStockAccountSystem.sol` is the mainnet deployment. It is an FPS
`MultisigProposal`, so it deploys, assembles the Safe batch, simulates it through a Safe and asserts
the end state, all from the committed `deploy/stock-accounts/8453_PROD.json` and
`config/stock-accounts/8453.json`.

**One Safe is what makes one batch possible.** On PROD the stock registry admin, the
`MamoStrategyRegistry` `DEFAULT_ADMIN_ROLE` holder and `CHAINLINK_SWAP_CHECKER_PROXY`'s `owner()` are
all `MAMO_MULTISIG`. `preBuildMock` asserts that identity rather than assuming it; if any of the three
moves, the proposal stops being executable as one batch and has to be split.

The batch, in order — the order is load-bearing for the same two reasons as the script's
(see [Ordering](#ordering-and-what-it-means-for-the-safe-batch)):

1. `STOCK_ACCOUNT_REGISTRY.setPriceChecker(STOCK_ACCOUNT_PRICE_CHECKER)`
2. `MAMO_STRATEGY_REGISTRY.whitelistImplementation(impl, 5)` — the **configured** id, never auto-assigned
3. `MAMO_STRATEGY_REGISTRY.grantRole(BACKEND_ROLE, STOCK_ACCOUNT_STRATEGY_FACTORY)`
4. `CHAINLINK_SWAP_CHECKER_PROXY.addTokenConfiguration(cbBTC, USDC, [BTC/USD, USDC/USD reversed])`
5. `CHAINLINK_SWAP_CHECKER_PROXY.setMaxTimePriceValid(cbBTC, 3600)`
6-10. `STOCK_ACCOUNT_REGISTRY.listToken(...)` for AAPLc, cbBTC, GOOGLc, METAc, NVDAc

Run it against a Base fork:

```bash
# DEPLOY_ENV is not read here: the proposal is pinned to deploy/stock-accounts/8453_PROD.json
forge script multisig/mamo-multisig/016_DeployStockAccountSystem.sol:DeployStockAccountSystem \
  --fork-url base --ffi -vvv
```

**The address book is not written unless you ask.** FPS gates that on `DO_UPDATE_ADDRESS_JSON`, which
defaults to **false**; the run only prints the four new keys (`STOCK_ACCOUNT_REGISTRY`,
`STOCK_ACCOUNT_PRICE_CHECKER`, `STOCK_ACCOUNT_STRATEGY_IMPL`, `STOCK_ACCOUNT_STRATEGY_FACTORY`). Add
`DO_UPDATE_ADDRESS_JSON=true` on the run whose deployed addresses you want committed, and only then.

**Known discrepancy: two MultiSend addresses.** The simulator hard-codes
`0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761` (`Constants.SAFE_MULTISEND_COTNRACT` in the FPS library)
as the `delegatecall` target of its simulated `execTransaction`, while `docs/SAFE_CALLDATA_GUIDE.md`
tells the signer to use `0x40A2aCCbd92BCA938b02010E17A5b8929b49130D`. Both are canonical Safe v1.3.0
deployments, and the labels are the other way round from what you might assume: the simulator's
`0xA238…7761` is **MultiSend** (629 bytes, carrying the "should only be called via delegatecall"
guard) and the guide's `0x40A2…130D` is **MultiSendCallOnly** (410 bytes, no such branch). Identified
by their runtime bytecode, not by a registry. Every action in this batch is a plain call, so either
one produces the same ten calls, and the guide's choice of the call-only variant is the safer of the
two. Whoever builds the Safe transaction follows the signing guide, not the simulator.

**The Safe is v1.4.1, and that changes the hash.** `MAMO_MULTISIG` reports version 1.4.1 with a
threshold of 2. The Safe web interface builds a 1.4.1 batch against the v1.4.1 call-only contract at
`0x9641d764fc13c8B624c04430C7356C1C7C8102e2`, which is a different `to` from the one in the signing
guide. The ten inner calls are identical either way, but the transaction hash signers compare is not,
so **agree which `to` is being signed before anyone starts comparing hashes** — otherwise a correct
batch looks like a mismatch.

**The batch cannot be built before the contracts exist.** Eight of the ten actions name contracts the
deploy step creates, so the calldata and its hash depend on the deployer's nonce at the time. The
order is: run the deploys, re-run the proposal to print the batch against the addresses that actually
landed, then build and sign the Safe transaction. Do not pre-sign, and do not let the deployer send
anything else in between.

**Fund the deployer first.** The four deployments measured 9.34M gas on a fork, and that figure is
only the execution half: Base also charges for posting roughly 40 KB of creation code to L1. Check the
balance against both before starting rather than discovering it midway through the sequence.

The fork rehearsal of all of this is `test/StockAccountSystemSetup.integration.t.sol`
(`make stock-accounts-setup`): it drives 016 hook by hook at a pinned block, checks the ten recorded
actions, then runs a real cbBTC account through create, deposit, valuation, withdrawal and a fee
settlement.

## Configuration

`deploy/stock-accounts/8453_PROD.json` and `deploy/stock-accounts/8453_TESTING.json` hold the registry
parameters; every address field is an FPS address **name** resolved against `addresses/8453.json`.

`placeholderPriceChecker` is `CHAINLINK_SWAP_CHECKER_PROXY` in both environments. It is a permanent
bootstrap detail, not a stopgap: the registry constructor needs a price checker that has code, and
the real `StockAccountPriceChecker` needs the registry address, so the registry is born with the
placeholder and step 3 immediately points it at the checker deployed in step 2. Any address with code
works; nothing is ever priced through the placeholder.

`existingPriceChecker` is also `CHAINLINK_SWAP_CHECKER_PROXY` in both environments, but it is load
bearing: it is the audited checker the step 2 constructor keeps, and every token listed with
`PriceSource.Chainlink` is routed to it. Tokens listed as `PoolTwap` never reach it.

TESTING differs from PROD in one way: `admin`, `guardian` and `feeRecipient` are `DEPLOYER_EOA`, so a
vnet run needs no impersonation for the stock registry itself — step 3 and step 8 run directly. The
`MamoStrategyRegistry` steps still run as `MAMO_MULTISIG`, and so does step 8a, which goes to
`existingPriceChecker`'s own owner in both environments. On PROD every admin step goes to the Safe.

`config/stock-accounts/8453.json` is the token list. It holds five entries: the four launch stocks —
AAPLc, GOOGLc, METAc, NVDAc — priced from their Aerodrome CL pool against USDC, and cbBTC priced from
Chainlink through `existingPriceChecker`. One of each kind, abridged from the committed file:

```json
{"tokens":[
  {"chainlinkFeed":"0x0000000000000000000000000000000000000000","decimals":8,"heartbeat":0,
   "pool":"0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9","source":"PoolTwap","symbol":"NVDAc",
   "token":"0xb20000000000000000000078ee7ce2fE4908108C"},
  {"chainlinkFeed":"0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F","decimals":8,"heartbeat":3600,
   "pool":"0x160D7E9d948B16c163332a277b393c288408eb12","source":"Chainlink","symbol":"cbBTC",
   "token":"0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf"}
]}
```

`source` is `PoolTwap` or `Chainlink`, `heartbeat` is the Chainlink feed's staleness bound in seconds —
it is both the first hop's heartbeat and the `setMaxTimePriceValid` value — and every token is listed
as `Active`. A `PoolTwap` entry still carries a `pool` — the registry refuses a listing without one —
and writes the zero feed with a zero heartbeat.

`decimals` is carried in the file rather than read off the token, because the four B20 tokens cannot
be read at all from a fork (see [Listing a B20 token is node-only](#listing-a-b20-token-is-node-only)).
Proposal 016 needs it for the stand-in it puts over them, and every one-whole-token price probe needs
it. All five launch tokens are 8-decimal. `loadTokenList` rejects a zero.

The second hop, USDC/USD, is not configured from the file: `USDC_USD_HEARTBEAT` — the same constant in
both `DeployStockAccounts` and proposal 016 — fixes it at **90,000 seconds**, deliberately above the
feed's nominal 86,400 heartbeat. Walking the live Base aggregator
`0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` over 31.8 days, 31 of its 32 round gaps ran past 86,400 —
median 86,418, longest 86,490 — so the node fires tens of seconds late almost every cycle. The checker
enforces the bound strictly and valuation has no `try`/`catch`, so at 86,400 the cbBTC quote would
revert for roughly a minute a day and take account value, weights, both deposits, every withdrawal,
the preview, the fee and order validation down with it for any account holding it.
**Do not tighten it back to the nominal heartbeat.** The cbBTC hop's own 3,600 is loose the other way —
that feed's real interval measures 1,200 with a longest gap of 1,232 — and is left as it is, matching
how `config/strategies/cbBTCStrategyConfig.json` configures the same feed.

Three rules the file has to follow, because `vm.parseJson` types each JSON value by its shape and the
whole `.tokens` array is decoded as one Solidity type:

- every entry carries every key, in alphabetical order;
- an unused feed is the **zero address**, never `""` — a missing key does revert the decode, but a key
  of the wrong type in the right position does not: `""` is encoded as a string and reads back as the
  ABI offset `0x…C0`, a nonzero garbage address. `StockAccountsConfig._validate` and the exact
  addresses pinned in the unit test are what catch that, not the decode;
- entries are sorted by symbol, which is only cosmetic.

`loadTokenList` validates every entry it decodes — token, pool and decimals non-zero, `source` exactly
one of the two legal strings, feed and heartbeat non-zero exactly when the source is `Chainlink` — so a bad
entry fails at load rather than reaching an admin batch that only breaks when the Safe executes it.
`test/StockAccountsConfig.unit.t.sol` runs that load against the committed file in CI, pinning all five
entries by exact address and counting the pool-priced ones.

`asset` (USDC) is the quote asset: it goes to the registry constructor, the price checker and the
factory. The registry probes every listing and every raise back to `Active` through it, so a token
the checker cannot quote — no pool against `asset`, or a pool whose history is shorter than
`twapWindow` — is refused at listing instead of breaking `getNAV` for every holder. Lowering a
token to `SellOnly` or `Halted` never probes.

### Pool readiness

A `PoolTwap` token is only listable once its pool can serve a `twapWindow`-long `observe`, which needs
enough observation slots in the pool's ring. `script/StockAccountsPoolReadiness.s.sol` reports and, when
short, grows them:

```bash
make stock-pool-readiness                                  # every PoolTwap pool in the token list
POOLS=0x3F53aFD15909bF5B1c5963b5C0D28123668ce174 make stock-pool-readiness
```

The target is `twapWindow / 2 x 2`, capped at `type(uint16).max`: Base produces a block about every two
seconds, so a 180-second window needs about 90 observations, and the ring is sized at twice that for
headroom — **180 for the configured 180-second window**. `twapWindow` is read from the deployed
registry when `STOCK_ACCOUNT_REGISTRY` is in the address book, and from the deploy config before that.

The script only sends `increaseObservationCardinalityNext` to a pool whose `observationCardinalityNext`
is below the target, so a second run sends nothing. All four launch pools already sit at 2048 and are
untouched:

```
twap window: 180 seconds, required cardinality: 180
AAPLc  0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0  2048/2048 required 180
  serves window: yes
```

`POOLS` overrides the token list with a comma-separated pool list, which is how the grow path is
demonstrated without touching a launch pool. The cbBTC/USDC pool at
`0x3F53aFD15909bF5B1c5963b5C0D28123668ce174` is still at cardinality 1:

```
POOLS  0x3F53aFD15909bF5B1c5963b5C0D28123668ce174  1/1 required 180
  grown to 1/180
  serves window: yes
```

`observationCardinality` itself only moves later, when the pool next writes an observation; `next` is
the slot count the pool has paid for.

The `serves window` line is **information, never a gate**. `observe` can succeed on a ring that has not
filled yet (a pool with one stale observation extrapolates), and it fails on a freshly grown ring that
has not accumulated blocks. Only `listToken` decides, through the registry's own probe.

`vnet-up.sh` runs the readiness script against the vnet just before the deploy, so a fresh fork has its
pools grown before step 8 probes them.

`setPriceChecker` and `setTwapWindow` change what "priceable" means for every listing at once, so both
apply the new value first and then re-probe every token that is not `Halted`, reverting the whole call
with `TokenNotPriceable(token)` if any of them stops quoting. A window no pool can serve is therefore
refused rather than silently bricking every holder's valuation. One broken pool blocks both calls until
that token is halted, which is deliberate: auto-halting would change account value as a side effect of
an unrelated admin action. Both calls probe on-chain, so they are not cheap — on a Base fork one
pool-TWAP listing costs about 107k gas and one Chainlink listing about 113k.

## Why the smoke test only deposits USDC

B20 stock tokens are node-native precompiles on Base: their code is the single byte `0xef`, which revm
refuses to execute. A foundry fork therefore cannot call them at all — no `balanceOf`, no `transfer`.
Anything touching a real stock token (pricing, rebalancing, in-kind withdrawals) has to run on the
Tenderly vnet, where the node serves the precompile, and not in `forge test`.

`StockAccountsSmoke` therefore creates an all-cash account (empty basket, `cashTargetBps = 10000`),
deposits 1,000 USDC and asserts `getNAV() == 1_000e6`. No token pricing is involved. It also asserts
the registry points at `STOCK_ACCOUNT_PRICE_CHECKER`.

`getNAV` still reads a balance for **every** listed token before it prices anything, so the smoke has
to run before the four B20 listings — which is exactly where `vnet-up.sh` puts it. After them, that
account can only be read with `cast`.

## The management fee

Every account charges the registry's `managementFeeBps` — 100 bps a year in both deploy configs — on
its whole NAV. Nothing is accrued in storage: `payFees(token)` values the fee as
`NAV x rate x elapsed / (10000 x 365 days)` in USDC, converts that to `token` at the price checker's
reference, sends it to the fee recipient and emits `FeesPaid(credited, token, amount)` with `token`
indexed. It is permissionless.

**A payment the balance cuts short only settles the part of the period it covers.** The clock moves
by `elapsed x amount / full`, not to now, so a payment out of a balance that covers a tenth of the
fee leaves nine tenths of the period owed for the next one. One wei of a token therefore buys
nothing: it settles the wei's worth of seconds and no more. A fee that converts to zero of the chosen
token — the period is so short that it is worth less than one unit of an 8 decimal stock — pays
nothing and moves nothing, rather than reverting or forgiving the period.

**The fee is paid in the token the account receives.** `token` has to be USDC or a listed token that
is neither unlisted nor Halted, otherwise `FeeTokenNotAllowed(token)`; a zero balance of it is
`NoBalanceForFee(token)` and the clock does not move. `feeDue()` is the USDC value owed right now,
`feeDueIn(token)` the same fee expressed in that token.

Three things call it:

- **The CoW post-hook.** An order's appData declares one post-hook, `payFees(buyToken)` on the account
  itself, with a 1,000,000 gas limit. So an order buying NVDAc pays its fee in NVDAc and an order
  selling NVDAc for USDC pays in USDC — the account never has to sell anything to pay, it just keeps a
  little less of what it is about to receive. CoW runs the hook inside the settlement, after the trade
  legs, so the fee is valued on the post-trade NAV. Every position is one more pool TWAP read in that
  NAV, so the cost grows with the basket: at `maxPositions` of 10, on a registry listing eleven tokens,
  the vnet measures `payFees` at 667,000 gas, about 1.5x inside the limit the document declares.
- **Withdrawals.** They pay the fee before they pay the owner, so nobody leaves ahead of it.
  `withdraw` and `withdrawAll` pay in USDC, after their sells. `withdrawToken(token)` pays in that
  token; if it is Halted or unlisted the fee falls back to USDC and then to the sellable stocks.
  `withdrawAllInKind` pays from USDC and then walks the listed tokens, stopping as soon as the period
  is settled, because the account is empty when it returns and anything left uncollected there is
  uncollectable forever. It only moves the clock outright when the NAV is zero, which is the one case
  where nothing is owed.
- **A poke.** An account that neither trades nor withdraws just keeps owing more; the backend calls
  `payFees(token)` on it directly, naming whichever balance it wants the fee taken out of.

The rate lives on the registry, one for every account: `managementFeeBps` in the deploy config, then
`setManagementFeeBps` from the admin, capped by the immutable `maxManagementFeeBps` of 200.

Before changing it, settle every account, and check `feeDue()` reads zero afterwards. The rate is
read when the fee is paid and applied to the period that payment settles, so a backlog left behind
is charged at the new rate. A poke is not enough on its own: `payFees(token)` out of a balance that
cannot cover `feeDueIn(token)` credits only its slice and leaves the rest owed, so settle out of
USDC, or out of a token whose balance covers the fee, and read `feeDue()` back to confirm.

## CoW appData

There is one appData document per **(account, buy token)**: the post-hook target is the account and
its argument is the token the order buys. The account is the source of truth for both:

```bash
cast call <account> 'appDataDocument(address)(string)' <buyToken> --rpc-url "$RPC"
cast call <account> 'appDataHash(address)(bytes32)' <buyToken> --rpc-url "$RPC"
```

The first time the backend places an order for an account that buys a given token, it uploads that
account's document for that token to the CoW API under its hash. Nothing is stored onchain, so the
document can be rebuilt at any time. `cast` already prints it as a JSON string, which is the shape
`fullAppData` wants:

```bash
HASH=$(cast call <account> 'appDataHash(address)(bytes32)' <buyToken> --rpc-url "$RPC")
DOC=$(cast call <account> 'appDataDocument(address)(string)' <buyToken> --rpc-url "$RPC")
curl -X PUT "https://api.cow.fi/base/api/v1/app_data/$HASH" \
  -H 'content-type: application/json' -d "{\"fullAppData\": $DOC}"
```

Every order has to carry the hash for its own buy token: `isValidSignature` compares
`order.appData` against `appDataHash(order.buyToken)` and refuses anything else with `InvalidAppData`,
so an order cannot settle unless its hook takes the fee in the token that order buys.

## The manifest

`script/stock-accounts/vnet-manifest.json` (gitignored) is written by the smoke script and is what the
backend or a follow-up script reads to pick the vnet up: the admin `rpc`, `chainId`, every
`STOCK_ACCOUNT_*` and `AERODROME_STOCKS_*` address, the `strategyTypeId`, the test user with the
account created for them, and that account's USDC document as `appDataHashUsdc` and
`appDataDocumentUsdc` — the cash leg, since documents are per buy token and the smoke account is all
cash. Forge writes the document inlined as JSON rather than as a string, so `jq -c` is what reproduces
the bytes the hash is over.

```bash
jq -r '.rpc' script/stock-accounts/vnet-manifest.json
cast call "$(jq -r '.testUserAccount' script/stock-accounts/vnet-manifest.json)" 'getNAV()(uint256)' \
  --rpc-url "$(jq -r '.rpc' script/stock-accounts/vnet-manifest.json)"
cast keccak "$(jq -c '.appDataDocumentUsdc' script/stock-accounts/vnet-manifest.json)"   # appDataHashUsdc
```

## Scenarios

`script/stock-accounts/scenarios/` is a scenario harness that exercises a deployed stock account
system end to end: CoW settlement, withdrawals, a price spike, the account lifecycle, and the gas
cost of order validation as a basket grows.

```bash
make tenderly-stock-accounts-scenarios
```

It runs against whatever vnet `script/stock-accounts/vnet-manifest.json` points at, so a fresh vnet is
just `make tenderly-stock-accounts` followed by the line above. Every run derives its actor addresses
from a new run id, so rerunning against the same vnet never collides with accounts an earlier run
created. State that has to survive a rerun — the settlement helper address, the run id — lives in the
gitignored `scenarios/.state/`.

### Why it is cast-driven and not a forge script

B20 stock tokens are node-native precompiles whose code is the single byte `0xef`. `forge script`
executes the script locally in revm before broadcasting, and revm refuses to execute that byte, so a
script step that moves a stock token fails even when it is pointed at the vnet. Every state change
here is therefore a transaction the Tenderly node executes (`cast send --unlocked --from`), every read
is a `cast call`, and Solidity appears only as `SettlementHelper.sol`, deployed to the vnet so that its
code runs on the node. USDC balances come from `tenderly_setErc20Balance` and time from
`evm_increaseTime`; stock tokens cannot be minted and are always bought on the stocks router.

`SettlementHelper` is registered as a CoW solver by impersonating the allow-list manager on the vnet.
It builds the `tokens`/`clearingPrices`/`trades` arrays for `GPv2Settlement.settle`, signs each trade
with the EIP-1271 scheme (the owner address followed by the encoded order and the backend signature
over its digest), and either sources the buy token from the stocks pool in the intra-settlement
interactions or nets two accounts against each other with no interaction at all. It also carries, as a
post-interaction, the hook each account's appData declares: `payFees(buyToken)` on the account, one per
account in the settle, each naming that account's own buy token. Real CoW routes hooks through the
`HooksTrampoline`; calling the account straight from the settlement is equivalent because `payFees` is
permissionless.

Every order an account accepts also carries a signature by `StockAccountRegistry.orderSigner`, so
being an allow-listed solver is not enough to author one. `prepare.sh` points the registry at
`0xc419099bfA195fe92e57d137dFe3b2116E9203fe`, a public test key that is fine on a vnet, and asserts it
has no code before use: the anvil accounts cannot serve here because each carries an EIP-7702
delegation on Base, which would make it an ERC-1271 signer rather than the plain EOA the harness signs
with.

`prepare.sh` still calls `ensure_listed NVDAc`, which is now a no-op: the deploy lists all four stocks
before the harness ever runs, so the registry already holds four B20 tokens plus cbBTC when the first
scenario starts. `05-gas.sh` likewise skips the four and lists whatever else it discovers,
up to its target of ten. cbBTC is not a B20 token, so it never appears in that discovery — it is listed
by the deploy and nothing else in the harness touches it.

One consequence of a registry with more than one token: `getWeights` returns **every listed token**, in
registry order, not just the account's own basket. A scenario reading a token's weight therefore looks
its row up by address (`weights_index`) instead of taking the first one.

### What each scenario proves

| Scenario | Proves |
| --- | --- |
| `01-settlement.sh` | An order priced inside the account slippage cap is accepted by `isValidSignature` and settles; the appData post-hook pays a day of fee in the token the order buys — NVDAc for the buy-in, the collector's USDC untouched; the same order carrying the document for the sell token is refused with `InvalidAppData`; NAV and weights survive the trade; the same trade sized past the band is refused by the account and therefore by the settlement; a solver-authored order with no backend signature is refused both ways and accepted once signed; two accounts on opposite sides of NVDAc/USDC net in one `settle` with no venue, the buyer paying its fee in NVDAc and the seller in USDC. |
| `02-withdrawals.sh` | Idle cash is paid out without touching a pool; a shortfall sells exactly what `previewWithdraw` planned and pays the owner the exact amount asked; when spot falls below the 180s average the router floor derived from that average blocks the sale instead of realising the gap. |
| `03-spike.sh` | After a 3x move the average has absorbed, the account reads far overweight, selling into the spike is accepted and settles, buying more is refused by the range rule, and unwinding the spike restores both the reference and the buy side. |
| `04-lifecycle.sh` | `computeStrategyAddress` predicts the created account; buy-in, `setBasket`, and a cash withdrawal behave; a month of management fee is paid in USDC by the next `withdraw` before the owner is paid; `withdrawToken(NVDAc)` pays in NVDAc and a `payFees(NVDAc)` poke settles an idle account out of its position; a Halted token leaves the NAV while remaining held and withdrawable in kind, can no longer settle the fee (`FeeTokenNotAllowed`), and the withdrawal that sends it pays out of the cash instead. |
| `05-gas.sh` | Discovers the B20/USDC pools on the stocks factory, lists up to ten of them — the four the deploy already listed are skipped and more are added — measures `isValidSignature` gas for accounts holding 2, 4 and 10 positions, and checks `payFees` on the widest of them fits the 1,000,000 gas the appData post-hook is given. |

Two things the range rule makes concrete and the scenarios assert. An account sitting on its targets
can move at most `maxDeviationBps` of its NAV in a single order, so a rebalance larger than that has
to be split. And in a two-asset account — cash plus one stock — `SellLeavesTokenBelowRange` and
`BuyLeavesTokenAboveRange` are the same condition read from either leg; `_checkRange` evaluates the
sell rule first, so the sell-side error is the one an out-of-range order always returns.

### Reading the results

`scenarios/results.json` (gitignored) is written as the run goes:

```json
{"setup": {"runId": "…", "settlementHelper": "0x…", "accountA": "0x…"},
 "checks": [{"scenario": "01-settlement", "check": "…", "pass": true, "value": "…"}]}
```

`run.sh` prints the same rows as a table at the end and exits with the number of failed checks, so it
is usable as a gate. Individual scenarios can be run on their own; they read the helper address from
`results.json` or `.state/`, and `CT11_RUN_ID` pins the actor addresses across separate invocations.
