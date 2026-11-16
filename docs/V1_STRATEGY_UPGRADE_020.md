# Proposal 020: v1 strategy upgrade (claim-time fee, new accounts vault only)

`multisig/mamo-multisig/020_UpgradeV1StrategiesClaimFeeVaultOnlyUsdc.sol` (`UpgradeV1Strategies`). Rehearsed by `make v1-upgrade`.

## 1. Deploy (DEPLOYER_EOA)

Five contracts: `ERC20MoonwellMorphoStrategy` twice (type 1, type 4), then the v1 `StrategyFactory` for USDC, cbBTC and WETH, all three with split 0 / 10000 (vault only) and fee recipient `MAMO_MULTISIG`.

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

`BACKEND_ROLE` members by index (`getRoleMember`, read on chain at block 58,277,032, after proposal 017 swapped the staking factories). Grants append at 6, 7, 8; each revoke swap-and-pops the last member into the freed slot; index 0 never moves:

| # | Before | After |
| --- | --- | --- |
| 0 | `STRATEGY_MULTICALL` 0x7cb24EFA3fe76650388145b9B0823De6600f1f4c | `STRATEGY_MULTICALL` |
| 1 | `USDC_STRATEGY_FACTORY` 0x3098360e627E84Fb9dD621F01ea03E325cCEE2c6 | new `WETH_STRATEGY_FACTORY` |
| 2 | `cbBTC_STRATEGY_FACTORY` 0xf8CFdEf5068929e022a50315983043b61E9987f8 | new `cbBTC_STRATEGY_FACTORY` |
| 3 | `STOCK_ACCOUNT_STRATEGY_FACTORY` 0x54fa54F8bDE08A5718022ec878044EdcF97eD144 (type 7) | unchanged |
| 4 | staking V2 factory 0x0Ce2e3b59FAd9baec5b8430870f63F0b52dFab8d (type 3, granted by 017, not in main's book) | unchanged |
| 5 | `WETH_STRATEGY_FACTORY` 0x14bA47Ef0286B345E2B74d26243767268290eE28 | new `USDC_STRATEGY_FACTORY` |

The proposal does not hard-code this set: before the batch it requires the strategy multicall at index 0 and the role on the three old factories and the stock factory, and afterwards it requires the member count unchanged. Members that unrelated proposals add or remove do not break it, so read the set again right before signing and vet any holder not listed here: on the new implementation every member may call `updatePosition`, `claimRewards` and `setFeeRecipient`.

- Proposal 011 (`011_DeployMultiMarketSystem`, never executed) whitelists a different implementation under type ids 1 and 4 and revokes `BACKEND_ROLE` from whatever `<token>_STRATEGY_FACTORY` names: it must not be executed after 020 without being reworked for the v1 fleet. `preBuildMock()` refuses to run if the book already has `MARKET_REGISTRY`.

## 4. After execution

`DO_DEPLOY=false DO_PRE_BUILD_MOCK=false DO_BUILD=false DO_SIMULATE=false DO_PRINT=false` with the command above runs `validate()` on chain:

- types 1 and 4 point to the new implementations, both whitelisted under those ids; the old ones stay whitelisted under 1 and 4 (un-upgraded proxies keep an upgrade path);
- the two new implementations share bytecode (bar UUPS's own-address immutable), refuse `initialize` with `InvalidInitialization()` and sign for the `1.3.0` appData;
- the three new factories hold `BACKEND_ROLE`, the three old ones do not; `getBackendAddress()` is still `STRATEGY_MULTICALL`;
- each new factory pins its type's new implementation and keeps the old one's type id, token, mToken, vault, price checker, hook gas and slippage; split 0 / 10000 on all three; `feeRecipient == MAMO_MULTISIG`, `compoundFee == 500`, `mamoBackend == MAMO_BACKEND`;
- the old USDC factory's `createStrategyForUser` reverts with `AccessControlUnauthorizedAccount`.

## 5. App and backend handoff

- The factory addresses flip at execution: the app and backend create accounts through the new keys from then on.
- New USDC, cbBTC and WETH accounts all start at 0 / 10000 (vault only). Existing cbBTC and WETH accounts keep their current split after upgrading: `initializeVaultSplit()` is USDC only, so the backend moves them with `updatePosition(0, 10000)`, which needs Moonwell to redeem the whole position.
- An existing USDC account is switched by its owner, through the app, with two calls sent back to back: `registry.upgradeStrategy(proxy, newImpl)`, then `initializeVaultSplit()` on the account. The second call is owner-only, runs once, and sets the split to 0 / 10000 without moving funds: new deposits go to the vault, the Moonwell share stays where it is. Wallets that support EIP-5792 batching sign both at once; plain wallets sign two transactions. The compounder's migrate-to-vault loop performs the real move with `updatePosition(0, 10000)`, which redeems the whole Moonwell position, so its cash gate keeps that to accounts whose position Moonwell can redeem in full. The loop must select accounts by their Moonwell position, not by `splitMToken`: after `initializeVaultSplit()` that reads 0 while Moonwell still holds the share. The app gates USDC deposits on an existing account until it is upgraded and reads `splitVault() == 10000`.
- On the new implementation `onlyBackend` is `BACKEND_ROLE` membership: any member listed in §3 may call `updatePosition`, `claimRewards` and `setFeeRecipient`. `MAMO_BACKEND` is not a member, so the backend keeps sending through `STRATEGY_MULTICALL` (index 0), which un-upgraded proxies require anyway.
- After `initializeVaultSplit()` on a funded account, `withdraw(amount)` routes the whole amount to the vault: it works up to the vault balance and reverts above it (inside MetaMorpho), even while Moonwell has some cash. `withdrawAll` reverts (`Failed to redeem mToken`) until Moonwell can redeem the whole Moonwell share. The window closes when the compounder's loop moves the account with `updatePosition(0, 10000)`, which it does once Moonwell's cash covers the share; from then on both work. Nothing can point the account back at Moonwell in the meantime, since `updatePosition` also needs Moonwell to pay the whole share. The app quotes the withdrawable amount from the split: the vault's `maxWithdraw` while the split is 0 / 10000, and up to Moonwell's cash while it is 10000 / 0. Decided 2026-10-29 to ship this way; the availability-aware `withdraw` that removes the window is #126.
- For "withdraw everything available", the app sends `withdraw` with the vault's `maxWithdraw` for the proxy (plus Moonwell's cash when the split points there), or `withdrawAll` when the account has no Moonwell share, never the nominal deposited amount: MetaMorpho rounds in its own favour, so a 500 USDC deposit is worth 499.999999 and `withdraw(500e6)` reverts. The same holds for new cbBTC and WETH accounts, which now sit in their vaults too.
- Partial migration and exits out of an illiquid Moonwell market ship in the follow-up PR.
- Merkl's distributor only lets the proxy claim for itself, so rewards on these accounts are claimable only through backend `claimRewards`, where the compound fee is taken; users cannot skip it. A reward token may appear only once per call; order does not matter.
- Reward-swap orders on an upgraded account use the hook-free appData from `expectedAppData()`. Accounts not yet upgraded keep the old hooked appData.
- Reward balances already sitting in a proxy at upgrade time are never charged (accepted).
- Nothing to sweep: no relayer allowance changes in this design.
