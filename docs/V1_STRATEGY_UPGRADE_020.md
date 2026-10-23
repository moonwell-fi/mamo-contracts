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

From this commit on, `v1-usdc-strategy`, `v1-cbbtc-strategy` and `v1-weth-strategy` test the NEW factories (they take `*_STRATEGY_FACTORY` from the book); `v1-upgrade` keeps rehearsing against the frozen pre-020 book in `addresses/rehearsal-020/`.

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

## 4. After execution

`DO_DEPLOY=false DO_PRE_BUILD_MOCK=false DO_BUILD=false DO_SIMULATE=false DO_PRINT=false` with the command above runs `validate()` on chain:

- types 1 and 4 point to the new implementations, both whitelisted under those ids;
- the three new factories hold `BACKEND_ROLE`, the three old ones do not; `getBackendAddress()` is still `STRATEGY_MULTICALL`;
- each new factory pins its type's new implementation and keeps the old one's type id, token, mToken, vault, price checker, hook gas and slippage; split USDC 0 / 10000, cbBTC and WETH 10000 / 0; `feeRecipient == MAMO_MULTISIG`, `compoundFee == 500`, `mamoBackend == MAMO_BACKEND`;
- the old USDC factory's `createStrategyForUser` reverts with `AccessControlUnauthorizedAccount`.

## 5. App and backend handoff

- The factory addresses flip at execution: the app and backend create accounts through the new keys from then on.
- An existing USDC account must be upgraded by its owner (`registry.upgradeStrategy(proxy, newImpl)`) and then re-split by the backend with `updatePosition(0, 10000)`, sent through `STRATEGY_MULTICALL` (v1 `onlyBackend` is `BACKEND_ROLE` index 0), before it accepts a USDC deposit. The re-split leaves any mToken Moonwell cannot redeem in place.
- Reward-swap orders on an upgraded account use the hook-free appData from `expectedAppData()`; the compound fee is taken at `claimRewards`. Accounts not yet upgraded keep the old hooked appData.
- Nothing to sweep: no relayer allowance changes in this design.
