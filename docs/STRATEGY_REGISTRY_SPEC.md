# Mamo Contracts Specification

This document outlines the specification for the Mamo contracts, which enable users to deploy personal strategy contracts and let Mamo manage their funds.

## Mamo Strategy Registry

This contract is responsible for tracking user strategies, whitelisting strategy implementations, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations.

The contract is initialized with three distinct roles that are passed as constructor parameters:
- `admin`: Granted the DEFAULT_ADMIN_ROLE, which can grant and revoke other roles
- `backend`: Granted the BACKEND_ROLE, which can manage strategies
- `guardian`: Granted the GUARDIAN_ROLE, which can pause and unpause the contract

### Roles

- `DEFAULT_ADMIN_ROLE`: The default admin role that can grant and revoke other roles, whitelist implementations, and recover tokens
- `BACKEND_ROLE`: The role that can register strategies for users
- `GUARDIAN_ROLE`: The role that can pause and unpause the contract in case of emergencies

### Storage

- `mapping(address => EnumerableSet.AddressSet) private _userStrategies`: Set of all strategy addresses for each user
- `mapping(address => bool) public whitelistedImplementations`: Mapping of whitelisted implementation addresses
- `mapping(uint256 => address) public latestImplementationById`: Maps strategy IDs to their latest implementation
- `mapping(address => uint256) public implementationToId`: Maps implementations to their strategy ID
- `uint256 public nextStrategyTypeId`: Counter for strategy type IDs, starting from 1. **Public**, and a stale lower bound rather than the next free slot — see the accepted-risk section below.

### Strategy Type ID

The strategy type ID is a uint256 value that uniquely identifies a type of strategy. Implementations of the same strategy type (e.g., different versions of a USDC strategy) share the same ID, ensuring that users can only upgrade to the latest implementation of the same strategy type.

An ID is either assigned from the counter (by passing `strategyTypeId == 0`) or claimed explicitly. On the deployed registry only the explicit form may be used; see below.

### Functions

- `function pause() external`: Pauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function unpause() external`: Unpauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function whitelistImplementation(address implementation, uint256 strategyTypeId) external returns (uint256 assignedStrategyTypeId)`: Adds an implementation to the whitelist and sets it as the latest implementation for its type. Passing `strategyTypeId == 0` assigns the next counter value; a nonzero value is used verbatim and does **not** advance the counter. Only callable by accounts with the **DEFAULT_ADMIN_ROLE**.

- `function latestImplementationById(uint256 strategyId) external view returns (address)`: Public mapping getter for the latest implementation of a strategy ID.

- `function implementationToId(address implementation) external view returns (uint256)`: Public mapping getter for an implementation's strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The caller is responsible for deploying the strategy first. Checks that the strategy points at this registry and that its implementation is the latest for its type. Pausable.

- `function upgradeStrategy(address strategy, address newImplementation) external`: Updates the implementation of a strategy. Only callable by the user who owns the strategy. `newImplementation` must be the latest implementation registered for that strategy's type. Calls `upgradeToAndCall` on the strategy. Pausable.

- `function updateStrategyOwner(address newOwner) external`: Called *by a strategy* to move its own registry-side ownership record to `newOwner`. Pausable.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) public view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Returns `getRoleMember(BACKEND_ROLE, 0)`. **Not an authorization primitive** — see the accepted-risk section. Retained for off-chain and legacy consumers.

- `function recoverERC20(address tokenAddress, address to, uint256 amount) external`: Recovers tokens sent to the registry itself. Only callable by accounts with the DEFAULT_ADMIN_ROLE.

### Known limitation: strategy type IDs on the deployed registry (ACCEPTED RISK)

`MamoStrategyRegistry` is **not upgradeable**, and `BaseStrategy.mamoStrategyRegistry` is written
once at initialization with no setter, so existing strategies cannot be moved to a replacement.
The issue below is therefore a permanent property of the deployed registry
(`0x46a5624C2ba92c08aBA4B206297052EDf14baa92`) and is mitigated operationally, not in code.
See Sherlock 2026-07 finding #42.

**An explicit `strategyTypeId` can squat a free slot.**
`whitelistImplementation(implementation, strategyTypeId)` assigns the next counter value when
`strategyTypeId == 0`, and otherwise uses the id verbatim **without advancing the counter**. An
explicit id may therefore occupy the value the counter is about to hand out; the next automatic
registration then reuses that id and overwrites `latestImplementationById` for it. The displaced
implementation is stranded — `addStrategy` requires an exact match against the latest, so every
factory pinned to it stops working, and its existing proxies would accept only an unrelated
implementation as their upgrade target.

**Recovery is possible but lossy.** `latestImplementationById` is written in exactly one place and
the "Implementation already whitelisted" guard blocks re-registering the *same address*, but
redeploying **identical bytecode to a fresh address** and whitelisting it at the displaced id
restores `latestImplementationById[id]`. Existing proxies and the (per-call-resolving) factories
then self-heal without further action. What cannot be undone is the window itself, and any
strategy registered against the squatting implementation in the meantime.

The live counter is already desynchronised:

```
nextStrategyTypeId          = 4
latestImplementationById(4) = 0x6C8577fa9B10807f7485f6476C2AFE0B8d61D1e7   (occupied)
```

`nextStrategyTypeId` is a **stale lower bound, not the next free slot**. Operating rules:

- **Never call `whitelistImplementation(impl, 0)` on this registry.** Auto-assignment would take
  id 4 and strand strategy type 4. Proposals `005_MamoStakingDeployment` and
  `008_MamoStakingV2Deployment` use this form and must not be re-executed against production.
- **Create a new type with an explicit id `>= 5`**, after asserting the slot is free
  (`latestImplementationById(id) == address(0)`) — this is the *real* guard and the only one that
  can fail for a well-chosen id — and that the counter has not reached it
  (`nextStrategyTypeId() < id`, strictly). Note the counter check is close to vacuous for any
  `id >= 5`, precisely because explicit ids never advance the counter; it exists to catch the case
  where auto-assignment has been used in the interim. `012_DeployLeveragedAeroAccountSystem`
  follows this pattern.
- Implementation rollouts to an existing type (`009`, `010`, `011`) are unaffected.

A future registry deployment should fix this in code (advance the counter past an explicit id, or
reject ids that do not already exist). That is a migration project, out of scope here.

### BACKEND_ROLE: membership, not index 0 (Sherlock #41 — FIXED in the strategies)

`getBackendAddress()` returns `getRoleMember(BACKEND_ROLE, 0)`. `EnumerableSet` has no ordering
guarantee and removes by swap-and-pop, so revoking the member at index 0 moves the **last** member
into that slot. The identity behind `getBackendAddress()` therefore changes as a side effect of
unrelated membership edits, and a member re-granted afterwards lands at the end of the set, never
back at index 0.

The registry itself cannot be fixed (not upgradeable, no proxy). The **consumers** could be, and
were: every strategy now gates on `mamoStrategyRegistry.hasRole(BACKEND_ROLE, msg.sender)` via
`BaseStrategy._isBackend`, matching what `MultiMarketStrategyFactory` already did. Affected call
sites, all of them deployed fresh by this change:

- `MamoMultiMarketStrategy.onlyBackend` (`updatePosition`, `claimRewards`, `setFeeRecipient`)
- `MamoMultiMarketStrategy.migrateV1ToMarketRegistry`
- `MamoLeveragedAeroStrategy.depositIdle`

Consequence to be explicit about: the authorized set is now **every BACKEND_ROLE holder**, which
today includes the per-asset factories as well as the operator. This is deliberate — it is the same
principal set the factory half of every operation already accepted, so the two halves of a repair
(factory `setDefaultSplitBps` + strategy `updatePosition`) finally agree on who may perform it.

#### Live topology, and what actually triggers this

The rotation model previously described here did not match production. On the deployed registry:

- `getBackendAddress()` resolves to `STRATEGY_MULTICALL`, whose owner is `MAMO_COMPOUNDER`.
- **No operator EOA held `BACKEND_ROLE` at all** before this change. `MAMO_BACKEND`
  (`0x2Ab0…5e73`) was usable only because the *old* factories pinned its address at construction.
- The remaining members are the per-asset factories.

So "grant the incoming operator before revoking the outgoing" describes a rotation that does not
exist. The real trigger is **retiring the multicall**: revoking it swaps a factory into index 0.

Operating rules:

- `011_DeployMultiMarketSystem` now grants `BACKEND_ROLE` to `MAMO_BACKEND` explicitly. Without it
  the new `hasRole`-gated factories would take operator-driven onboarding offline, since the pinned
  address the old factories relied on is gone.
- Grant before revoke, always — `011` was doing the reverse and was safe only by accident.
- Every proposal that mutates `BACKEND_ROLE` must assert `getBackendAddress()` in **both**
  `preBuildMock` and `validate`, so a change of identity is a test failure rather than a discovery.
  `011` carries the pair.
- Recovery, if index 0 does move: grant the desired principal, revoke the index-0 occupant (the
  desired principal or the last member swaps in), and re-grant anything revoked in the process.
- `MamoLeveragedAeroStrategyFactory` grants `BACKEND_ROLE` **on itself**, while the accounts it
  creates authorize against the *registry's* role. Two different principal sets from two different
  sources: a rotation has to touch both.

### Rollout note: legacy relayer allowances (Sherlock #32)

Live type-1 proxies carry `rewardFeeCharged = 0` alongside an unlimited CoW relayer approval left
by the previous implementation. The finite-allowance lock that secures the compound fee does not
exist in that state — the `isValidSignature` fee gate is the only protection, and it is scoped to
exactly that state by design. Immediately after upgrading each live proxy, call
`sweepRewardFees` for **xWELL and MORPHO** on it to replace the stale approval with a bounded one.
Pinned by `test_isValidSignature_refusesUntilTheRewardFeeIsSettled_underLegacyAllowance`.

### Operational note: market deactivation is a two-step repair

`MarketRegistry.deactivateMarket` makes the active splits incomplete, and `MamoMultiMarketStrategy`
refuses `deposit()` / `depositIdleTokens()` while they are (Sherlock #36 — the alternative is
silently over-allocating the retired market's share to whichever market happens to be last). The
window closes only when both halves are repaired:

1. `MultiMarketStrategyFactory.setDefaultSplitBps` — for strategies not yet created. As of this
   change the new allocation is validated against the registry at set time (length must match the
   market count; a deactivated market must be given zero), rather than failing later inside
   `createStrategyForUser`.
2. `MamoMultiMarketStrategy.updatePosition` — **per existing strategy**. There is no batch form.

Between the deactivation and step 2, every existing strategy on that token rejects deposits. Plan
the deactivation and the `updatePosition` sweep as one operation.

## SlippagePriceChecker

Validates swap prices using Chainlink price feeds and applies slippage tolerance. Implements
`ISlippagePriceChecker` and is used by the strategy contracts to validate CoW Swap orders. Upgradeable
via UUPS. The implementation is initializer-locked in its constructor (Sherlock #44) — the live
pre-fix implementation is claimable and must be redeployed.

### Storage

- `uint256 internal constant MAX_BPS`: The maximum basis points value (10,000 = 100%)
- `mapping(address => TokenFeedConfiguration[]) public tokenOracleData`: **Deprecated**, superseded by `tokenPairOracleData`
- `mapping(address => uint256) public maxTimePriceValid`: Per-token staleness window. Doubles as the reward-token flag: `isRewardToken(t)` is `maxTimePriceValid[t] > 0`.
- `mapping(address => mapping(address => TokenFeedConfiguration[])) public tokenPairOracleData`: Primary storage, keyed `fromToken -> toToken`

### TokenFeedConfiguration

- `address chainlinkFeed`: The address of the Chainlink price feed
- `bool reverse`: Whether to reverse the price calculation (divide instead of multiply)
- `uint256 heartbeat`: Maximum time between price feed updates

### Functions

- `function initialize(address _owner) external`: Initializes the contract with the given owner.
- `function addTokenConfiguration(address fromToken, address toToken, TokenFeedConfiguration[] calldata configurations) external`: Configures the feed chain for a token pair. Owner only.
- `function removeTokenConfiguration(address fromToken, address toToken) external`: Removes the feed chain for a pair. Owner only. Deliberately does **not** clear `maxTimePriceValid`, which is keyed by `fromToken` alone and shared with the token's other pairs.
- `function setMaxTimePriceValid(address fromToken, uint256 _maxTimePriceValid) external`: Sets the staleness window; rejects zero. Owner only.
- `function clearRewardToken(address fromToken) external`: Retires the token entirely by zeroing `maxTimePriceValid`. Owner only. Added because `isRewardToken` was otherwise a **one-way latch** — nothing could unset it, so a mistakenly configured token remained permanently eligible for the permissionless compound-fee sweep and relayer approval in `MamoMultiMarketStrategy`.
- `function checkPrice(uint256 _amountIn, address _fromToken, address _toToken, uint256 _minOut, uint256 _slippageInBps) external view returns (bool)`: Checks a swap against the feed price with the provided slippage.
- `function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken) public view returns (uint256)`: Expected output amount for a swap.
- `function isRewardToken(address token) external view returns (bool)`: Whether the token has a staleness window configured.
- `function isTokenPairConfigured(address fromToken, address toToken) external view returns (bool)`: Whether the pair has feeds *and* the from-token has a staleness window.

## MamoMultiMarketStrategy

Splits deposits across N Moonwell markets and M ERC4626 vaults, with market definitions read from
`MarketRegistry` and per-market allocations stored locally. Designed to be used as an implementation
for proxies; the implementation is initializer-locked in its constructor.

Notes that are easy to get wrong and are enforced in code:

- **Two ceilings per market.** A withdrawal from a Moonwell market is capped at
  `min(balanceOfUnderlying, getCash())`, not just the position size. A fully lent-out market returns
  `TOKEN_INSUFFICIENT_CASH` rather than reverting, and treating that as a hard failure took down the
  whole withdrawal — including the pass that would have covered the shortfall elsewhere
  (Sherlock #37). ERC4626 legs are capped at `maxWithdraw`, and a full-capacity exit goes through
  `redeem(maxRedeem(...))` so a vault whose rounding makes `withdraw(maxWithdraw(...))` unsatisfiable
  cannot brick the leg.
- **`withdrawAll` and `updatePosition` are best-effort sweeps**, not all-or-nothing. They drain what
  each market can currently pay and leave the rest in place.
- **The compound fee is a property of the balance**, not of the call that fetched it — Merkl's
  `claim` is permissionless, so anything keyed to the claim path is trivially bypassed. It is
  charged on receipt of any priced non-principal token, donations included, and is settled by the
  permissionless `sweepRewardFees`. Rebasing reward tokens are **not supported** (they move the
  balance under a fixed anchor); fee-on-transfer tokens are likewise unsupported.
- **What secures the fee is the finite relayer allowance**, re-armed at exactly the settled balance
  by every sweep. The `isValidSignature` fee gate applies only where that lock does not exist yet —
  a proxy still carrying a legacy unlimited approval. Applying it unconditionally let a 20-wei
  donation revert a solver's entire batch.
- **Market shares are not reward tokens.** `sweepRewardFees` rejects any registered market target,
  active or not, so a mistaken price-checker entry cannot be used to tax the strategy's principal.
- **`claimRewards` skips what it cannot settle** rather than reverting the batch, since the token
  set Merkl pays is not ours to choose.
- **`migrateV1ToMarketRegistry` is one-way**: it requires `marketRegistry == address(0)`, so a
  factory-created strategy (already at `_initialized == 1` with zeroed legacy splits) cannot have
  its registry re-pointed by its owner.
