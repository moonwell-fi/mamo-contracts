# Stock accounts: deploy and vnet runbook

How to stand up the stock accounts system on a fresh Tenderly virtual testnet, and how the same
scripts are used for a Base mainnet deployment.

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
is never touched by a vnet run, then runs the deploy and the smoke script against the vnet admin RPC
with `--broadcast --unlocked`.

Reuse an existing vnet instead of creating one:

```bash
VNET_REUSE=1 TENDERLY_VNET_RPC_URL=<admin rpc> make tenderly-stock-accounts
```

In reuse mode the address book copy is kept, so every deploy step that already ran is skipped.

## What it deploys, in order

1. `StockAccountRegistry(Config)` — the per-chain rulebook, recorded as `STOCK_ACCOUNT_REGISTRY`,
   deployed with the placeholder price checker (see Configuration)
2. `StockAccountPriceChecker(registry, USDC)` — recorded as `STOCK_ACCOUNT_PRICE_CHECKER`
3. admin: `StockAccountRegistry.setPriceChecker(checker)` — replaces the placeholder
4. `StockAccountStrategy` implementation — recorded as `STOCK_ACCOUNT_STRATEGY_IMPL`
5. admin: `MamoStrategyRegistry.whitelistImplementation(impl, 0)` — assigns the strategy type id
   (existing ids are 1, 2 and 3; the stock account implementation takes **4**)
6. `StockAccountStrategyFactory(...)` — recorded as `STOCK_ACCOUNT_STRATEGY_FACTORY`
7. admin: `MamoStrategyRegistry.grantRole(BACKEND_ROLE, factory)` so the factory can call `addStrategy`
8. admin: `StockAccountRegistry.listToken(...)` for every entry of `config/stock-accounts/8453.json`

Every step checks the address book (steps 1, 2, 4, 6) or the onchain state (steps 3, 5, 7, 8) first,
so a rerun against the same address book is a no-op. Deploying a name that is already recorded is
refused by the address book rather than silently overwritten.

## Admin steps: the two modes

`ADMIN_MODE=impersonate` (default) sends the admin calls from the role holder — the Mamo multisig for
the `MamoStrategyRegistry` calls, the configured `admin` for the stock registry. This only works where
accounts are unlocked, i.e. a Tenderly vnet or anvil.

`ADMIN_MODE=calldata` prints `from`, `to` and the calldata of each admin call and executes none of
them. That is the mainnet path: hand the printed calldata to the Safe, see `docs/SAFE_CALLDATA_GUIDE.md`.
The strategy type id used for the factory constructor is read ahead of time from
`MamoStrategyRegistry.nextStrategyTypeId()`, so the factory can be deployed before the Safe executes
the whitelist — but the whitelist must then land before any account is created, and no other
implementation may be whitelisted in between or the id shifts.

Mainnet dry run (no broadcast, writes to a throwaway copy of the address book):

```bash
make deploy-stock-accounts                     # DEPLOY_ENV defaults to 8453_TESTING
DEPLOY_ENV=8453_PROD make deploy-stock-accounts
```

The real mainnet run adds `ADDRESSES_PATH=./addresses` and `--broadcast` with the deployer account.

## Configuration

`deploy/stock-accounts/8453_PROD.json` and `deploy/stock-accounts/8453_TESTING.json` hold the registry
parameters; every address field is an FPS address **name** resolved against `addresses/8453.json`.

`placeholderPriceChecker` is `CHAINLINK_SWAP_CHECKER_PROXY` in both environments. It is a permanent
bootstrap detail, not a stopgap: the registry constructor needs a price checker that has code, and
the real `StockAccountPriceChecker` needs the registry address, so the registry is born with the
placeholder and step 3 immediately points it at the checker deployed in step 2. Any address with code
works; nothing is ever priced through the placeholder.

TESTING differs from PROD in one way: `admin`, `guardian` and `feeRecipient` are `DEPLOYER_EOA`, so a
vnet run needs no impersonation for the stock registry itself — step 3 and step 8 run directly. The
`MamoStrategyRegistry` steps still run as `MAMO_MULTISIG`. On PROD every admin step goes to the Safe.

`config/stock-accounts/8453.json` is the token list. It ships empty, so step 8 is a no-op — listing
tokens still waits on CT-04, which fills the file with entries shaped like:

```json
{"tokens":[{"chainlinkFeed":"","pool":"0x…","source":"PoolTwap","symbol":"NVDAc","token":"0xb20000000000000000000078ee7ce2fE4908108C"}]}
```

`pool` and `chainlinkFeed` are raw addresses (empty string means the zero address), `source` is
`PoolTwap` or `Chainlink`, and every token is listed as `Active`.

## Why the smoke test only deposits USDC

B20 stock tokens are node-native precompiles on Base: their code is the single byte `0xef`, which revm
refuses to execute. A foundry fork therefore cannot call them at all — no `balanceOf`, no `transfer`.
Anything touching a real stock token (pricing, rebalancing, in-kind withdrawals) has to run on the
Tenderly vnet, where the node serves the precompile, and not in `forge test`.

`StockAccountsSmoke` therefore creates an all-cash account (empty basket, `cashTargetBps = 10000`),
deposits 1,000 USDC and asserts `getNAV() == 1_000e6`. No token pricing is involved, so it passes
before any token is listed. It also asserts the registry points at `STOCK_ACCOUNT_PRICE_CHECKER`.

## CoW appData

`script/stock-accounts/appData.json` is the canonical document, byte for byte, with no trailing
newline. Its hash is what `requiredAppDataHash` is set to in both deploy configs:

```bash
make cow-appdata-hash
# 0x7cbb2322cf53b3a2b45d36850ed9678dd2ad87737e996de24646edbbed599382
```

Before any order is placed the document has to be uploaded to the CoW API (once per network):

```bash
curl -X PUT https://api.cow.fi/base/api/v1/app_data/0x7cbb2322cf53b3a2b45d36850ed9678dd2ad87737e996de24646edbbed599382 \
  -H 'content-type: application/json' \
  -d '{"fullAppData": "{\"appCode\":\"Mamo\",\"metadata\":{},\"version\":\"1.3.0\"}"}'
```

## The manifest

`script/stock-accounts/vnet-manifest.json` (gitignored) is written by the smoke script and is what the
backend or a follow-up script reads to pick the vnet up: the admin `rpc`, `chainId`, every
`STOCK_ACCOUNT_*` and `AERODROME_STOCKS_*` address, the `strategyTypeId`, and the test user with the
account created for them.

```bash
jq -r '.rpc' script/stock-accounts/vnet-manifest.json
cast call "$(jq -r '.testUserAccount' script/stock-accounts/vnet-manifest.json)" 'getNAV()(uint256)' \
  --rpc-url "$(jq -r '.rpc' script/stock-accounts/vnet-manifest.json)"
```
