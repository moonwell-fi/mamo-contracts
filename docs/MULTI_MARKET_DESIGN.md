# Multi-Market Strategy Design

## Overview

`ERC20MoonwellMorphoStrategy` supports N Moonwell markets + M ERC4626 vaults per strategy, replacing the original fixed 2-way split (1 mToken + 1 MetaMorpho vault). Since strategies are UUPS proxies, storage layout preservation is critical.

Market configuration (targets + types) is stored centrally in a `MarketRegistry` contract, shared across all strategies of the same type. Each strategy stores only its per-market split allocations, **keyed by market address** (not index).

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
│ marketSplitBps:     │
│   address => bps    │
└─────────────────────┘
```

## Why Address-Keyed Splits

Splits are stored as `mapping(address => uint256)` rather than `mapping(uint256 => uint256)`.

| Factor | Address-Keyed | Index-Keyed |
|--------|--------------|-------------|
| **Migration safety** | Self-contained: `marketSplitBps[address(mToken)] = splitMToken` — no external dependency | Fragile: requires registry to have markets in exact same order. Wrong order = funds to wrong protocol |
| **Ordering coupling** | None — calldata is self-describing | Implicit contract: "index 0 in registry = index 0 in every strategy" |
| **Market replacement** | Explicit in calldata: `oldAddr → 0, newAddr → X` | Silent: registry swaps target behind stable index |
| **Backend ergonomics** | Works directly with on-chain addresses | Requires address-to-index translation layer |
| **Auditability** | Human-readable in block explorers | Opaque without cross-referencing registry at that block height |
| **Deduplication** | Built-in: mapping key is unique | Registry must enforce address uniqueness separately |
| **Gas** | Negligible difference | Negligible difference |

## Types

```solidity
// Defined in IMarketRegistry.sol (single source of truth)
enum MarketType { MOONWELL, ERC4626 }

// Stored in MarketRegistry per strategyTypeId
struct RegistryMarket {
    address target;        // mToken or ERC4626 vault address
    MarketType marketType; // interface selector
    bool active;           // soft-delete flag
}

// Used by strategy's updatePosition
struct MarketSplitUpdate {
    address market;   // market address (not index)
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

Internally uses an array for enumeration + `mapping(address => uint256)` for address-to-index lookups.

| Function | Access | Description |
|----------|--------|-------------|
| `addMarket(strategyTypeId, target, marketType)` | BACKEND_ROLE | Appends market, enforces MAX_MARKETS=10, rejects duplicates |
| `deactivateMarket(strategyTypeId, target)` | BACKEND_ROLE | Sets active=false by address |
| `getMarkets(strategyTypeId)` | view | Returns full array (single STATICCALL) |
| `getMarketCount(strategyTypeId)` | view | Returns array length |
| `isMarketActive(strategyTypeId, target)` | view | Returns active flag by address |
| `getMarket(strategyTypeId, target)` | view | Returns single market by address |
| `pause()` / `unpause()` | GUARDIAN_ROLE | Emergency stop |

Key design: **append-only** — markets are never deleted, only deactivated. The array provides stable enumeration for strategies that iterate all markets.

## Storage Layout

Existing slots 0-59 preserved. New slots appended:

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
| 61 | `marketSplitBps` (mapping(address => uint256)) | **new** — market address => splitBps |

## Initialization Paths

### Fresh deployment (new factory)

```
MultiMarketStrategyFactory.createStrategyForUser(user)
  -> proxy = new ERC1967Proxy(impl, "")
  -> strategy.initialize(InitParams{ ..., marketRegistry, defaultSplitBps[] })
     -> sets marketRegistry
     -> reads markets from registry, copies defaultSplitBps[i] to marketSplitBps[market.target]
     -> validates splits sum to SPLIT_TOTAL against active registry markets
```

### Upgrade of existing v1 proxy (2-step)

```
Step 1: user -> registry.upgradeStrategy(strategy, newImpl)
  -> strategy.upgradeToAndCall(newImpl, "") // empty data

Step 2: owner or backend -> strategy.migrateV1ToMarketRegistry(marketRegistryAddr)
  [reinitializer(2)]
  -> sets marketRegistry
  -> marketSplitBps[address(mToken)] = splitMToken
  -> marketSplitBps[address(metaMorphoVault)] = splitVault
  -> validates each address is registered and active in the MarketRegistry
```

Migration is **self-contained** — the strategy reads its own `mToken`, `metaMorphoVault`, `splitMToken`, `splitVault` storage. No dependency on registry ordering.

### Upgrade of existing v2 proxy (already has markets[])

```
Step 1: user -> registry.upgradeStrategy(strategy, newImpl)
Step 2: owner or backend -> strategy.migrateToMarketRegistry(marketRegistryAddr)
  [reinitializer(3)]
  -> sets marketRegistry
  -> for each markets[i]: marketSplitBps[markets[i].target] = markets[i].splitBps
  -> validates each address is registered and active in the MarketRegistry
```

Also self-contained — reads target addresses from the strategy's own `markets[]` storage.

## Core Functions

### `depositInternal(amount)`

Reads markets from registry via `getMarkets(strategyTypeId)` (single STATICCALL), reads splits from `marketSplitBps[market.target]`. Each active market with nonzero split receives `(amount * splitBps) / SPLIT_TOTAL`. Last active market gets remainder.

### `withdraw(amount)`

If idle balance insufficient, calls `_withdrawProRata(amountNeeded)` which reads from registry and withdraws pro-rata per each market's split.

### `withdrawAll()`

Calls `_withdrawAllFromMarkets()` which iterates ALL markets (including inactive) to handle funds in recently-deactivated markets.

### `updatePosition(MarketSplitUpdate[])`

1. Withdraws everything from all markets
2. Zeros `marketSplitBps` for all registered markets
3. Applies new splits from updates array (keyed by address)
4. Validates each address is a registered active market
5. Validates active markets' splits sum to SPLIT_TOTAL
6. Re-deposits via `depositInternal`

### `_validateTotalSplit()`

Reads all markets from registry, sums `marketSplitBps[market.target]` for active markets, requires total == SPLIT_TOTAL.

### `_getTotalBalance()`

Sums idle tokens + each active market's underlying balance via `balanceOfUnderlying` (Moonwell) or `convertToAssets` (ERC4626).

## Market Lifecycle

### Adding a new market (backend -> MarketRegistry)

1. Backend calls `marketRegistry.addMarket(strategyTypeId, target, marketType)`
2. Existing strategies have `marketSplitBps[target] = 0` by default -> new market is skipped
3. `_validateTotalSplit` still passes (0 doesn't affect sum)
4. Backend calls `updatePosition()` on strategies when ready to allocate

### Deactivating a market (backend -> MarketRegistry)

1. Backend calls `marketRegistry.deactivateMarket(strategyTypeId, target)`
2. Backend calls `updatePosition()` on affected strategies with new splits excluding deactivated market
3. `_withdrawAllFromMarkets` withdraws from ALL markets (including inactive) — funds are never stuck

### Replacing a market

Explicit two-step via `updatePosition`:
```
updatePosition([
  { market: oldAddr, splitBps: 0 },
  { market: newAddr, splitBps: X }
])
```
Clear intent in calldata. No silent swaps behind stable indices.

## Files

| File | Action | Description |
|------|--------|-------------|
| `src/interfaces/IMarketRegistry.sol` | CREATE | Interface, MarketType enum, RegistryMarket struct |
| `src/MarketRegistry.sol` | CREATE | Centralized market storage per strategyTypeId |
| `src/ERC20MoonwellMorphoStrategy.sol` | MODIFY | New storage (60-61), refactor reads to use registry, remove addMarket/deactivateMarket, add migration fns, update InitParams |
| `src/MultiMarketStrategyFactory.sol` | MODIFY | Replace MarketInit[] with marketRegistry + defaultSplitBps |
| `src/MamoStrategyRegistry.sol` | NO CHANGES | Not upgradeable |
| `test/MarketRegistry.t.sol` | CREATE | Unit tests |
| `test/MultiMarketStrategy.integration.t.sol` | MODIFY | Deploy MarketRegistry in setUp |
| `test/MoonwellMorphoStrategy.integration.t.sol` | MODIFY | Deploy MarketRegistry in setUp |

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Storage collision | New vars appended after slot 59; mapping at slot 61 uses keccak256 |
| Gas (external call per operation) | Single `getMarkets()` STATICCALL returns full array; loop locally |
| Gas griefing | `MAX_MARKETS = 10` enforced in MarketRegistry |
| Funds in deactivated market | `_withdrawAllFromMarkets` iterates ALL markets including inactive |
| Rounding dust | Last active market gets remainder |
| Re-running migration | Protected by `reinitializer(2/3)` |
| Unregistered address in updatePosition | `updatePosition` validates each address is a registered active market |
| Duplicate market addresses | MarketRegistry rejects duplicates on `addMarket` |

## Test Coverage

- **MarketRegistry**: addMarket, deactivateMarket, duplicate rejection, MAX_MARKETS cap, access control, pause
- **Migration**: v1->registry (self-contained), v2->registry (self-contained), fresh deploy with registry
- **Multi-market lifecycle**: deposit distributes per splits, withdraw pro-rata, withdrawAll drains all, updatePosition rebalances
- **Market lifecycle**: add market in registry (strategies unaffected), deactivate + updatePosition, replace market
- **Error paths**: invalid splits, unregistered market address, non-backend access
- **Factory**: creates strategies reading from MarketRegistry
- **Backwards compatibility**: existing USDC and cbBTC tests pass
