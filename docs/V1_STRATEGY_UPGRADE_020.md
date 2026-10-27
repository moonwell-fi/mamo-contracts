# Proposal 020: v1 strategy upgrade (claim-time fee, USDC vault only)

`multisig/mamo-multisig/020_UpgradeV1StrategiesClaimFeeVaultOnlyUsdc.sol` (`UpgradeV1Strategies`). Rehearsed by `make v1-upgrade`.

## 1. Deploy (DEPLOYER_EOA)

Five contracts: `ERC20MoonwellMorphoStrategy` twice (type 1, type 4), then the v1 `StrategyFactory` for USDC (0 / 10000), cbBTC and WETH (10000 / 0), all with fee recipient `MAMO_MULTISIG`.

```bash
DO_DEPLOY=true DO_UPDATE_ADDRESS_JSON=true \
forge script multisig/mamo-multisig/020_UpgradeV1StrategiesClaimFeeVaultOnlyUsdc.sol:UpgradeV1Strategies \
  --fork-url base --account mamo-test --sender 0xDca82E03057329f53Ed4173429D46B0511E46Fb8 --broadcast --verify --slow -vv
```

The other hooks default to true, so the same run builds, simulates and validates the batch before anything is sent.

## 2. Address book commit

From this commit on, `v1-usdc-strategy`, `v1-cbbtc-strategy` and `v1-weth-strategy` test the NEW factories (they take `*_STRATEGY_FACTORY` from the book); `v1-upgrade` keeps rehearsing against the frozen pre-020 book in `addresses/rehearsal-020/`. Between this commit and the Safe execution, the unpinned suites that read `*_STRATEGY_FACTORY` at chain head (`v1-*-strategy`, `ERC20StrategyV2Test.test_FactoryCanCreateStrategy`) fail because the new factories hold no `BACKEND_ROLE` yet: expect that window red.

The new contracts already sit under the plain keys `MOONWELL_MORPHO_STRATEGY_IMPL`, `MOONWELL_MORPHO_STRATEGY_IMPL_V2`, `USDC_STRATEGY_FACTORY`, `cbBTC_STRATEGY_FACTORY` and `WETH_STRATEGY_FACTORY`. Add the retired ones by hand:

| Key | Address |
| --- | --- |
| `MOONWELL_MORPHO_STRATEGY_IMPL_DEPRECATED_2` | `0x4007EFfCE837701Fdd90017Ab747fefD58aAD98B` |
| `MOONWELL_MORPHO_STRATEGY_IMPL_V2_DEPRECATED` | `0x6C8577fa9B10807f7485f6476C2AFE0B8d61D1e7` |
| `USDC_STRATEGY_FACTORY_DEPRECATED_2` | `0x3098360e627E84Fb9dD621F01ea03E325cCEE2c6` |
| `cbBTC_STRATEGY_FACTORY_DEPRECATED_2` | `0xf8CFdEf5068929e022a50315983043b61E9987f8` |
| `WETH_STRATEGY_FACTORY_DEPRECATED` | `0x14bA47Ef0286B345E2B74d26243767268290eE28` |

## 3. Safe batch (MAMO_MULTISIG)

In order: `whitelistImplementation(newImpl, 1)`, `whitelistImplementation(newImplV2, 4)`, `grantRole(BACKEND_ROLE)` to the three new factories, `revokeRole(BACKEND_ROLE)` from the three old ones. Once step 2 has landed (before it the plain keys still hold the old implementations and `build()` reverts "Implementation already whitelisted"), print the MultiSend calldata (the "Proposal Calldata" section) and submit it as in `docs/SAFE_CALLDATA_GUIDE.md`:

```bash
DO_DEPLOY=false DO_UPDATE_ADDRESS_JSON=false \
forge script multisig/mamo-multisig/020_UpgradeV1StrategiesClaimFeeVaultOnlyUsdc.sol:UpgradeV1Strategies \
  --fork-url base --sender 0xDca82E03057329f53Ed4173429D46B0511E46Fb8 -vv
```

`BACKEND_ROLE` members by index (`getRoleMember`, read on chain at block 52,991,934). Grants append at 7, 8, 9; each revoke swap-and-pops the last member into the freed slot; index 0 never moves:

| # | Before | After |
| --- | --- | --- |
| 0 | `STRATEGY_MULTICALL` 0x7cb24EFA3fe76650388145b9B0823De6600f1f4c | `STRATEGY_MULTICALL` |
| 1 | `USDC_STRATEGY_FACTORY` 0x3098360e627E84Fb9dD621F01ea03E325cCEE2c6 | new `WETH_STRATEGY_FACTORY` |
| 2 | `cbBTC_STRATEGY_FACTORY` 0xf8CFdEf5068929e022a50315983043b61E9987f8 | new `cbBTC_STRATEGY_FACTORY` |
| 3 | `MAMO_STAKING_STRATEGY_FACTORY_DEPRECATED` 0xd7C3f474761B9A0ca4a8634570E8DCD4f5c92239 | unchanged |
| 4 | `MAMO_STAKING_STRATEGY_FACTORY` 0xd034Bf87003A216F9A451A55A2f4f7176AAE23C8 | unchanged |
| 5 | `WETH_STRATEGY_FACTORY` 0x14bA47Ef0286B345E2B74d26243767268290eE28 | new `USDC_STRATEGY_FACTORY` |
| 6 | type-7 stock factory 0x54fa54F8bDE08A5718022ec878044EdcF97eD144 (not in main's book) | unchanged |

## 4. After execution

`DO_DEPLOY=false DO_PRE_BUILD_MOCK=false DO_BUILD=false DO_SIMULATE=false DO_PRINT=false` with the command above runs `validate()` on chain:

- types 1 and 4 point to the new implementations, both whitelisted under those ids; the old ones stay whitelisted under 1 and 4 (un-upgraded proxies keep an upgrade path);
- the two new implementations share bytecode (bar UUPS's own-address immutable), refuse `initialize` with `InvalidInitialization()` and sign for the `1.3.0` appData;
- the three new factories hold `BACKEND_ROLE`, the three old ones do not; `getBackendAddress()` is still `STRATEGY_MULTICALL`;
- each new factory pins its type's new implementation and keeps the old one's type id, token, mToken, vault, price checker, hook gas and slippage; split USDC 0 / 10000, cbBTC and WETH 10000 / 0; `feeRecipient == MAMO_MULTISIG`, `compoundFee == 500`, `mamoBackend == MAMO_BACKEND`;
- the old USDC factory's `createStrategyForUser` reverts with `AccessControlUnauthorizedAccount`.

## 5. App and backend handoff

- The factory addresses flip at execution: the app and backend create accounts through the new keys from then on.
- An existing USDC account must be upgraded by its owner (`registry.upgradeStrategy(proxy, newImpl)`) and then pointed at the vault by the backend: `setSplit(0, 10000)` writes the split without moving funds so the next deposit lands in the vault, and `updatePosition(0, 10000)` additionally moves whatever Moonwell can redeem now and leaves the rest (emitting `MoonwellRedeemLimited`); the compounder reruns it as cash returns. The app gates USDC deposits on an existing account until it is upgraded and reads `splitVault() == 10000`.
- On the new implementation `onlyBackend` is `BACKEND_ROLE` membership: any member listed in §3 may call `updatePosition`, `claimRewards` and `setFeeRecipient`. `MAMO_BACKEND` is not a member, so the backend keeps sending through `STRATEGY_MULTICALL` (index 0), which un-upgraded proxies require anyway.
- `withdrawAll` and `updatePosition` no longer revert when Moonwell cannot redeem: they take the cash there is and emit `MoonwellRedeemLimited(cashRedeemed, mTokenLeft, underlyingLeft)`. Likewise, when MetaMorpho is short they redeem up to `maxRedeem` and emit `VaultRedeemLimited(sharesRedeemed, sharesLeft)`. The backend indexes both and re-runs `updatePosition(0, 10000)` for flagged accounts as liquidity recovers; the app reads `mToken.balanceOf(proxy) > 0` or vault shares > 0 after `withdrawAll` and shows the amount still held.
- `withdraw(amount)` on an upgraded account takes from whichever venue can pay, so the app's available balance is idle + vault `maxWithdraw` + min(Moonwell cash, Moonwell balance), not the raw total.
- Merkl's distributor only lets the proxy claim for itself, so rewards on these accounts are claimable only through backend `claimRewards`, where the compound fee is taken; users cannot skip it. A reward token may appear only once per call; order does not matter.
- Reward-swap orders on an upgraded account use the hook-free appData from `expectedAppData()`. Accounts not yet upgraded keep the old hooked appData.
- Reward balances already sitting in a proxy at upgrade time are never charged (accepted).
- Nothing to sweep: no relayer allowance changes in this design.
