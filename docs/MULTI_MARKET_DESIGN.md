# Multi-Market Strategy Design

## Overview

`ERC20MoonwellMorphoStrategy` supports N Moonwell markets + M ERC4626 vaults per strategy, replacing the original fixed 2-way split (1 mToken + 1 MetaMorpho vault). Since strategies are UUPS proxies, storage layout preservation is critical.

Market configuration (targets + types) is stored centrally in a `MarketRegistry` contract, shared across all strategies of the same type. Each strategy stores only its per-market split allocations.

## Architecture

```
┌─────────────────────┐        ┌───────────────────────┐
│   MarketRegistry    │◄───────│  Backend              │
│ (per strategyTypeId)│        │  addMarket()          │
│                     │        │  deactivateMarket()   │
│ markets[]:          │        └───────────────────────┘
│   target, type,     │
│   active            │
└────────┬────────────┘
         │ getMarkets() (STATICCALL)
         │
┌────────▼────────────┐        ┌───────────────────────┐
│  Strategy (proxy)   │◄───────│  Backend              │
│ (per user)          │        │  updatePosition()     │
│                     │        └───────────────────────┘
│ marketSplitBps[]:   │
│   index => bps      │
└─────────────────────┘
```

## Types

```solidity
// Defined in IMarketRegistry.sol (single source of truth)
enum MarketType { MOONWELL, ERC4626 }

// Stored in MarketRegistry per strategyTypeId
struct RegistryMarket {
    address target;      // mToken or ERC4626 vault address
    MarketType marketType; // interface selector
    bool active;         // soft-delete flag
}

// Used by strategy's updatePosition
struct MarketSplitUpdate {
    uint256 marketIndex;
    uint256 splitBps;
}

// Composite view returned by strategy's getMarkets()
struct Market {
    address target;
    MarketType marketType;
    bool active;
    uint256 splitBps;    // from strategy's local marketSplitBps mapping
}
```

## MarketRegistry Contract

New standalone contract (not upgradeable, same pattern as `MamoStrategyRegistry`).

| Function | Access | Description |
|----------|--------|-------------|
| `addMarket(strategyTypeId, target, marketType)` | BACKEND_ROLE | Appends market, enforces MAX_MARKETS=10 |
| `deactivateMarket(strategyTypeId, marketIndex)` | BACKEND_ROLE | Sets active=false (indices are stable) |
| `getMarkets(strategyTypeId)` | view | Returns full array (single STATICCALL) |
| `getMarketCount(strategyTypeId)` | view | Returns array length |
| `isMarketActive(strategyTypeId, marketIndex)` | view | Returns active flag |
| `getMarket(strategyTypeId, marketIndex)` | view | Returns single market |
| `pause()` / `unpause()` | GUARDIAN_ROLE | Emergency stop |

Key design: **append-only** — markets are never deleted, only deactivated. This preserves index stability since strategies reference markets by index.

## Storage Layout

Existing slots 0-61 preserved. New slots appended:

| Slot | Variable | Status |
|------|----------|--------|
| 0 | `mamoStrategyRegistry` | kept |
| 1 | `strategyTypeId` | kept |
| 2-49 | `__gap[48]` | kept |
| 50 | `mToken` | **deprecated** |
| 51 | `metaMorphoVault` | **deprecated** |
| 52 | `token` | kept |
| 53 | `slippagePriceChecker` | kept |
| 54 | `splitMToken` | **deprecated** |
| 55 | `splitVault` | **deprecated** |
| 56 | `allowedSlippageInBps` | kept |
| 57 | `compoundFee` | kept |
| 58 | `feeRecipient` | kept |
| 59 | `hookGasLimit` | kept |
| 60 | `marketRegistry` (IMarketRegistry) | **new** |
| 61 | `marketSplitBps` (mapping(uint256 => uint256)) | **new** — marketIndex => splitBps |

## Initialization Paths

### Fresh deployment (new factory)

```
MultiMarketStrategyFactory.createStrategyForUser(user)
  -> proxy = new ERC1967Proxy(impl, "")
  -> strategy.initialize(InitParams{ ..., marketRegistry, defaultSplitBps })
     -> sets marketRegistry, copies splits to marketSplitBps mapping
     -> sets migrated = true, migratedToRegistry = true
```

### Upgrade of existing v1 proxy (2-step)

```
Step 1: user -> registry.upgradeStrategy(strategy, newImpl)
  -> strategy.upgradeToAndCall(newImpl, "") // empty data

Step 2: owner or backend -> strategy.migrateV1ToMarketRegistry(marketRegistryAddr)
  [reinitializer(2)]
  -> sets marketRegistry
  -> maps splitMToken/splitVault -> marketSplitBps[0]/marketSplitBps[1]
  -> sets migrated = true, migratedToRegistry = true
```

### Upgrade of existing v2 proxy (already has markets[])

```
Step 1: user -> registry.upgradeStrategy(strategy, newImpl)
Step 2: owner or backend -> strategy.migrateToMarketRegistry(marketRegistryAddr)
  [reinitializer(3)]
  -> sets marketRegistry
  -> copies markets[i].splitBps -> marketSplitBps[i]
  -> sets migratedToRegistry = true
```

## Core Functions

### `depositInternal(amount)`

Reads markets from registry in a single STATICCALL, reads splits from local `marketSplitBps` mapping. Each active market with nonzero split receives `(amount * splitBps) / SPLIT_TOTAL`. Last active market gets remainder.

### `withdraw(amount)`

If idle balance insufficient, calls `_withdrawProRata(amountNeeded)` which reads from registry and withdraws pro-rata per each market's split.

### `withdrawAll()`

Calls `_withdrawAllFromMarkets()` which iterates ALL markets (including inactive) to handle funds in recently-deactivated markets.

### `updatePosition(MarketSplitUpdate[])`

1. Withdraws everything from all markets
2. Zeros all `marketSplitBps`
3. Applies new splits from updates array
4. Validates active markets' splits sum to SPLIT_TOTAL
5. Re-deposits via `depositInternal`

### `_getTotalBalance()`

Sums idle tokens + each active market's underlying balance via `balanceOfUnderlying` (Moonwell) or `convertToAssets` (ERC4626).

## Market Lifecycle

### Adding a new market (backend -> MarketRegistry)

1. Backend calls `marketRegistry.addMarket(strategyTypeId, target, marketType)`
2. Existing strategies have `marketSplitBps[newIndex] = 0` -> new market is skipped
3. `_validateTotalSplit` still passes (0 doesn't affect sum)
4. Backend calls `updatePosition()` on strategies when ready to allocate

### Deactivating a market (backend -> MarketRegistry)

1. Backend calls `marketRegistry.deactivateMarket(strategyTypeId, marketIndex)`
2. Backend calls `updatePosition()` on affected strategies with new splits excluding deactivated market
3. `_withdrawAllFromMarkets` withdraws from ALL markets (including inactive) — funds are never stuck


## Files

| File | Action | Description |
|------|--------|-------------|
| `src/interfaces/IMarketRegistry.sol` | CREATE | Interface, MarketType enum, RegistryMarket struct |
| `src/MarketRegistry.sol` | CREATE | Centralized market storage per strategyTypeId |
| `src/ERC20MoonwellMorphoStrategy.sol` | MODIFY | New storage (62-64), refactor reads to use registry, remove addMarket/deactivateMarket, add migration fns, update InitParams |
| `src/MultiMarketStrategyFactory.sol` | MODIFY | Replace MarketInit[] with marketRegistry + defaultSplitBps |
| `src/MamoStrategyRegistry.sol` | NO CHANGES | Not upgradeable |
| `test/MarketRegistry.t.sol` | CREATE | Unit tests |
| `test/MultiMarketStrategy.integration.t.sol` | MODIFY | Deploy MarketRegistry in setUp |
| `test/MoonwellMorphoStrategy.integration.t.sol` | MODIFY | Deploy MarketRegistry in setUp |

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Storage collision | New vars appended after slot 61; mapping at slot 63 uses keccak256 |
| Gas (external call per operation) | Single `getMarkets()` STATICCALL returns full array; loop locally |
| Gas griefing | `MAX_MARKETS = 10` enforced in MarketRegistry |
| Index mismatch during migration | Backend must register markets in MarketRegistry in same order before migrating strategies |
| Funds in deactivated market | `_withdrawAllFromMarkets` iterates ALL markets including inactive |
| Rounding dust | Last active market gets remainder |
| Re-running migration | Protected by `reinitializer(2/3)` and `migratedToRegistry` flag |

## Test Coverage

- **MarketRegistry**: addMarket, deactivateMarket, MAX_MARKETS cap, access control, pause
- **Migration**: v1->registry, v2->registry, fresh deploy with registry
- **Multi-market lifecycle**: deposit distributes per splits, withdraw pro-rata, withdrawAll drains all, updatePosition rebalances
- **Market lifecycle**: add market in registry (strategies unaffected), deactivate + updatePosition
- **Error paths**: invalid splits, invalid market index, non-backend access
- **Factory**: creates strategies reading from MarketRegistry
- **Backwards compatibility**: existing USDC and cbBTC tests pass
