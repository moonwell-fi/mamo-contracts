# Design Analysis: Address-Keyed vs Index-Keyed Market Splits

## Context

The multi-market strategy spec stores per-market split allocations as `mapping(uint256 => uint256) marketSplitBps` where the key is a sequential array index from the `MarketRegistry`. The question: should the key be `address` (the market's on-chain address) instead of `uint256` (a registry array index)?

## Recommendation: Use `mapping(address => uint256)`

Address-keyed splits are the better design. Here's why, in order of impact:

### 1. Migration Safety (High Impact)

This is the decisive factor. V1 strategies already have `mToken` and `metaMorphoVault` as address state variables, plus `splitMToken` and `splitVault` as uint256 state variables.

**With address keys**, the migration is self-contained and deterministic:
```solidity
function migrateV1ToMarketRegistry(address marketRegistryAddr) external reinitializer(2) {
    marketRegistry = IMarketRegistry(marketRegistryAddr);
    marketSplitBps[address(mToken)] = splitMToken;
    marketSplitBps[address(metaMorphoVault)] = splitVault;
}
```
No external dependency. The strategy already knows its own market addresses and splits.

**With index keys**, migration depends on the MarketRegistry having markets registered in the exact same order. The spec acknowledges this risk: *"Index mismatch during migration — Backend must register markets in MarketRegistry in same order before migrating strategies."* There's no on-chain safeguard — if the backend registers vault at index 0 and mToken at index 1 (reversed), splits get applied to the wrong markets. Funds go to the wrong protocol.

### 2. No Index-Ordering Coupling (Medium Impact)

With indices, there's an implicit contract: "index 0 in the registry means the same thing as index 0 in every strategy's split mapping." This coupling creates edge cases:

- **Market addition**: Safe in both approaches (new market defaults to 0 split). Equal.
- **Market deactivation**: Equal — both require the backend to rebalance via `updatePosition`.
- **Market replacement** (deprecated vault → new vault): With addresses, the change is explicit in calldata (`oldAddr → 0, newAddr → X`). With indices, the registry silently swaps the target address behind a stable index — implicit and harder to audit.
- **Race conditions in Multicall batches**: If registry state changes mid-batch, index-based calls become ambiguous. Address-based calls are self-describing — the calldata fully specifies intent regardless of registry state.

### 3. Backend Ergonomics (Medium Impact)

The backend already works with market addresses (they come from the chain). Index-based requires maintaining a translation layer (`address → index`) that must stay in sync with registry state. Address-based eliminates this entire class of bugs.

`updatePosition` calldata with addresses is human-readable in block explorers and debugging tools. Indices are opaque without cross-referencing the registry at that block height.

### 4. Built-in Deduplication (Low Impact)

`mapping(address => uint256)` naturally prevents the same market from having two separate allocations. With indices, the registry must enforce address uniqueness as a separate invariant.

### 5. Gas (Negligible)

Both are `mapping` lookups with keccak256 hashing. ABI encoding pads both `address` (20 bytes) and `uint256` (32 bytes) to 32-byte slots in calldata. For N ≤ 10 markets, the difference is immaterial.

## What Changes in the Spec

### Strategy Storage
```solidity
// Before (spec):
mapping(uint256 => uint256) public marketSplitBps; // index => bps

// After:
mapping(address => uint256) public marketSplitBps; // market address => bps
```

### updatePosition Signature
```solidity
// Before (spec):
struct MarketSplitUpdate { uint256 marketIndex; uint256 splitBps; }

// After:
struct MarketSplitUpdate { address market; uint256 splitBps; }
```

### MarketRegistry API
The registry can still use an array internally for enumeration. But the external API should be address-based:

```solidity
// Before (spec):
deactivateMarket(uint256 strategyTypeId, uint256 marketIndex)
getMarket(uint256 strategyTypeId, uint256 marketIndex)
isMarketActive(uint256 strategyTypeId, uint256 marketIndex)

// After:
deactivateMarket(uint256 strategyTypeId, address target)
getMarket(uint256 strategyTypeId, address target)
isMarketActive(uint256 strategyTypeId, address target)
```

Internally, the registry maintains a `mapping(uint256 => mapping(address => uint256))` to resolve addresses to array indices for `deactivateMarket`. Standard EnumerableSet-style pattern.

### Market Composite View
```solidity
// The Market struct returned by strategy.getMarkets() stays the same —
// it already has `address target` as a field. No change needed.
```

### Split Validation in updatePosition
The strategy reads the full market list from the registry via `getMarkets(strategyTypeId)`, then for each active market, reads `marketSplitBps[market.target]`. Sums must equal `SPLIT_TOTAL`. Logic is identical — just a different key type for the mapping lookup.

## What Doesn't Change

- MarketRegistry's internal array storage (`RegistryMarket[]` per strategyTypeId)
- `addMarket` signature (already takes `address target`)
- `getMarkets` return type (already includes `address target` in struct)
- MAX_MARKETS cap, pause/unpause, access control
- deposit/withdraw/withdrawAll flow logic
- Storage slot layout (the mapping slot position is the same regardless of key type)
- MamoStrategyRegistry — no changes needed

## Tradeoffs Accepted

| Tradeoff | Assessment |
|----------|-----------|
| Market replacement requires explicit zero-old + set-new in calldata | Feature, not bug — explicit > implicit |
| Registry needs internal address→index mapping for `deactivateMarket` | Minor implementation cost, standard pattern |
| `updatePosition` validation should check each address is a registered market | Already `onlyBackend`; can add `isMarketActive` check if desired |
