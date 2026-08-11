## Mamo Strategy Registry

This contract is responsible for tracking user strategies, whitelisting strategy implementations, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations. 

The contract is initialized with three distinct roles that are passed as constructor parameters:
- `admin`: Granted the DEFAULT_ADMIN_ROLE, which can grant and revoke other roles
- `backend`: Granted the BACKEND_ROLE, which can manage strategies
- `guardian`: Granted the GUARDIAN_ROLE, which can pause and unpause the contract

### Roles

- `DEFAULT_ADMIN_ROLE`: The default admin role that can grant and revoke other roles, and is responsible for contract upgrades
- `BACKEND_ROLE`: The role that can manage strategies, deploy strategies, update user strategies, and claim rewards for users
- `GUARDIAN_ROLE`: The role that can pause and unpause the contract in case of emergencies

### Storage

- `mapping(address => EnumerableSet.AddressSet) _userStrategies`: Set of all strategy addresses for each user
- `mapping(address => bool) public whitelistedImplementations`: Mapping of whitelisted implementation addresses
- `mapping(uint256 => address) public latestImplementationById`: Maps strategy IDs to their latest implementation
- `mapping(address => uint256) public implementationToId`: Maps implementations to their strategy ID
- `uint256 private _nextStrategyTypeId`: Counter for strategy type IDs, starting from 1

### Strategy Type ID

The strategy type ID is a simple incremental uint256 value that uniquely identifies a type of strategy. Each new strategy type receives the next available ID from the counter, which starts at 1 and increments by 1 for each new strategy type.

This approach simplifies the ID system while still allowing for type-safe upgrades. Implementations of the same strategy type (e.g., different versions of a USDC strategy) will share the same ID, ensuring that users can only upgrade to the latest implementation of the same strategy type.

### Functions

- `function pause() external`: Pauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function unpause() external`: Unpauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function whitelistImplementation(address implementation) external returns (uint256 strategyTypeId)`: Adds an implementation to the whitelist with a new strategy type ID and sets it as the latest implementation for that type. Returns the assigned strategy type ID. Only callable by accounts with the BACKEND_ROLE.

- `function getImplementationId(address implementation) external view returns (uint256)`: Gets the strategy ID for an implementation.

- `function getLatestImplementation(uint256 strategyId) external view returns (address)`: Gets the latest implementation for a strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function checks that the strategy has the correct registry address set up. This function is pausable.

- `function upgradeStrategy(address strategy) external`: Updates the implementation of a strategy to the latest implementation of the same type. Only callable by the user. This function calls the `upgradeToAndCall` method on the strategy contract through the `IUUPSUpgradeable` interface.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Gets the strategy operator address — the explicitly stored `strategyOperator`, NOT a member of the BACKEND_ROLE set. BACKEND_ROLE is shared by the operator and every factory, and OpenZeppelin's EnumerableSet removes by swap-and-pop, so member index 0 would change identity during a key rotation.

- `function setStrategyOperator(address newOperator) external`: Sets the address strategies recognise as the backend operator. Only callable by accounts with the DEFAULT_ADMIN_ROLE; the new operator cannot be the zero address.

## SlippagePriceChecker

This contract is responsible for validating swap prices using Chainlink price feeds and applying slippage tolerance. It implements the ISlippagePriceChecker interface and is used by the ERC20MoonwellMorphoStrategy contract to validate swap prices for CowSwap orders. The contract is upgradeable using the UUPS (Universal Upgradeable Proxy Standard) pattern.

### Storage

- `uint256 internal constant MAX_BPS`: The maximum basis points value (10,000 = 100%)
- `mapping(address token => TokenFeedConfiguration[]) public tokenOracleData`: Maps token addresses to their oracle configurations

### TokenFeedConfiguration

- `address chainlinkFeed`: The address of the Chainlink price feed
- `bool reverse`: Whether to reverse the price calculation (divide instead of multiply)

### Functions

- `function initialize(address _owner) external initializer`: Initializes the contract with the given owner
- `function _authorizeUpgrade(address newImplementation) internal override onlyOwner`: Function that authorizes an upgrade to a new implementation, only callable by the owner
- `function checkPrice(uint256 _amountIn, address _fromToken, address _toToken, uint256 _minOut, uint256 _slippageInBps) external view returns (bool)`: Checks if a swap meets the price requirements with the provided slippage
- `function addTokenConfiguration(address token, TokenFeedConfiguration[] calldata configurations, uint256 maxTimePriceValid) external`: Adds a configuration for a token with price checker data and sets the maximum time a price is considered valid. Only callable by the owner.
- `function removeTokenConfiguration(address token) external`: Removes all configurations for a token. Only callable by the owner.
- `function getExpectedOut(uint256 _amountIn, address _fromToken, address _toToken) public view returns (uint256)`: Gets the expected output amount for a swap
- `function maxTimePriceValid(address token) external view returns (uint256)`: Gets the maximum time a price is considered valid for a token.

## ERC20MoonwellMorphoStrategy

A generic implementation of a Strategy Contract for ERC20 tokens that splits deposits between Moonwell core market and Morpho Vaults. This contract is designed to be used as an implementation for proxies.

### Storage


- `bytes32 public constant DOMAIN_SEPARATOR`: The settlement contract's EIP-712 domain separator for Cow Swap
- `uint256 public constant SPLIT_TOTAL`: The total basis points for split calculations (10,000)
- `IMamoStrategyRegistry public mamoStrategyRegistry`: Reference to the Mamo Strategy Registry contract
- `IMToken public mToken`: The Moonwell mToken contract
- `IERC4626 public metaMorphoVault`: The MetaMorpho Vault contract
- `IERC20 public token`: The ERC20 token
- `ISlippagePriceChecker public SlippagePriceChecker`: Reference to the swap checker contract used to validate swap prices
- `address public vaultRelayer`: The address of the Cow Protocol Vault Relayer contract that needs token approval for executing trades
- `uint256 public splitMToken`: Percentage of funds allocated to Moonwell mToken in basis points
- `uint256 public splitVault`: Percentage of funds allocated to MetaMorpho Vault in basis points
- `uint256 public allowedSlippageInBps`: The allowed slippage in basis points (e.g., 100 = 1%) used for swap price validation

### Functions

- `struct InitParams`: A struct containing all initialization parameters to avoid stack too deep errors. Includes mamoStrategyRegistry, mamoBackend, mToken, metaMorphoVault, token, SlippagePriceChecker, vaultRelayer, splitMToken, and splitVault.

- `modifier onlyStrategyRegistry()`: Modifier to ensure the caller is the Mamo Strategy Registry contract.

- `modifier onlyStrategyOwner()`: Modifier to ensure the caller is the user who owns this strategy, as verified by the Mamo Strategy Registry.

- `modifier onlyBackend()`: Modifier to ensure the caller is the backend address from the Mamo Strategy Registry.

- `modifier onlyBackendOrStrategyOwner()`: Modifier to ensure the caller is either the backend address from the Mamo Strategy Registry or the user who owns this strategy.

- `function initialize(InitParams calldata params) external`: Initializer function that sets all the parameters and grants appropriate roles. This is used instead of a constructor since the contract is designed to be used with proxies. The function sets up the admin role for the specified admin address. Only the backend address specified in params can call this function, providing protection against unauthorized initialization.

# Mamo Contracts Specification

This document outlines the specification for the Mamo contracts, which enable users to deploy personal strategy contracts and let Mamo manage their funds.

## Mamo Strategy Registry

This contract is responsible for tracking user strategies, whitelisting strategy implementations, and coordinating operations across strategies. It inherits from the AccessControlEnumerable and Pausable contracts from OpenZeppelin and uses the EnumerableSet library for efficient set operations. 

The contract is initialized with three distinct roles that are passed as constructor parameters:
- `admin`: Granted the DEFAULT_ADMIN_ROLE, which can grant and revoke other roles
- `backend`: Granted the BACKEND_ROLE, which can manage strategies
- `guardian`: Granted the GUARDIAN_ROLE, which can pause and unpause the contract

### Roles

- `DEFAULT_ADMIN_ROLE`: The default admin role that can grant and revoke other roles, and is responsible for contract upgrades
- `BACKEND_ROLE`: The role that can manage strategies, deploy strategies, update user strategies, and claim rewards for users
- `GUARDIAN_ROLE`: The role that can pause and unpause the contract in case of emergencies

### Storage

- `mapping(address => EnumerableSet.AddressSet) _userStrategies`: Set of all strategy addresses for each user
- `mapping(address => bool) public whitelistedImplementations`: Mapping of whitelisted implementation addresses
- `mapping(uint256 => address) public latestImplementationById`: Maps strategy IDs to their latest implementation
- `mapping(address => uint256) public implementationToId`: Maps implementations to their strategy ID
- `uint256 private _nextStrategyTypeId`: Counter for strategy type IDs, starting from 1

### Strategy Type ID

The strategy type ID is a simple incremental uint256 value that uniquely identifies a type of strategy. Each new strategy type receives the next available ID from the counter, which starts at 1 and increments by 1 for each new strategy type.

This approach simplifies the ID system while still allowing for type-safe upgrades. Implementations of the same strategy type (e.g., different versions of a USDC strategy) will share the same ID, ensuring that users can only upgrade to the latest implementation of the same strategy type.

#### Creating a type vs rolling out an implementation

`whitelistImplementation(implementation, strategyTypeId)` has exactly two sanctioned uses, and the
contract enforces the split:

- `strategyTypeId == 0` - **create a new strategy type.** The next counter value is assigned and the
  counter advances. This is the only way a type comes into existence.
- `strategyTypeId == <existing id>` - **roll out a new implementation** for a type that already
  exists. The counter is untouched. Passing an id that is not in use reverts with
  `Unknown strategy type`.

A new type can never be created at a caller-chosen id. That restriction is what keeps
`nextStrategyTypeId` authoritative: when an explicit id could claim a free slot, it was able to
squat the value the counter was about to hand out, and the next automatic registration then
overwrote `latestImplementationById` for that slot. The consequences were unrecoverable -
`addStrategy` requires an exact match against the latest implementation, so every factory pinned to
the displaced implementation stopped working, and its existing proxies would accept only an
unrelated implementation as their upgrade target. Neither can be undone: `latestImplementationById`
is written in exactly one place, and the "Implementation already whitelisted" guard blocks
re-registering the displaced implementation.

#### Operational constraint on the deployed registry

`MamoStrategyRegistry` is **not upgradeable**, so the enforcement above applies only to a freshly
deployed registry. The registry live on Base (`0x46a5624C2ba92c08aBA4B206297052EDf14baa92`) predates
it and its counter is already desynchronised:

```
nextStrategyTypeId          = 4
latestImplementationById(4) = 0x6C8577fa9B10807f7485f6476C2AFE0B8d61D1e7   (occupied)
```

`nextStrategyTypeId` is therefore a **stale lower bound, not the next free slot**. On this registry:

- **Never call `whitelistImplementation(impl, 0)`.** Auto-assignment would take id 4 and
  permanently strand strategy type 4. Proposals `005_MamoStakingDeployment` and
  `008_MamoStakingV2Deployment` use this form and must not be re-executed against production.
- **Create new types with an explicit id `>= 5`**, after asserting the id is free
  (`latestImplementationById(id) == address(0)`) and that the counter has not reached it
  (`nextStrategyTypeId() < id`). `012_DeployLeveragedAeroAccountSystem` follows this pattern.
- Implementation rollouts to existing types (`009`, `010`, `011`) are unaffected.

### Functions

- `function pause() external`: Pauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function unpause() external`: Unpauses the contract. Only callable by accounts with the GUARDIAN_ROLE.

- `function whitelistImplementation(address implementation) external returns (uint256 strategyTypeId)`: Adds an implementation to the whitelist with a new strategy type ID and sets it as the latest implementation for that type. Returns the assigned strategy type ID. Only callable by accounts with the BACKEND_ROLE.

- `function getImplementationId(address implementation) external view returns (uint256)`: Gets the strategy ID for an implementation.

- `function getLatestImplementation(uint256 strategyId) external view returns (address)`: Gets the latest implementation for a strategy ID.

- `function addStrategy(address user, address strategy) external`: Adds a strategy for a user. Only callable by accounts with the BACKEND_ROLE. The backend is responsible for deploying the strategy before calling this function. This function checks that the strategy has the correct registry address set up. This function is pausable.

- `function upgradeStrategy(address strategy) external`: Updates the implementation of a strategy to the latest implementation of the same type. Only callable by the user. This function calls the `upgradeToAndCall` method on the strategy contract through the `IUUPSUpgradeable` interface.

- `function getUserStrategies(address user) external view returns (address[] memory)`: Gets all strategies for a user.

- `function isUserStrategy(address user, address strategy) external view returns (bool)`: Checks if a strategy belongs to a user.

- `function getBackendAddress() external view returns (address)`: Gets the strategy operator address — the explicitly stored `strategyOperator`, NOT a member of the BACKEND_ROLE set. BACKEND_ROLE is shared by the operator and every factory, and OpenZeppelin's EnumerableSet removes by swap-and-pop, so member index 0 would change identity during a key rotation.

- `function setStrategyOperator(address newOperator) external`: Sets the address strategies recognise as the backend operator. Only callable by accounts with the DEFAULT_ADMIN_ROLE; the new operator cannot be the zero address.

## Operator Containment (security note)

`getBackendAddress()` returns the explicitly stored `strategyOperator`, not a member of the
BACKEND_ROLE set. That removed a real bug — swap-and-pop removal from an `EnumerableSet` could hand
operator identity to a factory during a key rotation — but it has an accepted cost, recorded here
because it changes the incident-response picture:

- Revoking BACKEND_ROLE from a compromised operator key **no longer removes its strategy-level
  authority**. `onlyBackend` on the strategies reads `strategyOperator`, which role changes do not
  move.
- `setStrategyOperator` is DEFAULT_ADMIN_ROLE, i.e. the timelocked multisig, and it cannot be set
  to the zero address.
- The strategies' `onlyBackend` entry points are not `whenNotPaused`, so pausing the registry does
  not reach them.

Left alone, containment would therefore be strictly slower than before the change. It is not:
`freezeStrategyOperator()` (GUARDIAN_ROLE, the same role that holds `pause`) is the fast path. It
can only ever set the operator to the registry's own address — a sentinel no key controls and which
never calls a strategy's `onlyBackend` surface — so the guardian can switch the backend off without
being able to become it. Recovery stays with DEFAULT_ADMIN.

### Runbook: suspected operator key compromise

1. **GUARDIAN** — `MamoStrategyRegistry.freezeStrategyOperator()`. Every strategy's
   `updatePosition` / `claimRewards` / `setFeeRecipient` becomes uncallable immediately. User
   deposits and withdrawals are unaffected; this is not a fund freeze.
2. **GUARDIAN** — `pause()` if strategy *creation* should also stop (this blocks `addStrategy` and
   `upgradeStrategy`; step 1 does not).
3. **ADMIN** — `revokeRole(BACKEND_ROLE, compromisedKey)` so the key can no longer register
   strategies, and `grantRole(BACKEND_ROLE, newKey)`.
4. **ADMIN** — `setStrategyOperator(newKey)` to restore operations. Only after step 3: the two are
   deliberately separate, and only this step re-enables the strategy-level surface.
5. Verify `getBackendAddress() == newKey` and that the old key holds neither the role nor the
   operator slot.
